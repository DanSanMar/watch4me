#!/usr/bin/env bash
# watch4me — vigilancia en vivo de conexiones, servicios y persistencia
#
# No es un antivirus: es un monitor de solo lectura que compara instantáneas
# de sockets, servicios, procesos y ficheros críticos. No bloquea nada, no
# instala nada y no envía datos.
#
# Licencia: GPLv3

WATCH_INTERVAL=${WATCH_INTERVAL:-3}
WATCH_ONCE=${WATCH_ONCE:-0}
WATCH_STOP=0
WATCH_LIVE=0
WATCH_SCREEN=0
WATCH_FIRST=1
WATCH_EVENTS=()
WATCH_FINDINGS=()
declare -A WATCH_EVENT_SEEN=()
declare -A WATCH_FINDING_SEEN=()

WATCH_LISTEN_COUNT=0
WATCH_EXPOSED_COUNT=0
WATCH_ESTAB_COUNT=0
WATCH_SERVICE_COUNT=0
WATCH_FILE_COUNT=0

# Puertos que nunca deberían estar expuestos sin una razón muy clara.
WATCH_HIGH_RISK_PORTS=' 21 23 69 111 135 139 445 512 513 514 1433 1521 2375 2376 3306 3389 5432 5900 5901 6379 9200 11211 27017 '
# Puertos remotos usados por mineros, IRC, Tor y shells de prueba.
WATCH_RISKY_REMOTE_PORTS=' 23 445 3389 5900 5901 6667 8333 9050 9051 1337 3333 4444 5555 7777 9999 14444 31337 '

WATCH_MINER_RE='(xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|stratum\+tcp|stratum\+ssl|--donate-level|--coin=|mining[[:space:]]+pool)'
WATCH_REVSHELL_RE='(/dev/tcp/|(^|[[:space:]])nc[[:space:]]+[^#]*-e[[:space:]]|(^|[[:space:]])ncat[[:space:]]+[^#]*-e[[:space:]]|socat[^#]*exec:|mkfifo[[:space:]]+/(tmp|var/tmp|dev/shm)|bash[[:space:]]+-i[[:space:]]*>&|python[0-9.]*[[:space:]]+-c[^#]*socket)'

_watch_rule() {
    local n=${1:-40} ch='-'
    [ "${UI_UTF8:-0}" -eq 1 ] && ch='─'
    while [ "$n" -gt 0 ]; do
        printf '%s' "$ch"
        n=$(( n - 1 ))
    done
}

_watch_section() {
    local title=$1
    printf '\n%s── %s%s\n' "$C_BOLD$C_CYAN_B" "$title" "$C_RESET"
}

watch_trim_events() {
    [ "${#WATCH_EVENTS[@]}" -gt 20 ] || return 0
    WATCH_EVENTS=("${WATCH_EVENTS[@]: -20}")
}

watch_add_finding() {
    local level=$1
    shift
    local text=$* key
    key="$level|$text"
    [ -n "${WATCH_FINDING_SEEN[$key]:-}" ] && return 0
    WATCH_FINDING_SEEN[$key]=1
    WATCH_FINDINGS+=("$key")
}

watch_add_event() {
    local level=$1
    shift
    local text=$* key
    key="$level|$*"
    [ -n "${WATCH_EVENT_SEEN[$key]:-}" ] && return 0
    WATCH_EVENT_SEEN[$key]=1
    WATCH_EVENTS+=("$level|$(date '+%H:%M:%S')|$*")
    watch_trim_events
}

# Convierte "addr:puerto" (IPv4, IPv6 o con %interfaz) en "addr|puerto".
watch_split_hostport() {
    local hp=$1 addr port
    case "$hp" in
        *:*)
            port=${hp##*:}
            addr=${hp%:*}
            addr=${addr#[}
            addr=${addr%]}
            addr=${addr%%\%*}
            ;;
        *)
            return 1
            ;;
    esac
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    printf '%s|%s' "${addr:-*}" "$port"
}

