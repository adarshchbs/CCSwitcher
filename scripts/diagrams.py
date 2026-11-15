"""Draws the README's two "how it works" diagrams as SVG, light and dark.

Run from the repo root: python3 scripts/diagrams.py
Writes docs/assets/{switch,sessions,install,acts,token}-{light,dark}.svg. The colors match the
app's account palette: indigo for the first account, teal for the second.
"""

from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent.parent / "docs" / "assets"
FONT = '-apple-system, BlinkMacSystemFont, &quot;SF Pro Text&quot;, &quot;Segoe UI&quot;, Helvetica, Arial, sans-serif'
MONO = 'ui-monospace, &quot;SF Mono&quot;, Menlo, Consolas, monospace'

THEMES = {
    "light": dict(rose="#C23F6A", rosefill="#FBEAF0", canvas="#F6F7FB", card="#FFFFFF", edge="#E1E4EC", ink="#1D2030", muted="#646B80",
                  line="#B4BAC8", team="#4C5BD4", teamfill="#ECEEFC", personal="#0F8A7E",
                  personalfill="#E1F3F0", warn="#B4690E", warnfill="#FFF3E2", onaccent="#FFFFFF"),
    "dark": dict(rose="#FF9EB8", rosefill="#3A1F2A", canvas="#151A24", card="#1E2431", edge="#2E3646", ink="#E8EBF3", muted="#9AA1B5",
                 line="#4A5366", team="#9DA8FF", teamfill="#262C4A", personal="#5FD4C4",
                 personalfill="#163431", warn="#F2B45A", warnfill="#3A2E1C", onaccent="#16161A"),
}


def text(x, y, s, size=13, fill="ink", weight=400, anchor="start", mono=False):
    family = MONO if mono else FONT
    return (f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
            f'fill="{{{fill}}}" text-anchor="{anchor}">{escape(s)}</text>')


def chip(x, y, label, color, fill, mono=False, width=None):
    """A rounded label; returns (svg, width)."""
    w = width or int(len(label) * (7.4 if mono else 7.0) + 20)
    return (f'<rect x="{x}" y="{y - 11}" width="{w}" height="22" rx="11" fill="{{{fill}}}" stroke="{{{color}}}" '
            f'stroke-opacity="0.5"/>' + text(x + w / 2, y + 4.5, label, 12, color, 500, "middle", mono)), w


def badge(x, y, letter, color):
    return (f'<circle cx="{x}" cy="{y}" r="10" fill="{{{color}}}"/>'
            + text(x, y + 4.2, letter, 11, "onaccent", 700, "middle"))


def svg(width, height, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">'
            f'<title>{escape(title)}</title>'
            '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{line}"/></marker>'
            '<marker id="warnarrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{warn}"/></marker>'
            + ''.join(f'<marker id="{name}arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                      f'markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" '
                      f'fill="{{{name}}}"/></marker>' for name in ('rose', 'personal')) + '</defs>'
            f'<rect width="{width}" height="{height}" rx="16" fill="{{canvas}}"/>{body}</svg>')


# ---------------------------------------------------------------- switch


