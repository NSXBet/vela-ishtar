// Sources/App/ModelsSectionView.swift
// WP-07 07.2: the MODELS section — label + the selected period's
// authoritative scoped total (SummaryDisplayState.selectedPeriodTotalUSD,
// B08) + the Today/Month switcher + the always-five-stride row block.
// Built ONCE; rows update by stable ID (SummaryDisplayState.Row.id) with
// no remove/recreate when the state is identical (06.2 continuation, B10).
// Long model names truncate with the FULL route in accessibility and the
// tooltip — the amount never clips (DESIGN.md §3 semantic truncation).
// The observed blended $/M rides the row's accessibility value with a
// truthful "observed" label; tokens arrive in Row.detail's money part and
// the rate is rendered in the detail column when provided by the state.
// RELEVANT FILES: Sources/App/PeriodSwitcher.swift, Sources/App/PopoverView.swift,
// Sources/VelaCore/MoneyFormat.swift, docs/v2/DESIGN.md

import AppKit

@MainActor
final class ModelsSectionView: NSView {

    /// Fired after a real tab click; the owner re-derives display state
    /// (AppCoordinator.setSelectedPeriod) — no 210ms wait (B10).
    var onSelectPeriod: ((Int) -> Void)?

    private let sectionLabel = NSTextField(labelWithString: "MODELS")
    private let totalLabel = NSTextField(labelWithString: "")
    private let switcher = PeriodSwitcher(labels: ["Today", "Month"])
    private let block = NSView()

