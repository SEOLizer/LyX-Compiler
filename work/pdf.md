# Lyx PDF-Bibliothek (`std/pdf`) — Offene Work Packages

**Abgeschlossen:** WP-PDF-01 bis WP-PDF-16 (Objekte, Seiten, Text, Grafik, Komprimierung,
Bilder, Metadaten, Annotierungen, Reader, Outlines, Seitenbeschriftungen, Seitenübergänge,
Viewer-Einstellungen, Named Destinations, Dateianhänge, Ebenen/OCG).

**Konvention:** WP-PDF-NN. Status: ⬜ Offen.

---

### WP-PDF-17: Verschlüsselung & Passwortschutz ⬜

**Ziel:** PDF mit User- und Owner-Passwort schützen; Berechtigungen einschränken
(Drucken, Kopieren, Bearbeiten).

**API:**
```lyx
PdfSetUserPassword(doc, "leser")          // zum Öffnen
PdfSetOwnerPassword(doc, "admin")         // zum Bearbeiten
PdfSetPermissions(doc, PDF_PERM_PRINT | PDF_PERM_COPY)
// PDF_PERM_PRINT / COPY / MODIFY / ANNOTATE / FILLFORMS
PdfSetEncryption(doc, PDF_ENC_AES128)     // PDF_ENC_RC4_128 / AES128 / AES256
```

**Zu implementieren:**
- RC4-128 und AES-128 Verschlüsselung (PDF 1.4 / 1.6)
- Encryption-Dict im Trailer: `/Filter /Standard /V /R /O /U /P`
- Schlüsselableitung: MD5/SHA-256 je nach AES-Variante
- Alle Objekt-Streams und Strings verschlüsseln beim Serialisieren

**Akzeptanzkriterien:**
- Evince/Acrobat fragt nach Passwort beim Öffnen
- Owner-Passwort erlaubt Bearbeitung, User-Passwort nur Lesen
- `pdfinfo -upw leser out.pdf` liefert Metadaten korrekt

---

### WP-PDF-18: Formularfelder (AcroForms) ⬜

**Ziel:** Interaktive Formularfelder: Textfelder, Checkboxen, Radiobuttons, Dropdowns.

**API:**
```lyx
PdfAddTextField(doc, page, x, y, w, h, name, defaultValue)  → int64
PdfAddCheckbox(doc, page, x, y, size, name, checked)         → int64
PdfAddRadioButton(doc, page, x, y, size, groupName, value)   → int64
PdfAddComboBox(doc, page, x, y, w, h, name, items, count)    → int64
PdfFlattenForms(doc)   // alle Felder in statischen Inhalt umwandeln
```

**Zu implementieren:**
- `/AcroForm`-Dict im Catalog mit `/Fields`-Array
- Widget-Annotation je Feld (`/Subtype /Widget`)
- Appearance-Stream (AP) für Checkboxen und Radiobuttons
- Default Appearance-String (`/DA`) für Textfelder

**Akzeptanzkriterien:**
- Textfeld editierbar in Acrobat/Evince
- Checkbox kann an-/abgehakt werden
- `PdfFlattenForms` erzeugt visuell identisches PDF ohne interaktive Felder

---

### WP-PDF-19: PDF mergen / Seiten einfügen ⬜

**Ziel:** Seiten aus bestehenden PDFs in ein neues Dokument kopieren.

**API:**
```lyx
PdfImportPage(dst, src, srcPageIdx)    → int64  // neue Page-Handle in dst
PdfMergeAll(dst, src)                           // alle Seiten von src in dst
```

**Zu implementieren:**
- Alle Objekte einer Seite (Content-Stream, Font-Ressourcen, XObjects) aus `src`
  in `dst` kopieren, IDs umnummerieren
- Ressourcen-Konflikte auflösen (Font `/F0` in src vs. dst)
- Reader-Handle (WP-PDF-09) als Quelle nutzen

**Akzeptanzkriterien:**
- Zwei 3-seitige PDFs zu einem 6-seitigen zusammenführen; alle Texte/Bilder intakt
- Fonts aus `src` korrekt re-registriert in `dst`

---

### WP-PDF-20: Seitenrotation ⬜

**Ziel:** Einzelne Seiten rotieren (0 / 90 / 180 / 270 Grad).

**API:**
```lyx
PdfSetPageRotation(doc, pageIdx, degrees)   // degrees: 0, 90, 180, 270
```

**Zu implementieren:**
- `/Rotate`-Eintrag im Page-Dict setzen
- Validation: nur Vielfache von 90 erlaubt

**Akzeptanzkriterien:**
- Seite 0 auf 90°, Seite 1 auf 270° — Viewer zeigt korrekte Ausrichtung

---

### WP-PDF-21: Textextraktion im Reader ⬜

**Ziel:** Rohtext aus einer Seite des gelesenen PDFs extrahieren.

**API:**
```lyx
PdfRdrExtractText(rdr, pageIdx, buf, maxLen)   // NUL-terminiert
```

**Zu implementieren:**
- Content-Stream der Seite parsen (BT/ET, Tj/TJ, Tf, Td/TD/Tm)
- String-Dekodierung: Literal `(...)` und Hex `<...>`
- Zeilenumbrüche via Td/TD-Verschiebung inferieren

**Akzeptanzkriterien:**
- Text aus WP-PDF-03-erzeugtem PDF vollständig extrahierbar
- Mehrzeiliger Text enthält `\n` an den richtigen Stellen

---

### WP-PDF-22: Verläufe / Shading ⬜

**Ziel:** Lineare und radiale Farbverläufe als Füllmuster.

