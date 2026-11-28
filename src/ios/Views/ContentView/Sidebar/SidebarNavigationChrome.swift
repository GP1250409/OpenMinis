import SwiftUI
import UIKit

/// Navigation chrome belongs to the identity-stable session-list wrapper, not
/// to either its native, search or selection renderer. Keep visibility explicit
/// at this root only; pushed chats and presented tools retain their own policy.
///
/// Kept standalone (literal key + inline top fade) so `minismod_accordion_regression.py`
/// can compile this file without pulling in `ContentView/Support/LiquidGlassSurface.swift`.
struct SidebarNavigationChrome<Items: ToolbarContent>: ViewModifier {
    let items: Items
    @AppStorage("liquidGlassLegacyEnabled") private var liquidGlassEnabled: Bool = true

    init(@ToolbarContentBuilder items: () -> Items) { self.items = items() }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { items }
        } else if liquidGlassEnabled {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { items }
                .overlay(alignment: .top) {
                    GeometryReader { geo in
                        let bg = Color(UIColor.systemBackground)
                        LinearGradient(
                            stops: [
                                .init(color: bg.opacity(0.86), location: 0.0),
                                .init(color: bg.opacity(0.52), location: 0.58),
                                .init(color: bg.opacity(0.0), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: geo.safeAreaInsets.top + 52)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                    }
                    .frame(height: 0)
                    .allowsHitTesting(false)
                }
        } else {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { items }
        }
    }
}
