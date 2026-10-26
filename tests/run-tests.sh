#!/usr/bin/env bash
# watch4me — pruebas de regresión
#
# Suite sin dependencias externas: solo bash >= 4.4 y las herramientas que
# ya usa el propio programa. No modifica el sistema: los informes de prueba
# van a un directorio temporal que se borra al terminar.
#
# Uso:
#   ./tests/run-tests.sh
#   ./tests/run-tests.sh --filter watch
#
# Licencia: GPLv3

# Las librerías se cargan dinámicamente y los stubs se invocan indirectamente.
# shellcheck disable=SC1091,SC2034,SC2317

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="$ROOT/watch4me.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/watch4me-tests.XXXXXX") || {
    printf 'watch4me-tests: no se pudo crear el directorio temporal\n' >&2
    exit 1
}
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
cd -- "$ROOT" || exit 1

VERSION=$(sed -n "s/^VERSION='\([^']*\)'.*/\1/p" "$SCRIPT" | head -n 1)
FILTER=''

# ---------------------------------------------------------------------------
# Marco de pruebas
# ---------------------------------------------------------------------------

TESTS=0
PASSED=0
FAILED=0
SKIPPED=0

assert_eq() {
    local got=$1 want=$2
    if [ "$got" != "$want" ]; then
        printf 'esperado: %s\nobtenido: %s\n' "$want" "$got"
        return 1
    fi
}

assert_ne() {
    local got=$1 other=$2
    if [ "$got" = "$other" ]; then
        printf 'no debería ser igual a: %s\n' "$other"
        return 1
    fi
}

assert_contains() {
    local text=$1 needle=$2
    case "$text" in
        *"$needle"*) return 0 ;;
    esac
    printf 'no contiene: %s\nen: %s\n' "$needle" "$text"
    return 1
}

assert_not_contains() {
    local text=$1 needle=$2
    case "$text" in
        *"$needle"*)
            printf 'no debería contener: %s\nen: %s\n' "$needle" "$text"
            return 1
            ;;
    esac
}

assert_no_ansi() {
    case "$1" in
        *$'\e'*)
            printf 'la salida contiene secuencias ANSI\n'
            return 1
            ;;
    esac
}

assert_file() {
    [ -s "$1" ] || {
        printf 'no existe o está vacío: %s\n' "$1"
        return 1
    }
}

assert_exit() {
    local got=$1 want=$2
    if [ "$got" -ne "$want" ]; then
        printf 'código de salida esperado: %s\nobtenido: %s\n' "$want" "$got"
        return 1
    fi
}

assert_in() {
    local got=$1 allowed=" $2 "
    case "$allowed" in
        *" $got "*) return 0 ;;
    esac
    printf 'valor no permitido: %s (esperado uno de: %s)\n' "$got" "$2"
    return 1
}

run_test() {
    local name=$1 fn=$2 out rc
    TESTS=$(( TESTS + 1 ))
    out=$("$fn" 2>&1)
    rc=$?
    # Los dobles de ss/ip son ejecutables temporales: no deben sobrevivir a la
    # prueba ni aparecer en auditorías posteriores (MAL-03).
    rm -rf -- "$TMP/fakebin"
    case "$rc" in
        0)
            PASSED=$(( PASSED + 1 ))
            printf 'ok %d - %s\n' "$TESTS" "$name"
            ;;
        77)
            SKIPPED=$(( SKIPPED + 1 ))
            printf 'ok %d - %s # SKIP %s\n' "$TESTS" "$name" "${out:-sin dependencia}"
            ;;
        *)
            FAILED=$(( FAILED + 1 ))
            printf 'not ok %d - %s\n' "$TESTS" "$name"
            printf '%s\n' "$out" | sed 's/^/  # /'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Utilidades de carga
# ---------------------------------------------------------------------------

# Carga las librerías sin ejecutar main. Cada prueba corre en un subshell,
# así que puede modificar arrays y variables sin contaminar al resto.
load_libs() {
    # shellcheck source=../lib/common.sh
    . "$ROOT/lib/common.sh"
    # shellcheck source=../lib/checks.sh
    . "$ROOT/lib/checks.sh"
    # shellcheck source=../lib/profiles.sh
    . "$ROOT/lib/profiles.sh"
    # shellcheck source=../lib/watch.sh
    . "$ROOT/lib/watch.sh"
}

