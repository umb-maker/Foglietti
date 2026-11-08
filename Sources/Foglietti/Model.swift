import AppKit
import SwiftUI

// MARK: - Serializable color

struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, a: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 1)
        r = Double(c.redComponent); g = Double(c.greenComponent)
        b = Double(c.blueComponent); a = Double(c.alphaComponent)
    }

    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var swiftUI: Color { Color(nsColor: ns) }

    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    var isDark: Bool { luminance < 0.5 }

    func darker(_ k: Double) -> RGBA { RGBA(r: r * (1 - k), g: g * (1 - k), b: b * (1 - k), a: a) }
    func lighter(_ k: Double) -> RGBA { RGBA(r: r + (1 - r) * k, g: g + (1 - g) * k, b: b + (1 - b) * k, a: a) }

    /// Text color that is readable on this background.
    var readableText: RGBA { isDark ? RGBA(hex: 0xF2F2F2) : RGBA(hex: 0x2B2B2B) }
}

extension KeyedDecodingContainer {
    /// Decodes with a default value, so saved files stay compatible when fields are added.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Note style

/// Surface of the note.
enum NoteMaterial: String, Codable, CaseIterable, Identifiable {
    case solid          // solid color
    case glass          // system Liquid Glass (macOS 26+)
    case clearGlass     // clear Liquid Glass
    case blur           // classic blurred glass (also works on macOS 14–15)
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: L("Solid")
        case .glass: "Liquid Glass"
        case .clearGlass: L("Clear glass")
        case .blur: L("Blurred")
        }
    }
    var isTranslucent: Bool { self != .solid }
}

struct NoteStyle: Codable, Hashable {
    var background = RGBA(hex: 0xFFE680)
    var text = RGBA(hex: 0x2B2B2B)
    var useCustomHeader = false
    var header = RGBA(hex: 0xF5D660)
    var fontName = ""               // "" = system font
    var fontSize: Double = 14
    var opacity: Double = 1
    var cornerRadius: Double = 8
    var padding: Double = 12
    var lineSpacing: Double = 2
    var borderWidth: Double = 0
    var border = RGBA(hex: 0x000000, a: 0.18)
    var shadow = true
    var headerHeight: Double = 24
    var buttonsOnHover = true
    var material = NoteMaterial.solid
    var glassTint: Double = 0.25     // how strongly the background color tints the glass

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = NoteStyle()
        s.background = c.v(.background, s.background)
        s.text = c.v(.text, s.text)
        s.useCustomHeader = c.v(.useCustomHeader, s.useCustomHeader)
        s.header = c.v(.header, s.header)
        s.fontName = c.v(.fontName, s.fontName)
        s.fontSize = c.v(.fontSize, s.fontSize)
        s.opacity = c.v(.opacity, s.opacity)
        s.cornerRadius = c.v(.cornerRadius, s.cornerRadius)
        s.padding = c.v(.padding, s.padding)
        s.lineSpacing = c.v(.lineSpacing, s.lineSpacing)
        s.borderWidth = c.v(.borderWidth, s.borderWidth)
        s.border = c.v(.border, s.border)
        s.shadow = c.v(.shadow, s.shadow)
        s.headerHeight = c.v(.headerHeight, s.headerHeight)
        s.buttonsOnHover = c.v(.buttonsOnHover, s.buttonsOnHover)
        s.material = c.v(.material, s.material)
        s.glassTint = c.v(.glassTint, s.glassTint)
        self = s
    }

    var headerColor: RGBA { useCustomHeader ? header : (background.isDark ? background.lighter(0.08) : background.darker(0.06)) }

    var baseFont: NSFont { font(size: fontSize) }

    func font(size: Double) -> NSFont {
        if !fontName.isEmpty, let f = NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// Moves an existing font into this style's family, keeping bold/italic.
    func convertFamily(_ f: NSFont) -> NSFont {
        let fm = NSFontManager.shared
        let traits = fm.traits(of: f).intersection([.boldFontMask, .italicFontMask])
        var out = font(size: f.pointSize)
        if traits.contains(.boldFontMask) { out = fm.convert(out, toHaveTrait: .boldFontMask) }
        if traits.contains(.italicFontMask) { out = fm.convert(out, toHaveTrait: .italicFontMask) }
        return out
    }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        return p
    }

    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: text.ns, .paragraphStyle: paragraphStyle]
    }

    func sameText(as o: NoteStyle) -> Bool {
        fontName == o.fontName && fontSize == o.fontSize && text == o.text && lineSpacing == o.lineSpacing
    }
}

