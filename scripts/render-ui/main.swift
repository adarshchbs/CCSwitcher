// Renders the menu bar panel with sample data for the README:
// docs/assets/ui.png, light and dark side by side.
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

/// One panel on a transparent background, with a stand-in for the tinted
/// glass, which ImageRenderer can't draw. The account colors resolve
/// against the app appearance, so each mode renders in its own pass.
@MainActor func panel(dark: Bool) -> NSImage {
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let glass = RoundedRectangle(cornerRadius: 18, style: .continuous)
    let view = MenuPanelView(rows: rows, perform: { _ in }, switchTo: { _ in }, resize: { _ in })
        .background(glass.fill(dark ? Color(white: 0.11, opacity: 0.82) : Color(white: 0.99, opacity: 0.74)))
        .overlay(glass.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 24, y: 10)
        .padding(40)
        .fixedSize()
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage else { fatalError("render failed") }
    return image
}

/// Light on the left, dark on the right, each on its own wallpaper-like
/// backdrop, joined at a straight seam with rounded outer corners.
@MainActor func renderBoth(to path: String) {
    let light = panel(dark: false)
    let dark = panel(dark: true)
    func half(_ image: NSImage, _ colors: [Color]) -> some View {
        Image(nsImage: image)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    let view = HStack(spacing: 0) {
        half(light, [Color(red: 0.80, green: 0.86, blue: 0.98), Color(red: 0.94, green: 0.84, blue: 0.91)])
        half(dark, [Color(red: 0.11, green: 0.13, blue: 0.24), Color(red: 0.27, green: 0.16, blue: 0.30)])
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .fixedSize()
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let tiff = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("render failed") }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("can't write \(path): \(error)") }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    renderBoth(to: "\(CommandLine.arguments[1])/ui.png")
}
