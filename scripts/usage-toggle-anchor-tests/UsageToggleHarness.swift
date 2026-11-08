import Foundation
import UIKit
import SwiftUI

// Fixture list: production `MessageListLayout` + production `SelfSizingCell`
// (UIHostingConfiguration content) + a real diffable data source of
// `MessageListItem`, in a real window. The only invented part is the row
// content, which mirrors the two geometry facts under test:
//   * a text row is tall (its estimate is already right — production memoizes
//     measured text heights, that is not what the recording shows breaking);
//   * the quiet usage footer is ~21pt tall but is SEEDED at 4pt
//     (`setEstimatedHeight(footerProminent ? 48 : 4, at:)`).

/// The quiet footer's content: one 12pt line + the production footer's 2pt
/// vertical padding. Real SwiftUI layout, so its height is measured, not fixed.
/// Drives the footer's hosted content through the two phases production
/// documents for a freshly inserted row: the FIRST layout pass sees only the
/// seed (`ready == false`, a 4pt strip), and the real hosted height arrives
/// with the hosting graph one run-loop later (`ready == true`). The cell
/// therefore self-sizes twice — exactly the estimate→measured correction the
/// 2026-11-08 recording shows on the insert side. Without this, a trivial
/// SwiftUI body resolves inside the very layout pass that runs with
/// `suppressContentOffsetAdjustment == true`, and the correction is silently
/// unpaid, which makes the insert and delete sides symmetric (0pt/cycle) and
/// hides the shipped bug instead of reproducing it.
final class FooterPhase: ObservableObject {
    @Published var ready = true
}

let quietFooterSeedHeight: CGFloat = 4

struct UsageStampFixture: View {
    @ObservedObject var phase: FooterPhase
    var body: some View {
        Group {
            if phase.ready {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 10))
                    Text("ctx:14k in:14k out:398 · 10/27 Tue 20:00")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            } else {
                // The seed itself: what `setEstimatedHeight(4)` reserves.
                Color.clear.frame(height: quietFooterSeedHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TextRowFixture: View {
    let height: CGFloat
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 15))
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
    }
}

final class UsageRow {
    let id = UUID()
    let isFooter: Bool
    let height: CGFloat
    let label: String
    init(isFooter: Bool, height: CGFloat, label: String) {
        self.isFooter = isFooter
        self.height = height
        self.label = label
    }
    var item: MessageListItem {
        isFooter ? .assistantFooter(id) : .assistantBlock(id, id)
    }
}

final class UsageHarness {
    let layout = MessageListLayout()
    let collection: TrackingCollectionView
    let controller: CollectionViewMessageListV3.ListViewController
    let coordinator = CollectionViewMessageListV3.Coordinator()
    private let window: UIWindow

    /// Rows in list order. `footerIndex` names the single footer row; every
    /// other row is text.
    private(set) var rows: [UsageRow]
    let footerIndex: Int
    /// True while the footer item is in the data source.
    private(set) var footerPresent = false
    /// Hosted-content phase for the footer row (seed strip → real stamp).
    let phase = FooterPhase()
    /// Production's quiet-footer seed (`+Snapshot.swift`, `footerProminent ? 48 : 4`).
    static let quietFooterSeed: CGFloat = 4

    var footerItem: MessageListItem { rows[footerIndex].item }
    var referenceIndex: Int { footerIndex + 1 }

