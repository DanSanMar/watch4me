#!/usr/bin/env bash
# watch4me — adaptador Fedora / RHEL / derivados
# Licencia: GPLv3

FAMILY_LABEL='Fedora/RHEL'
PKG_MGR='dnf'

pkg_updates_report() {
    local raw list
    if have dnf; then
        raw=$(timeout "$(pkg_timeout 60)" dnf -q check-update 2>/dev/null)
    else
        raw=$(timeout "$(pkg_timeout 60)" yum -q check-update 2>/dev/null)
    fi
    list=$(printf '%s\n' "$raw" | awk 'NF == 3 && $2 ~ /^[0-9]/')
    printf '%s\n' "$list" | grep -c .
    printf '%s\n' "$list" | grep .
}
