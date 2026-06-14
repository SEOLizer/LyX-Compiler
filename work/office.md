# ODF-Bibliothek — Arbeitspakete (OFF)

> Ziel: Lyx-Stdlib-Unit `std/office.lyx` zum Erzeugen von `.odt`- und `.ods`-Dateien.  
> Scope V1: **Nur Schreiben** (kein Lesen/Parsen). Lesen kommt in V2.  
> Abhängigkeit: `std/zip.lyx` (DEFLATE + STORE), `std/string.lyx`

---

## Abhängigkeitsreihenfolge

```
OFF-01  →  OFF-02  →  OFF-03  →  OFF-04
                  ↘              OFF-05
```

---

## OFF-01: ZIP-Writer — STORE/DEFLATE mit mimetype-Garantie

### Info

ODF-Dateien sind ZIP-Archive. Die einzige Besonderheit gegenüber normalem ZIP:
Die Datei `mimetype` **muss** der allererste Eintrag im ZIP-Stream sein, und sie
**muss** unkomprimiert gespeichert werden (Compression Method = 0, STORE).
Erst danach folgen alle anderen Dateien (gerne DEFLATE-komprimiert).

`std/zip.lyx` muss deshalb einen Modus unterstützen, bei dem der erste Eintrag
erzwungen STORE ist. Das API-Design:

```lyx
pub fn ZipOpenWrite(path: pchar): ZipWriter
pub fn ZipAddFileStore(z: ZipWriter, name: pchar, data: pchar, size: int64)   // STORE
pub fn ZipAddFileDeflate(z: ZipWriter, name: pchar, data: pchar, size: int64) // DEFLATE
pub fn ZipClose(z: ZipWriter)
```

Die ODF-Wrapper-Funktion:

```lyx
fn odf_zip_write(outPath: pchar, files: OdfFileList) {
  var z: ZipWriter := ZipOpenWrite(outPath);
  // mimetype MUSS als erstes und STORE:
  ZipAddFileStore(z, "mimetype"c, files.mimetype, files.mimetypeLen);
  ZipAddFileDeflate(z, "META-INF/manifest.xml"c, files.manifest, files.manifestLen);
  ZipAddFileDeflate(z, "content.xml"c, files.content, files.contentLen);
  ZipAddFileDeflate(z, "styles.xml"c, files.styles, files.stylesLen);
  ZipAddFileDeflate(z, "meta.xml"c, files.meta, files.metaLen);
  ZipClose(z);
}
```

### Wichtige Hinweise

- **Reihenfolge ist Standard, nicht optional.** LibreOffice und das ODF-1.3-Spec
  verlangen `mimetype` an Position 0 im Central Directory — nicht nur irgendwo
  vor den anderen Dateien, sondern als allerersten Local-File-Header im Stream.
- **STORE bedeutet: kein DEFLATE, kein Header-Flag, kein CRC-Trick.** Viele
  ZIP-Implementierungen erlauben `STORE`, setzen dabei aber fälschlich
  `compressed_size != uncompressed_size`. Das führt zu Korruptions-Warnung in
  LibreOffice — CRC und beide Größenfelder müssen identisch sein.
- **Kein BOM in mimetype.** Die Datei enthält exakt den String
  `application/vnd.oasis.opendocument.text` (für `.odt`) ohne Zeilenumbruch,
  ohne BOM, ohne Leerzeichen.
- `std/zip.lyx` prüfen: unterstützt es `STORE`? Falls nicht, muss es erweitert
  werden, bevor OFF-01 abgeschlossen werden kann.

### Abnahmekriterien

- [ ] Generierte `.odt`-Datei öffnet ohne Warnung in LibreOffice 7+
- [ ] `zipinfo -v output.odt | head -5` zeigt `mimetype` als ersten Eintrag mit
  `method: stored`
- [ ] `mimetype`-Datei enthält exakt `application/vnd.oasis.opendocument.text`
  (kein `\n`, kein BOM) — prüfbar mit `xxd output.odt | head -4`
- [ ] Alle anderen Dateien im ZIP sind mit DEFLATE komprimiert
- [ ] Test mit einer Datei > 64 KB komprimierten Content (ZIP64-Felder korrekt)

