import Foundation
import FoundationModels

/// AI action that can be applied to a note's text.
struct AIAction: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var prompt: String
    var symbol = "sparkles"

    static let builtIns: [AIAction] = [
        .init(name: L("Summarize"), prompt: L("Summarize the text in a few lines, keeping the important details (dates, names, figures)."), symbol: "text.append"),
        .init(name: L("Proofread"), prompt: L("Fix spelling, grammar and punctuation. Do not change the meaning or the style. Return only the corrected text."), symbol: "checkmark.seal"),
        .init(name: L("Make clearer"), prompt: L("Rewrite the text more clearly and in a tidier order, without losing information."), symbol: "wand.and.stars"),
        .init(name: L("Formal tone"), prompt: L("Rewrite the text in a formal, professional tone."), symbol: "briefcase"),
        .init(name: L("Friendly tone"), prompt: L("Rewrite the text in a friendly, informal tone."), symbol: "face.smiling"),
        .init(name: L("Make a checklist"), prompt: L("Turn the text into a to-do list: one item per line, each line starting with \"☐ \". Nothing else."), symbol: "checklist"),
        .init(name: L("Translate to English"), prompt: L("Translate the text into English. Return only the translation."), symbol: "globe"),
        .init(name: L("Translate to Italian"), prompt: L("Translate the text into Italian. Return only the translation."), symbol: "globe.europe.africa"),
        .init(name: L("Keep writing"), prompt: L("Continue the text with 2–4 consistent sentences in the same style. Return only the continuation."), symbol: "text.cursor"),
    ]
}

/// Engine built on the Apple Intelligence model that runs on the Mac: no keys, no costs,
/// and the text never leaves the computer.
@available(macOS 26.0, *)
enum AIEngine {
    static let maxChars = 6000   // the on-device model has a small context window