def switch_diagram():
    rows = [120, 196, 272, 348]
    parts = []

    # The click that starts everything.
    parts.append(f'<rect x="40" y="30" width="232" height="40" rx="20" fill="{{personalfill}}" '
                 f'stroke="{{personal}}" stroke-opacity="0.6"/>')
    parts.append(text(62, 55, "You click", 14, "ink", 500))
    parts.append(badge(146, 50, "P", "personal"))
    parts.append(text(163, 55, "Personal", 14, "ink", 600))
    parts.append(text(296, 55, "in the menu. Nothing else ever starts a switch.", 13, "muted"))

    # The sequence line through the step numbers.
    parts.append(f'<line x1="58" y1="70" x2="58" y2="{rows[-1]}" stroke="{{line}}" stroke-width="1.5"/>')

    steps = [
        ("Back up the current login", "Team's newest token goes to its saved slot."),
        ("Swap the token", "Only claudeAiOauth changes. MCP logins stay."),
        ("Update the profile", "Personal's org and email go into oauthAccount."),
        ("Check who owns the token", "Anthropic must answer Personal."),
    ]
    for n, ((title, sub), y) in enumerate(zip(steps, rows), start=1):
        parts.append(f'<circle cx="58" cy="{y}" r="14" fill="{{card}}" stroke="{{line}}" stroke-width="1.5"/>')
        parts.append(text(58, y + 4.5, str(n), 13, "ink", 600, "middle"))
        parts.append(text(86, y - 3, title, 15, "ink", 600))
        parts.append(text(86, y + 17, sub, 12.5, "muted"))
        parts.append(f'<line x1="430" y1="{y}" x2="508" y2="{y}" stroke="{{line}}" stroke-width="1.5" '
                     f'marker-end="url(#arrow)"/>')
        parts.append(f'<rect x="516" y="{y - 28}" width="344" height="56" rx="12" fill="{{card}}" stroke="{{edge}}"/>')

    # Stores, one per step.
    y = rows[0]
    parts.append(text(532, y - 8, "Saved logins", 11.5, "muted", 500))
    c, w = chip(532, y + 12, "Team", "team", "teamfill")
    parts.append(c)
    c, _ = chip(532 + w + 8, y + 12, "Personal", "personal", "personalfill")
    parts.append(c)
    parts.append(text(844, y + 16, "CCSwitcher’s Keychain items", 11, "muted", 400, "end"))

    y = rows[1]
    parts.append(text(532, y - 8, "Claude Code-credentials", 11.5, "muted", 500, mono=True))
    c, w = chip(532, y + 12, "claudeAiOauth → Personal", "personal", "personalfill", mono=True)
    parts.append(c)
    c, _ = chip(532 + w + 8, y + 12, "mcpOAuth · kept", "line", "card", mono=True)
    parts.append(c)

    y = rows[2]
    parts.append(text(532, y - 8, "~/.claude.json", 11.5, "muted", 500, mono=True))
    c, _ = chip(532, y + 12, "oauthAccount → Personal", "personal", "personalfill", mono=True)
    parts.append(c)

    y = rows[3]
    parts.append(text(532, y - 8, "api.anthropic.com", 11.5, "muted", 500, mono=True))
    c, _ = chip(532, y + 12, "/api/oauth/profile", "line", "card", mono=True)
    parts.append(c)
    parts.append(text(844, y + 16, "access token only", 11, "muted", 400, "end"))

    # Rollback: from step 4 back to the backup.
    parts.append(f'<path d="M 44 {rows[3] + 6} C 14 {rows[3] - 20}, 14 {rows[0] + 20}, 44 {rows[0] + 6}" '
                 f'fill="none" stroke="{{warn}}" stroke-width="1.5" stroke-dasharray="5 4" marker-end="url(#warnarrow)"/>')
    parts.append(f'<rect x="40" y="392" width="820" height="40" rx="10" fill="{{warnfill}}"/>')
    parts.append(text(58, 417, "↺", 15, "warn", 600))
    parts.append(text(80, 417, "If any step fails, or Anthropic names another org, the step 1 backup is put back.",
                      13, "ink"))
    return 900, 456, "".join(parts), "What one click does: back up, swap the token, update the profile, verify"


# ---------------------------------------------------------------- sessions


