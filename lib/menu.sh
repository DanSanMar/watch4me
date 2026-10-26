#!/usr/bin/env bash
# watch4me — menú interactivo basado en fzf
#
# El menú es opcional: la auditoría funciona sin fzf. Si falta, se ofrece
# instalarlo con el gestor de la distribución tras confirmación explícita.
# Esa instalación es la única acción del programa que modifica el sistema.
#
# Licencia: GPLv3

# Variables compartidas con watch4me.sh y las librerías de checks.
# shellcheck disable=SC2034

MENU_TAB=$'\t'
MENU_LOGO_PID=''
MENU_LOGO_TICKS=${MENU_LOGO_TICKS:-15}   # 15 x 0,2 s = cambio de color cada 3 s
MENU_EXIT_SHOWN=0
MENU_SUDO=0

# Orden estable de los dominios en el catálogo y sus submenús. No se usa el
# orden de CHECK_IDS porque puede variar al añadir ficheros de checks.
MENU_DOMAIN_ORDER=(SYS USR NET SVC FS AUTH INT MAL)

# ---------------------------------------------------------------------------
# Logo animado del menú
#
# Redibuja la primera línea cada 3 s (como el refresco de dash4me.sh) con
# los colores de su tabla, calculados a partir del segundo actual. La
# velocidad de la animación de auditoría no cambia.
# ---------------------------------------------------------------------------

menu_logo_redraw() {
    # Guarda el cursor, va a la línea 1, borra y redibuja el logo.
    menu_refresh_width
    printf '\0337\033[1;1H\033[K%s\0338' "$(ui_line1 0 menu)"
}

menu_logo_start() {
    menu_logo_stop
    [ "${UI_ANIM:-0}" -eq 1 ] || return 0
    [ -t 1 ] || return 0

    (
        local ticks=0
        while :; do
            # Ticks cortos para que matar el animador no bloquee la salida.
            sleep 0.2 2>/dev/null || sleep 1
            ticks=$(( ticks + 1 ))
            [ "$ticks" -lt "${MENU_LOGO_TICKS:-15}" ] && continue
            ticks=0
            menu_logo_redraw
        done
    ) &
    MENU_LOGO_PID=$!
}

menu_logo_stop() {
    if [ -n "${MENU_LOGO_PID:-}" ]; then
        kill "$MENU_LOGO_PID" 2>/dev/null || true
        wait "$MENU_LOGO_PID" 2>/dev/null || true
        MENU_LOGO_PID=''
    fi
}

# Mensaje de despedida (ESC, Ctrl-C, «Salir» o cualquier salida del menú).
menu_exit_msg() {
    [ "${MENU_EXIT_SHOWN:-0}" -eq 1 ] && return 0
    MENU_EXIT_SHOWN=1
    local rule sep
    if [ "${UI_UTF8:-0}" -eq 1 ]; then
        rule='────────────────────────────────────────'
        sep='·'
    else
        rule='----------------------------------------'
        sep='-'
    fi
    printf '\n%s%s%s\n' "$C_DIM" "$rule" "$C_RESET"
    printf ' %s%s%s %sHas salido de watch4me.%s\n' \
        "$C_BOLD$C_CYAN_B" "$(ui_icon '👋' '[x]')" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf ' %sAuditoría directa sin menú:%s %s./watch4me.sh audit%s\n' \
        "$C_DIM" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf ' %sAtajos:%s ./watch4me.sh --help %s%s%s ./watch4me.sh --version\n' \
        "$C_DIM" "$C_RESET" "$C_DIM" "$sep" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$rule" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Utilidades de presentación
# ---------------------------------------------------------------------------

menu_clear() {
    if [ -t 1 ] && have clear; then
        clear 2>/dev/null || printf '\n'
    else
        printf '\n'
    fi
}

menu_sep() {
    if [ "${UI_UTF8:-0}" -eq 1 ]; then
        printf '·'
    else
        printf '-'
    fi
}

# Una fila del menú: texto visible <TAB> valor interno.
menu_row() {
    printf '%s\t%s\n' "$1" "$2"
}

menu_pause() {
    [ -t 0 ] || return 0
    local msg='Pulsa ENTER para volver al menú...'
    [ "${UI_UTF8:-0}" -eq 1 ] && msg='Pulsa ENTER para volver al menú…'
    printf '\n%s%s%s ' "$C_DIM" "$msg" "$C_RESET"
    local _
    read -r _ || true
}

menu_prompt() {
    if [ "${UI_UTF8:-0}" -eq 1 ]; then
        printf '%s ❯ ' "$1"
    else
        printf '%s > ' "$1"
    fi
}

menu_term_cols() {
    local size
    size=$(stty size 2>/dev/null < /dev/tty || true)
    if [[ "$size" =~ ^[0-9]+[[:space:]]+([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    size=$(tput cols 2>/dev/null || true)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    printf '%s' "$size"
}

# Recalcula el ancho real de la terminal para adaptar la cabecera tras un
# redimensionado (UI_WIDTH de ui_init puede quedar obsoleto).
menu_refresh_width() {
    local cols
    cols=$(menu_term_cols)
    [ "$cols" -gt 0 ] || cols=${UI_WIDTH:-100}
    [ "$cols" -gt 140 ] && cols=140
    UI_WIDTH=$cols
    if [ "$cols" -lt 70 ]; then
        UI_COMPACT=1
    else
        UI_COMPACT=0
    fi
}

menu_header() {
    local context=${1:-} detail=${2:-} sep
    sep=$(menu_sep)
    menu_refresh_width
    ui_menu_extra_widths
    menu_logo_stop
    menu_clear
    if [ "${UI_ANIM:-0}" -eq 1 ]; then
        printf '\033[1;1H%s\n' "$(ui_line1 0 menu)"
    else
        printf '%s\n' "$(ui_line1_static menu)"
    fi

    # Cabecera de un submenú: título y explicación breve de lo que hay dentro.
    if [ -n "$context" ]; then
        printf ' %s%s%s\n' "$C_BOLD$C_CYAN_B" "$context" "$C_RESET"
        [ -n "$detail" ] && printf ' %s%s%s\n' "$C_DIM" "$detail" "$C_RESET"
        printf '\n'
        menu_logo_start
        return 0
    fi

    if [ "${UI_COMPACT:-0}" -eq 0 ] \
        && [ "${UI_WIDTH:-0}" -ge "${UI_HOST_MIN_WIDTH:-92}" ]; then
        # El host ya aparece en el logo: no se repite en la segunda línea.
        printf ' %s%d checks%s %s %sdistro:%s %s\n' \
            "$C_DIM" "${#CHECK_IDS[@]}" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET" "${DISTRO_FAMILY:-unknown}"
    elif [ "${UI_WIDTH:-0}" -ge 46 ]; then
        printf ' %s%d checks%s %s %shost:%s %s %s %sdistro:%s %s\n' \
            "$C_DIM" "${#CHECK_IDS[@]}" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET" "${HOSTNAME_SHORT:-localhost}" "$sep" \
            "$C_DIM" "$C_RESET" "${DISTRO_FAMILY:-unknown}"
    else
        # Muy estrecho: solo el contador para no robar líneas a fzf.
        printf ' %s%d checks%s\n' "$C_DIM" "${#CHECK_IDS[@]}" "$C_RESET"
    fi
    if [ "${UI_WIDTH:-0}" -ge 78 ]; then
        printf ' %sAuditorías = 5 perfiles%s %s %sHistorial = baseline e informes%s\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET"
        printf ' %sVigilancia = watch%s %s %sCatálogo = fichas%s %s %s+sudo = más datos%s\n\n' \
            "$C_BOLD$C_GREEN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET"
    elif [ "${UI_WIDTH:-0}" -ge 52 ]; then
        printf ' %s5 perfiles%s %s %sHistorial%s %s %sCatálogo%s %s %s+sudo%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_GREEN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET"
    else
        printf ' %sPerfiles%s %s %sHistorial%s %s %sCatálogo%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_GREEN_B" "$C_RESET"
    fi
    menu_logo_start
}

# ---------------------------------------------------------------------------
# fzf
# ---------------------------------------------------------------------------

# Altura del panel de fzf: 85 % de la terminal, pero sin tapar la cabecera
# (4 líneas). Así el logo animado de la línea 1 nunca queda fuera de pantalla.
menu_term_lines() {
    local size
    size=$(stty size 2>/dev/null < /dev/tty || true)
    if [[ "$size" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
        printf '%s' "${size%% *}"
        return 0
    fi
    size=$(tput lines 2>/dev/null || true)
    [[ "$size" =~ ^[0-9]+$ ]] || size=24
    printf '%s' "$size"
}

menu_fzf_height() {
    local lines h max
    lines=$(menu_term_lines)
    [ "$lines" -gt 0 ] || lines=24
    h=$(( lines * 85 / 100 ))
    max=$(( lines - 6 ))
    [ "$h" -gt "$max" ] && h=$max
    [ "$h" -lt 6 ] && h=6
    printf '%s' "$h"
}

menu_fzf_opts() {
    local prompt=$1 header=$2 kind=$3
    local self bashq prev ptr mark height

    self=$(printf '%q' "$SCRIPT_DIR/watch4me.sh")
    bashq=$(printf '%q' "${BASH:-bash}")
    prev="WATCH4ME_PREVIEW_COLOR=${UI_COLOR:-0} WATCH4ME_PREVIEW_SUDO=${MENU_SUDO:-0} ${bashq} ${self} __preview ${kind} {2}"
    if [ "${UI_UTF8:-0}" -eq 1 ]; then
        ptr='▶'
        mark='✓'
    else
        ptr='>'
        mark='*'
    fi
    height=$(menu_fzf_height)

    FZF_OPTS=(
        --ansi --reverse --no-sort --cycle
        --height="$height" --border=rounded
        --delimiter="$MENU_TAB" --with-nth=1
        --prompt="$prompt"
        --header="$header"
        --pointer="$ptr" --marker="$mark"
        --preview="$prev"
        --preview-window='right:58%:wrap'
    )

    if [ "${UI_COLOR:-0}" -eq 1 ]; then
        FZF_OPTS+=(
            --color='fg:#d0d0d0,bg:-1,hl:#5fd7ff,fg+:#ffffff,bg+:#2a2a2a,hl+:#5fd7ff,info:#8a8a8a,prompt:#5fd7ff,pointer:#92ff92,marker:#ffd75f,spinner:#ffd75f,header:#5fb2ff,border:#00ffff'
        )
    else
        FZF_OPTS+=(--no-color)
    fi
}

menu_fzf() {
    local prompt=$1 header=$2 kind=$3
    menu_fzf_opts "$prompt" "$header" "$kind"
    fzf "${FZF_OPTS[@]}"
}

menu_privileged() {
    if is_root; then
        "$@"
    elif have sudo; then
        sudo -- "$@"
    elif have doas; then
        doas "$@"
    else
        return 1
    fi
}

menu_install_cmd() {
    case "${PKG_MGR:-}" in
        pacman) printf 'sudo pacman -S fzf' ;;
        apt)    printf 'sudo apt-get install fzf' ;;
        dnf)    printf 'sudo dnf install fzf' ;;
        zypper) printf 'sudo zypper install fzf' ;;
        *)      printf '' ;;
    esac
}

# Instala fzf con el gestor nativo. Solo se llama tras confirmación explícita.
menu_install_fzf() {
    local rc=1
    printf '%sInstalando fzf con %s...%s\n' "$C_BOLD" "${FAMILY_LABEL:-el gestor de paquetes}" "$C_RESET"

    case "${PKG_MGR:-}" in
        pacman)
            menu_privileged pacman -S --needed --noconfirm fzf && rc=0
            ;;
        apt)
            menu_privileged apt-get install -y fzf && rc=0
            if [ "$rc" -ne 0 ]; then
                menu_privileged apt-get update \
                    && menu_privileged apt-get install -y fzf && rc=0
            fi
            ;;
        dnf)
            menu_privileged dnf install -y fzf && rc=0
            ;;
        zypper)
            menu_privileged zypper --non-interactive install fzf && rc=0
            ;;
    esac

    hash -r 2>/dev/null || true
    if [ "$rc" -eq 0 ] && have fzf; then
        printf '%sfzf instalado correctamente.%s\n' "$C_GREEN_B" "$C_RESET"
        return 0
    fi
    printf '%sNo se pudo instalar fzf.%s\n' "$C_RED_B" "$C_RESET"
    return 1
}

