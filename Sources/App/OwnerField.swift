import SwiftUI

/// Where a repository owner is typed for a profile, and under it the owners offered for what is typed so
/// far: those this Mac's repositories have, then those the search finds once the typing pauses. A click
/// on one claims it, as do Return and the check for what is typed.
struct OwnerField: View {
    let profile: String
    let leave: () -> Void
    @Environment(Running.self) private var running
    @State private var text = ""
    @State private var here: [String] = []
    @State private var found: [String] = []
    @FocusState private var typing: Bool

    private var offered: [(owner: String, here: Bool)] {
        let near = here.filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }
        let far = found.filter { name in !near.contains { $0.lowercased() == name.lowercased() } }
        return Array((near.map { ($0, true) } + far.map { ($0, false) }).prefix(6))
    }

    private var typed: String { text.trimmingCharacters(in: .whitespaces) }

    private func claim(_ owner: String) {
        if !owner.isEmpty { running.claim(owner: owner, for: profile) }
        leave()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                OwnerMark().foregroundStyle(.secondary)
                TextField("Repository owner", text: $text)
                    .textFieldStyle(.plain).font(.caption).focused($typing)
                    .onAppear {
                        typing = true
                        here = running.ownersHere()
                    }
                    .onSubmit { claim(typed) }
                    .onExitCommand(perform: leave)
                Confirm(undoable: true, ready: !typed.isEmpty, act: { claim(typed) }, back: leave)
            }
            .padding(.bottom, 2)
            ForEach(offered, id: \.owner) { offer in
                Button { claim(offer.owner) } label: {
                    HStack {
                        Text(offer.owner).lineLimit(1)
                        Spacer()
                        Text(offer.here ? "on this Mac" : "GitHub").foregroundStyle(.tertiary)
                    }
                    .font(.caption).padding(.leading, 17).padding(.vertical, 2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // Asked once the typing has paused, so that a name is one search and not one a letter.
        .task(id: text) {
            guard text.count > 1, (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
            let found = await running.owners(like: text)
            if !Task.isCancelled { self.found = found }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in leave() }
    }
}
