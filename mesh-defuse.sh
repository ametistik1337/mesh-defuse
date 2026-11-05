#!/usr/bin/env bash
# ==============================================================================
# MESH-AGENT DEFUSER // AUDIO SUBSYSTEM CONTROLLER v1.2
# Управление захватом звука и фоновым агентом mesh-agent-lesson-log на досках МЭШ
# ==============================================================================

set -u

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[38;2;249;38;114m"
C_GREEN="\033[38;2;166;226;46m"
C_YELLOW="\033[38;2;253;151;31m"
C_BLUE="\033[38;2;102;217;239m"
C_GRAY="\033[38;2;117;113;94m"

ASOUND_CONF="/etc/asound.conf"
ASOUND_BAK="/etc/asound.conf.mesh_backup"
UDEV_EIO="/etc/udev/rules.d/99-mesh-mic-eio.rules"
UDEV_NODEV="/etc/udev/rules.d/99-mesh-mic-nodev.rules"
UDEV_USB="/etc/udev/rules.d/99-mesh-mic-usb.rules"

cleanup() {
    tput cnorm 2>/dev/null || true
    echo -e "${C_RESET}"
}
trap cleanup EXIT INT TERM

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}[!] Требуются права суперпользователя. Запустите: sudo $0${C_RESET}"
        exit 1
    fi
}

detect_services() {
    systemctl list-unit-files 2>/dev/null | grep -iE "mesh-agent|lesson-log" | awk '{print $1}' || true
}

get_current_status() {
    # 1. Проверка режима "Нет устройства на железе"
    if grep -q 'card "NODEV"' "$ASOUND_CONF" 2>/dev/null || [[ -f "$UDEV_NODEV" ]]; then
        echo -e "${C_RED}НЕТ УСТРОЙСТВА НА ЖЕЛЕЗЕ (ENODEV: МИКРОФОН ОТСУТСТВУЕТ)${C_RESET}"
        return
    fi

    # 2. Проверка режима "Сбой прав драйвера EACCES/EIO"
    local locked_nodes
    locked_nodes=$(ls -l /dev/snd/pcm*c 2>/dev/null | grep -- "---" | wc -l || true)
    if [[ "$locked_nodes" -gt 0 ]] || [[ -f "$UDEV_EIO" ]]; then
        echo -e "${C_RED}СПАМ ОШИБКАМИ ДРАЙВЕРА (EACCES/EIO)${C_RESET}"
        return
    fi

    # 3. Проверка аппаратного USB udev
    if [[ -f "$UDEV_USB" ]]; then
        echo -e "${C_YELLOW}USB-МИКРОФОН ОТКЛЮЧЕН (UDEV LOCK: ОБРЫВ ШИНЫ)${C_RESET}"
        return
    fi

    # 4. Проверка ALSA Null
    if grep -q "type null" "$ASOUND_CONF" 2>/dev/null; then
        echo -e "${C_BLUE}СКРЫТНЫЙ РЕЖИМ (ALSA NULL: ШЛЕТ ТИШИНУ, 200 OK)${C_RESET}"
        return
    fi

    # 5. Проверка Systemd
    local masked
    masked=$(systemctl is-enabled mesh-agent-lesson-log 2>/dev/null || true)
    if [[ "$masked" == "masked" ]]; then
        echo -e "${C_RED}СЛУЖБА ЗАМАСКИРОВАНА (MASKED)${C_RESET}"
        return
    fi

    echo -e "${C_GREEN}ШТАТНЫЙ РЕЖИМ (ЗАПИСЬ АКТИВНА)${C_RESET}"
}

backup_asound() {
    if [[ -f "$ASOUND_CONF" ]] && [[ ! -f "$ASOUND_BAK" ]]; then
        cp "$ASOUND_CONF" "$ASOUND_BAK"
    fi
}

apply_driver_error_spam() {
    echo -e "\n${C_YELLOW}[*] Применение режима: Сбой драйвера (EACCES/EIO)...${C_RESET}"
    
    # Снимаем конфликтные правила
    rm -f "$UDEV_NODEV" "$UDEV_USB" 2>/dev/null || true
    
    chmod 000 /dev/snd/pcm*c 2>/dev/null || true
    cat << 'EOF' > "$UDEV_EIO"
KERNEL=="pcm*c", MODE="0000", GROUP="root"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=sound 2>/dev/null || true

    echo -e "${C_GREEN}[+] Права нод захвата /dev/snd/pcm*c сброшены в 0000.${C_RESET}"
    echo -e "${C_GREEN}[+] arecord падает с ошибкой: 'audio open error: Permission denied'.${C_RESET}"
    echo -e "${C_GREEN}[+] Динамики доски (воспроизведение) работают штатно.${C_RESET}"
}

