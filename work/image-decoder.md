# std/image — Grafik-Decoder-Bibliothek (GRF)

> **Ziel:** Native Lyx-Implementierungen zum Lesen und Schreiben gängiger Rastergrafikformate  
> **Namespace:** `std.image.*`  
> **Stand:** Planung  
> **Formats:** BMP · PNG · JPEG · GIF · TIFF · WebP · AVIF

---

## Architektur-Überblick

Alle Decoder schreiben in ein einheitliches **GrfImage**-Struct (kanonisches Format RGBA8).  
Jedes Format bekommt eine eigene Unit (`std.image.bmp`, `std.image.png`, …).  
`std.image.core` definiert das gemeinsame Struct-Layout und Hilfsfunktionen.

```
Datei auf Disk
     │
     ▼
FormatDecoder (std.image.xyz)
     │  GrfImageDecode(path) → GrfImage
     ▼
GrfImage (RGBA8, row-major, top-down)
     │
     ├─→ PdfImageEmbed / SvgAddImageRGB / eigene Ausgabe
     └─→ GrfImageFree()
```

### GrfImage-Struct-Layout (`std.image.core`)

```
GRF_OFF_WIDTH    := 0   // int64  — Breite in Pixeln
GRF_OFF_HEIGHT   := 8   // int64  — Höhe in Pixeln
GRF_OFF_CHANNELS := 16  // int64  — 1=Gray, 2=GrayA, 3=RGB, 4=RGBA
GRF_OFF_DEPTH    := 24  // int64  — Bits pro Kanal (8 oder 16)
GRF_OFF_FORMAT   := 32  // int64  — GRF_FMT_* Konstante
GRF_OFF_PIXELS   := 40  // int64  — Pointer auf Pixel-Buffer (immer RGBA8)
GRF_OFF_PIXLEN   := 48  // int64  — Byte-Länge des Pixel-Buffers
GRF_SIZE         := 56
```

Canonical Internal Format: **RGBA8** (4 Byte/Pixel, R, G, B, A, row-major, top-down).  
Grayscale-Input wird auf RGBA8 expandiert (R=G=B=Gray, A=255).

---

## Lyx-spezifische Constraints (für alle WPs)

| Constraint | Workaround |
|---|---|
| Max 6 Parameter | Context-Struct (GRF_CTX_SIZE-Pattern) verwenden |
| Kein `break` | Exit-Flag oder `i := count` als Loop-Abbruch |
| `type`/`value`/`match` reserviert | `fmt`/`val`/`depth` etc. als Variablenname |
| Negativer int64-con → 0 | Hex-Literal (0xFFFF…) oder Funktion |
| `pub con X: pchar` → Null-Ptr | Wrapper-Funktion `fn getX(): pchar { return "..."c; }` |
| DEFLATE-Bug in std/zlib | **Für Encoding**: `ZipWriterSaveStore` statt `ZipWriterSave` |
| INFLATE vorhanden | `InflateDEFLATE` / `ZlibDecompress` aus `std.zlib` — für Decode nutzbar |
| Division mit neg. Dividend | `0 - val` statt unärem Minus |

---

## Arbeitspakete

---

### GRF-00 · Core Image API
**Unit:** `std/image/core.lyx`  
**Abhängigkeiten:** `std.alloc`, `std.fs`

**Was zu implementieren ist:**
- GrfImage-Struct-Konstanten (`GRF_OFF_*`, `GRF_SIZE`)
- `GrfImageAlloc(w, h)` → alloziert RGBA8-Pixel-Buffer
- `GrfImageFree(img)` → gibt Pixel-Buffer und Struct frei
- `GrfImageGetPixel(img, x, y)` → int64 (0xRRGGBBAA)
- `GrfImageSetPixel(img, x, y, rgba)` → void
- `GrfImageClear(img, rgba)` → füllt gesamten Buffer
- Format-Konstanten: `GRF_FMT_BMP=1`, `GRF_FMT_PNG=2`, `GRF_FMT_JPEG=3`, `GRF_FMT_GIF=4`, `GRF_FMT_TIFF=5`, `GRF_FMT_WEBP=6`, `GRF_FMT_AVIF=7`
- `GrfFileRead(path, plen, outBuf, maxLen)` → Datei in Puffer laden
- `GrfDetectFormat(buf, len)` → GRF_FMT_* anhand Magic Bytes

