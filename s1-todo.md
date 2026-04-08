# S1 Bootstrap Compiler - Todo List

## Aktueller Stand (2026-04-08)

### STATUS: Sema funktioniert, emitX86_64 gibt 1 zurück

Der Compiler durchläuft jetzt alle Stages bis auf Binary Writing:

| Stage | Status | Notes |
|-------|--------|-------|
| Parser | ✅ | Funktioniert |
| Sema | ✅ | Funktioniert jetzt! |
| Linter | ⚠️ | Übersprungen |
| IR Generation | ✅ | Funktioniert |
| Optimization | ⚠️ | Übersprungen |
| Code Generation | ⚠️ | emitX86 gibt codeBuf=1 zurück |
| Binary Writing | ❌ | Bekommt ungültigen codeBuffer |

## Gelöste Issues

| Issue | Status | Lösung |
|-------|--------|--------|
| CLI-Parsing (inputFile=1) | ✅ | Flat fields statt struct |
| Free() Crash | ✅ | Inline map_free |
| astRoot Parser (Parse=0) | ✅ | Fallback zu parser.nodes |
| IR-Lowering | ✅ | funktioniert |
| Sema.Check | ✅ | astRoot handling fixed |

## Offene Bugs

### emitX86_64 ❌ OFFEN
- **Problem:** Emitx86.getCodeBuf() gibt 1 zurück statt Buffer-Adresse
- **Location:** bootstrap/backend/x86_64/emit_x86.lyx
- **Symptom:** writeBinary() bekommt code=1, gibt false zurück
- **Ursache:** S1 berechnet class field offsets falsch

**Debug-Ergebnisse:**
```
emitter.codeBuf (before init) = CRASH (Segfault)
emitter.codeBuf (after init) = ?
getCodeBuf() returns 1
```

Das Problem ist, dass S1 die class field offsets in Emitx86 falsch berechnet. Die Methode `getCodeBuf()` gibt `self.codeBuf` zurück, aber `self` zeigt auf die falsche Adresse (oder die offsets sind falsch).

## Nächste Schritte

1. [ ] Debug emitX86_64 - class field offset Berechnung
2. [ ] Linter wieder aktivieren
3. [ ] Selbst-Kompilierung testen (Singularität)

## Test-Befehle

```bash
# S1 bauen
./lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_new

# Testen (Minimal-File)
timeout 30 /tmp/lyxc_new test_min_literal.lyx -o /tmp/test_out

# Debug-Ausgabe
timeout 30 /tmp/lyxc_new test_min_literal.lyx -o /tmp/test_out 2>&1
```

## Letzte Commits

- d8b138d fix(bootstrap): CLI parsing and memory management
- 7df84ea cleanup(bootstrap): remove debug output from lyxc.lyx  
- 198208d fix(bootstrap): enable full pipeline stages
- 8dc625f fix(bootstrap): enable Sema, add s1-todo.md