# Lyx Bootstrap Compiler – Vollständiger Support-Fahrplan

**Stand:** 2026-05-21  
**Ziel:** Volle EBNF-Abdeckung + 100 % Testbestehen im `tests/lyx/`-Verzeichnis  
**Basis:** `src/lyxc.lyx` (self-hosted x86_64 Bootstrap-Compiler)

---

## Aktueller Teststatus

| Kategorie | Anzahl |
|-----------|--------|
| ✅ Passing (`tests/lyx/`) | **85** |
| 💥 Crash (SIGSEGV) | **6** |
| ❌ Compile-Fehler (echte Bugs) | **~30** |
| ⏭ Compile-Fehler (fehlende ext. Libs) | **~83** |
| ✅ Snapshot-Tests (`tests/snapshot/`) | **10 / 10** |
| ✅ Singularität (S3 == S4) | **bestätigt** |

**Echte offene Bugs (Compile-Fehler ohne externe Abhängigkeiten):**

| Fehler | Betroffene Tests |
|--------|-----------------|
| `=` nicht als Statement-Zuweisung | `operators/test_inc_dec`, überall wo `x = expr;` steht |
| `++`/`--` nicht implementiert | `operators/test_inc_dec` |
| `@`-Attribute vor `fn` nicht geparst | `energy/*`, Safety-Tests |
| `Map<K,V>` / `Set<T>` nicht in ParseType | `map_set/test_map_get`, viele `audio/*` |
| `parallel Array<T>` nicht geparst | `simd/*` |
| `static` lokal nicht implementiert | `globals/static_test`, `globals/test_static` |
| `push/pop` sind Stubs (kein echter Heap) | `dynarray/test_dyn_index`, `test_append` |
| Fehlende Builtins in Sema | `arm64/test_poke_simple` (`write_raw`), `io/*` |
| `|> fn(?, arg)` Pipe mit Platzhalter | `pipe/test_pipe_args` |
| Import-Pfad-Auflösung (`std.io` → Datei) | `stdlib/test_debug_cast4`, `import/*` |

---

## Fahrplan: Work Packages WP-BC-52 bis WP-BC-67

---

### WP-BC-52 – `=` als Statement-Zuweisung

**Priorität:** 🔴 Hoch  
**Aufwand:** 0,5 Tage  
**EBNF-Referenz:** `AssignStmt = LValue ":=" Expr ";"` → Erweiterung auf `"=" | ":="`

**Problem:**  
`ParseStmt` akzeptiert nach einem Ausdruck nur `:=` (TK_ASSIGN) als Zuweisung.  
`x = x + 1;` verwendet `=` (TK_EQ1) und wird als Fehler behandelt.

**Lösung:**
- `src/parser.lyx` → `ParseStmt()`: nach `ParseExpr()` auch `TK_EQ1` als Zuweisung akzeptieren
- `ParseVarDecl` akzeptiert `=` bereits – nur in Statements fehlt es
- Auch `+=`, `-=`, `*=` etc. könnten hier langfristig ergänzt werden (eigene WP)

**Behebt:**
- `operators/test_inc_dec` (nutzt `x = 5`, `x = x + 1`)
- Alle Tests, die `=` als Statement-Zuweisung verwenden

**Implementierung:**
```lyx
// ParseStmt: nach ParseExpr()
var isAssign: int64 := self.Match(TK_ASSIGN);
if (isAssign == 0) { isAssign := self.Match(TK_EQ1); }
if (isAssign != 0) {
  var rhs: int64 := self.ParseExpr();
  self.Match(TK_SEMI);
  var n: int64 := self._alloc(NK_ASSIGN, ti);
  self._sc0(n, expr); self._sc1(n, rhs);
  return n;
}
```

---

### WP-BC-53 – `++`/`--` IncDecStmt

**Priorität:** 🔴 Hoch  
**Aufwand:** 0,5 Tage  
**EBNF-Referenz:** `IncDecStmt = LValue ( "++" | "--" ) ";"` → Desugaring zu `:= x ± 1`

**Problem:**  
`TK_PLUSPLUS` (75) und `TK_MINMIN` (76) existieren im Lexer, werden aber in `ParseStmt` ignoriert.  
`x++;` und `arr[i]--;` führen zu Parse-Fehler.

