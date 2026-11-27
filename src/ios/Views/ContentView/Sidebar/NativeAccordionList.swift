import SwiftUI
import UIKit

struct AccordionRenderSection {
    var group: SidebarGroup
    var members: [String]
    var geometry: AccordionSectionGeometry
    var expanded: Bool {
        // [T-pinned-section-collapse] The pinned bucket is the one date bucket
        // that folds. Its flag lives in PinnedSectionState (not in the group,
        // whose grouping is shared with the plain-List paths), so read it
        // here: `reveal` 0 then animates the rows away exactly like a folder.
        if group.folderId == nil, group.label == "Pinned" {
            return !PinnedSectionState.isCollapsedNow
        }
        return group.folderId == nil || !group.isCollapsed
    }
}
enum AccordionCellRole { case label, folder, member(Int) }
final class AccordionViewportState {
    var offset: CGFloat?
}

/// Only the compact, non-search, non-selection path uses this renderer.
/// Existing SwiftUI row actions/menus/drag/drop remain the source of truth.
struct NativeAccordionList: UIViewControllerRepresentable {
    var sections: [AccordionRenderSection]
    var viewport: AccordionViewportState
    var bottomInset: CGFloat = 76
    var toggle: (String) -> Void
    var render: (SidebarGroup, Int, AccordionCellRole) -> AnyView
    func makeUIViewController(context: Context) -> NativeAccordionController {
        NativeAccordionController(viewport: viewport, bottomInset: bottomInset)
    }
    func updateUIViewController(_ controller: NativeAccordionController, context: Context) {
        controller.bottomInset = bottomInset
        controller.onToggle = toggle
        controller.receive(sections, render: render)
    }
    static func dismantleUIViewController(_ controller: NativeAccordionController, coordinator: ()) {
        controller.stop()
    }
}

/// Row renderer. A plain UIHostingController added as a child inherits the
/// enclosing navigation controller and, on iOS 16-18, bridges ITS OWN (empty)
/// toolbar / bar-visibility preferences to it when it (re)enters a window.
/// Upstream documents the same failure for a nested host: an empty state
/// bridged to the navigation controller removes the whole bar until relaunch.
/// Rows never own navigation chrome, so cut them off from it entirely.
final class AccordionRowHostingController: UIHostingController<AnyView> {
    override var navigationController: UINavigationController? { nil }
}

