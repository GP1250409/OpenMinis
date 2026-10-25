//
//  ChatColors.swift
//  Minis - chat page (AIChatView)
//
//  ChatColors: the chat UI's color palette (system colors, light / dark).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Color Palette (clean light theme)

// MARK: - Chat Themes
//
// A theme is a small palette of light/dark colour pairs. `ChatColors` reads the
// selected theme, so every existing `ChatColors.xxx` call site follows it with
// no changes. "system" keeps the original iOS semantic colours.

private extension UIColor {
    convenience init(chatHex v: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

struct ChatThemePair: @unchecked Sendable {
    let light: UIColor
    let dark: UIColor
    /// Built ONCE. A computed property here made every `body` pass (and every
    /// frame of the typing-dots animation) create a fresh dynamic UIColor, which
    /// SwiftUI sees as a changed value and re-lays-out.
    let uiColor: UIColor
    let color: Color
    init(_ l: UInt32, _ d: UInt32, la: CGFloat = 1, da: CGFloat = 1) {
        let lc = UIColor(chatHex: l, alpha: la), dc = UIColor(chatHex: d, alpha: da)
        light = lc; dark = dc
        let ui = UIColor { $0.userInterfaceStyle == .dark ? dc : lc }
        uiColor = ui
        color = Color(ui)
    }
}

struct ChatTheme: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let background, secondaryBg, inputIconBorder, inputBg, inputBorder: ChatThemePair
    let primaryText, secondaryText, tertiaryText: ChatThemePair
    let userBubble, toolBg, toolBorder, accent, sendButton, sendButtonDisabled: ChatThemePair
    /// Markdown surfaces: fenced code block, inline code, table border.
    let codeBg, codeText, inlineCodeBg, inlineCodeText, tableBorder: ChatThemePair

    // Codex: Catppuccin Latte (day) / Mocha (night) — Codex's default theme.
    static let codex = ChatTheme(
        id: "codex", name: "Codex",
        background: .init(0xEFF1F5, 0x1E1E2E), secondaryBg: .init(0xE6E9EF, 0x181825),
        inputIconBorder: .init(0xCCD0DA, 0x45475A), inputBg: .init(0xFFFFFF, 0x313244),
        inputBorder: .init(0xCCD0DA, 0x45475A),
        primaryText: .init(0x4C4F69, 0xCDD6F4), secondaryText: .init(0x6C6F85, 0xA6ADC8),
        tertiaryText: .init(0x9CA0B0, 0x6C7086),
        userBubble: .init(0xDCE0E8, 0x313244), toolBg: .init(0xE6E9EF, 0x181825),
        toolBorder: .init(0xCCD0DA, 0x45475A),
        accent: .init(0x8839EF, 0xCBA6F7), sendButton: .init(0x8839EF, 0xCBA6F7),
        sendButtonDisabled: .init(0xBCC0CC, 0x45475A),
        codeBg: .init(0xE6E9EF, 0x11111B), codeText: .init(0x4C4F69, 0xCDD6F4),
        inlineCodeBg: .init(0xDCE0E8, 0x313244), inlineCodeText: .init(0x8839EF, 0xCBA6F7),
        tableBorder: .init(0xCCD0DA, 0x45475A))

    // Claude Code: colours from the CLI's own `dark` / `light` theme tables
    // (text, accent 0xD77757 day / 0xFF9933 night, user message 0xF0F0F0 / 0x373737).
    static let claudeCode = ChatTheme(
        id: "claudecode", name: "Claude Code",
        background: .init(0xFFFFFF, 0x000000), secondaryBg: .init(0xF0F0F0, 0x1A1A1A),
        inputIconBorder: .init(0xD4D4D4, 0x3A3A3A), inputBg: .init(0xFFFFFF, 0x000000),
        inputBorder: .init(0xD4D4D4, 0x3A3A3A),
        primaryText: .init(0x000000, 0xFFFFFF), secondaryText: .init(0x666666, 0x999999),
        tertiaryText: .init(0xAFAFAF, 0x505050),
        userBubble: .init(0xF0F0F0, 0x373737), toolBg: .init(0xF0F0F0, 0x1A1A1A),
        toolBorder: .init(0xD4D4D4, 0x3A3A3A),
        accent: .init(0xD77757, 0xFF9933), sendButton: .init(0xD77757, 0xFF9933),
        sendButtonDisabled: .init(0xD4D4D4, 0x3A3A3A),
        codeBg: .init(0xF0F0F0, 0x1A1A1A), codeText: .init(0x000000, 0xFFFFFF),
        inlineCodeBg: .init(0xF0F0F0, 0x373737), inlineCodeText: .init(0xD77757, 0xFF9933),
        tableBorder: .init(0xD4D4D4, 0x3A3A3A))

    // ChatGPT: neutral white / graphite.
    static let chatgpt = ChatTheme(
        id: "chatgpt", name: "ChatGPT",
        background: .init(0xFFFFFF, 0x212121), secondaryBg: .init(0xF7F7F8, 0x2A2A2A),
        inputIconBorder: .init(0xE5E5E5, 0x3A3A3A), inputBg: .init(0xFFFFFF, 0x303030),
        inputBorder: .init(0xE5E5E5, 0x3A3A3A),
        primaryText: .init(0x0D0D0D, 0xECECEC), secondaryText: .init(0x5D5D5D, 0xB4B4B4),
        tertiaryText: .init(0x8F8F8F, 0x8E8E8E),
        userBubble: .init(0xF4F4F4, 0x303030), toolBg: .init(0xF7F7F8, 0x2A2A2A),
        toolBorder: .init(0xE5E5E5, 0x3A3A3A),
        accent: .init(0x0D0D0D, 0xECECEC), sendButton: .init(0x0D0D0D, 0xECECEC),
        sendButtonDisabled: .init(0xD7D7D7, 0x4A4A4A),
        codeBg: .init(0xF9F9F9, 0x171717), codeText: .init(0x0D0D0D, 0xECECEC),
        inlineCodeBg: .init(0xF0F0F0, 0x171717), inlineCodeText: .init(0x0D0D0D, 0xECECEC),
        tableBorder: .init(0xE5E5E5, 0x3A3A3A))

    // Claude (claude.ai): warm paper, clay accent.
    static let claude = ChatTheme(
        id: "claude", name: "Claude",
        background: .init(0xFAF9F5, 0x262624), secondaryBg: .init(0xF0EEE6, 0x30302E),
        inputIconBorder: .init(0xE3E0D3, 0x43423F), inputBg: .init(0xFFFFFF, 0x30302E),
        inputBorder: .init(0xE3E0D3, 0x43423F),
        primaryText: .init(0x141413, 0xF4F3EE), secondaryText: .init(0x73726C, 0xB0AEA5),
        tertiaryText: .init(0xA3A199, 0x7D7B74),
        userBubble: .init(0xEFE9DE, 0x3A3937), toolBg: .init(0xF0EEE6, 0x30302E),
        toolBorder: .init(0xE3E0D3, 0x43423F),
        accent: .init(0xD97757, 0xD97757), sendButton: .init(0xD97757, 0xD97757),
        sendButtonDisabled: .init(0xDDD9CB, 0x43423F),
        codeBg: .init(0xF0EEE6, 0x1F1E1D), codeText: .init(0x3D3929, 0xE6E3D8),
        inlineCodeBg: .init(0xEDE9DD, 0x3A3937), inlineCodeText: .init(0xB8532F, 0xE8956F),
        tableBorder: .init(0xE3E0D3, 0x43423F))

    // DeepSeek: white / graphite with the blue brand accent.
    static let deepseek = ChatTheme(
        id: "deepseek", name: "DeepSeek",
        background: .init(0xFFFFFF, 0x1E1F22), secondaryBg: .init(0xF6F7FA, 0x28292D),
        inputIconBorder: .init(0xE3E6EC, 0x3A3C41), inputBg: .init(0xF4F6FA, 0x2A2B2F),
        inputBorder: .init(0xE3E6EC, 0x3A3C41),
        primaryText: .init(0x0F1115, 0xE8EAED), secondaryText: .init(0x5B6270, 0xA0A5B0),
        tertiaryText: .init(0x9AA1AE, 0x6F7480),
        userBubble: .init(0xEBF0FF, 0x2D3A63), toolBg: .init(0xF6F7FA, 0x28292D),
        toolBorder: .init(0xE3E6EC, 0x3A3C41),
        accent: .init(0x4D6BFE, 0x4D6BFE), sendButton: .init(0x4D6BFE, 0x4D6BFE),
        sendButtonDisabled: .init(0xC9D1F5, 0x3A3C41),
        codeBg: .init(0xF6F7FA, 0x161719), codeText: .init(0x1F2430, 0xE8EAED),
        inlineCodeBg: .init(0xEEF1F7, 0x2B2D33), inlineCodeText: .init(0x4D6BFE, 0x8EA2FF),
        tableBorder: .init(0xE3E6EC, 0x3A3C41))

    static let custom: [ChatTheme] = [.codex, .claudeCode, .chatgpt, .claude, .deepseek]
}

enum ChatThemeStore {
    static let key = "chatThemeId"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedId: String? = UserDefaults.standard.string(forKey: key)
    nonisolated(unsafe) private static var observer: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            let v = UserDefaults.standard.string(forKey: ChatThemeStore.key)
            ChatThemeStore.lock.lock()
            let changed = ChatThemeStore.cachedId != v
            ChatThemeStore.cachedId = v
            ChatThemeStore.lock.unlock()
            if changed {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .chatThemeChanged, object: nil) }
            }
        }
    }()
    /// Called by the settings picker right after writing the preference, so the
    /// cache is already current when SwiftUI re-renders (the UserDefaults
    /// notification alone can arrive after the first redraw).
    static func select(_ id: String) {
        _ = observer
        UserDefaults.standard.set(id, forKey: key)
        lock.lock()
        let changed = cachedId != id
        cachedId = id
        lock.unlock()
        if changed { NotificationCenter.default.post(name: .chatThemeChanged, object: nil) }
    }
    /// nil = "Default Theme" (original iOS semantic colours). Reads a cached id
    /// (refreshed on UserDefaults changes) so per-frame colour lookups never hit
    /// the preferences store.
    static var current: ChatTheme? {
        _ = observer
        lock.lock(); let id = cachedId; lock.unlock()
        guard let id, !id.isEmpty else { return nil }
        return ChatTheme.custom.first { $0.id == id }
    }
}

