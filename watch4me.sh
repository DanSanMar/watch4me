#!/usr/bin/env bash
# watch4me — auditoría de seguridad local
# Copyright (C) 2026
# Licencia: GPLv3
#
# La cabecera animada deriva de dash4me (GPLv3):
# https://github.com/DanSanMar/dash4me — Copyright (C) DanSanMar

set -uo pipefail

VERSION='0.4.0'

if [ "${BASH_VERSINFO[0]}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    printf 'watch4me: se requiere bash >= 4.4\n' >&2
    exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=lib/menu.sh
. "$LIB_DIR/menu.sh"
# shellcheck source=lib/ui.sh
. "$LIB_DIR/ui.sh"
# shellcheck source=lib/distro.sh
. "$LIB_DIR/distro.sh"
# shellcheck source=lib/checks.sh
. "$LIB_DIR/checks.sh"
# shellcheck source=lib/render-term.sh
. "$LIB_DIR/render-term.sh"
# shellcheck source=lib/render-md.sh
. "$LIB_DIR/render-md.sh"

MODE=''
PROFILE='full'
SAVE_TO=''
NO_ANIM_FLAG=0
NO_COLOR_FLAG=0
USE_SUDO=0
EXPLAIN_LIST=0
declare -a EXPLAIN_IDS=()
PREVIEW_KIND=''
PREVIEW_ARG=''
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || printf 'localhost')
RUN_DIR=''

usage() {
    cat <<EOF
watch4me v$VERSION — auditoría de seguridad local (solo lectura)

USO
  ./watch4me.sh                 menú interactivo (TTY) o auditoría (sin TTY)
  ./watch4me.sh menu            fuerza el menú interactivo (requiere fzf)
  ./watch4me.sh audit [opciones]
  ./watch4me.sh explain <ID> [<ID>...]
  ./watch4me.sh explain --list
  ./watch4me.sh --help

OPCIONES
  -m, --menu             abre el menú interactivo (requiere fzf)
  --profile quick|full   quick reduce los timeouts de red (por defecto: full)
  --save [ruta]          guarda el informe Markdown sin preguntar
                         sin ruta usa reports/; con "-" lo escribe por stdout
  --no-anim              desactiva la cabecera animada
  --no-color             desactiva los colores (también NO_COLOR=1)
  --sudo                 permite lecturas con sudo -n (nunca pide contraseña)
  -h, --help             muestra esta ayuda
  -v, --version          muestra la versión

MENÚ
  El menú usa fzf, que es opcional: la auditoría funciona sin él.
  Si fzf no está instalado, el menú ofrece instalarlo con el gestor de
  la distribución tras confirmación explícita. Es la única acción del
  programa que modifica el sistema; las auditorías son solo lectura.
  Para desactivar esa oferta: WATCH4ME_NO_INSTALL=1 ./watch4me.sh menu

EJEMPLOS
  ./watch4me.sh
  ./watch4me.sh audit --profile quick
  ./watch4me.sh audit --save
  ./watch4me.sh audit --save - > informe.md
  ./watch4me.sh explain --list
  ./watch4me.sh explain NET-01 SVC-07

SALIDA
  0  sin hallazgos relevantes
  1  avisos o fallos no críticos
  2  al menos un fallo crítico

VARIABLES
  NO_COLOR=1                desactiva colores
  WATCH4ME_ALLOW_PORTS      puertos expuestos considerados esperados (def. "22")
EOF
}

