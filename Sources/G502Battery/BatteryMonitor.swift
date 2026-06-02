import Foundation
import Combine
import HIDPPKit

private func mlog(_ s: String) { FileHandle.standardError.write(Data(("[monitor] " + s + "\n").utf8)) }

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percent: Int?
    @Published var charging = false
    @Published var status = "Starting…"
    @Published var lastUpdated: Date?

    private let hid = HIDPP()
    private var timer: Timer?

    init() {
        hid.start()
        // The receiver can take a moment to enumerate, and the mouse may be asleep.
        // Retry quickly until we get a first reading, then settle into a slow poll.
        for delay in [1.5, 3.5, 6.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                mlog("retry fire delay=\(delay)")
                guard let self, self.percent == nil else { return }
                self.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        mlog("init done")
    }

    var menuTitle: String {
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    var symbol: String {
        if charging { return "battery.100.bolt" }
        switch percent ?? 0 {
        case 0:        return "battery.0"
        case 1..<25:   return "battery.25"
        case 25..<50:  return "battery.50"
        case 50..<75:  return "battery.75"
        default:       return "battery.100"
        }
    }

    func refresh() {
        mlog("refresh()")
        status = "Reading…"
        let hid = self.hid
        Task.detached {
            let result = hid.readBattery()
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.percent = r.percent
                    self.charging = r.charging
                    self.status = r.detail
                    self.lastUpdated = Date()
                case .failure(let e):
                    self.status = e.message
                }
            }
        }
    }
}
