# KI-Native Weiterentwicklung von Lyx – Fahrplan & Arbeitspakete

> **Dokumenttyp:** Strategie & Roadmap  
> **Bezug:** Ursprüngliches Konzeptpapier (ki-lang.md, v1) – "Lyx als AI-native Systems Programming Language"  
> **Stand:** 2026-05-31  
> **Autor:** Architekturanalyse auf Basis des Lyx-Projektstands v0.9.0A  
> **Revision:** v1.1 – WP1 auf reinen AST-Export eingegrenzt; AST-Rückkanal als eigenständiges WP5 ausgegliedert

---

## 1. Einordnung

Das ursprüngliche Dokument `ki-lang.md` hat fünf ambitionierte Thesen aufgestellt:

1. Eindeutige Grammatik (Context-Free Grammar)
2. Maschinenlesbare Semantik im Compiler (AST-Exposition)
3. Formale Verifikation im Typsystem (Dependent Types)
4. Compiler-Fehlermeldungen im LLM-Format
5. Native Unterstützung für Code-Dokumentation als "Prompt" (Contract/Intent)

Grundthese: **Lyx soll die erste "AI-native" Systems Programming Language werden.**

Die Analyse des aktuellen Projektstands (Compiler selbsthostend in Lyx, 7 Backends, DO-178C Safety-DNA, ~400 Tests, ~140 Stdlib-Module) zeigt:  
Lyx hat **ideale Voraussetzungen** – Pascal-artige Klarheit, Safety-Fokus, vollständige Eigenständigkeit.  
Aber nicht alle Vorschläge sind gleich prioritär oder gleich realistisch.

Dieses Dokument definiert einen **gestuften Fahrplan** mit sieben konkreten Arbeitspaketen (WPs), priorisiert nach:

> **KI-Nutzen × Machbarkeit × Menschlicher Nutzen**

---

## 2. Fahrplan-Übersicht

```
Meilenstein A (1–2 Monate)     │  Meilenstein B (3–6 Monate)    │  Meilenstein C (>12 Monate)
───────────────────────────────┼────────────────────────────────┼───────────────────────────────
WP1: --ast-json (Export)       │  WP3: Const Generics           │  WP6: Volles Dependent Typing
WP2: Strukturierte Error-Codes │  WP4: Contract-Attribute       │  WP7: 100% CFG Grammatik
  (--error-json)               │  WP5: AST-Rückkanal (JSON→AST) │
```

| Rang | Feature | Aufwand | KI-Nutzen | Menschen-Nutzen | Meilenstein |
|------|---------|---------|-----------|-----------------|-------------|
| 1 | `--ast-json` (Export) + `--error-json` | Gering | Sehr hoch | Mittel (Debugging) | A |
| 2 | Strukturierte Error-Codes in JSON | Gering | Hoch | Niedrig | A |
| 3 | Const Generics (`Array<T, N>`) | Mittel | Hoch | Hoch | B |
| 4 | Contract-Attribute (`@pre`/`@post`) | Mittel | Hoch | Mittel (Safety) | B |
| 5 | AST-Rückkanal (JSON → AST → Quelltext) | Mittel–Hoch | Hoch | Niedrig | B |
| 6 | Volles Dependent Typing | Sehr hoch | Mittel | Mittel | C |
| 7 | 100% CFG Grammatik | Niedrig | Gering | Negativ | C (nicht empfohlen) |

---

## 3. Arbeitspakete

---

### WP1: AST-Export via `--ast-json`

**Ziel:** Der Lyx-Compiler gibt den vollständigen Abstract Syntax Tree (AST) als maschinenlesbares JSON aus, sodass KI-Agenten die Baumstruktur und exakte Positionen kennen – ohne rohen Text parsen zu müssen.

> **Scope-Abgrenzung:** WP1 deckt ausschließlich den **Export** ab (Lyx → JSON). Der umgekehrte Pfad (JSON → AST → Quelltext) ist ein eigenständiges Problem mit erheblichem Zusatzaufwand (Kommentar-/Formatierungsverlust) und wird in WP5 behandelt.

**Wie KI-Agenten mit dem Export arbeiten (Interim-Ansatz):**  
Da WP1 keinen Rückkanal liefert, navigieren KI-Agenten über **Position-Guided Patching**: Der AST-JSON enthält für jeden Knoten exakte Positionsangaben (`file`, `line`, `col`, `endLine`, `endCol`). Der Agent identifiziert strukturell den zu ändernden Knoten und ersetzt präzise den entsprechenden Quelltextbereich in der `.lyx`-Datei. Alles außerhalb des Blocks (Kommentare, Formatierung) bleibt unberührt. Dieses Modell entspricht dem, was Claude Code, Copilot und vergleichbare Tools heute bereits verwenden – WP1 macht es strukturell präzise statt heuristisch.