**API:**
```lyx
PdfLinearGradient(doc, page, x0, y0, x1, y1, r0, g0, b0, r1, g1, b1)
PdfRadialGradient(doc, page, cx, cy, r0, r1, ri0, gi0, bi0, ri1, gi1, bi1)
```

**Zu implementieren:**
- Shading-Dict Typ 2 (axial) und Typ 3 (radial)
- `/Shading`-Ressource im Seiten-Dict
- `sh`-Operator im Content-Stream

**Akzeptanzkriterien:**
- Linearer Verlauf von Blau nach Weiß über Seite sichtbar
- Radialer Verlauf mit transparentem Außenring via Alpha-SMask

---

### WP-PDF-23: Form XObjects ⬜

**Ziel:** Wiederverwendbare Grafikblöcke (z.B. Logo, Kopfzeile) einmal definieren
und auf mehreren Seiten platzieren.

**API:**
```lyx
var xobj: int64 := PdfBeginXObject(doc, w, h)
// ... beliebige Zeichen-Operationen ...
PdfEndXObject(doc, xobj)
PdfDrawXObject(doc, page, xobj, x, y, w, h)
```

**Zu implementieren:**
- Form-XObject (`/Subtype /Form`) mit eigenem Content-Stream
- `/BBox`, `/Matrix` im XObject-Dict
- `Do`-Operator im Seiten-Content; Ressourcen-Registrierung

**Akzeptanzkriterien:**
- Logo-XObject einmal definiert, auf 10 Seiten platziert — Dateigröße wächst nicht proportional
- XObject-Inhalt korrekt geclippt auf BBox

---

### WP-PDF-24: TrueType-Font-Einbettung ⬜

**Ziel:** Beliebige TrueType-Fonts (`.ttf`) in das PDF einbetten mit Subsetting
(nur verwendete Glyphen), sodass das PDF auf jedem Gerät identisch aussieht.

**API:**
```lyx
var fontId: int64 := PdfLoadFont(doc, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
PdfSetFontTT(doc, page, fontId, 14.0)
PdfTextAtUTF8(doc, page, 72.0, 720.0, "Привет мир")
```

**Zu implementieren:**
- TrueType-Parser: Tabellen `cmap` (Format 4), `glyf`, `loca`, `hmtx`, `head`, `hhea`, `maxp`
- Unicode → Glyph-ID-Mapping via `cmap`
- Subsetter: nur verwendete Glyph-IDs in Subset-Font kopieren
- PDF-Einbettung: `/Type /Font /Subtype /TrueType` (Latin) + `/Type0`/CIDFont für Unicode
- `/ToUnicode`-CMap für Copy/Paste im Viewer
- `/FontDescriptor` mit `/FontFile2`

**Akzeptanzkriterien:**
- Kyrillischer Text mit DejaVuSans-TTF korrekt dargestellt
- Font-Subset deutlich kleiner als Original-TTF
- Text im Viewer selektierbar und kopierbar
- PDF öffnet korrekt auf System ohne installierten Font

---

### WP-PDF-25: Spot-Farben ⬜

**Ziel:** PANTONE und andere Sonderfarben für Druckvorstufe.

**API:**
```lyx
var spotId: int64 := PdfDefineSpotColor(doc, "PANTONE 485 C", 0.0, 0.9, 0.85, 0.0)
PdfSetStrokeSpot(doc, page, spotId, 1.0)   // tint: 0.0–1.0
PdfSetFillSpot(doc, page, spotId, 0.5)
```

**Zu implementieren:**
- `/ColorSpace [/Separation /Name /DeviceCMYK tintTransform]` im Seiten-Dict
- `CS cs SC sc`-Operatoren im Content-Stream
- Alternativfarbraum (CMYK) als Fallback

**Akzeptanzkriterien:**
- Spot-Farbe erscheint in Acrobat Separation-Preview
- CMYK-Fallback auf Systemen ohne Spot-Unterstützung korrekt

---

### WP-PDF-26: XMP-Metadaten ⬜

**Ziel:** Extended Metadata Platform (XMP) als XML-Stream im Catalog — Voraussetzung
für PDF/A.

**API:**
```lyx
PdfSetXMP(doc, xmpXml, len)   // roher XMP-Blob
// oder automatisch aus /Info-Dict generieren:
PdfGenerateXMP(doc)
```

**Zu implementieren:**
- `/Metadata`-Stream am Catalog (`/Type /Metadata /Subtype /XML`)
- XMP-Paket: `<x:xmpmeta>` mit Dublin Core (`dc:title`, `dc:creator` etc.)
- Synchronisation mit `/Info`-Dict-Werten

**Akzeptanzkriterien:**
- `exiftool out.pdf` liest XMP-Felder korrekt
- Titel und Autor aus `PdfSetTitle`/`PdfSetAuthor` im XMP vorhanden

---

### WP-PDF-27: PDF/A-Konformität ⬜

**Ziel:** PDF/A-1b-konformes Ausgabeformat für Langzeitarchivierung.

**API:**
```lyx
PdfSetConformance(doc, PDF_CONFORMANCE_A1B)
// PDF_CONFORMANCE_A1B / A2B / A3B
```

**Zu implementieren:**
- OutputIntent (`/GTS_PDFA1`) mit ICC-Profil (sRGB)
- XMP-Metadaten mit `pdfaid:conformance` und `pdfaid:part` (→ WP-PDF-26)
- Alle Fonts eingebettet (→ WP-PDF-24)
- Keine Transparenz (flatten falls vorhanden)
- Keine Verschlüsselung im PDF/A-Modus

**Akzeptanzkriterien:**
- `veraPDF out.pdf` meldet PDF/A-1b-Konformität ohne Fehler
