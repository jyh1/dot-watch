import Foundation

// Bounded queues isolate Network and AVAudioEngine callbacks from codec work.
public final class DirectAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Dot.opus", qos: .userInteractive)
    private let lock = NSLock()
    private let codec: OpusCodec
    private let peer: DirectPeer
    private let capture: PacketCapture?
    private var timer: DispatchSourceTimer?
    private var input = Data(), output = Data()
    private var muted = false
    private let receiver: NetEqReceiver
    private var nextMicrophoneAt = 0.0
    private var nextReportAt = 0.0
    private var receiveMetrics: [String: Int] = [:]
    private var lastPacketAt = ProcessInfo.processInfo.systemUptime
    private var running = false
    private var lastFailure: String?
    private var received = 0, sent = 0, decodedPeak = 0, outputDrops = 0
    public init(peer: DirectPeer, capture: PacketCapture? = nil) throws {
        guard capture == nil || capture?.mediaFormat == .neteq48k else { throw DirectRTCError("NetEq calls require a 48 kHz diagnostic capture.") }
        self.peer = peer; self.capture = capture
        codec = try OpusCodec(); receiver = try NetEqReceiver(now: ProcessInfo.processInfo.systemUptime)
    }
    public func start() {
        queue.sync {
            guard !running else { return }; running = true
            lastPacketAt = ProcessInfo.processInfo.systemUptime
            capture?.beginMediaTimeline(uptime: lastPacketAt)
            nextMicrophoneAt = lastPacketAt; nextReportAt = lastPacketAt + 1
            peer.onOpus = { [weak self] data, sequence, timestamp in
                let arrival = ProcessInfo.processInfo.systemUptime
                self?.queue.async { [weak self] in
                    guard let self, self.running else { return }
                    let processing = ProcessInfo.processInfo.systemUptime
                    self.capture?.record(payload: data, sequence: sequence, timestamp: timestamp, arrivalUptime: arrival, processingUptime: processing)
                    do { try self.receiver.insert(data, sequence: sequence, timestamp: timestamp, arrival: arrival, processing: processing) }
                    catch { self.fail(error); return }
                    self.lastPacketAt = arrival
                    self.lock.lock(); self.received += 1; self.lock.unlock()
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    public func push(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !muted else { return }
        input.append(data)
        if input.count > 4800 { input.removeFirst(input.count - 4800) }
    }
    public func mute(_ value: Bool) { lock.lock(); muted = value; input.removeAll(); lock.unlock() }
    public func takeOutput() -> Data { lock.lock(); defer { lock.unlock() }; let data = output; output.removeAll(keepingCapacity: true); return data }
    public var failure: String? { lock.lock(); defer { lock.unlock() }; return lastFailure }
    public var statistics: [String: Int] { lock.lock(); defer { lock.unlock() }; return receiveMetrics.merging(["receivedPackets": received, "sentPackets": sent, "decodedPeak": decodedPeak, "outputDrops": outputDrops]) { _, new in new } }
    private func tick() {
        guard running else { return }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextMicrophoneAt {
                lock.lock()
                let count = min(input.count, 960)
                var frame = Data(input.prefix(count)); input.removeFirst(count)
                lock.unlock()
                if frame.count < 960 { frame.append(Data(count: 960 - frame.count)) }
                try peer.sendOpus(codec.encode(frame))
                lock.lock(); sent += 1; lock.unlock()
                // Keep the 20 ms phase, but never replay coalesced microphone ticks.
                nextMicrophoneAt += (floor((now - nextMicrophoneAt) / 0.02) + 1) * 0.02
            }
            let renderTime = ProcessInfo.processInfo.systemUptime
            capture?.recordRender(uptime: renderTime)
            let decoded = try receiver.render(now: renderTime)
            var peak = 0
            decoded.withUnsafeBytes { b in for i in stride(from: 0, to: decoded.count, by: 2) { peak = max(peak, abs(Int(b.loadUnaligned(fromByteOffset:i, as:Int16.self)))) } }
            let statistics = receiver.statistics
            lock.lock(); receiveMetrics = statistics; decodedPeak = max(decodedPeak, peak); output.append(decoded)
            if output.count > 19200 { output.removeFirst(output.count - 19200); outputDrops += 1 }
            lock.unlock()
            if now >= nextReportAt { try peer.sendReport(); nextReportAt = now + 1 }
            if let error = peer.failure { throw DirectRTCError(error) }
            if ProcessInfo.processInfo.systemUptime - lastPacketAt > 30 { throw DirectRTCError("No audio received from the call server for 30 seconds.") }
        } catch {
            fail(error)
        }
    }
    private func fail(_ error: Error) {
        lock.lock(); lastFailure = error.localizedDescription; lock.unlock()
        running = false; timer?.cancel(); timer = nil
    }
    public func stop() {
        queue.sync { running = false; timer?.cancel(); timer = nil; peer.onOpus = nil; try? receiver.reset(now: ProcessInfo.processInfo.systemUptime) }
        lock.lock(); input.removeAll(); output.removeAll(); lock.unlock()
    }
}
