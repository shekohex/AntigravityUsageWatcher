import SwiftUI

@main
struct AntigravityUsageWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}
