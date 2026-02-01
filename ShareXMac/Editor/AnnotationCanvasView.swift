import AppKit

class AnnotationCanvasView: NSView {
    var currentTool: AnnotationTool = .rectangle {
        didSet {
            updateCursor()
        }
    }
    
    var onComplete: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?
    
    private let image: NSImage
    private var annotations: [Annotation] = []
    private var selectedAnnotation: Annotation?
    private var activeHandle: AnnotationHandle?
    
    // Drawing state
    private var isDrawing = false
    private var drawStartPoint: CGPoint?
    private var currentDrawEndPoint: CGPoint?
    
    // Dragging state
    private var isDragging = false
    private var dragStartPoint: CGPoint?
    private var dragStartBounds: CGRect?
    private var dragStartArrowStart: CGPoint?
    private var dragStartArrowEnd: CGPoint?
    
    private let annotationColor = NSColor.red.cgColor
    private let strokeWidth: CGFloat = 3.0
    
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    
    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        setupTrackingArea()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    private func updateCursor() {
        switch currentTool {
        case .select:
            NSCursor.arrow.set()
        case .rectangle, .arrow:
            NSCursor.crosshair.set()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        debugLog("DEBUG CANVAS: draw called, bounds: \(bounds)")
        // Draw image
        image.draw(in: bounds)
        debugLog("DEBUG CANVAS: image drawn")
        
        // Draw existing annotations
        guard let context = NSGraphicsContext.current?.cgContext else { 
            debugLog("DEBUG CANVAS: no context")
            return 
        }
        
        debugLog("DEBUG CANVAS: drawing \(annotations.count) annotations")
        for annotation in annotations {
            annotation.draw(in: context)
            
            // Draw selection handles if selected
            if annotation.id == selectedAnnotation?.id {
                drawSelectionHandles(for: annotation, in: context)
            }
        }
        
        // Draw current shape being created
        if isDrawing, let start = drawStartPoint, let end = currentDrawEndPoint {
            context.setStrokeColor(annotationColor)
            context.setFillColor(annotationColor)
            context.setLineWidth(strokeWidth)
            
            switch currentTool {
            case .rectangle:
                let rect = rectFromPoints(start, end)
                context.stroke(rect)
            case .arrow:
                drawArrowPreview(from: start, to: end, in: context)
            case .select:
                break
            }
        }
        debugLog("DEBUG CANVAS: draw complete")
    }
    
    private func drawArrowPreview(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let arrowHeadLength: CGFloat = 20.0
        let arrowHeadAngle: CGFloat = .pi / 6
        
        // Draw line
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        
        // Calculate arrow head
        let angle = atan2(end.y - start.y, end.x - start.x)
        
        let arrowPoint1 = CGPoint(
            x: end.x - arrowHeadLength * cos(angle + arrowHeadAngle),
            y: end.y - arrowHeadLength * sin(angle + arrowHeadAngle)
        )
        
        let arrowPoint2 = CGPoint(
            x: end.x - arrowHeadLength * cos(angle - arrowHeadAngle),
            y: end.y - arrowHeadLength * sin(angle - arrowHeadAngle)
        )
        
        // Draw filled arrow head
        context.move(to: end)
        context.addLine(to: arrowPoint1)
        context.addLine(to: arrowPoint2)
        context.closePath()
        context.fillPath()
    }
    
    private func drawSelectionHandles(for annotation: Annotation, in context: CGContext) {
        let handleSize: CGFloat = 8
        let bounds = annotation.bounds
        
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1)
        
        if let arrow = annotation as? ArrowAnnotation {
            // Draw handles at arrow endpoints
            let handles = [arrow.startPoint, arrow.endPoint]
            for point in handles {
                let handleRect = CGRect(
                    x: point.x - handleSize/2,
                    y: point.y - handleSize/2,
                    width: handleSize,
                    height: handleSize
                )
                context.fillEllipse(in: handleRect)
                context.strokeEllipse(in: handleRect)
            }
        } else {
            // Draw corner handles
            let corners = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY)
            ]
            
