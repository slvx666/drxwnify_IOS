#!/bin/bash
# Выполняется на VM macOS из ~/drxwnify-ios. Запускает его scripts/build.ps1.
# Лог целиком пишется в ~/drxwnify-ios/build.log, код возврата = результат сборки.
set -o pipefail
export PATH="$HOME/bin:$PATH"
cd "$HOME/drxwnify-ios" || exit 2

DD="$HOME/drxwnify-dd"
SPM="$HOME/drxwnify-spm"
LOG="$PWD/build.log"
: > "$LOG"

# Секреты (Last.fm) не в git: без файла собирается приложение без Last.fm.
[ -f secrets.xcconfig ] || printf 'LASTFM_API_KEY =\nLASTFM_SECRET =\n' > secrets.xcconfig

echo "== xcodegen" >> "$LOG"
xcodegen generate >> "$LOG" 2>&1 || exit 10

echo "== xcodebuild" >> "$LOG"
# На VM стоит только iOS SDK, без компонента «iOS platform», поэтому
# `-scheme … -destination generic/platform=iOS` не находит устройство.
# Сборка через -target работает без destination.
xcodebuild \
  -project Drxwnify.xcodeproj \
  -target Drxwnify \
  -configuration Release \
  -sdk iphoneos \
  -clonedSourcePackagesDirPath "$SPM" \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DD/Build/Products" \
  OBJROOT="$DD/Build/Intermediates" \
  build >> "$LOG" 2>&1 || exit 20

APP="$DD/Build/Products/Release-iphoneos/Drxwnify.app"
[ -d "$APP" ] || { echo "error: нет $APP" >> "$LOG"; exit 30; }

echo "== ipa" >> "$LOG"
rm -rf out && mkdir -p out/Payload
cp -R "$APP" out/Payload/ || exit 31
(cd out && zip -qry Drxwnify.ipa Payload) >> "$LOG" 2>&1 || exit 32
ls -l out/Drxwnify.ipa >> "$LOG"
exit 0
