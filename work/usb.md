# USB-Anbindung in Lyx – Architektur & Umsetzungsfahrplan

> **Dokumenttyp:** Technischer Entwurf & Arbeitsplan
> **Zielsprache:** Lyx
> **Zielplattform:** Linux (ARM64 / x86_64)
> **Status:** Überarbeitete Fassung v2 (Mai 2026)

---

## 1. Einleitung

Da Lyx auf **Zero Dependencies** setzt, wird libusb oder jede andere C-Bibliothek komplett umgangen.
Dieses Dokument beschreibt die native USB-Anbindung über die Linux-Kernel-Schnittstelle `/dev/bus/usb/` und die `usbdevfs`-ioctl-API.

**Abgedeckte Transfer-Typen:**

| Typ | Priorität | Typische Anwendung |
|-----|-----------|-------------------|
| Control | 🔴 Hoch | Konfiguration, Befehle, Deskriptoranfragen |
| Bulk | 🔴 Hoch | Massenspeicher, Custom-USB-Geräte, Serial |
| Interrupt | 🔴 Hoch | HID-Tastaturen, Mäuse, Gamepads, Sensoren |
| Isochronous | 🟡 Mittel | Audio, Video (nicht auf allen Embedded-Plattformen verfügbar) |

> **Endianness-Hinweis:** USB-Deskriptoren sind per USB-Spezifikation **Little-Endian** kodiert. ARM64 und x86_64 sind ebenfalls Little-Endian – es ist daher kein Byte-Swap nötig. Bei einer zukünftigen Big-Endian-Portierung müssen alle `Word`- und `DWord`-Felder in USB-Deskriptoren nach dem Lesen umgedreht werden.

> **IOCTL-Code-Formel (64-Bit Linux):**
> `_IOC(dir, type, nr, size)` = `((dir << 30) | (size << 16) | (type << 8) | nr)`
> mit `_IOC_NONE=0`, `_IOC_WRITE=1`, `_IOC_READ=2`, `_IOC_RW=3`.
> Alle Codes in diesem Dokument gelten für **64-Bit**; auf 32-Bit unterscheiden sich die `sizeof`-Werte, da Pointer 4 statt 8 Bytes groß sind.

---

## 2. Architekturübersicht

```
+-------------------------------------------------------+
|                Dein Lyx-Programm                       |
+-------------------------------------------------------+
                        |
                        v
+-------------------------------------------------------+
|           std.hardware.usb (High-Level API)            |
|  (FindDevice, ClaimInterface, Control/Bulk/Interrupt)  |
+-------------------------------------------------------+
                        |
                        v
+-------------------------------------------------------+
|         Linux usbdevfs (ioctl-Ebene)                   |
|  USBDEVFS_CONTROL, USBDEVFS_BULK, USBDEVFS_URB        |
|  USBDEVFS_CLAIMINTERFACE, USBDEVFS_RELEASEINTERFACE   |
|  USBDEVFS_SUBMITURB, USBDEVFS_DISCARDURB              |
+-------------------------------------------------------+
                        |
                        v
+-------------------------------------------------------+
|            Linux-Kernel-Syscalls                       |
|  (sys_openat, sys_read, sys_ioctl, sys_close,         |
|   sys_getdents64, sys_lseek, sys_poll)                 |
+-------------------------------------------------------+
```

**Datenfluss bei der Geräteerkennung:**

```
/dev/bus/usb/             sys_getdents64
       │                        │
       v                        v
  001/001, 001/002 ...    Liste der Gerätedateien
       │                        │
       v                        v
  sys_openat + sys_read → Device Descriptor (18 Byte)
       │                        │
       v                        v
  Vendor/Product-ID prüfen → falls Treffer:
       │                        │
       v                        v
  sys_lseek(0) + sys_read → Vollständiger Descriptor-Strom
       │
       v
  ParseConfiguration → Config/Interface/Endpoint-Baum
```

---

## 3. Fahrplan – Arbeitspakete (WPs)

| WP  | Titel | Aufwand (geschätzt) | Priorität |
|-----|-------|---------------------|-----------|
| 1   | Low-Level-Syscalls bereitstellen | 1 PT | 🔴 Hoch |
| 1.1 | Hilfstypen & -funktionen (LinuxDirent64, IsNumeric, ParseNum, BuildPath) | 1 PT | 🔴 Hoch |
| 2   | USB-Descriptor-Typen abbilden | 2 PT | 🔴 Hoch |
| 2.1 | Configuration-Parsing (Descriptor-Strom parsen) | 2 PT | 🔴 Hoch |
| 3   | Geräteerkennung (Device Discovery) | 2 PT | 🔴 Hoch |
| 4   | Control-Transfers + Interface-Claim | 2 PT | 🔴 Hoch |
| 5   | Bulk-Transfers | 1 PT | 🔴 Hoch |
| 6   | Interrupt-Transfers (asynchron, URB-basiert) | 3 PT | 🔴 Hoch |
| 7   | AI‑Native Typsicherheit | 2 PT | 🔴 Geblockt (Generics fehlen) |
| 8   | Erweiterungen (Isochronous, Claim-Manager, URB-Pool) | 4 PT | 🟢 Niedrig |

*(PT = Personen-Tage, Richtwerte)*

---

### WP 1: Low-Level-Syscalls bereitstellen

#### Info

| Syscall-Name | ARM64-Nr. | Zweck |
|--------------|-----------|-------|
| `sys_openat` | 56 | Öffnet Gerätedateien in `/dev/bus/usb/` |
| `sys_read` | 63 | Liest USB-Deskriptoren und Transferdaten |
| `sys_write` | 64 | Schreiben auf Gerätedateien (selten benötigt) |
| `sys_ioctl` | 29 | usbdevfs-Operationen (Control, Bulk, Claim, …) |
| `sys_close` | 57 | Schließt Dateideskriptoren |
| `sys_lseek` | 62 | Setzt Dateiposition zurück (für erneutes Lesen des Descriptor-Stroms) |
| `sys_getdents64` | 217 | Listet Verzeichniseinträge von `/dev/bus/usb/` |
| `sys_poll` | 32 | Wartet auf asynchrone URB-Ereignisse (Interrupt-Transfers) |

> **Hinweis:** `sys_lseek` (Nr. 62) ist neu gegenüber der Vorversion. Er wird in WP 2.1 benötigt, um den Datei-Lesezeiger nach dem Einlesen des Device-Descriptors wieder auf Byte 0 zu setzen.

#### Abnahmekriterien
1. Jeder Syscall ist als Lyx-Intrinsic (`sys_*`) deklariert und in einem Testprogramm aufrufbar.
2. Der Compiler erzeugt die korrekte ARM64-`svc`-Instruktion mit der passenden Nummer in `x8`.
3. Ein Testprogramm kann mittels `sys_getdents64` den Inhalt eines beliebigen Verzeichnisses auslesen.
4. `sys_lseek(fd, 0, SEEK_SET)` setzt die Position in einer offenen Datei korrekt zurück.

---

### WP 1.1: Hilfstypen & -funktionen

Dieses WP definiert Typen und Hilfsfunktionen, die von mehreren anderen WPs benötigt werden. Es muss vor WP 2.1, WP 3 und WP 6 implementiert sein.

#### Info

