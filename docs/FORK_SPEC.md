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
   Keychain item in-process with `SecItemUpdate` (see Deviation 1; the
   original `security -i` plan can't carry a real-sized envelope). Reading with
   `security find-generic-password -w` is fine, since the secret comes back on
   stdout, and so is an in-process `SecItemCopyMatching` (Deviation 14).
2. **Nothing changes credentials without a click.** No timers, wake
   handlers, launch-time capture, auto-switch, background refresh, URL
   scheme, intents or widget.
3. **The app never calls the OAuth token endpoint.** Delete every refresh
   path. Claude Code refreshes its own tokens.
4. **The only outbound requests are** `GET https://api.anthropic.com/api/oauth/usage`
   and `GET https://api.anthropic.com/api/oauth/profile`. The profile request
   proves which organization an access token belongs to (see "Ownership
   check"); it sends the access token only, never the refresh token. Both use
   one ephemeral `URLSession` with no URL cache that refuses every redirect.
   No analytics, updater, pricing fetch, or version check.
5. **Swap only `claudeAiOauth`.** When switching, read the live envelope fresh
   and replace only its `claudeAiOauth` key. Keep `mcpOAuth` and every other
   key exactly as they are. Saved accounts store only `claudeAiOauth`, plus the
   `oauthAccount` profile block.
6. **Fail closed.** If you're unsure who owns the live credential, or a backup
   or verification fails, abort and leave the live login as it is. A network
   failure during the ownership check counts as unsure, never as a pass.
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
  - data: JSON `{ "claudeAiOauth": {...}, "oauthAccount": {...}, "previous": {...} }`.
    `previous` is the login this one replaced (same two keys, one
    generation). Overwriting a saved login moves it there, unless the
    `claudeAiOauth` bytes are unchanged; then the older `previous` stays.
  - add with `kSecAttrSynchronizable: false` and set it explicitly
  - write with `SecItemUpdate`, falling back to `SecItemAdd` only on `errSecItemNotFound`
- **Usage cache** goes in `UserDefaults`: percentages, reset times, and the
  `fetchedAt` time per account. No tokens.

### Claude Code's Keychain item

- service `Claude Code-credentials`, account `NSUserName()`, in the user's
  default keychain.
- **Pinned keychain:** resolve the default keychain once with
  `SecKeychainCopyDomainDefault(.user)`. Pass its path to every `security`
  call, and its ref (`kSecMatchSearchList`, `kSecUseKeychain`) to every
  `SecItem` call in `ClaudeItem` and `AccountStore`.
- **Read:** `/usr/bin/security find-generic-password -s <svc> -a <acct> -w <keychain>`
  for every read outside a switch's critical window. Inside it (pre-flight,
  final re-read, rollback re-read), read in-process with `SecItemCopyMatching`.
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
3. **Prove ownership** of the live pair with `verifyOwner(login,
   organizationUuid)` (see "Ownership check") before storing anything.
4. Store it, keeping the account's old saved login as `previous`. Read the
   item back to confirm it was written.

The user logs in outside the app (`claude /login`). The app only imports.

### Switch to account X

Triggered only by clicking an account in the menu.

1. **Check for running sessions.** If `SessionGuard` finds live Claude Code
   processes, show a confirmation listing them ("Running Claude sessions may
   keep using the old account until restarted"). Continue only if the user
   confirms.
   - Live processes are those whose executable basename is `claude`, or whose
     PID appears in `~/.claude/sessions/*.json`.
   - **Pin the item.** Count the items matching Claude's service and account
     across the whole keychain search list (attributes only, no data,
     `kSecMatchLimitAll`). Require exactly one, in the pinned keychain.
     Otherwise abort and say which keychains hold copies.
   - **Pre-authorize.** Read Claude's item in-process and discard the data.
     This is the read that can show the Keychain dialog; doing it now keeps
     the dialog out of the window between the last read and the write. A
     declined dialog aborts here, before anything changes.
2. **Read live state.** Read the live envelope `E0` and `oauthAccount` `P0`
   (through `security`). Find the owner `A`, the saved account whose
   `organizationUuid` equals `P0.organizationUuid`.
   - No match: abort with "Save the current login first".
   - `A == X`: there's nothing to do.
   - `E0` holds X's refresh token: abort (`liveLoginMismatch`).
   - **Prove ownership** with `verifyOwner(E0.claudeAiOauth, A.organizationUuid)`.
     Abort if it fails.
3. **Back up A.** Store `{E0.claudeAiOauth, P0}` in A's item, moving A's old
   saved login to `previous`. Read it back and compare. If that fails, abort;
   nothing has changed yet.
4. **Journal.** Persist `{fromId: A, toId: X, startedAt}` in `UserDefaults`
   (key `pendingSwitch.v1`, no secrets).
5. **Re-read and write, back to back.** Read the item in-process (`E1`). If
   `E1.claudeAiOauth != E0.claudeAiOauth`, write nothing, clear the journal
   and go back to step 2 (2 retries, then abort). Otherwise write `E1` with
   `claudeAiOauth` replaced by X's stored value right away with
   `SecItemUpdate`; every other key stays as it is in `E1`. No process is
   spawned between this read and the write.
6. **Write the profile.** Set `~/.claude.json` `oauthAccount` to X's stored
   profile.
7. **Verify.**
   - Re-read the item: its `claudeAiOauth.refreshToken` must equal X's.
   - Re-read `oauthAccount`: its `organizationUuid` must equal X's.
   - Then clear the journal.
8. **Roll back on failure.** If step 5, 6 or 7 fails:
   - Re-read the item in-process. Restore `E1` only if the item holds exactly
     what step 5 wrote, or still holds `E1`. Anything else means Claude Code
     changed it since (it may have rotated X's token), so stop with
     `rollbackSkipped` and leave the item and profile alone.
   - Restore `P0` if `oauthAccount` differs from it.
   - Verify the restored state and clear the journal. If that verification
     fails, or the rollback was skipped, keep the journal and show a blocking
     alert telling the user to run `claude /login` and pick the org.

### Ownership check

`verifyOwner(login, expectedOrgUuid)` passes if either holds:

- (b) the live refresh token is byte-equal to the refresh token in the saved
  login of the account with `expectedOrgUuid` (which was verified when it was
  stored); or
- (a) the access token is unexpired and
  `GET https://api.anthropic.com/api/oauth/profile` with
  `Authorization: Bearer <accessToken>` returns `organization.uuid ==
  expectedOrgUuid`.

(b) is checked first, so a match needs no request. It fails if the refresh
token is byte-equal to a **different** saved account's refresh token, even
if (a) would pass. It fails closed in every other case: an expired token with
no match ("Can't confirm which organization the current Claude login belongs
to: its access token has expired and it doesn't match a saved login. Use
Claude Code once so it refreshes, then try again."), a 401/403, a network
error, or another account's saved login that can't be read (a cross-account
match can't be ruled out).

It runs in three places: Save (step 3), Switch (step 2), and a detect-only
status check when the app starts and when the menu opens (at most once a
minute, with usage). The status check shows "Live login doesn't match
~/.claude.json" in the menu when the live token is provably another
organization's. It never fixes anything.

### Unfinished switch

A journal present at launch or before any operation means a switch was
interrupted between steps 4 and 7. Every operation except the two below is
then refused, and the app shows a recovery alert. Nothing runs on its own.

- **Restore <from>:** if the live login provably belongs to `to` (or `from`)
  by the ownership check, back it up to that account first, since it may be
  the only valid copy. If neither can be proven, abort and change nothing.
  Then write from's saved `claudeAiOauth` into the item (same compare and
  write as step 5), write from's profile, verify, and clear the journal.
- **I've fixed it:** clear the journal. Nothing else changes.

### Restore previous saved login

Settings has a "Restore previous saved login…" button per account. After a
confirmation it swaps the account's saved login with `previous`, so doing it
again swaps back. It refuses a `previous` from another organization, and it
never touches the live login.

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
- **Ownership:** an unexpired token from another org fails; an expired token
  matching the saved backup passes with no request; an expired token with no
  match fails closed; a cross-account refresh token match fails; a network
  error fails closed; Save stores `previous`; Restore previous swaps back.
- **Rollback** is skipped when the item changed after the switch wrote it.
- **Journal:** written before the item write and cleared on success; a crash
  right after the item write blocks every operation on the next launch until
  "Restore" or "I've fixed it".
- **Pinning:** a second temp keychain holding the item, on an injected search
  list, makes the switch abort. The user's search list is never touched.
- **Redirects:** the session's delegate refuses them.
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
- The only URLs in the sources are the usage and profile endpoints.
- No `"-w"` argument appears next to a write call in `ClaudeItem.swift`, and
  nothing between `ClaudeItem.update`'s in-process read and its
  `SecItemUpdate` can spawn a process.
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

1. **Writes use `SecItemUpdate`, not `security -i`.** This supersedes Hard
   rule 1's write method and the "Claude Code's Keychain item → Write" section.
   - Why: `security -i` reads its input in 4096-byte chunks. A longer line gets
     split, and each piece runs as its own command. The first piece is a valid
     `add-generic-password` with a truncated `-X` value and no keychain
     argument, so it writes a corrupt password to the default keychain. (Seen
     while probing: a cut-off test command wrote a junk item to the login
     keychain. That item has since been deleted.) The owner's real envelope is
     2,932 bytes of JSON (`mcpOAuth` is 2,361 of them), about 5.9 KB as hex,
     so `security -i` could never write it.
   - Now: `ClaudeItem.write` calls `SecItemUpdate` on the existing item and
     changes only `kSecValueData`. It throws `.notFound` rather than creating an
     item, and nothing deletes one. Reads still go through
     `security find-generic-password -w`, which the item already trusts, so
     reads never prompt. No secret goes in argv or the environment, so Hard
     rule 1 still holds.
   - Cost: the first switch shows a Keychain dialog asking to let CCSwitcher
     change the item. Ad hoc signing means it can come back after a rebuild.
   - Tests: `testUpdateLeavesAccessListUnchanged` checks that an update leaves
     the item's access list and partition IDs exactly as they were.
     `testRoundTrips16KBPayloadWithQuotesSpacesAndUnicode` restores the
     spec's 16 KB case. A static check bans `security -i`, `-X`,
     `add-generic-password`, `SecItemAdd` and `SecItemDelete` in
     `ClaudeItem.swift`. Test items are seeded through `security` with `-A`
     and an `apple-tool:,apple:,unsigned:` partition list on the temp
     keychain only, so the suite never shows a dialog.
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
14. **Security review fixes (proof of ownership, race narrowing, journal,
    pinning, redirects).** This round adds the "Ownership check", "Unfinished
    switch" and "Restore previous saved login" sections and steps 1, 4, 5 and
    8 of the switch as written above. Notes on how it was built:
    - **What the Keychain dialog guards.** Probed on a temp keychain with
      Keychain UI disabled (so a would-be prompt fails with `-25308` instead):
      on an item created by `security add-generic-password`, an app outside
      the access list gets `errSecAuthFailed` reading the data but succeeds
      with `SecItemUpdate`. The item's ACL gives `encrypt` (which covers
      writing the data) to every app and `decrypt` only to `/usr/bin/security`.
      So the write never prompts, and the only dialog is for the in-process
      read. This corrects Deviation 1's "Cost" note: the first switch asks to
      let CCSwitcher **read** the item. Pre-authorizing therefore can't cover
      the write, and doesn't need to; it gets the read dialog done before the
      critical window. Not verified against the owner's real item (tests
      never touch it); it assumes Claude Code created it with `security`'s
      default ACL.
    - **Reads.** `security` stays for every read outside the critical window
      (status, usage, save, verify), because it never prompts: the item
      already trusts `/usr/bin/security`. In-process reads would show the
      dialog on menu open, without a click, and again after every ad hoc
      rebuild. Inside a switch, all reads are in-process.
    - **Residual race.** A few milliseconds remain between the in-process
      read and `SecItemUpdate`, and between the last `~/.claude.json`
      fingerprint check and the rename. Claude Code has no lock to coordinate
      on. The README lists both under "Known risks".
    - **Rollback leaves `~/.claude.json` alone when it already equals `P0`**,
      to avoid a needless rewrite that could race Claude Code.
    - **Restore previous swaps** current and `previous` instead of dropping
      the current login, so it can be undone.
    - **A journal that no longer decodes** still counts as an unfinished
      switch (with no account names), so it can't unblock switching by
      accident. "I've fixed it" clears it.
    - **Duplicate keys** inside `claudeAiOauth` (in Claude's item and in saved
      logins) and inside `oauthAccount` (in saved logins and in
      `~/.claude.json`) are now rejected at any depth, escaped spellings
      included. Other members (`mcpOAuth`) keep theirs untouched. A duplicate
      top-level key in `~/.claude.json` also makes the profile unreadable.
    - `ClaudeItem.decodePassword` accepts leading JSON whitespace.
    - New file `Model/PendingSwitch.swift` (the journal). `ProfileClient`
      lives in `UsageClient.swift`, which stays the only network code.
    - The status check runs at launch as well as on menu open. It reads, and
      may call the profile endpoint, but never changes anything (Hard rule 2).
