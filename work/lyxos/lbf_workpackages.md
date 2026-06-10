# Lyx Binary Format (LBF) — Implementierungs-Fahrplan

**Version:** 1.0
**Basis-Spezifikation:** `lbf.md`
**Implementierungssprache:** Lyx (lyxc v0.8.3+)
**Pfade:** `tools/lbf/` (Userspace-Werkzeuge), `kernel/lbf_exec.lyx` (Kernel-Integration)
**Abhängigkeit:** IOFS WP01–WP10 (für WP08–WP10)

---

## Schichtenmodell

```
+----------------------------------------------------------+
| WP12 — Lifecycle Descriptor (Compiler + Kernel)          |
+----------------------------------------------------------+
| WP11 — lbf-dump (Inspektion & Debugging)                 |
+----------------------------------------------------------+
| WP07 — lbf_run (POSIX-Loader)                            |
| WP08 — lbf_import (POSIX → IOFS-Konvertierung)           |
+----------------------------------------------------------+
| WP10 — Zero-Load Executor (IOFS-Kernel, CR3-Mapping)     |
+----------------------------------------------------------+
| WP09 — Dependency Resolver (Hash → LPID auf IOFS)        |
+----------------------------------------------------------+
| WP06 — lyxc LBF-Backend (Compiler-Integration)           |
+----------------------------------------------------------+
| WP05 — Supply Chain Security (SHA-256, CRC, Blacklist)   |
+----------------------------------------------------------+
| WP04 — Section Block Emitter (.text/.data/.rodata/.bss)  |
+----------------------------------------------------------+
| WP03 — TLV-Framework (Encoder/Decoder, alle Typen)       |
+----------------------------------------------------------+
| WP02 — Genesis-Content Serializer (4032-Byte-Struktur)   |
+----------------------------------------------------------+
| WP01 — LBF Block Header I/O (64-Byte-Header, CRC32C)    |
+----------------------------------------------------------+
```

---

## Arbeitspaket-Übersicht

| WP   | Name                             | Abhängig von         | Pfad                        | Priorität |
|------|----------------------------------|----------------------|-----------------------------|-----------|
| WP01 | Block Header I/O                 | —                    | `tools/lbf/block_header.lyx`| Kritisch  |
| WP02 | Genesis-Content Serializer       | WP01                 | `tools/lbf/genesis.lyx`     | Kritisch  |
| WP03 | TLV-Framework                    | WP02                 | `tools/lbf/tlv.lyx`         | Kritisch  |
| WP04 | Section Block Emitter            | WP01                 | `tools/lbf/sections.lyx`    | Kritisch  |
| WP05 | Supply Chain Security            | WP01, WP02, WP03     | `tools/lbf/security.lyx`    | Kritisch  |
| WP06 | lyxc LBF-Backend                 | WP01–WP05            | lyxc intern                 | Kritisch  |
| WP07 | POSIX-Loader (lbf_run)           | WP01, WP04, WP05     | `tools/lbf_run.lyx`         | Hoch      |
| WP08 | IOFS-Import (lbf_import)         | WP01–WP05, IOFS WP03 | `tools/lbf_import.lyx`      | Hoch      |
| WP09 | Dependency Resolver              | WP08, IOFS WP06      | `tools/lbf/dep_resolver.lyx`| Hoch      |
| WP10 | Zero-Load Executor               | WP08, WP09, IOFS WP10| `kernel/lbf_exec.lyx`       | Hoch      |
| WP11 | lbf-dump Inspection Tool         | WP01–WP05            | `tools/lbf_dump.lyx`        | Mittel    |
| WP12 | Lifecycle Descriptor             | WP03, WP06, WP10     | lyxc intern + kernel        | Hoch      |

---

## Physische Konstanten (lbf_layout.lyx)

```lyx
unit lbf_layout;

// Magic
con LBF_MAGIC_0: int64 := 0x4C;   // 'L'
con LBF_MAGIC_1: int64 := 0x42;   // 'B'
con LBF_MAGIC_2: int64 := 0x46;   // 'F'
con LBF_MAGIC_3: int64 := 0x31;   // '1'

// Block-Geometrie
con LBF_BLOCK_SIZE:      int64 := 4096;
con LBF_HEADER_SIZE:     int64 := 64;
con LBF_PAYLOAD_SIZE:    int64 := 4032;   // 4096 - 64

// Genesis-Payload-Offsets (ab Byte 0x0040 der Datei)
con LBF_GEN_CONTENT_TYPE:    int64 := 0x0000;
con LBF_GEN_TARGET_ARCH:     int64 := 0x0001;
con LBF_GEN_OS_VERSION:      int64 := 0x0002;
con LBF_GEN_ENTRY_POINT:     int64 := 0x0004;
con LBF_GEN_FILE_SIZE:       int64 := 0x000C;
con LBF_GEN_TEXT_BLOCKS:     int64 := 0x0010;
con LBF_GEN_RODATA_BLOCKS:   int64 := 0x0012;
con LBF_GEN_DATA_BLOCKS:     int64 := 0x0014;
con LBF_GEN_BSS_BLOCKS:      int64 := 0x0016;
con LBF_GEN_STACK_SIZE:      int64 := 0x0018;
con LBF_GEN_FILE_CRC32C:     int64 := 0x001C;
con LBF_GEN_COMPILER_NAME:   int64 := 0x0020;
con LBF_GEN_COMPILER_VER:    int64 := 0x0030;
con LBF_GEN_COMPILED_AT:     int64 := 0x0034;
con LBF_GEN_COMPILER_UUID:   int64 := 0x003C;
con LBF_GEN_SOURCE_SHA256:   int64 := 0x004C;
con LBF_GEN_TLV_OFFSET:      int64 := 0x006C;
con LBF_GEN_TLV_USED:        int64 := 0x006E;
con LBF_GEN_TLV_POOL:        int64 := 0x0080;
con LBF_GEN_TLV_MAX_SIZE:    int64 := 3904;   // 4032 - 128

// Block-Header-Offsets (ab Byte 0x0000 jedes Blocks auf POSIX)
con LBF_HDR_MAGIC:        int64 := 0x0000;
con LBF_HDR_PAGE_TYPE:    int64 := 0x0004;
con LBF_HDR_FLAGS:        int64 := 0x0005;
con LBF_HDR_EDGE_OFFSET:  int64 := 0x0006;
con LBF_HDR_LPID:         int64 := 0x0008;
con LBF_HDR_PAYLOAD_SIZE: int64 := 0x0010;
con LBF_HDR_BLOCK_CRC32C: int64 := 0x0018;
con LBF_HDR_META_OFFSET:  int64 := 0x001C;
con LBF_HDR_CONT_LPID:    int64 := 0x0020;
con LBF_HDR_BLOCK_INDEX:  int64 := 0x0028;
con LBF_HDR_TOTAL_BLOCKS: int64 := 0x002C;
con LBF_HDR_COMPILED_AT:  int64 := 0x0038;

// TLV-Typen
con LBF_TLV_INTENT:         int64 := 0x01;
con LBF_TLV_DEPS:           int64 := 0x02;
con LBF_TLV_EXPORTS:        int64 := 0x03;
con LBF_TLV_SECTIONS:       int64 := 0x04;
con LBF_TLV_CAPABILITIES:   int64 := 0x05;
con LBF_TLV_EMBEDDING:      int64 := 0x06;
con LBF_TLV_BUILD_MANIFEST: int64 := 0x07;
con LBF_TLV_LIFECYCLE:      int64 := 0x08;   // NEU: Prozess-Lebenszyklus

// Lifecycle-Kinds (TLV 0x08, Byte 0)
con LBF_LC_ONE_SHOT:   int64 := 0x00;   // CLI: start → main → exit (aktueller _start LX-03)
con LBF_LC_EVENT_LOOP: int64 := 0x01;   // Hat explizite Event-Schleife
con LBF_LC_DAEMON:     int64 := 0x02;   // Langlebiger Hintergrundprozess
con LBF_LC_REACTIVE:   int64 := 0x03;   // Lazy-Start: nur bei eingehendem Event hochfahren

// Event-Source-Kinds (TLV 0x08, Deskriptor Byte 0)
con LBF_EV_STDIN:       int64 := 0x01;
con LBF_EV_FD:          int64 := 0x02;
con LBF_EV_TIMER:       int64 := 0x03;
con LBF_EV_SIGNAL:      int64 := 0x04;
con LBF_EV_NET_ACCEPT:  int64 := 0x05;
con LBF_EV_NET_RECV:    int64 := 0x06;
con LBF_EV_IOFS_EVENT:  int64 := 0x07;
con LBF_EV_KI_MESSAGE:  int64 := 0x08;
con LBF_EV_CHILD_EXIT:  int64 := 0x09;
con LBF_EV_AUDIO_IN:    int64 := 0x0A;
con LBF_EV_UNRESTRICTED: int64 := 0xFF;

// Lifecycle-Deskriptor-Offsets (innerhalb TLV-Value)
con LBF_LC_KIND:          int64 := 0x00;   // uint8_t
con LBF_LC_SOURCE_COUNT:  int64 := 0x01;   // uint8_t
con LBF_LC_QUIESCENCE_KB: int64 := 0x02;   // uint16_t
con LBF_LC_ON_IDLE_VA:    int64 := 0x04;   // uint64_t
con LBF_LC_IDLE_TIMEOUT:  int64 := 0x0C;   // uint32_t
con LBF_LC_SOURCES:       int64 := 0x10;   // Event-Source-Array ab hier
con LBF_LC_SRC_SIZE:      int64 := 12;     // Bytes pro Event-Source-Deskriptor
con LBF_LC_SRC_KIND:      int64 := 0x00;   // uint8_t (im Deskriptor)
con LBF_LC_SRC_FLAGS:     int64 := 0x01;   // uint8_t
con LBF_LC_SRC_PARAM:     int64 := 0x02;   // uint16_t (Hz / Signalnummer / ...)
con LBF_LC_SRC_ON_EVENT:  int64 := 0x04;   // uint64_t (VA des Event-Handlers)

// Section-Typen
con LBF_SECT_TEXT:   int64 := 0x01;
con LBF_SECT_DATA:   int64 := 0x02;
con LBF_SECT_RODATA: int64 := 0x03;
con LBF_SECT_BSS:    int64 := 0x04;

// Schutzrechte (Bitmaske)
con LBF_PROT_READ:    int64 := 0x01;
con LBF_PROT_WRITE:   int64 := 0x02;
con LBF_PROT_EXEC:    int64 := 0x04;

// IOFS-Pagetyp für LBF
con IOFS_PAGE_TYPE_LBF_EXEC: int64 := 0x04;

// Kanten-Gewichte
con LBF_EDGE_BLOCK_CHAIN: int64 := 0xB001;
con LBF_EDGE_DEPENDENCY:  int64 := 0xD001;

// Capabilities-Bits
con LBF_CAP_FS_READ:       int64 := 1;
con LBF_CAP_FS_WRITE:      int64 := 2;
con LBF_CAP_NET_SOCKET:    int64 := 4;
con LBF_CAP_PROC_SPAWN:    int64 := 8;
con LBF_CAP_KI_EMBED:      int64 := 16;
con LBF_CAP_KI_GRAPH_WRITE: int64 := 32;
con LBF_CAP_SANDBOX_ACCESS: int64 := 64;
con LBF_CAP_AUDIO_MIC:     int64 := 128;
con LBF_CAP_PRIVILEGED:    int64 := 9223372036854775808;  // Bit 63
```

