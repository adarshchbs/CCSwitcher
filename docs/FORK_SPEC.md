# CCSwitcher fork: manual-only, hardened

This fork of [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher)
(MIT) cuts the app down to one job: switching Claude Code between saved logins
from the macOS menu bar, when the user clicks. Three independent audits of upstream commit
`d009cd625d0054f9c64e014312c83ce0380de7f3` shaped this spec. Each requirement
below cites the audit finding behind it.

## User and threat model

- One macOS user with two Claude logins that share **one email address**: a
  company Team-plan org and a personal org. **Org UUID tells the accounts
  apart. Email can't.**
- The worst outcome is leaking or losing the company refresh token. Losing a
  login (forcing a browser re-login) is the second worst.
- Company EDR/MDM may record every process command line.
- The user switches accounts 2–4 times a week, by hand.

## Hard rules

1. **No secret ever goes in argv or the environment.** Write the Claude Code
   Keychain item with `/usr/bin/security -i` and send the command on stdin,
   with the password hex-encoded using `-X`. Reading with
   `security find-generic-password -w` is fine, since the secret comes back on stdout.
2. **Nothing changes credentials without a click.** No timers, wake
   handlers, launch-time capture, auto-switch, background refresh, URL
   scheme, intents or widget.
3. **The app never calls the OAuth token endpoint.** Delete every refresh
   path. Claude Code refreshes its own tokens.
4. **The only outbound request is** `GET https://api.anthropic.com/api/oauth/usage`.
   No analytics, updater, pricing fetch, or version check.
5. **Swap only `claudeAiOauth`.** When switching, read the live envelope fresh
   and replace only its `claudeAiOauth` key. Keep `mcpOAuth` and every other
   key exactly as they are. Saved accounts store only `claudeAiOauth`, plus the
   `oauthAccount` profile block.
6. **Fail closed.** If you're unsure who owns the live credential, or a backup
   or verification fails, abort and leave the live login as it is.
7. **Account identity is `organizationUuid`**, taken from `oauthAccount`.
   Never match accounts by email.
8. **No file logging.** Use `os.Logger` only. Mark emails, org names and
   UUIDs `privacy: .private`. Never log tokens or HTTP bodies.

## What to delete

Delete these, along with their tests, localizations and `project.yml` entries:

- The widget target (`CCSwitcherWidget/`), `Shared/WidgetData.swift`, and the app group entitlement
- Sparkle (`UpdateChecker.swift`, `SUFeedURL`, `SUPublicEDKey`, the package)
- Aptabase (`Analytics.swift`, the package)
- GRDB and all usage, cost, and activity stats: `UsageDatabase`,
  `SessionUsageStore`, `SessionTranscriptParser`, `CostParser`, `ActivityParser`,
  `StatsParser`, `PricingService`, `litellm-pricing.json`, `verified-against.json`,
  the cost, activity and chart views, and `Tools/`
- `AutoSwitchEngine`, refresh timers, wake handlers, first-launch auto-capture,
  `refreshBackupInPlace`, `refreshOAuthCredentials`
- The in-app login flow (BROWSER interceptor, auth URL file, pasteboard copy)
  and shell-based CLI discovery (`zsh -ilc`)
- `FileLogger` and the legacy `~/.ccswitcher/backups.json` migration
- `CFBundleURLTypes`
- All localizations except English
- The upstream release workflow (see CI below)

The rewrite will leave most of the remaining upstream sources (`AppState.swift`,
`ClaudeService.swift`, views) unused. Delete them instead of keeping dead code.
Keep `LICENSE` unchanged.

## What to keep or reuse

- `KeychainService.claudeJSON(_:replacingOAuthAccount:)` and its atomic
  `~/.claude.json` writer: temp file plus rename, keep permissions, resolve
  symlinks. Keep `ClaudeJSONRewriteTests`. Close the gap where a write can
  slip in between the mtime check and the rename: re-check the mtime right
  before the rename and retry, up to 3 times.
- The request shape from `ClaudeService.getUsageLimits` (headers, decoding of
  `five_hour` and `seven_day`), and the `UsageAPIResponse` model.
- The `AnyCodable` helper, if it's still needed.

## Architecture

Single macOS app target. No third-party dependencies. Use SwiftUI
`MenuBarExtra` with `.menuBarExtraStyle(.menu)` so the menu looks like a native
NSMenu: a section header, a checkmark on the active account, a separator, then
actions.

