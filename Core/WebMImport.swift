import AVFoundation
import CoreVideo
import Foundation

/// AVFoundation can't read WebM, so a WebM is imported: its frames are found by a small parser, decoded by WebKit
/// (VP9, VP8, AV1 through WebCodecs), and written to a temporary ProRes movie, which then edits like any other video.
enum WebMImporter {
    struct Frame { var time: Double; var key: Bool; var data: Data }
    struct Parsed { var codec: String; var width: Int; var height: Int; var duration: Double?; var frames: [Frame] }

    // MARK: the container

    /// Walks the Matroska structure for the first video track's frames. Handles the unknown sizes live recorders write.
    static func parse(_ bytes: Data) -> Parsed? {
        let d = bytes
        guard d.count > 4, d.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) else { return nil }
        var codec: String?, width = 0, height = 0, videoTrack = -1, scale = 1_000_000.0, duration: Double?
        var frames: [Frame] = []
        var clusterTime = 0.0

        func vint(_ p: inout Int, keepMarker: Bool) -> UInt64? {
            guard p < d.count else { return nil }
            let first = d[d.startIndex + p]
            guard first != 0 else { return nil }
            let n = first.leadingZeroBitCount + 1
            guard p + n <= d.count else { return nil }
            var v = UInt64(keepMarker ? first : first & (0xFF >> UInt8(n)))
            var unknown = (first & (0xFF >> UInt8(n))) == (0xFF >> UInt8(n))
            for i in 1..<max(n, 1) where n > 1 {
                let b = d[d.startIndex + p + i]
                if b != 0xFF { unknown = false }
                v = v << 8 | UInt64(b)
            }
            p += n
            return (!keepMarker && unknown) ? UInt64.max : v
        }
        func uint(_ a: Int, _ b: Int) -> Int { d[(d.startIndex + a)..<(d.startIndex + b)].reduce(0) { $0 << 8 | Int($1) } }
        func float(_ a: Int, _ b: Int) -> Double? {
            let raw = UInt64(uint(a, b))
            if b - a == 8 { return Double(bitPattern: raw) }
            if b - a == 4 { return Double(Float(bitPattern: UInt32(raw))) }
            return nil
        }
        func block(_ a: Int, _ b: Int, simple: Bool, hasReference: Bool) {
            var p = a
            guard let track = vint(&p, keepMarker: false), Int(track) == videoTrack, p + 3 <= b else { return }
            var rel = uint(p, p + 2)
            if rel >= 0x8000 { rel -= 0x10000 }
            let flags = d[d.startIndex + p + 2]
            p += 3
            let key = simple ? (flags & 0x80) != 0 : !hasReference
            let time = (clusterTime + Double(rel)) * scale / 1e9
            frames.append(Frame(time: time, key: key, data: d.subdata(in: (d.startIndex + p)..<(d.startIndex + b))))
        }
        func walkTrack(_ a: Int, _ b: Int) {
            var p = a, number = -1, type = 0, id: String?, w = 0, h = 0
            while p < b, let tag = vint(&p, keepMarker: true), let size = vint(&p, keepMarker: false) {
                let end = min(b, p &+ Int(clamping: size))
                switch tag {
                case 0xD7: number = uint(p, end)
                case 0x83: type = uint(p, end)
                case 0x86: id = String(decoding: d[(d.startIndex + p)..<(d.startIndex + end)], as: UTF8.self)
                case 0xE0:
                    var q = p
                    while q < end, let t = vint(&q, keepMarker: true), let s = vint(&q, keepMarker: false) {
                        let e = min(end, q &+ Int(clamping: s))
                        if t == 0xB0 { w = uint(q, e) }
                        if t == 0xBA { h = uint(q, e) }
                        q = e
                    }
                default: break
                }
                p = end
            }
            if type == 1, codec == nil { (videoTrack, codec, width, height) = (number, id, w, h) }
        }

