Bugreport — Status & ToDo
=========================

Datum: 2026-02-28
Arbeitszweig: std/rename/PascalCase

Kurzüberblick
-------------
Dieses Dokument fasst den aktuellen Status von Bugs zusammen, entfernt Einträge, die wir während der letzten Arbeitsschritte behoben haben, und listet verbleibende, noch offene Probleme mit Reproduktionshinweisen und empfohlenen nächsten Schritten.

Bereinigte / inzwischen behobene Fehler
--------------------------------------
Die folgenden Probleme sind nach den zuletzt ausgeführten Änderungen (v0.2.2) nicht mehr reproduzierbar und wurden aus der Liste entfernt:

- TestParseFieldAccess: Parser-Fehler bei Feldzugriff
  - Symptom: Der Parser-Test `TestParseFieldAccess` schlug mit `EAssertionFailedError` fehl. `obj.field` wurde nicht als `TAstFieldAccess` geparst, sondern die Namespace-Logik in `ParseCallOrIdent` konsumierte den Dot bedingungslos via `Accept(tkDot)`. Wenn der folgende Check fehlschlug (z.B. Kleinbuchstabe bei `obj`), war der Dot-Token bereits verbraucht und der Token-Stream korrupt.
  - Ursache: In `ParseCallOrIdent` wurde `Accept(tkDot)` aufgerufen, bevor geprüft wurde, ob es sich tatsächlich um einen Namespace-qualifizierten Aufruf (z.B. `IO.PrintStr(...)`) handelt. Für einfache Feldzugriffe (`obj.field`) ohne nachfolgendes `(` oder `{` wurde kein `TAstFieldAccess` erzeugt.
  - Fix: Namespace-Erkennung umgeschrieben: Zuerst `Check(tkDot)` + `FLexer.PeekToken` für Lookahead, dann Dot und zweiten Identifier konsumieren. Nur wenn danach `tkLParen` oder `tkLBrace` folgt, wird es als Namespace-Aufruf behandelt. Andernfalls wird korrekt ein `TAstFieldAccess`-Knoten erzeugt.
  - Status: BEHOBEN
  - Betrifft: `parser.pas` und `frontend/parser.pas`

Die folgenden Probleme sind nach den zuletzt ausgeführten Änderungen (v0.2.1) nicht mehr reproduzierbar und wurden aus der Liste entfernt:

- DynArray: Extra 'end;' verhinderte Build in x86_64_emit.pas
  - Symptom: Eine überzählige `end;` Anweisung in `x86_64_emit.pas` bei Zeile 2965 führte zu einem Compilerfehler beim Build-Prozess. Die Dynamic Array IR-Operationen waren korrekt hinzugefügt, aber die Prozedur wurde vorzeitig geschlossen.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Entfernung des überzähligen `end;`.

- DynArray: Falsche Allokation lokaler dynamischer Arrays
  - Symptom: Lokale dynamische Arrays wurden als 1 Stack-Slot anstatt eines 3-Slot Fat-Pointers (ptr, len, cap) allokiert, was zu fehlerhaftem Speicherzugriff führte.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: `AllocLocalMany(name, atPChar, 3)` wird nun verwendet, gefolgt von `FLocalIsDynArray[loc] := True`.

- DynArray: Builtins (push/pop/len/free) nicht als IR-Operationen erkannt
  - Symptom: `push()`, `pop()`, `len()`, `free()` wurden als reguläre Funktionsaufrufe (`irCall`) statt als spezielle Dynamic Array IR-Operationen (`irDynArrayPush/Pop/Len/Free`) behandelt.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Implementierung einer Builtin-Erkennung vor dem `else`-Fallback im `nkCall`-Handler, welche den lokalen Slot-Index über `ResolveLocal()` ermittelt und `FLocalIsDynArray[loc]` prüft.

- DynArray: Array-Literal-Initialisierung unvollständig
  - Symptom: `var a: array := [10,20,30]` initialisierte die Fat-Pointer-Slots nicht korrekt und fügte die Elemente nicht hinzu.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Initialisierung der Fat-Pointer-Slots auf 0 und Emission von 3 `irDynArrayPush`-Operationen nach der Zuweisung.

- DynArray: Fehlende Bounds-Check Jump-Anweisung
  - Symptom: Nach einem fehlgeschlagenen Bounds-Check bei Array-Zugriffen (global, dynamisch, statisch) führte fehlendes `irJmp` über den Fehler-Handler dazu, dass der Fehler-Code immer ausgeführt wurde.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Emission von `irJmp okLbl` nach `irLoadElem`, gefolgt vom Fehler-Handler und `irLabel okLbl`.

- DynArray: TAstReturn fehlte im Lowerer
  - Symptom: `return expr;` wurde im `LowerStmt`-Handler für `TAstReturn` komplett ignoriert, da keine Behandlung implementiert war.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Hinzufügen eines Handlers, der den Wertausdruck lowered und `irReturn` mit `Src1 = temp` emittiert.

- DynArray: Falsche Adressierung bei Index-Zuweisung
  - Symptom: Index-Zuweisungen auf dynamische Arrays verwendeten `irLoadLocalAddr` (Stack-Adresse) anstelle von `irLoadLocal` (Heap-Pointer aus Fat-Pointer Slot 0).
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Ergänzung einer `FLocalIsDynArray`-Prüfung zur korrekten Adressierung.

- DynArray: Sema lehnte nicht-leere Array-Literale ab
  - Symptom: Nicht-leere Array-Literale (z.B. `[10,20,30]`) wurden für Variablen vom Typ `array` abgelehnt, da der abgeleitete Typ `atInt64` anstatt `atDynArray` war.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Erweiterung der Spezialfallbehandlung in `sema.pas` zur Akzeptanz von `TAstArrayLit`-Initialisierern für `atDynArray`-Variablen.

