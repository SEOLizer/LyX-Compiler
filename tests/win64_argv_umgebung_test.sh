#!/usr/bin/env bash
# tests/win64_argv_umgebung_test.sh
#
# #2263: Der win64-Zerleger der Kommandozeile (wxb_emitArgvSetup) trennte nur
# an Bytes <= 0x20 und liess Anfuehrungszeichen stehen. argv[0] kam als
# `"D:\pfad\prog.exe"` an, und `-o "C:\Program Files\x.exe"` wurde zu zwei
# Argumenten mit Fremdzeichen.
#
# #2264: lyx_getEnvVar in src/lyxc.lyx rechnete das SysV-Bild aus (envp hinter
# argv). Auf win64 liegt dort der Zeichenbereich des argv-Blocks: die ersten
# acht Bytes von argv[0] wurden als ZEIGER gelesen — Zugriffsverletzung, noch
# vor dem Banner. lyxc.exe konnte deshalb nichts uebersetzen, waehrend
# --version lief. Der Weg steht in std/env.lyx (GetEnvBlock, #1677); hier wird
# er fuer dieselbe Aufgabe im Compiler gemessen.
#
# Gemessen wird die WIRKUNG am laufenden Erzeugnis unter wine, beide Seiten:
# die Quotes sind weg UND ein ungequotetes Argument bleibt unveraendert.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- Sonde argv
cat > "$TMP/argv.lyx" <<'LYX'
import src.std.io;
fn main(argc: int64, argv: int64): int64 {
  PrintStr("argc="c); PrintLn(argc);
  var i: int64 := 0;
  while (i < argc) {
    PrintStr("["c); PrintInt(i); PrintStr("]="c);
    var p: int64 := peek64(argv + i * 8);
    if (p == 0) { PrintStrLn("<null>"c); } else { PrintStrLn(p as pchar); }
    i += 1;
  }
  return 0;
}
LYX

# ----------------------------------------------------- Sonde Umgebungssuche
# Dieselbe Reihenfolge wie lyx_getEnvVar: erst der Windows-Block, sonst SysV.
cat > "$TMP/env.lyx" <<'LYX'
import src.std.io;

pub fn holeUmgebung(argc: int64, argv: pchar, name: pchar): pchar {
  if (name as int64) == 0 { return 0 as pchar; }
  var nameLen: int64 := StrLen(name);
  var block: int64 := GetEnvBlock();
  if block != 0 {
    var p: int64 := block;
    while peek8(p) != 0 {
      var j: int64 := 0;
      var passt: int64 := 1;
      while j < nameLen {
        if peek8(p + j) != peek8(name as int64 + j) { passt := 0; j := nameLen; }
        j += 1;
      }
      if passt == 1 && peek8(p + nameLen) == 61 { return (p + nameLen + 1) as pchar; }
      while peek8(p) != 0 { p += 1; }
      p += 1;
    }
    return 0 as pchar;
  }
  if (argv as int64) == 0 { return 0 as pchar; }
  var envp: int64 := argv as int64 + (argc + 1) * 8;
  var i: int64 := 0;
  while i < 8192 {
    var e: int64 := peek64(envp + i * 8);
    if e == 0 { return 0 as pchar; }
    var j2: int64 := 0;
    var ok2: int64 := 1;
    while j2 < nameLen {
      if peek8(e + j2) != peek8(name as int64 + j2) { ok2 := 0; j2 := nameLen; }
      j2 += 1;
    }
    if ok2 == 1 && peek8(e + nameLen) == 61 { return (e + nameLen + 1) as pchar; }
    i += 1;
  }
  return 0 as pchar;
}

fn main(argc: int64, argv: pchar): int64 {
  var v: pchar := holeUmgebung(argc, argv, "LYX_ARGV_PROBE"c);
  if (v as int64) == 0 { PrintStrLn("LEER"c); } else { PrintStr("WERT="c); PrintStrLn(v); }
  return 0;
}
LYX

uebersetze() { # $1 = quelle, $2 = ziel, $3.. = weitere Schalter
  local q="$1"; local z="$2"; shift 2
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$@" "$q" -o "$z" ) >"$TMP/bau.log" 2>&1
}

