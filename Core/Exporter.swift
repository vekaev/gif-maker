import CoreImage
import Foundation

/// Runs one export on a background thread: read frames in order, render, encode, write the file.
final class Exporter {
    struct Job {
        var source: any MediaSource
        var clip: Clip
        var crop: CGRect
        var adjustments: Adjustments
        var settings: ExportSettings
        var baseName: String
        var folder: URL
    }

    struct Output {
        var url: URL
        var bytes: Int
        var seconds: Double
    }

    enum Stage { case colours, frames(Double), shrinking }

    private let lock = NSLock()
    private var isCancelled = false
    func cancel() { lock.lock(); isCancelled = true; lock.unlock() }
    private func check() throws {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { throw MediaError.cancelled }
    }

    func run(_ job: Job, progress: @escaping (Stage) -> Void) throws -> Output {
        let began = Date()
        let plan = ExportPlan(clip: job.clip, crop: job.crop.size, settings: job.settings)
        let name = FileNames.export(base: job.baseName, look: job.adjustments.look, format: job.settings.format, size: plan.size)
        // written elsewhere and moved in when done, so the folder never shows half a file or an encoder's leftovers
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GIFMaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent("export.\(job.settings.format.fileExtension)")
        switch job.settings.format {
        case .gif: try writeGIF(job, plan, to: temp, progress)
        case .mp4: try writeMP4(job, plan, to: temp, progress)
        case .webm: try writeVP9(job, plan, to: temp, targetBytes: nil, progress)
        case .sticker: try writeVP9(job, plan, to: temp, targetBytes: ExportPlan.stickerBytes, progress)
        }
        try check()
        let url = FileNames.unique(name, in: job.folder)
        try FileManager.default.moveItem(at: temp, to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(url: url, bytes: bytes, seconds: Date().timeIntervalSince(began))
    }

    private func writeGIF(_ job: Job, _ plan: ExportPlan, to url: URL, _ progress: (Stage) -> Void) throws {
        let (w, h) = plan.size, renderer = Renderer.shared
        let adj = job.adjustments, grey = adj.look.recipe.mix != nil
        var palette: [GIFWriter.RGB]
        if grey {
            palette = GIFWriter.greyPalette(adj)
        } else {
            // up to 32 frames from across the clip at a small size: enough that a fade or a change of light
            // has palette colours close together, and quick
            progress(.colours)
            let sw = min(w, 160), sh = max(1, sw * h / w), k = min(32, plan.frames)
            let times = (0..<k).map { plan.times[k > 1 ? $0 * (plan.frames - 1) / (k - 1) : 0] }
            var sample = [UInt8](repeating: 0, count: sw * sh * 4 * k)
            try sample.withUnsafeMutableBytes { raw in
                try job.source.read(times: times) { i, image in
                    try check()
                    let f = renderer.frame(image, crop: job.crop, size: CGSize(width: sw, height: sh), adjustments: adj, seed: i + 1)
                    renderer.rgba(f, width: sw, height: sh, into: raw.baseAddress! + i * sw * sh * 4)
                }
            }
            palette = sample.withUnsafeBufferPointer { GIFWriter.palette(from: $0) }
        }
        let writer = GIFWriter(width: w, height: h, fps: plan.fps, palette: palette, dither: job.settings.dither)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        try job.source.read(times: plan.times) { i, image in
            try check()
            let f = renderer.frame(image, crop: job.crop, size: CGSize(width: w, height: h), adjustments: adj, seed: i + 1, tinted: !grey)
            pixels.withUnsafeMutableBytes { renderer.rgba(f, width: w, height: h, into: $0.baseAddress!) }
            pixels.withUnsafeBufferPointer { writer.add(rgba: $0.baseAddress!, grey: grey) }
            progress(.frames(Double(i + 1) / Double(plan.frames)))
        }
        try writer.finish().write(to: url)
    }

    private func writeMP4(_ job: Job, _ plan: ExportPlan, to url: URL, _ progress: (Stage) -> Void) throws {
        let (w, h) = plan.size, renderer = Renderer.shared
        let writer = try MP4Writer(url: url, width: w, height: h, fps: plan.fps, silentTrack: job.settings.silentTrack)
        try job.source.read(times: plan.times) { i, image in
            try check()
            try writer.add(renderer.frame(image, crop: job.crop, size: CGSize(width: w, height: h), adjustments: job.adjustments, seed: i + 1))
            progress(.frames(Double(i + 1) / Double(plan.frames)))
        }
        try writer.finish()
    }

    /// WebM. A sticker has a size limit: frames are kept and the bitrate stepped down until it fits.
    private func writeVP9(_ job: Job, _ plan: ExportPlan, to url: URL, targetBytes: Int?, _ progress: (Stage) -> Void) throws {
        let (w, h) = plan.size, renderer = Renderer.shared
        let step = 1 / Double(plan.fps)
        var bitrate = targetBytes.map { Int(Double($0 * 8) * 0.85 / plan.length) } ?? max(2_000_000, Int(Double(w * h * plan.fps) * 0.15))
        var kept: [Data] = []

        func encode() throws -> Data {
            let encoder = VP9Encoder()
            try encoder.start(width: w, height: h, fps: plan.fps, bitrate: bitrate)
            func send(_ data: Data, _ i: Int) throws {
                try check()
                try encoder.add(rgba: data, time: Double(i) * step, duration: step, key: i % (plan.fps * 2) == 0)
                progress(.frames(Double(i + 1) / Double(plan.frames)))
            }
            if kept.isEmpty {
                try job.source.read(times: plan.times) { i, image in
                    let f = renderer.frame(image, crop: job.crop, size: CGSize(width: w, height: h), adjustments: job.adjustments, seed: i + 1)
                    var data = Data(count: w * h * 4)
                    data.withUnsafeMutableBytes { renderer.rgba(f, width: w, height: h, into: $0.baseAddress!) }
                    if targetBytes != nil { kept.append(data) }
                    try send(data, i)
                }
            } else {
                for (i, data) in kept.enumerated() { try send(data, i) }
            }
            return WebM.file(chunks: try encoder.finish(), width: w, height: h, duration: Double(plan.frames) * step, frameSeconds: step)
        }

        var file = try encode()
        if let targetBytes {
            var attempt = 0
            while file.count > targetBytes, attempt < 4 {
                progress(.shrinking)
                bitrate = Int(Double(bitrate) * Double(targetBytes) / Double(file.count) * 0.85)
                file = try encode()
                attempt += 1
            }
        }
        try file.write(to: url)
    }
}
