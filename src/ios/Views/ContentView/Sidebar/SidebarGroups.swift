//
//  SidebarGroups.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The sidebar's data model: SidebarGroup (one date bucket or folder section,
//  ids only so the list diffs cheaply), FolderGlyph, and the memo key / box
//  that lets an unchanged session list reuse the previous grouping.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// One sidebar section: a date bucket (folderId == nil) or a folder section.
/// Equatable and cheap on purpose — the sidebar ForEach diffs this on every
/// transaction flush, so it must stay a [String] + small scalars, never a
/// [ChatSession] ([T-ios-session-list-equatable-jank]).
struct SidebarGroup: Equatable, Identifiable {
    /// [T-ios-sidebar-foreach-index-id] Stable identity for the section ForEach.
    ///
    /// The list was keyed by `\.offset` — the array INDEX. Group order is not
    /// stable: `groupedSessionIDs` emits "Pinned" only when a pinned session
    /// exists, folder groups sort by pin state and newest member, and date
    /// buckets appear and disappear as sessions age. Pinning one chat, or a
    /// background sync bumping a folder's newest `updatedAt`, renumbers every
    /// group after it, so SwiftUI sees the sections it already has under new
    /// identities and rebuilds them as remove+insert rather than an update.
    ///
    /// That is the churn the 2026-08-26 crash lands in: EXC_BAD_ACCESS in
    /// `assignWithTake for ForEachState.LazyEdits` inside a graph transaction,
    /// i.e. a double release while ForEach applied its edit list. The
    /// folderId/label pair is what actually names a group, and it survives
    /// reordering — an update stays an update.
    var id: String { folderId.map { "f:\($0)" } ?? "b:\(label)" }

    var label: String            // English key for date buckets; folder name otherwise

    /// Member session ids, in display order. Emptied when the folder is
    /// collapsed.
    ///
    /// [T-ios-foreach-lazyedits-dup-guard] DEFENSIVE: writes are de-duplicated,
    /// first occurrence wins. This is NOT a diagnosed fix — see the property's
    /// full rationale on `dedupedPreservingOrder` below.
    ///
    /// The invariant lives here, on the property, rather than at the two
    /// construction sites, so a third site added later cannot bypass it and so
    /// the `g.ids = []` collapse write is covered by the same rule.
    var ids: [String] {
        get { _ids }
        set { _ids = Self.dedupedPreservingOrder(newValue) }
    }
    private var _ids: [String] = []

    /// First occurrence wins, order otherwise untouched.
    ///
    /// Why this guard exists: the sidebar renders members with
    /// `ForEach(group.ids, id: \.self)`, i.e. keyed by the session id itself.
    /// A repeated id would hand SwiftUI two rows with the SAME identity inside
    /// one ForEach, which is a documented trigger for the double release this
    /// app has already crashed on twice —
    /// `assignWithTake for ForEachState.LazyEdits` →
    /// `_swift_release_dealloc`, EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE at
    /// 0x24 (2026-08-26 on iOS 26.6.1, again 2026-09-17 on iOS 27.0, both
    /// iPhone18,1).
    ///
    /// Honest status: an audit on 2026-09-17 could NOT find a way to reach a
    /// duplicate. `groupedSessions` partitions with `continue`/`else if`,
    /// `filteredSessions` is a filter, both writes to `sessions` are
    /// @MainActor from `listSessions()`, and ChatStore's incremental
    /// `patchedSessionList` appends at most one row per cached entry. The
    /// crashing stack carries no app frames at all (frames 0-39 are
    /// libswiftCore / SwiftUICore / AttributeGraph / UIKitCore), so the .ips
    /// cannot name the offending view either. This is therefore a cheap
    /// backstop against one specific, known-fatal input shape — not a claim
    /// about the cause.
    ///
    /// If the crash STOPS after this ships, duplicates were reachable and the
    /// real bug is whatever produced them (a merge/restore path appending
    /// without deduping is the likeliest candidate); the `#if DEBUG` report in
    /// `computeGroupedSessionIDs` is what would name it. If the crash
    /// CONTINUES, duplicate identity was not the trigger and this guard should
    /// stay only as belt-and-braces while the search moves elsewhere.
    /// Explicit memberwise-equivalent init. Needed because the private `_ids`
    /// backing store suppresses the synthesised one, and required anyway so
    /// every construction path goes through the de-duplicating setter.
    init(label: String, ids: [String], folderId: String? = nil) {
        self.label = label
        self.folderId = folderId
        self.ids = ids          // via the setter — dedup applies here too
    }

