// Sources/App/SummaryHeaderView.swift
// WP-07 07.1: the summary shell's header — TODAY label + Settings control,
// the 30pt tabular hero with its factual suffix, and the freshness/status
// region rendered through ConnectionStatusView.
// Why: DESIGN.md §5.2 freezes this hierarchy; B11 lives here — the hero
// suffix comes from MoneyFormat.heroSuffix, which returns nil when the
// global limit is disabled, so a no-limit account NEVER reads "of $400
// today" and the hero keeps the real spend (never a $0.00 lie).
// RELEVANT FILES: Sources/App/ConnectionStatusView.swift, Sources/App/PopoverView.swift,
// Sources/VelaCore/MoneyFormat.swift, Sources/App/DesignTokens.swift

import AppKit

@MainActor
final class SummaryHeaderView: NSView {

    var onSettings: (() -> Void)?

    private let periodLabel = NSTextField(labelWithString: "TODAY")
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
    private let heroLabel = NSTextField(labelWithString: "$0.00")
    private let suffixLabel = NSTextField(labelWithString: "")
    private let statusView: ConnectionStatusView

    init() {
        statusView = ConnectionStatusView()
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.summaryWidth, height: 0))
        periodLabel.font = VelaDesign.Typography.sectionLabel
        periodLabel.textColor = VelaDesign.Color.sectionLabel
        addSubview(periodLabel)

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .inline
        settingsButton.font = VelaDesign.Typography.secondaryInteractive
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        addSubview(settingsButton)

        heroLabel.font = VelaDesign.Typography.hero
        heroLabel.textColor = .labelColor
        addSubview(heroLabel)

        suffixLabel.font = VelaDesign.Typography.heroSuffix
        suffixLabel.textColor = .secondaryLabelColor
        suffixLabel.lineBreakMode = .byTruncatingTail
        suffixLabel.maximumNumberOfLines = 1
        addSubview(suffixLabel)

        addSubview(statusView)
    }

    public required init?(coder: NSCoder) {
        fatalError("SummaryHeaderView does not support NSCoder-based initialization")
    }

    @objc private func settingsTapped() { onSettings?() }

    // MARK: - Layout (named slots; stable geometry, DESIGN.md §4)

    private static let headerHeight: CGFloat = 18
    private static let heroHeight: CGFloat = 34
    private static let suffixHeight: CGFloat = 18

    var statusSlotHeight: CGFloat { VelaDesign.Rows.statusSlotHeight }

    /// One-pass placement; the caller sizes this view to `preferredHeight`
    /// before calling so bottom-anchored rows land against final bounds.
    func layoutContent(contrast: Bool) {
        let inset = VelaDesign.Layout.contentInset
        let width = bounds.width
        var y = bounds.height

        // TODAY and Settings share one horizontal centerline: the button's
        // 24pt control height defines the row; the label centers in it.
        let rowHeight = VelaDesign.Rows.controlMinHeight
        periodLabel.frame = NSRect(x: inset, y: y - Self.headerHeight + (rowHeight - 14) / 2,
                                   width: 60, height: 14)
        let settingsW: CGFloat = 64
        settingsButton.frame = NSRect(x: width - inset - settingsW, y: y - Self.headerHeight,
                                      width: settingsW, height: rowHeight)
        y -= Self.headerHeight

        heroLabel.frame = NSRect(x: inset, y: y - Self.heroHeight, width: heroLabel.fittingSize.width + 2, height: 30)
        y -= Self.heroHeight

        suffixLabel.frame = NSRect(x: inset, y: y - Self.suffixHeight, width: width - 2 * inset, height: 16)
        y -= Self.suffixHeight

        statusView.frame = NSRect(x: 0, y: y - VelaDesign.Rows.statusSlotHeight, width: width, height: VelaDesign.Rows.statusSlotHeight)
    }

    /// Natural height of the header block (header + hero + suffix + status slot).
    var preferredHeight: CGFloat {
        Self.headerHeight + Self.heroHeight + Self.suffixHeight + VelaDesign.Rows.statusSlotHeight
    }

    // MARK: - State application (in-place; the view is built once)

    /// Applies the hero + freshness facts from committed display state.
    /// No polling, formatting, or I/O beyond string building (§7.2: the
    /// state arrives pre-derived; this only words/places it).
    func apply(hero: SummaryDisplayState.Row, freshnessText: String, statusKind: VelaDesign.Color.StatusKind, contrast: Bool) {
        heroLabel.stringValue = hero.title
        heroLabel.textColor = hero.title == "$0.00" && hero.detail.isEmpty
            ? NSColor.tertiaryLabelColor : .labelColor
        // B11: the suffix is nil when the limit is disabled — never "of $400
        // today" for a limit that doesn't exist. The presenter already routes
        // MoneyFormat.heroSuffix; `detail` carries it verbatim.
        let suffix = hero.detail
        suffixLabel.stringValue = suffix
        suffixLabel.isHidden = suffix.isEmpty
        statusView.apply(text: freshnessText, kind: statusKind, contrast: contrast)
        layoutContent(contrast: contrast)
    }
}
