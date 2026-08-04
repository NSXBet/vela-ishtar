// Sources/App/PopoverView.swift
// Renders the popover panel content: hero spend, pace sentence, hourly curve,
// top models, and footer with dashboard link, API key copy, and status indicator.
// Why: this is the primary UI surface showing budget status and model costs
// in a fixed 320pt width, laid out with hairline section dividers and a status
// dot that changes color with fetch freshness.
// RELEVANT FILES: Sources/App/CurveView.swift, Sources/VelaCore/PaceEngine.swift, Sources/VelaCore/PollStateMachine.swift

import Cocoa

@MainActor
public final class PopoverView: NSView {
    private let curveView = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))
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
                yOffset += makeModelRow(name: model.model, cost: model.totalCostUSD, tokens: Double(model.totalTokens), maxCost: topModels.first?.totalCostUSD ?? 1, at: &yOffset)
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

    private func makeHeroRow(spent: Double, limit: Double, isNeverFetched: Bool = false, at yOffset: inout CGFloat) -> CGFloat {
        let containerHeight: CGFloat = 36
        let container = NSView(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - containerHeight, width: 320 - 2 * sidePadding, height: containerHeight))
        addSubview(container)
        managedSubviews.append(container)

        let heroText = isNeverFetched ? "—" : String(format: "$%.2f", spent)
        let heroLabel = NSTextField(labelWithString: heroText)
        heroLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        heroLabel.textColor = .labelColor
        heroLabel.frame = NSRect(x: 0, y: 0, width: 150, height: 30)
        container.addSubview(heroLabel)

        let suffixText = isNeverFetched ? "" : String(format: " of $%.0f today", limit)
        let suffixLabel = NSTextField(labelWithString: suffixText)
        suffixLabel.font = NSFont.systemFont(ofSize: 15)
        suffixLabel.textColor = .secondaryLabelColor
        suffixLabel.frame = NSRect(x: 150, y: 4, width: container.bounds.width - 150, height: 15)
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
        let utcHour = Calendar(identifier: .gregorian).component(.hour, from: now)
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
        let barWidth = maxCost > 0 ? CGFloat(cost / maxCost) * 80 : 0
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
            tokensFormatted = String(format: "%.2fM", millions).trimmingCharacters(in: CharacterSet(charactersIn: "0"))
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
        let footerHeight: CGFloat = 24

        // "Dashboard ↗"
        let dashboardButton = NSButton(frame: NSRect(x: sidePadding, y: bounds.height - yOffset - footerHeight, width: 60, height: footerHeight))
        dashboardButton.setButtonType(.momentaryLight)
        dashboardButton.bezelStyle = .recessed
        dashboardButton.title = "Dashboard ↗"
        dashboardButton.font = NSFont.systemFont(ofSize: 12)
        dashboardButton.target = self
        dashboardButton.action = #selector(openDashboard)
        addSubview(dashboardButton)
        managedSubviews.append(dashboardButton)

        // "API key"
        let apiKeyButton = NSButton(frame: NSRect(x: sidePadding + 65, y: bounds.height - yOffset - footerHeight, width: 50, height: footerHeight))
        apiKeyButton.setButtonType(.momentaryLight)
        apiKeyButton.bezelStyle = .recessed
        apiKeyButton.title = "API key"
        apiKeyButton.font = NSFont.systemFont(ofSize: 12)
        apiKeyButton.target = self
        apiKeyButton.action = #selector(copyAPIKey)
        addSubview(apiKeyButton)
        managedSubviews.append(apiKeyButton)

        // Right side: status dot + time
        let dotColor: NSColor
        switch isFresh {
        case true:
            dotColor = .systemGreen
        case false:
            dotColor = lastSuccessAt != nil ? .systemOrange : .labelColor.withAlphaComponent(0.35)
        }

        let dot = NSView(frame: NSRect(x: 320 - sidePadding - 14 - 50, y: bounds.height - yOffset - 8, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)
        managedSubviews.append(dot)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeString = formatter.string(from: now)
        let statusPrefix = isFresh ? "" : "stale "
        let statusLabel = NSTextField(labelWithString: "AI Hub · " + statusPrefix + timeString)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .labelColor.withAlphaComponent(0.38)
        statusLabel.frame = NSRect(x: 320 - sidePadding - 120, y: bounds.height - yOffset - footerHeight, width: 100, height: footerHeight)
        addSubview(statusLabel)
        managedSubviews.append(statusLabel)

        return footerHeight
    }

    @objc private func openDashboard() {
        if let url = URL(string: "https://ai-llm-gateway.fbr.land") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyAPIKey() {
        let keychain = KeychainStore()
        let token = keychain.read() ?? ""
        NSPasteboard.general.setString(token, forType: .string)
    }
}
