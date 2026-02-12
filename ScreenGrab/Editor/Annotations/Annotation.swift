import Foundation
import CoreGraphics

enum AnnotationTool: String, CaseIterable {
    case select = "Select"
    case rectangle = "Rectangle"
    case arrow = "Arrow"

    var shortcut: String {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .arrow: return "A"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .select: return 9      // V
        case .rectangle: return 15  // R
        case .arrow: return 0       // A
        }
    }
}

protocol Annotation: AnyObject {
    var id: UUID { get }
    var bounds: CGRect { get set }
    var color: CGColor { get set }
    var strokeWidth: CGFloat { get set }

    func draw(in context: CGContext)
    func contains(point: CGPoint) -> Bool
    func hitTest(point: CGPoint) -> AnnotationHandle?
}

enum AnnotationHandle {
    case body
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
    case startPoint, endPoint  // For arrows
}

extension Annotation {
    func contains(point: CGPoint) -> Bool {
        return bounds.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2).contains(point)
    }

    func hitTest(point: CGPoint) -> AnnotationHandle? {
        let handleSize: CGFloat = 10

        let corners: [(CGPoint, AnnotationHandle)] = [
            (CGPoint(x: bounds.minX, y: bounds.minY), .bottomLeft),
            (CGPoint(x: bounds.maxX, y: bounds.minY), .bottomRight),
            (CGPoint(x: bounds.minX, y: bounds.maxY), .topLeft),
            (CGPoint(x: bounds.maxX, y: bounds.maxY), .topRight),
        ]

        // Find the closest handle whose rect contains the point
        var closestHandle: AnnotationHandle?
        var closestDist = CGFloat.infinity

        for (corner, handle) in corners {
            let handleRect = CGRect(
                x: corner.x - handleSize / 2, y: corner.y - handleSize / 2,
                width: handleSize, height: handleSize
            )
            if handleRect.contains(point) {
                let dist = hypot(point.x - corner.x, point.y - corner.y)
                if dist < closestDist {
                    closestDist = dist
                    closestHandle = handle
                }
            }
        }

        if let handle = closestHandle {
            return handle
        }

        // Check body (includes stroke width overhang)
        if contains(point: point) {
            return .body
        }

        return nil
    }
}
