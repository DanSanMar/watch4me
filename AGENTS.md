# AGENTS.md — watch4me

Auditoría de seguridad local en Bash, **solo lectura**, multi-distro. Estado actual: **M2 / v0.3.0** (70 checks, 8 dominios, resumen ejecutivo y guía de actuación). Repo: rama `Security-Scripts-Bash`, remoto `DanSanMar/watch4me`.

## Invariantes (no romper)

- **Nunca modificar el sistema.** Los remedios son texto orientativo. Las escrituras van a `reports/` y `state/tmp/` (este último se borra al salir desde `ui_restore`); `--save <ruta>` es la única excepción explícita del usuario.
- **Bash >= 4.4**, sin dependencias obligatorias: nada de `jq`, `python` ni red. Las herramientas opcionales se comprueban con `have`; si faltan o no hay privilegios, el check emite **SKIP**, nunca FAIL.
- **Todo el texto de usuario en español** (títulos, detalles, remedios, README, ayuda). Nuevos ficheros con cabecera GPLv3; no eliminar la atribución a [dash4me](https://github.com/DanSanMar/dash4me) de la animación.
- **Contrato de checks**: `register_check ID sev titulo funcion desc remed` a nivel de fichero + `emit`/`ev` dentro de la función. La función usa `local id=$CURRENT_ID`, no recibe argumentos y debe llamar a `emit` exactamente una vez; si no, el runner lo marca SKIP.
- **stdout/stderr de un check se descarta** (`run_single_check` ejecuta `( fn ) >/dev/null 2>&1`). Para depurar no sirve `echo`: usa `ev` o el informe. Los checks corren en subshell, así que no pueden mutar estado del padre.
- **`emit` aplana el detalle a una línea y lo corta a 400 caracteres**; la información importante va ahí. `ev` añade evidencia multilínea, pero solo se renderiza en Markdown (máx. 12 líneas); el terminal muestra únicamente el detalle.
- El script usa `set -uo pipefail` **sin `-e`**: cada check maneja sus propios fallos (`|| true`) y debe proteger variables no definidas (`${VAR:-}`).
- **Salida limpia**: 0 ANSI cuando no hay TTY o con `--no-color`/`NO_COLOR`; los iconos Unicode se reservan para UTF-8/TTY y deben tener fallback ASCII. `--save -` escribe **solo Markdown** por stdout: nada de cabecera, animación ni mensajes.
- **`--sudo` solo usa `sudo -n`** y nunca pide contraseña. Usa `sudo_ok`, `as_root` y `rootread`; no llames a `sudo` directamente.
- **Códigos de salida**: `0` limpio, `1` WARN o FAIL no crítico, `2` FAIL crítico, `64` uso incorrecto o modo no disponible.
- **Scoring**: pesos `critical 10 / high 7 / medium 4 / low 2 / info 0`; penalización `FAIL = peso`, `WARN = peso/2`; SKIP e INFO no puntúan.
- **Escaneos pesados** con `with_timeout "$(scan_timeout)"` (quick 8 s, full 30 s). En `quick`, INT-02 se omite y `pkg_timeout` reduce timeouts.

## Flujo

`watch4me.sh`: `parse_args` → `ui_init` → `ui_trap_install` → `detect_distro` → modo. En `audit`: `load_checks` (sourcea `checks/*.sh` en orden de glob) → `init_run_dir` → `run_checks` (subshell en segundo plano con fichero `progress`) → `compute_scores` → `render_terminal` → `maybe_save` → `compute_exit_code`.

- `lib/checks.sh`: registro, estado en `$RUN_DIR/ID.status|detail|evidence`, scoring, exit codes e iconos.
- `lib/ui.sh`: color/animación y progreso. La animación se activa con TTY, color, ancho >= 36 y sin `--no-anim`; por debajo de 70 columnas usa una cabecera compacta. Sin animación pero con TTY, `ui_progress_frame` mantiene una línea de progreso. Los traps restauran cursor, limpian la línea y borran `RUN_DIR`. Con `--save -` se activa `UI_QUIET` y no se emite nada por stdout salvo el Markdown.
- `lib/distro.sh` + `lib/family/*.sh`: familia desde `/etc/os-release` (fallback por gestor). Cada adaptador define `FAMILY_LABEL`, `PKG_MGR` y `pkg_updates_report` (primera línea = nº de actualizaciones, resto = listado). Nueva capacidad → `pkg_update_supported` o guardas con `have`.
- `lib/render-term.sh` y `lib/render-md.sh`: **ambos** deben cubrir cualquier campo nuevo. El terminal es un resumen (resumen ejecutivo, fallos detallados, avisos en una línea, tabla por dominio y guía); el Markdown conserva el detalle completo, la evidencia y los remedios. El orden de dominios (`SYS USR NET SVC FS AUTH INT MAL`) está hardcodeado en ambos renderizadores y en `explain_list`.
- `checks/NN-dominio.sh`: el prefijo numérico fija el orden de ejecución. ID = `DOMINIO-NN`; el dominio se deriva del prefijo.
- Informes: `reports/watch4me-<host>-YYYYmmdd-HHMM.md`. `baseline` y `monitor` son stubs intencionales que salen con 64 hasta M3.

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
./watch4me.sh --no-anim --no-color > /tmp/opencode/out.txt; echo "exit=$?"
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/out.txt   # debe imprimir 0

# Markdown limpio por stdout
./watch4me.sh --no-anim --no-color --save - > /tmp/opencode/report.md
perl -0777 -ne 'print scalar(() = /\e\[/g)' /tmp/opencode/report.md # debe imprimir 0

# Perfil rápido (≈5 s) y con privilegios
./watch4me.sh --profile quick --no-anim --no-color
./watch4me.sh --no-anim --no-color --sudo
```

Al terminar, borra `reports/watch4me-*.md` de prueba y comprueba que `state/tmp` queda vacío. `shellcheck` **no está instalado** en el equipo de desarrollo; M4 lo contempla.

## Estado conocido del equipo de referencia

Arch Linux, `sudo -n` disponible. Última auditoría: **78/100 sin sudo y 79/100 con sudo, exit 1**. Los 4 FAIL actuales son reales y no regresiones: SYS-04 (sysctl), SYS-08 (`old_microcode=Vulnerable`), SYS-09 (opciones de montaje) y USR-05 (2 reglas NOPASSWD en `/etc/sudoers`). No los "arregles" en el código.
