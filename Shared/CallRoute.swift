import Foundation

// One constant is compiled into both the widget and the containing app.
// The widget carries no account/session data and starts media only after a tap.
enum CallRoute {
    static let scheme = Bundle.main.object(forInfoDictionaryKey: "DotURLScheme") as? String ?? "dotwatch"
    static let url = URL(string: "\(scheme)://call")!
    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased() && url.host?.lowercased() == "call"
            && (url.path.isEmpty || url.path == "/") && url.query == nil
            && url.fragment == nil && url.user == nil && url.password == nil && url.port == nil
    }
}
