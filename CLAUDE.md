# Arbeitsregeln für aurum (lyxc)

Destillat aus den Postmortems. Jede Regel hat schon einmal Zeit oder
Korrektheit gekostet. Ausführliche Belege im Bug-Store — hier nur der Auslöser.

## Bevor du debuggst

- `bug_recall` zuerst (`projekt=aurum`, dann projektübergreifend); nach jedem
  verstandenen Fix `bug_record` mit der Ursache, nicht dem Symptom.
- **Herkunft des Artefakts vor dem Code prüfen.** „Regression" mit Disassembly
  wie der alte Bug = alte Binary, bis das Gegenteil belegt ist.
- **`make bootstrap`, nie `make clean`.** Default-Ziel von `make` ist
  `lic_build_flags`, baut also keinen Compiler; der Seed-Build scheitert
  ASLR-bedingt sporadisch (`singularity` macht deshalb fünf Anläufe).
- **Patch bricht den Selbstbau:** erst `git stash` + beiseitegelegte
  Compiler-Kopie (Flakiness vs. Regress trennen), dann halbieren
  (Aufrufstelle aus → Rumpf tot → Rumpf in Hälften).

## Die zwei häufigsten Ursachen

**Stiller Default** — ein Catch-all, der etwas Plausibles tut statt zu melden,
macht aus jeder Lücke stille Fehlfunktion. Belegt: 16 verworfene Opcodes samt
Sicherheits-Asserts (`emit_lyxos`), `|~` → 0, `for i in range` → kein Code,
unbekanntes Feld → Offset 0, `zstd` → Müll ohne Fehlerflag.
→ Default-Zweige scheitern laut. Wer einen entschärft, belegt vorher, dass
nichts Legitimes durchfällt, und kommentiert den gewollten Durchfall.

**Die richtige Ebene fehlt im Entwurf** — trifft ein Konstrukt *konsequent* das
Falsche, lautet die Frage nicht „wo wird falsch gerechnet", sondern „wo müsste
das Richtige entstehen — gibt es die Stelle?". Belegt: `defer` (#1006,
Vorabpass ohne Blockbegriff), `&&`/`||` (#1023, nie eine bedingte Auswertung
erzeugt), `ir_lower` (kannte nur das eigene Modul).

## Tests

- **Den Weg prüfen, nicht das Ergebnis**, wenn der Defekt in der Ausführung
  liegt: Auswertungen zählen, Reihenfolgen vergleichen, Zweige über einen
  Seiteneffekt identifizieren. Prüffrage: *wäre der Test vor dem Fix rot?*
  Dreimal in Folge wäre ein Ergebnistest grün gewesen (`case _`, `&&`, `defer`).
- **Ein Test, der nicht läuft, ist schlimmer als keiner.** Neue Suiten ins
  `test`-Target bzw. in `tests/suite-*.txt`; `test_coverage_test.sh` wacht —
  seit #1112 rekursiv, denn davor sah er nur `tests/*.sh` und übersah damit
  621 Dateien in Unterverzeichnissen. Ein *Runner*, der an keinem Ziel hängt,
  ist derselbe Verfall; die Prüfung erkennt ein Verzeichnis nur dann als
  abgedeckt, wenn sein Runner im Makefile aufgerufen wird.
- **Roter Test bleibt im Lauf.** Wer ihn aus dem Ziel nimmt, macht ihn
  unsichtbar. `tests/known-red.txt` führt ihn mit Issue weiter mit; wird er
  wieder grün, wird das Ziel rot, damit der Eintrag verschwindet.
- **Erwartete Ausgaben ohne Versionsbanner.** Snapshot-Erwartungen, die die
  Copyright-Zeile enthielten, verrotteten bei jedem Bump (`0.9.1A`).
- **Kein Test darf an einem fremden offenen Defekt hängen** — sonst ist unklar,
  was er misst. Rest als eigenes Issue.
