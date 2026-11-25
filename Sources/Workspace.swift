import COpenXR
import CoreVideo
import CryptoKit
import Foundation
import Metal
import simd

private struct Grab {
    let panel: Panel
    let action: PanelAction
    let initial: Placement
    let point: Vec3
    let initialPan: Vec2
    let distance: Float
    let initialScroll: Float
    var dragTarget: Float?
    var moved = false
}

private enum PointerButton { case trigger, squeeze }

private final class Pointer {
    var button: PointerButton?
    var acceptsPress = false
    var emptyPress: Double?
    var grab: Grab?
    var ray: Ray?
    var hit: Hit?
    var preview: Placement?
}

struct Hit {
    let panel: Panel
    let action: PanelAction?
    let uv: Vec2
    let distance: Float
}

private struct SavedLayout: Codable {
    var panels: [SavedPanel]
    var panorama: Int?
    var panoramaYaw: Float?
    var lastBrowserDirectory: URL?
}

final class Workspace {
    let root: URL
    let device: MTLDevice
    let cache: CVMetalTextureCache
    private let layoutURL: URL?
    private let storage = DispatchQueue(label: "miru.layout", qos: .utility)
    private(set) var panels: [Panel] = []
    private(set) var panorama: Panel?
    private(set) var panoramaYaw: Float = 0
    private var anchor: (position: Vec3, yaw: Float)?
    private let pointers = [Pointer(), Pointer()]
    private var head = XrPosef()
    private var restored: SavedLayout?
    private var lastBrowserDirectory: URL?
    private let initial: [URL]
    private let muted: Bool
    private let startPanorama: Bool
    private let diagnostics: Bool
    private var dirty = false

