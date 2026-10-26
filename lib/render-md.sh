#!/usr/bin/env bash
# watch4me — renderizador Markdown
# Licencia: GPLv3

# Los textos son Markdown literal (comillas invertidas incluidas).
# shellcheck disable=SC2016

_md_status_label() {
    status_label "$1"
}

_md_escape() {
    printf '%s' "$1" | sed 's/|/\\|/g'
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
    printf '### %s\n\n' "$title"
    if [ "${#ids[@]}" -eq 0 ]; then
        printf 'Sin hallazgos.\n\n'
        return
    fi
    local id
    for id in "${ids[@]}"; do
        _md_finding "$id"
    done
}

_md_summary() {
    local crit_fail=0 high_fail=0 mid_fail=0 id st sev
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")
    for id in "${ids[@]}"; do
        st=$(status_of "$id")
        [ "$st" = FAIL ] || continue
        sev=${CHECK_SEVERITY[$id]}
        case "$sev" in
            critical) crit_fail=$(( crit_fail + 1 )) ;;
            high) high_fail=$(( high_fail + 1 )) ;;
            *) mid_fail=$(( mid_fail + 1 )) ;;
        esac
    done

    printf '## Resumen ejecutivo\n\n'
    printf -- '- **Score:** %d/100 (%s)\n' "$GLOBAL_SCORE" "$(score_verdict "$GLOBAL_SCORE")"
    printf -- '- **Fallos:** %d (críticos %d · altos %d · medios y bajos %d)\n' \
        "${COUNT[FAIL]}" "$crit_fail" "$high_fail" "$mid_fail"
    printf -- '- **Avisos:** %d · **Omitidos:** %d · **Informativos:** %d\n' \
        "${COUNT[WARN]}" "${COUNT[SKIP]}" "${COUNT[INFO]}"
    printf -- '- **Duración:** %ss\n\n' "${ELAPSED:-0}"
    printf '**Veredicto:** %s\n\n' "$(audit_verdict_text)"
}

