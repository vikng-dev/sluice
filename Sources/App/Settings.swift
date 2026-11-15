import SluiceCore
import SluiceProviders
import SwiftUI

/// What the app does and says by itself, each changed where it is and holding at once.
struct SettingsView: View {
    let now: Date
    @Environment(Running.self) private var running

    var body: some View {
        let autoResets = running.config.autoResets
        VStack(alignment: .leading, spacing: 8) {
            LineCard(items: running.config.statusLine, now: now).card()
            VStack(alignment: .leading, spacing: 10) {
                Setting(symbol: "arrow.triangle.branch", title: "Route the clients", says: "Claude Code and Codex go through Sluice", on: running.routed, turn: running.route)
                Setting(symbol: autoResets ? "bolt.fill" : "bolt", title: "Use resets for me", says: "when a pool is out, or one is about to lapse", on: autoResets, turn: running.autoReset)
            }
            .card()
            HStack {
                Text("Sluice \(Sluice.version)")
                Spacer()
                Button("Quit", action: running.quit).buttonStyle(.plain)
            }
            .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10)
        }
    }
}

/// One thing the app does: its mark, what it is, and the switch that turns it on and off.
private struct Setting: View {
    let symbol: String
    let title: String
    let says: String
    let on: Bool
    let turn: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(says).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding { on } set: { turn($0) }).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

/// The clients' status line as it would read, over the items it says, in order, and those it could. A
/// click takes an item off or puts it on at the end; one that is said is dragged to where it is said.
private struct LineCard: View {
    let items: [StatusLine.Item]
    let now: Date
    @Environment(Running.self) private var running
    @State private var frames: [String: CGRect] = [:]
    @State private var dragged: (item: StatusLine.Item, by: CGSize)?

    private func chip(_ item: StatusLine.Item, said: Bool) -> some View {
        HStack(spacing: 4) {
            if said { Image(systemName: "line.3.horizontal").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
            Text(item.about.title).font(.caption)
            if !said { Image(systemName: "plus").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(said ? .primary : .secondary)
        .background(Color.primary.opacity(said ? 0.12 : 0), in: Capsule())
        .overlay { if !said { Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
        .contentShape(Capsule())
        .tip(washed: false) {
            Text(item.about.says).font(.caption)
            Text(said ? "Click to take it off, drag to move it" : "Click to add it").font(.caption2).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        // A pool that has something to say for every item.
        let pool = StatusLine.Pool(profile: "work", tint: .purple, used: 0.87, resetsAt: now + 28 * 3600, dry: now + 19 * 3600, account: "ada@work.example", today: 0.09)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Status line").font(.callout.weight(.semibold))
                Spacer()
                Text(providers.filter { $0 is any StatusShowing }.map(\.name).formatted(.list(type: .and))).font(.caption).foregroundStyle(.secondary)
                    .help("The clients that show it under their prompt, of the pool that pays for the work, before a line of your own")
            }
            StatusLine.runs(items, of: pool, now: now).enumerated().reduce(Text("")) { line, item in
                item.element.reduce(line + Text(item.offset > 0 ? StatusLine.separator : "").foregroundColor(.gray)) { $0 + Text($1.text).foregroundColor($1.tone.color) }
            }
            .font(.system(size: 11, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
            .padding(8).background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 6))
            .environment(\.colorScheme, .dark)
            Flow {
                ForEach(items, id: \.self) { item in
                    chip(item, said: true)
                        .framed("item:\(item.rawValue)")
                        .offset(dragged?.item == item ? dragged!.by : .zero).zIndex(dragged?.item == item ? 1 : 0)
                        .onTapGesture { running.say(items.filter { $0 != item }) }
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named(Frames.space))
                                .onChanged { dragged = (item, $0.translation) }
                                .onEnded { drop in
                                    dragged = nil
                                    // It lands after the items its middle has passed, row by row.
                                    guard let from = frames["item:\(item.rawValue)"] else { return }
                                    let middle = CGPoint(x: from.midX + drop.translation.width, y: from.midY + drop.translation.height)
                                    var moved = items.filter { $0 != item }
                                    let passed = moved.filter { other in
                                        guard let frame = frames["item:\(other.rawValue)"] else { return false }
                                        return frame.maxY < middle.y || (frame.minY <= middle.y && frame.midX < middle.x)
                                    }
                                    moved.insert(item, at: passed.count)
                                    if moved != items { running.say(moved) }
                                }
                        )
                }
            }
            Flow {
                ForEach(StatusLine.Item.allCases.filter { !items.contains($0) }, id: \.self) { item in
                    chip(item, said: false).onTapGesture { running.say(items + [item]) }
                }
            }
        }
        .moves(.snappy(duration: 0.2), with: items)
        .onPreferenceChange(Frames.self) { frames = $0 }
    }
}