---

## WP01 — LBF Block Header I/O

**Datei:** `tools/lbf/block_header.lyx`
**Abhängigkeiten:** `lbf_layout.lyx`, CRC32C-Primitive (aus IOFS WP03 oder eigenständig)
**Geschätzter Aufwand:** 2–3 Tage

### Ziel

Lesen, Schreiben und Validieren des 64-Byte-LBF-Block-Headers. Dieser Header ist das kleinste strukturelle Atom des gesamten Formats. Alle höheren WPs bauen darauf auf.

### Funktionen

**`lbf_header_init(buf: pchar, block_index: int64, total_blocks: int64, compiled_at: int64, is_genesis: bool)`**

Befüllt 64 Bytes im Puffer mit Default-Werten:

```lyx
fn lbf_header_init(buf: pchar, block_index: int64, total_blocks: int64, compiled_at: int64, is_genesis: bool) {
  poke8(buf + LBF_HDR_MAGIC + 0, LBF_MAGIC_0);
  poke8(buf + LBF_HDR_MAGIC + 1, LBF_MAGIC_1);
  poke8(buf + LBF_HDR_MAGIC + 2, LBF_MAGIC_2);
  poke8(buf + LBF_HDR_MAGIC + 3, LBF_MAGIC_3);
  poke8(buf + LBF_HDR_PAGE_TYPE, IOFS_PAGE_TYPE_LBF_EXEC);
  poke8(buf + LBF_HDR_FLAGS, 0x00);
  poke8(buf + LBF_HDR_EDGE_OFFSET + 0, 0x40);
  poke8(buf + LBF_HDR_EDGE_OFFSET + 1, 0x00);
  poke64(buf + LBF_HDR_LPID, 0);
  poke8(buf + LBF_HDR_PAYLOAD_SIZE + 0, 0xC0);
  poke8(buf + LBF_HDR_PAYLOAD_SIZE + 1, 0x0F);
  poke32(buf + LBF_HDR_BLOCK_CRC32C, 0);
  if (is_genesis) {
    poke32(buf + LBF_HDR_META_OFFSET, 0x0040);
  } else {
    poke32(buf + LBF_HDR_META_OFFSET, 0x0000);
  }
  poke64(buf + LBF_HDR_CONT_LPID, 0);
  poke32(buf + LBF_HDR_BLOCK_INDEX, block_index);
  poke32(buf + LBF_HDR_TOTAL_BLOCKS, total_blocks);
  poke64(buf + LBF_HDR_COMPILED_AT, compiled_at);
}
```

**`lbf_header_set_immutable(buf: pchar)`** — setzt `Flags |= 0x01` (für .text und .rodata Blöcke)

**`lbf_header_set_crc(buf: pchar, payload: pchar)`** — berechnet CRC32C über `payload` (4032 Bytes), schreibt Ergebnis an `LBF_HDR_BLOCK_CRC32C`

**`lbf_header_validate(buf: pchar) → int64`** — prüft Magic, liest und verifiziert CRC32C des Payloads; return 0 = OK, -1 = Magic-Fehler, -2 = CRC-Fehler

**`lbf_header_get_block_index(buf: pchar) → int64`** — liest `block_index` aus Header

**`lbf_header_get_total_blocks(buf: pchar) → int64`**

**`lbf_header_is_genesis(buf: pchar) → bool`** — prüft `LBF_HDR_META_OFFSET == 0x0040`

### Abnahmekriterien

- [ ] `lbf_header_init()` + direkter Byte-Dump: alle 64 Bytes korrekt belegt, Padding-Bytes = 0x00
- [ ] `lbf_header_validate()` auf korrekt initialisiertem Header mit gesetztem CRC → return 0
- [ ] `lbf_header_validate()` nach Flippen von 1 Bit im Payload → return -2 (CRC-Fehler)
- [ ] `lbf_header_validate()` auf Puffer mit falschen Magic-Bytes → return -1
- [ ] `lbf_header_set_immutable()` setzt exakt Bit 0 des Flags-Bytes; übrige Bits bleiben unverändert
- [ ] `lbf_header_is_genesis()` gibt `true` für Block 0 (meta_offset=0x0040) und `false` für Block 1+ (meta_offset=0x0000)
- [ ] Roundtrip: 100 verschiedene `block_index`-Werte (0–99): `lbf_header_get_block_index()` liefert stets den eingetragenen Wert zurück

---

## WP02 — Genesis-Content Serializer

**Datei:** `tools/lbf/genesis.lyx`
**Abhängigkeiten:** WP01
**Geschätzter Aufwand:** 3–4 Tage

### Ziel

Aufbau, Serialisierung und Deserialisierung des 4032-Byte-Genesis-Content-Blocks. Dieser Block enthält alle maschinen-lesbaren Metadaten eines LBF-Programms. Er wird vom lyxc-Backend (WP06) befüllt und vom Kernel (WP10) sowie vom IOFS-Importer (WP08) gelesen.

### Interne Datenstruktur

```lyx
// Repräsentation im Compiler-RAM (vor Serialisierung)
type LbfGenesisData = struct {
  // Core Machine Header
  target_arch:    int64;
  os_version_min: int64;
  entry_point:    int64;
  file_size:      int64;
  text_blocks:    int64;
  rodata_blocks:  int64;
  data_blocks:    int64;
  bss_blocks:     int64;
  stack_size:     int64;

  // Provenance
  compiler_name:    pchar;
  compiler_version: int64;
  compiled_at:      int64;
  compiler_uuid:    pchar;   // 16 Bytes
  source_sha256:    pchar;   // 32 Bytes

  // TLV-Bereich (wird von WP03 befüllt)
  tlv_buf:  pchar;
  tlv_used: int64;
};
```

### Funktionen

**`genesis_serialize(data: LbfGenesisData, out: pchar)`**

Schreibt alle Felder byteweise in den 4032-Byte-Ausgabepuffer `out` (der Payload-Teil von Block 0):

```lyx
fn genesis_serialize(data: LbfGenesisData, out: pchar) {
  poke8(out + LBF_GEN_CONTENT_TYPE, 0x01);
  poke8(out + LBF_GEN_TARGET_ARCH, data.target_arch);
  poke8(out + LBF_GEN_OS_VERSION + 0, data.os_version_min & 0xFF);
  poke8(out + LBF_GEN_OS_VERSION + 1, (data.os_version_min >> 8) & 0xFF);
  poke64(out + LBF_GEN_ENTRY_POINT, data.entry_point);
  poke32(out + LBF_GEN_FILE_SIZE, data.file_size);
  poke8(out + LBF_GEN_TEXT_BLOCKS + 0, data.text_blocks & 0xFF);
  poke8(out + LBF_GEN_TEXT_BLOCKS + 1, (data.text_blocks >> 8) & 0xFF);
  poke8(out + LBF_GEN_RODATA_BLOCKS + 0, data.rodata_blocks & 0xFF);
  poke8(out + LBF_GEN_RODATA_BLOCKS + 1, (data.rodata_blocks >> 8) & 0xFF);
  poke8(out + LBF_GEN_DATA_BLOCKS + 0, data.data_blocks & 0xFF);
  poke8(out + LBF_GEN_DATA_BLOCKS + 1, (data.data_blocks >> 8) & 0xFF);
  poke8(out + LBF_GEN_BSS_BLOCKS + 0, data.bss_blocks & 0xFF);
  poke8(out + LBF_GEN_BSS_BLOCKS + 1, (data.bss_blocks >> 8) & 0xFF);
  poke32(out + LBF_GEN_STACK_SIZE, data.stack_size);
  poke32(out + LBF_GEN_FILE_CRC32C, 0);   // Platzhalter; WP05 setzt finalen Wert

  // Provenance-Block
  var i: int64 := 0;
  while (i < 16) { poke8(out + LBF_GEN_COMPILER_NAME + i, peek8(data.compiler_name + i)); i := i + 1; }
  poke32(out + LBF_GEN_COMPILER_VER, data.compiler_version);
  poke64(out + LBF_GEN_COMPILED_AT, data.compiled_at);
  i := 0;
  while (i < 16) { poke8(out + LBF_GEN_COMPILER_UUID + i, peek8(data.compiler_uuid + i)); i := i + 1; }
  i := 0;
  while (i < 32) { poke8(out + LBF_GEN_SOURCE_SHA256 + i, peek8(data.source_sha256 + i)); i := i + 1; }

  // TLV-Verzeichnis
  poke8(out + LBF_GEN_TLV_OFFSET + 0, (LBF_GEN_TLV_POOL) & 0xFF);
  poke8(out + LBF_GEN_TLV_OFFSET + 1, (LBF_GEN_TLV_POOL >> 8) & 0xFF);
  poke8(out + LBF_GEN_TLV_USED + 0, data.tlv_used & 0xFF);
  poke8(out + LBF_GEN_TLV_USED + 1, (data.tlv_used >> 8) & 0xFF);

  // TLV-Pool kopieren
  i := 0;
  while (i < data.tlv_used) {
    poke8(out + LBF_GEN_TLV_POOL + i, peek8(data.tlv_buf + i));
    i := i + 1;
  }
}
```

**`genesis_deserialize(payload: pchar, out: LbfGenesisData)`** — liest alle Felder aus dem 4032-Byte-Puffer zurück in eine `LbfGenesisData`-Struktur

