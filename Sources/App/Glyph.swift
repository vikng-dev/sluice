import AppKit

/// The menu bar glyph: the app icon's tile as an outline (Assets/AppIcon.svg), in a 760-unit square.
/// It holds a wave of water while clients are routed, and a low still line when not.
func poolGlyph(routed: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let fit = NSAffineTransform()
        fit.scale(by: 18.0 / 760)
        fit.translateX(by: -132, yBy: -132)
        fit.concat()
        NSColor.black.set()
        let tile = NSBezierPath(roundedRect: NSRect(x: 176, y: 176, width: 672, height: 672), xRadius: 170, yRadius: 170)
        tile.lineWidth = 72
        tile.stroke()
        if routed {
            NSBezierPath(roundedRect: NSRect(x: 200, y: 200, width: 624, height: 624), xRadius: 140, yRadius: 140).addClip()
            let water = NSBezierPath()
            water.move(to: NSPoint(x: 176, y: 520))
            water.curve(to: NSPoint(x: 512, y: 520), controlPoint1: NSPoint(x: 288, y: 450), controlPoint2: NSPoint(x: 400, y: 590))
            water.curve(to: NSPoint(x: 848, y: 520), controlPoint1: NSPoint(x: 624, y: 450), controlPoint2: NSPoint(x: 736, y: 590))
            water.line(to: NSPoint(x: 848, y: 848))
            water.line(to: NSPoint(x: 176, y: 848))
            water.fill()
        } else {
            let still = NSBezierPath()
            still.move(to: NSPoint(x: 350, y: 670))
            still.line(to: NSPoint(x: 674, y: 670))
            still.lineWidth = 68
            still.lineCapStyle = .round
            still.stroke()
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// The starred pools in the menu bar by profile: a short bar in the profile's colour, then each pool as
/// the provider's mark and its share, a profile's pools close together and the profiles apart.
@MainActor func counterGlyph(_ profiles: [(color: NSColor?, pools: [(provider: String, text: String)])]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let (side, gap, between, apart, height) = (12.0, 2.0, 6.0, 12.0, 18.0)
    /// What to draw and where, worked out here so that the drawing itself touches no state.
    var marks: [(image: NSImage, at: NSRect)] = [], texts: [(text: String, at: NSPoint)] = []
    var bars: [(color: NSColor?, at: NSRect)] = [], x = 0.0
    for (index, profile) in profiles.enumerated() {
        if index > 0 { x += apart - between }
        bars.append((profile.color, NSRect(x: x, y: 2, width: 2.5, height: height - 4)))
        x += 6
        for pool in profile.pools {
            if let mark = providerMark(pool.provider) {
                marks.append((mark, NSRect(x: x, y: (height - side) / 2, width: side, height: side)))
                x += side + gap
            }
            let size = NSAttributedString(string: pool.text, attributes: [.font: font]).size()
            texts.append((pool.text, NSPoint(x: x, y: (height - size.height) / 2)))
            x += size.width.rounded(.up) + between
        }
    }
    // It has colours of its own, so the bar does not colour it: it is drawn in black or white for the bar it
    // is on, which is asked at each drawing.
    return NSImage(size: NSSize(width: max(x - between, 1), height: height), flipped: false) { whole in
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        for mark in marks { mark.image.draw(in: mark.at) }
        ink.setFill()
        whole.fill(using: .sourceAtop)
        for text in texts { NSAttributedString(string: text.text, attributes: [.font: font, .foregroundColor: ink]).draw(at: text.at) }
        for bar in bars {
            // A profile without a colour has the grey its dot has in the panel.
            (bar.color ?? ink.withAlphaComponent(0.35)).setFill()
            NSBezierPath(roundedRect: bar.at, xRadius: 1.25, yRadius: 1.25).fill()
        }
        return true
    }
}

/// A provider's mark. The drawings are in Assets/providers, named by provider; a provider without one is
/// shown by name.
@MainActor func providerMark(_ provider: String) -> NSImage? { mark("providers/\(provider)") }

/// GitHub's mark, which stands for a repository's owner.
@MainActor func githubMark() -> NSImage? { mark("github") }

/// A drawing among the app's resources, drawn in the text colour.
@MainActor private func mark(_ path: String) -> NSImage? {
    if let known = marks[path] { return known }
    guard let url = Bundle.main.resourceURL?.appending(path: "\(path).svg"), let mark = NSImage(contentsOf: url) else { return nil }
    mark.isTemplate = true
    // A menu draws an image at its own size.
    mark.size = NSSize(width: 14, height: 14)
    marks[path] = mark
    return mark
}

@MainActor private var marks: [String: NSImage] = [:]