**Motivation:**  
LLMs "raten" die Code-Struktur aus Text. Wenn der Compiler den AST mit vollständigen Positionen liefert, kann eine KI:
- den AST vor der Codegenerierung validieren
- Compiler-Feedback (s. WP2) direkt auf AST-Knoten abbilden
- Quelltextänderungen chirurgisch präzise auf den richtigen Block anwenden (Position-Guided Patching)

**Aufwand:** Gering (1–2 Wochen)

**Konkrete Aufgaben:**

| # | Aufgabe | Betroffene Dateien | Beschreibung |
|---|---------|-------------------|-------------|
| 1.1 | AST-JSON-Schema definieren | Neu: `ast-schema.json` | JSON-Schema (Draft 2020-12) für den AST. Enthält Knotentypen, Positionen (file/line/col/endLine/endCol), Typinformationen, Symbol-Referenzen. Wird auch als `$schema` im Output referenziert. |
| 1.2 | Serialisierungs-Pass schreiben | Neu in `src/backend/`: `ast_json.lyx` | Ein neuer Codegen-Durchlauf, der den AST aus `ir.lyx` in das JSON-Schema serialisiert. Jeder AST-Knoten erhält: `nodeType`, `pos`, `children`, `data`, `typeInfo`. |
| 1.3 | CLI-Flag `--ast-json` integrieren | `src/lyxc.lyx`, `src/codegen.lyx` | Neues Compiler-Flag. Aufruf: `lyxc --ast-json file.lyx`. Output auf stdout oder per `-o file.json`. |
| 1.4 | JSON-Ausgabe mit optionalem Pretty-Print | `src/backend/ast_json.lyx` | Flag `--ast-json-pretty` für menschenlesbare Formatierung (KI nutzt kompakte Form). |
| 1.5 | JSON-Schema in Compiler-Doku veröffentlichen | `COMPILER_MANUAL.md` | Schema dokumentieren, Beispiel-Output zeigen. Position-Guided-Patching-Workflow erklären. |
| 1.6 | Test: AST-JSON-Validität | `tests/compiler/` | `lyxc --ast-json file.lyx` für alle Test-Quelltexte ausführen und Output gegen das JSON-Schema validieren. Positionsangaben stichprobenartig gegen Quelltextzeilen prüfen. |

**Akzeptanzkriterien:**
- `lyxc --ast-json hello.lyx` gibt gültiges JSON gemäß Schema aus
- Das JSON-Schema validiert alle AST-Knotentypen des aktuellen Sprachumfangs
- Jeder AST-Knoten enthält vollständige Positionsangaben (file/line/col/endLine/endCol)
- Der Output ist **stabil** (Breaking Changes nur mit Versionssprung)
- Laufzeit-Overhead < 10 % der normalen Compile-Zeit

**Abhängigkeiten:** Keine

---

### WP2: Strukturierte Error-Codes & `--error-json`

**Ziel:** Compiler-Fehlermeldungen werden als strukturiertes JSON ausgegeben, mit Fehler-ID, Scope (welcher AST-Knoten), erwartetem vs. tatsächlichem Zustand und den letzten erfolgreichen Compiler-Schritten.

**Motivation:**  
KI-Agenten in einem "Agentic Loop" müssen Fehler schnell verstehen und korrigieren können. Unformatierter Text wie `Error: Unexpected token at line 42` zwingt die KI zum Raten. Strukturierte Metadaten erlauben gezielte Quelltextänderungen via Position-Guided Patching (WP1) ohne erneutes Voll-Parsing.

**Aufwand:** Gering (1–2 Wochen)

**Konkrete Aufgaben:**