**`genesis_get_entry_point(payload: pchar) → int64`** — direkte Schnell-Abfrage ohne volle Deserialisierung

**`genesis_get_total_block_count(payload: pchar) → int64`** — `text + rodata + data + bss + 1` (Genesis)

### Abnahmekriterien

- [ ] `genesis_serialize()` + `genesis_deserialize()` Roundtrip: alle Felder byte-identisch
- [ ] `entry_point = 0x0000000000401000` korrekt serialisiert und deserialisiert (Little-Endian, 8 Bytes)
- [ ] `source_sha256`: alle 32 Bytes korrekt serialisiert (kein Off-by-One)
- [ ] `compiler_name = "lyxc"` wird als 16-Byte-Feld mit 0-Padding serialisiert: Bytes 4–15 = 0x00
- [ ] Puffer mit 4032 Bytes: nach `genesis_serialize()` sind alle nicht-gesetzten Bytes (Padding, unbenutzte TLV-Bytes) = 0x00
- [ ] `genesis_get_total_block_count()` gibt korrekte Summe zurück: text=3, rodata=1, data=1, bss=1 → 7 (inkl. Genesis)
- [ ] `LBF_GEN_FILE_CRC32C`-Feld ist nach `genesis_serialize()` exakt 0x00000000 (wird von WP05 nachgefüllt)

---

## WP03 — TLV-Framework

**Datei:** `tools/lbf/tlv.lyx`
**Abhängigkeiten:** WP02
**Geschätzter Aufwand:** 3–4 Tage

### Ziel

Ein vollständiges Type-Length-Value-Encoding-/Decoding-System für den 3904-Byte-KI-Kontext-Pool im Genesis-Block. Das Framework ist der Erweiterungspunkt für alle semantischen Metadaten des Formats.

### TLV-Encoding (Draht-Format)

```
[Type: uint8_t (1 Byte)] [Length: uint16_t LE (2 Bytes)] [Value: Length Bytes]
Overhead pro Eintrag: 3 Bytes
```

### Funktionen

**`tlv_append(pool: pchar, pool_used: pchar, type: int64, value: pchar, length: int64) → int64`**

```lyx
fn tlv_append(pool: pchar, pool_used: pchar, type: int64, value: pchar, length: int64): int64 {
  var used: int64 := peek64(pool_used);
  if (used + 3 + length > LBF_GEN_TLV_MAX_SIZE) { return -1; }  // ETLV_POOL_FULL
  poke8(pool + used, type);
  poke8(pool + used + 1, length & 0xFF);
  poke8(pool + used + 2, (length >> 8) & 0xFF);
  var i: int64 := 0;
  while (i < length) { poke8(pool + used + 3 + i, peek8(value + i)); i := i + 1; }
  poke64(pool_used, used + 3 + length);
  return 0;
}
```

**`tlv_find(pool: pchar, pool_used: int64, type: int64, out_value: pchar, out_length: pchar) → int64`**

Traversiert den Pool linear; gibt bei erstem Treffer Pointer und Länge zurück. Return 0 = gefunden, -1 = nicht gefunden.

**`tlv_count(pool: pchar, pool_used: int64) → int64`** — zählt Anzahl TLV-Einträge im Pool

**`tlv_iterate(pool: pchar, pool_used: int64, callback: pchar)`** — ruft Callback für jeden Eintrag auf

### Implementierung der Standard-TLV-Typen

**`tlv_add_intent(pool: pchar, pool_used: pchar, intent_text: pchar) → int64`**
- Begrenzt Länge auf 512 Bytes; kürzt mit 0-Terminator wenn länger
- Ruft `tlv_append(pool, pool_used, LBF_TLV_INTENT, intent_text, len)` auf

**`tlv_add_dependency(pool: pchar, pool_used: pchar, sha256: pchar, version_min: int64, alias: pchar) → int64`**
- Serialisiert einen 52-Byte-Dependency-Deskriptor: `sha256[32] + version[4] + alias[16]`
- Hängt via `tlv_append` an bestehenden TLV 0x02 an oder erstellt neuen Eintrag

**`tlv_add_section(pool: pchar, pool_used: pchar, block_start: int64, block_count: int64, sect_type: int64, prot: int64) → int64`**
- Serialisiert einen 8-Byte-Section-Deskriptor: `block_start[2] + block_count[2] + type[1] + prot[1] + align[2]`
- Hängt via `tlv_append` an bestehenden TLV 0x04 an

**`tlv_add_capabilities(pool: pchar, pool_used: pchar, cap_bits: int64) → int64`**
- Serialisiert `cap_bits` als 8-Byte-Little-Endian in TLV 0x05

**`tlv_add_embedding_lpid(pool: pchar, pool_used: pchar, embed_lpid: int64) → int64`**
- Serialisiert LPID (8 Bytes) in TLV 0x06

**`tlv_add_build_file(pool: pchar, pool_used: pchar, filename: pchar, sha256: pchar) → int64`**
- Serialisiert einen 96-Byte-Build-Manifest-Eintrag: `filename[64] + sha256[32]`

### Abnahmekriterien

- [ ] `tlv_append()` + `tlv_find()` Roundtrip für jeden der 7 Standard-Typen: Inhalt byte-identisch
- [ ] `tlv_count()` auf leerem Pool = 0; nach 3 Einträgen = 3
- [ ] Pool-Überlauf: `tlv_append()` bei Pool-Full → return -1, Pool-Inhalt unverändert
- [ ] `tlv_find()` auf nicht vorhandenem Typ → return -1
- [ ] Mehrere Einträge desselben Typs: `tlv_find()` gibt ersten zurück; `tlv_iterate()` findet alle
- [ ] `tlv_add_dependency()` zweimal aufgerufen: zwei separate 52-Byte-Blöcke im Pool, beide via `tlv_iterate()` abrufbar
- [ ] `tlv_add_section()` für 4 Sektionen (.text, .rodata, .data, .bss): Section-Deskriptor-Array korrekt serialisiert (32 Bytes gesamt), alle 4 Einträge via `tlv_iterate()` korrekt deserialisierbar
- [ ] Maximale Intent-Länge: 512 Bytes → kein Überlauf; 513 Bytes → auf 512 Bytes gekürzt, kein Absturz
- [ ] `tlv_append()` mit Length > verbleibendem Pool-Platz → return -1 ohne Teilschreiben

---

## WP04 — Section Block Emitter

**Datei:** `tools/lbf/sections.lyx`
**Abhängigkeiten:** WP01
**Geschätzter Aufwand:** 3–4 Tage

### Ziel

Erzeugung der Code- und Daten-Blöcke (Block 1 bis Block N) aus dem compilierten Maschinencode und den initialen Datenwerten. Jeder Block ist exakt 4096 Bytes groß (64-Byte-Header + 4032 Bytes Nutzdaten), CRC32C-gesichert und mit korrekten Schutzrechts-Flags versehen.

### Algorithmus: `section_emit()`

Eingabe: roher Byte-Strom (Maschinencode oder Datenwerte), Sektionstyp, Strom-Schreiber (Datei-Handle)

```lyx
fn section_emit(
  fd:           int64,       // Ausgabe-Datei-Descriptor
  data:         pchar,       // Roher Inhalt dieser Sektion
  data_len:     int64,       // Länge in Bytes
  sect_type:    int64,       // LBF_SECT_TEXT / _DATA / _RODATA / _BSS
  start_block:  int64,       // erster Block-Index dieser Sektion
  total_blocks: int64,       // Gesamtanzahl Blöcke der Datei
  compiled_at:  int64        // Timestamp für Block-Header
): int64 {                   // gibt Anzahl geschriebener Blöcke zurück

  var prot: int64;
  match sect_type {
    case LBF_SECT_TEXT   => { prot := LBF_PROT_READ | LBF_PROT_EXEC; }
    case LBF_SECT_RODATA => { prot := LBF_PROT_READ; }
    case LBF_SECT_DATA   => { prot := LBF_PROT_READ | LBF_PROT_WRITE; }
    case LBF_SECT_BSS    => { prot := LBF_PROT_READ | LBF_PROT_WRITE; }
    default => { return -1; }
  }

  var blocks_written: int64 := 0;
  var offset: int64 := 0;

  while (offset < data_len) {
    var block_buf: pchar := mmap(0, LBF_BLOCK_SIZE, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    var payload:   pchar := block_buf + LBF_HEADER_SIZE;

    // Payload: max. LBF_PAYLOAD_SIZE Bytes aus data, Rest 0-padded
    var chunk: int64 := data_len - offset;
    if (chunk > LBF_PAYLOAD_SIZE) { chunk := LBF_PAYLOAD_SIZE; }
    var i: int64 := 0;
    while (i < chunk) { poke8(payload + i, peek8(data + offset + i)); i := i + 1; }
    // Rest auf 0 padden
    while (i < LBF_PAYLOAD_SIZE) { poke8(payload + i, 0); i := i + 1; }

    // Block-Header
    lbf_header_init(block_buf, start_block + blocks_written, total_blocks, compiled_at, false);
    if (prot & LBF_PROT_WRITE == 0) { lbf_header_set_immutable(block_buf); }
    lbf_header_set_crc(block_buf, payload);

    // Schreiben
    write(fd, block_buf, LBF_BLOCK_SIZE);
    munmap(block_buf, LBF_BLOCK_SIZE);
    offset := offset + chunk;
    blocks_written := blocks_written + 1;
  }

  // .bss: kein Byte wird geschrieben (Kernel alloziert und zeroed zur Ladezeit)
  // Nur die Block-Anzahl im Genesis-Header wird gezählt
  return blocks_written;
}
```

### Sonder-Behandlung .bss

Die .bss-Sektion enthält keine Daten auf der Platte. Der Compiler trägt nur die Anzahl benötigter Blöcke in den Genesis-Header (`LBF_GEN_BSS_BLOCKS`) ein. Der Loader (WP07/WP10) alloziert und nulled den Speicher zur Ladezeit.

### Abnahmekriterien

