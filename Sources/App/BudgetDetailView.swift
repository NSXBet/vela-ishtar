// Sources/App/BudgetDetailView.swift
// WP-08 08.2/08.3: the F01 detail surface. Clicking the budget row opens
// this compact view listing EVERY returned model cap — observed spend, cap,
// remaining budget room, enforcement/cooldown state — plus the global limit,
// the reset context, and how fresh the numbers are.
// Why: v1 showed only the single most urgent cap, so a global $400 budget
// with plenty left could hide one exhausted $20 model cap. This view makes
// the full nested policy visible at once, derived from one BudgetOverview
// value (no I/O, no re-derivation in AppKit).
// Honesty rules (plan F01): these are the gateway's RETURNED budget limits,
// never a complete model-availability catalog — the footer says so. Budget
// room never implies a guaranteed number of requests. Unknown/old policy
// data renders as "last observed".
// RELEVANT FILES: Sources/VelaCore/BudgetOverview.swift, Sources/App/DesignTokens.swift,
// Tests/VelaAppTests/BudgetDetailTests.swift

import Cocoa

@MainActor
public final class BudgetDetailView: NSView {

    /// The single value this view renders from. Replaced wholesale on
    /// re-render; per-row identity comes from the model route ID.
    private var overview: BudgetOverview
    private let calendar: Calendar

    /// The ONE scheduled invalidation for the soonest known cooldown expiry
    /// (plan §3.4: a single scheduled redraw, never a repeating timer).
    /// Cancelled and re-armed on every re-render.
    private var expiryWorkItem: DispatchWorkItem?

    /// Fired after the one cooldown-expiry redraw so the owning surface can
    /// relayout. Not fired when no cooldown is pending.
    public var onCooldownExpired: (() -> Void)?

    public init(overview: BudgetOverview, calendar: Calendar = .current) {
        self.overview = overview
        self.calendar = calendar
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.contentWidth, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BudgetDetailView does not support NSCoder-based initialization")
    }

    deinit {
        expiryWorkItem?.cancel()
    }

    // MARK: rendering

    /// Replaces the rendered content. Rows are keyed by stable model ID so
    /// AppKit (and VoiceOver) track the same logical cap across refreshes.
    public func render(overview: BudgetOverview) {
        self.overview = overview
        render()
    }

