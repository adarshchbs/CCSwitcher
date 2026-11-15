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
- **No secret on a command line.** The app writes Claude Code's Keychain item
  through `security -i`, with the hex-encoded secret on stdin. It refuses
  envelopes too long for one `security -i` line (about 1.9 KB of JSON) rather
  than put them in argv.
- **The app never calls the OAuth token endpoint.** Claude Code refreshes its
  own tokens.
- **One network request:** `GET https://api.anthropic.com/api/oauth/usage`. No
  analytics, updater, pricing fetch or version check.
- **A switch swaps only `claudeAiOauth`.** It keeps `mcpOAuth` and every other
  key in Claude Code's item byte for byte. Before writing, it backs up the
  current login and reads the backup back. Afterward it verifies the result
  and rolls back on failure.
- **No file logs.** Logging goes through `os.Logger`, with emails, org names
  and UUIDs marked private.
- Removed: Sparkle, Aptabase, GRDB, the cost/activity stats, the desktop
  widget, the in-app login flow, and the translations.

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

## Using it

1. In a terminal, run `claude /login` and pick the first organization. Then
   choose **Save current login…** from the menu and name it.
2. Run `claude /login` again, pick the other organization, and save that too.
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