**Lösung:**
- `src/parser.lyx` → `ParseStmt()`: nach `ParseExpr()` auf `TK_PLUSPLUS` / `TK_MINMIN` prüfen
- Desugaring: `x++ → x := x + 1`, `x-- → x := x - 1`
- LValue kann Ident, Feldpfad (`a.b`) oder Index (`arr[i]`) sein

**Behebt:**
- `operators/test_inc_dec` (nach WP-BC-52 vollständig)

**Implementierung:**
```lyx
if (self.Match(TK_PLUSPLUS) != 0 || self.Match(TK_MINMIN) != 0) {
  // desugar: expr++ → NK_ASSIGN(expr, NK_BINOP(expr, 1, +/-))
  ...
}
```

---

### WP-BC-54 – `@`-Funktionsattribute (energy, dal, critical, wcet, stack_limit, integrity)

**Priorität:** 🔴 Hoch  
**Aufwand:** 1 Tag  
**EBNF-Referenz:** `FuncAttr = EnergyAttr | DALAttr | CriticalAttr | WCETAttr | StackLimitAttr | IntegrityAttr`

**Problem:**  
`TK_AT` (111) ist tokenisiert, aber das Top-Level-Parse (`Parse()`) und `ParseStmt` kennen `@` nicht.  
`@energy(3) fn main() ...` → `Parse error: unexpected top-level token`

**Lösung:**
- `src/parser.lyx` → `Parse()`: bei `TK_AT` `_parseFuncAttrs()` aufrufen, dann `ParseFuncDecl`
- `_parseFuncAttrs()`: liest `@ident(args)` wiederholend; speichert in NK_FUNC_DECL iVal-Bits
- Attributnamen: `energy`, `dal`, `critical`, `wcet`, `stack_limit`, `integrity`, `redundant`, `flight_crit`
- Sema: ungültige Kombinationen als Warning melden
- Codegen: Attribute in IR-Metadaten; `@energy` → optional Unroll-Hinweis (aktuell no-op ok)

**Behebt:**
- `energy/test_energy_simple` und alle Tests mit `@`-Attributen vor `fn`

---

### WP-BC-55 – Fehlende Sema-Builtins registrieren + Codegen-Stubs

**Priorität:** 🔴 Hoch  
**Aufwand:** 0,5 Tage  
**EBNF-Referenz:** §8 Builtin-Funktionen

**Problem:**  
Mehrere Builtins sind im Codegen implementiert aber nicht in der Sema registriert.

**Fehlend in Sema (`_registerBuiltins`):**

| Builtin | Beschreibung |
|---------|-------------|
| `write_raw` | `sys_write(fd, ptr, n)` – rohe Bytes schreiben |
| `sys_read` | `sys_read(fd, ptr, n)` – rohe Bytes lesen |
| `PrintStrLn` | `PrintStr` + `"\n"` |
| `EPrintStr` | `write(2, ...)` – stderr |
| `EPrintStrLn` | stderr + Newline |
| `EPrintInt` | Integer auf stderr |
| `StrReplace` | String-Ersetzung |
| `StrToInt` | String → int64 |
| `Sqrt`, `Abs`, `Min`, `Max` | Math-Builtins |
| `memcpy`, `memset` | Speicher-Ops |
| `lseek`, `close` | File-IO |
| `VerifyIntegrity` | TMR-Check (aerospace) |

**Lösung:** `src/sema.lyx` → `_registerBuiltins()`: alle oben fehlenden ergänzen.  
Codegen: für fehlende Codepfade in `cg_genCall` passende x86-64 Sequenzen emittieren.

**Behebt:**
- `arm64/test_poke_simple` (`write_raw`)
- `arm64/test_str_basics`, `arm64/test_str_builtins`
- Alle Tests, die `EPrintStr*`, `StrToInt`, `Sqrt` etc. verwenden

---

### WP-BC-56 – `Map<K,V>` und `Set<T>` Typ-Parsing + Codegen

**Priorität:** 🟠 Mittel  
**Aufwand:** 2 Tage  
**EBNF-Referenz:** `Type = ... | "Map" "<" Type "," Type ">" | "Set" "<" Type ">"`