final class AccordionHostingCell: UICollectionViewCell {
    private var host: AccordionRowHostingController?
    private var fullHeight: CGFloat = 0
    private var cardClipMask: CAShapeLayer?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.clipsToBounds = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() {
        super.prepareForReuse()
        applyCardClip(nil)
    }
    static func liveCardClipPath(for card: CGRect, radius r: CGFloat = 16, bleed: CGFloat = 1.0) -> CGPath {
        let cr = min(r, card.width / 2, card.height / 2)
        let tr = cr + bleed
        // Top + upper side walls bleed outward by `bleed` with concentric top
        // arcs (cr + bleed) so the outer half of the 0.75pt top/side border
        // stroke survives unclipped while any rectangular spandrel outside the
        // top corners is still masked off; the bottom corners follow `card` at
        // exact `cr` so .top/.middle fills never leave residue while folding.
        let topArcEndY = card.minY + cr
        let bottomArcStartY = max(topArcEndY, card.maxY - cr)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: card.minX - bleed, y: topArcEndY))
        p.addArc(withCenter: CGPoint(x: card.minX + cr, y: topArcEndY),
                 radius: tr, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        p.addLine(to: CGPoint(x: card.maxX - cr, y: card.minY - bleed))
        p.addArc(withCenter: CGPoint(x: card.maxX - cr, y: topArcEndY),
                 radius: tr, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: true)
        p.addLine(to: CGPoint(x: card.maxX + bleed, y: bottomArcStartY))
        p.addLine(to: CGPoint(x: card.maxX, y: bottomArcStartY))
        p.addArc(withCenter: CGPoint(x: card.maxX - cr, y: bottomArcStartY),
                 radius: cr, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: card.minX + cr, y: card.maxY))
        p.addArc(withCenter: CGPoint(x: card.minX + cr, y: bottomArcStartY),
                 radius: cr, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: card.minX - bleed, y: bottomArcStartY))
        p.close()
        return p.cgPath
    }
    func applyCardClip(_ localCardRect: CGRect?) {
        guard let localCardRect, localCardRect.width > 0, localCardRect.height > 0 else {
            if contentView.layer.mask != nil { contentView.layer.mask = nil }
            return
        }
        let mask = cardClipMask ?? {
            let m = CAShapeLayer()
            cardClipMask = m
            return m
        }()
        mask.path = Self.liveCardClipPath(for: localCardRect)
        if contentView.layer.mask !== mask {
            contentView.layer.mask = mask
        }
    }
    func set(_ content: AnyView, height: CGFloat, overflow: CGFloat = 0, owner: UIViewController) {
        // `overflow` lets a collapsed folder card own its 4pt bottom gap (the
        // empty footer slot below it) so the context-menu preview can have
        // equal margins on all four sides. Nothing else lives in that slot.
        let height = height + overflow
        fullHeight = height
        contentView.clipsToBounds = overflow == 0
        clipsToBounds = overflow == 0
        // The collection owns screen safe areas. A row host is only a local
        // drawing surface: inheriting the window's safe area can inset its
        // SwiftUI content as the cell scrolls/re-enters the viewport, while
        // the outer cell still clips to the invariant row height (iOS 16).
        // Ignore container safe areas at the host root, not at the collection;
        // keep the full-height frame and cell clipping for accordion reveal.
        let root = AnyView(
            content.frame(maxWidth: .infinity)
                .frame(height: height, alignment: .top)
                .ignoresSafeArea(.container, edges: .all)
        )
        if let host { host.rootView = root }
        else {
            let next = AccordionRowHostingController(rootView: root)
            // Collection layout owns the viewport safe area. Forwarding it
            // again into a fixed-height row can shift its SwiftUI body upward.
            if #available(iOS 16.4, *) { next.safeAreaRegions = [] }
            next.view.backgroundColor = .clear
            owner.addChild(next)
            contentView.addSubview(next.view)
            next.didMove(toParent: owner)
            host = next
        }
        setNeedsLayout()
    }
    func clear() { applyCardClip(nil); host?.rootView = AnyView(EmptyView()) }
    override func layoutSubviews() {
        super.layoutSubviews()
        // The host never sees the partially-revealed cell height. Text is NOT
        // scaled, squeezed, or measured again during the animation.
        host?.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fullHeight)
    }
}

