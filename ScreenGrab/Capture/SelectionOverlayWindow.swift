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
            // Hide text popover when leaving text mode
            if currentMode != .text {
                hideTextPopover()
            }
            // Close the system color panel when switching modes
            if oldValue != currentMode {
                NSColorPanel.shared.close()
            }
            // Track the last non-regionSelect mode for Tab toggling
            if oldValue != .regionSelect {
                modeBeforeRegionSelect = oldValue
            }
            updateCursorForMode()
        }
    }
    private var modeBeforeRegionSelect: CaptureMode = .select
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
    private var dragStartFontSize: CGFloat = 24

    // Text editing state
    private var editingTextAnnotation: TextAnnotation?
    private var editingTextLayer: CATextLayer?
    private var isTextAllSelected = false

    // Hover-to-select in drawing modes
    private var hoveredAnnotation: (any Annotation)?
    private var hoverHighlightLayer: CAShapeLayer?
    private var isHoveringSelectedHandle = false

    // CALayer-based annotation rendering for smooth dragging
    private var annotationLayers: [UUID: CALayer] = [:]
    private var selectionHandleLayer: CAShapeLayer?

    // Undo/redo
    private var undoStack: [[AnnotationSnapshot]] = []
    private var redoStack: [[AnnotationSnapshot]] = []
    private var textEditUndoAlreadyPushed = false

    private var annotationColor = NSColor.red.cgColor
    private var textForegroundColor: CGColor = NSColor.white.cgColor
    private let strokeWidth: CGFloat = 3.0
    private var textFontSize: CGFloat = 24
    private let fontSizeRange: ClosedRange<CGFloat> = 10...120
    private var fontSizeTextField: NSTextField?
    private var fontSizeFieldRect: NSRect = .zero

    // Text background color
    private var textBackgroundColor: CGColor? = NSColor.black.cgColor
    private var textBackgroundOpacity: CGFloat = 0.75
    private var textBackgroundPadding: CGFloat = 4
    private enum ColorTarget { case foreground, background }
    private var activeColorTarget: ColorTarget = .foreground

    // Clipboard for copy/paste annotations
    private var copiedAnnotationSnapshot: AnnotationSnapshot?

    private let colorPalette: [NSColor] = [
        .red, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .white, .lightGray, .gray, .darkGray, .black, .systemPink,
    ]

    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var coordLayer: CATextLayer?
    private var coordBgLayer: CALayer?
    private var crosshairCursor: NSCursor?
    private var lastCrosshairCoordKey: String?

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
        if let outline = path.copy() as? NSBezierPath {
            outline.lineWidth = 3.0
            outline.stroke()
        }
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
        if let outline = path.copy() as? NSBezierPath {
            outline.lineWidth = 3.0
            outline.stroke()
        }
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
        // Load saved text foreground color
        if let rgba = AppSettings.shared.textForegroundColorRGBA, rgba.count == 4 {
            textForegroundColor = CGColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        // Load saved text background color (defaults to dark gray via registerDefaults)
        if let rgba = AppSettings.shared.textBackgroundColorRGBA, rgba.count == 4 {
            textBackgroundColor = CGColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        textBackgroundOpacity = AppSettings.shared.textBackgroundOpacity
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

    // Cache font and character metrics for crosshair cursor rendering.
    // Since the font is monospaced, we compute text sizes arithmetically
    // from cached metrics for efficiency.
    private static let crosshairFont: NSFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let crosshairCharSize: NSSize = {
        let font = crosshairFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        return ("0" as NSString).size(withAttributes: attrs)
    }()

    private func buildCrosshairCursor(at point: NSPoint) {
        let crosshairSize: CGFloat = 33
        let center = crosshairSize / 2
        let armLength: CGFloat = 14
        let gap: CGFloat = 3

        // Coord text — compute size from cached monospaced char metrics
        let coordText = "\(Int(point.x)), \(Int(point.y))"
        let font = SelectionView.crosshairFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let charMetrics = SelectionView.crosshairCharSize
        let textSize = NSSize(
            width: charMetrics.width * CGFloat(coordText.count),
            height: charMetrics.height
        )

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
        // Only rebuild and re-register when integer coords change.
        // NSCursor.set() is expensive (~80% of mouseMoved cost) because the system
        // re-registers the cursor image with the window server on every call.
        let key = "\(Int(point.x)), \(Int(point.y))"
        if key != lastCrosshairCoordKey {
            lastCrosshairCoordKey = key
            buildCrosshairCursor(at: point)
            crosshairCursor?.set()
        }
    }

    /// Returns the full visual bounding rect for an annotation, including arrowhead extent.
    private func visualBounds(for annotation: any Annotation) -> CGRect {
        if let arrow = annotation as? ArrowAnnotation {
            let geo = ArrowAnnotation.arrowGeometry(from: arrow.startPoint, to: arrow.endPoint,
                                                     headLength: arrow.arrowHeadLength, headAngle: arrow.arrowHeadAngle)
            let allX = [arrow.startPoint.x, arrow.endPoint.x, geo.point1.x, geo.point2.x]
            let allY = [arrow.startPoint.y, arrow.endPoint.y, geo.point1.y, geo.point2.y]
            let minX = allX.min() ?? 0, maxX = allX.max() ?? 0
            let minY = allY.min() ?? 0, maxY = allY.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return annotation.bounds
    }

    private func updateHoverState(at point: NSPoint) {
        guard !isDraggingAnnotation && !isDrawingAnnotation else { return }

        isHoveringSelectedHandle = false

        if setArrowCursorIfOverPopover(point) { return }

        // Text editing always gets iBeam
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
            return
        }

        // Select mode: show handle-aware cursors and hover highlights
        if currentMode == .select {
            // Check selected annotation handles first
            if let selected = selectedAnnotation, let handle = selected.hitTest(point: point) {
                // Hovering the selected annotation — no dashed highlight needed (handles are visible)
                if hoveredAnnotation != nil {
                    hoveredAnnotation = nil
                    updateHoverHighlightLayer()
                }
                isHoveringSelectedHandle = true
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

        // Check selected annotation's resize handles first (visible after grab-and-release)
        if let selected = selectedAnnotation, let handle = selected.hitTest(point: point) {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                updateHoverHighlightLayer()
            }
            isHoveringSelectedHandle = true
            cursorForHandle(handle).set()
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
            NSCursor.openHand.set()
        } else {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                updateHoverHighlightLayer()
            }
        }
    }

    private func updateCoordDisplay(at point: NSPoint) {
        if setArrowCursorIfOverPopover(point) { return }
        // Show iBeam when editing text
        if editingTextAnnotation != nil {
            NSCursor.iBeam.set()
            return
        }
        // Don't override drag/draw/handle-hover cursors
        if isDraggingAnnotation || isDrawingAnnotation || isHoveringSelectedHandle { return }
        // Only show coords cursor in non-select modes, and not when hovering over an annotation
        if currentMode != .select && hoveredAnnotation == nil {
            updateCursorWithCoords(point)
        }
    }

    private func updateCursorForMode() {
        if let pos = currentMousePosition, setArrowCursorIfOverPopover(pos) {
            // handled
        } else if editingTextAnnotation != nil {
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
        // Don't add cursor rects — we manage all cursors via mouse event handlers.
        // System cursor rects fight with our dynamic cursor logic and cause flicker.
    }

    override func cursorUpdate(with event: NSEvent) {
        // During drag/draw, updateHoverState returns early without setting a cursor.
        // We must set the correct cursor here so the system doesn't revert to default.
        if isDraggingAnnotation, let handle = activeHandle {
            cursorForHandle(handle, isDragging: true).set()
            return
        }
        if isDrawingAnnotation {
            crosshairCursor?.set()
            return
        }
        if let pos = currentMousePosition, setArrowCursorIfOverPopover(pos) { return }
        if let pos = currentMousePosition {
            updateHoverState(at: pos)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if isDraggingAnnotation, let handle = activeHandle {
            cursorForHandle(handle, isDragging: true).set()
            return
        }
        if isDrawingAnnotation {
            crosshairCursor?.set()
            return
        }
        if let pos = currentMousePosition {
            updateHoverState(at: pos)
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Don't reset cursor - we control cursor everywhere on our overlay
    }

    func setupMonitors() {
        // Remove any existing monitors to prevent duplicates
        stopMonitors()

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Let the font size text field handle its own key events
            if let self = self, let tf = self.fontSizeTextField, tf.superview != nil {
                if event.keyCode == 53 { // Escape - dismiss field
                    self.dismissFontSizeField()
                    self.needsDisplay = true
                    return nil
                }
                return event // pass to text field
            }
            self?.handleKeyEvent(event)
            return nil
        }
        window?.invalidateCursorRects(for: self)
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
        // Cmd+Z = undo, Cmd+Shift+Z = redo (works in all modes)
        if event.modifierFlags.contains(.command) && event.keyCode == 6 { // Z key
            // Cancel any in-progress drawing first
            if isDrawingAnnotation {
                isDrawingAnnotation = false
                clearDrawingPreviewLayer()
                annotationStart = nil
                annotationEnd = nil
            }
            // Cancel any in-progress text editing (discard uncommitted text)
            if editingTextAnnotation != nil {
                editingTextLayer?.removeFromSuperlayer()
                editingTextLayer = nil
                editingTextAnnotation = nil
                textEditUndoAlreadyPushed = false
            }
            if event.modifierFlags.contains(.shift) {
                performRedo()
            } else {
                performUndo()
            }
            return
        }

        // Cmd+C/X/V/D = clipboard operations
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 8: // C key - copy
                copySelectedAnnotation()
                return
            case 7: // X key - cut
                cutSelectedAnnotation()
                return
            case 9: // V key - paste
                pasteAnnotation()
                return
            case 2: // D key - duplicate
                duplicateSelectedAnnotation()
                return
            case 30: // ] key - bring forward / bring to front
                if event.modifierFlags.contains(.shift) {
                    bringSelectedToFront()
                } else {
                    bringSelectedForward()
                }
                return
            case 33: // [ key - send backward / send to back
                if event.modifierFlags.contains(.shift) {
                    sendSelectedToBack()
                } else {
                    sendSelectedBackward()
                }
                return
            default:
                break
            }
        }

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
        case 48: // Tab - toggle region select mode
            if currentMode == .regionSelect {
                currentMode = modeBeforeRegionSelect
            } else {
                currentMode = .regionSelect
            }
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
                pushUndoState()
                annotations.removeAll { $0.id == selected.id }
                selectedAnnotation = nil
                selectionHandleLayer?.removeFromSuperlayer()
                selectionHandleLayer = nil
                syncAnnotationLayers()
                needsDisplay = true
            }
        case 33: // [ or { (Shift+[)
            if event.modifierFlags.contains(.shift) {
                // Shift+[ — decrease background padding
                if let textAnn = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    textAnn.backgroundPadding = max(0, textAnn.backgroundPadding - 2)
                    textBackgroundPadding = textAnn.backgroundPadding
                    syncAnnotationLayers()
                    needsDisplay = true
                } else {
                    textBackgroundPadding = max(0, textBackgroundPadding - 2)
                    needsDisplay = true
                }
            } else {
                // [ — decrease font size
                if let textAnn = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    textAnn.fontSize = (textAnn.fontSize - 2).clampedTo(fontSizeRange)
                    textFontSize = textAnn.fontSize
                    syncAnnotationLayers()
                    needsDisplay = true
                } else {
                    textFontSize = (textFontSize - 2).clampedTo(fontSizeRange)
                    needsDisplay = true
                }
            }
        case 30: // ] or } (Shift+])
            if event.modifierFlags.contains(.shift) {
                // Shift+] — increase background padding
                if let textAnn = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    textAnn.backgroundPadding = min(40, textAnn.backgroundPadding + 2)
                    textBackgroundPadding = textAnn.backgroundPadding
                    syncAnnotationLayers()
                    needsDisplay = true
                } else {
                    textBackgroundPadding = min(40, textBackgroundPadding + 2)
                    needsDisplay = true
                }
            } else {
                // ] — increase font size
                if let textAnn = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    textAnn.fontSize = (textAnn.fontSize + 2).clampedTo(fontSizeRange)
                    textFontSize = textAnn.fontSize
                    syncAnnotationLayers()
                    needsDisplay = true
                } else {
                    textFontSize = (textFontSize + 2).clampedTo(fontSizeRange)
                    needsDisplay = true
                }
            }
        default:
            break
        }
    }

    private func handleTextKeyEvent(_ event: NSEvent) {
        guard let annotation = editingTextAnnotation else { return }

        // Cmd+A = select all
        if event.modifierFlags.contains(.command) && event.keyCode == 0 { // A key
            if !annotation.text.isEmpty {
                isTextAllSelected = true
                updateEditingTextLayer()
            }
            return
        }

        switch event.keyCode {
        case 53, 36, 76: // ESC / Return / Enter - commit text
            isTextAllSelected = false
            commitTextAnnotation()
        case 51: // Delete/Backspace
            if isTextAllSelected {
                annotation.text = ""
                isTextAllSelected = false
            } else if !annotation.text.isEmpty {
                annotation.text = String(annotation.text.dropLast())
            }
            updateEditingTextLayer()
        case 33: // [ or { (Shift+[)
            if event.modifierFlags.contains(.shift) {
                annotation.backgroundPadding = max(0, annotation.backgroundPadding - 2)
                textBackgroundPadding = annotation.backgroundPadding
                updateEditingTextLayer()
                needsDisplay = true
            } else {
                adjustFontSize(by: -2, for: annotation)
            }
        case 30: // ] or } (Shift+])
            if event.modifierFlags.contains(.shift) {
                annotation.backgroundPadding = min(40, annotation.backgroundPadding + 2)
                textBackgroundPadding = annotation.backgroundPadding
                updateEditingTextLayer()
                needsDisplay = true
            } else {
                adjustFontSize(by: 2, for: annotation)
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
                    if isTextAllSelected {
                        annotation.text = filtered
                        isTextAllSelected = false
                    } else {
                        annotation.text += filtered
                    }
                    updateEditingTextLayer()
                }
            }
        }
    }

    private func adjustFontSize(by delta: CGFloat, for annotation: TextAnnotation) {
        let newSize = (annotation.fontSize + delta).clampedTo(fontSizeRange)
        annotation.fontSize = newSize
        textFontSize = newSize
        updateEditingTextLayer()
        needsDisplay = true
    }

    private func beginEditingTextAnnotation(_ annotation: TextAnnotation) {
        pushUndoState()
        textEditUndoAlreadyPushed = true
        isTextAllSelected = false

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
        let padding = textLayerPadding(for: annotation)
        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + padding / 2,
                                     y: annotation.position.y + size.height / 2 + padding / 2)
        layer?.addSublayer(textLayer)
        editingTextLayer = textLayer

        currentMode = .text
        showTextPopover()
        needsDisplay = true
    }

    private func commitTextAnnotation() {
        guard let annotation = editingTextAnnotation else { return }

        // Only push undo if text is non-empty (otherwise nothing changes)
        if !annotation.text.isEmpty && !textEditUndoAlreadyPushed {
            pushUndoState()
        }
        textEditUndoAlreadyPushed = false

        // Remove the editing layer
        editingTextLayer?.removeFromSuperlayer()
        editingTextLayer = nil
        editingTextAnnotation = nil
        hideTextPopover()

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

        // Update background
        if let bgColor = annotation.backgroundColor {
            textLayer.backgroundColor = bgColor
            textLayer.cornerRadius = 3
        } else {
            textLayer.backgroundColor = nil
            textLayer.cornerRadius = 0
        }

        let padding = textLayerPadding(for: annotation)
        let displayText = annotation.text.isEmpty ? "|" : annotation.text + "|"
        let attrs = annotation.textAttributes()

        if isTextAllSelected && !annotation.text.isEmpty {
            // Show selection highlight: white text on blue background
            let selectedPart = annotation.text
            let cursor = "|"
            let attrStr = NSMutableAttributedString(string: selectedPart, attributes: attrs)
            attrStr.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: NSRange(location: 0, length: selectedPart.count))
            attrStr.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: selectedPart.count))
            let cursorAttrs = attrs
            attrStr.append(NSAttributedString(string: cursor, attributes: cursorAttrs))
            textLayer.string = attrStr
        } else {
            textLayer.string = NSAttributedString(string: displayText, attributes: attrs)
        }

        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + padding / 2,
                                     y: annotation.position.y + size.height / 2 + padding / 2)

        CATransaction.commit()
    }

    private func createEditingTextLayer(for annotation: TextAnnotation) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.alignmentMode = .left
        textLayer.contentsScale = window?.screen?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = false
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull(),
                             "backgroundColor": NSNull(), "cornerRadius": NSNull()]

        if let bgColor = annotation.backgroundColor {
            textLayer.backgroundColor = bgColor
            textLayer.cornerRadius = 3
        }

        let padding = textLayerPadding(for: annotation)

        // Use attributed string for reliable rendering
        let displayText = "|"
        let attrs = annotation.textAttributes()
        textLayer.string = NSAttributedString(string: displayText, attributes: attrs)

        let size = (displayText as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + padding / 2,
                                     y: annotation.position.y + size.height / 2 + padding / 2)

        return textLayer
    }

    // MARK: - Undo/Redo

    enum AnnotationSnapshot {
        case arrow(id: UUID, startPoint: CGPoint, endPoint: CGPoint, color: CGColor, strokeWidth: CGFloat)
        case rectangle(id: UUID, bounds: CGRect, color: CGColor, strokeWidth: CGFloat)
        case text(id: UUID, text: String, position: CGPoint, fontSize: CGFloat, color: CGColor, backgroundColor: CGColor?, backgroundPadding: CGFloat)
    }

    private func snapshotAnnotations() -> [AnnotationSnapshot] {
        annotations.map { annotation in
            if let arrow = annotation as? ArrowAnnotation {
                return .arrow(id: arrow.id, startPoint: arrow.startPoint, endPoint: arrow.endPoint,
                              color: arrow.color, strokeWidth: arrow.strokeWidth)
            } else if let rect = annotation as? RectangleAnnotation {
                return .rectangle(id: rect.id, bounds: rect.bounds, color: rect.color, strokeWidth: rect.strokeWidth)
            } else if let text = annotation as? TextAnnotation {
                return .text(id: text.id, text: text.text, position: text.position,
                             fontSize: text.fontSize, color: text.color, backgroundColor: text.backgroundColor,
                             backgroundPadding: text.backgroundPadding)
            }
            // Unknown annotation type — skip rather than crash
            return .rectangle(id: UUID(), bounds: .zero, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0), strokeWidth: 0)
        }
    }

    private func restoreAnnotations(from snapshots: [AnnotationSnapshot]) {
        annotations = snapshots.map { snapshot in
            switch snapshot {
            case .arrow(let id, let startPoint, let endPoint, let color, let strokeWidth):
                return ArrowAnnotation(id: id, startPoint: startPoint, endPoint: endPoint,
                                       color: color, strokeWidth: strokeWidth)
            case .rectangle(let id, let bounds, let color, let strokeWidth):
                return RectangleAnnotation(id: id, bounds: bounds, color: color, strokeWidth: strokeWidth)
            case .text(let id, let text, let position, let fontSize, let color, let backgroundColor, let backgroundPadding):
                return TextAnnotation(id: id, text: text, position: position, fontSize: fontSize, color: color, backgroundColor: backgroundColor, backgroundPadding: backgroundPadding)
            }
        }

        // Clear any stale editing state
        editingTextLayer?.removeFromSuperlayer()
        editingTextLayer = nil
        editingTextAnnotation = nil
        textEditUndoAlreadyPushed = false

        // Re-select the previously selected annotation if it still exists, else clear
        if let selectedId = selectedAnnotation?.id {
            selectedAnnotation = annotations.first { $0.id == selectedId }
            // If no match found, explicitly nil out (don't keep stale reference)
        }
        if selectedAnnotation != nil && !annotations.contains(where: { $0.id == selectedAnnotation!.id }) {
            selectedAnnotation = nil
        }

        selectionHandleLayer?.removeFromSuperlayer()
        selectionHandleLayer = nil
        if selectedAnnotation != nil {
            updateSelectionHandlesLayer()
        }

        syncAnnotationLayers()
        needsDisplay = true
    }

    private func pushUndoState() {
        undoStack.append(snapshotAnnotations())
        redoStack.removeAll()
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshotAnnotations())
        restoreAnnotations(from: previous)
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshotAnnotations())
        restoreAnnotations(from: next)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hideCoordDisplay()

        // Check text popover clicks — but annotations underneath take priority
        let clickHitsAnnotation = annotations.contains { $0.hitTest(point: point) != nil }
        if !clickHitsAnnotation && handleTextPopoverClick(at: point) {
            return
        }

        // Check toolbar clicks first
        if handleToolbarClick(at: point) {
            return
        }

        // Clear hover state on any mouse down
        hoveredAnnotation = nil
        updateHoverHighlightLayer()

        switch currentMode {
        case .select:
            // Check if clicking on an annotation
            for annotation in annotations.reversed() {
                if let handle = annotation.hitTest(point: point) {
                    // Double-click on text annotation enters edit mode
                    if event.clickCount == 2, let textAnnotation = annotation as? TextAnnotation {
                        beginEditingTextAnnotation(textAnnotation)
                        return
                    }
                    pushUndoState()
                    selectedAnnotation = annotation
                    activeHandle = handle
                    isDraggingAnnotation = true
                    dragStartPoint = point
                    dragStartBounds = annotation.bounds

                    if let arrow = annotation as? ArrowAnnotation {
                        dragStartArrowStart = arrow.startPoint
                        dragStartArrowEnd = arrow.endPoint
                    }
                    if let textAnn = annotation as? TextAnnotation {
                        dragStartFontSize = textAnn.fontSize
                    }

                    cursorForHandle(handle, isDragging: true).set()

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    updateTextPopoverForSelection()
                    return
                }
            }
            // Clicked on nothing - deselect
            selectedAnnotation = nil
            selectionHandleLayer?.removeFromSuperlayer()
            selectionHandleLayer = nil
            updateTextPopoverForSelection()
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
                    pushUndoState()
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
                    if let textAnn = annotation as? TextAnnotation {
                        dragStartFontSize = textAnn.fontSize
                    }

                    cursorForHandle(handle, isDragging: true).set()

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    updateTextPopoverForSelection()
                    needsDisplay = true
                    return
                }
            }

            // No annotation hit — deselect and start drawing new one
            selectedAnnotation = nil
            selectionHandleLayer?.removeFromSuperlayer()
            selectionHandleLayer = nil
            hideTextPopover()
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
                    // Double-click on text annotation enters edit mode
                    if event.clickCount == 2, let textAnnotation = annotation as? TextAnnotation {
                        beginEditingTextAnnotation(textAnnotation)
                        return
                    }
                    // Single-click: select and drag
                    pushUndoState()
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
                    if let textAnn = annotation as? TextAnnotation {
                        dragStartFontSize = textAnn.fontSize
                    }

                    cursorForHandle(handle, isDragging: true).set()

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateSelectionHandlesLayer()
                    CATransaction.commit()
                    updateTextPopoverForSelection()
                    needsDisplay = true
                    return
                }
            }

            // No annotation hit — deselect and start a new text annotation at click position
            selectedAnnotation = nil
            selectionHandleLayer?.removeFromSuperlayer()
            selectionHandleLayer = nil
            let annotation = TextAnnotation(position: point, fontSize: textFontSize, color: textForegroundColor, backgroundColor: effectiveBackgroundColor(), backgroundPadding: textBackgroundPadding)
            editingTextAnnotation = annotation

            let textLayer = createEditingTextLayer(for: annotation)
            layer?.addSublayer(textLayer)
            editingTextLayer = textLayer
            showTextPopover()
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
            } else if let textAnn = selected as? TextAnnotation, let originalBounds = dragStartBounds {
                // Text annotations: resize = scale font size proportionally
                switch activeHandle {
                case .body:
                    textAnn.position = CGPoint(
                        x: originalBounds.origin.x + delta.x,
                        y: originalBounds.origin.y + delta.y
                    )
                case .topRight:
                    let newHeight = originalBounds.height + delta.y
                    if newHeight > 0 && originalBounds.height > 0 {
                        let scale = newHeight / originalBounds.height
                        textAnn.fontSize = (dragStartFontSize * scale).clampedTo(fontSizeRange)
                        textFontSize = textAnn.fontSize
                    }
                case .topLeft:
                    let newHeight = originalBounds.height + delta.y
                    if newHeight > 0 && originalBounds.height > 0 {
                        let scale = newHeight / originalBounds.height
                        textAnn.fontSize = (dragStartFontSize * scale).clampedTo(fontSizeRange)
                        textFontSize = textAnn.fontSize
                        // Anchor bottom-right corner
                        let newSize = textAnn.textSize()
                        textAnn.position = CGPoint(
                            x: originalBounds.maxX - newSize.width,
                            y: originalBounds.origin.y
                        )
                    }
                case .bottomRight:
                    let newHeight = originalBounds.height - delta.y
                    if newHeight > 0 && originalBounds.height > 0 {
                        let scale = newHeight / originalBounds.height
                        textAnn.fontSize = (dragStartFontSize * scale).clampedTo(fontSizeRange)
                        textFontSize = textAnn.fontSize
                        // Anchor top-left corner, adjust Y for new height
                        let newSize = textAnn.textSize()
                        textAnn.position = CGPoint(
                            x: originalBounds.origin.x,
                            y: originalBounds.maxY - newSize.height
                        )
                    }
                case .bottomLeft:
                    let newHeight = originalBounds.height - delta.y
                    if newHeight > 0 && originalBounds.height > 0 {
                        let scale = newHeight / originalBounds.height
                        textAnn.fontSize = (dragStartFontSize * scale).clampedTo(fontSizeRange)
                        textFontSize = textAnn.fontSize
                        // Anchor top-right corner
                        let newSize = textAnn.textSize()
                        textAnn.position = CGPoint(
                            x: originalBounds.maxX - newSize.width,
                            y: originalBounds.maxY - newSize.height
                        )
                    }
                default:
                    break
                }
                needsDisplay = true
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

            // Recompute popover position after annotation was moved/resized
            if isTextPopoverVisible {
                recomputeTextPopoverRect()
            }

            needsDisplay = true
        } else if isDrawingAnnotation, let start = annotationStart, let end = annotationEnd {
            isDrawingAnnotation = false
            clearDrawingPreviewLayer()

            if currentDrawingTool == .arrow {
                let distance = hypot(end.x - start.x, end.y - start.y)
                if distance > 10 {
                    pushUndoState()
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
                    pushUndoState()
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
        let viewPos = convert(event.locationInWindow, from: nil)
        currentMousePosition = viewPos
        updateHoverState(at: viewPos)
        updateCoordDisplay(at: viewPos)
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Hit test to find annotation under cursor (use bounding box for generous hit area)
        var targetAnnotation: (any Annotation)?
        for annotation in annotations.reversed() {
            let rect = visualBounds(for: annotation).insetBy(dx: -4, dy: -4)
            if rect.contains(point) {
                targetAnnotation = annotation
                break
            }
        }

        // If right-clicked on an annotation, select it and show menu
        if let annotation = targetAnnotation {
            selectedAnnotation = annotation
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateSelectionHandlesLayer()
            CATransaction.commit()
            updateTextPopoverForSelection()

            showAnnotationContextMenu(for: annotation, at: event)
        } else if copiedAnnotationSnapshot != nil {
            // Right-clicked on empty space with something copied - show paste menu
            showPasteContextMenu(at: event, pastePoint: point)
        }
    }

    private func showAnnotationContextMenu(for annotation: any Annotation, at event: NSEvent) {
        let menu = NSMenu()

        let cutItem = NSMenuItem(title: "Cut", action: #selector(contextMenuCut), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = .command
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextMenuCopy), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        menu.addItem(copyItem)

        if copiedAnnotationSnapshot != nil {
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextMenuPaste), keyEquivalent: "v")
            pasteItem.keyEquivalentModifierMask = .command
            menu.addItem(pasteItem)
        }

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate), keyEquivalent: "d")
        duplicateItem.keyEquivalentModifierMask = .command
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        let index = annotations.firstIndex(where: { $0.id == annotation.id }) ?? 0
        let isTop = index == annotations.count - 1
        let isBottom = index == 0

        let bringToFrontItem = NSMenuItem(title: "Bring to Front", action: isTop ? nil : #selector(contextMenuBringToFront), keyEquivalent: "]")
        bringToFrontItem.keyEquivalentModifierMask = [.command, .shift]
        if isTop { bringToFrontItem.isEnabled = false }
        menu.addItem(bringToFrontItem)

        let bringForwardItem = NSMenuItem(title: "Bring Forward", action: isTop ? nil : #selector(contextMenuBringForward), keyEquivalent: "]")
        bringForwardItem.keyEquivalentModifierMask = .command
        if isTop { bringForwardItem.isEnabled = false }
        menu.addItem(bringForwardItem)

        let sendBackwardItem = NSMenuItem(title: "Send Backward", action: isBottom ? nil : #selector(contextMenuSendBackward), keyEquivalent: "[")
        sendBackwardItem.keyEquivalentModifierMask = .command
        if isBottom { sendBackwardItem.isEnabled = false }
        menu.addItem(sendBackwardItem)

        let sendToBackItem = NSMenuItem(title: "Send to Back", action: isBottom ? nil : #selector(contextMenuSendToBack), keyEquivalent: "[")
        sendToBackItem.keyEquivalentModifierMask = [.command, .shift]
        if isBottom { sendToBackItem.isEnabled = false }
        menu.addItem(sendToBackItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextMenuDelete), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showPasteContextMenu(at event: NSEvent, pastePoint: NSPoint) {
        let menu = NSMenu()
        // Store paste point for use in action
        contextMenuPastePoint = pastePoint
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextMenuPasteAtPoint), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        menu.addItem(pasteItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private var contextMenuPastePoint: NSPoint?

    // MARK: - Context Menu Actions

    @objc private func contextMenuCut() {
        cutSelectedAnnotation()
    }

    @objc private func contextMenuCopy() {
        copySelectedAnnotation()
    }

    @objc private func contextMenuPaste() {
        pasteAnnotation()
    }

    @objc private func contextMenuPasteAtPoint() {
        if let point = contextMenuPastePoint {
            pasteAnnotation(at: point)
        }
        contextMenuPastePoint = nil
    }

    @objc private func contextMenuDuplicate() {
        duplicateSelectedAnnotation()
    }

    @objc private func contextMenuBringToFront() {
        bringSelectedToFront()
    }

    @objc private func contextMenuBringForward() {
        bringSelectedForward()
    }

    @objc private func contextMenuSendBackward() {
        sendSelectedBackward()
    }

    @objc private func contextMenuSendToBack() {
        sendSelectedToBack()
    }

    @objc private func contextMenuDelete() {
        deleteSelectedAnnotation()
    }

    // MARK: - Arrange Actions

    private func bringSelectedToFront() {
        guard let selected = selectedAnnotation,
              let index = annotations.firstIndex(where: { $0.id == selected.id }),
              index < annotations.count - 1 else { return }
        pushUndoState()
        let annotation = annotations.remove(at: index)
        annotations.append(annotation)
        reorderAnnotationLayers()
        needsDisplay = true
    }

    private func bringSelectedForward() {
        guard let selected = selectedAnnotation,
              let index = annotations.firstIndex(where: { $0.id == selected.id }),
              index < annotations.count - 1 else { return }
        pushUndoState()
        annotations.swapAt(index, index + 1)
        reorderAnnotationLayers()
        needsDisplay = true
    }

    private func sendSelectedBackward() {
        guard let selected = selectedAnnotation,
              let index = annotations.firstIndex(where: { $0.id == selected.id }),
              index > 0 else { return }
        pushUndoState()
        annotations.swapAt(index, index - 1)
        reorderAnnotationLayers()
        needsDisplay = true
    }

    private func sendSelectedToBack() {
        guard let selected = selectedAnnotation,
              let index = annotations.firstIndex(where: { $0.id == selected.id }),
              index > 0 else { return }
        pushUndoState()
        let annotation = annotations.remove(at: index)
        annotations.insert(annotation, at: 0)
        reorderAnnotationLayers()
        needsDisplay = true
    }

    // MARK: - Clipboard Actions

    private func copySelectedAnnotation() {
        guard let selected = selectedAnnotation else { return }
        copiedAnnotationSnapshot = snapshotAnnotations().first { snapshot in
            switch snapshot {
            case .arrow(let id, _, _, _, _): return id == selected.id
            case .rectangle(let id, _, _, _): return id == selected.id
            case .text(let id, _, _, _, _, _, _): return id == selected.id
            }
        }
    }

    private func cutSelectedAnnotation() {
        copySelectedAnnotation()
        deleteSelectedAnnotation()
    }

    private func pasteAnnotation(at point: NSPoint? = nil) {
        guard let snapshot = copiedAnnotationSnapshot else { return }
        pushUndoState()

        let offset: CGFloat = point == nil ? 20 : 0
        let newAnnotation: any Annotation

        switch snapshot {
        case .arrow(_, let startPoint, let endPoint, let color, let strokeWidth):
            let dx = point.map { $0.x - startPoint.x } ?? offset
            let dy = point.map { $0.y - startPoint.y } ?? offset
            newAnnotation = ArrowAnnotation(
                startPoint: CGPoint(x: startPoint.x + dx, y: startPoint.y + dy),
                endPoint: CGPoint(x: endPoint.x + dx, y: endPoint.y + dy),
                color: color, strokeWidth: strokeWidth
            )
        case .rectangle(_, let bounds, let color, let strokeWidth):
            let dx = point.map { $0.x - bounds.midX } ?? offset
            let dy = point.map { $0.y - bounds.midY } ?? offset
            newAnnotation = RectangleAnnotation(
                bounds: CGRect(x: bounds.origin.x + dx, y: bounds.origin.y + dy,
                               width: bounds.width, height: bounds.height),
                color: color, strokeWidth: strokeWidth
            )
        case .text(_, let text, let position, let fontSize, let color, let backgroundColor, let backgroundPadding):
            let dx = point.map { $0.x - position.x } ?? offset
            let dy = point.map { $0.y - position.y } ?? offset
            newAnnotation = TextAnnotation(
                text: text, position: CGPoint(x: position.x + dx, y: position.y + dy),
                fontSize: fontSize, color: color, backgroundColor: backgroundColor,
                backgroundPadding: backgroundPadding
            )
        }

        annotations.append(newAnnotation)
        selectedAnnotation = newAnnotation
        syncAnnotationLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateSelectionHandlesLayer()
        CATransaction.commit()
        needsDisplay = true
    }

    private func duplicateSelectedAnnotation() {
        guard selectedAnnotation != nil else { return }
        copySelectedAnnotation()
        pasteAnnotation()
    }

    private func deleteSelectedAnnotation() {
        guard let selected = selectedAnnotation else { return }
        pushUndoState()
        annotations.removeAll { $0.id == selected.id }
        selectedAnnotation = nil
        selectionHandleLayer?.removeFromSuperlayer()
        selectionHandleLayer = nil
        syncAnnotationLayers()
        needsDisplay = true
    }

    /// Reorder CALayers to match the annotations array order
    private func reorderAnnotationLayers() {
        for (i, annotation) in annotations.enumerated() {
            if let annotationLayer = annotationLayers[annotation.id] {
                annotationLayer.zPosition = CGFloat(i)
            }
            if let headLayer = arrowHeadLayers[annotation.id] {
                headLayer.zPosition = CGFloat(i) + 0.5
            }
        }
        // Keep selection handles and hover highlight above all annotations
        let top = CGFloat(annotations.count + 1)
        selectionHandleLayer?.zPosition = top
        hoverHighlightLayer?.zPosition = top
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

        if isTextPopoverVisible {
            drawTextPopover()
        }
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
    private var isTextPopoverVisible = false
    private var lockedTextPopoverRect: NSRect?
    private let fontSizePresets: [CGFloat] = [16, 24, 36, 48, 72]

    // Cached shortcut label sizes — static strings measured once
    private static let shortcutLabelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private static let shortcutLabelSizes: [String: NSSize] = {
        let attrs: [NSAttributedString.Key: Any] = [.font: shortcutLabelFont, .foregroundColor: NSColor.white]
        var cache: [String: NSSize] = [:]
        for label in ["Tab", "S", "R", "A", "T"] {
            cache[label] = label.size(withAttributes: attrs)
        }
        return cache
    }()

    private var isTextModeActive: Bool {
        currentMode == .text || editingTextAnnotation != nil
    }

    private func toolbarRect() -> NSRect {
        let count = CGFloat(toolbarButtons.count)
        let buttonsWidth = count * toolbarButtonSize + (count - 1) * toolbarSpacing
        let colorButtonsWidth: CGFloat = isTextModeActive ? (toolbarButtonSize * 2 + toolbarSpacing) : toolbarButtonSize
        let dividerWidth: CGFloat = colorDividerGap
        let totalWidth = buttonsWidth + dividerWidth + colorButtonsWidth + toolbarPadding * 2
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

    private func bgColorButtonRect() -> NSRect {
        let fgBtn = colorButtonRect()
        return NSRect(x: fgBtn.maxX + toolbarSpacing, y: fgBtn.minY, width: toolbarButtonSize, height: toolbarButtonSize)
    }

    // Color popover layout
    private let popoverSwatchSize: CGFloat = 22
    private let popoverSwatchSpacing: CGFloat = 6
    private let popoverPadding: CGFloat = 10
    private let popoverColumns = 6

    private func colorPopoverRect() -> NSRect {
        let btnRect = activeColorTarget == .background ? bgColorButtonRect() : colorButtonRect()
        // For background target, add 1 extra swatch to count for "No Fill"
        let swatchCount = activeColorTarget == .background ? colorPalette.count + 1 : colorPalette.count
        let rows = ceil(CGFloat(swatchCount) / CGFloat(popoverColumns))
        let gridWidth = CGFloat(popoverColumns) * popoverSwatchSize + CGFloat(popoverColumns - 1) * popoverSwatchSpacing
        let gridHeight = rows * popoverSwatchSize + (rows - 1) * popoverSwatchSpacing
        let customRowHeight: CGFloat = 28
        let opacityRowHeight: CGFloat = activeColorTarget == .background ? 28 + popoverSwatchSpacing : 0
        let totalWidth = gridWidth + popoverPadding * 2
        let totalHeight = gridHeight + popoverPadding * 2 + popoverSwatchSpacing + customRowHeight + opacityRowHeight
        // Right-align to button, position just below toolbar
        let x = btnRect.maxX - totalWidth
        let toolbar = toolbarRect()
        let y = toolbar.minY - totalHeight - 4
        return NSRect(x: x, y: y, width: totalWidth, height: totalHeight)
    }

    /// Returns the rect for a swatch at a given visual index.
    /// For background mode, index 0 is the "No Fill" swatch, and palette colors start at index 1.
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

    private func popoverOpacityRowRect() -> NSRect {
        let customBtn = popoverCustomButtonRect()
        return NSRect(
            x: customBtn.minX,
            y: customBtn.maxY + popoverSwatchSpacing,
            width: customBtn.width,
            height: 24
        )
    }

    private func popoverOpacityButtonRect(at index: Int) -> NSRect {
        let row = popoverOpacityRowRect()
        let btnWidth = (row.width - 3 * popoverSwatchSpacing) / 4
        let x = row.minX + CGFloat(index) * (btnWidth + popoverSwatchSpacing)
        return NSRect(x: x, y: row.minY, width: btnWidth, height: row.height)
    }

    private func applyColor(_ color: CGColor) {
        // If in text mode or editing/selected annotation is text, route to text foreground color
        if isTextModeActive || selectedAnnotation is TextAnnotation {
            applyTextForegroundColor(color)
            return
        }
        annotationColor = color
        // Persist — convert to device RGB to ensure 4 components
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        if let components = color.components, color.numberOfComponents == 4 {
            AppSettings.shared.annotationColorRGBA = components
        } else if let converted = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
                  let components = converted.components, converted.numberOfComponents == 4 {
            AppSettings.shared.annotationColorRGBA = components
        } else {
            // Last resort: save as opaque red so we never lose the setting
            AppSettings.shared.annotationColorRGBA = [1.0, 0.0, 0.0, 1.0]
        }
        if let selected = selectedAnnotation {
            pushUndoState()
            selected.color = color
            updateAnnotationLayer(for: selected)
            if let arrow = selected as? ArrowAnnotation {
                arrowHeadLayers[arrow.id]?.fillColor = color
            }
        }
        needsDisplay = true
    }

    private func applyTextForegroundColor(_ color: CGColor) {
        textForegroundColor = color
        // Persist
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        if let components = color.components, color.numberOfComponents == 4 {
            AppSettings.shared.textForegroundColorRGBA = components
        } else if let converted = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
                  let components = converted.components, converted.numberOfComponents == 4 {
            AppSettings.shared.textForegroundColorRGBA = components
        } else {
            AppSettings.shared.textForegroundColorRGBA = [1.0, 1.0, 1.0, 1.0]
        }
        if let selected = selectedAnnotation as? TextAnnotation {
            pushUndoState()
            selected.color = color
            updateAnnotationLayer(for: selected)
        }
        if let editing = editingTextAnnotation {
            editing.color = color
            updateEditingTextLayer()
        }
        needsDisplay = true
    }

    private func applyBackgroundColor(_ color: CGColor?) {
        textBackgroundColor = color
        // Persist
        if let color = color {
            let rgbSpace = CGColorSpaceCreateDeviceRGB()
            if let components = color.components, color.numberOfComponents == 4 {
                AppSettings.shared.textBackgroundColorRGBA = components
            } else if let converted = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
                      let components = converted.components, converted.numberOfComponents == 4 {
                AppSettings.shared.textBackgroundColorRGBA = components
            }
        } else {
            AppSettings.shared.textBackgroundColorRGBA = nil
        }
        if let selected = selectedAnnotation as? TextAnnotation {
            pushUndoState()
            selected.backgroundColor = effectiveBackgroundColor()
            syncAnnotationLayers()
        }
        if let editing = editingTextAnnotation {
            editing.backgroundColor = effectiveBackgroundColor()
            updateEditingTextLayer()
        }
        needsDisplay = true
    }

    private func effectiveBackgroundColor() -> CGColor? {
        guard let base = textBackgroundColor else { return nil }
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        guard let converted = base.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count == 4 else { return base }
        return CGColor(red: comps[0], green: comps[1], blue: comps[2], alpha: textBackgroundOpacity)
    }

    private func drawNoFillIndicator(in rect: NSRect) {
        // Gray circle
        NSColor.gray.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        // Red diagonal slash
        NSColor.red.setStroke()
        let slash = NSBezierPath()
        slash.lineWidth = 2
        slash.move(to: NSPoint(x: rect.minX + 4, y: rect.maxY - 4))
        slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.minY + 4))
        slash.stroke()
    }

    @objc private func colorPanelColorChanged(_ sender: NSColorPanel) {
        if activeColorTarget == .background {
            applyBackgroundColor(sender.color.cgColor)
        } else {
            applyColor(sender.color.cgColor)
        }
    }

    private func openSystemColorPicker() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelColorChanged(_:)))
        if activeColorTarget == .background {
            panel.color = textBackgroundColor.flatMap { NSColor(cgColor: $0) } ?? .gray
        } else if isTextModeActive {
            panel.color = NSColor(cgColor: textForegroundColor) ?? .white
        } else {
            panel.color = NSColor(cgColor: annotationColor) ?? .red
        }
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

        // Position the color panel near the toolbar so it doesn't open offscreen
        if let screen = window?.screen ?? NSScreen.main {
            let toolbar = toolbarRect()
            let panelSize = panel.frame.size
            // Convert toolbar rect from view coords to screen coords
            if let window = self.window {
                let toolbarInWindow = convert(toolbar, to: nil)
                let toolbarOnScreen = window.convertToScreen(toolbarInWindow)
                // Place panel centered below the toolbar
                var x = toolbarOnScreen.midX - panelSize.width / 2
                var y = toolbarOnScreen.minY - panelSize.height - 8
                // Clamp to screen visible frame
                let visible = screen.visibleFrame
                x = max(visible.minX, min(x, visible.maxX - panelSize.width))
                y = max(visible.minY, min(y, visible.maxY - panelSize.height))
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        panel.orderFront(nil)
    }

    private let opacityPresets: [CGFloat] = [0.25, 0.5, 0.75, 1.0]

    private func handleToolbarClick(at point: NSPoint) -> Bool {
        // If popover is open, handle clicks inside it first
        if isColorPopoverVisible {
            let popover = colorPopoverRect()
            if popover.contains(point) {
                if activeColorTarget == .background {
                    // Background popover: index 0 = No Fill, then palette colors
                    if popoverSwatchRect(at: 0).contains(point) {
                        applyBackgroundColor(nil)
                        isColorPopoverVisible = false
                        return true
                    }
                    for (index, color) in colorPalette.enumerated() {
                        if popoverSwatchRect(at: index + 1).contains(point) {
                            applyBackgroundColor(color.cgColor)
                            isColorPopoverVisible = false
                            return true
                        }
                    }
                    // Check opacity buttons
                    for (index, opacity) in opacityPresets.enumerated() {
                        if popoverOpacityButtonRect(at: index).contains(point) {
                            textBackgroundOpacity = opacity
                            AppSettings.shared.textBackgroundOpacity = opacity
                            // Re-apply to update effective color
                            if let selected = selectedAnnotation as? TextAnnotation {
                                pushUndoState()
                                selected.backgroundColor = effectiveBackgroundColor()
                                syncAnnotationLayers()
                            }
                            if let editing = editingTextAnnotation {
                                editing.backgroundColor = effectiveBackgroundColor()
                                updateEditingTextLayer()
                            }
                            needsDisplay = true
                            return true
                        }
                    }
                } else {
                    // Foreground popover: standard palette
                    for (index, color) in colorPalette.enumerated() {
                        if popoverSwatchRect(at: index).contains(point) {
                            applyColor(color.cgColor)
                            isColorPopoverVisible = false
                            return true
                        }
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

        // Foreground color button toggles popover
        if colorButtonRect().contains(point) {
            activeColorTarget = .foreground
            isColorPopoverVisible = !isColorPopoverVisible
            needsDisplay = true
            return true
        }

        // Background color button (text mode only)
        if isTextModeActive && bgColorButtonRect().contains(point) {
            activeColorTarget = .background
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
                if let tinted = icon.copy() as? NSImage {
                    tinted.lockFocus()
                    tintColor.set()
                    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                    tinted.unlockFocus()
                    tinted.draw(in: NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height))
                }
            }

            // Draw shortcut label below icon (sizes cached — static strings)
            let shortcutAttrs: [NSAttributedString.Key: Any] = [
                .font: SelectionView.shortcutLabelFont,
                .foregroundColor: isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.4)
            ]
            let shortcutSize = SelectionView.shortcutLabelSizes[button.shortcut]
                ?? button.shortcut.size(withAttributes: shortcutAttrs)
            let shortcutPoint = NSPoint(
                x: btnRect.midX - shortcutSize.width / 2,
                y: btnRect.minY + 3
            )
            button.shortcut.draw(at: shortcutPoint, withAttributes: shortcutAttrs)
        }

        // Draw foreground color button (filled circle showing current color)
        let colorBtn = colorButtonRect()
        let circleInset: CGFloat = 8
        let circleRect = colorBtn.insetBy(dx: circleInset, dy: circleInset)

        // Button background
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: colorBtn, xRadius: 8, yRadius: 8).fill()

        // Color circle — show text foreground color in text mode, annotation color otherwise
        let displayColor = isTextModeActive ? textForegroundColor : annotationColor
        (NSColor(cgColor: displayColor) ?? .red).setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // White border on fg circle (thick in text mode to distinguish from bg)
        NSColor.white.setStroke()
        let fgBorder = NSBezierPath(ovalIn: circleRect)
        fgBorder.lineWidth = isTextModeActive ? 2.5 : 1.5
        fgBorder.stroke()

        // Draw background color button in text mode
        if isTextModeActive {
            let bgBtn = bgColorButtonRect()
            let bgCircleRect = bgBtn.insetBy(dx: circleInset, dy: circleInset)

            // Button background
            NSColor.white.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bgBtn, xRadius: 8, yRadius: 8).fill()

            if let bgColor = effectiveBackgroundColor() {
                // Filled circle with background color
                (NSColor(cgColor: bgColor) ?? .gray).setFill()
                NSBezierPath(ovalIn: bgCircleRect).fill()
            } else {
                // "No fill" indicator
                drawNoFillIndicator(in: bgCircleRect)
            }

            // Thin border on bg circle
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let bgBorder = NSBezierPath(ovalIn: bgCircleRect)
            bgBorder.lineWidth = 1.0
            bgBorder.stroke()
        }

        // Draw font size indicator when in text mode
        if isTextModeActive {
            drawFontSizeIndicator(below: toolbar)
        }

        // Draw color popover if visible
        if isColorPopoverVisible {
            drawColorPopover()
        }
    }

    private func drawFontSizeIndicator(below toolbar: NSRect) {
        let displaySize = editingTextAnnotation?.fontSize ?? textFontSize
        let label = "[ \(Int(displaySize))pt ]"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let size = label.size(withAttributes: attrs)
        let bgWidth = size.width + 12
        let bgHeight = size.height + 6
        let bgRect = NSRect(
            x: toolbar.midX - bgWidth / 2,
            y: toolbar.minY - bgHeight - 4,
            width: bgWidth,
            height: bgHeight
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()
        label.draw(
            at: NSPoint(x: bgRect.midX - size.width / 2, y: bgRect.minY + 3),
            withAttributes: attrs
        )
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

        if activeColorTarget == .background {
            // "No Fill" swatch at index 0
            let noFillRect = popoverSwatchRect(at: 0)
            let isNoFillActive = textBackgroundColor == nil
            if isNoFillActive {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: noFillRect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
            }
            drawNoFillIndicator(in: noFillRect)
            NSColor.white.withAlphaComponent(0.15).setStroke()
            let nfBorder = NSBezierPath(roundedRect: noFillRect, xRadius: 4, yRadius: 4)
            nfBorder.lineWidth = 0.5
            nfBorder.stroke()

            // Palette colors starting at index 1
            for (index, color) in colorPalette.enumerated() {
                let swatchRect = popoverSwatchRect(at: index + 1)
                let isActive = textBackgroundColor != nil && colorsMatch(color.cgColor, textBackgroundColor!)

                if isActive {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: swatchRect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
                }
                color.setFill()
                NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()
                NSColor.white.withAlphaComponent(0.15).setStroke()
                let sBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4)
                sBorder.lineWidth = 0.5
                sBorder.stroke()
            }

            // Opacity presets row
            let opacityAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7)
            ]
            for (index, opacity) in opacityPresets.enumerated() {
                let btnRect = popoverOpacityButtonRect(at: index)
                let isActive = abs(textBackgroundOpacity - opacity) < 0.01
                if isActive {
                    NSColor.white.withAlphaComponent(0.2).setFill()
                } else {
                    NSColor.white.withAlphaComponent(0.06).setFill()
                }
                NSBezierPath(roundedRect: btnRect, xRadius: 4, yRadius: 4).fill()
                let label = "\(Int(opacity * 100))%"
                let labelSize = label.size(withAttributes: opacityAttrs)
                label.draw(
                    at: NSPoint(x: btnRect.midX - labelSize.width / 2, y: btnRect.minY + (btnRect.height - labelSize.height) / 2),
                    withAttributes: opacityAttrs
                )
            }
        } else {
            // Standard foreground color swatches
            for (index, color) in colorPalette.enumerated() {
                let swatchRect = popoverSwatchRect(at: index)
                let isActive = colorsMatch(color.cgColor, annotationColor)

                if isActive {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: swatchRect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
                }
                color.setFill()
                NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()
                NSColor.white.withAlphaComponent(0.15).setStroke()
                let sBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4)
                sBorder.lineWidth = 0.5
                sBorder.stroke()
            }
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

    private func colorsMatch(_ a: CGColor, _ b: CGColor) -> Bool {
        // Convert both to device RGB for reliable comparison across color spaces
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        guard let ac = a.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
              let bc = b.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
              let aComps = ac.components, let bComps = bc.components,
              aComps.count == bComps.count else { return false }
        return zip(aComps, bComps).allSatisfy { abs($0 - $1) < 0.01 }
    }

    // MARK: - Text Popover

    private let textPopoverWidth: CGFloat = 260
    private let textPopoverPadding: CGFloat = 10
    private let fontSizeFieldWidth: CGFloat = 38

    /// Compute rects for the font size row elements given the popover rect and Y position.
    /// Shared between draw and click handlers to guarantee layout consistency.
    private func fontSizeRowLayout(popover: NSRect, curY: CGFloat) -> (fieldRect: NSRect, presetButtons: [NSRect]) {
        let p = textPopoverPadding
        let sizeRowHeight: CGFloat = 24
        let fieldRect = NSRect(x: popover.minX + p, y: curY, width: fontSizeFieldWidth, height: sizeRowHeight)

        let sizeStartX = popover.minX + p + fontSizeFieldWidth + 4
        let sizeGap: CGFloat = 3
        let sizeBtnWidth = (popover.maxX - p - sizeStartX - CGFloat(fontSizePresets.count - 1) * sizeGap) / CGFloat(fontSizePresets.count)

        var buttons: [NSRect] = []
        for i in 0..<fontSizePresets.count {
            buttons.append(NSRect(x: sizeStartX + CGFloat(i) * (sizeBtnWidth + sizeGap),
                                  y: curY, width: sizeBtnWidth, height: sizeRowHeight))
        }
        return (fieldRect, buttons)
    }

    /// Returns the annotation rect that the text popover should anchor to.
    private func textPopoverAnchor() -> CGRect? {
        if let editing = editingTextAnnotation {
            return editing.backgroundRect.isEmpty ? editing.bounds : editing.backgroundRect
        }
        if let selected = selectedAnnotation as? TextAnnotation {
            return selected.backgroundRect.isEmpty ? selected.bounds : selected.backgroundRect
        }
        return nil
    }

    /// Returns true if the given point is inside any visible popover (text or color).
    private func isPointInsidePopover(_ point: NSPoint) -> Bool {
        if isTextPopoverVisible && textPopoverRect().contains(point) {
            return true
        }
        if isColorPopoverVisible && colorPopoverRect().contains(point) {
            return true
        }
        return false
    }

    /// If the point is over a popover, sets arrow cursor and returns true.
    /// Use as an early-return guard in cursor-update methods.
    private func setArrowCursorIfOverPopover(_ point: NSPoint) -> Bool {
        if isPointInsidePopover(point) {
            NSCursor.arrow.set()
            return true
        }
        return false
    }

    private func textPopoverRect() -> NSRect {
        if let locked = lockedTextPopoverRect {
            return locked
        }
        let computed = computeTextPopoverRect()
        lockedTextPopoverRect = computed
        return computed
    }

    /// Clears the cached popover rect and recomputes it.
    private func recomputeTextPopoverRect() {
        lockedTextPopoverRect = nil
        lockedTextPopoverRect = computeTextPopoverRect()
    }

    private func computeTextPopoverRect() -> NSRect {
        guard let anchor = textPopoverAnchor() else {
            // Fallback: center below toolbar
            let toolbar = toolbarRect()
            return NSRect(x: toolbar.midX - textPopoverWidth / 2,
                          y: toolbar.minY - 130,
                          width: textPopoverWidth, height: 120)
        }

        let popoverHeight: CGFloat = 120
        let gap: CGFloat = 8

        // Try above the annotation
        var x = anchor.midX - textPopoverWidth / 2
        var y = anchor.maxY + gap

        // If too close to top, flip below
        if y + popoverHeight > bounds.height - 10 {
            y = anchor.minY - popoverHeight - gap
        }

        // Clamp to screen bounds
        x = max(10, min(x, bounds.width - textPopoverWidth - 10))
        y = max(10, min(y, bounds.height - popoverHeight - 10))

        return NSRect(x: x, y: y, width: textPopoverWidth, height: popoverHeight)
    }

    private struct TextPreset {
        let label: String
        let textColor: CGColor
        let bgColor: CGColor?
        let bgOpacity: CGFloat
    }

    private let textPresets: [TextPreset] = [
        TextPreset(label: "Wht/Blk", textColor: NSColor.white.cgColor,
                   bgColor: NSColor.black.cgColor, bgOpacity: 0.75),
        TextPreset(label: "Blk/Light", textColor: NSColor.black.cgColor,
                   bgColor: CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1), bgOpacity: 0.85),
        TextPreset(label: "Yellow", textColor: CGColor(red: 1, green: 0.95, blue: 0, alpha: 1),
                   bgColor: nil, bgOpacity: 0.75),
    ]

    private func drawTextPopover() {
        let popover = textPopoverRect()

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

        let p = textPopoverPadding
        let contentWidth = popover.width - p * 2
        var curY = popover.maxY - p

        // --- Presets Row ---
        let presetHeight: CGFloat = 24
        curY -= presetHeight
        let presetWidth = (contentWidth - CGFloat(textPresets.count - 1) * 4) / CGFloat(textPresets.count)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        for (i, preset) in textPresets.enumerated() {
            let btnRect = NSRect(x: popover.minX + p + CGFloat(i) * (presetWidth + 4),
                                 y: curY, width: presetWidth, height: presetHeight)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: btnRect, xRadius: 4, yRadius: 4).fill()
            let sz = preset.label.size(withAttributes: labelAttrs)
            preset.label.draw(at: NSPoint(x: btnRect.midX - sz.width / 2,
                                          y: btnRect.minY + (btnRect.height - sz.height) / 2),
                              withAttributes: labelAttrs)
        }

        // --- Separator ---
        curY -= 8
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSRect(x: popover.minX + p, y: curY, width: contentWidth, height: 1).fill()
        curY -= 6

        let sectionLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]

        // --- Font Size Row ---
        curY -= 24  // sizeRowHeight
        let layout = fontSizeRowLayout(popover: popover, curY: curY)

        let displaySize = editingTextAnnotation?.fontSize ?? (selectedAnnotation as? TextAnnotation)?.fontSize ?? textFontSize

        // Editable size field
        let fieldRect = layout.fieldRect
        fontSizeFieldRect = fieldRect
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: fieldRect, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let fieldBorder = NSBezierPath(roundedRect: fieldRect, xRadius: 4, yRadius: 4)
        fieldBorder.lineWidth = 0.5
        fieldBorder.stroke()
        // Draw the value (only if text field is not active)
        if fontSizeTextField?.superview == nil {
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
            let valueStr = "\(Int(displaySize))"
            let valueSize = valueStr.size(withAttributes: valueAttrs)
            valueStr.draw(at: NSPoint(x: fieldRect.midX - valueSize.width / 2,
                                      y: fieldRect.minY + (fieldRect.height - valueSize.height) / 2),
                          withAttributes: valueAttrs)
        }

        // Preset size buttons
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let sizeActiveAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        for (i, preset) in fontSizePresets.enumerated() {
            let btnRect = layout.presetButtons[i]
            let isActive = Int(displaySize) == Int(preset)
            if isActive {
                NSColor.white.withAlphaComponent(0.25).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.08).setFill()
            }
            NSBezierPath(roundedRect: btnRect, xRadius: 4, yRadius: 4).fill()
            let label = "\(Int(preset))"
            let attrs = isActive ? sizeActiveAttrs : sizeAttrs
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: btnRect.midX - sz.width / 2,
                                   y: btnRect.minY + (btnRect.height - sz.height) / 2),
                       withAttributes: attrs)
        }

        // --- Separator ---
        curY -= 6
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSRect(x: popover.minX + p, y: curY, width: contentWidth, height: 1).fill()
        curY -= 6

        // --- Background Row ---
        let bgRowHeight: CGFloat = 24
        curY -= bgRowHeight
        let bgLabel = "Background"
        bgLabel.draw(at: NSPoint(x: popover.minX + p, y: curY + (bgRowHeight - 14) / 2),
                     withAttributes: sectionLabelAttrs)

        // Background color swatch
        let bgSwatchRect = NSRect(x: popover.minX + p + 70, y: curY + 2, width: 20, height: 20)
        if let bgColor = effectiveBackgroundColor() {
            (NSColor(cgColor: bgColor) ?? .gray).setFill()
            NSBezierPath(roundedRect: bgSwatchRect, xRadius: 3, yRadius: 3).fill()
        } else {
            drawNoFillIndicator(in: bgSwatchRect)
        }
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let bgBorder = NSBezierPath(roundedRect: bgSwatchRect, xRadius: 3, yRadius: 3)
        bgBorder.lineWidth = 0.5
        bgBorder.stroke()

        // "No Fill" toggle
        let noFillRect = NSRect(x: bgSwatchRect.maxX + 6, y: curY, width: 44, height: bgRowHeight)
        let isNoFill = textBackgroundColor == nil
        if isNoFill {
            NSColor.white.withAlphaComponent(0.2).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.06).setFill()
        }
        NSBezierPath(roundedRect: noFillRect, xRadius: 4, yRadius: 4).fill()
        let noFillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let noFillSize = "No Fill".size(withAttributes: noFillAttrs)
        "No Fill".draw(at: NSPoint(x: noFillRect.midX - noFillSize.width / 2,
                                   y: noFillRect.minY + (noFillRect.height - noFillSize.height) / 2),
                       withAttributes: noFillAttrs)

        // Opacity presets: 25 50 75 100
        let opacityStartX = noFillRect.maxX + 4
        let opacityGap: CGFloat = 2
        let opacityBtnWidth = (popover.maxX - p - opacityStartX - CGFloat(opacityPresets.count - 1) * opacityGap) / CGFloat(opacityPresets.count)
        let opAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        for (i, opacity) in opacityPresets.enumerated() {
            let btnRect = NSRect(x: opacityStartX + CGFloat(i) * (opacityBtnWidth + opacityGap),
                                 y: curY, width: opacityBtnWidth, height: bgRowHeight)
            let isActive = textBackgroundColor != nil && abs(textBackgroundOpacity - opacity) < 0.01
            if isActive {
                NSColor.white.withAlphaComponent(0.2).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.06).setFill()
            }
            NSBezierPath(roundedRect: btnRect, xRadius: 3, yRadius: 3).fill()
            let label = "\(Int(opacity * 100))"
            let lsz = label.size(withAttributes: opAttrs)
            label.draw(at: NSPoint(x: btnRect.midX - lsz.width / 2,
                                   y: btnRect.minY + (btnRect.height - lsz.height) / 2),
                       withAttributes: opAttrs)
        }
    }

    /// Handle click inside the text popover. Returns true if the click was consumed.
    private func handleTextPopoverClick(at point: NSPoint) -> Bool {
        guard isTextPopoverVisible else { return false }
        let popover = textPopoverRect()
        guard popover.contains(point) else {
            // Click outside text popover dismisses it
            isTextPopoverVisible = false
            lockedTextPopoverRect = nil
            dismissFontSizeField()
            needsDisplay = true
            return false
        }

        // Click inside popover but not on the font size field — commit any active edit
        if !fontSizeFieldRect.contains(point) {
            commitFontSizeField()
        }

        let p = textPopoverPadding
        let contentWidth = popover.width - p * 2
        var curY = popover.maxY - p

        // --- Presets ---
        let presetHeight: CGFloat = 24
        curY -= presetHeight
        let presetWidth = (contentWidth - CGFloat(textPresets.count - 1) * 4) / CGFloat(textPresets.count)
        for (i, preset) in textPresets.enumerated() {
            let btnRect = NSRect(x: popover.minX + p + CGFloat(i) * (presetWidth + 4),
                                 y: curY, width: presetWidth, height: presetHeight)
            if btnRect.contains(point) {
                applyTextForegroundColor(preset.textColor)
                if let bgColor = preset.bgColor {
                    applyBackgroundColor(bgColor)
                    textBackgroundOpacity = preset.bgOpacity
                    AppSettings.shared.textBackgroundOpacity = preset.bgOpacity
                    // Re-apply effective bg
                    if let editing = editingTextAnnotation {
                        editing.backgroundColor = effectiveBackgroundColor()
                        updateEditingTextLayer()
                    }
                    if let selected = selectedAnnotation as? TextAnnotation {
                        selected.backgroundColor = effectiveBackgroundColor()
                        syncAnnotationLayers()
                    }
                } else {
                    applyBackgroundColor(nil)
                }
                needsDisplay = true
                return true
            }
        }

        // Skip separator
        curY -= 8 + 1 + 6

        // --- Font Size Row ---
        curY -= 24  // sizeRowHeight
        let sizeLayout = fontSizeRowLayout(popover: popover, curY: curY)

        // Editable size field
        if sizeLayout.fieldRect.contains(point) {
            showFontSizeTextField()
            return true
        }

        // Preset size buttons
        for (i, preset) in fontSizePresets.enumerated() {
            let btnRect = sizeLayout.presetButtons[i]
            if btnRect.contains(point) {
                let newSize = preset.clampedTo(fontSizeRange)
                if let editing = editingTextAnnotation {
                    let delta = newSize - editing.fontSize
                    adjustFontSize(by: delta, for: editing)
                } else if let selected = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    selected.fontSize = newSize
                    textFontSize = newSize
                    syncAnnotationLayers()
                    updateSelectionHandlesLayer()
                } else {
                    textFontSize = newSize
                }
                recomputeTextPopoverRect()
                needsDisplay = true
                return true
            }
        }

        // Skip separator
        curY -= 6 + 1 + 6

        // --- Background Row ---
        let bgRowHeight: CGFloat = 24
        curY -= bgRowHeight

        // Background color swatch — open background color picker
        let bgSwatchRect = NSRect(x: popover.minX + p + 70, y: curY + 2, width: 20, height: 20)
        if bgSwatchRect.contains(point) {
            activeColorTarget = .background
            openSystemColorPicker()
            return true
        }

        // "No Fill" toggle
        let noFillRect = NSRect(x: bgSwatchRect.maxX + 6, y: curY, width: 44, height: bgRowHeight)
        if noFillRect.contains(point) {
            applyBackgroundColor(nil)
            needsDisplay = true
            return true
        }

        // Opacity presets
        let opacityStartX = noFillRect.maxX + 4
        let opacityGap: CGFloat = 2
        let opacityBtnWidth = (popover.maxX - p - opacityStartX - CGFloat(opacityPresets.count - 1) * opacityGap) / CGFloat(opacityPresets.count)
        for (i, opacity) in opacityPresets.enumerated() {
            let btnRect = NSRect(x: opacityStartX + CGFloat(i) * (opacityBtnWidth + opacityGap),
                                 y: curY, width: opacityBtnWidth, height: bgRowHeight)
            if btnRect.contains(point) {
                // If no bg color, set a default dark gray
                if textBackgroundColor == nil {
                    textBackgroundColor = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
                    AppSettings.shared.textBackgroundColorRGBA = [0.1, 0.1, 0.1, 1.0]
                }
                textBackgroundOpacity = opacity
                AppSettings.shared.textBackgroundOpacity = opacity
                if let selected = selectedAnnotation as? TextAnnotation {
                    pushUndoState()
                    selected.backgroundColor = effectiveBackgroundColor()
                    syncAnnotationLayers()
                }
                if let editing = editingTextAnnotation {
                    editing.backgroundColor = effectiveBackgroundColor()
                    updateEditingTextLayer()
                }
                needsDisplay = true
                return true
            }
        }

        return true // absorb click inside popover
    }

    private func showTextPopover() {
        isTextPopoverVisible = true
        isColorPopoverVisible = false
        recomputeTextPopoverRect()
        needsDisplay = true
    }

    private func hideTextPopover() {
        guard isTextPopoverVisible else { return }
        isTextPopoverVisible = false
        lockedTextPopoverRect = nil
        dismissFontSizeField()
        NSColorPanel.shared.close()
        needsDisplay = true
    }

    private func showFontSizeTextField() {
        let displaySize = editingTextAnnotation?.fontSize ?? (selectedAnnotation as? TextAnnotation)?.fontSize ?? textFontSize
        let tf: NSTextField
        if let existing = fontSizeTextField {
            tf = existing
        } else {
            tf = NSTextField()
            tf.isBordered = false
            tf.focusRingType = .none
            tf.alignment = .center
            tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            tf.textColor = .white
            tf.backgroundColor = NSColor.white.withAlphaComponent(0.12)
            tf.drawsBackground = true
            tf.target = self
            tf.action = #selector(fontSizeFieldAction(_:))
            tf.delegate = self
            fontSizeTextField = tf
        }
        tf.stringValue = "\(Int(displaySize))"
        // Vertically center the text field within the font size field rect.
        // NSTextField has ~3pt internal top padding, so inset to align with the drawn label.
        let insetY: CGFloat = 3
        tf.frame = NSRect(x: fontSizeFieldRect.minX,
                          y: fontSizeFieldRect.minY + insetY,
                          width: fontSizeFieldRect.width,
                          height: fontSizeFieldRect.height - insetY * 2)
        if tf.superview == nil {
            addSubview(tf)
        }
        tf.selectText(nil)
        window?.makeFirstResponder(tf)
    }

    @objc private func fontSizeFieldAction(_ sender: NSTextField) {
        commitFontSizeField()
    }

    private func commitFontSizeField() {
        guard let tf = fontSizeTextField, tf.superview != nil else { return }
        if let value = Double(tf.stringValue) {
            let newSize = CGFloat(value).clampedTo(fontSizeRange)
            if let editing = editingTextAnnotation {
                let delta = newSize - editing.fontSize
                adjustFontSize(by: delta, for: editing)
            } else if let selected = selectedAnnotation as? TextAnnotation {
                pushUndoState()
                selected.fontSize = newSize
                textFontSize = newSize
                syncAnnotationLayers()
                updateSelectionHandlesLayer()
            } else {
                textFontSize = newSize
            }
            recomputeTextPopoverRect()
        }
        dismissFontSizeField()
        needsDisplay = true
    }

    private func dismissFontSizeField() {
        fontSizeTextField?.removeFromSuperview()
    }

    /// Call after changing selectedAnnotation to show/hide text popover as needed.
    private func updateTextPopoverForSelection() {
        if selectedAnnotation is TextAnnotation {
            showTextPopover()
        } else if editingTextAnnotation == nil {
            hideTextPopover()
        }
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

    private func textLayerPadding(for annotation: TextAnnotation) -> CGFloat {
        return annotation.backgroundColor != nil ? annotation.backgroundPadding + 4 : 4
    }

    private func createTextAnnotationLayer(for annotation: TextAnnotation) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.fontSize = annotation.fontSize
        textLayer.font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .bold)
        textLayer.foregroundColor = annotation.color
        textLayer.alignmentMode = .left
        textLayer.contentsScale = window?.screen?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = false
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull(),
                             "backgroundColor": NSNull(), "cornerRadius": NSNull()]

        if let bgColor = annotation.backgroundColor {
            textLayer.backgroundColor = bgColor
            textLayer.cornerRadius = 3
        }

        let padding = textLayerPadding(for: annotation)
        textLayer.string = annotation.text
        let attrs = annotation.textAttributes()
        let size = (annotation.text as NSString).size(withAttributes: attrs)
        textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding)
        textLayer.position = CGPoint(x: annotation.position.x + size.width / 2 + padding / 2,
                                     y: annotation.position.y + size.height / 2 + padding / 2)

        return textLayer
    }

    private func updateLayerPath(_ layerToUpdate: CALayer, for annotation: any Annotation) {
        if let textAnnotation = annotation as? TextAnnotation, let textLayer = layerToUpdate as? CATextLayer {
            textLayer.string = textAnnotation.text
            textLayer.fontSize = textAnnotation.fontSize
            textLayer.font = NSFont.systemFont(ofSize: textAnnotation.fontSize, weight: .bold)
            textLayer.foregroundColor = textAnnotation.color
            if let bgColor = textAnnotation.backgroundColor {
                textLayer.backgroundColor = bgColor
                textLayer.cornerRadius = 3
            } else {
                textLayer.backgroundColor = nil
                textLayer.cornerRadius = 0
            }
            let padding = textLayerPadding(for: textAnnotation)
            let attrs = textAnnotation.textAttributes()
            let size = (textAnnotation.text as NSString).size(withAttributes: attrs)
            textLayer.bounds = CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding)
            textLayer.position = CGPoint(x: textAnnotation.position.x + size.width / 2 + padding / 2,
                                         y: textAnnotation.position.y + size.height / 2 + padding / 2)
            return
        }

        guard let shapeLayer = layerToUpdate as? CAShapeLayer else { return }
        let path = CGMutablePath()

        if let arrow = annotation as? ArrowAnnotation {
            let geo = ArrowAnnotation.arrowGeometry(from: arrow.startPoint, to: arrow.endPoint,
                                                     headLength: arrow.arrowHeadLength, headAngle: arrow.arrowHeadAngle)
            path.move(to: arrow.startPoint)
            path.addLine(to: geo.basePoint)

            // Update arrowhead layer with filled triangle
            if let headLayer = arrowHeadLayers[arrow.id] {
                let headPath = CGMutablePath()
                headPath.move(to: arrow.endPoint)
                headPath.addLine(to: geo.point1)
                headPath.addLine(to: geo.point2)
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
            let geo = ArrowAnnotation.arrowGeometry(from: start, to: end)
            path.move(to: start)
            path.addLine(to: geo.basePoint)

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
            headPath.addLine(to: geo.point1)
            headPath.addLine(to: geo.point2)
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
        // Remove stale layers using Set difference (avoids O(n×m) nested contains)
        let currentIDs = Set(annotations.map { $0.id })
        for id in Set(annotationLayers.keys).subtracting(currentIDs) {
            annotationLayers[id]?.removeFromSuperlayer()
            annotationLayers.removeValue(forKey: id)
            arrowHeadLayers[id]?.removeFromSuperlayer()
            arrowHeadLayers.removeValue(forKey: id)
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

        // Ensure layer z-ordering matches array order
        reorderAnnotationLayers()
    }
}

// MARK: - NSTextFieldDelegate (font size field numeric filtering)

extension SelectionView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let tf = notification.object as? NSTextField else { return }
        let filtered = tf.stringValue.filter { $0.isNumber }
        if filtered != tf.stringValue {
            tf.stringValue = filtered
        }
    }
}

private extension CGFloat {
    func clampedTo(_ range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
