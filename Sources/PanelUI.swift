import CoreGraphics
import CoreText
import Foundation
import Metal

enum PanelAction: Equatable {
    case back, close, exit, previous, next, entry(Int)
    case media, play, mute, loopStart, loopEnd, panorama, seek
    case move(Vec2), resize(Vec2)
}

struct Button {
    let action: PanelAction
    let rect: Rect
    let label: String
    var active = false
}

// Layout dimensions use meters in panel-local coordinates, measured from the top left.
struct PanelUI {
    static let minimumSize: Vec2 = [0.32, 0.26]
    static let cardSize: Vec2 = [0.22, 0.22]
    static let margin: Float = 0.025
    static let background: Vec4 = [0.14, 0.14, 0.14, 1]

    private var displayedCardSize: Vec2 {
        Vec2(repeating: min(Self.cardSize.y, size.y - Self.gridTop - Self.footerHeight))
    }
    private var cardStep: Vec2 { displayedCardSize + Vec2(0.014, 0.0132) }
    private static let gridTop: Float = 0.112
    private static let footerHeight: Float = 0.068

    let size: Vec2

    static let gripReach: Float = 0.055
    private static let cornerLength: Float = 0.05

    func grip(at point: Vec2) -> PanelAction? {
        let centered = point - size / 2
        let dx = abs(centered.x) - size.x / 2
        let dy = abs(centered.y) - size.y / 2
        guard max(dx, dy) <= Self.gripReach, max(dx, dy) >= -0.016 else { return nil }
        let x: Float = dx >= -Self.cornerLength ? (centered.x < 0 ? -1 : 1) : 0
        let y: Float = dy >= -Self.cornerLength ? (centered.y < 0 ? 1 : -1) : 0
        let side = Vec2(x, y)
        return x != 0 && y != 0 ? .resize(side) : .move(side)
    }

    func gripRects(_ side: Vec2) -> [Rect] {
        let offset: Float = 0.022, stroke: Float = 0.0028
        let corner = Self.cornerLength + offset - 0.009
        let x = side.x < 0 ? -offset : size.x + offset - stroke
        let y = side.y > 0 ? -offset : size.y + offset - stroke
        if side.x == 0 {
            return [Rect(Self.cornerLength, y, size.x - 2 * Self.cornerLength, stroke)]
        }
        if side.y == 0 {
            return [Rect(x, Self.cornerLength, stroke, size.y - 2 * Self.cornerLength)]
        }
        return [Rect(side.x < 0 ? x : x + stroke - corner, y, corner, stroke),
                Rect(x, side.y > 0 ? y + stroke : y + stroke - corner, stroke, corner - stroke)]
    }

    var columns: Int {
        1 + Int(max(0, size.x - 2 * Self.margin - displayedCardSize.x) / cardStep.x)
    }

    var pageSize: Int {
        let room = size.y - Self.gridTop - Self.footerHeight - displayedCardSize.y
        return columns * (1 + Int(max(0, room) / cardStep.y))
    }

    func card(_ index: Int) -> Rect {
        Rect(Self.margin + Float(index % columns) * cardStep.x,
             Self.gridTop + Float(index / columns) * cardStep.y, displayedCardSize.x, displayedCardSize.y)
    }

    func cardIndex(at point: Vec2) -> Int? {
        let origin = Vec2(Self.margin, Self.gridTop)
        guard point.x >= origin.x, point.y >= origin.y else { return nil }
        let cell = (point - origin) / cardStep
        let column = Int(cell.x), row = Int(cell.y)
        guard column < columns else { return nil }
        let index = row * columns + column
        return index < pageSize && card(index).contains(point) ? index : nil
    }

    var back: Button {
        Button(action: .back, rect: Rect(0.03, 0.03, 0.15, 0.068), label: "← Back")
    }
    var close: Button {
        Button(action: .close, rect: Rect(size.x - Self.margin - 0.12, 0.017, 0.12, 0.058), label: "Close")
    }
    var exit: Button {
        Button(action: .exit, rect: Rect(close.rect.origin.x - 0.118, 0.017, 0.108, 0.058), label: "Exit VR")
    }

