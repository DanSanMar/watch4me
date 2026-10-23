#!/usr/bin/env bash
# watch4me — utilidades comunes
# Licencia: GPLv3

have() {
    command -v "$1" >/dev/null 2>&1
}

is_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ]
}

# Caché de sudo -n: nunca se pide contraseña.
SUDO_CHECKED=0
SUDO_OK=0
sudo_ok() {
    if [ "$SUDO_CHECKED" -eq 0 ]; then
        SUDO_CHECKED=1
        if [ "${USE_SUDO:-0}" -eq 1 ] && ! is_root && have sudo; then
            if sudo -n true 2>/dev/null; then
                SUDO_OK=1
            fi
        fi
    fi
    [ "$SUDO_OK" -eq 1 ]
}

# Lee un fichero como usuario o, si --sudo está activo, con sudo -n.
rootread() {
    local f=$1
    if [ -r "$f" ]; then
        cat -- "$f"
    elif sudo_ok; then
        sudo -n cat -- "$f" 2>/dev/null
    else
        return 1
    fi
}

as_root() {
    if is_root; then
        "$@"
    elif sudo_ok; then
        sudo -n -- "$@"
    else
        return 1
    fi
}

sysctl_val() {
    sysctl -n "$1" 2>/dev/null
}

# ¿Systemd está gestionando el sistema?
systemd_running() {
    [ -d /run/systemd/system ] && have systemctl
}

unit_active() {
    have systemctl && systemctl is-active --quiet "$1" 2>/dev/null
}

unit_enabled() {
    have systemctl && systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Timeout para escaneos pesados según el perfil.
scan_timeout() {
    if [ "${PROFILE:-full}" = 'quick' ]; then
        printf '8'
    else
        printf '30'
    fi
}

# Ejecuta con timeout y sin ruido en stderr.
with_timeout() {
    local t=$1
    shift
    timeout -- "$t" "$@" 2>/dev/null
}

# Usuarios con shell interactiva (root o UID >= 1000).
interactive_users() {
    awk -F: '($3 == 0 || $3 >= 1000) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ { print $1 }' \
        /etc/passwd 2>/dev/null
}

user_home() {
    awk -F: -v u="$1" '$1 == u { print $6; exit }' /etc/passwd 2>/dev/null
}

# ¿La cadena $1 está en la lista separada por espacios $2?
in_list() {
    case " ${2:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# ¿La ruta $1 está dentro de $2?
under_path() {
    case "$1" in
        "$2"|"$2"/*) return 0 ;;
    esac
    return 1
}

# Detección reutilizable de firewall. Imprime ufw|firewalld|nftables|iptables|vacío.
firewall_state() {
    if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        printf 'ufw'
        return
    fi
    if have firewall-cmd && [ "$(firewall-cmd --state 2>/dev/null)" = 'running' ]; then
        printf 'firewalld'
        return
    fi

    local unit
    if systemd_running; then
        for unit in nftables iptables firewalld ufw; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                printf '%s' "$unit"
                return
            fi
        done
    fi

    if have nft; then
        local rules
        rules=$(as_root nft list ruleset 2>/dev/null)
        [ -n "$rules" ] && { printf 'nftables'; return; }
    fi
    if have iptables; then
        local policies
        policies=$(as_root iptables -S 2>/dev/null | grep -c '^-P' || true)
        [ "${policies:-0}" -gt 0 ] && { printf 'iptables'; return; }
    fi

    printf ''
}

trim() {
    local s=$*
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

oneline() {
    tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'
}

term_width() {
    local w=${COLUMNS:-0}
    if [ "$w" -le 0 ] && have tput; then
        w=$(tput cols 2>/dev/null || echo 0)
    fi
    [ "$w" -gt 0 ] || w=100
    [ "$w" -gt 140 ] && w=140
    printf '%s' "$w"
}

die() {
    printf 'watch4me: %s\n' "$*" >&2
    exit 64
}

warn() {
    printf 'watch4me: aviso: %s\n' "$*" >&2
}

# Recorta un texto a N caracteres visibles (sin ANSI, para detalles ya limpios).
clip() {
    local text=$1 max=$2
    if [ "${#text}" -gt "$max" ]; then
        printf '%s…' "${text:0:$((max - 1))}"
    else
        printf '%s' "$text"
    fi
}
