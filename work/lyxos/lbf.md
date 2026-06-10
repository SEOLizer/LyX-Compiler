# Lyx Binary Format (LBF) — System-Spezifikation

**Version:** 1.1  
**Ebene:** KI-natives, seitenbasiertes ausführbares Binärformat  
**Ziel-Architektur:** Heterogenes Computing (x86-64, ARM64 u. a. mit ISA-Feature-Validierung)  
**Abhängigkeit:** Optimiert für das Island & Ocean File System (IOFS) / Portabel auf POSIX-Dateisystemen  
**Implementierungsdetails & Arbeitsschritte:** `lbf_workpackages.md`

---

## 1. Fundamentale Philosophie

Das Lyx Binary Format (LBF) ist ein Paradigmenwechsel für KI-native Architekturen. Anstatt den historischen Ballast klassischer Formate wie ELF oder PE (komplexe dynamische Linker, Symboltabellen, Relokationsschleifen) mitzuschleifen, nutzt LBF ein duales Ladeprinzip:

**Auf Legacy-Filesystemen:** Es verhält sich wie eine flache, sequentielle Binärdatei, die problemlos transportiert, kopiert und vom Lyx-Compiler erzeugt werden kann.

**Auf dem nativen Lyx OS (IOFS):** Es ist exakt auf das physische 4KB-Page-Raster der Hardware angepasst. Der Kernel trennt die Datei alle 4096 Bytes und injiziert die Segmente direkt als fertige Datenknoten in den Graphen.

LBF integriert semantische Beschreibungen (Intents) und kryptografische Herkunftsnachweise direkt im Header, sodass die System-KI vor der ersten Ausführung genau versteht, was das Programm tut, welche Hardware-Erweiterungen es benötigt und ob die Vertrauenskette intakt ist.

---

## 2. Speicher-Effizienz & Layout-Modi

Um das Problem des Speicherverschnitts (Internal Fragmentation) bei kleinen Programmen oder Microservices zu lösen, unterstützt LBF zwei Layout-Modi:

### Modus A: Striktes Alignment (Standard)

Jede logische Sektion (`.text`, `.data`, `.rodata`) beginnt zwingend an einer physischen 4096-Byte-Grenze. Perfekt für große, monolithische Anwendungen für maximale Page-Table-Mapping-Performance.

```
BLOCK 0     Genesis-Block   — Metadaten, KI-Kontext, Provenienz, Lifecycle
BLOCK 1..N  .text           — Maschinencode (R/X, Immutable)
BLOCK N+1.. .rodata         — Konstanten, String-Literale (R, Immutable)
BLOCK M+1.. .data           — Initialisierte Globale (R/W)
BLOCK K+1.. .bss            — Uninitialisierte Globale (R/W, kein physischer Block)
```

### Modus B: Sub-Page Packing (`LBF_FLAGS_PACKED`)

Für Kleinstprogramme oder Microservices kann der Compiler das Packing-Flag setzen.

**Mechanismus:** Sektionen mit identischen Zugriffsberechtigungen (z. B. ausführbarer Code in `.text` und Konstanten in `.rodata`, die sich beide das Attribut Read-Only / Executable teilen) werden in dieselbe physische 4KB-Page gepackt. Erst wenn beschreibbare Variablen (`.data` mit Read-Write-Rechten) folgen, wird an der nächsten 4KB-Grenze geschnitten. Dies reduziert den minimalen Footprint von Kleinst-Binaries erheblich.

---

## 3. Byte-genaues Layout von Block 0 (Der Genesis-Header)

Der erste Block (exakt 4096 Bytes) bildet das Kontrollzentrum des Programms. Alle Offsets sind strikt aligned.

