# Lyx Capability-Based Security (LCBS) — Spezifikation v3.0

> **Status:** Überarbeiteter Entwurf (v3.0)
> **Ziel-Compiler:** lyxc v0.10+
> **Abhängigkeiten:** WP-6 (W^X für ELF), WP-7 (Path Traversal) – müssen vor LCBS abgeschlossen sein
> **Referenzen:** `ebnf.md`, `security.md`, `COMPILER_MANUAL.md`, `src/frontend/ffi_parser.lyx`
> **Änderungen gegenüber v2.0:** Grant-basiertes Vererbungsmodell, vollständige EBNF, implizite Capabilities, Proxy-Lifecycle, Klassen-Modell überarbeitet, ROP-Analyse, WP-Struktur

---

## 1. Einleitung & Grundphilosophie

Standardmäßig besitzt ein kompiliertes Lyx-Programm **keinerlei Rechte** (Zero-Privilege-Prinzip). Es kann weder auf das Dateisystem zugreifen, noch Netzwerkverbindungen öffnen, noch Hardware-Pins manipulieren.

Ressourcen werden durch **explizite Capability-Deklarationen** freigeschaltet. Das Sicherheitsmodell ist **Grant-basiert**: ein importiertes Modul erhält per Default **keine** Capabilities seines Importierenden – es erhält nur, was ihm explizit gewährt wird.

LCBS verwendet ein mehrschichtiges Validierungsmodell:

| Schicht | Zeitpunkt | Mechanismus |
|---------|-----------|-------------|
| 1. Sprach-/Compiler-Ebene | Compile-Zeit | `@capabilities`-Annotation, Grant-Validierung |
| 2. FFI-Ebene | Compile-Zeit | Signatur-basierte Klassifizierung, Blacklist |
| 3. Link-Ebene | Compile-Zeit | Dead-Module-Eliminierung (Reachability-Analyse) |
| 4. Runtime-Start | Prozessstart | seccomp-BPF + Landlock vor `main()` |
| 5. Runtime-Prozess | Laufzeit | W^X (getrennte RX/RW-Segmente), RELRO, Stack Canaries |

> **Wichtigste Änderung zu v2.0:** Das alte Modell „Import ohne `restrict` → Modul erbt alle Rechte des Importierenden" ist **ersetzt**. Das neue Modell: „Import ohne `grant` → Modul erhält seine deklarierten Mindest-Capabilities, **gekappt** auf die Menge des Importierenden". Details in Abschnitt 5.

---

## 2. Voraussetzungen: W^X und ergänzende Härtung

LCBS setzt folgende Schutzmechanismen als **blockierende Prerequisiten** voraus:

### 2.1 W^X (WP-6)

- **RX-Segment:** `.text` (ausführbar, nicht beschreibbar)
- **RW-Segment:** `.data`, `.bss`, Stack, Heap (beschreibbar, nicht ausführbar)
- **PIE:** Position Independent Executable (ASLR-wirksam)

### 2.2 RELRO (WP-6, Erweiterung)

Read-Only Relocations: nach dem Dynamic-Linker-Lauf werden die GOT/PLT-Sektionen als read-only remappt (`mprotect`). Das verhindert, dass ein Angreifer Funktionszeiger in der GOT überschreibt.

### 2.3 ROP ist durch W^X allein nicht verhindert

> **Wichtige Klarstellung:** W^X verhindert Shellcode-Injektion, aber **nicht Return-Oriented-Programming (ROP)**. Ein Angreifer mit Schreibzugriff auf Stack oder Heap kann vorhandene Code-Gadgets im `.text`-Segment verketten und direkt `syscall`-Gadgets ausführen – ohne eine einzige Byte in ein RWX-Segment zu schreiben.

Wirksamer Schutz gegen ROP erfordert das Zusammenspiel mehrerer Mechanismen:

| Mechanismus | Wirkung | Lücke |
|-------------|---------|-------|
| W^X | kein Shellcode | ROP-Chains weiterhin möglich |
| ASLR + PIE | Gadget-Adressen unbekannt | Entropie-Angriffe, Info-Leaks |
| seccomp (LCBS) | unbekannte Syscalls blockiert | Bekannte Syscalls via ROP noch möglich |
| Stack Canaries (WP-18) | Stack-Overflow erkannt | Heap-Overflows nicht abgedeckt |
| seccomp SECCOMP_RET_KILL_PROCESS | Gesamten Prozess bei Violation töten | – |

**Fazit:** Kein einzelner Mechanismus schützt vollständig. LCBS verkleinert die Angriffsfläche durch seccomp erheblich (nur deklarierte Syscalls erlaubt), aber ein Angreifer der einen Info-Leak ausnutzen kann, behält die Möglichkeit zu ROP-Angriffen auf erlaubte Syscalls. Dies ist ein bekanntes, dokumentiertes Limit des Modells (vgl. Abschnitt 14).

---

## 3. Syntax: Das `@capabilities`-Manifest

### 3.1 EBNF-Erweiterungen (vollständig)

```ebnf
(* Capability-Annotation für Funktionen, Module, Klassen *)
CapabilityAttr   = "@capabilities" "(" "[" CapabilityList "]" ")" ;

CapabilityList   = CapabilityDecl { "," CapabilityDecl } ;

CapabilityDecl   = CapabilityPath
                   [ "(" CapabilityArgList ")" ]
                   [ "@fastpath" ] ;

CapabilityPath   = Ident { "." Ident } ;

CapabilityArgList = CapabilityArg { "," CapabilityArg } ;

(* Ein einzelnes Argument: name: wert *)
CapabilityArg    = Ident ":" CapabilityArgValue ;

CapabilityArgValue = StringLiteral
                   | IntLiteral
                   | Ident              (* z. B. input, output, up, down *)
                   | NetworkTarget      (* z. B. "192.168.1.0/24":5000 *)
                   | "dynamic" ;        (* nur für @capabilities(dynamic) *)

(* Netzwerk-Adressen mit optionalem CIDR und Port *)
NetworkTarget    = NetworkAddr [ ":" PortSpec ] ;
NetworkAddr      = "*"
                 | IPv4Cidr
                 | IPv6Literal ;        (* IPv6 als StringLiteral *)
IPv4Cidr         = IPv4Addr [ "/" IntLiteral ] ;
IPv4Addr         = IntLiteral "." IntLiteral "." IntLiteral "." IntLiteral ;
PortSpec         = "*"
                 | IntLiteral
                 | IntLiteral "-" IntLiteral ;   (* Port-Bereich *)

(* Erweiterung ImportDecl: grant und restrict *)
ImportDecl       = "import"
                   ImportItem { "," ImportItem }
                   ";" ;

ImportItem       = DotPath
                   [ "grant"    "[" CapabilityList "]" ]
                   [ "restrict" "[" CapabilityList "]" ] ;

(* Hinweis: grant und restrict sind kombinierbar.
   Effektive Capabilities = (declared ∩ parent) ∩ restrict, wenn kein grant.
   Effektive Capabilities = (grant ∩ parent),                wenn grant. *)

(* Extern-Fn mit optionalem Capability-Tag *)
ExternFnDecl     = "extern"
                   [ "@cap" "(" CapabilityPath ")" ]
                   "fn"
                   Ident
                   "(" [ ParamList ] ")"
                   [ ":" Type ]
                   "link" StringLiteral
                   ";" ;

(* Caller-Capability-Deklaration für Capability-Leihe *)
UsesCallerCap    = "@uses_caller_cap" "(" "[" CapabilityList "]" ")" ;
```

### 3.2 Beispiele

#### Minimal-Programm (keinerlei explizite Rechte)

```lyx
fn main(): void {
    // Kein Dateizugriff, kein Netzwerk, kein GPIO.
    // Implizit aktiv: system.exit, system.memory.heap (siehe Abschnitt 6)
}
```

#### Robot Controller mit Capabilities

```lyx
@capabilities([
    hardware.gpio(pin: 18, direction: output, initial: low),
    hardware.gpio(pin: 23, direction: input, pull: up),
    network.udp(connect: "192.168.1.0/24":5000),
    fs.read(path: "/etc/robot.conf"),
    process.exec(binary: "/usr/bin/tar")
])
fn main(): void {
    // ...
}
```

#### Import mit `grant` (neues Grant-Modell)

```lyx
// Modul bekommt genau das, was ihm explizit gewährt wird.
// Ohne grant bekommt es seine deklarierten Capabilities ∩ Eltern-Capabilities.
import
    std.hardware.gpio grant [hardware.gpio(pin: 18, direction: output)],
    std.net.udp       grant [network.udp(connect: "192.168.1.0/24":5000)],
    ThirdParty.Parser restrict [fs.read(path: "/etc/robot.conf")];
//  ^ restrict schränkt zusätzlich ein: Parser bekommt
//    min(deklariert, Eltern) ∩ restrict_set
```

#### Extern-Fn mit Capability-Tag

```lyx
@cap(fs.write) extern fn fwrite(ptr: Pointer; size: u64; nmemb: u64; stream: Pointer): u64
    link "libc.so.6";

@cap(network.tcp.connect) extern fn connect(fd: i32; addr: Pointer; len: u32): i32
    link "libc.so.6";
```

#### @fastpath (kein Userspace-Proxy, nur seccomp/landlock)

```lyx
@capabilities([
    network.udp(connect: "*":9000) @fastpath
])
fn highFrequencyPublisher(): void {
    // Direkte UDP-Nutzung ohne Proxy-Overhead.
    // Kein IP/Port-Filter auf Lyx-Ebene – nur seccomp blockiert alles außer UDP.
}
```