    static func dedupedPreservingOrder(_ input: [String]) -> [String] {
        // Fast path: the overwhelmingly common case is already unique, and
        // this runs inside a hot AttributeGraph aggregation pass.
        var seen = Set<String>(minimumCapacity: input.count)
        var hasDuplicate = false
        for id in input where !seen.insert(id).inserted {
            hasDuplicate = true
            break
        }
        guard hasDuplicate else { return input }

        seen.removeAll(keepingCapacity: true)
        var out: [String] = []
        out.reserveCapacity(input.count)
        for id in input where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
    var folderId: String? = nil
    // Retain IDs only, never eager row views, for the native virtualized accordion.
    var accordionMemberIDs: [String] = []
    var totalCount: Int = 0      // member count incl. hidden-by-collapse rows
    var glyphs: [FolderGlyph] = []   // top-3 distinct member category glyphs
    var anyUnread = false
    var anyActive = false
    var anyPaused = false
    var isCollapsed = false
    var isFolderPinned = false
    var latestDate: Date? = nil      // newest member updatedAt (nil = empty folder)
    var summaryTitle: String? = nil  // newest member's title, for the subtitle line
    /// [T-folder-summary-lock] The member `summaryTitle` came from, so the
    /// line can be blurred while that session is Face ID locked.
    var summarySessionId: String? = nil
    /// True on the FIRST folder group only: renders the "Groups" divider
    /// label (styled like the date-bucket headers) above the folder block.
    var showsGroupsHeader = false
    /// [T-search-folder-pages] Matches of a search-expanded folder not yet
    /// shown; > 0 renders the "Show more" row below `ids`.
    var hiddenMatchCount = 0
    /// [T-sidebar-recent-section] Members the Recent bucket shows DIM: already
    /// read, but still inside its one-hour activity window. Empty for every
    /// other bucket, so no other section pays for the lookup.
    var dimmedIds: Set<String> = []

    /// [T-sidebar-recent-section] Row opacity for a dimmed Recent member.
    /// A separate member so the two row builders (and their tests) agree.
    func isDimmed(_ id: String) -> Bool { !dimmedIds.isEmpty && dimmedIds.contains(id) }

    /// The member row that closes the folder card (bottom segment). With a
    /// "Show more" row below, that row closes it instead.
    func isLastMemberRow(_ id: String) -> Bool { hiddenMatchCount == 0 && id == ids.last }
}

/// A single composed-icon glyph. Small struct instead of a tuple because
/// tuples can't satisfy Equatable inside SidebarGroup's array.
struct FolderGlyph: Equatable {
    var systemName: String
    var color: Color
}

/// Projection of EXACTLY the per-session fields the sidebar grouping reads —
/// the memo key's session component. Deliberately excludes `lastMessage`
/// (the expensive field at the heart of [T-ios-session-list-equatable-jank]);
/// comparing N of these is a handful of short-string compares per element,
/// far cheaper than re-running the grouping.
struct SidebarSessionKey: Equatable {
    let id: String
    let updatedAt: Date
    let pinnedAt: Date?
    let isPinned: Bool
    let folderId: String?
    let category: String?
    let title: String?
}

/// Every input `groupedSessionIDs` depends on. Compared (not hashed) so a
/// hit is provably identical input — no collision risk. The badge/activity
/// sets are IN the key on purpose: they're both the aggregation inputs and
/// the invalidation signal (a badge aging past the 24h window changes the
/// freshly-built set, which misses the memo — same "next ambient refresh"
/// timing the unmemoized per-member query had). `dayStamp` invalidates the
/// date buckets when the calendar day flips.
struct SidebarGroupsMemoKey: Equatable {
    let sessions: [SidebarSessionKey]
    let folders: [ChatFolder]
    let collapsedFolderIds: Set<String>
    let pendingDraftId: String?
    let pendingDraftFolderId: String?
    let isSearching: Bool
    let searchResultsActive: Bool
    let searchMatchedFolderIds: Set<String>
    let searchFolderPages: [String: Int]
    let unreadIds: Set<String>
    let freshCornerIds: Set<String>
    let activeIds: Set<String>
    let dayStamp: Date
    /// [T-sidebar-recent-section] The planned Recent membership. IN the key on
    /// purpose: the bucket's rows are a copy of sessions that also live in
    /// another bucket, so a change here changes what the list shows even when
    /// no session/folder value did (a read chat crossing the 1-hour window, a
    /// switch being flipped, the 3/5/10 cap moving).
    let recentPlan: RecentPlan
    /// Settings switch + the search gate. Folded into the key so flipping the
    /// toggle rebuilds the list on the next pass instead of waiting for an
    /// unrelated session edit.
    let recentEnabled: Bool
}

/// Reference-type memo box held in @State: mutating its contents during a
/// body evaluation is legal (no observed value changes, so no re-entrant
/// invalidation), and identity survives ContentView struct re-inits. A memo
/// hit returns the SAME [SidebarGroup] array instance, so the downstream
/// ForEach diff takes the identical-storage fast path instead of comparing
/// element-wise.
final class SidebarGroupsMemo {
    var key: SidebarGroupsMemoKey?
    var groups: [SidebarGroup] = []
}

// MARK: - [T-sidebar-recent-section] Recent bucket membership
//
// The official sidebar opens with a "最近" bucket above "置顶": unread,
// running and recently active conversations in one place at the top, while
// each of them STAYS in its own bucket below — PINNED ones included
// ([T-sidebar-recent-pinned-copy]). This is the whole rule, kept as a pure
// function over the fields the sidebar already publishes (unread badge,
// running set, `updatedAt`) — no new model field, no second source of truth,
// and drivable from a test without the app.
//
// BEGIN sidebar-recent-planner
/// One conversation as the Recent bucket sees it. Deliberately a value type
/// with no `ChatSession`: the planning rule must stay testable on its own.
struct RecentCandidate: Equatable {
    let id: String
    let updatedAt: Date
    /// Carried for the record and for the tests; it no longer excludes the
    /// candidate — a pinned chat rides along in 最近 and keeps its 置顶 row
    /// ([T-sidebar-recent-pinned-copy], see `RecentSectionPlanner.rank`).
    let isPinned: Bool
    let isUnread: Bool
    let isRunning: Bool
}

/// What the Recent bucket shows this pass: the capped, ordered member ids and
/// the subset that is DIM (read, still inside the activity window).
struct RecentPlan: Equatable {
    var ids: [String] = []
    var dimmedIds: Set<String> = []
    var isEmpty: Bool { ids.isEmpty }
}

/// "最近" bucket membership + the visibility gate. Pure, side-effect free.
enum RecentSectionPlanner {
    /// "最近 1 小时内活跃过": the read-but-recent window, and the point at which
    /// an already-read conversation LEAVES the bucket (official: 已读的对话会变暗
    /// 留在那里，直到最后一次活跃的 1 小时后).
    static let activityWindow: TimeInterval = 3600
    /// "只有置顶对话和分组合计超过 4 个时才会显示这个分区" — 4 is still hidden,
    /// 5 shows it.
    static let minimumPinnedAndGroups = 5
    /// 3 / 5 / 10, default 5 (settings › Grouping › 最近分区条数).
    static let limitChoices = [3, 5, 10]
    static let defaultLimit = 5
    /// Opacity of a read-but-recent row: still readable, visibly quieter than
    /// an unread/running one.
    static let dimOpacity: Double = 0.55

