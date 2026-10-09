import Foundation
import Darwin

/// Explicitly opted-in received-audio diagnostics. Never captures microphone PCM or signaling.
public final class PacketCapture: @unchecked Sendable {
    public enum MediaFormat: Sendable {
        case legacy24k, neteq48k
    }

    public struct Limits: Sendable {
        public let durationSeconds: Double
        public let fileBytes: Int
        public let queuedBytes: Int
        public init(durationSeconds: Double = 300, fileBytes: Int = 10 * 1024 * 1024, queuedBytes: Int = 256 * 1024) {
            self.durationSeconds = durationSeconds; self.fileBytes = fileBytes; self.queuedBytes = queuedBytes
        }
        public static let `default` = Limits()
    }
    public struct Summary: Codable, Sendable {
        public let recordedPackets: Int
        public let recordedRenders: Int
        public let droppedEvents: Int
        public let truncated: Bool
        public let writeError: String?
        public let fileBytes: Int
    }
    struct Record: Codable, Sendable {
        var type: String
        var version: Int? = nil
        var rtpClock: Int? = nil
        var pcmRate: Int? = nil
        var receiver: String? = nil
        var renderIntervalMilliseconds: Int? = nil
        var appBuild: String? = nil
        var platform: String? = nil
        var elapsedNanoseconds: UInt64? = nil
        var processingNanoseconds: UInt64? = nil
        var sequence: UInt16? = nil
        var timestamp: UInt32? = nil
        var opus: String? = nil
        var summary: Summary? = nil
    }
    public let mediaFormat: MediaFormat
    public let url: URL
    private let limits: Limits
    private var started: Double?
    private let writer: DispatchQueue
    private let lock = NSLock()
    private let handle: FileHandle
    private var queuedBytes = 0, dropped = 0
    private var closed = false, truncated = false
    // Writer-queue owned state.
    private var bytes = 0, packets = 0, renders = 0
    private var errorText: String?
    private var finalSummary: Summary?

