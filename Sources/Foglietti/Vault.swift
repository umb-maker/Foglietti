import AppKit
import CryptoKit
import CommonCrypto
import LocalAuthentication
import Security

/// Data that lets any Mac check the master password. Saved with the notes (and synced),
/// it contains no key: only the salt and a value encrypted with the key.
struct VaultInfo: Codable, Equatable {
    var salt: Data
    var rounds: Int
    var check: Data
    var updated = Date()
}

/// Content of a protected note, encrypted as a whole.
struct ProtectedPayload: Codable {
    var content: Data
    var plainText: String
}

/// The vault for protected notes: master password, AES-GCM encryption, Touch ID and auto-lock.
/// While locked the key exists nowhere in memory; protected notes are stored only encrypted.
@MainActor
final class Vault {
    static let shared = Vault()
    static let changed = Notification.Name("FogliettiVaultChanged")

    enum VaultError: LocalizedError {
        case notUnlocked, wrongPassword
        var errorDescription: String? {
            switch self {
            case .notUnlocked: L("Protected notes are locked.")
            case .wrongPassword: L("Wrong password.")
            }
        }
    }

    private(set) var key: SymmetricKey?
    var isUnlocked: Bool { key != nil }
    var isSetUp: Bool { store.vault != nil }
    private var store: NoteStore { NoteStore.shared }
    private var lastActivity = Date()
    private var timer: Timer?
    private static let checkText = Data("foglietti-vault-check".utf8)
    private static let rounds = 600_000

