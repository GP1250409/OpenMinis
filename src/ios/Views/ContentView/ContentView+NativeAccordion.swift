import SwiftUI
import UIKit

extension ContentView {
    var nativeAccordionSidebar: AnyView {
        let groups = groupedSessionIDs(filteredSessions)
        // Normal (non-search) rows have exactly two single-line texts and a
        // 44pt icon. Calculate their invariant height without instantiating
        // thousands of SessionRow views. Search snippets retain the old List.
        let title = UIFont.systemFont(ofSize: accordionFontSettings.scaledApp(16), weight: .semibold).lineHeight
        let subtitle = UIFont.systemFont(ofSize: accordionFontSettings.scaledApp(14)).lineHeight
        let rowHeight = ceil(max(44, title + 4 + subtitle) + 24)
        let items: [AccordionRenderSection] = groups.enumerated().map { index, group in
            let folder = group.folderId != nil
            let members = folder ? group.accordionMemberIDs : group.ids
            let hasLabel = folder ? group.showsGroupsHeader : (index > 0 || group.label == "Pinned")
            return AccordionRenderSection(group: group, members: members,
                geometry: AccordionSectionGeometry(id: group.id, folderID: group.folderId,
                    count: members.count, rowHeight: rowHeight,
                    labelHeight: hasLabel ? 32 : 0, headerHeight: folder ? 68 : 0,
                    footerHeight: folder ? 4 : 0))
        }
        return AnyView(
            FloatingSidebarSurface {
                NativeAccordionList(sections: items, viewport: accordionViewport, bottomInset: nativeFabInset,
                    toggle: { id in toggleFolderCollapsed(id) },
                    render: { group, index, role in
                        nativeAccordionCell(group, index: index, role: role)
                    })
                .opacity(didInitialLoad ? 1 : 0)
                .overlay { if didInitialLoad, filteredSessions.isEmpty { emptyState } }
            } controls: {
                if !hidesFABForOnboarding(listIsEmpty: filteredSessions.isEmpty) {
                    fabRow
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { nativeFabInset = geo.size.height }
                                    .onChange(of: geo.size.height) { nativeFabInset = $0 }
                            }
                        }
                }
            }
            .ignoresSafeArea(.keyboard, edges: showSearchBar ? [] : .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sidebarToolbarContent }
        )
    }

    private func nativeAccordionCell(_ group: SidebarGroup, index: Int, role: AccordionCellRole) -> AnyView {
        switch role {
        case .label:
            return AnyView(
                HStack {
                    if group.folderId != nil {
                        Text("Groups").font(.subheadline.weight(.semibold)).foregroundStyle(Color(UIColor.secondaryLabel))
                    } else {
                        sectionHeader(index: index, group: group)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(UIColor.systemBackground))
            )
        case .folder:
            return AnyView(folderSectionHeader(group, nativeAccordion: true))
        case .member(let row):
            let id = group.ids[row]
            return AnyView(
                stackRow(id, group: group)
                    .background {
                        // listRowBackground is ignored outside SwiftUI.List.
                        if group.folderId != nil {
                            FolderMemberRowBackground(isLast: row == group.ids.count - 1)
                        } else { Color(UIColor.systemBackground) }
                    }
            )
        }
    }
}
