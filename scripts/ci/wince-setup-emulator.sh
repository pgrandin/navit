#!/usr/bin/env bash
# Download and extract Microsoft Device Emulator 3.0 and WM 6.1 ROM images.
# Designed to run on GitHub-hosted Ubuntu runners (no Wine needed for extraction).
#
# Output:
#   emulator/DeviceEmulator.exe  — the emulator binary
#   emulator/rom.bin             — the WM ROM image
#
# Usage: bash scripts/ci/wince-setup-emulator.sh [output_dir]

set -euo pipefail

OUT_DIR="${1:-emulator}"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

log() { echo "[emu-setup] $*"; }

# --- Install extraction tools if missing ---
install_tools() {
    local need_install=false
    for tool in 7z msiextract cabextract; do
        if ! command -v "$tool" &>/dev/null; then
            need_install=true
            break
        fi
    done
    if $need_install; then
        log "Installing extraction tools..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq p7zip-full msitools cabextract
    fi
}

# --- Download Device Emulator 3.0 (32-bit) ---
download_device_emulator() {
    if [ -f "vs_emulator.exe" ]; then
        log "Device Emulator installer already present"
        return
    fi
    log "Downloading Microsoft Device Emulator 3.0 (32-bit)..."
    curl -fSL --retry 3 -o vs_emulator.exe \
        "https://archive.org/download/microsoft_emulators/vs_emulator.exe"
    log "Downloaded vs_emulator.exe ($(du -h vs_emulator.exe | cut -f1))"
}

# --- Extract Device Emulator ---
extract_device_emulator() {
    if [ -f "DeviceEmulator.exe" ]; then
        log "DeviceEmulator.exe already extracted"
        return
    fi

    log "Extracting Device Emulator..."
    mkdir -p emu_tmp

    # vs_emulator.exe is a self-extracting setup — try multiple extraction methods
    # Method 1: 7z (handles most installer formats)
    if 7z x vs_emulator.exe -oemu_tmp -y >/dev/null 2>&1; then
        log "Extracted with 7z"
    # Method 2: cabextract
    elif cabextract -d emu_tmp vs_emulator.exe >/dev/null 2>&1; then
        log "Extracted with cabextract"
    else
        log "ERROR: Could not extract vs_emulator.exe with 7z or cabextract"
        log "Contents may require Wine-based installation"
        return 1
    fi

    # Search for DeviceEmulator.exe in extracted files
    local found
    found="$(find emu_tmp -iname "DeviceEmulator.exe" -print -quit 2>/dev/null || true)"

    if [ -n "$found" ]; then
        cp "$found" DeviceEmulator.exe
        log "Found DeviceEmulator.exe: $(du -h DeviceEmulator.exe | cut -f1)"
    else
        # The installer may contain MSI files that need further extraction
        log "DeviceEmulator.exe not found directly, checking for nested MSI/CAB..."
        local msi_file
        msi_file="$(find emu_tmp -iname "*.msi" -print -quit 2>/dev/null || true)"
        if [ -n "$msi_file" ]; then
            log "Found nested MSI: $msi_file"
            mkdir -p emu_msi_tmp
            msiextract "$msi_file" -C emu_msi_tmp 2>/dev/null || \
                7z x "$msi_file" -oemu_msi_tmp -y >/dev/null 2>&1 || true
            found="$(find emu_msi_tmp -iname "DeviceEmulator.exe" -print -quit 2>/dev/null || true)"
            if [ -n "$found" ]; then
                cp "$found" DeviceEmulator.exe
                log "Found DeviceEmulator.exe in nested MSI: $(du -h DeviceEmulator.exe | cut -f1)"
            fi
            rm -rf emu_msi_tmp
        fi

        # Check for CAB files
        if [ ! -f "DeviceEmulator.exe" ]; then
            for cab in $(find emu_tmp -iname "*.cab" 2>/dev/null); do
                mkdir -p emu_cab_tmp
                cabextract -d emu_cab_tmp "$cab" >/dev/null 2>&1 || true
                found="$(find emu_cab_tmp -iname "DeviceEmulator.exe" -print -quit 2>/dev/null || true)"
                if [ -n "$found" ]; then
                    cp "$found" DeviceEmulator.exe
                    log "Found DeviceEmulator.exe in CAB: $(du -h DeviceEmulator.exe | cut -f1)"
                    rm -rf emu_cab_tmp
                    break
                fi
                rm -rf emu_cab_tmp
            done
        fi
    fi

    rm -rf emu_tmp

    if [ ! -f "DeviceEmulator.exe" ]; then
        log "ERROR: Could not find DeviceEmulator.exe after extraction"
        log "Falling back to Wine-based installation..."
        extract_device_emulator_wine
    fi
}

