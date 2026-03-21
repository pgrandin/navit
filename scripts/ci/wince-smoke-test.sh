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
# WinCE shell calls SHGetAutoRunPath() when a storage card is INSERTED and
# runs \Storage Card\<procID>\autorun.exe automatically.
# We also place a copy at the root for ROMs that check there instead.
mkdir -p "$NAVIT_DIR/2577"
cp "$NAVIT_DIR/navit.exe" "$NAVIT_DIR/2577/autorun.exe"
cp "$NAVIT_DIR/navit.exe" "$NAVIT_DIR/autorun.exe"
log "Created autorun.exe at root and 2577/ for SD card autorun"

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
# Boot WITHOUT /sharedfolder so we can hot-plug it later.
# Hot-plugging triggers a genuine storage card insertion event in WinCE,
# which causes the shell to detect and run autorun.exe.
log "Launching Device Emulator (without shared folder)..."

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

# --- Hot-plug storage card via File > Configure ---
# Open the Device Emulator's Configure dialog and set the shared folder.
# This triggers a genuine storage card insertion event in WinCE,
# which causes the shell to execute autorun.exe → launches Navit.
log "Hot-plugging storage card via File > Configure..."
EMU_WID="$(xdotool search --name 'Device Emulator' 2>/dev/null | head -1 || true)"
if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window for hot-plug"
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

    # Click "Configure..." (4th item in File dropdown)
    #   Save State and Exit  (~18px)
    #   Clear Saved State    (~18px)
    #   Reset >              (~18px)
    #   Configure...         (~18px)  <-- target
    #   Exit
    CONF_X=$((X + 50))
    CONF_Y=$((Y + 19 + 18*3 + 9))
    log "Clicking Configure at absolute ($CONF_X, $CONF_Y)"
    xdotool mousemove "$CONF_X" "$CONF_Y"
    sleep 0.5
    import -window root "$RESULTS_DIR/03-configure-hover-$(date '+%H%M%S').png" 2>/dev/null || true
    xdotool click 1
    sleep 2
    import -window root "$RESULTS_DIR/04-configure-dialog-$(date '+%H%M%S').png" 2>/dev/null || true

    # The Configure dialog should now be open.
    # We need to find and fill the "Shared Folder" field.
    # Look for the Configure dialog window.
    CONF_WID="$(xdotool search --name 'Emulator Properties' 2>/dev/null | head -1 || true)"
    if [ -z "$CONF_WID" ]; then
        CONF_WID="$(xdotool search --name 'Configure' 2>/dev/null | head -1 || true)"
    fi
    if [ -z "$CONF_WID" ]; then
        CONF_WID="$(xdotool getactivewindow 2>/dev/null || true)"
    fi
    log "Configure dialog window: ${CONF_WID:-not found}"

    if [ -n "$CONF_WID" ]; then
        # Take a screenshot of the dialog window itself
        import -window "$CONF_WID" "$RESULTS_DIR/05-configure-window-$(date '+%H%M%S').png" 2>/dev/null || true

        # Try to find the shared folder field.
        # In the Device Emulator Properties dialog, there's typically a
        # "Shared Folder" text field. Try using Tab to navigate to it.
        # The dialog may have multiple tabs and fields.
        # Strategy: use xdotool to type the shared folder path into the
        # field. We'll try Alt+keyboard shortcuts first.

        # First, let's see if there's a "General" or "Peripherals" tab
        # with the shared folder. Take a screenshot of the dialog first.
        xdotool windowfocus "$CONF_WID" 2>/dev/null || true
        sleep 0.5

        # Try clicking on "General" tab if it exists (usually first tab, top-left)
        # Tab headers are typically at the top of the dialog
        # Try clicking at various positions to find the shared folder field

        # Get configure dialog geometry
        eval "$(xdotool getwindowgeometry --shell "$CONF_WID" 2>/dev/null)" || {
            log "Could not get Configure dialog geometry"
        }
        log "Configure dialog at X=$X Y=$Y W=${WIDTH:-?} H=${HEIGHT:-?}"

        # The shared folder field is likely a text input near the bottom of
        # the General tab. Try clearing any existing value and typing our path.
        # Use Ctrl+A to select all text in a field, then type the new path.

        # Navigate through the dialog controls with Tab
        # Try tabbing through and typing at each position,
        # taking screenshots to see where we are
        for tab_count in 1 2 3 4 5 6 7 8; do
            xdotool key Tab
            sleep 0.2
        done
        import -window root "$RESULTS_DIR/06-after-tabs-$(date '+%H%M%S').png" 2>/dev/null || true

        # Try typing the shared folder path
        # First select all text in the current field
        xdotool key ctrl+a
        sleep 0.2
        xdotool type --clearmodifiers "$SHARE_WIN"
        sleep 0.5
        import -window root "$RESULTS_DIR/07-after-type-$(date '+%H%M%S').png" 2>/dev/null || true

        # Click OK to apply (typically bottom-right of dialog)
        # OK button is usually at the bottom of the dialog
        if [ -n "${WIDTH:-}" ] && [ -n "${HEIGHT:-}" ]; then
            OK_X=$((X + WIDTH - 170))
            OK_Y=$((Y + HEIGHT - 15))
            log "Clicking OK at absolute ($OK_X, $OK_Y)"
            xdotool mousemove "$OK_X" "$OK_Y"
            sleep 0.3
            xdotool click 1
        else
            # Fallback: press Enter for OK
            xdotool key Return
        fi
        sleep 2
        import -window root "$RESULTS_DIR/08-after-ok-$(date '+%H%M%S').png" 2>/dev/null || true
        log "Configure dialog closed"
    else
        log "WARNING: Could not find Configure dialog window"
    fi
fi

# --- Wait for Navit to launch via autorun ---
log "Waiting 30s for autorun.exe to detect storage card and launch Navit..."
sleep 30
capture_screenshot "09-post-hotplug"

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
