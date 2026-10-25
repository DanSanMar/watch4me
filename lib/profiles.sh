#!/usr/bin/env bash
# watch4me — perfiles de auditoría por tipo de equipo
#
# Un perfil no cambia la profundidad de los checks: cambia QUÉ checks se
# ejecutan. Así «general» es la auditoría completa y «servidor», «cliente» o
# «domestico» son subconjuntos centrados en el uso real del equipo.
#
# Licencia: GPLv3

PROFILE='general'
PROFILE_LABEL='General'
PROFILE_DESC='Auditoría completa: todos los dominios y todos los checks.'

# Checks mínimos para un vistazo rápido. Deben ser baratos y de alto valor.
PROFILE_ESENCIAL='
SYS-02 USR-01 USR-02 USR-04 NET-01 NET-02 SVC-01
FS-02 FS-07 AUTH-02 INT-07 MAL-01 MAL-03 MAL-04
'

# Un servidor no suele tener escritorio, Wi-Fi ni inicio gráfico automático.
PROFILE_SERVIDOR_EXCLUDE='
SYS-06 SYS-07 SYS-13 SYS-14 USR-11 NET-09 AUTH-04
'

# Un cliente no necesita el hardening propio de un servidor expuesto.
PROFILE_CLIENTE_EXCLUDE='
SYS-05 SYS-12
USR-03 USR-06 USR-07 USR-08
NET-03 NET-04 NET-06 NET-07 NET-08
SVC-02 SVC-03 SVC-04 SVC-05 SVC-06 SVC-07 SVC-08
FS-01 FS-06 FS-08 FS-10
AUTH-03 AUTH-05 AUTH-06 AUTH-07 AUTH-08
INT-01 INT-02 INT-05 INT-06
MAL-06 MAL-07
'

# Un PC doméstico: lo importante, explicado sin jerga de servidor.
PROFILE_DOMESTICO='
SYS-01 SYS-02 SYS-03 SYS-07 SYS-08 SYS-13 SYS-14
USR-01 USR-02 USR-04 USR-09 USR-10 USR-11
NET-01 NET-02 NET-05 NET-09
SVC-01
FS-02 FS-03 FS-04 FS-05 FS-07 FS-09
AUTH-01 AUTH-02 AUTH-04
INT-03 INT-04 INT-07
MAL-01 MAL-02 MAL-03 MAL-04 MAL-05
'

# Etiquetas cortas para el catálogo y las fichas.
declare -A PROFILE_SHORT_LABEL=(
    [general]='G'
    [servidor]='S'
    [cliente]='C'
    [domestico]='D'
    [esencial]='E'
)

declare -a PROFILE_EXCLUDED_IDS=()

profile_label() {
    case "${1:-general}" in
        general)   printf 'General' ;;
        servidor)  printf 'Servidor' ;;
        cliente)   printf 'Cliente' ;;
        domestico) printf 'PC doméstico' ;;
        esencial)  printf 'Esencial' ;;
        *)         printf '%s' "${1:-?}" ;;
    esac
}

profile_desc() {
    case "${1:-general}" in
        general)
            printf 'Auditoría completa: todos los dominios y todos los checks.'
            ;;
        servidor)
            printf 'Enfoque servidor: exposición, SSH, servicios, integridad y persistencia. Omite lo propio de un escritorio.'
            ;;
        cliente)
            printf 'Enfoque cliente: actualizaciones, cuentas, firewall, malware, Wi-Fi, cifrado y bloqueo de pantalla. Omite el hardening de servidor.'
            ;;
        domestico)
            printf 'Enfoque PC doméstico: lo importante para un equipo de casa, sin auditoría avanzada de servidor.'
            ;;
        esencial)
            printf 'Vistazo rápido: checks de alto valor y bajo coste. No sustituye a la auditoría general.'
            ;;
        *)
            printf 'Perfil de auditoría.'
            ;;
    esac
}

profile_valid() {
    case "${1:-}" in
        general|servidor|cliente|domestico|esencial) return 0 ;;
    esac
    return 1
}

# Normaliza alias antiguos. quick/full se mantienen para no romper scripts,
# pero ahora significan cosas distintas: quick = esencial, full = general.
profile_normalize() {
    case "${1:-}" in
        full)  printf 'general' ;;
        quick) printf 'esencial' ;;
        *)     printf '%s' "$1" ;;
    esac
}

profile_applies() {
    local profile=$1 id=$2
    case "$profile" in
        general)
            return 0
            ;;
        esencial)
            in_list "$id" "$PROFILE_ESENCIAL"
            ;;
        servidor)
            ! in_list "$id" "$PROFILE_SERVIDOR_EXCLUDE"
            ;;
        cliente)
            ! in_list "$id" "$PROFILE_CLIENTE_EXCLUDE"
            ;;
        domestico)
            in_list "$id" "$PROFILE_DOMESTICO"
            ;;
        *)
            return 1
            ;;
    esac
}

profile_tags() {
    local id=$1 p out=''
    # General incluye el catálogo completo: no aporta información en una fila.
    for p in servidor cliente domestico esencial; do
        profile_applies "$p" "$id" && out+="${PROFILE_SHORT_LABEL[$p]}"
    done
    printf '%s' "$out"
}

profile_names() {
    local id=$1 p out=''
    for p in general servidor cliente domestico esencial; do
        profile_applies "$p" "$id" || continue
        [ -n "$out" ] && out+=', '
        out+=$(profile_label "$p")
    done
    printf '%s' "$out"
}

# IDs separados por espacios, para mensajes e informes.
profile_excluded_text() {
    local id out=''
    for id in "${PROFILE_EXCLUDED_IDS[@]}"; do
        out+="${out:+ }$id"
    done
    printf '%s' "$out"
}

profile_included_text() {
    local profile=$1 id out=''
    for id in "${CHECK_IDS[@]}"; do
        profile_applies "$profile" "$id" || continue
        out+="${out:+ }$id"
    done
    printf '%s' "$out"
}

# Rellena ACTIVE_CHECK_IDS con el perfil actual. CHECK_IDS sigue siendo el
# catálogo completo (lo usan explain, el menú y las fichas).
profile_select() {
    local id
    ACTIVE_CHECK_IDS=()
    for id in "${CHECK_IDS[@]}"; do
        profile_applies "${PROFILE:-general}" "$id" && ACTIVE_CHECK_IDS+=("$id")
    done
}

profile_count() {
    local profile=$1 id n=0
    for id in "${CHECK_IDS[@]}"; do
        profile_applies "$profile" "$id" && n=$(( n + 1 ))
    done
    printf '%s' "$n"
}

profile_excluded_ids() {
    local id
    PROFILE_EXCLUDED_IDS=()
    for id in "${CHECK_IDS[@]}"; do
        profile_applies "${PROFILE:-general}" "$id" || PROFILE_EXCLUDED_IDS+=("$id")
    done
}

profile_set() {
    local requested=$1
    PROFILE=$(profile_normalize "$requested")
    if ! profile_valid "$PROFILE"; then
        die "perfil desconocido: $requested (usa general, servidor, cliente, domestico o esencial)"
    fi
    PROFILE_LABEL=$(profile_label "$PROFILE")
    PROFILE_DESC=$(profile_desc "$PROFILE")
    profile_select
    profile_excluded_ids
}
