import Foundation

enum DotPage {
    static func identifier(from input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: text) != nil { return text }
        if let url = URL(string: text), url.scheme == "https", url.host == "chatgpt.com",
           url.user == nil, url.password == nil, url.port == nil,
           url.query == nil, url.fragment == nil {
            let parts = url.path.split(separator: "/")
            if parts.count == 2, parts[0] == "dots", UUID(uuidString: String(parts[1])) != nil {
                return String(parts[1])
            }
        }
        throw RelayFailure(message: "Paste your https://chatgpt.com/dots/… page URL or its ID.")
    }
}