```
Offset (Byte) | Größe (Bytes) | Datentyp    | Beschreibung
---------------------------------------------------------------------------------------
[THE CORE MACHINE HEADER]
0x0000        | 4             | Char[4]     | Magic Bytes: 0x4C 0x59 0x58 0x21 ("LYX!")
0x0004        | 1             | uint8_t     | LBF-Format-Version (aktuell 0x01)
0x0005        | 1             | uint8_t     | Basis-CPU-Architektur (0x01=x86-64, 0x02=ARM64, 0x03=RISC-V)
0x0006        | 2             | uint16_t    | Mindestanforderung an die Kernel-Version
0x0008        | 8             | uint64_t    | Entry-Point (Virtuelle RAM-Adresse für den CPU-Start)
---------------------------------------------------------------------------------------
[THE COMPILER COMPONENT & PROVENANCE BLOCK]
0x0010        | 16            | Char[16]    | Name des Erzeugers (Standard: "lyxc            ")
0x0020        | 4             | uint32_t    | Compiler-Version (Packed: Major.Minor.Patch → z. B. 0x010000)
0x0024        | 8             | uint64_t    | Zeitstempel der Kompilierung (Epoch in Mikrosekunden)
0x002C        | 16            | uint8_t[16] | Eindeutige Seriennummer (UUID) der Compiler-Instanz
0x003C        | 32            | uint8_t[32] | SHA-256 Krypto-Prüfsumme des zugrundeliegenden Quellcodes
0x005C        | 2             | uint16_t    | LBF_Flags (Bit 0: Packed-Layout, Bits 1–15: Reserviert)
0x005E        | 2             | uint16_t    | Byte-Offset zum KI-Context-Bereich (Standard: 0x0060)
---------------------------------------------------------------------------------------
[DYNAMIC KI-CONTEXT & SEMANTICS AREA (TLV-Struktur)]
0x0060        | 4000          | Byte[]      | Flexibler, erweiterbarer Metadatenpool für die System-KI
```

---

## 4. Das KI-Semantik-Register (TLV-Framework)

Der Bereich ab Offset `0x0060` verwendet eine Type-Length-Value (TLV)-Struktur. Jedes Element besteht aus einem 1-Byte-Typfeld, einem 2-Byte-Längenfeld (`uint16_t`) und der variablen Payload.

Sollte der Platz von 4000 Bytes aufgrund komplexer Signaturen erschöpft sein, kommt ein Überlauf-Mechanismus zum Einsatz: Tag `0x05` (EXT_META_PTR) verweist auf eine Continuation-LPID — eine zusätzliche Page am Ende der Datei — wodurch das Metadaten-Framework unbegrenzt erweiterbar bleibt.

### 0x01 — HUMAN_INTENT (Deklarative Absicht)

**Payload:** UTF-8 kodierter Freitext.  
Enthält die semantische Beschreibung des Programms (was es tut, welche Parameter es erwartet). Extrahiert vom Compiler aus `///`-Doc-Comments über `main()`. Ohne Doc-Comment: Dateiname. Die System-Shell nutzt dies, um dem Nutzer ad hoc ohne Man-Pages präzise Hilfestellungen zu geben. Dient der Semantischen Firewall (WP13) als Kohärenzgrundlage.

### 0x02 — DEP_HASH_GRAPH (Statische Abhängigkeiten)

**Payload:** Array aus 32-Byte SHA-256-Hashes.  
Deklariert die unveränderlichen Identitäten der System-Inseln oder Bibliotheken, die zum Kompilierungszeitpunkt vorausgesetzt wurden. Auf IOFS löst der Kernel diese Hashes beim Import zu LPIDs auf und webt Dependency-Kanten in den Graphen — kein klassischer Linker nötig.

### 0x03 — SYM_INTERFACE (Kryptografisch verifiziertes Contract-Linking)

