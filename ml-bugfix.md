# ml-bugfix.md – Cross-Module Import Bug Documentation

## 1 Executive Summary

**Bug ID:** ML-001  
**Severity:** High  
**Status:** Open - Workaround Available  
**Affected Components:** `std.ml` import system, ELF64 code generation

### Summary

Importierte Funktionen aus `std.ml` (und anderen Units) geben inkorrekte Werte zurück wenn gleichzeitig `std.io` importiert wird. Das Problem liegt im ELF-Backend beim Auflösen von Cross-Module Funktionsaufrufen.

---

## 2 Symptome

### 2.1 Reproduktion

```lyx
// Test 1: Funktioniert NICHT
import std.io;
import std.ml;

pub fn main(): int64 {
  var r: f64 := SquareF64(5.0);  // Erwartet: 25.0, Tatsächlich: 0.0
  return 0;
}
```

### 2.2 Ausgabe

```
SquareF64(5) = 0.000000   // ❌ Falsch!
```

### 2.3 Kombinationen

| Import Kombination | Ergebnis |
|-----------------|----------|
| Nur `std.ml` | ❌ 0.0 |
| `std.io` + `std.ml` | ❌ 0.0 |
| `std.math` + andere Unit | ✅ Korrekt |
| Nur andere Unit | ✅ Korrekt |
| Andere Unit + `std.math` | ✅ Korrekt |
| Andere Unit + `std.io` | ❌ 0.0 |

---

## 3 Root Cause Analysis

### 3.1 Identifiziertes Problem

**Location:** `compiler/ir/lower_ast_to_ir.pas`, Zeile ~3539

Der IR-Lowering generiert für Funktionsaufrufe nur den einfachen Namen (`call.Name`), ohne den notwendigen `_L_` Prefix für Cross-Module Calls.

```pascal
// Aktueller Code (fehlerhaft)
instr.ImmStr := call.Name;  // z.B. "SquareF64" statt "_L_SquareF64"
```

### 3.2 ELF Label Auflösung

Das Lyx-ELF-Backend (Linux x86_64) generiert statische Binärdateien ohne externe Symbolauflösung:

1. **Labels im .text:** `_L_<UnitName>_<FunctionName>` (z.B. `_L_stdml_SquareF64`)
2. **Importierte Funktionen:** Werden mit Prefix `_L_` ins Binary geschrieben
3. **Call-Auflösung:** Der Jump-Patch verwendet den falschen Symbol-Namen

### 3.3 Debug-Ausgabe (Symptom)

```
[DEBUG] Unresolved jump patch: label="_L_Triple"
```

Das Label existiert nicht im generierten Binary → der Call geht ins Leere.

---

## 4 Work Products (WPs)

### WP-1: IR-Lowering Fix (Kurzfristig)

**Beschreibung:** Im IR-Lowering den korrekten Mangled Name generieren.

**Location:** `compiler/ir/lower_ast_to_ir.pas`, Funktion `LowerExpr`, Case `nkCall`

**Änderung:**
```pascal
// Aktueller Code
instr.ImmStr := call.Name;

// Ziel: Prüfen ob Funktion importiert ist
// Wenn ja: '_L_' + Namespace + '_' + Name
// Wenn nein: Original-Name
```

**Aufwand:** Geschätzt 2-4 Stunden  
**Risiko:** Niedrig - keine bestehende Funktionalität wird beeinträchtigt

---

### WP-2: Symbol-Tabelle Import-Flag (Mittelfristig)

**Beschreibung:** Das bereits existierende `IsImported` Flag in `TSymbol` nutzen um zu prüfen ob eine Funktion importiert wurde.

**Location:** `compiler/frontend/sema.pas`

**Ansatz:**
```pascal
// Im IR-Lowering:
var sym := ResolveSymbol(call.Name);
if Assigned(sym) and sym.IsImported then
  instr.ImmStr := '_L_' + sym.Name  // oder Namespace lookup
else
  instr.ImmStr := call.Name;
```

