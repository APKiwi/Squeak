import SwiftUI
import AppKit

@main
struct SqueakApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var monitor: BatteryMonitor

    init() {
        // Create settings first so the monitor can read and observe the poll interval.
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: BatteryMonitor(settings: settings))

        // Menu-bar-only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            // Composited battery+bolt image (bolt overlay only exists for the full SF
            // Symbol, so we draw our own). The percentage text is optional per settings.
            HStack(spacing: 3) {
                Image(nsImage: monitor.barImage)
                if settings.showPercentInMenuBar {
                    Text(monitor.menuTitle)
                }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settings)
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        Group {
            if let p = monitor.percent {
                Text("G502 X: \(p)%")
                if !monitor.stateText.isEmpty {
                    Text(monitor.stateText)
                }
            } else {
                Text("G502 X: no reading")
            }

            if let updated = monitor.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }

            // Only surface a status line when there's something to say (errors / "Reading…"),
            // not the raw HID++ bytes.
            if !monitor.status.isEmpty {
                Divider()
                Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Button("Refresh now") { monitor.refresh() }
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
