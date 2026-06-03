# Lyx Capability-Based Security (LCBS)

> **Version:** 3.0 · **Ab:** lyxc v0.9.0C · **Plattform:** Linux x86-64 (Kernel ≥ 5.13)

---

## 1. Überblick

LCBS ist das Sicherheitsmodell von Lyx. Es setzt das **Zero-Privilege-Prinzip** um:

> Ein kompiliertes Lyx-Programm besitzt standardmäßig **keinerlei Rechte**.
> Ressourcen werden ausschließlich durch explizite Deklarationen freigeschaltet.

Drei Durchsetzungsschichten arbeiten zusammen:

| Schicht | Zeitpunkt | Mechanismus |
|---------|-----------|-------------|
| Sprache | Compile-Zeit | `@capabilities`-Annotation, Grant-Validierung |
| FFI | Compile-Zeit | Signatur-Klassifizierung, Blacklist |
| Runtime | Prozessstart | seccomp-BPF + Landlock vor `main()` |

---

## 2. Schnellstart

### 2.1 Einfaches Programm ohne Capabilities

```lyx
// Keinerlei OS-Ressourcen deklariert.
// Implizit immer aktiv: system.exit, system.memory.heap
fn main(): int64 {
  PrintLn("Hello, secure world!");
  return 0;
}
```

Kein `@capabilities` → kein seccomp → kein Landlock. Läuft ohne Einschränkungen.

### 2.2 Programm mit Dateizugriff

```lyx
@capabilities([fs.read])
fn main(): int64 {
  // Darf Dateien lesen; Schreiben ist blockiert (Landlock + seccomp)
  return 0;
}
```

Kompilieren:
```bash
lyxc my_program.lyx -o my_program
```

Der Compiler installiert automatisch:
- seccomp: erlaubt `openat(O_RDONLY)` und `read`; blockiert `write` → SIGSYS
- Landlock: erlaubt Lesezugriff auf `/` (Verzeichnisbaum); blockiert Schreibzugriff

### 2.3 Netzwerk + Hardware

```lyx
@capabilities([
  network.tcp.connect,
  hardware.gpio(pin: 18)
])
fn main(): int64 {
  // Darf TCP-Verbindungen aufbauen und GPIO-Pin 18 steuern
  return 0;
}
```

---

## 3. Capability-Hierarchie

### 3.1 Implizite Capabilities (immer aktiv, nicht deklarierbar)

| Capability | Syscall | Begründung |
|-----------|---------|-----------|
| `system.exit` | `exit_group` | Jedes Programm muss sauber beenden können |
| `system.memory.heap` | `brk`, `mmap(MAP_ANON)`, `munmap` | `alloc`/`free` benötigen diese Syscalls |
| `system.memory.stack` | `mmap(MAP_STACK)` | Stack-Erweiterung bei tiefer Rekursion |

### 3.2 Explizite Capabilities

#### System

| Capability | Syscall | Beschreibung |
|-----------|---------|-------------|
| `system.time` | `clock_gettime` | Systemzeit lesen |
| `system.env` | *(Compile-Zeit-Filter)* | Umgebungsvariablen |
| `system.rand` | `getrandom` | Kryptographisch sichere Zufallszahlen |
| `system.unsafe.format_string` | *(none)* | Erlaubt Format-String-Funktionen (printf etc.) |

#### Dateisystem

| Capability | Syscall | Landlock |
|-----------|---------|---------|
| `fs.read` | `openat(O_RDONLY)`, `read` | READ_FILE, READ_DIR |
| `fs.write` | `openat(O_WRONLY)`, `write` | WRITE_FILE |
| `fs.create` | `openat(O_CREAT)` | MAKE_REG, MAKE_DIR |
| `fs.delete` | `unlinkat`, `rmdir` | REMOVE_FILE, REMOVE_DIR |
| `fs.meta` | `statx`, `getdents64` | READ_DIR |
| `fs.exec` | `execveat` | EXECUTE |