**Magic Bytes (für GrfDetectFormat):**
```
BMP:  89 4D (BM)
PNG:  89 50 4E 47 0D 0A 1A 0A
JPEG: FF D8 FF
GIF:  47 49 46 38 (GIF8)
TIFF: 49 49 2A 00 (LE) oder 4D 4D 00 2A (BE)
WebP: 52 49 46 46 … 57 45 42 50 (RIFF….WEBP)
AVIF: ftyp-Box mit "avif"/"avis" ab Offset 4
```

**Abnahmekriterien:**
- [ ] `GrfImageAlloc(100, 100)` → PIXLEN == 40000, CHANNELS == 4
- [ ] `GrfImageSetPixel` + `GrfImageGetPixel` round-trip korrekt
- [ ] `GrfDetectFormat` erkennt alle 7 Formate anhand Testpuffer
- [ ] `GrfImageFree` gibt exakt so viel frei wie `GrfImageAlloc` alloziert hat

---

### GRF-01 · BMP Decoder
**Unit:** `std/image/bmp.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`  
**Komplexität:** Niedrig (einfachstes Format)

**Dateiformat-Überblick:**
```
Offset  Size  Feld
0       2     Signatur "BM"
2       4     Dateigröße
10      4     Pixel-Offset (wo Pixel-Daten beginnen)
14      4     Header-Größe (BITMAPINFOHEADER = 40)
18      4     Breite (signed)
22      4     Höhe (signed, negativ = top-down)
26      2     Planes (immer 1)
28      2     Bits per Pixel (1, 4, 8, 16, 24, 32)
30      4     Kompression (0=BI_RGB, 1=BI_RLE8, 2=BI_RLE4)
34      4     Bildgröße in Bytes
```

**Was zu implementieren ist:**
- `BmpDecode(buf, len, img)` → int64 (1=ok, 0=fehler)
- `BmpDecodeFile(path, plen, img)` → int64
- Unterstützte Farbtiefen: **24 bpp (RGB)** und **32 bpp (BGRA)**
- Row-Padding: Zeilen auf 4-Byte-Grenze padden (`rowBytes = (w * bpp + 31) / 32 * 4`)
- Bottom-up Rows: BMP speichert Standard bottom-up → beim Lesen umkehren
- Top-down wenn Höhe negativ: direkt verwenden
- `BmpEncode(img, outBuf, maxLen)` → int64 (geschriebene Bytes)

**Worauf achten:**
- `height` ist **signed**: negative Höhe = top-down, positive = bottom-up
- Padding pro Zeile muss korrekt berechnet werden (häufigster Fehler)
- 24-bpp BMP ist BGR, nicht RGB → beim Lesen R und B tauschen
- Kompression BI_RLE8/BI_RLE4 nur dokumentieren, nicht zwingend implementieren (optionale Erweiterung)

**Abnahmekriterien:**
- [ ] 24-bpp BMP 2×2 Pixel: korrekte RGB-Werte (auch BGR-Swap geprüft)
- [ ] 32-bpp BMP: Alpha-Kanal korrekt
- [ ] Bottom-up Rows: erste Zeile im Bild == letzte Zeile in Datei
- [ ] Zeilen-Padding: 1×1 Pixel 24bpp → rowBytes = 4 (nicht 3)
- [ ] `BmpEncode` → `BmpDecode` round-trip: alle Pixel identisch
- [ ] Datei nicht gefunden → return 0

---

### GRF-02 · PNG Decoder
**Unit:** `std/image/png.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`, `std.zlib`  
**Komplexität:** Mittel

**Dateiformat-Überblick:**
```
PNG Signatur: 89 50 4E 47 0D 0A 1A 0A (8 Byte)
Chunks: [length:4][type:4][data:length][crc32:4]
  IHDR  — Header (Pflicht, erster Chunk)
  PLTE  — Palette (für color type 3)
  IDAT  — Pixel-Daten (zlib-komprimiert, kann mehrere geben → concatenieren)
  IEND  — Ende-Marker (leerer Chunk)
  tRNS  — Transparenz
```

**IHDR (13 Byte):**
```
Width:             4 Byte
Height:            4 Byte
Bit depth:         1 Byte (1,2,4,8,16)
Color type:        1 Byte (0=Gray, 2=RGB, 3=Palette, 4=GrayA, 6=RGBA)
Compression:       1 Byte (immer 0)
Filter method:     1 Byte (immer 0)
Interlace method:  1 Byte (0=keine, 1=Adam7)
```

