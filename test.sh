#!/bin/bash
# Phase 2: explore with the release APK (debug APK ships without config assets).
set -x
PKG=org.navitproject.navit
mkdir -p out
n=0
shot(){ n=$((n+1)); adb exec-out screencap -p > out/$(printf %02d $n)_$1.png; }
adb install -g apk/release/navit-android--release-signed.apk
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
sleep 30; shot launched
adb shell input tap 540 1200; sleep 5; shot tap1
sleep 5; shot tap1_later
adb logcat -d > out/logcat.txt
