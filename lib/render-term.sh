#!/usr/bin/env bash
# watch4me — renderizador de terminal
# Licencia: GPLv3

_term_wrap() {
    local text=$1 indent=$2 width=$3
    local avail=$(( width - indent ))
    [ "$avail" -lt 12 ] && avail=12
    printf '%s\n' "$text" | fold -s -w "$avail" | while IFS= read -r line; do
        printf '%*s%s\n' "$indent" '' "$line"
    done
}

# Línea horizontal ASCII o Unicode según el terminal.
_term_rule() {
    local n=${1:-30} ch='-'
    [ "$UI_UTF8" -eq 1 ] && ch='─'
    while [ "$n" -gt 0 ]; do
        printf '%s' "$ch"
        n=$(( n - 1 ))
    done
}

# Cabecera de sección que no desborda en terminales estrechas.
_term_section() {
    local title=$1 max=${2:-40} width=${3:-100}
    local fill=$(( width - ${#title} - 4 ))
    [ "$fill" -gt "$max" ] && fill=$max
    [ "$fill" -lt 2 ] && fill=2
    printf '\n%s── %s%s %s%s%s\n' \
        "$C_BOLD$C_CYAN_B" "$title" "$C_RESET" "$C_DIM" "$(_term_rule "$fill")" "$C_RESET"
}

_term_sev_badge() {
    local sev=$1 label color pad
    case "$sev" in
        critical) label='CRÍTICA'; color=$C_RED_B ;;
        high)     label='ALTA';    color=$C_YELLOW_B ;;
        medium)   label='MEDIA';   color=$C_YELLOW ;;
        low)      label='BAJA';    color=$C_CYAN ;;
        *)        label='INFO';    color=$C_DIM ;;
    esac
    pad=$(( 9 - ${#label} - 2 ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s[%s]%s' "$color$C_BOLD" "$label" "$C_RESET"
    printf '%*s' "$pad" ''
}

_term_badge_line() {
    local sev=$1 text=$2 width=${3:-100} badge
    badge=$(_term_sev_badge "$sev")
    if [ "$width" -ge 70 ]; then
        printf '  %s  %s\n' "$badge" "$text"
    else
        printf '  %s\n' "$badge"
        _term_wrap "$text" 6 "$width"
    fi
}

_term_bar() {
    local score=${1:-0} width=${2:-24}
    local filled i out=''
    [ "$score" -lt 0 ] && score=0
    [ "$score" -gt 100 ] && score=100
    filled=$(( score * width / 100 ))
    for (( i = 0; i < width; i++ )); do
        if [ "$i" -lt "$filled" ]; then
            if [ "$UI_UTF8" -eq 1 ]; then out+='█'; else out+='#'; fi
        else
            if [ "$UI_UTF8" -eq 1 ]; then out+='░'; else out+='-'; fi
        fi
    done
    printf '%s%s%s' "$(score_color "$score")" "$out" "$C_RESET"
}

_term_summary() {
    local width=${1:-100} verdict color active_n total_n
    if [ "$GLOBAL_SCORE" -ge 80 ]; then
        color=$C_GREEN_B; verdict='BUENO'
    elif [ "$GLOBAL_SCORE" -ge 50 ]; then
        color=$C_YELLOW_B; verdict='MEJORABLE'
    else
        color=$C_RED_B; verdict='CRÍTICO'
    fi
    active_n=${#ACTIVE_CHECK_IDS[@]}
    [ "$active_n" -gt 0 ] || active_n=${#CHECK_IDS[@]}
    total_n=${#CHECK_IDS[@]}

    _term_section 'Resumen' 42 "$width"
    printf '\n'
    printf '  %sScore:%s %s%d/100%s  %s%s%s\n' \
        "$C_BOLD" "$C_RESET" "$color$C_BOLD" "$GLOBAL_SCORE" "$C_RESET" \
        "$color" "$verdict" "$C_RESET"
    printf '  %s\n' "$(_term_bar "$GLOBAL_SCORE" 24)"

    if [ "$width" -ge 70 ]; then
        printf '  %s %d correctos   %s %d fallos   %s %d avisos   %s %d omitidos   %s %d info\n' \
            "$(status_icon PASS)" "${COUNT[PASS]}" \
            "$(status_icon FAIL)" "${COUNT[FAIL]}" \
            "$(status_icon WARN)" "${COUNT[WARN]}" \
            "$(status_icon SKIP)" "${COUNT[SKIP]}" \
            "$(status_icon INFO)" "${COUNT[INFO]}"
    elif [ "$width" -ge 46 ]; then
        printf '  %s %d correctos   %s %d fallos\n' \
            "$(status_icon PASS)" "${COUNT[PASS]}" \
            "$(status_icon FAIL)" "${COUNT[FAIL]}"
        printf '  %s %d avisos   %s %d omitidos   %s %d info\n' \
            "$(status_icon WARN)" "${COUNT[WARN]}" \
            "$(status_icon SKIP)" "${COUNT[SKIP]}" \
            "$(status_icon INFO)" "${COUNT[INFO]}"
    else
        printf '  %s %d correctos   %s %d fallos\n' \
            "$(status_icon PASS)" "${COUNT[PASS]}" \
            "$(status_icon FAIL)" "${COUNT[FAIL]}"
        printf '  %s %d avisos   %s %d omitidos\n' \
            "$(status_icon WARN)" "${COUNT[WARN]}" \
            "$(status_icon SKIP)" "${COUNT[SKIP]}"
        printf '  %s %d info\n' "$(status_icon INFO)" "${COUNT[INFO]}"
    fi

    if [ "${#PROFILE_EXCLUDED_IDS[@]}" -gt 0 ]; then
        printf '\n  %sExcluidos por este perfil (%d):%s\n' \
            "$C_DIM" "${#PROFILE_EXCLUDED_IDS[@]}" "$C_RESET"
        _term_wrap "$(profile_excluded_text)" 4 "$width"
    fi

    if [ "$width" -ge 70 ]; then
        printf '  %sDuración:%s %ss · %sperfil:%s %s (%d/%d checks) · %shost:%s %s%s\n' \
            "$C_DIM" "$C_RESET" "${ELAPSED:-0}" \
            "$C_DIM" "$C_RESET" "${PROFILE_LABEL:-General}" "$active_n" "$total_n" \
            "$C_DIM" "$C_RESET" "${HOSTNAME_SHORT:-localhost}" "$C_RESET"
    else
        printf '  %sDuración:%s %ss · %sperfil:%s %s (%d/%d)\n' \
            "$C_DIM" "$C_RESET" "${ELAPSED:-0}" \
            "$C_DIM" "$C_RESET" "${PROFILE_LABEL:-General}" "$active_n" "$total_n"
        printf '  %shost:%s %s%s\n' \
            "$C_DIM" "$C_RESET" "${HOSTNAME_SHORT:-localhost}" "$C_RESET"
    fi
}

# Fallos confirmados: se explican en detalle porque exigen acción.
_term_failures() {
    local width=$1 sev id detail n=0
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")

    _term_section 'Fallos' 41 "$width"

    for sev in critical high medium low; do
        for id in "${ids[@]}"; do
            [ "${CHECK_SEVERITY[$id]}" = "$sev" ] || continue
            [ "$(status_of "$id")" = FAIL ] || continue
            n=$(( n + 1 ))
            detail=$(detail_of "$id")

            printf '\n  %s %s %s%s%s\n' \
                "$(status_icon FAIL)" "$(_term_sev_badge "$sev")" \
                "$C_BOLD" "$id" "$C_RESET"
            _term_wrap "${CHECK_TITLE[$id]}" 6 "$width"
            [ -n "$detail" ] && _term_wrap "$detail" 6 "$width"
        done
    done

    if [ "$n" -eq 0 ]; then
        printf '  %sNinguno: no hay fallos confirmados.%s\n' "$C_GREEN_B" "$C_RESET"
    fi
}

# Avisos: una línea por hallazgo, suficiente para decidir si profundizar.
_term_warnings() {
    local width=$1 sev id text avail n=0
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")
    # Prefijo: 2 espacios + icono + espacio + insignia (9) + espacio
    # + ID (hasta 7) + 2 espacios.
    avail=$(( width - 23 ))
    [ "$avail" -lt 10 ] && avail=10

    _term_section 'Avisos' 41 "$width"

    for sev in critical high medium low; do
        for id in "${ids[@]}"; do
            [ "${CHECK_SEVERITY[$id]}" = "$sev" ] || continue
            [ "$(status_of "$id")" = WARN ] || continue
            n=$(( n + 1 ))

            text=$(detail_of "$id")
            [ -n "$text" ] || text=${CHECK_TITLE[$id]}
            text=$(clip "$text" "$avail")

            printf '  %s %s %s%s%s  %s\n' \
                "$(status_icon WARN)" "$(_term_sev_badge "$sev")" \
                "$C_BOLD" "$id" "$C_RESET" "$text"
        done
    done

    if [ "$n" -eq 0 ]; then
        printf '  %sNinguno.%s\n' "$C_GREEN_B" "$C_RESET"
    fi
}

# Vista compacta por dominio; el detalle completo vive en el informe.
_term_domains() {
    local width=${1:-100} dom id pass_n
    local -a domains=(SYS USR NET SVC FS AUTH INT MAL)
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")

    _term_section 'Por dominio' 37 "$width"
    printf '\n'

    if [ "$width" -ge 70 ]; then
        printf '  %-22s %7s   %s %s   %s %s   %s %s   %s %s\n' \
            'Dominio' 'Score' \
            "$(status_icon PASS)" 'OK' "$(status_icon FAIL)" 'FAIL' \
            "$(status_icon WARN)" 'WARN' "$(status_icon SKIP)" 'SKIP'

        for dom in "${domains[@]}"; do
            [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
            pass_n=0
            for id in "${ids[@]}"; do
                [ "$(domain_of "$id")" = "$dom" ] || continue
                [ "$(status_of "$id")" = PASS ] && pass_n=$(( pass_n + 1 ))
            done

            printf '  %-22s %s%3d/100%s   %s %d    %s %d    %s %d    %s %d\n' \
                "${DOMAIN_NAME[$dom]:-$dom}" \
                "$(score_color "${DOMAIN_SCORE[$dom]:-100}")" "${DOMAIN_SCORE[$dom]:-100}" "$C_RESET" \
                "$(status_icon PASS)" "$pass_n" \
                "$(status_icon FAIL)" "${DOMAIN_FAIL[$dom]:-0}" \
                "$(status_icon WARN)" "${DOMAIN_WARN[$dom]:-0}" \
                "$(status_icon SKIP)" "${DOMAIN_SKIP[$dom]:-0}"
        done
    elif [ "$width" -ge 46 ]; then
        for dom in "${domains[@]}"; do
            [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
            pass_n=0
            for id in "${ids[@]}"; do
                [ "$(domain_of "$id")" = "$dom" ] || continue
                [ "$(status_of "$id")" = PASS ] && pass_n=$(( pass_n + 1 ))
            done

            printf '  %-22s %s%3d/100%s  %s%d %s%d %s%d %s%d\n' \
                "${DOMAIN_NAME[$dom]:-$dom}" \
                "$(score_color "${DOMAIN_SCORE[$dom]:-100}")" "${DOMAIN_SCORE[$dom]:-100}" "$C_RESET" \
                "$(status_icon PASS)" "$pass_n" \
                "$(status_icon FAIL)" "${DOMAIN_FAIL[$dom]:-0}" \
                "$(status_icon WARN)" "${DOMAIN_WARN[$dom]:-0}" \
                "$(status_icon SKIP)" "${DOMAIN_SKIP[$dom]:-0}"
        done
    else
        for dom in "${domains[@]}"; do
            [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
            pass_n=0
            for id in "${ids[@]}"; do
                [ "$(domain_of "$id")" = "$dom" ] || continue
                [ "$(status_of "$id")" = PASS ] && pass_n=$(( pass_n + 1 ))
            done

            printf '  %s\n' "${DOMAIN_NAME[$dom]:-$dom}"
            printf '    %s%3d/100%s  %s%d %s%d %s%d %s%d\n' \
                "$(score_color "${DOMAIN_SCORE[$dom]:-100}")" "${DOMAIN_SCORE[$dom]:-100}" "$C_RESET" \
                "$(status_icon PASS)" "$pass_n" \
                "$(status_icon FAIL)" "${DOMAIN_FAIL[$dom]:-0}" \
                "$(status_icon WARN)" "${DOMAIN_WARN[$dom]:-0}" \
                "$(status_icon SKIP)" "${DOMAIN_SKIP[$dom]:-0}"
        done
    fi
}

_term_guide() {
    local width=$1

    _term_section 'Cómo leer y actuar' 32 "$width"
    printf '\n'

    _term_wrap 'Puntuación: 80-100 buen estado · 50-79 mejorable · menos de 50 crítico. La nota es orientativa: un fallo crítico aislado puede pesar más que muchos avisos.' 2 "$width"
    printf '\n'

    _term_wrap '• Empieza por CRÍTICA y ALTA. Aplica un cambio cada vez y vuelve a ejecutar la auditoría.' 2 "$width"
    _term_wrap '• Revisa el contexto antes de tocar nada: exposición a Internet, usuarios, datos y servicios.' 2 "$width"
    _term_wrap '• Un aviso puede ser una decisión deliberada; confirma que encaja con tu uso.' 2 "$width"
    _term_wrap '• Cambia el enfoque con --profile servidor|cliente|domestico|esencial; la general revisa todo.' 2 "$width"
    _term_wrap '• Guarda el informe con --save para comparar el antes y el después.' 2 "$width"
    _term_wrap '• Vigila conexiones y servicios con ./watch4me.sh watch (solo lectura).' 2 "$width"
    printf '\n'

    printf '  %sCómo valorar el peligro%s\n' "$C_BOLD" "$C_RESET"
    _term_badge_line critical 'acceso remoto o root sin control, malware o persistencia.' "$width"
    _term_badge_line high 'escalada local, servicio expuesto o paquetes alterados.' "$width"
    _term_badge_line medium 'hardening incompleto: reduce el margen de defensa.' "$width"
    _term_badge_line low 'higiene y configuraciones de bajo impacto.' "$width"
    printf '\n'

    if [ "$width" -ge 70 ]; then
        printf '  %sDetalle completo y remedios:%s ./watch4me.sh explain <ID>   %s·%s   informe: --save\n' \
            "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '  %sGenerado por watch4me v%s · GPLv3 · solo lectura%s\n' \
            "$C_DIM" "${VERSION:-0.6.1}" "$C_RESET"
    else
        _term_wrap 'Detalle completo y remedios: ./watch4me.sh explain <ID> · informe: --save' 2 "$width"
        _term_wrap "Generado por watch4me v${VERSION:-0.6.1} · GPLv3 · solo lectura" 2 "$width"
    fi
}

render_terminal() {
    local width
    width=$(term_width)
    _term_summary "$width"
    _term_failures "$width"
    _term_warnings "$width"
    _term_domains "$width"
    _term_guide "$width"
}
