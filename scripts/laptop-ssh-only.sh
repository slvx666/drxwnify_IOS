#!/bin/bash
# Ноут как «тихий сервер» для SSH и установки на iPhone по USB: крышку можно закрыть — сон не наступит,
# экран гаснет, процессор в режиме экономии, Bluetooth выключен. Всё временно: до перезагрузки или `off`.
#
#   sudo ~/drxwnify/ssh-only.sh on     — включить
#   sudo ~/drxwnify/ssh-only.sh off    — вернуть как было
#   ~/drxwnify/ssh-only.sh status      — что сейчас включено
set -u
STATE=/run/drx-ssh-only      # /run очищается при перезагрузке — состояние тоже временное
UNIT=drx-ssh-only-inhibit

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Нужен sudo: sudo $0 $1"; exit 1; }; }

on() {
    need_root on
    mkdir -p "$STATE"
    # 1. Крышка и простой не усыпляют ноут, пока работает этот «запрет» (снимается off или перезагрузкой).
    systemctl stop "$UNIT" 2>/dev/null
    systemd-run --unit="$UNIT" --quiet \
        systemd-inhibit --what=handle-lid-switch:sleep:idle --who=drxwnify --why="SSH-only" --mode=block sleep infinity
    # 2. Экран: подсветка в 0 (старое значение запоминается) и консоль гаснет.
    for b in /sys/class/backlight/*; do
        [ -e "$b/brightness" ] || continue
        cat "$b/brightness" > "$STATE/$(basename "$b").brightness"
        echo 0 > "$b/brightness"
    done
    for t in /dev/tty1 /dev/tty2; do TERM=linux setterm --blank force --powerdown 1 < "$t" > "$t" 2>/dev/null; done
    # 3. Процессор: режим экономии, без турбо.
    if command -v powerprofilesctl >/dev/null; then
        powerprofilesctl get > "$STATE/profile" 2>/dev/null
        powerprofilesctl set power-saver 2>/dev/null
    fi
    if [ -e /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        cat /sys/devices/system/cpu/intel_pstate/no_turbo > "$STATE/no_turbo"; echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
    elif [ -e /sys/devices/system/cpu/cpufreq/boost ]; then
        cat /sys/devices/system/cpu/cpufreq/boost > "$STATE/boost"; echo 0 > /sys/devices/system/cpu/cpufreq/boost
    fi
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$g" ] || continue
        [ -e "$STATE/governor" ] || cat "$g" > "$STATE/governor"
        echo powersave > "$g" 2>/dev/null
    done
    # 4. Bluetooth не нужен. Wi-Fi и USB остаются (SSH и iPhone по кабелю).
    rfkill list bluetooth 2>/dev/null | grep -q "Soft blocked: yes" || { touch "$STATE/bt_was_on"; rfkill block bluetooth 2>/dev/null; }
    echo "Готово: можно закрыть крышку. SSH и USB работают. Вернуть: sudo $0 off (или перезагрузка)."
}

off() {
    need_root off
    systemctl stop "$UNIT" 2>/dev/null
    for f in "$STATE"/*.brightness; do
        [ -e "$f" ] || continue
        n=$(basename "$f" .brightness); cat "$f" > "/sys/class/backlight/$n/brightness"
    done
    for t in /dev/tty1 /dev/tty2; do TERM=linux setterm --blank poke < "$t" > "$t" 2>/dev/null; done
    [ -e "$STATE/profile" ] && powerprofilesctl set "$(cat "$STATE/profile")" 2>/dev/null
    [ -e "$STATE/no_turbo" ] && cat "$STATE/no_turbo" > /sys/devices/system/cpu/intel_pstate/no_turbo
    [ -e "$STATE/boost" ] && cat "$STATE/boost" > /sys/devices/system/cpu/cpufreq/boost
    if [ -e "$STATE/governor" ]; then
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do cat "$STATE/governor" > "$g" 2>/dev/null; done
    fi
    [ -e "$STATE/bt_was_on" ] && rfkill unblock bluetooth 2>/dev/null
    rm -rf "$STATE"
    echo "Вернул как было."
}

status() {
    if systemctl is-active --quiet "$UNIT"; then echo "SSH-only: включено (крышка не усыпляет)"; else echo "SSH-only: выключено"; fi
    command -v powerprofilesctl >/dev/null && echo "Профиль питания: $(powerprofilesctl get 2>/dev/null)"
    for b in /sys/class/backlight/*; do [ -e "$b/brightness" ] && echo "Подсветка $(basename "$b"): $(cat "$b/brightness")"; done
}

case "${1:-}" in
    on) on ;;
    off) off ;;
    status) status ;;
    *) echo "Использование: sudo $0 on | sudo $0 off | $0 status"; exit 1 ;;
esac
