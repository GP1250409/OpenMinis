import SwiftUI
import UIKit

struct AccordionRenderSection {
    var group: SidebarGroup
    var members: [String]
    var geometry: AccordionSectionGeometry
    var expanded: Bool { group.folderId == nil || !group.isCollapsed }
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
    var toggle: (String) -> Void
    var render: (SidebarGroup, Int, AccordionCellRole) -> AnyView
    func makeUIViewController(context: Context) -> NativeAccordionController {
        NativeAccordionController(viewport: viewport)
    }
    func updateUIViewController(_ controller: NativeAccordionController, context: Context) {
        controller.onToggle = toggle
        controller.receive(sections, render: render)
    }
    static func dismantleUIViewController(_ controller: NativeAccordionController, coordinator: ()) {
        controller.stop()
    }
}

final class AccordionHostingCell: UICollectionViewCell {
    private var host: UIHostingController<AnyView>?
    private var fullHeight: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.clipsToBounds = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(_ content: AnyView, height: CGFloat, owner: UIViewController) {
        fullHeight = height
        let root = AnyView(content.frame(maxWidth: .infinity).frame(height: height, alignment: .top))
        if let host { host.rootView = root }
        else {
            let next = UIHostingController(rootView: root)
            next.view.backgroundColor = .clear
            owner.addChild(next)
            contentView.addSubview(next.view)
            next.didMove(toParent: owner)
            host = next
        }
        setNeedsLayout()
    }
    func clear() { host?.rootView = AnyView(EmptyView()) }
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
    var onToggle: ((String) -> Void)?
    private var restored = false
    private var link: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.32
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
    private var tickTarget: AccordionDisplayTarget?
    private var observers: [NSObjectProtocol] = []
    private(set) var configuredCellCount = 0 // simulator performance assertions

    init(viewport: AccordionViewportState) { self.viewport = viewport; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collection.backgroundColor = .systemBackground
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .onDrag
        collection.contentInsetAdjustmentBehavior = .automatic
        collection.register(AccordionHostingCell.self, forCellWithReuseIdentifier: "row")
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
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if link != nil, abs(motionWidth - view.bounds.width) > 0.5 { finishMotion() }
        collection.frame = view.bounds
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
    func stop() {
        pending = nil
        finishMotion()
        viewport.offset = collection.contentOffset.y
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        renderer = nil
        collection.visibleCells.forEach { ($0 as? AccordionHostingCell)?.clear() }
    }
    deinit { link?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func receive(_ next: [AccordionRenderSection], render: @escaping Renderer) {
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
        if sameMembers, old != target, view.window != nil, !UIAccessibility.isReduceMotionEnabled,
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
        miniBar.isHidden = true
        displayLink.add(to: .main, forMode: .common)
    }

    fileprivate func advance(_ timestamp: CFTimeInterval) {
        guard link != nil else { return }
        let elapsed = timestamp - animationStart
        if elapsed >= duration { finishMotion(); return }
        let p = AccordionMotion.ease(CGFloat(elapsed / duration))
        accordionLayout.reveal = zip(from, to).map { pair in pair.0 + (pair.1 - pair.0) * p }
        accordionLayout.prepare()
        accordionLayout.translation = AccordionMotion.translation(startHeader: anchorStartY,
            currentHeader: accordionLayout.headerY(section: anchorSection), endHeader: anchorEndY,
            startOffset: startOffset, endOffset: endOffset, progress: p)
        UIView.performWithoutAnimation {
            accordionLayout.invalidateLayout()
            collection.layoutIfNeeded()
        }
    }

    private func finishMotion() {
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
        }
        refreshVisible(); updateMiniBar()
        if let latest = pending {
            pending = nil
            receive(latest.0, render: latest.1)
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
        (cell as? AccordionHostingCell)?.clear()
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
        cell.set(renderer(group, path.section, role), height: height, owner: self)
        // Prevent navigation through a partially clipped row. Header taps stay
        // active so a new request can replace the pending intent.
        if case .member = role {
            cell.isUserInteractionEnabled = link == nil
            cell.accessibilityElementsHidden = link != nil
        } else {
            cell.isUserInteractionEnabled = true
            cell.accessibilityElementsHidden = false
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

private final class AccordionDisplayTarget {
    weak var owner: NativeAccordionController?
    init(owner: NativeAccordionController) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.advance(link.timestamp) }
}
