import Foundation

// Event names and system errors only: never tokens, SDP, cookies, or audio contents.
enum CallTrace {
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    private static let lock = NSLock()
    static func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        var events = UserDefaults.standard.stringArray(forKey: "DotWatch.callTrace") ?? []
        let event = "\(ISO8601DateFormatter().string(from: Date())) \(message.prefix(400))"
        events.append(event)
        UserDefaults.standard.set(Array(events.suffix(120)), forKey: "DotWatch.callTrace")
        NSLog("Dot Watch trace: %@", event)
    }
}
