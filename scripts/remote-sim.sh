#!/bin/bash
# Выполняется на VM из ~/drxwnify-ios (запускает scripts/sim.ps1 build).
# Debug-сборка под симулятор iOS 26 и установка на симулятор «Drxwnify-26». Лог — ~/drxwnify-ios/sim-build.log.
# Все команды simctl идут через ~/bin/drx-gui (scripts/vm-gui.sh): симулятор грузится только из GUI-сессии.
set -o pipefail
export PATH="$HOME/bin:$PATH"
cd "$HOME/drxwnify-ios" || exit 2

DD="$HOME/drxwnify-dd-sim"
SPM="$HOME/drxwnify-spm"
LOG="$PWD/sim-build.log"
SIM_NAME="Drxwnify-26"
: > "$LOG"

mkdir -p "$HOME/bin"
tr -d '\r' < scripts/vm-gui.sh > "$HOME/bin/drx-gui" && chmod +x "$HOME/bin/drx-gui"

[ -f secrets.xcconfig ] || printf 'LASTFM_API_KEY =\nLASTFM_SECRET =\n' > secrets.xcconfig

echo "== xcodegen" >> "$LOG"
xcodegen generate >> "$LOG" 2>&1 || exit 10

echo "== xcodebuild" >> "$LOG"
xcodebuild \
  -project Drxwnify.xcodeproj \
  -target Drxwnify \
  -configuration Debug \
  -sdk iphonesimulator \
  -clonedSourcePackagesDirPath "$SPM" \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DD/Build/Products" \
  OBJROOT="$DD/Build/Intermediates" \
  build >> "$LOG" 2>&1 || exit 20

APP="$DD/Build/Products/Debug-iphonesimulator/Drxwnify.app"
[ -d "$APP" ] || { echo "error: нет $APP" >> "$LOG"; exit 30; }

echo "== simulator" >> "$LOG"
# GUI-сессия появляется через ~1–3 мин после загрузки VM (автовход).
for i in $(seq 1 60); do launchctl print "gui/$(id -u)" >/dev/null 2>&1 && break; sleep 5; done
# Служба симулятора, запущенная из SSH, мешает загрузке — убрать, её поднимет drx-gui.
if launchctl print "user/$(id -u)" 2>/dev/null | grep -q CoreSimulator.CoreSimulatorService; then
  launchctl bootout "user/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService" 2>/dev/null
  launchctl bootout "user/$(id -u)/com.apple.CoreSimulator.SimLaunchHost-x86" 2>/dev/null
fi

drx-gui "
set -o pipefail
UDID=\$(xcrun simctl list devices | grep '$SIM_NAME (' | grep -v unavailable | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z \"\$UDID\" ]; then
  RT=\$(xcrun simctl list runtimes | grep -E '^iOS 26' | tail -1 | sed -E 's/.* - (com\.apple\.[^ ]+).*/\1/')
  [ -n \"\$RT\" ] || { echo 'error: нет рантайма симулятора iOS 26'; exit 40; }
  UDID=\$(xcrun simctl create '$SIM_NAME' com.apple.CoreSimulator.SimDeviceType.iPhone-17 \"\$RT\") || exit 41
fi
echo udid \$UDID
xcrun simctl bootstatus \$UDID -b | tail -3 || exit 42
xcrun simctl terminate \$UDID com.drxwnify.ios >/dev/null 2>&1
xcrun simctl install \$UDID '$APP' || exit 43
echo installed
" >> "$LOG" 2>&1
exit $?
