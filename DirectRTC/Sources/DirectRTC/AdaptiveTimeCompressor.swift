import Foundation

// Mono PCM16 at 24 kHz. Removes pitch-aligned spans with normalized correlation
// and a 20 ms overlap. This changes duration, not playback sample rate/pitch.
struct AdaptiveTimeCompressor {
    private var credit = 0.0
    private(set) var removedSamples = 0
    private(set) var acceleratedFrames = 0
    private(set) var correlationMisses = 0
    mutating func reset() { credit = 0 }
    mutating func lookahead(rate: Double) -> Int {
        guard rate > 1 else { credit = 0; return 0 }
        credit = min(960, credit + 480 * min(0.10, rate - 1))
        return credit >= 48 ? min(480, Int(credit)) : 0
    }
    mutating func process(_ input: Data, maximumSkip: Int) -> (output: Data, consumedBytes: Int) {
        let count = input.count / 2
        let limit = min(maximumSkip, count - 480)
        guard limit >= 48 else { return (Data(input.prefix(960)), 960) }
        var bestLag = 0, bestScore = -1.0
        input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func sample(_ i: Int) -> Double { Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) }
            func correlation(_ lag: Int) -> Double {
                var sx = 0.0, sy = 0.0, xx = 0.0, yy = 0.0, xy = 0.0
                for i in stride(from: 0, to: 480, by: 4) {
                    let x = sample(i), y = sample(i + lag)
                    sx += x; sy += y; xx += x*x; yy += y*y; xy += x*y
                }
                let ex = xx - sx*sx/120, ey = yy - sy*sy/120
                if ex < 120 && ey < 120 { return 1 }
                if ex < 120 || ey < 120 { return -1 } // Near silence can safely lose duration.
                return (xy - sx*sy/120) / sqrt(ex*ey)
            }
            for lag in stride(from: 48, through: limit, by: 4) {
                let score = correlation(lag)
                if score > bestScore + 0.002 { bestScore = score; bestLag = lag }
            }
            guard bestLag > 0 else { return }
            let center = bestLag
            for lag in max(48, center - 3)...min(limit, center + 3) {
                let score = correlation(lag)
                if score > bestScore + 0.00001 { bestScore = score; bestLag = lag }
            }
        }
        // Do not force a poorly aligned splice just to meet the requested speed.
        guard bestLag > 0, bestScore >= 0.98 else { correlationMisses += 1; return (Data(input.prefix(960)), 960) }
        var output = Data(count: 960)
        output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for i in 0..<480 {
                    let a = Double(Int16(littleEndian: src.loadUnaligned(fromByteOffset: i*2, as: Int16.self)))
                    let b = Double(Int16(littleEndian: src.loadUnaligned(fromByteOffset: (i+bestLag)*2, as: Int16.self)))
                    let mix = Double(i) / 479
                    let value = Int16(max(-32768, min(32767, (a*(1-mix) + b*mix).rounded())))
                    dst.storeBytes(of: value.littleEndian, toByteOffset: i*2, as: Int16.self)
                }
            }
        }
        credit = max(0, credit - Double(bestLag)); removedSamples += bestLag; acceleratedFrames += 1
        return (output, (480 + bestLag) * 2)
    }
}
