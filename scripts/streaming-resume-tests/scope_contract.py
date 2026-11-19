#!/usr/bin/env python3
"""Offline proof: exact resume exemptions cannot hide unrelated/module changes."""
import importlib.util
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scope', ROOT / 'scripts/ci_validation_scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
checks = 0

def need(ok, label):
    global checks
    if not ok:
        raise AssertionError(label)
    checks += 1

for name in scope.ALLOWED_RESUME_EXACT_FILES:
    need(scope.path_is_allowed_incremental(name), 'exact positive: ' + name)
    for suffix in ('.bak', '/other.swift', 'Extra'):
        need(not scope.path_is_allowed_incremental(name + suffix), 'exact suffix negative: ' + name + suffix)
need(not scope.path_is_allowed_incremental('src/ios/Agent/Chat/Unreviewed.swift'), 'no blanket Chat exemption')
need(scope.path_is_allowed_incremental('scripts/streaming-resume-tests/ResumeMain.swift'), 'driver is covered')

with tempfile.TemporaryDirectory(prefix='resume-scope-') as tmp:
    repo = pathlib.Path(tmp)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    def write(name, text='baseline\n'):
        p = repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    def commit():
        git('add', '.')
        git('commit', '-qm', 'offline scope test')
        return git('rev-parse', 'HEAD')
    git('init', '-q')
    git('config', 'user.name', 'Scope Test')
    git('config', 'user.email', 'scope@example.invalid')
    for specs in scope.SKIPPABLE_MODULES.values():
        for name in specs:
            write(name + 'scope-probe.txt' if name.endswith('/') else name)
    for name in scope.ALLOWED_RESUME_EXACT_FILES:
        write(name)
    base = commit()
    for name in scope.ALLOWED_RESUME_EXACT_FILES:
        write(name, 'resume change\n')
    write('scripts/streaming-resume-tests/ResumeMain.swift', 'new regression\n')
    resume = commit()
    result = scope.compute_scope(repo, 'incremental', base, resume)
    need(result['mode'] == 'incremental', 'resume-only stays incremental')
    for module in scope.SKIPPABLE_MODULES:
        evidence = result['modules'][module]
        need(evidence['run'] is False and evidence['file_count'] > 0
             and evidence['head_tree_hash'] == evidence['baseline_tree_hash'], 'real unchanged hash: ' + module)
    for module in ('mod_uikit', 'thinking_uikit', 'toolfold'):
        need(result['modules'][module]['run'] is True, 'mandatory suite retained: ' + module)
    write('src/ios/Agent/Chat/Unreviewed.swift')
    unknown = commit()
    result = scope.compute_scope(repo, 'incremental', base, unknown)
    need(result['mode'] == 'full' and 'src/ios/Agent/Chat/Unreviewed.swift'
         in result['unexpected_changed_files'], 'unreviewed Chat change forces full')
    git('checkout', '-q', resume)
    write('src/ios/Views/Chat/AIChatView/MinisUI/scope-probe.txt', 'changed rendering\n')
    render = commit()
    result = scope.compute_scope(repo, 'incremental', base, render)
    need(result['mode'] == 'incremental', 'render change is mapped not hidden')
    for module in scope.SKIPPABLE_MODULES:
        need(result['modules'][module]['run'] is True, 'changed render module reruns: ' + module)
print('STREAMING_RESUME_SCOPE_PASS checks=' + str(checks))
