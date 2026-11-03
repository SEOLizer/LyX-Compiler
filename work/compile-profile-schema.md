# Compilatprofil — Schemaentwurf (`--compile-profile`)

Stand: 2026-11-01 · lyxc 1.2.27E · **Entwurf, nicht umgesetzt**

> Korrektur gegenüber der Fassung vom 2026-10-30: dort stand, es gebe keinen
> Auto-Vektorisierer. Das war ein Stale-Befund — die Bestandsaufnahme lief auf
> `perf/namensindex-felder-2316`, der Vektorisierer war zu diesem Zeitpunkt in
> `develop` schon gemergt (#2194, PR #2327). Die Regel „Herkunft des Artefakts
> vor dem Code prüfen" gilt auch für die *Abwesenheit* von Code.

Entwurf des Datenvertrags für ein optionales, strukturiertes Profil des
Kompilierungsvorgangs. Dieses Dokument legt nur das Format und die
Belegbarkeit jedes Feldes fest. Die Umsetzung folgt getrennt.

## 1. Bestandsaufnahme

Die Messinfrastruktur ist weitgehend vorhanden; neu ist der Datenvertrag.

| Baustein | Fundstelle | Zustand |
|---|---|---|
| Ereignispuffer (32-Byte-Records: name, t0, dauer, args) | `src/lyxc.lyx:5768` `_zlEreignis` | vorhanden (#2174) |
| Spans je Phase | `_passStart`/`_passEnd`, `src/lyxc.lyx:5828` | vorhanden |
| Zusatzwerte je Phase (`args`) | `_zlZusatz`, `src/lyxc.lyx:5782` | vorhanden |
| Monotone Uhr | `MonotonicTimeNano()` | vorhanden |
| Prozess-CPU-Zeit | `lyxc_zlCpuNs()` | vorhanden |
| Peak-RSS | `lyxc_zlPeakRssKb()` | vorhanden |
| JSON-Ausgabe | `_zlSchreiben`, `src/lyxc.lyx:5791` | Chrome-Trace, **nicht atomar** |
| Billiger Aus-Pfad | `_passStart`: früher `return` ohne Flag | vorhanden |
| Pass-Textausgabe | `--trace-passes` | vorhanden |

**Entscheidung: kein zweiter Puffer.** `--compile-profile` liest denselben
Ereignispuffer wie `--time-trace` und bekommt nur einen zweiten Serializer.
Zwei Aufzählungen derselben Sache driften auseinander (CLAUDE.md,
„Die zweite Stelle wurde nicht nachgezogen").

### Instrumentierte Spans heute

Stabile IDs, wie sie heute an `_passStart` übergeben werden:

```
lexer  parser  sema  analysis  ir-lowering
codegen-x86_64  codegen-win-x86_64  codegen-macos-x86_64  lyxos-emit
```

Nicht instrumentiert: `ir_optimize`, `ir_inline`, `ir_static_analysis`,
`ir_call_graph`, Linkerschritt, `lyu`-Schreiben, Paketauflösung.

### Was es an Entscheidungen zu melden gibt

- **`ir_optimize`** (`src/ir_optimize.lyx`, 8 Pässe) hat echte
  Ablehnungszweige mit benennbarer Ursache: `strengthReduction`
  (kein Zweierpotenz-Divisor), `deadCodeElimination` (`hasSideEffect`),
  `constantFolding` (f64-Sperre #1499/#1803), `copyPropagation`
  (`_darfNutzen`), `commonSubexprElimination`, `removeRedundantLoads`,
  `mergeStores`, `eliminateUnreachableBlocks`.
- **Inlining liefert nichts.** `src/ir_inline.lyx` ist in `lyxc.lyx:26`
  importiert, wird aber nie instanziiert; `getFuncBodyStart`/`getFuncBodyEnd`
  (`ir_inline.lyx:488`, `:493`) geben fest `0` zurück. `shouldInline` mit
  Schwelle und Tiefe existiert, läuft aber nicht. Kosten- und Grenzwerte
  wären eine Erfindung.
- **Der Autovektorisierer ist die beste Entscheidungsquelle** (#2194).
  `cg_vmErkennen` (`src/codegen_x86.lyx:23827`) prüft eine elementweise
  Schleife gegen eine Kette von Bedingungen und verlässt sie bei Nichtpassen
  mit `return 0` — **29 solcher Zweige**, jeder mit benennbarer Ursache, genau
  an der Stelle, wo die Entscheidung fällt. Die angewandte Seite zählt
  `zlVmVektor` (`:1242`, hochgezählt in `cg_vmEmit`, `:24038`).

`inline` steht als `not_run` in `coverage.passes`, nicht als leere
Entscheidungsliste, die „geprüft und nichts gefunden" suggeriert.

## 2. Schema 1.0

Einheiten: Dauern **Integer-Nanosekunden** (`_ns`), Größen **Bytes**
(`_bytes`), Speicher **Bytes** (nicht KiB wie `lyxc_zlPeakRssKb`, die
Umrechnung geschieht beim Schreiben). Zeitstempel in `spans` sind Offsets
zum Profilbeginn, nicht Kalenderzeit.

Jeder Zahlenwert, der eine Messung ist, steht in einem Messobjekt:

```json
{ "value": 1234567, "origin": "measured" }
```

`origin` ∈ `measured` | `estimated` | `pgo` | `user_supplied`.
Fehlt die Fähigkeit, steht statt des Messobjekts:

```json
{ "value": null, "unavailable": "NO_PHASE_RSS" }
```

**Niemals `0` für „nicht gemessen".** Ein `value: 0` heißt gemessene Null.

### 2.1 Rahmen

```json
{
  "schema_version": "1.0",
  "invocation_id": "…",
  "compiler": { },
  "inputs": { },
  "configuration": { },
  "environment": { },
  "coverage": { },
  "status": { },
  "summary": { },
  "spans": [ ],
  "decisions": [ ],
  "decision_summary": [ ],
  "artifacts": [ ],
  "collection": { }
}
```

Listen ohne Einträge sind `[]`. Unbekannte Bereiche fehlen nicht, sondern
tragen ihren Verfügbarkeitsgrund.

### 2.2 `compiler`

```json
"compiler": {
  "version": "1.2.26G",
  "version_date": "2026-10-30",
  "commit": { "value": null, "unavailable": "NO_COMMIT_IN_BINARY" },
  "self_hosted": true,
  "seed_version": "1.0.12A"
}
```

`version` aus denselben Strings, die `tests/version_consistency_test.sh`
zusammenhält. `commit` ist heute nicht im Binary — darum `unavailable`,
nicht ein leerer String. `--build-info` (`lyxc.lyx:1683`) prüfen, ob dort
mehr steht.

### 2.3 `inputs`

```json
"inputs": {
  "root": "src/lyxc.lyx",
  "hash_algorithm": "sha256",
  "completeness": "resolved_only",
  "files": [
    { "path": "src/lyxc.lyx", "bytes": 241733, "hash": "…" },
    { "path": "std/alloc.lyx", "bytes": 8120, "hash": null }
  ]
}
```

- Pfade projektbezogen und relativ, keine absoluten Heimatpfade.
- `completeness`: `complete` nur, wenn jede gelesene Quelle und jede `.lyu`
  erfasst ist. Realistisch zunächst `resolved_only` — der Importresolver
  kennt zwei stdlib-Orte (`std/**` und
  `lyx-compiler/usr/include/...`) und bevorzugt `.lyx` vor `.lyu`; welche
  Datei tatsächlich gelesen wurde, muss aus dem Resolver kommen, nicht aus
  dem Importnamen geraten werden.
- `hash: null` ohne `unavailable` ist unzulässig; entweder Hash oder Grund.

### 2.4 `configuration`

Nur semantikrelevante, effektive Optionen. Host und Ziel getrennt.

```json
"configuration": {
  "target": "linux-x86_64",
  "arch": "x86_64",
  "format": "elf",
  "output_type": "exe",
  "opt_level": 2,
  "no_opt": false,
  "target_cpu": { "value": null, "unavailable": "NOT_SET" },
  "target_energy": { "value": null, "unavailable": "NOT_SET" },
  "runtime_checks": false,
  "debug_symbols": false,
  "capabilities_mode": "strict",
  "std_path": ".",
  "include_paths": ["."]
}
```

Keine Umgebungsvariablen pauschal, keine Credentials, keine Lizenzpfade
(`--license-file=` bleibt draußen).

### 2.5 `environment`

```json
"environment": {
  "os": "linux",
  "host_arch": "x86_64",
  "host_cpu_model": "…",
  "workers": 1,
  "cache_state": { "value": "parse_cache_present", "origin": "measured" }
}
```

`workers: 1` ist die Wahrheit: lyxc kompiliert heute einphasig. Keine
Warm/Kalt-Behauptung — nur der beobachtbare Zustand des Parse-Cache
(#2176/#2314 liefern `parse_cache_eintraege`, `_treffer`,
`_lesen_gespart`), oder `user_supplied`, wenn der Aufrufer es angibt.

### 2.6 `coverage`

Der wichtigste Bereich. Er trennt „nicht passiert" von „nicht gemessen".

```json
"coverage": {
  "level": "analysis",
  "filters": { "function": null, "pass": null, "matches": null },
  "passes": [
    { "pass_id": "sema",          "timing": "measured", "decisions": "not_instrumented" },
    { "pass_id": "ir-lowering",   "timing": "measured", "decisions": "not_instrumented" },
    { "pass_id": "ir-optimize",   "timing": "measured", "decisions": "aggregate_only" },
    { "pass_id": "vectorize",     "timing": "measured", "decisions": "per_event" },
    { "pass_id": "inline",        "timing": "not_run",  "decisions": "not_run",
      "note": "Pass ist nicht verdrahtet (ir_inline.lyx:488 liefert 0)" }
  ],
  "missing_capabilities": [
    "PHASE_RSS", "THREAD_CPU_TIME", "CRITICAL_PATH", "IO_COUNTERS",
    "ALLOCATION_COUNTERS", "CHILD_CPU_TIME"
  ]
}
```

`timing` ∈ `measured` | `not_instrumented` | `not_run` | `absent`.
`decisions` ∈ `per_event` | `aggregate_only` | `not_instrumented` |
`not_run` | `absent`.

`absent` heißt: den Pass gibt es im Compiler nicht. `not_run` heißt: er
existiert als Code, lief in diesem Lauf aber nicht. Der Unterschied ist für
den Buildvergleich entscheidend.

### 2.7 `status`

```json
"status": {
  "result": "success",
  "exit_code": 0,
  "completion": "full",
  "diagnostics": { "errors": 0, "warnings": 3 },
  "last_span": "codegen-x86_64"
}
```

`result` ∈ `success` | `compile_error` | `cli_error` | `aborted`.
`completion` ∈ `full` | `partial`. Bei `partial` nennt `last_span`, wo der
Lauf endete. Der Exitcode ist der des Compilers, nicht des Profils.

### 2.8 `summary`

```json
"summary": {
  "compile_wall_ns":    { "value": 4821993114, "origin": "measured" },
  "process_cpu_ns":     { "value": 4710220000, "origin": "measured",
                          "scope": "process" },
  "peak_rss_bytes":     { "value": 412778496,  "origin": "measured",
                          "scope": "process" },
  "phase_rss_bytes":    { "value": null, "unavailable": "PHASE_RSS" },
  "child_cpu_ns":       { "value": null, "unavailable": "CHILD_CPU_TIME" },
  "output_bytes":       { "value": 4087192, "origin": "measured" },
  "profile_serialize_ns": { "value": 1840221, "origin": "measured" }
}
```

- `compile_wall_ns` beginnt **nach** erfolgreicher CLI-Auswertung und endet
  mit dem Ende der Pipeline. `profile_serialize_ns` steht daneben, nicht
  darin.
- `peak_rss_bytes` trägt `scope: "process"` und wird **keiner Phase**
  zugeschrieben.
- Kein Feld „Messoverhead herausgerechnet".

### 2.9 `spans`

```json
"spans": [
  {
    "span_id": 3,
    "parent_span_id": null,
    "pass_id": "sema",
    "task_id": null,
    "thread_id": 0,
    "start_offset_ns": 318442000,
    "duration_ns": 1904221000,
    "self_duration_ns": { "value": null, "unavailable": "NO_CHILD_SPANS" },
    "metrics": {
      "importe_ns":        { "value": 812004000, "origin": "measured" },
      "importe_units":     { "value": 190, "origin": "measured" },
      "lookup_aufrufe":    { "value": 2411903, "origin": "measured" },
      "lookup_vergleiche": { "value": 88142991, "origin": "measured" }
    }
  }
]
```

- `span_id` ist **nur innerhalb eines Laufs** gültig. Der Buildvergleich
  läuft über `pass_id`, nie über `span_id`.
- `self_duration_ns` wird nur geschrieben, wenn Kindspans erfasst sind und
  Überlappungen korrekt behandelt werden. Heute hat der Puffer keine
  Verschachtelung → zunächst durchgehend `unavailable`.
- Die `metrics`-Schlüssel sind die bestehenden `_zlZusatz`-Felder, in
  Nanosekunden statt Mikrosekunden umbenannt (`importe_us` → `importe_ns`).
  Das ist ein bewusster Bruch gegenüber `--time-trace`; `--time-trace`
  bleibt wie es ist.
- Keine Summenbildung über `duration_ns` als Walltime — die Serialisierung
  schreibt dazu keine Summe, damit sie niemand falsch liest.

### 2.10 `decisions` (nur `detailed`)

```json
"decisions": [
  {
    "span_id": 6,
    "offset_ns": 2904112000,
    "pass_id": "ir-optimize.strength-reduction",
    "outcome": "rejected",
    "reason_code": "DIVISOR_NOT_POWER_OF_TWO",
    "function": "src.mathlib.SinF64",
    "unit": "src.mathlib",
    "location": { "value": null, "unavailable": "NO_IR_SOURCE_MAP" },
    "message": "Divisor ist keine Zweierpotenz; Shift nicht anwendbar.",
    "evidence": {
      "divisor": { "value": 10, "origin": "measured" }
    }
  }
]
```

- `outcome` ∈ `applied` | `rejected` | `deferred`.
- `reason_code` ist stabile Schnittstelle, `message` darf sich ändern.
- `location` nur, wenn `--ir-source-map` die Zuordnung trägt; sonst
  `unavailable`. **Vor der Umsetzung nachmessen**, ob die Zuordnung auf
  IR-Index-Ebene überhaupt bis zur Quellzeile reicht.
- Kein Feld „Codewachstum in Bytes", solange nur IR-Kosten bekannt sind.

**Zum Konzeptbeispiel `ALIAS_NOT_PROVEN`:** der Code passt hier nicht.
Überlappung wird nicht statisch bewiesen, sondern **zur Laufzeit** geprüft —
`cg_vmEmit` legt vor die Vektorschleife zwei Vergleichspaare (`c + len <= a`
oder `a + len <= c`, dasselbe für die rechte Seite) und springt bei
Überlappung in die skalare Fassung. Die Entscheidung des Compilers lautet also
`applied` mit `ALIAS_CHECKED_AT_RUNTIME`, nicht `rejected`.

**Keine Entscheidung ist die Pfadwahl AVX2 gegen SSE2** (`cg_cpuHat(2)` in
`cg_vmEmit`). Sie gehört als Merkmal an den Span, nicht in `decisions` —
sonst zählt `decision_summary` Pfadwahlen wie verworfene Kandidaten.

Reason-Codes aus `cg_vmErkennen`, je aus einem `return 0`-Zweig gelesen:

| Code | Auslöser | Zweig |
|---|---|---|
| `VECTOR_APPLIED` | Schleife auf den Vektorweg gelegt | `cg_vmEmit`, `zlVmVektor` |
| `ALIAS_CHECKED_AT_RUNTIME` | Überlappungsprüfung eingebaut | `cg_vmEmit` |
| `DEBUG_MODE` | `debugMode` oder `debugInfoEnabled` gesetzt | erster Zweig, `:23828` |
| `CONDITION_NOT_I_LT_N` | Bedingung ist nicht `i < n` auf zwei Locals | `CGT_LT`-Prüfung |
| `BODY_SHAPE_MISMATCH` | Rumpf nicht `poke`-Aufruf + `i := i + 1` | `CGN_BLOCK`-Kette |
| `HELPER_NOT_I_TIMES_K` | Hilfsvariable ist nicht `i * K` mit K Literal | #2334-Zweig |
| `HELPER_FACTOR_MISMATCH` | `K` passt nicht zur Elementbreite | `oK != breite` |
| `HELPER_SHADOWS_LOOP_VAR` | Hilfsvariable heißt wie Zähler oder Schranke | `cg_seq`-Prüfung |
| `STEP_NOT_PLUS_ONE` | Fortschaltung ist nicht `i := i + 1` | `CGT_PLUS`, Literal 1 |
| `WIDTH_UNKNOWN` | `poke`-Name ergibt keine Elementbreite | `cg_vmBreiteVonName` |
| `WIDTH_MISMATCH` | Leseseiten haben andere Breite als die Schreibseite | beide `peek`-Namen |
| `NOT_PEEK_CALL` | Leseseite ist kein `peekW`-Aufruf | `CGN_CALL`-Prüfung |
| `INDEX_FORM_MISMATCH` | Adressform nicht als Basis + Index auflösbar | `cg_vmBasisVon` |
| `OP_NOT_VECTORIZABLE` | Operation außer `+ - *` | `CGT_PLUS/MINUS/STAR` |
| `NO_VECTOR_OPCODE` | Breite und Operation haben keinen SSE-Befehl | `cg_sseGanzOpcode` |
| `NO_SSE4_FOR_PMULLD` | 0F-38-Befehl, Ziel-CPU ohne sse4 | `cg_cpuHat(1)`, `:23884` |
| `POINTER_IS_LOOP_VAR` | Zeiger ist der Zähler | `aOff == iOff` |
| `POINTER_IS_BOUND` | Zeiger ist die Schranke | `aOff == nOff` |

`NO_SSE4_FOR_PMULLD` ist der aussagekräftigste Fall: der Kommentar an der
Stelle begründet, warum hier **nicht** abgebrochen wird — eine automatische
Umformung darf keine CPU-Forderung erheben, die der Quelltext nicht gestellt
hat. Genau solche Begründungen soll das Profil tragen, statt sie im Quelltext
zu lassen.

Reason-Codes aus `ir_optimize`:

| Pass-ID | Code | Auslöser |
|---|---|---|
| `ir-optimize.const-fold` | `FOLD_APPLIED` | Faltung durchgeführt |
| `ir-optimize.const-fold` | `F64_FOLD_LOCKED` | f64-Sperre #1499/#1803 |
| `ir-optimize.copy-prop` | `DEF_NOT_USABLE` | `_darfNutzen` false |
| `ir-optimize.dce` | `HAS_SIDE_EFFECT` | `hasSideEffect` |
| `ir-optimize.strength-reduction` | `DIVISOR_NOT_POWER_OF_TWO` | `isPowerOfTwo` false |
| `ir-optimize.cse` | `CSE_APPLIED` | Teilausdruck ersetzt |
| `ir-optimize.redundant-load` | `LOAD_REMOVED` | Last entfernt |
| `ir-optimize.unreachable` | `BLOCK_UNREACHABLE` | Block entfernt |

Beide Listen sind aus den Zweigen von `src/codegen_x86.lyx` beziehungsweise
`src/ir_optimize.lyx` gelesen, nicht erfunden; jeder Code wird beim
Instrumentieren an seinem Zweig belegt.

Damit ist die Forderung „beide Seiten messen" erfüllbar: der Vektorisierer
liefert angewandte Fälle (`zlVmVektor`) **und** verworfene mit Grund. Mit
`ir_optimize` allein wäre nur die aggregierte Seite messbar gewesen.

### 2.11 `decision_summary`

Zähler, auch wenn `decisions` trunkiert wurde oder der Level nur
`analysis` ist.

```json
"decision_summary": [
  { "pass_id": "ir-optimize.strength-reduction",
    "outcome": "applied",  "reason_code": "SHIFT_APPLIED", "count": 412 },
  { "pass_id": "ir-optimize.strength-reduction",
    "outcome": "rejected", "reason_code": "DIVISOR_NOT_POWER_OF_TWO", "count": 97 }
]
```

Die Summen sind global und bleiben global, auch wenn ein Filter die
Einzelereignisse beschränkt. `collection.filtered` sagt das ausdrücklich.

### 2.12 `artifacts`

```json
"artifacts": [
  { "path": "app", "bytes": 4087192, "hash": "…", "role": "executable" }
]
```

`hash` identifiziert die tatsächlichen Ausgabebytes. Davon getrennt:

```json
"build_config_id": {
  "value": "…",
  "derived_from": ["inputs", "compiler", "configuration"],
  "inputs_complete": false
}
```

`build_config_id` beweist **keine** Byte-Reproduzierbarkeit, und
`inputs_complete: false` sagt, dass sie es auch nicht kann.

### 2.13 `collection`

```json
"collection": {
  "level": "detailed",
  "event_limit": 65536,
  "events_recorded": 12044,
  "events_dropped": 0,
  "truncated": false,
  "filtered": false,
  "warnings": [],
  "serialize_ns": { "value": 1840221, "origin": "measured" }
}
```

## 3. CLI (Entwurf)

```
--compile-profile                 Basisprofil, Pfad = <ausgabe>.lyxc-profile.json
--compile-profile=PFAD            expliziter Pfad
--compile-profile-level=LEVEL     basic | analysis | detailed  (Default basic)
--compile-profile-function=NAME   exakter qualifizierter Name
--compile-profile-pass=ID         stabile Pass-ID
```

Verbindlich:

- `--compile-profile` und `--compile-profile=…` sind **zwei getrennte,
  exakte Prüfungen**. Kein `StrStartsWith` ohne `=`, sonst frisst der
  Schalter den nächsten Quelldateinamen. (Vgl. `--std-path`-Off-by-one:
  `lyxc.lyx:1207` rechnet `arg + 11`, Länge des Präfixes *mit* `=`.)
- Level oder Filter ohne `--compile-profile` → CLI-Fehler vor Buildbeginn.
- Filter in `basic` → CLI-Fehler.
- Unbekanntes Level, unbekannte Pass-ID → CLI-Fehler über den bestehenden
  `_rejectWert`-Pfad, mit Auflistung der gültigen Werte.
- Filter ohne Treffer ist **kein** Fehler: `coverage.filters.matches = 0`
  plus Eintrag in `collection.warnings`.
- Profilpfad darf keine Quelldatei und keine Compilerausgabe überschreiben
  → Prüfung gegen `inputs.files` und `artifacts` vor dem Schreiben.
- Fehlende Zielverzeichnisse werden nicht angelegt.
- Abschlussmeldung mit Pfad und Level auf **stderr**; stdout bleibt frei.

## 4. Schreibpfad

`_zlSchreiben` schreibt heute direkt mit `FileWriteAll` — bei einem Fehler
mitten im Schreiben steht eine halbe Datei. Für das Profil:

1. `<pfad>.tmp.<pid>` im **Zielverzeichnis** schreiben,
2. volle Länge prüfen (`FileWriteAll` liefert die Bytes, negativ bei
   Fehler — nur die volle Länge ist Erfolg),
3. umbenennen.

Schlägt Schritt 1 oder 2 fehl: Warnung mit Pfad und Ursache auf stderr,
`.tmp` entfernen, **bestehenden Bericht nicht anfassen**, Compiler-Exitcode
unverändert lassen.

## 5. Fehlerverhalten

| Fall | Verhalten |
|---|---|
| Compilerfehler | Teilbericht mit `status.result = compile_error`, `completion = partial`, ursprünglicher Exitcode |
| Profil nicht schreibbar | Warnung, Build bleibt erfolgreich, Exitcode unverändert |
| Ungültige Profiloption | CLI-Fehler vor der Kompilierung |
| SIGKILL / OOM | kein Bericht zugesichert, keine Serialisierung aus Signalhandlern |
| Mehrere Prozesse | unterschiedliche Pfade nötig; kein Merging |

## 6. Nachweis (vor einem PR)

- **Bitgleichheit am Erzeugnis**: SHA-256 des Compilats mit und ohne
  Schalter, für alle drei Level. Nicht „JSON-Datei ist entstanden" prüfen —
  ein Vorhandenseinstest ist blind.
- Fixpunkt gen2 == gen3, `make test` 0 FAIL, `make test-lyx` 0 unerwartet
  rot, `make test-lyx-integration`.
- Kein Seed-Neuanker nötig, solange der Codegen unberührt bleibt; wird
  `codegen_x86.lyx` doch angefasst, gilt `make singularity` (S3 == S4).
- Neue Suite ins `test`-Target bzw. `tests/suite-*.txt`, sonst meldet
  `test_coverage_test.sh`.
- **Beide Seiten messen**: der Filtertest muss zeigen, dass die gefilterten
  Ereignisse fehlen *und* `decision_summary` vollständig bleibt.
- Overhead: wiederholte Läufe mit `taskset`, Median, Streuung angeben.
  Kein Null-Overhead-Versprechen.
- Versionsbump (vier lebende Stellen), `ebnf.md` nur bei
  Grammatikänderung — hier keine.

## 7. Offene Fragen

1. Trägt `cg_vmErkennen` eine Quellzeile für `decisions[].location`? Die
   Stelle arbeitet auf AST-Knotenindizes (`cg_nkind`, `cg_nc0`), und
   `cg_lineOf` existiert — plausibel, aber nicht nachgemessen. Dasselbe für
   `ir_optimize` über `--ir-source-map`, dort auf IR-Index-Ebene.
2. Soll `ir-optimize` zugleich einen Span bekommen? Heute läuft es
   innerhalb von `codegen-*` ohne eigenen `_passStart`. Der Vektorisierer
   läuft ebenfalls innerhalb von `codegen-x86_64` (aus `cg_genWhile`), hat
   also keinen eigenen Span, nur den Zähler.
3. Schreibt `--build-info` einen Commit, der für `compiler.commit` taugt?
4. Bleibt `--time-trace` dauerhaft daneben stehen, oder wird es später
   als Ansicht auf denselben Puffer ausgedrückt?
5. `event_limit` 65536: Hausnummer. Am Selbstbau von `src/lyxc.lyx`
   nachmessen, wie viele Entscheidungen `ir_optimize` dort überhaupt fällt.

## 8. Ausdrücklich nicht im ersten Umfang

HTML-Ansicht, Trace-Export, Build-ID im Compilat, Multi-Prozess-Merging,
Allokator-Zähler, I/O-Zähler, kritischer Pfad, phasenbezogener Speicher,
Inlining-Entscheidungen (Pass nicht verdrahtet). Vektorisierungs- und
`ir_optimize`-Entscheidungen sind **enthalten** — sie sind der Grund, warum
`detailed` überhaupt etwas aussagt.

Nicht instrumentiert bleiben die Vektorwege der anderen Ziele: `cg_vmErkennen`
ist x86-spezifisch. Für arm64 und riscv steht `vectorize` auf `absent`, mit
`note`, dass es dort keinen solchen Pass gibt — nicht auf `not_instrumented`,
was eine vorhandene Stelle behaupten würde.