```lyx
// std/hardware/usb_util.lyx
module usb_util;

// --- Hilfstyp für sys_getdents64 ---

type
    // Entspricht struct linux_dirent64 aus <dirent.h>
    // Das Feld d_name ist variabel lang – daher wird auf den Anfang
    // des Arrays gezeigt; die tatsächliche Länge ergibt sich aus d_reclen.
    LinuxDirent64 = packed record
        d_ino:    UInt64;               // Inode-Nummer
        d_off:    Int64;                // Offset zum nächsten Eintrag
        d_reclen: Word;                 // Gesamtlänge dieses Eintrags in Bytes
        d_type:   Byte;                 // Dateityp (DT_REG, DT_DIR, …)
        d_name:   array[0..0] of Char;  // Null-terminierter Name (variabel lang)
    end;

const
    DT_UNKNOWN = 0;
    DT_DIR     = 4;
    DT_REG     = 8;

    SEEK_SET = 0;
    SEEK_CUR = 1;
    SEEK_END = 2;

// --- Hilfsfunktionen ---

// Gibt true zurück, wenn alle Zeichen in str Ziffern (0–9) sind.
function IsNumeric(str: ^Char): Boolean;
var
    i: DWord;
begin
    i := 0;
    if str[0] = #0 then return false; // Leerstring = nicht numerisch
    while str[i] != #0 do
    begin
        if (str[i] < '0') or (str[i] > '9') then return false;
        i := i + 1;
    end;
    return true;
end;

// Parst einen Null-terminierten Dezimal-String als DWord.
function ParseNum(str: ^Char): DWord;
var
    i:      DWord;
    result: DWord;
begin
    result := 0;
    i      := 0;
    while str[i] != #0 do
    begin
        if (str[i] >= '0') and (str[i] <= '9') then
            result := result * 10 + (DWord(str[i]) - DWord('0'))
        else
            break;
        i := i + 1;
    end;
    return result;
end;

// Fügt zwei Pfadsegmente zusammen: BuildPath("/dev/bus/usb/", "001") → "/dev/bus/usb/001"
// Schreibt in buf (maximal buf_size Bytes inkl. NUL).
procedure BuildPath(base: ^Char; segment: ^Char; suffix: ^Char;
                    buf: ^Char; buf_size: DWord);
var
    i, j: DWord;
begin
    i := 0;
    // Basis kopieren
    while (i < buf_size - 1) and (base[i] != #0) do
    begin
        buf[i] := base[i];
        i := i + 1;
    end;
    // Segment anhängen
    j := 0;
    while (i < buf_size - 1) and (segment[j] != #0) do
    begin
        buf[i] := segment[j];
        i := i + 1;
        j := j + 1;
    end;
    // Optionales Suffix (z. B. "/") anhängen
    j := 0;
    while (i < buf_size - 1) and (suffix[j] != #0) do
    begin
        buf[i] := suffix[j];
        i := i + 1;
        j := j + 1;
    end;
    buf[i] := #0;
end;
```

#### Abnahmekriterien
1. `IsNumeric("001")` → `true`; `IsNumeric("00a")` → `false`; `IsNumeric("")` → `false`.
2. `ParseNum("042")` → `42`; `ParseNum("0")` → `0`.
3. `BuildPath("/dev/bus/usb/", "001", "/", buf, 64)` ergibt `/dev/bus/usb/001/`.
4. Kein Buffer-Overflow: `BuildPath` schreibt nie mehr als `buf_size` Bytes.

---

### WP 2: USB-Descriptor-Typen abbilden

#### Info

```lyx
// std/hardware/usb_types.lyx
module usb_types;

type
    // --- USB-Deskriptor-Kopf (gemeinsamer Anfang aller Deskriptoren) ---
    // Wird in ParseConfiguration zum Identifizieren des Typs genutzt.
    USBDescriptorHeader = packed record
        bLength:         Byte;   // Gesamtlänge dieses Deskriptors
        bDescriptorType: Byte;   // Typ: 1=Device, 2=Config, 4=Interface, 5=Endpoint, …
    end;

    // --- Device Descriptor (18 Bytes, USB 2.0 Spec §9.6.1) ---
    USBDeviceDescriptor = packed record
        bLength:            Byte;   // 18
        bDescriptorType:    Byte;   // 1
        bcdUSB:             Word;   // USB-Version (BCD, z. B. 0x0200 für USB 2.0)
        bDeviceClass:       Byte;
        bDeviceSubClass:    Byte;
        bDeviceProtocol:    Byte;
        bMaxPacketSize0:    Byte;   // Max. Paketgröße für EP0
        idVendor:           Word;   // Vendor-ID (Little-Endian)
        idProduct:          Word;   // Product-ID (Little-Endian)
        bcdDevice:          Word;
        iManufacturer:      Byte;
        iProduct:           Byte;
        iSerialNumber:      Byte;
        bNumConfigurations: Byte;
    end;

    // --- Configuration Descriptor (9 Bytes, USB 2.0 Spec §9.6.3) ---
    USBConfigurationDescriptor = packed record
        bLength:             Byte;
        bDescriptorType:     Byte;   // 2
        wTotalLength:        Word;   // Länge dieses + aller folgenden Deskriptoren
        bNumInterfaces:      Byte;
        bConfigurationValue: Byte;
        iConfiguration:      Byte;
        bmAttributes:        Byte;   // Bit 6: Self-Powered; Bit 5: Remote-Wakeup
        bMaxPower:           Byte;   // in 2-mA-Einheiten (z. B. 50 → 100 mA)
    end;

    // --- Interface Descriptor (9 Bytes, USB 2.0 Spec §9.6.5) ---
    USBInterfaceDescriptor = packed record
        bLength:            Byte;
        bDescriptorType:    Byte;   // 4
        bInterfaceNumber:   Byte;
        bAlternateSetting:  Byte;
        bNumEndpoints:      Byte;   // Anzahl der Endpunkte (ohne EP0)
        bInterfaceClass:    Byte;
        bInterfaceSubClass: Byte;
        bInterfaceProtocol: Byte;
        iInterface:         Byte;
    end;

    // --- Endpoint Descriptor (7 Bytes, USB 2.0 Spec §9.6.6) ---
    USBEndpointDescriptor = packed record
        bLength:          Byte;
        bDescriptorType:  Byte;   // 5
        bEndpointAddress: Byte;   // Bit 7: 0=OUT, 1=IN; Bits 0-3: EP-Nummer
        bmAttributes:     Byte;   // Bits 1-0: 0=Control, 1=Isochron, 2=Bulk, 3=Interrupt
        wMaxPacketSize:   Word;   // Max. Nutzdaten pro Paket
        bInterval:        Byte;   // Polling-Intervall (in ms für FS/LS; Frames für HS)
    end;

    // --- Höhere Lyx-Typen (aus den Deskriptoren aufgebaut) ---

    USBEndpointDirection = enum (Out, In);
    USBTransferType      = enum (Control, Isochronous, Bulk, Interrupt);

    USBEndpoint = record
        address:       Byte;                  // bEndpointAddress (roh)
        direction:     USBEndpointDirection;  // aus Bit 7 extrahiert
        number:        Byte;                  // Bits 0-3 von bEndpointAddress
        transfer_type: USBTransferType;       // aus Bits 1-0 von bmAttributes
        max_packet:    Word;
        interval:      Byte;
    end;

    USBInterface = record
        interface_number:  Byte;
        alternate_setting: Byte;
        class_code:        Byte;
        subclass_code:     Byte;
        protocol_code:     Byte;
        num_endpoints:     Byte;
        endpoints:         ^USBEndpoint;  // alloc(num_endpoints * SizeOf(USBEndpoint))
    end;

    USBConfiguration = record
        configuration_value: Byte;
        attributes:          Byte;
        max_power_ma:        Word;   // in mA (bMaxPower * 2)
        num_interfaces:      Byte;
        interfaces:          ^USBInterface;  // alloc(num_interfaces * SizeOf(USBInterface))
    end;

    USBDevice = record
        vendor_id:    Word;
        product_id:   Word;
        device_class: Byte;
        usb_version:  Word;       // bcdUSB
        bus_num:      Byte;
        dev_num:      Byte;
        handle:       Int;        // Dateideskriptor aus sys_openat (bleibt offen)
        num_configs:  Byte;
        configs:      ^USBConfiguration;  // alloc(num_configs * SizeOf(USBConfiguration))
    end;
```

> **Hinweis zu `packed record`:** Die vier Deskriptor-Typen (`USBDeviceDescriptor` etc.) sind wirklich byte-packed entsprechend der USB-Spezifikation. Die höheren Lyx-Typen (`USBEndpoint`, `USBInterface`, etc.) sind normale Records ohne Alignment-Anforderungen – hier wird kein `packed` benötigt.

