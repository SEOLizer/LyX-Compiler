# Bluetooth-Anbindung in Lyx – Architektur & Umsetzungsfahrplan

> **Dokumenttyp:** Technischer Entwurf & Arbeitsplan
> **Zielsprache:** Lyx
> **Zielplattform:** Linux (ARM64 / x86_64) mit BlueZ
> **Abhängigkeiten:** Keine (Zero Dependencies – direkte Syscalls)
> **Status:** Überarbeiteter Entwurf (fokussiert auf Bluetooth-Kernthema)

---

## 1. Einleitung

Bluetooth (klassisch + BLE) ist für Embedded-Systeme und IoT unverzichtbar – sei es für Sensordaten, Audio-Streaming oder Gerätekopplung.
Da Lyx auf **Zero Dependencies** setzt, wird BlueZ nicht als Bibliothek gelinkt. Stattdessen kommuniziert Lyx direkt mit dem Linux-Kernel.

**Zwei-Wege-Ansatz:**

| Ebene | Methode | Technologie | Zweck |
|-------|---------|-------------|-------|
| **Data-Plane** | Native Sockets | `AF_BLUETOOTH` (L2CAP, RFCOMM) | Hochgeschwindigkeits-Datentransfer nach Verbindungsaufbau |
| **Control-Plane** | D‑Bus via Unix-Socket | `/var/run/dbus/system_bus_socket` | Discovery, Pairing, Adapter-Steuerung, GATT-Registrierung |

**Warum D‑Bus für die Control-Plane?**
BlueZ hält die HCI-Schnittstelle exklusiv. Ein direkter HCI-Socket (`SOCK_RAW`) wird von BlueZ blockiert, sobald der Daemon läuft. Der offizielle und stabile Weg ist D‑Bus.

**Warum Sockets für die Data-Plane?**
Sobald die Verbindung steht, liefern D‑Bus-Aufrufe zu hohe Latenzen. Native `AF_BLUETOOTH`-Sockets (`BTPROTO_L2CAP` für BLE, `BTPROTO_RFCOMM` für Classic) sind syscall-schnell und overhead-arm.

---

## 2. Architekturübersicht

```
+-------------------------------------------------------+
|                Dein Lyx-Programm                       |
+-------------------------------------------------------+
                        |
         +--------------+--------------+
         | Control-Plane               | Data-Plane
         v                             v
+-----------------------+   +-----------------------+
|  D-Bus via            |   |  AF_BLUETOOTH-Sockets  |
|  Unix-Socket          |   |  (L2CAP, RFCOMM)      |
|  (Discovery, Pairing, |   |  (ATT, GATT-Daten)    |
|   Adapter-Steuerung)  |   |                       |
+-----------------------+   +-----------------------+
         |                             |
         v                             v
+-------------------------------------------------------+
|              Linux-Kernel-Syscalls                     |
|  (sys_socket, sys_bind, sys_connect, sys_listen,      |
|   sys_accept, sys_sendto, sys_recvfrom, sys_getsockopt,|
|   sys_setsockopt, sys_poll, sys_ioctl, sys_readv,     |
|   sys_writev)                                          |
+-------------------------------------------------------+
                        |
                        v
+-------------------------------------------------------+
|              Bluetooth-Controller (HCI)                |
|              (USB / UART / SDIO)                      |
+-------------------------------------------------------+
```

**Datenfluss bei einer BLE-Verbindung (Heart Rate Monitor):**

```
1. D‑Bus:    Scan → Gerät entdecken ("00:1A:7D:DA:71:11")
2. D‑Bus:    Pairing initiieren + Bond speichern
3. Socket:   L2CAP-Socket öffnen → connect → ATT-Protokoll
4. Socket:   GATT-Read/Write (Charakteristik $2A37)
5. Socket:   GATT-CCCD setzen → Notifications aktivieren
6. Socket:   recv() empfängt Heart-Rate-Messwerte (zyklisch)
```

---

## 3. Fahrplan – Arbeitspakete (WPs)

| WP | Titel | Aufwand (geschätzt) | Priorität |
|----|-------|---------------------|-----------|
| 1  | Low-Level-Netzwerk-Syscalls bereitstellen | 2 PT | 🔴 Hoch |
| 2  | Bluetooth-Adress- und Socket-Typen | 2 PT | 🔴 Hoch |
| 3  | RFCOMM (Classic Bluetooth) – Client & Server | 4 PT | 🔴 Hoch |
| 4  | BLE L2CAP + ATT-Protokoll | 4 PT | 🔴 Hoch |
| 5  | D‑Bus-Control-Plane (BlueZ) | 4 PT | 🔴 Hoch |
| 6  | GATT-Client (Read, Write, Subscribe) | 3 PT | 🔴 Hoch |
| 7  | GATT-Server (eigene Services anbieten) | 3 PT | 🟡 Mittel |
| 8  | AI‑Native Typsicherheit | 3 PT | 🟡 Mittel |
| 9  | Erweiterungen (Scanner, Advertising, Mesh) | 4 PT | 🟢 Niedrig |

*(PT = Personen-Tage, Richtwerte)*

---

### WP 1: Low-Level-Netzwerk-Syscalls bereitstellen

#### Info
Für die Bluetooth-Kommunikation werden die folgenden Linux-Syscalls benötigt (ARM64‑Nummern):

