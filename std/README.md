Standard-Units (std)
====================

Dieses Verzeichnis enthält standardisierte Units, die als umfassende Bibliothek für Lyx-Programme dienen. Die Libraries kombinieren native Builtin-Funktionen mit ergonomischen Wrapper-Funktionen und erweiterten Utilities.

## Übersicht der verfügbaren Units

| Unit | Beschreibung |
|------|--------------|
| `std/math` | Integer-Mathematik, Fixed-Point, Trigonometrie |
| `std/vector` | Vec2 2D-Vektor, Rotation, Normalisierung |
| `std/rect` | Rect Bounding Box, Flächenberechnung |
| `std/circle` | Circle/Range für Umkreissuchen |
| `std/color` | RGBA Farben, HSL, Hex-Konvertierung |
| `std/list` | Dynamische Listen, RingBuffer, Stack, Queue |
| `std/result` | Result/Option Pattern für Error-Handling |
| `std/string` | String-Manipulation und -Suche |
| `std/io` | Print/Printf, Formatierung |
| `std/env` | Command-Line Argumente |
| `std/time` | Datum/Zeit, Kalenderfunktionen |
| `std/geo` | Geolocation, Koordinaten, Distanzen |
| `std/crt` | ANSI Terminal-Steuerung |
| `std/crt_raw` | Raw-Mode Input (experimentell) |
| `std/pack` | Binary Serialisierung |
| `std/regex` | Regex-Matching |
| `std/fs` | Dateisystem-Operationen, Path-Funktionen |
| `std/process` | Prozess-Management (fork/exec/wait) |
| `std/json` | JSON Parser und Serializer |
| `std/alloc` | Explizite Speicherverwaltung (malloc/free, Pool) |
| `std/hash` | Hash-Funktionen (FNV, CRC32, SHA-256) |

---

## std/math.lyx

### Basis-Integer-Mathematik
- `Abs64(x: int64): int64` - Absoluter Wert
- `Min64(a, b: int64): int64` - Minimum
- `Max64(a, b: int64): int64` - Maximum
- `Div64(a, b: int64): int64` - Ganzzahlige Division
- `Mod64(a, b: int64): int64` - Modulo
- `TimesTwo(x: int64): int64` - Verdoppeln
- `Min3(a, b, c: int64): int64` - Minimum von 3 Werten
- `Max3(a, b, c: int64): int64` - Maximum von 3 Werten

### Zufallszahlen
- `RandomRange(max: int64): int64` - Zufallszahl [0, max)
- `RandomBetween(min, max: int64): int64` - Zufallszahl [min, max]

**Native Builtins** (kein Import nötig):
- `Random(): int64` - Pseudo-Zufallszahl (0..2³¹-1)
- `RandomSeed(seed: int64): void` - Seed für LCG setzen

### Erweiterte Integer-Mathematik
- `Sqrt64(n: int64): int64` - Ganzzahlige Quadratwurzel (Newton-Verfahren)
- `IntSqrt(n: int64): int64` - Alias für Sqrt64
- `Clamp64(val, min, max: int64): int64` - Wert begrenzen
- `Sign64(x: int64): int64` - Vorzeichen (-1, 0, 1)
- `Pow64(base, exp: int64): int64` - Potenz (base^exp)
- `InRange64(val, min, max: int64): bool` - Prüft Bereichszugehörigkeit
- `Round64(x: int64): int64` - Runden
- `Atan2Microdegrees(y, x: int64): int64` - Atan2 in Microdegrees
- `Cos64Inverse(cos_value: int64): int64` - Inverser Kosinus

### Fixed-Point & Interpolation
- `Lerp64(a, b, t_permille: int64): int64` - Lineare Interpolation (t: 0-1000)
- `Map64(val, in_min, in_max, out_min, out_max: int64): int64` - Wert umskalieren
- `Hypot64(x, y: int64): int64` - √(x² + y²) mit Überlaufschutz

### Fixed-Point Trigonometrie
- `Sin64(degrees: int64): int64` - Sinus (Microdegrees)
- `Cos64(degrees: int64): int64` - Cosinus (Microdegrees)

### Bit-Manipulation
- `IsEven(x: int64): bool` - Gerade Zahl?
- `IsOdd(x: int64): bool` - Ungerade Zahl?
- `NextPowerOfTwo(x: int64): int64` - Nächste 2er-Potenz
- `IsPowerOfTwo(x: int64): bool` - Ist 2er-Potenz?
- `PopCount(x: int64): int64` - Anzahl gesetzter Bits
- `Log2(x: int64): int64` - Logarithmus zur Basis 2

---

## std/vector.lyx

2D-Vektor-Bibliothek mit Vec2 struct.

### Vec2 Struct
```lyx
struct Vec2 {
  x: int64,
  y: int64
}
```

### Konstruktoren
- `Vec2New(x, y: int64): Vec2` - Aus Koordinaten
- `Vec2Zero(): Vec2` - Nullvektor (0, 0)
- `Vec2FromScalar(v: int64): Vec2` - Aus Skalar (v, v)

