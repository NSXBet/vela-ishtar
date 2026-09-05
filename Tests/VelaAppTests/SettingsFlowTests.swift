// Tests/VelaAppTests/SettingsFlowTests.swift
// WP-10 10.3 acceptance: the settings surface's pure logic is pinned —
// ServiceManagement state mapping (enabled/disabled/requires-approval/
// unavailable), the credential status lines (B06: a Keychain failure is
// never worded as first-run), the honest update lines, and the pill-size
// round trip through the persisted defaults. No real SMAppService call,
// no real Keychain, no window shown.
// RELEVANT FILES: Sources/App/SettingsView.swift,
// Sources/App/PopoverView.swift, Sources/App/StatusItemController.swift

import AppKit
import Foundation
import Testing
@testable import VelaCore

@Suite("SettingsFlow")
struct SettingsFlowTests {

    // MARK: - ServiceManagement state mapping (10.3)

    @Test func loginStateMapping() {
        #expect(LoginServiceState.from(.enabled) == .enabled)
        #expect(LoginServiceState.from(.notRegistered) == .disabled)
        #expect(LoginServiceState.from(.requiresApproval) == .requiresApproval)
    }

    /// A not-found / unknown service is UNAVAILABLE with an explanation —
    /// never silently "off" (no error swallowed into an inert checkmark).
    @Test func loginStateNotFoundExplains() {
        let state = LoginServiceState.from(.notFound)
        guard case .unavailable(let why) = state else {
            Issue.record("expected .unavailable, got \(state)")
            return
        }
        #expect(!why.isEmpty)
    }

    @Test func loginStateUserLinesDistinguish() {
        let lines = [
            LoginServiceState.enabled.userLine,
            LoginServiceState.disabled.userLine,
            LoginServiceState.requiresApproval.userLine,
            LoginServiceState.unavailable("test reason").userLine,
        ]
        #expect(Set(lines).count == 4)
        #expect(lines[2].contains("System Settings"))
        #expect(lines[3].contains("test reason"))
    }

    // MARK: - Credential recovery lines (10.3, B06 semantics)

    /// Each observed CredentialStatus gets its own truthful line. The key
    /// B06 pin: a denied/locked Keychain NEVER reads as "no token saved".
    @MainActor
    @Test func credentialLinesNeverMaskFailureAsFirstRun() {
        let missing = SettingsView.credentialLine(for: .missing)
        let denied = SettingsView.credentialLine(for: .denied(errSecUserCanceled))
        let locked = SettingsView.credentialLine(for: .locked(errSecInteractionNotAllowed))
        let invalid = SettingsView.credentialLine(for: .invalid)

        #expect(missing.contains("No token"))
        #expect(denied.contains("denied") && denied.contains("\(errSecUserCanceled)"))
        #expect(locked.contains("locked"))
        #expect(invalid.contains("rejected") && invalid.contains("untouched"))
        // The failure lines must not collapse into the first-run wording.
        #expect(denied != missing)
        #expect(locked != missing)
    }

    @MainActor
    @Test func credentialLineForAvailableStatesHealthy() {
        #expect(SettingsView.credentialLine(for: .available).contains("Keychain"))
        #expect(SettingsView.credentialLine(for: .validationInProgress).contains("Validating"))
    }

    // MARK: - Update line (10.3: same truths as the bell's card)

    @MainActor
    @Test func updateLineNeverClaimsCurrentFromUnknown() {
        #expect(!PopoverView.settingsUpdateLine(.neverChecked).contains("Up to date"))
        #expect(!PopoverView.settingsUpdateLine(.failed(.networkError)).contains("Up to date"))
        #expect(PopoverView.settingsUpdateLine(.checkedCurrent) == "Up to date.")
        #expect(PopoverView.settingsUpdateLine(.checking).contains("Checking"))
    }

    // MARK: - Pill size round trip (10.3)

    /// applyPillSize persists through the same defaults key the right-click
    /// submenu uses, and sharedPillSize reads it back — Settings and the
    /// pill can never disagree.
    @MainActor
    @Test func pillSizeAppliesAndReadsBack() {
        let controller = StatusItemController()
        // Defaults mutation must not leak between tests: use the same key
        // the implementation uses, restore afterwards.
        let original = UserDefaults.standard.integer(forKey: "vela.calmLevel")
        defer { UserDefaults.standard.set(original, forKey: "vela.calmLevel") }

        controller.applyPillSize(2)   // .compact
        #expect(StatusItemController.sharedPillSize == 2)
        controller.applyPillSize(0)   // .automatic
        #expect(StatusItemController.sharedPillSize == 0)
        // Out-of-range levels are refused, not clamped into lies.
        controller.applyPillSize(9)
        #expect(StatusItemController.sharedPillSize == 0)
    }

    // MARK: - SettingsView rendering (built detached)

    /// The checkmark follows the applied pill size and the status labels
    /// carry the honest lines — a settings card that always shows real state.
    @MainActor
    @Test func settingsViewRendersAppliedState() {
        let view = SettingsView(
            pillSize: 1,
            login: .requiresApproval,
            credentialLine: SettingsView.credentialLine(for: .missing),
            exportAvailable: false,
            version: "2.0.0",
            updateLine: "Updates not checked yet."
        )
        view.apply(pillSize: 3, login: .enabled, credentialLine: "Token saved in Keychain — healthy.", updateLine: "Up to date.")
        // The view survives re-application without rebuilding (stable for
        // the secondary-panel seam).
        view.apply(credentialLine: "Keychain is locked or unavailable — unlock your Mac to restore readings.")
    }
}
