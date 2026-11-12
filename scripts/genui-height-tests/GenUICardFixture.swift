import SwiftUI

// MARK: - Fixture: the show_ui card's real SwiftUI geometry

/// The values a Minis UI Lang program binds to. `json` mirrors the production
/// `block.genuiStateJSON` payload (the card's state, never view @State).
struct GenUICardState: Equatable {
    var choice: String = ""
    var feedback: String = ""
    var segmented: String = "月"
    var slider: Double = 30
    /// A long program: pushes the card's top off-screen so a tap happens on a
    /// card whose top the user can no longer see.
    var long: Bool = false
    var json: String {
        "{\"choice\":\"\(choice)\",\"feedback\":\"\(feedback)\",\"segmented\":\"\(segmented)\",\"slider\":\(Int(slider))}"
    }
    /// Distinguishes content keys exactly like production (genui key includes
    /// the state hash), so a state change never hits the old measured memo.
    var contentHash: String { "\(choice)|\(feedback)|\(segmented)|\(Int(slider))|\(long)" }
}

/// A quiz card with the production card geometry: 12pt padding, 2pt vertical
/// outer padding, 10pt stack gap, one 36pt row per Choice option, an optional
/// verdict Callout (this is what makes a quiz card grow), a fixed-height
/// Segmented row and a slider block. Only the Minis UI Lang renderer is
/// replaced by this view; heights still come from real SwiftUI layout.
struct GenUICardFixture: View {
    let state: GenUICardState
    let options: [String]

    static let longText: String = {
        var s = ""
        for i in 0..<26 {
            s += "第\(i + 1)题：这是一段用来把卡片撑长的题干，用来复现长卡片顶部已离屏时点击下方选项的场景。\n"
        }
        return s
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.long {
                Text(Self.longText)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("小测")
                .font(.system(size: 15, weight: .semibold))
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                HStack(spacing: 8) {
                    Text(option).font(.system(size: 14))
                    Spacer(minLength: 0)
                    if state.choice == option {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            }
            if !state.feedback.isEmpty {
                Text(state.feedback)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
            }
            HStack(spacing: 6) {
                ForEach(["月", "年"], id: \.self) { option in
                    Text(option)
                        .font(.system(size: 13, weight: state.segmented == option ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(state.segmented == option ? Color.accentColor.opacity(0.18) : Color.clear))
                }
            }
            .frame(height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("金额").font(.system(size: 12))
                    Spacer(minLength: 0)
                    Text("\(Int(state.slider))").font(.system(size: 12, design: .monospaced))
                }
                Slider(value: .constant(state.slider), in: 0...100).frame(height: 28)
            }
        }
        .padding(12)
        // Production card root: full width, top aligned, 2pt outer padding.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// Ordinary answer / user row so content exists above AND below the card.
struct GenUIFillerRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 90, alignment: .topLeading)
    }
}
