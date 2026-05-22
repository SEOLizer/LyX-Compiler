# Fahrplan: Fehlgeschlagene Tests (Stand 2026-05-22)

Alle verbleibenden FAIL-Tests aus `tests/lyx/` mit Ursache und Lösungsplan.
Abgearbeitet nach Aufwand (einfach → komplex).

---

## Gruppe A — Falsche .expected-Dateien (kein echter Bug im Compiler)

### WP-FIX-01 · Fehlende Zeilenumbrüche in .expected-Dateien
**Tests:** `basic/if_test.lyx`, `panic/test_assert_fail.lyx`, `panic/test_panic_direct.lyx`  
**Status:** FAIL (output mismatch)

**Ursache:** Die Programme geben korrekte Ausgabe aus, aber die `.expected`-Dateien
enden mit `\n`, die Programme aber nicht (kein abschließendes `PrintStr("\n")`
bzw. kein Newline nach `panic`/`assert`-Meldung).

- `basic/if_test.expected`: `greaterbetweenten\n` — Programm gibt `greaterbetweenten` (kein `\n`)
- `panic/test_assert_fail.expected`: `assertion failed\n` — Runtime gibt kein `\n`
- `panic/test_panic_direct.expected`: `test\n` — panic("test") gibt kein `\n`

**Fix:** `.expected`-Dateien ohne trailing `\n` speichern **oder** abschließende
Newlines in den Programmen/Runtime ergänzen. Empfehlung: Runtime-Ausgabe von
`panic`/`assert` mit `\n` terminieren, `if_test.expected` anpassen.

**Aufwand:** 30 min

---

### WP-FIX-02 · Test-Runner-Bug: arm64-Tests als falsch negativ markiert
**Tests:** `arm64/test_str_basics.lyx`, `arm64/test_str_builtins.lyx`,  
`arm64/test_str_concat.lyx`, `arm64/test_str_fromint.lyx`,  
`arm64/test_memory_builtins.lyx`  
**Status:** FAIL (output mismatch) — aber eigentlich PASS

**Ursache:** Der Test-Runner verwendet `result=$(...)`, was trailing `\n` strippt.
Dann `printf "%s" "$result"` vs. `.expected`-Datei (mit `\n`) → diff sieht
Unterschied obwohl der Inhalt identisch ist. Verifiziert: `diff` direkt gibt `exit=0`.

**Fix:** Test-Runner-Skript (oder die ad-hoc-Schleife) anpassen:
`diff -q <(printf "%s\n" "$result")` oder `echo "$result"` statt `printf "%s"`.
Alternativ: `.expected`-Dateien ohne trailing `\n`.

**Aufwand:** 15 min

---

## Gruppe B — Bibliotheks-Units ohne `main` (kein Executable)

### WP-FIX-03 · `precompiled/myunit.lyx` und `data/structmod*.lyx` / `data/pointmod.lyx`
**Tests:** `precompiled/myunit.lyx`, `data/structmod.lyx`, `data/structmod_debug.lyx`,
`data/pointmod.lyx`  
**Status:** FAIL (exit=139, SIGSEGV)

**Ursache:** Diese Dateien sind **Library-Units** (`pub fn ...`, kein `fn main()`).
Der Compiler erzeugt trotzdem ein ELF, dessen `_start` dann `main` aufruft —
aber `main` existiert nicht → ungepatchter Sprung → SIGSEGV.

**Fix:** Zwei Optionen:
1. **Test-Runner**: `.lyx`-Dateien ohne `fn main()` überspringen (als SKIP markieren)
2. **Erwartete Nutzung**: Diese Units werden von anderen Tests importiert — der
   Test-Runner sollte nur Dateien mit `main` direkt ausführen. Scan-Heuristik:
   `grep -q "^fn main" "$f"` vor dem Ausführen.

**Aufwand:** 30 min (Test-Runner-Anpassung)

---

## Gruppe C — Echter Compiler-Bug: pchar `+` Operator

### WP-FIX-04 · `bootstrap/test_parser.lyx` crash in Test 8
**Test:** `tests/lyx/bootstrap/test_parser.lyx`  
**Status:** FAIL (exit=139, SIGSEGV nach Test 7)

**Ursache:** Test 8 baut den Quellstring via `pchar + pchar`:
```lyx
var src: pchar :=
  "pub enum TokenKind { tkEof, tkIdent, tkInt }; " +
  "fn tokenName(k: int64): pchar { " + ...
```
Der Bootstrap-Codegen (`cg_emitBinOp(CGT_PLUS)`) erzeugt für `+` immer
`add rax, rbx` — reine Pointer-Addition statt String-Konkatenation.
Das Ergebnis ist ein ungültiger Zeiger → SIGSEGV beim Zugriff.

