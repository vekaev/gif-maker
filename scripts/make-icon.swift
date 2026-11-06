// Draws the GIF Maker app icon (1024×1024 PNG): the same light soft-UI tile and dial as Fuji Recipes (and the tile of
// Photo Minimalist, DayGate, Meeting Memo). The dial's position reads GIF, and its dots fade round it like a loop's frames.
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
ctx.addPath(tilePath); ctx.setFillColor(rgb(240, 240, 237)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(250, 250, 248), rgb(228, 228, 224)]), start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

/// The mark: a dial seen from above, knurled edge, GIF filled black under the index, the frames of a loop trailing behind it.
func drawMark() {
    let R = 300 * k, face = 236 * k
    func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil) }
    // The dial body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 40 * k, color: rgb(0, 0, 0, 0.22))
    ctx.addPath(circle(R)); ctx.setFillColor(rgb(236, 236, 233)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(circle(R)); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(252, 252, 250), rgb(214, 214, 210)]), start: CGPoint(x: 0, y: center.y + R), end: CGPoint(x: 0, y: center.y - R), options: [])
    ctx.restoreGState()
    // Knurling around the edge.
    ctx.setStrokeColor(rgb(150, 150, 146, 0.55)); ctx.setLineWidth(3 * k)
    for i in 0..<90 {
        let a = CGFloat(i) / 90 * 2 * .pi
        ctx.move(to: CGPoint(x: center.x + cos(a) * (R - 4 * k), y: center.y + sin(a) * (R - 4 * k)))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * (R - 30 * k), y: center.y + sin(a) * (R - 30 * k)))
    }
    ctx.strokePath()
    // The face.
    ctx.saveGState(); ctx.addPath(circle(face)); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(236, 236, 233), rgb(250, 250, 248)]), start: CGPoint(x: 0, y: center.y + face), end: CGPoint(x: 0, y: center.y - face), options: [])
    ctx.restoreGState()
    ctx.addPath(circle(face)); ctx.setStrokeColor(rgb(0, 0, 0, 0.08)); ctx.setLineWidth(3 * k); ctx.strokePath()
    // Frames round the dial, counter-clockwise from the top: the newest is biggest and darkest, like a loop going round.
    let positions = 12
    for i in 2...(positions - 2) {   // the two beside the disc would hide under it
        let a = .pi / 2 + CGFloat(i) / CGFloat(positions) * 2 * .pi
        let p = CGPoint(x: center.x + cos(a) * 158 * k, y: center.y + sin(a) * 158 * k)
        let f = 1 - CGFloat(i - 2) / CGFloat(positions - 4)            // 1 next to GIF, 0 at the far end
        let r = (8 + 11 * f) * k
        ctx.addPath(circle(r).copy(using: [CGAffineTransform(translationX: p.x - center.x, y: p.y - center.y)])!)
        ctx.setFillColor(rgb(120 - 70 * f, 120 - 70 * f, 116 - 68 * f, 0.45 + 0.55 * f)); ctx.fillPath()
    }
    let top = CGPoint(x: center.x, y: center.y + 158 * k)
    let disc = 78 * k
    ctx.addPath(CGPath(ellipseIn: CGRect(x: top.x - disc, y: top.y - disc, width: 2 * disc, height: 2 * disc), transform: nil))
    ctx.setFillColor(rgb(24, 24, 26)); ctx.fillPath()
    let font = NSFont.systemFont(ofSize: 62 * k, weight: .bold)
    let c = NSAttributedString(string: "GIF", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -1.5 * k])
    let sz = c.size()
    c.draw(at: CGPoint(x: top.x - sz.width / 2, y: top.y - sz.height / 2 + 1 * k))
    // The index above the dial.
    ctx.move(to: CGPoint(x: center.x - 26 * k, y: center.y + R + 52 * k))
    ctx.addLine(to: CGPoint(x: center.x + 26 * k, y: center.y + R + 52 * k))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + R + 16 * k))
    ctx.closePath(); ctx.setFillColor(rgb(24, 24, 26)); ctx.fillPath()
}
drawMark()

// Fine grain, like brushed paper.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<22000 {
    ctx.setFillColor(rnd() > 0.5 ? rgb(255, 255, 255, 0.05) : rgb(0, 0, 0, 0.018))
    ctx.fill(CGRect(x: tile.minX + rnd() * tile.width, y: tile.minY + rnd() * tile.height, width: 2, height: 2))
}
ctx.restoreGState()
if !iOS { ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0, 0, 0, 0.10)); ctx.setLineWidth(3); ctx.strokePath() }

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
