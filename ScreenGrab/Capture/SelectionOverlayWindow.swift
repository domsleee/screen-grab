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
    case text          // Place text annotation
}

class SelectionView: NSView {
    var onSelectionComplete: ((CGRect, [any Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    private var currentMode: CaptureMode = .regionSelect {
        didSet {
            // Commit any in-progress text annotation when switching modes
            if oldValue == .text && currentMode != .text {
                commitTextAnnotation()
            }
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

    // Text editing state
    private var editingTextAnnotation: TextAnnotation?
    private var editingTextLayer: CATextLayer?

    // Hover-to-select in drawing modes
    private var hoveredAnnotation: (any Annotation)?
    private var hoverHighlightLayer: CAShapeLayer?

    // CALayer-based annotation rendering for smooth dragging
    private var annotationLayers: [UUID: CALayer] = [:]
    private var selectionHandleLayer: CAShapeLayer?

    private var annotationColor = NSColor.red.cgColor
    private let strokeWidth: CGFloat = 3.0

    private let colorPalette: [NSColor] = [
        .red, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .white, .lightGray, .gray, .darkGray, .black, .systemPink,
    ]

    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var coordLayer: CATextLayer?
    private var coordBgLayer: CALayer?
    private var crosshairCursor: NSCursor?
    private var coordTimer: Timer?

    // Custom diagonal resize cursors (macOS has no native ones)
    private lazy var nwseResizeCursor: NSCursor = {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setStroke()
        NSColor.black.withAlphaComponent(0.8).setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        // NW-SE diagonal line
        path.move(to: NSPoint(x: 3, y: size - 3))
        path.line(to: NSPoint(x: size - 3, y: 3))
        // NW arrowhead
        path.move(to: NSPoint(x: 3, y: size - 3))
        path.line(to: NSPoint(x: 3, y: size - 7))
        path.move(to: NSPoint(x: 3, y: size - 3))
        path.line(to: NSPoint(x: 7, y: size - 3))
        // SE arrowhead
        path.move(to: NSPoint(x: size - 3, y: 3))
        path.line(to: NSPoint(x: size - 3, y: 7))
        path.move(to: NSPoint(x: size - 3, y: 3))
        path.line(to: NSPoint(x: size - 7, y: 3))
        // Draw black outline first, then white
        NSColor.black.setStroke()
        let outline = path.copy() as! NSBezierPath
        outline.lineWidth = 3.0
        outline.stroke()
        NSColor.white.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    private lazy var neswResizeCursor: NSCursor = {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        // NE-SW diagonal line
        path.move(to: NSPoint(x: size - 3, y: size - 3))
        path.line(to: NSPoint(x: 3, y: 3))
        // NE arrowhead
        path.move(to: NSPoint(x: size - 3, y: size - 3))
        path.line(to: NSPoint(x: size - 7, y: size - 3))
        path.move(to: NSPoint(x: size - 3, y: size - 3))
        path.line(to: NSPoint(x: size - 3, y: size - 7))
        // SW arrowhead
        path.move(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 3))
        path.move(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 3, y: 7))
        // Draw black outline first, then white
        NSColor.black.setStroke()
        let outline = path.copy() as! NSBezierPath
        outline.lineWidth = 3.0
        outline.stroke()
        NSColor.white.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

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
        // Load saved color
        if let rgba = AppSettings.shared.annotationColorRGBA, rgba.count == 4 {
            annotationColor = CGColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
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
        // Poll mouse position at 120Hz for smooth coordinate updates and hover detection
        coordTimer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            let screenPos = NSEvent.mouseLocation
            let windowPos = window.convertPoint(fromScreen: screenPos)
            let viewPos = self.convert(windowPos, from: nil)
            self.currentMousePosition = viewPos
            self.updateHoverState(at: viewPos)
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
        // Just create the cursor image, don't set it (we start in select mode with arrow cursor)
        buildCrosshairCursor(at: NSPoint(x: 0, y: 0))
    }

    private func buildCrosshairCursor(at point: NSPoint) {
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
    }

    private func updateCursorWithCoords(_ point: NSPoint) {
        // Guard against calling from contexts where font operations may crash
        guard let _ = window else { return }
        buildCrosshairCursor(at: point)
        crosshairCursor?.set()
    }

    /// Returns the full visual bounding rect for an annotation, including arrowhead extent.
    private func visualBounds(for annotation: any Annotation) -> CGRect {
        if let arrow = annotation as? ArrowAnnotation {
            let angle = atan2(arrow.endPoint.y - arrow.startPoint.y, arrow.endPoint.x - arrow.startPoint.x)
            let arrowPoint1 = CGPoint(
                x: arrow.endPoint.x - arrow.arrowHeadLength * cos(angle + arrow.arrowHeadAngle),
                y: arrow.endPoint.y - arrow.arrowHeadLength * sin(angle + arrow.arrowHeadAngle)
            )
            let arrowPoint2 = CGPoint(
                x: arrow.endPoint.x - arrow.arrowHeadLength * cos(angle - arrow.arrowHeadAngle),
                y: arrow.endPoint.y - arrow.arrowHeadLength * sin(angle - arrow.arrowHeadAngle)
            )
            let allX = [arrow.startPoint.x, arrow.endPoint.x, arrowPoint1.x, arrowPoint2.x]
            let allY = [arrow.startPoint.y, arrow.endPoint.y, arrowPoint1.y, arrowPoint2.y]
            return CGRect(
                x: allX.min()!, y: allY.min()!,
                width: allX.max()! - allX.min()!, height: allY.max()! - allY.min()!
            )
        }
        return annotation.bounds
    }

    private func updateHoverState(at point: NSPoint) {
        guard !isDraggingAnnotation && !isDrawingAnnotation else { return }

        // Select mode: show handle-aware cursors and hover highlights
        if currentMode == .select {
            // Check selected annotation handles first
            if let selected = selectedAnnotation, let handle = selected.hitTest(point: point) {
                // Hovering the selected annotation — no dashed highlight needed (handles are visible)
                if hoveredAnnotation != nil {
                    hoveredAnnotation = nil
                    updateHoverHighlightLayer()
                }
                cursorForHandle(handle).set()
                return
            }

            // Check if hovering over any annotation
            var foundAnnotation: (any Annotation)?
            for annotation in annotations.reversed() {
                let rect = visualBounds(for: annotation).insetBy(dx: -4, dy: -4)
                if rect.contains(point) {
                    foundAnnotation = annotation
                    break
                }
            }

            if let found = foundAnnotation {
                // Show dashed highlight for hovered annotation (if not the selected one)
                if found.id != selectedAnnotation?.id {
                    if hoveredAnnotation?.id != found.id {
                        hoveredAnnotation = found
                        updateHoverHighlightLayer()
                    }
                } else if hoveredAnnotation != nil {
                    hoveredAnnotation = nil
                    updateHoverHighlightLayer()
                }
                NSCursor.openHand.set()
                return
            }

            // Hovering nothing
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                updateHoverHighlightLayer()
            }
            NSCursor.arrow.set()
            return
        }

        // Drawing modes: hover-to-select with highlight
        guard currentMode == .rectangle || currentMode == .arrow || currentMode == .text else {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                updateHoverHighlightLayer()
            }
            return
        }

        // Use bounding rect for hover detection — much broader than hitTest line proximity
        var foundAnnotation: (any Annotation)?
        for annotation in annotations.reversed() {
            let rect = visualBounds(for: annotation).insetBy(dx: -4, dy: -4)
            if rect.contains(point) {
                foundAnnotation = annotation
                break
            }
        }

        if let found = foundAnnotation {
            if hoveredAnnotation?.id != found.id {
                hoveredAnnotation = found
                updateHoverHighlightLayer()
            }
            NSCursor.arrow.set()
        } else {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                updateHoverHighlightLayer()
            }
        }
    }

    private func updateCoordDisplay(at point: NSPoint) {
        // Show iBeam when editing text
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
            return
        }
        // Only show coords cursor in non-select modes, and not when hovering over an annotation
        if currentMode != .select && hoveredAnnotation == nil {
            updateCursorWithCoords(point)
        }
    }

    private func updateCursorForMode() {
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
        } else if currentMode == .select {
            NSCursor.arrow.set()
        } else if let pos = currentMousePosition {
            updateCursorWithCoords(pos)
        } else {
            crosshairCursor?.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    private func cursorForHandle(_ handle: AnnotationHandle, isDragging: Bool = false) -> NSCursor {
        switch handle {
        case .body:
            return isDragging ? .closedHand : .openHand
        case .topLeft, .bottomRight:
            return nwseResizeCursor
        case .topRight, .bottomLeft:
            return neswResizeCursor
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .startPoint, .endPoint:
            return .crosshair
        }
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
            // Don't set a fixed cursor rect — hover state manages cursors dynamically
        } else if let cursor = crosshairCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
        } else if currentMode == .select {
            // Let hover state manage cursor — just do a quick update
            if let pos = currentMousePosition {
                updateHoverState(at: pos)
            } else {
                NSCursor.arrow.set()
            }
        } else {
            crosshairCursor?.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
        } else if currentMode == .select {
            // Let hover state manage cursor
            if let pos = currentMousePosition {
                updateHoverState(at: pos)
            } else {
                NSCursor.arrow.set()
            }
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
        // If we're editing text, handle text input instead of shortcuts
        if editingTextAnnotation != nil {
            handleTextKeyEvent(event)
            return
        }

        switch event.keyCode {
        case 53: // ESC - cancel
            onCancel?()
        case 1: // S - select mode
            currentMode = .select
            needsDisplay = true
        case 48: // Tab - region select mode
            currentMode = .regionSelect
            needsDisplay = true
        case 15: // R - rectangle annotation mode
            currentMode = .rectangle
            needsDisplay = true
        case 0: // A - arrow annotation mode
            currentMode = .arrow
            needsDisplay = true
        case 17: // T - text annotation mode
            currentMode = .text
            needsDisplay = true
        case 51: // Delete
            if let selected = selectedAnnotation {
                annotations.removeAll { $0.id == selected.id }
                selectedAnnotation = nil
                selectionHandleLayer?.removeFromSuperlayer()
                selectionHandleLayer = nil
                syncAnnotationLayers()
                needsDisplay = true
            }
        default:
            break
        }
    }

    private func handleTextKeyEvent(_ event: NSEvent) {
        guard let annotation = editingTextAnnotation else { return }

        switch event.keyCode {
        case 53: // ESC - cancel current text (discard)
            editingTextLayer?.removeFromSuperlayer()
            editingTextLayer = nil
            editingTextAnnotation = nil
        case 36, 76: // Return / Enter - commit text
            commitTextAnnotation()
        case 51: // Delete/Backspace
            if !annotation.text.isEmpty {
                annotation.text = String(annotation.text.dropLast())
                updateEditingTextLayer()
            }
        default:
            // Append typed characters
            if let chars = event.characters, !chars.isEmpty {
                // Filter out control characters — keep printable characters only
                let filtered = chars.filter { char in
                    if char.isNewline { return false }
                    if let ascii = char.asciiValue { return ascii >= 32 }
                    return true // non-ASCII (emoji, unicode) is fine
                }
                if !filtered.isEmpty {
                    annotation.text += filtered
                    updateEditingTextLayer()
                }
            }
        }
    }

    private func beginEditingTextAnnotation(_ annotation: TextAnnotation) {
        // Remove from committed annotations and its layer
        annotations.removeAll { $0.id == annotation.id }
        annotationLayers[annotation.id]?.removeFromSuperlayer()
        annotationLayers.removeValue(forKey: annotation.id)

        // Clear selection state
        selectedAnnotation = nil
        selectionHandleLayer?.removeFromSuperlayer()
        selectionHandleLayer = nil

        // Enter text editing mode
        editingTextAnnotation = annotation
        let textLayer = createEditingTextLayer(for: annotation)
        // Show current text with cursor
        let displayText = annotation.text + "|"
        let attrs = annotation.textAttributes()
        textLayer.string = NSAttributedString(string: displayText, attributes: attrs)
        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + 2,
                                     y: annotation.position.y + size.height / 2 + 2)
        layer?.addSublayer(textLayer)
        editingTextLayer = textLayer

        currentMode = .text
        needsDisplay = true
    }

