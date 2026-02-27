Bugreport — Status & ToDo
=========================

Datum: 2026-02-27
Arbeitszweig: main (lokales Commit: c7d135f)

Kurzüberblick
-------------
Dieses Dokument fasst den aktuellen Status von Bugs zusammen, entfernt Einträge, die wir während der letzten Arbeitsschritte behoben haben, und listet verbleibende, noch offene Probleme mit Reproduktionshinweisen und empfohlenen nächsten Schritten.

Bereinigte / inzwischen behobene Fehler
--------------------------------------
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

Anmerkung: Die oben genannten Fixes wurden mit umfassenden Test-Suiten (tests/test_*.pas) verifiziert. Alle 11 Test-Suiten bestehen mit 0 Failures.

Verbleibende, offene Probleme
-----------------------------
Diese Probleme sind weiterhin offen und sollten separat adressiert:

1) Beispiele/Integration: Fehler beim Kompilieren von examples/use_math.lyx
   - Symptom: use_math.lyx nutzt falsche Funktionsnamen (`print_int`, `print_str` statt `PrintInt`, `PrintStr`) und hat Import-Konflikte mit Builtins.
   - Status: offen (keine Regression)
   - Reproduktion: make test → test_integration_examples schlägt fehl mit "call to undeclared function: print_int"
   - Nächste Schritte: use_math.lyx korrigieren → Kleinbuchstaben-Funktionsnamen durch korrekte Builtin-Namen ersetzen.
   - Priorität: Niedrig

2) LibraryName für extern fn hartcodiert
   - Symptom: Alle externen Funktionsaufrufe bekommen 'libc.so.6' als Library, unabhängig von der tatsächlichen Quelle.
   - Status: offen
   - Nächste Schritte: Syntax für `extern fn libname:symbol` ergänzen oder aus Library-Declaration ableiten.
   - Priorität: Mittel

3) Stack-Alignment callPad-Formel
   - Symptom: Die mathematische Formel für Stack-Alignment bei ungeraden Stack-Argumenten ist fragwürdig.
   - Status: offen (funktioniert durch konservative Reserve im Prolog)
   - Nächste Schritte: Formel überprüfen und ggf. optimieren.
   - Priorität: Niedrig

4) irVarCall toter Code
   - Symptom: Der IR-Opcode irVarCall existiert, wird aber nie generiert (Function-Pointer-Support fehlt).
   - Status: offen
   - Nächste Schritte: Function-Pointer-Typen und Aufrufe implementieren.
   - Priorität: Niedrig

5) Windows PE64 / ARM64 Backend Stabilisierung
   - Symptom: Beide Backends haben Grundfunktionalität, aber es fehlen Tests und ggf. Feature-Parität.
   - Status: offen
   - Nächste Schritte: Mehr Integrationstests für beide Plattformen.
   - Priorität: Mittel

Weitere Hinweise
----------------
- Commit-Referenz: f673bb2 (lokal, nicht gepusht). Enthält v0.2.0 mit unified call path, Bugfixes und neuen CLI-Flags.
- Tests: make test → 15 Test-Suiten, alle bestehen (0 Failures). Nur test_integration_examples hat einen bekannten Fehler (use_math.lyx).
- Neue CLI-Flags (v0.2.0):
  - `--emit-asm`: Gibt IR als Pseudo-Assembler aus
  - `--dump-relocs`: Zeigt externe Symbole und PLT-Patches

