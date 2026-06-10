# Lyx Binary Format (LBF) — Design-Spezifikation

**Version:** 1.0  
**Implementierungsdetails & Arbeitsschritte:** `lbf_workpackages.md`

---

## 1. Fundamentale Philosophie

Das Lyx Binary Format (LBF) ist die logische Konsequenz eines KI-gesteuerten Betriebssystems. Klassische Formate wie ELF oder PE tragen jahrzehntelangen Ballast: komplexe Relokationstabellen, dynamische Linker, Sektions-Parsing zur Laufzeit, und keinerlei semantische Selbstbeschreibung.

LBF bricht mit diesem Ansatz auf zwei Ebenen:

**Physisch:** LBF ist auf das 4096-Byte-Page-Raster der NVMe-Hardware und der CPU ausgerichtet. Auf nativem IOFS lädt der Kernel keine Segmente in den RAM — er trägt die physischen Sektoradressen (LBAs) direkt in die Page Tables ein. Die CPU feuert den Maschinencode ohne eine einzige Kopie.

**Semantisch:** LBF ist nicht blind. Jedes Binary enthält einen strukturierten Kontext-Block (Genesis-Block), der der System-KI vor der ersten Ausführung mitteilt: was das Programm tut, welche Absichten es hat, welche Ressourcen es anfordert, welchen Lebenszyklus es hat, und woher es stammt. Die Semantische Firewall (IOFS WP13) liest diesen Block und entscheidet über Ausführungsberechtigung — ohne Sandbox, ohne Syscall-Intercepting, auf Datei-Ebene.

---

## 2. Duales Lademodell

LBF existiert in zwei Darstellungsformen desselben Inhalts:

**POSIX-Portable:** Eine flache, 4096-Byte-aligned Binärdatei. Magic `LBF1`. Transportierbar, kopierbar, vom Compiler auf jedem Betriebssystem erzeugbar. Der semantische Sicherheitslayer entfällt; Ausführung via `lbf_run` (WP07).

**IOFS-Native:** Jeder LBF-Block lebt als IOFS-Data-Page (Typ `0x04 = LBF_Executable`) im Graphen. Der LBF-Block-Header wird durch den IOFS-Page-Header ersetzt (`LYX!`), der Nutzinhalt (4032 Bytes) bleibt identisch. Auf IOFS verlieren LBF-Blöcke ihre eigene Magic — sie sind reguläre IOFS-Pages eines speziellen Typs.

Die 64-Byte-Grenze ist die Naht zwischen den beiden Welten: Header-Ersatz, Nutzinhalt unverändert.

---

## 3. Datei-Struktur

Eine LBF-Datei besteht ausschließlich aus 4096-Byte-Blöcken. Sektionen beginnen an Block-Grenzen.

```
BLOCK 0     Genesis-Block   — Metadaten, KI-Kontext, Provenienz, Lifecycle
BLOCK 1..N  .text           — Maschinencode (R/X, Immutable)
BLOCK N+1.. .rodata         — Konstanten, String-Literale (R, Immutable)
BLOCK M+1.. .data           — Initialisierte Globale (R/W)
BLOCK K+1.. .bss            — Uninitialisierte Globale (R/W, kein physischer Block)
```

Jeder Block: 64-Byte-Header + 4032 Bytes Nutzinhalt. Das Layout ist in `lbf_workpackages.md` (Physische Konstanten) byte-genau spezifiziert.

---

## 4. Genesis-Block — Struktur

Der Genesis-Block (Block 0) ist das Kontrollzentrum jedes LBF-Programms. Er besteht aus:

**Core Machine Header:** Ziel-Architektur, Entry-Point, Sektionszähler, Stack-Größe, Gesamt-CRC32C.

**Compiler Provenance Block:** Compiler-Name, Version, Kompilierungs-Timestamp, Instanz-UUID, SHA-256 aller Quelldateien. Zusammen bilden diese Felder eine lückenlose Herkunftskette.

