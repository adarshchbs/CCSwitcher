# CCSwitcher (manual-only hardened fork): agent guidelines

**Rules**
- `docs/FORK_SPEC.md` is the spec. Every rule there came out of a security audit; don't relax one without asking.
- `project.yml` is the only source of truth for the Xcode project. Never edit `.pbxproj` or `Info.plist`; run `xcodegen generate` after changes. `CCSwitcher.xcodeproj` is disposable (git-ignored).
- Tests must never touch the login keychain, Claude Code's `Claude Code-credentials` item, `~/.claude.json` or `~/.claude/`. Use `TempKeychain`, temp files and the fakes in `CCSwitcherTests/Fakes.swift`.
- Never launch the app from an agent session.

**Files** (`Sources/`)
- `App.swift`: `MenuBarExtra` menu and the Settings window. `AppModel.swift`: menu state and actions. `Prompts.swift`: modal alerts.
- `Switcher.swift`: the only code that changes credentials (save, switch, remove, rename).
- `Keychain/ClaudeItem.swift`: Claude Code's item via `/usr/bin/security`. `Keychain/AccountStore.swift`: one Keychain item per saved account.
- `ClaudeConfig.swift`: the `oauthAccount` block of `~/.claude.json`.
- `Model/Envelope.swift`: splices `claudeAiOauth` into the item's JSON without touching other bytes.
- `UsageClient.swift`: the only network code. `SessionGuard.swift`: running Claude Code processes.
