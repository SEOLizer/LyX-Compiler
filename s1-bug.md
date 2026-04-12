# Bootstrap-Compiler Bug-Analyse (Stage 1)

**Datum**: 2026-04-08  
**Branch**: `fix/bootstrap-continue-keyword`  
**Symptom**: S1 kompiliert erfolgreich mit S0, tokenisiert und parsed korrekt, aber crashed mit "Speicherzugriffsfehler" nach Stage 4 (Linting).

---

## Zusammenfassung der Bugs

| # | Datei | Schwere | Status |
|---|-------|---------|--------|
| 1 | `bootstrap/ir_lower.lyx` | KRITISCH | ✅ War bereits implementiert |
| 2 | `bootstrap/lyxc.lyx` | KRITISCH | ✅ War bereits behoben |
| 3 | `bootstrap/lexer.lyx` | KRITISCH | ✅ **Gefixt**: TK_CONTINUE=69 |
| 4 | `bootstrap/codegen_x86.lyx` | MITTEL | ✅ **Gefixt**: for continue support |
| 6 | `bootstrap/ir_lower.lyx` | KRITISCH | ⚠️ **NEU**: Crash nach Stage 4 |

---

## Bug 1 — IR-Control-Flow (bereits implementiert)

**Status**: ✅ War bereits implementiert in `ir_lower.lyx`

Die Funktionen `lowerIf`, `lowerWhile`, `lowerBreak`, `lowerContinue` emittieren korrekte IR-Instruktionen.

---

## Bug 2 — API-Mismatch in lyxc.lyx (bereits behoben)

**Status**: ✅ War bereits behoben

`lyxc.lyx` verwendet korrekte API:
```lyx
var lx: Lexer := new Lexer();
lx.Init(source, srcLen);
```

---

## Bug 3 — Token-Kollision TK_CONTINUE = TK_STATIC = 36

**Datei**: `bootstrap/lexer.lyx`

### Problem

```lyx
pub con TK_CONTINUE: int64 := 36;   // Kollision!
pub con TK_STATIC:   int64 := 36;
```

### Fix

```lyx
pub con TK_CONTINUE: int64 := 69;  // Freie Lücke zwischen TK_IS=68 und TK_PLUS=70
```

### Verifizierung

S1 tokenisiert jetzt korrekt:
```
Token 10: fn
Token 2: main
Token 100: (
Token 101: )
...
```

---

## Bug 4 — `cg_genFor` unterstützt `continue` nicht

**Datei**: `bootstrap/codegen_x86.lyx`

### Problem

In `cg_genWhile` wurde `curContHead` korrekt implementiert (save/restore/patch). In `cg_genFor` fehlte das vollständig.

### Fix

Analog zu `cg_genWhile` implementiert:
```lyx
fn cg_genFor(ni: int64) {
  // ...
  // Save and reset break/continue lists for this loop
  var savedBreakHead: int64 := self.curBreakHead;
  var savedContHead: int64 := self.curContHead;
  self.curBreakHead := -1;
  self.curContHead := -1;
  // Body
  self.cg_genBlock(self.cg_nc2(ni));
  // loop_cont: patch all continue jumps to here
  var ch: int64 := self.curContHead;
  while (ch != -1) {
    // ... patch logic ...
  }
  // ... rest of loop ...
  // Restore break/continue lists
  self.curBreakHead := savedBreakHead;
  self.curContHead := savedContHead;
}
```

---

## Bug 6 — S1 Crash nach Stage 4 (NEU)

**Datei**: `bootstrap/ir_lower.lyx` / `bootstrap/ir.lyx`

### Symptom

S1 parsed und linted erfolgreich:
```
Stage 1: Lexing... ✅
Stage 2: Parsing... ✅
Stage 3: Semantic Analysis... ✅
Stage 4: Linting... ✅
=== COMPILATION STATS ===
Errors: 0
Warnings: 1
Time: 0ms
[CRASH] Speicherzugriffsfehler
```

### Analyse

Der Crash passiert in **Stage 5 (IR Generation)** oder **Stage 7 (Code Generation)**.

Kandidaten für das Problem:
1. **IRModule.init()**: mmap(0, 8192, 3, 34, -1, 0) - prot=3 (READ|WRITE) sollte korrekt sein
2. **IRLower.init()**: accessors wie `nodeOff()`, `nodeKind()` - 88 bytes pro Node
3. **Emitx86.init()**: mmap(0, 65536, 3, 34, -1, 0)

### Mögliche Ursachen

1. **Pointer-Arithmetik-Fehler**: Falsche Berechnung von Node-Offsets
2. **Null-Pointer-Dereferenzierung**: IR Module oder Nodes sind 0
3. **rel32-Patching im Codegen**: Falsche Offsets für builtin calls

### rel32-Patching Analyse

Die Formel für rel32-Patching:
```lyx
// cg_emitCall gibt Position NACH dem rel32-Platzhalter zurück
fn cg_emitCall(): int64 {
  self.cg_e8(0xE8);           // call opcode
  var pos: int64 := self.codeLen;  // Position des rel32 (NICHT des call opcode!)
  self.cg_e32(0);
  return pos;
}
```

Korrekte Formel:
```lyx
var pp: int64 := self.cg_emitCall();
// target_va = 0x401000 + CG_H_XXX
// call_va = 0x401000 + pp - 4 (4 bytes vorher für call opcode)
// rel32 = target_va - call_va - 5
//       = (0x401000 + CG_H_XXX) - (0x401000 + pp - 4) - 5
//       = CG_H_XXX - pp - 1
// Vereinfacht: CG_H_XXX - pp - 4 (weil pp = position + 4 von call opcode)
```

Getestete Formeln:
- `CG_H_XXX - pp - 5` ❌ (negative rel32, springt zu falschen Adressen)
- `CG_H_XXX - pp - 4` ❌ (funktioniert nicht korrekt)
- `CG_H_XXX - pp` ⚠️ (besser, aber immer noch Crash)

### Nächste Schritte zur Analyse

1. **Debug-Ausgabe in IRModule.init()**: Prüfen ob mmap返回 nicht 0
2. **Debug-Ausgabe in IRLower.lowerModule()**: Prüfen ob nodes/astRoot gültig
3. **Debug-Ausgabe in Emitx86.emit()**: Prüfen ob getFuncCount() > 0

---

## Empfohlene Fix-Reihenfolge

1. ✅ **Bug 3** - Token-Kollision beheben (`lexer.lyx`): `TK_CONTINUE := 69`
2. ✅ **Bug 4** - `cg_genFor` continue-Support (`codegen_x86.lyx`)
3. 🔧 **Bug 6** - Debug-Ausgabe hinzufügen um Crash-Ursache zu finden
4. 🔧 **rel32-Patching** - Formel verifizieren (eventuell falsch)

---

## Test-Programme

```lyx
// test_ultra_minimal.lyx - minimalstes Programm
fn Main(): int64 { return 42; }

// test_no_strings.lyx - ohne String-Literale
fn Main(): int64 { PrintInt(42); return 0; }

// test_no_builtins.lyx - nur Arithmetik
fn Main(): int64 { var a:=10; var b:=20; return a+b; }
```

---

## Links

- Vorher funktionierender S1: `lyxc_stage1` (vor Änderungen am 2026-04-07)
- Aktueller S0: `./lyxc` (FPC-Compiler, funktioniert)