| # | Aufgabe | Betroffene Dateien | Beschreibung |
|---|---------|-------------------|-------------|
| 2.1 | Fehler-Katalog definieren | Neu: `doc/error-codes.md` | Jeder Compiler-Fehler erhält eine eindeutige ID (z. B. `LYX-E0001`), eine Kategorie (Parser, Sema, Codegen, Safety, IO), einen Schweregrad (Error/Warning/Note) und eine strukturierte Beschreibung. |
| 2.2 | Error-JSON-Schema definieren | Neu: `error-schema.json` | Felder: `errorId`, `category`, `severity`, `message`, `locations[]` (file, line, col, length), `expected`, `actual`, `suggestion`, `astPath` (Pfad zum betroffenen AST-Knoten aus WP1), `compilerSteps` (letzte 5 erfolgreiche Schritte). |
| 2.3 | Error-Collector in Sema/Parser integrieren | `src/sema.lyx`, `src/parser.lyx`, `src/codegen.lyx` | Fehlerausgabe wird zentral über eine neue `ErrorCollector`-Struktur geleitet. Diese sammelt alle Fehler und kann sie entweder als Text (wie bisher) oder als JSON (bei `--error-json`) ausgeben. |
| 2.4 | CLI-Flag `--error-json` integrieren | `src/lyxc.lyx` | Aktiviert JSON-Ausgabe. Kombinierbar mit `--ast-json`: KI bekommt AST + Fehlerreport in einem Aufruf. |
| 2.5 | `astPath`-Tracking im Parser | `src/parser.lyx` | Jeder AST-Knoten erhält beim Erzeugen seine Parent-Referenz (oder einen Pfad-String). Fehlerreferenzen nutzen diesen Pfad. Implementiert intern in WP2 – nutzt die Positionsdaten aus WP1, ist aber kein Blocker für WP1. |
| 2.6 | Bestehende Fehler migrieren | Alle Fehlerstellen | Alle bestehenden `panic`/`Error`/`Warn`-Aufrufe werden auf den ErrorCollector umgestellt. |
| 2.7 | Tests: JSON-Fehlerausgabe | `tests/compiler/` | Für jede Fehlerkategorie wird getestet: `lyxc --error-json faulty.lyx` produziert valides JSON mit korrekter `errorId`. |

**Akzeptanzkriterien:**
- Alle bisherigen Fehler (Parser, Sema, Codegen) sind im Katalog erfasst
- `lyxc --error-json faulty.lyx` gibt ausschließlich JSON auf stdout aus
- Kein Informationsverlust gegenüber Text-Output
- `astPath` ist für > 95 % der Fehler gesetzt

**Abhängigkeiten:** WP1 (Positionsdaten als Basis für `astPath`; WP2 kann aber parallel gestartet werden, `astPath` ist intern in WP2 implementiert)

---

### WP3: Const Generics (`Array<T, N>`)

**Ziel:** Einführung von Const Generic Parameters, insbesondere für Array-Längen: `Array<T, N: con usize>`. Damit wird `Array<Int, 5>` zu einem vom Compiler geprüften Typ, der Index-Fehler bereits zur Compile-Zeit abfängt.

**Motivation (KI):**  
Wenn eine KI eine Funktion `sort(a: Array<Int, 5>)` generiert und versehentlich `Array<Int, 6>` übergibt, gibt es sofort einen Compiler-Fehler – mit klarer Ursache (Typ mismatch). Ohne Const Generics würde der Fehler erst zur Laufzeit als Buffer Overflow auffliegen.

**Motivation (Mensch):**  
Selber Effekt – das Typsystem wird ausdrucksstärker und fängt ganze Fehlerklassen statisch ab.  
Lyx hat mit `con` (Compile-Time Constant) und `dim`/`utype` (Dimensional Analysis) bereits ein starkes Fundament.

**Aufwand:** Mittel (3–5 Wochen)

**Konkrete Aufgaben:**

| # | Aufgabe | Betroffene Dateien | Beschreibung |
|---|---------|-------------------|-------------|
| 3.1 | EBNF-Erweiterung für Const Generic Parameter | `ebnf.md` | Neues Grammatik-Regel: `TypeParamDecl → Ident ':' 'con' Type`. Const-Generics sind auf Integer-Typen und `bool` beschränkt. |
| 3.2 | Const Generic Deklaration im Parser | `src/parser.lyx` | Parsen von `fn foo(a: Array<Int, N: con usize>)` und `type MyArr = Array<Int, 5>`. |
| 3.3 | Const Generic Evaluation im Typsystem | `src/sema.lyx` | Const-Ausdrücke werden bei der Monomorphisierung ausgewertet. Typgleichheit wird über den Wert (nicht die Variable) bestimmt: `Array<Int, 5>` ist identisch zu `Array<Int, 2+3>`. |
| 3.4 | Array-Typ-Erweiterung auf Const-Länge | `src/ir.lyx`, `src/codegen.lyx` | `Array<T, N>` wird zu einem vollwertigen Typen mit bekannter Länge im IR. Der Codegen allokiert statisch (Stack) statt dynamisch (Heap), wenn die Länge bekannt ist. |
| 3.5 | Bounds-Check-Optimierung | `src/ir_optimize.lyx` | Bei statisch bekannten Array-Längen können Index-Prüfen zur Compile-Zeit aufgelöst werden (eliminiert für gültige Indizes, garantiert Fehler für ungültige). |
| 3.6 | Stdlib-Integration | `std/vector.lyx`, `std/array.lyx` | Ein neues `Array<T, N>` als Builtin-Typ (analog zu `array[T]`). Vector wird dahingehend erweitert, dass er optional mit fester Länge arbeitet. |
| 3.7 | Fehlermeldungen für Const-Mismatch (WP2) | Error-Codes | Neue Error-Codes: `LYX-T0301` (const type mismatch), `LYX-T0302` (const value out of range). |
| 3.8 | AST-JSON-Erweiterung (WP1) | `src/backend/ast_json.lyx` | Const Generic Parameter werden im AST-JSON abgebildet. |

