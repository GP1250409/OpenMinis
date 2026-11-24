import SwiftUI
import UIKit

struct FolderAppearanceFixture: View {
    let box: FloatingBarGeometryBox
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 68)
                .modifier(FolderCardBackground(isDropTarget: false, isExpanded: false))
                .padding(.horizontal, 6)
            Color.clear.frame(height: 24)
            Color.clear.frame(height: 68)
                .modifier(FolderCardBackground(isDropTarget: false, isExpanded: true))
                .padding(.horizontal, 6)
            Color.clear.frame(height: 68)
                .background(FolderMemberRowBackground(isLast: false))
            Color.clear.frame(height: 68)
                .background(FolderMemberRowBackground(isLast: true))
        }
        .frame(width: 320)
        .background(FloatingBarGeometryMarker(box: box))
    }
}

final class SwiftUIListFolderModel: ObservableObject {
    @Published var collapsedIds: Set<String> = ["f0", "f1", "f2"]
    weak var f0HeaderView: UIView?
    weak var f1HeaderView: UIView?

    func toggle(_ fid: String) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if collapsedIds.contains(fid) {
                collapsedIds = ["f0", "f1", "f2"]
                collapsedIds.remove(fid)
            } else {
                collapsedIds.insert(fid)
            }
        }
    }
}

struct HeaderUIViewProbe: UIViewRepresentable {
    let assign: (UIView) -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        assign(uiView)
    }
}

struct SwiftUIListFolderFixture: View {
    @ObservedObject var model: SwiftUIListFolderModel
    let actions = SessionMenuActionChannel()

    private func makeGroup(id: String, name: String, count: Int) -> SidebarGroup {
        let isCollapsed = model.collapsedIds.contains(id)
        let allIds = (0..<count).map { "\(id)-m\($0)" }
        return SidebarGroup(
            id: "folder-\(id)",
            ids: isCollapsed ? [] : allIds,
            label: name,
            isCollapsed: isCollapsed,
            folderId: id,
            totalCount: count,
            summaryTitle: "邮件往来"
        )
    }

    private func makeSession(_ sid: String, title: String) -> ChatSession {
        var s = ChatSession()
        s.id = sid
        s.title = title
        return s
    }

    var body: some View {
        let groups = [
            makeGroup(id: "f0", name: "商务邮件", count: 6),
            makeGroup(id: "f1", name: "朗文词典改造", count: 4),
            makeGroup(id: "f2", name: "网站开发", count: 3),
        ]
        List {
            Section {
                ForEach(["pin-0", "pin-1"], id: \.self) { sid in
                    SessionStackRow(
                        session: makeSession(sid, title: sid == "pin-0" ? "Herd 连接 RN" : "查看 Codex 用量"),
                        isActive: false, isSuspended: false, highlightQuery: nil, matchSnippet: nil,
                        isRegeneratingTitle: false, inFolder: false, isLastInFolder: false, menuActions: actions
                    )
                }
            } header: {
                Text("Pinned").font(.subheadline.weight(.semibold)).foregroundStyle(Color(UIColor.secondaryLabel))
            }
            .listSectionSeparator(.hidden)
            .listSectionSeparatorTint(.clear)

            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    AnyView(
                        ProductionFolderHeaderFixture(group: group)
                            .background(
                                HeaderUIViewProbe { v in
                                    if group.folderId == "f0" { model.f0HeaderView = v }
                                    if group.folderId == "f1" { model.f1HeaderView = v }
                                }
                            )
                            .id("folderHeader-\(group.folderId ?? "")")
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowSeparatorTint(.clear)
                    .listRowBackground(Color(UIColor.systemBackground))

                    ForEach(Array(group.ids.enumerated()), id: \.element) { idx, sid in
                        SessionStackRow(
                            session: makeSession(sid, title: idx == 0 ? "邮件往来" : "Ivan电源适配器 \(idx)"),
                            isActive: false, isSuspended: false, highlightQuery: nil, matchSnippet: nil,
                            isRegeneratingTitle: false, inFolder: true,
                            isLastInFolder: idx == group.ids.count - 1,
                            menuActions: actions
                        )
                    }
                } header: {
                    if index == 0 {
                        Text("Groups")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                            .textCase(nil)
                    }
                }
                .listSectionSeparator(.hidden)
                .listSectionSeparatorTint(.clear)
            }
        }
        .listStyle(.plain)
    }
}

