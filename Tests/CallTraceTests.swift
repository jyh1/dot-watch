import XCTest

final class CallTraceTests: XCTestCase {
    func testAllMediaCountersSurviveWatchForwardingLimit() {
        var metrics = ["receivedPackets": 123456, "outputDrops": 0, "schedulerStalls": 12]
        for duration in stride(from: 120, through: 5760, by: 120) {
            metrics["packetDurationTicks_\(duration)"] = duration
        }
        let lines = CallTrace.mediaStatistics(metrics)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 280 })
        let items = lines.flatMap { $0.dropFirst("Call media: ".count).split(separator: " ").map(String.init) }
        XCTAssertEqual(Set(items), Set(metrics.map { "\($0.key)=\($0.value)" }))
        XCTAssertEqual(items.count, metrics.count)
        XCTAssertEqual(lines, CallTrace.mediaStatistics(metrics))
    }
}