**PNG-Filter (pro Zeile vor DEFLATE):**
```
Filter 0 (None):    Recon(x) = Filt(x)
Filter 1 (Sub):     Recon(x) = Filt(x) + Recon(x-bpp)
Filter 2 (Up):      Recon(x) = Filt(x) + Prior(x)
Filter 3 (Average): Recon(x) = Filt(x) + floor((Recon(x-bpp) + Prior(x)) / 2)
Filter 4 (Paeth):   Recon(x) = Filt(x) + PaethPredictor(Recon(x-bpp), Prior(x), Prior(x-bpp))
```

**Was zu implementieren ist:**
- `PngDecode(buf, len, img)` → int64
- `PngDecodeFile(path, plen, img)` → int64
- Chunk-Parser (iteriert über alle Chunks)
- Alle IDAT-Chunks concatenieren → dann `ZlibDecompress` aufrufen
- Filter-Rekonstruktion für alle 5 Filter-Typen
- Unterstützte Color Types: 0 (Gray), 2 (RGB), 6 (RGBA) — Pflicht
- Color Type 3 (Palette + PLTE) — optional
- Bit Depth 8 — Pflicht; 16 → 8-bit reduzieren (High-Byte verwenden)
- `PngEncode(img, outBuf, maxLen)` → int64 (Store-only, kein DEFLATE wegen Bug → `ZipWriterSaveStore`)

**Worauf achten:**
- IDAT kann auf **mehrere Chunks verteilt** sein → alle Daten concatenieren
- Jede Zeile hat ein vorangestelltes **Filter-Byte** (wird nicht in Breite mitgezählt)
- Paeth-Predictor: Vergleich von `p-a`, `p-b`, `p-c` mit Absolutwerten
- `bpp` = bytes per pixel (color type 2 → 3, color type 6 → 4 usw.)
- CRC32 aus `std.zlib` ist vorhanden
- `ZlibDecompress` erwartet zlib-Header (CMF+FLG) — PNG IDAT hat diesen

**Abnahmekriterien:**
- [ ] 1×1 RGBA PNG: korrekter Pixelwert
- [ ] Filter 0–4: je ein Testfall pro Filter-Typ PASS
- [ ] RGB PNG 10×10 → korrekte Pixel-Matrix
- [ ] RGBA PNG: Alpha-Kanal korrekt durchgereicht
- [ ] 16-bit PNG → 8-bit Reduktion: High-Byte korrekt
- [ ] Kaputte Signatur → return 0
- [ ] `PngEncode` + `PngDecode` round-trip ohne Pixel-Verlust (store-only)

---

### GRF-03 · JPEG Decoder
**Unit:** `std/image/jpeg.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`  
**Komplexität:** Hoch (komplexestes Format)

**Dateiformat-Überblick:**
```
Marker-basiertes Format:  FF XX
  FF D8       — SOI (Start of Image)
  FF E0       — APP0 (JFIF)
  FF DB       — DQT  (Quantisierungstabelle)
  FF C0       — SOF0 (Baseline DCT)
  FF C4       — DHT  (Huffman-Tabelle)
  FF DA       — SOS  (Start of Scan — Pixel-Daten)
  FF D9       — EOI  (End of Image)
```

**Dekodier-Pipeline:**
```
Datei → Marker-Parser
      → DHT: Huffman-Tabellen aufbauen
      → DQT: Quantisierungstabellen laden
      → SOF0: Bild-Dimensionen, Komponenten
      → SOS: Entropy-Decoder → IDCT → YCbCr → RGB → RGBA8
```

**Was zu implementieren ist:**
- Phase 1 (Metadaten): `JpegMeta(buf, len, img)` → Breite/Höhe/Channels ausfüllen, keine Pixel
- Phase 2 (Vollständig): `JpegDecode(buf, len, img)` → vollständige Pixel-Dekodierung
  - Huffman-Decoder (AC + DC, Luma + Chroma)
  - Baseline DCT (8×8 Blöcke, Integer-IDCT)
  - Dequantisierung
  - YCbCr → RGB Konversion (BT.601)
  - Chroma-Upsampling (4:2:0, 4:2:2, 4:4:4)
- `JpegDecodeFile(path, plen, img)` → int64