    init(rowCount: Int, footerIndex: Int, textHeight: CGFloat, staggered: Bool = false,
         tallRowAt: Int? = nil, viewport: CGSize = CGSize(width: 390, height: 800)) {
        precondition(footerIndex < rowCount - 1, "a row must follow the footer")
        self.footerIndex = footerIndex
        var built: [UsageRow] = []
        for i in 0..<rowCount {
            if i == footerIndex {
                built.append(UsageRow(isFooter: true, height: 21, label: "usage footer"))
            } else {
                // A little variety so the list is not a uniform ladder; the
                // reference row keeps a stable, known height.
                var h = staggered ? textHeight + CGFloat((i % 3) * 30) : textHeight
                // One row much taller than the viewport, for the clipped-top case.
                if let tallRowAt, i == tallRowAt { h = 1400 }
                built.append(UsageRow(isFooter: false, height: h, label: "row \(i)"))
            }
        }
        self.rows = built

        collection = TrackingCollectionView(frame: CGRect(origin: .zero, size: viewport),
                                            collectionViewLayout: layout)
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collection.backgroundColor = .white
        collection.register(SelfSizingCell.self, forCellWithReuseIdentifier: "cell")
        controller = CollectionViewMessageListV3.ListViewController(collectionView: collection,
                                                                    messageListLayout: layout)
        window = UIWindow(frame: CGRect(origin: .zero, size: viewport))

        coordinator.viewController = controller
        coordinator.vm = CollectionViewMessageListV3.ViewModel()
        coordinator.scrollMode = .userBrowsing

        let ds = UICollectionViewDiffableDataSource<CollectionViewMessageListV3.Section, MessageListItem>(
            collectionView: collection) { [weak self] cv, ip, item in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "cell", for: ip) as! SelfSizingCell
                self?.configure(cell, item: item, index: ip.item)
                return cell
            }
        coordinator.dataSource = ds

        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: viewport)
        collection.frame = CGRect(origin: .zero, size: viewport)
        window.layoutIfNeeded()

        // Production never hands the collection view a snapshot without first
        // seeding the layout: `applySnapshot`'s seeding loop runs before every
        // apply, the first one included. Going straight through `ds.apply`
        // here left every off-screen row on `estimatedItemHeight` (200pt)
        // until the first toggle re-seeded it at 120pt, and that collapse —
        // not the footer — is what produced the 6740→4460 contentSize drop and
        // the −710pt first cycle.
        apply(showFooter: true, anchored: false)
        settle()
    }

    deinit { window.isHidden = true }

    /// Content keys are index-independent here on purpose: the production
    /// footer's `f:` key also withholds the 8pt hug gap, which is a symmetric
    /// effect (report §2) and would only blur the row-height measurement.
    private func configure(_ cell: SelfSizingCell, item: MessageListItem, index: Int) {
        // Resolve the row by IDENTITY. While the footer is hidden every later
        // item sits one index lower than its slot in `rows`, so `rows[index]`
        // rendered the wrong content (the row after the footer became a footer).
        guard let row = rows.first(where: { $0.item == item }) else { return }
        cell.rendersNonEmptyText = true
        cell.contentKey = "t:\(row.id.uuidString)"
        layout.setContentKey(cell.contentKey!, at: index)
        // Production's `configureCell` seeds the estimate at dequeue time
        // (`MessageListV3Coordinator+CellConfiguration.swift`), before the cell
        // can self-size. Mirroring it keeps the 4pt footer seed in place for a
        // cell UIKit realises outside the apply's seeding loop.
        let estimate = row.isFooter ? quietFooterSeedHeight : row.height
        if layout.cachedHeight(at: index) == nil { layout.setEstimatedHeight(estimate, at: index) }
        if row.isFooter {
            // Zero hosting margins so the row's height is the footer content
            // itself (seed strip = exactly 4pt) and not SwiftUI's default 8+8.
            cell.applyContentConfiguration(
                UIHostingConfiguration { UsageStampFixture(phase: phase) }.margins(.all, 0))
        } else {
            let h = row.height, label = row.label
            cell.applyContentConfiguration(UIHostingConfiguration { TextRowFixture(height: h, label: label) })
        }
    }

    // MARK: - Geometry

    func attrs(_ index: Int) -> UICollectionViewLayoutAttributes? {
        layout.layoutAttributesForItem(at: IndexPath(item: index, section: .zero))
    }
    func rowHeight(_ index: Int) -> CGFloat { attrs(index)?.frame.height ?? .nan }

    /// The row's current index inside the applied item list. Row identity is
    /// stable across a footer insert/delete, an index is not.
    func index(of item: MessageListItem) -> Int? {
        coordinator.dataSource?.snapshot().indexOfItem(item)
    }
    func attrs(of item: MessageListItem) -> UICollectionViewLayoutAttributes? {
        guard let i = index(of: item) else { return nil }
        return layout.layoutAttributesForItem(at: IndexPath(item: i, section: .zero))
    }
    /// Top edge of a row on screen, addressed by identity.
    func screenTop(of item: MessageListItem) -> CGFloat {
        guard let a = attrs(of: item) else { return .nan }
        return a.frame.minY - collection.contentOffset.y
    }
    /// The row the reader is watching: the one right below the footer.
    var referenceItem: MessageListItem { rows[referenceIndex].item }
    /// The row's top edge in screen coordinates (what the reader sees).
    func screenTop(_ index: Int) -> CGFloat {
        guard let a = attrs(index) else { return .nan }
        return a.frame.minY - collection.contentOffset.y
    }
    var footerRealHeight: CGFloat { rowHeight(footerIndex) }
    var maxOffset: CGFloat {
        max(0, collection.contentSize.height - collection.bounds.height
            + collection.adjustedContentInset.bottom)
    }

    /// Put the footer's bottom just above the viewport top, so a row-height
    /// change on the footer moves everything the reader sees — the exact
    /// situation in the 2026-11-08 recording.
    func scrollFooterAboveViewport(margin: CGFloat = 8) {
        guard let a = attrs(footerIndex) else { return }
        let y = a.frame.maxY + margin
        collection.setContentOffset(CGPoint(x: 0, y: min(y, maxOffset)), animated: false)
        collection.layoutIfNeeded()
    }

    /// Put the footer INSIDE the viewport (it is realised, so it self-sizes to
    /// its real height), `topInset` points below the viewport top. This is
    /// where the recording's double-tap happens: the footer is on screen.
    func scrollFooterIntoViewport(topInset: CGFloat = 300) {
        guard let a = attrs(footerIndex) else { return }
        let y = a.frame.minY - topInset
        collection.setContentOffset(CGPoint(x: 0, y: max(0, min(y, maxOffset))), animated: false)
        collection.layoutIfNeeded()
    }
    var aboveItem: MessageListItem { rows[footerIndex - 1].item }

    func scrollFooterBelowViewport() {
        guard let a = attrs(footerIndex) else { return }
        let y = a.frame.minY - collection.bounds.height + margin
        collection.setContentOffset(CGPoint(x: 0, y: max(0, min(y, maxOffset))), animated: false)
        collection.layoutIfNeeded()
    }
    private var margin: CGFloat { 24 }

    func scrollToBottom() {
        collection.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: false)
        collection.layoutIfNeeded()
    }

    // MARK: - Apply

    /// One structural apply, through the fixture mirror of `applySnapshot`.
    /// `showFooter` is the `bridge.showUsage` value: false means the footer row
    /// is not in the item list at all (production omits it — `needsFooter`).
    @discardableResult
    func apply(showFooter: Bool, anchored: Bool, onFirstLayout: (() -> Void)? = nil) -> Bool {
        var items = rows.map { $0.item }
        if !showFooter, let i = items.firstIndex(of: footerItem) { items.remove(at: i) }
        if showFooter, !items.contains(footerItem) { items.append(footerItem) }
        var estimates: [MessageListItem: CGFloat] = [:]
        for row in rows {
            estimates[row.item] = row.isFooter ? UsageHarness.quietFooterSeed : row.height
        }
        // Insert side, production timing: the row lays out at the 4pt seed in
        // the apply's own layout pass (`suppressContentOffsetAdjustment` is on
        // for it), and the real hosted height lands one run-loop later.
        if showFooter { phase.ready = false }
        coordinator.onFirstLayout = onFirstLayout
        coordinator.applyStructural(items: items, estimates: estimates, preserveVisibleAnchor: anchored)
        coordinator.onFirstLayout = nil
        footerPresent = showFooter
        if showFooter {
            DispatchQueue.main.async { [weak self] in self?.phase.ready = true }
        }
        return true
    }

    /// Let the hosting graph deliver the real heights and let the deferred
    /// restore (DispatchQueue.main.async) run, exactly as a frame boundary does
    /// in the app. Three layout passes with run-loop turns between them: the
    /// phase flip is a main-queue hop, the SwiftUI size change is a second
    /// transaction, and the cell's self-size correction is a third layout.
    func settle(_ seconds: Double = 0.10) {
        collection.layoutIfNeeded()
        pump(min(0.06, seconds))
        collection.layoutIfNeeded()
        pump(seconds)
        collection.layoutIfNeeded()
        pump(0.03)
        collection.layoutIfNeeded()
    }

    /// One compact geometry line, so a failing run says WHY it failed.
    /// Duplicate-render probe: how many cell VIEWS UIKit holds vs how many it
    /// reports visible, how many carry a pending Core Animation, and how far
    /// the on-screen (presentation) position of a cell is from its model
    /// position. A row drawn twice in one frame shows up here as extra views
    /// or as a presentation/model gap.
    func renderProbe(_ label: String) {
        let views = collection.subviews.compactMap { $0 as? UICollectionViewCell }
        let visible = collection.visibleCells
        let animated = views.filter { !($0.layer.animationKeys() ?? []).isEmpty }.count
        var maxGap: CGFloat = 0
        for v in views {
            if let p = v.layer.presentation() { maxGap = max(maxGap, abs(p.position.y - v.layer.position.y)) }
        }
        let keys = Set(views.flatMap { $0.layer.animationKeys() ?? [] }).sorted().joined(separator: "|")
        let ys = views.map { Int($0.frame.minY) }.sorted()
        let dup = ys.count - Set(ys).count
        print("PROBE \(label) cellViews=\(views.count) visible=\(visible.count) animated=\(animated)"
              + " presGap=\(f(maxGap)) sameY=\(dup) keys=[\(keys)]")
    }

    func trace(_ label: String) {
        let items = collection.numberOfItems(inSection: 0)
        let foot = footerPresent ? rowHeight(footerIndex) : -1
        let ri = index(of: referenceItem) ?? -1
        let attrs = ri >= 0
            ? layout.layoutAttributesForItem(at: IndexPath(item: ri, section: 0)) : nil
        let cached = layout.cachedHeight(at: footerIndex).map { String(format: "%.2f", $0) } ?? "nil"
        print("TRACE \(label) items=\(items) present=\(footerPresent ? 1 : 0)"
              + " foot=\(f(foot)) cache=\(cached)"
              + " off=\(f(collection.contentOffset.y)) cs=\(f(collection.contentSize.height))"
              + " refIdx=\(ri) refY=\(attrs.map { f($0.frame.minY) } ?? "nil")"
              + " refTop=\(attrs.map { f($0.frame.minY - collection.contentOffset.y) } ?? "nil")"
              + " aboveTop=\(f(screenTop(of: aboveItem)))"
              + " deferred=\(layout.deferredHeightCount)")
    }

    /// Like `cycle`, but reports BOTH neighbours of the footer: the row above
    /// it (never displaced by the footer's own height) and the row below it.
    func cycleBoth(anchored: Bool) -> (above: CGFloat, below: CGFloat) {
        let a0 = screenTop(of: aboveItem), b0 = screenTop(of: referenceItem)
        apply(showFooter: false, anchored: anchored)
        if traceCycles { trace("hide"); renderProbe("hide.apply") }
        settle()
        if traceCycles { trace("hide.settled") }
        apply(showFooter: true, anchored: anchored)
        if traceCycles { trace("show"); renderProbe("show.apply") }
        pump(0.004)
        if traceCycles { renderProbe("show.+4ms") }
        settle()
        if traceCycles { trace("show.settled"); renderProbe("show.settled") }
        return (screenTop(of: aboveItem) - a0, screenTop(of: referenceItem) - b0)
    }

    func pump(_ seconds: Double) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            let slice = min(0.004, end.timeIntervalSinceNow)
            if slice <= 0 { break }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: slice))
            RunLoop.main.run(mode: .common, before: Date(timeIntervalSinceNow: 0.0005))
        }
    }

    /// One show/hide cycle as the user performs it: hide, let it settle, show,
    /// let it settle. Returns the net movement of the row the reader watches.
    var traceCycles = false
    func cycle(anchored: Bool) -> CGFloat {
        let before = screenTop(of: referenceItem)
        apply(showFooter: false, anchored: anchored)
        if traceCycles { trace("hide") }
        settle()
        if traceCycles { trace("hide.settled") }
        apply(showFooter: true, anchored: anchored)
        if traceCycles { trace("show") }
        settle()
        if traceCycles { trace("show.settled") }
        return screenTop(of: referenceItem) - before
    }
}
