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
    private(set) var page = 0
    private(set) var listingError: String?
    private(set) var thumbnails: [URL: CGImage] = [:]
    private(set) var revision = 0
    var controls = false
    var pan = Vec2.zero

    var browser: Bool { entry == nil }
    var canShowPanorama: Bool { entry?.kind == .video && playback?.frame != nil }
    var pageCount: Int { max(1, (entries.count + PanelUI.pageSize - 1) / PanelUI.pageSize) }
    var visibleEntries: ArraySlice<MediaEntry> {
        entries.dropFirst(page * PanelUI.pageSize).prefix(PanelUI.pageSize)
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
    var chromeKey: String?
    var chrome: MTLTexture?
    var headerKey: Int?
    var header: MTLTexture?
    var transportKey: String?
    var transport: MTLTexture?

    private var listing: MediaLoad<Result<[MediaEntry], Error>>?
    private var imageLoad: MediaLoad<MTLTexture?>?
    private var thumbnailLoad: MediaLoad<(URL, CGImage?)>?
    private var thumbnailJob: Task<Void, Never>?
    private var remainingThumbnails: ArraySlice<MediaEntry> = []
    private var sizeToFit: Float?
    private let device: MTLDevice
    private let root: URL

    init(placement: Placement, directory: URL, root: URL, device: MTLDevice) {
        self.placement = placement
        self.directory = directory
        self.root = root
        self.device = device
    }

    deinit { thumbnailJob?.cancel() }

    func browse(_ url: URL) {
        if !browser {
            placement.size = browserSize
            entry = nil
            playback = nil
            image = nil
            imageLoad = nil
            sizeToFit = nil
            controls = false
            transport = nil
            transportKey = nil
        }
        directory = url
        entries = []
        listingError = nil
        listing = loadDirectory(url, root: root)
        changePage(to: 0)
    }

    func changePage(to index: Int) {
        page = clamp(index, 0, pageCount - 1)
        thumbnailJob?.cancel()
        thumbnailJob = nil
        thumbnailLoad = nil
        thumbnails = [:]
        remainingThumbnails = visibleEntries.filter { $0.kind == .image || $0.kind == .video }[...]
        revision += 1
    }

    func open(_ entry: MediaEntry, state: SavedPanel? = nil, fit: Bool) {
        listing = nil
        entries = []
        thumbnailJob?.cancel()
        thumbnailJob = nil
        thumbnailLoad = nil
        remainingThumbnails = []
        thumbnails = [:]
        self.entry = entry
        if let stored = state?.pan, stored.allFinite {
            pan = simd_clamp(stored, Vec2(repeating: -1), Vec2(repeating: 1))
        } else {
            pan = .zero
        }
        controls = entry.kind == .audio
        revision += 1
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
        if fit { sizeToFit = placement.size.x }
    }

    func update(hostTime: Double, cache: CVMetalTextureCache, loadThumbnails: Bool) -> Bool {
        if let result = listing?.take() {
            listing = nil
            switch result {
            case .success(let entries): self.entries = entries
            case .failure(let error): listingError = error.localizedDescription
            }
            changePage(to: 0)
        }
        if let result = imageLoad?.take() {
            imageLoad = nil
            image = result
            imageFailed = result == nil
        }
        if let (url, image) = thumbnailLoad?.take() {
            thumbnailLoad = nil
            thumbnailJob = nil
            if let image { thumbnails[url] = image; revision += 1 }
        }
        if loadThumbnails, thumbnailLoad == nil, let next = remainingThumbnails.popFirst() {
            let result = MediaLoad<(URL, CGImage?)>()
            thumbnailLoad = result
            thumbnailJob = Task.detached(priority: .utility) {
                result.complete((next.url, await loadThumbnail(next)))
            }
        }

        let newFrame = playback?.update(hostTime: hostTime, cache: cache) ?? false
        if let width = sizeToFit {
            let aspect = image.map { Float($0.width) / Float($0.height) } ?? playback?.aspect
            if let aspect {
                placement.size.y = width / clamp(aspect, 0.52, 3.0)
                sizeToFit = nil
            } else if entry?.kind == .audio {
                placement.size.y = width * 0.48
                sizeToFit = nil
            }
        }
        return newFrame
    }

    func cancelFit() { sizeToFit = nil }

    var saved: SavedPanel {
        SavedPanel(placement: placement, directory: directory, media: entry?.url, pan: pan,
                   paused: playback?.paused ?? false, muted: playback?.muted ?? false,
                   loopStart: playback?.loopStart ?? 0, loopEnd: playback?.loopEnd)
    }

    func buttons(root: URL, transportVisible: Bool, panorama: Bool) -> [Button] {
        if browser {
            var buttons = [PanelUI.close, PanelUI.exit]
            if directory != root { buttons.append(PanelUI.up) }
            if page > 0 { buttons.append(PanelUI.previous) }
            if page + 1 < pageCount { buttons.append(PanelUI.next) }
            for (index, _) in visibleEntries.enumerated() {
                buttons.append(Button(action: .entry(index), rect: PanelUI.card(index), label: ""))
            }
            return buttons
        }
        var buttons = [PanelUI.close, PanelUI.back]
        if transportVisible, let playback {
            buttons += PanelUI.playbackButtons(playback, video: canShowPanorama, panorama: panorama)
        }
        return buttons
    }
}