### Arithmetik
- `Vec2Add(a, b: Vec2): Vec2` - Vektoraddition
- `Vec2Sub(a, b: Vec2): Vec2` - Vektorsubtraktion
- `Vec2Mul(v: Vec2, scalar: int64): Vec2` - Skalarmultiplikation
- `Vec2Div(v: Vec2, scalar: int64): Vec2` - Skulardivision
- `Vec2Negate(v: Vec2): Vec2` - Negation

### Vektor-Operationen
- `Vec2Dot(a, b: Vec2): int64` - Skalarprodukt
- `Vec2Cross(a, b: Vec2): int64` - Kreuzprodukt (2D)
- `Vec2LengthSquared(v: Vec2): int64` - Länge²
- `Vec2Length(v: Vec2): int64` - Länge
- `Vec2DistanceSquared(a, b: Vec2): int64` - Abstand²
- `Vec2Distance(a, b: Vec2): int64` - Abstand
- `Vec2Normalize(v: Vec2): Vec2` - Normalisieren (auf 1.0)
- `Vec2NormalizeSafe(v, fallback: Vec2): Vec2` - Safe Normalize

### Interpolation
- `Vec2Lerp(a, b: Vec2, t: int64): Vec2` - Lineare Interpolation (t: 0-1000000)
- `Vec2Clamp(v, min, max: Vec2): Vec2` - Begrenzen

### Rotation
- `Vec2Rotate(v: Vec2, angle_deg: int64): Vec2` - Rotation (Microdegrees)
- `Vec2Rotate90(v: Vec2): Vec2` - 90° gegen Uhrzeigersinn
- `Vec2Rotate180(v: Vec2): Vec2` - 180° Rotation
- `Vec2Rotate270(v: Vec2): Vec2` - 270° Rotation

### Vergleich
- `Vec2Equal(a, b: Vec2): bool` - Gleichheit
- `Vec2NotEqual(a, b: Vec2): bool` - Ungleichheit
- `Vec2IsZero(v: Vec2): bool` - Nullvektor?

### Min/Max
- `Vec2Min(a, b: Vec2): Vec2` - Komponentenweises Minimum
- `Vec2Max(a, b: Vec2): Vec2` - Komponentenweises Maximum
- `Vec2Abs(v: Vec2): Vec2` - Komponentenweiser Absolutwert
- `Vec2Sign(v: Vec2): Vec2` - Komponentenweises Vorzeichen

### Projektion
- `Vec2Perpendicular(v: Vec2): Vec2` - Senkrechter Vektor
- `Vec2Project(v, onto: Vec2): Vec2` - Projektion auf Vektor
- `Vec2Reflect(v, normal: Vec2): Vec2` - Reflexion an Normalen

### Winkel
- `Vec2AngleTo(v, target: Vec2): int64` - Winkel zu Ziel (Microdegrees)
- `Vec2Heading(v: Vec2): int64` - Winkel von X-Achse (Microdegrees)

---

## std/rect.lyx

Rechteck und Bounding Box utilities.

### Rect Struct
```lyx
struct Rect {
  min: Vec2,  // Minimum (top-left)
  max: Vec2   // Maximum (bottom-right)
}
```

### Konstruktoren
- `RectNew(min, max: Vec2): Rect` - Aus Min/Max
- `RectFromPoints(p1, p2: Vec2): Rect` - Aus zwei Punkten
- `RectFromCenterSize(center, size: Vec2): Rect` - Aus Zentrum und Größe
- `RectEmpty(): Rect` - Leeres Rechteck
- `RectFromXYWH(x, y, w, h: int64): Rect` - Aus x,y,width,height

### Eigenschaften
- `RectWidth(r: Rect): int64` - Breite
- `RectHeight(r: Rect): int64` - Höhe
- `RectSize(r: Rect): Vec2` - Größe als Vec2
- `RectCenter(r: Rect): Vec2` - Zentrum
- `RectArea(r: Rect): int64` - Fläche
- `RectIsEmpty(r: Rect): bool` - Leer?
- `RectIsValid(r: Rect): bool` - Gültig?

### Punkt-Tests
- `RectContains(r: Rect, p: Vec2): bool` - Punkt enthalten (inkl. Rand)
- `RectContainsInclusive(r: Rect, p: Vec2): bool` - Punkt enthalten (exkl. Rand)

### Rechteck-Operationen
- `RectInflate(r: Rect, amount: int64): Rect` - Aufblähen
- `RectDeflate(r: Rect, amount: int64): Rect` - Verkleinern
- `RectExpand(r: Rect, p: Vec2): Rect` - Mit Punkt erweitern
- `RectUnion(a, b: Rect): Rect` - Vereinigung
- `RectIntersect(a, b: Rect): Rect` - Schnitt
- `RectIntersects(a, b: Rect): bool` - Überlappen?

### Ecken
- `RectTopLeft(r: Rect): Vec2` - Oben links
- `RectTopRight(r: Rect): Vec2` - Oben rechts
- `RectBottomLeft(r: Rect): Vec2` - Unten links
- `RectBottomRight(r: Rect): Vec2` - Unten rechts

### Seiten
- `RectLeft(r: Rect): int64`, `RectRight`, `RectTop`, `RectBottom`

---

## std/circle.lyx

Circle, Range und 2D-Range utilities.

