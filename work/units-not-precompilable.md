# Unit-Übersetzbarkeit (Stand 2026-07-31, lyxc 1.0.11A)

**390 von 390 Unit-Quellen übersetzen.** Diese Datei hielt die Ausnahmen fest;
es gibt derzeit keine mehr.

## Verlauf

| Stand | übersetzbar | offen |
|---|---:|---:|
| Sitzungsbeginn | 302 | 88 |
| Keyword-Kollisionen (#971) | 315 | 75 |
| nicht existierende Syntax, Imports, Builtin-Namen (#972) | 352 | 38 |
| verschachtelte Funktionen fertiggebaut (#974) | 361 | 29 |
| `do` → `digitalocean` (#975) | 374 | 16 |
| falsche Namen, Sichtbarkeit, Reste (#976) | 388 | 2 |
| `ec2` Cursor-Umbau, `ssh` Capability | **390** | **0** |

## Wo die Fehler herkamen

Nichts davon war ein Compiler-Fehler im engeren Sinn — mit einer Ausnahme
(verschachtelte Funktionen, #973/#974). Der Rest waren Unit-Quellen, die nie
übersetzt wurden und deshalb Syntax und Namen benutzten, die es nicht gibt:

- reservierte Wörter als Bezeichner (`match`, `do`, `to`, `pool`, `unit`, `i8`)
- Konstrukte, die Lyx nicht hat: Struct-Literale, `if` als Ausdruck,
  `import … as`, `pub use`
- falsch geschriebene Funktionen (`int64ToStr`, `Open`, `MmapAnon`,
  `sys_munmap`, `read_raw`) und fehlende Imports
- ein fehlendes Semikolon nach `extern fn`, das die folgenden `pub con`
  verschluckte

## Was den Zustand so lange verdeckt hat

`test_compile_units.sh` lief über `"$STD_DIR"/*.lyx` — nur die oberste Ebene.
Er meldete 92 OK / 0 failed, während ein Viertel der stdlib nie geprüft wurde.
Seit #977 läuft er rekursiv über `std/` und `data/` und kennt zwei Wächter: ein
neuer Fehlschlag färbt rot, und eine Unit aus `KNOWN_FAILURES`, die wieder
übersetzt, ebenfalls — damit die Liste nicht still verrottet. `KNOWN_FAILURES`
ist derzeit leer.

## Zwei Details, die man wiederfinden will

- **`@cap(pfad)` statt `@capabilities([...])` bei `extern fn`.** Der Parser hängt
  `@capabilities` als Geschwisterknoten vor die Deklaration; sema liest die
  Annotation aber aus `c2`. Nur `@cap(...)` schreibt dorthin. Bei einem
  OS-Klassen-Extern ist `@capabilities([...])` also wirkungslos — siehe
  `std/net/ssh.lyx` und `std/net/dns.lyx`.
- **Verschachtelte Funktionen sehen die Locals der umgebenden Funktion nicht.**
  Wer einen Cursor braucht, gibt ihn durch: `xxAppend(buf, off, s): int64` mit
  neuem Offset als Rückgabewert, wie in `lambda`, `cloudwatch` und jetzt `ec2`.
