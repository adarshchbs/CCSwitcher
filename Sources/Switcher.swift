import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Switcher")

enum SwitchError: Error, Equatable {
    case busy
    case unknownAccount
    case liveLoginUnreadable(String)
    case ownerUnknown
    case liveLoginMismatch
    case ownershipUnverified(String)
    case keychainAccessDenied(String)
    case claudeItemNotUnique(found: [String], expected: String)
    case storedLoginInvalid(String)
    case noPreviousLogin
    case backupFailed(String)
    case liveLoginKeptChanging
    case loginChangedDuringSave
    case switchUnfinished
    case rolledBack(String)
    case rollbackFailed(String)
    case rollbackSkipped(String)
    case recoveryFailed(String)
    case removeFailed(String)
    case invalidLabel
    case metadata(String)

    /// Why ownership can't be proven when the token is expired and matches no
    /// saved login.
    static let expiredAndUnmatched = "its access token has expired and it doesn't match a saved login. "
        + "Use Claude Code once so it refreshes, then try again."

    var message: String {
        switch self {
        case .busy: "Another account operation is still running. Try again when it finishes."
        case .unknownAccount: "That account is no longer saved."
        case .liveLoginUnreadable(let why): "Couldn't read the current Claude login: \(why)"
        case .ownerUnknown: "The current Claude login isn't saved. Save the current login first."
        case .liveLoginMismatch: "Claude's Keychain item and ~/.claude.json disagree about the current login. Nothing was changed. Run `claude /login` and try again."
        case .ownershipUnverified(let why): "Can't confirm which organization the current Claude login belongs to: \(why) Nothing was changed."
        case .keychainAccessDenied(let why): "CCSwitcher couldn't read Claude's Keychain item, so nothing was changed (\(why)). Allow access when macOS asks."
        case .claudeItemNotUnique(let found, let expected):
            found.isEmpty
                ? "Claude's Keychain item wasn't found in any keychain. Nothing was changed. Run `claude /login` first."
                : "Claude's Keychain item must exist exactly once, in your default keychain (\(expected)). Found it in: \(found.joined(separator: ", ")). Nothing was changed. Remove the extra copies in Keychain Access, then try again."
        case .storedLoginInvalid(let why): "The saved login for this account is unusable: \(why)"
        case .noPreviousLogin: "This account has no previous saved login to restore."
        case .backupFailed(let why): "Couldn't back up the current login, so nothing was changed: \(why)"
        case .liveLoginKeptChanging: "Claude Code kept updating its login during the switch. Nothing was changed. Try again."
        case .loginChangedDuringSave: "The Claude login changed while you were naming it. Nothing was saved."
        case .switchUnfinished: "A previous switch didn't finish. Resolve it before changing accounts."
        case .rolledBack(let why): "The switch failed and the previous login was restored: \(why)"
        case .rollbackFailed(let why): "The switch failed and the previous login couldn't be restored (\(why)). Run `claude /login` in a terminal and pick the organization you want."
        case .rollbackSkipped(let why): "The switch failed (\(why)), and Claude Code changed its Keychain item before CCSwitcher could restore it, so CCSwitcher left it alone rather than overwrite a newer login. Check which organization Claude Code is using; if it's wrong, run `claude /login` and pick the one you want."
        case .recoveryFailed(let why): "Couldn't restore the login from before the unfinished switch: \(why). Run `claude /login` in a terminal and pick the organization you want."
        case .removeFailed(let why): "Couldn't delete the saved login, so the account was kept: \(why)"
        case .invalidLabel: "The account name can't be empty."
        case .metadata(let why): "Couldn't read or save the account list: \(why)"
        }
    }

