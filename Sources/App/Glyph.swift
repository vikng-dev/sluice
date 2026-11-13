import AppKit

/// The menu bar glyph: the gate of the app icon, in the icon's own coordinates (Assets/AppIcon.svg).
/// The blade is up with water running under it while clients are routed, and down on the sill when not.
func gateGlyph(open: Bool) -> NSImage {
    let scale = 18.0 / 624
    let image = NSImage(size: NSSize(width: 672 * scale, height: 18), flipped: true) { _ in
        let fit = NSAffineTransform()
        fit.scale(by: scale)
        fit.translateX(by: -176, yBy: -224)
        fit.concat()
        NSColor.black.withAlphaComponent(0.45).setFill()
        if open {
            let water = NSBezierPath()
            water.move(to: NSPoint(x: 336, y: 528))
            water.line(to: NSPoint(x: 688, y: 528))
            water.line(to: NSPoint(x: 688, y: 616))
            water.curve(to: NSPoint(x: 848, y: 848), controlPoint1: NSPoint(x: 688, y: 724), controlPoint2: NSPoint(x: 752, y: 780))
            water.line(to: NSPoint(x: 176, y: 848))
            water.curve(to: NSPoint(x: 336, y: 616), controlPoint1: NSPoint(x: 272, y: 780), controlPoint2: NSPoint(x: 336, y: 724))
            water.fill()
        } else {
            NSRect(x: 336, y: 552, width: 352, height: 40).fill()
        }
        NSColor.black.setFill()
        for x in [248.0, 688] { NSBezierPath(roundedRect: NSRect(x: x, y: 224, width: 88, height: 544), xRadius: 24, yRadius: 24).fill() }
        NSBezierPath(roundedRect: NSRect(x: 360, y: open ? 280 : 592, width: 304, height: 176), xRadius: 20, yRadius: 20).fill()
        return true
    }
    image.isTemplate = true
    return image
}

/// The starred profiles in the menu bar: each pool's provider mark and its share, a profile's pools
/// close together and the profiles apart.
@MainActor func counterGlyph(_ profiles: [[(provider: String, text: String)]]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let (side, gap, between, apart) = (12.0, 2.0, 6.0, 12.0)
    /// What to draw and where, worked out here so that the drawing itself touches no state.
    var marks: [(image: NSImage, at: NSRect)] = [], texts: [(text: NSAttributedString, at: NSPoint)] = [], x = 0.0
    for (index, pools) in profiles.enumerated() {
        if index > 0 { x += apart - between }
        for pool in pools {
            if let mark = providerMark(pool.provider) {
                marks.append((mark, NSRect(x: x, y: 3, width: side, height: side)))
                x += side + gap
            }
            let text = NSAttributedString(string: pool.text, attributes: [.font: font, .foregroundColor: NSColor.black])
            texts.append((text, NSPoint(x: x, y: (18 - text.size().height) / 2)))
            x += text.size().width.rounded(.up) + between
        }
    }
    let image = NSImage(size: NSSize(width: max(x - between, 1), height: 18))
    image.lockFocus()
    for mark in marks { mark.image.draw(in: mark.at) }
    for text in texts { text.text.draw(at: text.at) }
    image.unlockFocus()
    image.isTemplate = true
    return image
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
