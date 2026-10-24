# CouchKeys

A macOS menu-bar remote for a TCL Roku TV, with laptop-keyboard text entry for Netflix search and other compatible TV text fields.

CouchKeys connects directly to the TV over your local network. The native app runs without a browser, Python server, or open Terminal window. An optional web interface provides remote controls and a Safari/AirPlay workflow.

## Quick start: run on your Mac

Use **macOS 14 or later** and **Swift 6 or later**. The native app does **not** need Python or a running web server.

### 1. Install the Mac build tools once

If you do not already have Apple's Command Line Tools or Xcode, run:

```sh
xcode-select --install
```

Finish the macOS installer, then check the compiler:

```sh
/usr/bin/swift --version
```

It must report Swift **6.0 or newer**. If it reports an older version, update Xcode or the Command Line Tools before continuing. If Swift 6+ is already installed, skip the installation step.

### 2. Get the code

This repository is private, so your GitHub account needs access. With the [GitHub CLI](https://cli.github.com/) installed:

```sh
gh auth login
gh repo clone NikhithVasa/couchkeys
cd couchkeys
```

Already authenticated? Skip `gh auth login`. Alternatively, sign in to GitHub in your browser, select **Code → Download ZIP**, extract it, and open Terminal in the extracted project folder. You do not need the GitHub CLI for the ZIP option.

### 3. Check the TV, build, and open

Turn on the TV and connect the Mac and TV to the same local network. On the TV, enable **Settings → System → Advanced system settings → Control by mobile apps → Network access → Enabled**.

The source is preconfigured for the existing TV, not automatic discovery. If you are using a different TV or its IP address changed, follow [TV configuration](#tv-configuration) **before building**.

From the project folder, run:

```sh
bash build.sh
open "$HOME/Applications/CouchKeys.app"
```

### 4. Use the app

Allow **Local Network** access if macOS asks. Click the **TV icon in the menu bar** to open CouchKeys; a Desktop shortcut is also created. You can close Terminal after launching the native app.

For keyboard search, open **Search in Netflix on the TV** first, then type into CouchKeys' **Keyboard** field and press **Return** or **Send**.

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

For the optional web interface, also install Python **3.9 or later** and the dependencies in `requirements.txt`. Safari/AirPlay browsing requires AirPlay enabled on the TV; automatic receiver selection also depends on macOS Accessibility permission for the process running the server.

## Update an existing checkout

Quit CouchKeys using **Remote options → Quit CouchKeys** before replacing the installed app. From a Git checkout, pull the latest code, rebuild, and reopen:

```sh
git pull --ff-only
bash build.sh
open "$HOME/Applications/CouchKeys.app"
```

If you downloaded a ZIP instead, download and extract the latest ZIP and run the build/open commands from that folder without `git pull`. Keep any local TV-configuration changes before updating. To rebuild only, skip `git pull`.

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

Fast TV Start was previously enabled for the configured TV. Its original and enabled-state records remain in the original machine's `device-backups/` folder, which is ignored by Git and not included in a clone or ZIP. Those records are not required to run the app. This setting increases standby power; installing CouchKeys does not itself change it.

## Optional web interface

Use this only if you want browser-based controls; it is not needed for the native app. With **Python 3.9+** installed, run these commands from the project folder:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python src/web/server.py --open
```

The `--open` flag opens the local page in your browser. Its address is **http://127.0.0.1:8765**. Keep this Terminal process running while using the web interface; press **Control-C** there to stop it. To start it again, run only `.venv/bin/python src/web/server.py --open`; you do not need to recreate the environment or reinstall dependencies each time.

If port 8765 is used by a different app, run `.venv/bin/python src/web/server.py --port 8766 --open` and use **http://127.0.0.1:8766**. A running CouchKeys server for the same TV can be reused by `--open`.

The web interface provides TV navigation, sound, app/input launching, picture controls, power, and wake. Laptop-to-TV search text entry is in the **native app**, not the web interface.

### Browse on the TV with AirPlay

The web interface can open Safari on the Mac and request AirPlay mirroring to the verified TV receiver. Complete any pairing and display-sharing prompts. Use **Mirror Entire Screen** if you want the TV to show the same desktop.

This is Safari running on the Mac, not a browser installed on Roku. Use the Mac's keyboard and trackpad normally. Mirroring may expose visible windows and notifications, and protected video may prohibit screen mirroring. The app can inspect Mac display topology, but it cannot confirm everything visible on the TV or detect every window-only sharing session.

## TV configuration

The checkout contains settings for one existing TCL Roku TV. Another Mac on the same network can use those settings if the TV's address is unchanged. A different TV must be configured explicitly; there is no first-launch device picker.

Find the TV's IP address under **Settings → Network → About** and its serial number under **Settings → System → About**. To inspect the configured TV from your Mac, replace the address below if necessary:

```sh
TV_IP=10.0.0.128
curl --noproxy '*' --connect-timeout 3 --max-time 5 "http://${TV_IP}:8060/query/device-info"
```

The response includes `serial-number`, `wifi-mac`, vendor, power mode, and mobile-app network-control state. Use `serial-number`, not `device-id` or `udn`.

For the **native app**, edit `TVTarget.configured` in `src/native/Models.swift`:

| Field | Value |
| --- | --- |
| `host` | The TV's literal IPv4 address, without `http://` or a port. |
| `serial` | The TV's exact serial number. |
| `name` | Your preferred display label. |
| `wifiMAC` | The TV's six Wi-Fi MAC bytes; used for network wake. |
| `broadcast` | Your network's broadcast address; used for network wake. |

Quit the app, then rerun `bash build.sh` and `open "$HOME/Applications/CouchKeys.app"` after changing these values.

For the **web interface**, set `SERIAL` and `WIFI_MAC` near the top of `src/web/server.py` for a different TV. `WIFI_MAC` is the Wi-Fi MAC as 12 hexadecimal digits without separators. Pass addresses on startup:

```sh
.venv/bin/python src/web/server.py --tv 10.0.0.128 --broadcast 10.0.0.255 --open
```

Replace those addresses with your TV and network values. `--tv`, `--broadcast`, and `--port` override network addresses, **not** the serial-number identity check. Stop and restart the server after editing its configuration. Both interfaces verify the TCL vendor and configured serial number; do not disable that check to work around a connection problem.

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
device-backups/       Optional local TV records; not tracked in Git
```

All app implementation lives under `src/`. Run the commands above from the project root. Generated builds use `.build/`, and the local Python environment uses `.venv/`. Those generated folders and any local device backups are ignored by Git; a fresh checkout creates the required build/environment files when you follow the setup commands.

## Safety and attribution

TV control stays on the local network. The web server binds to loopback, checks local request origins, and requires a per-session token for mutations. Neither interface automatically retries a command after an uncertain connection failure. No root access, custom firmware, or TV package removal is required.

CouchKeys is an independent local utility, not an official TCL, Roku, or Netflix app. The menu-bar design was inspired by LGwebOS-menubar; its MIT notice is retained in `src/resources/LGwebOS-menubar-LICENSE.txt` and included in the installed app as `Reference-LICENSE.txt`.
