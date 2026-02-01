import AppKit

class ClipboardManager {
    static func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        pasteboard.clearContents()
        let success = pasteboard.writeObjects([image])

        let changeCountAfter = pasteboard.changeCount

        if success && changeCountAfter > changeCountBefore {
            logDebug("Clipboard: success, changeCount \(changeCountBefore) -> \(changeCountAfter), " +
                     "image size: \(image.size)")
        } else {
            logError("Clipboard: FAILED! success=\(success), changeCount \(changeCountBefore) -> \(changeCountAfter)")
        }
    }
}