> **Hinweis zu dynamischen Arrays:** `endpoints`, `interfaces`, `configs` werden mit `alloc()` auf dem Heap angelegt. Die Anzahl ist vorab aus dem jeweiligen Descriptor bekannt.

#### Abnahmekriterien
1. `SizeOf(USBDeviceDescriptor)` = 18, `SizeOf(USBConfigurationDescriptor)` = 9, `SizeOf(USBInterfaceDescriptor)` = 9, `SizeOf(USBEndpointDescriptor)` = 7.
2. Ein Testprogramm parst einen bekannten Device-Descriptor (aus einer Datei) korrekt.
3. `bEndpointAddress` Bit 7 wird korrekt in `USBEndpointDirection` übersetzt.
4. `bmAttributes` Bits 1-0 werden korrekt in `USBTransferType` übersetzt.

---

### WP 2.1: Configuration-Parsing (`ParseConfiguration`)

Dieses WP war in der Vorversion ein leerer Stub. Es implementiert das Einlesen und Dekodieren des vollständigen Descriptor-Stroms einer USB-Gerätedatei.

#### Info

Der Datei-Inhalt unter `/dev/bus/usb/BBB/DDD` ist ein kontinuierlicher Byte-Strom:
- Device Descriptor (18 Bytes)
- Configuration Descriptor (9 Bytes)
  - Interface Descriptor (9 Bytes)
    - [Class-spezifische Deskriptoren – werden übersprungen]
    - Endpoint Descriptor (7 Bytes) × N
  - weiterer Interface Descriptor × M
- weitere Configuration Descriptor × K

```lyx
// std/hardware/usb_parse.lyx
module usb_parse;

import usb_types;
import usb_util;

const
    USB_DT_DEVICE        = 1;
    USB_DT_CONFIG        = 2;
    USB_DT_INTERFACE     = 4;
    USB_DT_ENDPOINT      = 5;
    USB_MAX_DESC_BUF     = 4096;  // ausreichend für die meisten Geräte

// Liest den vollständigen Descriptor-Strom von dev_fd und befüllt device.
// Setzt den Datei-Lesezeiger vor dem Lesen auf Byte 0 zurück (sys_lseek).
function ParseConfiguration(dev_fd: Int; out device: USBDevice): Boolean;
var
    buf:       array[0..USB_MAX_DESC_BUF-1] of Byte;
    total:     Int;
    offset:    Int;
    hdr:       ^USBDescriptorHeader;
    dev_desc:  ^USBDeviceDescriptor;
    cfg_desc:  ^USBConfigurationDescriptor;
    ifc_desc:  ^USBInterfaceDescriptor;
    ep_desc:   ^USBEndpointDescriptor;
    cfg_idx:   Int;
    ifc_idx:   Int;
    ep_idx:    Int;
    cur_cfg:   ^USBConfiguration;
    cur_ifc:   ^USBInterface;
begin
    // Descriptor-Strom von vorne lesen
    if sys_lseek(dev_fd, 0, SEEK_SET) < 0 then return false;
    total := sys_read(dev_fd, addr(buf), USB_MAX_DESC_BUF);
    if total < 18 then return false;  // mind. ein Device-Descriptor nötig

    // Device-Descriptor (Byte 0..17) auswerten
    dev_desc := addr(buf[0]);
    device.num_configs  := dev_desc.bNumConfigurations;
    device.usb_version  := dev_desc.bcdUSB;
    device.device_class := dev_desc.bDeviceClass;

    if device.num_configs = 0 then return false;

    // Konfigurationsarray anlegen
    device.configs := alloc(device.num_configs * SizeOf(USBConfiguration));
    if device.configs = nil then return false;

    cfg_idx := -1;
    ifc_idx := -1;
    ep_idx  := 0;
    cur_cfg := nil;
    cur_ifc := nil;

    offset := dev_desc.bLength;  // ersten Deskriptor nach dem Device-Desc anspringen

    while offset + 2 <= total do
    begin
        hdr := addr(buf[offset]);

        // Korruptionsschutz: Länge muss mindestens 2 sein und in den Puffer passen
        if hdr.bLength < 2 then break;
        if offset + hdr.bLength > total then break;

        case hdr.bDescriptorType of

            USB_DT_CONFIG:
            begin
                cfg_idx := cfg_idx + 1;
                if cfg_idx >= device.num_configs then break;

                cfg_desc := addr(buf[offset]);
                cur_cfg  := addr(device.configs[cfg_idx]);

                cur_cfg.configuration_value := cfg_desc.bConfigurationValue;
                cur_cfg.attributes          := cfg_desc.bmAttributes;
                cur_cfg.max_power_ma        := DWord(cfg_desc.bMaxPower) * 2;
                cur_cfg.num_interfaces      := cfg_desc.bNumInterfaces;

                if cur_cfg.num_interfaces > 0 then
                begin
                    cur_cfg.interfaces := alloc(cur_cfg.num_interfaces * SizeOf(USBInterface));
                    if cur_cfg.interfaces = nil then return false;
                end;

                ifc_idx := -1;
            end;

            USB_DT_INTERFACE:
            begin
                if cur_cfg = nil then begin offset := offset + hdr.bLength; continue; end;

                ifc_idx := ifc_idx + 1;
                if ifc_idx >= cur_cfg.num_interfaces then
                begin
                    offset := offset + hdr.bLength;
                    continue;
                end;

                ifc_desc := addr(buf[offset]);
                cur_ifc  := addr(cur_cfg.interfaces[ifc_idx]);

                cur_ifc.interface_number  := ifc_desc.bInterfaceNumber;
                cur_ifc.alternate_setting := ifc_desc.bAlternateSetting;
                cur_ifc.class_code        := ifc_desc.bInterfaceClass;
                cur_ifc.subclass_code     := ifc_desc.bInterfaceSubClass;
                cur_ifc.protocol_code     := ifc_desc.bInterfaceProtocol;
                cur_ifc.num_endpoints     := ifc_desc.bNumEndpoints;

                if cur_ifc.num_endpoints > 0 then
                begin
                    cur_ifc.endpoints := alloc(cur_ifc.num_endpoints * SizeOf(USBEndpoint));
                    if cur_ifc.endpoints = nil then return false;
                end;

                ep_idx := 0;
            end;

            USB_DT_ENDPOINT:
            begin
                if cur_ifc = nil then begin offset := offset + hdr.bLength; continue; end;
                if ep_idx >= cur_ifc.num_endpoints then begin offset := offset + hdr.bLength; continue; end;

                ep_desc := addr(buf[offset]);

                cur_ifc.endpoints[ep_idx].address    := ep_desc.bEndpointAddress;
                cur_ifc.endpoints[ep_idx].number     := ep_desc.bEndpointAddress and $0F;
                cur_ifc.endpoints[ep_idx].max_packet := ep_desc.wMaxPacketSize;
                cur_ifc.endpoints[ep_idx].interval   := ep_desc.bInterval;

                if (ep_desc.bEndpointAddress and $80) != 0 then
                    cur_ifc.endpoints[ep_idx].direction := USBEndpointDirection.In
                else
                    cur_ifc.endpoints[ep_idx].direction := USBEndpointDirection.Out;

                case ep_desc.bmAttributes and $03 of
                    0: cur_ifc.endpoints[ep_idx].transfer_type := USBTransferType.Control;
                    1: cur_ifc.endpoints[ep_idx].transfer_type := USBTransferType.Isochronous;
                    2: cur_ifc.endpoints[ep_idx].transfer_type := USBTransferType.Bulk;
                    3: cur_ifc.endpoints[ep_idx].transfer_type := USBTransferType.Interrupt;
                end;

                ep_idx := ep_idx + 1;
            end;

            // Alle anderen Deskriptor-Typen (Class-spezifisch, HID, etc.)
            // werden übersprungen.
        end;

        offset := offset + hdr.bLength;
    end;

    // Erfolgreich, wenn mindestens eine Configuration geparst wurde
    return cfg_idx >= 0;
end;
```

