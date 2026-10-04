import SwiftUI
#if os(watchOS)
import WatchKit
#endif
import DirectRTC

@MainActor final class CallModel: ObservableObject {
    static let shared = CallModel()
    #if os(watchOS)
    private let deviceName = "Watch"
    #else
    private let deviceName = "iPhone"
    #endif
    private let widgetLaunch = ForegroundCallLauncher()
    private var siriWaiters: [ReplyGate<Void>] = []
    private var registrationResult: Result<Void, Error>?
    @Published var phase = "idle"
    @Published var name = AppBrand.name
    @Published var stage = "Preparing audio…"
    @Published var startedAt = Date()
    @Published var error = UserDefaults.standard.string(forKey: "DotWatch.lastWatchError")
    @Published var muted = false
    @Published var changingMute = false
    @Published var finishing = false
    let link = PhoneLink()
    private var audio: CallAudio?
    private var systemCall: DeviceCallSession?
    private var direct: DirectCall?
    private var lastStatistics: [String: Int] = [:]
    private var generation = 0
    private var sendTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    func startFromWidget() {
        guard phase == "idle", !finishing else { return }
        link.reportWatchEvent("Widget call requested; app active \(ForegroundCallLauncher.appIsActive())")
        widgetLaunch.request(start: { [weak self] in
            guard let self else { return }
            self.link.reportWatchEvent("Widget call starting after app activation")
            self.start()
        }, onTimeout: { [weak self] in
            self?.error = "Open \(AppBrand.name) and tap Call. The app could not become active."
            self?.link.reportWatchEvent("Widget launch expired before app activation")
        })
    }
    func start() {
        widgetLaunch.cancel()
        guard phase == "idle", !finishing else { return }
        guard let account = AccountVault.load() ?? DirectProbe.account else { error = "Open \(AppBrand.name) on iPhone once to sync sign-in."; return }
        generation += 1; let attempt = generation
        registrationResult = nil
        phase = "connecting"; error = nil; muted = false; startedAt = Date(); stage = "Preparing audio…"
        name = account.name
        UserDefaults.standard.removeObject(forKey: "DotWatch.lastWatchError")
        link.reportWatchEvent("Direct \(deviceName) call requested")
        let audio = CallAudio(), systemCall = DeviceCallSession(), direct = DirectCall(account: account, http: DirectProbe.transport(account))
        self.audio = audio; self.systemCall = systemCall; self.direct = direct
        systemCall.onRegistered = { [weak self] in self?.completeRegistration(.success(())) }
        systemCall.onProgress = { [weak self] message in self?.link.reportWatchEvent(message) }
        systemCall.onEnd = { [weak self] message in self?.end(message: message) }
        systemCall.onMute = { [weak self] value in
            guard let self, self.phase == "active" else { throw RelayFailure(message: "Call is not active.") }
            self.muted = value; audio.setMuted(value); direct.pipeline?.mute(value); self.changingMute = false
        }
        audio.onProgress = { [weak self] message in self?.link.reportWatchEvent(message) }
        audio.onFailure = { [weak self] message in self?.end(message: message) }
        audio.onInterrupted = { [weak self] in Task { @MainActor in self?.end(message: "Call audio was interrupted.") } }
        direct.progress = { [weak self] message in
            guard attempt == self?.generation else { return }
            self?.stage = message; self?.link.reportWatchEvent(message)
        }
        startTask = Task {
            do {
                try await audio.requestPermission()
                guard attempt == generation else { return }
                try await systemCall.start(name: account.name)
                guard attempt == generation else { return }
                try audio.start()
                try await direct.start()
                guard attempt == generation else { return }
                _ = audio.takeInput()
                phase = "active"; startedAt = Date(); systemCall.connected(); audio.connected()
                #if os(watchOS)
                WKInterfaceDevice.current().play(.start)
                #endif
                sendTask = Task {
                    while !Task.isCancelled, attempt == generation {
                        guard let pipeline = direct.pipeline else { break }
                        pipeline.push(audio.takeInput()); audio.play(pipeline.takeOutput())
                        if let failure = pipeline.failure {
                            link.reportWatchEvent("Media connection failed: \(failure)")
                            end(message: "The call connection was lost. Check your internet connection and call again.")
                            return
                        }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
            } catch { if attempt == generation { end(message: error.localizedDescription) } }
        }
    }
    // Return Siri's control of audio after CallKit accepts the call, before waiting
    // for didActivate. Waiting for activation inside perform() can deadlock Siri.
    func startFromSiri() async throws {
        guard !finishing else { throw RelayFailure(message: "The previous call is still ending. Try again shortly.") }
        if phase == "idle" { start() }
        guard phase != "idle" else { throw RelayFailure(message: error ?? "Open \(AppBrand.name) to finish setup.") }
        if let registrationResult { return try registrationResult.get() }
        try await withCheckedThrowingContinuation { siriWaiters.append(ReplyGate($0)) }
    }
    private func completeRegistration(_ result: Result<Void, Error>) {
        guard registrationResult == nil else { return }
        registrationResult = result
        let waiters = siriWaiters; siriWaiters.removeAll()
        waiters.forEach { $0.finish(result) }
    }
    func runSilentProbe() async {
        guard DirectProbe.enabled, phase == "idle", !finishing else { return }
        link.ready = true; link.dotName = AppBrand.name
        if ProcessInfo.processInfo.arguments.contains("--widget-probe") {
            #if targetEnvironment(simulator)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DirectProbe")
            try? Data().write(to: directory.appendingPathComponent("ready-for-widget"))
            for _ in 0..<1800 {
                if phase != "idle" { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            #endif
        } else if ProcessInfo.processInfo.arguments.contains("--siri-probe") {
            do { _ = try await CallDotIntent().perform() }
            catch { self.error = error.localizedDescription }
        } else { start() }
        for _ in 0..<600 { if phase != "connecting" { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        if phase == "active" {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            toggleMute()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            toggleMute()
            let extra = DirectProbe.duration - 10
            for _ in 0..<max(0, extra * 10) {
                if phase != "active" { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let stats = direct?.pipeline?.statistics ?? lastStatistics
        let connected = phase == "active"
        end()
        while finishing { try? await Task.sleep(nanoseconds: 100_000_000) }
        DirectProbe.save(stats, connected: connected, error: error)
    }
    func toggleMute() {
        guard phase == "active", !changingMute, let systemCall else { return }
        changingMute = true
        let requested = !muted
        if requested { muted = true; audio?.setMuted(true); direct?.pipeline?.mute(true) }
        let attempt = generation
        Task {
            do { try await systemCall.requestMute(requested) }
            catch { if attempt == generation { changingMute = false; end(message: "Mute could not be confirmed.") } }
        }
    }
    func end(message: String? = nil) {
        guard phase != "idle" else { return }
        completeRegistration(.failure(RelayFailure(message: message ?? "Call cancelled.")))
        generation += 1; finishing = true
        sendTask?.cancel(); sendTask = nil
        audio?.stop(); audio = nil
        systemCall?.end(failed: message != nil); systemCall = nil
        lastStatistics = direct?.pipeline?.statistics ?? [:]
        let direct = self.direct; self.direct = nil
        phase = "idle"; muted = false; changingMute = false; error = message
        UserDefaults.standard.set(message, forKey: "DotWatch.lastWatchError")
        link.reportWatchEvent(message.map { "\(deviceName) ended: \($0)" } ?? "\(deviceName) user ended call")
        Task { await direct?.finish(); self.finishing = false }
        #if os(watchOS)
        WKInterfaceDevice.current().play(.stop)
        #endif
    }
}
