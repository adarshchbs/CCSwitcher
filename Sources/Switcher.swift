import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Switcher")

enum SwitchError: Error, Equatable {
    case busy
    case unknownAccount
    case liveLoginUnreadable(String)
    case ownerUnknown
    case liveLoginMismatch
    case storedLoginInvalid(String)
    case backupFailed(String)
    case liveLoginKeptChanging
    case loginChangedDuringSave
    case rolledBack(String)
    case rollbackFailed(String)
    case removeFailed(String)
    case invalidLabel
    case metadata(String)

    var message: String {
        switch self {
        case .busy: "Another account operation is still running. Try again when it finishes."
        case .unknownAccount: "That account is no longer saved."
        case .liveLoginUnreadable(let why): "Couldn't read the current Claude login: \(why)"
        case .ownerUnknown: "The current Claude login isn't saved. Save the current login first."
        case .liveLoginMismatch: "Claude's Keychain item and ~/.claude.json disagree about the current login. Nothing was changed. Run `claude /login` and try again."
        case .storedLoginInvalid(let why): "The saved login for this account is unusable: \(why)"
        case .backupFailed(let why): "Couldn't back up the current login, so nothing was changed: \(why)"
        case .liveLoginKeptChanging: "Claude Code kept updating its login during the switch. Nothing was changed. Try again."
        case .loginChangedDuringSave: "The Claude login changed while you were naming it. Nothing was saved."
        case .rolledBack(let why): "The switch failed and the previous login was restored: \(why)"
        case .rollbackFailed(let why): "The switch failed and the previous login couldn't be restored (\(why)). Run `claude /login` in a terminal and pick the organization you want."
        case .removeFailed(let why): "Couldn't delete the saved login, so the account was kept: \(why)"
        case .invalidLabel: "The account name can't be empty."
        case .metadata(let why): "Couldn't read or save the account list: \(why)"
        }
    }

    /// The live login may be broken and only the user can fix it.
    var isBlocking: Bool {
        if case .rollbackFailed = self { return true }
        return false
    }
}

enum SwitchOutcome: Equatable, Sendable {
    case switched
    case alreadyActive
    case cancelled
}

enum SaveOutcome: Equatable, Sendable {
    case added(SavedAccount)
    case updated(SavedAccount)
    case cancelled
}

