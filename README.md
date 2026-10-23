# 🛡 watch4me

Auditoría de seguridad local en Bash, **solo lectura**. Analiza el sistema, muestra los hallazgos en pantalla y, si tú quieres, guarda un informe en Markdown.

Estado actual: **M2 + pulido de salida (v0.3.0)** — 70 checks en 8 dominios, resumen ejecutivo con prioridades, guía de actuación y `explain` enriquecido.

```text
--- 🛡 WATCH4ME | AUDITORÍA DE SEGURIDAD | v0.3.0 ---
 perfil: full · host: arch-cosmic · distro: arch · root: no
```

## Requisitos

- Bash >= 4.4
- Linux con `coreutils`
- Opcionales (se usan si están): `ss`, `findmnt`, `sysctl`, `nft`, `ufw`, `firewall-cmd`, `systemctl`, `sshd`, `getcap`, `modinfo`, `debsums`, `rpm`
- No necesita `jq`, `python` ni conexión a red

## Uso

```sh
chmod +x watch4me.sh

./watch4me.sh                          # auditoría completa
./watch4me.sh --profile quick          # escaneos rápidos (< 10 s)
./watch4me.sh --sudo                   # permite lecturas con sudo -n
./watch4me.sh --save                   # guarda el .md en reports/
./watch4me.sh --save - > informe.md    # Markdown por stdout
./watch4me.sh --save /ruta/informe.md  # ruta concreta
./watch4me.sh explain NET-01           # detalle y remedio de un check
./watch4me.sh explain NET-01 SVC-07    # varios checks a la vez
./watch4me.sh explain --list           # catálogo agrupado por dominio
```

Al terminar, si hay terminal interactiva, pregunta:

```text
¿Guardar informe en reports/watch4me-arch-cosmic-20261023-1748.md? [s/N]
```

Sin terminal (cron, pipe) no pregunta: solo guarda con `--save`.

### Opciones

| Opción | Efecto |
|---|---|
| `--profile quick\|full` | `quick` usa timeouts de 5-8 s, omite INT-02 y puede omitir escaneos que no terminen a tiempo |
| `--save [ruta]` | guarda sin preguntar; sin ruta usa `reports/`; `-` = stdout |
| `--no-anim` | cabecera estática; el progreso sigue visible en terminal |
| `--no-color` | sin colores (también `NO_COLOR=1`) |
| `--sudo` | usa `sudo -n` para lecturas que requieren root; nunca pide contraseña |

`full` (por defecto) permite escaneos de hasta 30 s y verifica la integridad de los paquetes instalados.

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | sin hallazgos relevantes |
| `1` | avisos o fallos no críticos |
| `2` | al menos un fallo crítico |
| `64` | uso incorrecto o modo no disponible (`baseline`, `monitor`) |

### Salida

Mientras analiza, la cabecera muestra el check en curso, una barra de progreso y el tiempo transcurrido. En terminales estrechas se usa una cabecera compacta; con `--no-anim` o `NO_COLOR` se mantiene una línea de progreso.

El informe de terminal es deliberadamente resumido:

1. **Resumen** con score, barra y contadores.
2. **Fallos** confirmados, con severidad y explicación.
3. **Avisos** en una línea por hallazgo, ordenados por gravedad.
4. **Por dominio**, una tabla compacta de correctos/fallos/avisos/omitidos.
5. **Cómo leer y actuar**: prioridad, contexto y valoración del peligro.

El informe Markdown conserva el detalle completo, la evidencia y los remedios de cada check. `--save -` emite solo ese Markdown.

## Catálogo de checks (70)

Los IDs siguen el formato `DOMINIO-NN`. `explain` muestra la descripción completa y el remedio sugerido de cada uno.

### Sistema (SYS)

