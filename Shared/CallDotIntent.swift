import AppIntents
import AVFAudio

// This intent lives in the app targets (no extension). CallKit, rather than
// an audio-recording intent or a recording Live Activity, owns the VoIP session.
struct CallDotIntent: AppIntent {
    static var title: LocalizedStringResource = "Call agent"
    static var description = IntentDescription("Start a voice call with Dot on this iPhone or Apple Watch.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AccountVault.load() != nil || DirectProbe.enabled else {
            return .result(dialog: "Open \(AppBrand.name) on your iPhone to connect ChatGPT first.")
        }
        if !DirectProbe.enabled && AVAudioApplication.shared.recordPermission != .granted {
            // Only first-time permission setup needs the app in front. Established
            // calls use CallKit's audio activation, including from the lock screen.
            try await continueInForeground("Open \(AppBrand.name) to allow microphone access.", alwaysConfirm: false)
        }
        try await CallModel.shared.startFromSiri()
        return .result(dialog: "Calling \(AppBrand.name).")
    }
}

struct DotShortcuts: AppShortcutsProvider {
    // Configured INAlternativeAppNames share this one call action.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CallDotIntent(), phrases: [
            "Call \(.applicationName)",
            "Talk to \(.applicationName)",
            "Start a call with \(.applicationName)"
        ], shortTitle: "Call", systemImageName: "phone.fill")
    }
    static var shortcutTileColor: ShortcutTileColor { .yellow }
}
