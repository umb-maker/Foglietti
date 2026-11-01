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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
