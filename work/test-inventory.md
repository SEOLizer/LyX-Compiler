# Testbestand (Inventur zu Issue #1004)

Stand 2026-08-01, lyxc 1.0.11C — **abgeschlossen**.

Ausgangslage am 31.07.: `make test` rief 20 Prüfläufe auf, während in `tests/`
daneben 8 Shell-Tests und 193 `.lyx`-Tests lagen, die nie angefasst wurden.
Zwei davon schlugen nachweislich fehl. Diese Datei hält fest, was daraus wurde.

## Ergebnis

| | Anzahl |
|---|---|
| Testdateien insgesamt | 280 |
| davon einem Ziel oder einer Liste zugeordnet | **280** |
| `make test` | 20 Prüfläufe, 0 FAIL |
| `make test-lyx` (suite-full) | **143 grün, 0 bekannt rot, 0 unerwartet rot** |
| `make test-lyxos-units` (suite-lyxos) | 28 Einträge |
| `make test-external` (suite-external) | 15 übersetzen, 9 bekannt defekt (#1061) |
| `suite-manual` | 4 — nicht automatisch beurteilbar |
| `suite-broken` | 1 — #1024 |

`tests/test_coverage_test.sh` läuft in `make test` und meldet jede Testdatei,
die in keinem Ziel und in keiner Liste steht. Damit kann der Bestand nicht mehr
unbemerkt wachsen — Schritt 3 des Issues.

## Was die Inventur zutage gefördert hat

Die eigentliche Ausbeute waren nicht die Zahlen, sondern die Defekte darunter.
Alle sind inzwischen behoben:

| Befund | Issue |
|---|---|
| Methodenzeiger-Regression aus PR #988 (vier Shell-Tests rot) | in der Inventur behoben |
| `for i in range()` erzeugte gar keinen Code | #1007 |
| `defer` lief am Funktionsende statt am Blockende | #1006 |
| `defer`-Argumente wurden erst beim Blockende ausgewertet | #1030 |
| Unterstrich im Float-Literal wurde verschluckt | #1011 |
| `uint8` als Typ im var-Deklarator unbekannt | #1010 |
| `Printf` fehlte im x86-Codegen | #1012 |
| `std.hl7.results` fehlte | #1013 |
| Typparameter wurden von sema nicht aufgelöst | #1009 |
| `@packed` war wirkungslos | #1038 |
| statisches Array als Struct-Feld: Schreiben stürzte ab | #1052 |
| `f64ToInt100` lieferte immer 0 — traf die ganze PDF-Schicht | #1017 |
| `PrintLn(f64)` und `PrintLn(StrFromInt(x))` gaben Platzhalter bzw. Zeiger aus | #1049, #1058 |

Dazu zwei Befunde am **Testapparat selbst**:

- Der Suite-Runner zählte `FAIL` als Teilzeichenkette ohne Rücksicht auf Groß-
  und Kleinschreibung und färbte damit drei einwandfreie Tests rot — die Wörter
  standen in *grünen* Zeilen („after failed submit", „lseek failure",
  „PGTxFailed"). Siehe #1017.
- `suite-external.txt` war zwar angelegt, wurde aber von **keinem Ziel**
  ausgeführt. Die Einträge galten als zugeordnet und verfielen unbemerkt: beim
  ersten Durchlauf übersetzten 13 von 24 nicht. Siehe #1061.

Der zweite Fall ist die Lehre dieser Inventur in Reinform: **eine Zuordnung ist
noch keine Ausführung.** Eine Liste, die niemand abarbeitet, sieht in jeder
Abdeckungsprüfung genauso gut aus wie ein laufendes Ziel.

## Die Einteilung

- **`suite-core.txt`** (16) — Kernsprache, läuft in `make test`.
- **`suite-full.txt`** (143) — alles, was auf Linux/ELF ohne Fremdabhängigkeit
  läuft; `make test-lyx`. Einträge dürfen testeigene Übersetzungsoptionen
  tragen (`meta_safe_test --meta-safe`).
- **`suite-lyxos.txt`** (28) — brauchen `--target=lyxos`.
- **`suite-external.txt`** (24) — brauchen Zugangsdaten oder laufende Dienste.
  Ausgeführt werden sie nicht, **übersetzt** schon: `make test-external`.
- **`suite-manual.txt`** (4) — nicht automatisch beurteilbar, etwa ein
  Reproduktionsfall, dessen Exit-Code von Hand gelesen werden will, oder ein
  Laufzeittest für macOS.
- **`suite-broken.txt`** (1) — übersetzt nicht, mit Issue.

## Erfolgskonvention

Die Konvention ist im Bestand uneinheitlich: manche Tests liefern 0, manche 42,
und die `edi*`-Familie druckt „ALL PASS" und endet mit Exit 1.
`tests/run_lyx_suite.sh` urteilt deshalb nach der **Ausgabe** — eine
`FAIL`-Markierung am Zeilenanfang ist rot, `PASS`/`OK:` ohne solche Markierung
grün; der Exit-Code zählt nur, wenn die Ausgabe nichts hergibt. Ein Absturz
(rc ≥ 128) ist immer rot, auch nach lauter PASS-Zeilen.
