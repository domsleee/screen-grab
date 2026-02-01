import Foundation
import CoreGraphics
import AppKit

class ArrowAnnotation: Annotation {
    let id = UUID()
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: CGColor
    var strokeWidth: CGFloat
    var arrowHeadLength: CGFloat = 20.0
    var arrowHeadAngle: CGFloat = .pi / 6  // 30 degrees
    
    var bounds: CGRect {
        get {
            let minX = min(startPoint.x, endPoint.x)
            let minY = min(startPoint.y, endPoint.y)
            let maxX = max(startPoint.x, endPoint.x)
            let maxY = max(startPoint.y, endPoint.y)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        set {
            // Adjust points when bounds change
            let oldBounds = bounds
            let scaleX = newValue.width / max(oldBounds.width, 1)
            let scaleY = newValue.height / max(oldBounds.height, 1)
            
            startPoint = CGPoint(
                x: newValue.minX + (startPoint.x - oldBounds.minX) * scaleX,
                y: newValue.minY + (startPoint.y - oldBounds.minY) * scaleY
            )
            endPoint = CGPoint(
                x: newValue.minX + (endPoint.x - oldBounds.minX) * scaleX,
                y: newValue.minY + (endPoint.y - oldBounds.minY) * scaleY
            )
        }
    }
    
    init(startPoint: CGPoint, endPoint: CGPoint, color: CGColor = NSColor.red.cgColor, strokeWidth: CGFloat = 3.0) {
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.strokeWidth = strokeWidth
    }
    
    func draw(in context: CGContext) {
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        // Calculate arrow head
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        
        let arrowPoint1 = CGPoint(
            x: endPoint.x - arrowHeadLength * cos(angle + arrowHeadAngle),
            y: endPoint.y - arrowHeadLength * sin(angle + arrowHeadAngle)
        )
        
        let arrowPoint2 = CGPoint(
            x: endPoint.x - arrowHeadLength * cos(angle - arrowHeadAngle),
            y: endPoint.y - arrowHeadLength * sin(angle - arrowHeadAngle)
        )
        
        // Calculate where line should stop (at base of arrowhead)
        let arrowBasePoint = CGPoint(
            x: (arrowPoint1.x + arrowPoint2.x) / 2,
            y: (arrowPoint1.y + arrowPoint2.y) / 2
        )
        
        // Draw the line (stop at arrow base, not tip)
        context.move(to: startPoint)
        context.addLine(to: arrowBasePoint)
        context.strokePath()
        
        // Draw filled arrow head
        context.move(to: endPoint)
        context.addLine(to: arrowPoint1)
        context.addLine(to: arrowPoint2)
        context.closePath()
        context.fillPath()
    }
    
    func contains(point: CGPoint) -> Bool {
        // Check if point is near the line
        let distance = distanceFromPointToLine(point: point, lineStart: startPoint, lineEnd: endPoint)
        return distance < 10.0
    }
    
    func hitTest(point: CGPoint) -> AnnotationHandle? {
        let handleSize: CGFloat = 12
        
        // Check endpoints
        if CGRect(x: startPoint.x - handleSize/2, y: startPoint.y - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .startPoint
        }
        if CGRect(x: endPoint.x - handleSize/2, y: endPoint.y - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .endPoint
        }
        
        // Check line body
        if contains(point: point) {
            return .body
        }
        
        return nil
    }
    
    private func distanceFromPointToLine(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        
        if lengthSquared == 0 {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared))
        let projectionX = lineStart.x + t * dx
        let projectionY = lineStart.y + t * dy
        
        return hypot(point.x - projectionX, point.y - projectionY)
    }
}
