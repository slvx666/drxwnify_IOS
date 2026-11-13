# iPhone и Android с ПК: скриншоты, нажатия, свайпы, сверка экранов

Оба телефона подключены к Windows-ПК проводом. Всё делается из консоли, окна не открываются (пользователь в это время может играть).
Единый скрипт: `python ios/scripts/devices.py` (справка — без аргументов). VM с macOS для этого **не нужна**.

## Быстрый старт (новый чат)

```
python ios/scripts/devices.py wda status      # отвечает {'value': ... 'ready': True}? — можно работать
python ios/scripts/devices.py wda start       # если not running (после переподключения/перезагрузки айфона)
python ios/scripts/devices.py ios open home   # открыть экран Drxwnify без нажатий (DRX_SCREEN) + скриншот
python ios/scripts/devices.py ios buttons     # видимые кнопки текущего экрана с готовой командой "tap X Y"
python ios/scripts/devices.py ios tap 683 84  # нажать (пиксели скриншота айфона, 750x1334) + скриншот
python ios/scripts/devices.py ios swipe 375 1000 375 300   # пролистать вниз + скриншот
python ios/scripts/devices.py ios back        # «назад» = свайп от левого края
python ios/scripts/devices.py ios type текст  # ввод в поле с фокусом
python ios/scripts/devices.py ios shot        # только скриншот → ios/out/compare/ios-now.png
```
После каждого действия скрипт сам снимает экран в `ios/out/compare/ios-now.png` — смотреть его (Read), прежде чем нажимать дальше.
Пользователь может сам трогать телефон — перед нажатием по координатам брать свежий скриншот/`buttons`.

Те же команды для Android: `android shot|buttons|tap|swipe|type|back|home|open <экран>`.
Сверка: `compare <экран>` открывает экран на обоих, кладёт рядом → `ios/out/compare/<экран>.png` и печатает кнопки обоих
(экраны с прямым открытием — `SCREENS` в скрипте; разово: `compare -a <маршрут Android> -i <DRX_SCREEN> <имя>`).
Цель сверки: на iPhone интерфейс системный (по-айфоновски), но действий/кнопок на каждом экране столько же, сколько на Android.

## Если что-то не работает

| Симптом | Что делать |
|---|---|
| `Failed to connect to usbmuxd socket` | служба «Apple Mobile Device Service» не запущена (`Get-Service "Apple Mobile Device Service"`) |
| `usbmux list` пустой | айфон не подключён / не доверяет ПК (на айфоне «Доверять») |
| скриншот/запуск: ошибка про DeveloperDiskImage | после перезагрузки айфона: `python -m pymobiledevice3 mounter mount-developer D:\tools\ddi\DeveloperDiskImage.dmg D:\tools\ddi\DeveloperDiskImage.dmg.signature` (с `PYTHONPATH=D:\tools\pmd3`) |
| `wda start` → не отвечает 120 с, в `ios/out/wda.log` `didFailToBootstrap` | подпись WDA истекла (7 дней) → `wda install`, затем `wda start` |
| `The test runner app is not installed` | удалить `ios/out/wda-bundle.txt` (кэш id) и повторить; id должен быть `com.facebook.WebDriverAgentRunner.xctrunner.PNHU7KJ7PZ` |
| Причина падения раннера | `python -m pymobiledevice3 syslog live` во время `developer dvt xcuitest <id>`, искать `WebDriverAgentRunner-Runner` `<ERROR>` и `AMFI` |

## Как устроено

