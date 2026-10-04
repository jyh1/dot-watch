import Foundation

// No real credentials, audio hardware, or external service in this simulator-only fixture.
enum DirectProbe {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--direct-probe")
        #else
        return false
        #endif
    }
    static var duration: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--probe-duration"), i + 1 < args.count else { return 15 }
        return min(300, max(15, Int(args[i + 1]) ?? 15))
    }
    static var account: DotAccount? {
        guard enabled else { return nil }
        return DotAccount(token: "simulator", accountID: "simulator", dotID: "direct_simulator", threadID: "simulator", name: AppBrand.name, deviceID: nil)
    }
    static func transport(_ account: DotAccount) -> DotTransport? {
        #if targetEnvironment(simulator)
        return enabled ? WatchProbeTransport(account) : nil
        #else
        return nil
        #endif
    }
    static func save(_ stats: [String: Int], connected: Bool, error: String?) {
        #if targetEnvironment(simulator)
        var result: [String: Any] = stats
        result["connected"] = connected; result["error"] = error ?? ""; result["build"] = CallTrace.build
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DirectProbe")
        try? JSONSerialization.data(withJSONObject: result).write(to: dir.appendingPathComponent("watch-result.json"))
        try? Data().write(to: dir.appendingPathComponent("done"))
        #endif
    }
}
#if targetEnvironment(simulator)
private final class WatchProbeTransport: DotTransport {
    var account: DotAccount
    init(_ account: DotAccount) { self.account = account }
    func request(action: String, callID: String?, sdp: String?) async throws -> (Data, HTTPURLResponse) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DirectProbe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let response = HTTPURLResponse(url: URL(string: "https://chatgpt.com/simulator-only")!, statusCode: 200, httpVersion: nil, headerFields: ["Location": "/voice/calls/rtc_simulator_direct"])!
        if action == "create", let sdp {
            try sdp.write(to: dir.appendingPathComponent("offer.sdp"), atomically: true, encoding: .utf8)
            for _ in 0..<200 {
                if let answer = try? Data(contentsOf: dir.appendingPathComponent("answer.sdp")) { return (answer,response) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw RelayFailure(message: "Simulator peer did not return an answer.")
        }
        if action == "stop" { try Data().write(to: dir.appendingPathComponent("stopped")) }
        return (Data(), response)
    }
}
#endif
