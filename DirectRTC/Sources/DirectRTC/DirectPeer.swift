import Foundation
import Network
import WatchRTC

public struct DirectRTCError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Network.framework owns every datagram. No BSD sockets are used on watchOS.
private final class DatagramPath: @unchecked Sendable {
    let connection: NWConnection
    let remoteAddress: Data
    let queue = DispatchQueue(label: "Dot.rtc.datagrams", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    private var storedPeer: WebRTCConnection?
    var peer: WebRTCConnection? {
        get { lock.lock(); defer { lock.unlock() }; return storedPeer }
        set { lock.lock(); storedPeer = newValue; lock.unlock() }
    }
    init(candidate: WebRTCICECandidate) {
        var address = IPv4Address(candidate.address)?.rawValue ?? IPv6Address(candidate.address)?.rawValue ?? Data()
        address.append(contentsOf: [UInt8(candidate.port >> 8), UInt8(candidate.port & 255)])
        remoteAddress = address
        connection = NWConnection(host: NWEndpoint.Host(candidate.address), port: NWEndpoint.Port(rawValue: candidate.port)!, using: .udp)
    }
    func start() { connection.start(queue: queue); receive() }
    func send(_ data: consuming [UInt8]) -> Result<Void, WebRTCDatagramSendFailure> {
        lock.lock()
        guard !closed else { lock.unlock(); return .failure(.closed) }
        guard pending < 64 else { lock.unlock(); return .failure(.backpressured) }
        pending += 1; lock.unlock()
        connection.send(content: Data(data), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
            if error != nil { self.peer?.transportDidFail(.destinationUnreachable) }
        })
        return .success(())
    }
    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { do { try self.peer?.receive(data, remoteAddress: self.remoteAddress) } catch { /* terminalFailure is observed by owner */ } }
            if error != nil { self.peer?.transportDidFail(.destinationUnreachable); return }
            self.lock.lock(); let shouldContinue = !self.closed; self.lock.unlock()
            if shouldContinue { self.receive() }
        }
    }
    func close() {
        lock.lock(); closed = true; lock.unlock()
        connection.cancel(); peer = nil
    }
}