### Circle Struct
```lyx
struct Circle {
  center: Vec2,
  radius: int64
}
```

### Circle Konstruktoren
- `CircleNew(center: Vec2, radius: int64): Circle`
- `CircleFromXYR(x, y, r: int64): Circle`
- `CircleFromPoints(p1, p2: Vec2): Circle` - Aus zwei Punkten
- `CircleUnit(): Circle` - Einheitskreis

### Circle Eigenschaften
- `CircleDiameter(c: Circle): int64` - Durchmesser
- `CircleArea(c: Circle): int64` - Fläche (πr²)
- `CircleCircumference(c: Circle): int64` - Umfang (2πr)

### Circle Tests
- `CircleContainsPoint(c: Circle, p: Vec2): bool` - Punkt enthalten?
- `CircleContainsCircle(c, inner: Circle): bool` - Kreis enthalten?
- `CircleIntersectsCircle(a, b: Circle): bool` - Kreise schneiden?
- `CircleIntersectsRect(c: Circle, r: Rect): bool` - Kreis-Rechteck?

### Range (1D Intervall)
```lyx
struct Range {
  min: int64,
  max: int64
}
```

### Range Funktionen
- `RangeNew(min, max: int64): Range` - Range erstellen
- `RangeFromValue(value, delta: int64): Range` - Aus Wert ± Delta
- `RangeLength(r: Range): int64` - Länge
- `RangeContains(r: Range, value: int64): bool` - Wert enthalten?
- `RangeIntersects(r, other: Range): bool` - Überlappen?

### Range2D (2D Bounding Box)
- `Range2DNew(x, y: Range): Range2D`
- `Range2DFromPoints(p1, p2: Vec2): Range2D`
- `Range2DToRect(r2d: Range2D): Rect`

---

## std/color.lyx

RGBA Farben für Visualisierung.

### Color Struct
```lyx
struct Color {
  r: int64,  // 0-255
  g: int64,  // 0-255
  b: int64,  // 0-255
  a: int64   // 0-255 (255 = opaque)
}
```

### Konstruktoren
- `ColorNew(r, g, b, a: int64): Color` - RGBA
- `ColorRGB(r, g, b: int64): Color` - RGB (alpha = 255)
- `ColorRGBA(r, g, b, a: int64): Color` - Alias für ColorNew
- `ColorGray(gray: int64): Color` - Graustufen
- `ColorEmpty(): Color` - Transparent schwarz

### Preset Colors
- `ColorBlack()`, `ColorWhite()`, `ColorRed()`, `ColorGreen()`, `ColorBlue()`
- `ColorYellow()`, `ColorCyan()`, `ColorMagenta()`, `ColorOrange()`
- `ColorPurple()`, `ColorPink()`, `ColorBrown()`
- `ColorGrayLight()`, `ColorGrayDark()`

### Eigenschaften
- `ColorIsOpaque(c: Color): bool` - Vollständig deckend?
- `ColorIsTransparent(c: Color): bool` - Vollständig transparent?
- `ColorIsValid(c: Color): bool` - Gültige Werte?

### Manipulation
- `ColorWithAlpha(c: Color, alpha: int64): Color` - Alpha ändern
- `ColorInvert(c: Color): Color` - Invertieren
- `ColorGrayscale(c: Color): Color` - Graustufen
- `ColorBrighten(c: Color, amount: int64): Color` - Aufhellen
- `ColorDarken(c: Color, amount: int64): Color` - Abdunkeln

### Blending
- `ColorBlend(src, dst: Color): Color` - Alpha-Blending
- `ColorMultiply(c1, c2: Color): Color` - Multiplikations-Blend

### Interpolation
- `ColorLerp(c1, c2: Color, t: int64): int64` - Lineare Interpolation (t: 0-1000)
- `ColorMix(c1, c2: Color): Color` - 50/50 Mix

### Hex-Konvertierung
- `ColorFromHex(hex: int64): Color` - Aus Hex (0xRRGGBB)
- `ColorToHex(c: Color): int64` - Zu Hex
- `ColorToHexARGB(c: Color): int64` - Zu Hex mit Alpha

### HSL
- `ColorFromHSL(h, s, l: int64): Color` - Aus HSL (h: 0-360, s,l: 0-255)
- `ColorToHSL(c: Color): array[3]int64` - Zu HSL [h, s, l]

---

## std/list.lyx

Dynamische Container: Listen, RingBuffer, Stack, Queue.

### ListInt64 (Klasse mit Heap)
```lyx
class ListInt64 {
  data: int64,
  length: int64,
  capacity: int64
}
```

### ListInt64 Funktionen
- `ListInt64New(): ListInt64` - Neue Liste erstellen
- `ListInt64WithCapacity(capacity: int64): ListInt64`
- `ListInt64Add(list: ListInt64, value: int64): void`
- `ListInt64Get(list: ListInt64, index: int64): int64`
- `ListInt64Set(list: ListInt64, index, value: int64): void`
- `ListInt64Len(list: ListInt64): int64`

### StaticList (Statische Arrays, kein Heap)
- `StaticList8` - 8 Elemente
- `StaticList16` - 16 Elemente

