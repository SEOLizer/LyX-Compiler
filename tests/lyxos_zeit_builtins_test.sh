#!/usr/bin/env bash
# tests/lyxos_zeit_builtins_test.sh — Zeit-Builtins gehen über den r3_sc_block (#1750).
#
# Geprüft wird der WEG, nicht das Ergebnis. Der Defekt liegt in der Zustellung:
# .ring3_dispatch (bootloader/boot.asm) kennt nur eine Whitelist von
# Syscall-Nummern; keine der sechs Zeitnummern (116, 117, 134, 138, 140, 228)
# steht darin. Über den Registerweg (MOV rax,<nr>; SYSCALL) landen sie auf
# .r3_unknown und werden mit "xor eax,eax" beantwortet — ein Ergebnistest sähe
# eine 0 und könnte sie nicht von einer echten 0 unterscheiden.
#
# Deshalb wird die emittierte Befehlsfolge geprüft:
#   MOV rsi,-5 / SYSCALL   Blockadresse holen
#   MOV rcx,<nr>           Nummer in den Block …
#   MOV [rax+0],rcx        … an Offset 0
#   MOV rsi,-6 / SYSCALL   auslösen
#
# Vor dem Fix wäre der Test rot: sys_rtc_read/-datetime/-rdtsc/-utime_fd gab es
# nicht (Übersetzungsfehler), sys_time_ns/sys_vsync_wait emittierten
# MOV rax,<nr>; SYSCALL statt der Blockfolge.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

[ -x "$LYXC" ] || { echo "FAIL: $LYXC fehlt"; exit 1; }

cat > "$TMP/zeit.lyx" <<'LYX'
fn main(): int64 {
    var hm: int64 := sys_rtc_read();
    var dt: int64 := sys_rtc_datetime();
    var ts: int64 := sys_rdtsc();
    var ns: int64 := sys_time_ns();
    var vs: int64 := sys_vsync_wait();
    var ut: int64 := sys_utime_fd(3, 1234);
    return hm + dt + ts + ns + vs + ut;
}
LYX

# Gegenprobe ohne Zeitaufrufe: trennt unsere Folgen von denen, die das Backend
# ohnehin emittiert (der Canary-Seed benutzt 134 und 138 selbst).
cat > "$TMP/leer.lyx" <<'LYX'
fn main(): int64 { return 0; }
LYX

if ! "$LYXC" --target=lyxos "$TMP/zeit.lyx" -o "$TMP/zeit.lbf" > "$TMP/log" 2>&1; then
    echo "FAIL Übersetzung: $(tail -3 "$TMP/log")"; exit 1
fi
ok "uebersetzt --target=lyxos"
"$LYXC" --target=lyxos "$TMP/leer.lyx" -o "$TMP/leer.lbf" > /dev/null 2>&1

xxd -p "$TMP/zeit.lbf" | tr -d '\n' > "$TMP/zeit.hex"
xxd -p "$TMP/leer.lbf" | tr -d '\n' > "$TMP/leer.hex"

cnt() { grep -o "$1" "$2" 2>/dev/null | wc -l; }

# --- 1. Blockweg: sechs Aufrufe, also je sechs Sentinels ------------------
n="$(cnt 48befbffffffffffffff "$TMP/zeit.hex")"   # MOV rsi,-5
m="$(cnt 48befbffffffffffffff "$TMP/leer.hex")"
[ "$((n-m))" -eq 6 ] && ok "sechs mal Blockadresse geholt (mmap-Sentinel -5)" \
                     || no "Sentinel -5" "erwartet 6 zusaetzliche, gezaehlt $((n-m))"
n="$(cnt 48befaffffffffffffff "$TMP/zeit.hex")"   # MOV rsi,-6
m="$(cnt 48befaffffffffffffff "$TMP/leer.hex")"
[ "$((n-m))" -eq 6 ] && ok "sechs mal ausgeloest (mmap-Sentinel -6)" \
                     || no "Sentinel -6" "erwartet 6 zusaetzliche, gezaehlt $((n-m))"

# --- 2. Je Aufruf die richtige Nummer, in den Block geschrieben -----------
# MOV rcx,<nr> (48 B9 imm64) unmittelbar gefolgt von MOV [rax+0],rcx (48 89 48 00).
pruef_nr() {   # $1=Name $2=Nummer-Byte (little endian, erstes Byte) $3=Nummer
    local pat="48b9${2}0000000000000048894800"
    local z l
    z="$(cnt "$pat" "$TMP/zeit.hex")"; l="$(cnt "$pat" "$TMP/leer.hex")"
    [ "$((z-l))" -eq 1 ] && ok "$1 → Nr. $3 in den Block" \
                         || no "$1 (Nr. $3)" "erwartet genau 1 zusaetzliche Folge, gezaehlt $((z-l))"
}
pruef_nr sys_vsync_wait   74 116
pruef_nr sys_time_ns      75 117
pruef_nr sys_rtc_read     86 134
pruef_nr sys_rtc_datetime 8a 138
pruef_nr sys_utime_fd     8c 140
pruef_nr sys_rdtsc        e4 228

# --- 3. Kein Registerweg für diese Nummern -------------------------------
# MOV rax,<nr> (48 B8 imm64) darf für die vier reinen Zeitnummern gar nicht
# vorkommen; 134 und 138 benutzt der Canary-Seed selbst, dort zaehlt die
# Differenz zur Gegenprobe.
pruef_kein_reg() {  # $1=Name $2=Nummer-Byte $3=Nummer
    local pat="48b8${2}0000000000000"
    local z l
    z="$(cnt "$pat" "$TMP/zeit.hex")"; l="$(cnt "$pat" "$TMP/leer.hex")"
    [ "$((z-l))" -eq 0 ] && ok "$1 nicht ueber den Registerweg (Nr. $3)" \
                         || no "$1 (Nr. $3)" "$((z-l)) zusaetzliche MOV rax,$3 — Whitelist kennt die Nummer nicht"
}
pruef_kein_reg sys_vsync_wait   74 116
pruef_kein_reg sys_time_ns      75 117
pruef_kein_reg sys_rtc_read     86 134
pruef_kein_reg sys_rtc_datetime 8a 138
pruef_kein_reg sys_utime_fd     8c 140
pruef_kein_reg sys_rdtsc        e4 228

# --- 4. Argumente landen an a0 und a1 ------------------------------------
# sys_utime_fd(fd, mtime): MOV [rax+8],rcx und MOV [rax+16],rcx nach der Nummer.
if grep -q "48b98c0000000000000048894800488b4d..48894808488b4d..4889481048b809" "$TMP/zeit.hex"; then
    ok "sys_utime_fd legt beide Argumente in a0/a1"
else
    no "sys_utime_fd Argumente" "a0/a1-Folge nicht gefunden"
fi

# --- 5. Mehr als vier Argumente bricht ab --------------------------------
# Kein Zeit-Builtin hat fuenf; geprueft wird die Schranke selbst, damit sie
# nicht spaeter still verschwindet.
if grep -q "hat mehr als vier Argumente" "$ROOT/src/backend/lyxos/emit_lyxos.lyx"; then
    ok "Schranke bei vier Argumenten vorhanden"
else
    no "Argument-Schranke" "emitBlockSyscall meldet nicht mehr bei >4 Argumenten"
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
