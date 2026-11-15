import AppKit
import Combine
import SwiftUI

/// The menu bar item and the glass panel it opens.
///
/// Opening the panel starts (or joins) a usage refresh; rows update in place
/// while it stays open. Nothing refreshes on its own. A click outside, Esc,
/// or a second click on the icon closes it.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let settings = SettingsOpener()
    private let panel = GlassPanel()
    private var subscriptions: Set<AnyCancellable> = []
    private var outsideClicks: Any?
    /// When the panel last closed because it lost focus. A click on the icon
    /// also takes focus, so without this it would close and reopen at once.
    private var resignedAt: Date?
    private var updatePending = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let view = MenuPanelHost(
            model: model, status: model.status,
            perform: { [weak self] action in self?.perform(action) },
            switchTo: { [weak self] id in self?.switchTo(id) },
            resize: { [weak self] size in self?.resize(to: size) })
        let hosting = NSHostingView(rootView: view)
        // The panel sizes itself from the view's measured height.
        hosting.sizingOptions = []
        panel.setContent(hosting)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        if let button = statusItem.button {
            // A 1×1 SwiftUI view in the status bar's window, so the app can
            // read the `openSettings` action (see `SettingsOpener`).
            let capture = NSHostingView(rootView: SettingsActionCapture(opener: settings))
            capture.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(capture)
            button.target = self
            button.action = #selector(togglePanel)
        }
        updateIcon()
        model.objectWillChange.merge(with: model.status.objectWillChange)
            .sink { [weak self] _ in self?.scheduleIconUpdate() }
            .store(in: &subscriptions)
    }

    // MARK: Icon

    /// `objectWillChange` fires before the change; read the model after it.
    private func scheduleIconUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePending = false
                self.updateIcon()
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

    // MARK: Open and close

    @objc private func togglePanel() {
        if panel.isVisible {
            close()
        } else if let resignedAt, Date().timeIntervalSince(resignedAt) < 0.3 {
            // This click is what took focus away and closed the panel.
            self.resignedAt = nil
        } else {
            open()
        }
    }

    private func open() {
        model.menuWillOpen()
        place(size: panel.frame.size)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        resignedAt = Date()
        close()
    }

    // MARK: Size and position

    /// Keeps the panel's top edge under the icon as its height changes.
    private func resize(to size: CGSize) {
        let size = CGSize(width: MenuPanelView.width, height: ceil(size.height))
        guard size != panel.frame.size else { return }
        place(size: size)
        panel.invalidateShadow()
    }

    /// Centers the panel under the icon, kept 8 pt inside the screen.
    private func place(size: CGSize) {
        guard let button = statusItem.button, let window = button.window else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = icon.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Actions

    /// Closes the panel first, so a dialog the action shows isn't hidden
    /// behind it. Refresh keeps the panel open to show the new numbers.
    private func perform(_ action: ActionLine.Action) {
        if action != .refresh { close() }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch action {
                case .cancelSignIn: self.model.cancelSignIn()
                case .resolveUnfinished: self.model.resolveUnfinishedSwitchNow()
                case .fixClaudeJSON: self.model.fixClaudeJSON()
                case .saveLogin: self.model.saveCurrentLogin()
                case .addAccount: self.model.addAccount()
                case .refresh: self.model.refreshUsageNow()
                case .settings: self.settings.open()
                case .quit: NSApp.terminate(nil)
                }
            }
        }
    }

    private func switchTo(_ id: String) {
        close()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.switchTo(id: id) }
        }
    }
}

/// A borderless panel with Liquid Glass behind its content (macOS 26 and
/// later) or the popover material on older systems. It takes key focus
/// without activating the app, like a menu.
final class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 18
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MenuPanelView.width, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func setContent(_ view: NSView) {
        view.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = view
            contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            view.frame = effect.bounds
            effect.addSubview(view)
            contentView = effect
        }
    }
}

/// Redraws the panel whenever the model or the usage status changes.
struct MenuPanelHost: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: AccountStatus
    let perform: (ActionLine.Action) -> Void
    let switchTo: (String) -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        MenuPanelView(rows: model.menuRows(), perform: perform, switchTo: switchTo, resize: resize)
    }
}
