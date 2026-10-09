import Foundation
import XCTest
import DirectRTC

private final class DirectDeferredHTTP: DotTransport {
    var account = DotAccount(token: "fixture", accountID: "fixture", dotID: "direct_lifecycle_fixture", threadID: "fixture", name: "fixture", deviceID: nil)
    private let lock = NSLock()
    private var createReply: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var recordedActions: [String] = []
    private var shouldFailStop = false
    var hasCreateReply: Bool { lock.withLock { createReply != nil } }
    var actions: [String] { lock.withLock { recordedActions } }
    var failStop: Bool {
        get { lock.withLock { shouldFailStop } }
        set { lock.withLock { shouldFailStop = newValue } }
    }
    @discardableResult func completeCreate() -> Bool {
        let continuation = lock.withLock {
            let pending = createReply
            createReply = nil
            return pending
        }
        guard let continuation else { return false }
        continuation.resume(returning: response())
        return true
    }
    func request(action: String, callID: String?, sdp: String?) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recordedActions.append(action) }
        if action == "create" {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { createReply = continuation }
            }
        }
        if action == "stop", failStop { throw URLError(.notConnectedToInternet) }
        return response()
    }
    func response() -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: URL(string: "https://chatgpt.com/fixture")!, statusCode: 200, httpVersion: nil, headerFields: ["Location": "/voice/calls/rtc_direct_fixture"])!)
    }
}
@MainActor final class DirectLifecycleTests: XCTestCase {
    let journal = "DotWatch.direct.pending.direct_lifecycle_fixture"
    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: journal) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: journal); super.tearDown() }
    func testEndBeforeStartupDoesNotWaitForever() async {
        let http = DirectDeferredHTTP()
        let call = DirectCall(account: http.account, http: http)
        await call.finish()
        XCTAssertTrue(http.actions.isEmpty)
    }
    func testOptionalCaptureFinishesOnceWhenCallNeverStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.dotcall")
        let capture = try PacketCapture(url: url)
        let http = DirectDeferredHTTP()
        let call = DirectCall(account: http.account, http: http, capture: capture)
        let completed = expectation(description: "Capture finalized without media or network")
        completed.assertForOverFulfill = true
        call.onCaptureFinished = { summary in
            XCTAssertEqual(summary.recordedPackets, 0)
            XCTAssertNil(summary.writeError)
            completed.fulfill()
        }
        await call.finish()
        await call.finish()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(http.actions.isEmpty)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }
    func testCancelDuringAllocationLearnsIDThenStopsWithoutAttach() async throws {
        let http = DirectDeferredHTTP()
        let direct = DirectCall(account: http.account, http: http)
        let starting = Task { try await direct.start() }
        for _ in 0..<200 { if http.hasCreateReply { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(http.hasCreateReply)
        let ending = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(http.actions, ["create"])
        XCTAssertTrue(http.completeCreate())
        try await starting.value; await ending.value
        XCTAssertEqual(http.actions, ["create", "stop"])
        XCTAssertNil(UserDefaults.standard.string(forKey: journal))
    }
    func testFailedCleanupRetainsJournalForNextLaunch() async throws {
        let http = DirectDeferredHTTP(); http.failStop = true
        let direct = DirectCall(account: http.account, http: http)
        let starting = Task { try await direct.start() }
        for _ in 0..<200 { if http.hasCreateReply { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let ending = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(http.completeCreate())
        try await starting.value; await ending.value
        XCTAssertEqual(http.actions, ["create", "stop"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: journal), "rtc_direct_fixture")
    }
    func testFailedRecoveryDoesNotAllocateSecondCloudCall() async {
        UserDefaults.standard.set("rtc_previous_fixture", forKey: journal)
        let http = DirectDeferredHTTP(); http.failStop = true
        let call = DirectCall(account: http.account, http: http)
        do { try await call.start(); XCTFail("Failed recovery must block allocation") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        await call.finish()
        XCTAssertEqual(http.actions, ["stop"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: journal), "rtc_previous_fixture")
    }
    func testRepeatedFinishStopsAllocatedCallOnlyOnce() async throws {
        let http = DirectDeferredHTTP()
        let direct = DirectCall(account: http.account, http: http)
        let starting = Task { try await direct.start() }
        for _ in 0..<200 { if http.hasCreateReply { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let firstEnd = Task { await direct.finish() }
        let secondEnd = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(http.completeCreate())
        try await starting.value; await firstEnd.value; await secondEnd.value
        await direct.finish()
        XCTAssertEqual(http.actions, ["create", "stop"])
        XCTAssertNil(UserDefaults.standard.string(forKey: journal))
    }

}
