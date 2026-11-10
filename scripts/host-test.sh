#!/bin/bash
# Проверки формата на VM под macOS (симулятора iOS нет). Запуск: scripts/test.ps1 с Windows.
# Собирает чистые (без UIKit/GRDB) исходники приложения вместе с DrxwnifyTests/Host.
set -e
cd "$HOME/drxwnify-ios"
T="$HOME/drxwnify-hosttest"
rm -rf "$T" && mkdir -p "$T"

SOURCES=(
  Drxwnify/Storage/Prefs/PrefKey.swift
  Drxwnify/Storage/Prefs/PreferencesProto.swift
  Drxwnify/Storage/Prefs/AndroidPrefsXML.swift
  Drxwnify/Storage/Zip/ZipArchive.swift
)

python3 scripts/test_fixtures.py make Drxwnify/Resources/Schema/song_v40.sql "$T/android.backup"
swiftc -O -swift-version 5 -o "$T/host-tests" "${SOURCES[@]}" DrxwnifyTests/Host/*.swift 2>&1 | grep -E "error|warning: unre" || true
"$T/host-tests" "$T/android.backup" "$T/ios.backup"
python3 scripts/test_fixtures.py verify "$T/ios.backup"
