#!/usr/bin/env bash
# watch4me — checks de red (NET)
# Licencia: GPLv3

register_check \
    'NET-01' high 'Puertos a la escucha expuestos' check_net_01 \
    'Enumera sockets TCP/UDP accesibles desde fuera de loopback. Cada puerto expuesto es una superficie de ataque que debe estar justificada.' \
    $'Cierra o limita el servicio a loopback:\n  ss -tulpn                      # identifica el proceso\n  sudo systemctl disable --now <servicio>\nEn sshd usa ListenAddress 127.0.0.1 y en el firewall limita el origen.\nPuertos permitidos por defecto: define WATCH4ME_ALLOW_PORTS="22 443".'

check_net_01() {
    local id=$CURRENT_ID
    if ! have ss; then
        emit "$id" SKIP 'ss (iproute2) no disponible'
        return
    fi

    local raw
    raw=$(ss -tulpnH 2>/dev/null)
    if [ -z "$raw" ]; then
        raw=$(ss -tulpn 2>/dev/null | tail -n +2)
    fi

    if [ -z "$raw" ]; then
        emit "$id" SKIP 'ss no devolvió información'
        return
    fi

    local parsed
    parsed=$(printf '%s\n' "$raw" | awk '
        {
            proto = $1
            local = $5
            proc = ""
            for (i = 7; i <= NF; i++) proc = proc (i > 7 ? " " : "") $i

            if (match(local, /:[0-9]+$/) == 0) next
            port = substr(local, RSTART + 1)
            addr = substr(local, 1, RSTART - 1)

            exposed = (addr == "0.0.0.0" || addr == "*" || addr == "[::]" || addr == "::" || addr == "" \
                || (addr !~ /^127\./ && addr !~ /^\[?::1\]?$/ && addr !~ /^\[?::ffff:127\./))
            if (!exposed) next

            gsub(/\t/, " ", proc)
            print proto "/" port "\t" addr "\t" proc
        }')

    if [ -z "$parsed" ]; then
        emit "$id" PASS 'ningún socket accesible fuera de loopback'
        return
    fi

    local allow=" ${WATCH4ME_ALLOW_PORTS:-22} "
    local high_risk=' 21 23 69 111 135 139 445 512 513 514 1433 1521 2375 2376 3306 3389 5432 5900 5901 6379 9200 11211 27017 '
    local -A seen=()
    local proto_port addr proc port
    local exposed='' risky='' allowed='' n_exposed=0 n_risky=0 n_allowed=0

    while IFS=$'\t' read -r proto_port addr proc; do
        [ -n "$proto_port" ] || continue
        [ -n "${seen[$proto_port]:-}" ] && continue
        seen[$proto_port]=1

        port=${proto_port##*/}
        local label="$proto_port"
        if [ -n "$proc" ] && [ "$proc" != '-' ]; then
            local pname
            pname=$(printf '%s' "$proc" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1)
            [ -n "$pname" ] && label+=" ($pname)"
        fi

        case "$allow" in
            *" $port "*)
                allowed+="$label "
                n_allowed=$(( n_allowed + 1 ))
                ev "$proto_port en $addr (permitido) ${proc:-(proceso no visible sin root)}"
                continue
                ;;
        esac

        n_exposed=$(( n_exposed + 1 ))
        exposed+="$label "
        ev "$proto_port en $addr ${proc:-(proceso no visible sin root)}"

        case "$high_risk" in
            *" $port "*) risky+="$label "; n_risky=$(( n_risky + 1 )) ;;
        esac
    done <<< "$parsed"

    if [ "$n_exposed" -eq 0 ]; then
        if [ "$n_allowed" -gt 0 ]; then
            emit "$id" PASS "solo puertos permitidos: ${allowed% }"
        else
            emit "$id" PASS 'ningún socket accesible fuera de loopback'
        fi
        return
    fi

    local detail="$n_exposed puerto(s) expuestos: ${exposed% }"
    [ "$n_allowed" -gt 0 ] && detail+="; permitidos: ${allowed% }"
    if [ "$n_risky" -gt 0 ]; then
        emit "$id" FAIL "$detail; de alto riesgo: ${risky% }"
    else
        emit "$id" WARN "$detail"
    fi
}

register_check \
    'NET-02' high 'Firewall activo' check_net_02 \
    'Detecta si hay un firewall en marcha (ufw, firewalld, nftables o iptables). Sin filtrado, cualquier servicio escuchando queda accesible.' \
    $'Activa un firewall:\n  Arch:   sudo pacman -S ufw && sudo ufw enable\n  Debian: sudo apt install ufw && sudo ufw enable\n  RHEL:   sudo systemctl enable --now firewalld\n  SUSE:   sudo systemctl enable --now firewalld\nDefine primero las reglas de entrada que necesites.'

check_net_02() {
    local id=$CURRENT_ID
    local fw
    fw=$(firewall_state)

    if [ -z "$fw" ]; then
        emit "$id" FAIL 'no se detecta firewall activo'
        return
    fi

    ev "firewall detectado: $fw"
    emit "$id" PASS "firewall activo: $fw"
}

register_check \
    'NET-03' medium 'Reenvío de paquetes' check_net_03 \
    'Un equipo que no actúa como router ni host de contenedores no debería reenviar tráfico IPv4/IPv6: amplía el alcance de un compromiso.' \
    $'Desactiva el reenvío si no lo necesitas:\n  echo "net.ipv4.ip_forward = 0" | sudo tee /etc/sysctl.d/90-watch4me.conf\n  echo "net.ipv6.conf.all.forwarding = 0" | sudo tee -a /etc/sysctl.d/90-watch4me.conf\n  sudo sysctl --system\nSi usas Docker o una VPN, documenta por qué está activo.'

check_net_03() {
    local id=$CURRENT_ID
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: el reenvío lo controla el host'
        return
    fi

    local v4 v6 on=''
    v4=$(sysctl_val net.ipv4.ip_forward)
    v6=$(sysctl_val net.ipv6.conf.all.forwarding)
    [ "$v4" = '1' ] && on+='IPv4 '
    [ "$v6" = '1' ] && on+='IPv6 '

    if [ -z "$v4" ] && [ -z "$v6" ]; then
        emit "$id" SKIP 'no se pudieron leer los parámetros de reenvío'
        return
    fi
    if [ -n "$on" ]; then
        ev "ip_forward=$v4"
        ev "ipv6.forwarding=$v6"
        emit "$id" WARN "reenvío de paquetes habilitado: ${on% }"
    else
        emit "$id" PASS 'reenvío de paquetes deshabilitado'
    fi
}

register_check \
    'NET-04' high 'Servicios de red obsoletos o innecesarios' check_net_04 \
    'Telnet, FTP, TFTP, rsh y otros protocolos sin cifrar exponen credenciales y datos. Avahi, CUPS o rpcbind amplían la superficie si no se usan.' \
    $'Desactiva lo que no necesites:\n  sudo systemctl disable --now telnet.socket rsh.socket rlogin.socket tftp.socket\n  sudo systemctl disable --now vsftpd proftpd rpcbind avahi-daemon cups\n  ss -tulpn    # confirma qué sigue escuchando'

check_net_04() {
    local id=$CURRENT_ID
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi

    local units='cups cups-browsed avahi-daemon rpcbind rpcbind.socket nfs-server nfs-kernel-server smbd nmbd vsftpd proftpd pure-ftpd tftp.socket telnet.socket telnet rsh.socket rsh rlogin.socket rlogin rexec.socket'
    local legacy=' telnet.socket telnet rsh.socket rsh rlogin.socket rlogin rexec.socket tftp.socket vsftpd proftpd pure-ftpd nfs-server nfs-kernel-server '
    local active='' enabled_only='' legacy_active='' u

    for u in $units; do
        if unit_active "$u"; then
            active+="$u "
            case "$legacy" in
                *" $u "*) legacy_active+="$u " ;;
            esac
        elif unit_enabled "$u"; then
            enabled_only+="$u "
        fi
    done

    if [ -n "$legacy_active" ]; then
        emit "$id" FAIL "servicios inseguros activos: ${legacy_active% }"
        return
    fi

    if [ -n "$active" ]; then
        emit "$id" WARN "servicios de red activos: ${active% }"
    elif [ -n "$enabled_only" ]; then
        emit "$id" WARN "servicios habilitados al arranque: ${enabled_only% }"
    else
        emit "$id" PASS 'no se detectan servicios de red obsoletos activos'
    fi
}

