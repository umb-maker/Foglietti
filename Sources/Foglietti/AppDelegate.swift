import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NoteStore.shared
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var listWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableLaunchAtLoginOnce()
        applySettings()
        store.onSettingsChange = { [weak self] in self?.applySettings() }
        HotKey.shared.action = { NotesManager.shared.newNote() }
        HotKey.shared.askAction = { AskController.shared.show() }
        NSApp.mainMenu = buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Foglietti")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if store.notes.isEmpty { createWelcomeNote() }
        NotesManager.shared.start()
        Reminders.shared.start()
        store.startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesManager.shared.flushAll()
        store.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showList() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// On first launch Foglietti adds itself to the login items, so it comes back after a restart.
    /// It can be turned off in Settings → General → "Open at login" (that choice is respected).
    private func enableLaunchAtLoginOnce() {
        let key = "launchAtLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        UserDefaults.standard.set(true, forKey: key)
    }

    private func applySettings() {
        NSApp.setActivationPolicy(store.settings.showInDock ? .regular : .accessory)
        HotKey.shared.apply(store.settings)
    }

    // MARK: Windows

    func showList() {
        if listWindow == nil {
            listWindow = makeWindow(title: L("Foglietti – Note list"), view: NotesListView(), size: NSSize(width: 560, height: 480), resizable: true)
        }
        present(listWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: L("Foglietti Settings"), view: SettingsView(), size: NSSize(width: 720, height: 560), resizable: false)
        }
        present(settingsWindow)
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize, resizable: Bool) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view.environmentObject(store))
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ key: String = "", symbol: String? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(i)
        }
        add(L("New note"), #selector(newNote), symbol: "plus")
        menu.addItem(.separator())
        add(L("Show all"), #selector(showAll), symbol: "eye")
        add(L("Hide all"), #selector(hideAll), symbol: "eye.slash")
        if store.notes.contains(where: { $0.floating && $0.isOpen }) {
            add(L("Unpin all"), #selector(unpinAll), symbol: "pin.slash")
        }
        add(L("Note list…"), #selector(openList), symbol: "list.bullet.rectangle")
        add(L("Ask Foglietti…"), #selector(showAsk), symbol: "sparkles")

        let recent = store.notes.filter(\.isActive).sorted { $0.modified > $1.modified }.prefix(10)
        if !recent.isEmpty {
            menu.addItem(.separator())
            for n in recent {
                let i = NSMenuItem(title: n.title, action: #selector(openNote(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = n.id
                i.state = n.isOpen ? .on : .off
                i.image = swatch(n.style.background.ns)
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        add(L("Settings…"), #selector(showSettings), ",")
        add(L("Quit Foglietti"), #selector(NSApplication.terminate(_:)), "q")
        menu.items.last?.target = NSApp
    }

    private func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke(); NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            return true
        }
    }

    @objc func newNote() { NotesManager.shared.newNote() }
    @objc func showAll() { NotesManager.shared.showAll() }
    @objc func hideAll() { NotesManager.shared.hideAll() }
    @objc func unpinAll() { NotesManager.shared.unpinAll() }
    @objc func openList() { showList() }
    @objc func showAsk() { AskController.shared.show() }
    @objc func openNote(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { NotesManager.shared.show(id, focus: true) }
    }

    // MARK: Main menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            top.submenu = m
            main.addItem(top)
        }
        func item(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            return i
        }
        let fm = NSFontManager.shared

        submenu("Foglietti", [
            item(L("About Foglietti"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            item(L("Settings…"), #selector(showSettings), ",", target: self),
            .separator(),
            item(L("Hide Foglietti"), #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item(L("Quit Foglietti"), #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        submenu(L("File"), [
            item(L("New note"), #selector(newNote), "n", target: self),
            item(L("Note list"), #selector(openList), "e", [.command, .shift], target: self),
            item(L("Show all"), #selector(showAll), target: self),
            item(L("Hide all"), #selector(hideAll), target: self),
            .separator(),
            item(L("Move note to Trash"), #selector(NoteWindowController.deleteNote)),
            item(L("Send note by email…"), #selector(NoteWindowController.sendEmail(_:)), "m", [.command, .shift]),
            item(L("Send note via WhatsApp"), #selector(NoteWindowController.sendWhatsApp(_:)), "w", [.command, .control]),
            item(L("Share note…"), #selector(NoteWindowController.shareNote(_:))),
            .separator(),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Paste with formatting"), #selector(NoteTextView.pasteWithFormatting(_:)), "v", [.command, .option]),
            item(L("Select all"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Find…"), #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
            item(L("Find next"), #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)),
            .separator(),
            item(L("Insert date"), #selector(NoteTextView.insertDate(_:)), "d", [.command, .shift]),
            item(L("Emoji…"), #selector(NoteWindowController.showEmoji(_:)), "e", [.command, .control]),
            item(L("Insert screenshot…"), #selector(NoteTextView.insertScreenshot(_:)), "i", [.command, .shift]),
            item(L("System emoji & symbols"), #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control], target: NSApp),
        ])
        submenu(L("Format"), [
            item(L("Bold"), #selector(NoteTextView.toggleBold(_:)), "b"),
            item(L("Italic"), #selector(NoteTextView.toggleItalic(_:)), "i"),
            item(L("Underline"), #selector(NoteTextView.toggleUnderline(_:)), "u"),
            item(L("Strikethrough"), #selector(NoteTextView.toggleStrikethrough(_:)), "x", [.command, .shift]),
            item(L("Highlight"), #selector(NoteTextView.highlightSelection(_:)), "h", [.command, .shift]),
            .separator(),
            item(L("Title"), #selector(NoteTextView.makeTitle(_:)), "1"),
            item(L("Subtitle"), #selector(NoteTextView.makeSubtitle(_:)), "2"),
            item(L("Body text"), #selector(NoteTextView.makeBody(_:)), "0"),
            item(L("Checkbox"), #selector(NoteTextView.insertCheckbox(_:)), "l", [.command, .shift]),
            .separator(),
            item(L("Bigger"), #selector(NSFontManager.modifyFont(_:)), "+", target: fm, tag: Int(NSFontAction.sizeUpFontAction.rawValue)),
            item(L("Smaller"), #selector(NSFontManager.modifyFont(_:)), "-", target: fm, tag: Int(NSFontAction.sizeDownFontAction.rawValue)),
            item(L("Show fonts"), #selector(NSFontManager.orderFrontFontPanel(_:)), "t", target: fm),
            item(L("Show colors"), #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift], target: NSApp),
            .separator(),
            item(L("Align left"), #selector(NSText.alignLeft(_:)), "{", [.command]),
            item(L("Center"), #selector(NSText.alignCenter(_:)), "|", [.command]),
            item(L("Align right"), #selector(NSText.alignRight(_:)), "}", [.command]),
        ])
        submenu("AI", [
            item(L("Ask Foglietti…  (⌃⌥Space)"), #selector(showAsk), target: self),
            .separator(),
            item(L("Note actions…"), #selector(NoteWindowController.showAIMenu(_:)), "j"),
            item(L("Custom instruction…"), #selector(NoteWindowController.runAIFreePrompt), "j", [.command, .shift]),
            item(L("Find reminder in text"), #selector(NoteWindowController.findReminderAI)),
            .separator(),
            item(L("Translate note"), #selector(NoteWindowController.translateDefault(_:)), "t", [.command, .option]),
            item(L("Translate to…"), #selector(NoteWindowController.showTranslateMenu(_:))),
        ])
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        let wTop = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        wTop.submenu = windowMenu
        main.addItem(wTop)
        NSApp.windowsMenu = windowMenu
        return main
    }

    // MARK: First note

    private func createWelcomeNote() {
        let text = L("Welcome to Foglietti\n\nEverything is customizable: click 🎨 at the top for colors, fonts, opacity, corners, borders and themes.\n☐ Double-click the bar to collapse the note\n☐ ⌃⌥N creates a note from any app\n☐ ⇧⌘L adds a checkbox, click it to tick it\n☑ ✨ and 🌐 summarize, rewrite and translate your notes")
        NotesManager.shared.newNote(styledText: { style in
            let a = NSMutableAttributedString(string: text, attributes: style.typingAttributes)
            let first = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            a.addAttribute(.font, value: NSFontManager.shared.convert(style.font(size: style.fontSize * 1.4), toHaveTrait: .boldFontMask), range: first)
            return a
        }, size: CGSize(width: 330, height: 250))
    }
}