**Akzeptanzkriterien:**
- `Array<Int, 5>` und `Array<Int, 6>` sind unterschiedliche Typen (Compile-Fehler bei Zuweisung)
- `Array<Int, 5>` allokiert auf dem Stack (keine Heap-Allokation)
- Const-Ausdrücke werden korrekt ausgewertet (`Array<Int, 2+3>` ≡ `Array<Int, 5>`)
- Bestehende `Array<T>` (dynamisch) bleibt unverändert funktionsfähig
- Volle Kompatibilität mit bestehenden Regression-Tests

**Abhängigkeiten:** WP1 (AST-JSON), WP2 (Error-Codes)

---

### WP4: Contract-Attribute (`@pre`/`@post`)

**Ziel:** Einführung von optionalen Precondition-/Postcondition-Prüfungen als Compiler-Attribute. Funktionen können mit `@pre(condition)` und `@post(condition)` annotiert werden. Der Compiler generiert Laufzeit-Prüfungen (optional, per Compiler-Flag steuerbar) und dokumentiert die Contracts im AST-JSON (WP1).

**Motivation (KI):**  
Ein LLM, das eine Funktion mit `@pre(x > 0)` und `@post(result != null)` generiert, hat einen expliziten Vertrag, gegen den der generierte Code geprüft wird. Der Compiler bestraft Vertragsverletzungen sofort – das trainiert die KI, korrektere Verträge zu generieren.

**Motivation (Mensch):**  
Design-by-Contract (DbC) ist eine bewährte Methode für Safety-Critical Software (Ada/SPARK, Eiffel). Lyx hat mit `@dal`, `@integrity`, `@wcet` bereits ein Attribut-System für Safety – Contracts fügen sich nahtlos ein.

**Aufwand:** Mittel (3–4 Wochen)

**Hinweis zur Implementierung von `@post`:**  
Der Bezeichner `result` in Postconditions muss vor dem `return`-Statement gebunden werden. Der Codegen fügt implizit eine temporäre Variable ein, die den Rückgabewert hält, bevor der Post-Check ausgeführt wird. Dieses Binding muss in Task 4.4 explizit implementiert werden.

**Konkrete Aufgaben:**

| # | Aufgabe | Betroffene Dateien | Beschreibung |
|---|---------|-------------------|-------------|
| 4.1 | EBNF-Erweiterung für Contract-Attribute | `ebnf.md` | Zwei neue Funktions-Attribute: `@pre(expression)` und `@post(expression)`. Die Expressions sind boolesche Ausdrücke, die auf die Parameter (`param`) und den Rückgabewert (`result`) zugreifen können. |
| 4.2 | Contract-Parsing im Parser | `src/parser.lyx` | `@pre`/`@post` werden als Funktions-Attribute geparst und im AST abgelegt. |
| 4.3 | Contract-Validation im Typsystem | `src/sema.lyx` | Prüfung: Contract-Ausdrücke sind boolesch, referenzieren nur erlaubte Symbole (`param`, `result`), keine Seiteneffekte. |
| 4.4 | IR-Generierung für Contract-Checks | `src/ir.lyx`, `src/codegen.lyx` | Bei aktiviertem `--contracts`: Pre-Checks vor dem Funktionskörper, Post-Checks über eine implizite `result`-Variable vor jedem `return`. Generiert `if (not condition) panic("Contract violation: ...")`. |
| 4.5 | Compiler-Flag `--contracts` | `src/lyxc.lyx` | Drei Modi: `off` (keine Checks), `check` (Laufzeit-Checks), `enforce` (Checks + Optimierungshinweise für den Compiler). Default: `off`. |
| 4.6 | Contract-basierte Optimierung | `src/ir_optimize.lyx` | In `enforce`-Modus können Preconditions als Known-Values in die Optimierung einfließen (z. B. Division durch Null-Prüfung eliminieren, wenn `@pre(y != 0)` gesetzt ist). |
| 4.7 | Contract-Information in AST-JSON (WP1) | `src/backend/ast_json.lyx` | Contracts werden als `contracts`-Feld im Funktions-AST abgebildet. |
| 4.8 | Error-Codes für Contract-Verletzung (WP2) | Error-Codes | Neue Error-Codes: `LYX-C0401` (precondition violation), `LYX-C0402` (postcondition violation). |
| 4.9 | Stdlib-Beispiele | `examples/basics/` | Ein Beispiel `contracts.lyx` zeigt die Nutzung. |

