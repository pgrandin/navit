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
Xvfb :99 -screen 0 320x480x24 &
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

# Step 3: Double-tap File Explorer in the Programs grid
# From screenshot analysis of the Programs screen:
#   Grid layout (3 columns x 4 rows):
#     Row 1 (icon y~65, label y~85): Games(x~40), ActiveSync(x~120), Calculator(x~190)
#     Row 2 (icon y~140, label y~162): File Explorer(x~40), Getting Started(x~120), Internet Sharing(x~190)
#     Row 3 (icon y~210): Messenger(x~40), Notes(x~120), Pictures & Videos(x~190)
#     Row 4 (icon y~280): Search(x~40), SimTkUI(x~120), Task Manager(x~190)
# Single tap selects, double-tap opens.
log "Step 3: Double-tapping File Explorer icon..."
emu_dblclick 40 145
sleep 3
capture_screenshot "04-after-file-explorer-dblclick"

# Check if we got File Explorer or are still on Programs
# If still on Programs, try clicking the File Explorer text label
log "Step 3b: Trying File Explorer label area..."
emu_dblclick 40 165
sleep 3
capture_screenshot "05-after-label-dblclick"

# Step 4: Navigate up to root, then to Storage Card
# File Explorer opened in "Templates" folder. Need to go up to My Device root.
# Bottom softkey bar: "Up" at bottom-left ~WM(40, 307), "Menu" at bottom-right ~WM(200, 307)
log "Step 4: Navigating up to root..."

# Tap "Up" to go from Templates -> My Documents
emu_click 40 307
sleep 2
capture_screenshot "06a-up1"

# Tap "Up" again to go from My Documents -> My Device (root)
emu_click 40 307
sleep 2
capture_screenshot "06b-up2"

# Now we should be at \My Device root.
# From screenshot analysis of root listing (06c):
#   List items are ~18px tall, starting at WM y≈57:
#   Application D...  y≈57
#   ConnMgr           y≈75
#   Documents a...    y≈93
#   MUSIC             y≈111
#   My Documents      y≈129
#   Program Files     y≈147
#   Storage Card      y≈165
#   Temp              y≈183
#   Windows           y≈201
log "Step 4b: Looking for Storage Card in root..."
capture_screenshot "06c-root-view"

# Single-click navigates into folders in File Explorer list view
emu_click 120 165
sleep 3
capture_screenshot "06d-storage-card"

# Step 5: Find and tap navit.exe in Storage Card
# From screenshot analysis of Storage Card listing (06d):
#   espeak-data/      y≈57  (folder)
#   icons/            y≈75  (folder)
#   locale/           y≈93  (folder)
#   navit  7.93M      y≈111 (navit.exe)
#   navit  30.7K      y≈129 (navit.xml - opens in IE!)
#   navit  5.46M      y≈147
#   navit_layout_*    y≈165+
log "Step 5: Looking for navit.exe..."
capture_screenshot "07-folder-contents"

# navit.exe (7.93M) is the 4th item (after 3 folders, no maps/ folder)
emu_click 120 111
sleep 3
capture_screenshot "07a-click-navit-exe"

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