| Syscall | ARM64-Nr. | Zweck |
|---------|-----------|-------|
| `sys_socket` | 198 | Erzeugt einen `AF_BLUETOOTH`-Socket |
| `sys_bind` | 200 | Bindet Socket an eine Bluetooth-Adresse |
| `sys_connect` | 203 | Stellt eine Verbindung zu einem Remote-Gerät her |
| `sys_listen` | 201 | Wartet auf eingehende Verbindungen (Server) |
| `sys_accept` | 202 | Nimmt eine eingehende Verbindung an |
| `sys_sendto` | 206 | Sendet Daten an einen bestimmten Endpunkt |
| `sys_recvfrom` | 207 | Empfängt Daten von einem Endpunkt |
| `sys_sendmsg` | 211 | Sendet Daten mit Hilfsdaten (Ancillary Data) |
| `sys_recvmsg` | 212 | Empfängt Daten mit Hilfsdaten |
| `sys_getsockopt` | 209 | Ruft Socket-Optionen ab (z. B. L2CAP_OMTU) |
| `sys_setsockopt` | 208 | Setzt Socket-Optionen |
| `sys_poll` | 32 | Wartet auf Ereignisse / asynchrone Benachrichtigungen |
| `sys_ioctl` | 29 | HCI-Device-Steuerung (optional) |
| `sys_close` | 57 | Schließt den Socket |

#### Grund
Anders als bei GPIO und USB, wo `sys_openat` + `sys_ioctl` dominieren, steht bei Bluetooth die **Socket-API** im Zentrum. Socket-Operationen sind eigene Syscalls (`sys_socket`, `sys_bind`, etc.) – ohne sie ist keine Bluetooth-Kommunikation möglich.

#### Abnahmekriterien
1. Jeder Syscall ist als Lyx-intrinsic (`sys_*`) deklariert.
2. Der Compiler erzeugt die korrekte ARM64-`svc`-Instruktion.
3. Ein Testprogramm kann einen `AF_BLUETOOTH`-Socket öffnen und wieder schließen.

---

### WP 2: Bluetooth-Adress- und Socket-Typen

#### Info
Die Linux-Kernel-Strukturen für Bluetooth müssen eins-zu-eins in Lyx-Typen abgebildet werden:

```lyx
// std/hardware/bluetooth_types.lyx
module bluetooth_types;

// --- Bluetooth-Adresse (6 Bytes, Little-Endian) ---
type
    BDAddr = packed record
        b: array[0..5] of Byte;
    end;

// --- Alternativ: als 6-Byte-Ganzzahl für einfachen Vergleich ---
// Wird oft als UInt64 gespeichert (obere 2 Bytes = 0)
type
    BDAddrInt = UInt64;

// --- Sockaddr für AF_BLUETOOTH ---
type
    SockAddrBt = packed record
        family:  Word;          // AF_BLUETOOTH = 31
        bdaddr:  BDAddr;        // lokale oder Remote-Adresse
        channel: Byte;          // RFCOMM-Kanal oder L2CAP-CID (PSM)
        status:  Byte;          // reserviert
    end;

// --- Bluetooth-Protokolle für socket() ---
const
    AF_BLUETOOTH    = 31;
    BTPROTO_L2CAP   = 0;
    BTPROTO_HCI     = 1;
    BTPROTO_RFCOMM  = 3;

// --- L2CAP-spezifische Optionen ---
const
    L2CAP_OPTIONS   = 1;
    L2CAP_LM        = 2;        // L2CAP Link Manager (Master/Slave, Security)
    L2CAP_OMTU      = 4;        // Output Maximum Transmission Unit
    L2CAP_IMTU      = 5;        // Input Maximum Transmission Unit

// --- RFCOMM-spezifische Optionen ---
const
    RFCOMM_LM       = 3;

// --- L2CAP Link Manager Flags ---
const
    L2CAP_LM_MASTER     = 1;
    L2CAP_LM_AUTH       = 2;
    L2CAP_LM_ENCRYPT    = 4;
    L2CAP_LM_SECURE     = 8;

// --- RFCOMM Link Manager Flags ---
const
    RFCOMM_LM_MASTER    = 1;
    RFCOMM_LM_AUTH      = 2;
    RFCOMM_LM_ENCRYPT   = 4;
    RFCOMM_LM_SECURE    = 8;

// --- Hilfsfunktionen ---

function BDAddrToString(addr: BDAddr): String;
begin
    // Formatiert als "XX:XX:XX:XX:XX:XX"
end;

function StringToBDAddr(s: String): Nullable<BDAddr>;
begin
    // Parst "XX:XX:XX:XX:XX:XX"
end;

function BDAddrToUInt64(addr: BDAddr): BDAddrInt;
begin
    Result := (BDAddrInt(addr.b[0]) shl  0) or
              (BDAddrInt(addr.b[1]) shl  8) or
              (BDAddrInt(addr.b[2]) shl 16) or
              (BDAddrInt(addr.b[3]) shl 24) or
              (BDAddrInt(addr.b[4]) shl 32) or
              (BDAddrInt(addr.b[5]) shl 40);
end;
```

#### Grund
Die Bluetooth-API von Linux arbeitet mit `struct sockaddr_rc` und `struct sockaddr_l2` über das generische `struct sockaddr`. Ohne die korrekten `packed record`-Typen können `sys_bind` und `sys_connect` keine gültigen Adressen übergeben.

