# S2 Import-Handling Bug Plan

## Aktueller Stand (2026-04-11)

### Bug-Beschreibung

S2 (der Lyx-kompilierte Compiler) hat einen fundamentalen Bug im Import-Handling:

```
Test-File: import bootstrap.lexer; fn main(): int64 { return 42; }

Output:
  - Labels: 24 (leere + lexer functions + main)
  - Patches: 366 (viele aus importiertem lexer)
  - Error: "codegen: unresolved symbol: main"
  - Crash: Segfault
```

### Root Cause

Die importierten Module (z.B. bootstrap.lexer) haben viele Funktionsaufrufe (Patches).
Diese Referenzen werden aufgelöst gegen die Label-Tabelle des HAUPTMODULS.
Die Labels aus importierten Modulen sind NICHT in der aktuellen Label-Tabelle:

```
main() → label[23] ✓ (wird gefunden)
Lexer_Init() → ?
Lexer_ReadIdent() → ?
... (366 patches für 24 labels)
```

### Analysedetails

- **Labels**: 24 (test + main + 22 lexer functions)
- **Patches**: 366 (aus importiertem bootstrap.lexer)
- **Problem**: Die externen Referenzen können nicht aufgelöst werden
- **Crash**: Segfault in cg_patchAll() nach dem Label-Lookup

---

## Aktueller Stand nach AP-1+AP-2+AP-3

| AP | Status | Problem |
|----|--------|---------|
| AP-1 | ✅ Implementiert | Labels werden gesammelt |
| AP-2 | ✅ Implementiert | Timing gefixt |
| AP-3 | ✅ Implementiert | Patch-Cap erhöht, Unresolved übersprungen |

**AP-3 Änderungen** (Commit `1d6b944`):
- patchCap: 256 → 512
- Unresolved Patches werden übersprungen (int3)
- Doppelte Variablen-Deklarationen entfernt

**Verbleibendes Problem:**
- Crash passiert immer noch in der Patch-Schleife
- Muss tiefer analysiert werden

**Verbleibendes Problem:**
- 366 Patches (intern aus Import) können nicht alle als Labels aufgelöst werden
- Die Patches sindFAST ALLE aus dem importierten Modul selbst
- Das ist ein fundamentales Codegenerierungs-Problem

**Beschreibung:**
- Aktuelles Label-Capacity prüfen (CG_LABEL_CAP)
- Bei Bedarf: cg_growLabels() aufrufen
- Platz für importierte Labels schaffen

**Geschätzte Änderungen:**
- codegen_x86.lyx: ~20 Zeilen

### ❌ AP-3: Patch-Auflösung verbessern (OFFEN)

**Beschreibung:**
- Beim cg_patchAll(): auch importierte Labels durchsuchen
- Eine kombinierte Label-Suche implementieren
- Oder: einen externen Label-Index aufbauen

**Geschätzte Änderungen:**
- codegen_x86.lyx: ~40 Zeilen

---

## Testergebnisse

### Vor allen Fixes
```
Ohne Import: ✓ funktioniert
Mit Import:   ✗ Crash (unresolved symbol + segfault)
```

### Nach AP-1 (aktuell)
```
Ohne Import:    ✓ funktioniert
Mit Import:    ❌ Crash in cg_patchAll()
               - main wird gefunden ✓
               - aber 366 > 35 Labels = Crash
```

---

## Nächste Schritte

1. **AP-2 implementieren**: Label-Tabelle dynamisch erweitern
2. **AP-3 implementieren**: Bessere Cross-Module-Label-Auflösung
3. **Test**: Mit mehreren Imports und komplexeren Modulen

---

## Referenzen

- Commit AP-1: `ee19f29` - fix(codegen): AP-1 - Import-Label-Collection implementiert
- betroffene Dateien:
  - bootstrap/codegen_x86.lyx (cg_processImport, cg_collectImportLabels, cg_addLabel, cg_patchAll)
  - bootstrap/lyxc.lyx (Import-Pipeline)