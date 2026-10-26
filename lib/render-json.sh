#!/usr/bin/env bash
# watch4me — renderizador JSON
# Licencia: GPLv3
#
# Informe estructurado pensado para análisis automático (IA, scripts, diffs).
# No requiere jq, python ni red: el escape se hace con Bash puro.

_json_escape() {
    local s=${1-} out='' ch i
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Cualquier otro carácter de control rompería el JSON: se descarta.
    for (( i = 0; i < ${#s}; i++ )); do
        ch=${s:i:1}
        case "$ch" in
            [[:cntrl:]]) ;;
            *) out+=$ch ;;
        esac
    done
    printf '%s' "$out"
}

_json_str() {
    printf '"%s"' "$(_json_escape "${1-}")"
}

_json_bool() {
    if [ "${1:-0}" -eq 1 ] || [ "${1:-}" = 'true' ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# Array JSON de una línea por elemento de la evidencia.
_json_evidence() {
    local id=$1 ev line first=1
    ev=$(evidence_of "$id")
    if [ -z "$ev" ]; then
        printf '[]'
        return
    fi
    printf '['
    while IFS= read -r line; do
        [ "$first" -eq 1 ] || printf ', '
        printf '%s' "$(_json_str "$line")"
        first=0
    done <<< "$ev"
    printf ']'
}

render_json() {
    local base=${1:-}
    local host kernel now root_txt
    local id st sev w penalty first dom run_n
    local -a run_ids=("${ACTIVE_CHECK_IDS[@]}")
    [ "${#run_ids[@]}" -gt 0 ] || run_ids=("${CHECK_IDS[@]}")
    run_n=${#run_ids[@]}
    local exit_code=${EXIT_CODE:-0}

    host=${HOSTNAME_SHORT:-$(hostname 2>/dev/null || printf 'localhost')}
    kernel=$(uname -r 2>/dev/null || printf 'desconocido')
    now=$(date '+%Y-%m-%dT%H:%M:%S%:z' 2>/dev/null || true)
    case "$now" in
        ''|*%*) now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S') ;;
    esac
    if [ "$(id -u)" -eq 0 ]; then root_txt=1; else root_txt=0; fi

    printf '{\n'
    printf '  "schema": "watch4me.report/v1",\n'
    printf '  "language": "es",\n'
    printf '  "scope": "read-only",\n'

    printf '  "tool": {\n'
    printf '    "name": "watch4me",\n'
    printf '    "version": %s,\n' "$(_json_str "${VERSION:-0.7.0}")"
    printf '    "license": "GPLv3"\n'
    printf '  },\n'

    printf '  "report": {\n'
    printf '    "format_version": 1,\n'
    printf '    "generated_at": %s,\n' "$(_json_str "$now")"
    printf '    "markdown_file": %s,\n' "$(_json_str "$(basename -- "${base:-informe}.md")")"
    printf '    "json_file": %s\n' "$(_json_str "$(basename -- "${base:-informe}.json")")"
    printf '  },\n'

    printf '  "host": {\n'
    printf '    "name": %s,\n' "$(_json_str "$host")"
    printf '    "kernel": %s,\n' "$(_json_str "$kernel")"
    printf '    "distro": {\n'
    printf '      "name": %s,\n' "$(_json_str "${DISTRO_NAME:-desconocida}")"
    printf '      "family": %s\n' "$(_json_str "${DISTRO_FAMILY:-unknown}")"
    printf '    }\n'
    printf '  },\n'

    printf '  "run": {\n'
    printf '    "profile": %s,\n' "$(_json_str "${PROFILE:-general}")"
    printf '    "profile_label": %s,\n' "$(_json_str "${PROFILE_LABEL:-General}")"
    printf '    "profile_description": %s,\n' "$(_json_str "${PROFILE_DESC:-}")"
    printf '    "checks_catalog": %s,\n' "${#CHECK_IDS[@]}"
    printf '    "checks_total": %s,\n' "$run_n"
    printf '    "checks_excluded": ['
    first=1
    for id in "${PROFILE_EXCLUDED_IDS[@]}"; do
        [ "$first" -eq 1 ] || printf ', '
        printf '%s' "$(_json_str "$id")"
        first=0
    done
    printf '],\n'
    printf '    "root": %s,\n' "$(_json_bool "$root_txt")"
    printf '    "sudo_requested": %s,\n' "$(_json_bool "${USE_SUDO:-0}")"
    printf '    "duration_seconds": %s,\n' "${ELAPSED:-0}"
    printf '    "exit_code": %s\n' "$exit_code"
    printf '  },\n'

    printf '  "score": {\n'
    printf '    "global": %s,\n' "$GLOBAL_SCORE"
    printf '    "verdict": %s,\n' "$(_json_str "$(score_verdict "$GLOBAL_SCORE")")"
    printf '    "possible": %s,\n' "$TOTAL_POSSIBLE"
    printf '    "penalty": %s\n' "$TOTAL_PENALTY"
    printf '  },\n'

    printf '  "verdict_text": %s,\n' "$(_json_str "$(audit_verdict_text)")"

    printf '  "counts": {\n'
    printf '    "pass": %s,\n' "${COUNT[PASS]:-0}"
    printf '    "warn": %s,\n' "${COUNT[WARN]:-0}"
    printf '    "fail": %s,\n' "${COUNT[FAIL]:-0}"
    printf '    "skip": %s,\n' "${COUNT[SKIP]:-0}"
    printf '    "info": %s\n' "${COUNT[INFO]:-0}"
    printf '  },\n'

    printf '  "domains": [\n'
    first=1
    for dom in SYS USR NET SVC FS AUTH INT MAL; do
        [ "${DOMAIN_TOTAL[$dom]:-0}" -gt 0 ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {\n'
        printf '      "id": %s,\n' "$(_json_str "$dom")"
        printf '      "name": %s,\n' "$(_json_str "${DOMAIN_NAME[$dom]:-$dom}")"
        printf '      "score": %s,\n' "${DOMAIN_SCORE[$dom]:-100}"
        printf '      "possible": %s,\n' "${DOMAIN_POSSIBLE[$dom]:-0}"
        printf '      "penalty": %s,\n' "${DOMAIN_PENALTY[$dom]:-0}"
        printf '      "checks": %s,\n' "${DOMAIN_TOTAL[$dom]:-0}"
        printf '      "fail": %s,\n' "${DOMAIN_FAIL[$dom]:-0}"
        printf '      "warn": %s,\n' "${DOMAIN_WARN[$dom]:-0}"
        printf '      "skip": %s\n' "${DOMAIN_SKIP[$dom]:-0}"
        printf '    }'
    done
    printf '\n  ],\n'

    printf '  "checks": [\n'
    first=1
    for id in "${run_ids[@]}"; do
        st=$(status_of "$id")
        sev=${CHECK_SEVERITY[$id]}
        w=$(sev_weight "$sev")
        penalty=0
        case "$st" in
            FAIL) penalty=$w ;;
            WARN) penalty=$(( w / 2 )) ;;
        esac
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {\n'
        printf '      "id": %s,\n' "$(_json_str "$id")"
        printf '      "domain": %s,\n' "$(_json_str "$(domain_of "$id")")"
        printf '      "domain_name": %s,\n' "$(_json_str "${DOMAIN_NAME[$(domain_of "$id")]:-$(domain_of "$id")}")"
        printf '      "severity": %s,\n' "$(_json_str "$sev")"
        printf '      "severity_label": %s,\n' "$(_json_str "$(sev_label "$sev")")"
        printf '      "severity_weight": %s,\n' "$w"
        printf '      "status": %s,\n' "$(_json_str "$st")"
        printf '      "status_label": %s,\n' "$(_json_str "$(status_label "$st")")"
        printf '      "penalty": %s,\n' "$penalty"
        printf '      "title": %s,\n' "$(_json_str "${CHECK_TITLE[$id]:-}")"
        printf '      "description": %s,\n' "$(_json_str "${CHECK_DESC[$id]:-}")"
        printf '      "detail": %s,\n' "$(_json_str "$(detail_of "$id")")"
        printf '      "evidence": %s,\n' "$(_json_evidence "$id")"
        printf '      "remedy": %s\n' "$(_json_str "${CHECK_REMED[$id]:-}")"
        printf '    }'
    done
    printf '\n  ]\n'
    printf '}\n'
}