- [ ] `section_emit()` für 4000 Bytes .text-Code: genau 1 Block (4096 Bytes), Bytes 64–4063 = Code-Bytes, Bytes 4064–4095 = 0x00
- [ ] `section_emit()` für 4033 Bytes .text-Code: exakt 2 Blöcke (8192 Bytes); Block 0 voll (4032 Bytes Code), Block 1 enthält 1 Code-Byte + 4031 Null-Bytes
- [ ] Immutable-Flag: .text und .rodata-Blöcke haben `Flags = 0x01`; .data-Blöcke haben `Flags = 0x00`
- [ ] CRC32C jedes Blocks: `lbf_header_validate()` auf jedem emittierten Block → return 0
- [ ] Block-Index: Block 0 dieser Sektion hat `block_index = start_block`, Block 1 hat `block_index = start_block + 1`
- [ ] `total_blocks` ist in jedem Block-Header identisch und korrekt
- [ ] .bss: `section_emit()` mit `sect_type=LBF_SECT_BSS` schreibt 0 Bytes in die Datei, gibt korrekte Block-Anzahl zurück (ceil(bss_size / 4032))

---

## WP05 — Supply Chain Security

**Datei:** `tools/lbf/security.lyx`
**Abhängigkeiten:** WP01, WP02, WP03
**Geschätzter Aufwand:** 3–4 Tage

### Ziel

Lückenlose Sicherheitskette vom Quellcode bis zur Ausführung: SHA-256 der Quelldateien, CRC32C der gesamten Binärdatei, Compiler-UUID-Verwaltung und Blacklist-Prüfung.

### SHA-256 der Quelldateien

Da lyxc keine native SHA-256-Implementierung hat, wird eine Lyx-Implementierung nach RFC 6234 bereitgestellt:

```lyx
// Externe ASM-Routine (analog zu crc32c_hw.o in IOFS WP03)
extern fn sha256_buf(data: pchar, len: int64, out: pchar) link "tools/lbf/sha256_hw.o";

fn lbf_compute_source_hash(source_files: array, out_sha256: pchar) {
  // Alle Quelldatei-Inhalte konkateniert hashen
  var total_len: int64 := 0;
  var i: int64 := 0;
  while (i < len(source_files)) {
    total_len := total_len + FileSize(source_files[i]);
    i := i + 1;
  }
  var concat_buf: pchar := mmap(0, total_len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  var pos: int64 := 0;
  i := 0;
  while (i < len(source_files)) {
    var fd: int64 := open(source_files[i], 0, 0);
    var fsize: int64 := FileSize(source_files[i]);
    read(fd, concat_buf + pos, fsize);
    close(fd);
    pos := pos + fsize;
    i := i + 1;
  }
  sha256_buf(concat_buf, total_len, out_sha256);
  munmap(concat_buf, total_len);
}
```

### Gesamt-CRC32C der Binärdatei

Nach dem Schreiben aller Blöcke: CRC32C über den gesamten Dateiinhalt (alle Bytes aller Blöcke, beginnend ab Offset 0x0040 von Block 0, d.h. der Genesis-Content), wobei das `LBF_GEN_FILE_CRC32C`-Feld temporär 0 gesetzt ist.

```lyx
fn lbf_finalize_file_crc(filepath: pchar) {
  var total_size: int64 := FileSize(filepath);
  var fd: int64 := open(filepath, 2, 0);  // O_RDWR
  var buf: pchar := mmap(0, total_size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  read(fd, buf, total_size);

  // File-CRC-Feld im Genesis-Payload (Offset 0x0040 + LBF_GEN_FILE_CRC32C) auf 0 setzen
  poke32(buf + LBF_HEADER_SIZE + LBF_GEN_FILE_CRC32C, 0);

  // CRC über alle Payload-Bytes (alle Blöcke, jeweils ab Offset 0x0040)
  var crc: int64 := 0;
  var block_idx: int64 := 0;
  var total_blocks: int64 := total_size / LBF_BLOCK_SIZE;
  while (block_idx < total_blocks) {
    crc := crc32c_buf_update(crc, buf + block_idx * LBF_BLOCK_SIZE + LBF_HEADER_SIZE, LBF_PAYLOAD_SIZE);
    block_idx := block_idx + 1;
  }

  // In Genesis-Payload schreiben
  poke32(buf + LBF_HEADER_SIZE + LBF_GEN_FILE_CRC32C, crc);

  // Datei neu schreiben
  lseek(fd, 0, 0);
  write(fd, buf, total_size);
  close(fd);
  munmap(buf, total_size);
}
```

### Compiler-UUID (Instanz-Seriennummer)

```lyx
fn lbf_generate_compiler_uuid(out_uuid: pchar) {
  // UUID v4: 16 zufällige Bytes, Bits 6-7 des Byte 8 = 10 (RFC 4122 Variant)
  var i: int64 := 0;
  while (i < 16) { poke8(out_uuid + i, Random() & 0xFF); i := i + 1; }
  poke8(out_uuid + 6, (peek8(out_uuid + 6) & 0x0F) | 0x40);  // Version 4
  poke8(out_uuid + 8, (peek8(out_uuid + 8) & 0x3F) | 0x80);  // Variant 1
}
```

Die UUID wird einmalig beim Compiler-Start generiert und für alle in dieser Session kompilierten Binaries verwendet.

### Blacklist-Prüfung

```lyx
// Blacklist: flache Liste aus 16-Byte-UUIDs, gespeichert in der Panic-Sandbox (WP11 IOFS)
// Auf POSIX: ~/.lyx/compiler_blacklist.bin oder /etc/lyx/compiler_blacklist.bin
fn lbf_check_compiler_blacklist(uuid: pchar) → bool {
  var bl_path: pchar := "/etc/lyx/compiler_blacklist.bin";
  if (!FileExists(bl_path)) { return true; }  // keine Blacklist = alles erlaubt
  var bl_size: int64 := FileSize(bl_path);
  var fd: int64 := open(bl_path, 0, 0);
  var buf: pchar := mmap(0, bl_size, PROT_READ, MAP_PRIVATE, fd, 0);
  var found: bool := false;
  var i: int64 := 0;
  while (i + 16 <= bl_size) {
    var match: bool := true;
    var j: int64 := 0;
    while (j < 16) {
      if (peek8(buf + i + j) != peek8(uuid + j)) { match := false; }
      j := j + 1;
    }
    if (match) { found := true; }
    i := i + 16;
  }
  munmap(buf, bl_size);
  close(fd);
  return !found;  // true = vertrauenswürdig, false = auf Blacklist
}
```

### Abnahmekriterien

- [ ] `lbf_compute_source_hash()` auf denselben Quelldateien: identisches SHA-256-Ergebnis bei jedem Aufruf (Determinismus)
- [ ] Änderung eines einzelnen Bytes in einer Quelldatei: anderes SHA-256-Ergebnis
- [ ] `lbf_finalize_file_crc()`: CRC32C-Feld im Genesis-Block korrekt gesetzt; nachfolgende erneute Berechnung derselben Datei liefert identischen CRC (Idempotenz)
- [ ] `lbf_finalize_file_crc()` auf manipulierter Datei (1 Bit geflippt in Block 2): CRC-Mismatch beim Validieren
- [ ] `lbf_generate_compiler_uuid()`: 1000 generierte UUIDs sind alle unterschiedlich (kein Duplikat)
- [ ] `lbf_check_compiler_blacklist()` mit bekannter UUID aus der Blacklist → return false (gesperrt)
- [ ] `lbf_check_compiler_blacklist()` mit unbekannter UUID → return true (erlaubt)
- [ ] `lbf_check_compiler_blacklist()` ohne Blacklist-Datei → return true (erlaubt, kein Absturz)

---

## WP06 — lyxc LBF-Backend (Compiler-Integration)

**Datei:** lyxc-intern (Backend-Modul), gesteuert via `--target=lyxos` oder `--emit-lbf`
**Abhängigkeiten:** WP01–WP05
**Geschätzter Aufwand:** 6–8 Tage

### Ziel

Integration des LBF-Emitters als vollständiges Compiler-Backend in lyxc. Ersetzt das bisherige ELF-Backend für das `--target=lyxos`-Ziel. Der Compiler befüllt alle Strukturen aus WP01–WP05 und schreibt eine vollständige, valide LBF-Datei.

### Compiler-Flags

```bash
lyxc main.lyx -o main.lbf                          # Standard: --target=lyxos → LBF
lyxc main.lyx --target=lyxos -o main.lbf           # Explizit
lyxc main.lyx --target=linux -o main.elf            # Weiterhin ELF für Linux
lyxc main.lyx --emit-lbf --lbf-dump                 # Emittiert LBF und dumppt Header
lyxc main.lyx --target=lyxos --debug -o main.lbf    # Mit TLV 0x08 Debug-Symbolen
```

### Intent-Extraktion aus Doc-Comments

Der Parser extrahiert `///`-Kommentare über der `main()`-Funktion als Intent-String für TLV 0x01:

```lyx
// Aus main.lyx:
/// Berechnet die CRC32C-Prüfsumme für Speichermedien im IOFS.
/// Liest Eingabe von stdin, gibt Prüfsumme als Hex auf stdout aus.
fn main(): int64 { ... }

// lyxc extrahiert: "Berechnet die CRC32C-Prüfsumme für Speichermedien im IOFS.\nLiest Eingabe von stdin, gibt Prüfsumme als Hex auf stdout aus."
```

Wenn kein Doc-Comment vorhanden: Intent = Dateiname ohne Erweiterung (z.B. `"main"`).

### Backend-Ablauf

```
1.  Quellcode parsen (vorhandener lyxc-Frontend-Mechanismus)
    Bereits implementiert: LX-01 (ELF-Header + .note.lyx-abi), LX-02 (IR-Dispatch),
    LX-03 (_start-Stub: getrandom → call main → exit_group → implizit ONE_SHOT)
2.  IR-Code-Generierung (vorhandener IR-Pass)
3.  x86-64-Maschinencode-Ausgabe (vorhandener Codegen)
4.  [NEU] Statistiken sammeln: code_size, data_size, rodata_size, bss_size (in Bytes)
5.  [NEU] Block-Anzahlen berechnen: ceil(code_size / LBF_PAYLOAD_SIZE), etc.
6.  [NEU] Compiler-UUID generieren (WP05: lbf_generate_compiler_uuid)
7.  [NEU] SHA-256 der Quelldateien berechnen (WP05: lbf_compute_source_hash)
8.  [NEU] TLV-Pool aufbauen (WP03):
      - tlv_add_intent(): aus Doc-Comment
      - tlv_add_section(): für jede Sektion
      - tlv_add_capabilities(): aus @capability-Annotationen am Quellcode
      - tlv_add_dependency(): für alle import-Statements
      - tlv_add_lifecycle(): aus @lifecycle/@on_event/@quiescence_stack (WP12)
        Ohne Annotation: kind=ONE_SHOT, count=0 (entspricht LX-03 _start-Stub)
9.  [NEU] Genesis-Content serialisieren (WP02: genesis_serialize)
10. [NEU] Block 0 schreiben: Header (WP01) + Genesis-Content (WP02)
11. [NEU] .text-Blöcke emittieren (WP04: section_emit)
12. [NEU] .rodata-Blöcke emittieren (WP04)
13. [NEU] .data-Blöcke emittieren (WP04)
14. [NEU] Gesamt-CRC32C finalisieren (WP05: lbf_finalize_file_crc)
```

