#!/usr/bin/env bash
# tests/iso_verzeichnisse_test.sh — #1413: der ISO-Writer legt Verzeichnisse an.
#
# Bis 1.1.5A wies `IsoWriterAdd` jeden Namen mit Schraegstrich ab
# (ISO_ERR_NODIRS, #1401). Der Reader traversierte Verzeichnisse laengst — die
# Unit war unsymmetrisch.
#
# GEPRUEFT WIRD GEGEN FREMDE WERKZEUGE, nicht nur gegen den eigenen Reader.
# Beim tar-Fix (#1400) war der eigene Reader der Kronzeuge fuer den eigenen
# Fehler: er las den gekuerzten Namen zurueck und bestaetigte ihn. Hier
# entscheiden `xorriso`, `isoinfo` und `7z`.
#
# Das hat sich sofort ausgezahlt: isoinfo und 7z lasen das erste Abbild
# klaglos, xorriso wies es als "Wrong or damaged Primary Volume Descriptor"
# ab. Ursache war ein Byte Versatz in den vier Datumsfeldern des PVD, der
# schon im flachen Writer steckte und nie aufgefallen war.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- Abbild bauen
cat > "$TMP/bau.lyx" <<'EOF'
import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  PrintStr(IntToStr(IsoWriterAdd(w, "a.txt"c,          "hallo"c as int64, 5))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "sub/b.txt"c,      "welt"c  as int64, 4))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "sub/tief/c.txt"c, "tief"c  as int64, 4))); PrintStr(" ");
  // absichtlich verkehrt herum: ISO 9660 verlangt sortierte Directory Records
  PrintStr(IntToStr(IsoWriterAdd(w, "zz.txt"c, "z"c as int64, 1))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "mm.txt"c, "m"c as int64, 1))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "aa.txt"c, "a"c as int64, 1))); PrintStr(" ");
  // dasselbe Verzeichnis zweimal: es darf nur einmal entstehen
  PrintStr(IntToStr(IsoWriterAdd(w, "sub/d.txt"c, "d"c as int64, 1))); PrintStr(" ");
  PrintLn(IntToStr(IsoWriterSave(w, "bau.iso"c)));
  IsoWriterFree(w);
  return 0;
}
EOF
if ! "$LYXC" --std-path="$ROOT" "$TMP/bau.lyx" -o "$TMP/bau" >"$TMP/bau.log" 2>&1; then
  no "Testprogramm uebersetzt" "$(grep -iE 'error' "$TMP/bau.log" | head -1)"
  echo "----"; echo "$PASS PASS, $FAIL FAIL"; exit 1
fi
ok "Testprogramm uebersetzt"

RC=$(cd "$TMP" && ./bau | tail -1)
if [ "$RC" = "0 0 0 0 0 0 0 0" ]; then
  ok "alle Aufrufe melden Erfolg"
else
  no "alle Aufrufe melden Erfolg" "erhalten '$RC'"
fi

ISO="$TMP/bau.iso"

# ---------------------------------------------------------------- xorriso
# Der strengste der drei: er prueft den PVD, bevor er den Baum liest.
if have xorriso; then
  XO=$(xorriso -indev "$ISO" -find / 2>&1)
  if echo "$XO" | grep -qE "FAILURE|damaged"; then
    no "xorriso nimmt das Abbild an" "$(echo "$XO" | grep -E 'FAILURE|damaged' | head -1)"
  else
    ok "xorriso nimmt das Abbild an"
    for p in "'/A.TXT'" "'/SUB'" "'/SUB/B.TXT'" "'/SUB/TIEF'" "'/SUB/TIEF/C.TXT'"; do
      if echo "$XO" | grep -qF "$p"; then ok "xorriso findet $p"
      else no "xorriso findet $p"; fi
    done
  fi
else
  echo "SKIP xorriso nicht vorhanden"
fi

# ---------------------------------------------------------------- isoinfo
if have isoinfo; then
  II=$(isoinfo -f -i "$ISO" 2>&1)
  if echo "$II" | grep -q "^/SUB/TIEF/C.TXT;1$"; then
    ok "isoinfo sieht den Pfad ueber zwei Ebenen"
  else
    no "isoinfo sieht den Pfad ueber zwei Ebenen" "$(echo "$II" | tr '\n' ' ')"
  fi
  # Das Verzeichnis darf nicht doppelt angelegt worden sein.
  N=$(echo "$II" | grep -c "^/SUB$")
  if [ "$N" = "1" ]; then ok "SUB existiert genau einmal"
  else no "SUB existiert genau einmal" "gezaehlt: $N"; fi
else
  echo "SKIP isoinfo nicht vorhanden"
fi

# ---------------------------------------------------------------- 7z: Inhalte
# Der Baum kann stimmen und die Daten trotzdem am falschen Sektor liegen.
# Deshalb wird ausgepackt und der Inhalt gelesen, nicht nur die Liste.
if have 7z; then
  mkdir -p "$TMP/ex"
  if (cd "$TMP/ex" && 7z x "$ISO" >/dev/null 2>&1); then
    pruefe_inhalt() {
      if [ "$(cat "$TMP/ex/$1" 2>/dev/null)" = "$2" ]; then ok "Inhalt $1"
      else no "Inhalt $1" "erhalten '$(cat "$TMP/ex/$1" 2>/dev/null)'"; fi
    }
    pruefe_inhalt "A.TXT" "hallo"
    pruefe_inhalt "SUB/B.TXT" "welt"
    pruefe_inhalt "SUB/TIEF/C.TXT" "tief"
  else
    no "7z packt das Abbild aus"
  fi
