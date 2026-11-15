import AppKit
import SluiceCore
import SluiceProviders
import SwiftUI

extension StatusLine.Pool {
    /// One profile's pool as it stands, with what its last day of readings says of today and of how long it lasts.
    init(_ accounts: [AccountStatus], profile: String, config: Config, samples: [Sample], now: Date) {
        let total = accounts.map(\.size).reduce(0, +), today = Calendar.current.startOfDay(for: now)
        let burn = accounts.burn(samples, now: now)
        self.init(
            profile: config.shown(profile), tint: config.profiles[profile]?.color, used: accounts.used,
            resetsAt: accounts.compactMap(\.budget?.resetsAt).min(),
            dry: burn.flatMap { Forecast.dry(accounts.map { Member(size: $0.size, used: $0.budget?.used ?? 0, resetsAt: $0.budget?.resetsAt) }, burn: $0, now: now) },
            account: accounts.filter { $0.lastAnswered != nil }.max { $0.lastAnswered! < $1.lastAnswered! }?.label,
            today: total > 0 ? accounts.map { account in
                Forecast.rises(samples.filter { $0.provider == account.provider && $0.account == account.label }).filter { $0.at >= today }.map(\.by).reduce(0, +) * account.size / total
            }.reduce(0, +) : nil
        )
    }
}

private extension Tint {
    /// Its colour among a terminal's 256.
    var terminal: Int {
        switch self {
        case .red: 196
        case .orange: 208
        case .yellow: 220
        case .green: 41
        case .teal: 37
        case .blue: 33
        case .purple: 135
        case .pink: 205
        }
    }
}

private extension StatusLine.Tone {
    var terminal: Int? {
        switch self {
        case .plain: nil
        case .dim: 245
        case .faint: 238
        case .fill: 33
        case .warning: 208
        case .critical: 196
        case .tint(let tint): tint?.terminal ?? 245
        }
    }

    var color: Color {
        switch self {
        case .plain: .primary
        case .dim: .secondary
        case .faint: Color.primary.opacity(0.25)
        case .fill: .blue
        case .warning: .orange
        case .critical: .red
        case .tint(let tint): tint?.color ?? .secondary
        }
    }
}

/// The line as a terminal shows it, its items two spaces apart.
func terminalText(_ line: [[StatusLine.Run]]) -> String {
    line.map { $0.map { run in run.tone.terminal.map { "\u{1B}[38;5;\($0)m\(run.text)\u{1B}[0m" } ?? run.text }.joined() }.joined(separator: "  ")
}

/// The status line being put together: every item it could say, with whether it does, in order.
@Observable private final class LineDraft {
    var rows: [(item: StatusLine.Item, said: Bool)]

    init(_ items: [StatusLine.Item]) {
        rows = items.map { ($0, true) } + StatusLine.Item.allCases.filter { !items.contains($0) }.map { ($0, false) }
    }

    var items: [StatusLine.Item] { rows.filter(\.said).map(\.item) }
}

private extension StatusLine.Item {
    var about: (title: String, says: String) {
        switch self {
        case .profile: ("Profile", "its name and color")
        case .bar: ("Bar", "the pool's share as a bar")
        case .share: ("Share", "how much of the pool is used")
        case .reset: ("Reset", "until any of it comes back")
        case .dry: ("Dry", "when it runs out, if it would")
        case .account: ("Account", "the one that answered last")
        case .today: ("Today", "today's use against the pace")
        }
    }
}

/// The line as it would read, over the items: each is ticked to be said and dragged to where it is said.
private struct LineEditor: View {
    @Bindable var draft: LineDraft
    let now: Date

    var body: some View {
        // A pool that has something to say for every item.
        let pool = StatusLine.Pool(profile: "work", tint: .purple, used: 0.87, resetsAt: now + 28 * 3600, dry: now + 19 * 3600, account: "ada@work.example", today: 0.09)
        VStack(alignment: .leading, spacing: 8) {
            StatusLine.runs(draft.items, of: pool, now: now).enumerated().reduce(Text("")) { line, item in
                item.element.reduce(line + Text(item.offset > 0 ? "  " : "")) { $0 + Text($1.text).foregroundColor($1.tone.color) }
            }
            .font(.system(size: 11, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(8).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 6))
            .environment(\.colorScheme, .dark)
            List {
                ForEach($draft.rows, id: \.item) { $row in
                    HStack(spacing: 8) {
                        Toggle(isOn: $row.said) { Text(row.item.about.title) }
                        Text(row.item.about.says).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .onMove { draft.rows.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
        }
        .frame(width: 340, height: 236)
    }
}

/// Asks what the status line says; nil when the person thinks better of it.
@MainActor func askForStatusLine(_ items: [StatusLine.Item]) -> [StatusLine.Item]? {
    let draft = LineDraft(items), clients = providers.compactMap { $0 as? any StatusShowing }.map(\.client)
    let alert = NSAlert()
    alert.messageText = "Status line"
    alert.informativeText = "What \(clients.formatted(.list(type: .and))) shows under its prompt of the pool that pays for the work. Drag an item to where it is said."
    alert.accessoryView = NSHostingView(rootView: LineEditor(draft: draft, now: Date()))
    alert.accessoryView?.frame.size = NSSize(width: 340, height: 236)
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    NSApplication.shared.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn ? draft.items : nil
}
