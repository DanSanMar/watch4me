#!/usr/bin/env bash
# watch4me — registro de checks, estado y puntuación
# Licencia: GPLv3

declare -a CHECK_IDS=()
declare -A CHECK_SEVERITY=()
declare -A CHECK_TITLE=()
declare -A CHECK_FUNC=()
declare -A CHECK_DESC=()
declare -A CHECK_REMED=()
declare -A CHECK_DOMAIN=()

declare -A SEV_WEIGHT=(
    [critical]=10
    [high]=7
    [medium]=4
    [low]=2
    [info]=0
)

declare -A DOMAIN_NAME=(
    [SYS]='Sistema'
    [USR]='Usuarios'
    [NET]='Red'
    [SVC]='Servicios'
    [FS]='Ficheros'
    [AUTH]='Autenticación'
    [INT]='Integridad'
    [MAL]='Malware y persistencia'
)

# shellcheck disable=SC2034 # usado por los renderizadores
declare -A COUNT=([PASS]=0 [WARN]=0 [FAIL]=0 [SKIP]=0 [INFO]=0)
GLOBAL_SCORE=100
TOTAL_POSSIBLE=0
TOTAL_PENALTY=0
declare -A DOMAIN_SCORE=()
declare -A DOMAIN_POSSIBLE=()
declare -A DOMAIN_PENALTY=()
declare -A DOMAIN_TOTAL=()
declare -A DOMAIN_FAIL=()
declare -A DOMAIN_WARN=()
declare -A DOMAIN_SKIP=()

register_check() {
    local id=$1 sev=$2 title=$3 func=$4 desc=${5:-} remed=${6:-}
    if [ -z "$id" ] || [ -z "$func" ]; then
        warn "check mal declarado: ${id:-<sin id>}"
        return 1
    fi
    if [ -n "${CHECK_FUNC[$id]:-}" ]; then
        warn "check duplicado: $id"
        return 1
    fi
    case "$sev" in
        critical|high|medium|low|info) ;;
        *)
            warn "severidad desconocida en $id: $sev"
            sev=info
            ;;
    esac
    CHECK_IDS+=("$id")
    CHECK_SEVERITY[$id]=$sev
    CHECK_TITLE[$id]=$title
    CHECK_FUNC[$id]=$func
    CHECK_DESC[$id]=$desc
    CHECK_REMED[$id]=$remed
    CHECK_DOMAIN[$id]=${id%%-*}
}

domain_of() {
    local id=$1
    printf '%s' "${CHECK_DOMAIN[$id]:-${id%%-*}}"
}

sev_weight() {
    printf '%s' "${SEV_WEIGHT[${1:-info}]:-0}"
}

sev_label() {
    case "$1" in
        critical) printf 'Crítica' ;;
        high) printf 'Alta' ;;
        medium) printf 'Media' ;;
        low) printf 'Baja' ;;
        *) printf 'Informativa' ;;
    esac
}

detail_limit() {
    printf '%s' 400
}

emit() {
    local id=$1 status=$2 detail=${3:-}
    local safe
    safe=$(printf '%s' "$detail" | oneline)
    if [ "${#safe}" -gt 400 ]; then
        safe="${safe:0:399}…"
    fi
    printf '%s\n' "$status" > "$RUN_DIR/$id.status"
    printf '%s\n' "$safe" > "$RUN_DIR/$id.detail"
}

# Añade una línea de evidencia al check en curso.
ev() {
    [ -n "${CURRENT_ID:-}" ] || return 0
    printf '%s\n' "$*" >> "$RUN_DIR/$CURRENT_ID.evidence"
}

# Atajo para checks que no pueden ejecutarse.
skip_check() {
    emit "$CURRENT_ID" SKIP "$1"
}

run_single_check() {
    local id=$1
    CURRENT_ID=$id
    local fn=${CHECK_FUNC[$id]:-}
    : > "$RUN_DIR/$id.status"
    : > "$RUN_DIR/$id.detail"
    : > "$RUN_DIR/$id.evidence"

    if [ -z "$fn" ] || ! declare -F "$fn" >/dev/null 2>&1; then
        emit "$id" SKIP 'Check no implementado'
        return 0
    fi

    # stdout y stderr se descartan: los resultados van por emit/ev.
    ( "$fn" ) >/dev/null 2>&1

    if [ ! -s "$RUN_DIR/$id.status" ]; then
        emit "$id" SKIP 'El check no devolvió resultado'
    fi
}

status_of() {
    local f="$RUN_DIR/$1.status"
    if [ -r "$f" ]; then
        head -n 1 "$f"
    else
        printf 'SKIP'
    fi
}

detail_of() {
    local f="$RUN_DIR/$1.detail"
    if [ -r "$f" ]; then
        head -n 1 "$f"
    fi
}

evidence_of() {
    local f="$RUN_DIR/$1.evidence"
    if [ -r "$f" ] && [ -s "$f" ]; then
        head -n 12 "$f"
    fi
}

