#!/bin/bash
# Phase 2: explore with the release APK (debug APK ships without config assets).
set -x
PKG=org.navitproject.navit
mkdir -p out
n=0
shot(){ n=$((n+1)); adb exec-out screencap -p > out/$(printf %02d $n)_$1.png; }
BT=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1)
keytool -genkeypair -keystore t.jks -storepass android -keypass android -alias t -keyalg RSA -keysize 2048 -validity 1000 -dname CN=test -noprompt
$BT/zipalign -f -p 4 apk/release/navit-android--release-signed.apk aligned.apk
$BT/apksigner sign --ks t.jks --ks-pass pass:android --out navit.apk aligned.apk
adb install -g navit.apk
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
sleep 30; shot launched
adb shell input tap 540 1200; sleep 5; shot tap1
sleep 5; shot tap1_later
adb logcat -d > out/logcat.txt
