import AppKit
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "AppModel")

/// Menu state and the actions behind each menu item. Credentials change only
/// through `Switcher`, and only from a click.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var notice: String?
    /// A switch that was interrupted before it verified or rolled back.
    @Published private(set) var unfinished: PendingSwitch?
    /// Set while `claude auth login` waits for the browser; "Cancel sign-in"
    /// cancels it.
    @Published private(set) var signingIn: LoginCancellation?

    /// The live owner, usage, history and running sessions.
    let status: AccountStatus

    private let switcher: Switcher
    private let clock: Clock = SystemClock()
    private var menuReload: Task<Void, Never>?

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
                            journal: DefaultsSwitchJournal(defaults: defaults),
                            cli: ClaudeCLI.standard(), login: ProcessLoginRunner())
        do {
            status = try AccountStatus(source: switcher, client: UsageClient(http: http, clock: clock),
                                       cache: UsageCache(defaults: defaults), history: DefaultsLoginHistory(defaults: defaults),
                                       sessions: SessionGuard(), clock: clock)
        } catch {
            fatalError("Can't read the usage cache or login history: \(error)")
        }
        // At launch: the owner only, for the icon. No usage fetch.
        Task {
            await reload()
            _ = await resolveUnfinishedSwitch()
            await reloadLive(expecting: nil)
        }
    }

    /// The account with the checkmark: the live token's proven owner, or the
    /// one `~/.claude.json` names when that can't be proven.
    var activeId: String? { status.live?.activeId }

    /// `~/.claude.json` names another organization than the live token's
    /// proven owner. Shown as a warning; fixed only from a click.
    var liveMismatch: Bool { status.live?.fileMismatch ?? false }

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

    /// The menu's rows for the current state.
    func menuRows() -> [MenuRow] {
        MenuRows.rows(MenuInput(accounts: accounts, live: status.live, usage: status.usage, fetching: status.fetching,
                                sessions: status.sessions, externalChange: status.externalChange,
                                signingIn: signingIn != nil, unfinished: unfinished != nil, notice: notice,
                                now: clock.now()))
    }

    // MARK: - Menu open and Refresh: the only usage fetches

    /// Called by the menu's delegate each time it opens: reloads the
    /// account list and starts (or joins) a usage refresh.
    func menuWillOpen() {
        if menuReload == nil {
            menuReload = Task {
                await reload()
                menuReload = nil
            }
        }
        startUsageRefresh(showErrors: false)
    }

    /// The menu's "Refresh usage" item.
    func refreshUsageNow() {
        startUsageRefresh(showErrors: true)
    }

    private func startUsageRefresh(showErrors: Bool) {
        let refresh = status.refresh(accountIds: accounts.map(\.id))
        Task {
            do {
                try await refresh.value
            } catch is CancellationError {
                return
            } catch SwitchError.busy {
                // An operation is running; the next menu open reads again.
                if showErrors { notice = SwitchError.busy.message }
            } catch let error as SwitchError {
                if showErrors { Prompts.show(error) } else { notice = error.message }
            } catch {
                Prompts.showUnexpected(error)
            }
        }
    }

    // MARK: - Menu actions

    func switchTo(_ account: SavedAccount) {
        let label = account.label
        perform(expecting: .switch) {
            let outcome = try await self.switcher.switchTo(account.id) { sessions in
                await Prompts.confirmSwitch(to: label, sessions: sessions)
            }
            log.info("Switch outcome: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// The menu's account row for `id`.
    func switchTo(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switchTo(account)
    }

    /// "Fix ~/.claude.json": writes the proven owner's saved profile back.
    /// Offered only when the owner is proven; runs only from this click.
    func fixClaudeJSON() {
        guard let ownerId = status.live?.fixableOwnerId else { return }
        perform(expecting: nil) {
            let outcome = try await self.switcher.fixClaudeJSON(ownerId: ownerId)
            log.info("Fix outcome: \(String(describing: outcome), privacy: .public)")
            if case .fixed(let account) = outcome {
                Prompts.inform("Fixed ~/.claude.json", "It names \(account.label) again. Running Claude sessions may undo "
                    + "this until you restart them.")
            }
        }
    }

    func saveCurrentLogin() {
        perform(expecting: nil) {
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

    /// "Add account…": backs up the current login, runs
    /// `claude auth login --claudeai`, then saves whatever organization the
    /// user signed in to.
    func addAccount() {
        let cancellation = LoginCancellation()
        perform(resolvingAfter: true, expecting: .add) {
            defer { self.signingIn = nil }
            let outcome = try await self.switcher.addAccount(
                confirm: { label in await Prompts.confirmAddAccount(current: label) },
                loginStarted: { await self.showSigningIn(cancellation) },
                askLabel: { suggestion in await Prompts.askLabel(suggestion: suggestion, title: "Save new account") },
                cancellation: cancellation)
            log.info("Add account outcome: \(String(describing: outcome), privacy: .public)")
            self.signingIn = nil
            if let message = outcome.message { Prompts.inform(message.title, message.text) }
        }
    }

    /// The menu's "Cancel sign-in" item.
    func cancelSignIn() {
        signingIn?.cancel()
    }

    private func showSigningIn(_ cancellation: LoginCancellation) {
        signingIn = cancellation
    }

    func rename(_ account: SavedAccount, to label: String) {
        perform(expecting: nil) { try await self.switcher.rename(account.id, to: label) }
    }

    func remove(_ account: SavedAccount) {
        guard Prompts.confirmRemove(account.label) else { return }
        perform(expecting: nil) { try await self.switcher.remove(account.id) }
    }

    func restorePrevious(_ account: SavedAccount) {
        guard Prompts.confirmRestorePrevious(account.label) else { return }
        perform(expecting: nil) {
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
            await reloadLive(expecting: .switch)
        }
    }

    // MARK: - Reads

    /// The account list, the journal and the notice. Reads only; no network.
    private func reload() async {
        do {
            accounts = try await switcher.savedAccounts()
            unfinished = try await switcher.unfinishedSwitch()
            notice = nil
        } catch let error as SwitchError {
            notice = error.message
        } catch {
            notice = "Unexpected error: \(error)"
        }
    }

    /// The live owner (no usage), at launch and after a clicked operation.
    private func reloadLive(expecting: LoginChange.Source?) async {
        do {
            try await status.reloadLive(expecting: expecting)
        } catch SwitchError.busy {
            return  // An operation is running; the next menu open reads again.
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
            switch Prompts.recoverUnfinishedSwitch(from: from, to: to, kind: pending.kind, startedAt: pending.startedAt) {
            case .restore:
                let restoring = from ?? "the previous login"
                let outcome = try await switcher.restoreUnfinishedSwitch { suggestion in
                    await Prompts.askLabelBeforeRestore(suggestion: suggestion, restoring: restoring)
                }
                if outcome == .restored {
                    Prompts.inform("Restored \(restoring)", "Claude Code is back on the login it used before.")
                }
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
        await reloadLive(expecting: .switch)
        return true
    }

    /// `resolvingAfter`: if the operation leaves a journal behind (an Add
    /// account whose result couldn't be settled), show the recovery alert
    /// right away.
    /// `expecting`: the history source to record if the operation changes the
    /// live owner. Never fetches usage: that happens on menu open and
    /// Refresh only.
    private func perform(resolvingAfter: Bool = false, expecting: LoginChange.Source?,
                         _ operation: @escaping @MainActor () async throws -> Void) {
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
            if resolvingAfter, unfinished != nil, await resolveUnfinishedSwitch() {
                await reload()
            }
            await reloadLive(expecting: expecting)
        }
    }
}
