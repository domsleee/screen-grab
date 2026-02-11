import XCTest
@testable import ScreenGrab

// MARK: - Undo/Redo Model (mirrors SelectionView logic)

/// Testable model of the undo/redo system without requiring a full NSView.
/// Uses the real annotation types and SelectionView.AnnotationSnapshot.
private class UndoRedoModel {
    var annotations: [any Annotation] = []
    var selectedAnnotation: (any Annotation)?
    var undoStack: [[SelectionView.AnnotationSnapshot]] = []
    var redoStack: [[SelectionView.AnnotationSnapshot]] = []
    var textEditUndoAlreadyPushed = false

    func snapshotAnnotations() -> [SelectionView.AnnotationSnapshot] {
        annotations.map { annotation in
            if let arrow = annotation as? ArrowAnnotation {
                return .arrow(id: arrow.id, startPoint: arrow.startPoint, endPoint: arrow.endPoint,
                              color: arrow.color, strokeWidth: arrow.strokeWidth)
            } else if let rect = annotation as? RectangleAnnotation {
                return .rectangle(id: rect.id, bounds: rect.bounds, color: rect.color, strokeWidth: rect.strokeWidth)
            } else if let text = annotation as? TextAnnotation {
                return .text(id: text.id, text: text.text, position: text.position,
                             fontSize: text.fontSize, color: text.color, backgroundColor: text.backgroundColor,
                             backgroundPadding: text.backgroundPadding)
            }
            fatalError("Unknown annotation type")
        }
    }

    func restoreAnnotations(from snapshots: [SelectionView.AnnotationSnapshot]) {
        annotations = snapshots.map { snapshot in
            switch snapshot {
            case .arrow(let id, let startPoint, let endPoint, let color, let strokeWidth):
                return ArrowAnnotation(id: id, startPoint: startPoint, endPoint: endPoint,
                                       color: color, strokeWidth: strokeWidth)
            case .rectangle(let id, let bounds, let color, let strokeWidth):
                return RectangleAnnotation(id: id, bounds: bounds, color: color, strokeWidth: strokeWidth)
            case .text(let id, let text, let position, let fontSize, let color, let backgroundColor, let backgroundPadding):
                return TextAnnotation(id: id, text: text, position: position, fontSize: fontSize, color: color, backgroundColor: backgroundColor, backgroundPadding: backgroundPadding)
            }
        }

        if let selectedId = selectedAnnotation?.id {
            selectedAnnotation = annotations.first { $0.id == selectedId }
        } else {
            selectedAnnotation = nil
        }
    }

    func pushUndoState() {
        undoStack.append(snapshotAnnotations())
        redoStack.removeAll()
    }

    func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshotAnnotations())
        restoreAnnotations(from: previous)
    }

    func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshotAnnotations())
        restoreAnnotations(from: next)
    }

    // Simulate adding a rectangle annotation
    func addRectangle(bounds: CGRect, color: CGColor = NSColor.red.cgColor) {
        pushUndoState()
        let annotation = RectangleAnnotation(bounds: bounds, color: color)
        annotations.append(annotation)
    }

    // Simulate adding an arrow annotation
    func addArrow(start: CGPoint, end: CGPoint, color: CGColor = NSColor.red.cgColor) {
        pushUndoState()
        let annotation = ArrowAnnotation(startPoint: start, endPoint: end, color: color)
        annotations.append(annotation)
    }

    // Simulate adding a text annotation
    func addText(text: String, position: CGPoint, color: CGColor = NSColor.red.cgColor, backgroundColor: CGColor? = nil) {
        pushUndoState()
        let annotation = TextAnnotation(text: text, position: position, color: color, backgroundColor: backgroundColor)
        annotations.append(annotation)
    }

    // Simulate deleting the selected annotation
    func deleteSelected() {
        guard let selected = selectedAnnotation else { return }
        pushUndoState()
        annotations.removeAll { $0.id == selected.id }
        selectedAnnotation = nil
    }

    // Simulate moving an annotation
    func moveAnnotation(_ annotation: any Annotation, dx: CGFloat, dy: CGFloat) {
        pushUndoState()
        annotation.bounds = CGRect(
            x: annotation.bounds.origin.x + dx,
            y: annotation.bounds.origin.y + dy,
            width: annotation.bounds.width,
            height: annotation.bounds.height
        )
    }

    // Simulate changing color of selected annotation
    func changeColor(to color: CGColor) {
        guard let selected = selectedAnnotation else { return }
        pushUndoState()
        selected.color = color
    }
}

