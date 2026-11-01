import SwiftUI
import UIKit

// Doubles only: the usage capsule body and UsageStampRow are compiled from
// production sources (see minismod_accordion_regression.py).
struct TokenUsage {
    var latestContextTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
}
enum ChatColors {
    static var tertiaryText: Color { Color(UIColor.tertiaryLabel) }
    static var userBubble: Color { Color(UIColor.tertiarySystemFill) }
}

/// Footer usage row as shipped (production UsageStampRow + production capsule),
/// with a diagnostic probe around the usage capsule.
struct UsageRowFixture: View {
    let usage: TokenUsage
    let stamp: CompletionStampParts?
    var expanded = false
    var body: some View {
        UsageStampRow(stamp: stamp, contentVisible: true, expanded: expanded) {
            ProductionUsageCapsule(usage: usage).background(RowDiagnosticProbe(name: "usage"))
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
        .background(Color(UIColor.systemBackground))
    }
}

extension AccordionTestApp {
    func usageStampTest() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 16, minute: 30))!
        let old = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 11, minute: 8))!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 5))!
        let yesterdayLate = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 59))!
        NSTimeZone.default = cal.timeZone
        let oldStamp = CompletionStampParts(old, calendar: cal, now: now)
        print("STAMP_TEXT old=\(oldStamp.singleLine)")
        check(oldStamp.day == "10/23 Fri" && oldStamp.clock == "11:08", "not-today stamp parts are 10/23 Fri + 11:08")
        check(oldStamp.singleLine == "10/23 Fri 11:08", "not-today single line reads 10/23 Fri 11:08")
        let todayStamp = CompletionStampParts(today, calendar: cal, now: now)
        check(todayStamp.day == nil && todayStamp.singleLine == "09:05", "today keeps the bare 24-hour clock")
        check(CompletionStampParts(yesterdayLate, calendar: cal, now: now).singleLine == "10/31 Sat 23:59",
              "yesterday counts as not today")

        let owner = UIViewController()
        window!.rootViewController = owner
        owner.view.backgroundColor = .systemBackground
        let long = TokenUsage(latestContextTokens: 153_000, inputTokens: 2, outputTokens: 545,
                              cacheReadTokens: 151_000, cacheCreationTokens: 1_400)
        let short = TokenUsage(latestContextTokens: 12_000, inputTokens: 2, outputTokens: 545)
        func measure(_ view: AnyView, width: CGFloat, name: String?) -> (height: CGFloat, usage: CGRect) {
            DiagnosticFrames.current = [:]
            let host = UIHostingController(rootView: view)
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            owner.addChild(host); owner.view.addSubview(host.view); host.didMove(toParent: owner)
            let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            host.view.frame = CGRect(x: 0, y: 120, width: width, height: ceil(size.height))
            host.view.layoutIfNeeded(); pump(0.12)
            let usage = DiagnosticFrames.current["usage"] ?? .zero
            if let name {
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stamp-\(name).png"))
            }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            return (size.height, usage)
        }
        // Intrinsic stamp capsule width (same font + padding as production).
        func stampWidth(_ text: String) -> CGFloat {
            UIHostingController(rootView: Text(text).font(.system(size: 10, design: .monospaced))
                .fixedSize().padding(.horizontal, 8).padding(.vertical, 3))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        }
        let fullUsage = measure(AnyView(ProductionUsageCapsule(usage: long).fixedSize()
            .background(RowDiagnosticProbe(name: "usage"))), width: 1000, name: nil).usage.width
        for style in [UIUserInterfaceStyle.light, .dark] {
            owner.overrideUserInterfaceStyle = style
            let s = style == .light ? "light" : "dark"
            for width: CGFloat in [320, 375, 390, 430] {
                let oneLine = measure(AnyView(UsageRowFixture(usage: short, stamp: todayStamp)), width: width, name: nil).height
                for (tag, stamp) in [("old", oldStamp), ("today", todayStamp)] {
                    let row = measure(AnyView(UsageRowFixture(usage: long, stamp: stamp)), width: width,
                                      name: width == 390 ? "long-\(tag)-\(s)" : nil)
                    let room = width - 32 - 6 - stampWidth(stamp.singleLine)
                    print("STAMP_ROW \(s) w=\(width) \(tag) h=\(row.height) oneLine=\(oneLine) usage=\(row.usage.width) full=\(fullUsage) room=\(room)")
                    check(abs(row.height - oneLine) < 0.5, "row stays on one line (\(s) \(width) \(tag))")
                    check(row.usage.maxX <= 16 + room + 0.5, "full stamp keeps its intrinsic width (\(s) \(width) \(tag))")
                    if fullUsage > room + 1 {
                        check(row.usage.width < fullUsage - 1, "usage capsule truncates instead of wrapping (\(s) \(width) \(tag))")
                        check(row.usage.width >= room - 13, "truncated usage fills the room left by the stamp to within two glyphs (\(s) \(width) \(tag))")
                    }
                }
                let shortOld = measure(AnyView(UsageRowFixture(usage: short, stamp: oldStamp)), width: width,
                                       name: width == 390 ? "short-old-\(s)" : nil)
                check(abs(shortOld.height - oneLine) < 0.5, "short usage + 10/23 Fri 11:08 on one line (\(s) \(width))")
                // Tapped state: full usage alone on the line, stamp hidden, still one line.
                let open = measure(AnyView(UsageRowFixture(usage: long, stamp: oldStamp, expanded: true)), width: width,
                                   name: width == 390 ? "expanded-old-\(s)" : nil)
                print("STAMP_EXPANDED \(s) w=\(width) h=\(open.height) usage=\(open.usage.width) full=\(fullUsage)")
                check(abs(open.height - oneLine) < 0.5, "expanded usage stays on one line (\(s) \(width))")
                check(open.usage.maxX <= width - 16 + 0.5, "expanded usage stays inside the row (\(s) \(width))")
                if fullUsage <= width - 32 {
                    check(abs(open.usage.width - fullUsage) < 0.5, "expanded usage shows in full (\(s) \(width))")
                }
            }
        }
        owner.overrideUserInterfaceStyle = .unspecified
    }
}
