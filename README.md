# Moonswift

A controller-first game-streaming app for iPhone and iPad, written in Swift and SwiftUI.

Your games run on your PC. Moonswift shows the picture, plays the sound, and sends your controller, touch, keyboard and mouse input back. It speaks the Moonlight protocol and works with [Sunshine](https://github.com/LizardByte/Sunshine)-based hosts, with [Vibepollo](https://github.com/Nonary/Vibepollo) recommended.

> **Status:** in development and not on the App Store yet.

## Features

**Controllers**
- Navigate every screen with a controller, with a button legend in your controller's own glyphs
- Several controllers at once, with rumble, motion and touchpad
- DualSense adaptive triggers and waveform haptics
- Phone Rumble: game rumble on the iPhone when the controller has no motor, including the on-screen controller
- Button remapping

**Streaming**
- H.264, HEVC and AV1 (on devices that decode it in hardware), with HDR
- Up to 4K and 120 fps, or a custom width and height, depending on your device and host
- Adaptive Bitrate, which backs off when the network struggles
- Picture in Picture, resume and quit, and automatic reconnecting
- A splash screen that hides the host's desktop while a game launches, with Cancel (or Ⓑ) to stop the launch
- A Performance Overlay and an in-stream Control Center with quick actions
- Short one-time guides the first time you stream with gestures, a controller or the on-screen controller

**Touch, keyboard and mouse**
- On-screen controller with custom layouts, positioned separately for each rotation and for the iPhone Duo folded or unfolded
- Touchscreen and trackpad modes, with customizable gestures
- Hardware keyboard and mouse support (the pointer is captured while you play on iPad), plus custom key shortcuts

**Your library**
- A console-style Home and a full game library
- Automatic covers, backgrounds and logos from [SteamGridDB](https://www.steamgriddb.com) (needs your own free API key), or your own art; logos are sized evenly, with a Logo Size in Settings and a live per-game slider from Edit Game on Home
- Favorites, hidden games and voice search
- Siri Shortcuts and `moonswift://` links to launch a game (links ask before starting it)
- Reset to defaults, after asking: each Settings page (Stream, Interface), Gestures, Button Mapping, and each game in Edit Game (its name, your pictures and its overrides; favorites, hidden and chosen art stay)

**Hosts**
- Find hosts on your network automatically, or add one by address (needs Local Network access; if it was denied, Add a Host says so and links to Settings)
- PIN pairing with pinned certificates
- A remote address for playing away from home, with a Local or Remote label on each host
- Wake a sleeping PC on the same network (needs Wake-on-LAN turned on for the PC, ideally over Ethernet), from Home too when its games haven't loaded yet
- Layouts that keep content off the fold on iPhone Duo
- If the saved hosts can't be read, the app still opens and says so once; the unreadable files are kept in an `unreadable-<time>` folder, not deleted

### Features that need Vibepollo

Changing the bitrate during a stream, sharing the clipboard, putting the PC to sleep and DualSense waveform haptics rely on Vibepollo's extensions. Other Sunshine-based hosts should work for everything else, but Vibepollo is the host Moonswift is tested on.

## Requirements

- iPhone or iPad on iOS or iPadOS 26.6 or later
- A PC running a Sunshine-based host
- Xcode 27.2 or later, to build from source

## Build from source

Clone the project with its submodules (the streaming library and Mbed TLS):

```bash
git clone --recurse-submodules https://github.com/ivmatt/Moonswift.git
```

Build for the simulator:

```bash
cd Moonswift
xcodebuild -scheme Moonswift -destination 'platform=iOS Simulator,name=iPhone Duo' build
```

Run the tests:

```bash
xcodebuild -scheme Moonswift -destination 'platform=iOS Simulator,name=iPhone Duo' test
```

To run on your own device, open `Moonswift.xcodeproj` in Xcode, then set your own Team and Bundle Identifier under **Signing & Capabilities**.

## Releases

Each App Store build has a tag, `v<version>-build<build>` (for example `v1.0-build1`), in this repository and the same tag in the [moonlight-common-c fork](https://github.com/ivmatt/moonlight-common-c) on the commit this release pins, so the exact GPL source of every release stays findable. When releasing, tag both:

```bash
git tag v1.0-build1 && git push origin v1.0-build1
```

```bash
cd Packages/MoonlightCore/moonlight-common-c && git tag v1.0-build1 && git push origin v1.0-build1
```

## Documentation

| File | What it's for |
|---|---|
| [PRIVACY.md](PRIVACY.md) | What data the app handles and where it goes |

## Credits

Moonswift builds on the work of these projects:

- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c), the streaming core, used through [our fork](https://github.com/ivmatt/moonlight-common-c)
- [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios), the original iOS client, which parts of the streaming and input code are ported from
- [Nielk1](https://gist.github.com/Nielk1/6d54cc2c00d2201ccb8c2720ad7538db), for documenting the DualSense trigger effect format (MIT)
- [Nonary](https://github.com/Nonary), for the DualSense waveform haptics protocol
- [Sunshine](https://github.com/LizardByte/Sunshine) and [Vibepollo](https://github.com/Nonary/Vibepollo), the hosts
- [ENet](https://github.com/lsalzman/enet), [nanors](https://github.com/sleepybishop/nanors) and [Mbed TLS](https://github.com/Mbed-TLS/mbedtls), bundled libraries
- [SteamGridDB](https://www.steamgriddb.com), the community artwork service
- [Kenney](https://kenney.nl), the controller button icons (Input Prompts, CC0)

Moonswift is an independent project. It is not affiliated with or endorsed by Moonlight, Sunshine, Apollo, Vibepollo, SteamGridDB, or the makers of any game or controller. All trademarks belong to their owners.

## License

Moonswift is free software under the [GNU General Public License, version 3](LICENSE). The licenses of the bundled libraries are in [`Moonswift/Licenses`](Moonswift/Licenses).
