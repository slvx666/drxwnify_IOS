# Прогресс iOS-порта

Точка продолжения. Задание: `../IOS_BUILD_PROMPT.md`. Решения: `DECISIONS.md`. Проблемы: `KNOWN_ISSUES.md`.

Сборка: `powershell -ExecutionPolicy Bypass -File ios\scripts\build.ps1` → `ios\out\Drxwnify-<версия>.ipa`.
Проверки формата на VM: `powershell -ExecutionPolicy Bypass -File ios\scripts\test.ps1 -Sync`.

## Этапы

| Этап | Что | Статус |
|---|---|---|
| 0 | Конвейер, каркас, 4 вкладки, мини-плеер | готово, закоммичено (`Drxwnify-0.1.0.ipa`), ждёт проверки на телефоне |
| 1 | Хранилище, настройки, импорт бэкапа | готово (`Drxwnify-0.2.0.ipa`), ждёт проверки на телефоне |
| 2 | Spotify | начат: написана часть кода, не собиралось |
| 3–14 | см. задание | не начаты |

## С чего продолжить (сессия оборвалась по лимиту)

1. Сборка этапа 1 была запущена и шла (первая компиляция GRDB на VM очень долгая), результат не проверен.
   Запустить `build.ps1` заново и чинить ошибки. Сборку запускать только из PowerShell
   (в Git Bash подхватывается чужой `ssh`; скрипты уже закреплены на `System32\OpenSSH`).
2. **До сборки** добавить в `project.yml` пакет Nuke (`https://github.com/kean/Nuke`, `exactVersion: 12.8.0`, product `Nuke`):
   `UI/Common/ArtworkView.swift` уже его импортирует. Nuke 13+ требует iOS 15 — не брать.
3. После зелёной сборки: коммит «Этап 1», затем доделать этап 2.

## Этап 0

| ID | Статус | Примечание |
|---|---|---|
| UI-001 | частично | 4 вкладки; «узкая панель» позже |
| UI-051 | заглушка | мини-плеер без звука |

Проверить на телефоне: `.ipa` ставится и запускается; 4 вкладки переключаются; мини-плеер виден, ▶ меняется на ⏸.

## Этап 1 (написано, не собрано)

| ID | Статус | Где |
|---|---|---|
| SYS-200 | написано | `Storage/Backup/BackupManager.swift` (`create`) |
| SYS-201 | написано | `BackupManager.restore`, экран `UI/Settings/BackupScreen.swift` (Главная → шестерёнка) |
| SET-9xx | написано | `Storage/Prefs/*`: 314 ключей из `PreferenceKeys.kt` (`scripts/gen_prefkeys.py`), секреты в Keychain |
| схема v40 | написано | `Resources/Schema/song_v40.sql`, `Storage/DB/AppDatabase.swift` (GRDB 7.12.0) |

Проверено на VM (`test.ps1`, 29 проверок прошли): чтение zip с data descriptor, protobuf DataStore, XML SharedPreferences,
запись zip, читаемая потоково (как Java `ZipInputStream`). GRDB-часть и экран не проверены.

Локализация: `scripts/gen_strings.py` → `Localizable.strings` (2298 ключей из Android), свои строки — `IOS.strings`.

Проверить на телефоне после сборки: Главная → шестерёнка → «Резервное копирование» → восстановить `.backup` с Android →
в сводке видны числа треков/плейлистов и аккаунты; «Создать резервную копию» открывает «Поделиться».

## Этап 2 (начат)

Написано, не собиралось: `Spotify/SpotifyModels.swift`, `SpotifyAuth.swift` (TOTP, токен по `sp_dc`), `SpotifyHashes.swift`,
`SpotifyTokenManager.swift`, `SpotifyAPI.swift` (GQL + REST: профиль, медиатека, плейлист, лайки, альбом, артист),
`Support/HTTP.swift`, `Support/JSON.swift`, `UI/Common/ArtworkView.swift`, `UI/Common/Loader.swift`.

Осталось: подключить в `AppEnvironment` (tokens, hashes, api; `hashes.sync()` при запуске), экран входа `WKWebView`
(cookie `sp_dc`/`sp_key` с `open.spotify.com`, мобильный Safari UA, после входа ключи как в `SpotifyLoginScreen.kt:786-815`),
экран библиотеки с фильтрами, экраны плейлиста, лайков, альбома, артиста, папки; вход/выход в настройках.
