#!/usr/bin/env python3
"""Attachment raw-path URL encoding + <user-attached-files> XML attribute codec.

Compiles the REAL production files
  src/ios/Agent/Chat/MinisURLEncoding.swift
  src/ios/Agent/Chat/AttachmentXMLCodec.swift
  src/ios/Agent/Chat/MinisURLPathDecoding.swift
together with scripts/attachment-url-tests/main.swift and runs the result.
Nothing here re-implements the encoder/decoder: a regression in the production
helper fails this step.

Markers (consumed by build.py / review gates — a log that only echoes them
cannot pass, the counts are floors on the executed assertions):
  ATTACHMENT_URL_PASS checks=<n>       raw path -> minis:// URL + resolver identity
  ATTACHMENT_XML_PASS checks=<n>       escape / single-pass unescape / tag parse
  ATTACHMENT_SOURCE_PASS checks=<n>    production call sites really use the helpers
  ATTACHMENT_URL_XML_PASS url_checks=.. xml_checks=.. source_checks=..
  ATTACHMENT_URL_FAIL / ATTACHMENT_XML_FAIL / ATTACHMENT_SOURCE_FAIL on failure

Usage:
  python3 scripts/attachment_url_regression.py               # compile + run + wiring
  python3 scripts/attachment_url_regression.py --source-only # wiring only (no Swift)
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS = ROOT / 'src' / 'ios'
BUILD = ROOT / 'build' / 'attachment-url'
AGENT = IOS / 'Agent' / 'Chat'
URL_HELPER = AGENT / 'MinisURLEncoding.swift'
XML_HELPER = AGENT / 'AttachmentXMLCodec.swift'
DECODER = AGENT / 'MinisURLPathDecoding.swift'
TEST_MAIN = ROOT / 'scripts' / 'attachment-url-tests' / 'main.swift'

MIN_URL_CHECKS = 110
MIN_XML_CHECKS = 44
MIN_SOURCE_CHECKS = 12

failures = []


def check(condition, label):
    if not condition:
        failures.append(label)
        print('ATTACHMENT_SOURCE_CHECK_FAIL ' + label)
    return bool(condition)


def read(path):
    return path.read_text(errors='replace')


def source_checks():
    checks = 0
    chat_models = read(AGENT / 'ChatModels.swift')
    send = read(AGENT / 'AIChatViewModel+Send.swift')
    attachments = read(AGENT / 'AIChatViewModel+Attachments.swift')
    conversion = read(AGENT / 'RawMessage+Conversion.swift')
    url_src = read(URL_HELPER)
    xml_src = read(XML_HELPER)
    link_resolution = read(IOS / 'Views/Chat/Markdown/Support/MinisLinkResolution.swift')
    decoding_src = read(DECODER)
    image_ctx_tests = read(IOS / 'MinisTests/Standalone/ImageCtxIosETests.swift')

    checks += check('MinisURLEncoding.minisURL(forLinuxPath: path)' in chat_models,
                    'AttachmentMeta.minisURL delegates to the shared encoder')
    checks += check('"minis://\\(rel)"' not in chat_models and 'minis://\\(rel)' not in chat_models,
                    'ChatModels no longer concatenates minis:// by hand')
    checks += check('AttachmentXMLCodec.fileTagXML(path: meta.path, url: meta.minisURL' in send,
                    'Send.swift writes the <file> tag through the codec')
    checks += check('AttachmentXMLCodec.fileTagXML(path: meta.path, url: meta.minisURL' in attachments,
                    'Attachments.swift (queue route) writes through the same codec')
    checks += check('AttachmentXMLCodec.parseFileTags(in: body)' in conversion,
                    'RawMessage+Conversion reads through the same codec')
    checks += check('filePattern' not in conversion and 'NSRegularExpression(\n' not in conversion,
                    'the old attribute-order-sensitive <file> regex is gone')
    checks += check('s.contains("<user-attached-files>")' in conversion
                    and 's.range(of: openTag)' in conversion,
                    'outer <user-attached-files> block matching is unchanged')
    checks += check('.removingPercentEncoding' not in url_src,
                    'the encoder never pre-decodes (no .removingPercentEncoding call)')
    checks += check('.removingPercentEncoding' not in xml_src,
                    'the XML codec never pre-decodes (no .removingPercentEncoding call)')
    checks += check('import Foundation' in url_src and 'import UIKit' not in url_src
                    and 'import SwiftUI' not in url_src,
                    'MinisURLEncoding.swift is Foundation-only (the test compiles the real file)')
    checks += check('import Foundation' in xml_src and 'import UIKit' not in xml_src
                    and 'import SwiftUI' not in xml_src,
                    'AttachmentXMLCodec.swift is Foundation-only (the test compiles the real file)')
    checks += check('"xml-attributes-v1"' in xml_src and 'encodingAttribute' in xml_src,
                    'the new-format marker is a named constant')
    checks += check('percentEncodePathSegmentIdempotent' in link_resolution
                    and 'removingPercentEncoding' in link_resolution,
                    'markdown-side idempotent repair is kept (not replaced by the raw encoder)')
    checks += check('subPathCandidates' in decoding_src
                    and 'removingPercentEncoding' in decoding_src,
                    'resolver double-decode fallback is kept for legacy links')
    checks += check('AttachmentXMLCodec.fileTagXML(path: meta.path' in image_ctx_tests,
                    'ImageCtxIosETests mirror assertion tracks the new writer line')

    # Nothing in production may interpolate a raw path into an XML attribute again.
    raw_interpolations = []
    for path in IOS.rglob('*.swift'):
        if '/MinisTests/' in str(path) or path.name == 'AttachmentXMLCodec.swift':
            # AttachmentXMLCodec is the one sanctioned writer; it escapes every
            # value it interpolates.
            continue
        text = read(path)
        if re.search(r'path=\\?"\\\(', text) or re.search(r'path=\\"\\\\\(', text) or 'path=\\"\\(meta.path)' in text:
            raw_interpolations.append(str(path.relative_to(ROOT)))
    checks += check(not raw_interpolations,
                    'no production site interpolates a raw path into an XML attribute: %s' % raw_interpolations)

    # [T-attachment-raw-url-encoding] Target membership, not just "the file exists":
    # the Agent/Chat group is a classic PBXGroup, so a file missing from the project
    # never compiles and the app would fail with "cannot find 'MinisURLEncoding'".
    pbxproj = read(IOS / 'Minis.xcodeproj' / 'project.pbxproj')
    for name in ('MinisURLEncoding.swift', 'AttachmentXMLCodec.swift'):
        ref_lines = [l for l in pbxproj.splitlines() if name in l]
        checks += check(len(ref_lines) == 4,
                        f'{name} is registered exactly 4 times (fileRef, buildFile, group, Sources)')
        checks += check(any('isa = PBXFileReference' in l and f'path = {name};' in l for l in ref_lines),
                        f'{name} has a PBXFileReference with its path')
        checks += check(any(f'/* {name} in Sources */ = {{isa = PBXBuildFile' in l for l in ref_lines),
                        f'{name} has a PBXBuildFile')
        checks += check(any(l.strip().startswith('E5') and l.strip().endswith(f'/* {name} */,') for l in ref_lines),
                        f'{name} is a child of its PBXGroup')
        checks += check(any(l.strip().startswith('E5') and l.strip().endswith(f'/* {name} in Sources */,') for l in ref_lines),
                        f'{name} is in a Sources build phase')

    # The attachment file-card view must not reintroduce a silent failure guard.
    media = read(IOS / 'Views/Chat/MinisMediaViews.swift')
    checks += check('guard let url = URL(string: meta.minisURL)' in media,
                    'thumbnail loader still guards URL construction (now fed an ASCII URL)')

    return checks


def run_swift_test():
    swiftc = shutil.which('swiftc')
    if not swiftc:
        print('ATTACHMENT_URL_FAIL swiftc not available')
        return None
    BUILD.mkdir(parents=True, exist_ok=True)
    binary = BUILD / 'attachment-url-tests'
    cmd = [swiftc, '-O', str(URL_HELPER), str(XML_HELPER), str(DECODER), str(TEST_MAIN), '-o', str(binary)]
    compiled = subprocess.run(cmd, capture_output=True, text=True)
    (BUILD / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode != 0:
        print('ATTACHMENT_URL_FAIL compile')
        print(compiled.stderr[-4000:])
        return None
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    out = ran.stdout + ran.stderr
    (BUILD / 'result.log').write_text(out)
    sys.stdout.write(out)
    if ran.returncode != 0:
        print('ATTACHMENT_URL_FAIL run')
        return None
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()

    http_ok = True
    if not args.source_only:
        out = run_swift_test()
        if out is None:
            sys.exit(1)
        url_checks = [int(n) for n in re.findall(r'ATTACHMENT_URL_PASS checks=(\d+)', out)]
        xml_checks = [int(n) for n in re.findall(r'ATTACHMENT_XML_PASS checks=(\d+)', out)]
        url_ok = bool(url_checks) and max(url_checks) >= MIN_URL_CHECKS and 'ATTACHMENT_URL_FAIL' not in out
        xml_ok = bool(xml_checks) and max(xml_checks) >= MIN_XML_CHECKS and 'ATTACHMENT_XML_FAIL' not in out
        if not url_ok:
            print('ATTACHMENT_URL_FAIL url_checks=%s min=%d' % (url_checks, MIN_URL_CHECKS))
        if not xml_ok:
            print('ATTACHMENT_XML_FAIL xml_checks=%s min=%d' % (xml_checks, MIN_XML_CHECKS))
        http_ok = url_ok and xml_ok
        url_count = max(url_checks) if url_checks else 0
        xml_count = max(xml_checks) if xml_checks else 0
    else:
        url_count = 0
        xml_count = 0

    # The incremental scope must treat project.pbxproj as an exception ONLY for the
    # exact 8 registration lines; prove the predicate itself rejects look-alikes.
    scope_selftest = subprocess.run([sys.executable, str(ROOT / 'scripts' / 'ci_validation_scope.py'),
                                     '--self-test-pbxproj'], capture_output=True, text=True)
    sys.stdout.write(scope_selftest.stdout)
    selftest_ok = 'PBXPROJ_PREDICATE_SELFTEST_OK' in scope_selftest.stdout

    source_count = source_checks()
    if selftest_ok:
        source_count += 1
    else:
        failures.append('pbxproj registration predicate self-test failed')
    source_ok = source_count >= MIN_SOURCE_CHECKS
    if not source_ok:
        print('ATTACHMENT_SOURCE_FAIL checks=%d min=%d' % (source_count, MIN_SOURCE_CHECKS))

    if args.source_only:
        print('ATTACHMENT_SOURCE_PASS checks=%d' % source_count)
        if not source_ok:
            sys.exit(1)
        print('ATTACHMENT_URL_XML_SOURCE_ONLY checks=%d' % source_count)
        return

    if not (http_ok and source_ok):
        if failures:
            for f in failures:
                print('  - ' + f)
        sys.exit(1)

    print('ATTACHMENT_SOURCE_PASS checks=%d' % source_count)
    print('ATTACHMENT_URL_XML_PASS url_checks=%d xml_checks=%d source_checks=%d'
          % (url_count, xml_count, source_count))


if __name__ == '__main__':
    main()
