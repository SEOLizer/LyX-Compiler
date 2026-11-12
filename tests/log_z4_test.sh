#!/usr/bin/env bash
# tests/log_z4_test.sh — #1437, #1438, #1439, #1440, #1441, #1442.
#
# `std.log` hatte ZWEI Ausgabewege, die einander nicht kannten:
#
#   #1437 Die Kurzfunktionen (log_debug … log_fatal) riefen `PrintLn` und
#         umgingen damit Level-Filter, Datei-Sink und Zeitstempel. Ein Dienst
#         mit `log_set_file("dienst.log")` hinterließ eine leere Datei.
#   #1442 Umgekehrt rief nur dieser Weg den Callback, `log_emit` nicht. Filter
#         und Weiterleitung waren nicht gleichzeitig zu haben.
#   #1438 `log_set_color(true)` erzeugte kein einziges ANSI-Byte: die Codes
#         standen als OKTALE Escapes (`\033`) da, die Lyx nicht kennt — `\0`
#         ist NUL, der String hatte Länge 0.
#   #1439 `log_info_kv` schrieb ungültiges JSON (kein Escaping) und übersprang
#         den Level-Filter.
#   #1440 Die vier `log_*f`-Wrapper leckten pro Aufruf zwei Puffer.
#   #1441 `log_section_enter`/`exit` waren ununterscheidbar, `log_app_start`
#         verwarf den Namen.
#
# GEPRÜFT WIRD DER WEG, NICHT DIE ZEILE: ob der Filter greift, ob die Datei
# ankommt, ob der Callback feuert. Ein Test, der nur die Ausgabe von
# `log_info("x")` vergleicht, wäre vor dem Fix grün gewesen — sie sah ja
# richtig aus, sie ging nur an der Konfiguration vorbei.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1437 — Level-Filter und Datei-Sink gelten für ALLE Wege
# ===========================================================================

out "#1437: Level-Filter greift auch bei den Kurzfunktionen" 'import std.io;
import std.log;
fn main(): int64 {
  set_log_level(LOG_LEVEL_ERROR);
  log_info("darf nicht erscheinen");
  log_debug("darf nicht erscheinen");
  log_warn("darf nicht erscheinen");
  log_error("erscheint");
  log_emit(LOG_LEVEL_INFO, "emit: darf nicht erscheinen");
  log_emit(LOG_LEVEL_ERROR, "emit: erscheint");
  return 0;
}' "[ERROR] erscheint
[ERROR] emit: erscheint"

# Der Datei-Sink ist der Fall aus der Meldung: die Zeilen landeten auf stdout,
# die Datei blieb leer. Geprueft wird beides — Datei voll UND stdout leer.
cat > "$TMP/f.lyx" <<LYXEOF
import std.io;
import std.log;
fn main(): int64 {
  if (!log_set_file("$TMP/dienst.log")) { PrintLn("open fehlgeschlagen"); return 1; }
  log_info("erste Zeile");
  log_error("zweite Zeile");
  log_infof("dritte Zeile ", 7);
  log_set_file("");
  return 0;
}
LYXEOF
rm -f "$TMP/dienst.log"
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" >/dev/null 2>&1; then
  stdout="$(timeout 20 "$TMP/f" 2>&1)"
  datei="$(cat "$TMP/dienst.log" 2>/dev/null)"
  [ -z "$stdout" ] && ok "#1437: nichts landet auf stdout" \
                   || no "#1437: nichts landet auf stdout" "'$stdout'"
  erwartet="[INFO] erste Zeile
[ERROR] zweite Zeile
[INFO] dritte Zeile 7"
  [ "$datei" = "$erwartet" ] && ok "#1437: alle drei Wege schreiben in die Datei" \
                             || no "#1437: alle drei Wege schreiben in die Datei" "'$datei'"
else
  no "#1437: nichts landet auf stdout" "uebersetzt nicht"
  no "#1437: alle drei Wege schreiben in die Datei" "uebersetzt nicht"
fi

# ===========================================================================
# #1442 — der Callback hängt am einen Ausgabeweg
# ===========================================================================