    init(options: Options, device: MTLDevice) throws {
        self.device = device
        root = options.root
        initial = options.media
        muted = options.stressCount != nil
        startPanorama = options.startPanorama
        diagnostics = options.metrics
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw MiruError("Could not create the Core Video Metal texture cache")
        }
        self.cache = cache
        if initial.isEmpty {
            let key = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
            layoutURL = options.layoutDirectory.appendingPathComponent(key + ".json")
            if let layoutURL, FileManager.default.fileExists(atPath: layoutURL.path) {
                do { restored = try JSONDecoder().decode(SavedLayout.self, from: Data(contentsOf: layoutURL)) }
                catch { print("Could not load workspace: \(error.localizedDescription)") }
            }
        } else {
            layoutURL = nil
        }
    }

    func update(views: [XrView], hands: [Hand], menu: MenuCommand?, hostTime: Double, delta: Float) -> Int {
        lastTime = hostTime
        head = views[0].pose
        let center = (views[0].pose.position.vector + views[1].pose.position.vector) * 0.5
        head.position = XrVector3f(x: center.x, y: center.y, z: center.z)
        if anchor == nil { initialize() }
        switch menu {
        case .openBrowser: openBrowser(inFrontOf: head)
        case .recenter: recenter()
        case nil: break
        }
        for panel in panels { panel.placement.face(center) }
        for (pointer, hand) in zip(pointers, hands) { update(pointer, with: hand, at: hostTime) }
        for (pointer, hand) in zip(pointers, hands) where abs(hand.stickY) > 0.15 {
            pointer.hit = pointer.ray.flatMap(pick)
        }
        var updatedFrames = 0
        var canStartThumbnail = !panels.contains { $0.hasThumbnailJob }
        for panel in panels {
            if panel.browser {
                let grab = pointers.compactMap(\.grab).first { $0.panel === panel }
                var stick: Float = 0
                if grab == nil {
                    for (pointer, hand) in zip(pointers, hands) where pointer.hit?.panel === panel && pointer.button == nil {
                        if abs(hand.stickY) > abs(stick) { stick = hand.stickY }
                    }
                }
                let previousOffset = panel.scrollOffset
                panel.updateScroll(dragTarget: grab?.dragTarget, stick: stick, delta: delta)
                if abs(stick) > 0.15, panel.scrollOffset != previousOffset {
                    rememberBrowserDirectory(panel.directory)
                }
            }
            if panel.update(hostTime: hostTime, cache: cache, loadThumbnails: canStartThumbnail) {
                updatedFrames += 1
            }
            if panel.browser, panel.hasThumbnailJob { canStartThumbnail = false }
        }
        for pointer in pointers {
            pointer.hit = pointer.ray.flatMap(pick)
        }
        for panel in panels {
            let actions = pointers.compactMap { pointer -> PanelAction? in
                if let grab = pointer.grab, grab.panel === panel { return grab.action }
                guard let hit = pointer.hit, hit.panel === panel else { return nil }
                return hit.action
            }
            panel.updateHover(actions, delta: delta)
        }
        if dirty { save() }
        return updatedFrames
    }

    private func recenter() {
        guard let anchor else { return }
        let origin = (position: head.position.vector, yaw: head.heading)
        let yaw = origin.yaw - anchor.yaw
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        for panel in panels {
            panel.placement.center = origin.position + rotation.act(panel.placement.center - anchor.position)
        }
        if panorama != nil { panoramaYaw = origin.yaw }
        self.anchor = origin

        for pointer in pointers {
            pointer.grab = nil
            pointer.emptyPress = nil
            pointer.preview = nil
            pointer.acceptsPress = false
        }
        dirty = true
        if diagnostics { print("Recentered the workspace.") }
    }

    private func initialize() {
        let origin = (position: head.position.vector, yaw: head.heading)
        anchor = origin
        let rotation = simd_quatf(angle: origin.yaw, axis: Vec3(0, 1, 0))
        if let restored {
            lastBrowserDirectory = restored.lastBrowserDirectory
            var indexedPanels: [Int: Panel] = [:]
            for (index, state) in restored.panels.enumerated() {
                let directory = state.directory.resolvingSymlinksInPath()
                guard state.directory.isFileURL, isInside(directory, root: root),
                      state.placement.center.allFinite, state.placement.size.allFinite else { continue }
                var placement = state.placement
                placement.center = origin.position + rotation.act(placement.center)
                placement.size = simd_clamp(placement.size, PanelUI.minimumSize, [6, 6])
                let panel = Panel(placement: placement, directory: directory, root: root, device: device)
                if let url = state.media, url.isFileURL, isInside(url.resolvingSymlinksInPath(), root: root),
                   FileManager.default.fileExists(atPath: url.path), let kind = MediaKind(url: url) {
                    panel.open(MediaEntry(url: url, kind: kind), state: state)
                } else {
                    panel.browse(directory)
                }
                indexedPanels[index] = panel
                panels.append(panel)
            }
            if let index = restored.panorama, let panel = indexedPanels[index], panel.entry?.kind == .video,
               let yaw = restored.panoramaYaw, yaw.isFinite {
                panorama = panel
                panoramaYaw = yaw + origin.yaw
            }
            self.restored = nil
        }

        guard !initial.isEmpty else { return }
        let columns = min(initial.count, Int(ceil(sqrt(Double(initial.count) * 1.6))))
        let rows = (initial.count + columns - 1) / columns
        let width = clamp(4.4 / Float(columns), PanelUI.minimumSize.x, 1)
        let height = max(PanelUI.minimumSize.y, width * 0.58)
        for (index, url) in initial.enumerated() {
            guard let kind = MediaKind(url: url) else { continue }
            let row = index / columns
            let rowCount = min(columns, initial.count - row * columns)
            let x = (Float(index % columns) - Float(rowCount - 1) * 0.5) * width * 1.06
            let y = (Float(rows - 1) * 0.5 - Float(row)) * height * 1.1
            let placement = Placement(center: origin.position + rotation.act([x, y, -3]),
                                      size: [width, height])
            let panel = Panel(placement: placement, directory: root, root: root, device: device)
            panel.open(MediaEntry(url: url, kind: kind),
                       state: SavedPanel(placement: placement, directory: root, muted: muted))
            panels.append(panel)
        }
        if startPanorama, let panel = panels.first(where: { $0.entry?.kind == .video }) {
            togglePanorama(panel)
        }
    }

    func finish() {
        if dirty || pointers.contains(where: { $0.grab != nil }) { save() }
        storage.sync {}
    }

    private func save() {
        dirty = false
        guard let layoutURL, let anchor else { return }
        let inverse = simd_quatf(angle: -anchor.yaw, axis: Vec3(0, 1, 0))
        let saved = panels.map { panel in
            var saved = panel.saved
            saved.placement.center = inverse.act(saved.placement.center - anchor.position)
            return saved
        }
        let index = panorama.flatMap { active in panels.firstIndex { $0 === active } }
        let layout = SavedLayout(panels: saved, panorama: index,
                                 panoramaYaw: index.map { _ in panoramaYaw - anchor.yaw },
                                 lastBrowserDirectory: lastBrowserDirectory)
        storage.async {
            do {
                try FileManager.default.createDirectory(at: layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(layout).write(to: layoutURL, options: .atomic)
            } catch { print("Could not save workspace: \(error.localizedDescription)") }
        }
    }

    private func openBrowser(inFrontOf pose: XrPosef) {
        let ray = Ray(pose)
        openBrowser(at: ray.point(at: 1.35))
    }

    private func browserPlacement(at position: Vec3) -> Placement {
        var placement = Placement(center: position, size: browserSize)
        placement.face(head.position.vector)
        return placement
    }

    private func openBrowser(at position: Vec3) {
        let directory = browserStartDirectory()
        let panel = Panel(placement: browserPlacement(at: position), directory: directory, root: root, device: device)
        panel.browse(directory)
        panels.append(panel)
        dirty = true
        if diagnostics { print("Opened a media browser.") }
    }

    private func browserStartDirectory() -> URL {
        if let saved = lastBrowserDirectory, saved.isFileURL {
            let directory = saved.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            if isInside(directory, root: root),
               FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return directory
            }
        }
        lastBrowserDirectory = nil
        return root
    }

    private func rememberBrowserDirectory(_ directory: URL) {
        guard lastBrowserDirectory != directory else { return }
        lastBrowserDirectory = directory
        dirty = true
    }

    var beams: [(Ray, Float, Bool)] {
        pointers.compactMap { pointer in
            guard let ray = pointer.ray else { return nil }
            return (ray, pointer.hit?.distance ?? 1.35, pointer.button != nil)
        }
    }

    var previews: [(Placement, Float)] {
        pointers.compactMap { pointer in
            guard let placement = pointer.preview, let start = pointer.emptyPress else { return nil }
            return (placement, Float(clamp((lastTime - start) * 2, 0, 1)))
        }
    }

    private(set) var lastTime = 0.0

    private func update(_ pointer: Pointer, with hand: Hand, at time: Double) {
        guard let pose = hand.pose else {
            if pointer.grab != nil { dirty = true }
            pointer.grab = nil
            pointer.emptyPress = nil
            pointer.preview = nil
            pointer.ray = nil
            pointer.hit = nil
            pointer.button = nil
            pointer.acceptsPress = false
            return
        }
        let ray = Ray(pose)
        pointer.ray = ray
        let trigger = hand.trigger > (pointer.button == .trigger ? 0.35 : 0.55)
        let squeeze = hand.squeeze > (pointer.button == .squeeze ? 0.35 : 0.55)
        let button = pointer.button ?? (squeeze ? .squeeze : .trigger)
        if !(button == .squeeze ? squeeze : trigger) {
            pointer.button = nil
            pointer.acceptsPress = !trigger && !squeeze
            if var grab = pointer.grab {
                if grab.dragTarget != nil {
                    apply(&grab, ray: ray)
                    if !grab.moved, case .entry(let index) = grab.action,
                       let hit = pick(ray), hit.panel === grab.panel, hit.action == grab.action {
                        selectEntry(index, on: grab.panel)
                    }
                } else if grab.action == .seek, let hit = grab.panel.placement.hit(ray) {
                    seek(grab.panel, at: hit.uv.x, precise: true)
                } else if grab.action == .media && !grab.moved && grab.panel.playback != nil {
                    grab.panel.toggleControls(at: time)
                }
                if grab.dragTarget == nil { dirty = true }
            }
            pointer.grab = nil
            pointer.emptyPress = nil
            pointer.preview = nil
            return
        }
        guard pointer.acceptsPress else { return }
        if pointer.button == nil {
            pointer.button = button
            if let hit = pick(ray) {
                guard !pointers.contains(where: { $0.grab?.panel === hit.panel }),
                      let action = button == .squeeze ? .move(.zero) : hit.action else { return }
                press(action, hit: hit, ray: ray, pointer: pointer)
            } else if button == .trigger {
                pointer.emptyPress = time
            }
        }
        if let start = pointer.emptyPress {
            let position = ray.point(at: 1.35)
            if time - start >= 0.5 {
                openBrowser(at: position)
                pointer.emptyPress = nil
                pointer.preview = nil
            } else {
                pointer.preview = browserPlacement(at: position)
            }
        }
        if var grab = pointer.grab {
            apply(&grab, ray: ray)
            pointer.grab = grab
        }
    }

    private func pick(_ ray: Ray) -> Hit? {
        var nearest: Hit?
        for panel in panels.reversed() {
            guard let hit = panel.placement.hit(ray), hit.distance < (nearest?.distance ?? .infinity) else { continue }
            let uv = hit.uv
            let edge = Vec2(repeating: PanelUI.gripReach) / panel.placement.size
            let ui = panel.ui
            let point = uv * ui.size
            let inBody = uv.x >= -edge.x && uv.x <= 1 + edge.x && uv.y >= -edge.y && uv.y <= 1 + edge.y
            let inTransport = panel.controls && ui.transport.contains(point)
            guard inBody || inTransport else { continue }
            var action: PanelAction?
            if panel.openingAge(at: lastTime) >= Panel.openingDuration, panel.mediaStarted == nil {
                if inTransport, let playback = panel.playback, let start = panel.transportChanged,
                   lastTime - start >= Panel.openingDuration {
                    let buttons = ui.playbackButtons(playback, video: panel.canShowPanorama, panorama: panorama === panel)
                    action = ui.seek.contains(point) ? .seek : buttons.first { $0.rect.contains(point) }?.action
                } else if inBody {
                    if panel.browser, ui.close.rect.contains(point) {
                        action = .close
                    } else if panel.browser, ui.viewport.contains(point) {
                        if let index = ui.cardIndex(at: point, offset: panel.scrollOffset), panel.entries.indices.contains(index) {
                            action = .entry(index)
                        } else {
                            action = .scroll
                        }
                    } else if !panel.browser, ui.back.rect.contains(point) {
                        action = .back
                    } else {
                        action = ui.grip(at: point) ?? (panel.playback != nil || panel.contentAspect != nil ? .media : nil)
                    }
                }
            }
            nearest = Hit(panel: panel, action: action, uv: uv, distance: hit.distance)
        }
        return nearest
    }

    private func press(_ action: PanelAction, hit: Hit, ray: Ray, pointer: Pointer) {
        let panel = hit.panel
        switch action {
        case .move, .resize, .seek, .media, .entry, .scroll:
            pointer.grab = Grab(panel: panel, action: action, initial: panel.placement,
                                point: ray.point(at: hit.distance), initialPan: panel.pan, distance: hit.distance,
                                initialScroll: panel.scrollOffset)
            switch action {
            case .entry, .scroll:
                panel.stopScrolling()
                pointer.grab?.dragTarget = panel.scrollOffset
            default: break
            }
        case .close:
            if panorama === panel { panorama = nil }
            panels.removeAll { $0 === panel }
        case .back:
            if panorama === panel { panorama = nil }
            panel.browse(panel.directory, offset: panel.scrollOffset)
            rememberBrowserDirectory(panel.directory)
        case .play: panel.playback?.togglePaused()
        case .mute:
            if let playback = panel.playback { playback.muted.toggle() }
        case .loopStart:
            if let playback = panel.playback {
                playback.loopStart = abs(playback.loopStart - playback.time) < 0.2
                    ? 0 : min(playback.time, max(0, playback.duration - 0.1))
                if let end = playback.loopEnd, end <= playback.loopStart + 0.1 { playback.loopEnd = nil }
            }
        case .loopEnd:
            if let playback = panel.playback {
                playback.loopEnd = playback.loopEnd != nil || playback.time <= playback.loopStart + 0.1
                    ? nil : playback.time
            }
        case .panorama: togglePanorama(panel)
        }
        if pointer.grab == nil { dirty = true }
    }

    private func selectEntry(_ index: Int, on panel: Panel) {
        let entry = panel.entries[index]
        guard isInside(entry.url.resolvingSymlinksInPath(), root: root) else { return }
        if entry.kind == .folder {
            panel.openFolder(entry)
        } else {
            panel.open(entry, at: lastTime)
            if diagnostics { print("Opened \(entry.kind.rawValue): \(entry.name)") }
        }
        rememberBrowserDirectory(panel.directory)
        dirty = true
    }

    private func togglePanorama(_ panel: Panel) {
        if panorama === panel { panorama = nil }
        else {
            panorama = panel
            panoramaYaw = head.heading
        }
        if diagnostics { print("180° background \(panorama == nil ? "off" : "on").") }
    }

    private func seek(_ panel: Panel, at u: Float, precise: Bool) {
        guard let playback = panel.playback else { return }
        let seek = panel.ui.seek
        let x = u * panel.placement.size.x
        let time = Double(clamp((x - seek.origin.x) / seek.size.x, 0, 1)) * playback.duration
        if precise || abs(playback.time - time) > 0.15 { playback.seek(time, precise: precise) }
    }

    private func apply(_ grab: inout Grab, ray: Ray) {
        let panel = grab.panel
        switch grab.action {
        case .entry, .scroll:
            guard let intersection = grab.initial.hit(ray) else { return }
            let local = grab.initial.localOffset(ray.point(at: intersection.distance) - grab.point)
            guard grab.moved || simd_length(local) > 0.012 else { return }
            grab.moved = true
            let target = grab.initialScroll + local.y
            let limit = panel.ui.scrollLimit(count: panel.entries.count)
            if let previous = grab.dragTarget, clamp(target, 0, limit) != clamp(previous, 0, limit) {
                rememberBrowserDirectory(panel.directory)
            }
            grab.dragTarget = target
        case .move:
            panel.placement.center = grab.initial.center + ray.point(at: grab.distance) - grab.point
            panel.placement.face(head.position.vector)
        case .resize(let side):
            guard let intersection = grab.initial.hit(ray) else { return }
            let diff = ray.point(at: intersection.distance) - grab.point
            let local = grab.initial.localOffset(diff)
            let size = simd_clamp(grab.initial.size + side * local, PanelUI.minimumSize, [6, 6])
            let offset = side * (size - grab.initial.size) * 0.5
            panel.placement.center = grab.initial.center + grab.initial.right * offset.x + grab.initial.up * offset.y
            panel.placement.face(head.position.vector)
            panel.placement.size = size
            if panel.browser, !panel.loading {
                panel.reflowScroll(from: PanelUI(size: grab.initial.size), offset: grab.initialScroll)
            }
        case .seek:
            if let hit = panel.placement.hit(ray) { seek(panel, at: hit.uv.x, precise: false) }
        case .media:
            guard let intersection = grab.initial.hit(ray) else { return }
            let diff = ray.point(at: intersection.distance) - grab.point
            guard grab.moved || simd_length(diff) > 0.016 else { return }
            grab.moved = true
            let overflow = panel.mediaOverflow
            let local = grab.initial.localOffset(diff) * Vec2(1, -1)
            let change = Vec2(overflow.x > 0.0001 ? local.x * 2 / overflow.x : 0,
                              overflow.y > 0.0001 ? local.y * 2 / overflow.y : 0)
            panel.pan = simd_clamp(grab.initialPan + change, Vec2(repeating: -1), Vec2(repeating: 1))
        default: break
        }
    }
}

extension SIMD where Scalar == Float {
    var allFinite: Bool { indices.allSatisfy { self[$0].isFinite } }
}
