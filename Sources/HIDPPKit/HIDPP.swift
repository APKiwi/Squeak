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

public enum ChargeState: Equatable, Sendable {
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

public enum Transport: String, Sendable, Equatable {
    case receiver
    case bluetooth
}

/// One device seen in a single scan. A `DeviceReading` existing means the device
/// answered just now (it is online). Last-known / offline state is layered on by
/// `DeviceRegistry`, not here.
public struct DeviceReading: Sendable, Equatable {
    public let id: String          // stable: "U:<unitId>" if available, else "P:<pid>:<slot>"
    public let name: String        // e.g. "G502 X", "MX Master 3S"
    public let percent: Int?
    public let state: ChargeState
    public let transport: Transport

    public init(id: String, name: String, percent: Int?, state: ChargeState, transport: Transport) {
        self.id = id
        self.name = name
        self.percent = percent
        self.state = state
        self.transport = transport
    }
}

public struct BatteryError: Error { public let message: String }

public final class HIDPP: @unchecked Sendable {
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var pids: [Int] = []                 // parallel to devices
    private var targetDevice: IOHIDDevice?       // when set, requests go only here
    private let queue = DispatchQueue(label: "kiwi.ap.g502.hidpp")
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    // request/response synchronisation
    private let lock = NSLock()
    private var responseSem = DispatchSemaphore(value: 0)
    private var expectedFeature: UInt8 = 0xFF
    private var expectedDeviceIndex: UInt8 = 0xFF
    private var lastResponse: [UInt8] = []
    private var anySendSucceededThisCycle = false  // cleared per sweep; set when a SetReport gets through

    // pairing slot to talk to; we try 0x01 first then 0xFF.
    public var deviceIndex: UInt8 = 0x01
    public var verbose = false  // probe flips this on; the app leaves it quiet

    public init() {}

    deinit { inputBuffer.deallocate() }

    // MARK: - Setup

    public func start() {
        armManager()
        rescan()
    }

    /// Creates the HID manager and installs the Vendor 0x046D / usage-page 0xFF00 filter.
    /// Doesn't enumerate — that's `rescan()`. Split out so we can re-scan later without
    /// recreating the manager.
    public func armManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: kVendorLogitech,
            kIOHIDDeviceUsagePageKey as String: kUsagePageHIDPP,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        self.manager = mgr
    }

