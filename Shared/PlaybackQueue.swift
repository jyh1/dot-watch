import Foundation

// Access under CallAudio's lock. Played-back callbacks can arrive after a reset.
struct PlaybackQueue {
    struct Admission {
        let generation: Int
        let reset: Bool
    }
    private(set) var frames = 0
    private(set) var buffers = 0
    private(set) var generation = 0
    private(set) var resets = 0
    private(set) var maximumSeconds: Double = 0
    private(set) var outputLatency: Double = 0
    private var limitSeconds = 0.5
    private let sampleRate: Double

    init(sampleRate: Double = 24000) {
        precondition(sampleRate.isFinite && sampleRate > 0)
        self.sampleRate = sampleRate
    }

    mutating func updateRoute(outputLatency: Double, ioBufferDuration: Double) {
        self.outputLatency = outputLatency.isFinite ? max(0, outputLatency) : 0
        let io = ioBufferDuration.isFinite ? max(0, ioBufferDuration) : 0
        // Keep normal device latency plus a scheduling margin; bound stale replies.
        limitSeconds = min(1.5, max(0.5, self.outputLatency + 2 * io + 0.25))
    }
    var seconds: Double { Double(frames) / sampleRate }
    mutating func admit(frames newFrames: Int) -> Admission {
        // A single oversized chunk cannot be fixed by discarding its predecessors.
        let reset = frames > 0 && Double(frames + newFrames) / sampleRate > limitSeconds
        if reset { clear(); resets += 1 }
        frames += newFrames; buffers += 1
        maximumSeconds = max(maximumSeconds, seconds)
        return Admission(generation: generation, reset: reset)
    }
    @discardableResult
    mutating func complete(frames completedFrames: Int, generation completedGeneration: Int) -> Bool {
        guard completedGeneration == generation else { return false }
        frames = max(0, frames - completedFrames); buffers = max(0, buffers - 1)
        return true
    }
    mutating func clear() { frames = 0; buffers = 0; generation += 1 }
}
