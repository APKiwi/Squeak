import Foundation
import HIDPPKit

// Plain CLI: start HID++, then poll battery once a second for a while.
// No SwiftUI, no menu bar — just exercise the protocol and print what comes back.

let hid = HIDPP()
hid.verbose = CommandLine.arguments.contains("-v")

// `squeakprobe recover` reproduces the login-item race: it arms the HID manager but
// skips the initial scan, so `devices` starts empty exactly as when the app launches
// before the receiver has enumerated. A correct readBattery() must re-scan and recover.
// Handled before start() so nothing pre-populates the device list.
if CommandLine.arguments.contains("recover") {
    hid.armManager()
    FileHandle.standardError.write(Data("recover: armed manager, deviceCount=\(hid.deviceCount) (simulated empty launch)\n".utf8))
    switch hid.readBattery() {
    case .success(let r):
        print("RECOVERED: \(r.percent)% \(r.state)  [\(r.detail)]")
        exit(0)
    case .failure(let e):
        FileHandle.standardError.write(Data("STILL STUCK: \(e.message)\n".utf8))
        exit(1)
    }
}

// `squeakprobe staledev` reproduces the post-sleep/wake (or USB re-enumeration) path the
// `recover` mode can't: it arms the manager, then injects a stale device so `devices` is
// NON-empty but every SetReport fails. The empty-list rescan in readBattery() therefore can't
// fire; only the stale-device reconcile can recover. A correct readBattery() reconciles the
// dead refs against a fresh enumeration and retries. Proves red→green like `recover` does.
// Handled before start() so nothing else pre-populates the device list.
if CommandLine.arguments.contains("staledev") {
    hid.armManager()
    guard hid.injectStaleDeviceForTesting() else {
        FileHandle.standardError.write(Data("staledev: no spare HID device to borrow; cannot stage the scenario\n".utf8))
        exit(2)
    }
    FileHandle.standardError.write(Data("staledev: injected stale device, deviceCount=\(hid.deviceCount) (every SetReport will fail)\n".utf8))
    switch hid.readBattery() {
    case .success(let r):
        print("RECOVERED FROM STALE: \(r.percent)% \(r.state)  [\(r.detail)]")
        exit(0)
    case .failure(let e):
        FileHandle.standardError.write(Data("STILL STUCK: \(e.message)\n".utf8))
        exit(1)
    }
}

hid.start()

// `squeakprobe list` prints every Logitech battery device scanAll() finds — name, %, state,
// transport, and stable id. Hardware verification for the multi-device path and the Bluetooth
// spike (connect the MX Master over BT and check it appears with transport=bluetooth).
if CommandLine.arguments.contains("list") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        let devices = hid.scanAll()
        if devices.isEmpty {
            print("no Logitech battery devices found")
        }
        for d in devices {
            let pct = d.percent.map { "\($0)%" } ?? "—"
            print("\(d.name)  \(pct)  \(d.state)  [\(d.transport.rawValue)]  id=\(d.id)")
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    exit(0)
}

// `squeakprobe diag` reports which receiver currently hosts the mouse (Powerplay vs dongle).
if CommandLine.arguments.contains("diag") {
    // give the receivers a beat to enumerate
    nonisolated(unsafe) var done = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        print(hid.diagnose())
        done = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    exit(0)
}

FileHandle.standardError.write(Data("probe: started, polling…\n".utf8))

nonisolated(unsafe) var attempts = 0
let timer = Timer(timeInterval: 1.0, repeats: true) { t in
    attempts += 1
    switch hid.readBattery() {
    case .success(let r):
        print("BATTERY: \(r.percent)% \(r.state)  [\(r.detail)]")
        t.invalidate()
        CFRunLoopStop(CFRunLoopGetMain())
    case .failure(let e):
        FileHandle.standardError.write(Data("attempt \(attempts): \(e.message)\n".utf8))
    }
    if attempts >= 15 {
        FileHandle.standardError.write(Data("giving up after \(attempts) attempts\n".utf8))
        t.invalidate()
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
RunLoop.main.add(timer, forMode: .common)
CFRunLoopRun()
