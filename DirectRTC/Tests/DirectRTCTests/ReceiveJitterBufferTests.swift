import XCTest
@testable import DirectRTC
final class ReceiveJitterBufferTests: XCTestCase {
    private func packet(_ duration: Int) -> Data {
        switch duration {
        case 120: return Data([0x80])
        case 480: return Data([0x00])
        case 960: return Data([0x08])
        case 1920: return Data([0x10])
        case 2880: return Data([0x18])
        default: return Data([0x1b, 2])
        }
    }
    private func decode(_ data: Data) -> Data { Data(repeating: 1, count: ReceiveJitterBuffer.opusDuration(data)!) }
    func testOpusDurationsAndInvalidCounts() {
        for duration in [120, 480, 960, 1920, 2880, 5760] { XCTAssertEqual(ReceiveJitterBuffer.opusDuration(packet(duration)), duration) }
        XCTAssertNil(ReceiveJitterBuffer.opusDuration(Data([0x1b, 3])))
        XCTAssertNil(ReceiveJitterBuffer.opusDuration(Data([0x1b, 0])))
    }
    func testReorderDuplicatesAndWrap() throws {
        var buffer = ReceiveJitterBuffer()
        let start = UInt32.max - 959
        buffer.insert(data: packet(960), sequence: .max, timestamp: start, now: 0)
        buffer.insert(data: packet(960), sequence: 1, timestamp: start &+ 1920, now: 0.02)
        buffer.insert(data: packet(960), sequence: 0, timestamp: start &+ 960, now: 0.03)
        buffer.insert(data: packet(960), sequence: 0, timestamp: start &+ 960, now: 0.04)
        XCTAssertEqual(try buffer.render(now: 0.09, decode: decode), Data(count: 960))
        for time in [0.1, 0.12, 0.14] { XCTAssertEqual(try buffer.render(now: time, decode: decode), Data(repeating: 1, count: 960)) }
        XCTAssertEqual(buffer.metrics["duplicatePackets"], 1)
        XCTAssertEqual(buffer.metrics["concealedFrames"], 0)
        buffer.insert(data: packet(960), sequence: .max, timestamp: start, now: 0.15)
        XCTAssertEqual(buffer.metrics["latePackets"], 1)
    }
    func testVariableDurationsProduceTwentyMillisecondFrames() throws {
        var buffer = ReceiveJitterBuffer()
        var timestamp: UInt32 = 0
        for (index, duration) in [120,120,120,120,480,1920,2880,5760].enumerated() {
            buffer.insert(data: packet(duration), sequence: UInt16(index), timestamp: timestamp, now: 0)
            timestamp += UInt32(duration)
        }
        for i in 0..<12 { XCTAssertEqual(try buffer.render(now: 0.1 + Double(i)*0.02, decode: decode), Data(repeating: 1, count: 960)) }
        XCTAssertEqual(buffer.metrics["concealedFrames"], 0)
    }
    func testLossRebuffersAndSilenceResumes() throws {
        var buffer = ReceiveJitterBuffer()
        buffer.insert(data: packet(960), sequence: 0, timestamp: 0, now: 0)
        _ = try buffer.render(now: 0.1, decode: decode)
        for i in 1...3 { XCTAssertEqual(try buffer.render(now: 0.1+Double(i)*0.02, decode: decode).count, 960) }
        XCTAssertEqual(buffer.metrics["rebufferCount"], 1)
        for i in 9..<50 { _ = try buffer.render(now: Double(i)*0.02, decode: decode) }
        buffer.insert(data: packet(960), sequence: 1, timestamp: 48000, now: 1)
        for i in 50..<55 { XCTAssertEqual(try buffer.render(now: Double(i)*0.02, decode: decode), Data(count: 960)) }
        let resumed = try buffer.render(now: 1.101, decode: decode)
        XCTAssertEqual(resumed.suffix(720), Data(repeating: 1, count: 720))
        XCTAssertEqual(buffer.metrics["decodedPackets"], 2)
    }
    func testBurstAndSchedulerStallAreBounded() throws {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<100 { buffer.insert(data: packet(960), sequence: UInt16(i), timestamp: UInt32(i*960), now: 0) }
        XCTAssertGreaterThan(buffer.metrics["rebufferCount", default: 0], 0)
        _ = try buffer.render(now: 0.1, decode: decode)
        XCTAssertEqual(try buffer.render(now: 0.32, decode: decode), Data(count: 960))
        XCTAssertEqual(buffer.metrics["schedulerStalls"], 1)
    }
}

