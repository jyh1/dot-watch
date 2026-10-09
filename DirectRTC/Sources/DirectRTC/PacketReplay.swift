import Foundation
import CDotNetEq

/// Offline rendering only: no audio device, signaling, or network connection is opened.
public enum PacketReplay {
    public struct Diagnostic: Codable {
        public let time: Double
        public let reason: String
        public let timestamp: UInt32?
        public let sequence: UInt16?
        public let bufferedPackets: Int
        public let concealedFrames: Int
        public let rebufferCount: Int
    }
    public struct Result {
        public let diagnostics: [Diagnostic]
        public let arrivalPCM: Data
        public let referencePCM: Data
        public let metrics: [String: Int]
        public let captureSummary: PacketCapture.Summary
        public var sampleRate: Int = 24000
    }
    private struct Packet { let order: Int; let processingTime: Double; let time: Double; let sequence: UInt16; let timestamp: UInt32; let payload: Data; let duration: Int }
    public static func replay(url: URL, compressionEnabled: Bool = false, backlogMilliseconds: Int = 500, maximumSpeed: Double = 1.10) throws -> Result {
        guard (500...1000).contains(backlogMilliseconds), maximumSpeed >= 1, maximumSpeed <= 1.10 else { throw DirectRTCError("Invalid offline playback control.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 10 * 1024 * 1024 else { throw DirectRTCError("Capture is not a bounded regular file.") }
        let source = try Data(contentsOf: url)
        guard source.last == 10 else { throw DirectRTCError("Capture is incomplete: missing final newline.") }
        let lines = source.split(separator: 10)
        guard lines.count >= 2, lines.count <= 60002 else { throw DirectRTCError("Capture event count is invalid.") }
        let decoder = JSONDecoder()
        let header = try decoder.decode(PacketCapture.Record.self, from: Data(lines[0]))
        let native = header.version == 2
        guard header.type == "header", header.rtpClock == 48000,
              (header.version == 1 && header.pcmRate == 24000) ||
              (native && header.pcmRate == 48000 && header.receiver == "neteq-libopus" && header.renderIntervalMilliseconds == 10) else { throw DirectRTCError("Unsupported capture schema or audio clocks.") }
        if native, compressionEnabled || backlogMilliseconds != 500 || maximumSpeed != 1.10 { throw DirectRTCError("Legacy compression options do not apply to NetEq captures.") }
        let footer = try decoder.decode(PacketCapture.Record.self, from: Data(lines[lines.count - 1]))
        guard footer.type == "footer", let summary = footer.summary else { throw DirectRTCError("Capture was not finalized.") }
        var packets: [Packet] = [], ticks: [(time: Double, order: Int)] = []
        for (order, line) in lines.dropFirst().dropLast().enumerated() {
            guard line.count <= 83000 else { throw DirectRTCError("Capture event is oversized.") }
            let event = try decoder.decode(PacketCapture.Record.self, from: Data(line))
            guard let elapsed = event.elapsedNanoseconds, elapsed <= 300_000_000_000 else { throw DirectRTCError("Capture event time is invalid.") }
            let time = Double(elapsed) / 1_000_000_000
            switch event.type {
            case "packet":
                guard let sequence = event.sequence, let timestamp = event.timestamp, let encoded = event.opus,
                      let payload = Data(base64Encoded: encoded), !payload.isEmpty, payload.count <= 61440,
                      let duration = ReceiveJitterBuffer.opusDuration(payload) else { throw DirectRTCError("Capture Opus packet is invalid.") }
                let processing = event.processingNanoseconds ?? elapsed
                guard processing >= elapsed, processing <= 300_000_000_000 else { throw DirectRTCError("Capture insertion time is invalid.") }
                packets.append(Packet(order: order, processingTime: Double(processing) / 1_000_000_000, time: time, sequence: sequence, timestamp: timestamp, payload: payload, duration: duration))
            case "render": ticks.append((time, order))
            default: throw DirectRTCError("Unknown capture event type.")
            }
        }
        guard packets.count == summary.recordedPackets, ticks.count == summary.recordedRenders, summary.droppedEvents >= 0,
              ticks.count <= (native ? 30002 : 15002), !packets.isEmpty else { throw DirectRTCError("Capture counts do not match, or no packets were recorded.") }
        packets.sort { $0.processingTime == $1.processingTime ? $0.order < $1.order : $0.processingTime < $1.processingTime }
        if native { return try replayNetEq(packets: packets, ticks: ticks, summary: summary) }
        let capturedRenderEnd = ticks.last?.time ?? packets.last!.processingTime
        if ticks.isEmpty {
            let end = min(300.5, packets.last!.processingTime + 0.5)
            ticks = stride(from: 0.0, through: end, by: 0.02).map { ($0, Int.max) }
        } else {
            ticks.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            // Finish draining at the nominal cadence, without inventing network packets.
            let end = min(300.5, max(packets.last!.processingTime, ticks.last!.time) + 0.5)
            var next = ticks.last!.time + 0.02
            while next <= end { ticks.append((next, Int.max)); next += 0.02 }
        }
        var jitter = ReceiveJitterBuffer(backlogLimitTicks: backlogMilliseconds * 48, compressionEnabled: compressionEnabled, maximumSpeed: maximumSpeed), arrivalPCM = Data(), index = 0
        var diagnostics: [Diagnostic] = []
        let opus = try OpusCodec()
        var previousTick: Double?
        var firstDecodedTime: Double?
        let packetByTimestamp = Dictionary(packets.map { ($0.timestamp, $0) }, uniquingKeysWith: { first, _ in first })
        var decodedAges: [Int] = []
        var consumedAges: [Int] = []
        var consumedByTimestamp: [UInt32: Int] = [:]
        var actualFullyConsumed = 0, actualSourcePCMBytes = 0
        var actualRemovedSamples = 0, actualSafetyDiscardPackets = 0, actualSafetyDiscardPCMBytes = 0
        var actualDecoded = 0, actualConceal = 0, actualRebuffers = 0, actualConcealedBytes = 0
        var actualWaitingBytes = 0, actualStarvationBytes = 0, actualStarvationEpisodes = 0, actualKnownGapBytes = 0
        var schedulerGapBytes = 0
        for tick in ticks {
            let time = tick.time
            if previousTick == nil { arrivalPCM.append(Data(count: Int((time * 24000).rounded()) * 2)) }
            if let previousTick, time - previousTick > 0.03 {
                let gap = max(0, Int(((time - previousTick) * 24000).rounded()) - 480) * 2
                arrivalPCM.append(Data(count: gap)); schedulerGapBytes += gap
            }
            previousTick = time
            while index < packets.count, packets[index].processingTime < time || (packets[index].processingTime == time && packets[index].order < tick.order) {
                let packet = packets[index]
                let previousLate = jitter.metrics["latePackets", default: 0]
                jitter.insert(data: packet.payload, sequence: packet.sequence, timestamp: packet.timestamp, now: packet.time)
                if jitter.metrics["latePackets", default: 0] > previousLate, diagnostics.count < 60000 {
                    diagnostics.append(Diagnostic(time: time, reason: "latePacket", timestamp: packet.timestamp, sequence: packet.sequence, bufferedPackets: jitter.diagnosticBufferedPackets, concealedFrames: jitter.metrics["concealedFrames", default: 0], rebufferCount: jitter.metrics["rebufferCount", default: 0]))
                }
                index += 1
            }
            let beforeConceal = jitter.metrics["concealedFrames", default: 0]
            let beforeRebuffer = jitter.metrics["rebufferCount", default: 0]
            let expectedTimestamp = jitter.diagnosticCursor
            let bufferedBefore = jitter.diagnosticBufferedPackets
            arrivalPCM.append(try jitter.render(now: time, onDecoded: { timestamp in
                if let packet = packetByTimestamp[timestamp], time <= capturedRenderEnd {
                    decodedAges.append(Int(max(0, time - packet.time) * 1_000_000_000)); actualDecoded += 1
                    if diagnostics.count < 60000 {
                        diagnostics.append(Diagnostic(time: time, reason: "decode", timestamp: timestamp, sequence: packet.sequence, bufferedPackets: 0, concealedFrames: 0, rebufferCount: 0))
                    }
                }
            }, onConsumed: { timestamp, bytes in
                if let packet = packetByTimestamp[timestamp], time <= capturedRenderEnd {
                    let previous = consumedByTimestamp[timestamp, default: 0]
                    consumedByTimestamp[timestamp] = previous + bytes; actualSourcePCMBytes += bytes
                    if previous < packet.duration && previous + bytes >= packet.duration {
                        actualFullyConsumed += 1
                        consumedAges.append(Int(max(0, time - packet.time) * 1_000_000_000))
                        if diagnostics.count < 60000 {
                            diagnostics.append(Diagnostic(time: time, reason: "consumed", timestamp: timestamp, sequence: packet.sequence, bufferedPackets: 0, concealedFrames: 0, rebufferCount: 0))
                        }
                    }
                }
            }) { try opus.decode($0) })
            if time <= capturedRenderEnd {
                actualConceal = jitter.metrics["concealedFrames", default: 0]
                actualRebuffers = jitter.metrics["rebufferCount", default: 0]
                actualConcealedBytes = jitter.metrics["concealedPCMBytes", default: 0]
                actualWaitingBytes = jitter.metrics["waitingPCMBytes", default: 0]
                actualStarvationBytes = jitter.metrics["starvationPCMBytes", default: 0]
                actualStarvationEpisodes = jitter.metrics["starvationEpisodes", default: 0]
                actualKnownGapBytes = jitter.metrics["knownGapPCMBytes", default: 0]
                actualRemovedSamples = jitter.metrics["compressionRemovedSamples", default: 0]
                actualSafetyDiscardPackets = jitter.metrics["safetyDiscardPackets", default: 0]
                actualSafetyDiscardPCMBytes = jitter.metrics["safetyDiscardPCMBytes", default: 0]
            }
            if (jitter.metrics["concealedFrames", default: 0] > beforeConceal || jitter.metrics["rebufferCount", default: 0] > beforeRebuffer), diagnostics.count < 60000 {
                diagnostics.append(Diagnostic(time: time, reason: jitter.metrics["rebufferCount", default: 0] > beforeRebuffer ? "rebuffer" : "conceal", timestamp: expectedTimestamp, sequence: nil, bufferedPackets: bufferedBefore, concealedFrames: jitter.metrics["concealedFrames", default: 0], rebufferCount: jitter.metrics["rebufferCount", default: 0]))
            }
            if firstDecodedTime == nil, jitter.metrics["decodedPackets", default: 0] > 0 { firstDecodedTime = time }
        }
        // Reference orders the received packets by RTP media time. Missing ranges remain silence.
        // It is an ordering reference, not an oracle that can recover packets never captured.
        let sequenceBase = packets[0].sequence
        let sequenceOrder = packets.sorted { Int(Int16(bitPattern: $0.sequence &- sequenceBase)) < Int(Int16(bitPattern: $1.sequence &- sequenceBase)) }
        for pair in zip(sequenceOrder, sequenceOrder.dropFirst()) where pair.0.sequence != pair.1.sequence {
            guard Int32(bitPattern: pair.1.timestamp &- pair.0.timestamp) > 0 else {
                throw DirectRTCError("Reference cannot combine an RTP source-clock reset; capture separate media segments.")
            }
        }
        let base = packets[0].timestamp
        func offset(_ packet: Packet) -> Int { Int(Int32(bitPattern: packet.timestamp &- base)) }
        let ordered = packets.sorted { offset($0) < offset($1) }
        let first = offset(ordered[0])
        let end = ordered.reduce(first) { max($0, offset($1) + $1.duration) }
        guard end >= first, end - first <= 300 * 48000 else { throw DirectRTCError("Reference RTP span exceeds five minutes; source clock reset requires a separate trace.") }
        var reference = Data(count: end - first), seen = Set<UInt32>(), occupied = 0, duplicates = 0
        let referenceDecoder = try OpusCodec()
        var priming = true
        for packet in ordered {
            guard seen.insert(packet.timestamp).inserted else { duplicates += 1; continue }
            let raw = try referenceDecoder.decode(packet.payload)
            var decoded = Data(raw.prefix(packet.duration))
            if decoded.count < packet.duration {
                let silence = Data(count: packet.duration - decoded.count)
                decoded = priming ? silence + decoded : decoded + silence
            }
            priming = false
            let begin = offset(packet) - first
            reference.replaceSubrange(begin..<(begin + packet.duration), with: decoded)
            occupied += packet.duration
        }
        let mediaBytes = reference.count
        let referenceLeadingBytes = Int(((firstDecodedTime ?? ordered[0].time + 0.1) * 24000).rounded()) * 2
        reference = Data(count: referenceLeadingBytes) + reference
        var metrics = jitter.metrics
        consumedAges.sort()
        metrics["actualFullyConsumedPackets"] = actualFullyConsumed
        metrics["actualConsumedSourcePCMBytes"] = actualSourcePCMBytes
        metrics["actualCompressionRemovedSamples"] = actualRemovedSamples
        metrics["actualSafetyDiscardPackets"] = actualSafetyDiscardPackets
        metrics["actualSafetyDiscardPCMBytes"] = actualSafetyDiscardPCMBytes
        metrics["actualUnconsumedCapturedSourcePCMBytes"] = packets.reduce(0) { $0 + $1.duration } - actualSourcePCMBytes
        for percentile in [50, 95, 100] where !consumedAges.isEmpty {
            metrics["arrivalConsumedP\(percentile)Nanoseconds"] = consumedAges[min(consumedAges.count - 1, consumedAges.count * percentile / 100)]
        }
        decodedAges.sort()
        metrics["actualDecodedPackets"] = actualDecoded
        metrics["actualConcealedFrames"] = actualConceal
        metrics["actualRebufferCount"] = actualRebuffers
        metrics["actualConcealedPCMBytes"] = actualConcealedBytes
        metrics["actualWaitingPCMBytes"] = actualWaitingBytes
        metrics["actualStarvationPCMBytes"] = actualStarvationBytes
        metrics["actualStarvationEpisodes"] = actualStarvationEpisodes
        metrics["actualKnownGapPCMBytes"] = actualKnownGapBytes
        for percentile in [50, 95, 100] where !decodedAges.isEmpty {
            metrics["arrivalDecodeP\(percentile)Nanoseconds"] = decodedAges[min(decodedAges.count - 1, decodedAges.count * percentile / 100)]
        }
        metrics["referenceMediaPCMBytes"] = mediaBytes
        metrics["referenceLeadingPCMBytes"] = referenceLeadingBytes
        metrics["captureWriteFailed"] = summary.writeError == nil ? 0 : 1
        metrics["arrivalFirstRenderNanoseconds"] = Int(ticks[0].time * 1_000_000_000)
        metrics["commonMediaAnchorNanoseconds"] = Int((firstDecodedTime ?? ordered[0].time + 0.1) * 1_000_000_000)
        metrics["schedulerGapPCMBytes"] = schedulerGapBytes
        metrics["captureDroppedEvents"] = summary.droppedEvents
        metrics["captureTruncated"] = summary.truncated ? 1 : 0
        metrics["referenceDuplicatePackets"] = duplicates
        metrics["referenceMissingPCMBytes"] = max(0, mediaBytes - occupied)
        metrics["arrivalPCMBytes"] = arrivalPCM.count
        metrics["referencePCMBytes"] = reference.count
        return Result(diagnostics: diagnostics, arrivalPCM: arrivalPCM, referencePCM: reference, metrics: metrics, captureSummary: summary)
    }
    private static func replayNetEq(packets: [Packet], ticks recordedTicks: [(time: Double, order: Int)], summary: PacketCapture.Summary) throws -> Result {
        var ticks = recordedTicks.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        let actualEnd = max(ticks.last?.time ?? 0, packets.last!.processingTime)
        let end = min(300.5, actualEnd + 0.5)
        if ticks.isEmpty { ticks = stride(from: 0.0, through: end, by: 0.01).map { ($0, Int.max) } }
        else {
            var next = ticks.last!.time + 0.01
            while next <= end { ticks.append((next, Int.max)); next += 0.01 }
        }
        let receiver = try NetEqReceiver()
        var arrival = Data(), previousTick: Double?, index = 0, schedulerGapBytes = 0
        var actualStatistics: [String: Int] = [:]
        for tick in ticks {
            if let previousTick, tick.time - previousTick > 0.015 {
                let gap = max(0, Int(((tick.time - previousTick) * 48000).rounded()) - 480) * 2
                arrival.append(Data(count: gap)); schedulerGapBytes += gap
            } else if previousTick == nil { arrival.append(Data(count: Int((tick.time * 48000).rounded()) * 2)) }
            previousTick = tick.time
            while index < packets.count, packets[index].processingTime < tick.time || (packets[index].processingTime == tick.time && packets[index].order < tick.order) {
                let packet = packets[index]
                try receiver.insert(packet.payload, sequence: packet.sequence, timestamp: packet.timestamp, arrival: packet.time, processing: packet.processingTime)
                index += 1
            }
            arrival.append(try receiver.render(now: tick.time))
            if tick.time <= actualEnd { actualStatistics = receiver.statistics }
        }

        let base = packets[0].timestamp
        func offset(_ packet: Packet) -> Int { Int(Int32(bitPattern: packet.timestamp &- base)) }
        let ordered = packets.sorted { offset($0) < offset($1) }
        let first = offset(ordered[0])
        let mediaEnd = ordered.reduce(first) { max($0, offset($1) + $1.duration) }
        guard mediaEnd >= first, mediaEnd - first <= 300 * 48000 else { throw DirectRTCError("Native reference RTP span exceeds five minutes; split source-clock resets.") }
        let sequenceBase = packets[0].sequence
        let sequenceOrder = packets.sorted { Int(Int16(bitPattern: $0.sequence &- sequenceBase)) < Int(Int16(bitPattern: $1.sequence &- sequenceBase)) }
        for pair in zip(sequenceOrder, sequenceOrder.dropFirst()) where pair.0.sequence != pair.1.sequence {
            guard Int32(bitPattern: pair.1.timestamp &- pair.0.timestamp) > 0 else { throw DirectRTCError("Native reference requires a single RTP source-clock timeline.") }
        }
        guard let decoder = dot_opus_decoder_create() else { throw DirectRTCError("Native reference decoder could not start.") }
        defer { dot_opus_decoder_destroy(decoder) }
        var reference = Data(count: (mediaEnd - first) * 2), seen = Set<UInt32>(), occupied = 0
        var scratch = [Int16](repeating: 0, count: 5760)
        for packet in ordered {
            guard seen.insert(packet.timestamp).inserted else { continue }
            let count = packet.payload.withUnsafeBytes { payload in
                scratch.withUnsafeMutableBufferPointer { samples in
                    dot_opus_decoder_decode(decoder, payload.bindMemory(to: UInt8.self).baseAddress!, packet.payload.count, samples.baseAddress!, samples.count)
                }
            }
            guard count == packet.duration else { throw DirectRTCError("Native reference decoder returned an unexpected packet duration.") }
            let bytes = scratch.withUnsafeBytes { Data($0.prefix(Int(count) * 2)) }
            let begin = (offset(packet) - first) * 2
            reference.replaceSubrange(begin..<(begin + bytes.count), with: bytes)
            occupied += bytes.count
        }
        // This anchors the source-order reference to packet availability, not
        // to an inferred audible sample or NetEq playout timestamp crossing.
        let leading = Int((ordered[0].processingTime * 48000).rounded()) * 2
        let mediaBytes = reference.count
        reference = Data(count: leading) + reference
        var metrics = receiver.statistics
        for (key, value) in actualStatistics { metrics["actual" + key.prefix(1).uppercased() + key.dropFirst()] = value }
        metrics["receiverNetEq"] = 1; metrics["captureVersion"] = 2; metrics["sampleRate"] = 48000
        metrics["renderIntervalMilliseconds"] = 10; metrics["arrivalPCMBytes"] = arrival.count
        metrics["referencePCMBytes"] = reference.count; metrics["referenceLeadingPCMBytes"] = leading
        metrics["referenceLeadingUsesPacketAvailability"] = 1; metrics["referenceMediaPCMBytes"] = mediaBytes
        metrics["referenceMissingPCMBytes"] = max(0, mediaBytes - occupied)
        metrics["schedulerGapPCMBytes"] = schedulerGapBytes
        metrics["captureDroppedEvents"] = summary.droppedEvents; metrics["captureTruncated"] = summary.truncated ? 1 : 0
        return Result(diagnostics: [], arrivalPCM: arrival, referencePCM: reference, metrics: metrics, captureSummary: summary, sampleRate: 48000)
    }

    public static func wav(_ pcm: Data, sampleRate: Int = 24000) -> Data {
        precondition([24000, 48000].contains(sampleRate))
        var result = Data()
        func text(_ string: String) { result.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); text("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
