import AppKit
import CoreGraphics

class ScreenCaptureManager {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var editorWindow: NSWindow?
    private var canvasView: AnnotationCanvasView?
    
    func startCapture() {
        // Close any existing overlays
        closeOverlays()
        
        // Temporarily become a regular app to receive keyboard focus
        NSApp.setActivationPolicy(.regular)
        
        // Create overlay windows for all screens
        for screen in NSScreen.screens {
            let overlayWindow = SelectionOverlayWindow(screen: screen)
            overlayWindow.onSelectionComplete = { [weak self] rect, screenFrame, annotations in
                self?.handleSelectionComplete(rect: rect, screenFrame: screenFrame, annotations: annotations)
            }
            overlayWindow.onCancel = { [weak self] in
                self?.closeOverlays()
            }
            overlayWindows.append(overlayWindow)
            overlayWindow.makeKeyAndOrderFront(nil)
        }
        
        // Activate app AFTER windows are shown
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func handleSelectionComplete(rect: CGRect, screenFrame: CGRect, annotations: [any Annotation]) {
        // Convert to screen coordinates for capture
        let captureRect = CGRect(
            x: rect.origin.x + screenFrame.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height + screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )
        
        // Capture the screen region
        guard let cgImage = captureScreen(rect: captureRect) else {
            print("Failed to capture screen")
            closeOverlays()
            return
        }
        
        var nsImage = NSImage(cgImage: cgImage, size: rect.size)
        
        // If we have annotations, render them onto the image
        if !annotations.isEmpty {
            nsImage = renderAnnotations(annotations, onto: nsImage, selectionRect: rect)
        }
        
        // Copy to clipboard
        ClipboardManager.copy(image: nsImage)
        
        // Close overlays after everything is done
        DispatchQueue.main.async { [weak self] in
            self?.closeOverlays()
        }
    }
    
    private func renderAnnotations(_ annotations: [any Annotation], onto image: NSImage, selectionRect: CGRect) -> NSImage {
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
        // Convert from AppKit coordinates to CoreGraphics coordinates
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let cgRect = CGRect(
            x: rect.origin.x,
            y: mainDisplayBounds.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        
        return CGWindowListCreateImage(
            cgRect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.bestResolution]
        )
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
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
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
            // Clear callbacks and stop monitors
            window.onSelectionComplete = nil
            window.onCancel = nil
            window.stopKeyMonitors()
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        
        // Go back to accessory app (menu bar only)
        NSApp.setActivationPolicy(.accessory)
    }
}
