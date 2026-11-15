import Foundation

/// What the menu shows, as plain values. `MenuPanelView` draws the rows
/// in the glass panel; keeping this free of AppKit and SwiftUI lets the tests check the
/// wording and which rows appear.
enum MenuRow: Equatable {
    case header(String)
    case account(AccountLine)
    case usage(UsageLine)
    case note(NoteLine)
    case action(ActionLine)
    case separator(String)

    /// Rows with the same keys in the same order are updated in place; any
    /// other change rebuilds the menu.
    var key: String {
        switch self {
        case .header(let title): "h:\(title)"
        case .account(let line): "a:\(line.id)"
        case .usage(let line): "u:\(line.key)"
        case .note(let line): "n:\(line.key):\(line.text)"
        case .action(let line): "x:\(line.action.rawValue)"
        case .separator(let id): "s:\(id)"
        }
    }
}

struct AccountLine: Equatable {
    var id: String
    var label: String
    var checked: Bool
    /// "new sessions" on the proven owner, "unverified" when the checkmark
    /// follows `~/.claude.json` instead.
    var tag: String?
    /// "as of 14:02" when the rows are stale.
    var trailing: String?
    var fetching: Bool
    var tooltip: String?
}

struct UsageLine: Equatable {
    var key: String
    var label: String
    /// Percent used, as the API reports it.
    var percent: Double
    var severity: UsageSeverity
    var stale: Bool
    var tooltip: String?

    /// Percent left, 0–100: what the menu shows, like T3 Code's usage panel.
    var remaining: Double { min(max(100 - percent, 0), 100) }
}

struct NoteLine: Equatable {
    enum Style: Equatable { case secondary, warning }

    var key: String
    var text: String
    /// Indented under an account.
    var indented: Bool
    var style: Style
}

struct ActionLine: Equatable {
    enum Action: String {
        case cancelSignIn, resolveUnfinished, fixClaudeJSON, saveLogin, addAccount, refresh, settings, quit
    }

    var action: Action
    var title: String
    var enabled = true
}

/// Everything the rows depend on.
struct MenuInput {
    var accounts: [SavedAccount]
    var live: LiveState?
    var usage: [String: AccountUsage]
    var fetching: Set<String>
    var sessions: RunningSessions
    var externalChange: Date?
    var signingIn: Bool
    var unfinished: Bool
    var notice: String?
    var now: Date
}

enum MenuRows {
    static func rows(_ input: MenuInput) -> [MenuRow] {
        var rows: [MenuRow] = [.header("Claude Account")]
        if input.accounts.isEmpty {
            rows.append(.note(NoteLine(key: "empty", text: "No saved logins", indented: false, style: .secondary)))
        }
        for account in input.accounts {
            rows += accountRows(account, input)
        }
        rows += sessionWarnings(input)
        rows.append(.separator("accounts"))

        if input.signingIn {
            rows.append(.note(NoteLine(key: "signing-in", text: "Waiting for sign-in in your browser…", indented: false, style: .secondary)))
            rows.append(.action(ActionLine(action: .cancelSignIn, title: "Cancel sign-in")))
        }
        if input.unfinished {
            rows.append(.action(ActionLine(action: .resolveUnfinished, title: "⚠︎ A switch didn't finish. Resolve…")))
        }
        rows += mismatchRows(input)
        if let notice = input.notice {
            rows.append(.note(NoteLine(key: "notice", text: notice, indented: false, style: .secondary)))
        }
        rows += [
            .action(ActionLine(action: .saveLogin, title: "Save current login…")),
            .action(ActionLine(action: .addAccount, title: "Add account…", enabled: !input.signingIn)),
            .action(ActionLine(action: .refresh, title: "Refresh usage")),
            .action(ActionLine(action: .settings, title: "Settings…")),
            .separator("quit"),
            .action(ActionLine(action: .quit, title: "Quit")),
        ]
        return rows
    }

    private static func accountRows(_ account: SavedAccount, _ input: MenuInput) -> [MenuRow] {
        let live = input.live
        let checked = live?.activeId == account.id
        let isOwner = live?.ownerId == account.id
        let unverified = checked && live?.isProven == false
        let fetching = input.fetching.contains(account.id)
        let presentation = UsagePresentation.make(usage: input.usage[account.id], account: account, fetching: fetching,
                                                  ownerUnverified: unverified, now: input.now)

        var tooltip: String?
        if unverified, case .unproven(let why) = live?.owner {
            tooltip = "Can't verify who owns the live login (\(why)). The checkmark follows ~/.claude.json."
        } else if input.usage[account.id]?.tokenExpired == true {
            tooltip = "This account's saved token has expired. Its usage updates after you switch to it."
        }
        var rows: [MenuRow] = [.account(AccountLine(
            id: account.id, label: account.label, checked: checked,
            tag: isOwner ? "new sessions" : (unverified ? "unverified" : nil),
            trailing: presentation.asOf.map { "as of \(time($0))" },
            fetching: fetching, tooltip: tooltip))]

        if isOwner, let changed = input.externalChange {
            rows.append(note("\(account.id):external", "Changed outside CCSwitcher at \(time(changed))"))
        }
        if let count = input.sessions.byAccount[account.id], count > 0 {
            let started = isOwner ? "" : " started before the switch"
            rows.append(note("\(account.id):sessions", "\(running(count))\(started)"))
        }
        for (index, limit) in presentation.rows.enumerated() {
            rows.append(.usage(UsageLine(key: "\(account.id):\(index)", label: limit.label, percent: limit.percent,
                                         severity: limit.severity, stale: presentation.stale,
                                         tooltip: UsagePresentation.resetText(limit.resetsAt, now: input.now))))
        }
        if let placeholder = presentation.placeholder {
            rows.append(note("\(account.id):placeholder", placeholder))
        }
        return rows
    }

