# Arbeitsregeln für aurum (lyxc)

Destillat aus den Postmortems dieses Projekts. Jede Regel steht hier, weil ihr
Fehlen bereits Zeit oder Korrektheit gekostet hat.

## 1. Bevor du debuggst

**Erst das Postmortem-Gedächtnis fragen** (`bug_recall`, zuerst `projekt=aurum`,
dann projektübergreifend). Nach jedem verstandenen Fix `bug_record` — die
Ursache, nicht das Symptom wiederholen.

**Prüfe die Herkunft des getesteten Artefakts, bevor du den Code verdächtigst.**
Eine „Regression", deren Disassembly identisch zum alten Bug aussieht, ist bis
zum Beweis des Gegenteils eine alte Binary: falscher Branch-Punkt, nicht neu
gebaut, Fix nicht enthalten. Erst Branch-Basis und Buildzeit klären, dann Code
lesen.

**`make bootstrap` statt `make clean`.** Das Default-Ziel von `make` ist nicht
`build`, sondern `lic_build_flags` — `make` allein baut keinen Compiler. Der
Seed-Build aus dem Pascal-Seed scheitert ASLR-bedingt sporadisch und braucht
mehrere Anläufe (das `singularity`-Ziel macht deshalb fünf). Solange ein
funktionierendes `lyxc` da ist, nie darauf zurückfallen.

**Bricht dein Patch den Selbstbau:** zuerst `git stash` und mit einer vorher
beiseitegelegten Compiler-Kopie bauen, um sporadische Bootstrap-Flakiness von
echtem Regress zu trennen. Erst danach den Patch halbieren (Aufrufstelle aus →
Rumpf tot → Rumpf in Hälften).

## 2. Die zwei häufigsten Fehlerursachen in diesem Compiler

**Stiller Default.** Ein Catch-all, der etwas Plausibles tut statt zu melden,
verwandelt jede Implementierungslücke in stille Fehlfunktion. Gefunden in
`emit_lyxos.lyx` („unbehandelte Ops: kein Code" — 16 erreichbare Opcodes,
darunter alle Sicherheits-Asserts), im Binop-Dispatch (`|~` lieferte 0), in
`cg_genStmt` (`for i in range` erzeugte gar keinen Code), im Feldzugriff der
sema (unbekanntes Feld → Offset 0), in `zstd.lyx` (Müll ohne Fehlerflag).

> Ein Default-Zweig muss laut scheitern. Wer einen entschärft, weist vorher
> nach, dass nichts Legitimes hindurchfällt — und behält den bewusst
> durchfallenden Fall kommentiert.

**Die richtige Ebene kommt im Entwurf nicht vor.** Trifft ein Konstrukt
*konsequent* das Falsche, ist die Frage nicht „wo wird falsch gerechnet",
sondern „gibt es die richtige Ebene überhaupt":

