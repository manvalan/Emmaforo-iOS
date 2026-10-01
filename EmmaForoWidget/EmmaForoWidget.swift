import EmmaForoShared
import SwiftUI
import WidgetKit

private struct EmmaForoEntry: TimelineEntry {
    let date: Date
    let color: String
    let on: Bool
    let blink: Bool
}

private struct EmmaForoProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmmaForoEntry {
        EmmaForoEntry(date: .now, color: "", on: false, blink: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (EmmaForoEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EmmaForoEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> EmmaForoEntry {
        EmmaForoEntry(date: .now, color: LampSnapshot.color, on: LampSnapshot.isOn, blink: LampSnapshot.blink)
    }
}

private struct SignalDisc: View {
    let color: Color
    var filled: Bool
    var blinking: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            if filled && blinking {
                Circle().strokeBorder(color, lineWidth: size * 0.11)
                Circle().strokeBorder(color, lineWidth: size * 0.07)
                    .padding(size * 0.24)
            } else if filled {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct TrafficSignal: View {
    var entry: EmmaForoEntry

    private let disc: CGFloat = 28
    private let rim: CGFloat = 4
    private let corner: CGFloat = 12
    private let stroke: CGFloat = 2
    private let base: CGFloat = 15
    private var slotWidth: CGFloat { disc + rim * 2 }
    private var borderGap: CGFloat { rim - stroke }
    private let lights: [(id: String, color: Color, name: String)] = [
        ("rosso", Color(red: 0.92, green: 0.22, blue: 0.18), "Rosso"),
        ("giallo", Color(red: 0.96, green: 0.72, blue: 0.12), "Giallo"),
        ("verde", Color(red: 0.18, green: 0.72, blue: 0.34), "Verde")
    ]

    var body: some View {
        VStack(spacing: borderGap) {
            VStack(spacing: 4) {
                ForEach(lights, id: \.id) { light in
                    let active = entry.on && entry.color == light.id
                    Button(intent: LampIntent(color: light.id)) {
                        SignalDisc(color: light.color, filled: active, blinking: active && entry.blink, size: disc)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(light.name)
                }
            }
            .padding(rim)
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: stroke)
            }

            Button(intent: BlinkIntent()) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.black)
                    .frame(width: base, height: base)
                    .frame(width: slotWidth, height: base + 16, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lampeggio")
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct EmmaForoWidgetView: View {
    var entry: EmmaForoEntry

    var body: some View {
        TrafficSignal(entry: entry)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct EmmaForoWidget: Widget {
    let kind = "EmmaForoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EmmaForoProvider()) { entry in
            EmmaForoWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Emmaforo")
        .description("Semaforo")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
        .preferredBackgroundStyle(.transparent)
    }
}
