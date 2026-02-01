import AppKit
import QuartzCore

class SelectionOverlayWindow: NSPanel {
    var onSelectionComplete: ((CGRect, CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    private var screenFrame: CGRect = .zero
    private var selectionView: SelectionView?

    // Allow becoming key to receive mouse events, but don't become main
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        self.hidesOnDeactivate = false
        self.hasShadow = false
        self.isFloatingPanel = true

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

    func show() {
        orderFrontRegardless()
        makeKey()
        selectionView?.setupMonitors()
        selectionView?.setCrosshairCursor()
    }

    func stopEventMonitors() {
        selectionView?.stopMonitors()
        selectionView?.resetCursor()
    }

    override func close() {
        selectionView?.stopMonitors()
        selectionView?.resetCursor()
        selectionView?.onSelectionComplete = nil
        selectionView?.onCancel = nil
        super.close()
    }
}

enum SelectionTool {
    case select
    case rectangle
    case arrow
}

class SelectionView: NSView {
    var onSelectionComplete: ((CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?

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
    private var currentDrawingTool: SelectionTool = .rectangle

    private var currentMousePosition: NSPoint?

    private let annotationColor = NSColor.red.cgColor
    private let strokeWidth: CGFloat = 3.0

    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var crosshairCursor: NSCursor?
    private var coordLayer: CATextLayer?
    private var coordBgLayer: CALayer?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.drawsAsynchronously = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        canDrawSubviewsIntoLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupTrackingArea()
        createCrosshairCursor()
        setupCoordLayer()
    }
    
    private func setupCoordLayer() {
        // Background layer
        let bg = CALayer()
        bg.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        bg.cornerRadius = 3
        bg.actions = ["position": NSNull(), "bounds": NSNull()]  // Disable animations
        layer?.addSublayer(bg)
        coordBgLayer = bg
        
        // Text layer
        let text = CATextLayer()
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.fontSize = 11
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .left
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        text.actions = ["position": NSNull(), "bounds": NSNull(), "string": NSNull()]
        layer?.addSublayer(text)
        coordLayer = text
    }
    
    private func updateCoordDisplay(at point: NSPoint) {
        guard let textLayer = coordLayer, let bgLayer = coordBgLayer else { return }
        
        let coordText = "\(Int(point.x)), \(Int(point.y))"
        textLayer.string = coordText
        
        // Calculate size
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (coordText as NSString).size(withAttributes: attrs)
        
        let padding: CGFloat = 4
        let offsetX: CGFloat = 18
        let offsetY: CGFloat = 12
        
        // Position layers (CALayer uses bottom-left origin like NSView)
        let x = point.x + offsetX
        let y = point.y - textSize.height - offsetY
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = CGRect(x: x - padding, y: y - padding/2, 
                                width: textSize.width + padding * 2, height: textSize.height + padding)
        textLayer.frame = CGRect(x: x, y: y, width: textSize.width + 10, height: textSize.height + 4)
        CATransaction.commit()
    }

    deinit {
        stopMonitors()
    }
    
    private func createCrosshairCursor() {
        let size: CGFloat = 31  // Odd number for center pixel
        let center = size / 2
        let armLength: CGFloat = 13
        let gap: CGFloat = 2
        let lineWidth: CGFloat = 1.0
        let outlineWidth: CGFloat = 3.0
        
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        
        // Draw black outline
        NSColor.black.setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = outlineWidth
        // Horizontal
        outline.move(to: NSPoint(x: center - armLength, y: center))
        outline.line(to: NSPoint(x: center - gap, y: center))
        outline.move(to: NSPoint(x: center + gap, y: center))
        outline.line(to: NSPoint(x: center + armLength, y: center))
        // Vertical
        outline.move(to: NSPoint(x: center, y: center - armLength))
        outline.line(to: NSPoint(x: center, y: center - gap))
        outline.move(to: NSPoint(x: center, y: center + gap))
        outline.line(to: NSPoint(x: center, y: center + armLength))
        outline.stroke()
        
        // Draw white line on top
        NSColor.white.setStroke()
        let inner = NSBezierPath()
        inner.lineWidth = lineWidth
        // Horizontal
        inner.move(to: NSPoint(x: center - armLength, y: center))
        inner.line(to: NSPoint(x: center - gap, y: center))
        inner.move(to: NSPoint(x: center + gap, y: center))
        inner.line(to: NSPoint(x: center + armLength, y: center))
        // Vertical
        inner.move(to: NSPoint(x: center, y: center - armLength))
        inner.line(to: NSPoint(x: center, y: center - gap))
        inner.move(to: NSPoint(x: center, y: center + gap))
        inner.line(to: NSPoint(x: center, y: center + armLength))
        inner.stroke()
        
        image.unlockFocus()
        
        crosshairCursor = NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }
    
    func setCrosshairCursor() {
        crosshairCursor?.set()
    }
    
    func resetCursor() {
        NSCursor.arrow.set()
    }
    
    override func resetCursorRects() {
        if let cursor = crosshairCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }
    
    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            let screenPos = NSEvent.mouseLocation
            let windowPos = window.convertPoint(fromScreen: screenPos)
            currentMousePosition = convert(windowPos, from: nil)
            needsDisplay = true
        }
    }

    func setupMonitors() {
        // Global keyboard monitor (works even when not focused)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // Local keyboard monitor (when focused)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    func stopMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        NSCursor.unhide()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            if currentTool != .select {
                currentTool = .select
                needsDisplay = true
            } else {
                onCancel?()
            }
        case 15: // R
            currentTool = .rectangle
            needsDisplay = true
        case 0: // A
            currentTool = .arrow
            needsDisplay = true
        case 51: // Delete
            if !annotations.isEmpty {
                annotations.removeLast()
                needsDisplay = true
            }
        default:
            break
        }
    }

    // MARK: - Mouse Events (standard NSView)
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if currentTool == .rectangle || currentTool == .arrow {
            isDrawingAnnotation = true
            currentDrawingTool = currentTool
            annotationStart = point
            annotationEnd = point
        } else {
            selectionStart = point
            selectionEnd = point
            isSelecting = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDrawingAnnotation {
            annotationEnd = point
        } else if isSelecting {
            selectionEnd = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)

        if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
            isDrawingAnnotation = false

            if currentDrawingTool == .arrow {
                let distance = hypot(end.x - start.x, end.y - start.y)
                if distance > 10 {
                    let annotation = ArrowAnnotation(
                        startPoint: start, endPoint: end,
                        color: annotationColor, strokeWidth: strokeWidth
                    )
                    annotations.append(annotation)
                }
            } else {
                let rect = rectFromPoints(start, end)
                if rect.width > 5 && rect.height > 5 {
                    let annotation = RectangleAnnotation(
                        bounds: rect, color: annotationColor, strokeWidth: strokeWidth
                    )
                    annotations.append(annotation)
                }
            }

            currentTool = .select
            annotationStart = nil
            annotationEnd = nil
        } else if isSelecting, let start = selectionStart, let end = selectionEnd {
            isSelecting = false
            let rect = rectFromPoints(start, end)

            if rect.width > 10 && rect.height > 10 {
                onSelectionComplete?(rect, annotations)
            }

            selectionStart = nil
            selectionEnd = nil
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)
        // Only update the coord layer, don't redraw entire view
        if let pos = currentMousePosition, !isSelecting && !isDrawingAnnotation {
            updateCoordDisplay(at: pos)
            coordLayer?.isHidden = false
            coordBgLayer?.isHidden = false
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
        
        // Hide coord layers during selection/drawing (will show via mouseMoved when idle)
        if isSelecting || isDrawingAnnotation {
            coordLayer?.isHidden = true
            coordBgLayer?.isHidden = true
        }

        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = rectFromPoints(start, end)

            NSColor.clear.setFill()
            rect.fill(using: .copy)

            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 2
            borderPath.stroke()

            NSColor.black.setStroke()
            let dashedPath = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            dashedPath.lineWidth = 1
            dashedPath.setLineDash([4, 4], count: 2, phase: 0)
            dashedPath.stroke()

            drawSizeLabel(for: rect)
        }

        if let context = NSGraphicsContext.current?.cgContext {
            for annotation in annotations {
                annotation.draw(in: context)
            }

            if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
                context.setStrokeColor(annotationColor)
                context.setLineWidth(strokeWidth)

                if currentDrawingTool == .arrow {
                    context.setFillColor(annotationColor)
                    context.setLineCap(.round)
                    context.move(to: start)
                    context.addLine(to: end)
                    context.strokePath()

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
                    let rect = rectFromPoints(start, end)
                    context.stroke(rect)
                }
            }
        }

        drawInstructions()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
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
            y: bounds.height - 120
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

        var text: String
        switch currentTool {
        case .rectangle:
            text = "Drag to draw rectangle • ESC: Back to select"
        case .arrow:
            text = "Drag to draw arrow • ESC: Back to select"
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
            y: bounds.height - 80
        )

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
}
