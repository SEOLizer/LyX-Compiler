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
- **Ältere Meldung erst nachmessen, Prämisse eingeschlossen.** Von fünf Issues
  einer Runde war genau eines ein offener Defekt in der beschriebenen Form:
  #1815 war kernelseitig behoben, #1748 nicht mehr reproduzierbar, #1823 nannte
  einen Namen, den es gibt (`process.exec`), #1820 zwölf „fehlende" Funktionen,
  von denen acht nur anders heißen. Stimmt die Prämisse nicht, im Issue
  richtigstellen — wer später sucht, liest den Titel.
- **Fremdmeldung an der ORIGINALQUELLE prüfen**, mit zurückgedrehter Umgehung.
  Eine nachgebaute Minimalfassung mit denselben Zutaten übersetzte fehlerfrei;
  erst `vegagrid/metrics.lyx` selbst, von rohen Blöcken zurück auf `TIntArray`,
  war aussagekräftig (#1748). Fremdes Projekt nur lesen, Kopie ins Scratchpad.
- **Neuer Code beim ERSTEN Lauf unter `ulimit -v`.** Ohne Deckel trifft ein
  Fehler nicht nur den eigenen Prozess: der OOM-Killer sucht sich den größten
  Verbraucher im System. Der Disassembler aus #1370 lief in eine endlose
  Rekursion und hat dabei eine fremde Konsole mitgerissen.

## Die häufigsten Ursachen

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
erzeugt), `ir_lower` (kannte nur das eigene Modul), `_exprTypeNode` (#1787 —
der Typ war nur für einen Bezeichner bestimmbar, `h.b.W()` gab still 0).

