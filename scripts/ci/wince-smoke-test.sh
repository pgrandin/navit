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

set -euo pipefail

EMU_DIR="${EMU_DIR:-emulator}"
NAVIT_DIR="${NAVIT_DIR:-navit-package}"
RESULTS_DIR="smoke-results"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"

export WINEPREFIX="$PWD/.wine-emu"
export WINEARCH=win32
export WINEDEBUG="-all,+err"
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/smoke-test.log"; }

capture_screenshot() {
    local label="${1:-screenshot}"
    local outfile="$RESULTS_DIR/${label}-$(date '+%H%M%S').png"
    import -window root "$outfile" 2>/dev/null && \
        log "Screenshot: $outfile" || true
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
log "Starting Xvfb..."
Xvfb :99 -screen 0 800x600x24 &
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

wine "$EMU_DIR/DeviceEmulator.exe" \
    "$ROM_WIN" \
    /memsize 128 \
    /sharedfolder "$SHARE_WIN" \
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
# WM 6.1 Professional screen layout (240x320):
#   Title bar: y=0-20  ("Start" text at ~x=30, y=8)
#   Today screen content: y=20-295
#   Softkey bar: y=295-320 ("Calendar" left, "Contacts" right)
#
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

# Step 1: Tap "Start" in WM title bar
log "Step 1: Tapping Start..."
emu_click 30 8
sleep 3
capture_screenshot "02-start-tapped"

# Step 2: Tap "Programs" in the Start menu
# From screenshot analysis of the WM 6.1 Start menu layout:
#   Today:            y~30
#   Office Mobile:    y~50
#   Calendar:         y~68
#   Contacts:         y~86
#   Internet Explorer:y~104
#   Messaging:        y~122
#   "Recent Programs":y~148
#   Programs:         y~170
#   Settings:         y~190
#   Help:             y~208
log "Step 2: Tapping Programs..."
emu_click 50 170
sleep 3
capture_screenshot "03-programs-tapped"

# Step 3: Tap File Explorer in the Programs grid
# From screenshot analysis of the Programs screen:
#   Grid layout (3 columns x 4 rows visible):
#     Row 1 (y~90):  Games(x~40), ActiveSync(x~120), Calculator(x~190)
#     Row 2 (y~160): File Explorer(x~40), Getting Started(x~120), Internet Sharing(x~190)
#     Row 3 (y~230): Messenger(x~40), Notes(x~120), Pictures & Videos(x~190)
#     Row 4 (y~300): Search(x~40), SimTkUI(x~120), Task Manager(x~190)
log "Step 3: Tapping File Explorer..."
emu_click 40 160
sleep 3
capture_screenshot "04-file-explorer"

# Step 4: In File Explorer, navigate to Storage Card
# File Explorer shows the \My Device root with items like:
#   My Documents, Program Files, Storage Card, Temp, Windows, etc.
# Items are in a list view. "Storage Card" should be visible.
# List items start around y=35 with ~20px spacing.
log "Step 4: Looking for Storage Card in File Explorer..."
capture_screenshot "05-file-explorer-view"

# Scroll down if needed and try tapping "Storage Card"
# It's typically several items down in the list
# Try tapping items from top to bottom until we find it
emu_click 120 80
sleep 2
capture_screenshot "06a-fe-item1"

emu_click 120 100
sleep 2
capture_screenshot "06b-fe-item2"

emu_click 120 120
sleep 2
capture_screenshot "06c-fe-item3"

emu_click 120 140
sleep 2
capture_screenshot "06d-fe-item4"

emu_click 120 160
sleep 2
capture_screenshot "06e-fe-item5"

# Step 5: In Storage Card folder, find and tap navit.exe
log "Step 5: Looking for navit.exe..."
capture_screenshot "07-storage-card-contents"

# navit.exe should be one of the items in the folder
# The build produces: navit.exe, navit.xml, icons/, locale/, espeak-data/, maps/
emu_click 120 60
sleep 2
capture_screenshot "08a-item1"

emu_click 120 80
sleep 2
capture_screenshot "08b-item2"

emu_click 120 100
sleep 2
capture_screenshot "08c-item3"

emu_click 120 120
sleep 2
capture_screenshot "08d-item4"

# Give Navit time to start and render
log "Waiting 15s for Navit to initialize..."
sleep 15
capture_screenshot "09-navit-running"

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
