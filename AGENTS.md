# AGENTS.md – Lyx Compiler (Self-Hosted)

Lyx ist ein nativer Compiler für die Sprache **Lyx**, vollständig in **Lyx selbst** geschrieben
(100% self-hosted, singularitätsverifiziert).
Zielplattform: **Linux x86_64, ELF64**, ohne libc (reine Syscalls).
Spezifikation: `SPEC.md` (Architektur, Roadmap) · `ebnf.md` (Grammatik, Typen, Semantik).

## Build-Befehle

```bash
# Compiler aus Seed-Binary bauen (src/lyxc_bootstrap → src/lyxc.lyx → lyxc)
make build

# Selbstkompilierung (lyxc kompiliert sich selbst)
make bootstrap

# Singularitätsprüfung: S3 == S4 (bit-für-bit identisch)
make singularity
```

Direkt mit dem Seed-Binary:

```bash
src/lyxc_bootstrap src/lyxc.lyx -o lyxc
```

## Tests

```bash
# Integrationstest (examples/hello.lyx kompilieren und ausführen)
make test

# Erzeugtes Binary testen
./lyxc examples/hello.lyx -o /tmp/hello && /tmp/hello
echo $?
```

## Compiler-Quellstruktur

Der gesamte Compiler ist in `src/` als Lyx-Quellcode vorhanden:

```
src/
  lyxc.lyx              # Hauptprogramm (Entry Point, Pipeline)
  lexer.lyx             # Tokenizer
  parser.lyx            # Recursive-Descent Parser
  sema.lyx              # Semantische Analyse
  ir.lyx                # IR-Definition (3-Address-Code)
  ir_lower.lyx          # AST → IR
  ir_optimize.lyx       # IR-Optimierungen
  ir_inline.lyx         # IR-Inlining
  ir_call_graph.lyx     # Aufrufgraph-Analyse
  codegen_x86.lyx       # x86_64 ELF64 Code-Generierung
  dwarf_gen.lyx         # DWARF4 Debug-Info
  lyu_writer.lyx        # .lyu Pre-Compiled Unit Ausgabe
  lyu_reader.lyx        # .lyu Unit-Info Anzeige (--unit-info)
  lyxc_bootstrap        # Seed-Binary (singularitätsverifiziert)
```

## Debug- und Überprüfungswerkzeuge

### 1. Statische Analyse (`--static-analysis`)

```bash
./lyxc test.lyx -o test --static-analysis
```

| Pass | Erkennt | Wann nutzen |
|------|---------|-------------|
| Data-Flow-Analyse | Def-Use-Ketten für alle Variablen | Nach neuen IR-Ops |
| Live-Variable-Analyse | Ungenutzte Variablen (Warnungen) | Nach Parser-Erweiterungen |
| Constant-Propagation | Bekannte Konstanten durch irAdd/irSub/irMul | Nach Optimierer-Änderungen |
| Null-Pointer-Analyse | Potenzielle Null-Dereferenzierungen | Nach neuen Pointer-Ops |
| Array-Bounds-Analyse | Statische Index-Safety (SAFE/UNVERIFIED) | Nach Array-Features |
| Terminierungs-Analyse | Unbounded Loops, rekursive Calls | Nach Control-Flow-Änderungen |
| Stack-Nutzungs-Analyse | Worst-Case-Stack pro Funktion | Nach neuen Builtins |

### 2. MC/DC Coverage (`--mcdc`, `--mcdc-report`)

```bash
./lyxc test.lyx -o test --mcdc --mcdc-report
```

### 3. Assembly Listing (`--asm-listing`)

```bash
./lyxc test.lyx -o test --asm-listing
# Erzeugt: test.lst
```

### 4. AST-Dump (`--ast-dump`)

```bash
./lyxc test.lyx -o test --ast-dump
```

### 5. Symbol-Table (`--symtab-dump`)

```bash
./lyxc test.lyx -o test --symtab-dump
```

### 6. Type-Reasoning (`--type-reasoning`)

