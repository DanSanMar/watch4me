#!/usr/bin/env bash
# watch4me — cabecera animada
#
# La técnica de cambio de color por segundo y el redibujado con \e[H/\e[K
# deriva de dash4me (GPLv3): https://github.com/DanSanMar/dash4me
# Copyright (C) DanSanMar — adaptada para watch4me.
#
# Licencia: GPLv3

UI_COLOR=0
UI_ANIM=0
UI_UTF8=0
UI_TTY=0
UI_PROGRESS=0
UI_PROGRESS_ACTIVE=0
UI_PROGRESS_LAST=''
UI_QUIET=0
UI_WIDTH=100
UI_COMPACT=0
UI_HEADER_OPEN=0
UI_RESTORED=0
UI_CURRENT=''
UI_ELAPSED=0
BG_PID=''

# Se llama tras parsear argumentos.
ui_init() {
    if [ -t 1 ]; then
        UI_TTY=1
        UI_PROGRESS=1
    fi

    if [ "${NO_COLOR_FLAG:-0}" -eq 0 ] \
        && [ -z "${NO_COLOR:-}" ] \
        && [ "$UI_TTY" -eq 1 ] \
        && [ "${TERM:-dumb}" != "dumb" ]; then
        UI_COLOR=1
    fi

    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*) UI_UTF8=1 ;;
    esac

    UI_WIDTH=$(term_width)
    [ "$UI_WIDTH" -lt 70 ] && UI_COMPACT=1

    # La animación ya no depende de un ancho mínimo de 80: en terminales
    # estrechas se usa una cabecera compacta de una sola línea.
    if [ "$UI_COLOR" -eq 1 ] \
        && [ "${NO_ANIM_FLAG:-0}" -eq 0 ] \
        && [ "$UI_TTY" -eq 1 ] \
        && [ "$UI_WIDTH" -ge 36 ]; then
        UI_ANIM=1
    fi

    if [ "$UI_COLOR" -eq 1 ]; then
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'
        C_DIM=$'\e[90m'
        C_RED=$'\e[31m'
        C_RED_B=$'\e[91m'
        C_GREEN=$'\e[32m'
        C_GREEN_B=$'\e[92m'
        C_YELLOW=$'\e[33m'
        C_YELLOW_B=$'\e[93m'
        C_BLUE=$'\e[34m'
        C_BLUE_B=$'\e[94m'
        C_CYAN=$'\e[36m'
        C_CYAN_B=$'\e[96m'
        C_WHITE=$'\e[97m'
        C_MAGENTA_B=$'\e[95m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_RED_B='' C_GREEN='' C_GREEN_B=''
        C_YELLOW='' C_YELLOW_B='' C_BLUE='' C_BLUE_B='' C_CYAN='' C_CYAN_B=''
        C_WHITE='' C_MAGENTA_B=''
    fi

    PALETA=(
        "$C_RED" "$C_BLUE_B" "$C_GREEN_B" "$C_YELLOW_B" "$C_CYAN_B"
        "$C_MAGENTA_B" "$C_RED_B" "$C_GREEN" "$C_YELLOW" "$C_CYAN"
    )
}

