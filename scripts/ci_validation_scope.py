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
    'scripts/thinking-transaction-tests/',
    'scripts/thinking_transaction_regression.py',
    'scripts/genui-height-tests/',
    'scripts/genui_height_regression.py',
    # [T-fold-open-card] the show_ui A/B regression is an input of the
    # toolfold step only; it is not part of any skippable module spec, so
    # touching it cannot make chart/map/theme inherit or run twice.
    'scripts/genui_fold_barrier_regression.py',
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
    'src/ios/Views/Settings/',
    'src/ios/Localizable.xcstrings',
    'src/ios/Shared/Config/',
    'src/ios/Views/Chat/ChatExportRenderer.swift',
    'src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift',
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
    unexpected = [p for p in changed if not path_is_allowed_incremental(p)]

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
    args = parser.parse_args()

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
