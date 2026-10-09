import XCTest

final class PlaybackQueueTests: XCTestCase {
    func testNative48kFramesKeepPlaybackDurationAndGenerationBound() {
        var queue = PlaybackQueue(sampleRate: 48000)
        for _ in 0..<50 { XCTAssertFalse(queue.admit(frames: 480).reset) }
        XCTAssertEqual(queue.seconds, 0.5, accuracy: 0.0001)
        let stale = queue.generation
        let next = queue.admit(frames: 480)
        XCTAssertTrue(next.reset)
        XCTAssertEqual(queue.seconds, 0.01, accuracy: 0.0001)
        XCTAssertFalse(queue.complete(frames: 480, generation: stale))
        XCTAssertTrue(queue.complete(frames: 480, generation: next.generation))
        XCTAssertEqual(queue.seconds, 0)
    }

    func testVariableChunksUseDurationInsteadOfBufferCount() {
        var queue = PlaybackQueue()
        for _ in 0..<20 { XCTAssertFalse(queue.admit(frames: 240).reset) }
        XCTAssertEqual(queue.seconds, 0.2, accuracy: 0.0001)
        XCTAssertFalse(queue.admit(frames: 7200).reset)
        XCTAssertEqual(queue.seconds, 0.5, accuracy: 0.0001)
        XCTAssertTrue(queue.admit(frames: 480).reset)
        XCTAssertEqual(queue.frames, 480)
        XCTAssertEqual(queue.resets, 1)
    }
    func testDelayedCallbacksAllowRouteLatencyWithoutReset() {
        var queue = PlaybackQueue()
        queue.updateRoute(outputLatency: 0.4, ioBufferDuration: 0.02)
        for _ in 0..<30 { XCTAssertFalse(queue.admit(frames: 480).reset) }
        XCTAssertEqual(queue.maximumSeconds, 0.6, accuracy: 0.0001)
        XCTAssertEqual(queue.outputLatency, 0.4)
    }
    func testBacklogResetIgnoresLateCallbacks() {
        var queue = PlaybackQueue()
        let old = queue.admit(frames: 12000)
        let new = queue.admit(frames: 480)
        XCTAssertTrue(new.reset)
        XCTAssertFalse(queue.complete(frames: 12000, generation: old.generation))
        XCTAssertEqual(queue.frames, 480)
        XCTAssertTrue(queue.complete(frames: 480, generation: new.generation))
        XCTAssertEqual(queue.frames, 0)
        XCTAssertEqual(queue.buffers, 0)
    }
    func testLifecycleClearInvalidatesCallbacksAndRouteBoundIsFinite() {
        var queue = PlaybackQueue()
        queue.updateRoute(outputLatency: 100, ioBufferDuration: 100)
        let old = queue.admit(frames: 36000)
        XCTAssertTrue(queue.admit(frames: 480).reset)
        queue.clear()
        XCTAssertFalse(queue.complete(frames: 36000, generation: old.generation))
        XCTAssertEqual(queue.frames, 0)
        queue.updateRoute(outputLatency: .nan, ioBufferDuration: .infinity)
        XCTAssertFalse(queue.admit(frames: 12000).reset)
        XCTAssertTrue(queue.admit(frames: 480).reset)
    }
}
