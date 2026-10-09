import Foundation
import XCTest
@testable import DirectRTC

final class NetEqReceiverTests: XCTestCase {
    private struct Packet {
        let payload: Data
        let sequence: UInt16
        let timestamp: UInt32
        let arrival: Double
    }

    private func packets(count: Int = 100, sequence: UInt16 = 0, timestamp: UInt32 = 1_000_000) throws -> [Packet] {
        let encoder = try OpusCodec()
        return try (0..<count).map { n in
            let pcm = (0..<480).map { i in
                Int16((sin(Double(n * 480 + i) * 2 * .pi * 1000 / 24000) * 6000).rounded()).littleEndian
            }
            return Packet(payload: try encoder.encode(pcm.withUnsafeBytes { Data($0) }),
                          sequence: sequence &+ UInt16(n), timestamp: timestamp &+ UInt32(n * 960),
                          arrival: Double(50 + n * 20) / 1000)
        }
    }

    private func replay(_ packets: [Packet], through milliseconds: Int = 2200, onFinished: (([String: Int]) -> Void)? = nil) throws -> Data {
        let receiver = try NetEqReceiver()
        var index = 0, output = Data()
        for tick in stride(from: 0, through: milliseconds, by: 10) {
            let now = Double(tick) / 1000
            while index < packets.count, packets[index].arrival <= now {
                let packet = packets[index]
                try receiver.insert(packet.payload, sequence: packet.sequence, timestamp: packet.timestamp,
                                    arrival: packet.arrival, processing: now)
                index += 1
            }
            let frame = try receiver.render(now: now)
            XCTAssertEqual(frame.count, 960, "Every pull must represent 10 ms of 48 kHz mono PCM16")
            output.append(frame)
        }
        onFinished?(receiver.statistics)
        return output
    }