**YCbCr → RGB (BT.601, Integer-Näherung):**
```
R = Y + 1.402 * (Cr - 128)
G = Y - 0.344 * (Cb - 128) - 0.714 * (Cr - 128)
B = Y + 1.772 * (Cb - 128)
Clamp zu [0, 255]
```

**Worauf achten:**
- Huffman-Tabellen können **mehrfach** (DHT vor SOS) vorkommen
- JPEG-Restart-Marker (FF D0–D7): ignorieren oder unterstützen
- Progressive JPEG (FF C2 statt FF C0) → erst in Phase 2 optional
- Chroma-Subsampling 4:2:0 ist der häufigste Fall → Pflicht
- 16-Bit-Integer-IDCT bevorzugen (kein `f64` wegen Performance)
- Zig-Zag-Reihenfolge der DCT-Koeffizienten beachten
- Kein `f64` in der IDCT-Kern-Schleife (Integer-Approximation verwenden)

**Abnahmekriterien:**
- [ ] `JpegMeta`: Breite/Höhe korrekt aus JFIF- und EXIF-JPEG extrahiert
- [ ] Baseline JPEG 8×8 Graustufen: korrekter Pixelwert (±3 Toleranz wegen Quantisierung)
- [ ] Baseline JPEG RGB 4:4:4: Pixel korrekt (±5 Toleranz)
- [ ] Baseline JPEG RGB 4:2:0: gängige Test-JPEG liest ohne Crash
- [ ] Kein Heap-Überlauf bei Malformed-Input (Größen-Prüfung vor alloc)
- [ ] Progressive JPEG → return 0 (nicht implementiert, sauber abweisen)
- [ ] `JpegDecodeFile` → `JpegMeta` stimmt mit vollständigem Decode überein

---

### GRF-04 · GIF Decoder
**Unit:** `std/image/gif.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`  
**Komplexität:** Mittel

**Dateiformat-Überblick:**
```
Header:            "GIF87a" oder "GIF89a" (6 Byte)
Logical Screen Descriptor: 7 Byte
  - Breite/Höhe
  - Global Color Table Flag + Size
Global Color Table: 3 * 2^(size+1) Byte (optional)
Blocks:
  Image Descriptor: 0x2C + 9 Byte (pro Frame)
  Local Color Table: optional pro Frame
  Image Data: LZW-komprimiert in Sub-Blöcken
  Extension Blocks: 0x21 + Typ
    Graphic Control Extension (0xF9): Delay, Transparenz
    Comment Extension (0xFE)
    Application Extension (0xFF): NETSCAPE für Looping
Trailer: 0x3B
```

**LZW-Decoder:**
- Initial code size aus Image Data (1 Byte)
- Sub-Blöcke: [count: 1][data: count] ... [0x00]
- Dictionary aufbauen (max 4096 Einträge, 12 Bit)
- Clear-Code = 2^initSize, EOI-Code = Clear-Code + 1

**Was zu implementieren ist:**
- `GifDecode(buf, len, img)` → erstes Frame dekodieren → RGBA8
- `GifDecodeFile(path, plen, img)` → int64
- `GifGetFrameCount(buf, len)` → int64 (Anzahl Frames)
- `GifDecodeFrame(buf, len, frameIdx, img)` → int64
- Transparenz via `tRNS`-Index aus Graphic Control Extension
- Interlaced GIF (Interlace-Flag) entflechten (4-Pass-Schema)

**Worauf achten:**
- LZW-Dictionary wächst dynamisch — Code-Breite erhöht sich wenn `dictSize == 2^codeBits`
- Sub-Block-Parsing: jeder Block hat ein Längen-Byte vorne (0x00 = Ende)
- Palette: 256 Einträge à 3 Byte (RGB, kein Alpha!) → Alpha aus Transparenz-Index
- Bei Animation: vorherige Frames für Disposal Method eventuell nötig (für Basis-Support ignorieren)
- Keine Lyx-`break` im LZW-Loop → Exit-Flag verwenden

**Abnahmekriterien:**
- [ ] 1×1 GIF89a: korrekter Farb-Wert
- [ ] Transparenz-Index: Pixel-Alpha == 0 für transparente Pixel
- [ ] LZW: Standard-Testbild mit bekannten Pixelwerten
- [ ] `GifGetFrameCount` == 1 für Einzelbild, > 1 für Animation
- [ ] Interlaced GIF: Pixel-Reihenfolge korrekt entflochten
- [ ] Kaputte LZW-Daten (Code > dictSize) → return 0, kein Crash

