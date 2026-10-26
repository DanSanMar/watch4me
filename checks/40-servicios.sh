#!/usr/bin/env bash
# watch4me — checks de servicios (SVC)
# Licencia: GPLv3

# Recorre sshd_config expandiendo los Include en orden (primera coincidencia gana).
_sshd_collect() {
    local file=$1 depth=${2:-0}
    [ "$depth" -le 5 ] || return 0
    [ -r "$file" ] || return 0
    local line pattern match
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            [Ii]nclude*)
                pattern=$(printf '%s' "$line" | awk '{ $1=""; sub(/^[ \t]+/, ""); print }')
                for match in $pattern; do
                    [ -r "$match" ] && _sshd_collect "$match" $(( depth + 1 ))
                done
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$file"
}

# Configuración efectiva de sshd si hay privilegios; si no, la declarada.
_sshd_effective() {
    local cfg=/etc/ssh/sshd_config eff=''
    if is_root; then
        eff=$(timeout 10 sshd -T 2>/dev/null)
    elif sudo_ok; then
        eff=$(sudo -n timeout 10 sshd -T 2>/dev/null)
    fi
    if [ -z "$eff" ]; then
        eff=$(_sshd_collect "$cfg")
    fi
    printf '%s' "$eff"
}

register_check \
    'SVC-01' medium 'Unidades systemd fallidas' check_svc_01 \
    'Una unidad en estado failed indica un servicio que no arrancó o se cayó. Puede ser un fallo operativo o el síntoma de un intento de explotación.' \
    $'Revisa el motivo de cada fallo:\n  systemctl --failed\n  systemctl status <unidad>\n  journalctl -u <unidad> -n 100 --no-pager\nCorrige la causa y reinicia la unidad.'

check_svc_01() {
    local id=$CURRENT_ID
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi

    local out
    out=$(systemctl --failed --no-legend --plain 2>/dev/null)
    if [ -z "$out" ]; then
        emit "$id" PASS 'no hay unidades systemd fallidas'
        return
    fi

    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    emit "$id" WARN "$n unidad(es) systemd en estado failed"
    printf '%s\n' "$out" | head -n 10 | while IFS= read -r line; do
        ev "$(trim "$line")"
    done
}

register_check \
    'SVC-02' medium 'Servicios obsoletos habilitados al arranque' check_svc_02 \
    'Un servicio heredado habilitado vuelve a arrancar en cada inicio aunque no se use. Deshabilitarlo reduce la superficie de ataque de forma permanente.' \
    $'Deshabilita los servicios que no uses:\n  sudo systemctl disable --now telnet.socket rsh.socket rlogin.socket tftp.socket\n  sudo systemctl disable --now vsftpd proftpd rpcbind avahi-daemon cups\n  systemctl list-unit-files --state=enabled'

check_svc_02() {
    local id=$CURRENT_ID
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi

    local units='cups cups-browsed avahi-daemon rpcbind rpcbind.socket nfs-server nfs-kernel-server smbd nmbd vsftpd proftpd pure-ftpd tftp.socket telnet.socket telnet rsh.socket rsh rlogin.socket rlogin rexec.socket'
    local legacy=' telnet.socket telnet rsh.socket rsh rlogin.socket rlogin rexec.socket tftp.socket vsftpd proftpd pure-ftpd nfs-server nfs-kernel-server '
    local enabled='' enabled_legacy='' u
    for u in $units; do
        unit_enabled "$u" || continue
        enabled+="$u "
        case "$legacy" in
            *" $u "*) enabled_legacy+="$u " ;;
        esac
    done

    if [ -n "$enabled_legacy" ]; then
        emit "$id" FAIL "servicios inseguros habilitados: ${enabled_legacy% }"
    elif [ -n "$enabled" ]; then
        emit "$id" WARN "servicios habilitados que podrías no necesitar: ${enabled% }"
    else
        emit "$id" PASS 'no se detectan servicios obsoletos habilitados'
    fi
}

register_check \
    'SVC-03' medium 'Algoritmos débiles en SSH' check_svc_03 \
    'Cifrados, MACs e intercambios de claves obsoletos permiten ataques de downgrade o descifrado. OpenSSH ya excluye los peores por defecto; el riesgo aparece al reañadirlos.' \
    $'Elimina los algoritmos débiles de sshd_config y deja los valores por defecto de OpenSSH:\n  Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com\n  MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com\n  KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512\nValida con: sudo sshd -t'

