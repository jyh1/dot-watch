import Foundation
import CryptoKit

// Sent only across Apple's paired WatchConnectivity channel; never through the
// LAN relay or diagnostics. Each device saves its own protected Keychain copy.
struct WatchCredentials: Codable {
    let version: Int
    let account: DotAccount
    let cookies: [SessionCookie]
    static func export() throws -> Data? {
        guard let account = AccountVault.load() else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(WatchCredentials(version: 1, account: account, cookies: SessionCookies.load().map(SessionCookie.init)))
    }
    static func accept(_ data: Data) throws {
        guard data.count < 128_000 else { throw RelayFailure(message: "Invalid sign-in transfer.") }
        let digest = SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
        guard UserDefaults.standard.string(forKey: "DotWatch.credentialSyncDigest") != digest || AccountVault.load() == nil else { return }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.account.accountID.isEmpty,
              value.account.dotID.range(of: "^[a-zA-Z0-9_~.-]{1,200}$", options: .regularExpression) != nil else { throw RelayFailure(message: "Update both Dot apps before syncing sign-in.") }
        try SessionCookies.save(value.cookies.compactMap(\.cookie))
        try AccountVault.save(value.account)
        UserDefaults.standard.set(digest, forKey: "DotWatch.credentialSyncDigest")
    }
    static func clear() throws {
        try AccountVault.save(nil); try SessionCookies.save(nil)
        UserDefaults.standard.removeObject(forKey: "DotWatch.credentialSyncDigest")
    }
}
