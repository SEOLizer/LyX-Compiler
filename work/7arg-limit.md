# 7-Argument-Einschränkung im Lyx-Codegen

## Ursache

Auf x86-64 (SysV ABI) werden die ersten 6 Argumente in Registern übergeben:

| Position | Register |
|----------|----------|
| Arg 0    | `rdi`    |
| Arg 1    | `rsi`    |
| Arg 2    | `rdx`    |
| Arg 3    | `rcx`    |
| Arg 4    | `r8`     |
| Arg 5    | `r9`     |
| Arg 6+   | Stack    |

Bei Lyx-**Methoden** belegt `self` implizit `rdi` (Arg 0). Damit verbleiben nur 5 Register
für explizite Parameter — **maximal 5 explizite Parameter pro Methode** (6 gesamt).

## Das konkrete Problem im Codegen

Beide betroffenen Dateien sind identisch (je 7996 Zeilen):
- `src/codegen_x86.lyx`
- `bootstrap/codegen_x86.lyx`

### Call-Site (`cg_genCall`, Zeile ~3133)

Aktuell werden alle Args in Reihenfolge gepusht, dann die obersten 6 gepoppt:

```
// Stack nach dem Pushen (top → bottom): argN, argN-1, ..., arg1, arg0
pop r9  = argN      ← FALSCH — sollte arg5 sein
pop r8  = argN-1    ← FALSCH — sollte arg4 sein
...
pop rdi = argN-5    ← FALSCH — sollte arg0 (= self) sein
// arg0..argN-6 bleiben als Datenmüll auf dem Stack
```

### Callee-Side (`cg_genMethodDecl` Z. 2439, `cg_genFuncDecl` Z. 5199)

```
while (param != -1 && paramIdx < 6) { ... }
```

Parameter ab Index 6 werden schlicht ignoriert — sie werden nie gespillt.

## Möglicher Fix

### Callee-Side — einfach (~15 Zeilen)

`while`-Bedingung auf unbegrenzt, für `paramIdx >= 6` (Methoden: `>= 5`) statt
`spillR9` ein Lade-Pattern aus dem Caller-Frame:

```
mov rax, [rbp + (paramIdx - 5) * 8 + 16]
mov [rbp - off], rax
```

### Call-Site — das eigentliche Problem (~80 Zeilen)

SysV ABI verlangt für 7+ Args:
- `rdi..r9` = arg0..arg5
- `[rsp+0]` vor dem `call` = arg6 (erster Stack-Arg)
- `[rsp+8]` = arg7, usw.

Die saubere Lösung erfordert zweigeteilte Evaluierung:
1. Extra-Args (arg6..argN) in **umgekehrter** Reihenfolge pushen (argN zuerst, arg6 zuletzt)
2. Reg-Args (arg0..5) normal pushen und in Register poppen

**Problem:** Die Args sind eine einfach verkettete Liste — rückwärts traversieren geht nicht
direkt. Benötigt entweder Rekursion (rdi-clobber-Bug 18 lauert) oder einen temporären
Puffer via `mmap`.

## Aufwand

| Teil | Komplexität | Geschätzte Zeit |
|------|-------------|-----------------|
| Callee-Side (spill extra params) | Gering | ~2h |
| Call-Site (push in richtiger Reihenfolge) | Mittel-hoch | ~1-2 Tage |
| Tests | — | ~0.5 Tage |
| **Gesamt** | | **~2-3 Tage** |

Da `src/` und `bootstrap/` identisch sind, müsste der Fix synchron in beiden Dateien
eingepflegt werden.

## Bewertung: nicht empfehlenswert

- **Selten nötig** — 5 explizite Parameter reichen für fast alles; mehr ist oft ein Designsignal
- **Workaround existiert**: Parameter in eine Hilfsstruktur auslagern oder aufteilen
- **FPC-kompilierter lyxc** geht über die IR-Schicht und ist nicht betroffen — nur Lyx-Programme
  (kompiliert durch lyxc) unterliegen der Einschränkung
- Zeit ist woanders besser investiert, solange kein konkreter Bedarf besteht