    enum Status { case ready, notEligible, notEnabled, notReady, unknown }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .notReady
        default: return .unknown
        }
    }

    /// Runs an action on the text, streaming the result as it is generated.
    static func run(_ action: AIAction, on text: String) -> AsyncThrowingStream<String, Error> {
        let session = LanguageModelSession(instructions: """
        You are the assistant of a sticky-notes app. Carry out the instruction on the given text exactly.
        Reply in the same language as the text, unless the instruction asks for a translation.
        Return only the result, with no preamble, comments or quotes.
        """)
        let prompt = "Instruction: \(action.prompt)\n\nText:\n\(String(text.prefix(maxChars)))"
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await snap in session.streamResponse(to: prompt) { cont.yield(snap.content) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Reminders

    struct FoundReminder { let date: Date; let what: String }

    /// Explicit calendar of the coming days: the on-device model gets "tomorrow", "Thursday"… arithmetic wrong.
    static func calendarText(now: Date = Date()) -> String {
        let cal = Calendar.current
        let en = DateFormatter(); en.locale = Locale(identifier: "en_US_POSIX"); en.dateFormat = "EEEE"
        let local = DateFormatter(); local.locale = .current; local.dateFormat = "EEEE"
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        // weekday in English plus the user's language, so "giovedì" or "jeudi" map just as well as "Thursday"
        func weekday(_ d: Date) -> String {
            let a = en.string(from: d), b = local.string(from: d)
            return a.lowercased() == b.lowercased() ? a : "\(a) (\(b))"
        }
        var lines = ["Calendar:", "today = \(weekday(now)) \(iso.string(from: now)) (current time \(time.string(from: now)))"]
        for i in 1...13 {
            let d = cal.date(byAdding: .day, value: i, to: now)!
            let label = i == 1 ? "tomorrow" : i == 2 ? "the day after tomorrow" : (i > 7 ? "next week's " : "") + weekday(d)
            lines.append("\(label) = \(weekday(d)) \(iso.string(from: d))")
        }
        return lines.joined(separator: "\n")
    }

    static func parse(day: String, time: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day.trimmingCharacters(in: .whitespaces)) \(time.trimmingCharacters(in: .whitespaces))")
    }

    static func extractReminder(from text: String) async throws -> FoundReminder? {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Reminder", properties: [
            .init(name: "found", description: "true only if the text mentions a day or a time", schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: "day", description: "a date from the calendar, format yyyy-MM-dd", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "time", description: "HH:mm; 09:00 if no time is given", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "what", description: "the thing to remember, short", schema: DynamicGenerationSchema(type: String.self)),
        ]), dependencies: [])
        let session = LanguageModelSession(instructions: "Extract the first dated commitment from a text. Use ONLY the dates in the calendar provided.")
        let r = try await session.respond(to: "\(calendarText())\n\nText:\n\(String(text.prefix(maxChars)))", schema: schema)
        let c = r.content
        guard (try? c.value(Bool.self, forProperty: "found")) == true,
              let day = try? c.value(String.self, forProperty: "day"),
              let time = try? c.value(String.self, forProperty: "time"),
              let date = parse(day: day, time: time), date > Date() else { return nil }
        return FoundReminder(date: date, what: (try? c.value(String.self, forProperty: "what")) ?? "")
    }

    // MARK: Assistant

    /// Words that don't help the search.
    private static let stopwords: Set<String> = [
        // English
        "what", "which", "where", "when", "does", "about", "notes", "note", "say", "says", "tell", "show", "find",
        "have", "this", "that", "with", "from", "there", "written", "wrote",
        // Italian
        "quali", "quale", "quello", "quella", "sulle", "delle", "della", "dello", "nelle", "nella", "cosa", "dove",
        "come", "quando", "nota", "dicono", "parlano", "scritto", "devo", "fare", "questa", "questo", "sono",
        "hanno", "anche", "trova", "cerca", "dimmi", "mostra",
    ]

    /// Notes containing the words of the question: I hand them straight to the model, which on its own
    /// doesn't always remember to search.
    @MainActor static func relevantNotes(for question: String, limit: Int = 4) -> [Note] {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
        let notes = NoteStore.shared.notes.filter { !$0.isTrashed }
        guard !words.isEmpty else { return [] }
        return notes.map { n -> (Note, Int) in
            let t = n.plainText.lowercased()
            return (n, words.reduce(0) { $0 + (t.contains($1) ? 1 : 0) })
        }
        .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func ask(_ question: String) async throws -> String {
        let (titles, context) = await MainActor.run { () -> (String, String) in
            let titles = NoteStore.shared.notes.filter(\.isActive).prefix(30).map { "- \($0.title)" }.joined(separator: "\n")
            let found = relevantNotes(for: question)
            let context = found.map { "Note \"\($0.title)\":\n\($0.plainText.prefix(700))" }.joined(separator: "\n---\n")
            return (titles, context)
        }

        // 1. the model decides what to do (structured output: more reliable than tool calling on a small model)
        let str = DynamicGenerationSchema(type: String.self)
        let plan = try GenerationSchema(root: DynamicGenerationSchema(name: "Plan", properties: [
            .init(name: "action", description: "create_note if the user asks to remember, jot down, note or create something; remind_existing if they want a reminder on a note that already exists; list_reminders if they ask which reminders or commitments they have; answer for every question about the content of the notes",
                  schema: DynamicGenerationSchema(name: "Action", anyOf: ["create_note", "remind_existing", "list_reminders", "answer"])),
            .init(name: "text", description: "for create_note: the full text of the note, first line as a short title", schema: str, isOptional: true),
            .init(name: "note", description: "for remind_existing: title of the existing note", schema: str, isOptional: true),
            .init(name: "day", description: "due date yyyy-MM-dd taken from the calendar, if given", schema: str, isOptional: true),
            .init(name: "time", description: "time HH:mm, if given", schema: str, isOptional: true),
        ]), dependencies: [])
        // the small model sometimes drifts to another language: name the request's language explicitly
        let language = Translator.detect(question).flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) } ?? "the language of the request"
        let planner = LanguageModelSession(instructions: """
        You interpret requests made to Foglietti, a sticky-notes app. Pick the right action and fill in the fields.
        Use ONLY the dates in the calendar. Write any note text in \(language).
        \(calendarText())
        Titles of the existing notes:
        \(titles.isEmpty ? "(none)" : titles)
        """)
        let p = try await planner.respond(to: "Request: \(question)", schema: plan).content
        func field(_ k: String) -> String? {
            guard let v = (try? p.value(String?.self, forProperty: k)) ?? nil, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }
        let action = (try? p.value(String.self, forProperty: "action")) ?? "answer"
        let date: Date? = field("day").flatMap { parse(day: $0, time: field("time") ?? "09:00") }.flatMap { $0 > Date() ? $0 : nil }

        // 2. the app carries out the action
        switch action {
        case "create_note":
            let text = field("text") ?? question
            return await MainActor.run {
                let id = NotesManager.shared.newNote(text: text)
                if let date { Reminders.shared.set(id, at: date) }
                let title = NoteStore.shared.note(id)?.title ?? text
                return date.map { L("✅ Created the note “%@” with a reminder %@.", title, Reminders.label($0)) }
                    ?? L("✅ Created the note “%@”.", title)
            }
        case "remind_existing":
            guard let date else { return L("I didn't understand when to set the reminder: please give a day and a time.") }
            let target = field("note") ?? question
            return await MainActor.run {
                guard let n = relevantNotes(for: target, limit: 1).first ?? relevantNotes(for: question, limit: 1).first else {
                    return L("I couldn't find a note matching “%@”.", target)
                }
                Reminders.shared.set(n.id, at: date)
                return L("🔔 Reminder set on the note “%@” %@.", n.title, Reminders.label(date))
            }
        case "list_reminders":
            return await MainActor.run {
                let items = NoteStore.shared.notes.compactMap { n in n.reminder.map { (n, $0) } }.sorted { $0.1 < $1.1 }
                guard !items.isEmpty else { return L("You have no upcoming reminders.") }
                return items.map { "🔔 \(Reminders.label($0.1)) — \($0.0.title)" }.joined(separator: "\n")
            }
        default:
            let answerer = LanguageModelSession(instructions: """
            Answer in the same language as the question, briefly and concretely, based ONLY on the notes provided.
            Mention the titles of the notes you used. If the notes don't contain the answer, say so clearly without making anything up.
            \(calendarText())
            """)
            let prompt = context.isEmpty
                ? "No relevant notes. Available titles:\n\(titles)\n\nQuestion: \(question)"
                : "Notes:\n\(context)\n\nQuestion: \(question)"
            return try await answerer.respond(to: prompt).content
        }
    }
}
