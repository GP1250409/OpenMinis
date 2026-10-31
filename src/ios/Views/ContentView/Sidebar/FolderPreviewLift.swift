//
//  FolderPreviewLift.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  MOD: the long-press platter of a folder card — one geometry for the group
//  header and its member rows, the lifted paint that feeds the platter
//  snapshot, and the exact lifetime of that paint.
//
//  Why the row has to paint anything at all: `.contextMenu` builds its platter
//  from a SNAPSHOT of the source view, and `.contentShape(.contextMenuPreview,
//  _)` only crops that snapshot. A welded group row (expanded header, member
//  row) has no 4pt gap on its inner edges, so the snapshot alone can never
//  yield the accepted "lone card + 4pt band, concentric corners" look
//  (photo_EEB36A68): the CARD ITSELF has to be inset on all four sides while
//  the snapshot is taken.
//
//  Why that paint must not outlive the snapshot: keeping the lone card for the
//  whole press is what left a rounded card behind a cancelled menu (the press
//  state outlives the menu on iOS 16). So the paint is armed late (taps never
//  lift), and dropped the moment the system's platter exists — from then on the
//  row is the welded segment again and a dismissal lands on a continuous group.
//

import SwiftUI
import UIKit

/// One source of truth for the held folder card's geometry.
///
/// Resting card: 6pt in from the row sides, 4pt from the row top/bottom, corner
/// radius 16. The platter shows that card with the SAME band on all four sides,
/// so its mask is the card expanded by `gap`: radius 16 + 4 = 20 and the same
/// corner centres (concentric), which is what the device screenshot
/// photo_EEB36A68 was approved for.
enum FolderCardLift {
    /// Card ↔ row sides of a folder card.
    static let sideInset: CGFloat = 6
    /// Card ↔ row top/bottom of a lone folder card.
    static let verticalInset: CGFloat = 4
    /// Resting card corner radius.
    static let cornerRadius: CGFloat = 16
    /// The platter's band around the card.
    static let gap: CGFloat = 4
    /// Platter corner radius: concentric with the card's own 16pt corners.
    static var platterRadius: CGFloat { cornerRadius + gap }

    /// Row rect → platter rect: the card plus one `gap` on every side.
    static func platterRect(in row: CGRect) -> CGRect {
        row.insetBy(dx: sideInset - gap, dy: verticalInset - gap)
    }

    /// How long a touch must stay down before the row paints the lifted card.
    /// Long enough to leave taps (and its press feedback) untouched, short
    /// enough to be on screen when the system takes the platter snapshot at
    /// the 0.5s long-press threshold.
    static let liftDelay: TimeInterval = 0.22

    /// How far a touch may travel before it counts as a scroll/drag rather than
    /// a hold, and the lifted paint is dropped.
    static let dragSlop: CGFloat = 12
}

/// `.contentShape(.contextMenuPreview, …)` mask of a folder row: the card plus
/// its 4pt band, outer radius 20, sharing the card's corner centres.
///
/// No expanded/collapsed variant: the bottom band is produced by the CARD
/// being inset 4pt while held, not by cropping the snapshot (which is what left
/// the flat, cut-off bottom edge on an expanded group header).
struct FolderPlatterShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: FolderCardLift.platterRadius, style: .continuous)
            .path(in: FolderCardLift.platterRect(in: rect))
    }
}

/// Whether one folder row is currently allowed to paint the lifted card.
///
/// `lifted` is true only inside the window between "the finger has been down
/// long enough" and "the system has the snapshot" (platter on screen, or the
/// touch ended). A finished hold closes the cycle until the next touch-down, so
/// a press state that the platform never clears cannot re-paint the card.
final class FolderLiftState: ObservableObject {
    /// Paint the lone card instead of the welded segment.
    @Published private(set) var lifted = false
    /// A touch is held in this row: the platter probe polls while true.
    @Published private(set) var watching = false

    private var touching = false
    private var armed = false
    private var presented = false
    private var cycleClosed = false
    private var generation = 0

