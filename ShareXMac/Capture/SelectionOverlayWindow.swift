import AppKit

class SelectionOverlayWindow: NSWindow {
    var onSelectionComplete: ((CGRect, CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?
    
    private var screenFrame: CGRect = .zero
    private var selectionView: SelectionView?
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        self.screenFrame = screen.frame
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let selectionView = SelectionView(frame: screen.frame)
        selectionView.onSelectionComplete = { [weak self] rect, annotations in
            guard let self = self else { return }
            self.onSelectionComplete?(rect, self.screenFrame, annotations)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
        }
        self.selectionView = selectionView
        
        self.contentView = selectionView
    }
    
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        // Ensure view becomes first responder
        if let view = selectionView {
            makeFirstResponder(view)
        }
    }
    
    func stopKeyMonitors() {
        selectionView?.stopKeyMonitor()
    }
    
    override func close() {
        selectionView?.stopKeyMonitor()
        selectionView?.onSelectionComplete = nil
        selectionView?.onCancel = nil
        super.close()
    }
}

enum SelectionTool {
    case select      // For region selection
    case rectangle   // For drawing rectangles
    case arrow       // For drawing arrows
}

class SelectionView: NSView {
    var onSelectionComplete: ((CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?
    
    // Current tool mode
    private var currentTool: SelectionTool = .select
    
    // Region selection state
    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false
    
    // Annotation state
    private var annotations: [any Annotation] = []
    private var isDrawingAnnotation = false
    private var annotationStart: NSPoint?
    private var annotationEnd: NSPoint?
    private var currentDrawingTool: SelectionTool = .rectangle  // Track which tool we started drawing with
    
    private var currentMousePosition: NSPoint?
    
    private let annotationColor = NSColor.red.cgColor
    private let strokeWidth: CGFloat = 3.0
    
    // Local event monitor for keyboard events
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    
    override var acceptsFirstResponder: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
        setupKeyMonitor()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
        setupKeyMonitor()
    }
    
    deinit {
        stopKeyMonitor()
    }
    
    func stopKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
    }
    
