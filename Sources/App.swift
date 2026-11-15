import SwiftUI

@main
struct CCSwitcherApp: App {
    var body: some Scene {
        MenuBarExtra("CCSwitcher", systemImage: "person.2") {
            Button("Quit") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