---

## OFF-02: XML-Skelette — Namespace-Deklarationen und Default-Templates

### Info

Jede ODF-XML-Datei braucht korrekte Namespace-Präfixe im Root-Tag, sonst
verweigert LibreOffice das Öffnen. Diese Skelette werden als Lyx-String-Konstanten
hardcodiert und bilden die Grundlage jeder erzeugten Datei.

**`content.xml`-Skeleton (Minimal):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
  office:version="1.3">
  <office:automatic-styles/>
  <office:body>
    <office:text>
      <!-- Inhalt hier -->
    </office:text>
  </office:body>
</office:document-content>
```

**`styles.xml`-Skeleton (Default-Seitenränder + Standard-Absatz):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<office:document-styles
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
  office:version="1.3">
  <office:styles>
    <style:style style:name="Standard" style:family="paragraph" style:class="text"/>
    <style:style style:name="TextBold"   style:family="text">
      <style:text-properties fo:font-weight="bold"/>
    </style:style>
    <style:style style:name="TextItalic" style:family="text">
      <style:text-properties fo:font-style="italic"/>
    </style:style>
  </office:styles>
  <office:automatic-styles>
    <style:page-layout style:name="PageDefault">
      <style:page-layout-properties
        fo:margin-top="2cm" fo:margin-bottom="2cm"
        fo:margin-left="2.5cm" fo:margin-right="2.5cm"/>
    </style:page-layout>
  </office:automatic-styles>
  <office:master-styles>
    <style:master-page style:name="Standard" style:page-layout-name="PageDefault"/>
  </office:master-styles>
</office:document-styles>
```

**`meta.xml`-Skeleton:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  office:version="1.3">
  <office:meta>
    <meta:generator>lyxc 0.9.9A</meta:generator>
    <dc:date><!-- ISO-8601 Datum --></dc:date>
  </office:meta>
</office:document-meta>
```

**`META-INF/manifest.xml` wird dynamisch generiert** (OFF-03).

In Lyx werden diese Templates als `pchar`-Konstanten gespeichert und dann
per String-Builder zusammengesetzt (nicht geparst):

```lyx
con ODF_CONTENT_HEADER: pchar := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content ..."c;
con ODF_CONTENT_FOOTER: pchar := "  </office:text>\n </office:body>\n</office:document-content>\n"c;
```

### Wichtige Hinweise

- **Encoding muss UTF-8 sein.** Das `<?xml ... encoding="UTF-8"?>` ist nicht
  optional. Alle String-Inhalte, die vom Nutzer kommen, müssen auf Sonderzeichen
  geprüft und XML-escaped werden: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`,
  `"` → `&quot;`.
- **Keine zusätzlichen Leerzeichen oder BOM** im XML-Header. `<?xml` muss der
  allererste Byte-Inhalt der Datei sein (Byte 0 = `<`, Byte 1 = `?`).
- **`office:version="1.3"`** ist der aktuelle Standard. LibreOffice akzeptiert
  auch `1.2`, aber `1.3` sollte das Ziel sein.
- **Namespace-Vollständigkeit**: Fehlende Namespace-Deklarationen führen zu
  stillen Korruptionen (LibreOffice öffnet die Datei, aber Formatierungen gehen
  verloren). Alle verwendeten Präfixe müssen im Root-Tag deklariert sein.
- Die Skelette als **Hardcode-Templates** (nicht als XML-DOM) zu handhaben ist
  die richtige Wahl für V1 — kein XML-Parser nötig, keine Abhängigkeiten.

### Abnahmekriterien

- [ ] Alle erzeugten XML-Dateien sind valides UTF-8 (kein BOM, kein Latin-1)
- [ ] `xmllint --noout content.xml` gibt keine Fehler aus
- [ ] XML-Escape-Funktion `odf_escape(s)` besteht Tests für: `&`, `<`, `>`,
  `"`, `'`, leerer String, reiner ASCII, Umlaute (ä, ö, ü, ß), Emoji