menu_ensure_fzf() {
    have fzf && return 0

    local manual
    manual=$(menu_install_cmd)
    menu_clear
    printf '%sEl menú interactivo necesita fzf.%s\n\n' "$C_YELLOW_B" "$C_RESET"
    printf 'fzf es una dependencia opcional: la auditoría funciona sin él.\n'
    printf '  %s./watch4me.sh audit%s\n\n' "$C_BOLD" "$C_RESET"
    if [ -n "$manual" ]; then
        printf 'Instalación manual sugerida:\n  %s%s%s\n\n' "$C_BOLD" "$manual" "$C_RESET"
    else
        printf 'Instálalo con el gestor de paquetes de tu distribución.\n\n'
        printf 'No se detectó un gestor compatible para instalarlo automáticamente.\n'
        return 1
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf 'watch4me: sin terminal interactiva no se puede pedir confirmación.\n' >&2
        return 1
    fi
    if [ "${WATCH4ME_NO_INSTALL:-0}" = '1' ]; then
        printf 'WATCH4ME_NO_INSTALL=1: no se instala nada.\n'
        return 1
    fi

    printf 'La instalación es la única acción que modifica el sistema.\n'
    printf '¿Instalar fzf ahora con %s? [s/N] ' "${FAMILY_LABEL:-el gestor de paquetes}"
    local ans=''
    read -r ans || ans=''
    case "$ans" in
        s|S|si|sí|Si|Sí|y|Y|yes|YES|Yes)
            menu_install_fzf || return 1
            ;;
        *)
            printf '\nNo se instala nada. El menú no está disponible.\n'
            return 1
            ;;
    esac

    have fzf
}

# ---------------------------------------------------------------------------
# Filas del menú principal
# ---------------------------------------------------------------------------

# ¿Hay caché de sudo utilizable? No se pide contraseña.
menu_sudo_ready() {
    is_root && return 0
    have sudo || return 1
    sudo -n true 2>/dev/null
}

menu_rows_main() {
    local sep sudo_state
    sep=$(menu_sep)
    if [ "${MENU_SUDO:-0}" -eq 1 ]; then
        if menu_sudo_ready; then
            sudo_state='[x] activado'
        else
            sudo_state='[x] sin caché'
        fi
    else
        sudo_state='[ ] desactivado'
    fi

    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '▶' '>')${C_RESET} ${C_BOLD}Auditorías de seguridad${C_RESET} ${C_DIM}${sep}${C_RESET} 5 perfiles ${sep} ${#CHECK_IDS[@]} checks" "audit-profiles"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '📊' '[H]')${C_RESET} ${C_BOLD}Historial y cambios${C_RESET} ${C_DIM}${sep}${C_RESET} baseline, monitor e informes guardados" "history"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '👁' '[w]')${C_RESET} ${C_BOLD}Vigilancia${C_RESET} ${C_DIM}${sep}${C_RESET} en vivo o una sola captura" "watch-menu"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔎' '[?]')${C_RESET} ${C_BOLD}Catálogo y fichas${C_RESET} ${C_DIM}${sep}${C_RESET} buscar, explorar por dominio o ver los ${#CHECK_IDS[@]}" "catalog-menu"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔑' '[s]')${C_RESET} ${C_BOLD}Lecturas con sudo${C_RESET} ${C_DIM}${sep}${C_RESET} ${sudo_state} ${sep} no pide contraseña" "toggle-sudo"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '❓' '[h]')${C_RESET} ${C_BOLD}Ayuda y atajos${C_RESET} ${C_DIM}${sep}${C_RESET} cómo funciona, CLI, códigos y seguridad" "help"
    menu_row "${C_BOLD}${C_RED_B}$(ui_icon '⏻' '[x]')${C_RESET} ${C_BOLD}Salir${C_RESET} ${C_DIM}${sep}${C_RESET} cerrar sin ejecutar nada" "quit"
}

# Filas de los submenús. El segundo campo oculto es el que decide la acción.
menu_rows_audits() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '▶' '>')${C_RESET} ${C_BOLD}Auditoría general${C_RESET} ${C_DIM}${sep}${C_RESET} recomendada ${sep} ${#CHECK_IDS[@]} checks" "audit-general"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '🖥' '[S]')${C_RESET} ${C_BOLD}Servidor${C_RESET} ${C_DIM}${sep}${C_RESET} SSH, servicios e integridad ${sep} $(profile_count servidor) checks" "audit-servidor"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '💻' '[C]')${C_RESET} ${C_BOLD}Cliente${C_RESET} ${C_DIM}${sep}${C_RESET} escritorio, Wi-Fi y cifrado ${sep} $(profile_count cliente) checks" "audit-cliente"
    menu_row "${C_BOLD}${C_MAGENTA_B}$(ui_icon '🏠' '[D]')${C_RESET} ${C_BOLD}PC doméstico${C_RESET} ${C_DIM}${sep}${C_RESET} lo importante de casa ${sep} $(profile_count domestico) checks" "audit-domestico"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '⚡' '!')${C_RESET} ${C_BOLD}Vistazo esencial${C_RESET} ${C_DIM}${sep}${C_RESET} rápido ${sep} $(profile_count esencial) checks" "audit-esencial"
    menu_row "${C_DIM}$(ui_icon '↩' '<') Volver al menú principal${C_RESET} ${C_DIM}${sep}${C_RESET} ESC también vuelve${C_RESET}" "back"
}

menu_rows_history() {
    local sep base_state
    sep=$(menu_sep)
    base_state='sin baseline'
    if declare -F baseline_exists >/dev/null 2>&1 && baseline_exists; then
        base_state='baseline disponible'
    fi
    menu_row "${C_BOLD}${C_MAGENTA_B}$(ui_icon '📌' '[b]')${C_RESET} ${C_BOLD}Crear baseline (general)${C_RESET} ${C_DIM}${sep}${C_RESET} guarda una foto de la auditoría" "baseline"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '📋' '[v]')${C_RESET} ${C_BOLD}Ver baseline guardada${C_RESET} ${C_DIM}${sep}${C_RESET} ${base_state} ${sep} no ejecuta checks" "baseline-show"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '📈' '[m]')${C_RESET} ${C_BOLD}Monitorizar cambios${C_RESET} ${C_DIM}${sep}${C_RESET} compara la auditoría con la baseline" "monitor"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '📄' '[r]')${C_RESET} ${C_BOLD}Informes guardados${C_RESET} ${C_DIM}${sep}${C_RESET} consulta los .md y .json de reports/" "reports"
    menu_row "${C_DIM}$(ui_icon '↩' '<') Volver al menú principal${C_RESET} ${C_DIM}${sep}${C_RESET} ESC también vuelve${C_RESET}" "back"
}

