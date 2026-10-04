import XCTest

@MainActor final class ForegroundCallLauncherTests: XCTestCase {
    func testBackgroundWidgetWaitsForActivationAndCoalescesDelivery() async throws {
        var active = false
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { active })
        launcher.request(start: { starts += 1 }, onTimeout: { XCTFail("Unexpected timeout") })
        launcher.request(start: { starts += 1 }, onTimeout: { XCTFail("Duplicate request") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0, "CallKit must not be requested during widget launch transition")
        XCTAssertTrue(launcher.isPending)
        active = true
        for _ in 0..<50 { if !launcher.isPending { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(launcher.isPending)
    }
    func testAbandonedLaunchExpiresWithoutCallingOnLaterActivation() async throws {
        var active = false
        var starts = 0
        var timeouts = 0
        let launcher = ForegroundCallLauncher(timeout: .milliseconds(100), isActive: { active })
        launcher.request(start: { starts += 1 }, onTimeout: { timeouts += 1 })
        for _ in 0..<50 { if !launcher.isPending { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(timeouts, 1)
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0)
    }
    func testManualCallCancelsQueuedWidgetLaunch() async throws {
        var active = false
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { active })
        launcher.request(start: { starts += 1 }, onTimeout: { XCTFail("Cancelled launch timed out") })
        launcher.cancel()
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(launcher.isPending)
    }
}
