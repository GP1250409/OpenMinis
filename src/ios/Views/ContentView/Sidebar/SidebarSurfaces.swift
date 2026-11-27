//
//  SidebarSurfaces.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  View modifiers and backgrounds of the sidebar: selection opt-out, folder
//  header visibility probe, folder card / member-row surfaces (one source of
//  truth for the folder look), and the search bar / FAB glass styling.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// List-selection opt-out with an availability floor. The folder card row
/// must never become the List(selection:)'s selected value — its "tap" is
/// collapse/expand, not navigation — but .selectionDisabled is iOS 17+ and
/// the app floors at 16 (where the plain Button row doesn't self-select).
struct SelectionDisabledIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.selectionDisabled()
        } else {
            content
        }
    }
}

/// Tracks whether an expanded folder's header card has scrolled out above
/// the list's visible top, reporting only on TRANSITIONS (Bool onChange) so
/// scroll frames don't churn ContentView state. Lives in the header row's
/// background — geometry is read in .global and compared against the
/// threshold the mini-bar overlay measured, which sidesteps the known-flaky
/// preference propagation across List cell hosting boundaries entirely.
///
/// `lastMaxY` exists for the CULLING edge: when the List recycles the header
/// cell far offscreen, onDisappear is the only signal left, and it alone
/// can't tell "culled above" from "culled below". The last observed frame
/// disambiguates. onDisappear also fires on collapse and on entering select
/// mode (the header row unmounts) — those reports are harmless because the
/// mini-bar's display guard independently requires an expanded folder
/// outside select mode.
struct FolderHeaderVisibilityProbe: View {
    let folderId: String
    let thresholdY: CGFloat
    let onVisibilityChange: (String, Bool) -> Void

    @State private var lastMaxY: CGFloat = .infinity

    var body: some View {
        GeometryReader { geo in
            let maxY = geo.frame(in: .global).maxY
            let hidden = maxY < thresholdY
            Color.clear
                .onAppear {
                    lastMaxY = maxY
                    onVisibilityChange(folderId, hidden)
                }
                .onChange(of: maxY) { newValue in
                    lastMaxY = newValue
                }
                .onChange(of: hidden) { newValue in
                    onVisibilityChange(folderId, newValue)
                }
                .onDisappear {
                    onVisibilityChange(folderId, lastMaxY < thresholdY)
                }
        }
    }
}

/// Folder card container: what visually separates a folder from the flat
/// session rows around it. On iOS 26+ this is the system Liquid Glass
/// material (`glassEffect`) in a continuous rounded rect; on earlier systems
/// it degrades to a deliberately plain filled card with a hairline stroke —
/// no custom blur, since `.blur` is an offscreen pass and this list is the
/// site of two archived scroll-perf incidents. The drop-target state draws an
/// accent tint + stroke ON TOP of either material, so drag feedback reads the
/// same on both OS generations.
/// One row's share of the expanded container's OUTER border. The top kind
/// draws the top arc + upper side walls, middle draws side walls only, and
/// bottom draws the lower walls + bottom arc — tiled across the group's rows
/// they form one continuous rounded-rect highlight, with no horizontal lines
/// at the row boundaries (which a per-segment full stroke would create).
private struct FolderSegmentBorder: Shape {
    enum Kind { case lone, top, middle, bottom }
    let kind: Kind
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .lone:
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        case .top:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                     radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                     radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .middle:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return p
    }
}

/// Edge highlight for the simulated glass: bright hairline in dark mode
/// (the reference system-folder look), a subtle dark line in light mode
/// (white would vanish on the light page).
private let folderEdgeHighlight = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.30)
        : UIColor(white: 0, alpha: 0.08)
})

/// Background for the expanded FAB search bar. Liquid Glass capsule on iOS 26+,
/// the original opaque capsule + hand-rolled shadow below it.
///
/// A modifier rather than a background view because the bar's content has to sit
/// INSIDE the glass: `.glassEffect` styles the view it is applied to, so the
/// text field and its icons ride within the material instead of being composited
/// over a separately-drawn shape.
struct SearchBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // No .clipShape needed — glassEffect(in:) already clips to the
            // capsule, and no .shadow: the material carries its own.
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
        }
    }
}