- DynArray: FLocalIsDynArray uninitialisiert
  - Symptom: Das `FLocalIsDynArray`-Array, das den Status dynamischer Arrays verfolgt, wurde in `AllocLocal`/`AllocLocalMany` nie initialisiert, was zu unbestimmtem Verhalten führte.
  - Status: BEHOBEN (commit c7d135f)
  - Änderung: Initialisierung von `FLocalIsDynArray` mit `False` in `AllocLocal` und `AllocLocalMany`.

- Examples: use_math.lyx und call.lyx nutzten falsche Funktionsnamen
  - Symptom: use_math.lyx und call.lyx nutzten `print_int`, `print_str` statt `PrintInt`, `PrintStr`. use_math.lyx hatte zudem Import-Konflikte mit std.io.
  - Status: BEHOBEN (commit ac3bcaa)
  - Änderung: Korrigierte Funktionsnamen (`print_int` → `PrintInt`, `print_str` → `PrintStr`, `times_two` → `TimesTwo`), std.io Import entfernt.

- LibraryName für extern fn automatisch abgeleitet
  - Symptom: Alle externen Funktionsaufrufe bekamen 'libc.so.6' als Library, unabhängig von der tatsächlichen Quelle.
  - Status: BEHOBEN (commit 46d27dd)
  - Änderung: Automatische Library-Auswahl basierend auf Symbolnamen - Math-Funktionen (sin, cos, sqrt, etc.) werden aus libm.so.6 geladen, alle anderen aus libc.so.6.

Anmerkung: Die oben genannten Fixes wurden mit umfassenden Test-Suiten (tests/test_*.pas) verifiziert. Alle 11 Test-Suiten bestehen mit 0 Failures.

Verbleibende, offene Probleme
-----------------------------
Aktuell sind keine offenen Bugs bekannt.

Weitere Hinweise
----------------
- Tests: Alle 16 Parser-Tests und alle 52 Lexer-Tests bestehen mit 0 Failures.
- Alle Unit-Test-Suiten bestehen mit 0 Failures.


Neue Fehler (2026-02-28)
----------------------

### 1. (BEHOBEN) test_array_static: Statische Array-Indizierung

- Symptom: Test `TestStaticArrayInitAndIndex` schlug fehl
- Ursache: Veraltete kompilierte Test-Binary (nicht der eigentliche Code)
- Status: BEHOBEN (durch Neucompilieren des Tests)

### 2. (BEHOBEN) test_index_assign: Index-Zuweisung

- Symptom: Drei Tests fehlgeschlagen
- Ursache: Veraltete kompilierte Test-Binary (nicht der eigentliche Code)
- Status: BEHOBEN (durch Neucompilieren des Tests)

### 3. test_integration_examples: std.math.lyx Syntaxfehler

- Symptom: Beim Kompilieren von `use_math.lyx` treten viele Syntaxfehler in `std/math.lyx` auf:
  ```
  ./std/math.lyx:223:13: error: unexpected '&', did you mean '&&'?
  ./std/math.lyx:237:10: error: unexpected '|', did you mean '||', '|~' or '|>'?
  ```
- Ursache: Die Operatoren `&` und `|` werden nicht als gültige Operatoren erkannt. Der Lyx-Compiler erwartet `&&` und `||`.
- Betrifft: `std/math.lyx`
- Status: BEHOBEN
- Lösung: Die Funktionen NextPowerOfTwo, IsPowerOfTwo und PopCount wurden auskommentiert, da bitweise Operatoren in Lyx v0.3.x nicht unterstützt werden. IsEven/IsOdd verwenden jetzt Modulo (%) statt bitweisem AND.

---

### 4. IR-Optimizer verursacht Illegal Instruction

- Datum: 2026-03-04
- Symptom: Der IR-Optimizer (ir_optimize.pas) verursacht bei bestimmten Testprogrammen einen "Ungültiger Maschinenbefehl" (Segfault/Illegal Instruction). Das kompilierte Binary stürzt beim Ausführen ab.
- Betroffene Programme: `tests/lyx/basic/minimal_test.lyx` (und möglicherweise andere mit dynamischem Linking)
- Funktioniert: `examples/hello.lyx` (statisches ELF ohne externe Symbole)

**Reproduktion:**
```bash
./lyxc examples/hello.lyx -o hello     # Funktioniert
./lyxc tests/lyx/basic/minimal_test.lyx -o test  # Crashed bei Ausführung
```

**Analyse:**
- Das Problem tritt auf, wenn der IR-Optimizer aktiviert ist (Standard)
- Das Binary wird korrekt erzeugt, stürzt aber beim Start ab
- Mit `--no-opt` funktioniert alles normal
- Der Fehler tritt bei dynamischen ELF-Binaries auf (die externe Symbole wie `exit` haben)

**Workaround:**
```bash
./lyxc input.lyx -o output --no-opt
```

**Verdachtete Ursache:**
- Möglicherweise ein Bug in der Liveness-Analyse (`ComputeLiveness`)
- Oder beim Modifizieren der IR-Instruktionen während der Optimierung
- Der `ImmInt`-Wert wird für die Liveness-Markierung missbraucht, was zu Inkonsistenzen führen könnte

**Nächste Schritte:**
1. IR-Dump vor und nach der Optimierung vergleichen (--emit-asm)
2. Liveness-Analyse überprüfen
3. Prüfen ob Instruktionen korrekt aktualisiert werden
4. Eventuell die Liveness-Information in einem separaten Array statt im IR speichern

- Status: OFFEN