watch_is_local_addr() {
    case "${1:-}" in
        127.*|::1|::ffff:127.*|localhost) return 0 ;;
    esac
    return 1
}

watch_proc_exe() {
    local pid=$1 exe=''
    [ -n "$pid" ] || return 0
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    if [ -z "$exe" ] && [ "${USE_SUDO:-0}" -eq 1 ] && sudo_ok; then
        exe=$(as_root readlink "/proc/$pid/exe" 2>/dev/null || true)
    fi
    printf '%s' "$exe"
}

# ss con privilegios si se pidieron y hay caché de sudo.
watch_ss() {
    if [ "${USE_SUDO:-0}" -eq 1 ] && sudo_ok; then
        as_root timeout 10 ss "$@" 2>/dev/null
    else
        timeout 10 ss "$@" 2>/dev/null
    fi
}

watch_collect_listen() {
    local raw proto state laddr proc addr port exposed pname pid exe key
    raw=$(watch_ss -tulpnH)
    : > "$RUN_DIR/watch.listen"
    [ -n "$raw" ] || return 0

    local -A seen=()
    while IFS='|' read -r proto state laddr proc; do
        [ -n "$proto" ] || continue
        local pair
        pair=$(watch_split_hostport "$laddr") || continue
        IFS='|' read -r addr port <<< "$pair"
        [ -n "$port" ] || continue

        exposed=0
        case "$addr" in
            ''|'*'|0.0.0.0|::) exposed=1 ;;
            127.*|::1|::ffff:127.*) exposed=0 ;;
            *) exposed=1 ;;
        esac

        pname=$(printf '%s' "$proc" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1)
        pid=$(printf '%s' "$proc" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1)
        pname=${pname:-?}
        exe=$(watch_proc_exe "$pid")

        key="$proto|$addr|$port|$pname"
        [ -n "${seen[$key]:-}" ] && continue
        seen[$key]=1
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$proto" "$state" "$addr" "$port" "$exposed" "$pname" "${pid:-}" "$exe" \
            >> "$RUN_DIR/watch.listen"
    done < <(printf '%s\n' "$raw" | awk '
        {
            proto=$1; state=$2; laddr=$5; proc=""
            for (i=7; i<=NF; i++) proc=proc (i>7?" ":"") $i
            print proto "|" state "|" laddr "|" proc
        }')

    sort -t'|' -k1,1 -k4,4n "$RUN_DIR/watch.listen" -o "$RUN_DIR/watch.listen" 2>/dev/null || true
}

watch_collect_estab() {
    local raw proto state laddr peer proc lpair ppair laddr2 lport paddr pport
    local pname pid exe key
    raw=$(watch_ss -tunpH)
    : > "$RUN_DIR/watch.estab"
    [ -n "$raw" ] || return 0

    local -A seen=()
    while IFS='|' read -r proto state laddr peer proc; do
        [ "$proto" = 'tcp' ] || continue
        [ "$state" = 'ESTAB' ] || continue

        lpair=$(watch_split_hostport "$laddr") || continue
        ppair=$(watch_split_hostport "$peer") || continue
        IFS='|' read -r laddr2 lport <<< "$lpair"
        IFS='|' read -r paddr pport <<< "$ppair"
        [ -n "$pport" ] || continue
        case "$paddr" in
            ''|'*'|0.0.0.0|::) continue ;;
        esac

        pname=$(printf '%s' "$proc" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1)
        pid=$(printf '%s' "$proc" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1)
        pname=${pname:-?}

        exe=''
        case "$pname" in
            bash|sh|zsh|dash|ksh|python|python3|perl|ruby|php|nc|ncat|netcat|socat)
                exe=$(watch_proc_exe "$pid")
                ;;
        esac
        if [ -z "$exe" ] && in_list "$pport" "$WATCH_RISKY_REMOTE_PORTS"; then
            exe=$(watch_proc_exe "$pid")
        fi

        key="$paddr|$pport|$pname|$pid"
        [ -n "${seen[$key]:-}" ] && continue
        seen[$key]=1
        printf 'tcp|%s:%s|%s:%s|%s|%s|%s\n' \
            "$laddr2" "$lport" "$paddr" "$pport" "$pname" "${pid:-}" "$exe" \
            >> "$RUN_DIR/watch.estab"
    done < <(printf '%s\n' "$raw" | awk '
        {
            proto=$1; state=$2; laddr=$5; peer=$6; proc=""
            for (i=7; i<=NF; i++) proc=proc (i>7?" ":"") $i
            print proto "|" state "|" laddr "|" peer "|" proc
        }')

    sort -t'|' -k3,3 "$RUN_DIR/watch.estab" -o "$RUN_DIR/watch.estab" 2>/dev/null || true
}

