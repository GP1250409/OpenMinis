//
//  LegacyGlass.swift
//  [MOD legacy-glass] Glass surface for systems BELOW iOS 26.
//
//  iOS 26+ already uses the system Liquid Glass (`glassEffect`) everywhere in
//  the app. Earlier systems had flat fills. This file adds a look-alike for
//  them, following the layering Telegram-iOS uses for its own pre-26 glass
//  (`LegacyGlassView` / `GlassBackgroundView`), re-written here from the idea
//  only — no code is copied and none of Telegram's modules are needed:
//
//    1. a backdrop layer that samples whatever is drawn behind the view,
//    2. a gaussian blur + a saturation boost on that backdrop,
//    3. a translucent tint so text on top stays readable,
//    4. a rim light: two half-arcs, bright at the top-left and bottom-right,
//       fading to nothing in between (the way a lens edge catches light),
//    5. a soft, wide drop shadow with the shape cut out of it, so the shadow
//       never shows through the translucent body.
//
//  Refraction (Telegram's mesh transform at the edge) is deliberately NOT
//  done: it relies on more private API and has a battery cost.
//
//  The backdrop layer is private API (`CABackdropLayer` / `CAFilter`). The
//  app is distributed through TrollStore, so there is no App Store review;
//  if the classes are ever missing the view degrades to a system material.
//
//  What it must NOT be used for:
//   - rows inside the scrolling lists (folder cards: documented scroll-perf
//     incidents), and
//   - surfaces that are rendered offscreen with `layer.render` (the share
//     export): a backdrop layer draws nothing there.
//

import SwiftUI
import UIKit

// MARK: - Private-API helpers

private enum LegacyGlassRuntime {
    /// Names are assembled at runtime rather than written as literals.
    static let backdropLayerClass: CALayer.Type? = {
        let name = "CA" + "BackdropLayer"
        return NSClassFromString(name) as? CALayer.Type
    }()

    static func makeFilter(_ name: String) -> NSObject? {
        let className = "CA" + "Filter"
        guard let cls = NSClassFromString(className) else { return nil }
        let target = cls as AnyObject
        let sel = NSSelectorFromString("filterWith" + "Name:")
        guard target.responds(to: sel) else { return nil }
        return target.perform(sel, with: name)?.takeUnretainedValue() as? NSObject
    }

    static func blurFilter(radius: CGFloat) -> NSObject? {
        guard let f = makeFilter("gaussianBlur") else { return nil }
        f.setValue(NSNumber(value: Double(radius)), forKey: "inputRadius")
        f.setValue(NSNumber(value: true), forKey: "inputNormalizeEdges")
        return f
    }