/// Tags the search FAB and the expanded search bar with ONE shared
/// `glassEffectID`.
///
/// Currently INERT: `glassEffectID` only does anything inside a
/// `GlassEffectContainer`, and the FAB row no longer has one — that container
/// suppressed the new-chat FAB's context menu, see the note on `fabRow`. The
/// modifier is kept (harmless, and it costs nothing) so that if the container
/// is ever reinstated with the menu problem solved, the morph works again
/// without re-deriving the id plumbing. The row's scale+opacity transition is
/// what actually animates the swap today.
struct FABGlassMorphID: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffectID("fabSearch", in: namespace)
        } else {
            content
        }
    }
}

/// THE single source of truth for a folder surface's background — used
/// identically by the collapsed lone card and by every row of an expanded
/// group. Per the user's directive after several rounds of expanded-only
/// material tuning: there is NO expanded-specific material/tint/opacity
/// definition anymore. The only thing that varies by position is the SHAPE
/// (lone / top / middle / bottom corner segmentation) and how the border is
/// tiled; the fill comes from one place.
private struct FolderSurface: ViewModifier {
    enum Kind { case lone, top, middle, bottom }
    let kind: Kind
    private var edgeColor: Color {
        // Match official Minis: collapsed and expanded cards use the same
        // adaptive edge highlight (white 0.30 dark / black 0.08 light) across
        // all iOS versions.
        folderEdgeHighlight
    }
    private var edgeWidth: CGFloat {
        0.75
    }

    /// Collapsed card fill matching official Minis in dark mode (28/255/28/255/30/255,
    /// i.e. secondarySystemBackground) and clean light surface (252/252/252).
    static let sampledGlassColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 28/255.0, green: 28/255.0, blue: 30/255.0, alpha: 1)
            : UIColor(red: 252/255.0, green: 252/255.0, blue: 252/255.0, alpha: 1)
    })

    private var shape: UnevenRoundedRectangle {
        switch kind {
        case .lone:
            return UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 16,
                bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
        case .top:
            return UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 16, style: .continuous)
        case .middle:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .bottom:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 16,
                bottomTrailingRadius: 16, topTrailingRadius: 0, style: .continuous)
        }
    }

    private var borderKind: FolderSegmentBorder.Kind {
        switch kind {
        case .lone: return .lone
        case .top: return .top
        case .middle: return .middle
        case .bottom: return .bottom
        }
    }

    func body(content: Content) -> some View {
        content
        .background {
            // Keep the content on one structural path. Only the paint varies.
            ZStack {
                if #available(iOS 26.0, *) {
                    if kind == .lone {
                        shape.fill(Self.sampledGlassColor)
                    } else {
                        shape.fill(.regularMaterial)
                    }
                } else {
                    shape.fill(Color(UIColor.secondarySystemBackground))
                }
            }
        }
        .overlay {
            // Single structural border shape across lone and tiled expanded
            // segments so folding never cross-fades two distinct overlay types.
            FolderSegmentBorder(kind: borderKind)
                .stroke(edgeColor, lineWidth: edgeWidth)
        }
        .overlay(alignment: .bottom) {
            if kind == .top {
                Rectangle()
                    .fill(Color(UIColor.separator).opacity(0.6))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct FolderCardBackground: ViewModifier {
    let isDropTarget: Bool
    let isExpanded: Bool
    /// MOD: false = drop-target overlay only. An expanded header paints its
    /// welded segment outside the context-menu source instead (see
    /// folderSectionHeader), so the segment is never hidden with the source.
    var paintsSurface = true

    private var dropShape: UnevenRoundedRectangle {
        isExpanded
            ? UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 16, style: .continuous)
            : UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 16,
                bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    if paintsSurface {
                        Color.clear.modifier(FolderSurface(kind: isExpanded ? .top : .lone))
                    }
                }
                .transaction { $0.animation = nil }
            }
            .overlay {
                if isDropTarget {
                    ZStack {
                        dropShape.fill(Color.accentColor.opacity(0.15))
                        dropShape.stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
            }
    }
}

/// Middle/bottom rows of an expanded group: the SAME FolderSurface as the
/// collapsed card, with the corner segmentation and border tiling that
/// multi-row composition needs.
struct FolderMemberRowBackground: View {
    let isLast: Bool

    var body: some View {
        Color.clear
            .modifier(FolderSurface(kind: isLast ? .bottom : .middle))
            .padding(.horizontal, 6)
            .padding(.bottom, isLast ? 4 : 0)
    }
}

/// MOD: the card body an EXPANDED folder header keeps inside its context-menu
/// source — all corners rounded, inset by the edge width so the welded
/// segment's outline stays visible in the list. On iOS 26 the welded segment
/// behind it is masked to the area OUTSIDE this body (FolderWeldStrip).
struct FolderCardFill: View {
    static let edgeInset: CGFloat = 0.5
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                // Solid, like a collapsed card: the platter snapshot has a
                // clear backdrop, where a material would lift washed out.
                RoundedRectangle(cornerRadius: 16 - Self.edgeInset, style: .continuous)
                    .fill(FolderSurface.sampledGlassColor)
            } else {
                RoundedRectangle(cornerRadius: 16 - Self.edgeInset, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            }
        }
        .padding(Self.edgeInset)
    }
}

