# Lyx SVG-Bibliothek (`std/svg`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für `std/svg`, die
offizielle SVG-Standardbibliothek von Lyx. Ziel ist eine vollständige, portable
Bibliothek zum **Erstellen, Manipulieren und Lesen** von SVG-Dateien — ohne
externe Abhängigkeiten wie libsvg oder Cairo.

**Konvention:** WP-SVG-NN (SVG Library, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.svg;

pub fn main(): int64 {
  var doc: int64 := SvgNew(800.0, 600.0);
  SvgSetViewBox(doc, 0.0, 0.0, 800.0, 600.0);

  // Hintergrund
  SvgRect(doc, 0.0, 0.0, 800.0, 600.0);
  SvgSetFill(doc, 0.94, 0.96, 0.97);
  SvgApply(doc);

  // Farbverlauf definieren
  var grad: int64 := SvgLinearGradient(doc, "grad1", 0.0, 0.0, 1.0, 0.0);
  SvgGradientStop(doc, grad, 0.0, 0.29, 0.56, 0.89, 1.0);
  SvgGradientStop(doc, grad, 1.0, 0.48, 0.19, 0.97, 1.0);

  // Kreis mit Verlauf und Schatten
  SvgFilter(doc, SvgDropShadow(doc, 4.0, 4.0, 6.0, 0.0, 0.0, 0.0, 0.4));
  SvgCircle(doc, 400.0, 300.0, 150.0);
  SvgSetFillGradient(doc, grad);
  SvgApply(doc);

  // Text zentriert
  SvgSetFont(doc, "Arial", 36.0);
  SvgSetTextAnchor(doc, SVG_ANCHOR_MIDDLE);
  SvgTextAt(doc, 400.0, 310.0, "Hallo SVG!");
  SvgSetFill(doc, 1.0, 1.0, 1.0);
  SvgApply(doc);

  SvgSave(doc, "output.svg");
  SvgFree(doc);
  return 0;
}
```

`std/svg` soll sich so selbstverständlich anfühlen wie `std/io` — minimale API,
kein manuelles XML-Escaping, deterministischer und valider Output.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│                      std/svg (public API)                    │
│  SvgNew / SvgRect / SvgCircle / SvgTextAt / SvgSave ...     │
└────────────────────────────┬─────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────┐
│                       svg/builder.lyu                        │
│  Element-Stack · Attribut-Builder · XML-Writer               │
└──────┬──────────────────────┬──────────────────────┬─────────┘
       │                      │                      │
┌──────▼──────┐   ┌───────────▼────────┐   ┌────────▼──────────┐
│ svg/         │   │ svg/               │   │ svg/              │
│ elements.lyu │   │ style.lyu          │   │ defs.lyu          │
│ (Primitive:  │   │ (Fill, Stroke,     │   │ (Gradienten,      │
│  Rect/Circle │   │  Opacity, CSS,     │   │  Muster, Symbole, │
│  Path/Text)  │   │  Transform)        │   │  Marker, Filter)  │
└─────────────┘   └────────────────────┘   └───────────────────┘
```

### Datei-Überblick

```
std/
  svg.lyu                  ← öffentliche API (SvgNew, SvgRect, SvgSave, …)
  svg/
    builder.lyu            ← Dokument-Builder: Element-Stack, XML-Serialisierung
    elements.lyu           ← Primitive: rect, circle, ellipse, line, polyline, polygon
    path.lyu               ← <path d="…">: M L H V C Q A Z Befehle
    style.lyu              ← fill, stroke, opacity, transform, CSS-Klassen
    text.lyu               ← <text>, <tspan>, <textPath>, Fontmetriken
    defs.lyu               ← <defs>: Gradienten, Muster, Symbole, Marker
    filter.lyu             ← <filter>: blur, shadow, feComposite, feColorMatrix
    image.lyu              ← <image>: Base64-JPEG/PNG-Einbettung, data-URIs
    anim.lyu               ← <animate>, <animateTransform>, <animateMotion> (SMIL)
    parser.lyu             ← XML-Lexer + SVG-Element-Parser (Lesen)
    xml.lyu                ← generischer XML-Writer (Escaping, Indentierung)
```

---

## SVG-Grundkonzepte

### Dokumentstruktur

```xml
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     width="800" height="600"
     viewBox="0 0 800 600">
  <defs>
    <!-- Gradienten, Symbole, Filter, Muster -->
  </defs>
  <!-- Grafik-Elemente -->
</svg>
```

### Koordinatensystem

SVG verwendet ein kartesisches System mit Y-Achse nach **unten** (Ursprung
oben links). Einheiten sind standardmäßig Pixel (px), aber `viewBox` ermöglicht
beliebige Koordinatenräume.

### Pfad-Befehle (Auswahl)

| Befehl | Bedeutung |
|--------|-----------|
| `M x y` | Move to (absolut) |
| `m dx dy` | Move to (relativ) |
| `L x y` | Line to (absolut) |
| `H x` | Horizontale Linie |
| `V y` | Vertikale Linie |
| `C x1 y1 x2 y2 x y` | Kubische Bézier |
| `Q x1 y1 x y` | Quadratische Bézier |
| `A rx ry rot laf sf x y` | Elliptischer Bogen |
| `Z` | Pfad schließen |

### Styling-Modell

SVG-Elemente können per **Inline-Attributen** (`fill="red"`), **Inline-Style**
(`style="fill:red"`) oder **CSS-Klassen** gestylt werden. `std/svg` erzeugt
primär Inline-Attribute für maximale Kompatibilität, mit optionalem CSS-Modus.

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | Fundament: XML-Writer, Dokument, Primitive | SVG-01 – SVG-02 |
| 2 | Pfade und Styling | SVG-03 – SVG-04 |
| 3 | Gruppen, Transformationen, Text | SVG-05 – SVG-06 |
| 4 | Gradienten, Muster, Symbole | SVG-07 – SVG-08 |
| 5 | Bildeinbettung und Filter | SVG-09 – SVG-10 |
| 6 | Animation (SMIL) | SVG-11 |
| 7 | SVG-Parser (Lesen) | SVG-12 |

---

## Work Packages

---

### WP-SVG-01: XML-Writer & Dokumentgerüst ⬜

**Ziel:** Einen robusten XML-Writer implementieren und damit ein minimales,
valides SVG-Dokument erzeugen können — inklusive korrektem Namespace, Encoding
und optionaler Pretty-Print-Formatierung.

**Zu implementieren:**

- XML-Writer (`svg/xml.lyu`):
  - Element öffnen/schließen: `<tag>`, `</tag>`, `<tag />`
  - Attribut schreiben: Wert-Escaping (`"` → `&quot;`, `<` → `&lt;`, `&` → `&amp;`)
  - Text-Inhalt schreiben: XML-Character-Escaping
  - Indentierung (Pretty-Print, optional abschaltbar für kompakte Ausgabe)
  - Puffer-basiert: gesamtes Dokument im Speicher, dann einmalig `SvgSave()` schreiben
- Dokument-Builder (`svg/builder.lyu`):
  - `SvgNew(width, height: f64) → int64` — Dokument anlegen
  - SVG-Root-Element: `xmlns`, `width`, `height`, `viewBox`
  - `<defs>`-Block automatisch als erster Abschnitt
  - Element-Stack: öffnen/schließen von `<g>`, `<defs>` etc. gepusht/gepoppt
  - `SvgSave(doc, path: pchar) → int64` — in Datei schreiben
  - `SvgToString(doc) → pchar` — als nullterminierter String
  - `SvgFree(doc)` — alle Ressourcen freigeben

**Dateien:**
- `std/svg/xml.lyu`     — XML-Writer, Escaping, Puffer-Verwaltung
- `std/svg/builder.lyu` — Dokument-Lebenszyklus, Element-Stack, Serialisierung
- `std/svg.lyu`         — `SvgNew`, `SvgSave`, `SvgFree`, `SvgToString` (public API)

**Akzeptanzkriterien:**
- `SvgNew(100.0, 100.0)` + `SvgSave("out.svg")` erzeugt valides SVG
- XML-Validator (`xmllint --noout out.svg`) meldet keine Fehler
- Sonderzeichen `< > & " '` in Attributwerten korrekt escaped
- Pretty-Print: jedes Element eingerückt, `SvgSetPrettyPrint(doc, 0)` deaktiviert es

---

### WP-SVG-02: Geometrische Primitive ⬜

**Ziel:** Die fünf Grundformen von SVG als API zur Verfügung stellen:
Rechteck, Kreis, Ellipse, Linie, Polyline und Polygon.

**API:**
```lyx
// Rechteck (x, y, Breite, Höhe)
SvgRect(doc, x, y, w, h: f64)
SvgRoundRect(doc, x, y, w, h, rx, ry: f64)  // abgerundete Ecken

// Kreis
SvgCircle(doc, cx, cy, r: f64)

// Ellipse
SvgEllipse(doc, cx, cy, rx, ry: f64)

// Linie
SvgLine(doc, x1, y1, x2, y2: f64)

// Polyline (offene Kurve aus Punkten)
SvgPolyline(doc, points: pchar)   // "x1,y1 x2,y2 x3,y3"
SvgPolylineN(doc, xs, ys: pf64, n: int64)  // aus zwei f64-Arrays

// Polygon (geschlossene Kurve aus Punkten)
SvgPolygon(doc, points: pchar)
SvgPolygonN(doc, xs, ys: pf64, n: int64)

// Styling nach Primitive-Erstellung setzen (Builder-Pattern):
SvgSetFill(doc, r, g, b: f64)
SvgSetFillNone(doc)
SvgSetFillAlpha(doc, r, g, b, a: f64)
SvgSetFillHex(doc, hex: pchar)        // "#rrggbb" oder "#rrggbbaa"
SvgSetStroke(doc, r, g, b: f64)
SvgSetStrokeWidth(doc, w: f64)
SvgSetStrokeNone(doc)
SvgSetOpacity(doc, a: f64)            // 0.0–1.0

// Element mit aktuellen Styles schreiben:
SvgApply(doc)
```

**Styling-Modell:** Jede Primitive-Funktion öffnet einen internen Builder.
`SvgApply()` schließt das Element und schreibt alle gesetzten Attribute.
Nicht gesetzte Attribute werden weggelassen (SVG-Default gilt).

**Zu implementieren:**
- Jede Primitive als eigene Funktion in `svg/elements.lyu`
- Interner Style-Zustand im Builder: `fill`, `stroke`, `stroke-width`, `opacity`
- Farbkonvertierung f64 (0.0–1.0) → Hex-String `#rrggbb`
- Hex-Parser für `SvgSetFillHex` / `SvgSetStrokeHex`
- `SvgPolylineN` / `SvgPolygonN`: Punkte-Array → `points`-Attribut-String serialisieren

**Dateien:**
- `std/svg/elements.lyu` — alle Primitive-Funktionen
- `std/svg/style.lyu`    — Style-Zustand, Farb-Konvertierung
- `std/svg.lyu`          — öffentliche API (Re-Exports)

**Akzeptanzkriterien:**
- Rotes Rechteck (10, 10, 200, 100): `<rect x="10" y="10" width="200" height="100" fill="#ff0000"/>`
- Kreis ohne Füllung, mit Kontur: `<circle fill="none" stroke="#000000" stroke-width="2"/>`
- Polyline aus 5 Punkten: korrekte `points`-Formatierung
- Alpha < 1.0: `fill-opacity` Attribut korrekt gesetzt (oder `fill="rgba(...)"` als Alternative)

---

### WP-SVG-03: Pfad-API (`<path>`) ⬜

**Ziel:** Das mächtigste SVG-Element — `<path>` — mit einer komfortablen
Lyx-API für alle Pfad-Befehle zugänglich machen.

**API:**
```lyx
// Pfad beginnen
SvgPathBegin(doc)

// Absolute Befehle
SvgMoveTo(doc, x, y: f64)
SvgLineTo(doc, x, y: f64)
SvgHLineTo(doc, x: f64)
SvgVLineTo(doc, y: f64)
SvgCurveTo(doc, x1, y1, x2, y2, x, y: f64)    // kubische Bézier
SvgSmoothCurveTo(doc, x2, y2, x, y: f64)        // S-Befehl
SvgQuadTo(doc, x1, y1, x, y: f64)               // quadratische Bézier
SvgSmoothQuadTo(doc, x, y: f64)                 // T-Befehl
SvgArcTo(doc, rx, ry, rot: f64, laf, sf: int64, x, y: f64)
SvgClosePath(doc)

// Relative Varianten (gleiche Signaturen, Kleinbuchstaben intern)
SvgMoveToRel(doc, dx, dy: f64)
SvgLineToRel(doc, dx, dy: f64)
SvgCurveToRel(doc, dx1, dy1, dx2, dy2, dx, dy: f64)
// … analog für alle Befehle

// Pfad abschließen + Styling
SvgSetFill(doc, r, g, b: f64)
SvgSetStroke(doc, r, g, b: f64)
SvgSetStrokeWidth(doc, w: f64)
SvgSetFillRule(doc, SVG_FILL_NONZERO)   // oder SVG_FILL_EVENODD
SvgApply(doc)

// Hilfsfunktionen
SvgPathArc(doc, cx, cy, r, startDeg, endDeg: f64)       // Kreisbogen
SvgPathPieSlice(doc, cx, cy, r, startDeg, endDeg: f64)  // gefüllter Sektor
SvgPathStar(doc, cx, cy, r1, r2: f64, n: int64)         // Stern mit n Zacken
SvgPathArrow(doc, x1, y1, x2, y2, headLen, headAngle: f64) // Pfeil
```

**Zu implementieren:**
- Pfad-Puffer: String-Builder der `d`-Attribut-Wert aufbaut (Befehl für Befehl)
- Alle SVG-Pfad-Befehle: M m L l H h V v C c S s Q q T t A a Z
- Zahlenformatierung: f64 → kurze Dezimaldarstellung (max 4 Nachkommastellen,
  keine trailing zeros: `10.5` statt `10.5000`)
- Hilfsfunktionen: Bogen via A-Befehl, Kreissektor via M + A + L + Z,
  Stern via alternierende Innen-/Außenpunkte, Pfeil via L + Winkelberechnung

**Dateien:**
- `std/svg/path.lyu`  — Pfad-Builder, alle Befehle, Hilfsfunktionen

**Akzeptanzkriterien:**
- Offener Pfad (M L L): korrekte `d`-String, SVG valide
- Kreis-Annäherung via 4× kubische Bézier: visuell identisch mit `<circle>`
- `SvgPathArc(doc, 200, 200, 100, 0, 270)`: 270°-Bogen korrekt mit A-Befehl
- `SvgPathStar(doc, 200, 200, 80, 40, 5)`: 5-zackiger Stern korrekt geschlossen
- Zahlenformatierung: `1.5` statt `1.50000`, `100` statt `100.0`

---

### WP-SVG-04: Linienstil, Dash-Pattern & Transformationen ⬜

**Ziel:** Erweiterte Stileigenschaften für Linien und Konturen, sowie
Element-lokale Transformationen.

**API:**
```lyx
// Linienstil
SvgSetLineCap(doc, SVG_CAP_BUTT)    // SVG_CAP_ROUND, SVG_CAP_SQUARE
SvgSetLineJoin(doc, SVG_JOIN_MITER) // SVG_JOIN_ROUND, SVG_JOIN_BEVEL
SvgSetMiterLimit(doc, limit: f64)
SvgSetDashArray(doc, pattern: pchar)    // "5 3" = 5px an, 3px aus
SvgSetDashArrayN(doc, dashes: pf64, n: int64)
SvgSetDashOffset(doc, offset: f64)

// Element-Transformation (angehängt vor SvgApply)
SvgTranslate(doc, tx, ty: f64)
SvgScale(doc, sx, sy: f64)
SvgRotate(doc, angle: f64)              // Rotation um Ursprung
SvgRotateAround(doc, angle, cx, cy: f64) // Rotation um Punkt
SvgSkewX(doc, angle: f64)
SvgSkewY(doc, angle: f64)
SvgMatrix(doc, a, b, c, d, e, f: f64)  // vollständige Matrix

// Mehrere Transformationen kombinieren (werden zu einem transform-Attribut)
SvgTranslate(doc, 100.0, 50.0)
SvgRotate(doc, 45.0)
SvgApply(doc)  // → transform="translate(100 50) rotate(45)"
```

**Zu implementieren:**
- Dash-Array: f64-Array → `stroke-dasharray`-String (`"5 3 2 3"`)
- Transformations-Stack im Builder: jede Transformation hängt sich an, beim
  `SvgApply()` werden alle zum `transform`-Attribut zusammengesetzt
- Winkel: Grad (Lyx-API) → intern direkt als Grad (SVG nutzt Grad)
- `SvgRotateAround` → `rotate(angle cx cy)` in SVG-Syntax

**Dateien:**
- `std/svg/style.lyu` — Linienstil, Dash, Transformations-Stack (Erweiterung)

**Akzeptanzkriterien:**
- Gestrichelte Linie `"10 5"`: korrekte `stroke-dasharray="10 5"` im Output
- `SvgRotateAround(doc, 45.0, 200.0, 300.0)`: `transform="rotate(45 200 300)"`
- Kombination Translate + Scale: `transform="translate(50 20) scale(2 1)"`
- SVG mit allen Stilen valide laut `xmllint`

---

### WP-SVG-05: Gruppen & Ebenen (`<g>`) ⬜

**Ziel:** Elemente in Gruppen zusammenfassen, gemeinsame Styles und
Transformationen auf ganze Gruppen anwenden, Ebenen-basiertes Zeichnen ermöglichen.

**API:**
```lyx
// Gruppe öffnen / schließen
var g: int64 := SvgGroupBegin(doc)
SvgSetFill(doc, 0.2, 0.6, 0.9)    // gilt für alle Kinder
SvgSetOpacity(doc, 0.8)
SvgTranslate(doc, 100.0, 50.0)
// ... Primitive hinzufügen ...
SvgGroupEnd(doc)

// Benannte Gruppe (id-Attribut) für spätere Referenzierung
var g: int64 := SvgGroupBeginId(doc, "layer-background")

// Verschachtelte Gruppen
var outer: int64 := SvgGroupBegin(doc)
  var inner: int64 := SvgGroupBegin(doc)
  SvgCircle(doc, 100.0, 100.0, 50.0)
  SvgApply(doc)
  SvgGroupEnd(doc)
SvgGroupEnd(doc)

// Sichtbarkeit
SvgSetVisible(doc, g, 0)    // display:none
SvgSetVisible(doc, g, 1)

// id und class-Attribut für CSS
SvgSetId(doc, g, "main-chart")
SvgSetClass(doc, g, "highlight")
```

**Zu implementieren:**
- Element-Stack im Builder: `SvgGroupBegin` pusht einen neuen Kontext,
  `SvgGroupEnd` poppt ihn und schreibt `</g>`
- Style-Vererbung: Attribute auf dem `<g>`-Element (nicht auf jedem Kind)
  — Builder merkt sich, welche Styles auf Gruppen-Ebene gesetzt wurden
- Rekursive Verschachtelung bis mindestens 32 Ebenen tief
- `id`- und `class`-Attribut: immer HTML-safe (kein Escaping nötig für typische IDs)

**Dateien:**
- `std/svg/builder.lyu` — Element-Stack-Erweiterung für Gruppen (Update)
- `std/svg.lyu`         — `SvgGroupBegin`, `SvgGroupEnd`, `SvgSetId`, `SvgSetClass`

**Akzeptanzkriterien:**
- Verschachtelte `<g>`-Elemente korrekt geöffnet und geschlossen
- Gruppe mit `opacity="0.5"` und `transform="translate(100 0)"`: alle Kinder
  ohne eigene opacity/transform übernehmen die Gruppe
- `SvgGroupEnd` ohne vorangehendes `SvgGroupBegin`: kein Absturz, Fehlercode
- Maximale Verschachtelungstiefe 32: kein Stack-Overflow

---

### WP-SVG-06: Text & Typografie ⬜

**Ziel:** Text auf SVG-Zeichenflächen platzieren, Schriftarten, Ausrichtung,
Zeilenabstand und Dekorationen steuern; Text entlang eines Pfades führen.

**API:**
```lyx
// Einfacher Text
SvgTextAt(doc, x, y: f64, text: pchar)
SvgSetFont(doc, family: pchar, size: f64)
SvgSetFontWeight(doc, SVG_WEIGHT_BOLD)    // SVG_WEIGHT_NORMAL, SVG_WEIGHT_BOLD, int64
SvgSetFontStyle(doc, SVG_STYLE_ITALIC)    // SVG_STYLE_NORMAL, SVG_STYLE_ITALIC
SvgSetTextAnchor(doc, SVG_ANCHOR_START)   // SVG_ANCHOR_MIDDLE, SVG_ANCHOR_END
SvgSetDominantBaseline(doc, SVG_BASELINE_AUTO)  // SVG_BASELINE_MIDDLE, _HANGING
SvgSetLetterSpacing(doc, spacing: f64)
SvgSetWordSpacing(doc, spacing: f64)
SvgSetTextDecoration(doc, SVG_DECO_UNDERLINE)  // SVG_DECO_STRIKETHROUGH, _OVERLINE
SvgApply(doc)

// Mehrzeiliger Text via <tspan>
var txt: int64 := SvgTextBegin(doc, x, y: f64)
SvgTspan(doc, "Erste Zeile", 0.0, 0.0)      // dx=0, dy=0
SvgTspan(doc, "Zweite Zeile", 0.0, 20.0)    // dy=20 → neue Zeile
SvgTspanStyle(doc, "Fett", SVG_WEIGHT_BOLD, 0.0, 0.0)
SvgTextEnd(doc)

// Text entlang Pfad
var pathId: pchar := "textcurve";
SvgPathBeginId(doc, pathId)
SvgMoveTo(doc, 50.0, 300.0)
SvgCurveTo(doc, 150.0, 100.0, 350.0, 500.0, 500.0, 300.0)
SvgApplyHidden(doc)  // Pfad sichtbar=nein, aber referenzierbar

SvgTextOnPath(doc, pathId, "Text folgt dem Pfad!", 0.0)
SvgSetFont(doc, "Georgia", 18.0)
SvgApply(doc)

// Konstanten
SVG_ANCHOR_START   = 0
SVG_ANCHOR_MIDDLE  = 1
SVG_ANCHOR_END     = 2
SVG_WEIGHT_NORMAL  = 0
SVG_WEIGHT_BOLD    = 1
SVG_STYLE_NORMAL   = 0
SVG_STYLE_ITALIC   = 1
SVG_DECO_NONE      = 0
SVG_DECO_UNDERLINE = 1
```

**Zu implementieren:**
- `<text>`-Element mit `x`, `y`, `font-family`, `font-size`, `font-weight`,
  `font-style`, `text-anchor`, `dominant-baseline`, `letter-spacing`,
  `word-spacing`, `text-decoration`
- `<tspan>` innerhalb `<text>`: `dx`, `dy`, eigene Styles überschreiben
- `<textPath>`: `<text><textPath href="#id" startOffset="0%">…</textPath></text>`
- XML-Character-Escaping für Textinhalt: `<` `>` `&` `"` korrekt maskiert
- UTF-8-Durchleitung: Lyx-pchar (UTF-8) direkt in XML — SVG ist UTF-8-nativ

**Dateien:**
- `std/svg/text.lyu` — `<text>`, `<tspan>`, `<textPath>`, Konstanten

**Akzeptanzkriterien:**
- `SvgTextAt` zentriert (`SVG_ANCHOR_MIDDLE`): `text-anchor="middle"` im Attribut
- `SvgTspan` mit `dy=20`: zweite Zeile 20px tiefer als erste
- Text mit Sonderzeichen `< & >`: korrekt escaped, SVG valide
- `SvgTextOnPath`: Text folgt visuell dem Pfad im Browser

---

### WP-SVG-07: Gradienten & Muster ⬜

**Ziel:** Lineare und radiale Farbverläufe sowie Kachelmuster als
wiederverwendbare Definitionen in `<defs>` anlegen und Elementen zuweisen.

**API:**
```lyx
// Linearer Gradient (Koordinaten: 0.0–1.0 = Prozent, userSpaceOnUse optional)
var g: int64 := SvgLinearGradient(doc, "id", x1, y1, x2, y2: f64)
SvgGradientStop(doc, g, offset, r, g2, b, a: f64)  // offset: 0.0–1.0
SvgGradientSpread(doc, g, SVG_SPREAD_PAD)   // SVG_SPREAD_REFLECT, _REPEAT
SvgGradientUserSpace(doc, g)   // gradientUnits="userSpaceOnUse"

// Radialer Gradient
var rg: int64 := SvgRadialGradient(doc, "id", cx, cy, r, fx, fy: f64)
SvgGradientStop(doc, rg, 0.0, 1.0, 0.8, 0.0, 1.0)
SvgGradientStop(doc, rg, 1.0, 0.8, 0.0, 0.0, 0.0)

// Gradient auf Element anwenden
SvgSetFillGradient(doc, g)
SvgSetStrokeGradient(doc, g)

// Muster (wiederkachelndes Bild)
var pat: int64 := SvgPatternBegin(doc, "id", x, y, w, h: f64)
SvgRect(doc, 0.0, 0.0, w, h)
SvgSetFillHex(doc, "#ddeeff")
SvgApply(doc)
SvgLine(doc, 0.0, 0.0, w, h)
SvgSetStroke(doc, 0.5, 0.5, 0.5)
SvgApply(doc)
SvgPatternEnd(doc)

SvgSetFillPattern(doc, pat)

// Gradient-Transformation (z.B. Rotation)
SvgGradientRotate(doc, g, 45.0)
```

**Zu implementieren:**
- `<linearGradient>` in `<defs>`: `id`, `x1`, `y1`, `x2`, `y2`,
  `gradientUnits`, `spreadMethod`, `gradientTransform`
- `<radialGradient>` in `<defs>`: `id`, `cx`, `cy`, `r`, `fx`, `fy`
- `<stop>`: `offset`, `stop-color` (als `#rrggbb`), `stop-opacity`
- ID-Vergabe: automatisch eindeutige IDs wenn nicht angegeben (`grad0`, `grad1`, …)
- `<pattern>` in `<defs>`: `id`, `x`, `y`, `width`, `height`, `patternUnits`
- `fill="url(#id)"` wenn Gradient/Muster als Füllung zugewiesen

**Dateien:**
- `std/svg/defs.lyu` — Gradienten, Muster (erster Teil dieser Datei)

**Akzeptanzkriterien:**
- Linearer Blau-Lila-Gradient auf Rechteck: korrekte `<linearGradient>` in `<defs>`,
  `fill="url(#id)"` auf `<rect>`
- Radialer Gradient: Mittelpunkt und Fokuspunkt unabhängig einstellbar
- Gradient mit 3 Stops: alle drei `<stop>`-Elemente im Output
- Muster aus Kreis + Linie: `<pattern>` mit 2 Kind-Elementen, korrekt gekachelt

---

### WP-SVG-08: Symbole, Marker & Wiederverwendung ⬜

**Ziel:** Wiederverwendbare Symbole und Pfeilspitzen/Marker definieren, die
an mehreren Stellen referenziert werden können.

**API:**
```lyx
// Symbol definieren (wie <g>, aber unsichtbar bis <use>)
var sym: int64 := SvgSymbolBegin(doc, "id", viewBoxW, viewBoxH: f64)
SvgCircle(doc, 50.0, 50.0, 40.0)
SvgSetFill(doc, 1.0, 0.8, 0.0)
SvgApply(doc)
SvgSymbolEnd(doc)

// Symbol verwenden
SvgUse(doc, "id", x, y, w, h: f64)

// Marker (für Pfeilspitzen an Linien/Pfaden)
var arrowEnd: int64 := SvgMarkerBegin(doc, "arrow-end", 10.0, 10.0, 0.0, 5.0, 10.0)
// markerWidth, markerHeight, refX, refY, viewBox implizit
SvgPathBegin(doc)
SvgMoveTo(doc, 0.0, 0.0)
SvgLineTo(doc, 10.0, 5.0)
SvgLineTo(doc, 0.0, 10.0)
SvgSetFill(doc, 0.0, 0.0, 0.0)
SvgApply(doc)
SvgMarkerEnd(doc)

// Marker an Linie oder Pfad anhängen
SvgLine(doc, 50.0, 300.0, 400.0, 300.0)
SvgSetStroke(doc, 0.0, 0.0, 0.0)
SvgSetStrokeWidth(doc, 2.0)
SvgSetMarkerEnd(doc, arrowEnd)
SvgSetMarkerStart(doc, arrowEnd)  // optional: Anfangspfeil
SvgApply(doc)

// Clipping-Pfad
var clip: int64 := SvgClipPathBegin(doc, "clip1")
SvgCircle(doc, 200.0, 200.0, 150.0)
SvgApply(doc)
SvgClipPathEnd(doc)

SvgGroupBegin(doc)
SvgSetClipPath(doc, clip)
// alles innerhalb der Gruppe wird auf den Kreis geclipt
SvgRect(doc, 50.0, 50.0, 300.0, 300.0)
SvgSetFillHex(doc, "#ff6600")
SvgApply(doc)
SvgGroupEnd(doc)
```

**Zu implementieren:**
- `<symbol>` in `<defs>`: `id`, `viewBox` (`"0 0 w h"`), `overflow="hidden"`
- `<use>`: `href="#id"`, `x`, `y`, `width`, `height`
- `<marker>` in `<defs>`: `id`, `markerWidth`, `markerHeight`, `refX`, `refY`,
  `orient="auto"` (folgt der Pfadrichtung)
- `marker-start`, `marker-mid`, `marker-end` Attribute auf Elementen
- `<clipPath>` in `<defs>`: `id` + Kind-Elemente definieren die Clip-Region
- `clip-path="url(#id)"` auf Gruppen/Elementen

**Dateien:**
- `std/svg/defs.lyu` — Symbole, Marker, ClipPath (Erweiterung aus WP-SVG-07)

**Akzeptanzkriterien:**
- Symbol 3× per `<use>` an verschiedenen Positionen: jede Instanz korrekt skaliert
- Pfeil-Marker auf Linie: Spitze dreht sich automatisch in Pfadrichtung (`orient="auto"`)
- Clip-Pfad (Kreismaske) über einem Rechteck: nur der Kreis-Bereich sichtbar
- `<defs>` enthält alle Definitionen; Hauptbereich nur `<use>`-Referenzen

---

### WP-SVG-09: Bildeinbettung ⬜

**Ziel:** Rasterbilder (JPEG, PNG, rohe Pixel) als Base64-kodierte Data-URIs
direkt in das SVG einbetten — keine externe Dateiabhängigkeit des SVGs.

**API:**
```lyx
// Bild aus Datei einbetten (Base64 in data:URI)
var imgId: int64 := SvgAddImageJpeg(doc, "foto.jpg")
var imgId: int64 := SvgAddImagePng(doc, "grafik.png")

// Bild aus Speicher einbetten
var imgId: int64 := SvgAddImageJpegMem(doc, ptr, len: int64)
var imgId: int64 := SvgAddImageRGB(doc, ptr, width, height: int64)   // ohne Komprimierung
var imgId: int64 := SvgAddImageRGBA(doc, ptr, width, height: int64)

// Bild platzieren
SvgDrawImage(doc, imgId, x, y, w, h: f64)
SvgDrawImageFit(doc, imgId, x, y, maxW, maxH: f64)  // Seitenverhältnis behalten

// Direkte Einbettung (ohne vorige Registrierung)
SvgImageFile(doc, "foto.jpg", x, y, w, h: f64)  // kombiniert AddImage + DrawImage
```

**Zu implementieren:**
- Base64-Encoder (RFC 4648): Byte-Array → ASCII-String ohne Zeilenumbrüche
  - JPEG: `data:image/jpeg;base64,...`
  - PNG: `data:image/png;base64,...`
- JPEG-Header lesen (SOF-Marker): Breite und Höhe für `preserveAspectRatio`
- PNG-IHDR parsen: Breite und Höhe
- Raw-RGB → minimales PNG ohne Komprimierung (IDAT mit `None`-Filter, zlib-Level 0)
  für `SvgAddImageRGB` — vermeidet Deflate-Abhängigkeit in Phase 5
- `<image>` in `<defs>` mit `id`, dann `<use>` zum Platzieren
  — alternativ: `<image>` direkt im Hauptbereich (einfacher, dafür kein Reuse)
- `preserveAspectRatio="xMidYMid meet"` für `SvgDrawImageFit`

**Dateien:**
- `std/svg/image.lyu`  — Base64-Encoder, Bildformate, `<image>`-Element
- `std/svg.lyu`        — öffentliche API

**Akzeptanzkriterien:**
- JPEG (500 KB) in SVG eingebettet: `<image href="data:image/jpeg;base64,...">`
- Bild mit korrekten `width`/`height`-Attributen (aus Header gelesen)
- `SvgDrawImageFit`: Bild passt in Bounding-Box ohne Verzerrung
- Rohes RGB-Array als PNG-ähnliches Bild: korrekt dargestellt im Browser

---

### WP-SVG-10: Filter & Masken ⬜

**Ziel:** SVG-Filtereffekte (Unschärfe, Schatten, Farbkorrektur) und
Alpha-Masken für nicht-rechteckiges Compositing.

**API:**
```lyx
// Vordefinierte Komfort-Filter (erzeugen <filter> in <defs> + geben ID zurück)
var f: int64 := SvgDropShadow(doc, dx, dy, blur, r, g, b, a: f64)
var f: int64 := SvgBlur(doc, stdDeviation: f64)
var f: int64 := SvgGrayscale(doc)
var f: int64 := SvgSepia(doc)
var f: int64 := SvgInvert(doc)
var f: int64 := SvgBrightnessContrast(doc, brightness, contrast: f64)

// Filter anwenden (vor SvgApply, auf Element oder Gruppe)
SvgSetFilter(doc, f)

// Manueller Filter-Builder (für benutzerdefinierte Filter-Ketten)
var flt: int64 := SvgFilterBegin(doc, "myfilter", x, y, w, h: f64)
SvgFeGaussianBlur(doc, flt, "SourceGraphic", 3.0, 3.0)
SvgFeOffset(doc, flt, "", 4.0, 4.0)
SvgFeComposite(doc, flt, "", "SourceGraphic", SVG_COMP_OVER)
SvgFeColorMatrix(doc, flt, "", SVG_CM_SATURATE, 0.0)
SvgFilterEnd(doc)

// Maske (Alpha-Kanal-basiert)
var msk: int64 := SvgMaskBegin(doc, "mask1")
SvgLinearGradient(doc, "mg", 0.0, 0.0, 1.0, 0.0)  // Weiss→Schwarz = sichtbar→transparent
SvgGradientStop(doc, g, 0.0, 1.0, 1.0, 1.0, 1.0)
SvgGradientStop(doc, g, 1.0, 0.0, 0.0, 0.0, 1.0)
SvgRect(doc, 0.0, 0.0, 800.0, 600.0)
SvgSetFillGradient(doc, g)
SvgApply(doc)
SvgMaskEnd(doc)

SvgGroupBegin(doc)
SvgSetMask(doc, msk)
// … Elemente werden durch Maske ausgeblendet
SvgGroupEnd(doc)
```

**Zu implementieren:**
- `<filter>` in `<defs>`: `id`, `x`, `y`, `width`, `height` (Filter-Ausdehnung)
- Filter-Primitiven als XML-Kinder:
  - `<feGaussianBlur>`: `in`, `stdDeviation`, `result`
  - `<feOffset>`: `in`, `dx`, `dy`, `result`
  - `<feFlood>`: `flood-color`, `flood-opacity`
  - `<feComposite>`: `in`, `in2`, `operator` (over/in/out/atop/xor)
  - `<feColorMatrix>`: `type` (matrix/saturate/hueRotate/luminanceToAlpha), `values`
  - `<feMerge>` + `<feMergeNode>`: mehrere Ergebnisse zusammenführen
- Komfort-Filter als fertige Filter-Ketten:
  - Drop Shadow: feGaussianBlur + feOffset + feFlood + feComposite + feMerge
  - Grayscale/Sepia/Invert: feColorMatrix mit entsprechenden Matrizen
- `<mask>` in `<defs>`: `id`, `maskUnits`
- `mask="url(#id)"` auf Gruppen/Elementen

**Dateien:**
- `std/svg/filter.lyu` — Filter-Builder, Primitiven, Masken

**Akzeptanzkriterien:**
- `SvgDropShadow` auf einem Rechteck: sichtbarer Schatten versetzt um (dx, dy)
- `SvgBlur(doc, 5.0)` auf Text: Unschärfe korrekt im Browser gerendert
- `SvgGrayscale()` auf Gruppe mit Farben: alles in Graustufen
- Verlaufsmaske: Element faded von links (sichtbar) nach rechts (transparent)

---

### WP-SVG-11: Animation (SMIL) ⬜

**Ziel:** SVG-Animationen via SMIL (Synchronized Multimedia Integration Language)
einbetten — ohne JavaScript, nativ im SVG-Format, browserkompatibel.

**Hinweis:** SMIL-Animationen laufen in Chrome, Firefox und Safari nativ.
Für CSS-Animationen und JavaScript-Trigger ist ein gesondertes WP vorgesehen
(zukünftig), da diese den Scope deutlich erweitern.

**API:**
```lyx
// Attribut-Animation (Wert ändert sich über Zeit)
SvgAnimate(doc, elem, attrName: pchar, from, to: pchar, dur: f64, repeat: int64)
// repeat: 0 = indefinite, n = n-mal

// Beispiele:
SvgCircle(doc, 200.0, 200.0, 50.0)
SvgSetFillHex(doc, "#4a90e2")
SvgAnimate(doc, 0, "r", "50", "100", 2.0, 0)       // Radius pulsiert
SvgAnimate(doc, 0, "opacity", "1", "0.2", 1.5, 0)  // Opacity blinkt
SvgApply(doc)

// Transform-Animation
SvgAnimateTransform(doc, elem, SVG_AT_ROTATE, from, to: pchar, dur: f64, repeat: int64)
// from/to: "0 200 200" → "360 200 200" für Rotation um Mittelpunkt

// Positions-Animation entlang Pfad
var motionPath: pchar := "M 100 200 C 200 100 300 300 400 200";
SvgAnimateMotion(doc, elem, motionPath, dur: f64, repeat: int64)
SvgAnimateMotionRotate(doc, elem, motionPath, dur: f64, repeat: int64)
// auto-rotate: Objekt dreht sich in Fahrtrichtung

// Farb-Animation
SvgAnimateColor(doc, elem, attrName, fromHex, toHex: pchar, dur: f64, repeat: int64)

// Keyframe-Animation (mehrere Werte)
var kf: int64 := SvgKeyframesBegin(doc, elem, "r")
SvgKeyframe(doc, kf, 0.0,  "50")    // Zeit 0%: r=50
SvgKeyframe(doc, kf, 0.5,  "100")   // Zeit 50%: r=100
SvgKeyframe(doc, kf, 1.0,  "50")    // Zeit 100%: r=50
SvgKeyframesEnd(doc, kf, 2.0, 0)    // dur=2s, indefinite

// Trigger (begin nach anderem Element)
SvgAnimateBeginOn(doc, anim, otherAnim, "end")   // startet wenn otherAnim endet

// Konstanten
SVG_AT_TRANSLATE = 0
SVG_AT_SCALE     = 1
SVG_AT_ROTATE    = 2
SVG_AT_SKEWX     = 3
SVG_AT_SKEWY     = 4
```

**Zu implementieren:**
- `<animate>`: `attributeName`, `from`, `to`, `dur` (z.B. `"2s"`), `repeatCount`
  (`"indefinite"` oder Zahl), `begin` (optional)
- `<animateTransform>`: wie `<animate>` + `type` (translate/scale/rotate/skewX/skewY)
- `<animateMotion>`: `path` (SVG-Pfad-d-String), `dur`, `repeatCount`
  + `<mpath href="#pathId">` als Alternative zu inline `path`
- `<animateMotion>` mit `rotate="auto"`: Objekt richtet sich an Pfadrichtung aus
- Keyframe-Variante: `values` (`;`-separierte Liste) + `keyTimes` + `keySplines`
- Zeitformat: f64 (Sekunden) → `"2.5s"` String

**Dateien:**
- `std/svg/anim.lyu` — alle SMIL-Animationselemente

**Akzeptanzkriterien:**
- Pulsierender Kreis (Radius 50→100→50, 2s, indefinite): im Browser animiert
- Rotation eines Rechtecks um seinen Mittelpunkt: `<animateTransform type="rotate">`
- Objekt entlang Bézier-Pfad: `<animateMotion>` korrekt, Objekt bewegt sich
- Keyframe-Animation (3 Werte): korrekte `values` und `keyTimes` Attribute
- `repeatCount="indefinite"` und `repeatCount="3"` beide korrekt serialisiert

---

### WP-SVG-12: SVG-Parser (Lesen) ⬜

**Ziel:** Bestehende SVG-Dateien einlesen, die Element-Struktur traversieren
und Attributwerte auslesen — Grundlage für SVG-Bearbeitung und -Konvertierung.

**API:**
```lyx
// SVG laden
var doc: int64 := SvgOpen("input.svg")
if (doc == 0) { /* Fehler */ }

// Dokument-Eigenschaften
var w: f64 := SvgReadWidth(doc)
var h: f64 := SvgReadHeight(doc)
var vb: pchar := SvgReadViewBox(doc)   // "0 0 800 600"

// Element-Tree traversieren
var root: int64 := SvgRootElement(doc)
var child: int64 := SvgFirstChild(root)
while (child != 0) {
  var tag: pchar := SvgElementTag(child)     // "rect", "circle", "g", …
  var id:  pchar := SvgElementId(child)      // id-Attribut oder ""
  var x: f64 := SvgAttrF64(child, "x", 0.0) // Attribut als f64 mit Default
  var fill: pchar := SvgAttrStr(child, "fill")
  child = SvgNextSibling(child)
}

// Suche nach ID
var elem: int64 := SvgFindId(doc, "main-chart")

// Anzahl Elemente eines Typs
var nRects: int64 := SvgCountByTag(doc, "rect")

// Lesen von Pfad-d-Attribut
var d: pchar := SvgPathData(elem)

SvgFree(doc)
```

**Zu implementieren:**
- **XML-Lexer** (`svg/xml.lyu` Erweiterung):
  - Tokens: TagOpen, TagClose, TagSelfClose, AttrName, AttrValue, TextContent, Comment
  - UTF-8-durchleitend: Byte-Werte werden nicht dekodiert, nur als pchar weitergegeben
  - Entity-Dekodierung: `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` → Zeichen
- **Element-Tree-Builder:**
  - DOM-artiger Baum: jeder Knoten hat Tag, Attribut-Liste (Key-Value-Array),
    Kinder-Liste, Eltern-Zeiger
  - Allokation im Pool für schnelle `SvgFree`
- **SVG-spezifische Lesefunktionen:**
  - `width`/`height`: Einheiten-Parsing (`px`, `pt`, `mm`, `cm`, `%`, kein Suffix)
  - `viewBox`: 4 Zahlen parsen
  - `transform`-Attribut: `translate()`, `rotate()`, `scale()` parsen
- **Fehlerbehandlung:**
  - Fehlerhaftes XML: `SvgOpen` gibt 0 zurück
  - Fehler-Details: `SvgGetError(doc) → pchar`

**Dateien:**
- `std/svg/parser.lyu` — XML-Lexer, Tree-Builder, Lese-API
- `std/svg/xml.lyu`    — XML-Lexer (Erweiterung des Writers aus WP-SVG-01)

**Akzeptanzkriterien:**
- Valides SVG (erzeugt von WP-SVG-02) wird korrekt geparst
- `SvgReadWidth`, `SvgReadHeight`: korrekte Werte aus `width`/`height`-Attributen
- `SvgFindId`: findet Element mit gesuchter ID in verschachteltem Tree
- Entities in Attributwerten korrekt dekodiert: `&amp;` → `&`
- Fehlerhaftes XML (unklosene Tags): `SvgOpen` gibt 0, kein Absturz

---

## Meilensteine

| Meilenstein | WPs | Ergebnis |
|-------------|-----|----------|
| M1: Minimales SVG | SVG-01, SVG-02 | Valide SVG-Datei mit Grundformen |
| M2: Vektorgrafik | SVG-03, SVG-04 | Pfade, Linien, Dash, Transformationen |
| M3: Struktur & Text | SVG-05, SVG-06 | Gruppen, Ebenen, Typografie |
| M4: Dekorative Grafik | SVG-07, SVG-08 | Gradienten, Muster, Symbole, Clipping |
| M5: Reiche Medien | SVG-09, SVG-10 | Bilder, Filter, Masken, Schatten |
| M6: Animation | SVG-11 | SMIL-Animationen im Browser |
| M7: SVG-Verarbeitung | SVG-12 | SVG lesen, traversieren, auslesen |

---

## API-Übersicht (vollständig)

### Dokument
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgNew` | `(w, h: f64) → int64` | Neues Dokument |
| `SvgSave` | `(doc, path: pchar) → int64` | Datei schreiben |
| `SvgToString` | `(doc) → pchar` | Als String |
| `SvgFree` | `(doc)` | Freigeben |
| `SvgOpen` | `(path: pchar) → int64` | SVG einlesen |
| `SvgSetViewBox` | `(doc, x, y, w, h: f64)` | ViewBox setzen |
| `SvgSetPrettyPrint` | `(doc, enabled: int64)` | Formatierung an/aus |

### Primitive
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgRect` | `(doc, x, y, w, h: f64)` | Rechteck |
| `SvgRoundRect` | `(doc, x, y, w, h, rx, ry: f64)` | Abgerundetes Rechteck |
| `SvgCircle` | `(doc, cx, cy, r: f64)` | Kreis |
| `SvgEllipse` | `(doc, cx, cy, rx, ry: f64)` | Ellipse |
| `SvgLine` | `(doc, x1, y1, x2, y2: f64)` | Linie |
| `SvgPolyline` | `(doc, points: pchar)` | Polyline |
| `SvgPolygon` | `(doc, points: pchar)` | Polygon |
| `SvgApply` | `(doc)` | Element mit Styles schreiben |

### Pfade
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgPathBegin` | `(doc)` | Pfad starten |
| `SvgMoveTo` | `(doc, x, y: f64)` | Move To |
| `SvgLineTo` | `(doc, x, y: f64)` | Line To |
| `SvgCurveTo` | `(doc, x1, y1, x2, y2, x, y: f64)` | Kubische Bézier |
| `SvgQuadTo` | `(doc, x1, y1, x, y: f64)` | Quadratische Bézier |
| `SvgArcTo` | `(doc, rx, ry, rot: f64, laf, sf: int64, x, y: f64)` | Ellipsen-Bogen |
| `SvgClosePath` | `(doc)` | Pfad schließen |
| `SvgPathArc` | `(doc, cx, cy, r, a0, a1: f64)` | Kreisbogen (Hilfsfn.) |
| `SvgPathStar` | `(doc, cx, cy, r1, r2: f64, n: int64)` | Stern |

### Styling
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgSetFill` | `(doc, r, g, b: f64)` | Füllfarbe |
| `SvgSetFillAlpha` | `(doc, r, g, b, a: f64)` | Füllfarbe mit Alpha |
| `SvgSetFillNone` | `(doc)` | Keine Füllung |
| `SvgSetFillHex` | `(doc, hex: pchar)` | Hex-Farbe |
| `SvgSetFillGradient` | `(doc, gradId: int64)` | Gradient-Füllung |
| `SvgSetStroke` | `(doc, r, g, b: f64)` | Konturfarbe |
| `SvgSetStrokeWidth` | `(doc, w: f64)` | Konturstärke |
| `SvgSetOpacity` | `(doc, a: f64)` | Gesamttransparenz |
| `SvgSetDashArray` | `(doc, pattern: pchar)` | Strichmuster |
| `SvgSetLineCap` | `(doc, cap: int64)` | Linienende |
| `SvgSetLineJoin` | `(doc, join: int64)` | Linienverbindung |

### Transformationen
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgTranslate` | `(doc, tx, ty: f64)` | Verschiebung |
| `SvgScale` | `(doc, sx, sy: f64)` | Skalierung |
| `SvgRotate` | `(doc, angle: f64)` | Rotation |
| `SvgRotateAround` | `(doc, angle, cx, cy: f64)` | Rotation um Punkt |
| `SvgMatrix` | `(doc, a, b, c, d, e, f: f64)` | Volle Matrix |

### Gruppen
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgGroupBegin` | `(doc) → int64` | Gruppe öffnen |
| `SvgGroupBeginId` | `(doc, id: pchar) → int64` | Gruppe mit ID |
| `SvgGroupEnd` | `(doc)` | Gruppe schließen |
| `SvgSetId` | `(doc, elem, id: pchar)` | id-Attribut |
| `SvgSetClass` | `(doc, elem, cls: pchar)` | class-Attribut |

### Text
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgTextAt` | `(doc, x, y: f64, text: pchar)` | Text platzieren |
| `SvgSetFont` | `(doc, family: pchar, size: f64)` | Schriftart |
| `SvgSetFontWeight` | `(doc, weight: int64)` | Gewicht |
| `SvgSetTextAnchor` | `(doc, anchor: int64)` | Ausrichtung |
| `SvgTextBegin` | `(doc, x, y: f64)` | `<text>` öffnen |
| `SvgTspan` | `(doc, text: pchar, dx, dy: f64)` | Textzeile |
| `SvgTextEnd` | `(doc)` | `<text>` schließen |
| `SvgTextOnPath` | `(doc, pathId: pchar, text: pchar, offset: f64)` | Text auf Pfad |

### Gradienten & Muster
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgLinearGradient` | `(doc, id: pchar, x1, y1, x2, y2: f64) → int64` | Linearer Verlauf |
| `SvgRadialGradient` | `(doc, id: pchar, cx, cy, r, fx, fy: f64) → int64` | Radialer Verlauf |
| `SvgGradientStop` | `(doc, g, offset, r, g2, b, a: f64)` | Verlauf-Stopp |
| `SvgPatternBegin` | `(doc, id: pchar, x, y, w, h: f64) → int64` | Muster |
| `SvgPatternEnd` | `(doc)` | Muster schließen |
| `SvgSetFillPattern` | `(doc, patId: int64)` | Muster als Füllung |

### Symbole & Marker
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgSymbolBegin` | `(doc, id: pchar, vw, vh: f64) → int64` | Symbol definieren |
| `SvgSymbolEnd` | `(doc)` | Symbol schließen |
| `SvgUse` | `(doc, id: pchar, x, y, w, h: f64)` | Symbol verwenden |
| `SvgMarkerBegin` | `(doc, id: pchar, mw, mh, rx, ry: f64) → int64` | Marker definieren |
| `SvgMarkerEnd` | `(doc)` | Marker schließen |
| `SvgSetMarkerEnd` | `(doc, markerId: int64)` | Pfeil-Ende |
| `SvgClipPathBegin` | `(doc, id: pchar) → int64` | Clip-Pfad definieren |
| `SvgClipPathEnd` | `(doc)` | Clip-Pfad schließen |
| `SvgSetClipPath` | `(doc, clipId: int64)` | Clip-Pfad anwenden |

### Filter & Masken
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgDropShadow` | `(doc, dx, dy, blur, r, g, b, a: f64) → int64` | Schatten |
| `SvgBlur` | `(doc, stdDev: f64) → int64` | Unschärfe |
| `SvgGrayscale` | `(doc) → int64` | Graustufen |
| `SvgSetFilter` | `(doc, filterId: int64)` | Filter anwenden |
| `SvgMaskBegin` | `(doc, id: pchar) → int64` | Maske definieren |
| `SvgMaskEnd` | `(doc)` | Maske schließen |
| `SvgSetMask` | `(doc, maskId: int64)` | Maske anwenden |

### Bilder
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgAddImageJpeg` | `(doc, path: pchar) → int64` | JPEG einbetten |
| `SvgAddImagePng` | `(doc, path: pchar) → int64` | PNG einbetten |
| `SvgAddImageRGB` | `(doc, ptr, w, h: int64) → int64` | Raw-RGB |
| `SvgDrawImage` | `(doc, imgId, x, y, w, h: f64)` | Bild platzieren |
| `SvgDrawImageFit` | `(doc, imgId, x, y, mw, mh: f64)` | Proportional |

### Animation
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgAnimate` | `(doc, elem, attr, from, to: pchar, dur: f64, repeat: int64)` | Attribut-Animation |
| `SvgAnimateTransform` | `(doc, elem, type, from, to: pchar, dur: f64, repeat: int64)` | Transform-Animation |
| `SvgAnimateMotion` | `(doc, elem, path: pchar, dur: f64, repeat: int64)` | Pfad-Animation |
| `SvgKeyframesBegin` | `(doc, elem, attr: pchar) → int64` | Keyframe-Animation |
| `SvgKeyframe` | `(doc, kf, time: f64, value: pchar)` | Einzelner Keyframe |
| `SvgKeyframesEnd` | `(doc, kf, dur: f64, repeat: int64)` | Animation abschließen |

### Lesen (Parser)
| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `SvgOpen` | `(path: pchar) → int64` | SVG einlesen |
| `SvgReadWidth` | `(doc) → f64` | Dokumentbreite |
| `SvgReadHeight` | `(doc) → f64` | Dokumenthöhe |
| `SvgRootElement` | `(doc) → int64` | SVG-Root-Element |
| `SvgFirstChild` | `(elem) → int64` | Erstes Kind-Element |
| `SvgNextSibling` | `(elem) → int64` | Nächstes Geschwister |
| `SvgElementTag` | `(elem) → pchar` | Tag-Name |
| `SvgElementId` | `(elem) → pchar` | id-Attribut |
| `SvgAttrStr` | `(elem, name: pchar) → pchar` | Attribut als String |
| `SvgAttrF64` | `(elem, name: pchar, def: f64) → f64` | Attribut als f64 |
| `SvgFindId` | `(doc, id: pchar) → int64` | Element per ID suchen |
| `SvgGetError` | `(doc) → pchar` | Letzter Fehler |

---

## Offene Fragen / Entscheidungen

| # | Frage | Optionen | Empfehlung |
|---|-------|----------|------------|
| 1 | Styling-Modell | Inline-Attribute / `style=""`-String / CSS-Klassen | Inline-Attribute als Default; `style`-String optional per Flag |
| 2 | Farbformat intern | f64 (0.0–1.0) / uint8 (0–255) / pchar-Hex | f64 für API-Konsistenz mit PDF-Bibliothek; Hex nur beim Ausgeben |
| 3 | Pfad-Zahlenformat | printf-formatiert / eigener f64→str | Eigener Formatter: keine trailing zeros, max 4 Dezimalstellen |
| 4 | Base64 für Bilder | Eigene Implementierung / FFI | Eigene Implementierung (~60 Zeilen), keine Abhängigkeit nötig |
| 5 | SVG-Version | 1.1 / 2.0 | SVG 1.1 (maximale Browser-Kompatibilität; SVG 2.0 noch nicht überall) |
| 6 | Fehler-Rückgabe | Return-Code (int64) / Panic | Return-Code; `SvgGetError(doc) → pchar` für Details |
| 7 | Animation | SMIL / CSS-Animationen / beide | SMIL für V1 (nativ SVG, kein JS nötig); CSS-Animationen optional später |
| 8 | API-Ähnlichkeit zu std/pdf | Identisches Builder-Pattern / Eigenständig | Builder-Pattern identisch zu std/pdf: `SvgXxx(doc, ...)` + `SvgApply(doc)` |
