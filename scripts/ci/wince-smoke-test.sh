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

# --- Launch Device Emulator ---
# Boot WITH /sharedfolder so the Storage Card is available.
# After the shell boots, we soft-reset via File > Reset > Soft to trigger
# the autorun.exe mechanism on the second boot cycle.
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

# --- Wait for WinCE shell to fully boot ---
log "Waiting 30s for WinCE shell to boot..."
sleep 30
capture_screenshot "01-post-boot"

if ! kill -0 "$EMU_PID" 2>/dev/null; then
    log "Device Emulator died after boot"
    exit 1
fi

# --- Soft-reset to trigger autorun.exe ---
# The Storage Card (shared folder) is present from boot, but the WinCE shell
# may not trigger SHGetAutoRunPath() for a card that was already mounted.
# A soft reset re-initializes the shell while keeping the Storage Card mounted,
# which should trigger autorun detection on the second boot.
log "Performing soft reset via File > Reset > Soft..."
EMU_WID="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window for soft reset"
else
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Get window geometry for menu coordinate calculation
    eval "$(xdotool getwindowgeometry --shell "$EMU_WID" 2>/dev/null)" || true
    log "Emulator window at X=$X Y=$Y W=${WIDTH:-?} H=${HEIGHT:-?}"

    # Click "File" in the host menu bar
    xdotool mousemove --window "$EMU_WID" 15 8
    sleep 0.3
    xdotool click --window "$EMU_WID" 1
    sleep 1
    import -window root "$RESULTS_DIR/02-file-menu-$(date '+%H%M%S').png" 2>/dev/null || true

    # Click "Reset >" submenu (3rd item in File dropdown)
    #   Save State and Exit  (~16px)
    #   Clear Saved State    (~16px)
    #   Reset >              (~16px)  <-- target
    MENU_X=$((X + 30))
    MENU_Y=$((Y + 19 + 16*2 + 8))
    log "Clicking Reset at absolute ($MENU_X, $MENU_Y)"
    xdotool mousemove "$MENU_X" "$MENU_Y"
    sleep 0.5
    import -window root "$RESULTS_DIR/03-reset-hover-$(date '+%H%M%S').png" 2>/dev/null || true

    # The submenu appears to the right of "Reset" with "Soft" as the first item.
    # From screenshots: the submenu "Soft" is at roughly window-relative (155, 60).
    # Move slowly rightward to keep the submenu open, then click "Soft".
    xdotool mousemove --window "$EMU_WID" 100 60
    sleep 0.3
    xdotool mousemove --window "$EMU_WID" 140 60
    sleep 0.3
    xdotool mousemove --window "$EMU_WID" 165 60
    sleep 0.3
    import -window root "$RESULTS_DIR/04-submenu-hover-$(date '+%H%M%S').png" 2>/dev/null || true
    xdotool click 1
    sleep 2
    import -window root "$RESULTS_DIR/05-after-soft-click-$(date '+%H%M%S').png" 2>/dev/null || true

    # A confirmation dialog appears: "Are you sure you want to reset the guest OS?"
    # with Yes and No buttons. Click "Yes" with mouse coordinates.
    # From screenshots: Yes button is at approximately (140, 305) in root window.
    # The dialog is rendered inside the emulator window area.
    sleep 1
    import -window root "$RESULTS_DIR/06-confirm-dialog-$(date '+%H%M%S').png" 2>/dev/null || true

    # Click "Yes" button — it's at roughly window-relative (75, 275) based on
    # the dialog being centered in the 240-wide emulator window
    YES_X=$((X + 75))
    YES_Y=$((Y + 275))
    log "Clicking Yes at absolute ($YES_X, $YES_Y)"
    xdotool mousemove "$YES_X" "$YES_Y"
    sleep 0.3
    xdotool click 1
    sleep 1
    import -window root "$RESULTS_DIR/07-after-confirm-$(date '+%H%M%S').png" 2>/dev/null || true
    log "Soft reset confirmed"

    # Wait for the emulator to reboot
    sleep 5
    EMU_WID2="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
    if [ -n "$EMU_WID2" ]; then
        log "Emulator window after reset: $EMU_WID2"
    else
        log "WARNING: Emulator window not found after reset"
    fi
fi

# --- Wait for second boot + autorun ---
log "Waiting 30s for WinCE to reboot and autorun.exe to launch Navit..."
sleep 30
capture_screenshot "08-post-reset"

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