// MARK: - Tests

final class UndoRedoTests: XCTestCase {

    // MARK: - Basic Undo

    func testUndoCreation() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(model.annotations.count, 1)

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 0, "Undo should remove the created annotation")
    }

    func testUndoMultipleCreations() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        model.addArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
        model.addText(text: "Hello", position: CGPoint(x: 50, y: 50))
        XCTAssertEqual(model.annotations.count, 3)

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 2, "Undo should remove text")

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 1, "Undo should remove arrow")

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 0, "Undo should remove rectangle")
    }

    func testUndoOnEmptyStackDoesNothing() {
        let model = UndoRedoModel()
        model.performUndo() // should not crash
        XCTAssertEqual(model.annotations.count, 0)
    }

    // MARK: - Basic Redo

    func testRedoAfterUndo() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(model.annotations.count, 1)

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 0)

        model.performRedo()
        XCTAssertEqual(model.annotations.count, 1, "Redo should restore the annotation")
    }

    func testRedoOnEmptyStackDoesNothing() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        model.performRedo() // should not crash, no-op
        XCTAssertEqual(model.annotations.count, 1)
    }

    func testMultipleUndoRedo() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 10, y: 10, width: 50, height: 50))
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 50, height: 50))
        model.addRectangle(bounds: CGRect(x: 200, y: 200, width: 50, height: 50))
        XCTAssertEqual(model.annotations.count, 3)

        model.performUndo()
        model.performUndo()
        XCTAssertEqual(model.annotations.count, 1)

        model.performRedo()
        XCTAssertEqual(model.annotations.count, 2)

        model.performRedo()
        XCTAssertEqual(model.annotations.count, 3)
    }

    // MARK: - Redo Cleared on New Mutation

    func testNewMutationClearsRedoStack() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        model.addRectangle(bounds: CGRect(x: 200, y: 200, width: 100, height: 100))
        XCTAssertEqual(model.annotations.count, 2)

        model.performUndo() // back to 1 annotation
        XCTAssertEqual(model.redoStack.count, 1, "Redo stack should have one entry")

        // New mutation clears redo
        model.addArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 50, y: 50))
        XCTAssertEqual(model.redoStack.count, 0, "Redo stack should be cleared after new mutation")
        XCTAssertEqual(model.annotations.count, 2) // rect1 + arrow

        // Redo should do nothing now
        model.performRedo()
        XCTAssertEqual(model.annotations.count, 2, "Redo should be no-op after new mutation")
    }

    // MARK: - Delete Undo/Redo

    func testUndoDelete() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let annotationId = model.annotations[0].id

        model.selectedAnnotation = model.annotations[0]
        model.deleteSelected()
        XCTAssertEqual(model.annotations.count, 0)

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 1, "Undo should restore deleted annotation")
        XCTAssertEqual(model.annotations[0].id, annotationId, "Restored annotation should have same UUID")
    }

    func testRedoDelete() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))

        model.selectedAnnotation = model.annotations[0]
        model.deleteSelected()
        XCTAssertEqual(model.annotations.count, 0)

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 1)

        model.performRedo()
        XCTAssertEqual(model.annotations.count, 0, "Redo should re-delete the annotation")
    }

    // MARK: - Move Undo/Redo

    func testUndoMove() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let rect = model.annotations[0] as! RectangleAnnotation
        let originalBounds = rect.bounds

        model.moveAnnotation(rect, dx: 50, dy: 50)
        XCTAssertNotEqual(rect.bounds.origin, originalBounds.origin)

        model.performUndo()
        let restored = model.annotations[0] as! RectangleAnnotation
        XCTAssertEqual(restored.bounds.origin.x, originalBounds.origin.x, accuracy: 0.01,
                       "Undo should restore original position")
        XCTAssertEqual(restored.bounds.origin.y, originalBounds.origin.y, accuracy: 0.01)
    }

    // MARK: - Color Change Undo/Redo

    func testUndoColorChange() {
        let model = UndoRedoModel()
        let originalColor = NSColor.red.cgColor
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150), color: originalColor)
        model.selectedAnnotation = model.annotations[0]

        let newColor = NSColor.blue.cgColor
        model.changeColor(to: newColor)

        model.performUndo()
        let restored = model.annotations[0]
        // Compare color components since CGColor equality can be tricky
        XCTAssertEqual(restored.color.components, originalColor.components,
                       "Undo should restore original color")
    }

    // MARK: - UUID Preservation

    func testUUIDPreservedAcrossUndoRedo() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        let originalId = model.annotations[0].id

        model.performUndo()
        model.performRedo()

        XCTAssertEqual(model.annotations[0].id, originalId,
                       "Annotation UUID should be preserved across undo/redo")
    }

    func testUUIDPreservedForAllTypes() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 10, y: 10, width: 50, height: 50))
        model.addArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
        model.addText(text: "Test", position: CGPoint(x: 50, y: 50))

        let ids = model.annotations.map { $0.id }

        model.performUndo()
        model.performUndo()
        model.performUndo()
        model.performRedo()
        model.performRedo()
        model.performRedo()

        let restoredIds = model.annotations.map { $0.id }
        XCTAssertEqual(ids, restoredIds, "All annotation UUIDs should be preserved through undo/redo cycle")
    }

    // MARK: - Selection State After Undo/Redo

    func testSelectedAnnotationPreservedAfterUndo() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        model.addRectangle(bounds: CGRect(x: 300, y: 300, width: 100, height: 100))

        model.selectedAnnotation = model.annotations[0]
        let selectedId = model.selectedAnnotation!.id

        // Add a third annotation and undo it
        model.addRectangle(bounds: CGRect(x: 500, y: 500, width: 50, height: 50))
        model.performUndo()

        XCTAssertEqual(model.selectedAnnotation?.id, selectedId,
                       "Selected annotation should still be selected after undo if it still exists")
    }

    func testSelectedAnnotationClearedWhenUndoRemovesIt() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 200, height: 150))
        model.selectedAnnotation = model.annotations[0]

        model.performUndo() // removes the only annotation
        XCTAssertNil(model.selectedAnnotation,
                     "Selected annotation should be nil when undo removes it")
    }

    // MARK: - Snapshot Correctness

    func testArrowSnapshotPreservesAllProperties() {
        let model = UndoRedoModel()
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 300, y: 400)
        let color = NSColor.green.cgColor
        model.addArrow(start: start, end: end, color: color)

        model.performUndo()
        model.performRedo()

        let arrow = model.annotations[0] as! ArrowAnnotation
        XCTAssertEqual(arrow.startPoint, start)
        XCTAssertEqual(arrow.endPoint, end)
        XCTAssertEqual(arrow.color.components, color.components)
    }

    func testTextSnapshotPreservesAllProperties() {
        let model = UndoRedoModel()
        let position = CGPoint(x: 50, y: 75)
        model.addText(text: "Hello World", position: position)

        model.performUndo()
        model.performRedo()

        let text = model.annotations[0] as! TextAnnotation
        XCTAssertEqual(text.text, "Hello World")
        XCTAssertEqual(text.position, position)
        XCTAssertEqual(text.fontSize, 24) // default
    }

    func testRectangleSnapshotPreservesAllProperties() {
        let model = UndoRedoModel()
        let bounds = CGRect(x: 42, y: 99, width: 300, height: 200)
        let color = NSColor.purple.cgColor
        model.addRectangle(bounds: bounds, color: color)

        model.performUndo()
        model.performRedo()

        let rect = model.annotations[0] as! RectangleAnnotation
        XCTAssertEqual(rect.bounds, bounds)
        XCTAssertEqual(rect.color.components, color.components)
    }

    // MARK: - Text Background Color Undo/Redo

    func testTextBackgroundColorPreservedAcrossUndoRedo() {
        let model = UndoRedoModel()
        let bgColor = NSColor.yellow.withAlphaComponent(0.75).cgColor
        model.addText(text: "With BG", position: CGPoint(x: 50, y: 50), backgroundColor: bgColor)

        let text = model.annotations[0] as! TextAnnotation
        XCTAssertNotNil(text.backgroundColor, "Should have background color set")

        model.performUndo()
        XCTAssertEqual(model.annotations.count, 0)

        model.performRedo()
        XCTAssertEqual(model.annotations.count, 1)
        let restored = model.annotations[0] as! TextAnnotation
        XCTAssertNotNil(restored.backgroundColor, "Background color should be preserved after undo/redo")
        XCTAssertEqual(restored.backgroundColor?.components, bgColor.components,
                       "Background color components should match")
    }

    func testTextWithNilBackgroundColorPreserved() {
        let model = UndoRedoModel()
        model.addText(text: "No BG", position: CGPoint(x: 50, y: 50))

        model.performUndo()
        model.performRedo()

        let restored = model.annotations[0] as! TextAnnotation
        XCTAssertNil(restored.backgroundColor, "Nil background color should stay nil after undo/redo")
    }

    // MARK: - Text Edit Undo Flag

    func testTextEditUndoFlagPreventsDoublePush() {
        let model = UndoRedoModel()
        model.addText(text: "Original", position: CGPoint(x: 50, y: 50))
        let stackSizeAfterAdd = model.undoStack.count // 1

        // Simulate beginEditingTextAnnotation → pushes undo, sets flag
        model.pushUndoState()
        model.textEditUndoAlreadyPushed = true

        // Simulate commitTextAnnotation → should NOT push again because flag is set
        if !model.textEditUndoAlreadyPushed {
            model.pushUndoState()
        }
        model.textEditUndoAlreadyPushed = false

        XCTAssertEqual(model.undoStack.count, stackSizeAfterAdd + 1,
                       "Should only push once when editing existing text (beginEdit pushes, commit skips)")
    }

    func testNewTextAnnotationCommitPushesUndo() {
        let model = UndoRedoModel()
        // textEditUndoAlreadyPushed is false by default (new text, not editing existing)

        // Simulate commitTextAnnotation for new text
        if !model.textEditUndoAlreadyPushed {
            model.pushUndoState()
        }
        model.textEditUndoAlreadyPushed = false

        XCTAssertEqual(model.undoStack.count, 1,
                       "New text annotation commit should push undo state")
    }

    // MARK: - Stress / Edge Cases

    func testManyUndoRedoCycles() {
        let model = UndoRedoModel()

        // Create 20 annotations
        for i in 0..<20 {
            model.addRectangle(bounds: CGRect(x: CGFloat(i * 10), y: 0, width: 50, height: 50))
        }
        XCTAssertEqual(model.annotations.count, 20)

        // Undo all
        for _ in 0..<20 {
            model.performUndo()
        }
        XCTAssertEqual(model.annotations.count, 0)

        // Redo all
        for _ in 0..<20 {
            model.performRedo()
        }
        XCTAssertEqual(model.annotations.count, 20)
    }

    func testUndoBeyondStackDoesNothing() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 50, height: 50))

        model.performUndo() // back to 0
        model.performUndo() // no-op
        model.performUndo() // no-op

        XCTAssertEqual(model.annotations.count, 0)
        XCTAssertTrue(model.undoStack.isEmpty)
    }

    func testRedoBeyondStackDoesNothing() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 100, y: 100, width: 50, height: 50))
        model.performUndo()
        model.performRedo()
        model.performRedo() // no-op
        model.performRedo() // no-op

        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertTrue(model.redoStack.isEmpty)
    }

    func testMixedAnnotationTypesUndoRedo() {
        let model = UndoRedoModel()
        model.addRectangle(bounds: CGRect(x: 10, y: 10, width: 50, height: 50))
        model.addArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
        model.addText(text: "Hi", position: CGPoint(x: 20, y: 20))

        // Undo text
        model.performUndo()
        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertTrue(model.annotations[0] is RectangleAnnotation)
        XCTAssertTrue(model.annotations[1] is ArrowAnnotation)

        // Undo arrow
        model.performUndo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertTrue(model.annotations[0] is RectangleAnnotation)

        // Redo arrow
        model.performRedo()
        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertTrue(model.annotations[1] is ArrowAnnotation)

        // Redo text
        model.performRedo()
        XCTAssertEqual(model.annotations.count, 3)
        XCTAssertTrue(model.annotations[2] is TextAnnotation)
    }
}
