# 🛡 watch4me

Auditoría de seguridad local en Bash, **solo lectura**. Analiza el sistema, muestra los hallazgos en pantalla y, si tú quieres, guarda un informe en **Markdown y JSON**. Incluye **cinco perfiles** según el tipo de equipo, una **vigilancia en vivo** de conexiones, servicios, procesos y persistencia, y una **baseline de auditoría** para detectar cambios con `monitor`. También tiene un **menú interactivo con fzf** (agrupado en submenús, con vista previa y ayuda) que sigue la línea de los programas *4me*.

Estado actual: **M2.7 + M3 + M4 + M5 / v0.8.0** — 74 checks en 8 dominios, perfiles `general`, `servidor`, `cliente`, `domestico` y `esencial`, vigilancia `watch`, baseline y monitor de cambios (solo auditoría, sin timer), menú fzf agrupado con submenús y catálogo navegable, informes Markdown y JSON, resumen ejecutivo con prioridades, guía de actuación, `explain` enriquecido, suite de pruebas y `shellcheck` limpio.

```text
--- 🛡 WATCH4ME | AUDITORÍA DE SEGURIDAD | v0.8.0 ---
 perfil: General (74 checks) · host: arch-cosmic · distro: arch · root: no
```

## Requisitos

- Bash >= 4.4
- Linux con `coreutils`
- Opcionales en la auditoría (se usan si están): `fzf` (menú interactivo), `less` (paginador), `ss`, `findmnt`, `lsblk`, `sysctl`, `nft`, `ufw`, `firewall-cmd`, `systemctl`, `sshd`, `nmcli`, `getcap`, `modinfo`, `debsums`, `rpm`
- `ss` (iproute2) es necesario para `watch`; sin él, la vigilancia sale con código `64`
- No necesita `jq`, `python` ni conexión a red para auditar
- El menú no es obligatorio: sin `fzf` la auditoría funciona igual

## Uso

```sh
chmod +x watch4me.sh

./watch4me.sh                          # menú interactivo (TTY) / auditoría (sin TTY)
./watch4me.sh menu                     # fuerza el menú interactivo
./watch4me.sh audit                    # auditoría general sin menú
./watch4me.sh audit --profile servidor # enfoque servidor
./watch4me.sh audit --profile cliente  # enfoque cliente
./watch4me.sh audit --profile domestico # enfoque PC doméstico
./watch4me.sh audit --profile esencial # vistazo rápido
./watch4me.sh audit --sudo             # permite lecturas con sudo -n
./watch4me.sh audit --save             # guarda .md y .json en reports/
./watch4me.sh audit --save - > informe.md   # Markdown por stdout
./watch4me.sh audit --save /ruta/informe     # ruta concreta (genera .md y .json)
./watch4me.sh baseline                 # guarda la auditoría general como referencia
./watch4me.sh baseline --profile esencial # baseline del perfil esencial
./watch4me.sh baseline --show          # consulta la baseline sin auditar
./watch4me.sh monitor                  # compara la auditoría con la baseline
./watch4me.sh watch                    # vigilancia en vivo (TTY con color)
./watch4me.sh watch --once             # una sola captura, para scripts o cron
./watch4me.sh explain NET-01           # detalle y remedio de un check
./watch4me.sh explain NET-01 SVC-07    # varios checks a la vez
./watch4me.sh explain --list           # catálogo agrupado por dominio
```

Al terminar una auditoría, si hay terminal interactiva, pregunta:

```text
¿Guardar informes en reports/watch4me_arch_cosmic_24_10_2026_17_48.md y .json? [s/N]
```

Sin terminal (cron, pipe) no pregunta: solo guarda con `--save`.

### Perfiles

Un perfil cambia **qué checks se ejecutan**, no su profundidad. Así no se repiten auditorías rápidas y completas con el mismo contenido: cada perfil responde a un uso real del equipo. La excepción es `esencial`, que además reduce los timeouts.

