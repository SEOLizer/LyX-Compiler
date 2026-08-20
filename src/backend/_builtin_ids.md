# Builtin-IDs (`IRO_CALL_BUILTIN`)

Die ID im `IRO_CALL_BUILTIN`-Befehl ist ein **globaler Namensraum über alle
Backends**. Vergeben wird sie in `src/ir_lower.lyx`, ausgewertet in
`emitBuiltinCall` des jeweiligen Backends.

Diese Datei ist die Belegungsliste. Sie existiert, weil die Vergabe vorher in
jedem Backend-Zweig neu erfunden wurde: `Printf` und `mem_barrier()` trugen
beide die 10, wodurch `Printf` auf Linux-ARM64 eine Speicherbarriere emittierte
und nichts ausgab — ohne Meldung (#1037).

**Vor der Vergabe einer neuen ID hier nachsehen und den Eintrag ergänzen.**
`tests/builtin_id_test.sh` prüft, dass keine ID doppelt vergeben ist und dass
jede vergebene ID hier steht.

## Allgemeine IDs

Die ID benennt die **emittierte Operation**, nicht den Namen im Quelltext:
mehrere Builtins dürfen dieselbe ID benutzen, wenn sie denselben Code brauchen.
Die Spalte „Lowering von" führt deshalb alle Aufrufer auf — der Test prüft
gegen genau diese Liste, ein nicht eingetragener Aufrufer gilt als Kollision.

| ID | Operation | Lowering von | Anmerkung |
|---:|---|---|---|
| 1 | `write(1, ptr, len)` | `PrintStr`, `PrintLn`, `Print` | Länge −1 = „strlen zur Laufzeit"; **nur das lyxos-Backend wertet den Sentinel aus** |
| 2 | Ganzzahl nach stdout | `PrintInt`, `PrintLn`, `Print` | ohne Zeilenumbruch; `Print`/`PrintLn` seit #1716 auch mit Zahl-Argument, `PrintLn` haengt den Umbruch als eigenen ID-1-Aufruf an |
| 3 | Prozessende | `Exit`, `panic` | `panic` beendet mit 1 (#1720) |
| 4 | Pseudozufallszahl (xorshift64) | `Random` | #1728; der Zustand liegt im Wort hinter den Programm-Globalen |
| 5 | Zustand des Zufallsgenerators setzen | `RandomSeed` | #1728 |
| 6 | Teilzeichenkette | `StrSub` | |
| 7 | Verkettung | `StrConcat` | |
| 8 | Kopie | `StrCopy` | |
| 9 | Gleitkomma nach stdout | `PrintFloat` | Linux-ARM64 bislang No-op |
| 10 | Datenbarriere (DMB SY) | `mem_barrier` | |
| 11 | Befehlsbarriere (ISB SY) | `inst_barrier` | |
| 12 | Formatierte Ausgabe | `Printf` | war bis 1.0.11C fälschlich 10 |
| 13 | `write(2, ptr, strlen(ptr))` | `EPrintStr`, `EPrintStrLn`, `EPrint`, `panic` | #1388; Länge rechnet das Backend selbst |
| 14 | Zeilenumbruch nach stderr | `EPrintStrLn`, `EPrintLn`, `panic` | #1388 |
| 15 | Länge einer Zeichenkette | `StrLen`, `StrLength` | #1388 |
| 16 | Ganzzahl als Dezimaltext, Zeiger zurück | `IntToStr`, `StrFromInt` | #1720; der Puffer stammt aus mmap, nicht vom Stapel — er muss den Aufruf überleben |
| 17 | Anzahl der Programmargumente | `GetArgC` | #1720; auf lyxos 0 — `_start` liest keinen argv |
| 18 | Zeiger auf den Argumentvektor | `GetArgV`, `GetArg` | #1720; `GetArg(i)` ist ID 18 plus ein Lesezugriff, keine eigene ID |
| 19 | Zeiger auf den Umgebungsblock | `GetEnvBlock` | #1720; auf lyxos und Linux 0 — nur die win64-Laufzeit setzt ihn (#1677) |

**Der allgemeine Bereich ist ausgeschöpft** (mit #1728 auch 4 und 5) — wer eine weitere allgemeine ID braucht, erweitert den Bereich, statt eine bestehende doppelt zu belegen.

## Backend-Abdeckung der allgemeinen IDs

| Backend | behandelt | fehlt |
|---|---|---|
| x86-64 (ELF) | eigener Pfad ohne IR-Builtins | — |
| ARM64 Linux | 1, 2, 3, 6–11, **13, 14, 15**, **200–205, 208, 209** | 12 (`Printf`) — meldet Fehler |
| ARM64 Windows | 1, 2, 3, 6, 7, 8, 9, 12, **200–205, 208, 209** | 10/11 als ausdrückliches No-op |
| RISC-V Linux | 1, 2, 3, **13, 15, 200–205, 208, 209** | Rest meldet Fehler (#1388) |
| ARM Cortex-M | **200–205, 208, 209**; 1, 2, 3, 9, 12, 13, 14 als ausdrücklicher No-op bzw. BKPT | alles Übrige meldet Fehler |
| Xtensa | 1, 2 | Rest meldet Fehler (#1388, Kodierungen fehlen — vgl. #1281) |
| lyxos (LBF) | 1, 2, **3**, **4**, **5**, **6**, **9**, **13, 14, 15, 16, 17, 18, 19** + 20 … 256 | 7, 8, 10–12 — melden Fehler (#1715) |

**Speicherzugriffe (200–205, 208, 209)** sind seit #1388 auf ARM64, RISC-V und
Cortex-M umgesetzt. Sie brauchen kein Betriebssystem und gelten deshalb auch
im Windows- und im freistehenden Zweig.

Eine nicht behandelte ID **muss laut scheitern**. Ein stiller Default-Zweig
verwandelt jede Lücke in stille Fehlfunktion — dieselbe Klasse wie der
LyxOS-Builtin-Misdispatch (PR #839) und der verworfene Opcode-Catch-all
(PR #867).

## Bereich ab 300 — allgemeine IDs, die im Block 1…19 keinen Platz mehr fanden

| ID | Operation | Lowering von | Anmerkung |
|---:|---|---|---|
| 300 | abrunden (`roundsd`, Modus 1) | `fFloor` | #1720; SSE4.1, wie auf dem x86-Weg |
| 301 | aufrunden (`roundsd`, Modus 2) | `fCeil` | #1720 |
| 302 | kaufmaennisch runden (`roundsd`, Modus 0) | `fRound` | #1720; zur geraden Zahl |

Warum oberhalb des Syscall-Bereichs und nicht darin: das sind keine Syscalls,
sondern Rechenoperationen, die jedes Backend umsetzen kann. Sie im
lyxos-Block zu vergeben haette den Namensraum belogen.

## Bereich 20 … 256 — lyxos-Syscalls

`237` ist `sys_clock_nanosleep` (#1720): eigene Nummer statt Alias auf
`nanosleep` (233), weil der timespec dort am dritten Argument steht und
`TIMER_ABSTIME` einen Zeitpunkt meint, keine Dauer — die Flagge zu ignorieren
hiesse, den absoluten Zeitstempel als Dauer zu verschlafen.

`238` ist `sys_gettimeofday` (#1720): das Ziel liefert die Zeit als
Nanosekunden aus `sys_time_ns` (117), nicht als gefuelltes `timeval` — die
Umrechnung in Sekunden und Mikrosekunden macht das Backend.

`239` meldet **-ENOSYS** (#1720) und wird von `sys_timerfd_create`,
`sys_timerfd_settime` und `sys_timerfd_gettime` geteilt. LyxOS hat ein anderes
Timer-Modell als Linux; eine Abbildung waere eine Behauptung ueber die
Wartesemantik, und fuer `gettime` gibt es gar keine Entsprechung. Eine ehrliche
Fehlermeldung ist besser als eine plausible Fehluebersetzung.

Vergeben in `src/ir_lower.lyx` (Abschnitt „VFS syscalls"), ausgewertet in
`src/backend/lyxos/emit_lyxos.lyx`. Eine LyxOS-Syscall-ID ist an **drei**
Stellen konsistent zu halten: `sema._regBuiltin`, das Lowering in `ir_lower`
und `emit_lyxos.emitBuiltinCall`.