Die `BDAddrInt`-Konvertierung erlaubt schnelle Vergleiche (MAC-Adresse als Ganzzahl), was für die Geräteerkennung wichtig ist.

#### Abnahmekriterien
1. `SizeOf(SockAddrBt)` beträgt 10 Bytes (2 + 6 + 1 + 1) – entspricht `sizeof(struct sockaddr_rc)`.
2. `BDAddrToString` und `StringToBDAddr` sind invers zueinander.
3. Ein Testprogramm kann eine MAC-Adresse parsen, in ein `SockAddrBt` packen und zurück konvertieren.

---

### WP 3: RFCOMM (Classic Bluetooth) – Client & Server

#### Info
RFCOMM emuliert eine serielle Schnittstelle über Bluetooth. Es ist die einfachste Möglichkeit für klassisches Bluetooth.

```lyx
// std/hardware/bluetooth_rfcomm.lyx
module bluetooth_rfcomm;

import bluetooth_types;

// --- RFCOMM-Client ---

function RFCommConnect(remote_addr: BDAddr; channel: Byte): Int;
    // Rückgabe: Socket-FD oder -1 bei Fehler
var
    fd:  Int;
    addr: SockAddrBt;
begin
    fd := sys_socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
    if fd < 0 then return -1;

    addr.family  := AF_BLUETOOTH;
    addr.bdaddr  := remote_addr;
    addr.channel := channel;

    if sys_connect(fd, addr(fd), SizeOf(addr)) < 0 then
    begin
        sys_close(fd);
        return -1;
    end;

    return fd;
end;

function RFCommSend(fd: Int; data: Pointer; length: DWord): Int;
begin
    Result := sys_sendto(fd, data, length, 0, nil, 0);
end;

function RFCommRecv(fd: Int; buffer: Pointer; length: DWord): Int;
begin
    Result := sys_recvfrom(fd, buffer, length, 0, nil, nil);
end;

// --- RFCOMM-Server ---

function RFCommListen(local_channel: Byte; backlog: Int): Int;
    // Rückgabe: Listening-Socket-FD oder -1
var
    fd:  Int;
    addr: SockAddrBt;
begin
    fd := sys_socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
    if fd < 0 then return -1;

    addr.family  := AF_BLUETOOTH;
    addr.bdaddr  := zero(BDAddr);    // any address
    addr.channel := local_channel;

    if sys_bind(fd, addr(addr), SizeOf(addr)) < 0 then
    begin
        sys_close(fd);
        return -1;
    end;

    if sys_listen(fd, backlog) < 0 then
    begin
        sys_close(fd);
        return -1;
    end;

    return fd;
end;

function RFCommAccept(listen_fd: Int; out remote_addr: BDAddr): Int;
    // Rückgabe: Client-Socket-FD oder -1
var
    addr: SockAddrBt;
    addr_len: DWord;
begin
    addr_len := SizeOf(addr);

    Result := sys_accept(listen_fd, addr(addr), addr(addr_len));
    if Result >= 0 then
        remote_addr := addr.bdaddr;
end;
```

#### Grund
RFCOMM ist der einfachste Einstieg in die Bluetooth-Programmierung. Viele klassische Bluetooth-Geräte (GPS-Mäuse, serielle Adapter, Drucker) nutzen RFCOMM. Die Implementation folgt dem bekannten Socket-Paradigma (open → bind/listen → accept/connect → send/recv → close).

#### Abnahmekriterien
1. `RFCommConnect` verbindet sich mit einem RFCOMM-Server (z. B. ein Bluetooth-SPP-Server auf einem Smartphone).
2. `RFCommSend` und `RFCommRecv` übertragen Daten bidirektional.
3. `RFCommListen` + `RFCommAccept` akzeptieren eine eingehende RFCOMM-Verbindung.
4. Bei Verbindungsabbruch wird -1 zurückgegeben.

---

### WP 4: BLE L2CAP + ATT-Protokoll

#### Info
BLE nutzt L2CAP als Transportschicht. Darüber läuft das **ATT** (Attribute Protocol), das die Grundlage für **GATT** (Generic Attribute Profile) bildet.