| Perfil | Checks | Para quién | Cobertura |
|---|---|---|---|
| `general` | 74 | Cualquier equipo; auditoría de referencia | Todo el catálogo, los 8 dominios |
| `servidor` | 67 | Servidores y equipos expuestos | Exposición, SSH, servicios, integridad y persistencia; omite lo propio de escritorio |
| `cliente` | 41 | Portátiles y equipos de trabajo | Actualizaciones, cuentas, firewall, malware, Wi-Fi, cifrado y bloqueo de pantalla; omite el hardening de servidor |
| `domestico` | 35 | PC de casa | Lo importante para un equipo familiar, explicado sin jerga de servidor |
| `esencial` | 14 | Vistazo rápido o equipo con pocos recursos | Checks de alto valor y bajo coste, con escaneos de hasta 8 s |

`servidor` omite los checks que no aplican a un equipo sin escritorio ni Wi-Fi: reloj UTC, Secure Boot, cifrado, bloqueo de pantalla, autologin, Wi-Fi y contraseña de GRUB. `cliente` y `domestico` dejan fuera el hardening propio de un servidor expuesto. `esencial` no sustituye a la auditoría general: es un semáforo rápido.

Los alias antiguos siguen funcionando: `full` = `general` y `quick` = `esencial`.

### Menú interactivo

En una terminal, `./watch4me.sh` abre un menú basado en `fzf` con el mismo estilo visual del resto de programas *4me*. El menú principal está **agrupado en submenús** para no saturar la pantalla y cada fila muestra una descripción y una **vista previa** en el panel derecho antes de ejecutarse.

| Entrada principal | Qué agrupa |
|---|---|
| Auditorías de seguridad | Las cinco auditorías por perfil, con sus checks y tiempo estimado |
| Historial y cambios | Crear y ver la baseline, monitorizar cambios y abrir informes guardados |
| Vigilancia | `watch` en vivo o una sola captura |
| Catálogo y fichas | Buscar un check, explorar por dominio o abrir el catálogo completo |
| Lecturas con sudo | Activa o desactiva `sudo -n`; muestra «sin caché» si no está disponible |
| Ayuda y atajos | Guía del menú, comandos directos, códigos de salida y límites |
| Salir | Cierra el menú sin ejecutar nada |

Dentro de los submenús están las acciones concretas:

| Acción | Qué hace |
|---|---|
| Auditoría general | Perfil `general`: 74 checks y escaneos hasta 30 s; la más fiable |
| Servidor | Perfil `servidor`: 67 checks centrados en SSH, servicios e integridad |
| Cliente | Perfil `cliente`: 41 checks de escritorio, Wi-Fi y cifrado |
| PC doméstico | Perfil `domestico`: 35 checks de un equipo de casa |
| Vistazo esencial | Perfil `esencial`: 14 checks rápidos, con timeouts de 8 s |
| Crear baseline | Guarda una auditoría general como referencia en `state/baseline/<host>/` |
| Ver baseline guardada | Muestra la referencia guardada sin ejecutar la auditoría |
| Monitorizar cambios | Repite el perfil guardado y compara estados y score con la baseline |
| Informes guardados | Lista y abre los `.md` y `.json` de `reports/` |
| Vigilancia en vivo | Abre `watch`: puertos, conexiones, servicios y persistencia |
| Una sola captura | Ejecuta `watch --once`: analiza, muestra el resultado y sale |
| Explicar un check | Buscador por ID, título o dominio con ficha, perfiles y remedio |
| Explorar por dominio | Los 8 dominios con su cobertura; después eliges el check |
| Catálogo completo | Los 74 checks en un buscador `fzf`, agrupados por dominio |
| Lecturas con sudo | Se aplica a auditorías, `baseline`, `monitor` y `watch` |
| Ayuda y atajos | Comandos directos, códigos, funcionamiento del menú y seguridad |
| Salir o Volver | Cierra el menú o vuelve un nivel sin ejecutar acciones |

