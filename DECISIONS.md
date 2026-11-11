# Решения по ходу работы

Сюда пишется всё, что не было задано в `IOS_BUILD_PROMPT.md` и выбрано по месту.

## Этап 0

- **Git.** Папка `Drownify/` не репозиторий (репозиторий Android лежит в `android/`), поэтому `ios/` — отдельный репозиторий.
  Ветка `ios`, remote `origin` = `https://github.com/slvx666/drxwnify_IOS` (без токена в URL). Пуш только по просьбе.
- **Сборка через `-target`, а не `-scheme`.** На VM стоит iOS SDK 26.5, но нет компонента «iOS platform» (≈8 ГБ),
  и `-scheme … -destination 'generic/platform=iOS'` падает с «iOS 26.5 is not installed». `-target Drxwnify -sdk iphoneos`
  собирает без него. Продукты: `~/drxwnify-dd/Build/Products/Release-iphoneos/`.
  Если позже понадобится схема (тесты), ставить компонент: `xcodebuild -downloadPlatform iOS`.
- **xcodegen 2.46.0** — бинарник с релизов GitHub в `~/tools/xcodegen`, ссылка `~/bin/xcodegen` (Homebrew на VM нет).
- **Версия iOS-приложения** начинается с `0.1.0` (`MARKETING_VERSION` в `project.yml`), с версией Android не связана.
- **Только iPhone** (`TARGETED_DEVICE_FAMILY = 1`), только портрет.
- **Info.plist генерирует xcodegen** в `Generated/Info.plist` (в git не идёт); все ключи — в `project.yml`.
- **Мини-плеер.** iOS 26+: `tabViewBottomAccessory` (системное стекло). iOS 14–25: панель с `UIBlurEffect` поверх `TabView`,
  поднятая на 49 pt над панелью вкладок.
- **Строки.** `L("ключ")`, ключи совпадают с именами строк Android. Чисто iOS-ключи лежат в конце `Localizable.strings`.
- **`build.ps1` сохранён в UTF-8 с BOM**: Windows PowerShell 5.1 иначе портит кириллицу.
- **Плеер.** Один `AVQueuePlayer`: в нём текущий трек и заранее найденный следующий (поиск звука следующего начинается
  через 1,5 с после старта текущего). Очередь приложения — массив `Track`; случайный порядок — отдельная перестановка
  индексов, сама очередь не тасуется (как shuffle в ExoPlayer). Перестановка трека вручную пересобирает случайный порядок.
- **Идентификатор трека каталога** в очереди и в `song.db` — `mfb:<id Spotify>`, как `FallbackIds` на Android.
- **Очередь между запусками** хранится в `Application Support/persistent_queue.json` (на Android — сериализованные файлы
  Java; формат не переносится, в резервную копию не входит).
- **Проверка совпадения звука** — `FuzzyTrackMatch` из CRITICAL §2.3. В коде Android SoundCloud идёт через другой
  сопоставитель (`SpotifyMapper`/`ProviderGate`); по правилу «spec главнее» взят вариант из спецификации, поверх него
  оставлены правила SoundCloud: официальная загрузка раньше перезалива, перезалив ≤ 0,85, отсев правок (flip/edit/…).
- **SoundCloud HLS** отдаётся в `AVPlayer` как есть (на Android склеивается своим `HlsConcatDataSource`). Opus/Ogg пропускается.
- **Полный плеер и очередь — системные листы** (`.sheet`): тянутся вниз, как нижний лист на Android.
  Замок очереди: открыт — включён режим правки списка (ручки перетаскивания и удаление), закрыт — только тап по треку.
- **Ссылка «Поделиться» из плеера** пока `open.spotify.com/track/<id>`; формат ссылок приложения (CRITICAL §4.4) — этап 5.
- **Установка на телефон** — через ноут Arch и `plumesign`, скрипт `scripts/install-drxwnify.sh` (лежит на рабочем столе ноута).
  Sideloader (Dadoum) не работает: падает на входе в Apple ID.
- **VK.** Прямой вход (`Resolver/Providers/VkDirectAuth.swift`) использует id и секрет официального Android-клиента VK —
  те же константы приложения, что зашиты в открытом коде Android (`VkDirectAuth.kt`); это не пользовательские данные.
  Логин и пароль не сохраняются, токен лежит в Keychain (`vkAccessToken`). Общий демо-аккаунт VK с Android не перенесён.
  HLS VK (`index.m3u8`) переписывается в адрес MP3, как на Android; если не вышло — отдаётся в `AVPlayer` как HLS.
- **Сердечко в плеере** стоит в ряду с названием, слева от «Поделиться» (на Android лайк — в меню и жестах). Проверить по Android-телефону и при надобности переставить.
- **«Перейти к альбому / артисту»** из плеера и меню трека открывает экран листом поверх всего (`AppEnvironment.linkTarget`) —
  тот же механизм, что открывает ссылки `drxwnify.pages.dev`, `drxwnify://`, `open.spotify.com`.
- **Лайки:** `song.liked` в базе + мутации Spotify `addToLibrary`/`removeFromLibrary` при включённом `spotifySyncLikes` (по умолчанию включено).
