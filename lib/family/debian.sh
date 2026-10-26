#!/usr/bin/env bash
# watch4me — adaptador Debian / Ubuntu
# Licencia: GPLv3

# FAMILY_LABEL y PKG_MGR los consume lib/distro.sh.
# shellcheck disable=SC2034

FAMILY_LABEL='Debian/Ubuntu'
PKG_MGR='apt'

pkg_updates_report() {
    local list
    list=$(timeout "$(pkg_timeout 45)" apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst ')
    printf '%s\n' "$list" | grep -c .
    printf '%s\n' "$list" | grep .
}
