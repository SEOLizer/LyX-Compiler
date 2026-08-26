#!/bin/bash
# #1734: kein Aufruf darf eine Syscall-Nummer emittieren, die es in LyxOS
# nicht gibt.
#
# Die LyxOS-ABI hat zwei Tabellen: einen hex-gruppierten Entwurf (0x0400 IPC,
# 0x0800 KI, 0x0C00 IOFS ...) und das, was im Kernel steht. Der Entwurf sieht
# systematisch aus und ist zu grossen Teilen nie gebaut worden.
#
# Was es wirklich gibt, sagt die aus kernel/ring3.lyx ERZEUGTE Tabelle
# (tools/sync_syscalls.py, 197 Nummern) plus die Abfangstellen im Bootloader.
# Der erste Anlauf dieser Pruefung stuetzte sich auf eine Handfassung
# ("0-228 und 300-326") und wies damit 32 BELEGTE Nummern ab, darunter drei,
# die dieses Backend wirklich emittiert. Deshalb prueft diese Datei BEIDE
# Richtungen: Erfundenes muss melden, Belegtes muss bauen.
#
# Eine erfundene Nummer stuerzt NICHT ab -- der Bootloader liefert fuer
# Unbekanntes still 0 und meldet Erfolg (.r3_unknown). Diese Pruefung ist
# damit die einzige Stelle, die es ueberhaupt bemerken kann.

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
# sys_seek stand hier als Beispiel fuer eine Luecke. Es ist keine: die aus dem
# Kernel erzeugte Tabelle nennt fuer lseek die 8 (#1734 Punkt 3). Die Pruefung
# ist deshalb umgedreht — sie muss jetzt BAUEN, und weiter unten wird die
# emittierte Nummer nachgesehen.
pruefe_baut "sys_seek (8)"            "sys_seek(1, 0, 0)"
# #1734: sys_readdir stand hier als Phantasienummer. Es ist keine -- die
# erzeugte Tabelle fuehrt 522 mit echtem Handler (VfsReadDir). Umgedreht.
pruefe_baut "sys_readdir (522)"       "sys_readdir(1, 1, 1)"
pruefe_meldet "sys_socket (0x0600)"   "sys_socket(1, 1, 1)"
pruefe_meldet "sys_connect (0x0604)"  "sys_connect(1, 1, 1)"
pruefe_meldet "sys_mutex_lock (0x0401)" "sys_mutex_lock(1, 0)"
pruefe_meldet "sys_timer_create (0x0502)" "sys_timer_create(0, 1, 0)"
pruefe_meldet "sys_pledge (0x0703)"   "sys_pledge(1, 1)"
pruefe_meldet "sys_task_spawn (0x0B00)" "sys_task_spawn(1, 1, 1, 0)"
pruefe_meldet "sys_ai_infer (0x0804)" "sys_ai_infer(1, 1, 1, 0)"
pruefe_meldet "sys_iofs_mount (0x0C00)" "sys_iofs_mount(1, 0)"
pruefe_meldet "sys_trace_event (0x0A00)" "sys_trace_event(1, 1)"

echo "-- LX-VFS-Block: belegt, war faelschlich abgewiesen --"
# Diese drei wurden vom ersten Anlauf des Waechters zum Uebersetzungsfehler
# gemacht, obwohl sie funktionieren. Im Kernel nachgesehen: sys_stat macht
# open->fstat->close, sys_dup ruft VfsDup, sys_readdir ruft VfsReadDir.
pruefe_baut "sys_stat (517)"          "sys_stat(0, 0, 0, 0)"
pruefe_baut "sys_dup (523)"           "sys_dup(1, 0)"

echo "-- exit kommt aus dem BOOTLOADER, nicht aus der Tabelle --"
# 60/231 stehen nicht in der erzeugten Tabelle (die kennt nur
# Dispatcher-Eintraege), werden aber in bootloader/boot.asm abgefangen. Wer die
# Tabelle fuer vollstaendig haelt, weist exit ab -- und damit jedes Programm.
echo 'fn main(): int64 { exit(3); return 0; }' > "$TMP/e.lyx"
if $LYXC "$TMP/e.lyx" --target=lyxos -o "$TMP/e.lbf" >"$TMP/e.log" 2>&1; then
    echo "PASS exit (60) baut"; PASS=$((PASS + 1))
else
    echo "FAIL exit (60) baut nicht: $(grep -m1 -i error "$TMP/e.log")"; FAIL=$((FAIL + 1))
fi

echo "-- Luecken INNERHALB der Spannen muessen weiter auffallen --"
# 204, 206-209 und 216 sind unbelegt, liegen aber mitten in einer sonst
# belegten Spanne. Eine grobe Pruefung 0..255 wuerde sie durchlassen -- genau
# die Grosszuegigkeit, aus der #1734 entstanden ist.
pruefe_meldet "sys_umount (528)"      "sys_umount(1, 1, 1)"

