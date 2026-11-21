#!/bin/bash
# #2604: Ein Interface aus einer vorkompilierten .lyu muss ein Interface
# BLEIBEN. Verlor es seine Eigenschaft, baute ir_lower keinen
# Interface-Dispatch und loeste den Aufruf STATISCH in die rumpflose Methode
# der Interface-Deklaration auf -- kein Aufruf, keine Meldung, Rueckgabe war,
# was zufaellig im Rueckgaberegister stand. Gemessen vor dem Fix:
# 133549283110912 statt 4711, rc 0.
#
# WARUM DER WERT GEMESSEN WIRD UND NICHT DIE UEBERSETZUNG
# -------------------------------------------------------
# Die Uebersetzung war vorher GRUEN: rc 0, Binary entstand. Ein Test, der
# "uebersetzt" oder "Binary existiert" prueft, waere vor dem Fix bestanden und
# damit blind -- genau der Invariantentest, den CLAUDE.md verbietet. Geprueft
# wird deshalb die AUSGABE des laufenden Programms gegen 4711.
#
# WARUM BEIDE SEITEN
# ------------------
# Nur den Ablehnungsfall zu messen (kein Kandidat -> laut scheitern) waere
# auch von einem Compiler erfuellt, der Interfaces ueber .lyu GAR NICHT mehr
# kann: dann scheitert eben alles. Darum zwei Haelften:
#   positiv -- eine Klasse sagt das Interface zu: der Aufruf muss den
#              richtigen Wert liefern, aus der Quelle UND aus der .lyu;
#   negativ -- keine Klasse hat die Methode: beide Wege muessen dieselbe
#              Meldung geben und rc 1. Vor dem Fix war der .lyu-Weg hier
#              still rc 0.
#
# WARUM arm64 UND riscv
# ---------------------
# Der Defekt sass im gemeinsamen IR-Weg, nicht in einem Ziel. lyxos liesse
# sich lokal nicht ausfuehren (der LBF-Lader liefert Syscall-Ergebnisse in
# rax statt rdx, jede Allokation faultet), also wird auf den beiden
# IR-Zielen gemessen, die denselben Weg gehen und unter qemu laufen.
# Dreimal war ein gemeldeter "lyxos-Bug" in Wahrheit der gemeinsame IR-Weg
# (#1786, #1787, #1798).
#
# Der x86-Weg ist NICHT Teil der Pruefung: er verlangt die Quelle der
# importierten Unit und sagt das laut ("Quelle der importierten Unit nicht
# lesbar"). Das ist ehrlich und war nie der Defekt.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}" ;; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

# #2048: die Emulatoren NICHT selbst suchen. `qemu-user-static` nennt sie
# `qemu-aarch64-static`, das Nachfolgepaket `qemu-user` nur `qemu-aarch64` —
# und auf dem CI-Runner ist die -static-Form die installierte. Ein Skript, das
# am Namen vorbei sucht, laeuft dort durch, ohne die Wirkung zu messen.
# tests/qemu_name_test.sh wacht darueber und hat genau das hier gemeldet.
. "$(dirname "$0")/lib/qemu.sh"

ZIELE=""
[ -n "$QEMU_ARM64" ]   && ZIELE="$ZIELE arm64:$QEMU_ARM64"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv:$QEMU_RISCV64"
if [ -z "$ZIELE" ]; then
  echo "SKIP: kein Emulator fuer arm64 oder riscv64 vorhanden"
  echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ── Teil 1: positiv ────────────────────────────────────────────────────────
# Eine Klasse sagt das Interface mit `implements` zu. 4711 ist frei gewaehlt,
# aber nicht beliebig: es ist gross genug, dass ein zurueckgegebenes Feld
# oder eine Adresse es nicht zufaellig trifft, und klein genug, um es in der
# Ausgabe als Ganzes zu lesen.
mkdir -p "$T/pos"
cat > "$T/pos/pa.lyx" <<'LYX'
unit pa;
pub type IX = interface { fn Zzz(): int64; };
pub type TImpl = class implements IX {
  fn Zzz(): int64 { return 4711; }
};
LYX
cat > "$T/pos/pm.lyx" <<'LYX'
import pa;
fn main(): int64 {
  var o: TImpl := new TImpl();
  var i: IX := o as IX;
  PrintInt(i.Zzz());
  return 0;
}
LYX

# ── Teil 2: negativ ───────────────────────────────────────────────────────
# Keine Klasse hat `Zzz`. Der Aufruf ist nicht aufloesbar und MUSS gemeldet
# werden -- der Wortlaut traegt die Issue-Nummer #1787, an der die Meldung
# haengt.
mkdir -p "$T/neg"
cat > "$T/neg/na.lyx" <<'LYX'
unit na;
pub type IY = interface { fn Zzz(): int64; };
LYX
cat > "$T/neg/nb.lyx" <<'LYX'
unit nb;
import na;
pub type THold = class {
  F: IY;
  fn Ruf(): int64 { return self.F.Zzz(); }
};
LYX
cat > "$T/neg/nm.lyx" <<'LYX'
import na; import nb;
fn main(): int64 { var h: THold := new THold(); PrintInt(h.Ruf()); return 0; }
LYX