#### Memory

| Capability | Syscall | Beschreibung |
|-----------|---------|-------------|
| `memory.mmap` | `mmap(FILE\|SHARED)`, `mprotect` | Datei-Mappings |
| `memory.lock` | `mlock`, `mlockall` | Seiten im RAM halten |

#### Netzwerk

| Capability | Syscall | Beschreibung |
|-----------|---------|-------------|
| `network.tcp.bind` | `bind`, `listen`, `accept` | TCP-Server |
| `network.tcp.connect` | `socket`, `connect` | TCP-Client |
| `network.udp.bind` | `bind`, `recvfrom` | UDP-Empfangen |
| `network.udp.connect` | `sendto`, `connect` | UDP-Senden |
| `network.unix` | `socket(AF_UNIX)` | Unix Domain Sockets |
| `network.raw` | `socket(AF_PACKET)` | Raw Sockets (braucht CAP_NET_RAW) |

#### Hardware

| Capability | Argument | Landlock-Pfad | Beschreibung |
|-----------|---------|--------------|-------------|
| `hardware.gpio` | `pin: N` | `/dev/gpiochip0` (Pins 0-31) oder `/dev/gpiochip1` (32-53) | GPIO-Pin |
| `hardware.i2c` | `bus: N` | `/dev/i2c-N` | I2C-Bus |
| `hardware.spi` | `bus: N, cs: M` | `/dev/spidevN.M` | SPI-Bus |
| `hardware.usb` | *(keine)* | `/dev/bus/usb` | USB-Gerät |

#### Prozess

| Capability | Syscall | Beschreibung |
|-----------|---------|-------------|
| `process.fork` | `clone`, `fork` | Kindprozesse erzeugen |
| `process.exec` | `execve`, `execveat` | Programme ausführen |
| `process.signal` | `kill`, `tgkill` | Signale senden |
| `process.sched` | `sched_setattr`, `nice` | Prozess-Priorität |
| `process.exit` | `exit`, `exit_group` | *(redundant zu system.exit)* |

---

## 4. Capability-Argumente

Viele Capabilities akzeptieren Parameter zur Feinsteuerung:

```lyx
@capabilities([
  hardware.gpio(pin: 18, direction: output, initial: low),
  hardware.gpio(pin: 23, direction: input, pull: up),
  hardware.i2c(bus: 1, address: 0x48),
  hardware.spi(bus: 0, cs: 0, speed: 1000000),
  hardware.usb
])
```

### Netzwerk-Adressierung

Netzwerk-Capabilities können Zieladresse und Port einschränken:

```lyx
@capabilities([
  network.tcp.connect(addr: "192.168.1.0/24", port: 8080),
  network.udp.connect(addr: "*", port: 5000)
])
```

> **Hinweis:** Die IP/Port-Filterung erfordert den Userspace-Proxy (automatisch aktiv).

### @fastpath — Proxy-Bypass

Für latenzempfindliche Anwendungen kann der Proxy umgangen werden:

```lyx
@capabilities([
  network.udp.connect @fastpath
])
fn highFreqPublisher(): void {
  // Direkter UDP-Syscall, kein Proxy-Overhead
  // Kein IP/Port-Filter auf LCBS-Ebene
  // Security-Score: -3
}
```

---

## 5. Grant-basiertes Vererbungsmodell

### 5.1 Das Prinzip

Module erben Capabilities **nicht automatisch**. Stattdessen erhält ein importiertes Modul:

```
C(Modul) = C(Modul_deklariert) ∩ C(Eltermodul)
```

Ohne explizites `grant`: das Modul bekommt nur, was es selbst deklariert hat **und** der Importierende besitzt.

Mit `grant`: exakte Vergabe durch den Importierenden.

```lyx
import
  std.hardware.gpio  grant [hardware.gpio(pin: 18)],
  std.net.tcp        grant [network.tcp.connect],
  ThirdParty.Logger  restrict [fs.write];
```