**Связь с айфоном (iPhone 8, iOS 16.7.16).** На ПК нет Microsoft Store и winget, поэтому Apple Devices не ставится.
Служба usbmuxd поставлена из `AppleMobileDeviceSupport64.msi`, извлечённого 7-Zip из официального `iTunes64Setup.exe` (`D:\tools\itunes\x`).
pymobiledevice3 — `D:\tools\pmd3` (`$env:PYTHONPATH='D:\tools\pmd3'; python -m pymobiledevice3 …`; скрипт ставит `PYTHONUTF8=1`,
иначе русские названия приложений ломают JSON). Образ разработчика iOS 16 — `D:\tools\ddi\` (копия `~/drxwnify/ddi` с ноутбука).
Скриншот — `developer dvt screenshot`; открыть экран — `developer dvt launch --env DRX_SCREEN=<экран> com.drxwnify.ios.PNHU7KJ7PZ`
(экраны — `RootView.runDebugScreen`).

**WebDriverAgent** (Appium, нажатия/свайпы/дерево элементов через XCTest). `wda start` запускает раннер командой
`developer dvt xcuitest <id>` и проброс порта `usbmux forward 8100 8100` — оба фоном, без окон; HTTP API на `http://127.0.0.1:8100`
(`/status`, `/source?format=json`, `/session/<id>/wda/tap`, `/wda/dragfromtoforduration`, `/wda/keys`, `/wda/homescreen`).
Координаты WDA — точки (375x667), скрипт переводит из пикселей скриншота (масштаб 2).

**Переподпись раз в 7 дней — `wda install`** (нужен только ноутбук `slvt@192.168.0.140`, VM не нужна):
неподписанный `D:\tools\wda\WDA.ipa` → ноутбук → `scripts/wda-sign.sh` (plumesign, тот же Apple ID, что у Drxwnify) → `apps install` с ПК.
Тонкости подписи (всё уже в `wda-sign.sh`):
- plumesign подписывает `.xctest` в `PlugIns/` как приложение — с entitlements; iOS отказывает: «has entitlements but is not a main binary».
  Поэтому проход 1 — модуль временно в `Frameworks/WDAXCTest.framework` (подписывается без прав), проход 2 — обратно в `PlugIns/` и подпись раннера.
- Перед проходом 2 вернуть исходный `Info.plist` раннера, иначе id станет `…xctrunner.PNHU7KJ7PZ.PNHU7KJ7PZ` (второе приложение).

**Пересборка `WDA.ipa`** (только если потеряли `D:\tools\wda\WDA.ipa` или нужен новый Xcode; на VM, ~1,5 ч; SIMULATOR.md — как запустить VM):
1. `git clone --depth 1 https://github.com/appium/WebDriverAgent ~/WebDriverAgent` (версия 16.15.3, последняя до переезда в appium-ios).
2. Убрать каталог картинок (`actool` на VM виснет): `sed -i "" "/Assets.xcassets in Resources/d" WebDriverAgent.xcodeproj/project.pbxproj`.
3. `xcodebuild build-for-testing -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination generic/platform=iOS -derivedDataPath ~/wda-dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 RUN_CLANG_STATIC_ANALYZER=NO COMPILER_INDEX_STORE_ENABLE=NO`
   (без `RUN_CLANG_STATIC_ANALYZER=NO` каждый файл анализируется ~40 мин). В конце висит шаг `embed-runner-icon.sh` — когда
   `Debug-iphoneos/WebDriverAgentRunner-Runner.app` готов, xcodebuild можно убить.
4. Доложить в `Runner.app/Frameworks/` из `Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/`:
   `usr/lib/lib_TestingInterop.dylib` и `Library/Frameworks/_Testing_Foundation.framework` (без них раннер падает: `Library not loaded: @rpath/lib_TestingInterop.dylib`).
5. `Payload/WebDriverAgentRunner-Runner.app` → `zip -qr -y WDA.ipa Payload` → `D:\tools\wda\WDA.ipa`.

## Android
adb: `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`, пакет `com.drxwnify.app`; экран открывается
`am start -S -n com.drxwnify.app/com.metrolist.music.MainActivity --es meld_route <маршрут>` (маршруты — `ui/screens/NavigationBuilder.kt`).
Кнопки — `uiautomator dump` (кликабельные узлы). Телефон по проводу или беспроводная отладка (`adb connect <ip:порт>`, порт спросить).
