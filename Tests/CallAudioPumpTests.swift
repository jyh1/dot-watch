import XCTest

final class CallAudioPumpTests: XCTestCase {
    func testDeliveryContinuesWhileMainThreadIsBlocked() {
        let delivered = DispatchSemaphore(value: 0)
        let pump = CallAudioPump { _ in
            XCTAssertFalse(Thread.isMainThread)
            delivered.signal()
            return true
        }
        pump.start()
        // A synchronous wait prevents main-actor work from servicing delivery.
        for _ in 0..<5 { XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success) }
        pump.stop()
    }

    func testStopDrainsInFlightDeliveryBeforeTeardown() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let pump = CallAudioPump { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return true
        }
        pump.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { pump.stop(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success)
    }

    func testStopAndRestartDoNotDeliverStaleTicks() {
        let counter = PumpTestCounter()
        let pump = CallAudioPump { _ in counter.increment(); return true }
        pump.start()
        Thread.sleep(forTimeInterval: 0.06)
        pump.stop()
        let stoppedCount = counter.value
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertEqual(counter.value, stoppedCount)
        pump.start()
        Thread.sleep(forTimeInterval: 0.06)
        pump.stop()
        XCTAssertGreaterThan(counter.value, stoppedCount)
        pump.stop()
    }

    func testFailedTickStopsFurtherDelivery() {
        let stopped = DispatchSemaphore(value: 0)
        let counter = PumpTestCounter()
        let pump = CallAudioPump { _ in
            counter.increment()
            stopped.signal()
            return false
        }
        pump.start()
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.06)
        pump.stop()
        XCTAssertEqual(counter.value, 1)
    }
}

private final class PumpTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
