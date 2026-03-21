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

# Send a key to the emulator window
emu_key() {
    xdotool key --window "$EMU_WID" "$1"
    sleep 0.3
}

# Tap a point on the WinCE guest screen (guest coords).
# The WinCE display starts below the host menu bar (~19px).
MENU_BAR_H=19
tap_guest() {
    local gx="$1" gy="$2" label="${3:-}"
    [ -n "$label" ] && log "Tap ($gx,$gy) [${label}]"
    xdotool mousemove --window "$EMU_WID" "$gx" "$((gy + MENU_BAR_H))"
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
# Navigate: Start > Programs > File Explorer > [root] > Storage Card > navit.exe
#
# Confirmed from CI screenshots:
#
# Start menu items (Super key opens it):
#   Today, Office Mobile, Calendar, Contacts, Internet Explorer, Messaging,
#   [Recent Programs header], Programs, Settings, Help
#
# Programs grid (4 columns):
#   Row 1: Games | ActiveSync | Calculator | File Explorer
#
# My Device root folders (F1 = Up from My Documents):
#   Application Data, ConnMgr, Documents and Settings, MUSIC,
#   My Documents, Program Files, Storage Card, Temp, Windows
#   → Storage Card is the 7th item (6 Down from Application Data)
log "Navigating WinCE GUI to launch navit.exe..."

if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window"
else
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Step 1: Open Start menu with Super key
    log "Step 1: Opening Start menu..."
    emu_key super
    sleep 1
    capture_screenshot "02-start-menu"

    # Step 2: Tap "Programs" in the Start menu
    # Use direct tap coordinates instead of arrow keys (more reliable).
    # From CI screenshots:
    #   Landscape (320x240): Programs at approx guest (70, 168)
    #   Portrait (240x320): Programs at approx guest (70, 218)
    log "Step 2: Tapping Programs..."
    if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
        tap_guest 70 168 "Programs (landscape)"
    else
        tap_guest 70 218 "Programs (portrait)"
    fi
    sleep 2
    capture_screenshot "03-programs-screen"

    # Step 3: Tap "File Explorer" in the Programs grid
    # From CI screenshots: File Explorer is at row 1, col 4 (top-right area).
    #   Landscape (320x240): File Explorer icon at approx guest (275, 55)
    #   Portrait (240x320): File Explorer icon at approx guest (195, 55)
    log "Step 3: Tapping File Explorer..."
    if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
        tap_guest 275 55 "File Explorer (landscape)"
    else
        tap_guest 195 55 "File Explorer (portrait)"
    fi
    sleep 2
    capture_screenshot "04-file-explorer"

    # Step 4: Go up to My Device root with F1 (left softkey = "Up")
    # File Explorer defaults to "My Documents".
    # F1 = "Up" in File Explorer → goes to My Device root.
    log "Step 4: Pressing F1 (Up) to reach My Device root..."
    emu_key F1
    sleep 1
    capture_screenshot "05-my-device-root"

    # Step 5: Navigate to Storage Card
    # My Device root (from CI screenshot):
    #   1. Application Data (selected by default)
    #   2. ConnMgr
    #   3. Documents and Settings
    #   4. MUSIC
    #   5. My Documents
    #   6. Program Files
    #   7. Storage Card  ← target (6 Down presses)
    log "Step 5: Navigating to Storage Card (6x Down)..."
    for i in 1 2 3 4 5 6; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "06-storage-card-highlighted"
    emu_key Return
    sleep 2
    capture_screenshot "07-storage-card-contents"

    # Step 6: Navigate to navit.exe
    # Storage Card contents (sorted alphabetically, folders first):
    #   Folders: 2577, espeak-data, icons, locale, maps (5 folders)
    #   Files: autorun.exe, navit.exe, navit.xml, navit_layout_*.xml, ...
    # navit.exe is the 7th item (5 folders + autorun.exe + navit.exe)
    log "Step 6: Navigating to navit.exe (7x Down)..."
    for i in 1 2 3 4 5 6 7; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "08-navit-highlighted"
    emu_key Return
    sleep 5
    capture_screenshot "09-navit-launched"

    import -window root "$RESULTS_DIR/10-root-state-$(date '+%H%M%S').png" 2>/dev/null || true
    log "GUI navigation complete"
fi

# --- Wait for Navit to potentially start ---
log "Waiting 20s for Navit to initialize..."
sleep 20
capture_screenshot "11-after-wait"

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
