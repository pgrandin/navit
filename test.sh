#!/bin/bash
# Android persistence test for #532 (pitch + autozoom). Release APK, self-signed.
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
sleep 40   # let the launcher settle so it doesn't ANR over navit
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS
launch(){ adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1; sleep 25; adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS; sleep 3; }
restart(){ adb shell am force-stop $PKG; sleep 2; launch; shot ${1}_relaunched; }
tap(){ adb shell input tap $1 $2; sleep 4; shot $3; }
to_display(){ tap 540 1170 ${1}_menu; tap 667 1030 ${1}_settings; tap 404 1147 ${1}_display; }
PITCH="369 1244"; ZOOMTOGGLE="694 1244"; OSD_M="96 2120"

launch; shot launched
tap 889 1568 welcome_ok
to_display a                      # default: expect "2D" + "Manual zoom" (3D, autozoom on)
tap $ZOOMTOGGLE a_tap_manual_zoom
to_display a2
tap $PITCH a2_tap_2d
restart b
to_display b                      # expect "3D" + "Auto zoom" (2D, manual zoom) persisted
tap $PITCH b_tap_3d
tap $OSD_M b_tap_osd_autozoom
restart c
sleep 3
to_display c                      # expect "2D" + "Manual zoom" (3D, autozoom on) persisted
adb logcat -d > out/logcat.txt
