import AppKit
import SwiftUI

/// What is typed in the dialog that asks for an owner, and what was found for it.
@MainActor @Observable private final class OwnerSearch {
    var text = ""
    var found: [String] = []
}

/// The field an owner is typed in, and under it the owners offered for what is typed so far: those this
/// Mac's repositories have, then those the search finds once the typing pauses. A click on one types it.
private struct OwnerPicker: View {
    @Bindable var search: OwnerSearch
    let known: [String]
    let find: (String) async -> [String]
    @FocusState private var typing: Bool

    private var offered: [(owner: String, here: Bool)] {
        let near = known.filter { search.text.isEmpty || $0.localizedCaseInsensitiveContains(search.text) }
        let far = search.found.filter { name in !near.contains { $0.lowercased() == name.lowercased() } }
        return Array((near.map { ($0, true) } + far.map { ($0, false) }).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Owner", text: $search.text).textFieldStyle(.roundedBorder).focused($typing).onAppear { typing = true }
            VStack(spacing: 0) {
                ForEach(offered, id: \.owner) { offer in
                    Button { search.text = offer.owner } label: {
                        HStack {
                            if let mark = githubMark() { Image(nsImage: mark).foregroundStyle(.secondary) }
                            Text(offer.owner).lineLimit(1)
                            Spacer()
                            Text(offer.here ? "on this Mac" : "GitHub").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(offer.owner == search.text ? 0.2 : 0), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 280, height: 190, alignment: .top)
        // Asked once the typing has paused, so that a name is one search and not one a letter.
        .task(id: search.text) {
            guard search.text.count > 1, (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
            let found = await find(search.text)
            if !Task.isCancelled { search.found = found }
        }
    }
}

/// Asks which owner's repositories are `profile`'s; nil when the person thinks better of it.
@MainActor func askForOwner(of profile: String, known: [String], find: @escaping (String) async -> [String]) -> String? {
    let search = OwnerSearch()
    let alert = NSAlert()
    alert.messageText = "Add a repository owner to \(profile)"
    alert.informativeText = "Work in a repository whose origin is this owner's belongs to the profile."
    alert.accessoryView = NSHostingView(rootView: OwnerPicker(search: search, known: known, find: find))
    alert.accessoryView?.frame.size = NSSize(width: 280, height: 190)
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let owner = search.text.trimmingCharacters(in: .whitespaces)
    return owner.isEmpty ? nil : owner
}
