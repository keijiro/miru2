import COpenXR
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
    case texture(MTLTexture, Rect = .full)
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

final class Renderer {
    private let device: MTLDevice
    private let solid: MTLRenderPipelineState
    private let image: MTLRenderPipelineState
    private let video: MTLRenderPipelineState
    private let panoramic: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let backgroundDepth: MTLDepthStencilState

    init(device: MTLDevice, format: MTLPixelFormat, shaders: URL) throws {
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
            let hovered = workspace.hoveredActions(panel)
            if panel.browser {
                prepareBrowser(panel, root: workspace.root, output: &output)
            } else {
                prepareMedia(panel, header: workspace.showsHeader(panel), isPanorama: panorama === panel,
                             output: &output)
            }
            for action in hovered {
                if case .move = action {
                    output.outline(.full, on: panel.placement, color: [0.93, 0.93, 0.93, 0.82])
                } else if case .resize(let side) = action {
                    let corner = (side * Vec2(1, -1) + Vec2(repeating: 1)) * 0.5
                    let size = Vec2(repeating: 0.052) / panel.placement.size
                    let origin = corner * (Vec2(repeating: 1) - size)
                    output.outline(Rect(origin.x, origin.y, size.x, size.y), on: panel.placement,
                                   color: [0.93, 0.93, 0.93, 0.96])
                } else if let button = panel.buttons(root: workspace.root, transportVisible: panel.controls,
                                                     panorama: workspace.panorama === panel).first(where: { $0.action == action }) {
                    output.outline(button.rect, on: panel.placement, color: [0.9, 0.9, 0.9, 0.8])
                }
            }
        }
        for (placement, progress) in workspace.previews {
            output.outline(.full, on: placement, color: [0.89, 0.89, 0.89, 0.35 + progress * 0.55])
            output.quad(placement, Rect(0.03, 0.94, progress * 0.94, 0.006), .fill([0.92, 0.92, 0.92, 0.9]))
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

    private func beam(from start: Vec3, to end: Vec3) -> simd_float4x4 {
        let segment = end - start
        let width = simd_cross(segment, Vec3(0, 1, 0))
        let side: Vec3 = simd_length_squared(width) > 0.000001 ? simd_normalize(width) : [1, 0, 0]
        return simd_float4x4(columns: (Vec4(side * 0.0017, 0), Vec4(segment, 0), [0, 0, 1, 0],
                                      Vec4((start + end) * 0.5, 1)))
    }

    private func prepareBrowser(_ panel: Panel, root: URL, output: inout RenderFrame) {
        let key = "browser:\(panel.revision)"
        if panel.chromeKey != key {
            panel.chromeKey = key
            let buttons = panel.buttons(root: root, transportVisible: false, panorama: false)
            panel.chrome = Canvas.texture(device: device) { canvas in
                canvas.fill(.full, white: Canvas.background)
                for button in buttons where !button.label.isEmpty { canvas.button(button) }
                let path = panel.directory == root ? root.lastPathComponent :
                    panel.directory.pathComponents.dropFirst(root.pathComponents.count).joined(separator: " / ")
                let start: Float = panel.directory == root ? 0.035 : 0.17
                canvas.text(path.isEmpty ? "/" : path, in: Rect(start, 0.027, 0.69 - start, 0.088), size: 29)
                canvas.fill(Rect(0.025, 0.135, 0.95, 0.002), white: 0.30)
                if let error = panel.listingError {
                    canvas.text(error, in: Rect(0.045, 0.34, 0.91, 0.13), size: 29)
                } else if panel.visibleEntries.isEmpty {
                    let message = panel.loading ? "Loading…" : "No media in this folder"
                    canvas.text(message, in: Rect(0.045, 0.35, 0.91, 0.12), size: 30, centered: true)
                }
                for (index, entry) in panel.visibleEntries.enumerated() {
                    let card = PanelUI.card(index)
                    canvas.fill(card, white: 0.19, rounded: true)
                    let preview = Rect(card.origin.x + 0.012, card.origin.y + 0.014, card.size.x - 0.024, 0.222)
                    if let image = panel.thumbnails[entry.url] {
                        canvas.thumbnail(image, in: preview)
                    } else {
                        canvas.fill(preview, white: 0.16, rounded: true)
                        canvas.text(entry.kind.rawValue.capitalized, in: preview, size: 24, white: 0.71, centered: true)
                    }
                    canvas.text(entry.name, in: Rect(preview.origin.x + 0.003, card.origin.y + 0.25,
                                                    preview.size.x - 0.006, 0.053), size: 23)
                }
                if panel.pageCount > 1 {
                    canvas.text("\(panel.page + 1) / \(panel.pageCount)", in: Rect(0.035, 0.88, 0.42, 0.085),
                                size: 24, white: 0.73)
                }
            }
        }
        if let chrome = panel.chrome { output.quad(panel.placement, .full, .texture(chrome)) }
    }

    private func prepareMedia(_ panel: Panel, header: Bool, isPanorama: Bool, output: inout RenderFrame) {
        guard let entry = panel.entry else { return }
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
            let key = "status:\(panel.revision):\(status)"
            if panel.chromeKey != key {
                panel.chromeKey = key
                panel.chrome = Canvas.texture(device: device, height: 480) { canvas in
                    canvas.fill(.full, white: Canvas.background)
                    canvas.text(status, in: Rect(0.06, 0.31, 0.88, 0.2), size: 34, centered: true)
                }
            }
            if let chrome = panel.chrome { output.quad(panel.placement, .full, .texture(chrome)) }
        }
        if header {
            if panel.headerKey != panel.revision {
                panel.headerKey = panel.revision
                panel.header = Canvas.texture(device: device, height: 100) { canvas in
                    canvas.fill(.full, white: Canvas.background)
                    canvas.button(PanelUI.back, relativeTo: PanelUI.header)
                    canvas.button(PanelUI.close, relativeTo: PanelUI.header)
                    canvas.text(entry.name, in: Rect(0.178, 0, 0.64, 1), size: 28)
                }
            }
            if let header = panel.header {
                output.quad(panel.placement, PanelUI.header, .texture(header), offset: 0.002)
            }
        }
        if panel.controls, let playback {
            prepareTransport(panel, playback: playback, video: panel.canShowPanorama,
                             panorama: isPanorama, output: &output)
        }
    }

