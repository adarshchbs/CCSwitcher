import AppKit
import Combine
import SwiftUI
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Menu")

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel()
    private var menu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenuController(model: model)
    }
}

// MARK: - Status item and menu

/// The menu bar item and its `NSMenu`:
///
/// ```
/// Claude Account
/// ✓ Team  new sessions                 (spinner while fetching)
///     Session          ██████░░░░   41%
///     Weekly           █░░░░░░░░░    7%
///   Personal                           as of 14:02
///     2 running sessions started before the switch
///     Session ...  (dimmed when stale)
/// ⚠︎ 2 Claude sessions started before 16:17 may still be using Personal. …
/// ──────────────
/// <sign-in progress, unfinished switch, ~/.claude.json mismatch + Fix, notice>
/// Save current login… / Add account… / Refresh usage / Settings…
/// ──────────────
/// Quit
/// ```
///
/// Opening the menu starts (or joins) a refresh; rows update in place while
/// it stays open. Nothing refreshes on its own.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let width: CGFloat = 300

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let settings = SettingsOpener()
    private var rows: [MenuRow] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var isOpen = false
    private var updatePending = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            // A 1×1 SwiftUI view in the status bar's window, so the app can
            // read the `openSettings` action (see `SettingsOpener`).
            let capture = NSHostingView(rootView: SettingsActionCapture(opener: settings))
            capture.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(capture)
        }
        updateIcon()
        // Model changes reach the open menu: the main queue also runs while
        // the menu tracks events, unlike the default run loop mode.
        model.objectWillChange.merge(with: model.status.objectWillChange)
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &subscriptions)
    }

    private func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePending = false
                self.update()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: model.iconSymbol, accessibilityDescription: model.iconAccessibilityLabel)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(model.iconAccessibilityLabel)
    }

    private func update() {
        updateIcon()
        guard isOpen else { return }
        let next = model.menuRows()
        guard next != rows else { return }
        if next.map(\.key) == rows.map(\.key), menu.items.count == next.count {
            for (index, row) in next.enumerated() { configure(menu.items[index], with: row) }
            rows = next
        } else {
            rebuild(next)
        }
    }

    private func rebuild(_ next: [MenuRow]) {
        menu.removeAllItems()
        for row in next {
            let item = makeItem(row)
            configure(item, with: row)
            menu.addItem(item)
        }
        rows = next
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        model.menuWillOpen()
        rebuild(model.menuRows())
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? AccountRowView)?.isHighlighted = candidate === item
        }
    }

    // MARK: Items

    private func makeItem(_ row: MenuRow) -> NSMenuItem {
        switch row {
        case .header(let title):
            return NSMenuItem.sectionHeader(title: title)
        case .separator:
            return .separator()
        case .account(let line):
            let item = NSMenuItem(title: line.label, action: #selector(accountClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = line.id
            let view = AccountRowView()
            view.onClick = { [weak self, weak item] in
                guard let self, let item else { return }
                self.accountClicked(item)
            }
            item.view = view
            return item
        case .usage:
            let item = NSMenuItem()
            item.view = UsageRowView()
            item.isEnabled = false
            return item
        case .note:
            let item = NSMenuItem()
            item.view = NoteRowView()
            item.isEnabled = false
            return item
        case .action(let line):
            let item = NSMenuItem(title: line.title, action: #selector(actionClicked(_:)),
                                  keyEquivalent: line.action == .quit ? "q" : "")
            item.target = self
            item.representedObject = line.action.rawValue
            return item
        }
    }

    private func configure(_ item: NSMenuItem, with row: MenuRow) {
        switch row {
        case .header, .separator:
            break
        case .account(let line):
            item.title = line.label
            item.toolTip = line.tooltip
            (item.view as? AccountRowView)?.configure(line)
        case .usage(let line):
            item.toolTip = line.tooltip
            (item.view as? UsageRowView)?.configure(line)
        case .note(let line):
            (item.view as? NoteRowView)?.configure(line)
        case .action(let line):
            item.title = line.title
            item.isEnabled = line.enabled
        }
    }

    /// Switches after the menu has closed, so the confirm dialog isn't shown
    /// while the menu is still tracking.
    @objc private func accountClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.switchTo(id: id) }
        }
    }

    @objc private func actionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ActionLine.Action(rawValue: raw) else { return }
        switch action {
        case .cancelSignIn: model.cancelSignIn()
        case .resolveUnfinished: model.resolveUnfinishedSwitchNow()
        case .fixClaudeJSON: model.fixClaudeJSON()
        case .saveLogin: model.saveCurrentLogin()
        case .addAccount: model.addAccount()
        case .refresh: model.refreshUsageNow()
        case .settings: settings.open()
        case .quit: NSApp.terminate(nil)
        }
    }
}

