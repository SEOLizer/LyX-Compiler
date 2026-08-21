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

## Bereich ab 400 — allgemeine IDs, die im Block 1…19 keinen Platz mehr fanden

| ID | Operation | Lowering von | Anmerkung |
|---:|---|---|---|
| 400 | abrunden (`roundsd`, Modus 1) | `fFloor` | #1720; SSE4.1, wie auf dem x86-Weg |
| 401 | aufrunden (`roundsd`, Modus 2) | `fCeil` | #1720 |
| 402 | kaufmaennisch runden (`roundsd`, Modus 0) | `fRound` | #1720; zur geraden Zahl |
| 403 | f64 als Text, Zeiger zurück | `FloatToStr` | #1720; derselbe Formatierer wie ID 9, ohne Ausgabe |
| 404 | Zeichenketten auf Gleichheit | `StrEq`, `StrEquals` | #1720 |
| 405 | Anfang einer Zeichenkette prüfen | `StrStartsWith` | #1720 |
| 406 | Dateigröße oder −1 | `FileSize` | #1720; open + seek(ENDE) + close |
| 407 | Leerraum vorn/hinten entfernen | `StrTrim` | #1720; ändert an Ort und Stelle, gibt Zeiger zurück |
| 408 | Teilkette suchen, Index oder −1 | `StrFind` | #1720; leere Nadel → 0 |
| 409 | Datei ganz lesen, nullterminiert | `FileReadAll` | #1720; 0 bei Fehler |

Warum oberhalb des Syscall-Bereichs und nicht darin: das sind keine Syscalls,
sondern Rechenoperationen, die jedes Backend umsetzen kann. Sie im
lyxos-Block zu vergeben haette den Namensraum belogen.

**Warum 400 und nicht mehr 300.** Diese IDs lagen zuerst auf 300…309. Seit dem
2026-08-20 belegt LyxOS die *Syscall-Nummern* 300…326 (§10.9/§10.10). Das sind
zwei getrennte Namensräume — eine Kollision im Wortsinn war es nicht, und nichts
war dadurch kaputt. Verschoben wurde trotzdem: in `emit_lyxos.emitBuiltinCall`
stehen Builtin-ID und Syscall-Nummer in derselben Zeile nebeneinander
(`else if id == 172 { self.emitVfsSyscall(300, …) }`). Zwei gleiche Zahlen mit
verschiedener Bedeutung nebeneinander sind eine Falle für den nächsten Leser,
und die Zuordnungstabelle ist genau die Stelle, an der ein Zahlendreher
unbemerkt bliebe. Der Bereich 300…399 ist damit **den LyxOS-Nummern
vorbehalten** und wird für allgemeine IDs nicht mehr vergeben.

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

## Bereich 172 … 198 — LyxOS-Nummern 300 … 326 (§10.9/§10.10, Stand 2026-08-20)

Auf das Anforderungsdokument `work/lyxos/anforderungen-compiler.md` hin vom
LyxOS-Team umgesetzt und mit `/bin/systest.elf` bzw. gegen eine echte
Gegenstelle geprüft — nicht nur übersetzt.

| ID | LyxOS-Nr | Name | Argumente |
|---:|---:|---|---:|
| 172 | 300 | `sys_access` | 2 |
| 173 | 301 | `sys_fcntl` | 3 |
| 174 | 302 | `sys_dup2` | 2 |
| 175 | 303 | `sys_dup3` | 3 |
| 176 | 304 | `sys_ftruncate` | 2 |
| 177 | 305 | `sys_fsync` | 1 |
| 178 | 306 | `sys_fdatasync` | 1 |
| 179 | 307 | `sys_uname` | 1 |
| 180 | 308 | `sys_getcpu` | 2 |
| 181 | 309 | `sys_readv` | 3 |
| 182 | 310 | `sys_writev` | 3 |
| 183 | 311 | `sys_statfs` | 2 |
| 184 | 312 | `sys_sched_getaffinity` | 3 |
| 185 | 313 | `sys_sched_setaffinity` | 3 |
| 186 | 314 | `sys_getpriority` | 2 |
| 187 | 315 | `sys_setpriority` | 3 |
| 188 | 316 | `sys_futex_wait` | 2 |
| 189 | 317 | `sys_futex_wake` | 2 |
| 190 | 318 | `sys_futex_requeue` | 3 |
| 191 | 319 | `sys_kill` | 2 |
| 192 | 320 | `sys_pipe2` | 2 |
| 193 | 321 | `sys_udp_open` | 1 |
| 194 | 322 | `sys_udp_close` | 1 |
| 195 | 323 | `sys_sendto` | 4 |
| 196 | 324 | `sys_recvfrom` | 4 |
| 197 | 325 | `sys_getsockname` | 3 |
| 198 | 326 | `sys_getpeername` | 2 |

