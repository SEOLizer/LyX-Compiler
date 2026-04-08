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

## Debugging-Status

### Sema.Check ✅ GELÖST
- Problem war astRoot = 0 handling
- Sema läuft jetzt durch

### emitX86_64 ❌ OFFEN
- Emitx86.getCodeBuf() gibt 1 zurück statt Buffer-Adresse
- mmap in Emitx86.init() scheint zu funktionieren
- Problem liegt in S1's Behandlung von class fields
- Greift man auf emitter.codeBuf zu (bevor init), stürzt es ab
- Nach init sollte codeBuf正确的 sein, aber getCodeBuf() gibt 1 zurück

**Letzter Test:**
```
emitter.codeBuf (before init) = CRASH (Segfault)
emitter.codeBuf (after init) = ?
getCodeBuf() returns 1
```

Das Problem scheint zu sein, dass S1 die class field offsets falsch berechnet.

## Nächste Schritte

1. [ ] Debug class field offset calculation in Emitx86
2. [ ] Linter wieder aktivieren
3. [ ] Selbst-Kompilierung testen (Singularität)