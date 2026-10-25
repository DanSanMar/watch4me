#!/usr/bin/env bash
# watch4me — checks de usuarios y privilegios (USR)
# Licencia: GPLv3

register_check \
    'USR-01' critical 'Cuentas con UID 0' check_usr_01 \
    'Cualquier cuenta con UID 0 tiene privilegios equivalentes a root. Debe existir únicamente la cuenta root.' \
    $'Revisa la cuenta y cámbiale el UID o elimínala:\n  sudo usermod -u 1000 <usuario>\n  sudo userdel -r <usuario>\nComprueba antes qué procesos y ficheros pertenecen a esa cuenta.'

check_usr_01() {
    local id=$CURRENT_ID
    local extra
    extra=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd 2>/dev/null)

    if [ -z "$extra" ]; then
        emit "$id" PASS 'solo root tiene UID 0'
        return
    fi

    local count
    count=$(printf '%s\n' "$extra" | grep -c .)
    emit "$id" FAIL "$count cuenta(s) con UID 0 además de root: $(printf '%s' "$extra" | oneline)"

    while IFS= read -r user; do
        [ -n "$user" ] && ev "$(grep -E "^${user}:" /etc/passwd 2>/dev/null | head -n 1)"
    done <<< "$extra"
}

register_check \
    'USR-02' critical 'Cuentas con contraseña vacía' check_usr_02 \
    'Una cuenta con el campo de contraseña vacío en /etc/shadow permite iniciar sesión sin credencial. Requiere leer shadow con --sudo.' \
    $'Bloquea inmediatamente las cuentas afectadas:\n  sudo passwd -l <usuario>\nDespués asigna una contraseña nueva o revisa si la cuenta sigue siendo necesaria.'

check_usr_02() {
    local id=$CURRENT_ID
    local shadow
    shadow=$(rootread /etc/shadow 2>/dev/null)
    if [ -z "$shadow" ]; then
        emit "$id" SKIP 'no se puede leer /etc/shadow sin privilegios (usa --sudo)'
        return
    fi

    local empty='' n=0 user hash rest
    while IFS=: read -r user hash rest; do
        case "$user" in
            ''|'#'*) continue ;;
        esac
        if [ -z "$hash" ]; then
            n=$(( n + 1 ))
            empty+="$user "
            ev "$user tiene contraseña vacía"
        fi
    done <<< "$shadow"

    if [ "$n" -eq 0 ]; then
        emit "$id" PASS 'ninguna cuenta tiene la contraseña vacía'
    else
        emit "$id" FAIL "$n cuenta(s) con contraseña vacía: ${empty% }"
    fi
}

register_check \
    'USR-03' medium 'Cuentas de sistema con shell interactiva' check_usr_03 \
    'Las cuentas de sistema (UID < 1000) no deberían permitir iniciar sesión con shell. Si un servicio se ve comprometido, una shell válida facilita el movimiento lateral.' \
    $'Cambia la shell de las cuentas de servicio:\n  sudo usermod -s /usr/sbin/nologin <usuario>\nSi la cuenta no se usa, elimínala: sudo userdel <usuario>'

check_usr_03() {
    local id=$CURRENT_ID
    local bad
    bad=$(awk -F: '$3 < 1000 && $3 != 0 && $7 !~ /(nologin|false|sync|shutdown|halt|git-shell)$/ { print $1 " (" $7 ")" }' /etc/passwd 2>/dev/null)

    if [ -z "$bad" ]; then
        emit "$id" PASS 'las cuentas de sistema no tienen shell interactiva'
        return
    fi

    local n
    n=$(printf '%s\n' "$bad" | grep -c .)
    emit "$id" WARN "$n cuenta(s) de sistema con shell: $(printf '%s' "$bad" | oneline)"
    printf '%s\n' "$bad" | head -n 10 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
}