---

### GRF-05 · TIFF Reader
**Unit:** `std/image/tiff.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`, `std.zlib`  
**Komplexität:** Hoch (sehr flexibles Format)

**Dateiformat-Überblick:**
```
Header (8 Byte):
  [0-1]  Byte Order: "II" (LE=0x4949) oder "MM" (BE=0x4D4D)
  [2-3]  Magic: 42 (LE: 0x002A, BE: 0x2A00)
  [4-7]  Offset zu erstem IFD

IFD (Image File Directory):
  [0-1]  Anzahl Tags (uint16)
  Pro Tag: [tag:2][type:2][count:4][value_or_offset:4]
  [N]    Offset zum nächsten IFD (0 = Ende)
```

**Wichtige TIFF-Tags:**
```
256 (0x100)  ImageWidth
257 (0x101)  ImageLength (Höhe)
258 (0x102)  BitsPerSample
259 (0x103)  Compression (1=keine, 5=LZW, 6=JPEG, 8=Deflate, 32773=PackBits)
262 (0x106)  PhotometricInterpretation (1=BlackIsZero, 2=RGB, 3=Palette, 32803=CFA)
273 (0x111)  StripOffsets
278 (0x116)  RowsPerStrip
279 (0x117)  StripByteCounts
320 (0x140)  ColorMap (für Palette)
```

**Was zu implementieren ist:**
- `TiffDecode(buf, len, img)` → int64
- `TiffDecodeFile(path, plen, img)` → int64
- Byte-Order-Handling (LE und BE lesen)
- IFD-Parser (alle Pflicht-Tags auslesen)
- **Kompression 1 (None)**: Pflicht
- **Kompression 32773 (PackBits)**: Pflicht (häufig bei Mac-Exports)
- Kompression 5 (LZW) und 8 (Deflate): optional (via `ZlibDecompress`)
- Strip-basiertes Lesen (ggf. mehrere Strips zusammensetzen)
- PhotometricInterpretation 1 (Gray) und 2 (RGB): Pflicht

**Worauf achten:**
- **Byte-Order muss konsequent beachtet** werden — alle Reads je nach "II"/"MM" flippen
- Tag-Value: wenn count*typeSize ≤ 4 → direkt im value-Feld, sonst Offset
- Mehrere Strips: `StripOffsets[i]` + `StripByteCounts[i]` für Strip i
- 16-bit TIFF (BitsPerSample=16): High-Byte für RGBA8 verwenden
- PackBits: `[n: int8]` → n≥0: n+1 Bytes literal; n<0: 1-n mal nächstes Byte

**Abnahmekriterien:**
- [ ] Uncompressed RGB TIFF (LE): Pixel korrekt
- [ ] Uncompressed RGB TIFF (BE): Pixel korrekt (Byte-Order-Test)
- [ ] PackBits TIFF: korrekt dekomprimiert
- [ ] Graustufenbild (PhotometricInterpretation=1): R=G=B=Gray, A=255
- [ ] 16-bit TIFF → 8-bit RGBA: High-Byte korrekt
- [ ] Fehlende Pflicht-Tags → return 0 (nicht crashen)
- [ ] Multi-Strip-TIFF: alle Strips korrekt zusammengesetzt

---

### GRF-06 · WebP Decoder
**Unit:** `std/image/webp.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`, `std.zlib`  
**Komplexität:** Hoch

**Dateiformat-Überblick:**
```
RIFF-Container:
  "RIFF" [4] [fileSize-8: 4] "WEBP" [4]
  Chunks:
    VP8  — Lossy (VP8 Bitstream)
    VP8L — Lossless (VP8L Bitstream)
    VP8X — Extended (Flags + ICC + Alpha + EXIF + XMP)
    ALPH — Separate Alpha-Plane (für lossy mit Alpha)
    ANIM — Animation Header
    ANMF — Animation Frame
```

**VP8L (Lossless) — Pflicht-Implementierung:**
```
Signatur: 0x2F ('/')
Transform-Typen: Predictor, Color, Subtract Green, Color Indexing
Huffman-Coded ARGB-Werte (Prefix-Codes)
Backward-Referenzen (LZ77)
Color Cache
```