def sessions_diagram():
    x0, x1 = 196, 860

    def at(hour, minute=0):
        return x0 + ((hour - 14) * 60 + minute) / 240 * (x1 - x0)

    def bar(xa, xb, y, color):
        return f'<rect x="{xa:.1f}" y="{y - 7}" width="{xb - xa:.1f}" height="14" rx="7" fill="{{{color}}}"/>'

    switch = at(16, 17)
    lanes = {"disk": 112, "a": 182, "b": 252, "c": 322}
    parts = []

    # Legend.
    parts.append(badge(50, 44, "T", "team"))
    parts.append(text(66, 48.5, "Team", 13, "ink", 500))
    parts.append(badge(132, 44, "P", "personal"))
    parts.append(text(148, 48.5, "Personal", 13, "ink", 500))

    # The switch.
    parts.append(f'<line x1="{switch:.1f}" y1="70" x2="{switch:.1f}" y2="350" stroke="{{ink}}" stroke-opacity="0.55" '
                 f'stroke-width="1.5" stroke-dasharray="4 4"/>')
    parts.append(text(switch, 62, "16:17 · you switch to Personal", 12.5, "ink", 600, "middle"))

    # Lane labels.
    for key, label, sub in [("disk", "Login on disk", "what new sessions read"), ("a", "Session A", "started 14:20"),
                            ("b", "Session B", "started 15:30"), ("c", "Session C", "started 17:00")]:
        parts.append(text(40, lanes[key] - 1, label, 13.5, "ink", 600))
        parts.append(text(40, lanes[key] + 15, sub, 11.5, "muted"))

    # Login on disk.
    y = lanes["disk"]
    parts.append(bar(x0, switch - 3, y, "team"))
    parts.append(bar(switch + 3, x1, y, "personal"))

    # Session A: never restarted.
    y = lanes["a"]
    parts.append(bar(at(14, 20), x1, y, "team"))
    parts.append(text(at(14, 20), y + 26, "still Team: it loaded its login at start", 12, "muted"))
    refresh = at(17, 5)
    parts.append(f'<circle cx="{refresh:.1f}" cy="{y}" r="7" fill="{{warnfill}}" stroke="{{warn}}" stroke-width="2"/>')
    parts.append(f'<path d="M {refresh:.1f} {y - 9} L {refresh:.1f} {lanes["disk"] + 11}" stroke="{{warn}}" '
                 f'stroke-width="1.5" stroke-dasharray="4 3" marker-end="url(#warnarrow)"/>')
    parts.append(text(refresh + 10, lanes["disk"] + 34, "a token refresh can", 11.5, "warn", 500))
    parts.append(text(refresh + 10, lanes["disk"] + 48, "write Team back", 11.5, "warn", 500))

    # Session B: restarted after the switch.
    y = lanes["b"]
    restart = at(16, 43)
    parts.append(bar(at(15, 30), restart - 10, y, "team"))
    parts.append(f'<circle cx="{restart:.1f}" cy="{y}" r="9" fill="{{card}}" stroke="{{line}}" stroke-width="1.5"/>')
    parts.append(text(restart, y + 4.5, "↻", 12, "ink", 600, "middle"))
    parts.append(bar(restart + 10, x1, y, "personal"))
    parts.append(text(restart + 12, y + 26, "restarted: now Personal", 12, "muted"))

    # Session C: started after the switch.
    y = lanes["c"]
    parts.append(bar(at(17, 0), x1, y, "personal"))
    parts.append(text(at(17, 0), y + 26, "new session: Personal", 12, "muted"))

    # Time axis.
    axis = 366
    parts.append(f'<line x1="{x0}" y1="{axis}" x2="{x1}" y2="{axis}" stroke="{{line}}" stroke-width="1"/>')
    for hour in range(14, 19):
        x = at(hour)
        parts.append(f'<line x1="{x:.1f}" y1="{axis - 4}" x2="{x:.1f}" y2="{axis + 4}" stroke="{{line}}"/>')
        parts.append(text(x, axis + 20, f"{hour}:00", 11.5, "muted", 400, "middle"))

    parts.append(f'<rect x="40" y="404" width="820" height="40" rx="10" fill="{{warnfill}}"/>')
    parts.append(text(58, 429, "⚠", 14, "warn", 600))
    parts.append(text(80, 429, "The menu counts sessions like A and asks you to restart them.", 13, "ink"))
    return 900, 468, "".join(parts), "After a switch: running sessions keep the old login until restarted"


# ---------------------------------------------------------------- install


def install_diagram():
    parts = []
    # One entry per step of the README's install prompt, numbered the same.
    steps = [
        ("Check the Mac", "Xcode and brew"),
        ("Clone", "from GitHub"),
        ("Generate", "Xcode project"),
        ("Test", "temp keychain"),
        ("Build", "Release app"),
        ("Install", "~/Applications"),
        ("Hand off", "you save logins"),
    ]
    x0, gap, y = 40, 117, 58
    last = x0 + 14 + gap * (len(steps) - 1)
    parts.append(f'<line x1="{x0 + 14}" y1="{y}" x2="{last}" y2="{y}" stroke="{{line}}" stroke-width="1.5"/>')
    for i, (title, sub) in enumerate(steps):
        x = x0 + 14 + gap * i
        last = i == len(steps) - 1
        fill, stroke, ink = ("personal", "personal", "onaccent") if last else ("card", "line", "ink")
        parts.append(f'<circle cx="{x}" cy="{y}" r="14" fill="{{{fill}}}" stroke="{{{stroke}}}" stroke-width="1.5"/>')
        parts.append(text(x, y + 4.5, str(i + 1), 13, ink, 600, "middle"))
        parts.append(text(x - 14, y + 40, title, 14, "ink", 600))
        parts.append(text(x - 14, y + 58, sub, 12, "muted"))

    def card(x, title, color, fill, mark, items):
        out = [f'<rect x="{x}" y="150" width="400" height="150" rx="12" fill="{{card}}" stroke="{{edge}}"/>',
               f'<rect x="{x}" y="150" width="400" height="38" rx="12" fill="{{{fill}}}"/>',
               f'<rect x="{x}" y="176" width="400" height="12" fill="{{{fill}}}"/>',
               text(x + 18, 175, title, 13.5, color, 600)]
        for j, (item, mono) in enumerate(items):
            iy = 214 + j * 24
            out.append(text(x + 20, iy, mark, 13, color, 700))
            out.append(text(x + 40, iy, item, 12.5, "ink", 400, mono=mono))
        return "".join(out)

    parts.append(card(40, "Reaches the network for", "personal", "personalfill", "✓", [
        ("github.com/adarshchbs/CCSwitcher (git clone)", False),
        ("Homebrew, only if xcodegen is missing", False),
        ("Nothing else", False),
    ]))
    parts.append(card(460, "Never touches", "rose", "rosefill", "✕", [
        ("~/.claude.json", True),
        ("~/.claude/", True),
        ("Keychain item Claude Code-credentials", False),
        ("Your Claude sign-ins: you run them", False),
    ]))
    return 900, 330, "".join(parts), "What the install prompt does: seven steps, the network it uses, and what it never touches"


