# LBF-Nativ (LYX!) — Technische Format-Spezifikation

**Zweck:** Vollständige, kernel-implementierbare Spezifikation des nativen LyxOS-
Binärformats `LYX!`, damit der Kernel (Loader / Zero-Load-Executor, LX-34) Dateien
laden, validieren, mappen und ausführen kann.

**Stand:** V1.0.1A. Autoritative Quelle der Konstanten: `src/std/lyxos/lbf_layout.lyx`.
Referenz-Implementierungen: `src/tools/lbf/{block_header,genesis,tlv,sections,security,loader}.lyx`.

---

## 0. Zwei „LBF"-Formate — NICHT verwechseln

| Format | Magic | Bytes | Inhalt | Verwendung |
|--------|-------|-------|--------|------------|
| **LBF-IR** | `LBF\0` | 4C 42 46 00 | IR-Opcode-Bytecode | `--emit=lbf`, Simulation/Test via Interpreter |
| **LBF-Nativ** | `LYX!` | 4C 59 58 21 | Native Maschinencode-Blocks | **Produktion / Kernel** (diese Spec) |

Der Kernel verarbeitet ausschließlich **LYX!**.

---

## 1. Dateistruktur (Block-Stream)

Eine `LYX!`-Datei ist eine Folge von **Blocks à exakt 4096 Bytes**. Dateigröße ist
immer ein Vielfaches von 4096.

```
Block 0      : Genesis-Block      (Header 64 B + Genesis-Payload 4032 B)
Block 1..N   : Section-Blocks      (Header 64 B + Code/Daten-Payload 4032 B)
```

- `LBF_BLOCK_SIZE   = 4096`
- `LBF_HEADER_SIZE  = 64`
- `LBF_PAYLOAD_SIZE = 4032`   (= 4096 − 64)

Jeder Block: 64-Byte-Header gefolgt von 4032-Byte-Payload. Payload des Blocks `bi`
liegt bei `file + bi*4096 + 64`.

---

## 2. Block-Header (64 Bytes, little-endian)

| Offset | Größe | Feld | Beschreibung |
|--------|-------|------|--------------|
| 0x00 | 4 | `magic` | `'L''Y''X''!'` (4C 59 58 21) |
| 0x04 | 1 | `page_type` | 0x04 = EXECUTABLE |
| 0x05 | 1 | `flags` | Bit0 = IMMUTABLE (.text/.rodata) |
| 0x06 | 2 | `edge_offset` | IOFS-Kanten-Offset (Genesis: 0x40) |
| 0x08 | 8 | `lpid` | Logical Page ID |
| 0x10 | 2 | `payload_size` | immer 4032 |
| 0x18 | 4 | `block_crc32c` | CRC32C des 4032-B-Payloads (s. §4) |
| 0x1C | 4 | `meta_offset` | Genesis: 0x40 |
| 0x20 | 8 | `cont_lpid` | Fortsetzungs-LPID (Multi-Block) |
| 0x28 | 4 | `block_index` | 0-basierter Block-Index |
| 0x2C | 4 | `total_blocks` | Gesamt-Blockzahl der Datei |
| 0x38 | 8 | `compiled_at` | Zeitstempel (Epoch µs) |

(0x16, 0x30–0x37 reserviert / 0.)

---

## 3. Genesis-Payload (Block 0, ab Offset 64, little-endian)

| Offset | Größe | Feld | Beschreibung |
|--------|-------|------|--------------|
| 0x00 | 1 | `content_type` | 1 = EXECUTABLE |
| 0x01 | 1 | `target_arch` | 1=x86_64, 2=ARM64, 3=RISCV |
| 0x02 | 2 | `os_version_min` | u16 |
| 0x04 | 8 | `entry_point` | u64 — Programm-Einsprung-VA (ELF-Modus; nativ in-process = Code-Offset 0) |
| 0x0C | 4 | `file_size` | u32 — Gesamt-Bytes |
| 0x10 | 2 | `text_blocks` | u16 — Anzahl .text-Blocks |
| 0x12 | 2 | `rodata_blocks` | u16 |
| 0x14 | 2 | `data_blocks` | u16 |
| 0x16 | 2 | `bss_blocks` | u16 |
| 0x18 | 4 | `stack_size` | u32 (Default 0x20000) |
| 0x1C | 4 | `file_crc32c` | u32 — CRC32C über alle Payloads (s. §4); 0 während Berechnung |
| 0x20 | 16 | `compiler_name` | "lyxc" + 0-Padding |
| 0x30 | 4 | `compiler_ver` | u32 packed Major.Minor.Patch |
| 0x34 | 8 | `compiled_at` | u64 Epoch µs |
| 0x3C | 16 | `compiler_uuid` | UUID v4 (deterministisch aus source_sha256[0..15]) |
| 0x4C | 32 | `source_sha256` | SHA-256 der Quelldateien |
| 0x6C | 2 | `tlv_offset` | u16 (Standard 0x80) |
| 0x6E | 2 | `tlv_used` | u16 — belegte TLV-Bytes |
| 0x80 | 3904 | `tlv_pool` | TLV-Records (s. §5), `LBF_TLV_MAX_SIZE` |

