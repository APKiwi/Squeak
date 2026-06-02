import Foundation
import HIDPPKit

// Plain CLI: start HID++, then poll battery once a second for a while.
// No SwiftUI, no menu bar — just exercise the protocol and print what comes back.

let hid = HIDPP()
hid.verbose = true
hid.start()

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
