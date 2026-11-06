import AVFoundation
import CoreImage
import Foundation
import ImageIO

// The engine's test suite: a plain executable over Core/*.swift, run by scripts/test-core.sh. It exports real files from
// the fixtures in e2e/fixtures and checks what's in them, the same way the web suite does.

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0, passed = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if ok { passed += 1 } else { failures += 1; print("  ✗ line \(line): \(what())") }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double, _ what: String, line: Int = #line) {
    check(abs(a - b) <= tolerance, "\(what): \(a), expected \(b) ± \(tolerance)", line: line)
}
func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw: \(error)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures = root.appendingPathComponent("e2e/fixtures")
let outFolder = FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

func open(_ name: String) throws -> any MediaSource {
    let url = fixtures.appendingPathComponent(name)
    var result: Result<any MediaSource, Error>!
    let done = DispatchSemaphore(value: 0)
    Task { do { result = .success(try await Media.open(url)) } catch { result = .failure(error) }; done.signal() }
    done.wait()
    return try result.get()
}

func export(_ source: any MediaSource, clip: Clip? = nil, crop: CGRect? = nil, adjustments: Adjustments = Adjustments(), settings: ExportSettings, name: String = "out") throws -> Exporter.Output {
    var c = clip ?? Clip(start: 0, end: source.duration)
    if c.end == 0 { c.end = source.duration }
    let side = min(source.size.width, source.size.height)
    let square = CGRect(x: (source.size.width - side) / 2, y: (source.size.height - side) / 2, width: side, height: side)
    let job = Exporter.Job(source: source, clip: c, crop: crop ?? square, adjustments: adjustments, settings: settings, baseName: name, folder: outFolder)
    return try Exporter().run(job) { _ in }
}

