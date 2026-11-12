#!/bin/bash
# §10.9/§10.10 der LyxOS-ABI: die 27 nachgereichten Aufrufe (Kernel-Nummern
# 300-326) muessen auf --target=lyxos genau ihre eigene Nummer emittieren.
#
# Der Test prueft NICHT nur, dass gebaut wird. Er liest die erzeugten Bytes und
# verlangt: die eigene Nummer steht drin, und KEINE der 26 anderen Nummern aus
# derselben Tabelle. Sonst faende er einen vertauschten Zahlendreher nicht --
# und genau der waere hier der teure Fehler, weil eine falsche Nummer in LyxOS
# einen fremden Handler trifft (Linux 158 haette dort sys_iofs_write_lpid
# getroffen, das eine 4-KB-Seite ins Dateisystem schreibt).

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Name Argumentzahl LyxOS-Nummer
TAB="sys_access 2 300
sys_fcntl 3 301
sys_dup2 2 302
sys_dup3 3 303
sys_ftruncate 2 304
sys_fsync 1 305
sys_fdatasync 1 306
sys_uname 1 307
sys_getcpu 2 308
sys_readv 3 309
sys_writev 3 310
sys_statfs 2 311
sys_sched_getaffinity 3 312
sys_sched_setaffinity 3 313
sys_getpriority 2 314
sys_setpriority 3 315
sys_futex_wait 2 316
sys_futex_wake 2 317
sys_futex_requeue 3 318
sys_kill 2 319
sys_pipe2 2 320
sys_udp_open 1 321
sys_udp_close 1 322
sys_sendto 4 323
sys_recvfrom 4 324
sys_getsockname 3 325
sys_getpeername 2 326"

ALLE=$(echo "$TAB" | awk '{print $3}' | paste -sd,)

while read -r NAME ARGC NR; do
    [ -z "$NAME" ] && continue
    ARGS=""
    i=0
    while [ "$i" -lt "$ARGC" ]; do
        [ -n "$ARGS" ] && ARGS="$ARGS, "
        ARGS="${ARGS}a$i"
        i=$((i + 1))
    done
    {
        echo "fn main(): int64 {"
        i=0
        while [ "$i" -lt "$ARGC" ]; do
            echo "  var a$i: int64 := $((4096 + i));"
            i=$((i + 1))
        done
        echo "  var r: int64 := $NAME($ARGS);"
        echo "  return r;"
        echo "}"
    } > "$TMP/p.lyx"

    if ! $LYXC "$TMP/p.lyx" --target=lyxos -o "$TMP/p.lbf" >"$TMP/p.log" 2>&1; then
        echo "FAIL $NAME: baut nicht"
        sed -n '2,4p' "$TMP/p.log"
        FAIL=$((FAIL + 1))
        continue
    fi
    # zusaetzlich: kein stiller Durchfall auf einen anderen Builtin
    if grep -qi "unbekannt\|wird nicht behandelt" "$TMP/p.log"; then
        echo "FAIL $NAME: Meldung im Bau -- $(grep -i -m1 'unbekannt\|wird nicht behandelt' "$TMP/p.log")"
        FAIL=$((FAIL + 1))
        continue
    fi

    OUT=$(NR="$NR" ARGC="$ARGC" ALLE="$ALLE" python3 - "$TMP/p.lbf" <<'PY'
import os, struct, sys
d = open(sys.argv[1], 'rb').read()
nr = int(os.environ['NR']); argc = int(os.environ['ARGC'])
alle = [int(x) for x in os.environ['ALLE'].split(',')]
def imm(n):                       # mov rax, imm64
    return bytes([0x48, 0xB8]) + struct.pack('<q', n)
fehler = []
if imm(nr) not in d:
    fehler.append("Nummer %d fehlt" % nr)
fremd = [n for n in alle if n != nr and imm(n) in d]
if fremd:
    fehler.append("fremde Nummer(n) aus derselben Tabelle: %s" % fremd)
# 4-Argument-Aufrufe muessen r10 laden (arg4); SYSCALL zerstoert rcx
if argc >= 4 and bytes([0x4C, 0x8B, 0x55]) not in d:
    fehler.append("kein r10-Laden trotz 4 Argumenten")
print("; ".join(fehler))
PY
)
    if [ -n "$OUT" ]; then
        echo "FAIL $NAME (soll $NR): $OUT"
        FAIL=$((FAIL + 1))
    else
        echo "PASS $NAME -> $NR"
        PASS=$((PASS + 1))
    fi
done <<< "$TAB"


# ---------------------------------------------------------------------------
# Zweiter Teil: die Linux-Form derselben Namen muss LAUT scheitern.
#
# Acht dieser Namen gibt es auf dem x86-Weg mit Linux-Signatur. Naehme das
# Lowering einfach die ersten N Argumente, wuerde aus
# sendto(fd, buf, len, flags, addr, addrlen) ein dst := flags — das Paket
# ginge irgendwohin, ohne eine einzige Meldung. Genau dieser stille Default
# ist hier verboten, also wird er geprueft.
echo "-- Linux-Form muss scheitern --"
while read -r NAME ARGC; do
    [ -z "$NAME" ] && continue
    ARGS=""
    i=0
    while [ "$i" -lt "$ARGC" ]; do
        [ -n "$ARGS" ] && ARGS="$ARGS, "
        ARGS="${ARGS}$((100 + i))"
        i=$((i + 1))
    done
    echo "fn main(): int64 { return $NAME($ARGS); }" > "$TMP/w.lyx"
    if $LYXC "$TMP/w.lyx" --target=lyxos -o "$TMP/w.lbf" >"$TMP/w.log" 2>&1; then
        echo "FAIL $NAME mit $ARGC Argumenten (Linux-Form): baut durch, statt zu melden"
        FAIL=$((FAIL + 1))
    elif ! grep -q "erwartet auf LyxOS" "$TMP/w.log"; then
        echo "FAIL $NAME: scheitert, aber ohne die erklaerende Meldung"
        sed -n '2,3p' "$TMP/w.log"
        FAIL=$((FAIL + 1))
    else
        echo "PASS $NAME mit $ARGC Argumenten: meldet die LyxOS-Form"
        PASS=$((PASS + 1))
    fi
done <<'LINUXFORM'
sys_sendto 6
sys_recvfrom 6
sys_futex_wait 6
sys_futex_wake 4
sys_futex_requeue 4
sys_getpeername 3
sys_getcpu 3
LINUXFORM

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
