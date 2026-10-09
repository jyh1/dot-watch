import XCTest

@MainActor final class CallDiagnosticsTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    func testConsentDefaultsOffAndIsConsumedOnlyOnce() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = CallDiagnostics(directory: root)
        XCTAssertFalse(diagnostics.recordNextCall)
        XCTAssertNil(try diagnostics.consumeNextCaptureURL())
        diagnostics.recordNextCall = true
        let url = try XCTUnwrap(diagnostics.consumeNextCaptureURL())
        XCTAssertFalse(diagnostics.recordNextCall)
        XCTAssertNil(try diagnostics.consumeNextCaptureURL())
        try Data("incoming fixture".utf8).write(to: url)
        diagnostics.captureFinished(url: url, error: nil)
        XCTAssertEqual(diagnostics.recordings.count, 1)
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        XCTAssertFalse(CallDiagnostics(directory: root).recordNextCall)
    }

    func testRetentionAndDeletePreserveUnrelatedFiles() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = CallDiagnostics(directory: root, maximumFiles: 2, maximumBytes: 20)
        var retained: URL?
        for index in 0..<3 {
            diagnostics.recordNextCall = true
            let url = try XCTUnwrap(diagnostics.consumeNextCaptureURL())
            try Data(repeating: UInt8(index), count: 8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
            diagnostics.captureFinished(url: url, error: nil)
            retained = url
        }
        let unrelated = root.appendingPathComponent("personal.txt")
        try Data("keep".utf8).write(to: unrelated)
        XCTAssertEqual(diagnostics.recordings.count, 2)
        XCTAssertTrue(diagnostics.recordings.contains { $0.url == retained })
        XCTAssertLessThanOrEqual(diagnostics.recordings.reduce(0) { $0 + $1.bytes }, 20)
        diagnostics.delete(try XCTUnwrap(diagnostics.recordings.first))
        XCTAssertEqual(diagnostics.recordings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testByteLimitAndFailedStartupConsumeConsent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = CallDiagnostics(directory: root, maximumFiles: 5, maximumBytes: 12)
        for _ in 0..<2 {
            diagnostics.recordNextCall = true
            let url = try XCTUnwrap(diagnostics.consumeNextCaptureURL())
            try Data(repeating: 0, count: 8).write(to: url)
            diagnostics.captureFinished(url: url, error: nil)
        }
        XCTAssertEqual(diagnostics.recordings.count, 1)
        let invalidDirectory = root.appendingPathComponent("file")
        try Data().write(to: invalidDirectory)
        let failing = CallDiagnostics(directory: invalidDirectory)
        failing.recordNextCall = true
        XCTAssertThrowsError(try failing.consumeNextCaptureURL())
        XCTAssertFalse(failing.recordNextCall)
    }

    func testActiveCaptureCannotBeExportedOrDeleted() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = CallDiagnostics(directory: root)
        diagnostics.recordNextCall = true
        let url = try XCTUnwrap(diagnostics.consumeNextCaptureURL())
        try Data("partial".utf8).write(to: url)
        diagnostics.refresh()
        XCTAssertTrue(diagnostics.recordings.isEmpty)
        diagnostics.delete(.init(url: url, date: Date(), bytes: 7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        diagnostics.captureFinished(url: url, error: "fixture failure")
        XCTAssertEqual(diagnostics.recordings.count, 1)
        XCTAssertTrue(diagnostics.status?.contains("incomplete") == true)
    }

    func testTransferCopiesTemporaryFileBeforeItDisappears() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = Data("incoming packets fixture".utf8)
        try fixture.write(to: source)
        let target = try CallDiagnostics.receiveTransferredFile(source, directory: root)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: target), fixture)
        XCTAssertTrue(try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let diagnostics = CallDiagnostics(directory: root)
        XCTAssertEqual(diagnostics.recordings.first?.url, target)
    }
}