    /// Persistent row views keyed by stable ID. Rows are REUSED across
    /// refreshes: an unchanged ID re-words its labels, a vanished ID hides,
    /// a new ID takes an existing hidden slot or a fresh view. No removal.
    private struct RowCell {
        let container: NSView
        let nameLabel: NSTextField
        let costLabel: NSTextField
        let shareLabel: NSTextField
    }
    private var cells: [String: RowCell] = [:]
    private var visibleOrder: [String] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.summaryWidth, height: 0))
        sectionLabel.font = VelaDesign.Typography.sectionLabel
        sectionLabel.textColor = VelaDesign.Color.sectionLabel
        addSubview(sectionLabel)

        totalLabel.font = VelaDesign.Typography.money
        totalLabel.textColor = .labelColor
        totalLabel.alignment = .right
        totalLabel.setAccessibilityLabel("Selected period total")
        addSubview(totalLabel)

        switcher.onSelect = { [weak self] index in
            self?.onSelectPeriod?(index)
        }
        addSubview(switcher)
        addSubview(block)
    }

    public required init?(coder: NSCoder) {
        fatalError("ModelsSectionView does not support NSCoder-based initialization")
    }

    // MARK: - Geometry (DESIGN.md: header 26, block 5 × 32)

    static let headerHeight: CGFloat = 26
    static var blockHeight: CGFloat { CGFloat(VelaDesign.Rows.maxModelRows) * VelaDesign.Rows.dataRowStride }

    var sectionHeaderHeight: CGFloat { Self.headerHeight }
    var sectionBlockHeight: CGFloat { Self.blockHeight }
    var preferredHeight: CGFloat { Self.headerHeight + Self.blockHeight }

    func layoutContent(contrast: Bool) {
        let inset = VelaDesign.Layout.contentInset
        let width = bounds.width
        var y = bounds.height

        sectionLabel.frame = NSRect(x: inset, y: y - ModelsSectionView.headerHeight + 6, width: 70, height: 14)
        totalLabel.frame = NSRect(x: inset, y: y - ModelsSectionView.headerHeight + 5, width: width - 2 * inset - 130, height: 16)
        switcher.frame = NSRect(x: width - inset - 118, y: y - ModelsSectionView.headerHeight + 3, width: 118, height: 20)
        y -= ModelsSectionView.headerHeight

        block.frame = NSRect(x: 0, y: y - ModelsSectionView.blockHeight, width: width, height: ModelsSectionView.blockHeight)
        // Rows sit top-down inside the block (stride-ordered from the top).
        for (index, id) in visibleOrder.enumerated() {
            if let cell = cells[id] {
                cell.container.frame = NSRect(
                    x: 0, y: Self.blockHeight - CGFloat(index + 1) * VelaDesign.Rows.dataRowStride,
                    width: width, height: VelaDesign.Rows.dataRowHeight)
            }
        }
    }

    // MARK: - State application (stable-ID diffing)

    private static let cellReuseIndent = "slot"

    /// Applies the period's rows. Content updates in place by stable ID;
    /// the five-stride block never changes height (never-resize guarantee).
    /// `totalText` is the SELECTED period's authoritative scoped total
    /// (B08: the view renders what the presenter derived — month shares in
    /// Row.fraction already divide by current_month.totalCostUSD).

    /// The selected period's display name for row accessibility ("today" /
    /// "month"); kept in sync with the switcher index in apply().
    private var selectedPeriodName = "today"
    func apply(rows: [SummaryDisplayState.Row], totalText: String, selectedPeriodIndex: Int, contrast: Bool) {
        selectedPeriodName = selectedPeriodIndex == 0 ? "today" : "month"
        totalLabel.stringValue = totalText
        switcher.setSelected(selectedPeriodIndex, animated: false)
        switcher.layoutSubtreeIfNeeded()

        var nextOrder: [String] = []
        for row in rows.prefix(VelaDesign.Rows.maxModelRows) {
            nextOrder.append(row.id)
            let cell = cells[row.id] ?? makeCell(id: row.id)
            configure(cell, from: row)
            cell.container.isHidden = false
        }
        // Hide everything not in the new state (empty strides stay as
        // reserved air — DESIGN.md §2, not unexplained holes).
        for (id, cell) in cells where !nextOrder.contains(id) {
            cell.container.isHidden = true
        }
        let orderChanged = visibleOrder != nextOrder
        visibleOrder = nextOrder
        layoutContent(contrast: contrast)
        if orderChanged { needsDisplay = true }
    }

    private func makeCell(id: String) -> RowCell {
        let container = NSView()
        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = VelaDesign.Typography.body
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(nameLabel)

        let costLabel = NSTextField(labelWithString: "")
        costLabel.font = VelaDesign.Typography.money
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.lineBreakMode = .byClipping
        container.addSubview(costLabel)

        let shareLabel = NSTextField(labelWithString: "")
        shareLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shareLabel.textColor = NSColor.labelColor.withAlphaComponent(0.55)
        shareLabel.alignment = .right
        container.addSubview(shareLabel)

        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.row)
        block.addSubview(container)
        let cell = RowCell(container: container, nameLabel: nameLabel, costLabel: costLabel, shareLabel: shareLabel)
        cells[id] = cell
        return cell
    }

    private func configure(_ cell: RowCell, from row: SummaryDisplayState.Row) {
        // Row.detail carries "$12.34" (+ optional observed blended rate
        // appended by the presenter as " · $X/M observed"). Name may carry
        // the full provider route; display strips the prefix.
        let detailParts = row.detail.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let moneyText = detailParts.first ?? row.detail
        let rateText = detailParts.count > 1 ? detailParts[1] : nil

        let displayName = row.title.split(separator: "/").last.map(String.init) ?? row.title
        let shareText: String
        if let fraction = row.fraction {
            shareText = "\(Int((fraction * 100).rounded()))%"
        } else {
            shareText = ""
        }

        // Explanatory rows (auth/invalid/stale/inconsistent states) carry
        // no money figure: they render FULL-WIDTH with wrapping so the
        // required DESIGN.md copy is never clipped by the money columns.
        let isExplanatory = row.fraction == nil && !row.detail.isEmpty && !moneyText.hasPrefix("$")

        if isExplanatory {
            // The reserved 5-stride block is fixed geometry (§5.3), so the
            // explanatory sentence must fit ONE stride: full width (no
            // money columns) at caption size, wrapped to 2 lines within
            // the 24pt stride via a 10pt font + tightened line spacing.
            let combined = row.detail.isEmpty ? row.title : "\(row.title) — \(row.detail)"
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.maximumLineHeight = 11
            cell.nameLabel.attributedStringValue = NSAttributedString(string: combined, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            cell.nameLabel.lineBreakMode = .byWordWrapping
            cell.nameLabel.maximumNumberOfLines = 2
            cell.nameLabel.cell?.wraps = true
            cell.costLabel.stringValue = ""
            cell.shareLabel.stringValue = ""
            let inset = VelaDesign.Layout.contentInset
            let width = bounds.width
            cell.nameLabel.toolTip = nil
            cell.nameLabel.frame = NSRect(x: inset, y: 0, width: width - 2 * inset, height: VelaDesign.Rows.dataRowHeight)
            cell.costLabel.frame = NSRect.zero
            cell.shareLabel.frame = NSRect.zero
            cell.container.setAccessibilityLabel(row.title)
            cell.container.setAccessibilityValue(row.detail)
            return
        }
        cell.nameLabel.lineBreakMode = .byTruncatingTail
        cell.nameLabel.maximumNumberOfLines = 1
        cell.nameLabel.attributedStringValue = NSAttributedString(string: displayName, attributes: [
            .font: VelaDesign.Typography.body,
            .foregroundColor: NSColor.labelColor,
        ])
        cell.costLabel.stringValue = moneyText
        cell.shareLabel.stringValue = shareText

        // Long-name disclosure: full route on hover + in accessibility; the
        // amount column never clips (money text is never truncated).
        cell.nameLabel.toolTip = displayName != row.title ? row.title : nil

        let inset = VelaDesign.Layout.contentInset
        let width = bounds.width
        let costW: CGFloat = 78
        let shareW: CGFloat = 44
        cell.nameLabel.frame = NSRect(x: inset, y: 0, width: width - 2 * inset - costW - shareW - 12, height: VelaDesign.Rows.dataRowHeight)
        cell.costLabel.frame = NSRect(x: width - inset - costW - shareW - 8, y: 0, width: costW, height: VelaDesign.Rows.dataRowHeight)
        // WP-10 10.2: the row announces name, period, cost, share, and the
        // observed rate — the full route stays the label, so nothing
        // requires hover to read.
        var value = "\(selectedPeriodName): \(moneyText)"
        if !shareText.isEmpty { value += ", \(shareText) of the period total" }
        if let rateText { value += ", observed \(rateText)" }
        cell.container.setAccessibilityValue(value)
    }

    /// The share column's honest label for the pinned "Other" row: no share
    /// — it isn't a model. The presenter already passes fraction nil for it.
}