Cada auditoría lanzada desde el menú ofrece guardar el informe al terminar. En dos palabras: **general** es la recomendada; **servidor**, **cliente** y **doméstico** se ajustan al uso del equipo; **esencial** cambia exhaustividad por tiempo; **baseline** guarda una referencia y **monitor** avisa de cambios; **sudo** añade lecturas protegidas (activa antes la caché con `sudo -v`); **watch** vigila sin auditar; **catálogo** explica qué comprueba cada check.

Teclas: escribe para filtrar, `ENTER` abre un grupo o ejecuta la fila, `ESC` vuelve un nivel y `Ctrl-C` cancela la pantalla actual. En el menú principal, `ESC` o `Ctrl-C` salen del programa y restauran la terminal. Cada submenú incluye una fila «Volver» y explica sus opciones en el panel derecho. El logo de la cabecera va cambiando de color cada 3 segundos con la misma paleta de `dash4me` mientras el menú está abierto, e incluye fecha, hora y host cuando el ancho de la terminal lo permite; en terminales estrechas cambia el subtítulo por la hora y la fecha. Al salir se muestra un mensaje de despedida con los atajos directos.

El **catálogo completo** ya no se abre en un paginador externo: se navega con `fzf`, se filtra por ID, título o dominio y `ENTER` abre la ficha. Al cerrar la ficha con `ENTER` vuelve al buscador para seguir consultando; `ESC` o `Ctrl-C` vuelven al catálogo sin dejar la sesión atrapada y, desde el menú principal, `Ctrl-C` sale del programa. Los informes guardados sí usan `less`; dentro de él, `q` vuelve al menú y la línea inferior recuerda los atajos.

Si `fzf` no está instalado, el menú muestra el comando de instalación para tu distribución y **pide confirmación** antes de instalar nada. Es la única acción del programa que modifica el sistema; las auditorías siguen siendo solo lectura. Para impedir esa oferta:

```sh
WATCH4ME_NO_INSTALL=1 ./watch4me.sh menu
```

## Baseline y monitor (`baseline` / `monitor`)

La baseline es una **fotografía de la auditoría** para saber qué ha cambiado después. Guarda solo los checks: estado, detalle, severidad, score y metadatos del equipo. No guarda puertos, servicios, ficheros ni procesos; para eso está `watch`.

```sh
./watch4me.sh baseline                  # auditoría general y baseline del host
./watch4me.sh baseline --profile esencial
./watch4me.sh baseline --show           # consulta la baseline guardada
./watch4me.sh baseline --force          # sobrescribe sin preguntar (scripts)
./watch4me.sh monitor                   # repite el perfil guardado y compara
./watch4me.sh monitor --profile esencial # debe coincidir con la baseline
```

Hay **una baseline por host**. El perfil queda guardado dentro, así que `monitor` repite exactamente ese perfil y no hace falta indicarlo. Si ya existe, `baseline` pide confirmación en terminal; sin TTY exige `--force` para no sobrescribir por accidente. Los datos quedan en `state/baseline/<host>/` con permisos privados (`600` los ficheros, `700` los directorios); el detalle puede incluir nombres de usuario y rutas, por eso no se comparte.

`monitor` clasifica cada diferencia:

- **Empeoran**: un check pasa a un estado peor (por ejemplo, `PASS` → `FAIL`).
- **Omitidos**: antes se evaluaba y ahora no; puede ser falta de `sudo` o de una herramienta. Cuenta como pérdida de cobertura.
- **Se evalúan ahora**: antes era `SKIP` y ahora tiene un estado real.
- **Nuevos**: checks que no estaban en la baseline, por cambio de catálogo.
- **Mejoran** y **sin referencia**: mejoras y checks retirados del perfil; los retirados cuentan como pérdida de cobertura.

