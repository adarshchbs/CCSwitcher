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
    private var panel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = StatusPanelController(model: model)
    }
}

// MARK: - Settings

/// Opens the SwiftUI Settings scene from AppKit. `SettingsLink` doesn't work
/// from an AppKit status item, and macOS 14 ignores the `showSettingsWindow:` selector;
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

struct SettingsActionCapture: View {
    @Environment(\.openSettings) private var openSettings
    let opener: SettingsOpener

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { opener.action = openSettings }
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
