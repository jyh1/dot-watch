import Foundation
import XCTest

private final class LostConnectionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    static var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chatgpt.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let attempt = Self.count; Self.lock.unlock()
        if attempt == 1 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class HTTPRetryTests: XCTestCase {
    private func makeHTTP() throws -> DotHTTP {
        let claim = try JSONSerialization.data(withJSONObject: ["exp":Date().timeIntervalSince1970 + 3600]).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let account = DotAccount(token: "test.\(claim).test", accountID: "test", dotID: "test", threadID: "test", name: "Test", deviceID: nil)
        let http = DotHTTP(account)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LostConnectionProtocol.self]
        http.session = URLSession(configuration: config)
        LostConnectionProtocol.reset()
        return http
    }
    func testStopRetriesOneLostConnection() async throws {
        let http = try makeHTTP(); defer { http.session.invalidateAndCancel() }
        let (_, response) = try await http.request(action: "stop", callID: "rtc_test")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(LostConnectionProtocol.attempts, 2)
    }
    func testCreateDoesNotRetryAndRiskAllocatingAnotherCall() async throws {
        let http = try makeHTTP(); defer { http.session.invalidateAndCancel() }
        do {
            _ = try await http.request(action: "create", sdp: "test")
            XCTFail("Create should report the lost connection.")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertEqual(LostConnectionProtocol.attempts, 1)
    }
}