    public convenience init(url: URL, limits: Limits = .default, mediaFormat: MediaFormat = .legacy24k) throws {
        try self.init(url: url, limits: limits, mediaFormat: mediaFormat, writer: DispatchQueue(label: "Dot.packet-capture", qos: .utility))
    }
    init(url: URL, limits: Limits, mediaFormat: MediaFormat = .legacy24k, writer: DispatchQueue, started: Double? = nil) throws {
        guard limits.durationSeconds.isFinite, limits.durationSeconds > 0, limits.durationSeconds <= 300,
              limits.fileBytes >= 1024, limits.fileBytes <= 10 * 1024 * 1024,
              limits.queuedBytes > 0, limits.queuedBytes <= 1024 * 1024 else { throw DirectRTCError("Invalid packet capture limits.") }
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { throw DirectRTCError("Packet capture requires a new local file.") }
        let parent = url.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { throw DirectRTCError("Packet capture folder does not exist.") }
        // Exclusive creation prevents replacing an existing capture.
        let descriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw DirectRTCError("Could not create packet capture file.") }
        self.mediaFormat = mediaFormat; self.url = url; self.limits = limits; self.writer = writer; self.started = started
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                #if os(iOS)
        let platform = "iOS"
        #elseif os(watchOS)
        let platform = "watchOS"
        #else
        let platform = "macOS"
        #endif
        let candidate = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let build = candidate.flatMap { value in
            value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? value : nil
        }
        let native = mediaFormat == .neteq48k
        let header = try Self.line(Record(type: "header", version: native ? 2 : 1, rtpClock: 48000, pcmRate: native ? 48000 : 24000, receiver: native ? "neteq-libopus" : nil, renderIntervalMilliseconds: native ? 10 : nil, appBuild: build, platform: platform))
        do {
            #if os(iOS) || os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            var protectedURL = url
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            try protectedURL.setResourceValues(resource)
            try handle.write(contentsOf: header); bytes = header.count
        }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    func beginMediaTimeline(uptime: Double) {
        lock.lock(); if started == nil { started = uptime }; lock.unlock()
    }
    public func record(payload: Data, sequence: UInt16, timestamp: UInt32, arrivalUptime: Double, processingUptime: Double? = nil) {
        guard !payload.isEmpty, payload.count <= 61440 else { reject(); return }
        enqueue(cost: payload.count * 2 + 256, uptime: arrivalUptime, processingUptime: processingUptime) { elapsed, processing in
            Record(type: "packet", elapsedNanoseconds: elapsed, processingNanoseconds: processing, sequence: sequence, timestamp: timestamp, opus: payload.base64EncodedString())
        }
    }
    public func recordRender(uptime: Double) {
        enqueue(cost: 128, uptime: uptime) { elapsed, _ in Record(type: "render", elapsedNanoseconds: elapsed) }
    }
    private func reject() { lock.lock(); if !closed { dropped += 1 }; lock.unlock() }
    private func enqueue(cost: Int, uptime: Double, processingUptime: Double? = nil, record: @escaping @Sendable (UInt64, UInt64?) -> Record) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard uptime.isFinite else { dropped += 1; return }
        if started == nil { started = uptime }
        let elapsed = uptime - started!
        guard elapsed.isFinite, elapsed >= 0 else { dropped += 1; return }
        guard elapsed <= limits.durationSeconds else { truncated = true; dropped += 1; return }
        guard !truncated else { dropped += 1; return }
        guard cost <= limits.queuedBytes - queuedBytes else { dropped += 1; return }
        let processing: UInt64?
        if let processingUptime {
            let value = processingUptime - started!
            guard value.isFinite, value >= elapsed, value <= limits.durationSeconds else { dropped += 1; return }
            processing = UInt64(value * 1_000_000_000)
        } else { processing = nil }
        queuedBytes += cost
        let nanoseconds = UInt64(elapsed * 1_000_000_000)
        writer.async { [self] in
            defer { lock.lock(); queuedBytes -= cost; lock.unlock() }
            guard errorText == nil else { lock.lock(); dropped += 1; lock.unlock(); return }
            do {
                let value = record(nanoseconds, processing)
                let line = try Self.line(value)
                guard bytes + line.count <= limits.fileBytes - 768 else {
                    lock.lock(); truncated = true; dropped += 1; lock.unlock(); return
                }
                try handle.write(contentsOf: line); bytes += line.count
                if value.type == "packet" { packets += 1 } else { renders += 1 }
            } catch { errorText = "Packet capture write failed."; lock.lock(); dropped += 1; lock.unlock() }
        }
    }
    public func finish() async -> Summary {
        await withCheckedContinuation { continuation in
            lock.lock(); closed = true
            writer.async { [self] in
                if let finalSummary { continuation.resume(returning: finalSummary); return }
                lock.lock(); let losses = dropped, capped = truncated; lock.unlock()
                var summary = Summary(recordedPackets: packets, recordedRenders: renders, droppedEvents: losses, truncated: capped, writeError: errorText, fileBytes: bytes)
                do {
                    var footer = try Self.line(Record(type: "footer", summary: summary))
                    for _ in 0..<4 {
                        summary = Summary(recordedPackets: packets, recordedRenders: renders, droppedEvents: losses, truncated: capped, writeError: errorText, fileBytes: bytes + footer.count)
                        footer = try Self.line(Record(type: "footer", summary: summary))
                    }
                    try handle.write(contentsOf: footer); bytes += footer.count
                    try handle.synchronize(); try handle.close()
                } catch { errorText = "Packet capture finalization failed."; try? handle.close() }
                summary = Summary(recordedPackets: packets, recordedRenders: renders, droppedEvents: losses, truncated: capped, writeError: errorText, fileBytes: bytes)
                finalSummary = summary; continuation.resume(returning: summary)
            }
            lock.unlock()
        }
    }
    private static func line(_ value: Record) throws -> Data { var data = try JSONEncoder().encode(value); data.append(10); return data }
}
