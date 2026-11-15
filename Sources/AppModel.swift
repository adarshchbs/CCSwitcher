import AppKit
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "AppModel")

/// Menu state and the actions behind each menu item. Credentials change only
/// through `Switcher`, and only from a click.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var activeId: String?
    @Published private(set) var usage: [String: AccountUsage] = [:]
    @Published private(set) var notice: String?
    /// The live Keychain token provably belongs to a different organization
    /// than `~/.claude.json` names. Shown as a warning; never fixed
    /// automatically.
    @Published private(set) var liveMismatch = false
    /// A switch that was interrupted before it verified or rolled back.
    @Published private(set) var unfinished: PendingSwitch?

    private let switcher: Switcher
    private let usageClient: UsageClient
    private let cache: UsageCache
    private let clock: Clock = SystemClock()
    private var lastUsageFetch: Date?
    private var backoffUntil: Date?

    init() {
        let defaults = UserDefaults.standard
        // Every Keychain call goes to the keychain that is the default now.
        // Without one there is nowhere safe to read or write: fail fast.
        let keychain: KeychainPin
        do { keychain = try KeychainPin.userDefault() } catch { fatalError("No default keychain: \(error)") }
        // One session for both requests: ephemeral, no cache, no redirects.
        let http = EphemeralHTTP()
        switcher = Switcher(item: ClaudeItem(keychain: keychain), store: AccountStore(keychain: keychain),
                            config: ClaudeConfig(), accounts: DefaultsAccountList(defaults: defaults),
                            sessions: SessionGuard(), lookup: ProfileClient(http: http), clock: clock,
                            journal: DefaultsSwitchJournal(defaults: defaults))
        usageClient = UsageClient(http: http, clock: clock)
        cache = UsageCache(defaults: defaults)

        // The menu-style MenuBarExtra is an NSMenu: refresh when it opens.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpened() }
        }
        Task {
            await reload()
            _ = await resolveUnfinishedSwitch()
            await checkLiveStatus()
        }
    }

    /// The menu bar icon, an SF Symbol rendered as a template image so it
    /// matches the other menu bar icons:
    /// - an unfinished switch or a live login that doesn't match
    ///   `~/.claude.json`: a person with an exclamation mark
    /// - the active account: its initial in a filled circle (Ⓚ, Ⓟ), or a
    ///   filled person when the label doesn't start with a letter A–Z
    /// - no saved login active: a person with a question mark
    var iconSymbol: String {
        if unfinished != nil || liveMismatch { return "person.crop.circle.badge.exclamationmark" }
        guard let active = accounts.first(where: { $0.id == activeId }) else {
            return "person.crop.circle.badge.questionmark"
        }
        guard let initial = active.label.lowercased().first, ("a"..."z").contains(initial) else {
            return "person.crop.circle.fill"
        }
        return "\(initial).circle.fill"
    }

    /// What VoiceOver reads for the menu bar icon.
    var iconAccessibilityLabel: String {
        if unfinished != nil { return "Claude account: unfinished switch" }
        if liveMismatch { return "Claude account: login mismatch" }
        guard let active = accounts.first(where: { $0.id == activeId }) else { return "Claude account: none saved" }
        return "Claude account: \(active.label)"
    }

    func title(for account: SavedAccount) -> String {
        let summary = (usage[account.id] ?? AccountUsage()).summary(now: clock.now())
        return "\(account.label)    \(summary)"
    }

    // MARK: - Menu actions

    func switchTo(_ account: SavedAccount) {
        let label = account.label
        perform {
            let outcome = try await self.switcher.switchTo(account.id) { sessions in
                await Prompts.confirmSwitch(to: label, sessions: sessions)
            }
            log.info("Switch outcome: \(String(describing: outcome), privacy: .public)")
            if outcome == .switched { self.lastUsageFetch = nil }
        }
    }

    func saveCurrentLogin() {
        perform {
            let outcome = try await self.switcher.saveCurrentLogin { suggestion in
                await Prompts.askLabel(suggestion: suggestion)
            }
            switch outcome {
            case .added(let account): Prompts.inform("Saved \(account.label)", "The current Claude login is now saved.")
            case .updated(let account): Prompts.inform("Updated \(account.label)", "The saved login now matches the current Claude login.")
            case .cancelled: break
            }
        }
    }

    func refreshUsageNow() {
        Task { await refreshUsage(force: true) }
    }

    func rename(_ account: SavedAccount, to label: String) {
        perform { try await self.switcher.rename(account.id, to: label) }
    }

    func remove(_ account: SavedAccount) {
        guard Prompts.confirmRemove(account.label) else { return }
        perform { try await self.switcher.remove(account.id) }
    }

    func restorePrevious(_ account: SavedAccount) {
        guard Prompts.confirmRestorePrevious(account.label) else { return }
        perform {
            try await self.switcher.restorePrevious(account.id)
            Prompts.inform("Restored \(account.label)",
                           "The previous saved login is back. The one it replaced is now the previous login, so you can undo this the same way.")
        }
    }

    /// The menu's "Unfinished switch" row.
    func resolveUnfinishedSwitchNow() {
        Task {
            _ = await resolveUnfinishedSwitch()
            await reload()
        }
    }

    // MARK: - Refresh

    private func menuOpened() {
        Task {
            await reload()
            await refreshUsage(force: false)
        }
    }

    private func reload() async {
        do {
            accounts = try await switcher.savedAccounts()
            activeId = try await switcher.liveOwner()?.id
            unfinished = try await switcher.unfinishedSwitch()
            usage = try cache.load()
            notice = nil
        } catch let error as SwitchError {
            notice = error.message
        } catch {
            notice = "Unexpected error: \(error)"
        }
    }

    /// Fetches usage at most once a minute, unless forced, and never while
    /// backing off after a 429.
    private func refreshUsage(force: Bool) async {
        let now = clock.now()
        if let until = backoffUntil, now < until {
            if force { notice = "Usage is rate limited until \(until.formatted(date: .omitted, time: .shortened))." }
            return
        }
        if !force, let last = lastUsageFetch, now.timeIntervalSince(last) < 60 { return }
        lastUsageFetch = now
        await checkLiveStatus()

        do {
            let tokens = try await switcher.usageTokens()
            var updated = usage.filter { id, _ in accounts.contains { $0.id == id } }
            for account in accounts {
                guard let token = tokens[account.id] else { continue }
                let result = try await usageClient.fetch(token)
                updated[account.id] = (updated[account.id] ?? AccountUsage()).applying(result)
                if case .rateLimited(let retryAfter) = result {
                    backoffUntil = now.addingTimeInterval(retryAfter ?? 300)
                    break
                }
            }
            usage = updated
            try cache.save(updated)
        } catch is CancellationError {
            return
        } catch let error as SwitchError {
            if force { Prompts.show(error) }
        } catch {
            Prompts.showUnexpected(error)
        }
    }

    /// Whether the live token provably belongs to another org than the
    /// profile names. Detection only.
    private func checkLiveStatus() async {
        do {
            liveMismatch = try await switcher.liveLoginStatus() == .mismatch
        } catch SwitchError.busy {
            return  // An operation is running; the next menu open checks again.
        } catch is CancellationError {
            return
        } catch let error as SwitchError {
            notice = error.message
        } catch {
            notice = "Unexpected error: \(error)"
        }
    }

    /// Shows the recovery alert when a switch was interrupted. Returns true
    /// when there was one, so the caller skips its own operation: the user
    /// decides what happens next, and nothing runs on its own.
    private func resolveUnfinishedSwitch() async -> Bool {
        let pending: PendingSwitch?
        do {
            pending = try await switcher.unfinishedSwitch()
        } catch let error as SwitchError {
            Prompts.show(error)
            return true
        } catch {
            Prompts.showUnexpected(error)
            return true
        }
        guard let pending else { return false }
        unfinished = pending
        let from = accounts.first { $0.id == pending.fromId }?.label
        let to = accounts.first { $0.id == pending.toId }?.label
        do {
            switch Prompts.recoverUnfinishedSwitch(from: from, to: to, startedAt: pending.startedAt) {
            case .restore:
                try await switcher.restoreUnfinishedSwitch()
                Prompts.inform("Restored \(from ?? "the previous login")", "Claude Code is back on the login it used before the unfinished switch.")
            case .dismiss:
                try await switcher.dismissUnfinishedSwitch()
            case .later:
                break
            }
        } catch let error as SwitchError {
            Prompts.show(error)
        } catch {
            Prompts.showUnexpected(error)
        }
        lastUsageFetch = nil
        return true
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            if await resolveUnfinishedSwitch() {
                await reload()
                return
            }
            do {
                try await operation()
            } catch let error as SwitchError {
                Prompts.show(error)
            } catch {
                Prompts.showUnexpected(error)
            }
            await reload()
            await refreshUsage(force: false)
        }
    }
}
