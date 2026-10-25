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
MENU_SUDO=0

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
    if [ "${UI_WIDTH:-0}" -ge 78 ]; then
        printf ' %sGeneral = completa%s %s %sServidor/Cliente/PC = enfoque%s\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET"
        printf ' %sEsencial = rápido%s %s %s+sudo = más datos%s %s %swatch = vigilancia%s\n\n' \
            "$C_BOLD$C_YELLOW_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_GREEN_B" "$C_RESET"
    elif [ "${UI_WIDTH:-0}" -ge 52 ]; then
        printf ' %sGeneral = completa%s %s %sServidor/Cliente/PC%s %s %s+sudo%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_YELLOW_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_CYAN_B" "$C_RESET"
    else
        printf ' %sPerfiles%s %s %s+sudo%s\n\n' \
            "$C_BOLD$C_CYAN_B" "$C_RESET" "$sep" \
            "$C_BOLD$C_CYAN_B" "$C_RESET"
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
    local sep sudo_state
    sep=$(menu_sep)
    if [ "${MENU_SUDO:-0}" -eq 1 ]; then
        sudo_state='[x] activado'
    else
        sudo_state='[ ] desactivado'
    fi

    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '▶' '>')${C_RESET} ${C_BOLD}Auditoría general${C_RESET} ${C_DIM}${sep}${C_RESET} recomendada ${sep} $(profile_count general) checks" "audit-general"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '🖥' '[S]')${C_RESET} ${C_BOLD}Servidor${C_RESET} ${C_DIM}${sep}${C_RESET} SSH, servicios e integridad ${sep} $(profile_count servidor) checks" "audit-servidor"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '💻' '[C]')${C_RESET} ${C_BOLD}Cliente${C_RESET} ${C_DIM}${sep}${C_RESET} escritorio, Wi-Fi y cifrado ${sep} $(profile_count cliente) checks" "audit-cliente"
    menu_row "${C_BOLD}${C_MAGENTA_B}$(ui_icon '🏠' '[D]')${C_RESET} ${C_BOLD}PC doméstico${C_RESET} ${C_DIM}${sep}${C_RESET} lo importante de casa ${sep} $(profile_count domestico) checks" "audit-domestico"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '⚡' '!')${C_RESET} ${C_BOLD}Vistazo esencial${C_RESET} ${C_DIM}${sep}${C_RESET} rápido ${sep} $(profile_count esencial) checks" "audit-esencial"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔑' '[s]')${C_RESET} ${C_BOLD}Lecturas con sudo${C_RESET} ${C_DIM}${sep}${C_RESET} ${sudo_state} ${sep} no pide contraseña" "toggle-sudo"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '👁' '[w]')${C_RESET} ${C_BOLD}Vigilancia en vivo${C_RESET} ${C_DIM}${sep}${C_RESET} conexiones, servicios y persistencia" "watch"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '🔎' '[?]')${C_RESET} ${C_BOLD}Explicar un check${C_RESET} ${C_DIM}${sep}${C_RESET} detalle y remedio" "explain-pick"
    menu_row "${C_BOLD}${C_CYAN_B}$(ui_icon '📚' '[c]')${C_RESET} ${C_BOLD}Catálogo de checks${C_RESET} ${C_DIM}${sep}${C_RESET} los ${#CHECK_IDS[@]} por dominio" "explain-list"
    menu_row "${C_BOLD}${C_YELLOW_B}$(ui_icon '📄' '[r]')${C_RESET} ${C_BOLD}Informes guardados${C_RESET} ${C_DIM}${sep}${C_RESET} consulta .md y .json" "reports"
    menu_row "${C_BOLD}${C_GREEN_B}$(ui_icon '❓' '[h]')${C_RESET} ${C_BOLD}Ayuda y atajos${C_RESET} ${C_DIM}${sep}${C_RESET} comandos y guía" "help"
    menu_row "${C_BOLD}${C_RED_B}$(ui_icon '⏻' '[x]')${C_RESET} ${C_BOLD}Salir${C_RESET} ${C_DIM}${sep}${C_RESET} cerrar sin ejecutar" "quit"
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
    local rc anim_save=$UI_ANIM

    USE_SUDO=${MENU_SUDO:-0}
    SUDO_CHECKED=0
    SUDO_OK=0
    WATCH_ONCE=0
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
    menu_row "${C_BOLD}./watch4me.sh audit${C_RESET} ${C_DIM}${sep}${C_RESET} auditoría general (${#CHECK_IDS[@]} checks) sin menú" "audit"
    menu_row "${C_BOLD}./watch4me.sh audit --profile <perfil>${C_RESET} ${C_DIM}${sep}${C_RESET} servidor, cliente, doméstico o esencial" "profiles"
    menu_row "${C_BOLD}./watch4me.sh watch${C_RESET} ${C_DIM}${sep}${C_RESET} vigilancia en vivo de conexiones y servicios" "watch"
    menu_row "${C_BOLD}./watch4me.sh watch --once${C_RESET} ${C_DIM}${sep}${C_RESET} una sola captura, útil en scripts o cron" "watch-once"
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
        audit-general|audit-full)
            menu_pv_profile general 0
            ;;
        audit-servidor)
            menu_pv_profile servidor 0
            ;;
        audit-cliente)
            menu_pv_profile cliente 0
            ;;
        audit-domestico)
            menu_pv_profile domestico 0
            ;;
        audit-esencial|audit-quick)
            menu_pv_profile esencial 0
            ;;
        audit-sudo)
            menu_pv_profile general 1
            ;;
        audit-quick-sudo)
            menu_pv_profile esencial 1
            ;;
        audit-save)
            menu_pv_profile general 0
            ;;
        toggle-sudo)
            menu_pv_title 'LECTURAS CON SUDO'
            menu_pv_text 'Activa o desactiva sudo -n para las próximas auditorías y para watch.'
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
        explain-pick)
            menu_pv_title 'EXPLICAR UN CHECK'
            menu_pv_text 'Abre un buscador con los checks registrados.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'Escribe un ID (NET-01), un título o un dominio (SSH, red,'
            menu_pv_text 'contraseñas...). El panel derecho muestra la ficha y los perfiles.'
            menu_pv_text 'ENTER abre la descripción completa y el remedio sugerido.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain NET-01'
            ;;
        explain-list)
            menu_pv_title 'CATÁLOGO DE CHECKS'
            menu_pv_text 'Muestra todos los checks agrupados por dominio, con su ID,'
            menu_pv_text 'severidad, perfiles que lo incluyen y título.'
            menu_pv_label 'PERFILES'
            menu_pv_text 'S servidor · C cliente · D doméstico · E esencial · - solo general'
            menu_pv_label 'EFECTOS'
            menu_pv_text 'Solo lectura. Abre el resultado en el paginador.'
            menu_pv_label 'EQUIVALENTE EN CLI'
            menu_pv_cmd './watch4me.sh explain --list'
            ;;
        reports)
            menu_pv_title 'INFORMES GUARDADOS'
            menu_pv_text 'Lista los .md y .json de reports/ del más reciente al más antiguo.'
            menu_pv_label 'CÓMO'
            menu_pv_text 'El panel derecho muestra una vista previa del Markdown o del JSON.'
            menu_pv_text 'ENTER lo abre en less (o en cat si no está disponible).'
            menu_pv_label 'SI ESTÁ VACÍO'
            menu_pv_text 'Ejecuta una auditoría y responde «s» cuando ofrezca guardar.'
            ;;
        help)
            menu_pv_title 'AYUDA Y ATAJOS'
            menu_pv_text 'Reúne los comandos directos de watch4me con ejemplos listos'
            menu_pv_text 'para copiar: perfiles, watch, sudo, informes y explain.'
            menu_pv_label 'INCLUYE'
            menu_pv_text '--profile, watch, --once, --interval, --save, --save -, --sudo,'
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
            menu_pv_text '0   sin hallazgos relevantes'
            menu_pv_text '1   avisos o fallos no críticos'
            menu_pv_text '2   al menos un fallo crítico'
            menu_pv_text '64  uso incorrecto, modo no disponible o falta ss en watch'
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
            audit-general)    menu_run_audit general ;;
            audit-servidor)   menu_run_audit servidor ;;
            audit-cliente)    menu_run_audit cliente ;;
            audit-domestico)  menu_run_audit domestico ;;
            audit-esencial)   menu_run_audit esencial ;;
            toggle-sudo)      MENU_SUDO=$(( 1 - MENU_SUDO )) ;;
            watch)            menu_watch ;;
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
