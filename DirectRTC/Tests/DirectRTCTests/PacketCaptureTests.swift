import Foundation
import XCTest
@testable import DirectRTC

final class PacketCaptureTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dot-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testActualOpusCaptureReplayReorderLossAndWrap() async throws {
        let url = try directory().appendingPathComponent("synthetic.ndjson")
        let capture = try PacketCapture(url: url, limits: .default, writer: DispatchQueue(label: "capture-test"), started: 0)
        let codec = try OpusCodec()
        var encoded: [Data] = []
        for n in 0..<12 {
            let samples = (0..<480).map { Int16(sin(Double(n*480 + $0) * 2 * .pi * 440 / 24000) * 3000).littleEndian }
            encoded.append(try codec.encode(samples.withUnsafeBytes { Data($0) }))
        }
        for i in 0..<12 where i != 4 {
            let arrival = Double(i)*0.02 + 0.04 + (i == 3 ? 0.04 : 0)
            capture.record(payload: encoded[i], sequence: UInt16.max &- 5 &+ UInt16(i), timestamp: (UInt32.max &- 4800) &+ UInt32(i*960), arrivalUptime: arrival, processingUptime: arrival + 0.001)
        }
        capture.record(payload: encoded[2], sequence: UInt16.max &- 3, timestamp: (UInt32.max &- 4800) &+ 1920, arrivalUptime: 0.081, processingUptime: 0.082)
        for i in 0..<35 { capture.recordRender(uptime: Double(i)*0.02) }
        let summary = await capture.finish()
        XCTAssertEqual(summary.recordedPackets, 12)
        XCTAssertEqual(summary.recordedRenders, 35)
        XCTAssertEqual(summary.droppedEvents, 0)
        XCTAssertNil(summary.writeError)
        if let artifact = ProcessInfo.processInfo.environment["DOT_CAPTURE_SYNTHETIC_ARTIFACT"] {
            try Data(contentsOf: url).write(to: URL(fileURLWithPath: artifact), options: .withoutOverwriting)
        }
        let again = await capture.finish()
        XCTAssertEqual(again.fileBytes, summary.fileBytes)
        let result = try PacketReplay.replay(url: url)
        XCTAssertEqual(result.metrics["referenceMissingPCMBytes"], 960)
        XCTAssertEqual(result.metrics["referenceDuplicatePackets"], 1)
        XCTAssertEqual(result.metrics["referenceMediaPCMBytes"], 12*960)
        XCTAssertGreaterThan(result.arrivalPCM.count, 0)
        XCTAssertEqual(String(data: PacketReplay.wav(result.referencePCM).prefix(4), encoding: .utf8), "RIFF")
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["token", "address", "ssrc", "microphone", "sdp"] { XCTAssertFalse(text.lowercased().contains(forbidden)) }
    }
    func testBoundedQueueOverflowIsExplicit() async throws {
        let writer = DispatchQueue(label: "blocked-capture-test")
        let blocker = DispatchSemaphore(value: 0)
        writer.async { blocker.wait() }
        let url = try directory().appendingPathComponent("queue.ndjson")
        let capture = try PacketCapture(url: url, limits: .init(queuedBytes: 300), writer: writer, started: 0)
        for i in 0..<10 { capture.record(payload: Data([0x08]), sequence: UInt16(i), timestamp: UInt32(i*960), arrivalUptime: Double(i)*0.02) }
        blocker.signal()
        let summary = await capture.finish()
        XCTAssertEqual(summary.recordedPackets, 1)
        XCTAssertEqual(summary.droppedEvents, 9)
        XCTAssertFalse(summary.truncated)
    }
    func testFileAndDurationCapsAreExplicit() async throws {
        let url = try directory().appendingPathComponent("cap.ndjson")
        let capture = try PacketCapture(url: url, limits: .init(durationSeconds: 1, fileBytes: 1024), writer: DispatchQueue(label: "capture-cap-test"), started: 0)
        for i in 0..<100 { capture.record(payload: Data(repeating: 8, count: 100), sequence: UInt16(i), timestamp: UInt32(i*960), arrivalUptime: Double(i)*0.001) }
        capture.recordRender(uptime: 1.1)
        let summary = await capture.finish()
        XCTAssertTrue(summary.truncated)
        XCTAssertGreaterThan(summary.droppedEvents, 0)
        XCTAssertLessThanOrEqual(summary.fileBytes, 1024)
    }
    func testSetupTimeDoesNotConsumeCaptureBudget() async throws {
        let url = try directory().appendingPathComponent("timeline.ndjson")
        let capture = try PacketCapture(url: url, limits: .init(durationSeconds: 1))
        capture.recordRender(uptime: 10_000)
        capture.recordRender(uptime: 10_000.5)
        let summary = await capture.finish()
        XCTAssertEqual(summary.recordedRenders, 2)
        XCTAssertFalse(summary.truncated)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("500000000"))
    }
    func testNonexistentDirectoryAndExistingFileFailWithoutReplacement() throws {
        let directory = try directory()
        XCTAssertThrowsError(try PacketCapture(url: directory.appendingPathComponent("absent/file.ndjson")))
        let url = directory.appendingPathComponent("existing.ndjson")
        try Data("preserve".utf8).write(to: url)
        XCTAssertThrowsError(try PacketCapture(url: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("preserve".utf8))
    }
    func testMalformedAndUnfinishedFilesAreRejected() throws {
        let url = try directory().appendingPathComponent("bad.ndjson")
        for text in ["not-json\n", "{\"type\":\"header\",\"version\":99}\n{}\n", "{\"type\":\"header\",\"version\":1,\"rtpClock\":48000,\"pcmRate\":24000}\n"] {
            try Data(text.utf8).write(to: url)
            XCTAssertThrowsError(try PacketReplay.replay(url: url))
        }
    }
    func testInsertionTimesAndRenderStallsArePreserved() async throws {
        let url = try directory().appendingPathComponent("stall.ndjson")
        let capture = try PacketCapture(url: url, limits: .default, writer: DispatchQueue(label: "capture-stall-test"), started: 0)
        let codec = try OpusCodec()
        let packet = try codec.encode(Data(count: 960))
        capture.record(payload: packet, sequence: 0, timestamp: 0, arrivalUptime: 0.01, processingUptime: 0.2)
        for time in [0.0, 0.02, 0.04, 0.20, 0.22, 0.24, 0.26, 0.28, 0.30, 0.32] { capture.recordRender(uptime: time) }
        _ = await capture.finish()
        let result = try PacketReplay.replay(url: url)
        XCTAssertEqual(result.metrics["schedulerGapPCMBytes"], 6720)
        XCTAssertEqual(result.metrics["schedulerStalls"], 1)
        XCTAssertEqual(result.metrics["decodedPackets"], 1)
    }
}