**Problem:**  
`TK_MAP` (62) und `TK_SET` (63) sind tokenisiert, aber `ParseType` hat keinen Handler dafür.  
`var scores: Map<int64, int64>` → Parse-Fehler `expected token 83 (>), got 2 (int-literal)`.

**Lösung:**

*Parser (`src/parser.lyx`):*
- `ParseType()`: Branch für `TK_MAP` → consume `<`, Parse KeyType, `,`, Parse ValType, `>`; alloc `NK_TYPE_MAP`
- `ParseType()`: Branch für `TK_SET` → consume `<`, Parse ElemType, `>`; alloc `NK_TYPE_SET`

*Sema (`src/sema.lyx`):*
- `ResolveType()`: `NK_TYPE_MAP → TY_INT64` (Pointer-Typ, wie Array)
- `_p2Decl` Map-Literal-Prüfung

*Codegen (`src/codegen_x86.lyx`):*
- `NK_TYPE_MAP`/`NK_TYPE_SET` in Var-Deklaration: `localIsArray` Flag setzen
- Map-Literal `{k: v, ...}`: mmap + lineare Einträge schreiben
- `map[key]` Indexzugriff: lineare Suche + Wert zurückgeben
- `len(map)`: Header-Länge lesen
- `in`-Operator: Teilimplementierung

**Behebt:**
- `map_set/test_map_get`
- Alle Audio-Tests die Map für Konfiguration nutzen (wenn korrekte Typen vorliegen)

---

### WP-BC-57 – `parallel Array<T>` SIMD-Typ

**Priorität:** 🟠 Mittel  
**Aufwand:** 3 Tage  
**EBNF-Referenz:** `Type = ... | "parallel" "Array" "<" Type ">"` + SIMD-Ops

**Problem:**  
`TK_PARALLEL` (57) existiert im Lexer, wird aber nirgends als Typ oder Ausdruck verarbeitet.  
`let vec: parallel Array<int64>(4)` → Parse-Fehler.

**Lösung:**

*Parser:*
- `ParseType()`: `TK_PARALLEL` → erwarte `Array`, `<`, Typ, `>` → alloc `NK_TYPE_SIMD_ARRAY`
- `ParsePrimary()`: `TK_PARALLEL` → erwarte `Array<T>(N)` → alloc `NK_SIMD_NEW`

*Codegen:*
- `NK_SIMD_NEW`: mmap-Allokation mit 16-Byte-Alignment (SSE2-konform)
- Array-Indexzugriff: `movdqu` / `movq` je nach Element-Typ
- SIMD-Binäroperatoren (`+`, `-`, `*`): `paddd`, `psubd`, `pmulld` (SSE4.1) oder Fallback-Loops

**Behebt:**
- `simd/simd_basic_test`, `simd/vector_basic_test`, `simd/vector_loop_test`

---

### WP-BC-58 – Echte Dynamic Array Implementation (push/pop/cap)

**Priorität:** 🟠 Mittel  
**Aufwand:** 2 Tage  
**EBNF-Referenz:** Dynamic Arrays §5.4 – `push`, `pop`, `len`, `cap`, `free`

**Problem:**  
`push(arr, val)` und `pop(arr)` sind aktuell No-Op-Stubs in `cg_genCall`.  
Tests wie `dynarray/test_dyn_index` compilieren aber crachen zur Laufzeit.

**Aktuelles Array-Layout:**
```
[rsp+0]:  cap  (int64)
[rsp+8]:  len  (int64)
[rsp+16]: elem[0]
[rsp+24]: elem[1]
...
```
Das ist das Stack-Layout für Array-Literale. Für echte dynamische Arrays brauchen wir Heap-Allokation.

**Lösung:**

*`push(arr, val)` Codegen:*
```
1. arr-Pointer (rax) laden
2. len = peek64(rax+8), cap = peek64(rax)
3. if len < cap: peek64(rax+16+len*8) := val; poke64(rax+8, len+1); done
4. else: new_cap = cap*2; new_buf = mmap(0, new_cap*8+16, ...)
          memcpy(new_buf, arr, cap*8+16)
          poke64(arr, new_buf)  [Pointer-Update im lokalen Stack-Slot]
          poke64(new_buf, new_cap)
          poke64(new_buf+8, len+1)
          poke64(new_buf+16+len*8, val)
```

