#!/bin/bash
# Ставит свежий Drxwnify .ipa на подключённый по кабелю iPhone.
# .ipa лежат в ~/drxwnify/ipa (туда их кладёт сборка с Windows). Берётся самый новый.
# Можно указать файл явно: ./Установить-Drxwnify.sh /путь/к/файлу.ipa

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
step() { echo; echo "${B}${G}== $1${N}"; }
warn() { echo "${Y}$1${N}"; }
die()  { echo; echo "${R}ОШИБКА: $1${N}"; echo; read -rp "Enter — закрыть. " _; exit 1; }
pause() { echo; read -rp "${B}Готово? Нажми Enter. ${N}" _; }

IPA_DIR="$HOME/drxwnify/ipa"

# --- 0. программа для подписи ---
# plumesign из Impactor. Sideloader (Dadoum) не годится: падает на входе в Apple ID (ноябрь 2026).
PS="$HOME/drxwnify/bin/plumesign"
[ -x "$PS" ] || die "не найден $PS"

# --- 1. файл ---
IPA="$1"
[ -z "$IPA" ] && IPA="$(ls -t "$IPA_DIR"/*.ipa 2>/dev/null | head -1)"
[ -f "$IPA" ] || die "нет .ipa в $IPA_DIR"

clear
echo "${B}Установка Drxwnify на iPhone${N}"
echo "Файл: $(basename "$IPA")  ($(date -r "$IPA" '+%d.%m.%Y %H:%M'))"

step "Шаг 1 из 4. Подготовь телефон"
cat <<EOF
  1. Подключи iPhone кабелем к этому ноутбуку.
  2. Разблокируй телефон (введи код) и оставь экран включённым.
  3. Если на телефоне появится «Доверять этому компьютеру?» —
     нажми «Доверять» и введи код телефона.
  4. Телефон должен быть в интернете (Wi-Fi или сотовая сеть).
EOF
pause

# --- 2. ждём телефон и сопряжение ---
step "Шаг 2 из 4. Ищу телефон"
for i in $(seq 1 60); do
  UDID="$(idevice_id -l 2>/dev/null | head -1)"
  [ -n "$UDID" ] && break
  [ "$i" = 1 ] && echo "  Телефона не видно. Проверь кабель и разблокируй экран…"
  sleep 2
done
[ -n "$UDID" ] || die "телефон не найден за 2 минуты. Попробуй другой кабель или порт; проверь: systemctl status usbmuxd"

if ! idevicepair -u "$UDID" validate >/dev/null 2>&1; then
  warn "  На телефоне нажми «Доверять» и введи код."
  for i in $(seq 1 60); do
    idevicepair -u "$UDID" pair >/dev/null 2>&1
    idevicepair -u "$UDID" validate >/dev/null 2>&1 && break
    sleep 2
  done
  idevicepair -u "$UDID" validate >/dev/null 2>&1 || die "телефон не подтвердил доверие. Отключи и подключи кабель, запусти скрипт ещё раз."
fi

NAME="$(ideviceinfo -u "$UDID" -k DeviceName 2>/dev/null)"
VER="$(ideviceinfo -u "$UDID" -k ProductVersion 2>/dev/null)"
echo "  Найден: ${B}$NAME${N}, iOS $VER"
MAJOR="${VER%%.*}"
if [ -n "$MAJOR" ] && [ "$MAJOR" -lt 14 ] 2>/dev/null; then
  die "нужна iOS 14 или новее, на телефоне $VER"
fi

# --- 3. подпись и установка ---
step "Шаг 3 из 4. Подписываю и ставлю"
if "$PS" account list 2>&1 | grep -q "No accounts found"; then
  cat <<EOF
  Нужен вход в Apple ID — один раз, потом он запоминается.
  На телефон брата ставится под тем же Apple ID, ему свой не нужен.
  ${Y}Переключи раскладку на английскую.${N} Пароль при вводе не виден.
  Код подтверждения придёт на устройство Apple.
EOF
  echo
  read -rp "  Apple ID (почта): " APPLE_ID
  [ -n "$APPLE_ID" ] || die "Apple ID не введён"
  RUST_LOG="error,plumesign=info" "$PS" account login -u "$APPLE_ID" || die "вход в Apple ID не прошёл. Текст выше покажи Claude."
  "$PS" account list 2>&1 | grep -q "No accounts found" && die "вход не сохранился. Текст выше покажи Claude."
fi
echo
echo "  ${Y}Сейчас появится список телефонов — выбери нужный стрелками и нажми Enter.${N}"
echo
# Без --udid: plumesign 2.7.2 с ним не находит телефон («Device ID … not found»), а из списка — находит.
RUST_LOG="error,plumesign=info" "$PS" sign --package "$IPA" --apple-id --register-and-install
RC=$?
[ $RC -eq 0 ] || die "установка не прошла (код $RC). Текст выше покажи Claude."

# --- 4. что сделать на телефоне после ---
step "Шаг 4 из 4. Разреши запуск на телефоне"
cat <<EOF
  Делается один раз на каждом телефоне:

  1. Настройки → Основные → VPN и управление устройством →
     выбери строку с Apple ID → «Доверять».
EOF
if [ -n "$MAJOR" ] && [ "$MAJOR" -ge 16 ] 2>/dev/null; then
  idevicedevmodectl reveal -u "$UDID" >/dev/null 2>&1
  cat <<EOF
  2. Настройки → Конфиденциальность и безопасность → в самом низу
     «Режим разработчика» → включить → телефон перезагрузится →
     после включения нажми «Включить» и введи код.
EOF
fi
cat <<EOF

  Потом открой Drxwnify на телефоне.
  ${Y}Бесплатная подпись живёт 7 дней: потом запусти этот скрипт ещё раз,
  данные приложения сохранятся.${N}
EOF
echo
read -rp "Enter — закрыть. " _
