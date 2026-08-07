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

    let curveView = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))   // internal: PopoverPanel/main drive the draw-on animation
    private var managedSubviews: [NSView] = []

    /// Which window the models list aggregates over. Today/Week compute from
    /// local history (the API has no period param); Month uses the API's
    /// current_month + top_models directly.
    private enum ModelPeriod: Int { case today = 0, month = 1 }
    private var selectedPeriod: ModelPeriod = .today
    private weak var periodControl: NSSegmentedControl?
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

    private let sidePadding: CGFloat = 18
    private let sectionSpacing: CGFloat = 12
    private let hairlineHeight: CGFloat = 0.5

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        self.managedSubviews = []
    }

    public required init?(coder: NSCoder) {
        fatalError("PopoverView does not support NSCoder-based initialization")
    }

    private var isRelayout = false

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
            return
        }
        latestResponse = usageResponse
        latestHistory = history
        latestState = state
        latestExhaustedAt = exhaustedAt
        latestSuccessAt = lastSuccessAt
        latestModelSplit = todayModelSplit
        // If no draw-on animation is in flight, the curve must be fully
        // visible — poll-triggered updates shouldn't leave it half-drawn.
        if !curveAnimationRunning && curveView.drawProgress == 0 {
            curveView.drawProgress = 1
        }

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
                exhaustedAt: exhaustedAt
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
            if isFresh, let runway = PaceEngine.monthRunway(monthSpent: usage.currentMonth.totalCostUSD, now: now) {
                yOffset += makePaceRow(runway, at: &yOffset)
            }
        } else {
            yOffset += makePaceRow("No data yet.", at: &yOffset)
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

        // 6. Models header + rows (aggregated over the chosen period)
        let modelsForPeriod = aggregatedModels(response: usageResponse, history: history, now: now)
        yOffset += makeModelsHeader(at: &yOffset)
        if selectedPeriod == .today, let usage = usageResponse {
            // Today segment, three states. The split is the snapshot-derived
            // per-model breakdown (v0.3.0) — only trustable when the data is
            // fresh, so a stale reading falls back to the honest total-only
            // row and never shows a derived split against hours-old data.
            if isFresh, case .split(let s) = todayModelSplit {
                // Bars normalize against the largest NAMED cost — Other is a
                // residual bucket, not a model, so it must not set the scale.
                let maxNamedCost = s.rows.filter { !$0.isOther }.map(\.costUSD).max() ?? 1
                for row in s.rows.prefix(5) {
                    let displayName = row.name.split(separator: "/").last.map(String.init) ?? row.name
                    yOffset += makeModelRow(name: displayName, cost: row.costUSD, tokens: Double(row.tokens), maxCost: maxNamedCost, showsBar: !row.isOther, at: &yOffset)
                }
            } else if isFresh, case .unavailable(let reason) = todayModelSplit {
                // Fresh but not derivable (first day, month seam, gap): the
                // honest total plus WHY there's no split. noSpendYet's nil
                // note keeps the plain "monthly only" line.
                yOffset += makeTodayTotalRow(spent: usage.dailyBudget.spentUSD, note: reason.note, at: &yOffset)
            } else {
                // Stale: total only, no split note — the banner already says
                // the data is old, and a split note would claim a freshness
                // the rows below don't have.
                yOffset += makeTodayTotalRow(spent: usage.dailyBudget.spentUSD, note: nil, at: &yOffset)
            }
        } else if !modelsForPeriod.isEmpty {
            for model in modelsForPeriod.prefix(5) {
                // Display strips the provider prefix ("moonshotai/kimi-k3" -> "kimi-k3").
                let displayName = model.model.split(separator: "/").last.map(String.init) ?? model.model
                yOffset += makeModelRow(name: displayName, cost: model.totalCostUSD, tokens: Double(model.totalTokens), maxCost: modelsForPeriod.first?.totalCostUSD ?? 1, at: &yOffset)
            }
        }

        yOffset += sectionSpacing

        // 7. Stale note (if applicable)
        if !isFresh && usageResponse != nil, let lastSuccess = lastSuccessAt {
            let minutesOld = Int(now.timeIntervalSince(lastSuccess) / 60)
            yOffset += makeStaleBanner(minutesOld: minutesOld, at: &yOffset)
            yOffset += 6
        }

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

        // Size the view to its content so the panel never leaves dead space
        // below the footer (the stale banner used to overflow the fixed 480).
        let contentHeight = yOffset + 12
        if abs(frame.height - contentHeight) > 1 && !isRelayout {
            setFrameSize(NSSize(width: 320, height: contentHeight))
            // The panel tracks its content's height.
            if let panel = window as? NSPanel {
                var panelFrame = panel.frame
                let delta = contentHeight - panelFrame.height
                panelFrame.size.height = contentHeight
                panelFrame.origin.y -= delta   // keep the top edge anchored
                panel.setFrame(panelFrame, display: true, animate: false)
            }
            // Rows were laid out against the OLD height — re-lay against the
            // new one so the hero isn't cut off on first open.
            isRelayout = true
            update(state: state, history: history, exhaustedAt: exhaustedAt, lastSuccessAt: lastSuccessAt, now: now, todayModelSplit: todayModelSplit)
            isRelayout = false
        }
    }

    /// Draw-on animation for the curve, run once per popover open (Task 13).
    /// Steps drawProgress 0 -> 1 over ~0.5s with an ease-out feel (fewer,
    /// larger steps toward the end). Reduce Motion callers skip this and
    /// leave drawProgress at 1.
    private var curveAnimationItems: [DispatchWorkItem] = []
    private var curveAnimationRunning = false

    public func animateCurveDrawOn() {
        curveAnimationRunning = true
        // Cancel any in-flight steps (a reopen or a poll mid-animation
        // would otherwise race and leave the curve half-drawn).
        curveAnimationItems.forEach { $0.cancel() }
        curveAnimationItems.removeAll()
        curveView.drawProgress = 0
        let steps = 14
        for i in 1...steps {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Ease-out: t^0.5 curve so the leading edge decelerates.
                let t = sqrt(CGFloat(i) / CGFloat(steps))
                self.curveView.drawProgress = t
                if i == steps { self.curveAnimationRunning = false }
            }
            curveAnimationItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * (0.5 / Double(steps)), execute: work)
        }
    }

    /// Loading state for the very first open (state == .neverFetched):
    /// spinner + "Connecting to AI Hub…" centered in the fixed 320x480 frame.
    /// main.swift calls this instead of building a separate throwaway panel,
    /// so the loading view and the first real render share ONE panel — the
    /// only resize is the single shrink-to-content when real data lands.
    func renderLoadingState() {
        update(state: .neverFetched, history: HistoryStore(directory: URL(fileURLWithPath: "/")),
               exhaustedAt: nil, lastSuccessAt: nil, now: Date())
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
        // Ghost curve (v0.3.0): the median day behind today. Only when fresh —
        // a stale response would pin the "now" tick against hours-old data.
        let ghost: [Double?]?
        if isFresh, let usage = usageResponse {
            ghost = PaceEngine.ghostCurve(in: history.allDays, excluding: usage.dailyBudget.spendDate)
        } else {
            ghost = nil
        }
        curveView.configure(hourly: hourly, limit: limit, nowHourUTC: utcHour, ghost: ghost)

        addSubview(curveView)
        managedSubviews.append(curveView)

        // 7-day strip (v0.3.0): hairline bars under the curve, one per
        // gateway day ending at today. Same freshness gate as the ghost.
        var stripHeight: CGFloat = 0
        if let usage = usageResponse, isFresh {
            let week = DayStrip.week(in: history.allDays, today: usage.dailyBudget.spendDate)
            let stripY = curveY - 6 - DayStripView.height
            let strip = DayStripView(week: week, frame: NSRect(x: (320 - 284) / 2, y: stripY, width: 284, height: DayStripView.height))
            addSubview(strip)
            managedSubviews.append(strip)
            stripHeight = DayStripView.height + 6
        }

        return labelHeight + sectionSpacing + 92 + stripHeight
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

        // Period switcher: segmented Today / Week / Month on the right.
        let control = NSSegmentedControl(
            labels: ["Today", "Month"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(periodChanged)
        )
        control.selectedSegment = selectedPeriod == .today ? 0 : 1
        control.frame = NSRect(x: 320 - sidePadding - 118, y: bounds.height - yOffset - 20, width: 118, height: 20)
        control.controlSize = .small
        addSubview(control)
        managedSubviews.append(control)
        self.periodControl = control
        return 26   // 20pt control + 6pt air before the rows below
    }

    /// Today's total spend as a single row — used when the per-model split
    /// isn't shown (stale data, or the split is unavailable today). `note`
    /// overrides the quiet sub-line; nil falls back to the plain "monthly
    /// only" explanation.
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
        return rowHeight + 24
    }

    private func makeModelRow(name: String, cost: Double, tokens: Double, maxCost: Double, showsBar: Bool = true, at yOffset: inout CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 24

        // Name (13pt, 118 wide)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - rowHeight, width: 118, height: rowHeight)
        addSubview(nameLabel)
        managedSubviews.append(nameLabel)

        // Bar (2pt tall, width proportional to cost). The "Other" residual
        // bucket passes showsBar=false — it isn't a model, so a bar would
        // imply a magnitude the number doesn't carry.
        if showsBar {
            // Capped so the bar never reaches the cost label (starts x=194;
            // bar starts x=138; 8pt gap -> 48pt max). Pre-cap it ran 100pt
            // and cut straight through the dollar figure on the top model.
            let barWidth = maxCost > 0 ? min(CGFloat(cost / maxCost) * 100, 48) : 0
            let bar = NSView(frame: NSRect(x: sidePadding + 120, y: bounds.height - yOffset - 8, width: barWidth, height: 2))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.labelColor.cgColor
            addSubview(bar)
            managedSubviews.append(bar)
        }

        // Cost (13pt, tabular right, 52 wide; sits left of the 64pt
        // efficiency column, so its x accounts for the wider right column).
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", cost))
        costLabel.font = NSFont.systemFont(ofSize: 13)
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.frame = NSRect(x: 320 - sidePadding - 52 - 64, y: bounds.height - yOffset - rowHeight, width: 52, height: rowHeight)
        addSubview(costLabel)
        managedSubviews.append(costLabel)

        // Efficiency (11pt, 40% alpha, right, 64 wide): cost per million
        // tokens. Raw token counts are a vanity metric — two models can burn
        // the same tokens at wildly different prices, so $/1M tok is the
        // number that actually compares them. Tokens == 0 (no usage) shows
        // an em-dash rather than a divide-by-zero or a meaningless $0.00.
        // Past $999/M the label switches to compact form ("$1.2k/M") so a
        // new model with a handful of expensive calls doesn't clip the column.
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
        tokenLabel.font = NSFont.systemFont(ofSize: 11)
        tokenLabel.textColor = .labelColor.withAlphaComponent(0.40)
        tokenLabel.alignment = .right
        tokenLabel.frame = NSRect(x: 320 - sidePadding - 64, y: bounds.height - yOffset - rowHeight, width: 64, height: rowHeight)
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

        // Borderless link-style buttons -- chrome stays quiet per the design.
        let dashboardButton = Self.makeLinkButton(title: "Dashboard ↗", frame: NSRect(x: sidePadding, y: bounds.height - yOffset - footerHeight, width: 78, height: footerHeight))
        dashboardButton.target = self
        dashboardButton.action = #selector(openDashboard)
        addSubview(dashboardButton)
        managedSubviews.append(dashboardButton)

        let apiKeyButton = Self.makeLinkButton(title: "API key", frame: NSRect(x: sidePadding + 84, y: bounds.height - yOffset - footerHeight, width: 56, height: footerHeight))
        apiKeyButton.target = self
        apiKeyButton.action = #selector(replaceTokenTapped)
        addSubview(apiKeyButton)
        managedSubviews.append(apiKeyButton)

        // Launch-at-login toggle: a quiet text link that reflects and flips
        // SMAppService registration. The checkmark shows current state.
        let atLogin = SMAppService.mainApp.status == .enabled
        let loginTitle = atLogin ? "✓ Start at login" : "Start at login"
        let loginButton = Self.makeLinkButton(title: loginTitle, frame: NSRect(x: sidePadding + 146, y: bounds.height - yOffset - footerHeight, width: 96, height: footerHeight))
        loginButton.target = self
        loginButton.action = #selector(toggleLaunchAtLogin)
        addSubview(loginButton)
        managedSubviews.append(loginButton)

        // Health unit, right-aligned as ONE group: dot + "AI Hub · time".
        let dotColor: NSColor = isFresh ? .systemGreen : (lastSuccessAt != nil ? .systemOrange : .labelColor.withAlphaComponent(0.35))

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let statusText = "AI Hub · " + (isFresh ? "" : "stale ") + formatter.string(from: now)
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let statusWidth = ceil((statusText as NSString).size(withAttributes: [.font: statusFont]).width)

        // The left button group ends at sidePadding+146+96; the health unit
        // right-anchors. If they'd collide (long timestamp), fall back to
        // dot + "AI Hub" only — the exact time is nice-to-have, not chrome.
        let leftGroupEnd = sidePadding + 146 + 96
        let healthFits = (320 - sidePadding - statusWidth - 12) > leftGroupEnd
        let finalStatusText = healthFits ? statusText : "AI Hub"
        let finalStatusWidth = healthFits ? statusWidth : ceil((finalStatusText as NSString).size(withAttributes: [.font: statusFont]).width)

        let statusLabel = NSTextField(labelWithString: finalStatusText)
        statusLabel.font = statusFont
        statusLabel.textColor = .labelColor.withAlphaComponent(0.38)
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: 320 - sidePadding - finalStatusWidth, y: bounds.height - yOffset - footerHeight + 3, width: finalStatusWidth, height: 14)
        addSubview(statusLabel)
        managedSubviews.append(statusLabel)

        let dot = NSView(frame: NSRect(x: 320 - sidePadding - finalStatusWidth - 12, y: bounds.height - yOffset - footerHeight + 6, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)
        managedSubviews.append(dot)

        return footerHeight
    }

    /// Borderless button that looks like quiet text, not chrome.
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
        // Re-render the footer immediately so the checkmark follows reality.
        if let panel = window as? PopoverPanel { panel.contentView?.needsDisplay = true }
    }

    /// Swaps the popover into token-entry mode. Deliberately does NOT copy
    /// the token to the pasteboard — the general pasteboard is readable by
    /// every process and syncs via Universal Clipboard, so a silent copy of
    /// a spend-capable token is a leak. The token stays in the Keychain;
    /// colleagues who need it for curl paste a fresh one here.
    @objc private func replaceTokenTapped() {
        onReplaceToken?()
    }

    @objc private func periodChanged() {
        selectedPeriod = (periodControl?.selectedSegment == 0) ? .today : .month
        guard let history = latestHistory else { return }
        // Re-render from the REAL last state — never re-wrap latestResponse as
        // .fresh. If the gateway is unreachable the reading is .stale, and the
        // banner / amber dot / dimming must survive a period toggle.
        update(state: latestState, history: history,
               exhaustedAt: latestExhaustedAt, lastSuccessAt: latestSuccessAt, now: Date(), todayModelSplit: latestModelSplit)
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
