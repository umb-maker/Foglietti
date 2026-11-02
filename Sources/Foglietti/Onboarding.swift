import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

/// Live state of what Foglietti may use. Nothing here is asked for until the user presses a button.
@MainActor
final class PermissionState: ObservableObject {
    enum Status { case granted, denied, notAsked, unavailable }

    @Published var notifications = Status.notAsked
    @Published var login = Status.notAsked
    @Published var screen = Status.notAsked
    @Published var ai = Status.notAsked

    func refresh() async {
        if Bundle.main.bundleIdentifier != nil {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notifications = .granted
            case .denied: notifications = .denied
            default: notifications = .notAsked
            }
        }
        switch SMAppService.mainApp.status {
        case .enabled: login = .granted
        case .requiresApproval: login = .denied
        default: login = .notAsked
        }
        screen = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        ai = AIAvailability.problem == nil ? .granted : .unavailable
    }

    // MARK: Actions

    func requestNotifications() {
        if notifications == .denied {
            let id = Bundle.main.bundleIdentifier ?? ""
            open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func enableLogin() {
        if login == .denied { SMAppService.openSystemSettingsLoginItems(); return }
        try? SMAppService.mainApp.register()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    func openAISettings() { open("x-apple.systempreferences:com.apple.Siri-Settings.extension") }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: NoteStore
    @StateObject private var state = PermissionState()
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Welcome to Foglietti")).font(.title).bold()
                    Text(L("Sticky notes you can shape any way you like. A few things work better with your permission: each one is optional, and you can change it later."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                PermissionRow(symbol: "bell.badge", title: L("Notifications"),
                              detail: L("So reminders reach you even when Foglietti is in the background."),
                              status: state.notifications, action: L("Allow"), perform: state.requestNotifications)
                Divider()
                PermissionRow(symbol: "power", title: L("Open at login"),
                              detail: L("Your notes come back after a restart. macOS will show a “Background item added” notice: that's this."),
                              status: state.login, action: L("Turn on"), perform: state.enableLogin)
                Divider()
                PermissionRow(symbol: "sparkles", title: L("Apple Intelligence"),
                              detail: state.ai == .granted
                                  ? L("Summaries, rewriting and Ask Foglietti run on your Mac. Nothing to allow.")
                                  : (AIAvailability.problem ?? ""),
                              status: state.ai, action: L("Open Settings"), perform: state.openAISettings)
                Divider()
                PermissionRow(symbol: "camera.viewfinder", title: L("Screen Recording (optional)"),
                              detail: L("Only to capture screenshots straight into a note with ⇧⌘I. Dragging or pasting images works without it."),
                              status: state.screen, action: L("Allow"), perform: state.requestScreen)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Pick a look for new notes")).font(.headline)
                HStack(spacing: 10) {
                    ForEach(store.themes.prefix(9)) { t in
                        let selected = store.settings.defaultThemeID == t.id
                        NotePreview(style: t.style, text: "")
                            .frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: t.style.cornerRadius).stroke(Color.accentColor, lineWidth: selected ? 3 : 0))
                            .onTapGesture { store.settings.defaultThemeID = t.id; store.settings.randomTheme = false }
                            .help(t.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Good to know")).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { Text("⌃⌥N").monospaced(); Text(L("new note, from any app")) }
                    GridRow { Text("⌃⌥Space").monospaced(); Text(L("Ask Foglietti, from any app")) }
                    GridRow { Text("🎨").monospaced(); Text(L("customize a note: colors, fonts, Liquid Glass")) }
                    GridRow { Text("🗒").monospaced(); Text(L("everything else is in the menu bar icon")) }
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button(L("Start using Foglietti"), action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task {
            // statuses change in System Settings: keep them current while the window is open
            while !Task.isCancelled {
                await state.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: PermissionState.Status
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.blue).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch status {
            case .granted:
                Label(L("Ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .denied:
                VStack(alignment: .trailing, spacing: 4) {
                    Label(L("Off"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button(L("Open Settings"), action: perform).controlSize(.small)
                }
            case .unavailable:
                Button(action, action: perform).controlSize(.small)
            case .notAsked:
                Button(action, action: perform)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Shows the welcome window on first launch (and from the Foglietti menu).
@MainActor
final class WelcomeController {
    static let shared = WelcomeController()
    private static let doneKey = "welcomeShown"
    private var window: NSWindow?

    var shouldShowAtLaunch: Bool { !UserDefaults.standard.bool(forKey: Self.doneKey) }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: WelcomeView { [weak self] in self?.finish() }.environmentObject(NoteStore.shared))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: WelcomeController.doneKey)
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}