final class NativeAccordionController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    typealias Renderer = (SidebarGroup, Int, AccordionCellRole) -> AnyView
    let accordionLayout = AccordionCollectionLayout()
    private(set) lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: accordionLayout)
    private var sections: [AccordionRenderSection] = []
    private var renderer: Renderer?
    private var pending: ([AccordionRenderSection], Renderer)?
    private let viewport: AccordionViewportState
    var bottomInset: CGFloat
    var onToggle: ((String) -> Void)?
    private var restored = false
    private var link: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.25
    private var from: [CGFloat] = []
    private var to: [CGFloat] = []
    private var anchorSection = 0
    private var anchorStartY: CGFloat = 0
    private var anchorEndY: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var endOffset: CGFloat = 0
    private var reservedHeight: CGFloat = 0
    private var motionWidth: CGFloat = 0
    private var miniFolderID: String?
    private let miniBar = UIView()
    private let miniTitle = UIButton(type: .system)
    private let miniCollapse = UIButton(type: .system)
    private let liveBottomCapView = UIView()
    private let liveBottomCapLayer = CAShapeLayer()
    private var tickTarget: AccordionDisplayTarget?
    /// [T-pinned-section-collapse] Pinned fold requested while another
    /// section's motion was running; applied by finishMotion.
    private var pendingPinnedTarget: [CGFloat]?
    private var observers: [NSObjectProtocol] = []
    private(set) var configuredCellCount = 0 // simulator performance assertions

    init(viewport: AccordionViewportState, bottomInset: CGFloat) { self.viewport = viewport; self.bottomInset = bottomInset; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collection.backgroundColor = .systemBackground
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .onDrag
        collection.contentInsetAdjustmentBehavior = .never
        collection.register(AccordionHostingCell.self, forCellWithReuseIdentifier: "row")
        liveBottomCapView.isUserInteractionEnabled = false
        liveBottomCapView.backgroundColor = .clear
        liveBottomCapView.isHidden = true
        liveBottomCapLayer.fillColor = nil
        liveBottomCapLayer.lineWidth = 0.75
        liveBottomCapView.layer.addSublayer(liveBottomCapLayer)
        collection.addSubview(liveBottomCapView)
        view.addSubview(collection)
        miniBar.backgroundColor = .secondarySystemBackground
        miniBar.layer.cornerRadius = 24
        miniBar.layer.shadowOpacity = 0.1
        miniBar.layer.shadowRadius = 5
        miniBar.isHidden = true
        view.addSubview(miniBar)
        miniTitle.contentHorizontalAlignment = .leading
        miniTitle.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        miniTitle.setTitleColor(.label, for: .normal)
        miniTitle.addTarget(self, action: #selector(revealHeader), for: .touchUpInside)
        miniCollapse.setImage(UIImage(systemName: "chevron.up.circle.fill"), for: .normal)
        miniCollapse.accessibilityLabel = AppLocalized("Collapse")
        miniCollapse.addTarget(self, action: #selector(collapseFromBar), for: .touchUpInside)
        miniBar.addSubview(miniTitle); miniBar.addSubview(miniCollapse)
        observers = [UIApplication.willResignActiveNotification, UIAccessibility.reduceMotionStatusDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishMotion() }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.probeNavigationBar("active")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.probeNavigationBar("active+0.6") }
            }
        })
        // [T-pinned-section-collapse] The pinned bucket folds through the SAME
        // reveal motion a folder card gets. Its flag lives outside SwiftUI's
        // grouping (PinnedSectionState), so the controller watches it directly
        // and runs one motion here instead of waiting for a data rebuild that
        // would only reload the list.
        observers.append(NotificationCenter.default.addObserver(
            forName: PinnedSectionState.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pinnedSectionStateChanged() }
            })
    }

    /// One reveal motion for the pinned bucket, mirroring what `receive(_:)`
    /// does when a folder's collapse flag flips: same duration, same easing,
    /// same scroll anchor, same reduce-motion / tracking guards.
    private func pinnedSectionStateChanged() {
        guard let index = sections.firstIndex(where: { $0.group.folderId == nil && $0.group.label == "Pinned" }),
              accordionLayout.reveal.indices.contains(index) else { return }
        var target = accordionLayout.reveal
        target[index] = PinnedSectionState.isCollapsedNow ? 0 : 1
        guard target != accordionLayout.reveal else { return }
        if link != nil {
            // A folder is mid-fold; the display link owns the layout. Land on
            // the requested state when it finishes rather than stacking moves.
            pendingPinnedTarget = target
            return
        }
        guard view.window != nil, !UIAccessibility.isReduceMotionEnabled,
              !collection.isTracking, !collection.isDragging, !collection.isDecelerating,
              collection.bounds.height > 0 else {
            accordionLayout.reveal = target
            accordionLayout.invalidateLayout()
            collection.layoutIfNeeded()
            refreshVisible()
            updateMiniBar()
            return
        }
        beginMotion(from: accordionLayout.reveal, to: target)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if link != nil, abs(motionWidth - view.bounds.width) > 0.5 { finishMotion() }
        collection.frame = view.bounds
        // FloatingSidebarSurface gives the collection a full-height viewport.
        // Insets provide end-of-scroll clearance, NOT a permanently empty panel:
        // rows still draw through this region at intermediate scroll positions.
        let top = view.safeAreaInsets.top
        let bottom = max(0, view.safeAreaInsets.bottom) + max(0, bottomInset)
        if collection.contentInset.top != top || collection.contentInset.bottom != bottom {
            collection.contentInset.top = top
            collection.contentInset.bottom = bottom
            collection.scrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        if !restored, !sections.isEmpty, collection.bounds.height > 0 {
            restored = true
            collection.layoutIfNeeded()
            let y = AccordionMotion.clampedOffset(viewport.offset ?? -collection.adjustedContentInset.top,
                contentHeight: accordionLayout.naturalHeight, viewportHeight: collection.bounds.height,
                inset: collection.adjustedContentInset)
            collection.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        updateMiniBar()
    }
    override func viewWillDisappear(_ animated: Bool) {
        finishMotion(); viewport.offset = collection.contentOffset.y
        super.viewWillDisappear(animated)
    }
    /// MOD diagnostics: record the home navigation bar state into crash
    /// breadcrumbs (Library/Application Support/Crumbs) whenever the sidebar
    /// reappears or the app returns to foreground, and only on CHANGE.
    /// The bar going missing leaves no other trace; this lets the next
    /// occurrence be matched to the exact preceding page/sheet transition.
    private var lastNavProbe = ""
    func probeNavigationBar(_ why: String) {
        guard let nav = parent?.navigationController ?? navigationController else {
            if lastNavProbe != "nonav" { lastNavProbe = "nonav"; CrashBreadcrumbs.record("navbar", detail: "\(why) no-nav") }
            return
        }
        let bar = nav.navigationBar
        let item = bar.topItem ?? nav.topViewController?.navigationItem
        var left = (item?.leftBarButtonItems?.count ?? 0)
        var right = (item?.rightBarButtonItems?.count ?? 0)
        if #available(iOS 16.0, *) {
            left += item?.leadingItemGroups.reduce(0) { $0 + $1.barButtonItems.count } ?? 0
            right += item?.trailingItemGroups.reduce(0) { $0 + $1.barButtonItems.count } ?? 0
        }
        let state = "hidden=\(nav.isNavigationBarHidden ? 1 : 0) barHidden=\(bar.isHidden ? 1 : 0) inWin=\(bar.window != nil ? 1 : 0) alpha=\(String(format: "%.2f", bar.alpha)) h=\(Int(bar.bounds.height)) L=\(left) R=\(right) title=\(item?.titleView != nil ? 1 : 0) depth=\(nav.viewControllers.count)"
        guard state != lastNavProbe else { return }
        lastNavProbe = state
        CrashBreadcrumbs.record("navbar", detail: "\(why) \(state)")
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        probeNavigationBar("appear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.probeNavigationBar("appear+0.6") }
    }
    func stop() {
        pending = nil
        pendingPinnedTarget = nil
        finishMotion()
        viewport.offset = collection.contentOffset.y
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        renderer = nil
        collection.visibleCells.forEach { ($0 as? AccordionHostingCell)?.clear() }
    }
    deinit { link?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func receive(_ next: [AccordionRenderSection], render: @escaping Renderer, allowAnimation: Bool = true) {
        loadViewIfNeeded()
        if link != nil { pending = (next, render); return } // latest intent wins
        let sameMembers = sections.count == next.count && zip(sections, next).allSatisfy { pair in
            pair.0.group.id == pair.1.group.id && pair.0.members == pair.1.members && pair.0.geometry == pair.1.geometry
        }
        let old = accordionLayout.reveal
        renderer = render
        sections = next.map { item in
            var copy = item
            if copy.group.ids != copy.members { copy.group.ids = copy.members }
            return copy
        }
        accordionLayout.sections = next.map(\.geometry)
        let target: [CGFloat] = next.map { $0.expanded ? 1 : 0 }
        if allowAnimation, sameMembers, old != target, view.window != nil, !UIAccessibility.isReduceMotionEnabled,
           !collection.isTracking, !collection.isDragging, !collection.isDecelerating {
            beginMotion(from: old, to: target)
        } else {
            accordionLayout.reveal = target
            accordionLayout.invalidateLayout()
            if !sameMembers { collection.reloadData() }
            collection.layoutIfNeeded()
            refreshVisible()
            updateMiniBar()
        }
    }

    private func beginMotion(from old: [CGFloat], to target: [CGFloat]) {
        guard old.count == target.count, !target.isEmpty else { return }
        from = old; to = target
        accordionLayout.prepare()
        anchorSection = target.indices.first(where: { target[$0] > old[$0] })
            ?? target.indices.first(where: { target[$0] != old[$0] }) ?? 0
        anchorStartY = accordionLayout.headerY(section: anchorSection)
        startOffset = collection.contentOffset.y
        motionWidth = collection.bounds.width
        let oldHeight = accordionLayout.naturalHeight
        accordionLayout.reveal = target
        accordionLayout.prepare()
        anchorEndY = accordionLayout.headerY(section: anchorSection)
        let inset = collection.adjustedContentInset
        let screenY = anchorStartY - startOffset
        let headerVisible = screenY >= inset.top && screenY < collection.bounds.height - inset.bottom
        let desired = headerVisible ? startOffset + anchorEndY - anchorStartY : anchorEndY - inset.top - 8
        endOffset = AccordionMotion.clampedOffset(desired,
            contentHeight: accordionLayout.naturalHeight, viewportHeight: collection.bounds.height, inset: inset)
        reservedHeight = max(oldHeight, accordionLayout.naturalHeight + max(0, startOffset - endOffset),
                             startOffset + collection.bounds.height - inset.bottom)
        accordionLayout.reveal = old
        accordionLayout.minimumContentHeight = reservedHeight
        accordionLayout.prepare()
        animationStart = CACurrentMediaTime()
        let proxy = AccordionDisplayTarget(owner: self)
        tickTarget = proxy
        let displayLink = CADisplayLink(target: proxy, selector: #selector(AccordionDisplayTarget.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link = displayLink
        // Refresh only once per state transition; not on every animation frame.
        refreshVisible()
        updateLiveCardClips()
        miniBar.isHidden = true
        displayLink.add(to: .main, forMode: .common)
    }

    fileprivate func advance(_ timestamp: CFTimeInterval) {
        guard link != nil else { return }
        let elapsed = timestamp - animationStart
        if elapsed >= duration { finishMotion(allowPendingAnimation: true); return }
        let p = AccordionMotion.ease(CGFloat(elapsed / duration))
        accordionLayout.reveal = zip(from, to).map { pair in pair.0 + (pair.1 - pair.0) * p }
        accordionLayout.prepare()
        accordionLayout.translation = AccordionMotion.translation(startHeader: anchorStartY,
            currentHeader: accordionLayout.headerY(section: anchorSection), endHeader: anchorEndY,
            startOffset: startOffset, endOffset: endOffset, progress: p)
        UIView.performWithoutAnimation {
            accordionLayout.invalidateLayout()
            collection.layoutIfNeeded()
            updateLiveCardClips()
        }
    }

    private func finishMotion(allowPendingAnimation: Bool = false) {
        guard let running = link else { return }
        running.invalidate(); link = nil; tickTarget = nil
        UIView.performWithoutAnimation {
            // Geometry and offset commit in the SAME main-thread transaction;
            // no visible frame has the un-translated layout with the old offset.
            accordionLayout.reveal = to
            accordionLayout.translation = 0
            accordionLayout.minimumContentHeight = 0
            accordionLayout.invalidateLayout()
            collection.setContentOffset(CGPoint(x: 0, y: endOffset), animated: false)
            collection.layoutIfNeeded()
            clearLiveCardClips()
        }
        refreshVisible(); updateMiniBar()
        if let queued = pendingPinnedTarget {
            pendingPinnedTarget = nil
            // Land the fold the user asked for while a folder was moving.
            if queued != accordionLayout.reveal, accordionLayout.reveal.count == queued.count {
                beginMotion(from: accordionLayout.reveal, to: queued)
                return
            }
        }
        if let latest = pending {
            pending = nil
            receive(latest.0, render: latest.1, allowAnimation: allowPendingAnimation)
        }
    }

    private func clearLiveCardClips() {
        liveBottomCapView.isHidden = true
        liveBottomCapLayer.path = nil
        for cell in collection.visibleCells {
            (cell as? AccordionHostingCell)?.applyCardClip(nil)
            guard let path = collection.indexPath(for: cell),
                  sections.indices.contains(path.section) else { continue }
            let s = sections[path.section]
            if s.group.folderId == nil, path.item >= s.geometry.prefixCount {
                let p = path.section < accordionLayout.reveal.count ? min(1, max(0, accordionLayout.reveal[path.section])) : 1
                cell.alpha = p
                cell.layer.zPosition = p < 0.999 ? -1 : 0
            }
        }
    }

    private func updateLiveCardClips() {
        guard link != nil else { clearLiveCardClips(); return }
        let width = collection.bounds.width
        let cardWidth = max(0, width - 12)
        guard cardWidth > 32, accordionLayout.starts.count == sections.count else {
            clearLiveCardClips()
            return
        }
        var activeCards: [Int: CGRect] = [:]
        let capPath = UIBezierPath()
        let r: CGFloat = 16
        for i in sections.indices {
            let s = sections[i]
            guard s.group.folderId != nil, !s.members.isEmpty, s.geometry.headerHeight > 0,
                  i < accordionLayout.reveal.count else { continue }
            let p = min(1, max(0, accordionLayout.reveal[i]))
            let changing = i < from.count && i < to.count && from[i] != to[i]
            guard changing || (p > 0 && p < 1) else { continue }
            let headerY = accordionLayout.starts[i] + accordionLayout.translation + s.geometry.labelHeight
            let cardTopY = headerY + 4
            let cardBottomY = headerY + s.geometry.headerHeight
                + max(0, min(s.geometry.fullHeight * p, s.geometry.fullHeight - 4))
            let cardRect = CGRect(x: 6, y: cardTopY, width: cardWidth, height: max(32, cardBottomY - cardTopY))
            activeCards[i] = cardRect
            if p < 0.999 {
                let yArc = cardRect.maxY - r
                capPath.move(to: CGPoint(x: cardRect.minX, y: yArc))
                capPath.addArc(withCenter: CGPoint(x: cardRect.minX + r, y: yArc),
                               radius: r, startAngle: .pi, endAngle: .pi / 2, clockwise: false)
                capPath.addLine(to: CGPoint(x: cardRect.maxX - r, y: cardRect.maxY))
                capPath.addArc(withCenter: CGPoint(x: cardRect.maxX - r, y: yArc),
                               radius: r, startAngle: .pi / 2, endAngle: 0, clockwise: false)
            }
        }
        for cell in collection.visibleCells {
            guard let hosting = cell as? AccordionHostingCell else { continue }
            guard let path = collection.indexPath(for: hosting) else {
                hosting.applyCardClip(nil)
                continue
            }
            let s = sections[path.section]
            if s.group.folderId == nil, path.item >= s.geometry.prefixCount,
               path.section < accordionLayout.reveal.count {
                let p = min(1, max(0, accordionLayout.reveal[path.section]))
                hosting.alpha = p
                hosting.layer.zPosition = p < 0.999 ? -1 : 0
            }
            guard let cardRect = activeCards[path.section] else {
                hosting.applyCardClip(nil)
                continue
            }
            let isLabel = s.geometry.labelHeight > 0 && path.item == 0
            let isHeader = s.geometry.headerHeight > 0 && path.item == s.geometry.prefixCount - 1
            if isLabel || (!isHeader && hosting.frame.maxY < cardRect.maxY - 20) {
                hosting.applyCardClip(nil)
            } else {
                hosting.applyCardClip(cardRect.offsetBy(dx: -hosting.frame.minX, dy: -hosting.frame.minY))
            }
        }
        if !capPath.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveBottomCapView.frame = CGRect(x: 0, y: 0, width: width, height: max(collection.bounds.height, accordionLayout.collectionViewContentSize.height))
            let stroke = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 1, alpha: 0.30)
                    : UIColor(white: 0, alpha: 0.08)
            }.resolvedColor(with: collection.traitCollection)
            liveBottomCapLayer.strokeColor = stroke.cgColor
            liveBottomCapLayer.path = capPath.cgPath
            liveBottomCapView.isHidden = false
            collection.bringSubviewToFront(liveBottomCapView)
            CATransaction.commit()
        } else {
            liveBottomCapView.isHidden = true
            liveBottomCapLayer.path = nil
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].geometry.itemCount
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! AccordionHostingCell
        configure(cell, at: indexPath)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if collectionView.indexPath(for: cell) == nil {
            (cell as? AccordionHostingCell)?.clear()
        }
    }
    private func configure(_ cell: AccordionHostingCell, at path: IndexPath) {
        guard sections.indices.contains(path.section), let renderer else { return }
        let s = sections[path.section]
        var group = s.group
        // Membership was normalized ONCE in receive(), not for every cell.
        // Keep the card connected throughout the closing interval.
        if link != nil && from.indices.contains(path.section) {
            group.isCollapsed = max(from[path.section], to[path.section]) <= 0
        }
        let role: AccordionCellRole
        let height: CGFloat
        if s.geometry.labelHeight > 0 && path.item == 0 {
            role = .label; height = s.geometry.labelHeight
        } else if s.geometry.headerHeight > 0 && path.item == s.geometry.prefixCount - 1 {
            role = .folder; height = s.geometry.headerHeight
        } else {
            let index = path.item - s.geometry.prefixCount
            guard s.members.indices.contains(index) else { return }
            role = .member(index); height = s.geometry.rowHeight
        }
        var overflow: CGFloat = 0
        if case .folder = role, group.isCollapsed || group.ids.isEmpty { overflow = s.geometry.footerHeight }
        cell.set(renderer(group, path.section, role), height: height, overflow: overflow, owner: self)
        // Prevent navigation through a partially clipped row. Header taps stay
        // active so a new request can replace the pending intent.
        if case .member = role {
            cell.isUserInteractionEnabled = link == nil
            cell.accessibilityElementsHidden = link != nil
        } else {
            cell.isUserInteractionEnabled = true
            cell.accessibilityElementsHidden = false
        }
        if link == nil { cell.applyCardClip(nil) }
        if group.folderId == nil, case .member = role, accordionLayout.reveal.indices.contains(path.section) {
            let p = min(1, max(0, accordionLayout.reveal[path.section]))
            cell.alpha = p
            cell.layer.zPosition = p < 0.999 ? -1 : 0
        } else {
            cell.alpha = 1
            if case .member = role { cell.layer.zPosition = 0 }
        }
        configuredCellCount += 1
    }
    private func refreshVisible() {
        for path in collection.indexPathsForVisibleItems {
            if let cell = collection.cellForItem(at: path) as? AccordionHostingCell { configure(cell, at: path) }
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if link == nil { updateMiniBar() }
        else { updateLiveCardClips() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A real gesture owns the scroll position. Finish once, then never
        // continue an anchor correction loop against the user's finger.
        finishMotion()
    }
    private func updateMiniBar() {
        guard isViewLoaded, link == nil else { return }
        let top = collection.contentOffset.y + collection.adjustedContentInset.top
        let found = sections.indices.first { i in
            sections[i].group.folderId != nil && sections[i].expanded && !sections[i].members.isEmpty
                && accordionLayout.starts.indices.contains(i)
                && accordionLayout.headerY(section: i) + sections[i].geometry.headerHeight < top
        }
        guard let i = found else { miniBar.isHidden = true; miniFolderID = nil; return }
        miniFolderID = sections[i].group.folderId
        miniTitle.setTitle(sections[i].group.label, for: .normal)
        miniBar.frame = CGRect(x: 16, y: view.safeAreaInsets.top + 4, width: max(0, view.bounds.width - 32), height: 48)
        miniTitle.frame = CGRect(x: 16, y: 0, width: max(0, miniBar.bounds.width - 68), height: 48)
        miniCollapse.frame = CGRect(x: miniBar.bounds.width - 48, y: 0, width: 48, height: 48)
        miniBar.isHidden = false
    }
    @objc private func revealHeader() {
        guard let id = miniFolderID, let i = sections.firstIndex(where: { $0.group.folderId == id }) else { return }
        let y = AccordionMotion.clampedOffset(accordionLayout.headerY(section: i) - collection.adjustedContentInset.top - 8,
            contentHeight: accordionLayout.naturalHeight, viewportHeight: collection.bounds.height,
            inset: collection.adjustedContentInset)
        collection.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }
    @objc private func collapseFromBar() { if let id = miniFolderID { onToggle?(id) } }
}

private final class AccordionDisplayTarget: NSObject {
    weak var owner: NativeAccordionController?
    init(owner: NativeAccordionController) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        // CADisplayLink fires on the main run loop; use the same explicit
        // isolation the StablePinnedTitle KVO observer already uses, instead of
        // annotating the class @MainActor (whose deinit was implicated in a
        // flaky test teardown after gesture interruption).
        MainActor.assumeIsolated {
            owner?.advance(link.timestamp)
        }
    }
}
