import AVFAudio
import CallKit

// The device with the microphone owns the system call and its audio activation.
// The paired iPhone must not register a second CallKit call for this conversation.
@MainActor final class DeviceCallSession: NSObject, @preconcurrency CXProviderDelegate {
    private let provider: CXProvider
    private let controller = CXCallController()
    private let id = UUID()
    private var activation: ReplyGate<Void>?
    private var ended = false
    var onRegistered: (() -> Void)?
    var onEnd: ((String?) -> Void)?
    var onMute: ((Bool) async throws -> Void)?
    var onProgress: ((String) -> Void)?
    #if targetEnvironment(simulator)
    private var simulated: Bool { ProcessInfo.processInfo.arguments.contains("--without-watch-callkit") }
    #endif

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }
    deinit { provider.invalidate() }
    func start(name: String) async throws {
        #if targetEnvironment(simulator)
        if simulated {
            onProgress?("Simulator: CallKit substituted")
            onRegistered?()
            if !ProcessInfo.processInfo.arguments.contains("--simulated-audio") {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
                try session.setActive(true)
                onProgress?("Simulator: real audio engine session activated")
            }
            return
        }
        #endif
        onProgress?("Registering system call")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ReplyGate(continuation)
            activation = gate
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.activation != nil else { return }
                self.activation = nil
                gate.finish(.failure(RelayFailure(message: "The system did not activate call audio.")))
            }
            let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
            controller.request(CXTransaction(action: action)) { error in
                if let error { gate.finish(.failure(error)) }
            }
        }
    }
    func connected() {
        #if targetEnvironment(simulator)
        if simulated { return }
        #endif
        provider.reportOutgoingCall(with: id, connectedAt: Date())
    }
    func end(failed: Bool) {
        guard !ended else { return }
        ended = true
        activation?.finish(.failure(CancellationError())); activation = nil
        #if targetEnvironment(simulator)
        if simulated {
            if !ProcessInfo.processInfo.arguments.contains("--simulated-audio") {
                try? AVAudioSession.sharedInstance().setActive(false)
            }
            provider.invalidate()
            return
        }
        #endif
        provider.reportCall(with: id, endedAt: Date(), reason: failed ? .failed : .remoteEnded)
        // CXProvider must be invalidated before release. This also clears any
        // outstanding system-call state if reporting the failure is still queued.
        provider.invalidate()
    }
    func requestMute(_ muted: Bool) async throws {
        #if targetEnvironment(simulator)
        if simulated { try await onMute?(muted); return }
        #endif
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func providerDidReset(_ provider: CXProvider) {
        activation?.finish(.failure(RelayFailure(message: "Call service reset."))); activation = nil
        if !ended { onEnd?("Call service reset.") }
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard !ended else { action.fail(); return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            #else
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
            #endif
            let update = CXCallUpdate()
            update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false
            update.supportsDTMF = false; update.hasVideo = false
            provider.reportCall(with: id, updated: update)
            action.fulfill()
            onRegistered?()
            provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
        } catch {
            action.fail()
            activation?.finish(.failure(error)); activation = nil
        }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard !ended else { return }
        onProgress?("System call audio activated")
        activation?.finish(.success(())); activation = nil
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        if !ended { onEnd?("System call audio deactivated.") }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        if !ended { onEnd?(nil) }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard !ended, let onMute else { action.fail(); return }
        Task {
            do { try await onMute(action.isMuted); action.fulfill() }
            catch { action.fail(); onEnd?("Mute could not be confirmed. The call has ended.") }
        }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if !ended { onEnd?("System call action timed out.") }
    }
}
