import Foundation
import XCTest

final class SessionTests: XCTestCase {
    @MainActor func testRefreshCannotOverwriteNewLoginOrRestoreDisconnectedAccount() throws {
        let original = try account(expiration: Date().timeIntervalSince1970 + 3600)
        XCTAssertNoThrow(try DotSession.validateRefreshDestination(original: original, current: original))
        XCTAssertThrowsError(try DotSession.validateRefreshDestination(original: original, current: nil))
        let switched = DotAccount(token: original.token, accountID: "different", dotID: "other-dot", threadID: "thread", name: "Dot", deviceID: nil)
        XCTAssertThrowsError(try DotSession.validateRefreshDestination(original: original, current: switched))
        let renewed = DotAccount(token: "new-session", accountID: original.accountID, dotID: original.dotID, threadID: original.threadID, name: original.name, deviceID: nil)
        XCTAssertThrowsError(try DotSession.validateRefreshDestination(original: original, current: renewed))
    }
    func account(expiration: Double) throws -> DotAccount {
        let data = try JSONSerialization.data(withJSONObject: ["exp":expiration])
        let claim = data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return DotAccount(token: "header.\(claim).signature", accountID: "test", dotID: "dot", threadID: UUID().uuidString, name: "Dot", deviceID: nil)
    }
    func testExpiredAndMalformedSessionsFailClosed() throws {
        XCTAssertTrue(try account(expiration: Date().timeIntervalSince1970 - 1).tokenExpired)
        XCTAssertTrue(try account(expiration: Date().timeIntervalSince1970 + 30).tokenExpired)
        XCTAssertFalse(try account(expiration: Date().timeIntervalSince1970 + 3600).tokenExpired)
        XCTAssertTrue(DotAccount(token: "malformed", accountID: "test", dotID: "dot", threadID: "thread", name: "Dot", deviceID: nil).tokenExpired)
    }
    func testLateRepliesResumeContinuationOnlyOnce() async throws {
        let value: Int = try await withCheckedThrowingContinuation { c in
            let gate = ReplyGate(c)
            gate.finish(.success(42))
            // Real WatchConnectivity can deliver a reply after the timeout handler has run.
            for _ in 0..<100 { DispatchQueue.global().async { gate.finish(.failure(RelayFailure(message: "late"))) } }
        }
        XCTAssertEqual(value,42)
    }
    func testCookieRestoreRejectsOtherSitesAndExpiredSessions() {
        let foreign = HTTPCookie(properties:[.name:"session",.value:"fake",.domain:"accounts.google.com",.path:"/",.secure:"TRUE"])!
        XCTAssertNil(SessionCookie(foreign).cookie)
        let expired = HTTPCookie(properties:[.name:"session",.value:"fake",.domain:"chatgpt.com",.path:"/",.secure:"TRUE",.expires:Date(timeIntervalSinceNow:-30)])!
        XCTAssertNil(SessionCookie(expired).cookie)
        let valid = HTTPCookie(properties:[.name:"session",.value:"fake",.domain:".chatgpt.com",.path:"/api",.secure:"TRUE",.expires:Date(timeIntervalSinceNow:3600)])!
        let restored = SessionCookie(valid).cookie
        XCTAssertTrue(restored?.isSecure == true)
        XCTAssertEqual(restored?.domain,".chatgpt.com")
        XCTAssertEqual(restored?.path,"/api")
        XCTAssertEqual(restored?.value,"fake")
    }

    @MainActor func testRefreshRejectsExpiredTokenAndWrongAccountBeforeSaving() throws {
        let original = try account(expiration: Date().timeIntervalSince1970 + 3600)
        let ok = HTTPURLResponse(url: URL(string: "https://chatgpt.com/api/auth/session")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        func payload(_ token: String, id: String = "test") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["accessToken": token, "account": ["id": id]])
        }
        XCTAssertThrowsError(try DotSession.refreshedAccount(data: payload(original.token, id: "different-account"), response: ok, original: original))
        XCTAssertThrowsError(try DotSession.refreshedAccount(data: payload(account(expiration: 0).token), response: ok, original: original))
        XCTAssertThrowsError(try DotSession.refreshedAccount(data: payload("malformed"), response: ok, original: original))
        let next = try DotSession.refreshedAccount(data: payload(original.token), response: ok, original: original)
        XCTAssertEqual(next.dotID, original.dotID)
        XCTAssertEqual(next.accountID, original.accountID)
        XCTAssertEqual(next.threadID, original.threadID)
    }
    @MainActor func testExpiredSessionResponseNeedsSignIn() throws {
        let original = try account(expiration: 0)
        let denied = HTTPURLResponse(url: URL(string: "https://chatgpt.com/api/auth/session")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try DotSession.refreshedAccount(data: Data("{}".utf8), response: denied, original: original)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Refresh login"))
        }
    }

}
