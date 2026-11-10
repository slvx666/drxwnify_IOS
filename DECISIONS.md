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