/// MOD: mask for an expanded header's welded segment painted outside the
/// menu source: the whole segment EXCEPT the card body (FolderCardFill
/// geometry, `bottomGap` short of the segment's bottom). Use with eoFill.
///
/// The outer boundary is pushed `edgeBleed` past the segment frame: the
/// 0.75pt edge hairline is centred on the frame edge, so a mask clipped AT
/// the frame kept only its inner half and the header's top/side walls read
/// thinner than the member rows' unmasked walls (photo_AFC030AE).
struct FolderWeldStrip: Shape {
    static let edgeBleed: CGFloat = 2
    let bottomGap: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -Self.edgeBleed, dy: -Self.edgeBleed))
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                          height: max(0, rect.height - bottomGap))
            .insetBy(dx: FolderCardFill.edgeInset, dy: FolderCardFill.edgeInset)
        p.addPath(RoundedRectangle(cornerRadius: 16 - FolderCardFill.edgeInset, style: .continuous).path(in: body))
        return p
    }
}

/// Rename + dissolve alerts for the folder-header menu, extracted into a
/// modifier so their inline Binding(get:set:) expressions don't count against

// MARK: - MOD stable pinned-title presentation
// UIKit owns only the title's presentation. No per-frame parent @State writes,
// no replacement List, no row-height animation and no scroll-position changes.
@MainActor
final class StablePinnedTitle: ObservableObject {
    enum Edge { case header, first, last }
    private weak var scroll: UIScrollView?
    private weak var headerProbe: UIView?
    private weak var firstProbe: UIView?
    private weak var lastProbe: UIView?
    private var observations: [NSKeyValueObservation] = []
    private var ids: [String] = []
    private var enabled = false
    private var firstY: CGFloat?
    private var lastY: CGFloat?
    private var headerHeight: CGFloat = 28
    private var labelX: CGFloat = 16
    private let surface = UIView()
    private let label = UILabel()
    /// [T-sidebar-recent-section] No leading glyph on either date-bucket title
    /// ([T-sidebar-title-glyph-removal]): the sticky copy used to paint the
    /// pinned bucket's pin symbol in the gutter to mirror the SwiftUI header,
    /// and it is gone from both, so the handover between the two copies cannot
    /// show a glyph one of them no longer draws.
    /// [T-pinned-section-collapse] The chevron the SwiftUI header draws for a
    /// date bucket. While the section is expanded the sticky overlay is the
    /// only VISIBLE copy of that header (the SwiftUI one is at opacity 0.001
    /// for the probe), so the chevron has to be painted here too or the
    /// expand affordance would disappear exactly when it is needed.
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private var chevronAngle: CGFloat = 0
    private var queued = false

    init() {
        surface.isUserInteractionEnabled = false
        surface.backgroundColor = .systemBackground
        label.textColor = .secondaryLabel
        label.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        label.accessibilityTraits = .header
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        surface.addSubview(label); surface.addSubview(chevron)
    }

    func configure(ids: [String], enabled: Bool) {
        if self.ids != ids {
            self.ids = ids; firstY = nil; lastY = nil
            firstProbe = nil; lastProbe = nil
        }
        self.enabled = enabled && !ids.isEmpty
        requestLayout()
    }

    func stop() {
        enabled = false
        observations.removeAll()
        surface.removeFromSuperview()
        scroll = nil
    }