**Akzeptanzkriterien:**
- `@pre(x > 0)` und `@post(result != null)` werden korrekt geparst und validiert
- `lyxc --contracts=check` generiert Laufzeit-Prüfungen
- `lyxc --contracts=off` erzeugt keinen Code-Overhead (Zero-Cost-Abstraktion)
- Contract-Verletzungen geben einen klaren Fehler mit Funktionsname, Contract und Werten aus
- Contracts sind im AST-JSON sichtbar

**Abhängigkeiten:** WP1 (AST-JSON), WP2 (Error-Codes)

---

### WP5: AST-Rückkanal (JSON → AST → Quelltext)

**Ziel:** Einführung eines bidirektionalen AST-Kanals: Ein KI-Agent kann einen modifizierten AST-JSON an den Compiler übergeben, der daraus validen Lyx-Quelltext regeneriert. Zusammen mit WP1 entsteht ein vollständiger AST-Edit-Zyklus ohne direkten Quelltextzugriff.

**Warum nicht in WP1:**  
Der Export (WP1) ist einfach und verlustfrei. Der Rückkanal ist aufwändiger und hat einen fundamentalen Trade-off: Kommentare, Leerzeilen und Einrückungsentscheidungen existieren nicht im AST und gehen beim Rückweg verloren. Der Unparser produziert immer kanonisch formatierten Code – das Original ist faktisch nicht rekonstruierbar. Dieser Trade-off muss bewusst akzeptiert werden, bevor der Rückkanal implementiert wird.

**Interim-Ansatz bis WP5 abgeschlossen ist:**  
KI-Agenten nutzen Position-Guided Patching (siehe WP1): Der AST-JSON liefert exakte Quelltextpositionen, der Agent ersetzt chirurgisch den entsprechenden Textblock. Kommentare und Formatierung außerhalb des Blocks bleiben erhalten. Dieser Ansatz deckt den Großteil der Praxisfälle ab.

**Aufwand:** Mittel–Hoch (4–6 Wochen)

**Konkrete Aufgaben:**

| # | Aufgabe | Betroffene Dateien | Beschreibung |
|---|---------|-------------------|-------------|
| 5.1 | JSON-Deserialisierer für AST-Knoten | Neu: `src/backend/ast_json_reader.lyx` | Liest einen modifizierten AST-JSON und rekonstruiert die interne AST-Struktur. Validierung gegen das JSON-Schema (WP1). |
| 5.2 | Lyx-Unparser / Pretty-Printer | Neu: `src/backend/lyx_unparse.lyx` | Serialisiert den AST zurück in validen Lyx-Quelltext. Kanonische Formatierung (kein Erhalt von Originalformatierung). Unterstützt alle Sprachkonstrukte des aktuellen Sprachumfangs. |
| 5.3 | CLI-Flag `--from-ast-json` | `src/lyxc.lyx` | `lyxc --from-ast-json modified.json -o output.lyx` – regeneriert Quelltext aus AST-JSON. |
| 5.4 | Kommentar-Strategie definieren | Designdokument | Entscheidung vor Implementierungsbeginn: (a) Kommentare komplett verwerfen (einfach), (b) Kommentare als Metadaten-Felder im AST-JSON erhalten (aufwändig). |
| 5.5 | Roundtrip-Stabilitätstest | `tests/compiler/` | `lyx → ast-json → lyx (unparse) → ast-json` muss strukturell identische ASTs produzieren. Kommentare sind explizit ausgenommen (je nach Ergebnis von 5.4). |
| 5.6 | Integration mit Sema-Validation | `src/sema.lyx` | Der aus JSON regenerierte AST durchläuft den vollen Sema-Pass, bevor Quelltext ausgegeben wird. Ungültige AST-Modifikationen werden mit Error-Codes (WP2) gemeldet. |

**Akzeptanzkriterien:**
- `lyxc --from-ast-json modified.json -o out.lyx` produziert kompilierbaren Lyx-Quelltext
- Roundtrip `lyx → ast-json → lyx` ist strukturell stabil (Semantik erhalten)
- Ungültige AST-JSONs werden mit klaren Fehlermeldungen (WP2) abgelehnt
- Kommentar-Strategie ist dokumentiert und umgesetzt
- Laufzeit-Overhead < 20 % gegenüber normalem Compile