for zp in $ZIELE; do
  ziel="${zp%%:*}"; lauf="${zp##*:}"
  D="$T/$ziel"; rm -rf "$D"; cp -r "$T/pos" "$D" || { pr fail "$ziel: Vorbereitung"; continue; }

  # (A) aus der QUELLE -- der Bezugswert. Ginge schon er schief, saesse der
  #     Fehler nicht an der .lyu und die ganze Messung waere wertlos.
  if "$LYXC" "$D/pm.lyx" --target="$ziel" -I "$D" -o "$D/aus_quelle" >"$D/a.log" 2>&1 \
     && [ -f "$D/aus_quelle" ]; then
    got=$("$lauf" "$D/aus_quelle" 2>/dev/null)
    if [ "$got" = "4711" ]; then pr ok "$ziel positiv: aus der Quelle 4711"
    else pr fail "$ziel positiv: aus der Quelle '$got' statt 4711"; fi
  else
    pr fail "$ziel positiv: Quelle uebersetzt nicht -- $(tail -1 "$D/a.log")"
  fi

  # (B) aus der .lyu, mit WEGGESCHOBENER Quelle. Das Verschieben ist der Kern
  #     des Versuchs: liegt pa.lyx noch da, nimmt der Resolver sie und der
  #     .lyu-Weg wird nie betreten (er bevorzugt .lyx vor .lyu).
  if "$LYXC" "$D/pa.lyx" --compile-unit --target="$ziel" -I "$D" -o "$D/pa.lyu" >"$D/u.log" 2>&1 \
     && [ -f "$D/pa.lyu" ]; then
    pr ok "$ziel: pa.lyu geschrieben"
  else
    pr fail "$ziel: pa.lyu nicht geschrieben -- $(tail -1 "$D/u.log")"
  fi
  mv "$D/pa.lyx" "$D/pa.lyx.weg"

  if "$LYXC" "$D/pm.lyx" --target="$ziel" -I "$D" -o "$D/aus_lyu" >"$D/b.log" 2>&1 \
     && [ -f "$D/aus_lyu" ]; then
    got=$("$lauf" "$D/aus_lyu" 2>/dev/null)
    if [ "$got" = "4711" ]; then
      pr ok "$ziel positiv: aus der .lyu 4711 (Interface ueberlebt, #2604)"
    else
      pr fail "$ziel positiv: aus der .lyu '$got' statt 4711 -- still statisch gerufen (#2604)"
    fi
  else
    pr fail "$ziel positiv: .lyu-Weg uebersetzt nicht -- $(tail -1 "$D/b.log")"
  fi

  # (C) negativ, aus der .lyu. Vor dem Fix: rc 0 und ein Binary.
  N="$T/n_$ziel"; rm -rf "$N"; cp -r "$T/neg" "$N"
  "$LYXC" "$N/na.lyx" --compile-unit --target="$ziel" -I "$N" -o "$N/na.lyu" >/dev/null 2>&1
  mv "$N/na.lyx" "$N/na.lyx.weg"
  "$LYXC" "$N/nm.lyx" --target="$ziel" -I "$N" -o "$N/x" >"$N/c.log" 2>&1
  rc=$?
  if [ "$rc" != "0" ] && [ ! -f "$N/x" ]; then
    pr ok "$ziel negativ: nicht aufloesbarer Interface-Aufruf scheitert (rc=$rc, kein Erzeugnis)"
  else
    pr fail "$ziel negativ: rc=$rc, Erzeugnis $([ -f "$N/x" ] && echo da || echo weg) -- stille Fehluebersetzung (#2604)"
  fi
  if grep -q '#1787' "$N/c.log"; then
    pr ok "$ziel negativ: Meldung nennt die Ursache (#1787)"
  else
    pr fail "$ziel negativ: Meldung ohne #1787 -- $(tail -1 "$N/c.log")"
  fi
done

# ── Teil 3: die Beschreibung steht wirklich in der Datei ──────────────────
# Zwei Stellen im Leser muessen uebereinstimmen: die Ausgabe (LyrDeklText)
# und die Auskunft "ist beschrieben". Kennt die zweite die Art nicht, bleibt
# die Unit quellpflichtig, und man sieht es der Meldung nicht an -- genau das
# ist bei den Arten 5/6 (#2488) und 11/12 (#2514) schon zweimal passiert.
# Geprueft wird es daran, dass der .lyu-Weg oben ueberhaupt ohne die Quelle
# uebersetzt hat; hier zusaetzlich am Dateiinhalt: der Interface-Name muss
# als beschriebener Eintrag drinstehen.
Z="$(echo $ZIELE | awk '{print $1}')"; Z="${Z%%:*}"
D="$T/$Z"
if [ -f "$D/pa.lyu" ]; then
  if grep -q 'IX' "$D/pa.lyu"; then
    pr ok "pa.lyu traegt den Interface-Namen"
  else
    pr fail "pa.lyu ohne Interface-Namen"
  fi
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