#### Abnahmekriterien
1. `ParseConfiguration` eines bekannten USB-Geräts (z. B. USB-Hub) liefert korrekte `num_interfaces` und `num_endpoints`.
2. Ein Gerät mit 2 Konfigurationen und je 3 Interfaces wird vollständig in den Baum eingelesen.
3. Bei einem korrupten Deskriptor (`bLength = 0`) bricht die Funktion sauber ab.
4. Nach dem Aufruf ist jedes `interfaces`- und `endpoints`-Feld korrekt allokiert oder `nil` (wenn keine Endpoints vorhanden).
5. `sys_lseek`-Fehler (z. B. nicht-seekbare Datei) führt zu `return false`.

---

### WP 3: Geräteerkennung (Device Discovery)

#### Info

```lyx
// std/hardware/usb_discovery.lyx
module usb_discovery;

import usb_types;
import usb_parse;
import usb_util;

const
    USB_BUS_PATH     = "/dev/bus/usb/";
    USB_BUS_PATH_LEN = 256;

function FindDevice(vendor: Word; product: Word; out device: USBDevice): Int;
    // Rückgabe: 0 = Erfolg, -1 = nicht gefunden, -2 = keine Berechtigung
var
    bus_fd:   Int;
    buf:      array[0..2047] of Byte;
    num_read: Int;
    offset:   Int;
    entry:    ^LinuxDirent64;
    bus_dir:  array[0..USB_BUS_PATH_LEN-1] of Char;
    found:    Boolean;
begin
    bus_fd := sys_openat(AT_FDCWD, USB_BUS_PATH, O_RDONLY or O_DIRECTORY);
    if bus_fd < 0 then return -1;

    num_read := sys_getdents64(bus_fd, addr(buf), SizeOf(buf));
    sys_close(bus_fd);

    if num_read <= 0 then return -1;

    found  := false;
    offset := 0;

    while (offset < num_read) and (not found) do
    begin
        entry := addr(buf[offset]);

        if (entry.d_type = DT_DIR) and IsNumeric(addr(entry.d_name)) then
        begin
            BuildPath(USB_BUS_PATH, addr(entry.d_name), "/", addr(bus_dir), USB_BUS_PATH_LEN);
            ScanBusDirectory(addr(bus_dir), vendor, product, device, found);
        end;

        offset := offset + entry.d_reclen;
    end;

    if found then return 0;
    return -1;
end;

procedure ScanBusDirectory(dir: ^Char; vendor, product: Word;
                            out device: USBDevice; out found: Boolean);
var
    dir_fd:   Int;
    buf:      array[0..1023] of Byte;
    num_read: Int;
    offset:   Int;
    entry:    ^LinuxDirent64;
    dev_path: array[0..USB_BUS_PATH_LEN-1] of Char;
    dev_fd:   Int;
    desc:     USBDeviceDescriptor;
begin
    found  := false;

    dir_fd := sys_openat(AT_FDCWD, dir, O_RDONLY or O_DIRECTORY);
    if dir_fd < 0 then return;  // Verzeichnis nicht zugänglich → überspringen

    num_read := sys_getdents64(dir_fd, addr(buf), SizeOf(buf));
    sys_close(dir_fd);

    if num_read <= 0 then return;

    offset := 0;
    while (offset < num_read) and (not found) do
    begin
        entry := addr(buf[offset]);

        if (entry.d_type = DT_REG) and IsNumeric(addr(entry.d_name)) then
        begin
            BuildPath(dir, addr(entry.d_name), "", addr(dev_path), USB_BUS_PATH_LEN);

            // O_RDWR versuchen; Fallback auf O_RDONLY
            dev_fd := sys_openat(AT_FDCWD, addr(dev_path), O_RDWR);
            if dev_fd < 0 then
                dev_fd := sys_openat(AT_FDCWD, addr(dev_path), O_RDONLY);

            if dev_fd < 0 then
            begin
                // Dieses Gerät ist nicht zugänglich – weiter zum nächsten
                offset := offset + entry.d_reclen;
                continue;
            end;

            if sys_read(dev_fd, addr(desc), SizeOf(desc)) = SizeOf(desc) then
            begin
                if (desc.idVendor = vendor) and (desc.idProduct = product) then
                begin
                    device.vendor_id   := desc.idVendor;
                    device.product_id  := desc.idProduct;
                    device.handle      := dev_fd;
                    device.bus_num     := ParseNum(addr(entry.d_name));  // Bus-Num aus Pfad
                    device.dev_num     := ParseNum(addr(entry.d_name));  // Dev-Num aus Entry

                    if ParseConfiguration(dev_fd, device) then
                        found := true
                    else
                        sys_close(dev_fd); // Descriptor-Parsing fehlgeschlagen
                end
                else
                    sys_close(dev_fd); // Nicht das gesuchte Gerät
            end
            else
                sys_close(dev_fd); // Lesen des Descriptors fehlgeschlagen
        end;

        offset := offset + entry.d_reclen;
    end;
end;
```

> **Änderungen gegenüber v1:**
> - `String`-Typ durch explizite Char-Puffer ersetzt (Lyx hat kein natürliches String-Objekt mit Heap-Management).
> - Berechtigungsfehler (`dev_fd < 0`) führt jetzt zu `continue` statt `return` – alle Geräte im Verzeichnis werden geprüft, auch wenn einzelne nicht zugänglich sind.
> - `out`-Parameter für `found` statt Rückgabewert, damit `ScanBusDirectory` nicht abbricht wenn ein Gerät nicht zugänglich ist.

#### Abnahmekriterien
1. `FindDevice(0x1234, 0x5678, device)` findet ein angeschlossenes USB-Gerät mit dieser VID/PID.
2. Ist ein Gerät nicht zugänglich (fehlendes udev-Recht), wird es übersprungen; nachfolgende Geräte werden weiterhin geprüft.
3. Ein angeschlossener USB-Hub mit mehreren Kindern wird korrekt durchlaufen.
4. `device.configs` ist nach erfolgreichem `FindDevice` vollständig befüllt.

---

### WP 4: Control-Transfers + Interface-Claim

#### Info

**IOCTL-Code-Herleitung:**
- `USBDEVFS_CONTROL = _IOWR('U', 0, struct usbdevfs_ctrltransfer)`
  - `sizeof(usbdevfs_ctrltransfer)` auf 64-Bit = 24 Bytes (1+1+2+2+2+4 + 4 Padding + 8 Pointer)
  - = `(3 << 30) | (24 << 16) | (0x55 << 8) | 0` = **`0xC0185500`**
- `USBDEVFS_CLAIMINTERFACE = _IOW('U', 15, unsigned int)`
  - = `(1 << 30) | (4 << 16) | (0x55 << 8) | 15` = **`0x4004550F`**
- `USBDEVFS_RELEASEINTERFACE = _IOW('U', 16, unsigned int)`
  - = `(1 << 30) | (4 << 16) | (0x55 << 8) | 16` = **`0x40045510`**

