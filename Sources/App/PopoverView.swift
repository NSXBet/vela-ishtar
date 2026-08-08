// Sources/App/PopoverView.swift
// Renders the popover panel content: hero spend, pace sentence, hourly curve,
// top models, and footer with dashboard link, API key copy, and status indicator.
// Why: this is the primary UI surface showing budget status and model costs
// in a fixed 320pt width, laid out with hairline section dividers and a status
// dot that changes color with fetch freshness.
// RELEVANT FILES: Sources/App/CurveView.swift, Sources/VelaCore/PaceEngine.swift, Sources/VelaCore/PollStateMachine.swift

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

    let curveView = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))   // internal: PopoverPanel/main drive the draw-on animation
    private var managedSubviews: [NSView] = []

    /// Which window the models list aggregates over. Today/Week compute from
    /// local history (the API has no period param); Month uses the API's
    /// current_month + top_models directly.
    private enum ModelPeriod: Int { case today = 0, month = 1 }
    private var selectedPeriod: ModelPeriod = .today
    private var latestResponse: UsageResponse?
    private var latestHistory: HistoryStore?
    // The last real PollState and its freshness inputs, captured in update().
    // periodChanged() re-renders from these (NOT from latestResponse re-wrapped
    // as .fresh) so a stale reading stays amber/dimmed/bannered across a
    // period toggle — the UI must never claim fresh data it doesn't have.
    private var latestState: PollState = .neverFetched
    private var latestExhaustedAt: Date?
    private var latestSuccessAt: Date?
    // The latest Today-by-model split, captured in update() like latestState
    // so periodChanged() can re-render the Today segment without a fresh poll.
    private var latestModelSplit: TodayModelSplitResult = .unavailable(.noBaseline)

    /// The update checker (v0.5.2), injected by main.swift after launch.
    /// addVersionBullet reads `pendingRelease` to place the update bell left
    /// of the version dot; nil means no bell (never checked, nothing newer,
    /// or the user skipped it).
    public var updateChecker: UpdateChecker?

    private let sidePadding: CGFloat = 18
    private let sectionSpacing: CGFloat = 12
    private let hairlineHeight: CGFloat = 0.5

    /// The version bullet's what's-new list. Read from the build-generated
    /// Contents/Resources/whatsnew.txt (awk-extracted from CHANGELOG.md by
    /// build.sh), so the bullet can never drift from the shipped release.
    /// The static array below is only a fallback for runs without the build
    /// artifact (e.g. a bare swiftc invocation that skipped the copy step).
    private static var whatsNew: [(version: String, note: String)] {
        WhatsNew.bundled(fallback: whatsNewFallback)
    }
    private static let whatsNewFallback: [(version: String, note: String)] = [
        ("1.0.0", "a true Mon–Sun week you can hover, plus the update bell"),
        ("0.5.1", "the spend curve is now scrubable"),
        ("0.5.0", "the models table, re-set: aligned numbers and a share figure"),
    ]

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        self.managedSubviews = []
    }

    public required init?(coder: NSCoder) {
        fatalError("PopoverView does not support NSCoder-based initialization")
    }

    private var isRelayout = false
    /// Month runway (v0.2.0) or pace/median line (v0.2.0) — one 18pt slot
    /// that both periods ALWAYS consume (v0.4.3). Rendering the slot even when
    /// its text is suppressed (early month, no spend, stale) is what makes the
    /// two periods equal-height: the panel never resizes on a tab switch, so
    /// the curve, the rows, and the top edge stay glued in place. The label is
    /// invisible when there's nothing to say — reserved air, not dead UI.
    private static let paceSlotHeight: CGFloat = 18

    /// Today shows 1–5 model rows, Month up to 5. v0.4.3 pads the models
    /// block to a constant 5 rows in BOTH periods (empty slots render as
    /// blank air), so the section is the same height whichever tab is up —
    /// the second half of the never-resize-on-switch guarantee above.
    private static let maxModelRows = 5
    /// One model row's FULL stride: makeModelRow's 24pt row + its 8pt of air
    /// (it returns rowHeight + 8). The padding loop adds this per empty slot
    /// and makeTodayTotalRow claims maxModelRows × it, so every models-block
    /// branch lands on exactly maxModelRows × stride — v0.4.3's first cut used
    /// the bare rowHeight and under-charged rendered rows by 8pt each, which
    /// made a Today-total ↔ Month switch resize the card again.
    private static let modelRowSlotHeight: CGFloat = 32

    @MainActor
    public func update(state: PollState, history: HistoryStore, exhaustedAt: Date?, lastSuccessAt: Date?, now: Date, todayModelSplit: TodayModelSplitResult = .unavailable(.noBaseline)) {
        // Clear all subviews and rebuild from scratch on each update.
        subviews.forEach { $0.removeFromSuperview() }
        managedSubviews.removeAll()

        let usageResponse: UsageResponse?
        let isFresh: Bool

        switch state {
        case .neverFetched:
            usageResponse = nil
            isFresh = false
        case .fresh(let response):
            usageResponse = response
            isFresh = true
        case .stale(let response, _):
            usageResponse = response
            isFresh = false
        }

        // Loading state: a spinner + one line, centered. The full layout
        // renders once when the first real state arrives — no hero jump.
        if usageResponse == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.frame = NSRect(x: (320 - 16) / 2, y: 240, width: 16, height: 16)
            spinner.startAnimation(nil)
            addSubview(spinner)
            managedSubviews.append(spinner)

            let connecting = NSTextField(labelWithString: "Connecting to AI Hub…")
            connecting.font = NSFont.systemFont(ofSize: 13)
            connecting.textColor = .secondaryLabelColor
            connecting.alignment = .center
            connecting.frame = NSRect(x: 0, y: 210, width: 320, height: 18)
            addSubview(connecting)
            managedSubviews.append(connecting)
            // Chrome, not data: the version bullet shows even before the
            // first poll lands (offline first-run is exactly when a bug
            // report needs "what am I running").
            addVersionBullet()
            return
        }
        latestResponse = usageResponse
        latestHistory = history
        latestState = state
        latestExhaustedAt = exhaustedAt
        latestSuccessAt = lastSuccessAt
        latestModelSplit = todayModelSplit
        // A poll-driven rebuild re-configures the curve but must not fight the
        // draw-on reveal. v0.4.0: the reveal is a mask animation on CurveView's
        // layer (a persistent subview, so it survives this rebuild), and the
        // mask always ends at full width on its own. We only pin drawProgress
        // to 1 so the content UNDER the moving mask is complete — we do NOT
        // touch the mask here, or a poll landing mid-reveal would cut it short.
        curveView.drawProgress = 1

        var yOffset: CGFloat = 12

        // 1. Hero: "$54.51" + " of $400 today"
        if let usage = usageResponse {
            yOffset += makeHeroRow(spent: usage.dailyBudget.spentUSD, limit: usage.dailyBudget.limitUSD, at: &yOffset)
        } else {
            yOffset += makeHeroRow(spent: 0, limit: 0, isNeverFetched: true, at: &yOffset)
        }

        yOffset += sectionSpacing

        // 2. Pace sentence
        if let usage = usageResponse {
            let paceVerdict = PaceEngine.verdict(
                spent: usage.dailyBudget.spentUSD,
                limit: usage.dailyBudget.limitUSD,
                limitEnabled: usage.dailyBudget.limitEnabled,
                now: now,
                exhaustedAt: exhaustedAt,
                isFresh: isFresh
            )
            // Median-day benchmark: compare today's spend against the median
            // of past days at this same UTC hour. Only used when the pace
            // sentence would otherwise be the inert "stay under budget" line.
            //
            // Gated on isFresh: a stale response's spend figure is hours (or
            // a month boundary) old, so comparing it against NOW's UTC hour,
            // or projecting it over the CURRENT month, would present a
            // confident line derived from mismatched timestamps. Fall back
            // to the un-benchmarked sentence and no runway when stale.
            let typical: (median: Double, spent: Double)?
            if isFresh {
                var utcCalendar = Calendar(identifier: .gregorian)
                utcCalendar.timeZone = TimeZone(identifier: "UTC")!
                let hourUTC = utcCalendar.component(.hour, from: now)
                typical = PaceEngine.medianSpend(
                    atHourUTC: hourUTC,
                    in: history.allDays,
                    excluding: usage.dailyBudget.spendDate
                ).map { (median: $0, spent: usage.dailyBudget.spentUSD) }
            } else {
                typical = nil
            }
            let paceSentence = PaceEngine.sentence(for: paceVerdict, now: now, typical: typical)
            yOffset += makePaceRow(paceSentence, at: &yOffset)

            // 2b. Month runway: "On track for ~$X this month." — linear
            // extrapolation of the month's spend so far. Same freshness gate
            // as the median line above; suppressed early in the month and
            // when there's no spend yet (see PaceEngine.monthRunway).
            //
            // v0.4.3: the slot is RESERVED either way. When the runway is
            // suppressed we still consume the 18pt (an invisible row), so the
            // card's height doesn't breathe when the line appears on day 7 —
            // and, more importantly, so Today and Month stay equal height.
            if isFresh, let runway = PaceEngine.monthRunway(monthSpent: usage.currentMonth.totalCostUSD, now: now) {
                yOffset += makePaceRow(runway, at: &yOffset)
            } else {
                yOffset += Self.paceSlotHeight
            }
        } else {
            yOffset += makePaceRow("No data yet.", at: &yOffset)
            // Same reservation as the data path: the loading/first-run card is
            // the same height as the settled one, so the first real render
            // doesn't settle at all — it just brightens in place.
            yOffset += Self.paceSlotHeight
        }

        yOffset += sectionSpacing

        // 3. Hairline
        yOffset += makeHairline(at: &yOffset)
        yOffset += sectionSpacing

        // 4. "TODAY" + CurveView
        yOffset += makeTodayLabelAndCurve(history: history, limit: usageResponse?.dailyBudget.limitUSD ?? 0, usageResponse: usageResponse, isFresh: isFresh, now: now, at: &yOffset)
        yOffset += sectionSpacing

        // 5. Hairline
        yOffset += makeHairline(at: &yOffset)
        yOffset += sectionSpacing

        // 6. Models header + rows (aggregated over the chosen period).
        // v0.4.3: the block is ALWAYS maxModelRows tall in both periods —
        // short lists pad with invisible slot rows. This is half of the
        // never-resize-on-switch guarantee: the panel height can't depend on
        // how many models happen to be shown.
        let modelsForPeriod = aggregatedModels(response: usageResponse, history: history, now: now)
        yOffset += makeModelsHeader(at: &yOffset)
        var modelRowsRendered = 0
        if selectedPeriod == .today, let usage = usageResponse {
            // Today segment, three states. The split is the snapshot-derived
            // per-model breakdown (v0.3.0) — only trustable when the data is
            // fresh, so a stale reading falls back to the honest total-only
            // row and never shows a derived split against hours-old data.
            if isFresh, case .split(let s) = todayModelSplit {
                // Shares are of TODAY's total spend (the authoritative daily
                // figure), so the percents tie to the hero number. The pinned
                // "Other" residual passes showsShare=false — it isn't a model.
                // Display compaction (v0.3.1): at most 5 rows render, and the
                // reconciling Other row must NEVER be the one dropped — else
                // the visible breakdown stops tying to the day total. With
                // >4 named rows, fold the tail into Other so row 5 is always
                // the pinned residual.
                let dayTotal = usage.dailyBudget.spentUSD
                let named = s.rows.filter { !$0.isOther }
                let engineOther = s.rows.first { $0.isOther }?.costUSD ?? 0
                let displayRows: [(name: String, cost: Double, tokens: Double, isOther: Bool)]
                if named.count <= 4 {
                    displayRows = named.map { ($0.name, $0.costUSD, Double($0.tokens), false) }
                        + (engineOther > 0 ? [("Other", engineOther, 0, true)] : [])
                } else {
                    let kept = named.prefix(4)
                    let folded = named.dropFirst(4).reduce(0) { $0 + $1.costUSD } + engineOther
                    displayRows = kept.map { ($0.name, $0.costUSD, Double($0.tokens), false) }
                        + [( "Other", folded, 0, true )]
                }
                for row in displayRows {
                    let displayName = row.name.split(separator: "/").last.map(String.init) ?? row.name
                    let share = ModelShare.percent(cost: row.cost, total: dayTotal)
                    yOffset += makeModelRow(name: displayName, cost: row.cost, tokens: row.tokens, sharePercent: share, showsShare: !row.isOther, at: &yOffset)
                    modelRowsRendered += 1
                }
            } else if isFresh, case .unavailable(let reason) = todayModelSplit {
                // Fresh but not derivable (first day, month seam, gap): the
                // honest total plus WHY there's no split. noSpendYet's nil
                // note keeps the plain "monthly only" line.
                yOffset += makeTodayTotalRow(spent: usage.dailyBudget.spentUSD, note: reason.note, at: &yOffset)
                modelRowsRendered = Self.maxModelRows   // total row + note fills the block
            } else {
                // Stale: total only, no split note — the banner already says
                // the data is old, and a split note would claim a freshness
                // the rows below don't have.
                yOffset += makeTodayTotalRow(spent: usage.dailyBudget.spentUSD, note: nil, at: &yOffset)
                modelRowsRendered = Self.maxModelRows
            }
        } else if !modelsForPeriod.isEmpty {
            // Shares are of the month's total spend across all models, so the
            // percents tie to the month hero figure.
            let monthTotal = modelsForPeriod.reduce(0) { $0 + $1.totalCostUSD }
            for model in modelsForPeriod.prefix(Self.maxModelRows) {
                // Display strips the provider prefix ("moonshotai/kimi-k3" -> "kimi-k3").
                let displayName = model.model.split(separator: "/").last.map(String.init) ?? model.model
                let share = ModelShare.percent(cost: model.totalCostUSD, total: monthTotal)
                // Month has no "Other" residual, so every row is a real model
                // and shows its share. Explicit (not the default) so a future
                // Month-side Other-fold is forced to reconsider this line.
                yOffset += makeModelRow(name: displayName, cost: model.totalCostUSD, tokens: Double(model.totalTokens), sharePercent: share, showsShare: true, at: &yOffset)
                modelRowsRendered += 1
            }
        }
        // Pad the block out to its constant height. A slot is one full row
        // stride (32pt) of blank air — invisible, but it keeps the models
        // section (and so the whole card) the same height whether Today
        // shows 1 model or 5, and equal to the total row's claimed block.
        while modelRowsRendered < Self.maxModelRows {
            yOffset += Self.modelRowSlotHeight
            modelRowsRendered += 1
        }

        yOffset += sectionSpacing

        // 7. Stale note (if applicable)
        if !isFresh && usageResponse != nil, let lastSuccess = lastSuccessAt {
            let minutesOld = PaceEngine.ageMinutes(now: now, lastSuccessAt: lastSuccess)
            yOffset += makeStaleBanner(minutesOld: minutesOld, at: &yOffset)
            yOffset += 6
        }

        // 7b. The 7-day strip, sitting directly on the footer hairline — its
        // own section, away from the curve it used to butt against.
        yOffset += makeDayStrip(history: history, usageResponse: usageResponse, isFresh: isFresh, at: &yOffset)

        // 8. Hairline
        yOffset += makeHairline(at: &yOffset)
        yOffset += sectionSpacing

        // 9. Footer
        yOffset += makeFooter(isFresh: isFresh, lastSuccessAt: lastSuccessAt, now: now, at: &yOffset)

        // Apply stale-state alpha to everything except footer.
        if !isFresh && usageResponse != nil {
            for subview in managedSubviews {
                if !(subview is NSButton) {
                    subview.alphaValue = 0.55
                }
            }
        }

        // 10. Version bullet, top-right corner (v0.3.2). A 6pt dot whose
        // tooltip answers "what am I running and what changed" without a
        // trip to GitHub. Positioned in the corner, outside the yOffset
        // flow — it doesn't consume layout height. Added AFTER the stale-
        // alpha pass above so the dot isn't dimmed with the content (like
        // the footer, it's chrome, not data).
        addVersionBullet()

        // Size the view to its content so the panel never leaves dead space
        // below the footer (the stale banner used to overflow the fixed 480).
        let contentHeight = yOffset + 12
        guard abs(frame.height - contentHeight) > 1, !isRelayout else { return }

        let panel = window as? NSPanel
        var panelFrame = panel?.frame ?? .zero
        let delta = contentHeight - (panel?.frame.height ?? contentHeight)
        panelFrame.size.height = contentHeight
        panelFrame.origin.y -= delta   // keep the top edge anchored

        // v0.4.3: the resize is SYNCHRONOUS again. The animated settle this
        // replaced existed to hide rows sliding during a height change — but
        // the only height change a user can trigger was the period switch, and
        // the two periods are now EQUAL height by construction (constant model
        // rows + a reserved pace slot), so a tab tap never reaches this block.
        // What remains is the rare content-driven change (a stale banner
        // appearing, the first live render settling over the loading view) —
        // infrequent enough that a one-beat snap beats the snapshot machinery,
        // and it can no longer clash with a period morph because there isn't
        // one. Simpler, and the card simply never resizes under the user.
        setFrameSize(NSSize(width: 320, height: contentHeight))
        panel?.setFrame(panelFrame, display: true, animate: false)
        // Rows were laid out against the OLD height — re-lay against the new
        // one so the hero isn't cut off on first open.
        isRelayout = true
        update(state: state, history: history, exhaustedAt: exhaustedAt, lastSuccessAt: lastSuccessAt, now: now, todayModelSplit: todayModelSplit)
        isRelayout = false
    }

    /// Draw-on animation for the curve, run once per popover open.
    /// v0.4.0: delegated to CurveView.animateReveal(), which renders once and
    /// animates a GPU mask (vsync-locked 60fps) instead of stepping
    /// drawProgress on 14 DispatchWorkItems. Reduce Motion callers skip this
    /// and leave drawProgress at 1 (the gate is in main.swift).
    public func animateCurveDrawOn() {
        curveView.animateReveal()
        curveView.rearmScrubRing()
    }

    /// Loading state for the very first open (state == .neverFetched).
    /// main.swift calls this instead of building a separate throwaway panel,
    /// so the loading view and the first real render share ONE panel — the
    /// only resize is the single settle-to-content when real data lands.
    ///
    /// Cold-open fix (v0.3.4): when history already holds a TODAY reading,
    /// the loading view shows it dimmed + a "Last reading" caption instead of
    /// a bare spinner — so the hero never sits blank for the 0.5–1s the first
    /// fetch takes. The frame is sized to its FINAL height up front (before
    /// any subview is laid out against `bounds.height`), then the hero,
    /// caption, and curve render in the SAME slots the live path uses. The
    /// live path is taller (it adds hairlines, models, footer), so the first
    /// real render still settles once — but it's a content swap in place, and
    /// the hero number the user is reading never moves or blanks out.
    func renderLoadingState(history: HistoryStore, now: Date) {
        subviews.forEach { $0.removeFromSuperview() }
        managedSubviews.removeAll()

        // Rehydrate today's last reading from history. nil on a true first
        // run (or past the midnight seam) → keep the honest spinner.
        let snapshot = PollStateMachine.coldOpenSnapshot(in: history, now: now)

        // Open at the FINAL content height BEFORE laying out any subview. The
        // row helpers position against `bounds.height` (bottom-anchored,
        // non-flipped view), so the frame must already be the target height —
        // otherwise everything is placed against the stale 480pt init bounds
        // and clipped away when the panel shrinks. nil → spinner at 200.
        let height: CGFloat = snapshot != nil
            ? (12 + 36 + 18 + sectionSpacing + 14 + sectionSpacing + 92 + 12)
            : 200
        if abs(frame.height - height) > 1 {
            setFrameSize(NSSize(width: 320, height: height))
        }

        // Same top margin + row stack as update()'s live path.
        var yOffset: CGFloat = 12

        if let snapshot {
            yOffset += makeHeroRow(spent: snapshot.spentUSD, limit: snapshot.limitUSD, at: &yOffset)
            // Caption takes the pace-sentence slot (same 18pt line height).
            let age = snapshot.ageMinutes
            let ageText = age < 1 ? "Last reading · just now"
                : age < 60 ? "Last reading · \(age)m ago"
                : "Last reading · \(age / 60)h ago"
            yOffset += makePaceRow(ageText, at: &yOffset)
            yOffset += sectionSpacing
            // The real curve lane — today's history points, fully drawn. Same
            // 92pt slot as the live curve so the open height is final.
            yOffset += makeLoadingCurve(history: history, limit: snapshot.limitUSD, now: now, at: &yOffset)
            addVersionBullet()
            // Dimmed like a stale reading: it IS a cached figure until the
            // first fetch confirms it. Everything except chrome.
            for subview in managedSubviews where !(subview is NSButton) {
                subview.alphaValue = 0.55
            }
        } else {
            // True first run: no today reading to show. Centered spinner in
            // the same content region the cold-open path occupies, so the
            // panel opens at a matching height and the first real render is a
            // clean swap, not a jump.
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.frame = NSRect(x: (320 - 16) / 2, y: 110, width: 16, height: 16)
            spinner.startAnimation(nil)
            addSubview(spinner)
            managedSubviews.append(spinner)

            let connecting = NSTextField(labelWithString: "Connecting to AI Hub…")
            connecting.font = NSFont.systemFont(ofSize: 13)
            connecting.textColor = .secondaryLabelColor
            connecting.alignment = .center
            connecting.frame = NSRect(x: 0, y: 82, width: 320, height: 18)
            addSubview(connecting)
            managedSubviews.append(connecting)
            addVersionBullet()
        }
        // Frame was set to the final height up front, before layout — no
        // trailing resize here (that was the v0.3.4 blocker: subviews placed
        // against stale bounds got clipped when the panel shrank).
    }

    /// The loading path's curve: today's recorded history points in the same
    /// lane the live curve occupies (284×92, centered, below a TODAY label),
    /// fully drawn — no draw-on animation, this is a cached preview and the
    /// live open re-animates on top. Height includes the label so it matches
    /// the live section's total.
    private func makeLoadingCurve(history: HistoryStore, limit: Double, now: Date, at yOffset: inout CGFloat) -> CGFloat {
        let labelHeight: CGFloat = 14
        let label = NSTextField(labelWithString: "TODAY")
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .labelColor.withAlphaComponent(0.42)
        label.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - labelHeight, width: 50, height: labelHeight)
        addSubview(label)
        managedSubviews.append(label)

        let curveY = bounds.height - yOffset - labelHeight - sectionSpacing - 92
        let curve = CurveView(frame: NSRect(x: (320 - 284) / 2, y: curveY, width: 284, height: 92))
        curve.drawProgress = 1
        if let today = history.day(utcDate: now) {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            let utcHour = utcCalendar.component(.hour, from: now)
            curve.configure(hourly: today.hourly, limit: limit, nowHourUTC: utcHour, ghost: nil, drawGhostStroke: false)
        }
        addSubview(curve)
        managedSubviews.append(curve)

        return labelHeight + sectionSpacing + 92
    }

    private func makeHeroRow(spent: Double, limit: Double, isNeverFetched: Bool = false, at yOffset: inout CGFloat) -> CGFloat {
        let containerHeight: CGFloat = 36
        let container = NSView(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - containerHeight, width: 320 - 2 * sidePadding, height: containerHeight))
        addSubview(container)
        managedSubviews.append(container)

        // Reserve the FULL hero width even when neverFetched — "—" is
        // narrower than "$109.42", and without the reservation the first
        // poll's update shifts the whole layout (the visible jump).
        let heroText = isNeverFetched ? "$0.00" : String(format: "$%.2f", spent)
        let heroFont = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        let heroLabel = NSTextField(labelWithString: heroText)
        heroLabel.font = heroFont
        heroLabel.textColor = isNeverFetched ? .tertiaryLabelColor : .labelColor
        // Size the hero to its rendered width so the suffix sits right next
        // to it (fixed 150pt left a visible gap after the amount).
        let heroWidth = (heroText as NSString).size(withAttributes: [.font: heroFont]).width
        heroLabel.frame = NSRect(x: 0, y: 0, width: ceil(heroWidth) + 2, height: 30)
        container.addSubview(heroLabel)

        let suffixText = isNeverFetched ? " of $0 today" : String(format: " of $%.0f today", limit)
        let suffixLabel = NSTextField(labelWithString: suffixText)
        suffixLabel.font = NSFont.systemFont(ofSize: 15)
        suffixLabel.textColor = .secondaryLabelColor
        // Baseline-align: the 30pt hero's baseline sits ~7pt above its frame's
        // bottom; the 15pt suffix needs ~4pt to share that line. 8pt gap.
        suffixLabel.frame = NSRect(x: ceil(heroWidth) + 2 + 8, y: 5, width: container.bounds.width - ceil(heroWidth) - 10, height: 19)
        suffixLabel.isHidden = isNeverFetched
        container.addSubview(suffixLabel)

        return containerHeight
    }

    private func makePaceRow(_ sentence: String, at yOffset: inout CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: sentence)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        // The slot is a fixed 18pt single line (v0.4.3's equal-height
        // guarantee). PaceEngine keeps its sentences short, but if one ever
        // outgrows 284pt, truncate with an ellipsis instead of hard-clipping
        // a word in half (the "…3:38 ar" report).
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - 18, width: 320 - 2 * sidePadding, height: 18)
        addSubview(label)
        managedSubviews.append(label)
        return 18
    }

    private func makeHairline(at yOffset: inout CGFloat) -> CGFloat {
        let hairline = NSView(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - hairlineHeight, width: 320 - 2 * sidePadding, height: hairlineHeight))
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        addSubview(hairline)
        managedSubviews.append(hairline)
        return hairlineHeight
    }

    private func makeTodayLabelAndCurve(history: HistoryStore, limit: Double, usageResponse: UsageResponse?, isFresh: Bool, now: Date, at yOffset: inout CGFloat) -> CGFloat {
        let labelHeight: CGFloat = 14
        let label = NSTextField(labelWithString: "TODAY")
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .labelColor.withAlphaComponent(0.42)
        label.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - labelHeight, width: 50, height: labelHeight)
        addSubview(label)
        managedSubviews.append(label)

        // Curve view positioned below label.
        let curveY = bounds.height - yOffset - labelHeight - sectionSpacing - 92
        curveView.frame = NSRect(x: (320 - 284) / 2, y: curveY, width: 284, height: 92)

        // Read the GATEWAY's day, not the local clock's: history is keyed by
        // spend_date, and the two disagree around the UTC-midnight seam.
        // Without a response (loading state) there's no spend_date to ask
        // for, so the curve stays empty — correct, since there is no "today"
        // until the gateway tells us which day it's billing.
        let dayRecord = usageResponse.map { history.day(spendDate: $0.dailyBudget.spendDate) } ?? nil
        let hourly = dayRecord?.hourly ?? Array(repeating: nil, count: 24)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let utcHour = utcCalendar.component(.hour, from: now)
        // Ghost curve (v0.3.0): the median day behind today. The ghost is
        // COMPUTED whenever there's a response (so its peak always joins the
        // y-scale — otherwise the scale would visibly jump on every
        // fresh↔stale flap), but its STROKE only draws when fresh: a stale
        // response would pin the "typical day" shape against hours-old data.
        let ghost = usageResponse.map {
            PaceEngine.ghostCurve(in: history.allDays, excluding: $0.dailyBudget.spendDate)
        } ?? nil
        curveView.configure(hourly: hourly, limit: limit, nowHourUTC: utcHour, ghost: ghost, drawGhostStroke: isFresh)

        addSubview(curveView)
        managedSubviews.append(curveView)

        return labelHeight + sectionSpacing + 92
    }

    /// The 7-day strip (v0.5.2), placed directly above the footer hairline
    /// rather than under the curve. Why it moved out of the TODAY block: butted
    /// against the curve's baseline the cells read as part of the chart — a
    /// second, contradictory x-axis on the same lane. Its own section, sitting
    /// on the footer rule, reads as what it is: the week around today.
    ///
    /// Gates (unchanged from the under-curve version): a response must exist
    /// and be FRESH — a stale reading would pin the week's shape against
    /// hours-old data — and at least 4 of the 7 days must carry data, because a
    /// 3-day history renders as floating cells with no grid to read against.
    /// Silence over noise. Returns 0 (consuming no height) when gated off.
    private func makeDayStrip(history: HistoryStore, usageResponse: UsageResponse?, isFresh: Bool, at yOffset: inout CGFloat) -> CGFloat {
        guard let usage = usageResponse, isFresh else { return 0 }
        let week = DayStrip.week(in: history.allDays, today: usage.dailyBudget.spendDate)
        guard week.filter({ $0.total != nil }).count >= 4 else { return 0 }

        let strip = DayStripView(week: week, frame: NSRect(x: (320 - 284) / 2, y: bounds.height - yOffset - DayStripView.height, width: 284, height: DayStripView.height))
        addSubview(strip)
        // In managedSubviews (and not an NSButton), so the stale-alpha pass
        // dims it with the rest of the data — same as under the curve.
        managedSubviews.append(strip)
        return DayStripView.height + 6
    }

    private func makeModelsHeader(at yOffset: inout CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: "MODELS")
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .labelColor.withAlphaComponent(0.42)
        label.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - 14, width: 60, height: 14)
        addSubview(label)
        managedSubviews.append(label)

        // Spacer between label and switcher (12pt gap)
        yOffset += 12

        // Period switcher (v0.4.0): custom Today/Month tabs with a sliding
        // indicator, flush RIGHT at the content margin so the tabs read as
        // scoping the numbers below (the "tabs shifted from the numbers"
        // report — the old home pinned the right edge 66pt in, on the
        // efficiency column, visibly short of the rightmost figures).
        // CRITICAL: position the indicator WITHOUT animating here — update()
        // rebuilds all subviews every 60s, so an animated setSelected would
        // re-slide the indicator once a minute for no reason. Only a real
        // click animates (see the onSelect handler below).
        let switcher = PeriodSwitcher(labels: ["Today", "Month"])
        switcher.frame = NSRect(x: 320 - sidePadding - 118, y: bounds.height - yOffset - 20, width: 118, height: 20)
        switcher.onSelect = { [weak self] index in
            self?.periodSelected(index)
        }
        addSubview(switcher)
        managedSubviews.append(switcher)
        // Layout BEFORE snapping the indicator: setSelected positions the
        // indicator under the selected label, but labels are only framed in
        // layout(). Without this, a "Month"-selected rebuild computes the
        // indicator from unlaid-out labels (all at x=0) and shows it under
        // "Today" for a frame before layout() corrects it.
        switcher.layoutSubtreeIfNeeded()
        switcher.setSelected(selectedPeriod == .today ? 0 : 1, animated: false)
        return 26   // 20pt control + 6pt air before the rows below
    }

    /// Today's total spend as a single row — used when the per-model split
    /// isn't shown (stale data, or the split is unavailable today). `note`
    /// overrides the quiet sub-line; nil falls back to the plain "monthly
    /// only" explanation.
    /// v0.4.3: returns the FULL models-block height (maxModelRows × the 32pt
    /// row stride), not just the row+note's visible height — the split and
    /// Month branches consume one stride per rendered row plus one per padded
    /// slot, so the total row + note must claim the same 160pt or a tab
    /// switch in the stale/unavailable state would resize the card.
    private func makeTodayTotalRow(spent: Double, note: String? = nil, at yOffset: inout CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 24
        let totalLabel = NSTextField(labelWithString: String(format: "$%.2f across all models", spent))
        totalLabel.font = NSFont.systemFont(ofSize: 13)
        totalLabel.textColor = .labelColor
        totalLabel.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - rowHeight, width: 320 - 2 * sidePadding, height: rowHeight)
        addSubview(totalLabel)
        managedSubviews.append(totalLabel)

        let noteLabel = NSTextField(labelWithString: note ?? "Per-model breakdown is monthly only")
        noteLabel.font = NSFont.systemFont(ofSize: 10.5)
        noteLabel.textColor = .labelColor.withAlphaComponent(0.40)
        noteLabel.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - rowHeight - 16, width: 320 - 2 * sidePadding, height: 14)
        addSubview(noteLabel)
        managedSubviews.append(noteLabel)
        return Self.modelRowSlotHeight * CGFloat(Self.maxModelRows)
    }

    /// One model row (v0.5.0). The 2pt proportional bar is gone — it restated
    /// the cost column as decoration and its variable right edge was half the
    /// column-raggedness problem. Its "which model dominates" answer now lives
    /// inline in the name as a dim ` · 62%` share-of-period-spend, computed by
    /// the caller (period-aware: Today shares the day total, Month the month).
    /// `showsShare` is false only for the "Other" residual bucket — it isn't a
    /// model, so a share would imply a magnitude the number doesn't carry.
    ///
    /// Columns, left to right: name+share (flexible, truncating) · cost
    /// (tabular, right) · $/M efficiency (tabular, right). Both number columns
    /// use monospacedDigitSystemFont so their right edges and decimal points
    /// stack into true columns — the hero already proved this is what makes
    /// figures read as aligned (the old proportional face left a wavy edge).
    private func makeModelRow(name: String, cost: Double, tokens: Double, sharePercent: Int, showsShare: Bool = true, at yOffset: inout CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 24

        // Name + share, one attributed label so a long model name truncates
        // with the share still attached. Share is dimmer + smaller so it reads
        // as a qualifier, not a second name.
        let nameFont = NSFont.systemFont(ofSize: 13)
        let nameAttr = NSMutableAttributedString(string: name, attributes: [
            .font: nameFont,
            .foregroundColor: NSColor.labelColor,
        ])
        if showsShare {
            nameAttr.append(NSAttributedString(string: " · \(sharePercent)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.40),
            ]))
        }
        let nameLabel = NSTextField(labelWithAttributedString: nameAttr)
        nameLabel.lineBreakMode = .byTruncatingTail
        // 152pt: the clear-space arithmetic is 320 - 18 (left pad) - 66 (cost)
        // - 66 (efficiency) - 18 (right pad) = 152. A longer budget would
        // overlap the cost column's frame. A long name truncates its tail
        // rather than push the number columns — the provider prefix is
        // already stripped, so the meaningful part leads.
        nameLabel.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - rowHeight, width: 152, height: rowHeight)
        addSubview(nameLabel)
        managedSubviews.append(nameLabel)

        // Cost (13pt tabular digits, right-aligned, 66 wide). Right-aligned +
        // tabular figures is what stacks the decimal points down the column.
        // 66pt clears the worst case ($9,999.99 = 64.4pt measured) with margin.
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", cost))
        costLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.frame = NSRect(x: 320 - sidePadding - 66 - 66, y: bounds.height - yOffset - rowHeight, width: 66, height: rowHeight)
        addSubview(costLabel)
        managedSubviews.append(costLabel)

        // Efficiency (11pt tabular digits, 40% alpha, right, 64 wide): cost
        // per million tokens. Raw token counts are a vanity metric — two
        // models can burn the same tokens at wildly different prices, so $/1M
        // tok is the number that actually compares them. Tokens == 0 (no
        // usage) shows an em-dash rather than a divide-by-zero or a
        // meaningless $0.00. Past $999/M the label switches to compact form
        // ("$1.2k/M") so a new model with a handful of expensive calls
        // doesn't clip the column. Dropped 2pt so its baseline sits on the
        // 13pt cost baseline (the two fonts' first baselines differ by ~2pt).
        let efficiencyText: String
        if tokens > 0 {
            let perMillion = cost / (tokens / 1_000_000)
            if perMillion >= 1000 {
                efficiencyText = String(format: "$%.1fk/M", perMillion / 1000)
            } else {
                efficiencyText = String(format: "$%.2f/M", perMillion)
            }
        } else {
            efficiencyText = "—"
        }

        let tokenLabel = NSTextField(labelWithString: efficiencyText)
        tokenLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tokenLabel.textColor = .labelColor.withAlphaComponent(0.40)
        tokenLabel.alignment = .right
        // 66pt clears the worst case ($999.99k/M = 64.4pt measured).
        tokenLabel.frame = NSRect(x: 320 - sidePadding - 66, y: bounds.height - yOffset - rowHeight - 2, width: 66, height: rowHeight)
        addSubview(tokenLabel)
        managedSubviews.append(tokenLabel)

        return rowHeight + 8
    }

    private func makeStaleBanner(minutesOld: Int, at yOffset: inout CGFloat) -> CGFloat {
        let bannerHeight: CGFloat = 40
        let banner = NSView(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - bannerHeight, width: 320 - 2 * sidePadding, height: bannerHeight))
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        banner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.cornerRadius = 7

        let text = "AI Hub unreachable — retrying. Data is \(minutesOld) min old."
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 8)
        label.textColor = .labelColor
        label.frame = NSRect(x: 8, y: 8, width: banner.bounds.width - 16, height: banner.bounds.height - 16)
        banner.addSubview(label)

        addSubview(banner)
        managedSubviews.append(banner)
        return bannerHeight
    }

    private func makeFooter(isFresh: Bool, lastSuccessAt: Date?, now: Date, at yOffset: inout CGFloat) -> CGFloat {
        let footerHeight: CGFloat = 20
        let rowY = bounds.height - yOffset - footerHeight

        // All the horizontal arithmetic lives in VelaCore.FooterLayout, which is
        // unit-tested; this method only measures glyphs and hangs views on the
        // result. Why the split: this row produced two bug reports in a row —
        // "✓ Start at login" overlapping the green dot, then a "fix" that moved
        // the link CLOSER, because the dot is right-anchored while the link sat
        // at a hardcoded x. The gaps are named inputs now, and the invariants
        // (nothing overlaps; the login→dot gap is identical in both ✓ states)
        // are pinned by FooterLayoutTests instead of eyeballed on a screenshot.
        //
        // Widths are MEASURED. The old hardcoded frames (78pt for 75pt of
        // "Dashboard ↗", 56pt for 42pt of "API key") reserved 17pt of invisible
        // padding, which was exactly the space the login↔dot gap needed: the row
        // was over-subscribed, so opening a gap on the right could only be paid
        // for by overlapping something on the left.
        let linkFont = NSFont.systemFont(ofSize: 12)
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func measure(_ title: String, _ font: NSFont) -> CGFloat {
            ceil((title as NSString).size(withAttributes: [.font: font]).width)
        }

        let atLogin = SMAppService.mainApp.status == .enabled
        let loginTitle = atLogin ? "✓ Start at login" : "Start at login"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let statusText = "AI Hub · " + (isFresh ? "" : "stale ") + formatter.string(from: lastSuccessAt ?? now)

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
                totalWidth: 320,
                sidePadding: sidePadding,
                linkSpacing: Self.linkSpacing,
                linkGutter: Self.linkGutter,
                loginToDotGap: Self.loginToDotGap,
                dotToStatus: 12
            )
        )

        // Borderless link-style buttons -- chrome stays quiet per the design.
        let dashboardButton = Self.makeLinkButton(title: "Dashboard ↗", frame: NSRect(x: layout.dashboard.x, y: rowY, width: layout.dashboard.width, height: footerHeight))
        dashboardButton.target = self
        dashboardButton.action = #selector(openDashboard)
        addSubview(dashboardButton)
        managedSubviews.append(dashboardButton)

        let apiKeyButton = Self.makeLinkButton(title: "API key", frame: NSRect(x: layout.apiKey.x, y: rowY, width: layout.apiKey.width, height: footerHeight))
        apiKeyButton.target = self
        apiKeyButton.action = #selector(replaceTokenTapped)
        addSubview(apiKeyButton)
        managedSubviews.append(apiKeyButton)

        // Launch-at-login toggle: a quiet text link that reflects and flips
        // SMAppService registration. The checkmark shows current state; the link
        // hangs off the health DOT (see FooterLayout), so the space beside the
        // dot is a stated constant rather than whatever happened to be left.
        let loginButton = Self.makeLinkButton(title: loginTitle, frame: NSRect(x: layout.login.x, y: rowY, width: layout.login.width, height: footerHeight))
        loginButton.target = self
        loginButton.action = #selector(toggleLaunchAtLogin)
        addSubview(loginButton)
        managedSubviews.append(loginButton)

        // Health unit, right-aligned as ONE group: dot + "AI Hub · time". The
        // timestamp yields to a bare "AI Hub" when the row is tight — the exact
        // time is nice-to-have, the clearances are not.
        let dotColor: NSColor = isFresh ? .systemGreen : (lastSuccessAt != nil ? .systemOrange : .labelColor.withAlphaComponent(0.35))
        let finalStatusText = layout.showsTimestamp ? statusText : "AI Hub"

        let statusLabel = NSTextField(labelWithString: finalStatusText)
        statusLabel.font = statusFont
        statusLabel.textColor = .labelColor.withAlphaComponent(0.38)
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: layout.statusX, y: rowY + 3, width: 320 - sidePadding - layout.statusX, height: 14)
        // Same right-anchor pin as the version dot: the footer's health unit is
        // right-anchored, so it must track the window-frame open animation or it
        // sits 13pt in from the edge (and collides with the login button) until
        // the first poll re-anchors it.
        statusLabel.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(statusLabel)
        managedSubviews.append(statusLabel)

        let dot = NSView(frame: NSRect(x: layout.dotX, y: rowY + 6, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(dot)
        managedSubviews.append(dot)

        return footerHeight
    }

    /// Borderless button that looks like quiet text, not chrome.
    /// Centres its title, so a frame `linkGutter` wider than the glyphs leaves
    /// exactly half that slack on each side — the arithmetic makeFooter's
    /// login↔dot gap relies on.
    private static func makeLinkButton(title: String, frame: NSRect) -> NSButton {
        let button = NSButton(frame: frame)
        button.setButtonType(.momentaryLight)
        button.isBordered = false
        button.bezelStyle = .inline
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.65),
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return button
    }

    /// Clear space the footer keeps between the "Start at login" link's FRAME
    /// and the health dot. Each link frame carries linkGutter/2 of dead padding
    /// a side, so the space the eye actually sees between the last letter and
    /// the dot is this + linkGutter/2 = 14pt.
    /// THIS is the single constant to change to re-tune that gap. Note the row
    /// is genuinely tight in the "✓ Start at login" state — at 320pt there are
    /// only ~20pt of slack for all three gaps — so raising this much past 12
    /// has to come out of the gap left of the login link.
    private static let loginToDotGap: CGFloat = 12

    /// Clear space between two adjacent footer links' FRAMES (so linkGutter/2
    /// more between their glyphs). Kept modest so the login↔dot gap above —
    /// the one the user reads as "is the ✓ crowding the dot" — gets the slack.
    private static let linkSpacing: CGFloat = 5

    /// Slack added around a link button's measured title so a borderless
    /// button never clips its own tail (AppKit insets the glyphs ~2pt a side).
    /// FooterLayout applies this to every measured width.
    private static let linkGutter: CGFloat = 4

    /// The top-right version bullet: a 6pt dot that shows "vX.Y.Z" plus the
    /// embedded what's-new list on hover. Custom-drawn tip (VersionBulletView)
    /// because this popover is a nonactivating panel — native tooltips never
    /// fire on windows that can't become key (the v0.3.2 report).
    private func addVersionBullet() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let hitSize: CGFloat = 20
        let margin: CGFloat = 6

        let bullet = VersionBulletView(version: version, notes: Self.whatsNew)
        // Pin with autoresizing, NOT a bounds-derived x: the open animation
        // resizes the WINDOW frame (width and height 0.96×→1.0× together), so
        // any x computed from a bounds read is only right at one instant — a
        // static pin ends up in from the edge (and a bounds/0.96 pin clipped
        // OUT of the narrowing window). minXMargin + minYMargin anchor the dot
        // to the top-right corner through every resize, settle included.
        bullet.autoresizingMask = [.minXMargin, .minYMargin]
        bullet.frame = NSRect(x: bounds.width - margin - hitSize, y: bounds.height - margin - hitSize, width: hitSize, height: hitSize)
        addSubview(bullet)
        managedSubviews.append(bullet)

        // The update bell (v1.0.0) sits immediately LEFT of the version dot and
        // is now ALWAYS present. It used to appear only while a newer release
        // was known, which meant its absence carried no information — you
        // couldn't tell "up to date" from "the bell hasn't checked / doesn't
        // exist". A permanent light that is grey-and-still when current, and
        // yellow-and-rocking when not, makes "no news" readable. The checker
        // re-renders the popover when that state changes, so the bell's look
        // always reflects the latest fetch or skip.
        let bell = UpdateBellView(release: updateChecker?.pendingRelease, runningVersion: version)
        bell.onSkip = { [weak self] in
            self?.updateChecker?.skipCurrent()
        }
        // Every card action (copy, release notes, skip) ends the update
        // moment — the popover goes with it, never a card over empty air.
        bell.onOpenRelease = { [weak self] in
            self?.onRequestDismiss?()
        }
        bell.autoresizingMask = [.minXMargin, .minYMargin]
        // Derived from the same top-right corner arithmetic as the dot, one
        // slot to its left — NOT read off `bullet.frame`. Same numbers, but
        // it can't be broken by someone reordering these two blocks, and it
        // states the intent ("second chrome slot from the corner") instead
        // of chaining off a sibling that happens to be positioned already.
        bell.frame = NSRect(x: bounds.width - margin - 2 * hitSize - 4, y: bounds.height - margin - hitSize, width: hitSize, height: hitSize)
        addSubview(bell)
        managedSubviews.append(bell)
        // Chrome is added AFTER the stale-alpha dimming pass (this whole
        // method runs after it), so dot and bell land full-strength.
    }


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
        // Re-render so the checkmark follows reality. The old code set
        // needsDisplay, but the ✓ is baked into the button TITLE (makeFooter
        // reads SMAppService status) — needsDisplay redraws pixels, it does
        // not rebuild the title, so the mark stayed stale until the next
        // poll. Rebuild via the same path periodChanged() uses; makeFooter
        // re-reads the live status, so the checkmark is always true.
        guard let history = latestHistory else { return }
        update(state: latestState, history: history,
               exhaustedAt: latestExhaustedAt, lastSuccessAt: latestSuccessAt, now: Date(), todayModelSplit: latestModelSplit)
    }

    /// Swaps the popover into token-entry mode. Deliberately does NOT copy
    /// the token to the pasteboard — the general pasteboard is readable by
    /// every process and syncs via Universal Clipboard, so a silent copy of
    /// a spend-capable token is a leak. The token stays in the Keychain;
    /// colleagues who need it for curl paste a fresh one here.
    @objc private func replaceTokenTapped() {
        onReplaceToken?()
    }

    /// Called by PeriodSwitcher after a real click (the indicator has already
    /// started sliding to the tapped tab). v0.4.0: replaces the @objc
    /// periodChanged that NSSegmentedControl targeted — selection now arrives
    /// as an index.
    ///
    /// The rebuild is deferred past the indicator's 0.2s slide: update() begins
    /// by removing ALL subviews, so rebuilding synchronously would destroy the
    /// switcher mid-slide and the indicator would jump instead of gliding.
    /// Letting the slide commit first keeps the motion visible; the rebuild
    /// then re-asserts the same selection (positioned, not re-slid) on the
    /// fresh switcher.
    ///
    /// v0.4.3: the morph is gone. v0.4.1/0.4.2 tried to choreograph a period
    /// switch whose content height DIFFERED — and every attempt (coordinated
    /// settle, then a bitmap morph) fought the bottom-anchored rows re-laying
    /// out against a moving bounds. The real fix is that there is no height
    /// change to choreograph: both periods render the same sections at the
    /// same height (constant model rows, reserved pace slot), so a tap is just
    /// the indicator slide plus an in-place content rebuild. Nothing resizes,
    /// nothing re-flows, the top edge and the curve never move — and the whole
    /// class of shake/clip bugs is designed out rather than animated around.
    ///
    /// The generation guard survives the cleanup: rapid Today→Month→Today taps
    /// each queue a deferred rebuild, and without the guard the FIRST tap's
    /// rebuild would land mid-way through the SECOND tap's indicator slide and
    /// destroy the switcher mid-glide — the exact blink the defer exists to
    /// prevent. Only the latest tap's rebuild runs. Under Reduce Motion the
    /// indicator snaps instantly (no slide to wait past), so the defer drops
    /// to zero rather than adding 210ms of dead latency.
    private var periodRebuildGeneration = 0
    private func periodSelected(_ index: Int) {
        selectedPeriod = (index == 0) ? .today : .month
        guard let history = latestHistory else { return }
        periodRebuildGeneration += 1
        let generation = periodRebuildGeneration
        let delay: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.21
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.periodRebuildGeneration == generation else { return }
            // Re-render from the REAL last state — never re-wrap latestResponse
            // as .fresh. If the gateway is unreachable the reading is .stale,
            // and the banner / amber dot / dimming must survive a period toggle.
            self.update(state: self.latestState, history: history,
                        exhaustedAt: self.latestExhaustedAt, lastSuccessAt: self.latestSuccessAt,
                        now: Date(), todayModelSplit: self.latestModelSplit)
        }
    }

    /// Aggregates model usage over the selected window. Month: the API's
    /// top_models (current-month per-model breakdown). Today: the gateway
    /// doesn't return per-day model splits, so this returns empty and the
    /// section shows today's total + a note instead of a fake list.
    private func aggregatedModels(response: UsageResponse?, history: HistoryStore, now: Date) -> [(model: String, totalCostUSD: Double, totalTokens: Int)] {
        guard let response else { return [] }
        switch selectedPeriod {
        case .month:
            return response.topModels.map { (model: $0.model, totalCostUSD: $0.totalCostUSD, totalTokens: $0.totalTokens) }
        case .today:
            return []
        }
    }
}
