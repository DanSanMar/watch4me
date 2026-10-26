#!/usr/bin/env bash
# watch4me — checks de integridad (INT)
# Licencia: GPLv3

register_check \
    'INT-01' medium 'Monitorización de integridad de ficheros' check_int_01 \
    'AIDE o Tripwire guardan una base de datos con el hash de los ficheros críticos. Sin ella, un binario o una configuración modificada puede pasar desapercibido durante meses.' \
    $'Instala y configura un monitor de integridad:\n  Debian/Ubuntu: sudo apt install aide aide-common && sudo aideinit\n  RHEL/SUSE:     sudo dnf install aide && sudo aide --init\n  Arch:          sudo pacman -S aide && sudo aide --init\nPrograma una comprobación periódica (aide.wrapper, aidecheck.timer o cron) y revisa los informes.'

check_int_01() {
    local id=$CURRENT_ID
    local tool='' db=''

    if have aide; then
        tool='AIDE'
        local c
        for c in /var/lib/aide/aide.db /var/lib/aide/aide.db.gz /var/lib/aide/aide.db.new \
                 /var/lib/aide/aide.db.new.gz; do
            [ -e "$c" ] && { db=$c; break; }
        done
    elif have tripwire || have twadmin; then
        tool='Tripwire'
        local c
        for c in /var/lib/tripwire/*.twd /var/lib/tripwire/*.twd.gz; do
            [ -e "$c" ] && { db=$c; break; }
        done
    fi

    if [ -z "$tool" ]; then
        emit "$id" WARN 'no se detecta AIDE ni Tripwire: no hay monitorización de integridad'
        return
    fi

    if [ -n "$db" ]; then
        ev "base de datos: $db"
        emit "$id" PASS "$tool instalado con base de datos de integridad"
    else
        emit "$id" WARN "$tool instalado pero sin base de datos inicializada"
    fi
}

register_check \
    'INT-02' high 'Verificación de paquetes instalados' check_int_02 \
    'Compara los ficheros instalados con los hashes del gestor de paquetes. Detecta binarios alterados o sustituidos tras la instalación. Requiere privilegios y puede tardar: forma parte de los perfiles General y Servidor.' \
    $'Revisa los ficheros señalados y reinstala el paquete afectado:\n  Arch:   sudo pacman -Qkk <paquete> && sudo pacman -S <paquete>\n  Debian: sudo debsums -s && sudo apt install --reinstall <paquete>\n  RHEL:   sudo rpm -Va && sudo dnf reinstall <paquete>\nSi la alteración no la has hecho tú, investiga el sistema antes de reinstalar.'

check_int_02() {
    local id=$CURRENT_ID
    if [ "$PKG_MGR" != 'pacman' ] && [ "$PKG_MGR" != 'apt' ] && [ "$PKG_MGR" != 'dnf' ] && [ "$PKG_MGR" != 'zypper' ]; then
        emit "$id" SKIP "gestor de paquetes no soportado (${DISTRO_FAMILY:-desconocido})"
        return
    fi

    case "$PKG_MGR" in
        pacman)
            if ! have pacman; then
                emit "$id" SKIP 'pacman no disponible'
                return
            fi
            ;;
        apt)
            if ! have debsums; then
                emit "$id" SKIP 'debsums no está instalado (sudo apt install debsums)'
                return
            fi
            ;;
        dnf|zypper)
            if ! have rpm; then
                emit "$id" SKIP 'rpm no disponible'
                return
            fi
            ;;
    esac

    if ! is_root && ! sudo_ok; then
        emit "$id" SKIP 'la verificación de paquetes requiere privilegios (usa --sudo)'
        return
    fi

    local raw rc=0 issues='' n=0

    case "$PKG_MGR" in
        pacman)
            if is_root; then
                raw=$(timeout 120 pacman -Qkk 2>&1) || rc=$?
            else
                raw=$(sudo -n timeout 120 pacman -Qkk 2>&1) || rc=$?
            fi
            issues=$(printf '%s\n' "$raw" | grep -E 'warning: .*\((Checksum|Size|File type|Missing file|Permissions?|Owner|Group) mismatch\)' || true)
            ;;
        apt)
            if is_root; then
                raw=$(timeout 120 debsums -s 2>&1) || rc=$?
            else
                raw=$(sudo -n timeout 120 debsums -s 2>&1) || rc=$?
            fi
            issues=$(printf '%s\n' "$raw" | grep -v '^[[:space:]]*$' || true)
            ;;
        dnf|zypper)
            if is_root; then
                raw=$(timeout 120 rpm -Va 2>&1) || rc=$?
            else
                raw=$(sudo -n timeout 120 rpm -Va 2>&1) || rc=$?
            fi
            # Solo cambios de contenido/tamaño/tipo y ficheros ausentes; se
            # excluyen los ficheros de configuración, que cambian a propósito.
            issues=$(printf '%s\n' "$raw" | awk '
                length($0) > 10 {
                    attrs = substr($0, 1, 9)
                    tipo = ($2 ~ /^[a-z]$/) ? $2 : ""
                    if ((attrs ~ /5/ || attrs ~ /S/ || attrs ~ /missing/) && tipo != "c") print
                }' || true)
            ;;
    esac

    if [ -z "$raw" ] && [ "$rc" -ne 0 ]; then
        emit "$id" SKIP 'el gestor de paquetes no devolvió información (¿permisos o timeout?)'
        return
    fi

    if [ -z "$issues" ]; then
        emit "$id" PASS 'los ficheros de los paquetes coinciden con la base de datos'
        return
    fi

    n=$(printf '%s\n' "$issues" | grep -c . || true)
    emit "$id" WARN "$n fichero(s) alterados o ausentes según $PKG_MGR"
    printf '%s\n' "$issues" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$(clip "$line" 220)"
    done
}

register_check \
    'INT-03' high 'Permisos de cron y at' check_int_03 \
    'Los ficheros y directorios de cron y at ejecutan comandos con los privilegios de su propietario. Si son escribibles por otros usuarios, cualquiera puede programar una tarea como root.' \
    $'Restaura propietario y permisos:\n  sudo chown -R root:root /etc/crontab /etc/cron.d /etc/cron.* /var/spool/cron /var/spool/at\n  sudo chmod 644 /etc/crontab /etc/cron.d/*\n  sudo chmod 700 /var/spool/cron /var/spool/at\nRestringe quién puede usar cron creando /etc/cron.allow con las cuentas autorizadas.'

check_int_03() {
    local id=$CURRENT_ID
    local -a paths=(
        /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily
        /etc/cron.weekly /etc/cron.monthly /var/spool/cron
        /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs
        /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny
    )

    local cron_present=0
    if have crond || have cron || unit_active cronie || unit_active cron || unit_active crond; then
        cron_present=1
    fi

    local p st mode owner m bad='' checked=0 missing_stat=0
    for p in "${paths[@]}"; do
        [ -e "$p" ] || continue
        checked=$(( checked + 1 ))
        st=$(stat -c '%a %U' "$p" 2>/dev/null) \
            || st=$(as_root stat -c '%a %U' "$p" 2>/dev/null) \
            || { missing_stat=$(( missing_stat + 1 )); continue; }
        mode=${st%% *}
        owner=${st#* }
        [[ "$mode" =~ ^[0-7]+$ ]] || continue
        m=$(( 8#$mode ))

        if [ "$owner" != 'root' ]; then
            bad+="$p:propietario=$owner "
            ev "$p: propietario $owner (esperado root)"
        fi

        if [ -d "$p" ]; then
            if [ $(( m & 002 )) -ne 0 ]; then
                bad+="$p:modo=$mode "
                ev "$p: directorio escribible por otros (modo $mode)"
            fi
        else
            if [ $(( m & 022 )) -ne 0 ]; then
                bad+="$p:modo=$mode "
                ev "$p: fichero escribible por grupo u otros (modo $mode)"
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        if [ "$cron_present" -eq 1 ]; then
            emit "$id" WARN 'cron está activo pero no se encontraron sus directorios de configuración'
        else
            emit "$id" INFO 'cron y at no están instalados'
        fi
        return
    fi

    if [ "$missing_stat" -gt 0 ] && [ -z "$bad" ]; then
        emit "$id" SKIP "no se pudieron leer $missing_stat ruta(s) de cron/at (usa --sudo)"
        return
    fi

    if [ -n "$bad" ]; then
        emit "$id" FAIL "permisos incorrectos en cron/at: ${bad% }"
        return
    fi

    if [ "$cron_present" -eq 1 ] && [ ! -e /etc/cron.allow ]; then
        emit "$id" WARN 'permisos correctos, pero no existe /etc/cron.allow: cualquier usuario puede programar tareas'
        return
    fi

    emit "$id" PASS "los ${checked} elementos de cron/at revisados tienen permisos correctos"
}

register_check \
    'INT-04' high 'Unidades systemd con ejecutables en rutas escribibles' check_int_04 \
    'Un servicio que ejecuta un binario desde /tmp, /home o una ruta escribible por otros permite persistencia y escalada. Los ejecutables de systemd deben vivir en rutas administradas por root.' \
    $'Mueve el ejecutable a /usr/local/bin (propiedad root) y actualiza la unidad:\n  sudo install -o root -g root -m 755 ./servicio /usr/local/bin/servicio\n  sudo systemctl daemon-reload\nRevisa la unidad con: systemctl cat <unidad>'

check_int_04() {
    local id=$CURRENT_ID
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi

    local -a dirs=(/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system)
    local d
    local -a existing=()
    for d in "${dirs[@]}"; do
        [ -d "$d" ] && existing+=("$d")
    done

    if [ "${#existing[@]}" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron directorios de unidades systemd'
        return
    fi

    local listing
    listing=$(with_timeout "$(scan_timeout)" find "${existing[@]}" -maxdepth 2 -type f \
        \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.path' \) 2>/dev/null)

    if [ -z "$listing" ]; then
        emit "$id" PASS 'no se encontraron unidades que revisar'
        return
    fi

    local -A seen=()
    local f line val cmd bad='' n=0 checked=0
    local -a temps=(/tmp /var/tmp /dev/shm /run/user /var/run/user /home)

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in
                ExecStart=*|ExecStop=*|ExecReload=*) ;;
                *) continue ;;
            esac
            val=${line#*=}
            val=$(printf '%s' "$val" | sed -E 's/^[[:space:]]*[-@:+!]*//')
            cmd=${val%%[[:space:]]*}
            cmd=${cmd#\"}
            cmd=${cmd%\"}
            case "$cmd" in
                /*) ;;
                *) continue ;;
            esac
            checked=$(( checked + 1 ))
            [ -n "${seen[$cmd]:-}" ] && continue

            local suspicious=''
            local t
            for t in "${temps[@]}"; do
                if under_path "$cmd" "$t"; then
                    suspicious="ruta temporal o de usuario"
                    break
                fi
            done
            if [ -z "$suspicious" ] && [ -e "$cmd" ] && [ -w "$cmd" ] && ! is_root; then
                suspicious="ejecutable escribible por el usuario actual"
            fi

            if [ -n "$suspicious" ]; then
                seen[$cmd]=1
                n=$(( n + 1 ))
                bad+="$f -> $cmd ($suspicious) · "
                ev "$f: $line"
            fi
        done < "$f"
    done <<< "$listing"

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se pudo extraer ningún ejecutable de las unidades'
        return
    fi

    if [ "$n" -eq 0 ]; then
        emit "$id" PASS "las unidades revisadas ejecutan binarios desde rutas administradas"
    else
        emit "$id" FAIL "$n unidad(es) con ejecutables en rutas inseguras: ${bad% · }"
    fi
}

register_check \
    'INT-05' high 'Claves autorizadas de root' check_int_05 \
    '/root/.ssh/authorized_keys permite entrar como root sin contraseña. Debe existir solo si es imprescindible, con permisos 600 y propietario root; un permiso laxo permite añadir claves a otros usuarios.' \
    $'Revisa las claves autorizadas y elimina las que no reconozcas:\n  sudo cat /root/.ssh/authorized_keys\n  sudo chmod 700 /root/.ssh\n  sudo chmod 600 /root/.ssh/authorized_keys\n  sudo chown -R root:root /root/.ssh\nValora deshabilitar el login directo de root en sshd (PermitRootLogin no).'

check_int_05() {
    local id=$CURRENT_ID
    if ! is_root && ! sudo_ok; then
        emit "$id" SKIP 'no se puede inspeccionar /root sin privilegios (usa --sudo)'
        return
    fi

    local dir=/root/.ssh ak=/root/.ssh/authorized_keys
    if ! as_root test -d "$dir" 2>/dev/null; then
        emit "$id" PASS 'root no tiene directorio ~/.ssh'
        return
    fi

    local dst st mode owner m bad=''
    dst=$(as_root stat -c '%a %U' "$dir" 2>/dev/null)
    mode=${dst%% *}
    owner=${dst#* }
    if [[ "$mode" =~ ^[0-7]+$ ]]; then
        m=$(( 8#$mode ))
        if [ $(( m & 077 )) -ne 0 ]; then
            bad+="$dir:modo=$mode "
            ev "$dir: modo $mode (esperado 700)"
        fi
    fi
    [ "$owner" != 'root' ] && { bad+="$dir:propietario=$owner "; ev "$dir: propietario $owner (esperado root)"; }

    if ! as_root test -e "$ak" 2>/dev/null; then
        if [ -n "$bad" ]; then
            emit "$id" WARN "/root/.ssh con permisos débiles: ${bad% }"
        else
            emit "$id" PASS 'root no tiene claves autorizadas'
        fi
        return
    fi

    st=$(as_root stat -c '%a %U' "$ak" 2>/dev/null)
    mode=${st%% *}
    owner=${st#* }
    ev "$ak: modo ${mode:-?} propietario ${owner:-?}"
    if [[ "$mode" =~ ^[0-7]+$ ]]; then
        m=$(( 8#$mode ))
        if [ $(( m & 077 )) -ne 0 ]; then
            bad+="$ak:modo=$mode "
            ev "$ak: modo $mode (esperado 600)"
        fi
    fi
    [ "$owner" != 'root' ] && { bad+="$ak:propietario=$owner "; ev "$ak: propietario $owner (esperado root)"; }

    local nkeys=0
    nkeys=$(as_root grep -cvE '^[[:space:]]*(#|$)' "$ak" 2>/dev/null || true)
    [[ "$nkeys" =~ ^[0-9]+$ ]] || nkeys=0
    ev "$nkeys clave(s) autorizadas"

    if [ -n "$bad" ]; then
        emit "$id" WARN "$nkeys clave(s) de root con permisos débiles: ${bad% }"
    elif [ "$nkeys" -gt 0 ]; then
        emit "$id" PASS "root tiene $nkeys clave(s) autorizadas con permisos correctos"
    else
        emit "$id" PASS 'authorized_keys de root existe pero está vacío'
    fi
}

register_check \
    'INT-06' high 'Capacidades de ficheros' check_int_06 \
    'Las capacidades POSIX otorgan privilegios concretos a un binario sin necesidad de SUID. Capacidades como cap_setuid o cap_sys_admin equivalen a root y deben estar justificadas.' \
    $'Revisa cada binario con capacidades:\n  sudo getcap -r /usr /opt /usr/local\nElimina las que no sean imprescindibles:\n  sudo setcap -r <fichero>\nDocumenta las que necesites (por ejemplo cap_net_raw en ping o cap_net_bind_service en un servidor web).'

check_int_06() {
    local id=$CURRENT_ID
    if ! have getcap; then
        emit "$id" SKIP 'getcap no está instalado (paquete libcap)'
        return
    fi

    local -a dirs=()
    local -A seen_dir=()
    local d rd
    for d in /usr/bin /usr/sbin /bin /sbin /usr/local/bin /usr/local/sbin /opt; do
        [ -d "$d" ] || continue
        # /bin y /sbin suelen ser enlaces a /usr/bin y /usr/sbin.
        rd=$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")
        [ -n "${seen_dir[$rd]:-}" ] && continue
        seen_dir[$rd]=1
        dirs+=("$d")
    done
    if [ "${#dirs[@]}" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron directorios de binarios'
        return
    fi

    local out rc t
    t=$(scan_timeout)
    out=$(with_timeout "$t" getcap -r "${dirs[@]}" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 124 ]; then
        emit "$id" SKIP 'escaneo interrumpido por timeout (prueba el perfil general)'
        return
    fi
    if [ -z "$out" ]; then
        emit "$id" PASS 'ningún fichero tiene capacidades POSIX asignadas'
        return
    fi

    local dangerous=' cap_setuid cap_setgid cap_sys_admin cap_sys_ptrace cap_sys_module cap_dac_read_search cap_dac_override cap_chown cap_fowner cap_setfcap cap_mac_admin cap_mac_override cap_sys_rawio cap_sys_boot cap_audit_control cap_syslog '
    local safe=' cap_net_raw cap_net_bind_service cap_net_broadcast cap_ipc_lock cap_sys_nice cap_sys_time cap_wake_alarm cap_block_suspend cap_audit_read cap_bpf cap_perfmon cap_checkpoint_restore '
    local path caps bad='' risky='' n=0

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path=${line%% *}
        caps=${line#* }
        n=$(( n + 1 ))
        local hit=0 cap
        for cap in ${caps//,/ }; do
            cap=${cap%%=*}
            case "$dangerous" in
                *" $cap "*) hit=2; break ;;
            esac
            case "$safe" in
                *" $cap "*) ;;
                *) [ "$hit" -eq 0 ] && hit=1 ;;
            esac
        done

        # newuidmap/newgidmap usan cap_setuid/cap_setgid para los mapas de
        # user namespaces sin privilegios: son binarios estándar del sistema.
        case "$path" in
            /usr/bin/newuidmap|/usr/bin/newgidmap|/bin/newuidmap|/bin/newgidmap)
                if [ "$hit" -eq 2 ]; then
                    local onlymap=1
                    for cap in ${caps//,/ }; do
                        cap=${cap%%=*}
                        case "$cap" in
                            cap_setuid|cap_setgid) ;;
                            *) onlymap=0 ;;
                        esac
                    done
                    [ "$onlymap" -eq 1 ] && hit=0
                fi
                ;;
        esac
        if [ "$hit" -eq 2 ]; then
            bad+="$line · "
            ev "$line"
        elif [ "$hit" -eq 1 ]; then
            risky+="$line · "
            ev "$line"
        else
            ev "$line"
        fi
    done <<< "$out"

    if [ -n "$bad" ]; then
        emit "$id" FAIL "capacidades peligrosas: ${bad% · }"
    elif [ -n "$risky" ]; then
        emit "$id" WARN "capacidades poco habituales: ${risky% · }"
    elif [ "$n" -gt 0 ]; then
        emit "$id" PASS "$n binario(s) con capacidades habituales (red, tiempo o bloqueo)"
    else
        emit "$id" PASS 'ningún fichero tiene capacidades POSIX asignadas'
    fi
}

register_check \
    'INT-07' high 'Directorios escribibles en PATH' check_int_07 \
    'Si PATH incluye un directorio que el usuario puede escribir, cualquier proceso que confíe en él (incluido root) puede ejecutar un binario suplantado. Es una vía clásica de escalada.' \
    $'Elimina de PATH los directorios escribibles o inexistentes:\n  echo "$PATH" | tr ":" "\\n" | while read d; do [ -w "$d" ] && echo "escribible: $d"; done\nCorrige /etc/profile, /etc/environment, /etc/profile.d/*.sh y los perfiles de root. Usa rutas propiedad de root.'

check_int_07() {
    local id=$CURRENT_ID
    local -a all=()
    local -A sys_dir=()
    local -A seen=()

    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$d" in
            /*) ;;
            *) continue ;;
        esac
        [ -n "${seen[$d]:-}" ] || { seen[$d]=1; all+=("$d"); }
    done < <(printf '%s' "${PATH:-}" | tr ':' '\n')

    local -a pfiles=(
        /etc/environment /etc/profile /etc/bash.bashrc /etc/bashrc
        /root/.bashrc /root/.bash_profile /root/.profile /root/.zshrc
    )
    local f line val
    local -a globs=()
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && globs+=("$f")
    done

    local readable=0
    for f in "${pfiles[@]}"; do
        [ -r "$f" ] && readable=$(( readable + 1 ))
        [ -r "$f" ] || continue
        while IFS= read -r line; do
            [[ "$line" =~ (^|[[:space:]])(export[[:space:]]+)?PATH= ]] || continue
            val=${line#*PATH=}
            val=${val%%[[:space:]]*}
            val=${val#\"}; val=${val%\"}
            val=${val#\'}; val=${val%\'}
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                case "$d" in
                    /*) ;;
                    *) continue ;;
                esac
                sys_dir[$d]=1
                [ -n "${seen[$d]:-}" ] || { seen[$d]=1; all+=("$d"); }
            done < <(printf '%s' "$val" | tr ':' '\n')
        done < "$f"
    done
    for f in "${globs[@]}"; do
        readable=$(( readable + 1 ))
        while IFS= read -r line; do
            [[ "$line" =~ (^|[[:space:]])(export[[:space:]]+)?PATH= ]] || continue
            val=${line#*PATH=}
            val=${val%%[[:space:]]*}
            val=${val#\"}; val=${val%\"}
            val=${val#\'}; val=${val%\'}
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                case "$d" in
                    /*) ;;
                    *) continue ;;
                esac
                sys_dir[$d]=1
                [ -n "${seen[$d]:-}" ] || { seen[$d]=1; all+=("$d"); }
            done < <(printf '%s' "$val" | tr ':' '\n')
        done < "$f"
    done

    local home=${HOME:-}
    local bad='' warn='' checked=0 st mode m
    for d in "${all[@]}"; do
        checked=$(( checked + 1 ))
        local in_sys=0
        [ -n "${sys_dir[$d]:-}" ] && in_sys=1

        if [ ! -d "$d" ]; then
            if [ "$in_sys" -eq 1 ]; then
                warn+="$d(no existe) "
                ev "$d: no existe y aparece en un PATH del sistema"
            fi
            continue
        fi

        st=$(stat -c '%a' "$d" 2>/dev/null) || continue
        [[ "$st" =~ ^[0-7]+$ ]] || continue
        m=$(( 8#$st ))

        if [ $(( m & 002 )) -ne 0 ]; then
            bad+="$d(escribible por otros) "
            ev "$d: modo $st, escribible por otros"
            continue
        fi

        if [ -w "$d" ] && ! is_root; then
            if [ "$in_sys" -eq 1 ]; then
                bad+="$d(escribible por el usuario en PATH del sistema) "
                ev "$d: el usuario actual puede escribir en un PATH del sistema"
            elif [ -n "$home" ] && ! under_path "$d" "$home"; then
                warn+="$d(escribible por el usuario) "
                ev "$d: el usuario actual puede escribir en PATH fuera de su home"
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'PATH está vacío o no contiene rutas absolutas'
        return
    fi

    if [ -n "$bad" ]; then
        emit "$id" FAIL "directorios peligrosos en PATH: ${bad% }"
    elif [ -n "$warn" ]; then
        emit "$id" WARN "directorios a revisar en PATH: ${warn% }"
    elif [ "$readable" -eq 0 ]; then
        emit "$id" INFO 'solo se revisó el PATH actual: los perfiles del sistema no son legibles'
    else
        emit "$id" PASS "los ${checked} directorios de PATH revisados son rutas administradas"
    fi
}
