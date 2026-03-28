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
# All navigation uses keyboard (Super, arrows, Enter, F1).
# Confirmed from CI:
#   - Super opens Start menu
#   - In landscape: 6 Down reaches Programs (Today is pre-selected)
#   - In portrait: may need 7 Down (if nothing is pre-selected)
#   - Enter opens the selected item
#   - Programs grid: 3 Right from Games reaches File Explorer
#   - F1 in File Explorer = "Up" (goes from My Documents to My Device root)
#   - My Device root has 9 folders; Storage Card is 7th (6 Down)

log "Navigating WinCE GUI to launch navit.exe..."

if [ -z "$EMU_WID" ]; then
    log "WARNING: Could not find Device Emulator window"
else
    xdotool windowfocus "$EMU_WID" 2>/dev/null || true
    sleep 0.5

    # Step 1: Open Start menu
    log "Step 1: Opening Start menu (Super key)..."
    emu_key super
    sleep 1
    capture_screenshot "02-start-menu"

    # Step 2: Navigate to Programs
    # The Start menu has a variable number of recent items at the top, making
    # Down-counting unreliable. Instead, jump to the bottom with End, then go
    # Up to reach "Programs" which is always 2 above the bottom (Help → Settings → Programs).
    log "Step 2: Navigating to Programs (End then 2x Up)..."
    emu_key End
    sleep 0.3
    emu_key Up
    emu_key Up
    sleep 0.5
    capture_screenshot "03-programs-highlighted"

    log "Step 2b: Opening Programs (Enter)..."
    emu_key Return
    sleep 2
    capture_screenshot "04-programs-screen"

    # Step 3: Navigate to File Explorer in Programs grid
    # Landscape grid (4 columns): Games | ActiveSync | Calculator | File Explorer
    #   → 3 Right from Games
    # Portrait grid (3 columns): Games | ActiveSync | Calculator
    #                            File Explorer | Getting Started | ...
    #   → 1 Down from Games (File Explorer is row 2, col 1)
    log "Step 3: Navigating to File Explorer..."
    if [ "$ROTATE" = "1" ] || [ "$ROTATE" = "3" ]; then
        emu_key Right
        emu_key Right
        emu_key Right
    else
        emu_key Down
    fi
    sleep 0.5
    capture_screenshot "05-file-explorer-highlighted"
    emu_key Return
    sleep 2
    capture_screenshot "06-file-explorer-opened"

    # Step 4: Navigate up from My Documents to My Device root
    # F1 = left softkey = "Up" in File Explorer
    log "Step 4: Going up to root (F1 = Up)..."
    emu_key F1
    sleep 1
    capture_screenshot "07-my-device-root"

    # Step 5: Navigate to Storage Card
    # My Device root (confirmed from CI):
    #   1. Application Data (selected)
    #   2. ConnMgr
    #   3. Documents and Settings
    #   4. MUSIC
    #   5. My Documents
    #   6. Program Files
    #   7. Storage Card  ← target (6 Down)
    log "Step 5: Navigating to Storage Card (6x Down)..."
    for i in 1 2 3 4 5 6; do
        emu_key Down
    done
    sleep 0.5
    capture_screenshot "08-storage-card-highlighted"
    emu_key Return
    sleep 2
    capture_screenshot "09-storage-card-contents"

    # Step 6: Navigate to navit.exe
    # Use type-ahead: pressing "n" in File Explorer jumps to the first
    # file starting with "n" = navit.exe (7.93M, the largest "navit" file).
    # Folders are listed first, then files alphabetically.
    # autorun.exe comes before navit*, so "n" should jump to navit.exe.
    log "Step 6: Jumping to navit.exe (type-ahead 'n')..."
    xdotool type --window "$EMU_WID" "n"
    sleep 1
    capture_screenshot "10-navit-highlighted"

    # navit.exe should now be highlighted. Open it.
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

# --- Check navit.log for env var expansion ---
# The Device Emulator shared folder may be read-only from WinCE side,
# so navit.log might not appear in $NAVIT_DIR. Search broader locations too.
log "Searching for navit.log..."
find "$NAVIT_DIR" "$WINEPREFIX" -name "navit.log" 2>/dev/null | while read -r f; do
    log "  Found: $f ($(wc -c < "$f") bytes)"
done
NAVIT_LOG="$(find "$NAVIT_DIR" "$WINEPREFIX" -name "navit.log" 2>/dev/null | head -1)"
[ -z "$NAVIT_LOG" ] && NAVIT_LOG="$NAVIT_DIR/navit.log"
if [ -f "$NAVIT_LOG" ]; then
    cp "$NAVIT_LOG" "$RESULTS_DIR/"
    log "navit.log found ($(wc -l < "$NAVIT_LOG") lines)"

    # Check if $NAVIT_SHAREDIR was expanded (not left as literal)
    if grep -q '\$NAVIT_SHAREDIR' "$NAVIT_LOG"; then
        log "FAIL: \$NAVIT_SHAREDIR not expanded — env var fix is broken"
        grep '\$NAVIT_SHAREDIR' "$NAVIT_LOG" | head -5 | while read -r line; do log "  $line"; done
        ENVVAR_FAIL=1
    fi

    # Check for the specific error from issue #1499
    if grep -q "Failed to load.*\\\$" "$NAVIT_LOG"; then
        log "FAIL: Map loading failed with unexpanded variable (issue #1499)"
        grep "Failed to load" "$NAVIT_LOG" | head -5 | while read -r line; do log "  $line"; done
        ENVVAR_FAIL=1
    fi

    # Check for successful map loading
    if grep -qi "binfile.*open\|map_new.*binfile" "$NAVIT_LOG"; then
        log "PASS: binfile map operations detected in log"
    fi

    if [ "${ENVVAR_FAIL:-0}" = "1" ]; then
        log "Results in $RESULTS_DIR/"
        ls -la "$RESULTS_DIR/"
        exit 1
    fi
else
    log "WARNING: navit.log not found in shared folder"
fi

log "Results in $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
exit 0