Funktionen: `New()`, `Add()`, `Get()`, `Set()`, `Len()`, `Clear()`, `IsEmpty()`

### Vec2List (für Routen/Polygone)
```lyx
struct Vec2List {
  data: array[64]Vec2,
  length: int64
}
```
- `Vec2ListNew(): Vec2List`
- `Vec2ListAdd(list: Vec2List, value: Vec2): bool`
- `Vec2ListGet(list: Vec2List, index: int64): Vec2`
- `Vec2ListLast(list: Vec2List): Vec2` - Letztes Element
- `Vec2ListPushBack()`, `Vec2ListPopBack()`

### RingBufferVec2 (GPS-Tracking)
```lyx
struct RingBufferVec2 {
  data: array[128]Vec2,
  head: int64,
  tail: int64,
  count: int64,
  capacity: int64
}
```
- `RingBufferVec2New(): RingBufferVec2`
- `RingBufferVec2WithCapacity(cap: int64): RingBufferVec2`
- `RingBufferVec2Push(rb: RingBufferVec2, value: Vec2): void`
- `RingBufferVec2Pop(rb: RingBufferVec2): Vec2`
- `RingBufferVec2Peek(rb: RingBufferVec2): Vec2` - Nächstes ohne Entfernen
- `RingBufferVec2Len(rb: RingBufferVec2): int64`

### StackInt64 (LIFO)
```lyx
struct StackInt64 {
  data: array[32]int64,
  top: int64
}
```
- `StackInt64New(): StackInt64`
- `StackInt64Push(s: StackInt64, value: int64): bool`
- `StackInt64Pop(s: StackInt64): int64`
- `StackInt64Peek(s: StackInt64): int64`

### QueueInt64 (FIFO)
```lyx
struct QueueInt64 {
  data: array[32]int64,
  front: int64,
  rear: int64,
  count: int64
}
```
- `QueueInt64New(): QueueInt64`
- `QueueInt64Enqueue(q: QueueInt64, value: int64): bool`
- `QueueInt64Dequeue(q: QueueInt64): int64`

---

## std/result.lyx

Result/Option Pattern für robustes Error-Handling (wie Rust).

### Error Codes (Konstanten)
```lyx
ERR_NONE = 0
ERR_UNKNOWN = 1
ERR_INVALID_INPUT = 2
ERR_OUT_OF_BOUNDS = 3
ERR_DIVISION_BY_ZERO = 4
ERR_OVERFLOW = 5
ERR_UNDERFLOW = 6
ERR_PARSE_ERROR = 7
ERR_NOT_FOUND = 8
ERR_ALREADY_EXISTS = 9
ERR_PERMISSION_DENIED = 10
ERR_IO = 11
ERR_OUT_OF_MEMORY = 12
ERR_NOT_IMPLEMENTED = 13
```

### ResultInt64
```lyx
struct ResultInt64 {
  success: bool,
  value: int64,
  error_code: int64
}
```

### ResultInt64 Funktionen
- `OkInt64(value: int64): ResultInt64` - Erfolgreich
- `ErrInt64(error_code: int64): ResultInt64` - Fehler
- `ResultInt64IsOk(r: ResultInt64): bool` - Erfolgreich?
- `ResultInt64IsErr(r: ResultInt64): bool` - Fehler?
- `ResultInt64Unwrap(r: ResultInt64): int64` - Wert holen (panic bei Fehler)
- `ResultInt64UnwrapOr(r: ResultInt64, default: int64): int64` - Mit Default
- `ResultInt64Error(r: ResultInt64): int64` - Fehlercode holen

### ResultVec2
- `OkVec2(value: Vec2): ResultVec2`
- `ErrVec2(error_code: int64): ResultVec2`
- `ResultVec2IsOk/isErr/Unwrap/UnwrapOr/Error`

### OptionInt64 (Some/None)
```lyx
struct OptionInt64 {
  has_value: bool,
  value: int64
}
```
- `SomeInt64(value: int64): OptionInt64`
- `NoneInt64(): OptionInt64`
- `OptionInt64IsSome/IsNone/Unwrap/UnwrapOr`

### Safe Arithmetic
- `SafeAdd(a, b: int64): ResultInt64` - Mit Overflow-Check
- `SafeSub(a, b: int64): ResultInt64`
- `SafeMul(a, b: int64): ResultInt64`
- `SafeDiv(a, b: int64): ResultInt64` - Mit Division-by-Zero Check
- `SafeMod(a, b: int64): ResultInt64`

### Safe Array Access
- `SafeArrayGet(arr, len, index: int64): ResultInt64` - Mit Bounds-Check
- `SafeArraySet(arr, len, index, value: int64): ResultBool`

---

## std/string.lyx

### Kompatibilität
- `StrCopy(dest, src: pchar): pchar` - String kopieren
- `StrCpy(dest, src: pchar): pchar` - Alias für StrCopy

### String-Suche
- `StrFind(haystack, needle: pchar): int64` - Erste Position oder -1
- `StrSafeCharAt(s: pchar, index: int64): int64` - Sicherer Zeichen-Zugriff
- `StrContains(s, needle: pchar): bool` - Enthält Substring?
- `StrIndexOf(s, needle: pchar, startIndex: int64): int64` - Position ab Index
- `StrLastIndexOfChar(s: pchar, c: int64): int64` - Letzte Zeichen-Position
- `StrAllIndicesOfCharCount(s: pchar, c: int64): int64` - Zeichen-Anzahl