// MARK: - Note

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var content = Data()            // RTFD (formatted text + images)
    var plainText = ""              // plain copy for title and search
    var style = NoteStyle()
    var frame = CGRect(x: 240, y: 240, width: 260, height: 240)
    var created = Date()
    var modified = Date()
    var isOpen = true
    var floating = false
    var allSpaces = false
    var archived = false
    var collapsed = false
    var trashedAt: Date?            // in the trash since this date
    var reminder: Date?             // scheduled reminder
    var sound: String?              // reminder sound for this note (nil = the default one)
    var importantReminder = false   // repeats and ignores quiet hours

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var n = Note()
        n.id = c.v(.id, n.id)
        n.content = c.v(.content, n.content)
        n.plainText = c.v(.plainText, n.plainText)
        n.style = c.v(.style, n.style)
        n.frame = c.v(.frame, n.frame)
        n.created = c.v(.created, n.created)
        n.modified = c.v(.modified, n.modified)
        n.isOpen = c.v(.isOpen, n.isOpen)
        n.floating = c.v(.floating, n.floating)
        n.allSpaces = c.v(.allSpaces, n.allSpaces)
        n.archived = c.v(.archived, n.archived)
        n.collapsed = c.v(.collapsed, n.collapsed)
        n.trashedAt = try? c.decodeIfPresent(Date.self, forKey: .trashedAt)
        n.reminder = try? c.decodeIfPresent(Date.self, forKey: .reminder)
        n.sound = try? c.decodeIfPresent(String.self, forKey: .sound)
        n.importantReminder = c.v(.importantReminder, n.importantReminder)
        self = n
    }

    var isTrashed: Bool { trashedAt != nil }
    /// Visible on screen / in menus: neither archived nor in the trash.
    var isActive: Bool { !archived && trashedAt == nil }

    var title: String {
        let line = plainText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? L("Empty note") : String(line.prefix(80))
    }

    var preview: String {
        let lines = plainText.split(whereSeparator: \.isNewline).dropFirst()
        return lines.joined(separator: " ").prefix(120).trimmingCharacters(in: .whitespaces)
    }

    var attributed: NSAttributedString {
        if !content.isEmpty, let a = NSAttributedString(rtfd: content, documentAttributes: nil) { return a }
        return NSAttributedString(string: plainText, attributes: style.typingAttributes)
    }

    mutating func setText(_ a: NSAttributedString) {
        content = a.rtfd(from: NSRange(location: 0, length: a.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) ?? Data()
        plainText = a.string
    }
}

// MARK: - Themes

struct Theme: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var style: NoteStyle

    static func make(_ id: String, _ name: String, bg: UInt32, configure: (inout NoteStyle) -> Void = { _ in }) -> Theme {
        var s = NoteStyle()
        s.background = RGBA(hex: bg)
        s.text = s.background.readableText
        configure(&s)
        return Theme(id: UUID(uuidString: id)!, name: name, style: s)
    }

    static let builtIns: [Theme] = [
        make("00000000-0000-0000-0000-000000000001", L("Classic yellow"), bg: 0xFFE680),
        make("00000000-0000-0000-0000-000000000002", L("Pink"), bg: 0xFFC2D4),
        make("00000000-0000-0000-0000-000000000003", L("Mint"), bg: 0xBDEBD5),
        make("00000000-0000-0000-0000-000000000004", L("Sky"), bg: 0xB3DCFF),
        make("00000000-0000-0000-0000-000000000005", L("Lavender"), bg: 0xDCCBF5),
        make("00000000-0000-0000-0000-000000000006", L("Peach"), bg: 0xFFD3A8),
        make("00000000-0000-0000-0000-000000000007", L("Paper"), bg: 0xFBFAF6) { s in
            s.fontName = "Georgia"; s.fontSize = 15; s.borderWidth = 1; s.cornerRadius = 4
        },
        make("00000000-0000-0000-0000-000000000008", L("Night"), bg: 0x26262C) { s in
            s.text = RGBA(hex: 0xE8E6E3); s.border = RGBA(hex: 0xFFFFFF, a: 0.12); s.borderWidth = 1
        },
        make("00000000-0000-0000-0000-000000000009", L("Glass"), bg: 0xFFFFFF) { s in
            s.opacity = 0.55; s.cornerRadius = 14; s.borderWidth = 1; s.border = RGBA(hex: 0xFFFFFF, a: 0.6)
        },
        make("00000000-0000-0000-0000-00000000000A", L("Terminal"), bg: 0x0E1A12) { s in
            s.text = RGBA(hex: 0x6CF08C); s.fontName = "Menlo"; s.fontSize = 13; s.cornerRadius = 2
        },
        make("00000000-0000-0000-0000-00000000000B", "Liquid Glass", bg: 0xFFFFFF) { s in
            s.material = .glass; s.glassTint = 0.12; s.text = RGBA(hex: 0x1C1C1E); s.cornerRadius = 22
            s.padding = 16; s.headerHeight = 26; s.shadow = false
        },
        make("00000000-0000-0000-0000-00000000000C", L("Liquid Glass amber"), bg: 0xFFC94D) { s in
            s.material = .glass; s.glassTint = 0.35; s.text = RGBA(hex: 0x2B2111); s.cornerRadius = 22
            s.padding = 16; s.headerHeight = 26; s.shadow = false
        },
        make("00000000-0000-0000-0000-00000000000D", L("Liquid Glass night"), bg: 0x1C1C24) { s in
            s.material = .glass; s.glassTint = 0.45; s.text = RGBA(hex: 0xF2F2F7); s.cornerRadius = 22
            s.padding = 16; s.headerHeight = 26; s.shadow = false
        },
        make("00000000-0000-0000-0000-00000000000E", L("Clear glass"), bg: 0xB3DCFF) { s in
            s.material = .clearGlass; s.glassTint = 0.15; s.text = RGBA(hex: 0x10202E); s.cornerRadius = 22
            s.padding = 16; s.headerHeight = 26; s.shadow = false; s.fontName = "Avenir Next"
        },
    ]
}