check_svc_03() {
    local id=$CURRENT_ID
    local cfg=/etc/ssh/sshd_config
    if [ ! -f "$cfg" ]; then
        emit "$id" INFO 'OpenSSH no está instalado'
        return
    fi

    local raw eff
    raw=$(_sshd_collect "$cfg")
    eff=$(_sshd_effective)

    local critical=' arcfour arcfour128 arcfour256 3des-cbc blowfish-cbc cast128-cbc hmac-md5 hmac-md5-96 diffie-hellman-group1-sha1 ssh-dss '
    local deprecated=' hmac-sha1 hmac-sha1-96 diffie-hellman-group14-sha1 ssh-rsa '
    local issues='' n_crit=0 n_dep=0

    local line key vals tok
    while IFS= read -r line; do
        key=$(printf '%s' "$line" | awk '{ print tolower($1) }')
        case "$key" in
            ciphers|macs|kexalgorithms|hostkeyalgorithms) ;;
            *) continue ;;
        esac
        vals=$(printf '%s' "$line" | cut -d' ' -f2-)
        for tok in ${vals//,/ }; do
            tok=${tok,,}
            case "$critical" in
                *" $tok "*)
                    issues+="$key:$tok "
                    n_crit=$(( n_crit + 1 ))
                    ;;
            esac
        done
    done <<< "$eff"

    # Los algoritmos solo obsoletos se señalan únicamente si están declarados.
    while IFS= read -r line; do
        key=$(printf '%s' "$line" | awk '{ print tolower($1) }')
        case "$key" in
            ciphers|macs|kexalgorithms|hostkeyalgorithms) ;;
            *) continue ;;
        esac
        vals=$(printf '%s' "$line" | cut -d' ' -f2-)
        for tok in ${vals//,/ }; do
            tok=${tok,,}
            case "$deprecated" in
                *" $tok "*)
                    issues+="$key:$tok "
                    n_dep=$(( n_dep + 1 ))
                    ;;
            esac
        done
    done <<< "$raw"

    if [ "$n_crit" -gt 0 ]; then
        emit "$id" WARN "algoritmos débiles habilitados: ${issues% }"
    elif [ "$n_dep" -gt 0 ]; then
        emit "$id" WARN "algoritmos obsoletos declarados: ${issues% }"
    elif [ -z "$eff" ]; then
        emit "$id" SKIP 'no se pudo leer la configuración de sshd'
    else
        emit "$id" PASS 'sin algoritmos criptográficos débiles configurados'
    fi
}

register_check \
    'SVC-04' medium 'Protección contra fuerza bruta SSH' check_svc_04 \
    'Si SSH acepta contraseñas, un atacante puede probar credenciales sin límite. fail2ban, sshguard o crowdsec bloquean tras varios fallos.' \
    $'Instala y activa una protección:\n  Debian/Ubuntu: sudo apt install fail2ban && sudo systemctl enable --now fail2ban\n  Arch:          sudo pacman -S fail2ban && sudo systemctl enable --now fail2ban\n  RHEL/SUSE:     sudo dnf install fail2ban   # o usa firewalld + reglas limit\nAlternativa con ufw: sudo ufw limit 22/tcp'

check_svc_04() {
    local id=$CURRENT_ID
    if ! unit_active sshd && ! unit_active ssh; then
        emit "$id" INFO 'el servidor SSH no está activo'
        return
    fi

    local found='' u
    for u in fail2ban sshguard crowdsec; do
        if unit_active "$u"; then
            found+="$u "
        fi
    done

    if [ -z "$found" ] && have ufw; then
        if ufw status 2>/dev/null | grep -Eq '^22(/tcp)?[[:space:]].*LIMIT'; then
            found='ufw limit'
        fi
    fi

    if [ -n "$found" ]; then
        emit "$id" PASS "protección activa: ${found% }"
    else
        emit "$id" WARN 'SSH activo sin fail2ban, sshguard, crowdsec ni límite de ufw'
    fi
}

register_check \
    'SVC-05' high 'Contenedores privilegiados y socket de Docker' check_svc_05 \
    'Un contenedor privilegiado puede escapar del aislamiento y acceder al anfitrión. Un socket de Docker escribible por otros equivale a root.' \
    $'Evita --privileged y montar /var/run/docker.sock dentro de contenedores.\nRevisa los permisos del socket:\n  stat -c "%a %U:%G" /var/run/docker.sock   # esperado 660 root:docker\nAudita los contenedores:\n  docker ps -q | xargs docker inspect -f "{{.Name}} {{.HostConfig.Privileged}}"'

