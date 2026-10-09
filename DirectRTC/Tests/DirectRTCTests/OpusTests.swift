import XCTest
@testable import DirectRTC
final class OpusTests: XCTestCase {
    func testAudioRoundTripAndSilence() throws {
        let codec = try OpusCodec()
        var peak = 0, total = 0
        for n in 0..<30 {
            let samples = (0..<480).map { Int16(sin(Double(n * 480 + $0) * 2 * .pi * 440 / 24000) * 4000).littleEndian }
            let encoded = try codec.encode(samples.withUnsafeBytes { Data($0) })
            let decoded = try codec.decode(encoded); total += decoded.count
            decoded.withUnsafeBytes { b in for i in stride(from: 0, to: decoded.count, by: 2) { peak = max(peak,abs(Int(b.loadUnaligned(fromByteOffset: i, as: Int16.self)))) } }
        }
        XCTAssertGreaterThan(peak, 1000); XCTAssertGreaterThanOrEqual(total, 30 * 960 - 240); XCTAssertLessThanOrEqual(total, 30 * 960) // Decoder startup delay
        var mutedPeak = 0
        for n in 0..<30 {
            let decoded = try codec.decode(codec.encode(Data(count:960)))
            if n > 25 { decoded.withUnsafeBytes { b in for i in stride(from:0,to:decoded.count,by:2) { mutedPeak = max(mutedPeak,abs(Int(b.loadUnaligned(fromByteOffset:i,as:Int16.self)))) } } }
        }
        XCTAssertLessThan(mutedPeak, 100)
    }
}

extension OpusTests {
    func testRealVariableDurationPackets() throws {
        let decoder = try OpusCodec()
        for frames in [240, 480, 960, 1440] {
            let encoder = try OpusCodec(frameSize: frames)
            var total = 0
            for n in 0..<10 {
                let samples = (0..<frames).map { Int16(sin(Double(n * frames + $0) * 2 * .pi * 440 / 24000) * 4000).littleEndian }
                let packet = try encoder.encode(samples.withUnsafeBytes { Data($0) })
                XCTAssertEqual(ReceiveJitterBuffer.opusDuration(packet), frames * 2)
                let decoded = try decoder.decode(packet)
                total += decoded.count
                XCTAssertLessThanOrEqual(decoded.count, frames * 2)
            }
            XCTAssertGreaterThanOrEqual(total, 10 * frames * 2 - 240)
        }
    }
}