// MARK: - Settings

/// Opens the SwiftUI Settings scene from AppKit. `SettingsLink` doesn't work
/// in an `NSMenu`, and macOS 14 ignores the `showSettingsWindow:` selector;
/// the supported way is the `openSettings` environment action, which a
/// SwiftUI view captures (`SettingsActionCapture`, hosted in the status
/// item's button).
@MainActor
final class SettingsOpener {
    fileprivate var action: OpenSettingsAction?

    func open() {
        guard let action else {
            log.fault("openSettings wasn't captured")
            Prompts.inform("Can't open Settings", "CCSwitcher couldn't reach its Settings window. Quit and reopen the app.")
            return
        }
        NSApp.activate()
        action()
    }
}

private struct SettingsActionCapture: View {
    @Environment(\.openSettings) private var openSettings
    let opener: SettingsOpener

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { opener.action = openSettings }
    }
}

// MARK: - Row views

private enum RowMetrics {
    static let inset: CGFloat = 14
    /// Where labels start, past the checkmark column.
    static let textX: CGFloat = 26
    @MainActor static var smallFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
}

/// An account: checkmark, label, tag, and a spinner or "as of" on the right.
/// Clickable, with the menu's selection highlight.
final class AccountRowView: NSView {
    private let check = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    var onClick: (() -> Void)?

    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            applyColors()
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenuController.width, height: 22))
        autoresizingMask = [.width]
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Active")
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        title.font = .menuFont(ofSize: 0)
        title.lineBreakMode = .byTruncatingTail
        tagLabel.font = RowMetrics.smallFont
        trailing.font = RowMetrics.smallFont
        trailing.alignment = .right
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [check, title, tagLabel, trailing, spinner] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ line: AccountLine) {
        check.isHidden = !line.checked
        title.stringValue = line.label
        tagLabel.stringValue = line.tag ?? ""
        tagLabel.isHidden = line.tag == nil
        trailing.stringValue = line.trailing ?? ""
        trailing.isHidden = line.fetching || line.trailing == nil
        if line.fetching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        toolTip = line.tooltip
        setAccessibilityLabel([line.label, line.checked ? "active" : nil, line.tag, line.trailing]
            .compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let right = bounds.width - RowMetrics.inset
        check.frame = NSRect(x: 10, y: (height - 14) / 2, width: 14, height: 14)
        spinner.frame = NSRect(x: right - 14, y: (height - 14) / 2, width: 14, height: 14)
        trailing.sizeToFit()
        let trailingWidth = min(trailing.frame.width, 120)
        trailing.frame = NSRect(x: right - trailingWidth, y: (height - trailing.frame.height) / 2,
                                width: trailingWidth, height: trailing.frame.height)
        let reserved: CGFloat = trailing.isHidden ? (spinner.isHidden ? 0 : 22) : trailingWidth + 8
        title.sizeToFit()
        tagLabel.sizeToFit()
        let tagWidth = tagLabel.isHidden ? 0 : tagLabel.frame.width + 6
        let titleWidth = max(0, min(title.frame.width, right - reserved - tagWidth - RowMetrics.textX))
        title.frame = NSRect(x: RowMetrics.textX, y: (height - title.frame.height) / 2,
                             width: titleWidth, height: title.frame.height)
        tagLabel.frame = NSRect(x: title.frame.maxX + 6, y: (height - tagLabel.frame.height) / 2,
                           width: tagLabel.frame.width, height: tagLabel.frame.height)
    }

    private func applyColors() {
        let primary: NSColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        title.textColor = primary
        check.contentTintColor = primary
        tagLabel.textColor = secondary
        trailing.textColor = secondary
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    /// The whole row takes the click, not the labels inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard enclosingMenuItem?.isEnabled == true else { return }
        onClick?()
    }
}

