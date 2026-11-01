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
    var body: some View {
        UsageStampRow(stamp: stamp, contentVisible: true) {
            ProductionUsageCapsule(usage: usage).background(RowDiagnosticProbe(name: "usage"))
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
        .background(Color(UIColor.systemBackground))
    }
}

/// The pre-change row ("10-24 11:08", fixedSize), as the width reference.
struct LegacyUsageRowFixture: View {
    let usage: TokenUsage
    var body: some View {
        HStack(spacing: 6) {
            ProductionUsageCapsule(usage: usage).background(RowDiagnosticProbe(name: "usage"))
            Spacer()
            Text("10-24 11:08")
                .lineLimit(1).fixedSize()
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
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
        for style in [UIUserInterfaceStyle.light, .dark] {
            owner.overrideUserInterfaceStyle = style
            let s = style == .light ? "light" : "dark"
            for width: CGFloat in [375, 390, 430] {
                let legacy = measure(AnyView(LegacyUsageRowFixture(usage: long)), width: width, name: nil)
                let stacked = measure(AnyView(UsageRowFixture(usage: long, stamp: oldStamp)), width: width,
                                      name: width == 390 ? "long-old-\(s)" : nil)
                let todayRow = measure(AnyView(UsageRowFixture(usage: long, stamp: todayStamp)), width: width,
                                       name: width == 390 ? "long-today-\(s)" : nil)
                let shortOld = measure(AnyView(UsageRowFixture(usage: short, stamp: oldStamp)), width: width,
                                       name: width == 390 ? "short-old-\(s)" : nil)
                let shortToday = measure(AnyView(UsageRowFixture(usage: short, stamp: todayStamp)), width: width, name: nil)
                print("STAMP_GEOMETRY \(s) w=\(width) legacyUsage=\(legacy.usage.width) newUsage=\(stacked.usage.width) "
                      + "h legacy=\(legacy.height) stacked=\(stacked.height) today=\(todayRow.height) "
                      + "shortOld=\(shortOld.height) shortToday=\(shortToday.height)")
                check(stacked.usage.width >= legacy.usage.width - 0.5,
                      "weekday never narrows the usage capsule below the old layout (\(s) \(width))")
                check(todayRow.usage.width >= legacy.usage.width - 0.5, "today row keeps usage width (\(s) \(width))")
                check(abs(shortOld.height - shortToday.height) < 0.5,
                      "short usage keeps 10/23 Fri 11:08 on one line (\(s) \(width))")
                check(shortOld.usage.width > 0, "short usage capsule rendered (\(s) \(width))")
            }
            // Switch logic with a fixed 150pt single-line usage stand-in, so the
            // usage capsule's own wrapping cannot mask the stamp's layout.
            func block(_ stamp: CompletionStampParts) -> AnyView {
                AnyView(UsageStampRow(stamp: stamp, contentVisible: true) {
                    Color.gray.frame(width: 150, height: 12).background(RowDiagnosticProbe(name: "usage"))
                }.padding(.horizontal, 16).padding(.vertical, 2))
            }
            let wideOld = measure(block(oldStamp), width: 360, name: "fits-old-\(s)")
            let wideToday = measure(block(todayStamp), width: 360, name: nil)
            let narrowOld = measure(block(oldStamp), width: 280, name: "narrow-old-\(s)")
            let narrowToday = measure(block(todayStamp), width: 280, name: nil)
            print("STAMP_SWITCH \(s) wideOld=\(wideOld.height) wideToday=\(wideToday.height) narrowOld=\(narrowOld.height) narrowToday=\(narrowToday.height)")
            check(abs(wideOld.height - wideToday.height) < 0.5, "10/23 Fri 11:08 stays on one line when it fits (\(s))")
            check(narrowOld.height > narrowToday.height + 8, "stamp stacks date/weekday over time when it cannot fit (\(s))")
            check(abs(narrowOld.usage.width - 150) < 0.5, "stacked stamp leaves usage width intact (\(s))")
        }
        owner.overrideUserInterfaceStyle = .unspecified
    }
}
