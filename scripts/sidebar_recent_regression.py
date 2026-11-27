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
        'if candidate.isPinned { return nil }',
        'if candidate.isRunning { return .running }',
        'if candidate.isUnread { return .unread }',
        'return now.timeIntervalSince(candidate.updatedAt) < window ? .recent : nil',
    ):
        assert literal in groups, f'membership rule drifted: {literal!r}'
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

    # --- header: clock out of the layout flow, title x identical to Pinned ---
    pin_row = slice_between(surfaces, 'struct PinnedSectionHeaderRow: View {',
                            '/// [T-sidebar-recent-section] The "最近" bucket', 'PinnedSectionHeaderRow')
    recent_row = slice_between(surfaces, 'struct RecentSectionHeaderRow: View {',
                               '/// [T-sidebar-recent-section] Rows of the Recent bucket', 'RecentSectionHeaderRow')
    for row, name in ((pin_row, 'pinned'), (recent_row, 'recent')):
        hstack = slice_between(row, 'HStack(spacing: 4) {',
                               '.frame(maxWidth: .infinity, alignment: .leading)', f'{name} hstack')
        assert 'Image(' not in hstack.split('if folds')[0], f'{name}: no glyph may precede the title'
        assert hstack.index('Text(LocalizedStringKey(label))') < hstack.index('if folds'), name
        assert '.overlay(alignment: .leading) {' in row, f'{name}: glyph must be a leading overlay'
        assert '.offset(x: -PinnedTitlePin.gutter)' in row, f'{name}: glyph must hang in the gutter'
        checks += 1
    # Same title text, same spacing, same chevron -> same x for both buckets.
    def title_block(row):
        hstack = slice_between(row, 'HStack(spacing: 4) {', '.frame(maxWidth: .infinity, alignment: .leading)', 'hstack')
        return hstack[:hstack.index('if folds')]
    assert title_block(pin_row) == title_block(recent_row), 'both bucket titles must be laid out identically'
    assert 'Image(systemName: "clock.arrow.circlepath")' in recent_row
    assert '.font(.system(size: PinnedTitlePin.glyphPointSize, weight: .semibold))' in recent_row
    assert '.frame(width: PinnedTitlePin.glyphBox.width,\n                       height: PinnedTitlePin.glyphBox.height)' in recent_row
    assert 'Image(systemName: "pin.fill")' in pin_row
    assert 'static let gutter: CGFloat = 14' in surfaces
    assert 'static let glyphBox = CGSize(width: 10, height: 12)' in surfaces
    assert 'static let glyphPointSize: CGFloat = 10' in surfaces
    checks += 1

    # --- every renderer folds the bucket ------------------------------------
    assert 'RecentSectionHeaderRow(label: group.label, folds: !isSearching)' in headers
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