```lyx
// std/hardware/bluetooth_l2cap.lyx
module bluetooth_l2cap;

import bluetooth_types;

// --- L2CAP-Client ---

function L2CapConnect(remote_addr: BDAddr; psm: Word): Int;
    // psm: Protocol Service Multiplexer (z. B. 0x001F = ATT)
var
    fd:  Int;
    addr: SockAddrBt;
begin
    fd := sys_socket(AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP);
    if fd < 0 then return -1;

    addr.family  := AF_BLUETOOTH;
    addr.bdaddr  := remote_addr;
    addr.channel := psm and $FF;   // L2CAP-PSM wird im channel-Feld abgelegt

    if sys_connect(fd, addr(addr), SizeOf(addr)) < 0 then
    begin
        sys_close(fd);
        return -1;
    end;

    // L2CAP_IMTU auf 23 setzen (default MTU für ATT)
    var imtu: Word := 23;
    sys_setsockopt(fd, BTPROTO_L2CAP, L2CAP_IMTU, addr(imtu), SizeOf(imtu));

    return fd;
end;

// --- ATT-Paket-Struktur ---

type
    AttOpcode = Byte;

const
    ATT_OP_ERROR_RSP          = $01;
    ATT_OP_MTU_REQ            = $02;
    ATT_OP_MTU_RSP            = $03;
    ATT_OP_READ_REQ           = $0A;
    ATT_OP_READ_RSP           = $0B;
    ATT_OP_WRITE_REQ          = $12;
    ATT_OP_WRITE_RSP          = $13;
    ATT_OP_HANDLE_VALUE_NTF   = $1B;
    ATT_OP_HANDLE_VALUE_IND   = $1D;
    ATT_OP_WRITE_CMD          = $52;  // Write without response

type
    AttPacket = packed record
        opcode:  AttOpcode;
        payload: array[0..21] of Byte;  // MTU-23 → max 22 Byte Nutzdaten
    end;

function AttSend(l2cap_fd: Int; opcode: AttOpcode;
                 payload: Pointer; payload_len: Byte): Int;
var
    pkt: AttPacket;
begin
    pkt.opcode := opcode;
    if payload_len > 0 then
        CopyMemory(payload, addr(pkt.payload), payload_len);

    Result := sys_sendto(l2cap_fd, addr(pkt), 1 + payload_len, 0, nil, 0);
end;

function AttRecv(l2cap_fd: Int; out opcode: AttOpcode;
                 buffer: Pointer; buf_len: Byte): Int;
var
    pkt: AttPacket;
begin
    Result := sys_recvfrom(l2cap_fd, addr(pkt), SizeOf(pkt), 0, nil, nil);
    if Result > 0 then
    begin
        opcode := AttOpcode(pkt.opcode);
        CopyMemory(addr(pkt.payload), buffer, Result - 1);
    end;
end;
```

#### Grund
BLE ist der wichtigste Bluetooth-Standard für IoT. L2CAP ist die Transportschicht, ATT das Protokoll, über das alle GATT-Operationen laufen. Dieses WP baut die Brücke zwischen dem rohen Socket und der GATT-Ebene.

Die MTU von 23 Bytes ist der Bluetooth-Standard (kann über MTU-Request verhandelt werden).

#### Abnahmekriterien
1. `L2CapConnect` stellt eine L2CAP-Verbindung zu einem BLE-Gerät her (z. B. Heart-Rate-Sensor).
2. `AttSend` sendet ein ATT-Paket (z. B. MTU-Request).
3. `AttRecv` empfängt die zugehörige Antwort.
4. Ein vollständiger ATT-Read-Request/Response-Zyklus funktioniert.

---

### WP 5: D‑Bus-Control-Plane (BlueZ)

#### Info
BlueZ stellt seine Steuerungsfunktionen über D‑Bus auf dem System-Bus bereit. Lyx kommuniziert direkt über den Unix-Socket `/var/run/dbus/system_bus_socket`.

```lyx
// std/hardware/bluetooth_dbus.lyx
module bluetooth_dbus;

// --- D‑Bus-Protokoll (vereinfacht) ---

const
    DBUS_SYSTEM_BUS_SOCKET = "/var/run/dbus/system_bus_socket";

    // D‑Bus-Nachrichtentypen
    DBUS_MSG_TYPE_INVALID  = 0;
    DBUS_MSG_TYPE_METHOD_CALL  = 1;
    DBUS_MSG_TYPE_METHOD_RETURN = 2;
    DBUS_MSG_TYPE_ERROR    = 3;
    DBUS_MSG_TYPE_SIGNAL   = 4;

    // D‑Bus-Header-Flags
    DBUS_HEADER_FLAG_NO_REPLY_EXPECTED = $01;

    // BlueZ-D‑Bus-Schnittstellen (org.bluez)
    BLUEZ_INTERFACE        = "org.bluez";
    BLUEZ_ADAPTER1         = "org.bluez.Adapter1";
    BLUEZ_DEVICE1          = "org.bluez.Device1";
    BLUEZ_GATT_SERVICE1    = "org.bluez.GattService1";
    BLUEZ_GATT_CHARACTERISTIC1 = "org.bluez.GattCharacteristic1";

// --- High-Level-Funktionen ---

function BlueZOpenConnection(): Int;
    // Öffnet den D‑Bus-System-Socket
begin
    Result := sys_socket(AF_UNIX, SOCK_STREAM, 0);
    if Result < 0 then return -1;

    var addr: SockAddrUn;
    addr.family := AF_UNIX;
    CopyString(DBUS_SYSTEM_BUS_SOCKET, addr.path, SizeOf(addr.path));

    if sys_connect(Result, addr(addr), SizeOf(addr)) < 0 then
    begin
        sys_close(Result);
        return -1;
    end;
end;

function BlueZDiscoverDevices(dbus_fd: Int; adapter_path: String;
                               timeout_sec: DWord): Array of String;
    // Sendet eine org.bluez.Adapter1.StartDiscovery-Methode
    // und sammelt die Devices-Signale
begin
    // 1. D‑Bus-Method-Call: StartDiscovery
    // 2. poll() auf dbus_fd bis Signal eintrifft
    // 3. InterfacesAdded-Signal parsen → Gerätepfade extrahieren
    // 4. StopDiscovery
end;

function BlueZPairDevice(dbus_fd: Int; device_path: String): Boolean;
begin
    // Sendet Pair-Methode an org.bluez.Device1
end;

function BlueZConnectGatt(dbus_fd: Int; device_path: String): Nullable<BDAddr>;
    // Stellt die GATT-Verbindung her und liefert die MAC-Adresse
    // für den späteren L2CAP-Socket
begin
    // 1. Connect-Methode auf Device1 aufrufen
    // 2. MAC aus Properties auslesen
    // 3. MAC zurückgeben
end;
```

