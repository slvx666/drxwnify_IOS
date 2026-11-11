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
  Drxwnify/Support/HTTP.swift
  Drxwnify/Support/JSON.swift
  Drxwnify/Spotify/SpotifyModels.swift
  Drxwnify/Spotify/SpotifyAuth.swift
  Drxwnify/Resolver/AudioModels.swift
  Drxwnify/Resolver/FuzzyTrackMatch.swift
  Drxwnify/Resolver/ParallelAudioResolver.swift
  Drxwnify/Support/AppLinks.swift
  Drxwnify/Friends/Secp256k1.swift
  Drxwnify/Friends/Nostr.swift
  Drxwnify/Resolver/Providers/YouTubeProvider.swift
  Drxwnify/Resolver/Providers/BandcampProvider.swift
  Drxwnify/Resolver/Providers/AudiusProvider.swift
)

python3 scripts/nostr_vectors.py "$T/nostr.json"
python3 scripts/test_fixtures.py make Drxwnify/Resources/Schema/song_v40.sql "$T/android.backup"
swiftc -O -swift-version 5 -o "$T/host-tests" "${SOURCES[@]}" DrxwnifyTests/Host/*.swift 2>&1 | grep -E "error|warning: unre" || true
NOSTR_VECTORS="$T/nostr.json" LIVE="${LIVE:-0}" "$T/host-tests" "$T/android.backup" "$T/ios.backup"
python3 scripts/test_fixtures.py verify "$T/ios.backup"
