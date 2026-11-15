#!/usr/bin/env bash
# tests/shani_lyxos_2438_test.sh — #2438: SHA-NI auch auf lyxos, aus EINER
# Beschreibung gerendert.
#
# BEFUND. `sha256_compress` war nur auf ELF-x86 emittiert; auf lyxos fiel es
# auf IRO_PANIC, weil emit_lyxos die Folge nicht kannte und ein unbehandeltes
# IRO_CALL_BUILTIN dort still verworfen wird. Die Begruendung im Quelltext
# nannte dazu einen falschen Grund: `cpu_id` liefere auf Nicht-x86 0, die
# Weiche in std/crypto/sha256.lyx schuetze lyxos also. Gemessen liefert das
# lyxos-Erzeugnis dieselben CPUID-Werte wie x86 -- auf einer SHA-NI-Maschine
# waere die Bibliothek in den PANIC gelaufen.
#
# WAS DIESER TEST PRUEFT, und warum in dieser Form:
#
#  1. Das lyxos-Erzeugnis traegt die Befehle ueberhaupt (32x sha256rnds2,
#     12x msg1, 12x msg2) und die K-Tabelle genau EINMAL.
#
#  2. Die RECHNENDE Folge ist in beiden Erzeugnissen BYTE-GLEICH. Das ist der
#     Kern: "zwei Emitter aus einer Beschreibung" ist eine Behauptung, solange
#     sie nicht am Erzeugnis gemessen wird. Ein Zaehlen der Befehle wuerde eine
#     vertauschte Reihenfolge oder eine falsche Konstante NICHT finden
#     (#2390: eine falsche pshufb-Maske sah im Disassemblat richtig aus).
#
#  3. Die ZIELABHAENGIGE Klammer einzeln, denn von (2) ist sie gerade nicht
#     gedeckt: x86 holt die K-Tabelle aus dem Datensegment, lyxos legt sie
#     hinter einen Sprung in den Codestrom. Geprueft wird am Byte, dass der
#     Sprung das Tabellenende trifft, `lea r8` den Tabellenanfang, `lea r9`
#     die Maske und der `jz` das Rumpfende.
#
#  4. BEIDE SEITEN: arm64 und riscv muessen weiter LAUT scheitern. Ein Test,
#     der nur zeigt, dass lyxos jetzt emittiert, waere auch von einer viel zu
#     weit gefassten Zielliste erfuellt.
#
#  5. Die Richtigkeit der gerenderten Folge am NIST-Vektor, auf x86 unter
#     `qemu-x86_64 -cpu max` (die Entwicklungsmaschine hat kein SHA-NI).
#     Zusammen mit (2) traegt dieser Nachweis auf lyxos ueber: dieselbe
#     Bytefolge rechnet dasselbe.
#
# WAS DIESER TEST NICHT LEISTET, und das ist eine echte Grenze: das
# lyxos-Erzeugnis AUSFUEHREN. Der lokale LBF-Lader faultet an jeder
# Allokation (LyxOS liefert Syscall-Ergebnisse in rdx, Linux in rax, #1834),
# und ohne Allokation gibt es keinen Puffer -- `@` auf ein Array liefert den
# Slot der Variablen, nicht die Datenadresse. Der Nachweis fuer lyxos ruht
# deshalb auf (2) + (3) + (5), nicht auf einem Lauf.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
LYXC_TIMEOUT="${LYXC_TIMEOUT:-180}"
. "$ROOT/tests/lib/lyxc_guard.sh"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/c.lyx" <<'LYX'
unit main;
var st: int64 := 0;
var dt: int64 := 0;
fn main(): int64 { sha256_compress(st, dt, 0); return 0; }
LYX

