import AppKit

/// Sending a note by email.
///
/// Mail ignores RTFD text passed directly and opens .eml files as received messages,
/// so the note is converted to HTML and then to a "clean" NSAttributedString: the draft opens
/// editable and keeps bold, italic, colors, sizes and links. Images go as attachments.
@MainActor
enum Emailer {
    static func send(_ note: Note, settings: AppSettings) {
        guard let service = NSSharingService(named: .composeEmail) else {
            let a = NSAlert()
            a.messageText = L("No mail app configured")
            a.informativeText = L("Set up an account in Mail (or choose another default mail app) and try again.")
            a.runModal()
            return
        }
        let to = settings.emailRecipient
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init).filter { !$0.isEmpty }
        if !to.isEmpty { service.recipients = to }
        service.subject = note.title

        var items: [Any] = []
        if settings.emailFormatted, let body = formattedBody(note) {
            items.append(body)
        } else {
            items.append(note.plainText.replacingOccurrences(of: "\u{FFFC}", with: ""))
        }
        items.append(contentsOf: imageFiles(note.attributed))
        service.perform(withItems: items)
    }

    static func formattedBody(_ note: Note) -> NSAttributedString? {
        let (html, _) = html(for: note, card: false)
        return NSAttributedString(html: Data(html.utf8),
                                  options: [.documentType: NSAttributedString.DocumentType.html,
                                            .characterEncoding: String.Encoding.utf8.rawValue],
                                  documentAttributes: nil)
    }

    private static func imageFiles(_ text: NSAttributedString) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Foglietti-email-\(UUID().uuidString)")
        var urls: [URL] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            guard let att = v as? NSTextAttachment, let (data, mime) = imageData(att) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = mime == "image/jpeg" ? "jpg" : String(mime.split(separator: "/").last ?? "png")
            let url = dir.appendingPathComponent("image-\(urls.count + 1).\(ext)")
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    struct InlineImage { let cid: String; let mime: String; let data: Data }

    /// Converts the note's text to HTML with inline styles (Gmail-friendly too),
    /// inside a box with the note's colors and font.
    static func html(for note: Note, card: Bool = true) -> (String, [InlineImage]) {
        let text = note.attributed
        let s = note.style
        var body = ""
        var images: [InlineImage] = []
        let fm = NSFontManager.shared
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if let att = attrs[.attachment] as? NSTextAttachment {
                if card, let img = imageData(att) {
                    let cid = "img\(images.count + 1)@foglietti"
                    images.append(InlineImage(cid: cid, mime: img.1, data: img.0))
                    body += "<img src=\"cid:\(cid)\" style=\"max-width:100%;border-radius:4px;\">"
                }
                return
            }
            let raw = (text.string as NSString).substring(with: range)
            var css: [String] = []
            if let f = attrs[.font] as? NSFont {
                let traits = fm.traits(of: f)
                if traits.contains(.boldFontMask) { css.append("font-weight:bold") }
                if traits.contains(.italicFontMask) { css.append("font-style:italic") }
                if abs(f.pointSize - s.fontSize) > 0.5 { css.append("font-size:\(Int(f.pointSize))px") }
            }
            if let c = attrs[.foregroundColor] as? NSColor, RGBA(c) != s.text { css.append("color:\(hex(c))") }
            if let c = attrs[.backgroundColor] as? NSColor { css.append("background:\(hex(c))") }
            var deco: [String] = []
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { deco.append("underline") }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { deco.append("line-through") }
            if !deco.isEmpty { css.append("text-decoration:\(deco.joined(separator: " "))") }
            var chunk = escape(raw).replacingOccurrences(of: "\n", with: "<br>")
            if !css.isEmpty { chunk = "<span style=\"\(css.joined(separator: ";"))\">\(chunk)</span>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? "\(link)"
                chunk = "<a href=\"\(escape(href))\" style=\"color:\(hex(s.text.ns))\">\(chunk)</a>"
            }
            body += chunk
        }
        if !card {
            let family = s.fontName.isEmpty ? "Helvetica Neue,Helvetica,Arial,sans-serif" : "'\(s.fontName)',Helvetica,Arial,sans-serif"
            return ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:\(family);font-size:\(Int(s.fontSize))px;color:\(hex(s.text.isDark ? s.text.ns : .black))\">\(body)</body></html>", images)
        }
        let family = s.fontName.isEmpty ? "-apple-system,Helvetica,Arial,sans-serif" : "'\(s.fontName)',Helvetica,Arial,sans-serif"
        let card = """
        <div style="background:\(hex(s.background.ns));color:\(hex(s.text.ns));font-family:\(family);font-size:\(Int(s.fontSize))px;\
        line-height:1.45;padding:18px 20px;border-radius:\(Int(s.cornerRadius))px;max-width:560px;\
        box-shadow:0 2px 8px rgba(0,0,0,.15);">\(body)</div>
        """
        return ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(card)</body></html>", images)
    }

    private static func imageData(_ att: NSTextAttachment) -> (Data, String)? {
        if let w = att.fileWrapper, let d = w.regularFileContents {
            let ext = (w.preferredFilename as NSString?)?.pathExtension.lowercased() ?? ""
            if ["png", "gif"].contains(ext) { return (d, "image/\(ext)") }
            if ["jpg", "jpeg"].contains(ext) { return (d, "image/jpeg") }
            if let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) { return (png, "image/png") }
        }
        if let img = att.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        return nil
    }

    private static func hex(_ c: NSColor) -> String {
        let r = RGBA(c)
        func h(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return r.a < 0.99 ? "rgba(\(Int(r.r * 255)),\(Int(r.g * 255)),\(Int(r.b * 255)),\(String(format: "%.2f", r.a)))" : "#\(h(r.r))\(h(r.g))\(h(r.b))"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
