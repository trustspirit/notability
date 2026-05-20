import Foundation
import Security

// File-based credentials store at ~/Library/Application Support/Notability/credentials/.
// Files are written with POSIX mode 0600 (owner read/write only).
//
// Why not Keychain? With ad-hoc code signing, each release build has a different
// CDHash and therefore a different Keychain ACL identity. After every update,
// macOS either prompts the user with a hard-to-notice "Notability wants to
// access keychain item" dialog or returns errSecAuthFailed, which manifests as
// "settings disappeared." This store sidesteps that by keying off the user's
// login session (file ownership) rather than the binary signature.
//
// First-launch migration: if a value isn't on disk yet, we try the old Keychain
// service once. If we find it, we copy to disk and delete the Keychain item so
// subsequent loads never have to consult Keychain (or trigger ACL prompts) again.
enum CredentialsStore {
    private static let legacyKeychainService = "com.meetingscribe.app"

    private static let directoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Notability/credentials", isDirectory: true)
    }()

    static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        ensureDirectory()
        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Drop any legacy Keychain copy so we never see the ACL prompt again
            // for this key after a successful write.
            deleteLegacyKeychain(for: key)
        } catch {
            print("[CredentialsStore] Failed to write \(key): \(error)")
        }
    }

    static func load(forKey key: String) -> String? {
        if let value = readFile(for: key) { return value }
        if let value = lookupKeychain(account: key) {
            save(value, forKey: key)
            return value
        }
        // Versions before the rebrand wrote under the "com.meetingscribe.*" namespace.
        // Check that location too so upgrading users don't lose their API key.
        let legacyKey = key.replacingOccurrences(of: "com.notability.", with: "com.meetingscribe.")
        if legacyKey != key {
            if let value = readFile(for: legacyKey) {
                save(value, forKey: key)
                try? FileManager.default.removeItem(at: fileURL(for: legacyKey))
                return value
            }
            if let value = lookupKeychain(account: legacyKey) {
                save(value, forKey: key)
                deleteLegacyKeychain(for: legacyKey)
                return value
            }
        }
        return nil
    }

    static func delete(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
        deleteLegacyKeychain(for: key)
    }

    // MARK: - Private

    private static func ensureDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private static func fileURL(for key: String) -> URL {
        // Defensive: forbid path-separator characters in filenames.
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent(safe)
    }

    private static func readFile(for key: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lookupKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func deleteLegacyKeychain(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