Si el cambio de catálogo es intencionado, recrea la baseline con `./watch4me.sh baseline --force`. Además, `monitor` compara el score. Si la baseline se creó con `--sudo`, `monitor` intenta reutilizar `sudo -n`; si ya no hay caché, avisa y los checks protegidos pueden quedar omitidos.

La baseline **no guarda informes** `.md`/`.json`: para conservar una auditoría completa usa `./watch4me.sh audit --save`. `monitor` es una sola ejecución y **no instala timer ni envía notificaciones**; se puede llamar a mano, desde el menú o desde cron usando su código de salida.

| Modo | Códigos |
|---|---|
| `baseline` | `0` guardada o cancelada por el usuario · `64` error de uso, de ejecución o de escritura |
| `monitor` | `0` sin regresiones · `1` regresión, aviso nuevo o pérdida de cobertura (omitidos o retirados) · `2` fallo crítico nuevo · `64` sin baseline, baseline incompatible o perfil incorrecto |

El estado interno se puede aislar en pruebas o mover a otra ruta con `WATCH4ME_STATE_DIR`:

```sh
WATCH4ME_STATE_DIR=/tmp/watch4me-state ./watch4me.sh baseline --profile esencial
```

## Vigilancia en vivo (`watch`)

`watch` es un monitor de **solo lectura** que compara instantáneas del sistema. No es un antivirus, no bloquea conexiones, no instala nada y no envía datos: señala lo que conviene revisar y tú decides qué hacer.

```sh
./watch4me.sh watch                    # pantalla en vivo; Ctrl-C para salir
./watch4me.sh watch --interval 5       # una captura cada 5 s (por defecto, 3)
./watch4me.sh watch --once             # una sola captura y sale
./watch4me.sh watch --once --sudo      # más datos de procesos de otros usuarios
```

En cada captura revisa:

- **Puertos a la escucha** clasificados como `expuestos`, `virtual` (puentes de libvirt, Docker o contenedores) o `local`; los puertos de alto riesgo se marcan como aviso.
- **Conexiones TCP establecidas**, con atención a puertos remotos peligrosos, shells o intérpretes con red y binarios borrados o en rutas temporales.
- **Procesos** con patrones de mineros o shells inversas.
- **Servicios systemd** en estado `failed`.
- **Persistencia**: contenido de `/etc/ld.so.preload` y cambios en ficheros críticos como `passwd`, `shadow`, `sudoers`, la configuración de SSH, `cron`, `rc.local`, claves `authorized_keys` y unidades de systemd.
- **Cambios entre capturas**: puertos nuevos, servicios nuevos o detenidos, ficheros críticos modificados y procesos sospechosos nuevos.

Un socket solo cuenta como `expuesto` si escucha en una interfaz física o en un comodín sin ámbito. Los que se atan a un puente del host (`virbr*`, `docker*`, `br-*`, `vnet*`, etc.) se muestran como `virtual`: solo los alcanzan el propio equipo y sus invitados. El ámbito `%interfaz` se conserva en la tabla (`0.0.0.0%virbr0`).

La pantalla en vivo necesita TTY y color. Sin TTY, o con `--no-color`/`NO_COLOR=1`, se muestra **una única captura** con el mismo formato que `--once`; si no se pidió `--once`, se avisa por stderr. `watch` no guarda informes: para conservar un análisis usa `audit --save`.

En una captura única, `watch` devuelve `0` sin hallazgos, `1` con avisos y `2` con hallazgos críticos. La pantalla en vivo termina con `0` al salir con `Ctrl-C`. En ambos casos, `64` indica que falta `ss` o que una opción no es válida.

### Opciones

