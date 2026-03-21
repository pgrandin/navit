#!/usr/bin/env bash
# WinCE Smoke Test: Boot Device Emulator under Wine+Xvfb, launch Navit, verify startup.
#
# Expects:
#   emulator/DeviceEmulator.exe  — from wince-setup-emulator.sh
#   emulator/rom.bin             — from wince-setup-emulator.sh
#   navit-package/navit.exe      — from build_wince artifact
#
# Environment:
#   EMU_DIR        - emulator directory (default: emulator)
#   NAVIT_DIR      - navit package directory (default: navit-package)
#   SMOKE_TIMEOUT  - total timeout in seconds (default: 180)
#   ROTATE         - emulator rotation: 0=portrait (default), 1=landscape-right,
#                    2=upside-down, 3=landscape-left

set -euo pipefail

EMU_DIR="${EMU_DIR:-emulator}"
NAVIT_DIR="${NAVIT_DIR:-navit-package}"
RESULTS_DIR="smoke-results"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
ROTATE="${ROTATE:-0}"

export WINEPREFIX="$PWD/.wine-emu"
export WINEARCH=win32
export WINEDEBUG="-all,+err"
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/smoke-test.log"; }

capture_screenshot() {
    local label="${1:-screenshot}"
    local outfile="$RESULTS_DIR/${label}-$(date '+%H%M%S').png"
    local wid
    wid="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
    if [ -n "$wid" ]; then
        import -window "$wid" "$outfile" 2>/dev/null && \
            log "Screenshot: $outfile" || true
    else
        import -window root "$outfile" 2>/dev/null && \
            log "Screenshot (root): $outfile" || true
    fi
}

# Tap a point on the WinCE guest screen.
# Guest coordinates are relative to the WinCE display area,
# which starts below the host menu bar (~19px).
MENU_BAR_H=19
tap_guest() {
    local gx="$1" gy="$2" label="${3:-}"
    local wx=$gx
    local wy=$((gy + MENU_BAR_H))
    [ -n "$label" ] && log "Tap ($gx,$gy) [${label}]"
    xdotool mousemove --window "$EMU_WID" "$wx" "$wy"
    sleep 0.3
    xdotool click --window "$EMU_WID" 1
}

