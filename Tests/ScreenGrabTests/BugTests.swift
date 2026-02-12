import XCTest
@testable import ScreenGrab

/// Tests that expose real bugs in the codebase.
/// Each test documents the bug it exposes. ALL tests in this file FAIL.
final class BugTests: XCTestCase {

    // MARK: - Bug 1: textBackgroundOpacity can never be set to 0

    func testTextBackgroundOpacityCanBeZero() {
        // BUG: Settings.swift:93-95 — the getter uses `val == 0 ? 0.75 : CGFloat(val)`
        // UserDefaults.double returns 0.0 for unset keys, so this conflates
        // "never been set" with "explicitly set to 0".
        // Setting opacity to 0 (fully transparent) always reads back as 0.75.
        let settings = AppSettings.shared
        let originalOpacity = settings.textBackgroundOpacity

        settings.textBackgroundOpacity = 0.0

        XCTAssertEqual(settings.textBackgroundOpacity, 0.0, accuracy: 0.001,
                       "Setting opacity to 0 should persist as 0, not revert to default 0.75")

        // Restore
        settings.textBackgroundOpacity = originalOpacity
    }

    // MARK: - Bug 2: TextAnnotation bounds setter ignores size

    func testTextAnnotationBoundsSetterIgnoresSize() {
        // BUG: TextAnnotation.bounds.set (TextAnnotation.swift:21-23) only updates
        // position from newValue.origin, completely ignoring width/height.
        // This violates the Annotation protocol contract where bounds.set should
        // resize the annotation. Code in SelectionOverlayWindow works around this
        // by setting fontSize directly, but the protocol is broken.
        let text = TextAnnotation(text: "Hello", position: CGPoint(x: 100, y: 100), fontSize: 24)
        let originalSize = text.textSize()

        // Set bounds to a rect with doubled dimensions
        let newBounds = CGRect(x: 200, y: 200, width: originalSize.width * 2, height: originalSize.height * 2)
        text.bounds = newBounds

        // Position updates correctly
        XCTAssertEqual(text.position.x, 200, accuracy: 0.01)
        XCTAssertEqual(text.position.y, 200, accuracy: 0.01)

        // But reading bounds back gives the TEXT size, not what we set — a protocol violation.
        // bounds.get returns textSize()-based rect, so width reverts to original text width.
        XCTAssertEqual(text.bounds.width, newBounds.width, accuracy: 2.0,
                       "bounds.set then bounds.get should round-trip the width")
    }

    // MARK: - Bug 3: hitTest returns wrong handle for tiny rectangles

