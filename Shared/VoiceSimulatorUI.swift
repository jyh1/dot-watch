import Foundation

// Explicit simulator-only layout fixture shared by iPhone and Watch. Views
// showing this fixture must not start audio, refresh credentials, or resume jobs.
enum VoiceSimulatorUI {
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--voice-ui-fixture")
        #else
        return false
        #endif
    }
}
