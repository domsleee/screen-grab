import XCTest
@testable import ScreenGrab

// MARK: - Text Editing Model (mirrors SelectionView text editing logic)

/// Testable model of the text editing state machine without requiring a full NSView.
private class TextEditingModel {
    var text: String = ""
    var isAllSelected: Bool = false
    var fontSize: CGFloat = 24
    let fontSizeRange: ClosedRange<CGFloat> = 10...120

    /// Simulate Cmd+A
    func selectAll() {
        if !text.isEmpty {
            isAllSelected = true
        }
    }

    /// Simulate typing a character
    func type(_ chars: String) {
        let filtered = chars.filter { char in
            if char.isNewline { return false }
            if let ascii = char.asciiValue { return ascii >= 32 }
            return true
        }
        guard !filtered.isEmpty else { return }

        if isAllSelected {
            text = filtered
            isAllSelected = false
        } else {
            text += filtered
        }
    }

    /// Simulate backspace
    func backspace() {
        if isAllSelected {
            text = ""
            isAllSelected = false
        } else if !text.isEmpty {
            text = String(text.dropLast())
        }
    }

    /// Simulate commit (ESC / Return)
    func commit() {
        isAllSelected = false
    }

    /// Simulate font size change with [ or ]
    func adjustFontSize(by delta: CGFloat) {
        fontSize = min(max(fontSize + delta, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

// MARK: - Tests

final class TextEditingTests: XCTestCase {

    // MARK: - Basic Typing

    func testTypingAppendsCharacters() {
        let model = TextEditingModel()
        model.type("H")
        model.type("i")
        XCTAssertEqual(model.text, "Hi")
    }

    func testBackspaceRemovesLastCharacter() {
        let model = TextEditingModel()
        model.type("Hello")
        model.backspace()
        XCTAssertEqual(model.text, "Hell")
    }

    func testBackspaceOnEmptyTextDoesNothing() {
        let model = TextEditingModel()
        model.backspace()
        XCTAssertEqual(model.text, "")
    }

    func testMultipleBackspacesToEmpty() {
        let model = TextEditingModel()
        model.type("AB")
        model.backspace()
        model.backspace()
        XCTAssertEqual(model.text, "")
    }

    func testNewlinesFiltered() {
        let model = TextEditingModel()
        model.type("A\nB")
        XCTAssertEqual(model.text, "AB")
    }

    func testControlCharsFiltered() {
        let model = TextEditingModel()
        model.type("A\u{01}B")
        XCTAssertEqual(model.text, "AB")
    }

    func testUnicodeAndEmojiAllowed() {
        let model = TextEditingModel()
        model.type("Hello 🌍")
        XCTAssertEqual(model.text, "Hello 🌍")
    }

    // MARK: - Select All (Cmd+A)

    func testSelectAllOnNonEmptyText() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        XCTAssertTrue(model.isAllSelected)
    }

    func testSelectAllOnEmptyTextDoesNothing() {
        let model = TextEditingModel()
        model.selectAll()
        XCTAssertFalse(model.isAllSelected, "Select all on empty text should not set selection")
    }

    func testTypingAfterSelectAllReplacesText() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.type("X")
        XCTAssertEqual(model.text, "X")
        XCTAssertFalse(model.isAllSelected, "Selection should be cleared after typing")
    }

    func testTypingMultipleCharsAfterSelectAllReplacesAll() {
        let model = TextEditingModel()
        model.type("Hello World")
        model.selectAll()
        model.type("New")
        XCTAssertEqual(model.text, "New")
    }

    func testBackspaceAfterSelectAllClearsAll() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.backspace()
        XCTAssertEqual(model.text, "")
        XCTAssertFalse(model.isAllSelected, "Selection should be cleared after backspace")
    }

    func testCommitClearsSelection() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.commit()
        XCTAssertFalse(model.isAllSelected)
        XCTAssertEqual(model.text, "Hello", "Commit should not modify text")
    }

    func testSelectAllThenTypePreservesNewText() {
        let model = TextEditingModel()
        model.type("Old text")
        model.selectAll()
        model.type("N")
        model.type("e")
        model.type("w")
        XCTAssertEqual(model.text, "New")
    }

    func testSelectAllThenSelectAllAgainIsIdempotent() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.selectAll()
        XCTAssertTrue(model.isAllSelected)
        model.type("X")
        XCTAssertEqual(model.text, "X")
    }

    func testSelectAllBackspaceAndRetype() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.backspace()
        XCTAssertEqual(model.text, "")
        model.type("World")
        XCTAssertEqual(model.text, "World")
    }

    // MARK: - Font Size

    func testFontSizeIncrease() {
        let model = TextEditingModel()
        model.adjustFontSize(by: 2)
        XCTAssertEqual(model.fontSize, 26)
    }

    func testFontSizeDecrease() {
        let model = TextEditingModel()
        model.adjustFontSize(by: -2)
        XCTAssertEqual(model.fontSize, 22)
    }

    func testFontSizeClampedAtMin() {
        let model = TextEditingModel()
        model.fontSize = 10
        model.adjustFontSize(by: -2)
        XCTAssertEqual(model.fontSize, 10, "Font size should not go below minimum")
    }

    func testFontSizeClampedAtMax() {
        let model = TextEditingModel()
        model.fontSize = 120
        model.adjustFontSize(by: 2)
        XCTAssertEqual(model.fontSize, 120, "Font size should not go above maximum")
    }

    func testFontSizeDoesNotAffectSelection() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.adjustFontSize(by: 2)
        XCTAssertTrue(model.isAllSelected, "Font size change should not clear selection")
        XCTAssertEqual(model.text, "Hello", "Font size change should not modify text")
    }

    // MARK: - Edge Cases

    func testSelectAllAfterBackspaceToSingleChar() {
        let model = TextEditingModel()
        model.type("AB")
        model.backspace()
        model.selectAll()
        model.type("Z")
        XCTAssertEqual(model.text, "Z")
    }

    func testSelectAllBackspaceThenSelectAllOnEmpty() {
        let model = TextEditingModel()
        model.type("Hello")
        model.selectAll()
        model.backspace()
        model.selectAll() // should be no-op on empty
        XCTAssertFalse(model.isAllSelected)
        XCTAssertEqual(model.text, "")
    }

    func testRapidSelectAllAndType() {
        let model = TextEditingModel()
        model.type("First")
        model.selectAll()
        model.type("Second")
        model.selectAll()
        model.type("Third")
        XCTAssertEqual(model.text, "Third")
    }
}
