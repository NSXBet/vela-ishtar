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
public final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let account: String

    /// Production uses the fixed service/account; tests inject a unique
    /// service so they can exercise the "no item yet" path against the real
    /// Keychain without touching the app's actual token.
    public init(service: String = "com.nsxbet.velaishtar", account: String = "gateway-token") {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// True only when `status` means "there is genuinely no token stored"
    /// — the real first-run case. Every other status is a *failure* (auth
    /// failed, user cancelled, ACL mismatch, …) and must not be mistaken for
    /// first-run. `errSecItemNotFound` is the only "absent" status.
    public static func isAbsentStatus(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound
    }

    /// Reads the stored token together with the raw `OSStatus`, so callers can
    /// distinguish "no token yet" (`errSecItemNotFound`) from a real Keychain
    /// failure. This is the seam that stops a hard error from masquerading as
    /// first-run.
    public func readStatus() -> (token: String?, status: OSStatus) {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    /// Reads the stored token, or nil if none exists.
    ///
    /// A genuine "no token" (`errSecItemNotFound`) returns nil quietly — that
    /// is the normal first-run path. Any OTHER status is a real Keychain
    /// failure (e.g. the post-update ACL mismatch that returns
    /// `errSecAuthFailed`, or the user pressing Deny → `errSecUserCanceled`);
    /// we still return nil so the caller's contract is unchanged, but we log
    /// it so the failure leaves a trace instead of silently reading as
    /// "logged out / first-run".
    public func read() -> String? {
        let (token, status) = readStatus()
        if token == nil, !KeychainStore.isAbsentStatus(status) {
            NSLog("KeychainStore.read: Keychain error \(status) reading token (not first-run); returning nil")
        }
        return token
    }

    /// Adds the token, or updates it in place if one is already stored.
    @discardableResult
    public func write(_ token: String) -> Bool {
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
    public func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