    private func render() {
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = VelaDesign.Layout.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Global line: the bound every cap nests under. A disabled limit
        // says so; it never renders "of $0" for a limit that doesn't exist
        // (B11 semantics preserved from the summary).
        stack.addArrangedSubview(globalLine())

        // Every returned cap gets a row — a relaxed cap cannot hide a
        // blocked one (08.1: concurrent conditions all surface).
        for signal in overview.modelSignals {
            stack.addArrangedSubview(row(for: signal))
        }

        // Reset context + freshness, then the availability disclaimer.
        let resetLabel = noteLabel(Self.resetText(overview: overview, calendar: calendar))
        stack.addArrangedSubview(resetLabel)
        stack.addArrangedSubview(noteLabel(Self.freshnessText(overview: overview, calendar: calendar)))
        stack.addArrangedSubview(noteLabel(Self.disclaimerText))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
        ])

        // Complete state to assistive technology (08.3): the whole view is
        // one element whose label covers global + every cap + freshness.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilitySummary(overview: overview, calendar: calendar))

        scheduleExpiryInvalidation()
    }

    // MARK: row construction

    private func globalLine() -> NSTextField {
        let text: String
        switch overview.globalState {
        case .disabled:
            text = "Global budget: no daily limit"
        case .invalid:
            text = "Global budget: unusable data"
        case .enabled:
            let remaining = overview.globalRemainingUSD ?? 0
            text = "Global budget: \(MoneyFormat.dollars(overview.globalSpentUSD)) of \(MoneyFormat.dollarsRounded(overview.globalLimitUSD)) · \(MoneyFormat.dollars(remaining)) left"
        }
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.body
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// One cap row: display name, spend of cap, room, policy status. The
    /// route ID is the stable identity, not the display name.
    private func row(for signal: BudgetOverview.ModelSignal) -> NSView {
        let name = ModelBudgetSignal.displayName(for: signal.model)
        let value = Self.rowValue(signal)
        let status = signal.statusDescription

        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .firstBaseline
        container.spacing = VelaDesign.Layout.space2

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = VelaDesign.Typography.budgetName
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(nameLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = VelaDesign.Typography.budgetValue
        valueLabel.textColor = .labelColor
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        container.addArrangedSubview(valueLabel)

        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = VelaDesign.Typography.secondary
        statusLabel.textColor = VelaDesign.Color.caption(contrast: false)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        container.addArrangedSubview(statusLabel)

        // Stable identity + per-row accessibility: the same complete facts
        // a sighted user reads, in one element (08.3).
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.staticText)
        container.identifier = NSUserInterfaceItemIdentifier(Self.rowID(for: signal.model))
        container.setAccessibilityLabel("\(name), \(value), \(status)")
        return container
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.secondary
        label.textColor = VelaDesign.Color.caption(contrast: false)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        return label
    }

    // MARK: copy builders (pure, test-pinned)

    /// The value cell: "spend of cap · room left". A blocked cap shows its
    /// factual spend with zero room; uncapped/invalid room renders without
    /// inventing a number.
    public static func rowValue(_ signal: BudgetOverview.ModelSignal) -> String {
        let capText: String
        if let limit = signal.limitUSD {
            capText = MoneyFormat.dollarsRounded(limit)
        } else {
            capText = "no cap"
        }
        var parts = ["\(MoneyFormat.dollars(signal.spentUSD)) of \(capText)"]
        if let room = signal.headroomUSD {
            parts.append("\(MoneyFormat.dollars(room)) room")
        } else {
            parts.append("room unknown")
        }
        return parts.joined(separator: " · ")
    }

    /// The reset line, worded per §3.4: UTC explicit, local time rides
    /// along; a disabled limit says there is no limit to reset.
    public static func resetText(overview: BudgetOverview, calendar: Calendar) -> String {
        overview.resetDescription
    }

    /// Freshness line. Fresh readings state it; anything else — stale,
    /// invalidated, or unknown — is visibly "last observed" (08.3).
    public static func freshnessText(overview: BudgetOverview, calendar: Calendar) -> String {
        switch overview.freshness {
        case .fresh:
            return "current"
        case .stale(let lastReceivedAt):
            if let lastReceivedAt {
                return "last observed \(BudgetOverview.clockTime(lastReceivedAt, calendar: calendar))"
            }
            return "last observed: unknown"
        case .invalidated:
            return "last observed: unknown"
        }
    }

    /// The F01 honesty footer, verbatim intent: returned limits are not a
    /// model-availability catalog, and room is not a request guarantee.
    public static let disclaimerText =
        "Returned budget limits only — not a complete model catalog. Other limits may apply."

    /// Full summary for VoiceOver: global, then every cap, then freshness.
    public static func accessibilitySummary(overview: BudgetOverview, calendar: Calendar) -> String {
        var parts: [String] = []
        switch overview.globalState {
        case .disabled:
            parts.append("No global daily limit")
        case .invalid:
            parts.append("Global budget unusable")
        case .enabled:
            parts.append("Global budget \(MoneyFormat.dollars(overview.globalSpentUSD)) of \(MoneyFormat.dollarsRounded(overview.globalLimitUSD))")
        }
        for signal in overview.modelSignals {
            parts.append("\(ModelBudgetSignal.displayName(for: signal.model)), \(rowValue(signal)), \(signal.statusDescription)")
        }
        parts.append(resetText(overview: overview, calendar: calendar))
        parts.append(freshnessText(overview: overview, calendar: calendar))
        parts.append(disclaimerText)
        return parts.joined(separator: ". ")
    }

    /// Stable row identity: the gateway route ID. Display names are for
    /// humans; identity must never change when naming rules change.
    public static func rowID(for model: String) -> String {
        "budget-row-\(model)"
    }

    // MARK: cooldown expiry (08.3)

    /// Arms the single scheduled invalidation for the soonest still-active
    /// cooldown. No repeating timer: after this fires once, the next render
    /// re-derives and either re-arms another expiry or none remains.
    private func scheduleExpiryInvalidation() {
        let now = Date()
        let soonest = overview.modelSignals
            .compactMap { $0.relaxedUntil }
            .filter { $0 > now }
            .min()
        guard let soonest else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-render with the same overview: the expired cooldown's
            // relaxedUntil is now in the past, so the relaxed marker and
            // its headroom semantics drop out. Exactly one redraw.
            self.render(overview: self.overview)
            self.onCooldownExpired?()
        }
        expiryWorkItem = item
        // Schedule against the OVERVIEW's own instant (now), not Date() at
        // arm time — the overview may have been derived slightly earlier, and
        // the delay must count from when the cooldown was current.
        let delay = max(0, soonest.timeIntervalSince(now))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