```
Sources
  App.swift                 MenuBarExtra + Settings window (rename/remove)
  Model/SavedAccount.swift  id, label, email, orgUuid, orgName, plan (no secrets)
  Model/Envelope.swift      pure functions: parse, replace claudeAiOauth, validate
  Keychain/ClaudeItem.swift read via `security find-generic-password -w`;
                            write via `security -i` + stdin + `-X <hex>`; no delete
  Keychain/AccountStore.swift  one SecItem generic password per account
  ClaudeConfig.swift        ~/.claude.json oauthAccount read/rewrite
  Switcher.swift            actor; the only code that mutates credentials
  UsageClient.swift         the only URLSession use in the app
  SessionGuard.swift        detects running Claude Code processes
```

Wrap every external dependency (Claude item, account store, config file,
process list, clock, HTTP) in a protocol, so tests can drive `Switcher` with
fakes.

### Storage

- **Account metadata** (no secrets) goes in `UserDefaults`, key `accounts.v1`.
- **Credentials:** one generic-password item per account.
  - service `com.adarshchbs.ccswitcher.account`, account `<SavedAccount.id>`
  - data: JSON `{ "claudeAiOauth": {...}, "oauthAccount": {...} }`
  - add with `kSecAttrSynchronizable: false` and set it explicitly
  - write with `SecItemUpdate`, falling back to `SecItemAdd` only on `errSecItemNotFound`
- **Usage cache** goes in `UserDefaults`: percentages, reset times, and the
  `fetchedAt` time per account. No tokens.

### Claude Code's Keychain item

- service `Claude Code-credentials`, account `NSUserName()`, login keychain.
- **Read:** `/usr/bin/security find-generic-password -s <svc> -a <acct> -w`.
- **Write:** start `/usr/bin/security -i` and write this to stdin:
  `add-generic-password -U -s "Claude Code-credentials" -a "<acct>" -X <hex>\n`
  then close stdin. Check the exit status and stderr. `<acct>` must match
  `^[A-Za-z0-9._-]+$`, otherwise refuse. Never delete the item.
- Let tests aim it at a temporary keychain by passing a keychain path as the
  final argument. **Tests must never touch the login keychain.**

## Operations

All of these run inside `Switcher` (an actor), one at a time. If an operation
is already running, reject the new one with a visible message.

### Save current login

Menu: "Save current login…"

1. Read the live item and `oauthAccount`. Require `claudeAiOauth.accessToken`
   and `refreshToken` to be non-empty, and require `organizationUuid` and
   `emailAddress`.
2. If a saved account has the same `organizationUuid`, update its stored
   credentials. Otherwise create a new account and ask for a label, defaulting
   to `organizationName`.
3. Read the item back to confirm it was written.

The user logs in outside the app (`claude /login`). The app only imports.

### Switch to account X

Triggered only by clicking an account in the menu.