| Opción | Efecto |
|---|---|
| `menu`, `-m`, `--menu` | abre el menú interactivo (requiere `fzf`) |
| `audit` | fuerza la auditoría sin menú |
| `watch` | abre la vigilancia en vivo |
| `--profile P` | selecciona el perfil: `general` (por defecto), `servidor`, `cliente`, `domestico` o `esencial`; en `baseline` elige el que se guarda y en `monitor` debe coincidir con el guardado |
| `--interval N` | `watch`: segundos entre capturas (por defecto, 3) |
| `--once` | `watch`: una sola captura y sale; útil sin TTY o en cron |
| `--save [ruta]` | guarda `.md` y `.json` sin preguntar; sin ruta usa `reports/`; `-` = solo Markdown por stdout |
| `--force` | `baseline`: sobrescribe la baseline existente sin preguntar |
| `--show` | `baseline`: muestra la baseline guardada sin ejecutar checks |
| `--no-anim` | cabecera estática; el progreso sigue visible en terminal |
| `--no-color` | sin colores (también `NO_COLOR=1`) |
| `--sudo` | usa `sudo -n` para lecturas que requieren root; nunca pide contraseña; `monitor` reutiliza el sudo de la baseline |
| `explain <ID>...` | muestra la ficha y el remedio de uno o varios checks |
| `explain --list` | catálogo agrupado por dominio y perfiles |
| `-h`, `--help` | ayuda completa de la CLI |
| `-v`, `--version` | versión |

En `audit`, `baseline` y `monitor`, los perfiles `general`, `servidor`, `cliente` y `domestico` permiten escaneos de hasta 30 s; `esencial` los limita a 8 s y reduce los timeouts de paquetes (mínimo 5 s). `--save` no se puede combinar con `watch`, `baseline` ni `monitor`.

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | sin hallazgos relevantes |
| `1` | avisos o fallos no críticos |
| `2` | al menos un fallo crítico |
| `64` | uso incorrecto, baseline ausente o incompatible, menú sin TTY o falta `ss` en `watch` |

`baseline` usa `0`/`64`; `monitor` usa `0`/`1`/`2`/`64` según los cambios. La tabla anterior describe los códigos de `audit`.

### Salida

Mientras analiza, la cabecera muestra el check en curso, una barra de progreso y el tiempo transcurrido. En terminales estrechas se usa una cabecera compacta; con `--no-anim` o `NO_COLOR` se mantiene una línea de progreso.

El informe de terminal es deliberadamente resumido:

1. **Resumen** con score, barra y contadores.
2. **Fallos** confirmados, con severidad y explicación.
3. **Avisos** en una línea por hallazgo, ordenados por gravedad.
4. **Por dominio**, una tabla compacta de correctos/fallos/avisos/omitidos.
5. **Cómo leer y actuar**: prioridad, contexto y valoración del peligro.

El informe Markdown conserva el detalle completo, la evidencia y los remedios de cada check. El JSON contiene los mismos datos en un esquema estable (`watch4me.report/v1`), pensado para análisis automático con IA o scripts. `--save -` emite solo el Markdown por stdout.

### Informes guardados

Cada auditoría guardada crea **dos ficheros con la misma base**:

```text
reports/watch4me_arch_cosmic_24_10_2026_17_48.md
reports/watch4me_arch_cosmic_24_10_2026_17_48.json
```

El nombre usa barras bajas y la fecha en orden día, mes y año. Si ya existe un informe de ese minuto, se añaden los segundos (y un contador si hiciera falta) comprobando siempre `.md` y `.json`: **nunca se sobrescribe** un informe anterior.

El JSON incluye metadatos de la herramienta y del equipo, fecha ISO 8601, perfil (`profile`, `profile_label`, `profile_description`), uso de `root`/`sudo`, duración, código de salida, score global, contadores, una entrada por dominio y un array `checks` con `id`, severidad, estado, descripción, detalle, evidencia y remedio sugerido. `checks_total` es el número de checks ejecutados por el perfil y `checks_catalog` el total del catálogo; `checks_excluded` enumera los que quedaron fuera. Está formateado y es válido sin necesidad de `jq` ni `python`.

## Catálogo de checks (74)

Los IDs siguen el formato `DOMINIO-NN`. `explain` muestra la descripción completa, los perfiles y el remedio sugerido de cada uno.