watch_collect_services() {
    : > "$RUN_DIR/watch.services"
    : > "$RUN_DIR/watch.failed"
    systemd_running || return 0

    systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -E '\.service$' | sort -u > "$RUN_DIR/watch.services" || true
    systemctl --failed --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -E '\.service$' | sort -u > "$RUN_DIR/watch.failed" || true
}

watch_file_line() {
    local f=$1 st
    st=$(stat -c '%n|%Y|%s|%a|%U:%G' -- "$f" 2>/dev/null) || return 0
    printf '%s\n' "$st"
}

watch_collect_files() {
    local -a paths=()
    local f u home
    for f in \
        /etc/passwd /etc/group /etc/shadow /etc/gshadow \
        /etc/sudoers /etc/ssh/sshd_config /etc/ld.so.preload \
        /etc/ld.so.conf /etc/crontab /etc/rc.local \
        /root/.ssh/authorized_keys; do
        [ -e "$f" ] && paths+=("$f")
    done

    while IFS= read -r f; do
        [ -n "$f" ] && paths+=("$f")
    done < <(find /etc/sudoers.d /etc/ssh/sshd_config.d /etc/cron.d /etc/pam.d \
        -maxdepth 1 -type f 2>/dev/null)

    while IFS= read -r f; do
        [ -n "$f" ] && paths+=("$f")
    done < <(find /etc/systemd/system -maxdepth 1 \( -type f -o -type l \) \
        \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.path' \) 2>/dev/null)

    while IFS= read -r u; do
        home=$(user_home "$u")
        [ -n "$home" ] && [ -e "$home/.ssh/authorized_keys" ] \
            && paths+=("$home/.ssh/authorized_keys")
    done < <(interactive_users)

    : > "$RUN_DIR/watch.files"
    for f in "${paths[@]}"; do
        watch_file_line "$f"
    done | sort -u > "$RUN_DIR/watch.files"
}

watch_collect_procs() {
    local d pid comm cmd
    : > "$RUN_DIR/watch.procs"
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        pid=${d##*/}
        cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        [ -n "$cmd" ] || continue
        if [[ "$cmd" =~ $WATCH_MINER_RE ]] || [[ "$cmd" =~ $WATCH_REVSHELL_RE ]]; then
            comm=$(cat "$d/comm" 2>/dev/null || true)
            printf '%s|%s|%s\n' "$pid" "${comm:-?}" "$(clip "$cmd" 200)" >> "$RUN_DIR/watch.procs"
        fi
    done
    LC_ALL=C sort "$RUN_DIR/watch.procs" -o "$RUN_DIR/watch.procs" 2>/dev/null || true
}

watch_collect() {
    watch_collect_listen
    watch_collect_estab
    watch_collect_services
    watch_collect_files
    watch_collect_procs
}

watch_update_counts() {
    WATCH_LISTEN_COUNT=$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.listen" 2>/dev/null)
    WATCH_EXPOSED_COUNT=$(awk -F'|' '$5 == 1 { n++ } END { print n + 0 }' "$RUN_DIR/watch.listen" 2>/dev/null)
    WATCH_ESTAB_COUNT=$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.estab" 2>/dev/null)
    WATCH_SERVICE_COUNT=$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.services" 2>/dev/null)
    WATCH_FILE_COUNT=$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.files" 2>/dev/null)
}

watch_analyze() {
    local proto state addr port exposed pname pid exe
    local laddr peer paddr pport comm cmd unit
    WATCH_FINDINGS=()
    WATCH_FINDING_SEEN=()

    while IFS='|' read -r proto state addr port exposed pname pid exe; do
        [ -n "$proto" ] || continue
        [ "$exposed" -eq 1 ] || continue
        if in_list "$port" "$WATCH_HIGH_RISK_PORTS"; then
            watch_add_finding WARN "puerto de alto riesgo a la escucha: $proto/$port en $addr ($pname)"
        fi
        case "$exe" in
            *'(deleted)'*)
                watch_add_finding CRIT "servicio a la escucha desde un binario borrado: $proto/$port $pname ($exe)"
                ;;
            /tmp/*|/var/tmp/*|/dev/shm/*)
                watch_add_finding CRIT "servicio a la escucha desde una ruta temporal: $proto/$port $pname ($exe)"
                ;;
        esac
    done < "$RUN_DIR/watch.listen"

    while IFS='|' read -r proto laddr peer pname pid exe; do
        [ -n "$proto" ] || continue
        paddr=${peer%:*}
        pport=${peer##*:}
        [ -n "$pport" ] || continue

        # Las conexiones a loopback son normales (IPC local): no se marcan.
        watch_is_local_addr "$paddr" && continue

        if in_list "$pport" "$WATCH_RISKY_REMOTE_PORTS"; then
            watch_add_finding WARN "conexión saliente a puerto de riesgo: $peer ($pname)"
        fi
        case "$pname" in
            bash|sh|zsh|dash|ksh|python|python3|perl|ruby|php|nc|ncat|netcat|socat)
                watch_add_finding WARN "shell o intérprete con conexión de red: $pname -> $peer"
                ;;
        esac
        case "$exe" in
            *'(deleted)'*)
                watch_add_finding CRIT "conexión desde un binario borrado: $pname -> $peer ($exe)"
                ;;
            /tmp/*|/var/tmp/*|/dev/shm/*)
                watch_add_finding CRIT "conexión desde una ruta temporal: $pname -> $peer ($exe)"
                ;;
        esac
    done < "$RUN_DIR/watch.estab"

    while IFS='|' read -r pid comm cmd; do
        [ -n "$pid" ] || continue
        watch_add_finding WARN "proceso con indicadores de minero o shell inversa: $comm (pid $pid): $cmd"
    done < "$RUN_DIR/watch.procs"

    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        watch_add_finding WARN "servicio systemd en estado failed: $unit"
    done < "$RUN_DIR/watch.failed"

    if [ -s /etc/ld.so.preload ]; then
        watch_add_finding CRIT '/etc/ld.so.preload tiene contenido: revisa las bibliotecas precargadas'
    fi
}

watch_diff_listen() {
    local key
    [ -s "$RUN_DIR/watch.listen.prev" ] || return 0
    while IFS= read -r key; do
        [ -n "$key" ] && watch_add_event WARN "nuevo puerto a la escucha: $key"
    done < <(comm -13 \
        <(cut -d'|' -f1-4 "$RUN_DIR/watch.listen.prev" 2>/dev/null | sort -u) \
        <(cut -d'|' -f1-4 "$RUN_DIR/watch.listen" 2>/dev/null | sort -u))
    while IFS= read -r key; do
        [ -n "$key" ] && watch_add_event INFO "puerto cerrado: $key"
    done < <(comm -23 \
        <(cut -d'|' -f1-4 "$RUN_DIR/watch.listen.prev" 2>/dev/null | sort -u) \
        <(cut -d'|' -f1-4 "$RUN_DIR/watch.listen" 2>/dev/null | sort -u))
}

watch_diff_services() {
    local unit
    [ -s "$RUN_DIR/watch.services.prev" ] || return 0
    while IFS= read -r unit; do
        [ -n "$unit" ] && watch_add_event WARN "servicio nuevo en ejecución: $unit"
    done < <(comm -13 "$RUN_DIR/watch.services.prev" "$RUN_DIR/watch.services" 2>/dev/null)
    while IFS= read -r unit; do
        [ -n "$unit" ] && watch_add_event INFO "servicio detenido: $unit"
    done < <(comm -23 "$RUN_DIR/watch.services.prev" "$RUN_DIR/watch.services" 2>/dev/null)
}

watch_diff_files() {
    local kind path old new
    [ -s "$RUN_DIR/watch.files.prev" ] || return 0
    while IFS='|' read -r kind path old new; do
        [ -n "$kind" ] || continue
        case "$kind" in
            new)     watch_add_event WARN "fichero crítico nuevo: $path" ;;
            removed) watch_add_event WARN "fichero crítico eliminado: $path" ;;
            changed) watch_add_event WARN "fichero crítico modificado: $path" ;;
        esac
    done < <(awk -F'|' '
        NR == FNR { old[$1]=$0; next }
        {
            if ($1 in old) {
                if (old[$1] != $0) {
                    split(old[$1], o, "|")
                    split($0, n, "|")
                    print "changed|" $1 "|" o[2] "|" n[2]
                }
                delete old[$1]
            } else {
                print "new|" $1 "||"
            }
        }
        END {
            for (p in old) print "removed|" p "||"
        }' "$RUN_DIR/watch.files.prev" "$RUN_DIR/watch.files" 2>/dev/null)
}

watch_diff_procs() {
    local line
    [ -s "$RUN_DIR/watch.procs.prev" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && watch_add_event WARN "proceso sospechoso nuevo: $(printf '%s' "$line" | cut -d'|' -f2- | oneline)"
    done < <(LC_ALL=C comm -13 "$RUN_DIR/watch.procs.prev" "$RUN_DIR/watch.procs" 2>/dev/null)
}

watch_diff() {
    WATCH_EVENT_SEEN=()
    watch_diff_listen
    watch_diff_services
    watch_diff_files
    watch_diff_procs
}

watch_save_prev() {
    local f base
    for f in listen estab services files procs; do
        cp -f -- "$RUN_DIR/watch.$f" "$RUN_DIR/watch.$f.prev" 2>/dev/null || true
    done
}

watch_print_listen() {
    local proto state addr port exposed pname pid exe status n=0
    while IFS='|' read -r proto state addr port exposed pname pid exe; do
        [ -n "$proto" ] || continue
        n=$(( n + 1 ))
        if [ "$n" -gt 20 ]; then
            printf '  %s... y más puertos%s\n' "$C_DIM" "$C_RESET"
            break
        fi
        status='local'
        [ "$exposed" -eq 1 ] && status='EXPUESTO'
        printf '  %-10s %-22s %-20s %s\n' "$proto/$port" "$addr" "$pname" "$status"
        case "$exe" in
            *'(deleted)'*|/tmp/*|/var/tmp/*|/dev/shm/*)
                printf '  %s%s%s\n' "$C_DIM" "    $exe" "$C_RESET"
                ;;
        esac
    done < "$RUN_DIR/watch.listen"
    [ "$n" -eq 0 ] && printf '  Sin datos de sockets (ss no devolvió información).\n'
}

watch_print_estab() {
    local proto laddr peer pname pid exe n=0
    while IFS='|' read -r proto laddr peer pname pid exe; do
        [ -n "$proto" ] || continue
        n=$(( n + 1 ))
        if [ "$n" -gt 15 ]; then
            printf '  %s... y más conexiones%s\n' "$C_DIM" "$C_RESET"
            break
        fi
        printf '  %-44s %s\n' "$laddr -> $peer" "$pname"
    done < "$RUN_DIR/watch.estab"
    [ "$n" -eq 0 ] && printf '  Sin conexiones TCP establecidas.\n'
}

watch_print_services() {
    local failed=0 unit n=0
    failed=$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.failed" 2>/dev/null)
    printf '  Servicios activos: %d · fallidos: %d\n' "$WATCH_SERVICE_COUNT" "$failed"
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        n=$(( n + 1 ))
        [ "$n" -gt 10 ] && break
        printf '  %s%s%s %s\n' "$C_RED_B" "$(ui_icon '✖' 'x')" "$C_RESET" "$unit"
    done < "$RUN_DIR/watch.failed"
}

watch_finding_counts() {
    local f crit=0 warn=0
    for f in "${WATCH_FINDINGS[@]}"; do
        case "$f" in
            CRIT\|*) crit=$(( crit + 1 )) ;;
            WARN\|*) warn=$(( warn + 1 )) ;;
        esac
    done
    WATCH_CRIT_COUNT=$crit
    WATCH_WARN_COUNT=$warn
}

watch_render_findings() {
    local max=${1:-10} f level text n=0 total
    total=${#WATCH_FINDINGS[@]}
    if [ "$total" -eq 0 ]; then
        printf '  %sSin hallazgos en esta instantánea.%s\n' "$C_GREEN_B" "$C_RESET"
        return 0
    fi
    for f in "${WATCH_FINDINGS[@]}"; do
        n=$(( n + 1 ))
        [ "$n" -gt "$max" ] && break
        level=${f%%|*}
        text=${f#*|}
        case "$level" in
            CRIT) printf '  %s[CRÍTICO]%s %s\n' "$C_RED_B$C_BOLD" "$C_RESET" "$text" ;;
            WARN) printf '  %s[AVISO]%s   %s\n' "$C_YELLOW_B$C_BOLD" "$C_RESET" "$text" ;;
            *)    printf '  %s[INFO]%s    %s\n' "$C_DIM" "$C_RESET" "$text" ;;
        esac
    done
    [ "$total" -gt "$max" ] && printf '  %s... y %d hallazgo(s) más%s\n' "$C_DIM" "$(( total - max ))" "$C_RESET"
}

watch_render_events() {
    local max=${1:-10} e level stamp text n=0 total
    total=${#WATCH_EVENTS[@]}
    if [ "$total" -eq 0 ]; then
        if [ "${WATCH_FIRST:-0}" -eq 1 ]; then
            printf '  %sPrimera captura: aún no hay cambios que mostrar.%s\n' "$C_DIM" "$C_RESET"
        else
            printf '  %sSin cambios desde la captura anterior.%s\n' "$C_DIM" "$C_RESET"
        fi
        return 0
    fi
    # Los últimos eventos son los más recientes: se muestran en orden.
    local -a tail=("${WATCH_EVENTS[@]: -$max}")
    for e in "${tail[@]}"; do
        n=$(( n + 1 ))
        level=${e%%|*}
        stamp=${e#*|}
        stamp=${stamp%%|*}
        text=${e#*|*|}
        case "$level" in
            CRIT) printf '  %s%s [CRÍTICO]%s %s\n' "$C_RED_B$C_BOLD" "$stamp" "$C_RESET" "$text" ;;
            WARN) printf '  %s%s [AVISO]%s   %s\n' "$C_YELLOW_B$C_BOLD" "$stamp" "$C_RESET" "$text" ;;
            *)    printf '  %s%s [INFO]%s    %s\n' "$C_DIM" "$stamp" "$C_RESET" "$text" ;;
        esac
    done
    [ "$total" -gt "$max" ] && printf '  %s... y %d evento(s) anterior(es)%s\n' "$C_DIM" "$(( total - max ))" "$C_RESET"
}

watch_render_once() {
    local now host
    host=${HOSTNAME_SHORT:-localhost}
    now=$(date '+%Y-%m-%d %H:%M:%S')
    watch_finding_counts

    printf '\n%sVIGILANCIA DE CONEXIONES Y SERVICIOS%s\n' "$C_BOLD$C_CYAN_B" "$C_RESET"
    printf '%sHost:%s %s · %sFecha:%s %s · %sroot:%s %s · %ssudo:%s %s\n' \
        "$C_DIM" "$C_RESET" "$host" \
        "$C_DIM" "$C_RESET" "$now" \
        "$C_DIM" "$C_RESET" "$([ "$(id -u)" -eq 0 ] && printf 'sí' || printf 'no')" \
        "$C_DIM" "$C_RESET" "$([ "${USE_SUDO:-0}" -eq 1 ] && printf 'sí' || printf 'no')"
    printf '%s%s%s\n' "$C_DIM" "$(_watch_rule "${UI_WIDTH:-60}")" "$C_RESET"

    _watch_section "Puertos a la escucha ($WATCH_LISTEN_COUNT; $WATCH_EXPOSED_COUNT expuestos)"
    watch_print_listen

    _watch_section "Conexiones establecidas ($WATCH_ESTAB_COUNT)"
    watch_print_estab

    _watch_section 'Servicios'
    watch_print_services

    _watch_section "Hallazgos ($WATCH_CRIT_COUNT críticos, $WATCH_WARN_COUNT avisos)"
    watch_render_findings 20

    _watch_section 'Alcance'
    printf '  Ficheros críticos vigilados: %d\n' "$WATCH_FILE_COUNT"
    printf '  Procesos con indicadores sospechosos: %d\n' "$(awk 'END { print NR + 0 }' "$RUN_DIR/watch.procs" 2>/dev/null)"

    _watch_section 'Resumen'
    if [ "$WATCH_CRIT_COUNT" -gt 0 ]; then
        printf '  %sHay %d hallazgo(s) crítico(s). Revisa los procesos y las rutas señaladas antes de continuar.%s\n' \
            "$C_RED_B" "$WATCH_CRIT_COUNT" "$C_RESET"
    elif [ "$WATCH_WARN_COUNT" -gt 0 ]; then
        printf '  %sHay %d aviso(s). Puede ser actividad legítima, pero conviene identificarla.%s\n' \
            "$C_YELLOW_B" "$WATCH_WARN_COUNT" "$C_RESET"
    else
        printf '  %sSin hallazgos en esta instantánea.%s\n' "$C_GREEN_B" "$C_RESET"
    fi
    printf '\n'
}

watch_render_live() {
    local now host exposed_list
    host=${HOSTNAME_SHORT:-localhost}
    now=$(date '+%H:%M:%S')
    exposed_list=$(awk -F'|' '$5 == 1 { print $1 "/" $4 }' "$RUN_DIR/watch.listen" 2>/dev/null | paste -sd' ' -)
    watch_finding_counts

    printf '\033[H\033[2J'
    printf '%sVIGILANCIA EN VIVO%s · %s · cada %ss · %s\n' \
        "$C_BOLD$C_CYAN_B" "$C_RESET" "$now" "${WATCH_INTERVAL}" "$host"
    printf '%sEscucha:%s %d (%d expuestos) · %sEstablecidas:%s %d · %sServicios:%s %d · %sHallazgos:%s %d\n' \
        "$C_DIM" "$C_RESET" "$WATCH_LISTEN_COUNT" "$WATCH_EXPOSED_COUNT" \
        "$C_DIM" "$C_RESET" "$WATCH_ESTAB_COUNT" \
        "$C_DIM" "$C_RESET" "$WATCH_SERVICE_COUNT" \
        "$C_DIM" "$C_RESET" "$(( WATCH_CRIT_COUNT + WATCH_WARN_COUNT ))"
    if [ -n "$exposed_list" ]; then
        printf '%sExpuestos:%s %s\n' "$C_DIM" "$C_RESET" "$exposed_list"
    fi
    printf '%s%s%s\n' "$C_DIM" "$(_watch_rule "${UI_WIDTH:-60}")" "$C_RESET"

    _watch_section 'Hallazgos actuales'
    watch_render_findings 8

    _watch_section 'Cambios recientes'
    watch_render_events 10

    printf '\n%sCtrl-C para salir. La vigilancia es solo lectura y no bloquea nada.%s\n' \
        "$C_DIM" "$C_RESET"
}

watch_screen_open() {
    [ "${UI_TTY:-0}" -eq 1 ] || return 0
    WATCH_SCREEN=1
    printf '\033[?1049h\033[?25l'
}

watch_screen_close() {
    [ "${WATCH_SCREEN:-0}" -eq 1 ] || return 0
    printf '\033[?25h\033[?1049l'
    WATCH_SCREEN=0
}

watch_exit_code() {
    local f
    for f in "${WATCH_FINDINGS[@]}"; do
        case "$f" in CRIT\|*) return 2 ;; esac
    done
    for f in "${WATCH_FINDINGS[@]}"; do
        case "$f" in WARN\|*) return 1 ;; esac
    done
    return 0
}

watch_main() {
    if ! have ss; then
        printf 'watch4me: la vigilancia necesita ss (iproute2).\n' >&2
        return 64
    fi
    if ! [[ "${WATCH_INTERVAL:-3}" =~ ^[0-9]+$ ]] || [ "${WATCH_INTERVAL:-3}" -lt 1 ]; then
        die '--interval requiere un número de segundos mayor o igual que 1'
    fi
    if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then
        init_run_dir
    fi

    WATCH_STOP=0
    WATCH_LIVE=1
    WATCH_FIRST=1
    WATCH_EVENTS=()
    WATCH_EVENT_SEEN=()
    if [ "${WATCH_ONCE:-0}" -eq 1 ] || [ ! -t 1 ] || [ "${UI_COLOR:-0}" -ne 1 ]; then
        WATCH_LIVE=0
    fi
    if [ "$WATCH_LIVE" -eq 0 ] && [ "${WATCH_ONCE:-0}" -ne 1 ] && [ -t 1 ]; then
        printf 'watch4me: la pantalla en vivo necesita color; se muestra una única captura.\n' >&2
    fi

    local old_int old_term old_hup old_exit
    old_int=$(trap -p INT)
    old_term=$(trap -p TERM)
    old_hup=$(trap -p HUP)
    old_exit=$(trap -p EXIT)

    if [ "$WATCH_LIVE" -eq 1 ]; then
        trap 'WATCH_STOP=1' INT
        trap 'WATCH_STOP=1' TERM
        trap 'WATCH_STOP=1' HUP
        trap 'watch_screen_close; ui_restore' EXIT
        watch_screen_open
    fi

    watch_collect
    watch_update_counts
    watch_analyze

    if [ "$WATCH_LIVE" -eq 0 ]; then
        watch_render_once
        old_int=${old_int:-}
        old_term=${old_term:-}
        old_hup=${old_hup:-}
        old_exit=${old_exit:-}
        [ -n "$old_int" ] && eval "$old_int" || trap - INT
        [ -n "$old_term" ] && eval "$old_term" || trap - TERM
        [ -n "$old_hup" ] && eval "$old_hup" || trap - HUP
        [ -n "$old_exit" ] && eval "$old_exit" || trap - EXIT
        watch_exit_code
        return $?
    fi

    watch_render_live
    watch_save_prev
    WATCH_FIRST=0

    while [ "$WATCH_STOP" -eq 0 ]; do
        sleep "$WATCH_INTERVAL" 2>/dev/null || true
        [ "$WATCH_STOP" -eq 1 ] && break
        watch_collect
        watch_update_counts
        watch_analyze
        watch_diff
        watch_render_live
        watch_save_prev
    done

    watch_screen_close
    watch_finding_counts
    printf '\n%sVigilancia detenida%s · %d hallazgo(s) en la última captura · %d evento(s) registrado(s)\n' \
        "$C_BOLD$C_CYAN_B" "$C_RESET" "$(( WATCH_CRIT_COUNT + WATCH_WARN_COUNT ))" "${#WATCH_EVENTS[@]}"

    [ -n "$old_int" ] && eval "$old_int" || trap - INT
    [ -n "$old_term" ] && eval "$old_term" || trap - TERM
    [ -n "$old_hup" ] && eval "$old_hup" || trap - HUP
    [ -n "$old_exit" ] && eval "$old_exit" || trap - EXIT
    return 0
}