register_check \
    'NET-05' medium 'Política por defecto del firewall' check_net_05 \
    'Un firewall activo con política de entrada ACCEPT no protege nada. Debe descartar el tráfico entrante que no esté permitido explícitamente.' \
    $'Establece una política de entrada restrictiva:\n  ufw:       sudo ufw default deny incoming\n  firewalld: sudo firewall-cmd --permanent --zone=public --set-target=DROP && sudo firewall-cmd --reload\n  iptables:  sudo iptables -P INPUT DROP\nDefine antes las reglas de los servicios que sí necesitas.'

check_net_05() {
    local id=$CURRENT_ID
    local fw
    fw=$(firewall_state)

    case "$fw" in
        '')
            emit "$id" INFO 'sin firewall activo (lo evalúa NET-02)'
            return
            ;;
        ufw)
            local out line policy='' pol
            out=$(ufw status verbose 2>/dev/null)
            line=$(printf '%s\n' "$out" | grep -i '^Default:' | head -n 1)
            [ -n "$line" ] && ev "$line"

            case "$line" in
                *'deny (incoming)'*|*'reject (incoming)'*) policy=deny ;;
                *'allow (incoming)'*) policy=allow ;;
            esac

            # Sin privilegios, ufw no muestra la política: se lee la
            # configuración estática, que sí es legible.
            if [ -z "$policy" ] && [ -r /etc/default/ufw ]; then
                pol=$(awk -F= '/^[[:space:]]*DEFAULT_INPUT_POLICY/ { gsub(/"/, "", $2); print $2; exit }' /etc/default/ufw 2>/dev/null)
                case "${pol,,}" in
                    drop|reject) policy=deny; ev "/etc/default/ufw: DEFAULT_INPUT_POLICY=$pol" ;;
                    accept) policy=allow; ev "/etc/default/ufw: DEFAULT_INPUT_POLICY=$pol" ;;
                esac
            fi

            if [ -z "$policy" ]; then
                if ! is_root && ! sudo_ok; then
                    emit "$id" SKIP 'no se puede leer la política de ufw sin privilegios (usa --sudo)'
                else
                    emit "$id" WARN 'no se pudo leer la política por defecto de ufw'
                fi
            elif [ "$policy" = deny ]; then
                emit "$id" PASS 'ufw descarta el tráfico entrante por defecto'
            else
                emit "$id" WARN 'ufw permite el tráfico entrante por defecto'
            fi
            ;;
        firewalld)
            local zone target
            zone=$(firewall-cmd --get-default-zone 2>/dev/null)
            target=$(firewall-cmd --zone="$zone" --get-target 2>/dev/null)
            ev "zona=$zone target=${target:-default}"
            case "${target,,}" in
                drop|reject) emit "$id" PASS "firewalld descarta el tráfico entrante (zona $zone)" ;;
                *) emit "$id" WARN "firewalld usa target ${target:-default} en la zona $zone" ;;
            esac
            ;;
        nftables)
            local rules
            rules=$(as_root nft list ruleset 2>/dev/null)
            if [ -z "$rules" ] && ! is_root && ! sudo_ok; then
                emit "$id" SKIP 'nftables requiere privilegios para leer las reglas (usa --sudo)'
                return
            fi
            if printf '%s\n' "$rules" | grep -A8 'hook input' | grep -Eq 'policy[[:space:]]+(drop|reject)'; then
                emit "$id" PASS 'nftables aplica policy drop/reject en la cadena de entrada'
            else
                emit "$id" WARN 'nftables no muestra policy drop/reject en la cadena de entrada'
            fi
            ;;
        iptables)
            local pol
            pol=$(as_root iptables -S 2>/dev/null | awk '/^-P INPUT/ { print $3; exit }')
            ev "política INPUT: ${pol:-desconocida}"
            case "$pol" in
                DROP|REJECT) emit "$id" PASS "iptables aplica política INPUT $pol" ;;
                ACCEPT) emit "$id" WARN 'iptables acepta todo el tráfico entrante por defecto' ;;
                *) emit "$id" WARN 'no se pudo leer la política INPUT de iptables' ;;
            esac
            ;;
        *)
            emit "$id" WARN "no se pudo evaluar la política por defecto de $fw"
            ;;
    esac
}

