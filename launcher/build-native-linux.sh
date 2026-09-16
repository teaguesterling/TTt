#!/usr/bin/env bash
# Assemble the native-Linux TiinyOS build tree.
#
# TiinyOS ships Windows-only, and running it under Wine ROTS: a prefix's
# graphics state white-screens the renderer while the JS runs fine. This
# repackages the app's own payload onto a native linux-x64 Electron of the SAME
# version, which sidesteps that failure class entirely.
#
# It does NOT touch pcsvr. That stays under patched Wine (it is a Windows Go
# binary with no Linux build) -- see ../wine/README.md.
#
#   ./build-native-linux.sh [--target DIR] [--src WINE_INSTALL] [--force]
#
# Idempotent: re-running verifies and repairs rather than starting over. Pass
# --force to rebuild the Electron runtime from scratch.
set -euo pipefail

ELECTRON_VER="${ELECTRON_VER:-37.4.0}"     # MUST match the app's own Electron
SHARP_VER="${SHARP_VER:-0.34.5}"           # the app's pin, NOT npm latest
COLOUR_VER="${COLOUR_VER:-1.0.0}"          # sharp pulls @img/colour by range;
                                           # pinned so npm cannot drift it
TARGET="${TIINY_NATIVE_BUILD:-$HOME/tiiny-tools/linux-native-build-$ELECTRON_VER}"
SRC=""
FORCE=0
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --src)    SRC="$2";    shift 2 ;;
    --force)  FORCE=1;     shift ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say(){ printf '==> %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for t in unzip curl npm python3; do
  command -v "$t" >/dev/null || die "missing required tool: $t"
done

# --- 1. Locate the Windows install --------------------------------------------
# The payload comes from the vendor .exe installed into a Wine prefix. We only
# read from it; nothing here modifies the prefix.
if [ -z "$SRC" ]; then
  for p in "$HOME"/.local/share/wineprefixes/*/drive_c/users/*/AppData/Local/Programs/TiinyOS; do
    [ -f "$p/resources/app.asar" ] || continue
    # newest asar wins, so an upgraded prefix is preferred over a stale one
    if [ -z "$SRC" ] || [ "$p/resources/app.asar" -nt "$SRC/resources/app.asar" ]; then SRC="$p"; fi
  done
fi
[ -n "$SRC" ] && [ -f "$SRC/resources/app.asar" ] \
  || die "no TiinyOS install found. Install the vendor .exe into a Wine prefix first (see ../docs/from-scratch.md step 4), or pass --src"

say "source : $SRC"
say "target : $TARGET"
say "electron v$ELECTRON_VER, sharp v$SHARP_VER"

APP="$TARGET/tiinyos-linux"

# --- 2. Electron runtime -------------------------------------------------------
if [ "$FORCE" = 1 ] || [ ! -x "$APP/electron" ]; then
  say "fetching electron v$ELECTRON_VER (linux-x64)"
  mkdir -p "$TARGET"
  ZIP="$TARGET/.electron-v$ELECTRON_VER-linux-x64.zip"
  if [ ! -s "$ZIP" ]; then
    curl -fL --retry 3 -o "$ZIP" \
      "https://github.com/electron/electron/releases/download/v${ELECTRON_VER}/electron-v${ELECTRON_VER}-linux-x64.zip"
  fi
  rm -rf "$APP"; mkdir -p "$APP"
  unzip -q "$ZIP" -d "$APP"
  [ -x "$APP/electron" ] || die "electron binary missing after unzip"
else
  say "electron runtime already present (use --force to rebuild)"
fi

# --- 3. The app payload --------------------------------------------------------
# Straight copy from the Windows install: same app.asar, same unpacked tree.
# app.asar.unpacked holds the native modules that cannot live inside an archive.
say "copying app payload"
mkdir -p "$APP/resources"
for item in app.asar app.asar.unpacked app-update.yml pcsvr scripts; do
  [ -e "$SRC/resources/$item" ] || { echo "    (skip, absent: $item)"; continue; }
  rm -rf "$APP/resources/${item:?}"
  cp -a "$SRC/resources/$item" "$APP/resources/"
  echo "    $item"
done

# --- 4. The ONE native module that needs a Linux build -------------------------
# sharp ships per-platform binaries and the Windows install has only win32/darwin.
# The app's other native modules (@napi-rs/system-ocr, registry-js,
# selection-hook) already self-guard on Linux and need nothing.
#
# Pin to the app's own sharp version -- npm latest resolves a newer libvips that
# fails at runtime against this Electron's ABI. And install the MAIN sharp package with the platform forced, not just
# @img/sharp-linux-x64. The sub-package alone omits @img/colour, which sharp
# 0.34.x requires at runtime and which is NOT declared as its dependency --
# installing only the platform binary produces a tree that looks complete and
# fails when sharp is first used.
say "installing sharp@$SHARP_VER (linux-x64) and its @img packages"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && npm install --silent --no-audit --no-fund \
    --os=linux --cpu=x64 --include=optional \
    "sharp@$SHARP_VER" "@img/colour@$COLOUR_VER" >/dev/null 2>&1 ) \
  || die "npm install of sharp@$SHARP_VER (linux-x64) failed"

