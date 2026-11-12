# DATATYPES.md – Lyx Datentypen-Übersicht

## Aktuell unterstützte Datentypen

### 1. Ganzzahl-Typen (signiert)

| Typ     | Bits | Wertebereich                                               | Status | Literale    |
|---------|------|------------------------------------------------------------|--------|-------------|
| `int8`  | 8    | -128 bis 127                                               | ✅ Full | `42i8`      |
| `int16` | 16   | -32,768 bis 32,767                                         | ✅ Full | `42i16`     |
| `int32` | 32   | -2,147,483,648 bis 2,147,483,647                           | ✅ Full | `42i32`     |
| `int64` | 64   | -9,223,372,036,854,775,808 bis 9,223,372,036,854,775,807  | ✅ Full | `42` (std)  |
| `int`   | 64   | Alias für `int64`                                          | ✅ Full | `42`        |

### 2. Ganzzahl-Typen (unsigniert)

| Typ      | Bits | Wertebereich                                          | Status | Literale    |
|----------|------|-------------------------------------------------------|--------|-------------|
| `uint8`  | 8    | 0 bis 255                                             | ✅ Full | `42u8`      |
| `uint16` | 16   | 0 bis 65,535                                          | ✅ Full | `42u16`     |
| `uint32` | 32   | 0 bis 4,294,967,295                                   | ✅ Full | `42u32`     |
| `uint64` | 64   | 0 bis 18,446,744,073,709,551,615                     | ✅ Full | `42u64`     |

### 3. Plattform-abhängige Typen

| Typ     | Beschreibung                  | Status    | Anmerkung                         |
|---------|-------------------------------|-----------|-----------------------------------|
| `isize` | Pointer-Größe (signiert)      | ⚠️ Partial | Typ definiert; Tests/ABI prüfen   |
| `usize` | Pointer-Größe (unsigniert)    | ⚠️ Partial | Typ definiert; Tests/ABI prüfen   |

### 4. Fließkomma-Typen

| Typ   | Bits | IEEE 754 | Status | Literale |
|-------|------|----------|--------|----------|
| `f32` | 32   | single   | ✅ Full | `3.14f32` / `3.14` |
| `f64` | 64   | double   | ✅ Full | `3.14` / `3.14f64` |

> Status: Frontend (Lexer, Parser, AST, Sema), IR-Lowering und grundlegende Codegen‑Pfad für f32/f64 sind implementiert. Feinheiten der optimierten Float‑Codegenerierung können noch erweitert werden.

### 5. Zeichen- und String-Typen

| Typ     | Beschreibung               | Status | Literale |
|---------|----------------------------|--------|----------|
| `char`  | Einzelnes Zeichen (ASCII/Unicode codepoint) | ✅ Full | `'a'`, Escape-Sequenzen |
| `pchar` | Null-terminierter String (statisch, read-only) | ✅ Full | `"hello"` |
| `string`| Dynamisch wachsender String (mmap-Heap, v0.5.7) | ✅ Full | via `StrNew` |

**Dynamische Strings (v0.5.7):** `string`-Werte verwenden einen 16-Byte-Header vor dem Datenpuffer (`[capacity:8][length:8]`). Der zurückgegebene `pchar`-Zeiger zeigt auf die Nutzdaten und ist kompatibel mit `Print`.

**String-Builtins (v0.5.7):**

| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `StrNew` | `(cap: int64): string` | Allokiert neuen String mit Kapazität `cap` |
| `StrFree` | `(s: string)` | Gibt String-Speicher frei (munmap) |
| `StrLen` | `(s: string): int64` | Länge des Strings (ohne Null-Terminator) |
| `StrCharAt` | `(s: string, i: int64): int64` | Zeichen an Position `i` als int64 |
| `StrSetChar` | `(s: string, i: int64, c: int64)` | Setzt Zeichen an Position `i` |
| `StrAppend` | `(s: string, c: int64): string` | Hängt Zeichen an, gibt neuen Puffer zurück |
| `StrFromInt` | `(n: int64): string` | Konvertiert int64 zu String |

```lyx
var s: string := StrNew(64);
s := StrAppend(s, 72);   // 'H'
s := StrAppend(s, 105);  // 'i'
Print(s);                // "Hi"
StrFree(s);
```