struct GIFInfo { var frames: Int; var width: Int; var height: Int; var duration: Double; var centre: [Double]; var allGrey: Bool; var firstLevels: Int }
func inspectGIF(_ url: URL) -> GIFInfo {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let n = CGImageSourceGetCount(src)
    var info = GIFInfo(frames: n, width: 0, height: 0, duration: 0, centre: [], allGrey: true, firstLevels: 0)
    for i in 0..<n {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as! [CFString: Any]
        let gif = props[kCGImagePropertyGIFDictionary] as! [CFString: Any]
        info.duration += (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as! Double
        let cg = CGImageSourceCreateImageAtIndex(src, i, nil)!
        let (w, h) = (cg.width, cg.height)
        (info.width, info.height) = (w, h)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for y in (h / 2 - 8)..<(h / 2 + 8) { for x in (w / 2 - 8)..<(w / 2 + 8) { let q = (y * w + x) * 4; sum += (Double(px[q]) + Double(px[q + 1]) + Double(px[q + 2])) / 3 } }
        info.centre.append(sum / 256)
        var levels = Set<UInt8>()
        for q in stride(from: 0, to: px.count, by: 4) {
            if px[q] != px[q + 1] || px[q + 1] != px[q + 2] { info.allGrey = false }
            if i == 0 { levels.insert(px[q]) }
        }
        if i == 0 { info.firstLevels = levels.count }
    }
    return info
}

func ffprobe(_ url: URL, _ entries: String) -> String? {
    let paths = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
    guard let bin = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-v", "error", "-count_frames", "-show_entries", entries, "-of", "compact=nk=0", url.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

func mainTests() {
    test("speed map: lengths and source times") {
        var c = Clip(start: 0, end: 5)
        near(c.playLength, 5, 1e-9, "plain")
        c.speed = 2
        near(c.playLength, 2.5, 1e-9, "2×")
        near(c.sourceTime(at: 1), 2, 1e-9, "1 s in at 2×")
        c = Clip(start: 0, end: 5, parts: [SpeedPart(from: 1, to: 3, speed: 4)])
        near(c.playLength, 3.5, 1e-9, "a 4× part")
        near(c.sourceTime(at: 1.25), 2, 1e-9, "inside the part")
        near(c.sourceTime(at: 2), 3.5, 1e-9, "after the part")
        near(c.rate(at: 2), 4, 1e-9, "rate in the part")
    }
    test("clip edges stay in the source; parts don't overlap") {
        var c = Clip(start: 0, end: 5)
        c.set(start: 4.99, end: 1, moved: .start, duration: 5)
        check(c.start < c.end, "start before end")
        c = Clip(start: 3, end: 4)
        c.set(start: 4.5, end: 5.5, moved: .both, duration: 5)
        near(c.end, 5, 1e-9, "slides to the end"); near(c.end - c.start, 1, 1e-9, "keeps its length")
        c = Clip(start: 0, end: 5)
        let a = c.addPart(around: 1, duration: 5)
        check(a != nil && c.addPart(around: 1.2, duration: 5) == nil, "no part on top of a part")
        let b = c.addPart(around: 1.8, duration: 5)
        check(b != nil && b!.from >= a!.to - 1e-9, "the next part starts after the first")
    }
    test("the plan: no upscaling, 50 fps GIF cap, sticker size and 3 s") {
        var s = ExportSettings(); s.width = 1080
        var p = ExportPlan(clip: Clip(start: 0, end: 1), crop: CGSize(width: 360, height: 360), settings: s)
        check(p.size == (360, 360), "no upscaling")
        s.fps = 60
        p = ExportPlan(clip: Clip(start: 0, end: 1), crop: CGSize(width: 360, height: 360), settings: s)
        check(p.fps == 50 && p.frames == 50, "GIF cap")
        s.format = .sticker
        p = ExportPlan(clip: Clip(start: 0, end: 5), crop: CGSize(width: 1280, height: 720), settings: s)
        check(p.size == (512, 288), "sticker size \(p.size)")
        check(p.fps == 30 && p.frames == 90, "sticker stops at 3 s")
        s.format = .mp4
        p = ExportPlan(clip: Clip(start: 0, end: 5), crop: CGSize(width: 1280, height: 720), settings: s)
        check(p.frames == 300, "other formats have no limit")
    }
    test("names: what the app added comes off; exports say what they are") {
        check(FileNames.clean("гифa (1)-leicaHC-600x600-sticker-512x512 (2).gif") == "гифa (1)", FileNames.clean("гифa (1)-leicaHC-600x600-sticker-512x512 (2).gif"))
        check(FileNames.clean("holiday.mov") == "holiday", "plain name")
        check(FileNames.export(base: "a", look: .noir, format: .gif, size: (600, 600)) == "a-iphone-noir-600x600.gif", "gif name")
        check(FileNames.export(base: "a", look: .color, format: .sticker, size: (512, 512)) == "a-telegram-sticker.webm", "sticker name")
    }
    test("looks: every black-and-white look is neutral and clearly different") {
        let looks = Look.allCases.filter { $0 != .color }
        func grid(_ l: Look) -> [Double] {
            var a = Adjustments(); a.look = l
            return stride(from: 0.0, through: 1, by: 0.25).flatMap { r in stride(from: 0.0, through: 1, by: 0.25).flatMap { g in stride(from: 0.0, through: 1, by: 0.25).map { b in a.apply(r, g, b, tinted: false).0 } } }
        }
        for (i, x) in looks.enumerated() {
            var a = Adjustments(); a.look = x
            let v = a.apply(0.8, 0.2, 0.4, tinted: false)
            check(v.0 == v.1 && v.1 == v.2, "\(x) is grey")
            for y in looks[(i + 1)...] {
                let d = zip(grid(x), grid(y)).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(grid(x).count)
                check(d * 255 > 6, "\(x) vs \(y): \(d * 255)")
            }
        }
    }
    test("sliders go both ways") {
        var a = Adjustments(); a.exposure = -100
        near(a.tone(0.5), 0.25, 1e-9, "one stop down")
        a = Adjustments(); a.exposure = 100
        near(a.tone(0.25), 0.5, 1e-9, "one stop up")
        a = Adjustments(); a.shadows = 100
        check(a.tone(0.2) > 0.4, "shadows up"); a.shadows = -100
        check(a.tone(0.5) < 0.3, "shadows down")
    }
    test("video to GIF: frames, length and the right moments, read in order") {
        let s = try open("fade.mp4")
        near(s.duration, 5, 0.05, "duration")
        var set = ExportSettings(); set.width = 240
        let o = try export(s, clip: Clip(start: 1, end: 4), settings: set, name: "fade")
        check(o.url.lastPathComponent == "fade-240x240.gif", o.url.lastPathComponent)
        let g = inspectGIF(o.url)
        check(g.frames == 45 && g.width == 240 && g.height == 240, "\(g.frames) frames \(g.width)×\(g.height)")
        near(g.duration, 3, 0.011, "length")
        near(g.centre[0], 51, 9, "first frame"); near(g.centre[22], 125, 11, "middle frame"); near(g.centre[44], 200, 13, "last frame")
        for i in 1..<g.centre.count {
            check(g.centre[i] >= g.centre[i - 1] - 1, "ramp at \(i)")
            check(g.centre[i] - g.centre[i - 1] <= 9, "step at \(i): \(g.centre[i] - g.centre[i - 1])")
        }
    }
    test("colour settings reach the file; black and white is pure grey with many levels") {
        var set = ExportSettings(); set.width = 240
        var a = Adjustments(); a.exposure = 100
        let bright = inspectGIF(try export(try open("fade.mp4"), clip: Clip(start: 1, end: 2), adjustments: a, settings: set).url)
        near(bright.centre[0], 102, 12, "one stop up")
        a = Adjustments(); a.look = .leica
        let bw = inspectGIF(try export(try open("bars.mp4"), clip: Clip(start: 0, end: 1), adjustments: a, settings: set).url)
        check(bw.allGrey, "grey"); check(bw.firstLevels > 40, "\(bw.firstLevels) levels")
        a.look = .silvertone
        let tinted = inspectGIF(try export(try open("bars.mp4"), clip: Clip(start: 0, end: 1), adjustments: a, settings: set).url)
        check(!tinted.allGrey, "Silvertone keeps its tint")
    }
    test("crop picks the right pixels") {
        // split.mp4: red 0–280 px, green 280–1000 px, blue 1000–1280 px
        let s = try open("split.mp4")
        var set = ExportSettings(); set.width = 120; set.fps = 5
        func colour(_ x: CGFloat) throws -> [UInt8] {
            let o = try export(s, clip: Clip(start: 0, end: 0.4), crop: CGRect(x: x, y: 0, width: 720, height: 720), settings: set)
            let src = CGImageSourceCreateWithURL(o.url as CFURL, nil)!
            let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return Array(px[(60 * cg.width + 3) * 4..<(60 * cg.width + 3) * 4 + 3]) + Array(px[(60 * cg.width + cg.width - 4) * 4..<(60 * cg.width + cg.width - 4) * 4 + 3])
        }
        let left = try colour(0), right = try colour(560)
        check(left[0] > 150 && left[1] < 80, "left edge red: \(left)")
        check(right[5] > 150 && right[3] < 80, "right edge blue: \(right)")
    }
    test("a file cut without re-encoding (edit list) starts at the right frame") {
        let s = try open("trimmed.mp4")
        near(s.duration, 3, 0.05, "duration")
        var set = ExportSettings(); set.width = 240
        let g = inspectGIF(try export(s, settings: set).url)
        check(g.frames == 45, "\(g.frames) frames")
        near(g.centre[0], 102, 12, "first frame"); near(g.centre[44], 251, 14, "last frame")
    }
    test("a frame held for seconds, as in screen recordings, shows while it's held") {
        // held.mp4: fade.mp4's first (black) frame held until 4 s, then its last second
        var set = ExportSettings(); set.width = 240
        let g = inspectGIF(try export(try open("held.mp4"), clip: Clip(start: 2.5, end: 4.8), settings: set).url)
        near(g.centre[0], 0, 8, "still the held black frame at 2.5 s")
        check(g.centre[g.centre.count - 1] > 180, "the later frames follow: \(g.centre[g.centre.count - 1])")
    }
    test("the frame times agree with the speed map") {
        let c = Clip(start: 0.5, end: 5, speed: 1.5, parts: [SpeedPart(from: 1, to: 3, speed: 4)])
        let times = c.sourceTimes(count: 40, fps: 15)
        for (i, t) in times.enumerated() { near(t, c.sourceTime(at: Double(i) / 15), 1e-9, "frame \(i)") }
    }
    test("speed reaches the file, frame by frame") {
        var set = ExportSettings(); set.width = 240
        let g = inspectGIF(try export(try open("fade.mp4"), clip: Clip(start: 0, end: 5, parts: [SpeedPart(from: 1, to: 3, speed: 4)]), settings: set).url)
        check(g.frames == 53, "\(g.frames) frames")
        near(g.centre[15], 51, 10, "1 s in the source is at 1 s"); near(g.centre[21], 51 * 2.6, 12, "0.4 s later: 2.6 s")
    }
    test("a GIF as the source keeps its frames and timing") {
        let s = try open("fade.gif")
        check(s.size == CGSize(width: 320, height: 320), "\(s.size)"); near(s.duration, 2, 0.01, "duration")
        var set = ExportSettings(); set.width = 320
        let g = inspectGIF(try export(s, settings: set).url)
        check(g.frames == 30, "\(g.frames) frames"); near(g.duration, 2, 0.011, "length")
        near(g.centre[0], 0, 15, "starts dark"); near(g.centre[15], 127, 18, "middle"); near(g.centre[29], 242, 18, "ends bright")
    }
    test("a photo becomes a 3-second clip") {
        let s = try open("photo.png")
        check(s.size == CGSize(width: 1280, height: 720), "\(s.size)"); near(s.duration, 3, 1e-9, "duration")
        var set = ExportSettings(); set.width = 240
        let g = inspectGIF(try export(s, settings: set).url)
        check(g.frames == 45, "\(g.frames) frames")
    }
    test("a file that isn't a video says so") {
        do { _ = try open("broken.mp4"); check(false, "should have thrown") }
        catch { check(error.localizedDescription.contains("Can’t open"), error.localizedDescription) }
    }
    test("MP4: H.264 with the right size, length and silent track, in the look") {
        var set = ExportSettings(); set.format = .mp4; set.width = 480; set.fps = 30
        let o = try export(try open("bars.mp4"), clip: Clip(start: 0, end: 2), settings: set)
        let asset = AVURLAsset(url: o.url)
        let sem = DispatchSemaphore(value: 0)
        Task {
            let v = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await v.load(.naturalSize)
            let a = try await asset.loadTracks(withMediaType: .audio)
            let d = try await asset.load(.duration).seconds
            let f = try await v.load(.formatDescriptions).first!
            check(size == CGSize(width: 480, height: 480), "size \(size)")
            near(d, 2, 0.1, "length")
            check(a.count == 1, "silent track")
            check(CMFormatDescriptionGetMediaSubType(f) == kCMVideoCodecType_H264, "H.264")
            sem.signal()
        }
        sem.wait()
        set.silentTrack = false
        let silent = try export(try open("bars.mp4"), clip: Clip(start: 0, end: 1), settings: set)
        Task { let a = try await AVURLAsset(url: silent.url).loadTracks(withMediaType: .audio); check(a.isEmpty, "no track when off"); sem.signal() }
        sem.wait()
        // the look survives into the video
        var look = Adjustments(); look.look = .noir
        let bw = try export(try open("bars.mp4"), clip: Clip(start: 0, end: 1), adjustments: look, settings: set)
        Task {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: bw.url))
            let (cg, _) = try await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var chroma = 0
            for q in stride(from: 0, to: px.count, by: 16) { chroma = max(chroma, Int(max(px[q], px[q + 1], px[q + 2])) - Int(min(px[q], px[q + 1], px[q + 2]))) }
            check(chroma < 14, "chroma \(chroma)")
            sem.signal()
        }
        sem.wait()
    }
    test("Telegram sticker: VP9 WebM, 512 px, at most 3 s and 256 KB, no sound") {
        var set = ExportSettings(); set.format = .sticker; set.fps = 60
        let s = try open("fade.gif")
        let o = try export(s, settings: set, name: "fade")
        check(o.url.lastPathComponent == "fade-telegram-sticker.webm", o.url.lastPathComponent)
        check(o.bytes <= 256 * 1024, "\(o.bytes) bytes")
        if let p = ffprobe(o.url, "stream=codec_name,codec_type,width,height,nb_read_frames:format=duration,format_name") {
            check(p.contains("codec_name=vp9") && p.contains("width=512") && p.contains("height=512"), p)
            check(!p.contains("codec_type=audio"), "no sound")
            check(p.contains("webm"), p)
            check(p.contains("nb_read_frames=60"), p)
        } else { print("  (ffprobe not installed: container not inspected)") }
        // a long, busy clip is cut to 3 s and squeezed under the limit
        let long = try export(try open("bars.mp4"), crop: CGRect(x: 0, y: 0, width: 960, height: 540), settings: set, name: "bars")
        check(long.bytes <= 256 * 1024, "\(long.bytes) bytes")
        if let p = ffprobe(long.url, "stream=width,height,nb_read_frames:format=duration") {
            // at this tight a bitrate VP9 may drop a frame or two
            check(p.contains("width=512") && p.contains("height=288") && (p.contains("nb_read_frames=90") || p.contains("nb_read_frames=89") || p.contains("nb_read_frames=88")), p)
        }
    }
    test("WebM: VP9, chosen size") {
        var set = ExportSettings(); set.format = .webm; set.width = 320; set.fps = 15
        let o = try export(try open("bars.mp4"), clip: Clip(start: 0, end: 1), settings: set, name: "bars")
        check(o.url.lastPathComponent == "bars-320x320.webm", o.url.lastPathComponent)
        if let p = ffprobe(o.url, "stream=codec_name,width,nb_read_frames") { check(p.contains("vp9") && p.contains("width=320") && p.contains("nb_read_frames=15"), p) }
    }
    test("a taken name gets a number; nothing half-written is left behind") {
        var set = ExportSettings(); set.width = 120; set.fps = 5
        let a = try export(try open("fade.mp4"), clip: Clip(start: 0, end: 0.4), settings: set, name: "same")
        let b = try export(try open("fade.mp4"), clip: Clip(start: 0, end: 0.4), settings: set, name: "same")
        check(a.url != b.url && b.url.lastPathComponent == "same-120x120 (2).gif", b.url.lastPathComponent)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: outFolder.path).filter { $0.hasPrefix(".") }
        check(hidden.isEmpty, "\(hidden)")
    }
}

// WebKit (the VP9 encoder) needs the main thread's run loop, so the tests run on a background one.
Thread.detachNewThread {
    mainTests()
    try? FileManager.default.removeItem(at: outFolder)
    print(failures == 0 ? "✓ \(passed) checks passed" : "✗ \(failures) failed, \(passed) passed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
