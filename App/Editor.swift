import AppKit
import AVFoundation
import CoreImage
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case crop, result, compare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "Crop"
        case .result: "Result"
        case .compare: "Before / After"
        }
    }
    var hint: String {
        switch self {
        case .crop: "Drag the frame to move it. Scroll to zoom."
        case .result: "The finished picture. Drag to move the crop, scroll to zoom."
        case .compare: "Drag the line: before on the left, after on the right."
        }
    }
}

enum Aspect: String, CaseIterable, Identifiable {
    case square = "1:1", portrait = "4:5", story = "9:16", wide = "16:9", original = "Original"
    var id: String { rawValue }
    func ratio(source: CGSize) -> CGFloat {
        switch self {
        case .square: 1
        case .portrait: 0.8
        case .story: 9.0 / 16
        case .wide: 16.0 / 9
        case .original: source.width / source.height
        }
    }
}

/// A file this app wrote, for the list in the side panel.
struct RecentExport: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var name: String
    var bytes: Int
    var poster: Data?
}

enum Status: Equatable {
    case idle
    case working(String, Double?)
    case done(String, URL)
    case failed(String)
}

func sizeText(_ bytes: Int) -> String {
    bytes < 1_048_576 ? "\(max(1, bytes / 1024)) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func secondsText(_ t: Double) -> String { String(format: "%.1f s", t) }

func speedText(_ x: Double) -> String {
    if x >= 10 { return "\(Int(x.rounded()))×" }
    let s = String(format: x >= 1 ? "%.2f" : "%.3f", x)
    let trimmed = s.contains(".") ? s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) : s
    return trimmed + "×"
}

/// The open document and everything the window shows.
@MainActor @Observable final class Editor {
    private(set) var source: (any MediaSource)?
    private(set) var baseName = ""
    var clip = Clip() { didSet { if clip != oldValue { invalidate() } } }
    private(set) var crop = CGRect.zero { didSet { invalidate() } }
    private(set) var aspect = Aspect.square
    private(set) var zoom = 1.0
    var adjustments = Adjustments() { didSet { invalidate() } }
    var settings = ExportSettings() { didSet { saveSettings() } }
    var mode = ViewMode.crop { didSet { invalidate() } }
    var split = 0.5 { didSet { invalidate() } }
    var selectedPart: UUID?
    private(set) var status = Status.idle
    private(set) var isExporting = false
    private(set) var thumbnails: [CGImage?] = []
    private(set) var recent: [RecentExport] = []

    /// The playhead, in source seconds. Updated many times a second; only the small views that read it redraw.
    private(set) var time = 0.0
    private(set) var isPlaying = false
    /// Bumped whenever the picture needs drawing again.
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private(set) var currentImage: CIImage?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var clock: (start: CFTimeInterval, from: Double)?
    @ObservationIgnored private var chase: (active: Bool, target: Double?) = (false, nil)
    @ObservationIgnored private var exporter: Exporter?
    @ObservationIgnored private var stripTask: Task<Void, Never>?
    @ObservationIgnored private var scrubResume = false