check_svc_05() {
    local id=$CURRENT_ID
    local tool=''
    if have docker && docker info >/dev/null 2>&1; then
        tool=docker
    elif have podman && podman info >/dev/null 2>&1; then
        tool=podman
    fi

    local sock_issue='' priv=''
    if [ -S /var/run/docker.sock ]; then
        local st mode m
        st=$(stat -c '%a %U:%G' /var/run/docker.sock 2>/dev/null)
        mode=${st%% *}
        if [[ "$mode" =~ ^[0-7]+$ ]]; then
            m=$(( 8#$mode ))
            if [ $(( m & 002 )) -ne 0 ]; then
                sock_issue="/var/run/docker.sock escribible por otros ($st)"
                ev "$sock_issue"
            fi
        fi
    fi

    if [ -z "$tool" ]; then
        if [ -n "$sock_issue" ]; then
            emit "$id" FAIL "$sock_issue"
        elif have docker || have podman; then
            emit "$id" SKIP 'motor de contenedores presente pero sin acceso al daemon'
        else
            emit "$id" SKIP 'no se detecta Docker ni Podman'
        fi
        return
    fi

    local names
    if [ "$tool" = docker ]; then
        names=$(timeout 15 docker ps -q 2>/dev/null)
    else
        names=$(timeout 15 podman ps -q 2>/dev/null)
    fi

    if [ -n "$names" ]; then
        local c
        for c in $names; do
            local flag
            if [ "$tool" = docker ]; then
                flag=$(timeout 10 docker inspect -f '{{.Name}} {{.HostConfig.Privileged}}' "$c" 2>/dev/null)
            else
                flag=$(timeout 10 podman inspect -f '{{.Name}} {{.HostConfig.Privileged}}' "$c" 2>/dev/null)
            fi
            case "$flag" in
                *' true') priv+="${flag% true} "; ev "$flag" ;;
            esac
        done
    fi

    if [ -n "$sock_issue" ]; then
        emit "$id" FAIL "$sock_issue"
    elif [ -n "$priv" ]; then
        emit "$id" WARN "contenedores privilegiados: ${priv% }"
    else
        emit "$id" PASS 'sin contenedores privilegiados ni socket de Docker expuesto'
    fi
}

register_check \
    'SVC-06' medium 'Auditoría del kernel (auditd)' check_svc_06 \
    'auditd registra ejecuciones, cambios de identidad y accesos a ficheros sensibles. Es clave para investigar un incidente después de que ocurra.' \
    $'Instala y activa auditd:\n  Debian/Ubuntu: sudo apt install auditd && sudo systemctl enable --now auditd\n  RHEL/SUSE:     sudo dnf install audit && sudo systemctl enable --now auditd\n  Arch:          sudo pacman -S audit && sudo systemctl enable --now auditd\nAñade reglas en /etc/audit/rules.d/.'

check_svc_06() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: la auditoría del kernel depende del host'
        return
    fi
    if ! have auditctl && ! have auditd; then
        emit "$id" INFO 'auditd no está instalado'
        return
    fi
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi

    if unit_active auditd; then
        emit "$id" PASS 'auditd está activo'
    else
        emit "$id" WARN 'auditd está instalado pero no activo'
    fi
}

register_check \
    'SVC-07' high 'Configuración del servidor SSH' check_svc_07 \
    'Revisa las directivas de sshd que permiten acceso de root, autenticación por contraseña, cuentas vacías o reenvío de X11.' \
    $'Endurece /etc/ssh/sshd_config (o un drop-in en /etc/ssh/sshd_config.d/):\n  PermitRootLogin no\n  PasswordAuthentication no\n  PermitEmptyPasswords no\n  X11Forwarding no\n  MaxAuthTries 3\nDespués valida y recarga:\n  sudo sshd -t && sudo systemctl reload sshd'

