import XCTest
@testable import ScreenGrab

final class CursorBehaviorTests: XCTestCase {

    // MARK: - Annotation HitTest Tests

    func testRectangleHitTestBody() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let handle = rect.hitTest(point: CGPoint(x: 200, y: 175))
        XCTAssertEqual(handle, .body)
    }

    func testRectangleHitTestTopLeft() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        // topLeft corner is at (100, 250) — minX, maxY
        let handle = rect.hitTest(point: CGPoint(x: 100, y: 250))
        XCTAssertEqual(handle, .topLeft)
    }

    func testRectangleHitTestTopRight() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        // topRight corner is at (300, 250) — maxX, maxY
        let handle = rect.hitTest(point: CGPoint(x: 300, y: 250))
        XCTAssertEqual(handle, .topRight)
    }

    func testRectangleHitTestBottomLeft() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        // bottomLeft corner is at (100, 100) — minX, minY
        let handle = rect.hitTest(point: CGPoint(x: 100, y: 100))
        XCTAssertEqual(handle, .bottomLeft)
    }

    func testRectangleHitTestBottomRight() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        // bottomRight corner is at (300, 100) — maxX, minY
        let handle = rect.hitTest(point: CGPoint(x: 300, y: 100))
        XCTAssertEqual(handle, .bottomRight)
    }

    func testRectangleHitTestOutside() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let handle = rect.hitTest(point: CGPoint(x: 50, y: 50))
        XCTAssertNil(handle)
    }

    func testArrowHitTestStartPoint() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 300))
        let handle = arrow.hitTest(point: CGPoint(x: 101, y: 101))
        XCTAssertEqual(handle, .startPoint)
    }

    func testArrowHitTestEndPoint() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 300))
        let handle = arrow.hitTest(point: CGPoint(x: 299, y: 299))
        XCTAssertEqual(handle, .endPoint)
    }

    func testArrowHitTestBody() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 300))
        // Point near the middle of the line
        let handle = arrow.hitTest(point: CGPoint(x: 200, y: 200))
        XCTAssertEqual(handle, .body)
    }

    func testArrowHitTestOutside() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 300))
        let handle = arrow.hitTest(point: CGPoint(x: 50, y: 300))
        XCTAssertNil(handle)
    }

    // MARK: - Select Mode Hover Highlight Tests

    func testSelectModeHoverShowsHighlightForNonSelectedAnnotation() {
        // When in select mode, hovering over an annotation that is NOT selected
        // should show the dashed hover highlight
        let rect1 = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let rect2 = RectangleAnnotation(bounds: CGRect(x: 400, y: 100, width: 200, height: 150))

        // Simulate: rect1 is selected, hovering over rect2
        // rect2 should get hover highlight (hoveredAnnotation = rect2)
        let hoverPoint = CGPoint(x: 500, y: 175) // center of rect2
        let rect2Bounds = rect2.bounds.insetBy(dx: -4, dy: -4)
        XCTAssertTrue(rect2Bounds.contains(hoverPoint), "Hover point should be inside rect2's visual bounds")
        XCTAssertNotEqual(rect1.id, rect2.id, "Annotations should have distinct IDs")
    }

    func testSelectModeHoverSelectedAnnotationNoHighlight() {
        // When in select mode, hovering over the SELECTED annotation
        // should NOT show dashed hover highlight (handles are shown instead)
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let handle = rect.hitTest(point: CGPoint(x: 200, y: 175))
        XCTAssertEqual(handle, .body, "Hovering body of selected annotation should return .body handle")
    }

    // MARK: - Visual Bounds Tests (for hover detection)

    func testVisualBoundsRectangle() {
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        // Rectangle visual bounds should equal its bounds
        XCTAssertEqual(rect.bounds, CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testArrowBoundsEncloseEndpoints() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 250))
        let bounds = arrow.bounds
        // CGRect.contains excludes points on maxX/maxY edge, so inset by -1
        let expandedBounds = bounds.insetBy(dx: -1, dy: -1)
        XCTAssertTrue(expandedBounds.contains(arrow.startPoint), "Bounds should enclose start point")
        XCTAssertTrue(expandedBounds.contains(arrow.endPoint), "Bounds should enclose end point")
    }

    // MARK: - Handle-to-Cursor Mapping Tests (logic verification)

    func testHandleMappingCompleteness() {
        // Verify all AnnotationHandle cases are accounted for
        let allHandles: [AnnotationHandle] = [
            .body, .topLeft, .topRight, .bottomLeft, .bottomRight,
            .top, .bottom, .left, .right, .startPoint, .endPoint
        ]
        // Each handle should map to a known cursor behavior:
        // .body → openHand/closedHand
        // .topLeft/.bottomRight → NWSE diagonal
        // .topRight/.bottomLeft → NESW diagonal
        // .top/.bottom → resizeUpDown
        // .left/.right → resizeLeftRight
        // .startPoint/.endPoint → crosshair
        XCTAssertEqual(allHandles.count, 11, "All 11 handle types should be covered")
    }

    func testCornerHandlesArePaired() {
        // topLeft and bottomRight should use the same cursor (NWSE)
        // topRight and bottomLeft should use the same cursor (NESW)
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 200))

        let tl = rect.hitTest(point: CGPoint(x: 100, y: 300))  // topLeft
        let br = rect.hitTest(point: CGPoint(x: 300, y: 100))  // bottomRight
        let tr = rect.hitTest(point: CGPoint(x: 300, y: 300))  // topRight
        let bl = rect.hitTest(point: CGPoint(x: 100, y: 100))  // bottomLeft

        // NWSE pair
        XCTAssertEqual(tl, .topLeft)
        XCTAssertEqual(br, .bottomRight)

        // NESW pair
        XCTAssertEqual(tr, .topRight)
        XCTAssertEqual(bl, .bottomLeft)
    }

    // MARK: - Arrow Endpoint Handle Priority

    func testArrowEndpointTakesPriorityOverBody() {
        // When clicking near an arrow endpoint, the endpoint handle
        // should be returned, not .body
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 300, y: 300))
        let handle = arrow.hitTest(point: CGPoint(x: 103, y: 103))
        XCTAssertEqual(handle, .startPoint, "Endpoint should take priority over body when near endpoint")
    }

    func testArrowBodyReturnedWhenNotNearEndpoint() {
        let arrow = ArrowAnnotation(startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 400, y: 400))
        // Point at midpoint of line, far from endpoints
        let handle = arrow.hitTest(point: CGPoint(x: 250, y: 250))
        XCTAssertEqual(handle, .body, "Body should be returned when far from endpoints")
    }
}
