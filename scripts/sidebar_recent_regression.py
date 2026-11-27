#!/usr/bin/env python3
"""[T-sidebar-recent-section] The "最近" bucket: membership rule + source contracts.

Two halves, both runnable on Linux and on the macOS runner:

1. LOGIC — the SHIPPING `RecentSectionPlanner` / `RecentSectionSettings` block is
   sliced verbatim out of SidebarGroups.swift, compiled together with a real
   Swift test main and executed. Membership (unread / running / 1-hour window /
   dimming / 3-5-10 cap / pinned exclusion) and the "pinned + groups > 4" gate
   are therefore tested against production code, not a copy.

2. SOURCE CONTRACTS — the wiring that a number cannot prove: the clock glyph is
   out of the title's layout flow (so 最近 and 置顶 share one text x), the fold
   state is observed by the accordion, every renderer (accordion / compact list /
   split list) folds and dims, the grouping inserts the bucket above Pinned and
   only outside search, and the settings rows keep the same defaults as the code
   that reads them.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SIDEBAR = ROOT / 'src/ios/Views/ContentView/Sidebar'
CONTENT = ROOT / 'src/ios/Views/ContentView'
OUT = ROOT / 'build/sidebar-recent'
BEGIN = '// BEGIN sidebar-recent-planner'
END = '// END sidebar-recent-planner'


def read(path):
    return path.read_text(encoding='utf-8')


def slice_between(text, start, stop, name):
    assert start in text, f'{name}: missing start marker {start!r}'
    body = text[text.index(start):]
    assert stop in body, f'{name}: missing end marker {stop!r}'
    return body[:body.index(stop)]


def source_checks():
    checks = 0
    groups = read(SIDEBAR / 'SidebarGroups.swift')
    surfaces = read(SIDEBAR / 'SidebarSurfaces.swift')
    accordion = read(SIDEBAR / 'NativeAccordionList.swift')
    native = read(CONTENT / 'ContentView+NativeAccordion.swift')
    grouping = read(CONTENT / 'ContentView+SidebarGrouping.swift')
    headers = read(CONTENT / 'ContentView+SectionHeaders.swift')
    session_list = read(CONTENT / 'ContentView+SessionList.swift')
    settings = read(ROOT / 'src/ios/Views/Settings/AppearanceSettingsView.swift')
    layout = read(SIDEBAR / 'AccordionCollectionLayout.swift')
    catalog = json.loads(read(ROOT / 'src/ios/Localizable.xcstrings'))['strings']

    # --- the rule itself -----------------------------------------------------
    for literal in (
        'static let activityWindow: TimeInterval = 3600',
        'static let minimumPinnedAndGroups = 5',
        'static let limitChoices = [3, 5, 10]',
        'static let defaultLimit = 5',
        'if candidate.isRunning { return .running }',
        'if candidate.isUnread { return .unread }',
        'return now.timeIntervalSince(candidate.updatedAt) < window ? .recent : nil',
        # [T-sidebar-recent-unread-badge] the header's number is a projection
        'static func unreadCount(ids: [String], unread: Set<String>) -> Int',
    ):
        assert literal in groups, f'membership rule drifted: {literal!r}'
        checks += 1
    # [T-sidebar-recent-pinned-copy] the pin no longer excludes anything.
    assert 'if candidate.isPinned { return nil }' not in groups, 'a pinned chat must ride along in 最近'
    assert 'guard recentEnabled else { continue }' in grouping, 'the candidate walk must not filter pins out'
    assert '!session.isPinned else { continue }' not in grouping, 'the pin filter is gone from the candidate walk'
    assert 'isPinned: session.isPinned,' in grouping, 'the candidate carries the real pin flag'
    assert 'isPinned: false,' not in grouping, 'the candidate must not hard-code "unpinned"'
    checks += 1
    assert 'var dimmedIds: Set<String> = []' in groups and 'func isDimmed(_ id: String)' in groups
    checks += 1

    # --- memo wiring ---------------------------------------------------------
    for literal in ('let recentPlan: RecentPlan', 'let recentEnabled: Bool',
                    'recentPlan: recentPlan,\n            recentEnabled: recentEnabled)',
                    'recentPlan: recentPlan, recentEnabled: recentEnabled)'):
        assert literal in groups + grouping, f'memo wiring drifted: {literal!r}'
        checks += 1

    # --- grouping: above Pinned, gated, never in a result set ----------------
    for literal in (
        'let recentEnabled = RecentSectionSettings.isEnabled && !isSearching',
        'if recentEnabled, !recentPlan.isEmpty {',
        'RecentSectionPlanner.isVisible(pinnedCount: pinnedCount,',
        'groupCount: folderGroups.count)',
        'var recent = SidebarGroup(label: "Recent", ids: recentPlan.ids)',
        'recent.dimmedIds = recentPlan.dimmedIds',
        'recent.accordionMemberIDs = recentPlan.ids',
        'assembled.insert(recent, at: 0)',
    ):
        assert literal in grouping, f'recent bucket assembly drifted: {literal!r}'
        checks += 1
    # The duplicate rows must not touch the buckets they are copied from.
    tail = grouping[grouping.index('var assembled: [SidebarGroup]'):]
    assert 'assemble =' not in tail
    assert 'ids = []' not in tail, 'the recent bucket must not empty any other bucket'
    checks += 1

    # --- spacing contract: one 32pt label slot, no date-bucket footer ---------
    for literal in ('labelHeight: hasLabel ? 32 : 0',
                    'headerHeight: folder ? 68 : 0',
                    'footerHeight: folder ? 4 : 0',
                    '(index > 0 || group.label == "Pinned" || group.label == "Recent")'):
        assert literal in native, f'accordion geometry drifted: {literal!r}'
        checks += 1
    # The shipped row height is NOT shrunk by this feature.
    assert 'max(44, title + 4 + subtitle) + 24' in native, 'session row height must stay as shipped'
    checks += 1
    # No inter-section spacing anywhere in the layout: a section contributes
    # exactly label + header + rows * reveal + footer.
    assert 'y += s.labelHeight + s.headerHeight + s.fullHeight * p + s.footerHeight' in layout
    assert 'interSectionSpacing' not in layout
    checks += 1

    # --- fold state + accordion ---------------------------------------------
    assert 'nonisolated static let defaultsKey = "recentSectionCollapsed"' in surfaces
    assert 'Notification.Name("RecentSectionStateDidChange")' in surfaces
    assert 'if group.folderId == nil, group.label == "Recent" {\n            return !RecentSectionState.isCollapsedNow' in accordion
    assert 'forName: RecentSectionState.didChange' in accordion
    assert 'dateBucketFoldChanged("Recent"' in accordion
    # The pinned path is untouched: same store, same label, same motion.
    assert 'forName: PinnedSectionState.didChange' in accordion
    assert 'if group.folderId == nil, group.label == "Pinned" {\n            return !PinnedSectionState.isCollapsedNow' in accordion
    checks += 1

    # --- [T-sidebar-title-glyph-removal] no glyph before either title -------
    #
    # The clock (最近) and the pin (置顶) that used to hang in the leading
    # gutter are GONE from every real header AND from the sticky UIKit copy,
    # and the titles did not move: the glyphs were always out-of-flow overlays
    # at a negative offset, never HStack members.
    pin_row = slice_between(surfaces, 'struct PinnedSectionHeaderRow: View {',
                            '/// Rows of the pinned bucket for the plain-List paths', 'PinnedSectionHeaderRow')
    recent_row = slice_between(surfaces, 'struct RecentSectionHeaderRow: View {',
                               '/// [T-sidebar-recent-section] Rows of the Recent bucket', 'RecentSectionHeaderRow')
    badge = slice_between(surfaces, 'struct RecentUnreadBadge: View {',
                          '/// [T-sidebar-recent-section] The "最近" bucket', 'RecentUnreadBadge')
    stable = surfaces[surfaces.index('final class StablePinnedTitle'):
                      surfaces.index('/// [T-pinned-section-collapse] Fold state')]
    for glyph in ('Image(systemName: "clock.arrow.circlepath")',
                  'Image(systemName: "pin.fill")',
                  'enum PinnedTitlePin', 'PinnedTitlePin.'):
        assert glyph not in surfaces, f'the bucket title glyph must be gone: {glyph!r}'
        checks += 1
    # No overlay at all on either row: a decorative glyph was the only thing
    # that ever used one there.
    for row, name in ((pin_row, 'pinned'), (recent_row, 'recent')):
        assert '.overlay(alignment: .leading)' not in row, f'{name}: no leading overlay may come back'
        images = re.findall(r'Image\(systemName: "([^"]+)"\)', row)
        assert images == ['chevron.down'], f'{name}: the fold chevron is the only glyph left, got {images}'
        checks += 1
    # …and the sticky copy paints no glyph either, while still drawing the
    # SAME title at the SAME x (`labelX` is the only thing it may never move).
    assert 'pin.frame' not in stable, 'the sticky copy must not draw a glyph in the gutter'
    assert 'label.frame = CGRect(x: labelX' in stable, 'the sticky title still starts at labelX'
    assert 'chevron.frame = CGRect(x: labelX + titleWidth + 4' in stable, 'the sticky chevron stays right after the title'
    checks += 1
    # Same title text, same font, same colour -> same x for both buckets. The
    # badge sits AFTER the title, so it cannot move the text edge.
    def title_text(row):
        start = row.index('Text(LocalizedStringKey(label))')
        anchor = row.index('.foregroundStyle(Color(UIColor.secondaryLabel))', start)
        block = row[start:row.index('\n', anchor)]
        # Indentation differs by one nesting level in the Recent row; the
        # modifiers themselves must be identical.
        return [line.strip() for line in block.splitlines()]
    assert title_text(pin_row) == title_text(recent_row), 'both bucket titles must be laid out identically'
    # The badge is the ONLY thing between title and chevron, and it comes after
    # the title.
    assert recent_row.index('Text(LocalizedStringKey(label))') < recent_row.index('RecentUnreadBadge(count: unreadCount)')
    assert recent_row.index('RecentUnreadBadge(count: unreadCount)') < recent_row.index('if folds')
    checks += 1

    # --- [T-sidebar-recent-unread-badge] counter + 全部已读 -----------------
    # The number is a COUNT derived from the store every pass (never a stored
    # counter), it is hidden at zero, and it keeps working while folded.
    assert 'unreadCount > 0' in recent_row and 'if unreadCount > 0 {' in recent_row
    assert 'Text(verbatim:' in badge and 'Capsule().fill(Color.red)' in badge, 'a red numeric badge'
    assert 'unreadCount: recentUnreadCount(group),' in headers, 'the header is fed the live count'
    assert 'RecentSectionPlanner.unreadCount(ids: group.ids,' in headers
    assert 'unread: sidebarBadgeStore.unreadSessionIds)' in headers, 'count comes from the real unread set'
    assert 'sidebarBadgeStore' in headers, 'the store must be the source, not a local counter'
    # Folded: rows disappear, membership does not — the count is built from
    # group.ids, which a fold never empties (only FOLDER groups are emptied).
    assert 'recent.accordionMemberIDs = recentPlan.ids' in grouping
    assert 'if g.isCollapsed { g.ids = [] }' in grouping, 'only folder groups may drop their ids'
    checks += 1
    # "全部已读" uses the EXISTING mark-read primitive only: it removes the
    # transient `.unread` hint. It must not clear other badge states, delete a
    # message, or rewrite a session.
    assert 'markAllRead: { markAllSessionsRead() }' in headers, 'the button runs the mark-read action'
    assert 'Text("Mark All as Read")' in recent_row, 'the button label is a catalog key'
    mark = headers[headers.index('func markAllSessionsRead()'):]
    mark = mark[:mark.index('\n    }')]
    assert 'sidebarBadgeStore.remove(.unread, for: id)' in mark, 'marking read = remove(.unread)'
    assert 'clearAll' not in mark, 'marking read must NOT wipe paused/other badge states'
    for forbidden in ('deleteSession', 'ChatStore', 'deleteMessage', 'updatedAt =', 'setFolder'):
        assert forbidden not in mark, f'全部已读 must not touch session content ({forbidden})'
    checks += 1
    # The button is OUTSIDE the fold tap area: the fold gesture sits on the
    # leading child, the button is its sibling, so no gesture race can fold the
    # bucket while the user meant to mark everything read.
    tap = recent_row[recent_row.index('THE FOLD TAP AREA'):recent_row.index('if let markAllRead')]
    assert '.onTapGesture { if folds { state.toggle() } }' in tap, 'the fold tap stays on the leading region'
    assert 'Button(action: markAllRead)' in recent_row, 'the button is a sibling of that region'
    after_button = recent_row[recent_row.index('if let markAllRead'):]
    assert '.onTapGesture' not in after_button, 'the button must not carry the fold gesture'
    assert '.buttonStyle(.plain)' in after_button
    checks += 1

    # --- every renderer folds the bucket ------------------------------------
    assert 'RecentSectionHeaderRow(label: group.label,' in headers
    assert '|| group.label == "Recent"' in headers
    assert session_list.count('RecentBucketRows(active: isRecentBucket(group))') == 2, 'both lists fold Recent'
    assert 'PinnedBucketRows(active: isPinnedBucket(group) && !isSearching)' in session_list
    assert session_list.count('RecentSectionPlanner.dimOpacity') == 2, 'both lists dim read rows'
    assert '.opacity(group.isDimmed(id) ? RecentSectionPlanner.dimOpacity : 1)' in native
    checks += 1

    # --- settings ------------------------------------------------------------
    assert '@AppStorage("sidebarRecentSectionEnabled") private var showsRecentSection: Bool = true' in settings
    assert '@AppStorage("sidebarRecentSectionCount") private var recentSectionCount: Int = 5' in settings
    assert 'Toggle("Show Recent Section", isOn: $showsRecentSection)' in settings
    assert 'Picker("Recent Section Chats", selection: $recentSectionCount)' in settings
    assert 'ForEach([3, 5, 10], id: \\.self)' in settings
    assert 'static let enabledKey = "sidebarRecentSectionEnabled"' in groups
    assert 'static let limitKey = "sidebarRecentSectionCount"' in groups
    # The appearance gate counts the six legacy gray menu pickers: the new
    # picker must not join that pattern.
    assert len(re.findall(r'\.pickerStyle\(\.menu\)\s*\.tint\(Color\(uiColor: \.secondaryLabel\)\)',
                          settings)) == 6, 'the six gray menu pickers must stay exactly six'
    checks += 1

    # --- catalog: every new key is translated, the footer key matches the view -
    for key, zh in (('Show Recent Section', '显示最近分区'),
                    ('Recent Section Chats', '最近分区条数')):
        assert key in catalog, f'missing catalog key {key!r}'
        assert catalog[key]['localizations']['zh-Hans']['stringUnit']['value'] == zh
        checks += 1
    assert catalog['Recent']['localizations']['zh-Hans']['stringUnit']['value'] == '最近'
    footer_literal = re.search(r'Text\("(Unread, running and recently active[^"]*)"\)', settings)
    assert footer_literal, 'recent-section footer text is missing'
    footer_key = footer_literal.group(1)
    assert footer_key in catalog, 'the footer Text literal is not a catalog key'
    assert '超过 4 个' in catalog[footer_key]['localizations']['zh-Hans']['stringUnit']['value']
    checks += 1
    for key, zh in (('Mark All as Read', '全部已读'),):
        assert key in catalog, f'missing catalog key {key!r}'
        assert catalog[key]['localizations']['zh-Hans']['stringUnit']['value'] == zh
        assert catalog[key]['localizations']['zh-Hant']['stringUnit']['value'] == '全部已讀'
        checks += 1

    # --- [T-sidebar-recent-pinned-copy] duplicate identity is contained ------
    #
    # One chat in two sections is legitimate now; two rows sharing ONE identity
    # inside one ForEach is the shape that has crashed this list. Three things
    # keep them apart, and all three are asserted:
    #   1. the plain-List select rows carry a SECTION-scoped `.id()`;
    #   2. the native accordion keys rows by IndexPath (UIKit cells), and its
    #      label cells are re-rendered from the section's own group;
    #   3. the DEBUG tracer reports duplicates PER SECTION, not on the
    #      flattened sequence (which now repeats by design).
    assert session_list.count(r'.id("select-\(group.id)-\(sessionId)")') == 2, \
        'both lists must scope their select row ids by section'
    assert r'.id("select-\(sessionId)")' not in session_list, 'an unscoped row id would collide across sections'
    tracer = read(SIDEBAR / 'SidebarIdentityTracer.swift')
    assert 'let duplicatedSections = groups.filter { $0.ids.count != Set($0.ids).count }' in tracer, \
        'the duplicate check must be per section'
    assert 'rows.count != newRowSet.count' not in tracer, \
        'the flattened check now fires on the legitimate pinned copy'
    checks += 1
    print(f'SIDEBAR_RECENT_SOURCE_PASS checks={checks}', flush=True)
    return checks


def logic_run():
    OUT.mkdir(parents=True, exist_ok=True)
    groups = read(SIDEBAR / 'SidebarGroups.swift')
    planner = slice_between(groups, BEGIN, END, 'planner')
    assert 'struct RecentCandidate' in planner and 'enum RecentSectionPlanner' in planner
    (OUT / 'ProductionRecentPlanner.swift').write_text('import Foundation\n\n' + planner + '\n')
    test = read(ROOT / 'scripts/sidebar-recent-tests/RecentSectionPlannerTests.swift')
    # A top-level test program must be the compiler's `main.swift`.
    (OUT / 'main.swift').write_text(test)
    compiler = 'swiftc'
    exe = OUT / 'recent-planner-tests'
    subprocess.run([compiler, '-O', str(OUT / 'ProductionRecentPlanner.swift'),
                    str(OUT / 'main.swift'), '-o', str(exe)], check=True)
    result = subprocess.run([str(exe)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, flush=True)
    (OUT / 'results.log').write_text(result.stdout)
    assert result.returncode == 0, 'recent-section planner tests failed'
    match = re.search(r'SIDEBAR_RECENT_PASS checks=(\d+)', result.stdout)
    assert match, result.stdout
    print(f'SIDEBAR_RECENT_LOGIC_PASS checks={match.group(1)}', flush=True)
    return int(match.group(1))


def main():
    source_checks()
    if '--source-only' in sys.argv:
        print('SIDEBAR_RECENT_SOURCE_ONLY planner not executed')
        return 0
    logic_run()
    print('SIDEBAR_RECENT_OK', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
