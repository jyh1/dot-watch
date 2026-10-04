import SwiftUI

enum AppBrand {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "DotAppName") as? String ?? "Dot" }
    static var defaultAgentPage: String { Bundle.main.object(forInfoDictionaryKey: "DotDefaultAgentPage") as? String ?? "" }
    static var siriHint: String { "Say ‘Siri, call \(name)’ on your iPhone or Apple Watch." }
    static var accent: Color {
        let hex = Bundle.main.object(forInfoDictionaryKey: "DotAccentHex") as? String ?? "45D6E8"
        let value = UInt32(hex, radix: 16) ?? 0x45D6E8
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }
}
