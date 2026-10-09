import Foundation

// One constant is compiled into both the widget and the containing app.
// The widget carries no account/session data and starts media only after a tap.
enum CallRoute {
    enum Action: String { case call, speak }
    static let scheme = Bundle.main.object(forInfoDictionaryKey: "DotURLScheme") as? String ?? "dotwatch"
    static let url = URL(string: "\(scheme)://call")!
    static let speakURL = URL(string: "\(scheme)://speak")!
    static func matches(_ url: URL) -> Bool {
        action(for: url) == .call
    }
    static func action(for url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              (url.path.isEmpty || url.path == "/"), url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        return Action(rawValue: host)
    }
}
