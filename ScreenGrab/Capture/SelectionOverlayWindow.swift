import AppKit
import QuartzCore
import CoreVideo

class SelectionOverlayWindow: NSPanel {
    var onSelectionComplete: ((CGRect, CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    private var screenFrame: CGRect = .zero
    private var selectionView: SelectionView?

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
        // Temporarily activate app to ensure cursor works, then set to accessory
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        orderFrontRegardless()
        makeKey()
        selectionView?.setupMonitors()

        // Set cursor after brief delay - starts in select mode with arrow cursor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.selectionView?.setInitialCursor()
        }
    }

    func stopEventMonitors() {
        selectionView?.stopMonitors()
    }

    override func close() {
        selectionView?.stopMonitors()
        selectionView?.onSelectionComplete = nil
        selectionView?.onCancel = nil
        super.close()
    }
}

enum CaptureMode {
    case select        // Move/edit existing annotations
    case regionSelect  // Draw screenshot capture area
    case rectangle     // Draw rectangle annotation
    case arrow         // Draw arrow annotation
}

class SelectionView: NSView {
    var onSelectionComplete: ((CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    private var currentMode: CaptureMode = .select {
        didSet {
            updateCursorForMode()
        }
    }
    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false
    private var annotations: [any Annotation] = []
    private var isDrawingAnnotation = false
    private var annotationStart: NSPoint?
    private var annotationEnd: NSPoint?
    private var currentDrawingTool: CaptureMode = .rectangle
    private var currentMousePosition: NSPoint?

    // Selection/dragging state
    private var selectedAnnotation: (any Annotation)?
    private var activeHandle: AnnotationHandle?
    private var isDraggingAnnotation = false
    private var dragStartPoint: NSPoint?
    private var dragStartBounds: CGRect?
    private var dragStartArrowStart: CGPoint?
    private var dragStartArrowEnd: CGPoint?

    // CALayer-based annotation rendering for smooth dragging
    private var annotationLayers: [UUID: CAShapeLayer] = [:]
    private var selectionHandleLayer: CAShapeLayer?

    private let annotationColor = NSColor.red.cgColor
    private let strokeWidth: CGFloat = 3.0

    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var coordLayer: CATextLayer?
    private var coordBgLayer: CALayer?
    private var crosshairCursor: NSCursor?
    private var coordTimer: Timer?

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
        // Disable implicit animations for immediate updates
        layer?.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "sublayers": NSNull(),
            "transform": NSNull(),
            "anchorPoint": NSNull()
        ]
        canDrawSubviewsIntoLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        createCrosshairCursor()
        setupTrackingArea()
        setupCoordLayer()
    }

    private func setupDisplayLink() {
        // Poll mouse position at 120Hz for smooth coordinate updates
        coordTimer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            let screenPos = NSEvent.mouseLocation
            let windowPos = window.convertPoint(fromScreen: screenPos)
            let viewPos = self.convert(windowPos, from: nil)
            self.updateCoordDisplay(at: viewPos)
        }
        if let timer = coordTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopDisplayLink() {
        coordTimer?.invalidate()
        coordTimer = nil
    }

    private func setupCoordLayer() {
        // Coords are now baked into cursor image - no separate layer needed
        // Keep empty layers to avoid nil checks elsewhere
        let bg = CALayer()
        bg.isHidden = true
        layer?.addSublayer(bg)
        coordBgLayer = bg

        let text = CATextLayer()
        text.isHidden = true
        layer?.addSublayer(text)
        coordLayer = text
    }

    private func createCrosshairCursor() {
        updateCursorWithCoords(NSPoint(x: 0, y: 0))
    }

