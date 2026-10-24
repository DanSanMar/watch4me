#!/usr/bin/env bash
# watch4me — menú interactivo basado en fzf
#
# El menú es opcional: la auditoría funciona sin fzf. Si falta, se ofrece
# instalarlo con el gestor de la distribución tras confirmación explícita.
# Esa instalación es la única acción del programa que modifica el sistema.
#
# Licencia: GPLv3

MENU_TAB=$'\t'
MENU_LOGO_PID=''
MENU_LOGO_TICKS=${MENU_LOGO_TICKS:-15}   # 15 x 0,2 s = cambio de color cada 3 s
MENU_EXIT_SHOWN=0

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
    local sep
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
    if [ "${UI_WIDTH:-0}" -ge 70 ]; then
        printf ' %sMenú interactivo%s %s %sENTER ejecutar%s %s %sEscribe para filtrar%s %s %sESC salir%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET"
    else
        printf ' %sMenú%s %s %sENTER ejecutar%s %s %sESC salir%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET" "$sep" \
            "$C_DIM" "$C_RESET"
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
    max=$(( lines - 5 ))
    [ "$h" -gt "$max" ] && h=$max
    [ "$h" -lt 6 ] && h=6
    printf '%s' "$h"
}

menu_fzf_opts() {
    local prompt=$1 header=$2 kind=$3
    local self bashq prev ptr mark height

    self=$(printf '%q' "$SCRIPT_DIR/watch4me.sh")
    bashq=$(printf '%q' "${BASH:-bash}")
    prev="WATCH4ME_PREVIEW_COLOR=${UI_COLOR:-0} ${bashq} ${self} __preview ${kind} {2}"
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

menu_rows_main() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '▶' '>')${C_RESET} ${C_BOLD}Auditoría completa${C_RESET} ${C_DIM}${sep}${C_RESET} ${#CHECK_IDS[@]} checks ${sep} escaneos hasta 30 s" "audit-full"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '⚡' '!')${C_RESET} ${C_BOLD}Auditoría rápida${C_RESET} ${C_DIM}${sep}${C_RESET} timeouts reducidos ${sep} revisión en segundos" "audit-quick"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔑' '[s]')${C_RESET} ${C_BOLD}Auditoría con sudo${C_RESET} ${C_DIM}${sep}${C_RESET} más lecturas con sudo -n ${sep} sin pedir contraseña" "audit-sudo"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔐' '[q]')${C_RESET} ${C_BOLD}Auditoría rápida con sudo${C_RESET} ${C_DIM}${sep}${C_RESET} lo mejor de ambos perfiles" "audit-quick-sudo"
    menu_row "${C_BOLD}${C_MAGENTA_B}$(ui_icon '💾' '[w]')${C_RESET} ${C_BOLD}Auditar y guardar informe${C_RESET} ${C_DIM}${sep}${C_RESET} escribe el Markdown en reports/" "audit-save"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔎' '[?]')${C_RESET} ${C_BOLD}Explicar un check${C_RESET} ${C_DIM}${sep}${C_RESET} busca por ID, título o dominio" "explain-pick"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '📚' '[c]')${C_RESET} ${C_BOLD}Catálogo de checks${C_RESET} ${C_DIM}${sep}${C_RESET} los ${#CHECK_IDS[@]} checks agrupados por dominio" "explain-list"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '📄' '[r]')${C_RESET} ${C_BOLD}Informes guardados${C_RESET} ${C_DIM}${sep}${C_RESET} consulta los .md de reports/" "reports"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '❓' '[h]')${C_RESET} ${C_BOLD}Ayuda y atajos${C_RESET} ${C_DIM}${sep}${C_RESET} comandos directos: --save, --profile, explain..." "help"
    menu_row "${C_BOLD}${C_RED_B}$(ui_icon '⏻' '[x]')${C_RESET} ${C_BOLD}Salir${C_RESET} ${C_DIM}${sep}${C_RESET} cerrar el menú sin ejecutar nada" "quit"
}

# ---------------------------------------------------------------------------
# Acciones
# ---------------------------------------------------------------------------

