# Lyx Capability-Based Security (LCBS)

> **Version:** 3.0 · **Ab:** lyxc v0.9.9B · **Plattform:** Linux x86-64 (Kernel ≥ 5.13)

---

## 1. Überblick

LCBS ist das Sicherheitsmodell von Lyx. Es setzt das **Zero-Privilege-Prinzip** um:

> Ein Lyx-Programm besitzt standardmäßig **keinerlei Rechte**.
> Alle Ressourcenzugriffe müssen im Quellcode explizit deklariert werden.

Der Compiler erzwingt diese Deklarationen auf zwei Ebenen:

| Ebene | Zeitpunkt | Was wird geprüft |
|-------|-----------|-----------------|
| Sprache | Compile-Zeit | `@capabilities`-Annotation, Grant-Validierung, `@uses_caller_cap`-Aufrufstellen |
| Runtime | Prozessstart | Kernel-seitige Durchsetzung vor `main()` |

Ein Programm ohne `@capabilities`-Annotation läuft ohne jede Einschränkung und bekommt einen niedrigen Security-Score.

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

### 2.2 Programm mit Dateizugriff

```lyx
@capabilities([fs.read])
fn main(): int64 {
  // Darf Dateien lesen; Schreiben ist vollständig blockiert
  return 0;
}
```

```bash
lyxc my_program.lyx -o my_program
```

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

Diese Capabilities sind in jedem Lyx-Programm automatisch aktiv:

| Capability | Beschreibung |
|-----------|-------------|
| `system.exit` | Sauberes Beenden des Prozesses |
| `system.memory.heap` | Heap-Allokation (`alloc` / `free`) |
| `system.memory.stack` | Stack-Erweiterung bei tiefer Rekursion |

### 3.2 Explizite Capabilities

#### System

| Capability | Beschreibung |
|-----------|-------------|
| `system.time` | Systemzeit lesen **und warten** (`clock_gettime`, `nanosleep`, `clock_nanosleep`) |
| `system.tty` | Terminal einstellen — `ioctl` nur mit `TCGETS`/`TCSETS`/`TCSETSW`/`TCSETSF`/`TIOCGWINSZ`/`TIOCSWINSZ` |
| `system.env` | Umgebungsvariablen lesen (Compile-Zeit-Filter) |
| `system.rand` | Kryptographisch sichere Zufallszahlen |
| `system.unsafe.format_string` | Format-String-Funktionen (printf etc.) |

#### Dateisystem

| Capability | Beschreibung |
|-----------|-------------|
| `fs.read` | Dateien und Verzeichnisse lesen |
| `fs.write` | In Dateien schreiben |
| `fs.create` | Neue Dateien und Verzeichnisse anlegen |
| `fs.delete` | Dateien und Verzeichnisse löschen |
| `fs.meta` | Metadaten lesen (stat, Verzeichnislisting) |
| `fs.perm` | Zugriffsrechte und Eigentümer ändern (chmod, chown) |

Welche Syscalls die einzelne Capability freigibt, steht im seccomp-Generator
(`src/security/seccomp_gen.lyx`) und ist durch `tests/seccomp_filter_test.sh`
festgehalten — je Fall wird geprueft, dass der erlaubte Aufruf laeuft **und**
der nicht gewaehrte weiterhin mit `SIGSYS` stirbt.

Zwei Festlegungen, die sich nicht aus der Tabelle ergeben:

* **`rename` verlangt `fs.create` UND `fs.delete`.** Umbenennen legt am Ziel an
  und entfernt an der Quelle; mit nur einer der beiden waere es ein Weg, ohne
  `fs.delete` zu loeschen.
