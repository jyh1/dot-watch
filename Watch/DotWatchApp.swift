import SwiftUI
import AppIntents

@main struct DotWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var call = CallModel.shared
    var body: some Scene {
        WindowGroup {
            CallView().environmentObject(call.link).environmentObject(call)
                .onOpenURL { url in if CallRoute.matches(url) { call.startFromWidget() } }
                .onChange(of:scenePhase) { _, phase in
                    call.link.reportWatchEvent("Watch scene \(String(describing:phase)); call \(call.phase)")
                }
        }
    }
}
struct CallView: View {
    @EnvironmentObject var link: PhoneLink
    @EnvironmentObject var call: CallModel
    @State private var showingInfo = false
    private let gold = AppBrand.accent
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if call.phase == "idle" {
                    Image("Dot").resizable().scaledToFit().scaleEffect(1.65).frame(width: 100, height: 72).clipped()
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
                } else if link.ready {
                    Button { call.start() } label: {
                        Label(call.finishing ? "Ending call…" : "Call", systemImage: "phone.fill").font(.headline).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(gold).foregroundStyle(.black).disabled(call.finishing)
                } else {
                    Text(link.setupError ?? "Checking your iPhone…").font(.caption).multilineTextAlignment(.center)
                    Button("Check iPhone") { Task { await link.refreshSetup() } }
                }
                if let error = call.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if call.phase == "idle" {
                    Button { showingInfo = true } label: { Image(systemName: "info.circle").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("About Dot")
                }
            }.padding(.horizontal, 8)
        }
        .sheet(isPresented: $showingInfo) {
            ScrollView { VStack(spacing: 12) {
                Text(AppBrand.name).font(.headline)
                Text("Build \(CallTrace.build)").font(.caption)
                Text("Say ‘Siri, call \(AppBrand.name)’, or add \(AppBrand.name) to your Smart Stack. Calls connect from your Watch. Sign in on iPhone once; the iPhone app does not need to stay open.").font(.caption)
                Button("Done") { showingInfo = false }
            }.padding() }
        }
        .task { DotShortcuts.updateAppShortcutParameters(); if DirectProbe.enabled { await call.runSilentProbe() } else { await link.refreshSetup() } }
        .onChange(of: link.ready) { _, ready in if !ready && !DirectProbe.enabled && call.phase != "idle" { call.end(message: "Dot was disconnected on iPhone.") } }
    }
}
