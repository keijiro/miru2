import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal
import os

enum MediaKind: String {
    case folder, video, image, audio

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "mpg", "mpeg", "3gp", "webm", "ogv": self = .video
        case "jpeg", "jpg", "png", "webp", "avif", "heic", "heif", "tiff", "tif", "bmp", "gif": self = .image
        case "wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac", "ogg", "oga", "opus", "weba": self = .audio
        default: return nil
        }
    }
}

struct MediaEntry {
    let url: URL
    let kind: MediaKind
    var isParent = false
    var name: String { isParent ? "↑ Up" : url.lastPathComponent }
}

// Directory enumeration, still-image decoding and video metadata loading stay off the XR thread.
final class MediaLoad<Value>: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)

    func complete(_ result: Value) { value.withLock { $0 = result } }

    func take() -> Value? {
        value.withLock {
            let result = $0
            $0 = nil
            return result
        }
    }
}

func loadDirectory(_ directory: URL, root: URL) -> MediaLoad<Result<[MediaEntry], Error>> {
    let result = MediaLoad<Result<[MediaEntry], Error>>()
    DispatchQueue.global(qos: .userInitiated).async {
        result.complete(Result {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
            )
            return files.compactMap { url -> MediaEntry? in
                guard let info = try? url.resourceValues(forKeys: keys) else { return nil }
                if info.isSymbolicLink == true {
                    let target = url.resolvingSymlinksInPath()
                    guard isInside(target, root: root), target != directory,
                          let targetInfo = try? target.resourceValues(forKeys: keys) else { return nil }
                    if targetInfo.isDirectory == true { return MediaEntry(url: url, kind: .folder) }
                    if targetInfo.isRegularFile == true, let kind = MediaKind(url: url) {
                        return MediaEntry(url: url, kind: kind)
                    }
                    return nil
                }
                if info.isDirectory == true { return MediaEntry(url: url, kind: .folder) }
                guard info.isRegularFile == true, let kind = MediaKind(url: url) else { return nil }
                return MediaEntry(url: url, kind: kind)
            }.sorted {
                if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        })
    }
    return result
}

func isInside(_ url: URL, root: URL) -> Bool {
    url.pathComponents.starts(with: root.pathComponents)
}

func loadImage(_ url: URL, device: MTLDevice) -> MediaLoad<MTLTexture?> {
    let result = MediaLoad<MTLTexture?>()
    DispatchQueue.global(qos: .userInitiated).async {
        let texture = decodeImage(url, maximumSize: 4096).flatMap { imageTexture($0, device: device) }
        result.complete(texture)
    }
    return result
}

private func decodeImage(_ url: URL, maximumSize: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumSize,
        kCGImageSourceShouldCacheImmediately: true
    ]
    return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
        CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary)
    }
}

func loadThumbnail(_ entry: MediaEntry) async -> CGImage? {
    if entry.kind == .image { return decodeImage(entry.url, maximumSize: 256) }
    let video = await VideoAsset.load(entry.url)
    guard !Task.isCancelled, !video.unavailable else { return nil }
    defer { withExtendedLifetime(video) {} }
    let generator = AVAssetImageGenerator(asset: video.asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 256, height: 144)
    return try? await withTaskCancellationHandler {
        try await generator.image(at: .zero).image
    } onCancel: {
        generator.cancelAllCGImageGeneration()
    }
}

private struct VideoAsset {
    let asset: AVURLAsset
    let track: AVAssetTrack?
    let unavailable: Bool
    // AVAssetResourceLoader holds its delegate weakly.
    private var resource: HEVCResource?

    static func load(_ url: URL) async -> VideoAsset {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else {
            return VideoAsset(asset: asset, track: nil, unavailable: false)
        }
        guard let track = tracks.first else {
            return VideoAsset(asset: asset, track: nil, unavailable: true)
        }
        guard tracks.count == 1, (try? await track.load(.isDecodable)) == false else {
            return VideoAsset(asset: asset, track: track, unavailable: false)
        }
        if !Task.isCancelled, let resource = try? HEVCResource(url: url) {
            let compatible = resource.makeAsset()
            if let tracks = try? await compatible.loadTracks(withMediaType: .video),
               let track = tracks.first, (try? await track.load(.isDecodable)) == true {
                return VideoAsset(asset: compatible, track: track, unavailable: false, resource: resource)
            }
        }
        return VideoAsset(asset: asset, track: track, unavailable: true)
    }
}

