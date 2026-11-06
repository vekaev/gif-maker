import CoreGraphics
import Foundation

// The document model: pure values and maths, no UI, no media frameworks. Same recipes and maths as the web
// version (index.html), so a look or a speed setting means the same thing in both.

/// A look: a black-and-white conversion (a coloured filter in front of the lens) plus a tone curve.
enum Look: String, CaseIterable, Codable, Identifiable {
    case color, mono, silvertone, noir, leica, leicaHC, acros
    var id: String { rawValue }

    struct Recipe {
        var mix: (Double, Double, Double)? = nil
        var exposure = 0.0, black = 0.0, white = 1.0, curve = 0.0
        var tint: (Double, Double, Double) = (0, 0, 0)   // in 0–255 units, strongest in the midtones
    }

    var name: String {
        switch self {
        case .color: "Color"
        case .mono: "iPhone Mono"
        case .silvertone: "iPhone Silvertone"
        case .noir: "iPhone Noir"
        case .leica: "Leica Monochrom"
        case .leicaHC: "Leica High Contrast"
        case .acros: "Fuji Acros"
        }
    }

    /// The part of a file name that says which look it has.
    var slug: String? {
        switch self {
        case .color: nil
        case .mono: "iphone-mono"
        case .silvertone: "iphone-silvertone"
        case .noir: "iphone-noir"
        case .leica: "leica-monochrom"
        case .leicaHC: "leica-high-contrast"
        case .acros: "fuji-acros"
        }
    }

    var recipe: Recipe {
        switch self {
        case .color: Recipe()
        case .mono: Recipe(mix: (0.299, 0.587, 0.114))
        case .silvertone: Recipe(mix: (0.30, 0.59, 0.11), exposure: 0.2, black: 0.02, curve: 0.35, tint: (-5, 0, 7))
        case .noir: Recipe(mix: (0.45, 0.50, 0.05), black: 0.08, white: 0.92, curve: 0.7)
        case .leica: Recipe(mix: (0.33, 0.50, 0.17), black: 0.015, curve: 0.2)
        case .leicaHC: Recipe(mix: (0.30, 0.59, 0.11), black: 0.07, white: 0.93, curve: 0.6)
        case .acros: Recipe(mix: (0.46, 0.48, 0.06), black: 0.03, white: 1.06, curve: 0.3)
        }
    }
}

/// The light and colour sliders. All go both ways from zero, except grain.
struct Adjustments: Equatable, Codable {
    var look: Look = .color
    var exposure = 0.0      // −150…150, hundredths of a stop
    var shadows = 0.0       // −100…100
    var contrast = 0.0      // −100…100
    var saturation = 0.0    // −100…100
    var warmth = 0.0        // −50…50
    var grain = 0.0         // 0…30

    /// The tone curve for one channel, 0…1 in and out.
    func tone(_ input: Double) -> Double {
        let r = look.recipe
        var v = min(1, input * pow(2, exposure / 100 + r.exposure))
        let gamma = shadows >= 0 ? 1 / (1 + shadows / 100) : 1 - shadows / 100
        v = pow(max(0, v), gamma)
        v = (v - 0.5) * (1 + contrast / 100) + 0.5
        v = max(0, min(1, (v - r.black) / (r.white - r.black)))
        if r.curve != 0 { v += r.curve * (v * v * (3 - 2 * v) - v) }
        return v
    }

    /// One colour through the whole pipeline. `tinted: false` leaves a black-and-white look neutral, for
    /// formats that put the tint in the palette instead.
    func apply(_ red: Double, _ green: Double, _ blue: Double, tinted: Bool = true) -> (Double, Double, Double) {
        let warm = warmth * 0.6 / 255
        let r = min(1, max(0, red + warm)), b = min(1, max(0, blue - warm))
        let recipe = look.recipe
        if let mix = recipe.mix {
            let v = tone(r * mix.0 + green * mix.1 + b * mix.2)
            guard tinted else { return (v, v, v) }
            let mid = 4 * v * (1 - v) / 255
            return (clamp(v + recipe.tint.0 * mid), clamp(v + recipe.tint.1 * mid), clamp(v + recipe.tint.2 * mid))
        }
        var (x, y, z) = (tone(r), tone(green), tone(b))
        let sat = 1 + saturation / 100
        if sat != 1 {
            let l = 0.299 * x + 0.587 * y + 0.114 * z
            (x, y, z) = (clamp(l + (x - l) * sat), clamp(l + (y - l) * sat), clamp(l + (z - l) * sat))
        }
        return (x, y, z)
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// True when the sliders leave the picture as it is, so the colour step can be skipped.
    var isNeutral: Bool {
        look == .color && exposure == 0 && shadows == 0 && contrast == 0 && saturation == 0 && warmth == 0
    }
}

/// A faster or slower stretch of the clip, in source seconds. Its speed multiplies the clip's.
struct SpeedPart: Identifiable, Equatable, Codable {
    var id = UUID()
    var from: Double
    var to: Double
    var speed = 2.0
}

/// What part of the source plays, and how fast.
struct Clip: Equatable, Codable {
    var start = 0.0
    var end = 0.0
    var speed = 1.0
    var parts: [SpeedPart] = []

    static let minimumLength = 0.1

    func rate(at t: Double) -> Double {
        speed * (parts.first { t >= $0.from && t < $0.to }?.speed ?? 1)
    }

    /// [start, end] cut where the speed changes.
    func pieces() -> [(from: Double, to: Double, rate: Double)] {
        let cuts = parts.flatMap { [$0.from, $0.to] }.filter { $0 > start && $0 < end }
        let xs = Array(Set([start, end] + cuts)).sorted()
        return zip(xs, xs.dropFirst()).map { ($0, $1, rate(at: ($0 + $1) / 2)) }
    }

