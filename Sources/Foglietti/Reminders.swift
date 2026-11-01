import AppKit
import UserNotifications

/// Reminders: at the set time the note reopens in front and a notification arrives.
/// A periodic check covers the case where notifications are off or the Mac was asleep.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    private var timer: Timer?
    private var store: NoteStore { NoteStore.shared }
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.notes.forEach { reschedule($0.id) }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in Reminders.shared.fireDue() }
        }
        fireDue()
    }

    func set(_ id: UUID, at date: Date?) {
        store.update(id) { $0.reminder = date }
        reschedule(id)
    }

    func reschedule(_ id: UUID) {
        center?.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        guard let n = store.note(id), let date = n.reminder, date > Date(), !n.isTrashed else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Reminder")
        content.body = n.title
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let req = UNNotificationRequest(identifier: id.uuidString, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        center?.add(req)
    }

    func fireDue() {
        let now = Date()
        for n in store.notes where !n.isTrashed && (n.reminder ?? .distantFuture) <= now { fire(n.id) }
    }

    private func fire(_ id: UUID) {
        guard store.note(id)?.reminder != nil else { return }
        store.update(id) { $0.reminder = nil; $0.collapsed = false }
        NotesManager.shared.show(id, focus: true)
        NSApp.requestUserAttention(.informationalRequest)
        if let w = NotesManager.shared.controllers[id]?.window { shake(w) }
    }

    /// A little shake to get the note noticed.
    private func shake(_ w: NSWindow) {
        let f = w.frame
        let anim = CAKeyframeAnimation()
        let path = CGMutablePath()
        path.move(to: f.origin)
        for i in 0..<6 { path.addLine(to: CGPoint(x: f.minX + (i.isMultiple(of: 2) ? 8 : -8), y: f.minY)) }
        path.addLine(to: f.origin)
        anim.path = path
        anim.duration = 0.45
        w.animations = ["frameOrigin": anim]
        w.animator().setFrameOrigin(f.origin)
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = UUID(uuidString: notification.request.identifier)
        Task { @MainActor in if let id { Reminders.shared.fire(id) } }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = UUID(uuidString: response.notification.request.identifier)
        Task { @MainActor in
            if let id {
                Reminders.shared.fire(id)
                NotesManager.shared.controllers[id]?.show(focus: true)
            }
        }
        completionHandler()
    }

    // MARK: Quick choices

    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func presets(now: Date = Date()) -> [(String, Date)] {
        let cal = Calendar.current
        func at(_ day: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day)! }
        var out: [(String, Date)] = [
            (L("In 30 minutes"), now.addingTimeInterval(30 * 60)),
            (L("In 1 hour"), now.addingTimeInterval(3600)),
            (L("In 3 hours"), now.addingTimeInterval(3 * 3600)),
        ]
        if at(now, 18) > now.addingTimeInterval(3600) { out.append((L("This evening at 6 PM"), at(now, 18))) }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        out.append((L("Tomorrow at 9 AM"), at(tomorrow, 9)))
        if let monday = cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) {
            out.append((L("Monday at 9 AM"), at(monday, 9)))
        }
        return out
    }

    static func askDate(initial: Date?) -> Date? {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = Date()
        picker.dateValue = initial ?? Date().addingTimeInterval(3600)
        picker.sizeToFit()
        let a = NSAlert()
        a.messageText = L("When should I remind you of this note?")
        a.accessoryView = picker
        a.addButton(withTitle: L("Set"))
        a.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? picker.dateValue : nil
    }
}
