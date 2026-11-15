import AppKit
import SwiftUI

/// Each saved account's color, by its position in the list. Each hue has a
/// deeper tone for light mode and a brighter one for dark mode, so it keeps
/// its color on grey glass. It marks the account's initial, its bars and,
/// when active, its card. Orange and red stay reserved for low limits and
/// warnings.
enum AccountPalette {
    static let colors: [Color] = [
        dynamic(light: 0x4C5BD4, dark: 0x9DA8FF),  // indigo
        dynamic(light: 0x0F8A7E, dark: 0x5FD4C4),  // teal
        dynamic(light: 0xC23F6A, dark: 0xFF9EB8),  // rose
        dynamic(light: 0x7A4FD0, dark: 0xC7A9FF),  // violet
    ]

    /// Text on a solid accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x16161A)

    static func color(_ index: Int) -> Color {
        colors[index % colors.count]
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The panel's content:
///
/// ```
/// Claude Account                          ⟳
/// ╭ (T) Team             new sessions      ╮   active: tinted card
/// │ Session   ━━━━━━━━━━━━━━━━━━━━━   100% │   percent left
/// ╰ Weekly    ━━━━━━━━━━━━━━━━━━━──    92% ╯
/// ╭ (P) Personal                  as of 14:02 ╮
/// ╰ 2 running sessions started before the switch …╯
/// ⚠ warnings, mismatch + Fix ~/.claude.json, notices
/// ⤓ Save current login…
/// ＋ Add account…
/// ⚙ Settings…                       Quit ⌘Q
/// ```
struct MenuPanelView: View {
    static let width: CGFloat = 320

    let rows: [MenuRow]
    let perform: (ActionLine.Action) -> Void
    let switchTo: (String) -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        let blocks = MenuRows.blocks(rows)
        let actions = rows.compactMap { if case .action(let line) = $0 { line } else { nil } }
        VStack(alignment: .leading, spacing: 6) {
            header(title: rows.lazy.compactMap { if case .header(let title) = $0 { title } else { nil } }.first,
                   refresh: actions.first { $0.action == .refresh })
            ForEach(blocks) { block in
                switch block {
                case .card(let card):
                    AccountCardView(card: card) { switchTo(card.account.id) }
                case .row(let row):
                    standalone(row)
                }
            }
            footer(settings: actions.first { $0.action == .settings }, quit: actions.first { $0.action == .quit })
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
    }

    private func header(title: String?, refresh: ActionLine?) -> some View {
        HStack {
            Text(title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let refresh {
                Button { perform(.refresh) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(HoverButtonStyle(radius: 11))
                .disabled(!refresh.enabled)
                .help(refresh.title)
                .accessibilityLabel(refresh.title)
            }
        }
        .padding(.leading, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func standalone(_ row: MenuRow) -> some View {
        switch row {
        case .header, .account, .usage:
            EmptyView()
        case .separator(let id):
            if id != "quit" {
                Divider().opacity(0.6).padding(.horizontal, 6).padding(.vertical, 2)
            }
        case .note(let line):
            if line.style == .warning {
                WarningView(text: line.text)
            } else {
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, line.indented ? 34 : 8)
            }
        case .action(let line):
            if ![.refresh, .settings, .quit].contains(line.action) {
                ActionRowView(line: line) { perform(line.action) }
            }
        }
    }

    private func footer(settings: ActionLine?, quit: ActionLine?) -> some View {
        HStack(spacing: 4) {
            if let settings {
                ActionRowView(line: settings) { perform(.settings) }
                    .keyboardShortcut(",")
            }
            if let quit {
                ActionRowView(line: quit, shortcut: "⌘Q") { perform(.quit) }
                    .keyboardShortcut("q")
                    .fixedSize()
            }
        }
    }
}

// MARK: - Account card

/// An account: initial badge, name, tag, then its notes and usage bars.
/// Clicking an account switches to it; the switch asks first.
struct AccountCardView: View {
    let card: AccountCard
    let onSelect: () -> Void
    @State private var hovering = false

    private var accent: Color { AccountPalette.color(card.index) }
    private var active: Bool { card.account.checked }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                ForEach(card.rows, id: \.key) { row in
                    switch row {
                    case .usage(let line):
                        UsageBarRow(line: line, accent: accent)
                    case .note(let line):
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 30)
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape.fill(fill))
            .overlay(cardShape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(card.account.tooltip ?? (active ? "" : "Switch to \(card.account.label)"))
        .accessibilityLabel([card.account.label, active ? "active" : nil, card.account.tag, card.account.trailing]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(active ? "" : "Switches Claude Code to this account")
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var fill: Color {
        if active { return accent.opacity(hovering ? 0.17 : 0.12) }
        return Color.primary.opacity(hovering ? 0.10 : 0.06)
    }

    private var stroke: Color {
        active ? accent.opacity(0.55) : Color.clear
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            badge
            Text(card.account.label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let tag = card.account.tag {
                TagView(text: tag, color: tag == "unverified" ? .orange : accent)
            }
            Spacer(minLength: 4)
            if card.account.fetching {
                ProgressView().controlSize(.mini)
            } else if let trailing = card.account.trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The initial in a circle: solid when active, a faint wash otherwise.
    private var badge: some View {
        let initial = card.account.label.first.map { String($0).uppercased() } ?? "?"
        return Text(initial)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(active ? AccountPalette.onAccent : accent)
            .frame(width: 22, height: 22)
            .background(Circle().fill(active ? accent : accent.opacity(0.22)))
            .accessibilityHidden(true)
    }
}

struct TagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.2)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// "Weekly · Fable   ━━━━━━━━━━━━──   93%", the percent left. The bar takes
/// the account's color, orange or red when Anthropic flags the limit.
struct UsageBarRow: View {
    let line: UsageLine
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var value: Int { Int(line.remaining.rounded()) }

    private var barColor: Color {
        switch line.severity {
        case .normal: accent
        case .warning: Color.orange.opacity(0.9)
        case .critical: Color.red.opacity(0.9)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(line.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    if line.remaining > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(5, geometry.size.width * line.remaining / 100))
                    }
                }
            }
            .frame(height: 5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: line.remaining)
            Text("\(value)%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.leading, 30)
        .opacity(line.stale ? 0.45 : 1)
        .help(line.tooltip ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.label) \(value) percent left\(line.stale ? ", stale" : "")")
    }
}

// MARK: - Notes and actions

/// A warning: amber triangle on a faint amber wash.
struct WarningView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text.droppingWarningMark)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.22), lineWidth: 1))
    }
}

/// A menu-style row: symbol, title, optional shortcut, hover highlight.
struct ActionRowView: View {
    let line: ActionLine
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(line.action))
                    .font(.system(size: 12))
                    .foregroundStyle(line.action == .resolveUnfinished || line.action == .fixClaudeJSON ? .orange : .secondary)
                    .frame(width: 18)
                Text(line.title.droppingWarningMark)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 8))
        .disabled(!line.enabled)
    }

    static func symbol(_ action: ActionLine.Action) -> String {
        switch action {
        case .cancelSignIn: "xmark.circle"
        case .resolveUnfinished: "exclamationmark.triangle"
        case .fixClaudeJSON: "wrench.and.screwdriver"
        case .saveLogin: "square.and.arrow.down"
        case .addAccount: "person.badge.plus"
        case .refresh: "arrow.clockwise"
        case .settings: "gearshape"
        case .quit: "power"
        }
    }
}

/// A faint rounded highlight under the pointer, darker while pressed.
struct HoverButtonStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.07 : 0))))
                .onHover { hovering = $0 }
        }
    }
}

private extension String {
    /// The panel draws its own warning symbol.
    var droppingWarningMark: String {
        hasPrefix("⚠︎ ") ? String(dropFirst("⚠︎ ".count)) : self
    }
}
