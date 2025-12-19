import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?

    func show(model: AppModel) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = DashboardView(model: model)
        let hosting = NSHostingView(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        newWindow.title = "Antigravity Usage"
        newWindow.contentView = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        newWindow.delegate = self
        window = newWindow
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Antigravity Usage")
                    .font(.title2)
                    .bold()

                Spacer()

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Refresh") {
                    Task { await model.refreshNow() }
                }
                .disabled(!model.isSignedIn || model.isRefreshing)
            }

            if !model.isSignedIn {
                Text("Sign in to view quotas.")
                    .foregroundStyle(.secondary)

                Button("Sign in with Google…") {
                    Task { await model.signIn() }
                }
                .keyboardShortcut(.defaultAction)

                Spacer()
            } else {
                if let message = model.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let snapshot = model.snapshot {
                    if let line = snapshot.promptCreditsLine {
                        Text(line)
                            .font(.headline)
                    }

                    List(snapshot.modelsSortedForDisplay, id: \.modelId) { quota in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quota.label)
                                    .font(.headline)
                                if let untilReset = quota.timeUntilReset {
                                    Text("Resets in \(untilReset)")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }

                            Spacer()

                            Text("\(quota.remainingPercent)%")
                                .monospacedDigit()
                                .font(.headline)
                        }
                    }
                } else {
                    Text(model.isRefreshing ? "Loading…" : "No data yet")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Sign Out") {
                        Task { await model.signOut() }
                    }

                    Spacer()
                }
            }
        }
        .padding(16)
    }
}