func imageTexture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
    makeTexture(width: image.width, height: image.height, device: device) { context in
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

struct VideoUV {
    var u: Vec4 = [1, 0, 0, 0]
    var v: Vec4 = [0, 1, 0, 0]

    init() {}

    func cropped(to rect: Rect) -> VideoUV {
        var result = self
        result.u = [u.x * rect.size.x, u.y * rect.size.y, u.z + u.x * rect.origin.x + u.y * rect.origin.y, 0]
        result.v = [v.x * rect.size.x, v.y * rect.size.y, v.z + v.x * rect.origin.x + v.y * rect.origin.y, 0]
        return result
    }

    init(size: CGSize, transform: CGAffineTransform) {
        self.init()
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0,
              abs(transform.a * transform.d - transform.b * transform.c) > 0.0001 else { return }
        let inverse = transform.inverted()
        let origin = bounds.origin.applying(inverse)
        let right = CGPoint(x: bounds.maxX, y: bounds.minY).applying(inverse)
        let down = CGPoint(x: bounds.minX, y: bounds.maxY).applying(inverse)
        u = [Float((right.x - origin.x) / size.width), Float((down.x - origin.x) / size.width),
             Float(origin.x / size.width), 0]
        v = [Float((right.y - origin.y) / size.height), Float((down.y - origin.y) / size.height),
             Float(origin.y / size.height), 0]
    }
}

final class VideoFrame {
    // The CV objects own the IOSurface mapping. Keep them alive through Metal completion.
    private let buffer: CVPixelBuffer
    private let planes: (CVMetalTexture, CVMetalTexture)
    let luma: MTLTexture
    let chroma: MTLTexture
    let conversion: Vec4

    init?(buffer: CVPixelBuffer, cache: CVMetalTextureCache) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard full || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              let y = Self.texture(buffer, cache: cache, plane: 0, format: .r8Unorm),
              let cbcr = Self.texture(buffer, cache: cache, plane: 1, format: .rg8Unorm),
              let luma = CVMetalTextureGetTexture(y), let chroma = CVMetalTextureGetTexture(cbcr) else { return nil }
        self.buffer = buffer
        self.planes = (y, cbcr)
        self.luma = luma
        self.chroma = chroma
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let coefficients: Vec2
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            coefficients = [0.299, 0.114]
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            coefficients = [0.2627, 0.0593]
        } else {
            coefficients = [0.2126, 0.0722]
        }
        conversion = [coefficients.x, coefficients.y, full ? 0 : 16 / 255, full ? 1 : 255 / 219]
    }

    private static func texture(
        _ buffer: CVPixelBuffer, cache: CVMetalTextureCache, plane: Int, format: MTLPixelFormat
    ) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }
}

final class Playback {
    let url: URL
    let openedAt = DispatchTime.now()
    private let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var videoAsset: VideoAsset?
    private var videoLoad: MediaLoad<(VideoAsset, VideoUV)>?
    private var videoTask: Task<Void, Never>?
    private var initialPosition: Double?
    private var pendingSeek: MediaLoad<Bool>?
    private var seekTarget: Double?
    private(set) var frame: VideoFrame?
    private(set) var videoUV = VideoUV()
    private(set) var time = 0.0
    private(set) var failed = false
    var videoUnavailable: Bool { videoAsset?.unavailable == true }
    private(set) var duration = 0.0
    private(set) var aspect: Float?
    private(set) var paused: Bool
    var loopStart: Double
    var loopEnd: Double?
    var muted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
    init(entry: MediaEntry, paused: Bool, muted: Bool, loopStart: Double, loopEnd: Double?, position: Double? = nil) {
        url = entry.url
        self.paused = paused
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        let startTime = position ?? loopStart
        initialPosition = startTime > 0 ? startTime : nil
        player.actionAtItemEnd = .pause
        player.isMuted = muted
        if entry.kind == .video {
            let result = MediaLoad<(VideoAsset, VideoUV)>()
            videoLoad = result
            videoTask = Task {
                let video = await VideoAsset.load(entry.url)
                var uv = VideoUV()
                if let track = video.track, let (size, orientation) = try? await track.load(.naturalSize, .preferredTransform) {
                    uv = VideoUV(size: size, transform: orientation)
                }
                if !Task.isCancelled { result.complete((video, uv)) }
            }
        } else {
            start(AVPlayerItem(url: entry.url))
        }
    }