- [ ] Skeleton-Konstanten für `content.xml`, `styles.xml`, `meta.xml` sind
  in `src/tools/office/odf_xml.lyx` definiert und kompilierbar
- [ ] `styles.xml` enthält gültige Default-Styles für `Standard`, `TextBold`,
  `TextItalic` und Seitenränder — nachprüfbar in LibreOffice unter
  *Format → Styles → Zeichen-Styles*

---

## OFF-03: ODF-Dokument-Kern — OdfDocument-Klasse und manifest.xml

### Info

Die zentrale Klasse `OdfDocument` verwaltet alle XML-Buffer im Speicher und
generiert am Ende die vollständige ODF-Datei.

```lyx
class OdfDocument {
  pub docType:   int64;   // ODF_TYPE_TEXT=1, ODF_TYPE_SPREADSHEET=2
  contentBuf:    int64;   // alloc-Buffer für content.xml-Body
  contentLen:    int64;
  contentCap:    int64;
  autoStyleBuf:  int64;   // automatic-styles (inline-Formatierungen)
  autoStyleLen:  int64;
  autoStyleCap:  int64;
  autoStyleIdx:  int64;   // Zähler für Style-Namen (as0, as1, ...)

  pub fn Init(docType: int64)
  pub fn Close()
  pub fn SaveToFile(path: pchar): int64   // 0=ok, -1=Fehler

  // intern:
  fn _appendContent(s: pchar, len: int64)
  fn _appendAutoStyle(s: pchar, len: int64)
  fn _buildManifest(): pchar
  fn _buildMeta(): pchar
  fn _buildContent(): pchar
}
```

**`manifest.xml` wird dynamisch erzeugt**, weil die enthaltenen Dateien vom
`docType` abhängen:

```lyx
fn _buildManifest(): pchar {
  // Skeleton + je eine <manifest:file-entry> pro Datei
  // Pflicht-Einträge: "/", "content.xml", "styles.xml", "meta.xml"
  // Kein Eintrag für "mimetype" (das ist der Spec-Wortlaut)
}
```

`SaveToFile()` ruft intern `odf_zip_write()` (OFF-01) auf.

### Wichtige Hinweise

- **`manifest.xml` braucht keinen Eintrag für `mimetype`** — das ist eine
  explizite Ausnahme im ODF-Spec. Alle anderen Dateien müssen drin stehen.
- **Buffer-Management**: `contentBuf` und `autoStyleBuf` wachsen dynamisch
  (ähnlich `StringBuilder`). Startgröße 8 KB, verdoppeln wenn voll.
- **`office:automatic-styles`** enthält inline-Styles, die nur für dieses
  Dokument gelten (z.B. `TextBoldItalic`-Kombination). Sie werden in einem
  separaten Buffer gesammelt und beim Schreiben von `content.xml` zwischen
  `<office:automatic-styles>` und `<office:body>` eingefügt.
- **`SaveToFile()` ist die einzige öffentliche IO-Funktion.** Kein
  `SaveToStream()` in V1 — das kommt in V2.
- **Fehlerbehandlung**: Wenn der ZIP-Write fehlschlägt (kein Speicher, kein
  Schreibrecht), gibt `SaveToFile()` `-1` zurück. Keine Exception, kein Crash.

### Abnahmekriterien

- [ ] `OdfDocument.Init(ODF_TYPE_TEXT)` + `SaveToFile("test.odt")` erzeugt
  eine Datei, die LibreOffice öffnet (leeres Dokument, keine Fehler)
- [ ] `manifest.xml` enthält Einträge für `content.xml`, `styles.xml`,
  `meta.xml` und `"/"` (Root) — aber **keinen** für `mimetype`
- [ ] `meta.xml` enthält `<meta:generator>lyxc 0.9.9A</meta:generator>`
- [ ] `SaveToFile()` gibt `-1` zurück wenn der Zielpfad nicht beschreibbar ist
  (Verzeichnis existiert nicht) — kein Crash
- [ ] `OdfDocument.Close()` gibt alle Puffer frei (kein Memory-Leak,
  prüfbar mit Valgrind oder internem Alloc-Tracker)

---

## OFF-04: ODT-Text-Writer — Absätze und Zeichenformatierung

