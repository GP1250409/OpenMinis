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
struct UsageStampFixture: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 10))
            Text("ctx:14k in:14k out:398 · 10/27 Tue 20:00")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
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
        super.init()

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

        var snap = NSDiffableDataSourceSnapshot<CollectionViewMessageListV3.Section, MessageListItem>()
        snap.appendSections([.main])
        snap.appendItems(rows.map { $0.item }, toSection: .main)
        ds.apply(snap, animatingDifferences: false)
        footerPresent = true
        collection.layoutIfNeeded()
        settle()
    }

    deinit { window.isHidden = true }

    /// Content keys are index-independent here on purpose: the production
    /// footer's `f:` key also withholds the 8pt hug gap, which is a symmetric
    /// effect (report §2) and would only blur the row-height measurement.
    private func configure(_ cell: SelfSizingCell, item: MessageListItem, index: Int) {
        let row = rows[index]
        cell.rendersNonEmptyText = true
        cell.contentKey = "t:\(row.id.uuidString)"
        layout.setContentKey(cell.contentKey!, at: index)
        if row.isFooter {
            cell.applyContentConfiguration(UIHostingConfiguration { UsageStampFixture() })
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
        coordinator.onFirstLayout = onFirstLayout
        coordinator.applyStructural(items: items, estimates: estimates, preserveVisibleAnchor: anchored)
        coordinator.onFirstLayout = nil
        footerPresent = showFooter
        return true
    }

    /// Let the hosting graph deliver the real heights and let the deferred
    /// restore (DispatchQueue.main.async) run, exactly as a frame boundary does
    /// in the app.
    func settle(_ seconds: Double = 0.10) {
        collection.layoutIfNeeded()
        pump(seconds)
        collection.layoutIfNeeded()
        pump(0.03)
        collection.layoutIfNeeded()
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
    func cycle(anchored: Bool) -> CGFloat {
        let before = screenTop(of: referenceItem)
        apply(showFooter: false, anchored: anchored)
        settle()
        apply(showFooter: true, anchored: anchored)
        settle()
        return screenTop(of: referenceItem) - before
    }
}
