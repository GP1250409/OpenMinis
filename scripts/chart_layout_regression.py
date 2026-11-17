#!/usr/bin/env python3
"""Chart layout / emphasis regression (real Swift, no simulator needed).

Two modes:

  python3 scripts/chart_layout_regression.py --source-only
      Static contract audit only. Runs anywhere (Linux preflight); it never
      claims the Swift suite ran.

  python3 scripts/chart_layout_regression.py [--swiftc PATH]
      Static audit + compiles the production file
      src/ios/Views/Chat/AIChatView/MinisUI/MinisUICore.swift together with
      scripts/chart-layout-tests/main.swift and runs it.

What it protects (all three were reported from a device with a 三国 GDP line
chart): the highlighted series must take a fixed accent colour no matter which
row it sits on; end-of-line labels must stay out of the right-hand axis numbers;
labels of lines with close end values must not overlap. It also checks that the
show_ui prompt still carries the charting rules, so the model guidance cannot be
dropped silently.

Prints `CHART_LAYOUT_PASS checks=<n>` on success.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
core = root / 'src/ios/Views/Chat/AIChatView/MinisUI/MinisUICore.swift'
view = root / 'src/ios/Views/Chat/AIChatView/MinisUI/MinisUIView.swift'
prompt = root / 'src/ios/Views/Chat/AIChatView/MinisUI/AIChatViewModel+GenUI.swift'
tests = root / 'scripts/chart-layout-tests/main.swift'

source_only = '--source-only' in sys.argv[1:]
swiftc = shutil.which('swiftc')
if '--swiftc' in sys.argv[1:]:
    swiftc = sys.argv[sys.argv.index('--swiftc') + 1]

failures = []
static_passed = 0


def need(cond, msg):
    global static_passed
    if cond:
        static_passed += 1
        print('SOURCE_CHECK_OK: ' + msg, flush=True)
    else:
        failures.append(msg)
        print('SOURCE_CHECK_FAILED: ' + msg, flush=True)


core_text = core.read_text()
view_text = view.read_text()
prompt_text = prompt.read_text()

# --- the shared resolver lives in the pure file -----------------------------
need('enum MUChartEmphasis' in core_text, 'MUChartEmphasis is defined in the pure core file')
need('static func roles(series: [String], highlight: [String]) -> [MUChartRole]' in core_text,
     'highlight roles are resolved by one pure function')
need('enum MUChartEndLabels' in core_text and 'static func layout(values: [Double]' in core_text,
     'end-label placement is a pure function of values + domain + height')
need('enum MUChartLabelMetrics' in core_text and 'static func gutter(labels: [String]' in core_text,
     'the trailing gutter is computed from the label texts and the card width')
need('import Foundation' in core_text and 'import SwiftUI' not in core_text and 'import UIKit' not in core_text,
     'the layout rules stay SwiftUI-free (they run on a plain Swift toolchain)')

# --- the view only maps results, never re-decides ---------------------------
need('MUChartEmphasis.roles(series: series, highlight: highlight)' in view_text,
     'the view asks the shared resolver for the roles')
need('MUChartEndLabels.layout(values: lastValues, domain: domain' in view_text,
     'the view uses the computed label placement')
need('MUChartColumns.layout(width: width, labelWidth: gutter.labelWidth,' in view_text,
     'the view uses the owned columns instead of Charts axis layout')
# [T-chart-label-physical] Build 8ec8992 still put "中国" on the axis "5": the
# gutter was an estimate and the labels were mark annotations, which Charts may
# place outside the plot area. Both halves of the fix are pinned here.
need('widths: labelWidths' in view_text and 'MUStyle.textWidth(' in view_text,
     'the gutter is sized from the MEASURED width of the labels, not from an estimate')
need('.annotation(position: .trailing' not in view_text,
     'end labels are no longer mark annotations (they could overflow into the axis)')
need('plot.padding(.trailing' not in view_text and '.chartYAxis(.hidden)' in view_text,
     'native y labels and the misplaced trailing padding are both removed')
need('max(lastX + 3' not in view_text and 'columns.axisMinX - columns.plotMinX' in view_text,
     'label and axis x positions are exclusively owned by the pure columns')
need('static let innerInset: CGFloat = 10' in core_text and 'static let axisGap: CGFloat = 6' in core_text,
     'one shared 10pt inset and at least 6pt between the text columns')
need('struct MUChartTheme' in view_text and 'static func current(for value: String)' in view_text,
     'all chart types resolve one complete theme preset')
need('series.count > 1 && !showEndLabels' in view_text,
     'end labels automatically hide the duplicate legend')
need('MUChartTypography.estimatedHeight' in core_text,
     'height estimates share the typography and row contract')
need('0xFFFFFF, dark: 0x161B1F' in view_text and 'theme.topRule' in view_text,
     '2017 web theme uses white ground plus top rule, with adapted dark ground')
need('let fonts: MUChartFontScale = .phone' in view_text and 'theme.fonts.subtitle' in view_text,
     'each complete theme exposes the shared phone typography scale')
need('if !framed, !unit.isEmpty' in view_text,
     'single-series units remain visible inside the existing axis headroom')
need('.position(x: box.midX, y: box.midY)' in view_text and 'y: y - 7, width: columns.axisWidth, height: 14' in view_text,
     'axis digit box center equals the corresponding real grid coordinate')
need('y: y - 1.5 - 7' not in view_text and 'axisBoxes: axisBoxes.map' in view_text,
     'the old optical/top-edge shift is removed and the rendered box is observable')
need('MUChartRenderGeometryKey' in view_text,
     'actual ChartProxy geometry is exposed to the real rendering fixture')
need('.chartOverlay { proxy in' in view_text and 'proxy.plotAreaFrame' in view_text,
     'the labels are drawn inside the real plot frame (ChartProxy.plotAreaFrame)')
need('proxy.position(forY:' in view_text and 'baseY: baseY' in view_text,
     'the label y is the REAL mark position, not a recomputed pixel')
# [T-card-surface] Outer Card remains; chart/map interior receives actual surface.
need('static func retainsOuterSurface' in core_text,
     'all Cards retain their outer plane regardless of chart content')
need('MUCardPlane.isChartOnly(comp)' not in view_text and 'flat ? Color.clear' not in view_text,
     'legacy chart classifier cannot make the outer Card transparent')
map_view_text = (view.parent / 'MinisUIMapView.swift').read_text()
need('.modifier(MUCardSurface(fill: topLevel ? ChatColors.secondaryBg : Color.primary.opacity(0.04),' in view_text
     and 'nativeFill: topLevel ? ChatColors.secondaryBgUIColor : UIColor.label.withAlphaComponent(0.04)' in view_text,
     'Card preserves theme fill and nested 4% alpha through explicit native tokens')
need('MUSurface.rgb($0, over: parent, scheme: scheme)' in map_view_text
     and '.environment(\\.muSurface, surface)' in map_view_text
     and '.fill(surface.color)' in map_view_text,
     'painted Card fill and descendant surface consume the same opaque composite')
need('RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)' in map_view_text
     and 'Color.primary.opacity(bordered ? 0.08 : 0)' in map_view_text,
     'shared Card surface preserves configurable rounded corners and border')
need('.background(framed ? theme.panel' not in view_text and 'on: surface, scheme: scheme)' in view_text,
     'chart interior is transparent and foregrounds consume the composited surface')
need('.modifier(MURootSurface())' in view_text and 'MUSurface.rgb(ChatColors.background' in (view.parent / 'MinisUIMapView.swift').read_text(),
     'standalone output inherits the actual chat theme background')
need('.chartYScale(domain: domain.lower...domain.upper, range: .plotDimension(startPadding: 0, endPadding: 0))' in view_text,
     'the y domain is explicit, so a value\'s pixel position is exact')
need('plot.padding(.trailing, kind == "line" && hasSeriesHighlight ? 22 : 0)' not in view_text,
     'the old hard-coded 22pt trailing padding is gone')
need('private var chartHeight: CGFloat' in view_text
     and 'envChartPlotHeight' in view_text
     and 'h.isFinite, h > 0' in view_text
     and 'return 180' in view_text,
     'the plot defaults to 180pt height with finite positive environment override')
need(view_text.count('palette[s % palette.count]') == 1 and 'MUChartEmphasis.styles(' in view_text,
     'the palette is indexed in exactly one place (behind the pure style resolver)')
need('GeometryReader' in view_text and '.frame(height: chartHeight + MUChartTypography.xAxisHeight + MUChartTypography.plotTop)' in view_text,
     'the width comes from a fixed-height GeometryReader, not from a guessed constant')
for symbol in ['MUChartStyle.accent2017', 'MUChartStyle.accentRecent', 'MUChartStyle.accentSystem']:
    need(symbol in view_text, symbol + ' is defined for the accent ramp')
need('enum MUChartPaletteTokens' in core_text and 'static func styles(' in core_text,
     'palette tokens and non-colliding style allocator live in pure Foundation core')
need('light: 0xA81829' in core_text, '2017 dark red stand-in #A81829 is preserved unchanged')
need('MUChartEmphasis.styles(' in view_text and 'forLabel: true' in view_text,
     'view consumes pure style allocator and separates 4.5:1 end-label text adaptation')
need('surface.luminance < 0.179' in view_text and 'seriesLabels: series.map(text)' in view_text,
     'theme adaptation resolves light/dark from actual surface and separates text vs graphic contrast')

# --- [T-chart-x-axis] the x tick boxes are PLACED, not stacked --------------
need('enum MUChartXAxisLabels' in core_text and 'static func layout(centers: [CGFloat]' in core_text,
     'x tick placement is a pure function of real centres + measured widths')
need('plotMinX: frame.minX, plotMaxX: frame.maxX' in view_text,
     'the x tick layout receives the real plot strip')
need('MUChartXAxisLabels.layout(centers: xCenters, widths: xWidths' in view_text,
     'the view hands REAL tick centres and REAL text widths to the x-tick layout')
need('i % max(1, Int(ceil(Double(cols) / 5)))' not in view_text,
     'the old index-stride tick rule (which could not see the text width) is gone')
need('min(44, frame.width / 3)' not in view_text,
     'the fixed 44pt tick box that overlapped its neighbour is gone')
need('UIFont.monospacedDigitSystemFont' in view_text and 'monospacedDigit: true' in view_text,
     'tick width is measured in the monospaced-digit font that is actually drawn')
need('truncationMode(.tail)' in view_text,
     'a shrunk tick box ellipsizes instead of painting over the next label')

# --- [T-chart-interaction-theme] callouts follow the chart card tokens ------
need('enum MUChartInteractionTheme' in core_text,
     'one interaction token set (table + callouts) is defined in the pure core')
need('static func panel(on surface: MUMapRGB)' in core_text
     and 'MUChartInteractionTheme.panel(on:' in view_text,
     'the data table and every callout share one ground token')
need('MUChartInteractionTheme.resolved(tone: tone' in view_text,
     'the callout resolves its colours from the interaction tokens')
callout_body = view_text[view_text.index('private struct MUCallout: View'):]
callout_body = callout_body[:callout_body.index('\n}\n')]
need('ChatColors.' not in callout_body,
     'the callout takes no colour from the chat theme tint')
need('MUChartInteractionTheme.resolved' in callout_body and 'look.accent' in callout_body,
     'the callout paints its icon and leading bar from the semantic chart accent')
theme_block = core_text[core_text.index('enum MUChartInteractionTheme'):]
theme_block = theme_block[:theme_block.index('\n}\n')]
need('ChatColors' not in theme_block,
     'the interaction tokens never read the chat palette')
for symbol in ['static let info = MUChartColorPair', 'static let warning = MUChartColorPair',
               'static let danger = MUChartColorPair', 'static let success = MUChartColorPair']:
    need(symbol in theme_block, symbol.split(' = ')[0] + ' keeps its semantic accent token')

# --- the prompt still teaches the charting rules ---------------------------
for phrase, why in [
    ('Prefer show_ui for an ordinary data chart', 'show_ui is the preferred path for ordinary data charts'),
    ('does not follow the app\'s chart-colour setting', 'a generated image is described as not following the settings'),
    ('Do not invent data or sources', 'no invented data or sources'),
    ('("估算", "示意数据")', 'estimates must be labelled as estimates'),
    ('Time series in time order, oldest first', 'time order is stated'),
    ('at most 4 series where possible', 'series budget is stated'),
    ('No second y-axis, no dashed/forecast styling, no pie/donut', 'MultiChart limits are accurate'),
    ('system: orange bars on blue, Economist recent: red on grey, Economist 2017: cyan on blue',
     'BarChart highlight colours match what the code draws'),
    ('blue appears naturally from 3–4 series onward, with no >6 series gate',
     'prompt drops the old >6 blue gate and documents natural blue usage'),
    ('recent: red → salmon → dark blue', 'prompt documents red/salmon priority accent order'),
    ('retain distinct, non-colliding palette colours', 'prompt documents independent non-highlighted series identity'),
    ('lines are solid by default', 'prompt documents default solid lines'),
    ('no shared-grey background-group mode', 'prompt accurately states background-group mode is unsupported'),
    ('no faceting', 'prompt accurately states faceting is unsupported'),
    ('the others turn grey in the Economist chart style', 'the old, wrong "others turn grey" claim is gone'),
    ('and the other series turn grey', 'the old MultiChart "other series turn grey" claim is gone'),
    ('context greyed via', 'the old Charts rule "context greyed via highlight" claim is gone'),
    ('recent style red → dark red → blue', 'the old accent order claim is gone'),
]:
    if why.startswith('the old'):
        need(phrase not in prompt_text, why)
    else:
        need(phrase in prompt_text, why)

if failures:
    print('CHART_LAYOUT_STATIC_FAILED checks=%d failures=%d' % (static_passed, len(failures)), flush=True)
    sys.exit(1)

if source_only:
    print('CHART_LAYOUT_SOURCE_PASS checks=%d' % static_passed)
    print('NOTE: --source-only audited the sources; the Swift suite did NOT run.')
    sys.exit(0)

if not swiftc:
    print('CHART_LAYOUT_NO_SWIFTC')
    sys.exit(1)

binary = root / 'build/chart-layout/ChartLayoutTests'
binary.parent.mkdir(parents=True, exist_ok=True)
compile_cmd = [swiftc, '-swift-version', '5', str(core), str(core.with_name('MinisUIMapCore.swift')), str(core.with_name('MinisUIMapData.swift')), str(core.with_name('MinisUIMapPack.swift')), str(tests), '-o', str(binary)]
print('COMPILE: swiftc MinisUICore.swift main.swift', flush=True)
proc = subprocess.run(compile_cmd, capture_output=True, text=True)
if proc.returncode != 0:
    print(proc.stdout[-6000:])
    print(proc.stderr[-6000:])
    print('CHART_LAYOUT_COMPILE_FAILED')
    sys.exit(1)

run = subprocess.run([str(binary)], capture_output=True, text=True)
for line in run.stdout.splitlines():
    if line.startswith('PASS:') or line.startswith('FAIL:'):
        print(line, flush=True)
match = re.search(r'CHART_LAYOUT_PASS checks=(\d+)', run.stdout)
if run.returncode != 0 or not match:
    print(run.stdout[-4000:])
    print(run.stderr[-4000:])
    print('CHART_LAYOUT_RUN_FAILED')
    sys.exit(1)
checks = int(match.group(1))
if static_passed < 61:
    print('CHART_LAYOUT_TOO_FEW_SOURCE_CHECKS %d' % static_passed)
    sys.exit(1)
if checks < 1190:
    print('CHART_LAYOUT_TOO_FEW_CHECKS %d' % checks)
    sys.exit(1)
print('CHART_LAYOUT_SOURCE_PASS checks=%d' % static_passed)
print('CHART_LAYOUT_PASS checks=%d' % checks)
