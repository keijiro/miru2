import COpenXR
import CoreGraphics
import Foundation
import Metal
import simd

private struct VideoParameters {
    var conversion: Vec4
    var u: Vec4
    var v: Vec4
}

private struct PanoramaCamera {
    var eyeToPanorama: simd_float4x4
    var fov: Vec4
    var eyeUV: Vec4
}

enum Material {
    case fill(Vec4)
    case texture(MTLTexture, Rect = .full, opacity: Float = 1)
    case ring(Float)
    case video(VideoFrame, VideoUV)
}

struct DrawQuad {
    let model: simd_float4x4
    let material: Material
}

struct RenderFrame {
    var quads: [DrawQuad] = []
    var panorama: (VideoFrame, VideoUV, Float)?

    mutating func quad(_ placement: Placement, _ rect: Rect = .full, _ material: Material, offset: Float = 0) {
        quads.append(DrawQuad(model: placement.model(rect: rect, offset: offset), material: material))
    }

    mutating func outline(_ rect: Rect, on placement: Placement, color: Vec4, offset: Float = 0.004) {
        let thickness = Vec2(repeating: 0.0025) / placement.size
        let p = rect.origin, s = rect.size
        quad(placement, Rect(p.x, p.y, s.x, thickness.y), .fill(color), offset: offset)
        quad(placement, Rect(p.x, p.y + s.y - thickness.y, s.x, thickness.y), .fill(color), offset: offset)
        quad(placement, Rect(p.x, p.y, thickness.x, s.y), .fill(color), offset: offset)
        quad(placement, Rect(p.x + s.x - thickness.x, p.y, thickness.x, s.y), .fill(color), offset: offset)
    }
}

private struct ButtonStyle: Hashable {
    let label: String
    let pixels: SIMD2<Int>
    let active: Bool
    let hovered: Bool
}

final class Renderer {
    private let device: MTLDevice
    private let solid: MTLRenderPipelineState
    private let ring: MTLRenderPipelineState
    private let image: MTLRenderPipelineState
    private let video: MTLRenderPipelineState
    private let panoramic: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let backgroundDepth: MTLDepthStencilState
    private var buttonTextures: [ButtonStyle: MTLTexture] = [:]

    private var cardBackgrounds: [Bool: MTLTexture] = [:]