    /// Why a candidate is in the bucket. The raw order IS the display order:
    /// running first, then unread, then read-but-recent.
    enum Rank: Int {
        case running = 0
        case unread = 1
        case recent = 2
    }

    /// nil = not in the bucket.
    ///
    /// [T-sidebar-recent-pinned-copy] A PINNED conversation is NOT excluded:
    /// the official sidebar lists it here *and* keeps it in "置顶" (photo
    /// ref: the third row of 最近 carries the 置顶 pill). The two sections are
    /// keyed independently, so one chat legitimately appears in both — that is
    /// the "同时保留在原来的位置" rule, not a duplicate-identity bug. Unread and
    /// running conversations never age out; a read one ages out after `window`.
    static func rank(_ candidate: RecentCandidate, now: Date,
                     window: TimeInterval = activityWindow) -> Rank? {
        if candidate.isRunning { return .running }
        if candidate.isUnread { return .unread }
        return now.timeIntervalSince(candidate.updatedAt) < window ? .recent : nil
    }

    /// How many of `ids` are unread right now — the number on the 最近 header's
    /// red badge ([T-sidebar-recent-unread-badge]).
    ///
    /// Deliberately a projection over the SIDEBAR's own membership plus the
    /// store's unread set: there is no second counter to keep in sync, so
    /// opening one chat (which calls `SessionBadgeStore.remove(.unread,…)`)
    /// or "全部已读" moves this number on the very next evaluation. Counting
    /// members rather than "everything unread in the library" is what makes
    /// the badge read as "unread in 最近": with the 3/5/10 cap, the two numbers
    /// differ, and only this one can reach zero by reading the rows shown.
    ///
    /// Duplicate ids are counted once (the bucket's own ids are unique; the
    /// guard is here so a future caller cannot inflate the number).
    static func unreadCount(ids: [String], unread: Set<String>) -> Int {
        guard !unread.isEmpty else { return 0 }
        var seen = Set<String>(minimumCapacity: ids.count)
        var count = 0
        for id in ids where seen.insert(id).inserted {
            if unread.contains(id) { count += 1 }
        }
        return count
    }