        /// One flat pass: containers are stepped into, so an unknown size doesn't matter.
        func walk(_ from: Int, _ to: Int) {
            var p = from
            while p < to, let tag = vint(&p, keepMarker: true), let size = vint(&p, keepMarker: false) {
                let end = size == UInt64.max ? to : min(to, p &+ Int(clamping: size))
                switch tag {
                case 0x18538067, 0x1654AE6B, 0x1F43B675: // Segment, Tracks, Cluster: their children are read right here
                    continue
                case 0x1549A966: // Info
                    var q = p, raw: Double?
                    while q < end, let t = vint(&q, keepMarker: true), let s = vint(&q, keepMarker: false) {
                        let e = min(end, q &+ Int(clamping: s))
                        if t == 0x2AD7B1 { scale = Double(uint(q, e)) }
                        if t == 0x4489 { raw = float(q, e) }
                        q = e
                    }
                    if let raw { duration = raw * scale / 1e9 }
                case 0xAE: walkTrack(p, end)
                case 0xE7: clusterTime = Double(uint(p, end))
                case 0xA3: block(p, end, simple: true, hasReference: false)
                case 0xA0: // BlockGroup
                    var q = p, range: (Int, Int)?, referenced = false
                    while q < end, let t = vint(&q, keepMarker: true), let s = vint(&q, keepMarker: false) {
                        let e = min(end, q &+ Int(clamping: s))
                        if t == 0xA1 { range = (q, e) }
                        if t == 0xFB { referenced = true }
                        q = e
                    }
                    if let range { block(range.0, range.1, simple: false, hasReference: referenced) }
                default: break
                }
                p = end
            }
        }
        walk(0, d.count)
        guard let codec, !frames.isEmpty else { return nil }
        frames.sort { $0.time < $1.time }
        return Parsed(codec: codec, width: width, height: height, duration: duration, frames: frames)
    }

    // MARK: decoding, in WebKit

    private static let page = """
    <!doctype html><script>
    let dec, ready = [], failure = null, canvas, ctx;
    const b64 = (u) => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };
    const take = () => JSON.stringify(ready.splice(0));
    async function start(codecs, width, height) {
      dec = new VideoDecoder({
        output: (f) => {
          const w = f.displayWidth, h = f.displayHeight, t = f.timestamp / 1e6;
          if (!canvas || canvas.width !== w || canvas.height !== h) { canvas = new OffscreenCanvas(w, h); ctx = canvas.getContext('2d', { willReadFrequently: true }); }
          ctx.drawImage(f, 0, 0); f.close();
          const d = ctx.getImageData(0, 0, w, h).data;
          ready.push({ t, w, h, d: b64(new Uint8Array(d.buffer, d.byteOffset, d.byteLength)) });
        },
        error: (e) => { failure = String(e); },
      });
      for (const codec of codecs) {
        const config = { codec, codedWidth: width, codedHeight: height };
        if ((await VideoDecoder.isConfigSupported(config)).supported) { dec.configure(config); return codec; }
      }
      throw new Error('no decoder');
    }
    async function put(data, time, key) {
      if (failure) throw new Error(failure);
      const raw = atob(data), u = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) u[i] = raw.charCodeAt(i);
      dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: time, data: u }));
      while (dec.decodeQueueSize > 4) await new Promise((r) => setTimeout(r, 2));
      await new Promise((r) => setTimeout(r));
      return take();
    }
    async function finish() {
      await dec.flush(); dec.close();
      if (failure) throw new Error(failure);
      return take();
    }
    </script>
    """

    private static func candidates(_ codec: String) -> [String]? {
        switch codec {
        case "V_VP9": ["vp09.00.41.08", "vp09.00.61.08", "vp09.02.41.10"]
        case "V_VP8": ["vp8"]
        case "V_AV1": ["av01.0.08M.08", "av01.0.13M.08", "av01.0.08M.10"]
        default: nil
        }
    }

    // MARK: the temporary movie

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("GIFMaker-imports") }

    /// Removes the temporary movie behind a source, once nothing uses it any more.
    static func discard(_ source: (any MediaSource)?) {
        guard let url = source?.url, url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Decoded: Decodable { var t: Double; var w: Int; var h: Int; var d: String }

    static func importToMovie(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let parsed = parse(data) else {
            throw MediaError.unreadable(name)
        }
        guard let codecs = candidates(parsed.codec) else { throw MediaError.failed("\(name) uses \(parsed.codec), which this app can’t decode.") }
        let worker = try WebKitWorker(page: page)
        do { _ = try worker.call("return await start(codecs, width, height);", ["codecs": codecs, "width": parsed.width, "height": parsed.height]) }
        catch { throw MediaError.failed("This Mac’s WebKit can’t decode \(name).") }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("\(UUID().uuidString).mov")
        var movie: Movie?
        let first = parsed.frames[0].time
        let gap = parsed.frames.count > 1 ? parsed.frames[1].time - first : 1.0 / 30

        func write(_ json: Any?) throws {
            guard let text = json as? String else { return }
            for frame in try JSONDecoder().decode([Decoded].self, from: Data(text.utf8)) {
                guard let rgba = Data(base64Encoded: frame.d) else { continue }
                if movie == nil { movie = try Movie(url: out, width: frame.w, height: frame.h) }
                try movie?.add(rgba: rgba, sourceWidth: frame.w, time: frame.t - first)
            }
        }
        do {
            for (i, f) in parsed.frames.enumerated() {
                try write(try worker.call("return await put(data, time, key);",
                    ["data": f.data.base64EncodedString(), "time": Int(f.time * 1e6), "key": f.key]))
                progress(Double(i + 1) / Double(parsed.frames.count))
            }
            try write(try worker.call("return await finish();", [:]))
            guard let movie else { throw MediaError.unreadable(name) }
            try movie.finish(end: (parsed.frames.last?.time ?? first) - first + gap)
        } catch {
            movie?.cancel()
            try? FileManager.default.removeItem(at: out)
            if let e = error as? MediaError { throw e }
            throw MediaError.unreadable(name)
        }
        return out
    }

    /// A ProRes movie: close to lossless, and fast to scrub.
    private final class Movie {
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let width: Int, height: Int

        init(url: URL, width sourceWidth: Int, height sourceHeight: Int) throws {
            // ProRes wants even sizes
            width = max(2, sourceWidth & ~1); height = max(2, sourceHeight & ~1)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? MediaError.failed("Can’t prepare this WebM.") }
            writer.startSession(atSourceTime: .zero)
        }

        func add(rgba: Data, sourceWidth: Int, time: Double) throws {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? MediaError.failed("Can’t prepare this WebM.") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? MediaError.failed("Can’t prepare this WebM.") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw MediaError.failed("Out of memory.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: UInt8.self).baseAddress!
                for y in 0..<height {
                    let from = src + y * sourceWidth * 4, to = base + y * stride
                    for x in 0..<width {
                        to[x * 4] = from[x * 4 + 2]; to[x * 4 + 1] = from[x * 4 + 1]; to[x * 4 + 2] = from[x * 4]; to[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: max(0, time), preferredTimescale: 60_000)) else {
                throw writer.error ?? MediaError.failed("Can’t prepare this WebM.")
            }
        }

        func cancel() { if writer.status == .writing { writer.cancelWriting() } }

        func finish(end: Double) throws {
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 60_000))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            if writer.status != .completed { throw writer.error ?? MediaError.failed("Can’t prepare this WebM.") }
        }
    }
}
