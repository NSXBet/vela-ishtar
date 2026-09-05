// Sources/App/ConnectionStatusView.swift
// WP-07 07.1: the reserved 34pt status slot (DESIGN.md §2/§4). Every state
// fills it — a neutral freshness line when calm, a tinted band (border +
// label, VelaDesign.Color.statusBand) when stale/auth/error — so the card's
// outer geometry never breathes between states and critical status never
// disappears into a low-opacity dimming pass (this view is EXCLUDED from
// PopoverView's data dimming).
// Why a separate view: the v1 stale banner rendered 8pt text inside the
// dimmed content (B17), and a poll could rebuild it out from under the
// reader. This slot is built once and re-worded in place.
// RELEVANT FILES: Sources/App/SummaryHeaderView.swift, Sources/App/PopoverView.swift,
// Sources/App/DesignTokens.swift, docs/v2/DESIGN.md

import AppKit

@MainActor
final class ConnectionStatusView: NSView {

    private let line = NSTextField(labelWithString: "")
    private let band = NSView()
    private let bandLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: VelaDesign.Rows.statusSlotHeight))
        line.font = VelaDesign.Typography.secondary
        line.lineBreakMode = .byTruncatingTail
        line.maximumNumberOfLines = 1
        addSubview(line)

        band.wantsLayer = true
        band.layer?.cornerRadius = 7
        band.layer?.borderWidth = 1
        bandLabel.font = VelaDesign.Typography.secondaryInteractive
        bandLabel.textColor = .labelColor
        bandLabel.lineBreakMode = .byTruncatingTail
        bandLabel.maximumNumberOfLines = 1
        band.addSubview(bandLabel)
        band.setAccessibilityElement(true)
        band.setAccessibilityRole(.staticText)
        band.setAccessibilityLabel("Connection status")
        addSubview(band)
        band.isHidden = true
        layoutContent()
    }

    public required init?(coder: NSCoder) {
        fatalError("ConnectionStatusView does not support NSCoder-based initialization")
    }

    /// Re-words the slot in place. Neutral/cached states show the plain
    /// line; notice/alarm states show the tinted band. Same 34pt frame
    /// either way.
    func apply(text: String, kind: VelaDesign.Color.StatusKind, contrast: Bool) {
        let tinted = (kind == .notice || kind == .alarm)
        band.isHidden = !tinted
        line.isHidden = tinted
        if tinted {
            let colors = VelaDesign.Color.statusBand(kind: kind, contrast: contrast)
            band.layer?.backgroundColor = colors.background.cgColor
            band.layer?.borderColor = colors.border.cgColor
            bandLabel.stringValue = text
            band.setAccessibilityValue(text)
        } else {
            line.stringValue = text
            line.textColor = VelaDesign.Color.caption(contrast: contrast)
        }
        needsLayout = true
        layoutContent()
    }

    private func layoutContent() {
        let inset = VelaDesign.Layout.contentInset
        let width = bounds.width
        let height = VelaDesign.Rows.statusSlotHeight
        if band.isHidden {
            line.frame = NSRect(x: inset, y: (height - 14) / 2, width: width - 2 * inset, height: 14)
        } else {
            band.frame = NSRect(x: inset, y: 2, width: width - 2 * inset, height: height - 4)
            bandLabel.frame = NSRect(x: 8, y: (band.bounds.height - 15) / 2, width: band.bounds.width - 16, height: 15)
        }
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }
}