menu_rows_watch() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '👁' '[w]')${C_RESET} ${C_BOLD}Vigilancia en vivo${C_RESET} ${C_DIM}${sep}${C_RESET} compara capturas cada 3 s ${sep} Ctrl-C vuelve" "watch"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '📸' '[1]')${C_RESET} ${C_BOLD}Una sola captura${C_RESET} ${C_DIM}${sep}${C_RESET} revisa y sale ${sep} ideal para scripts o cron" "watch-once"
    menu_row "${C_DIM}$(ui_icon '↩' '<') Volver al menú principal${C_RESET} ${C_DIM}${sep}${C_RESET} ESC también vuelve${C_RESET}" "back"
}

menu_rows_catalog() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔎' '[?]')${C_RESET} ${C_BOLD}Buscar una ficha${C_RESET} ${C_DIM}${sep}${C_RESET} por ID, título o dominio" "explain-pick"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🗂' '[D]')${C_RESET} ${C_BOLD}Explorar por dominio${C_RESET} ${C_DIM}${sep}${C_RESET} sistema, usuarios, red, servicios…" "catalog-domains"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '📚' '[c]')${C_RESET} ${C_BOLD}Catálogo completo${C_RESET} ${C_DIM}${sep}${C_RESET} los ${#CHECK_IDS[@]} checks en un buscador fzf" "catalog-all"
    menu_row "${C_DIM}$(ui_icon '↩' '<') Volver al menú principal${C_RESET} ${C_DIM}${sep}${C_RESET} ESC también vuelve${C_RESET}" "back"
}

menu_domain_desc() {
    case "${1:-}" in
        SYS)  printf 'Reloj, kernel, actualizaciones, arranque, cifrado y bloqueo.' ;;
        USR)  printf 'Cuentas, contraseñas, sudoers, permisos de home e inicio de sesión.' ;;
        NET)  printf 'Puertos, firewall, interfaces, SSH expuesto, contenedores y Wi-Fi.' ;;
        SVC)  printf 'Servicios systemd, SSH, contenedores, auditoría y logs.' ;;
        FS)   printf 'Permisos de bases de usuarios, SUID, temporales y rutas de confianza.' ;;
        AUTH) printf 'PAM, contraseña de root, GRUB, bloqueos de intentos y sesiones.' ;;
        INT)  printf 'Paquetes, cron, systemd, claves, capacidades y directorios del PATH.' ;;
        MAL)  printf 'ld.so.preload, procesos sospechosos, temporales y módulos del kernel.' ;;
        *)    printf 'Dominio de seguridad.' ;;
    esac
}

menu_rows_domains() {
    local dom id n sep
    sep=$(menu_sep)
    for dom in "${MENU_DOMAIN_ORDER[@]}"; do
        n=0
        for id in "${CHECK_IDS[@]}"; do
            [ "$(domain_of "$id")" = "$dom" ] && n=$(( n + 1 ))
        done
        menu_row "${C_BOLD}${C_CYAN_B}${DOMAIN_NAME[$dom]:-$dom}${C_RESET} ${C_DIM}($dom)${C_RESET} ${C_DIM}${sep}${C_RESET} ${n} checks ${sep} $(menu_domain_desc "$dom")" "domain-$dom"
    done
    menu_row "${C_DIM}$(ui_icon '↩' '<') Volver al catálogo${C_RESET} ${C_DIM}${sep}${C_RESET} ESC también vuelve${C_RESET}" "back"
}

# Lanza un submenú y devuelve su campo oculto. Cualquier salida de fzf
# (ESC, Ctrl-C, error o lista sin coincidencias) se traduce en «volver».
menu_pick_row() {
    local rows_fn=$1 prompt=$2 header=$3 kind=$4 sel rc
    sel=$("$rows_fn" | menu_fzf "$(menu_prompt "$prompt")" "$header" "$kind")
    rc=$?
    menu_logo_stop
    if [ "$rc" -ne 0 ] || [ -z "$sel" ]; then
        return 130
    fi
    printf '%s' "${sel##*"$MENU_TAB"}"
}

menu_audits() {
    local id rc
    while :; do
        menu_header "Auditorías de seguridad · 5 perfiles" \
            'General revisa todo; los demás cambian qué checks se ejecutan, no su profundidad.'
        id=$(menu_pick_row menu_rows_audits 'auditoría' \
            'ENTER ejecuta | ESC vuelve al menú principal | panel derecho: alcance, tiempo y guardado' \
            action)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        case "$id" in
            audit-general)   menu_run_audit general ;;
            audit-servidor)  menu_run_audit servidor ;;
            audit-cliente)   menu_run_audit cliente ;;
            audit-domestico) menu_run_audit domestico ;;
            audit-esencial)  menu_run_audit esencial ;;
            back)            return 0 ;;
        esac
    done
}

menu_history() {
    local id rc
    while :; do
        menu_header "Historial y cambios · baseline, monitor e informes" \
            'La baseline es una foto; monitor la compara; los informes son auditorías guardadas.'
        id=$(menu_pick_row menu_rows_history 'historial' \
            'ENTER ejecuta | ESC vuelve al menú principal | panel derecho: qué guarda o compara' \
            action)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        case "$id" in
            baseline)      menu_baseline create ;;
            baseline-show) menu_baseline show ;;
            monitor)       menu_monitor ;;
            reports)       menu_reports ;;
            back)          return 0 ;;
        esac
    done
}

menu_watch_menu() {
    local id rc
    while :; do
        menu_header "Vigilancia · watch" \
            'En vivo compara capturas cada 3 s; la captura única sale al terminar.'
        id=$(menu_pick_row menu_rows_watch 'vigilancia' \
            'ENTER abre | ESC vuelve al menú principal | panel derecho: requisitos y cómo salir' \
            action)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        case "$id" in
            watch)      menu_watch live ;;
            watch-once) menu_watch once ;;
            back)       return 0 ;;
        esac
    done
}

menu_catalog_domains() {
    local id dom rc
    while :; do
        menu_header "Catálogo por dominio · 8 grupos" \
            'Elige un dominio para ver sus checks; el panel derecho resume qué cubre.'
        id=$(menu_pick_row menu_rows_domains 'dominio' \
            'ENTER elige dominio | ESC vuelve al catálogo | panel derecho: cobertura' \
            domain)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        case "$id" in
            domain-*)
                dom=${id#domain-}
                menu_pick_check "$dom" \
                    "Catálogo · ${DOMAIN_NAME[$dom]:-$dom}" \
                    "$(menu_domain_desc "$dom")"
                ;;
            back)
                return 0
                ;;
        esac
    done
}

menu_catalog_menu() {
    local id rc
    while :; do
        menu_header "Catálogo y fichas · ${#CHECK_IDS[@]} checks" \
            'Busca por ID, título o dominio; ENTER abre la ficha y ESC vuelve.'
        id=$(menu_pick_row menu_rows_catalog 'catálogo' \
            'ENTER abre | ESC vuelve al menú principal | panel derecho: qué incluye' \
            action)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        case "$id" in
            explain-pick)
                menu_pick_check '' 'Ficha de un check' \
                    'Escribe un ID, un título o un dominio; ENTER abre la descripción y el remedio.'
                ;;
            catalog-domains)
                menu_catalog_domains
                ;;
            catalog-all)
                menu_catalog_all
                ;;
            back)
                return 0
                ;;
        esac
    done
}


# ---------------------------------------------------------------------------
# Acciones
# ---------------------------------------------------------------------------

menu_run_audit() {
    local profile=$1 anim_save=$UI_ANIM

    profile_set "$profile" || return $?
    USE_SUDO=${MENU_SUDO:-0}
    SUDO_CHECKED=0
    SUDO_OK=0
    SAVE_TO=''

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''

    menu_clear
    init_run_dir || return 64
    run_checks
    compute_scores
    render_terminal
    compute_exit_code
    EXIT_CODE=$?
    maybe_save

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''
    SAVE_TO=''
    UI_ANIM=$anim_save

    menu_pause
    return 0
}

menu_watch() {
    local mode=${1:-live}
    local rc anim_save=$UI_ANIM

    USE_SUDO=${MENU_SUDO:-0}
    SUDO_CHECKED=0
    SUDO_OK=0
    WATCH_ONCE=0
    [ "$mode" = 'once' ] && WATCH_ONCE=1
    menu_clear
    watch_main
    rc=$?

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''
    UI_ANIM=$anim_save

    menu_pause
    return "$rc"
}

menu_baseline() {
    local mode=${1:-create}
    local rc anim_save=$UI_ANIM

    USE_SUDO=${MENU_SUDO:-0}
    SUDO_CHECKED=0
    SUDO_OK=0
    SAVE_TO=''
    PROFILE='general'
    PROFILE_EXPLICIT=0
    BASELINE_SHOW=0
    [ "$mode" = 'show' ] && BASELINE_SHOW=1
    FORCE=0

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''

    menu_clear
    baseline_main
    rc=$?

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''
    SAVE_TO=''
    UI_ANIM=$anim_save

    menu_pause
    return "$rc"
}

