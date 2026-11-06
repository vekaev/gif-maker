import AVFoundation
import CoreImage
import WebKit

/// H.264 MP4 through VideoToolbox (the hardware encoder), optionally with a silent AAC track: Telegram
/// sends a video without any sound track as a GIF, and one with a track as a regular video.
final class MP4Writer {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let fps: Int
    private var written = 0
    private var audioWritten = 0
    private let audioFormat: CMAudioFormatDescription?
    private static let sampleRate = 48_000, audioBlock = 1024

    init(url: URL, width: Int, height: Int, fps: Int, silentTrack: Bool) throws {
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * 0.2))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(video)
        if silentTrack {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
            var desc = AudioStreamBasicDescription(mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
                mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &desc, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            audioFormat = format
        } else { audio = nil; audioFormat = nil }
        guard writer.startWriting() else { throw writer.error ?? MediaError.failed("Can’t write this file.") }
        writer.startSession(atSourceTime: .zero)
    }

    private func wait(_ input: AVAssetWriterInput) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? MediaError.failed("Writing the video failed.") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// As much silence up to `seconds` as the writer will take right now. It never waits: the writer holds
    /// each track back until the other has caught up, so waiting here would deadlock with the picture.
    private func writeSilence(upTo seconds: Double) throws {
        guard let audio, let audioFormat else { return }
        let target = Int(seconds * Double(Self.sampleRate))
        while audioWritten < target, audio.isReadyForMoreMediaData {
            let count = Self.audioBlock, bytes = count * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw MediaError.failed("Writing the sound track failed.") }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(audioWritten), timescale: CMTimeScale(Self.sampleRate)), packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, audio.append(sample) else { throw writer.error ?? MediaError.failed("Writing the sound track failed.") }
            audioWritten += count
        }
    }

    func add(_ image: CIImage) throws {
        let time = Double(written + 1) / Double(fps)
        while !video.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? MediaError.failed("Writing the video failed.") }
            // the sound runs ahead of the picture, or the writer keeps waiting for it (AAC holds back a little
            // to begin with); the end of the session cuts off whatever is left over
            try writeSilence(upTo: time + 2)
            if !video.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        }
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? MediaError.failed("Writing the video failed.") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw MediaError.failed("Out of memory.") }
        Renderer.shared.context.render(image, to: buffer, bounds: image.extent, colorSpace: Renderer.shared.srgb)
        // the values go in as they are, tagged the way they'll be read back, so the encoder doesn't convert them
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(fps))) else {
            throw writer.error ?? MediaError.failed("Writing the video failed.")
        }
        written += 1
    }

    /// For an export that stops early.
    func cancel() { if writer.status == .writing { writer.cancelWriting() } }

    func finish() throws {
        video.markAsFinished()
        if let audio {
            let end = Double(written) / Double(fps)
            while Double(audioWritten) / Double(Self.sampleRate) < end {
                try wait(audio)
                try writeSilence(upTo: end)
            }
            audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(fps)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? MediaError.failed("Writing the video failed.") }
    }
}

/// A hidden web view for what only WebKit can do on a Mac: VP9 through WebCodecs. It runs on the main thread;
/// call this from a background one.
final class WebKitWorker: NSObject {
    private var web: WKWebView?
    private var delegate: Loaded?

    private final class Loaded: NSObject, WKNavigationDelegate {
        let done: DispatchSemaphore
        init(_ done: DispatchSemaphore) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.signal() }
    }

    init(page: String) throws {
        super.init()
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let config = WKWebViewConfiguration()
            config.preferences.inactiveSchedulingPolicy = .none   // keep working while the app is in the background
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
            let delegate = Loaded(ready)
            web.navigationDelegate = delegate
            self.delegate = delegate
            self.web = web
            web.loadHTMLString(page, baseURL: URL(string: "https://gifmaker.local/"))   // WebCodecs needs a secure context
        }
        guard ready.wait(timeout: .now() + 30) != .timedOut else { throw MediaError.failed("WebKit didn’t start.") }
    }

    // WebKit objects have to go away on the main thread, also when the work stops early
    deinit {
        let (web, delegate) = (web, delegate)
        DispatchQueue.main.async { _ = web; _ = delegate }
    }

    func call(_ js: String, _ args: [String: Any]) throws -> Any? {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Any?, Error> = .success(nil)
        DispatchQueue.main.async {
            self.web?.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { r in
                switch r {
                case .success(let v): result = .success(v)
                case .failure(let e): result = .failure(e)
                }
                done.signal()
            }
        }
        if done.wait(timeout: .now() + 120) == .timedOut { throw MediaError.failed("WebKit stopped responding.") }
        return try result.get()
    }
}

/// macOS has no public VP9 encoder, but WebKit does, through WebCodecs. Telegram video stickers must be VP9.
final class VP9Encoder: NSObject {
    struct Chunk { var time: Double; var key: Bool; var data: Data }