    private func prepareTransport(_ panel: Panel, playback: Playback, video: Bool, panorama: Bool,
                                  output: inout RenderFrame) {
        let time = clockText(playback.time)
        let duration = clockText(playback.duration)
        let key = "\(panel.revision):\(time):\(duration):\(playback.paused):\(playback.muted):\(playback.loopStart > 0):\(playback.loopEnd != nil):\(video):\(panorama)"
        if panel.transportKey != key {
            panel.transportKey = key
            panel.transport = Canvas.texture(device: device, height: 180) { canvas in
                canvas.fill(.full, white: Canvas.background)
                for button in PanelUI.playbackButtons(playback, video: video, panorama: panorama) {
                    canvas.button(button, relativeTo: PanelUI.transport)
                }
                canvas.text("\(time) / \(duration)", in: Rect(0.35, 0.51, 0.19, 0.39),
                            size: 23, white: 0.80, centered: true)
            }
        }
        if let transport = panel.transport {
            output.quad(panel.placement, PanelUI.transport, .texture(transport), offset: 0.002)
        }
        let seek = PanelUI.seek
        let y = seek.origin.y + seek.size.y * 0.55
        output.quad(panel.placement, Rect(seek.origin.x, y, seek.size.x, 0.012),
                    .fill([0.35, 0.35, 0.35, 1]), offset: 0.003)
        guard playback.duration > 0 else { return }
        let progress = Float(clamp(playback.time / playback.duration, 0, 1)) * seek.size.x
        output.quad(panel.placement, Rect(seek.origin.x, y, progress, 0.012),
                    .fill([0.82, 0.82, 0.82, 1]), offset: 0.0032)
        for marker in [playback.loopStart > 0 ? playback.loopStart : nil, playback.loopEnd].compactMap({ $0 }) {
            let x = seek.origin.x + seek.size.x * Float(clamp(marker / playback.duration, 0, 1))
            output.quad(panel.placement, Rect(x - 0.002, y - 0.012, 0.004, 0.036),
                        .fill([0.78, 0.85, 0.97, 1]), offset: 0.0035)
        }
    }

    func encode(_ frame: RenderFrame, into command: MTLCommandBuffer, color: MTLTexture, depth: MTLTexture,
                view: XrView, eye: Int) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
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
            case .texture(let texture, let crop):
                pipeline = image
                var coords = Vec4(crop.origin.x, crop.origin.y, crop.size.x, crop.size.y)
                encoder.setFragmentBytes(&coords, length: MemoryLayout<Vec4>.stride, index: 0)
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
