import XCTest
@testable import DirectRTC

final class SourceDescriptionTests: XCTestCase {
    func testCnamePacketLengthAndPadding() {
        let packet = DirectPeer.sourceDescription(ssrc: 0x12345678)
        XCTAssertEqual(packet.count % 4, 0)
        XCTAssertEqual((Int(packet[2]) * 256 + Int(packet[3]) + 1) * 4, packet.count)
        XCTAssertEqual(Array(packet[4..<8]), [0x12,0x34,0x56,0x78])
        let end = 10 + Int(packet[9])
        XCTAssertEqual(String(bytes: packet[10..<end], encoding: .utf8), "dotwatch")
        XCTAssertTrue(packet[end...].allSatisfy { $0 == 0 })
    }
}
