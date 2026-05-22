# Lyx PDF-Bibliothek (`std/pdf`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für `std/pdf`, die
offizielle PDF-Standardbibliothek von Lyx. Ziel ist eine vollständige, portable
Bibliothek zum **Erstellen, Lesen und Bearbeiten** von PDF-Dateien — ohne externe
Abhängigkeiten wie libpoppler oder libharu.

**Konvention:** WP-PDF-NN (PDF Library, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.pdf;

pub fn main(): int64 {
  var doc: int64 := PdfNew();
  var page: int64 := PdfAddPage(doc, PDF_A4_W, PDF_A4_H);

  PdfSetFont(doc, page, PDF_FONT_HELVETICA_BOLD, 24.0);
  PdfTextAt(doc, page, 72.0, 760.0, "Hallo aus Lyx!");

  PdfSetFont(doc, page, PDF_FONT_HELVETICA, 12.0);
  PdfTextAt(doc, page, 72.0, 720.0, "Dieses PDF wurde in reinem Lyx erzeugt.");

  PdfSetStrokeColor(doc, page, 0.0, 0.4, 0.8);
  PdfRect(doc, page, 72.0, 700.0, 200.0, 2.0);
  PdfFill(doc, page);

  PdfSave(doc, "output.pdf");
  PdfFree(doc);
  return 0;
}
```

`std/pdf` soll sich so selbstverständlich anfühlen wie `std/io` — minimale API,
keine manuelle Speicherverwaltung von Objekten, deterministischer Output.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│                       std/pdf (public API)                   │
│  PdfNew / PdfAddPage / PdfTextAt / PdfRect / PdfSave ...     │
└────────────────────────────┬─────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────┐
│                      pdf/builder.lyu                         │
│  Objekt-Pool · XRef-Tabelle · Content-Stream-Builder         │
└──────┬──────────────────────┬──────────────────────┬─────────┘
       │                      │                      │
┌──────▼──────┐   ┌───────────▼────────┐   ┌────────▼──────────┐
│ pdf/         │   │ pdf/               │   │ pdf/              │
│ objects.lyu  │   │ graphics.lyu       │   │ fonts.lyu         │
│ (Obj/Dict/  │   │ (Pfade, Farben,    │   │ (Standard-14,     │
│  Stream/Ref)│   │  Bilder)           │   │  TrueType-Subset) │
└─────────────┘   └────────────────────┘   └───────────────────┘
```

### Datei-Überblick

```
std/
  pdf.lyu                  ← öffentliche API (PdfNew, PdfAddPage, …)
  pdf/
    objects.lyu            ← PDF-Objekte: Integer, String, Name, Dict, Array, Stream, Ref
    builder.lyu            ← Dokument-Builder: Objekt-Allokation, XRef, Trailer
    page.lyu               ← Seiten-Baum, MediaBox, Ressourcen-Dict
    graphics.lyu           ← Content-Stream: Pfade, Farben, Transformationen
    fonts.lyu              ← Standard-14-Fonts, Glyphen-Metriken, TrueType-Subset
    images.lyu             ← JPEG-Inlining, Pixel-Images (DCTDecode, FlateDecode)
    compress.lyu           ← Deflate/zlib für Content-Streams (FlateDecode)
    meta.lyu               ← Dokumentinfo-Dict (Titel, Autor, Datum, Creator)
    annot.lyu              ← Annotierungen, URI-Links, Named Destinations
    parser.lyu             ← PDF-Lexer + Cross-Reference-Parser (Lesen)
    editor.lyu             ← Seiten extrahieren, zusammenführen, ersetzen
```

---

## PDF-Grundkonzepte

### Objektmodell

```
PDF-Datei =
  Header       (%PDF-1.4)
  Body         (N indirekte Objekte: "1 0 obj … endobj")
  XRef-Tabelle (Byte-Offsets aller Objekte)
  Trailer      (Root-Katalog, Objekt-Anzahl, XRef-Offset)
```

### Content-Stream-Operatoren (Auswahl)

| Operator | Bedeutung |
|----------|-----------|
| `BT … ET` | Text-Block Begin/End |
| `Tf` | Font + Größe setzen |
| `Td` | Text-Position verschieben |
| `Tj` | String ausgeben |
| `m / l / c` | Move/Line/Curve im Pfad |
| `re` | Rechteck als Pfad |
| `S / f / B` | Stroke / Fill / Stroke+Fill |
| `RG / rg` | Stroke-/Fill-Farbe (RGB) |
| `cm` | Current Transformation Matrix |
| `Do` | XObject (Bild) einbetten |

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | Fundament: Objekte, Builder, einfacher Text | PDF-01 – PDF-03 |
| 2 | Grafik: Pfade, Farben, Transformationen | PDF-04 – PDF-05 |
| 3 | Bilder und Komprimierung | PDF-06 – PDF-07 |
| 4 | Metadaten, Links, Annotierungen | PDF-08 – PDF-09 |
| 5 | Lesen & Bearbeiten bestehender PDFs | PDF-10 – PDF-11 |
| 6 | Erweiterte Typografie: TrueType-Einbettung | PDF-12 |

---

## Work Packages

---

### WP-PDF-01: PDF-Objektmodell & Grundstruktur ⬜

**Ziel:** Die internen Datenstrukturen für alle PDF-Objekttypen implementieren
und einen minimalen Dokument-Builder aufbauen, der ein valides (leeres) PDF
ausgeben kann.

**Zu implementieren:**

- Objekttypen als Tagged-Union im Heap:
  - `PDF_OBJ_INT`, `PDF_OBJ_REAL`, `PDF_OBJ_BOOL`, `PDF_OBJ_NULL`
  - `PDF_OBJ_STRING` (Byte-String), `PDF_OBJ_NAME` (`/Name`)
  - `PDF_OBJ_ARRAY`, `PDF_OBJ_DICT`
  - `PDF_OBJ_STREAM` (Dict + Byte-Daten), `PDF_OBJ_REF` (Obj-Nr, Gen-Nr)
- Objekt-Pool: festes Array indirekter Objekte, IDs vergeben per `PdfAllocObj()`
- XRef-Tabelle: Byte-Offset je Objekt, beim `PdfSave()` am Ende berechnet
- Serialisierer: jedes Objekt nach PDF-Syntax schreiben
- Minimales Dokument-Skelett: Catalog → Pages → leere Pages-Liste → Trailer

**Dateien:**
- `std/pdf/objects.lyu` — Typen, Allokation, Serialisierung
- `std/pdf/builder.lyu` — Objekt-Pool, XRef, Trailer, `PdfNew()`, `PdfSave()`

**Akzeptanzkriterien:**
- `PdfNew()` + `PdfSave("out.pdf")` erzeugt ein valides PDF ohne Seiten
- `pdfinfo out.pdf` (Poppler-Tool) meldet keine Fehler
- XRef-Offsets korrekt: `pdfinfo -f 1 -l 1` findet alle Objekte
- Round-trip: PDF kann mit Acrobat Reader / Evince geöffnet werden (leeres Dok)

---

### WP-PDF-02: Seitenmanagement ⬜

**Ziel:** Seiten anlegen, Seitengrößen definieren und den Pages-Baum korrekt
aufbauen.

**Zu implementieren:**

- `PdfAddPage(doc, width, height) → pageHandle`
- Vordefinierte Seitenformate als Konstanten:
  ```
  PDF_A4_W   = 595.28   PDF_A4_H   = 841.89
  PDF_A3_W   = 841.89   PDF_A3_H   = 1190.55
  PDF_LETTER_W = 612.0  PDF_LETTER_H = 792.0
  PDF_A5_W   = 419.53   PDF_A5_H   = 595.28
  ```
- Hochformat/Querformat: `PdfSetLandscape(doc, page)`
- Seitennummer abrufen: `PdfPageCount(doc) → int64`
- Inhalts-Stream je Seite: leerer `stream … endstream` als Platzhalter
- Ressourcen-Dictionary je Seite (Fonts, XObjects später befüllt)

**Dateien:**
- `std/pdf/page.lyu` — Pages-Tree, MediaBox, Ressourcen-Dict
- `std/pdf.lyu`      — `PdfAddPage`, Konstanten (public API)

**Akzeptanzkriterien:**
- `PdfNew()` + 3× `PdfAddPage()` + `PdfSave()` → PDF mit 3 leeren Seiten
- `pdfinfo out.pdf` zeigt `Pages: 3` und korrekte Dimensionen
- A4 Hochformat: MediaBox `[0 0 595.28 841.89]`

---

### WP-PDF-03: Textausgabe mit Standard-14-Fonts ⬜

**Ziel:** Text auf Seiten platzieren mit den 14 eingebetteten PDF-Standard-Fonts.
Kein externes Font-File nötig — alle Viewer kennen diese Fonts.

**Standard-14-Fonts:**

| Konstante | PostScript-Name |
|-----------|----------------|
| `PDF_FONT_HELVETICA` | Helvetica |
| `PDF_FONT_HELVETICA_BOLD` | Helvetica-Bold |
| `PDF_FONT_HELVETICA_OBLIQUE` | Helvetica-Oblique |
| `PDF_FONT_HELVETICA_BOLDOBLIQUE` | Helvetica-BoldOblique |
| `PDF_FONT_TIMES` | Times-Roman |
| `PDF_FONT_TIMES_BOLD` | Times-Bold |
| `PDF_FONT_TIMES_ITALIC` | Times-Italic |
| `PDF_FONT_TIMES_BOLDITALIC` | Times-BoldItalic |
| `PDF_FONT_COURIER` | Courier |
| `PDF_FONT_COURIER_BOLD` | Courier-Bold |
| `PDF_FONT_COURIER_OBLIQUE` | Courier-Oblique |
| `PDF_FONT_COURIER_BOLDOBLIQUE` | Courier-BoldOblique |
| `PDF_FONT_SYMBOL` | Symbol |
| `PDF_FONT_ZAPFDINGBATS` | ZapfDingbats |

**API:**
```lyx
PdfSetFont(doc, page, PDF_FONT_HELVETICA, 12.0)
PdfTextAt(doc, page, x, y, "Text")
PdfTextWidth(doc, fontId, size, "Text") → f64   // Breite in Punkten
PdfSetTextColor(doc, page, r, g, b)
PdfSetLineSpacing(doc, page, leading)
PdfTextBlock(doc, page, x, y, width, "Langer Text...")  // mit Zeilenumbruch
```

**Zu implementieren:**
- Font-Ressource im Seiten-Dict registrieren (`/F0 ... /Type /Font ...`)
- Content-Stream: `BT ... /F0 12 Tf ... x y Td (Text) Tj ET`
- PDF-String-Escaping: `(`, `)`, `\` maskieren
- Glyphen-Breiten-Tabellen für Helvetica (AFM-Daten) für `PdfTextWidth()`

**Dateien:**
- `std/pdf/fonts.lyu`    — Font-Registrierung, AFM-Metriken, String-Escape
- `std/pdf/graphics.lyu` — Content-Stream-Builder (`BT/ET`, `Tf`, `Td`, `Tj`)
- `std/pdf.lyu`          — `PdfSetFont`, `PdfTextAt`, `PdfTextWidth` (public API)

**Akzeptanzkriterien:**
- `PdfTextAt(doc, page, 72.0, 720.0, "Hallo Welt")` ist im PDF sichtbar
- Mehrere Fonts auf derselben Seite: korrekte Ressourcen-Refs
- `PdfTextWidth` gibt plausible Breite zurück (Helvetica 12pt "Hello" ≈ 32pt)
- Sonderzeichen `()\\` korrekt escaped; PDF öffnet ohne Fehler

---

### WP-PDF-04: Grafikprimitive ⬜

**Ziel:** Vektorgrafik-Grundbausteine: Linien, Rechtecke, Bézier-Kurven und
Polygone mit einstellbaren Farben, Linienstärken und Füllmodi.

**API:**
```lyx
// Farben
PdfSetStrokeColor(doc, page, r, g, b)   // 0.0–1.0
PdfSetFillColor(doc, page, r, g, b)
PdfSetStrokeColorCMYK(doc, page, c, m, y, k)
PdfSetFillColorCMYK(doc, page, c, m, y, k)

// Linienstil
PdfSetLineWidth(doc, page, width)
PdfSetLineCap(doc, page, cap)   // 0=butt, 1=round, 2=square
PdfSetLineJoin(doc, page, join) // 0=miter, 1=round, 2=bevel
PdfSetDash(doc, page, on, off)  // gestrichelte Linie

// Pfad-Konstruktion
PdfMoveTo(doc, page, x, y)
PdfLineTo(doc, page, x, y)
PdfCurveTo(doc, page, x1, y1, x2, y2, x3, y3)  // kubische Bézier
PdfRect(doc, page, x, y, w, h)
PdfClosePath(doc, page)
PdfCircle(doc, page, cx, cy, r)                 // via 4 Bézier-Segmente
PdfEllipse(doc, page, cx, cy, rx, ry)

// Pfad-Ausgabe
PdfStroke(doc, page)
PdfFill(doc, page)
PdfFillStroke(doc, page)
PdfClip(doc, page)

// Koordinatentransformation
PdfSaveState(doc, page)
PdfRestoreState(doc, page)
PdfTranslate(doc, page, tx, ty)
PdfScale(doc, page, sx, sy)
PdfRotate(doc, page, angle)  // Grad
```

**Zu implementieren:**
- Content-Stream-Operatoren: `m l c re h S f B W`
- Farb-Operatoren: `RG rg K k`
- Linienstil-Operatoren: `w J j d`
- Transformations-Operatoren: `cm q Q`
- Kreisannäherung: κ ≈ 0.5523 als Bézier-Kontrollpunkt-Faktor

**Dateien:**
- `std/pdf/graphics.lyu` — alle Pfad- und Transformations-Operatoren

**Akzeptanzkriterien:**
- Blaues ausgefülltes Rechteck (72, 72, 200, 100) sichtbar auf Seite
- Gestrichelte rote Linie von (100, 500) nach (400, 500)
- Kreis (cx=300, cy=400, r=50) korrekt als geschlossener Pfad dargestellt
- `PdfSaveState` / `PdfRestoreState` isolieren Farb-/Transform-Kontext korrekt

---

### WP-PDF-05: Deflate-Komprimierung für Content-Streams ⬜

**Ziel:** Content-Streams mit `FlateDecode` komprimieren, um die Ausgabe-Dateigröße
signifikant zu reduzieren.

**Hintergrund:** Unkomprimierte PDF-Streams enthalten redundante Operatoren-Texte.
Deflate (RFC 1951) reduziert Textinhalt typischerweise um 60–80 %.

**Zu implementieren:**
- Deflate-Encoder: DEFLATE Level 1 (fast) als Default, Level 6 optional
  - Option A: FFI auf `libz` (`zlib.h` — nahezu überall vorhanden)
  - Option B: reines Lyx (Huffman + LZ77, ~500 Zeilen)
- `PdfSetCompression(doc, level)` — 0=aus, 1=schnell, 6=ausgewogen, 9=maximal
- Stream-Dict bekommt `/Filter /FlateDecode` wenn Komprimierung aktiv
- Beim Lesen (WP-PDF-10): entsprechende Inflate-Unterstützung

**Dateien:**
- `std/pdf/compress.lyu` — Deflate/Inflate (FFI libz oder native)
- `std/pdf/builder.lyu`  — Stream-Komprimierung vor der Serialisierung

**Akzeptanzkriterien:**
- PDF mit `PdfSetCompression(doc, 6)`: Dateigröße ≤ 50 % des unkomprimierten PDFs
- `pdfinfo` und Evince/Acrobat öffnen das komprimierte PDF fehlerfrei
- `PdfSetCompression(doc, 0)` erzeugt weiterhin valides unkomprimiertes PDF

---

### WP-PDF-06: JPEG-Bildeinbettung ⬜

**Ziel:** JPEG-Bilder als XObjects in das PDF einbetten und auf Seiten platzieren.
JPEG ist das einzige nativ im PDF-Format unterstützte Bildformat (`DCTDecode`).

**API:**
```lyx
// Bild laden und registrieren
var imgId: int64 := PdfAddImageJpeg(doc, "foto.jpg")
var imgId: int64 := PdfAddImageJpegMem(doc, ptr, len)  // aus Puffer

// Bild auf Seite zeichnen
PdfDrawImage(doc, page, imgId, x, y, width, height)
PdfDrawImageFit(doc, page, imgId, x, y, maxW, maxH)    // Seitenverhältnis behalten
```

**Zu implementieren:**
- JPEG-Datei einlesen (rohe JPEG-Bytes, kein Dekodieren nötig — `DCTDecode`)
- JPEG-Header parsen: Breite, Höhe, Farbmodus (Graustufen/RGB/CMYK) aus SOF-Marker
- XObject-Dict: `/Type /XObject /Subtype /Image /Filter /DCTDecode /Width /Height /ColorSpace`
- Ressourcen-Dict der Seite: `/XObject << /Im0 N 0 R >>`
- Zeichnen: `q … cm /Im0 Do Q` (Transform-Matrix + Do-Operator)

**Dateien:**
- `std/pdf/images.lyu` — JPEG-Loader, XObject-Erstellung, `PdfDrawImage`

**Akzeptanzkriterien:**
- RGB-JPEG (1920×1080) korrekt in A4-PDF eingebettet und skaliert auf 400×225 pt
- Graustufenbild: korrekte `/ColorSpace /DeviceGray`
- CMYK-JPEG: `/ColorSpace /DeviceCMYK`
- Mehrere Bilder auf einer Seite: unabhängige XObject-Refs, kein Konflikt

---

### WP-PDF-07: Raster-Bilder (PNG-ähnlich via Raw-Pixel) ⬜

**Ziel:** Rohe Pixel-Daten (RGBA/RGB/Graustufen-Arrays) als eingebettete Bilder
ausgeben — ohne externe Abhängigkeit auf libpng.

**API:**
```lyx
// Raw-Pixel einbetten
var imgId: int64 := PdfAddImageRGB(doc, ptr, width, height)
var imgId: int64 := PdfAddImageGray(doc, ptr, width, height)
var imgId: int64 := PdfAddImageRGBA(doc, ptr, width, height)  // Alpha via SMask

// PNG-Datei direkt einbetten (Chunks parsen, IDAT-Daten extrahieren)
var imgId: int64 := PdfAddImagePng(doc, "bild.png")
```

**Zu implementieren:**
- Raw-RGB → PDF-Stream mit `/FlateDecode` (via WP-PDF-05)
- Alpha-Kanal: separates SMask-XObject (`/Subtype /Image /ColorSpace /DeviceGray`)
- PNG-Parser: Signature prüfen, IHDR/IDAT/IEND-Chunks, Zlib-Inflate der IDAT-Daten,
  PNG-Filter (None, Sub, Up, Average, Paeth) rückgängig machen
- Unterstützte PNG-Typen: Graustufen (1/8 bit), RGB (8 bit), RGBA (8 bit)

**Dateien:**
- `std/pdf/images.lyu`   — Raw-Pixel + PNG-Einbettung (Erweiterung aus WP-PDF-06)
- `std/pdf/compress.lyu` — Inflate wird hier benötigt (Erweiterung aus WP-PDF-05)

**Akzeptanzkriterien:**
- `PdfAddImageRGB` mit synthetischem Farbverlauf sichtbar im PDF
- `PdfAddImageRGBA`: transparente Bereiche korrekt via SMask
- PNG 8-bit RGB: wie JPEG platziert, korrekte Dimensionen
- PNG mit Alpha: transparente Pixel sichtbar wenn über farbigem Hintergrund

---

### WP-PDF-08: Dokumentmetadaten ⬜

**Ziel:** PDF-Metadaten setzen, die von Viewern, Suchmaschinen und
Dokumentenverwaltungssystemen ausgelesen werden.

**API:**
```lyx
PdfSetTitle(doc, "Mein Bericht")
PdfSetAuthor(doc, "Andreas Röne")
PdfSetSubject(doc, "Jahresabschluss 2026")
PdfSetKeywords(doc, "Finanzen, Bericht, 2026")
PdfSetCreator(doc, "Lyx 1.0")
PdfSetProducer(doc, "std/pdf")
PdfSetCreationDate(doc, year, month, day, hour, min, sec)
PdfSetModDate(doc, year, month, day, hour, min, sec)

// PDF/A-Konformitätsstufe (optional, für Archivierung)
PdfSetConformance(doc, PDF_CONFORMANCE_A1B)
```

**Zu implementieren:**
- `/Info`-Dictionary im Trailer: alle Metadaten-Felder als PDF-Strings
- Datums-Format: `D:YYYYMMDDHHmmSS` (z.B. `D:20260520143000`)
- XMP-Metadaten-Stream (optional, für PDF/A): `<xpacket>` XML-Blob als
  `/Metadata`-Stream am Catalog

**Dateien:**
- `std/pdf/meta.lyu`  — Info-Dict, XMP-Blob, Datumsformat
- `std/pdf/builder.lyu` — Trailer-Integration (Update)

**Akzeptanzkriterien:**
- `pdfinfo out.pdf` zeigt Titel, Autor, Erstelldatum korrekt
- `exiftool out.pdf` liest XMP-Metadaten (wenn XMP implementiert)
- Fehlende Felder (`PdfSetAuthor` nicht aufgerufen): Dict-Key wird weggelassen

---

### WP-PDF-09: Annotierungen & Hyperlinks ⬜

**Ziel:** Klickbare Links, URI-Annotierungen und interne Sprungmarken
(Named Destinations) für Inhaltsverzeichnisse und Querverweise.

**API:**
```lyx
// Externer Link (URI)
PdfAddUriLink(doc, page, x, y, w, h, "https://example.com")

// Interner Link (Sprung zu Seite N)
PdfAddPageLink(doc, page, x, y, w, h, targetPage, destX, destY)

// Named Destination (Bookmark-Ziel)
var destId: int64 := PdfAddDestination(doc, page, x, y, "kapitel-1")
PdfAddNamedLink(doc, page, x, y, w, h, "kapitel-1")

// Lesezeichen / Outline (Inhaltsverzeichnis)
var root: int64 := PdfAddOutlineRoot(doc)
var item: int64 := PdfAddOutlineItem(doc, root, "Kapitel 1", page, 0.0, 800.0)
var sub:  int64 := PdfAddOutlineItem(doc, item, "Abschnitt 1.1", page2, 0.0, 700.0)

// Tooltip-Annotierung
PdfAddTooltip(doc, page, x, y, w, h, "Erklärungstext")
```

**Zu implementieren:**
- Annotation-Dict: `/Type /Annot /Subtype /Link /Rect [x1 y1 x2 y2]`
- URI-Action: `/A << /S /URI /URI (https://...) >>`
- GoTo-Action: `/A << /S /GoTo /D [pageRef /XYZ x y 0] >>`
- Named Destinations: `/Dests`-Dictionary im Catalog
- Outline-Baum: `/Outlines`-Dictionary, `/Count`, `/First`, `/Last`, `/Next`, `/Prev`

**Dateien:**
- `std/pdf/annot.lyu` — Annotations, Links, Destinations, Outlines

**Akzeptanzkriterien:**
- URI-Link öffnet Browser beim Klick in Evince/Acrobat
- Interne Seitenreferenz springt korrekt zur Zielseite und -position
- Outline (3 Ebenen tief) erscheint als navigierbares Inhaltsverzeichnis

---

### WP-PDF-10: PDF-Parser (Lesen bestehender PDFs) ⬜

**Ziel:** Bestehende PDF-Dateien einlesen, Objekte und Seiteninhalte
extrahieren — Grundlage für die Bearbeitungs-API in WP-PDF-11.

**Zu implementieren:**
- **Lexer:** Tokens: Integer, Real, Name, String (Literal + Hex), Stream,
  `<<`, `>>`, `[`, `]`, Keyword (obj/endobj/stream/endstream/xref/trailer)
- **XRef-Parser:** klassische XRef-Tabelle (`xref … trailer`) + XRef-Stream (PDF 1.5+)
- **Indirekte Objekte:** `N G obj … endobj` parsen, in Objekt-Tabelle laden
- **Trailer-Dict:** `/Root`, `/Info`, `/Size` auslesen
- **Seiten-Baum traversieren:** alle `/Page`-Objekte in Reihenfolge sammeln
- **Content-Stream dekomprimieren:** FlateDecode (via WP-PDF-05 Inflate)
- **Metadaten lesen:** `PdfReadTitle`, `PdfReadAuthor`, `PdfReadPageCount`

**API:**
```lyx
var doc: int64 := PdfOpen("input.pdf")
if (doc == 0) { /* Fehler */ }

var pages: int64 := PdfPageCount(doc)
var title: pchar := PdfReadTitle(doc)
var w: f64 := PdfReadPageWidth(doc, 0)   // Seite 0
var h: f64 := PdfReadPageHeight(doc, 0)

PdfFree(doc)
```

**Dateien:**
- `std/pdf/parser.lyu` — Lexer, XRef-Parser, Objekt-Lader, Seiten-Traversal

**Akzeptanzkriterien:**
- Beliebiges valides PDF (erzeugt von WP-PDF-03) wird korrekt eingelesen
- `PdfReadPageCount` gibt die korrekte Seitenanzahl zurück
- Komprimierter XRef-Stream (PDF 1.5) und klassische XRef-Tabelle beide unterstützt
- Fehlerhaftes/abgeschnittenes PDF: `PdfOpen` gibt 0 zurück, kein Absturz

---

### WP-PDF-11: PDF-Bearbeitung (Merge, Split, Overlay) ⬜

**Ziel:** Bestehende PDFs zusammenführen, Seiten extrahieren, Inhalt überlagern
und Seiten löschen oder umsortieren.

**API:**
```lyx
// Seiten aus Quell-PDF in Ziel-PDF kopieren
PdfMerge(dst, src, fromPage, toPage)      // fromPage=-1: alle
PdfInsertPage(dst, atIndex, src, srcPage)

// Seiten umsortieren / löschen
PdfMovePage(doc, fromIndex, toIndex)
PdfDeletePage(doc, pageIndex)

// Overlay: Inhalt einer Seite auf eine andere legen
PdfOverlay(dst, dstPage, src, srcPage)

// Wasserzeichen (Text diagonal über alle Seiten)
PdfAddWatermark(doc, "VERTRAULICH", 0.3)  // 0.3 = Transparenz

// Seiten aus PDF extrahieren → neues PDF
var sub: int64 := PdfExtract(src, 0, 4)  // Seiten 0–4
PdfSave(sub, "seiten_0_4.pdf")
PdfFree(sub)
```

**Zu implementieren:**
- Objekt-Import: Objekte aus Quell-Dok in Ziel-Dok kopieren, IDs umnummerieren
- Ressourcen-Merge: Font- und XObject-Dicts zusammenführen (Namenskonflikte auflösen)
- Wasserzeichen: transparenter Content-Stream über bestehenden Seiteninhalt legen
  (`/ExtGState` mit `/ca` für Fill-Alpha)

**Dateien:**
- `std/pdf/editor.lyu` — Merge, Split, Overlay, Watermark

**Akzeptanzkriterien:**
- Merge von 2 PDFs mit je 3 Seiten → 6-Seiten-PDF, alle Inhalte intakt
- `PdfDeletePage` entfernt Seite, verbleibende Seiten durchgehend nummeriert
- Wasserzeichen sichtbar aber halbtransparent auf jeder Seite

---

### WP-PDF-12: TrueType-Font-Einbettung ⬜

**Ziel:** Beliebige TrueType-Fonts (`.ttf`-Dateien) in das PDF einbetten —
inklusive Font-Subsetting (nur verwendete Glyphen), sodass das PDF ohne
installierte Fonts auf jedem Gerät identisch aussieht.

**Hintergrund:** Standard-14-Fonts (WP-PDF-03) sind immer verfügbar, decken
aber kein Unicode-Extended-Subset ab. TrueType-Einbettung ist nötig für
Nicht-Latin-Schriften, Ligaturen und branded Typografie.

**API:**
```lyx
var fontId: int64 := PdfLoadFont(doc, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
var boldId: int64 := PdfLoadFont(doc, "fonts/Inter-Bold.ttf")

PdfSetFontTT(doc, page, fontId, 14.0)
PdfTextAtUTF8(doc, page, 72.0, 720.0, "Привет мир")  // Kyrillisch
PdfTextAtUTF8(doc, page, 72.0, 700.0, "日本語テスト")  // CJK (mit CJK-Font)
```

**Zu implementieren:**
- **TrueType-Parser:**
  - Tabellen-Directory: `cmap`, `glyf`, `loca`, `hmtx`, `name`, `head`, `hhea`, `maxp`, `post`
  - `cmap`-Tabelle (Format 4): Unicode → Glyph-ID-Mapping
  - `glyf`/`loca`: Glyph-Outlines und Offsets
  - `hmtx`: horizontale Metrik (Breite je Glyph)
- **Subsetting:** nur verwendete Glyph-IDs ins Subset-Font kopieren
- **PDF-Einbettung:**
  - `/Type /Font /Subtype /TrueType` (Latin-Subset)
  - `/Type /Font /Subtype /Type0` + CIDFont (für Unicode/CJK)
  - `/ToUnicode`-CMap für Text-Selektion und Copy/Paste im Viewer
  - `/FontDescriptor` mit `/FontFile2` (eingebetteter Font-Stream)

**Dateien:**
- `std/pdf/fonts.lyu` — TrueType-Parser, Subsetter, CIDFont-Dict (Erweiterung)

**Akzeptanzkriterien:**
- Cyrillischer Text mit DejaVuSans-TTF korrekt dargestellt
- Font-Subset deutlich kleiner als Original-TTF (nur verwendete Glyphen)
- Text im Viewer selektierbar und kopierbar (dank `/ToUnicode`)
- PDF mit eingebettetem Font öffnet korrekt auf System ohne den Font installiert

---

## Meilensteine

| Meilenstein | WPs | Ergebnis |
|-------------|-----|----------|
| M1: Minimales PDF | PDF-01, PDF-02 | Leeres Dokument mit Seiten, valide Struktur |
| M2: Text & Grafik | PDF-03, PDF-04 | Text, Linien, Formen, Farben |
| M3: Kompakte PDFs | PDF-05 | FlateDecode-Komprimierung aktiv |
| M4: Bilder | PDF-06, PDF-07 | JPEG + PNG/Raw-Pixel einbetten |
| M5: Reichhaltige Dokumente | PDF-08, PDF-09 | Metadaten, Links, Lesezeichen |
| M6: PDF-Bearbeitung | PDF-10, PDF-11 | Lesen, Merge, Split, Watermark |
| M7: Volle Typografie | PDF-12 | TrueType-Einbettung, Unicode |

---

## API-Übersicht (vollständig)

### Dokument
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfNew` | `() → int64` | Neues leeres Dokument |
| `PdfOpen` | `(path: pchar) → int64` | PDF-Datei einlesen |
| `PdfSave` | `(doc, path: pchar) → int64` | Datei schreiben (0=OK) |
| `PdfFree` | `(doc)` | Dokument freigeben |
| `PdfSetCompression` | `(doc, level: int64)` | 0=aus, 1–9 |
| `PdfSetConformance` | `(doc, mode: int64)` | PDF/A-Modus |

### Seiten
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfAddPage` | `(doc, w, h: f64) → int64` | Seite hinzufügen |
| `PdfPageCount` | `(doc) → int64` | Anzahl Seiten |
| `PdfSetLandscape` | `(doc, page)` | Querformat |
| `PdfDeletePage` | `(doc, idx: int64)` | Seite entfernen |
| `PdfMovePage` | `(doc, from, to: int64)` | Seite verschieben |

### Text
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfSetFont` | `(doc, page, fontId, size: f64)` | Standard-14-Font |
| `PdfSetFontTT` | `(doc, page, fontId, size: f64)` | TrueType-Font |
| `PdfLoadFont` | `(doc, path: pchar) → int64` | TTF laden |
| `PdfTextAt` | `(doc, page, x, y: f64, text: pchar)` | Text platzieren |
| `PdfTextAtUTF8` | `(doc, page, x, y: f64, text: pchar)` | UTF-8-Text |
| `PdfTextWidth` | `(doc, fontId, size: f64, text: pchar) → f64` | Textbreite |
| `PdfTextBlock` | `(doc, page, x, y, w: f64, text: pchar)` | Automatischer Zeilenumbruch |
| `PdfSetTextColor` | `(doc, page, r, g, b: f64)` | Textfarbe |

### Grafik
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfSetStrokeColor` | `(doc, page, r, g, b: f64)` | Konturfarbe |
| `PdfSetFillColor` | `(doc, page, r, g, b: f64)` | Füllfarbe |
| `PdfSetLineWidth` | `(doc, page, w: f64)` | Linienstärke |
| `PdfMoveTo` | `(doc, page, x, y: f64)` | Pfad-Start |
| `PdfLineTo` | `(doc, page, x, y: f64)` | Linie |
| `PdfCurveTo` | `(doc, page, x1, y1, x2, y2, x3, y3: f64)` | Bézier |
| `PdfRect` | `(doc, page, x, y, w, h: f64)` | Rechteck |
| `PdfCircle` | `(doc, page, cx, cy, r: f64)` | Kreis |
| `PdfStroke` | `(doc, page)` | Kontur zeichnen |
| `PdfFill` | `(doc, page)` | Füllen |
| `PdfFillStroke` | `(doc, page)` | Füllen + Kontur |
| `PdfSaveState` | `(doc, page)` | Grafikzustand sichern |
| `PdfRestoreState` | `(doc, page)` | Grafikzustand wiederherstellen |
| `PdfTranslate` | `(doc, page, tx, ty: f64)` | Verschiebung |
| `PdfScale` | `(doc, page, sx, sy: f64)` | Skalierung |
| `PdfRotate` | `(doc, page, angle: f64)` | Rotation in Grad |

### Bilder
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfAddImageJpeg` | `(doc, path: pchar) → int64` | JPEG-Datei |
| `PdfAddImagePng` | `(doc, path: pchar) → int64` | PNG-Datei |
| `PdfAddImageRGB` | `(doc, ptr, w, h: int64) → int64` | Raw-RGB-Puffer |
| `PdfAddImageRGBA` | `(doc, ptr, w, h: int64) → int64` | Raw-RGBA (mit Alpha) |
| `PdfDrawImage` | `(doc, page, imgId, x, y, w, h: f64)` | Bild platzieren |
| `PdfDrawImageFit` | `(doc, page, imgId, x, y, mw, mh: f64)` | Proportional |

### Metadaten & Links
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfSetTitle` | `(doc, title: pchar)` | Dokumenttitel |
| `PdfSetAuthor` | `(doc, author: pchar)` | Autor |
| `PdfAddUriLink` | `(doc, page, x, y, w, h: f64, uri: pchar)` | Externer Link |
| `PdfAddPageLink` | `(doc, page, x, y, w, h: f64, target, tx, ty)` | Interner Link |
| `PdfAddOutlineRoot` | `(doc) → int64` | Lesezeichen-Wurzel |
| `PdfAddOutlineItem` | `(doc, parent, label: pchar, page, x, y) → int64` | Lesezeichen |

### Bearbeitung
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `PdfMerge` | `(dst, src, from, to: int64)` | Seiten kopieren |
| `PdfExtract` | `(src, from, to: int64) → int64` | Teilkopie |
| `PdfOverlay` | `(dst, dstPage, src, srcPage: int64)` | Inhalte überlagern |
| `PdfAddWatermark` | `(doc, text: pchar, alpha: f64)` | Wasserzeichen |

---

## Offene Fragen / Entscheidungen

| # | Frage | Optionen | Empfehlung |
|---|-------|----------|------------|
| 1 | Deflate-Implementierung | FFI auf libz / natives Lyx | FFI libz für V1 (bewährt, schnell), natives Lyx in WP-PDF-12+ |
| 2 | Interne Objekt-Speicherung | Heap-Linked-List / festes Array | Festes Array mit vorab allokiertem Pool (schnellere Serialisierung) |
| 3 | Content-Stream-Aufbau | Sofort schreiben / Builder puffern | Builder-Puffer — ermöglicht nachträgliche Ressourcen-Registrierung |
| 4 | TrueType-CJK | Vollständige CIDFont-Unterstützung / Latin only | Latin-only für V1, CJK als optionale Erweiterung |
| 5 | PDF-Version | 1.4 / 1.7 | PDF 1.4 (maximale Kompatibilität; XRef-Streams optional via Flag) |
| 6 | Fehler-Rückgabe | Return-Code (int64) / Panic | Return-Code; `PdfGetError(doc) → pchar` für Details |
| 7 | PNG-Dekodierung | Eigener Parser / FFI libpng | Eigener Parser (vermeidet Abhängigkeit; PNG-Subset reicht) |