### 5.2 Vererbungsregeln

| Situation | Regel | Effekt |
|-----------|-------|--------|
| Import ohne grant/restrict | `C(M) = C(M_decl) ∩ C(Parent)` | Deklariertes Minimum, gekappt auf Parent |
| Import mit grant | `C(M) = grant_set ∩ C(Parent)` | Exakte Vergabe |
| Import mit restrict | `C(M) = C(M_decl) ∩ C(Parent) ∩ restrict_set` | Zusätzliche Einschränkung |

**Invariante:** `C(M) ⊆ C(Parent)` — kein Modul kann mehr Rechte haben als sein Importierender.

### 5.3 Fehlende Grants

Fehlt ein `grant`, gibt der Compiler eine Warnung:

```
warning: Import ohne explizites grant — Security-Score -2
```

Das Programm kompiliert trotzdem, aber der Security-Score wird reduziert.

---

## 6. `@uses_caller_cap` — Capability-Leihe

Wenn eine Bibliotheksfunktion Capabilities des **Aufrufers** benötigt (nicht eigene):

```lyx
// Im Bibliotheks-Modul flexible_logger:
@uses_caller_cap([fs.write])
fn logToFile(path: pchar, msg: pchar): void {
  // Benutzt fs.write — aber das Modul selbst hat fs.write nicht.
  // Der AUFRUFER muss fs.write besitzen.
}
```

**Semantik:**
- Der Compiler prüft an jedem Aufruf-Site, ob der Aufrufer die geliehene Capability hat.
- Aufruf ohne entsprechende Capability → Compile-Fehler.
- Das Modul selbst hat `C(flexible_logger) = ∅`.

**Beispiel — korrekter Aufruf:**
```lyx
@capabilities([fs.write])
fn saveLog(): void {
  logToFile("/var/log/app.log"c, "started"c);  // OK: Aufrufer hat fs.write
}
```

**Beispiel — Fehler:**
```lyx
@capabilities([fs.read])
fn readAndLog(): void {
  logToFile("/var/log/app.log"c, "started"c);  // FEHLER: Aufrufer hat nur fs.read
}
```

---

## 7. Runtime-Mechanismen

### 7.1 Startup-Sequenz

```
_start / main():
  1. Falls Netzwerk-Capabilities mit Proxy: fork() → Proxy-Prozess
  2. Landlock-Regeln installieren  ← muss VOR seccomp sein
  3. seccomp-BPF installieren
  4. Benutzerprogramm main() ausführen
```

### 7.2 seccomp-BPF

- Standardaktion: `SECCOMP_RET_KILL_PROCESS` (tötet sofort die gesamte Prozessgruppe)
- Erlaubte Syscalls: exakt die deklarierten + implizite Capabilities
- Kein SIGSYS-Handler möglich (KILL_PROCESS umgeht Signal-Handler)

### 7.3 Landlock (Linux ≥ 5.13)

Landlock filtert Pfadzugriffe im Kernel:
- Für `fs.read`: `/`-Regel mit `READ_FILE|READ_DIR`
- Für `fs.write`: `/`-Regel mit `WRITE_FILE`
- Für Hardware: spezifische Device-Pfade (z. B. `/dev/gpiochip0`, `/dev/i2c-1`)
- Fallback bei Kernel < 5.13: Warnung, nur seccomp aktiv

Landlock muss **vor** seccomp installiert werden, da die Landlock-Syscalls (444/445/446) sonst blockiert würden.

### 7.4 Userspace-Proxy (Netzwerk)

Für IP/Port-Filterung (seccomp kann keine Adressen prüfen) startet der Compiler bei Netzwerk-Capabilities einen Proxy-Prozess:

```
+---[Hauptprogramm]---+       +---[Proxy]---+
| fork+socketpair     |       | Eigener     |
| Proxy-Fd gespeichert|<=====>| seccomp     |
| Sendet Anfragen     |       | IP/Port-    |
|                     |       | Whitelist   |
+---------------------+       +-------------+
```

