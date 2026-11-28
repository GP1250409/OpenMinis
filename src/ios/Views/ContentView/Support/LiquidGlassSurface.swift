//
//  LiquidGlassSurface.swift
//  Minis-mod — iOS 16–25 Liquid Glass backport (Telegram-inspired)
//
//  Provides a reusable, GPU-friendly Liquid Glass surface family for iOS < 26
//  devices where SwiftUI's native `.glassEffect(...)` is unavailable:
//    1. Real-time system blur (`Material` / `UIVisualEffectView`) painted
//       directly INTO the shape (preserving the [T-popup-white-patch] invariant
//       with no rectangular backing layer).
//    2. Directional top-to-bottom inner specular luminance wash (light/dark
//       adaptive) so glass reads bright and watery even over flat white or
//       pure black backgrounds.
//    3. Diagonal Fresnel rim highlight (`strokeBorder` / `CAGradientLayer` ring)
//       plus a hairline light-mode outer edge for crisp separation.
//    4. Soft floating elevation shadow outside the clipped material.
//    5. Respects `accessibilityReduceTransparency` and a user-facing toggle
//       (`liquidGlassLegacyEnabled`, default ON).
//
//  On iOS 26+ all legacy helpers are strictly no-ops so native Liquid Glass
//  behavior is completely untouched.
//

import SwiftUI
import UIKit

// MARK: - Settings

enum LiquidGlassLegacySettings {
    /// Persisted toggle key. Literal string is mirrored in `AppearanceSettingsView`
    /// so that file can continue compiling standalone in the settings harness.
    nonisolated static let defaultsKey = "liquidGlassLegacyEnabled"
    static let didChangeNotification = Notification.Name("LiquidGlassLegacySettingsDidChange")

    /// True on iOS < 26 when the user has not explicitly disabled the toggle
    /// (default ON). Always false on iOS 26+ where native `.glassEffect` runs.
    nonisolated static var isEnabledNow: Bool {
        if #available(iOS 26.0, *) { return false }
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return stored
        }
        return true
    }
}

// MARK: - Visual Style Presets

enum LiquidGlassStyle {
    /// Floating circular buttons (FABs, scroll-to-bottom, browser downloads).
    case floatingButton
    /// Top navigation bar circular/capsule buttons (gear, alarm, terminal, back, "...").
    case navBarButton
    /// Chat composer container and expanded search bar capsule.
    case composer
    /// Floating popups (`/` and `@` pickers) and tool status bar.
    case popup
    /// Floating pill / segmented switch (share sheet controls).
    case pill
    /// User message bubble in Default Theme (lightweight rim + subtle depth).
    case bubble

    var material: Material {
        switch self {
        case .floatingButton, .navBarButton, .pill, .bubble:
            return .ultraThinMaterial
        case .composer:
            return .thinMaterial
        case .popup:
            return .regularMaterial
        }
    }

    var rimWidth: CGFloat {
        switch self {
        case .bubble: return 0.75
        case .navBarButton, .pill: return 1.0
        case .floatingButton, .composer, .popup: return 1.0
        }
    }
}

// MARK: - SwiftUI Liquid Glass Surface Modifier

