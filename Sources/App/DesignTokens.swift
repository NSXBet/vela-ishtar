// Sources/App/DesignTokens.swift
// The frozen v2.0 design tokens (V2_IMPLEMENTATION_PLAN.md §5.1, validated by
// WP-05's fixtures in Tools/design_fixture_main.swift and documented in
// docs/v2/DESIGN.md).
// Why: every later UI work package (WP-06/07/08/11) must read ONE source of
// truth for width, spacing, type, and status color instead of re-copying the
// ad-hoc constants PopoverView grew over v1 (sidePadding 18 here, 66 there,
// alphas 0.38/0.40/0.42/0.45 sprinkled by hand). Values are the plan's
// proposals, confirmed against long-content fixtures; a change starts here.
// Pure values + small color helpers. No I/O, no layout, no view hierarchy.
// RELEVANT FILES: docs/v2/DESIGN.md, Tools/design_fixture_main.swift,
// Sources/App/PopoverView.swift, V2_IMPLEMENTATION_PLAN.md

import AppKit

public enum VelaDesign {

    // MARK: - Layout

    /// Geometry scale. The summary card grows 320 → 360pt; the content inset
    /// grows 18 → 20pt so column clearances stay honest at the wider hero.
    public enum Layout {
        /// Proposed summary width, fixture-validated at 360pt.
        public static let summaryWidth: CGFloat = 360
        /// Current v1 summary width, kept for the 05.1 comparison fixtures.
        public static let legacySummaryWidth: CGFloat = 320
        /// Horizontal content inset on both sides.
        public static let contentInset: CGFloat = 20
        /// Inner content width (summaryWidth - 2 × inset).
        public static var contentWidth: CGFloat { summaryWidth - 2 * contentInset }

        /// Spacing scale (plan §5.1: 4/8/12/16/24). `section` is the default
        /// gap between sections and matches v1's 12pt rhythm.
        public static let space1: CGFloat = 4
        public static let space2: CGFloat = 8
        public static let space3: CGFloat = 12
        public static let space4: CGFloat = 16
        public static let space5: CGFloat = 24
        public static let sectionSpacing: CGFloat = space3
    }

    // MARK: - Rows and controls

    public enum Rows {
        /// Standard row height where practical (plan §5.1).
        public static let height: CGFloat = 32
        /// A data row's visible height inside its 32pt stride (name/cost/share).
        public static let dataRowHeight: CGFloat = 24
        /// Full stride per model row: data row + 8pt air (v1's proven rhythm).
        public static let dataRowStride: CGFloat = height
        /// Interactive controls never go below 24pt (hit-target floor).
        public static let controlMinHeight: CGFloat = 24
        /// Reserved status/copy slot under the hero — present in EVERY state
        /// so the card's outer geometry never breathes between states
        /// (plan §5.3 "reserved status slots with meaningful neutral content").
        public static let statusSlotHeight: CGFloat = 34
        /// The models block is ALWAYS five row strides tall in both periods —
        /// carried over from v1's never-resize-on-tab-switch guarantee.
        public static let maxModelRows = 5
    }

    // MARK: - Typography

    /// SF system type only, monetary digits tabular. Every font is a computed
    /// property so call sites always get a fresh NSFont descriptor (cheap, and
    /// it keeps the scale stated in exactly one place).
    public enum Typography {
        /// Hero amount: 30pt semibold, tabular digits (plan §5.1).
        public static var hero: NSFont { .monospacedDigitSystemFont(ofSize: 30, weight: .semibold) }
        /// Hero suffix (" of $400 today"), baseline-aligned to the hero.
        public static var heroSuffix: NSFont { .systemFont(ofSize: 15) }
        /// Primary body and row names.
        public static var body: NSFont { .systemFont(ofSize: 13) }
        /// Monetary figures in rows: tabular so decimal points stack.
        public static var money: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
        /// Secondary information (11–12pt band; 12 for interactive text).
        public static var secondary: NSFont { .systemFont(ofSize: 11) }
        public static var secondaryInteractive: NSFont { .systemFont(ofSize: 12) }
        /// Section labels (11pt medium).
        public static var sectionLabel: NSFont { .systemFont(ofSize: 11, weight: .medium) }
        /// Nested budget row name/value.
        public static var budgetName: NSFont { .systemFont(ofSize: 12) }
        public static var budgetValue: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    }

    // MARK: - Color