out "#1442: Callback feuert bei Kurzfunktion UND log_emit" 'import std.io;
import std.log;
fn handler(msg: pchar): void { PrintStr("[cb]"); PrintLn(msg); }
fn main(): int64 {
  register_log_callback(handler as int64);
  log_warn("kurz");
  log_emit(LOG_LEVEL_WARN, "emit");
  log_warnf("mitZahl", 3);
  unregister_log_callback();
  log_warn("ohne");
  return 0;
}' "[WARN] kurz
[cb]kurz
[WARN] emit
[cb]emit
[WARN] mitZahl3
[cb]mitZahl3
[WARN] ohne"

# Der Callback darf NICHT feuern, wenn der Level die Zeile verwirft — sonst
# sieht das externe System Zeilen, die im Log fehlen.
out "#1442: kein Callback fuer gefilterte Zeilen" 'import std.io;
import std.log;
fn handler(msg: pchar): void { PrintStr("[cb]"); PrintLn(msg); }
fn main(): int64 {
  register_log_callback(handler as int64);
  set_log_level(LOG_LEVEL_ERROR);
  log_info("gefiltert");
  log_error("durch");
  return 0;
}' "[ERROR] durch
[cb]durch"

# ===========================================================================
# #1438 — ANSI-Farben
# ===========================================================================

