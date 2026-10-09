import Foundation

// RTP uses a 48 kHz clock even though the decoded mono PCM is 24 kHz.
// This is bounded jitter buffering with faded repeat concealment, not Opus PLC/FEC.
struct ReceiveJitterBuffer {
    struct Packet { let sequence: UInt16; let timestamp: UInt32; let duration: Int; let data: Data }
    private var packets: [UInt32: Packet] = [:]
    private struct Segment { let timestamp: UInt32?; var bytes: Int }
    private var segments: [Segment] = []
    private var compressor = AdaptiveTimeCompressor()
    private var accelerating = false
    private let backlogLimitTicks: Int
    private let compressionEnabled: Bool
    private let maximumSpeed: Double
    init(backlogLimitTicks: Int = 24000, compressionEnabled: Bool = false, maximumSpeed: Double = 1.10) {
        self.backlogLimitTicks = backlogLimitTicks; self.compressionEnabled = compressionEnabled; self.maximumSpeed = maximumSpeed
    }
    private var anchor: UInt32?
    private var cursor: UInt32?
    private var consumedUntil: UInt32?
    private var readyAt: Double = 0
    private var lastArrival: Double = 0
    private var lastRender: Double?
    private var pcm = Data()
    private var lastFrame = Data(count: 960)
    private var missing = 0
    private var knownGapCount = 0
    private var newestSequence: UInt16?
    private var decodedOnce = false
    private(set) var metrics: [String: Int] = ["latePackets": 0, "duplicatePackets": 0, "concealedFrames": 0, "rebufferCount": 0, "timestampResets": 0, "schedulerStalls": 0, "maximumBufferedMs": 0]
    private var cushion = 0.10
    private var variation = 0.0
    private var newestArrival: Double?
    private var newestTimestamp: UInt32?
    private var recovering = false
    var diagnosticCursor: UInt32? { cursor ?? consumedUntil }
    var diagnosticBufferedPackets: Int { packets.count }
    private func delta(_ a: UInt32, _ b: UInt32) -> Int { Int(Int32(bitPattern: a &- b)) }
    private mutating func bump(_ key: String) { metrics[key, default: 0] += 1 }
    mutating func reset() { self = ReceiveJitterBuffer(backlogLimitTicks: backlogLimitTicks, compressionEnabled: compressionEnabled, maximumSpeed: maximumSpeed) }
    private mutating func reanchor(_ packet: Packet, now: Double) {
        metrics["safetyDiscardPackets", default: 0] += packets.values.filter { $0.timestamp != packet.timestamp }.count
        metrics["safetyDiscardPCMBytes", default: 0] += pcm.count
        packets.removeAll(); pcm.removeAll(); segments.removeAll(); compressor.reset(); accelerating = false; cursor = nil; anchor = packet.timestamp
        readyAt = now + cushion; consumedUntil = packet.timestamp; missing = 0; knownGapCount = 0; lastFrame = Data(count: 960)
    }
    mutating func insert(data: Data, sequence: UInt16, timestamp: UInt32, now: Double) {
        guard let duration = Self.opusDuration(data) else { bump("invalidPackets"); return }
        let packet = Packet(sequence: sequence, timestamp: timestamp, duration: duration, data: data)
        let newerSequence = newestSequence.map { Int16(bitPattern: sequence &- $0) > 0 } ?? true
        if !newerSequence, let timeline = consumedUntil ?? cursor ?? anchor, delta(timestamp, timeline) > 24000 {
            bump("latePackets"); return
        }
        if cursor == nil, let consumedUntil, delta(timestamp, consumedUntil) < 0 {
            if newerSequence && abs(delta(timestamp, consumedUntil)) > 48000 {
                reanchor(packet, now: now); bump("timestampResets")
            } else { bump("latePackets"); return }
        }
        if cursor == nil, packets.isEmpty, pcm.isEmpty, let timeline = consumedUntil ?? anchor,
           newerSequence, now - lastArrival > 0.25, delta(timestamp, timeline) > 960 {
            reanchor(packet, now: now); bump("timestampResets")
        }
        if let cursor {
            let distance = delta(timestamp, cursor)
            // A new talkspurt after silence or a discontinuous source clock needs a new timeline.
            if newerSequence && ((now - lastArrival > 0.25 && distance > 960) || abs(distance) > 48000) {
                reanchor(packet, now: now); bump("timestampResets")
            } else if distance < 0 { bump("latePackets"); return }
        }
        if newerSequence {
            if let newestArrival, let newestTimestamp {
                let media = Double(delta(timestamp, newestTimestamp)) / 48000
                if media > 0 && media < 0.25 {
                    variation += (abs((now - newestArrival) - media) - variation) / 16
                    cushion = min(0.20, max(0.08, 0.08 + variation * 4))
                }
            }
            newestArrival = now; newestTimestamp = timestamp
            metrics["targetBufferMs"] = Int(cushion * 1000)
            metrics["arrivalVariationMs"] = Int(variation * 1000)
        }
        if anchor == nil { anchor = timestamp; readyAt = now + cushion }
        if cursor == nil, let anchor, delta(timestamp, anchor) < 0 { self.anchor = timestamp }
        if packets[timestamp] != nil { bump("duplicatePackets"); return }
        // Bound both packet count and media span; discard stale speech as one reset.
        if packets.count >= (backlogLimitTicks > 24000 ? 400 : 50) || (anchor.map { delta(timestamp, cursor ?? $0) + pcm.count > backlogLimitTicks } ?? false) {
            reanchor(packet, now: now); bump("rebufferCount")
        }
        packets[timestamp] = packet; lastArrival = now
        bump("packetDurationTicks_\(duration)")
        metrics["minimumPacketTicks"] = min(metrics["minimumPacketTicks"] ?? duration, duration)
        metrics["maximumPacketTicks"] = max(metrics["maximumPacketTicks"] ?? duration, duration)
        if newerSequence { newestSequence = sequence }
        let span = packets.values.reduce(0) { max($0, delta($1.timestamp, cursor ?? anchor ?? $1.timestamp) + $1.duration) }
        metrics["maximumBufferedMs"] = max(metrics["maximumBufferedMs", default: 0], span / 48)
    }
    mutating func render(now: Double, onDecoded: ((UInt32) -> Void)? = nil, onConsumed: ((UInt32, Int) -> Void)? = nil, decode: (Data) throws -> Data) throws -> Data {
        if let lastRender, now - lastRender > 0.20 {
            // Dispatch timers coalesce missed ticks. Do not replay their obsolete audio.
            if let newest = packets.values.max(by: { delta($0.timestamp, anchor ?? $0.timestamp) < delta($1.timestamp, anchor ?? $1.timestamp) }) {
                reanchor(newest, now: now); packets[newest.timestamp] = newest
            } else { metrics["safetyDiscardPCMBytes", default: 0] += pcm.count; cursor = nil; anchor = nil; pcm.removeAll(); segments.removeAll(); compressor.reset(); missing = 0; knownGapCount = 0 }
            bump("schedulerStalls"); bump("rebufferCount")
        }
        if let lastRender, now - lastRender > 0.08 && now - lastRender <= 0.20 { bump("schedulerStalls"); bump("preservedSchedulerStalls") }
        lastRender = now
        if cursor == nil {
            guard now >= readyAt, let first = earliestPacket() else { metrics["waitingPCMBytes", default: 0] += 960; return Data(count: 960) }
            cursor = first.timestamp; anchor = first.timestamp
        }
        let queuedBytes = pcm.count + packets.values.reduce(0) { $0 + $1.duration }
        let queuedSeconds = Double(queuedBytes) / 48000
        if queuedSeconds >= 0.40 { accelerating = true }
        if queuedSeconds <= 0.30 { accelerating = false }
        let requestedRate = compressionEnabled && accelerating ? 1 + min(maximumSpeed - 1, max(0, queuedSeconds - 0.30) * 0.15) : 1
        metrics["requestedSpeedPermille"] = Int(requestedRate * 1000)
        metrics["maximumRequestedSpeedPermille"] = max(metrics["maximumRequestedSpeedPermille", default: 1000], Int(requestedRate * 1000))
        metrics["maximumQueuedPCMEquivalentMs"] = max(metrics["maximumQueuedPCMEquivalentMs", default: 0], queuedBytes / 48)
        var maximumSkip = compressor.lookahead(rate: requestedRate)
        var neededBytes = 960 + maximumSkip * 2
        while pcm.count < neededBytes {
            guard let cursor else { break }
            if let packet = packets.removeValue(forKey: cursor) {
                let decoded = try decode(packet.data)
                onDecoded?(packet.timestamp)
                let expectedBytes = packet.duration
                var piece = Data(decoded.prefix(expectedBytes))
                if piece.count < expectedBytes {
                    let deficit = expectedBytes - piece.count
                    if !decodedOnce { piece = Data(count: deficit) + piece; bump("decoderPrimingFrames") }
                    else { piece.append(Data(count: deficit)); bump("decoderShortPackets") }
                }
                decodedOnce = true
                if recovering {
                    let fadeSamples = min(120, piece.count / 2)
                    piece.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                        for i in 0..<fadeSamples {
                            let value = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i*2, as: Int16.self))
                            bytes.storeBytes(of: Int16(Double(value) * Double(i) / 120).littleEndian, toByteOffset: i*2, as: Int16.self)
                        }
                    }
                    recovering = false
                }
                pcm.append(piece); segments.append(Segment(timestamp: packet.timestamp, bytes: expectedBytes))
                self.cursor = cursor &+ UInt32(packet.duration); consumedUntil = self.cursor; missing = 0; knownGapCount = 0
                bump("decodedPackets")
            } else {
                // Lookahead must never manufacture loss or use future packet data.
                if pcm.count >= 960 { maximumSkip = 0; neededBytes = 960; break }
                let nextDistance = packets.keys.map { delta($0, cursor) }.filter { $0 > 0 }.min()
                let step = min(960, nextDistance ?? 960)
                if nextDistance != nil {
                    knownGapCount += 1; metrics["knownGapPCMBytes", default: 0] += step
                    self.cursor = cursor &+ UInt32(step); consumedUntil = self.cursor
                } else {
                    knownGapCount = 0; metrics["starvationPCMBytes", default: 0] += step
                    if missing == 0 { bump("starvationEpisodes") }
                }
                missing += 1; bump("concealedFrames")
                pcm.append(conceal().prefix(step)); segments.append(Segment(timestamp: nil, bytes: step))
                recovering = true; metrics["concealedPCMBytes", default: 0] += step
                maximumSkip = 0; neededBytes = 960; compressor.reset()
                if missing == 3 && nextDistance == nil {
                    self.cursor = nil; anchor = cursor; readyAt = now + cushion; bump("rebufferCount")
                } else if knownGapCount >= 3 && nextDistance != nil {
                    self.cursor = nil; anchor = earliestPacket()?.timestamp; readyAt = now + cushion; bump("rebufferCount")
                }
            }
        }
        if pcm.count < 960 {
            let padding = 960 - pcm.count
            pcm.append(Data(count: padding)); segments.append(Segment(timestamp: nil, bytes: padding))
            metrics["waitingPCMBytes", default: 0] += padding
        }
        let compressed = compressor.process(pcm, maximumSkip: maximumSkip)
        var consumed = compressed.consumedBytes
        while consumed > 0, !segments.isEmpty {
            let count = min(consumed, segments[0].bytes)
            if let timestamp = segments[0].timestamp { onConsumed?(timestamp, count) }
            segments[0].bytes -= count; consumed -= count
            if segments[0].bytes == 0 { segments.removeFirst() }
        }
        pcm.removeFirst(compressed.consumedBytes)
        metrics["compressionRemovedSamples"] = compressor.removedSamples
        metrics["acceleratedFrames"] = compressor.acceleratedFrames
        metrics["correlationMisses"] = compressor.correlationMisses
        metrics["renderedFrames", default: 0] += 1
        metrics["consumedSourceSamples", default: 0] += compressed.consumedBytes / 2
        metrics["remainingDecodedPCMBytes"] = pcm.count
        lastFrame = compressed.output
        return compressed.output
    }
    private func earliestPacket() -> Packet? {
        guard let anchor else { return nil }
        return packets.values.min { delta($0.timestamp, anchor) < delta($1.timestamp, anchor) }
    }
    private func conceal() -> Data {
        var result = Data(count: 960)
        // Fade the previous 20 ms waveform toward zero; never sustain stale speech.
        let gain = max(0, 1 - Double(missing) / 3)
        result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            lastFrame.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for i in 0..<480 {
                    let value = Int16(littleEndian: src.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    let fade = gain * (1 - Double(i) / 480)
                    dst.storeBytes(of: Int16(Double(value) * fade).littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
        }
        return result
    }
    static func opusDuration(_ data: Data) -> Int? {
        guard let toc = data.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int
        if config >= 16 { frame = 120 << (config & 3) }
        else if config >= 12 { frame = 480 << (config & 1) }
        else { frame = [480, 960, 1920, 2880][config & 3] }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default: guard data.count >= 2 else { return nil }; count = Int(data[data.startIndex + 1] & 0x3f)
        }
        let total = frame * count
        return count > 0 && total <= 5760 ? total : nil
    }
}
