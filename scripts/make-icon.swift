// Draws the GIF Maker app icon (1024×1024 PNG): a graphite tile with a crop frame around a play triangle.
// Run: swift scripts/make-icon.swift AppIcon-1024.png [ios]
//      ios: full-bleed square (the system rounds it); default is the macOS rounded tile with shadow.
import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "AppIcon-1024.png"
let iOS = args.contains("ios")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) })!
}

// macOS icon grid: ~824pt rounded square centered on a 1024 canvas.
let inset: CGFloat = iOS ? 0 : 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = iOS ? 0 : 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
let k = tile.width / 824
let center = CGPoint(x: size / 2, y: size / 2)

ctx.saveGState()
if !iOS { ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0, 0, 0, 0.28)) }
ctx.addPath(tilePath); ctx.setFillColor(rgb(26, 26, 28)); ctx.fillPath()
ctx.restoreGState()

/// The app's mark: a white crop frame around a play triangle in the trim handles' yellow.
func drawMark() {
    let half = 290 * k, arm = 150 * k, line = 46 * k
    ctx.saveGState()
    ctx.setStrokeColor(rgb(255, 255, 255)); ctx.setLineWidth(line); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] as [(CGFloat, CGFloat)] {
        let c = CGPoint(x: center.x + sx * half, y: center.y + sy * half)
        ctx.move(to: CGPoint(x: c.x, y: c.y - sy * arm))
        ctx.addLine(to: c)
        ctx.addLine(to: CGPoint(x: c.x - sx * arm, y: c.y))
        ctx.strokePath()
    }
    ctx.restoreGState()
    let w = 150 * k, h = 172 * k, x = center.x + 18 * k
    let play = CGMutablePath()
    play.move(to: CGPoint(x: x - w, y: center.y + h))
    play.addLine(to: CGPoint(x: x + w, y: center.y))
    play.addLine(to: CGPoint(x: x - w, y: center.y - h))
    play.closeSubpath()
    ctx.saveGState()
    ctx.addPath(play); ctx.setLineWidth(44 * k); ctx.setLineJoin(.round); ctx.replacePathWithStrokedPath()
    ctx.addPath(play); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(255, 214, 64), rgb(245, 150, 30)]), start: CGPoint(x: 0, y: center.y + h + 22 * k), end: CGPoint(x: 0, y: center.y - h - 22 * k), options: [])
    ctx.restoreGState()
}
drawMark()

// Fine grain, like brushed paper.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<22000 {
    ctx.setFillColor(rnd() > 0.5 ? rgb(255, 255, 255, 0.05) : rgb(0, 0, 0, 0.03))
    ctx.fill(CGRect(x: tile.minX + rnd() * tile.width, y: tile.minY + rnd() * tile.height, width: 2, height: 2))
}
ctx.restoreGState()
if !iOS { ctx.addPath(tilePath); ctx.setStrokeColor(rgb(58, 58, 62)); ctx.setLineWidth(3); ctx.strokePath() }

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
