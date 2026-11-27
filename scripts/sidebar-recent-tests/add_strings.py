#!/usr/bin/env python3
"""Insert the [T-sidebar-recent-section] catalog entries into Localizable.xcstrings.

Textual insertion on purpose: a json round-trip reorders/reformats the whole
7.6 MB catalog. The new entries are appended right after the "Auto-Grouping"
entry (JSON object order is not meaningful to the compiler).
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / 'src/ios/Localizable.xcstrings'
ANCHOR = '    "Auto-Grouping" : {'

FOOTER_EN = ("Unread, running and recently active conversations also appear at the "
             "top of the list and stay in their original position. Read ones stay "
             "there, dimmed, until one hour after their last activity. This section "
             "appears only when pinned conversations and groups together exceed four.")
FOOTER_ZH_HANS = ("未读、正在运行以及最近 1 小时内活跃过的对话也会显示在列表顶部，同时保留在原来的位置。"
                  "已读的对话会变暗留在那里，直到最后一次活跃的 1 小时后。"
                  "只有置顶对话和分组合计超过 4 个时才会显示这个分区。")
FOOTER_ZH_HANT = ("未讀、正在執行以及最近 1 小時內活躍過的對話也會顯示在列表頂部，同時保留在原來的位置。"
                  "已讀的對話會變暗留在那裡，直到最後一次活躍的 1 小時後。"
                  "只有置頂對話和分組合計超過 4 個時才會顯示這個分區。")

ENTRIES = [
    ("Show Recent Section", [("en", "Show Recent Section"),
                             ("zh-Hans", "显示最近分区"),
                             ("zh-Hant", "顯示最近分區")]),
    ("Recent Section Chats", [("en", "Recent Section Chats"),
                              ("zh-Hans", "最近分区条数"),
                              ("zh-Hant", "最近分區條數")]),
    (FOOTER_EN, [("en", FOOTER_EN),
                 ("zh-Hans", FOOTER_ZH_HANS),
                 ("zh-Hant", FOOTER_ZH_HANT)]),
    # [T-sidebar-recent-unread-badge] The 最近 header's "全部已读" control.
    # Official wording (zh-Hans) is verbatim from the reference screenshot.
    ("Mark All as Read", [("en", "Mark All as Read"),
                          ("zh-Hans", "全部已读"),
                          ("zh-Hant", "全部已讀")]),
]


def entry_text(key, langs):
    out = ['    %s : {' % json.dumps(key, ensure_ascii=False), '      "localizations" : {']
    for index, (lang, value) in enumerate(langs):
        out += ['        %s : {' % json.dumps(lang),
                '          "stringUnit" : {',
                '            "state" : "translated",',
                '            "value" : %s' % json.dumps(value, ensure_ascii=False),
                '          }',
                '        }' + (',' if index < len(langs) - 1 else '')]
    out += ['      }', '    },']
    return '\n'.join(out) + '\n'


def main():
    raw = CATALOG.read_text(encoding='utf-8')
    catalog = json.loads(raw)['strings']
    missing = [k for k, _ in ENTRIES if k not in catalog]
    if not missing:
        print('STRINGS_ALREADY_PRESENT count=%d' % len(ENTRIES))
        return 0
    anchor = raw.index(ANCHOR)
    end = raw.index('\n    },\n', anchor) + len('\n    },\n')
    fresh = [(k, v) for k, v in ENTRIES if k in missing]
    raw = raw[:end] + ''.join(entry_text(k, v) for k, v in fresh) + raw[end:]
    CATALOG.write_text(raw, encoding='utf-8')
    # Re-parse the whole catalog: a broken edit here would break every build.
    parsed = json.loads(CATALOG.read_text(encoding='utf-8'))['strings']
    for key, langs in ENTRIES:
        got = parsed.get(key)
        assert got, 'missing key after insert: %r' % key
        locs = got.get('localizations', {})
        for lang, value in langs:
            assert locs.get(lang, {}).get('stringUnit', {}).get('value') == value, (key, lang)
    assert parsed['Recent']['localizations']['zh-Hans']['stringUnit']['value'] == '最近'
    print('STRINGS_INSERTED count=%d total=%d' % (len(fresh), len(parsed)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
