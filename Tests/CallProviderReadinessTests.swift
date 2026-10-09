import XCTest

@MainActor final class CallProviderReadinessTests: XCTestCase {
    func testColdProviderWaitsForReadyAndSubmitsOnlyOnce() {
        let readiness = CallProviderReadiness()
        var requests = 0
        readiness.request { requests += 1 }
        XCTAssertEqual(requests, 0)
        readiness.request { XCTFail("Duplicate start replaced the pending request") }
        readiness.providerDidBegin()
        readiness.providerDidBegin()
        readiness.request { XCTFail("Ready provider started a duplicate call") }
        XCTAssertEqual(requests, 1)
    }
    func testProviderReadyBeforeRequestStartsImmediately() {
        let readiness = CallProviderReadiness()
        var requests = 0
        readiness.providerDidBegin()
        readiness.request { requests += 1 }
        XCTAssertEqual(requests, 1)
    }
    func testEndResetOrTimeoutBeforeReadinessCannotStartLater() {
        let readiness = CallProviderReadiness()
        readiness.request { XCTFail("Cancelled call started after late readiness") }
        readiness.cancel()
        readiness.providerDidBegin()
        readiness.request { XCTFail("Cancelled provider accepted another start") }
    }
}