# Gemessen werden BYTES, nicht das Aussehen: vor dem Fix schrieb die Unit null
# Zeichen, weil der oktale Escape den String bei NUL enden liess.
cat > "$TMP/c1.lyx" <<'LYXEOF'
import std.io;
import std.log;
fn main(): int64 {
  log_set_color(true);
  log_warn("bunt");
  log_set_color(false);
  log_warn("schlicht");
  return 0;
}
LYXEOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c1.lyx" -o "$TMP/c1" >/dev/null 2>&1; then
  roh="$(timeout 20 "$TMP/c1" 2>&1 | od -c | tr -s ' ')"
  if echo "$roh" | grep -q '033'; then ok "#1438: Farbe erzeugt ESC-Bytes"
  else no "#1438: Farbe erzeugt ESC-Bytes" "kein ESC in der Ausgabe"; fi
  sichtbar="$(timeout 20 "$TMP/c1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  [ "$sichtbar" = "[WARN] bunt
[WARN] schlicht" ] && ok "#1438: Text bleibt ohne die Codes derselbe" \
                   || no "#1438: Text bleibt ohne die Codes derselbe" "'$sichtbar'"
  # Die Ruecksetzung gehoert VOR den Zeilenumbruch, sonst faerbt sie die
  # naechste Zeile mit.
  letzte="$(timeout 20 "$TMP/c1" 2>&1 | head -1 | od -c | tr -s ' ')"
  if echo "$letzte" | grep -q '0 m'; then ok "#1438: Ruecksetzung steht in der Zeile"
  else no "#1438: Ruecksetzung steht in der Zeile" "kein Reset vor dem Umbruch"; fi
else
  no "#1438: Farbe erzeugt ESC-Bytes" "uebersetzt nicht"
  no "#1438: Text bleibt ohne die Codes derselbe" "uebersetzt nicht"
  no "#1438: Ruecksetzung steht in der Zeile" "uebersetzt nicht"
fi

# Ohne log_set_color darf kein einziges Steuerzeichen erscheinen.
cat > "$TMP/c2.lyx" <<'LYXEOF'
import std.io;
import std.log;
fn main(): int64 { log_warn("schlicht"); return 0; }
LYXEOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c2.lyx" -o "$TMP/c2" >/dev/null 2>&1; then
  roh="$(timeout 20 "$TMP/c2" 2>&1 | od -c | tr -s ' ')"
  if echo "$roh" | grep -q '033'; then no "#1438: ohne Farbe keine Codes" "ESC in der Ausgabe"
  else ok "#1438: ohne Farbe keine Codes"; fi
else
  no "#1438: ohne Farbe keine Codes" "uebersetzt nicht"
fi

# ===========================================================================
# #1439 — gültiges JSON und Level-Filter
# ===========================================================================

out "#1439: Anfuehrungszeichen und Backslash werden escaped" 'import std.io;
import std.log;
fn main(): int64 {
  log_info_kv("cfg", "pfad", "C:\"tmp\"x");
  log_info_kv("cfg", "esc", "a\\b");
  return 0;
}' '{"level":"info","event":"cfg","pfad":"C:\"tmp\"x"}
{"level":"info","event":"cfg","esc":"a\\b"}'

# Steuerzeichen unter 0x20 verlangt RFC 8259 als \u00XX; Tab und Zeilenumbruch
# haben eigene Kurzformen.
out "#1439: Steuerzeichen nach RFC 8259" 'import std.io;
import std.alloc;
import std.log;
fn main(): int64 {
  var b: int64 := alloc(8);
  poke8(b, 97); poke8(b + 1, 9); poke8(b + 2, 10); poke8(b + 3, 1); poke8(b + 4, 98); poke8(b + 5, 0);
  log_info_kv("e", "k", b as pchar);
  return 0;
}' '{"level":"info","event":"e","k":"a\t\n\u0001b"}'

out "#1439: Level-Filter gilt auch hier" 'import std.io;
import std.log;
fn main(): int64 {
  set_log_level(LOG_LEVEL_FATAL);
  log_info_kv("cfg", "a", "b");
  set_log_level(LOG_LEVEL_INFO);
  log_info_kv("cfg", "c", "d");
  return 0;
}' '{"level":"info","event":"cfg","c":"d"}'

# ===========================================================================
# #1441 — Sektionen und Anwendungsname
# ===========================================================================

out "#1441: Eintritt und Austritt sind unterscheidbar" 'import std.io;
import std.log;
fn main(): int64 {
  log_section_enter("aussen");
  log_section_enter("innen");
  log_section_exit("innen");
  log_section_exit("aussen");
  return 0;
}' "[INFO] -> aussen
[INFO]   -> innen
[INFO]   <- innen
[INFO] <- aussen"

out "#1441: log_app_start nennt den Namen" 'import std.io;
import std.log;
fn main(): int64 {
  log_app_start("dienst-a");
  return 0;
}' "[INFO] ========================================
[INFO] Application started: dienst-a
[INFO] ========================================"

# ===========================================================================
# #1440 — die Format-Wrapper geben ihre Puffer frei
# ===========================================================================

# Der Speicherverbrauch ist von aussen schwer zu messen; geprueft wird deshalb
# die Wirkung, die ein Leck haette: 20000 Aufrufe mit langer Nachricht wuerden
# rund 2 MB verlieren. Das Programm muss sie ohne Absturz durchlaufen und
# danach noch richtig arbeiten.
out "#1440: viele Aufrufe laufen durch" 'import std.io;
import std.log;
fn main(): int64 {
  set_log_level(LOG_LEVEL_ERROR);
  var i: int64 := 0;
  while (i < 20000) {
    log_infof("eine mittellange Nachricht zum Messen des Verbrauchs ", i);
    log_debugf("noch eine ", i);
    i := i + 1;
  }
  set_log_level(LOG_LEVEL_INFO);
  log_infof("fertig ", 42);
  return 0;
}' "[INFO] fertig 42"

# log_errorf hatte als einziger keinen Level-Filter.
out "#1440: log_errorf beachtet den Filter" 'import std.io;
import std.log;
fn main(): int64 {
  set_log_level(LOG_LEVEL_FATAL);
  log_errorf("unterdrueckt ", 1);
  set_log_level(LOG_LEVEL_ERROR);
  log_errorf("sichtbar ", 2);
  return 0;
}' "[ERROR] sichtbar 2"

# ===========================================================================
# Gegenproben
# ===========================================================================

out "std.log: Vorgabe unveraendert (INFO, stdout)" 'import std.io;
import std.log;
fn main(): int64 {
  log_debug("debug faellt weg");
  log_info("info kommt");
  log_warn("warn kommt");
  log_error("error kommt");
  PrintStr("level="); PrintLn(IntToStr(get_log_level()));
  return 0;
}' "[INFO] info kommt
[WARN] warn kommt
[ERROR] error kommt
level=1"

out "std.log: log_fatal beendet mit 1" 'import std.io;
import std.log;
fn main(): int64 {
  log_fatal("Schluss");
  PrintLn("unerreichbar");
  return 0;
}' "[FATAL] Schluss"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
