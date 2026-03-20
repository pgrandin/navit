#!/usr/bin/env bash
# WinCE Smoke Test: Boot Device Emulator under Wine+Xvfb, auto-launch Navit, verify startup.
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

# --- Auto-start setup ---
# Place autorun.exe in the ARM processor-specific subfolder (2577 = ARMV4I).
# WinCE shell calls SHGetAutoRunPath() when a storage card is inserted and
# runs \Storage Card\<procID>\autorun.exe automatically.
# We boot WITHOUT /sharedfolder and hot-plug it later via the Device Emulator's
# File > Configure dialog so the shell sees a genuine card-insertion event.
mkdir -p "$NAVIT_DIR/2577"
cp "$NAVIT_DIR/navit.exe" "$NAVIT_DIR/2577/autorun.exe"
log "Created 2577/autorun.exe for SD card autorun"

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

# --- Launch Device Emulator (without shared folder) ---
# Boot without /sharedfolder so we can hot-plug it later via the Configure
# dialog, triggering a genuine SD card insertion event for autorun.exe.
log "Launching Device Emulator (no shared folder)..."

EMU_ARGS=("$ROM_WIN" /memsize 128)
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

# --- Wait for WinCE shell to fully boot ---
log "Waiting 30s for WinCE shell to boot..."
sleep 30
capture_screenshot "01-post-boot"

if ! kill -0 "$EMU_PID" 2>/dev/null; then
    log "Device Emulator died after boot"
    exit 1
fi

# --- Hot-plug shared folder via File > Configure dialog ---
# This simulates inserting an SD card after boot, which triggers
# SHGetAutoRunPath() -> \Storage Card\2577\autorun.exe -> navit.exe
log "Hot-plugging shared folder via File > Configure..."
EMU_WID="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window for hot-plug"
else
    # Click "File" in the host menu bar using window-relative coordinates.
    # The menu bar is rendered by Wine at the top of the window.
    # "File" text is at approximately x=15, y=8 in the window.
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Get window position for absolute coordinate calculation
    eval "$(xdotool getwindowgeometry --shell "$EMU_WID" 2>/dev/null)" || true
    log "Emulator window at X=$X Y=$Y W=${WIDTH:-?} H=${HEIGHT:-?}"

    # Click on "File" menu text in the menu bar
    xdotool mousemove --window "$EMU_WID" 15 8
    sleep 0.3
    xdotool click --window "$EMU_WID" 1
    sleep 1
    # Take a full-screen screenshot to see the menu dropdown
    import -window root "$RESULTS_DIR/02-file-menu-$(date '+%H%M%S').png" 2>/dev/null || true
    log "Screenshot: 02-file-menu (root)"

    # "Configure..." should be in the dropdown menu (a separate popup window).
    # The dropdown appears below the menu bar at absolute screen coordinates.
    # Menu items are ~20px tall. Configure is the 1st item under File.
    # Calculate absolute position: window Y + menu bar height (~19px) + item offset
    MENU_X=$((X + 15))
    MENU_Y=$((Y + 28))
    log "Clicking Configure at absolute ($MENU_X, $MENU_Y)"
    xdotool mousemove "$MENU_X" "$MENU_Y"
    sleep 0.3
    xdotool click 1
    sleep 2
    import -window root "$RESULTS_DIR/03-after-menu-click-$(date '+%H%M%S').png" 2>/dev/null || true
    log "Screenshot: 03-after-menu-click (root)"

    # Search for any new dialog window that appeared
    CFG_WID=""
    for title in "Emulator Properties" "Configure" "General"; do
        CFG_WID="$(xdotool search --name "$title" 2>/dev/null | head -1 || true)"
        [ -n "$CFG_WID" ] && break
    done

    if [ -n "$CFG_WID" ]; then
        log "Configure dialog found: $CFG_WID"
        import -window root "$RESULTS_DIR/04-configure-dialog-$(date '+%H%M%S').png" 2>/dev/null || true

        # Tab through to the Shared folder field, then type the path
        xdotool windowfocus "$CFG_WID" 2>/dev/null || true
        sleep 0.5
        for i in $(seq 1 12); do
            xdotool key --window "$CFG_WID" Tab
            sleep 0.2
        done
        sleep 0.5
        xdotool type --window "$CFG_WID" --delay 50 "$SHARE_WIN"
        sleep 1
        import -window root "$RESULTS_DIR/05-shared-folder-set-$(date '+%H%M%S').png" 2>/dev/null || true

        # Press Enter to confirm (OK button)
        xdotool key --window "$CFG_WID" Return
        sleep 2
        log "Shared folder set via Configure dialog"
    else
        log "WARNING: Configure dialog not found. Trying keyboard shortcut approach..."
        import -window root "$RESULTS_DIR/04-no-dialog-$(date '+%H%M%S').png" 2>/dev/null || true

        # Fallback: try sending Alt+F,C via X keyboard events to the root
        xdotool key alt+f
        sleep 1
        xdotool key c
        sleep 2
        import -window root "$RESULTS_DIR/05-fallback-$(date '+%H%M%S').png" 2>/dev/null || true
    fi
    capture_screenshot "06-after-hotplug"
    log "Shared folder hot-plug attempted: $SHARE_WIN"
fi

# --- Wait for autorun to trigger ---
log "Waiting 15s for autorun.exe to launch Navit..."
sleep 15
capture_screenshot "07-navit-check"

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