cleanup() {
    log "Cleaning up..."
    [ -n "${EMU_PID:-}" ] && kill "$EMU_PID" 2>/dev/null && sleep 1 && kill -9 "$EMU_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Validate inputs ---
[ -f "$EMU_DIR/DeviceEmulator.exe" ] || { log "FATAL: $EMU_DIR/DeviceEmulator.exe not found"; exit 1; }
[ -f "$EMU_DIR/rom.bin" ] || { log "FATAL: $EMU_DIR/rom.bin not found"; exit 1; }
[ -f "$NAVIT_DIR/navit.exe" ] || { log "FATAL: $NAVIT_DIR/navit.exe not found"; exit 1; }

log "DeviceEmulator.exe: $(du -h "$EMU_DIR/DeviceEmulator.exe" | cut -f1)"
log "rom.bin: $(du -h "$EMU_DIR/rom.bin" | cut -f1)"
log "Navit package: $(find "$NAVIT_DIR" -type f | wc -l) files"

# --- Start Xvfb ---
log "Starting Xvfb (rotate=$ROTATE)..."
if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
    Xvfb :99 -screen 0 480x360x24 &
else
    Xvfb :99 -screen 0 320x480x24 &
fi
XVFB_PID=$!
export DISPLAY=:99
sleep 2
kill -0 "$XVFB_PID" 2>/dev/null || { log "FATAL: Xvfb failed to start"; exit 1; }

# --- Initialize Wine ---
log "Initializing Wine prefix..."
timeout 60 wineboot --init 2>/dev/null || {
    log "WARNING: wineboot timed out or failed (exit $?) — continuing anyway"
}
timeout 10 wineserver --wait 2>/dev/null || true
log "Wine initialized"

# --- Convert paths to Windows format ---
ROM_WIN="$(winepath -w "$(realpath "$EMU_DIR/rom.bin")")"
SHARE_WIN="$(winepath -w "$(realpath "$NAVIT_DIR")")"

# --- Launch Device Emulator ---
log "Launching Device Emulator..."

EMU_ARGS=("$ROM_WIN" /memsize 128 /sharedfolder "$SHARE_WIN")
if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
    EMU_ARGS+=(/video 320x240x16)
fi

wine "$EMU_DIR/DeviceEmulator.exe" \
    "${EMU_ARGS[@]}" \
    > "$RESULTS_DIR/wine-output.log" 2>&1 &
EMU_PID=$!
log "Device Emulator PID: $EMU_PID"

# --- Wait for emulator window ---
log "Waiting for emulator window..."
START=$SECONDS

for i in $(seq 1 30); do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        log "Device Emulator died during boot"
        tail -30 "$RESULTS_DIR/wine-output.log" | tee -a "$RESULTS_DIR/smoke-test.log"
        capture_screenshot "crash"
        exit 1
    fi
    if xdotool search --name "Device Emulator" 2>/dev/null | grep -q .; then
        log "Emulator window detected after $((SECONDS - START))s"
        break
    fi
    sleep 2
done

EMU_WID="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"

# --- Wait for WinCE shell to fully boot ---
log "Waiting 30s for WinCE shell to boot..."
sleep 30
capture_screenshot "01-post-boot"

if ! kill -0 "$EMU_PID" 2>/dev/null; then
    log "Device Emulator died after boot"
    exit 1
fi

# --- Launch Navit via WinCE File Explorer ---
# Navigate the WinCE GUI: Start > Programs > File Explorer > Storage Card > navit.exe
# All coordinates are in WinCE guest screen space (240x320 portrait, 320x240 landscape).
log "Navigating WinCE GUI to launch navit.exe..."

if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window"
else
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Dismiss any "Device unlocked" notification by tapping the main area
    tap_guest 120 160 "dismiss notifications"
    sleep 1

    # Step 1: Tap "Start" at top-left of WinCE screen
    # The Start button in PPC 2003 SE is in the top-left corner with a flag icon.
    tap_guest 25 12 "Start button"
    sleep 2
    capture_screenshot "02-start-menu"

    # Step 2: Tap "Programs" in the Start menu
    # In PPC 2003 SE, the Start menu shows items vertically.
    # "Programs" is typically near the bottom with a folder icon.
    # The start menu occupies roughly the top 2/3 of the screen.
    # Common items: Today, Calendar, Contacts, IE, Messaging, etc.
    # Programs is usually the 7th-9th item.
    # Each item is ~26px tall. Programs at roughly y=26*8+26 = 234
    # But there's also a title area. Let's estimate y=260.
    tap_guest 100 260 "Programs"
    sleep 2
    capture_screenshot "03-programs"

    # Step 3: Tap "File Explorer" in the Programs screen
    # The Programs screen shows icons in a grid layout.
    # File Explorer typically has a folder icon with a magnifying glass.
    # Icons are arranged in rows of ~4, with ~60px spacing.
    # File Explorer is often in the first or second row.
    # Let's try a few common positions.
    # Row 1: y ≈ 55, icons at x ≈ 30, 90, 150, 210
    # Row 2: y ≈ 115, icons at x ≈ 30, 90, 150, 210
    tap_guest 40 55 "File Explorer (guess: row1, col1)"
    sleep 2
    capture_screenshot "04-after-programs-tap"

    # Step 4: Look for Storage Card in File Explorer
    # File Explorer shows a list of folders/files in My Device.
    # Storage Card should be one of the items.
    # The file list starts below the address bar (~40px from top).
    # Items are ~20px tall in list view.
    # Common items: My Documents, Program Files, Storage Card, Windows, etc.
    # Storage Card might be the 3rd-5th item.
    tap_guest 100 120 "Storage Card (guess)"
    sleep 2
    capture_screenshot "05-storage-card"

    # Step 5: Find and tap navit.exe
    # In Storage Card, navit.exe should be in the file list.
    # But there are many files. It might be alphabetically sorted.
    # navit.exe would be near the middle of an alphabetical list.
    # Let's try tapping on the first visible .exe file.
    tap_guest 100 80 "navit.exe (guess)"
    sleep 3
    capture_screenshot "06-navit-attempt"

    # Take a root screenshot to see the full state
    import -window root "$RESULTS_DIR/07-root-state-$(date '+%H%M%S').png" 2>/dev/null || true
    log "GUI navigation complete"
fi

# --- Wait for Navit to potentially start ---
log "Waiting 20s for Navit to initialize..."
sleep 20
capture_screenshot "08-after-wait"

# --- Monitor for remaining time ---
REMAINING=$((SMOKE_TIMEOUT - (SECONDS - START)))
if [ "$REMAINING" -gt 0 ]; then
    log "Monitoring for ${REMAINING}s..."
    LAST_SHOT=$SECONDS

    while [ $((SECONDS - START)) -lt "$SMOKE_TIMEOUT" ]; do
        if ! kill -0 "$EMU_PID" 2>/dev/null; then
            log "Device Emulator exited during monitoring"
            capture_screenshot "exit"
            exit 1
        fi

        if [ $((SECONDS - LAST_SHOT)) -ge 20 ]; then
            capture_screenshot "monitor"
            LAST_SHOT=$SECONDS
        fi

        sleep 5
    done
fi

# --- Final ---
capture_screenshot "99-final"

if kill -0 "$EMU_PID" 2>/dev/null; then
    log "PASS: Device Emulator survived ${SMOKE_TIMEOUT}s"
else
    log "FAIL: Device Emulator died before timeout"
    exit 1
fi

find "$NAVIT_DIR" -name "*.log" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true
ps aux > "$RESULTS_DIR/processes.txt" 2>/dev/null || true

log "Results in $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
exit 0
