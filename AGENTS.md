# AGENTS.md — watch4me

Auditoría de seguridad local en Bash, **solo lectura**, multi-distro. Estado actual: **M2.7 + M3 + M4 + M5 / v0.8.0** (74 checks, 8 dominios, cinco perfiles, vigilancia en vivo `watch`, baseline de auditoría y `monitor`, menú fzf agrupado con submenús y catálogo navegable, informes Markdown + JSON, resumen ejecutivo, guía de actuación, suite de pruebas y `shellcheck` limpio). Repo: rama `Security-Scripts-Bash`, remoto `DanSanMar/watch4me`.

## Invariantes (no romper)

- **Nunca modificar el sistema.** Los remedios son texto orientativo. Las escrituras van a `reports/`, `state/tmp/` (este último se borra al salir desde `ui_restore`) y `state/baseline/` (solo `baseline`, persistente); `--save <ruta>` es la única excepción explícita del usuario. `watch` también es solo lectura y escribe únicamente en `state/tmp/`. `WATCH4ME_STATE_DIR` mueve todo el estado interno y se usa en pruebas para no tocar `state/`. **Excepción acotada:** el menú puede instalar `fzf` con el gestor nativo solo tras confirmación interactiva (`[s/N]`, por defecto no) y usando `sudo`/`doas`; `WATCH4ME_NO_INSTALL=1` lo impide. La ruta de auditoría (`audit`) no instala nada.
- **Baseline y monitor.** Una baseline por host en `state/baseline/<host>/baseline.tsv` y `.meta` (schema `watch4me.baseline/v1`), con ficheros `600` y directorios `700`, escritura atómica. Guarda **solo auditoría** (estado, detalle, severidad, score y metadatos); nunca puertos, servicios, ficheros ni procesos. El perfil queda guardado: `monitor` lo reutiliza y rechaza un `--profile` distinto; si la baseline usó `--sudo`, reintenta `sudo -n` sin pedir contraseña. `baseline` sale `0`/`64`; `monitor` sale `0` sin regresiones, `1` con regresión o pérdida de cobertura (omitidos o retirados), `2` con fallo crítico nuevo y `64` sin baseline, baseline incompatible o perfil distinto. Sin TTY, `baseline` exige `--force` para sobrescribir. No guardan informes `.md`/`.json` (`--save` se rechaza) y **no hay timer ni notificaciones** en M3.
- **Bash >= 4.4**, sin dependencias obligatorias: nada de `jq`, `python` ni red. Las herramientas opcionales se comprueban con `have`; si faltan o no hay privilegios, el check emite **SKIP**, nunca FAIL. `watch` necesita `ss` (iproute2) y sale con 64 si no está.
- **Todo el texto de usuario en español** (títulos, detalles, remedios, README, ayuda). Nuevos ficheros con cabecera GPLv3; no eliminar la atribución a [dash4me](https://github.com/DanSanMar/dash4me) de la animación.
- **Contrato de checks**: `register_check ID sev titulo funcion desc remed` a nivel de fichero + `emit`/`ev` dentro de la función. La función usa `local id=$CURRENT_ID`, no recibe argumentos y debe llamar a `emit` exactamente una vez; si no, el runner lo marca SKIP.
- **stdout/stderr de un check se descarta** (`run_single_check` ejecuta `( fn ) >/dev/null 2>&1`). Para depurar no sirve `echo`: usa `ev` o el informe. Los checks corren en subshell, así que no pueden mutar estado del padre.
- **`emit` aplana el detalle a una línea y lo corta a 400 caracteres**; la información importante va ahí. `ev` añade evidencia multilínea, que se renderiza en Markdown y en JSON (máx. 12 líneas); el terminal muestra únicamente el detalle.
- El script usa `set -uo pipefail` **sin `-e`**: cada check maneja sus propios fallos (`|| true`) y debe proteger variables no definidas (`${VAR:-}`).
- **Salida limpia**: 0 ANSI cuando no hay TTY o con `--no-color`/`NO_COLOR`; los iconos Unicode se reservan para UTF-8/TTY y deben tener fallback ASCII. `--save -` escribe **solo Markdown** por stdout: nada de cabecera, animación ni mensajes.
- **`--sudo` solo usa `sudo -n`** y nunca pide contraseña. Usa `sudo_ok`, `as_root` y `rootread`; no llames a `sudo` directamente. `watch` reutiliza `watch_ss`/`watch_proc_exe` para esto.
- **Códigos de salida**: `0` limpio, `1` WARN o FAIL no crítico, `2` FAIL crítico, `64` uso incorrecto o modo no disponible. En `watch --once`/captura única se aplican 0/1/2; la pantalla en vivo termina con 0 al salir con `Ctrl-C`; sin `ss`, 64.
- **Scoring**: pesos `critical 10 / high 7 / medium 4 / low 2 / info 0`; penalización `FAIL = peso`, `WARN = peso/2`; SKIP e INFO no puntúan. Se calcula **solo sobre `ACTIVE_CHECK_IDS`**, no sobre el catálogo completo.
- **Perfiles**: `CHECK_IDS` es el catálogo completo (74, para `explain`, menú y fichas); `ACTIVE_CHECK_IDS` es el subconjunto del perfil. `profile_set` debe ejecutarse **después de `load_checks`** y antes de `run_checks`, scoring, render o exit code. Al añadir un check, decide su pertenencia a `servidor`/`cliente`/`domestico`/`esencial` y actualiza las listas de `lib/profiles.sh`; `general` siempre lo incluye. Los alias `full`→`general` y `quick`→`esencial` se mantienen por compatibilidad.
- **Escaneos pesados** con `with_timeout "$(scan_timeout)"`: `general`, `servidor`, `cliente` y `domestico` usan 30 s; `esencial` usa 8 s. `pkg_timeout` reduce los timeouts de paquetes en `esencial` (mínimo 5 s). No hay ramas especiales por `quick` dentro de los checks.

## Flujo

`watch4me.sh`: `parse_args` → `ui_init` → `ui_trap_install` → `detect_distro` → modo. En `audit`: `load_checks` (sourcea `checks/*.sh` en orden de glob) → `profile_set` → `init_run_dir` → `run_checks` (subshell en segundo plano con fichero `progress`, solo `ACTIVE_CHECK_IDS`) → `compute_scores` → `render_terminal` → `compute_exit_code` (guarda `EXIT_CODE`) → `maybe_save`. En `baseline`: `load_checks` → `profile_set` → `init_run_dir` → `run_checks` → `compute_scores` → `compute_exit_code` → `baseline_save` (o `baseline_show` con `--show`, que no ejecuta checks). En `monitor`: `baseline_load_meta`/`baseline_load_checks` → `profile_set` con el perfil guardado → auditoría de `ACTIVE_CHECK_IDS` → `baseline_compare` → `baseline_exit_code` → `baseline_render`. En `menu`: `load_checks` → `menu_main` (bucle fzf de siete entradas); cada submenú llama a `menu_run_audit`, `menu_baseline`, `menu_monitor`, `menu_watch`, `menu_reports` o al catálogo, que reutilizan el flujo correspondiente y limpian `RUN_DIR` entre ejecuciones. En `watch`: `parse_args` valida `--interval`/`--once` → `watch_main` comprueba `ss`, captura, analiza y elige pantalla en vivo o captura única. `__preview <tipo> <arg>` es un modo interno para el panel de vista previa de fzf. Sin argumentos y con TTY, el modo por defecto es `menu`; sin TTY, `audit`.

- `lib/checks.sh`: registro, estado en `$RUN_DIR/ID.status|detail|evidence`, scoring, exit codes e iconos. Scoring y exit code usan `ACTIVE_CHECK_IDS` con caída al catálogo si aún no se ha aplicado un perfil.
- `lib/profiles.sh`: definición de perfiles (`PROFILE_ESENCIAL`, `PROFILE_SERVIDOR_EXCLUDE`, `PROFILE_CLIENTE_EXCLUDE`, `PROFILE_DOMESTICO`), alias, etiquetas, `profile_applies`, `profile_tags`, `profile_select`, `profile_count` y `profile_set`. Las listas son multilínea y `in_list` las trata como separadores.
- `lib/watch.sh`: capturas con `ss -tulpnH` / `ss -tunpH`, `systemctl`, `stat` y `/proc`. Vigila puertos, conexiones, servicios, procesos y ficheros críticos; genera hallazgos y eventos de cambio. Los sockets en loopback o en puentes virtuales del host (`virbr*`, `docker*`, `br-*`, `vnet*`…) se etiquetan `local`/`virtual` y no cuentan como expuestos; se conserva el ámbito `%interfaz`. `NET-01` reutiliza esta clasificación. La pantalla en vivo exige TTY y color (`WATCH_LIVE`); sin ello hace una captura única y avisa por stderr. No guarda informes.
- `lib/baseline.sh`: baseline de auditoría en `$(state_dir)/baseline/<host>/` con `baseline.tsv` (`id<TAB>status<TAB>severity<TAB>title<TAB>detail`) y `baseline.meta` (`schema=watch4me.baseline/v1`). `baseline_save` escribe temporales y renombra; `baseline_load_meta`/`baseline_load_checks` leen y validan. `--show` no ejecuta checks. `baseline_compare` clasifica empeoran, omitidos, se evalúan, nuevos, mejoran y retirados, además del delta de score; `baseline_exit_code` aplica 0/1/2 y `baseline_render` pinta el resultado. `baseline_main` y `monitor_main` orquestan los modos; el perfil y el uso de sudo quedan en los metadatos.
- `lib/ui.sh`: color/animación y progreso. La animación se activa con TTY, color, ancho >= 36 y sin `--no-anim`; por debajo de 70 columnas usa una cabecera compacta. La línea del logo incluye fecha/hora (y host solo en modo `menu`) según el ancho; en compacta sustituye el subtítulo por hora/fecha. La animación de auditoría dura al menos `UI_ANIM_MIN_MS` y se mantiene `UI_ANIM_TAIL_MS` al terminar los checks, sin cambiar la velocidad de frame. Sin animación pero con TTY, `ui_progress_frame` mantiene una línea de progreso. Los traps restauran cursor, limpian la línea y borran `RUN_DIR`. Con `--save -` se activa `UI_QUIET` y no se emite nada por stdout salvo el Markdown.
- `lib/menu.sh`: menú fzf (`menu_main`), submenús por grupo, filas con campo oculto para la vista previa (`__preview action|check|domain|report|help <arg>`) y autoinstalación de fzf. Las filas usan `texto<TAB>valor` (tabulador como delimitador invisible); el panel derecho se genera en un subproceso del propio script. El menú principal tiene siete entradas: Auditorías (cinco perfiles con contadores dinámicos), Historial y cambios (baseline, baseline --show, monitor e informes), Vigilancia (watch y watch --once), Catálogo y fichas (buscar, dominios y catálogo completo), toggle `MENU_SUDO` (se aplica a auditorías, `baseline`, `monitor` y `watch`; la fila indica «sin caché» si `sudo -n` no está disponible), Ayuda y Salir. Los submenús reutilizan `menu_header` (contexto y explicación breve), `menu_pick_row` (ESC/Ctrl-C/error = volver) y una fila «Volver»; el catálogo completo se navega con fzf y **no** con `less`, para que ESC vuelva y la sesión no quede atrapada. Los informes sí usan `menu_pager` (`less -R -F -X -P`), con `q` para volver. El logo de la cabecera se redibuja cada 3 s con la tabla de colores de `dash4me.sh` calculada a partir del segundo actual y, en modo `menu`, añade fecha/hora y host según `UI_DT_MIN_WIDTH`/`UI_HOST_MIN_WIDTH` (el host no se repite en la segunda línea) (`menu_logo_start`, en el menú principal y en las cabeceras de grupo; se detiene antes de lanzar una acción o tras cada fzf). Los traps del menú paran el animador y muestran `menu_exit_msg` al salir con ESC, Ctrl-C, TERM o HUP; la salida normal usa el mismo mensaje sin duplicarlo (`MENU_EXIT_SHOWN`). Respeta `--no-color`/`NO_COLOR` y `UI_UTF8`. `UI_ANIM` se restaura tras cada auditoría porque `ui_header_close` lo desactiva. La cabecera resume los grupos en lenguaje llano y `menu_fzf_height` reserva seis líneas para no tapar esa cabecera.
- `lib/distro.sh` + `lib/family/*.sh`: familia desde `/etc/os-release` (fallback por gestor). Cada adaptador define `FAMILY_LABEL`, `PKG_MGR` y `pkg_updates_report` (primera línea = nº de actualizaciones, resto = listado). Nueva capacidad → `pkg_update_supported` o guardas con `have`.
- `lib/render-term.sh`, `lib/render-md.sh` y `lib/render-json.sh`: **los tres** deben cubrir cualquier campo nuevo. El terminal es un resumen (resumen ejecutivo, fallos detallados, avisos en una línea, tabla por dominio y guía); el Markdown conserva el detalle completo, la evidencia y los remedios; el JSON (`watch4me.report/v1`) expone metadatos, perfil, catálogo, checks excluidos, score, dominios y el array de checks con los mismos datos. Los tres recorren `ACTIVE_CHECK_IDS`, no el catálogo. El orden de dominios (`SYS USR NET SVC FS AUTH INT MAL`) está hardcodeado en los tres y en `explain_list`.
- `checks/NN-dominio.sh`: el prefijo numérico fija el orden de ejecución. ID = `DOMINIO-NN`; el dominio se deriva del prefijo.
- Informes: cada auditoría guardada escribe dos ficheros con la misma base: `reports/watch4me_<host>_DD_MM_YYYY_HH_MM.md` y `.json`. `resolve_report_base` comprueba ambos antes de escribir y añade segundos/contador si hay colisión; `save_report` escribe a temporales y los renombra. `--save -` sigue emitiendo solo Markdown por stdout. `watch`, `baseline` y `monitor` no admiten `--save`; `baseline` guarda su propio estado y `monitor` no persiste informes.

## Añadir o cambiar un check

1. Implementa `check_xxx_NN` en el fichero del dominio con `local id=$CURRENT_ID`.
2. Registra con `register_check` (severidad `critical|high|medium|low|info`) y un remedio sugerido.
3. Usa los helpers: `have`, `is_root`, `sudo_ok`, `as_root`, `rootread`, `with_timeout`, `scan_timeout`, `under_path`, `interactive_users`, `user_home`, `firewall_state`, `unit_active`.
4. Decide su presencia en los perfiles y actualiza `lib/profiles.sh` (las listas explícitas o de exclusión). Comprueba el reparto con `./watch4me.sh explain --list`.
5. Actualiza el catálogo, los contadores y las etiquetas de perfil del README si cambia el número de checks; sube `VERSION` en `watch4me.sh` al cerrar un hito.

## Validación

```sh
# Suite completa (Bash puro; shellcheck opcional)
./tests/run-tests.sh
SHELLCHECK=/ruta/a/shellcheck ./tests/run-tests.sh   # incluye lint si se indica

# ShellCheck directo (si está instalado)
shellcheck -x watch4me.sh lib/*.sh lib/family/*.sh checks/*.sh tests/*.sh

# Sintaxis de todo
for f in watch4me.sh lib/*.sh lib/family/*.sh checks/*.sh tests/*.sh; do bash -n "$f" || exit 1; done

# Auditoría no interactiva: 74 checks, exit 0/1/2, 0 ANSI
./watch4me.sh audit --no-anim --no-color > /tmp/opencode/out.txt; echo "exit=$?"
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/out.txt   # debe imprimir 0

# Sin argumentos y sin TTY también debe auditar (no abrir menú)
./watch4me.sh > /tmp/opencode/out-default.txt; echo "exit=$?"

# Los cinco perfiles y los alias antiguos
./watch4me.sh audit --profile general   --no-anim --no-color
./watch4me.sh audit --profile servidor  --no-anim --no-color
./watch4me.sh audit --profile cliente   --no-anim --no-color
./watch4me.sh audit --profile domestico --no-anim --no-color
./watch4me.sh audit --profile esencial  --no-anim --no-color
./watch4me.sh audit --profile full      --no-anim --no-color
./watch4me.sh audit --profile quick     --no-anim --no-color

# Markdown limpio por stdout y JSON válido
./watch4me.sh audit --no-anim --no-color --save - > /tmp/opencode/report.md
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/report.md # debe imprimir 0
./watch4me.sh audit --no-anim --no-color --save /tmp/opencode/report
# Si tienes jq instalado, valida el esquema y los contadores:
jq -e '.schema == "watch4me.report/v1" and .run.checks_catalog == 74' /tmp/opencode/report.json

# Perfil con privilegios
./watch4me.sh audit --profile servidor --no-anim --no-color --sudo

# Vigilancia: captura única sin TTY (0 ANSI) y con privilegios
./watch4me.sh watch --once --no-color > /tmp/opencode/watch.txt; echo "exit=$?"
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/watch.txt # debe imprimir 0
./watch4me.sh watch --once --sudo --no-color

# Baseline y monitor con estado aislado (no toca state/ ni crea baseline real)
rm -rf /tmp/opencode/w4m-state
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh baseline --profile esencial --no-anim --no-color
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh baseline --show --no-anim --no-color
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh monitor --no-anim --no-color; echo "exit=$?"
# Sin TTY exige --force para sobrescribir; --show no audita; --save se rechaza
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh baseline --profile esencial --no-anim --no-color; echo "exit=$? (64)"
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh baseline --profile esencial --force --no-anim --no-color; echo "exit=$? (0)"
WATCH4ME_STATE_DIR=/tmp/opencode/w4m-state ./watch4me.sh baseline --profile esencial --no-anim --no-color --save; echo "exit=$? (64)"

# Menú: fuera de TTY sale 64; la vista previa es texto plano
./watch4me.sh menu; echo "exit=$? (64 esperado sin TTY)"
./watch4me.sh __preview action audit-profiles
./watch4me.sh __preview action history
./watch4me.sh __preview action watch-menu
./watch4me.sh __preview action catalog-menu
./watch4me.sh __preview action audit-general
./watch4me.sh __preview action audit-servidor
./watch4me.sh __preview action baseline
./watch4me.sh __preview action baseline-show
./watch4me.sh __preview action monitor
./watch4me.sh __preview action watch
./watch4me.sh __preview action watch-once
./watch4me.sh __preview action catalog-domains
./watch4me.sh __preview action catalog-all
./watch4me.sh __preview domain SYS
./watch4me.sh __preview help menu-map
./watch4me.sh __preview help safety
./watch4me.sh __preview help baseline
./watch4me.sh __preview help monitor
./watch4me.sh __preview check SYS-13
```

En TTY, comprueba a mano que `./watch4me.sh` abre el menú principal de siete entradas, que cada grupo abre su submenú, que las filas de perfil ejecutan la auditoría correcta, que el toggle de sudo cambia de estado, que `ESC` vuelve un nivel (y sale desde el principal), que «Volver» hace lo mismo, que el catálogo completo se navega con fzf sin paginador externo (ESC vuelve al catálogo), que los informes abren `less` y `q` vuelve, que `watch` redibuja la pantalla y se detiene con `Ctrl-C` sin dejar la terminal sucia, que «Crear baseline» pide confirmación si ya existe, que «Ver baseline guardada» no ejecuta checks y que «Monitorizar cambios» usa el perfil guardado. El panel de vista previa se puede probar sin fzf con `__preview`.

Al terminar, borra `reports/watch4me_*` de prueba (`.md` y `.json`) y comprueba que `state/tmp` queda vacío. Los datos de baseline de las pruebas viven en `/tmp/opencode/w4m-state`; no borres una baseline real de `state/baseline/` sin permiso. La suite usa un `WATCH4ME_STATE_DIR` temporal. La suite omite `shellcheck` si no está instalado; se validó con el binario estático 0.10.0. Los arrays de las librerías usan `declare -g` para poder cargarse dentro de funciones (subshells de la suite).

## Estado conocido del equipo de referencia

Arch Linux. En la última medición `sudo -n` no tenía caché (`sudo: no (sin caché)`), así que `--sudo` no añadió lecturas. Última auditoría general: **75/100 sin sudo, exit 1**; 74 checks, 32 PASS / 22 WARN / 5 FAIL / 13 SKIP / 2 INFO. Los 5 FAIL actuales son reales y no regresiones: SYS-04 (sysctl), SYS-09 (opciones de montaje), SYS-11 (sin AppArmor/SELinux), USR-06 (miembro `brltty` en el grupo root) e INT-06 (capacidades de `btop`). No los "arregles" en el código. Los avisos cambian con el estado del equipo (actualizaciones pendientes, permisos de `/root`, temporales); no son parte del menú.

Perfiles medidos en el mismo equipo: `servidor` 67 checks (exit 1), `cliente` 41 (exit 1), `domestico` 35 (exit 1), `esencial` 14 (93/100, exit 1 por SYS-02 y MAL-03; puede salir 0 cuando el equipo está al día). `watch --once` funciona sin TTY con 0 ANSI. La suite v0.8.0 tiene 29 pruebas: sin `shellcheck` pasan 28 y se omite 1; con el binario 0.10.0 pasan las 29.
