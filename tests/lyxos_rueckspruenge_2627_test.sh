#!/usr/bin/env bash
# tests/lyxos_rueckspruenge_2627_test.sh — landet jeder Rücksprung der
# lyxos-Handblöcke auf einer BEFEHLSGRENZE? (#2627)
#
# BEFUND. `IntToStr(42)` beendete unter --target=lyxos das Programm, `IntToStr(0)`
# und `IntToStr(7)` nicht. Ursache: in emitIntToStr stand `JNZ -20` als Zahl im
# Quelltext, abgeschrieben von emitPrintIntFd. Dort ist -20 richtig, weil der
# Rumpf die 32-Bit-Formen benutzt (31 D2, 83 C2 30, 41 FF CB) und 20 Byte lang
# ist. emitIntToStr benutzt die 64-Bit-Formen (48 31 D2, 48 83 C2 30, 49 FF CB)
# und ist 22 Byte lang -- der Rücksprung landete zwei Byte hinter dem
# Schleifenanfang, also MITTEN in `XOR rdx, rdx`. Bei einer Ziffer wird der
# Rücksprung nie genommen; ab zwei Ziffern dekodierte der zweite Durchlauf
# versetzt. Genau diese Grenze trennt "0 und 7 gehen" von "42 tötet".
#
# WARUM EIN GENERELLER WAECHTER UND NICHT EIN EINZELFALL. Die Klasse ist die
# von Hand gerechnete rel8 im Handblock -- sie ist so lange richtig, wie
# niemand den Rumpf anfasst (#2244 lag genauso). emit_lyxos.lyx trug 11 solche
# Zahlen; nachgerechnet wurden alle (sechs -11, zwei -16, zwei -20 und die
# falsche), genau eine war falsch. Dieser Test prüft nicht die Zahl, sondern
# die WIRKUNG am Erzeugnis: ein Ziel, das keine Befehlsgrenze ist, ist immer
# ein Fehler, egal welche Zahl ihn erzeugt hat.
#
# Nur RUECKWAERTSsprünge: Vorwärtsziele führen in diesem Format regelmäßig
# über Datenbereiche, die objdump als Befehle liest -- dort entstehen
# Scheintreffer (gemessen: 126 bei einem fehlerfreien Erzeugnis). Die
# Rückwärtsrichtung ist rauschfrei und genau die Richtung der Schleifen.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

command -v objdump >/dev/null 2>&1 || { echo "SKIP: objdump fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

# Ein Programm, das die Handblöcke MIT Schleife anfasst: IntToStr (Ziffern),
# StrLen (Nullbyte suchen), StrConcat (zwei Kopierschleifen), StrSub (Kopie
# mit Länge) und die Ausgabe selbst.
cat > "$TMP/p.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
    var a: pchar := IntToStr(4711);
    var b: pchar := StrConcat(a, "-ende"c);
    var c: pchar := StrSub(b, 0, 4);
    PrintLn(a); PrintLn(b); PrintLn(c);
    PrintLn(IntToStr(StrLen(b)));
    PrintLn(IntToStr(0 - 12345));
    return 0;
}
LYX
if ! "$LYXC" --std-path=. --target=lyxos "$TMP/p.lyx" -o "$TMP/p.lbf" > "$TMP/bau.log" 2>&1; then
  pr fail "Programm uebersetzt nicht: $(head -3 "$TMP/bau.log" | tr '\n' ' ')"
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
pr ok "Programm mit IntToStr/StrLen/StrConcat/StrSub uebersetzt"

# -z, sonst kürzt objdump lange Nullfolgen ab und disassembliert den Rest gar
# nicht; --no-show-raw-insn, sonst zählen Byte-Folgezeilen als eigene Befehle
# (#1370). -D -b binary, weil ein LBF keine Sektionen hat.
objdump -D -b binary -m i386:x86-64 -z --no-show-raw-insn "$TMP/p.lbf" 2>/dev/null > "$TMP/dis.txt"

# Der erste 4-KiB-Block ist der LYX!-Containerkopf (Magic, Einsprung, CRC,
# Stapelgröße) und kein Code; objdump liest ihn trotzdem als Befehle. Jumps
# mit Quelle ODER Ziel darin bleiben außen vor.
KOPF=4096
awk -v kopf="$KOPF" '
  match($0, /^ *([0-9a-f]+):/, a) { adr[strtonum("0x" a[1])] = 1 }
  match($0, /^ *([0-9a-f]+):\t(j[a-z]+|loop[a-z]*) +0x([0-9a-f]+)/, m) {
     v = strtonum("0x" m[1]); z = strtonum("0x" m[3])
     if (z < v && v >= kopf && z >= kopf) { n++; q[n] = v; t[n] = z }
  }
  END {
    bad = 0
    for (i = 1; i <= n; i++) if (!(t[i] in adr)) { bad++; printf "%x -> %x\n", q[i], t[i] > "/dev/stderr" }
    print n " " bad
  }' "$TMP/dis.txt" 2> "$TMP/treffer.txt" > "$TMP/zahlen.txt"
read -r RUECK SCHLECHT < "$TMP/zahlen.txt"

# Ein Filter, der alles wegnimmt, macht den Test gruen ohne zu messen.
if [ "${RUECK:-0}" -ge 8 ]; then
  pr ok "$RUECK Rueckwaertssprunge im Code liegen im Pruefbereich"
else
  pr fail "nur ${RUECK:-0} Rueckwaertssprunge gefunden -- der Filter nimmt zu viel weg"
fi

if [ "${SCHLECHT:-1}" = 0 ]; then
  pr ok "jeder Rueckwaertssprung landet auf einer Befehlsgrenze"
else
  pr fail "$SCHLECHT Rueckwaertssprung/-spruenge landen zwischen zwei Befehlen:"
  sed 's/^/      /' "$TMP/treffer.txt"
fi

# Gezielt: die Ziffernschleife von IntToStr. Anker ist `div %r9` mit dem
# `add $0x30,%rdx` dahinter; der Rücksprung muss auf das `xor %rdx,%rdx`
# davor zeigen und nicht irgendwohin.
echo "--- Ziffernschleife von IntToStr ---"
awk '
  /xor +%rdx,%rdx/              { kopf = $1; sub(":", "", kopf) }
  /div +%r9/                    { gesehen = 1 }
  gesehen && /jne +0x/          { ziel = $NF; sub("^0x", "", ziel)
                                  print kopf " " ziel; gesehen = 0 }
' "$TMP/dis.txt" > "$TMP/its.txt"
if [ ! -s "$TMP/its.txt" ]; then
  pr fail "keine Ziffernschleife im Erzeugnis gefunden -- wird IntToStr ueberhaupt emittiert?"
else
  schief=0; anz=0
  while read -r kopf ziel; do
    anz=$((anz+1))
    [ "$kopf" = "$ziel" ] || { schief=$((schief+1)); echo "      Schleifenkopf $kopf, Ruecksprungziel $ziel"; }
  done < "$TMP/its.txt"
  if [ "$schief" = 0 ]; then
    pr ok "$anz Ziffernschleife(n): Ruecksprung zeigt auf den Schleifenkopf"
  else
    pr fail "$schief von $anz Ziffernschleifen springen nicht auf ihren Kopf (#2627)"
  fi
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
