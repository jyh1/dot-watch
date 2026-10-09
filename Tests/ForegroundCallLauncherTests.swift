import XCTest

@MainActor final class ForegroundCallLauncherTests: XCTestCase {
    func testIntentWaitRequiresBothSceneAndNativeActivation() async throws {
        var sceneActive = false
        var nativeActive = true
        var completed = false
        let launcher = ForegroundCallLauncher(isActive: { nativeActive })
        let wait = Task {
            try await launcher.awaitActive(sceneIsActive: { sceneActive })
            completed = true
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completed)
        nativeActive = false
        sceneActive = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completed)
        nativeActive = true
        try await wait.value
        XCTAssertTrue(completed)
    }
    func testIntentCancellationLeavesNoDeferredStart() async throws {
        var active = false
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { active })
        let wait = Task {
            try await launcher.awaitActive(sceneIsActive: { true })
            starts += 1
        }
        await Task.yield()
        wait.cancel()
        do { try await wait.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(launcher.isPending)
    }
    func testIntentTimeoutLeavesNoDeferredStart() async throws {
        var active = false
        var starts = 0
        let launcher = ForegroundCallLauncher(timeout: .milliseconds(100), isActive: { active })
        do {
            try await launcher.awaitActive(sceneIsActive: { true })
            starts += 1
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not become active")) }
        active = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(launcher.isPending)
    }
    func testExplicitLaunchCancellationCancelsIntentActivationWait() async throws {
        var active = false
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { active })
        let wait = Task {
            try await launcher.awaitActive(sceneIsActive: { true })
            starts += 1
        }
        try await Task.sleep(for: .milliseconds(100))
        launcher.cancel()
        active = true
        do { try await wait.value; XCTFail("Expected launch cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(starts, 0)
        // Cancellation invalidates existing waits, without blocking a new request.
        try await launcher.awaitActive(sceneIsActive: { true })
    }
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
    func testWidgetRequiresSceneAndNativeActivationAndStartsOnlyOnce() async throws {
        var sceneActive = false
        var nativeActive = true
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { nativeActive })
        launcher.request(sceneIsActive: { sceneActive }, start: { starts += 1 }, onTimeout: { XCTFail("Unexpected timeout") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0, "Native activation alone is insufficient")
        nativeActive = false
        sceneActive = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 0, "Scene activation alone is insufficient")
        nativeActive = true
        for _ in 0..<50 { if !launcher.isPending { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts, 1)
        sceneActive = false
        sceneActive = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 1)
    }
    func testBackgroundCancellationPreventsLaterReadyLaunch() async throws {
        var sceneActive = false
        var starts = 0
        let launcher = ForegroundCallLauncher(isActive: { true })
        launcher.request(sceneIsActive: { sceneActive }, start: { starts += 1 }, onTimeout: { XCTFail("Cancelled launch timed out") })
        await Task.yield()
        launcher.cancel()
        sceneActive = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(launcher.isPending)
        XCTAssertEqual(starts, 0)
    }
}
