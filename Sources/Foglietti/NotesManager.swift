import AppKit

/// Keeps the open windows in line with the saved state of the notes.
@MainActor
final class NotesManager {
    static let shared = NotesManager()
    private(set) var controllers: [UUID: NoteWindowController] = [:]
    weak var lastActive: NoteWindowController?
    private var store: NoteStore { NoteStore.shared }

    func start() {
        store.onNotesChange = { [weak self] in self?.sync() }
        if !store.settings.showNotesAtLaunch {
            for n in store.notes where n.isOpen { store.update(n.id) { $0.isOpen = false } }
        }
        purgeTrash()
        sync()
    }

    func sync() {
        let wanted = Dictionary(uniqueKeysWithValues: store.notes.filter { $0.isOpen && $0.isActive }.map { ($0.id, $0) })
        for (id, c) in controllers where wanted[id] == nil {
            c.flush()
            c.window?.orderOut(nil)
            controllers[id] = nil
        }
        for (id, note) in wanted {
            if let c = controllers[id] {
                c.apply(note)
            } else {
                let c = NoteWindowController(note: note)
                controllers[id] = c
                c.show(focus: false)
            }
        }
    }

    func flushAll() { controllers.values.forEach { $0.flush() } }

    func show(_ id: UUID, focus: Bool) {
        store.update(id) { $0.isOpen = true; $0.archived = false; $0.trashedAt = nil }
        sync()
        controllers[id]?.show(focus: focus)
    }

    @discardableResult
    func newNote(text: String? = nil, styledText: ((NoteStyle) -> NSAttributedString)? = nil, size custom: CGSize? = nil, near: NoteWindowController? = nil) -> UUID {
        let s = store.settings
        var n = Note()
        n.style = store.styleForNewNote()
        n.floating = s.newNotesFloat
        let size = custom ?? CGSize(width: s.newNoteWidth, height: s.newNoteHeight)
        if let ref = (near ?? lastActive)?.window, ref.isVisible {
            n.frame = CGRect(origin: CGPoint(x: ref.frame.minX + 28, y: ref.frame.maxY - 28 - size.height), size: size)
        } else {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let k = CGFloat(controllers.count % 8) * 24
            n.frame = CGRect(x: screen.midX - size.width / 2 + k, y: screen.midY - size.height / 2 - k, width: size.width, height: size.height)
        }
        if let text { n.setText(NSAttributedString(string: text, attributes: n.style.typingAttributes)) }
        if let styledText { n.setText(styledText(n.style)) }
        store.notes.append(n)
        show(n.id, focus: true)
        return n.id
    }

    func showAll() {
        for n in store.notes where n.isActive { store.update(n.id) { $0.isOpen = true } }
        sync()
        NSApp.activate(ignoringOtherApps: true)
        controllers.values.forEach { $0.show(focus: false) }
    }

    func unpinAll() {
        for n in store.notes where n.floating { store.update(n.id) { $0.floating = false } }
    }

    func hideAll() {
        flushAll()
        for n in store.notes where n.isOpen { store.update(n.id) { $0.isOpen = false } }
    }

    // MARK: Trash

    /// Deleting is reversible: the note goes to the trash and is really removed only after `trashDays` days.
    func moveToTrash(_ ids: [UUID]) {
        for id in ids {
            controllers[id]?.flush()
            store.update(id) { $0.trashedAt = Date(); $0.isOpen = false; $0.modified = Date(); $0.reminder = nil }
            Reminders.shared.reschedule(id)
        }
    }

    func restore(_ ids: [UUID]) {
        for id in ids { store.update(id) { $0.trashedAt = nil; $0.modified = Date() } }
    }

    func deletePermanently(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if store.settings.confirmDelete {
            let a = NSAlert()
            a.messageText = ids.count == 1 ? L("Delete this note permanently?") : L("Delete %ld notes permanently?", ids.count)
            a.informativeText = L("You won't be able to recover them.")
            a.addButton(withTitle: L("Delete"))
            a.addButton(withTitle: L("Cancel"))
            a.buttons[0].hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        for id in ids { store.delete(id) }
    }

    func emptyTrash() { deletePermanently(store.notes.filter(\.isTrashed).map(\.id)) }

    func purgeTrash() {
        let limit = Date().addingTimeInterval(-Double(max(1, store.settings.trashDays)) * 86_400)
        for n in store.notes where (n.trashedAt ?? .distantFuture) < limit { store.delete(n.id) }
    }
}
