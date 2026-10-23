#!/usr/bin/env bash
# watch4me — checks de autenticación (AUTH)
# Licencia: GPLv3

register_check \
    'AUTH-01' high 'Política de autenticación PAM' check_auth_01 \
    'Comprueba el bloqueo tras intentos fallidos, la calidad de contraseñas y si se aceptan contraseñas vacías en la pila PAM.' \
    $'Activa el bloqueo de cuenta tras fallos:\n  Debian/Ubuntu: sudo apt install libpam-modules && añade pam_faillock a /etc/pam.d/common-auth\n  RHEL/SUSE:     authconfig --enablefaillock --faillockargs="deny=5 unlock_time=900" --update\nExige calidad de contraseña con pam_pwquality y elimina la opción nullok de pam_unix.'

check_auth_01() {
    local id=$CURRENT_ID
    local pam_dir=/etc/pam.d

    if [ ! -d "$pam_dir" ]; then
        emit "$id" SKIP 'no existe /etc/pam.d'
        return
    fi

    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: la política PAM depende de la imagen base'
        return
    fi

    local lockout quality nullok
    lockout=$(grep -lE '^[[:space:]]*[^#[:space:]].*(pam_faillock|pam_tally2)' "$pam_dir"/* 2>/dev/null)
    quality=$(grep -lE '^[[:space:]]*[^#[:space:]].*(pam_pwquality|pam_cracklib)' "$pam_dir"/* 2>/dev/null)
    nullok=$(grep -nE '^[[:space:]]*[^#[:space:]].*pam_unix.*nullok' "$pam_dir"/* 2>/dev/null)

    local fails=0 warns=0 issues=''

    if [ -z "$lockout" ]; then
        fails=$(( fails + 1 ))
        issues+='sin bloqueo por intentos fallidos · '
    else
        ev "bloqueo: $(printf '%s' "$lockout" | oneline)"
    fi

    if [ -z "$quality" ]; then
        warns=$(( warns + 1 ))
        issues+='sin módulo de calidad de contraseñas · '
    else
        ev "calidad: $(printf '%s' "$quality" | oneline)"
    fi

    if [ -n "$nullok" ]; then
        warns=$(( warns + 1 ))
        issues+='pam_unix acepta contraseñas vacías (nullok) · '
        printf '%s\n' "$nullok" | head -n 3 | while IFS= read -r line; do ev "$line"; done
    fi

    local detail="${issues% · }"
    [ -z "$detail" ] && detail='bloqueo por fallos y calidad de contraseñas configurados'

    if [ "$fails" -gt 0 ]; then
        emit "$id" FAIL "$detail"
    elif [ "$warns" -gt 0 ]; then
        emit "$id" WARN "$detail"
    else
        emit "$id" PASS "$detail"
    fi
}

register_check \
    'AUTH-02' high 'Estado de la contraseña de root' check_auth_02 \
    'root sin contraseña permite entrar sin credencial. Un hash MD5/DES es recuperable con fuerza bruta. Requiere leer shadow con --sudo.' \
    $'Bloquea la contraseña de root si solo usas sudo desde otra cuenta:\n  sudo passwd -l root\nO asigna una contraseña fuerte y un hash moderno:\n  sudo passwd root\n  sudo authselect select sssd --force   # RHEL, asegura yescrypt/sha512'

check_auth_02() {
    local id=$CURRENT_ID
    local hash
    hash=$(rootread /etc/shadow 2>/dev/null | awk -F: '$1 == "root" { print $2; exit }')
    if [ -z "$hash" ]; then
        if ! rootread /etc/shadow >/dev/null 2>&1; then
            emit "$id" SKIP 'no se puede leer /etc/shadow sin privilegios (usa --sudo)'
        else
            emit "$id" SKIP 'no se encontró la entrada de root en /etc/shadow'
        fi
        return
    fi

    case "$hash" in
        '')
            emit "$id" FAIL 'root no tiene contraseña'
            ;;
        '!'*|'*'*)
            emit "$id" PASS 'root tiene el login por contraseña bloqueado'
            ;;
        \$1\$*)
            emit "$id" FAIL 'root usa MD5-crypt, un hash débil'
            ;;
        *)
            if [ "${#hash}" -eq 13 ] && [[ "$hash" != *'$'* ]]; then
                emit "$id" FAIL 'root usa DES-crypt, un hash roto'
            else
                emit "$id" PASS 'root usa un hash de contraseña moderno'
            fi
            ;;
    esac
}

register_check \
    'AUTH-03' medium 'Política de contraseñas en login.defs' check_auth_03 \
    'Los valores de /etc/login.defs determinan caducidad, longitud mínima y algoritmo de hash por defecto para las cuentas nuevas.' \
    $'Ajusta /etc/login.defs:\n  PASS_MAX_DAYS 365\n  PASS_MIN_DAYS 1\n  PASS_WARN_AGE 7\n  PASS_MIN_LEN 12\n  ENCRYPT_METHOD YESCRYPT\nAplica la caducidad a usuarios existentes con chage.'

check_auth_03() {
    local id=$CURRENT_ID
    if [ ! -r /etc/login.defs ]; then
        emit "$id" SKIP 'no existe /etc/login.defs'
        return
    fi

    local max min warn len method
    max=$(awk '$1 == "PASS_MAX_DAYS" { print $2; exit }' /etc/login.defs)
    min=$(awk '$1 == "PASS_MIN_DAYS" { print $2; exit }' /etc/login.defs)
    warn=$(awk '$1 == "PASS_WARN_AGE" { print $2; exit }' /etc/login.defs)
    len=$(awk '$1 == "PASS_MIN_LEN" { print $2; exit }' /etc/login.defs)
    method=$(awk '$1 == "ENCRYPT_METHOD" { print toupper($2); exit }' /etc/login.defs)

    local issues='' n=0
    if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -eq 0 ] || [ "$max" -gt 365 ]; then
        issues+="PASS_MAX_DAYS=${max:-?} "
        n=$(( n + 1 ))
    fi
    if ! [[ "$min" =~ ^[0-9]+$ ]] || [ "$min" -lt 1 ]; then
        issues+="PASS_MIN_DAYS=${min:-?} "
        n=$(( n + 1 ))
    fi
    if ! [[ "$warn" =~ ^[0-9]+$ ]] || [ "$warn" -lt 7 ]; then
        issues+="PASS_WARN_AGE=${warn:-?} "
        n=$(( n + 1 ))
    fi
    if ! [[ "$len" =~ ^[0-9]+$ ]] || [ "$len" -lt 8 ]; then
        issues+="PASS_MIN_LEN=${len:-?} "
        n=$(( n + 1 ))
    fi
    case "$method" in
        ''|SHA512|YESCRYPT|SCRYPT|BCRYPT) ;;
        *) issues+="ENCRYPT_METHOD=$method "; n=$(( n + 1 )) ;;
    esac

    ev "PASS_MAX_DAYS=${max:-?} PASS_MIN_DAYS=${min:-?} PASS_WARN_AGE=${warn:-?} PASS_MIN_LEN=${len:-?} ENCRYPT_METHOD=${method:-?}"

    if [ "$n" -eq 0 ]; then
        emit "$id" PASS 'la política de contraseñas de login.defs es razonable'
    else
        emit "$id" WARN "$n valor(es) débiles en login.defs: ${issues% }"
    fi
}

register_check \
    'AUTH-04' medium 'Contraseña de arranque de GRUB' check_auth_04 \
    'Sin contraseña en GRUB, cualquiera con acceso físico puede arrancar en modo single/rescue y obtener root sin credenciales.' \
    $'Genera un hash y protege GRUB:\n  grub-mkpasswd-pbkdf2\nAñade en /etc/grub.d/40_custom:\n  set superusers="root"\n  password_pbkdf2 root <HASH>\nY regenera: sudo grub-mkconfig -o /boot/grub/grub.cfg'

check_auth_04() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: el gestor de arranque lo controla el host'
        return
    fi

    local cfg='' c
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [ -f "$c" ] && { cfg=$c; break; }
    done
    if [ -z "$cfg" ]; then
        emit "$id" SKIP 'no se encontró configuración de GRUB'
        return
    fi

    local content
    content=$(rootread "$cfg" 2>/dev/null)
    if [ -z "$content" ]; then
        emit "$id" SKIP 'la configuración de GRUB no es legible (usa --sudo)'
        return
    fi

    if printf '%s\n' "$content" | grep -Eq '^[[:space:]]*password_pbkdf2[[:space:]]+'; then
        emit "$id" PASS 'GRUB exige contraseña (hash PBKDF2)'
    elif printf '%s\n' "$content" | grep -Eq '^[[:space:]]*password[[:space:]]+'; then
        emit "$id" WARN 'GRUB usa una contraseña en texto plano; usa password_pbkdf2'
    else
        emit "$id" WARN 'GRUB no está protegido con contraseña'
    fi
}

register_check \
    'AUTH-05' medium 'Parámetros de bloqueo por intentos fallidos' check_auth_05 \
    'Un bloqueo demasiado tardío o que se libera pronto permite probar contraseñas sin límite práctico. Revisa deny y unlock_time de faillock.' \
    $'Ajusta /etc/security/faillock.conf:\n  deny = 5\n  unlock_time = 900\n  even_deny_root\nAsegúrate de que pam_faillock está en la pila PAM (AUTH-01).'

check_auth_05() {
    local id=$CURRENT_ID
    local pam_dir=/etc/pam.d

    if ! grep -lqE '^[[:space:]]*[^#[:space:]].*pam_faillock' "$pam_dir"/* 2>/dev/null; then
        emit "$id" SKIP 'pam_faillock no está configurado (ver AUTH-01)'
        return
    fi

    local deny='' unlock=''
    if [ -r /etc/security/faillock.conf ]; then
        deny=$(awk '$1 == "deny" { print $3; exit }' /etc/security/faillock.conf)
        unlock=$(awk '$1 == "unlock_time" { print $3; exit }' /etc/security/faillock.conf)
    fi
    # Valores por defecto de pam_faillock.
    [ -n "$deny" ] || deny=3
    [ -n "$unlock" ] || unlock=600

    ev "deny=$deny unlock_time=$unlock"
    local issues='' n=0
    if ! [[ "$deny" =~ ^[0-9]+$ ]] || [ "$deny" -gt 5 ]; then
        issues+="deny=$deny "
        n=$(( n + 1 ))
    fi
    if ! [[ "$unlock" =~ ^[0-9]+$ ]] || [ "$unlock" -lt 900 ]; then
        issues+="unlock_time=$unlock "
        n=$(( n + 1 ))
    fi

    if [ "$n" -eq 0 ]; then
        emit "$id" PASS "bloqueo tras $deny fallos durante $unlock segundos"
    else
        emit "$id" WARN "parámetros débiles de faillock: ${issues% }"
    fi
}

register_check \
    'AUTH-06' low 'Historial de contraseñas' check_auth_06 \
    'Sin historial, un usuario puede volver a usar inmediatamente una contraseña filtrada. pam_pwhistory evita la reutilización reciente.' \
    $'Activa el historial en PAM:\n  password requisite pam_pwhistory.so remember=5 use_authtok\nO en pam_unix: remember=5\nComprueba con: grep -r remember /etc/pam.d/'

check_auth_06() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: la política PAM depende de la imagen base'
        return
    fi
    if [ ! -d /etc/pam.d ]; then
        emit "$id" SKIP 'no existe /etc/pam.d'
        return
    fi

    local hits
    hits=$(grep -nE '^[[:space:]]*[^#[:space:]].*(pam_pwhistory|pam_unix.*remember=)' /etc/pam.d/* 2>/dev/null)
    if [ -n "$hits" ]; then
        ev "$(printf '%s' "$hits" | head -n 3 | oneline)"
        emit "$id" PASS 'PAM mantiene historial de contraseñas'
    else
        emit "$id" WARN 'PAM no configura historial de contraseñas'
    fi
}

register_check \
    'AUTH-07' low 'Bloqueo de sesión inactiva' check_auth_07 \
    'Una sesión olvidada en una terminal o SSH queda abierta indefinidamente. TMOUT cierra las shells interactivas tras un periodo de inactividad.' \
    $'Define un timeout en /etc/profile.d/50-tmout.sh:\n  TMOUT=600\n  readonly TMOUT\n  export TMOUT\nAplícalo también a bash.bashrc si tu distribución lo separa.'

check_auth_07() {
    local id=$CURRENT_ID
    local val=''
    val=$(grep -hE '^[[:space:]]*(export[[:space:]]+)?TMOUT=' \
        /etc/profile /etc/bash.bashrc /etc/profile.d/*.sh 2>/dev/null \
        | tail -n 1 | sed 's/.*TMOUT=//' | tr -cd '0-9')

    if [ -z "$val" ]; then
        emit "$id" WARN 'no se configura TMOUT para cerrar sesiones inactivas'
        return
    fi
    ev "TMOUT=$val"
    if [ "$val" -le 900 ]; then
        emit "$id" PASS "las sesiones inactivas se cierran a los ${val}s"
    else
        emit "$id" WARN "TMOUT=$val es demasiado largo (recomendado <= 900)"
    fi
}

register_check \
    'AUTH-08' low 'Banner de advertencia en el login' check_auth_08 \
    'Un banner legal disuade accesos no autorizados y deja constancia de que el uso está monitorizado. Es una medida disuasoria, no un control técnico.' \
    $'Configura un banner:\n  sudo sh -c "echo \\"Acceso restringido. Toda actividad se registra.\\" > /etc/issue"\nEn sshd_config:\n  Banner /etc/issue.net\nDespués recarga sshd.'

check_auth_08() {
    local id=$CURRENT_ID
    local banner='' issue_ok=0

    if [ -s /etc/issue ] && grep -q '[[:alnum:]]' /etc/issue 2>/dev/null; then
        issue_ok=1
    fi

    local cfg=/etc/ssh/sshd_config
    if [ -f "$cfg" ]; then
        local eff b
        eff=$(_sshd_effective)
        b=$(printf '%s\n' "$eff" | awk 'tolower($1) == "banner" { print $2; exit }')
        if [ -n "$b" ] && [ -s "$b" ]; then
            banner=$b
        fi
    fi

    if [ -n "$banner" ] || [ "$issue_ok" -eq 1 ]; then
        local detail=''
        [ -n "$banner" ] && detail+="sshd Banner=$banner"
        [ "$issue_ok" -eq 1 ] && { [ -n "$detail" ] && detail+=', '; detail+='/etc/issue'; }
        emit "$id" PASS "banner configurado ($detail)"
    else
        emit "$id" WARN 'no se detecta banner en /etc/issue ni en sshd'
    fi
}
