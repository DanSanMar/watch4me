#!/usr/bin/env bash
# watch4me — detección de distribución y carga del adaptador de familia
# Licencia: GPLv3

# FAMILY_LABEL, PKG_MGR y DISTRO_NAME los consumen otros módulos.
# shellcheck disable=SC2034

DISTRO_ID=unknown
DISTRO_LIKE=''
DISTRO_NAME='unknown'
DISTRO_FAMILY=unknown
FAMILY_LABEL='desconocida'
PKG_MGR=''

detect_distro() {
    local k v
    if [ -r /etc/os-release ]; then
        while IFS='=' read -r k v; do
            [ -n "$k" ] || continue
            v=${v%\"}
            v=${v#\"}
            case "$k" in
                ID) DISTRO_ID=$v ;;
                ID_LIKE) DISTRO_LIKE=$v ;;
                PRETTY_NAME) DISTRO_NAME=$v ;;
            esac
        done < /etc/os-release
    fi

    local probe="$DISTRO_ID $DISTRO_LIKE"
    case "$probe" in
        *arch*) DISTRO_FAMILY=arch ;;
        *debian*|*ubuntu*|*mint*|*pop*) DISTRO_FAMILY=debian ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*) DISTRO_FAMILY=rhel ;;
        *suse*|*sles*) DISTRO_FAMILY=suse ;;
        *)
            if have pacman; then
                DISTRO_FAMILY=arch
            elif have apt-get; then
                DISTRO_FAMILY=debian
            elif have dnf || have yum; then
                DISTRO_FAMILY=rhel
            elif have zypper; then
                DISTRO_FAMILY=suse
            else
                DISTRO_FAMILY=unknown
            fi
            ;;
    esac

    local adapter="$LIB_DIR/family/$DISTRO_FAMILY.sh"
    if [ -r "$adapter" ]; then
        # shellcheck source=/dev/null
        . "$adapter"
    fi
}

# Cada adaptador define pkg_updates_report: primera línea = número de
# actualizaciones, siguientes líneas = listado para la evidencia.
# Si no hay adaptador o no soporta la operación, devuelve fallo.
pkg_update_supported() {
    declare -F pkg_updates_report >/dev/null 2>&1
}

# Timeout adaptado al perfil: el vistazo esencial divide entre 3 (mínimo 5 s).
pkg_timeout() {
    local t=${1:-30}
    case "${PROFILE:-general}" in
        esencial|quick)
            t=$(( t / 3 ))
            [ "$t" -lt 5 ] && t=5
            ;;
    esac
    printf '%s' "$t"
}
