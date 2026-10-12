# Open Bulb 💡

A macOS menu bar app that controls Wi-Fi bulbs built on the Tuya platform straight over your local network. No cloud round trips, no phone app needed after setup. Tested with the Elgin Smart 15W bulb and compatible with any Tuya based bulb.

The menu bar icon reflects the real state of the lamp: on, off, and its current color.

## What it does

- Dynamic menu bar icon that shows the bulb state and color
- One click on and off, plus a brightness slider
- White mode with warm to cool temperature control
- Color mode with a custom color wheel
- Favorites: save a state and apply it with one click
- Setup entirely inside the app, with a QR code wizard
- Optional launch at login
- Changes made from the phone app show up in the menu bar through state polling

## How it works

Tuya bulbs speak a local protocol on your Wi-Fi network. Open Bulb implements it in pure Swift with zero dependencies.

- Discovery: listens for UDP broadcasts on ports 6666 and 6667, and also sweeps the local network for the Tuya TCP port when broadcasts are filtered
- Control: TCP on port 6668
- Protocols 3.1, 3.3, 3.4 and 3.5, including the 3.4 session key handshake with HMAC-SHA256 and the 3.5 framing with AES-GCM
- Bulb data points: 20 power, 21 mode, 22 brightness, 23 temperature, 24 color

The protocol implementation was ported from the community reference [tinytuya](https://github.com/jasonacox/tinytuya) and covered by 22 unit tests that check crypto and framing byte by byte.

## Requirements

- macOS 14 or newer
- Xcode command line tools (Swift 5.9+)
- A bulb already paired in the vendor app (Elgin Smart, Smart Life or Tuya Smart)
- A free developer account at [iot.tuya.com](https://iot.tuya.com)

## Setup

Build and install the app:

```bash
./Scripts/build.sh --install
```

Then open Open Bulb from /Applications and follow the wizard:

1. Create a free account at iot.tuya.com. Under Cloud, create a Smart Home project. Accounts created in Brazil usually live in the Western America data center. Copy the Access ID and Access Secret from the Authorization tab.
2. Enter those credentials in the app. It shows a QR code.
3. Scan the QR with the vendor app on your phone (Elgin Smart: Me tab, scan icon). This links your account so the app can fetch the device id and local key.
4. Pick your bulb. The app finds it on the network and finishes on its own.

The first run needs one more thing: when macOS asks for Local Network permission, allow it. You can also check this later under System Settings, Privacy and Security, Local Network.

The Tuya account is only used during setup to fetch the local key. All day to day control happens on your Wi-Fi network.

## The CLI

The same build produces a debug tool called openbulb-cli:

```bash
swift build

# find Tuya devices on the network (passive UDP listening)
.build/debug/openbulb-cli discover

# active subnet sweep, useful when broadcasts do not arrive
.build/debug/openbulb-cli scan

# full state of the configured bulb
.build/debug/openbulb-cli dump

# power
.build/debug/openbulb-cli on
.build/debug/openbulb-cli off

# brightness 0 to 1, white temperature 0 warm to 1 cool
.build/debug/openbulb-cli set --brightness 0.5
.build/debug/openbulb-cli set --temp 0.3

# color as r,g,b or h,s,v
.build/debug/openbulb-cli set --rgb 255,0,0
.build/debug/openbulb-cli set --hsv 120,1,1

# stored configuration
.build/debug/openbulb-cli config --show
```

Flags override the stored config: `--id`, `--key`, `--ip`, `--version`.

## Development

```bash
swift build
swift test
```

The code is organized in three SwiftPM modules: TuyaLocal (protocol, crypto and discovery), TuyaCloud (setup wizard API client) and OpenBulb (the SwiftUI app).

## Known limitations

- One bulb at a time
- The bulb IP comes from DHCP. If the router changes it, run the wizard again or use `openbulb-cli scan`
- Vendor apps can hold a local connection to the bulb, which may briefly block Open Bulb commands

## Credits

- [tinytuya](https://github.com/jasonacox/tinytuya), the community reference for the Tuya local protocol
- [tuya-convert](https://github.com/ct-Open-Source/tuya-convert), source of the public broadcast key

## License

MIT. See [LICENSE](LICENSE).