# --- Fallback: extract using Wine ---
extract_device_emulator_wine() {
    log "Attempting Wine-based extraction of Device Emulator..."
    local wine_prefix="$PWD/wine_tmp"
    export WINEPREFIX="$wine_prefix"
    export WINEARCH=win32
    export WINEDEBUG=-all

    # Initialize Wine prefix
    xvfb-run -a wineboot --init 2>/dev/null
    wineserver --wait 2>/dev/null || true

    # Run the installer silently
    xvfb-run -a wine vs_emulator.exe /quiet /norestart 2>/dev/null || true
    wineserver --wait 2>/dev/null || true

    # Find the installed binary
    local found
    found="$(find "$wine_prefix" -iname "DeviceEmulator.exe" -print -quit 2>/dev/null || true)"
    if [ -n "$found" ]; then
        cp "$found" DeviceEmulator.exe
        log "Found DeviceEmulator.exe via Wine install: $(du -h DeviceEmulator.exe | cut -f1)"
        # Also grab any DLLs from the same directory
        local emu_dir
        emu_dir="$(dirname "$found")"
        cp "$emu_dir"/*.dll . 2>/dev/null || true
    else
        log "FATAL: Could not extract DeviceEmulator.exe by any method"
        rm -rf "$wine_prefix"
        return 1
    fi

    rm -rf "$wine_prefix"
    unset WINEPREFIX WINEARCH WINEDEBUG
}

# --- Download WM 6.1 ROM images ---
download_wm_images() {
    if [ -f "rom.bin" ]; then
        log "ROM image already present"
        return
    fi

    log "Downloading Windows Mobile 6.1.4 Emulator Images..."

    # Try the WM 6.1.4 emulator images from Internet Archive
    if [ ! -f "wm_images_raw" ]; then
        # The archive.org item may be an MSI or an EXE installer
        curl -fSL --retry 3 -o wm_images_raw \
            "https://archive.org/download/WM614Emulator/Windows%20Mobile%206.1.4%20Emulator%20Images%20-%20ENU.msi" 2>/dev/null || \
        curl -fSL --retry 3 -o wm_images_raw \
            "https://archive.org/download/windows-mobile-emulation-images-archive.-7z/Windows%20Mobile%20Emulation%20Images%20Archive.7z" 2>/dev/null || {
            log "ERROR: Could not download WM emulator images"
            return 1
        }
    fi

    log "Downloaded WM images ($(du -h wm_images_raw | cut -f1))"
    extract_wm_images
}

# --- Extract WM ROM .bin ---
extract_wm_images() {
    log "Extracting WM ROM images..."
    mkdir -p wm_tmp

    local ext
    ext="$(file wm_images_raw | head -1)"

    # Try extraction methods based on file type
    if echo "$ext" | grep -qi "msi\|composite"; then
        msiextract wm_images_raw -C wm_tmp 2>/dev/null || \
            7z x wm_images_raw -owm_tmp -y >/dev/null 2>&1 || true
    elif echo "$ext" | grep -qi "7-zip\|7z"; then
        7z x wm_images_raw -owm_tmp -y >/dev/null 2>&1 || true
    else
        # Try all methods
        msiextract wm_images_raw -C wm_tmp 2>/dev/null || \
            7z x wm_images_raw -owm_tmp -y >/dev/null 2>&1 || \
            cabextract -d wm_tmp wm_images_raw >/dev/null 2>&1 || true
    fi

    # Find .bin ROM files (should be >10MB for a real ROM image)
    local rom_file
    rom_file="$(find wm_tmp -iname "*.bin" -size +10M -print -quit 2>/dev/null || true)"

    if [ -z "$rom_file" ]; then
        # May need to extract nested CABs
        log "No large .bin found directly, checking nested archives..."
        for nested in $(find wm_tmp -iname "*.cab" -o -iname "*.msi" 2>/dev/null); do
            mkdir -p wm_nested_tmp
            cabextract -d wm_nested_tmp "$nested" >/dev/null 2>&1 || \
                msiextract "$nested" -C wm_nested_tmp 2>/dev/null || \
                7z x "$nested" -owm_nested_tmp -y >/dev/null 2>&1 || true
            rom_file="$(find wm_nested_tmp -iname "*.bin" -size +10M -print -quit 2>/dev/null || true)"
            if [ -n "$rom_file" ]; then
                break
            fi
            rm -rf wm_nested_tmp
        done
    fi

    if [ -n "$rom_file" ]; then
        cp "$rom_file" rom.bin
        log "Found ROM image: rom.bin ($(du -h rom.bin | cut -f1))"
        # Also grab skin files if present
        local skin_dir
        skin_dir="$(dirname "$rom_file")"
        find "$(dirname "$skin_dir")" -iname "*skin*" -exec cp {} . \; 2>/dev/null || true
        find "$(dirname "$skin_dir")" -iname "*.xml" -path "*skin*" -exec cp {} . \; 2>/dev/null || true
    else
        log "ERROR: No ROM .bin image found after extraction"
        log "Files found:"
        find wm_tmp -type f -exec ls -lh {} \; 2>/dev/null | head -20
        rm -rf wm_tmp wm_nested_tmp
        return 1
    fi

    rm -rf wm_tmp wm_nested_tmp
}

# --- Main ---
install_tools
download_device_emulator
extract_device_emulator
download_wm_images

log ""
log "=== Setup Complete ==="
if [ -f "DeviceEmulator.exe" ] && [ -f "rom.bin" ]; then
    log "DeviceEmulator.exe: $(du -h DeviceEmulator.exe | cut -f1)"
    log "rom.bin: $(du -h rom.bin | cut -f1)"
    log "Ready for smoke test"
    exit 0
else
    log "INCOMPLETE — missing files:"
    [ ! -f "DeviceEmulator.exe" ] && log "  - DeviceEmulator.exe"
    [ ! -f "rom.bin" ] && log "  - rom.bin"
    exit 1
fi
