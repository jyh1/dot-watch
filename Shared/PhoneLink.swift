import Foundation
import WatchConnectivity

struct RelayFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
// A timeout and a late WatchConnectivity reply must resume an async request only once.
final class ReplyGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var ready = false
    @Published var reachable = false
    @Published var dotName = AppBrand.name
    @Published var setupError: String?
    func reportWatchEvent(_ message: String) {
        CallTrace.record(message)
        #if os(watchOS)
        let event: [String: Any] = ["action":"watchTrace", "eventID":UUID().uuidString, "build":CallTrace.build, "message":String(message.prefix(300))]
        // Coalesce progress instead of putting two messages per event ahead of call traffic.
        // Keep a durable copy of terminal events, where reachability may already be lost.
        if message.hasPrefix("Watch ended:") || message == "Watch user ended call" {
            WCSession.default.transferUserInfo(event)
        }
        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(event)
        }
        #endif
    }
    #if os(iOS)
    var onCommand: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    #endif
    override init() {
        super.init()
        if DirectProbe.enabled { ready = true; return }
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func publish(ready: Bool, name: String) {
        self.ready = ready; dotName = name
        #if os(iOS)
        var context: [String: Any] = ["ready": ready, "name": name, "directVersion": 1]
        if ready, let credentials = try? WatchCredentials.export() { context["credentials"] = credentials }
        try? WCSession.default.updateApplicationContext(context)
        #endif
    }
    @MainActor func command(_ action: String, id: String? = nil, muted: Bool? = nil, message: String? = nil) async throws -> [String: Any] {
        var payload: [String: Any] = ["action": action]
        if let id { payload["id"] = id }; if let muted { payload["muted"] = muted }
        if let message { payload["message"] = String(message.prefix(300)) }
        guard WCSession.default.activationState == .activated else { throw RelayFailure(message: "The iPhone connection is starting. Try again.") }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) { gate.finish(.failure(RelayFailure(message: "iPhone did not respond. Open \(AppBrand.name) on iPhone and try again."))) }
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                if let error = reply["error"] as? String { gate.finish(.failure(RelayFailure(message: error))) }
                else { gate.finish(.success(reply)) }
            }, errorHandler: { gate.finish(.failure(RelayFailure(message: $0.localizedDescription))) })
        }
    }
    @MainActor func refreshSetup() async {
        #if os(watchOS)
        if let account = AccountVault.load() { ready = true; dotName = account.name; setupError = nil; return }
        #endif
        do {
            let state = try await command("setup")
            #if os(watchOS)
            if let credentials = state["credentials"] as? Data { try WatchCredentials.accept(credentials) }
            ready = AccountVault.load() != nil
            #else
            ready = state["ready"] as? Bool ?? false
            #endif
            dotName = state["name"] as? String ?? AppBrand.name; setupError = ready ? nil : "Open \(AppBrand.name) on iPhone once to sync sign-in."
        } catch { setupError = "Open \(AppBrand.name) on iPhone once, then check again." }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        sessionReachabilityDidChange(session)
        #if os(watchOS)
        receive(session.receivedApplicationContext)
        reportWatchEvent("Watch companion activated")
        Task { @MainActor in await self.refreshSetup() }
        #else
        DispatchQueue.main.async { self.publish(ready: self.ready, name: self.dotName) }
        #endif
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.reachable = session.isReachable }
        #if os(watchOS)
        if session.isReachable { Task { @MainActor in if !self.ready { await self.refreshSetup() } } }
        #endif
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        #if os(iOS)
        if applicationContext["action"] as? String == "watchTrace" {
            DispatchQueue.main.async { self.onCommand?(applicationContext, { _ in }) }
        }
        #else
        receive(applicationContext)
        #endif
    }
    private func receive(_ context: [String: Any]) {
        #if os(watchOS)
        DispatchQueue.main.async {
            do {
                if let data = context["credentials"] as? Data { try WatchCredentials.accept(data) }
                else if context["directVersion"] as? Int == 1, context["ready"] as? Bool == false { try WatchCredentials.clear() }
                self.ready = AccountVault.load() != nil
                self.dotName = AccountVault.load()?.name ?? AppBrand.name
                self.setupError = self.ready ? nil : "Open \(AppBrand.name) on iPhone once to sync sign-in."
            } catch { self.setupError = error.localizedDescription }
        }
        #endif
    }
    #if os(iOS)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["action"] as? String == "watchTrace" else { return }
        DispatchQueue.main.async { self.onCommand?(userInfo, { _ in }) }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { self.onCommand?(message, replyHandler) }
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.publish(ready: self.ready, name: self.dotName) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