// MARK: - Preferences

struct AppSettings: Codable, Equatable {
    var defaultThemeID: UUID? = Theme.builtIns.first?.id
    var randomTheme = false
    var showInDock = false
    var showNotesAtLaunch = true
    var confirmDelete = true
    var continueLists = true
    var newNotesFloat = false
    var newNoteWidth: Double = 260
    var newNoteHeight: Double = 240
    var hotKeyEnabled = true
    var hotKeyKey = "N"
    var hotKeyCommand = false
    var hotKeyControl = true
    var hotKeyOption = true
    var hotKeyShift = false
    var askHotKeyKey = "Space"
    var askHotKeyCommand = false
    var askHotKeyControl = true
    var askHotKeyOption = true
    var askHotKeyShift = false
    var emailRecipient = ""
    var emailFormatted = true
    var trashDays = 30
    var whatsappNumber = ""
    var emojiFavorites = "✅❗️⭐️📌💡🔥📅⏰📞✉️🛒💰🎯👍❤️😊"
    var checkForUpdates = true
    var skippedVersion = ""
    var aiActions = AIAction.builtIns
    var aiHotKeyEnabled = true
    var translateLanguages = ["en", "it", "es", "fr", "de"]
    var reminderSound = "Glass"
    var soundVolume: Double = 0.8
    var repeatCount = 1               // how many times a reminder rings
    var repeatMinutes = 1
    var speakReminders = false
    var uiSounds = false
    var quietHoursEnabled = false
    var quietFrom = 22 * 60           // minutes after midnight
    var quietTo = 7 * 60

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = AppSettings()
        s.defaultThemeID = c.v(.defaultThemeID, s.defaultThemeID)
        s.randomTheme = c.v(.randomTheme, s.randomTheme)
        s.showInDock = c.v(.showInDock, s.showInDock)
        s.showNotesAtLaunch = c.v(.showNotesAtLaunch, s.showNotesAtLaunch)
        s.confirmDelete = c.v(.confirmDelete, s.confirmDelete)
        s.continueLists = c.v(.continueLists, s.continueLists)
        s.newNotesFloat = c.v(.newNotesFloat, s.newNotesFloat)
        s.newNoteWidth = c.v(.newNoteWidth, s.newNoteWidth)
        s.newNoteHeight = c.v(.newNoteHeight, s.newNoteHeight)
        s.hotKeyEnabled = c.v(.hotKeyEnabled, s.hotKeyEnabled)
        s.hotKeyKey = c.v(.hotKeyKey, s.hotKeyKey)
        s.hotKeyCommand = c.v(.hotKeyCommand, s.hotKeyCommand)
        s.hotKeyControl = c.v(.hotKeyControl, s.hotKeyControl)
        s.hotKeyOption = c.v(.hotKeyOption, s.hotKeyOption)
        s.hotKeyShift = c.v(.hotKeyShift, s.hotKeyShift)
        s.askHotKeyKey = c.v(.askHotKeyKey, s.askHotKeyKey)
        s.askHotKeyCommand = c.v(.askHotKeyCommand, s.askHotKeyCommand)
        s.askHotKeyControl = c.v(.askHotKeyControl, s.askHotKeyControl)
        s.askHotKeyOption = c.v(.askHotKeyOption, s.askHotKeyOption)
        s.askHotKeyShift = c.v(.askHotKeyShift, s.askHotKeyShift)
        s.emailRecipient = c.v(.emailRecipient, s.emailRecipient)
        s.emailFormatted = c.v(.emailFormatted, s.emailFormatted)
        s.trashDays = c.v(.trashDays, s.trashDays)
        s.whatsappNumber = c.v(.whatsappNumber, s.whatsappNumber)
        s.emojiFavorites = c.v(.emojiFavorites, s.emojiFavorites)
        s.checkForUpdates = c.v(.checkForUpdates, s.checkForUpdates)
        s.skippedVersion = c.v(.skippedVersion, s.skippedVersion)
        s.aiActions = c.v(.aiActions, s.aiActions)
        s.aiHotKeyEnabled = c.v(.aiHotKeyEnabled, s.aiHotKeyEnabled)
        s.translateLanguages = c.v(.translateLanguages, s.translateLanguages)
        s.reminderSound = c.v(.reminderSound, s.reminderSound)
        s.soundVolume = c.v(.soundVolume, s.soundVolume)
        s.repeatCount = c.v(.repeatCount, s.repeatCount)
        s.repeatMinutes = c.v(.repeatMinutes, s.repeatMinutes)
        s.speakReminders = c.v(.speakReminders, s.speakReminders)
        s.uiSounds = c.v(.uiSounds, s.uiSounds)
        s.quietHoursEnabled = c.v(.quietHoursEnabled, s.quietHoursEnabled)
        s.quietFrom = c.v(.quietFrom, s.quietFrom)
        s.quietTo = c.v(.quietTo, s.quietTo)
        self = s
    }

    var hotKeyLabel: String {
        Self.label(hotKeyKey, control: hotKeyControl, option: hotKeyOption, shift: hotKeyShift, command: hotKeyCommand)
    }

    var askHotKeyLabel: String {
        Self.label(askHotKeyKey, control: askHotKeyControl, option: askHotKeyOption, shift: askHotKeyShift, command: askHotKeyCommand)
    }

    /// True when both global shortcuts are on and use the same keys (only one could work).
    var hotKeysClash: Bool {
        hotKeyEnabled && aiHotKeyEnabled && hotKeyKey == askHotKeyKey && hotKeyControl == askHotKeyControl
            && hotKeyOption == askHotKeyOption && hotKeyShift == askHotKeyShift && hotKeyCommand == askHotKeyCommand
    }

    static func label(_ key: String, control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (key == "Space" ? L("Space") : key)
    }
}

