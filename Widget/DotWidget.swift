import SwiftUI
import WidgetKit
import ImageIO

struct DotEntry: TimelineEntry { let date: Date }
struct DotProvider: TimelineProvider {
    func placeholder(in context: Context) -> DotEntry { DotEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DotEntry) -> Void) {
        completion(DotEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DotEntry>) -> Void) {
        completion(Timeline(entries: [DotEntry(date: .now)], policy: .never))
    }
}

struct DotWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    // WidgetKit archives the bitmap at its original size, even for a 48pt view.
    // Decode a small thumbnail so the mascot stays within watch widget limits.
    private static let icon: CGImage? = {
        guard let url = Bundle.main.url(forResource: "Dot", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary)
    }()
    private let gold = AppBrand.accent
    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "phone.fill").font(.title2).widgetAccentable()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Call \(AppBrand.name)")
                .accessibilityHint("Opens \(AppBrand.name) and starts a call on this Watch.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if renderingMode == .fullColor, let icon = Self.icon {
                            Image(decorative: icon, scale: 2).resizable().scaledToFit()
                                .scaleEffect(1.6).frame(width: 20, height: 20).clipped()
                                .accessibilityHidden(true)
                        }
                        Text(AppBrand.name).font(.headline).widgetAccentable()
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        actionLink("Call", symbol: "phone.fill", destination: CallRoute.url)
                        actionLink("Speak", symbol: "mic.fill", destination: CallRoute.speakURL)
                    }
                }

            }
        }
        .containerBackground(for: .widget) { Color(red: 0.10, green: 0.10, blue: 0.08) }
        .widgetURL(CallRoute.url)
    }
    private func actionLink(_ title: String, symbol: String, destination: URL) -> some View {
        Link(destination: destination) {
            Label(title, systemImage: symbol).font(.caption.bold())
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(renderingMode == .fullColor ? gold : .primary)
        .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(title) \(AppBrand.name)")
        .accessibilityHint(title == "Call" ? "Starts a call after the app opens." : "Opens the voice-message recording screen.")
    }
}

@main struct DotCallWidget: Widget {
    let kind = Bundle.main.object(forInfoDictionaryKey: "DotWidgetKind") as? String ?? "DotCall"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DotProvider()) { _ in DotWidgetView() }
            .configurationDisplayName("Call or Speak")
            .description("Call your Dot or open a voice message from the Smart Stack. Circular complications start a call.")
            .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}
