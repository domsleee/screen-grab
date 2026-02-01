import AppKit
import CoreGraphics
import ScreenCaptureKit

class ScreenCaptureManager {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var editorWindow: NSWindow?
    private var canvasView: AnnotationCanvasView?
    private var previousApp: NSRunningApplication?

    func startCapture() {
        // Close any existing overlays
        closeOverlays()

        // Remember the currently active app to restore later
        previousApp = NSWorkspace.shared.frontmostApplication

        // Create overlay windows for all screens (non-activating panels)
        for screen in NSScreen.screens {
            let overlayWindow = SelectionOverlayWindow(screen: screen)
            overlayWindow.onSelectionComplete = { [weak self] rect, screenFrame, annotations in
                self?.handleSelectionComplete(rect: rect, screenFrame: screenFrame, annotations: annotations)
            }
            overlayWindow.onCancel = { [weak self] in
                self?.closeOverlays()
            }
            overlayWindows.append(overlayWindow)
            overlayWindow.show()
        }
        
        // Don't activate - panels are non-activating
    }

    private func handleSelectionComplete(rect: CGRect, screenFrame: CGRect, annotations: [any Annotation]) {
        logInfo("Selection complete: \(Int(rect.width))x\(Int(rect.height)) with \(annotations.count) annotations")

        // Hide overlays FIRST so they don't appear in the capture
        for window in overlayWindows {
            window.orderOut(nil)
        }

        // Small delay to ensure windows are fully hidden before capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.performCapture(rect: rect, screenFrame: screenFrame, annotations: annotations)
        }
    }

    private func performCapture(rect: CGRect, screenFrame: CGRect, annotations: [any Annotation]) {
        autoreleasepool {
            // Convert to screen coordinates for capture
            let captureRect = CGRect(
                x: rect.origin.x + screenFrame.origin.x,
                y: screenFrame.height - rect.origin.y - rect.height + screenFrame.origin.y,
                width: rect.width,
                height: rect.height
            )
            
            logDebug("Capturing rect: \(captureRect)")

            // Capture the screen region
            guard let cgImage = captureScreen(rect: captureRect) else {
                logError("Failed to capture screen - CGWindowListCreateImage returned nil")
                cleanupOverlays()
                return
            }

            var nsImage = NSImage(cgImage: cgImage, size: rect.size)
            logDebug("Captured image: \(cgImage.width)x\(cgImage.height)")

            // If we have annotations, render them onto the image
            if !annotations.isEmpty {
                nsImage = renderAnnotations(annotations, onto: nsImage, selectionRect: rect)
            }

            // Copy to clipboard
            ClipboardManager.copy(image: nsImage)
            logInfo("Copied to clipboard")
        }

        cleanupOverlays()
    }

    private func cleanupOverlays() {
        for window in overlayWindows {
            window.onSelectionComplete = nil
            window.onCancel = nil
            window.stopEventMonitors()
        }
        overlayWindows.removeAll()
        previousApp = nil
    }

    private func renderAnnotations(
        _ annotations: [any Annotation],
        onto image: NSImage,
        selectionRect: CGRect
    ) -> NSImage {
        let finalImage = NSImage(size: image.size)

        finalImage.lockFocus()

        // Draw original image
        image.draw(in: NSRect(origin: .zero, size: image.size))

        // Draw annotations - need to translate coordinates from screen to image
        if let context = NSGraphicsContext.current?.cgContext {
            for annotation in annotations {
                // Create a translated copy for rendering
                if let rectAnnotation = annotation as? RectangleAnnotation {
                    let translatedBounds = CGRect(
                        x: rectAnnotation.bounds.origin.x - selectionRect.origin.x,
                        y: rectAnnotation.bounds.origin.y - selectionRect.origin.y,
                        width: rectAnnotation.bounds.width,
                        height: rectAnnotation.bounds.height
                    )
                    context.setStrokeColor(rectAnnotation.color)
                    context.setLineWidth(rectAnnotation.strokeWidth)
                    context.stroke(translatedBounds)
                } else if let arrowAnnotation = annotation as? ArrowAnnotation {
                    let translatedStart = CGPoint(
                        x: arrowAnnotation.startPoint.x - selectionRect.origin.x,
                        y: arrowAnnotation.startPoint.y - selectionRect.origin.y
                    )
                    let translatedEnd = CGPoint(
                        x: arrowAnnotation.endPoint.x - selectionRect.origin.x,
                        y: arrowAnnotation.endPoint.y - selectionRect.origin.y
                    )
                    let translatedArrow = ArrowAnnotation(
                        startPoint: translatedStart,
                        endPoint: translatedEnd,
                        color: arrowAnnotation.color,
                        strokeWidth: arrowAnnotation.strokeWidth
                    )
                    translatedArrow.draw(in: context)
                }
            }
        }

        finalImage.unlockFocus()

        return finalImage
    }

    private func captureScreen(rect: CGRect) -> CGImage? {
        // Try ScreenCaptureKit first (macOS 14+), fallback to CGWindowListCreateImage
        if #available(macOS 14.0, *) {
            if let image = captureWithScreenCaptureKit(rect: rect) {
                return image
            }
        }
        
        // Fallback to old API - rect is already in screen coordinates (top-left origin)
        return CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, kCGNullWindowID, [.bestResolution])
    }
    
    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(rect: CGRect) -> CGImage? {
        let box = UnsafeMutablePointer<CGImage?>.allocate(capacity: 1)
        box.initialize(to: nil)
        let semaphore = DispatchSemaphore(value: 0)
        
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    logError("No display found")
                    semaphore.signal()
                    return
                }
                
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Int(display.width) * 2
                config.height = Int(display.height) * 2
                config.showsCursor = false
                
                let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                
                // rect is already in screen coordinates (top-left origin)
                let scale = CGFloat(fullImage.width) / CGFloat(display.width)
                let cropRect = CGRect(
                    x: rect.origin.x * scale,
                    y: rect.origin.y * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                
                box.pointee = fullImage.cropping(to: cropRect)
            } catch {
                logError("ScreenCaptureKit error: \(error)")
            }
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 5)
        let result = box.pointee
        box.deallocate()
        return result
    }

    private func openAnnotationEditor(with image: NSImage) {
        // Create window sized to image (with some max bounds)
        let maxSize = NSSize(width: 1200, height: 800)
        let imageWidth = max(image.size.width, 100)
        let imageHeight = max(image.size.height, 100)
        let windowSize = NSSize(
            width: min(imageWidth + 40, maxSize.width),
            height: min(imageHeight + 100, maxSize.height)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Annotate Screenshot"
        window.center()
        window.isReleasedWhenClosed = false

        // Create canvas view
        let canvas = AnnotationCanvasView(image: image)
        canvas.frame = NSRect(origin: .zero, size: image.size)
        canvas.onComplete = { [weak self] finalImage in
            ClipboardManager.copy(image: finalImage)
            self?.editorWindow?.close()
            self?.editorWindow = nil
        }
        canvas.onCancel = { [weak self] in
            self?.editorWindow?.close()
            self?.editorWindow = nil
        }
        self.canvasView = canvas

        // Create scroll view
        let scrollViewFrame = window.contentView?.bounds ?? .zero
        let scrollView = NSScrollView(frame: scrollViewFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.documentView = canvas

        window.contentView = scrollView

        // Store and show window
        self.editorWindow = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)

        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        cleanupOverlays()
    }
}