**Was zu implementieren ist:**
- `WebpMeta(buf, len, img)` → Breite/Höhe/Kanäle, keine Pixel
- `WebpDecodeLossless(buf, len, img)` → VP8L vollständig dekodieren
- `WebpDecodeFile(path, plen, img)` → int64 (VP8L-only für erste Version)
- VP8 (lossy) → `return 0` mit Fehler-Dokumentation (VP8 = reduzierter H.264, sehr komplex)

**VP8L-Decoder-Schritte:**
1. RIFF-Container parsen, VP8L-Chunk finden
2. Signatur-Byte (0x2F) prüfen
3. Breite/Höhe aus Bitstream lesen (14 Bit je, +1)
4. Transform-Flags auslesen (1 Bit, dann Transform-Typ)
5. Huffman-Gruppen dekodieren (Meta-Huffman-Codes)
6. Pixel-Stream: Literal (ARGB), Backward-Ref, Color-Cache
7. Transforms rückwärts anwenden (Subtract Green, Color, Predictor)

**Worauf achten:**
- VP8L liest **Bits LSB-first** aus dem Byte-Stream
- Transforms werden **rückwärts** angewendet (letzter Transform zuerst rückgängig machen)
- Color-Cache-Größe ist Potenz von 2 (2^bits)
- Predictor-Transform: 13 Prädiktor-Modi, ähnlich PNG-Filter aber komplexer
- Huffman-Codes: komplexe Längen-Kodierung (ähnlich DEFLATE aber mit Meta-Codes)
- RIFF chunk-Längen sind auf 2 Byte aufgerundet (padding)

**Abnahmekriterien:**
- [ ] `WebpMeta`: Breite/Höhe aus VP8L-WebP korrekt
- [ ] `WebpMeta`: Breite/Höhe aus VP8-WebP korrekt (keine Pixel-Decode nötig)
- [ ] VP8L 1×1 Pixel: korrekter RGBA-Wert
- [ ] VP8L ohne Transforms (einfachstes Encoding): korrekte Pixel
- [ ] VP8L mit Subtract-Green-Transform: korrekte Pixel
- [ ] VP8 (lossy) → return 0, kein Crash
- [ ] Malformed RIFF-Header → return 0

---

### GRF-07 · AVIF Decoder
**Unit:** `std/image/avif.lyx`  
**Abhängigkeiten:** `std.image.core`, `std.alloc`, `std.fs`  
**Komplexität:** Sehr hoch (AV1-Codec + ISOBMFF-Container)

**Dateiformat-Überblick:**
```
ISOBMFF-Container (ISO Base Media File Format):
  Boxes: [size:4][type:4][data:size-8]
    ftyp — File Type Box (major_brand: "avif" oder "avis")
    mdat — Media Data (komprimierte AV1-Frames)
    moov/meta/mdat-Struktur je nach Profil
    
AV1-Bitstream:
  OBU (Open Bitstream Units):
    Sequence Header OBU
    Frame Header OBU
    Tile Group OBU (eigentliche Pixel-Daten)
```

**Realistischer Scope:**
AVIF/AV1 ist einer der komplexesten Codecs (vergleichbar mit H.265). Eine vollständige native Implementierung ist > 10.000 Zeilen. **Daher zweistufiger Ansatz:**

**Phase 1 (GRF-07A) — Metadaten:**
- `AvifMeta(buf, len, img)` → Breite/Höhe/Tiefe/Farbraum aus ISOBMFF
- Box-Parser für `ftyp`, `ispe` (Image Spatial Extents), `colr` (Colour Information)
- `AvifDetect(buf, len)` → 1 wenn AVIF, sonst 0

**Phase 2 (GRF-07B) — Pixel-Decode (späterer Meilenstein):**
- AV1-Sequence-Header parsen
- Tile-basiertes Decoding (AV1 Intra-Frames)
- CDEF, Loop-Filter, Film-Grain
- YUV → RGB Konversion (BT.2020 für HDR, BT.709 für SDR)

**Was in GRF-07 (erste Version) zu implementieren ist:**
- Phase 1 vollständig
- Phase 2: Dokumentierter Stub mit `return 0`

**Worauf achten:**
- ISOBMFF-Boxes können verschachtelt sein (Container-Boxes)
- `ftyp` muss major_brand oder compatible_brands "avif" oder "avis" enthalten
- `ispe`-Box liegt in `meta/iprp/ipco` — Pfad durch mehrere Container
- Breite/Höhe in `ispe` sind uint32, Big-Endian
- AVIF kann HEIF-Container mit AV1 sein — Marker-Kompatibilität prüfen
- AV1-OBU-Parsing ist eigenständig sehr komplex