// MARK: - Text restyling

enum TextStyler {
    /// Applies the new style to existing text: changes family and color and scales sizes
    /// proportionally (so headings stay bigger than body text).
    static func restyle(_ ts: NSMutableAttributedString, from old: NoteStyle, to new: NoteStyle) {
        let full = NSRange(location: 0, length: ts.length)
        guard full.length > 0 else { return }
        let fm = NSFontManager.shared
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: full) { value, range, _ in
            let f = (value as? NSFont) ?? old.baseFont
            let ratio = old.fontSize > 0 ? f.pointSize / old.fontSize : 1
            var nf = fm.convert(f, toSize: max(6, new.fontSize * ratio))
            if old.fontName != new.fontName { nf = new.convertFamily(nf) }
            ts.addAttribute(.font, value: nf, range: range)
        }
        if old.text != new.text {
            ts.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                // keeps the transparency of ticked items
                let alpha = (value as? NSColor).map { $0.alphaComponent } ?? 1
                ts.addAttribute(.foregroundColor, value: new.text.ns.withAlphaComponent(alpha * new.text.a), range: range)
            }
        }
        if old.lineSpacing != new.lineSpacing {
            ts.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
                let p = ((value as? NSParagraphStyle) ?? new.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
                p.lineSpacing = new.lineSpacing
                ts.addAttribute(.paragraphStyle, value: p, range: range)
            }
        }
        ts.endEditing()
    }
}
