import AppIntents

// This intent lives in the app targets (no extension). CallKit, rather than
// an audio-recording intent or a recording Live Activity, owns the VoIP session.
struct CallDotIntent: AppIntent {
    static var title: LocalizedStringResource = "Call agent"
    static var isDiscoverable: Bool = true
    static var description = IntentDescription("Open the app and start a voice call with Dot on this iPhone or Apple Watch. Unlock your device if prompted.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AccountVault.load() != nil || DirectProbe.enabled else {
            return .result(dialog: "Open \(AppBrand.name) on your iPhone to connect ChatGPT first.")
        }
        try await CallModel.shared.startFromSiri()
        return .result(dialog: "Calling \(AppBrand.name).")
    }
}

// Recording requires the app in front. Shortcuts opens the composer on the device
// where this shortcut runs; the user still reviews/stops and taps Send.
struct SpeakDotIntent: AppIntent {
    static var title: LocalizedStringResource = "Record voice message"
    static var description = IntentDescription("Open the app and record a voice message to your connected Dot on this iPhone or Apple Watch. Tap Send when you are ready. Recording requires the app in the foreground.")
    static var isDiscoverable: Bool = true
    static var supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor func perform() async throws -> some IntentResult {
        CallModel.shared.cancelWidgetLaunch()
        return try await perform(using: VoiceMessageLaunch.shared)
    }
    @MainActor func perform(using launch: VoiceMessageLaunch) async throws -> some IntentResult {
        try launch.request()
        // A spoken success dialog can compete with the recorder for audio.
        return .result()
    }
}

struct DotShortcuts: AppShortcutsProvider {
    // Configured INAlternativeAppNames apply to both actions.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CallDotIntent(), phrases: [
            "Call \(.applicationName)",
            "Talk to \(.applicationName)",
            "Start a call with \(.applicationName)"
        ], shortTitle: "Call", systemImageName: "phone.fill")
        AppShortcut(intent: SpeakDotIntent(), phrases: [
            "Record a voice message with \(.applicationName)"
        ], shortTitle: "Voice message", systemImageName: "mic.fill")
    }
    static var shortcutTileColor: ShortcutTileColor { .yellow }
}
