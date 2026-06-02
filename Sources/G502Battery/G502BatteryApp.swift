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
            // Composited battery+bolt image (bolt overlay only exists for the full SF
            // Symbol, so we draw our own) plus the percentage text.
            HStack(spacing: 3) {
                Image(nsImage: monitor.barImage)
                Text(monitor.menuTitle)
            }
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