for ziel in win64 linux; do
  schalter=""
  [ "$ziel" = win64 ] && schalter="--target=win64 --format=pe"
  if ! uebersetze "$TMP/argv.lyx" "$TMP/argv_$ziel.bin" $schalter; then
    nok "$ziel: argv-Sonde uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"
  else ok "$ziel: argv-Sonde uebersetzt"; fi
  if ! uebersetze "$TMP/env.lyx" "$TMP/env_$ziel.bin" $schalter; then
    nok "$ziel: Umgebungssonde uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"
  else ok "$ziel: Umgebungssonde uebersetzt"; fi
done

# --------------------------------------------------------------- Linux-Seite
chmod +x "$TMP/argv_linux.bin" "$TMP/env_linux.bin" 2>/dev/null
aus="$("$TMP/argv_linux.bin" eins "a b" 2>/dev/null)"
if [ "$(printf '%s\n' "$aus" | sed -n '3p')" = "[1]=eins" ] \
   && [ "$(printf '%s\n' "$aus" | sed -n '4p')" = "[2]=a b" ]; then
  ok "linux: argv unveraendert (Gegenprobe)"
else nok "linux: argv [$aus]"; fi
if [ "$(LYX_ARGV_PROBE=ZZ "$TMP/env_linux.bin" 2>/dev/null)" = "WERT=ZZ" ]; then
  ok "linux: Umgebungssuche findet den Wert (SysV-Weg)"
else nok "linux: Umgebungssuche"; fi

# ---------------------------------------------------------------- win64/wine
if ! command -v wine >/dev/null 2>&1; then
  echo "SKIP wine nicht vorhanden — win64-Wirkung nicht messbar"
else
  cp "$TMP/argv_win64.bin" "$TMP/argv.exe"
  cp "$TMP/env_win64.bin"  "$TMP/env.exe"
  aus="$(cd "$TMP" && WINEDEBUG=-all timeout 180 wine argv.exe eins "a b" drei 2>/dev/null)"
  # argv[0]: Windows quotet den Programmpfad — im Erzeugnis darf kein " stehen.
  z0="$(printf '%s\n' "$aus" | sed -n '2p')"
  case "$z0" in
    *'"'*) nok "wine: argv[0] traegt Anfuehrungszeichen: $z0" ;;
    '[0]='*) ok "wine: argv[0] ohne Anfuehrungszeichen" ;;
    *) nok "wine: argv[0] fehlt: [$aus]" ;;
  esac
  # Ein gequotetes Argument mit Leerzeichen ist EIN Eintrag, ohne Quotes.
  if [ "$(printf '%s\n' "$aus" | sed -n '1p')" = "argc=4" ]; then
    ok "wine: argc=4 (Programm + drei Argumente)"
  else nok "wine: $(printf '%s\n' "$aus" | sed -n '1p') statt argc=4"; fi
  if [ "$(printf '%s\n' "$aus" | sed -n '4p')" = "[2]=a b" ]; then
    ok "wine: \"a b\" bleibt EIN Argument, ohne Quotes"
  else nok "wine: [2] ist [$(printf '%s\n' "$aus" | sed -n '4p')] statt [a b]"; fi
  # Beide Seiten: ein ungequotetes Argument bleibt unveraendert.
  if [ "$(printf '%s\n' "$aus" | sed -n '3p')" = "[1]=eins" ] \
     && [ "$(printf '%s\n' "$aus" | sed -n '5p')" = "[3]=drei" ]; then
    ok "wine: ungequotete Argumente unveraendert"
  else nok "wine: ungequotete Argumente [$aus]"; fi

  # #2264: Umgebungssuche darf nicht abstuerzen und muss den Wert finden.
  ausE="$(cd "$TMP" && LYX_ARGV_PROBE=ZZ WINEDEBUG=-all timeout 180 wine env.exe 2>/dev/null)"
  rcE=$?
  if [ "$ausE" = "WERT=ZZ" ]; then
    # Das belegt den WEG (GetEnvBlock liefert auf win64 den Block), nicht den
    # Fix in lyxc selbst — diese Sonde waere auch vor #2264 gruen gewesen.
    # Die Wirkung im Compiler messt tests/win64_selbstbau_test.sh.
    ok "wine: Umgebungssuche findet den Wert (GetEnvBlock-Weg)"
  else nok "wine: Umgebungssuche gab [$ausE] (rc $rcE) statt WERT=ZZ"; fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
