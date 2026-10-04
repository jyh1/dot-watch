import XCTest
@testable import DirectRTC
final class SignalingTests: XCTestCase {
    func testOversizedAnswerRejectedBeforeNetwork() async throws {
        let peer = try DirectPeer(); defer { peer.close() }
        do { try await peer.connect(answer: String(repeating:"x",count:65537)); XCTFail("Accepted oversized SDP") }
        catch { XCTAssertTrue(error.localizedDescription.contains("size limit")) }
        XCTAssertFalse(peer.mediaReady)
    }
    func testMissingFingerprintRejectedBeforeNetwork() async throws {
        let peer = try DirectPeer(); defer { peer.close() }
        let missing = peer.offer.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(decoding:$0,as:UTF8.self) }.filter { !$0.hasPrefix("a=fingerprint:") }.joined(separator:"\n")
        do { try await peer.connect(answer:missing); XCTFail("Accepted unauthenticated answer") }
        catch { XCTAssertTrue(error.localizedDescription.contains("security settings")) }
        XCTAssertFalse(peer.mediaReady)
    }
    func testConflictingBundleIdentityRejectedBeforeNetwork() async throws {
        let peer = try DirectPeer(); defer { peer.close() }
        let sdp = peer.offer + "a=ice-pwd:conflicting-password-123456789\r\n"
        do { try await peer.connect(answer:sdp); XCTFail("Accepted conflicting identities") }
        catch { XCTAssertTrue(error.localizedDescription.contains("security settings")) }
        XCTAssertFalse(peer.mediaReady)
    }
    func testRejectedAudioCannotBecomeCall() async throws {
        let peer = try DirectPeer(); defer { peer.close() }
        do { try await peer.connect(answer: peer.offer.replacingOccurrences(of:"m=audio 9",with:"m=audio 0")); XCTFail("Accepted rejected audio") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Opus audio")) }
        XCTAssertFalse(peer.mediaReady)
    }
}