**Aufwand:** Geschätzt 4-8 Stunden  
**Risiko:** Mittel - muss Symbol-Resolving integriert werden

---

### WP-3: Backend Label Resolver (Langfristig)

**Beschreibung:** Im ELF-Backend einen Fallback-Label-Resolver implementieren der automatisch nach dem `_L_` Prefix sucht wenn das Original nicht gefunden wird.

**Location:** `compiler/backend/x86_64/x86_64_emit.pas`, Case `irCall`

**Pseudocode:**
```pascal
// Im Backend:
if FLabelMap.IndexOf(instr.ImmStr) < 0 then
  // Fallback: Versuche mit _L_ Prefix
  tryLabel := '_L_' + instr.ImmStr;
  if FLabelMap.IndexOf(tryLabel) >= 0 then
    instr.ImmStr := tryLabel;
```

**Aufwand:** Geschätzt 8-16 Stunden  
**Risiko:** Niedrig - nur Workaround im Backend

---

### WP-4: Unit-Namespace Tracking (Langfristig)

**Beschreibung:** Den vollständigen Namespace-Pfad im AST speichern und beim Import in die Symbol-Tabelle übertragen.

**Location:** `compiler/frontend/ast.pas`, `TAstImportDecl`

**Felder hinzufügen:**
```pascal
TAstImportDecl = class(TAstNode)
  // ... exists fields
  ImportedModuleName: string;  // z.B. "std.ml"
  ImportedUnitPath: string;   // z.B. "/full/path/to/std/ml.lyx"
end;
```

**Aufwand:** Geschätzt 16-24 Stunden  
**Risiko:** Mittel - Änderungen im Frontend

---

### WP-5: Cross-Module Label Resolution (Architektur-Fix)

**Beschreibung:** Die Label-Positionen müssen zwischen allen importierten Units geteilt werden. Aktuell wird jede Unit separat kompiliert und die Labels werden nicht zwischen Modulen aufgelöst.

**Location:** `compiler/backend/x86_64/x86_64_emit.pas`, `EmitModule`

**Lösungsansätze:**

1. **Zentrale Label-Registry**: Alle Labels aller Units in einer zentralen Map speichern
2. **ELF-Section-Merging**: Die .text-Sections aller Units beim Linken zusammenführen
3. **PLT-basierte Auflösung**: Externe Funktionen immer über PLT (Procedure Linkage Table) aufrufen

**Aufwand:** Geschätzt 24-40 Stunden  
**Risiko:** Hoch - Änderungen an der Architektur

---

### WP-6: Interim Workaround (Sofort)

**Beschreibung:** Bis der vollständige Fix implementiert ist, können Tests mit inline-Funktionen durchgeführt werden.

**Siehe Section 5: Workaround (Sofort)**

---

## 5 Workaround (Sofort)

### 5.1 Für ML-Tests

Da der Bug noch nicht behoben ist, können Tests mit einem inline Workaround durchgeführt werden:

```lyx
import std.io;

// ML Funktionen inline definieren (statt importieren)
pub fn SquareF64(x: f64): f64 {
  return x * x;
}

pub fn ExpF64(x: f64): f64 {
  return 1.0 + x + (x * x * 0.5);
}

pub fn main(): int64 {
  var r: f64 := SquareF64(5.0);  // ✅ Korrekt: 25.0
  PrintStr("Ergebnis: ");
  PrintFloat(r);
  PrintStr("\n");
  return 0;
}
```

### 5.2 Für std.ml Integration

Langfristig sollte `std.ml` als Teil des "builtins" Systems implementiert werden anstatt als importierbare Unit:

**Option A:** Builtin-Funktionen
```lyx
// Statt:
import std.ml;
var r := SquareF64(5.0);

// Als Builtin:
var r := __builtin_square(5.0);
```

**Option B:** Compile-Time Inlining
Der Compiler inlined den Inhalt von `std.ml` automatisch in alle Dateien die `math.ml` verwenden.

---

## 6 Test Plan

### 6.1 Regression Tests

Nach jedem Fix müssen diese Tests bestehen:

