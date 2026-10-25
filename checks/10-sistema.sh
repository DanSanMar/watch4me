#!/usr/bin/env bash
# watch4me — checks de sistema (SYS)
# Licencia: GPLv3

register_check \
    'SYS-01' medium 'Sincronización del reloj' check_sys_01 \
    'Un reloj desincronizado invalida logs, certificados TLS, tickets Kerberos y marcas de tiempo forenses.' \
    $'Activa un cliente NTP y compruébalo:\n  Arch/Debian: sudo systemctl enable --now systemd-timesyncd\n  RHEL/SUSE:   sudo systemctl enable --now chronyd\n  timedatectl status\n  chronyc tracking'

check_sys_01() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: el reloj lo sincroniza el host'
        return
    fi

    local sync=''
    if have timedatectl; then
        sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [ "$sync" = 'yes' ]; then
            ev 'timedatectl: NTPSynchronized=yes'
            emit "$id" PASS 'reloj sincronizado por NTP'
            return
        fi
    fi

    if have chronyc; then
        local tracking
        tracking=$(with_timeout 5 chronyc -n tracking)
        if printf '%s' "$tracking" | grep -qi 'Leap status.*Normal'; then
            ev "$(printf '%s' "$tracking" | grep -i 'Leap status' | head -n 1)"
            emit "$id" PASS 'reloj sincronizado por chrony'
            return
        fi
    fi

    if have ntpq; then
        local peers
        peers=$(with_timeout 5 ntpq -pn)
        if printf '%s' "$peers" | grep -q '^\*'; then
            ev "$(printf '%s' "$peers" | grep '^\*' | head -n 1)"
            emit "$id" PASS 'reloj sincronizado por ntpd'
            return
        fi
    fi

    if [ "$sync" = 'no' ]; then
        ev "$(timedatectl status 2>/dev/null | head -n 8 | oneline)"
        emit "$id" WARN 'el reloj no está sincronizado (NTPSynchronized=no)'
        return
    fi

    if have timedatectl; then
        emit "$id" WARN 'no se pudo confirmar la sincronización del reloj'
    else
        emit "$id" SKIP 'no se detecta cliente NTP (timedatectl/chronyc/ntpq)'
    fi
}

register_check \
    'SYS-02' high 'Actualizaciones pendientes' check_sys_02 \
    'Cuenta las actualizaciones disponibles sin instalar nada. Un sistema sin parchear acumula vulnerabilidades conocidas y explotables.' \
    $'Actualiza el sistema con tu gestor de paquetes:\n  Arch:   sudo pacman -Syu\n  Debian: sudo apt update && sudo apt upgrade\n  RHEL:   sudo dnf upgrade\n  SUSE:   sudo zypper update'

check_sys_02() {
    local id=$CURRENT_ID
    if ! pkg_update_supported; then
        emit "$id" SKIP "gestor de paquetes no soportado (${DISTRO_FAMILY:-desconocido})"
        return
    fi

    local report count list note
    report=$(pkg_updates_report 2>/dev/null)
    count=$(printf '%s\n' "$report" | head -n 1)
    list=$(printf '%s\n' "$report" | tail -n +2)

    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        emit "$id" SKIP "no se pudo consultar el gestor de paquetes (${PKG_MGR:-?})"
        return
    fi

    note=''
    [ "$DISTRO_FAMILY" = arch ] && ! have checkupdates && note='; base de datos local sin refrescar'

    if [ "$count" -eq 0 ]; then
        emit "$id" PASS "sin actualizaciones pendientes (${PKG_MGR})"
        return
    fi

    local detail="$count actualizaciones pendientes (${PKG_MGR})${note}"
    if [ "$count" -ge 25 ]; then
        emit "$id" FAIL "$detail"
    else
        emit "$id" WARN "$detail"
    fi

    printf '%s\n' "$list" | head -n 12 | while IFS= read -r line; do
        [ -n "$line" ] && ev "$line"
    done
    [ "$count" -gt 12 ] && ev "... y $((count - 12)) más"
}

