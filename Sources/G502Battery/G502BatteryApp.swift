import SwiftUI
import AppKit

@main
struct G502BatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()

    init() {
        // Menu-bar-only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            // SwiftUI renders the SF Symbol + text in the menu bar.
            Label(monitor.menuTitle, systemImage: monitor.symbol)
        }
        .menuBarExtraStyle(.menu)
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

            Divider()
            Text(monitor.status).font(.caption).foregroundStyle(.secondary)

            Divider()
            Button("Refresh now") { monitor.refresh() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