### 3.3 Syntax-Begründung

| Entscheidung | Begründung |
|-------------|-----------|
| `@capabilities([...])` statt `program ... capabilities` | Konsistenz mit bestehenden Annotations (`@integrity`, `@dal`, `@wcet`) |
| `()` für Capability-Argumente (statt `[]` in v2.0 EBNF) | Konsistenz mit Beispielen; `[]` war nur in der EBNF, nicht in der Praxis |
| `grant` statt implizite Vererbung | Explizit ist sicherer als implizit – vergessener `grant` = keine Rechte (lauter Fehler) |
| `NetworkTarget` als eigene Produktion | `"192.168.1.0/24":5000` war in v2.0 grammatikalisch undefiniert |
| `@fastpath` als Modifier | Nicht als separate Capability, sondern als Transport-Hinweis |
| `@uses_caller_cap` | Ersetzt das ungeklärte "Call-Graph-Analyse wie Rusts Borrow Checker" durch ein explizites, implementierbares Konstrukt |

---

## 4. Capability-Hierarchie (vollständig)

### 4.1 Implizite Capabilities (immer aktiv, nicht widerrufbar)

Diese Capabilities sind in jedem Lyx-Programm aktiv, ohne dass sie deklariert werden müssen. Sie erscheinen im Security-Audit-Output, können aber nicht via `restrict` entfernt werden.

| Capability | Syscall | Begründung |
|-----------|---------|-----------|
| `system.exit` | `exit_group` | Jedes Programm muss beendet werden können. Fehlt dieser Syscall im seccomp-Filter, endet das Programm mit SIGSYS statt sauber. |
| `system.memory.heap` | `brk`, `mmap(ANON)`, `munmap` | `malloc`/`free` nutzen intern `brk` oder `mmap`. Alle Programme, die dynamisch allokieren, benötigen diese Syscalls. Ein seccomp-Filter ohne `brk` würde beim ersten `malloc` crashen. |
| `system.memory.stack` | `mmap(STACK)` | Stack-Erweiterung bei Stack-Overflows (selten, aber notwendig für Stabilität) |

> **Designentscheidung:** Diese drei Capabilities implizit zu machen löst die in v2.0 ungelöste Spannung zwischen `malloc` (Klasse 0) und `memory.mmap`-Capability. Der seccomp-Filter erlaubt `brk`/anonymes `mmap` immer; `memory.mmap` steuert nur *benanntes* `mmap` (Datei-Mappings).

### 4.2 Explizite Capability-Domänen

| Domain | Capability | Parameter | Syscall | Kernel-Mechanismus |
|--------|-----------|-----------|---------|-------------------|
| `system` | `system.time` | – | `clock_gettime` | seccomp |
| `system` | `system.env` | `key: "NAME"` | – | Compile-Zeit-Filter |
| `system` | `system.rand` | – | `getrandom` | seccomp |
| `system` | `system.unsafe.format_string` | – | – | Compile-Zeit (FFI-Klasse 3 Ausnahme) |
| `fs` | `fs.read` | `path: "/pfad"` | `openat(O_RDONLY)`, `read` | landlock |
| `fs` | `fs.write` | `path: "/pfad"` | `openat(O_WRONLY\|O_RDWR)`, `write` | landlock |
| `fs` | `fs.create` | `path: "/pfad"` | `openat(O_CREAT)` | landlock |
| `fs` | `fs.delete` | `path: "/pfad"` | `unlinkat`, `rmdir` | landlock |
| `fs` | `fs.meta` | `path: "/pfad"` | `statx`, `getdents64` | landlock |
| `fs` | `fs.exec` | `path: "/pfad"` | `execveat` | landlock + seccomp |
| `memory` | `memory.mmap` | – | `mmap(FILE\|SHARED)`, `mprotect` | seccomp |
| `memory` | `memory.lock` | – | `mlock`, `mlockall` | seccomp |
| `network` | `network.tcp.bind` | `port: N` | `bind`, `listen`, `accept` | seccomp + Proxy |
| `network` | `network.tcp.connect` | `addr: "…"`, `port: N` | `connect` | seccomp + Proxy |
| `network` | `network.udp.bind` | `port: N` | `bind`, `recvfrom` | seccomp + Proxy |
| `network` | `network.udp.connect` | `addr: "…"`, `port: N` | `sendto`, `connect` | seccomp + Proxy |
| `network` | `network.unix` | `path: "/pfad"` | `socket(AF_UNIX)` | seccomp + landlock |
| `network` | `network.raw` | – | `socket(AF_PACKET)` | seccomp + **CAP_NET_RAW** |
| `hardware` | `hardware.gpio` | `pin: N`, `direction: in\|out` | `ioctl` auf `/dev/gpiochipX` | landlock |
| `hardware` | `hardware.i2c` | `bus: N` | `ioctl` auf `/dev/i2c-N` | landlock |
| `hardware` | `hardware.spi` | `bus: N`, `cs: N` | `ioctl` auf `/dev/spidevN.N` | landlock |
| `hardware` | `hardware.usb` | `vendor: N`, `product: N` | `ioctl` auf `/dev/bus/usb/` | landlock |
| `process` | `process.fork` | – | `clone`, `fork` | seccomp |
| `process` | `process.exec` | `binary: "/pfad"` | `execve`, `execveat` | seccomp + landlock |
| `process` | `process.signal` | `pid: N\|"self"\|"group"` | `kill`, `tgkill` | seccomp |
| `process` | `process.sched` | – | `sched_setattr`, `nice` | seccomp |
| `process` | `process.exit` | – | `exit`, `exit_group` | seccomp *(redundant zu system.exit)* |

> **`network.raw`-Hinweis:** Raw Sockets erfordern die Linux-Prozess-Capability `CAP_NET_RAW`. Ein Lyx-Programm ohne Root-Rechte kann diese nicht selbst erwerben – entweder muss das Binary via `setcap cap_net_raw+ep` markiert oder als Root gestartet werden. LCBS prüft zur Compile-Zeit, ob `network.raw` deklariert ist, und gibt eine Warnung aus, wenn das Binary nicht für Root-Ausführung konfiguriert ist.

---

## 5. Capability-Vererbungsmodell (Grant-basiert)

Dies ist die **fundamentalste Änderung** gegenüber v2.0.

### 5.1 Das Problem mit v2.0 (Ambient Authority)

v2.0 Regel 3: „Import ohne `restrict`: C(M) = C(P)" – ein Modul erbt alle Rechte des Importierenden.

Das ist **Ambient Authority**: Recht durch implizite Nähe, nicht durch explizite Vergabe. Es bedeutet:
- Vergessene `restrict`-Klausel → Modul hat zu viele Rechte (stiller Fehler)
- Das widerspricht dem OCAP-Prinzip (Object Capabilities)

### 5.2 Das neue Grant-Modell

```
Gegeben:
  C(P)       = Capabilities des Importierenden (Parent)
  C(M_decl)  = vom Modul selbst deklarierte Capabilities (@capabilities)
  grant_set  = explizit via grant [...] gewährte Capabilities
  restrict_set = explizit via restrict [...] eingeschränkte Capabilities

Regel 1 – Import ohne grant, ohne restrict:
  C(M) = C(M_decl) ∩ C(P)
  → Modul bekommt seine deklarierten Capabilities, gekappt auf Eltern-Menge.
  → Vergisst man grant, bekommt M was es braucht (falls Eltern es hat).
  → Fehlt eine Capability im Eltern: Compiler-Fehler.

Regel 2 – Import mit grant:
  C(M) = grant_set ∩ C(P)
  → Explizite Override: grant_set definiert die Menge exakt.
  → grant_set muss ⊆ C(P), sonst Compiler-Fehler.
  → grant_set kann kleiner als C(M_decl) sein (Einschränkung).
  → grant_set kann gleich C(M_decl) sein (explizite Bestätigung).

Regel 3 – Import mit restrict (ohne grant):
  C(M) = C(M_decl) ∩ C(P) ∩ restrict_set
  → Restrict schränkt unterhalb des deklarierten Minimums ein.
  → Nützlich für Drittanbieter-Module, denen man misstraut.

Regel 4 – Import mit grant und restrict (kombiniert):
  C(M) = grant_set ∩ C(P) ∩ restrict_set
  → Selten benötigt; erlaubt feingranulare Kontrolle.

Invariante (unveränderlich):
  ∀ M: C(M) ⊆ C(parent(M))
  → Kein Modul kann mehr Rechte haben als sein Importierender. Nie.
```

### 5.3 Konsequenz: Vergessene Grant vs. vergessene Restrict

| Szenario | v2.0 (Restrict-Modell) | v3.0 (Grant-Modell) |
|----------|----------------------|---------------------|
| Annotation vergessen | Modul hat ALLE Eltern-Rechte | Modul hat nur deklariertes Minimum |
| Fehler entdeckt wie? | Erst beim Audit oder Pentest | Compiler-Fehler, wenn Eltern Capability fehlt |
| Sicherheitsrisiko | Zu viele Rechte (still) | Zu wenige Rechte (laut) |
| Fail-Safe? | Nein – fail-open | Ja – fail-closed |

### 5.4 Transitivität

```
C(N) ⊆ C(M) ⊆ C(P)   ← für alle transitiven Imports

Formell:
∀ m ∈ Modul-Graph: C(m) = C(m_decl) ∩ C(parent(m)) ∩ grant_from_parent(m)
```

