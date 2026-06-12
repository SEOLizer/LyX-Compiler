# Audio Equalizer Unit — Planungsdokument

## Überblick

Eine neue Unit `std.audio.equalizer` mit Biquad-Filtern nach dem
**Audio EQ Cookbook** von Robert Bristow-Johnson (RBJ). Arbeitet auf rohen PCM-Puffern
(int16, little-endian, interleaved) im Speicher — der natürliche Einfügepunkt
zwischen `WAVReadData`/`MP3Decode` und `ALSAWrite`.

---

## Dateistruktur

```
lyx-compiler/usr/include/lyx/units/std/audio/
  ├─ alsa.lyx          (vorhanden)
  ├─ mpg123.lyx        (vorhanden)
  ├─ playback.lyx      (vorhanden)
  └─ equalizer.lyx     ← NEU (Phase A–C)
```

Unit-Deklaration: `unit std.audio.equalizer;`  
Import: `import std.audio;`

---

## Datenfluß

```
[WAVReadData / MP3Decode]
        │
        ▼  int16 PCM-Puffer (mmap)
[EQApply(buf, size, channels, sampleRate)]   ← std.audio.equalizer
        │
        ▼  int16 PCM-Puffer (in-place modifiziert)
[ALSAWriteGeneric / AudioPlayPCM]
```

---

## Mathematische Basis — Biquad-Filter (RBJ)

Ein Biquad-Filter zweiter Ordnung (Direct Form II Transposed):

```
y[n] = b0·x[n] + w1
w1   = b1·x[n] - a1·y[n] + w2
w2   = b2·x[n] - a2·y[n]
```

Koeffizienten (normiert auf a0=1):

| Filter-Typ  | Verwendung                  |
|-------------|-----------------------------|
| Low-Shelf   | Bass (Band 0)               |
| Peaking EQ  | Mittenbänder (Band 1–N-1)   |
| High-Shelf  | Höhen (letztes Band)        |

**Peaking-Filter (RBJ):**
```
A     = 10^(dBgain/40)
w0    = 2π · f0 / Fs
alpha = sin(w0) / (2·Q)

b0 =  1 + alpha·A      a0 =  1 + alpha/A
b1 = -2·cos(w0)        a1 = -2·cos(w0)
b2 =  1 - alpha·A      a2 =  1 - alpha/A
```

**Low-Shelf:**
```
b0 =  A·[(A+1) - (A-1)·cos(w0) + 2·√A·alpha]
b1 = 2A·[(A-1) - (A+1)·cos(w0)]
b2 =  A·[(A+1) - (A-1)·cos(w0) - 2·√A·alpha]
a0 =    [(A+1) + (A-1)·cos(w0) + 2·√A·alpha]
a1 =-2·[(A-1) + (A+1)·cos(w0)]
a2 =    [(A+1) + (A-1)·cos(w0) - 2·√A·alpha]
```

**High-Shelf:** analog, cos-Terme invertiert.

Alle Koeffizienten werden vor der Audio-Schleife berechnet.
Im Schleifenkörper nur 5 Multiplikationen + 4 Additionen pro Sample.

---

## Lyx-spezifische Voraussetzungen

| Funktion | Verfügbar als |
|----------|--------------|
| `sin(f64)` | `extern fn sin(x: float64): float64;` via libm (FFI, `ffi_parser.lyx:446`) |
| `cos(f64)` | `extern fn cos(x: float64): float64;` via libm (FFI, `ffi_parser.lyx:447`) |
| `sqrt(f64)` | Builtin `IRO_FSQRT` (SSE2 `sqrtsd`) — direkt verwendbar |
| `float64` | Voller Sprachtyp, f64-Arithmetik in IR vorhanden |
| PCM-Sample lesen | `(peek8(buf+off+1) << 8) \| peek8(buf+off)` → int16 sign-extend |
| PCM-Sample schreiben | `poke8(buf+off, val & 255); poke8(buf+off+1, (val>>8)&255)` |

> **Keine Heap-Allokation im Audio-Loop** — Filterstate wird in Struct-Feldern gehalten,
> nicht in separaten mmap-Calls.

---

## API-Design

```lyx
// Equalizer-Konstanten
pub con EQ_MAX_BANDS:   int64 := 10;
pub con EQ_CH_MAX:      int64 := 2;

pub con EQ_MODE_3BAND:  int64 := 3;
pub con EQ_MODE_5BAND:  int64 := 5;
pub con EQ_MODE_10BAND: int64 := 10;

// Presets
pub con EQ_PRESET_FLAT:      int64 := 0;
pub con EQ_PRESET_ROCK:      int64 := 1;
pub con EQ_PRESET_POP:       int64 := 2;
pub con EQ_PRESET_CLASSICAL: int64 := 3;
pub con EQ_PRESET_BASS_BOOST:int64 := 4;
pub con EQ_PRESET_PODCAST:   int64 := 5;

// Biquad-Filter (interner Typ)
pub type BiquadFilter = struct {
  b0: float64; b1: float64; b2: float64;
  a1: float64; a2: float64;
  // Zustandsspeicher getrennt pro Kanal (max 2)
  w1_0: float64; w2_0: float64;   // Kanal 0 (L)
  w1_1: float64; w2_1: float64;   // Kanal 1 (R)
};

// Haupt-Equalizer-Klasse
pub type Equalizer = class {
  bands:      int64;               // aktive Bandanzahl (3, 5 oder 10)
  filters:    BiquadFilter[10];    // statisches Array, kein Heap

  pub fn EQInit(mode: int64);
  pub fn EQSetGain(band: int64, gainDb: float64);
  pub fn EQPreset(preset: int64);
  pub fn EQApply(buf: int64, dataSize: int64, channels: int64, sampleRate: int64);
};

// High-Level-Integration (in std.audio.playback)
pub fn AudioPlayWAVEQ(handle: int64, path: pchar, eq: Equalizer): int64;
pub fn AudioPlayMP3EQ(handle: int64, path: pchar, eq: Equalizer): int64;
```

