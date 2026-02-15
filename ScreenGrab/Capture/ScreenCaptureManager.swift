import AppKit
import CoreGraphics
import ScreenCaptureKit

class ScreenCaptureManager {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var previewWindow: ScreenshotPreviewWindow?
    private var isCapturing = false

    private static let captureSoundURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    func startCapture() {
        // Prevent re-entrant captures — covers both overlay phase and post-selection capture
        if isCapturing {
            logDebug("Capture already in progress, ignoring")
            return
        }
        isCapturing = true

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
                self?.isCapturing = false
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
            guard let cgImage = captureScreen(rect: captureRect, screenFrame: screenFrame) else {
                logError("Failed to capture screen - CGWindowListCreateImage returned nil")
                showCaptureError("Screen capture failed. Check screen recording permissions in System Settings.")
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

            // Save to file
            let savedPath = saveImageToFile(nsImage)

            // Play capture sound
            if AppSettings.shared.playSound {
                let sound = NSSound(contentsOf: Self.captureSoundURL, byReference: true) ?? NSSound(named: .init("Tink"))
                sound?.play()
            }

            // Show preview thumbnail on the screen where the capture happened
            DispatchQueue.main.async { [weak self] in
                self?.showPreviewThumbnail(image: nsImage, filePath: savedPath, screenFrame: screenFrame)
            }
        }

        isCapturing = false
        cleanupOverlays()
    }

    @discardableResult
    private func saveImageToFile(_ image: NSImage) -> String? {
        let savePath = AppSettings.shared.savePath
        let fileManager = FileManager.default

        // Create directory if needed
        if !fileManager.fileExists(atPath: savePath) {
            do {
                try fileManager.createDirectory(atPath: savePath, withIntermediateDirectories: true)
            } catch {
                logError("Failed to create save directory: \(error)")
                showCaptureError("Could not create save directory: \(savePath)")
                return nil
            }
        }

        // Generate filename with timestamp (millisecond precision to avoid collisions)
        let timestamp = Self.timestampFormatter.string(from: Date())
        let filename = "ScreenGrab_\(timestamp).png"
        let filePath = URL(fileURLWithPath: savePath).appendingPathComponent(filename).path

        // Write PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logError("Failed to create PNG data")
            return nil
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: filePath))
            logInfo("Saved screenshot to \(filePath)")
            return filePath
        } catch {
            logError("Failed to save screenshot: \(error)")
            showCaptureError("Could not save screenshot to \(filePath)")
            return nil
        }
    }

    private func showPreviewThumbnail(image: NSImage, filePath: String?, screenFrame: CGRect) {
        // Dismiss any existing preview
        previewWindow?.dismiss()
        previewWindow = nil

        // Find the NSScreen matching the capture screen frame
        guard let screen = NSScreen.screens.first(where: {
            abs($0.frame.origin.x - screenFrame.origin.x) < 1 && abs($0.frame.width - screenFrame.width) < 1
        }) ?? NSScreen.main else { return }

        let preview = ScreenshotPreviewWindow(image: image, filePath: filePath, screen: screen)
        preview.onDismiss = { [weak self] in
            self?.previewWindow = nil
        }
        preview.orderFrontRegardless()
        previewWindow = preview
    }

    private func cleanupOverlays() {
        for window in overlayWindows {
            window.onSelectionComplete = nil
            window.onCancel = nil
            window.stopEventMonitors()
        }
        overlayWindows.removeAll()

        // Restore focus to the app that was active before capture started
        previousApp?.activate()
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
                } else if let textAnnotation = annotation as? TextAnnotation {
                    let translatedPosition = CGPoint(
                        x: textAnnotation.position.x - selectionRect.origin.x,
                        y: textAnnotation.position.y - selectionRect.origin.y
                    )
                    // Draw background rect if set
                    if let bgColor = textAnnotation.backgroundColor {
                        let textSize = textAnnotation.textSize()
                        let padding = textAnnotation.backgroundPadding
                        let bgRect = CGRect(
                            x: translatedPosition.x - padding,
                            y: translatedPosition.y - padding,
                            width: textSize.width + padding * 2,
                            height: textSize.height + padding * 2
                        )
                        context.setFillColor(bgColor)
                        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                        context.addPath(bgPath)
                        context.fillPath()
                    }
                    let attrs = textAnnotation.textAttributes()
                    (textAnnotation.text as NSString).draw(
                        at: translatedPosition,
                        withAttributes: attrs
                    )
                }
            }
        }

        finalImage.unlockFocus()

        return finalImage
    }

    private func captureScreen(rect: CGRect, screenFrame: CGRect) -> CGImage? {
        // Try ScreenCaptureKit first (macOS 14+), fallback to CGWindowListCreateImage
        if #available(macOS 14.0, *) {
            if let image = captureWithScreenCaptureKit(rect: rect, screenFrame: screenFrame) {
                return image
            }
        }

        // Fallback to old API - rect is already in screen coordinates (top-left origin)
        return CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, kCGNullWindowID, [.bestResolution])
    }

    private class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(rect: CGRect, screenFrame: CGRect) -> CGImage? {
        let box = ImageBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task { @Sendable in
            do {
                let content = try await SCShareableContent.current

                // Find the display matching the screen where the user made their selection
                guard let display = content.displays.first(where: { display in
                    return abs(display.frame.origin.x - screenFrame.origin.x) < 1
                        && abs(CGFloat(display.width) - screenFrame.width) < 1
                }) ?? content.displays.first else {
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
                    x: (rect.origin.x - display.frame.origin.x) * scale,
                    y: (rect.origin.y - display.frame.origin.y) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )

                // Clamp crop rect to image bounds to prevent nil from cropping(to:)
                let clampedRect = cropRect.intersection(CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height))
                guard !clampedRect.isNull && clampedRect.width > 0 && clampedRect.height > 0 else {
                    logError("Crop rect outside image bounds: \(cropRect) vs \(fullImage.width)x\(fullImage.height)")
                    semaphore.signal()
                    return
                }
                box.image = fullImage.cropping(to: clampedRect)
            } catch {
                logError("ScreenCaptureKit error: \(error)")
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return box.image
    }

    private func showCaptureError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screenshot Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        cleanupOverlays()
    }
}
