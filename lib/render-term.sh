#!/usr/bin/env bash
# watch4me — renderizador de terminal
# Licencia: GPLv3

_term_wrap() {
    local text=$1 indent=$2 width=$3
    local avail=$(( width - indent ))
    [ "$avail" -lt 24 ] && avail=24
    printf '%s\n' "$text" | fold -s -w "$avail" | while IFS= read -r line; do
        printf '%*s%s\n' "$indent" '' "$line"
    done
}

render_terminal() {
    local width
    width=$(term_width)
    local dom id st sev detail title icon_name
    local -a domains=(SYS USR NET SVC FS AUTH INT MAL)

    for dom in "${domains[@]}"; do
        [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
        local score=${DOMAIN_SCORE[$dom]:-100}
        local scolor
        scolor=$(score_color "$score")

        printf '\n%s── %s %s' "$C_BOLD$C_CYAN_B" "${DOMAIN_NAME[$dom]:-$dom}" "$C_RESET"
        printf '%s%s%s %s%s/100%s\n' "$C_DIM" "$(printf '─%.0s' {1..40})" "$C_RESET" "$scolor" "$score" "$C_RESET"

        for id in "${CHECK_IDS[@]}"; do
            [ "$(domain_of "$id")" = "$dom" ] || continue
            st=$(status_of "$id")
            sev=${CHECK_SEVERITY[$id]}
            title=${CHECK_TITLE[$id]}
            detail=$(detail_of "$id")

            printf '  %s %s%-8s%s %s\n' \
                "$(status_icon "$st")" "$C_BOLD" "$id" "$C_RESET" "$title"

            if [ -n "$detail" ]; then
                local color=''
                case "$st" in
                    FAIL) color=$C_RED ;;
                    WARN) color=$C_YELLOW ;;
                    PASS) color=$C_DIM ;;
                    SKIP|INFO) color=$C_DIM ;;
                esac
                printf '%s' "$color"
                _term_wrap "$detail" 12 "$width"
                printf '%s' "$C_RESET"
            fi
        done
    done

    local verdict color
    if [ "$GLOBAL_SCORE" -ge 80 ]; then
        color=$C_GREEN_B
        verdict='BUENO'
    elif [ "$GLOBAL_SCORE" -ge 50 ]; then
        color=$C_YELLOW_B
        verdict='MEJORABLE'
    else
        color=$C_RED_B
        verdict='CRÍTICO'
    fi

    local exit_code=0
    compute_exit_code || exit_code=$?

    printf '\n%s\n' "$(printf '─%.0s' {1..60})"
    printf ' %sScore global:%s %s%d/100%s  %s%s%s\n' \
        "$C_BOLD" "$C_RESET" "$color$C_BOLD" "$GLOBAL_SCORE" "$C_RESET" "$color" "$verdict" "$C_RESET"
    printf ' %s✔ %d   ✖ %d   ! %d   ○ %d   ℹ %d%s\n' \
        "$C_RESET" "${COUNT[PASS]}" "${COUNT[FAIL]}" "${COUNT[WARN]}" "${COUNT[SKIP]}" "${COUNT[INFO]}" "$C_RESET"

    case "$exit_code" in
        2) printf ' %sEstado: fallo crítico (exit 2)%s\n' "$C_RED_B" "$C_RESET" ;;
        1) printf ' %sEstado: requiere atención (exit 1)%s\n' "$C_YELLOW_B" "$C_RESET" ;;
        *) printf ' %sEstado: sin hallazgos relevantes (exit 0)%s\n' "$C_GREEN_B" "$C_RESET" ;;
    esac

    printf ' %sDetalle y remedio de un check: %s./watch4me.sh explain <ID>%s\n' \
        "$C_DIM" "$C_WHITE" "$C_RESET"
}