    init(device: MTLDevice, format: MTLPixelFormat, shaders: URL, sampleCount: Int) throws {
        self.device = device
        let library = try device.makeLibrary(source: String(contentsOf: shaders, encoding: .utf8), options: nil)
        let constants = MTLFunctionConstantValues()
        var srgb = format == .bgra8Unorm_srgb || format == .rgba8Unorm_srgb
        constants.setConstantValue(&srgb, type: .bool, index: 0)
        func makePipeline(_ vertex: String, _ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
            guard let vertexShader = library.makeFunction(name: vertex) else { throw MiruError("Missing \(vertex)") }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = vertexShader
            descriptor.fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
            descriptor.rasterSampleCount = sampleCount
            descriptor.depthAttachmentPixelFormat = .depth32Float
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            color.isBlendingEnabled = blend
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        solid = try makePipeline("quadVertex", "solidFragment", blend: true)
        ring = try makePipeline("quadVertex", "ringFragment", blend: true)
        image = try makePipeline("quadVertex", "imageFragment", blend: true)
        video = try makePipeline("quadVertex", "videoFragment", blend: false)
        panoramic = try makePipeline("panoramaVertex", "panoramaFragment", blend: false)

        let descriptor = MTLDepthStencilDescriptor()
        guard let backgroundDepth = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MiruError("Could not create a background depth state")
        }
        self.backgroundDepth = backgroundDepth
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MiruError("Could not create a panel depth state")
        }
        self.depth = depth
    }

    func prepare(_ workspace: Workspace) -> RenderFrame {
        var output = RenderFrame()
        output.quads.reserveCapacity(workspace.panels.count * 4 + 12)
        let panorama = workspace.panorama
        if let playback = panorama?.playback, let frame = playback.frame {
            output.panorama = (frame, playback.videoUV, workspace.panoramaYaw)
        }
        for panel in workspace.panels {
            let age = panel.openingAge(at: workspace.lastTime)
            if age < Panel.openingDuration {
                drawOpening(.full, age: age, on: panel, output: &output)
                continue
            }
            if panel.browser || panel.mediaStarted != nil {
                prepareBrowser(panel, root: workspace.root, output: &output)
                if let start = panel.mediaStarted {
                    let scale = Float((workspace.lastTime - start) / Panel.outlineDuration)
                    drawOutline(.full, scale: scale, on: panel, output: &output)
                    continue
                }
            } else {
                prepareMedia(panel, isPanorama: panorama === panel, time: workspace.lastTime, output: &output)
            }
            if panel.gripOpacity > 0 {
                for side: Vec2 in [[0, 1], [0, -1], [-1, 0], [1, 0], [-1, 1], [1, 1], [-1, -1], [1, -1]] {
                    let alpha = panel.gripOpacity * (panel.litGrips.contains(side) ? 1 : 0.25)
                    for rect in panel.ui.gripRects(side) {
                        output.quad(panel.placement, rect.normalized(in: panel.ui.size),
                                    .fill([0.87, 0.87, 0.87, alpha]))
                    }
                }
            }
        }
        for (placement, progress) in workspace.previews {
            output.outline(.full, on: placement, color: [0.89, 0.89, 0.89, 0.35 + progress * 0.55])
            let size = Vec2(repeating: 0.074) / placement.size
            output.quad(placement, Rect((1 - size.x) / 2, (1 - size.y) / 2, size.x, size.y), .ring(progress))
        }
        for (ray, distance, pressed) in workspace.beams {
            let end = ray.point(at: max(0.07, distance - 0.006))
            output.quads.append(DrawQuad(model: beam(from: ray.point(at: 0.055), to: end),
                                         material: .fill([0.82, 0.85, 0.9, pressed ? 0.85 : 0.53])))
            let yaw = atan2(-ray.direction.x, -ray.direction.z)
            let dot = Placement(center: end, yaw: yaw, size: Vec2(repeating: pressed ? 0.011 : 0.007))
            output.quad(dot, .full, .fill([0.95, 0.95, 0.97, 1]))
        }
        return output
    }

    private func drawOpening(_ bounds: Rect, age: Double, on panel: Panel, output: inout RenderFrame) {
        let line = Float(clamp(age / 0.045, 0, 1))
        let expand = Float(clamp((age - 0.045) / 0.050, 0, 1))
        let stroke = Vec2(repeating: 0.0025) / panel.placement.size
        let size = stroke + (bounds.size - stroke) * Vec2(line, expand)
        let origin = bounds.origin + (bounds.size - size) / 2
        let white: Float = age < 0.095 ? 0.345 : 1
        output.quad(panel.placement, Rect(origin.x, origin.y, size.x, size.y), .fill([white, white, white, 1]))
    }

    private func drawOutline(_ bounds: Rect, scale: Float, on panel: Panel, output: inout RenderFrame) {
        let size = bounds.size * scale
        let metres = size * panel.placement.size
        guard min(metres.x, metres.y) > 0.005 else { return }
        let origin = bounds.origin + (bounds.size - size) / 2
        output.outline(Rect(origin.x, origin.y, size.x, size.y), on: panel.placement, color: [0.87, 0.87, 0.87, 1])
    }

    private func beam(from start: Vec3, to end: Vec3) -> simd_float4x4 {
        let segment = end - start
        let width = simd_cross(segment, Vec3(0, 1, 0))
        let side: Vec3 = simd_length_squared(width) > 0.000001 ? simd_normalize(width) : [1, 0, 0]
        return simd_float4x4(columns: (Vec4(side * 0.0017, 0), Vec4(segment, 0), [0, 0, 1, 0],
                                      Vec4((start + end) * 0.5, 1)))
    }

    private func drawButtons(_ buttons: [Button], on panel: Panel, opacity: Float = 1, output: inout RenderFrame) {
        for button in buttons {
            let pixels = Canvas.pixels(for: button.rect.size)
            let style = ButtonStyle(label: button.label, pixels: pixels, active: button.active,
                                    hovered: panel.hovered.contains(button.action))
            if buttonTextures[style] == nil {
                buttonTextures[style] = Canvas.texture(device: device, pixels: pixels) { canvas in
                    let loop = button.action == .loopStart || button.action == .loopEnd
                    if style.hovered || (style.active && !loop) {
                        canvas.fill(.full, white: style.hovered ? 0.255 : 0.188, rounded: true)
                    }
                    if loop && style.active { canvas.outlineButton() }
                    if !canvas.playbackIcon(button.label) {
                        canvas.text(button.label, in: .full, size: loop ? 21 : 25, centered: true)
                    }
                }
            }
            if let texture = buttonTextures[style] {
                output.quad(panel.placement, button.rect.normalized(in: panel.placement.size),
                            .texture(texture, opacity: opacity), offset: 0.003)
            }
        }
    }

    private func drawLabel(_ value: String, slot: PanelLabel, in rect: Rect, on panel: Panel, size: CGFloat,
                           white: CGFloat = 0.93, centered: Bool = false, output: inout RenderFrame) {
        let pixels = Canvas.pixels(for: rect.size)
        guard pixels.x >= Int(size), pixels.y > 0 else { return }
        let cached = panel.labelTextures[slot]
        if cached?.value != value || cached?.pixels != pixels {
            panel.labelTextures[slot] = Canvas.texture(device: device, pixels: pixels) {
                $0.text(value, in: .full, size: size, white: white, centered: centered)
            }.map { LabelTexture(value: value, pixels: pixels, texture: $0) }
        }
        if let label = panel.labelTextures[slot] {
            output.quad(panel.placement, rect.normalized(in: panel.placement.size), .texture(label.texture),
                        offset: 0.003)
        }
    }

    private func prepareBrowser(_ panel: Panel, root: URL, output: inout RenderFrame) {
        let ui = panel.ui
        output.quad(panel.placement, .full, .fill(PanelUI.background))
        drawButtons(panel.browserButtons(), on: panel, output: &output)
        let atRoot = panel.directory == root
        let path = atRoot ? root.lastPathComponent :
            panel.directory.pathComponents.dropFirst(root.pathComponents.count).joined(separator: " / ")
        drawLabel(path.isEmpty ? "/" : path, slot: .title, in: ui.title,
                  on: panel, size: 28, output: &output)
        let visible = panel.visibleEntries
        if visible.isEmpty || panel.listingError != nil {
            let message = panel.listingError ?? (panel.loading ? "Loading…" : "No media in this folder")
            drawLabel(message, slot: .message, in: ui.message, on: panel, size: 29, centered: true, output: &output)
        }
        for (index, entry) in visible.enumerated() {
            let hovered = panel.hovered.contains(.entry(visible.startIndex + index))
            if cardBackgrounds[hovered] == nil {
                cardBackgrounds[hovered] = Canvas.texture(device: device, pixels: Canvas.pixels(for: PanelUI.cardSize)) {
                    $0.fill(.full, white: hovered ? 0.255 : 0.161, rounded: true)
                }
            }
            if let background = cardBackgrounds[hovered] {
                output.quad(panel.placement, ui.card(index).normalized(in: ui.size), .texture(background), offset: 0.001)
            }
            if panel.cardTextures[entry.url] == nil {
                panel.cardTextures[entry.url] = makeCard(entry, thumbnail: panel.thumbnails[entry.url])
            }
            if let texture = panel.cardTextures[entry.url] {
                output.quad(panel.placement, ui.card(index).normalized(in: ui.size), .texture(texture), offset: 0.002)
            }
        }
        if panel.pageCount > 1 {
            drawLabel("\(panel.page + 1) / \(panel.pageCount)", slot: .pageNumber, in: ui.pageNumber, on: panel,
                      size: 24, white: 0.73, output: &output)
        }
    }

    private func makeCard(_ entry: MediaEntry, thumbnail: CGImage?) -> MTLTexture? {
        let size = PanelUI.cardSize
        return Canvas.texture(device: device, pixels: Canvas.pixels(for: size)) { canvas in
            let preview = Rect(0.012, 0.009, size.x - 0.024, 0.1465).normalized(in: size)
            if let thumbnail {
                canvas.thumbnail(thumbnail, in: preview)
            } else if entry.kind == .folder {
                canvas.folder(in: preview)
            } else if entry.kind == .audio {
                canvas.text("♪", in: preview, size: 46, white: 0.74, centered: true)
            } else {
                canvas.fill(preview, white: 0.16, rounded: true)
                canvas.text(entry.kind.rawValue.capitalized, in: preview, size: 24, white: 0.71, centered: true)
            }
            let label = Rect(0.015, 0.165, size.x - 0.03, 0.035)
            canvas.text(entry.name, in: label.normalized(in: size), size: 23)
        }
    }

    private func prepareMedia(_ panel: Panel, isPanorama: Bool, time: Double, output: inout RenderFrame) {
        guard let entry = panel.entry else { return }
        let ui = panel.ui
        let playback = panel.playback
        if let frame = playback?.frame, let playback {
            if isPanorama {
                output.outline(.full, on: panel.placement, color: [0.93, 0.93, 0.93, 0.35])
            } else {
                output.quad(panel.placement, .full, .video(frame, playback.videoUV.cropped(to: panel.mediaCrop)))
            }
        } else if let texture = panel.image {
            output.quad(panel.placement, .full, .fill([0.07, 0.07, 0.07, 1]))
            output.quad(panel.placement, .full, .texture(texture, panel.mediaCrop), offset: 0.0005)
        } else {
            let status: String
            if playback?.failed == true || panel.imageFailed { status = "Could not open this file" }
            else if playback?.videoUnavailable == true { status = "Could not decode video" }
            else if entry.kind == .audio { status = entry.name }
            else { status = "Loading…" }
            output.quad(panel.placement, .full, .fill(PanelUI.background))
            drawLabel(status, slot: .message, in: ui.message, on: panel, size: 29, centered: true, output: &output)
        }
        if panel.gripOpacity > 0 {
            let opacity = panel.gripOpacity * (panel.backHighlighted ? 1 : 0.25)
            drawButtons([ui.back], on: panel, opacity: opacity, output: &output)
        }
        guard let start = panel.transportChanged, let playback else { return }
        let age = time - start
        let bounds = ui.transport.normalized(in: ui.size)
        if !panel.controls {
            if age < Panel.outlineDuration {
                drawOutline(bounds, scale: 1 - Float(age / Panel.outlineDuration), on: panel, output: &output)
            }
        } else if age < Panel.openingDuration {
            drawOpening(bounds, age: age, on: panel, output: &output)
        } else {
            prepareTransport(panel, playback: playback, video: panel.canShowPanorama,
                             panorama: isPanorama, output: &output)
        }
    }

    private func prepareTransport(_ panel: Panel, playback: Playback, video: Bool, panorama: Bool,
                                  output: inout RenderFrame) {
        let ui = panel.ui
        let time = clockText(playback.time), duration = clockText(playback.duration)
        output.quad(panel.placement, ui.transport.normalized(in: ui.size), .fill(PanelUI.background), offset: 0.002)
        drawButtons(ui.playbackButtons(playback, video: video, panorama: panorama), on: panel, output: &output)
        drawLabel("\(time) / \(duration)", slot: .playbackTime, in: ui.playbackTime(video: video), on: panel,
                  size: 21, white: 0.74, output: &output)

        let seek = ui.seek
        let y = seek.origin.y + seek.size.y * 0.5
        let track = Rect(seek.origin.x, y - 0.001, seek.size.x, 0.002)
        output.quad(panel.placement, track.normalized(in: ui.size), .fill([0.35, 0.35, 0.35, 1]), offset: 0.003)
        guard playback.duration > 0 else { return }
        let progress = Float(clamp(playback.time / playback.duration, 0, 1)) * seek.size.x
        let elapsed = Rect(seek.origin.x, track.origin.y, progress, track.size.y)
        output.quad(panel.placement, elapsed.normalized(in: ui.size), .fill([0.82, 0.82, 0.82, 1]), offset: 0.0032)
        for marker in [playback.loopStart > 0 ? playback.loopStart : nil, playback.loopEnd].compactMap({ $0 }) {
            let x = seek.origin.x + seek.size.x * Float(clamp(marker / playback.duration, 0, 1))
            let mark = Rect(x - 0.002, y - 0.012, 0.004, 0.024)
            output.quad(panel.placement, mark.normalized(in: ui.size), .fill([0.93, 0.93, 0.93, 1]), offset: 0.0035)
        }
        let knob = Rect(seek.origin.x + progress - 0.007, y - 0.007, 0.014, 0.014)
        output.quad(panel.placement, knob.normalized(in: ui.size), .ring(1), offset: 0.004)

    }

    func encode(_ frame: RenderFrame, into command: MTLCommandBuffer, color: MTLTexture, depth: MTLTexture,
                multisampleColor: MTLTexture?, view: XrView, eye: Int) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = multisampleColor ?? color
        pass.colorAttachments[0].loadAction = .clear
        if multisampleColor != nil {
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw MiruError("Could not create a Metal render encoder")
        }
        if let (frame, uv, yaw) = frame.panorama {
            encoder.setRenderPipelineState(panoramic)
            encoder.setDepthStencilState(backgroundDepth)
            // Sample directions about the current eye, with the panorama yaw fixed in the room.
            let orientation = simd_quatf(angle: -yaw, axis: Vec3(0, 1, 0)) * view.pose.orientation.rotation
            // Keep bilinear luma and chroma samples in their own eye's half.
            let horizontal = abs(uv.u.x) > 0.5 ? frame.chroma.width : frame.chroma.height
            let inset = min(0.25, 0.5 / Float(horizontal))
            let start = Float(eye) * 0.5
            var camera = PanoramaCamera(eyeToPanorama: simd_float4x4(orientation), fov: view.fov.tangents,
                                        eyeUV: [start + inset, start + 0.5 - inset, start, 0])
            encoder.setVertexBytes(&camera, length: MemoryLayout<PanoramaCamera>.stride, index: 0)
            encoder.setFragmentBytes(&camera, length: MemoryLayout<PanoramaCamera>.stride, index: 1)
            bind(frame, uv: uv, to: encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.setDepthStencilState(self.depth)
        let camera = view.fov.projection * simd_inverse(view.pose.matrix)
        var activePipeline: MTLRenderPipelineState?
        for quad in frame.quads {
            var mvp = camera * quad.model
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 0)
            let pipeline: MTLRenderPipelineState
            switch quad.material {
            case .fill(var color):
                pipeline = solid
                encoder.setFragmentBytes(&color, length: MemoryLayout<Vec4>.stride, index: 0)
            case .ring(var progress):
                pipeline = ring
                encoder.setFragmentBytes(&progress, length: MemoryLayout<Float>.stride, index: 0)
            case .texture(let texture, let crop, var opacity):
                pipeline = image
                var coords = Vec4(crop.origin.x, crop.origin.y, crop.size.x, crop.size.y)
                encoder.setFragmentBytes(&coords, length: MemoryLayout<Vec4>.stride, index: 0)
                encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
            case .video(let frame, let uv):
                pipeline = video
                bind(frame, uv: uv, to: encoder)
            }
            if activePipeline !== pipeline {
                encoder.setRenderPipelineState(pipeline)
                activePipeline = pipeline
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    private func bind(_ frame: VideoFrame, uv: VideoUV, to encoder: MTLRenderCommandEncoder) {
        var params = VideoParameters(conversion: frame.conversion, u: uv.u, v: uv.v)
        encoder.setFragmentBytes(&params, length: MemoryLayout<VideoParameters>.stride, index: 0)
        encoder.setFragmentTexture(frame.luma, index: 0)
        encoder.setFragmentTexture(frame.chroma, index: 1)
    }
}
