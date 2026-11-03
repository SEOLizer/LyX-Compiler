# Compilatprofil (`--compile-profile`)

Optionaler, strukturierter Bericht über einen Übersetzungslauf: welche Arbeit
wie lange gedauert hat, unter welchen Bedingungen sie lief und — ab Stufe
`detailed` — warum Optimierungsentscheidungen getroffen oder verworfen wurden.
Gedacht für Compilerentwicklung, Performanceanalyse und den Vergleich von
Builds. Issue #2343, Schemaentwurf und Bestandsaufnahme in
`work/compile-profile-schema.md`.

Ohne Schalter entsteht keine Datei, kein Ereignispuffer und keine Zusatzarbeit.

## Aufruf

```sh
# Basisprofil, Pfad aus dem Ausgabenamen abgeleitet: app.lyxc-profile.json
lyxc main.lyx -o app --compile-profile

# Expliziter Pfad
lyxc main.lyx -o app --compile-profile=reports/build.json

# Mit Phasenkennzahlen
lyxc main.lyx -o app --compile-profile=reports/build.json \
  --compile-profile-level=analysis
```

| Schalter | Bedeutung |
|---|---|
| `--compile-profile` | Profil einschalten, Stufe `basic`, Pfad `<ausgabe>.lyxc-profile.json` |
| `--compile-profile=PFAD` | Profil einschalten, Bericht nach `PFAD` |
| `--compile-profile-level=L` | `basic` (Vorgabe), `analysis`, `detailed` |
| `--compile-profile-function=NAME` | Detaildaten auf einen qualifizierten Funktionsnamen beschränken |
| `--compile-profile-pass=ID` | Detaildaten auf eine Pass-Kennung beschränken |

Verbindliches Verhalten:

- `--compile-profile` und `--compile-profile=…` sind **zwei getrennte, exakte
  Prüfungen**. Der Pfad kommt nur nach `=`; der Schalter frisst nie den
  nachfolgenden Quelldateinamen.
- Stufe oder Filter **ohne** `--compile-profile` sind ein CLI-Fehler (Exit 2).
  Filter in `basic` ebenso: dort entstehen keine Detaildaten, die ein Filter
  einschränken könnte.
- Unbekannte Stufe und unbekannte Pass-Kennung werden **vor dem Bau** gemeldet,
  mit Auflistung der gültigen Werte.
- Ein Profilpfad, der die Quelldatei oder die Ausgabedatei treffen würde, ist
  ein CLI-Fehler **vor dem Bau** — nicht eine Ablehnung danach, die den Lauf
  trotzdem als Erfolg meldete.
- Relative Pfade gelten relativ zum Arbeitsverzeichnis. Fehlende
  Zielverzeichnisse werden nicht angelegt.
- Die Abschlussmeldung geht auf **stderr**; stdout bleibt den bestehenden
  Compilerfunktionen.

## Fehlerverhalten

| Fall | Verhalten |
|---|---|
| Regulärer Compilerfehler | Teilbericht mit `status.result = "compile_error"`, `completion = "partial"`; der ursprüngliche Exitcode bleibt |
| Build übersprungen (aktuell) | Bericht mit `result = "up_to_date"`, `completion = "none"`; Zeiten als `NOT_COMPILED` |
| Profilziel nicht beschreibbar | Warnung mit Pfad auf stderr, der erfolgreiche Build bleibt erfolgreich, Exitcode unverändert, kein halber Bericht |
| Ungültige Profiloption | CLI-Fehler (Exit 2) vor der Übersetzung |
| SIGKILL, Speichermangel | kein Bericht zugesichert; es wird nicht aus Signalhandlern serialisiert |

Der Bericht wird in eine Nachbardatei `<pfad>.tmp.<pid>` im Zielverzeichnis
geschrieben und erst nach vollständigem Schreiben an seinen Platz gezogen. Ein
Schreibfehler ersetzt einen vorhandenen Bericht nicht durch eine halbe Datei.

Mehrere gleichzeitig laufende Übersetzungen brauchen verschiedene Profilpfade;
ein automatisches Zusammenführen gibt es nicht.

## Datenvertrag

JSON, `schema_version` zunächst `"1.0"`. Eine inkompatible Änderung erhöht die
Hauptversion. Dauern in **ganzen Nanosekunden**, Größen in **Byte**.

### Messobjekte

Jeder Zahlenwert, der eine Messung ist, steht als Objekt mit Herkunft:

```json
{ "value": 27976992, "origin": "measured" }
```

`origin` ist `measured`, `estimated`, `pgo` oder `user_supplied`. Werte, die
den Prozess als Ganzes betreffen, tragen zusätzlich `scope`:

```json
{ "value": 17924096, "origin": "measured", "scope": "process" }
```

Fehlt die Messfähigkeit, steht statt der Zahl ein Grund:

```json
{ "value": null, "unavailable": "PHASE_RSS" }
```

**Eine `0` heißt gemessene Null.** Eine fehlende Messung wird nie als `0 ns`
oder `0 Byte` ausgegeben — diese Verwechslung hat im Compiler mehrfach einen
echten Defekt verdeckt. Listen ohne Einträge sind `[]`.

### Bereiche

