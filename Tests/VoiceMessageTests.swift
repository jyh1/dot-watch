import Foundation
import XCTest

final class VoiceMessageTests: XCTestCase {
    private func job() -> VoiceMessage {
        VoiceMessage(id: UUID(), accountID: "test-account", dotID: "test-dot", createdAt: Date(), duration: 5)
    }
    private func account(_ account: String = "test-account", dot: String = "test-dot") -> DotAccount {
        DotAccount(token: "secret-not-persisted", accountID: account, dotID: dot, threadID: "thread", name: "Dot", deviceID: nil)
    }
    func testOutboxSurvivesRelaunchAndKeepsRetryIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceOutboxStore(directory: dir)
        var job = job(); job.transcript = "test message"; job.state = .sending
        try store.save([job])
        let restored = try XCTUnwrap(VoiceOutboxStore(directory: dir).load().first)
        XCTAssertEqual(restored, job)
        let initial = try JSONSerialization.jsonObject(with: VoiceMessageWire.messageBody(job)) as! [String: Any]
        let retry = try JSONSerialization.jsonObject(with: VoiceMessageWire.messageBody(restored)) as! [String: Any]
        XCTAssertEqual(initial["idempotency_token"] as? String, retry["idempotency_token"] as? String)
        XCTAssertEqual(initial["request_id"] as? String, initial["idempotency_token"] as? String)
        XCTAssertFalse(String(data: try Data(contentsOf: dir.appendingPathComponent("outbox.json")), encoding: .utf8)!.contains("secret-not-persisted"))
    }
    func testAccountOrDotSwitchCannotRetargetSavedMessage() {
        let job = job()
        XCTAssertTrue(job.belongs(to: account()))
        XCTAssertFalse(job.belongs(to: account("other-account")))
        XCTAssertFalse(job.belongs(to: account(dot: "other-dot")))
        XCTAssertFalse(job.belongs(to: nil))
    }
    func testUnknownDeliveryIsDifferentFromFailedTranscription() {
        for status: Int? in [nil, 408, 500, 502, 200] {
            XCTAssertEqual(VoiceMessageWire.failure(status: status, sending: true).0, .uncertain)
        }
        XCTAssertEqual(VoiceMessageWire.failure(status: nil, sending: false).0, .failed)
        for status in [400, 401, 403, 413, 429] {
            XCTAssertEqual(VoiceMessageWire.failure(status: status, sending: true).0, .failed)
        }
    }
    func testEmptyTranscriptionNeverCreatesMessage() throws {
        XCTAssertThrowsError(try VoiceMessageWire.transcript(Data(#"{"text":"  "}"#.utf8)))
        XCTAssertThrowsError(try VoiceMessageWire.transcript(Data(#"{"error":"bad"}"#.utf8)))
        XCTAssertThrowsError(try VoiceMessageWire.messageBody(job()))
        XCTAssertEqual(try VoiceMessageWire.transcript(Data(#"{"text":"hello 世界"}"#.utf8)), "hello 世界")
    }
    func testSuccessRequiresMessageReceipt() throws {
        XCTAssertThrowsError(try VoiceMessageWire.receipt(Data("{}".utf8)))
        XCTAssertThrowsError(try VoiceMessageWire.receipt(Data("<html>login</html>".utf8)))
        XCTAssertEqual(try VoiceMessageWire.receipt(Data(#"{"id":"message-test"}"#.utf8)), "message-test")
    }
    func testUnsafeDestinationIsRejected() {
        for value in [".", "..", "../other", "room?redirect=x", "room/other", "", "room\r\nheader:x"] {
            XCTAssertThrowsError(try VoiceMessageWire.pathComponent(value))
        }
    }
    func testUploadContainsAudioAndNoCredentialFields() throws {
        let id = UUID(), audio = Data([0,1,2,255])
        let body = try VoiceMessageWire.multipart(audio: audio, boundary: "test-boundary", id: id, duration: 2.5)
        XCTAssertNotNil(body.range(of: audio))
        let printable = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(printable.contains("audio/mp4"))
        XCTAssertTrue(printable.contains(id.uuidString.lowercased()))
        XCTAssertTrue(printable.contains("2500"))
        XCTAssertTrue(printable.hasSuffix("--test-boundary--\r\n"))
        XCTAssertFalse(printable.contains("Authorization"))
    }
    func testRequestsAreBoundToChatGPTAndHaveNoBypassHeaders() {
        let request = VoiceMessageWire.request(path: "/transcribe", account: account())
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-openai-web-frontend"))
    }
    func testStateIndicatorsDistinguishPendingAttentionAndSent() {
        var message = job()
        for state in [VoiceMessage.State.queued, .transcribing, .sending] {
            message.state = state
            XCTAssertTrue(message.pending)
            XCTAssertFalse(message.needsAttention)
        }
        for state in [VoiceMessage.State.failed, .uncertain] {
            message.state = state
            XCTAssertFalse(message.pending)
            XCTAssertTrue(message.needsAttention)
        }
        message.state = .sent
        XCTAssertFalse(message.pending)
        XCTAssertFalse(message.needsAttention)
    }
    func testCorruptOutboxIsReportedInsteadOfSilentlyDroppingMessages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceOutboxStore(directory: dir)
        try store.write(Data("not json".utf8), to: dir.appendingPathComponent("outbox.json"))
        XCTAssertThrowsError(try store.load())
    }
    func testLongRecordingHasNoTimeCap() throws {
        for duration in [121.0, 3600, 86400] {
            XCTAssertNoThrow(try VoiceRecordingLimits.validate(duration: duration, audioBytes: 100))
            let body = try VoiceMessageWire.multipart(audio: Data([1]), boundary: "test", id: UUID(), duration: duration)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(String(Int(duration * 1000))))
        }
    }
    func testInvalidRecordingDurationCannotReachUpload() {
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, 0.99, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try VoiceRecordingLimits.validate(duration: duration, audioBytes: 1))
            XCTAssertThrowsError(try VoiceMessageWire.multipart(audio: Data([1]), boundary: "test", id: UUID(), duration: duration))
        }
        XCTAssertNoThrow(try VoiceRecordingLimits.validate(duration: 1, audioBytes: 1))
    }
    func testRecordingSizeUsesSameHardLimitAndStopsBeforeFinalization() {
        XCTAssertNoThrow(try VoiceRecordingLimits.validate(duration: 600, audioBytes: VoiceRecordingLimits.maximumAudioBytes))
        for bytes in [-1, 0, VoiceRecordingLimits.maximumAudioBytes + 1] {
            XCTAssertThrowsError(try VoiceRecordingLimits.validate(duration: 600, audioBytes: bytes))
        }
        XCTAssertFalse(VoiceRecordingLimits.shouldStop(audioBytes: VoiceRecordingLimits.stoppingAudioBytes - 1))
        XCTAssertTrue(VoiceRecordingLimits.shouldStop(audioBytes: VoiceRecordingLimits.stoppingAudioBytes))
        XCTAssertTrue(VoiceRecordingLimits.shouldStop(audioBytes: VoiceRecordingLimits.maximumAudioBytes))
        XCTAssertLessThan(VoiceRecordingLimits.stoppingAudioBytes, VoiceRecordingLimits.maximumAudioBytes)
    }
    func testRemovingMediaRetainsReceiptAndOtherJobs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceOutboxStore(directory: dir), second = job()
        var first = job(); first.state = .sent; first.serverMessageID = "receipt"
        try store.save([first,second])
        for suffix in ["m4a", "body", "response"] {
            try store.write(Data([1]), to: store.file(first.id, suffix))
            try store.write(Data([2]), to: store.file(second.id, suffix))
        }
        store.removeMedia(first.id)
        for suffix in ["m4a", "body", "response"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(first.id, suffix).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(second.id, suffix).path))
        }
        let restored = try store.load()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?.serverMessageID, "receipt")
    }
}

final class VoiceSentNoticeTests: XCTestCase {
    private func account(_ id: String = "account", dot: String = "dot", token: String = "fixture") -> DotAccount {
        DotAccount(token: token, accountID: id, dotID: dot, threadID: "thread", name: "Dot", deviceID: nil)
    }
    private func receipt(id: UUID = UUID()) -> VoiceMessage {
        var message = VoiceMessage(id: id, accountID: "account", dotID: "dot", createdAt: Date(), duration: 2)
        message.state = .sent; message.serverMessageID = "receipt-" + id.uuidString
        return message
    }
    func testReopenedOutboxKeepsHistoryWithoutRecreatingSuccessNotice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VoiceOutboxStore(directory: directory), message = receipt()
        try store.save([message])
        let restored = try store.load()
        XCTAssertFalse(VoiceSentNotice().isVisible(in: restored, account: account()))
        XCTAssertEqual(restored.first?.serverMessageID, message.serverMessageID)
        XCTAssertEqual(restored.first?.state, .sent)
    }
    func testDismissalPreservesReceiptAndNextConfirmedMessageShowsNewNotice() {
        let first = receipt(), second = receipt()
        var notice = VoiceSentNotice()
        notice.received(first, account: account())
        XCTAssertTrue(notice.isVisible(in: [first], account: account()))
        notice.dismiss()
        XCTAssertFalse(notice.isVisible(in: [first], account: account()))
        XCTAssertNotNil(first.serverMessageID, "Dismissing a notice does not change its durable receipt")
        notice.received(second, account: account())
        XCTAssertEqual(notice.messageID, second.id)
        XCTAssertTrue(notice.isVisible(in: [first, second], account: account()))
    }
    func testAccountOrDotSwitchDismissesNoticeAndReturningCannotResurrectIt() {
        for other in [account("other"), account(dot: "other"), nil] {
            let message = receipt()
            var notice = VoiceSentNotice()
            notice.received(message, account: account())
            XCTAssertFalse(notice.isVisible(in: [message], account: other))
            notice.accountChanged(messages: [message], account: other)
            XCTAssertFalse(notice.isVisible(in: [message], account: account()))
        }
    }
    func testRefreshingSameAccountDoesNotHideCurrentConfirmedReceipt() {
        let message = receipt()
        var notice = VoiceSentNotice()
        notice.received(message, account: account())
        let refreshed = account(token: "renewed-fixture")
        notice.accountChanged(messages: [message], account: refreshed)
        XCTAssertTrue(notice.isVisible(in: [message], account: refreshed))
    }
    func testUnconfirmedFailedOrWrongAccountDeliveryCannotCreateSuccessNotice() {
        for state in [VoiceMessage.State.queued, .sending, .failed, .uncertain] {
            var message = receipt(); message.state = state
            var notice = VoiceSentNotice(); notice.received(message, account: account())
            XCTAssertFalse(notice.isVisible(in: [message], account: account()))
        }
        var message = receipt(); message.serverMessageID = nil
        var notice = VoiceSentNotice(); notice.received(message, account: account())
        XCTAssertFalse(notice.isVisible(in: [message], account: account()))
        message = receipt(); notice.received(message, account: account("other"))
        XCTAssertNil(notice.messageID)
    }
}