**Payload:** Strukturierte Funktions-Signaturen gekoppelt mit kryptografischen Bedingungen (Contract Hashes).  
Verhindert "Late-Binding"-Angriffe, bei denen Schadsoftware identische Signaturen fälscht. Ein Import/Linking wird von der KI nur erlaubt, wenn die Ziel-Insel die Bedingung erfüllt — z. B. "Binde `calculate(int)` nur, wenn die Ziel-Insel mit dem Public Key des System-Herstellers signiert ist" oder dem exakten Hash entspricht. Exportierte Funktionen ermöglichen außerdem Dynamic Graph Linking ohne Dynamic-Linker-Lauf.

### 0x04 — ISA_EXTENSIONS (Hardware-Feature-Validierung)

**Payload:** `uint64_t` Bitmaske.  
Deklariert spezifische CPU-Instruktionserweiterungen:

| Bit | Extension |
|-----|-----------|
| 0   | AVX2      |
| 1   | AVX-512   |
| 2   | ARM-NEON  |
| 3   | AMX       |
| …   | Reserviert |

Die KI gleicht diese Maske vor dem ersten Thread-Start mit den echten CPUID-Registern des Kernels ab. Bei Inkompatibilität wird die Ausführung sicher abgefangen, anstatt einen `Illegal Instruction`-Trap auf Hardware-Ebene zu riskieren.

### 0x05 — EXT_META_PTR (Metadaten-Überlauf)

**Payload:** `uint64_t` LPID (Logical Page ID).  
Wenn die 4000 Bytes im Header-Block 0 vollgeschrieben sind, zeigt dieser Pointer auf eine oder mehrere nachgelagerte Pages, die ausschließlich weitere TLV-Daten aufnehmen.

### 0x06 — SOURCE_MAP (Observability & Debugging)

**Payload:** Git-Commit-Hash, URI oder direkter Verweis auf einen unkompilierten Quellcode-Knoten im IOFS.  
Ermöglicht es Entwicklern, über Kernel-Tracing-Hooks den Zustand des Maschinencodes und der CPU-Register direkt in lesbaren Lyx-Quellcode zurückzuübersetzen.

### 0x07 — BUILD_MANIFEST (Reproduzierbarkeit)

**Payload:** Array aus `(Dateiname, SHA-256)`-Paaren aller Quelldateien.  
Macht den Build vollständig reproduzierbar und auditierbar.

### 0x08 — LIFECYCLE_DESCRIPTOR (Prozess-Lebenszyklus)

Deklarativer Prozess-Lebenszyklus — siehe Abschnitt 6.

---

## 5. Referenz-Struktur für das Lyx-Compiler-Backend

Das Compiler-Backend befüllt diese kompakte Struktur und schreibt sie als sequentiellen Bytestream heraus. Kein komplexer ELF-Emissions-Code nötig.

```rust
#[repr(C, packed)]
struct LbfHeader {
    // Core Machine Header
    magic:                [u8; 4],   // 0x4C 0x59 0x58 0x21 ("LYX!")
    format_version:       u8,        // 0x01
    target_arch:          u8,        // 0x01=x86-64, 0x02=ARM64, 0x03=RISC-V
    os_version:           u16,       // Mindestanforderung Kernel
    entry_point:          u64,       // Startadresse für die CPU

    // Provenance & Security
    compiler_name:        [u8; 16],  // "lyxc"
    compiler_version:     u32,       // Packed: Major.Minor.Patch
    compiled_at:          u64,       // Zeitstempel in µs
    compiler_instance_sn: [u8; 16], // Eindeutige ID der Compiler-Instanz
    source_sha256:        [u8; 32], // SHA-256 des Quellcodes

    // Layout & Control Flags
    lbf_flags:            u16,       // Bit 0 = Packed Layout aktiv
    ki_context_offset:    u16,       // Standard: 0x0060

    // Erweiterbarer Semantik-Pool
    ki_context:           [u8; 4000] // TLV-Blöcke (Typ 0x01–0x08+)
}
```

---

## 6. Lifecycle Descriptor (TLV 0x08) — Design-Entscheidung

### Was die Geschichte lehrt

Klassische Systeme kennen den App-Lebenszyklus nicht statisch:

- **Windows Win32:** Manueller Message-Pump (`GetMessage`/`DispatchMessage`). Der Kernel weiß nicht ob ein Prozess wartet oder hängt → "Nicht reagierend".
- **Linux epoll:** Interessen werden erst zur Laufzeit registriert — zu spät für Scheduling-Optimierungen oder Lazy-Start.
- **macOS RunLoop:** Besser strukturiert, aber immer noch vollständig implizit im Binary.

LBF löst das durch statische Deklaration.

### Die vier Lifecycle-Arten

**ONE_SHOT** (`0x00`) — Klassisches CLI-Programm. Startet, läuft, beendet sich. Keine Event-Quellen. Entspricht dem aktuell implementierten `_start`-Stub (LX-03: getrandom → CALL main → exit_group).

**EVENT_LOOP** (`0x01`) — Hat eine explizite Event-Schleife. Der Kernel kennt alle Event-Quellen im Voraus und richtet sie *vor* dem ersten `_start`-Aufruf ein. Das Binary muss nicht selbst `epoll_create`/`sigaction` aufrufen.

**DAEMON** (`0x02`) — Langlebiger Hintergrundprozess ohne Terminal. Kernel behandelt ihn strukturell als Service-Knoten im IOFS-Graphen (kein SIGHUP bei Session-Ende, eigener Prozess-Knoten-Typ).

**REACTIVE** (`0x03`) — Lazy-Start. Der Kernel startet den Prozess nicht sofort; er registriert nur die Event-Quellen. Erst beim ersten eingehenden Event wird der Prozess hochgefahren — optional direkt in den Handler, nicht in `_start`. Spart RAM für selten genutzte Dienste.

### Event-Quellen

Jede deklarierte Event-Quelle hat:
- Eine Art (`stdin`, `timer/Hz`, `signal/Nr`, `net_accept`, `net_recv`, `iofs_event`, `ki_message`, `child_exit`, `audio_in`)
- Optional einen dedizierten Entry-Point (`on_event_va`): statt durch `_start` zu gehen, springt der Kernel direkt in den Handler

### Quiescence-Stack

Deklarierter Stack-Bedarf im Idle-Zustand (in KB). Wenn alle Event-Quellen leer sind, kann der Kernel den physischen Stack-Footprint auf diesen Wert reduzieren.

### Was LyxOS damit kann

| Optimierung | Voraussetzung |
|---|---|
| Lazy-Start: Prozess erst bei erstem Event starten | `REACTIVE` |
| Direkter Event-Dispatch: in Handler springen statt `_start` | `on_event_va` gesetzt |
| Stack schrumpfen im Idle | `quiescence_stack_kb > 0` |
| Event-Quellen pre-wired vor `_start` | Alle deklarierten Quellen |
| Kernel unterscheidet Warten von Hänger | Alle Kinds außer ONE_SHOT |

### Quellcode-Annotationen

```lyx
/// Rendert eine GUI-Anwendung mit 60 FPS.
@lifecycle(event_loop)
@on_event(stdin,  handler: fn handle_key)
@on_event(timer,  hz: 60, handler: fn render_frame)
@on_event(signal, sig: 15, handler: fn on_sigterm)
@quiescence_stack(4)
fn main(): int64 { ... }
```

```lyx
/// Netzwerkdienst ohne Terminal.
@lifecycle(daemon)
@on_event(net_accept, handler: fn on_client)
@on_event(signal, sig: 1, handler: fn reload_config)
fn main(): int64 { ... }
```

Ohne Annotation: `ONE_SHOT` implizit. Erzeugt TLV 0x08 mit `kind=0x00`, `count=0` — identisch mit dem aktuellen LX-03-Stub.

---

## 7. Supply Chain Security — Vertrauenskette

LBF etabliert vier Sicherheitsschichten, die alle im Genesis-Block verankert sind:

**Schicht 1 — Bit-Rot-Schutz:** CRC32C pro Block + CRC32C über die gesamte Datei. Zweistufige Prüfung beim Import.