1. **Check for running sessions.** If `SessionGuard` finds live Claude Code
   processes, show a confirmation listing them ("Running Claude sessions may
   keep using the old account until restarted"). Continue only if the user
   confirms.
   - Live processes are those whose executable basename is `claude`, or whose
     PID appears in `~/.claude/sessions/*.json`.
2. **Read live state.** Read the live envelope `E0` and `oauthAccount` `P0`.
   Find the owner `A`, the saved account whose `organizationUuid` equals
   `P0.organizationUuid`.
   - No match: abort with "Save the current login first".
   - `A == X`: there's nothing to do.
3. **Back up A.** Store `{E0.claudeAiOauth, P0}` in A's item. Read it back and
   compare. If that fails, abort; nothing has changed yet.
4. **Check for changes.** Read the live envelope `E1` again. If
   `E1.claudeAiOauth != E0.claudeAiOauth`, go back to step 2. Allow 2 retries,
   then abort.
5. **Write the Claude item.** Write `E1` with `claudeAiOauth` replaced by X's
   stored value. Every other key stays as it is in `E1`.
6. **Write the profile.** Set `~/.claude.json` `oauthAccount` to X's stored
   profile.
7. **Verify.**
   - Re-read the item: its `claudeAiOauth.refreshToken` must equal X's.
   - Re-read `oauthAccount`: its `organizationUuid` must equal X's.
8. **Roll back on failure.** If step 5, 6 or 7 fails, write `E1` and `P0` back,
   then verify them. If the rollback also fails, show a blocking alert telling
   the user to run `claude /login` and pick the org.

### Remove account

Delete the Keychain item and check the status. If it fails, leave the
metadata in place and show the error. Never touch the live login. Never
switch implicitly.

### Rename account

Change the label only.

### Usage

Fetch usage when the menu opens (at most once every 60 s), or when the user
clicks "Refresh usage".

For each account:

1. Pick the token. For the active account, use the live item. For the others,
   use the stored item.
2. If `expiresAt` is in the past, don't send a request. Show the cached values
   with "as of <time> · refreshes after switching".
3. Otherwise send the GET. On 401, mark the token expired. Never refresh it.
4. On 429, keep the cached values and back off.

Show it as `5h 42% · 7d 63%` under each account name.

## Menu

```
Claude Account
✓ Team (Acme)        5h 42% · 7d 63%
  Personal            5h 3% · 7d 18%  (as of 14:02)
──────────────
Save current login…
Refresh usage
Settings…              (rename / remove accounts)
──────────────
Quit
```

The menu bar icon shows the active account's label initial, or `?` when the
live owner is unknown.

## Build and signing (`project.yml`)

- `bundleIdPrefix: com.adarshchbs`, app ID `com.adarshchbs.ccswitcher`
- No `DEVELOPMENT_TEAM`. Sign ad hoc with `CODE_SIGN_IDENTITY: "-"`.
- `ENABLE_HARDENED_RUNTIME: YES`
- Not sandboxed, because the app needs `~/.claude.json` and Claude's Keychain
  item. Say this in the README. No entitlements beyond what hardened runtime needs.
- `LSUIElement: true`
- No packages. Set `MARKETING_VERSION` to `3.0.0-fork.1`.

## Tests

Use XCTest. The suite must pass `xcodebuild test` without touching the real
Keychain or `~/.claude*`. Cover:

- **Envelope merge:** replacing `claudeAiOauth` keeps `mcpOAuth` and unknown keys
  byte-for-byte as values.
- **Owner detection:** two accounts with the same email and different org UUIDs
  resolve correctly. With no org match, the result is unknown and the switch
  aborts.
- **Switcher state machine with fakes:**
  - backup failure → no live write
  - item write failure → rollback
  - profile write failure → rollback
  - verify failure → rollback
  - rollback failure → blocking error
  - live token changes between steps 2 and 4 → retry, then abort
  - an operation already in progress → the new one is rejected
- **Usage:** an expired token sends no request. A 401 marks it expired and
  never triggers a refresh.
- **`ClaudeItem` against a temporary keychain** (`security create-keychain` in
  a temp dir, deleted in teardown):
  - a round trip of a 16 KB payload containing quotes, spaces and unicode
  - `-U` updates in place
  - a bad account name is refused
  - the argv of the spawned process never contains the payload
- **`ClaudeJSONRewriteTests`** (kept from upstream)

## CI

Replace `.github/workflows/build.yml` with a single test workflow:

- runs on `pull_request` and `push`
- `permissions: contents: read`
- no secrets, no signing, no release
- runs `xcodegen` and `xcodebuild test`

Pin actions by SHA.

## Static checks (part of the test suite)

These tests read the source tree:

- `URLSession` appears only in `UsageClient.swift`.
- No `"-w"` argument appears next to a write call in `ClaudeItem.swift`.
- None of these strings appear: `oauth/token`, `Sparkle`, `Aptabase`,
  `GRDB`, `FileLog`.

## README

Add a short "About this fork" section at the top:

- what it is
- the differences from upstream (link this spec)
- the link to upstream
- MIT attribution
- how to build: `brew install xcodegen && xcodegen && xcodebuild ...`
- the first switch shows a Keychain prompt. Since the build is signed ad hoc,
  you may be asked again after each rebuild.

## Deviations

Places where the implementation differs from the text above, and why.

1. **`security -i` can't take a 16 KB payload.** `security -i` reads its
   input in 4096-byte chunks. A longer line gets split, and each piece runs as
   its own command. The first piece is a valid `add-generic-password` with a
   truncated `-X` value and no keychain argument, so it writes a corrupt
   password to the default keychain. (Seen while probing: a cut-off test
   command wrote a junk item to the login keychain.) Changes:
   - `ClaudeItem` refuses any command line over 4000 bytes (`maxCommandBytes`)
     before it starts `security`. With the real service name and a short
     account name, that allows an envelope of about 1,960 bytes of JSON.
   - Before writing anything, `Switcher` checks that both the new envelope
     and the rollback envelope fit. If either doesn't, the switch aborts with
     `tooLargeToWrite` and nothing has changed.
   - The 16 KB round-trip test became two tests. One round-trips the largest
     payload that fits, with quotes, spaces and unicode. The other checks that
     a 16 KB payload is refused without starting `security`.
   - **Open decision:** if Claude Code's real envelope (with `mcpOAuth`
     entries) is larger than about 1.9 KB, every switch will be refused. The
     alternative that keeps secrets out of argv is writing the item
     in-process with `SecItemUpdate`. That changes which process the item's
     ACL sees, and it brings Keychain prompts that may need the login
     password. It needs the owner's call, so it isn't implemented.
