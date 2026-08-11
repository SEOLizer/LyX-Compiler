# Native PCI-Unterstützung — Implementierungsfahrplan

**Ziel:** PCI/PCIe-Geräte aus Lyx heraus finden, konfigurieren, per MMIO
ansteuern und (via VFIO) mit DMA und Interrupts betreiben — ohne C-FFI.

**Ort:** `std/hardware/pci*.lyx`, Fassade `std/hardware/pci.lyx`
**Branch-Namensschema:** `feat/pci-wp<nn>-<kürzel>`
**Stand:** Phase 1 und Phase 2 umgesetzt (PCI-01..08). Offen: Phase 3
(PCI-09/10, VFIO und Interrupts) und Phase 4 (PCI-11/12, Port-I/O und ECAM).

---

## Zugriffswege

PCI ist nicht ein Mechanismus, sondern vier. Der Unit-Schnitt folgt ihnen,
damit die Fassade auf allen Targets dieselbe API zeigt.

| Weg | Kann | Braucht | Ziel-Plattform |
|-----|------|---------|----------------|
| **sysfs** `/sys/bus/pci/devices/*` | Enumeration, Config-Space r/w, BAR-mmap (`resourceN`) | root (Schreiben), sonst nichts | Linux |
| **VFIO** `/dev/vfio` | DMA (IOMMU-Mapping), MSI/MSI-X über eventfd, exklusives Ownership | IOMMU aktiv, Device an `vfio-pci` gebunden | Linux |
| **Legacy-Port-CAM** 0xCF8/0xCFC | Config-Space ohne Kernel-Hilfe | `iopl`/`ioperm` + `asm{}`, x86-64 | Linux (root), LyxOS, bare metal |
| **ECAM-MMIO** | Config-Space PCIe, alle 4096 Bytes | physische Basis aus ACPI-MCFG, `/dev/mem` bzw. Kernel-Map | LyxOS, bare metal |

Nur sysfs zu bauen ergäbe ein Werkzeug ohne Treiberfähigkeit; nur Port-I/O
ergäbe etwas, das auf keinem normalen Linux-System nutzbar ist.

---

## Work-Package-Übersicht

| WP | Unit | Inhalt | Phase | Abhängig von |
|----|------|--------|-------|--------------|
| PCI-01 ✅ | `pci_types.lyx` | Konstanten: Config-Offsets, Header-Typen, BAR-Flags, Class-Codes, Cap-IDs, Fehlercodes | 1 | — |
| PCI-02 ✅ | `pci_syscalls.lyx` | `open/pread/pwrite/mmap/munmap/ioctl/close/eventfd`, BDF-Parse und -Format | 1 | — |
| PCI-03 ✅ | `pci_config.lyx` | `PciCfgRead8/16/32`, `PciCfgWrite8/16/32` mit Backend-Umschaltung | 1 | 01, 02 |
| PCI-04 ✅ | `pci_enum.lyx` | Geräte auflisten und filtern (sysfs + Brute-Force-Scan) | 1 | 03 |
| PCI-05 ✅ | `pci_bar.lyx` | BAR-Decode, Größe, `mmap`, MMIO-Zugriffe mit Barrieren | 2 | 03 |
| PCI-06 ✅ | `pci_caps.lyx` | Capability- und Extended-Capability-Liste, MSI/MSI-X, PCIe-Link | 2 | 03 |
| PCI-07 ✅ | `pci_ids.lyx` | Namensauflösung Vendor/Device/Class aus `pci.ids` | 2 | 02 |
| PCI-08 ✅ | `pci.lyx` | Fassade: `PciDevice`-Kontext, Öffnen/Suchen/Schließen | 2 | 03–07 |
| PCI-09 | `pci_vfio.lyx` | Container/Group/Device, `VFIO_IOMMU_MAP_DMA`, DMA-Puffer | 3 | 08 |
| PCI-10 | `pci_irq.lyx` | `VFIO_DEVICE_SET_IRQS`, eventfd-Warten, MSI-X-Vektortabelle | 3 | 09 |
| PCI-11 | `pci_portio.lyx` | `iopl`/`ioperm`, `asm{}` in/out, CF8-Adressrechnung | 4 | 03 |
| PCI-12 | `pci_ecam.lyx` | MCFG-Basis, ECAM-Adressrechnung, Mapping | 4 | 03 |