> **Hinweis:** D‑Bus ist ein binäres Protokoll mit Marshalling-Regeln (Alignment, Endianness, Typ-Codes). Eine vollständige Implementierung umfasst Method-Call/Return/Error/Signal-Handling, das Parsen von `org.freedesktop.DBus.Properties` und die BlueZ‑spezifischen Schnittstellen.

#### Grund
BlueZ ist der Standard-Bluetooth-Stack unter Linux. Der Zugriff auf HCI-Controller, Device-Discovery, Pairing und Bonding läuft ausschließlich über D‑Bus. Ohne diese Control-Plane ist kein sinnvoller Bluetooth-Betrieb möglich.

Der Umweg über D‑Bus ist notwendig, weil BlueZ den HCI-Controller exklusiv belegt und direkte `HCI_SOCK_RAW`-Zugriffe blockiert.

#### Abnahmekriterien
1. `BlueZOpenConnection` stellt eine Verbindung zum D‑Bus-System-Bus her.
2. `BlueZDiscoverDevices` findet Bluetooth-Geräte in der Umgebung (Test mit Smartphone).
3. `BlueZPairDevice` initiiert erfolgreich ein Pairing.
4. `BlueZConnectGatt` liefert die MAC-Adresse für den späteren L2CAP-Socket.

---

### WP 6: GATT-Client (Read, Write, Subscribe)

#### Info
GATT (Generic Attribute Profile) ist die Abstraktion über ATT. Der Client entdeckt Services, liest/schreibt Charakteristiken und abonniert Notifications.

```lyx
// std/hardware/bluetooth_gattc.lyx
module bluetooth_gattc;

import bluetooth_types;
import bluetooth_l2cap;
import bluetooth_dbus;

// --- Standard-GATT-Charakteristik-UUIDs ---

const
    GATT_PRIMARY_SERVICE    = $2800;
    GATT_CHARACTERISTIC     = $2803;
    GATT_CLIENT_CHAR_CONFIG = $2902;   // CCCD
    GATT_SERVER_CHAR_CONFIG = $2903;

    // Bekannte Profile
    HEART_RATE_SERVICE      = $180D;
    HEART_RATE_MEASUREMENT  = $2A37;
    BATTERY_SERVICE         = $180F;
    BATTERY_LEVEL           = $2A19;
    DEVICE_NAME             = $2A00;

// --- GATT-Client-Strukturen ---

type
    GattUuid = Word;       // 16-Bit-UUID (Standard)
    // Erweiterung: 128-Bit-UUIDs via array[0..15] of Byte

    GattCharacteristic = record
        declaration_handle: Word;
        properties:         Byte;
        value_handle:       Word;
        uuid:               GattUuid;
    end;

    GattService = record
        start_handle:   Word;
        end_handle:     Word;
        uuid:           GattUuid;
        characteristics: Array of GattCharacteristic;
    end;

// --- Funktionen ---

function GattDiscoverServices(l2cap_fd: Int): Array of GattService;
begin
    // Sendet ATT-Read-by-Group-Type-Request (UUID $2800)
    // Empfängt und parst die Service-Deskriptoren
end;

function GattReadChar(l2cap_fd: Int; value_handle: Word): Array of Byte;
begin
    // Sendet ATT-Read-Request (Opcode $0A)
    // Empfängt ATT-Read-Response (Opcode $0B)
end;

function GattWriteChar(l2cap_fd: Int; value_handle: Word;
                        data: Pointer; length: Word): Boolean;
begin
    // Sendet ATT-Write-Request (Opcode $12)
    // Empfängt ATT-Write-Response (Opcode $13)
end;

function GattWriteCmd(l2cap_fd: Int; value_handle: Word;
                       data: Pointer; length: Word): Boolean;
begin
    // Sendet ATT-Write-Command (Opcode $52) – ohne Antwort
end;

function GattEnableNotification(l2cap_fd: Int; cccd_handle: Word): Boolean;
begin
    // Schreibt $0001 in die CCCD (Client Characteristic Config)
    // Ermöglicht eingehende Notifications
end;

// --- Heart-Rate-Spezialisierung ---

type
    HeartRateMeasurement = packed record
        flags:           Byte;       // Bit 0: HR-Value-Format (0=UInt8, 1=UInt16)
        hr_value_8:      Byte;       // Herzfrequenz (UInt8)
        hr_value_16:     Word;       // Herzfrequenz (UInt16, wenn Bit 0 gesetzt)
        // Energieaufwand, RR-Intervalle folgen optional
    end;

function ReadHeartRate(l2cap_fd: Int; hr_handle: Word): Nullable<HeartRateMeasurement>;
begin
    var data := GattReadChar(l2cap_fd, hr_handle);
    if data.Length >= 2 then
        Result := Null(ParseHeartRate(data))
    else
        Result := Null(nil);
end;
```

#### Grund
GATT ist der wichtigste BLE-Profile-Standard. Ohne GATT-Client-Funktionen kann Lyx keine BLE-Geräte auslesen (Sensoren, Thermometer, Herzfrequenzgurte, etc.).