---

## Preset-Tabellen (Gain in dB)

Bandmitten für 10-Band-EQ: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz

| Preset      | 32Hz | 64Hz | 125Hz | 250Hz | 500Hz | 1kHz | 2kHz | 4kHz | 8kHz | 16kHz |
|-------------|------|------|-------|-------|-------|------|------|------|------|-------|
| Flat        |  0   |  0   |   0   |   0   |   0   |   0  |   0  |   0  |   0  |   0   |
| Rock        | +5   | +4   |  +3   |  +1   |  -1   |  -1  |  +1  |  +3  |  +4  |  +4   |
| Pop         |  0   | +1   |  +2   |  +3   |  +2   |   0  |  -1  |  -1  |   0  |  +1   |
| Classical   |  0   |  0   |   0   |  +2   |  +3   |  +2  |  +1  |   0  |   0  |   0   |
| Bass-Boost  | +8   | +7   |  +5   |  +2   |   0   |   0  |   0  |   0  |   0  |   0   |
| Podcast     | -3   | -2   |   0   |  +2   |  +4   |  +5  |  +4  |  +2  |   0  |  -2   |

---

## Clipping-Schutz

Strategien (in dieser Reihenfolge implementieren):

1. **Hard-Clip** (Phase A): Clamping auf `-32768 .. 32767` nach der Biquad-Kette.
   Einfachste Variante, kein Overhead.
2. **Pre-Gain** (Phase B): Vor der Schleife `masterGain`-Faktor berechnen —
   wenn ein Band >= +6dB gesetzt ist, Gesamtlautstärke automatisch um denselben
   Betrag absenken.
3. **Soft-Limiter** (Phase C, optional): Tanh-Sättigung statt hartem Clip.

---

## Kanaltrennung

Jeder `BiquadFilter` hält **pro Kanal** separate State-Felder (`w1_0/w2_0` für L,
`w1_1/w2_1` für R). Die Schleife in `EQApply` iteriert über Frames:

```
frame = 0..totalFrames-1
  ch = 0..channels-1
    offset = (frame * channels + ch) * 2
    sample  ← peek16(buf + offset)          // int16 → f64
    sample  ← BiquadProcess(filter, sample, ch)
    ...kette alle Bänder durch...
    clamp   → poke16(buf + offset, result)  // f64 → int16
```

---

## Arbeits­pakete

### WP-EQ-01 — BiquadFilter: Struct + Koeffizienten­berechnung
**Phase:** A  
**Dateien:** `std/audio/equalizer.lyx`

- `BiquadFilter`-Struct deklarieren (b0–b2, a1–a2, 4× State)
- `extern fn sin/cos` deklarieren
- `BiquadSetPeaking(f: BiquadFilter, f0: float64, gainDb: float64, Q: float64, Fs: float64)`
- `BiquadSetLowShelf(f: BiquadFilter, f0: float64, gainDb: float64, Fs: float64)`
- `BiquadSetHighShelf(f: BiquadFilter, f0: float64, gainDb: float64, Fs: float64)`
- `BiquadProcess(f: BiquadFilter, x: float64, ch: int64): float64`
- `BiquadReset(f: BiquadFilter)` — State auf 0 setzen

Referenz: RBJ Audio EQ Cookbook, Section "Peaking EQ" + "Shelving EQ"

---

### WP-EQ-02 — Equalizer-Klasse + 3-Band-Modus
**Phase:** A  
**Dateien:** `std/audio/equalizer.lyx`  
**Abhängigkeit:** WP-EQ-01

- `Equalizer`-Klasse mit statischem `BiquadFilter[10]`-Array
- `EQInit(mode)` — Bandanzahl setzen, Frequenzen zuweisen, Gain=0dB initialisieren
- `EQSetGain(band, gainDb)` — Koeffizienten neu berechnen für dieses Band
- `EQReset()` — alle States zurücksetzen (nötig bei neuem Track)
- 3-Band-Belegung:  
  - Band 0: Low-Shelf  @ 200 Hz  
  - Band 1: Peaking    @ 1000 Hz, Q=1.0  
  - Band 2: High-Shelf @ 5000 Hz

---

