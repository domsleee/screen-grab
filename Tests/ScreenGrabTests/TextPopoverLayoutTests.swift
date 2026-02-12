import XCTest
@testable import ScreenGrab

/// Tests for text popover layout, ensuring all elements fit within bounds.
/// Mirrors the layout math from SelectionView.drawTextPopover() and
/// handleTextPopoverClick() without requiring a full NSView.
final class TextPopoverLayoutTests: XCTestCase {

    // Layout constants (must match SelectionView)
    private let textPopoverWidth: CGFloat = 260
    private let textPopoverPadding: CGFloat = 10
    private let opacityPresets: [CGFloat] = [0.25, 0.5, 0.75, 1.0]

    /// Compute the background row element rects, mirroring drawTextPopover().
    private func backgroundRowLayout(popoverOriginX: CGFloat = 0) -> (
        bgSwatchRect: NSRect,
        noFillRect: NSRect,
        opacityButtons: [NSRect]
    ) {
        let p = textPopoverPadding
        let bgRowHeight: CGFloat = 24

        let bgSwatchRect = NSRect(
            x: popoverOriginX + p + 70,
            y: 0, width: 20, height: 20
        )

        let noFillRect = NSRect(
            x: bgSwatchRect.maxX + 6,
            y: 0, width: 44, height: bgRowHeight
        )

        let opacityStartX = noFillRect.maxX + 4
        let opacityGap: CGFloat = 2
        let opacityBtnWidth = (popoverOriginX + textPopoverWidth - p - opacityStartX
                               - CGFloat(opacityPresets.count - 1) * opacityGap)
                              / CGFloat(opacityPresets.count)

        var buttons: [NSRect] = []
        for i in 0..<opacityPresets.count {
            let btnRect = NSRect(
                x: opacityStartX + CGFloat(i) * (opacityBtnWidth + opacityGap),
                y: 0, width: opacityBtnWidth, height: bgRowHeight
            )
            buttons.append(btnRect)
        }

        return (bgSwatchRect, noFillRect, buttons)
    }

    // MARK: - Tests

    func testOpacityButtonsFitWithinPopover() {
        let popoverOriginX: CGFloat = 100
        let popoverRect = NSRect(
            x: popoverOriginX, y: 0,
            width: textPopoverWidth, height: 220
        )
        let layout = backgroundRowLayout(popoverOriginX: popoverOriginX)

        for (i, btnRect) in layout.opacityButtons.enumerated() {
            let label = "\(Int(opacityPresets[i] * 100))"
            XCTAssertGreaterThanOrEqual(
                btnRect.minX, popoverRect.minX,
                "Opacity button '\(label)' left edge (\(btnRect.minX)) should be within popover left (\(popoverRect.minX))"
            )
            XCTAssertLessThanOrEqual(
                btnRect.maxX, popoverRect.maxX - textPopoverPadding,
                "Opacity button '\(label)' right edge (\(btnRect.maxX)) should be within popover content area (\(popoverRect.maxX - textPopoverPadding))"
            )
        }
    }

    func testOpacityButtonsHavePositiveWidth() {
        let layout = backgroundRowLayout()

        for (i, btnRect) in layout.opacityButtons.enumerated() {
            let label = "\(Int(opacityPresets[i] * 100))"
            XCTAssertGreaterThan(
                btnRect.width, 0,
                "Opacity button '\(label)' should have positive width"
            )
        }
    }

    func testOpacityButtonsDoNotOverlap() {
        let layout = backgroundRowLayout()

        for i in 1..<layout.opacityButtons.count {
            let prev = layout.opacityButtons[i - 1]
            let curr = layout.opacityButtons[i]
            XCTAssertGreaterThanOrEqual(
                curr.minX, prev.maxX,
                "Opacity button \(i) should not overlap button \(i - 1)"
            )
        }
    }

    func testLastOpacityButtonRightEdgeMatchesContentArea() {
        let popoverOriginX: CGFloat = 50
        let layout = backgroundRowLayout(popoverOriginX: popoverOriginX)
        let contentRightEdge = popoverOriginX + textPopoverWidth - textPopoverPadding

        guard let lastButton = layout.opacityButtons.last else {
            XCTFail("No opacity buttons")
            return
        }

        // The last button's right edge should align with the content area right edge
        XCTAssertEqual(
            lastButton.maxX, contentRightEdge, accuracy: 0.5,
            "Last opacity button should align with content area right edge"
        )
    }

    /// Regression test: with the old hardcoded width of 28, the "100" button
    /// overflowed the popover by 12px.
    func testHardcoded28WidthWouldOverflow() {
        let popoverOriginX: CGFloat = 0
        let p = textPopoverPadding

        let bgSwatchMaxX = popoverOriginX + p + 70 + 20
        let noFillMaxX = bgSwatchMaxX + 6 + 44
        let opacityStartX = noFillMaxX + 4
        let hardcodedWidth: CGFloat = 28
        let hardcodedGap: CGFloat = 2

        // Last button right edge with old hardcoded layout
        let lastBtnRightEdge = opacityStartX
            + CGFloat(opacityPresets.count) * hardcodedWidth
            + CGFloat(opacityPresets.count - 1) * hardcodedGap
        let contentRightEdge = popoverOriginX + textPopoverWidth - p

        XCTAssertGreaterThan(
            lastBtnRightEdge, contentRightEdge,
            "Confirms the old hardcoded 28px width caused overflow (regression guard)"
        )
    }
}
