#!/bin/bash
# Phase 1: explore — install, launch, screenshot, tap centre, screenshot.
set -x
PKG=org.navitproject.navit.debug
mkdir -p out
n=0
shot(){ n=$((n+1)); adb exec-out screencap -p > out/$(printf %02d $n)_$1.png; }
adb shell wm size > out/wm_size.txt
adb install -g apk/debug/navit-android--debug-signed.apk
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
sleep 25; shot launched
adb shell input tap 540 1100; sleep 5; shot tap_centre
adb shell run-as $PKG find . -maxdepth 3 > out/appdir.txt 2>&1
adb logcat -d > out/logcat.txt
