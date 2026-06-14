# lyxc 0.9.9B — Bug-Report (LLM-Runtime-Projekt)

- **Datum:** 2026-06-11
- **Compiler:** `lyxc 0.9.9B` (`/tmp/lyxc_new`), Target `x86_64`
- **Plattform:** Linux x86-64 (Kernel 6.8)
- **Kontext:** Gefunden beim Debuggen der Tests `ll01`–`ll08` des LLM-Runtime-Projekts.
  Alle Repros sind unten inline angegeben und unabhängig vom Projekt nachstellbar.

---

## Übersicht

| ID | Titel | Schwere | Symptom |
|----|-------|---------|---------|
| BUG-1 | `TypeName.field` evaluiert immer zu 0 | **Kritisch** | Alle Struct-Offset-Zugriffe lesen/schreiben Offset 0 |
| BUG-2 | Platzhalter-CALL `e8 cc 00 00 00` für fehlende Codegen-Implementierungen | **Kritisch** | SIGSEGV zur Laufzeit statt Compile-Fehler |
| BUG-3 | Sema-Fehler in importierten Modulen werden verschluckt | **Kritisch** | Build "erfolgreich", Binary defekt |
| BUG-4 | `MemCopy`: in sema registriert, fehlt in codegen | Hoch | Kompiliert sauber, SIGSEGV (via BUG-2) |
| BUG-5 | `sizeof(Type)`: inkonsistent in sema, fehlt in codegen | Hoch | Modulebene: sema error; Klassenmethode: SIGSEGV |
| BUG-6 | Statischer Aufruf `TypeName.Method()` wird nicht abgelehnt | Hoch | Kompiliert sauber, SIGSEGV (via BUG-2) |
| BUG-7 | `StrEq` fehlt in sema (inkonsistent zu `StrLen`) | Mittel | `sema error: undefined function` |
| BUG-8 | `var self` Shadowing in Klassenmethoden wird akzeptiert | Mittel | Feldzuweisungen gehen stillschweigend fehl |

Die Bugs 4, 5, 6 und (indirekt) 3 sind Symptome desselben Mechanismus — BUG-2.

---

## BUG-1: `TypeName.field` evaluiert immer zu 0

**Schwere: Kritisch** — bricht das gesamte dokumentierte Struct-Offset-Pattern
(`peek64(ptr + StructType.fieldName)`, siehe CLAUDE.md). Mit lyxc ≤ 0.9.4 hat
das Pattern funktioniert (Tests ll04–ll07 liefen damit grün); vermutlich
Regression beim Umbau der `TypeName.*`-Behandlung.

### Repro

```lyx
import src.llm.platform;

pub type Pair = class {
  first  : int64;
  second : int64;
  third  : int64;
}

fn main(): void {
  var m: int64 := LlmAlloc(24);
  poke64(m + Pair.first,  11);
  poke64(m + Pair.second, 22);
  poke64(m + Pair.third,  33);
  if peek64(m + 0)  != 11 { LlmPrintLn("FAIL first");  LlmExit(1); }
  if peek64(m + 8)  != 22 { LlmPrintLn("FAIL second"); LlmExit(2); }
  if peek64(m + 16) != 33 { LlmPrintLn("FAIL third");  LlmExit(3); }
  LlmPrintLn("OK");
}
```

### Beobachtet
- Kompiliert fehlerfrei.
- Ausgabe: `FAIL first` — alle drei `poke64` schreiben an `m + 0`.
- Direkte Ausgabe der Ausdrücke bestätigt: `Pair.first == 0`, `Pair.second == 0`, `Pair.third == 0`.
- **Gilt in allen Kontexten:** auch innerhalb von Klassenmethoden liefert
  `return Pair.second;` den Wert 0 (per Instanzmethoden-Aufruf verifiziert).

### Erwartet
`Pair.first == 0`, `Pair.second == 8`, `Pair.third == 16` — der Byte-Offset des
Feldes im Struct-Layout (je `int64` = 8 Bytes, Deklarationsreihenfolge).