---

## 4. CRC32C (Castagnoli)

Bitweise, **reflektiert**:
- Polynom: `0x82F63B78`
- Init: `0xFFFFFFFF`
- Pro Byte: `crc ^= byte; 8×{ crc = (crc&1) ? (crc>>1)^poly : crc>>1 }`
- Final: `crc ^ 0xFFFFFFFF` (32-bit)

**Block-CRC** (`block_crc32c` @ Header+0x18): über die 4032 Payload-Bytes des Blocks.

**File-CRC** (`file_crc32c` @ Genesis+0x1C): EIN fortlaufender CRC32C über die
**Payloads ALLER Blocks** (je 4032 B, in Block-Reihenfolge), wobei das Feld
`file_crc32c` selbst während der Berechnung auf 0 gesetzt ist.

---

## 5. TLV-Framework (im Genesis-tlv_pool)

Record-Encoding: `[type:u8][length:u16LE][value:length Bytes]`, sequenziell ab
`tlv_pool` (Genesis+0x80), Summe ≤ `tlv_used`, max 3904 B.

| Type | Name | Value |
|------|------|-------|
| 1 | HUMAN_INTENT | UTF-8-Freitext (///-Doc) |
| 2 | DEP_HASH_GRAPH | SHA-256 der Dependencies |
| 3 | SYM_INTERFACE | Signaturen + Contract-Hashes |
| 4 | ISA_EXTENSIONS | u64-Bitmaske (AVX2=bit0, AVX512=bit1, …) |
| 5 | CAPABILITIES | u64 Capability-Bits (s. §7) |
| 6 | SOURCE_MAP | Git-Commit / URI |
| 7 | BUILD_MANIFEST | Array(filename[64]+sha256[32]) |
| 8 | LIFECYCLE | Lifecycle-Descriptor (s. §8) |
| 9 | SECTION_MAP | Segment-Deskriptor: `start_block, count, sect_type, prot` |

**SECTION_MAP (Type 9)** ist für den Kernel zentral: bildet Block-Bereiche auf
Segmente ab. Felder: `start_block` (block_index des ersten Blocks), `count`
(Block-Anzahl), `sect_type` (§6), `prot` (§6).

---

## 6. Section-Typen & Schutz

| sect_type | | prot | Wert | mmap |
|-----------|--|------|------|------|
| 1 | TEXT   | RX | 5 | PROT_READ\|PROT_EXEC |
| 2 | RODATA | R  | 4 | PROT_READ |
| 3 | DATA   | RW | 3 | PROT_READ\|PROT_WRITE |
| 4 | BSS    | RW | 3 | (zero-mapped) |

TEXT/RODATA tragen `IMMUTABLE` (Header flags bit0).

---

## 7. Capability-Bits (TLV Type 5, u64)

| Bit | Wert | Capability |
|-----|------|-----------|
| 0 | 1 | FS_READ |
| 1 | 2 | FS_WRITE |
| 2 | 4 | NET_SOCKET |
| 3 | 8 | PROC_SPAWN |
| 4 | 16 | KI_EMBED |
| 5 | 32 | KI_GRAPH_WRITE |
| 7 | 128 | AUDIO_MIC |

Der Kernel MUSS die Sandbox gemäß diesen Bits einrichten (Default: keine = Zero-Privilege).

---

## 8. Lifecycle (TLV Type 8) + Event-IDs

| kind | Bedeutung |
|------|-----------|
| 0 | ONE_SHOT (start→main→exit) |
| 1 | EVENT_LOOP |
| 2 | DAEMON |
| 3 | REACTIVE (Lazy-Start beim ersten Event) |

Event-IDs: 1=STDIN, 2=FD, 3=TIMER, 4=SIGNAL, 5=NET_ACCEPT, 6=NET_RECV,
7=IOFS_EVENT, 8=KI_MESSAGE, 9=CHILD_EXIT, 10=AUDIO_IN.

---

## 9. Loader-/Kernel-Kontrakt (Lade- & Ausführungssequenz)

Referenz: `src/tools/lbf/loader.lyx` (`lbf_run`, POSIX in-process). Kernel-Pflicht:

1. **Geometrie:** Dateigröße prüfen — Vielfaches von 4096, ≥ 4096. Sonst Fehler.
2. **Genesis-Magic:** Block 0 Header-Magic == `LYX!`. Sonst Fehler.
3. **Genesis-Block-CRC:** `crc32c(payload0, 4032)` == `block_crc32c`. Sonst Fehler.
4. **File-CRC:** §4 über alle Payloads == `file_crc32c`. Sonst Fehler.
5. **Genesis lesen:** `target_arch` (gegen Kernel-Arch prüfen), `text/rodata/data/bss_blocks`,
   `entry_point`, `stack_size`, CAPABILITIES- + LIFECYCLE-TLV.
6. **Segmente mappen:** Pro SECTION_MAP-TLV (bzw. Block-Reihenfolge text→rodata→data→bss):
   - Payloads der Section-Blocks konkatenieren.
   - Speicher mit `prot` mappen (TEXT=RX, RODATA=R, DATA=RW, BSS=RW zero).
   - Optional pro Block `block_crc32c` verifizieren.
7. **Sandbox:** seccomp/Landlock-Äquivalent gemäß CAPABILITIES-Bits.
8. **Sprung:** Kontrolle an `entry_point` übergeben (Stack `stack_size`). Im
   minimalen in-process-Modus (`lbf_run`): TEXT-Payloads in RWX, Sprung zu Offset 0,
   Code ist als Funktion aufrufbar (endet mit RET, Resultat in rax/x0).

**Minimal-Loader (lbf_run, vereinfacht, ohne Section-Map):** validieren →
`text_blocks` aus Genesis → alle Text-Block-Payloads in `mmap(RWX)` konkatenieren →
zu Offset 0 springen. Für vollwertigen Kernel: getrennte prot-Segmente + entry_point + Stack.

---

## 10. Producer (Referenz) — LX-30 ✅ ERLEDIGT

**`lyxc --target=lyxos prog.lyx`** erzeugt direkt natives `LYX!` (NICHT `--emit=lbf`,
das ist der IR-Pfad). Flow: `emitLyxOS` (lyxc.lyx) → `EmitLyxOS`-Backend (nativer
x86_64-Maschinencode mit lyxos-Syscall-ABI, _start-Stub nach Lifecycle, StrPool ans Code
angehängt) → `LBFNativeWriter.writeLBF(out, src, codeBuf, codeLen)`.

`writeLBF`: `text_blocks = ceil(codeLen/4032)`, `entry_point = 0x400000`, Genesis + Text-
Blocks, Block-CRCs + File-CRC, TLV CAPABILITIES + LIFECYCLE + SECTION_MAP(1, text_blocks, TEXT, RX).

**Verifiziert (V1.0.1A):** lyxc kompiliert sich selbst zu nativem lyxos-LYX! —
2.072.576 B = 506 Blocks, `lbf_header_validate=0`, File-CRC32C OK. Regressions-Test:
`tests/lbf_native_emit_test.sh`.

Aktuell: gesamter Code/StrPool in EINER TEXT-Section. rodata/data/bss als getrennte
Sektionen (eigene prot, mehrere SECTION_MAP-Einträge) = Erweiterung.

---

## 11b. Kernel-Abstimmung nötig (LYXOS-WP-5, blockiert)

Der native lyxos-Emit kann jetzt Arithmetik, Control-Flow, Globals, Fields/Index
(LYXOS-WP-1..4). Für W^X-taugliche Multi-Section-Ausgabe braucht der Compiler drei
Kernel-Entscheidungen — bitte Kernel-Team festlegen:

1. **Section-Mapping-Strategie:** Werden `.text`/`.rodata`/`.data` **contiguous im selben
   VA-Bereich** geladen (ein Adressraum, prot pro Block-Bereich gesetzt — dann bleiben die
   RIP-relativen Compiler-Offsets gültig), ODER als **getrennte mmaps** (dann braucht der
   Compiler eine Relokationstabelle für sektionsübergreifende Referenzen)? Aktuell: alles in
   EINER RX-Section, RIP-relativ — funktioniert nur ohne W^X.
2. **entry_point-Konvention:** Aktuell hart `0x400000` (Genesis +0x04). Soll das die feste
   Kernel-Lade-VA sein, oder ein **datei-/sektions-relativer Offset** (z. B. Offset 0 = Start
   .text)? Der Loader-Kontrakt (§9.8) muss das fixieren.
3. **Lifecycle-Event-Modell:** Für EVENT_LOOP/REACTIVE — Format der Event-ID→Handler-Tabelle
   im LIFECYCLE-TLV (§8). Welche Adress-Form für Handler (VA / .text-Offset)? Wie ruft der
   Kernel Handler auf (Signatur, Argumente)?

Sobald geklärt: WP-5 = Pools block-alignen, 3× SECTION_MAP + Genesis-Counts, RIP-Patches gegen
finales Layout, `lbf_run` parallel auf Multi-Section-Mapping upgraden.

## 11. Offene Punkte / Kernel-Erweiterung

- **LX-34 Zero-Load-Executor:** Blocks direkt aus Speicher/IOFS ausführen (kein Kopieren).
- **Ausführung auf POSIX:** native LYX! mit lyxos-Syscall-ABI läuft NUR auf dem lyxos-Kernel,
  nicht via POSIX-`lbf_run` (dieser ist für plain-Funktions-Blobs). Kernel muss die
  lyxos-Syscall-Tabelle + _start-Konvention bereitstellen.
- **Multi-Section:** Producer trennt aktuell nicht rodata/data/bss — alles in TEXT.
- IOFS-Kanten (`edge_offset`, `cont_lpid`) für Multi-Block-Graph-Layout.
- ARM64-Code in `LYX!` (target_arch=2) + arm64-Loader.
- entry_point-Konvention vereinheitlichen (ELF-VA 0x400000 vs in-process-Offset 0).

## Verwandt
[[LYX-Native-Loader]] · [[lyu-format-v3]] · src/std/lyxos/lbf_layout.lyx (Konstanten)
