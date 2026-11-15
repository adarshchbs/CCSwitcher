import SwiftUI

@main
struct CCSwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Text(model.iconText)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Claude Account
/// ✓ Team (Acme)    5h 42% · 7d 63%
///   Personal        5h 3% · 7d 18%  (as of 14:02)
/// ───
/// Save current login… / Refresh usage / Settings…
/// ───
/// Quit
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Claude Account") {
            if model.accounts.isEmpty {
                Text("No saved logins")
            }
            ForEach(model.accounts) { account in
                Toggle(model.title(for: account), isOn: Binding(
                    get: { model.activeId == account.id },
                    set: { _ in model.switchTo(account) }
                ))
            }
        }
        if model.unfinished != nil {
            Button("⚠︎ A switch didn't finish. Resolve…") { model.resolveUnfinishedSwitchNow() }
        }
        if model.liveMismatch {
            Text("⚠︎ Live login doesn't match ~/.claude.json")
        }
        if let notice = model.notice {
            Text(notice)
        }
        Divider()
        Button("Save current login…") { model.saveCurrentLogin() }
        Button("Refresh usage") { model.refreshUsageNow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// Rename or remove saved accounts.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Text("No saved logins. Log in with `claude /login`, then choose Save current login… from the menu.")
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