**TLV-Pool (3904 Bytes):** Erweiterbares Type-Length-Value-Verzeichnis für semantische Metadaten. Alle nicht-trivialen Programmeigenschaften leben hier.

---

## 5. TLV-Typen — Semantik

Der TLV-Pool ist der Erweiterungspunkt des Formats. Jeder Eintrag: `[Type: 1 Byte] [Length: 2 Bytes LE] [Value: Length Bytes]`.

### 0x01 — Human Readable Intent
UTF-8-String, der beschreibt was das Programm tut. Extrahiert vom Compiler aus `///`-Doc-Comments über `main()`. Ohne Doc-Comment: Dateiname. Dient der Semantischen Firewall (WP13) als Kohärenzgrundlage und dem IOFS-Omni-Ingest als Suchindex.

### 0x02 — Dependency Hash Graph
Array aus SHA-256-Hashes aller Bibliotheksabhängigkeiten. Auf IOFS: der Kernel löst diese Hashes beim Import zu LPIDs auf und webt Dependency-Kanten in den Graphen. Kein klassischer Linker nötig.

### 0x03 — Symbolic Export Interface
Exportierte Funktionen mit vollständigen Typ-Signaturen. Ermöglicht Dynamic Graph Linking: die System-KI verbindet zwei Programme direkt über Graph-Kanten ohne Dynamic-Linker-Lauf.

### 0x04 — Section Descriptor Table
Welche Blöcke welche Sektionen bilden und welche Speicherschutzrechte (R/W/X) sie bekommen. Vom Kernel direkt in CR3-Page-Table-Attribute übersetzt.

### 0x05 — Required Capabilities
Bitfeld welche Syscall-Kategorien das Binary benötigt (FS_READ, NET_SOCKET, KI_EMBED, ...). Die Semantische Firewall prüft Kohärenz zwischen Capabilities und Intent: ein Texteditor mit NET_SOCKET ohne entsprechende Intent-Beschreibung → Cognitive Prompt.

### 0x06 — Semantic Embedding Vector
LPID eines vorberechneten float32-Embedding-Vektors (erzeugt aus TLV 0x01). Auf POSIX: SHA-256 als Referenz, Vektor wird beim ersten IOFS-Import generiert. Dient semantischer Ähnlichkeitssuche (WP10).

### 0x07 — Build Reproducibility Manifest
Array aus (Dateiname, SHA-256)-Paaren aller Quelldateien. Macht den Build vollständig reproduzierbar und auditierbar.

### 0x08 — Lifecycle Descriptor
Deklarativer Prozess-Lebenszyklus. Dieser TLV ist der strukturelle Kern dessen, was klassische Betriebssysteme nie kannten: ein Binary das dem Kernel *vor* der ersten Ausführung mitteilt, wie es läuft — statt es der Runtime blind zu überlassen.

---

## 6. Lifecycle Descriptor — Design-Entscheidung

### Was die Geschichte lehrt

Klassische Systeme kennen den App-Lebenszyklus nicht statisch:

- **Windows Win32:** Manueller Message-Pump (`GetMessage`/`DispatchMessage`). Der Kernel weiß nicht ob ein Prozess wartet oder hängt → "Nicht reagierend".
- **Linux epoll:** Interessen werden erst zur Laufzeit registriert — zu spät für Scheduling-Optimierungen oder Lazy-Start.
- **macOS RunLoop:** Besser strukturiert, aber immer noch vollständig implizit im Binary.

In allen Systemen gilt: das Binary gibt dem Kernel eine Black Box. LBF löst das durch statische Deklaration.

### Die vier Lifecycle-Arten

**ONE_SHOT** (`0x00`) — Klassisches CLI-Programm. Startet, läuft, beendet sich. Keine Event-Quellen. Entspricht dem aktuell implementierten `_start`-Stub (LX-03: getrandom → CALL main → exit_group).

**EVENT_LOOP** (`0x01`) — Hat eine explizite Event-Schleife. Der Kernel kennt alle Event-Quellen im Voraus und richtet sie *vor* dem ersten `_start`-Aufruf ein. Das Binary muss nicht selbst `epoll_create`/`sigaction` aufrufen.

