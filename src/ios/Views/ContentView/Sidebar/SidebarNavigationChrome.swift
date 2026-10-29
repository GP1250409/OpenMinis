import SwiftUI

/// Navigation chrome belongs to the identity-stable session-list wrapper, not
/// to either its native, search or selection renderer. Keep visibility explicit
/// at this root only; pushed chats and presented tools retain their own policy.
struct SidebarNavigationChrome<Items: ToolbarContent>: ViewModifier {
    let items: Items

    init(@ToolbarContentBuilder items: () -> Items) { self.items = items() }

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { items }
    }
}