else
  echo "SKIP 7z nicht vorhanden"
fi

# ---------------------------------------------------------------- Sortierung
# ISO 9660 verlangt Directory Records in aufsteigender Bezeichner-Reihenfolge.
# Ein Leser, der binaer sucht, findet sonst Eintraege nicht — und das faellt
# erst bei fremden Werkzeugen auf, weil der eigene Reader linear laeuft.
if have isoinfo; then
  ORD=$(isoinfo -f -i "$ISO" | grep -E "^/(AA|MM|ZZ)\.TXT;1$" | tr '\n' ' ')
  if [ "$ORD" = "/AA.TXT;1 /MM.TXT;1 /ZZ.TXT;1 " ]; then
    ok "Eintraege stehen sortiert im Verzeichnis"
  else
    no "Eintraege stehen sortiert im Verzeichnis" "erhalten '$ORD'"
  fi
fi

# ---------------------------------------------------------------- Tiefe
# ECMA-119 6.8.2.1: hoechstens acht Ebenen, die Wurzel zaehlt mit. Sieben
# Verzeichnisse sind erlaubt, acht nicht. Geprueft wird beides — eine Grenze,
# die nur ablehnt, koennte auch alles ablehnen.
cat > "$TMP/tiefe.lyx" <<'EOF'
import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  PrintStr(IntToStr(IsoWriterAdd(w, "a1/a2/a3/a4/a5/a6/a7/x.txt"c, "8"c as int64, 1))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "b1/b2/b3/b4/b5/b6/b7/b8/x.txt"c, "9"c as int64, 1))); PrintStr(" ");
  PrintLn(IntToStr(IsoWriterSave(w, "tiefe.iso"c)));
  IsoWriterFree(w);
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/tiefe.lyx" -o "$TMP/tiefe" >"$TMP/tiefe.log" 2>&1; then
  T=$(cd "$TMP" && ./tiefe | tail -1)
  if [ "$T" = "0 7 0" ]; then
    ok "sieben Ebenen gehen, acht melden ISO_ERR_TOODEEP"
  else
    no "sieben Ebenen gehen, acht melden ISO_ERR_TOODEEP" "erhalten '$T'"
  fi
  # Der abgewiesene Pfad darf nichts hinterlassen haben.
  if have isoinfo; then
    if isoinfo -f -i "$TMP/tiefe.iso" 2>/dev/null | grep -q "^/B1$"; then
      no "abgewiesener Pfad legt keine Verzeichnisse an" "B1 ist im Abbild"
    else
      ok "abgewiesener Pfad legt keine Verzeichnisse an"
    fi
  fi
else
  no "Tiefentest uebersetzt"
fi

# ---------------------------------------------------------------- grosses Verzeichnis
# Ein Directory Record darf keine Sektorgrenze ueberschreiten. Mit 90 Eintraegen
# braucht das Verzeichnis mehr als einen Sektor, und die Regel greift.
cat > "$TMP/viele.lyx" <<'EOF'
import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  var i: int64 := 0;
  while (i < 90) {
    IsoWriterAdd(w, ("D/F" + IntToStr(i) + ".TXT") as pchar, "xy"c as int64, 2);
    i := i + 1;
  }
  PrintLn(IntToStr(IsoWriterSave(w, "viele.iso"c)));
  IsoWriterFree(w);
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/viele.lyx" -o "$TMP/viele" >"$TMP/viele.log" 2>&1; then
  (cd "$TMP" && ./viele >/dev/null)
  if have isoinfo; then
    N=$(isoinfo -f -i "$TMP/viele.iso" 2>/dev/null | grep -c "^/D/F")
    if [ "$N" = "90" ]; then ok "Verzeichnis ueber mehr als einen Sektor: alle 90 Eintraege"
    else no "Verzeichnis ueber mehr als einen Sektor" "gezaehlt: $N"; fi
  fi
  if have xorriso; then
    if xorriso -indev "$TMP/viele.iso" -find / 2>&1 | grep -qE "FAILURE|damaged"; then
      no "xorriso nimmt das grosse Verzeichnis an"
    else
      ok "xorriso nimmt das grosse Verzeichnis an"
    fi
  fi
else
  no "Test fuer grosses Verzeichnis uebersetzt"
fi

# ---------------------------------------------------------------- flaches Abbild
# Der alte Weg muss unveraendert funktionieren.
cat > "$TMP/flach.lyx" <<'EOF'
import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  IsoWriterAdd(w, "DATEI.TXT"c, "abc"c as int64, 3);
  PrintStr(IntToStr(IsoWriterSave(w, "flach.iso"c))); PrintStr(" ");
  IsoWriterFree(w);
  var h: int64 := IsoOpen("flach.iso"c);
  PrintStr(IntToStr(IsoCount(h))); PrintStr(" ");
  PrintLn(IsoName(h, 0) as pchar);
  IsoClose(h);
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/flach.lyx" -o "$TMP/flach" >"$TMP/flach.log" 2>&1; then
  F=$(cd "$TMP" && ./flach | tail -1)
  if [ "$F" = "0 1 DATEI.TXT" ]; then ok "flaches Abbild unveraendert"
  else no "flaches Abbild unveraendert" "erhalten '$F'"; fi
  if have xorriso; then
    if xorriso -indev "$TMP/flach.iso" -find / 2>&1 | grep -qE "FAILURE|damaged"; then
      no "xorriso nimmt das flache Abbild an"
    else
      ok "xorriso nimmt das flache Abbild an"
    fi
  fi
else
  no "Test fuer flaches Abbild uebersetzt"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
