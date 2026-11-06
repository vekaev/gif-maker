import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Crop, scale and colour with Core Image, on the GPU. The working space is plain sRGB so the numbers in
/// `Adjustments` mean what they mean in the web version.
final class Renderer {
    static let shared = Renderer()
    let device = MTLCreateSystemDefaultDevice()
    let context: CIContext
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private let cubeDimension = 48
    private var cube: (key: Adjustments, tinted: Bool, data: Data)?
    private let lock = NSLock()

    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false]
        context = device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }

    /// The colour step as a 3D table built from `Adjustments.apply`. Rebuilt only when a slider moved.
    private func cubeData(_ adjustments: Adjustments, tinted: Bool) -> Data {
        var key = adjustments
        key.grain = 0
        lock.lock(); defer { lock.unlock() }
        if let cube, cube.key == key, cube.tinted == tinted { return cube.data }
        let n = cubeDimension
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Double(n - 1)
        values.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { b in
                let base = b * n * n * 4
                for g in 0..<n {
                    for r in 0..<n {
                        let (x, y, z) = key.apply(Double(r) * step, Double(g) * step, Double(b) * step, tinted: tinted)
                        let i = base + (g * n + r) * 4
                        out[i] = Float(x); out[i + 1] = Float(y); out[i + 2] = Float(z)
                    }
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cube = (key, tinted, data)
        return data
    }

    /// `crop` is in source pixels with the origin at the top left.
    func cropped(_ image: CIImage, crop: CGRect) -> CIImage {
        let e = image.extent
        let rect = CGRect(x: e.minX + crop.minX, y: e.maxY - crop.maxY, width: crop.width, height: crop.height)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Scales a picture whose origin is at (0, 0) to exactly `size` pixels.
    func scaled(_ image: CIImage, to size: CGSize, highQuality: Bool) -> CIImage {
        let e = image.extent
        guard e.width != size.width || e.height != size.height else { return image }
        let target = CGRect(origin: .zero, size: size)
        if highQuality {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image.clampedToExtent().cropped(to: e.insetBy(dx: -8, dy: -8))
            f.scale = Float(size.height / e.height)
            f.aspectRatio = Float((size.width / e.width) / (size.height / e.height))
            if let out = f.outputImage { return out.cropped(to: target) }
        }
        return image.transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height), highQualityDownsample: true)
            .cropped(to: target)
    }

    func colored(_ image: CIImage, _ adjustments: Adjustments, seed: Int = 1, tinted: Bool = true) -> CIImage {
        var out = image
        if !adjustments.isNeutral {
            let f = CIFilter.colorCube()
            f.inputImage = out
            f.cubeDimension = Float(cubeDimension)
            f.cubeData = cubeData(adjustments, tinted: tinted)
            out = f.outputImage ?? out
        }
        guard adjustments.grain > 0 else { return out }
        // film-like noise: the same amount on all channels, centred on zero
        let amount = CGFloat(adjustments.grain * 0.8 / 255)
        let shift = CGAffineTransform(translationX: CGFloat(seed &* 7919 % 4096), y: CGFloat(seed &* 104_729 % 4096))
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = CIFilter.randomGenerator().outputImage?.transformed(by: shift)
        let v = CIVector(x: 2 * amount, y: 0, z: 0, w: 0)
        matrix.rVector = v; matrix.gVector = v; matrix.bVector = v
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: -amount, y: -amount, z: -amount, w: 0)
        guard let noise = matrix.outputImage?.cropped(to: out.extent) else { return out }
        let add = CIFilter.additionCompositing()
        add.inputImage = noise
        add.backgroundImage = out
        return add.outputImage ?? out
    }

    /// The finished frame of an export.
    func frame(_ source: CIImage, crop: CGRect, size: CGSize, adjustments: Adjustments, seed: Int, tinted: Bool = true) -> CIImage {
        colored(scaled(cropped(source, crop: crop), to: size, highQuality: true), adjustments, seed: seed, tinted: tinted)
    }

    /// Renders to tightly packed RGBA.
    func rgba(_ image: CIImage, width: Int, height: Int, into data: UnsafeMutableRawPointer) {
        context.render(image, toBitmap: data, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: srgb)
    }

    func cgImage(_ image: CIImage) -> CGImage? { context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb) }
}