```lyx
// std/hardware/usb_control.lyx
module usb_control;

const
    // 64-Bit Linux – aus Kernel-Headern verifiziert (Linux >= 2.6)
    USBDEVFS_CONTROL          = 0xC0185500;
    USBDEVFS_CLAIMINTERFACE   = 0x4004550F;
    USBDEVFS_RELEASEINTERFACE = 0x40045510;

    // Standard Request-Typen (USB 2.0 Spec §9.4)
    USB_DIR_OUT = $00;   // Host → Device
    USB_DIR_IN  = $80;   // Device → Host

    USB_REQ_GET_DESCRIPTOR    = 6;
    USB_REQ_SET_CONFIGURATION = 9;
    USB_REQ_GET_CONFIGURATION = 8;

    USB_DT_DEVICE        = 1;
    USB_DT_CONFIGURATION = 2;

type
    // sizeof = 24 auf 64-Bit (mit explizitem Padding-Feld)
    UsbDevFsCtrlTransfer = record
        bRequestType: Byte;
        bRequest:     Byte;
        wValue:       Word;
        wIndex:       Word;
        wLength:      Word;
        timeout:      DWord;   // in Millisekunden
        _pad:         DWord;   // explizites Padding für 8-Byte-Pointer-Alignment
        data:         Pointer; // 8 Bytes auf 64-Bit
    end;

function ControlTransfer(dev_fd: Int; request_type, request: Byte;
                         value, index: Word; data: Pointer;
                         length: Word; timeout: DWord): Int;
var
    ctrl: UsbDevFsCtrlTransfer;
begin
    ctrl.bRequestType := request_type;
    ctrl.bRequest     := request;
    ctrl.wValue       := value;
    ctrl.wIndex       := index;
    ctrl.wLength      := length;
    ctrl.data         := data;
    ctrl.timeout      := timeout;
    ctrl._pad         := 0;

    return sys_ioctl(dev_fd, USBDEVFS_CONTROL, addr(ctrl));
    // Rückgabe: Anzahl der übertragenen Bytes oder negativer Fehlercode
end;

function GetDeviceDescriptor(dev_fd: Int; out desc: USBDeviceDescriptor): Boolean;
begin
    return ControlTransfer(dev_fd,
        USB_DIR_IN or $00,              // bmRequestType: Device-to-Host, Standard, Device
        USB_REQ_GET_DESCRIPTOR,
        (USB_DT_DEVICE shl 8) or 0,    // wValue: Descriptor-Typ 1 (DEVICE), Index 0
        0,
        addr(desc),
        SizeOf(desc),
        5000
    ) >= 0;
end;

// Wichtig: USBDEVFS_CLAIMINTERFACE erwartet einen Zeiger auf unsigned int,
// nicht den Wert direkt.
function ClaimInterface(dev_fd: Int; interface_num: DWord): Boolean;
begin
    return sys_ioctl(dev_fd, USBDEVFS_CLAIMINTERFACE, addr(interface_num)) >= 0;
end;

function ReleaseInterface(dev_fd: Int; interface_num: DWord): Boolean;
begin
    return sys_ioctl(dev_fd, USBDEVFS_RELEASEINTERFACE, addr(interface_num)) >= 0;
end;
```

> **Bug-Fix gegenüber v1:** `ClaimInterface` und `ReleaseInterface` übergaben bisher den Wert direkt. `USBDEVFS_CLAIMINTERFACE` erwartet `unsigned int *` – ohne `addr()` schlägt der Syscall mit `-EINVAL` fehl.

> **Architekturhinweis:** Der Code `0xC0185500` gilt für 64-Bit. Auf 32-Bit ist `sizeof(usbdevfs_ctrltransfer)` = 16 (kein Padding vor dem 4-Byte-Pointer), der Code wäre dann `0xC0105500`.

#### Abnahmekriterien
1. `ControlTransfer` mit `USB_REQ_GET_DESCRIPTOR` liest den Device-Descriptor korrekt aus.
2. `ClaimInterface(dev_fd, 0)` beansprucht Interface 0 erfolgreich (kein `-EINVAL`).
3. `ReleaseInterface(dev_fd, 0)` gibt Interface 0 wieder frei.
4. Bei Timeout oder ungültigem `dev_fd` wird ein negativer Wert zurückgegeben.

---

### WP 5: Bulk-Transfers

#### Info

**IOCTL-Code-Herleitung:**
- `USBDEVFS_BULK = _IOW('U', 2, struct usbdevfs_bulktransfer)`
  - `sizeof(usbdevfs_bulktransfer)` auf 64-Bit = 24 Bytes (4+4+4 + 4 Padding + 8 Pointer)
  - = `(1 << 30) | (24 << 16) | (0x55 << 8) | 2` = **`0x40185502`**

```lyx
// std/hardware/usb_bulk.lyx
module usb_bulk;

const
    USBDEVFS_BULK = 0x40185502;  // _IOW('U', 2, usbdevfs_bulktransfer), 64-Bit

type
    // sizeof = 24 auf 64-Bit (mit explizitem Padding)
    UsbDevFsBulkTransfer = record
        ep:      DWord;   // Endpunkt-Adresse (Bit 7 = Richtung)
        len:     DWord;   // Anzahl der zu übertragenden Bytes
        timeout: DWord;   // in Millisekunden
        _pad:    DWord;   // explizites Padding für 8-Byte-Pointer-Alignment
        data:    Pointer; // 8 Bytes auf 64-Bit
    end;

function BulkTransfer(dev_fd: Int; endpoint: Byte; data: Pointer;
                      length: DWord; timeout: DWord): Int;
var
    bulk: UsbDevFsBulkTransfer;
begin
    bulk.ep      := endpoint;
    bulk.len     := length;
    bulk.timeout := timeout;
    bulk._pad    := 0;
    bulk.data    := data;

    return sys_ioctl(dev_fd, USBDEVFS_BULK, addr(bulk));
    // Rückgabe: Anzahl übertragener Bytes (Erfolg) oder negativer Fehlercode
end;

// endpoint muss OUT-Richtung haben (Bit 7 = 0); z. B. 0x01, 0x02, …
function BulkWrite(dev_fd: Int; endpoint: Byte; data: Pointer;
                   length: DWord; timeout: DWord): Int;
begin
    return BulkTransfer(dev_fd, endpoint, data, length, timeout);
end;

// endpoint muss IN-Richtung haben (Bit 7 = 1); z. B. 0x81, 0x82, …
function BulkRead(dev_fd: Int; endpoint: Byte; buffer: Pointer;
                  length: DWord; timeout: DWord): Int;
begin
    return BulkTransfer(dev_fd, endpoint, buffer, length, timeout);
end;
```

> **Änderung gegenüber v1:** Hardcodierter 1000ms-Timeout entfernt – `timeout` ist jetzt ein Parameter. Der Aufrufer kennt die Geräte-Latenz besser als die Bibliothek.

#### Abnahmekriterien
1. `BulkWrite(fd, 0x01, data, len, 1000)` sendet Daten an Endpunkt 1 OUT.
2. `BulkRead(fd, 0x81, buffer, len, 1000)` empfängt Daten von Endpunkt 1 IN.
3. Bei Timeout wird ein negativer Wert zurückgegeben (nicht blockiert).
4. Ein Write-Read-Test mit einem USB-Serial-Loopback-Adapter überträgt Daten korrekt.

---

### WP 6: Interrupt-Transfers (asynchron, URB-basiert)

#### Info

Interrupt-Transfers werden über **URBs** (USB Request Blocks) abgewickelt. Der Ablauf ist asynchron:
1. `SubmitURB` – URB einreichen (kehrt sofort zurück)
2. `poll()` – auf Abschluss warten
3. `ReapURB` – fertigen URB abholen und Daten lesen
4. URB erneut einreichen (muss nach jedem Reap explizit wiederholt werden)

**IOCTL-Code-Herleitung:**
- `USBDEVFS_SUBMITURB = _IOW('U', 10, struct usbdevfs_urb)`
  - `sizeof(usbdevfs_urb)` auf 64-Bit = 56 Bytes (siehe Layout-Kommentar unten)
  - = `(1 << 30) | (56 << 16) | (0x55 << 8) | 10` = **`0x4038550A`**
- `USBDEVFS_DISCARDURB = _IO('U', 11)` = **`0x0000550B`**
- `USBDEVFS_REAPURB = _IOW('U', 12, void *)` = **`0x4008550C`**
- `USBDEVFS_REAPURBNDELAY = _IOW('U', 13, void *)` = **`0x4008550D`**