### Boolean-Tests
- `StrEquals(s1, s2: pchar): bool` - Gleichheit
- `StrStartsWith(s, prefix: pchar): bool` - Beginnt mit Prefix?
- `StrEndsWith(s, suffix: pchar): bool` - Endet mit Suffix?

### Case-Konvertierung
- `CharToLower(c: int64): int64` - Einzelnes Zeichen zu Kleinbuchstabe
- `CharToUpper(c: int64): int64` - Einzelnes Zeichen zu Großbuchstabe
- `StrToLower(dest, src: pchar): pchar` - String zu Kleinbuchstaben
- `StrToUpper(dest, src: pchar): pchar` - String zu Großbuchstaben
- `StrFirstCharToUpper(s: pchar): pchar` - Erster Buchstabe groß
- `StrFirstCharToLower(s: pchar): pchar` - Erster Buchstabe klein
- `StrLastCharToUpper(s: pchar): pchar` - Letzter Buchstabe groß
- `StrLastCharToLower(s: pchar): pchar` - Letzter Buchstabe klein

### String-Manipulation
- `StrConcat(dest, s1, s2: pchar): pchar` - Verketten
- `StrReverse(s: pchar): pchar` - Umkehren
- `StrTrimWhitespace(dest, src: pchar): pchar` - Whitespace entfernen
- `StrSubstring(dest, src: pchar, start, len: int64): pchar` - Teilstring
- `StrReplace(dest, src, old, new: pchar): pchar` - Ersetzen
- `IsWhitespace(c: int64): bool` - Ist Whitespace?
- `StrCount(s, needle: pchar): int64` - Vorkommen zählen

**Native Builtins** (direkt verfügbar):
- `StrLength(s: pchar): int64`
- `StrCharAt(s: pchar, i: int64): int64`
- `StrSetChar(s: pchar, i: int64, c: int64): void`
- `str_compare(a, b: pchar): int64`

---

## std/io.lyx

### Print-Funktionen
- `Print(s: pchar): void` - Ausgabe ohne Newline
- `PrintLn(s: pchar): void` - Ausgabe mit Newline
- `PrintLn(x: int64): void` - Integer mit Newline
- `PrintLn(x: f64): void` - Float mit Newline
- `PrintLn(b: bool): void` - Boolean mit Newline
- `PrintIntLn(x: int64): void` - Integer mit Newline (Alias)
- `ExitProc(code: int64): void` - Programm beenden
- `BoolToStr(b: bool): pchar` - Boolean zu String
- `FloatToStr(val: f64, prec: int64): pchar` - Float zu String

### Printf (pure-Lyx)
`Printf(fmt: pchar, ...)` - Formatierte Ausgabe

Unterstützte Platzhalter:
- `%s` - String (pchar)
- `%d` - Integer (int64)
- `%f` - Float (f64)
- `%%` - Literal %

Maximal 4 Platzhalter pro Aufruf. Überladene Varianten für alle Typkombinationen (0-4 Argumente).

---

## std/env.lyx

### Environment
- `Init(argc: int64, argv: pchar): void` - Explizite Initialisierung (optional)
- `ArgCount(): int64` - Anzahl Command-Line-Argumente
- `Arg(i: int64): pchar` - Argument i (0-basiert)

**Hinweis**: Seit v0.1.5 erfolgt die Initialisierung automatisch.

---

## std/time.lyx

### Kalender-Berechnungen
- `DaysFromCivil(year, month, day: int64): int64` - Tage seit Epoch
- `CivilYearFromDays(days: int64): int64` - Jahr aus Tagen
- `CivilMonthFromDays(days: int64): int64` - Monat aus Tagen
- `CivilDayFromDays(days: int64): int64` - Tag aus Tagen
- `IsLeapYear(year: int64): bool` - Schaltjahr?
- `DayOfWeekFromDate(d: date): int64` - Wochentag (0=Sonntag)
- `DaysInMonth(year, month: int64): int64` - Tage im Monat

### Datum/Zeit-Typen
- `DateFromYmd(year, month, day: int64): date` - Datum erstellen
- `YearFromDate(d: date): int64` - Jahr aus Datum
- `MonthFromDate(d: date): int64` - Monat aus Datum
- `DayFromDate(d: date): int64` - Tag aus Datum
- `TimeFromHms(hour, minute, second: int64): time` - Zeit erstellen
- `HourFromTime(t: time): int64` - Stunde aus Zeit
- `MinuteFromTime(t: time): int64` - Minute aus Zeit
- `SecondFromTime(t: time): int64` - Sekunde aus Zeit
- `DatetimeFromUnixSeconds(sec: int64): datetime` - DateTime aus Epoch
- `DatetimeToUnixSeconds(dt: datetime): int64` - DateTime zu Epoch
- `TimestampFromUnixSeconds(sec: int64): timestamp` - Timestamp (Mikrosec)
- `UnixSecondsFromTimestamp(ts: timestamp): int64` - Timestamp zu Epoch