    /// How long the clip lasts in the export.
    var playLength: Double { pieces().reduce(0) { $0 + ($1.to - $1.from) / $1.rate } }

    /// The source time shown `tau` seconds into the export.
    func sourceTime(at tau: Double) -> Double {
        var left = tau
        for p in pieces() {
            let len = (p.to - p.from) / p.rate
            if left <= len { return p.from + left * p.rate }
            left -= len
        }
        return end
    }

    /// Moves one edge or both, keeping the clip inside the source and at least 0.1 s long.
    enum Edge { case start, end, both }
    mutating func set(start newStart: Double, end newEnd: Double, moved: Edge, duration d: Double) {
        var (a, b) = (newStart, newEnd)
        switch moved {
        case .both:
            let len = b - a
            a = max(0, min(a, d - len)); b = a + len
        case .start:
            a = max(0, min(a, d - Self.minimumLength)); b = min(d, b)
            if b < a + Self.minimumLength { b = a + Self.minimumLength }
        case .end:
            b = max(Self.minimumLength, min(b, d)); a = max(0, a)
            if a > b - Self.minimumLength { a = b - Self.minimumLength }
        }
        (start, end) = (a, b)
    }

    /// Adds a 2× part around `t` without touching its neighbours; nil if there's already one here.
    @discardableResult
    mutating func addPart(around t: Double, duration d: Double) -> SpeedPart? {
        if parts.contains(where: { t >= $0.from && t < $0.to }) { return nil }
        let before = parts.filter { $0.to <= t }.map(\.to).max() ?? 0
        let after = parts.filter { $0.from >= t }.map(\.from).min() ?? d
        guard after - before >= 0.1 else { return nil }
        let part = SpeedPart(from: max(before, t - 0.5), to: min(after, t + 0.5))
        parts.append(part)
        parts.sort { $0.from < $1.from }
        return part
    }

    /// Moves one edge of a part to `t`, without running into its neighbours.
    mutating func movePart(_ id: UUID, from t: Double? = nil, to u: Double? = nil, duration d: Double) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        if let t {
            let limit = parts.filter { $0.id != id && $0.to <= parts[i].from + 1e-9 }.map(\.to).max() ?? 0
            parts[i].from = max(limit, min(t, parts[i].to - 0.1))
        }
        if let u {
            let limit = parts.filter { $0.id != id && $0.from >= parts[i].to - 1e-9 }.map(\.from).min() ?? d
            parts[i].to = min(limit, max(u, parts[i].from + 0.1))
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case gif, mp4, webm, sticker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gif: "GIF"
        case .mp4: "MP4 video"
        case .webm: "WebM video"
        case .sticker: "Telegram sticker"
        }
    }
    var action: String {
        switch self {
        case .gif: "GIF"
        case .mp4: "MP4"
        case .webm: "WebM"
        case .sticker: "sticker"
        }
    }
    var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .mp4: "mp4"
        case .webm, .sticker: "webm"
        }
    }
}

struct ExportSettings: Equatable, Codable {
    var format: ExportFormat = .gif
    var width = 600
    var fps = 15
    var dither = true
    var silentTrack = true
}

/// Exactly what an export will write: size, frames and which moment each frame shows.
struct ExportPlan {
    static let stickerSeconds = 3.0
    static let stickerBytes = 256 * 1024

    var size: (width: Int, height: Int)
    var fps: Int
    var length: Double
    var total: Double
    var times: [Double]
    var frames: Int { times.count }

    init(clip: Clip, crop: CGSize, settings: ExportSettings) {
        var rate = settings.fps
        if settings.format == .gif { rate = min(rate, 50) }   // viewers slow down GIF frames shorter than 20 ms
        if settings.format == .sticker { rate = min(rate, 30) }
        fps = rate
        total = clip.playLength
        length = settings.format == .sticker ? min(total, Self.stickerSeconds) : total
        let n = max(1, Int((length * Double(rate)).rounded()))
        times = (0..<n).map { clip.sourceTime(at: Double($0) / Double(rate)) }
        if settings.format == .sticker {
            // Telegram wants the longer side at exactly 512 px
            let k = 512 / max(crop.width, crop.height)
            size = (Self.even(crop.width * k), Self.even(crop.height * k))
        } else {
            // never upscale: at most as big as the cropped source
            let w = min(settings.width, Int(crop.width / 2) * 2)
            size = (w, Self.even(CGFloat(w) * crop.height / crop.width))
        }
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
}

enum FileNames {
    private static let added = try! NSRegularExpression(pattern:
        #"-(\d+x\d+|sticker|telegram-sticker|mono|silvertone|noir|leica|leicaHC|acros|iphone-mono|iphone-silvertone|iphone-noir|leica-monochrom|leica-high-contrast|fuji-acros)( \(\d+\))?$"#)

    /// The source's name without what this app added, so names don't pile up when an export comes back in.
    static func clean(_ fileName: String) -> String {
        var base = (fileName as NSString).deletingPathExtension
        while true {
            let range = NSRange(base.startIndex..., in: base)
            guard let m = added.firstMatch(in: base, range: range), let r = Range(m.range, in: base) else { return base }
            base.removeSubrange(r)
        }
    }

    static func export(base: String, look: Look, format: ExportFormat, size: (width: Int, height: Int)) -> String {
        let tag = look.slug.map { "-\($0)" } ?? ""
        if format == .sticker { return "\(base)\(tag)-telegram-sticker.webm" }
        return "\(base)\(tag)-\(size.width)x\(size.height).\(format.fileExtension)"
    }

    /// `name.gif`, or `name (2).gif` if that's taken.
    static func unique(_ name: String, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let next = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}
