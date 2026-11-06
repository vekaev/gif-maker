import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum MediaError: LocalizedError {
    case unreadable(String), cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Can’t open \(name). Try an MP4, MOV, GIF or a photo."
        case .cancelled: "Cancelled."
        case .failed(let why): why
        }
    }
}

/// A video, GIF or photo, as far as editing and exporting are concerned.
protocol MediaSource: AnyObject {
    var url: URL { get }
    var size: CGSize { get }
    var duration: Double { get }
    /// Calls `body` once per time (ascending) with the frame showing then. Reads in order, decoding each
    /// frame once; seeking per frame is what makes exports crawl.
    func read(times: [Double], body: (Int, CIImage) throws -> Void) throws
    /// Evenly spaced stills for the timeline.
    func thumbnails(count: Int, height: CGFloat, each: @escaping (Int, CGImage) -> Void) async
}

/// Any file AVFoundation plays: MP4, MOV, HEVC, M4V.
final class VideoSource: MediaSource {
    let url: URL
    let asset: AVURLAsset
    let size: CGSize
    let duration: Double
    private let track: AVAssetTrack
    private let orientation: CGImagePropertyOrientation
    private let isHDR: Bool

    init(url: URL) async throws {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unreadable(url.lastPathComponent)
        }
        self.track = track
        let (natural, transform, length) = try await (track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration))
        orientation = Self.orientation(transform)
        let transfer = (try await track.load(.formatDescriptions).first).flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        isHDR = transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let turned = orientation == .left || orientation == .right
        size = turned ? CGSize(width: natural.height, height: natural.width) : natural
        duration = length.seconds
        guard size.width > 0, duration > 0 else { throw MediaError.unreadable(url.lastPathComponent) }
    }

    private static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0, t.b == 1, t.c == -1, t.d == 0 { return .right }
        if t.a == 0, t.b == -1, t.c == 1, t.d == 0 { return .left }
        if t.a == -1, t.d == -1 { return .down }
        return .up
    }

    func oriented(_ buffer: CVPixelBuffer) -> CIImage {
        // Ordinary video keeps its values as they are, the way browsers and ffmpeg treat it, so an export looks
        // like the source. Converting BT.709's transfer curve to sRGB would lift the midtones. HDR does need converting.
        var options: [CIImageOption: Any] = [.applyOrientationProperty: false]
        if !isHDR { options[.colorSpace] = NSNull() }
        let image = CIImage(cvPixelBuffer: buffer, options: options)
        return orientation == .up ? image : image.oriented(orientation)
    }

    func read(times: [Double], body: (Int, CIImage) throws -> Void) throws {
        guard let first = times.first else { return }
        let reader = try AVAssetReader(asset: asset)
        // a little before the first frame, so the frame covering that moment is included
        let from = max(0, first - 0.5)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaError.failed("This video can’t be read.")
        }
        defer { reader.cancelReading() }

        func next() -> (buffer: CVPixelBuffer, time: Double)? {
            while let sample = output.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    return (buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
            }
            return nil
        }
        var current: (buffer: CVPixelBuffer, time: Double)?
        var coming = next()
        for (i, t) in times.enumerated() {
            try autoreleasepool {
                while let c = coming, c.time <= t + 1e-4 {
                    current = c
                    coming = next()
                }
                guard let frame = current ?? coming else {
                    throw reader.error ?? MediaError.failed("This video ended early.")
                }
                try body(i, oriented(frame.buffer))
            }
        }
    }

    func thumbnails(count: Int, height: CGFloat, each: @escaping (Int, CGImage) -> Void) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        // nearest keyframe within half a slot: a filmstrip doesn't need to be frame-exact, and this is far faster
        let tolerance = CMTime(seconds: duration / Double(max(count, 1)) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        for i in 0..<count {
            if Task.isCancelled { return }
            let t = CMTime(seconds: (Double(i) + 0.5) / Double(count) * duration, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: t) { each(i, image) }
        }
    }
}

/// A GIF, animated WebP / PNG (each frame keeps its own timing), or a still photo, which becomes a 3-second clip.
final class ImageSource: MediaSource {
    static let photoSeconds = 3.0

    let url: URL
    let size: CGSize
    let duration: Double
    private let source: CGImageSource
    private let starts: [Double]
    private let orientation: CGImagePropertyOrientation
    private var cached: (index: Int, image: CIImage)?
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { throw MediaError.unreadable(url.lastPathComponent) }
        self.source = source
        let n = CGImageSourceGetCount(source)
        var starts: [Double] = [], t = 0.0
        for i in 0..<n {
            starts.append(t)
            t += Self.delay(source, i)
        }
        self.starts = starts
        duration = n == 1 ? Self.photoSeconds : t
        let raw = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        size = raw >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Viewers play delays of 0–10 ms as 100 ms, so this does too.
    private static func delay(_ source: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else { return 0.1 }
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dict, unclamped, clamped) in dictionaries {
            if let d = props[dict] as? [CFString: Any], let v = (d[unclamped] ?? d[clamped]) as? Double {
                return v > 0.011 ? v : 0.1
            }
        }
        return 0.1
    }

    func index(at t: Double) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t + 1e-6 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func image(at t: Double) -> CIImage? {
        let i = index(at: t)
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.index == i { return cached.image }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let cg = CGImageSourceCreateImageAtIndex(source, i, options) else { return nil }
        let image = CIImage(cgImage: cg).oriented(orientation)
        cached = (i, image)
        return image
    }

    func read(times: [Double], body: (Int, CIImage) throws -> Void) throws {
        for (i, t) in times.enumerated() {
            try autoreleasepool {
                guard let image = image(at: t) else { throw MediaError.failed("This image can’t be read.") }
                try body(i, image)
            }
        }
    }

    func thumbnails(count: Int, height: CGFloat, each: @escaping (Int, CGImage) -> Void) async {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: height * 4] as CFDictionary
        for i in 0..<count {
            if Task.isCancelled { return }
            let t = (Double(i) + 0.5) / Double(count) * duration
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, index(at: t), options) { each(i, cg) }
        }
    }
}

enum Media {
    /// Opens anything the app can edit. Images by their type, everything else as video.
    static func open(_ url: URL) async throws -> any MediaSource {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return try ImageSource(url: url) }
        do { return try await VideoSource(url: url) }
        catch { throw MediaError.unreadable(url.lastPathComponent) }
    }
}