**Fix (kurzfristig):** Test 8 umschreiben, `StrConcat(a, b)` statt `a + b` verwenden:
```lyx
var src: pchar := StrConcat(
  StrConcat("pub enum TokenKind { tkEof, tkIdent, tkInt }; ",
            "fn tokenName(k: int64): pchar { "),
  StrConcat("  if (k == 0) { return \"EOF\"; } ",
            "  return \"?\"; }"));
```
**Fix (langfristig):** Im Bootstrap-Codegen (`cg_emitBinOp`) Typ-Erkennung für
pchar-Operanden: wenn beide Seiten pchar sind → StrConcat-Inlining statt `add`.

**Aufwand:** 1h (Kurzfrist) / 4h (Langfrist mit Typ-Inferenz im Bootstrap-CGT)

---

### WP-FIX-05 · `bootstrap/test_codegen.lyx` crash in Test 2
**Test:** `tests/lyx/bootstrap/test_codegen.lyx`  
**Status:** FAIL (exit=139, SIGSEGV nach Test 1)

**Ursache:** Identisches Problem wie WP-FIX-04 — Test 2 baut den Quellstring via `+`:
```lyx
var src: pchar :=
  "fn add(x: int64, y: int64): int64 { return x + y; } " +
  "fn main(): int64 { PrintInt(add(3, 4)); PrintStr(\"\\n\"); return 0; }";
```
`+` erzeugt Pointer-Addition statt StrConcat → SIGSEGV.

**Fix:** Wie WP-FIX-04 — entweder Test umschreiben oder Codegen erweitern.
Wenn WP-FIX-04 (Codegen-Fix) umgesetzt ist, löst sich dieser Test automatisch.

**Aufwand:** 30 min (Testrewrite) oder automatisch nach WP-FIX-04 Langfrist-Fix

---

## Gruppe D — Parser: Fehlende Syntax

### WP-FIX-06 · `pipe/test_pipe_args.lyx` — `|>` mit `?` Placeholder
**Test:** `tests/lyx/pipe/test_pipe_args.lyx`  
**Status:** COMPILE_FAIL (`Parse error at line 6: expected expression`)

**Quellcode:**
```lyx
fn main(): int64 {
  let result: int64 = 5 |> add(?, 3);
  return result;
}
```

**Ursache:** Der Parser kennt zwar `|>` (pipe-Operator), aber `?` als Argument-Platzhalter
ist nicht implementiert. `?` ist kein gültiger Ausdruck → Parse error.

**Fix:** Parser erweitern: im Ausdruck-Parsing `?` als `nkPipePlaceholder`-Node
erkennen. Im Codegen: bei `|>` den Pipe-Ausdruck links auswerten und als das
erste `?`-Argument einsetzen.

**Schritte:**
1. Lexer: `?` als `TK_QUESTION` (falls noch nicht vorhanden)
2. Parser: In `_parsePrimary` — wenn `TK_QUESTION` → `nkPipePlaceholder`-Node
3. Parser: In `_parseBinOp` für `|>` — Aufrufstruktur so bauen, dass `?` durch
   linken Operanden ersetzt wird
4. Codegen: Pipe-Call mit Placeholder korrekt auswerten
5. Sema: `?` nur in Pipe-Kontext zulassen

**Aufwand:** 4–6h

---

## Übersicht

| WP | Test(s) | Ursache | Aufwand | Priorität |
|----|---------|---------|---------|-----------|
| WP-FIX-01 | basic/if_test, panic/* | Fehlende `\n` in .expected | 30 min | Hoch |
| WP-FIX-02 | arm64/* | Test-Runner-Bug (printf strip) | 15 min | Hoch |
| WP-FIX-03 | data/structmod*, precompiled/myunit | Lib-Units ohne main | 30 min | Mittel |
| WP-FIX-04 | bootstrap/test_parser (Test 8) | `pchar + pchar` → add statt StrConcat | 1–4h | Hoch |
| WP-FIX-05 | bootstrap/test_codegen (Test 2) | Identisch WP-FIX-04 | auto | Hoch |
| WP-FIX-06 | pipe/test_pipe_args | `?` Placeholder nicht geparst | 4–6h | Mittel |

**Nicht fixbar ohne Hardware:** audio/* (ALSA/mpg123), stdlib/test_mysql_nopass* (MySQL-Server)

---

## Reihenfolge

1. **WP-FIX-02** (15 min) — Test-Runner-Bug, keine Code-Änderung
2. **WP-FIX-01** (30 min) — .expected-Dateien korrigieren
3. **WP-FIX-03** (30 min) — Test-Runner überspringt Lib-Units
4. **WP-FIX-04 + 05** (1–4h) — pchar `+` Bug, dann test_parser + test_codegen grün
5. **WP-FIX-06** (4–6h) — `|>` Placeholder, eigenständiges Feature
