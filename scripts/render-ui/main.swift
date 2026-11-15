// Renders the menu bar panel with sample data for the README:
// docs/assets/ui-light.png and docs/assets/ui-dark.png.
// Run scripts/render-ui.sh from the repo root.
import AppKit
import SwiftUI

func usage(_ key: String, _ label: String, used: Double) -> MenuRow {
    .usage(UsageLine(key: key, label: label, percent: used, severity: .normal, stale: false, tooltip: nil))
}

let rows: [MenuRow] = [
    .header("Claude Account"),
    .account(AccountLine(id: "team", label: "Team", checked: false, tag: nil, trailing: nil, fetching: false, tooltip: nil)),
    usage("t0", "Session", used: 0), usage("t1", "Weekly", used: 8), usage("t2", "Weekly · Fable", used: 7),
    .account(AccountLine(id: "personal", label: "Personal", checked: true, tag: "new sessions", trailing: nil,
                         fetching: false, tooltip: nil)),
    .note(NoteLine(key: "p:sessions", text: "5 running sessions", indented: true, style: .secondary)),
    usage("p1", "Weekly", used: 24), usage("p2", "Weekly · Fable", used: 3),
    .separator("accounts"),
    .action(ActionLine(action: .saveLogin, title: "Save current login…")),
    .action(ActionLine(action: .addAccount, title: "Add account…")),
    .action(ActionLine(action: .refresh, title: "Refresh usage")),
    .action(ActionLine(action: .settings, title: "Settings…")),
    .separator("quit"),
    .action(ActionLine(action: .quit, title: "Quit")),
]

/// A wallpaper-like backdrop and a stand-in for the tinted glass, which
/// ImageRenderer can't draw.
@MainActor func render(dark: Bool, to path: String) {
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let backdrop = dark
        ? [Color(red: 0.11, green: 0.13, blue: 0.24), Color(red: 0.27, green: 0.16, blue: 0.30)]
        : [Color(red: 0.78, green: 0.84, blue: 0.97), Color(red: 0.93, green: 0.82, blue: 0.90)]
    let glass = RoundedRectangle(cornerRadius: 18, style: .continuous)
    let view = ZStack {
        LinearGradient(colors: backdrop, startPoint: .topLeading, endPoint: .bottomTrailing)
        MenuPanelView(rows: rows, perform: { _ in }, switchTo: { _ in }, resize: { _ in })
            .background(glass.fill(dark ? Color(white: 0.11, opacity: 0.80) : Color(white: 0.99, opacity: 0.72)))
            .overlay(glass.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 24, y: 10)
            .padding(36)
    }
    .fixedSize()
    .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let tiff = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("render failed") }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("can't write \(path): \(error)") }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let out = CommandLine.arguments[1]
    render(dark: false, to: "\(out)/ui-light.png")
    render(dark: true, to: "\(out)/ui-dark.png")
}
