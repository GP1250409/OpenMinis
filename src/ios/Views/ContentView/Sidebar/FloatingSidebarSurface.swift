import SwiftUI

/// The scrolling surface and floating controls are siblings. A safeAreaInset
/// reduces the proposed viewport of a UIViewControllerRepresentable; content
/// insets cannot make pixels draw outside that clipped viewport.
/// Only the scrolling sibling extends below the home-indicator safe area.
/// The controls keep their normal safe-area position and have no backing panel.
struct FloatingSidebarSurface<Content: View, Controls: View>: View {
    let content: Content
    let controls: Controls

    init(@ViewBuilder content: () -> Content, @ViewBuilder controls: () -> Controls) {
        self.content = content()
        self.controls = controls()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content.ignoresSafeArea(.container, edges: .bottom)
            controls
        }
    }
}