    private func commitTextAnnotation() {
        guard let annotation = editingTextAnnotation else { return }

        // Remove the editing layer
        editingTextLayer?.removeFromSuperlayer()
        editingTextLayer = nil
        editingTextAnnotation = nil

        // Only add if text is non-empty
        if !annotation.text.isEmpty {
            annotations.append(annotation)
            syncAnnotationLayers()
        }

        needsDisplay = true
    }

    private func updateEditingTextLayer() {
        guard let annotation = editingTextAnnotation, let textLayer = editingTextLayer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let displayText = annotation.text.isEmpty ? "|" : annotation.text + "|"
        let attrs = annotation.textAttributes()
        textLayer.string = NSAttributedString(string: displayText, attributes: attrs)

        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + 2,
                                     y: annotation.position.y + size.height / 2 + 2)

        CATransaction.commit()
    }

    private func createEditingTextLayer(for annotation: TextAnnotation) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.alignmentMode = .left
        textLayer.contentsScale = window?.screen?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = false
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull()]

        // Use attributed string for reliable rendering
        let displayText = "|"
        let attrs = annotation.textAttributes()
        textLayer.string = NSAttributedString(string: displayText, attributes: attrs)

        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + 2,
                                     y: annotation.position.y + size.height / 2 + 2)

        return textLayer
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hideCoordDisplay()

        // Check toolbar clicks first
        if handleToolbarClick(at: point) {
            return
        }

        // Clear hover state on any mouse down
        hoveredAnnotation = nil
        updateHoverHighlightLayer()

        switch currentMode {
        case .select:
            // Double-click on a text annotation to edit it
            if event.clickCount == 2 {
                for annotation in annotations.reversed() {
                    if let textAnnotation = annotation as? TextAnnotation,
                       textAnnotation.contains(point: point) {
                        beginEditingTextAnnotation(textAnnotation)
                        return
                    }
                }
            }

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

                    cursorForHandle(handle, isDragging: true).set()

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
            // Check if clicking on an existing annotation (use bounding rect, not line proximity)
            for annotation in annotations.reversed() {
                let rect = visualBounds(for: annotation).insetBy(dx: -4, dy: -4)
                if rect.contains(point) {
                    selectedAnnotation = annotation
                    // Use precise hitTest for endpoint/corner handles, fall back to .body
                    let handle = annotation.hitTest(point: point) ?? .body
                    activeHandle = handle
                    isDraggingAnnotation = true
                    dragStartPoint = point
                    dragStartBounds = annotation.bounds

                    if let arrow = annotation as? ArrowAnnotation {
                        dragStartArrowStart = arrow.startPoint
                        dragStartArrowEnd = arrow.endPoint
                    }

                    cursorForHandle(handle, isDragging: true).set()

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    needsDisplay = true
                    return
                }
            }

            // No annotation hit — start drawing new one
            isDrawingAnnotation = true
            currentDrawingTool = currentMode
            annotationStart = point
            annotationEnd = point
        case .text:
            // If currently editing, commit first
            if editingTextAnnotation != nil {
                commitTextAnnotation()
            }

            // Check if clicking on an existing annotation (use bounding rect)
            for annotation in annotations.reversed() {
                let rect = visualBounds(for: annotation).insetBy(dx: -4, dy: -4)
                if rect.contains(point) {
                    // Double-click on text to edit it
                    if event.clickCount == 2, let textAnnotation = annotation as? TextAnnotation {
                        beginEditingTextAnnotation(textAnnotation)
                        return
                    }
                    selectedAnnotation = annotation
                    let handle = annotation.hitTest(point: point) ?? .body
                    activeHandle = handle
                    isDraggingAnnotation = true
                    dragStartPoint = point
                    dragStartBounds = annotation.bounds

                    if let arrow = annotation as? ArrowAnnotation {
                        dragStartArrowStart = arrow.startPoint
                        dragStartArrowEnd = arrow.endPoint
                    }

                    cursorForHandle(handle, isDragging: true).set()

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    needsDisplay = true
                    return
                }
            }

            // No annotation hit — start a new text annotation at click position
            let annotation = TextAnnotation(position: point, color: annotationColor)
            editingTextAnnotation = annotation

            let textLayer = createEditingTextLayer(for: annotation)
            layer?.addSublayer(textLayer)
            editingTextLayer = textLayer
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingAnnotation, let selected = selectedAnnotation, let start = dragStartPoint {
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)

            // Keep the drag cursor locked
            if let handle = activeHandle {
                cursorForHandle(handle, isDragging: true).set()
            }

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

            // Restore cursor for current mode
            if currentMode == .select {
                // Check what's under the mouse now for hover cursor
                if let pos = currentMousePosition, let selected = selectedAnnotation,
                   let handle = selected.hitTest(point: pos) {
                    cursorForHandle(handle).set()
                } else {
                    NSCursor.arrow.set()
                }
            } else {
                updateCursorForMode()
            }
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
        // Hover detection and coord display handled by 120Hz timer
        // In select mode, cursor is managed by updateHoverState
        if currentMode != .select && hoveredAnnotation == nil {
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

        drawToolbar()
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

    // MARK: - Toolbar

    private struct ToolbarButton {
        let mode: CaptureMode
        let icon: String  // SF Symbol name
        let shortcut: String
        let label: String
    }

    private let toolbarButtons: [ToolbarButton] = [
        ToolbarButton(mode: .regionSelect, icon: "crop", shortcut: "Tab", label: "Region"),
        ToolbarButton(mode: .select, icon: "cursorarrow", shortcut: "S", label: "Select"),
        ToolbarButton(mode: .rectangle, icon: "rectangle", shortcut: "R", label: "Rect"),
        ToolbarButton(mode: .arrow, icon: "arrow.up.right", shortcut: "A", label: "Arrow"),
        ToolbarButton(mode: .text, icon: "textformat", shortcut: "T", label: "Text"),
    ]

    private let toolbarButtonSize: CGFloat = 40
    private let toolbarSpacing: CGFloat = 4
    private let toolbarPadding: CGFloat = 6

    private let colorDividerGap: CGFloat = 8
    private var isColorPopoverVisible = false

    private func toolbarRect() -> NSRect {
        let count = CGFloat(toolbarButtons.count)
        let buttonsWidth = count * toolbarButtonSize + (count - 1) * toolbarSpacing
        // One color button after divider
        let totalWidth = buttonsWidth + colorDividerGap + toolbarButtonSize + toolbarPadding * 2
        let totalHeight = toolbarButtonSize + toolbarPadding * 2
        return NSRect(
            x: bounds.midX - totalWidth / 2,
            y: bounds.height - 60 - totalHeight,
            width: totalWidth,
            height: totalHeight
        )
    }

    private func rectForToolbarButton(at index: Int) -> NSRect {
        let toolbar = toolbarRect()
        let x = toolbar.minX + toolbarPadding + CGFloat(index) * (toolbarButtonSize + toolbarSpacing)
        let y = toolbar.minY + toolbarPadding
        return NSRect(x: x, y: y, width: toolbarButtonSize, height: toolbarButtonSize)
    }

    private func colorButtonRect() -> NSRect {
        let toolbar = toolbarRect()
        let count = CGFloat(toolbarButtons.count)
        let x = toolbar.minX + toolbarPadding + count * (toolbarButtonSize + toolbarSpacing) - toolbarSpacing + colorDividerGap
        let y = toolbar.minY + toolbarPadding
        return NSRect(x: x, y: y, width: toolbarButtonSize, height: toolbarButtonSize)
    }

    // Color popover layout
    private let popoverSwatchSize: CGFloat = 22
    private let popoverSwatchSpacing: CGFloat = 6
    private let popoverPadding: CGFloat = 10
    private let popoverColumns = 6

    private func colorPopoverRect() -> NSRect {
        let btnRect = colorButtonRect()
        let rows = ceil(CGFloat(colorPalette.count) / CGFloat(popoverColumns))
        let gridWidth = CGFloat(popoverColumns) * popoverSwatchSize + CGFloat(popoverColumns - 1) * popoverSwatchSpacing
        let gridHeight = rows * popoverSwatchSize + (rows - 1) * popoverSwatchSpacing
        let customRowHeight: CGFloat = 28
        let totalWidth = gridWidth + popoverPadding * 2
        let totalHeight = gridHeight + popoverPadding * 2 + popoverSwatchSpacing + customRowHeight
        // Right-align to color button, position just below toolbar
        let x = btnRect.maxX - totalWidth
        let toolbar = toolbarRect()
        let y = toolbar.minY - totalHeight - 4
        return NSRect(x: x, y: y, width: totalWidth, height: totalHeight)
    }

    private func popoverSwatchRect(at index: Int) -> NSRect {
        let popover = colorPopoverRect()
        let col = index % popoverColumns
        let row = index / popoverColumns
        let x = popover.minX + popoverPadding + CGFloat(col) * (popoverSwatchSize + popoverSwatchSpacing)
        // Row 0 at top of popover
        let topY = popover.maxY - popoverPadding - popoverSwatchSize
        let y = topY - CGFloat(row) * (popoverSwatchSize + popoverSwatchSpacing)
        return NSRect(x: x, y: y, width: popoverSwatchSize, height: popoverSwatchSize)
    }

    private func popoverCustomButtonRect() -> NSRect {
        let popover = colorPopoverRect()
        return NSRect(
            x: popover.minX + popoverPadding,
            y: popover.minY + popoverPadding,
            width: popover.width - popoverPadding * 2,
            height: 24
        )
    }

    private func applyColor(_ color: CGColor) {
        annotationColor = color
        // Persist
        if let components = color.components, color.numberOfComponents == 4 {
            AppSettings.shared.annotationColorRGBA = components
        } else if let converted = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
                  let components = converted.components, converted.numberOfComponents == 4 {
            AppSettings.shared.annotationColorRGBA = components
        }
        if let selected = selectedAnnotation {
            selected.color = color
            updateAnnotationLayer(for: selected)
            if let arrow = selected as? ArrowAnnotation {
                arrowHeadLayers[arrow.id]?.fillColor = color
            }
        }
        if let editing = editingTextAnnotation {
            editing.color = color
            updateEditingTextLayer()
        }
        needsDisplay = true
    }

    @objc private func colorPanelColorChanged(_ sender: NSColorPanel) {
        applyColor(sender.color.cgColor)
    }

    private func openSystemColorPicker() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelColorChanged(_:)))
        panel.color = NSColor(cgColor: annotationColor) ?? .red
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.orderFront(nil)
    }

    private func handleToolbarClick(at point: NSPoint) -> Bool {
        // If popover is open, handle clicks inside it first
        if isColorPopoverVisible {
            let popover = colorPopoverRect()
            if popover.contains(point) {
                // Check swatch clicks
                for (index, color) in colorPalette.enumerated() {
                    if popoverSwatchRect(at: index).contains(point) {
                        applyColor(color.cgColor)
                        isColorPopoverVisible = false
                        return true
                    }
                }
                // Check custom button
                if popoverCustomButtonRect().contains(point) {
                    isColorPopoverVisible = false
                    openSystemColorPicker()
                    needsDisplay = true
                    return true
                }
                return true // absorb click inside popover
            }
            // Click outside popover dismisses it
            isColorPopoverVisible = false
            needsDisplay = true
            // Fall through to check toolbar buttons
        }

        for (index, button) in toolbarButtons.enumerated() {
            let btnRect = rectForToolbarButton(at: index)
            if btnRect.contains(point) {
                currentMode = button.mode
                needsDisplay = true
                return true
            }
        }

        // Color button toggles popover
        if colorButtonRect().contains(point) {
            isColorPopoverVisible = !isColorPopoverVisible
            needsDisplay = true
            return true
        }

        return false
    }

    private func drawToolbar() {
        let toolbar = toolbarRect()

        // Draw toolbar background
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: toolbar, xRadius: 10, yRadius: 10).fill()

        for (index, button) in toolbarButtons.enumerated() {
            let btnRect = rectForToolbarButton(at: index)
            let isActive = currentMode == button.mode

            // Draw button background
            if isActive {
                NSColor.white.withAlphaComponent(0.25).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.05).setFill()
            }
            NSBezierPath(roundedRect: btnRect, xRadius: 8, yRadius: 8).fill()

            // Draw SF Symbol icon
            let iconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            if let icon = NSImage(systemSymbolName: button.icon, accessibilityDescription: button.label)?
                .withSymbolConfiguration(iconConfig) {
                let iconSize = icon.size
                let iconX = btnRect.midX - iconSize.width / 2
                let iconY = btnRect.midY - iconSize.height / 2 + 5
                let tintColor: NSColor = isActive ? .white : .white.withAlphaComponent(0.6)
                let tinted = icon.copy() as! NSImage
                tinted.lockFocus()
                tintColor.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height))
            }

            // Draw shortcut label below icon
            let shortcutAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.4)
            ]
            let shortcutSize = button.shortcut.size(withAttributes: shortcutAttrs)
            let shortcutPoint = NSPoint(
                x: btnRect.midX - shortcutSize.width / 2,
                y: btnRect.minY + 3
            )
            button.shortcut.draw(at: shortcutPoint, withAttributes: shortcutAttrs)
        }

        // Draw color button (filled circle showing current color)
        let colorBtn = colorButtonRect()
        let circleInset: CGFloat = 8
        let circleRect = colorBtn.insetBy(dx: circleInset, dy: circleInset)

        // Button background
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: colorBtn, xRadius: 8, yRadius: 8).fill()

        // Color circle
        (NSColor(cgColor: annotationColor) ?? .red).setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // Border on circle
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let circleBorder = NSBezierPath(ovalIn: circleRect)
        circleBorder.lineWidth = 1.5
        circleBorder.stroke()

        // Draw color popover if visible
        if isColorPopoverVisible {
            drawColorPopover()
        }
    }

    private func drawColorPopover() {
        let popover = colorPopoverRect()

        // Shadow
        let shadowRect = popover.insetBy(dx: -2, dy: -2).offsetBy(dx: 0, dy: -2)
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: shadowRect, xRadius: 10, yRadius: 10).fill()

        // Background
        NSColor(white: 0.15, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: popover, xRadius: 8, yRadius: 8).fill()

        // Border
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let borderPath = NSBezierPath(roundedRect: popover, xRadius: 8, yRadius: 8)
        borderPath.lineWidth = 0.5
        borderPath.stroke()

        // Draw swatches
        for (index, color) in colorPalette.enumerated() {
            let swatchRect = popoverSwatchRect(at: index)
            let isActive = color.cgColor == annotationColor

            // Selection indicator
            if isActive {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: swatchRect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
            }

            // Filled rounded square
            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()

            // Subtle border
            NSColor.white.withAlphaComponent(0.15).setStroke()
            let sBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4)
            sBorder.lineWidth = 0.5
            sBorder.stroke()
        }

        // "Custom..." button
        let customBtn = popoverCustomButtonRect()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: customBtn, xRadius: 4, yRadius: 4).fill()

        let customAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let customText = "Custom..."
        let textSize = customText.size(withAttributes: customAttrs)
        customText.draw(
            at: NSPoint(x: customBtn.midX - textSize.width / 2, y: customBtn.minY + (customBtn.height - textSize.height) / 2),
            withAttributes: customAttrs
        )
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

    private var arrowHeadLayers: [UUID: CAShapeLayer] = [:]

    private func createAnnotationLayer(for annotation: any Annotation) -> CALayer {
        if let textAnnotation = annotation as? TextAnnotation {
            return createTextAnnotationLayer(for: textAnnotation)
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.strokeColor = annotation.color
        shapeLayer.lineWidth = annotation.strokeWidth
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        // Disable implicit animations
        shapeLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]

        if annotation is ArrowAnnotation {
            shapeLayer.fillColor = nil
            // Create separate layer for filled arrowhead
            let headLayer = CAShapeLayer()
            headLayer.fillColor = annotation.color
            headLayer.strokeColor = nil
            headLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(headLayer)
            arrowHeadLayers[annotation.id] = headLayer
        } else {
            shapeLayer.fillColor = nil
        }

        updateLayerPath(shapeLayer, for: annotation)
        return shapeLayer
    }

    private func createTextAnnotationLayer(for annotation: TextAnnotation) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.fontSize = annotation.fontSize
        textLayer.font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .bold)
        textLayer.foregroundColor = annotation.color
        textLayer.alignmentMode = .left
        textLayer.contentsScale = window?.screen?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = false
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull()]

        textLayer.string = annotation.text
        let attrs = annotation.textAttributes()
        let size = (annotation.text as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + 2,
                                     y: annotation.position.y + size.height / 2 + 2)

        return textLayer
    }

    private func updateLayerPath(_ layerToUpdate: CALayer, for annotation: any Annotation) {
        if let textAnnotation = annotation as? TextAnnotation, let textLayer = layerToUpdate as? CATextLayer {
            textLayer.string = textAnnotation.text
            let attrs = textAnnotation.textAttributes()
            let size = (textAnnotation.text as NSString).size(withAttributes: attrs)
            textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
            textLayer.position = CGPoint(x: textAnnotation.position.x + size.width / 2 + 2,
                                         y: textAnnotation.position.y + size.height / 2 + 2)
            return
        }

        guard let shapeLayer = layerToUpdate as? CAShapeLayer else { return }
        let path = CGMutablePath()

        if let arrow = annotation as? ArrowAnnotation {
            // Draw arrow line (stop at base of arrowhead)
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

            // Line stops at arrow base
            let arrowBasePoint = CGPoint(
                x: (arrowPoint1.x + arrowPoint2.x) / 2,
                y: (arrowPoint1.y + arrowPoint2.y) / 2
            )
            path.move(to: arrow.startPoint)
            path.addLine(to: arrowBasePoint)

            // Update arrowhead layer with filled triangle
            if let headLayer = arrowHeadLayers[arrow.id] {
                let headPath = CGMutablePath()
                headPath.move(to: arrow.endPoint)
                headPath.addLine(to: arrowPoint1)
                headPath.addLine(to: arrowPoint2)
                headPath.closeSubpath()
                headLayer.path = headPath
            }
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

    private func updateHoverHighlightLayer() {
        hoverHighlightLayer?.removeFromSuperlayer()
        hoverHighlightLayer = nil

        guard let hovered = hoveredAnnotation else { return }

        let highlight = CAShapeLayer()
        highlight.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        highlight.fillColor = nil
        highlight.lineWidth = 1.5
        highlight.lineDashPattern = [4, 4]
        highlight.actions = ["path": NSNull(), "position": NSNull()]

        let path = CGMutablePath()
        let rect = visualBounds(for: hovered).insetBy(dx: -4, dy: -4)
        path.addRect(rect)

        highlight.path = path
        layer?.addSublayer(highlight)
        hoverHighlightLayer = highlight
    }

    private var drawingPreviewLayer: CAShapeLayer?
    private var drawingPreviewHeadLayer: CAShapeLayer?

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

            // Line stops at arrow base
            let arrowBasePoint = CGPoint(
                x: (arrowPoint1.x + arrowPoint2.x) / 2,
                y: (arrowPoint1.y + arrowPoint2.y) / 2
            )
            path.move(to: start)
            path.addLine(to: arrowBasePoint)

            // Create/update filled arrowhead layer
            if drawingPreviewHeadLayer == nil {
                let headLayer = CAShapeLayer()
                headLayer.fillColor = annotationColor
                headLayer.strokeColor = nil
                headLayer.actions = ["path": NSNull()]
                layer?.addSublayer(headLayer)
                drawingPreviewHeadLayer = headLayer
            }

            let headPath = CGMutablePath()
            headPath.move(to: end)
            headPath.addLine(to: arrowPoint1)
            headPath.addLine(to: arrowPoint2)
            headPath.closeSubpath()
            drawingPreviewHeadLayer?.path = headPath
        } else {
            let rect = rectFromPoints(start, end)
            path.addRect(rect)
        }

        drawingPreviewLayer?.path = path
    }

    private func clearDrawingPreviewLayer() {
        drawingPreviewLayer?.removeFromSuperlayer()
        drawingPreviewLayer = nil
        drawingPreviewHeadLayer?.removeFromSuperlayer()
        drawingPreviewHeadLayer = nil
    }

    private func syncAnnotationLayers() {
        // Remove old layers
        for (id, layer) in annotationLayers {
            if !annotations.contains(where: { $0.id == id }) {
                layer.removeFromSuperlayer()
                annotationLayers.removeValue(forKey: id)
                // Also remove arrowhead layer if exists
                arrowHeadLayers[id]?.removeFromSuperlayer()
                arrowHeadLayers.removeValue(forKey: id)
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
