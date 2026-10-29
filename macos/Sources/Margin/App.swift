import AppKit
import Carbon.HIToolbox

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    var statusItem: NSStatusItem!
    let panel = CheckPanel()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Margin")
        let menu = NSMenu()
        menu.addItem(withTitle: "Check selection   ⌥Space", action: #selector(checkSelection), keyEquivalent: "")
        menu.addItem(withTitle: "Check screen region   ⌥⇧Space", action: #selector(checkRegion), keyEquivalent: "")
        menu.addItem(withTitle: "Research selection   ⌃⌥Space", action: #selector(researchSelection), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Margin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        statusItem.menu = menu

        // Prompts for Accessibility once; needed to read the selection in other apps
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        Hotkeys.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.checkSelection() }
        Hotkeys.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.checkRegion() }
        Hotkeys.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey)) { [weak self] in self?.researchSelection() }
    }

    /// Opening the app again (Finder, Spotlight) shows the history.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showHistory()
        return false
    }

    @objc func checkSelection() { fromSelection(.check) }
    @objc func researchSelection() { fromSelection(.research) }

    @objc func showHistory() {
        HistoryWindow.show { [weak self] text in
            self?.panel.show(Check(mode: .research, text: text, image: nil, app: "History"))
        }
    }

    func fromSelection(_ mode: Mode) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // Each rebuild changes the app's signature, which silently invalidates the old Accessibility grant
        guard AXIsProcessTrusted() else {
            panel.show(Check(error: "Margin needs Accessibility access to read your selection. In the window that just opened, "
                             + "remove Margin with −, add it back with +, then reopen Margin.", app: app))
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        Task { @MainActor in
            guard let text = await Selection.read(), !text.isEmpty else {
                panel.show(Check(error: "Select some text first, then press ⌥Space.", app: app))
                return
            }
            panel.show(Check(mode: mode, text: String(text.prefix(mode == .research ? 1500 : 2000)), image: nil, app: app))
        }
    }

    @objc func checkRegion() {
        Task { @MainActor in
            guard let png = await Selection.captureRegion() else { return }
            panel.show(Check(mode: .check, text: "", image: png, app: "Screen"))
        }
    }
}

/// Global hotkeys through Carbon: no dependency, works without the app being focused.
enum Hotkeys {
    static var handlers: [UInt32: () -> Void] = [:]
    static var installed = false

    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { Hotkeys.handlers[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4D52474E), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