    func report(_ view: UIView, edge: Edge) {
        guard view.window != nil else { return }
        var parent = view.superview
        while let p = parent, !(p is UIScrollView) { parent = p.superview }
        guard let sv = parent as? UIScrollView else { return }
        if scroll !== sv {
            observations.removeAll(); surface.removeFromSuperview()
            scroll = sv
            sv.addSubview(surface)
            observations = [
                sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.layoutTitle() }
                },
                sv.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.requestLayout() }
                }
            ]
        }
        switch edge {
        case .header: headerProbe = view
        case .first: firstProbe = view
        case .last: lastProbe = view
        }
        requestLayout()
    }

    private func requestLayout() {
        guard !queued else { return }; queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.queued = false; self.layoutTitle()
        }
    }

    // Pure clamp: natural flow -> pinned -> pushed out by the section bottom.
    static func titleY(natural: CGFloat, viewport: CGFloat, bottom: CGFloat, height: CGFloat) -> CGFloat {
        min(max(natural, viewport), bottom - height)
    }

    private func layoutTitle() {
        guard let scroll else { return }
        // [T-pinned-section-collapse] A folded bucket has no members, so the
        // first/last probes that give this overlay its bounds are stale at
        // best: hide the sticky copy and let the real SwiftUI header (with
        // its right-pointing chevron) be the visible one.
        guard enabled, !PinnedSectionState.isCollapsedNow else { surface.isHidden = true; return }
        if let h = headerProbe, h.window != nil, h.isDescendant(of: scroll) {
            // Use the supplementary container's height, not just the Text's
            // glyph box: this preserves the native section header spacing.
            var container: UIView = h
            var p = h.superview
            while let v = p, v !== scroll {
                if (v is UICollectionReusableView && !(v is UICollectionViewCell)) || v is UITableViewHeaderFooterView {
                    container = v; break
                }
                p = v.superview
            }
            if container.bounds.height > 0 { headerHeight = container.bounds.height }
            labelX = max(12, h.convert(h.bounds, to: scroll).minX)
        }
        if let v = firstProbe, v.window != nil, v.isDescendant(of: scroll) {
            firstY = v.convert(v.bounds, to: scroll).minY
        }
        if let v = lastProbe, v.window != nil, v.isDescendant(of: scroll) {
            lastY = v.convert(v.bounds, to: scroll).maxY
        }
        // Offscreen probes may be recycled; retain the last CONTENT-space
        // boundary, not a viewport-space snapshot. New rows remeasure it.
        guard let firstY else { surface.isHidden = true; return }
        let viewport = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let y = Self.titleY(natural: firstY - headerHeight, viewport: viewport,
                            bottom: lastY ?? .greatestFiniteMagnitude, height: headerHeight)
        surface.isHidden = y + headerHeight <= viewport || y >= scroll.contentOffset.y + scroll.bounds.height
        surface.frame = CGRect(x: 0, y: y, width: scroll.bounds.width, height: headerHeight)
        label.text = AppLocalized("Pinned")
        let fontSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        label.frame = CGRect(x: labelX, y: 0, width: max(0, surface.bounds.width - labelX - 16), height: headerHeight)
        // [T-sidebar-title-glyph-removal] The gutter glyph is gone, so the
        // sticky copy draws NOTHING left of `labelX` any more: both bucket
        // titles start exactly at the SwiftUI header's text edge, and the
        // handover between the two copies is a pure cross-fade of the same
        // title at the same x. `label.frame` above was never touched by the
        // glyph (it hung outside the layout flow), which is why removing it
        // moves nothing.
        // [T-pinned-section-collapse] Chevron right after the title, matching
        // the SwiftUI header's 4pt spacing and 11pt glyph.
        let titleWidth = min(label.intrinsicContentSize.width,
                             max(0, surface.bounds.width - labelX - 30))
        let chevronSize: CGFloat = 11
        chevron.frame = CGRect(x: labelX + titleWidth + 4,
                               y: (headerHeight - chevronSize) / 2,
                               width: chevronSize, height: chevronSize)
        chevron.transform = CGAffineTransform(rotationAngle: chevronAngle)
        // Keep the title in front of newly inserted rows; scrollView still
        // receives all taps and drops through this noninteractive surface.
        scroll.bringSubviewToFront(surface)
    }
}

/// [T-pinned-section-collapse] Fold state of the "置顶" bucket.
///
/// A tiny store instead of a `ContentView` @State on purpose. The pinned
/// bucket collapses through the NATIVE ACCORDION's own display-link motion —
/// the same 0.25s reveal a folder card gets — and that motion is driven by
/// `NativeAccordionController`, which can only react to a change it can see.
/// Keeping the flag here means:
///   • the header row re-renders its chevron on its own (`@ObservedObject`),
///   • the accordion observes `didChange` and animates the section height,
///   • `ContentView`'s body never rebuilds its grouping for a pure fold, so
///     the sidebar memo and the row identities stay exactly as they were.
///
/// Persisted like the folder accordion, never synced.
@MainActor
final class PinnedSectionState: ObservableObject {
    static let shared = PinnedSectionState()
    /// Non-isolated because `isCollapsedNow` (below) reads it from code that
    /// must stay callable off the SwiftUI actor path.
    nonisolated static let defaultsKey = "pinnedSectionCollapsed"
    static let didChange = Notification.Name("PinnedSectionStateDidChange")