/// "Weekly · Fable   ████████░░   93%". Not clickable, never highlighted.
final class UsageRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bar = UsageBarView()
    private let percent = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenuController.width, height: 18))
        autoresizingMask = [.width]
        label.font = RowMetrics.smallFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        for view in [label, bar, percent] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ line: UsageLine) {
        let value = Int(line.percent.rounded())
        label.stringValue = line.label
        percent.stringValue = "\(value)%"
        bar.fraction = min(max(line.percent / 100, 0), 1)
        bar.severity = line.severity
        alphaValue = line.stale ? 0.45 : 1
        toolTip = line.tooltip
        setAccessibilityLabel("\(line.label) \(value) percent\(line.stale ? ", stale" : "")")
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let right = bounds.width - RowMetrics.inset
        let labelX = RowMetrics.textX + 8
        let labelWidth: CGFloat = 104
        let percentWidth: CGFloat = 36
        label.sizeToFit()
        label.frame = NSRect(x: labelX, y: (height - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
        percent.sizeToFit()
        percent.frame = NSRect(x: right - percentWidth, y: (height - percent.frame.height) / 2,
                               width: percentWidth, height: percent.frame.height)
        let barX = labelX + labelWidth + 6
        bar.frame = NSRect(x: barX, y: (height - 5) / 2, width: max(0, right - percentWidth - 8 - barX), height: 5)
    }
}

/// A thin rounded bar: a dark fill on a light track (light on dark in Dark
/// Mode), tinted orange or red for a warning or critical limit.
final class UsageBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var severity: UsageSeverity = .normal { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        let fill: NSColor = switch severity {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
        fill.setFill()
        let width = max(bounds.height, bounds.width * fraction)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Secondary text that wraps to the menu's width.
final class NoteRowView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var indented = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenuController.width, height: 18))
        autoresizingMask = [.width]
        label.font = RowMetrics.smallFont
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var textX: CGFloat { indented ? RowMetrics.textX + 8 : RowMetrics.textX }

    func configure(_ line: NoteLine) {
        indented = line.indented
        label.stringValue = line.text
        label.textColor = line.style == .warning ? .labelColor : .secondaryLabelColor
        let width = StatusMenuController.width - textX - RowMetrics.inset
        label.preferredMaxLayoutWidth = width
        let height = ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        setFrameSize(NSSize(width: frame.width, height: height + 4))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: textX, y: 2, width: bounds.width - textX - RowMetrics.inset, height: bounds.height - 4)
    }
}

// MARK: - Settings window

/// Rename or remove saved accounts.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Text("No saved logins. Choose Add account… from the menu, or log in with `claude /login` and choose Save current login….")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                AccountRow(model: model, account: account)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 200)
        .onAppear { NSApp.activate() }
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @State private var draft: String

    init(model: AppModel, account: SavedAccount) {
        self.model = model
        self.account = account
        _draft = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $draft)
                    .onSubmit(save)
                Button("Rename", action: save)
                    .disabled(draft == account.label)
                Button("Remove…", role: .destructive) { model.remove(account) }
            }
            Button("Restore previous saved login…") { model.restorePrevious(account) }
                .controlSize(.small)
            Text([account.email, account.orgName, account.plan].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: account.label) { _, label in draft = label }
    }

    private func save() {
        model.rename(account, to: draft)
    }
}
