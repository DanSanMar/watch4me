#!/usr/bin/env bash
# watch4me — checks de ficheros y permisos (FS)
# Licencia: GPLv3

# Comprueba un fichero contra una especificación simple:
#   ww        -> no escribible por grupo ni otros
#   nr        -> no legible por grupo ni otros
#   nro       -> no legible por otros (permite grupo, p. ej. shadow)
#   root      -> propietario root
#   self      -> propietario el usuario actual
#   NNN       -> modo exacto
#   maxNNN    -> modo sin bits adicionales (mode & ~NNN == 0)
_fs_check_spec() {
    local path=$1 spec=$2
    local stat_line mode owner uid
    stat_line=$(stat -c '%a %U %u' "$path" 2>/dev/null) || return 1
    mode=$(printf '%s' "$stat_line" | awk '{print $1}')
    owner=$(printf '%s' "$stat_line" | awk '{print $2}')
    uid=$(printf '%s' "$stat_line" | awk '{print $3}')

    [[ "$mode" =~ ^[0-7]+$ ]] || return 0
    local m=$(( 8#$mode ))
    local rule
    local IFS=','
    for rule in $spec; do
        case "$rule" in
            ww)
                if [ $(( m & 002 )) -ne 0 ] || [ $(( m & 020 )) -ne 0 ]; then
                    printf 'escribible por grupo u otros (modo %s)' "$mode"
                    return 2
                fi
                ;;
            nr)
                if [ $(( m & 004 )) -ne 0 ] || [ $(( m & 040 )) -ne 0 ]; then
                    printf 'legible por grupo u otros (modo %s)' "$mode"
                    return 2
                fi
                ;;
            nro)
                if [ $(( m & 004 )) -ne 0 ]; then
                    printf 'legible por otros (modo %s)' "$mode"
                    return 2
                fi
                ;;
            root)
                if [ "$owner" != 'root' ]; then
                    printf 'propietario %s (esperado root)' "$owner"
                    return 2
                fi
                ;;
            self)
                if [ "$uid" != "$(id -u)" ]; then
                    printf 'propietario %s (esperado usuario actual)' "$owner"
                    return 2
                fi
                ;;
            max[0-7][0-7][0-7])
                local max=${rule#max}
                local mm=$(( 8#$max ))
                if [ $(( m & ~mm & 0777 )) -ne 0 ]; then
                    printf 'modo %s demasiado permisivo' "$mode"
                    return 2
                fi
                ;;
            [0-7][0-7][0-7])
                if [ "$m" -ne $(( 8#$rule )) ]; then
                    printf 'modo %s (esperado %s)' "$mode" "$rule"
                    return 2
                fi
                ;;
        esac
    done
    return 0
}

register_check \
    'FS-01' low 'Particiones separadas' check_fs_01 \
    'Separar /tmp, /var, /var/log, /var/tmp, /home y /boot limita el impacto de un disco lleno y permite aplicar opciones de montaje específicas.' \
    $'Durante la instalación o con LVM crea volúmenes independientes para:\n  /tmp /var /var/log /var/tmp /home /boot\nEn sistemas existentes puedes mover /var/log o /tmp a un volumen nuevo y actualizar /etc/fstab.'

check_fs_01() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: las particiones las define el host'
        return
    fi
    if ! have findmnt; then
        emit "$id" SKIP 'findmnt no disponible'
        return
    fi

    local m mounted missing='' ok=0
    for m in /tmp /var /var/log /var/tmp /home /boot; do
        [ -d "$m" ] || continue
        local target
        target=$(findmnt -no TARGET --target "$m" 2>/dev/null)
        if [ "$target" = "$m" ]; then
            ok=$(( ok + 1 ))
        else
            missing+="$m "
        fi
    done

    if [ -n "$missing" ]; then
        emit "$id" WARN "sin partición propia: ${missing% }"
    else
        emit "$id" PASS "los ${ok} directorios revisados usan particiones separadas"
    fi
}

register_check \
    'FS-02' critical 'Permisos de las bases de usuarios' check_fs_02 \
    'passwd, group, shadow y gshadow definen identidades y contraseñas. Un permiso de escritura permite crear una cuenta root; uno de lectura expone hashes.' \
    $'Restaura propietario y permisos:\n  sudo chown root:root /etc/passwd /etc/group /etc/shadow /etc/gshadow\n  sudo chmod 644 /etc/passwd /etc/group\n  sudo chmod 640 /etc/shadow /etc/gshadow\nComprueba con: stat -c "%a %U:%G %n" /etc/{passwd,group,shadow,gshadow}'

check_fs_02() {
    local id=$CURRENT_ID
    local -a specs=(
        '/etc/passwd|ww,root,max644'
        '/etc/group|ww,root,max644'
        '/etc/shadow|ww,root,nro'
        '/etc/gshadow|ww,root,nro'
    )

    local spec path issue checked=0 bad=0
    for spec in "${specs[@]}"; do
        path=${spec%%|*}
        [ -e "$path" ] || continue
        checked=$(( checked + 1 ))
        issue=$(_fs_check_spec "$path" "${spec#*|}")
        if [ "$?" -eq 2 ]; then
            bad=$(( bad + 1 ))
            ev "$path: $issue"
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron las bases de usuarios'
        return
    fi
    if [ "$bad" -eq 0 ]; then
        emit "$id" PASS "los ${checked} ficheros de identidad tienen permisos correctos"
    else
        emit "$id" FAIL "$bad de $checked ficheros de identidad con permisos incorrectos"
    fi
}

register_check \
    'FS-03' high 'Binarios SUID/SGID fuera del sistema' check_fs_03 \
    'Un binario con SUID o SGID en /home, /tmp, /opt o /usr/local permite ejecutar con privilegios de otro usuario. Fuera de las rutas gestionadas por paquetes es sospechoso.' \
    $'Localiza el origen del binario y retira los bits especiales si no son necesarios:\n  sudo chmod u-s,g-s <fichero>\n  find /opt /usr/local /home -xdev -type f \\( -perm -4000 -o -perm -2000 \\)\nSi es legítimo, documenta para qué se usa.'

check_fs_03() {
    local id=$CURRENT_ID
    local out rc
    out=$(with_timeout "$(scan_timeout)" find /opt /usr/local /home /srv /tmp /var/tmp /dev/shm \
        -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null)
    rc=$?

    if [ "$rc" -eq 124 ] && [ -z "$out" ]; then
        emit "$id" SKIP 'escaneo interrumpido por timeout (prueba el perfil general)'
        return
    fi
    if [ -z "$out" ]; then
        emit "$id" PASS 'no hay binarios SUID/SGID en rutas no gestionadas'
        return
    fi

    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    emit "$id" WARN "$n binario(s) SUID/SGID fuera de las rutas del sistema"
    printf '%s\n' "$out" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
}

register_check \
    'FS-04' high 'Permisos de ficheros sensibles' check_fs_04 \
    'Verifica propietario y permisos de sudoers, sshd_config, crontab, hosts y claves SSH. Un permiso de escritura indebido permite escalar privilegios.' \
    $'Corrige propietario y permisos:\n  sudo chown root:root /etc/sudoers /etc/ssh/sshd_config /etc/crontab /etc/hosts\n  sudo chmod 440 /etc/sudoers\n  chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'

check_fs_04() {
    local id=$CURRENT_ID
    local -a specs=(
        '/etc/sudoers|ww,root,max440'
        '/etc/ssh/sshd_config|ww,root'
        '/etc/crontab|ww,root'
        '/etc/hosts|ww,root'
    )

    local home="${HOME:-}"
    if [ -n "$home" ] && [ -d "$home/.ssh" ]; then
        specs+=("$home/.ssh|ww,self,max700")
        if [ -f "$home/.ssh/authorized_keys" ]; then
            specs+=("$home/.ssh/authorized_keys|ww,self,max600")
        fi
        local key
        for key in "$home"/.ssh/id_*; do
            [ -f "$key" ] || continue
            case "$key" in
                *.pub) continue ;;
            esac
            specs+=("$key|ww,self,max600")
        done
    fi

    local bad=0 checked=0 spec path issue
    for spec in "${specs[@]}"; do
        path=${spec%%|*}
        [ -e "$path" ] || continue
        checked=$(( checked + 1 ))
        issue=$(_fs_check_spec "$path" "${spec#*|}")
        if [ "$?" -eq 2 ]; then
            bad=$(( bad + 1 ))
            ev "$path: $issue"
        fi
    done

    if [ -n "$home" ] && [ ! -d "$home/.ssh" ]; then
        ev "$home/.ssh no existe (sin claves SSH propias)"
    fi

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron ficheros sensibles que revisar'
        return
    fi

    if [ "$bad" -eq 0 ]; then
        emit "$id" PASS "$checked ficheros sensibles con permisos correctos"
    else
        emit "$id" FAIL "$bad de $checked ficheros sensibles con permisos incorrectos"
    fi
}

register_check \
    'FS-05' medium 'Ficheros escribibles por cualquier usuario' check_fs_05 \
    'Un fichero world-writable en /etc, /opt o /usr/local puede ser modificado por cualquier cuenta local para alterar la configuración o ejecutar código.' \
    $'Revisa cada fichero y retira el permiso de escritura a otros:\n  chmod o-w <fichero>\nSi debe ser escribible por un grupo concreto, usa permisos de grupo en lugar de world-writable.'

check_fs_05() {
    local id=$CURRENT_ID
    local out rc
    out=$(with_timeout "$(scan_timeout)" find /etc /opt /usr/local \
        -xdev -type f -perm -0002 -print 2>/dev/null)
    rc=$?

    if [ "$rc" -eq 124 ] && [ -z "$out" ]; then
        emit "$id" SKIP 'escaneo interrumpido por timeout (prueba el perfil general)'
        return
    fi
    if [ -z "$out" ]; then
        emit "$id" PASS 'no hay ficheros world-writable en /etc, /opt ni /usr/local'
        return
    fi

    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    emit "$id" WARN "$n fichero(s) escribibles por cualquier usuario"
    printf '%s\n' "$out" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
}

register_check \
    'FS-06' medium 'Ficheros sin propietario o grupo' check_fs_06 \
    'Un fichero huérfano (UID/GID inexistente) puede ser reclamado por una cuenta nueva con ese mismo UID. También indica usuarios o paquetes eliminados a medias.' \
    $'Localiza el UID/GID huérfano y reasigna el fichero:\n  find /etc /opt /usr/local /home -xdev \\( -nouser -o -nogroup \\) -ls\n  sudo chown root:root <fichero>\nSi el UID pertenece a LDAP/NIS, verifica que el servicio de identidad funciona.'

check_fs_06() {
    local id=$CURRENT_ID
    local out rc
    out=$(with_timeout "$(scan_timeout)" find /etc /opt /usr/local /srv /var/tmp \
        -xdev \( -nouser -o -nogroup \) -print 2>/dev/null)
    rc=$?

    if [ "$rc" -eq 124 ] && [ -z "$out" ]; then
        emit "$id" SKIP 'escaneo interrumpido por timeout (prueba el perfil general)'
        return
    fi
    if [ -z "$out" ]; then
        emit "$id" PASS 'no se encontraron ficheros huérfanos'
        return
    fi

    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    emit "$id" WARN "$n fichero(s) sin propietario o grupo válido"
    printf '%s\n' "$out" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
}

register_check \
    'FS-07' medium 'Sticky bit en directorios temporales' check_fs_07 \
    'Sin el sticky bit, cualquier usuario puede borrar o renombrar ficheros de otros en /tmp, /var/tmp y /dev/shm.' \
    $'Restaura el sticky bit:\n  sudo chmod 1777 /tmp /var/tmp /dev/shm\nComprueba con: stat -c "%a %n" /tmp /var/tmp /dev/shm'

check_fs_07() {
    local id=$CURRENT_ID
    local d st m bad='' checked=0
    for d in /tmp /var/tmp /dev/shm; do
        [ -d "$d" ] || continue
        st=$(stat -c '%a' "$d" 2>/dev/null) || continue
        checked=$(( checked + 1 ))
        if [[ "$st" =~ ^[0-7]+$ ]]; then
            m=$(( 8#$st ))
            if [ $(( m & 01000 )) -eq 0 ]; then
                bad+="$d($st) "
                ev "$d: sin sticky bit (modo $st)"
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron directorios temporales'
    elif [ -n "$bad" ]; then
        emit "$id" FAIL "sin sticky bit: ${bad% }"
    else
        emit "$id" PASS 'los directorios temporales tienen sticky bit'
    fi
}

register_check \
    'FS-08' medium 'Permisos de /root y /etc/skel' check_fs_08 \
    '/root contiene claves y configuración crítica: no debe ser accesible por otros usuarios. /etc/skel se copia a cada home nuevo y tampoco debe ser escribible.' \
    $'Restringe los permisos:\n  sudo chmod 700 /root\n  sudo chown root:root /root /etc/skel\n  sudo chmod 755 /etc/skel'

check_fs_08() {
    local id=$CURRENT_ID
    local bad='' checked=0
    local p st mode owner m
    for p in /root /etc/skel; do
        [ -e "$p" ] || continue
        st=$(stat -c '%a %U' "$p" 2>/dev/null) || continue
        checked=$(( checked + 1 ))
        mode=${st%% *}
        owner=${st#* }
        [[ "$mode" =~ ^[0-7]+$ ]] || continue
        m=$(( 8#$mode ))

        if [ "$p" = /root ]; then
            if [ "$owner" != 'root' ]; then
                bad+="$p:propietario=$owner "
                ev "$p: propietario $owner (esperado root)"
            fi
            if [ $(( m & 077 )) -ne 0 ]; then
                bad+="$p:modo=$mode "
                ev "$p: modo $mode (esperado 700 o más restrictivo)"
            fi
        else
            if [ "$owner" != 'root' ]; then
                bad+="$p:propietario=$owner "
                ev "$p: propietario $owner (esperado root)"
            fi
            if [ $(( m & 022 )) -ne 0 ]; then
                bad+="$p:modo=$mode "
                ev "$p: modo $mode (escribible por grupo u otros)"
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron /root ni /etc/skel'
    elif [ -n "$bad" ]; then
        emit "$id" WARN "permisos incorrectos: ${bad% }"
    else
        emit "$id" PASS '/root y /etc/skel tienen permisos correctos'
    fi
}

register_check \
    'FS-09' high 'Ficheros de confianza heredados' check_fs_09 \
    'hosts.equiv, .rhosts y .netrc permiten autenticación sin contraseña o guardan credenciales en texto plano. .forward puede desviar correo de forma silenciosa.' \
    $'Elimina los ficheros heredados que no uses:\n  sudo rm -f /etc/hosts.equiv /etc/ssh/shosts.equiv\n  rm -f ~/.rhosts ~/.netrc ~/.forward\nSi necesitas .netrc, protégelo con chmod 600 y valora un gestor de secretos.'

check_fs_09() {
    local id=$CURRENT_ID
    local bad='' checked=0

    local f
    for f in /etc/hosts.equiv /etc/ssh/shosts.equiv; do
        [ -e "$f" ] || continue
        checked=$(( checked + 1 ))
        if [ -s "$f" ] && grep -q '[^[:space:]]' "$f" 2>/dev/null; then
            bad+="$f "
            ev "$f contiene reglas de confianza"
        fi
    done

    local u home
    local -a homes=()
    local -A hseen=()
    while IFS= read -r u; do
        home=$(user_home "$u")
        if [ -n "$home" ] && [ -d "$home" ] && [ -z "${hseen[$home]:-}" ]; then
            hseen[$home]=1
            homes+=("$home")
        fi
    done < <(interactive_users)
    if [ -d /root ] && [ -z "${hseen[/root]:-}" ]; then
        homes+=(/root)
    fi

    local h
    for h in "${homes[@]}"; do
        [ -r "$h" ] || continue
        if [ -e "$h/.rhosts" ]; then
            checked=$(( checked + 1 ))
            bad+="$h/.rhosts "
            ev "$h/.rhosts permite confianza remota"
        fi
        if [ -e "$h/.netrc" ]; then
            checked=$(( checked + 1 ))
            local mode
            mode=$(stat -c '%a' "$h/.netrc" 2>/dev/null)
            bad+="$h/.netrc "
            ev "$h/.netrc guarda credenciales (modo ${mode:-?})"
        fi
        if [ -e "$h/.forward" ]; then
            checked=$(( checked + 1 ))
            bad+="$h/.forward "
            ev "$h/.forward redirige correo"
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" PASS 'no se encontraron ficheros de confianza heredados'
    else
        emit "$id" WARN "ficheros de confianza encontrados: ${bad% }"
    fi
}

register_check \
    'FS-10' medium 'Permisos de los logs del sistema' check_fs_10 \
    'Un log escribible por otros permite borrar huellas o inyectar entradas falsas. Los registros deben ser de root y solo legibles por los grupos autorizados.' \
    $'Corrige los permisos de /var/log:\n  sudo chown -R root:root /var/log\n  sudo chmod -R o-w /var/log\nRevisa si algún servicio necesita un grupo concreto (por ejemplo adm o systemd-journal).'

check_fs_10() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: los logs dependen del host'
        return
    fi
    [ -d /var/log ] || { emit "$id" SKIP 'no existe /var/log'; return; }

    local out rc
    out=$(with_timeout "$(scan_timeout)" find /var/log -xdev \( -type f -o -type d \) -perm -0002 -print 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 124 ] && [ -z "$out" ]; then
        emit "$id" SKIP 'escaneo interrumpido por timeout (prueba el perfil general)'
        return
    fi
    if [ -z "$out" ]; then
        emit "$id" PASS 'ningún fichero o directorio de /var/log es world-writable'
        return
    fi

    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    emit "$id" WARN "$n elemento(s) de /var/log escribibles por cualquier usuario"
    printf '%s\n' "$out" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
}
