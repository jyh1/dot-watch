import Foundation

// Event names and system errors only: never tokens, SDP, cookies, or audio contents.
enum CallTrace {
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    private static let lock = NSLock()
    // Watch forwarding has a 300-character limit. Split deterministically so a
    // growing metric set never silently loses counters at the end of a line.
    static func mediaStatistics(_ values: [String: Int]) -> [String] {
        let prefix = "Call media: "
        var lines: [String] = []
        var line = prefix
        for key in values.keys.sorted() {
            let item = "\(key)=\(values[key]!)"
            if line.count + item.count + 1 > 280, line != prefix {
                lines.append(line); line = prefix
            }
            line += (line == prefix ? "" : " ") + item
        }
        if line != prefix { lines.append(line) }
        return lines
    }
    static func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        var events = UserDefaults.standard.stringArray(forKey: "DotWatch.callTrace") ?? []
        let event = "\(ISO8601DateFormatter().string(from: Date())) \(message.prefix(400))"
        events.append(event)
        UserDefaults.standard.set(Array(events.suffix(120)), forKey: "DotWatch.callTrace")
        NSLog("Dot Watch trace: %@", event)
    }
}