**Abhängigkeiten:** WP1 (AST-JSON-Schema und Export als Basis), WP2 (Error-Codes für Validierungsfehler)

---

### WP6: Volles Dependent Typing (Langfristvision)

**Ziel:** Erweiterung des Typsystems auf vollwertige Dependent Types (Wert-abhängige Typen, proof-irrelevante Constraints). Eine Funktion kann ausdrücken: `fn safe_div(a: Int, b: Int { b != 0 }) -> Int { result != 0 }`.

**Motivation:**  
Das ultimative Werkzeug gegen KI-Halluzination: Alle Invarianten werden formal im Typ kodiert und vom Compiler geprüft. Eine KI kann keine Index Out of Bounds, Null-Pointer oder Division-by-Zero mehr generieren, ohne dass der Compiler sofort anschlägt.

**Warum Langfristvision (> 12 Monate):**  

| Aspekt | Begründung |
|--------|-----------|
| **Compiler-Komplexität** | Dependent Types erfordern einen Proof-Checking-Mechanismus im Typsystem. Der gesamte Sema-Pass müsste grundlegend überarbeitet werden. |
| **Monomorphisierung** | Lyx verwendet monomorphisiert Generics. Dependent Types erzeugen potentiell unendlich viele Typ-Instanzen – das bricht das aktuelle Monomorphisierungs-Modell. |
| **Laufzeit-Modell** | Typ-Informationen, die Werte abbilden, müssen in das IR und den Codegen propagiert werden. Das ist ein massiver Eingriff. |
| **Ökosystem-Reife** | Lyx sollte erst WP1–WP5 abgeschlossen haben, bevor eine derart fundamentale Erweiterung angegangen wird. |
| **Menschliche Komplexität** | Dependent Types sind selbst für erfahrene Entwickler schwer zu lesen/schreiben. Lyx würde seine Zugänglichkeit einbüßen. |

**Konkrete Aufgaben (Vorphase):**

| # | Aufgabe | Beschreibung |
|---|---------|-------------|
| 6.1 | Proof-of-Concept | Ein Mini-Compiler in Lyx, der für eine eingeschränkte Subsprache Dependent Types implementiert. Dient als Machbarkeitsstudie. |
| 6.2 | Literaturrecherche | Analyse von Idris, Coq, F*, Liquid Haskell, Ada/SPARK. Welche Konzepte sind für Lyx adaptierbar? |
| 6.3 | Spezifikation | Sprachspezifikation für Dependent Types in Lyx. Wie tief soll die Integration gehen? (Z. B. nur reine Constraints vs. vollwertige Pi-Typen). |
| 6.4 | Impact-Analyse | Welche Änderungen an Parser, Sema, IR, Codegen, Optimierung sind nötig? |
| 6.5 | Entscheidungsdokument | Finale Empfehlung: Dependent Types vollständig oder in abgespeckter Form (Liquid Types/Refinement Types)? |

**Akzeptanzkriterien (für die Vorphase):**
- Machbarkeits-POC existiert und compiliert
- Spezifikationsdokument liegt vor
- Entscheidung: Volles Dependent Typing vs. Refinement Types

**Abhängigkeiten:** WP1, WP2, WP3 (Const Generics sind ein notwendiger Vorläufer), WP4, WP5

---

### WP7: 100% CFG Grammatik (Nicht empfohlen)

**Ziel:** Elimination aller kontextabhängigen Grammatik-Elemente, sodass die gesamte Sprache mit einer reinen Kontextfreien Grammatik (CFG) beschreibbar ist.

**Bewertung aus dem ursprünglichen Dokument:**  
> "Eine absolut strikte, mathematisch eindeutige Grammatik"

**Analyse:**

| Aktuelle kontextabhängige Elemente in Lyx | Bewertung |
|--------------------------------------------|-----------|
| Soft Keywords (`range`, `wraps`, `defer`) | Könnten eliminiert werden (Reserved Keywords), aber das bricht bestehenden Code. Nutzen für KI: minimal – aktuelle LLMs kommen mit Soft Keywords klar. |
| Typ-Inferenz (`var x = ...`) | Streng genommen kontextabhängig (der Typ wird aus dem Kontext erschlossen). Aber: keine CFG-Leistung – der Parser produziert trotzdem einen eindeutigen AST. Typprüfung ist Sema, nicht Parser. |
| Operator Overloading (geplant) | Könnte zu Mehrdeutigkeiten führen. Aber: Lyx hat kein Operator Overloading und wird es nach aktueller Planung auch nicht bekommen. |
| `dim`/`utype` Dimensional Analysis | Ist Typsystem-Ebene, nicht Grammatik. Kein Problem für CFG. |