extension ReceiveJitterBufferTests {
    func testTenSecondJitterTraceHasContinuousPlayout() throws {
        var buffer = ReceiveJitterBuffer()
        var arrivals: [(Double, Int)] = []
        for i in 0..<500 {
            let jitter = [0.0, 0.04, -0.02, 0.02, -0.01][i % 5]
            arrivals.append((0.04 + Double(i)*0.02 + jitter, i))
            if i % 31 == 0 { arrivals.append((0.05 + Double(i)*0.02 + jitter, i)) }
        }
        arrivals.sort { $0.0 < $1.0 }
        var index = 0, rendered = 0
        for tick in 0..<510 {
            let now = Double(tick)*0.02
            while index < arrivals.count && arrivals[index].0 <= now + 0.000001 {
                let i = arrivals[index].1
                buffer.insert(data: packet(960), sequence: UInt16(i), timestamp: UInt32(i*960), now: arrivals[index].0)
                index += 1
            }
            let output = try buffer.render(now: now, decode: decode)
            if output == Data(repeating: 1, count: 960) { rendered += 1 }
        }
        XCTAssertEqual(rendered, 500)
        XCTAssertEqual(buffer.metrics["latePackets"], 0)
        XCTAssertEqual(buffer.metrics["schedulerStalls"], 0)
        XCTAssertGreaterThan(buffer.metrics["duplicatePackets", default: 0], 0)
        XCTAssertLessThanOrEqual(buffer.metrics["targetBufferMs", default: 0], 200)
    }
    func testShortPacketLossRetainsFollowingPackets() throws {
        var buffer = ReceiveJitterBuffer()
        for i in [0,2,3,4,5,6,7] {
            buffer.insert(data: packet(120), sequence: UInt16(i), timestamp: UInt32(i*120), now: 0)
        }
        let output = try buffer.render(now: 0.1, decode: decode)
        XCTAssertEqual(output.count, 960)
        XCTAssertEqual(buffer.metrics["decodedPackets"], 7)
        XCTAssertEqual(buffer.metrics["concealedFrames"], 1)
    }
    func testPrimingIsAccountedOnceWithoutDurationDrift() throws {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<5 { buffer.insert(data: packet(960), sequence: UInt16(i), timestamp: UInt32(i*960), now: 0) }
        var first = true
        for i in 0..<5 {
            let output = try buffer.render(now: 0.1 + Double(i)*0.02) { _ in
                defer { first = false }
                return Data(repeating: 1, count: first ? 720 : 960)
            }
            XCTAssertEqual(output.count, 960)
        }
        XCTAssertEqual(buffer.metrics["decoderPrimingFrames"], 1)
        XCTAssertEqual(buffer.metrics["decoderShortPackets", default: 0], 0)
        XCTAssertEqual(buffer.metrics["concealedFrames"], 0)
    }
    func testStallDiscardsStalePackets() throws {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<10 { buffer.insert(data: Data([0x08, UInt8(i)]), sequence: UInt16(i), timestamp: UInt32(i*960), now: 0) }
        let decoder: (Data) -> Data = { Data(repeating: $0.last!, count: 960) }
        _ = try buffer.render(now: 0.1, decode: decoder)
        XCTAssertEqual(try buffer.render(now: 0.36, decode: decoder), Data(count: 960))
        buffer.insert(data: Data([0x08, 0]), sequence: 0, timestamp: 0, now: 0.37)
        XCTAssertEqual(buffer.metrics["latePackets"], 1)
        var resumed = false
        for i in 1...10 {
            let frame = try buffer.render(now: 0.36 + Double(i)*0.02, decode: decoder)
            if buffer.metrics["decodedPackets"] == 2 {
                XCTAssertEqual(frame, Data(repeating: 9, count: 960)); resumed = true; break
            }
        }
        XCTAssertTrue(resumed)
    }
    func testAdaptiveTargetGrowsWithinBounds() {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<40 { buffer.insert(data: packet(960), sequence: UInt16(i), timestamp: UInt32(i*960), now: Double(i)*0.02) }
        let stable = buffer.metrics["targetBufferMs"]!
        for i in 40..<80 { buffer.insert(data: packet(960), sequence: UInt16(i), timestamp: UInt32(i*960), now: Double(i)*0.02 + (i % 2 == 0 ? 0.08 : 0)) }
        XCTAssertGreaterThan(buffer.metrics["targetBufferMs"]!, stable)
        XCTAssertLessThanOrEqual(buffer.metrics["targetBufferMs"]!, 200)
    }
}

extension ReceiveJitterBufferTests {
    func testConsumedDuplicateCannotRestartEmptyBuffer() throws {
        var buffer = ReceiveJitterBuffer()
        buffer.insert(data: packet(960), sequence: 0, timestamp: 0, now: 0)
        for i in 0..<4 { _ = try buffer.render(now: 0.1 + Double(i)*0.02, decode: decode) }
        buffer.insert(data: packet(960), sequence: 0, timestamp: 0, now: 0.17)
        XCTAssertEqual(buffer.metrics["latePackets"], 1)
        for i in 4..<12 { XCTAssertEqual(try buffer.render(now: 0.1 + Double(i)*0.02, decode: decode), Data(count: 960)) }
        XCTAssertEqual(buffer.metrics["decodedPackets"], 1)
    }
}