```lyx
// std/hardware/usb_interrupt.lyx
module usb_interrupt;

const
    USBDEVFS_SUBMITURB     = 0x4038550A;
    USBDEVFS_DISCARDURB    = 0x0000550B;
    USBDEVFS_REAPURB       = 0x4008550C;  // blockierend
    USBDEVFS_REAPURBNDELAY = 0x4008550D;  // nicht blockierend

    USBDEVFS_URB_TYPE_ISO       = 0;
    USBDEVFS_URB_TYPE_INTERRUPT = 1;
    USBDEVFS_URB_TYPE_CONTROL   = 2;
    USBDEVFS_URB_TYPE_BULK      = 3;

type
    // Entspricht struct usbdevfs_urb aus <linux/usbdevice_fs.h>
    //
    // Layout auf 64-Bit (56 Bytes total):
    //   Offset  0: type          (1 Byte)
    //   Offset  1: endpoint      (1 Byte) – Bit 7: Richtung (1=IN, 0=OUT)
    //   Offset  2: _pad0         (2 Bytes Padding für int-Alignment)
    //   Offset  4: status        (4 Bytes, signed)
    //   Offset  8: flags         (4 Bytes)
    //   Offset 12: _pad1         (4 Bytes Padding für Pointer-Alignment)
    //   Offset 16: buffer        (8 Bytes Pointer)
    //   Offset 24: buffer_length (4 Bytes, signed)
    //   Offset 28: actual_length (4 Bytes, signed – Rückgabe vom Kernel)
    //   Offset 32: start_frame   (4 Bytes)
    //   Offset 36: number_of_packets (4 Bytes)
    //   Offset 40: error_count   (4 Bytes)
    //   Offset 44: signr         (4 Bytes, unsigned – NICHT Byte!)
    //   Offset 48: usercontext   (8 Bytes Pointer)
    //   Total: 56 Bytes
    UsbDevFsUrb = record
        typ:               Byte;     // USBDEVFS_URB_TYPE_*
        endpoint:          Byte;     // Endpunkt-Adresse inkl. Richtung in Bit 7
        _pad0:             Word;     // explizites Padding
        status:            Int;      // Fehlercode nach Abschluss (0 = OK)
        flags:             DWord;
        _pad1:             DWord;    // explizites Padding für Pointer-Alignment
        buffer:            Pointer;
        buffer_length:     Int;
        actual_length:     Int;      // vom Kernel befüllt
        start_frame:       Int;
        number_of_packets: Int;
        error_count:       Int;
        signr:             DWord;    // Signalnummer (0 = kein Signal) – unsigned int!
        usercontext:       Pointer;  // wird unverändert zurückgegeben
    end;

function SubmitInterruptRead(dev_fd: Int; endpoint: Byte;
                              buffer: Pointer; length: DWord;
                              context: Pointer): Int;
var
    urb: UsbDevFsUrb;
begin
    urb               := zero(UsbDevFsUrb);
    urb.typ           := USBDEVFS_URB_TYPE_INTERRUPT;
    urb.endpoint      := endpoint;   // z. B. 0x81 für IN-Endpunkt 1
    urb.buffer        := buffer;
    urb.buffer_length := length;
    urb.usercontext   := context;    // kann nil sein; wird beim Reap zurückgegeben

    return sys_ioctl(dev_fd, USBDEVFS_SUBMITURB, addr(urb));
end;

// Wartet bis ein URB fertig ist und gibt einen Zeiger auf ihn zurück.
// Rückgabe: Zeiger auf den fertigen URB (im Kernel-Speicher), nil bei Timeout/Fehler.
//
// WICHTIG: p_urb muss mit nil initialisiert werden – der Kernel überschreibt es.
function WaitForUrb(dev_fd: Int; timeout_ms: Int): ^UsbDevFsUrb;
var
    fds:   PollFd;
    ret:   Int;
    p_urb: ^UsbDevFsUrb;
begin
    fds.fd      := dev_fd;
    fds.events  := POLLIN;
    fds.revents := 0;

    ret := sys_poll(addr(fds), 1, timeout_ms);
    if ret <= 0 then return nil;  // Timeout oder Fehler

    // REAPURBNDELAY: der Kernel schreibt den Zeiger auf den fertigen URB in p_urb.
    // p_urb muss nil sein (nicht vorbelegt), da der Kernel es befüllt.
    p_urb := nil;
    ret   := sys_ioctl(dev_fd, USBDEVFS_REAPURBNDELAY, addr(p_urb));
    if ret < 0 then return nil;

    return p_urb;  // zeigt auf den URB, der gerade abgeschlossen wurde
end;

// Bricht einen laufenden URB ab.
// urb muss der Zeiger sein, der zuvor an SubmitInterruptRead übergeben wurde.
function DiscardUrb(dev_fd: Int; urb: ^UsbDevFsUrb): Boolean;
begin
    // USBDEVFS_DISCARDURB ist _IO (kein Datentransfer) – übergibt den Zeiger direkt.
    return sys_ioctl(dev_fd, USBDEVFS_DISCARDURB, urb) >= 0;
end;
```

> **Bug-Fix: `WaitForUrb`** – In der Vorversion wurde `p_urb := addr(urb)` vor dem ioctl gesetzt. Das ist falsch: `USBDEVFS_REAPURBNDELAY` überschreibt `p_urb` mit dem Kernel-Zeiger auf den fertigen URB. `p_urb` muss `nil` sein und dient nur als Ausgabe-Parameter.

> **Bug-Fix: `DiscardUrb`** – In der Vorversion stand `addr(urb)` (`^^ UsbDevFsUrb`). `USBDEVFS_DISCARDURB` ist `_IO` (keine Größe) und erwartet den URB-Zeiger direkt, kein Pointer-auf-Pointer.

> **Bug-Fix: `UsbDevFsUrb`** – Das Phantom-Feld `direction: Byte` (existiert nicht im C-Struct) wurde entfernt. `signr` war `Byte`, ist aber `unsigned int` (4 Bytes). Beide Fehler hätten alle URB-Zugriffe auf dem falschen Speicherlayout ausgeführt.

**Typische Anwendung (HID-Tastatur):**

```lyx
var
    report: array[0..7] of Byte;
    urb:    UsbDevFsUrb;
    done:   ^UsbDevFsUrb;

begin
    // Ersten URB einreichen
    SubmitInterruptRead(dev_fd, $81, addr(report), 8, nil);

    while true do
    begin
        done := WaitForUrb(dev_fd, 1000);
        if done != nil then
        begin
            if done.status = 0 then
                HandleKeyPress(addr(report), done.actual_length);

            // URB erneut einreichen (nötig nach jedem Reap)
            SubmitInterruptRead(dev_fd, $81, addr(report), 8, nil);
        end;
    end;
end;
```

#### Abnahmekriterien
1. `SubmitInterruptRead(fd, $81, buffer, 8, nil)` gibt 0 zurück (kein Fehler beim Submit).
2. `WaitForUrb(fd, 1000)` gibt einen gültigen Zeiger zurück, wenn eine Taste gedrückt wird.
3. Ohne Tastendruck läuft der 1000ms-Timeout korrekt ab (`WaitForUrb` gibt `nil` zurück).
4. `DiscardUrb(fd, addr(urb))` bricht einen laufenden URB ab (Rückgabe ≥ 0).
5. `done.actual_length` enthält die tatsächlich empfangenen Bytes (≤ 8).
6. Die CPU-Last im Wartezustand (nur `poll()`) ist < 1 %.

---

### WP 7: AI‑Native Typsicherheit – Compiler-Garantien für USB-Endpunkte

> **Status: 🔴 Geblockt** – Lyx unterstützt derzeit keine Generics/Templates (vgl. Risikotabelle). Identisches Problem wie GPIO-WP 4. Bis Generics implementiert sind, steht WP 7b als Makro-Fallback zur Verfügung.

#### WP 7a – Zielkonzept (Generics erforderlich)