Perfiles: **S** servidor · **C** cliente · **D** doméstico · **E** esencial · `—` solo general. `general` incluye siempre todos.

### Sistema (SYS)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `SYS-01` | media | Sincronización del reloj | S C D |
| `SYS-02` | alta | Actualizaciones pendientes | S C D E |
| `SYS-03` | media | Reinicio pendiente | S C D |
| `SYS-04` | alta | Parámetros sysctl de hardening | S C |
| `SYS-05` | media | Módulos de sistemas de ficheros innecesarios | S |
| `SYS-06` | baja | Reloj del hardware en UTC | C |
| `SYS-07` | media | Secure Boot | C D |
| `SYS-08` | alta | Mitigaciones de vulnerabilidades de CPU | S C D |
| `SYS-09` | media | Opciones de montaje | S C |
| `SYS-10` | media | Integridad del kernel (taint) | S C |
| `SYS-11` | alta | Control de acceso obligatorio (AppArmor/SELinux) | S C |
| `SYS-12` | baja | Visibilidad de procesos (/proc) | S |
| `SYS-13` | media | Cifrado del disco del sistema | C D |
| `SYS-14` | media | Bloqueo automático de pantalla | C D |

### Usuarios (USR)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `USR-01` | crítica | Cuentas con UID 0 | S C D E |
| `USR-02` | crítica | Cuentas con contraseña vacía | S C D E |
| `USR-03` | media | Cuentas de sistema con shell interactiva | S |
| `USR-04` | alta | Algoritmos de hash de contraseñas débiles | S C D E |
| `USR-05` | alta | Configuración de sudoers | S C |
| `USR-06` | alta | Grupo root sin miembros adicionales | S |
| `USR-07` | media | Caducidad de contraseñas | S |
| `USR-08` | baja | UMASK por defecto | S |
| `USR-09` | media | UID y nombres de usuario duplicados | S C D |
| `USR-10` | baja | Permisos de los directorios home | S C D |
| `USR-11` | media | Inicio de sesión automático y cuenta invitado | C D |

### Red (NET)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `NET-01` | alta | Puertos a la escucha expuestos | S C D E |
| `NET-02` | alta | Firewall activo | S C D E |
| `NET-03` | media | Reenvío de paquetes | S |
| `NET-04` | alta | Servicios de red obsoletos o innecesarios | S |
| `NET-05` | media | Política por defecto del firewall | S C D |
| `NET-06` | media | Interfaces en modo promiscuo | S |
| `NET-07` | media | SSH escuchando en todas las interfaces | S |
| `NET-08` | media | Contenedores con red host | S |
| `NET-09` | alta | Seguridad de las redes Wi-Fi guardadas | C D |

### Servicios (SVC)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `SVC-01` | media | Unidades systemd fallidas | S C D E |
| `SVC-02` | media | Servicios obsoletos habilitados al arranque | S |
| `SVC-03` | media | Algoritmos débiles en SSH | S |
| `SVC-04` | media | Protección contra fuerza bruta SSH | S |
| `SVC-05` | alta | Contenedores privilegiados y socket de Docker | S |
| `SVC-06` | media | Auditoría del kernel (auditd) | S |
| `SVC-07` | alta | Configuración del servidor SSH | S |
| `SVC-08` | media | Persistencia de los logs de systemd | S |

### Ficheros (FS)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `FS-01` | baja | Particiones separadas | S |
| `FS-02` | crítica | Permisos de las bases de usuarios | S C D E |
| `FS-03` | alta | Binarios SUID/SGID fuera del sistema | S C D |
| `FS-04` | alta | Permisos de ficheros sensibles | S C D |
| `FS-05` | media | Ficheros escribibles por cualquier usuario | S C D |
| `FS-06` | media | Ficheros sin propietario o grupo | S |
| `FS-07` | media | Sticky bit en directorios temporales | S C D E |
| `FS-08` | media | Permisos de /root y /etc/skel | S |
| `FS-09` | alta | Ficheros de confianza heredados | S C D |
| `FS-10` | media | Permisos de los logs del sistema | S |

