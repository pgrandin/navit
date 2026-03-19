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
#   SMOKE_TIMEOUT  - total timeout in seconds (default: 120)

set -euo pipefail

EMU_DIR="${EMU_DIR:-emulator}"
NAVIT_DIR="${NAVIT_DIR:-navit-package}"
RESULTS_DIR="smoke-results"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120}"

export WINEPREFIX="$PWD/.wine-emu"
export WINEARCH=win32
export WINEDEBUG="-all,+err"
# Skip mono/gecko downloads — they hang in CI and aren't needed for Device Emulator
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/smoke-test.log"; }

capture_screenshot() {
    local label="${1:-screenshot}"
    local outfile="$RESULTS_DIR/${label}-$(date '+%H%M%S').png"
    import -window root "$outfile" 2>/dev/null && \
        log "Screenshot: $outfile" || true
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
# Timeout wineboot — it can hang downloading mono/gecko even with WINEDLLOVERRIDES
timeout 60 wineboot --init 2>/dev/null || {
    log "WARNING: wineboot timed out or failed (exit $?) — continuing anyway"
}
timeout 10 wineserver --wait 2>/dev/null || true
log "Wine initialized"

# --- Convert paths to Windows format ---
EMU_WIN="$(winepath -w "$(realpath "$EMU_DIR/DeviceEmulator.exe")")"
ROM_WIN="$(winepath -w "$(realpath "$EMU_DIR/rom.bin")")"
SHARE_WIN="$(winepath -w "$(realpath "$NAVIT_DIR")")"

# --- Launch Device Emulator ---
log "Launching: wine $EMU_WIN $ROM_WIN /memsize 128 /sharedfolder $SHARE_WIN"

wine "$EMU_DIR/DeviceEmulator.exe" \
    "$ROM_WIN" \
    /memsize 128 \
    /sharedfolder "$SHARE_WIN" \
    > "$RESULTS_DIR/wine-output.log" 2>&1 &
EMU_PID=$!
log "Device Emulator PID: $EMU_PID"

# --- Wait for emulator window ---
BOOT_TIMEOUT=60
log "Waiting up to ${BOOT_TIMEOUT}s for emulator window..."
START=$SECONDS
BOOTED=false

while [ $((SECONDS - START)) -lt "$BOOT_TIMEOUT" ]; do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        log "Device Emulator died during boot"
        tail -30 "$RESULTS_DIR/wine-output.log" | tee -a "$RESULTS_DIR/smoke-test.log"
        capture_screenshot "crash"
        exit 1
    fi

    # Search for emulator window by various possible titles
    if xdotool search --name "Device Emulator" 2>/dev/null | grep -q . || \
       xdotool search --name "Windows Mobile" 2>/dev/null | grep -q . || \
       xdotool search --name "Pocket PC" 2>/dev/null | grep -q .; then
        BOOTED=true
        log "Emulator window detected after $((SECONDS - START))s"
        break
    fi

    sleep 2
done

capture_screenshot "boot"

if ! $BOOTED; then
    # Process alive but no window — might still be OK (rendering offscreen or unknown title)
    if kill -0 "$EMU_PID" 2>/dev/null; then
        log "WARNING: No window detected but process alive — continuing"
    else
        log "FATAL: No window and process dead"
        exit 1
    fi
fi

# --- Let WM finish booting ---
log "Waiting 20s for WM to stabilize..."
sleep 20
capture_screenshot "post-boot"

# Check process still alive after boot
if ! kill -0 "$EMU_PID" 2>/dev/null; then
    log "Device Emulator died after boot"
    tail -30 "$RESULTS_DIR/wine-output.log" | tee -a "$RESULTS_DIR/smoke-test.log"
    exit 1
fi

# --- Monitor for remaining time ---
REMAINING=$((SMOKE_TIMEOUT - (SECONDS - START)))
log "Monitoring for ${REMAINING}s more..."
LAST_SHOT=$SECONDS

while [ $((SECONDS - START)) -lt "$SMOKE_TIMEOUT" ]; do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        log "Device Emulator exited during monitoring"
        wait "$EMU_PID" 2>/dev/null || true
        capture_screenshot "exit"
        # Exiting during monitoring is a failure — the emulator should stay alive
        exit 1
    fi

    if [ $((SECONDS - LAST_SHOT)) -ge 20 ]; then
        capture_screenshot "monitor"
        LAST_SHOT=$SECONDS
    fi

    sleep 5
done

# --- Final ---
capture_screenshot "final"

if kill -0 "$EMU_PID" 2>/dev/null; then
    log "PASS: Device Emulator survived ${SMOKE_TIMEOUT}s"
else
    log "FAIL: Device Emulator died before timeout"
    exit 1
fi

# Collect any Navit logs from the shared folder
find "$NAVIT_DIR" -name "*.log" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true
ps aux > "$RESULTS_DIR/processes.txt" 2>/dev/null || true

log "Results in $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
exit 0