# ---------------------------------------------------------------- upstream vs fork

PANELS = [(40, "Upstream", "rose"), (460, "This fork", "personal")]
PANEL_W = 400

# How each kind of element looks: (fill, stroke, text, weight, dashed).
STYLES = {
    "auto": ("rosefill", "rose", "ink", 500, False),      # acts without you, or leaks
    "plain": ("card", "line", "ink", 500, False),          # same in both
    "kept": ("personalfill", "personal", "ink", 600, False),  # what the fork keeps
    "gone": ("canvas", "line", "muted", 400, True),        # removed in the fork
}
ARROW = {"auto": ("rose", "url(#rosearrow)"), "plain": ("line", "url(#arrow)"),
         "kept": ("personal", "url(#personalarrow)")}


def frame(height):
    out = []
    for px, title, color in PANELS:
        out.append(f'<rect x="{px}" y="24" width="{PANEL_W}" height="{height - 48}" rx="14" fill="{{card}}" '
                   f'stroke="{{edge}}"/>')
        out.append(f'<circle cx="{px + 26}" cy="52" r="5" fill="{{{color}}}"/>')
        out.append(text(px + 40, 57, title, 15, "ink", 600))
        out.append(f'<line x1="{px + 20}" y1="76" x2="{px + PANEL_W - 20}" y2="76" stroke="{{edge}}"/>')
    return "".join(out)


def box(x, y, w, h, label, kind, size=12.5, mono=False, radius=8):
    fill, stroke, ink, weight, dashed = STYLES[kind]
    dash = ' stroke-dasharray="4 3"' if dashed else ""
    out = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{{{fill}}}" stroke="{{{stroke}}}"'
           f'{dash}/>' + text(x + w / 2, y + h / 2 + 4.3, label, size, ink, weight, "middle", mono))
    if kind == "gone":
        half = len(label) * size * 0.27
        out += (f'<line x1="{x + w / 2 - half:.1f}" y1="{y + h / 2:.1f}" x2="{x + w / 2 + half:.1f}" '
                f'y2="{y + h / 2:.1f}" stroke="{{muted}}" stroke-width="1"/>')
    return out


def arrow(d, kind, width=1.5):
    color, marker = ARROW[kind]
    return f'<path d="{d}" fill="none" stroke="{{{color}}}" stroke-width="{width}" marker-end="{marker}"/>'


def note(x, y, ok, words):
    mark, color = ("✓", "personal") if ok else ("✕", "rose")
    return text(x, y, mark, 13, color, 700) + text(x + 18, y, words, 12.5, "ink")