load_catalog() {
    load_libs
    local f
    for f in "$ROOT"/checks/*.sh; do
        # shellcheck disable=SC1090
        . "$f"
    done
}

new_run_dir() {
    local d="$TMP/run-$1"
    rm -rf -- "$d"
    mkdir -p -- "$d" || return 1
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Catálogo y perfiles
# ---------------------------------------------------------------------------

test_catalog() {
    load_catalog

    assert_eq "${#CHECK_IDS[@]}" 74 || return 1
    local id f
    local -A seen=()
    for id in "${CHECK_IDS[@]}"; do
        [ -z "${seen[$id]:-}" ] || {
            printf 'ID duplicado: %s\n' "$id"
            return 1
        }
        seen[$id]=1

        [[ "$id" =~ ^[A-Z]{2,4}-[0-9]{2}$ ]] || {
            printf 'ID con formato inválido: %s\n' "$id"
            return 1
        }
        case "${id%%-*}" in
            SYS|USR|NET|SVC|FS|AUTH|INT|MAL) ;;
            *)
                printf 'dominio desconocido en %s\n' "$id"
                return 1
                ;;
        esac

        case "${CHECK_SEVERITY[$id]:-}" in
            critical|high|medium|low|info) ;;
            *)
                printf 'severidad inválida en %s: %s\n' "$id" "${CHECK_SEVERITY[$id]:-}"
                return 1
                ;;
        esac

        f=${CHECK_FUNC[$id]:-}
        if [ -z "$f" ] || ! declare -F "$f" >/dev/null 2>&1; then
            printf 'función no definida para %s: %s\n' "$id" "${f:-<vacía>}"
            return 1
        fi
        [ -n "${CHECK_TITLE[$id]:-}" ] || {
            printf 'check sin título: %s\n' "$id"
            return 1
        }
        [ -n "${CHECK_DESC[$id]:-}" ] || {
            printf 'check sin descripción: %s\n' "$id"
            return 1
        }
        [ -n "${CHECK_REMED[$id]:-}" ] || {
            printf 'check sin remedio: %s\n' "$id"
            return 1
        }
    done
}

test_profile_counts() {
    load_catalog

    local profile want got
    for pair in 'general 74' 'servidor 67' 'cliente 41' 'domestico 35' 'esencial 14'; do
        profile=${pair%% *}
        want=${pair##* }
        got=$(profile_count "$profile")
        assert_eq "$got" "$want" || return 1
    done

    assert_eq "$(profile_normalize full)" 'general' || return 1
    assert_eq "$(profile_normalize quick)" 'esencial' || return 1
    assert_eq "$(profile_normalize general)" 'general' || return 1
}

test_profile_membership() {
    load_catalog

    assert_eq "$(profile_tags SYS-13)" 'CD' || return 1
    assert_eq "$(profile_tags SVC-05)" 'S' || return 1
    assert_eq "$(profile_tags NET-09)" 'CD' || return 1

    profile_applies servidor SYS-13 && {
        printf 'SYS-13 no debería estar en servidor\n'
        return 1
    }
    profile_applies cliente SYS-13 || {
        printf 'SYS-13 debería estar en cliente\n'
        return 1
    }
    profile_applies domestico SYS-13 || {
        printf 'SYS-13 debería estar en doméstico\n'
        return 1
    }

    assert_contains "$(profile_names NET-09)" 'Cliente' || return 1
    assert_contains "$(profile_names NET-09)" 'PC doméstico' || return 1
    assert_not_contains "$(profile_names NET-09)" 'Servidor' || return 1
}

test_profile_set() {
    load_catalog

    local profile want excluded got id
    for pair in 'general 74 0' 'servidor 67 7' 'cliente 41 33' 'domestico 35 39' 'esencial 14 60'; do
        read -r profile want excluded <<< "$pair"
        profile_set "$profile" || return 1
        got=${#ACTIVE_CHECK_IDS[@]}
        assert_eq "$got" "$want" || return 1
        assert_eq "${#PROFILE_EXCLUDED_IDS[@]}" "$excluded" || return 1
        for id in "${ACTIVE_CHECK_IDS[@]}"; do
            in_list "$id" "${CHECK_IDS[*]}" || {
                printf '%s activo pero fuera del catálogo (perfil %s)\n' "$id" "$profile"
                return 1
            }
        done
    done

    # Un perfil inválido sale con 64 sin dejar el perfil a medias.
    ( profile_set inexistente ) >/dev/null 2>&1
    assert_exit "$?" 64 || return 1
}

# ---------------------------------------------------------------------------
# Scoring, contrato de checks e informes
# ---------------------------------------------------------------------------

test_scoring() {
    load_libs
    RUN_DIR=$(new_run_dir scoring) || return 1

    CHECK_IDS=(SYS-01 SYS-02 SYS-03 SYS-04 SYS-05)
    ACTIVE_CHECK_IDS=("${CHECK_IDS[@]}")
    declare -gA CHECK_SEVERITY=(
        [SYS-01]=critical [SYS-02]=high [SYS-03]=medium [SYS-04]=low [SYS-05]=info
    )
    declare -gA CHECK_DOMAIN=(
        [SYS-01]=SYS [SYS-02]=SYS [SYS-03]=SYS [SYS-04]=SYS [SYS-05]=SYS
    )

    printf 'FAIL\n' > "$RUN_DIR/SYS-01.status"
    printf 'WARN\n' > "$RUN_DIR/SYS-02.status"
    printf 'PASS\n' > "$RUN_DIR/SYS-03.status"
    printf 'SKIP\n' > "$RUN_DIR/SYS-04.status"
    printf 'INFO\n' > "$RUN_DIR/SYS-05.status"

    compute_scores
    assert_eq "${COUNT[PASS]}" 1 || return 1
    assert_eq "${COUNT[WARN]}" 1 || return 1
    assert_eq "${COUNT[FAIL]}" 1 || return 1
    assert_eq "${COUNT[SKIP]}" 1 || return 1
    assert_eq "${COUNT[INFO]}" 1 || return 1
    assert_eq "$TOTAL_POSSIBLE" 21 || return 1
    assert_eq "$TOTAL_PENALTY" 13 || return 1
    assert_eq "$GLOBAL_SCORE" 38 || return 1
    assert_eq "${DOMAIN_SCORE[SYS]}" 38 || return 1
    assert_eq "${DOMAIN_TOTAL[SYS]}" 5 || return 1
    assert_eq "${DOMAIN_FAIL[SYS]}" 1 || return 1
    assert_eq "${DOMAIN_WARN[SYS]}" 1 || return 1
    assert_eq "${DOMAIN_SKIP[SYS]}" 1 || return 1
}

test_exit_codes() {
    load_libs
    RUN_DIR=$(new_run_dir exits) || return 1

    CHECK_IDS=(SYS-01 SYS-02 SYS-03)
    ACTIVE_CHECK_IDS=("${CHECK_IDS[@]}")
    declare -gA CHECK_SEVERITY=([SYS-01]=critical [SYS-02]=high [SYS-03]=low)

    printf 'FAIL\n' > "$RUN_DIR/SYS-01.status"
    printf 'WARN\n' > "$RUN_DIR/SYS-02.status"
    printf 'PASS\n' > "$RUN_DIR/SYS-03.status"
    compute_exit_code
    assert_exit "$?" 2 || return 1

    printf 'PASS\n' > "$RUN_DIR/SYS-01.status"
    compute_exit_code
    assert_exit "$?" 1 || return 1

    printf 'PASS\n' > "$RUN_DIR/SYS-02.status"
    compute_exit_code
    assert_exit "$?" 0 || return 1

    # Un FAIL crítico fuera del perfil no debe afectar al código de salida.
    printf 'FAIL\n' > "$RUN_DIR/SYS-01.status"
    ACTIVE_CHECK_IDS=(SYS-02 SYS-03)
    compute_exit_code
    assert_exit "$?" 0 || return 1
}

test_emit_contract() {
    load_libs
    RUN_DIR=$(new_run_dir emit) || return 1

    emit TST-01 WARN $'linea uno\nlinea dos'
    assert_eq "$(cat "$RUN_DIR/TST-01.status")" 'WARN' || return 1
    assert_eq "$(cat "$RUN_DIR/TST-01.detail")" 'linea uno linea dos' || return 1
    assert_eq "$(wc -l < "$RUN_DIR/TST-01.detail" | tr -d ' ')" '1' || return 1

    local long
    long=$(printf 'a%.0s' {1..500})
    emit TST-02 FAIL "$long"
    assert_eq "$(wc -l < "$RUN_DIR/TST-02.detail" | tr -d ' ')" '1' || return 1
    assert_contains "$(cat "$RUN_DIR/TST-02.detail")" '…' || return 1
}

test_check_contract() {
    load_libs
    RUN_DIR=$(new_run_dir checks) || return 1
    CHECK_IDS=()
    ACTIVE_CHECK_IDS=()

    test_ok() { emit "$CURRENT_ID" PASS 'correcto'; }
    test_silent() { :; }
    test_noisy() { printf 'esto no debe leerse\n'; }

    register_check TST-01 low 'Check correcto' test_ok
    register_check TST-02 low 'Check silencioso' test_silent
    register_check TST-03 low 'Check ruidoso' test_noisy

    run_single_check TST-01
    assert_eq "$(status_of TST-01)" 'PASS' || return 1

    run_single_check TST-02
    assert_eq "$(status_of TST-02)" 'SKIP' || return 1
    assert_contains "$(detail_of TST-02)" 'no devolvió resultado' || return 1

    run_single_check TST-03
    assert_eq "$(status_of TST-03)" 'SKIP' || return 1
}

# ---------------------------------------------------------------------------
# Vigilancia y NET-01
# ---------------------------------------------------------------------------

test_watch_parse() {
    load_libs

    assert_eq "$(watch_split_hostport '127.0.0.1:11434')" '127.0.0.1|11434|' || return 1
    assert_eq "$(watch_split_hostport '[::1]:18789')" '::1|18789|' || return 1
    assert_eq "$(watch_split_hostport '0.0.0.0%virbr0:67')" '0.0.0.0|67|virbr0' || return 1
    assert_eq "$(watch_split_hostport 'fe80::1%wlo1:53')" 'fe80::1|53|wlo1' || return 1
    assert_eq "$(watch_split_hostport '*:68')" '*|68|' || return 1

    watch_split_hostport 'sinpuerto' >/dev/null 2>&1 && {
        printf 'debería rechazar una dirección sin puerto\n'
        return 1
    }
    watch_split_hostport '127.0.0.1:abc' >/dev/null 2>&1 && {
        printf 'debería rechazar un puerto no numérico\n'
        return 1
    }
    return 0
}

test_watch_classify() {
    load_libs
    WATCH_VIRTUAL_ADDRS=(192.168.122.1)

    assert_eq "$(watch_listen_kind '127.0.0.1' '')" 'local' || return 1
    assert_eq "$(watch_listen_kind '::1' '')" 'local' || return 1
    assert_eq "$(watch_listen_kind '0.0.0.0' '')" 'expuesto' || return 1
    assert_eq "$(watch_listen_kind '0.0.0.0' 'virbr0')" 'virtual' || return 1
    assert_eq "$(watch_listen_kind '0.0.0.0' 'docker0')" 'virtual' || return 1
    assert_eq "$(watch_listen_kind '0.0.0.0' 'wlo1')" 'expuesto' || return 1
    assert_eq "$(watch_listen_kind '192.168.122.1' '')" 'virtual' || return 1
    assert_eq "$(watch_listen_kind '192.168.1.212' '')" 'expuesto' || return 1
    assert_eq "$(watch_listen_kind 'fe80::1' 'wlo1')" 'expuesto' || return 1

    watch_is_virtual_iface virbr0 || {
        printf 'virbr0 debería ser virtual\n'
        return 1
    }
    watch_is_virtual_iface br-1a2b || {
        printf 'br-1a2b debería ser virtual\n'
        return 1
    }
    watch_is_virtual_iface br0 && {
        printf 'br0 es un puente físico, no virtual\n'
        return 1
    }
    watch_is_virtual_iface wlo1 && {
        printf 'wlo1 no es virtual\n'
        return 1
    }
    return 0
}

test_watch_exit_and_diff() {
    load_libs
    RUN_DIR=$(new_run_dir watchdiff) || return 1

    WATCH_FINDINGS=()
    watch_exit_code
    assert_exit "$?" 0 || return 1

    WATCH_FINDINGS=('WARN|aviso')
    watch_exit_code
    assert_exit "$?" 1 || return 1

    WATCH_FINDINGS=('WARN|aviso' 'CRIT|crítico')
    watch_exit_code
    assert_exit "$?" 2 || return 1

    printf 'tcp|LISTEN|0.0.0.0|67|0|?|||virbr0|1\n' > "$RUN_DIR/watch.listen.prev"
    printf 'tcp|LISTEN|0.0.0.0|67|1|?|||\n' > "$RUN_DIR/watch.listen"
    WATCH_EVENTS=()
    declare -A WATCH_EVENT_SEEN=()
    watch_diff_listen
    assert_eq "${#WATCH_EVENTS[@]}" 2 || return 1
    assert_contains "${WATCH_EVENTS[0]}" 'nuevo puerto a la escucha: tcp/67 en 0.0.0.0' || return 1
    assert_contains "${WATCH_EVENTS[1]}" 'puerto cerrado: tcp/67 en 0.0.0.0%virbr0' || return 1

    printf '/etc/passwd|1700000000|100|644|root:root\n' > "$RUN_DIR/watch.files.prev"
    printf '/etc/passwd|1700000000|120|644|root:root\n' > "$RUN_DIR/watch.files"
    WATCH_EVENTS=()
    WATCH_EVENT_SEEN=()
    watch_diff_files
    assert_eq "${#WATCH_EVENTS[@]}" 1 || return 1
    assert_contains "${WATCH_EVENTS[0]}" 'fichero crítico modificado: /etc/passwd (100 -> 120 bytes)' || return 1
}

test_watch_sudo_state() {
    load_libs
    is_root() { return 1; }
    USE_SUDO=0
    assert_eq "$(watch_sudo_state)" 'no' || return 1

    USE_SUDO=1
    sudo_ok() { return 1; }
    assert_eq "$(watch_sudo_state)" 'no (sin caché)' || return 1

    sudo_ok() { return 0; }
    assert_eq "$(watch_sudo_state)" 'sí' || return 1

    is_root() { return 0; }
    assert_eq "$(watch_sudo_state)" 'raíz' || return 1
}

test_net01_virtual() {
    load_catalog
    RUN_DIR=$(new_run_dir net01) || return 1
    local fake="$TMP/fakebin"
    mkdir -p -- "$fake" || return 1

    cat > "$fake/ip" <<'EOF'
#!/usr/bin/env bash
printf '3: virbr0    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0\n'
EOF

    cat > "$fake/ss" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
tcp   LISTEN 0 4096 127.0.0.1:11434 0.0.0.0:*
tcp   LISTEN 0 4096 192.168.122.1:53 0.0.0.0:*
udp   UNCONN 0 0    0.0.0.0%virbr0:67 0.0.0.0:*
OUT
EOF

    chmod +x "$fake/ip" "$fake/ss" || return 1
    PATH="$fake:$PATH"
    CURRENT_ID='NET-01'

    check_net_01
    assert_eq "$(status_of NET-01)" 'PASS' || return 1
    assert_contains "$(detail_of NET-01)" 'ningún socket' || return 1

    cat > "$fake/ss" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
tcp   LISTEN 0 4096 127.0.0.1:11434 0.0.0.0:*
tcp   LISTEN 0 4096 192.168.122.1:53 0.0.0.0:*
udp   UNCONN 0 0    0.0.0.0%virbr0:67 0.0.0.0:*
tcp   LISTEN 0 4096 203.0.113.5:8080 0.0.0.0:*
OUT
EOF
    chmod +x "$fake/ss" || return 1

    check_net_01
    assert_eq "$(status_of NET-01)" 'WARN' || return 1
    local detail
    detail=$(detail_of NET-01)
    assert_contains "$detail" 'tcp/8080' || return 1
    assert_not_contains "$detail" '192.168.122.1' || return 1
    assert_not_contains "$detail" 'udp/67' || return 1
}

# ---------------------------------------------------------------------------
# Menú y CLI
# ---------------------------------------------------------------------------

test_menu_sudo_row() {
    load_catalog
    # shellcheck source=../lib/ui.sh
    . "$ROOT/lib/ui.sh"
    # shellcheck source=../lib/menu.sh
    . "$ROOT/lib/menu.sh"
    ui_init

    menu_row() { printf '%s\n' "$1"; }
    menu_sep() { printf '·'; }

    MENU_SUDO=0
    menu_sudo_ready() { return 1; }
    assert_contains "$(menu_rows_main)" '[ ] desactivado' || return 1

    MENU_SUDO=1
    assert_contains "$(menu_rows_main)" '[x] sin caché' || return 1

    menu_sudo_ready() { return 0; }
    assert_contains "$(menu_rows_main)" '[x] activado' || return 1
}

test_cli_basic() {
    local out rc m

    out=$("$SCRIPT" --version 2>&1)
    assert_exit "$?" 0 || return 1
    assert_eq "$out" "watch4me $VERSION" || return 1

    out=$("$SCRIPT" --help 2>&1)
    assert_exit "$?" 0 || return 1
    assert_contains "$out" 'USO' || return 1
    assert_contains "$out" 'watch' || return 1

    out=$("$SCRIPT" audit --profile inexistente --no-anim --no-color 2>&1)
    rc=$?
    assert_exit "$rc" 64 || return 1
    assert_contains "$out" 'perfil desconocido' || return 1

    for m in baseline monitor; do
        out=$("$SCRIPT" "$m" 2>&1)
        rc=$?
        assert_exit "$rc" 64 || return 1
        assert_contains "$out" 'M3' || return 1
    done

    out=$("$SCRIPT" watch --interval 0 2>&1)
    rc=$?
    assert_exit "$rc" 64 || return 1
}

test_explain() {
    local out

    out=$("$SCRIPT" explain --list 2>&1)
    assert_exit "$?" 0 || return 1
    assert_contains "$out" 'Catálogo de checks (74)' || return 1

    out=$("$SCRIPT" explain SYS-01 2>&1)
    assert_exit "$?" 0 || return 1
    assert_contains "$out" 'Sincronización del reloj' || return 1

    out=$("$SCRIPT" explain NOEX-99 2>&1)
    assert_exit "$?" 1 || return 1
    assert_contains "$out" 'check desconocido' || return 1
}

test_menu_no_tty() {
    local out rc
    out=$("$SCRIPT" menu 2>&1)
    rc=$?
    assert_exit "$rc" 64 || return 1
    assert_contains "$out" 'terminal interactiva' || return 1
}

# ---------------------------------------------------------------------------
# Auditorías, informes y vigilancia de extremo a extremo
# ---------------------------------------------------------------------------

test_audit_esencial() {
    local out rc
    out=$("$SCRIPT" audit --profile esencial --no-anim --no-color 2>&1)
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_contains "$out" 'Esencial (14 checks)' || return 1
    assert_no_ansi "$out" || return 1
}

test_default_no_tty() {
    local out rc
    out=$("$SCRIPT" 2>&1)
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_contains "$out" 'AUDITORIA DE SEGURIDAD' || return 1
    assert_no_ansi "$out" || return 1
}

test_audit_save_stdout() {
    local out rc err="$TMP/save-stdout.err"
    out=$("$SCRIPT" audit --profile esencial --no-anim --no-color --save - 2>"$err")
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_contains "$out" '# watch4me — informe de seguridad' || return 1
    assert_not_contains "$out" 'VIGILANCIA DE CONEXIONES' || return 1
    assert_no_ansi "$out" || return 1
    assert_eq "$(wc -c < "$err" | tr -d ' ')" '0' || return 1
}

test_audit_save_files() {
    local base="$TMP/reports/main" out rc
    out=$("$SCRIPT" audit --profile esencial --no-anim --no-color --save "$base" 2>&1)
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_file "$base.md" || return 1
    assert_file "$base.json" || return 1

    local md json
    md=$(cat "$base.md")
    json=$(cat "$base.json")
    assert_contains "$md" '# watch4me — informe de seguridad' || return 1
    assert_contains "$json" '"schema": "watch4me.report/v1"' || return 1
    assert_contains "$json" '"checks_catalog": 74' || return 1
    assert_contains "$json" '"checks_total": 14' || return 1
    assert_contains "$json" '"profile": "esencial"' || return 1
    assert_no_ansi "$json" || return 1
}

test_audit_collision() {
    local dir="$TMP/collision" base="$TMP/collision/report" rc
    "$SCRIPT" audit --profile esencial --no-anim --no-color --save "$base" >/dev/null 2>&1
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    "$SCRIPT" audit --profile esencial --no-anim --no-color --save "$base" >/dev/null 2>&1
    rc=$?
    assert_in "$rc" '0 1 2' || return 1

    local md json
    md=$(find "$dir" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    json=$(find "$dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$md" '2' || return 1
    assert_eq "$json" '2' || return 1
}

test_watch_once() {
    command -v ss >/dev/null 2>&1 || {
        printf 'ss no disponible'
        return 77
    }

    local out rc err="$TMP/watch-once.err"
    out=$("$SCRIPT" watch --once --no-color 2>"$err")
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_contains "$out" 'Puertos a la escucha' || return 1
    assert_no_ansi "$out" || return 1
    assert_eq "$(wc -c < "$err" | tr -d ' ')" '0' || return 1
}

test_watch_warning() {
    command -v ss >/dev/null 2>&1 || {
        printf 'ss no disponible'
        return 77
    }

    local out rc err="$TMP/watch-warn.err"
    out=$("$SCRIPT" watch --no-color 2>"$err")
    rc=$?
    assert_in "$rc" '0 1 2' || return 1
    assert_contains "$out" 'Puertos a la escucha' || return 1
    assert_contains "$(cat "$err")" 'sin TTY o sin color' || return 1
}

# ---------------------------------------------------------------------------
# ShellCheck (opcional)
# ---------------------------------------------------------------------------

test_shellcheck() {
    local sc=${SHELLCHECK:-shellcheck}
    command -v "$sc" >/dev/null 2>&1 || {
        printf 'shellcheck no instalado'
        return 77
    }

    local -a files=()
    local f
    for f in "$SCRIPT" "$ROOT"/lib/*.sh "$ROOT"/lib/family/*.sh "$ROOT"/checks/*.sh "$ROOT"/tests/*.sh; do
        files+=("$f")
    done
    "$sc" -x "${files[@]}"
}

# ---------------------------------------------------------------------------
# Ejecución
# ---------------------------------------------------------------------------

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --filter)
                [ -n "${2:-}" ] || {
                    printf 'uso: %s --filter <texto>\n' "$0" >&2
                    exit 64
                }
                FILTER=$2
                shift 2
                ;;
            -h|--help)
                printf 'uso: %s [--filter <texto>]\n' "$0"
                exit 0
                ;;
            *)
                printf 'opción desconocida: %s\n' "$1" >&2
                exit 64
                ;;
        esac
    done

    printf 'watch4me tests · v%s\n' "$VERSION"

    local name
    for name in \
        test_catalog \
        test_profile_counts \
        test_profile_membership \
        test_profile_set \
        test_scoring \
        test_exit_codes \
        test_emit_contract \
        test_check_contract \
        test_watch_parse \
        test_watch_classify \
        test_watch_exit_and_diff \
        test_watch_sudo_state \
        test_net01_virtual \
        test_menu_sudo_row \
        test_cli_basic \
        test_explain \
        test_menu_no_tty \
        test_audit_esencial \
        test_default_no_tty \
        test_audit_save_stdout \
        test_audit_save_files \
        test_audit_collision \
        test_watch_once \
        test_watch_warning \
        test_shellcheck
    do
        if [ -n "$FILTER" ]; then
            case "$name" in
                *"$FILTER"*) ;;
                *) continue ;;
            esac
        fi
        run_test "${name#test_}" "$name"
    done

    printf '\n%d pruebas · %d pasadas · %d fallidas · %d omitidas\n' \
        "$TESTS" "$PASSED" "$FAILED" "$SKIPPED"
    [ "$FAILED" -eq 0 ]
}

main "$@"