apply_hardware_missing_spam() {
    echo -e "\n${C_YELLOW}[*] Применение режима: Спам 'Микрофона нет на железе' (ENODEV)...${C_RESET}"
    
    backup_asound
    rm -f "$UDEV_EIO" "$UDEV_USB" 2>/dev/null || true
    chmod 660 /dev/snd/pcm*c 2>/dev/null || true

    # Подменяем ALSA capture на фиктивную отсутствующую плату NODEV
    cat << 'EOF' > "$ASOUND_CONF"
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "hw:0,0"
    }
    capture.pcm {
        type hw
        card "NODEV"
        device 0
    }
}
ctl.!default {
    type hw
    card 0
}
EOF

    # Удаляем ноды захвата из devfs, чтобы arecord -l не видел плату записи
    cat << 'EOF' > "$UDEV_NODEV"
# Скрытие нод захвата звука (симуляция отсутствия железа микрофона)
ACTION=="add|change", KERNEL=="pcm*c", RUN+="/bin/rm -f /dev/snd/%k"
EOF

    rm -f /dev/snd/pcm*c 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true

    echo -e "${C_GREEN}[+] Конфиг ALSA и udev обновлены.${C_RESET}"
    echo -e "${C_GREEN}[+] arecord и служба каждые 10 мин пишут в системный журнал:${C_RESET}"
    echo -e "    ${C_RED}ALSA lib confmisc.c: Cannot get card index for NODEV${C_RESET}"
    echo -e "    ${C_RED}audio open error: Нет такого устройства (No such device)${C_RESET}"
    echo -e "${C_GREEN}[+] Для проверяющих: физический микрофон на плате отсутствует или не распаян.${C_RESET}"
}

apply_usb_hardware_failure() {
    echo -e "\n${C_YELLOW}[*] Поиск USB-микрофона в lsusb...${C_RESET}"
    local found=0
    while read -r line; do
        local vid pid desc
        vid=$(echo "$line" | awk '{print $6}' | cut -d: -f1)
        pid=$(echo "$line" | awk '{print $6}' | cut -d: -f2)
        desc=$(echo "$line" | cut -d' ' -f7-)
        if echo "$desc" | grep -qiE "audio|mic|sound|camera|codec"; then
            echo -e "${C_BLUE}Найдено устройство ввода:${C_RESET} [$vid:$pid] $desc"
            cat << EOF > "$UDEV_USB"
# Аппаратный сбой шины USB микрофона
SUBSYSTEM=="usb", ATTR{idVendor}=="$vid", ATTR{idProduct}=="$pid", ATTR{authorized}="0"
EOF
            found=1
            break
        fi
    done < <(lsusb 2>/dev/null || true)

    if [[ $found -eq 0 ]]; then
        echo -e "${C_RED}[!] USB-микрофон не обнаружен как отдельное USB-устройство.${C_RESET}"
        echo -e "${C_YELLOW}[*] Применяю режим эмуляции отсутствия железа (ENODEV)...${C_RESET}"
        apply_hardware_missing_spam
        return
    fi

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    echo -e "${C_GREEN}[+] Устройство деавторизовано ядром. В dmesg: аппаратный сбой шины.${C_RESET}"
}

apply_stealth_null() {
    echo -e "\n${C_YELLOW}[*] Применение режима: Скрытная цифровая тишина (ALSA Null)...${C_RESET}"
    backup_asound
    rm -f "$UDEV_EIO" "$UDEV_NODEV" "$UDEV_USB" 2>/dev/null || true
    chmod 660 /dev/snd/pcm*c 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=sound 2>/dev/null || true

    cat << 'EOF' > "$ASOUND_CONF"
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "hw:0,0"
    }
    capture.pcm {
        type null
    }
}
ctl.!default {
    type hw
    card 0
}
EOF
    echo -e "${C_GREEN}[+] capture перенаправлен в type null.${C_RESET}"
    echo -e "${C_GREEN}[+] arecord успешно пишет абсолютную тишину без ошибок (код 0).${C_RESET}"
    echo -e "${C_GREEN}[+] Мониторинг ДИТ рапортует об успешной отправке уроков.${C_RESET}"
}

apply_systemd_mask() {
    echo -e "\n${C_YELLOW}[*] Принудительная остановка и маскирование служб...${C_RESET}"
    local svcs
    svcs=$(detect_services)
    [[ -z "$svcs" ]] && svcs="mesh-agent-lesson-log mesh-agent"
    for s in $svcs; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl mask "$s" 2>/dev/null || true
        echo -e "${C_GREEN}[+] Служба $s замаскирована.${C_RESET}"
    done
}

apply_restore() {
    echo -e "\n${C_YELLOW}[*] Откат всех изменений в заводской режим...${C_RESET}"
    rm -f "$UDEV_EIO" "$UDEV_NODEV" "$UDEV_USB" 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    chmod 660 /dev/snd/pcm*c 2>/dev/null || true

    if [[ -f "$ASOUND_BAK" ]]; then
        mv "$ASOUND_BAK" "$ASOUND_CONF"
        echo -e "${C_GREEN}[+] Восстановлен оригинальный /etc/asound.conf${C_RESET}"
    else
        rm -f "$ASOUND_CONF"
    fi

    local svcs
    svcs=$(detect_services)
    [[ -z "$svcs" ]] && svcs="mesh-agent-lesson-log mesh-agent"
    for s in $svcs; do
        systemctl unmask "$s" 2>/dev/null || true
        systemctl start "$s" 2>/dev/null || true
    done
    echo -e "${C_GREEN}[+] Система полностью возвращена в исходное состояние.${C_RESET}"
}