echo "-- echte Nummern muessen bleiben --"
# #1742: drei Argumente, kein dir_fd — die Vierer-Form wird weiter unten geprueft.
pruefe_baut "sys_open (2)"        "sys_open(1, 1, 0)"
pruefe_baut "sys_write (95)"      "sys_write(1, 1, 1)"
pruefe_baut "sys_getpid (136)"    "sys_getpid()"
pruefe_baut "sys_yield (24)"      "sys_yield()"
pruefe_baut "sys_win_create (110)" "sys_win_create(0, 0, 10, 10, 0)"
pruefe_baut "sys_access (300)"    "sys_access(1, 0)"
pruefe_baut "sys_pipe2 (320)"     "sys_pipe2(1, 0)"
pruefe_baut "sys_recvfrom (324)"  "sys_recvfrom(0, 1, 1, 1)"

# ---------------------------------------------------------------------------
# #1734 Punkt 3: die zwei Widersprueche sind geklaert.
#
# `lseek` emittierte 0x0204 = 516 mit dem Vermerk "kernel-adoptiert" — eine
# Behauptung ueber ein fremdes Repo. Die aus kernel/ring3.lyx ERZEUGTE Tabelle
# nennt dreimal unabhaengig die 8. `stat` emittierte 0x0205 = 517; einen
# Aufruf ueber den PFAD gibt es in LyxOS gar nicht, wohl aber sys_fstat (135)
# ueber einen Deskriptor.
#
# Geprueft werden die BYTES, weil sich das lyxos-Ziel hier nicht ausfuehren
# laesst. Die Gegenprobe (516/517 sind WEG) gehoert dazu: die neue Nummer
# koennte drinstehen und die alte trotzdem auch.
echo "-- geklaerte Nummern (#1734 Punkt 3) --"

pruefe_bytes() {   # Name, Quelle, "muss:a,b" , "darf-nicht:c,d"
    printf '%s' "$2" > "$TMP/n.lyx"
    if ! $LYXC "$TMP/n.lyx" --target=lyxos -o "$TMP/n.lbf" >"$TMP/n.log" 2>&1; then
        echo "FAIL $1 baut: $(grep -m1 -iE 'error|gibt es' "$TMP/n.log")"
        FAIL=$((FAIL + 1))
        return
    fi
    local fehlt
    fehlt=$(MUSS="$3" NICHT="$4" python3 - "$TMP/n.lbf" <<'PY2'
import os, struct, sys
d = open(sys.argv[1], 'rb').read()
def hat(n):
    return bytes([0x48, 0xB8]) + struct.pack('<q', n) in d
fehler = []
for x in os.environ['MUSS'].split(','):
    if x and not hat(int(x)):
        fehler.append("Nummer %s fehlt" % x)
for x in os.environ['NICHT'].split(','):
    if x and hat(int(x)):
        fehler.append("Nummer %s steht noch drin" % x)
print("; ".join(fehler))
PY2
)
    if [ -z "$fehlt" ]; then
        echo "PASS $1"; PASS=$((PASS + 1))
    else
        echo "FAIL $1: $fehlt"; FAIL=$((FAIL + 1))
    fi
}

pruefe_bytes "lseek emittiert 8, nicht 516" \
    'fn main(): int64 { return lseek(3, 0, 2); }' "8" "516"

# stat wird aus open(2) + fstat(135) + close(3) zusammengesetzt.
pruefe_bytes "stat nutzt open+fstat+close, nicht 517" \
    'fn main(): int64 { var out: int64 := 0; return stat("/etc/hostname"c, out); }' "2,135,3" "517"

# ---------------------------------------------------------------------------
# #1741: Entwurfsnummern UNTERHALB von 229.
#
# Die Nummernpruefung oben vergleicht gegen den BEREICH 0-228, nicht gegen die
# BELEGUNG. Acht Zuordnungen aus der hex-gruppierten Entwurfs-ABI landen genau
# dort: 0x0004..0x000D werden zu 4, 5, 6, 8, 10, 11, 12, 13. Der schaerfste
# Fall war sys_gettid → 8, und die 8 ist im Kernel sys_lseek — ein Aufruf, der
# eine Thread-Nummer liefern soll, fuehrte einen Seek aus.
echo "-- Entwurfsnummern unter 229 (#1741) --"

pruefe_meldet_text() {   # Name, Aufruf, erwarteter Textbaustein
    echo "fn main(): int64 { return $2; }" > "$TMP/u.lyx"
    if $LYXC "$TMP/u.lyx" --target=lyxos -o "$TMP/u.lbf" >"$TMP/u.log" 2>&1; then
        echo "FAIL $1: baut durch, obwohl es den Aufruf nicht gibt"; FAIL=$((FAIL + 1))
    elif ! grep -q "$3" "$TMP/u.log"; then
        echo "FAIL $1: scheitert, aber ohne die erklaerende Meldung"; FAIL=$((FAIL + 1))
    else
        echo "PASS $1 meldet"; PASS=$((PASS + 1))
    fi
}