| Test-ID | Beschreibung | Erwartetes Ergebnis |
|---------|--------------|---------------------|
| T-001 | `import std.ml; SquareF64(5)` | 25.0 |
| T-002 | `import std.ml; import std.io; SquareF64(5)` | 25.0 |
| T-003 | `import custom.unit; import std.io; Func(5)` | Korrekter Wert |
| T-004 | `import std.math; import std.io; Abs64(-5)` | 5 |
| T-005 | `import std.io; import std.math; Abs64(-5)` | 5 |

### 6.2 Boundary Tests

| Test-ID | Beschreibung | Erwartetes Ergebnis |
|---------|--------------|---------------------|
| B-001 | `SquareF64(0)` | 0.0 |
| B-002 | `SquareF64(-3)` | 9.0 |
| B-003 | `SquareF64(1e10)` | 1e20 |

---

## 7 Referenzen

### 7.1 Betroffene Dateien

- `compiler/ir/lower_ast_to_ir.pas` - IR Lowering (Hauptproblem)
- `compiler/frontend/sema.pas` - Symbol Management
- `compiler/backend/x86_64/x86_64_emit.pas` - ELF Codegenerierung
- `std/ml.lyx` - ML Standardbibliothek
- `std/io.lyx` - I/O Standardbibliothek

### 7.2 Verwandte Issues

- Issue #101: Static ELF Linking without libc
- Issue #203: Cross-module function resolution

---

## 8 Timeline

| Datum | Event |
|-------|-------|
| 2026-04-25 | Bug entdeckt bei ML-Tests |
| 2026-04-25 | Workaround dokumentiert |
| 2026-04-25 | Investigation begonnen (dieses Dokument) |
| 2026-04-25 | WP1 Versuch: IR-Lowering + Backend -NICHT ERFOLGREICH |
| TBD | WP-5: Cross-Module Label Resolution (Architektur-Änderung) |
| TBD | Regression Tests |
| TBD | Release mit Fix |

---

## 9 WP1 Versuch (Fehlgeschlagen)

### Analyse

Der erste Fix-Versuch (WP1) war nicht erfolgreich. Die Ursache:

1. **IR-Lowering**: Fügt `_L_` Prefix zu Funktionsaufrufen hinzu ✅
2. **Backend**: Schreibt Labels mit `_L_` Prefix in FLabelPositions ✅
3. **Problem**: Die Labels für importierte Funktionen werden **nicht in module.Functions eingetragen**!

### Root Cause

Importierte Units (std.io, std.ml) werden als **separate IR-Module** generiert. Die Labels werden nur für Funktionen in `module.Functions` registriert. Die Labels aus importierten Units existieren nicht in der aktuellen FLabelPositions Map.

### Evidence

```
[DEBUG] Unresolved jump patch: label="_L_StrLength"
[DEBUG] Unresolved jump patch: label="_L__PrintfCore"
```

Die Labels mit `_L_` Prefix werden generiert aber nicht gefunden.

### Nächste Schritte

**WP-5:** Cross-Module Label Resolution implementieren:
- Die FLabelPositions müssen zwischen allen importierten Units geteilt werden
- ODER: Ein zentrales Label-Register für alle Funktionen
- ODER: Statische ELF-Auflösung anders implementieren

---

## 10 Autor

Andreas Röne  
Senior Compiler Engineer, Lyx ML-Unit  
DO-178C TQL-5 Qualified

---

## Appendix A: Quick Reference

### A.1 Symptom Erkennung

```bash
# Kompiliere mit Debug-Output
./lyxc test.ml -o test 2>&1 | grep "Unresolved"

# Output:
[DEBUG] Unresolved jump patch: label="_L_FunctionName"
```

### A.2 Notfall-Workaround

```lyx
// Vor jedem Test:
import std.io;

// Definiere benötigte Funktionen inline:
pub fn SquareF64(x: f64): f64 { return x * x; }

// ... rest of code
```

---

*Document Version: 1.0*  
*Last Updated: 2026-04-25*