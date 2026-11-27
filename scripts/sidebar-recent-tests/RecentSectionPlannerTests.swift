import Foundation

#if canImport(Glibc)
import Glibc
#endif

// [T-sidebar-recent-section] Membership rule of the "最近" bucket, driven
// against the SHIPPING `RecentSectionPlanner` block (extracted verbatim from
// SidebarGroups.swift by scripts/sidebar_recent_regression.py). No app model,
// no UIKit: the rule is pure, so it runs on Linux and on the macOS runner.

var failures = 0
var passed = 0
func check(_ condition: Bool, _ name: String) {
    if condition { passed += 1; print("PASS: \(name)") }
    else { failures += 1; print("FAIL: \(name)") }
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
func candidate(_ id: String, minutesAgo: Double, pinned: Bool = false,
               unread: Bool = false, running: Bool = false) -> RecentCandidate {
    RecentCandidate(id: id, updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                    isPinned: pinned, isUnread: unread, isRunning: running)
}

// 1. Unread and running never age out.
var plan = RecentSectionPlanner.plan(candidates: [
    candidate("unread-5d", minutesAgo: 5 * 24 * 60, unread: true),
    candidate("running-5d", minutesAgo: 5 * 24 * 60, running: true),
], limit: 5, now: now)
check(plan.ids == ["running-5d", "unread-5d"], "unread/running stay past the window, running first")
check(plan.dimmedIds.isEmpty, "unread/running are never dimmed")

// 2. The read window: inside 1h = kept + dimmed, outside = gone.
plan = RecentSectionPlanner.plan(candidates: [
    candidate("read-59m", minutesAgo: 59),
    candidate("read-61m", minutesAgo: 61),
    candidate("read-60m", minutesAgo: 60),
], limit: 5, now: now)
check(plan.ids == ["read-59m"], "read chat stays inside the hour, leaves at exactly 60 minutes")
check(plan.dimmedIds == ["read-59m"], "the kept read chat is the dimmed one")

// 3. Pinned conversations are never duplicated into Recent.
plan = RecentSectionPlanner.plan(candidates: [
    candidate("pinned-unread", minutesAgo: 1, pinned: true, unread: true),
    candidate("plain-unread", minutesAgo: 120, unread: true),
], limit: 5, now: now)
check(plan.ids == ["plain-unread"], "pinned chat is left to the pinned bucket")
check(RecentSectionPlanner.rank(candidate("p", minutesAgo: 0, pinned: true), now: now) == nil,
      "rank() reports nil for a pinned chat")

// 4. Ordering: running, then unread, then read — each newest first, ties by id.
plan = RecentSectionPlanner.plan(candidates: [
    candidate("read-new", minutesAgo: 1),
    candidate("unread-old", minutesAgo: 600, unread: true),
    candidate("running-old", minutesAgo: 900, running: true),
    candidate("read-old", minutesAgo: 50),
    candidate("unread-new", minutesAgo: 5, unread: true),
], limit: 5, now: now)
check(plan.ids == ["running-old", "unread-new", "unread-old", "read-new", "read-old"],
      "running → unread → read, newest first inside each rank")
check(plan.dimmedIds == ["read-new", "read-old"], "only the read rank is dimmed")

// 5. The 3/5/10 cap, and the fallback for a stored value outside it.
var many: [RecentCandidate] = []
for i in 0..<8 { many.append(candidate("u\(i)", minutesAgo: Double(i), unread: true)) }
check(RecentSectionPlanner.plan(candidates: many, limit: 3, now: now).ids
      == ["u0", "u1", "u2"], "limit 3 keeps the three newest")
check(RecentSectionPlanner.plan(candidates: many, limit: 5, now: now).ids.count == 5, "limit 5 keeps five")
check(RecentSectionPlanner.plan(candidates: many, limit: 10, now: now).ids.count == 8, "limit 10 keeps all eight")
check(RecentSectionPlanner.plan(candidates: many, limit: 0, now: now).ids.count == 5,
      "a non-positive limit falls back to the 5 default")
check(RecentSectionPlanner.limitChoices == [3, 5, 10], "the picker offers exactly 3 / 5 / 10")
check(RecentSectionPlanner.defaultLimit == 5, "the default count is 5")
check(RecentSectionPlanner.activityWindow == 3600, "the read window is one hour")
check(RecentSectionPlanner.dimOpacity > 0 && RecentSectionPlanner.dimOpacity < 1,
      "dim opacity is a partial fade")

// 6. The visibility gate: pinned conversations + groups must EXCEED four.
check(!RecentSectionPlanner.isVisible(pinnedCount: 2, groupCount: 2), "4 together stays hidden")
check(!RecentSectionPlanner.isVisible(pinnedCount: 4, groupCount: 0), "4 pinned alone stays hidden")
check(!RecentSectionPlanner.isVisible(pinnedCount: 0, groupCount: 4), "4 groups alone stays hidden")
check(RecentSectionPlanner.isVisible(pinnedCount: 5, groupCount: 0), "5 pinned shows it")
check(RecentSectionPlanner.isVisible(pinnedCount: 0, groupCount: 5), "5 groups shows it")
check(RecentSectionPlanner.isVisible(pinnedCount: 3, groupCount: 2), "3 pinned + 2 groups shows it")

// 7. Settings defaults (fresh install): ON, five chats.
let defaults = UserDefaults.standard
let enabledKey = RecentSectionSettings.enabledKey
let limitKey = RecentSectionSettings.limitKey
defaults.removeObject(forKey: enabledKey)
defaults.removeObject(forKey: limitKey)
check(RecentSectionSettings.isEnabled, "the section is ON by default")
check(RecentSectionSettings.limit == 5, "the default count reads as 5")
defaults.set(false, forKey: enabledKey)
check(!RecentSectionSettings.isEnabled, "the switch is honoured when off")
defaults.set(10, forKey: limitKey)
check(RecentSectionSettings.limit == 10, "a stored 10 is honoured")
defaults.set(7, forKey: limitKey)
check(RecentSectionSettings.limit == 5, "a stored value outside 3/5/10 falls back to 5")
defaults.removeObject(forKey: enabledKey)
defaults.removeObject(forKey: limitKey)

// 8. Empty input never produces an empty header.
check(RecentSectionPlanner.plan(candidates: [], limit: 5, now: now).isEmpty,
      "nothing to show means no bucket")

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")
print("SIDEBAR_RECENT_PASS checks=\(passed)")
exit(failures == 0 ? 0 : 1)