```lyx
type
    Endpoint = generic<address: Byte, attrs: Byte>;

    BulkOutEndpoint = record[Endpoint<address, 2>]
        function Write(data: Pointer; length: DWord; timeout: DWord): Int;
    end;

    BulkInEndpoint = record[Endpoint<address, 2>]
        function Read(buffer: Pointer; length: DWord; timeout: DWord): Int;
    end;

    InterruptInEndpoint = record[Endpoint<address, 3>]
        procedure SubmitRead(buffer: Pointer; length: DWord): Int;
        function Wait(timeout_ms: Int): ^UsbDevFsUrb;
    end;

var
    EpOut: BulkOutEndpoint<$01>;
    EpIn:  BulkInEndpoint<$81>;
    Key:   InterruptInEndpoint<$81>;

begin
    EpOut.Write(data, len, 1000);   // OK
    // EpOut.Read(...);              // Compiler-Fehler
    EpIn.Read(buffer, len, 1000);   // OK
    // EpIn.Write(...);              // Compiler-Fehler
end.
```

**Weitere Compile-Time-Prüfungen:**

| Prüfung | Wirkung |
|---------|---------|
| `BulkOutEndpoint<$81>` (IN-Adresse für OUT-Typ) | Compiler-Warning: Bit 7 sollte 0 sein für OUT |
| Transfer-Typ-Konflikt | `InterruptInEndpoint<$81>` kann nicht mit `BulkTransfer` genutzt werden |
| Claim-Checker | Compiler stellt sicher, dass vor `Write`/`Read` ein `ClaimInterface` erfolgt ist |

#### WP 7b – Makro-Fallback (ohne Generics)

```lyx
macro DefineOutEndpoint(Name, Addr)
begin
    function Name##_Write(data: Pointer; length, timeout: DWord): Int
        = BulkWrite(current_dev_fd, Addr, data, length, timeout);
end;

macro DefineInEndpoint(Name, Addr)
begin
    function Name##_Read(buffer: Pointer; length, timeout: DWord): Int
        = BulkRead(current_dev_fd, Addr, buffer, length, timeout);
end;

DefineOutEndpoint(EpOut, $01);
DefineInEndpoint(EpIn, $81);
```

#### Abnahmekriterien (WP 7a – nach Generics-Implementierung)
1. `BulkOutEndpoint<$01>.Write(...)` kompiliert; `.Read(...)` erzeugt Compiler-Fehler.
2. `BulkInEndpoint<$81>.Read(...)` kompiliert; `.Write(...)` erzeugt Compiler-Fehler.
3. `BulkOutEndpoint<$81>` (falsche Richtung) erzeugt mindestens eine Compiler-Warning.
4. Zero-Cost-Abstraktion: identischer Maschinencode wie manueller Aufruf.

---

### WP 8: Erweiterungen

#### WP 8.1: Isochrone Transfers (Audio/Video)

##### Info

ISO-Transfers bieten garantierte Bandbreite ohne Fehlerkorrektur – verwendet für USB-Audio und USB-Video.

**IOCTL-Codes:** Gleich wie URB (`USBDEVFS_SUBMITURB`, `USBDEVFS_REAPURB`), Transfer-Typ = `USBDEVFS_URB_TYPE_ISO`.

```lyx
type
    // ISO-Paket-Deskriptor: beschreibt ein einzelnes ISO-Paket im Transfer
    UsbDevFsIsoPacket = record
        length:        DWord;   // gewünschte Länge
        actual_length: DWord;   // tatsächliche Länge (vom Kernel befüllt)
        status:        DWord;   // 0 = OK
    end;

    // ISO-URB: wie UsbDevFsUrb, aber mit angehängten ISO-Paket-Deskriptoren.
    // Das Layout ist: UsbDevFsUrb (56 Bytes) gefolgt von N × UsbDevFsIsoPacket.
    // Muss als zusammenhängendes alloc() angelegt werden.
    UsbDevFsIsoUrb = record
        urb:      UsbDevFsUrb;                    // Basis-URB (56 Bytes)
        packets:  array[0..0] of UsbDevFsIsoPacket; // variabel, nach urb im Speicher
    end;

function SubmitIsoRead(dev_fd: Int; endpoint: Byte;
                       buffer: Pointer; packet_size: DWord;
                       num_packets: DWord): ^UsbDevFsIsoUrb;
var
    iso_urb:     ^UsbDevFsIsoUrb;
    total_bytes: DWord;
    i:           DWord;
begin
    // Allokation: Basis-URB + N ISO-Paket-Deskriptoren
    iso_urb := alloc(SizeOf(UsbDevFsUrb) + num_packets * SizeOf(UsbDevFsIsoPacket));
    if iso_urb = nil then return nil;

    iso_urb.urb               := zero(UsbDevFsUrb);
    iso_urb.urb.typ           := USBDEVFS_URB_TYPE_ISO;
    iso_urb.urb.endpoint      := endpoint;
    iso_urb.urb.buffer        := buffer;
    iso_urb.urb.buffer_length := packet_size * num_packets;
    iso_urb.urb.number_of_packets := num_packets;

    // ISO-Paket-Deskriptoren initialisieren
    for i := 0 to num_packets - 1 do
    begin
        iso_urb.packets[i].length        := packet_size;
        iso_urb.packets[i].actual_length := 0;
        iso_urb.packets[i].status        := 0;
    end;

    if sys_ioctl(dev_fd, USBDEVFS_SUBMITURB, iso_urb) < 0 then
    begin
        dealloc(iso_urb);
        return nil;
    end;

    return iso_urb;
end;

function ReapIsoUrb(dev_fd: Int): ^UsbDevFsIsoUrb;
var
    p: Pointer;
begin
    p := nil;
    if sys_ioctl(dev_fd, USBDEVFS_REAPURB, addr(p)) < 0 then return nil;
    return p;
end;
```

##### Abnahmekriterien
1. `SubmitIsoRead` gibt einen gültigen Zeiger zurück und reicht den URB erfolgreich ein.
2. `ReapIsoUrb` liefert den fertigen URB nach dem nächsten ISO-Frame.
3. `packets[i].actual_length` enthält die empfangenen Bytes pro Paket.
4. `error_count` ist 0 bei fehlerfreier Übertragung.

---

#### WP 8.2: Claim/Release-Manager

##### Info

```lyx
type
    InterfaceClaim = record
        dev_fd:        Int;
        interface_num: DWord;
        is_claimed:    Boolean;
    end;

function Claim(var iface: InterfaceClaim): Boolean;
begin
    if iface.is_claimed then return true;
    iface.is_claimed := ClaimInterface(iface.dev_fd, iface.interface_num);
    return iface.is_claimed;
end;

procedure Release(var iface: InterfaceClaim);
begin
    if iface.is_claimed then
    begin
        ReleaseInterface(iface.dev_fd, iface.interface_num);
        iface.is_claimed := false;
    end;
end;
```

##### Abnahmekriterien
1. Doppeltes `Claim` ist idempotent.
2. `Release` → `Claim` funktioniert ohne Fehler.

---

#### WP 8.3: URB-Pool für Interrupt-Transfers

##### Info

Nach jedem `WaitForUrb` muss ein neuer URB eingereicht werden. Ein Pool mit mehreren URBs ermöglicht überlappende I/O – während ein URB verarbeitet wird, wartet der nächste bereits im Kernel.

```lyx
const
    URB_POOL_SIZE    = 4;
    URB_BUFFER_SIZE  = 64;  // Bytes pro URB-Puffer (an Gerät anpassen)

type
    UrbPoolEntry = record
        urb:    UsbDevFsUrb;
        buffer: array[0..URB_BUFFER_SIZE-1] of Byte;
        in_use: Boolean;
    end;

    UrbPool = record
        dev_fd:   Int;
        endpoint: Byte;
        entries:  array[0..URB_POOL_SIZE-1] of UrbPoolEntry;
    end;

// Initialisiert den Pool und reicht alle URBs beim Kernel ein.
function InitUrbPool(var pool: UrbPool; dev_fd: Int; endpoint: Byte): Boolean;
var
    i: DWord;
begin
    pool.dev_fd   := dev_fd;
    pool.endpoint := endpoint;

    for i := 0 to URB_POOL_SIZE - 1 do
    begin
        pool.entries[i].in_use := true;
        if SubmitInterruptRead(dev_fd, endpoint,
                               addr(pool.entries[i].buffer),
                               URB_BUFFER_SIZE,
                               addr(pool.entries[i])) < 0 then
        begin
            pool.entries[i].in_use := false;
            return false;
        end;
    end;
    return true;
end;

// Wartet auf den nächsten fertigen URB, ruft callback auf, reicht URB erneut ein.
procedure PollUrbPool(var pool: UrbPool; callback: procedure(data: Pointer; len: Int));
var
    done:  ^UsbDevFsUrb;
    entry: ^UrbPoolEntry;
begin
    done := WaitForUrb(pool.dev_fd, 100);
    if done = nil then return;

    entry := done.usercontext;  // zeigt auf den UrbPoolEntry (via usercontext)
    if (entry != nil) and (done.status = 0) then
        callback(addr(entry.buffer), done.actual_length);

    // URB erneut einreichen
    SubmitInterruptRead(pool.dev_fd, pool.endpoint,
                        addr(entry.buffer), URB_BUFFER_SIZE,
                        entry);
end;
```

