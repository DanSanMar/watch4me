# AGENTS.md — watch4me

Auditoría de seguridad local en Bash, **solo lectura**, multi-distro. Estado actual: **M2.6 / v0.5.0** (70 checks, 8 dominios, menú fzf con vista previa, informes Markdown + JSON, resumen ejecutivo y guía de actuación). Repo: rama `Security-Scripts-Bash`, remoto `DanSanMar/watch4me`.

## Invariantes (no romper)

- **Nunca modificar el sistema.** Los remedios son texto orientativo. Las escrituras van a `reports/` y `state/tmp/` (este último se borra al salir desde `ui_restore`); `--save <ruta>` es la única excepción explícita del usuario. **Excepción acotada:** el menú puede instalar `fzf` con el gestor nativo solo tras confirmación interactiva (`[s/N]`, por defecto no) y usando `sudo`/`doas`; `WATCH4ME_NO_INSTALL=1` lo impide. La ruta de auditoría (`audit`) no instala nada.
- **Bash >= 4.4**, sin dependencias obligatorias: nada de `jq`, `python` ni red. Las herramientas opcionales se comprueban con `have`; si faltan o no hay privilegios, el check emite **SKIP**, nunca FAIL.
- **Todo el texto de usuario en español** (títulos, detalles, remedios, README, ayuda). Nuevos ficheros con cabecera GPLv3; no eliminar la atribución a [dash4me](https://github.com/DanSanMar/dash4me) de la animación.
- **Contrato de checks**: `register_check ID sev titulo funcion desc remed` a nivel de fichero + `emit`/`ev` dentro de la función. La función usa `local id=$CURRENT_ID`, no recibe argumentos y debe llamar a `emit` exactamente una vez; si no, el runner lo marca SKIP.
- **stdout/stderr de un check se descarta** (`run_single_check` ejecuta `( fn ) >/dev/null 2>&1`). Para depurar no sirve `echo`: usa `ev` o el informe. Los checks corren en subshell, así que no pueden mutar estado del padre.
- **`emit` aplana el detalle a una línea y lo corta a 400 caracteres**; la información importante va ahí. `ev` añade evidencia multilínea, que se renderiza en Markdown y en JSON (máx. 12 líneas); el terminal muestra únicamente el detalle.
- El script usa `set -uo pipefail` **sin `-e`**: cada check maneja sus propios fallos (`|| true`) y debe proteger variables no definidas (`${VAR:-}`).
- **Salida limpia**: 0 ANSI cuando no hay TTY o con `--no-color`/`NO_COLOR`; los iconos Unicode se reservan para UTF-8/TTY y deben tener fallback ASCII. `--save -` escribe **solo Markdown** por stdout: nada de cabecera, animación ni mensajes.
- **`--sudo` solo usa `sudo -n`** y nunca pide contraseña. Usa `sudo_ok`, `as_root` y `rootread`; no llames a `sudo` directamente.
- **Códigos de salida**: `0` limpio, `1` WARN o FAIL no crítico, `2` FAIL crítico, `64` uso incorrecto o modo no disponible.
- **Scoring**: pesos `critical 10 / high 7 / medium 4 / low 2 / info 0`; penalización `FAIL = peso`, `WARN = peso/2`; SKIP e INFO no puntúan.
- **Escaneos pesados** con `with_timeout "$(scan_timeout)"` (quick 8 s, full 30 s). En `quick`, INT-02 se omite y `pkg_timeout` reduce timeouts.

## Flujo

`watch4me.sh`: `parse_args` → `ui_init` → `ui_trap_install` → `detect_distro` → modo. En `audit`: `load_checks` (sourcea `checks/*.sh` en orden de glob) → `init_run_dir` → `run_checks` (subshell en segundo plano con fichero `progress`) → `compute_scores` → `render_terminal` → `compute_exit_code` (guarda `EXIT_CODE`) → `maybe_save`. En `menu`: `load_checks` → `menu_main` (bucle fzf); cada acción llama a `menu_run_audit`, que reutiliza el flujo de auditoría y limpia `RUN_DIR` entre ejecuciones. `__preview <tipo> <arg>` es un modo interno para el panel de vista previa de fzf. Sin argumentos y con TTY, el modo por defecto es `menu`; sin TTY, `audit`.

- `lib/checks.sh`: registro, estado en `$RUN_DIR/ID.status|detail|evidence`, scoring, exit codes e iconos.
- `lib/ui.sh`: color/animación y progreso. La animación se activa con TTY, color, ancho >= 36 y sin `--no-anim`; por debajo de 70 columnas usa una cabecera compacta. La línea del logo incluye fecha/hora (y host solo en modo `menu`) según el ancho; en compacta sustituye el subtítulo por hora/fecha. La animación de auditoría dura al menos `UI_ANIM_MIN_MS` y se mantiene `UI_ANIM_TAIL_MS` al terminar los checks, sin cambiar la velocidad de frame. Sin animación pero con TTY, `ui_progress_frame` mantiene una línea de progreso. Los traps restauran cursor, limpian la línea y borran `RUN_DIR`. Con `--save -` se activa `UI_QUIET` y no se emite nada por stdout salvo el Markdown.
- `lib/menu.sh`: menú fzf (`menu_main`), filas con campo oculto para la vista previa (`__preview action|check|report|help <arg>`) y autoinstalación de fzf. Las filas usan `texto<TAB>valor` (tabulador como delimitador invisible); el panel derecho se genera en un subproceso del propio script. El logo de la cabecera se redibuja cada 3 s con la tabla de colores de `dash4me.sh` calculada a partir del segundo actual y, en modo `menu`, añade fecha/hora y host según `UI_DT_MIN_WIDTH`/`UI_HOST_MIN_WIDTH` (el host no se repite en la segunda línea) (`menu_logo_start`, solo en el menú principal; se detiene al lanzar una acción). Los traps del menú paran el animador y muestran `menu_exit_msg` al salir con ESC, Ctrl-C, TERM o HUP; la salida normal usa el mismo mensaje sin duplicarlo (`MENU_EXIT_SHOWN`). Respeta `--no-color`/`NO_COLOR` y `UI_UTF8`. `UI_ANIM` se restaura tras cada auditoría porque `ui_header_close` lo desactiva.
- `lib/distro.sh` + `lib/family/*.sh`: familia desde `/etc/os-release` (fallback por gestor). Cada adaptador define `FAMILY_LABEL`, `PKG_MGR` y `pkg_updates_report` (primera línea = nº de actualizaciones, resto = listado). Nueva capacidad → `pkg_update_supported` o guardas con `have`.
- `lib/render-term.sh`, `lib/render-md.sh` y `lib/render-json.sh`: **los tres** deben cubrir cualquier campo nuevo. El terminal es un resumen (resumen ejecutivo, fallos detallados, avisos en una línea, tabla por dominio y guía); el Markdown conserva el detalle completo, la evidencia y los remedios; el JSON (`watch4me.report/v1`) expone metadatos, score, dominios y el array de checks con los mismos datos. El orden de dominios (`SYS USR NET SVC FS AUTH INT MAL`) está hardcodeado en los tres y en `explain_list`.
- `checks/NN-dominio.sh`: el prefijo numérico fija el orden de ejecución. ID = `DOMINIO-NN`; el dominio se deriva del prefijo.
- Informes: cada auditoría guardada escribe dos ficheros con la misma base: `reports/watch4me_<host>_DD_MM_YYYY_HH_MM.md` y `.json`. `resolve_report_base` comprueba ambos antes de escribir y añade segundos/contador si hay colisión; `save_report` escribe a temporales y los renombra. `--save -` sigue emitiendo solo Markdown por stdout. `baseline` y `monitor` son stubs intencionales que salen con 64 hasta M3.

## Añadir o cambiar un check

1. Implementa `check_xxx_NN` en el fichero del dominio con `local id=$CURRENT_ID`.
2. Registra con `register_check` (severidad `critical|high|medium|low|info`) y un remedio sugerido.
3. Usa los helpers: `have`, `is_root`, `sudo_ok`, `as_root`, `rootread`, `with_timeout`, `scan_timeout`, `under_path`, `interactive_users`, `user_home`, `firewall_state`, `unit_active`.
4. Actualiza el catálogo y los contadores del README si cambia el número de checks; sube `VERSION` en `watch4me.sh` al cerrar un hito.

## Validación (no hay suite de tests todavía)

```sh
# Sintaxis de todo
for f in watch4me.sh lib/*.sh lib/family/*.sh checks/*.sh; do bash -n "$f" || exit 1; done

# Auditoría no interactiva: 70 checks, exit 0/1/2, 0 ANSI
./watch4me.sh audit --no-anim --no-color > /tmp/opencode/out.txt; echo "exit=$?"
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/out.txt   # debe imprimir 0

# Sin argumentos y sin TTY también debe auditar (no abrir menú)
./watch4me.sh > /tmp/opencode/out-default.txt; echo "exit=$?"

# Markdown limpio por stdout
./watch4me.sh audit --no-anim --no-color --save - > /tmp/opencode/report.md
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/report.md # debe imprimir 0

# Perfil rápido (≈5 s) y con privilegios
./watch4me.sh audit --profile quick --no-anim --no-color
./watch4me.sh audit --no-anim --no-color --sudo

# Menú: fuera de TTY sale 64; la vista previa es texto plano
./watch4me.sh menu; echo "exit=$? (64 esperado sin TTY)"
./watch4me.sh __preview action audit-full
./watch4me.sh __preview check SYS-01
```

En TTY, comprueba a mano que `./watch4me.sh` abre el menú, que `ESC` vuelve/sale y que una acción ejecuta la auditoría y regresa al menú. El panel de vista previa se puede probar sin fzf con `__preview`.

Al terminar, borra `reports/watch4me_*` de prueba (`.md` y `.json`) y comprueba que `state/tmp` queda vacío. `shellcheck` **no está instalado** en el equipo de desarrollo; M4 lo contempla.

## Estado conocido del equipo de referencia

Arch Linux, `sudo -n` disponible. Última auditoría: **78/100 sin sudo y 80/100 con sudo, exit 1**. Los 4 FAIL actuales son reales y no regresiones: SYS-04 (sysctl), SYS-08 (`old_microcode=Vulnerable`), SYS-09 (opciones de montaje) y USR-05 (2 reglas NOPASSWD en `/etc/sudoers`). No los "arregles" en el código.