            for corner in corners {
                let handleRect = CGRect(
                    x: corner.x - handleSize/2,
                    y: corner.y - handleSize/2,
                    width: handleSize,
                    height: handleSize
                )
                context.fill(handleRect)
                context.stroke(handleRect)
            }
        }
    }
    
    private func rectFromPoints(_ p1: CGPoint, _ p2: CGPoint) -> CGRect {
        let x = min(p1.x, p2.x)
        let y = min(p1.y, p2.y)
        let width = abs(p2.x - p1.x)
        let height = abs(p2.y - p1.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if currentTool == .select {
            // Check if clicking on an annotation
            for annotation in annotations.reversed() {
                if let handle = annotation.hitTest(point: point) {
                    selectedAnnotation = annotation
                    activeHandle = handle
                    isDragging = true
                    dragStartPoint = point
                    dragStartBounds = annotation.bounds
                    
                    if let arrow = annotation as? ArrowAnnotation {
                        dragStartArrowStart = arrow.startPoint
                        dragStartArrowEnd = arrow.endPoint
                    }
                    
                    needsDisplay = true
                    return
                }
            }
            
            // Clicked on nothing - deselect
            selectedAnnotation = nil
            needsDisplay = true
        } else {
            // Start drawing
            isDrawing = true
            drawStartPoint = point
            currentDrawEndPoint = point
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if isDragging, let selected = selectedAnnotation, let start = dragStartPoint {
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            
            if let arrow = selected as? ArrowAnnotation {
                switch activeHandle {
                case .startPoint:
                    if let originalStart = dragStartArrowStart {
                        arrow.startPoint = CGPoint(x: originalStart.x + delta.x, y: originalStart.y + delta.y)
                    }
                case .endPoint:
                    if let originalEnd = dragStartArrowEnd {
                        arrow.endPoint = CGPoint(x: originalEnd.x + delta.x, y: originalEnd.y + delta.y)
                    }
                case .body:
                    if let originalStart = dragStartArrowStart, let originalEnd = dragStartArrowEnd {
                        arrow.startPoint = CGPoint(x: originalStart.x + delta.x, y: originalStart.y + delta.y)
                        arrow.endPoint = CGPoint(x: originalEnd.x + delta.x, y: originalEnd.y + delta.y)
                    }
                default:
                    break
                }
            } else if let originalBounds = dragStartBounds {
                switch activeHandle {
                case .body:
                    selected.bounds = CGRect(
                        x: originalBounds.origin.x + delta.x,
                        y: originalBounds.origin.y + delta.y,
                        width: originalBounds.width,
                        height: originalBounds.height
                    )
                case .topRight:
                    selected.bounds = CGRect(
                        x: originalBounds.origin.x,
                        y: originalBounds.origin.y,
                        width: originalBounds.width + delta.x,
                        height: originalBounds.height + delta.y
                    )
                case .topLeft:
                    selected.bounds = CGRect(
                        x: originalBounds.origin.x + delta.x,
                        y: originalBounds.origin.y,
                        width: originalBounds.width - delta.x,
                        height: originalBounds.height + delta.y
                    )
                case .bottomRight:
                    selected.bounds = CGRect(
                        x: originalBounds.origin.x,
                        y: originalBounds.origin.y + delta.y,
                        width: originalBounds.width + delta.x,
                        height: originalBounds.height - delta.y
                    )
                case .bottomLeft:
                    selected.bounds = CGRect(
                        x: originalBounds.origin.x + delta.x,
                        y: originalBounds.origin.y + delta.y,
                        width: originalBounds.width - delta.x,
                        height: originalBounds.height - delta.y
                    )
                default:
                    break
                }
            }
            
            needsDisplay = true
        } else if isDrawing {
            currentDrawEndPoint = point
            needsDisplay = true
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            dragStartPoint = nil
            dragStartBounds = nil
            dragStartArrowStart = nil
            dragStartArrowEnd = nil
            activeHandle = nil
        } else if isDrawing, let start = drawStartPoint, let end = currentDrawEndPoint {
            isDrawing = false
            
            // Create annotation
            switch currentTool {
            case .rectangle:
                let rect = rectFromPoints(start, end)
                if rect.width > 5 && rect.height > 5 {
                    let annotation = RectangleAnnotation(bounds: rect, color: annotationColor, strokeWidth: strokeWidth)
                    annotations.append(annotation)
                    selectedAnnotation = annotation
                    currentTool = .select
                }
            case .arrow:
                let distance = hypot(end.x - start.x, end.y - start.y)
                if distance > 10 {
                    let annotation = ArrowAnnotation(startPoint: start, endPoint: end, color: annotationColor, strokeWidth: strokeWidth)
                    annotations.append(annotation)
                    selectedAnnotation = annotation
                    currentTool = .select
                }
            case .select:
                break
            }
            
            drawStartPoint = nil
            currentDrawEndPoint = nil
            needsDisplay = true
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }
    
    // MARK: - Keyboard Events
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            if selectedAnnotation != nil {
                selectedAnnotation = nil
                needsDisplay = true
            } else {
                onCancel?()
            }
        case 51: // Delete/Backspace
            if let selected = selectedAnnotation {
                annotations.removeAll { $0.id == selected.id }
                selectedAnnotation = nil
                needsDisplay = true
            }
        case 36: // Enter
            completeEditing()
        case 9: // V - Select tool
            currentTool = .select
        case 15: // R - Rectangle tool
            currentTool = .rectangle
        case 0: // A - Arrow tool
            currentTool = .arrow
        case 8: // C - Copy (with Cmd)
            if event.modifierFlags.contains(.command) {
                completeEditing()
            }
        default:
            super.keyDown(with: event)
        }
    }
    
    func completeEditing() {
        let finalImage = renderFinalImage()
        onComplete?(finalImage)
    }
    
    private func renderFinalImage() -> NSImage {
        let finalImage = NSImage(size: image.size)
        
        finalImage.lockFocus()
        
        // Draw original image
        image.draw(in: NSRect(origin: .zero, size: image.size))
        
        // Draw annotations
        if let context = NSGraphicsContext.current?.cgContext {
            for annotation in annotations {
                annotation.draw(in: context)
            }
        }
        
        finalImage.unlockFocus()
        
        return finalImage
    }
}
