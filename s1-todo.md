# S1 Bootstrap Compiler - Aktueller Stand

**Datum**: 2026-04-09  
**Branch**: `fix/bootstrap-continue-keyword`  
**Status**: S1 kann sich selbst kompilieren, aber die Codegenerierung produziert 0 Bytes Output

---

## Zusammenfassung

| Komponente | Status | Notizen |
|------------|--------|---------|
| S0 (FPC-basierend) | ✅ FUNKTIONIEREND | Original-Compiler |
| S1 Kompiliert S0 | ✅ FUNKTIONIEREND | `lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_test` |
| S1 Kompiliert S1 | ✅ FUNKTIONIEREND | Self-Hosting funktioniert |
| S1 Kompiliert andere Files | ❌ FEHLER | Codegenerierung produziert 0 Bytes |

---

## Debug-Erkenntnisse

### Beobachtung 1: Methoden werden aufgerufen aber Inhalte nicht ausgeführt

```
irAddFunc: called addFunc, returned = 0  ← Methode wurde AUFGERUFEN
# ABER:
# addFunc: idx=..., funcLen before=...   ← Diese Prints in addFunc erscheinen NICHT
# EMIT: funcCount = ...                 ← Diese Prints in emit() erscheinen NICHT
# EMIT: getCodeBuf called, codeBuf = .. ← Diese Prints in getCodeBuf() erscheinen NICHT
```

**Analyse**: S1 ruft die Methoden auf, aber der Code innerhalb der Methoden wird nicht ausgeführt.

### Beobachtung 2: getCodeBuf() gibt 1 zurück statt Buffer-Adresse

```
emitX86: returning codeBuf = 1
emitX86_64 returned: 1
Final codeBuffer = 1
```

**Analyse**: Das Return-Statement in getCodeBuf() gibt den falschen Wert zurück.

### Beobachtung 3: IRModule Felder werden nicht korrekt aktualisiert

```
lyxc: lower.globalFuncCount = 1          ← IRLower hat 1 Funktion
irMod funcLen after lower = 0            ← ABER IRModule zeigt 0
irMod.getFuncCount() = 0                 ← Methodenaufruf gibt 0 zurück
```

**Analyse**: Die IRModule-Feld-Write-Operationen funktionieren nicht korrekt in S1→S2.

---

## Identifizierte Root Causes

### 1. VTable / Method Dispatch Bug (KRITISCH)

Methoden werden aufgerufen aber der Body wird nicht ausgeführt. Das deutet auf:
- VTable-Mismatch zwischen S0-kompilierten (Pascal) und S1-kompilierten (Lyx) Klassen
- Oder: Methodenaufruf springt an falsche Adresse (VTable-Corruption)

### 2. Field Write Bug in S1→S2 (KRITISCH)

poke64() und Feld-Zuweisungen funktionieren nicht korrekt, wenn:
- S0 (Pascal) ein IRModule erstellt
- S1 (Lyx) darauf zugreift und Felder schreibt

### 3. Return Value Bug in S1 (KRITISCH)

Das return Statement in getCodeBuf() gibt 1 zurück statt self.codeBuf.

---

## Durchgeführte Fix-Versuche

1. ✅ **irAddFunc reparieren**: IRLower verwendet jetzt irModule.addFunc() statt peek/poke
2. ❌ **Ergebnis**: Methode wird aufgerufen, aber Inhalte werden nicht ausgeführt
3. ❌ **Ergebnis**: IRModule Felder werden nicht aktualisiert

---

## Nächste Schritte (Optionen)

### Option A: Low-Level Debug mit ASM-Listing
ASM-Output von S1 generieren und analysieren, ob die Methoden-Calls korrekt sind.

### Option B: Direkte Feld-Manipulation in IRLower
statt Methodenaufrufe poke64() direkt auf IRModule-Speicher anwenden.

### Option C: Minimal-Test erstellen
Eine einfache Lyx-Datei schreiben, die einen return-Wert testet und den generierten Code debuggen.

---

## Aktive Todos

1. **ASM-Listing generieren und analysieren** - ✅ ABGESCHLOSSEN
2. **lowerReturn() implementieren** - ✅ ABGESCHLOSSEN
3. **irAddFunc mit direct peek/poke** - ✅ FUNKTIONIERT (funcLen = 1)
4. **irAddInstrDirect mit korrekten Offsets** - ✅ FUNKTIONIERT
5. **IR-Lowering funktioniert jetzt!** - ✅ ABGESCHLOSSEN
   - lowerBlock/lowerStmt/lowerReturn generieren jetzt IR Instructions
   - instrLen = 4 (statt vorher 0)
   - IR Module zeigt: funcLen=1, instrLen=4

6. **emit() VTable Bug fixen** - ❌ LETZTER BUG
   - Methodenaufrufe in emit_x86.lyx werden nicht ausgeführt
   - Der emit() Body wird nicht ausgeführt obwohl die Methode aufgerufen wird
   - Das ist der letzte verbleibende Bug für die Codegenerierung

---

## Fortschritt

**IR-Lowering funktioniert jetzt!**
```
irMod instrLen after lower = 4
lowerBlock: first stmt=3
lowerStmt: stmt=3 kind=23
lowerExpr: expr=4 kind=40
lowerExpr: found NK_LIT_INT
lowerExpr: dest=1 val=0
```

**Letzter Bug**: emit() VTable Problem - muss noch gefixt werden.

---

## Test-Kommandos

```bash
# S0 kompiliert S1
cd /home/andreas/PhpstormProjects/aurum
./lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_test

# S1 kompiliert Test-File
/tmp/lyxc_test tests/lyx/misc/simple_test.lyx -o /tmp/test_out

# Check output
ls -la /tmp/test_out
file /tmp/test_out

# Debug output
/tmp/lyxc_test tests/lyx/misc/simple_test.lyx -o /tmp/test_out 2>&1 | grep -E "(addFunc|emit:|codeSize)"
```

---

## Letzte Änderungen

- **+irModule.addFunc()**: IRLower verwendet jetzt IRModule-Objekt für Methodenaufrufe
- **+irModule Feld**: IRLower hat jetzt irModule: IRModule Referenz
- **+init Parameter**: IRLower.init() nimmt jetzt irMod: IRModule als vierten Parameter

---

## Offene Fragen

1. Warum werden Methoden-Inhalte nicht ausgeführt obwohl Methoden aufgerufen werden?
2. Warum funktionieren Feld-Zuweisungen in S1→S2 nicht?
3. Warum gibt return den falschen Wert zurück?