    func touchDown() {
        generation &+= 1
        let gen = generation
        touching = true
        armed = false
        presented = false
        cycleClosed = false
        watching = true
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + FolderCardLift.liftDelay) { [weak self] in
            guard let self, self.generation == gen, self.touching, !self.presented, !self.cycleClosed else { return }
            self.armed = true
            self.refresh()
        }
    }

    func touchEnded() {
        generation &+= 1
        guard touching || watching || lifted else { return }
        touching = false
        armed = false
        presented = false
        watching = false
        cycleClosed = true
        refresh()
    }

    /// The system's long-press platter exists: the snapshot has been taken, the
    /// row may go back to its welded paint. Called from the probe's display
    /// link (main thread).
    func platterDidPresent() {
        guard !presented else { return }
        presented = true
        armed = false
        watching = false
        cycleClosed = true
        refresh()
    }

    private func refresh() {
        let next = touching && armed && !presented && !cycleClosed
        if lifted != next { lifted = next }
    }
}

// MARK: - Header card

/// Folder card surface (group header) with its long-press lift wired in.
///
/// The card keeps its resting paint (welded `top` segment when expanded) except
/// during the platter snapshot window, when it is painted as a lone card inset
/// 4pt at the bottom — the only way an expanded header can show a 4pt band
/// under the card, since it is welded to its first member row at rest.
struct FolderLiftableCardSurface<Content: View>: View {
    let isDropTarget: Bool
    let isExpanded: Bool
    private let content: () -> Content
    @StateObject private var lift = FolderLiftState()

    init(isDropTarget: Bool, isExpanded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isDropTarget = isDropTarget
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        FolderCardPaint(isDropTarget: isDropTarget, isExpanded: isExpanded, lifted: lift.lifted, content: content)
            .background { FolderLiftTouchObserver(state: lift) }
            .background { ContextMenuPlatterProbe(state: lift) }
    }
}

/// The card's paint (fill + tiled border + drop-target tint). Split from the
/// lift state so the same paint can be rendered without observers in tests and
/// in the non-interactive lifted card.
struct FolderCardPaint<Content: View>: View {
    let isDropTarget: Bool
    let isExpanded: Bool
    let lifted: Bool
    let content: () -> Content

    private var kind: FolderSurface.Kind { (lifted || !isExpanded) ? .lone : .top }
    private var bottomInset: CGFloat { (lifted && isExpanded) ? FolderCardLift.verticalInset : 0 }

    private var dropShape: AnyShape {
        if lifted || !isExpanded {
            return AnyShape(RoundedRectangle(cornerRadius: FolderCardLift.cornerRadius, style: .continuous))
        }
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: FolderCardLift.cornerRadius, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: FolderCardLift.cornerRadius, style: .continuous))
    }

    var body: some View {
        content()
            .background {
                Color.clear
                    .modifier(FolderSurface(kind: kind))
                    .padding(.bottom, bottomInset)
            }
            .overlay {
                if isDropTarget {
                    ZStack {
                        dropShape.fill(Color.accentColor.opacity(0.15))
                        dropShape.stroke(Color.accentColor, lineWidth: 1.5)
                    }
                    .padding(.bottom, bottomInset)
                }
            }
    }
}

// MARK: - Member row

/// Background of a folder member row: the welded segment of the group at rest,
/// the lone card while the long-press platter is being snapshotted.
///
/// The spec asks for the same 4pt band on all four sides as the group header,
/// and a member row only has side gaps at rest (rows weld vertically), so the
/// lifted state insets the card 4pt from the top and bottom too. That gap is
/// visible only inside the platter (whose mask is the card + 4pt); the row is
/// welded again before the menu can be dismissed.
struct FolderMemberLiftBackground: View {
    let isLast: Bool
    /// The Button's own press state, used as a SECOND arming signal: if the
    /// passive recognizer is ever unavailable, the row still lifts for the
    /// snapshot exactly as before. Neither signal can keep the card painted
    /// after the platter exists, which is what the residue was.
    var pressed: Bool = false
    @StateObject private var lift = FolderLiftState()

    var body: some View {
        FolderMemberRowBackground(isLast: isLast, lifted: lift.lifted)
            .background { FolderLiftTouchObserver(state: lift) }
            .background { ContextMenuPlatterProbe(state: lift) }
            .onAppear { if pressed { lift.touchDown() } }
            .onChange(of: pressed) { isDown in
                if isDown { lift.touchDown() } else { lift.touchEnded() }
            }
            .onDisappear { lift.touchEnded() }
    }
}

// MARK: - Observers