Der Proxy:
- Installiert eigenen restriktiven seccomp (nur Netzwerk-Syscalls)
- Validiert Verbindungsanfragen gegen die deklarierten Adressen/Ports
- Beendet sich automatisch, wenn das Hauptprogramm endet (EOF auf socketpair)

---

## 8. Klassen-Capabilities

Capabilities können auf Klassen-Ebene deklariert werden:

```lyx
@capabilities([fs.write(path: "/var/log")])
class FileWriter {
  // Alle Instanzmethoden haben implizit fs.write(path: "/var/log")

  fn writeLog(msg: pchar): void {
    // Abgedeckt durch Klassen-Deklaration
  }

  @capabilities([network.tcp.connect])
  fn writeRemote(msg: pchar): void {
    // Vereinigung: fs.write + network.tcp.connect
  }

  static fn formatTimestamp(ts: int64): pchar {
    // Statische Methode: keine Instanz-Capabilities
  }
}
```

**Regel:** Instanzmethoden können Klassen-Capabilities **nicht einschränken**, nur erweitern.

---

## 9. FFI-Klassifizierung

Externe Funktionen werden automatisch klassifiziert:

| Klasse | Beschreibung | Beispiele |
|--------|-------------|---------|
| **0: Safe** | Reine Berechnung | `memcpy`, `strlen`, `sin`, `snprintf` |
| **1: OS Resource** | Betriebsmittelzugriff | `open`, `read`, `socket` |
| **2: Process** | Prozesssteuerung | `fork`, `kill` |
| **3: Verboten** | Systemisch unsicher | `gets`, `system`, `sprintf`, `strcpy` |

Klasse 3 wird abgelehnt, außer bei expliziter `@cap`-Annotation:

```lyx
@cap(fs.write)
extern fn fwrite(ptr: int64, size: int64, n: int64, f: int64): int64 link "libc.so.6";
```

**Blacklist (Klasse 3, immer blockiert):**
- `gets`, `system`, `popen`, `sprintf`, `vsprintf`
- `strcpy`, `strcat`, `wcscpy`, `wcscat`
- `execve`, `execvp` (als direktes FFI — nur via `process.exec` erlaubt)

---

## 10. CLI-Werkzeuge

### 10.1 `--migrate-capabilities`

Analysiert ein Lyx-Programm ohne `@capabilities` und generiert ein minimales Manifest:

```bash
lyxc --migrate-capabilities my_program.lyx
```

**Ausgabe:**
```
@capabilities([
  fs.read(path: "/etc/config"),
  network.tcp.connect  // Adresse und Port manuell ergaenzen
])
```

**Erkannte Funktionen:** `fopen`, `open`, `read`, `write`, `socket`, `connect`, `fork`, `getenv`, `ioctl` und viele mehr.

**Dynamische Pfade** (nicht statisch analysierbar) erzeugen eine Warnung:
```
Warnung: Dynamisch konstruierte Pfade erkannt -- manuell ergaenzen
```

### 10.2 `--capabilities=compat`

Kompiliert ein LCBS-Programm **ohne** seccomp/Landlock-Installation. Nützlich für die schrittweise Migration:

```bash
lyxc --capabilities=compat my_program.lyx -o my_program
```

- `@capabilities` wird akzeptiert und validiert
- Kein seccomp/Landlock zur Laufzeit
- Der Security-Audit zeigt die fehlenden Mechanismen
- Security-Score reduziert

### 10.3 `--self-test`

Führt den LCBS-Integrationstest aus:

```bash
lyxc --self-test
```

Der Selbsttest:
1. Kompiliert Test-Programme mit verschiedenen LCBS-Capabilities
2. Prüft BPF-Filter auf korrekte Syscall-Listen
3. Führt die kompilierten Programme aus
4. Meldet Ergebnis: `LCBS SELF-TEST: PASSED` oder `FAILED`