Die Heart-Rate-Messurement-Struktur zeigt exemplarisch, wie komplexe GATT-Profile in Lyx-Typen abgebildet werden.

#### Abnahmekriterien
1. `GattDiscoverServices` findet alle Services und Charakteristiken eines BLE-Geräts.
2. `GattReadChar(handle)` liest den aktuellen Wert einer Charakteristik.
3. `GattWriteChar(handle)` schreibt einen Wert (z. B. CCCD aktivieren).
4. `GattEnableNotification` aktiviert Notifications; danach treffen `ATT_HANDLE_VALUE_NTF`-Pakete ein.
5. `ReadHeartRate` gibt einen geparsten Herzfrequenzwert zurück (Test mit Brustgurt).

---

### WP 7: GATT-Server (eigene Services anbieten)

#### Info
Lyx kann selbst als BLE-Peripherie auftreten und eigene GATT-Services anbieten – z. B. ein Temperatursensor-Service oder eine Fernbedienung.

```lyx
// std/hardware/bluetooth_gatts.lyx
module bluetooth_gatts;

import bluetooth_types;
import bluetooth_l2cap;
import bluetooth_dbus;

type
    GattAttribute = record
        typ:        GattUuid;
        handle:     Word;
        permissions: Byte;
        value:      Array of Byte;
    end;

    GattServiceDef = record
        typ:        GattUuid;           // PRIMARY_SERVICE = $2800
        start_handle: Word;
        end_handle:   Word;
    end;

// --- Server-Initialisierung ---

function GattServerRegister(dbus_fd: Int; adapter_path: String): Boolean;
begin
    // 1. D‑Bus: GattManager1.RegisterApplication aufrufen
    // 2. Eigene Services/Charakteristiken als D‑Bus-Objekte anlegen
    // 3. Auf eingehende Read/Write-Requests reagieren
end;

function GattServerSendNotification(dbus_fd: Int; char_path: String;
                                     data: Pointer; length: Word): Boolean;
begin
    // Sendet über D‑Bus eine Handle-Value-Notification an verbundene Clients
end;
```

> **Hinweis:** Der GATT-Server unter BlueZ wird vollständig über D‑Bus abgewickelt (`org.bluez.GattManager1`, `org.bluez.GattCharacteristic1`). Anders als beim Client gibt es hier keine rohen ATT-Sockets – BlueZ erwartet die Profil-Registrierung über D‑Bus.

#### Grund
Viele Embedded-Anwendungen erfordern, dass das Gerät selbst als BLE-Peripherie auftritt (z. B. Sensor-Daten an ein Smartphone senden, Fernbedienung, Beacon). Ohne GATT-Server ist Lyx auf die Client-Rolle beschränkt.

#### Abnahmekriterien
1. `GattServerRegister` registriert einen benutzerdefinierten Service bei BlueZ.
2. Ein Smartphone (nRF Connect oder LightBlue) sieht den Service und kann die Charakteristik lesen.
3. `GattServerSendNotification` sendet eine Benachrichtigung an den verbundenen Client.

---

### WP 8: AI‑Native Typsicherheit – Bluetooth-Profile als Compiler-Typen

#### Info
Das folgende Konzept nutzt Lyx' Typsystem, um Bluetooth-Fehler bereits zur Compile-Zeit auszuschließen:

```lyx
// Typgebundene Bluetooth-Profile – der Compiler prüft die korrekte Verwendung

type
    // Ein Bluetooth-Gerät mit bekanntem Profil
    BLEDevice = generic<Address: BDAddr>;

    // Heart-Rate-Sensor: hat bekannte Charakteristiken
    HeartRateSensor = record[BLEDevice<"00:1A:7D:DA:71:11">]
        // Compiler-weiss: Service $180D, Char $2A37
        function ReadHeartRate(): Byte;
        function SubscribeHeartRate(): EventStream<HeartRateMeasurement>;
    end;

    // Temperatursensor-Server (eigener Service)
    TemperatureSensor = record
        temperature:    Byte;       // wird als GATT-Char $2A6E angeboten
        // Compiler erzeugt automatisch die GATT-Service-Definition
    end;

    // Endpunkt-Richtung (analog zu USB)
    GattCharacteristic = generic<handle: Word, uuid: GattUuid>;

    // Readable: Lesen erlaubt
    ReadableChar = record[GattCharacteristic<handle, uuid>]
        function Read(): Array of Byte;
        // Write() existiert nicht → Compiler-Fehler
    end;

    // Writable: Schreiben erlaubt
    WritableChar = record[GattCharacteristic<handle, uuid>]
        procedure Write(data: Pointer; length: Word);
        // Read() existiert nicht → Compiler-Fehler
    end;

    // Notifiable: Subscribe erlaubt
    NotifiableChar = record[GattCharacteristic<handle, uuid>]
        function Subscribe(): EventStream<Array of Byte>;
    end;

var
    Hrm:    ReadableChar<$2A37>;      // Heart Rate Measurement (lesen + notify)
    Config: WritableChar<$2902>;      // CCCD (schreiben)
begin
    var hr := Hrm.Read();             // ✅
    Config.Write(@cccd_value, 2);     // ✅
    // Hrm.Write(@data, len);         // ❌ Compiler-Fehler
end.
```

