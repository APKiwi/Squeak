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

Transport works end to end on macOS 26: it opens both Logitech receivers, sends HID++ short reports, and parses replies (normal and `0x8F` error frames). What's not yet confirmed is reading an actual percentage, because every test so far hit the mouse while it was asleep/disconnected - the receiver answers the root-feature query with `unknown device` (0x08) / `connection error` (0x09) on every slot.

Next step: run `g502probe` while actively moving the mouse so it's awake and connected, and see which device index + battery feature (`0x1004` UNIFIED_BATTERY or `0x1000` BATTERY_STATUS) answers. Then lock the read path to that.

### HID++ notes

- Receiver enumerates as VID `0x046D`, usage page `0xFF00`. Two receivers were present in testing (`0xC547`, `0xC53A`); the app sets up all matching collections and broadcasts each request, routing the reply by feature index + swID.
- Frame: `[reportID, deviceIndex, featureIndex, funcID<<4|swID, params...]`. Short report `0x10` (7 bytes), long `0x11` (20 bytes). The IOKit input buffer already includes the report ID as byte 0.
- Wireless device sits at slot `0x01` on the receiver; `0xFF` addresses the receiver itself.
- Do NOT mix the manager dispatch queue with per-device input callbacks: registering an input callback inside the manager's activate-applier traps (`EXC_BREAKPOINT`). Enumerate with `IOHIDManagerCopyDevices`, then give each device its own queue + activate.

## License

MIT