def acts_diagram():
    """What can make the app act: triggers on the left, network on the right."""
    triggers = ["Timer", "Wake from sleep", "Low usage", "Your click"]
    network = ["Analytics", "Update check", "Token refresh", "Usage, profile"]
    kinds = {
        "Upstream": (["auto", "auto", "auto", "plain"], ["auto", "auto", "auto", "plain"]),
        "This fork": (["gone", "gone", "gone", "kept"], ["gone", "gone", "gone", "kept"]),
    }
    height = 330
    parts = [frame(height)]
    rows = [114, 156, 198, 240]
    for px, title, _ in PANELS:
        tk, nk = kinds[title]
        left_x, left_w = px + 16, 112
        app_x, app_w, app_y, app_h = px + 158, 84, 168, 60
        right_x, right_w = px + 272, 112
        mid = app_y + app_h / 2
        parts.append(text(left_x, 102, "Starts a switch", 12, "muted", 500))
        parts.append(text(right_x, 102, "Talks to", 12, "muted", 500))
        for label, kind, y in zip(triggers, tk, rows):
            parts.append(box(left_x, y, left_w, 30, label, kind, 12))
            if kind != "gone":
                ey = mid + (y + 15 - mid) * 0.35
                parts.append(arrow(f"M {left_x + left_w + 2} {y + 15} C {left_x + left_w + 20} {y + 15}, "
                                   f"{app_x - 18} {ey:.1f}, {app_x - 3} {ey:.1f}", kind))
        for label, kind, y in zip(network, nk, rows):
            parts.append(box(right_x, y, right_w, 30, label, kind, 12))
            if kind != "gone":
                sy = mid + (y + 15 - mid) * 0.35
                parts.append(arrow(f"M {app_x + app_w + 1} {sy:.1f} C {app_x + app_w + 18} {sy:.1f}, "
                                   f"{right_x - 20} {y + 15}, {right_x - 3} {y + 15}", kind))
        parts.append(f'<rect x="{app_x}" y="{app_y}" width="{app_w}" height="{app_h}" rx="12" fill="{{canvas}}" '
                     f'stroke="{{ink}}" stroke-opacity="0.35"/>')
        parts.append(text(app_x + app_w / 2, mid + 4.5, "CCSwitcher", 12.5, "ink", 600, "middle"))
    return 900, height, "".join(parts), ("What can make the app act. Upstream: a timer, waking from sleep, low usage or "
                                         "your click switch accounts, and it calls analytics, an update check and the "
                                         "token endpoint. This fork: only your click, and only the usage and profile "
                                         "requests.")


def token_diagram():
    """What happens to your token: writing it, and deciding whose it is."""
    parts = [frame(420)]
    for px, title, _ in PANELS:
        fork = title == "This fork"
        good = "kept" if fork else "auto"

        # Writing the token.
        parts.append(text(px + 20, 102, "Writing the token", 12, "muted", 500))
        parts.append(box(px + 20, 116, 110, 40, "CCSwitcher", "plain", 13))
        parts.append(box(px + 270, 116, 110, 40, "Keychain", "plain", 13))
        parts.append(arrow(f"M {px + 132} 136 L {px + 266} 136", good, 1.8))
        label = "SecItemUpdate" if fork else "security -w ‹token›"
        parts.append(text(px + 200, 128, label, 11.5, "personal" if fork else "rose", 500, "middle", mono=True))
        parts.append(note(px + 20, 186, fork, "The token stays in the app’s memory." if fork
                          else "The token shows up in ps while it runs."))

        # Deciding whose token it is.
        parts.append(text(px + 20, 232, "Saving a login as Team", 12, "muted", 500))
        if fork:
            parts.append(box(px + 20, 246, 150, 30, "Refresh token matches", "kept", 12))
            parts.append(text(px + 95, 292, "or", 11.5, "muted", 400, "middle"))
            parts.append(box(px + 20, 300, 150, 30, "Anthropic’s profile", "kept", 12))
            parts.append(arrow(f"M {px + 172} 261 C {px + 205} 261, {px + 220} 288, {px + 246} 288", "kept"))
            parts.append(arrow(f"M {px + 172} 315 C {px + 205} 315, {px + 220} 288, {px + 246} 288", "kept"))
        else:
            parts.append(box(px + 20, 268, 150, 40, "~/.claude.json", "auto", 12.5, mono=True))
            parts.append(arrow(f"M {px + 172} 288 L {px + 246} 288", "auto"))
            parts.append(text(px + 209, 280, "trusted", 11, "rose", 500, "middle"))
        parts.append(f'<rect x="{px + 250}" y="268" width="134" height="40" rx="8" fill="{{card}}" stroke="{{line}}"/>')
        parts.append(badge(px + 270, 288, "T", "team"))
        parts.append(text(px + 286, 292.5, "Saved as Team", 12, "ink", 500))
        parts.append(note(px + 20, 364, fork, "Owner proven before saving." if fork
                          else "Running sessions rewrite this file."))
    return 900, 420, "".join(parts), ("What happens to your token. Upstream passes it to security on the command line "
                                      "and trusts ~/.claude.json for its owner. This fork writes it in-process and "
                                      "proves the owner first.")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in [("switch", switch_diagram), ("sessions", sessions_diagram), ("install", install_diagram), ("acts", acts_diagram), ("token", token_diagram)]:
        width, height, body, title = build()
        for theme, colors in THEMES.items():
            path = OUT / f"{name}-{theme}.svg"
            path.write_text(svg(width, height, body, title).format(**colors) + "\n")
            print(f"wrote {path.relative_to(OUT.parent.parent)}")


if __name__ == "__main__":
    main()