**Weitere Prüfideen:**

| Prüfung | Wirkung |
|---------|---------|
| **Profil-Vollständigkeit** | Der Compiler warnt, wenn ein Service nicht alle obligatorischen Charakteristiken hat |
| **UUID-Kollision** | Zwei Services mit derselben UUID werden abgelehnt |
| **Subscription ohne CCCD** | Der Compiler stellt sicher, dass eine `NotifiableChar` eine zugehörige CCCD (`$2902`) deklariert |
| **Richtungs-Check**| Lesen/Subscribe auf einem Write-Only-Endpunkt wird abgefangen |

#### Grund
Typische BLE-Fehler sind:
- Lesen von einer Charakteristik ohne Read-Eigenschaft → Kernel-Fehler
- Schreiben auf eine Read-Only-Charakteristik → `-EINVAL`
- Notification ohne aktivierte CCCD → Daten kommen nie an
- Falsche UUID im Code (Tippfehler) → stundenlanges Debugging

Der Lyx-Compiler kann solche Fehler **vor dem Ausliefern** abfangen.

#### Abnahmekriterien
1. `ReadableChar<$2A37>.Read()` wird kompiliert; `.Write(...)` erzeugt Compiler-Fehler.
2. `WritableChar<$2902>.Write(...)` wird kompiliert; `.Read()` erzeugt Compiler-Fehler.
3. `NotifiableChar<$2A37>.Subscribe()` erzeugt einen EventStream; ohne CCCD-Deklaration Warning.
4. `HeartRateSensor.ReadHeartRate()` und `.SubscribeHeartRate()` sind Typsicher.

---

### WP 9: Erweiterungen (Scanner, Advertising, Mesh)

#### Info
Erweiterte BLE-Funktionen, die nicht für den ersten Release nötig sind, aber langfristig die Plattform abrunden.

##### WP 9.1: BLE Scanner (passiv + aktiv)

```lyx
type
    BleScanResult = record
        address:      BDAddr;
        rssi:         Int;
        advertisement: Array of Byte;
        is_connectable: Boolean;
    end;

function BleScan(dbus_fd: Int; timeout_sec: DWord): Array of BleScanResult;
begin
    // Nutzt D‑Bus-Signal org.bluez.Device1.InterfacesAdded
end;
```

##### WP 9.2: BLE Advertising (als Peripherie)

```lyx
type
    AdvertisementData = record
        local_name:  String;
        service_uuids: Array of GattUuid;
        tx_power:    ShortInt;
        manufacturer_data: Array of Byte;
    end;

function BleAdvertise(dbus_fd: Int; adapter_path: String;
                       data: AdvertisementData): Boolean;
begin
    // Nutzt org.bluez.LEAdvertisingManager1
end;
```

##### WP 9.3: Bluetooth Mesh

> **Hinweis:** Mesh wird von BlueZ erst seit Kernel 5.x unterstützt und ist protokollarisch sehr komplex. Hier ist eine reine D‑Bus-Lösung angedacht, sobald BlueZ Mesh vollständig unterstützt.

#### Grund
- **Scanner:** Bevor man ein Gerät kennt, muss man es finden. Der Scanner ist die Grundlage für jede BLE-Interaktion.
- **Advertising:** Für IoT-Sensoren, Beacon-Anwendungen und eigene Peripherie.
- **Mesh:** Für industrielle IoT-Netzwerke mit vielen Knoten (Beleuchtung, Gebäudeautomatisierung).

#### Abnahmekriterien
1. `BleScan` findet alle BLE-Geräte in Reichweite und liefert RSSI + Adressdaten.
2. `BleAdvertise` macht das Lyx-Gerät für andere BLE-Scanner sichtbar.
3. Advertising-Daten (Local Name, UUIDs) werden korrekt übertragen (sichtbar in nRF Connect).

---

## 4. Abhängigkeiten zwischen den Arbeitspaketen

```
WP 1 (Netzwerk-Syscalls) ─── Grundlage
  ├── WP 2 (Adress-/Socket-Typen) ─── Grundlage für WP 3 + WP 4
  │    ├── WP 3 (RFCOMM) ─────────── setzt WP 1 + WP 2 voraus
  │    └── WP 4 (L2CAP + ATT) ────── setzt WP 1 + WP 2 voraus
  │         └── WP 6 (GATT-Client) ─ setzt WP 4 voraus
  │              └── WP 7 (GATT-Server) ─ setzt WP 6 voraus (Kenntnis GATT)
  └── WP 5 (D‑Bus Control-Plane) ─── setzt WP 1 voraus (socket/connect)
       ├── WP 6 (GATT-Client) ────── benötigt D‑Bus für Connect + Pairing
       ├── WP 7 (GATT-Server) ────── benötigt D‑Bus für GattManager1
       └── WP 9 (Erweiterungen) ──── setzt D‑Bus voraus

WP 8 (Typsicherheit) ─── setzt WP 2 + WP 6 voraus (GATT-Typen)
```

**Empfohlene Reihenfolge:**
1. WP 1 (Syscalls)
2. WP 2 (Grundtypen)
3. WP 3 (RFCOMM) + WP 5 (D‑Bus) – parallel
4. WP 4 (L2CAP + ATT)
5. WP 6 (GATT-Client)
6. WP 7 (GATT-Server) + WP 8 (Typsicherheit) – parallel nach WP 6
7. WP 9 (Erweiterungen) – nachlaufend