(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/p.x86" >"$TMP/x.log" 2>&1) \
  || { no "x86 uebersetzen" "$(tail -2 "$TMP/x.log")"; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1; }
(cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/c.lyx" -o "$TMP/p.lbf" >"$TMP/l.log" 2>&1) \
  || { no "lyxos uebersetzen" "$(grep -m1 -iE 'error|wuerde|panic' "$TMP/l.log")"; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1; }
ok "beide Ziele uebersetzen sha256_compress"

# ── 1. Befehle und Tabelle im lyxos-Erzeugnis ──────────────────────────────
hexl="$(xxd -p "$TMP/p.lbf" | tr -d '\n')"
n_rnds=$(grep -o '0f38cb' <<<"$hexl" | wc -l)
n_msg1=$(grep -o '0f38cc' <<<"$hexl" | wc -l)
n_msg2=$(grep -o '0f38cd' <<<"$hexl" | wc -l)
n_ktab=$(grep -o '982f8a4291443771' <<<"$hexl" | wc -l)
if [ "$n_rnds" -eq 32 ] && [ "$n_msg1" -eq 12 ] && [ "$n_msg2" -eq 12 ] && [ "$n_ktab" -eq 1 ]; then
  ok "lyxos-Erzeugnis: 32 sha256rnds2, 12 msg1, 12 msg2, K-Tabelle einmal"
else
  no "lyxos-Befehlszahlen" "rnds2=$n_rnds (32) msg1=$n_msg1 (12) msg2=$n_msg2 (12) ktab=$n_ktab (1)"
fi

# ── 2.+3. Byte-Gleichheit und die zielabhaengige Klammer ───────────────────
python3 - "$TMP/p.x86" "$TMP/p.lbf" > "$TMP/py.out" 2>&1 <<'PY'
import sys
x = open(sys.argv[1],'rb').read(); l = open(sys.argv[2],'rb').read()
def s32(bs): return int.from_bytes(bs,'little',signed=True)
def fenster(b, name):
    a = b.find(bytes.fromhex('f3450f6f11'))          # movdqu xmm10,[r9]
    e = b.find(bytes.fromhex('f30f7f5710'), a)       # movdqu [rdi+16],xmm2
    if a < 0 or e < 0: print(f"FEHLER {name}: Rumpf nicht gefunden"); sys.exit(1)
    return b[a:e+5], a
rx, _  = fenster(x, 'x86')
rl, _  = fenster(l, 'lyxos')
print("RUMPF_X86_LEN", len(rx)); print("RUMPF_LYXOS_LEN", len(rl))
print("RUMPF_GLEICH", "ja" if rx == rl else "nein")
k = l.find(bytes.fromhex('982f8a4291443771'))
kx = x.find(bytes.fromhex('982f8a4291443771'))
print("KTAB_GLEICH", "ja" if l[k:k+272] == x[kx:kx+272] else "nein")
j = k - 5
print("JMP_OPCODE", f"{l[j]:02x}")
print("JMP_TRIFFT", "ja" if (j + 5 + s32(l[j+1:j+5])) == k + 272 else "nein")
p = k + 272
print("LEA8_OPCODE", l[p:p+3].hex())
print("LEA8_TRIFFT", "ja" if (p + 7 + s32(l[p+3:p+7])) == k else "nein")
q = p + 7
print("LEA9_OPCODE", l[q:q+3].hex())
print("LEA9_DISP", s32(l[q+3:q+7]))
h = q + 7
print("KOPF_OPCODE", l[h:h+5].hex())
ende = l.find(bytes.fromhex('f30f7f5710'), h) + 5
print("JZ_TRIFFT", "ja" if (h + 9 + s32(l[h+5:h+9])) == ende else "nein")
PY
g() { grep -m1 "^$1 " "$TMP/py.out" | cut -d' ' -f2-; }
if [ "$(g RUMPF_GLEICH)" = "ja" ] && [ "$(g RUMPF_X86_LEN)" = "$(g RUMPF_LYXOS_LEN)" ]; then
  ok "rechnende Folge byte-gleich in beiden Erzeugnissen ($(g RUMPF_X86_LEN) Byte)"
else
  no "Byte-Gleichheit" "$(grep -E '^RUMPF' "$TMP/py.out" | tr '\n' ' ')"
fi
[ "$(g KTAB_GLEICH)" = "ja" ] && ok "K-Tabelle (272 Byte) in beiden gleich" \
                              || no "K-Tabelle" "weicht ab"
if [ "$(g JMP_OPCODE)" = "e9" ] && [ "$(g JMP_TRIFFT)" = "ja" ] \
   && [ "$(g LEA8_OPCODE)" = "4c8d05" ] && [ "$(g LEA8_TRIFFT)" = "ja" ] \
   && [ "$(g LEA9_OPCODE)" = "4d8d88" ] && [ "$(g LEA9_DISP)" = "256" ] \
   && [ "$(g KOPF_OPCODE)" = "4885d20f84" ] && [ "$(g JZ_TRIFFT)" = "ja" ]; then
  ok "lyxos-Klammer: jmp trifft das Tabellenende, lea r8 den Anfang, lea r9 die Maske, jz das Rumpfende"
else
  no "lyxos-Klammer" "$(grep -E '^(JMP|LEA|KOPF|JZ)' "$TMP/py.out" | tr '\n' ' ')"
fi

# ── 4. Gegenrichtung: arm64 und riscv tragen die Folge NICHT ───────────────
# Sie uebersetzen sehr wohl -- IRO_PANIC ist ein LAUFZEIT-Abbruch, kein
# Compilerfehler (erste Fassung dieses Tests erwartete faelschlich einen
# Fehlschlag beim Uebersetzen und war darueber rot). Gemessen wird deshalb am
# Erzeugnis: steht die SHA-NI-Folge drin, ist die Zielliste zu weit gefasst.
zuweit=""
for t in arm64 riscv; do
  if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target=$t "$TMP/c.lyx" -o "$TMP/p.$t" >"$TMP/$t.log" 2>&1); then
    ht="$(xxd -p "$TMP/p.$t" | tr -d '\n')"
    nr=$(grep -o '0f38cb' <<<"$ht" | wc -l)
    nk=$(grep -o '982f8a4291443771' <<<"$ht" | wc -l)
    [ "$nr" -gt 0 ] && zuweit="$zuweit $t(sha256rnds2 x$nr)"
    [ "$nk" -gt 0 ] && zuweit="$zuweit $t(K-Tabelle)"
  fi
done
[ -z "$zuweit" ] && ok "arm64/riscv tragen weder die Befehle noch die K-Tabelle (Zielliste nicht zu weit)" \
                 || no "Zielliste zu weit" "$zuweit"

# ── 5. NIST-Vektor: die gerenderte Folge rechnet richtig ───────────────────
cat > "$TMP/n.lyx" <<'LYX'
unit main;
import std.alloc;
fn main(): int64 {
  var sp: int64 := alloc(64);
  var bp: int64 := alloc(64);
  if (sp == 0 || bp == 0) { return 9; }
  poke32(sp +  0, 0x6a09e667); poke32(sp +  4, 0xbb67ae85);
  poke32(sp +  8, 0x3c6ef372); poke32(sp + 12, 0xa54ff53a);
  poke32(sp + 16, 0x510e527f); poke32(sp + 20, 0x9b05688c);
  poke32(sp + 24, 0x1f83d9ab); poke32(sp + 28, 0x5be0cd19);
  var i: int64 := 0;
  while (i < 64) { poke8(bp + i, 0); i += 1; }
  poke8(bp + 0, 97); poke8(bp + 1, 98); poke8(bp + 2, 99);   // "abc"
  poke8(bp + 3, 128);
  poke8(bp + 63, 24);
  sha256_compress(sp, bp, 1);
  if ((peek32(sp + 0) & 0xFFFFFFFF) != 0xba7816bf) { return 1; }
  if ((peek32(sp + 4) & 0xFFFFFFFF) != 0x8f01cfea) { return 2; }
  return 0;
}
LYX
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" >"$TMP/n.log" 2>&1); then
  if command -v qemu-x86_64 >/dev/null 2>&1; then
    timeout 60 qemu-x86_64 -cpu max "$TMP/n" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && ok "NIST-Vektor SHA-256(\"abc\") stimmt (qemu -cpu max)" \
                    || no "NIST-Vektor" "rc=$rc (1/2 = falsches Zustandswort, 132 = SIGILL, 139 = SIGSEGV)"
    # Gegenprobe: ohne SHA-NI muss derselbe Lauf SIGILL geben -- sonst messen
    # wir nicht die Befehle, sondern irgendeinen Softwareweg.
    timeout 60 qemu-x86_64 -cpu Nehalem "$TMP/n" >/dev/null 2>&1; rc2=$?
    [ "$rc2" -ge 128 ] && ok "ohne SHA-NI loest derselbe Lauf aus (rc=$rc2) -- gemessen werden die Befehle" \
                       || no "Gegenprobe" "ohne SHA-NI rc=$rc2, erwartet >= 128"
  else
    echo "SKIP NIST-Vektor: kein qemu-x86_64 (die Maschine hat kein SHA-NI)"
  fi
else
  no "NIST-Programm" "$(tail -2 "$TMP/n.log")"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