**DAEMON** (`0x02`) — Langlebiger Hintergrundprozess ohne Terminal. Kernel behandelt ihn strukturell als Service-Knoten im IOFS-Graphen (kein SIGHUP bei Session-Ende, eigener Prozess-Knoten-Typ).

**REACTIVE** (`0x03`) — Lazy-Start. Der Kernel startet den Prozess nicht sofort; er registriert nur die Event-Quellen. Erst beim ersten eingehenden Event wird der Prozess hochgefahren — optional direkt in den Handler, nicht in `_start`. Spart RAM für selten genutzte Dienste.

### Event-Quellen

Jede deklarierte Event-Quelle hat:
- Eine Art (stdin, timer/Hz, signal/Nr, net_accept, net_recv, iofs_event, ki_message, child_exit, audio_in)
- Optional einen dedizierten Entry-Point (`on_event_va`): statt durch `_start` zu gehen, springt der Kernel direkt in den Handler

### Quiescence-Stack

Deklarierter Stack-Bedarf im Idle-Zustand (in KB). Wenn alle Event-Quellen leer sind, kann der Kernel den physischen Stack-Footprint auf diesen Wert reduzieren und die restlichen Pages als swappable markieren.

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
@quiescence_stack(4)   // 4 KB im Idle ausreichend
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

**Schicht 3 — Compiler-Vertrauen:** Jede lyxc-Instanz hat eine UUID. Das OS hält eine Blacklist kompromittierter Compiler-Seriennummern; Binaries von geblacklisteten Compilern werden nicht ausgeführt.

**Schicht 4 — Intent-Kohärenz:** Die Semantische Firewall (WP13) prüft: ist TLV 0x01 (Intent) semantisch konsistent mit TLV 0x05 (Capabilities)? Inkohärenz → Cognitive Prompt oder Ausführungsverbot.

---

## 8. Zero-Load auf nativem IOFS

Das 4096-Byte-Alignment entfaltet seinen Vorteil beim nativen Start: Der Kernel übersetzt Block-LPIDs via LIP-Tabelle in physische NVMe-Sektoradressen (LBAs) und trägt diese direkt in die CPU-Page-Table (CR3) ein. Kein Segment wird kopiert.

**Ladezeit:** O(n) — n LIP-Lookups (je O(1)) + n PTE-Schreibvorgänge. Kein Parser, kein Allokator.

**Lifecycle-Integration:**
- Bei `EVENT_LOOP`: Kernel registriert alle TLV-0x08-Quellen *vor* dem ersten `_start`-Aufruf
- Bei `REACTIVE`: `sys_exec()` kehrt sofort zurück, kein CPU-Kontext wird erzeugt; Prozess startet erst beim ersten Event
- Bei gesetztem `quiescence_stack_kb`: Kernel reduziert physischen Stack im Idle, restauriert ihn vor jedem Event-Handler-Aufruf

---

## 9. POSIX-Kompatibilität

Auf Linux/macOS/Windows läuft LBF über `lbf_run` (WP07): `mmap()` mit korrekten Schutzrechten, Sprung zum Entry-Point. TLV 0x08 wird gelesen und von `lbf_dump` angezeigt, aber nicht ausgeführt — kein nativer Event-Router auf POSIX. `lbf_run` ist ein Kompatibilitätswerkzeug für die Entwicklungsphase, kein Produktionspfad.

---

## 10. Versions-Roadmap

| Version | Inhalt |
|---------|--------|
| v1.0 | Genesis-Block, TLV 0x01–0x08, Zero-Load, Lifecycle-Dispatch |
| v1.1 | TLV 0x09: Debug-Symboltabelle; TLV 0x0A: DWARF-Unwind-Frame |
| v1.2 | Multi-Arch-Fat-Binaries (x86-64 + ARM64) |
| v2.0 | LAB: Genesis-Block enthält LLM-Gewichts-Fragment — Programm und Inference-Modell in einer Datei |
