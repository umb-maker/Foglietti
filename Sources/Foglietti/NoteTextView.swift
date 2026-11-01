import AppKit
import UniformTypeIdentifiers

/// Note editor: quick formatting, clickable checkboxes, lists that continue.
final class NoteTextView: NSTextView {
    static let unchecked = "☐"
    static let checked = "☑"
    private static let listPrefixes = ["☐ ", "☑ ", "- ", "• ", "* ", "→ "]

    private var noteStyle: NoteStyle { (window as? NoteWindow)?.noteController.flatMap { NoteStore.shared.note($0.noteID)?.style } ?? NoteStyle() }

    // MARK: Checkboxes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let r = checkboxRange(at: point) {
            toggleCheckbox(at: r)
            return
        }
        if event.clickCount == 2, let data = imageData(at: point) {
            openInPreview(data)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Images and screenshots

    /// Longest side, in pixels, of stored images: Retina screenshots stay sharp without bloating the notes.
    static let maxImagePixels: CGFloat = 1800

    func setupImageDrops() {
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL, .png, .tiff])
    }

    private func dragHasImage(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        if pb.canReadObject(forClasses: [NSURL.self], options: imageURLOptions) { return true }
        return pb.string(forType: .string) == nil && (pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil)
    }

    private var imageURLOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        return op.isEmpty && dragHasImage(sender.draggingPasteboard) ? .copy : op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        return op.isEmpty && dragHasImage(sender.draggingPasteboard) ? .copy : op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        // image files dragged from Finder or the Desktop
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: imageURLOptions) as? [URL], !urls.isEmpty {
            insertImages(urls.compactMap { try? Data(contentsOf: $0) }, at: index)
            return true
        }
        // the thumbnail shown after ⇧⌘4 / ⇧⌘5 delivers its file as a "promise"
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Foglietti-drop-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for p in promises {
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil, let data = try? Data(contentsOf: url) else { return }
                    MainActor.assumeIsolated { self?.insertImages([data], at: index) }
                }
            }
            return true
        }
        // a "bare" image (e.g. dragged from a browser)
        if pb.string(forType: .string) == nil, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            insertImages([data], at: index)
            return true
        }
        return super.performDragOperation(sender)
    }

    func insertImages(_ datas: [Data], at index: Int) {
        guard let ts = textStorage else { return }
        let out = NSMutableAttributedString()
        for d in datas {
            guard let png = Self.normalizedPNG(d) else { continue }
            let w = FileWrapper(regularFileWithContents: png)
            w.preferredFilename = "image-\(UUID().uuidString.prefix(8)).png"
            if out.length == 0, index > 0, (ts.string as NSString).character(at: min(index, ts.length) - 1) != 10 {
                out.append(NSAttributedString(string: "\n", attributes: typingAttributes))
            }
            out.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: w)))
            out.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        }
        guard out.length > 0 else { NSSound.beep(); return }
        let range = NSRange(location: min(max(0, index), ts.length), length: 0)
        if shouldChangeText(in: range, replacementString: out.string) {
            ts.replaceCharacters(in: range, with: out)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + out.length, length: 0))
        }
        fitImages()
    }

    static func normalizedPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 else { return nil }
        let longest = CGFloat(max(rep.pixelsWide, rep.pixelsHigh))
        guard longest > maxImagePixels else { return rep.representation(using: .png, properties: [:]) }
        let k = maxImagePixels / longest
        let w = Int(CGFloat(rep.pixelsWide) * k), h = Int(CGFloat(rep.pixelsHigh) * k)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        out.size = NSSize(width: rep.size.width * k, height: rep.size.height * k)   // keep the Retina density
        return out.representation(using: .png, properties: [:])
    }

    /// Resizes images (on screen only) so they never exceed the note's width.
    func fitImages() {
        guard let ts = textStorage, let tc = textContainer, ts.length > 0 else { return }
        let maxW = max(40, tc.size.width - tc.lineFragmentPadding * 2 - 4)
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length)) { v, range, _ in
            guard let att = v as? NSTextAttachment, let data = att.fileWrapper?.regularFileContents,
                  let rep = NSBitmapImageRep(data: data), rep.size.width > 0 else { return }
            var size = rep.size
            if size.width > maxW { size = NSSize(width: maxW, height: (size.height * maxW / size.width).rounded()) }
            if let cell = att.attachmentCell as? NSTextAttachmentCell, cell.image?.size == size { return }
            guard let img = NSImage(data: data) else { return }
            img.size = size
            att.attachmentCell = NSTextAttachmentCell(imageCell: img)
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    private func imageData(at point: NSPoint) -> Data? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: nil)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let ci = lm.characterIndexForGlyph(at: glyph)
        guard ci < ts.length, let att = ts.attribute(.attachment, at: ci, effectiveRange: nil) as? NSTextAttachment else { return nil }
        return att.fileWrapper?.regularFileContents
    }

    private func openInPreview(_ data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Foglietti-image-\(UUID().uuidString.prefix(8)).png")
        if (try? data.write(to: url)) != nil { NSWorkspace.shared.open(url) }
    }

    /// Interactive selection of an area of the screen, inserted into the note (like ⇧⌘4).
    @objc func insertScreenshot(_ sender: Any?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Foglietti-capture-\(UUID().uuidString.prefix(8)).png")
        let index = selectedRange().location
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, let data = try? Data(contentsOf: url) else { return }   // cancelled with Esc
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
                self.insertImages([data], at: index)
            }
        }
        try? p.run()
    }

    private func checkboxRange(at point: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: nil)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        let ci = lm.characterIndexForGlyph(at: glyph)
        guard ci < ts.length else { return nil }
        let r = (ts.string as NSString).rangeOfComposedCharacterSequence(at: ci)
        let ch = (ts.string as NSString).substring(with: r)
        return ch == Self.unchecked || ch == Self.checked ? r : nil
    }

    private func toggleCheckbox(at r: NSRange) {
        guard let ts = textStorage else { return }
        let ns = ts.string as NSString
        let nowChecked = ns.substring(with: r) == Self.unchecked
        let replacement = nowChecked ? Self.checked : Self.unchecked
        let line = ns.lineRange(for: r)
        guard shouldChangeText(in: line, replacementString: nil) else { return }
        ts.beginEditing()
        ts.replaceCharacters(in: r, with: replacement)
        let rest = NSRange(location: r.location + 1, length: max(0, line.upperBound - r.location - 1))
        let base = noteStyle.text.ns
        if nowChecked {
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
            ts.addAttribute(.foregroundColor, value: base.withAlphaComponent(0.45), range: rest)
        } else {
            ts.removeAttribute(.strikethroughStyle, range: rest)
            ts.addAttribute(.foregroundColor, value: base, range: rest)
        }
        ts.endEditing()
        didChangeText()
        if nowChecked { Sounds.ui(.tick) }
    }

    @objc func insertCheckbox(_ sender: Any?) {
        guard let ts = textStorage else { return }
        let line = (ts.string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let text = (ts.string as NSString).substring(with: line)
        if text.hasPrefix(Self.unchecked + " ") || text.hasPrefix(Self.checked + " ") {
            replace(NSRange(location: line.location, length: 2), with: "")
        } else {
            replace(NSRange(location: line.location, length: 0), with: Self.unchecked + " ")
        }
    }

    // MARK: Lists

    /// Return on a list line: continue with the same prefix; on an empty item, end the list.
    func continueList() -> Bool {
        guard let ts = textStorage else { return false }
        let ns = ts.string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
        var prefix: String?
        for p in Self.listPrefixes where content.hasPrefix(p) { prefix = p }
        if prefix == nil, let m = content.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            prefix = String(content[m])
        }
        guard let prefix else { return false }
        if content == prefix.trimmingCharacters(in: .whitespaces) || content == prefix {
            replace(NSRange(location: line.location, length: (content as NSString).length), with: "")
            return true
        }
        var next = prefix == Self.checked + " " ? Self.unchecked + " " : prefix
        if let n = Int(prefix.prefix { $0.isNumber }) {
            next = "\(n + 1)" + String(prefix.drop { $0.isNumber })
        }
        var attrs = noteStyle.typingAttributes
        attrs.removeValue(forKey: .strikethroughStyle)
        typingAttributes = attrs
        insertText("\n" + next, replacementRange: sel)
        return true
    }

    private func replace(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: noteStyle.typingAttributes))
        didChangeText()
    }

    // MARK: Formatting

    @objc func toggleBold(_ sender: Any?) { toggleTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggleTrait(.italicFontMask) }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let r = selectedRange()
        if r.length == 0 {
            var ta = typingAttributes
            let f = (ta[.font] as? NSFont) ?? noteStyle.baseFont
            ta[.font] = fm.traits(of: f).contains(trait) ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            typingAttributes = ta
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        let first = (ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? noteStyle.baseFont
        let remove = fm.traits(of: first).contains(trait)
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = (v as? NSFont) ?? first
            ts.addAttribute(.font, value: remove ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: sub)
        }
        ts.endEditing()
        didChangeText()
    }

    @objc func toggleStrikethrough(_ sender: Any?) { toggleLine(.strikethroughStyle) }
    @objc func toggleUnderline(_ sender: Any?) { toggleLine(.underlineStyle) }

    private func toggleLine(_ key: NSAttributedString.Key) {
        let r = selectedRange()
        if r.length == 0 {
            var ta = typingAttributes
            ta[key] = (ta[key] as? Int ?? 0) != 0 ? nil : NSUnderlineStyle.single.rawValue
            typingAttributes = ta
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        let on = (ts.attribute(key, at: r.location, effectiveRange: nil) as? Int ?? 0) != 0
        if on { ts.removeAttribute(key, range: r) } else { ts.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: r) }
        didChangeText()
    }

    @objc func makeTitle(_ sender: Any?) { setParagraphSize(1.6, bold: true) }
    @objc func makeSubtitle(_ sender: Any?) { setParagraphSize(1.25, bold: true) }
    @objc func makeBody(_ sender: Any?) { setParagraphSize(1, bold: false) }

    private func setParagraphSize(_ scale: Double, bold: Bool) {
        guard let ts = textStorage else { return }
        let r = (ts.string as NSString).paragraphRange(for: selectedRange())
        let s = noteStyle
        var f = s.font(size: s.fontSize * scale)
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        var ta = typingAttributes
        ta[.font] = f
        typingAttributes = ta
        guard r.length > 0, shouldChangeText(in: r, replacementString: nil) else { return }
        ts.addAttribute(.font, value: f, range: r)
        didChangeText()
    }

    @objc func highlightSelection(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0, let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        if ts.attribute(.backgroundColor, at: r.location, effectiveRange: nil) != nil {
            ts.removeAttribute(.backgroundColor, range: r)
        } else {
            let bg = noteStyle.background
            ts.addAttribute(.backgroundColor, value: (bg.isDark ? RGBA(hex: 0x8A6D00) : RGBA(hex: 0xFFF176)).ns.withAlphaComponent(0.8), range: r)
        }
        didChangeText()
    }

    @objc func insertDate(_ sender: Any?) {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        insertText(f.string(from: Date()), replacementRange: selectedRange())
    }

    /// Pasting always adapts the text to the note's style (⌥⌘V pastes keeping the original style).
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            insertImages([data], at: selectedRange().location)
        } else if pb.canReadObject(forClasses: [NSImage.self], options: nil), pb.string(forType: .string) == nil {
            super.paste(sender)
        } else {
            pasteAsPlainText(sender)
        }
    }
    @objc func pasteWithFormatting(_ sender: Any?) { super.paste(sender) }
}