menu_run_audit() {
    local profile=$1 use_sudo=$2 save=$3 anim_save=$UI_ANIM

    PROFILE=$profile
    USE_SUDO=$use_sudo
    SUDO_CHECKED=0
    SUDO_OK=0
    SAVE_TO=$save

    if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
        rm -rf -- "$RUN_DIR"
    fi
    RUN_DIR=''

    menu_clear
    init_run_dir || return 64
    run_checks
    compute_scores
    render_terminal
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

menu_rows_checks() {
    local id sev dom color label
    for id in "${CHECK_IDS[@]}"; do
        sev=${CHECK_SEVERITY[$id]}
        dom=$(domain_of "$id")
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
}

menu_pick_check() {
    local sel rc id
    sel=$(menu_rows_checks | menu_fzf \
        "$(menu_prompt check)" \
        'ENTER: ficha completa | escribe ID, título o dominio | ESC: volver' \
        check)
    rc=$?
    [ "$rc" -eq 130 ] && return 0
    [ -z "$sel" ] && return 0
    id=${sel##*"$MENU_TAB"}
    menu_clear
    explain_check "$id"
    menu_pause
}

menu_show_catalog() {
    menu_clear
    if [ -t 1 ] && have less; then
        explain_list | less -R
    else
        explain_list
        menu_pause
    fi
}

menu_reports() {
    local -a files=()
    local f sel rc path display size stamp sep
    sep=$(menu_sep)

    while IFS= read -r f; do
        [ -f "$f" ] && files+=("$f")
    done < <(printf '%s\n' "$SCRIPT_DIR"/reports/*.md 2>/dev/null | sort -r)

    if [ "${#files[@]}" -eq 0 ]; then
        menu_clear
        printf '%sNo hay informes en reports/%s\n\n' "$C_YELLOW_B" "$C_RESET"
        printf 'Ejecuta "Auditar y guardar informe" o usa:\n'
        printf '  %s./watch4me.sh audit --save%s\n' "$C_BOLD" "$C_RESET"
        menu_pause
        return 0
    fi

    local -a rows=()
    for f in "${files[@]}"; do
        size=$(du -h -- "$f" 2>/dev/null | cut -f1)
        stamp=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '')
        display="${C_BOLD}$(basename -- "$f")${C_RESET} ${C_DIM}${sep}${C_RESET} ${stamp:-sin fecha} ${C_DIM}${sep}${C_RESET} ${size:-?}"
        rows+=("${display}"$'\t'"${f}")
    done

    sel=$(printf '%s\n' "${rows[@]}" | menu_fzf \
        "$(menu_prompt informe)" \
        'ENTER: abrir en el paginador | escribe para filtrar | ESC: volver' \
        report)
    rc=$?
    [ "$rc" -eq 130 ] && return 0
    [ -z "$sel" ] && return 0
    path=${sel##*"$MENU_TAB"}

    menu_clear
    if [ -t 1 ] && have less; then
        less -R -- "$path"
    else
        cat -- "$path"
        menu_pause
    fi
}

# ---------------------------------------------------------------------------
# Ayuda y atajos
# ---------------------------------------------------------------------------

menu_rows_help() {
    local sep
    sep=$(menu_sep)
    menu_row "${C_BOLD}./watch4me.sh${C_RESET} ${C_DIM}${sep}${C_RESET} menú en terminal y auditoría cuando no hay TTY" "basic"
    menu_row "${C_BOLD}./watch4me.sh audit${C_RESET} ${C_DIM}${sep}${C_RESET} fuerza la auditoría completa sin menú" "audit"
    menu_row "${C_BOLD}./watch4me.sh audit --profile quick${C_RESET} ${C_DIM}${sep}${C_RESET} perfil rápido de 5-8 s" "quick"
    menu_row "${C_BOLD}./watch4me.sh audit --sudo${C_RESET} ${C_DIM}${sep}${C_RESET} más lecturas con sudo -n, sin contraseña" "sudo"
    menu_row "${C_BOLD}./watch4me.sh audit --save${C_RESET} ${C_DIM}${sep}${C_RESET} guarda el informe en reports/" "save"
    menu_row "${C_BOLD}./watch4me.sh audit --save - > informe.md${C_RESET} ${C_DIM}${sep}${C_RESET} Markdown limpio por stdout" "save-stdout"
    menu_row "${C_BOLD}./watch4me.sh audit --save /ruta/informe.md${C_RESET} ${C_DIM}${sep}${C_RESET} ruta concreta para el informe" "save-path"
    menu_row "${C_BOLD}./watch4me.sh explain NET-01${C_RESET} ${C_DIM}${sep}${C_RESET} ficha, descripción y remedio de un check" "explain"
    menu_row "${C_BOLD}./watch4me.sh explain --list${C_RESET} ${C_DIM}${sep}${C_RESET} catálogo agrupado por dominio" "list"
    menu_row "${C_BOLD}./watch4me.sh --help${C_RESET} ${C_DIM}${sep}${C_RESET} ayuda completa de la CLI" "cli"
    menu_row "${C_BOLD}./watch4me.sh menu${C_RESET} ${C_DIM}${sep}${C_RESET} abre este menú de forma explícita" "menu"
    menu_row "${C_BOLD}./watch4me.sh audit --profile quick --sudo --save${C_RESET} ${C_DIM}${sep}${C_RESET} combinar opciones" "combo"
    menu_row "${C_BOLD}Códigos de salida${C_RESET} ${C_DIM}${sep}${C_RESET} 0 limpio ${sep} 1 avisos ${sep} 2 crítico ${sep} 64 uso" "exit"
    menu_row "${C_BOLD}WATCH4ME_ALLOW_PORTS=\"22 443\"${C_RESET} ${C_DIM}${sep}${C_RESET} puertos esperados en NET-01" "env"
}

menu_help() {
    local sel rc key
    while :; do
        sel=$(menu_rows_help | menu_fzf \
            "$(menu_prompt ayuda)" \
            'ENTER: ver detalle | escribe para buscar | ESC: volver al menú' \
            help)
        rc=$?
        [ "$rc" -eq 130 ] && return 0
        [ -z "$sel" ] && return 0
        key=${sel##*"$MENU_TAB"}
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

menu_pv_action() {
    local id=$1
    case "$id" in
        audit-full)
            menu_pv_title 'AUDITORÍA COMPLETA'
            menu_pv_text 'Analiza el sistema en los 8 dominios: sistema, usuarios,'
            menu_pv_text 'red, servicios, ficheros, autenticación, integridad y malware.'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text "Ejecuta los ${#CHECK_IDS[@]} checks con el perfil full:"
            menu_pv_text 'escaneos de red de hasta 30 s y verificación de paquetes.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. No modifica el sistema.'
            menu_pv_text 'Al terminar ofrece guardar el informe en reports/.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh audit'
            menu_pv_label 'TIEMPO'
            menu_pv_text 'Normalmente entre 10 y 30 s, según el equipo.'
            ;;
        audit-quick)
            menu_pv_title 'AUDITORÍA RÁPIDA'
            menu_pv_text 'Misma batería de checks con timeouts reducidos (5-8 s).'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Omite INT-02 (integridad de paquetes) y los escaneos que no'
            menu_pv_text 'terminen a tiempo. El resto de dominios se mantiene.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. No modifica el sistema.'
            menu_pv_text 'Ideal para una revisión rápida antes de una auditoría completa.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh audit --profile quick'
            ;;
        audit-sudo|audit-quick-sudo)
            if [ "$id" = 'audit-quick-sudo' ]; then
                menu_pv_title 'AUDITORÍA RÁPIDA CON SUDO'
                menu_pv_text 'Perfil quick con lecturas privilegiadas.'
            else
                menu_pv_title 'AUDITORÍA COMPLETA CON SUDO'
                menu_pv_text 'Perfil full con lecturas privilegiadas.'
            fi
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Permite leer ficheros y ejecutar consultas que requieren root'
            menu_pv_text 'mediante «sudo -n»: sudoers, SSH, nftables, paquetes, etc.'
            menu_pv_label 'IMPORTANTE'
            menu_pv_text 'Nunca pide contraseña. Si la caché de sudo no está activa,'
            menu_pv_text 'los checks que necesitan root salen SKIP (no FAIL).'
            menu_pv_text 'Activa la caché antes con: sudo -v'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. No modifica el sistema.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            if [ "$id" = 'audit-quick-sudo' ]; then
                menu_pv_cmd './watch4me.sh audit --profile quick --sudo'
            else
                menu_pv_cmd './watch4me.sh audit --sudo'
            fi
            ;;
        audit-save)
            menu_pv_title 'AUDITAR Y GUARDAR'
            menu_pv_text 'Ejecuta la auditoría completa y guarda el informe Markdown'
            menu_pv_text 'sin preguntar.'
            menu_pv_label 'DÓNDE'
            menu_pv_text 'reports/watch4me-<host>-AAAAMMDD-HHMM.md'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura del sistema. El único fichero escrito es el informe.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh audit --save'
            ;;
        explain-pick)
            menu_pv_title 'EXPLICAR UN CHECK'
            menu_pv_text 'Abre un buscador con los checks registrados.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'Escribe un ID (NET-01), un título o un dominio (SSH, red,'
            menu_pv_text 'contraseñas...). El panel derecho muestra la ficha.'
            menu_pv_text 'ENTER abre la descripción completa y el remedio sugerido.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain NET-01'
            ;;
        explain-list)
            menu_pv_title 'CATÁLOGO DE CHECKS'
            menu_pv_text 'Muestra todos los checks agrupados por dominio, con su ID,'
            menu_pv_text 'severidad y título.'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. Abre el resultado en el paginador.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain --list'
            ;;
        reports)
            menu_pv_title 'INFORMES GUARDADOS'
            menu_pv_text 'Lista los informes .md de reports/ ordenados por fecha.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'El panel derecho muestra una vista previa del Markdown.'
            menu_pv_text 'ENTER lo abre en less (o en cat si no está disponible).'
            menu_pv_label 'SI ESTÁ VACÍO'
            menu_pv_text 'Ejecuta antes «Auditar y guardar informe».'
            ;;
        help)
            menu_pv_title 'AYUDA Y ATAJOS'
            menu_pv_text 'Reúne los comandos directos de watch4me con ejemplos listos'
            menu_pv_text 'para copiar: perfiles, sudo, informes y explain.'
            menu_pv_label 'INCLUYE'
            menu_pv_text '--save, --save -, --save <ruta>, --profile, --sudo,'
            menu_pv_text 'explain, códigos de salida y variables de entorno.'
            menu_pv_label 'ATAJOS'
            menu_pv_text 'Dentro del menú: escribe para filtrar, ENTER para ejecutar,'
            menu_pv_text 'ESC para volver o salir.'
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

menu_pv_report() {
    local f=$1
    if [ ! -r "$f" ]; then
        menu_pv_text "No se puede leer el informe: $f"
        return 0
    fi
    menu_pv_title 'INFORME MARKDOWN'
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
        audit)
            menu_pv_title 'AUDITORÍA DIRECTA'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Ejecuta los 70 checks con el perfil full sin pasar por el menú.'
            ;;
        quick)
            menu_pv_title 'PERFIL RÁPIDO'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --profile quick'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Reduce los timeouts (5-8 s) y omite INT-02.'
            ;;
        sudo)
            menu_pv_title 'LECTURAS CON SUDO'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --sudo'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Usa «sudo -n» para lecturas que requieren root.'
            menu_pv_text 'Nunca pide contraseña: sin caché de sudo, el check sale SKIP.'
            menu_pv_label 'CONSEJO'
            menu_pv_cmd 'sudo -v && ./watch4me.sh audit --sudo'
            ;;
        save)
            menu_pv_title 'GUARDAR EN REPORTS/'
            menu_pv_label 'COMANDO'
            menu_pv_cmd './watch4me.sh audit --save'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Ejecuta la auditoría y escribe el .md en reports/ sin preguntar.'
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
            menu_pv_text 'Guarda el informe en la ruta indicada. Si es un directorio,'
            menu_pv_text 'genera el nombre con host y fecha.'
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
            menu_pv_text 'Lista los 70 checks agrupados por dominio con su severidad.'
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
            menu_pv_cmd './watch4me.sh audit --profile quick --sudo --save'
            menu_pv_label 'QUÉ HACE'
            menu_pv_text 'Perfil rápido, lecturas privilegiadas y guardado automático.'
            menu_pv_text 'El orden de las opciones no importa.'
            ;;
        exit)
            menu_pv_title 'CÓDIGOS DE SALIDA'
            menu_pv_text '0   sin hallazgos relevantes'
            menu_pv_text '1   avisos o fallos no críticos'
            menu_pv_text '2   al menos un fallo crítico'
            menu_pv_text '64  uso incorrecto o modo no disponible'
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
            'ENTER ejecutar | escribe para filtrar | ESC salir' \
            action)
        rc=$?
        menu_logo_stop
        [ "$rc" -eq 130 ] && break
        [ -z "$sel" ] && break
        id=${sel##*"$MENU_TAB"}

        case "$id" in
            audit-full)       menu_run_audit full 0 '' ;;
            audit-quick)      menu_run_audit quick 0 '' ;;
            audit-sudo)       menu_run_audit full 1 '' ;;
            audit-quick-sudo) menu_run_audit quick 1 '' ;;
            audit-save)       menu_run_audit full 0 'reports' ;;
            explain-pick)     menu_pick_check ;;
            explain-list)     menu_show_catalog ;;
            reports)          menu_reports ;;
            help)             menu_help ;;
            quit)             break ;;
        esac
    done

    menu_clear
    menu_exit_msg
    return 0
}
