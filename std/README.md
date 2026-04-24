Standard Units (std)
=====================

This directory contains standardized units serving as a comprehensive library for Lyx programs. The libraries combine native builtin functions with ergonomic wrapper functions and extended utilities.

## Overview of Available Units

| Unit | Description |
|------|-------------|
| `std/math` | Integer math, fixed-point, trigonometry |
| `std/vector` | Vec2 2D vector, rotation, normalization |
| `std/vector_batch` | Batch processing for Vec2 arrays |
| `std/rect` | Rect bounding box, area calculation |
| `std/circle` | Circle/Range for circumference searches |
| `std/color` | RGBA colors, HSL, hex conversion |
| `std/list` | Dynamic lists, RingBuffer, Stack, Queue |
| `std/result` | Result/Option pattern for error handling |
| `std/conv` | Integer formatting, bit manipulation, endianness |
| `std/hash` | FNV-1a, DJB2, CRC32, SHA-256 (simplified), password hashing |
| `std/string` | String manipulation and search |
| `std/io` | Print/Printf, formatting |
| `std/env` | Command-line arguments |
| `std/time` | Date/time, calendar functions |
| `std/datetime` | Extended date/time operations |
| `std/geo` | Geolocation, coordinates, distances |
| `std/country` | Country codes (ISO 3166-1), country names |
| `std/crt` | ANSI terminal control |
| `std/crt_raw` | Raw-mode input (experimental) |
| `std/pack` | Binary serialization |
| `std/regex` | Regex matching |
| `std/fs` | File system operations, path functions |
| `std/process` | Process management (fork/exec/wait) |
| `std/json` | JSON parser and serializer |
| `std/alloc` | Explicit memory management (malloc/free, pool) |
| `std/sort` | Efficient sorting algorithms (QuickSort) |
| `std/base64` | Base64 encoding and decoding |
| `std/buffer` | Buffer utilities (Hex, Base64 helpers) |
| `std/zlib` | DEFLATE/zlib compression (stored blocks, Adler-32) |
| `std/url` | URL parser and builder |
| `std/uuid` | UUID generation (v4, v7) and parsing |
| `std/html` | HTML escaping, unescaping, tag utilities |
| `std/xml` | XML parser and generator |
| `std/yaml` | YAML parser and generator |
| `std/ini` | INI file parser and writer |
| `std/os` | OS-level functions, system calls |
| `std/system` | System information |
| `std/systeminfo` | System information (CPU, memory, load, uptime, process stats) |
| `std/log` | Logging framework |
| `std/stats` | Statistical functions |
| `std/stats_batch` | Batch processing for statistics |
| `std/math_batch` | Batch processing for math |
| `std/thread` | Multi-threading (pthread, mutex, cond, TLS, atomic) |
| `std/net.ldap` | LDAP client (RFC 4511) |
| `std/net.mongo` | MongoDB client |
| `std/audio` | Audio playback and MP3/WAV processing |
| `std/audio.mpg123` | MP3 decoding via libmpg123 |
| `std/audio.alsa` | ALSA audio playback (Linux) |
| `std/audio.playback` | High-level audio playback interface |
| `std/qbool` | Quotient Boolean (ternary logic) |
| `std/error` | Error code management |

| `std/qt5_core` | Qt5 Core types, constants, application wrapper |
| `std/qt5_gl` | OpenGL 2.1 FFI bindings (gl*, shaders, textures) |
| `std/qt5_egl` | EGL 1.4 FFI bindings (Wayland/DRM OpenGL context) |
| `std/qt5_glx` | GLX 1.4 FFI bindings (X11 OpenGL context) |
| `std/x11` | X11 Window system FFI bindings (display, window, events) |

---

## Namespace Convention

After `import std.math;`, all functions are imported **globally** and can be called directly:

```lyx
import std.math;

var x: int64 := Abs64(-42);  // Not: math.Abs64()
var y: int64 := Min64(1, 2);
```

**Attention:** In case of name conflicts (e.g., `std.list` and `std.string` both have `Length()`), the last imported namespace wins. To avoid conflicts:

1. **Mind the order** - Sort imports by priority
2. **Direct import** - Import only needed functions (if supported)
3. **Avoid** - Don't mix multiple units with the same function names

## std/audio.lyx

### Audio Units Overview

The `std.audio` module provides complete audio playback and processing capabilities:

| Unit | Description |
|------|-------------|
| `std.audio` | Main audio module with WAV file handling |
| `std.audio.mpg123` | MP3 decoding via libmpg123 |
| `std.audio.alsa` | ALSA audio playback (Linux) |
| `std.audio.playback` | High-level audio playback interface |

### Features

- **MP3 Decoding**: Read and decode MP3 files using libmpg123
- **WAV Processing**: Parse and create WAV audio files
- **ALSA Playback**: Play audio directly via Linux ALSA (Advanced Linux Sound Architecture)
- **Format Support**: 48000 Hz, stereo, 16-bit PCM

### Usage Example

```lyx
import std.audio;
import std.audio.mpg123;
import std.audio.alsa;

// Decode MP3
mpg123_init();
var handle := mpg123_new(0, 0);
mpg123_open(handle, "music.mp3");

// Get format (48000 Hz, stereo)
var ratePtr := mmap(0, 8, 3, 34, -1, 0);
var chanPtr := mmap(0, 8, 3, 34, -1, 0);
mpg123_getformat(handle, ratePtr, chanPtr, 0);

// Decode audio data
var buf := mmap(0, 10000000, 3, 34, -1, 0);
var donePtr := mmap(0, 8, 3, 34, -1, 0);
mpg123_read(handle, buf, 262144, donePtr);

// Play via ALSA
var hp := mmap(0, 8, 3, 34, -1, 0);
snd_pcm_open(hp, "hw:0", 0, 0);
// ... set params and play
```

### ALSA Functions

- `snd_pcm_open(handlePtr, device, stream, mode): int64` - Open PCM device
- `snd_pcm_close(handle): int64` - Close PCM device
- `snd_pcm_hw_params_malloc(paramsPtr): int64` - Allocate params
- `snd_pcm_hw_params_set_format(handle, params, format): int64` - Set format (S16_LE)
- `snd_pcm_hw_params_set_rate_near(handle, params, rate, dir): int64` - Set sample rate
- `snd_pcm_hw_params_set_channels(handle, params, channels): int64` - Set channels
- `snd_pcm_hw_params(handle, params): int64` - Apply params
- `snd_pcm_writei(handle, buffer, frames): int64` - Write interleaved audio
- `snd_pcm_drain(handle): int64` - Drain playback

### MP3 Functions

- `mpg123_init(): int64` - Initialize library
- `mpg123_exit(): void` - Exit library
- `mpg123_new(decoder, err): int64` - Create handle
- `mpg123_delete(handle): void` - Delete handle
- `mpg123_open(handle, path): int64` - Open MP3 file
- `mpg123_close(handle): int64` - Close MP3 file
- `mpg123_getformat(handle, rate, channels, encoding): int64` - Get audio format
- `mpg123_read(handle, buffer, bufSize, done): int64` - Decode audio

### WAV Functions

- `WAVSaveFile(path, buffer, dataSize, sampleRate, channels, bitsPerSample): int64` - Save as WAV
- `WAVParseHeader(path): AudioInfo` - Parse WAV file header

## std/math.lyx

### Basic Integer Math
- `Abs64(x: int64): int64` - Absolute value
- `Min64(a, b: int64): int64` - Minimum
- `Max64(a, b: int64): int64` - Maximum
- `Div64(a, b: int64): int64` - Integer division
- `Mod64(a, b: int64): int64` - Modulo
- `TimesTwo(x: int64): int64` - Double
- `Min3(a, b, c: int64): int64` - Minimum of 3 values
- `Max3(a, b, c: int64): int64` - Maximum of 3 values

### Random Numbers
- `RandomRange(max: int64): int64` - Random number [0, max)
- `RandomBetween(min, max: int64): int64` - Random number [min, max]

**Native Builtins** (no import needed):
- `Random(): int64` - Pseudo-random number (0..2³¹-1)
- `RandomSeed(seed: int64): void` - Set seed for LCG