compute_scores() {
    local id sev st w dom p possible penalty
    COUNT[PASS]=0 COUNT[WARN]=0 COUNT[FAIL]=0 COUNT[SKIP]=0 COUNT[INFO]=0
    TOTAL_POSSIBLE=0
    TOTAL_PENALTY=0
    DOMAIN_SCORE=()
    DOMAIN_POSSIBLE=()
    DOMAIN_PENALTY=()
    DOMAIN_TOTAL=()
    DOMAIN_FAIL=()
    DOMAIN_WARN=()
    DOMAIN_SKIP=()

    for id in "${CHECK_IDS[@]}"; do
        sev=${CHECK_SEVERITY[$id]}
        st=$(status_of "$id")
        dom=$(domain_of "$id")
        w=$(sev_weight "$sev")
        DOMAIN_TOTAL[$dom]=$(( ${DOMAIN_TOTAL[$dom]:-0} + 1 ))

        case "$st" in
            PASS|WARN|FAIL|SKIP|INFO) COUNT[$st]=$(( ${COUNT[$st]:-0} + 1 )) ;;
            *) st=SKIP; COUNT[SKIP]=$(( ${COUNT[SKIP]:-0} + 1 )) ;;
        esac

        case "$st" in
            FAIL) DOMAIN_FAIL[$dom]=$(( ${DOMAIN_FAIL[$dom]:-0} + 1 )) ;;
            WARN) DOMAIN_WARN[$dom]=$(( ${DOMAIN_WARN[$dom]:-0} + 1 )) ;;
            SKIP) DOMAIN_SKIP[$dom]=$(( ${DOMAIN_SKIP[$dom]:-0} + 1 )) ;;
        esac

        # SKIP e INFO no puntúan.
        [ "$st" = SKIP ] && continue
        [ "$sev" = info ] && continue

        possible=$w
        penalty=0
        case "$st" in
            FAIL) penalty=$w ;;
            WARN) penalty=$(( w / 2 )) ;;
        esac

        DOMAIN_POSSIBLE[$dom]=$(( ${DOMAIN_POSSIBLE[$dom]:-0} + possible ))
        DOMAIN_PENALTY[$dom]=$(( ${DOMAIN_PENALTY[$dom]:-0} + penalty ))
        TOTAL_POSSIBLE=$(( TOTAL_POSSIBLE + possible ))
        TOTAL_PENALTY=$(( TOTAL_PENALTY + penalty ))
    done

    for dom in "${!DOMAIN_TOTAL[@]}"; do
        possible=${DOMAIN_POSSIBLE[$dom]:-0}
        penalty=${DOMAIN_PENALTY[$dom]:-0}
        if [ "$possible" -gt 0 ]; then
            DOMAIN_SCORE[$dom]=$(( ((possible - penalty) * 100 + possible / 2) / possible ))
        else
            DOMAIN_SCORE[$dom]=100
        fi
        [ "${DOMAIN_SCORE[$dom]}" -lt 0 ] && DOMAIN_SCORE[$dom]=0
    done

    if [ "$TOTAL_POSSIBLE" -gt 0 ]; then
        GLOBAL_SCORE=$(( ((TOTAL_POSSIBLE - TOTAL_PENALTY) * 100 + TOTAL_POSSIBLE / 2) / TOTAL_POSSIBLE ))
    else
        GLOBAL_SCORE=100
    fi
    [ "$GLOBAL_SCORE" -lt 0 ] && GLOBAL_SCORE=0
}

score_color() {
    local score=${1:-0}
    if [ "$score" -ge 80 ]; then
        printf '%s' "$C_GREEN_B"
    elif [ "$score" -ge 50 ]; then
        printf '%s' "$C_YELLOW_B"
    else
        printf '%s' "$C_RED_B"
    fi
}

score_verdict() {
    local score=${1:-0}
    if [ "$score" -ge 80 ]; then
        printf 'BUENO'
    elif [ "$score" -ge 50 ]; then
        printf 'MEJORABLE'
    else
        printf 'CRÍTICO'
    fi
}

# 0 = todo correcto, 1 = avisos o fallos, 2 = algún fallo crítico.
compute_exit_code() {
    local id st sev
    for id in "${CHECK_IDS[@]}"; do
        st=$(status_of "$id")
        sev=${CHECK_SEVERITY[$id]}
        if [ "$st" = FAIL ] && [ "$sev" = critical ]; then
            return 2
        fi
    done
    for id in "${CHECK_IDS[@]}"; do
        st=$(status_of "$id")
        if [ "$st" = FAIL ] || [ "$st" = WARN ]; then
            return 1
        fi
    done
    return 0
}

status_icon() {
    local color=1
    if [ "$UI_COLOR" -eq 0 ]; then color=0; fi
    case "$1" in
        PASS) [ "$color" -eq 1 ] && printf '%s✔%s' "$C_GREEN_B" "$C_RESET" || printf '+' ;;
        WARN) [ "$color" -eq 1 ] && printf '%s!%s' "$C_YELLOW_B" "$C_RESET" || printf '!' ;;
        FAIL) [ "$color" -eq 1 ] && printf '%s✖%s' "$C_RED_B" "$C_RESET" || printf 'x' ;;
        SKIP) [ "$color" -eq 1 ] && printf '%s○%s' "$C_DIM" "$C_RESET" || printf '-' ;;
        INFO) [ "$color" -eq 1 ] && printf '%sℹ%s' "$C_CYAN" "$C_RESET" || printf 'i' ;;
        *) printf '?' ;;
    esac
}
