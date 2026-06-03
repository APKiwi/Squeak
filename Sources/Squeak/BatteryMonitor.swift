import Foundation
import Combine
import AppKit
import HIDPPKit

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var devices: [RegisteredDevice] = []
    @Published var primary: RegisteredDevice?
    @Published var status = "Starting…"
    @Published var lastUpdated: Date?

    private var registry = DeviceRegistry()
    private let hid = HIDPP()
    private let settings: AppSettings
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings

        // Set SQUEAK_DEBUG=1 to dump HID++ traffic + readings to stderr.
        if ProcessInfo.processInfo.environment["SQUEAK_DEBUG"] != nil { hid.verbose = true }
        hid.start()
        // The receiver can take a moment to enumerate, and devices may be asleep.
        // Retry quickly until we get a first reading, then settle into the slow poll.
        for delay in [1.5, 3.5, 6.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.devices.isEmpty else { return }
                self.refresh()
            }
        }

        scheduleTimer(seconds: settings.pollIntervalSeconds)
        // Reschedule whenever the user changes the interval in Settings. dropFirst skips
        // the value we just scheduled with above.
        settings.$pollIntervalSeconds
            .dropFirst()
            .sink { [weak self] seconds in self?.scheduleTimer(seconds: seconds) }
            .store(in: &cancellables)

        // Recompute the menu-bar primary immediately when the favourite changes, so clicking
        // a device in the list updates the bar without waiting for the next poll.
        settings.$favouriteDeviceID
            .sink { [weak self] favID in
                guard let self else { return }
                self.primary = self.registry.primary(favouriteID: favID)
            }
            .store(in: &cancellables)
    }

    private func scheduleTimer(seconds: Int) {
        timer?.invalidate()
        let interval = TimeInterval(max(1, seconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var menuTitle: String {
        guard let p = primary, let pct = p.percent else { return "—" }
        return "\(pct)%"
    }

    private var levelSymbol: String {
        switch primary?.percent ?? 0 {
        case 0:        return "battery.0"
        case 1..<25:   return "battery.25"
        case 25..<50:  return "battery.50"
        case 50..<75:  return "battery.75"
        default:       return "battery.100"
        }
    }

    var stateText: String {
        guard let state = primary?.state else { return "" }
        switch state {
        case .discharging: return "On battery"
        case .charging:    return "Charging"
        case .full:        return "Full (plugged in)"
        case .unknown:     return ""
        }
    }

    /// Menu-bar icon for the `primary` device: the level-appropriate battery, a bolt composited
    /// on top when on power, and the whole thing drawn dim when the primary's reading is stale
    /// (device offline / asleep) so the last-known level stays visible but clearly not live.
    var barImage: NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let battery = NSImage(systemSymbolName: levelSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()

        let onPower = primary?.state.isOnPower ?? false
        let base: NSImage
        if onPower {
            let boltCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(boltCfg) ?? NSImage()
            let size = battery.size
            let composed = NSImage(size: size)
            composed.lockFocus()
            battery.draw(in: NSRect(origin: .zero, size: size))
            let b = bolt.size
            bolt.draw(in: NSRect(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2,
                                 width: b.width, height: b.height))
            composed.unlockFocus()
            base = composed
        } else {
            base = battery
        }

        let online = primary?.isOnline ?? false
        let result: NSImage
        if online || primary == nil {
            result = base
        } else {
            let dimmed = NSImage(size: base.size)
            dimmed.lockFocus()
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 0.4)
            dimmed.unlockFocus()
            result = dimmed
        }
        result.isTemplate = true
        return result
    }

    func refresh() {
        status = "Reading…"
        let hid = self.hid
        Task.detached {
            let scan = hid.scanAll()
            await MainActor.run {
                self.registry.merge(scan: scan, now: Date())
                self.devices = self.registry.sorted
                self.primary = self.registry.primary(favouriteID: self.settings.favouriteDeviceID)
                self.lastUpdated = Date()
                self.status = self.devices.isEmpty ? "no devices found yet" : ""
                if ProcessInfo.processInfo.environment["SQUEAK_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("APP SCAN: \(scan.count) device(s)\n".utf8))
                }
            }
        }
    }
}
