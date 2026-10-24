# CouchKeys

A macOS menu-bar remote for a TCL Roku TV, with laptop-keyboard text entry for Netflix search and other compatible TV text fields.

CouchKeys connects directly to the TV over your local network. The native app runs without a browser, Python server, or open Terminal window. An optional web interface provides remote controls and a Safari/AirPlay workflow.

## What it does

- **Keyboard input:** type a search on your Mac and send it to the TV, with separate Backspace and Enter controls.
- **Navigation and playback:** directional pad, OK, Home, Back, Options, play/pause, rewind, and forward.
- **Apps and inputs:** launch Netflix, YouTube, or another app/input reported by the TV.
- **Sound:** volume slider, volume buttons, and mute, with TV readback.
- **Picture:** select modes and settings that the current TV input actually exposes. Available choices come from the TV, not a fixed list of assumed capabilities.
- **Power:** explicit screen-on/off commands and a separate Wake-on-LAN action.

This is a single-TV setup, not a universal remote or an automatic device-discovery app. The current implementation verifies a configured TCL Roku TV by vendor and serial number before controlling it.

## Interface

The native app and web interface use the dark settings-screen palette from [House Control for Android](https://github.com/0xProbabillity/house-control-android), with colors taken directly from its [Theme.kt](https://github.com/0xProbabillity/house-control-android/blob/HEAD/app/src/main/kotlin/dev/housecontrol/android/ui/Theme.kt): background `#0A0E1A`, blue `#3D8BFF`, warm accent `#FFB46B`, text `#F3F5FA`, green `#4ADE80`, and error red `#FF786E`.

Cards have 22-point corners, a 5.5% white surface, and an 8.5% white border. Primary buttons use the reference's `#5AA2FF` to `#2F7BF2` blue fill; supporting controls use neutral translucent surfaces, muted labels, and small tinted icon badges.

The interface is static: no 3D TV illustration, decorative animation, bevels, glow, hover lift, or press-depth movement. Buttons retain color feedback, and the keyboard field has a blue focus outline. TV status is read from the device, not represented by a simulated video preview.

## Requirements

For the native app:

- macOS 14 or later.
- A Swift 6 toolchain to build from source.
- The Mac and configured TV must be reachable on the same local network.
- On the TV, enable **Settings → System → Advanced system settings → Control by mobile apps → Network access → Enabled**.
- Allow Local Network access on the Mac if prompted.

For the optional web interface, also install Python 3 and the dependencies in `requirements.txt`. Safari/AirPlay browsing requires AirPlay enabled on the TV; automatic receiver selection also depends on macOS Accessibility permission for the process running the server.

## Build and install

From the project directory:

```sh
bash build.sh
open "$HOME/Applications/CouchKeys.app"
```

The installer builds the release executable, generates the app icon, packages and ad-hoc signs `CouchKeys.app`, verifies its signature, and installs it in `~/Applications`. It also creates a Desktop shortcut unless an unrelated item already occupies that name.

When replacing an existing CouchKeys installation, the installer keeps the previous app under:

```text
~/Library/Application Support/CouchKeys/Backups/
```

CouchKeys is a menu-bar app. Open it from Applications or the Desktop shortcut, then click the **TV icon in the menu bar**. To quit, use **Remote options → Quit CouchKeys**.

The bundle identifier remains `local.tclremote.menubar` to preserve the app's existing identity during the rename; the displayed name and executable are CouchKeys.

## Search Netflix using your laptop keyboard

1. Open Netflix on the TV and navigate to **Search** so its text-entry screen is active.
2. Open CouchKeys and find the **Keyboard** section.
3. Type or paste into **Search text…**.
4. Press **Return** or click **Send** to append the draft to the focused TV field.
5. Use **Delete on TV** to send Backspace, or **Enter on TV** to send Enter to the TV.

Typing edits a local draft; characters are not streamed to the TV as you type. Editing that draft does not erase text already sent. Text is sent as ordered UTF-8 literal keys using [Roku's External Control Protocol](https://developer.roku.com/dev/docs/external-control-api).

The draft is consumed once when submitted. A failed or partial send is not automatically replayed: check the TV before entering more text to avoid duplicates. Empty drafts and text containing tabs, newlines, or ASCII control characters are rejected.

Keyboard handling depends on the TV app and the focused screen. A successful response confirms that the TV accepted the commands, not that Netflix displayed the intended text or search results. CouchKeys cannot read Netflix's search field back.

## Other controls

### Volume, apps, and picture

The native app reads the current app/input, volume, mute, power, and available picture state. Operations with exposed state use readback rather than treating a sent request as proof of a change. Refresh after using another remote or when the app reports cached state.

Picture settings belong to the TV's current input and picture mode. CouchKeys checks that context before writing; if it changed, refresh instead of applying a setting to a different profile. Numeric panel backlight and black-level brightness are not exposed by the verified interface. Gamma is not backlight brightness.

### Power and wake

Power changes are spaced by 10 seconds because immediate reverse commands were ignored during device testing. Startup and navigation can also wait for that settling interval.

**Send Wake packet** sends a network wake packet; it does not prove that the screen turned on. Wait, refresh, and use **Turn TV on** if necessary. Standby wake depends on the TV's power and network settings.

Fast TV Start was previously enabled for the configured TV. Its original and enabled-state records are kept in `device-backups/`. This setting increases standby power; installing CouchKeys does not itself change it.

## Optional web interface

From the project directory:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python src/web/server.py --open
```

The server listens on `http://127.0.0.1:8765`. On this Mac, the Desktop launcher is named **CouchKeys Web.command**. Keep its Terminal process running while using the web interface; press **Control-C** there to stop it.

The web interface provides TV navigation, sound, app/input launching, picture controls, power, and wake. Laptop-to-TV search text entry is in the **native app**, not the web interface.

### Browse on the TV with AirPlay

The web interface can open Safari on the Mac and request AirPlay mirroring to the verified TV receiver. Complete any pairing and display-sharing prompts. Use **Mirror Entire Screen** if you want the TV to show the same desktop.

This is Safari running on the Mac, not a browser installed on Roku. Use the Mac's keyboard and trackpad normally. Mirroring may expose visible windows and notifications, and protected video may prohibit screen mirroring. The app can inspect Mac display topology, but it cannot confirm everything visible on the TV or detect every window-only sharing session.

## TV configuration

Native connection settings are in `src/native/Models.swift`, in `TVTarget.configured`: host, serial number, display name, Wi-Fi MAC address, and broadcast address. Rebuild and reinstall after changing them.

The web server's target defaults and device identity are in `src/web/server.py`. Its `--tv`, `--broadcast`, and `--port` options override network addresses, not the serial-number identity check. If the TV's IP changes, update the native target and use `.venv/bin/python src/web/server.py --tv NEW_IP --open` for the web server. Do not disable identity verification to work around a connection problem.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| TV cannot be reached | TV address, local network connection, and Mac Local Network permission. |
| Controls are unavailable | TV must report PowerOn and enabled mobile-app network control; refresh stale state. |
| Keyboard text does not appear | Open the TV app's text-entry screen first; that app must handle literal keyboard input. |
| A send failed partway | Check the TV before sending more text. No automatic replay is performed. |
| Picture options are missing | The current signal/input may not expose them. No guessed settings are substituted. |
| Wake does not turn the screen on | Wait, refresh, and check the TV's standby/network configuration. |
| AirPlay selection fails | Check AirPlay, pairing prompts, and Accessibility permission, or use Mac Control Center → Screen Mirroring. |
| Web port is occupied | Reuse the matching local server with `--open`, or choose another `--port`. A different app or TV target is not silently reused. |

## Source layout

```text
src/
  native/             SwiftUI/AppKit app, state management, and TV transport
  web/
    server.py         Localhost web server and TV/AirPlay integration
    index.html        Web interface and usage guidance
    *.applescript     macOS AirPlay helpers
  resources/          App metadata and third-party attribution
  tools/              App icon generator
Package.swift         Native executable package definition
build.sh              Release build and local app installer
requirements.txt      Pinned Python dependency
device-backups/       Existing TV configuration records
```

All app implementation lives under `src/`. Run the commands above from the project root. Generated builds and preserved pre-restructure caches are under `.build/`; the local Python environment remains in `.venv/`. Device backups are data, not source, and stay separate.

## Safety and attribution

TV control stays on the local network. The web server binds to loopback, checks local request origins, and requires a per-session token for mutations. Neither interface automatically retries a command after an uncertain connection failure. No root access, custom firmware, or TV package removal is required.

CouchKeys is an independent local utility, not an official TCL, Roku, or Netflix app. The menu-bar design was inspired by LGwebOS-menubar; its MIT notice is retained in `src/resources/LGwebOS-menubar-LICENSE.txt` and included in the installed app as `Reference-LICENSE.txt`.