public final class DirectPeer: @unchecked Sendable {
    private let stateLock = NSRecursiveLock()
    private let handlerLock = NSLock()
    private var closed = false
    private var consentTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private let endpoint: WebRTCEndpoint
    private let credentials = ICECredentials()
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private var sentPackets: UInt32 = 0, sentOctets: UInt32 = 0
    private var path: DatagramPath?
    private var peer: WebRTCConnection?
    private var opusHandler: (@Sendable (Data, UInt16, UInt32) -> Void)?
    public var onOpus: (@Sendable (Data, UInt16, UInt32) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return opusHandler }
        set { handlerLock.lock(); opusHandler = newValue; handlerLock.unlock() }
    }
    public init() throws { endpoint = try WebRTCEndpoint.create() }
    public var mediaReady: Bool { stateLock.withLock { peer?.isMediaReady == true } }
    public var state: String { stateLock.withLock { peer?.state.label ?? "new" } }
    public var failure: String? { stateLock.withLock { peer?.terminalFailure.map { String(describing: $0) } } }
    public var offer: String {
        let security = ["a=ice-ufrag:\(credentials.localUfrag)", "a=ice-pwd:\(credentials.localPassword)", "a=fingerprint:\(endpoint.localFingerprint.sdpFormat)", "a=setup:actpass"]
        let lines = ["v=0", "o=- \(UInt64.random(in: 1...UInt64.max)) 0 IN IP4 0.0.0.0", "s=-", "t=0 0", "a=group:BUNDLE 0 1", "a=msid-semantic: WMS dotwatch", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0"] + security + ["a=sendrecv", "a=rtcp-mux", "a=rtcp-rsize", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1;stereo=0;sprop-stereo=0", "a=msid:dotwatch watch", "a=ssrc:\(ssrc) cname:dotwatch", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0", "a=mid:1"] + security + ["a=sctp-port:5000", "a=max-message-size:16384"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
    public func connect(answer: String) async throws {
        guard answer.utf8.count <= 65536 else { throw DirectRTCError("Audio answer exceeds its size limit.") }
        let lines = answer.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(decoding: $0, as: UTF8.self) }
        guard lines.contains("a=rtpmap:111 opus/48000/2"),
              lines.contains(where: { $0.hasPrefix("m=audio ") && !$0.hasPrefix("m=audio 0 ") }),
              lines.contains("a=group:BUNDLE 0 1") else { throw DirectRTCError("The server did not negotiate bundled Opus audio.") }
        for prefix in ["a=ice-ufrag:", "a=ice-pwd:", "a=fingerprint:sha-256 ", "a=setup:"] {
            guard Set(lines.filter { $0.hasPrefix(prefix) }).count == 1 else { throw DirectRTCError("Inconsistent security settings in the audio answer.") }
        }
        // RFC 8122 allows multiple hashes; this transport authenticates SHA-256.
        let supported = lines.filter { !$0.hasPrefix("a=fingerprint:") || $0.hasPrefix("a=fingerprint:sha-256 ") }.joined(separator: "\r\n")
        let description = try WebRTCSessionDescription.parse(supported, type: .answer)
        // BUNDLE answers usually put candidates on the first (audio) section.
        let candidates = try answer.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("a=candidate:") }.map(WebRTCICECandidate.parse)
        guard let candidate = candidates.filter({ $0.component == 1 && $0.transport == .udp }).sorted(by: { if $0.address.contains(":") != $1.address.contains(":") { return !$0.address.contains(":") }; return $0.priority > $1.priority }).first else { throw DirectRTCError("The call server did not provide a UDP audio route.") }
        let ice = WebRTCICEConfiguration.controlling(credentials: ICECredentials(localUfrag: credentials.localUfrag, localPassword: credentials.localPassword, remoteUfrag: description.iceCredentials.localUfrag, remotePassword: description.iceCredentials.localPassword))
        let path = DatagramPath(candidate: candidate)
        let media = try WebRTCMediaConfiguration(rtpPayloadTypes: [111], allowsReducedSizeRTCP: true)
        let sender: WebRTCConnection.SendHandler = { [weak path] bytes in
            guard let path else { return .failure(.closed) }
            return path.send(consume bytes)
        }
        let peer: WebRTCConnection
        if description.setupRole == .active {
            peer = try WebRTCConnection.asServer(certificate: endpoint.certificate, remoteFingerprint: description.fingerprint, iceConfiguration: ice, mediaConfiguration: media, sendHandler: sender)
        } else {
            peer = try endpoint.connect(remoteFingerprint: description.fingerprint, iceConfiguration: ice, mediaConfiguration: media, sendHandler: sender)
        }
        try stateLock.withLock {
            guard !closed else { peer.close(); path.close(); throw CancellationError() }
            self.peer = peer; self.path = path; path.peer = peer
        }
        peer.setRTPHandler { [weak self] packet in
            self?.onOpus?(Data(packet.payload), packet.layout.fixedHeader.sequenceNumber, packet.layout.fixedHeader.timestamp)
        }
        let events = try peer.claimDataChannelEvents()
        stateLock.withLock {
            eventTask = Task {
                defer { events.discardRemainingEvents() }
                do { while !Task.isCancelled, try await events.next() != nil {} } catch {}
            }
        }
        path.start()
        try await peer.establishICEConnectivity()
        if description.setupRole == .passive { try peer.start() }
        for _ in 0..<400 {
            try Task.checkCancellation()
            if stateLock.withLock({ closed }) { throw CancellationError() }
            if let failure = peer.terminalFailure { throw failure }
            if peer.isMediaReady, description.setupRole == .active { try peer.startDataChannelAssociation() }
            if peer.state == .connected {
                _ = try peer.openDataChannel(label: "oai-events")
                stateLock.withLock {
                    consentTask = Task { [weak peer] in
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for: .seconds(5))
                                guard let peer else { return }
                                try await peer.refreshConsent(timeout: .seconds(5))
                            } catch { return }
                        }
                    }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DirectRTCError("Encrypted audio connection timed out (\(peer.state.label)).")
    }
    // Caller serializes sends, one Opus packet every 20 ms (48 kHz RTP clock).
    public func sendOpus(_ opus: Data) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let peer, peer.isMediaReady else { throw DirectRTCError("Audio transport is not ready.") }
        var bytes: [UInt8] = [0x80, 111, UInt8(sequence >> 8), UInt8(sequence & 255)]
        for value in [timestamp, ssrc] { bytes += [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        bytes.append(contentsOf: opus)
        sequence &+= 1; timestamp &+= 960
        try peer.sendRTP(bytes)
        sentPackets &+= 1; sentOctets &+= UInt32(opus.count)
    }
    public func sendReport() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let peer, peer.isMediaReady else { return }
        let now = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(UInt64(now) & 0xffffffff)
        let fraction = UInt32((now - floor(now)) * 4_294_967_296)
        var report: [UInt8] = [0x80, 200, 0, 6]
        for value in [ssrc, seconds, fraction, timestamp, sentPackets, sentOctets] {
            report += [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        report += Self.sourceDescription(ssrc: ssrc)
        try peer.sendRTCP(report)
    }
    // SDES length includes the header, CNAME item, terminator and word padding.
    static func sourceDescription(ssrc: UInt32) -> [UInt8] {
        let cname = Array("dotwatch".utf8)
        var packet: [UInt8] = [0x81, 202, 0, 0, UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 255), UInt8((ssrc >> 8) & 255), UInt8(ssrc & 255), 1, UInt8(cname.count)]
        packet += cname + [0]
        while packet.count % 4 != 0 { packet.append(0) }
        let words = packet.count / 4 - 1
        packet[2] = UInt8(words >> 8); packet[3] = UInt8(words & 255)
        return packet
    }
    public func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        closed = true; consentTask?.cancel(); consentTask = nil; eventTask?.cancel(); eventTask = nil
        peer?.close(); path?.close(); peer = nil; path = nil; endpoint.close()
    }
}
