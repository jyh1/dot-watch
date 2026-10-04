import Foundation

// Bounded queues isolate Network and AVAudioEngine callbacks from codec work.
public final class DirectAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Dot.opus", qos: .userInteractive)
    private let lock = NSLock()
    private let codec: OpusCodec
    private let peer: DirectPeer
    private var timer: DispatchSourceTimer?
    private var input = Data(), output = Data()
    private var muted = false
    private var packets: [UInt16: Data] = [:]
    private var expected: UInt16?
    private var firstPacketAt: Date?
    private var lastPacketAt = Date()
    private var running = false
    private var tickNumber = 0
    private var lastFailure: String?
    private var received = 0, sent = 0, decodedPeak = 0
    public init(peer: DirectPeer) throws { self.peer = peer; codec = try OpusCodec() }
    public func start() {
        queue.sync {
            guard !running else { return }; running = true
            lastPacketAt = Date()
            peer.onOpus = { [weak self] data, sequence, _ in
                self?.queue.async { [weak self] in
                    guard let self, self.running else { return }
                    if let expected = self.expected, Int16(bitPattern: sequence &- expected) < 0 { return }
                    if self.expected == nil { self.expected = sequence; self.firstPacketAt = Date() }
                    if self.packets.count >= 50 { self.packets.removeAll(); self.expected = sequence; self.firstPacketAt = Date() }
                    self.packets[sequence] = data; self.lastPacketAt = Date()
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
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
    public var statistics: [String: Int] { lock.lock(); defer { lock.unlock() }; return ["receivedPackets": received, "sentPackets": sent, "decodedPeak": decodedPeak] }
    private func tick() {
        guard running else { return }
        do {
            lock.lock()
            let count = min(input.count, 960)
            var frame = Data(input.prefix(count)); input.removeFirst(count)
            lock.unlock()
            if frame.count < 960 { frame.append(Data(count: 960 - frame.count)) }
            try peer.sendOpus(codec.encode(frame))
            var decoded = Data()
            if let expected, let firstPacketAt, Date().timeIntervalSince(firstPacketAt) >= 0.06 {
                if let packet = packets.removeValue(forKey: expected) {
                    self.expected = expected &+ 1
                    decoded = try codec.decode(packet)
                    lock.lock(); received += 1; lock.unlock()
                } else if !packets.isEmpty {
                    self.expected = expected &+ 1
                    decoded = Data(count: 960)
                }
            }
            var peak = 0
            decoded.withUnsafeBytes { b in for i in stride(from: 0, to: decoded.count, by: 2) { peak = max(peak, abs(Int(b.loadUnaligned(fromByteOffset:i, as:Int16.self)))) } }
            lock.lock(); sent += 1; decodedPeak = max(decodedPeak, peak); output.append(decoded)
            if output.count > 9600 { output.removeFirst(output.count - 9600) }
            lock.unlock()
            tickNumber += 1
            if tickNumber % 50 == 0 { try peer.sendReport() }
            if let error = peer.failure { throw DirectRTCError(error) }
            if Date().timeIntervalSince(lastPacketAt) > 30 { throw DirectRTCError("No audio received from the call server for 30 seconds.") }
        } catch {
            lock.lock(); lastFailure = error.localizedDescription; lock.unlock()
            running = false; timer?.cancel(); timer = nil
        }
    }
    public func stop() {
        queue.sync { running = false; timer?.cancel(); timer = nil; peer.onOpus = nil; packets.removeAll() }
        lock.lock(); input.removeAll(); output.removeAll(); lock.unlock()
    }
}
