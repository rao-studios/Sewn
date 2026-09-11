import Foundation

/// Token store for the dev client. Backed by UserDefaults, not the Keychain:
/// `swift build` re-signs the binary ad hoc on every build, so the Keychain
/// treated each build as a new app and prompted for access on every launch.
/// The sign-in credentials are development test values that already live in
/// source (`TestCredentials`), so the Keychain added prompts without adding
/// protection. Keeps the KeychainStore name/API so call sites are unchanged.
enum KeychainStore {
    private static let prefix = "sewn.client.secure."

    static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func get(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func delete(_ key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }
}
