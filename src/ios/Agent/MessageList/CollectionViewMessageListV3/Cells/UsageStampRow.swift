//
//  UsageStampRow.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [MOD] The assistant footer's usage row: usage capsule on the left, the
//  completion stamp on the far right. Hosted by BridgedAssistantFooterV3.
//
//  Stamp rules:
//  - today:      "11:08"
//  - not today:  "10/24 Fri 11:08"
//  The stamp is always shown in full on one line. The row never wraps: when
//  space runs out, the usage capsule truncates its tail ("…") instead.
//

import SwiftUI

/// [MOD] Text parts of the completion stamp. Locale-pinned (`en_US_POSIX`) so
/// a 12-hour region still gets 24-hour HH:mm and the weekday is always the
/// English three-letter form ("Fri"), matching the capsule's ASCII metrics.
struct CompletionStampParts: Equatable {
    /// "11:08"
    let clock: String
    /// "10/24 Fri" — nil when the reply landed today.
    let day: String?

    init(_ date: Date, calendar: Calendar = .current, now: Date = Date()) {
        clock = Self.clockFormatter.string(from: date)
        day = calendar.isDate(date, inSameDayAs: now)
            ? nil
            : Self.dayFormatter.string(from: date)
    }

    /// "10/24 Fri 11:08", or "11:08" for today.
    var singleLine: String { day.map { "\($0) \(clock)" } ?? clock }

    /// Static so the DateFormatter alloc is not paid per message per render.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd EEE"
        return f
    }()
}

/// [MOD] Usage capsule + right-aligned completion stamp, always one line.
struct UsageStampRow<Usage: View>: View {
    let stamp: CompletionStampParts?
    let contentVisible: Bool
    @ViewBuilder let usage: () -> Usage

    var body: some View {
        HStack(spacing: 6) {
            // Takes whatever the stamp leaves; one line, tail-truncated.
            usage()
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let stamp {
                Text(stamp.singleLine)
                    .lineLimit(1)
                    .font(.system(size: 10, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(ChatColors.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ChatColors.userBubble.opacity(0.6))
                    .clipShape(Capsule())
                    .opacity(contentVisible ? 1 : 0)
                    .layoutPriority(1)
            }
        }
    }
}