#### 5.1 Bibliotheks-String-Typen: `String` und `Text`

Über den Builtins liegen zwei stdlib-Typen. Beide sind Klassen, libc-frei
(mmap/munmap) und besitzen ihre Bytes; beide nehmen am Operator-Overloading teil
(siehe `ebnf.md` §15.3).

| Typ | Unit | Ebene | Bedeutung |
|-----|------|-------|-----------|
| `String` | `std.strtype` | **Bytes** | Rohe, uninterpretierte Bytes mit expliziter Länge + Kapazität. Embedded NUL erlaubt, kein NUL-Scan. `CharAt`/`Get` = **Byte**. |
| `Text` | `std.text` | **UTF-8** | Bei Konstruktion als UTF-8 validiert, codepoint-orientiert. `CodepointAt`/`Get` = **Codepoint**, `ByteAt` = Rohbyte. |

Das entspricht dem Encoding-Beschluss: UTF-8 ist das kanonische interne Encoding,
und der Bytes/Text-Split trennt „rohe Bytes" von „garantiert gültigem UTF-8".
Volle Unicode-Korrektheit (Normalisierung, Grapheme, volles Case-Mapping) liegt
bewusst in opt-in-Units (`std.unicode`, `std.unicode_case`, `std.grapheme`),
nicht im Basistyp — die Tabellen sind MB-groß.

**Operatoren** (beide Typen definieren die Methoden, auf die der Compiler abbildet):

| Operator | Methode | `String` | `Text` |
|----------|---------|----------|--------|
| `a + b` | `Add` | Byte-Konkatenation | UTF-8-Konkatenation |
| `a == b` / `a != b` | `Eq` / `Ne` | inhaltsgleich (Bytes) | inhaltsgleich (Bytes) |
| `a < b` `<=` `>` `>=` | `Lt`/`Le`/`Gt`/`Ge` über `Compare` | lexikografisch nach Bytes | lexikografisch nach UTF-8-Bytes = **Codepoint-Ordnung** |
| `a[i]` | `Get` | `i`-tes **Byte** | `i`-ter **Codepoint** |

`==` vergleicht Bytes, ist also **nicht** normalisierungs-insensitiv: „é" als ein
Codepoint und als `e`+kombinierender Akut sind ungleich. `Compare` ist
Codepoint-Ordnung, **keine** Locale-Collation. Ebenso trimmt `Trim()` nur
ASCII-Whitespace — NBSP, EN/EM-Space und das ideographische Leerzeichen bleiben
stehen. Für beides gibt es opt-in-Funktionen:

| Frage | Funktion | Unit |
|-------|----------|------|
| Gleich trotz unterschiedlicher Normalisierung? | `TextEqualsNormalized(a, b)` | `std.unicode` |
| Sortierung trotz unterschiedlicher Normalisierung? | `TextCompareNormalized(a, b)` | `std.unicode` |
| Präfix trotz unterschiedlicher Normalisierung? | `TextStartsWithNormalized(t, p)` | `std.unicode` |
| Unicode-Whitespace trimmen | `TextTrimUnicode` / `TextTrimStartUnicode` / `TextTrimEndUnicode` | `std.unicode` |
| Gleich ohne Rücksicht auf Groß/Klein? | `TextEqualsFold(a, b)` | `std.unicode_case` |
| Sortierung ohne Rücksicht auf Groß/Klein? | `TextCompareFold(a, b)` | `std.unicode_case` |
| Enthält, ohne Rücksicht auf Groß/Klein? | `TextContainsFold(t, needle)` | `std.unicode_case` |
| Vergleichsschlüssel einmal berechnen | `TextFoldFull(t)` | `std.unicode_case` |

Die beiden Achsen sind **getrennt**: `TextEqualsFold` ist nicht
normalisierungs-insensitiv und `TextEqualsNormalized` nicht case-insensitiv. Wer
beides braucht, normalisiert erst (`TextToNFC`) und faltet dann
(`TextEqualsFold`). Grund für die Trennung ist keine Designvorliebe, sondern eine
Compiler-Grenze: die Normalisierungs- und die Case-Tabelle zusammen in einer
Kompilierungseinheit sprengen das Größenlimit von `lyxc`.

