import AppKit

enum Selection {
    /// Reads the selected text of the focused app: Accessibility first, then a simulated ⌘C as fallback.
    @MainActor static func read() async -> String? {
        if let text = axSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return await copyFallback()
    }

    static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    /// Browsers and Electron apps often hide the selection from Accessibility, so copy it and restore the clipboard.
    @MainActor static func copyFallback() async -> String? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            item.types.forEach { if let d = item.data(forType: $0) { copy.setData(d, forType: $0) } }
            return copy
        } ?? []
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: down)  // "c"
            ev?.flags = .maskCommand
            ev?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Native crosshair region picker from macOS itself; returns PNG data.
    static func captureRegion() async -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proofmark-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        return await withCheckedContinuation { cont in
            p.terminationHandler = { _ in
                let data = try? Data(contentsOf: url)
                try? FileManager.default.removeItem(at: url)
                cont.resume(returning: data)
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }
}
