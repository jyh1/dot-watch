import Foundation
import Security
#if os(iOS)
import WebKit
#endif

// Refresh only this app's own ChatGPT session. No Google-app or Safari cookie access.
struct SessionCookie: Codable {
    let name: String, value: String, domain: String, path: String
    let expires: Date?
    init(_ cookie: HTTPCookie) { name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path; expires = cookie.expiresDate }
    var cookie: HTTPCookie? {
        guard domain == "chatgpt.com" || domain == ".chatgpt.com", path.hasPrefix("/") else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name:name,.value:value,.domain:domain,.path:path,.secure:"TRUE"]
        if let expires { guard expires > Date() else { return nil }; properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}
enum SessionCookies {
    private static var key: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:AccountVault.service + ".cookies",kSecAttrAccount as String:"chatgpt"] }
    static func load() -> [HTTPCookie] {
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data, let cookies = try? JSONDecoder().decode([SessionCookie].self, from: data) else { return [] }
        return cookies.compactMap(\.cookie)
    }
    static func save(_ cookies: [HTTPCookie]?) throws {
        guard let cookies else { SecItemDelete(key as CFDictionary); return }
        let filtered = cookies.filter { ($0.domain == "chatgpt.com" || $0.domain == ".chatgpt.com") && $0.isSecure }
        guard !filtered.isEmpty else { return }
        let fields: [String: Any] = [kSecValueData as String:try JSONEncoder().encode(filtered.map(SessionCookie.init)),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(key as CFDictionary,fields as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(key.merging(fields,uniquingKeysWith:{_,new in new}) as CFDictionary,nil) == errSecSuccess else { throw RelayFailure(message:"Could not save the ChatGPT session.") }
        } else if result != errSecSuccess { throw RelayFailure(message:"Could not save the ChatGPT session.") }
    }
    #if os(iOS)
    @MainActor static func capture() async throws {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        try save(cookies)
    }
    #endif
}
@MainActor enum DotSession {
    private static var renewal: (accountID: String, dotID: String, task: Task<DotAccount, Error>)?
    static func valid(_ account: DotAccount, force: Bool = false) async throws -> DotAccount {
        let cached = AccountVault.load()
        let current = cached?.accountID == account.accountID && cached?.dotID == account.dotID ? cached! : account
        if !force && !current.tokenExpired { return current }
        if let renewal {
            guard renewal.accountID == current.accountID, renewal.dotID == current.dotID else {
                throw RelayFailure(message: "The connected Dot changed. Try again after login finishes.")
            }
            return try await renewal.task.value
        }
        let task = Task { try await refresh(current) }
        renewal = (current.accountID, current.dotID, task)
        defer { renewal = nil }
        return try await task.value
    }
    private static func refresh(_ account: DotAccount) async throws -> DotAccount {
        var cookies = SessionCookies.load()
        #if os(iOS)
        if cookies.isEmpty { try await SessionCookies.capture(); cookies = SessionCookies.load() }
        #endif
        guard !cookies.isEmpty else { throw RelayFailure(message:"Open Dot on iPhone and refresh the ChatGPT login.") }
        let url = URL(string:"https://chatgpt.com/api/auth/session")!
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage?.setCookies(cookies,for:url,mainDocumentURL:url)
        let delegate = NoAuthRedirect()
        let session = URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url:url); request.timeoutInterval = 15
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response) = try await session.data(for:request)
        guard let response = response as? HTTPURLResponse else { throw RelayFailure(message: "ChatGPT returned an invalid session response.") }
        let next = try refreshedAccount(data: data, response: response, original: account)
        try validateRefreshDestination(original: account, current: AccountVault.load())
        try AccountVault.save(next)
        try SessionCookies.save(config.httpCookieStorage?.cookies ?? cookies)
        return next
    }
    static func validateRefreshDestination(original: DotAccount, current: DotAccount?) throws {
        guard let current, current.accountID == original.accountID,
              current.dotID == original.dotID, current.token == original.token else {
            throw RelayFailure(message: "The saved login changed during refresh. Try again with the current Dot.")
        }
    }
    // Validate before persisting: a login change must never silently switch the agent's account.
    static func refreshedAccount(data: Data, response: HTTPURLResponse, original account: DotAccount) throws -> DotAccount {
        guard response.statusCode == 200,
              let auth = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let token = auth["accessToken"] as? String, !token.isEmpty,
              let info = auth["account"] as? [String:Any], info["id"] as? String == account.accountID else {
            throw RelayFailure(message:"ChatGPT's saved session expired. Refresh login in Dot on iPhone.")
        }
        let next = DotAccount(token:token,accountID:account.accountID,dotID:account.dotID,threadID:account.threadID,name:account.name,deviceID:account.deviceID)
        guard !next.tokenExpired else { throw RelayFailure(message: "ChatGPT's saved session expired. Refresh login in Dot on iPhone.") }
        return next
    }

}
private final class NoAuthRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