    // MARK: Lifecycle

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in Vault.shared.lockIfIdle() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Vault.shared.lock() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in Vault.shared.lock() }
        }
    }

    /// Any activity in a protected note postpones the auto-lock.
    func touch() { lastActivity = Date() }

    private func lockIfIdle() {
        let minutes = store.settings.vaultAutoLockMinutes
        guard isUnlocked, minutes > 0, Date().timeIntervalSince(lastActivity) > Double(minutes) * 60 else { return }
        lock()
    }

    func lock() {
        guard isUnlocked else { return }
        NotesManager.shared.flushAll()      // encrypt what is open before the key goes away
        key = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func didUnlock(_ k: SymmetricKey) {
        key = k
        touch()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Setup and passwords

    /// `useTouchID: nil` leaves the keychain untouched (used by the self-test).
    func setUp(password: String, useTouchID: Bool?) throws {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let k = Self.derive(password, salt: salt, rounds: Self.rounds)
        let check = try AES.GCM.seal(Self.checkText, using: k).combined!
        store.vault = VaultInfo(salt: salt, rounds: Self.rounds, check: check)
        if useTouchID == true { saveKeyInKeychain(k) } else if useTouchID == false { deleteKeyFromKeychain() }
        didUnlock(k)
    }

    @discardableResult
    func unlock(password: String) -> Bool {
        guard let v = store.vault else { return false }
        let k = Self.derive(password, salt: v.salt, rounds: v.rounds)
        guard Self.verify(k, v) else { return false }
        didUnlock(k)
        return true
    }

    /// Changes the master password and re-encrypts every protected note with the new key.
    func changePassword(old: String, new: String) throws {
        guard let v = store.vault else { return }
        let oldKey = Self.derive(old, salt: v.salt, rounds: v.rounds)
        guard Self.verify(oldKey, v) else { throw VaultError.wrongPassword }
        NotesManager.shared.flushAll()
        let payloads = store.notes.filter(\.isProtected).compactMap { n in try? (n.id, Self.open(n.cipher, oldKey)) }
        try setUp(password: new, useTouchID: hasKeyInKeychain)
        for (id, data) in payloads {
            if let sealed = try? seal(data) { store.update(id) { $0.cipher = sealed; $0.modified = Date() } }
        }
    }

    private static func verify(_ k: SymmetricKey, _ v: VaultInfo) -> Bool {
        (try? open(v.check, k)) == checkText
    }

    static func derive(_ password: String, salt: Data, rounds: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    // MARK: Encryption

    func seal(_ data: Data) throws -> Data {
        guard let key else { throw VaultError.notUnlocked }
        return try AES.GCM.seal(data, using: key).combined!
    }

    func open(_ data: Data?) throws -> Data {
        guard let key else { throw VaultError.notUnlocked }
        return try Self.open(data, key)
    }

    private static func open(_ data: Data?, _ k: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data ?? Data()), using: k)
    }

    // MARK: Touch ID (key kept in the login keychain, released after Touch ID)

    private let service = "com.umbertocaputo.foglietti.vault"
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "key"]
    }

    var hasKeyInKeychain: Bool {
        var q = keychainQuery
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    func saveKeyInKeychain(_ k: SymmetricKey? = nil) {
        guard let k = k ?? key else { return }
        deleteKeyFromKeychain()
        var q = keychainQuery
        q[kSecValueData as String] = k.withUnsafeBytes { Data($0) }
        q[kSecAttrLabel as String] = "Foglietti protected notes"
        SecItemAdd(q as CFDictionary, nil)
    }

    func deleteKeyFromKeychain() { SecItemDelete(keychainQuery as CFDictionary) }

    private func keyFromKeychain() -> SymmetricKey? {
        var q = keychainQuery
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return SymmetricKey(data: d)
    }

    static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: Unlock flow

    /// Unlocks if needed: Touch ID when the key is in the keychain, otherwise the master password.
    func ensureUnlocked(reason: String = L("unlock your protected notes")) async -> Bool {
        if isUnlocked { touch(); return true }
        guard isSetUp else { return false }
        if hasKeyInKeychain {
            let ctx = LAContext()
            ctx.localizedFallbackTitle = L("Use Master Password")
            if (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true,
               let k = keyFromKeychain(), let v = store.vault, Self.verify(k, v) {
                didUnlock(k)
                return true
            }
        }
        return askPassword()
    }

    private func askPassword() -> Bool {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let a = NSAlert()
        a.messageText = L("Enter the master password")
        a.informativeText = L("It unlocks the protected notes on this Mac.")
        a.accessoryView = field
        a.addButton(withTitle: L("Unlock"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        while a.runModal() == .alertFirstButtonReturn {
            if unlock(password: field.stringValue) {
                // a Mac that doesn't have the key yet (e.g. after sync) can start using Touch ID
                if store.settings.vaultTouchID, Self.touchIDAvailable, !hasKeyInKeychain { saveKeyInKeychain() }
                return true
            }
            a.informativeText = L("Wrong password. Try again.")
            field.stringValue = ""
        }
        return false
    }

    /// First-time setup: password twice, a clear warning that it can't be recovered.
    func runSetup() -> Bool {
        let p1 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        p1.placeholderString = L("Master password")
        p2.placeholderString = L("Repeat the password")
        let touch = NSButton(checkboxWithTitle: L("Unlock with Touch ID"), target: nil, action: nil)
        touch.state = Self.touchIDAvailable ? .on : .off
        touch.isEnabled = Self.touchIDAvailable
        let stack = NSStackView(views: [p1, p2, touch])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 84)
        let a = NSAlert()
        a.messageText = L("Create a master password")
        a.informativeText = L("It encrypts your protected notes. If you forget it, those notes can't be recovered by anyone, not even by restoring a backup.")
        a.accessoryView = stack
        a.addButton(withTitle: L("Create"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = p1
        NSApp.activate(ignoringOtherApps: true)
        while a.runModal() == .alertFirstButtonReturn {
            if p1.stringValue.count < 6 {
                a.informativeText = L("Use at least 6 characters.")
            } else if p1.stringValue != p2.stringValue {
                a.informativeText = L("The two passwords don't match.")
            } else {
                store.settings.vaultTouchID = touch.state == .on
                try? setUp(password: p1.stringValue, useTouchID: touch.state == .on)
                return true
            }
            p2.stringValue = ""
        }
        return false
    }
}

// MARK: - Protected notes

extension Note {
    var isProtected: Bool { cipher != nil }

    /// Encrypts the note's content; the readable copy is removed.
    @MainActor mutating func protect() throws {
        let payload = try JSONEncoder().encode(ProtectedPayload(content: content, plainText: plainText))
        cipher = try Vault.shared.seal(payload)
        content = Data()
        plainText = ""
    }

    @MainActor mutating func removeProtection() throws {
        let p = try decryptedPayload()
        content = p.content
        plainText = p.plainText
        cipher = nil
    }

    @MainActor func decryptedPayload() throws -> ProtectedPayload {
        try JSONDecoder().decode(ProtectedPayload.self, from: Vault.shared.open(cipher))
    }

    /// Readable copy (for sending or exporting): nil while the vault is locked.
    @MainActor var readable: Note? {
        guard isProtected else { return self }
        guard let p = try? decryptedPayload() else { return nil }
        var n = self
        n.content = p.content
        n.plainText = p.plainText
        n.cipher = nil
        return n
    }

    /// Saves new text into a protected note, encrypted.
    @MainActor mutating func setProtectedText(_ a: NSAttributedString) throws {
        var tmp = Note()
        tmp.setText(a)
        let payload = try JSONEncoder().encode(ProtectedPayload(content: tmp.content, plainText: tmp.plainText))
        cipher = try Vault.shared.seal(payload)
    }
}
