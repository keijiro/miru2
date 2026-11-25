import CoreGraphics
import CoreText
import Foundation
import Metal

enum PanelAction: Equatable {
    case back, close, exit, previous, next, up, entry(Int)
    case media, play, mute, loopStart, loopEnd, panorama, seek
    case move, resize(Vec2)
}

struct Button {
    let action: PanelAction
    let rect: Rect
    let label: String
    var active = false
}

enum PanelUI {
    static let header = Rect(0, 0, 1, 0.14)
    static let transport = Rect(0, 0.72, 1, 0.28)
    static let seek = Rect(0.045, 0.745, 0.91, 0.095)
    static let back = Button(action: .back, rect: Rect(0.025, 0.025, 0.13, 0.09), label: "Back")
    static let close = Button(action: .close, rect: Rect(0.85, 0.025, 0.125, 0.09), label: "Close")
    static let exit = Button(action: .exit, rect: Rect(0.71, 0.025, 0.125, 0.09), label: "Exit VR")
    static let up = Button(action: .up, rect: Rect(0.025, 0.025, 0.13, 0.09), label: "Up")
    static let previous = Button(action: .previous, rect: Rect(0.61, 0.88, 0.17, 0.085), label: "Previous")
    static let next = Button(action: .next, rect: Rect(0.8, 0.88, 0.175, 0.085), label: "Next")
    static let pageSize = 6

    static func card(_ index: Int) -> Rect {
        Rect(0.025 + Float(index % 3) * 0.321, 0.17 + Float(index / 3) * 0.345, 0.307, 0.325)
    }

    static func playbackButtons(_ playback: Playback, video: Bool, panorama: Bool) -> [Button] {
        var buttons = [
            Button(action: .play, rect: Rect(0.025, 0.865, 0.14, 0.105), label: playback.paused ? "Play" : "Pause"),
            Button(action: .mute, rect: Rect(0.18, 0.865, 0.16, 0.105), label: playback.muted ? "Unmute" : "Mute"),
            Button(action: .loopStart, rect: Rect(0.55, 0.865, 0.105, 0.105), label: "A", active: playback.loopStart > 0),
            Button(action: .loopEnd, rect: Rect(0.67, 0.865, 0.105, 0.105), label: "B", active: playback.loopEnd != nil)
        ]
        if video {
            buttons.append(Button(action: .panorama, rect: Rect(0.79, 0.865, 0.185, 0.105),
                                  label: "180° SBS", active: panorama))
        }
        return buttons
    }
}

func makeTexture(
    width: Int, height: Int, device: MTLDevice, draw: (CGContext) -> Void
) -> MTLTexture? {
    guard let color = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: color,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let pixels = context.data else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
    )
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    draw(context)
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: context.bytesPerRow)
    return texture
}

struct Canvas {
    private let context: CGContext
    private let width: CGFloat
    private let height: CGFloat
    static let background: CGFloat = 0.14

    static func texture(
        device: MTLDevice, width: Int = 960, height: Int = 620, draw: (Canvas) -> Void
    ) -> MTLTexture? {
        makeTexture(width: width, height: height, device: device) { context in
            draw(Canvas(context: context, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private func bounds(_ rect: Rect) -> CGRect {
        CGRect(x: CGFloat(rect.origin.x) * width, y: CGFloat(1 - rect.origin.y - rect.size.y) * height,
               width: CGFloat(rect.size.x) * width, height: CGFloat(rect.size.y) * height)
    }

    func fill(_ rect: Rect, white: CGFloat, rounded: Bool = false) {
        context.setFillColor(red: white, green: white, blue: white, alpha: 1)
        if rounded {
            context.addPath(CGPath(roundedRect: bounds(rect), cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.fillPath()
        } else {
            context.fill(bounds(rect))
        }
    }

    func text(
        _ value: String, in rect: Rect, size: CGFloat, white: CGFloat = 0.93, centered: Bool = false
    ) {
        let box = bounds(rect)
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: white, alpha: 1)
        ] as CFDictionary
        func line(_ string: String) -> CTLine? {
            CFAttributedStringCreate(nil, string as CFString, attributes).map(CTLineCreateWithAttributedString)
        }
        guard let fullLine = line(value), let ellipsis = line("…") else { return }
        let displayed = CTLineCreateTruncatedLine(fullLine, box.width, .end, ellipsis) ?? fullLine
        let length = CTLineGetTypographicBounds(displayed, nil, nil, nil)
        context.saveGState()
        context.clip(to: box)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: centered ? box.midX - length / 2 : box.minX,
                                       y: box.midY - (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2)
        CTLineDraw(displayed, context)
        context.restoreGState()
    }

    func button(_ button: Button, relativeTo parent: Rect = .full) {
        let rect = Rect((button.rect.origin.x - parent.origin.x) / parent.size.x,
                        (button.rect.origin.y - parent.origin.y) / parent.size.y,
                        button.rect.size.x / parent.size.x, button.rect.size.y / parent.size.y)
        fill(rect, white: button.active ? 0.38 : 0.22, rounded: true)
        text(button.label, in: rect, size: 25, centered: true)
    }

    func thumbnail(_ image: CGImage, in rect: Rect) {
        let box = bounds(rect)
        let scale = max(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: box)
        context.draw(image, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                       width: size.width, height: size.height))
        context.restoreGState()
    }
}

func clockText(_ seconds: Double) -> String {
    let time = Int(clamp(seconds.isFinite ? seconds : 0, 0, 359_999))
    if time >= 3600 { return String(format: "%d:%02d:%02d", time / 3600, time / 60 % 60, time % 60) }
    return String(format: "%d:%02d", time / 60, time % 60)
}