### Capability-Annotation im Quellcode

```lyx
@capability(LBF_CAP_FS_READ | LBF_CAP_NET_SOCKET)
fn main(): int64 { ... }
```

Ohne `@capability`-Annotation: lyxc leitet Capabilities automatisch aus dem verwendeten Standard-Bibliotheks-API ab (z.B. `import std.net.socket` → `LBF_CAP_NET_SOCKET` gesetzt).

### Abnahmekriterien

- [ ] `lyxc hello.lyx -o hello.lbf`: Ausgabedatei existiert, Größe ist Vielfaches von 4096
- [ ] `lbf_header_validate()` auf Block 0 der Ausgabe → return 0 (CRC32C korrekt)
- [ ] Genesis-Block: `entry_point` zeigt auf korrekte virtuelle Adresse der `main()`-Funktion
- [ ] `lbf_finalize_file_crc()` bereits integriert: CRC32C-Feld im Genesis ≠ 0
- [ ] Doc-Comment-Test: `///`-Kommentar über `main()` → TLV 0x01 mit korrektem UTF-8-String im Genesis-Block
- [ ] `import std.net.socket`-Test: TLV 0x05 enthält gesetztes `LBF_CAP_NET_SOCKET`-Bit
- [ ] Section-Table-Test: TLV 0x04 enthält 4 Einträge (.text R/X, .rodata R, .data R/W, .bss R/W); `block_start`-Werte aufsteigend und lückenfrei
- [ ] Reproduzierbarkeit: zweimaliges Kompilieren derselben Quelldatei (ohne Timestamp-Unterschied): byte-identische Ausgabe (deterministischer Build)

---

## WP07 — POSIX-Loader (lbf_run)

**Datei:** `tools/lbf_run.lyx`
**Abhängigkeiten:** WP01, WP04, WP05
**Geschätzter Aufwand:** 3–5 Tage

### Ziel

Ein schlanker POSIX-Loader, der eine LBF-Datei auf Linux/macOS/Windows ausführt. Er nutzt `mmap()` mit korrekten Schutzrechten und springt zum Entry-Point. Kein IOFS-Kernel nötig, kein Graph-Lookup — reiner POSIX-Kompatibilitätspfad.

### Ladesequenz

```lyx
fn main(): int64 {
  if (GetArgC() < 2) { EPrintLn("Usage: lbf_run <binary.lbf> [args...]"); return 1; }
  var path: pchar := GetArg(1);

  // 1. Datei öffnen und Größe prüfen
  var fd: int64 := open(path, 0, 0);
  if (fd < 0) { EPrintLn("lbf_run: cannot open file"); return 1; }
  var file_size: int64 := FileSize(path);
  if (file_size % LBF_BLOCK_SIZE != 0) { EPrintLn("lbf_run: size not 4KB-aligned"); return 1; }

  // 2. Gesamt-Datei mappen (read-only zunächst)
  var file_map: pchar := mmap(0, file_size, PROT_READ, MAP_PRIVATE, fd, 0);

  // 3. Block 0 validieren
  if (lbf_header_validate(file_map) != 0) { EPrintLn("lbf_run: genesis header invalid"); return 1; }
  if (!lbf_header_is_genesis(file_map)) { EPrintLn("lbf_run: block 0 is not genesis"); return 1; }

  // 4. Gesamt-CRC32C prüfen (WP05)
  if (lbf_verify_file_crc(file_map, file_size) != 0) { EPrintLn("lbf_run: file CRC mismatch"); return 1; }

  // 5. Compiler-UUID gegen Blacklist prüfen
  var uuid_ptr: pchar := file_map + LBF_HEADER_SIZE + LBF_GEN_COMPILER_UUID;
  if (!lbf_check_compiler_blacklist(uuid_ptr)) { EPrintLn("lbf_run: compiler blacklisted"); return 1; }

  // 6. Genesis-Content lesen
  var genesis: pchar := file_map + LBF_HEADER_SIZE;
  var entry_point: int64 := peek64(genesis + LBF_GEN_ENTRY_POINT);
  var stack_size: int64 := peek32(genesis + LBF_GEN_STACK_SIZE);
  if (stack_size == 0) { stack_size := 131072; }  // Default: 128 KB

  // 7. Section-Table aus TLV 0x04 lesen
  var sect_data: pchar := mmap(0, 256, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  var sect_len: int64 := 0;
  tlv_find(genesis + LBF_GEN_TLV_POOL, peek16(genesis + LBF_GEN_TLV_USED),
           LBF_TLV_SECTIONS, sect_data, &sect_len);
  var sect_count: int64 := sect_len / 8;

  // 8. Jede Sektion mit korrekten mmap-Flags mappen
  var base_va: int64 := 0x0000000000400000;  // Standard Linux User-Space Base
  var i: int64 := 0;
  while (i < sect_count) {
    var block_start: int64 := peek8(sect_data + i*8 + 0) | (peek8(sect_data + i*8 + 1) << 8);
    var block_count: int64 := peek8(sect_data + i*8 + 2) | (peek8(sect_data + i*8 + 3) << 8);
    var sect_type:   int64 := peek8(sect_data + i*8 + 4);
    var prot:        int64 := peek8(sect_data + i*8 + 5);

    if (sect_type == LBF_SECT_BSS) {
      // .bss: anonymes, zeroed Mapping
      mmap(base_va + block_start * LBF_PAYLOAD_SIZE, block_count * LBF_PAYLOAD_SIZE,
           PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED, -1, 0);
    } else {
      // Datei-Mapping der Blocks
      var posix_prot: int64 := 0;
      if (prot & LBF_PROT_READ  != 0) { posix_prot := posix_prot | 1; }
      if (prot & LBF_PROT_WRITE != 0) { posix_prot := posix_prot | 2; }
      if (prot & LBF_PROT_EXEC  != 0) { posix_prot := posix_prot | 4; }
      var file_offset: int64 := block_start * LBF_BLOCK_SIZE + LBF_HEADER_SIZE;
      mmap(base_va + block_start * LBF_PAYLOAD_SIZE, block_count * LBF_PAYLOAD_SIZE,
           posix_prot, MAP_PRIVATE|MAP_FIXED, fd, file_offset);
    }
    i := i + 1;
  }

  // 9. Stack allozieren
  var stack: pchar := mmap(0, stack_size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);

  // 10. Zu Entry-Point springen (via Funktionspointer-Aufruf)
  // [Plattform-spezifisch: Entry-Point-Aufruf via indirektem Sprung]
  return 0;
}
```

### Abnahmekriterien

- [ ] `lbf_run hello.lbf`: Programm startet, gibt "Hello" aus, Exit-Code 0
- [ ] `lbf_run nonexistent.lbf`: Fehlermeldung auf stderr, kein Absturz, Exit-Code 1
- [ ] `lbf_run manipulated.lbf` (1 Bit im .text-Block geflippt): CRC-Fehler abgefangen, Ausführung verweigert
- [ ] .bss-Sektion: Global-Variable ohne Initializer = 0 zur Laufzeit (via MAP_ANON korrekt zeroed)
- [ ] .rodata-Sektion: Schreibversuch auf konstante Variable → SIGSEGV (mprotect schützt korrekt)
- [ ] Stack-Overflow-Test: Deep-Recursion bis Stack-Grenze → definiertes Verhalten (SIGSEGV, kein stiller Korruption anderer Segmente)
- [ ] Blacklisted-UUID-Test: Datei mit bekannter Blacklist-UUID → Ausführungsverbot, Fehlermeldung
- [ ] Exit-Code: Rückgabewert von `main()` als Prozess-Exit-Code weitergereicht

---

## WP08 — IOFS-Import Tool (lbf_import)

**Datei:** `tools/lbf_import.lyx`
**Abhängigkeiten:** WP01–WP05, IOFS WP03 (Page-IO-Manager), IOFS WP06 (Graph-Engine)
**Geschätzter Aufwand:** 4–6 Tage

### Ziel

Konvertierung einer POSIX-LBF-Datei in IOFS-native Pages (Typ `0x04 = LBF_Executable`) und Einbindung in den IOFS-Graphen. Nach dem Import ist das Programm als zusammenhängender Knoten-Cluster im Graphen präsent und kann vom Zero-Load Executor (WP10) geladen werden.

### Import-Ablauf