register_check \
    'USR-04' high 'Algoritmos de hash de contraseñas débiles' check_usr_04 \
    'MD5-crypt y DES son rompibles con GPU en muy poco tiempo. Lo recomendado es yescrypt, SHA-512 o bcrypt. Requiere leer shadow con --sudo.' \
    $'Rehashea las contraseñas afectadas (se pedirá una nueva):\n  sudo passwd <usuario>\nComprueba el método por defecto en /etc/login.defs:\n  ENCRYPT_METHOD YESCRYPT   # o SHA512'

check_usr_04() {
    local id=$CURRENT_ID
    local shadow
    shadow=$(rootread /etc/shadow 2>/dev/null)
    if [ -z "$shadow" ]; then
        emit "$id" SKIP 'no se puede leer /etc/shadow sin privilegios (usa --sudo)'
        return
    fi

    local weak='' sha256='' user hash rest n_weak=0 n_sha=0
    while IFS=: read -r user hash rest; do
        case "$user" in ''|'#'*) continue ;; esac
        case "$hash" in
            ''|'!'*|'*'*) continue ;;
        esac
        case "$hash" in
            \$1\$*) weak+="$user(MD5) "; n_weak=$(( n_weak + 1 )) ;;
            \$5\$*) sha256+="$user(SHA-256) "; n_sha=$(( n_sha + 1 )) ;;
            \$6\$*|\$y\$*|\$7\$*|\$2a\$*|\$2b\$*|\$2y\$*) ;;
            *)
                if [ "${#hash}" -eq 13 ]; then
                    weak+="$user(DES) "
                    n_weak=$(( n_weak + 1 ))
                fi
                ;;
        esac
    done <<< "$shadow"

    if [ "$n_weak" -gt 0 ]; then
        emit "$id" FAIL "$n_weak cuenta(s) con hash débil: ${weak% }"
        printf '%s\n' "$weak" | tr ' ' '\n' | grep . | head -n 10 | while IFS= read -r line; do
            ev "$line"
        done
    elif [ "$n_sha" -gt 0 ]; then
        emit "$id" WARN "$n_sha cuenta(s) usan SHA-256 (aceptable, no ideal): ${sha256% }"
    else
        emit "$id" PASS 'las contraseñas usan un algoritmo de hash fuerte'
    fi
}

register_check \
    'USR-05' high 'Configuración de sudoers' check_usr_05 \
    'Busca reglas NOPASSWD, permisos excesivos y ficheros de sudoers manipulables. Un sudoers débil permite escalar a root sin contraseña.' \
    $'Corrige los permisos:\n  sudo chown root:root /etc/sudoers /etc/sudoers.d/*\n  sudo chmod 440 /etc/sudoers /etc/sudoers.d/*\nElimina NOPASSWD salvo que sea imprescindible y limita las reglas a comandos concretos.'

