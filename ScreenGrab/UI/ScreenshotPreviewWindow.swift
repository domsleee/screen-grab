import AppKit

class ScreenshotPreviewWindow: NSPanel {
    private static let thumbnailMaxWidth: CGFloat = 200
    private static let cornerRadius: CGFloat = 12
    private static let padding: CGFloat = 20
    private static let displayDuration: TimeInterval = 5
    private static let animationDuration: TimeInterval = 0.3
    private static let fadeOutDuration: TimeInterval = 0.5
    private static let dragThresholdSquared: CGFloat = 25

    private var dismissTimer: Timer?
    private var filePath: String?
    private var isDragging = false
    private var dragStartLocation: NSPoint = .zero
    var onDismiss: (() -> Void)?

    init(image: NSImage, filePath: String?, screen: NSScreen) {
        self.filePath = filePath

        // Calculate thumbnail size maintaining aspect ratio
        let aspect = image.size.height / image.size.width
        let thumbWidth = Self.thumbnailMaxWidth
        let thumbHeight = thumbWidth * aspect

        let contentSize = NSSize(width: thumbWidth, height: thumbHeight)

        // Start offscreen to the right for slide-in animation
        let visibleFrame = screen.visibleFrame
        let startX = visibleFrame.maxX + Self.padding
        let startY = visibleFrame.minY + Self.padding

        super.init(
            contentRect: NSRect(origin: NSPoint(x: startX, y: startY), size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Build content view: outer container for shadow, inner clip for rounded corners
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.4
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        container.layer?.shadowRadius = 10

        let clipView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Self.cornerRadius
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        clipView.layer?.borderWidth = 0.5

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: contentSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]

        clipView.addSubview(imageView)
        container.addSubview(clipView)
        self.contentView = container

        // Slide in
        let finalX = visibleFrame.maxX - thumbWidth - Self.padding
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(
                NSRect(x: finalX, y: startY, width: thumbWidth, height: thumbHeight),
                display: true
            )
        }

        // Auto-dismiss timer — explicitly use main RunLoop
        let timer = Timer(timeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            self?.fadeOutAndClose()
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    deinit {
        dismissTimer?.invalidate()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let dx = current.x - dragStartLocation.x
        let dy = current.y - dragStartLocation.y
        if !isDragging && (dx * dx + dy * dy) > Self.dragThresholdSquared {
            isDragging = true
        }
        if isDragging {
            // Move window with drag
            var origin = self.frame.origin
            origin.x += dx
            origin.y += dy
            self.setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            fadeOutAndClose()
        } else {
            // Click - open file in Finder
            if let filePath = filePath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
            }
            dismissImmediately()
        }
    }

    func dismiss() {
        fadeOutAndClose()
    }

    private func fadeOutAndClose() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss?()
        })
    }

    private func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
        onDismiss?()
    }
}