### Autenticación (AUTH)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `AUTH-01` | alta | Política de autenticación PAM | S C D |
| `AUTH-02` | alta | Estado de la contraseña de root | S C D E |
| `AUTH-03` | media | Política de contraseñas en login.defs | S |
| `AUTH-04` | media | Contraseña de arranque de GRUB | C D |
| `AUTH-05` | media | Parámetros de bloqueo por intentos fallidos | S |
| `AUTH-06` | baja | Historial de contraseñas | S |
| `AUTH-07` | baja | Bloqueo de sesión inactiva | S |
| `AUTH-08` | baja | Banner de advertencia en el login | S |

### Integridad (INT)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `INT-01` | media | Monitorización de integridad de ficheros | S |
| `INT-02` | alta | Verificación de paquetes instalados | S |
| `INT-03` | alta | Permisos de cron y at | S C D |
| `INT-04` | alta | Unidades systemd con ejecutables en rutas escribibles | S C D |
| `INT-05` | alta | Claves autorizadas de root | S |
| `INT-06` | alta | Capacidades de ficheros | S |
| `INT-07` | alta | Directorios escribibles en PATH | S C D E |

### Malware y persistencia (MAL)

| ID | Severidad | Check | Perfiles |
|---|---|---|---|
| `MAL-01` | crítica | Precarga de bibliotecas (ld.so.preload) | S C D E |
| `MAL-02` | alta | Ejecutables borrados en ejecución | S C D |
| `MAL-03` | media | Ejecutables en directorios temporales | S C D E |
| `MAL-04` | alta | Patrones de persistencia sospechosos | S C D E |
| `MAL-05` | alta | Procesos a la escucha desde rutas temporales | S C D |
| `MAL-06` | alta | Rutas no estándar en ld.so.conf | S |
| `MAL-07` | media | Módulos del kernel fuera de rutas estándar | S |

Cada check emite `PASS`, `WARN`, `FAIL`, `SKIP` o `INFO`, con evidencia y remedio sugerido.

## Puntuación

Pesos por severidad: `critical 10 · high 7 · medium 4 · low 2 · info 0`.

```text
score = 100 * (posible - penalización) / posible
penalización = peso(FAIL) + peso(WARN)/2
```

