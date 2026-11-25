import CoreVideo
import Foundation
import Metal
import simd

let browserSize: Vec2 = [1.0, 0.66]

struct SavedPanel: Codable {
    var placement: Placement
    var directory: URL
    var media: URL?
    var pan: Vec2?
    var paused = false
    var muted = false
    var loopStart = 0.0
    var loopEnd: Double?
}

final class Panel {
    var placement: Placement
    private(set) var directory: URL
    private(set) var entry: MediaEntry?
    private(set) var playback: Playback?
    private(set) var image: MTLTexture?
    private(set) var imageFailed = false
    private(set) var entries: [MediaEntry] = []
    private(set) var scrollOffset: Float = 0
    private var scrollVelocity: Float = 0
    private var parents: [(directory: URL, offset: Float)] = []
    private(set) var listingError: String?
    private(set) var thumbnails: [URL: CGImage] = [:]
    var cardTextures: [URL: MTLTexture] = [:]
    var labelTextures: [PanelLabel: LabelTexture] = [:]
    private(set) var hovered: [PanelAction] = []
    private(set) var litGrips: [Vec2] = []
    private(set) var gripOpacity: Float = 0

    private(set) var backHighlighted = false

    func updateHover(_ actions: [PanelAction], delta: Float) {
        hovered = actions
        let grips = actions.compactMap { action -> Vec2? in
            switch action {
            case .move(let side), .resize(let side): return side
            default: return nil
            }
        }
        let reveal = !grips.isEmpty || actions.contains(.back)
        if reveal {
            litGrips = grips
            backHighlighted = actions.contains(.back)
        }
        gripOpacity = clamp(gripOpacity + (reveal ? delta : -delta) / 0.09, 0, 1)
    }

    static let openingDuration = 0.125
    static let outlineDuration = 0.110
    private var bodyStarted: Double?
    private(set) var mediaStarted: Double?
    private(set) var transportChanged: Double?
    private(set) var controls = false

    func openingAge(at time: Double) -> Double { time - (bodyStarted ?? time) }

    func toggleControls(at time: Double) {
        controls.toggle()
        transportChanged = time
    }

    var pan = Vec2.zero

    var browser: Bool { entry == nil }
    var canShowPanorama: Bool { entry?.kind == .video && playback?.frame != nil }
    var ui: PanelUI { PanelUI(size: placement.size) }
    var visibleEntries: ArraySlice<MediaEntry> {
        entries[ui.visibleRange(offset: scrollOffset, count: entries.count)]
    }
    var loading: Bool { listing != nil }
    var hasThumbnailJob: Bool { thumbnailLoad != nil }
    var contentAspect: Float? {
        if let image { return Float(image.width) / Float(image.height) }
        if let playback, let frame = playback.frame {
            return playback.aspect ?? Float(frame.luma.width) / Float(frame.luma.height)
        }
        return nil
    }

    var mediaOverflow: Vec2 {
        guard let aspect = contentAspect else { return .zero }
        let size = placement.size
        return simd_max([size.y * aspect - size.x, size.x / aspect - size.y], .zero)
    }

    var mediaCrop: Rect {
        let overflow = mediaOverflow
        let cropped = overflow / (placement.size + overflow)
        let start = (Vec2(repeating: 1) - pan) * cropped * 0.5
        return Rect(start.x, start.y, 1 - cropped.x, 1 - cropped.y)
    }

    private var listing: MediaLoad<Result<[MediaEntry], Error>>?
    private var imageLoad: MediaLoad<MTLTexture?>?
    private var thumbnailLoad: MediaLoad<(URL, CGImage?)>?
    private var thumbnailJob: Task<Void, Never>?
    private var thumbnailURL: URL?
    private var thumbnailRange: Range<Int>?
    private var attemptedThumbnails: Set<URL> = []
    private var remainingThumbnails: ArraySlice<MediaEntry> = []
    private let device: MTLDevice
    private let root: URL

    init(placement: Placement, directory: URL, root: URL, device: MTLDevice) {
        self.placement = placement
        self.directory = directory
        self.root = root
        self.device = device
    }

    deinit { thumbnailJob?.cancel() }

    func browse(_ url: URL, offset: Float = 0) {
        if !browser {
            entry = nil
            playback = nil
            image = nil
            imageLoad = nil
            controls = false
            transportChanged = nil
            mediaStarted = nil
        }
        directory = url
        resetThumbnails()
        entries = []
        listingError = nil
        listing = loadDirectory(url, root: root)
        scrollOffset = offset
        scrollVelocity = 0
    }

    func openFolder(_ folder: MediaEntry) {
        if folder.isParent {
            let parent = parents.popLast()
            browse(parent?.directory ?? folder.url, offset: parent?.offset ?? 0)
        } else {
            parents.append((directory, scrollOffset))
            browse(folder.url.resolvingSymlinksInPath())
        }
    }

    func reflowScroll(from initial: PanelUI, offset: Float) {
        let row = offset / initial.rowHeight
        let firstEntry = Int(row) * initial.columns
        let newRow = Float(firstEntry / ui.columns) + (row - floor(row))
        scrollOffset = min(newRow * ui.rowHeight, ui.scrollLimit(count: entries.count))
        scrollVelocity = 0
    }

    func stopScrolling() { scrollVelocity = 0 }