**Phase 1** liefert einen `lspci`-Klon als Beispiel — nachweisbar auf jedem
Linux ohne IOMMU, ohne Treiber-Unbind, für Lesen sogar ohne root.
**Phase 2** macht Geräte inspizierbar (Register-Dump, Link-Speed, Klarnamen).
**Phase 3** macht echte Userspace-Treiber möglich (Demo: NVMe-`Identify`).
**Phase 4** bringt denselben Header auf LyxOS und bare metal.

---

## PCI-01 — `pci_types.lyx`

Reine Konstanten-Unit, keine Logik.

Config-Space-Header Typ 0:

| Offset | Breite | Feld |
|--------|--------|------|
| 0x00 | 16 | Vendor-ID (0xFFFF = kein Gerät) |
| 0x02 | 16 | Device-ID |
| 0x04 | 16 | Command (Bit 0 IO-Space, 1 Mem-Space, 2 Bus-Master, 10 INTx-Disable) |
| 0x06 | 16 | Status (Bit 4 = Capability-Liste vorhanden) |
| 0x08 | 8 | Revision |
| 0x09 | 24 | Prog-IF, Subclass, Class |
| 0x0C | 8 | Cache-Line-Size |
| 0x0E | 8 | Header-Typ (Bit 7 = Multifunction) |
| 0x10–0x24 | 6×32 | BAR0–BAR5 |
| 0x2C | 16 | Subsystem-Vendor-ID |
| 0x2E | 16 | Subsystem-ID |
| 0x34 | 8 | Capability-Pointer |
| 0x3C | 8 | Interrupt-Line |
| 0x3D | 8 | Interrupt-Pin |

Capability-IDs: MSI 0x05, PCIe 0x10, MSI-X 0x11.
Extended-Caps ab 0x100 (nur PCIe, 16-Bit-ID + 12-Bit-Next).

Fehlercodes negativ und sprechend (`PCI_E_NODEV`, `PCI_E_PERM`,
`PCI_E_NOBACKEND`, `PCI_E_CAPLOOP`, `PCI_E_NOTSUP`) — kein Rückgabewert 0
für „ging nicht", weil 0 ein gültiger Registerinhalt ist.

## PCI-02 — `pci_syscalls.lyx`

Dünne Wrapper wie in `std/hardware/usb_syscalls.lyx`: eine Schicht, die
nichts entscheidet, damit die Logik darüber testbar bleibt.

- `pci_open(path, flags)`, `pci_pread(fd, buf, len, off)`, `pci_pwrite(...)`,
  `pci_mmap(...)`, `pci_munmap(...)`, `pci_ioctl(fd, req, arg)`, `pci_close(fd)`,
  `pci_eventfd(initval, flags)`
- `PciBdfParse(s: pchar): int64` → gepackt `(dom<<16)|(bus<<8)|(dev<<3)|fn`
- `PciBdfFormat(dest: pchar, bdf: int64): pchar` → `0000:03:00.0`
- `PciSysfsPath(dest, bdf, suffix)` → `/sys/bus/pci/devices/0000:03:00.0/config`

Parser akzeptiert beide Schreibweisen (`03:00.0` und `0000:03:00.0`);
alles andere ist ein Fehler, keine stillschweigende Null.

## PCI-03 — `pci_config.lyx`

Kontext (`alloc`-Block, peek/poke-Accessoren wie `gpio_mmio.lyx`):

```
+0   backend   (0 = unset, 1 = sysfs, 2 = portio, 3 = ecam)
+8   fd        (sysfs)  |  ecam-Basisadresse (ecam)
+16  bdf       gepackt
+24  ecam_len
```

