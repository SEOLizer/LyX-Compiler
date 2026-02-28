Standard-Units (std)
====================

Dieses Verzeichnis enthält standardisierte Units, die als umfassende Bibliothek für Lyx-Programme dienen. Die Libraries kombinieren native Builtin-Funktionen mit ergonomischen Wrapper-Funktionen und erweiterten Utilities.

## Übersicht der verfügbaren Units

| Unit | Beschreibung |
|------|--------------|
| `std/math` | Integer-Mathematik, Fixed-Point, Trigonometrie |
| `std/string` | String-Manipulation und -Suche |
| `std/io` | Print/Printf, Formatierung |
| `std/env` | Command-Line Argumente |
| `std/time` | Datum/Zeit, Kalenderfunktionen |
| `std/geo` | Geolocation, Koordinaten, Distanzen |
| `std/crt` | ANSI Terminal-Steuerung |
| `std/crt_raw` | Raw-Mode Input (experimentell) |
| `std/pack` | Binary Serialisierung |
| `std/regex` | Regex-Matching |
| `std/fs` | Dateisystem-Operationen |

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
- `Clamp64(val, min, max: int64): int64` - Wert begrenzen
- `Sign64(x: int64): int64` - Vorzeichen (-1, 0, 1)
- `Pow64(base, exp: int64): int64` - Potenz (base^exp)
- `InRange64(val, min, max: int64): bool` - Prüft Bereichszugehörigkeit
- `Round64(x: int64): int64` - Runden

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
