import Foundation
import CoreGraphics
import AppKit

class TextAnnotation: Annotation {
    let id: UUID
    var text: String
    var position: CGPoint
    var fontSize: CGFloat
    var color: CGColor
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

    init(id: UUID = UUID(), text: String = "", position: CGPoint, fontSize: CGFloat = 24, color: CGColor = NSColor.red.cgColor, strokeWidth: CGFloat = 0) {
        self.id = id
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.color = color
        self.strokeWidth = strokeWidth
    }

    func draw(in context: CGContext) {
        guard !text.isEmpty else { return }
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
        // Text annotations only support move (no resize handles)
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

    private func textSize() -> CGSize {
        guard !text.isEmpty else {
            // Return a minimum size for the cursor/caret area
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            return CGSize(width: 2, height: font.ascender - font.descender)
        }
        let attrs = textAttributes()
        return (text as NSString).size(withAttributes: attrs)
    }
}
