# Bug: Negative `con`-Konstanten werden zu `0` ausgewertet

**Status:** ✅ Behoben in `fix/con-neg-literal`  
**Entdeckt bei:** WP-SQ-01 (std/db/sqlite — SQLITE_TRANSIENT = -1)  
**Workaround:** nicht mehr nötig

---

## Symptom

```lyx
pub con X: int64 := -1;     // Laufzeitwert: 0  ← falsch
pub con Y: int64 := 0 - 1;  // Laufzeitwert: 0  ← falsch
```

Bei normalen Variablen funktioniert es korrekt:

```lyx
var a: int64 := -1;     // Laufzeitwert: -1  ✅
var b: int64 := 0 - 1;  // Laufzeitwert: -1  ✅
```

Der Compiler gibt keine Warnung oder Fehlermeldung — der Fehler ist komplett lautlos.

---

## Ursache

**Datei:** `src/sema.lyx`, Funktion `_evalConstExpr` (ab Zeile 694)

Die Funktion wertet Konstantenausdrücke für `con`-Deklarationen zur Compile-Zeit aus.
Sie ist jedoch unvollständig: Arithmetische Operatoren sind nicht implementiert.

### Fall 1: Unäres Minus (`con X := -1`)

Der Parser erzeugt für `-1` einen `SNK_UNOP`-Knoten mit `iVal = TK_MINUS (71)`.
Der Evaluator behandelt im `SNK_UNOP`-Zweig **nur** `TK_NOT (87)` und fällt
für alle anderen Operatoren auf `return 0` zurück:

```lyx
if (k == SNK_UNOP) {
    var uop: int64 := self.sn_iVal(ni);
    var cv: int64 := self._evalConstExpr(self.sn_c0(ni));
    if (uop == 87) { if (cv == 0) { return 1; } else { return 0; } }  // TK_NOT
    return 0;  // ← TK_MINUS (71) landet hier
}
```

### Fall 2: Binäres Minus (`con Y := 0 - 1`)

Der Parser erzeugt einen `SNK_BINOP`-Knoten mit `iVal = TK_MINUS (71)`.
Der `SNK_BINOP`-Zweig behandelt nur Vergleichs- und Logikoperatoren (79–86),
nicht Arithmetik:

```lyx
if (k == SNK_BINOP) {
    var bop: int64 := self.sn_iVal(ni);
    // TK_AND=85, TK_OR=86 — Kurzschluss-Auswertung
    if (bop == 85) { ... }
    if (bop == 86) { ... }
    var rv: int64 := self._evalConstExpr(self.sn_c1(ni));
    if (bop == 79) { ... }  // ==
    if (bop == 80) { ... }  // !=
    if (bop == 81) { ... }  // <
    if (bop == 82) { ... }  // <=
    if (bop == 83) { ... }  // >
    if (bop == 84) { ... }  // >=
    return 0;  // ← TK_MINUS (71) landet hier
}
```

---

## Relevante Token-Codes (aus `src/lexer.lyx`)

| Token       | Code | Operator |
|-------------|------|----------|
| `TK_PLUS`   | 70   | `+`      |
| `TK_MINUS`  | 71   | `-`      |
| `TK_STAR`   | 72   | `*`      |
| `TK_SLASH`  | 73   | `/`      |
| `TK_PERCENT`| 74   | `%`      |
| `TK_NOT`    | 87   | `!`/`not`|
| `TK_BITXOR` | 89   | `^`      |
| `TK_BITAND` | 90   | `&`      |
| `TK_BITOR`  | 91   | `\|`     |
| `TK_SHL`    | 93   | `<<`     |
| `TK_SHR`    | 94   | `>>`     |

---

## Fix

**Datei:** `src/sema.lyx` — Funktion `_evalConstExpr`

### 1. `SNK_UNOP`-Zweig: unäres Minus ergänzen

```lyx
if (k == SNK_UNOP) {
    var uop: int64 := self.sn_iVal(ni);
    var cv: int64 := self._evalConstExpr(self.sn_c0(ni));
    if (uop == 87) { if (cv == 0) { return 1; } else { return 0; } }  // TK_NOT
    if (uop == 71) { return 0 - cv; }   // ← NEU: TK_MINUS (unäres Negieren)
    return 0;
}
```

### 2. `SNK_BINOP`-Zweig: Arithmetik ergänzen

Die neuen Cases **vor** den Vergleichen einfügen (nach dem `rv`-Aufruf):

```lyx
// Arithmetik
if (bop == 70) { return lv + rv; }             // TK_PLUS
if (bop == 71) { return lv - rv; }             // TK_MINUS
if (bop == 72) { return lv * rv; }             // TK_STAR
if (bop == 73) { if (rv == 0) { return 0; } return lv / rv; }  // TK_SLASH
if (bop == 74) { if (rv == 0) { return 0; } return lv % rv; }  // TK_PERCENT
if (bop == 89) { return lv ^ rv; }             // TK_BITXOR  (^)
if (bop == 90) { return lv & rv; }             // TK_BITAND  (&)
if (bop == 91) { return lv | rv; }             // TK_BITOR   (|)
if (bop == 93) { return lv << rv; }            // TK_SHL     (<<)
if (bop == 94) { return lv >> rv; }            // TK_SHR     (>>)
```

> **Hinweis Division:** `TK_SLASH` und `TK_PERCENT` in der normalen Code-Generierung
> behandeln negative Operanden unsigned (siehe `work/lyx-division-bug.md`). In
> `_evalConstExpr` arbeiten wir direkt auf `int64`-Lyx-Variablen — dort ist das
> Verhalten korrekt. Der Fix hier ist daher unabhängig vom Division-Bug.

---

## Workaround (bis Fix umgesetzt)

Statt des negativen Literals das Two's-Complement als Hex-Literal schreiben:

| Gewünschter Wert | Workaround            |
|------------------|-----------------------|
| `-1`             | `0xFFFFFFFFFFFFFFFF`  |
| `-2`             | `0xFFFFFFFFFFFFFFFE`  |
| `-100`           | `0xFFFFFFFFFFFFFF9C`  |

Für kleine negative Werte gilt: `0x100000000000000 + gewünschterWert` gibt die
Hex-Darstellung (z.B. `-1 = 0x10000000000000000 - 1 = 0xFFFFFFFFFFFFFFFF`).

Bereits angewendet in: `std/db/sqlite.lyx` (`SQLITE_TRANSIENT`).

---

## Akzeptanzkriterien für den Fix

```lyx
pub con A: int64 := -1;
pub con B: int64 := 0 - 1;
pub con C: int64 := 5 - 10;
pub con D: int64 := 2 * 3 + 1;
pub con E: int64 := 0xFF & 0x0F;

// Nach dem Fix: A=-1, B=-1, C=-5, D=7, E=15
```

- Alle fünf Konstanten liefern den erwarteten Wert zur Laufzeit
- Kein Compiler-Fehler, keine Warnung
- Singularitätsprüfung (`make singularity`) besteht weiterhin
- Nach dem Fix: `SQLITE_TRANSIENT` kann auf `int64 := -1` vereinfacht werden
  (Hex-Workaround in `std/db/sqlite.lyx` entfernen)
