# Install CCSwitcher

You are a coding agent installing CCSwitcher, a macOS menu bar app that switches Claude Code between saved logins. You build it from source, install it to `~/Applications`, and hand off to the user.

The user owns every Claude login. Your job ends at a running app. The user saves and switches logins from its menu. Leave `~/.claude.json`, `~/.claude/` and the Keychain item `Claude Code-credentials` exactly as you found them. The user runs every Claude sign-in themselves.

Run the steps in order. Each ends on a check. If a check fails, stop and show the user the command and its last 20 lines of output.

## 1. Check the Mac

| Check | Passes when |
| --- | --- |
| `sw_vers -productVersion` | 14.0 or later |
| `xcodebuild -version` | Xcode 26 or later. The glass panel needs the macOS 26 SDK. If it says the active developer directory is the Command Line Tools, the user must install Xcode from the App Store, open it once, and run `sudo xcode-select -s /Applications/Xcode.app`. |
| `brew --version` | prints a version |
| `ls ~/.local/bin/claude /opt/homebrew/bin/claude /usr/local/bin/claude 2>/dev/null` | lists at least one path. **Add account** runs `claude` from these paths only. |

Done when all four pass.

## 2. Get the source

The fork lives on the `manual-switch-hardened` branch. The default branch, `main`, holds upstream's code.

- If `~/CCSwitcher` is already a clone: `git -C ~/CCSwitcher fetch origin && git -C ~/CCSwitcher checkout manual-switch-hardened && git -C ~/CCSwitcher pull --ff-only`
- Otherwise: `git clone --branch manual-switch-hardened https://github.com/adarshchbs/CCSwitcher.git ~/CCSwitcher`

Use another directory only if the user named one.

Done when `git -C ~/CCSwitcher rev-parse --abbrev-ref HEAD` prints `manual-switch-hardened` and `git -C ~/CCSwitcher status --porcelain` prints nothing.

## 3. Generate the Xcode project

```sh
command -v xcodegen || brew install xcodegen
cd ~/CCSwitcher && xcodegen generate
```

Done when `~/CCSwitcher/CCSwitcher.xcodeproj` exists.

## 4. Run the tests

```sh
cd ~/CCSwitcher && xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -derivedDataPath build test
```

The tests use a throwaway keychain in a temp directory, temp files and fakes. They run unattended and never open a dialog. If a Keychain password dialog appears anyway, that is a test bug: tell the user to click **Deny**, then stop and report it.

Done when the output ends with `** TEST SUCCEEDED **`.

## 5. Build the app

```sh
cd ~/CCSwitcher && xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Release -derivedDataPath build build
```

Done when the output ends with `** BUILD SUCCEEDED **` and `build/Build/Products/Release/CCSwitcher.app` exists.

## 6. Install and launch

```sh
pkill -x CCSwitcher || true
ditto ~/CCSwitcher/build/Build/Products/Release/CCSwitcher.app ~/Applications/CCSwitcher.app
open ~/Applications/CCSwitcher.app
```

Quit a running copy with `pkill`. `osascript -e 'quit app "CCSwitcher"'` fails with error -128 for this menu bar app.

Done when `pgrep -x CCSwitcher` prints a PID, and `shasum` gives the same hash for both executables:

```sh
shasum ~/CCSwitcher/build/Build/Products/Release/CCSwitcher.app/Contents/MacOS/CCSwitcher ~/Applications/CCSwitcher.app/Contents/MacOS/CCSwitcher
```

## 7. Hand off

Tell the user the installed commit (`git -C ~/CCSwitcher rev-parse --short HEAD`), then these steps, in your own words:

1. Click the person icon in the menu bar to open CCSwitcher.
2. In a terminal, check that `claude` is signed in to the first organization. Then choose **Save current login…** and name it, for example Team.
3. Choose **Add account…**, pick the other organization in the browser, and name it, for example Personal.
4. Click an account to switch. macOS asks to let CCSwitcher use `Claude Code-credentials` and `CCSwitcher saved login`: choose **Always Allow**. The app is signed ad hoc, so macOS asks again after each rebuild.
5. After a switch, restart Claude Code, or quit and reopen T3 Code. Running sessions keep the old login until they restart.

Done when you have sent the commit and all five steps.

## Update

Run steps 2 to 6 again. Saved logins live in the login keychain, so a reinstall keeps them.

## Uninstall

On request only: have the user remove each account in **Settings…** first, which deletes its saved login. Then run `pkill -x CCSwitcher` and move `~/Applications/CCSwitcher.app` to the Trash. Logins left behind stay in the login keychain under the service `com.adarshchbs.ccswitcher.account`, where Keychain Access can delete them.