### Systemzeit
- `Now(): datetime` - Aktuelle Zeit (Sekunden seit Epoch)
- `NowUs(): timestamp` - Aktuelle Zeit (Mikrosekunden)
- `NowMs(): int64` - Aktuelle Zeit (Millisekunden)

### Konstanten
- `SECOND: int64` - 1.000.000 (Mikrosekunden)
- `MINUTE: int64` - 60 * SECOND
- `HOUR: int64` - 60 * MINUTE
- `DAY: int64` - 24 * HOUR

### Zeitzonen
- `TimeZone` - Struct mit name und offset_seconds
- `ZoneUTC(): TimeZone`
- `ZoneCET(): TimeZone`
- `ZoneCEST(): TimeZone`
- `ApplyTimeZone(dt: datetime, zone: TimeZone): datetime`

### Formatierung
- `ToIsoDateString(d: date): string` - Datum als "YYYY-MM-DD"
- `IntToString(n: int64): string` - Integer zu String

---

## std/geo.lyx

### Koordinaten-System
Alle Koordinaten werden als **Microdegrees** (int64) gespeichert:
- 1° = 1.000.000 µ°

### Parsing & Formatierung
- `ParseLat(s: pchar): int64` - Breitengrad parsen
- `ParseLon(s: pchar): int64` - Längengrad parsen
- `FormatDecimal(coord: int64): pchar` - Koordinate als Dezimalstring

### Validierung
- `IsValidLat(lat: int64): bool` - Gültiger Breitengrad?
- `IsValidLon(lon: int64): bool` - Gültiger Längengrad?
- `IsValidGeoPoint(p: GeoPoint): bool` - Gültiger Punkt?

### Distanz-Berechnungen
- `DistanceM(p1, p2: GeoPoint): int64` - Distanz in Metern
- `DistanceKm(p1, p2: GeoPoint): int64` - Distanz in Kilometern
- `DistanceSq(p1, p2: GeoPoint): int64` - Quadrat-Distanz (für Vergleiche)
- `IsWithinDistanceM(p1, p2: GeoPoint, thresholdM: int64): bool` - Distanz-Schwelle
- `HaversineDistanceM(p1, p2: GeoPoint): int64` - Präzise Great-Circle Distanz
- `DistanceMCorrected(p1, p2: GeoPoint): int64` - Mit Cosinus-Korrektur

### GeoPoint-Hilfen
- `GeoPointNew(lon, lat: int64): GeoPoint` - Punkt erstellen

### Mittelpunkt
- `Midpoint(p1, p2: GeoPoint): GeoPoint` - Mittelpunkt zweier Punkte
- `MidpointLat(lat1, lat2: int64): int64` - Breitengrad-Mittelpunkt
- `MidpointLon(lon1, lon2: int64): int64` - Längengrad-Mittelpunkt

### BoundingBox
- `IsPointInRect(p, min, max: GeoPoint): bool` - Punkt im Rechteck?
- `BoundingBoxFromPoints(p1, p2: GeoPoint): [GeoPoint, GeoPoint]` - BoundingBox
- `DoBoundingBoxesOverlap(min1, max1, min2, max2: GeoPoint): bool` - Überlappung?
- `BoundingBoxCenter(min, max: GeoPoint): GeoPoint` - Zentrum

### Navigation
- `Bearing(p1, p2: GeoPoint): int64` - Peilung/Richtung (Microdegrees)
- `CalculateBoundingBox(center: GeoPoint, radiusM: int64): [GeoPoint, GeoPoint]` - Umkreis
- `AddOffsetM(center: GeoPoint, bearing, distanceM: int64): GeoPoint` - Offset
- `CorrectLongitudeForLatitude(dLon, lat: int64): int64` - Cosinus-Korrektur

### DMS-Format
- `ParseDMS(degrees, minutes, seconds, direction: int64): int64` - DMS zu Microdegrees
- `FormatDMS(coord: int64, isLatitude: bool): pchar` - Microdegrees zu DMS

### Polygon
- `IsPointInPolygon(p: GeoPoint, polygon: [GeoPoint]): bool` - Punkt im Polygon

**Konstanten:**
- `EARTH_RADIUS_METERS: int64` - 6.371.000 m

---

## std/crt.lyx

### Farben (ANSI)
- `crt_color` - Enum: black, blue, green, cyan, red, magenta, brown, light_gray, dark_gray, light_blue, light_green, light_cyan, light_red, light_magenta, yellow, white

### Farb-Funktionen
- `TextColor(c: crt_color): void` - Vordergrundfarbe
- `TextBackground(c: crt_color): void` - Hintergrundfarbe
- `TextAttr(fg, bg: crt_color): void` - Beide Farben
- `ResetAttr(): void` - Attribute zurücksetzen

### Cursor & Bildschirm
- `ClrScr(): void` - Bildschirm löschen
- `ClrEol(): void` - Bis Zeilenende löschen
- `GoToXY(col, row: int64): void` - Cursor setzen (1-basiert)
- `HideCursor(): void` - Cursor verstecken
- `ShowCursor(): void` - Cursor anzeigen