register_check \
    'SYS-03' medium 'Reinicio pendiente' check_sys_03 \
    'Detecta si el kernel o bibliotecas críticas se actualizaron pero el sistema sigue ejecutando versiones antiguas hasta el próximo arranque.' \
    $'Programa un reinicio en una ventana de mantenimiento:\n  sudo reboot\nAntes revisa que no haya sesiones activas ni servicios en curso.'

check_sys_03() {
    local id=$CURRENT_ID

    if [ -e /run/reboot-required ] || [ -e /var/run/reboot-required ]; then
        ev "$(cat /run/reboot-required /var/run/reboot-required 2>/dev/null | oneline)"
        emit "$id" WARN 'hay un reinicio pendiente (/run/reboot-required)'
        return
    fi

    if have needs-restarting; then
        timeout 20 needs-restarting -r >/dev/null 2>&1
        case $? in
            0) emit "$id" PASS 'no hay servicios que requieran reinicio'; return ;;
            1) emit "$id" WARN 'needs-restarting indica que se requiere reiniciar'; return ;;
        esac
    fi

    if have pacman; then
        local rel base kind pkg mapped
        rel=$(uname -r)
        base=$rel
        kind=linux
        case "$rel" in
            *-lts) kind=linux-lts; base=${rel%-lts} ;;
            *-zen) kind=linux-zen; base=${rel%-zen} ;;
            *-hardened) kind=linux-hardened; base=${rel%-hardened} ;;
        esac
        pkg=$(pacman -Q "$kind" 2>/dev/null | awk '{print $2}')
        if [ -n "$pkg" ]; then
            mapped=${pkg/.arch/-arch}
            mapped=${mapped/.zen/-zen}
            mapped=${mapped/.hardened/-hardened}
            if [ "$mapped" = "$base" ]; then
                emit "$id" PASS "el kernel en ejecución coincide con $kind instalado"
            else
                ev "kernel en ejecución: $rel"
                ev "paquete $kind instalado: $pkg"
                emit "$id" WARN "kernel actualizado pendiente de reinicio ($kind $pkg)"
            fi
            return
        fi
        if [ ! -d "/usr/lib/modules/$rel" ]; then
            emit "$id" WARN "no hay módulos para el kernel en ejecución ($rel)"
            return
        fi
    fi

    if [ -e /run/reboot-needed ] || [ -e /var/run/reboot-needed ]; then
        emit "$id" WARN 'hay un reinicio pendiente (/run/reboot-needed)'
        return
    fi

    emit "$id" SKIP 'no se puede determinar si hay un reinicio pendiente'
}

register_check \
    'SYS-04' high 'Parámetros sysctl de hardening' check_sys_04 \
    'Revisa los valores del kernel que limitan la exposición de información, el abuso de ptrace/BPF y la suplantación de red.' \
    $'Aplica los valores que falten en /etc/sysctl.d/90-watch4me.conf y recarga con:\n  sudo sysctl --system\nRevisa cada clave antes de aplicarla en equipos con funciones de router o contenedores.'

check_sys_04() {
    local id=$CURRENT_ID
    if ! have sysctl; then
        emit "$id" SKIP 'sysctl no disponible'
        return
    fi

    local -a specs=(
        'kernel.kptr_restrict|ge|1'
        'kernel.dmesg_restrict|ge|1'
        'kernel.unprivileged_bpf_disabled|ge|1'
        'kernel.yama.ptrace_scope|ge|1'
        'kernel.perf_event_paranoid|ge|2'
        'kernel.randomize_va_space|eq|2'
        'fs.protected_hardlinks|eq|1'
        'fs.protected_symlinks|eq|1'
        'fs.suid_dumpable|eq|0'
        'net.ipv4.tcp_syncookies|eq|1'
        'net.ipv4.conf.all.rp_filter|eq|1'
        'net.ipv4.conf.all.accept_redirects|eq|0'
        'net.ipv4.conf.all.send_redirects|eq|0'
        'net.ipv4.conf.all.accept_source_route|eq|0'
    )
    if [ -r /proc/sys/net/ipv6/conf/all/accept_redirects ]; then
        specs+=(
            'net.ipv6.conf.all.accept_redirects|eq|0'
            'net.ipv6.conf.all.accept_source_route|eq|0'
        )
    fi

    local checked=0 weak=0 spec key op want val bad=''
    for spec in "${specs[@]}"; do
        IFS='|' read -r key op want <<< "$spec"
        val=$(sysctl_val "$key")
        [ -n "$val" ] || continue
        checked=$(( checked + 1 ))

        local ok=0
        case "$op" in
            ge) [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge "$want" ] && ok=1 ;;
            le) [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -le "$want" ] && ok=1 ;;
            eq) [ "$val" = "$want" ] && ok=1 ;;
        esac

        if [ "$ok" -eq 0 ]; then
            weak=$(( weak + 1 ))
            bad+="${key}=${val} "
            ev "${key} = ${val}  (esperado ${op} ${want})"
        fi
    done

    if [ "$checked" -eq 0 ]; then
        emit "$id" SKIP 'no se pudo leer ningún parámetro sysctl'
        return
    fi

    if [ "$weak" -eq 0 ]; then
        emit "$id" PASS "los ${checked} parámetros revisados están correctos"
    else
        emit "$id" FAIL "$weak de $checked valores débiles: ${bad% }"
    fi
}