### Info

Der Text-Writer baut auf `OdfDocument` auf und stellt eine einfache API
für `.odt`-Dokumente bereit:

```lyx
pub fn OdtAddParagraph(doc: OdfDocument, text: pchar)
pub fn OdtAddParagraphStyled(doc: OdfDocument, text: pchar, bold: int64, italic: int64)
pub fn OdtAddHeading(doc: OdfDocument, text: pchar, level: int64)  // H1..H6
pub fn OdtAddLineBreak(doc: OdfDocument)
pub fn OdtAddHorizontalRule(doc: OdfDocument)
```

**Intern generierte XML-Fragmente:**

Einfacher Absatz:
```xml
<text:p text:style-name="Standard">Hallo Welt</text:p>
```

Absatz mit Fettschrift via `text:span`:
```xml
<text:p text:style-name="Standard">
  <text:span text:style-name="as0">Fetter Text</text:span>
  normaler Text
</text:p>
```

Wobei `as0` ein auto-style in `<office:automatic-styles>` ist:
```xml
<style:style style:name="as0" style:family="text">
  <style:text-properties fo:font-weight="bold"/>
</style:style>
```

**Überschriften** nutzen vordefinierte Style-Namen aus `styles.xml`:
```xml
<text:h text:style-name="Heading_1" text:outline-level="1">Titel</text:h>
```
→ `styles.xml` muss `Heading_1`..`Heading_6` als Paragraph-Styles enthalten.

### Wichtige Hinweise

- **Kein `<b>` oder `<i>`** — ODF kennt das nicht. Formatierung läuft immer
  über `text:span` + Style-Referenz. Wer das vergisst, erzeugt scheinbar
  korrektes XML, das LibreOffice aber ignoriert.
- **Auto-Style-Deduplizierung**: Wenn der gleiche Bold+Italic-Style in einem
  Dokument 100× auftritt, sollte er nur **einmal** in `automatic-styles`
  stehen. Dafür einen einfachen Cache (Array aus `{bold, italic}` → Style-Name)
  einbauen.
- **XML-Escaping ist Pflicht**: Jeder Nutzer-String muss durch `odf_escape()`
  (OFF-02) laufen, bevor er in den XML-Buffer geschrieben wird.
- **Leerzeilen** zwischen Absätzen: In ODF ist eine Leerzeile ein leerer
  `<text:p>`, nicht ein `<br/>`. `OdtAddLineBreak()` emittiert:
  `<text:p text:style-name="Standard"/>`.
- **Heading-Styles** müssen in `styles.xml` als Skeleton vorhanden sein
  (OFF-02 erweitern). LibreOffice generiert sie normalerweise automatisch,
  aber für programmatisch erzeugte Dokumente müssen sie explizit deklariert
  sein.

### Abnahmekriterien

- [ ] `OdtAddParagraph(doc, "Hallo Welt")` → LibreOffice zeigt "Hallo Welt" im
  Standard-Stil
- [ ] `OdtAddParagraphStyled(doc, "Fett", 1, 0)` → Text erscheint fett in
  LibreOffice (nicht als normaler Text)
- [ ] `OdtAddParagraphStyled(doc, "BF", 1, 1)` → Text erscheint fett + kursiv
- [ ] `OdtAddHeading(doc, "Kapitel 1", 1)` → Heading-1-Style in LibreOffice
  korrekt gesetzt (Navigator zeigt Gliederung)
- [ ] Sonderzeichen-Test: `"Preis: 10 € & 20 < 30 >"` wird korrekt gerendert
  (kein `&amp;` sichtbar in LibreOffice, kein XML-Parse-Fehler)
- [ ] 1000 Absätze in einer Datei → keine Abstürze, Datei öffnet korrekt
- [ ] Auto-Style-Deduplizierung: Dokument mit 50× Bold → genau **1**
  `style:style`-Eintrag in `automatic-styles` (prüfbar mit `xmllint`)

---

## OFF-05: ODS-Tabellen-Writer — Zellen, Zeilen, Tabellenblätter

### Info

Der Tabellen-Writer ergänzt `OdfDocument` für `.ods`-Dokumente:

