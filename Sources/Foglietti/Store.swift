import AppKit
import Combine

/// Single source of truth: notes, themes and preferences, saved in a readable JSON file.
/// The file can live in iCloud Drive: then it is checked continuously and
/// changes made on another Mac are merged note by note (the most recent wins).
@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [Note] = [] { didSet { changed(notesChanged: true) } }
    @Published var themes: [Theme] = [] { didSet { changed() } }
    @Published var settings = AppSettings() { didSet { if settings != oldValue { changed(); onSettingsChange?() } } }
    /// Permanently deleted notes: needed so another Mac doesn't bring them back.
    private var tombstones: [UUID: Date] = [:]

    /// Called (asynchronously, coalesced) when notes change, to sync the windows.
    var onNotesChange: (() -> Void)?
    var onSettingsChange: (() -> Void)?

    @Published private(set) var directory: URL
    @Published private(set) var lastSync: Date?
    var fileURL: URL { directory.appendingPathComponent("foglietti.json") }

    static let localDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Foglietti", isDirectory: true)
    static let iCloudRoot = URL(fileURLWithPath: NSString(string: "~/Library/Mobile Documents/com~apple~CloudDocs").expandingTildeInPath)
    static let iCloudDirectory = iCloudRoot.appendingPathComponent("Foglietti", isDirectory: true)
    static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudRoot.path) }
    var usesICloud: Bool { directory.standardizedFileURL == Self.iCloudDirectory.standardizedFileURL }

    private static let locationKey = "dataDirectory"
    private var loading = false
    private var saveTask: Task<Void, Never>?
    private var syncScheduled = false
    private var backedUp = false
    private var lastWritten: Data?
    private var knownModDate: Date?
    private var watchTimer: Timer?

    private struct Persisted: Codable {
        var version = 2
        var notes: [Note]
        var themes: [Theme]
        var settings: AppSettings
        var tombstones: [UUID: Date]? = nil
    }

    init(directory: URL? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.locationKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? saved ?? Self.localDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Reading

    private func readDisk() -> Persisted? {
        let placeholder = directory.appendingPathComponent(".foglietti.json.icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            // iCloud evicted the file to save space: request it again
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        knownModDate = modDate()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ISO8601DateFormatter().date(from: s) { return date }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        do {
            return try dec.decode(Persisted.self, from: data)
        } catch {
            // unreadable file: set it aside instead of overwriting it
            let bad = directory.appendingPathComponent("foglietti-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: bad)
            NSLog("Foglietti: could not read data (\(error)); copy saved to \(bad.path)")
            return nil
        }
    }

    private func load() {
        loading = true
        defer { loading = false }
        if let p = readDisk() {
            notes = p.notes; themes = p.themes; settings = p.settings; tombstones = p.tombstones ?? [:]
        }
        if themes.isEmpty { themes = Theme.builtIns }
        // built-in themes added by an update: append them only once
        let seenKey = "seenBuiltInThemes"
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? Theme.builtIns.prefix(10).map(\.id.uuidString))
        for t in Theme.builtIns where !seen.contains(t.id.uuidString) && !themes.contains(where: { $0.id == t.id }) {
            themes.append(t)
        }
        UserDefaults.standard.set(Theme.builtIns.map(\.id.uuidString), forKey: seenKey)
    }

    private func modDate() -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Sync

    /// Periodically checks whether another copy of the app changed the file.
    func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in NoteStore.shared.checkForExternalChanges() }
        }
    }

    func checkForExternalChanges() {
        guard let m = modDate(), m != knownModDate else { return }
        NotesManager.shared.flushAll()
        mergeFromDisk()
    }

    private func mergeFromDisk() {
        guard let remote = readDisk() else { return }
        for (id, d) in remote.tombstones ?? [:] where (tombstones[id] ?? .distantPast) < d { tombstones[id] = d }

        var byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote.notes {
            if let local = byID[r.id], local.modified >= r.modified { continue }
            byID[r.id] = r
        }
        let merged = byID.values.filter { tombstones[$0.id] == nil }
        // keep the current order, new notes at the end
        let order = Dictionary(notes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = merged.sorted { (order[$0.id] ?? .max, $0.created) < (order[$1.id] ?? .max, $1.created) }
        if sorted != notes { notes = sorted }

        var themeByID = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in remote.themes { themeByID[t.id] = t }
        let mergedThemes = themes.map { themeByID[$0.id]! } + remote.themes.filter { t in !themes.contains { $0.id == t.id } }
        if mergedThemes != themes { themes = mergedThemes }
        if remote.settings != settings { settings = remote.settings }
        lastSync = Date()
        saveNow(skipMerge: true)   // writes only if the merge differs from what is on disk
    }

    // MARK: Writing

    private func changed(notesChanged: Bool = false) {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
        if notesChanged && !syncScheduled {
            syncScheduled = true
            Task { @MainActor [weak self] in
                self?.syncScheduled = false
                self?.onNotesChange?()
            }
        }
    }

    func saveNow(skipMerge: Bool = false) {
        saveTask?.cancel()
        // if another Mac wrote in the meantime, merge first so its changes aren't overwritten
        if !skipMerge, let m = modDate(), knownModDate != nil, m != knownModDate {
            mergeFromDisk()
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Persisted(notes: notes, themes: themes, settings: settings,
                                                  tombstones: tombstones.isEmpty ? nil : tombstones)) else { return }
        if data == lastWritten || data == (try? Data(contentsOf: fileURL)) {
            lastWritten = data
            knownModDate = modDate()
            return
        }
        if !backedUp, FileManager.default.fileExists(atPath: fileURL.path) {
            // one copy per session (stored locally), in case something goes wrong
            try? FileManager.default.createDirectory(at: Self.localDirectory, withIntermediateDirectories: true)
            let backup = Self.localDirectory.appendingPathComponent("foglietti.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            backedUp = true
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastWritten = data
            knownModDate = modDate()
        } catch {
            NSLog("Foglietti: save failed: \(error)")
        }
    }

    /// Moves the storage (e.g. to iCloud Drive). If notes are already there, they are merged.
    func moveData(to newDirectory: URL) {
        NotesManager.shared.flushAll()
        saveNow(skipMerge: true)
        directory = newDirectory
        try? FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        knownModDate = nil
        lastWritten = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            mergeFromDisk()
        }
        saveNow(skipMerge: true)
        UserDefaults.standard.set(newDirectory.path, forKey: Self.locationKey)
    }

    // MARK: Note access

    func index(_ id: UUID) -> Int? { notes.firstIndex { $0.id == id } }
    func note(_ id: UUID) -> Note? { index(id).map { notes[$0] } }

    func update(_ id: UUID, _ body: (inout Note) -> Void) {
        guard let i = index(id) else { return }
        var n = notes[i]
        body(&n)
        if n != notes[i] { notes[i] = n }
    }

    func delete(_ id: UUID) {
        tombstones[id] = Date()
        notes.removeAll { $0.id == id }
    }

    func theme(_ id: UUID?) -> Theme? { themes.first { $0.id == id } }

    func styleForNewNote() -> NoteStyle {
        if settings.randomTheme, let t = themes.randomElement() { return t.style }
        return theme(settings.defaultThemeID)?.style ?? themes.first?.style ?? NoteStyle()
    }

    @discardableResult
    func saveTheme(named name: String, style: NoteStyle) -> Theme {
        let t = Theme(name: name.isEmpty ? L("Theme %ld", themes.count + 1) : name, style: style)
        themes.append(t)
        return t
    }
}
