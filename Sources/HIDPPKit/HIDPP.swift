import Foundation
import IOKit
import IOKit.hid

// HID++ 2.0 over a Logitech Lightspeed receiver.
//
// The G502 X Lightspeed talks to its USB dongle, which macOS enumerates as one
// or more HID interfaces under Vendor 0x046D. The HID++ control channel lives on
// a vendor-defined collection (usage page 0xFF00) and uses two report IDs:
//   0x10  "short"  report, 7 bytes total
//   0x11  "long"   report, 20 bytes total
//
// Frame layout (byte 0 is the report ID):
//   [0] reportID
//   [1] deviceIndex   (pairing slot on the receiver; 0x01 = first paired device, 0xFF = direct/wired)
//   [2] featureIndex  (resolved at runtime via the Root feature)
//   [3] (funcId << 4) | swId
//   [4..] params
//
// We don't hardcode feature indices: HID++ requires asking the Root feature (index 0x00)
// for the index of a given feature ID, then calling functions on that index.

private let kVendorLogitech = 0x046D
private let kUsagePageHIDPP = 0xFF00

private let kShortReportID: UInt8 = 0x10
private let kLongReportID: UInt8 = 0x11

private let kSwID: UInt8 = 0x08  // arbitrary 1..15 tag so we can tell our replies from notifications

// Feature IDs we know how to read a percentage out of, in priority order.
private let kFeatureUnifiedBattery: UInt16 = 0x1004  // newer devices (G502 X likely)
private let kFeatureBatteryStatus: UInt16  = 0x1000  // older devices

public enum ChargeState {
    case discharging   // on battery
    case charging      // cable in, actively charging
    case full          // cable in, charge complete
    case unknown

    public var isOnPower: Bool { self == .charging || self == .full }
}

public struct BatteryReading {
    public let percent: Int
    public let state: ChargeState
    public let detail: String
}

public struct BatteryError: Error { public let message: String }

public final class HIDPP: @unchecked Sendable {
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private let queue = DispatchQueue(label: "kiwi.ap.g502.hidpp")
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    // request/response synchronisation
    private let lock = NSLock()
    private var responseSem = DispatchSemaphore(value: 0)
    private var expectedFeature: UInt8 = 0xFF
    private var expectedDeviceIndex: UInt8 = 0xFF
    private var lastResponse: [UInt8] = []

    // pairing slot to talk to; we try 0x01 first then 0xFF.
    public var deviceIndex: UInt8 = 0x01
    public var verbose = false  // probe flips this on; the app leaves it quiet

    public init() {}

    deinit { inputBuffer.deallocate() }

    // MARK: - Setup

    public func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: kVendorLogitech,
            kIOHIDDeviceUsagePageKey as String: kUsagePageHIDPP,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        self.manager = mgr

