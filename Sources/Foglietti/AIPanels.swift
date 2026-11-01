import AppKit
import SwiftUI

// MARK: - Shared state

enum AIAvailability {
    /// nil if the AI can be used, otherwise the reason to show the user.
    @MainActor static var problem: String? {
        guard #available(macOS 26.0, *) else { return L("Requires macOS 26 or later.") }
        switch AIEngine.status {
        case .ready: return nil
        case .notEligible: return L("This Mac doesn't support Apple Intelligence.")
        case .notEnabled: return L("Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri.")
        case .notReady: return L("The Apple Intelligence model is still downloading. Try again in a few minutes.")
        case .unknown: return L("Apple Intelligence isn't available right now.")
        }
    }

    static func message(for error: Error) -> String {
        let text = "\(error)"
        if text.contains("exceededContextWindowSize") { return L("The note is too long for the on-device model: select part of the text and try again.") }
        if text.contains("guardrailViolation") { return L("Apple Intelligence declined this content.") }
        if text.contains("unsupportedLanguageOrLocale") { return L("Language not supported by the on-device model.") }
        return L("Error: %@", error.localizedDescription)
    }
}

// MARK: - Result of an action on a note

@MainActor
final class AIRun: ObservableObject {
    @Published var text = ""
    @Published var running = true
    @Published var error: String?
    let title: String
    let onSelection: Bool
    var task: Task<Void, Never>?

    init(title: String, onSelection: Bool) {
        self.title = title
        self.onSelection = onSelection
    }
}

struct AIResultView: View {
    @ObservedObject var run: AIRun
    let replace: () -> Void
    let append: () -> Void
    let newNote: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(run.title).font(.headline)
                Spacer()
                if run.running { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(run.text.isEmpty && run.running ? L("Thinking…") : run.text)
                    .textSelection(.enabled)
                    .foregroundStyle(run.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 120)
            if let e = run.error { Text(e).font(.callout).foregroundStyle(.red) }
            HStack {
                Text(L("Apple Intelligence · on your Mac")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.text, forType: .string)
                }
                Button(L("New note"), action: newNote)
                Button(L("Add below"), action: append)
                Button(run.onSelection ? L("Replace selection") : L("Replace text"), action: replace)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(run.running || run.text.isEmpty)
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 240)
        .onExitCommand(perform: close)
    }
}

// MARK: - "Ask Foglietti"

@MainActor
final class AskModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var running = false
    @Published var history: [(String, String)] = []
}

struct AskView: View {
    @ObservedObject var model: AskModel
    let submit: () -> Void
    @FocusState private var focused: Bool

    private let examples = [L("Remind me tomorrow at 9 to pay the bill"), L("What do I have to do this week?"), L("Where did I write the wifi password?"), L("Make a shopping list for a carbonara")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.purple)
                TextField(L("Ask, or ask me to do something…"), text: $model.question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(submit)
                    .disabled(model.running)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onChange(of: model.running) { _, running in if !running { focused = true } }
                if model.running { ProgressView().controlSize(.small) }
            }
            if model.history.isEmpty && model.answer.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Examples")).font(.caption).foregroundStyle(.secondary)
                    ForEach(examples, id: \.self) { e in
                        Button(e) { model.question = e; submit() }.buttonStyle(.link).font(.callout)
                    }
                }
            }
            if !model.history.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.history.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(h.0).font(.callout).fontWeight(.semibold)
                                Text(h.1).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            Text(L("Apple Intelligence · everything stays on your Mac")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// Floating panel that closes with Esc.
final class AIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class AskController {
    static let shared = AskController()
    private var panel: AIPanel?
    private let model = AskModel()

    func show() {
        if panel == nil {
            let p = AIPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: AskView(model: model) { [weak self] in self?.submit() })
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            if let s = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: s.midX - 280, y: s.maxY - s.height * 0.22)) }
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // put the cursor in the text field even when the panel was already open
        if let field = panel?.contentView?.firstDescendant(ofType: NSTextField.self) { panel?.makeFirstResponder(field) }
    }

    private func submit() {
        let q = model.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.running else { return }
        if let problem = AIAvailability.problem {
            model.history.append((q, problem)); model.question = ""; return
        }
        guard #available(macOS 26.0, *) else { return }
        model.running = true
        Task { @MainActor in
            let answer: String
            do { answer = try await AIEngine.ask(q) } catch { answer = AIAvailability.message(for: error) }
            model.history.append((q, answer))
            if model.history.count > 8 { model.history.removeFirst() }
            model.question = ""
            model.running = false
        }
    }
}

extension NSView {
    func firstDescendant<T: NSView>(ofType: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstDescendant(ofType: T.self) { return t }
        }
        return nil
    }
}
