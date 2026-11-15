# CCSwitcher, manual-only hardened fork

## About this fork

A macOS menu bar app that switches Claude Code between saved logins, and only
when you click. It was built for one person with two logins under one email
address (a company Team org and a personal org). It tells them apart by
organization UUID, never by email.

This is a fork of [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher),
cut down after a security audit of upstream. [docs/FORK_SPEC.md](docs/FORK_SPEC.md)
has the full rules, and its Deviations section lists where this build differs
from them. Compared with upstream:

- **Nothing changes credentials without a click.** No timers, wake handlers,
  auto-switch, background token refresh, URL scheme, widget or launch-time
  capture.
- **No secret on a command line.** The app reads Claude Code's Keychain item
  with `security find-generic-password -w` (the secret comes back on stdout)
  or, during a switch, in-process with `SecItemCopyMatching`, and writes it
  in-process with `SecItemUpdate`. It never creates or deletes the item. The
  first switch asks you to let CCSwitcher read the item; that dialog comes
  before anything changes. Because the build is signed ad hoc, macOS may ask
  again after each rebuild.
- **The app never calls the OAuth token endpoint.** Claude Code refreshes its
  own tokens.
- **Two network requests:** `GET https://api.anthropic.com/api/oauth/usage`
  and `GET https://api.anthropic.com/api/oauth/profile`, through one ephemeral
  session with no cache that refuses redirects. No analytics, updater,
  pricing fetch or version check.
- **It proves whose login it's saving.** Both logins share one email, so
  before saving or backing up a login the app checks which organization it
  belongs to: either the refresh token matches the one already saved for
  that organization, or the profile endpoint says so for the (unexpired)
  access token. Only the access token is sent. If neither works (an expired
  token, no network), it changes nothing and tells you to use Claude Code once
  so it refreshes. The menu also warns when the live login provably belongs to
  a different organization than `~/.claude.json` names.
- **A switch swaps only `claudeAiOauth`.** It keeps `mcpOAuth` and every other
  key in Claude Code's item byte for byte. Before writing, it backs up the
  current login (keeping the one it replaces, which Settings can restore) and
  reads the backup back. Afterward it verifies the result and rolls back on
  failure, unless Claude Code changed the item in the meantime.
- **An interrupted switch is noticed.** If the app dies mid-switch, the next
  launch blocks switching and asks whether to restore the previous login or
  leave things as they are.
- **No file logs.** Logging goes through `os.Logger`, with emails, org names
  and UUIDs marked private.
- **Add account runs Claude Code's own login.** After a confirmation, the app
  backs up the current login and runs `claude auth login --claudeai` from a
  fixed path (`~/.local/bin/claude`, `/opt/homebrew/bin/claude` or
  `/usr/local/bin/claude`), with no shell and a minimal environment. It
  never reads, logs or shows the CLI's output. It saves the new login only
  after the profile endpoint confirms its organization.
- Removed: Sparkle, Aptabase, GRDB, the cost/activity stats, the desktop
  widget, upstream's in-app login flow (browser interceptor, URL handling,
  shell-based CLI lookup), and the translations.

The original code is © 2026 XueshiQiao, under the MIT License (see
[LICENSE](LICENSE)). This fork keeps the same license.

### Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Release -derivedDataPath build build
open build/Build/Products/Release   # CCSwitcher.app is here
```

Run the tests with:

```sh
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher test
```

The tests never touch your login keychain or `~/.claude*`. They use a
keychain created in a temp directory, plus temp files and fakes.

The build is signed ad hoc with hardened runtime on. It is **not sandboxed**,
because it has to read and write `~/.claude.json` and Claude Code's Keychain
item. It has no entitlements.

The first switch shows a Keychain prompt. Since every build has a new ad hoc
signature, macOS may ask again after each rebuild.

## Known risks

These remain after the hardening, because Claude Code offers nothing to
coordinate with (no lock, no API for switching accounts):

- **Token refresh race.** Claude Code can refresh and rotate its token at any
  moment. The switch re-reads the Keychain item in-process and writes it right
  after, with no process spawned in between, but a few milliseconds remain
  between that read and the write. If Claude Code rotates the token in that
  window, the switch overwrites the new token and the account you switched
  away from needs `claude /login`. Rollback won't overwrite an item that
  changed after the switch wrote it.
- **`~/.claude.json` race.** The profile write re-checks the file's mtime,
  size and inode right before renaming the new file over it, and retries up to
  3 times. A write Claude Code makes between that last check and the rename
  is still lost.
- **The ownership check trusts one Anthropic endpoint** when the token
  doesn't match a saved login. If the profile endpoint is unreachable, the
  app refuses to save or switch rather than guess.

## Using it

1. In a terminal, run `claude /login` and pick the first organization. Then
   choose **Save current login…** from the menu and name it.
2. Choose **Add account…**. The app backs up the current login, then your
   browser opens; pick the other organization there and name the new account
   when the app asks. The menu shows "Waiting for sign-in in your browser…"
   with **Cancel sign-in** until you finish (or 10 minutes pass). If you
   cancel the naming step, the new login stays active but unsaved; **Save
   current login…** saves it.
3. Click an account in the menu to switch. If Claude Code sessions are
   running, the app lists them first, because they may keep using the old
   account until you restart them.

The menu bar shows the first letter of the active account's name, or `?` when
the current login isn't one you saved. Each row shows 5-hour and 7-day usage.
The app reads usage when you open the menu (at most once a minute) or choose
**Refresh usage**. When a saved token has expired, the row shows the last
values it read, which update after you switch to that account. **Settings…**
renames and removes accounts. Removing an account deletes its saved login and
leaves the current Claude login alone.