### Ausgabe
- `WriteStrAt(col, row: int64, s: pchar): void` - String an Position

### Eingabe
- `ReadChar(): int64` - Blocking-Lesen (benötigt libc)

---

## std/crt_raw.lyx (experimentell)

**WICHTIG**: Diese Unit erfordert dynamisches Linking (libc).

### Raw-Mode
- `SetRawMode(enabled: bool): int64` - Raw-Mode aktivieren
- `KeyPressed(): bool` - Prüfen ob Taste wartet
- `ReadKeyRaw(): int64` - Non-blocking Lesen

---

## std/pack.lyx

Binary Serialisierung für Lyx-Datenstrukturen.

### VarInt
- `WriteVarInt(buf: pchar, pos, val: int64): int64` - VarInt schreiben
- `ReadVarInt(buf: pchar, pos: int64): int64` - VarInt lesen
- `VarIntSize(val: int64): int64` - Größe berechnen

### Integer-Packen
- `PackInt64(buf: pchar, pos, val: int64): int64` - 8 Bytes schreiben
- `UnpackInt64(buf: pchar, pos: int64): int64` - 8 Bytes lesen
- `PackInt32(...)` / `UnpackInt32(...)` - 4 Bytes
- `PackInt16(...)` / `UnpackInt16(...)` - 2 Bytes
- `PackInt8(...)` / `UnpackInt8(...)` - 1 Byte

### Boolean
- `PackBool(buf: pchar, pos: int64, val: bool): int64` - Boolean schreiben
- `UnpackBool(buf: pchar, pos: int64): bool` - Boolean lesen

### Float
- `PackFloat64(buf: pchar, pos: int64, val: f64): int64` - 8 Bytes IEEE 754
- `UnpackFloat64(buf: pchar, pos: int64): f64`
- `PackFloat32(...)` / `UnpackFloat32(...)` - 4 Bytes

### String
- `PackString(buf: pchar, pos: int64, s: pchar): int64` - Varint-Length + UTF-8
- `UnpackString(buf: pchar, pos: int64): pchar`
- `StringPackSize(s: pchar): int64` - Pack-Größe

### Spezial
- `PackNull(buf: pchar, pos: int64): int64` - Null-Marker (0xFF)
- `IsNull(buf: pchar, pos: int64): bool` - Null prüfen
- `PackArrayStart(buf: pchar, pos, count: int64): int64` - Array-Header
- `UnpackArrayStart(buf: pchar, pos: int64): int64` - Array-Header lesen

---

## std/regex.lyx

### Zeichen-Klassen
- `isAlpha(c: int64): bool` - Buchstabe?
- `isDigit(c: int64): bool` - Ziffer?
- `isAlnum(c: int64): bool` - Alphanumerisch?
- `isWhitespace(c: int64): bool` - Whitespace?

### Regex-Operationen
- `RegexMatch(pattern, text: pchar): bool` - Vollständiger Match
- `RegexSearch(pattern, text: pchar): int64` - Erste Position oder -1
- `RegexReplace(pattern, text, replacement: pchar): int64` - Ersetzen (0/1)

---

## std/fs.lyx

Dateisystem-Operationen.

### Typen
- `fd` - File Descriptor (int64)

### Konstanten (Flags)
**Zugriffsmodi:**
- `O_RDONLY` - Nur Lesen
- `O_WRONLY` - Nur Schreiben
- `O_RDWR` - Lesen und Schreiben

**Status-Flags:**
- `O_CREAT` - Erstellen falls nicht existent
- `O_TRUNC` - Auf 0 Bytes kürzen
- `O_APPEND` - Anhängen
- `O_EXCL` - Fehler falls existent

**Rechte:**
- `S_IRUSR`, `S_IWUSR` - Owner read/write
- `S_IRGRP`, `S_IWGRP` - Group read/write
- `S_IROTH`, `S_IWOTH` - Other read/write
- `DEFAULT_MODE` - 0644

**Seek-Positionen:**
- `SEEK_SET` - Vom Anfang
- `SEEK_CUR` - Von aktueller Position
- `SEEK_END` - Vom Ende

**Standard-FDs:**
- `STDIN_FILENO` - 0
- `STDOUT_FILENO` - 1
- `STDERR_FILENO` - 2

### Datei-Operationen
- `IsValidFd(f: fd): bool` - Gültiger FD?
- `ReadFile(path, buf: pchar, max_len: int64): int64` - Datei lesen
- `WriteFile(path, buf: pchar, len: int64): int64` - Datei schreiben
- `AppendFile(path, buf: pchar, len: int64): int64` - Anhängen
- `DeleteFile(path: pchar): bool` - Löschen
- `FileExists(path: pchar): bool` - Existiert Datei?
- `FileSize(path: pchar): int64` - Dateigröße

### Standard-I/O
- `StdoutWrite(buf: pchar, len: int64): int64` - stdout
- `StderrWrite(buf: pchar, len: int64): int64` - stderr
- `PutChar(c: int64): int64` - Zeichen ausgeben

