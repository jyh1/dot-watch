import SwiftUI
import WebKit
import AppIntents

@MainActor final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    // Instantiate WatchConnectivity during process launch, including a background wake from Watch.
    let bridge = PhoneBridge()
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        VoiceOutbox.shared.handleBackgroundSession(identifier: identifier, completionHandler: completionHandler)
    }
    func applicationDidEnterBackground(_ application: UIApplication) { CallTrace.record("iPhone entered background") }
    func applicationDidBecomeActive(_ application: UIApplication) { CallTrace.record("iPhone became active") }
}
@main struct DotWatchPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var login = DotLogin()
    @StateObject private var call = CallModel.shared
    var body: some Scene {
        WindowGroup {
            SetupView().environmentObject(appDelegate.bridge).environmentObject(login).environmentObject(call)
                .task { call.updateScenePhase(scenePhase); DotShortcuts.updateAppShortcutParameters(); guard !VoiceSimulatorUI.enabled else { return }; if DirectProbe.enabled { await call.runSilentProbe() } }
                .onOpenURL { url in
                    switch CallRoute.action(for: url) {
                    case .some(.call):
                        VoiceMessageLaunch.shared.cancel()
                        if !VoiceSimulatorUI.enabled { call.startFromWidget() }
                    case .some(.speak):
                        call.cancelWidgetLaunch()
                        try? VoiceMessageLaunch.shared.request()
                    case .none: break
                    }
                }
                .onChange(of:scenePhase) { _, phase in
                    call.updateScenePhase(phase)
                    if phase == .background { VoiceMessageLaunch.shared.cancel() }
                    guard !VoiceSimulatorUI.enabled else { return }
                    if phase == .active { VoiceOutbox.shared.dismissMessageFeedback(); VoiceOutbox.shared.resume(); VoiceOutbox.shared.accountChanged() }
                    CallTrace.record("iPhone scene \(String(describing:phase))")
                }
        }
    }
}
struct LoginBrowser: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct SetupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var bridge: PhoneBridge
    @EnvironmentObject var login: DotLogin
    @EnvironmentObject var call: CallModel
    private enum Sheet: String, Identifiable {
        case login, recording, outbox, diagnostics
        var id: String { rawValue }
    }
    @State private var activeSheet: Sheet?
    @ObservedObject private var recorder = VoiceRecorder.shared
    @ObservedObject private var outbox = VoiceOutbox.shared
    @ObservedObject private var voiceLaunch = VoiceMessageLaunch.shared
    @State private var showingSettings = false
    @State private var fixtureIntentPerformed = false
    @State private var busy = false
    @State private var error: String?
    @State private var thread = AppBrand.defaultAgentPage
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image("Dot").resizable().scaledToFit().frame(width: 172, height: 172).accessibilityHidden(true)
                        Text(bridge.account?.name ?? AppBrand.name).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        Text(bridge.account == nil ? "Your agent, a call away." : "Your agent, a call away.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }.listRowBackground(Color.clear)
                if bridge.account == nil && !VoiceSimulatorUI.enabled {
                    Section {
                        Button("Connect ChatGPT") { activeSheet = .login }
                        Text("Sign in once to connect your existing agent. Your session is stored securely on your paired iPhone and Watch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if call.phase != "idle" {
                            Label(call.phase == "active" ? "Call in progress" : "Connecting…", systemImage: "waveform")
                            if call.phase == "connecting" { Text(call.stage).font(.footnote).foregroundStyle(.secondary) }
                            Text(call.startedAt, style: .timer).monospacedDigit()
                            if call.phase == "active" {
                                Button(call.muted ? "Unmute" : "Mute") { call.toggleMute() }.disabled(call.changingMute)
                                HStack {
                                    Text("Audio output")
                                    Spacer()
                                    CallAudioRoutePicker().frame(width: 44, height: 44)
                                        .accessibilityLabel("Choose call audio output")
                                }
                            }
                            Button("End call", role: .destructive) { call.end() }
                        } else {
                            Button { voiceLaunch.cancel(); if !VoiceSimulatorUI.enabled { call.start() } } label: {
                                Label(call.finishing ? "Ending call…" : "Call \(AppBrand.name)", systemImage: "phone.fill")
                            }.disabled(call.finishing || recorder.holdsMicrophone)
                            Button { call.cancelWidgetLaunch(); try? voiceLaunch.request() } label: {
                                Label(recorder.hasRecording ? "Resume voice message" : "Speak", systemImage: "mic.fill")
                            }.disabled(call.finishing || (!recorder.hasRecording && !outbox.canRecord && !VoiceSimulatorUI.enabled))
                        }
                        if let error = call.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    }
                    Section("Shortcuts actions") {
                        Text("In Shortcuts, choose Add Action → Apps → \(AppBrand.name), then Call agent or Record voice message. Use these actions in your own shortcuts or automations.")
                        Text("Record voice message opens this app on the device running the action. Recording and Messages stay on that device. Tap Send when ready; recording requires the foreground app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Calling from your Watch") {
                        Text("Open \(AppBrand.name) and tap Call, or add the \(AppBrand.name) widget to your Smart Stack. Speak and listen on your Watch.")
                        Text("Sign-in syncs to your Watch once. Calls then connect from the Watch using its available internet connection; this app does not relay the audio.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !VoiceSimulatorUI.enabled, outbox.hasMessages {
                    Section("Messages") {
                        Button { activeSheet = .outbox } label: {
                            Label(outbox.status ?? "Messages", systemImage: outbox.failedCount > 0 ? "exclamationmark.circle" : "arrow.up.circle")
                        }
                        if let transcript = outbox.transcriptPreview {
                            Text(transcript).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                .accessibilityLabel("Transcript: \(transcript)")
                        }
                    }
                }
                if let error = voiceLaunch.error { Section { Text(error).foregroundStyle(.orange) } }
                if let error = outbox.error, !VoiceSimulatorUI.enabled { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    DisclosureGroup("Settings & diagnostics", isExpanded: $showingSettings) {
                        Button("Call audio diagnostics") { activeSheet = .diagnostics }
                        Button("Refresh ChatGPT login") { activeSheet = .login }.disabled(VoiceSimulatorUI.enabled)
                        TextField("Agent page URL or ID", text: $thread).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
                        if let account = bridge.account {
                            Button(busy ? "Checking…" : "Check saved login") {
                                busy = true; error = nil
                                Task {
                                    defer { busy = false }
                                    do { try await SessionCookies.capture(); let refreshed = try await DotSession.valid(account, force: true); bridge.use(refreshed); bridge.status = "Saved ChatGPT session renewed." }
                                    catch { self.error = error.localizedDescription }
                                }
                            }.disabled(busy || call.phase != "idle" || call.finishing)
                            Button("Disconnect", role: .destructive) { bridge.forget() }
                        }
                        Text("iPhone build \(CallTrace.build)").font(.caption)
                        Text(bridge.watchDiagnostic).font(.caption).textSelection(.enabled)
                        Text(bridge.status).font(.caption).textSelection(.enabled)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle(AppBrand.name).navigationBarTitleDisplayMode(.inline)
            .task {
                if !VoiceSimulatorUI.enabled { outbox.resume() }
                if VoiceSimulatorUI.enabled, ProcessInfo.processInfo.arguments.contains("--voice-shortcut-probe"), !fixtureIntentPerformed {
                    fixtureIntentPerformed = true
                    do { _ = try await SpeakDotIntent().perform() }
                    catch { self.error = error.localizedDescription }
                }
                showRequestedRecording()
            }
            .onChange(of: call.phase) { previous, phase in
                if previous != "idle", phase == "idle" { outbox.dismissMessageFeedback() }
            }
            .onChange(of: voiceLaunch.requestID) { _, id in if id != nil { showRequestedRecording() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { showRequestedRecording() } }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .diagnostics:
                    CallDiagnosticsView()
                case .recording:
                    if VoiceSimulatorUI.enabled {
                        VStack(spacing: 12) {
                            Label("Voice message", systemImage: "mic.fill").font(.headline)
                            Text("Simulator preview").foregroundStyle(.secondary)
                            Button("Done") { activeSheet = nil }
                        }.padding()
                    } else { VoiceRecordingView() }
                case .outbox:
                    VoiceOutboxView()
                case .login:
                NavigationStack {
                    VStack(spacing: 0) {
                        Text("Sign in on the official ChatGPT page, then tap Connect. Your session is saved in Keychain and synced securely to your paired Watch.").font(.caption).padding()
                        TextField("Paste your ChatGPT Dot page URL", text: $thread)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).padding(.horizontal)
                        LoginBrowser(view: login.webView)
                        if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                        Button(busy ? "Connecting…" : "Connect") {
                            busy = true; error = nil
                            Task {
                                defer { busy = false }
                                do { let account = try await login.connect(thread: thread); bridge.use(account); activeSheet = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).disabled(busy || thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).padding()
                    }.navigationTitle("ChatGPT sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { activeSheet = nil } } }
                }
                }
            }
        }
    }
    private func showRequestedRecording() {
        if voiceLaunch.consumeRequest() != nil { activeSheet = .recording }
    }
}
