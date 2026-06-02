import Foundation
import Combine
import AppKit
import HIDPPKit

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percent: Int?
    @Published var state: ChargeState = .unknown
    @Published var status = "Starting…"
    @Published var lastUpdated: Date?

    private let hid = HIDPP()
    private let settings: AppSettings
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings

        // Set SQUEAK_DEBUG=1 to dump HID++ traffic + readings to stderr.
        if ProcessInfo.processInfo.environment["SQUEAK_DEBUG"] != nil { hid.verbose = true }
        hid.start()
        // The receiver can take a moment to enumerate, and the mouse may be asleep.
        // Retry quickly until we get a first reading, then settle into the slow poll.
        for delay in [1.5, 3.5, 6.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.percent == nil else { return }
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
    }

    private func scheduleTimer(seconds: Int) {
        timer?.invalidate()
        let interval = TimeInterval(max(1, seconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var menuTitle: String {
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    private var levelSymbol: String {
        switch percent ?? 0 {
        case 0:        return "battery.0"
        case 1..<25:   return "battery.25"
        case 25..<50:  return "battery.50"
        case 50..<75:  return "battery.75"
        default:       return "battery.100"
        }
    }

    /// Menu-bar icon: the level-appropriate battery, with a bolt composited on top when
    /// on power. SF Symbols has no partial-level bolt symbol, so we draw our own overlay
    /// and mark it a template image so the menu bar tints it for light/dark automatically.
    var barImage: NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let battery = NSImage(systemSymbolName: levelSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()

        guard state.isOnPower else {
            battery.isTemplate = true
            return battery
        }

        let boltCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(boltCfg) ?? NSImage()

        let size = battery.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        battery.draw(in: NSRect(origin: .zero, size: size))
        let b = bolt.size
        bolt.draw(in: NSRect(x: (size.width - b.width) / 2,
                             y: (size.height - b.height) / 2,
                             width: b.width, height: b.height))
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }

    var stateText: String {
        switch state {
        case .discharging: return "On battery"
        case .charging:    return "Charging"
        case .full:        return "Full (plugged in)"
        case .unknown:     return ""
        }
    }

    func refresh() {
        status = "Reading…"
        let hid = self.hid
        Task.detached {
            let result = hid.readBattery()
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.percent = r.percent
                    self.state = r.state
                    self.status = ""   // raw HID++ detail only goes to SQUEAK_DEBUG, not the menu
                    self.lastUpdated = Date()
                    if ProcessInfo.processInfo.environment["SQUEAK_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("APP READING: \(r.percent)% \(r.state) [\(r.detail)]\n".utf8))
                    }
                case .failure(let e):
                    self.status = e.message
                }
            }
        }
    }
}