**Keine Formel, sondern Zeile für Zeile.** Andere Blöcke rechnen die Nummer aus
der ID (`0x0400 + (id - 72)`). Hier nicht: der Bereich hat zwei Quellen
(§10.9 und die nachgereichte §10.10) und keine Garantie, dass er lückenlos
bleibt. Eine Formel würde eine künftige Lücke stillschweigend überbrücken und
auf einen fremden Handler zeigen.

**Die Nummern sind nicht die von Linux.** Nur 0–3, 8, 9 und 24 stimmen zufällig
überein. Laut LyxOS-Team hätten **19 der 21** angefragten Aufrufe unter
Linux-Nummerierung einen bestehenden fremden Handler getroffen — Linux 158
(`arch_prctl`) etwa das dortige `sys_iofs_write_lpid`, das eine 4-KB-Seite ins
Dateisystem schreibt. Das ist #795 in schlimmer: dort war das Ergebnis falsches
Verhalten, hier wären es überschriebene Dateien.

### Abweichungen vom POSIX-Verhalten — hier, nicht nur im Kommentar

Wer eine dieser Funktionen benutzt, liest diese Tabelle, nicht den Kernel-Quelltext:

| Name | Weicht ab |
|---|---|
| `sys_dup2` | Der Dateizeiger wird **nicht geteilt** (Slot-Kopie). Zwei fds auf dieselbe Datei laufen unabhängig. |
| `sys_ftruncate` | **Nur Länge 0.** Jede andere Länge meldet −1, statt still etwas anderes zu tun. |
| `sys_statfs` | Freie Blöcke sind **−1 = unbekannt**, nicht 0. Wer 0 als „voll" liest, irrt. |
| `sys_getpriority`/`sys_setpriority` | **LyxOS-Skala 0…255** (0 = HARD_RT, 128 = NORMAL, 255 = IDLE), bewusst nicht auf nice −20…19 abgebildet. |
| `sys_kill` | **Kein Signalmodell.** `sig=0` prüft Existenz, sonst wird der Thread als DEAD markiert. Sich selbst zu töten wird abgelehnt. |
| `sys_pipe2` | **Blockiert nie** — leer liefert 0, voll nimmt 0 an. Ein 4096-Byte-Ring. |
| `sys_sendto`/`sys_recvfrom` | **Ein Socket zur Zeit.** Der Aufruf pollt die Karte selbst und verwirft Fremdpakete; währenddessen gehen Pakete für andere Ports verloren. Adressformat `{ip, port}`, kein `sockaddr_in`. Bei `recvfrom` steht bei +16 das Zeitlimit in ms als **Eingabe**. |
| `sys_access` | `mode` wird ignoriert — FAT32 kennt keine Rechte. |
| `sys_fcntl` | `O_NONBLOCK` wird gespeichert, aber noch nicht ausgewertet. |
| `sys_fsync`/`sys_fdatasync` | Erfolg ist hier die Wahrheit, keine Notlüge: FAT32 schreibt write-through. |

Dass das LyxOS-Team diese Punkte benennt statt sie zu verschweigen, ist der
Grund, warum sie hier stehen können. Eine Abweichung, die nur im Kernel steht,
ist beim Aufrufer ein Fehler ohne Absender.

## Die Entwurfs-ABI ist keine ABI (#1734)