/// Renders a Telegram-inspired Liquid Glass surface directly into `shape` on
/// iOS < 26. Callers wrap their content directly so foreground glyphs sit ABOVE
/// the material and specular layers.
struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let style: LiquidGlassStyle
    var tint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(opaqueFallbackColor)
                    } else {
                        shape.fill(style.material)
                    }
                    if let tint {
                        shape.fill(tint)
                    }
                    shape.fill(innerSpecularWash)
                }
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(specularRimGradient, lineWidth: style.rimWidth)
                    if colorScheme == .light {
                        shape.strokeBorder(Color.black.opacity(lightOuterHairlineOpacity), lineWidth: 0.5)
                    }
                }
                .allowsHitTesting(false)
            }
            .modifier(LiquidGlassShadow(style: style, colorScheme: colorScheme))
    }

    private var opaqueFallbackColor: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemBackground)
            : Color(UIColor.systemBackground)
    }

    /// Directional inner sheen: simulates light refracting across the curved
    /// glass face (bright top catchlight, clearer waist, subtle bottom bounce).
    private var innerSpecularWash: LinearGradient {
        if colorScheme == .dark {
            let top: Double = (style == .bubble) ? 0.10 : 0.15
            let mid: Double = (style == .bubble) ? 0.02 : 0.03
            let bottom: Double = (style == .bubble) ? 0.06 : 0.09
            return LinearGradient(
                stops: [
                    .init(color: .white.opacity(top), location: 0.0),
                    .init(color: .white.opacity(mid), location: 0.48),
                    .init(color: .white.opacity(bottom), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            let top: Double = (style == .bubble) ? 0.42 : 0.58
            let mid: Double = (style == .bubble) ? 0.14 : 0.22
            let bottom: Double = (style == .bubble) ? 0.24 : 0.34
            return LinearGradient(
                stops: [
                    .init(color: .white.opacity(top), location: 0.0),
                    .init(color: .white.opacity(mid), location: 0.48),
                    .init(color: .white.opacity(bottom), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Diagonal Fresnel rim highlight — bright specular arcs on top-leading and
    /// bottom-trailing, softer across the sides.
    private var specularRimGradient: LinearGradient {
        if colorScheme == .dark {
            let peak: Double = (style == .bubble) ? 0.30 : 0.44
            let mid: Double = (style == .bubble) ? 0.06 : 0.09
            let tail: Double = (style == .bubble) ? 0.18 : 0.26
            return LinearGradient(
                stops: [
                    .init(color: .white.opacity(peak), location: 0.0),
                    .init(color: .white.opacity(mid), location: 0.45),
                    .init(color: .white.opacity(mid * 0.7), location: 0.62),
                    .init(color: .white.opacity(tail), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            let peak: Double = (style == .bubble) ? 0.80 : 0.94
            let mid: Double = (style == .bubble) ? 0.12 : 0.18
            let tail: Double = (style == .bubble) ? 0.55 : 0.70
            return LinearGradient(
                stops: [
                    .init(color: .white.opacity(peak), location: 0.0),
                    .init(color: .white.opacity(mid), location: 0.45),
                    .init(color: .white.opacity(tail), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var lightOuterHairlineOpacity: Double {
        switch style {
        case .bubble: return 0.055
        case .navBarButton: return 0.075
        default: return 0.07
        }
    }
}

private struct LiquidGlassShadow: ViewModifier {
    let style: LiquidGlassStyle
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        switch style {
        case .bubble:
            content
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.22 : 0.05),
                    radius: 4, x: 0, y: 1.5
                )
        case .navBarButton:
            content
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.36 : 0.09),
                    radius: 6, x: 0, y: 2
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.18 : 0.04),
                    radius: 1.5, x: 0, y: 0.5
                )
        case .floatingButton, .pill:
            content
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.44 : 0.12),
                    radius: 10, x: 0, y: 4
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.20 : 0.05),
                    radius: 2, x: 0, y: 1
                )
        case .composer:
            content
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.46 : 0.11),
                    radius: 12, x: 0, y: 4
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.26 : 0.04),
                    radius: 3, x: 0, y: 1
                )
        case .popup:
            content
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.48 : 0.13),
                    radius: 18, x: 0, y: 8
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.22 : 0.06),
                    radius: 2.5, x: 0, y: 1
                )
        }
    }
}

// MARK: - Top Navigation Bar Glass Chrome (iOS < 26)

/// Wraps a top navigation bar icon button in a 34×34 Liquid Glass circle on
/// iOS < 26 when `liquidGlassLegacyEnabled` is ON. No-op on iOS 26+ or when OFF.
struct LiquidGlassNavBarIconChrome: ViewModifier {
    var diameter: CGFloat = 34
    @AppStorage(LiquidGlassLegacySettings.defaultsKey) private var glassEnabled: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else if glassEnabled {
            content
                .foregroundStyle(Color(UIColor.label))
                .frame(width: diameter, height: diameter)
                .modifier(LiquidGlassSurface(shape: Circle(), style: .navBarButton))
                .contentShape(Circle())
        } else {
            content
        }
    }
}

/// Wraps a top navigation bar text button (e.g. Cancel, Select All) in a Liquid
/// Glass capsule on iOS < 26 when `liquidGlassLegacyEnabled` is ON.
struct LiquidGlassNavBarPillChrome: ViewModifier {
    @AppStorage(LiquidGlassLegacySettings.defaultsKey) private var glassEnabled: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else if glassEnabled {
            content
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(UIColor.label))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .modifier(LiquidGlassSurface(shape: Capsule(), style: .navBarButton))
                .contentShape(Capsule())
        } else {
            content
        }
    }
}

/// Transparent navigation bar + soft top edge gradient fade for iOS < 26 when
/// Liquid Glass is enabled, so scrolling content flows behind the floating
/// glass toolbar buttons without harsh text overlap against the centered title.
struct LiquidGlassNavBarTopFade: View {
    let backgroundColor: Color

