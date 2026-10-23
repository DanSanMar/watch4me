#!/usr/bin/env bash
# watch4me — renderizador Markdown
# Licencia: GPLv3

_md_status_label() {
    case "$1" in
        PASS) printf 'correcto' ;;
        WARN) printf 'aviso' ;;
        FAIL) printf 'fallo' ;;
        SKIP) printf 'omitido' ;;
        *) printf 'informativo' ;;
    esac
}

_md_finding() {
    local id=$1
    local st sev title detail evidence
    st=$(status_of "$id")
    sev=${CHECK_SEVERITY[$id]}
    title=${CHECK_TITLE[$id]}
    detail=$(detail_of "$id")
    evidence=$(evidence_of "$id")

    printf '### %s · %s\n\n' "$id" "$title"
    printf -- '- **Severidad:** %s · **Estado:** %s\n' "$(sev_label "$sev")" "$(_md_status_label "$st")"
    [ -n "$detail" ] && printf -- '- **Detalle:** %s\n' "$detail"

    if [ -n "$evidence" ]; then
        printf '\n```text\n%s\n```\n' "$evidence"
    fi

    if [ "$st" = FAIL ] || [ "$st" = WARN ]; then
        local remed=${CHECK_REMED[$id]}
        if [ -n "$remed" ]; then
            printf '\n**Remedio sugerido:**\n\n```sh\n%s\n```\n' "$remed"
        fi
    fi

    printf '\n'
}

_md_section() {
    local title=$1
    shift
    local -a ids=("$@")
    printf '## %s\n\n' "$title"
    if [ "${#ids[@]}" -eq 0 ]; then
        printf 'Sin hallazgos.\n\n'
        return
    fi
    local id
    for id in "${ids[@]}"; do
        _md_finding "$id"
    done
}

render_md() {
    local host kernel now root_txt exit_code=0
    host=${HOSTNAME_SHORT:-$(hostname 2>/dev/null || printf 'localhost')}
    kernel=$(uname -r 2>/dev/null || printf 'desconocido')
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if [ "$(id -u)" -eq 0 ]; then root_txt='sí'; else root_txt='no'; fi
    compute_exit_code || exit_code=$?

    printf '# watch4me — informe de seguridad\n\n'
    printf -- '- **Host:** %s\n' "$host"
    printf -- '- **Distribución:** %s (%s)\n' "${DISTRO_NAME:-desconocida}" "${DISTRO_FAMILY:-unknown}"
    printf -- '- **Kernel:** %s\n' "$kernel"
    printf -- '- **Fecha:** %s\n' "$now"
    printf -- '- **Perfil:** %s · **root:** %s\n' "${PROFILE:-full}" "$root_txt"
    printf -- '- **Score global:** %d/100 (%s)\n' "$GLOBAL_SCORE" "$(score_verdict "$GLOBAL_SCORE")"
    printf -- '- **Resultado:** %d correctos · %d fallos · %d avisos · %d omitidos · %d informativos\n\n' \
        "${COUNT[PASS]}" "${COUNT[FAIL]}" "${COUNT[WARN]}" "${COUNT[SKIP]}" "${COUNT[INFO]}"

    printf '## Resumen por dominio\n\n'
    printf '| Dominio | Score | Fallos | Avisos | Omitidos |\n'
    printf '|---|---:|---:|---:|---:|\n'
    local dom
    for dom in SYS USR NET SVC FS AUTH INT MAL; do
        [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
        printf '| %s | %d/100 | %d | %d | %d |\n' \
            "${DOMAIN_NAME[$dom]:-$dom}" "${DOMAIN_SCORE[$dom]:-100}" \
            "${DOMAIN_FAIL[$dom]:-0}" "${DOMAIN_WARN[$dom]:-0}" "${DOMAIN_SKIP[$dom]:-0}"
    done
    printf '\n'

    local id st sev
    local -a crit=() high=() mid=() warn=() info=() skip=() pass=()
    for id in "${CHECK_IDS[@]}"; do
        st=$(status_of "$id")
        sev=${CHECK_SEVERITY[$id]}
        case "$st" in
            FAIL)
                case "$sev" in
                    critical) crit+=("$id") ;;
                    high) high+=("$id") ;;
                    *) mid+=("$id") ;;
                esac
                ;;
            WARN) warn+=("$id") ;;
            INFO) info+=("$id") ;;
            SKIP) skip+=("$id") ;;
            *) pass+=("$id") ;;
        esac
    done

    _md_section 'Hallazgos críticos' "${crit[@]}"
    _md_section 'Hallazgos altos' "${high[@]}"
    _md_section 'Hallazgos medios y bajos' "${mid[@]}"
    _md_section 'Avisos' "${warn[@]}"
    _md_section 'Informativo' "${info[@]}"
    _md_section 'Controles omitidos' "${skip[@]}"

    printf '## Controles superados\n\n'
    if [ "${#pass[@]}" -eq 0 ]; then
        printf 'Ninguno.\n\n'
    else
        local first=1
        for id in "${pass[@]}"; do
            if [ "$first" -eq 1 ]; then first=0; else printf ' · '; fi
            printf '%s' "$id"
        done
        printf '\n\n'
    fi

    printf -- '---\n\n'
    printf 'Generado por watch4me v%s · licencia GPLv3 · la cabecera animada deriva de [dash4me](https://github.com/DanSanMar/dash4me)\n' \
        "${VERSION:-0.1.0}"
}
