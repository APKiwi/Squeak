# G502Battery

Menu-bar battery readout for a Logitech G502 X Lightspeed on macOS, without G Hub.
Talks HID++ to the Lightspeed receiver directly via IOKit. No G Hub, no Options+, no daemon.

## Layout

- `Sources/HIDPPKit` - the HID++ 2.0 transport (open receiver, send/receive reports, resolve features, read battery).
- `Sources/G502Battery` - the SwiftUI `MenuBarExtra` app (no Dock icon).
- `Sources/g502probe` - a plain CLI that polls battery and dumps every HID++ frame to stderr. Use this to debug the protocol.

## Build

    swift build

## Run the menu-bar app

    swift run G502Battery

Menu-bar-only (`LSUIElement`/`.accessory`), shows `NN%` with a battery glyph. "Refresh now" and "Quit" in the menu.

## Run the probe (debugging)

    ./.build/debug/g502probe

Polls once a second up to 15 times, prints `BATTERY: NN%` on success, otherwise logs the raw `->`/`<-` frames and decoded HID++ error codes.

## Status

Working on macOS 26. Reads the percentage over the Lightspeed receiver and shows it in the menu bar. Verified at 11% against an awake G502 X Lightspeed.

The mouse must be awake to answer (a sleeping mouse returns `ERR_BUSY` and the read fails); the app retries a few times on launch then polls every two minutes, so it picks up a reading once you touch the mouse.

### HID++ notes

- Receiver enumerates as VID `0x046D`, usage page `0xFF00`. Two receivers were present in testing (`0xC547`, `0xC53A`); the app sets up all matching collections and broadcasts each request, routing the reply by feature index + swID.
- Frame: `[reportID, deviceIndex, featureIndex, funcID<<4|swID, params...]`. Short report `0x10` (7 bytes), long `0x11` (20 bytes). The IOKit input buffer already includes the report ID as byte 0.
- Wireless device sits at slot `0x01` on the receiver; `0xFF` addresses the receiver itself. The G502 X Lightspeed exposes UNIFIED_BATTERY (`0x1004`) at feature index 6; `get_status` (func 1) returns state-of-charge % in the first param byte.
- Each request draws two replies: an immediate short `ERR_BUSY` (0x08) ack, then the real answer as a separate long report. Ignore the BUSY and wait for the real one.
- Do NOT mix the manager dispatch queue with per-device input callbacks: registering an input callback inside the manager's activate-applier traps (`EXC_BREAKPOINT`). Enumerate with `IOHIDManagerCopyDevices`, then give each device its own queue + activate.

## License

MIT
