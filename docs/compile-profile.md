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
| `--compile-profile-function=NAME` | Detaildaten auf einen Funktionsnamen beschränken (**einfacher** Name, siehe unten) |
| `--compile-profile-pass=ID` | Detaildaten auf eine Pass-Kennung beschränken |
| `--compile-profile-max-events=N` | Deckel der Einzelereignisse, `1`..`100000000`, Vorgabe `16384` |

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
- `--compile-profile-max-events` braucht `--compile-profile-level=detailed`.
  Nur dort entstehen Einzelereignisse; eine Grenze für Ereignisse, die in
  dieser Stufe gar nicht anfallen, liest sich hinterher wie eine wirksame.
- Es gibt **kein „unbegrenzt"**. Jeder Eintrag belegt Speicher im gemessenen
  Lauf, und ein Deckel, den man abschalten kann, ist keiner. Der Wert muss
  vollständig aus Ziffern bestehen: `--compile-profile-max-events=12x` ist ein
  CLI-Fehler, kein stillschweigend angenommenes `12`.
- Wird der Deckel erreicht, zählt `collection.events_dropped` die nicht
  aufgezeichneten Ereignisse und `collection.truncated` steht auf `true`. Ein
  Bericht, der stillschweigend aufhört, liest sich wie ein vollständiger.

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
| `decisions`, `decision_summary` | Einzelentscheidungen und Zähler je Grund |
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
- `vectorize`: in `detailed` `per_event` — `cg_vmErkennen` meldet jede
  Entscheidung. In `basic` und `analysis` `not_instrumented`: der Pass läuft
  ununterbrochen, erfasst aber nichts. Auf arm64 und riscv ist er `absent` —
  diesen Pass gibt es dort nicht, er ist nicht bloß stumm;
- `ir-optimize`: `not_instrumented`. Die acht Pässe entscheiden tatsächlich
  etwas, melden es aber noch nicht;
- `inline`: `not_run`. `src/ir_inline.lyx` ist importiert, wird aber nie
  instanziiert, und `getFuncBodyStart`/`getFuncBodyEnd` liefern fest `0`;
- `coverage.missing_capabilities` nennt `PHASE_RSS`, `THREAD_CPU_TIME`,
  `CHILD_CPU_TIME`, `CRITICAL_PATH`, `IO_COUNTERS`, `ALLOCATION_COUNTERS` und
  `INPUT_HASHES`. `DECISION_EVENTS` steht dort nur außerhalb von `detailed`.

Leere `decisions` bedeuten deshalb **nicht** „geprüft und nichts gefunden" —
außerhalb von `detailed` sagt `coverage` das mit `DECISION_EVENTS`.

## Entscheidungen

In `detailed` erklärt der Bericht, warum eine Schleife vektorisiert wurde oder
nicht. Quelle ist `cg_vmErkennen` in `src/codegen_x86.lyx`: die 38
Ausstiegsstellen melden einen stabilen `reason_code`, der Erfolgsfall meldet
`VECTOR_APPLIED_ALIAS_CHECKED_AT_RUNTIME`.

```json
{
  "pass_id": "vectorize",
  "outcome": "rejected",
  "reason_code": "CONDITION_NOT_I_LT_N",
  "function": "summe",
  "location": { "file": "src/std/string.lyx", "line": 368 }
}
```

- **Beide Seiten stehen im Bericht.** Ein Bericht, der nur Ablehnungen zählt,
  wäre auch von einem Vektorisierer erfüllt, der nie etwas anwendet.
- Der `reason_code` ist die stabile Achse. Der Erklärungstext einer Oberfläche
  darf sich ändern, der Code nicht.
- `outcome` ist `applied` oder `rejected`. Die Überlappung von Ziel und
  Quellen ist beim Erfolgsfall **nicht statisch bewiesen**, sondern zur
  Laufzeit geprüft — daher der sprechende Code statt eines „alias proven".
- **Die Stelle gehört zum Eintrag, nicht zum Lauf.** Eine Entscheidung in
  einer importierten Unit trägt deren Pfad. `cg_lineOf` zählt in der Quelle
  der gerade erzeugten Unit; ein Pfad aus dem Lauf wäre zu einer fremden
  Zeilennummer eine erfundene Stelle.
- Knoten ohne Quelloffset haben keine Zeile. Dort steht
  `{"value": null, "unavailable": "NO_SOURCE_OFFSET"}` statt „Zeile 1".
- Dieselbe Quellzeile kann mehrfach auftauchen: gezählt wird je
  **Erzeugungsvorgang**, und eine generische Funktion wird je Instanz erzeugt.
- `decision_summary` zählt nach `pass_id`, `outcome` und `reason_code`.

### Filter

