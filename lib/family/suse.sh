#!/usr/bin/env bash
# watch4me — adaptador openSUSE / SLES
# Licencia: GPLv3

# FAMILY_LABEL y PKG_MGR los consume lib/distro.sh.
# shellcheck disable=SC2034

FAMILY_LABEL='openSUSE/SLES'
PKG_MGR='zypper'

pkg_updates_report() {
    local raw list
    raw=$(timeout "$(pkg_timeout 60)" zypper -q lu 2>/dev/null)
    list=$(printf '%s\n' "$raw" | awk -F'|' '$1 ~ /^[[:space:]]*v/ { sub(/^[[:space:]]+/, ""); print }')
    printf '%s\n' "$list" | grep -c .
    printf '%s\n' "$list" | grep .
}