menu_monitor() {
    local rc anim_save=$UI_ANIM

    USE_SUDO=${MENU_SUDO:-0}
    SUDO_CHECKED=0
    SUDO_OK=0
    SAVE_TO=''
    PROFILE_EXPLICIT=0
    BASELINE_SHOW=0
    FORCE=0

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''

    menu_clear
    monitor_main
    rc=$?

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''
    SAVE_TO=''
    UI_ANIM=$anim_save

    menu_pause
    return "$rc"
}

menu_rows_checks() {
    local domain=${1:-} id sev dom color label
    # Agrupado por dominio para que el catálogo completo sea fácil de recorrer.
    for dom in "${MENU_DOMAIN_ORDER[@]}"; do
        [ -n "$domain" ] && [ "$dom" != "$domain" ] && continue
        for id in "${CHECK_IDS[@]}"; do
            [ "$(domain_of "$id")" = "$dom" ] || continue
            sev=${CHECK_SEVERITY[$id]}
            case "$sev" in
                critical) color=$C_RED_B ;;
                high)     color=$C_YELLOW_B ;;
                medium)   color=$C_YELLOW ;;
                low)      color=$C_CYAN ;;
                *)        color=$C_DIM ;;
            esac
            label=$(sev_label "$sev")
            printf '%s %s[%s]%s %s %s%s%s\t%s\n' \
                "$C_BOLD$id$C_RESET" "$color" "$label" "$C_RESET" \
                "${CHECK_TITLE[$id]}" "$C_DIM" \
                "$(menu_sep) ${DOMAIN_NAME[$dom]:-$dom}" "$C_RESET" "$id"
        done
    done
}