    var title: Rect {
        Rect(Self.margin, 0.017, max(0, exit.rect.origin.x - Self.margin - 0.012), 0.058)
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

    private var compactTransport: Bool { size.x < 0.69 }
    var transport: Rect {
        Rect(0, size.y + Self.gripReach + 0.006, size.x, compactTransport ? 0.152 : 0.102)
    }
    var seek: Rect {
        Rect(Self.margin, transport.origin.y + 0.005, size.x - 2 * Self.margin, 0.035)
    }
    func playbackTime(video: Bool) -> Rect {
        let right = compactTransport ? size.x - Self.margin : loopStartX(video: video) - 0.012
        return Rect(0.098, transport.origin.y + 0.04, right - 0.098, 0.045)
    }
    private func loopStartX(video: Bool) -> Float {
        let gap: Float = compactTransport ? 0.006 : 0.012
        let loopWidth: Float = compactTransport ? 0.04 : 0.058
        return size.x - Self.margin - (video ? 2 : 1) * (0.056 + gap) - 2 * loopWidth - gap
    }

    func playbackButtons(_ playback: Playback, video: Bool, panorama: Bool) -> [Button] {
        let first = transport.origin.y + 0.04
        let row = compactTransport ? first + 0.052 : first
        let gap: Float = compactTransport ? 0.006 : 0.012
        let width: Float = compactTransport ? 0.04 : 0.058
        let x = loopStartX(video: video)
        let muteX = x + 2 * (width + gap)
        var buttons = [
            Button(action: .play, rect: Rect(0.019, first, 0.064, 0.045), label: playback.paused ? "Play" : "Pause"),
            Button(action: .loopStart, rect: Rect(x, row, width, 0.045), label: "[ A", active: playback.loopStart > 0),
            Button(action: .loopEnd, rect: Rect(x + width + gap, row, width, 0.045), label: "B ]", active: playback.loopEnd != nil),
            Button(action: .mute, rect: Rect(muteX, row, 0.056, 0.045), label: playback.muted ? "Unmute" : "Mute")
        ]
        if video {
            buttons.append(Button(action: .panorama, rect: Rect(muteX + 0.056 + gap, row, 0.056, 0.045),
                                  label: "Panorama", active: panorama))
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
            context.addPath(CGPath(roundedRect: bounds(rect), cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
        } else {
            context.fill(bounds(rect))
        }
    }

    func text(
        _ value: String, in rect: Rect, size: CGFloat, white: CGFloat = 0.93, centered: Bool = false
    ) {
        let box = bounds(rect)
        let font = CTFontCreateWithName("HelveticaNeue-Thin" as CFString, size, nil)
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

    func playbackIcon(_ label: String) -> Bool {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: width / 2, y: height / 2)
        context.setFillColor(gray: 0.93, alpha: 1)
        context.setStrokeColor(gray: 0.93, alpha: 1)
        context.setLineWidth(1.75)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch label {
        case "Play":
            context.move(to: CGPoint(x: -6, y: -9))
            context.addLine(to: CGPoint(x: 9, y: 0))
            context.addLine(to: CGPoint(x: -6, y: 9))
            context.fillPath()
        case "Pause":
            for x in [-8, 3] { context.fill(CGRect(x: x, y: -9, width: 5, height: 18)) }
        case "Mute", "Unmute":
            context.addLines(between: [CGPoint(x: -11, y: 3), CGPoint(x: -7, y: 3), CGPoint(x: -1, y: 8),
                                       CGPoint(x: -1, y: -8), CGPoint(x: -7, y: -3), CGPoint(x: -11, y: -3)])
            context.closePath()
            if label == "Unmute" {
                context.move(to: CGPoint(x: -8, y: 10))
                context.addLine(to: CGPoint(x: 10, y: -10))
            } else {
                for r in [4, 8] {
                    context.move(to: CGPoint(x: r, y: r))
                    context.addQuadCurve(to: CGPoint(x: r, y: -r), control: CGPoint(x: r * 2, y: 0))
                }
            }
            context.strokePath()
        case "Panorama":
            context.addArc(center: CGPoint(x: 0, y: -3), radius: 11, startAngle: 0, endAngle: .pi, clockwise: false)
            context.strokePath()
            context.strokeEllipse(in: CGRect(x: -11, y: -7.5, width: 22, height: 9))
        default: return false
        }
        return true
    }

    func outlineButton() {
        context.setStrokeColor(gray: 0.87, alpha: 1)
        context.setLineWidth(1.5)
        let box = bounds(.full).insetBy(dx: 1, dy: 1)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.strokePath()
    }

    func folder(in rect: Rect) {
        let box = bounds(rect)
        context.saveGState()
        context.translateBy(x: box.midX, y: box.midY)
        context.setStrokeColor(gray: 0.74, alpha: 1)
        context.setLineWidth(1.75)
        context.addLines(between: [CGPoint(x: -30, y: -21), CGPoint(x: -30, y: 23),
                                   CGPoint(x: -8, y: 23), CGPoint(x: 1, y: 15),
                                   CGPoint(x: 30, y: 15), CGPoint(x: 30, y: -21)])
        context.closePath()
        context.strokePath()
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
