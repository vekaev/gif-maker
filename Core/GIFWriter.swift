import Foundation

/// Writes GIFs the careful way: one palette for the whole clip (colours don't jump between frames), exact
/// nearest-colour matching (no contour lines), Bayer dithering (a pattern that stays still from frame to
/// frame, unlike error diffusion, which boils), every grey level for black-and-white looks, and delays that
/// keep the clip's real length. Same choices as the web version.
final class GIFWriter {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    private var out = Data()
    private let width: Int, height: Int, fps: Int, dither: Bool
    private let palette: [RGB]
    private var frameIndex = 0
    private var cache = [Int16](repeating: -1, count: 1 << 21)   // nearest palette entry, 7 bits per channel
    private let flatPalette: [Int32]
    private var indices: [UInt8]

    private static let bayer: [Int32] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]

    init(width: Int, height: Int, fps: Int, palette: [RGB], dither: Bool) {
        (self.width, self.height, self.fps, self.dither) = (width, height, fps, dither)
        var full = palette
        while full.count < 256 { full.append((0, 0, 0)) }   // the table's size is a power of two
        self.palette = full
        flatPalette = palette.flatMap { [Int32($0.r), Int32($0.g), Int32($0.b)] }
        indices = [UInt8](repeating: 0, count: width * height)
        out.reserveCapacity(1 << 22)
        out.append(contentsOf: Array("GIF89a".utf8))
        put16(width); put16(height)
        out.append(0xF7)   // a global table of 256 colours
        out.append(0); out.append(0)
        for c in full { out.append(c.r); out.append(c.g); out.append(c.b) }
        out.append(contentsOf: [0x21, 0xFF, 0x0B])                   // loop forever
        out.append(contentsOf: Array("NETSCAPE2.0".utf8))
        out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// A palette of all 256 grey levels, tinted the way the look asks. The index of a pixel is its grey value.
    static func greyPalette(_ adjustments: Adjustments) -> [RGB] {
        let tint = adjustments.look.recipe.tint
        return (0..<256).map { i in
            let v = Double(i), mid = 4 * (v / 255) * (1 - v / 255)
            func c(_ t: Double) -> UInt8 { UInt8(max(0, min(255, (v + t * mid).rounded()))) }
            return (c(tint.0), c(tint.1), c(tint.2))
        }
    }

    /// Median cut over a sample of pixels from across the clip (RGBA bytes).
    static func palette(from rgba: UnsafeBufferPointer<UInt8>, colors: Int = 256) -> [RGB] {
        var counts = [UInt32](repeating: 0, count: 1 << 18)   // 6 bits per channel
        var i = 0
        while i < rgba.count {
            let k = Int(rgba[i] >> 2) << 12 | Int(rgba[i + 1] >> 2) << 6 | Int(rgba[i + 2] >> 2)
            counts[k] &+= 1
            i += 4
        }
        var bins = [Int32]()
        for (k, n) in counts.enumerated() where n > 0 { bins.append(Int32(k)) }
        guard !bins.isEmpty else { return [(0, 0, 0)] }

        func value(_ bin: Int32, _ channel: Int) -> Int { Int(bin >> Int32(12 - channel * 6)) & 63 }
        struct Box { var items: ArraySlice<Int32>; var weight: UInt64; var spread: Int; var channel: Int }
        func box(_ items: ArraySlice<Int32>) -> Box {
            var lo = [63, 63, 63], hi = [0, 0, 0], weight: UInt64 = 0
            for b in items {
                weight += UInt64(counts[Int(b)])
                for c in 0..<3 { let v = value(b, c); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v) }
            }
            let spreads = (0..<3).map { hi[$0] - lo[$0] }
            let channel = spreads[1] >= spreads[0] && spreads[1] >= spreads[2] ? 1 : (spreads[0] >= spreads[2] ? 0 : 2)
            return Box(items: items, weight: weight, spread: spreads[channel], channel: channel)
        }
        var boxes = [box(bins[...])]
        while boxes.count < colors {
            // split the box with the most pixels × spread; a single-colour box can't be split
            guard let at = boxes.indices.filter({ boxes[$0].items.count > 1 && boxes[$0].spread > 0 })
                .max(by: { Double(boxes[$0].weight) * Double(boxes[$0].spread) < Double(boxes[$1].weight) * Double(boxes[$1].spread) })
            else { break }
            let b = boxes[at]
            let sorted = b.items.sorted { value($0, b.channel) < value($1, b.channel) }
            var seen: UInt64 = 0, cut = 0
            for (i, item) in sorted.enumerated() {
                seen += UInt64(counts[Int(item)])
                if seen * 2 >= b.weight { cut = i + 1; break }
            }
            cut = max(1, min(sorted.count - 1, cut))
            boxes[at] = box(Array(sorted[..<cut])[...])
            boxes.append(box(Array(sorted[cut...])[...]))
        }
        return boxes.map { b in
            // the pixel-weighted mean of the bin centres
            var r: UInt64 = 0, g: UInt64 = 0, bl: UInt64 = 0, total: UInt64 = 0
            for item in b.items {
                let n = UInt64(counts[Int(item)])
                r += UInt64(value(item, 0) * 4 + 2) * n; g += UInt64(value(item, 1) * 4 + 2) * n; bl += UInt64(value(item, 2) * 4 + 2) * n
                total += n
            }
            return (UInt8(min(255, r / total)), UInt8(min(255, g / total)), UInt8(min(255, bl / total)))
        }
    }

    /// Adds a frame of tightly packed RGBA. `grey`: the picture is neutral grey, its value is the palette index.
    func add(rgba: UnsafePointer<UInt8>, grey: Bool) {
        if grey { for i in 0..<(width * height) { indices[i] = rgba[i * 4] } }
        else { mapToPalette(rgba) }
        // delays are whole hundredths of a second; rounding the timestamps, not the delays, keeps the length
        let centi = Int((Double(frameIndex + 1) * 100 / Double(fps)).rounded()) - Int((Double(frameIndex) * 100 / Double(fps)).rounded())
        out.append(contentsOf: [0x21, 0xF9, 0x04, 0x00])
        put16(centi)
        out.append(0); out.append(0)
        out.append(0x2C)
        put16(0); put16(0); put16(width); put16(height)
        out.append(0)
        writeLZW()
        frameIndex += 1
    }

    func finish() -> Data {
        out.append(0x3B)
        return out
    }

    private func put16(_ v: Int) { out.append(UInt8(v & 255)); out.append(UInt8((v >> 8) & 255)) }

    private func mapToPalette(_ rgba: UnsafePointer<UInt8>) {
        let spread: Int32 = dither ? 14 : 0, n = flatPalette.count / 3
        let w = width
        cache.withUnsafeMutableBufferPointer { cache in
            flatPalette.withUnsafeBufferPointer { pal in
                indices.withUnsafeMutableBufferPointer { index in
                    Self.bayer.withUnsafeBufferPointer { bayer in
                        for y in 0..<height {
                            let row = y & 7
                            for x in 0..<w {
                                let p = (y * w + x) * 4
                                let t = spread == 0 ? 0 : (bayer[row * 8 + (x & 7)] * 2 - 63) * spread / 128
                                let r = max(0, min(255, Int32(rgba[p]) + t))
                                let g = max(0, min(255, Int32(rgba[p + 1]) + t))
                                let b = max(0, min(255, Int32(rgba[p + 2]) + t))
                                let key = Int(r >> 1) << 14 | Int(g >> 1) << 7 | Int(b >> 1)
                                var c = cache[key]
                                if c < 0 {
                                    var best = Int32.max
                                    for q in 0..<n {
                                        let dr = r - pal[q * 3], dg = g - pal[q * 3 + 1], db = b - pal[q * 3 + 2]
                                        let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                                        if d < best { best = d; c = Int16(q) }
                                    }
                                    cache[key] = c
                                }
                                index[y * w + x] = UInt8(c)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The GIF flavour of LZW, with a hash table for the dictionary.
    private func writeLZW() {
        let minCode = 8, clear = 1 << minCode, end = clear + 1
        out.append(UInt8(minCode))
        var block = [UInt8](), bits = 0, bitCount = 0
        block.reserveCapacity(255)
        func emit(_ code: Int, _ size: Int) {
            bits |= code << bitCount
            bitCount += size
            while bitCount >= 8 {
                block.append(UInt8(bits & 255))
                bits >>= 8; bitCount -= 8
                if block.count == 255 { out.append(255); out.append(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
        }
        let tableSize = 5003
        var keys = [Int32](repeating: -1, count: tableSize), values = [Int32](repeating: 0, count: tableSize)
        var next = end + 1, codeSize = minCode + 1
        emit(clear, codeSize)
        var prefix = Int(indices[0])
        indices.withUnsafeBufferPointer { px in
            for i in 1..<px.count {
                let c = Int(px[i]), key = Int32(prefix << 8 | c)
                let hash = (c << 4) ^ prefix
                var h = hash % tableSize
                let step = 1 + hash % (tableSize - 1)   // the table's size is prime, so this visits every slot
                var found = false
                while keys[h] >= 0 {
                    if keys[h] == key { prefix = Int(values[h]); found = true; break }
                    h = (h + step) % tableSize
                }
                if found { continue }
                emit(prefix, codeSize)
                if next < 4096 {
                    if next == 1 << codeSize, codeSize < 12 { codeSize += 1 }
                    keys[h] = key; values[h] = Int32(next); next += 1
                } else {
                    emit(clear, codeSize)
                    for k in 0..<tableSize { keys[k] = -1 }
                    next = end + 1; codeSize = minCode + 1
                }
                prefix = c
            }
        }
        emit(prefix, codeSize)
        emit(end, codeSize)
        if bitCount > 0 { block.append(UInt8(bits & 255)) }
        if !block.isEmpty { out.append(UInt8(block.count)); out.append(contentsOf: block) }
        out.append(0)
    }
}
