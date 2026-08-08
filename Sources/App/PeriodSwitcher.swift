// Sources/App/PeriodSwitcher.swift
// The Models section's Today / Month switcher: two text labels with a 1pt
// sliding indicator under the selected one (v0.4.0, replaces the
// NSSegmentedControl).
// Why: a segmented control can't animate its selection smoothly, so the
// "tabs" felt dead. This custom control slides a hairline indicator to the
// tapped tab over 0.2s on the GPU. The one hard constraint: PopoverView
// rebuilds ALL subviews every 60s, so the indicator must be POSITIONED
// (implicit animations disabled) on rebuild and ANIMATED only on a real
// click — otherwise it would re-slide every minute for no reason.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/CurveView.swift

import Cocoa

/// A two-tab Today/Month switcher with a sliding underline indicator.
/// Layer-backed so the indicator slide is compositor-driven (60fps). The
/// caller drives selection via setSelected(_:animated:): pass animated:false
/// from a rebuild (positions instantly), animated:true from a click (slides).
@MainActor
public final class PeriodSwitcher: NSView {
    /// Fired after the user clicks a tab (index 0 or 1). Not fired for
    /// programmatic setSelected calls that originate from a rebuild.
    public var onSelect: ((Int) -> Void)?

    private let labels: [String]
    private var labelViews: [NSTextField] = []
    private var hitButtons: [NSButton] = []
    private let indicator = NSView()
    private var selectedIndex = 0

    // One font weight for BOTH states — only the color changes — so each
    // label's width (and therefore the indicator's target frame) is stable
    // across selection changes. A bold-selected style would reflow the
    // indicator's x/width mid-animation.
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let indicatorHeight: CGFloat = 1

    public init(labels: [String] = ["Today", "Month"]) {
        self.labels = labels
        super.init(frame: NSRect(x: 0, y: 0, width: 118, height: 20))
        wantsLayer = true
        buildSubviews()
    }

    public required init?(coder: NSCoder) {
        fatalError("PeriodSwitcher does not support NSCoder-based initialization")
    }

    private func buildSubviews() {
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.labelColor.cgColor

        for (index, title) in labels.enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = font
            label.alignment = .center
            label.isSelectable = false
            label.sizeToFit()
            labelViews.append(label)
            addSubview(label)

            // Transparent hit-target over the label (wider than the text, so
            // the tap area is generous). The label itself ignores clicks.
            let button = NSButton(frame: .zero)
            button.isBordered = false
            button.title = ""
            button.tag = index
            button.target = self
            button.action = #selector(tabClicked(_:))
            hitButtons.append(button)
            addSubview(button)
        }
        addSubview(indicator)

        // Accessibility: the group reads as a tab control, each tab a radio.
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Models period")
        for (index, button) in hitButtons.enumerated() {
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(labels[index])
        }
        applySelectionColors()
    }

    /// Lay out labels left-to-right with a fixed gap, sized to fit their
    /// text, RIGHT-PACKED inside our bounds, and position the indicator under
    /// the selected label WITHOUT animating. Called whenever our bounds change
    /// (a rebuild re-adds us at the same size, so this is effectively a
    /// re-position pass).
    ///
    /// Why right-packed (v1.0.0): the caller pins our FRAME's right edge to the
    /// content margin so the tabs read as scoping the numbers below. But the
    /// labels only need ~94pt of the 118pt frame, and packing them from x=0 left
    /// all 24pt of that slack on the RIGHT — so the visible tabs ended up 24pt
    /// short of the cost/efficiency columns they label. Right-packing spends the
    /// slack on the left instead, and "Month" lands on the same edge as the
    /// figures beneath it. The frame stays 118pt (its generous hit targets
    /// depend on it); only the content moves.
    public override func layout() {
        super.layout()
        let gap: CGFloat = 18

        // Measure first so the content block can be right-aligned as a unit.
        for label in labelViews { label.sizeToFit() }
        let contentWidth = labelViews.reduce(0) { $0 + $1.frame.width }
            + gap * CGFloat(max(labelViews.count - 1, 0))
        // max(0, …) so a frame narrower than its own text degrades to
        // left-packed rather than sliding the first label off the left edge.
        var x = max(0, bounds.width - contentWidth)

        for (index, label) in labelViews.enumerated() {
            let w = label.frame.width
            label.frame = NSRect(x: x, y: (bounds.height - label.frame.height) / 2, width: w, height: label.frame.height)
            hitButtons[index].frame = NSRect(x: x - 6, y: 0, width: w + 12, height: bounds.height)
            x += w + gap
        }
        // Position the indicator without animating — this is a layout pass,
        // not a user gesture.
        setIndicatorFrame(animated: false)
    }

    /// Selects a tab. animated:true slides the indicator (a user click);
    /// animated:false snaps it (a rebuild re-asserting the current selection).
    public func setSelected(_ index: Int, animated: Bool) {
        guard index >= 0, index < labels.count else { return }
        selectedIndex = index
        applySelectionColors()
        setIndicatorFrame(animated: animated)
    }

    @objc private func tabClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index != selectedIndex else { return }
        // Reduce Motion: snap the indicator, don't slide it.
        setSelected(index, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        onSelect?(index)
    }

    private func applySelectionColors() {
        for (index, label) in labelViews.enumerated() {
            label.textColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
        }
        for (index, button) in hitButtons.enumerated() {
            button.setAccessibilitySelected(index == selectedIndex)
        }
    }

    /// Moves the indicator under the selected label. The slide is the whole
    /// point of the control, so it's the ONLY animated path; rebuilds pass
    /// animated:false and land instantly.
    private func setIndicatorFrame(animated: Bool) {
        guard selectedIndex < labelViews.count else { return }
        let label = labelViews[selectedIndex]
        let target = NSRect(
            x: label.frame.minX,
            y: 0,
            width: label.frame.width,
            height: indicatorHeight
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                indicator.animator().frame = target
            }
        } else {
            // Snap: disable implicit animations so a rebuild doesn't trigger
            // a stray slide.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicator.frame = target
            CATransaction.commit()
        }
    }
}
