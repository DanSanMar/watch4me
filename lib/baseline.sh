#!/usr/bin/env bash
# watch4me — baseline de auditoría y comparación de cambios
#
# La baseline guarda únicamente el resultado de una auditoría: estado, detalle
# y severidad de cada check, más el score y metadatos. No guarda puertos,
# servicios, ficheros ni procesos; para eso está watch.
#
# Licencia: GPLv3

# Variables compartidas con watch4me.sh y el menú.
# shellcheck disable=SC2034

BASELINE_SCHEMA='watch4me.baseline/v1'
BASELINE_SCHEMA_READ=''
BASELINE_PROFILE=''
BASELINE_PATH=''
BASELINE_META_PATH=''
BASELINE_CREATED=''
BASELINE_CREATED_EPOCH=0
BASELINE_SCORE=0
BASELINE_EXIT=0
BASELINE_VERSION=''
BASELINE_HOST=''
BASELINE_SUDO_REQ=0
BASELINE_SUDO_USED=0
BASELINE_SUDO_AUTO=0
BASELINE_ROOT=0
BASELINE_ACTIVE=0
BASELINE_CATALOG=0
BASELINE_PASS=0
BASELINE_WARN=0
BASELINE_FAIL=0
BASELINE_SKIP=0
BASELINE_INFO=0
BASELINE_N_WORSE=0
BASELINE_N_BETTER=0
BASELINE_N_SKIP=0
BASELINE_N_EVAL=0
BASELINE_N_NEW=0
BASELINE_N_REMOVED=0
BASELINE_N_ALERT=0
BASELINE_CRIT_FAIL=0
BASELINE_SCORE_DELTA=0

declare -g -a BASELINE_ORDER=()
declare -g -A BASELINE_STATUS=()
declare -g -A BASELINE_SEVERITY=()
declare -g -A BASELINE_TITLE=()
declare -g -A BASELINE_DETAIL=()
declare -g -A BASELINE_CHANGE=()
declare -g -A BASELINE_OLD=()
declare -g -A BASELINE_NEW=()

# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------

baseline_host() {
    local h=${HOSTNAME_SHORT:-localhost}
    h=${h//[^A-Za-z0-9._-]/_}
    case "$h" in
        ''|.|..) h='localhost' ;;
    esac
    printf '%s' "$h"
}

baseline_root() {
    printf '%s/baseline' "$(state_dir)"
}

baseline_host_dir() {
    printf '%s/%s' "$(baseline_root)" "$(baseline_host)"
}

baseline_tsv_path() {
    printf '%s/baseline.tsv' "$(baseline_host_dir)"
}

baseline_meta_path() {
    printf '%s/baseline.meta' "$(baseline_host_dir)"
}

baseline_exists() {
    local tsv meta
    tsv=$(baseline_tsv_path)
    meta=$(baseline_meta_path)
    [ -s "$tsv" ] && [ -s "$meta" ]
}

