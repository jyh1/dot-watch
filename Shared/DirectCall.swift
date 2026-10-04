import Foundation
import DirectRTC

@MainActor final class DirectCall {
    let account: DotAccount
    private let http: DotTransport
    private var peer: DirectPeer?
    private(set) var pipeline: DirectAudioPipeline?
    private var cloudID: String?
    private var startupFinished = false
    private var startupBegan = false
    private var stopped = false
    private var cleanupStarted = false
    private var journalKey: String { "DotWatch.direct.pending.\(account.dotID)" }
    var progress: (String) -> Void = { _ in }
    init(account: DotAccount, http: DotTransport? = nil) { self.account = account; self.http = http ?? DotHTTP(account) }
    func start() async throws {
        startupBegan = true
        defer { startupFinished = true }
        if let previous = UserDefaults.standard.string(forKey: journalKey) {
            progress("Finishing previous call…")
            _ = try await http.request(action: "stop", callID: previous)
            UserDefaults.standard.removeObject(forKey: journalKey)
        }
        guard !stopped else { return }
        progress("Preparing secure audio…")
        let peer = try DirectPeer(); self.peer = peer
        // Fail early if this device cannot encode/decode Opus, before allocating a cloud call.
        let pipeline = try DirectAudioPipeline(peer: peer); self.pipeline = pipeline
        progress("Connecting to Dot…")
        let (data, response) = try await http.request(action: "create", sdp: peer.offer)
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let id = location.split(separator: "?").first?.split(separator: "/").last.map(String.init),
              id.range(of: "^rtc_[a-zA-Z0-9_-]{1,150}$", options: .regularExpression) != nil else { throw RelayFailure(message: "The server did not return a call identifier.") }
        cloudID = id; UserDefaults.standard.set(id, forKey: journalKey)
        guard !stopped else { return }
        guard let answer = String(data: data, encoding: .utf8) else { throw RelayFailure(message: "The server returned invalid audio settings.") }
        // The media handshake and attach are independent after create, as in the browser.
        async let connection: Void = peer.connect(answer: answer)
        progress("Starting agent…")
        _ = try await http.request(action: "attach", callID: id)
        guard !stopped else { return }
        progress("Connecting audio…")
        try await connection
        guard !stopped else { return }
        pipeline.start()
        CallTrace.record("Direct WebRTC connected; no iPhone relay")
    }
    func finish() async {
        stopped = true
        pipeline?.stop(); peer?.close()
        // Do not cancel an allocating request: learn its ID, then stop after attach settles.
        while startupBegan && !startupFinished { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard !cleanupStarted else { return }; cleanupStarted = true
        guard let cloudID else { return }
        do {
            _ = try await http.request(action: "stop", callID: cloudID)
            UserDefaults.standard.removeObject(forKey: journalKey)
            CallTrace.record("Direct cloud call ended")
        } catch { CallTrace.record("Call cleanup pending: \(error.localizedDescription)") }
    }
}