### 10.4 Security-Audit

Jeder Build gibt automatisch einen Audit-Report auf stderr aus:

```
=== LCBS Security Audit ==========================================
Programm:          my_program.lyx
Capability-Modell: Zero-Privilege (default deny), Grant-basiert

Implizite Capabilities (immer aktiv):
  o system.exit         -> exit_group
  o system.memory.heap  -> brk, mmap(MAP_ANON)

Explizite Capabilities:
  + fs.read
  + hardware.gpio

Runtime-Schutz:
  + W^X / + RELRO / o PIE (statisch) / + seccomp / + landlock

Sicherheits-Score: 40/40
  +10: kein Klasse-3-Extern
  + 5: W^X, + 5: RELRO, + 0: PIE
  +10: alle Imports mit grant
  + 5: seccomp, + 5: landlock
  o: Stack Canaries (WP-18 offen)
==================================================================
```

---

## 11. Security-Score

Der Score misst die Qualität des Sicherheitsmodells (aktuell max. 40):

| Kriterium | Punkte | Bedingung |
|-----------|--------|----------|
| Kein Klasse-3-Extern | +10 | Build ohne FFI-Blacklist-Treffer |
| W^X | +5 | Immer aktiv (generiertes ELF) |
| RELRO | +5 | Immer aktiv (kein GOT im statischen ELF) |
| PIE | +0 | Nicht implementiert (geplant) |
| Grant-Vollständigkeit | +10 | Alle Imports mit explizitem `grant` (-2 pro fehlendem) |
| seccomp | +5 | Bei aktivem LCBS |
| landlock | +5 | Bei aktivem LCBS |
| Stack Canaries | +5 Bonus | WP-18 (geplant) |
| `@fastpath` | -3 | Pro Nutzung |

---

## 12. Beispiele

### 12.1 Robot Controller

```lyx
@capabilities([
  hardware.gpio(pin: 18, direction: output, initial: low),
  hardware.gpio(pin: 23, direction: input, pull: up),
  network.udp.connect(addr: "192.168.1.0/24", port: 5000),
  fs.read(path: "/etc/robot.conf")
])
fn main(): int64 {
  // GPIO, UDP, Config-Datei: alles deklariert, nichts anderes erlaubt
  return 0;
}
```

### 12.2 Modular mit Grant

```lyx
// In robot_controller.lyx
import
  std.hardware.gpio  grant [hardware.gpio(pin: 18)],
  std.net.udp        grant [network.udp.connect],
  std.config         grant [fs.read(path: "/etc/robot.conf")];

@capabilities([
  hardware.gpio(pin: 18),
  network.udp.connect,
  fs.read(path: "/etc/robot.conf")
])
fn main(): int64 {
  return 0;
}
```

### 12.3 Logging-Bibliothek mit Capability-Leihe

```lyx
// In logging.lyx — benötigt keine eigenen Capabilities
@uses_caller_cap([fs.write])
fn logEvent(event: pchar): void {
  // Der Aufrufer stellt fs.write bereit
}
```

```lyx
// In app.lyx
@capabilities([fs.write(path: "/var/log")])
fn main(): int64 {
  logEvent("app started"c);  // OK: Aufrufer hat fs.write
  return 0;
}
```

---

## 13. Fehlerbehebung

### Programm stirbt mit SIGSYS

Ein Syscall wurde von seccomp blockiert. Ursachen:
- Fehlende Capability deklariert (z. B. `fork` ohne `process.fork`)
- Implizite Capability fehlt (sollte nicht passieren — system.exit/heap sind immer aktiv)
- Externe Bibliothek ruft undokumentierten Syscall auf

**Lösung:** `strace ./mein_programm 2>&1 | grep -i "SIGSYS\|killed"`

### EACCES beim Dateizugriff