    private func setupKeyMonitor() {
        // Local monitor handles events when app is focused (can consume them)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
        
        // Global monitor as fallback when app not focused (can't consume events)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            _ = self.handleKeyEvent(event)
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // ESC
            onCancel?()
            return true
        case 15: // R - Rectangle tool
            currentTool = .rectangle
            updateCursor()
            needsDisplay = true
            return true
        case 0: // A - Arrow tool
            currentTool = .arrow
            updateCursor()
            needsDisplay = true
            return true
        case 51: // Delete - remove last annotation
            if !annotations.isEmpty {
                annotations.removeLast()
                needsDisplay = true
            }
            return true
        default:
            return false
        }
    }
    
    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    private func updateCursor() {
        switch currentTool {
        case .select:
            NSCursor.crosshair.set()
        case .rectangle:
            NSCursor.crosshair.set()
        case .arrow:
            NSCursor.crosshair.set()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // Draw semi-transparent overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        
        // Draw crosshair at mouse position (when not actively drawing)
        if let mousePos = currentMousePosition, !isSelecting && !isDrawingAnnotation {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            
            let horizontalLine = NSBezierPath()
            horizontalLine.move(to: NSPoint(x: 0, y: mousePos.y))
            horizontalLine.line(to: NSPoint(x: bounds.width, y: mousePos.y))
            horizontalLine.lineWidth = 1
            horizontalLine.stroke()
            
            let verticalLine = NSBezierPath()
            verticalLine.move(to: NSPoint(x: mousePos.x, y: 0))
            verticalLine.line(to: NSPoint(x: mousePos.x, y: bounds.height))
            verticalLine.lineWidth = 1
            verticalLine.stroke()
        }
        
        // Draw selection rectangle being drawn
        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = rectFromPoints(start, end)
            
            // Clear the selection area
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            
            // Draw selection border
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 2
            borderPath.stroke()
            
            // Draw dashed inner border
            NSColor.black.setStroke()
            let dashedPath = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            dashedPath.lineWidth = 1
            dashedPath.setLineDash([4, 4], count: 2, phase: 0)
            dashedPath.stroke()
            
            // Draw size label
            drawSizeLabel(for: rect)
        }
        
        // Draw existing annotations
        if let context = NSGraphicsContext.current?.cgContext {
            for annotation in annotations {
                annotation.draw(in: context)
            }
            
            // Draw annotation being drawn
            if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
                context.setStrokeColor(annotationColor)
                context.setLineWidth(strokeWidth)
                
                if currentDrawingTool == .arrow {
                    // Draw arrow preview
                    context.setFillColor(annotationColor)
                    context.setLineCap(.round)
                    context.move(to: start)
                    context.addLine(to: end)
                    context.strokePath()
                    
                    // Draw arrow head
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let arrowHeadLength: CGFloat = 20.0
                    let arrowHeadAngle: CGFloat = .pi / 6
                    let arrowPoint1 = CGPoint(
                        x: end.x - arrowHeadLength * cos(angle + arrowHeadAngle),
                        y: end.y - arrowHeadLength * sin(angle + arrowHeadAngle)
                    )
                    let arrowPoint2 = CGPoint(
                        x: end.x - arrowHeadLength * cos(angle - arrowHeadAngle),
                        y: end.y - arrowHeadLength * sin(angle - arrowHeadAngle)
                    )
                    context.move(to: end)
                    context.addLine(to: arrowPoint1)
                    context.addLine(to: arrowPoint2)
                    context.closePath()
                    context.fillPath()
                } else {
                    // Draw rectangle preview
                    let rect = rectFromPoints(start, end)
                    context.stroke(rect)
                }
            }
        }
        
        // Draw instructions
        drawInstructions()
    }
    
    private func drawSizeLabel(for rect: NSRect) {
        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        
        let textSize = sizeText.size(withAttributes: attributes)
        let labelRect = NSRect(
            x: rect.midX - textSize.width / 2 - 4,
            y: rect.minY - textSize.height - 8,
            width: textSize.width + 8,
            height: textSize.height + 4
        )
        
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        
        sizeText.draw(
            at: NSPoint(x: labelRect.minX + 4, y: labelRect.minY + 2),
            withAttributes: attributes
        )
    }
    
    private func drawInstructions() {
        // Draw mode indicator
        let modeText: String
        let modeColor: NSColor
        switch currentTool {
        case .rectangle:
            modeText = "🔴 RECTANGLE MODE"
            modeColor = NSColor.systemRed
        case .arrow:
            modeText = "➡️ ARROW MODE"
            modeColor = NSColor.systemOrange
        case .select:
            modeText = "🔲 SELECT MODE"
            modeColor = NSColor.white
        }
        let modeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: modeColor
        ]
        let modeSize = modeText.size(withAttributes: modeAttrs)
        let modePoint = NSPoint(
            x: bounds.midX - modeSize.width / 2,
            y: bounds.height - 90
        )
        let modeBgRect = NSRect(
            x: modePoint.x - 12,
            y: modePoint.y - 6,
            width: modeSize.width + 24,
            height: modeSize.height + 12
        )
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: modeBgRect, xRadius: 8, yRadius: 8).fill()
        modeText.draw(at: modePoint, withAttributes: modeAttrs)
        
        // Draw instructions
        var text: String
        switch currentTool {
        case .rectangle:
            text = "Drag to draw rectangle • ESC: Cancel"
        case .arrow:
            text = "Drag to draw arrow • ESC: Cancel"
        case .select:
            text = "Drag to select & capture • R: Rectangle • A: Arrow • ESC: Cancel"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        
        let textSize = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.height - 50
        )
        
        // Background
        let bgRect = NSRect(
            x: point.x - 10,
            y: point.y - 5,
            width: textSize.width + 20,
            height: textSize.height + 10
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()
        
        text.draw(at: point, withAttributes: attributes)
    }
    
    private func rectFromPoints(_ p1: NSPoint, _ p2: NSPoint) -> NSRect {
        let x = min(p1.x, p2.x)
        let y = min(p1.y, p2.y)
        let width = abs(p2.x - p1.x)
        let height = abs(p2.y - p1.y)
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if currentTool == .rectangle || currentTool == .arrow {
            isDrawingAnnotation = true
            currentDrawingTool = currentTool
            annotationStart = point
            annotationEnd = point
            needsDisplay = true
        } else {
            selectionStart = point
            selectionEnd = point
            isSelecting = true
            needsDisplay = true
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if isDrawingAnnotation {
            annotationEnd = point
            needsDisplay = true
        } else if isSelecting {
            selectionEnd = point
            needsDisplay = true
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
            isDrawingAnnotation = false
            
            // Create annotation based on what tool we started with
            if currentDrawingTool == .arrow {
                let distance = hypot(end.x - start.x, end.y - start.y)
                if distance > 10 {
                    let annotation = ArrowAnnotation(startPoint: start, endPoint: end, color: annotationColor, strokeWidth: strokeWidth)
                    annotations.append(annotation)
                }
            } else {
                let rect = rectFromPoints(start, end)
                if rect.width > 5 && rect.height > 5 {
                    let annotation = RectangleAnnotation(bounds: rect, color: annotationColor, strokeWidth: strokeWidth)
                    annotations.append(annotation)
                }
            }
            
            // Go back to select mode after drawing
            currentTool = .select
            
            annotationStart = nil
            annotationEnd = nil
            needsDisplay = true
        } else if isSelecting, let start = selectionStart, let end = selectionEnd {
            isSelecting = false
            let rect = rectFromPoints(start, end)
            
            // Minimum selection size - immediately complete
            if rect.width > 10 && rect.height > 10 {
                onSelectionComplete?(rect, annotations)
            }
            
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    
    // MARK: - Keyboard Events
    
    override func keyDown(with event: NSEvent) {
        // Consume all key events - don't pass through
        switch event.keyCode {
        case 53: // ESC
            onCancel?()
        case 15: // R - Rectangle tool
            currentTool = .rectangle
            updateCursor()
            needsDisplay = true
        case 51: // Delete - remove last annotation
            if !annotations.isEmpty {
                annotations.removeLast()
                needsDisplay = true
            }
        default:
            // Don't call super - consume all key events
            break
        }
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle key events here since performKeyEquivalent is called before keyDown
        switch event.keyCode {
        case 53: // ESC
            onCancel?()
            return true
        case 15: // R - Rectangle tool
            currentTool = .rectangle
            updateCursor()
            needsDisplay = true
            return true
        case 51: // Delete - remove last annotation
            if !annotations.isEmpty {
                annotations.removeLast()
                needsDisplay = true
            }
            return true
        default:
            return true // Still consume all other keys
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        return true
    }
}
