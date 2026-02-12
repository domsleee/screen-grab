import Foundation
import CoreGraphics
import AppKit

class ArrowAnnotation: Annotation {
    let id: UUID
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
            let oldBounds = bounds

            // Map each axis: scale proportionally when old dimension > 0,
            // otherwise distribute points across the new dimension.
            func mapPair(_ a: CGFloat, _ b: CGFloat,
                         oldMin: CGFloat, oldSize: CGFloat,
                         newMin: CGFloat, newSize: CGFloat) -> (CGFloat, CGFloat) {
                if oldSize < 0.001 {
                    return (newMin, newMin + newSize)
                }
                let scale = newSize / oldSize
                return (newMin + (a - oldMin) * scale,
                        newMin + (b - oldMin) * scale)
            }

            let (sx, ex) = mapPair(startPoint.x, endPoint.x,
                                   oldMin: oldBounds.minX, oldSize: oldBounds.width,
                                   newMin: newValue.minX, newSize: newValue.width)
            let (sy, ey) = mapPair(startPoint.y, endPoint.y,
                                   oldMin: oldBounds.minY, oldSize: oldBounds.height,
                                   newMin: newValue.minY, newSize: newValue.height)
            startPoint = CGPoint(x: sx, y: sy)
            endPoint = CGPoint(x: ex, y: ey)
        }
    }

    init(id: UUID = UUID(), startPoint: CGPoint, endPoint: CGPoint, color: CGColor = NSColor.red.cgColor, strokeWidth: CGFloat = 3.0) {
        self.id = id
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.strokeWidth = strokeWidth
    }

    /// Computed arrowhead geometry: the two wing points and the base center.
    struct ArrowGeometry {
        let point1: CGPoint
        let point2: CGPoint
        let basePoint: CGPoint
    }

    /// Compute arrowhead geometry for any start/end pair (used by rendering + CALayer code).
    static func arrowGeometry(from start: CGPoint, to end: CGPoint,
                              headLength: CGFloat = 20.0, headAngle: CGFloat = .pi / 6) -> ArrowGeometry {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let p1 = CGPoint(x: end.x - headLength * cos(angle + headAngle),
                         y: end.y - headLength * sin(angle + headAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle - headAngle),
                         y: end.y - headLength * sin(angle - headAngle))
        let base = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        return ArrowGeometry(point1: p1, point2: p2, basePoint: base)
    }

    func draw(in context: CGContext) {
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let geo = ArrowAnnotation.arrowGeometry(from: startPoint, to: endPoint,
                                                 headLength: arrowHeadLength, headAngle: arrowHeadAngle)

        // Draw the line (stop at arrow base, not tip)
        context.move(to: startPoint)
        context.addLine(to: geo.basePoint)
        context.strokePath()

        // Draw filled arrow head
        context.move(to: endPoint)
        context.addLine(to: geo.point1)
        context.addLine(to: geo.point2)
        context.closePath()
        context.fillPath()
    }

    func contains(point: CGPoint) -> Bool {
        // Check if point is near the line
        let distance = distanceFromPointToLine(point: point, lineStart: startPoint, lineEnd: endPoint)
        return distance < 10.0
    }

    func hitTest(point: CGPoint) -> AnnotationHandle? {
        let handleRadius: CGFloat = 5

        let distToStart = hypot(point.x - startPoint.x, point.y - startPoint.y)
        let distToEnd = hypot(point.x - endPoint.x, point.y - endPoint.y)
        let arrowLength = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)

        // Zero-length arrow: prefer endPoint so user can extend it
        if arrowLength < 1 {
            if distToEnd < handleRadius { return .endPoint }
            return nil
        }

        // Short arrows: prefer body at midpoint to allow dragging
        if arrowLength < handleRadius * 2 {
            let distToLine = distanceFromPointToLine(point: point, lineStart: startPoint, lineEnd: endPoint)
            if distToLine < 10 {
                let midX = (startPoint.x + endPoint.x) / 2
                let midY = (startPoint.y + endPoint.y) / 2
                let distToMid = hypot(point.x - midX, point.y - midY)
                if distToMid < min(distToStart, distToEnd) {
                    return .body
                }
            }
        }

        // Circular endpoint detection (not rectangular)
        if distToStart < handleRadius { return .startPoint }
        if distToEnd < handleRadius { return .endPoint }

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

        let param = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared))
        let projectionX = lineStart.x + param * dx
        let projectionY = lineStart.y + param * dy

        return hypot(point.x - projectionX, point.y - projectionY)
    }
}