*`pop(arr)` Codegen:*
```
len = peek64(arr+8)
if len > 0: val = peek64(arr+16+(len-1)*8); poke64(arr+8, len-1); return val
else: return 0
```

*`len(arr)` / `cap(arr)`:* Aus Header lesen (nicht mehr compile-time)  
*`free(arr)`:* `munmap(peek64(arr), peek64(arr)*8+16)` oder nur no-op wenn Stack-allokiert

**Behebt:**
- `dynarray/test_dyn_index` (push + arr[i])
- `dynarray/test_append` (append zwei Arrays)
- `dynarray/test_dyn_double`, `test_dyn_simple`

---

### WP-BC-59 – `unit`-Deklaration

**Priorität:** 🟡 Niedrig-Mittel  
**Aufwand:** 0,5 Tage  
**EBNF-Referenz:** `UnitDecl = [ IntegrityAttr ] "unit" DotPath ";"` als erste Deklaration

**Problem:**  
`TK_UNIT` (28) ist im Lexer definiert, aber `Parse()` hat keinen Handler.  
`unit math.utils;` → `Parse error: unexpected top-level token`.

**Lösung:**
- `Parse()`: `TK_UNIT` → consume unit-Deklaration; parsiere optional `DotPath`; erzeuge `NK_UNIT`-Knoten
- Sema: Unit-Name als Modul-Identifier registrieren (für späteres Namespace-System)
- Codegen: kein Code generiert (compile-time-only)

**Behebt:**
- `stdlib/test_mysql_prepared` (beginnt mit `unit`)
- Jede Datei, die mit `unit x.y;` startet

---

### WP-BC-60 – `static` lokale Variablen

**Priorität:** 🟡 Niedrig-Mittel  
**Aufwand:** 1 Tag  
**EBNF-Referenz:** (implizit) – `static` als Statement-Level-Deklaration

**Problem:**  
`static count: int64 = 42;` innerhalb einer Funktion → Parse-Fehler, da `ParseStmt` `TK_STATIC` nicht kennt.

**Lösung:**
- `ParseStmt()`: `TK_STATIC` → `ParseStaticDecl()` (analog zu `ParseVarDecl`)
- Codegen: Datensegment-Slot allokieren (Name mangling: `_static_<funcname>_<varname>`)
- Sema: als `SYM_VAR` mit globalem Lebenszyklus registrieren
- Top-Level `static`: bereits als `unexpected top-level token` korrekt abgelehnt (kein Bedarf)

**Behebt:**
- `globals/static_test`, `globals/test_static`

---

### WP-BC-61 – Hex / Binär / Oktal Integer-Literale

**Priorität:** 🟡 Niedrig-Mittel  
**Aufwand:** 1 Tag  
**EBNF-Referenz:** `HexLiteral = ('0x'|'0X'|'$') hex+` etc.

**Problem:**  
Nur Dezimal-Literale werden im Lexer unterstützt. `0xFF`, `0b1010`, `0o77`, `$FF`, `%1010`, `&77` und Unterstriche (`1_000_000`) werden nicht erkannt.

**Lösung:**
- `src/lexer.lyx` → Integer-Literal-Parser: Präfix-Erkennung + Basis-Konvertierung
- Unterstriche in Literalen ignorieren
- Ergebnis intern immer `int64` (wie Dezimal)

**Behebt:**
- Tests mit Hex-Konstanten (z. B. Bitmasken, poke8-Werte)
- `arm64/*` Tests, die `0x`-Konstanten verwenden

---

### WP-BC-62 – `|>` Pipe mit Platzhalter-Argument

**Priorität:** 🟡 Niedrig-Mittel  
**Aufwand:** 1 Tag  
**EBNF-Referenz:** Pipe-Operator `x |> f(?, arg)` → `f(x, arg)`

**Problem:**  
`ParsePipe()` unterstützt nur `x |> funcname` (LHS als erstes Argument).  
`5 |> add(?, 3)` → Parse-Fehler bei `?`.

**Lösung:**
- Lexer: `?` als `TK_QUESTION` bereits vorhanden (Null-Safety)
- `ParsePipe()`: Nach `funcname` optional `(` prüfen; `?` als Platzhalter für LHS einsetzen
- Desugaring: `x |> f(?, y, z)` → `f(x, y, z)` zur Parse-Zeit