    /// (Re-)enumerates matching devices and sets up any we aren't already tracking.
    /// Safe to call repeatedly. This is what lets the app recover when the receiver
    /// enumerates *after* launch — notably when started as a login item before the USB
    /// HID stack is up, which a one-shot scan at startup would miss permanently.
    ///
    /// We enumerate synchronously rather than via the manager's dispatch applier:
    /// registering a per-device input callback inside the manager applier traps in IOKit.
    public func rescan() {
        guard let mgr = manager else { return }
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            log("rescan: no Logitech HID++ devices found yet")
            return
        }
        var added = 0
        for dev in set where !devices.contains(dev) { setUpDevice(dev); added += 1 }
        log(added > 0 ? "rescan: now tracking \(devices.count) HID++ device(s)"
                      : "rescan: already tracking \(devices.count) HID++ device(s)")
    }

    public var deviceCount: Int { devices.count }

    /// Probe/test seam. Reproduces the post-sleep/wake state where our captured device
    /// refs have gone stale: appends a real but un-opened HID device that is NOT part of
    /// the Vendor 0x046D / FF00 match, so `devices` is non-empty yet every SetReport on it
    /// fails, and a fresh `IOHIDManagerCopyDevices()` won't contain it (mirrors a ref that
    /// USB re-enumeration replaced with a new-identity object). Returns false if the machine
    /// has no spare HID device to borrow. Not used by the app.
    public func injectStaleDeviceForTesting() -> Bool {
        let probe = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(probe, nil)  // match everything
        guard let all = IOHIDManagerCopyDevices(probe) as? Set<IOHIDDevice> else { return false }
        let ours = (manager.flatMap { IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> }) ?? []
        // Borrow a device the HID++ matcher doesn't claim, and never open it: SetReport will
        // return kIOReturnNotOpen, exactly the all-sends-fail signature of stale refs.
        guard let victim = all.first(where: { !ours.contains($0) }) else { return false }
        let pid = IOHIDDeviceGetProperty(victim, kIOHIDProductIDKey as CFString) as? Int ?? 0
        devices.append(victim)
        pids.append(pid)
        log(String(format: "injected stale device pid=0x%04X, deviceCount=%d", pid, devices.count))
        return true
    }

    private func setUpDevice(_ dev: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        let pidInt = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let pid = String(format: "0x%04X", pidInt)

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
        pids.append(pidInt)
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
            let targets = targetDevice.map { [$0] } ?? devices
            for dev in targets {
                let r = frame.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, len)
                }
                if r == kIOReturnSuccess { anySent = true }
            }
            guard anySent else { log("SetReport failed on all devices"); return nil }
            anySendSucceededThisCycle = true
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
        // The receiver can enumerate after we launch — notably as a login item that
        // starts before the USB HID stack is up. Re-scan when we have nothing rather
        // than staying stuck forever on the empty launch-time snapshot.
        if devices.isEmpty { rescan() }
        log("readBattery called, devices=\(devices.count)")
        guard !devices.isEmpty else { return .failure(BatteryError(message: "no receiver yet")) }

        if let r = readBatteryOnce() { return .success(r) }

        // Stale-ref recovery. If the whole sweep never got a single SetReport through, our
        // device refs are dead: sleep/wake or USB re-enumeration replaced them while `devices`
        // stayed non-empty, so the empty-list rescan above couldn't fire. Reconcile against a
        // fresh enumeration and try once more. A merely-asleep mouse still accepts SetReport
        // (it just doesn't reply), so anySendSucceededThisCycle stays true and we skip this.
        if !anySendSucceededThisCycle, reconcileStaleDevices(), let r = readBatteryOnce() {
            return .success(r)
        }
        return .failure(BatteryError(message: "no battery feature answered (try waking the mouse)"))
    }

    /// One full sweep over the pairing slots, trying both battery features. Returns nil if
    /// nothing answered. Clears `anySendSucceededThisCycle` first and lets `request()` set it,
    /// so the caller can tell a dead transport (no SetReport got through) from an asleep mouse
    /// (sends fine, no reply).
    private func readBatteryOnce() -> BatteryReading? {
        anySendSucceededThisCycle = false
        // Fixed list (don't build from the mutable property, or it sticks at the last value).
        // Lightspeed pairs at slot 0x01; 0xFF is the receiver itself.
        for idx in [0x01, 0x02, 0x03, 0xFF] as [UInt8] {
            deviceIndex = idx
            if let r = batteryForCurrentSlot() { return r }
        }
        return nil
    }

    /// Battery for whatever `deviceIndex`/`targetDevice` is currently set, trying the unified
    /// feature then the older one. No slot iteration — the caller controls the slot.
    private func batteryForCurrentSlot() -> BatteryReading? {
        if let bi = featureIndex(of: kFeatureUnifiedBattery),
           let r = readUnifiedBattery(featureIndex: bi) {
            return r
        }
        if let bi = featureIndex(of: kFeatureBatteryStatus),
           let r = readBatteryStatus(featureIndex: bi) {
            return r
        }
        return nil
    }

    /// Reconciles tracked device refs against a fresh enumeration after they go stale.
    /// Closes and drops refs the OS no longer reports, and sets up any new ones, so a receiver
    /// that came back with a fresh IOHIDDevice identity after sleep/wake gets picked up where
    /// the empty-list rescan can't help (because `devices` was never empty). Returns true if
    /// the tracked set changed.
    private func reconcileStaleDevices() -> Bool {
        guard let mgr = manager else { return false }
        let fresh = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        var kept: [IOHIDDevice] = []
        var keptPids: [Int] = []
        var changed = false
        for (i, dev) in devices.enumerated() {
            if fresh.contains(dev) {
                kept.append(dev)
                keptPids.append(pids[i])
            } else {
                IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                changed = true
            }
        }
        devices = kept
        pids = keptPids
        for dev in fresh where !devices.contains(dev) { setUpDevice(dev); changed = true }
        log("reconcile: now tracking \(devices.count) HID++ device(s) after dropping stale refs")
        return changed
    }

    // DEVICE_NAME 0x0005: func 0x00 getCount -> [0]=length; func 0x01 getName(charIndex) ->
    // ASCII chunk in params. Reply may be a long (0x11) report, so we append whatever params
    // come back until we've collected `length` chars.
    private func deviceName(featureIndex bi: UInt8) -> String? {
        guard let c = request(reportID: kShortReportID, featureIndex: bi, funcID: 0x00, params: []),
              c.count >= 5 else { return nil }
        let length = Int(c[4])
        guard length > 0 && length <= 64 else { return nil }
        var chars: [UInt8] = []
        var guardCount = 0
        while chars.count < length && guardCount < 16 {
            guardCount += 1
            guard let r = request(reportID: kShortReportID, featureIndex: bi, funcID: 0x01,
                                  params: [UInt8(chars.count)]), r.count > 4 else { break }
            let chunk = Array(r[4...])
            if chunk.allSatisfy({ $0 == 0 }) { break }
            chars.append(contentsOf: chunk)
        }
        let bytes = Array(chars.prefix(length)).filter { $0 != 0 }
        let name = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name : nil
    }

    // DEVICE_INFO 0x0003 func 0x00: params [0]=entityCount, [1..4]=unitId (stable per device).
    // In the frame that's resp[4]=entityCount, resp[5..8]=unitId.
    private func unitID(featureIndex bi: UInt8) -> String? {
        guard let r = request(reportID: kShortReportID, featureIndex: bi, funcID: 0x00, params: []),
              r.count >= 9 else { return nil }
        let unit = r[5...8]
        guard unit.contains(where: { $0 != 0 }) else { return nil }
        return unit.map { String(format: "%02X", $0) }.joined()
    }

    private func transport(of dev: IOHIDDevice) -> Transport {
        let t = (IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String) ?? ""
        return t.lowercased().contains("bluetooth") ? .bluetooth : .receiver
    }

    /// Enumerate every Logitech battery device across all tracked FF00 transports. For each
    /// device we get the battery, a friendly name (feature 0x0005), and a stable id from the
    /// unit id (feature 0x0003), falling back to "P:<pid>:<slot>". Deduped by id.
    public func scanAll() -> [DeviceReading] {
        if devices.isEmpty { rescan() }
        var out: [DeviceReading] = []
        var seen = Set<String>()

        for (i, dev) in devices.enumerated() {
            let pid = pids[i]
            let trans = transport(of: dev)
            targetDevice = dev
            defer { targetDevice = nil }

            for slot in [0x01, 0x02, 0x03, 0xFF] as [UInt8] {
                deviceIndex = slot
                guard let battery = batteryForCurrentSlot() else { continue }

                let name = featureIndex(of: 0x0005).flatMap { deviceName(featureIndex: $0) }
                    ?? receiverLabel(pid)
                let id = featureIndex(of: 0x0003).flatMap { unitID(featureIndex: $0) }
                    .map { "U:\($0)" }
                    ?? String(format: "P:%04X:%02X", pid, slot)

                if seen.contains(id) { continue }
                seen.insert(id)
                out.append(DeviceReading(id: id, name: name, percent: battery.percent,
                                         state: battery.state, transport: trans))
            }
        }
        targetDevice = nil
        return out
    }

    /// Probes each receiver separately and reports which one currently hosts the mouse,
    /// at which slot, plus its battery % and charge state. Used to tell whether the mouse
    /// is connected through the Powerplay mat or a different receiver.
    public func diagnose() -> String {
        guard !devices.isEmpty else { return "No Logitech receivers found on USB." }
        var lines: [String] = []
        for (i, dev) in devices.enumerated() {
            let pid = pids[i]
            let label = receiverLabel(pid)
            targetDevice = dev
            defer { targetDevice = nil }

            var found = false
            for slot in [0x01, 0x02, 0x03] as [UInt8] {
                deviceIndex = slot
                guard let bi = featureIndex(of: kFeatureUnifiedBattery),
                      let r = readUnifiedBattery(featureIndex: bi) else { continue }
                found = true
                lines.append(String(format: "receiver 0x%04X (%@): MOUSE on slot %d -> %d%%, %@",
                                    pid, label, Int(slot), r.percent, "\(r.state)"))
            }
            if !found {
                lines.append(String(format: "receiver 0x%04X (%@): no awake mouse on slots 1-3", pid, label))
            }
        }
        targetDevice = nil
        return lines.joined(separator: "\n")
    }

    private func receiverLabel(_ pid: Int) -> String {
        switch pid {
        case 0xC53A: return "Powerplay mat"
        case 0xC547: return "Lightspeed dongle"
        default:     return "unknown receiver"
        }
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