    @Published private(set) var isCollapsed: Bool

    /// Thread-safe, actor-free read for call sites that are not views (the
    /// accordion's geometry code runs on the main thread anyway, but a plain
    /// `UserDefaults` read keeps those paths free of actor hops).
    nonisolated static var isCollapsedNow: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private init() {
        isCollapsed = Self.isCollapsedNow
    }

    func toggle() {
        let next = !isCollapsed
        isCollapsed = next
        UserDefaults.standard.set(next, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// [T-sidebar-recent-section] Fold state of the "最近" bucket.
///
/// A byte-for-byte sibling of `PinnedSectionState`: same tiny store, same
/// persisted-key discipline, same `didChange` contract. Both buckets are date
/// buckets that fold through the native accordion's reveal motion, so the
/// accordion has to be able to observe them WITHOUT rebuilding the grouping —
/// hence a store outside `ContentView`'s @State.
@MainActor
final class RecentSectionState: ObservableObject {
    static let shared = RecentSectionState()
    nonisolated static let defaultsKey = "recentSectionCollapsed"
    static let didChange = Notification.Name("RecentSectionStateDidChange")

    @Published private(set) var isCollapsed: Bool

    /// Actor-free read for the accordion's geometry path (same reason as the
    /// pinned bucket's).
    nonisolated static var isCollapsedNow: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private init() {
        isCollapsed = Self.isCollapsedNow
    }

    func toggle() {
        let next = !isCollapsed
        isCollapsed = next
        UserDefaults.standard.set(next, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// [T-sidebar-title-glyph-removal] The leading-glyph geometry block used to live
// here: a 10pt symbol (a pin, and for 最近 a clock) drawn in a 14pt leading
// gutter as an out-of-flow overlay. Both date-bucket titles now carry NO
// leading glyph at all — the user asked for exactly that — so the geometry had
// no reader left and was deleted with them. The titles' x is unchanged: the
// glyph was always an overlay at a negative offset, never an HStack member, so
// nothing about the text's own layout depended on it. What remains of each
// header row is exactly [title][chevron], plus the Recent bucket's unread
// counter between them, and the sticky UIKit copy paints the same.

/// The pinned bucket's header row: title, and the chevron that folds the
/// bucket. Its own view so the chevron tracks `PinnedSectionState` without
/// `ContentView` observing the flag.
///
/// [T-sidebar-title-glyph-removal] No leading glyph any more: the pin that used
/// to hang in the gutter is gone, and the title is still the row's first
/// element at the same x it always had.
struct PinnedSectionHeaderRow: View {
    let label: String
    /// False in a result set: the bucket there is the search result list, so
    /// the chevron would fold away exactly what matched (same rule the folder
    /// cards follow — no fold chevron in results).
    var folds: Bool = true
    @ObservedObject private var state = PinnedSectionState.shared

    var body: some View {
        HStack(spacing: 4) {
            // Bucket labels are English keys; localize at display only.
            Text(LocalizedStringKey(label))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(UIColor.secondaryLabel))
            if folds {
                // Same chevron language as the folder cards: down while the
                // chats are on screen, pointing right once they are folded.
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                    .rotationEffect(.degrees(state.isCollapsed ? -90 : 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if folds { state.toggle() } }
        .animation(.easeInOut(duration: 0.25), value: state.isCollapsed)
        .textCase(nil)
        .accessibilityAddTraits(folds ? .isButton : [])
    }
}

/// Rows of the pinned bucket for the plain-List paths (search results,
/// multi-select, iPad/Mac sidebar). The native accordion animates its own
/// collapse, but a `List` has no reveal concept — there the rows simply have
/// to stop being rows — and the fold flag lives outside `ContentView`, so the
/// decision needs an observing wrapper of its own.
struct PinnedBucketRows<Rows: View>: View {
    @ObservedObject private var state = PinnedSectionState.shared
    /// True only for the pinned bucket, and only where folding applies.
    let active: Bool
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        if active && state.isCollapsed {
            EmptyView()
        } else {
            rows()
        }
    }
}

/// [T-sidebar-recent-unread-badge] The red counter beside the "最近" title —
/// the official header reads 最近 (1).
///
/// A COUNT, not a dot: it is the number of unread chats the bucket currently
/// lists, computed by the caller from `SessionBadgeStore.unreadSessionIds` and
/// the bucket's own ids (`RecentSectionPlanner.unreadCount`). Nothing here
/// remembers a number, so opening one chat (the existing mark-read path) or
/// "全部已读" moves it on the next pass. Zero never reaches this view — the
/// caller hides it.
struct RecentUnreadBadge: View {
    let count: Int

    var body: some View {
        // `verbatim`: this is a number, not a translatable sentence.
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            // One digit reads as a circle (18pt), three as a pill — the
            // official shape, and it keeps the header's height at 18pt either
            // way so a 32pt label slot never grows.
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color.red))
            // Non-localized on purpose: the visible text is the number, and
            // the header is announced with it.
            .accessibilityLabel(Text(verbatim: "\(count) unread"))
    }
}

/// [T-sidebar-recent-section] The "最近" bucket's header row: the title, the
/// unread counter, the fold chevron, and "全部已读" on the right.
///
/// [T-sidebar-title-glyph-removal] No leading glyph: the clock that used to
/// hang in the gutter is gone, and the title is still the row's first element
/// at the same x — it was never an HStack member, so nothing moved.
///
/// Deliberately a TWIN of `PinnedSectionHeaderRow`: same title `Text`, same
/// `.subheadline.weight(.semibold)`, same 4pt gap, same 11pt chevron, same
/// 0.25s fold animation — so "最近" and "置顶" share one text edge by
/// construction rather than by eye.
struct RecentSectionHeaderRow: View {
    let label: String
    /// [T-sidebar-recent-unread-badge] Unread chats currently listed in the
    /// bucket. 0 hides BOTH the badge and "全部已读": there is nothing to mark
    /// read, and a control that looks live but does nothing is worse than no
    /// control. Fed from the store every pass — this view owns no counter.
    var unreadCount: Int = 0
    /// False in a result set (see `PinnedSectionHeaderRow.folds`).
    var folds: Bool = true
    /// "全部已读". Optional so a caller with nothing to clear (and the UIKit
    /// fixture) renders the header without the button.
    var markAllRead: (() -> Void)? = nil
    @ObservedObject private var state = RecentSectionState.shared

    var body: some View {
        HStack(spacing: 4) {
            // THE FOLD TAP AREA: title + badge + chevron, stretched over all
            // the width left of the button. The tap lives on this CHILD rather
            // than on the whole row precisely so it cannot overlap "全部已读":
            // the button is a SIBLING, not something inside the tappable
            // region, so neither control has to win a gesture race.
            HStack(spacing: 4) {
                // Bucket labels are English keys; localize at display only.
                Text(LocalizedStringKey(label))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                if unreadCount > 0 {
                    RecentUnreadBadge(count: unreadCount)
                }
                if folds {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                        .rotationEffect(.degrees(state.isCollapsed ? -90 : 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if folds { state.toggle() } }

            if let markAllRead, unreadCount > 0 {
                Button(action: markAllRead) {
                    Text("Mark All as Read")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        // NO vertical padding on purpose: the row's height must
                        // stay the title's own (~20pt), or "最近" would be a
                        // few points taller than "置顶" everywhere the header is
                        // laid out by content (the iPad split list) instead of
                        // by the accordion's fixed 32pt slot. `contentShape`
                        // still makes the whole word tappable.
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mark All as Read"))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.isCollapsed)
        .textCase(nil)
        .accessibilityAddTraits(folds ? .isButton : [])
    }
}

/// [T-sidebar-recent-section] Rows of the Recent bucket for the plain-List
/// paths — same contract as `PinnedBucketRows`, different flag.
struct RecentBucketRows<Rows: View>: View {
    @ObservedObject private var state = RecentSectionState.shared
    let active: Bool
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        if active && state.isCollapsed {
            EmptyView()
        } else {
            rows()
        }
    }
}

struct PinnedBoundaryProbe: UIViewRepresentable {
    let owner: StablePinnedTitle
    let edge: StablePinnedTitle.Edge?
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ v: Probe, context: Context) {
        v.owner = owner; v.edge = edge; v.report()
    }
    final class Probe: UIView {
        weak var owner: StablePinnedTitle?
        var edge: StablePinnedTitle.Edge?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        func report() { if let edge { owner?.report(self, edge: edge) } }
    }
}
