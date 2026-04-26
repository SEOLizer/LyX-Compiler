# Aurum Compiler — Verbesserungsvorschläge

## P0 — Kritisch (Correctness-Bugs, stille Fehler)

### 1. Single-Pass Sema mit `atUnresolved` als Fallback (`sema.pas:2557`)
`atUnresolved` ist mit allem kompatibel und propagiert still durch das gesamte Typsystem (100+ Stellen). Typfehler werden dadurch erst beim Codegen sichtbar, nicht beim semantischen Check.

**Fix:** Zwei-Pass-Sema — Pass 1 registriert alle Typen/Funktionen, Pass 2 prüft Ausdrücke. Expliziter "forward reference forbidden"-Modus für strengere Prüfung.

---

### 2. CSE-Implementierung erzeugt ungültiges IR (`ir_optimize.pas:584`)
Wenn Common Subexpression Elimination eine redundante Instruktion findet, ersetzt sie diese durch:
```pascal
func.Instructions[i].Op := irAdd;  // Will be replaced
func.Instructions[i].Src2 := -1;   // Mark as copy
```
`Src2 = -1` ist kein gültiger Temp-Index. Wenn der Backend-Emitter diese Instruktion sieht, kann er falschen Assembly-Code oder einen Crash produzieren. Der Kommentar "Will be replaced" deutet auf einen fehlenden zweiten Pass hin, der nie implementiert wurde.

**Fix:** Redundante Instruktion direkt durch `irMove Dest, prevDest` ersetzen — kein zweistufiges Markierungsprotokoll.

---