# Color de la paleta según el segundo actual + desfase (0-9).
ui_palette() {
    local off=${1:-0}
    local s=$(( 10#$(date +%S) + off ))
    printf '%s' "${PALETA[$(( s % 10 ))]}"
}

ui_icon() {
    if [ "$UI_UTF8" -eq 1 ]; then
        printf '%s' "${1:-}"
    else
        printf '%s' "${2:-}"
    fi
}

ui_line1() {
    local off=${1:-0}
    local c1 c2 c3 icon logo subtitle ver
    c1=$(ui_palette "$off")
    c2=$(ui_palette "$(( off + 5 ))")
    c3=$(ui_palette "$(( off + 2 ))")
    if [ "$UI_UTF8" -eq 1 ]; then
        icon='🛡'
        subtitle='AUDITORÍA DE SEGURIDAD'
    else
        icon='[watch4me]'
        subtitle='AUDITORIA DE SEGURIDAD'
    fi
    logo='WATCH4ME'
    ver="v${VERSION:-0.3.0}"

    local line=""
    line+="${C_BLUE_B}---${C_RESET} "
    line+="${C_BLUE_B}${icon}${C_RESET} "
    line+="${c1}${C_BOLD}${logo}${C_RESET} "
    if [ "$UI_COMPACT" -eq 0 ]; then
        line+="${C_DIM}|${C_RESET} "
        line+="${c2}${subtitle}${C_RESET} "
    fi
    line+="${C_DIM}|${C_RESET} "
    line+="${c3}${ver}${C_RESET} "
    line+="${C_BLUE_B}---${C_RESET}"
    printf '%s' "$line"
}

ui_line1_static() {
    local icon logo subtitle ver
    if [ "$UI_UTF8" -eq 1 ]; then
        icon='🛡'
        subtitle='AUDITORÍA DE SEGURIDAD'
    else
        icon='[watch4me]'
        subtitle='AUDITORIA DE SEGURIDAD'
    fi
    logo='WATCH4ME'
    ver="v${VERSION:-0.3.0}"

    local line=""
    line+="${C_BLUE_B}---${C_RESET} "
    line+="${C_BLUE_B}${icon}${C_RESET} "
    line+="${C_CYAN_B}${C_BOLD}${logo}${C_RESET} "
    if [ "$UI_COMPACT" -eq 0 ]; then
        line+="${C_DIM}|${C_RESET} "
        line+="${C_CYAN}${subtitle}${C_RESET} "
    fi
    line+="${C_DIM}|${C_RESET} "
    line+="${C_MAGENTA_B}${ver}${C_RESET} "
    line+="${C_BLUE_B}---${C_RESET}"
    printf '%s' "$line"
}

# Barra de progreso en texto plano (sin ANSI): bloques si hay UTF-8.
ui_bar() {
    local done_n=${1:-0} total=${2:-1} width=${3:-20}
    local filled i out=''
    [ "$total" -gt 0 ] || total=1
    filled=$(( done_n * width / total ))
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ] && filled=0
    for (( i = 0; i < width; i++ )); do
        if [ "$i" -lt "$filled" ]; then
            if [ "$UI_UTF8" -eq 1 ]; then out+='█'; else out+='#'; fi
        else
            if [ "$UI_UTF8" -eq 1 ]; then out+='░'; else out+='-'; fi
        fi
    done
    printf '%s' "$out"
}

ui_line2_run() {
    local done_n=${2:-0} total=${3:-0}
    [ "$total" -gt 0 ] || total=1
    local elapsed=${UI_ELAPSED:-0}
    local current=${UI_CURRENT:-}
    local line=""

    if [ "$UI_COMPACT" -eq 1 ]; then
        line+=" ${C_DIM}Analizando${C_RESET} "
        line+="${C_YELLOW_B}${done_n}/${total}${C_RESET}"
        line+=" ${C_DIM}·${C_RESET} ${elapsed}s"
        [ -n "$current" ] && line+=" ${C_DIM}·${C_RESET} ${C_BOLD}${current}${C_RESET}"
        printf '%s' "$line"
        return
    fi

    line+=" ${C_DIM}Analizando${C_RESET} "
    line+="${C_YELLOW_B}[$(ui_bar "$done_n" "$total" 20)]${C_RESET}"
    line+=" ${done_n}/${total}"
    line+=" ${C_DIM}·${C_RESET} ${elapsed}s"
    [ -n "$current" ] && line+=" ${C_DIM}·${C_RESET} ${C_BOLD}${current}${C_RESET}"
    printf '%s' "$line"
}

ui_line2_static() {
    local root_txt
    if [ "$(id -u)" -eq 0 ]; then root_txt='sí'; else root_txt='no'; fi
    local line=""
    line+=" ${C_DIM}perfil:${C_RESET} ${C_WHITE}${PROFILE:-full}${C_RESET}"
    if [ "$UI_COMPACT" -eq 0 ] || [ "${UI_WIDTH:-100}" -ge 50 ]; then
        line+=" ${C_DIM}·${C_RESET}"
        line+=" ${C_DIM}host:${C_RESET} ${C_WHITE}${HOSTNAME_SHORT:-localhost}${C_RESET}"
    fi
    if [ "$UI_COMPACT" -eq 0 ]; then
        line+=" ${C_DIM}·${C_RESET}"
        line+=" ${C_DIM}distro:${C_RESET} ${C_WHITE}${DISTRO_FAMILY:-unknown}${C_RESET}"
    fi
    line+=" ${C_DIM}·${C_RESET}"
    line+=" ${C_DIM}root:${C_RESET} ${C_WHITE}${root_txt}${C_RESET}"
    printf '%s' "$line"
}

# Progreso de una sola línea para terminales sin animación de cabecera
# (--no-anim, NO_COLOR, ancho reducido o terminal sin color).
ui_progress_frame() {
    local done_n=${1:-0} total=${2:-1} elapsed=${3:-0}
    [ "$total" -gt 0 ] || total=1
    local line len pad=''

    if [ "$UI_COMPACT" -eq 1 ]; then
        line=" Analizando ${done_n}/${total} · ${elapsed}s"
    else
        line=" Analizando [$(ui_bar "$done_n" "$total" 20)] ${done_n}/${total} · ${elapsed}s"
    fi
    [ -n "${UI_CURRENT:-}" ] && line+=" · ${UI_CURRENT}"

    len=${#line}
    if [ "${#UI_PROGRESS_LAST}" -gt "$len" ]; then
        printf -v pad '%*s' $(( ${#UI_PROGRESS_LAST} - len )) ''
    fi
    printf '\r%s%s' "$line" "$pad"
    UI_PROGRESS_LAST=$line
    UI_PROGRESS_ACTIVE=1
}

ui_progress_close() {
    [ "${UI_PROGRESS_ACTIVE:-0}" -eq 1 ] || return 0
    printf '\r%*s\r\n' "${#UI_PROGRESS_LAST}" ''
    UI_PROGRESS_ACTIVE=0
    UI_PROGRESS_LAST=''
}

# Reserva dos líneas y coloca el cursor al inicio de la primera.
ui_header_open() {
    [ "$UI_ANIM" -eq 1 ] || return 0
    [ "$UI_HEADER_OPEN" -eq 1 ] && return 0
    tput civis 2>/dev/null || printf '\e[?25l'
    printf '\n\n'
    UI_HEADER_OPEN=1
}

# Redibuja las dos líneas de cabecera sin tocar el scrollback.
ui_frame() {
    [ "$UI_ANIM" -eq 1 ] || return 0
    [ "$UI_HEADER_OPEN" -eq 1 ] || ui_header_open
    local off=${1:-0} done_n=${2:-0} total=${3:-0}
    printf '\r\e[1A'
    printf '\e[K%s\n' "$(ui_line1 "$off")"
    printf '\e[K%s' "$(ui_line2_run "$off" "$done_n" "$total")"
}

ui_header_close() {
    if [ "$UI_HEADER_OPEN" -eq 1 ]; then
        printf '\r\e[1A'
        printf '\e[K%s\n' "$(ui_line1_static)"
        printf '\e[K%s' "$(ui_line2_static)"
        printf '\n'
        UI_HEADER_OPEN=0
    fi
    tput cnorm 2>/dev/null || printf '\e[?25h'
    UI_ANIM=0
}

# Cabecera plana para cuando no hay animación.
ui_header_plain() {
    printf '%s\n%s\n\n' "$(ui_line1_static)" "$(ui_line2_static)"
}

ui_restore() {
    [ "$UI_RESTORED" -eq 1 ] && return 0
    UI_RESTORED=1
    if [ -n "${BG_PID:-}" ]; then
        kill "$BG_PID" 2>/dev/null || true
        BG_PID=''
    fi
    if [ "${UI_PROGRESS_ACTIVE:-0}" -eq 1 ]; then
        printf '\r%*s\r\n' "${#UI_PROGRESS_LAST}" '' 2>/dev/null || true
        UI_PROGRESS_ACTIVE=0
    fi
    if [ "$UI_ANIM" -eq 1 ]; then
        tput cnorm 2>/dev/null || printf '\e[?25h'
        printf '\n'
        UI_ANIM=0
    fi
    if [ -n "${RUN_DIR:-}" ] && [ -d "${RUN_DIR:-}" ]; then
        rm -rf -- "$RUN_DIR" 2>/dev/null || true
    fi
}

ui_trap_install() {
    trap 'ui_restore' EXIT
    trap 'ui_restore; exit 130' INT
    trap 'ui_restore; exit 143' TERM
    trap 'ui_restore; exit 129' HUP
}