```lyx
pub fn OdsAddSheet(doc: OdfDocument, name: pchar)
pub fn OdsSetCell(doc: OdfDocument, row: int64, col: int64, text: pchar)
pub fn OdsSetCellInt(doc: OdfDocument, row: int64, col: int64, val: int64)
pub fn OdsSetCellFloat(doc: OdfDocument, row: int64, col: int64, val: int64, decimals: int64)
pub fn OdsFlushSheet(doc: OdfDocument)   // schließt aktuelle Tabelle
```

**Intern generiertes XML:**

```xml
<table:table table:name="Tabelle1">
  <table:table-row>
    <table:table-cell office:value-type="string">
      <text:p>Inhalt</text:p>
    </table:table-cell>
    <table:table-cell office:value-type="float" office:value="42">
      <text:p>42</text:p>
    </table:table-cell>
  </table:table-row>
</table:table>
```

Der `mimetype` für `.ods` ist:
`application/vnd.oasis.opendocument.spreadsheet`

Das Root-Element von `content.xml` ändert sich auf:
`<office:body><office:spreadsheet>...</office:spreadsheet></office:body>`

### Wichtige Hinweise

- **`office:value-type` und `office:value` sind Pflicht für Zahlen.** Ohne
  diese Attribute speichert LibreOffice die Zahl als Text — sie ist dann nicht
  summierbar. Die `<text:p>`-Darstellung ist nur für die Anzeige.
- **Zellen-Index ist 0-basiert intern, aber `col:row` im XML nicht.** Das
  interne API (`row`, `col`) ist 0-basiert; im XML gibt es keine expliziten
  Koordinaten — die Position ergibt sich aus der Reihenfolge der
  `table:table-row` und `table:table-cell`-Elemente.
- **Leere Zellen** müssen als `<table:table-cell/>` emittiert werden wenn
  zwischen zwei gefüllten Zellen eine Lücke liegt. Alternativ:
  `table:number-columns-repeated`-Attribut für kompaktere Ausgabe.
- **Mehrere Tabellenblätter**: `OdsAddSheet()` schließt das vorherige
  implizit. Jedes Sheet ist ein eigenes `<table:table>`-Element.
- **Float-Formatierung**: Dezimalzahlen müssen mit Punkt (`.`) als
  Dezimaltrennzeichen im `office:value`-Attribut stehen, unabhängig vom
  System-Locale.

### Abnahmekriterien

- [ ] `OdsSetCell(doc, 0, 0, "Name")` + `OdsSetCellInt(doc, 0, 1, 42)` →
  LibreOffice zeigt "Name" in A1 und `42` (als Zahl, nicht Text) in B1
- [ ] `SUM(B1:B100)` in LibreOffice liefert korrektes Ergebnis auf
  programmatisch erzeugten Zellen (beweist `office:value-type="float"`)
- [ ] Zwei Tabellenblätter `("Jan", "Feb")` → LibreOffice zeigt zwei Tabs
- [ ] Leere Zellen zwischen Werten werden korrekt übersprungen
  (Zelle A1 gefüllt, B1 leer, C1 gefüllt → C1 landet in Spalte C, nicht B)
- [ ] Float-Wert `3.14159` wird in LibreOffice als Zahl erkannt, nicht als
  Text (Zelle ist rechts-ausgerichtet und summierbar)
- [ ] 10.000 Zeilen × 10 Spalten → Datei öffnet in < 3 Sekunden in LibreOffice

---

## Offene Punkte V2 (außerhalb dieses Scope)

| ID | Thema |
|----|-------|
| OFF-06 | ODT-Reader: `.odt` einlesen und Text extrahieren |
| OFF-07 | Bilder einbetten (`draw:frame`, `draw:image`, Base64 oder Link) |
| OFF-08 | Kopf- und Fußzeilen (`style:header`, `style:footer`) |
| OFF-09 | ODT-Tabellen (Tabellen in Text-Dokumenten, nicht ODS) |
| OFF-10 | Kommentare / Anmerkungen (`office:annotation`) |
| OFF-11 | ODS-Formeln (`table:formula`-Attribut) |