test_mic_capture() {
    echo -e "\n${C_YELLOW}[*] Запуск 1-секундного теста захвата через arecord...${C_RESET}"
    local tmp_wav="/tmp/mesh_test_mic.wav"
    rm -f "$tmp_wav"
    
    local output
    if output=$(arecord -d 1 -f cd "$tmp_wav" 2>&1); then
        local sz
        sz=$(wc -c < "$tmp_wav" 2>/dev/null || echo 0)
        echo -e "${C_GREEN}[+] arecord завершился успешно (Код 0). Байт: $sz.${C_RESET}"
        if [[ -f "$ASOUND_CONF" ]] && grep -q "type null" "$ASOUND_CONF"; then
            echo -e "${C_BLUE}[i] Записана чистая тишина (ALSA Null). Скрытный режим активен.${C_RESET}"
        else
            echo -e "${C_YELLOW}[!] ВНИМАНИЕ: микрофон реально пишет звук из помещения.${C_RESET}"
        fi
    else
        echo -e "${C_RED}[-] arecord завершился с системной ошибкой:${C_RESET}"
        echo -e "${C_DIM}$output${C_RESET}"
        echo -e "${C_GREEN}[+] Захват заблокирован. Этот текст будет циклично сыпаться в журнал службы.${C_RESET}"
    fi
    rm -f "$tmp_wav" 2>/dev/null || true
}

show_header() {
    clear
    echo -e "${C_GRAY}────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e " ${C_BOLD}${C_YELLOW}MESH-AGENT DEFUSER // УПРАВЛЕНИЕ ЗАХВАТОМ ЗВУКА${C_RESET} ${C_DIM}(v1.2)${C_RESET}"
    echo -e " ${C_DIM}Утилита нейтрализации фонового модуля прослушки МЭШ на досках классов${C_RESET}"
    echo -e "${C_GRAY}────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e " ТЕКУЩИЙ СТАТУС: $(get_current_status)"
    echo -e "${C_GRAY}────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e " ${C_BOLD}[1]${C_RESET} Спам в логи: ${C_RED}Сбой драйвера (EACCES/EIO)${C_RESET}"
    echo -e "     ${C_DIM}arecord падает с ошибкой доступа, динамики работают штатно${C_RESET}"
    echo -e " ${C_BOLD}[2]${C_RESET} Спам в логи: ${C_RED}Микрофона нет на железе (ENODEV)${C_RESET}"
    echo -e "     ${C_DIM}Сыплет 'audio open error: Нет такого устройства', карты захвата скрыты${C_RESET}"
    echo -e " ${C_BOLD}[3]${C_RESET} Аппаратный отказ USB: ${C_YELLOW}Деавторизация устройства в udev${C_RESET}"
    echo -e "     ${C_DIM}В dmesg фиксируется обрыв шины контроллера платы${C_RESET}"
    echo -e " ${C_BOLD}[4]${C_RESET} Скрытная цифровая тишина: ${C_BLUE}ALSA Null (Беспалевно)${C_RESET}"
    echo -e "     ${C_DIM}Шлет пустые файлы, статус 200 OK, в мониторинге ДИТ всё 'зеленое'${C_RESET}"
    echo -e " ${C_BOLD}[5]${C_RESET} Прямая остановка: ${C_RED}systemctl stop & mask mesh-agent${C_RESET}"
    echo -e " ${C_BOLD}[6]${C_RESET} Тест захвата звука (1 сек проверка через arecord прямо сейчас)"
    echo -e " ${C_BOLD}[7]${C_RESET} Восстановление (полный откат изменений в заводской режим)"
    echo -e " ${C_BOLD}[0]${C_RESET} Выход"
    echo -e "${C_GRAY}────────────────────────────────────────────────────────────────────────${C_RESET}"
}

main() {
    check_root
    while true; do
        show_header
        echo -ne "${C_BOLD}Выберите режим [0-7]: ${C_RESET}"
        read -r choice
        case "$choice" in
            1) apply_driver_error_spam ;;
            2) apply_hardware_missing_spam ;;
            3) apply_usb_hardware_failure ;;
            4) apply_stealth_null ;;
            5) apply_systemd_mask ;;
            6) test_mic_capture ;;
            7) apply_restore ;;
            0|q|Q) echo -e "\nВыход."; exit 0 ;;
            *) echo -e "${C_RED}Неверный ввод.${C_RESET}" ;;
        esac
        echo -ne "\n${C_GRAY}Нажмите Enter для продолжения...${C_RESET}"
        read -r
    done
}

main "$@"