register_check \
    'NET-06' medium 'Interfaces en modo promiscuo' check_net_06 \
    'El modo promiscuo hace que una interfaz reciba todo el tráfico de su segmento. Suele indicar captura de tráfico o un bridge mal configurado.' \
    $'Revisa qué interfaz está en promiscuo:\n  ip -o link show | grep PROMISC\n  sudo ip link set <interfaz> promisc off\nSi es un bridge o una herramienta de captura, documenta su uso.'

check_net_06() {
    local id=$CURRENT_ID
    if ! have ip; then
        emit "$id" SKIP 'ip (iproute2) no disponible'
        return
    fi
    if [ -f /.dockerenv ]; then
        emit "$id" INFO 'contenedor detectado: las interfaces las gestiona el host'
        return
    fi

    local prom
    prom=$(ip -o link show 2>/dev/null | awk -F': ' '/PROMISC/ { print $2 }' | tr '\n' ' ')
    if [ -z "$prom" ]; then
        emit "$id" PASS 'ninguna interfaz está en modo promiscuo'
    else
        ev "$(ip -o link show 2>/dev/null | grep PROMISC | oneline)"
        emit "$id" WARN "interfaces en modo promiscuo: ${prom% }"
    fi
}

register_check \
    'NET-07' medium 'SSH escuchando en todas las interfaces' check_net_07 \
    'Si SSH escucha en 0.0.0.0/:: queda expuesto en todas las redes del equipo. Limítalo a la interfaz o VPN por la que realmente se administra.' \
    $'Limita las direcciones de escucha en sshd_config:\n  ListenAddress 10.0.0.5\n  ListenAddress 127.0.0.1\nValida y recarga:\n  sudo sshd -t && sudo systemctl reload sshd'