pruefe_meldet_text "sys_gettid"       "sys_gettid()"            "sys_getpid (136)"
pruefe_meldet_text "sys_thread_spawn" "sys_thread_spawn(0,0,0,0)" "sys_spawn_child"
pruefe_meldet_text "sys_thread_exit"  "sys_thread_exit(0)"      "kein Thread-Ende"
pruefe_meldet_text "sys_wait"         "sys_wait(0,0,0)"         "nicht vorgesehen"
pruefe_meldet_text "sys_priority"     "sys_priority(0,0)"       "314/315"
pruefe_meldet_text "sys_getrandom"    "sys_getrandom(0,0,0)"    "keine Zufallsquelle"
pruefe_meldet_text "sys_signal_mask"  "sys_signal_mask(0,0)"    "kein Signalmodell"

# Schlafen gibt es — aber in Ticks (Nr. 25), nicht in Nanosekunden. Geprueft
# wird die BEFEHLSFOLGE `mov rax, nr; syscall`, nicht nur die Zahl irgendwo:
# eine 10 steht in jedem zweiten Programm als Konstante herum.
echo "fn main(): int64 { return sys_sleep_ns(1000000); }" > "$TMP/sl.lyx"
if $LYXC "$TMP/sl.lyx" --target=lyxos -o "$TMP/sl.lbf" >"$TMP/sl.log" 2>&1; then
    ERG=$(python3 - "$TMP/sl.lbf" <<'PY2'
import struct, sys
d = open(sys.argv[1], 'rb').read()
def folge(n):
    return d.count(bytes([0x48, 0xB8]) + struct.pack('<q', n) + bytes([0x0F, 0x05]))
print("%d %d" % (folge(25), folge(10)))
PY2
)
    set -- $ERG
    if [ "$1" -ge 1 ] && [ "$2" -eq 0 ]; then
        echo "PASS sys_sleep_ns nutzt sleep_ticks (25), nicht die 10"; PASS=$((PASS + 1))
    else
        echo "FAIL sys_sleep_ns: 25 kam ${1}x vor, 10 kam ${2}x vor"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL sys_sleep_ns baut: $(grep -m1 -iE 'error|gibt es' "$TMP/sl.log")"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# #1742: Pfad-Aufrufe ohne dir_fd.
#
# Vier Nummern wurden aus zwei Stellen mit verschiedener Argumentzahl gerufen —
# eine davon musste falsch sein. §10.7 der ABI-Antwort entscheidet es:
# "Pfad-Syscalls ohne dir_fd — CWD implizit". Die Entwurfsfassung schob ein
# dir_fd vor den Pfad und verschob damit ALLE Argumente um eins.
#
# Das ueberzaehlige Argument still zu verwerfen waere falsch: wer AT_ROOT
# uebergibt, meint nicht das Arbeitsverzeichnis. Deshalb Meldung.
echo "-- Pfad-Aufrufe ohne dir_fd (#1742) --"

pruefe_baut "sys_open flach (3 Args)"    'sys_open("f"c as int64, 0, 0)'
pruefe_baut "sys_mkdir flach (1 Arg)"    'sys_mkdir("d"c as int64)'
pruefe_baut "sys_unlink flach (1 Arg)"   'sys_unlink("f"c as int64)'
pruefe_baut "sys_rename flach (2 Args)"  'sys_rename("a"c as int64, "b"c as int64)'

pruefe_meldet_text "sys_open mit dir_fd"   'sys_open(0 - 1, "f"c as int64, 0, 0)' "dir_fd"
pruefe_meldet_text "sys_mkdir mit dir_fd"  'sys_mkdir(0 - 1, "d"c as int64, 0)'   "dir_fd"
pruefe_meldet_text "sys_unlink mit dir_fd" 'sys_unlink(0 - 1, "f"c as int64, 0)'  "dir_fd"
pruefe_meldet_text "sys_rename mit dir_fd" 'sys_rename(0 - 1, "a"c as int64, 0 - 1, "b"c as int64)' "dir_fd"

# Und die Gegenprobe in den Bytes: drei Argumente heisst rdi/rsi/rdx — ein
# Ladebefehl fuer r10 (das vierte Argument) darf nicht vorkommen. Die
# Argumentzahl allein am Quelltext zu pruefen wuerde die Emission nicht
# erfassen; genau dort lag der Fehler.
echo 'fn main(): int64 { return sys_open("f"c as int64, 0, 0); }' > "$TMP/o.lyx"
if $LYXC "$TMP/o.lyx" --target=lyxos -o "$TMP/o.lbf" >"$TMP/o.log" 2>&1; then
    if python3 - "$TMP/o.lbf" <<'PY2'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if bytes([0x4C, 0x8B, 0x55]) not in d else 1)   # MOV r10, [rbp+off]
PY2
    then
        echo "PASS sys_open laedt kein viertes Argument"; PASS=$((PASS + 1))
    else
        echo "FAIL sys_open laedt r10, also ein viertes Argument"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL sys_open flach baut: $(grep -m1 -iE 'error|erwartet' "$TMP/o.log")"; FAIL=$((FAIL + 1))
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