extension AccordionTestApp {
    func rgb(_ image: UIImage, _ point: CGPoint) -> [Int] {
        guard let cg = image.cgImage,
              let crop = cg.cropping(to: CGRect(x: Int(point.x * image.scale), y: Int(point.y * image.scale), width: 1, height: 1)) else { return [0, 0, 0] }
        var bytes: [UInt8] = [0, 0, 0, 0]
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }

    func folderAppearanceTest() {
        let box = FloatingBarGeometryBox()
        let host = UIHostingController(rootView: FolderAppearanceFixture(box: box))
        window!.rootViewController = host
        for style in [UIUserInterfaceStyle.light, .dark] {
            host.overrideUserInterfaceStyle = style
            host.view.backgroundColor = .systemBackground
            host.view.layoutIfNeeded(); pump(0.3)
            guard let marker = box.marker else { check(false, "folder fixture mounted"); return }
            let rect = marker.convert(marker.bounds, to: host.view)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let title = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 126))
            let member = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 194))
            print("FOLDER_COLORS style=\(style.rawValue) title=\(title) member=\(member)")
            check(zip(title, member).allSatisfy { abs($0 - $1) <= 2 }, "expanded header shares member background without extra tint")
            // Upstream seamless weld: no horizontal separator rule inside an expanded folder card.
            let boundary = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 160 - 0.25))
            check(zip(boundary, title).allSatisfy { abs($0 - $1) <= 2 }, "expanded header welds seamlessly to first member without internal rule")
            let scale = image.scale
            func edgeStrength(_ y: CGFloat) -> Int {
                let base = rgb(image, CGPoint(x: rect.midX, y: rect.minY + y))
                return (-2...8).reduce(0) { sum, step in
                    let color = rgb(image, CGPoint(x: rect.minX + 6 + CGFloat(step) / scale, y: rect.minY + y))
                    return sum + zip(color, base).reduce(0) { $0 + abs($1.0 - $1.1) }
                }
            }
            let collapsed = edgeStrength(34), expanded = edgeStrength(194)
            print("FOLDER_EDGE style=\(style.rawValue) collapsed=\(collapsed) expanded=\(expanded)")
            check(collapsed > 0 && expanded > 0, "both collapsed and expanded outer edges remain visible")
            let filename = style == .light ? "folder-light.png" : "folder-dark.png"
            try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
        }
        swiftUIListExpandCollapseTest(legacyOpaque: true)
        swiftUIListExpandCollapseTest(legacyOpaque: false)
    }

    /// Real SwiftUI `List(.plain)` 0.25s expand + collapse pixel regression
    /// covering both the exact iOS 16 opaque `secondarySystemBackground` path
    /// (`legacyOpaque == true`) and the modern glass path (`legacyOpaque == false`).
    func swiftUIListExpandCollapseTest(legacyOpaque: Bool) {
        FolderSurfaceTesting.forceLegacyOpaqueCard = legacyOpaque
        defer { FolderSurfaceTesting.forceLegacyOpaqueCard = false }

        for style in [UIUserInterfaceStyle.light, .dark] {
            let model = SwiftUIListFolderModel()
            let host = UIHostingController(rootView: SwiftUIListFolderFixture(model: model))
            host.overrideUserInterfaceStyle = style
            host.view.backgroundColor = .systemBackground
            window!.rootViewController = host
            host.view.frame = window!.bounds
            host.view.layoutIfNeeded()
            pump(0.35)

            guard let f0View = model.f0HeaderView else {
                check(false, "SwiftUI List folder header f0 mounted (legacy=\(legacyOpaque), style=\(style.rawValue))")
                return
            }

            func snapLive() -> UIImage {
                UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
                }
            }

            let tag = "\(legacyOpaque ? "ios16" : "modern")-\(style == .light ? "light" : "dark")"
            let w = host.view.bounds.width

            // 1. Settled collapsed check: all 4 outer corner spandrels + inter-folder gap clean.
            let initialImg = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let r0 = f0View.convert(f0View.bounds, to: host.view)
            let bg = rgb(initialImg, CGPoint(x: 2, y: r0.midY))
            let collapsedCorners = [
                CGPoint(x: 7.5, y: r0.minY + 4 + 1.5),
                CGPoint(x: w - 7.5, y: r0.minY + 4 + 1.5),
                CGPoint(x: 7.5, y: r0.maxY - 4 - 1.5),
                CGPoint(x: w - 7.5, y: r0.maxY - 4 - 1.5),
            ]
            for (ci, pt) in collapsedCorners.enumerated() {
                let c = rgb(initialImg, pt)
                check(zip(c, bg).allSatisfy { abs($0 - $1) <= 2 },
                      "settled collapsed corner \(ci) clean (\(tag)) got=\(c) bg=\(bg)")
            }

            // 2. Animated EXPAND (0.25s): sample frames across 0.02s..0.34s.
            model.toggle("f0")
            var stepIndex = 0
            for dt in [0.02, 0.04, 0.06, 0.06, 0.06, 0.04, 0.08] {
                pump(dt)
                stepIndex += 1
                let img = snapLive()
                let curR = (f0View.layer.presentation()?.convert(f0View.bounds, to: host.view.layer))
                    ?? f0View.convert(f0View.bounds, to: host.view)
                let curBg = rgb(img, CGPoint(x: 2, y: curR.midY))
                let tl = rgb(img, CGPoint(x: 7.5, y: curR.minY + 4 + 1.5))
                let tr = rgb(img, CGPoint(x: w - 7.5, y: curR.minY + 4 + 1.5))
                print("LIST_EXPAND \(tag) step=\(stepIndex) tl=\(tl) tr=\(tr) bg=\(curBg)")
                check(zip(tl, curBg).allSatisfy { abs($0 - $1) <= 2 },
                      "expand frame \(stepIndex) top-left corner clean (\(tag)) got=\(tl) bg=\(curBg)")
                check(zip(tr, curBg).allSatisfy { abs($0 - $1) <= 2 },
                      "expand frame \(stepIndex) top-right corner clean (\(tag)) got=\(tr) bg=\(curBg)")
                // Right-gutter separator probe across the header/member boundary (catches full-bleed List separators).
                for yOff in stride(from: curR.maxY - 2, through: curR.maxY + 2, by: 0.5) {
                    let g = rgb(img, CGPoint(x: w - 2, y: yOff))
                    check(zip(g, curBg).allSatisfy { abs($0 - $1) <= 2 },
                          "expand frame \(stepIndex) has no full-bleed separator at y=\(yOff) (\(tag)) got=\(g) bg=\(curBg)")
                }
                if stepIndex == 2 {
                    try? img.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-list-expand-mid-\(tag).png"))
                }
            }

            // Settled expanded check: seamless weld between header and first member row (no separator line).
            let expandedImg = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let expR = f0View.convert(f0View.bounds, to: host.view)
            let cardFill = rgb(expandedImg, CGPoint(x: w / 2, y: expR.midY))
            for yOff in stride(from: expR.maxY - 1.5, through: expR.maxY + 1.5, by: 0.5) {
                let seam = rgb(expandedImg, CGPoint(x: w / 2, y: yOff))
                check(zip(seam, cardFill).allSatisfy { abs($0 - $1) <= 3 },
                      "expanded header-to-member seam has no separator line at y=\(yOff) (\(tag)) seam=\(seam) fill=\(cardFill)")
            }

            // 3. Animated COLLAPSE (0.25s): sample frames across 0.02s..0.34s.
            model.toggle("f0")
            stepIndex = 0
            for dt in [0.02, 0.04, 0.06, 0.06, 0.06, 0.04, 0.08] {
                pump(dt)
                stepIndex += 1
                let img = snapLive()
                let curR = (f0View.layer.presentation()?.convert(f0View.bounds, to: host.view.layer))
                    ?? f0View.convert(f0View.bounds, to: host.view)
                let curBg = rgb(img, CGPoint(x: 2, y: curR.midY))
                let tl = rgb(img, CGPoint(x: 7.5, y: curR.minY + 4 + 1.5))
                let tr = rgb(img, CGPoint(x: w - 7.5, y: curR.minY + 4 + 1.5))
                print("LIST_COLLAPSE \(tag) step=\(stepIndex) tl=\(tl) tr=\(tr) bg=\(curBg)")
                check(zip(tl, curBg).allSatisfy { abs($0 - $1) <= 2 },
                      "collapse frame \(stepIndex) top-left corner clean (\(tag)) got=\(tl) bg=\(curBg)")
                check(zip(tr, curBg).allSatisfy { abs($0 - $1) <= 2 },
                      "collapse frame \(stepIndex) top-right corner clean (\(tag)) got=\(tr) bg=\(curBg)")
                // Probe right gutter across all visible folder section boundaries so single-frame
                // end-of-collapse section separator flashes (frame_0108) are caught at every step.
                for yScan in stride(from: curR.maxY - 3, through: min(host.view.bounds.height - 20, curR.maxY + 220), by: 1.0) {
                    let g = rgb(img, CGPoint(x: w - 2, y: yScan))
                    check(zip(g, curBg).allSatisfy { abs($0 - $1) <= 2 },
                          "collapse frame \(stepIndex) has no right-gutter separator flash at y=\(yScan) (\(tag)) got=\(g) bg=\(curBg)")
                }
                if stepIndex == 2 {
                    try? img.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-list-collapse-mid-\(tag).png"))
                }
                if stepIndex == 6 {
                    try? img.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-list-collapse-settle-\(tag).png"))
                }
            }

            // Final post-collapse check on all 4 corners + inter-folder 8pt gap between f0 and f1.
            let postCollapseImg = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let finR0 = f0View.convert(f0View.bounds, to: host.view)
            let finBg = rgb(postCollapseImg, CGPoint(x: 2, y: finR0.midY))
            let finCorners = [
                CGPoint(x: 7.5, y: finR0.minY + 4 + 1.5),
                CGPoint(x: w - 7.5, y: finR0.minY + 4 + 1.5),
                CGPoint(x: 7.5, y: finR0.maxY - 4 - 1.5),
                CGPoint(x: w - 7.5, y: finR0.maxY - 4 - 1.5),
            ]
            for (ci, pt) in finCorners.enumerated() {
                let c = rgb(postCollapseImg, pt)
                print("LIST_POST_COLLAPSE \(tag) corner=\(ci) rgb=\(c) bg=\(finBg)")
                check(zip(c, finBg).allSatisfy { abs($0 - $1) <= 2 },
                      "post-collapse corner \(ci) clean (\(tag)) got=\(c) bg=\(finBg)")
            }
            if let f1View = model.f1HeaderView {
                let finR1 = f1View.convert(f1View.bounds, to: host.view)
                for yGap in stride(from: finR0.maxY - 3.0, through: finR1.minY + 3.0, by: 0.5) {
                    let midGap = rgb(postCollapseImg, CGPoint(x: w / 2, y: yGap))
                    check(zip(midGap, finBg).allSatisfy { abs($0 - $1) <= 2 },
                          "inter-folder gap has no separator line at y=\(yGap) (\(tag)) got=\(midGap) bg=\(finBg)")
                }
            }
        }
    }
}