menu_pick_check() {
    local domain=${1:-} sep
    local title=${2:-}
    local subtitle=${3:-}
    local sel rc id

    [ -n "$title" ] || title='Ficha de un check'
    [ -n "$subtitle" ] || subtitle='Escribe un ID, un título o un dominio; ENTER abre la descripción y el remedio.'
    sep=$(menu_sep)

    # Bucle propio: al cerrar una ficha se vuelve a la lista para seguir
    # consultando checks sin salir al menú anterior.
    while :; do
        menu_header "$title" "$subtitle"
        sel=$( {
            menu_rows_checks "$domain"
            menu_row "${C_DIM}$(ui_icon '↩' '<') Volver${C_RESET} ${C_DIM}${sep} ESC también vuelve${C_RESET}" "back"
        } | menu_fzf \
            "$(menu_prompt check)" \
            'ENTER: ficha completa | escribe ID, título o dominio | ESC: volver' \
            check)
        rc=$?
        menu_logo_stop
        if [ "$rc" -ne 0 ] || [ -z "$sel" ]; then
            return 0
        fi
        id=${sel##*"$MENU_TAB"}
        [ "$id" = 'back' ] && return 0
        menu_clear
        explain_check "$id"
        menu_pause
    done
}

# El catálogo completo se navega con fzf, igual que el resto del menú. Así
# ESC o Ctrl-C vuelven al catálogo sin quedar atrapado en un paginador
# externo. La versión CLI sigue disponible con explain --list.
menu_catalog_all() {
    menu_pick_check '' \
        "Catálogo completo · ${#CHECK_IDS[@]} checks + Volver" \
        'Buscador fzf: escribe para filtrar; ENTER abre la ficha; ESC vuelve sin paginador externo.'
}

menu_show_catalog() {
    menu_catalog_all
}

menu_pager() {
    local path=$1 hint
    menu_clear
    if [ -t 0 ] && [ -t 1 ] && have less; then
        if [ "${UI_UTF8:-0}" -eq 1 ]; then
            hint='q: volver al menú · ESPACIO: avanzar · /: buscar'
        else
            hint='q: volver al menu - ESPACIO: avanzar - /: buscar'
        fi
        less -R -F -X -P "$hint" -- "$path"
    else
        cat -- "$path"
        menu_pause
    fi
}

menu_reports() {
    local -a files=() candidates=()
    local f sel rc path display size stamp sep kind old_nullglob
    sep=$(menu_sep)

    # Markdown y JSON de cada auditoría, siempre del más reciente al más antiguo.
    old_nullglob=$(shopt -p nullglob 2>/dev/null || true)
    shopt -s nullglob
    candidates=("$SCRIPT_DIR"/reports/*.md "$SCRIPT_DIR"/reports/*.json)
    eval "${old_nullglob:-shopt -u nullglob}"
    if [ "${#candidates[@]}" -gt 0 ]; then
        while IFS= read -r f; do
            [ -f "$f" ] && files+=("$f")
        done < <(ls -1t -- "${candidates[@]}" 2>/dev/null)
    fi

    if [ "${#files[@]}" -eq 0 ]; then
        menu_clear
        printf '%sNo hay informes en reports/%s\n\n' "$C_YELLOW_B" "$C_RESET"
        printf 'Ejecuta una auditoría y responde «s» cuando ofrezca guardar.\n'
        printf 'También puedes usar:\n'
        printf '  %s./watch4me.sh audit --save%s\n' "$C_BOLD" "$C_RESET"
        menu_pause
        return 0
    fi

    local -a rows=()
    for f in "${files[@]}"; do
        size=$(du -h -- "$f" 2>/dev/null | cut -f1)
        stamp=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '')
        case "$f" in
            *.json) kind='JSON' ;;
            *)      kind='MD' ;;
        esac
        display="${C_BOLD}$(basename -- "$f")${C_RESET} ${C_DIM}${sep}${C_RESET} ${C_CYAN}${kind}${C_RESET} ${C_DIM}${sep}${C_RESET} ${stamp:-sin fecha} ${C_DIM}${sep}${C_RESET} ${size:-?}"
        rows+=("${display}"$'\t'"${f}")
    done

    sel=$(printf '%s\n' "${rows[@]}" | menu_fzf \
        "$(menu_prompt informe)" \
        'ENTER: abrir en el paginador | escribe para filtrar | ESC: volver' \
        report)
    rc=$?
    menu_logo_stop
    [ "$rc" -eq 130 ] && return 0
    [ -z "$sel" ] && return 0
    path=${sel##*"$MENU_TAB"}

    menu_pager "$path"
}

# ---------------------------------------------------------------------------
# Ayuda y atajos
# ---------------------------------------------------------------------------

menu_rows_help() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}./watch4me.sh${C_RESET} ${C_DIM}${sep}${C_RESET} menú en terminal y auditoría cuando no hay TTY" "basic"
    menu_row "${C_BOLD}Cómo funciona el menú${C_RESET} ${C_DIM}${sep}${C_RESET} grupos, ESC, panel de vista previa y salida" "menu-map"
    menu_row "${C_BOLD}Solo lectura y límites${C_RESET} ${C_DIM}${sep}${C_RESET} qué toca watch4me y qué nunca modifica" "safety"
    menu_row "${C_BOLD}./watch4me.sh audit${C_RESET} ${C_DIM}${sep}${C_RESET} auditoría general (${#CHECK_IDS[@]} checks) sin menú" "audit"
    menu_row "${C_BOLD}./watch4me.sh audit --profile <perfil>${C_RESET} ${C_DIM}${sep}${C_RESET} servidor, cliente, doméstico o esencial" "profiles"
    menu_row "${C_BOLD}./watch4me.sh watch${C_RESET} ${C_DIM}${sep}${C_RESET} vigilancia en vivo de conexiones y servicios" "watch"
    menu_row "${C_BOLD}./watch4me.sh watch --once${C_RESET} ${C_DIM}${sep}${C_RESET} una sola captura, útil en scripts o cron" "watch-once"
    menu_row "${C_BOLD}./watch4me.sh baseline${C_RESET} ${C_DIM}${sep}${C_RESET} guarda el estado de la auditoría como referencia" "baseline"
    menu_row "${C_BOLD}./watch4me.sh monitor${C_RESET} ${C_DIM}${sep}${C_RESET} compara la auditoría actual con la baseline" "monitor"
    menu_row "${C_BOLD}./watch4me.sh audit --sudo${C_RESET} ${C_DIM}${sep}${C_RESET} más lecturas con sudo -n, sin contraseña" "sudo"
    menu_row "${C_BOLD}./watch4me.sh audit --save${C_RESET} ${C_DIM}${sep}${C_RESET} guarda .md y .json en reports/" "save"
    menu_row "${C_BOLD}./watch4me.sh audit --save - > informe.md${C_RESET} ${C_DIM}${sep}${C_RESET} Markdown limpio por stdout" "save-stdout"
    menu_row "${C_BOLD}./watch4me.sh audit --save /ruta/informe.md${C_RESET} ${C_DIM}${sep}${C_RESET} ruta concreta para el informe" "save-path"
    menu_row "${C_BOLD}./watch4me.sh explain NET-01${C_RESET} ${C_DIM}${sep}${C_RESET} ficha, descripción, perfiles y remedio" "explain"
    menu_row "${C_BOLD}./watch4me.sh explain --list${C_RESET} ${C_DIM}${sep}${C_RESET} catálogo agrupado por dominio y perfil" "list"
    menu_row "${C_BOLD}./watch4me.sh --help${C_RESET} ${C_DIM}${sep}${C_RESET} ayuda completa de la CLI" "cli"
    menu_row "${C_BOLD}./watch4me.sh menu${C_RESET} ${C_DIM}${sep}${C_RESET} abre este menú de forma explícita" "menu"
    menu_row "${C_BOLD}./watch4me.sh audit --profile cliente --sudo --save${C_RESET} ${C_DIM}${sep}${C_RESET} combinar opciones" "combo"
    menu_row "${C_BOLD}Códigos de salida${C_RESET} ${C_DIM}${sep}${C_RESET} 0 limpio ${sep} 1 avisos ${sep} 2 crítico ${sep} 64 uso" "exit"
    menu_row "${C_BOLD}WATCH4ME_ALLOW_PORTS=\"22 443\"${C_RESET} ${C_DIM}${sep}${C_RESET} puertos esperados en NET-01" "env"
}

menu_help() {
    local key rc
    while :; do
        menu_header "Ayuda y atajos · comandos y guía" \
            'Elige una entrada; el panel derecho la explica antes de abrirla.'
        key=$(menu_pick_row menu_rows_help 'ayuda' \
            'ENTER detalle | ESC vuelve al menú principal | escribe para buscar | panel derecho: explicación' \
            help)
        rc=$?
        [ "$rc" -ne 0 ] && return 0
        menu_clear
        WATCH4ME_PREVIEW_COLOR=${UI_COLOR:-0}
        menu_pv_init
        menu_pv_help "$key"
        menu_pause
    done
}

# ---------------------------------------------------------------------------
# Vista previa (se invoca como `watch4me.sh __preview <tipo> <arg>`)
# ---------------------------------------------------------------------------

menu_pv_init() {
    if [ "${WATCH4ME_PREVIEW_COLOR:-0}" = '1' ]; then
        PV_B=$'\e[1m'
        PV_C=$'\e[96m'
        PV_D=$'\e[90m'
        PV_Y=$'\e[93m'
        PV_G=$'\e[92m'
        PV_R=$'\e[0m'
    else
        PV_B='' PV_C='' PV_D='' PV_Y='' PV_G='' PV_R=''
    fi
}

menu_pv_title() {
    local rule='----------------------------------------'
    [ "${UI_UTF8:-0}" -eq 1 ] && rule='────────────────────────────────────────'
    printf '\n%s%s%s\n' "$PV_B$PV_C" "$1" "$PV_R"
    printf '%s%s%s\n' "$PV_D" "$rule" "$PV_R"
}

menu_pv_label() {
    printf '\n%s%s%s\n' "$PV_Y$PV_B" "$1" "$PV_R"
}

menu_pv_text() {
    printf '%s\n' "$*"
}

menu_pv_cmd() {
    printf '\n%s%s%s\n' "$PV_G" "$1" "$PV_R"
}

menu_pv_profile() {
    local profile=$1 use_sudo=${2:-0}
    local n total id list desc
    if ! profile_valid "$profile"; then
        menu_pv_text "Perfil desconocido: $profile"
        return 0
    fi
    n=$(profile_count "$profile")
    total=${#CHECK_IDS[@]}
    desc=$(profile_desc "$profile")

    menu_pv_title "PERFIL $(profile_label "$profile")"
    menu_pv_text "$desc"
    menu_pv_label 'ALCANCE'
    menu_pv_text "$n de $total checks del catálogo."

    if [ "$profile" = 'general' ]; then
        menu_pv_text 'Incluye todo el catálogo, sin exclusiones.'
    elif [ "$profile" = 'servidor' ] || [ "$profile" = 'cliente' ]; then
        list=''
        for id in "${CHECK_IDS[@]}"; do
            profile_applies "$profile" "$id" || list+="${list:+ }$id"
        done
        menu_pv_label 'CHECKS OMITIDOS'
        menu_pv_text "$list"
    else
        list=$(profile_included_text "$profile")
        menu_pv_label 'CHECKS INCLUIDOS'
        menu_pv_text "$list"
    fi

    menu_pv_label 'CUÁNDO USARLO'
    case "$profile" in
        general)   menu_pv_text 'Para una revisión completa del equipo: es la opción recomendada.' ;;
        servidor)  menu_pv_text 'En un servidor o VPS: exposición, SSH, servicios, integridad y persistencia.' ;;
        cliente)   menu_pv_text 'En un portátil o escritorio: actualizaciones, cuentas, firewall, malware, Wi-Fi, cifrado y bloqueo.' ;;
        domestico) menu_pv_text 'En el PC de casa: lo importante sin la auditoría avanzada de servidor.' ;;
        esencial)  menu_pv_text 'Para una primera mirada rápida: 14 checks baratos y de alto valor.' ;;
    esac
    menu_pv_label 'SUDO'
    if [ "$use_sudo" -eq 1 ]; then
        menu_pv_text 'Activado: esta ejecución usará sudo -n para leer archivos protegidos.'
    else
        menu_pv_text 'Desactivado. Puedes activarlo con la fila «Lecturas con sudo».'
    fi
    menu_pv_label 'GUARDAR'
    menu_pv_text 'Al terminar te preguntará si guardar el informe .md y el .json.'
    menu_pv_label 'EFECTOS'
    menu_pv_text 'Solo lectura: no modifica el sistema.'
    menu_pv_label 'EQUIVALENTE EN CLI'
    if [ "$profile" = 'general' ]; then
        menu_pv_cmd "./watch4me.sh audit$([ "$use_sudo" -eq 1 ] && printf ' --sudo')"
    else
        menu_pv_cmd "./watch4me.sh audit --profile $profile$([ "$use_sudo" -eq 1 ] && printf ' --sudo')"
    fi
    menu_pv_label 'TIEMPO'
    case "$profile" in
        general)  menu_pv_text 'Normalmente entre 10 y 30 s, según el equipo.' ;;
        esencial) menu_pv_text 'Normalmente menos de 10 s.' ;;
        *)        menu_pv_text 'Normalmente menos que la general; depende del equipo.' ;;
    esac
}

menu_pv_action() {
    local id=$1
    case "$id" in
        audit-profiles)
            menu_pv_title 'AUDITORÍAS DE SEGURIDAD'
            menu_pv_text 'Abre los cinco perfiles de auditoría en un submenú.'
            menu_pv_label 'QUÉ CAMBIA CADA PERFIL'
            menu_pv_text 'No cambia la profundidad: cambia qué checks se ejecutan.'
            menu_pv_text 'Así ves lo importante de cada tipo de equipo sin repetir siempre la auditoría completa.'
            menu_pv_label 'RECOMENDACIÓN'
            menu_pv_text 'Empieza por General: es la referencia y cubre todo el catálogo.'
            menu_pv_text 'Después usa Servidor, Cliente o PC doméstico según el equipo; Esencial es un vistazo rápido.'
            menu_pv_label 'QUÉ VERÁS'
            menu_pv_text 'Cada fila del submenú muestra checks, enfoque y tiempo estimado en el panel derecho.'
            menu_pv_label 'CÓMO NAVEGAR'
            menu_pv_text 'ENTER abre el submenú. ESC vuelve al menú principal y no ejecuta nada.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura: no modifica el sistema. Al terminar ofrece guardar .md y .json.'
            ;;
        history)
            menu_pv_title 'HISTORIAL Y CAMBIOS'
            menu_pv_text 'Reúne la baseline, el monitor de cambios y los informes guardados.'
            menu_pv_label 'QUÉ ENCONTRARÁS'
            menu_pv_text 'Crear baseline: guarda una foto de la auditoría como referencia.'
            menu_pv_text 'Ver baseline: consulta la foto guardada sin ejecutar checks.'
            menu_pv_text 'Monitorizar: repite el perfil guardado y compara estado y score.'
            menu_pv_text 'Informes: abre los .md y .json que ya están en reports/.'
            menu_pv_label 'PARA QUÉ SIRVE'
            menu_pv_text 'Sirve para responder «¿qué ha cambiado desde la última vez?» sin revisar todo a mano.'
            menu_pv_label 'IMPORTANTE'
            menu_pv_text 'La baseline es por host y guarda solo auditoría: no puertos, servicios, ficheros ni procesos.'
            menu_pv_text 'No instala timer ni envía notificaciones; monitor se ejecuta cuando tú quieras.'
            menu_pv_label 'CÓMO NAVEGAR'
            menu_pv_text 'ENTER abre el submenú. ESC vuelve al menú principal.'
            ;;
        watch-menu)
            menu_pv_title 'VIGILANCIA'
            menu_pv_text 'Abre watch para revisar puertos, conexiones, servicios, procesos y persistencia.'
            menu_pv_label 'QUÉ ENCONTRARÁS'
            menu_pv_text 'Vigilancia en vivo: compara capturas cada 3 s y avisa de cambios.'
            menu_pv_text 'Una sola captura: revisa una instantánea, muestra el resultado y sale.'
            menu_pv_label 'DIFERENCIA CON UNA AUDITORÍA'
            menu_pv_text 'La auditoría revisa configuración y estado; watch vigila lo que ocurre ahora.'
            menu_pv_text 'No es un antivirus: no bloquea, no mata procesos y no modifica el sistema.'
            menu_pv_label 'REQUISITOS'
            menu_pv_text 'ss (iproute2). La pantalla en vivo necesita TTY y color; sin ellos hace una captura única.'
            menu_pv_label 'SALIR'
            menu_pv_text 'En vivo se detiene con Ctrl-C y vuelve a este menú. La captura única sale sola.'
            ;;
        catalog-menu)
            menu_pv_title 'CATÁLOGO Y FICHAS'
            menu_pv_text 'Consulta qué comprueba cada check, su severidad, sus perfiles y su remedio.'
            menu_pv_label 'QUÉ ENCONTRARÁS'
            menu_pv_text 'Buscar una ficha: filtra por ID, título o dominio y abre el detalle.'
            menu_pv_text 'Explorar por dominio: Sistema, Usuarios, Red, Servicios, Ficheros, Autenticación, Integridad y Malware.'
            menu_pv_text "Catálogo completo: los ${#CHECK_IDS[@]} checks en un buscador fzf, agrupados por dominio."
            menu_pv_label 'CÓMO FUNCIONA'
            menu_pv_text 'El panel derecho enseña la ficha resumida; ENTER abre descripción y remedio.'
            menu_pv_text 'El catálogo completo no usa less: ESC o Ctrl-C vuelven al catálogo, sin bloquear la sesión.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. El comando CLI equivalente es ./watch4me.sh explain --list.'
            ;;
        catalog-domains)
            menu_pv_title 'EXPLORAR POR DOMINIO'
            menu_pv_text 'Agrupa el catálogo en los ocho dominios de seguridad de watch4me.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'Elige un dominio; después selecciona un check para ver su ficha completa.'
            menu_pv_text 'Al cerrar la ficha vuelve a la lista del dominio para seguir consultando.'
            menu_pv_text 'El panel derecho resume la cobertura de cada dominio antes de entrar.'
            menu_pv_label 'ATAJOS'
            menu_pv_text 'ENTER entra en el dominio. ESC vuelve al catálogo. Dentro de un dominio, ESC vuelve aquí.'
            ;;
        catalog-all)
            menu_pv_title 'CATÁLOGO COMPLETO'
            menu_pv_text "Muestra los ${#CHECK_IDS[@]} checks y una fila Volver en un buscador fzf, agrupados por dominio."
            menu_pv_label 'CÓMO'
            menu_pv_text 'Escribe un ID (NET-01), un título o un dominio para filtrar.'
            menu_pv_text 'Mueve la selección para ver la ficha en el panel derecho; ENTER la abre completa.'
            menu_pv_text 'Al cerrar la ficha con ENTER vuelve al buscador para elegir otro check.'
            menu_pv_label 'SALIR SIN BLOQUEOS'
            menu_pv_text 'ESC o Ctrl-C vuelven al catálogo. Desde el menú principal, Ctrl-C sale.'
            menu_pv_text 'No se abre ningún paginador externo que pueda atrapar la sesión.'
            menu_pv_label 'VERSIÓN CLI'
            menu_pv_cmd './watch4me.sh explain --list'
            ;;
        back)
            menu_pv_title 'VOLVER'
            menu_pv_text 'Vuelve al menú anterior sin ejecutar ninguna acción.'
            menu_pv_label 'ATAJOS'
            menu_pv_text 'ESC también vuelve. En el menú principal, ESC o «Salir» cierran watch4me.'
            ;;
        audit-general|audit-full)
            menu_pv_profile general "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        audit-servidor)
            menu_pv_profile servidor "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        audit-cliente)
            menu_pv_profile cliente "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        audit-domestico)
            menu_pv_profile domestico "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        audit-esencial|audit-quick)
            menu_pv_profile esencial "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        audit-sudo)
            menu_pv_profile general 1
            ;;
        audit-quick-sudo)
            menu_pv_profile esencial 1
            ;;
        audit-save)
            menu_pv_profile general "${WATCH4ME_PREVIEW_SUDO:-0}"
            ;;
        baseline)
            menu_pv_title 'CREAR BASELINE'
            menu_pv_text 'Ejecuta una auditoría y guarda su estado como referencia para comparar después.'
            menu_pv_label 'QUÉ GUARDA'
            menu_pv_text 'Estado y detalle de cada check, severidad, score y metadatos del equipo.'
            menu_pv_text 'Solo auditoría: no guarda puertos, servicios, ficheros ni procesos.'
            menu_pv_label 'PERFIL'
            menu_pv_text 'Por defecto usa general. Para guardar otro perfil:'
            menu_pv_cmd './watch4me.sh baseline --profile esencial'
            menu_pv_label 'SI YA EXISTE'
            menu_pv_text 'Pide confirmación en el menú. En scripts, usa --force para sobrescribir.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Escribe únicamente en state/baseline/<host>/. No modifica el sistema.'
            menu_pv_label 'SIN TIMER'
            menu_pv_text 'No instala timer ni envía notificaciones: monitor se ejecuta a mano.'
            ;;
        baseline-show)
            menu_pv_title 'VER BASELINE GUARDADA'
            menu_pv_text 'Muestra la baseline del host sin ejecutar la auditoría.'
            menu_pv_label 'QUÉ ENSEÑA'
            menu_pv_text 'Ruta, fecha, perfil, score, contadores y los fallos que quedaron guardados.'
            menu_pv_text 'Es útil para recordar la referencia antes de lanzar monitor.'
            menu_pv_label 'SI NO EXISTE'
            menu_pv_text 'Avisa de que no hay baseline y vuelve al submenú para crearla.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. No ejecuta checks ni modifica la baseline.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh baseline --show'
            ;;
        monitor)
            menu_pv_title 'MONITORIZAR CAMBIOS'
            menu_pv_text 'Repite la auditoría del perfil guardado y la compara con la baseline.'
            menu_pv_label 'QUÉ COMPARA'
            menu_pv_text 'Estado de cada check y score. Muestra mejoras, regresiones,'
            menu_pv_text 'checks que dejan de evaluarse y cambios de catálogo.'
            menu_pv_label 'CÓDIGOS'
            menu_pv_text '0 sin regresiones · 1 regresión o pérdida de cobertura · 2 fallo crítico nuevo.'
            menu_pv_text '64 si no hay baseline o el perfil no coincide.'
            menu_pv_label 'SUDO'
            menu_pv_text 'Si la baseline se creó con sudo, monitor intenta reutilizarlo con sudo -n.'
            menu_pv_label 'SIN TIMER'
            menu_pv_text 'Es una sola ejecución. No instala timer ni envía notificaciones.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh monitor'
            ;;
        toggle-sudo)
            menu_pv_title 'LECTURAS CON SUDO'
            menu_pv_text 'Activa o desactiva sudo -n para auditorías, baseline, monitor y watch.'
            menu_pv_label 'CÓMO FUNCIONA'
            menu_pv_text 'Nunca pide contraseña: si no hay caché de sudo, los checks protegidos salen omitidos.'
            menu_pv_text 'Actívala antes en la terminal con: sudo -v'
            menu_pv_label 'QUÉ AÑADE'
            menu_pv_text 'Más datos reales: sudoers, SSH, firewall, paquetes, procesos y ficheros protegidos.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. La caché de sudo la gestiona el sistema.'
            menu_pv_label 'ATAJO'
            menu_pv_cmd 'sudo -v && ./watch4me.sh audit --sudo'
            ;;
        watch)
            menu_pv_title 'VIGILANCIA EN VIVO'
            menu_pv_text 'Monitoriza puertos, conexiones, servicios, procesos y ficheros críticos.'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Compara capturas cada 3 s y avisa de puertos nuevos, servicios que cambian,'
            menu_pv_text 'ficheros críticos modificados y procesos sospechosos.'
            menu_pv_text 'Marca puertos de riesgo, binarios borrados o en rutas temporales, mineros,'
            menu_pv_text 'shells inversas, servicios failed y contenido en ld.so.preload.'
            menu_pv_text 'Distingue puertos locales, virtuales (puentes) y expuestos; solo los'
            menu_pv_text 'expuestos pueden generar aviso por puerto de alto riesgo.'
            menu_pv_label 'QUÉ NO HACE'
            menu_pv_text 'No es un antivirus: no bloquea, no mata procesos y no modifica el sistema.'
            menu_pv_label 'REQUISITOS'
            menu_pv_text 'ss (iproute2). La pantalla en vivo necesita TTY y color; sin ellos hace una captura.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh watch'
            menu_pv_cmd './watch4me.sh watch --once'
            menu_pv_label 'SALIR'
            menu_pv_text 'Ctrl-C detiene la vigilancia y vuelve al menú.'
            ;;
        watch-once)
            menu_pv_title 'VIGILANCIA: UNA CAPTURA'
            menu_pv_text 'Toma una instantánea de puertos, conexiones, servicios, procesos y persistencia.'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Analiza el estado actual, muestra los hallazgos y sale sin quedarse vigilando.'
            menu_pv_text 'Es la opción práctica para cron, scripts o una revisión puntual.'
            menu_pv_label 'CÓDIGOS'
            menu_pv_text '0 sin hallazgos · 1 avisos · 2 hallazgos críticos · 64 si falta ss.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura: no bloquea procesos, no modifica ficheros y no guarda informes.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh watch --once'
            ;;
        explain-pick)
            menu_pv_title 'EXPLICAR UN CHECK'
            menu_pv_text 'Abre un buscador con los checks registrados.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'Escribe un ID (NET-01), un título o un dominio (SSH, red,'
            menu_pv_text 'contraseñas...). El panel derecho muestra la ficha y los perfiles.'
            menu_pv_text 'ENTER abre la descripción completa y el remedio sugerido.'
            menu_pv_text 'Al cerrar la ficha con ENTER vuelve al buscador para elegir otro check.'
            menu_pv_label 'SALIR'
            menu_pv_text 'ESC vuelve al catálogo. La fila «Volver» hace lo mismo.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain NET-01'
            ;;
        explain-list)
            menu_pv_title 'CATÁLOGO DE CHECKS'
            menu_pv_text 'Muestra todos los checks agrupados por dominio, con su ID,'
            menu_pv_text 'severidad, perfiles que lo incluyen y título.'
            menu_pv_label 'EN EL MENÚ'
            menu_pv_text 'Se abre en un buscador fzf: escribe para filtrar y ENTER para ver la ficha.'
            menu_pv_text 'ESC vuelve al catálogo. No usa un paginador externo, así que no bloquea la sesión.'
            menu_pv_label 'PERFILES'
            menu_pv_text 'S servidor · C cliente · D doméstico · E esencial · - solo general'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain --list'
            ;;
        reports)
            menu_pv_title 'INFORMES GUARDADOS'
            menu_pv_text 'Lista los .md y .json de reports/ del más reciente al más antiguo.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'El panel derecho muestra una vista previa del Markdown o del JSON.'
            menu_pv_text 'ENTER lo abre en el paginador; dentro, q vuelve al menú.'
            menu_pv_text 'El paginador indica los atajos en su línea inferior.'
            menu_pv_label 'SI ESTÁ VACÍO'
            menu_pv_text 'Ejecuta una auditoría y responde «s» cuando ofrezca guardar.'
            ;;
        help)
            menu_pv_title 'AYUDA Y ATAJOS'
            menu_pv_text 'Reúne los comandos directos de watch4me con ejemplos listos'
            menu_pv_text 'para copiar: perfiles, baseline, watch, sudo, informes y explain.'
            menu_pv_label 'INCLUYE'
            menu_pv_text '--profile, baseline, monitor, watch, --once, --interval, --save,'
            menu_pv_text '--save -, --sudo, explain, códigos de salida y variables de entorno.'
            menu_pv_label 'TAMBIÉN EXPLICA'
            menu_pv_text 'Cómo está organizado el menú, cómo navegar por grupos y qué límites tiene watch4me.'
            menu_pv_label 'ATAJOS'
            menu_pv_text 'Dentro del menú: escribe para filtrar, ENTER para ejecutar,'
            menu_pv_text 'ESC para volver un nivel y Ctrl-C para cancelar la pantalla actual.'
            menu_pv_text 'Desde el menú principal, ESC o Ctrl-C salen del programa.'
            ;;
        quit)
            menu_pv_title 'SALIR'
            menu_pv_text 'Cierra el menú y vuelve a la shell sin ejecutar ninguna acción.'
            menu_pv_label 'ATAJOS'
            menu_pv_text 'ESC o Ctrl-C también salen del menú.'
            ;;
        *)
            menu_pv_text 'Acción desconocida.'
            ;;
    esac
}

menu_pv_check() {
    local id=$1 sev dom
    if [ "$id" = 'back' ]; then
        menu_pv_title 'VOLVER'
        menu_pv_text 'Vuelve al menú anterior sin abrir ninguna ficha.'
        return 0
    fi
    if [ -z "${CHECK_TITLE[$id]:-}" ]; then
        menu_pv_text "Check desconocido: $id"
        return 0
    fi
    sev=${CHECK_SEVERITY[$id]}
    dom=$(domain_of "$id")
    menu_pv_title "$id  ${CHECK_TITLE[$id]}"
    printf '%sSeveridad:%s %s   %sDominio:%s %s\n' \
        "$PV_D" "$PV_R" "$(sev_label "$sev")" \
        "$PV_D" "$PV_R" "${DOMAIN_NAME[$dom]:-$dom}"
    printf '%sPerfiles:%s %s\n' \
        "$PV_D" "$PV_R" "$(profile_names "$id")"
    if [ -n "${CHECK_DESC[$id]:-}" ]; then
        menu_pv_label 'QUÉ COMPRUEBA'
        printf '%s\n' "${CHECK_DESC[$id]}"
    fi
    if [ -n "${CHECK_REMED[$id]:-}" ]; then
        menu_pv_label 'REMEDIO SUGERIDO'
        printf '%s\n' "${CHECK_REMED[$id]}"
    fi
    menu_pv_label 'FICHA COMPLETA'
    menu_pv_cmd "./watch4me.sh explain $id"
}

menu_pv_domain() {
    local dom=$1 id n=0
    menu_pv_title "DOMINIO ${DOMAIN_NAME[$dom]:-$dom} ($dom)"
    menu_pv_text "$(menu_domain_desc "$dom")"
    for id in "${CHECK_IDS[@]}"; do
        [ "$(domain_of "$id")" = "$dom" ] && n=$(( n + 1 ))
    done
    menu_pv_label 'ALCANCE'
    menu_pv_text "$n checks de los ${#CHECK_IDS[@]} del catálogo."
    menu_pv_label 'CHECKS'
    for id in "${CHECK_IDS[@]}"; do
        [ "$(domain_of "$id")" = "$dom" ] || continue
        printf '  %s%-7s%s %s\n' "$PV_B" "$id" "$PV_R" "${CHECK_TITLE[$id]}"
    done
    menu_pv_label 'CÓMO SEGUIR'
    menu_pv_text 'ENTER abre este dominio en el buscador de checks.'
    menu_pv_text 'Después elige un ID para ver descripción, perfiles y remedio.'
    menu_pv_label 'SALIR'
    menu_pv_text 'ESC vuelve al catálogo por dominios.'
}

menu_pv_report() {
    local f=$1
    if [ ! -r "$f" ]; then
        menu_pv_text "No se puede leer el informe: $f"
        return 0
    fi
    case "$f" in
        *.json) menu_pv_title 'INFORME JSON' ;;
        *)      menu_pv_title 'INFORME MARKDOWN' ;;
    esac
    printf '%s%s%s\n\n' "$PV_D" "$f" "$PV_R"
    sed -n '1,400p' -- "$f"
}

menu_pv_help() {
    local key=$1
    case "$key" in
        basic)
            menu_pv_title 'MENÚ O AUDITORÍA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Con terminal interactiva abre este menú.'
            menu_pv_text 'Sin terminal (cron, pipe, script) ejecuta la auditoría completa.'
            menu_pv_label 'FORZAR'
            menu_pv_cmd './watch4me.sh menu      # menú'
            menu_pv_cmd './watch4me.sh audit     # auditoría'
            ;;
        menu-map)
            menu_pv_title 'CÓMO FUNCIONA EL MENÚ'
            menu_pv_text 'El menú principal agrupa las acciones para no llenar la pantalla.'
            menu_pv_label 'GRUPOS'
            menu_pv_text 'Auditorías: cinco perfiles de revisión.'
            menu_pv_text 'Historial y cambios: baseline, monitor e informes.'
            menu_pv_text 'Vigilancia: watch en vivo o una sola captura.'
            menu_pv_text "Catálogo y fichas: buscar, explorar por dominio o ver los ${#CHECK_IDS[@]}."
            menu_pv_text 'Lecturas con sudo: activa o desactiva sudo -n.'
            menu_pv_text 'Ayuda y atajos: comandos, códigos y esta guía.'
            menu_pv_label 'NAVEGACIÓN'
            menu_pv_text 'ENTER abre un grupo o ejecuta la fila seleccionada.'
            menu_pv_text 'ESC vuelve un nivel; en el menú principal sale.'
            menu_pv_text 'Ctrl-C cancela la pantalla actual; desde el menú principal sale del programa.'
            menu_pv_text 'Escribe para filtrar y usa el panel derecho para leer la explicación.'
            menu_pv_label 'SIN FZF'
            menu_pv_text 'El menú necesita fzf. Sin fzf, la auditoría directa sigue disponible.'
            ;;
        safety)
            menu_pv_title 'SOLO LECTURA Y LÍMITES'
            menu_pv_text 'watch4me audita y muestra remedios; no aplica cambios por ti.'
            menu_pv_label 'QUÉ NO MODIFICA'
            menu_pv_text 'No cambia configuración, permisos, servicios, firewall ni paquetes.'
            menu_pv_text 'No bloquea procesos ni elimina ficheros. Los remedios son texto orientativo.'
            menu_pv_label 'ESCRITURAS PERMITIDAS'
            menu_pv_text 'Auditorías guardadas en reports/, estado temporal en state/tmp/ y baseline en state/baseline/.'
            menu_pv_text '--save <ruta> es la única excepción explícita del usuario.'
            menu_pv_label 'SUDO'
            menu_pv_text 'Solo usa sudo -n para lecturas y nunca pide contraseña.'
            menu_pv_text 'Sin caché de sudo, los checks protegidos salen omitidos (SKIP).'
            menu_pv_label 'ÚNICA EXCEPCIÓN DE INSTALACIÓN'
            menu_pv_text 'El menú puede instalar fzf con el gestor de la distribución, solo tras confirmación [s/N].'
            menu_pv_text 'WATCH4ME_NO_INSTALL=1 lo impide.'
            menu_pv_label 'WATCH'
            menu_pv_text 'Tampoco bloquea ni modifica: observa puertos, conexiones, servicios y persistencia.'
            ;;
        audit)
            menu_pv_title 'AUDITORÍA DIRECTA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text "Ejecuta los ${#CHECK_IDS[@]} checks del perfil general sin pasar por el menú."
            menu_pv_text 'Al terminar ofrece guardar el informe .md y .json.'
            ;;
        profiles)
            menu_pv_title 'PERFILES DE AUDITORÍA'
            menu_pv_text 'Cambian qué checks se ejecutan, no su profundidad.'
            menu_pv_label 'COMANDOS'
            menu_pv_cmd './watch4me.sh audit --profile general'
            menu_pv_cmd './watch4me.sh audit --profile servidor'
            menu_pv_cmd './watch4me.sh audit --profile cliente'
            menu_pv_cmd './watch4me.sh audit --profile domestico'
            menu_pv_cmd './watch4me.sh audit --profile esencial'
            menu_pv_label 'RESUMEN'
            menu_pv_text "general $(profile_count general) · servidor $(profile_count servidor) · cliente $(profile_count cliente) · doméstico $(profile_count domestico) · esencial $(profile_count esencial) checks"
            menu_pv_text 'Alias compatibles: full = general · quick = esencial.'
            menu_pv_label 'CONSEJO'
            menu_pv_text 'Usa el perfil que describa el equipo; la general sigue siendo la referencia.'
            ;;
        watch)
            menu_pv_title 'VIGILANCIA EN VIVO'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh watch'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Captura sockets, conexiones, servicios, procesos y ficheros críticos.'
            menu_pv_text 'Compara cada 3 s y avisa de puertos nuevos, servicios que cambian,'
            menu_pv_text 'ficheros modificados, mineros, shells inversas y rutas temporales.'
            menu_pv_label 'QUÉ NO HACE'
            menu_pv_text 'No es un antivirus: no bloquea, no mata procesos ni modifica el sistema.'
            menu_pv_label 'REQUISITOS'
            menu_pv_text 'ss (iproute2) y TTY con color para la pantalla en vivo.'
            menu_pv_label 'SALIR'
            menu_pv_text 'Ctrl-C detiene la vigilancia.'
            ;;
        watch-once)
            menu_pv_title 'VIGILANCIA: UNA CAPTURA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh watch --once'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Toma una única instantánea y sale sin abrir la pantalla en vivo.'
            menu_pv_text 'Ideal para cron, scripts o para revisar sin quedarse vigilando.'
            menu_pv_label 'CÓDIGOS'
            menu_pv_text '0 sin hallazgos · 1 avisos · 2 hallazgos críticos · 64 falta ss'
            menu_pv_label 'INTERVALO'
            menu_pv_cmd './watch4me.sh watch --interval 5'
            menu_pv_text 'Cambia los segundos entre capturas en el modo en vivo.'
            ;;
        baseline)
            menu_pv_title 'BASELINE DE AUDITORÍA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh baseline'
            menu_pv_cmd './watch4me.sh baseline --profile esencial'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Ejecuta una auditoría y guarda estados, detalle, severidad, score y metadatos.'
            menu_pv_text 'No guarda puertos, servicios, ficheros ni procesos: eso es watch.'
            menu_pv_label 'DÓNDE'
            menu_pv_text 'state/baseline/<host>/baseline.tsv y baseline.meta.'
            menu_pv_label 'SI YA EXISTE'
            menu_pv_text 'Pide confirmación o exige --force en scripts.'
            menu_pv_label 'SIN TIMER'
            menu_pv_text 'No instala timer ni notificaciones; la comparación es manual.'
            ;;
        monitor)
            menu_pv_title 'MONITOR DE CAMBIOS'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh monitor'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Repite la auditoría del perfil guardado y compara check por check.'
            menu_pv_text 'Muestra mejoras, regresiones, omitidos, nuevos y cambios de score.'
            menu_pv_label 'CÓDIGOS'
            menu_pv_text '0 sin regresiones · 1 regresión o pérdida de cobertura · 2 crítico nuevo · 64 sin baseline.'
            menu_pv_label 'SIN TIMER'
            menu_pv_text 'Una sola ejecución. No instala timer ni envía notificaciones.'
            ;;
        sudo)
            menu_pv_title 'LECTURAS CON SUDO'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --sudo'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Usa «sudo -n» para lecturas que requieren root.'
            menu_pv_text 'Nunca pide contraseña: sin caché de sudo, el check sale SKIP.'
            menu_pv_text 'También se aplica a la vigilancia: ./watch4me.sh watch --sudo'
            menu_pv_label 'CONSEJO'
            menu_pv_cmd 'sudo -v && ./watch4me.sh audit --sudo'
            ;;
        save)
            menu_pv_title 'GUARDAR EN REPORTS/'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --save'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Ejecuta la auditoría y escribe el .md y el .json en reports/.'
            ;;
        save-stdout)
            menu_pv_title 'MARKDOWN POR STDOUT'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --save - > informe.md'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Escribe solo el Markdown por stdout: sin cabecera ni progreso.'
            menu_pv_text 'Perfecto para cron, tuberías o procesar el informe.'
            ;;
        save-path)
            menu_pv_title 'RUTA PERSONALIZADA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --save /ruta/informe.md'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Guarda .md y .json en la ruta indicada (con o sin extensión).'
            menu_pv_text 'Si es un directorio, genera el nombre con host y fecha.'
            ;;
        explain)
            menu_pv_title 'FICHA DE UN CHECK'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh explain NET-01'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Muestra descripción, severidad y remedio sugerido.'
            menu_pv_label 'VARIOS A LA VEZ'
            menu_pv_cmd './watch4me.sh explain NET-01 SVC-07'
            ;;
        list)
            menu_pv_title 'CATÁLOGO COMPLETO'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh explain --list'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text "Lista los ${#CHECK_IDS[@]} checks agrupados por dominio, con severidad y perfiles."
            menu_pv_label 'EN EL MENÚ'
            menu_pv_text 'El catálogo se abre en un buscador fzf: ESC o Ctrl-C vuelven sin bloquearse.'
            ;;
        cli)
            menu_pv_title 'AYUDA Y VERSIÓN'
            menu_pv_label 'COMANDOS'
            menu_pv_cmd './watch4me.sh --help'
            menu_pv_cmd './watch4me.sh --version'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Muestra la ayuda completa de la CLI o la versión instalada.'
            ;;
        menu)
            menu_pv_title 'FORZAR EL MENÚ'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh menu'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Abre este menú aunque se invoque desde un entorno sin TTY.'
            menu_pv_text '(Si no hay TTY, el menú avisa y sale con código 64.)'
            ;;
        combo)
            menu_pv_title 'COMBINAR OPCIONES'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --profile cliente --sudo --save'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Perfil cliente, lecturas privilegiadas y guardado automático.'
            menu_pv_text 'El orden de las opciones no importa.'
            ;;
        exit)
            menu_pv_title 'CÓDIGOS DE SALIDA'
            menu_pv_text '0   sin hallazgos / monitor sin regresiones'
            menu_pv_text '1   avisos o fallos no críticos / monitor con regresión'
            menu_pv_text '2   fallo crítico / monitor con fallo crítico nuevo'
            menu_pv_text '64  uso incorrecto, sin baseline, perfil distinto o falta ss'
            menu_pv_label 'EJEMPLO EN SCRIPT'
            menu_pv_cmd './watch4me.sh audit --save - > informe.md || rc=$?'
            menu_pv_text 'rc guarda el código para decidir si hay que alertar.'
            ;;
        env)
            menu_pv_title 'PUERTOS ESPERADOS'
            menu_pv_label 'COMANDO'
            menu_pv_cmd 'WATCH4ME_ALLOW_PORTS="22 443 8080" ./watch4me.sh audit'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'NET-01 considera esperados esos puertos además del 22.'
            menu_pv_text 'Los puertos de alto riesgo siguen marcando FAIL.'
            ;;
        *)
            menu_pv_text 'Entrada de ayuda desconocida.'
            ;;
    esac
}

menu_preview() {
    local kind=$1 arg=$2
    UI_UTF8=${UI_UTF8:-0}
    menu_pv_init
    case "$kind" in
        action) menu_pv_action "$arg" ;;
        check)  menu_pv_check "$arg" ;;
        domain) menu_pv_domain "${arg#domain-}" ;;
        report) menu_pv_report "$arg" ;;
        help)   menu_pv_help "$arg" ;;
        *)      menu_pv_text 'Vista previa no disponible.' ;;
    esac
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------

menu_main() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf 'watch4me: el menú requiere una terminal interactiva\n' >&2
        printf 'watch4me: usa ./watch4me.sh audit para ejecutar la auditoría\n' >&2
        return 64
    fi

    menu_ensure_fzf || return 64

    # Traps propios del menú: paran el logo y muestran el mensaje de salida.
    trap 'menu_logo_stop; menu_exit_msg; ui_restore; exit 130' INT
    trap 'menu_logo_stop; menu_exit_msg; ui_restore; exit 143' TERM
    trap 'menu_logo_stop; menu_exit_msg; ui_restore; exit 129' HUP
    trap 'menu_logo_stop; ui_restore' EXIT

    local sel rc id
    while :; do
        menu_header
        sel=$(menu_rows_main | menu_fzf \
            "$(menu_prompt watch4me)" \
            'ENTER abre el grupo o ejecuta | ESC sale | escribe para filtrar | panel derecho: explicación' \
            action)
        rc=$?
        menu_logo_stop
        [ "$rc" -eq 130 ] && break
        [ -z "$sel" ] && break
        id=${sel##*"$MENU_TAB"}

        case "$id" in
            audit-profiles) menu_audits ;;
            history)        menu_history ;;
            watch-menu)     menu_watch_menu ;;
            catalog-menu)   menu_catalog_menu ;;
            toggle-sudo)    MENU_SUDO=$(( 1 - MENU_SUDO )) ;;
            help)           menu_help ;;
            quit)           break ;;
        esac
    done

    menu_clear
    menu_exit_msg
    return 0
}