### Path-Funktionen
- `PathNormalize(dest, src: pchar): pchar` - Pfad normalisieren (`./`, `../`, `//` auflösen)
- `PathDir(dest, path: pchar): pchar` - Verzeichnis-Teil zurückgeben
- `PathExt(dest, path: pchar): pchar` - Extension mit Punkt zurückgeben
- `PathBase(dest, path: pchar): pchar` - Basis-Dateiname ohne Extension
- `PathResolve(dest, base, relative: pchar): pchar` - Pfad auflösen (JoinHoch)

---

## std/process.lyx

Prozess-Management für CLI-Tools und System-Integration.

### Typen
- `Process` - Process Handle (int64, speichert PID)
- `ExitCode` - Exit-Status (0 = Erfolg, >0 = Fehler)

### Konstanten
- `WNOHANG` - Non-blocking wait
- `SIGTERM` - 15 (graceful termination)
- `SIGKILL` - 9 (force termination)

### Process API
- `spawn(prog: pchar): Process` - Prozess asynchron starten, gibt PID zurück
- `run(prog: pchar): ExitCode` - Prozess synchron starten & warten
- `wait(pid: int64): ExitCode` - Auf Prozess warten (blockierend)
- `try_wait(pid: int64): ExitCode` - Warten ohne Blockieren (-2 wenn noch läuft)
- `is_running(pid: int64): bool` - Prüfen ob Prozess läuft
- `kill(pid, sig: int64): int64` - Signal senden
- `terminate(pid: int64): int64` - Graceful beenden (SIGTERM)
- `terminate_force(pid: int64): int64` - Force beenden (SIGKILL)
- `self_pid(): int64` - Eigene PID abrufen

### Shell
- `shell(cmd: pchar): ExitCode` - Shell-Befehl ausführen (`/bin/sh -c "cmd"`)
  - **Warnung**: Sicherheitsrisiko bei User-Input!

**Beispiel:**
```lyx
import std.process;

fn main(): int64 {
  // Synchron: warten auf Beendigung
  var exit_code: int64 := run("/bin/ls");
  
  // Asynchron: PID holen und später warten
  var pid: int64 := spawn("/bin/sleep");
  // ... andere Arbeit ...
  exit_code := wait(pid);
  
  return 0;
}
```

---

## std/json.lyx

JSON Parser und Serializer für Lyx.

### Typen
- `JSON` - JSON Value Handle
- `JSON_NULL`, `JSON_BOOL`, `JSON_NUMBER`, `JSON_STRING`, `JSON_ARRAY`, `JSON_OBJECT`

### Fehler-Codes
- `ERR_JSON_OK` - Kein Fehler
- `ERR_JSON_INVALID` - Ungültiges JSON
- `ERR_JSON_EXPECTED` - Erwartetes Token nicht gefunden
- `ERR_JSON_EOF` - Unerwartetes Ende
- `ERR_JSON_ESCAPE` - Ungültige Escape-Sequenz

### Validierung
- `isValidJSON(s: pchar): bool` - Prüft ob String gültiges JSON ist

### Parsing
- `parseArray(dest, src: pchar): int64` - Parst JSON-Array zu Pipe-getrenntem String
- `parseValue(dest, src: pchar): int64` - Parst einzelnen JSON-Wert (gibt Typ zurück)
- `toArray(dest, json_str: pchar): pchar` - Komfort-Wrapper für parseArray

### Serialisierung
- `serializeArray(dest, src: pchar): pchar` - Pipe-String zu JSON-Array
- `serializeValue(dest, value: pchar, json_type: int64): pchar` - Einzelwert zu JSON
- `JSONEscape(dest, src: pchar): pchar` - String für JSON escapen
- `stringify(dest, pipe_str: pchar): pchar` - Komfort-Wrapper für serializeArray

**Hinweis**: Arrays werden intern als Pipe-getrennte Strings verarbeitet (`"a|b|c"`).

**Beispiel:**
```lyx
import std.json;

// Parse
var arr: pchar := "                                                                                ";
toArray(arr, '["Node1","Node2","Node3"]');
// arr = "Node1|Node2|Node3"

// Serialize
var json: pchar := "                                                                                ";
stringify(json, "Status|200|OK");
// json = ["Status","200","OK"]
```

---

## Verwendung

### Basis-Import
```lyx
import std.math;
import std.io;
import std.string;
import std.env;

fn main(argc: int64, argv: pchar): int64 {
  PrintIntLn(ArgCount());
  PrintLn(Arg(0));
  return 0;
}
```

### CRT Demo
```lyx
import std.crt;

fn main(): int64 {
  ClrScr();
  TextAttr(white, blue);
  WriteStrAt(1, 1, "Lyx CRT Demo");
  ResetAttr();
  return 0;
}
```

### Geo-Beispiel
```lyx
import std.geo;

fn main(): int64 {
  var berlin: GeoPoint := GeoPointNew(13400000, 52500000);  // 13.4°, 52.5°
  var paris: GeoPoint := GeoPointNew(2300000, 48800000);   // 2.3°, 48.8°
  var dist: int64 := DistanceM(berlin, paris);
  PrintIntLn(dist);  // in Metern
  return 0;
}
```

---

*Hinweis: Zusätzlich stehen 22 native Math-Builtins zur Verfügung (siehe Haupt-README).*
