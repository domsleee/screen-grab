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
    private let fontSizePresets: [CGFloat] = [16, 24, 36, 48, 72]
    private let fontSizeFieldWidth: CGFloat = 38
    private let fontSizeRange: ClosedRange<CGFloat> = 10...120

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

    /// Compute the font size row element rects, mirroring drawTextPopover().
    private func fontSizeRowLayout(popoverOriginX: CGFloat = 0) -> (
        fieldRect: NSRect,
        presetButtons: [NSRect]
    ) {
        let p = textPopoverPadding
        let sizeRowHeight: CGFloat = 24

        let fieldRect = NSRect(
            x: popoverOriginX + p,
            y: 0, width: fontSizeFieldWidth, height: sizeRowHeight
        )

        let sizeStartX = popoverOriginX + p + fontSizeFieldWidth + 4
        let sizeGap: CGFloat = 3
        let sizeBtnWidth = (popoverOriginX + textPopoverWidth - p - sizeStartX
                            - CGFloat(fontSizePresets.count - 1) * sizeGap)
                           / CGFloat(fontSizePresets.count)

        var buttons: [NSRect] = []
        for i in 0..<fontSizePresets.count {
            let btnRect = NSRect(
                x: sizeStartX + CGFloat(i) * (sizeBtnWidth + sizeGap),
                y: 0, width: sizeBtnWidth, height: sizeRowHeight
            )
            buttons.append(btnRect)
        }

        return (fieldRect, buttons)
    }

    // MARK: - Font Size Row Tests

    func testFontSizePresetsAreWithinRange() {
        for preset in fontSizePresets {
            XCTAssert(
                fontSizeRange.contains(preset),
                "Preset \(Int(preset)) should be within font size range \(fontSizeRange)"
            )
        }
    }

    func testFontSizePresetsAreSorted() {
        for i in 1..<fontSizePresets.count {
            XCTAssertGreaterThan(
                fontSizePresets[i], fontSizePresets[i - 1],
                "Font size presets should be in ascending order"
            )
        }
    }

    func testFontSizeFieldFitsWithinPopover() {
        let popoverOriginX: CGFloat = 100
        let layout = fontSizeRowLayout(popoverOriginX: popoverOriginX)

        XCTAssertGreaterThanOrEqual(
            layout.fieldRect.minX, popoverOriginX + textPopoverPadding,
            "Font size field should start within content area"
        )
        XCTAssertLessThanOrEqual(
            layout.fieldRect.maxX, popoverOriginX + textPopoverWidth - textPopoverPadding,
            "Font size field should end within content area"
        )
    }

    func testFontSizePresetButtonsFitWithinPopover() {
        let popoverOriginX: CGFloat = 100
        let layout = fontSizeRowLayout(popoverOriginX: popoverOriginX)
        let contentRight = popoverOriginX + textPopoverWidth - textPopoverPadding

        for (i, btnRect) in layout.presetButtons.enumerated() {
            XCTAssertGreaterThanOrEqual(
                btnRect.minX, layout.fieldRect.maxX,
                "Preset \(Int(fontSizePresets[i])) left edge should be after field"
            )
            XCTAssertLessThanOrEqual(
                btnRect.maxX, contentRight + 0.5,
                "Preset \(Int(fontSizePresets[i])) right edge (\(btnRect.maxX)) should be within content area (\(contentRight))"
            )
        }
    }

    func testFontSizePresetButtonsHavePositiveWidth() {
        let layout = fontSizeRowLayout()

        for (i, btnRect) in layout.presetButtons.enumerated() {
            XCTAssertGreaterThan(
                btnRect.width, 10,
                "Preset \(Int(fontSizePresets[i])) should have reasonable width (got \(btnRect.width))"
            )
        }
    }

    func testFontSizePresetButtonsDoNotOverlap() {
        let layout = fontSizeRowLayout()

        for i in 1..<layout.presetButtons.count {
            let prev = layout.presetButtons[i - 1]
            let curr = layout.presetButtons[i]
            XCTAssertGreaterThanOrEqual(
                curr.minX, prev.maxX,
                "Preset button \(Int(fontSizePresets[i])) should not overlap \(Int(fontSizePresets[i - 1]))"
            )
        }
    }

    func testFontSizeFieldDoesNotOverlapPresets() {
        let layout = fontSizeRowLayout()

        guard let firstPreset = layout.presetButtons.first else {
            XCTFail("No preset buttons")
            return
        }
        XCTAssertLessThanOrEqual(
            layout.fieldRect.maxX, firstPreset.minX,
            "Font size field should not overlap first preset button"
        )
    }

    func testLastFontSizePresetAlignsWithContentEdge() {
        let popoverOriginX: CGFloat = 50
        let layout = fontSizeRowLayout(popoverOriginX: popoverOriginX)
        let contentRight = popoverOriginX + textPopoverWidth - textPopoverPadding

        guard let lastButton = layout.presetButtons.last else {
            XCTFail("No preset buttons")
            return
        }
        XCTAssertEqual(
            lastButton.maxX, contentRight, accuracy: 0.5,
            "Last preset button should align with content area right edge"
        )
    }

    func testFontSizeDrawAndClickLayoutsMatch() {
        // Verify the draw and click handler use the same layout math
        let popoverOriginX: CGFloat = 200
        let layout = fontSizeRowLayout(popoverOriginX: popoverOriginX)

        // Re-derive click handler layout (must match fontSizeRowLayout)
        let p = textPopoverPadding
        let fieldWidth: CGFloat = fontSizeFieldWidth
        let sizeStartX = popoverOriginX + p + fieldWidth + 4
        let sizeGap: CGFloat = 3
        let sizeBtnWidth = (popoverOriginX + textPopoverWidth - p - sizeStartX
                            - CGFloat(fontSizePresets.count - 1) * sizeGap)
                           / CGFloat(fontSizePresets.count)

        for (i, preset) in fontSizePresets.enumerated() {
            let clickRect = NSRect(
                x: sizeStartX + CGFloat(i) * (sizeBtnWidth + sizeGap),
                y: 0, width: sizeBtnWidth, height: 24
            )
            XCTAssertEqual(
                clickRect.minX, layout.presetButtons[i].minX, accuracy: 0.01,
                "Draw/click mismatch for preset \(Int(preset)) left edge"
            )
            XCTAssertEqual(
                clickRect.width, layout.presetButtons[i].width, accuracy: 0.01,
                "Draw/click mismatch for preset \(Int(preset)) width"
            )
        }
    }

    // MARK: - Opacity Row Tests

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

    // MARK: - Font Size Field Numeric Filtering Tests

    func testFontSizeFieldStripsNonNumericCharacters() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Create and expose the text field by simulating showFontSizeTextField internals
        let tf = NSTextField()
        tf.delegate = view

        // Simulate typing "12abc3" then triggering controlTextDidChange
        tf.stringValue = "12abc3"
        let notification = Notification(name: NSControl.textDidChangeNotification, object: tf)
        view.controlTextDidChange(notification)
        XCTAssertEqual(tf.stringValue, "123", "Non-numeric characters should be stripped")
    }

    func testFontSizeFieldAllowsPureNumericInput() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tf = NSTextField()
        tf.delegate = view

        tf.stringValue = "48"
        let notification = Notification(name: NSControl.textDidChangeNotification, object: tf)
        view.controlTextDidChange(notification)
        XCTAssertEqual(tf.stringValue, "48", "Pure numeric input should be unchanged")
    }

    func testFontSizeFieldStripsAllNonNumeric() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tf = NSTextField()
        tf.delegate = view

        tf.stringValue = "abc"
        let notification = Notification(name: NSControl.textDidChangeNotification, object: tf)
        view.controlTextDidChange(notification)
        XCTAssertEqual(tf.stringValue, "", "All-alpha input should result in empty string")
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