```bash
./lyxc test.lyx -o test --type-reasoning
```

### 7. Provenance Tracking (`--provenance`)

```bash
./lyxc test.lyx -o test --provenance
```

### 8. Pre-Compiled Units (`--compile-unit`, `--unit-info`)

```bash
./lyxc --compile-unit std/io.lyx -o std/io.lyu
./lyxc --unit-info std/io.lyu
```

### 9. Call-Graph (`--call-graph`)

```bash
./lyxc test.lyx -o test --call-graph
```

### 10. Map-File (`--map-file`)

```bash
./lyxc test.lyx -o test --map-file
```

## Lyx-Sprachübersicht (Kurzreferenz)

Vollständige Spezifikation: `SPEC.md` und `ebnf.md`.

**Typen**: `int64`, `bool`, `void`, `pchar`, `pchar?`, `f32`, `f64`, `array[N]T`, `Map<K,V>`, `Set<T>`
**Speicherklassen**: `var` (mutable) · `let` (immutable) · `co` (readonly runtime) · `con` (compile-time)
**Builtins**: `exit(code)` · `PrintStr(s)` · `PrintInt(x)` · `PrintFloat(f)` · `Random()` · `RandomSeed(n)`
**Keywords**: `fn var let co con if else while return true false extern unit import pub as array struct class extends new dispose super static self Self private protected panic assert where value virtual override abstract match`
**Zuweisung**: `:=` (nicht `=`)
**Blöcke**: `{ }` (nicht begin/end)
**Operatoren**: `+ - * / %` · `== != < <= > >=` · `&& || !` · `& | ^ ~ << >>` · `?? ?.` · `|>`

## Architektur-Regeln

1. **Frontend ↔ Backend Trennung**: Kein x86-Code im Parser/Sema
2. **IR als Stabilitätsanker**: AST → IR → Maschinencode. Nie AST direkt zu Bytes
3. **ELF64 ohne libc**: `_start` ruft `main()`, dann `sys_exit`
4. **SysV ABI**: Parameter in RDI, RSI, RDX, RCX, R8, R9 · Return in RAX
5. **VMT**: Jede Klasse mit virtual/override erzeugt eine VMT im `.data`-Segment
6. **Compiler-Kompatibilität (self-hosting)**: Kein Lyx-Syntax verwenden, den der Bootstrap-Parser nicht unterstützt
   - `if (expr) != 0` ist OK (ParseExpr/ParsePrimary behandelt das korrekt)
   - `match` darf nicht als Variablenname verwendet werden (ist ein Keyword)

## Git-Konventionen

```
feat(src): neue Compiler-Feature beschreiben
fix(codegen): Off-by-one bei Stack-Alignment korrigieren
refactor(ir): ConstNode von LiteralNode trennen
test(parser): While-Statement-Tests ergänzen
docs: ebnf.md um neue Regeln erweitert
```

- `lyxc` Binary ist in `.gitignore` — wird lokal gebaut
- `src/lyxc_bootstrap` ist das Seed-Binary — ist in git versioniert
- Nach Singularitätsverifikation (`make singularity`) kann das Seed-Binary aktualisiert werden

## Checkliste vor Code-Änderungen

1. `ebnf.md` und `SPEC.md` lesen — Grammatik und Architektur verstehen
2. Compiler-Kompatibilität (self-hosting) beachten (keine Match-Variable, kein `(expr) op` als if-Bedingung ohne innere Parens)
3. Änderungen an `src/` immer mit `make singularity` verifizieren

## Checkliste nach Code-Änderungen

1. **Compiler baut**: `make build` ohne Fehler
2. **Singularität**: `make singularity` → S3 == S4
3. **Statische Analyse**: `--static-analysis` — 0 Warnungen für neue Features
4. **MC/DC Coverage**: `--mcdc --mcdc-report` — keine Gaps in neuen Branches
5. **Assembly Listing**: `--asm-listing` — Hex-Bytes und IR-Mnemonics prüfen
6. **Integrationstests**: `make test` — alle bestehenden Tests grün
