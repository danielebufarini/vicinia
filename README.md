# Vicinia

Vicinia is a native iPhone and iPad app for accessing your Mac over the local
network. It uses Apple's High Performance Screen Sharing (HPSS) protocol.

You can work on your Mac directly from the touchscreen or use a keyboard,
mouse or trackpad.

## Features

- High Performance Screen Sharing in Adaptive mode.
- Hardware-accelerated HEVC decoding, including 4:4:4, with Metal rendering.
- Encrypted connections with host-key verification.
- Remote mouse and keyboard input, with pointer lock.
- Pinch to zoom and pan around the desktop.
- A toolbar that stays out of the way until you need it.

Vicinia 1.0 connects directly to your Mac over the local network. It does not
require Internet port forwarding.

## Requirements

- iPhone or iPad running iOS or iPadOS 27 or later.
- A Mac running macOS 27 or later with Screen Sharing enabled.

To build the app, you'll need Xcode 27 or later and Swift 6.4 or later.

## Getting started

Enable Screen Sharing on your Mac, then open Vicinia on your iPhone or iPad.
Enter your Mac's IP address or hostname and your macOS username and password.

The first time you connect, Vicinia asks you to verify the Mac's key fingerprint
before trusting it. The key is saved for future connections.

Once connected, double-tap with two fingers to show or hide the toolbar. It
also disappears automatically after five seconds of inactivity.

See the [user manual](Docs/v1/USER_MANUAL.md) for setup instructions, gestures
and troubleshooting.

## Building from source

First, build the C dependencies from the repository root:

```sh
./build-deps.sh
```

The script builds OpenSSL 3.5.9 (`libcrypto`) and libSRTP 2.8.1 for arm64 iOS
devices and simulators. The dependencies are built locally in `Vendor/`.

Open `Vicinia.xcodeproj` in Xcode, select the Vicinia scheme and choose your
device or simulator. Set up code signing if you're building for a physical
device.

You can also build from the command line:

```sh
xcodebuild -project Vicinia.xcodeproj -scheme Vicinia -configuration Debug \
  -destination 'id=<simulator-udid>' -derivedDataPath build/standard-debug build
```

For a physical device, use its UDID instead and add
`-allowProvisioningUpdates`. The Metal shaders are compiled at runtime, so
there's no need to install the separate Metal Toolchain.

## Testing

The repository includes Swift regression tests. To run them, open
`Vicinia.xcodeproj` in Xcode and choose Product > Test, or run from the
command line:

```sh
xcodebuild -project Vicinia.xcodeproj -scheme Vicinia -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Air' -derivedDataPath build/test test
```

To run the tests on a connected device, use its UDID as the destination
instead. The suite contains 174 tests; one hardware-decoding test is skipped
on simulators.

## License

Vicinia is released under the [MIT License](LICENSE).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of the
third-party components used by the app.