Landlock blockiert den Pfad. Ursachen:
- `fs.write` deklariert, aber O_RDONLY-Zugriff auf falschen Pfad
- Hardware-Gerät nicht deklariert (z. B. `/dev/i2c-0` ohne `hardware.i2c(bus: 0)`)

**Lösung:** Capability-Argument prüfen und ggf. Pfad-Argument hinzufügen.

### Migration: Programm ohne `@capabilities`

1. Analyse starten:
   ```bash
   lyxc --migrate-capabilities my_program.lyx
   ```

2. Erzeugtes Manifest einfügen und überprüfen:
   ```bash
   lyxc --capabilities=compat my_program.lyx -o my_program  # erst testen
   lyxc my_program.lyx -o my_program                        # dann aktivieren
   ```

3. Security-Audit lesen und Score verbessern (fehlende `grant`-Klauseln ergänzen).

### Kernel < 5.13 (kein Landlock)

Der Compiler gibt eine Warnung und kompiliert nur mit seccomp. Pfad-basierte Einschränkungen sind dann nicht aktiv.

---

## 14. Referenz: Capability-IDs

| ID | Name | Domain |
|----|------|--------|
| 0 | system.exit | Implizit |
| 1 | system.memory.heap | Implizit |
| 2 | system.memory.stack | Implizit |
| 3 | system.time | System |
| 4 | system.env | System |
| 5 | system.rand | System |
| 6 | system.unsafe.format_string | System |
| 7 | fs.read | Dateisystem |
| 8 | fs.write | Dateisystem |
| 9 | fs.create | Dateisystem |
| 10 | fs.delete | Dateisystem |
| 11 | fs.meta | Dateisystem |
| 12 | fs.exec | Dateisystem |
| 13 | memory.mmap | Memory |
| 14 | memory.lock | Memory |
| 15 | network.tcp.bind | Netzwerk |
| 16 | network.tcp.connect | Netzwerk |
| 17 | network.udp.bind | Netzwerk |
| 18 | network.udp.connect | Netzwerk |
| 19 | network.unix | Netzwerk |
| 20 | network.raw | Netzwerk |
| 21 | hardware.gpio | Hardware |
| 22 | hardware.i2c | Hardware |
| 23 | hardware.spi | Hardware |
| 24 | hardware.usb | Hardware |
| 25 | process.fork | Prozess |
| 26 | process.exec | Prozess |
| 27 | process.signal | Prozess |
| 28 | process.sched | Prozess |
| 29 | process.exit | Prozess |

---

## 15. Arbeitspakete und Implementierungsstatus

| WP | Titel | Status |
|----|-------|--------|
| WP-L1 | EBNF-Erweiterung + Parser | ✓ Implementiert |
| WP-L2 | Capability-Hierarchie + implizite Caps | ✓ Implementiert |
| WP-L3 | Grant-basiertes Vererbungsmodell | ✓ Implementiert |
| WP-L4 | Transitiver Capability-Graph | ✓ Implementiert |
| WP-L5 | FFI-Klassifizierung + Signatur-Validierung | ✓ Implementiert |
| WP-L6 | Compile-Time Stripping | ✓ Implementiert |
| WP-L7 | `@uses_caller_cap` (Capability-Leihe) | ✓ Implementiert |
| WP-L8 | Klassen-Capability-Modell | ✓ Implementiert |
| WP-R9 | seccomp-BPF-Codegenerierung | ✓ Implementiert |
| WP-R10 | Landlock-Integration | ✓ Implementiert |
| WP-R11 | Userspace-Netzwerk-Proxy + Lifecycle | ✓ Implementiert |
| WP-H12 | Hardware-Capabilities + Device Tree | ✓ Implementiert |
| WP-T13 | Security Audit Output + Score | ✓ Implementiert |
| WP-T14 | Migration Tool (`--migrate-capabilities`) | ✓ Implementiert |
| WP-T15 | LCBS-Selbsttest (`--self-test`) | ✓ Implementiert |

---

*Lyx LCBS v3.0 — Stand: Juni 2026*