    private static let page = """
    <!doctype html><script>
    let enc, chunks, failure = null, dims;
    const b64 = (u) => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };
    async function start(width, height, fps, bitrate) {
      chunks = []; failure = null; dims = { width, height };
      enc = new VideoEncoder({
        output: (c) => { const u = new Uint8Array(c.byteLength); c.copyTo(u); chunks.push({ t: c.timestamp / 1e6, k: c.type === 'key', d: b64(u) }); },
        error: (e) => { failure = String(e); },
      });
      for (const codec of ['vp09.00.41.08', 'vp09.00.31.08', 'vp09.00.10.08']) {
        const config = { codec, width, height, bitrate, framerate: fps, latencyMode: 'quality' };
        if ((await VideoEncoder.isConfigSupported(config)).supported) { enc.configure(config); return codec; }
      }
      throw new Error('no VP9 encoder');
    }
    async function frame(data, time, duration, key) {
      if (failure) throw new Error(failure);
      const raw = atob(data), u = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) u[i] = raw.charCodeAt(i);
      const f = new VideoFrame(u, { format: 'RGBA', codedWidth: dims.width, codedHeight: dims.height, timestamp: time, duration });
      enc.encode(f, { keyFrame: key });
      f.close();
      while (enc.encodeQueueSize > 4) await new Promise((r) => setTimeout(r, 2));
      return true;
    }
    async function finish() {
      await enc.flush(); enc.close();
      if (failure) throw new Error(failure);
      return JSON.stringify(chunks);
    }
    </script>
    """

    private var worker: WebKitWorker?

    func start(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        worker = try WebKitWorker(page: Self.page)
        do { _ = try worker?.call("return await start(width, height, fps, bitrate);", ["width": width, "height": height, "fps": fps, "bitrate": bitrate]) }
        catch { throw MediaError.failed("This Mac’s WebKit can’t encode VP9, which WebM and Telegram stickers need. MP4 and GIF still work.") }
    }

    func add(rgba: Data, time: Double, duration: Double, key: Bool) throws {
        _ = try worker?.call("return await frame(data, time, duration, key);",
                     ["data": rgba.base64EncodedString(), "time": Int(time * 1e6), "duration": Int(duration * 1e6), "key": key])
    }

    func finish() throws -> [Chunk] {
        let json = try worker?.call("return await finish();", [:]) as? String ?? "[]"
        struct Raw: Decodable { var t: Double; var k: Bool; var d: String }
        let raw = try JSONDecoder().decode([Raw].self, from: Data(json.utf8))
        worker = nil
        return raw.map { Chunk(time: $0.t, key: $0.k, data: Data(base64Encoded: $0.d) ?? Data()) }
    }
}

/// A minimal WebM (Matroska) file: one VP9 video track, clusters and a seek index.
enum WebM {
    static func file(chunks: [VP9Encoder.Chunk], width: Int, height: Int, duration: Double, frameSeconds: Double) -> Data {
        func size(_ n: Int) -> Data {   // an 8-byte EBML size is always valid and keeps offsets simple
            var d = Data([0x01]); for shift in stride(from: 48, through: 0, by: -8) { d.append(UInt8((n >> shift) & 255)) }
            return d
        }
        func el(_ id: [UInt8], _ body: Data) -> Data { Data(id) + size(body.count) + body }
        func uint(_ id: [UInt8], _ v: Int) -> Data {
            var b = [UInt8](); var x = v
            repeat { b.insert(UInt8(x & 255), at: 0); x >>= 8 } while x > 0
            return el(id, Data(b))
        }
        func str(_ id: [UInt8], _ s: String) -> Data { el(id, Data(s.utf8)) }
        func float(_ id: [UInt8], _ v: Double) -> Data {
            var bits = v.bitPattern.bigEndian
            return el(id, withUnsafeBytes(of: &bits) { Data($0) })
        }

        let header = el([0x1A, 0x45, 0xDF, 0xA3],
            uint([0x42, 0x86], 1) + uint([0x42, 0xF7], 1) + uint([0x42, 0xF2], 4) + uint([0x42, 0xF3], 8) +
            str([0x42, 0x82], "webm") + uint([0x42, 0x87], 4) + uint([0x42, 0x85], 2))
        let info = el([0x15, 0x49, 0xA9, 0x66],
            uint([0x2A, 0xD7, 0xB1], 1_000_000) + str([0x4D, 0x80], "GIF Maker") + str([0x57, 0x41], "GIF Maker") + float([0x44, 0x89], duration * 1000))
        let videoSettings = el([0xE0], uint([0xB0], width) + uint([0xBA], height))
        let tracks = el([0x16, 0x54, 0xAE, 0x6B], el([0xAE],
            uint([0xD7], 1) + uint([0x73, 0xC5], 1) + uint([0x83], 1) + uint([0x9C], 0) + str([0x86], "V_VP9") +
            uint([0x23, 0xE3, 0x83], Int(frameSeconds * 1e9)) + videoSettings))

        var clusters = Data(), cuePoints: [(time: Int, offset: Int)] = []
        let prefix = info.count + tracks.count
        var i = 0
        while i < chunks.count {
            // a new cluster at each keyframe, or before block times would overflow
            let start = Int((chunks[i].time * 1000).rounded())
            var body = uint([0xE7], start), j = i
            while j < chunks.count {
                let c = chunks[j], t = Int((c.time * 1000).rounded()) - start
                if j > i, c.key || t > 30_000 { break }
                var block = Data([0x81, UInt8((t >> 8) & 255), UInt8(t & 255), c.key ? 0x80 : 0x00])
                block.append(c.data)
                body += el([0xA3], block)
                j += 1
            }
            if chunks[i].key { cuePoints.append((start, prefix + clusters.count)) }
            clusters += el([0x1F, 0x43, 0xB6, 0x75], body)
            i = j
        }
        var cueBody = Data()
        for c in cuePoints {
            cueBody += el([0xBB], uint([0xB3], c.time) + el([0xB7], uint([0xF7], 1) + uint([0xF1], c.offset)))
        }
        let cues = el([0x1C, 0x53, 0xBB, 0x6B], cueBody)
        return header + el([0x18, 0x53, 0x80, 0x67], info + tracks + clusters + cues)
    }
}
