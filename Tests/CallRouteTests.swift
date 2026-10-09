import Foundation
import XCTest

final class CallRouteTests: XCTestCase {
    func testWidgetRouteMatchesRegisteredCallAction() {
        XCTAssertTrue(CallRoute.matches(CallRoute.url))
        XCTAssertTrue(CallRoute.matches(URL(string: "\(CallRoute.scheme)://call/")!))
        XCTAssertEqual(CallRoute.action(for: CallRoute.url), .call)
    }
    func testSpeakRouteDoesNotMatchLegacyCallHandler() {
        XCTAssertEqual(CallRoute.action(for: CallRoute.speakURL), .speak)
        XCTAssertEqual(CallRoute.action(for: URL(string: "\(CallRoute.scheme)://SPEAK/")!), .speak)
        XCTAssertFalse(CallRoute.matches(CallRoute.speakURL), "A call-only handler must never treat Speak as Call")
    }
    func testBothActionsRejectParameterizedOrUnrelatedDestinations() {
        for action in ["call", "speak"] {
            for suffix in ["/other", "?name=other", "#other", ":8080"] {
                XCTAssertNil(CallRoute.action(for: URL(string: "\(CallRoute.scheme)://\(action)\(suffix)")!))
            }
            XCTAssertNil(CallRoute.action(for: URL(string: "\(CallRoute.scheme)://user@\(action)")!))
            XCTAssertNil(CallRoute.action(for: URL(string: "https://\(action)")!))
        }
        XCTAssertNil(CallRoute.action(for: URL(string: "\(CallRoute.scheme)://settings")!))
    }
    func testUnrelatedOrParameterizedLinksCannotStartCalls() {
        for value in ["https://dotwatch/call", "dotwatch://settings", "dotwatch://call/other", "dotwatch://call?name=other", "dotwatch://call#other", "dotwatch://user@call", "dotwatch://call:8080"] {
            XCTAssertFalse(CallRoute.matches(URL(string: value)!), value)
        }
    }
}
