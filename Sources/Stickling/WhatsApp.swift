import AppKit

/// Sending a note via WhatsApp: opens the app (or WhatsApp Web if it isn't installed) with the message already written.
/// If a default number is set, the chat with that number opens directly.
@MainActor
enum WhatsApp {
    static func send(_ note: Note, settings: AppSettings) {
        let text = formatted(note.attributed)
        let phone = settings.whatsappNumber.filter(\.isNumber)
        var items = [URLQueryItem(name: "text", value: text)]
        if !phone.isEmpty { items.insert(URLQueryItem(name: "phone", value: phone), at: 0) }

        var app = URLComponents(string: "whatsapp://send")!
        app.queryItems = items
        if let url = app.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            var web = URLComponents(string: "https://web.whatsapp.com/send")!
            web.queryItems = items
            if let url = web.url { NSWorkspace.shared.open(url) }
        }

        if note.attributed.containsAttachments {
            // images can't travel through the link: they go to the clipboard, ready to paste into the chat
            copyImages(note.attributed)
        }
    }

    /// Converts formatting to WhatsApp syntax: *bold*, _italic_, ~strikethrough~.
    static func formatted(_ text: NSAttributedString) -> String {
        let fm = NSFontManager.shared
        var out = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if attrs[.attachment] != nil { return }
            let raw = (text.string as NSString).substring(with: range)
            var open = "", close = ""
            if let f = attrs[.font] as? NSFont {
                let t = fm.traits(of: f)
                if t.contains(.boldFontMask) { open += "*"; close = "*" + close }
                if t.contains(.italicFontMask) { open += "_"; close = "_" + close }
            }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { open += "~"; close = "~" + close }
            guard !open.isEmpty else { out += raw; return }
            // the markers must touch the text: apply them line by line, excluding spaces
            out += raw.components(separatedBy: "\n").map { line -> String in
                let core = line.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty, let r = line.range(of: core) else { return line }
                return line[..<r.lowerBound] + open + core + close + line[r.upperBound...]
            }.joined(separator: "\n")
        }
        // adjacent markers of neighboring runs ("*Hi* *there*" stays, "*Hi**there*" becomes "*Hithere*")
        for m in ["*", "_", "~"] { out = out.replacingOccurrences(of: m + m, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func copyImages(_ text: NSAttributedString) {
        var images: [NSImage] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            guard let att = v as? NSTextAttachment else { return }
            if let d = att.fileWrapper?.regularFileContents, let img = NSImage(data: d) { images.append(img) }
            else if let img = att.image { images.append(img) }
        }
        guard !images.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(images)
    }
}
