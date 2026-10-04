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
            } else {
                HStack(spacing: 9) {
                    if renderingMode == .fullColor, let icon = Self.icon {
                        Image(decorative: icon, scale: 2).resizable().scaledToFit()
                            .frame(width: 48, height: 48).accessibilityHidden(true)
                    } else {
                        Image(systemName: "phone.fill").font(.title2).widgetAccentable()
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppBrand.name).font(.headline).widgetAccentable()
                        Label("Call \(AppBrand.name)", systemImage: "phone.fill")
                            .font(.caption).foregroundStyle(renderingMode == .fullColor ? gold : .primary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.10, green: 0.10, blue: 0.08) }
        .widgetURL(CallRoute.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call \(AppBrand.name)")
        .accessibilityHint("Opens \(AppBrand.name) and starts a call on this Watch.")
    }
}

@main struct DotCallWidget: Widget {
    let kind = Bundle.main.object(forInfoDictionaryKey: "DotWidgetKind") as? String ?? "DotCall"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DotProvider()) { _ in DotWidgetView() }
            .configurationDisplayName("Call \(AppBrand.name)")
            .description("One tap to call your Dot from the Smart Stack or watch face.")
            .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}
