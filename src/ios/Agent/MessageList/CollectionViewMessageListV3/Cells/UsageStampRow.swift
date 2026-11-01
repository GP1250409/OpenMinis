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
//  space runs out, the usage capsule truncates its tail ("…") instead, and
//  tapping it shows the full usage on the line (stamp hidden) until tapped
//  again.
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
///
/// When the usage capsule has to truncate, tapping it swaps the row to the
/// full usage on its own (the stamp steps aside); tapping again brings the
/// stamp back. The row stays one line in both states, so the footer height
/// never changes and no re-measure is needed.
struct UsageStampRow<Usage: View>: View {
    let stamp: CompletionStampParts?
    let contentVisible: Bool
    @ViewBuilder let usage: () -> Usage
    @State private var expanded: Bool

    init(stamp: CompletionStampParts?, contentVisible: Bool, expanded: Bool = false,
         @ViewBuilder usage: @escaping () -> Usage) {
        self.stamp = stamp
        self.contentVisible = contentVisible
        self.usage = usage
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        if let stamp, !expanded {
            // Full usage beside the stamp when it fits (no tap needed);
            // otherwise the tail-truncated usage, tappable to expand.
            ViewThatFits(in: .horizontal) {
                row { usage().fixedSize() } stamp: { stampCapsule(stamp) }
                row {
                    usage()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Show full usage"))
                } stamp: { stampCapsule(stamp) }
            }
        } else if stamp != nil {
            // Expanded: full usage alone on the line. On very narrow widths
            // it scales down a little rather than wrapping.
            row {
                usage()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Show time"))
            } stamp: { EmptyView() }
        } else {
            row { usage().lineLimit(1).truncationMode(.tail) } stamp: { EmptyView() }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
    }

    private func row<U: View, S: View>(@ViewBuilder _ left: () -> U,
                                       @ViewBuilder stamp: () -> S) -> some View {
        HStack(spacing: 6) {
            left()
            Spacer(minLength: 0)
            stamp()
        }
    }

    private func stampCapsule(_ stamp: CompletionStampParts) -> some View {
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