**Fazit:**  
Die Lyx-Grammatik **ist bereits zu > 95 % CFG-kompatibel**. Der Aufwand, die restlichen < 5 % zu eliminieren, wäre gering – aber der Nutzen für KI-Modelle ist **marginal bis negativ**:

- Aktuelle LLMs (GPT-4, Claude, etc.) haben keinerlei Probleme mit Lyx' Soft Keywords.  
- Die Umstellung auf Reserved Keywords würde **allen existierenden Lyx-Code brechen** (einschließlich des Compilers selbst).  
- Eine 100% CFG zwingt zu umständlichen syntaktischen Konstrukten, die von Menschen als "overly verbose" empfunden würden – das schadet der Adoption.

**Empfehlung:** **Nicht umsetzen.** Die aktuelle Grammatik ist bereits KI-freundlich genug.  
Das Team soll sich auf WP1–WP5 konzentrieren, die echten Mehrwert liefern.

---

## 4. Abhängigkeitsgraph der Arbeitspakete

```
WP1 (AST-Export) ────────────────────────────────────────┐
      │                                                   │
      ├── WP2 (Error-Codes) ──── astPath intern in WP2 ───┤
      │                                                   │
      ├── WP3 (Const Generics) ──── hängt von WP1 ────────┤
      │                                                   ├── WP6 (Dependent Types)
      ├── WP4 (Contracts) ──── hängt von WP1, WP2 ────────┤
      │                                                   │
      └── WP5 (AST-Rückkanal) ── hängt von WP1, WP2 ─────┘

WP7 (100% CFG) ───→ Nicht empfohlen, kein direkter Nutzen
```

**Parallele Bearbeitung:**
- WP1 und WP2 können parallel gestartet werden (WP2 benötigt nur das Positionsschema aus WP1, der `astPath` ist intern)
- WP3 kann nach Abschluss von WP1 begonnen werden
- WP4 kann nach Abschluss von WP1 + WP2 begonnen werden
- WP5 kann parallel zu WP3/WP4 begonnen werden (nach WP1 + WP2)
- WP6 frühestens nach WP3 + WP4 + WP5

---

## 5. Zeitplan (Schätzung)

| WP | Feature | Aufwand (Mann-Wochen) | Start (relativ) | Dauer |
|----|---------|----------------------|-----------------|-------|
| 1 | `--ast-json` (Export) | 2 MW | Monat 1 | 2 Wochen |
| 2 | `--error-json` + Error-Codes | 2 MW | Monat 1 | 2 Wochen |
| 3 | Const Generics | 4 MW | Monat 2 | 4 Wochen |
| 4 | Contract-Attribute | 3 MW | Monat 2–3 | 3 Wochen |
| 5 | AST-Rückkanal (JSON → AST) | 5 MW | Monat 3–4 | 5 Wochen |
| 6 | Dependent Types (Vorphase) | 4 MW | Monat 7 | 4 Wochen (Research) |
| 7 | 100% CFG | – | – | *Nicht empfohlen* |

**Kritischer Pfad:** WP1 → WP2 → WP4 → WP5 → WP6  
**Parallele Spur:** WP1 → WP3  
**Gesamtdauer WP1–WP5:** ca. **4–5 Monate** bei voller Teamkapazität (1–2 Entwickler)

---

## 6. Risiken & Annahmen

| Risiko | Eintrittswahrsch. | Impact | Maßnahme |
|--------|-------------------|--------|----------|
| AST-JSON wird zu groß (> 10 MB für große Dateien) | Mittel | Niedrig | Optionale Filter (`--ast-json-scope`: `types`, `functions`, `all`); Streaming-Output |
| Const Generics führen zu langen Compile-Zeiten | Mittel | Mittel | Monomorphisierungs-Caching; Limits für const-Ausdrücke |
| Contract-Checks verlangsamen Safety-Critical Code | Niedrig | Hoch | Default `--contracts=off`; Zero-Cost-Garantie im Safety-Modus |
| AST-Rückkanal: Kommentar-/Formatierungsverlust wird als Breaking Change wahrgenommen | Hoch | Mittel | Kommentar-Strategie vor WP5-Start festlegen (Task 5.4); klare Dokumentation des Trade-offs |
| AST-Rückkanal: Ungültige KI-generierte AST-JSONs destabilisieren den Compiler | Mittel | Hoch | Vollständige Sema-Validation vor Quelltext-Ausgabe (Task 5.6) |
| Dependent Types sind nicht mit Monomorphisierung vereinbar | Hoch | Sehr hoch | Deshalb WP6 als Langfrist-Vorphase; ggf. Refinement Types als Alternative |
| LLMs ignorieren die neuen Formate | Mittel | Mittel | Community-Arbeit: Beispiel-Prompts, OpenAI/GitHub Copilot-Integrationen, Open-Source-Agent-Framework |

