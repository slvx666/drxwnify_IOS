# Симулятор iOS 26 на VM — как снимать скриншоты

Цель: проверять ветку интерфейса iOS 26 (системный `TabView`, `tabViewBottomAccessory`, Liquid Glass) без iPhone на iOS 26.
Всё — с Windows, по SSH. Экран VM (http://127.0.0.1:8006) не нужен.

## Коротко: с нуля до скриншота

```
powershell -ExecutionPolicy Bypass -File D:\macos\start-docker.ps1          # VM (если не запущена)
powershell -ExecutionPolicy Bypass -File ios\scripts\sim.ps1 build          # синхронизация, Debug-сборка, загрузка симулятора, установка
powershell -ExecutionPolicy Bypass -File ios\scripts\sim.ps1 shot home      # → ios\out\sim\home.png
```

- `sim.ps1 shot <экран> [имя]` — перезапуск приложения с `DRX_SCREEN=<экран>` и скриншот. Экраны — `RootView.runDebugScreen`:
  `home`, `search`, `search:<запрос>`, `library`, `library:<фильтр>`, `player`, `album:<id>`, `artist:<id>`, `playlist:<id>`,
  `settings`, `integrations`, `together`, `stats`, `history`, `concerts`; `-` — без экрана.
- `sim.ps1 url "drxwnify://…" [имя]` — открыть ссылку в запущенном приложении и снять.
- `sim.ps1 snap <экран>` — снимок, который рисует само приложение (`DRX_SNAPSHOT`, Debug, `Support/DebugSnapshot.swift`), если экран симулятора чёрный.
- `sim.ps1 cmd "<команда>"` — команда на VM внутри GUI-сессии (`xcrun simctl …`).
- `sim.ps1 boot` — только загрузить симулятор (после перезапуска VM).
- Полный лог сборки — `ios\out\last-sim-build.log`. Сборка под симулятор не трогает Release-сборку для телефона (`build.ps1`).

## Что важно знать (иначе не заработает)

1. **simctl — только из GUI-сессии.** Если служба `CoreSimulatorService` впервые запущена из SSH, она живёт в домене
   `user/501`, и `simctl boot` падает: `Failed to start launchd_sim: could not bind to session` (ошибка 1102, код 60).
   Поэтому все команды simctl идут через `~/bin/drx-gui` (= `scripts/vm-gui.sh`): он запускает команду разовым LaunchAgent
   в `gui/501` и ждёт результата. `remote-sim.sh` сам убирает службу из `user/501`, если она там оказалась.
   Не запускать `xcrun simctl` напрямую по SSH до первой загрузки симулятора после перезапуска VM.
2. **GUI-сессия = автовход** пользователя `georgefloyd`, появляется через 1–3 мин после старта VM; проверка — `who` (строка `console`).
   Сразу после входа 5–10 мин VM сильно загружена (виджеты, iCloud, softwareupdated) — симулятор в это время может не успеть загрузиться.
3. **Ресурсы.** Нужно 10 ГБ памяти VM (`D:\macos\compose.yml`: `RAM_SIZE: "10G"`, `CPU_CORES: "8"`) и потолок WSL2 ≥ 13 ГБ
   (`%USERPROFILE%\.wslconfig`: `memory=13GB`, подкачка WSL на D: — на C: мало места). При 6 ГБ симулятор не грузится вообще.
4. **Кэш библиотек (x86_64).** На Intel-VM рантайм при первой загрузке собирает dyld shared cache; без него каждый из ~90
   процессов симулятора занимает 150–300 МБ, VM уходит в подкачку. Кэш собирается один раз:
   `sim.ps1 cmd "xcrun simctl runtime dyld_shared_cache update --all"` (долго). Если VM вдруг тормозит при загрузке
   симулятора и в `ps` виден `update_dyld_sim_shared_cache` — кэш не собран.
5. **Metal на VM нет** (QEMU, видеокарта VMware SVGA без драйвера). Симулятор рисует экран программно. Если `simctl io screenshot`
   отвечает `Timeout waiting for screen surfaces` — система внутри ещё грузится (ждать конца `bootstatus`) или отрисовки нет;
   тогда `sim.ps1 snap`.

## Как ставился рантайм (если VM пересоздадут)

`xcodebuild -downloadPlatform iOS` на этой VM виснет на «Preparing to download» (фоновая задача nsurlsessiond не стартует).
Обход — вручную, ~10 ГБ:
1. Ссылка и ключ — в каталоге MobileAsset, который скачивает тот же `xcodebuild -downloadPlatform` (его можно прервать):
   `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/com_apple_MobileAsset_iOSSimulatorRuntime.xml` —
   запись с `Architectures` = arm64 + x86_64: `__BaseURL` + `__RelativePath` (`.aar`), `ArchiveDecryptionKey`, `_Measurement-SHA256`.
2. `curl -L -C - -o rt.aar <URL>` → проверить SHA-256 (base64 от `shasum -a 256`).
3. `aea decrypt -i rt.aar -o dec.aar -key-value "base64:<ArchiveDecryptionKey>"`.
4. Внутри — поток pbzx: `python3 ~/simrt/pbzx.py dec.aar - | aa extract -d x` (скрипт на VM; формат: `pbzx`, размер куска,
   затем куски «размер, сжатый размер, xz-данные»; в конце падает на хвосте — это нормально).
5. `xcrun simctl runtime add x/AssetData/Restore/iOSSimulatorRuntime_Cryptex.dmg` → `iOS 26.5 (23F77) Ready`. Временные файлы удалить.

Установлено 12.11.2026: iOS 26.5 (23F77), симулятор `Drxwnify-26` (iPhone 17), UDID `14AA429C-565F-497B-AA3F-6F0EC64EB3CB`.

## После работы — выключить VM (пользователю нужна память)

- `docker compose -f D:\macos\compose.yml stop`. Если Docker CLI завис (бывает) — выключить macOS изнутри, без пароля:
  `ssh … georgefloyd@127.0.0.1 '~/bin/drx-gui "osascript -e \"tell application \\\"System Events\\\" to shut down\""'`;
  контейнер завершится сам. Проверка: `wsl -d docker-desktop -u root free -m` — занято ~1 ГБ, `vmmemWSL` ~2–3 ГБ.
- Перед Release-сборкой (`build.ps1`) симулятор выключать: `sim.ps1 cmd "xcrun simctl shutdown all"`.
