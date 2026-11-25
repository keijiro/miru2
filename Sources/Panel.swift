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
    // Keep the first entry of the last selected page visible as the grid reflows.
    private var pageAnchor = 0
    private(set) var listingError: String?
    private(set) var thumbnails: [URL: CGImage] = [:]
    var cardTextures: [URL: MTLTexture] = [:]
    var labelTextures: [PanelLabel: LabelTexture] = [:]
    private(set) var hovered: [PanelAction] = []
    private(set) var litGrips: [Vec2] = []
    private(set) var gripOpacity: Float = 0

    func updateHover(_ actions: [PanelAction], delta: Float) {
        hovered = actions
        let grips = actions.compactMap { action -> Vec2? in
            switch action {
            case .move(let side), .resize(let side): return side
            default: return nil
            }
        }
        if !grips.isEmpty { litGrips = grips }
        gripOpacity = clamp(gripOpacity + (grips.isEmpty ? -delta : delta) / 0.09, 0, 1)
    }

    var controls = false
    var pan = Vec2.zero

    var browser: Bool { entry == nil }
    var canShowPanorama: Bool { entry?.kind == .video && playback?.frame != nil }
    var ui: PanelUI { PanelUI(size: placement.size) }
    var page: Int { pageAnchor / ui.pageSize }
    var pageCount: Int { max(1, (entries.count + ui.pageSize - 1) / ui.pageSize) }
    var visibleEntries: ArraySlice<MediaEntry> {
        let capacity = ui.pageSize
        return entries.dropFirst(pageAnchor / capacity * capacity).prefix(capacity)
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

    func browse(_ url: URL) {
        if !browser {
            entry = nil
            playback = nil
            image = nil
            imageLoad = nil
            controls = false
        }
        directory = url
        resetThumbnails()
        entries = []
        listingError = nil
        listing = loadDirectory(url, root: root)
        changePage(to: 0)
    }

    func changePage(to index: Int) {
        pageAnchor = clamp(index, 0, pageCount - 1) * ui.pageSize
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

    func open(_ entry: MediaEntry, state: SavedPanel? = nil) {
        listing = nil
        entries = []
        resetThumbnails()
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
        if loadThumbnails, thumbnailLoad == nil, let next = remainingThumbnails.popFirst() {
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

    func buttons(panorama: Bool) -> [Button] {
        let ui = ui
        if browser {
            var buttons = [ui.close, ui.exit]
            if directory != root { buttons.append(ui.up) }
            if page > 0 { buttons.append(ui.previous) }
            if page + 1 < pageCount { buttons.append(ui.next) }
            return buttons
        }
        var buttons = [ui.close, ui.back]
        if controls, let playback {
            buttons += ui.playbackButtons(playback, video: canShowPanorama, panorama: panorama)
        }
        return buttons
    }
}