`emitVfsSyscall` prüft seit 1.1.4N jede Nummer gegen den **tatsächlich
implementierten** Raum: flach **0…228** und **300…326**, dazu der Wissensgraph
**2063…2066** und die Zeitleiste **2315**. Eine Nummer ausserhalb wird nicht
emittiert — der Bau bricht mit Builtin-ID, Nummer und Fundstelle ab.

Betroffen sind **106** Zuordnungen, die aus der hex-gruppierten Entwurfs-ABI
stammen und im Kernel nie gebaut wurden:

| Gruppe | Builtin-IDs | emittierte Entwurfsnummer |
|---|---|---|
| IPC/Sync | 72–84 | 0x0400 … 0x040C |
| Zeit | 85–89 | 0x0500 … 0x0504 |
| Capabilities | 90–98 | 0x0700 … 0x0708 |
| Tasks | 99–108 | 0x0B00 … 0x0B09 |
| KI | 109–115 | 0x0800 … 0x0806 |
| Embedding | 116–121 | 0x0807 … 0x080C |
| Sem/Graph | 122–127 | 0x080D … 0x0812 |
| Lyra | 128–139 | 0x0900 … 0x090B |
| IOFS | 140–144 | 0x0C00 … 0x0C04 |
| Debug | 145–150 | 0x0A00 … 0x0A05 |
| einzeln | 24, 25, 30–34, 36, 39–47, 48–57 | 0x0204, 0x0205, 0x020A–0x0215, 0x0300–0x0305, 0x0600–0x0609 |

Zwei Zufallstreffer bleiben gültig: **0x080F…0x0812** und **0x090B** sind
dezimal 2063…2066 und 2315 und damit echte Handler. Die Gruppe Sem/Graph trifft
also teils ins Leere und teils genau richtig — kein Verdienst des Entwurfs,
sondern der Grund, warum die Prüfung Zahlen vergleicht und keine Gruppen.

**Warum abbrechen und nicht `-ENOSYS`.** Heute trifft eine Entwurfsnummer
nichts, weil 229…399 im Kernel frei ist; ein Laufzeitfehler wäre also formal
ausreichend. Nur ist „heute frei" keine Eigenschaft, auf die man baut: wächst
die flache Tabelle, wandert eine Phantasienummer nach der anderen in belegtes
Gebiet, und der Tag kündigt sich nicht an. Das LyxOS-Team beziffert, was dann
passiert — Linux 158 träfe dort `sys_iofs_write_lpid`, das eine 4-KB-Seite ins
Dateisystem **schreibt**.

**Der Abbruch kostet nichts, was vorher funktioniert hätte.** Alle acht
stdlib-Units bauen weiter und `make test-lyxos` bleibt grün, weil der
Erreichbarkeitsfilter (#1727) ungenutzte Rümpfe gar nicht erst lowert. Getroffen
wird nur, wer eine dieser Funktionen **wirklich aufruft** — und dessen Programm
hätte vorher einen Syscall ins Nichts abgesetzt.

**Wo es eine echte Nummer gibt, gehört sie angebunden** statt der Entwurfszahl.
Aus `work/lyxos/antwort-lyxos.md`: Ereignisschleife mit Frist **218**, Ereignisse
**121/122/132**, TCP **180–184**, rohe Frames **146/147**, Netz/DNS/Ping
**141–145, 211–214**, IOFS mit Graph **155–188**, Statistik **202/203/205**,
Neustart **210**, RAM-Disks **153/154**, Audio **219–228**, Fenster **148–152**,
TSC **228**. Das ist Folgearbeit, kein Teil dieser Prüfung.

**Zwei ungeklärte Punkte, bewusst nicht überschrieben:** `sys_seek` emittierte
0x0204, die Antwort nennt `sys_lseek` = 8; unser eigener Stand führte 0x0204
als QEMU-verifiziert. Dasselbe bei `sys_stat` 0x0205 gegen `sys_fstat` 135.
Beide melden jetzt, statt eine der beiden Lesarten zur Tatsache zu erklären.

