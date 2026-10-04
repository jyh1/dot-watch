import Foundation

@MainActor final class PhoneBridge: ObservableObject {
    let link = CallModel.shared.link
    @Published var account = DirectProbe.account ?? AccountVault.load()
    @Published var status = "Sign in to connect \(AppBrand.name)."
    @Published var watchDiagnostic = UserDefaults.standard.string(forKey: "DotWatch.lastWatchEvent") ?? "Watch build not reported yet."
    private var watchEvents = Set<String>()
    init() {
        link.onCommand = { [weak self] request, reply in self?.command(request, reply: reply) }
        update()
    }
    func update() {
        link.publish(ready: account != nil, name: account?.name ?? AppBrand.name)
        status = account.map { "Connected to \($0.name)." } ?? "Sign in to connect \(AppBrand.name)."
    }
    func use(_ account: DotAccount) { self.account = account; update() }
    func forget() {
        CallModel.shared.end()
        do { try AccountVault.save(nil); try SessionCookies.save(nil); account = nil; update() }
        catch { status = error.localizedDescription }
    }
    func command(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let action = request["action"] as? String else { reply(["error":"Invalid request."]); return }
        if action == "watchTrace", let message = request["message"] as? String, let eventID = request["eventID"] as? String {
            if watchEvents.insert(eventID).inserted {
                if watchEvents.count > 200 { watchEvents = [eventID] }
                let build = request["build"] as? String ?? "?"
                watchDiagnostic = "Watch build \(build): \(message.prefix(300))"
                UserDefaults.standard.set(watchDiagnostic, forKey:"DotWatch.lastWatchEvent")
                CallTrace.record(watchDiagnostic)
            }
            reply(["ok":true]); return
        }
        if action == "setup" {
            account = AccountVault.load(); update()
            var state: [String: Any] = ["ready": account != nil, "name": account?.name ?? AppBrand.name]
            if let credentials = try? WatchCredentials.export() { state["credentials"] = credentials }
            reply(state); return
        }
        reply(["error":"Update \(AppBrand.name) on your Watch. Calls now connect directly."])
    }
}