```lyx
fn lbf_import(posix_path: pchar, island_name: pchar): int64 {
  // 1. POSIX-Datei einlesen und validieren (WP01, WP05)
  var fd: int64 := open(posix_path, 0, 0);
  var file_size: int64 := FileSize(posix_path);
  if (file_size % LBF_BLOCK_SIZE != 0) { return -1; }
  if (lbf_header_validate(mmap(0, LBF_BLOCK_SIZE, ...)) != 0) { return -2; }
  if (lbf_verify_file_crc(...) != 0) { return -3; }

  var total_blocks: int64 := file_size / LBF_BLOCK_SIZE;

  // 2. Programm-Struktur-Knoten im Graphen anlegen
  var prog_lpid: int64 := graph_node_create(0x01);  // Typ=Meta: Programm-Knoten
  // Payload: Name des Programms (aus Dateiname oder TLV 0x01 first line)
  graph_node_set_payload(prog_lpid, island_name, StrLen(island_name));

  // 3. Jeden Block als IOFS-Page importieren
  var prev_block_lpid: int64 := 0;
  var i: int64 := 0;
  while (i < total_blocks) {
    var file_offset: int64 := i * LBF_BLOCK_SIZE;
    var posix_header: pchar := ...; // Bytes [file_offset .. file_offset+64]
    var payload: pchar := ...;      // Bytes [file_offset+64 .. file_offset+4096]

    // Neuen LPID vergeben
    var block_lpid: int64 := lip_alloc_lpid();
    var lba: int64 := alloc_page();
    lip_set(block_lpid, lba);

    // IOFS-Page aufbauen (4096 Bytes):
    var page_buf: pchar := mmap(0, 4096, ...);
    page_set_magic(page_buf);                           // "LYX!"
    poke8(page_buf + 0x0004, IOFS_PAGE_TYPE_LBF_EXEC); // Typ = 0x04
    // Flags aus LBF-Block-Header übernehmen
    poke8(page_buf + 0x0005, peek8(posix_header + LBF_HDR_FLAGS));
    poke8(page_buf + 0x0006, 0x40); poke8(page_buf + 0x0007, 0x00);
    poke64(page_buf + 0x0008, block_lpid);
    poke16(page_buf + 0x0010, LBF_PAYLOAD_SIZE);  // 4032
    poke32(page_buf + 0x001C,                     // LBF_Meta_Offset
      (i == 0) ? 0x0040 : 0x0000);
    poke64(page_buf + 0x0020, 0);                 // Continuation (wird gesetzt wenn nötig)
    // Payload kopieren
    var j: int64 := 0;
    while (j < LBF_PAYLOAD_SIZE) {
      poke8(page_buf + 0x0040 + j, peek8(payload + j));
      j := j + 1;
    }
    // CRC32C der gesamten IOFS-Page berechnen und setzen
    poke32(page_buf + 0x0018, 0);
    poke32(page_buf + 0x0018, crc32c_page(page_buf));
    // Auf NVMe schreiben
    iofs_write_page_raw(block_lpid, lba, page_buf);

    // Kante: Programm-Knoten → Block oder Block → nächster Block
    if (i == 0) {
      graph_edge_add(prog_lpid, block_lpid, LBF_EDGE_BLOCK_CHAIN);
    } else {
      graph_edge_add(prev_block_lpid, block_lpid, LBF_EDGE_BLOCK_CHAIN);
    }
    prev_block_lpid := block_lpid;

    munmap(page_buf, 4096);
    i := i + 1;
  }

  // 4. Programm-Knoten in Island einhängen
  var island_lpid: int64 := iofs_find_island(island_name);
  if (island_lpid != 0) {
    graph_edge_add(island_lpid, prog_lpid, 0xF001);  // VFS-Kante
  }

  // 5. Embedding für TLV 0x01 (Intent) anfordern (async, WP15)
  var intent_data: pchar := ...;  // aus TLV 0x01 extrahiert
  if (intent_data != 0) {
    embedding_request_async(intent_data, StrLen(intent_data), prog_lpid);
  }

  return prog_lpid;
}
```

### Abnahmekriterien

- [ ] `lbf_import("hello.lbf", "tools")`: gibt valide LPID des Programm-Knotens zurück
- [ ] Anzahl IOFS-Pages nach Import = `total_blocks` (ein Page pro Block)
- [ ] Jede importierte IOFS-Page hat Typ=0x04, Magic="LYX!", valide CRC32C
- [ ] Block-0-Page hat `LBF_Meta_Offset=0x0040`; alle anderen Pages haben `LBF_Meta_Offset=0x0000`
- [ ] `graph_neighbors(prog_lpid)` gibt LPID von Block 0 zurück (Kante 0xB001)
- [ ] `graph_neighbors(block_0_lpid)` gibt LPID von Block 1 zurück (Kante 0xB001)
- [ ] Kette traversierbar: Von `prog_lpid` via 0xB001-Kanten alle `total_blocks` Blöcke erreichbar
- [ ] Import korrupter Datei (manipulierter CRC): `lbf_import()` bricht vor erstem Page-Write ab, kein halbfertiger Zustand im Graphen
- [ ] Nach Import: `iofs_read_page(block_0_lpid)` liest Genesis-Payload korrekt zurück (byte-identisch mit POSIX-Payload)

---

## WP09 — Dependency Resolver

**Datei:** `tools/lbf/dep_resolver.lyx`
**Abhängigkeiten:** WP08, IOFS WP06 (Graph-Engine)
**Geschätzter Aufwand:** 3–4 Tage

### Ziel

Auflösung der in TLV 0x02 (Dependency Hash Graph) gespeicherten SHA-256-Abhängigkeitshashes zu echten LPIDs im IOFS-Graphen. Einweben der Dependency-Kanten in den Programm-Graphen.

### Algorithmus

Die Suche nutzt einen globalen Index-Knoten im Graphen (`IOFS_HASH_INDEX_LPID`), der als Hash-Map aus `SHA-256 → Programm-LPID` realisiert ist:

```lyx
fn dep_resolve_all(prog_lpid: int64): int64 {
  // 1. TLV 0x02 aus Genesis-Block des Programms lesen
  var genesis_page: pchar := mmap(0, 4096, ...);
  iofs_read_page(lbf_get_genesis_lpid(prog_lpid), genesis_page);
  var genesis_payload: pchar := genesis_page + 0x0040;

  var dep_data: pchar := mmap(0, 4096, ...);
  var dep_len: int64 := 0;
  tlv_find(genesis_payload + LBF_GEN_TLV_POOL,
           peek16(genesis_payload + LBF_GEN_TLV_USED),
           LBF_TLV_DEPS, dep_data, &dep_len);

  var dep_count: int64 := dep_len / 52;
  var i: int64 := 0;
  var missing: int64 := 0;

  while (i < dep_count) {
    var sha256: pchar := dep_data + i * 52;
    var version_min: int64 := peek32(dep_data + i * 52 + 32);
    var alias: pchar := dep_data + i * 52 + 36;

    // 2. Hash → LPID im globalen Hash-Index nachschlagen
    var dep_lpid: int64 := dep_index_lookup(sha256);

    if (dep_lpid == 0) {
      EPrint("lbf_import: missing dependency: ");
      EPrintLn(alias);
      missing := missing + 1;
    } else {
      // 3. Dependency-Kante weben: Programm-Knoten → Dependency-Genesis
      graph_edge_add(prog_lpid, dep_lpid, LBF_EDGE_DEPENDENCY);
    }
    i := i + 1;
  }

  munmap(dep_data, 4096);
  munmap(genesis_page, 4096);
  return missing;  // 0 = alle aufgelöst
}
```

**`dep_index_register(sha256: pchar, prog_lpid: int64)`** — beim Import eines neuen Programms: SHA-256 → LPID in globalem Index registrieren

**`dep_index_lookup(sha256: pchar) → int64`** — O(1)-Suche via FNV-1a-Hash der SHA-256-Bytes → IOFS-Hash-Node

### Abnahmekriterien

- [ ] Programm A importiert, dann Programm B (das von A abhängt) importiert: `dep_resolve_all(B)` gibt 0 zurück (alle aufgelöst); `graph_neighbors(B_genesis_lpid)` enthält A_genesis_lpid mit Kante 0xD001
- [ ] Programm mit fehlender Dependency: `dep_resolve_all()` gibt 1 zurück, Fehlermeldung auf stderr mit Dependency-Alias
- [ ] `dep_index_register()` + `dep_index_lookup()` Roundtrip: identischer LPID zurückgegeben
- [ ] `dep_index_lookup()` mit unbekanntem SHA-256 → return 0 (kein Panic)
- [ ] 100 registrierte Dependencies, `dep_index_lookup()` für alle 100: alle korrekt gefunden (kein Hash-Kollisions-Fehler)
- [ ] Version-Mismatch: installierte Dependency hat `version < version_min` → Fehler, Kante wird nicht gesetzt

---

## WP10 — Zero-Load Executor (IOFS-Kernel)

**Datei:** `kernel/lbf_exec.lyx`
**Abhängigkeiten:** WP08, WP09, IOFS WP10 (Graph-Engine), IOFS WP13 (Semantische Firewall)
**Geschätzter Aufwand:** 6–8 Tage

### Ziel

Die Implementierung von `sys_exec()` für LBF-Programme auf nativem IOFS. Kein Kopieren von Segmenten, kein Parsen von Tabellen zur Laufzeit. Der Kernel mappt die physischen NVMe-Sektoradressen (LBAs) direkt in die CPU-Page-Tables (CR3-Struktur).

### sys_exec() — LBF-Ladesequenz im Kernel