| ID | Severidad | Check |
|---|---|---|
| `SYS-01` | media | Sincronización del reloj |
| `SYS-02` | alta | Actualizaciones pendientes |
| `SYS-03` | media | Reinicio pendiente |
| `SYS-04` | alta | Parámetros sysctl de hardening |
| `SYS-05` | media | Módulos de sistemas de ficheros innecesarios |
| `SYS-06` | baja | Reloj del hardware en UTC |
| `SYS-07` | media | Secure Boot |
| `SYS-08` | alta | Mitigaciones de vulnerabilidades de CPU |
| `SYS-09` | media | Opciones de montaje |
| `SYS-10` | media | Integridad del kernel (taint) |
| `SYS-11` | alta | Control de acceso obligatorio (AppArmor/SELinux) |
| `SYS-12` | baja | Visibilidad de procesos (/proc) |

### Usuarios (USR)

| ID | Severidad | Check |
|---|---|---|
| `USR-01` | crítica | Cuentas con UID 0 |
| `USR-02` | crítica | Cuentas con contraseña vacía |
| `USR-03` | media | Cuentas de sistema con shell interactiva |
| `USR-04` | alta | Algoritmos de hash de contraseñas débiles |
| `USR-05` | alta | Configuración de sudoers |
| `USR-06` | alta | Grupo root sin miembros adicionales |
| `USR-07` | media | Caducidad de contraseñas |
| `USR-08` | baja | UMASK por defecto |
| `USR-09` | media | UID y nombres de usuario duplicados |
| `USR-10` | baja | Permisos de los directorios home |

### Red (NET)

| ID | Severidad | Check |
|---|---|---|
| `NET-01` | alta | Puertos a la escucha expuestos |
| `NET-02` | alta | Firewall activo |
| `NET-03` | media | Reenvío de paquetes |
| `NET-04` | alta | Servicios de red obsoletos o innecesarios |
| `NET-05` | media | Política por defecto del firewall |
| `NET-06` | media | Interfaces en modo promiscuo |
| `NET-07` | media | SSH escuchando en todas las interfaces |
| `NET-08` | media | Contenedores con red host |

### Servicios (SVC)

| ID | Severidad | Check |
|---|---|---|
| `SVC-01` | media | Unidades systemd fallidas |
| `SVC-02` | media | Servicios obsoletos habilitados al arranque |
| `SVC-03` | media | Algoritmos débiles en SSH |
| `SVC-04` | media | Protección contra fuerza bruta SSH |
| `SVC-05` | alta | Contenedores privilegiados y socket de Docker |
| `SVC-06` | media | Auditoría del kernel (auditd) |
| `SVC-07` | alta | Configuración del servidor SSH |
| `SVC-08` | media | Persistencia de los logs de systemd |

### Ficheros (FS)

| ID | Severidad | Check |
|---|---|---|
| `FS-01` | baja | Particiones separadas |
| `FS-02` | crítica | Permisos de las bases de usuarios |
| `FS-03` | alta | Binarios SUID/SGID fuera del sistema |
| `FS-04` | alta | Permisos de ficheros sensibles |
| `FS-05` | media | Ficheros escribibles por cualquier usuario |
| `FS-06` | media | Ficheros sin propietario o grupo |
| `FS-07` | media | Sticky bit en directorios temporales |
| `FS-08` | media | Permisos de /root y /etc/skel |
| `FS-09` | alta | Ficheros de confianza heredados |
| `FS-10` | media | Permisos de los logs del sistema |

### Autenticación (AUTH)

| ID | Severidad | Check |
|---|---|---|
| `AUTH-01` | alta | Política de autenticación PAM |
| `AUTH-02` | alta | Estado de la contraseña de root |
| `AUTH-03` | media | Política de contraseñas en login.defs |
| `AUTH-04` | media | Contraseña de arranque de GRUB |
| `AUTH-05` | media | Parámetros de bloqueo por intentos fallidos |
| `AUTH-06` | baja | Historial de contraseñas |
| `AUTH-07` | baja | Bloqueo de sesión inactiva |
| `AUTH-08` | baja | Banner de advertencia en el login |

### Integridad (INT)

| ID | Severidad | Check |
|---|---|---|
| `INT-01` | media | Monitorización de integridad de ficheros |
| `INT-02` | alta | Verificación de paquetes instalados |
| `INT-03` | alta | Permisos de cron y at |
| `INT-04` | alta | Unidades systemd con ejecutables en rutas escribibles |
| `INT-05` | alta | Claves autorizadas de root |
| `INT-06` | alta | Capacidades de ficheros |
| `INT-07` | alta | Directorios escribibles en PATH |