`TextEqualsFold` faltet **simple** (1:1) — inklusive des griechischen
Schluss-Sigma (ς→σ), das reines Kleinschreiben nicht erwischt. Volles Folding mit
1:n-Expansion (ß→ss, ﬁ→fi) ist nicht abgedeckt, „STRASSE" und „Straße" bleiben
also ungleich.

```lyx
import std.text;

var a: Text := TextFromPchar("héllo");
var b: Text := TextFromPchar(" wörld");

a.ByteLength();        // 6  — Bytes
a.CodepointCount();    // 5  — Codepoints
a[1];                  // 233 (U+00E9) — Codepoint, nicht das Lead-Byte
a.ByteAt(1);           // 195 — Rohbyte

var joined: Text := a + b;
if (a == TextFromPchar("héllo")) { /* inhaltsgleich */ }

a.Free();              // Referenzsemantik: leert wirklich das Objekt
```

`Text` trägt neben den Operatoren die volle Methoden-API: `IsValid`, `Data`,
`ByteAt`, `CodepointCount`, `CodepointAt`, `ByteOffsetOfCodepoint`,
`SubstringCp` (codepoint-korrekt, zerteilt nie eine Multibyte-Sequenz),
`StartsWith`, `Find`/`FindCp`/`Contains`, `Trim`, `Replace`, `SplitCount`/`PartAt`,
`AsciiUpper`/`AsciiLower`, `ToPchar`, `Free`. Jede dieser Methoden existiert
zusätzlich als freie Funktion (`TextCodepointCount(t)` usw.).

**Lebensdauer:** beide Typen sind Klassen, also Referenzen — `Free()` wirkt auf
das Objekt des Aufrufers. Speicher wird manuell freigegeben (kein Refcount, kein
GC); das ist bewusst so, solange Lyx kein globales RC/COW hat.

#### 5.2 UTF-16 an der Grenze

UTF-16 ist ausschließlich **Boundary-Format** (Windows-FFI, UTF-16-Dateien), nie
internes Format — innerhalb von Lyx bleibt alles UTF-8. Die Konverter liegen in
`std.text`, brauchen keine Tabellen und arbeiten auf reinen Bytemustern:

| Funktion | Bedeutung |
|----------|-----------|
| `TextFromUtf16(ptr, byteLen, endian)` | UTF-16 → `Text`, Byte-Reihenfolge explizit |
| `TextFromUtf16Bom(ptr, byteLen)` | Byte-Reihenfolge aus dem BOM, BOM wird entfernt |
| `TextUtf16Length(t)` | Bytes, die die UTF-16-Kodierung braucht (ohne BOM) |
| `TextToUtf16(t, dest, endian)` | `Text` → UTF-16, ohne BOM; liefert geschriebene Bytes |
| `TextToUtf16Bom(t, dest, endian)` | dito mit vorangestelltem U+FEFF |

Byte-Reihenfolge über die Konstanten `UTF16_BE` / `UTF16_LE`.

**Puffergröße:** immer über `TextUtf16Length(t)` bestimmen (plus 2 für ein BOM) —
sie lässt sich **nicht** aus `ByteLength()` ableiten. UTF-8 und UTF-16 sind pro
Codepoint in beide Richtungen unterschiedlich groß: ASCII ist 1 vs. 2 Bytes,
U+0800..U+FFFF dagegen 3 vs. 2.

**Surrogate-Paare:** Codepoints über U+FFFF werden als Paar kodiert bzw. beim
Dekodieren wieder zusammengesetzt. Genau das ist der Grund, warum UTF-16 kein
Fixed-Width-Format ist und Indizierung nach Code-Unit eine Falle bleibt — `Text`
indiziert deshalb nach Codepoint.

**Fehlerhafte Eingabe bricht nicht ab**, sondern wird zu U+FFFD (`UNICODE_REPLACEMENT`),
je ein Ersatzzeichen pro fehlerhafter Code-Unit: unpaariges High-Surrogate,
verirrtes Low-Surrogate, abgeschnittenes Paar am Puffer-Ende, ungerades
Rest-Byte. Das Ergebnis ist damit garantiert gültiges UTF-8. Wer schlechte
Eingabe ablehnen statt ersetzen will, prüft das Resultat auf U+FFFD.

