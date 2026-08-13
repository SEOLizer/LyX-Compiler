# tests/lib/lyxc_guard.sh — Ressourcengrenze um jeden lyxc-Aufruf eines Tests.
#
# #1294: Die Testscripts kappten nur den PROGRAMMLAUF, nicht die UEBERSETZUNG.
# Ein lyxc, das wegen eines Compilerfehlers nicht zurueckkehrt oder unbegrenzt
# alloziert, frisst damit den Speicher der Maschine leer: der Kernel swappt,
# der X-Server haengt (die Maus friert zuerst ein), die Sitzung stirbt. Genau
# so passiert waehrend der Arbeit an #1154/#1155 — `make test` nahm den Desktop
# mit, und der eigentliche Defekt war danach nicht sichtbar, weil kein Log
# ueberlebte.
#
# Statt 126 Scripts an jeder Aufrufstelle umzuschreiben, wird hier LYXC selbst
# auf einen Wrapper umgebogen. Jedes vorhandene `"$LYXC" …` laeuft damit
# unveraendert weiter, nur eben unter Grenze und Zeitlimit.
#
# Verwendung — EINE Zeile, direkt nach der LYXC-Zuweisung:
#
#     LYXC="$ROOT/lyxc"
#     . "$ROOT/tests/lib/lyxc_guard.sh"
#
# Stellschrauben (vor dem Einbinden setzen):
#   LYXC_VM_KB    Adressraum in KB, Vorgabe 4194304 (4 GB)
#   LYXC_TIMEOUT  Sekunden je Aufruf, Vorgabe 60
#
# Wer die Compilerquelle selbst uebersetzt, braucht mehr:
#   LYXC_VM_KB=$(( 8 * 1024 * 1024 )) LYXC_TIMEOUT=900
#
# Die Grenze scheitert LAUT: `timeout` liefert 124, ein Speicherfehler >= 128.
# Ein Test, der beides als "uebersetzt nicht" verbucht, verschiebt das Problem
# nur — deshalb meldet der Wrapper den Grund auf stderr, bevor er den Code
# weiterreicht.

if [ -z "${_LYXC_GUARD_ACTIVE:-}" ]; then
  _LYXC_GUARD_ACTIVE=1

  _lyxc_guard_real="$LYXC"
  _lyxc_guard_dir="$(mktemp -d)"
  _lyxc_guard_bin="$_lyxc_guard_dir/lyxc"

  cat > "$_lyxc_guard_bin" <<GUARDEOF
#!/usr/bin/env bash
# Erzeugt von tests/lib/lyxc_guard.sh (#1294) — nicht von Hand bearbeiten.
ulimit -v "\${LYXC_VM_KB:-${LYXC_VM_KB:-4194304}}" 2>/dev/null
timeout "\${LYXC_TIMEOUT:-${LYXC_TIMEOUT:-60}}" "$_lyxc_guard_real" "\$@"
_rc=\$?
if [ "\$_rc" -eq 124 ]; then
  echo "lyxc_guard: Zeitueberschreitung (#1294) — der Compiler kehrte nicht zurueck" >&2
elif [ "\$_rc" -ge 128 ]; then
  echo "lyxc_guard: Abbruch durch Signal \$(( _rc - 128 )) (#1294) — moeglicherweise die Speichergrenze" >&2
fi
exit \$_rc
GUARDEOF
  chmod +x "$_lyxc_guard_bin"

  # Aufraeumen, ohne ein vorhandenes EXIT-trap des Scripts zu verlieren:
  # das Verzeichnis liegt unter /tmp und wird ohnehin vom System geraeumt.
  LYXC="$_lyxc_guard_bin"
fi