enum ChatColors {
    private static func pick(_ f: (ChatTheme) -> ChatThemePair, _ fallback: Color) -> Color {
        ChatThemeStore.current.map { f($0).color } ?? fallback
    }
    static var background: Color { pick({ $0.background }, Color(UIColor.systemBackground)) }
    static var secondaryBg: Color { pick({ $0.secondaryBg }, Color(UIColor.secondarySystemBackground)) }
    static var inputIconBg: Color { pick({ $0.secondaryBg }, Color(UIColor.secondarySystemBackground)) }
    static var inputIconBorder: Color {
        pick({ $0.inputIconBorder }, Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1) : UIColor(white: 0, alpha: 0) }))
    }
    static var inputBg: Color {
        pick({ $0.inputBg }, Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : .white }))
    }
    static var inputBorder: Color { pick({ $0.inputBorder }, Color(UIColor.separator)) }
    static var primaryText: Color { pick({ $0.primaryText }, Color(UIColor.label)) }
    static var secondaryText: Color { pick({ $0.secondaryText }, Color(UIColor.secondaryLabel)) }
    static var tertiaryText: Color { pick({ $0.tertiaryText }, Color(UIColor.tertiaryLabel)) }
    static var userBubble: Color { pick({ $0.userBubble }, Color(UIColor.tertiarySystemFill)) }
    static var toolBg: Color { pick({ $0.toolBg }, Color(UIColor.tertiarySystemGroupedBackground)) }
    static var toolBorder: Color { pick({ $0.toolBorder }, Color(UIColor.separator).opacity(0.5)) }
    static var accent: Color { pick({ $0.accent }, Color(UIColor.label)) }
    static var sendButton: Color { pick({ $0.sendButton }, Color(UIColor.label)) }
    static var sendButtonDisabled: Color { pick({ $0.sendButtonDisabled }, Color(UIColor.quaternaryLabel)) }
}

/// UIKit-side colours for the Markdown renderer. `nil` = keep the renderer's
/// original (system) colour, so the Default Theme is pixel-identical to before.
enum ChatMarkdownColors {
    static var label: UIColor? { ChatThemeStore.current?.primaryText.uiColor }
    static var secondaryLabel: UIColor? { ChatThemeStore.current?.secondaryText.uiColor }
    static var accent: UIColor? { ChatThemeStore.current?.accent.uiColor }
    static var codeBackground: UIColor? { ChatThemeStore.current?.codeBg.uiColor }
    static var codeText: UIColor? { ChatThemeStore.current?.codeText.uiColor }
    static var inlineCodeBackground: UIColor? { ChatThemeStore.current?.inlineCodeBg.uiColor }
    static var inlineCodeText: UIColor? { ChatThemeStore.current?.inlineCodeText.uiColor }
    static var tableBorder: UIColor? { ChatThemeStore.current?.tableBorder.uiColor }
}

extension Notification.Name {
    /// Posted when the chat theme changes so UIKit cells re-render.
    static let chatThemeChanged = Notification.Name("minis.chatThemeChanged")
}
