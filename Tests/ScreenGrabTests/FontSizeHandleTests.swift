import XCTest
@testable import ScreenGrab

/// Tests that selection handles stay in sync with TextAnnotation bounds
/// after font size changes.
final class FontSizeHandleTests: XCTestCase {

    /// Model that mirrors the selection handle update contract in SelectionView.
    /// When a selected annotation's font size changes, the handle positions
    /// (derived from annotation.bounds corners) must be recomputed.
    private struct SelectionHandleModel {
        var annotation: TextAnnotation
        var handleCorners: [CGPoint]

        init(annotation: TextAnnotation) {
            self.annotation = annotation
            self.handleCorners = Self.corners(from: annotation.bounds)
        }

        mutating func updateHandles() {
            handleCorners = Self.corners(from: annotation.bounds)
        }

        static func corners(from bounds: CGRect) -> [CGPoint] {
            return [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
            ]
        }
    }

    func testHandlesMatchBoundsAfterFontSizeChange() {
        let annotation = TextAnnotation(
            text: "Hello", position: CGPoint(x: 100, y: 100), fontSize: 24
        )
        var model = SelectionHandleModel(annotation: annotation)

        let oldBounds = annotation.bounds
        let oldCorners = model.handleCorners

        // Change font size (simulates clicking a preset on a selected annotation)
        annotation.fontSize = 48
        model.updateHandles()

        let newBounds = annotation.bounds
        let newCorners = model.handleCorners

        // Bounds should have grown
        XCTAssertGreaterThan(newBounds.height, oldBounds.height,
                             "Doubling font size should increase bounds height")

        // Handles should match the new bounds, not the old ones
        let expectedCorners = SelectionHandleModel.corners(from: newBounds)
        for (i, corner) in newCorners.enumerated() {
            XCTAssertEqual(corner.x, expectedCorners[i].x, accuracy: 0.01,
                           "Handle \(i) X should match new bounds after font size change")
            XCTAssertEqual(corner.y, expectedCorners[i].y, accuracy: 0.01,
                           "Handle \(i) Y should match new bounds after font size change")
        }

        // Handles should NOT match the old bounds
        XCTAssertNotEqual(newCorners[3].y, oldCorners[3].y,
                          "Top-right handle Y should differ after font size increase")
    }

    /// Regression: changing font size without calling updateHandles leaves stale handles.
    func testStaleHandlesAfterFontSizeChangeWithoutUpdate() {
        let annotation = TextAnnotation(
            text: "Test", position: CGPoint(x: 50, y: 50), fontSize: 16
        )
        var model = SelectionHandleModel(annotation: annotation)

        let handlesBefore = model.handleCorners

        // Change font size but do NOT call updateHandles (the bug)
        annotation.fontSize = 72

        // Handles are stale — still reflect fontSize 16 bounds
        let expectedNew = SelectionHandleModel.corners(from: annotation.bounds)
        XCTAssertNotEqual(model.handleCorners[3].y, expectedNew[3].y,
                          "Without updateHandles, corners should be stale (this documents the bug)")

        // After update, they match
        model.updateHandles()
        XCTAssertEqual(model.handleCorners[3].x, expectedNew[3].x, accuracy: 0.01)
        XCTAssertEqual(model.handleCorners[3].y, expectedNew[3].y, accuracy: 0.01)
    }

    /// Verify that TextAnnotation.bounds changes when fontSize changes.
    func testTextAnnotationBoundsChangeWithFontSize() {
        let annotation = TextAnnotation(
            text: "Resize me", position: CGPoint(x: 0, y: 0), fontSize: 16
        )
        let smallBounds = annotation.bounds

        annotation.fontSize = 48
        let largeBounds = annotation.bounds

        XCTAssertGreaterThan(largeBounds.width, smallBounds.width,
                             "Larger font size should produce wider bounds")
        XCTAssertGreaterThan(largeBounds.height, smallBounds.height,
                             "Larger font size should produce taller bounds")
    }
}
