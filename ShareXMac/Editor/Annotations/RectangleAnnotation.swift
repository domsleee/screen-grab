import Foundation
import CoreGraphics
import AppKit

class RectangleAnnotation: Annotation {
    let id = UUID()
    var bounds: CGRect
    var color: CGColor
    var strokeWidth: CGFloat
    
    init(bounds: CGRect, color: CGColor = NSColor.red.cgColor, strokeWidth: CGFloat = 3.0) {
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
