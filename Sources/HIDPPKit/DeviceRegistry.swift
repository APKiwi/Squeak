import Foundation

/// A device the app is tracking, with the online/last-known dimension layered on top of a
/// raw `DeviceReading`. When a device drops out of a scan we keep its last values and flip
/// `isOnline` to false, so the menu-bar primary can show a dimmed last-known reading.
public struct RegisteredDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var percent: Int?
    public var state: ChargeState
    public var transport: Transport
    public var isOnline: Bool
    public var lastSeen: Date
}

/// Pure (hardware-free) accumulation of scans into a stable device list. Order of insertion
/// is preserved internally; `sorted` provides the display order.
public struct DeviceRegistry {
    public private(set) var devices: [RegisteredDevice] = []

    /// Consecutive scans a device must be missing from before it's shown offline. 1 = the
    /// first miss (original behaviour); the app uses 2 so one flaky read doesn't say "asleep".
    public let missesBeforeOffline: Int
    private var misses: [String: Int] = [:]

    public init(missesBeforeOffline: Int = 1) {
        self.missesBeforeOffline = max(1, missesBeforeOffline)
    }

    /// Upsert every scanned device as online; mark any tracked device absent from this scan
    /// offline while keeping its last-known values.
    public mutating func merge(scan: [DeviceReading], now: Date) {
        let scannedIDs = Set(scan.map(\.id))

        for reading in scan {
            misses[reading.id] = 0
            if let i = devices.firstIndex(where: { $0.id == reading.id }) {
                devices[i].name = reading.name
                devices[i].percent = reading.percent
                devices[i].state = reading.state
                devices[i].transport = reading.transport
                devices[i].isOnline = true
                devices[i].lastSeen = now
            } else {
                devices.append(RegisteredDevice(
                    id: reading.id, name: reading.name, percent: reading.percent,
                    state: reading.state, transport: reading.transport,
                    isOnline: true, lastSeen: now))
            }
        }

        for i in devices.indices where !scannedIDs.contains(devices[i].id) {
            let id = devices[i].id
            misses[id, default: 0] += 1
            if misses[id, default: 0] >= missesBeforeOffline {
                devices[i].isOnline = false   // keep percent/state/lastSeen as last-known
            }
        }
    }

    /// Display order: online devices first, then by name, then by id (stable, deterministic).
    public var sorted: [RegisteredDevice] {
        devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    /// The device to show in the menu bar: the favourite if we're tracking it (online or not),
    /// else the first online device, else the first tracked device, else nil.
    public func primary(favouriteID: String?) -> RegisteredDevice? {
        if let favouriteID, let fav = devices.first(where: { $0.id == favouriteID }) {
            return fav
        }
        let order = sorted
        return order.first(where: { $0.isOnline }) ?? order.first
    }
}
