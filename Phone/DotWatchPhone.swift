import SwiftUI
import WebKit
import AppIntents

@MainActor final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    // Instantiate WatchConnectivity during process launch, including a background wake from Watch.
    let bridge = PhoneBridge()
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
                .task { DotShortcuts.updateAppShortcutParameters(); if DirectProbe.enabled { await call.runSilentProbe() } }
                .onOpenURL { url in if CallRoute.matches(url) { call.startFromWidget() } }
                .onChange(of:scenePhase) { _, phase in CallTrace.record("iPhone scene \(String(describing:phase))") }
        }
    }
}
struct LoginBrowser: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct SetupView: View {
    @EnvironmentObject var bridge: PhoneBridge
    @EnvironmentObject var login: DotLogin
    @EnvironmentObject var call: CallModel
    @State private var showingLogin = false
    @State private var showingSettings = false
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
                if bridge.account == nil {
                    Section {
                        Button("Connect ChatGPT") { showingLogin = true }
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
                            }
                            Button("End call", role: .destructive) { call.end() }
                        } else {
                            Button { call.start() } label: {
                                Label(call.finishing ? "Ending call…" : "Call \(AppBrand.name)", systemImage: "phone.fill")
                            }.disabled(call.finishing)
                        }
                        if let error = call.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    }
                    Section("Call with Siri") {
                        Text(AppBrand.siriHint)
                        Text("The call uses the microphone and speaker on the device where you ask. You can also use “Talk to \(AppBrand.name).”")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Calling from your Watch") {
                        Text("Open \(AppBrand.name) and tap Call, or add the \(AppBrand.name) widget to your Smart Stack. Speak and listen on your Watch.")
                        Text("Sign-in syncs to your Watch once. Calls then connect from the Watch using its available internet connection; this app does not relay the audio.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("Settings & diagnostics", isExpanded: $showingSettings) {
                        Button("Refresh ChatGPT login") { showingLogin = true }
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
            .sheet(isPresented: $showingLogin) {
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
                                do { let account = try await login.connect(thread: thread); bridge.use(account); showingLogin = false }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).disabled(busy || thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).padding()
                    }.navigationTitle("ChatGPT sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingLogin = false } } }
                }
            }
        }
    }
}