extension ReceiveJitterBufferTests {
    func testNewSequenceCanResetSourceClockBackward() throws {
        var buffer = ReceiveJitterBuffer()
        buffer.insert(data: packet(960), sequence: 10, timestamp: 1_000_000, now: 0)
        _ = try buffer.render(now: 0.1, decode: decode)
        buffer.insert(data: packet(960), sequence: 11, timestamp: 1000, now: 0.11)
        XCTAssertEqual(buffer.metrics["timestampResets"], 1)
        buffer.insert(data: packet(960), sequence: 10, timestamp: 1_000_000, now: 0.12)
        for i in 6...10 { _ = try buffer.render(now: Double(i)*0.02, decode: decode) }
        XCTAssertEqual(try buffer.render(now: 0.211, decode: decode), Data(repeating: 1, count: 960))
        XCTAssertEqual(buffer.metrics["decodedPackets"], 2)
    }
}

extension ReceiveJitterBufferTests {
    func testEmptyStarvationRefillPreservesDelayedPacketAndBoundedReserve() throws {
        var buffer = ReceiveJitterBuffer()
        buffer.insert(data: Data([0x08, 1]), sequence: 0, timestamp: 0, now: 0)
        let decoder: (Data) -> Data = { Data(repeating: $0.last!, count: 960) }
        _ = try buffer.render(now: 0.1, decode: decoder)
        for i in 1...3 { _ = try buffer.render(now: 0.1 + Double(i)*0.02, decode: decoder) }
        buffer.insert(data: Data([0x08, 2]), sequence: 1, timestamp: 960, now: 0.17)
        buffer.insert(data: Data([0x08, 3]), sequence: 2, timestamp: 1920, now: 0.18)
        var resumed = false
        for i in 4..<12 {
            let output = try buffer.render(now: 0.1 + Double(i)*0.02, decode: decoder)
            if buffer.metrics["decodedPackets"] == 2 {
                XCTAssertEqual(output.suffix(720), Data(repeating: 2, count: 720)); resumed = true; break
            }
        }
        XCTAssertTrue(resumed)
        XCTAssertEqual(buffer.metrics["latePackets"], 0)
        XCTAssertEqual(buffer.metrics["rebufferCount"], 1)
        XCTAssertEqual(buffer.metrics["starvationPCMBytes"], 2880)
    }
    func testKnownGapAfterStarvationDoesNotInheritStarvationStreak() throws {
        var buffer = ReceiveJitterBuffer()
        buffer.insert(data: packet(960), sequence: 0, timestamp: 0, now: 0)
        _ = try buffer.render(now: 0.1, decode: decode)
        for time in [0.12, 0.14] { _ = try buffer.render(now: time, decode: decode) }
        buffer.insert(data: packet(960), sequence: 2, timestamp: 1920, now: 0.15)
        _ = try buffer.render(now: 0.16, decode: decode)
        XCTAssertEqual(buffer.metrics["rebufferCount"], 0)
        _ = try buffer.render(now: 0.18, decode: decode)
        XCTAssertEqual(buffer.metrics["decodedPackets"], 2)
        XCTAssertEqual(buffer.metrics["knownGapPCMBytes"], 960)
    }
    func testNinetyMillisecondSchedulerPausePreservesQueuedSpeech() throws {
        var buffer = ReceiveJitterBuffer()
        for i in 0..<10 { buffer.insert(data: Data([0x08, UInt8(i+1)]), sequence: UInt16(i), timestamp: UInt32(i*960), now: 0) }
        let decoder: (Data) -> Data = { Data(repeating: $0.last!, count: 960) }
        _ = try buffer.render(now: 0.1, decode: decoder)
        XCTAssertEqual(try buffer.render(now: 0.191, decode: decoder), Data(repeating: 2, count: 960))
        XCTAssertEqual(buffer.metrics["preservedSchedulerStalls"], 1)
        XCTAssertEqual(buffer.metrics["rebufferCount"], 0)
    }
}

extension ReceiveJitterBufferTests {
    func testSlowProducerDoesNotLoseValidSpeechOrAccumulateLatency() throws {
        var buffer = ReceiveJitterBuffer()
        var nextPacket = 0, decodedPackets = 0, maximumAge = 0.0
        for tick in 0..<1270 {
            let now = Double(tick)*0.02
            while nextPacket < 1000 && 0.02 + Double(nextPacket)*0.025 <= now {
                let arrival = 0.02 + Double(nextPacket)*0.025
                buffer.insert(data: packet(960), sequence: UInt16(nextPacket), timestamp: UInt32(nextPacket*960), now: arrival)
                nextPacket += 1
            }
            _ = try buffer.render(now: now, onDecoded: { timestamp in
                let arrival = 0.02 + Double(timestamp / 960)*0.025
                maximumAge = max(maximumAge, now - arrival); decodedPackets += 1
            }, decode: decode)
        }
        XCTAssertEqual(decodedPackets, 1000)
        XCTAssertEqual(buffer.metrics["latePackets"], 0)
        XCTAssertGreaterThan(buffer.metrics["starvationPCMBytes", default: 0], 0)
        XCTAssertLessThanOrEqual(maximumAge, 0.20)
        XCTAssertLessThanOrEqual(buffer.metrics["maximumBufferedMs", default: 0], 500)
    }
}