2. **`find-generic-password -w` prints hex for non-ASCII data.** When the
   password isn't printable ASCII, `security` prints it as hex. `ClaudeItem`
   decodes the output as hex when it doesn't start with `{`.
3. **Usage runs partly outside `Switcher`.** Reading the tokens runs on the
   `Switcher` actor and is refused while another operation is running. It
   doesn't mark the switcher busy, though, and the HTTP requests run outside
   the actor, so a slow request never blocks or rejects a switch.
4. **Rollback is judged by verification.** The rollback attempts both writes
   (item, then profile) even if one fails, then verifies the restored state:
   the refresh token, plus `organizationUuid`. A write that failed before
   changing anything still counts as a successful rollback. A failed
   verification shows the blocking alert.
5. **Extra fail-closed check.** The switch aborts (`liveLoginMismatch`) when
   the live item already holds the target's refresh token while
   `oauthAccount` names a different account, because then it's unclear who
   owns the live credential.
6. **Owner detection.** If more than one saved account has the same
   `organizationUuid`, the owner counts as unknown. (Save never creates such
   duplicates.)
7. **Files beyond the architecture tree.** These were added:
   - `AppModel.swift` (menu state and actions)
   - `Prompts.swift` (NSAlert dialogs)
   - `Model/AnyCodable.swift`
   - `StoredLogin`, the saved item's format, in `AccountStore.swift`

   `AccountStore` takes an optional `SecKeychain` so tests can aim it at a
   temp keychain. It also sets `kSecUseDataProtectionKeychain: false`, so
   items always go to the file-based login keychain.
8. **`~/.claude.json` writer.** The check before the rename compares the
   modification time (to the nanosecond), size and inode. The temp file is
   created with `O_EXCL` and mode 0600, then given the original file's mode.
   (Upstream's temp file briefly had the default umask permissions.)
9. **Session detection.** Besides executables named `claude`, a process
   whose start name (`p_comm`) is `claude` also counts. Claude Code's native
   installer runs a versioned binary through a `claude` symlink.
10. **Menu row layout.** SwiftUI menu items are one line, so usage sits on the
    account's row (as in the menu sketch) instead of under the name.
11. **Static checks go further.** They also require the usage endpoint to be
    the only URL in the sources, and they ban `Timer`, `didWakeNotification`,
    `CFBundleURLTypes`, `WidgetKit`, `AppIntents`, `zsh`, `print(`, `NSLog(`
    and `.environment`.
12. **Docs.** The README was replaced, not prepended to. Upstream's version
    describes features that no longer exist (widgets, auto-update, analytics,
    the login flow). Upstream-only docs, release tooling and screenshots were
    deleted with the features: `ARCHITECTURE.md`, `BUILD_GUIDE.md`,
    `MACOS_APP_PLAYBOOK.md`, `COST_VERIFICATION.md`, `RELEASE_NOTES.md`, the
    translated READMEs, `docs/` except this spec, `scripts/release.sh` and
    `.claude/commands/release.md`. `AGENTS.md` now describes the fork.
13. **No `get-task-allow` in Release.** Xcode adds the
    `com.apple.security.get-task-allow` entitlement to ad hoc builds, which
    would let other processes attach to the app and read its memory.
    `project.yml` sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release,
    so the Release app has no entitlements at all.
