import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

// MARK: - Note list

struct NotesListView: View {
    @EnvironmentObject var store: NoteStore
    @Local private var query = ""
    @Local private var section = 0          // 0 notes, 1 archive, 2 trash
    @Local private var selection = Set<UUID>()

    private var manager: NotesManager { NotesManager.shared }

    private var filtered: [Note] {
        store.notes
            .filter { section == 2 ? $0.isTrashed : (!$0.isTrashed && $0.archived == (section == 1)) }
            .filter { query.isEmpty || $0.plainText.localizedCaseInsensitiveContains(query) }
            .sorted { $0.modified > $1.modified }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $section) {
                    Text(L("Notes")).tag(0)
                    Text(L("Archive")).tag(1)
                    Text(L("Trash")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                TextField(L("Search"), text: $query).textFieldStyle(.roundedBorder)
                Button { manager.newNote() } label: { Label(L("New"), systemImage: "plus") }
            }
            .padding(10)
            List(filtered, selection: $selection) { n in
                row(n)
                    .tag(n.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !n.isTrashed { manager.show(n.id, focus: true) } }
                    .contextMenu { menu(for: n) }
            }
            .overlay {
                if filtered.isEmpty {
                    Text(query.isEmpty ? ([L("No notes"), L("No archived notes"), L("The trash is empty")][section]) : L("No results"))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(L("%ld notes", filtered.count)).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if section == 2 {
                    Text(L("Notes stay here for %ld days", store.settings.trashDays)).font(.caption).foregroundStyle(.secondary)
                    Button(L("Restore selected")) { manager.restore(Array(selection)); selection = [] }
                        .disabled(selection.isEmpty)
                    Button(L("Empty Trash"), role: .destructive) { manager.emptyTrash(); selection = [] }
                        .disabled(filtered.isEmpty)
                } else {
                    Button(L("Show all")) { manager.showAll() }
                    Button(L("Hide all")) { manager.hideAll() }
                    Button(L("Move to Trash")) { manager.moveToTrash(Array(selection)); selection = [] }
                        .disabled(selection.isEmpty)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private func row(_ n: Note) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(n.style.background.swiftUI)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.15)))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).lineLimit(1).fontWeight(.medium)
                if !n.preview.isEmpty { Text(n.preview).lineLimit(1).foregroundStyle(.secondary).font(.caption) }
            }
            Spacer()
            if let r = n.reminder {
                Label(Reminders.label(r), systemImage: "bell.fill").font(.caption).foregroundStyle(.orange)
            }
            Text(n.modified, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            if !n.isTrashed { Button {
                if n.isOpen && !n.archived { store.update(n.id) { $0.isOpen = false } } else { manager.show(n.id, focus: true) }
            } label: {
                Image(systemName: n.isOpen && !n.archived ? "eye.fill" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(n.isOpen ? L("Hide") : L("Show")) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func menu(for n: Note) -> some View {
        if n.isTrashed {
            Button(L("Restore")) { manager.restore([n.id]) }
            Divider()
            Button(L("Delete permanently…"), role: .destructive) { manager.deletePermanently([n.id]) }
        } else {
            Button(L("Show")) { manager.show(n.id, focus: true) }
            Button(n.archived ? L("Restore") : L("Archive note")) {
                manager.controllers[n.id]?.flush()
                store.update(n.id) { $0.archived.toggle(); $0.isOpen = false }
            }
            Menu(L("Reminder")) {
                ForEach(Reminders.presets(), id: \.0) { p in Button(p.0) { Reminders.shared.set(n.id, at: p.1) } }
                Button(L("Date and time…")) { if let d = Reminders.askDate(initial: n.reminder) { Reminders.shared.set(n.id, at: d) } }
                if n.reminder != nil { Divider(); Button(L("Remove reminder")) { Reminders.shared.set(n.id, at: nil) } }
            }
            Button(L("Send by email…")) {
                manager.controllers[n.id]?.flush()
                if let note = store.note(n.id)?.readable { Emailer.send(note, settings: store.settings) } else { NSSound.beep() }
            }
            Button(L("Send via WhatsApp")) {
                manager.controllers[n.id]?.flush()
                if let note = store.note(n.id)?.readable { WhatsApp.send(note, settings: store.settings) } else { NSSound.beep() }
            }
            Menu(L("Theme")) {
                ForEach(store.themes) { t in Button(t.name) { store.update(n.id) { $0.style = t.style } } }
            }
            Divider()
            Button(L("Move to Trash")) { manager.moveToTrash([n.id]) }
        }
    }
}

// MARK: - Settings

/// Settings with a sidebar, like System Settings.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, themes, sounds, ai, shortcuts, protected, data, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: L("General")
            case .themes: L("Themes")
            case .sounds: L("Sounds")
            case .ai: L("AI & Translation")
            case .shortcuts: L("Shortcuts")
            case .data: L("Data & Sync")
            case .protected: L("Protected Notes")
            case .about: L("About & Updates")
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .themes: "paintpalette.fill"
            case .sounds: "speaker.wave.2.fill"
            case .ai: "sparkles"
            case .shortcuts: "keyboard.fill"
            case .data: "icloud.fill"
            case .protected: "lock.fill"
            case .about: "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .general: .gray
            case .themes: .orange
            case .sounds: .pink
            case .ai: .purple
            case .shortcuts: .gray
            case .data: .blue
            case .protected: .indigo
            case .about: .teal
            }
        }
    }

    @Local private var page: Page? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(Page.allCases) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(p.color.gradient))
                        Text(p.title)
                    }
                    .padding(.vertical, 2)
                    .tag(p)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            Group {
                switch page ?? .general {
                case .general: GeneralSettings()
                case .themes: ThemesSettings()
                case .sounds: SoundSettings()
                case .ai: AISettings()
                case .shortcuts: ShortcutSettings()
                case .data: DataSettings()
                case .protected: ProtectedSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

struct AboutSettings: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Foglietti").font(.title2).bold()
                        Text(L("Version %@", UpdateChecker.shared.currentVersion)).foregroundStyle(.secondary)
                        Text(L("Customizable sticky notes for macOS.")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section(L("Updates")) {
                Toggle(L("Check for updates automatically"), isOn: $store.settings.checkForUpdates)
                HStack {
                    Button(L("Check Now")) { UpdateChecker.shared.check(manual: true) }
                    if !store.settings.skippedVersion.isEmpty {
                        Button(L("Stop skipping version %@", store.settings.skippedVersion)) { store.settings.skippedVersion = "" }
                    }
                }
                Text(L("Foglietti looks at the public releases on GitHub once a day. Nothing is downloaded or installed without you."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Project")) {
                Link(L("Source code on GitHub"), destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
                Link(L("Release notes"), destination: URL(string: "https://github.com/\(UpdateChecker.repository)/releases")!)
                Button(L("Show the welcome window")) { WelcomeController.shared.show() }
                    .buttonStyle(.link)
                LabeledContent(L("License"), value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: NoteStore
    @Local private var loginEnabled = SMAppService.mainApp.status == .enabled
    @Local private var loginError: String?

    var body: some View {
        Form {
            Section(L("Startup")) {
                Toggle(L("Open at login"), isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(L("Show open notes at launch"), isOn: $store.settings.showNotesAtLaunch)
                Toggle(L("Dock icon (otherwise menu bar only)"), isOn: $store.settings.showInDock)
            }
            Section(L("New notes")) {
                Picker(L("Default theme"), selection: $store.settings.defaultThemeID) {
                    ForEach(store.themes) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(store.settings.randomTheme)
                Toggle(L("Random theme for each new note"), isOn: $store.settings.randomTheme)
                Toggle(L("Always on top"), isOn: $store.settings.newNotesFloat)
                SliderRow(title: L("Width"), value: $store.settings.newNoteWidth, range: 160...700, step: 10)
                SliderRow(title: L("Height"), value: $store.settings.newNoteHeight, range: 80...700, step: 10)
            }
            Section(L("Email")) {
                TextField(L("Default recipient"), text: $store.settings.emailRecipient, prompt: Text(L("e.g. name@example.com, other@example.com")))
                Text(L("Used by \"Send by email\" (⇧⌘M or the note's ⋯ menu). Leave empty to choose the recipient each time."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Formatted email (colors, bold, images)"), isOn: $store.settings.emailFormatted)
                Text(L("Keeps bold, italic, colors, headings and links; images are attached."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("WhatsApp")) {
                TextField(L("Default number"), text: $store.settings.whatsappNumber, prompt: Text(L("e.g. +1 555 123 4567")))
                Text(L("With a number, \"Send via WhatsApp\" (⌃⌘W) opens that chat directly. Leave empty to pick the contact each time. Bold, italic and strikethrough are converted; images are copied to the clipboard to paste into the chat."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Emoji")) {
                TextField(L("My emoji set"), text: $store.settings.emojiFavorites)
                    .font(.system(size: 16))
                HStack {
                    Text(L("The emoji you always want at hand, in the order you like. Add more with ⌃⌘Space."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Restore")) { store.settings.emojiFavorites = AppSettings().emojiFavorites }
                }
            }
            Section(L("Writing")) {
                Toggle(L("Continue lists and checkboxes with Return"), isOn: $store.settings.continueLists)
                Toggle(L("Ask before deleting permanently"), isOn: $store.settings.confirmDelete)
                Stepper(L("Empty the trash after %ld days", store.settings.trashDays), value: $store.settings.trashDays, in: 1...365)
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("Failed: %@. Move the app to Applications and try again.", error.localizedDescription)
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct ThemesSettings: View {
    @EnvironmentObject var store: NoteStore
    @Local private var selected: UUID?

    private var index: Int? { store.themes.firstIndex { $0.id == selected } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.themes) { t in
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(t.style.background.swiftUI).frame(width: 16, height: 16)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.2)))
                            Text(t.name)
                            if t.id == store.settings.defaultThemeID { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        }
                        .tag(t.id)
                    }
                    .onMove { store.themes.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 4) {
                    Button { selected = store.saveTheme(named: "", style: NoteStyle()).id } label: { Image(systemName: "plus") }
                    Button {
                        if let i = index { var t = store.themes[i]; t.id = UUID(); t.name += " copia"; store.themes.insert(t, at: i + 1); selected = t.id }
                    } label: { Image(systemName: "plus.square.on.square") }.disabled(index == nil)
                    Button {
                        if let i = index, store.themes.count > 1 { store.themes.remove(at: i); selected = store.themes.first?.id }
                    } label: { Image(systemName: "minus") }.disabled(index == nil || store.themes.count <= 1)
                    Spacer()
                    Menu {
                        Button(L("Export themes…"), action: exportThemes)
                        Button(L("Import themes…"), action: importThemes)
                        Divider()
                        Button(L("Add missing built-in themes")) {
                            for t in Theme.builtIns where !store.themes.contains(where: { $0.id == t.id }) { store.themes.append(t) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 36)
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            if let i = index {
                Form {
                    Section {
                        TextField(L("Name"), text: $store.themes[i].name)
                        HStack {
                            Button(L("Set as default")) { store.settings.defaultThemeID = store.themes[i].id }
                            Button(L("Apply to all notes")) {
                                let s = store.themes[i].style
                                for n in store.notes { store.update(n.id) { $0.style = s } }
                            }
                        }
                        NotePreview(style: store.themes[i].style).frame(height: 120).padding(.vertical, 6)
                    }
                    StyleForm(style: $store.themes[i].style)
                }
                .formStyle(.grouped)
            } else {
                Text(L("Select a theme")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selected = selected ?? store.themes.first?.id }
    }

    private func exportThemes() {
        let p = NSSavePanel()
        p.nameFieldStringValue = L("Foglietti themes.json")
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(store.themes).write(to: url)
    }

    private func importThemes() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url,
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([Theme].self, from: data) else { return }
        for var t in themes {
            if store.themes.contains(where: { $0.id == t.id }) { t.id = UUID() }
            store.themes.append(t)
        }
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var store: NoteStore
    private let keys = (65...90).map { String(UnicodeScalar($0)!) } + (0...9).map(String.init)

    var body: some View {
        Form {
            Section(L("New note from any app")) {
                HotKeyEditor(enabled: $store.settings.hotKeyEnabled, key: $store.settings.hotKeyKey,
                             control: $store.settings.hotKeyControl, option: $store.settings.hotKeyOption,
                             shift: $store.settings.hotKeyShift, command: $store.settings.hotKeyCommand,
                             label: store.settings.hotKeyLabel)
                if HotKey.shared.lastError != nil {
                    Text(L("That combination is already used by another app: choose a different one.")).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                HotKeyEditor(enabled: $store.settings.aiHotKeyEnabled, key: $store.settings.askHotKeyKey,
                             control: $store.settings.askHotKeyControl, option: $store.settings.askHotKeyOption,
                             shift: $store.settings.askHotKeyShift, command: $store.settings.askHotKeyCommand,
                             label: store.settings.askHotKeyLabel)
                if store.settings.hotKeysClash {
                    Text(L("It's the same combination as New note: choose a different one.")).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(L("Ask Foglietti from any app"))
            } footer: {
                Text(L("If nothing happens when you press it, another app (a launcher, a taskbar…) is using the same combination: pick another one, e.g. ⌃⌥A."))
            }
            Section(L("In notes")) {
                LabeledContent(L("Ask Foglietti (from any app)"), value: store.settings.aiHotKeyEnabled ? store.settings.askHotKeyLabel : L("Off"))
                ForEach(shortcuts, id: \.0) { LabeledContent($0.0, value: $0.1) }
            }
        }
        .formStyle(.grouped)
    }

    private let shortcuts = [
        (L("New note"), "⌘N"), (L("Close note"), "⌘W"), (L("Bold / Italic / Underline"), "⌘B / ⌘I / ⌘U"),
        (L("Strikethrough"), "⇧⌘X"), (L("Highlight"), "⇧⌘H"), (L("Checkbox"), "⇧⌘L"),
        (L("Title / Subtitle / Body"), "⌘1 / ⌘2 / ⌘0"), (L("Bigger / Smaller text"), "⌘+ / ⌘−"),
        (L("Insert date"), "⇧⌘D"), (L("Emoji"), "⌃⌘E"), (L("Insert screenshot"), "⇧⌘I"), (L("Open image in Preview"), L("double-click")), (L("AI actions on the note"), "⌘J"), (L("Translate note"), "⌥⌘T"), (L("Custom AI instruction"), "⇧⌘J"), (L("System emoji & symbols"), "⌃⌘" + L("Space")), (L("Send by email"), "⇧⌘M"), (L("Send via WhatsApp"), "⌃⌘W"), (L("Paste with formatting"), "⌥⌘V"), (L("Note list"), "⇧⌘E"),
        (L("Collapse to bar"), L("double-click the bar")),
    ]
}

struct DataSettings: View {
    @EnvironmentObject var store: NoteStore
    @Local private var message: String?

    var body: some View {
        Form {
            Section(L("Import")) {
                Text(L("Turn text files into notes: .txt, .md, .rtf and .rtfd (several at once). Imported notes go to the list, closed."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L("Import files…"), action: importFiles)
            }
            Section(L("Export")) {
                Button(L("Export all notes to a folder (RTFD + text)…"), action: exportAll)
            }
            Section(L("Sync between Macs")) {
                Toggle(L("Store notes in iCloud Drive"), isOn: Binding(
                    get: { store.usesICloud },
                    set: { on in store.moveData(to: on ? NoteStore.iCloudDirectory : NoteStore.localDirectory) }))
                    .disabled(!NoteStore.iCloudAvailable && !store.usesICloud)
                Text(NoteStore.iCloudAvailable
                     ? L("Install Foglietti on each Mac and turn this on: notes are merged and kept in sync (the most recent change wins). If the folder already holds notes, they are merged, not overwritten.")
                     : L("iCloud Drive is not enabled on this Mac (System Settings → Apple Account → iCloud → iCloud Drive)."))
                    .font(.caption).foregroundStyle(.secondary)
                if let d = store.lastSync {
                    LabeledContent(L("Last update from another Mac"), value: d.formatted(date: .abbreviated, time: .standard))
                }
            }
            Section(L("Data storage")) {
                LabeledContent(L("Data file"), value: store.fileURL.path).textSelection(.enabled)
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func importFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.plainText, .rtf, .rtfd, UTType(filenameExtension: "md") ?? .plainText]
        guard p.runModal() == .OK else { return }
        let style = store.styleForNewNote()
        var imported = 0
        for url in p.urls {
            let text: NSAttributedString?
            switch url.pathExtension.lowercased() {
            case "rtf", "rtfd":
                text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            default:
                text = (try? String(contentsOf: url, encoding: .utf8)).map { NSAttributedString(string: $0, attributes: style.typingAttributes) }
            }
            guard let text, text.length > 0 else { continue }
            var n = Note()
            n.style = style
            n.isOpen = false
            n.setText(text)
            store.notes.append(n)
            imported += 1
        }
        message = L("Imported %ld notes from %ld files.", imported, p.urls.count)
    }

    private func exportAll() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("Export here")
        guard p.runModal() == .OK, let dir = p.url else { return }
        NotesManager.shared.flushAll()
        var used = Set<String>()
        var exported = 0, skipped = 0
        for original in store.notes {
            // protected notes are exported only while unlocked, never as encrypted noise
            guard let n = original.readable else { skipped += 1; continue }
            exported += 1
            var name = n.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            while used.contains(name) { name += " bis" }
            used.insert(name)
            let a = n.attributed
            let range = NSRange(location: 0, length: a.length)
            try? a.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                .write(to: dir.appendingPathComponent(name + ".rtfd"), options: .atomic, originalContentsURL: nil)
            try? n.plainText.write(to: dir.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        message = L("Exported %ld notes to %@.", exported, dir.lastPathComponent)
            + (skipped > 0 ? " " + L("%ld protected notes were skipped: unlock them to include them.", skipped) : "")
    }
}

// MARK: - AI

struct AISettings: View {
    @EnvironmentObject var store: NoteStore
    @Local private var selected: UUID?

    private var index: Int? { store.settings.aiActions.firstIndex { $0.id == selected } }

    var body: some View {
        Form {
            Section(L("Apple Intelligence")) {
                if let problem = AIAvailability.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label(L("Ready. The model runs on this Mac: notes are never sent to any server."), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Toggle(L("\"Ask Foglietti\" from any app with %@", store.settings.askHotKeyLabel), isOn: $store.settings.aiHotKeyEnabled)
            }
            Section {
                ForEach(Array(store.settings.translateLanguages.enumerated()), id: \.offset) { i, code in
                    HStack {
                        Picker(L("Language %ld", i + 1), selection: $store.settings.translateLanguages[i]) {
                            ForEach(Translator.languages, id: \.self) { Text("\(Translator.flag($0)) \(Translator.name($0))").tag($0) }
                        }
                        Button { store.settings.translateLanguages.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(store.settings.translateLanguages.count <= 1)
                    }
                }
                Button(L("Add language")) {
                    let next = Translator.languages.first { !store.settings.translateLanguages.contains($0) } ?? "en"
                    store.settings.translateLanguages.append(next)
                }
            } header: {
                Text(L("Translation (Apple Translate)"))
            } footer: {
                Text(L("Preferred languages appear at the top of the 🌐 menu. ⌥⌘T translates right away into the first language that differs from the text's. The first time, macOS asks to download the languages; after that it also works offline."))
            }
            Section {
                List(selection: $selected) {
                    ForEach(store.settings.aiActions) { a in
                        Label(a.name, systemImage: a.symbol).tag(a.id)
                    }
                    .onMove { store.settings.aiActions.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: 150)
                HStack {
                    Button { let a = AIAction(name: L("New action"), prompt: L("Describe what to do with the text…")); store.settings.aiActions.append(a); selected = a.id } label: { Image(systemName: "plus") }
                    Button { if let i = index { store.settings.aiActions.remove(at: i); selected = nil } } label: { Image(systemName: "minus") }
                        .disabled(index == nil)
                    Spacer()
                    Button(L("Restore defaults")) { store.settings.aiActions = AIAction.builtIns; selected = nil }
                }
                .buttonStyle(.borderless)
                if let i = index {
                    TextField(L("Name in menu"), text: $store.settings.aiActions[i].name)
                    TextField(L("Instruction for the AI"), text: $store.settings.aiActions[i].prompt, axis: .vertical)
                        .lineLimit(3...6)
                    TextField(L("Icon (SF Symbol name)"), text: $store.settings.aiActions[i].symbol)
                }
            } header: {
                Text(L("Actions in the note's ✨ menu"))
            } footer: {
                Text(L("Drag to reorder. Write the instruction as you would to a person: “Rewrite as an email to the client”, “Extract only the phone numbers”…"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sounds

struct SoundSettings: View {
    @EnvironmentObject var store: NoteStore

    /// Minutes after midnight as a Date, for the time pickers.
    private func time(_ kp: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: store.settings[keyPath: kp] / 60, minute: store.settings[keyPath: kp] % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                store.settings[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Sound"), selection: $store.settings.reminderSound) {
                    Text(L("None")).tag("")
                    Divider()
                    ForEach(Sounds.available, id: \.self) { Text($0).tag($0) }
                    if store.settings.reminderSound.hasPrefix("/") {
                        Text(Sounds.displayName(store.settings.reminderSound)).tag(store.settings.reminderSound)
                    }
                }
                HStack {
                    Button(L("Play")) { Sounds.play(store.settings.reminderSound, volume: store.settings.soundVolume) }
                    Button(L("Choose a file…")) { if let p = Sounds.chooseFile() { store.settings.reminderSound = p } }
                }
                SliderRow(title: L("Volume"), value: $store.settings.soundVolume, range: 0...1, step: 0.05) { "\(Int($0 * 100))%" }
                Stepper(store.settings.repeatCount == 1 ? L("Ring once") : L("Ring %ld times", store.settings.repeatCount),
                        value: $store.settings.repeatCount, in: 1...10)
                if store.settings.repeatCount > 1 {
                    Picker(L("Every"), selection: $store.settings.repeatMinutes) {
                        ForEach([1, 2, 5, 10], id: \.self) { Text(L("%ld min", $0)).tag($0) }
                    }
                }
                HStack {
                    Toggle(L("Read the note title aloud"), isOn: $store.settings.speakReminders)
                    Button(L("Try")) { Sounds.speak(L("Reminder: call the dentist"), volume: store.settings.soundVolume) }
                }
            } header: {
                Text(L("Reminders"))
            } footer: {
                Text(L("A ringing reminder stops as soon as you click or type in the note, or from the menu bar. Notes marked Important ring at least 5 times. Each note can have its own sound: 🔔 → Sound."))
            }
            Section {
                Toggle(L("Silence sounds during quiet hours"), isOn: $store.settings.quietHoursEnabled)
                if store.settings.quietHoursEnabled {
                    DatePicker(L("From"), selection: time(\.quietFrom), displayedComponents: .hourAndMinute)
                    DatePicker(L("To"), selection: time(\.quietTo), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text(L("Quiet hours"))
            } footer: {
                Text(L("The note still appears on screen. Important reminders ring anyway."))
            }
            Section(L("Interface")) {
                Toggle(L("Interface sounds (checkbox ticked, AI or translation done, note moved to Trash)"), isOn: $store.settings.uiSounds)
            }
        }
        .formStyle(.grouped)
    }
}

/// Editor for a global shortcut: on/off, modifier keys and the main key.
struct HotKeyEditor: View {
    @Binding var enabled: Bool
    @Binding var key: String
    @Binding var control: Bool
    @Binding var option: Bool
    @Binding var shift: Bool
    @Binding var command: Bool
    let label: String
    private let keys = ["Space"] + (65...90).map { String(UnicodeScalar($0)!) } + (0...9).map(String.init)

    var body: some View {
        Toggle(L("Enable global shortcut"), isOn: $enabled)
        HStack(spacing: 16) {
            Toggle(L("⌃ Control"), isOn: $control)
            Toggle(L("⌥ Option"), isOn: $option)
            Toggle(L("⇧ Shift"), isOn: $shift)
            Toggle(L("⌘ Command"), isOn: $command)
        }
        .disabled(!enabled)
        Picker(L("Key"), selection: $key) {
            ForEach(keys, id: \.self) { Text($0 == "Space" ? L("Space") : $0).tag($0) }
        }
        .disabled(!enabled)
        LabeledContent(L("Current shortcut"), value: label)
        if enabled && !(control || option || shift || command) {
            Text(L("Add at least one modifier key (⌃ ⌥ ⇧ ⌘)."))
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Protected notes

struct ProtectedSettings: View {
    @EnvironmentObject var store: NoteStore
    @Local private var unlocked = Vault.shared.isUnlocked
    @Local private var message: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                if store.vault == nil {
                    Label(L("No master password yet. It is created the first time you protect a note."), systemImage: "lock.open")
                    Button(L("Create Master Password…")) { _ = Vault.shared.runSetup() }
                } else {
                    Label(unlocked ? L("Unlocked") : L("Locked"), systemImage: unlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(unlocked ? .orange : .green)
                    HStack {
                        if unlocked {
                            Button(L("Lock Now")) { Vault.shared.lock() }
                        } else {
                            Button(L("Unlock…")) { Task { @MainActor in _ = await Vault.shared.ensureUnlocked() } }
                        }
                        Button(L("Change Master Password…"), action: changePassword)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text(L("Master password"))
            } footer: {
                Text(L("Protected notes are encrypted (AES-256) with a key made from your master password. If you forget it, they can't be recovered."))
            }
            Section(L("Unlocking")) {
                Toggle(L("Unlock with Touch ID"), isOn: Binding(get: { store.settings.vaultTouchID }, set: setTouchID))
                    .disabled(!Vault.touchIDAvailable || store.vault == nil)
                Picker(L("Lock again after"), selection: $store.settings.vaultAutoLockMinutes) {
                    ForEach([1, 5, 15, 60], id: \.self) { Text(L("%ld min of inactivity", $0)).tag($0) }
                    Text(L("Only on sleep or screen lock")).tag(0)
                }
                Text(L("Protected notes also lock when the Mac sleeps or the screen locks."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in unlocked = Vault.shared.isUnlocked }
    }

    private func setTouchID(_ on: Bool) {
        store.settings.vaultTouchID = on
        if !on { Vault.shared.deleteKeyFromKeychain(); return }
        Task { @MainActor in
            // the key can be stored only while unlocked
            if await Vault.shared.ensureUnlocked() { Vault.shared.saveKeyInKeychain() }
        }
    }

    private func changePassword() {
        let old = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let p1 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        old.placeholderString = L("Current password")
        p1.placeholderString = L("New password")
        p2.placeholderString = L("Repeat the new password")
        let stack = NSStackView(views: [old, p1, p2])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 88)
        let a = NSAlert()
        a.messageText = L("Change master password")
        a.informativeText = L("Every protected note is encrypted again with the new password.")
        a.accessoryView = stack
        a.addButton(withTitle: L("Change"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = old
        while a.runModal() == .alertFirstButtonReturn {
            if p1.stringValue.count < 6 { a.informativeText = L("Use at least 6 characters."); continue }
            if p1.stringValue != p2.stringValue { a.informativeText = L("The two passwords don't match."); continue }
            do {
                try Vault.shared.changePassword(old: old.stringValue, new: p1.stringValue)
                message = L("Master password changed.")
                return
            } catch {
                a.informativeText = error.localizedDescription
                old.stringValue = ""
            }
        }
    }
}
