#!/usr/bin/env python3
"""Determine and cryptographically verify CI regression scope (full vs incremental)."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

# Complete source/script dependency specifications for conditionally skippable
# regression suites in incremental mode. Any change in these paths (or any
# changed path outside ALLOWED_INCREMENTAL_FILES) forces the affected suite(s)
# or falls back to full validation.
SKIPPABLE_MODULES = {
    'card_dark': [
        'scripts/card_dark_regression.py',
        'scripts/card-dark-tests/',
        'src/ios/Views/Chat/AIChatView/MinisUI/',
        'src/ios/Views/Chat/AIChatView/Support/ChatColors.swift',
    ],
    'theme_suite': [
        # [T-showui-interaction-theme] the show_ui interaction suite runs inside
        # the theme job; its own inputs are listed here so an incremental run
        # cannot skip a module whose compiled surface includes MinisUI.
        'scripts/showui_interaction_regression.py',
        'scripts/showui-interaction-tests/',
        'src/ios/Assets.xcassets/AccentColor.colorset/',
        'scripts/image_geometry_regression.py',
        'scripts/image_reflow_fixture.py',
        'scripts/image-geometry-tests/',
        'scripts/theme_matrix_regression.py',
        'scripts/theme-matrix-tests/',
        'scripts/settings_menu_regression.py',
        'scripts/settings-menu-tests/',
        'scripts/appearance_secondary_regression.py',
        'scripts/appearance-secondary-tests/',
        'src/ios/Views/Chat/Markdown/Attachments/ImageAttachment.swift',
        'src/ios/Views/Chat/Markdown/TextKit/SelectableMarkdownTextView+AttachmentViews.swift',
        'src/ios/Views/Chat/AIChatView/MinisUI/',
        'src/ios/Views/Chat/AIChatView/Support/ChatColors.swift',
        'src/ios/Views/Settings/',
        'src/ios/Views/ContentView/ContentView.swift',
        'src/ios/Shared/AppLocalization.swift',
        'src/ios/Shared/FontSettings.swift',
        'src/ios/MinisApp.swift',
        'src/ios/Localizable.xcstrings',
        'src/ios/MinisTests/Standalone/AppearanceSecondarySettingsTests.swift',
        'src/ios/MinisTests/Standalone/SendButtonReturnModeMenuTests.swift',
    ],
    'map': [
        'scripts/map_regression.py',
        'scripts/map_render_regression.py',
        'scripts/generate_map_data.py',
        'scripts/generate_map_packs.py',
        'scripts/map-tests/',
        'src/ios/Views/Chat/AIChatView/MinisUI/',
        'src/ios/Views/Chat/AIChatView/Support/ChatColors.swift',
    ],
    'chart_layout': [
        'scripts/chart_layout_regression.py',
        'scripts/chart-layout-tests/',
        'src/ios/Views/Chat/AIChatView/MinisUI/',
    ],
    'chart_render': [
        'scripts/chart_render_regression.py',
        'scripts/chart-render-tests/',
        'src/ios/Views/Chat/AIChatView/MinisUI/',
        'src/ios/Views/Chat/AIChatView/Support/ChatColors.swift',
    ],
}

# Files that are safe to modify in an incremental toolfold/message-list build
# without invalidating the unchanged map/chart/theme/card_dark modules.
ALLOWED_INCREMENTAL_PREFIXES = (
    '.github/workflows/build-ios.yml',
    'scripts/ci_validation_scope.py',
    'scripts/toolfold',
    'scripts/statusbar_scroll_regression.py',
    'scripts/statusbar-scroll-tests/',
    # [T-statusbar-native-scroll] the lifecycle type is a new production file
    # inside the message-list dependency tree; the suite above must run on the
    # current commit, so its script paths are safe incremental inputs.
    'scripts/thinking-transaction-tests/',
    'scripts/thinking_transaction_regression.py',
    # [T-user-ask-anchor-clamp] 2026-11-19. The answered-question card's
    # collapse anchor: its gate compiles the shipping ToggleAnchorMath block and
    # runs inside the mandatory toolfold step, so these paths are inputs of no
    # skippable module spec - allowing them only stops an incremental dispatch
    # from degrading to full for a reason the module hashes already decide.
    'scripts/ask_card_anchor_regression.py',
    'scripts/ask_card_anchor_uikit.py',
    'scripts/ask-card-anchor-tests/',
    'scripts/genui-height-tests/',
    'scripts/genui_height_regression.py',
    # [T-fold-open-card] the show_ui A/B regression is an input of the
    # toolfold step only; it is not part of any skippable module spec, so
    # touching it cannot make chart/map/theme inherit or run twice.
    'scripts/genui_fold_barrier_regression.py',
    # [T-showui-interaction-theme] the interaction suite runs inside the theme
    # job; listing its own files here only stops an incremental dispatch from
    # degrading to full for a reason the module hash already decides. No module
    # spec is narrowed and the whole MinisUI/ tree stays a dependency of all.
    'scripts/showui_interaction_regression.py',
    'scripts/showui-interaction-tests/',
    'src/ios/Agent/MessageList/',
    'src/ios/Views/Chat/AssistantBlockView.swift',
    'src/ios/MinisTests/Standalone/ToolFoldPlannerTests.swift',
    # showui-fold-settings-20261117: the three merged patch surfaces. These files
    # are the *inputs* of the chart_layout / card_dark / theme_suite / map /
    # chart_render specs above, so touching them makes those modules RUN (their
    # tree hash changes) instead of inheriting the baseline — allowing the paths
    # here only keeps an incremental dispatch from degrading to a full run for a
    # reason the hash already decides. No spec list is narrowed by this.
    'scripts/chart-layout-tests/',
    'scripts/chart_layout_regression.py',
    'src/ios/Views/Chat/AIChatView/MinisUI/',
    # [T-showui-interaction-theme] the action tint token now lives beside the
    # other native surface tokens. ChatColors.swift is already an input of the
    # card_dark / theme_suite / map / chart_render specs, so editing it makes
    # those modules RUN through their tree hash; allowing the path here only
    # keeps the dispatch from degrading to full for a reason the hash decides.
    'src/ios/Views/Chat/AIChatView/Support/ChatColors.swift',
    'src/ios/Views/Settings/',
    'src/ios/Localizable.xcstrings',
    'src/ios/Shared/Config/',
    'src/ios/Views/Chat/ChatExportRenderer.swift',
    'src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift',
    # [T-attachment-raw-url-encoding / T-attachment-xml-attr-escape] 2026-11-18.
    # Attachment path -> minis:// URL encoding and the <user-attached-files>
    # attribute codec touch only these Chat-layer files. They are NOT inputs of
    # any skippable module spec above (no fixture compiles them; the two scripts
    # that read ChatModels.swift live in the mandatory toolfold/thinking steps),
    # so the map/chart/theme/card-dark tree hashes stay identical and those
    # modules inherit the signed baseline instead of re-rendering 24 + 99 + 46
    # PNGs for a colour-neutral change. The new attachment step is UNCONDITIONAL
    # in build-ios.yml, so it cannot be skipped by an incremental dispatch.
    'src/ios/Agent/Chat/MinisURLEncoding.swift',
    'src/ios/Agent/Chat/AttachmentXMLCodec.swift',
    'src/ios/Agent/Chat/MinisURLPathDecoding.swift',
    'src/ios/Agent/Chat/ChatModels.swift',
    'src/ios/Agent/Chat/RawMessage+Conversion.swift',
    'src/ios/Agent/Chat/AIChatViewModel+Send.swift',
    'src/ios/Agent/Chat/AIChatViewModel+Attachments.swift',
    'scripts/attachment_url_regression.py',
    'scripts/attachment-url-tests/',
    'src/ios/MinisTests/Standalone/ImageCtxIosETests.swift',
)


def git(repo: pathlib.Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def resolve_commit(repo: pathlib.Path, ref: str) -> str:
    return git(repo, 'rev-parse', '--verify', ref + '^{commit}')


def is_ancestor(repo: pathlib.Path, ancestor: str, descendant: str) -> bool:
    r = subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', ancestor, descendant])
    return r.returncode == 0


def module_tree_hash(repo: pathlib.Path, commit: str, specs: list[str]) -> tuple[str, list[dict]]:
    entries = []
    out = git(repo, 'ls-tree', '-r', commit, '--', *specs)
    for line in out.splitlines():
        if not line:
            continue
        meta, path = line.split('\t', 1)
        parts = meta.split()
        blob_sha = parts[2]
        entries.append({'path': path, 'blob': blob_sha})
    entries.sort(key=lambda e: e['path'])
    h = hashlib.sha256()
    for e in entries:
        h.update(f"{e['path']}\0{e['blob']}\n".encode())
    return h.hexdigest(), entries


def path_is_allowed_incremental(path: str) -> bool:
    return any(path == p or path.startswith(p) for p in ALLOWED_INCREMENTAL_PREFIXES)


PBXPROJ_PATH = 'src/ios/Minis.xcodeproj/project.pbxproj'
PBXPROJ_HELPER_IDS = {
    'MinisURLEncoding.swift': ('E5AUE0001', 'E5AUE0011'),
    'AttachmentXMLCodec.swift': ('E5AXC0001', 'E5AXC0011'),
}


def pbxproj_expected_additions() -> set[str]:
    """The exact 8 registration lines (canonical, tab-indented) for the two helpers."""
    lines = set()
    for name, (build_id, ref_id) in PBXPROJ_HELPER_IDS.items():
        lines.add(f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};')
        lines.add(f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
        lines.add(f'\t\t\t\t{ref_id} /* {name} */,')
        lines.add(f'\t\t\t\t{build_id} /* {name} in Sources */,')
    return lines


def pbxproj_registration_matches(added: list[str], removed: list[str]) -> bool:
    """Pure predicate over diff lines: exactly the canonical 8 added lines, no removal.

    Anything else — a settings change, an extra line that merely mentions a helper
    (e.g. a comment), a different id, a deletion — is rejected so the dispatch falls
    back to a full run instead of inheriting modules on an unproven project diff.
    """
    if removed:
        return False
    return set(added) == pbxproj_expected_additions() and len(added) == 8


def _diff_lines(out: str) -> tuple[list[str], list[str]]:
    added, removed = [], []
    for line in out.splitlines():
        if line.startswith('+++') or line.startswith('---'):
            continue
        if line.startswith('+'):
            added.append(line[1:])
        elif line.startswith('-'):
            removed.append(line[1:])
    return added, removed


def pbxproj_is_pure_helper_registration(repo: pathlib.Path, baseline: str, head: str) -> bool:
    """True only when the project file changed by ADDING exactly the 8 registration
    lines of the two new helpers and nothing else.

    The Agent/Chat PBXGroup is a classic (non-synchronised) group, so a new source
    file must be listed by hand (PBXFileReference + PBXBuildFile + group children +
    Sources phase) or the target never compiles it. Whitelisting the project file would
    silently allow ANY future project change, so instead this predicate proves the diff
    is exactly that registration; anything else stays unexpected -> full run.
    """
    out = git(repo, 'diff', '--unified=0', f'{baseline}..{head}', '--', PBXPROJ_PATH)
    added, removed = _diff_lines(out)
    return pbxproj_registration_matches(added, removed)


def pbxproj_selftest() -> int:
    """Negative/positive cases for the predicate (used by the CI attachment step)."""
    ok = pbxproj_expected_additions()
    cases = [
        ('pure_registration', ok, set(), True),
        ('reordered_same_set', list(ok)[::-1], [], True),
        ('extra_comment_mentioning_helper', ok | {'// MinisURLEncoding.swift helper'}, set(), False),
        ('seven_lines_only', set(list(ok)[:7]), set(), False),
        ('deletion_present', ok, {'\t\tdeadbeef /* old */,'}, False),
        ('wrong_reference_id', (ok - {f'\t\tE5AUE0001 /* MinisURLEncoding.swift in Sources */ = {{isa = PBXBuildFile; fileRef = E5AUE0011 /* MinisURLEncoding.swift */; }};'})
         | {'\t\tE5AUE0001 /* MinisURLEncoding.swift in Sources */ = {isa = PBXBuildFile; fileRef = DEADBEEF /* MinisURLEncoding.swift */; };'}, set(), False),
        ('unrelated_project_setting', ok | {'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;'}, set(), False),
    ]
    failures = 0
    for name, added, removed, expected in cases:
        got = pbxproj_registration_matches(list(added), list(removed))
        if got != expected:
            failures += 1
            print(f'PBXPROJ_SELFTEST_FAIL {name} expected={expected} got={got}')
    if failures:
        print(f'PBXPROJ_PREDICATE_SELFTEST_FAIL cases={len(cases)} failures={failures}')
        return 1
    print(f'PBXPROJ_PREDICATE_SELFTEST_OK cases={len(cases)}')
    return 0


def compute_scope(repo: pathlib.Path, mode: str, baseline_ref: str, head_ref: str = 'HEAD') -> dict:
    head_sha = resolve_commit(repo, head_ref)
    result = {
        'mode': 'full',
        'requested_mode': mode,
        'head_sha': head_sha,
        'baseline_sha': None,
        'fallback_reason': None,
        'changed_files': [],
        'unexpected_changed_files': [],
        'modules': {},
        'skipped_modules': [],
        'executed_modules': list(SKIPPABLE_MODULES.keys()) + ['mod_uikit', 'thinking_uikit', 'toolfold'],
    }

    if mode != 'incremental':
        for mod in SKIPPABLE_MODULES:
            result['modules'][mod] = {'run': True, 'reason': 'full_mode'}
        result['modules']['mod_uikit'] = {'run': True, 'reason': 'full_mode'}
        result['modules']['thinking_uikit'] = {'run': False, 'reason': 'not_in_default_full_workflow'}
        result['modules']['toolfold'] = {'run': True, 'reason': 'full_mode'}
        return result

    if not baseline_ref:
        result['fallback_reason'] = 'missing_baseline_sha'
        return compute_scope(repo, 'full', '', head_ref) | {'requested_mode': 'incremental', 'fallback_reason': 'missing_baseline_sha'}

    try:
        baseline_sha = resolve_commit(repo, baseline_ref)
    except subprocess.CalledProcessError:
        out = compute_scope(repo, 'full', '', head_ref)
        out['requested_mode'] = 'incremental'
        out['fallback_reason'] = f'unresolvable_baseline:{baseline_ref}'
        return out

    if not is_ancestor(repo, baseline_sha, head_sha):
        out = compute_scope(repo, 'full', '', head_ref)
        out['requested_mode'] = 'incremental'
        out['baseline_sha'] = baseline_sha
        out['fallback_reason'] = 'baseline_not_ancestor'
        return out

    changed = [line for line in git(repo, 'diff', '--name-only', f'{baseline_sha}..{head_sha}').splitlines() if line]
    pbxproj_exception = PBXPROJ_PATH in changed and pbxproj_is_pure_helper_registration(repo, baseline_sha, head_sha)
    result['pbxproj_helper_registration'] = bool(pbxproj_exception)
    unexpected = [p for p in changed
                  if not path_is_allowed_incremental(p)
                  and not (p == PBXPROJ_PATH and pbxproj_exception)]

    result['baseline_sha'] = baseline_sha
    result['changed_files'] = changed
    result['unexpected_changed_files'] = unexpected

    if unexpected:
        out = compute_scope(repo, 'full', '', head_ref)
        out['requested_mode'] = 'incremental'
        out['baseline_sha'] = baseline_sha
        out['changed_files'] = changed
        out['unexpected_changed_files'] = unexpected
        out['fallback_reason'] = 'unexpected_files_changed'
        return out

    result['mode'] = 'incremental'
    skipped = []
    executed = []
    for mod, specs in SKIPPABLE_MODULES.items():
        base_hash, base_entries = module_tree_hash(repo, baseline_sha, specs)
        head_hash, head_entries = module_tree_hash(repo, head_sha, specs)
        unchanged = (base_hash == head_hash and len(base_entries) > 0)
        result['modules'][mod] = {
            'run': not unchanged,
            'unchanged': unchanged,
            'baseline_tree_hash': base_hash,
            'head_tree_hash': head_hash,
            'file_count': len(head_entries),
            'reason': 'unchanged_tree_hash' if unchanged else 'module_changed',
        }
        if unchanged:
            skipped.append(mod)
        else:
            executed.append(mod)

    for mandatory in ('mod_uikit', 'thinking_uikit', 'toolfold'):
        result['modules'][mandatory] = {'run': True, 'reason': 'mandatory_incremental_target'}
        executed.append(mandatory)

    result['skipped_modules'] = skipped
    result['executed_modules'] = executed
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', default='full', choices=['full', 'incremental'])
    parser.add_argument('--baseline', default='')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--repo', default=str(ROOT))
    parser.add_argument('--out', default='')
    parser.add_argument('--github-output', default=os.environ.get('GITHUB_OUTPUT', ''))
    parser.add_argument('--self-test-pbxproj', action='store_true')
    args = parser.parse_args()

    if args.self_test_pbxproj:
        sys.exit(pbxproj_selftest())

    repo = pathlib.Path(args.repo)
    scope = compute_scope(repo, args.mode, args.baseline, args.head)
    payload = json.dumps(scope, indent=2, sort_keys=True)
    if args.out:
        out_path = pathlib.Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(payload + '\n')

    if args.github_output:
        lines = [
            f"mode={scope['mode']}",
            f"baseline_sha={scope.get('baseline_sha') or ''}",
            f"run_card_dark={'true' if scope['modules']['card_dark']['run'] else 'false'}",
            f"run_theme_suite={'true' if scope['modules']['theme_suite']['run'] else 'false'}",
            f"run_map={'true' if scope['modules']['map']['run'] else 'false'}",
            f"run_chart_layout={'true' if scope['modules']['chart_layout']['run'] else 'false'}",
            f"run_chart_render={'true' if scope['modules']['chart_render']['run'] else 'false'}",
            f"run_mod_uikit={'true' if scope['modules']['mod_uikit']['run'] else 'false'}",
            f"run_thinking_uikit={'true' if scope['modules']['thinking_uikit']['run'] else 'false'}",
            f"run_toolfold={'true' if scope['modules']['toolfold']['run'] else 'false'}",
        ]
        with open(args.github_output, 'a') as f:
            f.write('\n'.join(lines) + '\n')

    print('VALIDATION_SCOPE_JSON ' + json.dumps(scope, sort_keys=True))


if __name__ == '__main__':
    main()
