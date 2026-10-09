import SwiftUI
import AppIntents
import WatchKit
import WidgetKit

enum DotWidgetTimeline {
    static func refreshAfterUpdate() {
        let kind = Bundle.main.object(forInfoDictionaryKey: "DotWidgetKind") as? String ?? "DotCall"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let marker = kind + ":" + version
        let key = "DotWatch.widgetTimelineVersion"
        guard UserDefaults.standard.string(forKey: key) != marker else { return }
        // Keep the installed widget kind stable while refreshing its saved view.
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        UserDefaults.standard.set(marker, forKey: key)
    }
}

@MainActor final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if VoiceSimulatorUI.enabled { task.setTaskCompletedWithSnapshot(false) }
            else if let task = task as? WKURLSessionRefreshBackgroundTask { VoiceOutbox.shared.handle(task) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}

@main struct DotWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var call = CallModel.shared
    var body: some Scene {
        WindowGroup {
            CallView().environmentObject(call.link).environmentObject(call)
                .task { call.updateScenePhase(scenePhase) }
                .onChange(of:scenePhase) { _, phase in
                    call.updateScenePhase(phase)
                    if phase == .active { DotWidgetTimeline.refreshAfterUpdate() }
                    if phase == .background { VoiceMessageLaunch.shared.cancel() }
                    guard !VoiceSimulatorUI.enabled else { return }
                    if phase == .active { VoiceOutbox.shared.resume(); VoiceOutbox.shared.accountChanged() }
                    call.link.reportWatchEvent("Watch scene \(String(describing:phase)); call \(call.phase)")
                }
        }
    }
}
struct CallView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var link: PhoneLink
    @EnvironmentObject var call: CallModel
    private enum Sheet: String, Identifiable {
        case info, recording, outbox, diagnostics
        var id: String { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var fixtureSelection: CallRoute.Action?
    #if DEBUG && targetEnvironment(simulator)
    @State private var fixtureIntentPerformed = false
    #endif
    @ObservedObject private var outbox = VoiceOutbox.shared
    @ObservedObject private var recorder = VoiceRecorder.shared
    @ObservedObject private var voiceLaunch = VoiceMessageLaunch.shared
    private let gold = AppBrand.accent
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if call.phase == "idle" {
                    Image("Dot").resizable().scaledToFit().scaleEffect(1.65).frame(width: 80, height: 48).clipped()
                        .accessibilityHidden(true)
                    Text(link.dotName).font(.system(.title3, design: .rounded, weight: .semibold)).lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Image("Dot").resizable().scaledToFit().scaleEffect(1.6).frame(width: 34, height: 34).clipped().accessibilityHidden(true)
                        Text(link.dotName).font(.headline).lineLimit(1)
                    }
                }
                if call.phase != "idle" {
                    if call.phase == "connecting" {
                        ProgressView().tint(gold)
                        Text(call.stage).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(call.muted ? "Microphone muted" : "Listening").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(call.startedAt, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if call.phase == "active" {
                        Button { call.toggleMute() } label: {
                            Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
                        }.disabled(call.changingMute)
                    }
                    Button(role: .destructive) { call.end() } label: { Label("End call", systemImage: "phone.down.fill") }
                } else if link.ready || VoiceSimulatorUI.enabled {
                    HStack(spacing: 6) {
                        Button { call.cancelWidgetLaunch(); voiceLaunch.cancel(); if !VoiceSimulatorUI.enabled { call.start() } } label: {
                            VStack(spacing: 4) { Image(systemName: "phone.fill"); Text(call.finishing ? "Ending…" : "Call") }
                                .font(.headline).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(gold).foregroundStyle(.black)
                            .disabled(call.finishing || recorder.holdsMicrophone)
                        Button { call.cancelWidgetLaunch(); voiceLaunch.cancel(); if !VoiceSimulatorUI.enabled { activeSheet = .recording } } label: {
                            VStack(spacing: 4) { Image(systemName: "mic.fill"); Text(recorder.hasRecording ? "Resume" : "Speak") }
                                .font(.headline).frame(maxWidth: .infinity)
                        }.disabled(call.finishing || (!recorder.hasRecording && !outbox.canRecord && !VoiceSimulatorUI.enabled))
                            .accessibilityLabel(recorder.hasRecording ? "Resume voice message" : "Speak a voice message")
                    }
                } else {
                    Text(link.setupError ?? "Checking your iPhone…").font(.caption).multilineTextAlignment(.center)
                    Button("Check iPhone") { Task { await link.refreshSetup() } }
                }
                if VoiceSimulatorUI.enabled, fixtureSelection == .call {
                    Text("Call selected").font(.caption2)
                }
                if outbox.hasMessages {
                    let status = outbox.status ?? "Messages"
                    Button { activeSheet = .outbox } label: {
                        Label(status, systemImage: outbox.failedCount > 0 ? "exclamationmark.circle" : (outbox.pendingCount > 0 ? "arrow.up.circle" : "checkmark.circle"))
                            .font(.caption2).foregroundStyle(outbox.failedCount > 0 ? .orange : .secondary)
                    }.buttonStyle(.plain)
                }
                if let transcript = outbox.transcriptPreview {
                    Text(transcript).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Transcript: \(transcript)")
                }
                if let error = outbox.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                if let error = voiceLaunch.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                if let error = call.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if call.phase == "idle" {
                    Button { activeSheet = .info } label: { Image(systemName: "info.circle").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("About Dot")
                }
            }.padding(.horizontal, 8)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .diagnostics:
                CallDiagnosticsView()
            case .recording:
                if VoiceSimulatorUI.enabled {
                    VStack(spacing: 12) {
                        Label("Speak", systemImage: "mic.fill").font(.headline)
                        Text("Voice message").font(.caption)
                        Text("Simulator preview").font(.caption2).foregroundStyle(.secondary)
                        Button("Done") { activeSheet = nil }
                    }.padding()
                } else { VoiceRecordingView() }
            case .outbox:
                VoiceOutboxView()
            case .info:
                ScrollView { VStack(spacing: 12) {
                    Text(AppBrand.name).font(.headline)
                    Text("Build \(CallTrace.build)").font(.caption)
                    Text("Say ‘Siri, call \(AppBrand.name)’, or add \(AppBrand.name) to your Smart Stack. Calls connect from your Watch. Speak records a message for your Dot; check Messages for delivery. Sign in on iPhone once; the iPhone app does not need to stay open.").font(.caption)
                    Button("Call audio diagnostics") { activeSheet = .diagnostics }
                    Button("Done") { activeSheet = nil }
                }.padding() }
            }
        }
        .onOpenURL(perform: openWidgetURL)
        .onChange(of: call.phase) { previous, phase in
            if phase != "idle" { call.cancelWidgetLaunch(); voiceLaunch.cancel() }
            else if previous != "idle" { outbox.dismissMessageFeedback() }
        }
        .onChange(of: voiceLaunch.requestID) { _, _ in presentVoiceRequest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { outbox.dismissMessageFeedback(); presentVoiceRequest() }
            else if phase == .background { call.cancelWidgetLaunch() }
        }
        .task {
            DotWidgetTimeline.refreshAfterUpdate()
            presentVoiceRequest()
            if VoiceSimulatorUI.enabled {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--voice-shortcut-probe"), !fixtureIntentPerformed {
                    fixtureIntentPerformed = true
                    do { _ = try await SpeakDotIntent().perform() }
                    catch { call.error = "The voice-message shortcut preview could not open." }
                }
                #endif
                return
            }
            outbox.resume()
            DotShortcuts.updateAppShortcutParameters()
            if DirectProbe.enabled { await call.runSilentProbe() }
            else { await link.refreshSetup() }
        }
        .onChange(of: link.ready) { _, ready in guard !VoiceSimulatorUI.enabled else { return }; outbox.accountChanged(); if !ready { voiceLaunch.cancel(); if !DirectProbe.enabled && call.phase != "idle" { call.end(message: "Dot was disconnected on iPhone.") } } }
    }
    private func presentVoiceRequest() {
        guard ForegroundCallLauncher.appIsActive(), voiceLaunch.consumeRequest() != nil else { return }
        call.cancelWidgetLaunch()
        activeSheet = .recording
    }
    private func openWidgetURL(_ url: URL) {
        guard let action = CallRoute.action(for: url) else { return }
        call.cancelWidgetLaunch()
        voiceLaunch.cancel()
        guard call.phase == "idle", !call.finishing else {
            call.error = "Finish your call before opening another action."; return
        }
        if VoiceSimulatorUI.enabled {
            fixtureSelection = action
            activeSheet = action == .speak ? .recording : nil
            return
        }
        switch action {
        case .call:
            guard !recorder.holdsMicrophone else {
                call.error = "Finish your voice message before calling."; return
            }
            activeSheet = nil
            call.startFromWidget()
        case .speak:
            do { try voiceLaunch.request() }
            catch { call.error = error.localizedDescription }
        }
    }
}