**Behebt:**
- `pipe/test_pipe_args`

---

### WP-BC-63 – `in`-Operator für Map/Set

**Priorität:** 🟡 Niedrig  
**Aufwand:** 1 Tag  
**EBNF-Referenz:** `InExpr = Expr "in" Expr`

**Problem:**  
`key in map` ist in der EBNF definiert, aber `ParseExpr` kennt kein `in`-Token.

**Lösung:**
- Lexer: `in` als Keyword (TK_IN) ergänzen
- Parser: `ParseNullCoal()` oder eigene `ParseIn()` Ebene einführen
- Codegen: lineare Suche durch Map/Set-Header, bool-Ergebnis in rax

**Behebt:**
- Map/Set-Mitgliedschaftstests

---

### WP-BC-64 – String-Verkettung `+` für `pchar`

**Priorität:** 🟡 Niedrig  
**Aufwand:** 0,5 Tage  
**EBNF-Referenz:** `"+" bei pchar + pchar → StrConcat`

**Problem:**  
`"Hello" + " World"` löst keinen Fehler aus, da `ParseExpr` `+` auf int64 addiert.  
Für `pchar`-Typen müsste `StrConcat` aufgerufen werden.

**Lösung:**
- Sema: bei `NK_BINOP(+)` mit beiden Operanden vom Typ `TY_PCHAR` → Typ `TY_PCHAR` zurückgeben
- Codegen: bei `NK_BINOP(+)` mit pchar-Typen → `cg_emitStrConcat()` aufrufen (Builtin-Call)

**Behebt:**
- String-Verkettungs-Tests

---

### WP-BC-65 – Import-Pfad-Auflösung (std.io → `std/io.lyu`)

**Priorität:** 🟠 Mittel  
**Aufwand:** 1,5 Tage  
**EBNF-Referenz:** `ImportDecl = "import" DotPath ";"` → Datei-Lookup

**Problem:**  
`import std.io;` wird korrekt geparst (`std.io` als Import-Name), aber der Codegen sucht  
`std/io.lyx` relativ zum aktuellen Verzeichnis. Die precompilierten `.lyu`-Dateien liegen unter  
`/usr/local/lib/lyx/units/std/io.lyu` oder ähnlich.

**Lösung:**
- `cg_processImport()`: Suchpfad-Liste abarbeiten (CWD, `--include-path`, `/usr/local/lib/lyx/units/`)
- Erst `.lyu` (precompiled) suchen, dann `.lyx` (source)
- Fehler nur wenn beide nicht gefunden

**Behebt:**
- `stdlib/test_debug_cast4` (`import std.io`)
- Alle Tests mit `import std.*` oder `import data.*`

---

### WP-BC-66 – Vollständige Bootstrap-Modul-Tests

**Priorität:** 🟠 Mittel  
**Aufwand:** 3 Tage  
**Abhängigkeit:** WP-BC-65

**Problem:**  
`bootstrap/test_lexer` importiert `bootstrap.lexer` (= `src/lexer.lyx`).  
Die importierten Labels (Lexer_Init etc.) werden nicht in die Hauptlabel-Tabelle gemergt.  
Patches auf importierte Symbole bleiben ungelöst → `int3`-Sprünge → SIGSEGV.

**Lösung:**
- `cg_processImport()`: Labels aus importierten Modulen in eine gemeinsame Label-Tabelle mergen
- Namespace-Präfix für importierte Labels (z. B. `bootstrap.lexer.Init`)
- Patches nach vollständigem Import-Graph auflösen (Post-Order)

**Behebt:**
- `bootstrap/test_lexer`, `bootstrap/test_parser`, `bootstrap/test_sema`, `bootstrap/test_codegen`

---

### WP-BC-67 – Snapshot-Test-Erweiterung auf 25+ Tests

**Priorität:** 🟡 Niedrig  
**Aufwand:** 1 Tag  
**Abhängigkeit:** WP-BC-52 bis WP-BC-56

**Ziel:** Für jedes neu implementierte Feature einen Snapshot-Test anlegen.

**Neue Tests (Vorschlag):**