check_svc_07() {
    local id=$CURRENT_ID
    local cfg=/etc/ssh/sshd_config

    if [ ! -f "$cfg" ]; then
        emit "$id" INFO 'OpenSSH no está instalado'
        return
    fi

    local eff
    eff=$(_sshd_effective)
    if [ -z "$eff" ]; then
        emit "$id" SKIP 'no se pudo leer la configuración de sshd'
        return
    fi

    getv() {
        local key=$1 val
        val=$(printf '%s\n' "$eff" | awk -v k="$key" 'tolower($1) == tolower(k) { print tolower($2); exit }')
        if [ -z "$val" ]; then
            # Valores por defecto de OpenSSH cuando la directiva no aparece.
            case "$key" in
                PermitRootLogin) val='prohibit-password' ;;
                PasswordAuthentication) val='yes' ;;
                PermitEmptyPasswords) val='no' ;;
                X11Forwarding) val='no' ;;
                PermitUserEnvironment) val='no' ;;
                MaxAuthTries) val='6' ;;
                Protocol) val='2' ;;
            esac
        fi
        printf '%s' "$val"
    }

    local issues='' warns=0 fails=0
    local v

    v=$(getv PermitRootLogin)
    case "$v" in
        yes) issues+="PermitRootLogin=yes · "; fails=$(( fails + 1 )) ;;
        prohibit-password|without-password) issues+="PermitRootLogin=$v · "; warns=$(( warns + 1 )) ;;
    esac

    v=$(getv PasswordAuthentication)
    if [ "$v" = 'yes' ]; then
        issues+="PasswordAuthentication=yes · "
        warns=$(( warns + 1 ))
    fi

    v=$(getv PermitEmptyPasswords)
    if [ "$v" = 'yes' ]; then
        issues+="PermitEmptyPasswords=yes · "
        fails=$(( fails + 1 ))
    fi

    v=$(getv X11Forwarding)
    if [ "$v" = 'yes' ]; then
        issues+="X11Forwarding=yes · "
        warns=$(( warns + 1 ))
    fi

    v=$(getv PermitUserEnvironment)
    if [ "$v" = 'yes' ]; then
        issues+="PermitUserEnvironment=yes · "
        warns=$(( warns + 1 ))
    fi

    v=$(getv MaxAuthTries)
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 4 ]; then
        issues+="MaxAuthTries=$v · "
        warns=$(( warns + 1 ))
    fi

    v=$(getv Protocol)
    if [ "$v" = '1' ]; then
        issues+="Protocol=1 · "
        fails=$(( fails + 1 ))
    fi

    local detail="${issues% · }"
    [ -z "$detail" ] && detail='sin directivas débiles conocidas'

    if [ "$fails" -gt 0 ]; then
        emit "$id" FAIL "$detail"
    elif [ "$warns" -gt 0 ]; then
        emit "$id" WARN "$detail"
    else
        emit "$id" PASS "$detail"
    fi

    local key
    for key in PermitRootLogin PasswordAuthentication PermitEmptyPasswords X11Forwarding MaxAuthTries; do
        v=$(getv "$key")
        [ -n "$v" ] && ev "$key $v"
    done
}

register_check \
    'SVC-08' medium 'Persistencia de los logs de systemd' check_svc_08 \
    'Si journald guarda los logs solo en memoria, se pierden al reiniciar. Sin registros persistentes es imposible investigar un incidente ocurrido antes del último arranque.' \
    $'Guarda los logs en disco:\n  sudo mkdir -p /var/log/journal\n  sudo systemctl edit systemd-journald   # añade [Journal] Storage=persistent\n  sudo systemctl restart systemd-journald\nComprueba con: journalctl --disk-usage'

check_svc_08() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: los logs dependen del host'
        return
    fi
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi
    if ! unit_active systemd-journald; then
        emit "$id" SKIP 'systemd-journald no está activo'
        return
    fi

    local storage
    storage=$(grep -hE '^[[:space:]]*Storage[[:space:]]*=' \
        /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null \
        | tail -n 1 | cut -d= -f2 | tr -d '[:space:]')
    [ -n "$storage" ] || storage='auto'
    ev "Storage=$storage"

    case "${storage,,}" in
        persistent|auto)
            if [ -d /var/log/journal ]; then
                emit "$id" PASS "journald persiste los logs en /var/log/journal (Storage=$storage)"
            else
                emit "$id" WARN "journald podría perder los logs al reiniciar (Storage=$storage, sin /var/log/journal)"
            fi
            ;;
        volatile|none|*)
            emit "$id" WARN "journald no persiste los logs (Storage=$storage)"
            ;;
    esac
}