**Die zweite Stelle wurde nicht nachgezogen** — geht ein Konstrukt auf einem
Pfad und auf einem anderen nicht, ist die richtige Umsetzung meist schon da,
wenige Zeilen entfernt. Belegt: `cg_foldConst` rechnet `~` korrekt,
`cg_evalConExpr` kannte es nicht (#1799); die f64-Sperre aus #1499 steht in
`cg_foldConst`, im unären Zweig daneben fehlte sie (#1803, aus `-1.5` wurde
`-3.0`); die Parameter-Suche steht für den Lesezugriff da, `_findLocalSlot`
hatte sie nicht (#1806).
→ Erst nach der **funktionierenden** Umsetzung im selben Modul greppen, statt
die kaputte Stelle von vorn zu durchdenken. Wer eine zweite Stelle anlegt,
verweist im Kommentar auf die erste („dieselbe Rechnung wie X — die beiden
müssen übereinstimmen"), wie es `cg_parseFloat`/`_parseFloatBits` vormachen.

**Eine Aufzählung ist unvollständig** — die Schwester der vorigen Ursache: nicht
eine zweite Stelle fehlt, sondern *ein Fall* in einer Liste. Die Auflösung zählt
auf, woher ein Name kommen kann, und vergisst eine Herkunft. Dreimal belegt,
jedes Mal mit derselben Speicherart-Frage: `_localTypeNode` kannte Feld und
Aufrufergebnis nicht (#1787), `_findLocalSlot` keine Parameter (#1806),
`_localTypeNode` keine Modulvariablen (#1812).
→ Im Bericht klingt es immer gleich: **„X geht, Y nicht — bei identischem
Objekt."** Dann nicht nach einem Rechenfehler suchen, sondern fragen, welche
*Herkunft* Y hat, die X nicht hat. `_localTypeNode` und `_findLocalSlot` sind
zwei getrennte Aufzählungen derselben Sache; eine neue Speicherart muss in
**beide**.

**Eine Präfixprüfung vergibt Rechte zu weit** — sie trifft auch jeden Namen,
den es noch gar nicht gibt, und die Wirkung fällt erst am Gerät auf. Dreimal
belegt: `audio` (5 Zeichen) hätte jedem künftigen `audio.*` still das
Mikrofonbit gegeben (#1826); `process` (7 Zeichen) traf alle fünf Namen, sodass
`@capabilities([process.exit])` `LBF_CAP_PROC_SPAWN` und damit `PLEDGE_EXEC`
setzte — „darf sich beenden" wurde zu „darf Programme starten" (#1823). Dazu
zwei tote Zweige `net.`/`proc.` ohne jeden deklarierbaren Namen.
→ In Rechtezuordnungen exakte Namen. Zum Prüfen jeden deklarierbaren Namen
EINZELN übersetzen und das Bit am Erzeugnis lesen, statt der Tabelle zu glauben.

## Tests

- **Den Weg prüfen, nicht das Ergebnis**, wenn der Defekt in der Ausführung
  liegt: Auswertungen zählen, Reihenfolgen vergleichen, Zweige über einen
  Seiteneffekt identifizieren. Prüffrage: *wäre der Test vor dem Fix rot?*
  Dreimal in Folge wäre ein Ergebnistest grün gewesen (`case _`, `&&`, `defer`).
- **Ein Test, der nur eine INVARIANTE prüft, ist blind für das falsche Ergebnis
  darin.** „Wert liegt in [-1,1]", „Opcode steht in der Liste", „Datei
  entsteht", „Rückgabewert plausibel" — jede dieser vier Prüfungen hat einen
  echten Defekt jahrelang verdeckt: `SinF64(1e16)` lieferte `sin(2)` und lag
  brav im Wertebereich (#1829); `WriteString` schrieb einen Beispieltext und
  meldete dessen Länge (#1827). Den WERT messen, die WIRKUNG, nicht das
  Vorhandensein.
- **Beide Seiten messen.** Ein Test, der belegt, dass die richtigen Namen ein
  Recht setzen, wäre auch von einer viel zu weiten Zuordnung erfüllt; er muss
  zusätzlich zeigen, dass die anderen es NICHT setzen (#1823).
- **„Opcode behandelt" ist keine Aussage über „richtig behandelt".** Eine Liste,
  die Vorhandensein prüft, meldet den *fehlenden* Opcode laut und übersieht den
  falschen Rumpf: `xt_opBehandelt` führte `IRO_DIV`, der Rumpf war `MOVI T0, 0`
  — jede Division lieferte still 0 (#1789). Nur Ausführung deckt das auf. Wo
  ein Ziel nicht läuft (lyxos braucht den Kernel), auf einem gegenmessen, das
  denselben IR-Weg geht: riscv und arm64 unter qemu. Dreimal war ein gemeldeter
  „lyxos-Bug" in Wahrheit der gemeinsame IR-Weg (#1786, #1787, #1798).
- **Ein Test darf nicht voraussetzen, dass eine Lücke offen bleibt.** Wer eine
  Ablehnungsmeldung als Nachweis nimmt, macht den Test rot, sobald die Lücke
  zugeht — in einer Sitzung viermal passiert. Vor dem Schließen einer Lücke in
  `tests/` nach ihrer Issue-Nummer und nach „meldet", „weist ab", „laut"
  suchen. Tragfähiger ist der Nachweis am **Erzeugnis** (`e_machine == 94`)
  oder an der **Wirkung** (Zusicherung löst aus, rc 132).
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
- **Den Lauf abkoppeln, nicht als Hintergrundaufgabe starten:**
  `setsid nohup bash -c 'ulimit -c 0; make test; echo "RC=$?"' > lauf.log 2>&1 &`,
  am Werkzeug bleibt nur ein Beobachter. Zweimal wurde ein `make test` ohne
  jede Ausgabe getötet — je rund 40 Minuten verloren. Filter eng fassen
  (`[1-9][0-9]* FAIL`), sonst meldet jede „0 FAIL"-Zeile.
- **Während eines Laufs NICHT bauen.** `make bootstrap` tauscht `./lyxc` mitten
  in der Messung aus; genau so ist einmal ein ganzer Nachweis wertlos geworden.
- **Codegen-Änderung heißt Seed neu verankern.** `make singularity` (S3 == S4)
  wird sonst rot: S3 trägt die Bytes des alten Seeds. Fixpunkt nach
  `src/lyxc_bootstrap` kopieren, `make singularity` muss SINGULAR melden.
  Der Seed stand bis 1.0.12A auf 1.0.7B und belegte nichts mehr (#1167).

## Versionsschema

`MAJOR.MINOR.TAG` + Suffix. **TAG** zählt die Build-*Tage*, nicht die
Kalendertage: der erste Build an einem neuen Tag erhöht ihn und setzt den
Suffix auf `A`. Der **Suffix** zählt die Kompilate innerhalb des Tages —
`A`…`Z`, dann `BA`…`BZ`, dann `CA`…; `AA` gibt es nicht.

- `tools/next_version.sh` rechnet und setzt (aus `VERSION`/`VERSION_DATE`).
- **Reihenfolge: erst bumpen, dann verankern.** Die Version steckt im Binary,
  ein Bump erzeugt also einen neuen Fixpunkt — umgekehrt ist `singularity`
  sofort wieder rot.
- Vier lebende Stellen (Makefile, README-Badge, vier Strings in `lyxc.lyx`,
  ebnf.md-Kopf); `tests/version_consistency_test.sh` hält sie zusammen.
  **Historische Angaben bleiben stehen** — „bis 1.0.11D war das so" nennt
  einen Zeitpunkt.
- **Verbleibende Fehlschläge gegen den Vorgängerstand belegen**, statt sie als
  vorbestehend abzutun.
- Bei **Semantikänderungen** zusätzlich der Gegenbeleg, dass sich der Bestand
  nicht auf das alte Verhalten stützte.

## Sprach- und Repo-Fallen

- **Nie `&`/`|` in Vergleichsketten** — `a >= 265 & a <= 284` parst C-artig als
  `a >= (265 & a) <= 284`.
- **`0 - n` ist keine Betragsfunktion.** Für den kleinstmöglichen int64 liefert
  sie denselben Wert; `if (n < 0) { … 0 - n … }` rekursiert dort endlos. Genau
  dieses Bitmuster emittiert der Codegen als f64-Vorzeichenmaske, es steht also
  in fast jedem Erzeugnis — der Disassembler aus #1370 ist daran in eine
  unbegrenzte Speicherbelegung gelaufen. 64-Bit-Werte ohnehin hexadezimal
  ausgeben: es sind fast immer Adressen oder Bitmuster.
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

## Messsonden und ihre Grenzen

- **Der lokale LBF-Lader** (`src.tools.lbf.loader`) führt lyxos-Abbilder unter
  LINUX aus. LyxOS liefert Syscall-Ergebnisse in `rdx`, Linux in `rax` — alles,
  was Speicher anfordert (allokierende Builtins, lokale Strukturen), bekommt
  darüber eine Mülladresse und faultet, obwohl es auf dem Gerät läuft. Nur
  Ganzzahlfälle so messen; sonst am Erzeugnis prüfen (Bytemuster, siehe
  `tests/lyxos_builtin_ids_test.sh`) oder arm64/riscv nehmen — gemeinsamer
  IR-Weg. Beim Vorbereiten von #1834 fiel die Sonde in beiden Formen aus.
- **`--seccomp-trap` (#1348) ist der erste Griff bei SIGSYS** unter
  `@capabilities`. Von außen ist die verworfene Nummer nicht bestimmbar: KILL
  tötet vor dem ptrace-Stop, gdb bekommt keinen Stop, `dmesg` ist restricted.
  Mit TRAP steht sie als `si_syscall` im strace (#1830). Nicht bisektieren.
- **Ein Vergleich gegen `objdump`** braucht `-z` (sonst werden lange Nullfolgen
  mit `...` abgekürzt und der Rest gar nicht disassembliert) und
  `--no-show-raw-insn` (sonst zählen die Byte-Folgezeilen langer Befehle als
  eigene Befehle). Ohne beides sah ein korrekter Dekodierer nach 947
  Abweichungen aus (#1370). Verglichen werden die BEFEHLSGRENZEN, nicht der
  Text: eine falsche Länge verschiebt alles danach.

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