    func updateScroll(dragTarget: Float?, stick: Float, delta: Float) {
        guard browser, !loading else { return }
        let dt = clamp(delta, 0, 0.05)
        guard dt > 0 else { return }
        let limit = ui.scrollLimit(count: entries.count)
        if let dragTarget {
            let target = clamp(dragTarget, 0, limit)
            let movement = (target - scrollOffset) * (1 - exp(-40 * dt))
            scrollOffset += movement
            scrollVelocity += (movement / dt - scrollVelocity) * (1 - exp(-22 * dt))
        } else {
            let speed = -copysign(max(0, abs(stick) - 0.15) / 0.85, stick) * 1.4
            scrollVelocity += (speed - scrollVelocity) * (1 - exp(-(speed == 0 ? 8 : 14) * dt))
            if abs(scrollVelocity) < 0.001 && speed == 0 { scrollVelocity = 0 }
            scrollOffset += scrollVelocity * dt
        }
        if scrollOffset <= 0 && scrollVelocity < 0 || scrollOffset >= limit && scrollVelocity > 0 {
            scrollVelocity = 0
        }
        scrollOffset = clamp(scrollOffset, 0, limit)
    }

    private func resetThumbnails() {
        thumbnailJob?.cancel()
        thumbnailJob = nil
        thumbnailLoad = nil
        thumbnailURL = nil
        thumbnailRange = nil
        attemptedThumbnails.removeAll()
        remainingThumbnails = []
        thumbnails.removeAll()
        cardTextures.removeAll()
    }

    private func updateThumbnailRange() {
        let visible = visibleEntries
        guard thumbnailRange != visible.indices else { return }
        thumbnailRange = visible.indices
        let urls = Set(visible.map(\.url))
        if let thumbnailURL, !urls.contains(thumbnailURL) {
            thumbnailJob?.cancel()
            thumbnailJob = nil
            thumbnailLoad = nil
            self.thumbnailURL = nil
        }
        attemptedThumbnails.formIntersection(urls)
        thumbnails = thumbnails.filter { urls.contains($0.key) }
        cardTextures = cardTextures.filter { urls.contains($0.key) }
        remainingThumbnails = visible.filter {
            ($0.kind == .image || $0.kind == .video) &&
            $0.url != thumbnailURL && !attemptedThumbnails.contains($0.url)
        }[...]
    }

    func open(_ entry: MediaEntry, state: SavedPanel? = nil, at time: Double? = nil) {
        listing = nil
        mediaStarted = time
        if time == nil {
            entries = []
            resetThumbnails()
        }
        self.entry = entry
        if let stored = state?.pan, stored.allFinite {
            pan = simd_clamp(stored, Vec2(repeating: -1), Vec2(repeating: 1))
        } else {
            pan = .zero
        }
        controls = entry.kind == .audio
        image = nil
        imageFailed = false
        if entry.kind == .image {
            playback = nil
            imageLoad = loadImage(entry.url, device: device)
        } else {
            imageLoad = nil
            playback = Playback(entry: entry, paused: state?.paused ?? false, muted: state?.muted ?? false,
                                loopStart: state?.loopStart ?? 0, loopEnd: state?.loopEnd)
        }
    }

    func update(hostTime: Double, cache: CVMetalTextureCache, loadThumbnails: Bool) -> Bool {
        bodyStarted = bodyStarted ?? hostTime
        if let start = mediaStarted, hostTime - start >= Self.outlineDuration {
            mediaStarted = nil
            entries = []
            resetThumbnails()
        }
        if controls, transportChanged == nil, mediaStarted == nil, openingAge(at: hostTime) >= Self.openingDuration {
            transportChanged = hostTime
        }
        if let result = listing?.take() {
            listing = nil
            switch result {
            case .success(let entries): self.entries = entries
            case .failure(let error): listingError = error.localizedDescription
            }
            if directory != root || !parents.isEmpty {
                let parent = MediaEntry(url: parents.last?.directory ?? directory.deletingLastPathComponent(), kind: .folder, isParent: true)
                entries.insert(parent, at: 0)
            }
            scrollOffset = min(scrollOffset, ui.scrollLimit(count: entries.count))
        }
        if let result = imageLoad?.take() {
            imageLoad = nil
            image = result
            imageFailed = result == nil
        }
        if browser { updateThumbnailRange() }
        if let (url, image) = thumbnailLoad?.take() {
            thumbnailLoad = nil
            thumbnailJob = nil
            thumbnailURL = nil
            attemptedThumbnails.insert(url)
            if let image {
                thumbnails[url] = image
                cardTextures.removeValue(forKey: url)
            }
        }
        if browser, loadThumbnails, thumbnailLoad == nil, let next = remainingThumbnails.popFirst() {
            let result = MediaLoad<(URL, CGImage?)>()
            thumbnailLoad = result
            thumbnailURL = next.url
            thumbnailJob = Task.detached(priority: .utility) {
                result.complete((next.url, await loadThumbnail(next)))
            }
        }

        return playback?.update(hostTime: hostTime, cache: cache) ?? false
    }

    var saved: SavedPanel {
        SavedPanel(placement: placement, directory: directory, media: entry?.url, pan: pan,
                   paused: playback?.paused ?? false, muted: playback?.muted ?? false,
                   loopStart: playback?.loopStart ?? 0, loopEnd: playback?.loopEnd)
    }

}
