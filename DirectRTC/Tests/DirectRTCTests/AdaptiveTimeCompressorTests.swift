import Foundation
import XCTest
@testable import DirectRTC

final class AdaptiveTimeCompressorTests: XCTestCase {
    private func tone(start: Int, count: Int, frequency: Double) -> Data {
        let values = (start..<(start+count)).map { Int16((sin(Double($0)*2 * .pi*frequency/24000)*8000).rounded()).littleEndian }
        return values.withUnsafeBytes { Data($0) }
    }
    func testPitchAndFrameContinuityIncludingLowVoice() {
        for frequency in [70.0, 80, 100, 200, 440, 1000] {
            var processor = AdaptiveTimeCompressor(), source = 0, samples: [Int16] = [], boundaryMaximum = 0
            for _ in 0..<500 {
                let lookahead = processor.lookahead(rate: 1.10)
                let result = processor.process(tone(start: source, count: 480+lookahead, frequency: frequency), maximumSkip: lookahead)
                XCTAssertEqual(result.output.count, 960)
                source += result.consumedBytes/2
                let frame: [Int16] = result.output.withUnsafeBytes { raw in (0..<480).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0*2, as: Int16.self)) } }
                if let last = samples.last { boundaryMaximum = max(boundaryMaximum, abs(Int(frame[0])-Int(last))) }
                samples.append(contentsOf: frame)
            }
            let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            XCTAssertEqual(Double(crossings)/10, frequency, accuracy: max(0.5, frequency*0.005))
            XCTAssertLessThan(Double(boundaryMaximum), 8000 * 2 * .pi * frequency / 24000 * 1.8 + 50)
            XCTAssertGreaterThan(processor.removedSamples, 20000)
            XCTAssertLessThanOrEqual(processor.removedSamples, 24001)
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(samples.count))
            XCTAssertEqual(rms, 8000/sqrt(2), accuracy: 200)
        }
    }
    func testNormalRateIsBitExactAndClearsSpeedCredit() {
        var processor = AdaptiveTimeCompressor()
        _ = processor.lookahead(rate: 1.10); _ = processor.lookahead(rate: 1.10)
        XCTAssertEqual(processor.lookahead(rate: 1), 0)
        let pcm = tone(start: 0, count: 480, frequency: 70)
        XCTAssertEqual(processor.process(pcm, maximumSkip: 0).output, pcm)
        XCTAssertLessThanOrEqual(processor.lookahead(rate: 1.10), 48)
    }
    func testSilenceAndDCStayStable() {
        for value: Int16 in [0, 100] {
            var processor = AdaptiveTimeCompressor()
            for _ in 0..<100 {
                let count = processor.lookahead(rate: 1.10)
                let input = Array(repeating: value.littleEndian, count: 480+count).withUnsafeBytes { Data($0) }
                let result = processor.process(input, maximumSkip: count)
                XCTAssertEqual(result.output, Array(repeating: value.littleEndian, count: 480).withUnsafeBytes { Data($0) })
            }
            XCTAssertGreaterThan(processor.removedSamples, 0)
        }
    }
    func testSilenceToVoicedOnsetIsNotMistakenForCorrelation() {
        var processor = AdaptiveTimeCompressor()
        _ = processor.lookahead(rate: 1.10)
        let input = Data(count: 960) + tone(start: 0, count: 480, frequency: 200)
        let result = processor.process(input, maximumSkip: 48)
        XCTAssertEqual(result.consumedBytes, 960)
        XCTAssertEqual(result.output, Data(count: 960))
    }
    func testAntiphaseMinimumLagDoesNotCrashOrForceSplice() {
        var processor = AdaptiveTimeCompressor()
        let result = processor.process(tone(start: 0, count: 528, frequency: 250), maximumSkip: 48)
        XCTAssertEqual(result.consumedBytes, 960)
        XCTAssertEqual(result.output.count, 960)
    }
    func testDefaultReceiverDoesNotEnableExperimentalCatchup() throws {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<20 { buffer.insert(data: Data([0x08]), sequence: UInt16(i), timestamp: UInt32(i*960), now: 0) }
        for i in 0..<10 {
            XCTAssertEqual(try buffer.render(now: 0.1+Double(i)*0.02) { _ in Data(repeating: 1, count: 960) }, Data(repeating: 1, count: 960))
        }
        XCTAssertEqual(buffer.metrics["compressionRemovedSamples"], 0)
        XCTAssertEqual(buffer.metrics["maximumRequestedSpeedPermille"], 1000)
    }
}