    private func frequency(_ data: Data, from firstSample: Int, count: Int) -> Double {
        let samples = data.withUnsafeBytes { raw in
            (firstSample..<(firstSample + count)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        return Double(crossings) * 48000 / Double(count)
    }

    func testNativeTenMillisecondContractRetainsTonePitch() throws {
        XCTAssertEqual(NetEqReceiver.sampleRate, 48000)
        XCTAssertEqual(NetEqReceiver.frameSamples, 480)
        XCTAssertEqual(NetEqReceiver.frameBytes, 960)
        let output = try replay(packets())
        XCTAssertEqual(output.count, 221 * 960)
        XCTAssertEqual(frequency(output, from: 24000, count: 48000), 1000, accuracy: 3)
    }

    func testSequenceAndRTPTimestampWrapPreserveContinuousTone() throws {
        let output = try replay(packets(sequence: .max - 4, timestamp: .max - 5000))
        XCTAssertEqual(frequency(output, from: 24000, count: 48000), 1000, accuracy: 3)
    }

    func testThreeMissingPacketsStillProduceFixedFramesAndResumeTone() throws {
        let original = try packets()
        let retained = original.enumerated().filter { !(40...42).contains($0.offset) }.map(\.element)
        var stats: [String: Int] = [:]
        let output = try replay(retained, onFinished: { stats = $0 })
        XCTAssertGreaterThan(stats["concealedSamples", default: 0], 0)
        XCTAssertGreaterThan(stats["concealmentEvents", default: 0], 0)
        XCTAssertEqual(stats["neteqReceivedPackets"], 97)
        XCTAssertEqual(output.count, 221 * 960)
        XCTAssertEqual(frequency(output, from: 60000, count: 24000), 1000, accuracy: 5)
    }

    func testResetClearsOldSpeechAndAcceptsNewTimeline() throws {
        let receiver = try NetEqReceiver()
        let packet = try packets(count: 1)[0]
        try receiver.insert(packet.payload, sequence: packet.sequence, timestamp: packet.timestamp,
                            arrival: 0.05, processing: 0.05)
        _ = try receiver.render(now: 0.05)
        try receiver.reset(now: 10)
        XCTAssertEqual(receiver.statistics["neteqReceivedPackets"], 0)
        for n in 0..<10 {
            XCTAssertEqual(try receiver.render(now: 10 + Double(n) / 100), Data(count: 960))
        }
        try receiver.insert(packet.payload, sequence: 0, timestamp: 10, arrival: 10.1, processing: 10.1)
        XCTAssertEqual(try receiver.render(now: 10.1).count, 960)
    }

    func testLateCallbackPullsOneFrameAndPreservesOriginalArrivalMetadata() throws {
        let receiver = try NetEqReceiver()
        XCTAssertEqual(try receiver.render(now: 0).count, 960)
        // A delayed callback pulls one frame; it must not synthesize missed pulls.
        XCTAssertEqual(try receiver.render(now: 0.09).count, 960)
        let packet = try packets(count: 1)[0]
        try receiver.insert(packet.payload, sequence: packet.sequence, timestamp: packet.timestamp,
                            arrival: 0.05, processing: 0.10)
        XCTAssertEqual(receiver.statistics["neteqReceivedPackets"], 1)
        XCTAssertEqual(try receiver.render(now: 0.10).count, 960)
        XCTAssertThrowsError(try receiver.render(now: 0.08))
        XCTAssertThrowsError(try receiver.insert(packet.payload, sequence: 1, timestamp: 1_000_960,
                                               arrival: 0.05, processing: 0.09))
        XCTAssertEqual(receiver.statistics["neteqReceivedPackets"], 1)
    }

    func testRejectsInvalidPacketTimingAndConfiguration() throws {
        XCTAssertThrowsError(try NetEqReceiver(minimumDelayMilliseconds: 501, maximumDelayMilliseconds: 500))
        XCTAssertThrowsError(try NetEqReceiver(now: .nan))
        let receiver = try NetEqReceiver()
        XCTAssertThrowsError(try receiver.render(now: -.infinity))
        XCTAssertThrowsError(try receiver.insert(Data(), sequence: 0, timestamp: 0, arrival: 0, processing: 0))
        XCTAssertThrowsError(try receiver.insert(Data(count: 61441), sequence: 0, timestamp: 0, arrival: 0, processing: 0))
        XCTAssertThrowsError(try receiver.insert(Data([0x08]), sequence: 0, timestamp: 0, arrival: 1, processing: 0.5))
    }
}


extension NetEqReceiverTests {
    func testNativeCaptureReplayCarriesReceiverClockAndWAVRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("native.dotcall")
        let capture = try PacketCapture(url: url, mediaFormat: .neteq48k)
        capture.beginMediaTimeline(uptime: 0)
        let input = try packets(count: 20)
        var next = 0
        for tick in 0...100 {
            let now = Double(tick) / 100
            while next < input.count, input[next].arrival <= now {
                let packet = input[next]
                capture.record(payload: packet.payload, sequence: packet.sequence, timestamp: packet.timestamp,
                               arrivalUptime: packet.arrival, processingUptime: now)
                next += 1
            }
            capture.recordRender(uptime: now)
        }
        let summary = await capture.finish()
        XCTAssertEqual(summary.droppedEvents, 0)
        XCTAssertEqual(summary.recordedPackets, 20)
        let headerLine = try Data(contentsOf: url).split(separator: 10)[0]
        let header = try JSONDecoder().decode(PacketCapture.Record.self, from: Data(headerLine))
        XCTAssertEqual(header.version, 2)
        XCTAssertEqual(header.pcmRate, 48000)
        XCTAssertEqual(header.receiver, "neteq-libopus")
        XCTAssertEqual(header.renderIntervalMilliseconds, 10)
        let result = try PacketReplay.replay(url: url)
        XCTAssertEqual(result.sampleRate, 48000)
        XCTAssertEqual(result.arrivalPCM.count % 960, 0)
        XCTAssertEqual(result.metrics["actualNeteqReceivedPackets"], 20)
        let wav = PacketReplay.wav(result.arrivalPCM, sampleRate: result.sampleRate)
        let rate = wav.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) }
        XCTAssertEqual(rate, 48000)
        XCTAssertEqual(wav.count, result.arrivalPCM.count + 44)
        XCTAssertThrowsError(try PacketReplay.replay(url: url, compressionEnabled: true))

        var records = try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(PacketCapture.Record.self, from: Data($0)) }
        records[0].pcmRate = 24000
        var invalid = Data()
        for record in records { invalid.append(try JSONEncoder().encode(record)); invalid.append(10) }
        let wrongRate = directory.appendingPathComponent("wrong-rate.dotcall")
        try invalid.write(to: wrongRate)
        XCTAssertThrowsError(try PacketReplay.replay(url: wrongRate))
        records[0].pcmRate = 48000; records[0].receiver = "legacy"
        invalid.removeAll()
        for record in records { invalid.append(try JSONEncoder().encode(record)); invalid.append(10) }
        let wrongReceiver = directory.appendingPathComponent("wrong-receiver.dotcall")
        try invalid.write(to: wrongReceiver)
        XCTAssertThrowsError(try PacketReplay.replay(url: wrongReceiver))
    }
}
