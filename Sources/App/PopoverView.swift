// Sources/App/PopoverView.swift
// WP-07: the summary composition root. Builds each section ONCE (persistent
// views, 06.2 continuation) and applies committed SummaryDisplayState by
// diffing — an unchanged poll touches nothing, a changed one re-words labels
// in place. Focus (chart hover, open update card, open secondary surface)
// survives every poll because nothing is torn down (B10).
// Why the rewrite: v1 removed and re-created its whole subview tree on every
// 60s update and deliberately waited 210ms on a period switch. Those classes
// of churn are designed out here: sections are stable; data flows down from
// the display state the presenter derives.
// RELEVANT FILES: Sources/App/SummaryHeaderView.swift, Sources/App/ModelsSectionView.swift,
// Sources/App/ConnectionStatusView.swift, Sources/App/SecondaryPanelCoordinator.swift,
// Sources/App/CurveView.swift, Sources/App/DayStripView.swift, Sources/App/PeriodSwitcher.swift

import Cocoa
import ServiceManagement

@MainActor
public final class PopoverView: NSView {
    /// Fired by the "API key" footer link; AppDelegate swaps the popover
    /// into token-entry mode so the user can paste a rotated token.
    public var onReplaceToken: (() -> Void)?

    /// Fired when a subview (the update bell's "View release notes") needs
    /// the whole popover gone. PopoverView doesn't own its panel — main.swift
    /// does — so dismissal travels up as a closure, not a panel reference.
    public var onRequestDismiss: (() -> Void)?