```lyx
fn sys_exec(prog_lpid: int64, argv: pchar, argc: int64): int64 {
  // 1. Genesis-Block lesen
  var genesis_block_lpid: int64 := lbf_get_genesis_lpid(prog_lpid);
  var genesis_page: pchar := kernel_alloc_page();
  iofs_read_page(genesis_block_lpid, genesis_page);
  var genesis: pchar := genesis_page + 0x0040;

  // 2. Semantische Firewall prüfen (IOFS WP13)
  var intent_lpid: int64 := embedding_get_struct_lpid(prog_lpid);
  var cap_bits: int64 := 0;
  var cap_data: pchar := kernel_alloc(8);
  tlv_find(genesis + LBF_GEN_TLV_POOL, peek16(genesis + LBF_GEN_TLV_USED),
           LBF_TLV_CAPABILITIES, cap_data, 0);
  cap_bits := peek64(cap_data);

  if (!firewall_check_program(intent_lpid, cap_bits)) {
    kernel_free(cap_data);
    kernel_free_page(genesis_page);
    return -1;  // EPERM: Firewall verweigert Ausführung
  }

  // 3. Neues CR3-Page-Table-Root erstellen
  var cr3: int64 := kernel_alloc_page_table();

  // 4. Section-Table aus TLV 0x04 lesen
  var sect_data: pchar := kernel_alloc(256);
  var sect_len: int64 := 0;
  tlv_find(genesis + LBF_GEN_TLV_POOL, peek16(genesis + LBF_GEN_TLV_USED),
           LBF_TLV_SECTIONS, sect_data, &sect_len);
  var sect_count: int64 := sect_len / 8;

  // 5. Block-LPIDs aus Kanten-Chain sammeln
  var block_lpids: array;  // von int64
  var current_lpid: int64 := genesis_block_lpid;
  push(block_lpids, current_lpid);
  var neighbors: pchar := kernel_alloc(4096);
  var n: int64 := 0;
  graph_neighbors(prog_lpid, neighbors, &n);
  // (vereinfacht: traversiere 0xB001-Ketten bis Ende)

  // 6. Jede Sektion per LBA direkt in Page-Table eintragen
  var base_va: int64 := 0x0000000000400000;
  var i: int64 := 0;
  while (i < sect_count) {
    var block_start: int64 := peek8(sect_data + i*8 + 0) | (peek8(sect_data + i*8 + 1) << 8);
    var block_count: int64 := peek8(sect_data + i*8 + 2) | (peek8(sect_data + i*8 + 3) << 8);
    var sect_type:   int64 := peek8(sect_data + i*8 + 4);
    var prot:        int64 := peek8(sect_data + i*8 + 5);

    var j: int64 := 0;
    while (j < block_count) {
      var blk_lpid: int64 := peek64(block_lpids_arr + (block_start + j) * 8);
      var lba: int64 := lip_get(blk_lpid);   // O(1) LIP-Übersetzung

      if (sect_type == LBF_SECT_BSS) {
        // .bss: neues zeroed RAM-Frame zuweisen, kein LBA-Mapping
        var phys_frame: int64 := kernel_alloc_zero_frame();
        cr3_map_page(cr3,
          base_va + (block_start + j) * LBF_PAYLOAD_SIZE,
          phys_frame * 4096,
          prot);
      } else {
        // Direktes LBA-zu-PA-Mapping: NVMe-Sektor = physischer RAM-Frame (DMA-Mapping)
        cr3_map_page(cr3,
          base_va + (block_start + j) * LBF_PAYLOAD_SIZE,
          lba * LBF_BLOCK_SIZE + LBF_HEADER_SIZE,   // PA: Sektor-Start + Header-Offset
          prot);
      }
      j := j + 1;
    }
    i := i + 1;
  }

  // 7. Stack allozieren
  var stack_size: int64 := peek32(genesis + LBF_GEN_STACK_SIZE);
  if (stack_size == 0) { stack_size := 131072; }
  var stack_va: int64 := 0x00007FFFFFFFFFFF - stack_size;
  var stack_frame: int64 := kernel_alloc_frames(stack_size / 4096);
  cr3_map_range(cr3, stack_va, stack_frame * 4096, stack_size, LBF_PROT_READ | LBF_PROT_WRITE);

  // 8. Prozess-Struktur anlegen, CR3 laden, zu Entry-Point springen
  var entry: int64 := peek64(genesis + LBF_GEN_ENTRY_POINT);
  kernel_create_process(cr3, entry, stack_va + stack_size, argv, argc);

  return 0;
}
```

### Abnahmekriterien

- [ ] `sys_exec(hello_lpid, ...)`: Programm "Hello World" startet und gibt Text aus, Exit-Code 0
- [ ] Kein Kopieren: RAM-Nutzung des Kernels steigt beim Laden von 100 Instanzen desselben LBF-Programms nicht proportional (Seiten werden geshared, nicht kopiert)
- [ ] .rodata-Schreib-Schutz: Write-Versuch eines Prozesses auf .rodata-Adresse → Page-Fault-Handler terminiert Prozess, Kernel läuft weiter
- [ ] .bss-Initialisierung: Global-Variable ohne Initializer = 0 bei Prozessstart (MAP_ZERO korrekt)
- [ ] Firewall-Integration: Programm mit `LBF_CAP_NET_SOCKET` ohne entsprechenden Intent → Firewall verweigert; mit Intent "network client" + Capability → erlaubt
- [ ] Dependency-Check: Programm mit fehlender Dependency (nicht im Graphen) → `sys_exec()` return -1
- [ ] Ladezeit-Messung: Laden eines 10-Block-Programms (40 KB) < 1ms (nur LIP-Lookups + PTE-Writes, kein memcpy)
- [ ] Multi-Process: 10 simultane Instanzen desselben Programms: alle laufen korrekt, keine gegenseitige Korruption

---

## WP11 — lbf-dump Inspection Tool

**Datei:** `tools/lbf_dump.lyx`
**Abhängigkeiten:** WP01–WP05
**Geschätzter Aufwand:** 2–3 Tage

### Ziel

Ein Kommandozeilen-Werkzeug zur vollständigen Inspektion, Validierung und menschenlesbaren Darstellung einer LBF-Datei. Analogon zu `readelf` für ELF oder `otool` für Mach-O.

### Ausgabe-Format

```
$ lbf_dump hello.lbf

=== LBF DUMP: hello.lbf ===

[Block Header — Block 0]
  Magic:         LBF1 (0x4C 0x42 0x46 0x31)  ✓
  IOFS Page Type: 0x04 (LBF_Executable)
  Flags:         0x00 (mutable)
  Block Index:   0 / 6 total
  Block CRC32C:  0x8A3F12C4  ✓ (verified)
  LBF Meta Offset: 0x0040 (Genesis Block)

[Genesis Content]
  Content Type:    0x01 (Genesis)
  Target Arch:     0x01 (x86-64)
  OS Version Min:  0x0100 (v1.0)
  Entry Point:     0x0000000000401040
  File Size:       24576 bytes (6 blocks)
  Sections:        .text=3, .rodata=1, .data=1, .bss=1
  Stack Size:      131072 bytes (128 KB)
  File CRC32C:     0x3F8A21B7  ✓ (verified)

[Compiler Provenance]
  Compiler Name:   lyxc
  Version:         0x000803 (0.8.3)
  Compiled At:     2026-06-09 14:32:07 UTC
  Instance UUID:   a3f72b18-4c91-4d2e-8e7b-1234567890ab
  Source SHA-256:  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

[Security]
  Compiler UUID:   ✓ (not blacklisted)
  File CRC32C:     ✓ (matches)
  All Block CRCs:  ✓ (6/6 valid)

[TLV Entries]
  [0x01] Intent (48 bytes):
         "Prints Hello World to stdout."
  [0x04] Section Table (32 bytes, 4 entries):
         .text:   blocks 1–3  (R/X)
         .rodata: blocks 4–4  (R)
         .data:   blocks 5–5  (R/W)
         .bss:    blocks 6–6  (R/W, zeroed)
  [0x05] Capabilities (8 bytes):
         0x0000000000000000 (none)

[Block Inventory]
  Block 0: Genesis       — CRC ✓
  Block 1: .text  [1/3]  — CRC ✓  Immutable
  Block 2: .text  [2/3]  — CRC ✓  Immutable
  Block 3: .text  [3/3]  — CRC ✓  Immutable
  Block 4: .rodata[1/1]  — CRC ✓  Immutable
  Block 5: .data  [1/1]  — CRC ✓
  Block 6: .bss   [1/1]  — no data on disk
```

### Funktionen

**`lbf_dump_block_header(buf: pchar, block_index: int64)`** — gibt Block-Header menschenlesbar aus

**`lbf_dump_genesis(payload: pchar)`** — gibt alle Genesis-Felder aus

**`lbf_dump_tlv_all(pool: pchar, pool_used: int64)`** — iteriert und dekodiert alle TLV-Einträge

**`lbf_dump_inventory(filepath: pchar)`** — zeigt alle Blöcke mit Typ und CRC-Status

**`lbf_dump_verify_all(filepath: pchar) → int64`** — führt alle Prüfungen durch, gibt Anzahl der Fehler zurück (0 = alles OK)

### Abnahmekriterien

