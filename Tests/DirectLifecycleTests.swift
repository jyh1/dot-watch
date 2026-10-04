import Foundation
import XCTest

private final class DirectDeferredHTTP: DotTransport {
    var account = DotAccount(token: "fixture", accountID: "fixture", dotID: "direct_lifecycle_fixture", threadID: "fixture", name: "fixture", deviceID: nil)
    var createReply: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var actions: [String] = []
    var failStop = false
    func request(action: String, callID: String?, sdp: String?) async throws -> (Data, HTTPURLResponse) {
        actions.append(action)
        if action == "create" { return try await withCheckedThrowingContinuation { createReply = $0 } }
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
    func testCancelDuringAllocationLearnsIDThenStopsWithoutAttach() async throws {
        let http = DirectDeferredHTTP()
        let direct = DirectCall(account: http.account, http: http)
        let starting = Task { try await direct.start() }
        for _ in 0..<200 { if http.createReply != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(http.createReply)
        let ending = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(http.actions, ["create"])
        http.createReply?.resume(returning: http.response()); http.createReply = nil
        try await starting.value; await ending.value
        XCTAssertEqual(http.actions, ["create", "stop"])
        XCTAssertNil(UserDefaults.standard.string(forKey: journal))
    }
    func testFailedCleanupRetainsJournalForNextLaunch() async throws {
        let http = DirectDeferredHTTP(); http.failStop = true
        let direct = DirectCall(account: http.account, http: http)
        let starting = Task { try await direct.start() }
        for _ in 0..<200 { if http.createReply != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let ending = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        http.createReply?.resume(returning: http.response()); http.createReply = nil
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
        for _ in 0..<200 { if http.createReply != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let firstEnd = Task { await direct.finish() }
        let secondEnd = Task { await direct.finish() }
        try await Task.sleep(nanoseconds: 20_000_000)
        http.createReply?.resume(returning: http.response()); http.createReply = nil
        try await starting.value; await firstEnd.value; await secondEnd.value
        await direct.finish()
        XCTAssertEqual(http.actions, ["create", "stop"])
        XCTAssertNil(UserDefaults.standard.string(forKey: journal))
    }

}