`PciCfgRead8/16/32` und `PciCfgWrite8/16/32` schalten über `backend`.
**Der `else`-Zweig meldet `PCI_E_NOBACKEND`** — er tut nicht ersatzweise
irgendetwas Plausibles (Repo-Regel „stiller Default").

Schreibzugriffe auf 0x04 (Command) bekommen einen benannten Helfer
`PciEnableBusMaster` / `PciEnableMemSpace`, damit Aufrufer nicht selbst
Read-Modify-Write über ein 16-Bit-Feld basteln.

## PCI-04 — `pci_enum.lyx`

- sysfs-Weg: `DirList("/sys/bus/pci/devices")` aus `std/fs`, jeder Eintrag ist
  eine BDF. Vendor/Device/Class aus den gleichnamigen Dateien oder aus
  `config` — bevorzugt `config`, dann ist nur ein `open` nötig.
- Scan-Weg (bare metal, kein sysfs): Bus 0–255 × Device 0–31 × Function 0–7,
  Function > 0 nur wenn HDRTYPE Bit 7 gesetzt ist. Vendor-ID 0xFFFF = leer.
- API: `PciEnumFirst/PciEnumNext` (Iterator, keine Liste im Speicher),
  zusätzlich `PciFindByClass(class, subclass)` und `PciFindById(vid, did)`.

## PCI-05 — `pci_bar.lyx`

BAR-Decode: Bit 0 = 1 → I/O-Space (Adresse Bits 31:2), sonst Memory
(Typ Bits 2:1, 0b10 = 64 Bit → BAR belegt zwei Slots; Bit 3 = prefetchable,
Adresse Bits 63:4).

**Größe:** aus `/sys/bus/pci/devices/<bdf>/resource` (je Zeile
`start end flags`, Größe = `end - start + 1`). Der klassische Weg
(0xFFFFFFFF schreiben, zurücklesen, Original restaurieren) stört ein
laufendes Gerät und bleibt dem bare-metal-Pfad vorbehalten — dort mit
deaktiviertem Mem-/IO-Space-Bit und wiederhergestelltem Original.

Mapping: `mmap` auf `resourceN`. MMIO-Zugriffe `PciMmioRead8/16/32/64` und
`PciMmioWrite*` — jeder Schreibzugriff mit anschließender Barriere,
Muster und Begründung wie in `std/hardware/gpio_barriers.lyx`.

## PCI-06 — `pci_caps.lyx`

- Nur betreten, wenn Status-Bit 4 gesetzt ist.
- Von 0x34 aus der `next`-Kette folgen, Pointer & 0xFC, Ende bei 0.
- **Schleifenlimit 48 und Besuchs-Bitmap**; eine Kette, die auf sich selbst
  zeigt, liefert `PCI_E_CAPLOOP` statt zu hängen. (Test dafür ist Pflicht.)
- Extended-Caps ab 0x100 analog, Ende bei 0 oder 0xFFF.
- Parser: MSI (Message-Control, Adresse, Daten), MSI-X (Tabellen-BAR und
  -Offset aus dem Table-Offset-Register), PCIe (Link-Status → Speed, Width).

## PCI-07 — `pci_ids.lyx` + mitgelieferte `pci.ids`

**Die Datei wird mitgeliefert** (Entscheidung 2026-08-11).

- Quelle im Repo: `share/pci.ids` (~1,4 MB, Format des `hwdata`-Projekts,
  Lizenz BSD-3/GPL-2 dual — `share/pci.ids.LICENSE` mit ablegen).
- Paketbaum: `lyx-compiler/usr/share/lyx/pci.ids`, Installationspfad
  `/usr/share/lyx/pci.ids`. Makefile-Ziel analog zu `sync-units-src`.
- **Nicht als Lyx-Datenunit generieren.** Eine generierte Datenunit dieser
  Größe bringt lyxc zum Absturz (bekannte Grenze ~1 MB, poke-Initialisierung).
  Die Datei wird zur Laufzeit gelesen.

Suchreihenfolge des Loaders, erster Treffer gewinnt:

1. `$LYX_PCI_IDS` (Umgebungsvariable, für Tests und abweichende Installationen)
2. `/usr/share/lyx/pci.ids` (mitgeliefert)
3. `/usr/share/hwdata/pci.ids` (Systemkopie)
4. `/usr/share/misc/pci.ids` (Systemkopie, ältere Distributionen)

Findet er nichts, liefert `PciIdsOpen` `PCI_E_NODB`; die Namensfunktionen
geben dann `nil` zurück, **nicht** einen erfundenen Namen. Der `lspci`-Klon
zeigt in dem Fall die numerischen IDs und sagt einmal, dass die Datenbank
fehlt.

Format (Tabulator-Einrückung bestimmt die Ebene):

```
1002  Advanced Micro Devices, Inc. [AMD/ATI]
→1234  Gerätename
→→1043 1234  Subsystem-Name
C  03  Display controller
→00  VGA compatible controller
```

Implementierung: kein Vollparse in den Speicher (1,4 MB Text ergäbe
zehntausende Allokationen). Stattdessen einmaliger Scan beim Öffnen, der
Datei-Offsets je Vendor in einen kompakten Index (`vid → off`, sortiert,
binäre Suche) schreibt; Gerätenamen werden bei Bedarf aus dem Vendor-Block
gelesen. Der Klassen-Abschnitt (`C ...`) bekommt einen eigenen kleinen Index.

Als Fallback ohne Datei bleibt eine **kleine inline-Tabelle** der Class-Codes
(Bridge, Netzwerk, Display, Storage, USB …) in `pci_types.lyx` — die sind
im Standard festgeschrieben und kosten wenige Zeilen.

API: `PciIdsOpen()`, `PciIdsVendorName(db, vid)`, `PciIdsDeviceName(db, vid, did)`,
`PciIdsClassName(db, class, subclass)`, `PciIdsClose(db)`.

## PCI-08 — `pci.lyx` (Fassade)

Einziger Import für Anwender. `PciDevice`-Kontext hält BDF, Config-Backend,
bis zu sechs BAR-Mappings, optional die `pci.ids`-Handle.

```
PciOpen(bdf: int64): int64          // Kontext oder Fehlercode
PciOpenByPath(s: pchar): int64
PciFindByClass(cls, sub: int64): int64
PciVendorId(dev) / PciDeviceId(dev) / PciClass(dev)
PciMapBar(dev, idx: int64): int64   // virtuelle Basis
PciBarSize(dev, idx: int64): int64
PciClose(dev)
```

`PciClose` munmappt jede Map und schließt jeden fd — der Kontext ist die
einzige Stelle, die weiß, was offen ist.

## PCI-09 — `pci_vfio.lyx`

Ablauf: Group-Nummer aus dem symlink `/sys/bus/pci/devices/<bdf>/iommu_group`,
`/dev/vfio/vfio` (Container) öffnen, `/dev/vfio/<group>` öffnen,
`VFIO_GROUP_SET_CONTAINER`, `VFIO_SET_IOMMU` (Typ1),
`VFIO_GROUP_GET_DEVICE_FD`, dann `VFIO_DEVICE_GET_REGION_INFO` je BAR.

DMA: anonym gemappter Puffer + `VFIO_IOMMU_MAP_DMA` (IOVA frei wählbar,
einfacher Bump-Allokator über einen reservierten IOVA-Bereich).
`PciDmaAlloc(ctx, len)` liefert Paar (virtuelle Adresse, IOVA).

Vorbedingungen laut prüfen: kein IOMMU → `PCI_E_NOIOMMU` mit Hinweis auf
`intel_iommu=on`/`amd_iommu=on`; Device nicht an `vfio-pci` gebunden →
eigener Fehlercode. Keine automatische Umbindung — das reißt dem laufenden
System die Hardware weg.

## PCI-10 — `pci_irq.lyx`

`VFIO_DEVICE_SET_IRQS` mit einem Array von eventfds (INTx, MSI oder MSI-X).
`PciIrqWait(ctx, idx, timeout_ms)` über `poll` + `read` (8 Byte Zähler).
MSI-X-Vektortabelle liegt im BAR, den PCI-06 meldet — Adresse und Daten
schreibt der Kernel, die Unit maskiert/demaskiert nur.

## PCI-11 — `pci_portio.lyx`

`iopl(3)` (Syscall 172) oder gezielt `ioperm(0xCF8, 8, 1)` (Syscall 173),
danach `asm{}`-Blöcke mit `in`/`out` in 8/16/32 Bit.

Adresse: `0x80000000 | (bus<<16) | (dev<<11) | (fn<<8) | (off & 0xFC)`,
nach `0xCF8`; Daten aus `0xCFC + (off & 3)`.

**Nur x86-64.** Auf anderen Targets meldet jede Funktion `PCI_E_NOTSUP` —
sie liefert keinen Ersatzwert. Der Zugriff ist nicht atomar gegenüber dem
Kernel; die Unit dokumentiert das und ist für bare metal / LyxOS gedacht,
nicht für den Parallelbetrieb neben Linux-Treibern.

## PCI-12 — `pci_ecam.lyx`

Basis aus der ACPI-MCFG-Tabelle (Linux: `/sys/firmware/acpi/tables/MCFG`,
LyxOS: vom Kernel gereicht). Adresse:
`base + (bus<<20) + (dev<<15) + (fn<<12) + off`.
Mapping über `/dev/mem` (root, `iomem=relaxed` nötig) bzw. die LyxOS-Map.
Erreicht als einziger Weg den vollen 4096-Byte-Config-Space.

---

## Tests

Der Defekt säße hier in der Adress- und Kettenrechnung, nicht im Ergebnis
eines Registerlesens — geprüft wird also der Weg.

**Ohne Hardware, ohne root, im `test`-Target** (`tests/pci_unit_test.sh`):

- BDF-Parse/Format: beide Schreibweisen, Grenzwerte, Müll → Fehler.
- BAR-Decode gegen einen **synthetischen Config-Space-Puffer** im Speicher:
  32-Bit-Mem, 64-Bit-Mem (belegt zwei Slots), I/O, prefetchable, BAR = 0.
- Capability-Walk gegen denselben Puffer: normale Kette, leere Kette,
  Status-Bit 4 nicht gesetzt, **Zyklus** (`next` zeigt auf sich selbst) →
  muss `PCI_E_CAPLOOP` liefern und darf nicht hängen.
- CF8-Adressrechnung und ECAM-Adressrechnung gegen Referenzwerte.
- `pci_ids`-Parser gegen eine kleine Beispieldatei im Testverzeichnis
  (via `LYX_PCI_IDS`): Vendor, Device, Subsystem, Klasse, unbekannte ID →
  `nil`, kaputte Einrückung → kein Absturz.
- `pci_config`-Backend `0` → `PCI_E_NOBACKEND` (belegt, dass der
  Default-Zweig meldet statt zu raten).

**Mit Hardware, read-only** (`tests/pci_hw_test.sh`, eigene Suite):

- Host-Bridge `0000:00:00.0` lesen: Vendor-ID ≠ 0xFFFF, Header-Typ 0.
- Enumeration liefert ≥ 1 Gerät und jede gemeldete BDF ist auflösbar.
- Fehlt `/sys/bus/pci`, wird **mit Begründung übersprungen** — der Lauf sagt,
  dass er nichts geprüft hat, statt grün zu melden.

Beide Runner in `tests/suite-*.txt` bzw. ins `test`-Ziel eintragen, sonst
schlägt `test_coverage_test.sh` an (ein Test, der nicht läuft, ist schlimmer
als keiner).

---

## Fallstricke

- **Kein `&`/`|` in Vergleichsketten** — `flags & 1 == 1` parst falsch.
  BAR-Flag-Prüfungen brauchen Klammern.
- **Datenunit > ~1 MB bringt lyxc zum Absturz** → `pci.ids` bleibt eine
  Datei, wird nie zu Lyx-Quelltext generiert.
- **String-Literale sind keine Schreibpuffer** — Pfade werden in `alloc`ten
  Puffern zusammengesetzt.
- **BAR-Sizing per Write/Read-back stört aktive Geräte** — auf Linux die
  `resource`-Datei nutzen.
- **VFIO ohne IOMMU schlägt fehl**, `vfio-pci`-Bindung muss der Betreiber
  vornehmen. Die Unit bindet nichts selbst um.
- **`/dev/mem` ist auf vielen Kerneln durch `CONFIG_STRICT_DEVMEM` gesperrt** —
  PCI-12 meldet das als eigenen Fehler statt als „Adresse liest 0".
- **Lazy-Init tief im Callstack crasht** (bekannte Lyx-Eigenheit) — die
  `pci.ids`-Datenbank wird am `pub fn`-Eintritt eager initialisiert.

---

## Nicht enthalten (eigene Issues)

- Hotplug-Ereignisse (udev/netlink)
- SR-IOV (VF-Erzeugung)
- PCI-Bridge-Konfiguration und Ressourcen-Zuweisung (bare metal — nötig,
  sobald LyxOS ohne Firmware-Vorkonfiguration bootet)
- ASPM/Power-Management (Cap 0x01)
