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

    private let switcher: Switcher
    private let usageClient: UsageClient
    private let cache: UsageCache
    private let clock: Clock = SystemClock()
    private var lastUsageFetch: Date?
    private var backoffUntil: Date?

    init() {
        let defaults = UserDefaults.standard
        switcher = Switcher(item: ClaudeItem(), store: AccountStore(), config: ClaudeConfig(),
                            accounts: DefaultsAccountList(defaults: defaults), sessions: SessionGuard())
        usageClient = UsageClient(clock: clock)
        cache = UsageCache(defaults: defaults)

        // The menu-style MenuBarExtra is an NSMenu: refresh when it opens.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpened() }
        }
        Task { await reload() }
    }

    /// The menu bar shows the active account's initial, or `?`.
    var iconText: String {
        guard let active = accounts.first(where: { $0.id == activeId }),
              let initial = active.label.first else { return "?" }
        return String(initial).uppercased()
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

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
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
