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

// Layout dimensions use meters in panel-local coordinates, measured from the top left.
struct PanelUI {
    static let browserMinimum: Vec2 = [0.36, 0.415]
    static let mediaMinimum: Vec2 = [0.32, 0.26]
    static let cardSize: Vec2 = [0.307, 0.2145]
    static let margin: Float = 0.025
    static let background: Vec4 = [0.14, 0.14, 0.14, 1]

    private static let cardStep = cardSize + Vec2(0.014, 0.0132)
    private static let gridTop: Float = 0.112
    private static let footerHeight: Float = 0.068

    let size: Vec2

    var columns: Int {
        1 + Int(max(0, size.x - 2 * Self.margin - Self.cardSize.x) / Self.cardStep.x)
    }

    var pageSize: Int {
        let room = size.y - Self.gridTop - Self.footerHeight - Self.cardSize.y
        return columns * (1 + Int(max(0, room) / Self.cardStep.y))
    }

    func card(_ index: Int) -> Rect {
        Rect(Self.margin + Float(index % columns) * Self.cardStep.x,
             Self.gridTop + Float(index / columns) * Self.cardStep.y, Self.cardSize.x, Self.cardSize.y)
    }

    func cardIndex(at point: Vec2) -> Int? {
        let origin = Vec2(Self.margin, Self.gridTop)
        guard point.x >= origin.x, point.y >= origin.y else { return nil }
        let cell = (point - origin) / Self.cardStep
        let column = Int(cell.x), row = Int(cell.y)
        guard column < columns else { return nil }
        let index = row * columns + column
        return index < pageSize && card(index).contains(point) ? index : nil
    }

    var header: Rect { Rect(0, 0, size.x, 0.092) }
    var divider: Rect { Rect(Self.margin, 0.089, size.x - 2 * Self.margin, 0.0015) }
    var back: Button {
        Button(action: .back, rect: Rect(Self.margin, 0.017, 0.12, 0.058), label: "Back")
    }
    var up: Button {
        Button(action: .up, rect: Rect(Self.margin, 0.017, 0.08, 0.058), label: "Up")
    }
    var close: Button {
        Button(action: .close, rect: Rect(size.x - Self.margin - 0.12, 0.017, 0.12, 0.058), label: "Close")
    }
    var exit: Button {
        Button(action: .exit, rect: Rect(close.rect.origin.x - 0.118, 0.017, 0.108, 0.058), label: "Exit VR")
    }

    func title(browser: Bool, atRoot: Bool) -> Rect {
        let left = browser ? (atRoot ? Self.margin : up.rect.origin.x + up.rect.size.x + 0.012)
                           : back.rect.origin.x + back.rect.size.x + 0.012
        let right = (browser ? exit : close).rect.origin.x - 0.012
        return Rect(left, 0.017, max(0, right - left), 0.058)
    }

    var next: Button {
        Button(action: .next, rect: Rect(size.x - Self.margin - 0.105, size.y - 0.061, 0.105, 0.043), label: "Next")
    }
    var previous: Button {
        Button(action: .previous, rect: Rect(next.rect.origin.x - 0.122, size.y - 0.061, 0.112, 0.043),
               label: "Previous")
    }
    var pageNumber: Rect {
        Rect(Self.margin, next.rect.origin.y, previous.rect.origin.x - Self.margin - 0.008, next.rect.size.y)
    }
    var message: Rect {
        Rect(Self.margin, (size.y - 0.06) / 2, size.x - 2 * Self.margin, 0.06)
    }

    private var compactTransport: Bool { size.x < 0.53 }
    var transport: Rect {
        let height: Float = compactTransport ? 0.162 : 0.107
        return Rect(0, size.y - height, size.x, height)
    }
    var seek: Rect {
        Rect(Self.margin, transport.origin.y + 0.008, size.x - 2 * Self.margin - 0.161, 0.035)
    }
    var playbackTime: Rect {
        Rect(size.x - Self.margin - 0.15, seek.origin.y, 0.15, seek.size.y)
    }

    func playbackButtons(_ playback: Playback, video: Bool, panorama: Bool) -> [Button] {
        let firstRow = transport.origin.y + 0.046
        let secondRow = compactTransport ? firstRow + 0.055 : firstRow
        let loopX: Float = compactTransport ? Self.margin : Self.margin + 0.24
        var buttons = [
            Button(action: .play, rect: Rect(Self.margin, firstRow, 0.105, 0.05),
                   label: playback.paused ? "Play" : "Pause"),
            Button(action: .mute, rect: Rect(Self.margin + 0.115, firstRow, 0.115, 0.05),
                   label: playback.muted ? "Unmute" : "Mute"),
            Button(action: .loopStart, rect: Rect(loopX, secondRow, 0.045, 0.05),
                   label: "A", active: playback.loopStart > 0),
            Button(action: .loopEnd, rect: Rect(loopX + 0.055, secondRow, 0.045, 0.05),
                   label: "B", active: playback.loopEnd != nil)
        ]
        if video {
            buttons.append(Button(action: .panorama, rect: Rect(loopX + 0.11, secondRow, 0.125, 0.05),
                                  label: "180° SBS", active: panorama))
        }
        return buttons
    }
}

enum PanelLabel {
    case title, message, pageNumber, playbackTime
}

struct LabelTexture {
    let value: String
    let pixels: SIMD2<Int>
    let texture: MTLTexture
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
    static func pixels(for size: Vec2) -> SIMD2<Int> {
        SIMD2(Int((size.x * 960).rounded()), Int((size.y * 960).rounded()))
    }

    static func texture(
        device: MTLDevice, pixels: SIMD2<Int>, draw: (Canvas) -> Void
    ) -> MTLTexture? {
        let width = pixels.x, height = pixels.y
        return makeTexture(width: width, height: height, device: device) { context in
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