    private func updateCursorWithCoords(_ point: NSPoint) {
        let crosshairSize: CGFloat = 33
        let center = crosshairSize / 2
        let armLength: CGFloat = 14
        let gap: CGFloat = 3

        // Coord text
        let coordText = "\(Int(point.x)), \(Int(point.y))"
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (coordText as NSString).size(withAttributes: attrs)

        // Text positioned to bottom-right of crosshair
        let textPadding: CGFloat = 4
        let textOffsetX: CGFloat = center + 8
        let textBoxHeight = textSize.height + textPadding
        let totalWidth = textOffsetX + textSize.width + textPadding * 2
        let bottomPadding: CGFloat = textBoxHeight + 4  // Space for text below crosshair
        let totalHeight = crosshairSize + bottomPadding

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        image.lockFocus()

        // Crosshair at top of image (NSImage y=0 is bottom)
        let crosshairCenterY = totalHeight - center

        // Black outline
        NSColor.black.setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = 5
        outline.move(to: NSPoint(x: center - armLength, y: crosshairCenterY))
        outline.line(to: NSPoint(x: center - gap, y: crosshairCenterY))
        outline.move(to: NSPoint(x: center + gap, y: crosshairCenterY))
        outline.line(to: NSPoint(x: center + armLength, y: crosshairCenterY))
        outline.move(to: NSPoint(x: center, y: crosshairCenterY - armLength))
        outline.line(to: NSPoint(x: center, y: crosshairCenterY - gap))
        outline.move(to: NSPoint(x: center, y: crosshairCenterY + gap))
        outline.line(to: NSPoint(x: center, y: crosshairCenterY + armLength))
        outline.stroke()

        // White inner line
        NSColor.white.setStroke()
        let inner = NSBezierPath()
        inner.lineWidth = 2
        inner.move(to: NSPoint(x: center - armLength, y: crosshairCenterY))
        inner.line(to: NSPoint(x: center - gap, y: crosshairCenterY))
        inner.move(to: NSPoint(x: center + gap, y: crosshairCenterY))
        inner.line(to: NSPoint(x: center + armLength, y: crosshairCenterY))
        inner.move(to: NSPoint(x: center, y: crosshairCenterY - armLength))
        inner.line(to: NSPoint(x: center, y: crosshairCenterY - gap))
        inner.move(to: NSPoint(x: center, y: crosshairCenterY + gap))
        inner.line(to: NSPoint(x: center, y: crosshairCenterY + armLength))
        inner.stroke()

        // Draw coord background at bottom-right
        let textY: CGFloat = 2  // Near bottom of image
        let bgRect = NSRect(x: textOffsetX - textPadding, y: textY,
                           width: textSize.width + textPadding * 2, height: textBoxHeight)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3).fill()

        // Draw coord text
        (coordText as NSString).draw(at: NSPoint(x: textOffsetX, y: textY + textPadding/2), withAttributes: attrs)

        image.unlockFocus()