### Auswirkung im Projekt
In `GGUFModelLoad` überschreiben sich alle Felder gegenseitig an Offset 0:
`kvCount` wird zuletzt vom ropeTheta-Bitmuster `0x40C3880000000000` überschrieben
→ Parse-Schleife mit ~4.6 × 10¹⁸ Iterationen (Endlosschleife), `fd` zerstört
→ alle Datei-Reads schlagen fehl (leere Keys).

---

## BUG-2: Platzhalter-CALL `e8 cc 00 00 00` für fehlende Codegen-Implementierungen

**Schwere: Kritisch** — der Mechanismus hinter den Bugs 4, 5, 6 und dem
früheren `syscall()`-Problem.

### Beschreibung

Wenn sema einen Funktionsaufruf akzeptiert, codegen aber **keine
Implementierung** für das Call-Target hat, wird ein CALL mit konstantem
rel32-Displacement emittiert:

```
e8 cc 00 00 00    call <eigene Adresse + 5 + 0xCC>
```

Das Displacement ist immer exakt `0xCC` (= 204), unabhängig vom Callsite.
Da jeder Callsite ein anderes absolutes Ziel ergibt (Callsite + 5 + 204), ist
das offensichtlich **kein gemeinsames Sprungziel, sondern ein nie gepatchter
Platzhalter** (0xCC ist das klassische Füllbyte / INT3-Opcode — vermutlich
wird das Displacement-Feld mit dem Fill-Pattern initialisiert und der
Relocation-/Patch-Schritt findet für diese Targets nie statt).

Das Ziel liegt dann mitten in fremdem Code oder in genulltem Speicher
(`00 00` = `add %al,(%rax)`) → SIGSEGV oder stilles Undefined Behavior.

### Binär-Evidenz (Beispiele aus diesem Projekt)

```
# tests/ll01 (StrEq-Aufrufe vor dem Workaround):
0x4024f7: e8 cc 00 00 00    call 0x4025c8   ; Ziel mitten in anderer Funktion
0x40250c: e8 cc 00 00 00    call 0x4025dd   ; "
0x402560: e8 cc 00 00 00    call 0x402631   ; Ziel: ff 48 8b 45 → decl -0x75(%rax) (Garbage)
0x402575: e8 cc 00 00 00    call 0x402646   ; "

# MemCopy-Repro:
0x40071d: e8 cc 00 00 00    call 0x4007ee   ; Ziel in genulltem Bereich → SIGSEGV
```

### Erwartet