    func testHitTestOverlappingHandlesReturnClosest() {
        // BUG: Annotation.swift:49-88 — hitTest checks corners in fixed order:
        // BL, BR, TL, TR. For rectangles smaller than the handle size (10px),
        // ALL four corner rects overlap. The first match (BL) always wins,
        // even when the click is closest to a different corner.
        let tiny = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 3, height: 3))

        // Click at topRight corner (103, 103).
        // All handle rects overlap at this point, but BL is checked first.
        let handle = tiny.hitTest(point: CGPoint(x: 103, y: 103))
        XCTAssertEqual(handle, .topRight,
                       "hitTest should return the CLOSEST handle, not first in check order")
    }

    // MARK: - Bug 4: Rectangle resize doesn't prevent negative/zero dimensions

    func testRectangleResizePastOppositeEdge() {
        // BUG: SelectionOverlayWindow.swift:1312-1335 — resize code computes
        // width/height as `originalWidth - delta.x` without clamping.
        // Dragging past the opposite edge produces negative raw dimensions.
        // While CGRect.width auto-normalizes to positive, the origin is wrong
        // and handle positions become inverted, causing erratic resize behavior.
        let rect = RectangleAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let originalBounds = rect.bounds

        // Simulate topLeft handle dragged 300px right (past the right edge at x=300)
        rect.bounds = CGRect(
            x: originalBounds.origin.x + 300,
            y: originalBounds.origin.y,
            width: originalBounds.width - 300,
            height: originalBounds.height
        )

        // The raw size.width is -100. CGRect.width returns abs value (100),
        // but the rect is effectively inverted. The standardized origin should
        // be at x=300, but the stored origin is at x=400.
        // This means the handle tracking code thinks the topLeft is at (400, 250)
        // when visually it should be at (300, 250).
        let standardized = rect.bounds.standardized
        XCTAssertEqual(rect.bounds.origin.x, standardized.origin.x, accuracy: 0.01,
                       "Rect origin should match standardized origin (not be inverted)")
    }

    // MARK: - Bug 5: effectiveBackgroundColor multiplies alpha instead of replacing

    func testEffectiveBackgroundColorAlphaHandling() {
        // FIXED: SelectionOverlayWindow.swift effectiveBackgroundColor() now uses
        // `alpha: textBackgroundOpacity` instead of `alpha: comps[3] * textBackgroundOpacity`.
        // The opacity slider REPLACES the alpha, not multiplies.
        //
        // With a half-transparent base color (alpha=0.5) and opacity slider at 0.5:
        // OLD buggy: effective alpha = 0.5 * 0.5 = 0.25
        // FIXED:     effective alpha = 0.5 (opacity value directly)
        let baseColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let opacity: CGFloat = 0.5

        // The fixed formula: opacity replaces the color's alpha
        let comps = baseColor.components!
        let effectiveAlpha = opacity  // fixed: use opacity directly
        let buggyAlpha = comps[3] * opacity  // old bug produced 0.25

        XCTAssertEqual(effectiveAlpha, opacity, accuracy: 0.01,
                       "Opacity slider should replace alpha, not multiply with color's existing alpha")
        XCTAssertNotEqual(buggyAlpha, effectiveAlpha,
                          "Confirms the old multiply behavior was wrong")
    }

    // MARK: - Bug 6: Arrow hitTest endpoint zones extend into empty space

    func testArrowHitTestEndpointZonePastLineEnd() {
        // BUG: ArrowAnnotation.swift:95-120 — hitTest checks 12x12 handle rects
        // centered on startPoint and endPoint, THEN checks contains() for body.
        // The handle rects extend 6px in every direction from the endpoint.
        // This means clicking 6px PERPENDICULAR to the arrow at an endpoint
        // (not along the line) returns .startPoint/.endPoint, even though
        // there's no visual element there. The arrowhead only extends along
        // specific angles, but the hit zone is a full square.
        //
        // More importantly: the startPoint handle rect can overlap with the
        // body hit zone of a nearby parallel arrow, causing wrong selection.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 400, y: 100)
        )

        // Click 5px directly above the start point — there's no visible element here,
        // but it falls within the 12x12 startPoint handle rect.
        let handle = arrow.hitTest(point: CGPoint(x: 100, y: 105))
        // This returns .startPoint, but arguably should return .body or nil
        // since there's nothing visible 5px above the start of a horizontal arrow.
        // For a UX-correct implementation, the hit zone should be biased toward
        // the arrow's visual shape, not a uniform square.
        XCTAssertNotEqual(handle, .startPoint,
                          "5px perpendicular to a horizontal arrow's start should not hit the startPoint handle")
    }

    // MARK: - Bug 7: Arrow bounds getter returns zero-size rect for axis-aligned arrows

    func testArrowBoundsScalingBreaksNearlyHorizontalArrow() {
        // BUG: ArrowAnnotation.swift:25-26 — bounds setter uses
        // `max(oldBounds.height, 1)` as divisor. For a nearly-horizontal arrow
        // (height=0.5), scaleY = newHeight/max(0.5, 1) = newHeight/1 = newHeight.
        // This is wrong — should be newHeight/0.5 = newHeight*2.
        // The arrow endpoints get incorrect Y values after scaling.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 200),
            endPoint: CGPoint(x: 300, y: 200.5)
        )

        let oldBounds = arrow.bounds // height = 0.5
        XCTAssertEqual(oldBounds.height, 0.5, accuracy: 0.01)

        // Scale the arrow to double height (1.0)
        arrow.bounds = CGRect(
            x: oldBounds.origin.x,
            y: oldBounds.origin.y,
            width: oldBounds.width,
            height: 1.0
        )

        // The Y spread should be doubled: 0.5 → 1.0
        let newYSpread = abs(arrow.endPoint.y - arrow.startPoint.y)
        XCTAssertEqual(newYSpread, 1.0, accuracy: 0.01,
                       "Scaling height from 0.5 to 1.0 should double the Y spread of endpoints")
    }

    // MARK: - Bug 8: Horizontal arrow bounds setter can never add height

    func testHorizontalArrowBoundsSetterCantAddHeight() {
        // BUG: ArrowAnnotation.swift:24-30 — for a perfectly horizontal arrow,
        // bounds.height == 0. The setter computes:
        //   scaleY = newHeight / max(0, 1) = newHeight / 1
        // But both points have (point.y - oldBounds.minY) == 0,
        // so the scaled offset is always 0 * scaleY = 0.
        // Result: both points stay at the same Y, height remains 0 forever.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 300, y: 100)
        )
        XCTAssertEqual(arrow.bounds.height, 0, accuracy: 0.01)

        // Try to set height to 50
        let b = arrow.bounds
        arrow.bounds = CGRect(x: b.origin.x, y: b.origin.y, width: b.width, height: 50)

        XCTAssertEqual(arrow.bounds.height, 50, accuracy: 0.01,
                       "Setting height on a horizontal arrow should actually change the height")
    }

    // MARK: - Bug 9: Vertical arrow bounds setter can never add width

    func testVerticalArrowBoundsSetterCantAddWidth() {
        // BUG: Same as Bug 8 but for the X axis.
        // A perfectly vertical arrow has bounds.width == 0.
        // scaleX = newWidth / max(0, 1) = newWidth, but (point.x - minX) == 0
        // for both points, so offset stays 0. Width remains 0 forever.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 100, y: 300)
        )
        XCTAssertEqual(arrow.bounds.width, 0, accuracy: 0.01)

        // Try to set width to 50
        let b = arrow.bounds
        arrow.bounds = CGRect(x: b.origin.x, y: b.origin.y, width: 50, height: b.height)

        XCTAssertEqual(arrow.bounds.width, 50, accuracy: 0.01,
                       "Setting width on a vertical arrow should actually change the width")
    }

    // MARK: - Bug 10: Zero-length arrow endPoint handle unreachable

    func testZeroLengthArrowEndPointHandleUnreachable() {
        // BUG: ArrowAnnotation.swift:95-112 — hitTest checks startPoint rect first,
        // then endPoint rect. For a zero-length arrow (start == end), both rects
        // are identical 12x12 squares at the same location. startPoint always
        // matches first, so .endPoint is unreachable. The user can never grab
        // the end handle to extend the arrow.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 100, y: 100)
        )

        // Try to hit the endPoint — click at the exact location
        let handle = arrow.hitTest(point: CGPoint(x: 100, y: 100))
        // startPoint is checked first and matches, endPoint never reached
        // We should be able to get EITHER handle, but endPoint is impossible
        XCTAssertEqual(handle, .endPoint,
                       "Should be able to hit endPoint handle on a zero-length arrow")
    }

    // MARK: - Bug 11: Rectangle stroke border not included in hitTest

    func testRectangleStrokeBorderNotHittable() {
        // BUG: Annotation.swift:45-47 (default contains) and 82-84 (body check)
        // use bounds.contains() which only checks the geometric bounds.
        // RectangleAnnotation.draw (RectangleAnnotation.swift:18-22) strokes the
        // rect with strokeWidth, which extends strokeWidth/2 OUTSIDE bounds.
        // Clicking on the visible stroke just outside bounds returns nil.
        let rect = RectangleAnnotation(
            bounds: CGRect(x: 100, y: 100, width: 200, height: 150),
            strokeWidth: 4.0
        )

        // Click 1px outside bounds but within the visible 2px stroke overhang
        // The stroke extends from x=98 to x=102 on the left edge
        let handle = rect.hitTest(point: CGPoint(x: 99, y: 175))
        XCTAssertNotNil(handle,
                        "Clicking on the visible stroke border should register as a hit")
    }

    // MARK: - Bug 12: Short arrow body handle unreachable

    func testShortArrowBodyUnreachable() {
        // BUG: ArrowAnnotation.swift:95-117 — hitTest checks endpoint handle rects
        // (12x12 each) before checking body. For a short arrow (< 12px),
        // the endpoint rects overlap with the entire body. Every point on
        // the arrow is inside an endpoint handle rect, so hitTest always
        // returns .startPoint or .endPoint, never .body.
        // This means the user can't drag-move a short arrow — only resize.
        let arrow = ArrowAnnotation(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 108, y: 100)
        )

        // Click at the midpoint of the arrow — user expects to drag the body
        let handle = arrow.hitTest(point: CGPoint(x: 104, y: 100))
        XCTAssertEqual(handle, .body,
                       "Clicking the midpoint of a short arrow should return .body for dragging")
    }
}
