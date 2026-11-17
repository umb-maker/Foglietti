import AppKit
import ServiceManagement

let args = CommandLine.arguments

// Headless check of the move from the old name, on copies in a scratch folder:
//   Stickling --migration-selftest /tmp/x
if let i = args.firstIndex(of: "--migration-selftest"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let root = URL(fileURLWithPath: args[i + 1], isDirectory: true), fm = FileManager.default
        func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
        let support = root.appendingPathComponent("Support"), cloud = root.appendingPathComponent("CloudDocs")
        let oldLocal = support.appendingPathComponent("Foglietti"), oldCloud = cloud.appendingPathComponent("Foglietti")
        let newLocal = support.appendingPathComponent("Stickling"), newCloud = cloud.appendingPathComponent("Stickling")
        for d in [oldLocal, oldCloud] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try? Data("local".utf8).write(to: oldLocal.appendingPathComponent("foglietti.json"))
        try? Data("local backup".utf8).write(to: oldLocal.appendingPathComponent("foglietti.backup.json"))
        try? Data("cloud".utf8).write(to: oldCloud.appendingPathComponent("foglietti.json"))
        let suite = "com.umbertocaputo.stickling.migration-selftest"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let old: [String: Any] = ["dataDirectory": oldCloud.path, "welcomeShown": true, "recentEmoji": ["😀"]]
        LegacyMigration.runIfNeeded(defaults: d, test: true, support: support, local: newLocal, iCloudRoot: cloud, oldPreferences: old)
        let read = { (u: URL) in (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        check(read(newLocal.appendingPathComponent("stickling.json")) == "local", "local notes copied to the new name")
        check(read(newLocal.appendingPathComponent("stickling.backup.json")) == "local backup", "local backup copied")
        check(read(newCloud.appendingPathComponent("stickling.json")) == "cloud", "iCloud Drive notes copied")
        check(d.string(forKey: "dataDirectory") == newCloud.path, "iCloud Drive location points to the new folder")
        check(fm.fileExists(atPath: oldLocal.appendingPathComponent("foglietti.json").path), "old files are left in place")
        check(d.stringArray(forKey: "recentEmoji") == ["😀"], "preferences carried over")
        check(!d.bool(forKey: "welcomeShown"), "welcome window shows again for permissions")
        check(d.bool(forKey: LegacyMigration.migratedKey), "welcome window knows about the rename")
        try? Data("changed".utf8).write(to: newLocal.appendingPathComponent("stickling.json"))
        d.set(false, forKey: "legacyMigrationDone")
        LegacyMigration.runIfNeeded(defaults: d, test: true, support: support, local: newLocal, iCloudRoot: cloud, oldPreferences: old)
        check(read(newLocal.appendingPathComponent("stickling.json")) == "changed", "a second run never overwrites newer notes")
        d.removePersistentDomain(forName: suite)
        exit(0)
    }
}

// first launch after the rename: bring notes and preferences over from the old name
MainActor.assumeIsolated { LegacyMigration.runIfNeeded() }

// Try the assistant from the terminal (read-only unless the question asks to create something):
// Stickling --ask "question"
if let i = args.firstIndex(of: "--ask"), i + 1 < args.count, #available(macOS 26.0, *) {
    let q = args[i + 1]
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do { print(try await AIEngine.ask(q)) } catch { print(AIAvailability.message(for: error)) }
        NoteStore.shared.saveNow()
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// Login-item status (for checks from the terminal):  Stickling --login-status
if args.contains("--login-status") {
    let st = SMAppService.mainApp.status
    print(["notRegistered", "enabled", "requiresApproval", "notFound"][min(st.rawValue, 3)])
    exit(0)
}

// Headless check of protected-note encryption, only on a separate data folder:
//   Stickling --data-dir /tmp/x --vault-selftest
if args.contains("--vault-selftest"), args.contains("--data-dir") {
    MainActor.assumeIsolated {
        let store = NoteStore.shared, vault = Vault.shared
        func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
        let secret = "Bank PIN 4711 — top secret"
        var n = Note()
        n.setText(NSAttributedString(string: secret))
        store.notes = [n]
        store.saveNow(skipMerge: true)
        // a session backup taken while the note was still in plain text
        try? FileManager.default.copyItem(at: store.fileURL, to: store.backupURL)
        try! vault.setUp(password: "correct horse", useTouchID: nil)
        store.update(n.id) { try? $0.protect() }
        store.rewriteBackup()
        let backup = (try? String(contentsOf: store.backupURL, encoding: .utf8)) ?? ""
        check(!backup.contains("4711"), "backup no longer holds the plain text after protecting")
        let file = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        check(!file.contains("4711") && !file.contains("top secret"), "secret text is not in the data file")
        check(store.note(n.id)?.plainText == "" && store.note(n.id)?.isProtected == true, "note keeps no plain text")
        vault.lock()
        check(store.note(n.id)?.readable == nil, "locked note can't be read")
        check(!vault.unlock(password: "wrong"), "wrong password is rejected")
        let realVault = store.vault
        store.vault?.rounds = 5
        check(!vault.unlock(password: "correct horse"), "tampered vault data is rejected")
        store.vault = realVault
        check(vault.unlock(password: "correct horse"), "right password unlocks")
        check(store.note(n.id)?.readable?.plainText == secret, "unlocked note reads back intact")
        // another Mac writes an older, unprotected copy with a newer date: protection must win
        store.saveNow(skipMerge: true)
        if var json = try? JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any],
           var notes = json["notes"] as? [[String: Any]] {
            notes[0]["cipher"] = nil
            notes[0]["plainText"] = secret
            notes[0]["modified"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            json["notes"] = notes
            Thread.sleep(forTimeInterval: 1.1)   // a different modification date on disk
            try? JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
            store.checkForExternalChanges()
        }
        check(store.note(n.id)?.isProtected == true, "an unprotected copy from another Mac doesn't replace the protected note")
        store.update(n.id) { try? $0.removeProtection() }
        check(store.note(n.id)?.plainText == secret && store.note(n.id)?.isProtected == false, "removing protection restores the text")
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
