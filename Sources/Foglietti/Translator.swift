import SwiftUI
import AppKit
import NaturalLanguage
import Translation

/// Translation with Apple Translate: a dedicated engine that runs on the Mac and works offline once languages are downloaded.
enum Translator {
    /// Languages offered in the menus (BCP-47 codes).
    static let languages: [String] = ["en", "it", "es", "fr", "de", "pt-BR", "nl", "pl", "ru", "uk", "tr",
                                      "ar", "hi", "zh-Hans", "zh-Hant", "ja", "ko", "th", "vi", "id"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized ?? code
    }

    static func flag(_ code: String) -> String {
        let map = ["en": "🇬🇧", "it": "🇮🇹", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪", "pt-BR": "🇧🇷", "nl": "🇳🇱", "pl": "🇵🇱",
                   "ru": "🇷🇺", "uk": "🇺🇦", "tr": "🇹🇷", "ar": "🇸🇦", "hi": "🇮🇳", "zh-Hans": "🇨🇳", "zh-Hant": "🇹🇼",
                   "ja": "🇯🇵", "ko": "🇰🇷", "th": "🇹🇭", "vi": "🇻🇳", "id": "🇮🇩"]
        return map[code] ?? "🌐"
    }

    /// Language of the text, detected on the Mac.
    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2000)))
        guard let lang = r.dominantLanguage else { return nil }
        switch lang {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .portuguese: return "pt-BR"
        default: return lang.rawValue
        }
    }

    /// Target language for ⌥⌘T: the first preferred one that differs from the text's.
    static func defaultTarget(for text: String, preferred: [String]) -> String {
        let src = detect(text)
        return preferred.first { $0.split(separator: "-").first.map(String.init) != src?.split(separator: "-").first.map(String.init) }
            ?? preferred.first ?? "en"
    }
}

@MainActor
final class TranslateRun: ObservableObject {
    @Published var text = ""
    @Published var running = true
    @Published var error: String?
    @Published var target: String
    let source: String
    let sourceLanguage: String?
    let onSelection: Bool

    init(source: String, target: String, onSelection: Bool) {
        self.source = source
        self.target = target
        self.onSelection = onSelection
        self.sourceLanguage = Translator.detect(source)
    }
}

@available(macOS 15.0, *)
struct TranslateView: View {
    @ObservedObject var run: TranslateRun
    let replace: () -> Void
    let append: () -> Void
    let newNote: () -> Void
    let close: () -> Void
    @Local private var config: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe").foregroundStyle(.blue)
                Text(run.sourceLanguage.map { "\(Translator.flag($0)) \(Translator.name($0))" } ?? L("Detected language"))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: $run.target) {
                    ForEach(Translator.languages, id: \.self) { Text("\(Translator.flag($0)) \(Translator.name($0))").tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
                Spacer()
                if run.running { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(run.text.isEmpty && run.running ? L("Translating…") : run.text)
                    .textSelection(.enabled)
                    .foregroundStyle(run.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 120)
            if let e = run.error { Text(e).font(.callout).foregroundStyle(.red) }
            HStack {
                Text(L("Apple Translate · on your Mac")).font(.caption2).foregroundStyle(.secondary)
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
        .frame(minWidth: 480, minHeight: 240)
        .onExitCommand(perform: close)
        .onAppear { restart() }
        .onChange(of: run.target) { _, _ in restart() }
        // the system downloads missing languages (asking first), then hands the session over here
        .translationTask(config) { session in
            do {
                let r = try await session.translate(run.source)
                run.text = r.targetText
            } catch {
                run.error = L("Translation failed: %@", error.localizedDescription)
            }
            run.running = false
        }
    }

    private func restart() {
        run.text = ""
        run.error = nil
        run.running = true
        if let src = run.sourceLanguage, src.split(separator: "-").first == run.target.split(separator: "-").first {
            run.error = L("The text is already in %@: choose another language.", Translator.name(run.target))
            run.running = false
            return
        }
        let new = TranslationSession.Configuration(source: run.sourceLanguage.map { Locale.Language(identifier: $0) },
                                                   target: Locale.Language(identifier: run.target))
        if new == config { config?.invalidate() } else { config = new }
    }
}