Harter Compile-/Link-Fehler („no codegen implementation for X" o. ä.), niemals
ein lauffähiges Binary mit Platzhalter-Calls.

### Empfehlung

Zusätzlich zum Fix der Einzelfälle: einen **Assert/Abort in codegen**, wenn ein
Call-Target beim finalen Patchen kein aufgelöstes Ziel hat. Damit kann diese
Fehlerklasse nie wieder still durchrutschen.

---

## BUG-3: Sema-Fehler in importierten Modulen werden verschluckt

**Schwere: Kritisch** — macht BUG-2 erst richtig gefährlich, weil der Build
„grün" aussieht.

### Repro (zwei Dateien)

```lyx
// mod/util.lyx
pub fn DoStuff(): int64 {
  return ThisFunctionDoesNotExist(1, 2);
}
```

```lyx
// main.lyx
import mod.util;

fn main(): void {
  var r: int64 := DoStuff();
  exit(r);
}
```

### Beobachtet

| Kompiliert wird | Sema-Fehler | Ergebnis |
|---|---|---|
| `mod/util.lyx` direkt | **1** (`undefined function`) | kein Binary (korrekt) |
| `main.lyx` (importiert util) | **0** | Binary wird gebaut, enthält `e8 cc`-Stub für `ThisFunctionDoesNotExist`, **SIGSEGV** zur Laufzeit |

Identisches Verhalten im Projekt: `gguf.lyx` standalone meldete 22 sema errors
(`StrEq` undefined), `ll01_gguf_test.lyx` (importiert gguf) kompilierte ohne
jede Fehlermeldung.

### Erwartet

Sema-Fehler aus importierten Modulen müssen den Gesamt-Build abbrechen und
gemeldet werden (inkl. Dateiname des Moduls).

---

## BUG-4: `MemCopy` — in sema registriert, fehlt in codegen

**Schwere: Hoch**

### Repro

```lyx
fn main(): void {
  var src: int64 := mmap(0, 16, 3, 34, 0xFFFFFFFFFFFFFFFF, 0);
  var dst: int64 := mmap(0, 16, 3, 34, 0xFFFFFFFFFFFFFFFF, 0);
  poke8(src, 42);
  MemCopy(dst, src, 8);
  exit(peek8(dst));
}
```

### Beobachtet
- Kompiliert **fehlerfrei** (sema kennt `MemCopy`).
- SIGSEGV zur Laufzeit: Callsite `0x40071d: e8 cc 00 00 00`, Ziel `0x4007ee`
  liegt in genulltem Speicher (BUG-2).

### Erwartet
Exit-Code 42 — oder, falls `MemCopy` kein Builtin sein soll, ein sema error.

### Vergleich der drei „String/Memory-Builtins"

| Builtin | sema | codegen | Laufzeit |
|---|---|---|---|
| `StrLen` | ✅ | ✅ | ✅ funktioniert korrekt |
| `MemCopy` | ✅ | ❌ | SIGSEGV (e8cc-Stub) |
| `StrEq` | ❌ | — | sema error (BUG-7) |

---

## BUG-5: `sizeof(Type)` — inkonsistente sema-Behandlung, fehlendes codegen

**Schwere: Hoch**

### Repro A — Modulebene

```lyx
pub type Pair = class { first: int64; second: int64; third: int64; }

fn main(): void {
  var sz: int64 := sizeof(Pair);   // → sema error (line 10): undefined function
  exit(sz);
}
```

### Repro B — Klassenmethode

```lyx
pub type Pair = class {
  first: int64; second: int64; third: int64;

  pub fn GetSize(): int64 {
    return sizeof(Pair);           // kompiliert fehlerfrei!
  }
}

fn main(): void {
  var p: Pair;
  var sz: int64 := p.GetSize();    // → SIGSEGV
  exit(sz);
}
```

### Beobachtet
- **Modulebene:** `sema error: undefined function` (Repro A).
- **Klassenmethode:** kompiliert ohne Fehler, aber der `sizeof`-Aufruf wird als
  `e8 cc 00 00 00`-Stub emittiert (verifiziert: Callsite `0x401187`) → SIGSEGV.
  `sizeof` „funktioniert" in Klassenmethoden also nur scheinbar.

### Erwartet
`sizeof(Pair)` sollte in **beiden** Kontexten zur Compile-Zeit die Konstante 24
ergeben (3 × int64) — bzw. falls `sizeof` nicht unterstützt werden soll
(es fehlt auch in der EBNF-BuiltinCall-Liste): in beiden Kontexten ein
sema error.

---

## BUG-6: Statischer Aufruf `TypeName.Method()` wird nicht abgelehnt

**Schwere: Hoch** — laut Sprachdefinition ist Dot-Notation nur auf Instanzen
gültig, nicht auf Typnamen. Der Compiler akzeptiert es aber stillschweigend.

### Repro

```lyx
pub type Pair = class {
  first: int64; second: int64; third: int64;

  pub fn GetSecondOffset(): int64 {
    return Pair.second;
  }
}

fn main(): void {
  var off: int64 := Pair.GetSecondOffset();   // statischer Aufruf — ungültig
  exit(off);
}
```

### Beobachtet
- Kompiliert **fehlerfrei**.
- Der Aufruf wird als `e8 cc 00 00 00`-Stub emittiert (verifiziert: Datei-Offset
  `0x11e4` im Binary) → SIGSEGV.
- Hinweis: Der **Instanz**-Aufruf (`var p: Pair; p.GetSecondOffset()`) erzeugt
  dagegen korrekten Code und läuft durch.

### Erwartet
Parse- oder Sema-Fehler: „dot notation requires an instance expression,
not a type name" o. ä.

---

## BUG-7: `StrEq` fehlt in sema

**Schwere: Mittel** (zusammen mit BUG-3 aber kritisch, weil unbemerkt)

### Repro

```lyx
fn main(): void {
  var a: pchar := "hello";
  var b: pchar := "hello";
  var r: int64 := StrEq(a, b);   // → sema error: undefined function
  exit(r);
}
```

### Beobachtet
- Direkt kompiliert: `sema error: undefined function` (korrektes Verhalten,
  falls `StrEq` kein Builtin ist).
- **Aber:** in importierten Modulen wird derselbe Fehler verschluckt (BUG-3)
  und als `e8 cc`-Stub kompiliert → SIGSEGV statt Compile-Fehler.

### Erwartet
Entweder `StrEq` als Builtin implementieren (konsistent zu `StrLen`) oder
dokumentieren, dass es keines ist. In jedem Fall muss der Fehler auch über
Import-Grenzen gemeldet werden (BUG-3).

---

## BUG-8: `var self` Shadowing in Klassenmethoden wird akzeptiert

**Schwere: Mittel**

### Repro

```lyx
import src.llm.platform;

pub type Box = class {
  value : int64;

  pub fn Make(): int64 {
    var self: int64 := LlmAlloc(8);
    self.value := 42;        // geht NICHT in den allokierten Puffer
    return self;
  }
}

fn main(): void {
  var b: Box;
  var p: int64 := b.Make();
  LlmExit(peek64(p));        // erwartet 42, tatsächlich 0
}
```

### Beobachtet
- Kompiliert fehlerfrei; `return self` liefert den korrekten Puffer-Zeiger.
- `self.value := 42` schreibt aber **nicht** in diesen Puffer
  (`peek64(p) == 0`). Die Zuweisung über die geshadowte Variable wird auf die
  implizite self-Instanz (bzw. eine andere Adresse) aufgelöst. In früheren
  Versuchen mit statischem Aufrufkontext (implizites self ≈ 0) führte das zu
  Writes nach Adresse ~0 → SIGSEGV.

### Erwartet
Sema error: `self` ist ein Keyword und darf nicht als Variablenname deklariert
werden.

---

## Verifiziert funktionierend (Negativliste — nicht weitersuchen)

Zur Abgrenzung, was beim Debugging explizit als **korrekt** verifiziert wurde:

- Benannte Syscall-Builtins: `mmap`, `munmap`, `open`, `read`, `write`,
  `lseek`, `close`, `clock_gettime`, `sys_getrandom`, `exit`
  (Datei-Roundtrip write→read inkl. Werte verifiziert)
- `StrLen` (sema + codegen + Laufzeit)
- `peek8`/`poke8`, `peek32`/`poke32`, `peek64`/`poke64` (Heap-Roundtrips)
- Instanzmethoden-Aufrufe auf typisierten Variablen (`var p: Pair; p.Method()`)
- `while`-Schleifen (auch `while 1` mit `return`), `if`/`else if`-Ketten,
  `||` mit Funktionsaufrufen auf beiden Seiten
- String-Literale als `pchar`-Argumente, `as`-Casts, Modul-Level-`con`
- Modul-Level-Funktionen über Import-Grenzen (`pub fn` aus importiertem Modul)

## Workarounds im Projekt (können nach Compiler-Fix zurückgebaut werden)

1. **`LlmStrEq` / `LlmMemCopy`** in `src/llm/platform.lyx` als Lyx-Implementierungen;
   alle `StrEq`/`MemCopy`-Aufrufe im Projekt ersetzt. → Nach Fix von BUG-4/BUG-7
   optional zurück auf Builtins.
2. **`SIZEOF_*`-Konstanten** (`SIZEOF_GGUF_MODEL`, `SIZEOF_TENSOR_INFO`, …)
   statt `sizeof(Type)`. → Nach Fix von BUG-5 optional zurück auf `sizeof`.
3. **Modul-Level-Funktionen** (`GGUFModelLoad`, `KVCacheCreate`, …) statt
   statischer Klassenmethoden — das bleibt so (kanonisches Lyx-Pattern).
4. **Noch offen:** Das Projekt nutzt weiterhin `TypeName.field` als Offset
   (BUG-1) — blockiert alle Tests, wartet auf Compiler-Fix.