### Malware y persistencia (MAL)

| ID | Severidad | Check |
|---|---|---|
| `MAL-01` | crítica | Precarga de bibliotecas (ld.so.preload) |
| `MAL-02` | alta | Ejecutables borrados en ejecución |
| `MAL-03` | media | Ejecutables en directorios temporales |
| `MAL-04` | alta | Patrones de persistencia sospechosos |
| `MAL-05` | alta | Procesos a la escucha desde rutas temporales |
| `MAL-06` | alta | Rutas no estándar en ld.so.conf |
| `MAL-07` | media | Módulos del kernel fuera de rutas estándar |

Cada check emite `PASS`, `WARN`, `FAIL`, `SKIP` o `INFO`, con evidencia y remedio sugerido.

## Puntuación

Pesos por severidad: `critical 10 · high 7 · medium 4 · low 2 · info 0`.

```text
score = 100 * (posible - penalización) / posible
penalización = peso(FAIL) + peso(WARN)/2
```

`SKIP` e `INFO` no puntúan. Se calcula el score global y uno por dominio; el informe muestra ambos.

## Multi-distro

Se detecta la familia desde `/etc/os-release` y se carga un adaptador:

| Familia | Actualizaciones | Integridad de paquetes |
|---|---|---|
| Arch | `checkupdates` o `pacman -Qu` | `pacman -Qkk` |
| Debian/Ubuntu | `apt-get -s upgrade` | `debsums -s` (si está instalado) |
| Fedora/RHEL | `dnf -q check-update` | `rpm -Va` |
| openSUSE/SLES | `zypper -q lu` | `rpm -Va` |

Si una capacidad no existe, el check sale `SKIP`, nunca `FAIL` falso.

## Puertos permitidos

`NET-01` considera esperado el puerto 22. Para declarar otros:

```sh
WATCH4ME_ALLOW_PORTS="22 443 8080" ./watch4me.sh
```

Los puertos de alto riesgo (21, 23, 445, 3389, 5900, 6379, 27017…) marcan `FAIL`.

## Seguridad del propio script

- No escribe fuera de `reports/` y `state/tmp/` (se borra al salir).
- No instala, no modifica configuración y no envía datos.
- No usa `eval` ni ejecuta contenido de ficheros analizados.
- Con `--sudo` solo ejecuta lecturas (`cat`, `stat`, `ss`, `find`, `readlink`, `grep`, `getcap`, `modinfo`, `nft list`, `iptables -S`, `sshd -T`, `pacman -Qkk`, `debsums -s`, `rpm -Va`) mediante `sudo -n`.
- No pide contraseña: si `sudo -n` falla, el check se omite con `SKIP`.

## Estructura

```text
watch4me.sh              CLI
lib/ui.sh                colores y cabecera animada
lib/common.sh            utilidades
lib/distro.sh            detección de familia
lib/family/*.sh          adaptadores por distribución
lib/checks.sh            registro, estado y scoring
lib/render-term.sh       salida en pantalla
lib/render-md.sh         informe Markdown
checks/*.sh              70 checks en 8 dominios
reports/                 informes generados
state/                   estado interno (futuro baseline)
```

## Roadmap

- **M1** ✅ CLI, cabecera animada, 12 checks, informes y licencia
- **M2** ✅ catálogo de 70 checks, scoring por dominio, `explain --list` / múltiples IDs y pulido de salida (v0.3.0)
- **M3** baseline + `monitor` con notificación de sistema (`notify-send` / journal) y timer de usuario
- **M4** documentación, tests y `shellcheck` limpio

## Licencia

GPLv3. Ver [LICENSE](LICENSE).

La cabecera animada (cambio de color y redibujado con `\e[H`/`\e[K`) deriva de
[dash4me](https://github.com/DanSanMar/dash4me), Copyright (C) DanSanMar, GPLv3.