IMG="$APP/resources/app.asar.unpacked/node_modules/@img"
mkdir -p "$IMG"
copied=0
for d in "$TMP/node_modules/@img/"*; do
  [ -d "$d" ] || continue
  rm -rf "$IMG/$(basename "$d")"
  cp -a "$d" "$IMG/"
  echo "    $(basename "$d")"
  copied=$((copied+1))
done
[ "$copied" -gt 0 ] || die "no @img packages were installed"

# --- 5. Rename the binary — NOT cosmetic ---------------------------------------
# app.isPackaged keys off the executable NAME. Launched as plain `electron` the
# app takes its dev-mode branch and every window dies with ERR_FILE_NOT_FOUND.
say "creating the 'tiinyos' binary (app.isPackaged depends on this name)"
cp -a "$APP/electron" "$APP/tiinyos"

# chrome-sandbox needs root:4755 to be used at all. We do not setuid it here --
# that needs sudo and this script deliberately needs none. The launcher passes
# --no-sandbox instead, which is why that flag is not optional.
if [ -e "$APP/chrome-sandbox" ] && [ ! -u "$APP/chrome-sandbox" ]; then
  echo "    note: chrome-sandbox is not setuid; the launcher runs with --no-sandbox"
fi

# --- 6. The launcher -----------------------------------------------------------
# Canonical copy lives in this repo; it must sit in the tree root because it
# self-roots via dirname "$BASH_SOURCE" to find tiinyos-linux/.
say "installing run-tiinyos-linux.sh"
cp -a "$SELF/run-tiinyos-linux.sh" "$TARGET/run-tiinyos-linux.sh"
chmod +x "$TARGET/run-tiinyos-linux.sh"

# --- 7. Verify -----------------------------------------------------------------
say "verifying"
fail=0
check(){ if eval "$2"; then echo "    ok   $1"; else echo "    FAIL $1"; fail=1; fi; }
check "electron v$ELECTRON_VER"        "[ \"\$(cat '$APP/version' 2>/dev/null)\" = 'v$ELECTRON_VER' ] || grep -q '$ELECTRON_VER' '$APP/version' 2>/dev/null"
check "tiinyos binary (renamed)"       "[ -x '$APP/tiinyos' ]"
check "app.asar present"               "[ -s '$APP/resources/app.asar' ]"
check "app.asar.unpacked present"      "[ -d '$APP/resources/app.asar.unpacked' ]"
check "sharp linux binary"             "[ -f '$IMG/sharp-linux-x64/lib/sharp-linux-x64.node' ]"
check "libvips linux binary"           "ls '$IMG'/sharp-libvips-linux-x64/lib/*.so* >/dev/null 2>&1"
check "@img/colour (sharp 0.34 runtime dep)" "[ -d '$IMG/colour' ]"
check "@img/colour pinned to $COLOUR_VER"    "[ \"\$(python3 -c \"import json;print(json.load(open('$IMG/colour/package.json'))['version'])\" 2>/dev/null)\" = '$COLOUR_VER' ]"
check "windows sharp binaries retained" "[ -d '$IMG/sharp-win32-x64' ] || [ -d '$IMG/sharp-darwin-x64' ]"
check "launcher in tree root"          "[ -x '$TARGET/run-tiinyos-linux.sh' ]"

if [ "$fail" != 0 ]; then
  die "build incomplete — see FAIL lines above"
fi

cat <<EOF

Build tree ready: $TARGET

Start it (pcsvr must come up first — the app dials it on 127.0.0.1:60000):

    TIINY_NATIVE_BUILD="$TARGET" $SELF/tiiny-native.sh start
    TIINY_NATIVE_BUILD="$TARGET" $SELF/tiiny-native.sh status

If the window is blank, check $TARGET/tiinyos-linux.log — and see
../docs/troubleshooting.md before suspecting the build.
EOF
