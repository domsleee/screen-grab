import AppKit

func debugLog(_ message: String) {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

class AnnotationEditorWindowController: NSWindowController {
    private let image: NSImage
    private var canvasView: AnnotationCanvasView?
    
    init(image: NSImage) {
        self.image = image
        
        debugLog("DEBUG EDITOR: Starting init with image size: \(image.size)")
        
        // Create window sized to image (with some max bounds)
        let maxSize = NSSize(width: 1200, height: 800)
        let imageWidth = max(image.size.width, 100)
        let imageHeight = max(image.size.height, 100)
        let windowSize = NSSize(
            width: min(imageWidth + 40, maxSize.width),
            height: min(imageHeight + 100, maxSize.height)
        )
        
        debugLog("DEBUG EDITOR: Creating window with size: \(windowSize)")
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        debugLog("DEBUG EDITOR: Window created")
        
        window.title = "Annotate Screenshot"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        debugLog("DEBUG EDITOR: super.init done, calling setupUI")
        
        setupUI()
        
        debugLog("DEBUG EDITOR: Init complete")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func showWindow(_ sender: Any?) {
        debugLog("DEBUG EDITOR: showWindow called")
        super.showWindow(sender)
        debugLog("DEBUG EDITOR: super.showWindow done")
        // Defer making first responder to next run loop to avoid crash
        DispatchQueue.main.async { [weak self] in
            if let canvas = self?.canvasView, let window = self?.window {
                debugLog("DEBUG EDITOR: Making canvas first responder (deferred)")
                window.makeFirstResponder(canvas)
                debugLog("DEBUG EDITOR: makeFirstResponder done")
            }
        }
    }
    
    private func setupUI() {
        guard let window = window, let windowContentView = window.contentView else { return }
        
        debugLog("DEBUG EDITOR: setupUI starting")
        
        let contentView = NSView(frame: windowContentView.bounds)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.red.cgColor  // Just show red for testing
        
        window.contentView = contentView
        
        debugLog("DEBUG EDITOR: setupUI done (simplified)")
    }
    
    private func createToolbar() -> NSView {
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 8
        stackView.alignment = .centerY
        
        // Tool buttons
        let selectButton = createToolButton(title: "Select (V)", tool: .select)
        let rectButton = createToolButton(title: "Rectangle (R)", tool: .rectangle)
        let arrowButton = createToolButton(title: "Arrow (A)", tool: .arrow)
        
        stackView.addArrangedSubview(selectButton)
        stackView.addArrangedSubview(rectButton)
        stackView.addArrangedSubview(arrowButton)
        
        // Spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacer)
        
        // Instructions
        let instructions = NSTextField(labelWithString: "Enter/⌘C to copy • ESC to cancel")
        instructions.font = NSFont.systemFont(ofSize: 11)
        instructions.textColor = NSColor.secondaryLabelColor
        stackView.addArrangedSubview(instructions)
        
        // Copy button
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyAction))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        stackView.addArrangedSubview(copyButton)
        
        toolbar.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stackView.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        
        return toolbar
    }
    
    private func createToolButton(title: String, tool: AnnotationTool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(toolSelected(_:)))
        button.bezelStyle = .rounded
        button.tag = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
        return button
    }
    
    @objc private func toolSelected(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        canvasView?.currentTool = tool
    }
    
    @objc private func copyAction() {
        canvasView?.completeEditing()
    }
    
    private func copyToClipboard(image: NSImage) {
        ClipboardManager.copy(image: image)
        showCopiedNotification()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.close()
        }
    }
    
    private func showCopiedNotification() {
        guard let window = window else { return }
        
        let notification = NSTextField(labelWithString: "✓ Copied to clipboard!")
        notification.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        notification.textColor = .white
        notification.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        notification.drawsBackground = true
        notification.alignment = .center
        notification.isBezeled = false
        notification.sizeToFit()
        notification.frame.size.width += 32
        notification.frame.size.height += 16
        notification.wantsLayer = true
        notification.layer?.cornerRadius = 8
        
        notification.frame.origin = NSPoint(
            x: (window.contentView!.bounds.width - notification.frame.width) / 2,
            y: (window.contentView!.bounds.height - notification.frame.height) / 2
        )
        
        window.contentView?.addSubview(notification)
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }, completionHandler: nil)
    }
}