| Bereich | Inhalt |
|---|---|
| `invocation_id` | Kennung dieses Laufs (Prozessnummer und Startzeitpunkt). Steht **nicht** im Compilat |
| `compiler` | Version; `commit` ist `unavailable`, solange das Binary keinen trägt |
| `inputs` | Wurzelquelle und `completeness`. Derzeit `"root_only"`: Inhalts-Hashes der tatsächlich gelesenen Quellen gibt es noch nicht |
| `configuration` | Ziel, Optimierungsstufe, Debugsymbole, Laufzeitprüfungen |
| `environment` | Betriebssystem, Workerzahl (lyxc übersetzt einphasig: 1), beobachteter Cachezustand |
| `coverage` | Stufe, Filter, Zustand je Pass, fehlende Fähigkeiten |
| `status` | `result`, `exit_code`, `completion` |
| `summary` | Walltime, Prozess-CPU-Zeit, Spitzen-RSS, Ergebnisgröße |
| `spans` | Phasen mit Offset, Dauer und Kennzahlen |
| `decisions`, `decision_summary` | Einzelentscheidungen und Zähler (ab Schritt 2) |
| `artifacts` | erzeugte Dateien mit Größe |
| `collection` | Zahl der Spannen und Kennzahlen, Trunkierung, Warnungen, Serialisierungsdauer |

### Zeiten

- `compile_wall_ns` beginnt **nach** erfolgreicher Auswertung der
  Kommandozeile und endet mit dem Ende der Pipeline.
- `collection.serialize_ns` steht **neben** dieser Zeit, nicht darin. Es wird
  kein „herausgerechneter Messoverhead" ausgewiesen.
- `spans[].duration_ns` sind Einzeldauern. **Ihre Summe ist keine Walltime**,
  und es gibt im Bericht absichtlich kein Feld, das sie als solche anbietet.
- `spans[].self_duration_ns` ist `unavailable` (`NO_CHILD_SPANS`): Selbstzeit
  braucht Kindspannen und eine Behandlung überlappender Intervalle; beides
  gibt es nicht.
- `span_id` gilt **nur innerhalb eines Laufs**. Für den Vergleich zweier
  Builds ist `pass_id` die stabile Achse.
- `peak_rss_bytes` ist ein Prozesswert und wird **keiner Phase** zugeschrieben.

### Abdeckung: vier Zustände

`coverage.passes` unterscheidet:

| `timing` / `decisions` | Bedeutung |
|---|---|
| `measured` / `per_event` | wird gemessen beziehungsweise meldet jede Entscheidung |
| `aggregate_only` | nur Zähler, keine Einzelereignisse |
| `not_instrumented` | die Stelle existiert und meldet nichts |
| `not_run` | der Pass existiert als Code und lief in diesem Lauf nicht |
| `absent` | diesen Pass gibt es in diesem Compiler nicht |

Der Unterschied zwischen `not_run` und `absent` ist nicht Kosmetik: er trägt
den späteren Buildvergleich. Ein nicht ausgeführter Pass ist kein verworfener
Optimierungskandidat.

Stand dieses Umfangs:

- gemessen: `lexer`, `parser`, `sema`, `analysis`, `ir-lowering`,
  `codegen-x86_64`, `codegen-win-x86_64`, `codegen-macos-x86_64`,
  `lyxos-emit` — je nach Ziel die, die gelaufen sind;
- `ir-optimize` und `vectorize`: `not_instrumented`. Beide entscheiden
  tatsächlich etwas, melden es aber noch nicht (Schritt 2);
- `inline`: `not_run`. `src/ir_inline.lyx` ist importiert, wird aber nie
  instanziiert, und `getFuncBodyStart`/`getFuncBodyEnd` liefern fest `0`;
- `coverage.missing_capabilities` nennt `PHASE_RSS`, `THREAD_CPU_TIME`,
  `CHILD_CPU_TIME`, `CRITICAL_PATH`, `IO_COUNTERS`, `ALLOCATION_COUNTERS`,
  `INPUT_HASHES` und `DECISION_EVENTS`.

Leere `decisions` bedeuten deshalb **nicht** „geprüft und nichts gefunden" —
das sagt `coverage` mit `DECISION_EVENTS`.

### Stufen

| Stufe | Inhalt |
|---|---|
| `basic` | Compileridentität, effektive Optionen, Ziel, Status, Gesamt- und Phasenzeiten, Prozessressourcen, Ergebnisgröße |
| `analysis` | zusätzlich Phasenkennzahlen (Importzeit, Lookup-Aufrufe und -Vergleiche, Parse-Cache-Treffer, Vektorschleifen, …) |
| `detailed` | zusätzlich Einzelentscheidungen (Schritt 2) |

Die feinen Zähler kosten im Rumpf der Phasen etwas und bleiben in `basic`
aus. Phasen**zeiten** stehen schon in `basic` — sie sind der Zweck der Stufe.

## Was das Profil nicht sagt

- **Compilerperformance und Programmlaufzeit sind getrennte Größen.** Aus
  einem Build folgt keine gemessene Laufzeit des Erzeugnisses.
- Die Messung beeinflusst den gemessenen Lauf. Stufe und erfasster Umfang
  stehen im Bericht; ein exakt herausgerechneter Messoverhead wird nicht
  behauptet.
- `build_config_id` (später) beweist keine Byte-Reproduzierbarkeit. Die
  tatsächlichen Ausgabebytes identifiziert ein Artifact-Hash.
- Eine Einzelmessung ist kein Performancebeweis. Für Vergleiche gehören
  wiederholte Läufe und die Streuung dazu.

## Nachweis

`tests/compile_profile_test.sh` (im `test`-Ziel) prüft den Datenvertrag, die
Fehlerpfade und vor allem: **das Compilat ist mit und ohne Schalter bitgleich**
(SHA-256, alle drei Stufen). Dass eine JSON-Datei entsteht, ist dagegen ein
Vorhandenseinstest und wird als Nachweis nicht akzeptiert.
