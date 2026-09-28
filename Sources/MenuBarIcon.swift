import AppKit

/// Menu bar template icon: a rounded tile split diagonally, 简 on the outlined half and 繁 knocked out of the filled half.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fanti"
        return image
    }()

    /// SF Symbol shown briefly after a conversion.
    static func feedback(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    private static func draw() {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.set()

        let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16), xRadius: 3.5, yRadius: 3.5)
        tile.lineWidth = 1.3
        tile.stroke()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let lowerRight = NSBezierPath()
        lowerRight.move(to: CGPoint(x: 18, y: 18))
        lowerRight.line(to: CGPoint(x: 18, y: 0))
        lowerRight.line(to: CGPoint(x: 0, y: 0))
        lowerRight.close()
        lowerRight.fill()
        NSGraphicsContext.restoreGraphicsState()

        glyph("简", size: 5.8, weight: .semibold, center: CGPoint(x: 5.7, y: 12.3))?.fill()
        context.compositingOperation = .clear
        glyph("繁", size: 6.6, weight: .bold, center: CGPoint(x: 12.3, y: 5.7))?.fill()
        context.compositingOperation = .sourceOver
    }

    /// Outline of a single character, using whichever CJK font the system falls back to.
    private static func glyph(_ character: String, size: CGFloat, weight: NSFont.Weight, center: CGPoint) -> NSBezierPath? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: character, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]))
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let font = attributes[kCTFontAttributeName] as! CTFont
        guard let cgPath = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        let path = NSBezierPath(cgPath: cgPath)
        let bounds = path.bounds
        path.transform(using: AffineTransform(translationByX: center.x - bounds.midX, byY: center.y - bounds.midY))
        return path
    }
}
