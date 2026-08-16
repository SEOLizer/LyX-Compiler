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
| 1 | `write(1, ptr, len)` | `PrintStr`, `PrintLn` | Länge −1 = „strlen zur Laufzeit"; **nur das lyxos-Backend wertet den Sentinel aus** |
| 2 | Ganzzahl nach stdout | `PrintInt` | ohne Zeilenumbruch |
| 3 | Prozessende | `Exit` | |
| 6 | Teilzeichenkette | `StrSub` | |
| 7 | Verkettung | `StrConcat` | |
| 8 | Kopie | `StrCopy` | |
| 9 | Gleitkomma nach stdout | `PrintFloat` | Linux-ARM64 bislang No-op |
| 10 | Datenbarriere (DMB SY) | `mem_barrier` | |
| 11 | Befehlsbarriere (ISB SY) | `inst_barrier` | |
| 12 | Formatierte Ausgabe | `Printf` | war bis 1.0.11C fälschlich 10 |
| 13 | `write(2, ptr, strlen(ptr))` | `EPrintStr`, `EPrintStrLn`, `EPrint` | #1388; Länge rechnet das Backend selbst |
| 14 | Zeilenumbruch nach stderr | `EPrintStrLn`, `EPrintLn` | #1388 |
| 15 | Länge einer Zeichenkette | `StrLen`, `StrLength` | #1388 |

Frei: 4, 5, 16–19.

## Backend-Abdeckung der allgemeinen IDs

| Backend | behandelt | fehlt |
|---|---|---|
| x86-64 (ELF) | eigener Pfad ohne IR-Builtins | — |
| ARM64 Linux | 1, 2, 3, 6–11, **13, 14, 15**, **200–205, 208, 209** | 12 (`Printf`) — meldet Fehler |
| ARM64 Windows | 1, 2, 3, 6, 7, 8, 9, 12, **200–205, 208, 209** | 10/11 als ausdrückliches No-op |
| RISC-V Linux | 1, 2, 3, **13, 15, 200–205, 208, 209** | Rest meldet Fehler (#1388) |
| ARM Cortex-M | **200–205, 208, 209**; 1, 2, 3, 9, 12, 13, 14 als ausdrücklicher No-op bzw. BKPT | alles Übrige meldet Fehler |
| Xtensa | 1, 2 | Rest meldet Fehler (#1388, Kodierungen fehlen — vgl. #1281) |
| lyxos (LBF) | 1, 2 + 20 … 256 | 3, 6–15 |

**Speicherzugriffe (200–205, 208, 209)** sind seit #1388 auf ARM64, RISC-V und
Cortex-M umgesetzt. Sie brauchen kein Betriebssystem und gelten deshalb auch
im Windows- und im freistehenden Zweig.

Eine nicht behandelte ID **muss laut scheitern**. Ein stiller Default-Zweig
verwandelt jede Lücke in stille Fehlfunktion — dieselbe Klasse wie der
LyxOS-Builtin-Misdispatch (PR #839) und der verworfene Opcode-Catch-all
(PR #867).

## Bereich 20 … 256 — lyxos-Syscalls

Vergeben in `src/ir_lower.lyx` (Abschnitt „VFS syscalls"), ausgewertet in
`src/backend/lyxos/emit_lyxos.lyx`. Eine LyxOS-Syscall-ID ist an **drei**
Stellen konsistent zu halten: `sema._regBuiltin`, das Lowering in `ir_lower`
und `emit_lyxos.emitBuiltinCall`.