**Ohne BOM liest `TextFromUtf16Bom` big-endian** — so schreibt es RFC 2781 für
schlichtes „UTF-16" vor. Das ist das Gegenteil dessen, was BOM-lose Dateien aus
der Windows-Welt üblicherweise sind: wenn die Byte-Reihenfolge bekannt ist, lieber
`TextFromUtf16` mit explizitem `UTF16_LE` verwenden.

```lyx
var t: Text := TextFromUtf16Bom(fileBytes, fileLen);

var need: int64 := TextUtf16Length(t) + 2;              // + BOM
var out: int64 := mmap(0, need, PROT_RW, MAP_ANON, FD_NONE, 0);
var written: int64 := TextToUtf16Bom(t, out, UTF16_LE);
```

### 6. Enum-Typen (v0.5.7)

Enums definieren eine benannte Menge von Integer-Konstanten.

```
EnumDecl  := 'enum' Ident '{' EnumBody '}' ;
EnumBody  := EnumMember { ',' EnumMember } ;
EnumMember := Ident [ '=' IntLiteral ] ;
EnumAccess := Ident '::' Ident ;
```

| Merkmal | Beschreibung |
|---------|--------------|
| Basistyp | `int64` (implizit) |
| Auto-Nummerierung | Startet bei 0, inkrementiert automatisch |
| Explizite Werte | `Name = <literal>` erlaubt |
| Zugriff | `EnumName::Wert` (Namespace-Operator `::`) |
| Vergleich | Mit `==` / `!=` gegen int64-Werte |

```lyx
enum Color { Red, Green, Blue }
enum Status { Ok = 0, Err = 1 }

fn main(): int64 {
  var c: int64 := Color::Green;   // c = 1
  if (c == Color::Green) {
    PrintLn("green");
  }
  return 0;
}
```

### 7. Tuple-Typen (v0.5.7)

Funktionen können mehrere Werte als Tuple zurückgeben.

```
TupleReturn  := '(' Expr { ',' Expr } ')' ;
TupleUnpack  := 'var' Ident { ',' Ident } ':=' CallExpr ';' ;
```

| Merkmal | Beschreibung |
|---------|--------------|
| Max. Elemente | Beliebig (aktuell bis 8 getestet) |
| Speicher | Stack-basiert via RDX/RAX für 2 Werte |
| Unpack | `var a, b := f()` — gleichzeitige Zuweisung |

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
  return (a / b, a % b);
}