    private func start(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        if !paused && initialPosition == nil { player.play() }
    }

    private func startVideo(_ video: VideoAsset, uv: VideoUV) {
        videoAsset = video
        videoUV = uv
        let item = AVPlayerItem(asset: video.asset)
        if !video.unavailable {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            output.suppressesPlayerRendering = true
            item.add(output)
            self.output = output
        }
        start(item)
    }

    deinit {
        videoTask?.cancel()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
    }

    func togglePaused() {
        paused.toggle()
        if paused { player.pause() }
        else if initialPosition == nil { player.play() }
    }

    var savedState: PlaybackState? {
        guard let item = player.currentItem, item.status == .readyToPlay,
              !failed, duration > 0, initialPosition == nil else { return nil }
        let position = pendingSeek == nil ? player.currentTime().seconds : time
        return PlaybackState(position: clamp(position.isFinite ? position : time, 0, duration),
                             loopStart: loopStart, loopEnd: loopEnd)
    }

    func seek(_ seconds: Double, precise: Bool = false) {
        guard duration > 0 else { return }
        // While a seek is in flight, keep the last frame and coalesce further requests.
        let target = clamp(seconds, 0, max(0, duration - 0.01))
        time = target
        guard pendingSeek == nil else {
            seekTarget = target
            return
        }
        let result = MediaLoad<Bool>()
        pendingSeek = result
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            result.complete(finished)
        }
    }

    // Called once per stereo frame, before either eye is encoded.
    func update(hostTime: Double, cache: CVMetalTextureCache) -> Bool {
        if let (video, uv) = videoLoad?.take() {
            videoLoad = nil
            videoTask = nil
            startVideo(video, uv: uv)
        }
        guard let item = player.currentItem else { return false }
        if item.status == .failed || player.status == .failed {
            if !failed { print("Playback failed: \(item.error?.localizedDescription ?? player.error?.localizedDescription ?? "unknown error")") }
            failed = true
            return false
        }
        if duration == 0, item.status == .readyToPlay {
            let seconds = item.duration.seconds
            if seconds.isFinite && seconds > 0 {
                duration = seconds
                loopStart = clamp(loopStart, 0, max(0, duration - 0.1))
                loopEnd = loopEnd.map { min($0, duration) }.flatMap { $0 > loopStart + 0.1 ? $0 : nil }
                if let initialPosition { seek(initialPosition, precise: true) }
                else if !paused { player.play() }
            }
        }
        if output != nil, aspect == nil {
            let size = item.presentationSize
            if size.width > 0 && size.height > 0 { aspect = Float(size.width / size.height) }
        }
        if let pending = pendingSeek {
            guard pending.take() != nil else { return false }
            pendingSeek = nil
            if let next = seekTarget {
                seekTarget = nil
                seek(next, precise: true)
                return false
            }
            initialPosition = nil
            if !paused { player.play() }
        }

        if let output {
            let itemTime = output.itemTime(forHostTime: hostTime)
            let seconds = itemTime.seconds
            if seconds.isFinite { time = max(0, seconds) }
            if shouldLoop {
                seek(loopStart, precise: true)
                return false
            }
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
               let texture = VideoFrame(buffer: buffer, cache: cache) {
                frame = texture
                return true
            }
        } else {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { time = max(0, seconds) }
            if shouldLoop { seek(loopStart, precise: true) }
        }
        return false
    }

    private var shouldLoop: Bool {
        guard !paused, duration > 0 else { return false }
        if let loopEnd { return time >= loopEnd }
        return time >= duration - 0.02 && player.timeControlStatus == .paused
    }
}
