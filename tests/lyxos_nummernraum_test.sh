#!/bin/bash
# #1734: kein Aufruf darf eine Syscall-Nummer emittieren, die es in LyxOS
# nicht gibt.
#
# Die LyxOS-ABI hat zwei Tabellen: einen hex-gruppierten Entwurf (0x0400 IPC,
# 0x0800 KI, 0x0C00 IOFS ...) und das, was im Kernel steht. Der Entwurf sieht
# systematisch aus und ist zu grossen Teilen nie gebaut worden. Implementiert
# sind flach 0-228 und 300-326, dazu 2063-2066 und 2315.
#
# Heute trifft eine erfundene Nummer nichts, weil 229-399 frei ist. Genau das
# macht den Fehler unsichtbar -- und waechst die flache Tabelle, wandert eine
# Phantasienummer nach der anderen in belegtes Gebiet.

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

pruefe_meldet() {   # Name, Aufruf
    local NAME="$1" AUFRUF="$2"
    echo "fn main(): int64 { return $AUFRUF; }" > "$TMP/p.lyx"
    if $LYXC "$TMP/p.lyx" --target=lyxos -o "$TMP/p.lbf" >"$TMP/p.log" 2>&1; then
        echo "FAIL $NAME: baut durch, obwohl die Nummer im Kernel fehlt"
        FAIL=$((FAIL + 1))
    elif ! grep -q "gibt es in LyxOS nicht" "$TMP/p.log"; then
        echo "FAIL $NAME: scheitert, aber nicht an der Nummernpruefung"
        sed -n '2,3p' "$TMP/p.log"
        FAIL=$((FAIL + 1))
    elif ! grep -q "Builtin-ID [0-9]" "$TMP/p.log"; then
        echo "FAIL $NAME: Meldung nennt die Builtin-ID nicht -- ohne sie ist sie nicht auffindbar"
        FAIL=$((FAIL + 1))
    else
        echo "PASS $NAME: $(grep -o 'Syscall-Nummer [0-9]*' "$TMP/p.log" | head -1) wird gemeldet"
        PASS=$((PASS + 1))
    fi
}

pruefe_baut() {     # Name, Aufruf
    local NAME="$1" AUFRUF="$2"
    echo "fn main(): int64 { return $AUFRUF; }" > "$TMP/q.lyx"
    if $LYXC "$TMP/q.lyx" --target=lyxos -o "$TMP/q.lbf" >"$TMP/q.log" 2>&1; then
        echo "PASS $NAME: baut weiterhin"
        PASS=$((PASS + 1))
    else
        echo "FAIL $NAME: baut nicht mehr -- die Pruefung schlaegt zu weit aus"
        sed -n '2,3p' "$TMP/q.log"
        FAIL=$((FAIL + 1))
    fi
}

echo "-- Entwurfs-Nummern muessen melden --"
pruefe_meldet "sys_poll (0x0300)"     "sys_poll(1, 1, 1)"
pruefe_meldet "sys_ioctl (0x0301)"    "sys_ioctl(1, 1, 1)"
pruefe_meldet "sys_port_in (0x0304)"  "sys_port_in(1, 1)"
pruefe_meldet "sys_seek (0x0204)"     "sys_seek(1, 0, 0)"
pruefe_meldet "sys_readdir (0x020A)"  "sys_readdir(1, 1, 1)"
pruefe_meldet "sys_socket (0x0600)"   "sys_socket(1, 1, 1)"
pruefe_meldet "sys_connect (0x0604)"  "sys_connect(1, 1, 1)"
pruefe_meldet "sys_mutex_lock (0x0401)" "sys_mutex_lock(1, 0)"
pruefe_meldet "sys_timer_create (0x0502)" "sys_timer_create(0, 1, 0)"
pruefe_meldet "sys_pledge (0x0703)"   "sys_pledge(1, 1)"
pruefe_meldet "sys_task_spawn (0x0B00)" "sys_task_spawn(1, 1, 1, 0)"
pruefe_meldet "sys_ai_infer (0x0804)" "sys_ai_infer(1, 1, 1, 0)"
pruefe_meldet "sys_iofs_mount (0x0C00)" "sys_iofs_mount(1, 0)"
pruefe_meldet "sys_trace_event (0x0A00)" "sys_trace_event(1, 1)"

echo "-- echte Nummern muessen bleiben --"
pruefe_baut "sys_open (2)"        "sys_open(1, 1, 1, 0)"
pruefe_baut "sys_write (95)"      "sys_write(1, 1, 1)"
pruefe_baut "sys_getpid (136)"    "sys_getpid()"
pruefe_baut "sys_yield (24)"      "sys_yield()"
pruefe_baut "sys_win_create (110)" "sys_win_create(0, 0, 10, 10, 0)"
pruefe_baut "sys_access (300)"    "sys_access(1, 0)"
pruefe_baut "sys_pipe2 (320)"     "sys_pipe2(1, 0)"
pruefe_baut "sys_recvfrom (324)"  "sys_recvfrom(0, 1, 1, 1)"

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