### Extended Integer Math
- `Sqrt64(n: int64): int64` - Integer square root (Newton's method)
- `IntSqrt(n: int64): int64` - Alias for Sqrt64
- `Clamp64(val, min, max: int64): int64` - Clamp value
- `Sign64(x: int64): int64` - Sign (-1, 0, 1)
- `Pow64(base, exp: int64): int64` - Power (base^exp)
- `InRange64(val, min, max: int64): bool` - Check range membership
- `Round64(x: int64): int64` - Rounding
- `Atan2Microdegrees(y, x: int64): int64` - Atan2 in microdegrees
- `Cos64Inverse(cos_value: int64): int64` - Inverse cosine

### Fixed-Point & Interpolation
- `Lerp64(a, b, t_permille: int64): int64` - Linear interpolation (t: 0-1000)
- `Map64(val, in_min, in_max, out_min, out_max: int64): int64` - Rescale value
- `Hypot64(x, y: int64): int64` - √(x² + y²) with overflow protection

### Fixed-Point Trigonometry
- `Sin64(degrees: int64): int64` - Sine (microdegrees)
- `Cos64(degrees: int64): int64` - Cosine (microdegrees)

### Bit Manipulation
- `IsEven(x: int64): bool` - Even number?
- `IsOdd(x: int64): bool` - Odd number?
- `NextPowerOfTwo(x: int64): int64` - Next power of two
- `IsPowerOfTwo(x: int64): bool` - Is power of two?
- `PopCount(x: int64): int64` - Number of set bits
- `Log2(x: int64): int64` - Logarithm base 2
- `Atan2Microdegrees(y, x: int64): int64` - Atan2 in microdegrees
- `Cos64Inverse(cos_value: int64): int64` - Inverse cosine

---

## std/conv.lyx

Conversion & Bit-Manipulation utilities.

### Integer to String
- `IntToStr(n: int64): pchar` - Decimal string
- `IntToHex(val, digits: int64): pchar` - Hex string (1-16 digits)
- `IntToHex8/16/32/64(val: int64): pchar` - Hex with fixed width
- `IntToBin(val, bits: int64): pchar` - Binary string
- `IntToBin8/16/32/64(val: int64): pchar` - Binary with fixed width
- `IntToOct(val, digits: int64): pchar` - Octal string
- `IntToStrWithComma(n: int64): pchar` - With thousands separator
- `IntToStrWithUnderscore(n: int64): pchar` - With underscore

### String to Integer
- `ParseHex(s: pchar): int64` - Hex string to int64
- `ParseBin(s: pchar): int64` - Binary string to int64
- `ParseOct(s: pchar): int64` - Octal string to int64

### Bit Manipulation
- `GetBit(val, bit_pos: int64): bool` - Read bit
- `SetBit(val, bit_pos: int64): int64` - Set bit to 1
- `ClearBit(val, bit_pos: int64): int64` - Set bit to 0
- `ToggleBit(val, bit_pos: int64): int64` - Invert bit
- `ExtractBits(val, start, count: int64): int64` - Extract bits
- `InsertBits(val, bits, start, count: int64): int64` - Insert bits

### Bit Counting
- `CountLeadingZeros(val: int64): int64` - Leading zeros
- `CountTrailingZeros(val: int64): int64` - Trailing zeros

### Endianness
- `SwapEndian16(val: int64): int64` - 16-bit byte order swap
- `SwapEndian32(val: int64): int64` - 32-bit byte order swap
- `SwapEndian64(val: int64): int64` - 64-bit byte order swap

### Byte Operations
- `GetByte(val, byte_pos: int64): int64` - Read single byte
- `SetByte(val, byte_pos, byte_val: int64): int64` - Write single byte

### Bit Rotation
- `RotateLeft32(val, n: int64): int64` - Rotate left (32-bit)
- `RotateRight32(val, n: int64): int64` - Rotate right (32-bit)

### Sign Extension
- `SignExtend8(val: int64): int64` - 8-bit sign extend
- `SignExtend16(val: int64): int64` - 16-bit sign extend
- `SignExtend32(val: int64): int64` - 32-bit sign extend

### Zero Extension
- `ZeroExtend8(val: int64): int64` - 8-bit zero extend
- `ZeroExtend16(val: int64): int64` - 16-bit zero extend
- `ZeroExtend32(val: int64): int64` - 32-bit zero extend

### Alignment
- `AlignDown(addr, alignment: int64): int64` - Align down
- `AlignUp(addr, alignment: int64): int64` - Align up
- `IsAligned(addr, alignment: int64): bool` - Check if aligned

---

## std/vector.lyx

2D vector library with Vec2 struct.

### Vec2 Struct
```lyx
struct Vec2 {
  x: int64,
  y: int64
}
```

### Constructors
- `Vec2New(x, y: int64): Vec2` - From coordinates
- `Vec2Zero(): Vec2` - Zero vector (0, 0)
- `Vec2FromScalar(v: int64): Vec2` - From scalar (v, v)

### Arithmetic
- `Vec2Add(a, b: Vec2): Vec2` - Vector addition
- `Vec2Sub(a, b: Vec2): Vec2` - Vector subtraction
- `Vec2Mul(v: Vec2, scalar: int64): Vec2` - Scalar multiplication
- `Vec2Div(v: Vec2, scalar: int64): Vec2` - Scalar division
- `Vec2Negate(v: Vec2): Vec2` - Negation

### Vector Operations
- `Vec2Dot(a, b: Vec2): int64` - Dot product
- `Vec2Cross(a, b: Vec2): int64` - Cross product (2D)
- `Vec2LengthSquared(v: Vec2): int64` - Length²
- `Vec2Length(v: Vec2): int64` - Length
- `Vec2DistanceSquared(a, b: Vec2): int64` - Distance²
- `Vec2Distance(a, b: Vec2): int64` - Distance
- `Vec2Normalize(v: Vec2): Vec2` - Normalize (to 1.0)
- `Vec2NormalizeSafe(v, fallback: Vec2): Vec2` - Safe normalize

### Interpolation
- `Vec2Lerp(a, b: Vec2, t: int64): Vec2` - Linear interpolation (t: 0-1000000)
- `Vec2Clamp(v, min, max: Vec2): Vec2` - Clamp

### Rotation
- `Vec2Rotate(v: Vec2, angle_deg: int64): Vec2` - Rotation (microdegrees)
- `Vec2Rotate90(v: Vec2): Vec2` - 90° counter-clockwise
- `Vec2Rotate180(v: Vec2): Vec2` - 180° rotation
- `Vec2Rotate270(v: Vec2): Vec2` - 270° rotation

### Comparison
- `Vec2Equal(a, b: Vec2): bool` - Equality
- `Vec2NotEqual(a, b: Vec2): bool` - Inequality
- `Vec2IsZero(v: Vec2): bool` - Zero vector?

### Min/Max
- `Vec2Min(a, b: Vec2): Vec2` - Component-wise minimum
- `Vec2Max(a, b: Vec2): Vec2` - Component-wise maximum
- `Vec2Abs(v: Vec2): Vec2` - Component-wise absolute value
- `Vec2Sign(v: Vec2): Vec2` - Component-wise sign

### Projection
- `Vec2Perpendicular(v: Vec2): Vec2` - Perpendicular vector
- `Vec2Project(v, onto: Vec2): Vec2` - Projection onto vector
- `Vec2Reflect(v, normal: Vec2): Vec2` - Reflection at normal

### Angles
- `Vec2AngleTo(v, target: Vec2): int64` - Angle to target (microdegrees)
- `Vec2Heading(v: Vec2): int64` - Angle from X-axis (microdegrees)

---

## std/rect.lyx

Rectangle and bounding box utilities.

### Rect Struct
```lyx
struct Rect {
  min: Vec2,  // Minimum (top-left)
  max: Vec2   // Maximum (bottom-right)
}
```

### Constructors
- `RectNew(min, max: Vec2): Rect` - From min/max
- `RectFromPoints(p1, p2: Vec2): Rect` - From two points
- `RectFromCenterSize(center, size: Vec2): Rect` - From center and size
- `RectEmpty(): Rect` - Empty rectangle
- `RectFromXYWH(x, y, w, h: int64): Rect` - From x,y,width,height

### Properties
- `RectWidth(r: Rect): int64` - Width
- `RectHeight(r: Rect): int64` - Height
- `RectSize(r: Rect): Vec2` - Size as Vec2
- `RectCenter(r: Rect): Vec2` - Center
- `RectArea(r: Rect): int64` - Area
- `RectIsEmpty(r: Rect): bool` - Empty?
- `RectIsValid(r: Rect): bool` - Valid?

### Point Tests
- `RectContains(r: Rect, p: Vec2): bool` - Contains point (incl. border)
- `RectContainsInclusive(r: Rect, p: Vec2): bool` - Contains point (excl. border)

### Rectangle Operations
- `RectInflate(r: Rect, amount: int64): Rect` - Inflate
- `RectDeflate(r: Rect, amount: int64): Rect` - Deflate
- `RectExpand(r: Rect, p: Vec2): Rect` - Expand with point
- `RectUnion(a, b: Rect): Rect` - Union
- `RectIntersect(a, b: Rect): Rect` - Intersection
- `RectIntersects(a, b: Rect): bool` - Overlaps?

### Corners
- `RectTopLeft(r: Rect): Vec2` - Top left
- `RectTopRight(r: Rect): Vec2` - Top right
- `RectBottomLeft(r: Rect): Vec2` - Bottom left
- `RectBottomRight(r: Rect): Vec2` - Bottom right

### Sides
- `RectLeft(r: Rect): int64`, `RectRight`, `RectTop`, `RectBottom`

---

## std/circle.lyx

Circle, Range and 2D Range utilities.

### Circle Struct
```lyx
struct Circle {
  center: Vec2,
  radius: int64
}
```

### Circle Constructors
- `CircleNew(center: Vec2, radius: int64): Circle`
- `CircleFromXYR(x, y, r: int64): Circle`
- `CircleFromPoints(p1, p2: Vec2): Circle` - From two points
- `CircleUnit(): Circle` - Unit circle

### Circle Properties
- `CircleDiameter(c: Circle): int64` - Diameter
- `CircleArea(c: Circle): int64` - Area (πr²)
- `CircleCircumference(c: Circle): int64` - Circumference (2πr)

### Circle Tests
- `CircleContainsPoint(c: Circle, p: Vec2): bool` - Contains point?
- `CircleContainsCircle(c, inner: Circle): bool` - Contains circle?
- `CircleIntersectsCircle(a, b: Circle): bool` - Circles intersect?
- `CircleIntersectsRect(c: Circle, r: Rect): bool` - Circle-rectangle?

### Range (1D Interval)
```lyx
struct Range {
  min: int64,
  max: int64
}
```

### Range Functions
- `RangeNew(min, max: int64): Range` - Create range
- `RangeFromValue(value, delta: int64): Range` - From value ± delta
- `RangeLength(r: Range): int64` - Length
- `RangeContains(r: Range, value: int64): bool` - Contains value?
- `RangeIntersects(r, other: Range): bool` - Overlaps?

### Range2D (2D Bounding Box)
- `Range2DNew(x, y: Range): Range2D`
- `Range2DFromPoints(p1, p2: Vec2): Range2D`
- `Range2DToRect(r2d: Range2D): Rect`

---

## std/color.lyx

RGBA colors for visualization.

### Color Struct
```lyx
struct Color {
  r: int64,  // 0-255
  g: int64,  // 0-255
  b: int64,  // 0-255
  a: int64   // 0-255 (255 = opaque)
}
```

### Constructors
- `ColorNew(r, g, b, a: int64): Color` - RGBA
- `ColorRGB(r, g, b: int64): Color` - RGB (alpha = 255)
- `ColorRGBA(r, g, b, a: int64): Color` - Alias for ColorNew
- `ColorGray(gray: int64): Color` - Grayscale
- `ColorEmpty(): Color` - Transparent black

### Preset Colors
- `ColorBlack()`, `ColorWhite()`, `ColorRed()`, `ColorGreen()`, `ColorBlue()`
- `ColorYellow()`, `ColorCyan()`, `ColorMagenta()`, `ColorOrange()`
- `ColorPurple()`, `ColorPink()`, `ColorBrown()`
- `ColorGrayLight()`, `ColorGrayDark()`

### Properties
- `ColorIsOpaque(c: Color): bool` - Fully opaque?
- `ColorIsTransparent(c: Color): bool` - Fully transparent?
- `ColorIsValid(c: Color): bool` - Valid values?

### Manipulation
- `ColorWithAlpha(c: Color, alpha: int64): Color` - Change alpha
- `ColorInvert(c: Color): Color` - Invert
- `ColorGrayscale(c: Color): Color` - Grayscale
- `ColorBrighten(c: Color, amount: int64): Color` - Brighten
- `ColorDarken(c: Color, amount: int64): Color` - Darken

### Blending
- `ColorBlend(src, dst: Color): Color` - Alpha blending
- `ColorMultiply(c1, c2: Color): Color` - Multiplication blend

### Interpolation
- `ColorLerp(c1, c2: Color, t: int64): int64` - Linear interpolation (t: 0-1000)
- `ColorMix(c1, c2: Color): Color` - 50/50 mix

### Hex Conversion
- `ColorFromHex(hex: int64): Color` - From hex (0xRRGGBB)
- `ColorToHex(c: Color): int64` - To hex
- `ColorToHexARGB(c: Color): int64` - To hex with alpha

### HSL
- `ColorFromHSL(h, s, l: int64): Color` - From HSL (h: 0-360, s,l: 0-255)
- `ColorToHSL(c: Color): array[3]int64` - To HSL [h, s, l]

---

## std/list.lyx

Dynamic containers: lists, RingBuffer, Stack, Queue.

### ListInt64 (class with heap)
```lyx
class ListInt64 {
  data: int64,
  length: int64,
  capacity: int64
}
```

### ListInt64 Functions
- `ListInt64New(): ListInt64` - Create new list
- `ListInt64WithCapacity(capacity: int64): ListInt64`
- `ListInt64Add(list: ListInt64, value: int64): void`
- `ListInt64Get(list: ListInt64, index: int64): int64`
- `ListInt64Set(list: ListInt64, index, value: int64): void`
- `ListInt64Len(list: ListInt64): int64`

### StaticList (static arrays, no heap)
- `StaticList8` - 8 elements
- `StaticList16` - 16 elements

Functions: `New()`, `Add()`, `Get()`, `Set()`, `Len()`, `Clear()`, `IsEmpty()`

### Vec2List (for routes/polygons)
```lyx
struct Vec2List {
  data: array[64]Vec2,
  length: int64
}
```
- `Vec2ListNew(): Vec2List`
- `Vec2ListAdd(list: Vec2List, value: Vec2): bool`
- `Vec2ListGet(list: Vec2List, index: int64): Vec2`
- `Vec2ListLast(list: Vec2List): Vec2` - Last element
- `Vec2ListPushBack()`, `Vec2ListPopBack()`

### RingBufferVec2 (GPS tracking)
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
- `RingBufferVec2Peek(rb: RingBufferVec2): Vec2` - Next without removing
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

## std/hash.lyx

Hash functions for data structures, integrity and passwords.

### FNV-1a (Fast Non-Cryptographic)
- `HashFNV1a32(data: pchar): int64` - 32-bit FNV-1a
- `HashFNV1a64(data: pchar): int64` - 64-bit FNV-1a
- `HashFNV1a32Bytes(data: pchar, len: int64): int64` - With length
- `HashFNV1a64Bytes(data: pchar, len: int64): int64` - With length

### More Non-Cryptographic
- `HashDJB2(data: pchar): int64` - DJB2 hash
- `HashMurmur2(data: pchar, seed: int64): int64` - MurmurHash2
- `HashMurmur2Default(data: pchar): int64` - MurmurHash2 with seed=0
- `HashCRC32(data: pchar): int64` - CRC32 checksum
- `HashBytes(data: array[256]int64, len: int64): int64` - Byte array hash
- `HashInt64(key: int64): int64` - Integer hash (64-bit)
- `HashInt32(key: int64): int64` - Integer hash (32-bit)

### Cryptographic (Simplified)
- `HashSHA256(data: pchar): int64` - SHA-256 (simplified)
- `HashSHA3_224(data: pchar): int64` - SHA-3-224
- `HashSHA3_256(data: pchar): int64` - SHA-3-256
- `HashSHA3_512(data: pchar): int64` - SHA-3-512
- `HashSHA3_256Hex(data: pchar): pchar` - SHA-3-256 as hex
- `HashKeccak(data: pchar): int64` - Raw Keccak-1600
- `HashSHAKE128(data: pchar, output_bits: int64): int64` - SHAKE128 XOF
- `HashSHAKE256(data: pchar, output_bits: int64): int64` - SHAKE256 XOF
- `HashBLAKE3(data: pchar): int64` - BLAKE3 (fast)
- `HashBLAKE3Hex(data: pchar): pchar` - BLAKE3 as hex

### Non-Cryptographic (Fast)
- `HashFNV1a32/64(data: pchar): int64` - FNV-1a
- `HashDJB2(data: pchar): int64` - DJB2
- `HashMurmur2(data: pchar, seed: int64): int64` - MurmurHash2
- `HashMurmur3_32(data: pchar, seed: int64): int64` - MurmurHash3
- `HashCity32(data: pchar): int64` - CityHash32
- `HashCity64(data: pchar): int64` - CityHash64
- `HashCity64Hex(data: pchar): pchar` - CityHash64 as hex
- `HashFarm32(data: pchar): int64` - FarmHash32
- `HashFarm64(data: pchar): int64` - FarmHash64
- `HashFarm64Hex(data: pchar): pchar` - FarmHash64 as hex
- `HashxxHash32(data: pchar): int64` - xxHash32 (very fast)
- `HashxxHash64(data: pchar): int64` - xxHash64
- `HashCRC32(data: pchar): int64` - CRC32
- `HashInt64/32(key: int64): int64` - Integer hash

### Password Hashing
- `HashPassword(password: pchar, salt: pchar): int64` - With string salt
- `HashPasswordSimple(password: pchar, salt: int64): int64` - With numeric salt

### Secure Password Hashing (KDF)
- `HashPBKDF2(password, salt: pchar, iterations: int64): int64` - PBKDF2-HMAC-SHA256
- `HashPBKDF2Default(password, salt: pchar): int64` - PBKDF2 with default iterations
- `HashPBKDF2Hex(password, salt: pchar, iterations: int64): pchar` - PBKDF2 as hex
- `HashBCrypt(password: pchar, cost: int64): int64` - bcrypt
- `HashBCryptHex(password: pchar, cost: int64): pchar` - bcrypt as hex
- `HashBCryptFormatted(password: pchar, cost: int64): pchar` - bcrypt formatted ($2a$...)
- `BCryptVerify(password: pchar, hash: int64): bool` - Verify bcrypt
- `HashArgon2d/i/id(password, salt: pchar, memory, iterations, parallelism): int64` - Argon2
- `HashArgon2(password, salt: pchar): int64` - Argon2id (default)
- `HashArgon2Hex(password, salt: pchar): pchar` - Argon2 as hex
- `HashArgon2Formatted(password, salt: pchar): pchar` - Argon2 formatted
- `Argon2Verify(password: pchar, hash: int64): bool` - Verify Argon2
- `HashScrypt(password, salt: pchar, n, r, p: int64): int64` - Scrypt
- `HashScryptDefault(password, salt: pchar): int64` - Scrypt with default parameters
- `HashScryptHex(password, salt: pchar): pchar` - Scrypt as hex

### Password Utilities
- `ComparePasswordHashes(hash1, hash2: int64): bool` - Constant-time comparison
- `GenerateSalt(len: int64): int64` - Generate salt
- `PasswordStrength(password: pchar): int64` - Strength score (0-4)

### Utilities
- `HashTableIndex(key: pchar, table_size: int64): int64` - Hash table index
- `VerifyHash(data: pchar, algorithm: int64, expected_hex: pchar): bool` - Verify hash

### Utilities
- `HashTableIndex(key: pchar, table_size: int64): int64` - Hash table index

---

## std/result.lyx

Result/Option pattern for robust error handling (like Rust).

### Error Codes (constants)
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

### ResultInt64 Functions
- `OkInt64(value: int64): ResultInt64` - Success
- `ErrInt64(error_code: int64): ResultInt64` - Error
- `ResultInt64IsOk(r: ResultInt64): bool` - Success?
- `ResultInt64IsErr(r: ResultInt64): bool` - Error?
- `ResultInt64Unwrap(r: ResultInt64): int64` - Get value (panic on error)
- `ResultInt64UnwrapOr(r: ResultInt64, default: int64): int64` - With default
- `ResultInt64Error(r: ResultInt64): int64` - Get error code

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
- `SafeAdd(a, b: int64): ResultInt64` - With overflow check
- `SafeSub(a, b: int64): ResultInt64`
- `SafeMul(a, b: int64): ResultInt64`
- `SafeDiv(a, b: int64): ResultInt64` - With division-by-zero check
- `SafeMod(a, b: int64): ResultInt64`

### Safe Array Access
- `SafeArrayGet(arr, len, index: int64): ResultInt64` - With bounds check
- `SafeArraySet(arr, len, index, value: int64): ResultBool`

---

## std/string.lyx

### Compatibility
- `StrCopy(dest, src: pchar): pchar` - Copy string
- `StrCpy(dest, src: pchar): pchar` - Alias for StrCopy

### String Search
- `StrFind(haystack, needle: pchar): int64` - First position or -1
- `StrSafeCharAt(s: pchar, index: int64): int64` - Safe character access
- `StrContains(s, needle: pchar): bool` - Contains substring?
- `StrIndexOf(s, needle: pchar, startIndex: int64): int64` - Position from index
- `StrLastIndexOfChar(s: pchar, c: int64): int64` - Last character position
- `StrAllIndicesOfCharCount(s: pchar, c: int64): int64` - Character count

### Boolean Tests
- `StrEquals(s1, s2: pchar): bool` - Equality
- `StrStartsWith(s, prefix: pchar): bool` - Starts with prefix?
- `StrEndsWith(s, suffix: pchar): bool` - Ends with suffix?

### Case Conversion
- `CharToLower(c: int64): int64` - Single character to lowercase
- `CharToUpper(c: int64): int64` - Single character to uppercase
- `StrToLower(dest, src: pchar): pchar` - String to lowercase
- `StrToUpper(dest, src: pchar): pchar` - String to uppercase
- `StrFirstCharToUpper(s: pchar): pchar` - First character uppercase
- `StrFirstCharToLower(s: pchar): pchar` - First character lowercase
- `StrLastCharToUpper(s: pchar): pchar` - Last character uppercase
- `StrLastCharToLower(s: pchar): pchar` - Last character lowercase

### String Manipulation
- `StrConcat(dest, s1, s2: pchar): pchar` - Concatenate
- `StrReverse(s: pchar): pchar` - Reverse
- `StrTrimWhitespace(dest, src: pchar): pchar` - Remove whitespace
- `StrSubstring(dest, src: pchar, start, len: int64): pchar` - Substring
- `StrReplace(dest, src, old, new: pchar): pchar` - Replace
- `IsWhitespace(c: int64): bool` - Is whitespace?
- `StrCount(s, needle: pchar): int64` - Count occurrences

**Native Builtins** (directly available):
- `StrLength(s: pchar): int64`
- `StrCharAt(s: pchar, i: int64): int64`
- `StrSetChar(s: pchar, i: int64, c: int64): void`
- `str_compare(a, b: pchar): int64`

---

## std/io.lyx

### Print Functions
- `Print(s: pchar): void` - Output without newline
- `PrintLn(s: pchar): void` - Output with newline
- `PrintLn(x: int64): void` - Integer with newline
- `PrintLn(x: f64): void` - Float with newline
- `PrintLn(b: bool): void` - Boolean with newline
- `PrintIntLn(x: int64): void` - Integer with newline (alias)
- `ExitProc(code: int64): void` - Exit program
- `BoolToStr(b: bool): pchar` - Boolean to string
- `FloatToStr(val: f64, prec: int64): pchar` - Float to string

### Printf (pure-Lyx)
`Printf(fmt: pchar, ...)` - Formatted output

Supported placeholders:
- `%s` - String (pchar)
- `%d` - Integer (int64)
- `%f` - Float (f64)
- `%%` - Literal %

Maximum 4 placeholders per call. Overloaded variants for all type combinations (0-4 arguments).

---

## std/env.lyx

### Environment
- `Init(argc: int64, argv: pchar): void` - Explicit initialization (optional)
- `ArgCount(): int64` - Number of command-line arguments
- `Arg(i: int64): pchar` - Argument i (0-based)

**Note**: Since v0.1.5, initialization happens automatically.

---

## std/time.lyx

### Calendar Calculations
- `DaysFromCivil(year, month, day: int64): int64` - Days since epoch
- `CivilYearFromDays(days: int64): int64` - Year from days
- `CivilMonthFromDays(days: int64): int64` - Month from days
- `CivilDayFromDays(days: int64): int64` - Day from days
- `IsLeapYear(year: int64): bool` - Leap year?
- `DayOfWeekFromDate(d: date): int64` - Day of week (0=Sunday)
- `DaysInMonth(year, month: int64): int64` - Days in month

### Date/Time Types
- `DateFromYmd(year, month, day: int64): date` - Create date
- `YearFromDate(d: date): int64` - Year from date
- `MonthFromDate(d: date): int64` - Month from date
- `DayFromDate(d: date): int64` - Day from date
- `TimeFromHms(hour, minute, second: int64): time` - Create time
- `HourFromTime(t: time): int64` - Hour from time
- `MinuteFromTime(t: time): int64` - Minute from time
- `SecondFromTime(t: time): int64` - Second from time
- `DatetimeFromUnixSeconds(sec: int64): datetime` - DateTime from epoch
- `DatetimeToUnixSeconds(dt: datetime): int64` - DateTime to epoch
- `TimestampFromUnixSeconds(sec: int64): timestamp` - Timestamp (microseconds)
- `UnixSecondsFromTimestamp(ts: timestamp): int64` - Timestamp to epoch

### System Time
- `Now(): datetime` - Current time (seconds since epoch)
- `NowUs(): timestamp` - Current time (microseconds)
- `NowMs(): int64` - Current time (milliseconds)

### Constants
- `SECOND: int64` - 1,000,000 (microseconds)
- `MINUTE: int64` - 60 * SECOND
- `HOUR: int64` - 60 * MINUTE
- `DAY: int64` - 24 * HOUR

### Timezones
- `TimeZone` - Struct with name and offset_seconds
- `ZoneUTC(): TimeZone`
- `ZoneCET(): TimeZone`
- `ZoneCEST(): TimeZone`
- `ApplyTimeZone(dt: datetime, zone: TimeZone): datetime`

### Formatting
- `ToIsoDateString(d: date): string` - Date as "YYYY-MM-DD"
- `IntToString(n: int64): string` - Integer to string

---

## std/geo.lyx

### Coordinate System
All coordinates are stored as **microdegrees** (int64):
- 1° = 1,000,000 µ°

### Parsing & Formatting
- `ParseLat(s: pchar): int64` - Parse latitude
- `ParseLon(s: pchar): int64` - Parse longitude
- `FormatDecimal(coord: int64): pchar` - Coordinate as decimal string

### Validation
- `IsValidLat(lat: int64): bool` - Valid latitude?
- `IsValidLon(lon: int64): bool` - Valid longitude?
- `IsValidGeoPoint(p: GeoPoint): bool` - Valid point?

### Distance Calculations
- `DistanceM(p1, p2: GeoPoint): int64` - Distance in meters
- `DistanceKm(p1, p2: GeoPoint): int64` - Distance in kilometers
- `DistanceSq(p1, p2: GeoPoint): int64` - Squared distance (for comparisons)
- `IsWithinDistanceM(p1, p2: GeoPoint, thresholdM: int64): bool` - Distance threshold
- `HaversineDistanceM(p1, p2: GeoPoint): int64` - Precise great-circle distance
- `DistanceMCorrected(p1, p2: GeoPoint): int64` - With cosine correction

### GeoPoint Helpers
- `GeoPointNew(lon, lat: int64): GeoPoint` - Create point

### Midpoint
- `Midpoint(p1, p2: GeoPoint): GeoPoint` - Midpoint of two points
- `MidpointLat(lat1, lat2: int64): int64` - Latitude midpoint
- `MidpointLon(lon1, lon2: int64): int64` - Longitude midpoint

### BoundingBox
- `IsPointInRect(p, min, max: GeoPoint): bool` - Point in rectangle?
- `BoundingBoxFromPoints(p1, p2: GeoPoint): [GeoPoint, GeoPoint]` - BoundingBox
- `DoBoundingBoxesOverlap(min1, max1, min2, max2: GeoPoint): bool` - Overlap?
- `BoundingBoxCenter(min, max: GeoPoint): GeoPoint` - Center

### Navigation
- `Bearing(p1, p2: GeoPoint): int64` - Bearing/direction (microdegrees)
- `CalculateBoundingBox(center: GeoPoint, radiusM: int64): [GeoPoint, GeoPoint]` - Circumcircle
- `AddOffsetM(center: GeoPoint, bearing, distanceM: int64): GeoPoint` - Offset
- `CorrectLongitudeForLatitude(dLon, lat: int64): int64` - Cosine correction

### DMS Format
- `ParseDMS(degrees, minutes, seconds, direction: int64): int64` - DMS to microdegrees
- `FormatDMS(coord: int64, isLatitude: bool): pchar` - Microdegrees to DMS

### Polygon
- `IsPointInPolygon(p: GeoPoint, polygon: [GeoPoint]): bool` - Point in polygon

**Constants:**
- `EARTH_RADIUS_METERS: int64` - 6,371,000 m

---

## std/crt.lyx

### Colors (ANSI)
- `crt_color` - Enum: black, blue, green, cyan, red, magenta, brown, light_gray, dark_gray, light_blue, light_green, light_cyan, light_red, light_magenta, yellow, white

### Color Functions
- `TextColor(c: crt_color): void` - Foreground color
- `TextBackground(c: crt_color): void` - Background color
- `TextAttr(fg, bg: crt_color): void` - Both colors
- `ResetAttr(): void` - Reset attributes

### Cursor & Screen
- `ClrScr(): void` - Clear screen
- `ClrEol(): void` - Clear to end of line
- `GoToXY(col, row: int64): void` - Set cursor (1-based)
- `HideCursor(): void` - Hide cursor
- `ShowCursor(): void` - Show cursor

### Output
- `WriteStrAt(col, row: int64, s: pchar): void` - String at position

### Input
- `ReadChar(): int64` - Blocking read (requires libc)

---

## std/crt_raw.lyx (experimental)

**IMPORTANT**: This unit requires dynamic linking (libc).

### Raw Mode
- `SetRawMode(enabled: bool): int64` - Enable raw mode
- `KeyPressed(): bool` - Check if key is waiting
- `ReadKeyRaw(): int64` - Non-blocking read

---

## std/pack.lyx

Binary serialization for Lyx data structures.

### VarInt
- `WriteVarInt(buf: pchar, pos, val: int64): int64` - Write VarInt
- `ReadVarInt(buf: pchar, pos: int64): int64` - Read VarInt
- `VarIntSize(val: int64): int64` - Calculate size

### Integer Packing
- `PackInt64(buf: pchar, pos, val: int64): int64` - Write 8 bytes
- `UnpackInt64(buf: pchar, pos: int64): int64` - Read 8 bytes
- `PackInt32(...)` / `UnpackInt32(...)` - 4 bytes
- `PackInt16(...)` / `UnpackInt16(...)` - 2 bytes
- `PackInt8(...)` / `UnpackInt8(...)` - 1 byte

### Boolean
- `PackBool(buf: pchar, pos: int64, val: bool): int64` - Write boolean
- `UnpackBool(buf: pchar, pos: int64): bool` - Read boolean

### Float
- `PackFloat64(buf: pchar, pos: int64, val: f64): int64` - 8 bytes IEEE 754
- `UnpackFloat64(buf: pchar, pos: int64): f64`
- `PackFloat32(...)` / `UnpackFloat32(...)` - 4 bytes

### String
- `PackString(buf: pchar, pos: int64, s: pchar): int64` - Varint-length + UTF-8
- `UnpackString(buf: pchar, pos: int64): pchar`
- `StringPackSize(s: pchar): int64` - Pack size

### Special
- `PackNull(buf: pchar, pos: int64): int64` - Null marker (0xFF)
- `IsNull(buf: pchar, pos: int64): bool` - Check null
- `PackArrayStart(buf: pchar, pos, count: int64): int64` - Array header
- `UnpackArrayStart(buf: pchar, pos: int64): int64` - Read array header

---

## std/regex.lyx

### Character Classes
- `isAlpha(c: int64): bool` - Letter?
- `isDigit(c: int64): bool` - Digit?
- `isAlnum(c: int64): bool` - Alphanumeric?
- `isWhitespace(c: int64): bool` - Whitespace?

### Regex Operations
- `RegexMatch(pattern, text: pchar): bool` - Match search in text
- `RegexSearch(pattern, text: pchar): int64` - First position or -1
- `RegexReplace(pattern, text, replacement: pchar): int64` - Count replacements
- `RegexMatchEx(pattern, text, flags: int64): bool` - Match with flags
- `RegexSearchEx(pattern, text, flags: int64): int64` - Search with flags
- `RegexReplaceEx(pattern, text, replacement, flags: int64): int64`
- `RegexReplaceInto(dest, pattern, text, replacement: pchar): int64`
- `RegexCaptureCount(): int64` - Number of captures
- `RegexCaptureStart(group: int64): int64` - Start position capture
- `RegexCaptureEnd(group: int64): int64` - End position capture
- `RegexCaptureText(dest, text: pchar, group: int64): pchar` - Capture text

---

## std/fs.lyx

File system operations.

### Types
- `fd` - File Descriptor (int64)

### Constants (Flags)
**Access modes:**
- `O_RDONLY` - Read only
- `O_WRONLY` - Write only
- `O_RDWR` - Read and write

**Status flags:**
- `O_CREAT` - Create if not exists
- `O_TRUNC` - Truncate to 0 bytes
- `O_APPEND` - Append
- `O_EXCL` - Error if exists

**Permissions:**
- `S_IRUSR`, `S_IWUSR` - Owner read/write
- `S_IRGRP`, `S_IWGRP` - Group read/write
- `S_IROTH`, `S_IWOTH` - Other read/write
- `DEFAULT_MODE` - 0644

**Seek positions:**
- `SEEK_SET` - From beginning
- `SEEK_CUR` - From current position
- `SEEK_END` - From end

**Standard FDs:**
- `STDIN_FILENO` - 0
- `STDOUT_FILENO` - 1
- `STDERR_FILENO` - 2

### File Operations
- `IsValidFd(f: fd): bool` - Valid FD?
- `ReadFile(path, buf: pchar, max_len: int64): int64` - Read file
- `WriteFile(path, buf: pchar, len: int64): int64` - Write file
- `AppendFile(path, buf: pchar, len: int64): int64` - Append
- `DeleteFile(path: pchar): bool` - Delete
- `FileExists(path: pchar): bool` - File exists?
- `FileSize(path: pchar): int64` - File size

### Standard I/O
- `StdoutWrite(buf: pchar, len: int64): int64` - stdout
- `StderrWrite(buf: pchar, len: int64): int64` - stderr
- `PutChar(c: int64): int64` - Output character

### Path Functions
- `PathNormalize(dest, src: pchar): pchar` - Normalize path (`./`, `../`, `//` resolve)
- `PathDir(dest, path: pchar): pchar` - Directory part
- `PathExt(dest, path: pchar): pchar` - Extension with dot
- `PathBase(dest, path: pchar): pchar` - Base filename without extension
- `PathResolve(dest, base, relative: pchar): pchar` - Resolve path (join)

---

## std/process.lyx

Process management for CLI tools and system integration.

### Types
- `Process` - Process handle (int64, stores PID)
- `ExitCode` - Exit status (0 = success, >0 = error)
- `StringList` - Argument list for run_args (static array of pchar)

### Constants
- `WNOHANG` - Non-blocking wait
- `SIGTERM` - 15 (graceful termination)
- `SIGKILL` - 9 (force termination)

### Process API
- `spawn(prog: pchar): Process` - Start process asynchronously, returns PID
- `run(prog: pchar): ExitCode` - Start process synchronously & wait
- `wait(pid: int64): ExitCode` - Wait for process (blocking)
- `try_wait(pid: int64): ExitCode` - Wait without blocking (-2 if still running)
- `is_running(pid: int64): bool` - Check if process is running
- `kill(pid, sig: int64): int64` - Send signal
- `terminate(pid: int64): int64` - Graceful termination (SIGTERM)
- `terminate_force(pid: int64): int64` - Force termination (SIGKILL)
- `self_pid(): int64` - Get own PID

### Shell & Argument Programs
- `shell(cmd: pchar): ExitCode` - Execute shell command (`/bin/sh -c "cmd"`)
  - ⚠️ **Security risk**: User input can interpret shell metacharacters
  - Avoid with user input — use `run_args()` instead
- `run_args(prog: pchar, args: StringList): ExitCode` - Execute program directly (recommended)
  - Uses `execvp` instead of shell — no shell injection possible
  - `args` must end with NULL (0)

**Example:**
```lyx
import std.process;

fn main(): int64 {
  // Synchronous: wait for completion
  var exit_code: int64 := run("/bin/ls");
  
  // Asynchronous: get PID and wait later
  var pid: int64 := spawn("/bin/sleep");
  // ... other work ...
  exit_code := wait(pid);
  
  // Safe: run_args instead of shell() for user input
  var args: StringList;
  args.data[0] := "/bin/ls";     // Program name
  args.data[1] := "-la";          // Argument 1
  args.data[2] := "/tmp";         // Argument 2
  args.data[3] := 0;              // NULL-terminate!
  exit_code := run_args("/bin/ls", args);
  
  return 0;
}
```

---

## std/json.lyx

JSON parser and serializer for Lyx.

### Types
- `JSON` - JSON value handle
- `JSON_NULL`, `JSON_BOOL`, `JSON_NUMBER`, `JSON_STRING`, `JSON_ARRAY`, `JSON_OBJECT`

### Error Codes
- `ERR_JSON_OK` - No error
- `ERR_JSON_INVALID` - Invalid JSON
- `ERR_JSON_EXPECTED` - Expected token not found
- `ERR_JSON_EOF` - Unexpected end
- `ERR_JSON_ESCAPE` - Invalid escape sequence

### Validation
- `isValidJSON(s: pchar): bool` - Check if string is valid JSON

### Parsing
- `parseArray(dest, src: pchar): int64` - Parse JSON array to pipe-separated string
- `parseValue(dest, src: pchar): int64` - Parse single JSON value (returns type)
- `toArray(dest, json_str: pchar): pchar` - Convenience wrapper for parseArray

### Serialization
- `serializeArray(dest, src: pchar): pchar` - Pipe string to JSON array
- `serializeValue(dest, value: pchar, json_type: int64): pchar` - Single value to JSON
- `JSONEscape(dest, src: pchar): pchar` - Escape string for JSON
- `stringify(dest, pipe_str: pchar): pchar` - Convenience wrapper for serializeArray

**Note**: Arrays are internally processed as pipe-separated strings (`"a|b|c"`).

**Example:**
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

## std/base64.lyx

Base64 encoding and decoding for data transmission and storage.

### Encoding
- `Encode(input, output: pchar): int64` - Encode input to Base64
- `EncodeBytes(input, len: int64, output: pchar): int64` - Encode byte array

### Decoding
- `Decode(input, output: pchar): int64` - Decode Base64 to raw bytes
- `DecodeToString(input, output: pchar): int64` - Decode to string

### Utilities
- `EncodeLength(input_len: int64): int64` - Calculate output length
- `DecodeLength(input_len: int64): int64` - Calculate output length
- `IsValidBase64(s: pchar): bool` - Check valid Base64 characters

---

## std/buffer.lyx

Buffer utilities for efficient byte processing.

### Buffer Operations
- `HexEncode(input, output: pchar): int64` - Hex encoding
- `HexDecode(input, output: pchar): int64` - Hex decoding
- `Base64Helper(input, output: pchar): int64` - Base64 helper functions

### Comparisons
- `BufferEquals(a, b: pchar): bool` - Byte-by-byte comparison
- `BufferCompare(a, b: pchar): int64` - Lexicographically (-1, 0, 1)

---

## std/url.lyx

URL parser and builder for web applications.

### Parsing
- `Parse(url: pchar): int64` - Parse URL (returns handle)
- `GetScheme(url: pchar): pchar` - Protocol (http, https, etc.)
- `GetHost(url: pchar): pchar` - Domain
- `GetPort(url: pchar): int64` - Port number
- `GetPath(url: pchar): pchar` - Path
- `GetQuery(url: pchar): pchar` - Query string
- `GetFragment(url: pchar): pchar` - Fragment (#anchor)

### Building
- `Build(scheme, host, port, path, query, fragment: pchar): pchar` - Compose URL
- `BuildWithDefaults(scheme, host, path: pchar): pchar` - With defaults

### Manipulation
- `SetScheme(url, scheme: pchar): bool` - Change scheme
- `SetHost(url, host: pchar): bool` - Change host
- `SetPort(url, port: int64): bool` - Change port
- `AddQueryParam(url, key, value: pchar): bool` - Add query parameter

---

## std/uuid.lyx

UUID generation and parsing (RFC 4122).

### UUID Types
- `UUID_VERSION_4` - Random UUID
- `UUID_VERSION_7` - Unix timestamp-based

### Generation
- `GenerateV4(output: pchar): bool` - Generate UUID v4 (random)
- `GenerateV7(output: pchar): bool` - Generate UUID v7 (timestamp)
- `GenerateV4String(output: pchar): bool` - UUID v4 as string
- `GenerateV7String(output: pchar): bool` - UUID v7 as string

### Conversion
- `ToString(uuid, output: pchar): bool` - UUID to string (8-4-4-4-12)
- `FromString(str, output: pchar): bool` - Parse string to UUID

### Comparison
- `Compare(uuidA, uuidB: pchar): int64` - Compare (-1, 0, 1)
- `IsNil(uuid: pchar): bool` - Check if nil UUID
- `IsValid(str: pchar): bool` - Validate string format
- `GetVersion(uuid: pchar): int64` - UUID version (1, 4, 7)
- `GetVariant(uuid: pchar): int64` - UUID variant

---

## std/html.lyx

HTML utilities for web applications.

### Escaping
- `Escape(input, output: pchar): int64` - Escape HTML special characters
- `Unescape(input, output: pchar): int64` - Unescape HTML entities

### Tag Utilities
- `GetTagName(html, output: pchar): int64` - Extract tag name
- `IsClosingTag(html: pchar): bool` - Check if </tag>
- `IsSelfClosing(html: pchar): bool` - Check if <tag/>

### Validation
- `HasTags(s: pchar): bool` - Contains HTML tags?
- `NeedsEscape(s: pchar): bool` - Needs escaping?
- `ValidateBalance(html: pchar): int64` - Tags balanced?

### Manipulation
- `StripTags(input, output: pchar): int64` - Remove tags, keep text
- `EncodeSpaces(input, output: pchar): int64` - Space to +
- `DecodeSpaces(input, output: pchar): int64` - + to space

---

## std/xml.lyx

XML parser and generator with full bidirectionality.

### Types
- `XML_NODE_ELEMENT`, `XML_NODE_TEXT`, `XML_NODE_CDATA`, `XML_NODE_COMMENT`

### Parsing
- `ParseString(input, output: pchar): int64` - Parse XML
- `XMLToArray(xml, output: pchar): int64` - Convert XML to array

### Generation
- `WriteDeclaration(output, version, encoding: pchar): int64` - XML declaration
- `WriteElement(output, tagName, attrs, attrCount, text, indent: pchar): int64` - Write element
- `WriteDocument(output, rootName, rootText, version, encoding: pchar): int64` - Complete document

### Escaping
- `EscapeText(input, output: pchar): int64` - Escape text
- `EscapeAttribute(input, output: pchar): int64` - Escape attribute value

### Array <-> XML
- `ArrayToXML(arr, output: pchar): int64` - Array to XML
- `CreateArrayEntry(name, text, output: pchar): int64` - Create array entry
- `GetArrayEntryName(arr, output: pchar): int64` - Name from entry
- `GetArrayEntryText(arr, output: pchar): int64` - Text from entry

### Validation
- `IsValid(xml: pchar): bool` - Valid XML?
- `CountElements(xml: pchar): int64` - Element count
- `PrettyPrint(input, output: pchar, indentSize: int64): int64` - Formatted output

---

## std/yaml.lyx

YAML parser and generator for configuration files.

### Types
- `YAML_NULL`, `YAML_BOOL`, `YAML_INT`, `YAML_FLOAT`, `YAML_STRING`, `YAML_SEQ`, `YAML_MAP`

### Parsing
- `ParseString(input: pchar): int64` - Parse YAML

### Getters
- `GetString(doc, path, default: pchar): pchar` - String value
- `GetInt(doc, path: pchar, default: int64): int64` - Integer value
- `GetFloat(doc, path: pchar, default: f64): f64` - Float value
- `GetBool(doc, path: pchar, default: bool): bool` - Boolean value

### Setters
- `SetString(doc, path, value: pchar): void` - Set string
- `SetInt(doc, path: pchar, value: int64): void` - Set integer

### Serialization
- `WriteString(doc, output: pchar, max_len: int64): int64` - Write YAML
- `EscapeString(input, output: pchar): int64` - Escape string
- `UnescapeString(input, output: pchar): int64` - Unescape string

### Validation
- `IsValidKey(s: pchar): bool` - Valid key?
- `NeedsQuoting(s: pchar): bool` - Needs quoting?

---

## std/ini.lyx

INI file parser and writer for configuration files.

### Constants
- `MAX_SECTIONS`, `MAX_ENTRIES_PER_SECTION`, `MAX_KEY_LENGTH`, `MAX_VALUE_LENGTH`

### Parsing
- `ParseString(input: pchar): int64` - Parse INI

### Getters
- `GetString(doc, section, key, default: pchar): pchar` - String value
- `GetInt(doc, section, key: pchar, default: int64): int64` - Integer value
- `GetBool(doc, section, key: pchar, default: bool): bool` - Boolean value
- `GetFloat(doc, section, key: pchar, default: f64): f64` - Float value

### Setters
- `SetString(doc, section, key, value: pchar): void` - Set string
- `SetInt(doc, section, key: pchar, value: int64): void` - Set integer

### Writing
- `WriteString(doc, output: pchar, max_len: int64): int64` - Write INI

### Deletion
- `DeleteKey(doc, section, key: pchar): bool` - Delete key
- `DeleteSection(doc, section: pchar): bool` - Delete section

### Validation
- `IsValidSectionName(name: pchar): bool` - Valid section name?
- `IsValidKeyName(name: pchar): bool` - Valid key name?

---

## std/os.lyx

OS-level functions and system calls.

### Process
- `GetPid(): int64` - Own PID
- `GetUid(): int64` - User ID
- `GetGid(): int64` - Group ID

### System
- `GetHostname(output: pchar): int64` - Hostname
- `GetEnv(name: pchar): pchar` - Environment variable
- `SetEnv(name, value: pchar): int64` - Set environment

### Time
- `GetTimestamp(): int64` - Nanoseconds since epoch
- `GetClockTime(): int64` - Clock time

---

## std/system.lyx

System information and configuration.

### CPU Info
- `GetCpuCount(): int64` - Number of CPU cores
- `GetCpuType(): int64` - CPU type
- `GetCpuFeatures(): int64` - CPU features (flags)

### Memory
- `GetTotalMemory(): int64` - Total RAM
- `GetFreeMemory(): int64` - Free RAM

### OS Info
- `GetOSName(): pchar` - OS name
- `GetOSVersion(): pchar` - OS version
- `GetArch(): pchar` - Architecture

---

## std/systeminfo.lyx

System information via `/proc` filesystem (Linux).

### CPU Information
- `GetLogicalCores(): int64` - Number of logical CPU cores
- `GetPhysicalCores(): int64` - Number of physical CPU cores
- `GetSMTWidth(): int64` - SMT/Hyperthreading width

### Memory Information
- `GetTotalMemory(): int64` - Total RAM in KB
- `GetAvailableMemory(): int64` - Available RAM in KB
- `GetFreeMemory(): int64` - Free RAM in KB

### Load Average
- `GetLoadAverage1(): int64` - 1-minute load average (format: XX.XX)
- `GetLoadAverage5(): int64` - 5-minute load average
- `GetLoadAverage15(): int64` - 15-minute load average

### System
- `GetOS(): int64` - OS type (0 = Linux)
- `GetUptime(): int64` - System uptime in seconds

### Process Information
- `GetProcessId(): int64` - Current process ID
- `GetParentProcessId(): int64` - Parent PID
- `GetUserTime(): int64` - User CPU time (ticks)
- `GetSystemTime(): int64` - System CPU time (ticks)
- `GetNumThreads(): int64` - Number of threads

### CPU Statistics
- `GetCpuUserTime(): int64` - Total CPU user time (jiffies)
- `GetCpuSystemTime(): int64` - Total CPU system time
- `GetCpuIdleTime(): int64` - Total CPU idle time
- `GetRunningProcesses(): int64` - Number of runnable processes

### Usage Example
```lyx
import std.systeminfo;
import std.io;

fn main(): int64 {
  PrintStr("Logical Cores: ");
  PrintIntLn(GetLogicalCores());
  
  PrintStr("Total Memory: ");
  PrintIntLn(GetTotalMemory() / 1024);
  
  PrintStr("Load 1min: ");
  PrintIntLn(GetLoadAverage1());
  
  return 0;
}
```

---

## std/log.lyx

Logging framework for application logging.

### Log Levels
- `LOG_DEBUG`, `LOG_INFO`, `LOG_WARN`, `LOG_ERROR`, `LOG_FATAL`

### Logging
- `Log(level, message: pchar): void` - Log message
- `LogDebug(msg: pchar): void` - Debug level
- `LogInfo(msg: pchar): void` - Info level
- `LogWarn(msg: pchar): void` - Warn level
- `LogError(msg: pchar): void` - Error level

### Configuration
- `SetLogLevel(level: int64): void` - Set log level
- `SetLogOutput(output: pchar): void` - Output destination

---

## std/stats.lyx

Statistical functions for data analysis.

### Descriptive Statistics
- `Mean(data: pchar): f64` - Arithmetic mean
- `Median(data: pchar): f64` - Median
- `StdDev(data: pchar): f64` - Standard deviation
- `Variance(data: pchar): f64` - Variance
- `Min(data: pchar): f64` - Minimum
- `Max(data: pchar): f64` - Maximum

### Calculations
- `Sum(data: pchar): f64` - Sum
- `Count(data: pchar): int64` - Number of elements
- `Range(data: pchar): f64` - Range (Max - Min)

---

## std/qbool.lyx

Quotient Boolean (ternary logic).

### Types
- `Q_TRUE` - True
- `Q_FALSE` - False
- `Q_NULL` - Undefined/Unknown

### Operations
- `QAnd(a, b: int64): int64` - Logical AND
- `QOr(a, b: int64): int64` - Logical OR
- `QNot(a: int64): int64` - Logical NOT

### Comparisons
- `QEquals(a, b: int64): bool` - Equality

---

## std/error.lyx

Error code management and handling.

### Error Types
- `ERR_NONE`, `ERR_UNKNOWN`, `ERR_INVALID_INPUT`, `ERR_OUT_OF_MEMORY`, etc.

### Error Handling
- `GetErrorCode(): int64` - Get last error code
- `SetErrorCode(code: int64): void` - Set error code
- `ClearError(): void` - Reset error
- `ErrorToString(code: int64): pchar` - Error code to string

---

## Usage

### Basic Import
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

### Geo Example
```lyx
import std.geo;

fn main(): int64 {
  var berlin: GeoPoint := GeoPointNew(13400000, 52500000);  // 13.4°, 52.5°
  var paris: GeoPoint := GeoPointNew(2300000, 48800000);   // 2.3°, 48.8°
  var dist: int64 := DistanceM(berlin, paris);
  PrintIntLn(dist);  // in meters
  return 0;
}
```

---

## std/alloc.lyx

Explicit memory management for high-performance system programming.

### Types
- `Ptr` - Raw pointer (int64)
- `Pool` - Pool allocator handle

### Constants
- `ALIGNMENT` - 8 bytes (x86_64)
- `ERR_ALLOC_OK` - No error
- `ERR_ALLOC_OOM` - Out of memory
- `ERR_ALLOC_INVALID` - Invalid pointer

### malloc/free API
- `malloc(size: int64): Ptr` - Allocate memory
- `calloc(count, elem_size: int64): Ptr` - Allocate + zero-initialize
- `free_mem(ptr: Ptr): int64` - Free memory
- `realloc_mem(ptr: Ptr, new_size: int64): Ptr` - Reallocate

### Pool Allocator (Arena)
- `createPool(capacity: int64): Pool` - Create pool
- `pool_alloc(pool: Ptr, size: int64): Ptr` - O(1) allocation from pool
- `pool_release(pool: Ptr): int64` - Release entire pool

### Utility
- `size_of_int64(): int64` - Size of int64
- `size_of_ptr(): int64` - Size of pointer
- `is_aligned(ptr: Ptr): bool` - Check 8-byte alignment
- `malloc_safe(size: int64): Ptr` - With error checking (returns 0 on OOM)
- `malloc_orpanic(size: int64): Ptr` - Allocate or panic

**Performance comparison:**
| Method | Speed | Fragmentation |
|--------|-------|---------------|
| malloc | Medium | Yes |
| Pool | O(1) | No |

**Example:**
```lyx
import std.alloc;

// Pool for 1000 elements
var pool: Pool := createPool(8192);

// O(1) allocation
var ptr: Ptr := pool_alloc(pool, 256);

// Release everything
pool_release(pool);
```

---

## Architecture Highlights

### Microdegrees
The decision to use **int64 for coordinates and angles** (`1° = 1,000,000 µ°`) cleverly avoids the typical precision problems of floating-point numbers in critical areas like GPS or trigonometry.

### Increased Robustness
The **`std/result`** unit brings modern error-handling patterns to a low-level language, which particularly prevents crashes in file operations (`std/fs`) and memory allocation (`std/alloc`).

### Versatility
From **low-level bit manipulations** to **high-level JSON parsing**, everything needed for modern CLI or system tools is covered.

---

## Coordinate Systems (Geo Overview)

Lyx uses **microdegrees** for all geodata:
- `1° = 1,000,000 µ°`
- Coordinates are stored as int64

**Example:** Berlin
```
Latitude: 52.52° → 52520000 µ°
Longitude: 13.405° → 13405000 µ°
```

---

## Pro Tips for Usage

### 1. Performance with Lists
In `std/list.lyx`, you have the choice between **ListInt64** (heap) and **StaticList** (stack).

- **Use StaticList** when the maximum number of elements (8 or 16) is known. This saves the overhead of malloc/free.
- **Use the pool allocator** from `std/alloc` if you have many small objects with the same lifetime (e.g., when parsing a JSON tree).

### 2. Safe String Handling
Since `pchar` in Lyx is a classic null-terminated pointer, you should always ensure the destination buffer is large enough with `StrConcat` and `StrCopy`.

**Important:** Use `StrLength(s)` from the builtins to validate buffer size before copy operations.

### 3. Geodata Calculations
When using `DistanceMCorrected` in `std/geo`, the longitude distance is adjusted based on latitude. This is extremely performant and precise enough for short to medium distances (up to a few hundred kilometers), without needing the computationally expensive Haversine formula:

```
d ≈ √((x₂ - x₁)² · cos(lat)² + (y₂ - y₁)²)
```

### 4. Memory Management Guide (Ownership)
Most string functions in `std/string` **expect a pre-allocated destination buffer** (`dest`) to avoid hidden heap allocations:

```lyx
import std.string;

var dest: pchar := "                                                                                ";
StrCopy(dest, source);  // User provides buffer
```

**Rules:**
- **Provide your own destination buffer** - Never assume functions allocate memory
- **Validate buffer size** - Check with `StrLength()` before copy operations
- **When in doubt** - Use `std/alloc` for explicit allocation
- **Pre-initialize buffers** - With spaces or zeros to overwrite old data

### 5. Visual Support (Coordinate System)
Lyx uses a **screen coordinate system** (Y points down):

```
std/vector (Vec2):
┌─────────────────────┐
│ (0,0)        (w,0) │
│                     │
│                     │
│ (0,h)        (w,h) │
└─────────────────────┘
```

**Rect:** `min` is top-left, `max` is bottom-right

**Rotation:** Positive angles rotate clockwise (due to inverted Y-axis)

**Important:** For geo calculations, **mathematical** coordinates are used (Y points up), while for UI graphics, **screen-based** coordinates are used (Y points down).

### 6. The Lyx Way (Best Practices)

> **Tip:** Avoid using `f64` for critical calculations when possible. Use the `std/math` fixed-point functions for maximum performance and deterministic results on all target systems.

**Best Practices:**
1. **Prefer int64** - For coordinates, angles, monetary amounts
2. **Use microdegrees** - `1° = 1,000,000 µ°` for geodata
3. **Pool allocator** - For many similar objects
4. **Result types** - For functions that can fail
5. **Provide your own buffer** - No hidden allocations

### Error Handling with std/result
Consistently use `std/result`. Instead of crashing on division by zero, SafeDiv allows an elegant fallback:

```lyx
import std.result;
import std.io;

fn divide(a, b: int64): void {
  var res := SafeDiv(a, b);
  if (ResultInt64IsOk(res)) {
    PrintIntLn(ResultInt64Unwrap(res));
  } else {
    PrintLn("Error: Division by zero!");
  }
}
```

---

## std/sort.lyx

Efficient sorting algorithms for int64 arrays.

### SortInt64
- `SortInt64(arr: Ptr, len: int64): void` - Sort int64 array in-place

### Algorithm
- **Hybrid QuickSort** with median-of-three pivot strategy
- **InsertionSort** for small partitions (< 10 elements)
- **In-place** - Minimal memory usage (only stack for recursion)

### Median-of-Three
The pivot selection uses the median of first, middle, and last element to avoid worst-case on already sorted data.

**Example:**
```lyx
import std.sort;

fn main(): int64 {
  var arr: array[5]int64;
  arr[0] := 5; arr[1] := 3; arr[2] := 8; arr[3] := 1; arr[4] := 9;
  
  SortInt64(arr, 5);  // arr is now [1, 3, 5, 8, 9]
  
  return 0;
}
```

---

## std/qt5_app.lyx

Qt5 Application wrapper for Lyx (FFI around libqtlyx.so).

### Setup
```bash
# Build libqtlyx.so
cd qt_wrapper && make

# Set library path when running
export LD_LIBRARY_PATH=$PWD/qt_wrapper:$LD_LIBRARY_PATH
```

### Application
- `qt_init(): int64` - Initialize QApplication
- `qt_exec(): int64` - Run event loop (blocks)
- `qt_quit(): int64` - Request quit
- `qt_create_window(title, width, height): int64` - Create window

### Widgets

**Input Widgets:**
- `qt_lineedit_create(parent, text): int64`
- `qt_spinbox_create(parent): int64`
- `qt_doublespinbox_create(parent): int64`
- `qt_slider_create(parent, orientation): int64`
- `qt_dial_create(parent): int64`

**Selection:**
- `qt_checkbox_create(parent, text): int64`
- `qt_radiobutton_create(parent, text): int64`
- `qt_combobox_create(parent): int64`

**Display:**
- `qt_progressbar_create(parent): int64`
- `qt_listwidget_create(parent): int64`
- `qt_treewidget_create(parent): int64`
- `qt_tablewidget_create(parent, rows, cols): int64`
- `qt_textedit_create(parent, text): int64`
- `qt_tabwidget_create(parent): int64`

**Layouts:**
- `qt_hbox_create(): int64` - Horizontal layout
- `qt_vbox_create(): int64` - Vertical layout
- `qt_grid_create(): int64` - Grid layout
- `qt_splitter_create(parent, orientation): int64`

### Graphics (2D)
- `qt_pixmap_create(width, height): int64`
- `qt_pixmap_load(pixmap, filename): int64`
- `qt_pixmap_save(pixmap, filename, format): int64`
- `qt_pixmap_width(pixmap): int64`
- `qt_pixmap_height(pixmap): int64`
- `qt_pixmap_fill(pixmap, r, g, b, a): int64`
- `qt_image_create(width, height, format): int64`

**QPainter:**
- `qt_painter_begin(pixmap): int64`
- `qt_painter_end(): int64`
- `qt_painter_set_pen_color(r, g, b, a): int64`
- `qt_painter_set_pen_width(width): int64`
- `qt_painter_set_brush_color(r, g, b, a): int64`
- `qt_painter_draw_line(x1, y1, x2, y2): int64`
- `qt_painter_draw_rect(x, y, w, h): int64`
- `qt_painter_draw_ellipse(x, y, w, h): int64`
- `qt_painter_draw_text(x, y, text): int64`
- `qt_painter_draw_text(x, y, text): int64`
- `qt_painter_fill_rect(x, y, w, h, r, g, b, a): int64`
- `qt_painter_set_font(family, size, bold): int64`
- `qt_painter_set_opacity(opacity): int64`

### Callbacks (Event-Marker System)

Widgets use an **event marker** pattern: connect a callback ID, then poll in your event loop.

| Widget | `on_*` Callback | `was_*` Poller |
|--------|-----------------|----------------|
| Button | `qt_button_on_clicked` | `qt_button_was_clicked` |
| CheckBox | `qt_checkbox_on_toggled` | `qt_checkbox_was_toggled` |
| Slider | `qt_slider_on_valuechanged` | `qt_slider_was_changed` |
| Dial | `qt_dial_on_value_changed` | `qt_dial_was_changed` |
| SpinBox | `qt_spinbox_on_value_changed` | `qt_spinbox_was_changed` |
| DoubleSpinBox | `qt_doublespinbox_on_value_changed` | - |
| LineEdit | `qt_lineedit_on_text_changed` | `qt_lineedit_was_changed` |
| TextEdit | `qt_textedit_on_text_changed` | `qt_textedit_was_changed` |
| ComboBox | `qt_combobox_on_current_index_changed` | `qt_combobox_was_changed` |
| ListWidget | `qt_listwidget_on_current_row_changed` | `qt_listwidget_was_changed` |
| TabWidget | `qt_tabwidget_on_current_changed` | `qt_tabwidget_was_changed` |
| Action | `qt_action_create_with_callback` | `qt_action_was_triggered` |
| Timer | `qt_timer_on_timeout` | - |

### Usage Example
```lyx
import std.qt5_app;

pub fn main(): int64 {
    qt_init();
    
    var win: int64 := qt_create_window("My App", 400, 300);
    var btn: int64 := qt_button_create(win, "Click Me");
    
    // Register callback
    qt_button_on_clicked(btn, 1);
    
    qt_show(win);
    
    // Event loop
    while true {
        qt_process_events();
        
        // Poll for button click
        if qt_button_was_clicked(btn) == 1 {
            // Handle click
        }
    }
    
    return qt_exec();
}
```

---

*Note: Additionally, 22 native math builtins are available (see main README).*