check_net_07() {
    local id=$CURRENT_ID
    if ! systemd_running; then
        emit "$id" SKIP 'systemd no está gestionando el sistema'
        return
    fi
    if ! unit_active sshd && ! unit_active ssh; then
        emit "$id" INFO 'el servidor SSH no está activo'
        return
    fi
    if ! have ss; then
        emit "$id" SKIP 'ss no disponible'
        return
    fi

    local ports=''
    if is_root || sudo_ok; then
        if is_root; then
            ports=$(timeout 10 sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
        else
            ports=$(sudo -n timeout 10 sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
        fi
    fi
    if [ -z "$ports" ]; then
        ports=$(grep -hE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | awk '{ print $2 }')
        [ -n "$ports" ] || ports=22
    fi
    ports=$(printf '%s\n' "$ports" | awk 'NF' | sort -u | tr '\n' ' ')

    local p addrs a wild='' listening=0
    for p in $ports; do
        addrs=$(ss -tlnH 2>/dev/null | awk -v p="$p" '{ a = $4; if (a ~ ":" p "$") print a }' | sed 's/:[0-9]*$//')
        [ -n "$addrs" ] && listening=1
        for a in $addrs; do
            case "$a" in
                0.0.0.0|'*'|'[::]'|'::')
                    case " $wild " in
                        *" $p "*) ;;
                        *) wild+="$p " ;;
                    esac
                    ;;
            esac
        done
    done

    if [ "$listening" -eq 0 ]; then
        emit "$id" INFO "sshd está activo pero no se detectó un socket en los puertos $ports"
        return
    fi
    if [ -n "$wild" ]; then
        emit "$id" WARN "SSH escucha en todas las interfaces (puerto(s): ${wild% })"
    else
        emit "$id" PASS "SSH solo escucha en direcciones concretas (puerto(s): $(printf '%s' "$ports" | oneline))"
    fi
}