##### Abnahmekriterien
1. `InitUrbPool` reicht alle 4 URBs erfolgreich ein.
2. `PollUrbPool` ruft den Callback bei jeder eingehenden Meldung auf.
3. Bei Geräte-Disconnect (`done.status = -ENODEV`) wird kein neuer URB eingereicht.

---

## 4. Abhängigkeiten zwischen den Arbeitspaketen

```
WP 1 (Syscalls)
  └── WP 1.1 (Hilfstypen: LinuxDirent64, IsNumeric, ParseNum, BuildPath)
        └── WP 2 (Descriptor-Typen: packed records + höhere Typen)
              └── WP 2.1 (ParseConfiguration: Descriptor-Strom → Config-Baum)
                    └── WP 3 (Device Discovery: FindDevice, ScanBusDirectory)
                          ├── WP 4 (Control + Claim/Release) ───── setzt WP 3 voraus
                          ├── WP 5 (Bulk) ─────────────────────── setzt WP 3 voraus
                          └── WP 6 (Interrupt/URB) ─────────────── setzt WP 3 voraus

WP 7a (Typsicherheit) ── GEBLOCKT bis Generics implementiert
WP 7b (Makro-Fallback) ── setzt WP 4, WP 5, WP 6 voraus

WP 8 (Erweiterungen)
  ├── WP 8.1 (ISO) ─────────── setzt WP 6 voraus (URB-Mechanik)
  ├── WP 8.2 (Claim-Manager) ── setzt WP 4 voraus (ClaimInterface)
  └── WP 8.3 (URB-Pool) ─────── setzt WP 6 voraus (Submit/Reap)
```

**Empfohlene Reihenfolge:**
1. WP 1 + WP 1.1 (Grundlage)
2. WP 2 (Typen)
3. WP 2.1 (Parsing – kritischer Pfad)
4. WP 3 (Discovery)
5. WP 4 + WP 5 parallel (Control + Bulk)
6. WP 6 (Interrupt)
7. WP 7b (Makro-Typsicherheit, parallel zu WP 8)
8. WP 8.1 + WP 8.2 + WP 8.3 parallel

---

## 5. Risiken und offene Fragen

| Risiko | Auswirkung | Maßnahme |
|--------|-----------|----------|
| **IOCTL-Codes architekturabhängig (32-/64-Bit)** | Falsche Codes führen zu stillen Fehlern | Codes per Build-Script aus `/usr/include/linux/usbdevice_fs.h` extrahieren und gegen Konstanten prüfen |
| **Kein Zugriff auf `/dev/bus/usb/`** | `openat` schlägt mit `-EPERM` fehl | udev-Regel für Gruppe `plugdev` oder `dialout`; Rückgabe `-2` dokumentiert |
| **USB-Gerät während Transfer abgesteckt** | ioctl schlägt mit `-ENODEV` fehl | Rückgabewert prüfen; URB-Pool bei `-ENODEV` nicht erneut einreichen |
| **Interrupt-URB-Puffergröße unbekannt** | Buffer-Overflow bei zu kleinen Puffern | HID-Report-Deskriptor parsen (nicht in diesem WP-Plan); sicherer Fallback: `wMaxPacketSize` aus Endpoint-Deskriptor |
| **Lyx unterstützt (noch) keine Generics** | WP 7a nicht umsetzbar | WP 7b als Makro-Fallback |
| **`sys_getdents64`-Puffer zu klein** | Geräte am Ende des Verzeichnisses werden nicht gefunden | Puffer iterativ vergrößern oder mehrfaches `getdents64` in Schleife (aktuell nicht implementiert) |
| **Gerät mit sehr großem Descriptor-Baum (> 4096 Bytes)** | `ParseConfiguration` liest Baum unvollständig | `USB_MAX_DESC_BUF` auf `wTotalLength` aus Configuration-Descriptor anpassen |
| **ISO-Transfers auf eingeschränkten Plattformen** | Kernel oder Bus unterstützt keine ISO-Bandbreite | Fehler bei `SubmitURB` auswerten; ISO als optional deklarieren |

---

## 6. Zusammenfassung

| Arbeitspaket | Status | Lieferumfang |
|-------------|--------|--------------|
| **WP 1** Syscalls | 🔜 | 8 ARM64-Syscall-Intrinsics inkl. `sys_lseek` |
| **WP 1.1** Hilfstypen/-funktionen | 🔜 | `LinuxDirent64`, `IsNumeric`, `ParseNum`, `BuildPath` |
| **WP 2** Descriptor-Typen | 🔜 | 4 packed Deskriptor-Typen + `USBDescriptorHeader` + 5 höhere Typen |
| **WP 2.1** Configuration-Parsing | 🔜 | `ParseConfiguration` (Descriptor-Strom → Config/Interface/Endpoint-Baum) |
| **WP 3** Device Discovery | 🔜 | `FindDevice` + `ScanBusDirectory` (kein Abbruch bei Einzelfehler) |
| **WP 4** Control + Claim | 🔜 | `ControlTransfer`, `ClaimInterface`, `ReleaseInterface` (mit korrektem `addr()`) |
| **WP 5** Bulk | 🔜 | `BulkWrite`, `BulkRead` (Timeout als Parameter) |
| **WP 6** Interrupt/URB | 🔜 | `SubmitInterruptRead`, `WaitForUrb`, `DiscardUrb` (alle Bugs behoben) |
| **WP 7a** Typsicherheit (Generics) | 🔴 Geblockt | `BulkOutEndpoint<N>`, `BulkInEndpoint<N>`, `InterruptInEndpoint<N>` |
| **WP 7b** Typsicherheit (Makros) | 🔜 | Makro-basierter Typ-Schutz als Übergang |
| **WP 8** Erweiterungen | 🟢 Niedrig | ISO-Transfers, Claim-Manager, URB-Pool |

**Behobene Fehler gegenüber v1:**

| Fehler | Behoben in |
|--------|-----------|
| `UsbDevFsUrb`: Phantom-Feld `direction` | **WP 6** |
| `UsbDevFsUrb`: `signr: Byte` statt `DWord` | **WP 6** |
| `WaitForUrb`: REAPURB-Zeiger vorbelegt statt nil | **WP 6** |
| `DiscardUrb`: `addr(urb)` statt `urb` | **WP 6** |
| `ClaimInterface`/`ReleaseInterface`: kein `addr()` | **WP 4** |
| Alle IOCTL-Codes falsch | **WP 4, WP 5, WP 6** |
| `LinuxDirent64` nie definiert | **WP 1.1** |
| `IsNumeric`, `ParseNum`, `BuildPath` nie definiert | **WP 1.1** |
| `ParseConfiguration` war leerer Stub | **WP 2.1** |
| `ScanBusDirectory` bricht bei erstem Berechtigungsfehler ab | **WP 3** |
| `sys_lseek` fehlte in Syscall-Tabelle | **WP 1** |
| WP 7 nicht als „geblockt" markiert | **WP 7** |
| Endianness nicht erwähnt | **Einleitung** |

---

*Stand: Mai 2026 – Überarbeitete Fassung v2 auf Basis des Code-Reviews*