        // Hotspot at crosshair center
        crosshairCursor = NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
        crosshairCursor?.set()
    }

    private func updateCoordDisplay(at point: NSPoint) {
        // Only show coords cursor in non-select modes
        if currentMode != .select {
            updateCursorWithCoords(point)
        }
    }

    private func updateCursorForMode() {
        if currentMode == .select {
            NSCursor.arrow.set()
        } else if let pos = currentMousePosition {
            updateCursorWithCoords(pos)
        } else {
            crosshairCursor?.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    private func hideCoordDisplay() {
        // No longer needed - coords are in cursor
    }

    deinit {
        stopMonitors()
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
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
            if let pos = currentMousePosition {
                updateCoordDisplay(at: pos)
            }
            window.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        if currentMode == .select {
            addCursorRect(bounds, cursor: .arrow)
        } else if let cursor = crosshairCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if currentMode == .select {
            NSCursor.arrow.set()
        } else {
            crosshairCursor?.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if currentMode == .select {
            NSCursor.arrow.set()
        } else {
            crosshairCursor?.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Don't reset cursor - we control cursor everywhere on our overlay
    }

    func setupMonitors() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
        window?.invalidateCursorRects(for: self)
        setupDisplayLink()
    }

    func setCrosshairCursor() {
        crosshairCursor?.set()
    }

    func setInitialCursor() {
        if currentMode == .select {
            NSCursor.arrow.set()
        } else {
            crosshairCursor?.set()
        }
    }

    func stopMonitors() {
        stopDisplayLink()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        NSCursor.arrow.set()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC - return to select mode or cancel
            if currentMode != .select {
                currentMode = .select
                needsDisplay = true
            } else {
                onCancel?()
            }
        case 48: // Tab - region select mode
            currentMode = .regionSelect
            needsDisplay = true
        case 15: // R - rectangle annotation mode
            currentMode = .rectangle
            needsDisplay = true
        case 0: // A - arrow annotation mode
            currentMode = .arrow
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

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hideCoordDisplay()

        switch currentMode {
        case .select:
            // Check if clicking on an annotation
            for annotation in annotations.reversed() {
                if let handle = annotation.hitTest(point: point) {
                    selectedAnnotation = annotation
                    activeHandle = handle
                    isDraggingAnnotation = true
                    dragStartPoint = point
                    dragStartBounds = annotation.bounds

                    if let arrow = annotation as? ArrowAnnotation {
                        dragStartArrowStart = arrow.startPoint
                        dragStartArrowEnd = arrow.endPoint
                    }

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    return
                }
            }
            // Clicked on nothing - deselect
            selectedAnnotation = nil
            selectionHandleLayer?.removeFromSuperlayer()
            selectionHandleLayer = nil
            needsDisplay = true
        case .regionSelect:
            selectionStart = point
            selectionEnd = point
            isSelecting = true
        case .rectangle, .arrow:
            isDrawingAnnotation = true
            currentDrawingTool = currentMode
            annotationStart = point
            annotationEnd = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingAnnotation, let selected = selectedAnnotation, let start = dragStartPoint {
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)

            // Disable implicit animations for immediate response
            CATransaction.begin()
            CATransaction.setDisableActions(true)

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

            // Update only the annotation layer, not the whole view
            updateAnnotationLayer(for: selected)
            updateSelectionHandlesLayer()

            CATransaction.commit()
        } else if isDrawingAnnotation {
            annotationEnd = point
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateDrawingPreviewLayer()
            CATransaction.commit()
        } else if isSelecting {
            selectionEnd = point
            display()
        }
    }

    override func mouseUp(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)

        if isDraggingAnnotation {
            isDraggingAnnotation = false
            dragStartPoint = nil
            dragStartBounds = nil
            dragStartArrowStart = nil
            dragStartArrowEnd = nil
            needsDisplay = true
        } else if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
            isDrawingAnnotation = false
            clearDrawingPreviewLayer()

            if currentDrawingTool == .arrow {
                let distance = hypot(end.x - start.x, end.y - start.y)
                if distance > 10 {
                    let annotation = ArrowAnnotation(
                        startPoint: start, endPoint: end,
                        color: annotationColor, strokeWidth: strokeWidth
                    )
                    annotations.append(annotation)
                    syncAnnotationLayers()
                }
            } else {
                let rect = rectFromPoints(start, end)
                if rect.width > 5 && rect.height > 5 {
                    let annotation = RectangleAnnotation(
                        bounds: rect, color: annotationColor, strokeWidth: strokeWidth
                    )
                    annotations.append(annotation)
                    syncAnnotationLayers()
                }
            }

            currentMode = .select
            annotationStart = nil
            annotationEnd = nil
            needsDisplay = true
        } else if isSelecting, let start = selectionStart, let end = selectionEnd {
            isSelecting = false
            let rect = rectFromPoints(start, end)

            if rect.width > 10 && rect.height > 10 {
                onSelectionComplete?(rect, annotations)
            }

            currentMode = .select
            selectionStart = nil
            selectionEnd = nil
        }

        if let pos = currentMousePosition {
            updateCoordDisplay(at: pos)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)
        // Coord display updated by 120Hz timer
        if currentMode == .select {
            NSCursor.arrow.set()
        } else {
            crosshairCursor?.set()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()

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

        // Annotations are now drawn via CAShapeLayers for smooth dragging
        // Selection handles are also drawn via CAShapeLayers

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
        switch currentMode {
        case .rectangle:
            modeText = "🔴 RECTANGLE MODE"
            modeColor = NSColor.systemRed
        case .arrow:
            modeText = "➡️ ARROW MODE"
            modeColor = NSColor.systemOrange
        case .select:
            modeText = "🔲 SELECT MODE"
            modeColor = NSColor.white
        case .regionSelect:
            modeText = "✂️ REGION SELECT"
            modeColor = NSColor.systemBlue
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
        switch currentMode {
        case .rectangle:
            text = "Drag to draw rectangle • ESC: Back to select"
        case .arrow:
            text = "Drag to draw arrow • ESC: Back to select"
        case .select:
            text = "Tab: Region select • R: Rectangle • A: Arrow • ESC: Cancel"
        case .regionSelect:
            text = "Drag to select & capture • ESC: Back to select"
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

    private func drawSelectionHandles(for annotation: any Annotation, in context: CGContext) {
        let handleSize: CGFloat = 8
        let handleColor = NSColor.systemBlue.cgColor

        context.setFillColor(handleColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)

        if let arrow = annotation as? ArrowAnnotation {
            // Draw circular handles at arrow endpoints
            let startHandle = CGRect(
                x: arrow.startPoint.x - handleSize/2,
                y: arrow.startPoint.y - handleSize/2,
                width: handleSize,
                height: handleSize
            )
            let endHandle = CGRect(
                x: arrow.endPoint.x - handleSize/2,
                y: arrow.endPoint.y - handleSize/2,
                width: handleSize,
                height: handleSize
            )
            context.fillEllipse(in: startHandle)
            context.strokeEllipse(in: startHandle)
            context.fillEllipse(in: endHandle)
            context.strokeEllipse(in: endHandle)
        } else {
            // Draw square handles at corners for rectangles
            let bounds = annotation.bounds
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

    // MARK: - CALayer-based Annotation Rendering

    private func createAnnotationLayer(for annotation: any Annotation) -> CAShapeLayer {
        let shapeLayer = CAShapeLayer()
        shapeLayer.strokeColor = annotation.color
        shapeLayer.fillColor = nil
        shapeLayer.lineWidth = annotation.strokeWidth
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        // Disable implicit animations
        shapeLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        updateLayerPath(shapeLayer, for: annotation)
        return shapeLayer
    }

    private func updateLayerPath(_ shapeLayer: CAShapeLayer, for annotation: any Annotation) {
        let path = CGMutablePath()

        if let arrow = annotation as? ArrowAnnotation {
            // Draw arrow line
            path.move(to: arrow.startPoint)
            path.addLine(to: arrow.endPoint)

            // Draw arrow head
            let angle = atan2(arrow.endPoint.y - arrow.startPoint.y, arrow.endPoint.x - arrow.startPoint.x)
            let arrowHeadLength: CGFloat = 20.0
            let arrowHeadAngle: CGFloat = .pi / 6

            let arrowPoint1 = CGPoint(
                x: arrow.endPoint.x - arrowHeadLength * cos(angle + arrowHeadAngle),
                y: arrow.endPoint.y - arrowHeadLength * sin(angle + arrowHeadAngle)
            )
            let arrowPoint2 = CGPoint(
                x: arrow.endPoint.x - arrowHeadLength * cos(angle - arrowHeadAngle),
                y: arrow.endPoint.y - arrowHeadLength * sin(angle - arrowHeadAngle)
            )
            path.move(to: arrow.endPoint)
            path.addLine(to: arrowPoint1)
            path.move(to: arrow.endPoint)
            path.addLine(to: arrowPoint2)

            shapeLayer.fillColor = nil
        } else {
            // Rectangle
            path.addRect(annotation.bounds)
        }

        shapeLayer.path = path
    }

    private func updateAnnotationLayer(for annotation: any Annotation) {
        guard let shapeLayer = annotationLayers[annotation.id] else { return }
        updateLayerPath(shapeLayer, for: annotation)
    }

    private func updateSelectionHandlesLayer() {
        selectionHandleLayer?.removeFromSuperlayer()

        guard let selected = selectedAnnotation else { return }

        let handleLayer = CAShapeLayer()
        handleLayer.fillColor = NSColor.systemBlue.cgColor
        handleLayer.strokeColor = NSColor.white.cgColor
        handleLayer.lineWidth = 1
        handleLayer.actions = ["path": NSNull(), "position": NSNull()]

        let path = CGMutablePath()
        let handleSize: CGFloat = 8

        if let arrow = selected as? ArrowAnnotation {
            path.addEllipse(in: CGRect(
                x: arrow.startPoint.x - handleSize/2,
                y: arrow.startPoint.y - handleSize/2,
                width: handleSize, height: handleSize
            ))
            path.addEllipse(in: CGRect(
                x: arrow.endPoint.x - handleSize/2,
                y: arrow.endPoint.y - handleSize/2,
                width: handleSize, height: handleSize
            ))
        } else {
            let bounds = selected.bounds
            let corners = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY)
            ]
            for corner in corners {
                path.addRect(CGRect(
                    x: corner.x - handleSize/2,
                    y: corner.y - handleSize/2,
                    width: handleSize, height: handleSize
                ))
            }
        }

        handleLayer.path = path
        layer?.addSublayer(handleLayer)
        selectionHandleLayer = handleLayer
    }

    private var drawingPreviewLayer: CAShapeLayer?

    private func updateDrawingPreviewLayer() {
        if drawingPreviewLayer == nil {
            let previewLayer = CAShapeLayer()
            previewLayer.strokeColor = annotationColor
            previewLayer.fillColor = nil
            previewLayer.lineWidth = strokeWidth
            previewLayer.lineCap = .round
            previewLayer.actions = ["path": NSNull()]
            layer?.addSublayer(previewLayer)
            drawingPreviewLayer = previewLayer
        }

        guard let start = annotationStart, let end = annotationEnd else { return }

        let path = CGMutablePath()
        if currentDrawingTool == .arrow {
            path.move(to: start)
            path.addLine(to: end)

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
            path.move(to: end)
            path.addLine(to: arrowPoint1)
            path.move(to: end)
            path.addLine(to: arrowPoint2)
        } else {
            let rect = rectFromPoints(start, end)
            path.addRect(rect)
        }

        drawingPreviewLayer?.path = path
    }

    private func clearDrawingPreviewLayer() {
        drawingPreviewLayer?.removeFromSuperlayer()
        drawingPreviewLayer = nil
    }

    private func syncAnnotationLayers() {
        // Remove old layers
        for (id, layer) in annotationLayers {
            if !annotations.contains(where: { $0.id == id }) {
                layer.removeFromSuperlayer()
                annotationLayers.removeValue(forKey: id)
            }
        }

        // Add/update layers for current annotations
        for annotation in annotations {
            if let existingLayer = annotationLayers[annotation.id] {
                updateLayerPath(existingLayer, for: annotation)
            } else {
                let newLayer = createAnnotationLayer(for: annotation)
                layer?.addSublayer(newLayer)
                annotationLayers[annotation.id] = newLayer
            }
        }
    }
}