- **Repro wörtlich übernehmen**, nicht in die eigene Schreibweise übersetzen.
- Erfolgskonvention im Bestand uneinheitlich (0, 42, „ALL PASS" + Exit 1) —
  `run_lyx_suite.sh` urteilt nach der Ausgabe, rc ≥ 128 immer rot. Jeder
  `KNOWN_RED`-Eintrag braucht ein Issue.

## Nachweis vor dem PR

- **Fixpunkt gen2 == gen3** (SHA-256), `make test` 0 FAIL, `make test-lyx`
  0 unerwartet rot; bei Codegen-Änderungen zusätzlich der Beispiel-Sweep.
- **Codegen-Änderung heißt Seed neu verankern.** `make singularity` (S3 == S4)
  wird sonst rot: S3 trägt die Bytes des alten Seeds. Fixpunkt nach
  `src/lyxc_bootstrap` kopieren, `make singularity` muss SINGULAR melden.
  Der Seed stand bis 1.0.12A auf 1.0.7B und belegte nichts mehr (#1167).
- **Verbleibende Fehlschläge gegen den Vorgängerstand belegen**, statt sie als
  vorbestehend abzutun.
- Bei **Semantikänderungen** zusätzlich der Gegenbeleg, dass sich der Bestand
  nicht auf das alte Verhalten stützte.

## Sprach- und Repo-Fallen

- **Nie `&`/`|` in Vergleichsketten** — `a >= 265 & a <= 284` parst C-artig als
  `a >= (265 & a) <= 284`.
- **String-Literale sind keine Schreibpuffer** (Speicherkorruption); `alloc()`.
- **Zwei Allokatoren:** `std/alloc.lyx` (mmap je Allokation, `free` muss
  munmappen) vs. `src/std/alloc.lyx` (Arena, `free` korrekt No-op, vom Compiler
  benutzt). „Den" Allokator gibt es nicht.
- **stdlib liegt doppelt** (`std/**` + `lyx-compiler/usr/include/...`), Resolver
  bevorzugt `.lyx` vor `.lyu` → Divergenz ist ein Korrektheitsproblem;
  `make sync-units-src`.
- **sema-Prüfungen über Typdeklarationen fail-open.** `SymNodeIdx == -1` bei
  importiertem Typ heißt „unentscheidbar", nicht „existiert nicht" — sonst gilt
  jedes geerbte Feld als unbekannt.
- **Vor dem Verschärfen einer sema-Regel prüfen, ob die eigene stdlib das
  Muster nutzt** (statische Factories wie `StringBuilder.Create`). Ein
  Bug-Report beschreibt die Absicht des Melders, nicht die Sprache.
- **Ein Workaround, der einen Fehler anderswo kompensiert, wird nach dem echten
  Fix selbst zum Bug** (`totalSlots`-Parität nach dem `_start`-Alignment).

## Git und Issues

- Branches von **`develop`**, PRs gegen `develop`, nie direkt auf `main`.
- **Issues immer von Hand schließen.** `Closes #N` greift nur beim Merge in den
  Default-Branch (`main`) — gearbeitet wird gegen `develop`, also nie. Nach dem
  Merge Status prüfen und mit Ursache, Fix und Nachweis schließen.
- **Issue mit falscher Prämisse: schließen und neu aufsetzen**, nicht
  korrigiert offenlassen — wer später sucht, liest den Titel.
- Versionsbump umfasst `ebnf.md` bei Grammatikänderungen, aber **historische
  Angaben bleiben stehen** (Rückblicke, Standvermerke unter `work/`).
- `gh` kann keine Dateien unter `/tmp` oder dem Scratchpad lesen → Text inline
  statt `--body-file`.

## Umfang

Vollständig implementieren — **keine Stubs**. Was den Rahmen sprengt, wird
nicht halb angefangen, sondern als Issue mit Repro und Lösungsweg geführt und
im PR als nicht enthalten benannt.