        // Enumerate synchronously rather than via the manager's dispatch applier:
        // registering a per-device input callback inside the manager applier traps in IOKit.
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            log("no Logitech HID++ devices found")
            return
        }
        for dev in set { setUpDevice(dev) }
        log("set up \(devices.count) HID++ device(s)")
    }

    private func setUpDevice(_ dev: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int).map { String(format: "0x%04X", $0) } ?? "?"

        let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            log(String(format: "skip %@ pid=%@: open failed 0x%08X", product, pid, openResult))
            return
        }

        // Canonical per-device order: register callback, give the device its own
        // dispatch queue, then activate. (Not the manager — the manager stays passive.)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPP>.fromOpaque(context).takeUnretainedValue()
            // The report buffer already includes the report ID as byte 0.
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            me.handleInput(bytes)
        }, ctx)
        IOHIDDeviceSetDispatchQueue(dev, queue)
        IOHIDDeviceActivate(dev)

        devices.append(dev)
        log("ready: \(product) pid=\(pid)")
    }

    private func handleInput(_ bytes: [UInt8]) {
        guard bytes.count >= 5 else { return }
        log("<- " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        // Frame: [reportID, deviceIndex, featureIndex, funcID|swID, params…]
        // Error frame: [reportID, deviceIndex, 0x8F, failedFeatureIndex, funcID|swID, errorCode]
        let deviceIdx = bytes[1]
        let isError = bytes[2] == 0x8F
        // ERR_BUSY (0x08) is a transient "processing" ack the receiver sends right before
        // the real reply arrives as a separate (usually long) report. Ignore it and keep waiting.
        if isError && bytes.count >= 6 && bytes[5] == 0x08 { return }
        let feature = isError ? bytes[3] : bytes[2]
        let swid = isError ? (bytes[4] & 0x0F) : (bytes[3] & 0x0F)
        lock.lock()
        let waitFeature = expectedFeature
        let waitDevice = expectedDeviceIndex
        lock.unlock()
        // Match our outstanding request by device index + swID + feature (or error).
        // This rejects unsolicited receiver notifications and replies for other slots.
        if deviceIdx == waitDevice && swid == kSwID && (feature == waitFeature || isError) {
            lock.lock(); lastResponse = bytes; lock.unlock()
            responseSem.signal()
        }
    }

    // MARK: - Request/response

    /// Sends one HID++ request and waits for the matching reply. Runs on the caller's thread
    /// (not `queue`), so the callback on `queue` can signal the semaphore without deadlock.
    /// Retries on ERR_BUSY (0x08), which the receiver returns transiently before the device
    /// delivers the real reply.
    private func request(reportID: UInt8, featureIndex: UInt8, funcID: UInt8,
                         params: [UInt8], timeout: TimeInterval = 1.2) -> [UInt8]? {
        guard !devices.isEmpty else { return nil }
        let len = reportID == kShortReportID ? 7 : 20
        var frame = [UInt8](repeating: 0, count: len)
        frame[0] = reportID
        frame[1] = deviceIndex
        frame[2] = featureIndex
        frame[3] = (funcID << 4) | kSwID
        for (i, p) in params.enumerated() where 4 + i < len { frame[4 + i] = p }

        for attempt in 0..<6 {
            lock.lock()
            expectedFeature = featureIndex
            expectedDeviceIndex = deviceIndex
            lastResponse = []
            lock.unlock()
            // drain any stale signal
            while responseSem.wait(timeout: .now()) == .success {}

            log("-> " + frame.map { String(format: "%02X", $0) }.joined(separator: " "))
            // Broadcast to every matched FF00 collection; only the right one answers, and
            // handleInput() routes the reply back by device index + feature + swID.
            var anySent = false
            for dev in devices {
                let r = frame.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, len)
                }
                if r == kIOReturnSuccess { anySent = true }
            }
            guard anySent else { log("SetReport failed on all devices"); return nil }
            guard responseSem.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); let resp = lastResponse; lock.unlock()

            // Error reply: feature index byte == 0x8F (ERROR).
            if resp.count >= 6 && resp[2] == 0x8F {
                let code = resp[5]
                log(String(format: "  HID++ error: idx=0x%02X func/sw=0x%02X code=0x%02X", resp[3], resp[4], code))
                if code == 0x08 {  // BUSY: wait briefly and resend
                    usleep(120_000)
                    continue
                }
                return nil
            }
            return resp
        }
        return nil
    }

    /// Asks the Root feature (index 0x00, function 0x00) for the index of a feature ID.
    /// Returns 0 if the device doesn't support it.
    private func featureIndex(of featureID: UInt16) -> UInt8? {
        let resp = request(reportID: kShortReportID, featureIndex: 0x00, funcID: 0x00,
                           params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)])
        guard let resp, resp.count >= 5 else { return nil }
        let idx = resp[4]
        return idx == 0 ? nil : idx
    }

    // MARK: - Public

    public func readBattery() -> Result<BatteryReading, BatteryError> {
        log("readBattery called, devices=\(devices.count)")
        guard !devices.isEmpty else { return .failure(BatteryError(message: "no receiver yet")) }

        // Fixed list (don't build from the mutable property, or it sticks at the last value).
        // Lightspeed pairs at slot 0x01; 0xFF is the receiver itself.
        for idx in [0x01, 0x02, 0x03, 0xFF] as [UInt8] {
            deviceIndex = idx

            if let bi = featureIndex(of: kFeatureUnifiedBattery),
               let r = readUnifiedBattery(featureIndex: bi) {
                return .success(r)
            }
            if let bi = featureIndex(of: kFeatureBatteryStatus),
               let r = readBatteryStatus(featureIndex: bi) {
                return .success(r)
            }
        }
        return .failure(BatteryError(message: "no battery feature answered (try waking the mouse)"))
    }

    // UNIFIED_BATTERY 0x1004, get_status = function 0x01
    //   reply params: [0]=state-of-charge %, [1]=level enum, [2]=charging status
    //   charging status enum: 0=discharging, 1=charging, 2=charging(slow), 3=charge complete
    private func readUnifiedBattery(featureIndex bi: UInt8) -> BatteryReading? {
        guard let resp = request(reportID: kShortReportID, featureIndex: bi, funcID: 0x01, params: []),
              resp.count >= 7 else { return nil }
        let pct = Int(resp[4])
        let state: ChargeState
        switch resp[6] {
        case 0:    state = .discharging
        case 1, 2: state = .charging
        case 3:    state = .full
        default:   state = .unknown
        }
        guard pct > 0 && pct <= 100 else { return nil }
        return BatteryReading(percent: pct, state: state,
                              detail: "unified-battery idx=\(bi) raw=\(hex(resp))")
    }

    // BATTERY_STATUS 0x1000, getBatteryLevelStatus = function 0x00
    //   reply params: [0]=discharge level %, [1]=next level, [2]=status
    private func readBatteryStatus(featureIndex bi: UInt8) -> BatteryReading? {
        guard let resp = request(reportID: kShortReportID, featureIndex: bi, funcID: 0x00, params: []),
              resp.count >= 7 else { return nil }
        let pct = Int(resp[4])
        // 0x1000 status: 0=discharging, 1=recharging, 2=charge-complete, 3=charging-error…
        let state: ChargeState
        switch resp[6] {
        case 0:  state = .discharging
        case 1:  state = .charging
        case 2:  state = .full
        default: state = .unknown
        }
        guard pct > 0 && pct <= 100 else { return nil }
        return BatteryReading(percent: pct, state: state,
                              detail: "battery-status idx=\(bi) raw=\(hex(resp))")
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private func log(_ s: String) { if verbose { FileHandle.standardError.write(Data(("[hidpp] " + s + "\n").utf8)) } }
}