parse_args() {
    local arg_count=$#
    while [ $# -gt 0 ]; do
        case "$1" in
            __preview)
                MODE=preview
                PREVIEW_KIND=${2:-}
                PREVIEW_ARG=${3:-}
                shift 2 2>/dev/null || true
                ;;
            audit) MODE=audit ;;
            menu|--menu|-m) MODE=menu ;;
            baseline|monitor)
                MODE=$1
                ;;
            explain)
                MODE=explain
                while [ $# -gt 1 ]; do
                    case "$2" in
                        --list)
                            EXPLAIN_LIST=1
                            shift
                            ;;
                        -*)
                            break
                            ;;
                        *)
                            EXPLAIN_IDS+=("$2")
                            shift
                            ;;
                    esac
                done
                ;;
            --profile)
                [ $# -ge 2 ] || die '--profile requiere quick|full'
                PROFILE=$2
                shift
                ;;
            --profile=*)
                PROFILE=${1#*=}
                ;;
            --save)
                if [ $# -ge 2 ] && { [ "${2#-}" = "$2" ] || [ "$2" = '-' ]; }; then
                    SAVE_TO=$2
                    shift
                else
                    SAVE_TO='reports'
                fi
                ;;
            --save=*)
                SAVE_TO=${1#*=}
                ;;
            --no-anim) NO_ANIM_FLAG=1 ;;
            --no-color) NO_COLOR_FLAG=1 ;;
            --sudo) USE_SUDO=1 ;;
            -h|--help) MODE=help ;;
            -v|--version) MODE=version ;;
            *)
                die "opción desconocida: $1 (usa --help)"
                ;;
        esac
        shift
    done

    [ -n "$MODE" ] || {
        if [ "$arg_count" -eq 0 ] \
            && [ -t 0 ] && [ -t 1 ] \
            && [ "${TERM:-dumb}" != 'dumb' ]; then
            MODE=menu
        else
            MODE=audit
        fi
    }

    case "$PROFILE" in
        quick|full) ;;
        *) die "perfil desconocido: $PROFILE (usa quick o full)" ;;
    esac
}