`SKIP` e `INFO` no puntúan. Se calcula el score global y uno por dominio; el informe muestra ambos. El cálculo usa solo los checks del perfil activo, no los 74 del catálogo: `servidor`, `cliente`, `domestico` y `esencial` se puntúan sobre su propia selección.

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
WATCH4ME_ALLOW_PORTS="22 443 8080" ./watch4me.sh audit
```

Los puertos de alto riesgo (21, 23, 445, 3389, 5900, 6379, 27017…) marcan `FAIL`. `watch` usa su propia lista de puertos peligrosos y no lee esta variable. `NET-01` comparte con `watch` la clasificación de sockets: loopback y puentes virtuales (`virbr*`, `docker*`, `br-*`, `vnet*`…) no cuentan como expuestos.

## Seguridad del propio script

- Las auditorías no escriben fuera de `reports/` y `state/tmp/` (este último se borra al salir). `watch` tampoco escribe fuera de `state/tmp/`.
- `baseline` guarda una referencia persistente en `state/baseline/<host>/` (`baseline.tsv` y `baseline.meta`, modo `600` y directorios `700`). Solo contiene el resultado de la auditoría; no guarda puertos, servicios, ficheros ni procesos. `monitor` escribe su ejecución temporal en `state/tmp/`.
- `WATCH4ME_STATE_DIR` permite mover todo el estado interno (útil en pruebas); si lo usas, protege esa ruta igual que `state/`.
- Las auditorías, `baseline`, `monitor` y la vigilancia no instalan, no modifican configuración, no bloquean tráfico y no envían datos.
- **Única excepción:** el menú ofrece instalar `fzf` con el gestor de la distribución. Solo ocurre tras confirmación explícita (`[s/N]`, por defecto no) y es la única escritura en el sistema. `WATCH4ME_NO_INSTALL=1` lo impide.
- No usa `eval` ni ejecuta contenido de ficheros analizados.
- Con `--sudo` solo ejecuta lecturas (`cat`, `stat`, `ss`, `find`, `readlink`, `grep`, `getcap`, `modinfo`, `nft list`, `iptables -S`, `sshd -T`, `pacman -Qkk`, `debsums -s`, `rpm -Va`) mediante `sudo -n`.
- No pide contraseña durante la auditoría, `baseline`, `monitor` ni la vigilancia: si `sudo -n` falla, el check se omite con `SKIP` o se muestra menos información.

## Pruebas

La suite no necesita dependencias nuevas, crea su propio directorio temporal y aísla el estado con `WATCH4ME_STATE_DIR`; no toca `reports/` ni `state/baseline/` reales:

```sh
./tests/run-tests.sh
```

Cubre catálogo, perfiles, scoring, contrato de checks, clasificación de `watch` y `NET-01`, baseline y comparación de cambios, menú, CLI e informes. Si `shellcheck` está disponible, se ejecuta como una prueba más; también se puede indicar su ruta:

```sh
SHELLCHECK=/ruta/a/shellcheck ./tests/run-tests.sh
```

La suite omite `shellcheck` si no está instalado. Se validó con el binario estático 0.10.0.

## Estructura

```text
watch4me.sh              CLI, modos y flujo de auditoría
lib/ui.sh                colores y cabecera animada
lib/menu.sh              menú fzf, perfiles, vista previa y ayuda
lib/profiles.sh          selección de checks por perfil
lib/watch.sh             vigilancia de conexiones, servicios y persistencia
lib/baseline.sh          baseline de auditoría, comparación y monitor
lib/common.sh            utilidades y directorio de estado
lib/distro.sh            detección de familia
lib/family/*.sh          adaptadores por distribución
lib/checks.sh            registro, estado y scoring
lib/render-term.sh       salida en pantalla
lib/render-md.sh         informe Markdown
lib/render-json.sh       informe JSON estructurado
checks/*.sh              74 checks en 8 dominios
tests/run-tests.sh       suite de regresión (Bash puro)
reports/                 informes generados (.md y .json)
state/tmp/               ejecuciones temporales (se borra al salir)
state/baseline/<host>/   baseline de auditoría (una por host)
```

## Roadmap

- **M1** ✅ CLI, cabecera animada, 12 checks, informes y licencia
- **M2** ✅ catálogo de 70 checks, scoring por dominio, `explain --list` / múltiples IDs y pulido de salida (v0.3.0)
- **M2.5** ✅ menú interactivo con fzf, vista previa por acción y ayuda de atajos (v0.4.0)
- **M2.6** ✅ informes Markdown + JSON, nombres sin guiones y sin sobrescrituras (v0.5.0)
- **M2.7** ✅ cinco perfiles por tipo de equipo y vigilancia en vivo `watch` (v0.6.0)
- **M4** ✅ documentación, tests y `shellcheck` limpio (v0.6.1, adelantado a M3)
- **M3** ✅ baseline de auditoría y `monitor` de una sola ejecución; compara estados y score, sin timer ni notificaciones (v0.7.0)
- **M5** ✅ menú principal agrupado en submenús, ayudas ampliadas y catálogo navegable con fzf sin paginador externo (v0.8.0)
- **Pendiente**: notificaciones de sistema (`notify-send` / journal) y timer de usuario para `monitor`; no forman parte de M3

## Licencia

GPLv3. Ver [LICENSE](LICENSE).

La cabecera animada (cambio de color y redibujado con `\e[H`/`\e[K`) deriva de
[dash4me](https://github.com/DanSanMar/dash4me), Copyright (C) DanSanMar, GPLv3.