    /// "置顶对话和分组合计超过 4 个" — pinned CONVERSATIONS plus GROUPS.
    static func isVisible(pinnedCount: Int, groupCount: Int) -> Bool {
        pinnedCount + groupCount >= minimumPinnedAndGroups
    }

    /// Ordered: running (newest first), unread (newest first), read-recent
    /// (newest first), capped to `limit`. Ties break on id so the order is
    /// deterministic (a wobbly order would churn the ForEach identities).
    static func plan(candidates: [RecentCandidate], limit: Int, now: Date,
                     window: TimeInterval = activityWindow) -> RecentPlan {
        let cap = limit > 0 ? limit : defaultLimit
        var ranked: [(rank: Rank, candidate: RecentCandidate)] = []
        ranked.reserveCapacity(min(candidates.count, cap * 2))
        for candidate in candidates {
            if let rank = rank(candidate, now: now, window: window) {
                ranked.append((rank, candidate))
            }
        }
        // Only the top `cap` matter; sorting the whole candidate set keeps the
        // comparator simple and the sets here are the unread/running/recent
        // few, never the whole library.
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank.rawValue < b.rank.rawValue }
            if a.candidate.updatedAt != b.candidate.updatedAt {
                return a.candidate.updatedAt > b.candidate.updatedAt
            }
            return a.candidate.id < b.candidate.id
        }
        var plan = RecentPlan()
        plan.ids.reserveCapacity(min(ranked.count, cap))
        for entry in ranked.prefix(cap) {
            plan.ids.append(entry.candidate.id)
            if entry.rank == .recent { plan.dimmedIds.insert(entry.candidate.id) }
        }
        return plan
    }
}

/// UserDefaults switches of the Recent bucket. Read straight from
/// `UserDefaults` (not @AppStorage) for the same reason `autoGroupingEnabled`
/// is: the value is consumed outside SwiftUI's view tree, in the grouping
/// pass, and a plain defaults read is the single source of truth there.
///
/// Keys are duplicated as literals in AppearanceSettingsView (which compiles
/// standalone in the settings harness) — `scripts/sidebar_recent_regression.py`
/// asserts the two spellings agree.
enum RecentSectionSettings {
    static let enabledKey = "sidebarRecentSectionEnabled"
    static let limitKey = "sidebarRecentSectionCount"

    /// ON by default: it only ever duplicates rows the user already has, and
    /// the visibility gate keeps it away from short lists.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// A stored value outside 3/5/10 (older build, manual defaults edit) falls
    /// back to 5 instead of an unbounded list.
    static var limit: Int {
        let stored = UserDefaults.standard.integer(forKey: limitKey)
        return RecentSectionPlanner.limitChoices.contains(stored)
            ? stored : RecentSectionPlanner.defaultLimit
    }
}
// END sidebar-recent-planner
