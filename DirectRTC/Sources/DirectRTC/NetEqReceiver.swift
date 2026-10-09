import Foundation
import CDotNetEq

/// Genuine upstream NetEq/libopus, mono PCM16 at 48 kHz, one 10 ms pull.
/// The lock serializes native decoder and timeline state, including teardown.
public final class NetEqReceiver: @unchecked Sendable {
    public static let sampleRate = 48000
    public static let frameSamples = 480
    public static let frameBytes = 960
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var scratch = [Int16](repeating: 0, count: frameSamples)

    public init(now: Double = 0, minimumDelayMilliseconds: Int = 80, maximumDelayMilliseconds: Int = 500) throws {
        guard minimumDelayMilliseconds >= 0, maximumDelayMilliseconds >= minimumDelayMilliseconds,
              maximumDelayMilliseconds <= 2000 else { throw DirectRTCError("Invalid NetEq delay limits.") }
        handle = dot_neteq_create(try Self.microseconds(now), Int32(minimumDelayMilliseconds), Int32(maximumDelayMilliseconds))
        guard handle != nil else { throw DirectRTCError("NetEq audio receiver could not start.") }
    }
    deinit { if let handle { dot_neteq_destroy(handle) } }

    public func insert(_ payload: Data, sequence: UInt16, timestamp: UInt32, arrival: Double, processing: Double) throws {
        let arrivalUS = try Self.microseconds(arrival), processingUS = try Self.microseconds(processing)
        guard !payload.isEmpty, payload.count <= 61440, processingUS >= arrivalUS else { throw DirectRTCError("Invalid NetEq packet or timing.") }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw DirectRTCError("NetEq receiver is closed.") }
        let status = payload.withUnsafeBytes { bytes in
            dot_neteq_insert(handle, bytes.bindMemory(to: UInt8.self).baseAddress!, payload.count, sequence, timestamp, arrivalUS, processingUS)
        }
        guard status == 0 else { throw DirectRTCError("NetEq could not insert call audio.") }
    }

    public func render(now: Double) throws -> Data {
        let time = try Self.microseconds(now)
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw DirectRTCError("NetEq receiver is closed.") }
        var info = DotNetEqFrameInfo()
        let status = scratch.withUnsafeMutableBufferPointer { dot_neteq_get_audio(handle, time, $0.baseAddress!, &info) }
        guard status == 0, info.sample_rate_hz == Self.sampleRate, info.channels == 1,
              info.samples_per_channel == Self.frameSamples else { throw DirectRTCError("NetEq could not render the required call audio format.") }
        return scratch.withUnsafeBytes { Data($0) }
    }

    public var statistics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return [:] }
        var stats = DotNetEqStats()
        guard dot_neteq_get_stats(handle, &stats) == 0 else { return [:] }
        return [
            "neteqReceivedPackets": Int(clamping: stats.packets_received),
            "neteqDiscardedPackets": Int(clamping: stats.packets_discarded),
            "concealedSamples": Int(clamping: stats.concealed_samples),
            "silentConcealedSamples": Int(clamping: stats.silent_concealed_samples),
            "concealmentEvents": Int(clamping: stats.concealment_events),
            "acceleratedSamples": Int(clamping: stats.accelerated_samples),
            "preemptiveSamples": Int(clamping: stats.preemptive_samples),
            "fecPacketsReceived": Int(clamping: stats.fec_packets_received),
            "currentBufferMs": Int(clamping: stats.current_buffer_ms),
            "preferredBufferMs": Int(clamping: stats.preferred_buffer_ms),
            "packetBufferFlushes": Int(clamping: stats.packet_buffer_flushes),
            "jitterBufferDelayMs": Int(clamping: stats.jitter_buffer_delay_ms),
            "jitterBufferEmittedCount": Int(clamping: stats.jitter_buffer_emitted_count),
            "interruptionCount": Int(clamping: stats.interruption_count),
            "interruptionDurationMs": Int(clamping: stats.interruption_duration_ms),
            "outputSampleRate": Self.sampleRate,
            "outputFrameSamples": Self.frameSamples
        ]
    }

    public func reset(now: Double) throws {
        let time = try Self.microseconds(now)
        lock.lock(); defer { lock.unlock() }
        guard let handle, dot_neteq_reset(handle, time) == 0 else { throw DirectRTCError("NetEq receiver reset failed.") }
    }

    private static func microseconds(_ time: Double) throws -> Int64 {
        guard time.isFinite, time >= 0, time < Double(Int64.max) / 1_000_000 else { throw DirectRTCError("Invalid NetEq monotonic time.") }
        return Int64((time * 1_000_000).rounded(.down))
    }
}