load_checks() {
    local f
    for f in "$SCRIPT_DIR"/checks/*.sh; do
        [ -r "$f" ] || continue
        # shellcheck source=/dev/null
        . "$f"
    done
}

init_run_dir() {
    local base="$SCRIPT_DIR/state/tmp"
    if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then
        chmod 700 "$base" 2>/dev/null || true
        RUN_DIR=$(mktemp -d "$base/run.XXXXXX" 2>/dev/null) || RUN_DIR=''
    fi
    if [ -z "$RUN_DIR" ]; then
        RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/watch4me.XXXXXX" 2>/dev/null) \
            || die 'no se pudo crear el directorio temporal'
    fi
    chmod 700 "$RUN_DIR" 2>/dev/null || true
}

run_checks() {
    if [ "${#CHECK_IDS[@]}" -eq 0 ]; then
        warn 'no se cargó ningún check'
        return 1
    fi

    local total=${#CHECK_IDS[@]}
    printf '0\n' > "$RUN_DIR/progress"
    : > "$RUN_DIR/current"

    # Cabecera y primer frame antes de lanzar los checks: la ejecución
    # nunca empieza con la pantalla en blanco.
    if [ "$UI_QUIET" -eq 0 ]; then
        if [ "$UI_ANIM" -eq 1 ]; then
            ui_header_open
            ui_frame 0 0 "$total"
        else
            ui_header_plain
            [ "$UI_PROGRESS" -eq 1 ] && ui_progress_frame 0 "$total" 0
        fi
    fi

    (
        trap - EXIT INT TERM HUP
        local n=0 id
        for id in "${CHECK_IDS[@]}"; do
            printf '%s\n' "$id" > "$RUN_DIR/current"
            run_single_check "$id"
            n=$(( n + 1 ))
            printf '%s\n' "$n" > "$RUN_DIR/progress"
        done
        : > "$RUN_DIR/current"
    ) &
    local pid=$!
    BG_PID=$pid

    local frame=0 start_ms now_ms done_n elapsed tail_ms tail_end
    start_ms=$(date +%s%3N)

    while kill -0 "$pid" 2>/dev/null; do
        frame=$(( frame + 1 ))
        done_n=$(cat "$RUN_DIR/progress" 2>/dev/null || printf '0')
        [[ "$done_n" =~ ^[0-9]+$ ]] || done_n=0
        UI_CURRENT=$(cat "$RUN_DIR/current" 2>/dev/null || true)
        now_ms=$(date +%s%3N)
        elapsed=$(( (now_ms - start_ms) / 1000 ))
        UI_ELAPSED=$elapsed

        if [ "$UI_QUIET" -eq 0 ]; then
            if [ "$UI_ANIM" -eq 1 ]; then
                ui_frame "$frame" "$done_n" "$total"
            elif [ "$UI_PROGRESS" -eq 1 ]; then
                ui_progress_frame "$done_n" "$total" "$elapsed"
            fi
        fi
        sleep 0.12
    done
    wait "$pid" 2>/dev/null || true
    BG_PID=''
    UI_CURRENT=''

    now_ms=$(date +%s%3N)
    elapsed=$(( (now_ms - start_ms) / 1000 ))
    UI_ELAPSED=$elapsed

    if [ "$UI_QUIET" -eq 0 ]; then
        if [ "$UI_ANIM" -eq 1 ]; then
            # Duración mínima para que el logo se vea antes del informe.
            # La velocidad de frame no cambia (sleep 0.05).
            while [ $(( now_ms - start_ms )) -lt "${UI_ANIM_MIN_MS:-2000}" ]; do
                frame=$(( frame + 1 ))
                ui_frame "$frame" "$total" "$total"
                sleep 0.05
                now_ms=$(date +%s%3N)
            done
            # Alarga un poco la permanencia del logo al terminar los checks.
            tail_ms=${UI_ANIM_TAIL_MS:-800}
            tail_end=$(( now_ms + tail_ms ))
            while [ "$now_ms" -lt "$tail_end" ]; do
                frame=$(( frame + 1 ))
                ui_frame "$frame" "$total" "$total"
                sleep 0.05
                now_ms=$(date +%s%3N)
            done
            ui_frame "$frame" "$total" "$total"
            ui_header_close
        elif [ "$UI_PROGRESS" -eq 1 ]; then
            ui_progress_close
        fi
    fi

    now_ms=$(date +%s%3N)
    ELAPSED=$(( (now_ms - start_ms) / 1000 ))
}

resolve_report_path() {
    local target=$1 ts name dir
    ts=$(date +%Y%m%d-%H%M)
    name="watch4me-${HOSTNAME_SHORT}-${ts}.md"

    if [ "$target" = 'reports' ]; then
        mkdir -p "$SCRIPT_DIR/reports" 2>/dev/null || die 'no se pudo crear reports/'
        printf '%s/reports/%s' "$SCRIPT_DIR" "$name"
        return
    fi

    if [ -d "$target" ]; then
        printf '%s/%s' "${target%/}" "$name"
        return
    fi

    dir=$(dirname -- "$target")
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || die "no se pudo crear el directorio $dir"
    fi

    if [ "${target%.md}" = "$target" ]; then
        target="${target}.md"
    fi
    if [ -e "$target" ]; then
        target="${target%.md}-$(date +%S).md"
    fi
    printf '%s' "$target"
}

save_report() {
    local path=$1
    render_md > "$path" || die "no se pudo escribir $path"
    printf '\n%sInforme guardado en:%s %s\n' "$C_GREEN_B" "$C_RESET" "$path"
}

maybe_save() {
    local path=''
    if [ -n "$SAVE_TO" ]; then
        path=$(resolve_report_path "$SAVE_TO")
    elif [ -t 0 ] && [ -t 1 ]; then
        local suggested="reports/watch4me-${HOSTNAME_SHORT}-$(date +%Y%m%d-%H%M).md"
        local ans=''
        printf '\n'
        read -r -p "¿Guardar informe en ${suggested}? [s/N] " ans || ans=''
        case "$ans" in
            s|S|si|sí|Si|Sí|y|Y|yes|YES|Yes) path=$(resolve_report_path reports) ;;
        esac
    fi

    [ -n "$path" ] && save_report "$path"
    return 0
}

explain_list() {
    local dom id sev
    printf '%sCatálogo de checks%s (%d)\n' "$C_BOLD" "$C_RESET" "${#CHECK_IDS[@]}"
    printf '%sCada check se puede detallar con: ./watch4me.sh explain <ID>%s\n' "$C_DIM" "$C_RESET"

    for dom in SYS USR NET SVC FS AUTH INT MAL; do
        local -a ids=()
        for id in "${CHECK_IDS[@]}"; do
            [ "$(domain_of "$id")" = "$dom" ] && ids+=("$id")
        done
        [ "${#ids[@]}" -gt 0 ] || continue

        printf '\n%s── %s (%s)%s\n' "$C_BOLD$C_CYAN_B" "${DOMAIN_NAME[$dom]:-$dom}" "$dom" "$C_RESET"
        for id in "${ids[@]}"; do
            sev=$(sev_label "${CHECK_SEVERITY[$id]}")
            printf '  %s%-7s%s %s[%s]%s %s\n' \
                "$C_BOLD" "$id" "$C_RESET" "$C_DIM" "$sev" "$C_RESET" "${CHECK_TITLE[$id]}"
        done
    done

    printf '\n%sID de dominio:%s SYS sistema · USR usuarios · NET red · SVC servicios\n' "$C_DIM" "$C_RESET"
    printf '%s             %s FS ficheros · AUTH autenticación · INT integridad · MAL malware\n' "$C_DIM" "$C_RESET"
}

explain_check() {
    local id=$1

    printf '%s%s%s · %s\n' "$C_BOLD" "$id" "$C_RESET" "${CHECK_TITLE[$id]}"
    printf '%sSeveridad:%s %s\n' "$C_DIM" "$C_RESET" "$(sev_label "${CHECK_SEVERITY[$id]}")"
    printf '%sDominio:%s   %s\n\n' "$C_DIM" "$C_RESET" "${DOMAIN_NAME[${id%%-*}]:-${id%%-*}}"

    if [ -n "${CHECK_DESC[$id]}" ]; then
        printf '%s\n\n' "${CHECK_DESC[$id]}"
    fi

    if [ -n "${CHECK_REMED[$id]}" ]; then
        printf '%sRemedio sugerido:%s\n' "$C_BOLD" "$C_RESET"
        printf '%s\n' "${CHECK_REMED[$id]}" | while IFS= read -r line; do
            printf '  %s\n' "$line"
        done
    fi
}

explain_checks() {
    if [ "$EXPLAIN_LIST" -eq 1 ]; then
        explain_list
        return 0
    fi

    local id rc=0 first=1
    for id in "${EXPLAIN_IDS[@]}"; do
        if [ -z "${CHECK_TITLE[$id]:-}" ]; then
            printf 'watch4me: check desconocido: %s\n' "$id" >&2
            rc=1
            continue
        fi
        [ "$first" -eq 1 ] || printf '\n'
        first=0
        explain_check "$id"
    done
    return "$rc"
}

main() {
    parse_args "$@"

    # Con --save - la salida estándar es el propio informe Markdown:
    # prohibido emitir animación o cabecera por stdout.
    [ "$SAVE_TO" = '-' ] && NO_ANIM_FLAG=1

    ui_init
    if [ "$SAVE_TO" = '-' ]; then
        # stdout es el informe Markdown: ni cabecera ni progreso.
        UI_QUIET=1
        UI_PROGRESS=0
    fi
    ui_trap_install
    detect_distro

    case "$MODE" in
        help)
            usage
            return 0
            ;;
        version)
            printf 'watch4me %s\n' "$VERSION"
            return 0
            ;;
        preview)
            load_checks
            menu_preview "$PREVIEW_KIND" "$PREVIEW_ARG"
            return $?
            ;;
        menu)
            load_checks
            menu_main
            return $?
            ;;
        baseline|monitor)
            printf 'watch4me: el modo %s se implementa en el hito M3 (baseline y vigilancia).\n' "$MODE" >&2
            return 64
            ;;
        explain)
            load_checks
            if [ "$EXPLAIN_LIST" -eq 0 ] && [ "${#EXPLAIN_IDS[@]}" -eq 0 ]; then
                die 'uso: watch4me explain <ID> [<ID>...] | explain --list'
            fi
            explain_checks
            return $?
            ;;
    esac

    load_checks
    init_run_dir

    run_checks

    if [ "$SAVE_TO" = '-' ]; then
        compute_scores
        render_md
        compute_exit_code
        return $?
    fi

    compute_scores
    render_terminal
    maybe_save

    compute_exit_code
    return $?
}

main "$@"
exit $?
