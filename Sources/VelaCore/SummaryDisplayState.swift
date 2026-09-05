// Sources/VelaCore/SummaryDisplayState.swift
// The immutable display state the popover renders from (WP-06 06.1/06.2).
// Why: the popover used to rebuild its whole subview tree from raw fetch
// state on every poll — rows lost identity, hover/focus died, and a poll
// could close the update card mid-read. This type is the single value the
// presenter derives from a PollOutcome + repository snapshot, and the only
// thing the view consumes: comparing two states tells the view exactly
// which sections changed, so unchanged sections are never touched.
// Moved here verbatim from UsageContracts.swift (WP-06 is the producer;
// fleshing stays within the frozen field set — names/cases/semantics are
// identical to the §7.2 declaration).
// RELEVANT FILES: Sources/App/SummaryPresenter.swift, Sources/App/PopoverView.swift,
// Sources/VelaCore/UsageContracts.swift

import Foundation

// MARK: - SummaryDisplayState

/// The immutable display state the popover renders from.
///
/// §7.2: "Equatable section states, stable row IDs, selected model period
/// and its scoped total, freshness/accessibility text; no Keychain/network
/// reads while constructing/applying." Pure value: building or applying
/// this state performs no I/O.
public struct SummaryDisplayState: Equatable, Sendable {
    /// One display row: stable ID across refreshes so AppKit diffing
    /// (and VoiceOver) track the same logical row.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let fraction: Double?

        public init(id: String, title: String, detail: String, fraction: Double?) {
            self.id = id
            self.title = title
            self.detail = detail
            self.fraction = fraction
        }
    }

    /// The hero section: headline amount + narrative line.
    public let hero: Row
    /// Model rows (max four named + pinned "Other" at the UI layer; the
    /// cap is presentation policy, not stored here).
    public let rows: [Row]
    /// The selected model period and its scoped total ("today" vs "month").
    public let selectedPeriod: String
    public let selectedPeriodTotalUSD: Double
    /// Freshness line for display and accessibility.
    public let freshnessText: String
    /// Full accessibility summary of the summary section.
    public let accessibilitySummary: String

    public init(
        hero: Row,
        rows: [Row],
        selectedPeriod: String,
        selectedPeriodTotalUSD: Double,
        freshnessText: String,
        accessibilitySummary: String
    ) {
        self.hero = hero
        self.rows = rows
        self.selectedPeriod = selectedPeriod
        self.selectedPeriodTotalUSD = selectedPeriodTotalUSD
        self.freshnessText = freshnessText
        self.accessibilitySummary = accessibilitySummary
    }
}
