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
sleep 40   # let the launcher settle so it doesn't ANR over navit
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS
launch(){ adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1; sleep 25; adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS; sleep 2; }
tap(){ adb shell input tap $1 $2; sleep 4; shot $3; }
launch; shot launched
tap 889 1568 welcome_ok
to_display(){ tap 540 1170 ${1}_menu; tap 667 1030 ${1}_settings; tap 404 1147 ${1}_display; }
to_display a
tap 386 1263 a_after_3d_tap
adb shell am force-stop $PKG; sleep 2
launch; shot b_relaunched
to_display b          # expect the toggle to read "2D" now
tap 386 1263 b_after_2d_tap
adb shell am force-stop $PKG; sleep 2
launch; shot c_relaunched
to_display c          # expect "3D" again
adb logcat -d > out/logcat.txt
