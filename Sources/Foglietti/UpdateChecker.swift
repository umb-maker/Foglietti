import AppKit

/// Checks GitHub Releases for a newer version: at launch and once a day, or on request.
/// It only reads public release data; nothing is downloaded or installed automatically.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repository = "umb-maker/Foglietti"

    private var timer: Timer?
    private var lastCheckKey = "lastUpdateCheck"
    private var store: NoteStore { NoteStore.shared }

    struct Release { let version: String; let url: URL; let notes: String }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func start() {
        // first check shortly after launch, then once a day
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard store.settings.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        Task { @MainActor in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let release = await fetchLatest()
            guard let release else {
                if manual { NSAlert.simple(L("Couldn't check for updates."), info: L("Check your internet connection and try again.")) }
                return
            }
            guard Self.isNewer(release.version, than: currentVersion) else {
                if manual { NSAlert.simple(L("Foglietti is up to date."), info: L("You have version %@, the latest one.", currentVersion)) }
                return
            }
            if !manual && store.settings.skippedVersion == release.version { return }
            present(release)
        }
    }

    private func fetchLatest() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, url: page, notes: json["body"] as? String ?? "")
    }

    /// Compares dotted versions numerically: 1.10.0 is newer than 1.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func present(_ r: Release) {
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = L("Foglietti %@ is available", r.version)
        a.informativeText = L("You have version %@.", currentVersion) + "\n\n" + Self.summary(r.notes)
        a.addButton(withTitle: L("Download"))
        a.addButton(withTitle: L("Later"))
        a.addButton(withTitle: L("Skip This Version"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.url)
        case .alertThirdButtonReturn: store.settings.skippedVersion = r.version
        default: break
        }
    }

    /// First lines of the release notes, without Markdown symbols.
    private static func summary(_ md: String) -> String {
        let lines = md.split(separator: "\n").map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.prefix(6).joined(separator: "\n")
    }
}