---

## 7. Messbarkeit & Erfolgskriterien

### Quantitative Metriken

| Metrik | WP | Zielwert | Messung |
|--------|----|----------|---------|
| KI-generierte Lyx-Code-Pass-Rate | 1, 2 | > 90 % | Benchmark-Suite mit 100 typischen KI-Codegen-Aufgaben |
| Compiler-Fehler ohne `astPath` | 2 | < 5 % | Statistische Auswertung der Error-JSONs |
| Const-Mismatch-Fehler zur Compile-Zeit statt Runtime | 3 | 100 % | Regression-Tests mit bekannten Out-of-Bounds-Fällen |
| Contract-Overhead im Safety-Mode | 4 | 0 % (Zero-Cost) | Compiler-Output-Vergleich mit/ohne Contracts |
| AST-Roundtrip-Stabilität (Semantik) | 5 | 100 % | Automatisierter Roundtrip-Test über alle Stdlib-Module |
| Anzahl LLMs mit nativer Lyx-Unterstützung | alle | ≥ 3 (GPT, Claude, CodeGemma) | Beobachtung der Modelle/Finetunes |

### Qualitative Erfolgskriterien

- Ein KI-Agent (z. B. Claude Code, GPT Engineer) kann **ohne menschliches Eingreifen** ein vollständiges Lyx-Programm generieren, compilieren und ausführen – allein durch Iteration über `--ast-json` + `--error-json` + Position-Guided Patching (WP1–WP2).
- Nach WP5: Ein KI-Agent kann AST-Knoten direkt modifizieren und regenerierten Quelltext vom Compiler validieren lassen – ohne Quelltextzugriff.
- Die **Error-JSON-Schnittstelle** ermöglicht einem LLM, > 90 % der Compiler-Fehler automatisiert zu korrigieren (gemessen an einem Korpus von 100 fehlerhaften Programmen).

---

## 8. Zusammenfassung

Das ursprüngliche Konzeptpapier hatte eine klare Vision: **Lyx als erste AI-native Systems Programming Language**.  
Dieser Fahrplan operationalisiert diese Vision in sieben Arbeitspaketen, priorisiert nach Machbarkeit und Nutzen.

### Die vier strategischen Empfehlungen

1. **Sofort starten: WP1 + WP2** – AST-Export und strukturierte Error-Codes sind der Game Changer.  
   WP1 liefert zunächst nur den Export (Lyx → JSON). KI-Agenten nutzen den AST zur strukturellen Navigation und führen Änderungen über **Position-Guided Patching** durch – chirurgisch präzise, ohne die Originalformatierung zu zerstören.  
   Das macht Lyx zur **einzigen Systems Language mit einer nativen KI-Compiler-API**.

2. **Kurzfristig umsetzen: WP3 + WP4** – Const Generics und Contracts erweitern das Typsystem  
   so, dass KI-Halluzinationen **bereits zur Compile-Zeit** abgefangen werden.  
   Das ist der Schritt von "KI kann Lyx-Code generieren" zu "KI generiert korrekten Lyx-Code".

3. **Mittelfristig umsetzen: WP5** – Der AST-Rückkanal schließt den Edit-Zyklus und erlaubt direkte AST-Manipulation. Erst nach WP1–WP2 beginnen; den Kommentar-Trade-off vor Start bewusst entscheiden.

4. **Langfristig prüfen: WP6** – Dependent Types sind das wissenschaftliche Fernziel,  
   aber kein kurzfristiges Produkt-Feature. Erst WP1–WP5 abschließen, dann evaluieren.

**WP7 (100% CFG) wird nicht empfohlen.** Die Lyx-Grammatik ist bereits KI-freundlich genug.  
Die Ressourcen sind besser in WP1–WP5 investiert.

---

> **Fazit:** Lyx hat das Potenzial, die **erste Sprache zu werden, die nicht nur für Menschen, sondern auch für KIs designt ist** – mit einer Compiler-API, die KI-Agenten direkt auf dem AST navigieren lässt, und einem Typsystem, das KI-Halluzinationen bereits beim Kompilieren abfängt.  
>  
> Dieser Fahrplan zeigt den Weg dorthin – in messbaren, realistischen Schritten.