### 5.5 Capability-Versioning (Breaking Changes)

| Änderungstyp | Auswirkung | Compiler-Verhalten |
|-------------|-----------|-------------------|
| Modul fügt Capability hinzu (additiv) | Neuer Bedarf | Warnung, wenn Eltern fehlt; Fehler wenn in grant_set fehlt |
| Modul entfernt Capability (subtraktiv) | Weniger Bedarf | Kein Problem |
| Modul ändert Capability-Parameter | Breaking Change | Fehler – grant/restrict-Klausel des Importierenden wird ungültig |

---

## 6. Implizite Capabilities und Systemrechte

Folgende Capabilities sind in **jedem** Lyx-Programm aktiv und erscheinen automatisch im Audit-Output:

```
Implizit (nicht deklarierbar, nicht widerrufbar):
  system.exit         → exit_group immer im seccomp erlaubt
  system.memory.heap  → brk, mmap(MAP_ANON) immer erlaubt
  system.memory.stack → mmap(MAP_STACK) bei Stack-Overflow

Implizit (aktiv wenn dynamische Allokation genutzt wird):
  system.memory.heap  → aktiviert sich, wenn alloc()/dealloc() im AST erscheint
```

Die Trennung von `memory.mmap` (v2.0) wird aufgelöst: `memory.mmap` steuert ab v3.0 nur noch **dateigestütztes Mapping** (`mmap` mit `fd >= 0`). Anonymes Mapping für den Heap ist implizit.

---

## 7. FFI-Absicherung

### 7.1 FFI-Funktionsklassen (unverändert gegenüber v2.0, ergänzt)

| Klasse | Beschreibung | Capability | Besonderheit |
|--------|-------------|------------|--------------|
| **0: Safe** | Reine Berechnung ohne Seiteneffekte (`sin`, `memcpy`, `strlen`, `strlcpy`, `strlcat`, `snprintf`) | Keine | Immer erlaubt |
| **1: OS Resource** | Betriebsmittelzugriff (`open`, `read`, `write`, `socket`) | Entsprechend `fs.*`, `network.*` | Compile-Zeit-Prüfung |
| **2: Process** | Prozesssteuerung (`execve`, `fork`, `kill`) | `process.*` | Compile-Zeit + seccomp |
| **3: Verboten (Hard-Blacklist)** | Systemisch unsicher | – | Build bricht ab |

### 7.2 Klasse-3-Erkennung: Signatur-basiert + Namenserkennung

Eine `extern fn`-Deklaration wird als **Klasse 3** eingestuft wenn:

1. **Name matcht Hard-Blacklist:** `gets`, `system`, `popen`, `sprintf`, `vsprintf`, `strcpy`, `strcat`, `wcscpy`, `wcscat`, alle `exec*`-Familien-Funktionen (außer `execveat` via `std.sys`).

2. **Signatur-Muster: Unbounded String-Operation:**
   - Erster Parameter `^Char` (oder `char*`), zweiter Parameter ebenfalls `^Char`, **kein** `u64`/`usize`-Parameter als Größenlimit → automatisch Klasse 3.
   - Catches auch unbekannte Funktionen: `mycopy(dst: ^Char, src: ^Char): void` würde abgewiesen.

3. **Format-String-Funktionen:**
   - Namenserkennung: `printf`, `fprintf`, `scanf`, `fscanf`, `sscanf`, `vprintf`, `vfprintf`, `vscanf` → Klasse 3, es sei denn `system.unsafe.format_string` ist deklariert.
   - Signatur-Erkennung: Parameter `format: ^Char` gefolgt von `...` (Variadic) → Klasse 3.

### 7.3 Erlaubte vs. verbotene String-Operationen

| Verboten (Klasse 3) | Erlaubt (Klasse 0) | Prüfung |
|---------------------|-------------------|---------|
| `strcpy(d, s)` | `strlcpy(d, s, n)` | Param 3 muss `usize`/`u64` sein |
| `strcat(d, s)` | `strlcat(d, s, n)` | Param 3 muss `usize`/`u64` sein |
| `sprintf(b, f, …)` | `snprintf(b, n, f, …)` | Param 2 muss `usize`/`u64` sein |
| `gets(b)` | `fgets(b, n, stream)` | Param 2 muss `usize`/`u64` sein |
| `strncpy(d, s, n)` | `strlcpy(d, s, n)` | `strncpy` garantiert kein NUL-Terminator |
| `strncat(d, s, n)` | `strlcat(d, s, n)` | `strncat`-Semantik ist fehleranfällig |

> **Begründung `strncpy`/`strncat`:** Beide wurden in v2.0 als „Klasse 0 (Safe)" eingestuft. Das ist falsch: `strncpy(dst, src, n)` schreibt keinen NUL-Terminator wenn `strlen(src) >= n`. Das erzeugt nicht-terminierte Strings. `strlcpy` ist die korrekte Alternative (immer NUL-terminiert, gibt die Länge zurück). Daher: `strncpy`/`strncat` → **Klasse 1** (erlaubt, aber mit Compiler-Warnung und Hinweis auf `strlcpy`/`strlcat`).

### 7.4 Klassifizierung bestehender Stdlib-Externs

| Funktion | Klasse | Capability | Anmerkung |
|----------|--------|-----------|-----------|
| `malloc`, `free`, `realloc`, `calloc` | 0 | – | Heap ist implizit |
| `exit`, `abort`, `atexit` | 1 | `process.exit` | Saubers Beenden via `std.sys` bevorzugt |
| `printf`, `fprintf`, `scanf`, `fscanf` | 3 | `system.unsafe.format_string` | Nur mit expliziter Capability |
| `sprintf` | 3 | – | **Immer verboten** (keine Größenbegrenzung) |
| `system` | 3 | – | **Immer verboten** (Shell-Injection) |
| `getenv`, `setenv`, `unsetenv` | 1 | `system.env` | |
| `fopen`, `fclose`, `fread`, `fwrite` | 1 | `fs.*` | |
| `strcpy`, `strcat` | 3 | – | **Immer verboten** |
| `strncpy`, `strncat` | 1 | – | Erlaubt mit Warnung; `strlcpy`/`strlcat` bevorzugen |
| `strlcpy`, `strlcat` | 0 | – | Safe |
| `snprintf`, `vsnprintf` | 0 | – | Safe (size-bounded) |
| `memcpy`, `memmove`, `memset`, `memcmp` | 0 | – | Safe |
| `fork` | 2 | `process.fork` | |
| `execve`, `execvp`, `execlp` etc. | 3 | – | **Immer verboten** als direkte FFI |
| `execveat` | 2 | `process.exec` | Nur via `std.sys.process.Execute` |
| `open`, `close`, `read`, `write`, `lseek` | 1 | `fs.*` | |
| `socket`, `bind`, `listen`, `connect` | 1 | `network.*` | |
| `time`, `clock_gettime` | 1 | `system.time` | |
| `sin`, `cos`, `sqrt` etc. | 0 | – | Reine Berechnung |

---

## 8. Capability-Leihe: `@uses_caller_cap`

