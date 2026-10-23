#!/usr/bin/env bash
# watch4me — adaptador Arch Linux
# Licencia: GPLv3

FAMILY_LABEL='Arch Linux'
PKG_MGR='pacman'

pkg_updates_report() {
    local list
    if have checkupdates; then
        list=$(timeout "$(pkg_timeout 30)" checkupdates 2>/dev/null)
    else
        list=$(timeout "$(pkg_timeout 20)" pacman -Qu 2>/dev/null)
    fi
    printf '%s\n' "$list" | grep -c .
    printf '%s\n' "$list" | grep .
}