register_check \
    'NET-08' medium 'Contenedores con red host' check_net_08 \
    'Un contenedor con --network host comparte la pila de red del anfitrión: evade el aislamiento y puede alcanzar cualquier servicio local.' \
    $'Usa una red propia y publica solo los puertos necesarios:\n  docker run --network bridge -p 127.0.0.1:8080:8080 ...\nRevisa los contenedores actuales:\n  docker ps --format "{{.Names}} {{.NetworkMode}}"'

check_net_08() {
    local id=$CURRENT_ID
    local tool=''

    if have docker && docker info >/dev/null 2>&1; then
        tool=docker
    elif have podman && podman info >/dev/null 2>&1; then
        tool=podman
    fi

    if [ -z "$tool" ]; then
        if have docker || have podman; then
            emit "$id" SKIP 'motor de contenedores presente pero sin acceso al daemon'
        else
            emit "$id" SKIP 'no se detecta Docker ni Podman'
        fi
        return
    fi

    local out
    if [ "$tool" = docker ]; then
        out=$(timeout 15 docker ps --format '{{.Names}}\t{{.NetworkMode}}' 2>/dev/null)
    else
        out=$(timeout 15 podman ps --format '{{.Names}}\t{{.NetworkMode}}' 2>/dev/null)
    fi

    if [ -z "$out" ]; then
        emit "$id" PASS 'no hay contenedores en ejecución'
        return
    fi

    local hostnet=''
    while IFS=$'\t' read -r name mode; do
        [ -n "$name" ] || continue
        if [ "$mode" = 'host' ]; then
            hostnet+="$name "
            ev "$name usa --network host"
        fi
    done <<< "$out"

    if [ -n "$hostnet" ]; then
        emit "$id" WARN "contenedores con red host: ${hostnet% }"
    else
        emit "$id" PASS 'ningún contenedor usa la red del anfitrión'
    fi
}

register_check \
    'NET-09' high 'Seguridad de las redes Wi-Fi guardadas' check_net_09 \
    'Una red Wi-Fi abierta o con WEP permite que cualquiera cercano lea el tráfico o se haga pasar por el punto de acceso. WPA2/WPA3 (o WPA2-Enterprise) es el mínimo razonable.' \
    $'Olvida la red insegura y vuelve a conectarte con WPA2/WPA3:\n  nmcli connection delete "<nombre>"\n  nmcli device wifi connect "<SSID>" password "<contraseña>"\nEn el router, cambia el cifrado a WPA2/WPA3 y desactiva WPS si no lo usas.'

check_net_09() {
    local id=$CURRENT_ID
    if ! have nmcli; then
        emit "$id" SKIP 'NetworkManager (nmcli) no disponible'
        return
    fi

    local out
    out=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
    if [ -z "$out" ]; then
        emit "$id" SKIP 'nmcli no devolvió conexiones guardadas'
        return
    fi

    local name type km wifi=0 open='' weak='' strong=''
    while IFS=: read -r name type; do
        [ "$type" = '802-11-wireless' ] || continue
        wifi=$(( wifi + 1 ))
        km=$(nmcli -t -f 802-11-wireless-security.key-mgmt connection show "$name" 2>/dev/null \
            | sed -n 's/^[^:]*:\(.*\)$/\1/p' | head -n 1)
        case "${km,,}" in
            ''|none)
                open+="$name "
                ev "$name: sin gestión de clave (abierta o WEP)"
                ;;
            wep)
                weak+="$name "
                ev "$name: WEP"
                ;;
            *)
                strong+="$name "
                ev "$name: $km"
                ;;
        esac
    done <<< "$out"

    if [ "$wifi" -eq 0 ]; then
        emit "$id" SKIP 'no hay redes Wi-Fi guardadas'
        return
    fi
    if [ -n "$open" ]; then
        emit "$id" FAIL "redes Wi-Fi sin cifrado moderno: ${open% }"
        return
    fi
    if [ -n "$weak" ]; then
        emit "$id" FAIL "redes Wi-Fi con WEP: ${weak% }"
        return
    fi
    emit "$id" PASS "las $wifi redes Wi-Fi guardadas usan WPA2/WPA3"
}
