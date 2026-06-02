import XCTest
@testable import HIDPPKit

final class DeviceRegistryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_060)

    private func reading(_ id: String, _ name: String, _ pct: Int?,
                         _ state: ChargeState = .discharging,
                         _ transport: Transport = .receiver) -> DeviceReading {
        DeviceReading(id: id, name: name, percent: pct, state: state, transport: transport)
    }

    func testMergeAddsScannedDevicesAsOnline() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81)], now: t0)
        XCTAssertEqual(reg.devices.count, 1)
        let d = reg.devices[0]
        XCTAssertEqual(d.id, "U:1")
        XCTAssertEqual(d.percent, 81)
        XCTAssertTrue(d.isOnline)
        XCTAssertEqual(d.lastSeen, t0)
    }

    func testMergeUpdatesExistingDevice() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81)], now: t0)
        reg.merge(scan: [reading("U:1", "G502 X", 79, .charging)], now: t1)
        XCTAssertEqual(reg.devices.count, 1)
        XCTAssertEqual(reg.devices[0].percent, 79)
        XCTAssertEqual(reg.devices[0].state, .charging)
        XCTAssertEqual(reg.devices[0].lastSeen, t1)
        XCTAssertTrue(reg.devices[0].isOnline)
    }

    func testMissingDeviceGoesOfflineButKeepsLastKnown() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81)], now: t0)
        reg.merge(scan: [], now: t1)
        XCTAssertEqual(reg.devices.count, 1)
        XCTAssertFalse(reg.devices[0].isOnline)
        XCTAssertEqual(reg.devices[0].percent, 81)   // retained
        XCTAssertEqual(reg.devices[0].lastSeen, t0)  // not refreshed
    }

    func testDeviceComesBackOnline() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81)], now: t0)
        reg.merge(scan: [], now: t1)
        reg.merge(scan: [reading("U:1", "G502 X", 60)], now: t1)
        XCTAssertTrue(reg.devices[0].isOnline)
        XCTAssertEqual(reg.devices[0].percent, 60)
    }

    func testSortedOnlineBeforeOfflineThenByName() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:z", "Zeta", 50), reading("U:a", "Alpha", 50)], now: t0)
        reg.merge(scan: [reading("U:a", "Alpha", 50)], now: t1)  // Zeta now offline
        let order = reg.sorted.map(\.name)
        XCTAssertEqual(order, ["Alpha", "Zeta"])  // online Alpha first, offline Zeta last
    }

    func testPrimaryFavouriteWinsEvenWhenOffline() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81), reading("U:2", "MX", 50)], now: t0)
        reg.merge(scan: [reading("U:2", "MX", 50)], now: t1)  // U:1 offline
        XCTAssertEqual(reg.primary(favouriteID: "U:1")?.id, "U:1")
    }

    func testPrimaryFallsBackToFirstOnlineWhenNoFavourite() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:1", "G502 X", 81), reading("U:2", "MX", 50)], now: t0)
        reg.merge(scan: [reading("U:2", "MX", 50)], now: t1)  // U:1 offline
        XCTAssertEqual(reg.primary(favouriteID: nil)?.id, "U:2")  // first online
    }

    func testPrimaryFallsBackToFirstOnlineWhenFavouriteUnknown() {
        var reg = DeviceRegistry()
        reg.merge(scan: [reading("U:2", "MX", 50)], now: t0)
        XCTAssertEqual(reg.primary(favouriteID: "U:gone")?.id, "U:2")
    }

    func testPrimaryNilWhenEmpty() {
        let reg = DeviceRegistry()
        XCTAssertNil(reg.primary(favouriteID: nil))
    }
}