---

## 5. Risiken und offene Fragen

| Risiko | Auswirkung | Maßnahme |
|--------|-----------|----------|
| **D‑Bus-Protokoll komplex** (Marshalling, Alignment, vs. XML‑Schnittstellenbeschreibung) | Falsch aufgebaute D‑Bus-Nachrichten werden still ignoriert | Schrittweise Annäherung zuerst mit festen BlueZ-Aufrufen; keine General‑Purpose‑D‑Bus-Bibliothek |
| **BlueZ-Versionsunterschiede** (≤5.50 vs. ≥5.55) | D‑Bus-Schnittstellen ändern sich (z. B. GATT-Server-API) | Abwärtskompatibilitätsschicht; Dokumentation der getesteten BlueZ-Version |
| **HCI-RAW blockiert** | Direkter HCI-Zugriff unmöglich, falls BlueZ läuft | Kein HCI-RAW; konsequent auf D‑Bus + AF_BLUETOOTH-Sockets setzen |
| **BLE-MTU-Verhandlung** (Standard 23, kann bis 512 wachsen) | ATT-Pakete >23 Byte werden still gekappt | `L2CAP_IMTU`-Sockopt setzen; MTU-Request/Antwort vor erstem Read |
| **BtMesh noch experimentell** | Mesh-Features instabil oder nicht vorhanden | Mesh als WP 9.3 mit Status „alpha“ kennzeichnen |
| **Lyx unterstützt (noch) keine Generics/Templates** | WP 8 nicht umsetzbar | Typsicherheit auf Makro-Ebene abbilden |

---

## 6. Abgrenzung zu anderen Themen der Urversion

Die Urversion von `bluetooth.md` enthielt auch:
- **Bitfields** (HCI-Paket-Struktur)
- **io_uring** als Standard-Laufzeit
- **Wi‑Fi** via nl80211
- **I²C / SPI**

Diese Themen **gehören nicht in dieses Dokument**, sondern in separate Architekturpapiere:

| Thema | Empfohlenes Dokument | Status |
|-------|----------------------|--------|
| Deterministische Bitfields | `bitfields.md` oder im Lyx-Compiler-Spec | 🔜 Noch zu schreiben |
| io_uring | `io_uring.md` oder Teil von `std.io` | 🔜 Noch zu schreiben |
| Wi‑Fi (nl80211) | `net_wifi.md` | 🔜 Noch zu schreiben |
| I²C / SPI | `hardware_bus.md` | 🔜 Noch zu schreiben |

---

## 7. Zusammenfassung

Das überarbeitete Dokument beschreibt einen **vollständigen Fahrplan** zur Bluetooth-Anbindung in Lyx:

| Arbeitspaket | Status (geplant) | Lieferumfang |
|-------------|------------------|--------------|
| **WP 1** Low-Level-Netzwerk-Syscalls | 🔜 | 13 ARM64-Syscall-Intrinsics |
| **WP 2** Bluetooth-Adress-/Socket-Typen | 🔜 | `BDAddr`, `SockAddrBt`, Konstanten, Konvertierung |
| **WP 3** RFCOMM (Classic Bluetooth) | 🔜 | `RFCommConnect`, `RFCommListen`, `RFCommSend`/`Recv` |
| **WP 4** BLE L2CAP + ATT | 🔜 | `L2CapConnect`, `AttSend`/`AttRecv` |
| **WP 5** D‑Bus-Control-Plane (BlueZ) | 🔜 | Discovery, Pairing, Adapter-Steuerung |
| **WP 6** GATT-Client | 🔜 | Service-Discovery, Read/Write/Subscribe |
| **WP 7** GATT-Server | 🔜 | Eigene Services, Notifications |
| **WP 8** AI‑Native Typsicherheit | 🔜 | `ReadableChar`, `WritableChar`, `NotifiableChar` |
| **WP 9** Erweiterungen | 🔜 | Scanner, Advertising, Mesh |

Gegenüber der Urversion wurden behoben:

| Problem der Urversion | Behoben |
|-----------------------|---------|
| Themen-Sammelsurium (BT + Wi‑Fi + I²C + io_uring) | **Kapitel 6** – klare Abgrenzung, separate Dokumente vorgeschlagen |
| Keine Markdown-Überschriften | ✅ Saubere `##`/`###`-Hierarchie |
| „Delphi“-Artefakte | ✅ Entfernt |
| Assembler-Code ohne Codeblock | ✅ Entfernt (gehört in Bitfields-Dokument) |
| Keine Adress-/Socket-Typen | **WP 2** – `BDAddr`, `SockAddrBt` |
| RFCOMM fehlte komplett | **WP 3** – Client + Server |
| D‑Bus nur angerissen | **WP 5** – Socket-Öffnung, konkrete BlueZ-Methoden |
| GATT-Server fehlte | **WP 7** |
| Kein AI‑Natives Konzept | **WP 8** – GATT-Profile als Compiler-Typen |
| Kein Fahrplan / keine Abnahmekriterien | ✅ Jedes WP mit Info, Grund, Abnahmekriterien |
| Keine Risikotabelle | ✅ **Kapitel 5** |

---

*Stand: Mai 2026 – Überarbeitete Fassung, fokussiert auf Bluetooth-Kernthema*