In v2.0 war unklar, wie eine Funktion die Capabilities ihres Aufrufers nutzen kann (bezeichnet als „Call-Graph-Analyse ähnlich Rusts Borrow Checker"). Das v3.0-Modell ist explizit und ohne vollständiges Type-and-Effect-System implementierbar.

### 8.1 Das Problem

```lyx
module flexible_logger;
// Dieses Modul deklariert keine eigenen Capabilities.
// logToFile braucht aber fs.write – vom Aufrufer.

fn logToFile(path: ^Char; msg: ^Char): void {
    // Hier wird openat(O_WRONLY) genutzt – welche Capability deckt das ab?
}
```

### 8.2 Lösung: `@uses_caller_cap`

```lyx
module flexible_logger;

@uses_caller_cap([fs.write])
fn logToFile(path: ^Char; msg: ^Char): void {
    // Der Aufrufer muss fs.write besitzen.
    // Der Compiler prüft an jedem Callsite, ob der Aufrufer fs.write hat.
}
```

**Semantik:**
- `@uses_caller_cap([X])` bedeutet: Diese Funktion benötigt Capability X, **liefert sie aber nicht selbst** – der Aufrufer muss X besitzen.
- Der Compiler prüft an jedem Aufruf-Site, ob `C(caller) ⊇ uses_caller_cap_set`.
- Das Modul selbst hat `C(flexible_logger) = ∅` – es gibt die Capability nicht weiter.
- Transitiv: wenn `logToFile` eine Funktion aufruft, die ebenfalls `@uses_caller_cap([fs.write])` hat, propagiert die Anforderung nach oben.

### 8.3 Grenzen

- `@uses_caller_cap` funktioniert nur bei statisch bekannten Callsites (keine Funktionszeiger).
- Für Funktionszeiger und Callbacks muss die Capability **im Typ** kodiert werden (zukünftiges WP-20: Capability-Funktionstypen).
- Dies ist keine vollständige Effect-Polymorphismus-Lösung – es ist eine pragmatische, implementierbare Annäherung.

---

## 9. Klassen-Capability-Modell

v2.0 hatte ein widersprüchliches Modell (Instanz erbt Capabilities der erzeugenden Methode, was Regel 2 überflüssig machte). v3.0 definiert:

### 9.1 Regeln

1. **Klassen-Capabilities** werden auf Klassen-Ebene deklariert. Sie gelten für **alle Instanzmethoden**.
2. **Methoden können zusätzliche Capabilities** via `@capabilities` deklarieren (nie weniger als die Klasse).
3. **Statische Methoden** haben keine Instanz-Capabilities; sie benötigen die Capabilities des aufrufenden Moduls.
4. **Alle Instanzen** einer Klasse haben dieselbe Capability-Menge – abgeleitet vom Klassentyp, nicht von der erzeugenden Methode.

```lyx
@capabilities([fs.write(path: "/var/log")])
class FileWriter {
    // Alle Instanzmethoden haben implizit fs.write(path: "/var/log")

    fn writeLog(msg: ^Char): void {
        // fs.write(path: "/var/log") ist durch Klassen-Deklaration abgedeckt
    }

    @capabilities([network.tcp.connect(addr: "log.server:514")])
    fn writeRemote(msg: ^Char): void {
        // fs.write + network.tcp.connect (Vereinigung)
    }

    // Statische Methode – keine Instanz-Capabilities
    static fn formatTimestamp(ts: u64): ^Char {
        // Benötigt keine Capability (reine Berechnung)
    }
}

// Beim Import: Der Importierende muss fs.write besitzen
// und es der Klasse via grant zur Verfügung stellen.
import FileLogger.FileWriter grant [fs.write(path: "/var/log")];
```

### 9.2 Konsequenz für das Typsystem

- Zwei `FileWriter`-Instanzen haben **immer** die gleiche Capability-Menge (`fs.write(path: "/var/log")`).
- `new FileWriter()` an verschiedenen Callsites erzeugt typgleiche Objekte – keine versteckten Capability-Unterschiede.
- Das Typsystem bleibt konsistent: gleicher Typ = gleiche Capabilities.

---

## 10. Netzwerk-Capabilities: Technische Umsetzung

### 10.1 Das Proxy-Modell (wiederholend aus v2.0, ergänzt um Lifecycle)

Seccomp kann keine IP-Adressen oder Ports filtern – es kennt nur Syscall-Nummern. Für granulare Netzwerkfilterung wird der **Userspace-Proxy** benötigt.

### 10.2 Proxy-Lifecycle (neu in v3.0)

```
Startup-Sequenz (in _start, vor seccomp):

1. Binary wird geladen. ELF-Loader führt mmap-Calls aus (kein seccomp aktiv).
2. _start liest .lcbs-ELF-Sektion (Capability-Manifest).
3. Falls network.*-Capabilities mit Adress-/Port-Filter vorhanden:
   a. Erstelle Socketpair (AF_UNIX, SOCK_STREAM) → [fd_child, fd_parent]
   b. fork() → LCBS-Proxy-Prozess
   c. Proxy-Prozess (Kind):
      - Schließt fd_parent
      - Liest Manifest via fd_child (authentifiziert durch gemeinsamen fd, nicht Netzwerk)
      - Installiert eigenen restriktiven seccomp-Filter (nur: socket, bind, connect,
        send, recv, sendmsg, recvmsg, accept, poll, close, exit_group)
      - Validiert alle Verbindungsanfragen gegen das Manifest
      - Reicht Sockets via SCM_RIGHTS durch fd_child weiter
   d. Hauptprogramm (Eltern):
      - Schließt fd_child
      - fd_parent ist der einzige Kommunikationskanal zum Proxy
      - Proxy ist nicht über Netzwerk erreichbar (nur AF_UNIX via vorher erstellten fd)
4. seccomp-Filter des Hauptprogramms wird installiert.
   (network.unix für fd_parent ist implizit erlaubt wenn Proxy aktiv)
5. landlock-Regeln werden installiert.
6. main() wird aufgerufen.
```

### 10.3 Proxy-Authentifizierung

- Der `socketpair`-fd wird **vor** dem Fork erstellt. Ein externer Angreifer kann sich nicht als Proxy ausgeben, weil er keinen Zugriff auf den fd hat.
- Das Manifest wird **nicht** über Netzwerk kommuniziert – nur über den vorher etablierten fd.
- Der Proxy selbst ist durch seinen eigenen seccomp-Filter gehärtet: er kann keine neuen Prozesse starten und hat nur Netzwerk-Syscalls erlaubt.
- `SCM_RIGHTS` für FD-Passing ist im seccomp-Filter des Hauptprogramms durch `sendmsg`/`recvmsg` auf `fd_parent` erlaubt (nur dieser spezifische fd, durch Argument-Filterung im BPF).

### 10.4 Proxy-Härtung

| Maßnahme | Schutz |
|----------|--------|
| Eigener seccomp-Filter | Proxy kann keine Dateien öffnen, keine Prozesse starten |
| Kein `network.raw` im Proxy | Proxy kann keine Raw Sockets öffnen |
| Manifest ist read-only | Proxy kann das Manifest nach dem Lesen nicht mehr ändern |
| Zeitlimit für Verbindungsaufbau | DoS-Schutz: Proxy schließt nach 5s inaktive Sockets |
| ASLR im Proxy-Prozess | PIE gilt für den Proxy-Prozess ebenso |

### 10.5 `@fastpath` – Proxy-Bypass

Für latenzempfindliche Anwendungen (z. B. Echtzeit-Telemetrie) kann der Proxy umgangen werden:

```lyx
@capabilities([
    network.udp(connect: "*":9000) @fastpath
])
fn rtPublish(): void { ... }
```

Mit `@fastpath`:
- Kein Proxy gestartet
- Seccomp erlaubt `socket(AF_INET, SOCK_DGRAM)` + `sendto` direkt
- **Keine IP/Port-Filterung auf LCBS-Ebene** – nur Typ-Filterung (UDP erlaubt, TCP nicht)
- Security-Score wird reduziert (fehlende Proxy-Ebene)

### 10.6 Capability vs. Kernel-Mechanismus

| Capability | seccomp | Proxy | fastpath |
|-----------|---------|-------|---------|
| kein `network.*` | `socket(AF_INET)` blockiert | – | – |
| `network.tcp.connect` | `socket`+`connect` erlaubt | IP/Port-Whitelist | nur wenn `@fastpath` |
| `network.udp.connect` | `socket`+`sendto` erlaubt | IP/Port-Whitelist | nur wenn `@fastpath` |
| `network.tcp.bind` | `socket`+`bind`+`listen` erlaubt | Port-Filter | nur wenn `@fastpath` |
| `network.raw` | `socket(AF_PACKET)` erlaubt | – | immer (kein Proxy möglich) |

---

## 11. Compile-Time Stripping (Dead-Module-Eliminierung)

### 11.1 Funktionsweise (unverändert zu v2.0)

1. Capability-Extraktion aus allen Modulen
2. Modul-Import-Graph mit Capability-Annotationen
3. Reachability-Analyse von `main()`
4. Capability-basiertes Pruning
5. Backend-Code nur für verbliebene Module

### 11.2 Transitive Capability-Berechnung

```
benötigte_caps(m) = eigene_caps(m) ∪ ⋃(importiert n: benötigte_caps(n))

Pruning-Bedingung für Modul m:
  m wird entfernt wenn: benötigte_caps(m) ∩ C(root) = ∅
```

### 11.3 Grenzen und `@uses_caller_cap`-Interaktion

Funktionen mit `@uses_caller_cap([X])` werden **nicht** gepruned nur weil das eigene Modul X nicht hat. Der Compiler bewahrt sie, wenn sie von erreichbaren Callsites aufgerufen werden, die X besitzen.

---

## 12. Runtime Sandboxing (seccomp + landlock)

### 12.1 Startup-Sequenz

```
_start() [generiert vom Compiler]:

1. Lese .lcbs-Sektion des ELF (Capability-Manifest)
2. Falls Proxy benötigt: fork() → LCBS-Proxy (siehe Abschnitt 10.2)
3. Konfiguriere seccomp-BPF:
   - Standardaktion: SECCOMP_RET_KILL_PROCESS  ← bewusst: tötet Prozessgruppe
   - Erlaubt: implizite Capabilities (exit_group, brk, mmap(ANON))
   - Erlaubt: alle aus dem Manifest abgeleiteten Syscalls
   - Proxy-Kommunikation: sendmsg/recvmsg auf fd_parent (falls Proxy aktiv)
4. Konfiguriere landlock-Regeln:
   - Für jedes fs.read(path: p): LANDLOCK_ACCESS_FS_READ_FILE
   - Für jedes fs.write(path: p): LANDLOCK_ACCESS_FS_WRITE_FILE
   - Für jedes fs.create: LANDLOCK_ACCESS_FS_MAKE_REG
   - Für jedes hardware.*: LANDLOCK_ACCESS_FS_READ_FILE auf /dev/*
   - Alle anderen Pfade: blockiert
5. Rufe main() auf
6. Nach main()-Rückkehr: direkt exit_group()
```

### 12.2 Warum `SECCOMP_RET_KILL_PROCESS` statt `SECCOMP_RET_KILL`

`SECCOMP_RET_KILL` sendet SIGSYS an den verletzenden Thread. Ein Angreifer kann einen SIGSYS-Handler installieren und Violations abfangen – das ist ein Bypass-Vektor. `SECCOMP_RET_KILL_PROCESS` tötet sofort die gesamte Prozessgruppe ohne Handler-Möglichkeit.

### 12.3 Overhead-Tabelle (realistisch)

| Komponente | Overhead | Anmerkung |
|-----------|----------|-----------|
| seccomp-BPF | ~50–200ns pro Syscall | Linear zur Regelanzahl |
| landlock | ~100–500ns pro Pfad-Op | Pfad-Präfix-Match |
| Userspace-Proxy | ~5–50µs pro Netzwerk-Op | +1 Context-Switch für Socket-Handoff |
| `@fastpath` | ~50–200ns (nur seccomp) | Kein Proxy-Overhead |
| Compile-Time Stripping | 0 Runtime-Overhead | Nur Compile-Zeit |

---

## 13. Hardware-Capabilities: GPIO, I2C, SPI

### 13.1 Syntax

```lyx
@capabilities([
    hardware.gpio(pin: 18, direction: output, initial: low),
    hardware.gpio(pin: 23, direction: input, pull: up),
    hardware.i2c(bus: 1, address: 0x48),
    hardware.spi(bus: 0, cs: 0, speed: 1000000)
])
```

> **`initial`-Semantik:** Der `initial`-Parameter wird **nicht** beim Capability-Setup gesetzt (das wäre ein Seiteneffekt vor `main()`). Er ist ein Compiler-Hint und wird als ersten Aufruf in `main()` expandiert: `gpio.setPin(18, Low)`. Das ist transparent, aber explizit im generierten Code sichtbar.

### 13.2 Device-Tree-Konfliktprüfung

```
lyxc --target-dtb rpi4.dts program.lyx

Prüfung:
  hardware.gpio(pin: 18) → DTB-Abgleich: Pin 18 = GPIO_OUT (i2c1-SDA belegt Pin 2/3)
  → OK

  hardware.gpio(pin: 2) → DTB-Abgleich: Pin 2 = I2C1-SDA → Conflict!
  → Warning: Pin 2 ist im Device Tree als i2c1-SDA belegt.
             Beim gleichzeitigen Betrieb von I2C und GPIO auf Pin 2 kann
             es zu Hardwareschäden kommen.
```

---

## 14. Sicherheits-Audit als Build-Output

```
=== LCBS Security Audit ==========================================
Programm:          robot_controller.lyx
Capability-Modell: Zero-Privilege (default deny), Grant-basiert

Implizite Capabilities (immer aktiv):
  ○ system.exit          → exit_group
  ○ system.memory.heap   → brk, mmap(MAP_ANON)

Explizite Capabilities:
  ✓ hardware.gpio        → Pin 18 (Output, initial: Low), Pin 23 (Input, Pull-Up)
  ✓ network.udp          → connect 192.168.1.0/24:5000 (via Proxy)
  ✓ fs.read              → /etc/robot.conf (landlock)
  ✓ process.exec         → /usr/bin/tar (seccomp + landlock)

Module mit grant:
  ✓ std.hardware.gpio    grant [hardware.gpio(pin: 18, direction: output)]
  ✓ std.net.udp          grant [network.udp(connect: "192.168.1.0/24":5000)]
  ✓ ThirdParty.Parser    restrict [fs.read(path: "/etc/robot.conf")]

FFI-Klassifizierung:
  Klasse 0 (Safe):    32 Funktionen
  Klasse 1 (OS):       8 Funktionen (mit Capability-Prüfung)
  Klasse 2 (Process):  1 Funktion   (process.exec via std.sys)
  Klasse 3 (Blocked): 12 Funktionen (sprintf, gets, strcpy, ...)

Runtime-Schutz:
  ✓ W^X (getrennte RX/RW-Segmente)
  ✓ RELRO (GOT read-only nach Loader)
  ✓ PIE (ASLR aktiv)
  ✓ seccomp (SECCOMP_RET_KILL_PROCESS, 14 Regeln)
  ✓ landlock (2 Pfad-Regeln)
  ✓ Userspace Proxy (UDP, Port 5000)
  ○ Stack Canaries  (nicht aktiv – WP-18 offen)

Sicherheits-Score: 44/50
  +10: Kein Klasse-3-Extern ohne system.unsafe.format_string
  +10: W^X + RELRO aktiv
  +10: PIE aktiv
   +8: Grant-Modell – 2 Imports ohne explizites grant (–2 pro fehlendem grant)
  +10: seccomp + landlock aktiv
   -6: Stack Canaries fehlen (WP-18 offen)
==================================================================
```

**Score-Berechnung:**

| Kriterium | Max | Wertung |
|-----------|-----|---------|
| Keine Klasse-3-Externs ohne unsafe-Capability | 10 | 0 wenn vorhanden, 10 wenn clean |
| W^X + RELRO | 10 | 5 pro Feature |
| PIE (ASLR) | 10 | 0 wenn fehlt, 10 wenn aktiv |
| Grant-Vollständigkeit: alle Imports haben explizites `grant` | 10 | –2 pro fehlendem `grant` |
| Runtime-Sandboxing (seccomp + landlock) | 10 | 5 pro Feature |
| Bonus: Stack Canaries (WP-18) | +5 | Bonus wenn aktiv |
| Malus: `@fastpath` ohne Proxy | –3 | Pro fastpath-Nutzung |

---

## 15. Timing Side-Channels (Out of Scope, dokumentiert)

**In Scope:**
- Zugriffskontrolle (Capabilities)
- Speicherschutz (W^X, RELRO, ASLR)
- Syscall-Filterung (seccomp, landlock)

**Out of Scope (zukünftig: LCBS v4.0 Privacy-Erweiterung):**
- Constant-Time-Implementierungen (WP-15)
- Cache-Timing-Angriffe (Cache-Partitioning)
- Spectre/Meltdown (Microcode/OS)
- Netzwerk-Timing (Packet-Padding)
- `/proc`-Timing-Leaks (partiell via seccomp abdeckbar)

---

## 16. Dynamische Capabilities (`@capabilities(dynamic)`)

Für Plugins, Scripting, REPL:

```lyx
@capabilities(dynamic)
fn loadPlugin(path: ^Char): void {
    // Plugin kann zur Laufzeit ein Unter-Manifest vorlegen.
    // Authentifizierung: das Unter-Manifest muss mit dem privaten
    // Schlüssel des Lyx-Compilers signiert sein (Build-Zeit-Signatur).
    // Alternativ: Hash des Manifests im übergeordneten @capabilities deklariert.
}
```

**Einschränkungen (unverändert zu v2.0, ergänzt):**
- Nur via AF_UNIX (kein Netzwerk-Manifest)
- Nur ⊆ eigener Capabilities des Hosts
- Muss im Haupt-`@capabilities` via `process.dynamic_load` erklärt sein
- **Neu:** Manifest-Authentizität durch Compiler-Signatur oder Hash-Deklaration:

```lyx
@capabilities([
    process.dynamic_load(
        manifest_hash: "sha256:a3f1bc..."
    )
])
fn loadPlugin(path: ^Char): void { ... }
```

---

## 17. Dokumentierte Annahmen und Grenzen

1. **Single-Process-Modell:** LCBS schützt innerhalb eines Prozesses. IPC liegt im Verantwortungsbereich der jeweiligen Prozess-Capabilities.

2. **Kein Schutz vor Kernel-Exploits:** Ein kompromittierter Kernel kann alle LCBS-Mechanismen umgehen.

3. **Kein Schutz vor ROP auf erlaubte Syscalls:** W^X + seccomp + ASLR verkleinern die Angriffsfläche erheblich, verhindern aber keinen gezielten ROP-Angriff, der sich auf erlaubte Syscalls beschränkt. Stack Canaries (WP-18) und CFI (Control Flow Integrity, future WP) würden das weiter einschränken.

4. **Kein Schutz vor Compiler-Bugs:** Ein Bug im `ffi_parser.lyx` kann LCBS unwirksam machen. Gegenmaßnahme: Fixed-Point-Bootstrap + LCBS-Selbsttest (WP-15).

5. **Proxy als Single-Point-of-Failure:** Der Userspace-Proxy ist durch eigenen seccomp und read-only Manifest gehärtet (Abschnitt 10.4), bleibt aber ein privilegierter Prozess.

6. **`network.raw` erfordert OS-Capabilities:** `CAP_NET_RAW` liegt außerhalb des LCBS-Modells. Lyx kann diese Linux-Capability nicht selbst erwerben.

7. **`@uses_caller_cap` nur bei statischen Callsites:** Funktionszeiger und virtuelle Dispatch sind nicht abgedeckt (zukünftiges WP-20).

---

## 18. Arbeitspakete (WPs)

| WP | Titel | Aufwand | Priorität | Abhängigkeit |
|----|-------|---------|-----------|-------------|
| WP-L1 | EBNF-Erweiterung + Parser | 2 PT | 🔴 Hoch | – |
| WP-L2 | Capability-Hierarchie (vollständige Tabelle, implizite Caps) | 1 PT | 🔴 Hoch | – |
| WP-L3 | Grant-basiertes Vererbungsmodell | 3 PT | 🔴 Hoch | WP-L1, WP-L2 |
| WP-L4 | Transitiver Capability-Graph | 2 PT | 🔴 Hoch | WP-L3 |
| WP-L5 | FFI-Klassifizierung + Signatur-Validierung | 2 PT | 🔴 Hoch | WP-L2 |
| WP-L6 | Compile-Time Stripping | 2 PT | 🟡 Mittel | WP-L4 |
| WP-L7 | `@uses_caller_cap` (Capability-Leihe) | 2 PT | 🟡 Mittel | WP-L3 |
| WP-L8 | Klassen-Capability-Modell | 2 PT | 🟡 Mittel | WP-L3 |
| WP-R9 | seccomp-BPF-Codegenerierung | 3 PT | 🔴 Hoch | WP-L4, WP-6 |
| WP-R10 | Landlock-Integration | 2 PT | 🔴 Hoch | WP-L2, WP-6 |
| WP-R11 | Userspace-Netzwerk-Proxy + Lifecycle | 4 PT | 🟡 Mittel | WP-R9 |
| WP-H12 | Hardware-Capabilities + Device Tree | 2 PT | 🟡 Mittel | WP-R10 |
| WP-T13 | Security Audit Output + Score | 1 PT | 🟡 Mittel | WP-L4, WP-R9 |
| WP-T14 | Migration Tool (`--migrate-capabilities`) | 3 PT | 🟢 Niedrig | WP-L5, WP-R9 |
| WP-T15 | LCBS-Selbsttest (Compiler compiliert sich mit LCBS) | 2 PT | 🟢 Niedrig | alle WPs |

---

### WP-L1: EBNF-Erweiterung + Parser

#### Grund
Die v2.0-Grammatik hatte eine Inkonsistenz: die EBNF verwendete `[]` für Capability-Argumente, die Beispiele `()`. Außerdem fehlte eine `NetworkTarget`-Produktion für `"192.168.1.0/24":5000`, `@fastpath` und `@uses_caller_cap`. Ohne korrekte Grammatik kann der Parser keine validen Syntax-Bäume für Capability-Annotationen erzeugen.

#### Inhalt
- EBNF gemäß Abschnitt 3.1 in `ebnf.md` eintragen
- Parser-Erweiterung in `src/frontend/parser.lyx`: `CapabilityAttr`, `CapabilityDecl`, `NetworkTarget`, `IPv4Cidr`, `PortSpec`, `ImportItem` mit `grant`/`restrict`, `ExternFnDecl` mit `@cap`, `UsesCallerCap`
- AST-Knoten: `nkCapabilityAttr`, `nkGrantClause`, `nkRestrictClause`, `nkCapabilityDecl`, `nkNetworkTarget`

#### Abnahmekriterien
1. `@capabilities([fs.read(path: "/etc")])` wird korrekt geparst; `nkCapabilityAttr`-Knoten im AST.
2. `network.udp(connect: "192.168.1.0/24":5000)` ergibt AST-Knoten mit `IPv4Cidr="192.168.1.0/24"` und `port=5000`.
3. `import Mod grant [fs.read(path: "/etc")]` erzeugt `nkGrantClause`-Knoten.
4. `@fastpath`-Modifier wird als Flag am `nkCapabilityDecl`-Knoten gesetzt.
5. `@uses_caller_cap([fs.write])` erzeugt `nkUsesCallerCap`-Knoten an der Funktionsdeklaration.
6. Fehlerhafte Syntax (`@capabilities([fs.read path: "/etc"])` – fehlendes `(`) erzeugt hilfreiche Fehlermeldung mit Zeilennummer.

---

### WP-L2: Capability-Hierarchie (vollständige Tabelle, implizite Capabilities)

#### Grund
v2.0 fehlten `system.exit` und `system.memory.heap` in der Hierarchie, obwohl jedes Programm diese Syscalls benötigt. Fehlten sie im seccomp-Filter, würde das Programm bei `exit()` oder `malloc()` mit SIGSYS sterben. Außerdem fehlte `system.unsafe.format_string`, das in der FFI-Klassifizierung referenziert wurde.

#### Inhalt
- Capability-Registry in `src/security/capabilities.lyx` anlegen
- Alle Capabilities aus Abschnitt 4 implementieren
- Implizite Capabilities (`system.exit`, `system.memory.heap`, `system.memory.stack`) als eigene Kategorie; werden immer in den seccomp-Filter eingetragen, ohne dass sie im `@capabilities`-Attribut auftauchen müssen
- Capability-Parameter-Validierung: `pin` muss 0–53, `port` muss 1–65535 etc.

#### Abnahmekriterien
1. `CapabilityRegistry.Resolve("system.exit")` liefert `[exit_group]` als Syscall-Liste.
2. `CapabilityRegistry.Resolve("system.memory.heap")` liefert `[brk, mmap(MAP_ANON), munmap]`.
3. `CapabilityRegistry.Resolve("network.udp.connect")` liefert `[socket(AF_INET,SOCK_DGRAM), sendto, connect]`.
4. `hardware.gpio(pin: 54)` → Compiler-Fehler „Pin 54 außerhalb des gültigen Bereichs 0–53".
5. `network.tcp.connect(port: 0)` → Compiler-Fehler „Port 0 ist kein gültiger Port".
6. Alle 25 expliziten Capabilities aus Abschnitt 4.2 sind registriert und auflösbar.

---

### WP-L3: Grant-basiertes Vererbungsmodell

#### Grund
v2.0 verwendete Ambient Authority: `C(M) = C(P)` als Default. Das ist das genaue Gegenteil von Least-Privilege und führt dazu, dass ein vergessenes `restrict` ein Modul mit zu vielen Rechten ausstattet (stiller Fehler). Das neue Modell (Abschnitt 5) ist fail-closed: vergessenes `grant` gibt das deklarierte Minimum, nicht das Maximum.

#### Inhalt
- Capability-Resolver in `src/security/capability_resolver.lyx`
- Implementierung der vier Vererbungsregeln (Abschnitt 5.2)
- Invarianten-Check: `C(M) ⊆ C(parent(M))` bei jedem Import
- Compiler-Fehler wenn `grant_set ⊄ C(parent)` (Eskalationsversuch)
- Compiler-Warnung wenn ein Import kein explizites `grant` hat (fördert explizite Deklaration, zählt negativ im Security Score)
- Breaking-Change-Erkennung bei Capability-Versioning

#### Abnahmekriterien
1. `import M` (ohne grant, M deklariert `fs.read`): `C(M) = {fs.read} ∩ C(P)`.
2. `import M grant [fs.read]`: `C(M) = {fs.read} ∩ C(P)`, egal was M deklariert.
3. `import M grant [network.tcp.connect]` wenn `C(P) = {fs.read}` → Compiler-Fehler „network.tcp.connect nicht in Parent-Capabilities".
4. Drei-Ebenen-Transitivität: P → M → N, jede Ebene kann nur einschränken, nie erweitern.
5. Capability-Versioning: Modul ändert `fs.read(path: "/etc/a")` → `fs.read(path: "/etc/b")` → Compiler-Fehler bei bestehendem `grant [fs.read(path: "/etc/a")]`.
6. Compiler-Warnung: „Import ohne explizites grant – Security-Score –2" wenn kein `grant` angegeben.

---

### WP-L4: Transitiver Capability-Graph

#### Grund
Module können ihrerseits Module importieren. Die Menge der Capabilities, die ein Programm-Root benötigen muss, ergibt sich aus der transitiven Hülle aller Importe. Ohne diese Berechnung ist Compile-Time Stripping (WP-L6) nicht korrekt möglich, und Capability-Eskalation über tiefe Import-Ketten könnte unentdeckt bleiben.

#### Inhalt
- Graph-Berechnung in `src/security/cap_graph.lyx`
- Fixpunkt-Algorithmus: `benötigte_caps(m) = eigene_caps(m) ∪ ⋃(importiert n: benötigte_caps(n))`
- Zyklus-Erkennung (Module können sich gegenseitig importieren)
- `@uses_caller_cap`-Propagation: Anforderungen an Callsites weitergeben

#### Abnahmekriterien
1. `std.net.udp` → transitiv `system.memory.heap`: wird korrekt erkannt.
2. Zyklischer Import `A → B → A` wird erkannt und mit Fehler abgebrochen.
3. Die transitive Capability-Menge des Hauptprogramms umfasst alle direkt und indirekt benötigten Capabilities.
4. Ein Test mit 5-Ebenen-Import-Hierarchie berechnet die korrekte transitive Hülle.

---

### WP-L5: FFI-Klassifizierung + Signatur-Validierung

#### Grund
Eine reine Blacklist nach Namen kann durch unbekannte Funktionen mit gefährlichen Signaturen umgangen werden (`mycopy(dst: ^Char, src: ^Char): void` würde nicht erkannt). Die Signatur-basierte Erkennung schließt diese Lücke. Außerdem wurden `strncpy`/`strncat` in v2.0 fälschlich als sicher (Klasse 0) eingestuft.

#### Inhalt
- FFI-Validator in `src/frontend/ffi_parser.lyx` (existiert bereits, erweitern)
- Vier-Klassen-System implementieren
- Signatur-Erkennung: unbounded `^Char`-Parameter ohne `usize`-Limit → Klasse 3
- Format-String-Erkennung: Namensliste + Variadic-Signatur → Klasse 3
- `strncpy`/`strncat` von Klasse 0 auf Klasse 1 hochstufen (Warnung + Hinweis auf `strlcpy`)
- `system.unsafe.format_string` als Klasse-3-Ausnahme implementieren

#### Abnahmekriterien
1. `extern fn strcpy(d: ^Char, s: ^Char): ^Char link "libc.so.6"` → Compiler-Fehler Klasse 3.
2. `extern fn mycopy(d: ^Char, s: ^Char): void link "mylib.so"` → Compiler-Fehler Klasse 3 (Signatur-Match).
3. `extern fn strlcpy(d: ^Char, s: ^Char, n: u64): u64 link "libc.so.6"` → OK (Klasse 0).
4. `extern fn strncpy(...)` → Compiler-Warnung + Hinweis auf `strlcpy`.
5. `extern fn printf(...)` ohne `system.unsafe.format_string` → Compiler-Fehler.
6. `extern fn printf(...)` mit `@capabilities([system.unsafe.format_string])` → OK.
7. `extern fn snprintf(buf: ^Char, n: u64, fmt: ^Char, ...): i32` → Klasse 0 (size-bounded).

---

### WP-L6: Compile-Time Stripping (Dead-Module-Eliminierung)

#### Grund
Programme sollen nur die Module im Binary enthalten, die tatsächlich erreichbar sind und deren Capabilities im Hauptprogramm-Manifest liegen. Ein UDP-Modul soll nicht im Binary erscheinen, wenn das Programm keine `network.udp`-Capability hat.

#### Inhalt
- Reachability-Analyse im AST (von `main()` ausgehend)
- Capability-basiertes Pruning: Modul entfernen wenn `benötigte_caps(m) ∩ C(root) = ∅`
- `@uses_caller_cap`-Interaktion: Funktionen mit Caller-Capabilities nicht prunen wenn Callsites sie referenzieren
- Pruning-Report im Build-Output

#### Abnahmekriterien
1. Programm ohne `network.*`-Capability: `std.net.*`-Module erscheinen nicht im Binary (`nm` / `objdump` bestätigt).
2. Programm mit `fs.read` aber ohne `fs.write`: `std.fs.writer`-Module sind nicht im Binary.
3. Ein Modul mit `@uses_caller_cap([network.tcp.connect])` das von unerreichbaren Callsites aufgerufen wird → gepruned.
4. Ein Modul mit `@uses_caller_cap([network.tcp.connect])` das von erreichbaren Callsites mit `network.tcp.connect` aufgerufen wird → nicht gepruned.

---

### WP-L7: `@uses_caller_cap` (Capability-Leihe)

#### Grund
Bibliotheks-Funktionen wie `logToFile` brauchen Capabilities, die sie selbst nicht besitzen, sondern vom Aufrufer erhalten. Ohne `@uses_caller_cap` müsste das Bibliotheks-Modul selbst alle möglichen Capabilities deklarieren, was das Prinzip der minimalen Capabilities unterläuft.

#### Inhalt
- `@uses_caller_cap`-Annotation im AST
- Callsite-Prüfung: wenn `fn f` deklariert `@uses_caller_cap([X])`, muss jeder Aufrufer `X ∈ C(caller)` haben
- Propagation: wenn `f` eine Funktion `g` aufruft, die ebenfalls `@uses_caller_cap([X])` hat, wird X an Aufrufer von `f` weiterpropagiert
- Einschränkung: nur bei statisch auflösbaren Callsites; Funktionszeiger nicht abgedeckt (Compiler-Warnung)

#### Abnahmekriterien
1. `@uses_caller_cap([fs.write]) fn logToFile(...)` – Aufruf aus Funktion mit `fs.write` → OK.
2. Aufruf aus Funktion ohne `fs.write` → Compiler-Fehler „Caller hat nicht: fs.write".
3. Transitive Propagation über zwei Ebenen korrekt.
4. Aufruf via Funktionszeiger → Compiler-Warnung „@uses_caller_cap bei indirektem Aufruf nicht überprüfbar".

---

### WP-L8: Klassen-Capability-Modell

#### Grund
v2.0 hatte widersprüchliche Regeln: Instanzen erbten Capabilities der erzeugenden Methode (macht Methoden-Capabilities überflüssig). Das neue Modell ist konsistent: Capabilities werden am Klassen-Typ deklariert, alle Instanzen desselben Typs haben dieselbe Capability-Menge.

#### Inhalt
- Klassen-Level-`@capabilities`-Annotation implementieren
- Alle Instanzmethoden erben implizit die Klassen-Capabilities
- Methoden können via eigenes `@capabilities` zusätzliche Capabilities hinzufügen (Vereinigung)
- Methoden können die Klassen-Capabilities **nicht** einschränken (wäre ein Typ-Bruch)
- Statische Methoden haben keine Klassen-Capabilities
- Typ-Check: `FileWriter`-Instanz hat immer `fs.write(path: "/var/log")`, egal wie erzeugt

#### Abnahmekriterien
1. Klassen-Capability deklariert `fs.write(path: "/var/log")`: alle Instanzmethoden dürfen `openat(O_WRONLY)`.
2. Methode deklariert `network.tcp.connect` zusätzlich: Vereinigung ist korrekt.
3. Methode versucht Klassen-Capability zu verringern → Compiler-Fehler.
4. Statische Methode mit `fs.write`-Aufruf ohne eigene Deklaration → Compiler-Fehler.
5. Zwei Instanzen der gleichen Klasse haben identische Capability-Menge (unabhängig vom Konstruktor-Aufruf).

---

### WP-R9: seccomp-BPF-Codegenerierung

#### Grund
Der Compiler muss aus dem Capability-Manifest ein korrektes BPF-Programm für seccomp generieren, das genau die benötigten Syscalls erlaubt und alle anderen mit `SECCOMP_RET_KILL_PROCESS` beendet. Falsch generiertes BPF könnte Programme bei `exit_group` oder `malloc` crashen.

#### Inhalt
- BPF-Code-Generator in `src/codegen/seccomp_gen.lyx`
- Implizite Capabilities immer einschließen (`exit_group`, `brk`, anonymes `mmap`)
- Für jede explizite Capability: Syscall-Liste aus WP-L2-Registry
- Proxy-Kommunikation: `sendmsg`/`recvmsg` auf `fd_parent` via Argument-Filter (BPF-Vergleich auf fd-Nummer)
- Standard-Aktion: `SECCOMP_RET_KILL_PROCESS`
- BPF-Programm als `.lcbs`-ELF-Sektion speichern
- Startup-Code (`_start`) der das BPF-Programm vor `main()` installiert

#### Abnahmekriterien
1. Programm ohne Capabilities: nur `exit_group`, `brk`, anonymes `mmap` erlaubt; `openat` → SIGSYS (Prozessgruppe stirbt).
2. Programm mit `fs.read`: `openat(O_RDONLY)` erlaubt; `openat(O_WRONLY)` → KILL_PROCESS.
3. Programm mit `network.udp.connect`: `socket(AF_INET, SOCK_DGRAM)` + `sendto` erlaubt; `socket(AF_INET, SOCK_STREAM)` → KILL_PROCESS.
4. Implizite Capabilities sind **immer** im BPF, auch wenn nicht deklariert.
5. Audit zeigt korrekte BPF-Regelanzahl.
6. Ein Programm das `exit(0)` aufruft beendet sich sauber (nicht mit SIGSYS).

---

### WP-R10: Landlock-Integration

#### Grund
seccomp filtert Syscall-Nummern, aber nicht Pfade. Landlock (Linux 5.13+) erlaubt pfadbasierte Zugriffskontrolle im Userspace. Zusammen ermöglichen beide eine vollständige Dateisystem-Isolation.

#### Inhalt
- Landlock-Setup-Code in `src/codegen/landlock_gen.lyx`
- Für jedes `fs.read(path: p)`: `landlock_add_rule(LANDLOCK_ACCESS_FS_READ_FILE, p)`
- Für jedes `fs.write(path: p)`: `LANDLOCK_ACCESS_FS_WRITE_FILE`
- Für jedes `hardware.*`: Entsprechende `/dev/`-Pfade via Landlock freigeben
- Fallback wenn Landlock nicht verfügbar (Kernel < 5.13): Warnung + nur seccomp
- `landlock_restrict_self()` vor `main()`

#### Abnahmekriterien
1. Programm mit `fs.read(path: "/etc")`: `open("/etc/hosts", O_RDONLY)` → OK; `open("/etc/hosts", O_WRONLY)` → EACCES.
2. Programm ohne `fs.*`: `open("/etc/hosts", O_RDONLY)` → EACCES.
3. Programm mit `hardware.gpio(pin: 18)`: `open("/dev/gpiochip0", O_RDWR)` → OK; `open("/dev/sda", O_RDONLY)` → EACCES.
4. Kernel < 5.13: Build gibt Warnung aus; seccomp-Filter bleibt aktiv.
5. Landlock-Regeln erscheinen korrekt im Security-Audit.

---

### WP-R11: Userspace-Netzwerk-Proxy + Lifecycle

#### Grund
v2.0 beschrieb den Proxy konzeptuell, aber ohne Lifecycle-Management, Trust-Boundaries oder Authentifizierungsmechanismus. Ein Proxy ohne diese Details ist nicht implementierbar und hat potenzielle Sandbox-Escape-Vektoren (kompromittierter Proxy = kompromittierte Netzwerk-Capabilities).

#### Inhalt
- Proxy-Prozess-Code in `src/runtime/lcbs_proxy.lyx`
- Startup-Sequenz gemäß Abschnitt 10.2
- `socketpair` + `fork` vor seccomp-Installation
- Proxy liest Manifest via vorher etablierten fd (nicht Netzwerk)
- Proxy installiert eigenen restriktiven seccomp-Filter
- Manifest-Validierung: IP/Port-Check gegen Capability-Liste
- `SCM_RIGHTS` für Socket-Weitergabe
- `@fastpath`-Bypass: kein Proxy, direkter Syscall
- Timeout-Mechanismus: inaktive Verbindungen nach 5s schließen

#### Abnahmekriterien
1. `network.udp(connect: "192.168.1.0/24":5000)`: Verbindung zu `192.168.1.1:5000` → OK.
2. Verbindung zu `10.0.0.1:5000` (nicht im CIDR) → ECONNREFUSED vom Proxy.
3. Verbindung zu `192.168.1.1:8080` (falscher Port) → ECONNREFUSED.
4. Proxy selbst kann keine Dateien öffnen (eigener seccomp-Filter bestätigt via strace).
5. Proxy ist nicht über Netzwerk erreichbar (nur via socketpair-fd).
6. `@fastpath`: kein Proxy-Prozess gestartet; direkter `sendto`-Syscall erlaubt.
7. Proxy-Absturz: Hauptprogramm erhält EPIPE auf fd_parent; fehlerbehandlung sauber.

---

### WP-H12: Hardware-Capabilities + Device Tree

#### Grund
Hardware-Capabilities müssen Landlock-Regeln für `/dev/gpiochipX`, `/dev/i2c-N`, `/dev/spidevN.N` etc. generieren. Optional können Device-Tree-Konflikte (z. B. GPIO-Pin als I2C-SDA belegt) zur Compile-Zeit erkannt werden.

#### Inhalt
- Hardware-Capability-Resolver in `src/security/hw_cap_resolver.lyx`
- GPIO: `/dev/gpiochipX` → Landlock-Regel
- I2C: `/dev/i2c-N` → Landlock-Regel
- SPI: `/dev/spidevN.N` → Landlock-Regel
- USB: `/dev/bus/usb/` → Landlock-Regel
- Optional: DTB-Parser (`--target-dtb <file>.dts`) für Konfliktprüfung
- `initial`-Parameter: Expansion zu ersten Aufruf in `main()`

#### Abnahmekriterien
1. `hardware.gpio(pin: 18)` generiert Landlock-Regel für `/dev/gpiochip0`.
2. `hardware.i2c(bus: 1)` generiert Landlock-Regel für `/dev/i2c-1`.
3. `hardware.gpio(pin: 2)` mit DTB das Pin 2 als I2C-SDA markiert → Compiler-Warnung.
4. `hardware.gpio(pin: 18, initial: low)` expandiert zu `gpio.setPin(18, Low)` als erste Anweisung in `main()`.
5. Zugriff auf `/dev/gpiochip1` ohne `hardware.gpio`-Capability → landlock blockiert.

---

### WP-T13: Security Audit Output + Score

#### Grund
Der Security-Audit-Output macht Capability-Entscheidungen für Entwickler sichtbar und erzeugt einen messbaren Score. Ohne Audit-Output sind Capability-Fehler schwer zu debuggen.

#### Inhalt
- Audit-Generator in `src/tooling/audit.lyx`
- Format gemäß Abschnitt 14
- Score-Berechnung gemäß Score-Tabelle
- Ausgabe vor jedem Build (auch `--check`/`--syntax-only`)
- JSON-Ausgabe optional (`--audit-json`) für CI-Integration
- Differenz-Ausgabe bei Änderungen (`--audit-diff`)

#### Abnahmekriterien
1. Jedes Build gibt Audit-Output auf stderr aus.
2. Score 50/50 für ein Programm ohne Externs, mit W^X, RELRO, PIE, allen Imports mit `grant`, seccomp + landlock.
3. Fehlendes `grant` → Score –2 pro Import.
4. Aktiver `@fastpath` → Score –3.
5. `--audit-json` erzeugt valides JSON mit allen Capability-Feldern.
6. `--audit-diff old_audit.json new_audit.json` zeigt neu hinzugekommene Capabilities.

---

### WP-T14: Migration Tool (`--migrate-capabilities`)

#### Grund
Bestehende Lyx-Programme haben keine `@capabilities`-Annotationen. Ein automatisches Tool, das das minimale Manifest aus einer statischen Analyse generiert, erleichtert die Migration erheblich. Ohne es müssten Entwickler manuell alle Syscall-Pfade im Code verfolgen.

#### Inhalt
- Statische Analyse in `src/tooling/migrate_caps.lyx`
- Durchlauf des AST: alle `extern fn`-Aufrufe → Capability-Mapping (WP-L2)
- `@uses_caller_cap`-Analyse: welche Caller-Capabilities werden benötigt?
- Output: `@capabilities([...])`-Annotation als Lyx-Quellcode
- `--capabilities=compat`-Modus: implizites `@capabilities([*])` ohne Sandboxing
- Warnungen für Capabilities, die nicht automatisch erkennbar sind (z. B. dynamisch konstruierte Pfade)

#### Abnahmekriterien
1. `lyxc --migrate-capabilities prog.lyx` gibt minimales `@capabilities`-Manifest aus.
2. Ein Programm das nur `fopen("/etc/x", "r")` aufruft: Output enthält `fs.read(path: "/etc/x")`.
3. Ein Programm das `socket(AF_INET, ...)` aufruft: Output enthält `network.tcp.connect` oder `network.udp.connect` (mit Hinweis zur manuellen Adress-Angabe).
4. `--capabilities=compat`: Binary kompiliert, Warnung für jede genutzte Ressource, kein seccomp/landlock.
5. Dynamisch konstruierte Pfade (`path = getenv("LOG_PATH")`) → Warnung „Pfad kann nicht statisch analysiert werden; manuell ergänzen".

---

### WP-T15: LCBS-Selbsttest

#### Grund
Ein Bug im `ffi_parser.lyx` könnte das gesamte Capability-System unwirksam machen. Der Selbsttest lässt den Compiler sich selbst mit LCBS kompilieren – dabei werden die Capabilities des Compilers strikt auf das Minimum reduziert und geprüft.

#### Inhalt
- Capability-Manifest für den Compiler selbst: `fs.read`, `fs.write`, `process.exec` (für Assembler/Linker), kein Netzwerk
- Compiler kompiliert sich selbst mit diesem Manifest
- Generierter seccomp-BPF-Filter wird gegen erwartete Syscall-Liste verglichen
- Integrations-Test: kompilierter Compiler kompiliert ein einfaches Testprogramm; prüft ob das Testprogramm die erwarteten Capabilities hat

#### Abnahmekriterien
1. `lyxc --self-test` kompiliert den Compiler mit LCBS und beendet sich ohne Fehler.
2. Der selbst-kompilierte Compiler hat keinen Zugriff auf Netzwerk-Syscalls (strace bestätigt).
3. Versuch den Compiler mit einem manipulierten `ffi_parser.lyx` zu compilieren, der `system()` erlaubt, wird vom eigenen LCBS abgefangen.
4. Integrations-Test: Testprogramm mit `fs.read` hat genau `openat(O_RDONLY)` im BPF; kein `openat(O_WRONLY)`.

---

## 19. Migration bestehender Programme

```bash
# Kompatibilitätsmodus: kein Sandboxing, Warnungen für jede Ressource
lyxc --capabilities=compat program.lyx

# Automatisches Manifest generieren
lyxc --migrate-capabilities program.lyx > capabilities.lyx
# → Ergebnis prüfen, anpassen, in program.lyx einfügen

# Schritt-für-Schritt: erst analysieren, dann strikt compilieren
lyxc --audit-json program.lyx > audit_before.json
# Manifest einfügen
lyxc --audit-json program.lyx > audit_after.json
lyxc --audit-diff audit_before.json audit_after.json
```

---

## Anhang A: Gegenüberstellung v2.0 vs. v3.0

| Aspekt | v2.0 | v3.0 |
|--------|------|------|
| **Capability-Vererbung** | Ambient Authority (`C(M) = C(P)` als Default) | Grant-basiert (`C(M) = C(M_decl) ∩ C(P)` als Default) |
| **Vergessene Annotation** | Zu viele Rechte (stiller Fehler) | Deklariertes Minimum (Compiler-Warnung) |
| **EBNF** | `[]` für Args, `()` für Constraints; inkonsistent mit Beispielen | `()` für Args überall; `NetworkTarget`-Produktion |
| **Netzwerk-Adresse** | `"192.168.1.0/24":5000` grammatikalisch undefiniert | `IPv4Cidr ":" PortSpec` als EBNF-Produktion |
| **Implizite Capabilities** | Nicht definiert; `malloc` würde mit `memory.mmap` crashen | `system.exit`, `system.memory.heap`, `system.memory.stack` explizit |
| **Proxy-Lifecycle** | Undefiniert (kein Daemon-Start, keine Authentifizierung) | `socketpair` + `fork` vor seccomp; FD-basierte Authentifizierung |
| **W^X / ROP** | „W^X verhindert Capability-Bypass" (overstated) | ROP explizit als bekannte Lücke dokumentiert; RELRO ergänzt |
| **strncpy/strncat** | Klasse 0 (Safe) | Klasse 1 (Warnung + Hinweis auf strlcpy) |
| **system.unsafe.format_string** | In FFI referenziert, nicht in Capability-Tabelle | In Capability-Tabelle (Abschnitt 4.2) |
| **@fastpath** | Erwähnt, nicht in EBNF | In EBNF als Modifier; im Security Score berücksichtigt |
| **Klassen-Capabilities** | Instanz erbt Capabilities der erzeugenden Methode (widersprüchlich) | Capabilities am Klassentyp; alle Instanzen gleich |
| **Capability-Leihe** | „Call-Graph-Analyse wie Rust's Borrow Checker" (unklar) | `@uses_caller_cap` als explizite, implementierbare Annotation |
| **seccomp-Standardaktion** | `SECCOMP_RET_KILL` | `SECCOMP_RET_KILL_PROCESS` (kein SIGSYS-Handler-Bypass) |
| **Security Score** | `unsafe`-Keyword referenziert, nicht definiert | Vollständige Score-Tabelle; `@fastpath`-Malus |
| **Arbeitspakete** | Keine | 15 WPs mit Grund und Abnahmekriterien |

---

*Stand: Juni 2026 – Vollständig überarbeitete Fassung v3.0 auf Basis des Design-Reviews von v2.0*
