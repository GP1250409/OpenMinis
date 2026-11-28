import SwiftUI

/// Navigation chrome belongs to the identity-stable session-list wrapper, not
/// to either its native, search or selection renderer. Keep visibility explicit
/// at this root only; pushed chats and presented tools retain their own policy.
struct SidebarNavigationChrome<Items: ToolbarContent>: ViewModifier {
    let items: Items
    @AppStorage(LiquidGlassLegacySettings.defaultsKey) private var liquidGlassEnabled: Bool = true

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
                    LiquidGlassNavBarTopFade(backgroundColor: Color(UIColor.systemBackground))
                }
        } else {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { items }
        }
    }
}
