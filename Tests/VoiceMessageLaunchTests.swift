import AppIntents
import XCTest

@MainActor final class VoiceMessageLaunchTests: XCTestCase {
    private func waitForRequest(_ launch: VoiceMessageLaunch) async throws {
        for _ in 0..<50 {
            if launch.requestID != nil || !launch.isPending { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func testRecordActionOpensOnlyAfterActivationAndRequiresNoAudioOrNetwork() async throws {
        var active = false
        let launch = VoiceMessageLaunch(isActive: { active }, prerequisiteFailure: { nil })
        _ = try await SpeakDotIntent().perform(using: launch)
        XCTAssertNil(launch.requestID)
        XCTAssertTrue(launch.isPending)
        XCTAssertEqual(SpeakDotIntent.supportedModes, [.foreground(.immediate)])
        XCTAssertTrue(SpeakDotIntent.isDiscoverable)
        XCTAssertTrue(CallDotIntent.isDiscoverable)
        active = true
        try await waitForRequest(launch)
        XCTAssertNotNil(launch.consumeRequest())
        XCTAssertNil(launch.consumeRequest(), "The view consumes each recording request only once")
    }
    func testDuplicateActionsCoalesceUntilTheViewConsumesRequest() async throws {
        let launch = VoiceMessageLaunch(isActive: { true }, prerequisiteFailure: { nil })
        _ = try await SpeakDotIntent().perform(using: launch)
        _ = try await SpeakDotIntent().perform(using: launch)
        try await waitForRequest(launch)
        let id = launch.requestID
        _ = try await SpeakDotIntent().perform(using: launch)
        XCTAssertEqual(launch.requestID, id)
        XCTAssertNotNil(launch.consumeRequest())
        XCTAssertFalse(launch.isPending)
    }
    func testAccountOrCallChangeWhileWaitingCannotOpenRecording() async throws {
        var active = false
        var failure: String?
        let launch = VoiceMessageLaunch(isActive: { active }, prerequisiteFailure: { failure })
        _ = try await SpeakDotIntent().perform(using: launch)
        failure = "End your call first."
        active = true
        try await waitForRequest(launch)
        XCTAssertNil(launch.requestID)
        XCTAssertEqual(launch.error, failure)
    }
    func testDisconnectedAccountRejectsRecordActionBeforeScheduling() async {
        let launch = VoiceMessageLaunch(isActive: { true }, prerequisiteFailure: { "Connect ChatGPT first." })
        do {
            _ = try await SpeakDotIntent().perform(using: launch)
            XCTFail("Disconnected recording action must fail")
        } catch { XCTAssertEqual(error.localizedDescription, "Connect ChatGPT first.") }
        XCTAssertFalse(launch.isPending)
    }
    func testBackgroundCancellationDoesNotOpenRecorderOnLaterActivation() async throws {
        var active = false
        let launch = VoiceMessageLaunch(isActive: { active }, prerequisiteFailure: { nil })
        _ = try await SpeakDotIntent().perform(using: launch)
        launch.cancel()
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(launch.requestID)
        XCTAssertFalse(launch.isPending)
    }
    func testExpiredActivationRequestCannotOpenRecorderLater() async throws {
        var active = false
        let launch = VoiceMessageLaunch(timeout: .milliseconds(50), isActive: { active }, prerequisiteFailure: { nil })
        _ = try await SpeakDotIntent().perform(using: launch)
        try await waitForRequest(launch)
        XCTAssertNotNil(launch.error)
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(launch.requestID)
    }
    func testPendingRequestRechecksEligibilityWhenColdLaunchViewConsumes() async throws {
        var failure: String?
        let launch = VoiceMessageLaunch(isActive: { true }, prerequisiteFailure: { failure })
        _ = try await SpeakDotIntent().perform(using: launch)
        try await waitForRequest(launch)
        failure = "Reconnect your original Dot."
        XCTAssertNil(launch.consumeRequest())
        XCTAssertEqual(launch.error, failure)
    }
    func testInactiveViewKeepsRequestUntilActiveWithoutStartingRecording() async throws {
        var active = true
        let launch = VoiceMessageLaunch(isActive: { active }, prerequisiteFailure: { nil })
        _ = try await SpeakDotIntent().perform(using: launch)
        try await waitForRequest(launch)
        active = false
        XCTAssertNil(launch.consumeRequest())
        XCTAssertNotNil(launch.requestID)
        active = true
        XCTAssertNotNil(launch.consumeRequest())
    }

}
