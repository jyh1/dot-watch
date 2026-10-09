import Combine
import Foundation

// An intent only requests the recording screen. The visible screen owns audio,
// permissions and the user's explicit Send; no message is sent from the intent.
@MainActor final class VoiceMessageLaunch: ObservableObject {
    static let shared = VoiceMessageLaunch()
    @Published private(set) var requestID: UUID?
    @Published private(set) var error: String?
    private let launcher: ForegroundCallLauncher
    private let isActive: () -> Bool
    private let prerequisiteFailure: () -> String?
    var isPending: Bool { launcher.isPending || requestID != nil }

    init(timeout: Duration = .seconds(10), isActive: (() -> Bool)? = nil, prerequisiteFailure: (() -> String?)? = nil) {
        let active = isActive ?? { ForegroundCallLauncher.appIsActive() }
        self.isActive = active
        launcher = ForegroundCallLauncher(timeout: timeout, isActive: active)
        self.prerequisiteFailure = prerequisiteFailure ?? { Self.currentFailure() }
    }
    private static func currentFailure() -> String? {
        if VoiceSimulatorUI.enabled { return nil }
        guard AccountVault.load() != nil else { return "Open \(AppBrand.name) on iPhone to connect ChatGPT first." }
        guard CallModel.shared.phase == "idle", !CallModel.shared.finishing else { return "End your call before recording a voice message." }
        guard VoiceRecorder.shared.hasRecording || VoiceOutbox.shared.canRecord else { return "Check Messages before recording another voice message." }
        return nil
    }
    func request() throws {
        if let failure = prerequisiteFailure() { error = failure; throw RelayFailure(message: failure) }
        guard !isPending else { return }
        error = nil
        launcher.request(start: { [weak self] in
            guard let self else { return }
            if let failure = prerequisiteFailure() { error = failure; return }
            requestID = UUID()
        }, onTimeout: { [weak self] in
            self?.error = "Open \(AppBrand.name) and tap Speak. The app could not become active."
        })
    }
    @discardableResult func consumeRequest() -> UUID? {
        guard let id = requestID, isActive() else { return nil }
        requestID = nil
        if let failure = prerequisiteFailure() { error = failure; return nil }
        return id
    }
    func cancel() { launcher.cancel(); requestID = nil }
}