    /// The live login may be broken and only the user can fix it.
    var isBlocking: Bool {
        switch self {
        case .rollbackFailed, .rollbackSkipped, .recoveryFailed: true
        default: false
        }
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

/// Whether the live Keychain token belongs to the organization
/// `~/.claude.json` names. Detection only; nothing acts on it automatically.
enum LiveLoginStatus: Equatable, Sendable {
    case consistent
    /// Provably a different organization: the token is another saved
    /// account's, or the profile endpoint names another org.
    case mismatch
    /// Can't tell (expired token, network failure, no profile).
    case unknown
}

/// The only code that changes credentials. Runs one operation at a time and
/// rejects a new one while another is in progress (including while it waits
/// for the user to answer a prompt or for the network).
actor Switcher {
    private let item: ClaudeItemAccess
    private let store: SavedLoginStore
    private let config: ClaudeProfileAccess
    private let accounts: AccountList
    private let sessions: SessionListing
    private let lookup: OrgLookup
    private let clock: Clock
    private let journal: SwitchJournal
    private var busy = false

    init(item: ClaudeItemAccess, store: SavedLoginStore, config: ClaudeProfileAccess,
         accounts: AccountList, sessions: SessionListing, lookup: OrgLookup, clock: Clock,
         journal: SwitchJournal) {
        self.item = item
        self.store = store
        self.config = config
        self.accounts = accounts
        self.sessions = sessions
        self.lookup = lookup
        self.clock = clock
        self.journal = journal
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
        } catch let error where error is ClaudeConfig.Failure || error is Envelope.Failure || error is DecodingError {
            log.notice("No live owner: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The interrupted switch, if any. A record that no longer decodes still
    /// counts (with empty ids), so it can't silently unblock switching.
    func unfinishedSwitch() throws -> PendingSwitch? {
        do {
            return try journal.load()
        } catch let error as DecodingError {
            log.error("Pending-switch journal doesn't decode: \(String(describing: error), privacy: .public)")
            return PendingSwitch(fromId: "", toId: "", startedAt: .distantPast)
        } catch {
            throw SwitchError.metadata("pending-switch journal: \(describe(error))")
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
            } catch let error where Self.isReadFailure(error) {
                log.notice("No usage token for \(account.id, privacy: .public): \(self.describe(error), privacy: .public)")
            }
        }
        return tokens
    }

    /// Checks the live token against the organization `~/.claude.json`
    /// names. Reads only; a mismatch is reported, never fixed.
    func liveLoginStatus() async throws -> LiveLoginStatus {
        guard !busy else { throw SwitchError.busy }
        let live: LiveLogin
        do { live = try readLiveLogin() } catch SwitchError.liveLoginUnreadable { return .unknown }
        guard let org = live.profile.organizationUuid else { return .unknown }
        switch try await ownership(of: live.login, org: org, saved: try loadAccounts(), strict: false) {
        case .proven: return .consistent
        case .otherAccount, .otherOrg: return .mismatch
        case .unprovable: return .unknown
        }
    }

    // MARK: - Save current login

    /// Imports the login Claude Code is using now. Updates the saved account
    /// with the same organization, or asks for a label and adds a new one.
    /// Proves the tokens belong to that organization before storing them.
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

        try await verifyOwner(live.login, org: org, saved: saved)
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

        // Exactly one Claude item, in the pinned keychain; then get the
        // Keychain dialog (if any) out of the way before the critical window.
        try requireSingleClaudeItem()
        try preauthorize()

        for attempt in 1...3 {
            // 2. Read live state, find its owner and prove the tokens are its.
            let live = try readLiveLogin()
            guard let owner = saved.owner(ofOrg: live.profile.organizationUuid) else { throw SwitchError.ownerUnknown }
            if owner.id == target.id { return .alreadyActive }
            // The item already holding X's tokens while the profile names
            // another account means the two disagree: who owns it is unclear.
            guard !Self.sameBytes(live.login.refreshToken, targetTokens.refreshToken) else { throw SwitchError.liveLoginMismatch }
            try await verifyOwner(live.login, org: owner.orgUuid, saved: saved)

            // 3. Back up the owner.
            try backUp(StoredLogin(claudeAiOauth: live.claudeAiOauth, profile: live.profile), to: owner)

            // 4 and 5. Re-read in-process and write right away, unless Claude
            // Code refreshed its token since step 2. The journal goes first,
            // so an interrupted switch is noticed on the next launch.
            try saveJournal(PendingSwitch(fromId: owner.id, toId: target.id, startedAt: clock.now()))
            var before: Envelope?
            var next: Envelope?
            do {
                _ = try item.update { data in
                    let current = try Envelope(data)
                    guard try current.claudeAiOauth() == live.claudeAiOauth else { return nil }
                    let replaced = try current.replacing("claudeAiOauth", with: targetLogin.claudeAiOauth)
                    (before, next) = (current, replaced)
                    return replaced.bytes
                }
            } catch {
                guard let before, let next else {
                    // The read or the parse failed: nothing was written.
                    journal.clear()
                    throw SwitchError.liveLoginUnreadable("Keychain item: \(describe(error))")
                }
                try rollBack(to: before, wrote: next, profile: live.profile, cause: error)
            }
            guard let before, let next else {
                journal.clear()
                log.notice("Live login changed during switch (attempt \(attempt, privacy: .public))")
                continue
            }

            do {
                try config.writeProfile(targetLogin.profile)   // 6.
                try verify(refreshToken: targetTokens.refreshToken, orgUuid: target.orgUuid)  // 7.
            } catch {
                try rollBack(to: before, wrote: next, profile: live.profile, cause: error)  // 8.
            }
            journal.clear()
            log.info("Switched from \(owner.id, privacy: .public) to \(target.id, privacy: .public)")
            return .switched
        }
        throw SwitchError.liveLoginKeptChanging
    }

    // MARK: - Unfinished switch

    /// "Restore <from>": puts back the login from before the interrupted
    /// switch. Whatever login is live first goes to the saved account it
    /// provably belongs to, since it may be the only valid copy (Claude Code
    /// may have rotated it). If that can't be proven, nothing is written.
    func restoreUnfinishedSwitch() async throws {
        try begin(allowUnfinished: true)
        defer { busy = false }
        guard let pending = try unfinishedSwitch() else { return }

        let saved = try loadAccounts()
        guard let from = saved.first(where: { $0.id == pending.fromId }) else { throw SwitchError.unknownAccount }
        let fromTokens: OAuthLogin
        do { fromTokens = try storedLogin(for: from).login() } catch let error as SwitchError { throw error }
        catch { throw SwitchError.storedLoginInvalid(describe(error)) }

        try requireSingleClaudeItem()
        try preauthorize()
        let live = try readLiveLogin()

        if !Self.sameBytes(live.login.refreshToken, fromTokens.refreshToken) {
            let to = saved.first { $0.id == pending.toId }
            if let to, try await ownership(of: live.login, org: to.orgUuid, saved: saved, strict: true) == .proven {
                try backUp(StoredLogin(claudeAiOauth: live.claudeAiOauth, profile: storedLogin(for: to).profile), to: to)
            } else if try await ownership(of: live.login, org: from.orgUuid, saved: saved, strict: true) == .proven {
                try backUp(StoredLogin(claudeAiOauth: live.claudeAiOauth, profile: storedLogin(for: from).profile), to: from)
            } else {
                throw SwitchError.ownershipUnverified(SwitchError.expiredAndUnmatched)
            }
        }

        let restore = try storedLogin(for: from)
        let restoreTokens: OAuthLogin
        do { restoreTokens = try restore.login() } catch { throw SwitchError.storedLoginInvalid(describe(error)) }
        var changed = false
        do {
            _ = try item.update { data in
                let current = try Envelope(data)
                guard try current.claudeAiOauth() == live.claudeAiOauth else { changed = true; return nil }
                return try current.replacing("claudeAiOauth", with: restore.claudeAiOauth).bytes
            }
        } catch {
            throw SwitchError.recoveryFailed("Keychain item: \(describe(error))")
        }
        if changed { throw SwitchError.liveLoginKeptChanging }
        do {
            try config.writeProfile(restore.profile)
            try verify(refreshToken: restoreTokens.refreshToken, orgUuid: from.orgUuid)
        } catch {
            throw SwitchError.recoveryFailed(describe(error))
        }
        journal.clear()
        log.info("Restored \(from.id, privacy: .public) after an unfinished switch")
    }

    /// "I've fixed it": forgets the interrupted switch. Changes nothing else.
    func dismissUnfinishedSwitch() throws {
        try begin(allowUnfinished: true)
        defer { busy = false }
        journal.clear()
    }

    // MARK: - Previous saved login

    /// Swaps an account's saved login with the one it replaced. Swapping
    /// (rather than dropping the current one) keeps the action reversible.
    /// Touches only the account's own item, never the live login.
    func restorePrevious(_ id: String) throws {
        try begin()
        defer { busy = false }
        let saved = try loadAccounts()
        guard let account = saved.first(where: { $0.id == id }) else { throw SwitchError.unknownAccount }
        let record: SavedLoginRecord
        do { record = try SavedLoginRecord(decoding: store.read(id: id)) }
        catch { throw SwitchError.storedLoginInvalid(describe(error)) }
        guard let previous = record.previous else { throw SwitchError.noPreviousLogin }
        guard previous.profile.organizationUuid == account.orgUuid else {
            throw SwitchError.storedLoginInvalid("the previous login belongs to a different organization")
        }
        do { _ = try previous.login() } catch { throw SwitchError.storedLoginInvalid(describe(error)) }
        try writeRecord(SavedLoginRecord(current: previous, previous: record.current), to: account)
        log.info("Restored the previous saved login for \(id, privacy: .public)")
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

    // MARK: - Ownership

    private enum Ownership: Equatable {
        case proven
        /// The refresh token is the one saved for this other account.
        case otherAccount(String)
        /// The profile endpoint names this other organization.
        case otherOrg(String?)
        case unprovable(String)
    }

    /// Proves `login` belongs to organization `org`, or throws. Passes when
    /// (b) its refresh token is byte-equal to the one saved for that org
    /// (verified when it was stored), or (a) its access token is unexpired
    /// and the profile endpoint names that org. Fails when the refresh token
    /// is another saved account's. Anything else, network failures included,
    /// fails closed.
    func verifyOwner(_ login: OAuthLogin, org: String, saved: [SavedAccount]) async throws {
        switch try await ownership(of: login, org: org, saved: saved, strict: true) {
        case .proven: return
        case .otherAccount(let label):
            log.error("Live refresh token is the one saved for \(label, privacy: .private)")
            throw SwitchError.liveLoginMismatch
        case .otherOrg(let name):
            log.error("Profile endpoint names another organization: \(name ?? "?", privacy: .private)")
            throw SwitchError.liveLoginMismatch
        case .unprovable(let why):
            throw SwitchError.ownershipUnverified(why)
        }
    }

    /// `strict`: a saved login of another account that can't be read makes
    /// the result unprovable, since a cross-account match can't be ruled out.
    private func ownership(of login: OAuthLogin, org: String, saved: [SavedAccount], strict: Bool) async throws -> Ownership {
        var matchesBackup = false
        for account in saved {
            let stored: StoredLogin
            let tokens: OAuthLogin
            do {
                stored = try StoredLogin(decoding: store.read(id: account.id))
                tokens = try stored.login()
            } catch let error where Self.isReadFailure(error) {
                if strict && account.orgUuid != org {
                    return .unprovable("the saved login for \(account.label) can't be read (\(describe(error))), "
                        + "so a mix-up with it can't be ruled out. Remove that account and save it again.")
                }
                continue
            }
            guard Self.sameBytes(tokens.refreshToken, login.refreshToken) else { continue }
            if account.orgUuid == org && stored.profile.organizationUuid == org {
                matchesBackup = true
            } else {
                return .otherAccount(account.label)
            }
        }
        if matchesBackup { return .proven }

        if let expiresAt = login.expiresAt, expiresAt <= clock.now() {
            return .unprovable(SwitchError.expiredAndUnmatched)
        }
        switch try await lookup.organization(accessToken: login.accessToken) {
        case .organization(let uuid, let name):
            return uuid == org ? .proven : .otherOrg(name)
        case .unauthorized:
            return .unprovable(SwitchError.expiredAndUnmatched)
        case .failed(let why):
            return .unprovable("the organization check with Anthropic failed (\(why)). Try again when you're online.")
        }
    }

    // MARK: - Steps

    private func begin(allowUnfinished: Bool = false) throws {
        guard !busy else { throw SwitchError.busy }
        if !allowUnfinished, try unfinishedSwitch() != nil { throw SwitchError.switchUnfinished }
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

    private func requireSingleClaudeItem() throws {
        do {
            try item.requireUnique()
        } catch ClaudeItem.Failure.notUnique(let found, let expected) {
            throw SwitchError.claudeItemNotUnique(found: found, expected: expected)
        } catch {
            throw SwitchError.liveLoginUnreadable("Keychain search: \(describe(error))")
        }
    }

    private func preauthorize() throws {
        do {
            try item.preauthorize()
        } catch ClaudeItem.Failure.notFound {
            throw SwitchError.liveLoginUnreadable("Claude's Keychain item wasn't found")
        } catch {
            throw SwitchError.keychainAccessDenied(describe(error))
        }
    }

    private func saveJournal(_ pending: PendingSwitch) throws {
        do { try journal.save(pending) } catch { throw SwitchError.metadata("pending-switch journal: \(describe(error))") }
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

    /// Saves `login` as the account's current login, keeping the one it
    /// replaces as `previous`, and reads it back. A saved item that exists
    /// but can't be decoded is never overwritten: its login would be lost.
    private func backUp(_ login: StoredLogin, to account: SavedAccount) throws {
        let existing: SavedLoginRecord?
        do {
            existing = try SavedLoginRecord(decoding: store.read(id: account.id))
        } catch AccountStore.Failure.notFound {
            existing = nil  // The account's first save.
        } catch {
            throw SwitchError.backupFailed("the saved login for \(account.label) can't be read (\(describe(error))), "
                + "and overwriting it would lose it")
        }
        try writeRecord(existing?.replacingCurrent(with: login) ?? SavedLoginRecord(current: login, previous: nil), to: account)
    }

    private func writeRecord(_ record: SavedLoginRecord, to account: SavedAccount) throws {
        do {
            let data = try record.encoded()
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

    private enum RollbackStop: Error {
        case itemChanged
    }

    private func verify(refreshToken: String, orgUuid: String?) throws {
        let live = try OAuthLogin(raw: Envelope(item.read()).claudeAiOauth())
        guard Self.sameBytes(live.refreshToken, refreshToken) else { throw VerifyFailure.itemHoldsOtherLogin }
        guard try config.readProfile().organizationUuid == orgUuid else { throw VerifyFailure.profileNamesOtherOrg }
    }

    /// Restores the item and profile read before the switch. The item is
    /// restored only if it still holds what the switch wrote (`next`) or what
    /// it held before (`original`); anything else means Claude Code changed it
    /// since, and overwriting it could destroy a freshly rotated token, so
    /// the rollback stops. Success is decided by verifying the restored
    /// state, not by the write calls. The journal stays unless that verify
    /// passes.
    private func rollBack(to original: Envelope, wrote next: Envelope, profile: OAuthProfile, cause: Error) throws -> Never {
        log.error("Switch failed (\(self.describe(cause), privacy: .public)); rolling back")
        var problems: [String] = []
        do {
            _ = try item.update { live in
                if live == next.bytes { return original.bytes }
                if live == original.bytes { return nil }
                throw RollbackStop.itemChanged
            }
        } catch RollbackStop.itemChanged {
            log.fault("Rollback skipped: Claude's Keychain item changed after the switch wrote it")
            throw SwitchError.rollbackSkipped(describe(cause))
        } catch {
            problems.append("item: \(describe(error))")
        }
        // Rewrite the profile only if it changed: every rewrite of
        // ~/.claude.json can race a write by Claude Code.
        var profileNeedsWrite = true
        do {
            profileNeedsWrite = try config.readProfile().canonicalJSON() != profile.canonicalJSON()
        } catch let error where error is ClaudeConfig.Failure || error is Envelope.Failure
                    || error is DecodingError || error is EncodingError {
            log.notice("Can't compare ~/.claude.json before restoring it: \(self.describe(error), privacy: .public)")
        }
        if profileNeedsWrite {
            do { try config.writeProfile(profile) } catch { problems.append("profile: \(describe(error))") }
        }
        do {
            let restored = try OAuthLogin(raw: original.claudeAiOauth())
            try verify(refreshToken: restored.refreshToken, orgUuid: profile.organizationUuid)
        } catch {
            problems.append("verify: \(describe(error))")
            log.fault("Rollback failed: \(problems.joined(separator: "; "), privacy: .public)")
            throw SwitchError.rollbackFailed(problems.joined(separator: "; "))
        }
        journal.clear()
        throw SwitchError.rolledBack(describe(cause))
    }

    private func loadAccounts() throws -> [SavedAccount] {
        do { return try accounts.load() } catch { throw SwitchError.metadata(describe(error)) }
    }

    private func saveAccounts(_ saved: [SavedAccount]) throws {
        do { try accounts.save(saved) } catch { throw SwitchError.metadata(describe(error)) }
    }

    /// Token comparison by bytes. Swift's `==` on String compares by Unicode
    /// canonical equivalence, which isn't what "the same token" means.
    private static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// Errors that mean "this saved or live login can't be read", as opposed
    /// to a bug.
    private static func isReadFailure(_ error: Error) -> Bool {
        error is ClaudeItem.Failure || error is AccountStore.Failure || error is Envelope.Failure
            || error is StoredLogin.Failure || error is DecodingError
    }

    /// Error text safe to show and log: the error types here carry statuses
    /// and key names, never secrets.
    private nonisolated func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
