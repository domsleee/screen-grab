import Foundation
import CoreGraphics
import AppKit

class TextAnnotation: Annotation {
    let id: UUID
    var text: String
    var position: CGPoint
    var fontSize: CGFloat
    var color: CGColor
    var backgroundColor: CGColor?
    var backgroundPadding: CGFloat
    var strokeWidth: CGFloat // unused but required by protocol

    var bounds: CGRect {
        get {
            let size = textSize()
            return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
        }
        set {
            position = newValue.origin
        }
    }

    /// Bounding rect for the background fill, with padding around the text.
    var backgroundRect: CGRect {
        let size = textSize()
        return CGRect(x: position.x - backgroundPadding, y: position.y - backgroundPadding,
                      width: size.width + backgroundPadding * 2, height: size.height + backgroundPadding * 2)
    }

    init(id: UUID = UUID(), text: String = "", position: CGPoint, fontSize: CGFloat = 24, color: CGColor = NSColor.red.cgColor, backgroundColor: CGColor? = nil, backgroundPadding: CGFloat = 4, strokeWidth: CGFloat = 0) {
        self.id = id
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
        self.backgroundPadding = backgroundPadding
        self.strokeWidth = strokeWidth
    }

    func draw(in context: CGContext) {
        guard !text.isEmpty else { return }

        // Draw background if set
        if let bgColor = backgroundColor {
            let bgRect = backgroundRect
            context.setFillColor(bgColor)
            let path = CGPath(roundedRect: bgRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(path)
            context.fillPath()
        }

        let attrs = textAttributes()

        // NSAttributedString.draw uses flipped coords, but we're in a CGContext
        // Push graphics state and use NSString drawing
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: position.x, y: position.y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func contains(point: CGPoint) -> Bool {
        return bounds.insetBy(dx: -5, dy: -5).contains(point)
    }

    func hitTest(point: CGPoint) -> AnnotationHandle? {
        let handleSize: CGFloat = 10

        // Check corners for resize handles
        let b = bounds
        let corners: [(CGPoint, AnnotationHandle)] = [
            (CGPoint(x: b.minX, y: b.minY), .bottomLeft),
            (CGPoint(x: b.maxX, y: b.minY), .bottomRight),
            (CGPoint(x: b.minX, y: b.maxY), .topLeft),
            (CGPoint(x: b.maxX, y: b.maxY), .topRight),
        ]
        for (corner, handle) in corners {
            let handleRect = CGRect(
                x: corner.x - handleSize / 2, y: corner.y - handleSize / 2,
                width: handleSize, height: handleSize
            )
            if handleRect.contains(point) {
                return handle
            }
        }

        if contains(point: point) {
            return .body
        }
        return nil
    }

    func textAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.red
        ]
    }

    func textSize() -> CGSize {
        guard !text.isEmpty else {
            // Return a minimum size for the cursor/caret area
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            return CGSize(width: 2, height: font.ascender - font.descender)
        }
        let attrs = textAttributes()
        return (text as NSString).size(withAttributes: attrs)
    }
}
