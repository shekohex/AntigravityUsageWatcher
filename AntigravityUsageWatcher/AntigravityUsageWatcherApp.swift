import SwiftUI
import AppKit

@main
struct AntigravityUsageWatcherApp: App {
    // 1. Link the AppDelegate to the SwiftUI App lifecycle
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // We still need a Scene, but it doesn't need to do anything
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
    }

    func setupStatusBar() {
        let statusBar = NSStatusBar.system
        // Using variableLength allows the icon to fit its own width
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // SF Symbols work best here
            button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Usage Watcher")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Check Usage", action: #selector(dummyAction), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Angravity", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func dummyAction() {
        print("Usage check triggered!")
    }
}
