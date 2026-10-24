#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CouchKeys.app"
BUNDLE_ID="local.tclremote.menubar"
DESTINATION="$HOME/Applications/$APP_NAME"
DESKTOP_LINK="$HOME/Desktop/$APP_NAME"

/usr/bin/swift build --package-path "$ROOT" --configuration release
BIN_DIR="$(/usr/bin/swift build --package-path "$ROOT" --configuration release --show-bin-path)"

ICON="$ROOT/.build/AppIcon.icns"
if [[ ! -f "$ICON" || "$ROOT/src/tools/MakeIcon.swift" -nt "$ICON" ]]; then
    ICONSET="$ROOT/.build/AppIcon.iconset"
    /usr/bin/swift -module-cache-path "$ROOT/.build/IconModuleCache" "$ROOT/src/tools/MakeIcon.swift" "$ICONSET"
    /usr/bin/iconutil -c icns "$ICONSET" -o "$ICON"
fi

mkdir -p "$HOME/Applications"
STAGING_ROOT="$(/usr/bin/mktemp -d "$HOME/Applications/.CouchKeys.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/install -m 755 "$BIN_DIR/CouchKeys" "$STAGED_APP/Contents/MacOS/CouchKeys"
/usr/bin/install -m 644 "$ROOT/src/resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/bin/install -m 644 "$ROOT/src/resources/LGwebOS-menubar-LICENSE.txt" "$STAGED_APP/Contents/Resources/Reference-LICENSE.txt"
/usr/bin/install -m 644 "$ICON" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"

BACKUP=""
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    EXISTING_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$DESTINATION/Contents/Info.plist")"
    if [[ "$EXISTING_ID" != "$BUNDLE_ID" || -L "$DESTINATION" ]]; then
        printf 'Cannot verify the existing destination as this app; nothing was replaced: %s\n' "$DESTINATION" >&2
        exit 1
    fi
    BACKUP_DIR="$HOME/Library/Application Support/CouchKeys/Backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP="$BACKUP_DIR/CouchKeys-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
    /bin/mv "$DESTINATION" "$BACKUP"
fi
if ! /bin/mv "$STAGED_APP" "$DESTINATION"; then
    if [[ -n "$BACKUP" && ! -e "$DESTINATION" ]]; then
        /bin/mv "$BACKUP" "$DESTINATION"
    fi
    exit 1
fi

if [[ ! -e "$DESKTOP_LINK" && ! -L "$DESKTOP_LINK" ]]; then
    /bin/ln -s "$DESTINATION" "$DESKTOP_LINK"
elif [[ -L "$DESKTOP_LINK" && "$(/usr/bin/readlink "$DESKTOP_LINK")" == "$DESTINATION" ]]; then
    :
else
    printf 'Preserved existing Desktop item: %s\n' "$DESKTOP_LINK"
fi
printf '\nInstalled: %s\n' "$DESTINATION"
if [[ -n "$BACKUP" ]]; then
    printf 'Previous app retained: %s\n' "$BACKUP"
fi
printf 'Open with: open "%s"\n' "$DESTINATION"
