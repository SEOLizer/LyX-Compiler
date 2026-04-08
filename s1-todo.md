# S1 Bootstrap Compiler - Todo List

## Aktueller Stand (2026-04-08)

Der S1 Bootstrap-Compiler kann jetzt den gesamten Pipeline durchlaufen:
- Parser ✅
- IR Generation ✅  
- Code Generation ✅
- Binary Writing ✅

Aber es gibt noch Bugs, die behoben werden müssen.

## Offene Bugs

### 1. Sema.Check Crash (hohe Priorität)
- **Problem:** Sema.Check() crashed bei Aufruf
- **Location:** bootstrap/sema.lyx
- **Symptom:** Speicherzugriffsfehler beim Betreten von Pass1
- **Ursache:** Unklar - braucht weitere Debugging
- **Workaround:** Sema ist aktuell übersprungen

### 2. emitX86_64 gibt 1 zurück (hohe Priorität)
- **Problem:** Emitx86.getCodeBuf() gibt 1 statt gültiger Buffer-Adresse zurück
- **Location:** bootstrap/backend/x86_64/emit_x86.lyx
- **Symptom:** writeBinary() bekommt code=1, gibt false zurück
- **Ergebnis:** Output-Datei ist 0 Bytes

### 3. Linter Crash
- **Problem:** Linter stürzt ab
- **Location:** bootstrap/frontend/linter.lyx
- **Ursache:** Unbekannt
- **Workaround:** Linting ist übersprungen

## Implementierte Fixes (bereits committed)

1. **CLI-Parsing Bug behoben**
   - Problem: inputFile wurde zu 1 statt gültiger Pointer
   - Lösung: Flat fields statt struct in CompilerConfig

2. **Free() Crash behoben**
   - Problem: map_free() stürzte ab
   - Lösung: Inline map_free im main() statt Methodenaufruf

3. **astRoot Parser-Problem**
   - Problem: Parse() gibt 0 zurück aber nodes existieren
   - Lösung: Fallback zu parser.nodes / Index 0

4. **IR-Lowering funktioniert jetzt**
   - IRLower.lowerModule() wird erfolgreich aufgerufen

## Nächste Schritte

1. [ ] Debug emitX86_64 - warum gibt getCodeBuf() 1 zurück?
2. [ ] Debug Sema.Check() - warum crashed Pass1?
3. [ ] Linter wieder aktivieren
4. [ ] Selbst-Kompilierung testen (Singularität)

## Test-Befehle

```bash
# S1 bauen
./lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_new

# Testen (Minimal-File)
timeout 30 /tmp/lyxc_new test_min_literal.lyx -o /tmp/test_out

# S1 Selbst-Kompilierung (der eigentliche Test)
timeout 30 /tmp/lyxc_new bootstrap/lyxc.lyx -o /tmp/lyxc_s2
```

## Notizen

- Commit-History:
  - d8b138d fix(bootstrap): CLI parsing and memory management
  - 7df84ea cleanup(bootstrap): remove debug output from lyxc.lyx  
  - 198208d fix(bootstrap): enable full pipeline stages