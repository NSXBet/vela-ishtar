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

    public func update(state: PollState, history: HistoryStore, exhaustedAt: Date?, lastSuccessAt: Date?, now: Date) {
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
            let paceSentence = PaceEngine.sentence(for: paceVerdict, now: now)
            yOffset += makePaceRow(paceSentence, at: &yOffset)
        } else {
            yOffset += makePaceRow("No data yet.", at: &yOffset)
        }

        yOffset += sectionSpacing

        // 3. Hairline
        yOffset += makeHairline(at: &yOffset)
        yOffset += sectionSpacing

        // 4. "TODAY" + CurveView
        yOffset += makeTodayLabelAndCurve(history: history, limit: usageResponse?.dailyBudget.limitUSD ?? 0, now: now, at: &yOffset)
        yOffset += sectionSpacing

        // 5. Hairline
        yOffset += makeHairline(at: &yOffset)
        yOffset += sectionSpacing

        // 6. Models header + top 5 rows
        if let topModels = usageResponse?.topModels, !topModels.isEmpty {
            yOffset += makeModelsHeader(at: &yOffset)
            for model in topModels.prefix(5) {
                // Display strips the provider prefix ("moonshotai/kimi-k3" -> "kimi-k3").
                let displayName = model.model.split(separator: "/").last.map(String.init) ?? model.model
                yOffset += makeModelRow(name: displayName, cost: model.totalCostUSD, tokens: Double(model.totalTokens), maxCost: topModels.first?.totalCostUSD ?? 1, at: &yOffset)
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
    }

    /// Draw-on animation for the curve, run once per popover open (Task 13).
    /// Steps drawProgress 0 -> 1 over ~0.5s with an ease-out feel (fewer,
    /// larger steps toward the end). Reduce Motion callers skip this and
    /// leave drawProgress at 1.
    public func animateCurveDrawOn() {
        curveView.drawProgress = 0
        let steps = 14
        for i in 1...steps {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Ease-out: t^0.5 curve so the leading edge decelerates.
                let t = sqrt(CGFloat(i) / CGFloat(steps))
                self.curveView.drawProgress = t
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * (0.5 / Double(steps)), execute: work)
        }
    }

    private func makeHeroRow(spent: Double, limit: Double, isNeverFetched: Bool = false, at yOffset: inout CGFloat) -> CGFloat {
        let containerHeight: CGFloat = 36
        let container = NSView(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - containerHeight, width: 320 - 2 * sidePadding, height: containerHeight))
        addSubview(container)
        managedSubviews.append(container)

        let heroText = isNeverFetched ? "—" : String(format: "$%.2f", spent)
        let heroFont = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        let heroLabel = NSTextField(labelWithString: heroText)
        heroLabel.font = heroFont
        heroLabel.textColor = .labelColor
        // Size the hero to its rendered width so the suffix sits right next
        // to it (fixed 150pt left a visible gap after the amount).
        let heroWidth = (heroText as NSString).size(withAttributes: [.font: heroFont]).width
        heroLabel.frame = NSRect(x: 0, y: 0, width: ceil(heroWidth) + 2, height: 30)
        container.addSubview(heroLabel)

        let suffixText = isNeverFetched ? "" : String(format: " of $%.0f today", limit)
        let suffixLabel = NSTextField(labelWithString: suffixText)
        suffixLabel.font = NSFont.systemFont(ofSize: 15)
        suffixLabel.textColor = .secondaryLabelColor
        // Baseline-align: the 30pt hero's baseline sits ~7pt above its frame's
        // bottom; the 15pt suffix needs ~4pt to share that line. 8pt gap.
        suffixLabel.frame = NSRect(x: ceil(heroWidth) + 2 + 8, y: 5, width: container.bounds.width - ceil(heroWidth) - 10, height: 19)
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

    private func makeTodayLabelAndCurve(history: HistoryStore, limit: Double, now: Date, at yOffset: inout CGFloat) -> CGFloat {
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

        let dayRecord = history.day(utcDate: now)
        let hourly = dayRecord?.hourly ?? Array(repeating: nil, count: 24)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let utcHour = utcCalendar.component(.hour, from: now)
        curveView.configure(hourly: hourly, limit: limit, nowHourUTC: utcHour)

        addSubview(curveView)
        managedSubviews.append(curveView)

        return labelHeight + sectionSpacing + 92
    }

    private func makeModelsHeader(at yOffset: inout CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: "MODELS · THIS MONTH")
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .labelColor.withAlphaComponent(0.42)
        label.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - 14, width: 200, height: 14)
        addSubview(label)
        managedSubviews.append(label)
        return 14
    }

    private func makeModelRow(name: String, cost: Double, tokens: Double, maxCost: Double, at yOffset: inout CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 24

        // Name (13pt, 118 wide)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: sidePadding, y: bounds.height - yOffset - rowHeight, width: 118, height: rowHeight)
        addSubview(nameLabel)
        managedSubviews.append(nameLabel)

        // Bar (2pt tall, width proportional to cost)
        // Capped so the bar never reaches the cost label (starts x=194; bar
        // starts x=138; 8pt gap -> 48pt max). Pre-cap it ran 100pt and cut
        // straight through the dollar figure on the top model.
        let barWidth = maxCost > 0 ? min(CGFloat(cost / maxCost) * 100, 48) : 0
        let bar = NSView(frame: NSRect(x: sidePadding + 120, y: bounds.height - yOffset - 8, width: barWidth, height: 2))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.cgColor
        addSubview(bar)
        managedSubviews.append(bar)

        // Cost (13pt, tabular right, 52 wide)
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", cost))
        costLabel.font = NSFont.systemFont(ofSize: 13)
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.frame = NSRect(x: 320 - sidePadding - 52 - 56, y: bounds.height - yOffset - rowHeight, width: 52, height: rowHeight)
        addSubview(costLabel)
        managedSubviews.append(costLabel)

        // Tokens (11pt, 40% alpha, right, 56 wide)
        let tokensFormatted: String
        if tokens >= 1_000_000 {
            let millions = tokens / 1_000_000
            var formatted = String(format: "%.2fM", millions)
            // Trim trailing zeros but never the decimal point ("5.00M" -> "5M",
            // "4.96M" stays) — the naive trim turned "5.00M" into "5.M".
            while formatted.hasSuffix("0") && !formatted.hasSuffix(".0M") { formatted.removeLast() }
            if formatted.hasSuffix(".0M") { formatted = formatted.replacingOccurrences(of: ".0M", with: "M") }
            tokensFormatted = formatted
        } else if tokens >= 1_000 {
            let thousands = tokens / 1_000
            tokensFormatted = String(format: "%.0fK", thousands)
        } else {
            tokensFormatted = String(format: "%.0f", tokens)
        }

        let tokenLabel = NSTextField(labelWithString: tokensFormatted)
        tokenLabel.font = NSFont.systemFont(ofSize: 11)
        tokenLabel.textColor = .labelColor.withAlphaComponent(0.40)
        tokenLabel.alignment = .right
        tokenLabel.frame = NSRect(x: 320 - sidePadding - 56, y: bounds.height - yOffset - rowHeight, width: 56, height: rowHeight)
        addSubview(tokenLabel)
        managedSubviews.append(tokenLabel)

        return rowHeight + 6
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
        if let url = URL(string: "https://ai-llm-gateway.fbr.land") {
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
}
