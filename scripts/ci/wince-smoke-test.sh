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
# Navigate: Start > Programs > File Explorer > [up to root] > Storage Card > navit.exe
#
# Keyboard navigation:
#   Super      → opens Start menu
#   Down x6    → highlights "Programs"
#   Return     → opens Programs screen
#   Right x3   → highlights "File Explorer" (grid: row1 col4)
#   Return     → opens File Explorer (defaults to My Documents)
#   Backspace  → goes up to My Device root
#   Down to "Storage Card" → Enter → navigate to navit.exe → Enter
#
# The Start menu layout (confirmed from landscape CI screenshots):
#   Today, Office Mobile, Calendar, Contacts, Internet Explorer, Messaging,
#   [Recent Programs header - not selectable],
#   Programs, Settings, Help
#
# Programs grid layout (4 columns, confirmed from CI screenshots):
#   Row 1: Games | ActiveSync | Calculator | File Explorer
#   Row 2: Getting Started | Internet Sharing | Messenger | Notes
#   ...
log "Navigating WinCE GUI to launch navit.exe..."

if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window"
else
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Step 1: Open Start menu with Super (Windows) key
    log "Step 1: Opening Start menu (Super key)..."
    emu_key super
    sleep 1
    capture_screenshot "02-start-menu"

    # Step 2: Navigate to Programs (6x Down + Enter)
    # From CI: Today is first, Programs is 7th selectable item (6 Down)
    log "Step 2: Navigating to Programs (6x Down)..."
    for i in 1 2 3 4 5 6; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "03-programs-highlighted"

    # Use Enter to open Programs.
    # In PPC, the action button to open an item is typically Enter/Return.
    log "Step 2b: Opening Programs (Enter)..."
    emu_key Return
    sleep 2
    capture_screenshot "04-programs-screen"

    # Step 3: Navigate to File Explorer (3x Right + Enter)
    # Grid: Games(col1) → ActiveSync(col2) → Calculator(col3) → File Explorer(col4)
    log "Step 3: Navigating to File Explorer (3x Right)..."
    emu_key Right
    emu_key Right
    emu_key Right
    sleep 0.5
    capture_screenshot "05-file-explorer-highlighted"
    emu_key Return
    sleep 2
    capture_screenshot "06-file-explorer-opened"

    # Step 4: Navigate up from My Documents to My Device root
    # File Explorer defaults to "My Documents". Use Backspace to go up.
    log "Step 4: Going up to My Device root (Backspace)..."
    emu_key BackSpace
    sleep 1
    capture_screenshot "07-my-device-root"

    # Step 5: Navigate to Storage Card
    # My Device root contains folders alphabetically:
    #   My Documents, Network, Program Files, Storage Card, Temp, Windows
    # Storage Card is typically the 4th item.
    log "Step 5: Navigating to Storage Card..."
    # First press Down to enter the file list, then navigate
    for i in 1 2 3 4; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "08-storage-card-highlighted"
    emu_key Return
    sleep 2
    capture_screenshot "09-storage-card-contents"

    # Step 6: Find and open navit.exe
    # Storage Card contents (from navit-package):
    #   Folders first (alphabetical): 2577/, espeak-data/, icons/, locale/, maps/
    #   Then files: autorun.exe, navit.exe, navit.xml, navit_layout_*.xml, ...
    # navit.exe is the 7th item (5 folders + autorun.exe + navit.exe)
    log "Step 6: Navigating to navit.exe..."
    for i in 1 2 3 4 5 6 7; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "10-navit-highlighted"
    emu_key Return
    sleep 5
    capture_screenshot "11-navit-launched"

    import -window root "$RESULTS_DIR/12-root-state-$(date '+%H%M%S').png" 2>/dev/null || true
    log "GUI navigation complete"
fi

# --- Wait for Navit to potentially start ---
log "Waiting 20s for Navit to initialize..."
sleep 20
capture_screenshot "13-after-wait"

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