    /// Fired on a Settings / connection-detail navigation. The app layer
    /// owns real settings surfaces (WP-10); the summary opens the connection
    /// detail through the secondary seam.
    public var onOpenSettings: (() -> Void)?
    /// WP-12: WP-09's explorer is live, so the settings export row is
    /// enabled; the app layer opens the explorer window (export dialog
    /// lives there, per-day).
    public var onOpenHistoryExplorer: (() -> Void)?
    let curveView = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))   // internal: PopoverPanel/main drive the draw-on animation

    // MARK: - Persistent sections (built once in init)

    let headerView = SummaryHeaderView()
    let modelsSection = ModelsSectionView()
    private let statusView = ConnectionStatusView()   // owned by headerView; kept for layout math
    private let secondary = SecondaryPanelCoordinator()

    /// Which window the models list aggregates over ("today" / "month").
    private var selectedPeriod: String = "today"

    /// The update checker, injected by main.swift after launch. The bell is
    /// rewired to read the checker's EXPLICIT state (WP-11 11.1) — a nil
    /// pendingRelease no longer collapses four truths into "up to date".
    public var updateChecker: UpdateChecker?

    // MARK: - v1 renderer inputs retained for the curve/strip (WP-09 owns
    // the timestamp-aware conversion; the legacy HistoryStore stays the
    // chart's data source).

    private var latestHistory: HistoryStore?
    private var latestResponse: UsageResponse?
    private var lastAppliedState: SummaryDisplayState?
    private var lastConnection: ConnectionState = .noCredential
    private var lastReceivedAt: Date?

    /// The version bullet's what's-new list. Read from the build-generated
    /// Contents/Resources/whatsnew.txt (awk-extracted from CHANGELOG.md by
    /// build.sh), so the bullet can never drift from the shipped release.
    private static var whatsNew: [(version: String, note: String)] {
        WhatsNew.bundled(fallback: whatsNewFallback)
    }
    private static let whatsNewFallback: [(version: String, note: String)] = [
        ("1.0.0", "a true Mon–Sun week you can hover, plus the update bell"),
        ("0.5.1", "the spend curve is now scrubable"),
        ("0.5.0", "the models table, re-set: aligned numbers and a share figure"),
    ]

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.summaryWidth, height: 480))
        wantsLayer = true
        buildSections()
    }

    public required init?(coder: NSCoder) {
        fatalError("PopoverView does not support NSCoder-based initialization")
    }

    /// Sections are constructed once and never removed. Rows inside them
    /// are reused by stable ID (ModelsSectionView.apply).
    private func buildSections() {
        headerView.onSettings = { [weak self] in
            self?.openSecondarySurface(.settings)
        }
        modelsSection.onSelectPeriod = { [weak self] index in
            guard let self else { return }
            let period = index == 0 ? "today" : "month"
            guard period != self.selectedPeriod else { return }
            self.selectedPeriod = period
            // Immediate data re-derive from already-committed state; the
            // indicator's own 140ms slide runs independently (B10).
            self.reapplyLastState()
        }
        addSubview(headerView)
        addSubview(modelsSection)
    }

    // MARK: - WP-06/07 application path

    /// Applies committed display state. The 07.1 entry: sections are updated
    /// in place; an identical state is a no-op, so an unchanged poll cannot
    /// rebuild anything and open detail/focus survives untouched.
    public func apply(
        displayState: SummaryDisplayState?,
        connection: ConnectionState,
        response: UsageResponse?,
        receivedAt: Date?
    ) {
        lastConnection = connection
        lastReceivedAt = receivedAt
        if let response { latestResponse = response }

        guard let state = displayState else {
            lastAppliedState = nil
            return
        }
        if state == lastAppliedState { return }
        lastAppliedState = state
        applyDisplayState(state)
    }

    /// Re-derives from the last committed state (a period switch). No poll,
    /// no wait — the state is already in memory.
    private func reapplyLastState() {
        guard let state = lastAppliedState else { return }
        applyDisplayState(state)
    }

    private func applyDisplayState(_ state: SummaryDisplayState) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        // Status slot kind from the CONNECTION (freshness copy already
        // carries the state's wording; the band kind maps DESIGN.md §4):
        // auth/invalid → alarm, stale/retrying → notice, else neutral.
        let statusKind: VelaDesign.Color.StatusKind
        switch lastConnection {
        case .authenticationRequired, .invalidResponse:
            statusKind = .alarm
        case .stale, .retrying, .keychainBlocked, .noCredential, .connecting:
            statusKind = .notice
        case .live:
            statusKind = .neutral
        }

        headerView.apply(
            hero: state.hero,
            freshnessText: state.freshnessText,
            statusKind: statusKind,
            contrast: contrast
        )
        modelsSection.apply(
            rows: state.rows,
            totalText: MoneyFormat.dollars(state.selectedPeriodTotalUSD),
            selectedPeriodIndex: selectedPeriod == "today" ? 0 : 1,
            contrast: contrast
        )

        // Curve + strip: still fed from the legacy HistoryStore (WP-09 owns
        // the Observation-based conversion). configure() is rebuild-safe and
        // preserves an active scrub.
        if let history = latestHistory {
            configureChart(history: history, state: state)
        }
        relayout()
    }

    /// The HistoryStore the curve/day-strip render from, injected at
    /// popover open.
    var historyForRender: HistoryStore = HistoryStore(directory: FileManager.default.temporaryDirectory) {
        didSet { latestHistory = historyForRender }
    }

    private func configureChart(history: HistoryStore, state: SummaryDisplayState) {
        guard let usage = latestResponse else { return }
        let dayRecord = history.day(spendDate: usage.dailyBudget.spendDate)
        let hourly = dayRecord?.hourly ?? Array(repeating: nil, count: 24)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let utcHour = utcCalendar.component(.hour, from: Date())
        // B11: no ceiling for a disabled limit (CurveView guards limit > 0,
        // and a disabled limit renders no dotted $X line at all).
        let ceiling = usage.dailyBudget.limitEnabled ? usage.dailyBudget.limitUSD : 0
        let isFresh = lastConnection == .live
        let ghost = PaceEngine.ghostCurve(in: history.allDays, excluding: usage.dailyBudget.spendDate)
        curveView.configure(
            hourly: hourly,
            limit: ceiling,
            nowHourUTC: utcHour,
            ghost: ghost,
            drawGhostStroke: isFresh,
            limitEnabled: usage.dailyBudget.limitEnabled
        )
    }

    // MARK: - Layout (named slots; height changes only on content growth)

    private static let topPad: CGFloat = 12
    private static let bottomPad: CGFloat = 12
    private static let sectionSpacing: CGFloat = VelaDesign.Layout.sectionSpacing
    private static let chartLabelHeight: CGFloat = 14
    private static let chartHeight: CGFloat = 92
    private static let chartCaptionHeight: CGFloat = 16
    private static let stripHeight: CGFloat = DayStripView.height + 6
    private static let footerHeight: CGFloat = 20

    /// Computes the content height from the CURRENT section states. Ordinary
    /// polls (numbers, freshness, row counts) never change it; only structural
    /// presence (cap row, stale caption) can.
    private func preferredHeight() -> CGFloat {
        var h = Self.topPad
        h += headerView.preferredHeight
        h += Self.sectionSpacing
        h += Self.chartLabelHeight + Self.sectionSpacing + Self.chartHeight + Self.chartCaptionHeight
        h += Self.sectionSpacing
        h += ModelsSectionView.headerHeight + ModelsSectionView.blockHeight
        h += Self.sectionSpacing
        h += Self.stripHeight
        h += Self.sectionSpacing
        h += Self.footerHeight
        h += Self.bottomPad
        return h
    }

    private func relayout() {
        let width = VelaDesign.Layout.summaryWidth
        let height = preferredHeight()
        var y = height - Self.topPad

        headerView.frame = NSRect(x: 0, y: y - headerView.preferredHeight, width: width, height: headerView.preferredHeight)
        headerView.layoutContent(contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        y -= headerView.preferredHeight + Self.sectionSpacing

        // Chart lane.
        y -= Self.chartLabelHeight
        y -= Self.sectionSpacing
        curveView.frame = NSRect(x: (width - 284) / 2, y: y - Self.chartHeight, width: 284, height: Self.chartHeight)
        y -= Self.chartHeight
        y -= Self.chartCaptionHeight
        y -= Self.sectionSpacing

        modelsSection.frame = NSRect(x: 0, y: y - modelsSection.preferredHeight, width: width, height: modelsSection.preferredHeight)
        modelsSection.layoutContent(contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        y -= modelsSection.preferredHeight + Self.sectionSpacing

        y -= Self.stripHeight
        y -= Self.sectionSpacing
        // Footer row sits at y.
        footerFrame = NSRect(x: 0, y: y - Self.footerHeight, width: width, height: Self.footerHeight)
        layoutFooter()

        if abs(frame.height - height) > 1 {
            setFrameSize(NSSize(width: width, height: height))
            let panel = window as? NSPanel
            if let panel {
                var panelFrame = panel.frame
                let delta = height - panel.frame.height
                panelFrame.size.height = height
                panelFrame.origin.y -= delta
                panel.setFrame(panelFrame, display: true, animate: false)
            }
        }
    }

    // MARK: - Footer (persistent; re-worded in place)

    private var footerFrame: NSRect = .zero
    private var footerButtons: [NSButton] = []
    private var footerStatusLabel: NSTextField?
    private var footerDot: NSView?
    private var footerBuilt = false

    private func layoutFooter() {
        if !footerBuilt { buildFooter(); footerBuilt = true }
        let atLogin = SMAppService.mainApp.status == .enabled
        let loginTitle = atLogin ? "✓ Start at login" : "Start at login"
        let linkFont = VelaDesign.Typography.secondaryInteractive
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let isFresh = lastConnection == .live
        let statusText = "AI Hub · " + (isFresh ? "" : "stale ") + formatter.string(from: lastReceivedAt ?? Date())

        func measure(_ title: String, _ font: NSFont) -> CGFloat {
            ceil((title as NSString).size(withAttributes: [.font: font]).width)
        }
        let layout = FooterLayout.layout(
            metrics: FooterLayout.Metrics(
                dashboard: measure("Dashboard ↗", linkFont),
                apiKey: measure("API key", linkFont),
                login: measure(loginTitle, linkFont),
                widestLogin: measure("✓ Start at login", linkFont),
                statusWithTimestamp: measure(statusText, statusFont),
                statusShort: measure("AI Hub", statusFont)
            ),
            spacing: FooterLayout.Spacing(
                totalWidth: VelaDesign.Layout.summaryWidth,
                sidePadding: VelaDesign.Layout.contentInset,
                linkSpacing: Self.linkSpacing,
                linkGutter: Self.linkGutter,
                loginToDotGap: Self.loginToDotGap,
                dotToStatus: 12
            )
        )
        // Re-measure-driven positions; widths are fixed per button title.
        footerButtons[0].frame = NSRect(x: layout.dashboard.x, y: footerFrame.minY, width: layout.dashboard.width, height: Self.footerHeight)
        footerButtons[1].frame = NSRect(x: layout.apiKey.x, y: footerFrame.minY, width: layout.apiKey.width, height: Self.footerHeight)
        footerButtons[2].setAccessibilityValue(atLogin ? "enabled" : "disabled")
        footerButtons[2].frame = NSRect(x: layout.login.x, y: footerFrame.minY, width: layout.login.width, height: Self.footerHeight)
        if footerButtons[2].title != loginTitle { footerButtons[2].title = loginTitle }

        let dotColor: NSColor = isFresh ? .systemGreen : (lastReceivedAt != nil ? .systemOrange : NSColor.labelColor.withAlphaComponent(0.35))
        footerDot?.layer?.backgroundColor = dotColor.cgColor
        footerDot?.frame = NSRect(x: layout.dotX, y: footerFrame.minY + 6, width: 7, height: 7)
        footerStatusLabel?.stringValue = layout.showsTimestamp ? statusText : "AI Hub"
        footerStatusLabel?.frame = NSRect(x: layout.statusX, y: footerFrame.minY + 3, width: VelaDesign.Layout.summaryWidth - VelaDesign.Layout.contentInset - layout.statusX, height: 14)
    }

    private func buildFooter() {
        let inset = VelaDesign.Layout.contentInset
        func makeLinkButton(title: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: nil)
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = VelaDesign.Typography.secondaryInteractive
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityRole(.link)
            return button
        }
        let dashboard = makeLinkButton(title: "Dashboard ↗")
        dashboard.target = self
        dashboard.action = #selector(openDashboard)
        let apiKey = makeLinkButton(title: "API key")
        apiKey.target = self
        apiKey.action = #selector(replaceTokenTapped)
        let login = makeLinkButton(title: "Start at login")
        login.target = self
        login.action = #selector(toggleLaunchAtLogin)
        footerButtons = [dashboard, apiKey, login]
        footerButtons.forEach { addSubview($0) }

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = NSColor.labelColor.withAlphaComponent(0.38)
        status.alignment = .right
        status.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(status)
        footerStatusLabel = status

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(dot)
        footerDot = dot
        _ = inset
    }

    private static let loginToDotGap: CGFloat = 12
    private static let linkSpacing: CGFloat = 5
    private static let linkGutter: CGFloat = 4

    @objc private func openDashboard() {
        if let url = URL(string: "https://ai.fbr.land/models") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Toggles SMAppService registration. Errors are swallowed on purpose:
    /// ad-hoc-signed builds can be refused by the system in some contexts,
    /// and the toggle simply keeps reflecting the real status next update.
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // See comment above — the button re-reads status on the next
            // popover open, so a failed toggle just looks like no change.
        }
        relayout()
    }

    /// Swaps the popover into token-entry mode. Deliberately does NOT copy
    /// the token to the pasteboard — the general pasteboard is readable by
    /// every process and syncs via Universal Clipboard, so a silent copy of
    /// a spend-capable token is a leak.
    @objc private func replaceTokenTapped() {
        onReplaceToken?()
    }

    // MARK: - Secondary surfaces (07.4)

    private func openSecondarySurface(_ surface: SecondaryPanelCoordinator.Surface) {
        guard let parent = window else { return }
        secondary.onRequestDismiss = { [weak self] in self?.onRequestDismiss?() }
        let content = secondaryContent(for: surface)
        secondary.toggle(surface: surface, contentView: content, relativeTo: parent)
    }

    /// Secondary content per surface. Budget detail is WP-08's
    /// BudgetDetailView hosted through this seam (07.4: one consistent
    /// native treatment); connection detail is minimal-truthful here;
    /// settings proper is WP-10's surface.
    private func secondaryContent(for surface: SecondaryPanelCoordinator.Surface) -> NSView {
        switch surface {
        case .budgetDetail:
            if let overview = derivedBudgetOverview {
                return BudgetDetailView(overview: overview)
            }
            return simpleInfoCard(title: "Budget", line: "Waiting for the first reading")
        case .connectionDetail:
            return simpleInfoCard(title: "Connection", line: lastAppliedState?.freshnessText ?? "Waiting for the first reading")
        case .settings:
            let settings = SettingsView(
                pillSize: StatusItemController.sharedPillSize,
                login: Self.loginServiceState(),
                credentialLine: SettingsView.credentialLine(for: credentialStatus),
                exportAvailable: true,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                updateLine: Self.settingsUpdateLine(updateChecker?.state ?? .neverChecked)
            )
            settings.onSelectPillSize = { level in
                StatusItemController.shared?.applyPillSize(level)
            }
            settings.onOpenExport = { [weak self] in
                self?.onOpenHistoryExplorer?()
            }
            settings.onOpenHistory = {
                NSWorkspace.shared.open(HistoryStore.defaultDirectory)
            }
            return settings
        case .updateInfo:
            return simpleInfoCard(title: "Updates", line: "Check for updates from the bell in the top-right corner.")
        }
    }


    // MARK: - Settings inputs (WP-10 10.3)

    /// The pill's current size level (0=automatic … 3=minimal), read live
    /// from StatusItemController's persisted setting so the checkmark
    /// matches what the pill actually is.
    var currentPillSize: Int { StatusItemController.sharedPillSize }

    /// The observed credential status, injected by main.swift at boot.
    /// Read-only: SettingsView renders it; nothing here mutates
    /// CredentialController.
    var credentialStatus: CredentialStatus = .missing

    /// ServiceManagement status → honest LoginServiceState. Errors are NOT
    /// swallowed: a not-found service carries its explanation.
    static func loginServiceState() -> LoginServiceState {
        LoginServiceState.from(SMAppService.mainApp.status)
    }

    /// The update line Settings renders — explicit state wording, same
    /// truths the bell's card shows (never "up to date" from unknown).
    static func settingsUpdateLine(_ state: ReleaseChecker.UpdateState) -> String {
        switch state {
        case .available(let release): return "Update available: v\(release.tag)."
        case .skipped(let release): return "Update v\(release.tag) available but skipped."
        case .checkedCurrent: return "Up to date."
        case .neverChecked: return "Updates not checked yet."
        case .checking: return "Checking for updates…"
        case .failed: return "Last update check failed."
        }
    }

    private func simpleInfoCard(title: String, line: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 110))
        let title2 = NSTextField(labelWithString: title)
        title2.font = VelaDesign.Typography.body
        title2.frame = NSRect(x: 16, y: 70, width: 228, height: 20)
        container.addSubview(title2)
        let text = NSTextField(labelWithString: line)
        text.font = VelaDesign.Typography.secondary
        text.textColor = VelaDesign.Color.caption(contrast: false)
        text.lineBreakMode = .byTruncatingTail
        text.frame = NSRect(x: 16, y: 44, width: 228, height: 16)
        container.addSubview(text)
        let close = NSButton(title: "Close", target: self, action: #selector(closeSecondary))
        close.isBordered = false
        close.bezelStyle = .inline
        close.frame = NSRect(x: 16, y: 8, width: 80, height: VelaDesign.Rows.controlMinHeight)
        container.addSubview(close)
        return container
    }

    /// The derived BudgetOverview for the seam, built from the last
    /// committed snapshot on demand (pure derivation, no I/O).
    private var derivedBudgetOverview: BudgetOverview? {
        guard let snapshot = latestSnapshot else { return nil }
        return BudgetOverview.derive(
            from: snapshot,
            freshness: .derive(receivedAt: snapshot.receivedAt, now: Date()),
            now: Date(),
            calendar: .current
        )
    }
    private var latestSnapshot: UsageSnapshot?

    /// The coordinator hands the committed snapshot at apply time so the
    /// budget-detail seam can derive its overview without new I/O.
    public func applySnapshot(_ snapshot: UsageSnapshot?) {
        latestSnapshot = snapshot
    }

    private func addSubviewStatic(_ view: NSView, to parent: NSView, y: CGFloat) {
        view.frame = NSRect(x: 0, y: y, width: parent.bounds.width, height: 20)
        parent.addSubview(view)
    }

    @objc private func closeSecondary() {
        secondary.close()
    }

    // MARK: - Chrome (version bullet + update bell; added once, state-applied)

    private var versionBullet: VersionBulletView?
    private var bell: UpdateBellView?
    private var chromeBuilt = false

    /// Adds the top-right chrome once; later calls only re-apply state.
    public func applyChrome() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        if !chromeBuilt {
            chromeBuilt = true
            let hitSize: CGFloat = 20
            let margin: CGFloat = 6
            let bullet = VersionBulletView(version: version, notes: Self.whatsNew)
            bullet.autoresizingMask = [.minXMargin, .minYMargin]
            bullet.frame = NSRect(x: bounds.width - margin - hitSize, y: bounds.height - margin - hitSize, width: hitSize, height: hitSize)
            addSubview(bullet)
            versionBullet = bullet

            let bell = UpdateBellView(state: updateChecker?.state ?? .neverChecked, runningVersion: version)
            bell.onSkip = { [weak self] in self?.updateChecker?.skipCurrent() }
            bell.onOpenRelease = { [weak self] in self?.onRequestDismiss?() }
            bell.autoresizingMask = [.minXMargin, .minYMargin]
            bell.frame = NSRect(x: bounds.width - margin - 2 * hitSize - 4, y: bounds.height - margin - hitSize, width: hitSize, height: hitSize)
            addSubview(bell)
            self.bell = bell
        }
        // Bell state re-applied in place — a poll or a checker change never
        // rebuilds (and never closes) an open update card (B10).
        bell?.apply(state: updateChecker?.state ?? .neverChecked, runningVersion: version)
    }

    // MARK: - Loading state (07.1: calm, neutral, reserved slots)

    /// Loading state for the very first open. The full section skeleton is
    /// already built; this shows the neutral connecting line in the reserved
    /// status slot and the honest empty curve lane — no geometry jump when
    /// the first real state lands.
    func renderLoadingState(history: HistoryStore, now: Date) {
        historyForRender = history
        latestHistory = history
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        headerView.apply(
            hero: SummaryDisplayState.Row(id: "hero", title: "$0.00", detail: "", fraction: nil),
            freshnessText: "Waiting for the first reading",
            statusKind: .neutral,
            contrast: contrast
        )
        modelsSection.apply(
            rows: [SummaryDisplayState.Row(id: "loading", title: "Connecting to AI Hub", detail: "first observation will appear here", fraction: nil)],
            totalText: "$0.00",
            selectedPeriodIndex: 0,
            contrast: contrast
        )
        curveView.configure(hourly: Array(repeating: nil, count: 24), limit: 0, nowHourUTC: 0, ghost: nil, drawGhostStroke: false, limitEnabled: false)
        relayout()
        applyChrome()
    }

    func renderLoadingState(now: Date) {
        renderLoadingState(history: historyForRender, now: now)
    }

    /// Draw-on animation for the curve, run once per popover open (skipped
    /// under Reduce Motion by the caller).
    public func animateCurveDrawOn() {
        curveView.animateReveal()
        curveView.rearmScrubRing()
    }
}
