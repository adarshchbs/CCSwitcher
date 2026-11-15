<p align="center">
  <img src="assets/CCSwitcher-icon.png" width="88" alt="">
</p>

<h1 align="center">CCSwitcher</h1>

<p align="center">
  Switch Claude Code between your Team and Personal logins from the menu bar.<br>
  Only when you click.
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/ui-dark.png">
    <img src="docs/assets/ui-light.png" width="392" alt="The CCSwitcher panel: Team and Personal accounts, each with Session and Weekly usage bars showing how much is left. Personal is active and tagged new sessions.">
  </picture>
</p>

<p align="center">
  Each account keeps its own color. Bars show how much of each limit is left.<br>
  The tagged account is the one new Claude sessions will use.
</p>

## Install

Paste this into Claude Code or Codex on your Mac:

```text
Install CCSwitcher on this Mac by following https://raw.githubusercontent.com/adarshchbs/CCSwitcher/manual-switch-hardened/docs/INSTALL.md
```

The agent builds the app from source, runs the tests and tells you how to save your first two logins.

## What one click does

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/switch-dark.svg">
  <img src="docs/assets/switch-light.svg" width="100%" alt="Switching to Personal: 1. back up Team's login, 2. swap only claudeAiOauth in Claude Code's Keychain item, 3. write Personal into ~/.claude.json, 4. ask Anthropic who owns the token. Any failure puts the backup back.">
</picture>

## After a switch

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sessions-dark.svg">
  <img src="docs/assets/sessions-light.svg" width="100%" alt="Timeline: sessions started before the switch keep Team until restarted, and a token refresh in one can write Team back. Sessions started after the switch use Personal.">
</picture>

Restart Claude Code (or T3 Code) after a switch, so every session picks up the new login.

## How this fork differs from upstream

This is a fork of [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher), cut down after a security audit. Each diagram shows upstream's behavior on the left and this fork's on the right.

**1. Accounts change only when you click.**

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 630}}}%%
flowchart LR
  subgraph Upstream
    direction TB
    u1["Usage nears a limit"] --> u2["Account switches on its own<br/>auto-switch engine, timers, wake handler"]
  end
  subgraph Fork
    direction TB
    f1["Usage nears a limit"] --> f2["The panel shows the numbers<br/>a switch waits for your click"]
  end
  Upstream ~~~ Fork
  classDef broke fill:#FCEBEB,stroke:#A32D2D,color:#791F1F
  classDef fixed fill:#EAF3DE,stroke:#3B6D11,color:#27500A
  classDef later fill:#FFFFFF,stroke:#888780,stroke-dasharray:5 5,color:#444441
  class u2 broke
  class f2 fixed
```

**2. Tokens stay off the command line.**

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 630}}}%%
flowchart LR
  subgraph Upstream
    direction TB
    u1["A switch writes the token"] --> u2["Token visible to any process<br/>passed as an argument to security -w"]
  end
  subgraph Fork
    direction TB
    f1["A switch writes the token"] --> f2["Token stays in the app's memory<br/>written in-process with SecItemUpdate"]
  end
  Upstream ~~~ Fork
  classDef broke fill:#FCEBEB,stroke:#A32D2D,color:#791F1F
  classDef fixed fill:#EAF3DE,stroke:#3B6D11,color:#27500A
  classDef later fill:#FFFFFF,stroke:#888780,stroke-dasharray:5 5,color:#444441
  class u2 broke
  class f2 fixed
```

**3. Only Claude Code refreshes its tokens.**

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 630}}}%%
flowchart LR
  subgraph Upstream
    direction TB
    u1["A token nears expiry"] --> u2["The app refreshes it itself<br/>rotating the refresh token Claude Code holds"]
  end
  subgraph Fork
    direction TB
    f1["A token nears expiry"] --> f2["Claude Code refreshes it<br/>the app never calls the token endpoint"]
  end
  Upstream ~~~ Fork
  classDef broke fill:#FCEBEB,stroke:#A32D2D,color:#791F1F
  classDef fixed fill:#EAF3DE,stroke:#3B6D11,color:#27500A
  classDef later fill:#FFFFFF,stroke:#888780,stroke-dasharray:5 5,color:#444441
  class u2 broke
  class f2 fixed
```

**4. A saved login is proven to belong to its organization.**

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 630}}}%%
flowchart LR
  subgraph Upstream
    direction TB
    u1["Save the live login"] --> u2["Owner read from ~/.claude.json<br/>running sessions rewrite that file"]
  end
  subgraph Fork
    direction TB
    f1["Save the live login"] --> f2["Owner proven first<br/>matching refresh token, or Anthropic's profile answer"]
  end
  Upstream ~~~ Fork
  classDef broke fill:#FCEBEB,stroke:#A32D2D,color:#791F1F
  classDef fixed fill:#EAF3DE,stroke:#3B6D11,color:#27500A
  classDef later fill:#FFFFFF,stroke:#888780,stroke-dasharray:5 5,color:#444441
  class u2 broke
  class f2 fixed
```

**5. Nothing phones home.**

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 630}}}%%
flowchart LR
  subgraph Upstream
    direction TB
    u1["The app runs"] --> u2["Analytics and update checks<br/>Aptabase and Sparkle"]
  end
  subgraph Fork
    direction TB
    f1["The app runs"] --> f2["Two Anthropic requests, on menu open<br/>usage and profile, nothing else"]
  end
  Upstream ~~~ Fork
  classDef broke fill:#FCEBEB,stroke:#A32D2D,color:#791F1F
  classDef fixed fill:#EAF3DE,stroke:#3B6D11,color:#27500A
  classDef later fill:#FFFFFF,stroke:#888780,stroke-dasharray:5 5,color:#444441
  class u2 broke
  class f2 fixed
```

[docs/FORK_SPEC.md](docs/FORK_SPEC.md) has the full rules and the audit's reasoning.

<details>
<summary><b>Known risks</b></summary>

Claude Code offers no lock or switching API, so these remain:

- **Token refresh race.** If Claude Code rotates its token in the milliseconds between the switch's read and write, the account you left needs `claude /login`.
- **`~/.claude.json` race.** A write Claude Code makes between the app's last check and its rename is lost.
- **Running sessions keep the old login** and can write it back when their token refreshes. The panel warns you; restart them.
- **The ownership check trusts Anthropic's profile endpoint** when the token matches no saved login. If it's unreachable, the app refuses to save or switch.

</details>

---

<sub>The original code is © 2026 XueshiQiao under the MIT License (see [LICENSE](LICENSE)). This fork keeps the same license.</sub>