fn main(): int64 {
  var q, r := divmod(17, 5);
  PrintLn(q);   // 3
  PrintLn(r);   // 2
  return 0;
}
```

### 8. Sonstige Typen

| Typ    | Beschreibung            | Status | Verwendung |
|--------|-------------------------|--------|------------|
| `bool` | Wahrheitswert           | ✅ Full | `true`, `false` |
| `void` | Kein Rückgabewert       | ✅ Full | Funktionen ohne Return |

### 9. Interne Typen

| Typ            | Verwendung                                 |
|----------------|--------------------------------------------|
| `atUnresolved` | Temporär während Typprüfung                 |

## Status-Legende

- ✅ **Full**: Vollständig implementiert (Parser, Sema, IR, Codegen)
- ⚠️ **Partial**: Teilweise implementiert (fehlende Komponenten oder Tests)
- ❌ **Missing**: Definiert, aber nicht implementiert
- 🔄 **WIP**: Work in Progress

## Implementierungsdetails

### Storage-Klassen-Kompatibilität

| Storage-Klasse | Beschreibung           | Status (HEAD) |
|----------------|------------------------|---------------|
| `var`          | Veränderbar            | ✅ Unterstützt für alle primitiven Typen |
| `let`          | Unveränderbar          | ✅ Unterstützt für alle primitiven Typen |
| `co`           | Compile-time readonly  | ✅ Unterstützt |
| `con`          | Compile-time constant  | ✅ Unterstützt |

**Getestet und funktionsfähig (Frontend + IR + grundlegende Codegen):**
- Integer-Typen (int8..int64, uint8..uint64)
- Boolean (`bool`)
- Char (`char`) inkl. Escape‑Sequenzen
- Strings (`pchar`/`string`) mit Literalunterstützung
- Floating-Point (f32, f64): Literal‑Parsing, Typprüfung, Konvertierungen und Basis‑Codegen
- Array‑Literal‑Parsing und elementare Load/Store-Operationen (Frontend und grundlegender Backend‑Support)

### Typkonvertierung

- **Automatisch**: Zwischen Integer‑Typen verschiedener Breiten
- **Explizit**: Mit Casts (teilweise implementiert)
- **Konstanten‑Folding**: Literale werden beim IR/Codegen auf Zielbreite behandelt

### Code-Generation-Status

#### Vollständig implementiert:
- Integer-Typen (8–64 Bit, signed/unsigned)
- `bool`, `char`, `pchar`, `string`
- Basis‑Floating‑Point‑Operationen (Loads/Stores, cvt, movsd/movss) und Konversionen
- Konstanten‑Folding mit Truncation/Extension
- Load/Store mit korrekter Breite

#### Teilweise implementiert:
- `isize`, `usize`: Typen sind definiert; ABI/Architekturtests fehlen
- Arrays: Frontend (Literals, Typprüfung) ist vollständig; komplexere Array‑Codegen (statische Layouts, Slicing, dynamische Allokation) ist noch in Arbeit

#### Fehlend / noch zu erweitern:
- Strukturen/Records (vollständiger Speicherlayout‑Support)
- Pointer‑Arithmetik (feinere Operationen)
- Union‑Typen

## Status-Update: HEAD (aktueller Stand)

Die aktuellen Änderungen haben folgende Lücken geschlossen und Features hinzugefügt:

- Frontend: Char‑ und Float‑Literal‑Lexing/Parsing implementiert
- IR/Backend: Grundlegende Float‑Operationen (cvtsi2sd, cvttsd2si, movsd) und Array Load/Store-Emissionen implementiert
- Platform‑Types (`isize`/`usize`) sind als Typen vorhanden; Tests/ABI‑Überprüfung stehen noch aus

## Test-Abdeckung (Stand: Februar 2026)

### ✅ Getestet / grün:
- Integer‑Primitiven (int8..int64, uint8..uint64)
- Boolean (`bool`)
- Char‑Literale und Escape‑Sequenzen
- String‑Literale (`pchar`/`string`) in Kombination mit Builtins (z.B. Print, PrintLn)
- Float‑Literals (f32, f64) — Parsing, Sema, Basiscodierung
- Array‑Literal‑Parsing und elementare Load/Store im Backend

### ⚠️ Zu verifizieren:
- `isize`/`usize` auf mehreren Architekturen
- Edge‑Cases bei Integer‑Overflow/Underflow
- Vollständiger Float‑Codegen (optimierte Sequenzen, ABI‑Konventionen für float‑Returns in SSE regs)

## Roadmap (aktualisiert)

### Kurzfristig
1. Tests für `isize`/`usize` hinzufügen und ABI‑Konformität prüfen
2. Erweiterte Array‑Codegen (statische Arrays, Layouts)
3. Pattern Matching: `match` auf Strings und Enums erweitern

### Mittelfristig
1. Strukturen/Records implementieren (Layout + Feldzugriff)
2. Pointer‑Arithmetik und dereferenzierung vervollständigen
3. Generics auf Strukturen ausweiten (aktuell: nur Funktionen)

### Langfristig
1. Union‑Typen
2. Smart‑Pointer
3. Garbage Collector (optional)

## Beispiele

```lyx
// Integer-Typen
var a: int8 := 127;
let b: uint16 := 65535;

// Floats
var pi: f32 := 3.14159;
let e: f64 := 2.718281828;

// Char & String
var ch: char := '\n';
let msg: pchar := "Hello, World!";

// Arrays (Literal + einfache Load/Store)
var arr := [1, 2, 3];
let first := arr[0];

// Function signatures
fn get_byte(): uint8 { return 255; }
fn get_flag(): bool { return true; }
```
