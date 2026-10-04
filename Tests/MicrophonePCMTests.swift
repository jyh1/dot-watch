import XCTest
import AVFAudio

final class MicrophonePCMTests: XCTestCase {
    func testContinuousHardwareAudioResamplesWithoutLosingMicrophoneFrames() throws {
        for rate in [48000.0, 44100.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let converter = try MicrophonePCM(source: format)
            var bytes = 0, peak = 0
            for n in 0..<100 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                for i in 0..<1024 {
                    buffer.floatChannelData![0][i] = Float(sin(Double(n * 1024 + i) * 2 * .pi * 440 / rate)) * 0.25
                }
                let output = try converter.convert(buffer)
                bytes += output.count
                output.withUnsafeBytes { data in
                    for i in stride(from: 0, to: output.count, by: 2) {
                        peak = max(peak, abs(Int(Int16(littleEndian: data.loadUnaligned(fromByteOffset: i, as: Int16.self)))))
                    }
                }
            }
            XCTAssertEqual(Double(bytes / 2), 102400 * 24000 / rate, accuracy: 32)
            XCTAssertGreaterThan(peak, 7000)
            XCTAssertLessThan(peak, 9000)
        }
    }
    func testSilentMicrophoneStillProducesFrames() throws {
        // Silence must be distinguishable from the physical failure: zero bytes.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let converter = try MicrophonePCM(source: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = 0 }
        let output = try converter.convert(buffer)
        XCTAssertGreaterThan(output.count, 900)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
}