    /// Shown only when running sessions started on an account that isn't
    /// the live owner, plus a line for sessions whose account is unknown.
    static func sessionWarnings(_ input: MenuInput) -> [MenuRow] {
        var rows: [MenuRow] = []
        if input.sessions.unknown > 0 {
            rows.append(.note(NoteLine(key: "sessions:unknown",
                                       text: "\(running(input.sessions.unknown)): account unknown",
                                       indented: false, style: .secondary)))
        }
        guard let ownerId = input.live?.ownerId else { return rows }
        let newLabel = label(ownerId, input)
        for warning in input.sessions.warnings where warning.count > 0 {
            let oldLabel = label(warning.accountId, input)
            let when = warning.liveSince.map { "started before \(time($0))" } ?? "started earlier"
            var text = "⚠︎ \(warning.count) Claude \(warning.count == 1 ? "session" : "sessions") \(when) may still be using "
                + "\(oldLabel). Restart \(warning.count == 1 ? "it" : "them") to be sure \(warning.count == 1 ? "it uses" : "they use") \(newLabel)."
            let around = warning.writeBackAround.map { " (around \(time($0)))" } ?? ""
            text += "\n\(warning.count == 1 ? "It" : "They") may switch the login back to \(oldLabel) when \(warning.count == 1 ? "its" : "their") token refreshes\(around)."
            rows.append(.note(NoteLine(key: "sessions:\(warning.accountId)", text: text, indented: false, style: .warning)))
        }
        return rows
    }

    /// The `~/.claude.json` mismatch, with the fix when the owner is a
    /// proven saved account.
    static func mismatchRows(_ input: MenuInput) -> [MenuRow] {
        guard let live = input.live, live.fileMismatch else { return [] }
        let shows = live.fileAccountId.map { label($0, input) } ?? live.fileOrgName ?? "no saved account"
        let actual: String = switch live.owner {
        case .account(let id): label(id, input)
        case .unsavedOrg(_, let name): "\(name ?? "an organization") (not saved)"
        case .unproven: "unknown"
        }
        var rows: [MenuRow] = [.note(NoteLine(
            key: "mismatch",
            text: "⚠︎ ~/.claude.json shows \(shows), but the live login is \(actual). A running Claude session probably rewrote it.",
            indented: false, style: .warning))]
        if live.fixableOwnerId != nil {
            rows.append(.action(ActionLine(action: .fixClaudeJSON, title: "Fix ~/.claude.json")))
            rows.append(.note(NoteLine(key: "mismatch:undo", text: "Running Claude sessions may undo this until restarted.",
                                       indented: true, style: .secondary)))
        }
        return rows
    }

    private static func note(_ key: String, _ text: String) -> MenuRow {
        .note(NoteLine(key: key, text: text, indented: true, style: .secondary))
    }

    private static func label(_ id: String, _ input: MenuInput) -> String {
        input.accounts.first { $0.id == id }?.label ?? "an account that's no longer saved"
    }

    /// "1 running session", "18 running sessions".
    private static func running(_ count: Int) -> String {
        "\(count) running \(count == 1 ? "session" : "sessions")"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Panel layout

/// One piece of the panel: an account card, or a row that stands alone.
enum MenuBlock: Equatable, Identifiable {
    case card(AccountCard)
    case row(MenuRow)

    var id: String {
        switch self {
        case .card(let card): "card:\(card.account.id)"
        case .row(let row): row.key
        }
    }
}

/// An account and the rows that belong to it: its indented notes and its
/// usage, in menu order.
struct AccountCard: Equatable {
    var account: AccountLine
    /// The account's position among saved accounts. Picks its color.
    var index: Int
    var rows: [MenuRow]
}

extension MenuRows {
    /// Groups rows into cards: each account takes the usage rows and
    /// indented notes that follow it. Any other row ends the card.
    static func blocks(_ rows: [MenuRow]) -> [MenuBlock] {
        var blocks: [MenuBlock] = []
        var card: AccountCard?
        var index = 0
        for row in rows {
            switch row {
            case .account(let line):
                if let card { blocks.append(.card(card)) }
                card = AccountCard(account: line, index: index, rows: [])
                index += 1
            case .usage where card != nil:
                card?.rows.append(row)
            case .note(let line) where card != nil && line.indented:
                card?.rows.append(row)
            default:
                if let finished = card { blocks.append(.card(finished)) }
                card = nil
                blocks.append(.row(row))
            }
        }
        if let card { blocks.append(.card(card)) }
        return blocks
    }
}