### 3. Halb-fertige Features mit `aerospace-todo` (~25 Tags)
Mehrere Features sind nur geparst, aber nicht bis zum IR durchgezogen:
- `@integrity` (P0 #43) — geparsed, nicht gesenkt
- Endianness (`P2 #52`) — `FPendingEndian` gesetzt, im IR nie verwendet
- `flat struct` (`P2 #57`) — Flag vorhanden, keine Validierung/Codegen
- Range-Checks (`P1 #7`) — IR emittiert Checks, aber keine Optimierung

**Fix:** Feature end-to-end fertigstellen bevor nächstes begonnen wird. Compile-time-Assertions für `@integrity` in `sema.pas:3338` ergänzen.

---

## P1 — Hoch (Wartbarkeit, Fehlermeldungsqualität, Refactoring-Sicherheit)

### 4. ✅ Kein Control Flow Graph im IR (kein CFG, kein SSA)
> **Erledigt** — Branch `fix/cfg-ir`

Das IR ist ein flaches Instruction-Array ohne Basic Blocks, Dominanz-Analyse oder Phi-Knoten. Alle Optimierungen in `ir_optimize.pas` arbeiten deshalb mit heuristischen Line-by-Line-Scans statt auf echten Datenfluss-Informationen. Loop Invariant Code Motion, echtes Liveness-Tracking und sichere Registerallokation sind strukturell unmöglich.

**Fix:** Minimaler Schritt: Instructions in Basic Blocks gruppieren (`TBasicBlock` mit expliziten Successors/Predecessors). Kein volles SSA nötig — schon das öffnet korrekte Dataflow-Analysen.

---

### 5. ✅ Monolithischer Lowering-Pass (`lower_ast_to_ir.pas` — 7.576 Zeilen, 221 Prozeduren)
> **Erledigt** — Branch `fix/lower-split`

Eine einzige gigantische `LowerExpr`/`LowerStmt`-Funktion mit massivem Case-Statement. SIMD, Generics, Range-Checks, Ausdrücke und Statements sind ungetrennt. Änderungen pflanzen sich überall fort.

**Fix:** Aufteilen in separate Module:
- `lower_expr.inc`
- `lower_simd.inc`
- `lower_generics.inc`
- `lower_range_checks.inc`

---

### 6. ✅ Duplizierte Typ-Logik in drei Schichten
> **Erledigt** — Branch `fix/type-utils`

Parser, Sema und Lowering implementieren `ResolveTypeAlias()`, `TypeEqual()`, `TypeSizeBytes()` jeweils unabhängig. Ein Bugfix in einer Schicht erreicht die anderen nicht, was zu Inkonsistenz zwischen Sema und Codegen führt.

**Fix:** Gemeinsame `type_utils.pas` mit geteilter Logik für alle drei Schichten.

---

### 7. ✅ Fehlende Error Recovery im Parser (`parser.pas:128`)
> **Erledigt** — Branch `fix/parser-error-recovery`

Bei unerwartetem Token: einmaliges `Advance`, kein Resynchronisations-Punkt. Eine fehlende geschweifte Klammer produziert 50+ Folgefehler und macht Fehlermeldungen unbrauchbar.

**Fix:** Panic-Recovery bis zum nächsten Semikolon oder Block-Begrenzer. Fehlerzähler mit Schwellwert zur Unterdrückung von Folgefehlern.

---

### 8. ✅ 53 Seitenkanal-Felder als globaler Parser-State (`parser.pas`)
> **Erledigt** — Branch `fix/parser-sidechannels`

`FLastElemType`, `FLastKeyType`, `FLastValType`, `FLastElemTypeName`, `FPendingEndian`, `FNoStructLit`, `FLastParamListVarArgs` u.a. — 53 Stellen laut Grep. Diese werden als implizite Rückgabewerte von `ParseTypeExFull` und verwandten Funktionen missbraucht, weil Pascal keine Mehrfach-Rückgabewerte hat. Die Aufruf-Reihenfolge wird damit zu einem impliziten, undokumentierten Protokoll.

**Fix:** `TTypeResult = record ElemType, KeyType, ValType: TAurumType; ElemTypeName: string; ... end` als explizites Rückgabe-Record aus `ParseTypeExFull`.

---

### 9. Test-Abdeckung dünn und nicht automatisiert
28 Kategorien in `tests/lyx/`, aber nur 1 Shell-Skript in `tests/integration/` (`test_int_widths.sh`). Die Compiler-Unit-Tests in `compiler/tests/` sind eigenständige Pascal-Programme ohne gemeinsamen Test-Runner. Kein Differenz-Test gegen erwarteten IR-Output oder erwartete Fehlermeldungen. Ohne automatisierte Tests ist jedes der P1/P2-Refactorings unten riskant.

**Fix:** Snapshot-basiertes Test-Framework: Jeder `.lyx`-Test hat eine `.expected`-Datei (stdout + exit code). `make test` kompiliert alle und vergleicht mit `diff`. Neue Tests: einfach `.lyx` + `.expected` ablegen.

---

## P2 — Mittel (Technische Schulden, Performance, Memory-Safety)

### 10. ✅ `TIRInstr` ist ein Fat Record (~20 Felder, meist ungenutzt) (`ir.pas:114`)
> **Erledigt** — Branch `fix/ir-lean-instr`

Jede Instruktion trägt alle Felder aller Opcodes: `ArgTemps`, `InspectFieldNames`, `InspectFieldOffsets`, `CastFromType`, `StructSize`, `VMTIndex` usw. Pro Opcode sind maximal 20–30% der Felder belegt. Das verschwendet Speicher und Cache-Lines für jede Instruktion in langen Funktionen.

**Fix:** 8 tote/redundante Felder entfernt (`SourceSpan`, `IRID`, `EnergyCostHint`, `InspectType`, `InspectStructName`, `InspectFieldNames[]`, `InspectFieldTypes[]`, `InspectFieldOffsets[]`) — ~68 Bytes pro Instruktion gespart, 5 Managed-Type-Referenzen eliminiert.

---

### 11. ✅ O(n²) CSE-Algorithmus (`ir_optimize.pas:547`)
> **Erledigt** — Branch `fix/cse-hash`

`FindRedundantInstruction` scannt für jede Instruktion rückwärts durch alle vorherigen — O(n²) pro Funktion. Außerdem matcht `GetInstructionSignature` nur auf Basis von Temp-Indices (`Format('%d:%d:%d', [Ord(Op), Src1, Src2])`) — ohne Wertpropagation werden nur identische Temps erkannt, nicht identische Werte.

**Fix:** Hash-Map `sig -> dest-Temp` statt linearem Scan. Signature nach konstantem Wert statt Temp-Index (nach Copy-Propagation).

---

### 12. `FindFunction` ist O(n) (`ir.pas:352`)
Linearer Scan durch alle Funktionen im Modul bei jedem Aufruf. Für größere Programme mit vielen Funktionen und Calls wächst das quadratisch.

**Fix:** `TStringList` → `TFPGMap<string, TIRFunction>` oder Hash-Dictionary.

---

### 13. `Emit()` wächst das Instructions-Array um 1 pro Aufruf (`ir.pas:272`)
```pascal
SetLength(Instructions, Length(Instructions) + 1);
```
Das ist O(n²) an Kopieroperationen über den Lebenszyklus einer Funktion. Bei großen Funktionen (der Lowering-Pass emittiert hunderte Instruktionen) spürbar.

**Fix:** Capacity-Doubling-Strategie — `if Len >= Cap then SetLength(..., Cap * 2)`.

---

### 14. Regex-Engine eingebettet in Sema (`sema.pas:125–1119`)
Vollständiger NFA-zu-Bytecode-Compiler mit 130+ Methoden (~1.000 Zeilen) mitten im Semantic Analyzer. Konzeptuell völlig unabhängig, schwer isoliert zu testen.

**Fix:** Auslagern in `regex_engine.pas`. Sema ruft nur noch `CompileRegex(pattern) -> TRegexBytecode` auf.

---

### 15. Parallele Arrays statt Record für Locals (`lower_ast_to_ir.pas:28–36`)
10+ parallele Arrays pro Local-Variable (`FLocalTypes[]`, `FLocalElemSize[]`, `FLocalIsStruct[]`, `FLocalSlotCount[]`, `FLocalArrayLen[]`, `FLocalIsDynArray[]`, `FLocalTypeNames[]`, `FLocalConst[]`). Falsche Indexierung führt zu stillem Datenverlust. Jedes neue Property erfordert Änderungen in `AllocLocal()` und `AllocLocalMany()`.

**Fix:** `TLocalVar = record` mit allen Feldern, `array of TLocalVar` statt 10 getrennter Arrays.

---

### 16. TStringList mit Object-Pointern für Symboltabelle (`sema.pas:47–58`)
`FStructTypes` und `FClassTypes` als `TStringList` mit unsicheren Object-Casts. `FTypeAliases` speichert `TAurumType`-Enums als `TObject` — ein offensichtlicher Cast-Missbrauch. Ownership ist unklar: manche Listen werden im Destruktor nicht freigegeben, Risiko von Double-Free oder Leak.

**Fix:** `TFPGMap<string, T>` aus der FGL-Unit für typsichere Maps. Explizites Freigeben im Destruktor.

---

### 17. Typsystem-Struktur fehlt für parametrisierte Typen
`Array<T>`, `Map<K,V>`, `Set<T>` speichern Typ-Parameter in Seitenkanal-Feldern (`FLastElemType`, `FLastKeyType`, etc.) ohne zusammenhängendes Record. Konsumenten müssen diese manuell abfragen und können es vergessen.

Symptom: `MyClass[5]` als Struct-Feld schlägt im Layout-Pass fehl, weil `sema.pas:4856` nur `FStructTypes` prüft, nicht `FClassTypes`. Class-Typen werden als Array-Element-Typ nicht erkannt.

**Fix:** `TParamType = record BaseType, ElemType, KeyType, ValType: TAurumType end`. Explizite Auflösung vor Codegen erzwingen.

---

### 18. Code-Duplizierung im Backend (70+ Emitter-Dateien)
x86\_64, ARM64, Xtensa, RISC-V implementieren Prologue/Epilogue, Calling Convention und Register-Allokation jeweils vollständig unabhängig. Ein ABI-Fix in x86\_64 erreicht ARM64 nicht.

**Fix:** `arch_common.pas` für geteilte Schablonen (Prologue-Templates, Calling-Convention-Abstraktion, Register-State-Management).

---

## Zusammenfassung

| # | Priorität | Bereich | Kernproblem | Status |
|---|-----------|---------|-------------|--------|
| 1 | P0 | Sema | `atUnresolved` propagiert still, Typfehler erst im Codegen | — |
| 2 | P0 | Optimizer | CSE emittiert ungültiges IR (`Src2 = -1`) | — |
| 3 | P0 | Features | ~25 aerospace-todo-Features nur halb implementiert | — |
| 4 | P1 | IR | Kein CFG — Optimierungen arbeiten blind | ✅ `fix/cfg-ir` |
| 5 | P1 | Lowering | 7.576-Zeilen-Monolith, alles vermischt | ✅ `fix/lower-split` |
| 6 | P1 | Typsystem | Typ-Logik dreifach dupliziert (Parser/Sema/Lowering) | ✅ `fix/type-utils` |
| 7 | P1 | Parser | Keine Error Recovery → Fehlerkaskaden | ✅ `fix/parser-error-recovery` |
| 8 | P1 | Parser | 53 Seitenkanal-Felder als implizites Aufruf-Protokoll | ✅ `fix/parser-sidechannels` |
| 9 | P1 | Tests | Kein automatisierter Test-Runner | — |
| 10 | P2 | IR | `TIRInstr` Fat Record — ~80% der Felder pro Opcode unbenutzt | ✅ `fix/ir-lean-instr` |
| 11 | P2 | Optimizer | CSE O(n²) + matcht nur Temps, nicht Werte | ✅ `fix/cse-hash` |
| 12 | P2 | IR | `FindFunction` O(n) | — |
| 13 | P2 | IR | `Emit()` O(n²) Array-Wachstum | — |
| 14 | P2 | Sema | Regex-Engine (~1.000 Zeilen) direkt in Sema eingebettet | — |
| 15 | P2 | Lowering | 10 parallele Arrays statt `TLocalVar`-Record | — |
| 16 | P2 | Sema | `TStringList`-Symboltabelle mit unsicheren Object-Casts | — |
| 17 | P2 | Typsystem | Parametrisierte Typen ohne zusammenhängendes Record | — |
| 18 | P2 | Backend | 70+ Emitter duplizieren ABI-Logik unabhängig | — |

**Größter Hebel:** Zwei-Pass-Sema (#1) + CSE-Fix (#2) beheben aktive Correctness-Bugs. Danach: gemeinsame `type_utils.pas` (#6) + CFG-IR (#4) als Fundament für alle weiteren Optimierungen.
