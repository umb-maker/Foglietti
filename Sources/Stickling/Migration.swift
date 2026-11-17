import Foundation
import Security

/// One-time move from the app's previous name (Foglietti, up to version 1.5) to Stickling.
/// Old files are copied, never deleted, so the previous version keeps working if someone goes back to it.
enum LegacyMigration {
    static let oldBundleID = "com.umbertocaputo.foglietti"
    static let oldName = "Foglietti"
    private static let doneKey = "legacyMigrationDone"
    /// Set when notes came over from the old name: the welcome window says so.
    static let migratedKey = "migratedFromLegacyName"

    /// Copies a folder's old data file and backup to the new file names, unless the new ones exist.
    @discardableResult
    static func renameFiles(in dir: URL) -> Bool {
        let fm = FileManager.default
        let pairs = [("foglietti.json", "stickling.json"), ("foglietti.backup.json", "stickling.backup.json")]
        var copied = false
        for (old, new) in pairs {
            let src = dir.appendingPathComponent(old), dst = dir.appendingPathComponent(new)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            if (try? fm.copyItem(at: src, to: dst)) != nil { copied = true }
        }
        return copied
    }

    /// Copies an old data folder (with renamed files) into the new one if the new one has no notes yet.
    @discardableResult
    static func copyFolder(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        let oldFile = old.appendingPathComponent("foglietti.json")
        if !fm.fileExists(atPath: oldFile.path), fm.fileExists(atPath: old.appendingPathComponent(".foglietti.json.icloud").path) {
            // iCloud Drive evicted the file to save space: bring it back before copying (up to 30 s)
            try? fm.startDownloadingUbiquitousItem(at: oldFile)
            for _ in 0..<60 where !fm.fileExists(atPath: oldFile.path) { Thread.sleep(forTimeInterval: 0.5) }
        }
        guard fm.fileExists(atPath: oldFile.path),
              !fm.fileExists(atPath: new.appendingPathComponent("stickling.json").path) else { return false }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        var copied = false
        for (o, n) in [("foglietti.json", "stickling.json"), ("foglietti.backup.json", "stickling.backup.json")] {
            let src = old.appendingPathComponent(o)
            guard fm.fileExists(atPath: src.path) else { continue }
            if (try? fm.copyItem(at: src, to: new.appendingPathComponent(n))) != nil { copied = true }
        }
        return copied
    }

    /// Runs at launch before the store loads. Skipped with --data-dir (tests and demos use their own folder).
    /// The folders are parameters only so the self-test can run on a copy.
    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard, test: Bool = false,
                            support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                            local: URL = NoteStore.localDirectory,
                            iCloudRoot: URL = NoteStore.iCloudRoot,
                            oldPreferences: [String: Any]? = nil) {
        guard !defaults.bool(forKey: doneKey), test || !CommandLine.arguments.contains("--data-dir") else { return }
        var migrated = false

        // 1. Preferences: everything except the "welcome shown" flag, so the welcome window
        //    comes back to turn notifications and open-at-login on again for the new name.
        let old = oldPreferences ?? defaults.persistentDomain(forName: oldBundleID) ?? [:]
        let skip: Set<String> = ["welcomeShown", "launchAtLoginConfigured", "lastUpdateCheck"]
        for (key, value) in old where !skip.contains(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }

        // 2. The data folder: local, iCloud Drive, or a folder the user picked.
        migrated = copyFolder(from: support.appendingPathComponent(oldName), to: local) || migrated
        if let saved = defaults.string(forKey: "dataDirectory") {
            let dir = URL(fileURLWithPath: saved, isDirectory: true).standardizedFileURL
            let oldICloud = iCloudRoot.appendingPathComponent(oldName, isDirectory: true).standardizedFileURL
            let newICloud = iCloudRoot.appendingPathComponent("Stickling", isDirectory: true)
            if dir == oldICloud {
                migrated = copyFolder(from: dir, to: newICloud) || migrated
                // switch only when the notes made it across; otherwise stay put and try again next launch
                guard FileManager.default.fileExists(atPath: newICloud.appendingPathComponent("stickling.json").path) else {
                    if migrated { defaults.set(true, forKey: migratedKey) }
                    return
                }
                defaults.set(newICloud.path, forKey: "dataDirectory")
            } else {
                migrated = renameFiles(in: dir) || migrated
            }
        }
        if migrated { defaults.set(true, forKey: migratedKey) }
        defaults.set(true, forKey: doneKey)
    }

    // MARK: Touch ID key

    private static let oldKeychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.umbertocaputo.foglietti.vault",
        kSecAttrAccount as String: "key",
    ]

    static var hasOldKeychainKey: Bool {
        var q = oldKeychainQuery
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the key saved by the old version (macOS may ask once to allow it), then removes the old item.
    /// Called only after Touch ID succeeded, and the caller verifies the key before using it.
    static func takeOldKeychainKey() -> Data? {
        var q = oldKeychainQuery
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return d
    }

    static func deleteOldKeychainKey() { SecItemDelete(oldKeychainQuery as CFDictionary) }
}
