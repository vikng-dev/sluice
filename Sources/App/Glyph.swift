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

/// A provider's mark, drawn in the text colour. The drawings are in Assets/providers, named by provider;
/// a provider without one is shown by name.
@MainActor func providerMark(_ provider: String) -> NSImage? {
    if let known = marks[provider] { return known }
    guard let url = Bundle.main.url(forResource: provider, withExtension: "svg", subdirectory: "providers"), let mark = NSImage(contentsOf: url) else { return nil }
    mark.isTemplate = true
    marks[provider] = mark
    return mark
}

@MainActor private var marks: [String: NSImage] = [:]