**Schicht 2 — Source-Herkunft:** SHA-256 der Quelldateien (nicht des Binaries). Geänderte Quelldatei → anderer Hash. Geänderter Maschinencode → Block-CRC bricht.

**Schicht 3 — Compiler-Vertrauen:** Jede lyxc-Instanz hat eine UUID (Provenance Block, Offset `0x002C`). Das OS hält eine Blacklist kompromittierter Compiler-Seriennummern; Binaries von geblacklisteten Compilern werden nicht ausgeführt.

**Schicht 4 — Intent-Kohärenz:** Die Semantische Firewall (WP13) prüft: ist TLV 0x01 (HUMAN_INTENT) semantisch konsistent mit TLV 0x03 (SYM_INTERFACE Capabilities)? Inkohärenz → Cognitive Prompt oder Ausführungsverbot.

---

## 8. Ladeprozess und Hardware-Injektion (Zero-Load)

Wenn ein LBF-Programm auf dem nativen Lyx OS ausgeführt wird, entfällt der klassische Overhead eines Programmladers:

1. Der Kernel liest Block 0 (Header) ein.
2. Die KI verifiziert anhand der Krypto-Prüfsummen und der ISA_EXTENSIONS-Maske (TLV 0x04) die Integrität und Hardware-Kompatibilität.
3. Die im SYM_INTERFACE (TLV 0x03) geforderten Abhängigkeiten werden über die LIP-Table (Logical-to-Physical) des Betriebssystems in O(1) in reale, physische Sektor-Pointer umgewandelt.
4. **Direktes CPU-Mapping:** Da alle Sektionen (oder gepackten Gruppen) exakt dem 4KB-Raster entsprechen, trägt der Page-Fault-Handler des Kernels die physischen Sektoren (LBAs) direkt in die Page-Tables der CPU (CR3-Struktur) ein.
5. Die CPU springt direkt an die Adresse des `entry_point`.

**Ladezeit:** O(n) — n LIP-Lookups (je O(1)) + n PTE-Schreibvorgänge. Kein Parser, kein Allokator.

**Lifecycle-Integration:**
- Bei `EVENT_LOOP`: Kernel registriert alle TLV-0x08-Quellen *vor* dem ersten `_start`-Aufruf
- Bei `REACTIVE`: `sys_exec()` kehrt sofort zurück; Prozess startet erst beim ersten Event
- Bei gesetztem `quiescence_stack_kb`: Kernel reduziert physischen Stack im Idle, restauriert ihn vor jedem Event-Handler-Aufruf

---

## 9. POSIX-Kompatibilität

Auf Linux/macOS/Windows läuft LBF über `lbf_run` (WP07): `mmap()` mit korrekten Schutzrechten, Sprung zum Entry-Point. TLV 0x08 wird gelesen und von `lbf_dump` angezeigt, aber nicht ausgeführt — kein nativer Event-Router auf POSIX. `lbf_run` ist ein Kompatibilitätswerkzeug für die Entwicklungsphase, kein Produktionspfad.

---

## 10. Versions-Roadmap

| Version | Inhalt |
|---------|--------|
| v1.0 | Genesis-Block, TLV 0x01–0x08, Zero-Load, Lifecycle-Dispatch |
| v1.1 | Sub-Page Packing (Modus B), ISA-Feature-Validierung (TLV 0x04), kryptografisches Contract-Linking (TLV 0x03 SYM_INTERFACE), SOURCE_MAP (TLV 0x06), byte-exaktes Header-Layout |
| v1.2 | TLV 0x09: Debug-Symboltabelle; TLV 0x0A: DWARF-Unwind-Frame |
| v1.3 | Multi-Arch-Fat-Binaries (x86-64 + ARM64) |
| v2.0 | LAB: Genesis-Block enthält LLM-Gewichts-Fragment — Programm und Inference-Modell in einer Datei |