_md_scope() {
    local id n total
    n=${#ACTIVE_CHECK_IDS[@]}
    [ "$n" -gt 0 ] || n=${#CHECK_IDS[@]}
    total=${#CHECK_IDS[@]}

    printf '## Alcance del perfil\n\n'
    printf 'Se ejecutaron **%d de %d** checks del perfil **%s** (`%s`).\n\n' \
        "$n" "$total" "${PROFILE_LABEL:-General}" "${PROFILE:-general}"
    [ -n "${PROFILE_DESC:-}" ] && printf '%s\n\n' "$PROFILE_DESC"

    if [ "${#PROFILE_EXCLUDED_IDS[@]}" -gt 0 ]; then
        printf '**Checks excluidos (%d):**' "${#PROFILE_EXCLUDED_IDS[@]}"
        for id in "${PROFILE_EXCLUDED_IDS[@]}"; do
            printf ' `%s`' "$id"
        done
        printf '\n\n'
    else
        printf 'No se excluyó ningún check del catálogo.\n\n'
    fi
}

_md_priorities() {
    local sev st id detail n=0
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")
    printf '## Prioridades\n\n'
    printf '| Estado | Severidad | Check | Qué ocurre |\n'
    printf '|---|---|---|---|\n'

    for sev in critical high medium low; do
        for st in FAIL WARN; do
            for id in "${ids[@]}"; do
                [ "${CHECK_SEVERITY[$id]}" = "$sev" ] || continue
                [ "$(status_of "$id")" = "$st" ] || continue
                n=$(( n + 1 ))
                detail=$(detail_of "$id")
                printf '| %s | %s | `%s` · %s | %s |\n' \
                    "$(_md_status_label "$st")" "$(sev_label "$sev")" \
                    "$id" "$(_md_escape "${CHECK_TITLE[$id]}")" \
                    "$(_md_escape "${detail:-sin detalle}")"
            done
        done
    done

    if [ "$n" -eq 0 ]; then
        printf '\nSin fallos ni avisos.\n'
    fi
    printf '\n'
}

_md_guide() {
    printf '## Cómo interpretar y actuar\n\n'
    printf '**Puntuación.** 80-100 indica buen estado; 50-79, mejorable; por debajo de 50, crítico. La nota es orientativa: un fallo crítico aislado puede ser más grave que muchos avisos juntos.\n\n'
    printf '**Gravedad.**\n\n'
    printf -- '- **Crítica:** acceso remoto o root sin control, malware o persistencia. Actúa de inmediato.\n'
    printf -- '- **Alta:** escalada local, servicio expuesto o paquetes alterados. Corrige pronto.\n'
    printf -- '- **Media:** hardening incompleto; reduce el margen de defensa.\n'
    printf -- '- **Baja:** higiene y configuraciones de bajo impacto.\n\n'
    printf '**Qué hacer con los resultados.**\n\n'
    printf '1. Empieza por los fallos críticos y altos; no intentes corregirlo todo a la vez.\n'
    printf '2. Revisa el contexto de cada hallazgo antes de aplicar el remedio: exposición a Internet, usuarios, datos y servicios afectados.\n'
    printf '3. Consulta el detalle y los comandos sugeridos con `./watch4me.sh explain <ID>`.\n'
    printf '4. Aplica un cambio cada vez, en una ventana de mantenimiento, y vuelve a ejecutar la auditoría.\n'
    printf '5. Si el equipo tiene un uso claro, repite con `--profile servidor`, `cliente` o `domestico`; el vistazo `esencial` es solo una primera mirada.\n'
    printf '6. Para vigilar conexiones y servicios en tiempo real, usa `./watch4me.sh watch` (solo lectura).\n'
    printf '7. Guarda el informe con `--save` para comparar el antes y el después.\n\n'
    printf 'Un aviso puede ser una decisión deliberada de tu configuración. Confirma que encaja con tu uso antes de cambiarlo. watch4me no modifica el sistema: todos los comandos son sugerencias.\n\n'
}

render_md() {
    local host kernel now root_txt
    host=${HOSTNAME_SHORT:-$(hostname 2>/dev/null || printf 'localhost')}
    kernel=$(uname -r 2>/dev/null || printf 'desconocido')
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if [ "$(id -u)" -eq 0 ]; then root_txt='sí'; else root_txt='no'; fi

    printf '# watch4me — informe de seguridad\n\n'
    printf -- '- **Host:** %s\n' "$host"
    printf -- '- **Distribución:** %s (%s)\n' "${DISTRO_NAME:-desconocida}" "${DISTRO_FAMILY:-unknown}"
    printf -- '- **Kernel:** %s\n' "$kernel"
    printf -- '- **Fecha:** %s\n' "$now"
    printf -- '- **Perfil:** %s (`%s`) · **Checks:** %d de %d · **root:** %s\n' \
        "${PROFILE_LABEL:-General}" "${PROFILE:-general}" \
        "${#ACTIVE_CHECK_IDS[@]}" "${#CHECK_IDS[@]}" "$root_txt"
    printf -- '- **Score global:** %d/100 (%s)\n' "$GLOBAL_SCORE" "$(score_verdict "$GLOBAL_SCORE")"
    printf -- '- **Resultado:** %d correctos · %d fallos · %d avisos · %d omitidos · %d informativos\n\n' \
        "${COUNT[PASS]}" "${COUNT[FAIL]}" "${COUNT[WARN]}" "${COUNT[SKIP]}" "${COUNT[INFO]}"

    _md_summary
    _md_scope
    _md_priorities

    printf '## Detalle completo\n\n'

    local id st sev
    local -a ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#ids[@]}" -gt 0 ] || ids=("${CHECK_IDS[@]}")
    local -a crit=() high=() mid=() warn=() info=() skip=() pass=()
    for id in "${ids[@]}"; do
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

    printf '### Controles superados\n\n'
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

    _md_guide

    printf -- '---\n\n'
    printf 'Generado por watch4me v%s · licencia GPLv3 · la cabecera animada deriva de [dash4me](https://github.com/DanSanMar/dash4me)\n' \
        "${VERSION:-0.7.0}"
}
