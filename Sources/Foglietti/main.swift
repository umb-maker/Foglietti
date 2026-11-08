import AppKit
import ServiceManagement

let args = CommandLine.arguments

// Try the assistant from the terminal (read-only unless the question asks to create something):
// Foglietti --ask "question"
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

// Login-item status (for checks from the terminal):  Foglietti --login-status
if args.contains("--login-status") {
    let st = SMAppService.mainApp.status
    print(["notRegistered", "enabled", "requiresApproval", "notFound"][min(st.rawValue, 3)])
    exit(0)
}

// Headless check of protected-note encryption, only on a separate data folder:
//   Foglietti --data-dir /tmp/x --vault-selftest
if args.contains("--vault-selftest"), args.contains("--data-dir") {
    MainActor.assumeIsolated {
        let store = NoteStore.shared, vault = Vault.shared
        func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
        let secret = "Bank PIN 4711 — top secret"
        var n = Note()
        n.setText(NSAttributedString(string: secret))
        store.notes = [n]
        try! vault.setUp(password: "correct horse", useTouchID: nil)
        store.update(n.id) { try? $0.protect() }
        store.saveNow(skipMerge: true)
        let file = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        check(!file.contains("4711") && !file.contains("top secret"), "secret text is not in the data file")
        check(store.note(n.id)?.plainText == "" && store.note(n.id)?.isProtected == true, "note keeps no plain text")
        vault.lock()
        check(store.note(n.id)?.readable == nil, "locked note can't be read")
        check(!vault.unlock(password: "wrong"), "wrong password is rejected")
        check(vault.unlock(password: "correct horse"), "right password unlocks")
        check(store.note(n.id)?.readable?.plainText == secret, "unlocked note reads back intact")
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
