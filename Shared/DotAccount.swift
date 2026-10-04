import Foundation
import Security
#if os(iOS)
import WebKit
#endif

struct DotAccount: Codable {
    let token: String, accountID: String, dotID: String, threadID: String, name: String
    let deviceID: String?
    var tokenExpired: Bool {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return true }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = claims["exp"] as? Double else { return true }
        return Date().timeIntervalSince1970 > exp - 60
    }
}
enum AccountVault {
    static let service = Bundle.main.object(forInfoDictionaryKey: "DotKeychainService") as? String ?? "com.example.dotwatch.account"
    static func load() -> DotAccount? {
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(DotAccount.self, from: data)
    }
    private static var key: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "chatgpt"] }
    static func save(_ account: DotAccount?) throws {
        guard let account else { SecItemDelete(key as CFDictionary); return }
        let fields: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(key as CFDictionary, fields as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(key.merging(fields, uniquingKeysWith: { _, new in new }) as CFDictionary, nil) == errSecSuccess else { throw RelayFailure(message: "Could not save the login in Keychain.") }
        } else if result != errSecSuccess { throw RelayFailure(message: "Could not save the login in Keychain.") }
    }
}
#if os(iOS)
@MainActor final class DotLogin: ObservableObject {
    // Opening the app for a Watch wake must not launch a sign-in page/web process.
    lazy var webView: WKWebView = {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        return view
    }()
    func connect(thread: String) async throws -> DotAccount {
        let thread = try DotPage.identifier(from: thread)
        let script = """
        if (location.origin !== 'https://chatgpt.com') throw new Error('Open ChatGPT first.');
        const a = await (await fetch('/api/auth/session', {credentials:'include'})).json();
        if (!a.accessToken || !a.account?.id) throw new Error('Sign in to ChatGPT first.');
        const r = await fetch('/backend-api/tbo?limit=25&include_room_preview=false', {headers:{Authorization:'Bearer '+a.accessToken,'ChatGPT-Account-Id':a.account.id,'x-openai-web-frontend':'codex_webview'}});
        if (!r.ok) throw new Error('Could not load your Dot.');
        const dots = await r.json(); const dot = dots.items?.find(x=>x.active_root_thread_id===thread);
        if (!dot) throw new Error('That Dot is not in this signed-in account.');
        const cookie = document.cookie.split('; ').find(x=>x.startsWith('oai-did='));
        return {token:a.accessToken,accountID:a.account.id,dotID:dot.id,threadID:thread,name:dot.display_name,deviceID:cookie?decodeURIComponent(cookie.slice(8)):null};
        """
        let value = try await webView.callAsyncJavaScript(script, arguments: ["thread": thread], in: nil, contentWorld: .page)
        guard let value else { throw RelayFailure(message: "No login was returned.") }
        let account = try JSONDecoder().decode(DotAccount.self, from: JSONSerialization.data(withJSONObject: value))
        guard account.dotID.range(of: "^[a-zA-Z0-9_~.-]{1,200}$", options: .regularExpression) != nil else { throw RelayFailure(message: "Invalid Dot identifier.") }
        try AccountVault.save(account); try await SessionCookies.capture(); return account
    }
}
#endif
protocol DotTransport: AnyObject {
    var account: DotAccount { get set }
    func request(action: String, callID: String?, sdp: String?) async throws -> (Data, HTTPURLResponse)
}
extension DotTransport {
    func request(action: String, callID: String? = nil, sdp: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try await request(action: action, callID: callID, sdp: sdp)
    }
}
final class DotHTTP: NSObject, DotTransport, URLSessionTaskDelegate {
    var account: DotAccount
    // A per-call ephemeral session keeps authentication out of shared URL storage.
    private let metrics = CallHTTPMetrics()
    lazy var session = URLSession(configuration: .ephemeral, delegate: metrics, delegateQueue: nil)
    init(_ account: DotAccount) { self.account = account }
    func request(action: String, callID: String? = nil, sdp: String? = nil) async throws -> (Data, HTTPURLResponse) {
        account = try await DotSession.valid(account)
        do { return try await send(action: action, callID: callID, sdp: sdp, retry: true) }
        catch let error as URLError where action == "stop" && error.code == .networkConnectionLost {
            // Retrying a stop for the same ID cannot allocate another cloud call.
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await send(action: action, callID: callID, sdp: sdp, retry: true)
        }
    }
    private func send(action: String, callID: String?, sdp: String?, retry: Bool) async throws -> (Data, HTTPURLResponse) {
        guard ["create", "attach", "stop"].contains(action) else { throw RelayFailure(message: "Invalid call action.") }
        var path = "/backend-api/tbo/\(account.dotID)/voice/calls"
        if action != "create" {
            guard let callID, callID.range(of: "^rtc_[a-zA-Z0-9_-]{1,150}$", options: .regularExpression) != nil else { throw RelayFailure(message: "Invalid call identifier.") }
            path += "/\(callID)/\(action)"
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com" + path)!); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
        request.setValue(account.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex_webview", forHTTPHeaderField: "x-openai-web-frontend")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let deviceID = account.deviceID { request.setValue(deviceID, forHTTPHeaderField: "OAI-Device-Id") }
        if let sdp { request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": sdp]) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RelayFailure(message: "Invalid ChatGPT response.") }
        if response.statusCode == 401 && retry {
            account = try await DotSession.valid(account, force: true)
            return try await send(action: action, callID: callID, sdp: sdp, retry: false)
        }
        if !(200..<300).contains(response.statusCode) {
            CallTrace.record("Dot HTTP \(action): \(response.statusCode)")
            if action == "stop", [404,410].contains(response.statusCode) { return (data,response) }
            if [401,403].contains(response.statusCode) { throw RelayFailure(message: "Refresh your ChatGPT login in Dot Watch on iPhone.") }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Keep short server conflict explanations, excluding any auth/media payload.
            if response.statusCode == 409,
               let reason = object?["detail"] as? String, reason.count <= 240,
               reason.range(of:"token|authorization|sdp|cookie|bearer|eyJ|rtc_", options:[.regularExpression,.caseInsensitive]) == nil {
                CallTrace.record("Dot conflict: \(reason)")
            }
            let detail = object?["detail"] as? [String: Any], problem = object?["error"] as? [String: Any]
            let code = (detail?["code"] ?? problem?["code"]) as? String
            let safeCode = code.flatMap { $0.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) == nil ? nil : $0 }
            let suffix = safeCode.map { " \($0)" } ?? ""
            throw RelayFailure(message: "Dot rejected \(action) (HTTP \(response.statusCode)\(suffix)).")
        }
        return (data,response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// Only durations and a fixed operation name are logged; never URLs, IDs, or headers.
private final class CallHTTPMetrics: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let tail = task.originalRequest?.url?.lastPathComponent ?? ""
        let operation = tail == "calls" ? "create" : (["attach", "stop"].contains(tail) ? tail : "request")
        guard let tx = metrics.transactionMetrics.last else { return }
        func seconds(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "n/a" }
            return String(format: "%.2f", end.timeIntervalSince(start))
        }
        CallTrace.record("HTTP \(operation): total \(String(format: "%.2f", metrics.taskInterval.duration))s; DNS \(seconds(tx.domainLookupStartDate, tx.domainLookupEndDate))s; connect \(seconds(tx.connectStartDate, tx.connectEndDate))s; TLS \(seconds(tx.secureConnectionStartDate, tx.secureConnectionEndDate))s; response wait \(seconds(tx.requestEndDate, tx.responseStartDate))s; reused \(tx.isReusedConnection)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
