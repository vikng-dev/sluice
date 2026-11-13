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

/// The starred profiles in the menu bar: each pool's provider mark and its share over a thin meter of
/// that share in the profile's colour, a profile's pools close together and the profiles apart.
@MainActor func counterGlyph(_ profiles: [(color: NSColor?, pools: [(provider: String, text: String, share: Double)])]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let (side, gap, between, apart, height) = (12.0, 2.0, 6.0, 12.0, 22.0)
    /// What to draw and where, worked out here so that the drawing itself touches no state.
    var marks: [(image: NSImage, at: NSRect)] = [], texts: [(text: String, at: NSPoint)] = []
    var meters: [(color: NSColor?, at: NSRect, share: Double)] = [], x = 0.0
    for (index, profile) in profiles.enumerated() {
        if index > 0 { x += apart - between }
        for pool in profile.pools {
            let from = x
            if let mark = providerMark(pool.provider) {
                marks.append((mark, NSRect(x: x, y: (height - side) / 2, width: side, height: side)))
                x += side + gap
            }
            let size = NSAttributedString(string: pool.text, attributes: [.font: font]).size()
            texts.append((pool.text, NSPoint(x: x, y: (height - size.height) / 2)))
            x += size.width.rounded(.up)
            meters.append((profile.color, NSRect(x: from, y: 1, width: x - from, height: 2), min(max(pool.share, 0), 1)))
            x += between
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
        for meter in meters {
            ink.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: meter.at, xRadius: 1, yRadius: 1).fill()
            (meter.color ?? ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: meter.at.minX, y: meter.at.minY, width: meter.at.width * meter.share, height: meter.at.height), xRadius: 1, yRadius: 1).fill()
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