    init() {
        try? FileManager.default.removeItem(at: WebMImporter.folder)   // whatever an earlier run left behind
        if let data = UserDefaults.standard.data(forKey: "exportSettings"), let saved = try? JSONDecoder().decode(ExportSettings.self, from: data) {
            settings = saved
        }
        if let data = try? Data(contentsOf: Self.recentFile), let saved = try? JSONDecoder().decode([RecentExport].self, from: data) {
            recent = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "exportSettings") }
    }

    private func invalidate() { revision &+= 1 }

    var plan: ExportPlan? { source == nil ? nil : ExportPlan(clip: clip, crop: crop.size, settings: settings) }
    var isStickerTooLong: Bool { settings.format == .sticker && clip.playLength > ExportPlan.stickerSeconds + 1e-6 }
    /// Where a sticker runs out of its 3 seconds, on the source's clock.
    var stickerCut: Double? { isStickerTooLong ? clip.sourceTime(at: ExportPlan.stickerSeconds) : nil }
    var duration: Double { source?.duration ?? 0 }

    var saveFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "saveFolder") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    // MARK: opening

    func openPanel() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .gif, .image] + (UTType(filenameExtension: "webm").map { [$0] } ?? [])
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !isExporting else { return }
        let isWebM = url.pathExtension.lowercased() == "webm"
        if isWebM { status = .working("Preparing \(url.lastPathComponent)…", nil) }
        Task {
            do {
                let media = try await Media.open(url) { [weak self] f in
                    Task { @MainActor [weak self] in
                        if case .working = self?.status { self?.status = .working("Preparing \(url.lastPathComponent)…", f) }
                    }
                }
                use(media, name: FileNames.clean(url.lastPathComponent))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func use(_ media: any MediaSource, name: String) {
        pause()
        player = nil; output = nil; clock = nil; currentImage = nil
        WebMImporter.discard(source)
        source = media
        baseName = name
        clip = Clip(start: 0, end: media.duration)
        selectedPart = nil
        time = 0
        status = .idle
        crop = .zero
        applyCrop(aspect: aspect, zoom: 1, center: CGPoint(x: media.size.width / 2, y: media.size.height / 2))
        loadThumbnails(count: 24)
        if let video = media as? VideoSource {
            let item = AVPlayerItem(asset: video.asset)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(out)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.actionAtItemEnd = .pause
            p.automaticallyWaitsToMinimizeStalling = false
            player = p; output = out
        } else if let image = media as? ImageSource {
            currentImage = image.image(at: 0)
        }
        play()
    }

    func close() {
        guard !isExporting else { return }
        pause()
        stripTask?.cancel()
        player = nil; output = nil; currentImage = nil; thumbnails = []
        WebMImporter.discard(source)
        source = nil
        status = .idle
    }

    func loadThumbnails(count: Int) {
        guard let source else { return }
        stripTask?.cancel()
        thumbnails = Array(repeating: nil, count: count)
        stripTask = Task { [weak self] in
            await source.thumbnails(count: count, height: 88) { i, image in
                Task { @MainActor [weak self] in
                    if let self, i < self.thumbnails.count { self.thumbnails[i] = image }
                }
            }
        }
    }

    // MARK: playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard source != nil, !isExporting else { return }
        if time >= clip.end - 0.02 || time < clip.start { seek(clip.start) }
        isPlaying = true
        if let player { player.rate = Float(min(16, clip.rate(at: time))) }
        else { clock = (CACurrentMediaTime(), time) }
    }

    func pause() {
        isPlaying = false
        player?.pause()
        clock = nil
    }

    func seek(_ t: Double) {
        let target = max(0, min(t, duration))
        time = target
        if player != nil {
            chase.target = target
            chaseSeek()
        } else {
            if isPlaying { clock = (CACurrentMediaTime(), target) }
            updateImageFrame()
        }
    }

    /// Asks for the newest wanted moment only when the last seek has landed, so scrubbing keeps up.
    private func chaseSeek() {
        guard !chase.active, let target = chase.target, let player else { return }
        chase = (true, nil)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chase.active = false
                self.chaseSeek()
            }
        }
    }

    private func updateImageFrame() {
        guard let image = (source as? ImageSource)?.image(at: time) else { return }
        if image !== currentImage { currentImage = image; invalidate() }
    }

    /// Called once per display refresh by the picture view: moves the playhead, loops, takes the newest frame.
    func tick() {
        guard source != nil else { return }
        if let player, let output {
            if isPlaying, !chase.active, chase.target == nil {
                let t = player.currentTime().seconds
                if t.isFinite { time = t }
                if time >= clip.end - 0.005 || player.timeControlStatus == .paused {
                    // through the chase, so the seek gets to land instead of being replaced on every refresh
                    seek(clip.start)
                    player.rate = Float(min(16, clip.rate(at: clip.start)))
                } else if time < clip.start - 0.05 {
                    seek(clip.start)
                } else {
                    let rate = Float(min(16, clip.rate(at: time)))
                    if abs(player.rate - rate) > 0.001 { player.rate = rate }
                }
            }
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
               let video = source as? VideoSource {
                currentImage = video.oriented(buffer)
                invalidate()
            }
        } else if isPlaying, let c = clock {
            // the same clock for GIFs and photos, in small steps so a speed change applies from here on
            let now = CACurrentMediaTime()
            var t = time + (now - c.start) * clip.rate(at: time)
            clock = (now, t)
            if t >= clip.end { t = clip.start; clock = (now, t) }
            if t < clip.start { t = clip.start }
            time = t
            updateImageFrame()
        }
    }

    // MARK: trim, scrub

    func beginScrub() { scrubResume = isPlaying; pause() }
    func endScrub(rewind: Bool) {
        if rewind { seek(clip.start) }
        if scrubResume { play() }
    }
    func trim(start: Double) { clip.set(start: start, end: clip.end, moved: .start, duration: duration); seek(clip.start) }
    func trim(end: Double) { clip.set(start: clip.start, end: end, moved: .end, duration: duration); seek(max(clip.start, clip.end - 0.02)) }
    func slide(from: Clip, by dt: Double) { clip.set(start: from.start + dt, end: from.end + dt, moved: .both, duration: duration); seek(clip.start) }
    func scrub(to t: Double) { seek(max(clip.start, min(t, clip.end - 0.02))) }
    func startHere() { clip.set(start: time, end: clip.end, moved: .start, duration: duration) }
    func endHere() { clip.set(start: clip.start, end: time, moved: .end, duration: duration) }

    // MARK: speed

    func addPart() {
        if let part = clip.addPart(around: time, duration: duration) { selectedPart = part.id }
        else { status = .failed("There’s already a fast part here: click its band to change it.") }
    }
    func deleteSelectedPart() {
        clip.parts.removeAll { $0.id == selectedPart }
        selectedPart = nil
    }
    func moveSelectedPart(from: Bool) {
        guard let id = selectedPart else { return }
        if from { clip.movePart(id, from: time, duration: duration) } else { clip.movePart(id, to: time, duration: duration) }
    }
    func setSelectedPartSpeed(_ v: Double) {
        if let i = clip.parts.firstIndex(where: { $0.id == selectedPart }) { clip.parts[i].speed = v }
    }
    func fitIntoStickerLength() {
        clip.speed = min(16, clip.speed * clip.playLength / ExportPlan.stickerSeconds)
    }

    // MARK: crop

    func setAspect(_ a: Aspect) { applyCrop(aspect: a, zoom: zoom, center: CGPoint(x: crop.midX, y: crop.midY)) }
    func setZoom(_ z: Double) { applyCrop(aspect: aspect, zoom: z, center: CGPoint(x: crop.midX, y: crop.midY)) }
    func moveCrop(to origin: CGPoint) { guard let source else { return }; crop = Self.clamped(CGRect(origin: origin, size: crop.size), in: source.size) }
    enum Snap { case left, center, right }
    func snap(_ s: Snap) {
        guard let source else { return }
        let x: CGFloat = s == .left ? 0 : s == .right ? source.size.width - crop.width : (source.size.width - crop.width) / 2
        moveCrop(to: CGPoint(x: x, y: crop.minY))
    }
    private func applyCrop(aspect a: Aspect, zoom z: Double, center: CGPoint) {
        guard let source else { return }
        aspect = a; zoom = z
        let ratio = a.ratio(source: source.size), s = source.size
        let full = s.width / s.height > ratio ? CGSize(width: s.height * ratio, height: s.height) : CGSize(width: s.width, height: s.width / ratio)
        let size = CGSize(width: full.width * z, height: full.height * z)
        crop = Self.clamped(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), in: s)
    }
    private static func clamped(_ r: CGRect, in s: CGSize) -> CGRect {
        CGRect(x: max(0, min(s.width - r.width, r.minX)), y: max(0, min(s.height - r.height, r.minY)), width: r.width, height: r.height)
    }

    // MARK: colour

    func resetColor() { adjustments = Adjustments() }

    /// Lifts the exposure so highlights reach about 95 %, then opens the shadows so the median sits near the middle.
    func autoLight() {
        guard let image = currentImage else { return }
        let r = Renderer.shared
        let w = 96, h = max(1, Int(96 * crop.height / max(crop.width, 1)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { r.rgba(r.scaled(r.cropped(image, crop: crop), to: CGSize(width: w, height: h), highQuality: false), width: w, height: h, into: $0.baseAddress!) }
        var levels: [Double] = []
        for i in stride(from: 0, to: px.count, by: 4) { levels.append((0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255) }
        levels.sort()
        guard !levels.isEmpty else { return }
        let top = max(0.05, levels[Int(Double(levels.count) * 0.99)])
        let e = max(-1, min(1.5, log2(0.95 / top)))
        let median = min(0.95, max(0.02, levels[levels.count / 2] * pow(2, e)))
        adjustments.exposure = (e * 100).rounded()
        adjustments.shadows = (max(0, min(1, log(median) / log(0.45) - 1)) * 100).rounded()
        adjustments.contrast = 12
        if adjustments.look == .color { adjustments.saturation = 10 }
    }

    // MARK: export

    func export() {
        guard let source, !isExporting else { return }
        pause()
        isExporting = true
        let exporter = Exporter(); self.exporter = exporter
        let label = settings.format.action
        status = .working("Making your \(label)…", 0)
        let job = Exporter.Job(source: source, clip: clip, crop: crop, adjustments: adjustments, settings: settings, baseName: baseName, folder: saveFolder)
        let poster = makePoster()
        Task.detached { [weak self] in
            let result = Result { () -> Exporter.Output in
                try exporter.run(job) { stage in
                    let next: Status
                    switch stage {
                    case .colours: next = .working("Choosing colours…", nil)
                    case .frames(let f): next = .working("Making your \(label)…", f)
                    case .shrinking: next = .working("Making it smaller for Telegram…", nil)
                    }
                    Task { @MainActor [weak self] in self?.report(next) }
                }
            }
            await self?.finished(result, poster: poster)
        }
    }

    func cancelExport() { exporter?.cancel() }

    private func report(_ s: Status) { if isExporting { status = s } }

    private func finished(_ result: Result<Exporter.Output, Error>, poster: Data?) {
        isExporting = false
        exporter = nil
        switch result {
        case .success(let out):
            let name = out.url.lastPathComponent
            status = .done("✓ Downloaded \(name) · \(sizeText(out.bytes)) · took \(String(format: "%.1f", out.seconds)) s", out.url)
            recent.insert(RecentExport(path: out.url.path, name: name, bytes: out.bytes, poster: poster), at: 0)
            if recent.count > 30 { recent.removeLast(recent.count - 30) }
            saveRecent()
        case .failure(let error):
            if case MediaError.cancelled = error { status = .idle } else { status = .failed(error.localizedDescription) }
        }
        seek(clip.start)
    }

    func removeRecent(_ item: RecentExport) { recent.removeAll { $0.id == item.id }; saveRecent() }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    private static var recentFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GIF Maker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent.json")
    }
    private func saveRecent() { try? JSONEncoder().encode(recent).write(to: Self.recentFile) }

    private func makePoster() -> Data? {
        guard let image = currentImage else { return nil }
        let r = Renderer.shared, h = max(1, 128 * crop.height / max(crop.width, 1))
        let still = r.colored(r.scaled(r.cropped(image, crop: crop), to: CGSize(width: 128, height: h), highQuality: false), adjustments)
        return r.context.jpegRepresentation(of: still, colorSpace: r.srgb, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.75])
    }
}
