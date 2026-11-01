import AppKit

/// Draws a small pie chart: an outlined circle filled clockwise from 12 o'clock
/// in proportion to `percent` (0…100). Below 80% it is a template image so it
/// matches the menu bar's light/dark style; at 80%+ it turns orange, 95%+ red.
enum PieIcon {
    static func image(percent: Double?, size: CGFloat = 16, colored: Bool = true) -> NSImage {
        let p = percent.map { min(max($0, 0), 100) }
        let warn: NSColor? = {
            guard colored, let p else { return nil }
            if p >= 95 { return .systemRed }
            if p >= 80 { return .systemOrange }
            return nil
        }()

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1.25, dy: 1.25)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = circleRect.width / 2

            let stroke = warn ?? (NSColor.black)
            let fill = warn ?? (NSColor.black)

            let outline = NSBezierPath(ovalIn: circleRect)
            outline.lineWidth = 1.3
            stroke.setStroke()
            outline.stroke()

            if let p {
                // Faint background disc so an empty pie is still readable.
                stroke.withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: circleRect).fill()

                let frac = p / 100
                fill.setFill()
                if frac >= 0.999 {
                    NSBezierPath(ovalIn: circleRect).fill()
                } else if frac > 0 {
                    let wedge = NSBezierPath()
                    wedge.move(to: center)
                    wedge.appendArc(withCenter: center, radius: radius,
                                    startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
                    wedge.close()
                    wedge.fill()
                }
            } else {
                // Unknown state: dashed-looking question mark-ish dot.
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
                stroke.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = (warn == nil)
        return image
    }
}