register_check \
    'SYS-05' medium 'Módulos de sistemas de ficheros innecesarios' check_sys_05 \
    'Los módulos de sistemas de ficheros poco usados amplían la superficie de ataque del kernel. Lo ideal es no cargarlos salvo necesidad.' \
    $'Bloquea los módulos que no uses en /etc/modprobe.d/99-watch4me.conf:\n  blacklist cramfs\n  blacklist freevxfs\n  blacklist jffs2\n  blacklist hfs\n  blacklist hfsplus\n  blacklist udf\nDespués ejecuta: sudo modprobe -r <módulo>'

check_sys_05() {
    local id=$CURRENT_ID
    if ! have lsmod; then
        emit "$id" SKIP 'lsmod no disponible'
        return
    fi

    local -a mods=(cramfs freevxfs jffs2 hfs hfsplus udf)
    local -a confs=(/etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf /run/modprobe.d/*.conf)
    local loaded
    loaded=$(lsmod | awk 'NR > 1 { print $1 }')

    local m loaded_list='' unblocked='' blocked_list=''
    for m in "${mods[@]}"; do
        printf '%s\n' "$loaded" | grep -qx "$m" || continue
        loaded_list+="$m "
        local blocked=0 f
        for f in "${confs[@]}"; do
            [ -r "$f" ] || continue
            if grep -Eq "^[[:space:]]*(blacklist[[:space:]]+$m|install[[:space:]]+$m[[:space:]]+/bin/(false|true))" "$f"; then
                blocked=1
            fi
        done
        if [ "$blocked" -eq 1 ]; then
            blocked_list+="$m "
        else
            unblocked+="$m "
        fi
    done

    if [ -z "$loaded_list" ]; then
        emit "$id" PASS 'ningún módulo de sistema de ficheros innecesario está cargado'
        return
    fi

    [ -n "$unblocked" ] && ev "cargados sin blacklist: ${unblocked% }"
    [ -n "$blocked_list" ] && ev "cargados pese a blacklist: ${blocked_list% }"
    emit "$id" WARN "módulos cargados: ${loaded_list% }"
}

register_check \
    'SYS-06' low 'Reloj del hardware en UTC' check_sys_06 \
    'Guardar la hora local en la CMOS complica el arranque dual y puede provocar saltos de hora. Lo recomendado es UTC.' \
    $'Cambia el reloj del hardware a UTC:\n  timedatectl set-local-rtc 0\n  sudo hwclock --systohc --utc'

check_sys_06() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: no gestiona el reloj del hardware'
        return
    fi
    if ! have timedatectl; then
        emit "$id" SKIP 'timedatectl no disponible'
        return
    fi
    local v
    v=$(timedatectl show -p LocalRTC --value 2>/dev/null)
    case "$v" in
        no) emit "$id" PASS 'el reloj del hardware está en UTC' ;;
        yes) emit "$id" WARN 'el reloj del hardware está en hora local (LocalRTC=yes)' ;;
        *) emit "$id" SKIP 'no se pudo leer la configuración del reloj' ;;
    esac
}

register_check \
    'SYS-07' medium 'Secure Boot' check_sys_07 \
    'Secure Boot impide cargar gestores de arranque y módulos firmados por terceros sin autorización. Solo aplica a sistemas UEFI.' \
    $'Comprueba el estado y, si procede, actívalo en la UEFI:\n  mokutil --sb-state\n  bootctl status\nTen en cuenta que algunos controladores propietarios requieren enrolar claves MOK.'

check_sys_07() {
    local id=$CURRENT_ID
    if [ ! -d /sys/firmware/efi ]; then
        emit "$id" INFO 'arranque BIOS/legacy: Secure Boot no aplica'
        return
    fi

    local state=''
    if have mokutil; then
        state=$(mokutil --sb-state 2>/dev/null)
    fi
    if [ -z "$state" ] && have bootctl; then
        state=$(bootctl status 2>/dev/null | grep -i 'secure boot' | head -n 1)
    fi
    if [ -z "$state" ]; then
        local var
        var=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n 1)
        if [ -n "$var" ] && [ -r "$var" ]; then
            local b
            b=$(od -An -tu1 -j4 -N1 "$var" 2>/dev/null | tr -d ' ')
            [ "$b" = '1' ] && state='SecureBoot enabled' || state='SecureBoot disabled'
        fi
    fi

    case "$state" in
        *[Ee]nabled*) emit "$id" PASS 'Secure Boot habilitado' ;;
        *[Dd]isabled*) emit "$id" WARN 'Secure Boot deshabilitado' ;;
        *) emit "$id" SKIP 'no se pudo determinar el estado de Secure Boot' ;;
    esac
}

register_check \
    'SYS-08' high 'Mitigaciones de vulnerabilidades de CPU' check_sys_08 \
    'Comprueba si el kernel ha aplicado mitigaciones para Spectre, Meltdown, MDS, L1TF y familias similares.' \
    $'Actualiza el kernel, el microcódigo y la UEFI:\n  Arch:   sudo pacman -Syu linux linux-firmware intel-ucode|amd-ucode\n  Debian: sudo apt update && sudo apt full-upgrade\n  RHEL:   sudo dnf update microcode_ctl\nDespués reinicia y revisa /sys/devices/system/cpu/vulnerabilities/.'

check_sys_08() {
    local id=$CURRENT_ID
    local dir=/sys/devices/system/cpu/vulnerabilities
    if [ ! -d "$dir" ]; then
        emit "$id" SKIP 'el kernel no expone información de vulnerabilidades'
        return
    fi

    local f total=0 vulnerable='' exact=0 unknown=''
    for f in "$dir"/*; do
        [ -r "$f" ] || continue
        total=$(( total + 1 ))
        local name val
        name=$(basename "$f")
        val=$(cat "$f" 2>/dev/null)
        ev "$name: $val"
        case "$val" in
            'Vulnerable') exact=$(( exact + 1 )); vulnerable+="$name " ;;
            *Vulnerable*) vulnerable+="$name " ;;
            Unknown*|unknown*) unknown+="$name " ;;
        esac
    done

    if [ "$total" -eq 0 ]; then
        emit "$id" SKIP 'no se encontraron indicadores de vulnerabilidades'
        return
    fi

    if [ "$exact" -gt 0 ]; then
        emit "$id" FAIL "sin mitigación: ${vulnerable% }"
    elif [ -n "$vulnerable" ]; then
        emit "$id" WARN "mitigación parcial o dependiente de microcódigo: ${vulnerable% }"
    elif [ -n "$unknown" ]; then
        emit "$id" WARN "estado desconocido: ${unknown% }"
    else
        emit "$id" PASS "las ${total} vulnerabilidades conocidas están mitigadas o no afectan"
    fi
}

register_check \
    'SYS-09' medium 'Opciones de montaje' check_sys_09 \
    'Comprueba que los directorios temporales y de usuarios no permiten ejecutar binarios, cambiar de dueño ni crear dispositivos.' \
    $'Añade las opciones que falten en /etc/fstab y remonta:\n  sudo mount -o remount /tmp\nEn systemd también puedes ajustar tmp.mount con: sudo systemctl edit tmp.mount'

check_sys_09() {
    local id=$CURRENT_ID
    if ! have findmnt; then
        emit "$id" SKIP 'findmnt no disponible'
        return
    fi

    local -a specs=(
        '/tmp|noexec,nosuid,nodev'
        '/var/tmp|noexec,nosuid,nodev'
        '/dev/shm|noexec,nosuid,nodev'
        '/home|nosuid,nodev'
        '/run|noexec,nosuid,nodev'
        '/boot|nosuid,nodev'
    )

    local spec mnt req target opts opt lacking='' notsep=''
    for spec in "${specs[@]}"; do
        IFS='|' read -r mnt req <<< "$spec"
        [ -d "$mnt" ] || continue
        target=$(findmnt -no TARGET --target "$mnt" 2>/dev/null)
        if [ -z "$target" ]; then
            lacking+="$mnt(no montado) "
            continue
        fi
        if [ "$target" != "$mnt" ]; then
            notsep+="$mnt "
            continue
        fi
        opts=$(findmnt -no OPTIONS --target "$mnt" 2>/dev/null)
        for opt in ${req//,/ }; do
            case ",$opts," in
                *",$opt,"*) ;;
                *) lacking+="$mnt:$opt " ;;
            esac
        done
        ev "$mnt -> $opts"
    done

    if [ -z "$lacking" ] && [ -z "$notsep" ]; then
        emit "$id" PASS 'todos los montajes revisados tienen las protecciones esperadas'
        return
    fi

    local detail=''
    [ -n "$lacking" ] && detail+="faltan opciones: ${lacking% }"
    if [ -n "$notsep" ]; then
        [ -n "$detail" ] && detail+='; '
        detail+="sin montaje propio (heredan /): ${notsep% }"
    fi

    if [ -n "$lacking" ]; then
        emit "$id" FAIL "$detail"
    else
        emit "$id" WARN "$detail"
    fi
}

register_check \
    'SYS-10' medium 'Integridad del kernel (taint)' check_sys_10 \
    'El flag tainted indica módulos propietarios, sin firma, out-of-tree, errores graves del kernel o bloqueos. Ayuda a detectar manipulación.' \
    $'Identifica el origen del taint:\n  cat /proc/sys/kernel/tainted\n  dmesg | grep -iE "taint|module verification|unsigned"\nElimina módulos propietarios o sin firma que no necesites y revisa los errores del kernel.'

check_sys_10() {
    local id=$CURRENT_ID
    local raw
    raw=$(cat /proc/sys/kernel/tainted 2>/dev/null)
    if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
        emit "$id" SKIP 'no se pudo leer /proc/sys/kernel/tainted'
        return
    fi
    if [ "$raw" -eq 0 ]; then
        emit "$id" PASS 'el kernel no está tainted'
        return
    fi

    local -a labels=(
        'módulo propietario' 'carga forzada de módulo' 'SMP inseguro' 'machine check'
        'página defectuosa' 'petición del usuario' 'die/oops' 'ACPI sobrescrito'
        'warning del kernel' 'módulo staging' 'workaround de firmware' 'módulo out-of-tree'
        'módulo sin firma' 'softlockup' 'livepatch' 'aux'
        'corrupción de página' 'kernel de prueba'
    )
    local n=$raw i=0 flags=''
    while [ "$n" -gt 0 ]; do
        if [ $(( n & 1 )) -ne 0 ]; then
            flags+="${labels[$i]:-bit $i} "
        fi
        n=$(( n >> 1 ))
        i=$(( i + 1 ))
    done
    ev "tainted=$raw"
    emit "$id" WARN "kernel tainted: ${flags% }"
}

register_check \
    'SYS-11' high 'Control de acceso obligatorio (AppArmor/SELinux)' check_sys_11 \
    'Comprueba si hay un módulo MAC activo y aplicando perfiles. Sin él, un servicio comprometido puede moverse libremente por el sistema.' \
    $'Arch:        sudo pacman -S apparmor && sudo systemctl enable --now apparmor\nDebian/Ubuntu: sudo apt install apparmor apparmor-utils\nRHEL/SUSE:   SELinux o AppArmor suelen venir activos; revisa /etc/selinux/config\nVerifica con: sudo aa-status   |   getenforce'

check_sys_11() {
    local id=$CURRENT_ID

    if [ -f /.dockerenv ] || { have systemd-detect-virt && systemd-detect-virt --quiet --container; }; then
        emit "$id" INFO 'contenedor detectado: el control de acceso lo aplica el host'
        return
    fi

    local aa_enabled=0 aa_profiles=0
    if [ -r /sys/module/apparmor/parameters/enabled ] \
        && grep -q '^Y' /sys/module/apparmor/parameters/enabled 2>/dev/null; then
        aa_enabled=1
        if [ -r /sys/kernel/security/apparmor/profiles ]; then
            aa_profiles=$(grep -c . /sys/kernel/security/apparmor/profiles 2>/dev/null || true)
        fi
    fi

    if [ "$aa_enabled" -eq 1 ]; then
        if [ "$aa_profiles" -gt 0 ]; then
            emit "$id" PASS "AppArmor activo con ${aa_profiles} perfiles"
        else
            emit "$id" WARN 'AppArmor habilitado pero sin perfiles cargados'
        fi
        return
    fi

    if have getenforce; then
        local mode
        mode=$(getenforce 2>/dev/null)
        case "$mode" in
            Enforcing) emit "$id" PASS 'SELinux en modo Enforcing' ;;
            Permissive) emit "$id" WARN 'SELinux en modo Permissive (solo registra, no bloquea)' ;;
            *) emit "$id" FAIL "SELinux en modo ${mode:-desconocido}" ;;
        esac
        return
    fi

    emit "$id" FAIL 'no se detecta AppArmor ni SELinux activos'
}

register_check \
    'SYS-12' low 'Visibilidad de procesos (/proc)' check_sys_12 \
    'hidepid oculta los procesos de otros usuarios en /proc y reduce la fuga de información entre cuentas.' \
    $'Añade hidepid=2 a /proc en /etc/fstab:\n  proc /proc proc defaults,hidepid=2 0 0\nY remonta: sudo mount -o remount /proc\nEn systemd puedes usar proc-hidepid.mount.'

check_sys_12() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: /proc lo controla el host'
        return
    fi
    if ! have findmnt; then
        emit "$id" SKIP 'findmnt no disponible'
        return
    fi
    local opts
    opts=$(findmnt -no OPTIONS --target /proc 2>/dev/null)
    ev "/proc -> $opts"
    case ",$opts," in
        *',hidepid=2,'*|*',hidepid=invisible,'*)
            emit "$id" PASS '/proc usa hidepid=2'
            ;;
        *',hidepid=1,'*)
            emit "$id" WARN '/proc usa hidepid=1 (ocultación parcial)'
            ;;
        *)
            emit "$id" WARN '/proc no usa hidepid: los procesos de otros usuarios son visibles'
            ;;
    esac
}

register_check \
    'SYS-13' medium 'Cifrado del disco del sistema' check_sys_13 \
    'Sin cifrado, quien acceda físicamente al disco (robo, pérdida o retirada del equipo) puede leer todos los datos sin necesidad de credenciales. Es clave en portátiles y equipos de casa.' \
    $'Cifra el disco durante la instalación o, si ya está instalado, valora LUKS con una copia de seguridad previa:\n  sudo cryptsetup luksFormat /dev/sdXN\n  sudo cryptsetup open /dev/sdXN root\n  sudo mkfs.ext4 /dev/mapper/root\nEn escritorios también puedes usar el cifrado de disco que ofrece el instalador de tu distribución.'

check_sys_13() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: el cifrado lo gestiona el host'
        return
    fi
    if ! have findmnt; then
        emit "$id" SKIP 'findmnt no disponible'
        return
    fi

    local src dev
    src=$(findmnt -no SOURCE / 2>/dev/null)
    if [ -z "$src" ]; then
        emit "$id" SKIP 'no se pudo identificar el dispositivo raíz'
        return
    fi
    case "$src" in
        overlay|tmpfs|none|ramfs|rootfs)
            emit "$id" INFO "sistema de ficheros especial ($src): no aplica el cifrado de disco"
            return
            ;;
        *:*)
            emit "$id" INFO "el sistema raíz es remoto ($src): el cifrado corresponde al servidor"
            return
            ;;
    esac

    if ! have lsblk; then
        emit "$id" SKIP 'lsblk no disponible'
        return
    fi

    # findmnt puede devolver /dev/nvme0n1p2[/@] para un subvolumen btrfs.
    dev=${src%%[*}
    local chain
    chain=$(lsblk -s -no NAME,TYPE,FSTYPE -- "$dev" 2>/dev/null)
    if [ -z "$chain" ]; then
        emit "$id" SKIP "no se pudo analizar el dispositivo raíz ($dev)"
        return
    fi

    ev "$(printf '%s\n' "$chain" | oneline)"
    if printf '%s\n' "$chain" | grep -qiE '(^|[[:space:]])crypt([[:space:]]|$)|crypt_LUKS|dm-crypt'; then
        emit "$id" PASS "el sistema raíz ($dev) está sobre un dispositivo cifrado"
    else
        emit "$id" WARN "el sistema raíz ($dev) no parece cifrado: un acceso físico permite leer los datos"
    fi
}

register_check \
    'SYS-14' medium 'Bloqueo automático de pantalla' check_sys_14 \
    'Una sesión desatendida y sin bloqueo deja el escritorio, el correo y los datos abiertos a cualquiera que pase por delante. El bloqueo por inactividad es la medida mínima en un cliente o PC doméstico.' \
    $'Activa el bloqueo automático en tu escritorio:\n  GNOME:   Configuración → Privacidad → Bloqueo de pantalla\n  KDE:     Configuración → Seguridad → Bloqueo de pantalla\n  XFCE:    Configuración → Ahorro de energía → Bloquear pantalla\nTambién puedes usar: gsettings set org.gnome.desktop.screensaver lock-enabled true'

check_sys_14() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: no hay escritorio que bloquear'
        return
    fi

    local found=0 issues='' schema val idle secs
    if have gsettings; then
        for schema in org.gnome.desktop.screensaver org.cinnamon.desktop.screensaver org.mate.screensaver; do
            val=$(gsettings get "$schema" lock-enabled 2>/dev/null) || continue
            [ -n "$val" ] || continue
            found=1

            idle=''
            case "$schema" in
                org.gnome.desktop.screensaver)
                    idle=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null) ;;
                org.cinnamon.desktop.screensaver)
                    idle=$(gsettings get org.cinnamon.desktop.session idle-delay 2>/dev/null) ;;
                org.mate.screensaver)
                    idle=$(gsettings get org.mate.session idle-delay 2>/dev/null) ;;
            esac
            secs=''
            [[ "$idle" =~ ([0-9]+) ]] && secs=${BASH_REMATCH[1]}
            ev "$schema: lock-enabled=$val idle-delay=${idle:-?}"

            if [ "$val" != 'true' ]; then
                issues+="$schema: bloqueo desactivado · "
            elif [ -n "$secs" ] && [ "$secs" -eq 0 ]; then
                issues+="$schema: sin tiempo de inactividad · "
            fi
            break
        done
    fi

    # KDE guarda la configuración en kscreenlockerrc.
    if [ "$found" -eq 0 ]; then
        local kread='' autolock='' timeout=''
        if have kreadconfig6; then
            kread=kreadconfig6
        elif have kreadconfig5; then
            kread=kreadconfig5
        fi
        if [ -n "$kread" ]; then
            autolock=$($kread --file kscreenlockerrc --group Daemon --key Autolock 2>/dev/null)
            timeout=$($kread --file kscreenlockerrc --group Daemon --key Timeout 2>/dev/null)
            if [ -n "$autolock" ] || [ -n "$timeout" ]; then
                found=1
                ev "KDE: Autolock=${autolock:-?} Timeout=${timeout:-?}"
                [ "${autolock,,}" = 'false' ] && issues+='KDE: Autolock=false · '
                if [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -eq 0 ]; then
                    issues+='KDE: Timeout=0 · '
                fi
            fi
        fi
    fi

    if [ "$found" -eq 0 ]; then
        emit "$id" SKIP 'no se detectó un escritorio con bloqueo de pantalla consultable'
        return
    fi

    if [ -n "$issues" ]; then
        emit "$id" WARN "bloqueo automático desactivado o sin tiempo: ${issues% · }"
    else
        emit "$id" PASS 'el bloqueo automático de pantalla está activado'
    fi
}
