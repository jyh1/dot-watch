import Foundation
import XCTest

final class CallRouteTests: XCTestCase {
    func testWidgetRouteMatchesRegisteredCallAction() {
        XCTAssertTrue(CallRoute.matches(CallRoute.url))
        XCTAssertTrue(CallRoute.matches(URL(string: "dotwatch://call/")!))
    }
    func testUnrelatedOrParameterizedLinksCannotStartCalls() {
        for value in ["https://dotwatch/call", "dotwatch://settings", "dotwatch://call/other", "dotwatch://call?name=other", "dotwatch://call#other", "dotwatch://user@call", "dotwatch://call:8080"] {
            XCTAssertFalse(CallRoute.matches(URL(string: value)!), value)
        }
    }
}
