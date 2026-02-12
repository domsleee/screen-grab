import Foundation
import CoreGraphics
import AppKit

class RectangleAnnotation: Annotation {
    let id: UUID
    var bounds: CGRect {
        didSet { bounds = bounds.standardized }
    }
    var color: CGColor
    var strokeWidth: CGFloat

    init(id: UUID = UUID(), bounds: CGRect, color: CGColor = NSColor.red.cgColor, strokeWidth: CGFloat = 3.0) {
        self.id = id
        self.bounds = bounds
        self.color = color
        self.strokeWidth = strokeWidth
    }

    func draw(in context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth)
        context.stroke(bounds)
    }
}