### WP-EQ-03 — EQApply: PCM-Puffer-Verarbeitung
**Phase:** A  
**Dateien:** `std/audio/equalizer.lyx`  
**Abhängigkeit:** WP-EQ-02

- `EQApply(buf, dataSize, channels, sampleRate)`:
  - int16 Sample lesen: `peek8` × 2, sign-extend
  - float64-Konvertierung: `sample_f64 = (f64)s / 32768.0`
  - Alle aktiven Bänder sequenziell durchlaufen
  - Clamp auf -32768..32767 (Hard-Clip)
  - int16 zurückschreiben
- Keine Allokation innerhalb der Schleife
- Randbedingung: `dataSize` muss gerade sein (assert: `dataSize & 1 == 0`)

---

### WP-EQ-04 — 5-Band und 10-Band grafischer EQ
**Phase:** B  
**Dateien:** `std/audio/equalizer.lyx`  
**Abhängigkeit:** WP-EQ-03

- `EQInit` für `EQ_MODE_5BAND` und `EQ_MODE_10BAND`
- 5-Band: Low-Shelf @ 100Hz, Peaking @ 400/1k/3.5kHz, High-Shelf @ 10kHz
- 10-Band: Bandmitten 32/64/125/250/500/1k/2k/4k/8k/16k Hz, Q=1.4
- Alle Peaking-Filter, außer Band 0 (Low-Shelf) und Band 9 (High-Shelf)
- `EQSetSampleRate(sr)` — Koeffizienten bei Samplerate-Wechsel neu berechnen

---

### WP-EQ-05 — Preset-System
**Phase:** B  
**Dateien:** `std/audio/equalizer.lyx`  
**Abhängigkeit:** WP-EQ-04

- `EQPreset(preset)`:
  - Statische Gain-Tabellen als `con`-Arrays (keine Heap-Allokation)
  - Iteriert über Bänder und ruft `EQSetGain` auf
- Presets: Flat, Rock, Pop, Classical, Bass-Boost, Podcast (siehe Tabelle oben)
- `EQPresetName(preset): pchar` — Name als String zurückgeben

---

### WP-EQ-06 — Pre-Gain & Clipping-Schutz
**Phase:** B  
**Dateien:** `std/audio/equalizer.lyx`  
**Abhängigkeit:** WP-EQ-05

- `EQComputePreGain(): float64`:
  - Höchsten positiven Gain über alle aktiven Bänder ermitteln
  - Wenn > 0 dB: `preGain = 1.0 / (10^(maxGain/20))`
  - Sonst: `preGain = 1.0`
- Pre-Gain wird in `EQApply` als erster Schritt auf jedes Sample angewandt
- `masterGain: float64` als Feld in `Equalizer` (Standard: 1.0, durch User setzbar)

---

### WP-EQ-07 — Integration in `std.audio.playback`
**Phase:** C  
**Dateien:** `std/audio/playback.lyx`  
**Abhängigkeit:** WP-EQ-03

- `AudioPlayWAVEQ(handle, path, eq: Equalizer): int64`:
  - WAV parsen → Puffer laden → `EQApply` → `ALSAWriteGeneric`
  - Puffer nach Wiedergabe freigeben
- `AudioPlayMP3EQ(handle, path, eq: Equalizer): int64`:
  - Vollständiges PCM-Decode zu Zwischenpuffer (via `MP3Decode`-Loop)
  - Dann `EQApply` auf Gesamtpuffer
  - An ALSA übergeben
  - Hinweis: für lange Tracks hoher RAM-Bedarf; streaming-Variante als WP-EQ-08

---

### WP-EQ-08 — Streaming-EQ (optionale Erweiterung)
**Phase:** D (zukünftig)  
**Dateien:** `std/audio/playback.lyx`, `std/audio/equalizer.lyx`

- EQ chunk-weise auf MP3-Decode-Loop anwenden (kein Gesamtpuffer)
- Ermöglicht EQ für sehr lange Dateien ohne hohen RAM-Bedarf
- State-Reset zwischen Chunks: NICHT — der Filterzustand muss über Chunks erhalten bleiben

---

## Abhängigkeitsreihenfolge

```
WP-EQ-01
    └── WP-EQ-02
            └── WP-EQ-03
                    ├── WP-EQ-04
                    │       └── WP-EQ-05
                    │               └── WP-EQ-06
                    └── WP-EQ-07
WP-EQ-08  (unabhängig, Phase D)
```

Empfohlene Reihenfolge: **01 → 02 → 03 → 04 → 05 → 06 → 07 → (08)**

---

## Offene Fragen

- Soll `AudioPlayMP3EQ` erst nach vollständigem PCM-Decode arbeiten (einfacher, mehr RAM)
  oder streaming-fähig sein (WP-EQ-08)?
- Q-Faktor der Peaking-Filter: fester Wert `1.4` oder per `EQSetQ(band, q)` einstellbar
  (parametrischer EQ als spätere Erweiterung)?
- Soll ein `@version`-Attribut in der Unit den EQ-API-Stand kennzeichnen (im Hinblick
  auf LYU-Format v3, siehe `work/lyu-format-v3.md`)?