| Name | Feature |
|------|---------|
| `11_incdec` | `++` / `--` Statements |
| `12_eq_assign` | `=` als Zuweisung |
| `13_dynarray` | push / pop / len / cap |
| `14_map` | Map<K,V> erstellen + abfragen |
| `15_pipe_placeholder` | `|> f(?, arg)` |
| `16_hex_literals` | `0xFF`, `0b1010`, `0o77` |
| `17_static_local` | `static` lokale Variable |
| `18_string_concat` | `pchar + pchar` |
| `19_energy_attr` | `@energy(3) fn` |
| `20_parallel_array` | SIMD Array Grundoperationen |

---

## Prioritäten-Matrix

| WP | Feature | Aufwand | Tests behoben | Priorität |
|----|---------|---------|---------------|-----------|
| WP-BC-52 | `=` Zuweisung | 0,5 T | ~10 | 🔴 P1 |
| WP-BC-53 | `++`/`--` | 0,5 T | 1+ | 🔴 P1 |
| WP-BC-54 | `@`-Attribute | 1 T | ~15 | 🔴 P1 |
| WP-BC-55 | Fehlende Builtins | 0,5 T | ~20 | 🔴 P1 |
| WP-BC-56 | `Map<K,V>` Parsing | 2 T | ~15 | 🟠 P2 |
| WP-BC-57 | `parallel Array` SIMD | 3 T | ~8 | 🟠 P2 |
| WP-BC-58 | Echte Dynamic Arrays | 2 T | ~6 | 🟠 P2 |
| WP-BC-59 | `unit`-Deklaration | 0,5 T | ~5 | 🟡 P3 |
| WP-BC-60 | `static` Locals | 1 T | 2 | 🟡 P3 |
| WP-BC-61 | Hex/Binär/Oktal Lit. | 1 T | ~8 | 🟡 P3 |
| WP-BC-62 | Pipe Platzhalter | 1 T | 1 | 🟡 P3 |
| WP-BC-63 | `in`-Operator | 1 T | ~3 | 🟡 P3 |
| WP-BC-64 | String `+` | 0,5 T | ~5 | 🟡 P3 |
| WP-BC-65 | Import-Pfad-Auflösung | 1,5 T | ~10 | 🟠 P2 |
| WP-BC-66 | Bootstrap-Modul-Tests | 3 T | 4 | 🟠 P2 |
| WP-BC-67 | Snapshot-Erweiterung | 1 T | — | 🟡 P3 |

**Gesamtaufwand:** ~20 Tage  
**Erwartetes Ergebnis nach P1:** ~115+ Tests passing  
**Erwartetes Ergebnis nach P2:** ~150+ Tests passing  
**Erwartetes Ergebnis nach P3:** ~180+ Tests passing (volle EBNF-Abdeckung)

---

## Nicht im Fahrplan (Außerhalb Bootstrap-Compiler)

Die folgenden Features sind in der EBNF spezifiziert und im Pascal-Compiler implementiert,  
aber für den Bootstrap-Compiler (`src/lyxc.lyx`) aktuell nicht geplant:

| Feature | Grund |
|---------|-------|
| ALSA / mpg123 / MySQL Builtins | Externe Bibliotheken, plattformspezifisch |
| DO-178C Compliance-Checks (Sema) | Nur Annotation-Parsing geplant (WP-BC-54) |
| WCET-Analyse | Erfordert separates Analyse-Pass |
| Regex-Literale | Komplex, niedrige Test-Abdeckung |
| `for key, value in map` Iteration | Nach WP-BC-56 + WP-BC-63 |
| GPU / CUDA-Backend | Separates Projekt |
| Windows / macOS / ARM64 Targets | Andere Backends |
| GC / Reference Counting | Kein GC geplant |

---

## Invarianten (immer einhalten)

1. **Singularität:** S3 == S4 nach jedem Commit (`make singularity`)
2. **Snapshot-Tests:** 10/10 nach jedem Commit (`make snapshot`)
3. **Seed-Binary:** `src/lyxc_bootstrap` nach jedem Feature-WP aktualisieren
4. **Branch pro WP:** `feat/wp-bc-NN-kurzbeschreibung`
5. **Keine Stubs:** Neue Funktionen vollständig implementieren oder als Feature-Flag ausblenden

---

*Generiert: 2026-05-21*