- [ ] `lbf_dump hello.lbf`: Ausgabe enthält Magic, Entry-Point, alle 7 möglichen TLV-Typen korrekt dekodiert
- [ ] `lbf_dump` auf manipulierter Datei (Block 2 CRC geflippt): Ausgabe markiert Block 2 mit `CRC ✗`, alle anderen mit `✓`
- [ ] `lbf_dump --verify-only hello.lbf`: Exit-Code 0 bei valider Datei, Exit-Code 1 bei korrupter Datei (verwendbar in CI/CD-Skripten)
- [ ] UUID-Ausgabe im Standard-UUID-Format (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
- [ ] Timestamp: Kompilierungs-Zeitstempel als menschenlesbares UTC-Datum ausgegeben
- [ ] Capabilities-Bitfeld: Jedes gesetzte Bit wird mit seinem Namen ausgegeben (z.B. `LBF_CAP_NET_SOCKET`)
- [ ] `lbf_dump` auf truncated Datei (letzte 100 Bytes fehlen): kein Absturz, Fehlermeldung "unexpected EOF"

---

---

## WP12 — Lifecycle Descriptor

**Datei:** lyxc-intern (Parser-Annotationen + TLV-Emitter), `kernel/lbf_exec.lyx` (Dispatch)
**Abhängigkeiten:** WP03 (TLV), WP06 (Compiler-Backend), WP10 (Zero-Load Executor)
**Geschätzter Aufwand:** 4–6 Tage

### Ziel

Vollständige Implementierung von TLV 0x08 (Lifecycle Descriptor) in drei Teilen:
1. **Compiler:** `@lifecycle`/`@on_event`/`@quiescence_stack`-Annotationen parsen → TLV 0x08 erzeugen
2. **_start-Varianten:** je nach `lifecycle_kind` unterschiedlichen Einstiegs-Code emittieren
3. **Kernel:** TLV 0x08 beim Zero-Load lesen → Event-Quellen registrieren, Lazy-Start, Stack-Schrumpfen

### Compiler: Annotation-Parser

```lyx
// Interne Repräsentation nach dem Parsen der @-Annotationen
type LbfLifecycle = struct {
  kind:             int64;    // LBF_LC_ONE_SHOT / EVENT_LOOP / DAEMON / REACTIVE
  quiescence_kb:    int64;    // 0 = nicht deklariert
  on_idle_va:       int64;    // 0 = kein Idle-Handler
  idle_timeout_ms:  int64;
  source_count:     int64;
  sources:          pchar;    // Array aus source_count × LbfEventSource (je 12 Bytes)
};

type LbfEventSource = struct {
  kind:       int64;    // LBF_EV_STDIN / TIMER / SIGNAL / ...
  flags:      int64;    // 0x01 = hat on_event_va
  param:      int64;    // Hz für Timer, Signalnr. für SIGNAL
  on_event_va: int64;   // virtuelle Adresse des Handlers (0 = main-Dispatch)
};
```

**`lifecycle_parse_annotations(main_fn: pchar) → LbfLifecycle`**

Liest alle `@lifecycle`, `@on_event`, `@quiescence_stack`-Annotationen von der `main()`-AST-Node
und baut die `LbfLifecycle`-Struktur auf. Unbekannte Annotationen → Compiler-Warnung.

Ohne jede Annotation: gibt `LbfLifecycle{ kind=ONE_SHOT, source_count=0 }` zurück.

### Compiler: TLV-Emitter

```lyx
fn tlv_add_lifecycle(pool: pchar, pool_used: pchar, lc: LbfLifecycle): int64 {
  var size: int64 := 16 + lc.source_count * LBF_LC_SRC_SIZE;
  var buf: pchar := mmap(0, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);

  poke8(buf + LBF_LC_KIND,          lc.kind);
  poke8(buf + LBF_LC_SOURCE_COUNT,  lc.source_count);
  poke8(buf + LBF_LC_QUIESCENCE_KB + 0, lc.quiescence_kb & 0xFF);
  poke8(buf + LBF_LC_QUIESCENCE_KB + 1, (lc.quiescence_kb >> 8) & 0xFF);
  poke64(buf + LBF_LC_ON_IDLE_VA,   lc.on_idle_va);
  poke32(buf + LBF_LC_IDLE_TIMEOUT, lc.idle_timeout_ms);

  var i: int64 := 0;
  while (i < lc.source_count) {
    var src: pchar := lc.sources + i * LBF_LC_SRC_SIZE;
    var dst: pchar := buf + LBF_LC_SOURCES + i * LBF_LC_SRC_SIZE;
    poke8(dst + LBF_LC_SRC_KIND,     peek64(src + 0));
    poke8(dst + LBF_LC_SRC_FLAGS,    peek64(src + 8));
    poke8(dst + LBF_LC_SRC_PARAM,    peek64(src + 16) & 0xFF);
    poke8(dst + LBF_LC_SRC_PARAM+1, (peek64(src + 16) >> 8) & 0xFF);
    poke64(dst + LBF_LC_SRC_ON_EVENT, peek64(src + 24));
    i := i + 1;
  }

  var ret: int64 := tlv_append(pool, pool_used, LBF_TLV_LIFECYCLE, buf, size);
  munmap(buf, size);
  return ret;
}
```

### Compiler: _start-Varianten

Der bestehende `emitStartStub()` (LX-03) bleibt unverändert für `ONE_SHOT`.
Für `EVENT_LOOP` wird ein erweiterter Stub emittiert:

```
emitStartStub_EventLoop():
  XOR rbp, rbp
  getrandom([rsp-8], 8, 0)                  // Canary (identisch LX-03)
  MOV rdi, <tlv_08_va>                      // Pointer auf TLV 0x08 im .rodata
  MOV rax, SYS_EVENT_LOOP_INIT (0x0020)     // LyxOS: Event-Quellen registrieren
  SYSCALL                                    // Kernel richtet alle Quellen ein
  CALL main                                  // main() läuft, enthält Event-Schleife
  MOV edi, eax
  MOV rax, 2 (sys_exit_group)
  SYSCALL
```

Für `REACTIVE` ruft `sys_exec` erst gar keinen `_start` auf — der Kernel wartet auf das
erste Event und springt dann direkt in den `on_event_va` des auslösenden Deskriptors.

### Kernel: sys_event_loop_init (LyxOS-Syscall 0x0020)

```lyx
// Neuer Syscall: liest TLV 0x08 des laufenden Prozesses und registriert Event-Quellen
fn sys_event_loop_init(tlv_08_ptr: pchar): int64 {
  var kind:   int64 := peek8(tlv_08_ptr + LBF_LC_KIND);
  var count:  int64 := peek8(tlv_08_ptr + LBF_LC_SOURCE_COUNT);

  var i: int64 := 0;
  while (i < count) {
    var src: pchar := tlv_08_ptr + LBF_LC_SOURCES + i * LBF_LC_SRC_SIZE;
    var ev_kind: int64 := peek8(src + LBF_LC_SRC_KIND);
    var param:   int64 := peek8(src + LBF_LC_SRC_PARAM) | (peek8(src + LBF_LC_SRC_PARAM+1) << 8);
    var va:      int64 := peek64(src + LBF_LC_SRC_ON_EVENT);

    if ev_kind == LBF_EV_STDIN      { kernel_event_register_fd(0, va, current_proc); }
    if ev_kind == LBF_EV_TIMER      { kernel_timer_create(param, va, current_proc); }
    if ev_kind == LBF_EV_SIGNAL     { kernel_signal_route(param, va, current_proc); }
    if ev_kind == LBF_EV_NET_ACCEPT { kernel_net_register_accept(va, current_proc); }
    // ... weitere Quellen analog
    i := i + 1;
  }
  return 0;
}
```

### Kernel: sys_exec — Erweiterung für REACTIVE

In `kernel/lbf_exec.lyx` (WP10), nach TLV 0x08 lesen:

```lyx
// Nach Schritt 2 (Firewall-Check), vor Schritt 3 (CR3 anlegen):
var lc_data: pchar := ...; // TLV 0x08 aus Genesis
var lc_kind: int64 := peek8(lc_data + LBF_LC_KIND);

if lc_kind == LBF_LC_REACTIVE {
  // Event-Quellen registrieren ohne CPU-Kontext zu starten
  kernel_lazy_register(lc_data, prog_lpid);
  return prog_lpid;  // kein Prozess gestartet, Kernel übernimmt
}
// Sonst: normaler Ablauf (Schritte 3–8)
```

### Abnahmekriterien

- [ ] `@lifecycle(one_shot)` (oder keine Annotation): TLV 0x08 in Genesis vorhanden; `kind=0x00`, `count=0`; emittierter `_start` identisch mit aktuellem LX-03-Stub
- [ ] `@lifecycle(event_loop)` + zwei `@on_event`-Annotationen: TLV 0x08 mit `kind=0x01`, `count=2`; beide Event-Source-Deskriptoren byte-korrekt serialisiert
- [ ] Timer-Deskriptor: `@on_event(timer, hz: 60)` → `source_kind=0x03`, `param=60`, `on_event_va` zeigt auf kompilierten Handler
- [ ] Signal-Deskriptor: `@on_event(signal, sig: 15)` → `source_kind=0x04`, `param=15`
- [ ] `@quiescence_stack(4)` → `quiescence_stack_kb=4` im TLV-Header
- [ ] `lifecycle_kind=REACTIVE`: `sys_exec()` gibt LPID zurück ohne Prozess zu starten; nach erstem Event: Prozess wird hochgefahren, `on_event_va` korrekt aufgerufen
- [ ] `sys_event_loop_init()` mit Timer 60Hz: Prozess erhält korrekt 60× pro Sekunde den Event (verifizierbar per Timestamp-Ausgabe aus dem Handler)
- [ ] `lbf_dump` zeigt TLV 0x08 vollständig: Lifecycle-Kind als Text, alle Event-Quellen mit Kind, param und VA

---

## Gesamtabnahme / Integrations-Meilenstein

Wenn alle WP01–WP10 abgeschlossen sind, gilt der folgende End-to-End-Test als finaler Systemnachweis:

**Kompilierung:**
1. `lyxc hello.lyx -o hello.lbf`: kompiliert ein Lyx-Programm mit Doc-Comment-Intent nach LBF
2. `lbf_dump --verify-only hello.lbf`: Exit-Code 0 (alle CRCs valide, kein Blacklist-Treffer)

**POSIX-Ausführung:**
3. `lbf_run hello.lbf`: Programm läuft, Ausgabe korrekt, .bss=0, .rodata write-protected

**IOFS-Integration:**
4. `lbf_import hello.lbf --into-island=tools`: gibt LPID zurück, Knoten-Cluster im Graphen
5. IOFS-Graph: `total_blocks` IOFS-Pages (Typ=0x04) über 0xB001-Ketten traversierbar
6. WP09-Test: Programm mit Dependency auf `std.net.socket.lbf` → nach Import beider: 0xD001-Kante vorhanden
7. `sys_exec(prog_lpid)`: Programm startet nativ auf IOFS, Entry-Point korrekt

**Sicherheit:**
8. Manipuliertes Binary (1 Bit im .text-Block geflippt): `lbf_run` verweigert, `lbf_import` verweigert
9. Blacklist-Test: Compiler-UUID auf Blacklist → `lbf_run` und `sys_exec` verweigern mit Meldung
10. Firewall-Test: Programm mit `LBF_CAP_NET_SOCKET` aber Intent "text processing" → `sys_exec` verweigert (Capability-Intent-Mismatch)

**Bestandskriterium:** Alle 10 Schritte ohne Absturz, ohne stille Korruption, mit korrekten Exit-Codes und Fehlermeldungen.

---

## Status

| WP   | Name                      | Status              | Begonnen   | Abgeschlossen |
|------|---------------------------|---------------------|------------|---------------|
| WP01 | Block Header I/O          | Offen               | —          | —             |
| WP02 | Genesis-Content Serializer| Offen               | —          | —             |
| WP03 | TLV-Framework             | Offen               | —          | —             |
| WP04 | Section Block Emitter     | Offen               | —          | —             |
| WP05 | Supply Chain Security     | Offen               | —          | —             |
| WP06 | lyxc LBF-Backend          | Teilweise (LX-01–03)| 2026-06-07 | —             |
| WP07 | POSIX-Loader (lbf_run)    | Offen               | —          | —             |
| WP08 | IOFS-Import (lbf_import)  | Offen               | —          | —             |
| WP09 | Dependency Resolver       | Offen               | —          | —             |
| WP10 | Zero-Load Executor        | Offen               | —          | —             |
| WP11 | lbf-dump Inspection Tool  | Offen               | —          | —             |
| WP12 | Lifecycle Descriptor      | Offen               | —          | —             |

### WP06 — Bereits erledigter Stand (LX-01 bis LX-03)

| LX-Tag | Inhalt | Datei | Status |
|--------|--------|-------|--------|
| LX-01  | ELF-Header + `.note.lyx-abi` (namesz, descsz, "LYX\0", major=1, minor=0) | `src/backend/lyxos/emit_lyxos.lyx` — `LyxOsELFWriter::writeELF()` | Erledigt |
| LX-02  | IR-Dispatch-Skelett (`emitInstr`: CONST_INT, LOAD_LOCAL, STORE_LOCAL, CALL, FUNC_EXIT) | `EmitLyxOS::emitInstr()` | Erledigt |
| LX-03  | `_start`-Stub: getrandom (Canary) → CALL main → MOV edi,eax → exit_group | `EmitLyxOS::emitStartStub()` | Erledigt |

LX-03 kodiert implizit `lifecycle_kind = ONE_SHOT`. WP12 formalisiert das und fügt
die anderen Lifecycle-Arten hinzu.
