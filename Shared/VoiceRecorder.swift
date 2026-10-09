import AVFAudio
import SwiftUI

@MainActor final class VoiceRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()
    @Published private(set) var recording = false
    @Published private(set) var preparing = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var hasRecording = false
    @Published var error: String?
    var holdsMicrophone: Bool { recording || preparing }
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var file: URL?
    private var account: DotAccount?
    private var generation = 0
    private var ownsAudioSession = false
    private var interruption: NSObjectProtocol?
    private var mediaReset: NSObjectProtocol?
    override init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pauseForBackground() }
        }
        mediaReset = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForBackground() }
        }
        // A draft is only retained while this app process is alive. Remove our own
        // abandoned temporary drafts after a crash, without touching other files.
        for url in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("voice-draft-") && url.pathExtension == "m4a" {
            try? FileManager.default.removeItem(at: url)
        }
    }
    func start() async {
        guard !VoiceSimulatorUI.enabled else { return }
        guard !holdsMicrophone, !hasRecording else { return }
        guard ForegroundCallLauncher.appIsActive() else { error = "Open \(AppBrand.name) to record a voice message."; return }
        guard CallModel.shared.phase == "idle", !CallModel.shared.finishing else { error = "End your call before recording."; return }
        guard let account = AccountVault.load() else { error = "Sign in on iPhone first."; return }
        guard VoiceOutbox.shared.canRecord else { error = "Outbox is full or unavailable. Check Messages first."; return }
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        generation += 1; let attempt = generation
        preparing = true; error = nil; self.account = account
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard attempt == generation else { return }
        guard !Task.isCancelled else { stop(); return }
        guard allowed else { preparing = false; self.account = nil; error = "Enable microphone access in Settings to record a message."; return }
        // Permission can return after the app leaves the foreground, including
        // when a newly presented sheet missed the earlier background change.
        guard ForegroundCallLauncher.appIsActive() else {
            preparing = false; self.account = nil; error = "Open \(AppBrand.name) and tap Record to continue."; return
        }
        guard CallModel.shared.phase == "idle", account.accountID == AccountVault.load()?.accountID, account.dotID == AccountVault.load()?.dotID else {
            preparing = false; self.account = nil; error = "The call or connected Dot changed. Try recording again."; return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true); ownsAudioSession = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-draft-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000])
            self.recorder = recorder; file = url
            recorder.delegate = self
            guard recorder.prepareToRecord() else { throw RelayFailure(message: "Microphone could not start. Try again.") }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            guard recorder.record() else { throw RelayFailure(message: "Microphone could not start. Try again.") }
            duration = 0; recording = true; preparing = false
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecording() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            discard()
            self.error = (error as? RelayFailure)?.message ?? "Could not start recording. Try again."
        }
    }
    private func updateRecording() {
        guard recording, let recorder, let file else { return }
        let elapsed = recorder.currentTime
        guard elapsed.isFinite, elapsed >= 0 else {
            stop(); error = "Recording stopped. You can send the captured audio or discard it."; return
        }
        duration = elapsed
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber else { throw RelayFailure(message: "Could not check recording storage.") }
            if VoiceRecordingLimits.shouldStop(audioBytes: bytes.intValue) {
                stop()
                error = "Recording stopped near the 10 MB recording size limit. Your recording is ready to send."
            }
        } catch {
            stop()
            self.error = "Recording stopped because storage could not be checked. You can send the captured audio or discard it."
        }
    }
    func stop() {
        generation += 1; preparing = false
        if recording, let elapsed = recorder?.currentTime, elapsed.isFinite, elapsed >= 0 { duration = max(duration, elapsed) }
        recording = false; timer?.invalidate(); timer = nil
        let captured = recorder; recorder = nil
        captured?.delegate = nil; captured?.stop()
        hasRecording = file != nil && duration.isFinite && duration >= 1
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func pauseForBackground() {
        guard holdsMicrophone else { return }
        stop()
        error = hasRecording ? "Recording stopped. Tap Send when you're ready." : "Recording stopped. Tap Record to try again."
    }
    func send() -> Bool {
        stop()
        guard hasRecording, let file, let account else { error = "Record at least one second first."; return false }
        do {
            try VoiceOutbox.shared.enqueue(file: file, duration: duration, account: account)
            discard(); return true
        } catch { self.error = (error as? RelayFailure)?.message ?? "Could not save the recording. Try Send again."; return false }
    }
    func discard() {
        generation += 1; stop(); preparing = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; account = nil; hasRecording = false; duration = 0; error = nil
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard self.recorder === recorder, recording else { return }
        stop()
        if !flag { error = "Recording was interrupted. You can send the captured audio or discard it." }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard self.recorder === recorder else { return }
        stop()
        self.error = "Could not finish the recording. Discard it and record again."
        hasRecording = false
    }
}

struct VoiceRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var recorder = VoiceRecorder.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: recorder.recording ? "waveform" : "mic.fill").font(.title).foregroundStyle(AppBrand.accent)
                Text(recorder.recording ? "Recording" : "Voice message").font(.headline)
                Text(String(format: "%d:%02d", Int(recorder.duration) / 60, Int(recorder.duration) % 60)).monospacedDigit()
                    .accessibilityLabel("Recorded \(Int(recorder.duration)) seconds")
                if recorder.preparing { ProgressView("Starting…") }
                if recorder.recording || recorder.hasRecording {
                    Button { if recorder.send() { dismiss() } } label: { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent).tint(AppBrand.accent).foregroundStyle(.black)
                        .disabled(recorder.duration < 1)
                    if recorder.recording { Button("Stop") { recorder.stop() } }
                } else if !recorder.preparing {
                    Button("Record") { Task { await recorder.start() } }
                }
                if let error = recorder.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                Text("Send saves your recording to Messages, then transcribes and sends it to your Dot.").font(.caption2).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { recorder.discard(); dismiss() }
            }.padding(.horizontal, 8)
        }
        .task { if !recorder.hasRecording { await recorder.start() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { recorder.pauseForBackground() } }
        .onDisappear { recorder.pauseForBackground() }
    }
}

struct VoiceOutboxView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var outbox = VoiceOutbox.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Messages").font(.headline)
                if outbox.messages.isEmpty { Text("No messages yet.").font(.caption) }
                ForEach(outbox.messages.reversed()) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(job.createdAt, style: .time); Spacer(); Text("\(Int(job.duration))s") }.font(.caption2).foregroundStyle(.secondary)
                        Text(label(job.state)).font(.headline).foregroundStyle(job.needsAttention ? .orange : .primary)
                        if let text = outbox.transcript(for: job) { Text(text).font(.caption) }
                        if let detail = job.detail { Text(detail).font(.caption2) }
                        if job.needsAttention { Button("Retry") { outbox.retry(job.id) } }
                        if !job.pending { Button("Remove", role: .destructive) { outbox.remove(job.id) } }
                    }
                    Divider()
                }
                if let error = outbox.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                Text("Your device may wait for a connection or defer delivery while the app is closed. Sent means Dot accepted the message.").font(.caption2).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
            }.padding(.horizontal, 8)
        }
    }
    private func label(_ state: VoiceMessage.State) -> String {
        switch state {
        case .queued: return "Queued"
        case .transcribing: return "Transcribing…"
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .failed: return "Not sent"
        case .uncertain: return "Check delivery"
        }
    }
}
