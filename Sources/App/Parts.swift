import SluiceCore
import SwiftUI

extension View {
    /// What a profile's accounts, and each part of the view of use, sit on.
    func card(_ fill: Color = Color.primary.opacity(0.06)) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(10).background(fill, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The outline of a place an account can be let go, while one is carried.
    func outlined(_ shown: Bool) -> some View {
        overlay { if shown { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
    }
}

/// What floats beside the pointer, which is at `at` in the panel's space.
struct Tip {
    let at: CGPoint
    let view: AnyView
}

/// The tip of the view the pointer is on, for the panel to float.
struct Tips: PreferenceKey {
    static var defaultValue: Tip? { nil }
    static func reduce(value: inout Tip?, nextValue: () -> Tip?) { value = nextValue() ?? value }
}

private struct Tipped<Said: View>: ViewModifier {
    let washed: Bool
    let said: () -> Said
    @State private var at: CGPoint?

    func body(content: Content) -> some View {
        content
            .overlay { if washed, at != nil { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)) } }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(Frames.space)) { if case .active(let point) = $0 { at = point } else { at = nil } }
            .preference(key: Tips.self, value: at.map { Tip(at: $0, view: AnyView(VStack(alignment: .leading, spacing: 3) { said() })) })
    }
}

extension View {
    /// Says more beside the pointer for as long as the pointer is on this view, which is washed meanwhile
    /// unless it has a shape of its own to keep.
    func tip<Said: View>(washed: Bool = true, @ViewBuilder _ said: @escaping () -> Said) -> some View { modifier(Tipped(washed: washed, said: said)) }
}

/// What a tip reads: what it is about, then its figure and what the figure is.
struct Readout: View {
    let about: String
    let figure: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !about.isEmpty { Text(about).font(.caption2).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(figure).font(.callout.weight(.semibold).monospacedDigit())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The pace that uses a pool up in a week, as a line across what it is laid over.
struct Pace: View {
    private struct Level: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }

    var body: some View { Level().stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1) }
}

/// A profile's color as a dot, grey for a profile without one.
struct Dot: View {
    let tint: Tint?
    var size = 7.0

    var body: some View { Circle().fill(tint?.color ?? Color.secondary.opacity(0.4)).frame(width: size, height: size) }
}

/// A provider's mark and what its subscriptions are sold as, at the head of a pool.
struct PoolTitle: View {
    let provider: String
    let title: String

    var body: some View {
        if let mark = providerMark(provider) {
            Image(nsImage: mark).resizable().frame(width: 13, height: 13).foregroundStyle(.secondary)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
        }
        Text(title).font(.callout.weight(.semibold))
    }
}

/// Motion in the panel is brief and says that something changed. None of it moves the layout, and a
/// person who asked the system for less motion gets none.
private struct Moves<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View { content.animation(still ? nil : animation, value: value) }
}

/// A line that comes into a row fades in where it is. The row's height is not animated: the window
/// around a menu bar panel resizes in one step, and a height that eased would race it.
private struct FadesIn: ViewModifier {
    let on: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content.opacity(shown || still || !on ? 1 : 0).onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
    }
}

extension View {
    /// Animates with a change of `value`.
    func moves<Value: Equatable>(_ animation: Animation, with value: Value) -> some View { modifier(Moves(animation: animation, value: value)) }

    func fadesIn(_ on: Bool = true) -> some View { modifier(FadesIn(on: on)) }
}

/// The one action in the panel that waits for its check or its cross, by a name of its own. Naming
/// another, a click on nothing, and the panel closing all let it go.
private struct ArmedKey: EnvironmentKey {
    static let defaultValue: Binding<String?> = .constant(nil)
}

extension EnvironmentValues {
    var armed: Binding<String?> {
        get { self[ArmedKey.self] }
        set { self[ArmedKey.self] = newValue }
    }
}

/// The cross and the check an action shows where it is once clicked, in place of a dialog. The check does
/// it and the cross backs out. The check is red where what it does cannot be undone. The cross comes
/// first, so that a second click where the first one landed backs out. Either lets the action go.
struct Confirm: View {
    var undoable = false
    var ready = true
    let act: () -> Void
    var back: () -> Void = {}
    @Environment(\.armed) private var armed

    var body: some View {
        HStack(spacing: 4) {
            Button { armed.wrappedValue = nil; back() } label: { mark("xmark", ink: .secondary, on: Color.primary.opacity(0.12)) }.help("Leave it")
            Button { armed.wrappedValue = nil; act() } label: { mark("checkmark", ink: .white, on: undoable ? Color.accentColor : .red) }
                .disabled(!ready).opacity(ready ? 1 : 0.4).help(undoable ? "Keep it" : "Do it. This cannot be undone")
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func mark(_ symbol: String, ink: Color, on fill: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(ink).frame(width: 14, height: 14).background(fill, in: Circle())
    }
}

extension Menu {
    /// A menu that is only its symbol.
    @MainActor func bare() -> some View { menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize() }
}

/// Lays its views out in rows, starting a new one when the next does not fit.
struct Flow: Layout {
    private let gap = 4.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, place(subviews, in: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    /// Its text sits where its first item's does, whatever else is on the line.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        subviews.first.map { bounds.minY + $0.dimensions(in: .unspecified)[guide] }
    }

    private func place(_ subviews: Subviews, in width: Double) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x = 0.0, y = 0.0, row = 0.0, widest = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + gap
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + gap
            row = max(row, size.height)
            widest = max(widest, x - gap)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

extension Tint {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// A share of an allowance, read as used or as left. A click on any of them turns them all.
struct Share: View {
    let used: Double
    /// Says which it is, where the number alone would not.
    var worded = false
    @AppStorage(Share.key) private var left = false

    /// Where it is kept which way the shares read.
    static let key = "readsLeft"

    static func text(_ used: Double, left: Bool) -> String { "\(Int(((left ? 1 - min(used, 1) : used) * 100).rounded()))%" }

    /// The colour that warns of a share nearly or wholly gone; nil while there is room.
    static func warning(_ used: Double) -> Color? { StatusLine.alarm(used).map { $0 == .critical ? .red : .orange } }

    var body: some View {
        let text = Self.text(used, left: left) + (worded ? (left ? " left" : " used") : "")
        Text(text)
            .font(.caption.monospacedDigit())
            .contentTransition(.numericText())
            .moves(.smooth(duration: 0.3), with: text)
            .foregroundStyle(Self.warning(used) ?? (worded ? .secondary : .primary))
            .contentShape(Rectangle())
            .onTapGesture { left.toggle() }
            .help(left ? "Left. Click for used" : "Used. Click for left")
    }
}

/// A time to come, read as the time left or as the time itself. A click on any of them turns them all.
struct Clock: View {
    let at: Date
    let now: Date
    @AppStorage("readsResetTimes") private var times = false

    var body: some View {
        let text = times ? at.timeText : at.leftText(now: now)
        Text(text)
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            .contentTransition(.numericText())
            .moves(.smooth(duration: 0.3), with: text)
            .contentShape(Rectangle())
            .onTapGesture { times.toggle() }
            .help(times ? "Resets then. Click for the time left" : "Resets in this long. Click for the time")
    }
}
