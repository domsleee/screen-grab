import XCTest
@testable import ScreenGrab

/// Benchmarks for hot-path operations identified in the performance audit.
/// Run with: swift test --filter PerformanceBenchmarks
///
/// Each test uses XCTest's measure{} which runs 10 iterations and reports avg/stddev.
/// The "current" variant measures the code as-is; where noted, an "optimized" variant
/// shows what caching or batching would achieve.
final class PerformanceBenchmarks: XCTestCase {

    // =========================================================================
    // MARK: - 1. Crosshair Cursor: NSImage Allocation per Mouse Move
    // =========================================================================
    // Audit item C6: buildCrosshairCursor() creates a full NSImage + NSCursor
    // on every mouseMoved event.

    /// Measures cost of building one crosshair cursor image (the per-mouse-move cost).
    func testCrosshairCursorBuild_perCall() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let charSize = ("0" as NSString).size(withAttributes: attrs)

        measure {
            // Simulate 500 mouse moves (a ~3-second drag at 160Hz)
            for i in 0..<500 {
                let x = CGFloat(i)
                let y = CGFloat(i * 2)
                let coordText = "\(Int(x)), \(Int(y))"
                let textSize = NSSize(
                    width: charSize.width * CGFloat(coordText.count),
                    height: charSize.height
                )
                let crosshairSize: CGFloat = 33
                let center = crosshairSize / 2
                let textOffsetX = center + 8
                let totalWidth = textOffsetX + textSize.width + 8
                let totalHeight = crosshairSize + textSize.height + 8

                let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
                image.lockFocus()

                // Simplified crosshair drawing (same cost profile as real code)
                NSColor.black.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 5
                path.move(to: NSPoint(x: 2, y: center))
                path.line(to: NSPoint(x: crosshairSize - 2, y: center))
                path.move(to: NSPoint(x: center, y: 2))
                path.line(to: NSPoint(x: center, y: crosshairSize - 2))
                path.stroke()

                NSColor.white.setStroke()
                let inner = NSBezierPath()
                inner.lineWidth = 2
                inner.move(to: NSPoint(x: 2, y: center))
                inner.line(to: NSPoint(x: crosshairSize - 2, y: center))
                inner.move(to: NSPoint(x: center, y: 2))
                inner.line(to: NSPoint(x: center, y: crosshairSize - 2))
                inner.stroke()

                // Background rect + text
                NSColor.black.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: NSRect(x: textOffsetX - 4, y: 2,
                                                  width: textSize.width + 8,
                                                  height: textSize.height + 4),
                             xRadius: 3, yRadius: 3).fill()
                (coordText as NSString).draw(at: NSPoint(x: textOffsetX, y: 4), withAttributes: attrs)

                image.unlockFocus()
                _ = NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
            }
        }
    }

    /// Optimized: only rebuild cursor when coordinate text changes (integer coords).
    func testCrosshairCursorBuild_cachedByCoordText() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var cache: [String: NSCursor] = [:]

        measure {
            for i in 0..<500 {
                // Sub-pixel movement: many consecutive events map to same integer coords
                let x = Int(CGFloat(i) * 0.3)
                let y = Int(CGFloat(i) * 0.6)
                let key = "\(x), \(y)"

                if cache[key] != nil { continue }

                let charSize = ("0" as NSString).size(withAttributes: attrs)
                let textSize = NSSize(width: charSize.width * CGFloat(key.count), height: charSize.height)
                let crosshairSize: CGFloat = 33
                let center = crosshairSize / 2
                let totalWidth = center + 8 + textSize.width + 8
                let totalHeight = crosshairSize + textSize.height + 8

                let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
                image.lockFocus()
                NSColor.black.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 5
                path.move(to: NSPoint(x: 2, y: center))
                path.line(to: NSPoint(x: crosshairSize - 2, y: center))
                path.stroke()
                (key as NSString).draw(at: NSPoint(x: center + 8, y: 4), withAttributes: attrs)
                image.unlockFocus()

                cache[key] = NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
            }
        }
    }

    // =========================================================================
    // MARK: - 2. Text Size Measurement in Draw Calls
    // =========================================================================
    // Audit items I6, M2, M3: .size(withAttributes:) and NSFont.systemFont()
    // called repeatedly in draw(rect:) and textSize().

    /// Measures cost of repeated text size calculations (current behavior).
    func testTextSizeMeasurement_uncached() {
        let labels = ["V", "R", "A", "T", "Tab", "Esc"]

        measure {
            // Simulate 1000 draw cycles (toolbar redrawn every frame during drag)
            for _ in 0..<1000 {
                for label in labels {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                        .foregroundColor: NSColor.white
                    ]
                    _ = label.size(withAttributes: attrs)
                }
            }
        }
    }

    /// Optimized: cache font + sizes (labels are static strings).
    func testTextSizeMeasurement_cached() {
        let labels = ["V", "R", "A", "T", "Tab", "Esc"]
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var sizeCache: [String: NSSize] = [:]
        for label in labels {
            sizeCache[label] = label.size(withAttributes: attrs)
        }

        measure {
            for _ in 0..<1000 {
                for label in labels {
                    _ = sizeCache[label]!
                }
            }
        }
    }

    /// TextAnnotation.textSize() — creates NSFont + measures string each call.
    func testTextAnnotation_textSizeRepeated() {
        let annotation = TextAnnotation(text: "Hello World! This is a benchmark.", position: .zero, fontSize: 24)

        measure {
            // textSize() is called from bounds getter, backgroundRect, layer updates, drawing
            // Simulate 5000 accesses (a busy drag-resize session)
            for _ in 0..<5000 {
                _ = annotation.textSize()
            }
        }
    }

    /// Optimized: cache textSize until text or fontSize changes.
    func testTextAnnotation_textSizeCached() {
        let text = "Hello World! This is a benchmark."
        let fontSize: CGFloat = 24
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let cachedSize = (text as NSString).size(withAttributes: attrs)

        measure {
            for _ in 0..<5000 {
                _ = cachedSize
            }
        }
    }

    // =========================================================================
    // MARK: - 3. CGColorSpace Creation
    // =========================================================================
    // Audit item M1: CGColorSpaceCreateDeviceRGB() called inside functions
    // that run during color popover rendering and color comparison.

    /// Measures repeated color space creation + color conversion.
    func testColorSpaceCreation_perCall() {
        let testColor = CGColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)

        measure {
            // colorsMatch() is called per-swatch in color popover (8 swatches × redraws)
            for _ in 0..<10000 {
                let rgbSpace = CGColorSpaceCreateDeviceRGB()
                _ = testColor.converted(to: rgbSpace, intent: .defaultIntent, options: nil)
            }
        }
    }

    /// Optimized: static color space, reused across all calls.
    func testColorSpaceCreation_static() {
        let testColor = CGColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)
        let rgbSpace = CGColorSpaceCreateDeviceRGB() // created once

        measure {
            for _ in 0..<10000 {
                _ = testColor.converted(to: rgbSpace, intent: .defaultIntent, options: nil)
            }
        }
    }

    /// Full colorsMatch() simulation: two conversions + component comparison.
    func testColorsMatch_perCall() {
        let colors: [CGColor] = (0..<8).map { i in
            CGColor(red: CGFloat(i) / 8.0, green: 0.5, blue: 0.5, alpha: 1.0)
        }
        let target = CGColor(red: 0.375, green: 0.5, blue: 0.5, alpha: 1.0)

        measure {
            // 1000 redraws × 8 swatches = 8000 comparisons
            for _ in 0..<1000 {
                for color in colors {
                    let rgbSpace = CGColorSpaceCreateDeviceRGB()
                    guard let ac = target.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
                          let bc = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
                          let aComps = ac.components, let bComps = bc.components,
                          aComps.count == bComps.count else { continue }
                    _ = zip(aComps, bComps).allSatisfy { abs($0 - $1) < 0.01 }
                }
            }
        }
    }

    // =========================================================================
    // MARK: - 4. Arrow Geometry (Trigonometry)
    // =========================================================================
    // Audit item I8: arrowGeometry() uses atan2/cos/sin, called multiple
    // times per frame for hit-testing and visual bounds.

    /// Measures arrow geometry computation (trig-heavy).
    func testArrowGeometry_perCall() {
        let start = CGPoint(x: 100, y: 200)
        let end = CGPoint(x: 400, y: 350)

        measure {
            // Called 2-4x per annotation per frame (visualBounds + layer update + hit test)
            // 50 arrows × 3 calls × 1000 frames
            for _ in 0..<150_000 {
                _ = ArrowAnnotation.arrowGeometry(from: start, to: end)
            }
        }
    }

    /// Optimized: cache geometry on the annotation (recompute only when endpoints change).
    func testArrowGeometry_cached() {
        let start = CGPoint(x: 100, y: 200)
        let end = CGPoint(x: 400, y: 350)
        let cached = ArrowAnnotation.arrowGeometry(from: start, to: end)

        measure {
            for _ in 0..<150_000 {
                _ = cached
            }
        }
    }

    // =========================================================================
    // MARK: - 5. Annotation Hit Testing: O(n) Linear Scan
    // =========================================================================
    // Audit item I7: updateHoverState iterates all annotations reversed,
    // computing visualBounds for each, on every mouse move.

    /// Measures hit-test scan with varying annotation counts.
    func testHitTestScan_10annotations() {
        let annotations = makeAnnotationMix(count: 10)
        let testPoint = CGPoint(x: 500, y: 500)

        measure {
            for _ in 0..<5000 {
                hitTestAll(annotations: annotations, point: testPoint)
            }
        }
    }

    func testHitTestScan_50annotations() {
        let annotations = makeAnnotationMix(count: 50)
        let testPoint = CGPoint(x: 500, y: 500)

        measure {
            for _ in 0..<5000 {
                hitTestAll(annotations: annotations, point: testPoint)
            }
        }
    }

    func testHitTestScan_200annotations() {
        let annotations = makeAnnotationMix(count: 200)
        let testPoint = CGPoint(x: 500, y: 500)

        measure {
            for _ in 0..<5000 {
                hitTestAll(annotations: annotations, point: testPoint)
            }
        }
    }

    // =========================================================================
    // MARK: - 6. Undo Snapshot: Full Array Copy
    // =========================================================================
    // Audit item C5: snapshotAnnotations() copies all annotation data on every
    // state change, with no size limit on the undo stack.

    /// Measures cost of snapshotting N annotations (the per-edit cost).
    func testUndoSnapshot_10annotations() {
        let annotations = makeAnnotationMix(count: 10)
        measure {
            for _ in 0..<10000 {
                _ = snapshotAnnotations(annotations)
            }
        }
    }

    func testUndoSnapshot_50annotations() {
        let annotations = makeAnnotationMix(count: 50)
        measure {
            for _ in 0..<10000 {
                _ = snapshotAnnotations(annotations)
            }
        }
    }

    /// Measures memory growth: 100 undo pushes with 50 annotations each.
    func testUndoStackMemoryGrowth() {
        let annotations = makeAnnotationMix(count: 50)
        var undoStack: [[AnnotationSnapshotData]] = []

        measure {
            undoStack.removeAll()
            for _ in 0..<100 {
                undoStack.append(snapshotAnnotations(annotations))
            }
        }
        // After measure: 100 snapshots × 50 annotations = 5000 snapshot objects
        // Each snapshot holds copies of all properties including CGColor refs
    }

    // =========================================================================
    // MARK: - 7. visualBounds() for Arrows (in Hit-Test Loop)
    // =========================================================================
    // Audit item I8: visualBounds calls arrowGeometry + min/max on 4 points
    // for every arrow annotation on every mouse move.

    func testVisualBounds_arrowsInLoop() {
        let arrows: [ArrowAnnotation] = (0..<30).map { i in
            ArrowAnnotation(
                startPoint: CGPoint(x: CGFloat(i) * 50, y: CGFloat(i) * 30),
                endPoint: CGPoint(x: CGFloat(i) * 50 + 100, y: CGFloat(i) * 30 + 80)
            )
        }

        measure {
            // 2000 mouse moves, each checking all 30 arrows
            for _ in 0..<2000 {
                for arrow in arrows {
                    let geo = ArrowAnnotation.arrowGeometry(
                        from: arrow.startPoint, to: arrow.endPoint,
                        headLength: arrow.arrowHeadLength, headAngle: arrow.arrowHeadAngle
                    )
                    let allX = [arrow.startPoint.x, arrow.endPoint.x, geo.point1.x, geo.point2.x]
                    let allY = [arrow.startPoint.y, arrow.endPoint.y, geo.point1.y, geo.point2.y]
                    _ = CGRect(
                        x: allX.min()!, y: allY.min()!,
                        width: allX.max()! - allX.min()!, height: allY.max()! - allY.min()!
                    ).insetBy(dx: -4, dy: -4)
                }
            }
        }
    }

    // =========================================================================
    // MARK: - 8. syncAnnotationLayers() Cost
    // =========================================================================
    // Audit item I13: full layer sync on every annotation change.
    // We can't benchmark actual CALayer ops in tests, but we can measure
    // the dictionary lookups + array iteration pattern.

    func testSyncAnnotationLayers_dictionaryPattern() {
        let annotations = makeAnnotationMix(count: 50)
        var layerMap: [UUID: Bool] = [:] // simulate annotationLayers dict
        for a in annotations { layerMap[a.id] = true }

        measure {
            for _ in 0..<5000 {
                // Remove stale layers (current O(n×m) pattern)
                var toRemove: [UUID] = []
                for id in layerMap.keys {
                    if !annotations.contains(where: { $0.id == id }) {
                        toRemove.append(id)
                    }
                }
                for id in toRemove { layerMap.removeValue(forKey: id) }

                // Add/update layers for current annotations
                for annotation in annotations {
                    if layerMap[annotation.id] != nil {
                        // update existing (no-op in benchmark)
                    } else {
                        layerMap[annotation.id] = true
                    }
                }
            }
        }
    }

    /// Optimized: use Set difference instead of nested contains().
    func testSyncAnnotationLayers_setDifference() {
        let annotations = makeAnnotationMix(count: 50)
        var layerMap: [UUID: Bool] = [:]
        for a in annotations { layerMap[a.id] = true }

        measure {
            for _ in 0..<5000 {
                let currentIDs = Set(annotations.map { $0.id })
                let layerIDs = Set(layerMap.keys)

                // Remove stale
                for id in layerIDs.subtracting(currentIDs) {
                    layerMap.removeValue(forKey: id)
                }

                // Add/update
                for annotation in annotations {
                    if layerMap[annotation.id] != nil {
                        // update
                    } else {
                        layerMap[annotation.id] = true
                    }
                }
            }
        }
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    /// Creates a mixed array of annotation types for realistic benchmarks.
    private func makeAnnotationMix(count: Int) -> [any Annotation] {
        (0..<count).map { i -> any Annotation in
            switch i % 3 {
            case 0:
                return RectangleAnnotation(
                    bounds: CGRect(x: CGFloat(i) * 40, y: CGFloat(i) * 30,
                                   width: 100, height: 80)
                )
            case 1:
                return ArrowAnnotation(
                    startPoint: CGPoint(x: CGFloat(i) * 40, y: CGFloat(i) * 30),
                    endPoint: CGPoint(x: CGFloat(i) * 40 + 120, y: CGFloat(i) * 30 + 90)
                )
            default:
                return TextAnnotation(
                    text: "Label \(i)", position: CGPoint(x: CGFloat(i) * 40, y: CGFloat(i) * 30),
                    fontSize: 24
                )
            }
        }
    }

    /// Simulates the current hit-test scan: reversed iteration with visualBounds.
    private func hitTestAll(annotations: [any Annotation], point: CGPoint) -> (any Annotation)? {
        for annotation in annotations.reversed() {
            let rect: CGRect
            if let arrow = annotation as? ArrowAnnotation {
                let geo = ArrowAnnotation.arrowGeometry(
                    from: arrow.startPoint, to: arrow.endPoint,
                    headLength: arrow.arrowHeadLength, headAngle: arrow.arrowHeadAngle
                )
                let allX = [arrow.startPoint.x, arrow.endPoint.x, geo.point1.x, geo.point2.x]
                let allY = [arrow.startPoint.y, arrow.endPoint.y, geo.point1.y, geo.point2.y]
                rect = CGRect(
                    x: allX.min()!, y: allY.min()!,
                    width: allX.max()! - allX.min()!, height: allY.max()! - allY.min()!
                ).insetBy(dx: -4, dy: -4)
            } else {
                rect = annotation.bounds.insetBy(dx: -4, dy: -4)
            }
            if rect.contains(point) {
                return annotation
            }
        }
        return nil
    }

    // Lightweight snapshot struct for benchmarking (mirrors the real AnnotationSnapshot enum)
    enum AnnotationSnapshotData {
        case arrow(id: UUID, startPoint: CGPoint, endPoint: CGPoint, color: CGColor, strokeWidth: CGFloat)
        case rectangle(id: UUID, bounds: CGRect, color: CGColor, strokeWidth: CGFloat)
        case text(id: UUID, text: String, position: CGPoint, fontSize: CGFloat, color: CGColor)
    }

    private func snapshotAnnotations(_ annotations: [any Annotation]) -> [AnnotationSnapshotData] {
        annotations.map { annotation in
            if let arrow = annotation as? ArrowAnnotation {
                return .arrow(id: arrow.id, startPoint: arrow.startPoint, endPoint: arrow.endPoint,
                              color: arrow.color, strokeWidth: arrow.strokeWidth)
            } else if let rect = annotation as? RectangleAnnotation {
                return .rectangle(id: rect.id, bounds: rect.bounds, color: rect.color, strokeWidth: rect.strokeWidth)
            } else if let text = annotation as? TextAnnotation {
                return .text(id: text.id, text: text.text, position: text.position,
                             fontSize: text.fontSize, color: text.color)
            }
            return .rectangle(id: UUID(), bounds: .zero, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0), strokeWidth: 0)
        }
    }
}