`--compile-profile-function` vergleicht den **einfachen** Namen, den der
Codegen an der Entscheidungsstelle hat; einen qualifizierten gibt es dort
nicht. Der Bericht sagt das in `coverage.filters.function_match`
(`"plain_name"`), statt einen zu behaupten. Ein Lambda heißt `<lambda>`.

Filter beschneiden **nur** `decisions`. `decision_summary` bleibt global,
sonst läse sich eine gefilterte Sicht wie der ganze Lauf;
`coverage.filters.matches` nennt die Trefferzahl und `collection.warnings`
sagt, dass gefiltert wurde.

### Stufen

| Stufe | Inhalt |
|---|---|
| `basic` | Compileridentität, effektive Optionen, Ziel, Status, Gesamt- und Phasenzeiten, Prozessressourcen, Ergebnisgröße |
| `analysis` | zusätzlich Phasenkennzahlen (Importzeit, Lookup-Aufrufe und -Vergleiche, Parse-Cache-Treffer, Vektorschleifen, …) |
| `detailed` | zusätzlich Einzelentscheidungen samt Grund und Stelle |

Die feinen Zähler kosten im Rumpf der Phasen etwas und bleiben in `basic`
aus. Phasen**zeiten** stehen schon in `basic` — sie sind der Zweck der Stufe.

## Was das Profil nicht sagt

- **Compilerperformance und Programmlaufzeit sind getrennte Größen.** Aus
  einem Build folgt keine gemessene Laufzeit des Erzeugnisses.
- Die Messung beeinflusst den gemessenen Lauf. Stufe und erfasster Umfang
  stehen im Bericht; ein exakt herausgerechneter Messoverhead wird nicht
  behauptet. In `detailed` berechnet das Profil selbst Quellzeilen, die
  Kennzahl `lineOf_aufrufe` enthält dort also auch die Aufrufe des Profils.
  Das steht als Warnung in `collection.warnings`; es herauszurechnen wäre eine
  Schätzung, die wie eine Messung aussieht.
- `build_config_id` (später) beweist keine Byte-Reproduzierbarkeit. Die
  tatsächlichen Ausgabebytes identifiziert ein Artifact-Hash.
- Eine Einzelmessung ist kein Performancebeweis. Für Vergleiche gehören
  wiederholte Läufe und die Streuung dazu.

## Was es kostet

Gemessen mit `tools/bench_profil_overhead.sh` auf `src/lyxc.lyx` (die größte
Last im Repo, rund 4400 geprüfte Schleifen), lyxc 1.2.29A, Intel Core i5-8250U,
gepinnt, neun alternierende Paare je Fassung — Median der paarweisen Differenz
gegen einen Rauschboden von −0,05 %:

| Fassung | Paardifferenz |
|---|---|
| `basic` | +0,93 % |
| `analysis` | +3,18 % |
| `detailed` | +1,70 % |

Die Einzelspannen liegen bei rund 20 %, die Reihenfolge `analysis` >
`detailed` ist damit **nicht** nachgewiesen — die Größenordnung „wenige
Prozent" schon. Protokoll:
`bench/ergebnisse/2026-11-03_profil-overhead_i5-8250U.md`. Ein
Null-Overhead-Versprechen gibt dieser Aufbau nicht her, und der Bericht
behauptet keines.

Die Serialisierung steht als `collection.serialize_ns` im Bericht selbst
(29,4 ms bei 1861,6 ms Übersetzung in `detailed`) und **neben** der
Compilezeit, nicht darin.

Bis zu diesem Schritt kostete `detailed` auf derselben Last +1037 %, und ein
Lauf wurde vom OOM-Killer getötet: die Einzelliste wurde mit `StrConcat`
gebaut (neue Zeichenkette je Anhang, byteweise kopiert, Arena gibt nichts
zurück) und die Zusammenfassung verglich jeden Eintrag mit allen vorherigen.
Beides ist durch einen Anhängepuffer und einen einzigen Durchlauf ersetzt. Mit
der kleinen Testquelle wäre es unentdeckt geblieben — **der Overhead einer
Messung gehört auf die größte verfügbare Last**.

## Nachweis

`tests/compile_profile_test.sh` (im `test`-Ziel) prüft den Datenvertrag, die
Fehlerpfade und vor allem: **das Compilat ist mit und ohne Schalter bitgleich**
(SHA-256, alle drei Stufen). Dass eine JSON-Datei entsteht, ist dagegen ein
Vorhandenseinstest und wird als Nachweis nicht akzeptiert.

Der Deckel wird **zweiseitig** geprüft: mit einer kleinen Grenze stehen genau
so viele Ereignisse im Bericht und der Rest als `events_dropped`, ohne Deckel
wird nichts verworfen und `truncated` bleibt `false`. Aufgezeichnete plus
verworfene Ereignisse müssen die Zahl des ungedeckelten Laufs treffen — ein
Test nur mit kleiner Grenze wäre auch von einem Deckel erfüllt, der immer
zuschlägt.
