import AppKit
import SwiftUI

// MARK: - Borderless window

final class NoteWindow: NSWindow {
    weak var noteController: NoteWindowController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { noteController?.closeNote() }
    override func sendEvent(_ event: NSEvent) {
        // touching a ringing note silences it
        if [.leftMouseDown, .keyDown].contains(event.type), let id = noteController?.noteID { Reminders.shared.stopRinging(id) }
        super.sendEvent(event)
    }
}

// MARK: - Container: background, border, corners

final class NoteContainerView: NSView {
    let header = NoteHeaderView()
    let scroll = NSScrollView()
    let grip = ResizeGripView()
    var style = NoteStyle() { didSet { applyStyle() } }
    var hovering = false { didSet { updateButtons() } }
    /// Buttons that stay visible without the mouse (pin when pinned, bell when a reminder is set),
    /// so the note's state is clear at a glance.
    var stickyButtons: [NSButton] = [] { didSet { updateButtons() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(scroll)
        addSubview(header)
        addSubview(grip)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func resizeSubviews(withOldSize oldSize: NSSize) { relayout() }

    func relayout() {
        let h = CGFloat(style.headerHeight)
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
        grip.frame = NSRect(x: bounds.width - 14, y: 0, width: 14, height: 14)
        header.layoutButtons()
    }

    private func applyStyle() {
        // on glass the background comes from the material (with its tint): here it stays transparent
        let bg = style.material.isTranslucent ? NSColor.clear : style.background.ns.withAlphaComponent(style.background.a * style.opacity)
        layer?.backgroundColor = bg.cgColor
        layer?.cornerRadius = style.cornerRadius
        layer?.borderWidth = style.borderWidth
        layer?.borderColor = style.border.ns.cgColor
        let headerAlpha = style.material.isTranslucent ? (style.useCustomHeader ? style.header.a * 0.5 : 0.0) : style.headerColor.a * style.opacity
        header.layer?.backgroundColor = style.headerColor.ns.withAlphaComponent(headerAlpha).cgColor
        header.tint = style.text.ns
        grip.tint = style.text.ns
        relayout()
        updateButtons()
    }

    private func updateButtons() {
        let visible = !style.buttonsOnHover || hovering
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            header.buttons.forEach { b in b.animator().alphaValue = visible || stickyButtons.contains(where: { $0 === b }) ? 1 : 0 }
            grip.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Top bar (dragging + buttons)

final class NoteHeaderView: NSView {
    var onDoubleClick: (() -> Void)?
    var leading: [NSButton] = []
    var trailing: [NSButton] = []
    var buttons: [NSButton] { leading + trailing }
    var tint: NSColor = .black { didSet { buttons.forEach { $0.contentTintColor = tint.withAlphaComponent(0.7) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func addButton(_ symbol: String, tip: String, trailing isTrailing: Bool, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.imageScaling = .scaleProportionallyDown
        b.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        addSubview(b)
        if isTrailing { trailing.append(b) } else { leading.append(b) }
        return b
    }

    func layoutButtons() {
        let s = min(bounds.height, 22), y = (bounds.height - s) / 2
        for (i, b) in leading.enumerated() { b.frame = NSRect(x: 4 + CGFloat(i) * (s + 2), y: y, width: s, height: s) }
        for (i, b) in trailing.reversed().enumerated() {
            b.frame = NSRect(x: bounds.width - 4 - CGFloat(i + 1) * (s + 2), y: y, width: s, height: s)
        }
        let hide = bounds.height < 12
        buttons.forEach { $0.isHidden = hide }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }
}

// MARK: - Resize grip

final class ResizeGripView: NSView {
    var tint: NSColor = .black { didSet { needsDisplay = true } }
    private var start: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.35).setStroke()
        for i in 0..<3 {
            let p = NSBezierPath()
            let o = CGFloat(4 + i * 3)
            p.move(to: NSPoint(x: bounds.width - o, y: 2))
            p.line(to: NSPoint(x: bounds.width - 2, y: o))
            p.lineWidth = 1
            p.stroke()
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = NSEvent.mouseLocation
        let width = max(w.minSize.width, startFrame.width + p.x - start.x)
        let height = max(w.minSize.height, startFrame.height - (p.y - start.y))
        w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
    }
}

// MARK: - Controller of one note

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let noteID: UUID
    let container = NoteContainerView()
    let textView = NoteTextView(usingTextLayoutManager: false)
    private var applied: Note?
    /// Glass view wrapping the container when the material is not "solid".
    private var materialHost: NSView?
    private var saveTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var paletteButton: NSButton!
    private var emojiButton: NSButton!
    private var aiButton: NSButton!
    private var translateButton: NSButton!
    private var aiPanel: AIPanel?
    private var aiRange = NSRange(location: 0, length: 0)
    private var pinButton: NSButton!
    private var bellButton: NSButton!
    private var store: NoteStore { NoteStore.shared }

    init(note: Note) {
        noteID = note.id
        let win = NoteWindow(contentRect: note.frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 140, height: 60)
        win.contentView = container
        super.init(window: win)
        win.noteController = self
        win.delegate = self
        buildViews()
        textView.textStorage?.setAttributedString(note.attributed)
        apply(note)
        textView.fitImages()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildViews() {
        let h = container.header
        _ = h.addButton("plus", tip: L("New note"), trailing: false, target: self, action: #selector(newNote))
        emojiButton = h.addButton("face.smiling", tip: L("Emoji (⌃⌘E)"), trailing: false, target: self, action: #selector(showEmoji(_:)))
        aiButton = h.addButton("sparkles", tip: "Apple Intelligence", trailing: false, target: self, action: #selector(showAIMenu(_:)))
        translateButton = h.addButton("globe", tip: L("Translate (⌥⌘T)"), trailing: false, target: self, action: #selector(showTranslateMenu(_:)))
        _ = h.addButton("xmark", tip: L("Close (stays in the list)"), trailing: true, target: self, action: #selector(closeNote))
        _ = h.addButton("ellipsis.circle", tip: L("More"), trailing: true, target: self, action: #selector(showMore(_:)))
        bellButton = h.addButton("bell", tip: L("Reminder"), trailing: true, target: self, action: #selector(showReminderMenu(_:)))
        pinButton = h.addButton("pin", tip: L("Always on top of other apps"), trailing: true, target: self, action: #selector(togglePin))
        paletteButton = h.addButton("paintpalette", tip: L("Customize"), trailing: true, target: self, action: #selector(showStyle))
        h.onDoubleClick = { [weak self] in self?.toggleCollapse() }

        let tv = textView
        tv.frame = container.scroll.contentView.bounds
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFontPanel = true
        tv.usesFindBar = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = self
        container.scroll.documentView = tv
        tv.setupImageDrops()
    }

    // MARK: Applying state

    func apply(_ note: Note) {
        let old = applied
        applied = note
        guard let win = window else { return }
        let s = note.style

        // content changed elsewhere (e.g. sync from another Mac): reload the text
        var reloaded = false
        if let old, old.content != note.content, let ts = textView.textStorage {
            let sel = textView.selectedRange()
            ts.setAttributedString(note.attributed)
            textView.fitImages()
            textView.setSelectedRange(NSRange(location: min(sel.location, ts.length), length: 0))
            reloaded = true
        }

        if old?.style != s {
            applyMaterial(s)
            container.style = s
            win.hasShadow = s.shadow
            textView.textContainerInset = NSSize(width: s.padding, height: s.padding * 0.6)
            textView.insertionPointColor = s.text.ns
            textView.selectedTextAttributes = [.backgroundColor: s.text.ns.withAlphaComponent(0.18)]
            textView.linkTextAttributes = [.foregroundColor: s.text.ns, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
            if !reloaded, let o = old?.style, !o.sameText(as: s), let ts = textView.textStorage {
                TextStyler.restyle(ts, from: o, to: s)
            }
            textView.typingAttributes = s.typingAttributes
            win.invalidateShadow()
        }
        if old?.floating != note.floating {
            win.level = note.floating ? .floating : .normal
            pinButton.image = NSImage(systemSymbolName: note.floating ? "pin.fill" : "pin", accessibilityDescription: nil)
            pinButton.toolTip = note.floating ? L("Pinned on top: click to let other apps cover it") : L("Always on top of other apps")
        }
        if old?.reminder != note.reminder {
            bellButton.image = NSImage(systemSymbolName: note.reminder == nil ? "bell" : "bell.fill", accessibilityDescription: nil)
            bellButton.toolTip = note.reminder.map { L("Reminder: ") + Reminders.label($0) } ?? L("Set a reminder")
        }
        container.stickyButtons = (note.floating ? [pinButton] : []) + (note.reminder != nil ? [bellButton] : [])
        if old?.allSpaces != note.allSpaces {
            win.collectionBehavior = note.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
        if old != nil, old?.collapsed != note.collapsed { setCollapsed(note.collapsed, frame: note.frame) }
        else if old == nil, note.collapsed { setCollapsed(true, frame: note.frame) }
    }

    private func applyMaterial(_ s: NoteStyle) {
        guard let win = window else { return }
        var material = s.material
        if material == .glass || material == .clearGlass {
            if #available(macOS 26.0, *) {
                let g = (materialHost as? NSGlassEffectView) ?? NSGlassEffectView()
                g.style = material == .clearGlass ? .clear : .regular
                g.cornerRadius = s.cornerRadius
                g.tintColor = s.glassTint > 0.01 ? s.background.ns.withAlphaComponent(s.glassTint) : nil
                host(container, in: g, window: win, isGlass: true)
                materialHost = g
                return
            }
            material = .blur   // older systems: fall back to blurred glass
        }
        if material == .blur {
            let v = (materialHost as? NSVisualEffectView) ?? NSVisualEffectView()
            v.material = s.background.isDark ? .hudWindow : .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = s.cornerRadius
            v.layer?.masksToBounds = true
            v.layer?.backgroundColor = s.background.ns.withAlphaComponent(s.glassTint * 0.6).cgColor
            host(container, in: v, window: win, isGlass: false)
            materialHost = v
            return
        }
        if win.contentView !== container {
            let frame = win.frame
            container.removeFromSuperview()
            win.contentView = container
            win.setFrame(frame, display: true)
        }
        materialHost = nil
    }

    private func host(_ content: NSView, in hostView: NSView, window win: NSWindow, isGlass: Bool) {
        let frame = win.frame
        if win.contentView !== hostView {
            content.removeFromSuperview()
            win.contentView = hostView
        }
        if #available(macOS 26.0, *), isGlass, let g = hostView as? NSGlassEffectView {
            if g.contentView !== content { g.contentView = content }
            if #available(macOS 27.0, *) { g.effectIsInteractive = false }
        } else if content.superview !== hostView {
            hostView.addSubview(content)
        }
        content.frame = hostView.bounds
        content.autoresizingMask = [.width, .height]
        win.setFrame(frame, display: true)
    }

    private func setCollapsed(_ collapsed: Bool, frame: CGRect) {
        guard let win = window else { return }
        let top = win.frame.maxY
        let h = collapsed ? CGFloat(applied?.style.headerHeight ?? 24) : frame.height
        win.minSize = NSSize(width: 140, height: collapsed ? h : 60)
        win.setFrame(NSRect(x: win.frame.minX, y: top - h, width: win.frame.width, height: h), display: true, animate: true)
        container.scroll.isHidden = collapsed
    }

    func show(focus: Bool) {
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
        } else {
            window?.orderFront(nil)
        }
    }

    // MARK: Saving text

    func textDidChange(_ notification: Notification) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let ts = textView.textStorage else { return }
        let copy = NSAttributedString(attributedString: ts)
        store.update(noteID) { n in
            guard n.plainText != copy.string || n.attributed != copy else { return }
            n.setText(copy)
            n.modified = Date()
        }
        applied = store.note(noteID) ?? applied
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), store.settings.continueLists {
            return (textView as? NoteTextView)?.continueList() ?? false
        }
        return false
    }

    // MARK: Window

    func windowDidMove(_ notification: Notification) { storeFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { storeFrame() }
    func windowDidResize(_ notification: Notification) {
        textView.fitImages()
        if window?.inLiveResize == false { storeFrame() }
    }

    private func storeFrame() {
        guard let win = window else { return }
        let collapsed = applied?.collapsed ?? false
        store.update(noteID) { n in
            if collapsed {
                // while collapsed keep the expanded height, with the top edge where it is now
                n.frame = CGRect(x: win.frame.minX, y: win.frame.maxY - n.frame.height, width: win.frame.width, height: n.frame.height)
            } else {
                n.frame = win.frame
            }
        }
        applied = store.note(noteID) ?? applied
    }

    func windowDidBecomeKey(_ notification: Notification) { NotesManager.shared.lastActive = self }
    func windowDidResignKey(_ notification: Notification) { flush() }

    // MARK: Actions

    @objc func newNote() { NotesManager.shared.newNote(near: self) }

    @objc func closeNote() {
        flush()
        store.update(noteID) { $0.isOpen = false }
    }

    @objc func togglePin() { store.update(noteID) { $0.floating.toggle() } }

    @objc func toggleCollapse() { store.update(noteID) { $0.collapsed.toggle() } }

    @objc func showStyle() {
        if let p = popover, p.isShown { p.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: NoteStyleEditor(noteID: noteID).environmentObject(store))
        p.show(relativeTo: paletteButton.bounds, of: paletteButton, preferredEdge: .maxY)
        popover = p
    }

    @objc func showEmoji(_ sender: Any?) {
        if let p = popover, p.isShown { p.close(); if p.contentViewController is NSHostingController<EmojiPickerHost> { return } }
        if applied?.collapsed == true { toggleCollapse() }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: EmojiPickerHost(store: store) { [weak self] e in self?.insertEmoji(e) })
        p.show(relativeTo: emojiButton.bounds, of: emojiButton, preferredEdge: .maxY)
        popover = p
    }

    /// Inserts the emoji at the cursor (at the end if the note wasn't being edited).
    func insertEmoji(_ e: String) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        textView.insertText(e, replacementRange: textView.selectedRange())
    }

    // MARK: Apple Intelligence

    @objc func showAIMenu(_ sender: Any?) {
        let m = NSMenu()
        if let problem = AIAvailability.problem {
            let i = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        } else {
            for (idx, a) in store.settings.aiActions.enumerated() {
                let i = NSMenuItem(title: a.name, action: #selector(runAIAction(_:)), keyEquivalent: "")
                i.target = self
                i.tag = idx
                i.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
                m.addItem(i)
            }
            m.addItem(.separator())
            let free = NSMenuItem(title: L("Custom instruction…"), action: #selector(runAIFreePrompt), keyEquivalent: "")
            free.target = self
            free.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            m.addItem(free)
            let rem = NSMenuItem(title: L("Find reminder in text"), action: #selector(findReminderAI), keyEquivalent: "")
            rem.target = self
            rem.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
            m.addItem(rem)
        }
        m.addItem(.separator())
        let ask = NSMenuItem(title: L("Ask Foglietti…"), action: #selector(AppDelegate.showAsk), keyEquivalent: "")
        ask.target = NSApp.delegate
        m.addItem(ask)
        let anchor = aiButton!
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc func runAIAction(_ sender: NSMenuItem) {
        let actions = store.settings.aiActions
        if actions.indices.contains(sender.tag) { startAI(actions[sender.tag]) }
    }

    @objc func runAIFreePrompt() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L("e.g. Rewrite as a message to my boss")
        let a = NSAlert()
        a.messageText = L("What should I do with the note's text?")
        a.informativeText = L("If you selected part of the text, I'll work on that only.")
        a.accessoryView = field
        a.addButton(withTitle: L("Run"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        startAI(AIAction(name: field.stringValue, prompt: field.stringValue))
    }

    func startAI(_ action: AIAction) {
        guard #available(macOS 26.0, *) else { return }
        if let problem = AIAvailability.problem { NSAlert.simple(problem); return }
        flush()
        guard let ts = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: ts.length)
        let source = (ts.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        aiRange = range
        aiPanel?.close()

        let run = AIRun(title: action.name, onSelection: sel.length > 0)
        let view = AIResultView(run: run,
                                replace: { [weak self] in self?.applyAI(run.text, replace: true) },
                                append: { [weak self] in self?.applyAI(run.text, replace: false) },
                                newNote: { [weak self] in
                                    NotesManager.shared.newNote(text: run.text, near: self)
                                    self?.aiPanel?.close() },
                                close: { [weak self] in self?.aiPanel?.close() })
        let p = AIPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Apple Intelligence"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        if let f = window?.frame {
            let screen = window?.screen?.visibleFrame ?? .zero
            let x = f.maxX + 12 + 480 < screen.maxX ? f.maxX + 12 : max(screen.minX, f.minX - 492)
            p.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            Task { @MainActor in run.task?.cancel() }
        }
        p.makeKeyAndOrderFront(nil)
        aiPanel = p

        run.task = Task { @MainActor in
            do {
                for try await partial in AIEngine.run(action, on: source) { run.text = partial }
            } catch is CancellationError {
            } catch {
                run.error = AIAvailability.message(for: error)
            }
            run.text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            run.running = false
            if run.error == nil { Sounds.ui(.done) }
        }
    }

    private func applyAI(_ text: String, replace: Bool) {
        guard let ts = textView.textStorage, let s = applied?.style else { return }
        let attr = NSAttributedString(string: text, attributes: s.typingAttributes)
        let range = replace ? NSIntersectionRange(aiRange, NSRange(location: 0, length: ts.length))
                            : NSRange(location: ts.length, length: 0)
        let insert = NSMutableAttributedString()
        if !replace && ts.length > 0 { insert.append(NSAttributedString(string: "\n\n", attributes: s.typingAttributes)) }
        insert.append(attr)
        // go through the text-editing machinery so ⌘Z undoes the AI's change
        if textView.shouldChangeText(in: range, replacementString: insert.string) {
            ts.replaceCharacters(in: range, with: insert)
            textView.didChangeText()
        }
        aiPanel?.close()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Translation

    @objc func showTranslateMenu(_ sender: Any?) {
        let m = NSMenu()
        guard #available(macOS 15.0, *) else {
            let i = NSMenuItem(title: L("Translation requires macOS 15 or later"), action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: translateButton.bounds.height), in: translateButton)
            return
        }
        let preferred = store.settings.translateLanguages
        func add(_ code: String, to menu: NSMenu) {
            let i = NSMenuItem(title: "\(Translator.flag(code))  \(Translator.name(code))", action: #selector(translateTo(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = code
            menu.addItem(i)
        }
        let head = NSMenuItem(title: textView.selectedRange().length > 0 ? L("Translate selection to…") : L("Translate note to…"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        preferred.forEach { add($0, to: m) }
        let others = NSMenu()
        Translator.languages.filter { !preferred.contains($0) }.forEach { add($0, to: others) }
        let more = NSMenuItem(title: L("More languages"), action: nil, keyEquivalent: "")
        more.submenu = others
        m.addItem(.separator())
        m.addItem(more)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: translateButton.bounds.height), in: translateButton)
    }

    @objc func translateTo(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { startTranslation(to: code) }
    }

    /// ⌥⌘T: translate right away into the first preferred language that differs from the text's.
    @objc func translateDefault(_ sender: Any?) {
        let text = textView.selectedRange().length > 0 ? (textView.string as NSString).substring(with: textView.selectedRange()) : textView.string
        startTranslation(to: Translator.defaultTarget(for: text, preferred: store.settings.translateLanguages))
    }

    func startTranslation(to target: String) {
        guard #available(macOS 15.0, *) else { NSAlert.simple(L("Translation requires macOS 15 or later.")); return }
        flush()
        guard let ts = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: ts.length)
        let source = (ts.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        aiRange = range
        aiPanel?.close()

        let run = TranslateRun(source: source, target: target, onSelection: sel.length > 0)
        let view = TranslateView(run: run,
                                 replace: { [weak self] in self?.applyAI(run.text, replace: true) },
                                 append: { [weak self] in self?.applyAI(run.text, replace: false) },
                                 newNote: { [weak self] in
                                     NotesManager.shared.newNote(text: run.text, near: self)
                                     self?.aiPanel?.close() },
                                 close: { [weak self] in self?.aiPanel?.close() })
        let p = AIPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = L("Translate")
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        if let f = window?.frame {
            let screen = window?.screen?.visibleFrame ?? .zero
            let x = f.maxX + 12 + 500 < screen.maxX ? f.maxX + 12 : max(screen.minX, f.minX - 512)
            p.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
        }
        p.makeKeyAndOrderFront(nil)
        aiPanel = p
    }

    @objc func findReminderAI() {
        guard #available(macOS 26.0, *) else { return }
        if let problem = AIAvailability.problem { NSAlert.simple(problem); return }
        flush()
        let text = textView.string
        let id = noteID
        Task { @MainActor in
            do {
                guard let found = try await AIEngine.extractReminder(from: text) else {
                    NSAlert.simple(L("I found no future dates or times in this note."), info: L("You can always set one by hand with the 🔔 bell."))
                    return
                }
                let a = NSAlert()
                a.messageText = L("Set the reminder?")
                a.informativeText = "\(found.what.isEmpty ? L("This note") : "«\(found.what)»")\n\(Reminders.label(found.date))"
                a.addButton(withTitle: L("Set"))
                a.addButton(withTitle: L("Choose another date…"))
                a.addButton(withTitle: L("Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                switch a.runModal() {
                case .alertFirstButtonReturn: Reminders.shared.set(id, at: found.date)
                case .alertSecondButtonReturn: if let d = Reminders.askDate(initial: found.date) { Reminders.shared.set(id, at: d) }
                default: break
                }
            } catch {
                NSAlert.simple(AIAvailability.message(for: error))
            }
        }
    }

    @objc func showMore(_ sender: NSButton) {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector, _ symbol: String) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            m.addItem(i)
        }
        item(L("Duplicate"), #selector(duplicate), "plus.square.on.square")
        item((applied?.collapsed ?? false) ? L("Expand") : L("Collapse to bar"), #selector(toggleCollapse), "rectangle.compress.vertical")
        item((applied?.allSpaces ?? false) ? L("This desktop only") : L("On all desktops"), #selector(toggleSpaces), "rectangle.3.group")
        let rem = NSMenuItem(title: L("Reminder"), action: nil, keyEquivalent: "")
        rem.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        rem.submenu = reminderMenu()
        m.addItem(rem)
        item(L("Send by email…"), #selector(sendEmail(_:)), "envelope")
        item(L("Send via WhatsApp"), #selector(sendWhatsApp(_:)), "message")
        item(L("Share…"), #selector(shareNote(_:)), "square.and.arrow.up")
        item(L("Export as text…"), #selector(exportText), "doc.text")
        m.addItem(.separator())
        item(L("Archive note"), #selector(archive), "archivebox")
        item(L("Move to Trash"), #selector(deleteNote), "trash")
        m.addItem(.separator())
        item(L("Note list"), #selector(openList), "list.bullet.rectangle")
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc func duplicate() {
        flush()
        guard var n = store.note(noteID) else { return }
        n.id = UUID(); n.created = Date(); n.modified = Date(); n.isOpen = true
        n.frame = n.frame.offsetBy(dx: 24, dy: -24)
        store.notes.append(n)
        NotesManager.shared.show(n.id, focus: true)
    }

    @objc func toggleSpaces() { store.update(noteID) { $0.allSpaces.toggle() } }

    @objc func archive() {
        flush()
        store.update(noteID) { $0.archived = true; $0.isOpen = false }
    }

    @objc func deleteNote() {
        flush()
        NotesManager.shared.moveToTrash([noteID])
    }

    // MARK: Reminders

    @objc func showReminderMenu(_ sender: NSButton) {
        reminderMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private func reminderMenu() -> NSMenu {
        let m = NSMenu()
        if let r = applied?.reminder {
            let i = NSMenuItem(title: L("Set for: ") + Reminders.label(r), action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.addItem(.separator())
        }
        for (title, date) in Reminders.presets() {
            let i = NSMenuItem(title: title, action: #selector(setReminderPreset(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = date
            m.addItem(i)
        }
        let custom = NSMenuItem(title: L("Date and time…"), action: #selector(setReminderCustom), keyEquivalent: "")
        custom.target = self
        m.addItem(custom)
        if applied?.reminder != nil {
            m.addItem(.separator())
            let rm = NSMenuItem(title: L("Remove reminder"), action: #selector(removeReminder), keyEquivalent: "")
            rm.target = self
            m.addItem(rm)
        }
        m.addItem(.separator())
        let important = NSMenuItem(title: L("Important (repeats, ignores quiet hours)"), action: #selector(toggleImportant), keyEquivalent: "")
        important.target = self
        important.state = applied?.importantReminder == true ? .on : .off
        m.addItem(important)
        let soundItem = NSMenuItem(title: L("Sound"), action: nil, keyEquivalent: "")
        soundItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        soundItem.submenu = soundMenu()
        m.addItem(soundItem)
        return m
    }

    /// Per-note sound: the default one, none, a system sound or a file. Choosing one plays a preview.
    private func soundMenu() -> NSMenu {
        let m = NSMenu()
        let current = applied?.sound
        func add(_ title: String, _ value: String?) {
            let i = NSMenuItem(title: title, action: #selector(chooseNoteSound(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = value
            i.state = current == value ? .on : .off
            m.addItem(i)
        }
        add(L("Default (%@)", Sounds.displayName(store.settings.reminderSound)), nil)
        add(L("None"), "")
        m.addItem(.separator())
        Sounds.available.forEach { add($0, $0) }
        if let c = current, c.hasPrefix("/") { add(Sounds.displayName(c), c) }
        m.addItem(.separator())
        let file = NSMenuItem(title: L("Choose a file…"), action: #selector(chooseNoteSoundFile), keyEquivalent: "")
        file.target = self
        m.addItem(file)
        return m
    }

    @objc func chooseNoteSound(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String
        Reminders.shared.setSound(noteID, value)
        Sounds.play(value ?? store.settings.reminderSound, volume: store.settings.soundVolume)
    }

    @objc func chooseNoteSoundFile() {
        guard let path = Sounds.chooseFile() else { return }
        Reminders.shared.setSound(noteID, path)
        Sounds.play(path, volume: store.settings.soundVolume)
    }

    @objc func toggleImportant() { store.update(noteID) { $0.importantReminder.toggle() } }

    @objc func setReminderPreset(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? Date { Reminders.shared.set(noteID, at: d) }
    }

    @objc func setReminderCustom() {
        if let d = Reminders.askDate(initial: applied?.reminder) { Reminders.shared.set(noteID, at: d) }
    }

    @objc func removeReminder() { Reminders.shared.set(noteID, at: nil) }

    @objc func exportText() {
        flush()
        guard let n = store.note(noteID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = n.title.replacingOccurrences(of: "/", with: "-") + ".rtfd"
        panel.allowedContentTypes = [.rtfd, .rtf, .plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let a = n.attributed
        let range = NSRange(location: 0, length: a.length)
        switch url.pathExtension.lowercased() {
        case "txt", "md":
            try? n.plainText.write(to: url, atomically: true, encoding: .utf8)
        case "rtf":
            try? a.rtf(from: range, documentAttributes: [:])?.write(to: url)
        default:
            try? a.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                .write(to: url, options: .atomic, originalContentsURL: nil)
        }
    }

    @objc func sendEmail(_ sender: Any?) {
        flush()
        if let n = store.note(noteID) { Emailer.send(n, settings: store.settings) }
    }

    @objc func sendWhatsApp(_ sender: Any?) {
        flush()
        if let n = store.note(noteID) { WhatsApp.send(n, settings: store.settings) }
    }

    @objc func shareNote(_ sender: Any?) {
        flush()
        guard let n = store.note(noteID) else { return }
        let picker = NSSharingServicePicker(items: [n.attributed])
        let anchor = container.header.trailing.first { $0.action == #selector(showMore(_:)) } ?? paletteButton!
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func openList() { (NSApp.delegate as? AppDelegate)?.showList() }
}

extension NSAlert {
    static func simple(_ message: String, info: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