baseline_display_path() {
    local path=$1
    if [ -n "${SCRIPT_DIR:-}" ]; then
        case "$path" in
            "$SCRIPT_DIR"/*)
                printf '%s' "${path#"$SCRIPT_DIR"/}"
                return 0
                ;;
        esac
    fi
    printf '%s' "$path"
}

baseline_prepare_dir() {
    local root hostdir
    root=$(baseline_root)
    if ! mkdir -p -- "$root" 2>/dev/null || [ ! -w "$root" ]; then
        return 1
    fi
    chmod 700 -- "$root" 2>/dev/null || true

    hostdir=$(baseline_host_dir)
    if ! mkdir -p -- "$hostdir" 2>/dev/null || [ ! -w "$hostdir" ]; then
        return 1
    fi
    chmod 700 -- "$hostdir" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Presentación
# ---------------------------------------------------------------------------

baseline_status_rank() {
    case "${1:-}" in
        PASS|INFO) printf '0' ;;
        WARN)      printf '1' ;;
        FAIL)      printf '2' ;;
        *)         printf '%s' '-1' ;;
    esac
}

baseline_status_color() {
    case "${1:-}" in
        PASS) printf '%s' "$C_GREEN_B" ;;
        WARN) printf '%s' "$C_YELLOW_B" ;;
        FAIL) printf '%s' "$C_RED_B" ;;
        SKIP) printf '%s' "$C_DIM" ;;
        *)    printf '%s' "$C_CYAN" ;;
    esac
}

baseline_arrow() {
    if [ "${UI_ICONS:-0}" -eq 1 ]; then
        printf '→'
    else
        printf '%s' '->'
    fi
}

# ---------------------------------------------------------------------------
# Lectura y escritura
# ---------------------------------------------------------------------------

baseline_load_meta() {
    local meta line key value
    meta=$(baseline_meta_path)
    [ -r "$meta" ] || return 1

    BASELINE_SCHEMA_READ=''
    BASELINE_PROFILE=''
    BASELINE_CREATED=''
    BASELINE_CREATED_EPOCH=0
    BASELINE_SCORE=0
    BASELINE_EXIT=0
    BASELINE_VERSION=''
    BASELINE_HOST=''
    BASELINE_SUDO_REQ=0
    BASELINE_SUDO_USED=0
    BASELINE_ROOT=0
    BASELINE_ACTIVE=0
    BASELINE_CATALOG=0
    BASELINE_PASS=0
    BASELINE_WARN=0
    BASELINE_FAIL=0
    BASELINE_SKIP=0
    BASELINE_INFO=0

    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            schema)           BASELINE_SCHEMA_READ=$value ;;
            profile)          BASELINE_PROFILE=$value ;;
            created)          BASELINE_CREATED=$value ;;
            created_epoch)    BASELINE_CREATED_EPOCH=$value ;;
            score)            BASELINE_SCORE=$value ;;
            exit_code)        BASELINE_EXIT=$value ;;
            tool_version)     BASELINE_VERSION=$value ;;
            host)             BASELINE_HOST=$value ;;
            sudo_requested)   BASELINE_SUDO_REQ=$value ;;
            sudo_used)        BASELINE_SUDO_USED=$value ;;
            root)             BASELINE_ROOT=$value ;;
            checks_active)    BASELINE_ACTIVE=$value ;;
            checks_catalog)   BASELINE_CATALOG=$value ;;
            pass)             BASELINE_PASS=$value ;;
            warn)             BASELINE_WARN=$value ;;
            fail)             BASELINE_FAIL=$value ;;
            skip)             BASELINE_SKIP=$value ;;
            info)             BASELINE_INFO=$value ;;
        esac
    done < "$meta"

    [ "$BASELINE_SCHEMA_READ" = "$BASELINE_SCHEMA" ] || return 1
    [ -n "$BASELINE_PROFILE" ] || return 1
    profile_valid "$BASELINE_PROFILE" || return 1
    [[ "$BASELINE_SCORE" =~ ^[0-9]+$ ]] || return 1
    [[ "$BASELINE_EXIT" =~ ^[0-2]$ ]] || BASELINE_EXIT=0
    [[ "$BASELINE_CREATED_EPOCH" =~ ^[0-9]+$ ]] || BASELINE_CREATED_EPOCH=0
    [[ "$BASELINE_ACTIVE" =~ ^[0-9]+$ ]] || BASELINE_ACTIVE=0
    [[ "$BASELINE_CATALOG" =~ ^[0-9]+$ ]] || BASELINE_CATALOG=0
    [[ "$BASELINE_SUDO_REQ" =~ ^[01]$ ]] || BASELINE_SUDO_REQ=0
    [[ "$BASELINE_SUDO_USED" =~ ^[01]$ ]] || BASELINE_SUDO_USED=0
    [[ "$BASELINE_ROOT" =~ ^[01]$ ]] || BASELINE_ROOT=0

    for key in BASELINE_PASS BASELINE_WARN BASELINE_FAIL BASELINE_SKIP BASELINE_INFO; do
        value=${!key}
        [[ "$value" =~ ^[0-9]+$ ]] || printf -v "$key" '%s' 0
    done

    BASELINE_PATH=$(baseline_tsv_path)
    BASELINE_META_PATH=$meta
    [ -s "$BASELINE_PATH" ] || return 1
    return 0
}

baseline_load_checks() {
    local tsv id st sev title detail
    tsv=$(baseline_tsv_path)
    [ -r "$tsv" ] || return 1

    BASELINE_ORDER=()
    BASELINE_STATUS=()
    BASELINE_SEVERITY=()
    BASELINE_TITLE=()
    BASELINE_DETAIL=()

    while IFS=$'\t' read -r id st sev title detail; do
        [ -n "$id" ] || continue
        case "$st" in
            PASS|WARN|FAIL|SKIP|INFO) ;;
            *) continue ;;
        esac
        case "$sev" in
            critical|high|medium|low|info) ;;
            *) sev='info' ;;
        esac
        BASELINE_ORDER+=("$id")
        BASELINE_STATUS[$id]=$st
        BASELINE_SEVERITY[$id]=$sev
        BASELINE_TITLE[$id]=${title:-$id}
        BASELINE_DETAIL[$id]=${detail:-}
    done < "$tsv"

    [ "${#BASELINE_ORDER[@]}" -gt 0 ]
}

baseline_save() {
    local profile=$1 audit_rc=$2
    local dir tsv meta tmp_tsv tmp_meta id st sev title detail created epoch
    if ! baseline_prepare_dir; then
        warn "no se pudo crear $(baseline_display_path "$(baseline_root)")"
        return 1
    fi

    dir=$(baseline_host_dir)
    tsv="$dir/baseline.tsv"
    meta="$dir/baseline.meta"
    tmp_tsv="$tsv.tmp.$$"
    tmp_meta="$meta.tmp.$$"
    created=$(date '+%Y-%m-%d %H:%M:%S')
    epoch=$(date +%s)

    (
        umask 077

        {
            for id in "${ACTIVE_CHECK_IDS[@]}"; do
                st=$(status_of "$id")
                sev=${CHECK_SEVERITY[$id]:-info}
                title=${CHECK_TITLE[$id]:-}
                detail=$(detail_of "$id")
                title=${title//$'\t'/ }
                detail=${detail//$'\t'/ }
                printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$st" "$sev" "$title" "$detail"
            done
        } > "$tmp_tsv" || exit 1

        {
            printf 'schema=%s\n' "$BASELINE_SCHEMA"
            printf 'tool_version=%s\n' "${VERSION:-?}"
            printf 'host=%s\n' "$(baseline_host)"
            printf 'profile=%s\n' "$profile"
            printf 'created=%s\n' "$created"
            printf 'created_epoch=%s\n' "$epoch"
            printf 'checks_catalog=%s\n' "${#CHECK_IDS[@]}"
            printf 'checks_active=%s\n' "${#ACTIVE_CHECK_IDS[@]}"
            printf 'score=%s\n' "${GLOBAL_SCORE:-0}"
            printf 'exit_code=%s\n' "$audit_rc"
            printf 'pass=%s\n' "${COUNT[PASS]:-0}"
            printf 'warn=%s\n' "${COUNT[WARN]:-0}"
            printf 'fail=%s\n' "${COUNT[FAIL]:-0}"
            printf 'skip=%s\n' "${COUNT[SKIP]:-0}"
            printf 'info=%s\n' "${COUNT[INFO]:-0}"
            printf 'sudo_requested=%s\n' "${USE_SUDO:-0}"
            if [ "${SUDO_OK:-0}" -eq 1 ]; then
                printf 'sudo_used=1\n'
            else
                printf 'sudo_used=0\n'
            fi
            if is_root; then
                printf 'root=1\n'
            else
                printf 'root=0\n'
            fi
            printf 'distro=%s\n' "${DISTRO_NAME:-desconocida}"
            printf 'family=%s\n' "${DISTRO_FAMILY:-unknown}"
        } > "$tmp_meta" || exit 1

        chmod 600 -- "$tmp_tsv" "$tmp_meta" 2>/dev/null || true
        mv -f -- "$tmp_tsv" "$tsv" || exit 1
        mv -f -- "$tmp_meta" "$meta" || exit 1
    ) || {
        rm -f -- "$tmp_tsv" "$tmp_meta"
        warn "no se pudo guardar la baseline en $(baseline_display_path "$tsv")"
        return 1
    }

    BASELINE_PROFILE=$profile
    BASELINE_PATH=$tsv
    BASELINE_META_PATH=$meta
    BASELINE_CREATED=$created
    BASELINE_CREATED_EPOCH=$epoch
    BASELINE_SCORE=${GLOBAL_SCORE:-0}
    BASELINE_EXIT=$audit_rc
    BASELINE_VERSION=${VERSION:-?}
    BASELINE_HOST=$(baseline_host)
    BASELINE_SUDO_REQ=${USE_SUDO:-0}
    if [ "${SUDO_OK:-0}" -eq 1 ]; then
        BASELINE_SUDO_USED=1
    else
        BASELINE_SUDO_USED=0
    fi
    if is_root; then
        BASELINE_ROOT=1
    else
        BASELINE_ROOT=0
    fi
    BASELINE_ACTIVE=${#ACTIVE_CHECK_IDS[@]}
    BASELINE_CATALOG=${#CHECK_IDS[@]}
    BASELINE_PASS=${COUNT[PASS]:-0}
    BASELINE_WARN=${COUNT[WARN]:-0}
    BASELINE_FAIL=${COUNT[FAIL]:-0}
    BASELINE_SKIP=${COUNT[SKIP]:-0}
    BASELINE_INFO=${COUNT[INFO]:-0}
    return 0
}

# ---------------------------------------------------------------------------
# Mostrar y comparar
# ---------------------------------------------------------------------------

baseline_show() {
    local width path id sev title detail nfail=0 sudo_note=''
    if ! baseline_load_meta; then
        warn 'la baseline está incompleta o es de una versión incompatible'
        return 64
    fi
    if ! baseline_load_checks; then
        warn 'la baseline no contiene estados de checks'
        return 64
    fi
    if [ "${PROFILE_EXPLICIT:-0}" -eq 1 ] && [ "${PROFILE:-general}" != "$BASELINE_PROFILE" ]; then
        warn "la baseline guardada es del perfil $BASELINE_PROFILE, no $PROFILE"
        return 64
    fi

    width=$(term_width)
    path=$(baseline_display_path "$BASELINE_PATH")
    _term_section 'Baseline de auditoría' 40 "$width"
    printf '\n  %sRuta:%s %s\n' "$C_DIM" "$C_RESET" "$path"
    printf '  %sCreada:%s %s\n' "$C_DIM" "$C_RESET" "${BASELINE_CREATED:-desconocida}"
    printf '  %sPerfil:%s %s (%d checks)\n' \
        "$C_DIM" "$C_RESET" "$(profile_label "$BASELINE_PROFILE")" "$BASELINE_ACTIVE"
    printf '  %sScore:%s %d/100\n' "$C_DIM" "$C_RESET" "$BASELINE_SCORE"
    printf '  %sResultado:%s %d correctos · %d avisos · %d fallos · %d omitidos · %d info\n' \
        "$C_DIM" "$C_RESET" \
        "$BASELINE_PASS" "$BASELINE_WARN" "$BASELINE_FAIL" "$BASELINE_SKIP" "$BASELINE_INFO"

    if [ "$BASELINE_SUDO_REQ" -eq 1 ]; then
        if [ "$BASELINE_SUDO_USED" -eq 1 ]; then
            sudo_note='solicitado y disponible'
        else
            sudo_note='solicitado, sin caché al crear'
        fi
        printf '  %sSudo:%s %s\n' "$C_DIM" "$C_RESET" "$sudo_note"
    else
        printf '  %sSudo:%s no solicitado\n' "$C_DIM" "$C_RESET"
    fi

    for id in "${BASELINE_ORDER[@]}"; do
        [ "${BASELINE_STATUS[$id]}" = 'FAIL' ] || continue
        nfail=$(( nfail + 1 ))
    done

    if [ "$nfail" -eq 0 ]; then
        printf '\n  %sSin fallos en la baseline.%s\n' "$C_GREEN_B" "$C_RESET"
        return 0
    fi

    _term_section "Fallos en la baseline ($nfail)" 40 "$width"
    for id in "${BASELINE_ORDER[@]}"; do
        [ "${BASELINE_STATUS[$id]}" = 'FAIL' ] || continue
        sev=${BASELINE_SEVERITY[$id]:-info}
        title=${BASELINE_TITLE[$id]:-$id}
        detail=${BASELINE_DETAIL[$id]:-}
        printf '\n  %s [%s] %s · %s\n' \
            "$(status_icon FAIL)" "$(sev_label "$sev")" "$id" "$title"
        if [ -n "$detail" ]; then
            _term_wrap "$detail" 6 "$width"
        fi
    done
    return 0
}

baseline_print_saved() {
    local width path
    width=$(term_width)
    path=$(baseline_display_path "$BASELINE_PATH")
    _term_section 'Baseline guardada' 40 "$width"
    printf '\n  %sRuta:%s %s\n' "$C_DIM" "$C_RESET" "$path"
    printf '  %sPerfil:%s %s (%d checks)\n' \
        "$C_DIM" "$C_RESET" "$(profile_label "$BASELINE_PROFILE")" "$BASELINE_ACTIVE"
    printf '  %sScore:%s %d/100 · %d correctos · %d avisos · %d fallos · %d omitidos · %d info\n' \
        "$C_DIM" "$C_RESET" "$BASELINE_SCORE" \
        "$BASELINE_PASS" "$BASELINE_WARN" "$BASELINE_FAIL" "$BASELINE_SKIP" "$BASELINE_INFO"

    if [ "$BASELINE_SUDO_REQ" -eq 1 ]; then
        if [ "$BASELINE_SUDO_USED" -eq 1 ]; then
            printf '  %sSudo:%s solicitado y disponible\n' "$C_DIM" "$C_RESET"
        else
            printf '  %sSudo:%s solicitado, sin caché; los checks protegidos quedaron omitidos\n' \
                "$C_DIM" "$C_RESET"
        fi
    fi

    if [ "$BASELINE_FAIL" -gt 0 ]; then
        printf '\n  %sNota:%s la baseline conserva %d fallo(s); monitor solo avisará de cambios.\n' \
            "$C_YELLOW_B" "$C_RESET" "$BASELINE_FAIL"
    fi
    printf '\n  %sComparar:%s ./watch4me.sh monitor\n' \
        "$C_DIM" "$C_RESET"
}

baseline_compare() {
    local id st old old_rank new_rank kind
    local -A active=()

    BASELINE_N_WORSE=0
    BASELINE_N_BETTER=0
    BASELINE_N_SKIP=0
    BASELINE_N_EVAL=0
    BASELINE_N_NEW=0
    BASELINE_N_REMOVED=0
    BASELINE_N_ALERT=0
    BASELINE_CRIT_FAIL=0
    BASELINE_CHANGE=()
    BASELINE_OLD=()
    BASELINE_NEW=()

    for id in "${ACTIVE_CHECK_IDS[@]}"; do
        active[$id]=1
    done

    for id in "${ACTIVE_CHECK_IDS[@]}"; do
        old=''
        st=$(status_of "$id")
        if [ -z "${BASELINE_STATUS[$id]:-}" ]; then
            kind='new'
        else
            old=${BASELINE_STATUS[$id]}
            [ "$old" = "$st" ] && continue
            if [ "$old" = 'SKIP' ] && [ "$st" != 'SKIP' ]; then
                kind='eval'
            elif [ "$st" = 'SKIP' ] && [ "$old" != 'SKIP' ]; then
                kind='skip'
            else
                old_rank=$(baseline_status_rank "$old")
                new_rank=$(baseline_status_rank "$st")
                if [ "$new_rank" -gt "$old_rank" ]; then
                    kind='worse'
                elif [ "$new_rank" -lt "$old_rank" ]; then
                    kind='better'
                else
                    # PASS <-> INFO no altera la puntuación.
                    continue
                fi
            fi
        fi

        BASELINE_CHANGE[$id]=$kind
        BASELINE_OLD[$id]=$old
        BASELINE_NEW[$id]=$st

        case "$kind" in
            worse)  BASELINE_N_WORSE=$(( BASELINE_N_WORSE + 1 )) ;;
            better) BASELINE_N_BETTER=$(( BASELINE_N_BETTER + 1 )) ;;
            skip)   BASELINE_N_SKIP=$(( BASELINE_N_SKIP + 1 )) ;;
            eval)   BASELINE_N_EVAL=$(( BASELINE_N_EVAL + 1 )) ;;
            new)    BASELINE_N_NEW=$(( BASELINE_N_NEW + 1 )) ;;
        esac

        case "$kind" in
            worse|eval|new)
                case "$st" in
                    WARN|FAIL) BASELINE_N_ALERT=$(( BASELINE_N_ALERT + 1 )) ;;
                esac
                if [ "$st" = 'FAIL' ] \
                    && [ "${CHECK_SEVERITY[$id]:-info}" = 'critical' ]; then
                    BASELINE_CRIT_FAIL=1
                fi
                ;;
        esac
    done

    for id in "${BASELINE_ORDER[@]}"; do
        [ -n "${active[$id]:-}" ] && continue
        BASELINE_CHANGE[$id]='removed'
        BASELINE_OLD[$id]=${BASELINE_STATUS[$id]:-}
        BASELINE_NEW[$id]=''
        BASELINE_N_REMOVED=$(( BASELINE_N_REMOVED + 1 ))
    done

    BASELINE_SCORE_DELTA=$(( ${GLOBAL_SCORE:-0} - BASELINE_SCORE ))
    return 0
}

baseline_exit_code() {
    local rc=0
    if [ "$BASELINE_CRIT_FAIL" -eq 1 ]; then
        return 2
    fi
    [ "$BASELINE_N_ALERT" -gt 0 ] && rc=1
    [ "$BASELINE_N_SKIP" -gt 0 ] && rc=1
    [ "$BASELINE_N_REMOVED" -gt 0 ] && rc=1
    if [ "$rc" -eq 0 ] && [ "$BASELINE_SCORE_DELTA" -lt 0 ]; then
        rc=1
    fi
    return "$rc"
}

baseline_render_change() {
    local id=$1 width=$2
    local kind=${BASELINE_CHANGE[$id]:-}
    local old=${BASELINE_OLD[$id]:-}
    local new=${BASELINE_NEW[$id]:-}
    local sev title detail_before detail_after icon=''

    sev=${CHECK_SEVERITY[$id]:-${BASELINE_SEVERITY[$id]:-info}}
    title=${CHECK_TITLE[$id]:-${BASELINE_TITLE[$id]:-$id}}
    detail_before=${BASELINE_DETAIL[$id]:-}
    detail_after=''
    if [ "$kind" != 'removed' ]; then
        detail_after=$(detail_of "$id")
    fi

    case "$kind" in
        removed) icon=$(status_icon SKIP) ;;
        *)       icon=$(status_icon "$new") ;;
    esac

    printf '\n  %s [%s] %s · %s\n' "$icon" "$(sev_label "$sev")" "$id" "$title"

    if [ -n "$old" ]; then
        printf '    %s%s%s' "$(baseline_status_color "$old")" "$(status_label "$old")" "$C_RESET"
    else
        printf '    %snuevo%s' "$C_DIM" "$C_RESET"
    fi
    printf ' %s ' "$(baseline_arrow)"
    if [ -n "$new" ]; then
        printf '%s%s%s\n' "$(baseline_status_color "$new")" "$(status_label "$new")" "$C_RESET"
    else
        printf '%ssin referencia%s\n' "$C_DIM" "$C_RESET"
    fi

    if [ -n "$detail_before" ]; then
        printf '    %sAntes:%s\n' "$C_DIM" "$C_RESET"
        _term_wrap "$detail_before" 6 "$width"
    fi
    if [ -n "$detail_after" ]; then
        printf '    %sAhora:%s\n' "$C_DIM" "$C_RESET"
        _term_wrap "$detail_after" 6 "$width"
    fi
}

baseline_render_section() {
    local title=$1 kind=$2 width=$3
    local id
    local -a ids=()

    if [ "$kind" = 'removed' ]; then
        for id in "${BASELINE_ORDER[@]}"; do
            [ "${BASELINE_CHANGE[$id]:-}" = "$kind" ] && ids+=("$id")
        done
    else
        for id in "${ACTIVE_CHECK_IDS[@]}"; do
            [ "${BASELINE_CHANGE[$id]:-}" = "$kind" ] && ids+=("$id")
        done
    fi

    [ "${#ids[@]}" -gt 0 ] || return 0
    _term_section "$title (${#ids[@]})" 40 "$width"
    for id in "${ids[@]}"; do
        baseline_render_change "$id" "$width"
    done
}

baseline_render() {
    local rc=$1 width path now days changes active_n
    width=$(term_width)
    path=$(baseline_display_path "$BASELINE_PATH")
    active_n=${#ACTIVE_CHECK_IDS[@]}

    _term_section 'Comparación con la baseline' 40 "$width"
    printf '\n  %sBaseline:%s %s\n' "$C_DIM" "$C_RESET" "$path"
    printf '  %sCreada:%s %s' "$C_DIM" "$C_RESET" "${BASELINE_CREATED:-desconocida}"
    if [ "$BASELINE_CREATED_EPOCH" -gt 0 ]; then
        now=$(date +%s)
        days=$(( (now - BASELINE_CREATED_EPOCH) / 86400 ))
        [ "$days" -lt 0 ] && days=0
        if [ "$days" -eq 0 ]; then
            printf ' %s(hoy)%s' "$C_DIM" "$C_RESET"
        elif [ "$days" -eq 1 ]; then
            printf ' %s(hace 1 día)%s' "$C_DIM" "$C_RESET"
        else
            printf ' %s(hace %d días)%s' "$C_DIM" "$C_RESET" "$days"
        fi
    fi
    printf '\n'
    printf '  %sPerfil:%s %s (%d checks) · %sScore:%s %d/100 %s %d/100 (%+d)\n' \
        "$C_DIM" "$C_RESET" "$(profile_label "$BASELINE_PROFILE")" "$active_n" \
        "$C_DIM" "$C_RESET" "$BASELINE_SCORE" "$(baseline_arrow)" \
        "$GLOBAL_SCORE" "$BASELINE_SCORE_DELTA"

    if [ "$BASELINE_SUDO_AUTO" -eq 1 ]; then
        printf '  %sSudo:%s activado para igualar la baseline.\n' "$C_DIM" "$C_RESET"
    elif [ "$BASELINE_SUDO_REQ" -eq 0 ] && [ "${USE_SUDO:-0}" -eq 1 ]; then
        printf '  %sSudo:%s --sudo activo; la baseline se creó sin sudo.\n' "$C_DIM" "$C_RESET"
    fi
    if [ "$BASELINE_SUDO_REQ" -eq 1 ] && [ "${SUDO_OK:-0}" -eq 0 ] && ! is_root; then
        printf '  %sAviso:%s la baseline se creó con sudo y ahora no hay caché; algunos checks pueden salir omitidos.\n' \
            "$C_YELLOW_B" "$C_RESET"
    fi
    if [ "$BASELINE_ACTIVE" -ne "$active_n" ]; then
        printf '  %sAviso:%s la baseline tiene %d checks y el perfil actual %d; puede haber cambios de catálogo.\n' \
            "$C_YELLOW_B" "$C_RESET" "$BASELINE_ACTIVE" "$active_n"
    fi

    changes=$(( BASELINE_N_WORSE + BASELINE_N_BETTER + BASELINE_N_SKIP \
        + BASELINE_N_EVAL + BASELINE_N_NEW + BASELINE_N_REMOVED ))

    if [ "$changes" -eq 0 ]; then
        printf '\n  %sSin cambios respecto a la baseline.%s\n' "$C_GREEN_B" "$C_RESET"
        if [ "$BASELINE_SCORE_DELTA" -ne 0 ]; then
            printf '  %sEl score cambió sin cambios de estado; revisa el catálogo o las severidades.%s\n' \
                "$C_YELLOW_B" "$C_RESET"
        fi
    else
        printf '\n  %sCambios:%s %d empeoran · %d omitidos · %d se evalúan · %d nuevos · %d mejoran · %d sin referencia\n' \
            "$C_DIM" "$C_RESET" "$BASELINE_N_WORSE" "$BASELINE_N_SKIP" \
            "$BASELINE_N_EVAL" "$BASELINE_N_NEW" "$BASELINE_N_BETTER" "$BASELINE_N_REMOVED"
        baseline_render_section 'Empeoran' 'worse' "$width"
        baseline_render_section 'Ahora no evaluables' 'skip' "$width"
        baseline_render_section 'Se evalúan ahora' 'eval' "$width"
        baseline_render_section 'Nuevos' 'new' "$width"
        baseline_render_section 'Mejoran' 'better' "$width"
        baseline_render_section 'Ya no están en el perfil' 'removed' "$width"
    fi

    printf '\n  %sResultado:%s ' "$C_BOLD" "$C_RESET"
    case "$rc" in
        2) printf '%shay un fallo crítico nuevo; actúa cuanto antes.%s\n' "$C_RED_B$C_BOLD" "$C_RESET" ;;
        1) printf '%shay regresiones o pérdida de cobertura; revisa los cambios.%s\n' "$C_YELLOW_B" "$C_RESET" ;;
        *) printf '%ssin regresiones respecto a la baseline.%s\n' "$C_GREEN_B" "$C_RESET" ;;
    esac
}

# ---------------------------------------------------------------------------
# Modos
# ---------------------------------------------------------------------------

ensure_checks_loaded() {
    [ "${#CHECK_IDS[@]}" -gt 0 ] && return 0
    load_checks
}

baseline_main() {
    ensure_checks_loaded || return 64

    if [ "${BASELINE_SHOW:-0}" -eq 1 ]; then
        if ! baseline_exists; then
            warn "no hay baseline para $(baseline_host); crea una con ./watch4me.sh baseline"
            return 64
        fi
        baseline_show
        return $?
    fi

    local profile=${PROFILE:-general}
    if baseline_exists && [ "${FORCE:-0}" -eq 0 ]; then
        local created='' existing_profile='' ans=''
        created=$(sed -n 's/^created=//p' "$(baseline_meta_path)" | head -n 1)
        existing_profile=$(sed -n 's/^profile=//p' "$(baseline_meta_path)" | head -n 1)
        if [ -t 0 ] && [ -t 1 ]; then
            printf '%sYa existe una baseline de %s%s' \
                "$C_BOLD" "$(baseline_host)" "$C_RESET"
            [ -n "$existing_profile" ] \
                && printf ' · perfil %s' "$(profile_label "$existing_profile")"
            [ -n "$created" ] && printf ' · creada %s' "$created"
            printf '.\n¿Sobrescribirla? [s/N] '
            read -r ans || ans=''
            case "$ans" in
                s|S|si|sí|Si|Sí|y|Y|yes|YES|Yes) ;;
                *)
                    printf '\nBaseline no modificada.\n'
                    return 0
                    ;;
            esac
        else
            warn "ya existe una baseline de $(baseline_host); usa --force para sobrescribirla"
            return 64
        fi
    fi

    profile_set "$profile" || return 64
    local anim_save=$UI_ANIM
    UI_ANIM=0
    init_run_dir
    if ! run_checks; then
        UI_ANIM=$anim_save
        return 64
    fi
    compute_scores
    compute_exit_code
    local audit_rc=$?
    if ! baseline_save "$profile" "$audit_rc"; then
        UI_ANIM=$anim_save
        return 64
    fi
    baseline_print_saved
    UI_ANIM=$anim_save
    return 0
}

monitor_main() {
    ensure_checks_loaded || return 64

    if ! baseline_exists; then
        warn "no hay baseline para $(baseline_host); crea una con ./watch4me.sh baseline"
        return 64
    fi
    if ! baseline_load_meta; then
        warn 'la baseline está incompleta o es de una versión incompatible'
        return 64
    fi
    if ! baseline_load_checks; then
        warn 'la baseline no contiene estados de checks'
        return 64
    fi
    if [ "${PROFILE_EXPLICIT:-0}" -eq 1 ] && [ "${PROFILE:-general}" != "$BASELINE_PROFILE" ]; then
        warn "la baseline guardada es del perfil $BASELINE_PROFILE, no $PROFILE"
        return 64
    fi

    PROFILE=$BASELINE_PROFILE
    BASELINE_SUDO_AUTO=0
    if [ "$BASELINE_SUDO_REQ" -eq 1 ] && [ "${USE_SUDO:-0}" -eq 0 ]; then
        USE_SUDO=1
        SUDO_CHECKED=0
        SUDO_OK=0
        BASELINE_SUDO_AUTO=1
    fi

    profile_set "$PROFILE" || return 64
    local anim_save=$UI_ANIM
    UI_ANIM=0
    init_run_dir
    if ! run_checks; then
        UI_ANIM=$anim_save
        return 64
    fi
    compute_scores
    baseline_compare
    baseline_exit_code
    local rc=$?
    baseline_render "$rc"
    UI_ANIM=$anim_save
    return "$rc"
}
