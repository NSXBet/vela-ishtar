// Sources/App/KeychainStore.swift
// Thin wrapper around a single generic-password Keychain item that holds
// the AI Hub gateway token.
// Why: the token must survive app relaunches and machine restarts without
// living in a plaintext file; Keychain is the standard macOS place for that.
// RELEVANT FILES: Sources/App/AIHubClient.swift, Sources/VelaCore/Models.swift

import Foundation
import Security

/// Reads, writes, and deletes the gateway token from the macOS Keychain.
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlock`: Vela Ishtar is a
/// login-item menu bar app that needs to read the token as soon as it
/// launches at login, with no user interaction. `AfterFirstUnlock` allows
/// that (unlike `WhenUnlocked`, which would block a pre-login launch), while
/// still requiring the disk to have been unlocked at least once since boot
/// (unlike `Always`, which is deprecated and never locks at all).
///
/// Security framework calls are thread-safe, so this type needs no locking
/// or actor isolation of its own.
final class KeychainStore {
    private let service = "com.nsxbet.velaishtar"
    private let account = "gateway-token"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads the stored token, or nil if none exists (or on any Keychain error).
    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds the token, or updates it in place if one is already stored.
    @discardableResult
    func write(_ token: String) -> Bool {
        let data = Data(token.utf8)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }

        guard addStatus == errSecDuplicateItem else { return false }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        return updateStatus == errSecSuccess
    }

    /// Removes the token. Returns true if it was deleted, or if there was
    /// nothing to delete (deleting an absent item is not a failure).
    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
