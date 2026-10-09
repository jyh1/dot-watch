import Foundation

// All media work and cancellation share one queue. stop() drains any in-flight
// delivery before returning, so the owner can then tear down its audio engine.
final class CallAudioPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DotWatch.call-media", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private let tick: @Sendable (Bool) -> Bool
    private var generation = 0
    private var lastReport: UInt64 = 0

    init(tick: @escaping @Sendable (Bool) -> Bool) {
        self.tick = tick
        queue.setSpecific(key: queueKey, value: 1)
    }
    func start() {
        queue.sync {
            guard timer == nil else { return }
            generation += 1
            let attempt = generation
            lastReport = DispatchTime.now().uptimeNanoseconds
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in
                guard let self, self.timer != nil, self.generation == attempt else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let reportDue = now - self.lastReport >= 5_000_000_000
                if reportDue { self.lastReport = now }
                if !self.tick(reportDue) { self.cancel() }
            }
            timer = source
            source.resume()
        }
    }
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { cancel() }
        else { queue.sync { cancel() } }
    }
    private func cancel() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }
    deinit { stop() }
}