**Abnahmekriterien:**
- [ ] `AvifDetect`: erkennt AVIF an ftyp-Brand, gibt 0 für PNG/JPEG
- [ ] `AvifMeta`: Breite/Höhe aus ispe-Box korrekt (Test mit bekanntem AVIF)
- [ ] `AvifMeta`: return 0 bei fehlendem ispe
- [ ] `AvifDecode` (Stub): return 0 mit GRF_FMT_AVIF gesetzt
- [ ] Kein Crash bei beliebigem Binary-Input (Größen-Check vor alloc)

---

### GRF-08 · Unified Image API (Facade)
**Unit:** `std/image/image.lyx`  
**Abhängigkeiten:** alle GRF-00–07  
**Komplexität:** Niedrig

**Was zu implementieren ist:**
- `ImageDecode(path, plen, img)` → erkennt Format automatisch, delegiert
- `ImageDecodeFromMem(buf, len, img)` → gleiche Logik aus Puffer
- `ImageFree(img)` → delegiert an `GrfImageFree`
- `ImageGetWidth(img)` / `ImageGetHeight(img)` / `ImageGetChannels(img)`
- `ImagePixelAt(img, x, y)` → int64 (0xRRGGBBAA)

**Abnahmekriterien:**
- [ ] `ImageDecode` mit BMP-Datei → korrekte Pixel
- [ ] `ImageDecode` mit PNG-Datei → korrekte Pixel
- [ ] `ImageDecode` mit JPEG-Datei → Pixel ±5 Toleranz
- [ ] `ImageDecode` mit unbekanntem Format → return 0
- [ ] `ImageDecodeFromMem` äquivalent zu `ImageDecode` (gleiche Ergebnisse)

---

## Meilensteine

| Meilenstein | WPs | Liefert |
|---|---|---|
| **A — Lossless Basics** | GRF-00, GRF-01, GRF-02 | BMP + PNG vollständig, Core API |
| **B — JPEG + GIF** | GRF-03, GRF-04 | JPEG Baseline + GIF Animation |
| **C — TIFF + WebP** | GRF-05, GRF-06 | TIFF PackBits + WebP Lossless |
| **D — AVIF + Facade** | GRF-07, GRF-08 | AVIF Meta, Unified API |

---

## Test-Strategie

Jede Unit hat eine Testdatei `tests/grf0X_<format>_test.lyx` mit:
- Kompakte Inline-Testbilder (hex-kodiert als Byte-Arrays im Testcode)
- PASS/FAIL-Ausgabe je Prüfpunkt
- Exit-Code 1 = alle Tests bestanden (Lyx-Konvention)

Beispiel-Teststruktur:
```lyx
pub fn main(argc: int64, argv: pchar): int64 {
    var ok: int64 := 1;
    var img: int64 := alloc(GRF_SIZE);
    // ... Testbild in Buffer laden
    var ret: int64 := BmpDecode(buf, len, img);
    if (ret != 1) { PrintLn("FAIL: BmpDecode returned 0"c); ok := 0; }
    else { PrintLn("PASS: BmpDecode=1"c); }
    // ...
    if (ok != 0) { PrintLn("=== GRF-01: ALL PASS ==="c); }
    return ok;
}
```

---

## Datei-Übersicht (nach Implementierung)

```
std/image/
  core.lyx      — GrfImage-Struct, Pixel-Buffer, Format-Detection
  bmp.lyx       — BMP Decoder/Encoder
  png.lyx       — PNG Decoder/Encoder (store-only)
  jpeg.lyx      — JPEG Decoder (Baseline)
  gif.lyx       — GIF Decoder (LZW, Animation)
  tiff.lyx      — TIFF Decoder (None + PackBits)
  webp.lyx      — WebP Decoder (VP8L Lossless)
  avif.lyx      — AVIF Meta + Decode-Stub
  image.lyx     — Unified Facade API

tests/
  grf00_core_test.lyx
  grf01_bmp_test.lyx
  grf02_png_test.lyx
  grf03_jpeg_test.lyx
  grf04_gif_test.lyx
  grf05_tiff_test.lyx
  grf06_webp_test.lyx
  grf07_avif_test.lyx
  grf08_image_test.lyx
```