    /// Semantic colors. Computed, NOT stored: a dynamic NSColor must be
    /// re-resolved when the appearance changes (§5.1), and `withAlphaComponent`
    /// on a cached color freezes one resolution. Call per draw.
    public enum Color {

        /// Hairline separators. Backing-scale aware by construction — AppKit
        /// draws the 0.5pt layer at the host window's backing scale.
        public static func hairline(contrast: Bool) -> NSColor {
            NSColor.labelColor.withAlphaComponent(contrast ? 0.30 : 0.14)
        }

        /// Section label ink (TODAY / MODELS). 0.55 on white ≈ 4.6:1 — the
        /// fixture pass showed 0.42 vanishes on the light surface (§5.1:
        /// validate contrast on BOTH surfaces, not just dark).
        public static var sectionLabel: NSColor {
            NSColor.labelColor.withAlphaComponent(0.55)
        }

        /// Quiet tertiary text (notes, captions). Under Increase Contrast the
        /// alpha lifts further instead of multiplying blindly (§5.1).
        public static func caption(contrast: Bool) -> NSColor {
            NSColor.labelColor.withAlphaComponent(contrast ? 0.75 : 0.55)
        }

        /// Progress-track background behind a budget fill.
        public static func trackBackground(contrast: Bool) -> NSColor {
            NSColor.labelColor.withAlphaComponent(contrast ? 0.28 : 0.14)
        }

        /// Neutral (non-binding) budget fill: achromatic on purpose — the cap
        /// is not currently costing the user anything.
        public static var trackNeutral: NSColor {
            NSColor.labelColor.withAlphaComponent(0.45)
        }

        /// The budget-state ramp (matches ModelBudgetSignal's states):
        /// ink → notice → amber → alarm. Cooldown/quiet stay neutral.
        public static func trackFill(kind: BudgetFillKind) -> NSColor {
            switch kind {
            case .neutral: return trackNeutral
            case .notice:  return .systemYellow
            case .amber:   return .systemOrange
            case .alarm:   return .systemRed
            }
        }

        public enum BudgetFillKind { case neutral, notice, amber, alarm }

        /// Status slot: a semantic tinted band with border + label. The band's
        /// background/border stay subtle; the TEXT does the work, so contrast
        /// survives both appearances.
        public static func statusBand(kind: StatusKind, contrast: Bool)
            -> (background: NSColor, border: NSColor) {
            let tintColor: NSColor
            switch kind {
            case .neutral: tintColor = .labelColor
            case .cached:  tintColor = .labelColor
            case .notice:  tintColor = .systemOrange
            case .alarm:   tintColor = .systemRed
            }
            let bgAlpha: CGFloat    = contrast ? 0.16 : (kind == .neutral ? 0.05 : 0.08)
            let borderAlpha: CGFloat = contrast ? 0.55 : (kind == .neutral ? 0.12 : 0.25)
            return (tintColor.withAlphaComponent(bgAlpha),
                    tintColor.withAlphaComponent(borderAlpha))
        }

        public enum StatusKind { case neutral, cached, notice, alarm }

        /// Fresh/healthy dot and positive fills.
        public static var healthy: NSColor { .systemGreen }
        /// Hover/focus band behind a row (replaces hover-only answers: the
        /// same information is always available to keyboard focus).
        public static func focusBand(contrast: Bool) -> NSColor {
            NSColor.controlAccentColor.withAlphaComponent(contrast ? 0.22 : 0.10)
        }
    }

    // MARK: - Material

    /// The summary panel's material, with the opaque fallback §5.1 requires:
    /// under Reduce Transparency the effect view is replaced by a flat
    /// window-background fill (never a translucent panel over unknown desktop
    /// content). The fixture bakes both onto opaque canvases so the two are
    /// reviewed side by side.
    public enum Material {
        public static let summaryEffect: NSVisualEffectView.Material = .popover
        /// Opaque flat fill used instead of `summaryEffect` when
        /// NSWorkspace.accessibilityDisplayShouldReduceTransparency is true.
        public static let opaqueFallback: NSColor = .windowBackgroundColor
    }

    // MARK: - Motion

    /// Motion budget (plan §5.3): opening uses a short opacity/translation
    /// transition; the period indicator's slide is 140ms; the curve's draw-on
    /// reveal is the ONLY open animation and is skipped entirely under Reduce
    /// Motion. No element repeats an animation continuously — the retired
    /// sonar intro and per-poll bell rocking stay retired.
    public enum Motion {
        public static let openTransitionSeconds: Double = 0.15
        public static let tabIndicatorSeconds: Double = 0.14
    }
}