* **Optionen der eigenen Verbindung gehören zur Netzwerk-Capability.**
  `setsockopt`, `getsockopt`, `getsockname` und `getpeername` sind mit jeder
  `network.*`-Capability erlaubt: wer eine Verbindung aufbauen darf, darf ihre
  Puffergrößen und Zeitgrenzen einstellen und wissen, mit wem er spricht. Ohne
  `setsockopt` stirbt jeder TLS-Handshake, weil OpenSSL `TCP_ULP` setzt
  (#1193).
* **Metadaten lesen und schreiben sind getrennt.** `chmod` und `chown` hängen
  an `fs.perm`, nicht an `fs.meta` — wer nur ein Verzeichnis auflisten will,
  soll nicht stillschweigend Rechte umschreiben dürfen (#1188).

Immer erlaubt, ohne Capability: `exit_group`, `exit`, `brk`, `mmap(anon)`,
`munmap`, `write`, `prctl`, `prlimit64`, `futex`, Signal-Rueckkehr,
`getrandom` (Stack-Canary) sowie ein Basissatz harmloser Introspektion —
`getpid`, `gettid`, `getppid`, `getuid`, `geteuid`, `getgid`, `getegid`. Diese
geben Auskunft ueber den eigenen Prozess und beruehren nichts ausserhalb davon;
ohne sie ist eine extern gelinkte Bibliothek nicht benutzbar (OpenSSL ruft
`getpid` beim Init). `clock_gettime` gehoert bewusst NICHT dazu — dafuer gibt
es `system.time`, das seit #1866 auch `nanosleep` und `clock_nanosleep`
abdeckt: wer die Uhr lesen darf, darf auch warten, und ohne das Recht laesst
sich ueber `nanosleep` auch keine Zeit messen.
| `fs.exec` | Ausführbare Dateien starten |

#### Ein- und Ausgabe

| Capability | Beschreibung |
|-----------|-------------|
| `io.wait` | Auf Deskriptoren warten: `poll`, `ppoll`, `select`, `epoll_*`, `eventfd2`, `signalfd4`, `timerfd_*` |
| `io.fd` | Deskriptoren erzeugen und verdoppeln: `pipe`, `pipe2`, `dup`, `dup2`, `dup3` |

`io.wait` macht kein neues Objekt erreichbar — gewartet wird auf das, was das
Programm ohnehin schon hat. `eventfd`, `signalfd` und `timerfd` erzeugen
allerdings Deskriptoren, weshalb die Zusage ausdrücklich bleibt und nicht in
den impliziten Basissatz wandert.

`fcntl` gehört **nicht** zu `io.fd`: es ist seit #1276 unter `fs.read` und
`fs.write` mit Argumentfilter freigegeben (`F_GETFD`, `F_SETFD`, `F_GETFL`,
`F_SETFL` und die Sperren).

#### Memory

| Capability | Beschreibung |
|-----------|-------------|
| `memory.mmap` | Datei-Mappings und gemeinsamer Speicher |
| `memory.lock` | Seiten fest im RAM halten |

#### Netzwerk

| Capability | Beschreibung |
|-----------|-------------|
| `network.tcp.bind` | TCP-Server (bind, listen, accept) |
| `network.tcp.connect` | TCP-Client (connect) |
| `network.udp.bind` | UDP-Empfangen |
| `network.udp.connect` | UDP-Senden |
| `network.unix` | Unix Domain Sockets |
| `network.raw` | Raw Sockets (erfordert `CAP_NET_RAW` des OS-Prozesses) |

#### Hardware

| Capability | Argument | Gerät | Beschreibung |
|-----------|---------|-------|-------------|
| `hardware.gpio` | `pin: N` | `/dev/gpiochipX` | GPIO-Pin |
| `hardware.i2c` | `bus: N` | `/dev/i2c-N` | I2C-Bus |
| `hardware.spi` | `bus: N, cs: M` | `/dev/spidevN.M` | SPI-Bus |
| `hardware.usb` | *(keine)* | `/dev/bus/usb` | USB-Gerät |
| `hardware.block` | *(keine)* | *(nur LyxOS)* | Rohzugriff auf Blockgeräte |

##### Was davon im LBF-Ziel ankommt (#1755)

`--target=lyxos` schreibt die Capabilities als Bitmaske in die CAPS-TLV des
Programms; der Kernel wertet sie beim Syscall aus. **Abgebildet sind nur diese:**

| Capability | Bit |
|---|---|
| `fs.read` | `0x1` |
| `fs.write` | `0x2` |
| `network.*` | `0x4` |
| `process.*` | `0x8` |
| `ki.embed` | `0x10` |
| `ki.graph` | `0x20` |
| `hardware.block` | `0x40` |
| `audio.*` | `0x80` (reserviert — es gibt derzeit keine `audio`-Capability) |
| `hardware.i2c`, `hardware.usb`, `hardware.gpio`, `hardware.spi` | `0x100` |

`hardware.i2c`, `hardware.usb`, `hardware.gpio` und `hardware.spi` teilen sich
`0x100` (#1759). Das ist Absicht: LyxOS kennt für den direkten Gerätezugriff
genau eine Klasse (`PLEDGE_DEVICE`), und feiner getrennte Bits wären eine
Zusage, die niemand durchsetzen könnte. Aufteilen lässt sich das später, ohne
die bestehenden Bedeutungen zu verschieben. `hardware.block` bleibt davon
getrennt — Blockgeräte sind im Kernel eine eigene Klasse (`PLEDGE_BLOCK`).

Capabilities, die **kein Bit setzen** — etwa `fs.create`, `fs.meta`,
`memory.mmap` —, sind für das Ziel gültig, aber wirkungslos; der Compiler warnt
beim Übersetzen darauf. `system.*` sind die impliziten Rechte (Programmende,
Heap, Zufall, Zeit); sie brauchen kein Bit und werden nicht gemeldet.

Ein Programm, dessen sämtliche Capabilities kein Bit setzen, kommt beim
Ladeprogramm an wie eines ohne Manifest und bekommt den Vorgabewert „nur
Standardausgabe".

#### Prozess

| Capability | Beschreibung |
|-----------|-------------|
| `process.fork` | Kindprozesse erzeugen |
| `process.exec` | Andere Programme ausführen |
| `process.signal` | Signale an andere Prozesse senden |
| `process.sched` | Prozess-Priorität ändern |

---

## 4. Capability-Argumente

Viele Capabilities akzeptieren Parameter zur Feinsteuerung des Zugriffs. Je präziser die Deklaration, desto höher der Security-Score.

```lyx
@capabilities([
  hardware.gpio(pin: 18, direction: output, initial: low),
  hardware.gpio(pin: 23, direction: input, pull: up),
  hardware.i2c(bus: 1, address: 0x48),
  hardware.spi(bus: 0, cs: 0, speed: 1000000),
  hardware.usb,
  fs.read(path: "/etc/config"),
  fs.write(path: "/var/log")
])
```

### Netzwerk-Adressfilter

Netzwerk-Capabilities können auf bestimmte Zieladressen und Ports eingeschränkt werden:

```lyx
@capabilities([
  network.tcp.connect(addr: "192.168.1.0/24", port: 8080),
  network.udp.connect(addr: "*", port: 5000)
])
```

Verbindungsversuche zu nicht deklarierten Adressen oder Ports werden zur Laufzeit abgelehnt.

### @fastpath — Proxy-Bypass für latenzempfindliche Pfade

```lyx
@capabilities([
  network.udp.connect @fastpath
])
fn highFreqPublisher(): void {
  // Direkter UDP-Syscall ohne Adress-/Port-Prüfung.
  // Security-Score: -3 pro Nutzung
}
```

`@fastpath` deaktiviert den Adressfilter für diese Capability. Nur verwenden, wenn Latenz kritisch ist und die Zieladressen anderweitig kontrolliert werden.

---

## 5. Grant-basiertes Vererbungsmodell

### 5.1 Das Prinzip

Module erben Capabilities **nicht automatisch**. Ein importiertes Modul erhält:

```
C(Modul) = C(Modul_deklariert) ∩ C(Eltermodul)
```

Mit explizitem `grant` vergibt der Importierende genau die erlaubten Capabilities:

```lyx
import
  std.hardware.gpio  grant [hardware.gpio(pin: 18)],
  std.net.tcp        grant [network.tcp.connect],
  ThirdParty.Logger  restrict [fs.write];
```

### 5.2 Vererbungsregeln

| Situation | Regel | Effekt |
|-----------|-------|--------|
| Import ohne `grant`/`restrict` | `C(M) = C(M_decl) ∩ C(Parent)` | Deklariertes Minimum, gekappt auf Parent |
| Import mit `grant` | `C(M) = grant_set ∩ C(Parent)` | Exakte Vergabe |
| Import mit `restrict` | `C(M) = C(M_decl) ∩ C(Parent) ∩ restrict_set` | Zusätzliche Einschränkung |

**Invariante:** `C(M) ⊆ C(Parent)` — kein Modul kann mehr Rechte haben als sein Importierender.

### 5.3 Fehlende Grants

Ein Import ohne explizites `grant` erzeugt eine Compiler-Warnung:

```
warning: Import ohne explizites grant — mit `grant` wird die Deklaration des Moduls geprüft (#1340)
```

Das Programm kompiliert trotzdem. Die +10 des Score gibt es aber nur, wenn
**jeder** Import ein `grant` trägt — der Posten ist ganz oder gar nicht, nicht
anteilig.

### 5.4 Transitivität: das Grant gilt für die ganze Hülle

Ein `grant` bindet den Import **und alles, was dieser Import seinerseits
importiert**. Die Deklaration einer Unit nennt deshalb nicht nur ihren eigenen
Bedarf, sondern die transitive Hülle über ihre `import std.*`-Kanten:

```
std.cloud.gcp.compute → std.cloud.gcp.transport → std.cloud.gcp.credentials → std.fs
```

`std.cloud.gcp.compute` deklariert damit `fs.read`, obwohl in seiner eigenen
Quelle kein Dateizugriff steht — über drei Kanten kann einer stattfinden. Die
Alternative wäre gewesen, nur den eigenen Bedarf zu deklarieren; dann wäre die
Eindämmung bei der ersten Weiterreichung zu Ende, und `grant [network.tcp.connect]`
auf `std.cloud.gcp.compute` hätte eine Zusicherung ausgewiesen, die der Code
nicht hält (#1340, Punkt 4).

Der Preis ist Weite: wer über vier Ecken `std.fs` erreicht, führt dessen
Rechte. Wer enger will, importiert enger — die Hülle ist eine Aussage über den
Import-Graphen, nicht über den Stil der Unit.

Die Deklarationen in `std/` sind **gemessen, nicht geschätzt**: abgeleitet aus
den OS-Builtins, die eine Unit aufruft, dann transitiv fortgeschrieben. Zwei
Feinheiten, die eine grobe Ableitung falsch macht:

- `read`/`write`/`lseek` sagen nichts über das Dateisystem — auf einem
  Socket-Deskriptor sind sie Netzverkehr, auf stdout Ausgabe. Sie zählen nur
  als `fs.*`, wenn die Unit selbst einen Datei-Deskriptor öffnet.
- `memory.mmap` meint die datei- oder speichergestützte *geteilte* Abbildung.
  Die anonyme Heap-Abbildung fällt unter `system.memory.heap`; wer die
  Deklaration der Konstante `MMAP_SHARED` schon als Nutzung zählt, vererbt
  `memory.mmap` über `std.alloc` an praktisch jede Unit.

---

## 6. `@uses_caller_cap` — Capability-Leihe

Bibliotheksfunktionen, die Capabilities des **Aufrufers** benötigen (statt eigener), werden mit `@uses_caller_cap` annotiert:

```lyx
// In logging.lyx — das Modul selbst hat keine eigenen Capabilities
@uses_caller_cap([fs.write])
fn logEvent(event: pchar): void {
  // Benutzt fs.write des Aufrufers
}
```

Der Compiler prüft an jedem Aufruf-Site, ob der Aufrufer die geliehene Capability besitzt:

```lyx
// Korrekter Aufruf:
@capabilities([fs.write(path: "/var/log")])
fn main(): int64 {
  logEvent("app started"c);  // OK: Aufrufer hat fs.write
  return 0;
}
```

```lyx
// Fehler:
@capabilities([fs.read])
fn readAndLog(): void {
  logEvent("started"c);  // FEHLER: Aufrufer hat nur fs.read, nicht fs.write
}
```

Das Modul `logging.lyx` selbst hat `C(logging) = ∅` — es besitzt keine eigenen Capabilities, nutzt aber die des Aufrufers.

---

## 7. Klassen-Capabilities

Capabilities können auf Klassen-Ebene deklariert werden und gelten dann für alle Instanzmethoden:

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

## 8. Externe Funktionen (FFI)

Externe C-Funktionen werden automatisch in Sicherheitsklassen eingeteilt:

| Klasse | Beschreibung | Beispiele |
|--------|-------------|---------|
| **0: Safe** | Reine Berechnung | `memcpy`, `strlen`, `sin`, `snprintf` |
| **1: OS Resource** | Betriebsmittelzugriff | `open`, `read`, `socket` |
| **2: Process** | Prozesssteuerung | `fork`, `kill` |
| **3: Verboten** | Systemisch unsicher | `gets`, `system`, `sprintf`, `strcpy` |

Klasse-3-Funktionen lehnt der Compiler ab. Mit `@cap`-Annotation kann eine externe Funktion explizit einer Capability zugeordnet werden:

```lyx
@cap(fs.write)
extern fn fwrite(ptr: int64, size: int64, n: int64, f: int64): int64 link "libc.so.6";
```

**Immer blockiert (Klasse 3, keine Ausnahme):**
- `gets`, `system`, `popen`
- `sprintf`, `vsprintf`
- `strcpy`, `strcat`, `wcscpy`, `wcscat`
- `execve`, `execvp` (als direktes FFI — nur via `process.exec` erlaubt)

---

## 9. CLI-Werkzeuge

### 9.1 `--migrate-capabilities`

Analysiert ein bestehendes Lyx-Programm ohne `@capabilities` und generiert ein minimales Manifest als Ausgangspunkt:

```bash
lyxc --migrate-capabilities my_program.lyx
```

**Beispielausgabe:**
```
@capabilities([
  fs.read(path: "/etc/config"),
  network.tcp.connect  // Adresse und Port manuell ergaenzen
])
```

Bei dynamisch konstruierten Pfaden erscheint:
```
Warnung: Dynamisch konstruierte Pfade erkannt -- manuell ergaenzen
```

Das erzeugte Manifest ist ein Startpunkt — Pfad-Argumente und Netzwerk-Adressen müssen manuell verfeinert werden.

### 9.2 `--capabilities=compat`

Kompiliert ein LCBS-Programm ohne Kernel-Durchsetzung zur Laufzeit. Nützlich für schrittweise Migration:

```bash
lyxc --capabilities=compat my_program.lyx -o my_program
```

- `@capabilities` wird akzeptiert und syntaktisch validiert
- Keine Kernel-seitige Durchsetzung zur Laufzeit
- Security-Score wird reduziert
- Der Security-Audit zeigt fehlende Schutzmechanismen

### 9.3 `--self-test`

Führt den LCBS-Integrationstest aus:

```bash
lyxc --self-test
```

Ergebnis: `LCBS SELF-TEST: PASSED` oder `FAILED`.

### 9.4 Security-Audit

Jeder Build gibt automatisch einen Audit-Report auf stderr aus:

```
=== LCBS Security Audit ==========================================
Programm:          my_program.lyx
Capability-Modell: Zero-Privilege (default deny), Grant-basiert

Implizite Capabilities (immer aktiv):
  o system.exit
  o system.memory.heap

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
==================================================================
```

---

## 10. Security-Score

Der Score bewertet die Qualität des Sicherheitsmodells (aktuell max. 40, mit optionalem Bonus):

| Kriterium | Punkte | Bedingung |
|-----------|--------|----------|
| Kein Klasse-3-Extern | +10 | Build ohne FFI-Blacklist-Treffer |
| W^X | +5 | Immer aktiv im generierten ELF |
| RELRO | +5 | Immer aktiv (kein GOT im statischen ELF) |
| PIE | +0 | Nicht implementiert (geplant) |
| Grant-Vollständigkeit | +10 | Nur wenn ALLE Imports ein `grant` tragen — sonst 0 (#1340) |
| seccomp | +5 | Bei aktivem LCBS (nicht `--capabilities=compat`) |
| landlock | +5 | Bei aktivem LCBS (Kernel ≥ 5.13) |
| Stack Canaries | +5 Bonus | Geplant |
| `@fastpath` | –3 | Pro Nutzung |

---

## 11. Capability-Referenz (IDs)

| ID | Capability | Domäne |
|----|-----------|--------|
| 0 | `system.exit` | Implizit |
| 1 | `system.memory.heap` | Implizit |
| 2 | `system.memory.stack` | Implizit |
| 3 | `system.time` | System |
| 4 | `system.env` | System |
| 5 | `system.rand` | System |
| 6 | `system.unsafe.format_string` | System |
| 7 | `fs.read` | Dateisystem |
| 8 | `fs.write` | Dateisystem |
| 9 | `fs.create` | Dateisystem |
| 10 | `fs.delete` | Dateisystem |
| 11 | `fs.meta` | Dateisystem |
| 12 | `fs.exec` | Dateisystem |
| 13 | `memory.mmap` | Memory |
| 14 | `memory.lock` | Memory |
| 15 | `network.tcp.bind` | Netzwerk |
| 16 | `network.tcp.connect` | Netzwerk |
| 17 | `network.udp.bind` | Netzwerk |
| 18 | `network.udp.connect` | Netzwerk |
| 19 | `network.unix` | Netzwerk |
| 20 | `network.raw` | Netzwerk |
| 21 | `hardware.gpio` | Hardware |
| 22 | `hardware.i2c` | Hardware |
| 23 | `hardware.spi` | Hardware |
| 24 | `hardware.usb` | Hardware |
| 31 | `hardware.block` | Hardware |
| 25 | `process.fork` | Prozess |
| 26 | `process.exec` | Prozess |
| 27 | `process.signal` | Prozess |
| 28 | `process.sched` | Prozess |
| 29 | `process.exit` | Prozess |
| 30 | `fs.perm` | Dateisystem |
| 32 | `system.config` | System |
| 33 | `ki.embed` | KI |
| 34 | `ki.graph` | KI |
| 35 | `audio.mic` | Audio |
| 36 | `audio.play` | Audio |
| 37 | `io.wait` | Ein-/Ausgabe |
| 38 | `io.fd` | Ein-/Ausgabe |
| 39 | `system.tty` | System |

---

## 12. Vollständige Beispiele

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

### 12.2 Modulares Programm mit Grant

```lyx
// robot_controller.lyx
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
// logging.lyx — keine eigenen Capabilities
@uses_caller_cap([fs.write])
fn logEvent(event: pchar): void {
  // Der Aufrufer stellt fs.write bereit
}
```

```lyx
// app.lyx
@capabilities([fs.write(path: "/var/log")])
fn main(): int64 {
  logEvent("app started"c);  // OK: Aufrufer hat fs.write
  return 0;
}
```

---

## 13. Fehlerbehebung

### Programm stirbt mit SIGSYS

Ein Syscall wurde zur Laufzeit blockiert. Typische Ursachen:
- Fehlende Capability (z. B. `fork` ohne `process.fork`)
- Externe Bibliothek ruft einen Syscall auf, der nicht im Capability-Set ist

**Diagnose:** `strace ./mein_programm 2>&1 | grep -i "SIGSYS\|killed"`

**Lösung:** Den fehlenden Syscall der richtigen Capability zuordnen und diese deklarieren.

### EACCES beim Dateizugriff

Der Pfad-Zugriff wird auf Kernel-Ebene blockiert. Typische Ursachen:
- Capability ohne Pfad-Argument deklariert, aber nur ein bestimmter Pfad ist tatsächlich erlaubt
- Hardware-Gerät nicht deklariert (z. B. `/dev/i2c-0` ohne `hardware.i2c(bus: 0)`)

**Lösung:** Capability-Argument mit dem benötigten Pfad ergänzen.

### Migration: Programm ohne `@capabilities`

1. Analyse starten:
   ```bash
   lyxc --migrate-capabilities my_program.lyx
   ```

2. Erzeugtes Manifest einfügen, zunächst im Compat-Modus testen:
   ```bash
   lyxc --capabilities=compat my_program.lyx -o my_program
   ```

3. Vollständig aktivieren und Audit-Output lesen:
   ```bash
   lyxc my_program.lyx -o my_program
   ```

4. Fehlende `grant`-Klauseln ergänzen, um den Security-Score zu maximieren.

### Kernel < 5.13

Der Compiler gibt eine Warnung aus. Pfad-basierte Einschränkungen sind dann nicht aktiv; nur Syscall-Filterung bleibt wirksam. Für volle LCBS-Garantien ist Kernel ≥ 5.13 erforderlich.

---

*Lyx LCBS v3.0 — Stand: Juni 2026*