    var body: some View {
        GeometryReader { geo in
            let height = geo.safeAreaInsets.top + 52
            LinearGradient(
                stops: [
                    .init(color: backgroundColor.opacity(0.86), location: 0.0),
                    .init(color: backgroundColor.opacity(0.52), location: 0.58),
                    .init(color: backgroundColor.opacity(0.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .frame(height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - UIKit Liquid Glass Disc (for UIKit-hosted bar buttons like ChatTrailingMenuButton)

/// Lightweight UIKit equivalent of `LiquidGlassSurface(shape: Circle(), style: .navBarButton)`.
/// Modeled on Telegram's `GlassBackgroundView`: `UIVisualEffectView` + inner
/// specular gradient + masked Fresnel rim `CAGradientLayer` + outer drop shadow.
final class LiquidGlassUIKitDiscView: UIView {
    private let blurView: UIVisualEffectView
    private let washLayer = CAGradientLayer()
    private let rimLayer = CAGradientLayer()
    private let rimMaskLayer = CAShapeLayer()
    private let outerHairlineLayer = CAShapeLayer()

    override init(frame: CGRect) {
        let blur = UIBlurEffect(style: .systemUltraThinMaterial)
        blurView = UIVisualEffectView(effect: blur)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false

        blurView.isUserInteractionEnabled = false
        blurView.clipsToBounds = true
        addSubview(blurView)

        washLayer.startPoint = CGPoint(x: 0.5, y: 0)
        washLayer.endPoint = CGPoint(x: 0.5, y: 1)
        washLayer.locations = [0.0, 0.48, 1.0]
        blurView.contentView.layer.addSublayer(washLayer)

        rimLayer.startPoint = CGPoint(x: 0, y: 0)
        rimLayer.endPoint = CGPoint(x: 1, y: 1)
        rimMaskLayer.fillColor = UIColor.clear.cgColor
        rimMaskLayer.strokeColor = UIColor.white.cgColor
        rimMaskLayer.lineWidth = 1.0
        rimLayer.mask = rimMaskLayer
        blurView.contentView.layer.addSublayer(rimLayer)

        outerHairlineLayer.fillColor = UIColor.clear.cgColor
        outerHairlineLayer.lineWidth = 0.5
        blurView.contentView.layer.addSublayer(outerHairlineLayer)

        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2
        blurView.frame = bounds
        blurView.layer.cornerRadius = radius

        washLayer.frame = blurView.bounds
        rimLayer.frame = blurView.bounds

        let insetRect = blurView.bounds.insetBy(dx: 0.5, dy: 0.5)
        let circlePath = UIBezierPath(ovalIn: insetRect).cgPath
        rimMaskLayer.frame = blurView.bounds
        rimMaskLayer.path = circlePath

        outerHairlineLayer.frame = blurView.bounds
        outerHairlineLayer.path = circlePath

        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyAppearance()
        }
    }

    private func applyAppearance() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        blurView.isHidden = false
        blurView.effect = reduceTransparency ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
        blurView.backgroundColor = reduceTransparency
            ? (isDark ? .secondarySystemBackground : .systemBackground)
            : .clear

        if isDark {
            washLayer.colors = [
                UIColor(white: 1, alpha: 0.15).cgColor,
                UIColor(white: 1, alpha: 0.03).cgColor,
                UIColor(white: 1, alpha: 0.09).cgColor
            ]
            rimLayer.locations = [0.0, 0.45, 0.62, 1.0]
            rimLayer.colors = [
                UIColor(white: 1, alpha: 0.44).cgColor,
                UIColor(white: 1, alpha: 0.09).cgColor,
                UIColor(white: 1, alpha: 0.06).cgColor,
                UIColor(white: 1, alpha: 0.26).cgColor
            ]
            outerHairlineLayer.strokeColor = UIColor.clear.cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.36
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 2)
        } else {
            washLayer.colors = [
                UIColor(white: 1, alpha: 0.58).cgColor,
                UIColor(white: 1, alpha: 0.22).cgColor,
                UIColor(white: 1, alpha: 0.34).cgColor
            ]
            rimLayer.locations = [0.0, 0.45, 1.0]
            rimLayer.colors = [
                UIColor(white: 1, alpha: 0.94).cgColor,
                UIColor(white: 1, alpha: 0.18).cgColor,
                UIColor(white: 1, alpha: 0.70).cgColor
            ]
            outerHairlineLayer.strokeColor = UIColor(white: 0, alpha: 0.075).cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.10
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }
    }
}

// MARK: - Interactive Pop Gesture Restorer (for custom glass back button on iOS < 26)

/// Re-enables `UINavigationController.interactivePopGestureRecognizer` when a
/// pushed page hides the system back button to draw a custom Liquid Glass back
/// circle. Explicitly guards `viewControllers.count > 1` so swiping on the root
/// view controller can never freeze the navigation stack.
struct LiquidGlassInteractivePopRestorer: UIViewRepresentable {
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navController: UINavigationController?
        weak var previousDelegate: UIGestureRecognizerDelegate?

        func attach(to view: UIView) {
            var responder: UIResponder? = view.next
            while let r = responder {
                if let vc = r as? UIViewController, let nav = vc.navigationController {
                    guard navController !== nav else { return }
                    navController = nav
                    if let pop = nav.interactivePopGestureRecognizer {
                        previousDelegate = pop.delegate
                        pop.delegate = self
                        pop.isEnabled = true
                    }
                    return
                }
                responder = r.next
            }
        }

        func detach() {
            if let pop = navController?.interactivePopGestureRecognizer, pop.delegate === self {
                pop.delegate = previousDelegate
            }
            navController = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navController else { return false }
            return nav.viewControllers.count > 1
        }
    }

    final class AnchorView: UIView {
        var onAttach: ((UIView) -> Void)?
        var onDetach: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttach?(self)
            } else {
                onDetach?()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.isHidden = true
        v.isUserInteractionEnabled = false
        v.onAttach = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(to: view)
        }
        v.onDetach = { [weak coordinator = context.coordinator] in
            coordinator?.detach()
        }
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        if uiView.window != nil {
            context.coordinator.attach(to: uiView)
        }
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }
}
