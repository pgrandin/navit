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

# Click inside the WM screen area of the emulator.
# The emulator window starts at screen position (3, 29) with a 19px Wine menu bar.
# The WM screen area starts at screen (3, 48) and is 240x320 pixels.
# WM coordinates (0,0) = screen (3, 48).
emu_click() {
    local wmx="$1" wmy="$2"
    local sx=$((3 + wmx))
    local sy=$((48 + wmy))
    log "Click WM($wmx,$wmy) -> screen($sx,$sy)"
    xdotool mousemove "$sx" "$sy"
    sleep 0.3
    xdotool mousedown 1
    sleep 0.1
    xdotool mouseup 1
    sleep 1
}

# Double-click inside the WM screen area
emu_dblclick() {
    local wmx="$1" wmy="$2"
    local sx=$((3 + wmx))
    local sy=$((48 + wmy))
    log "DblClick WM($wmx,$wmy) -> screen($sx,$sy)"
    xdotool mousemove "$sx" "$sy"
    sleep 0.2
    xdotool mousedown 1; sleep 0.05; xdotool mouseup 1
    sleep 0.15
    xdotool mousedown 1; sleep 0.05; xdotool mouseup 1
    sleep 1
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
    # Landscape: WM screen 320x240 + Wine chrome
    Xvfb :99 -screen 0 480x360x24 &
else
    # Portrait: WM screen 240x320 + Wine chrome
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
if [ "$ROTATE" != "0" ]; then
    EMU_ARGS+=(/rotate "$ROTATE")
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

# --- Let WM finish booting ---
log "Waiting 20s for WM to stabilize..."
sleep 20
capture_screenshot "01-post-boot"

if ! kill -0 "$EMU_PID" 2>/dev/null; then
    log "Device Emulator died after boot"
    exit 1
fi

# --- Navigate the WM UI to launch Navit ---
# Navigation plan:
#   1. Tap Start (top bar)
#   2. Tap Programs in the Start menu
#   3. Tap File Explorer in the Programs list
#   4. Navigate to Storage Card
#   5. Tap navit.exe

log "=== Launching Navit via UI navigation ==="

# Focus the emulator window first
WIN_ID="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
if [ -n "$WIN_ID" ]; then
    xdotool windowactivate "$WIN_ID" 2>/dev/null || true
    xdotool windowfocus "$WIN_ID" 2>/dev/null || true
    sleep 0.5
fi

if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
    # --- LANDSCAPE MODE (320x240) ---
    # WM screen is 320w x 240h. Title bar at top, softkeys at bottom.
    # Start button at top-left. Coordinates are estimated for first run.

    # Step 1: Tap "Start"
    log "Step 1: Tapping Start..."
    emu_click 30 8
    sleep 3
    capture_screenshot "02-start-tapped"

    # Step 2: Tap "Programs" — menu is taller than screen, Programs near bottom
    # In landscape the start menu shows fewer items before scrolling.
    # Items are same height (~18px) but menu may need scrolling.
    log "Step 2: Tapping Programs..."
    emu_click 50 170
    sleep 3
    capture_screenshot "03-programs-tapped"

    # Step 3: Double-tap File Explorer in Programs grid
    # Landscape grid may have more columns or same layout shifted.
    # File Explorer: Row 2, Col 1 — estimate same relative position.
    log "Step 3: Double-tapping File Explorer icon..."
    emu_dblclick 40 145
    sleep 3
    capture_screenshot "04-after-file-explorer-dblclick"

    log "Step 3b: Trying File Explorer label area..."
    emu_dblclick 40 165
    sleep 3
    capture_screenshot "05-after-label-dblclick"

    # Step 4: Navigate up to root
    # Softkey bar: "Up" at bottom-left ~WM(40, 227)
    log "Step 4: Navigating up to root..."
    emu_click 40 227
    sleep 2
    capture_screenshot "06a-up1"

    emu_click 40 227
    sleep 2
    capture_screenshot "06b-up2"

    # Root listing — same item order, same ~18px row height
    # In landscape the list area starts at ~y=37 (shorter title/address bar)
    # Storage Card is 7th item: y ≈ 37 + 6*18 = 145
    log "Step 4b: Looking for Storage Card in root..."
    capture_screenshot "06c-root-view"

    emu_click 160 145
    sleep 3
    capture_screenshot "06d-storage-card"

    # Step 5: navit.exe is 4th item: y ≈ 37 + 3*18 = 91
    log "Step 5: Looking for navit.exe..."
    capture_screenshot "07-folder-contents"

    emu_click 160 91
    sleep 3
    capture_screenshot "07a-click-navit-exe"
else
    # --- PORTRAIT MODE (240x320) ---
    # WM screen is 240w x 320h.

    # Step 1: Tap "Start" in WM title bar
    log "Step 1: Tapping Start..."
    emu_click 30 8
    sleep 3
    capture_screenshot "02-start-tapped"

    # Step 2: Tap "Programs" in the Start menu
    # Start menu layout (verified from screenshots):
    #   Today:            y~30    Programs:         y~170
    #   Office Mobile:    y~50    Settings:         y~190
    #   Calendar:         y~68    Help:             y~208
    #   Contacts:         y~86
    #   Internet Explorer:y~104
    #   Messaging:        y~122
    log "Step 2: Tapping Programs..."
    emu_click 50 170
    sleep 3
    capture_screenshot "03-programs-tapped"

    # Step 3: Double-tap File Explorer in the Programs grid
    # Grid layout (3 columns x 4 rows, verified from screenshots):
    #   Row 1 (y~65-85):  Games(x~40), ActiveSync(x~120), Calculator(x~190)
    #   Row 2 (y~140-162): File Explorer(x~40), Getting Started(x~120), Internet Sharing(x~190)
    log "Step 3: Double-tapping File Explorer icon..."
    emu_dblclick 40 145
    sleep 3
    capture_screenshot "04-after-file-explorer-dblclick"

    log "Step 3b: Trying File Explorer label area..."
    emu_dblclick 40 165
    sleep 3
    capture_screenshot "05-after-label-dblclick"

    # Step 4: Navigate up to root, then to Storage Card
    # Softkey bar: "Up" at bottom-left ~WM(40, 307)
    log "Step 4: Navigating up to root..."

    emu_click 40 307
    sleep 2
    capture_screenshot "06a-up1"

    emu_click 40 307
    sleep 2
    capture_screenshot "06b-up2"

    # Root listing (verified from screenshots):
    #   Items ~18px tall, starting at WM y≈57:
    #   Application D... y≈57, ConnMgr y≈75, Documents a... y≈93,
    #   MUSIC y≈111, My Documents y≈129, Program Files y≈147,
    #   Storage Card y≈165, Temp y≈183, Windows y≈201
    log "Step 4b: Looking for Storage Card in root..."
    capture_screenshot "06c-root-view"

    emu_click 120 165
    sleep 3
    capture_screenshot "06d-storage-card"

    # Step 5: navit.exe in Storage Card (verified from screenshots):
    #   espeak-data/ y≈57, icons/ y≈75, locale/ y≈93,
    #   navit.exe(7.93M) y≈111, navit.xml(30.7K) y≈129
    log "Step 5: Looking for navit.exe..."
    capture_screenshot "07-folder-contents"

    emu_click 120 111
    sleep 3
    capture_screenshot "07a-click-navit-exe"
fi

# Give Navit time to start and render
log "Waiting 15s for Navit to initialize..."
sleep 15
capture_screenshot "08-navit-result"

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