/// The only code that changes credentials. Runs one operation at a time and
/// rejects a new one while another is in progress (including while it waits
/// for the user to answer a prompt).
actor Switcher {
    private let item: ClaudeItemAccess
    private let store: SavedLoginStore
    private let config: ClaudeProfileAccess
    private let accounts: AccountList
    private let sessions: SessionListing
    private var busy = false

    init(item: ClaudeItemAccess, store: SavedLoginStore, config: ClaudeProfileAccess,
         accounts: AccountList, sessions: SessionListing) {
        self.item = item
        self.store = store
        self.config = config
        self.accounts = accounts
        self.sessions = sessions
    }

    // MARK: - Reads

    func savedAccounts() throws -> [SavedAccount] {
        try loadAccounts()
    }

    /// The saved account that owns the live login, by `organizationUuid`, or
    /// nil when it is unknown.
    func liveOwner() throws -> SavedAccount? {
        let saved = try loadAccounts()
        do {
            return saved.owner(ofOrg: try config.readProfile().organizationUuid)
        } catch let error as ClaudeConfig.Failure {
            log.notice("No live owner: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A token per account for reading usage: the live item's for the
    /// active account, the saved item's for the others. Accounts whose token
    /// can't be read are left out and show as unavailable.
    func usageTokens() throws -> [String: UsageToken] {
        guard !busy else { throw SwitchError.busy }
        let owner = try liveOwner()
        var tokens: [String: UsageToken] = [:]
        for account in try loadAccounts() {
            do {
                let login = account.id == owner?.id
                    ? try OAuthLogin(raw: Envelope(item.read()).claudeAiOauth())
                    : try StoredLogin(decoding: store.read(id: account.id)).login()
                tokens[account.id] = UsageToken(accessToken: login.accessToken, expiresAt: login.expiresAt)
            } catch let error where error is ClaudeItem.Failure || error is AccountStore.Failure
                        || error is Envelope.Failure || error is StoredLogin.Failure || error is DecodingError {
                log.notice("No usage token for \(account.id, privacy: .public): \(self.describe(error), privacy: .public)")
            }
        }
        return tokens
    }

    // MARK: - Save current login

    /// Imports the login Claude Code is using now. Updates the saved account
    /// with the same organization, or asks for a label and adds a new one.
    func saveCurrentLogin(askLabel: @Sendable (String) async -> String?) async throws -> SaveOutcome {
        try begin()
        defer { busy = false }

        var live = try readLiveLogin()
        guard let org = live.profile.organizationUuid else {
            throw SwitchError.liveLoginUnreadable("~/.claude.json has no organizationUuid")
        }
        guard live.profile.emailAddress != nil else {
            throw SwitchError.liveLoginUnreadable("~/.claude.json has no emailAddress")
        }

        var saved = try loadAccounts()
        let existing = saved.owner(ofOrg: org)
        var account: SavedAccount
        if let existing {
            account = existing
        } else {
            let suggestion = live.profile.organizationName ?? live.profile.emailAddress ?? "Claude"
            guard let answer = await askLabel(suggestion) else { return .cancelled }
            let label = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw SwitchError.invalidLabel }
            // The login may have changed while the prompt was open.
            live = try readLiveLogin()
            guard live.profile.organizationUuid == org else { throw SwitchError.loginChangedDuringSave }
            saved = try loadAccounts()
            account = SavedAccount(id: UUID().uuidString, label: label, email: "", orgUuid: org)
        }

        try backUp(StoredLogin(claudeAiOauth: live.claudeAiOauth, profile: live.profile), to: account)
        account.email = live.profile.emailAddress ?? account.email
        account.orgName = live.profile.organizationName
        account.plan = live.login.subscriptionType
        if let index = saved.firstIndex(where: { $0.id == account.id }) {
            saved[index] = account
        } else {
            saved.append(account)
        }
        try saveAccounts(saved)
        log.info("Saved login for account \(account.id, privacy: .public)")
        return existing == nil ? .added(account) : .updated(account)
    }

    // MARK: - Switch

    /// Makes `id` the live Claude login. See "Switch to account X" in
    /// docs/FORK_SPEC.md for the steps.
    func switchTo(_ id: String, confirm: @Sendable ([LiveSession]) async -> Bool) async throws -> SwitchOutcome {
        try begin()
        defer { busy = false }

        let saved = try loadAccounts()
        guard let target = saved.first(where: { $0.id == id }) else { throw SwitchError.unknownAccount }

        // 1. Running sessions may keep using the old login until restarted.
        let running = sessions.liveSessions()
        if !running.isEmpty, !(await confirm(running)) { return .cancelled }

        let targetLogin = try storedLogin(for: target)
        let targetTokens: OAuthLogin
        do { targetTokens = try targetLogin.login() } catch { throw SwitchError.storedLoginInvalid(describe(error)) }

        for attempt in 1...3 {
            // 2. Read live state and find its owner.
            let live = try readLiveLogin()
            guard let owner = saved.owner(ofOrg: live.profile.organizationUuid) else { throw SwitchError.ownerUnknown }
            if owner.id == target.id { return .alreadyActive }
            // The item already holding X's tokens while the profile names
            // another account means the two disagree: who owns it is unclear.
            guard live.login.refreshToken != targetTokens.refreshToken else { throw SwitchError.liveLoginMismatch }

            // 3. Back up the owner.
            try backUp(StoredLogin(claudeAiOauth: live.claudeAiOauth, profile: live.profile), to: owner)

            // 4. Claude Code may have refreshed its token since step 2.
            let current = try readItem()
            guard try liveClaudeAiOauth(current) == live.claudeAiOauth else {
                log.notice("Live login changed during switch (attempt \(attempt, privacy: .public))")
                continue
            }

            let next: Envelope
            do { next = try current.replacing("claudeAiOauth", with: targetLogin.claudeAiOauth) }
            catch { throw SwitchError.storedLoginInvalid(describe(error)) }
            do {
                try item.write(next.bytes)                     // 5.
                try config.writeProfile(targetLogin.profile)   // 6.
                try verify(refreshToken: targetTokens.refreshToken, orgUuid: target.orgUuid)  // 7.
            } catch {
                try rollBack(to: current, profile: live.profile, cause: error)  // 8.
            }
            log.info("Switched from \(owner.id, privacy: .public) to \(target.id, privacy: .public)")
            return .switched
        }
        throw SwitchError.liveLoginKeptChanging
    }

    // MARK: - Remove and rename

    /// Deletes the account's saved login, then its metadata. Never touches
    /// the live login.
    func remove(_ id: String) throws {
        try begin()
        defer { busy = false }
        var saved = try loadAccounts()
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw SwitchError.unknownAccount }
        do {
            try store.delete(id: id)
        } catch AccountStore.Failure.notFound {
            log.notice("Saved login for \(id, privacy: .public) was already gone")
        } catch {
            throw SwitchError.removeFailed(describe(error))
        }
        saved.remove(at: index)
        try saveAccounts(saved)
    }

    func rename(_ id: String, to label: String) throws {
        try begin()
        defer { busy = false }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw SwitchError.invalidLabel }
        var saved = try loadAccounts()
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw SwitchError.unknownAccount }
        saved[index].label = label
        try saveAccounts(saved)
    }

    // MARK: - Steps

    private func begin() throws {
        guard !busy else { throw SwitchError.busy }
        busy = true
    }

    private struct LiveLogin {
        let envelope: Envelope
        let claudeAiOauth: Data
        let login: OAuthLogin
        let profile: OAuthProfile
    }

    private func readLiveLogin() throws -> LiveLogin {
        let envelope = try readItem()
        let raw = try liveClaudeAiOauth(envelope)
        let login: OAuthLogin
        do { login = try OAuthLogin(raw: raw) } catch { throw SwitchError.liveLoginUnreadable(describe(error)) }
        let profile: OAuthProfile
        do { profile = try config.readProfile() } catch { throw SwitchError.liveLoginUnreadable("~/.claude.json: \(describe(error))") }
        return LiveLogin(envelope: envelope, claudeAiOauth: raw, login: login, profile: profile)
    }

    private func readItem() throws -> Envelope {
        do { return try Envelope(item.read()) } catch { throw SwitchError.liveLoginUnreadable("Keychain item: \(describe(error))") }
    }

    private func liveClaudeAiOauth(_ envelope: Envelope) throws -> Data {
        do { return try envelope.claudeAiOauth() } catch { throw SwitchError.liveLoginUnreadable(describe(error)) }
    }

    private func storedLogin(for account: SavedAccount) throws -> StoredLogin {
        let stored: StoredLogin
        do { stored = try StoredLogin(decoding: store.read(id: account.id)) }
        catch { throw SwitchError.storedLoginInvalid(describe(error)) }
        guard stored.profile.organizationUuid == account.orgUuid else {
            throw SwitchError.storedLoginInvalid("it belongs to a different organization")
        }
        return stored
    }

    /// Writes `login` to the account's item and reads it back.
    private func backUp(_ login: StoredLogin, to account: SavedAccount) throws {
        do {
            let data = try login.encoded()
            try store.write(id: account.id, data: data)
            guard try store.read(id: account.id) == data else {
                throw SwitchError.backupFailed("the saved copy doesn't match what was written")
            }
        } catch let error as SwitchError {
            throw error
        } catch {
            throw SwitchError.backupFailed(describe(error))
        }
    }

    private enum VerifyFailure: Error {
        case itemHoldsOtherLogin
        case profileNamesOtherOrg
    }

    private func verify(refreshToken: String, orgUuid: String?) throws {
        let live = try OAuthLogin(raw: Envelope(item.read()).claudeAiOauth())
        guard live.refreshToken == refreshToken else { throw VerifyFailure.itemHoldsOtherLogin }
        guard try config.readProfile().organizationUuid == orgUuid else { throw VerifyFailure.profileNamesOtherOrg }
    }

    /// Restores the item and profile read before the switch. Success is
    /// decided by verifying the restored state, not by the write calls: a
    /// write that failed may have failed before changing anything.
    private func rollBack(to envelope: Envelope, profile: OAuthProfile, cause: Error) throws -> Never {
        log.error("Switch failed (\(self.describe(cause), privacy: .public)); rolling back")
        var problems: [String] = []
        // Attempt both writes even if the first fails; verification decides.
        do { try item.write(envelope.bytes) } catch { problems.append("item: \(describe(error))") }
        do { try config.writeProfile(profile) } catch { problems.append("profile: \(describe(error))") }
        do {
            let original = try OAuthLogin(raw: envelope.claudeAiOauth())
            try verify(refreshToken: original.refreshToken, orgUuid: profile.organizationUuid)
        } catch {
            problems.append("verify: \(describe(error))")
            log.fault("Rollback failed: \(problems.joined(separator: "; "), privacy: .public)")
            throw SwitchError.rollbackFailed(problems.joined(separator: "; "))
        }
        throw SwitchError.rolledBack(describe(cause))
    }

    private func loadAccounts() throws -> [SavedAccount] {
        do { return try accounts.load() } catch { throw SwitchError.metadata(describe(error)) }
    }

    private func saveAccounts(_ saved: [SavedAccount]) throws {
        do { try accounts.save(saved) } catch { throw SwitchError.metadata(describe(error)) }
    }

    /// Error text safe to show and log: the error types here carry statuses
    /// and key names, never secrets.
    private nonisolated func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