    /// Plain saturation matrix (Rec.709 luma weights).
    static func saturationFilter(_ s: CGFloat) -> NSObject? {
        guard let f = makeFilter("colorMatrix") else { return nil }
        let lr: Float = 0.2126, lg: Float = 0.7152, lb: Float = 0.0722
        let sf = Float(s)
        let inv = 1 - sf
        var m: [Float] = [
            lr * inv + sf, lg * inv,      lb * inv,      0, 0,
            lr * inv,      lg * inv + sf, lb * inv,      0, 0,
            lr * inv,      lg * inv,      lb * inv + sf, 0, 0,
            0,             0,             0,             1, 0
        ]
        f.setValue(NSValue(bytes: &m, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
        return f
    }
}

private final class LegacyGlassNullActionDelegate: NSObject, CALayerDelegate {
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

// MARK: - UIKit backdrop view

final class LegacyGlassBackdropView: UIView {
    /// `nil` = fully round (capsule / circle): radius follows the short side.
    var cornerRadius: CGFloat? { didSet { setNeedsLayout() } }
    var continuousCorners = false { didSet { layer.cornerCurve = continuousCorners ? .continuous : .circular } }

    private var backdrop: CALayer?
    private var fallback: UIVisualEffectView?
    private let delegateObject = LegacyGlassNullActionDelegate()
    private var appliedBlur: CGFloat = -1
    private var appliedSaturation: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
        if let cls = LegacyGlassRuntime.backdropLayerClass {
            let b = cls.init()
            b.delegate = delegateObject
            // KVC on a missing key throws, so check the setter exists first.
            if b.responds(to: NSSelectorFromString("setScale:")) {
                b.setValue(NSNumber(value: 1.0), forKey: "scale")
            }
            b.rasterizationScale = 1.0
            layer.addSublayer(b)
            backdrop = b
        } else {
            let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            v.isUserInteractionEnabled = false
            addSubview(v)
            fallback = v
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(blur: CGFloat, saturation: CGFloat) {
        guard let backdrop, blur != appliedBlur || saturation != appliedSaturation else { return }
        appliedBlur = blur
        appliedSaturation = saturation
        var filters: [Any] = []
        if let s = LegacyGlassRuntime.saturationFilter(saturation) { filters.append(s) }
        if let b = LegacyGlassRuntime.blurFilter(radius: blur) { filters.append(b) }
        backdrop.filters = filters
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = cornerRadius ?? (min(bounds.width, bounds.height) / 2)
        layer.cornerRadius = min(r, min(bounds.width, bounds.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        CATransaction.commit()
        fallback?.frame = bounds
    }
}

private struct LegacyGlassBackdrop: UIViewRepresentable {
    let cornerRadius: CGFloat?
    let continuous: Bool
    let blur: CGFloat
    let saturation: CGFloat

    func makeUIView(context: Context) -> LegacyGlassBackdropView {
        let v = LegacyGlassBackdropView()
        v.cornerRadius = cornerRadius
        v.continuousCorners = continuous
        v.apply(blur: blur, saturation: saturation)
        return v
    }

    func updateUIView(_ v: LegacyGlassBackdropView, context: Context) {
        v.cornerRadius = cornerRadius
        v.continuousCorners = continuous
        v.apply(blur: blur, saturation: saturation)
    }
}

// MARK: - SwiftUI surface

enum LegacyGlassShape {
    case rounded(CGFloat, continuous: Bool)
    case capsule
    case circle

    fileprivate var cornerRadius: CGFloat? {
        if case let .rounded(r, _) = self { return r }
        return nil
    }
    fileprivate var continuous: Bool {
        if case let .rounded(_, c) = self { return c }
        return false
    }
}

/// Strength presets: how much the tint covers the blurred backdrop.
enum LegacyGlassStrength {
    /// Floating controls over the message list.
    case light
    /// Surfaces carrying text the user types or reads (composer, popups).
    case regular
}

/// One concrete InsettableShape for all three outlines, so `fill`,
/// `strokeBorder` and `shadow` can share a single value.
private struct LegacyGlassOutline: InsettableShape {
    let shape: LegacyGlassShape
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> LegacyGlassOutline {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let short = min(r.width, r.height) / 2
        switch shape {
        case let .rounded(radius, continuous):
            return Path(roundedRect: r, cornerRadius: min(max(0, radius - inset), short),
                        style: continuous ? .continuous : .circular)
        case .capsule, .circle:
            return Path(roundedRect: r, cornerRadius: short, style: .continuous)
        }
    }
}

/// Test hook: the bounding box of the outline's path (used by the regression harness).
func legacyGlassOutlineBounds(for size: CGSize, shape: LegacyGlassShape) -> CGRect {
    LegacyGlassOutline(shape: shape).path(in: CGRect(origin: .zero, size: size)).boundingRect
}

private struct LegacyGlassBody: ViewModifier {
    let shape: LegacyGlassShape
    let strength: LegacyGlassStrength
    let tint: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var dark: Bool { scheme == .dark }

    private var tintAlpha: Double {
        switch strength {
        case .light: return dark ? 0.34 : 0.42
        case .regular: return dark ? 0.52 : 0.62
        }
    }

    private var fillColor: Color {
        if reduceTransparency { return dark ? Color(white: 0.11) : Color(white: 0.97) }
        let base = dark ? Color(white: 0.10) : Color(white: 1.0)
        return base.opacity(tintAlpha)
    }

    private var rim: LinearGradient {
        let hi = dark ? 0.34 : 0.95
        return LinearGradient(
            stops: [
                .init(color: Color.white.opacity(hi), location: 0.0),
                .init(color: Color.white.opacity(hi * 0.55), location: 0.22),
                .init(color: Color.white.opacity(0.0), location: 0.45),
                .init(color: Color.white.opacity(0.0), location: 0.58),
                .init(color: Color.white.opacity(hi * 0.7), location: 0.85),
                .init(color: Color.white.opacity(hi), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var outline: LegacyGlassOutline { LegacyGlassOutline(shape: shape) }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if !reduceTransparency {
                        LegacyGlassBackdrop(
                            cornerRadius: shape.cornerRadius,
                            continuous: shape.continuous,
                            blur: 14,
                            saturation: 1.7
                        )
                    }
                    outline.fill(fillColor)
                    if let tint {
                        outline.fill(tint)
                    }
                }
            }
            .overlay {
                ZStack {
                    // The faint dark hairline keeps the edge readable in
                    // light mode, where a white rim alone would vanish.
                    outline.strokeBorder(Color.black.opacity(dark ? 0.0 : 0.07), lineWidth: 0.5)
                    outline.strokeBorder(rim, lineWidth: dark ? 0.6 : 0.9)
                }
                .allowsHitTesting(false)
            }
            .background {
                // Soft shadow with the body cut out of it, so it never shows
                // through the translucent glass.
                outline
                    .fill(Color.black)
                    .shadow(color: Color.black.opacity(dark ? 0.38 : 0.13), radius: 14, x: 0, y: 4)
                    .mask {
                        // The ZStack takes the shape's size; only the
                        // rectangle is enlarged, so the cut-out is exact.
                        ZStack {
                            Rectangle().padding(-80)
                            outline.fill(Color.black).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Pre-iOS-26 glass surface. The content sits ON the glass (it is the
    /// modified view), like `.glassEffect` on iOS 26.
    func legacyGlass(
        _ shape: LegacyGlassShape,
        strength: LegacyGlassStrength = .regular,
        tint: Color? = nil
    ) -> some View {
        modifier(LegacyGlassBody(shape: shape, strength: strength, tint: tint))
    }
}