- `defer` lief immer am Funktionsende — ein Vorabpass sammelte funktionsweit,
  der Blockbegriff fehlte im Modell (#1006).
- `&&`/`||` werteten immer beide Seiten aus — es wurde nie eine bedingte
  Auswertung *erzeugt*, die Reihenfolge war gar nicht das Thema (#1023).
- `ir_lower` kannte nur das aktuelle Modul — jede cross-module-Frage (Layout,
  Dispatch, Größe) brauchte erst ein modulglobales Registry.

## 3. Tests

**Prüfe den Weg, nicht das Ergebnis**, wenn der Defekt in der Ausführung liegt.
Dreimal in Folge hätte ein Ergebnistest nichts gefunden: `case _` traf etwas
(nur das Falsche), `&&` lieferte den richtigen Wert (nur nach Auswertung beider
Seiten), `defer` gab dieselben Zeilen aus (nur in falscher Folge). Also
Auswertungen **zählen**, Reihenfolgen **vergleichen**, Verzweigungen über einen
beobachtbaren Seiteneffekt identifizieren.

**Ein Test, der nicht läuft, ist schlimmer als keiner** — er täuscht
Absicherung vor. Jede neue Suite gehört ins `test`-Target bzw. in eine
`tests/suite-*.txt`; `tests/test_coverage_test.sh` wacht darüber.

**Ein Test darf nicht an einem fremden, offenen Defekt hängen.** Sonst ist
unklar, was er misst. Lieber den Fall so formulieren, dass er nur die eine
Eigenschaft prüft, und den Rest als eigenes Issue führen.

**Repro-Code aus einem Issue wörtlich übernehmen**, nicht in die eigene
Schreibweise übersetzen. Ein Fix, der nur die geklammerte `int64`-Variante
erfasst, während das Issue `pchar` ohne Klammern zeigt, sieht sonst grün aus.

**Die Erfolgskonvention im Bestand ist uneinheitlich** (0, 42, und die
`edi*`-Familie druckt „ALL PASS" und endet mit 1). `tests/run_lyx_suite.sh`
urteilt deshalb nach der Ausgabe; ein Absturz (rc ≥ 128) ist immer rot. Jeder
`KNOWN_RED`-Eintrag braucht ein Issue.

## 4. Nachweis vor dem PR

Pflicht bei jeder Compiler-Änderung:

- **Fixpunkt**: gen2 == gen3 (SHA-256), sonst ist die Änderung nicht
  selbsttragend
- `make test` — 0 FAIL
- `make test-lyx` — 0 unerwartet rot
- bei Codegen-Änderungen zusätzlich der Beispiel-Sweep

**Fehlschläge gegen den Vorgängerstand vergleichen**, bevor du sie als
vorbestehend abtust — mit dem alten Compiler nachbauen und das im PR belegen.

Bei einer **Semantikänderung** gehört der Gegenbeleg dazu, dass sich der
Bestand nicht auf das alte Verhalten gestützt hat.

## 5. Sprache und Repo: Fallen, die wiederholt zugeschlagen haben

- **Nie `&` oder `|` in Vergleichsketten.** `a >= 265 & a <= 284` parst
  C-artig als `a >= (265 & a) <= 284` und wird stillschweigend etwas anderes.
- **String-Literale sind keine Schreibpuffer** — das ist Speicherkorruption mit
  Ansage. `alloc()` verwenden.
- **Zwei Allokatoren:** `std/alloc.lyx` (ein mmap je Allokation, `free` muss
  munmappen) vs. `src/std/alloc.lyx` (Arena/Bump, `free` korrekt ein No-op, vom
  Compiler selbst benutzt). Eine Änderung an „dem" Allokator gibt es nicht.
- **Die stdlib liegt doppelt** (`std/**` und `lyx-compiler/usr/include/...`),
  der Resolver bevorzugt `.lyx` vor `.lyu`. Divergenz ist ein
  Korrektheitsproblem, kein Verpackungsdetail — `make sync-units-src`.
- **sema-Prüfungen über Typdeklarationen müssen fail-open sein.** Bei einem
  importierten Typ liefert `SymNodeIdx` −1: Symbol bekannt, AST-Knoten nicht
  einsehbar. Das ist „unentscheidbar", nicht „existiert nicht" — sonst meldet
  die Prüfung jedes geerbte Feld als unbekannt.
- **Vor dem Verschärfen einer sema-Regel prüfen, ob die eigene stdlib das
  angeblich verbotene Muster benutzt.** Ein Bug-Report beschreibt die Absicht
  des Melders, nicht zwingend die Sprache (statische Factory-Methoden wie
  `StringBuilder.Create` sind etabliert).
- **Ein Workaround, der einen Fehler an anderer Stelle kompensiert, wird nach
  dem echten Fix selbst zum Bug** (die `totalSlots`-Parität nach dem
  `_start`-Alignment).

## 6. Git und Issues

- Feature- und Fix-Branches von **`develop`** ableiten, PRs gegen `develop`.
  Nie direkt auf `main` pushen.
- **Issues gehen hier nie automatisch zu — immer von Hand schließen.** GitHub
  löst `Closes #N` nur aus, wenn der PR in den **Default-Branch** gemergt wird;
  der ist `main`, gearbeitet wird aber gegen `develop`. Das englische
  Schlüsselwort ist trotzdem richtig (deutsches „schliesst #995" wirkt ohnehin
  nie), es greift hier nur nicht. Nach jedem Merge den Issue-Status prüfen und
  mit einem Kommentar schließen, der Ursache, Fix und Nachweis nennt.
- **Ein Issue mit falscher Prämisse gehört geschlossen und neu aufgesetzt**,
  nicht korrigiert-und-offengelassen: wer später sucht, liest den Titel.
- Beim Versionsbump gehört `ebnf.md` dazu, wenn die Grammatik geändert wurde.
  **Historische Angaben nicht mitziehen** — Rückblicke („bis 1.0.11A war das
  nicht so") und die Standvermerke unter `work/` benennen die Version, unter
  der etwas galt bzw. gemessen wurde.
- `gh` kann Dateien unter `/tmp` und dem Scratchpad nicht lesen; `--body-file`
  scheitert dort, Text inline übergeben.

## 7. Umfang

Neue Funktionen vollständig implementieren — **keine Stubs, keine Dummies**.
Was den Rahmen sprengt, wird nicht halb angefangen, sondern als eigenes Issue
mit Repro und skizziertem Lösungsweg geführt, und im PR ausdrücklich als nicht
enthalten benannt.