check_usr_05() {
    local id=$CURRENT_ID

    local -a files=(/etc/sudoers)
    if [ -d /etc/sudoers.d ]; then
        local listing
        listing=$(find /etc/sudoers.d -maxdepth 1 -type f \
            ! -name '*~' ! -name '*.bak' ! -name '*.rpmsave' 2>/dev/null | sort)
        if [ -z "$listing" ]; then
            listing=$(as_root find /etc/sudoers.d -maxdepth 1 -type f \
                ! -name '*~' ! -name '*.bak' ! -name '*.rpmsave' 2>/dev/null | sort)
        fi
        while IFS= read -r f; do
            [ -n "$f" ] && files+=("$f")
        done <<< "$listing"
    fi

    local readable=0 inaccessible=0 nopass=0 perm_bad=0
    local f stat_line mode owner content line

    for f in "${files[@]}"; do
        [ -e "$f" ] || continue
        stat_line=$(stat -c '%a %U:%G' "$f" 2>/dev/null) \
            || stat_line=$(as_root stat -c '%a %U:%G' "$f" 2>/dev/null) \
            || { inaccessible=$(( inaccessible + 1 )); continue; }
        mode=${stat_line%% *}
        owner=${stat_line#* }

        if [ "$owner" != 'root:root' ]; then
            perm_bad=$(( perm_bad + 1 ))
            ev "$f: propietario $owner (esperado root:root)"
        fi
        if [[ "$mode" =~ ^[0-7]+$ ]]; then
            local m=$(( 8#$mode ))
            if [ $(( m & 002 )) -ne 0 ] || [ $(( m & 020 )) -ne 0 ]; then
                perm_bad=$(( perm_bad + 1 ))
                ev "$f: modo $mode (escribible por grupo u otros)"
            fi
        fi

        content=$(rootread "$f" 2>/dev/null) || { inaccessible=$(( inaccessible + 1 )); continue; }
        readable=$(( readable + 1 ))

        while IFS= read -r line; do
            local tline=${line#"${line%%[![:space:]]*}"}
            case "$tline" in
                ''|'#'*) continue ;;
            esac
            if printf '%s' "$tline" | grep -q 'NOPASSWD'; then
                nopass=$(( nopass + 1 ))
                ev "$f: $(trim "$tline")"
            fi
        done <<< "$content"
    done

    if [ "$readable" -eq 0 ]; then
        if [ "$inaccessible" -gt 0 ]; then
            emit "$id" SKIP 'sudoers no es legible sin privilegios (usa --sudo)'
        else
            emit "$id" SKIP 'no se encontró configuración de sudo'
        fi
        return
    fi

    if [ "$nopass" -gt 0 ]; then
        emit "$id" FAIL "$nopass regla(s) NOPASSWD en sudoers"
    elif [ "$perm_bad" -gt 0 ]; then
        emit "$id" WARN "$perm_bad problema(s) de permisos en ficheros sudoers"
    else
        emit "$id" PASS 'sudoers sin NOPASSWD y con permisos correctos'
    fi
}

register_check \
    'USR-06' high 'Grupo root sin miembros adicionales' check_usr_06 \
    'Pertenecer al grupo root (GID 0) da acceso de lectura y escritura a ficheros de grupo root. Debe estar vacío salvo root.' \
    $'Revisa y retira los miembros del grupo root:\n  getent group root\n  sudo gpasswd -d <usuario> root\nY cambia el grupo primario de las cuentas afectadas:\n  sudo usermod -g <grupo> <usuario>'

check_usr_06() {
    local id=$CURRENT_ID
    local members extra_gid
    members=$(awk -F: '$3 == 0 { print $4 }' /etc/group 2>/dev/null \
        | tr ',' '\n' | grep -vx 'root' | grep -v '^$' | paste -sd, -)
    extra_gid=$(awk -F: '$4 == 0 && $1 != "root" { print $1 }' /etc/passwd 2>/dev/null)

    if [ -z "$members" ] && [ -z "$extra_gid" ]; then
        emit "$id" PASS 'solo root pertenece al grupo root'
        return
    fi

    local detail=''
    [ -n "$members" ] && detail+="miembros del grupo root: $members"
    if [ -n "$extra_gid" ]; then
        [ -n "$detail" ] && detail+='; '
        detail+="grupo primario root: $(printf '%s' "$extra_gid" | oneline)"
    fi
    emit "$id" FAIL "$detail"
}

register_check \
    'USR-07' medium 'Caducidad de contraseñas' check_usr_07 \
    'Contraseñas sin caducidad ni bloqueo por inactividad permanecen válidas indefinidamente si se filtran. Requiere leer shadow con --sudo.' \
    $'Ajusta la política global en /etc/login.defs:\n  PASS_MAX_DAYS 365\n  PASS_MIN_DAYS 1\n  PASS_WARN_AGE 7\nY aplícala a los usuarios existentes:\n  sudo chage -M 365 -m 1 -W 7 -I 30 <usuario>'

check_usr_07() {
    local id=$CURRENT_ID
    local shadow
    shadow=$(rootread /etc/shadow 2>/dev/null)
    if [ -z "$shadow" ]; then
        emit "$id" SKIP 'no se puede leer /etc/shadow sin privilegios (usa --sudo)'
        return
    fi

    local uid
    local -A human=()
    while IFS=: read -r user _ uid _; do
        if [ "$uid" -eq 0 ] 2>/dev/null || { [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ]; }; then
            human[$user]=1
        fi
    done < /etc/passwd

    local user hash last min max warn inactive expire n=0 bad=''
    while IFS=: read -r user hash last min max warn inactive expire; do
        [ -n "${human[$user]:-}" ] || continue
        case "$hash" in ''|'!'*|'*'*) continue ;; esac

        local problem=''
        if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -eq 0 ]; then
            problem='sin caducidad'
        elif [ "$max" -gt 365 ]; then
            problem="caduca en $max días"
        fi
        if ! [[ "$inactive" =~ ^[0-9]+$ ]] || [ "$inactive" -eq 0 ]; then
            [ -n "$problem" ] && problem+=', '
            problem+='sin bloqueo por inactividad'
        elif [ "$inactive" -gt 30 ]; then
            [ -n "$problem" ] && problem+=', '
            problem+="inactividad $inactive días"
        fi

        if [ -n "$problem" ]; then
            n=$(( n + 1 ))
            bad+="$user($problem) "
            ev "$user: $problem"
        fi
    done <<< "$shadow"

    if [ "$n" -eq 0 ]; then
        emit "$id" PASS 'las cuentas humanas tienen caducidad y bloqueo por inactividad'
    else
        emit "$id" WARN "$n cuenta(s) con política de caducidad débil: ${bad% }"
    fi
}

register_check \
    'USR-08' low 'UMASK por defecto' check_usr_08 \
    'Un umask laxo hace que los ficheros nuevos nazcan legibles o escribibles por otros usuarios del sistema.' \
    $'Configura un umask restrictivo en /etc/login.defs y /etc/profile:\n  UMASK 027\n  umask 027\nComprueba con: umask'

check_usr_08() {
    local id=$CURRENT_ID
    local val='' src=''
    if [ -r /etc/login.defs ]; then
        val=$(awk '$1 == "UMASK" { print $2; exit }' /etc/login.defs 2>/dev/null)
        [ -n "$val" ] && src='/etc/login.defs'
    fi
    if [ -z "$val" ] && [ -r /etc/profile ]; then
        val=$(grep -E '^[[:space:]]*umask[[:space:]]+' /etc/profile 2>/dev/null | awk '{ print $2; exit }')
        [ -n "$val" ] && src='/etc/profile'
    fi

    if [ -z "$val" ]; then
        emit "$id" SKIP 'no se encontró UMASK en login.defs ni en /etc/profile'
        return
    fi
    if ! [[ "$val" =~ ^[0-7]{1,4}$ ]]; then
        emit "$id" SKIP "valor de umask no reconocido: $val"
        return
    fi

    local canon
    canon=$(printf '%o' $(( 8#$val )))
    ev "$src: umask $val"
    case "$canon" in
        27|37|47|77|7) emit "$id" PASS "umask restrictivo ($val)" ;;
        22|2|0|20) emit "$id" WARN "umask laxo ($val): otros usuarios pueden leer los ficheros nuevos" ;;
        *) emit "$id" WARN "umask no óptimo ($val)" ;;
    esac
}

register_check \
    'USR-09' medium 'UID y nombres de usuario duplicados' check_usr_09 \
    'Dos cuentas con el mismo UID comparten propietario y permisos: una puede leer o modificar los ficheros de la otra. Los nombres duplicados confunden la auditoría.' \
    $'Localiza las entradas duplicadas:\n  awk -F: "{print \\$3}" /etc/passwd | sort | uniq -d\nCorrige el UID o elimina la cuenta sobrante con usermod/userdel.'

check_usr_09() {
    local id=$CURRENT_ID
    local dup_uids dup_names dup_gids
    dup_uids=$(awk -F: '{ print $3 }' /etc/passwd 2>/dev/null | sort -n | uniq -d)
    dup_names=$(cut -d: -f1 /etc/passwd 2>/dev/null | sort | uniq -d)
    dup_gids=$(awk -F: '{ print $3 }' /etc/group 2>/dev/null | sort -n | uniq -d)

    if [ -z "$dup_uids" ] && [ -z "$dup_names" ]; then
        if [ -n "$dup_gids" ]; then
            emit "$id" WARN "GID duplicados: $(printf '%s' "$dup_gids" | oneline)"
        else
            emit "$id" PASS 'sin UID, nombres ni GID duplicados'
        fi
        return
    fi

    local detail=''
    [ -n "$dup_uids" ] && detail+="UID duplicados: $(printf '%s' "$dup_uids" | oneline)"
    if [ -n "$dup_names" ]; then
        [ -n "$detail" ] && detail+='; '
        detail+="nombres duplicados: $(printf '%s' "$dup_names" | oneline)"
    fi
    if [ -n "$dup_gids" ]; then
        [ -n "$detail" ] && detail+='; '
        detail+="GID duplicados: $(printf '%s' "$dup_gids" | oneline)"
    fi
    emit "$id" FAIL "$detail"

    local u
    for u in $dup_uids; do
        ev "$(awk -F: -v u="$u" '$3 == u { print $1 " (UID " $3 ")" }' /etc/passwd | oneline)"
    done
}

register_check \
    'USR-10' low 'Permisos de los directorios home' check_usr_10 \
    'Un home escribible por otros usuarios permite inyectar scripts, alterar configuraciones o robar datos. También se revisa que el propietario coincida.' \
    $'Corrige propietario y permisos de los homes:\n  sudo chown -R <usuario>:<usuario> /home/<usuario>\n  sudo chmod 750 /home/<usuario>'

check_usr_10() {
    local id=$CURRENT_ID
    local u home st mode owner m
    local writable='' wrong='' checked=0

    for u in $(interactive_users); do
        home=$(user_home "$u")
        [ -n "$home" ] && [ -d "$home" ] || continue
        st=$(stat -c '%a %U' "$home" 2>/dev/null) || continue
        checked=$(( checked + 1 ))
        mode=${st%% *}
        owner=${st#* }
        if [[ "$mode" =~ ^[0-7]+$ ]]; then
            m=$(( 8#$mode ))
            if [ $(( m & 002 )) -ne 0 ] || [ $(( m & 020 )) -ne 0 ]; then
                writable+="$home($mode) "
                ev "$home: escribible por grupo u otros"
            fi
        fi
        if [ "$owner" != "$u" ]; then
            wrong+="$home:$owner "
            ev "$home: propietario $owner (esperado $u)"
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron directorios home de usuarios'
        return
    fi
    if [ -n "$writable" ] || [ -n "$wrong" ]; then
        local detail=''
        [ -n "$writable" ] && detail+="escribibles por otros: ${writable% }"
        if [ -n "$wrong" ]; then
            [ -n "$detail" ] && detail+='; '
            detail+="propietario incorrecto: ${wrong% }"
        fi
        emit "$id" WARN "$detail"
    else
        emit "$id" PASS "los ${checked} directorios home revisados tienen permisos correctos"
    fi
}

register_check \
    'USR-11' medium 'Inicio de sesión automático y cuenta invitado' check_usr_11 \
    'El inicio automático entra sin pedir contraseña y la cuenta invitado permite usar el equipo sin identidad. En un cliente o PC doméstico facilitan el acceso físico, pero también el uso por parte de terceros.' \
    $'Desactiva el inicio automático y la cuenta invitado:\n  GDM:     /etc/gdm/custom.conf → AutomaticLoginEnable=false\n  SDDM:    /etc/sddm.conf → [Autologin] User=\n  LightDM: /etc/lightdm/lightdm.conf → autologin-user= y allow-guest=false\n  GNOME:   gsettings set org.gnome.login-screen allow-guest false\nDespués reinicia el gestor de sesión.'

check_usr_11() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: no hay gestor de sesión gráfico'
        return
    fi

    local found=0 issues='' checked=0 f val
    local -a files=(
        /etc/gdm3/custom.conf /etc/gdm/custom.conf
        /etc/sddm.conf /etc/sddm.conf.d/*.conf
        /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf
        /etc/lxdm/lxdm.conf
    )

    for f in "${files[@]}"; do
        [ -r "$f" ] || continue
        checked=$(( checked + 1 ))

        # GDM
        if grep -qiE '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*(true|yes|1)[[:space:]]*$' "$f" 2>/dev/null; then
            found=1
            val=$(grep -iE '^[[:space:]]*AutomaticLogin[[:space:]]*=' "$f" 2>/dev/null | tail -n 1)
            issues+="GDM inicio automático${val:+ ($(trim "$val"))} · "
            ev "$f: $(trim "$val")"
        fi

        # SDDM: [Autologin] User=...
        if grep -qiE '^[[:space:]]*\[Autologin\]' "$f" 2>/dev/null; then
            val=$(awk -F= '
                /^[[:space:]]*\[/ { sec=$0 }
                sec ~ /\[Autologin\]/ && $1 ~ /User[[:space:]]*$/ {
                    v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v != "") print v
                }' "$f" 2>/dev/null | head -n 1)
            if [ -n "$val" ]; then
                found=1
                issues+="SDDM inicio automático ($val) · "
                ev "$f: Autologin User=$val"
            fi
        fi

        # LightDM
        if grep -qiE '^[[:space:]]*autologin-user[[:space:]]*=[[:space:]]*[^[:space:]]' "$f" 2>/dev/null; then
            found=1
            val=$(grep -iE '^[[:space:]]*autologin-user[[:space:]]*=' "$f" 2>/dev/null | tail -n 1)
            issues+="LightDM inicio automático ($(trim "$val")) · "
            ev "$f: $(trim "$val")"
        fi
        if grep -qiE '^[[:space:]]*allow-guest[[:space:]]*=[[:space:]]*true' "$f" 2>/dev/null; then
            found=1
            issues+='LightDM cuenta invitado activa · '
            ev "$f: allow-guest=true"
        fi

        # LXDM
        if grep -qiE '^[[:space:]]*autologin[[:space:]]*=[[:space:]]*[^[:space:]]' "$f" 2>/dev/null; then
            found=1
            val=$(grep -iE '^[[:space:]]*autologin[[:space:]]*=' "$f" 2>/dev/null | tail -n 1)
            issues+="LXDM inicio automático ($(trim "$val")) · "
            ev "$f: $(trim "$val")"
        fi
    done

    # GNOME también permite consultar la cuenta invitado por gsettings.
    if have gsettings; then
        val=$(gsettings get org.gnome.login-screen allow-guest 2>/dev/null) || val=''
        if [ "$val" = 'true' ]; then
            found=1
            issues+='GNOME cuenta invitado activa · '
            ev 'gsettings: org.gnome.login-screen allow-guest=true'
        fi
    fi

    if [ "$found" -eq 0 ]; then
        if [ "$checked" -eq 0 ]; then
            emit "$id" SKIP 'no se detectó un gestor de sesión gráfico'
        else
            emit "$id" PASS 'sin inicio automático ni cuenta invitado'
        fi
        return
    fi

    emit "$id" WARN "acceso sin credenciales: ${issues% · }"
}