/// Reports touch-down/up of the row this view lives in.
///
/// A passive recognizer: it never recognizes, cancels nothing, and recognizes
/// simultaneously with everything the row already uses (Button, scroll pan,
/// the context menu's own recognizer, drag), so it cannot change how the row
/// behaves — it only tells the paint WHEN the finger is down. Attached to the
/// enclosing cell/hosting view (the row), so a hold on the row's 4pt/6pt
/// padding lifts too.
struct FolderLiftTouchObserver: UIViewRepresentable {
    let state: FolderLiftState

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.state = state
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.state = state
        view.install()
    }

    final class TouchView: UIView, UIGestureRecognizerDelegate {
        weak var state: FolderLiftState?
        private let recognizer = PassiveTouchRecognizer()
        private weak var host: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.onDown = { [weak self] in self?.handleDown() }
            recognizer.onUp = { [weak self] in self?.state?.touchEnded() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // Cells are recycled: never leave this row's recognizer behind on a
            // view that is about to host a different row.
            if newWindow == nil {
                recognizer.view?.removeGestureRecognizer(recognizer)
                host = nil
                state?.touchEnded()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            install()
        }

        func install() {
            guard window != nil, let next = rowHost() else { return }
            guard host !== next else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            next.addGestureRecognizer(recognizer)
            host = next
        }

        /// The row's own view: a list/collection cell, or the row's hosting view
        /// when the row is not inside a cell. Bounded so a whole-list host can
        /// never be mistaken for one row.
        private func rowHost() -> UIView? {
            var candidate = superview
            var hosting: UIView?
            while let view = candidate {
                if view is UICollectionViewCell || view is UITableViewCell { return view }
                if hosting == nil,
                   String(describing: type(of: view)).contains("HostingView"),
                   view.bounds.height > 0, view.bounds.height <= 200 {
                    hosting = view
                }
                candidate = view.superview
            }
            return hosting ?? superview
        }

        private func handleDown() {
            guard let state else { return }
            guard let host, host.window != nil else { return }
            // Only touches inside THIS row may lift it.
            let point = recognizer.location(in: host)
            guard host.bounds.contains(point) else { return }
            state.touchDown()
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    }
}

/// Observes touches without joining arbitration: it stays `.possible` for the
/// whole sequence, so no other recognizer is delayed, failed or cancelled.
final class PassiveTouchRecognizer: UIGestureRecognizer {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private var start: CGPoint = .zero
    private var active = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !active, numberOfTouches <= 1 else { return }
        active = true
        start = touches.first?.location(in: view) ?? .zero
        onDown?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard active, let point = touches.first?.location(in: view) else { return }
        if hypot(point.x - start.x, point.y - start.y) > FolderCardLift.dragSlop { end() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        end()
    }

    override func reset() {
        super.reset()
        active = false
    }

    private func end() {
        guard active else { return }
        active = false
        onUp?()
    }
}

/// Reports when the system's long-press platter is on screen.
///
/// The platter is a separate view hierarchy owned by UIKit (`UIContextMenu`
/// container views), so its existence is the only public-ish signal that the
/// snapshot has already been taken — and therefore that the row may stop
/// painting the lifted card. Polled only while a touch is held, and only until
/// the first hit: after that the cycle is closed until the next touch-down.
struct ContextMenuPlatterProbe: UIViewRepresentable {
    let state: FolderLiftState

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.state = state
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.state = state
        view.sync()
    }

    final class Probe: UIView {
        weak var state: FolderLiftState?
        private var link: CADisplayLink?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit { link?.invalidate() }

        func sync() {
            guard let state, state.watching, window != nil else { stop(); return }
            start()
        }

        private func start() {
            guard link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let window else { stop(); return }
            if Self.platterVisible(in: window.windowScene?.windows ?? [window]) {
                stop()
                state?.platterDidPresent()
            }
        }

        /// A presented context menu owns views whose type names carry
        /// "ContextMenu" (iOS 16+: `_UIContextMenuContainerView` and friends).
        /// Hidden/zero-alpha leftovers and empty shells are ignored so a stale
        /// container from a previous menu cannot hold the paint down.
        static func platterVisible(in windows: [UIWindow]) -> Bool {
            for window in windows where !window.isHidden {
                if scan(window) { return true }
            }
            return false
        }

        private static func scan(_ root: UIView) -> Bool {
            var stack: [UIView] = [root]
            var visited = 0
            while let view = stack.popLast() {
                visited += 1
                if visited > 800 { return false }
                let name = String(describing: type(of: view))
                if name.contains("ContextMenu") || name.contains("Platter") {
                    if !view.isHidden, view.alpha > 0.01,
                       view.bounds.width > 40, view.bounds.height > 20 {
                        return true
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
            return false
        }
    }
}
