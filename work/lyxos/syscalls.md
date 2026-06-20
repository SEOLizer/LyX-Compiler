# Lyx OS – Syscall ABI v1.0

**Ziel-Architektur:** x86-64  
**Ring-Niveau:** Ring-3 → Ring-0 (SYSCALL/SYSRET)  
**lyxc-Target:** `--target=lyxos`  
**ABI-Version:** 1.0 (major=1, minor=0)

---

## 1. Philosophie: Aus Fehlern lernen

Bevor die Tabelle beginnt, eine ehrliche Analyse warum Linux, Windows und macOS
an bestimmten Stellen versagen — und wie Lyx OS es besser macht.

### 1.1 Fehler anderer Systeme

| System | Problem | Lyx-Lösung |
|--------|---------|------------|
| **Linux** | `errno` ist ein globaler Thread-State; negativer Rückgabewert im selben Register wie der Nutzwert | Zwei dedizierte Register: `rax` = Fehlercode, `rdx` = Nutzwert |
| **Linux** | `ioctl` / `fcntl` machen >50 verschiedene Dinge; keine Typsicherheit | Ein Syscall = eine Operation; keine polymorph überlasteten Nummern |
| **Linux** | `open()` ohne Basis-fd → TOCTOU-Lücken (check-then-use races) | Alle Pfad-Syscalls nehmen `dir_fd` als erstes Argument; `AT_CWD` als Default |
| **Linux** | `CLOEXEC` ist opt-in → fd-Leaks über `exec` systemisch | `CLOEXEC` ist **Standard**; Vererbung ist opt-in (`O_INHERIT`) |
| **Linux** | Syscall-Nummern arch-spezifisch (x86 ≠ x86-64 ≠ ARM) | Stabile, arch-unabhängige Nummern; Arch-Mapping liegt im Kernel |
| **Linux** | `fork()` kopiert den gesamten Adressraum, `exec()` wirft ihn sofort weg | Kein `fork()`; nur `sys_spawn()` (analog zu Plan 9 / Windows CreateProcess) |
| **Linux** | Signale unterbrechen Userspace-Code an beliebiger Stelle; `SA_RESTART` nötig | Kein Signal-Mechanismus; stattdessen asynchrone Notification-Queues (`sys_notify_*`) |
| **Linux** | Kernel-Schnittstelle für KI: inexistent; GPU nur über IOCTL-Chaos | KI ist ein Kernel-Primitiv (Gruppe 0x0800–0x09FF); Modelle werden einmal geladen, OS-weit geteilt |
| **Windows** | Win32 → NTDLL → ntoskrnl → HAL: vier Abstraktionsschichten für einen Dateizugriff | Thin ABI: Userspace spricht direkt per SYSCALL mit dem Kernel; kein "ntdll.dll"-Äquivalent nötig |
| **Windows** | Registry: globaler, veränderlicher, binärer State | Kein Kernel-Registry; Konfiguration über normale Dateien |
| **Windows** | Handle-Typen (HANDLE, SOCKET, HKEY, ...) sind konzeptuell getrennt | Alles ist ein `fd`; Capabilities steuern was erlaubt ist |
| **macOS** | Mach-Ports + BSD-Syscalls: zwei parallele IPC-Welten | Ein IPC-Modell: `sys_channel_*` (Mach-inspiriert, aber unified) |
| **alle** | Security als Afterthought; Root/Admin hat Gottrechte | Capabilities + Pledge/Unveil von Anfang an; kein Root-Konzept im Kernel-ABI |
| **alle** | KI: externer Prozess oder HTTP-API; kein Scheduling, kein Sharing | AI-Inference ist ein schedulierter Kernel-Workload; Modell-Weights im Kernel-Shared-Memory |
| **alle** | Parallelismus: explizites Threading; Programmierer verwaltet Cores, Affinität, Locks manuell (pthreads, OpenMP, std::thread) | Automatischer Task-Scheduler: `sys_task_spawn` läuft immer auf dem optimalen Core — ohne Programmiereingriff |

### 1.2 Warum KI als Kernel-Primitiv?

> **Meine Einschätzung:** KI-Syscalls tief im Kernel zu verankern ist für Lyx OS
> nicht nur sinnvoll — es ist architektonisch zwingend, wenn Lyra wirklich
> das OS sein soll und nicht nur eine App, die darauf läuft.

**Konkrete Vorteile:**

1. **Geteilte Modell-Weights** — Ein 7-GB-Modell wird einmal in Kernel-verwaltetem
   Shared Memory geladen. Hundert Prozesse nutzen es gleichzeitig ohne
   Kopie. In jedem anderen Ansatz (User-Daemon) zahlt jeder Prozess die Latenz
   eines IPC-Roundtrips.

2. **Scheduling als First-Class-Citizen** — Der Kernel kann Inferenz als eigenen
   Workload-Typ schedulieren (neben CPU- und I/O-Tasks), Prioritäten vergeben,
   Preemption einbauen und KI-Arbeit in CPU-Idle-Zyklen schieben
   (→ Dreaming-AI, WP17).

3. **Semantisches Paging** — `sys_sem_annotate()` bindet ein Embedding an eine
   Speicherregion. Der VMM kann damit semantisch verwandte Seiten bevorzugt
   im L3-Cache halten oder Swap-Entscheidungen semantisch treffen.
   Das ist unmöglich ohne Kernel-Integration.

4. **Auditierbarkeit** — Alle KI-Prompts laufen durch den Kernel; ein
   `trace_event` wird automatisch für jede Inferenz geschrieben.
   Compliance, Debugging und Lyra-Memory sind direkt verfügbar.

5. **Hardware-Acceleration transparent** — NPU, GPU, oder FPGA-Beschleuniger
   werden wie Block-Devices verwaltet. Der KI-Scheduler wählt die beste
   verfügbare Ressource; Userspace sieht nur `sys_ai_infer()`.

**Risiken und Antworten:**

| Risiko | Antwort |
|--------|---------|
| Modell-Weights (GBs) im Kernel-Heap | KI-Subsystem nutzt eigene Speicher-Arena außerhalb des normalen Bump-Allocators; lazy-load per page-fault |
| Kernel-Crash durch defektes Modell | Modell-Loader läuft in isoliertem Ring-0-Context; bei Fehler → `ERR_BADMODEL`, kein Kernel-Panic |
| Latenz-Einfluss auf normale Syscalls | KI-Syscalls sind asynchron per Design (`sys_ai_infer` non-blocking); sync-Variante nur auf expliziten Wunsch |
| Komplexität | KI-Subsystem ist ein ladbares Kernel-Modul (`kernel/ai.lyx`); bei nicht geladenem Modul → `ERR_NOTSUP` |

### 1.3 Warum automatische Parallelität als Kernel-Prinzip?

> **Design-Entscheidung:** Der Programmierer denkt in Tasks, nicht in Cores.
> Das OS entscheidet — immer, automatisch, ohne explizite Anweisung.

Jedes moderne System hat mehrere Kerne. Trotzdem verlangen alle etablierten
Betriebssysteme dass der Programmierer selbst darüber nachdenkt:
`pthread_create`, `SetThreadAffinityMask`, OpenMP-Pragma, `std::async`.
Vergisst er es, läuft alles auf einem Core.

Lyx OS kehrt das Paradigma um: **Der Kernel ist verantwortlich, nicht der
Programmierer.** Die einzige benötigte API ist `sys_task_spawn` — der Rest
ist Kernel-Entscheidung.

**Konkrete Mechanismen:**

1. **Work-Stealing-Scheduler** — Jeder CPU-Core hat eine eigene Run-Queue.
   Idle-Cores stehlen Tasks von überlasteten Cores automatisch (Chase-Lev-Algorithmus,
   lock-frei via CAS). Kein Programmierer-Eingriff nötig.

2. **Tasks statt Threads** — `sys_task_spawn` erzeugt leichtgewichtige
   Arbeitseinheiten ohne festen Core-Bezug. Millionen Tasks sind möglich;
   der Scheduler packt sie auf die verfügbaren Kerne. Threads existieren
   weiterhin (`sys_thread_spawn`) für Fälle wo Core-Affinität semantisch
   sinnvoll ist (z.B. UI-Thread, Audio-Thread).

3. **lyxc `@parallel`-Annotation** — Der Compiler erkennt unabhängige
   Loop-Iterationen und generiert automatisch `sys_task_spawn`-Calls:
   ```lyx
   @parallel for x in range 0..1000 {
       process(data[x]);   // jede Iteration läuft auf beliebigem Core
   }
   ```
   Ohne `@parallel`: sequentiell. Mit `@parallel`: der Kernel verteilt.
   Der Programmierer muss nur wissen ob Iterationen unabhängig sind —
   welcher Core, wie viele Tasks, wann stehlen: alles Kernel.

4. **AI-Scheduling (Ausbau in WP18)** — Der Scheduler lernt aus
   historischen Zugriffsmustern: Tasks die auf dieselben Speicherseiten
   zugreifen werden bevorzugt auf denselben Core (Cache-Affinität)
   gelegt. Lyra kann proaktiv Tasks migrieren bevor der Cache kalt wird.

5. **Soft Hints, keine Mandate** — `sys_affinity_hint(fd, cpu_mask)` ist
   ein Hinweis, keine Vorschrift. Der Kernel kann ihn ignorieren wenn er
   eine bessere Entscheidung kennt. Kein `pthread_setaffinity`-Äquivalent
   das erzwungen wird.

**Was das für den Programmierer bedeutet:**

```lyx
// So sieht paralleles Rechnen in Lyx OS aus:
var tasks: int64 := sys_task_group_create(0);
for i in range 0..8 {
    sys_task_group_add(tasks, worker_fn, &args[i], 8);
}
sys_task_group_await(tasks, -1);   // warte auf alle
// Fertig. Kein Thread-Pool, kein Mutex für die Distribution,
// kein Nachdenken über Core-Anzahl.
```

**Abgrenzung zu bestehenden Ansätlen:**

| System | Ansatz | Problem |
|--------|--------|---------|
| POSIX pthreads | 1 Thread = 1 Core-Slot, manuell | Programmierer muss alles selbst machen |
| OpenMP | Pragma-basiert, Compiler-Erweiterung | Nicht OS-integriert; kein adaptives Scheduling |
| Go goroutines | Runtime-Scheduler (M:N) | Gut, aber nur für Go; kein OS-weites Prinzip |
| Erlang/BEAM | Leichtgewichtige Prozesse | Nur eine Sprache; kein allgemeiner OS-Kernel |
| **Lyx OS** | Kernel-nativer Task-Scheduler + lyxc `@parallel` | OS-weit, jede Sprache, AI-gestützt |

---

## 2. Aufrufkonvention (Calling Convention)

### 2.1 Mechanismus: SYSCALL/SYSRET

Lyx OS nutzt ausschließlich den `SYSCALL`/`SYSRET`-Pfad (AMD64 Fast Syscall).

```
SYSCALL speichert:  RIP  → RCX   (Rücksprungadresse)
                    RFLAGS → R11 (gespeicherte Flags)
                    CS/SS aus STAR-MSR
SYSCALL springt zu: LSTAR-MSR (= sys_entry in boot.asm)
```

Da `RCX` und `R11` vom Mechanismus clobbert werden, sind sie **nicht** als
Eingabe-Argumente nutzbar.

### 2.2 Register-Layout

```
Eingabe:
  rax  = Syscall-Nummer (0x0000 – 0x0AFF)
  rdi  = Argument 1
  rsi  = Argument 2
  rdx  = Argument 3
  r10  = Argument 4  (statt rcx, das SYSCALL clobbered)
  r8   = Argument 5
  r9   = Argument 6

Ausgabe:
  rax  = Fehlercode  (0 = Erfolg; >0 = ERR_* Konstante)
  rdx  = Rückgabewert (fd, Adresse, Byte-Anzahl, PID, ...)

Vom Kernel NICHT verändert (callee-saved per System V AMD64 ABI):
  rbx, rbp, r12, r13, r14, r15

Vom Kernel CLOBBERT (nach dem syscall-Rücksprung nicht verlassen):
  rcx, r11  (SYSCALL-Mechanismus)
  rdi, rsi, r10, r8, r9  (dürfen modifiziert werden)
```

### 2.3 Assembler-Beispiel

```nasm
; sys_write(FD_STDOUT, buf, len)  →  bytes_written in rdx, Fehler in rax
mov  rax, 0x0203        ; sys_write
mov  rdi, 1             ; arg1: fd = FD_STDOUT
mov  rsi, buf           ; arg2: Puffer
mov  rdx, len           ; arg3: Länge
syscall
test rax, rax
jnz  .error             ; rax ≠ 0 → ERR_* Fehler
; rdx = Anzahl tatsächlich geschriebener Bytes
```

### 2.4 lyxc-Codeerzeugung (--target=lyxos)

Der lyxc-Compiler erzeugt für `--target=lyxos` SYSCALL-basierte Stubs.
Builtins werden auf Lyx-Syscalls gemappt:

| lyxc-Builtin | Lyx-Syscall |
|-------------|-------------|
| `PrintLn(s)` | `sys_write(FD_STDOUT, ...)` |
| `EPrintLn(s)` | `sys_write(FD_STDERR, ...)` |
| `mmap(...)` | `sys_mmap(...)` |
| `munmap(...)` | `sys_munmap(...)` |
| `open(path, ...)` | `sys_open(AT_CWD, path, ...)` |
| `read(fd, ...)` | `sys_read(fd, ...)` |
| `write(fd, ...)` | `sys_write(fd, ...)` |
| `close(fd)` | `sys_close(fd)` |
| `ThreadSelf()` | `sys_gettid()` |
| `Random()` | `sys_getrandom(buf, 8, 0)` |
| `sys_socket(...)` | `sys_socket(...)` |

Die Runtime-Library (`lyxrt_lyxos.lyx`) wird automatisch gelinkt.
Es gibt keine Abhängigkeit von libc.

---

## 3. Rückgabekonvention & Fehlercodes

### 3.1 Zwei-Register-Rückgabe

```
rax = 0          → Erfolg; Nutzwert steht in rdx
rax = ERR_*      → Fehler; rdx ist undefiniert
```

**Vorteil gegenüber Linux:** Kein Vorzeichentest auf einem einzigen Register.
Kein globales `errno`. lyxc kann direkt `var val, err := syscall(...)` generieren.

Syscalls die keinen Nutzwert haben (z.B. `sys_close`, `sys_yield`):
`rdx` ist nach Erfolg 0; bei Fehler steht der Code in `rax`.

Syscalls die nie zurückkehren (`sys_exit`, `sys_exit_group`):
kein Rückgabewert.

### 3.2 Fehlercodes

```lyx
con ERR_OK          : int64 := 0   // Erfolg
con ERR_PERM        : int64 := 1   // Zugriff verweigert
con ERR_NOENT       : int64 := 2   // Datei / Ressource nicht gefunden
con ERR_BUSY        : int64 := 3   // Ressource belegt
con ERR_IO          : int64 := 4   // I/O-Fehler
con ERR_NOMEM       : int64 := 5   // Kein Speicher
con ERR_AGAIN       : int64 := 6   // Nochmal versuchen (würde blockieren)
con ERR_INVAL       : int64 := 7   // Ungültiges Argument
con ERR_OVERFLOW    : int64 := 8   // Puffer- / Wert-Überlauf
con ERR_TIMEOUT     : int64 := 9   // Zeitüberschreitung
con ERR_EXIST       : int64 := 10  // Existiert bereits
con ERR_NOTDIR      : int64 := 11  // Kein Verzeichnis
con ERR_ISDIR       : int64 := 12  // Ist ein Verzeichnis
con ERR_NOTEMPTY    : int64 := 13  // Verzeichnis nicht leer
con ERR_BADFD       : int64 := 14  // Ungültiger File-Deskriptor
con ERR_NOSYS       : int64 := 15  // Syscall nicht implementiert
con ERR_NOTSUP      : int64 := 16  // Operation nicht unterstützt
con ERR_RANGE       : int64 := 17  // Wert außerhalb des gültigen Bereichs
con ERR_FAULT       : int64 := 18  // Ungültige Speicheradresse
con ERR_LOOP        : int64 := 19  // Symbolischer-Link-Schleife
con ERR_NAMETOOLONG : int64 := 20  // Pfad-Komponente zu lang
con ERR_NOTCONN     : int64 := 21  // Socket nicht verbunden
con ERR_CONNREFUSED : int64 := 22  // Verbindung abgelehnt
con ERR_ADDRUSE     : int64 := 23  // Adresse bereits in Benutzung
con ERR_BROKEN      : int64 := 24  // Verbindung / Pipe getrennt
con ERR_CANCELED    : int64 := 25  // Operation abgebrochen
con ERR_DEADLOCK    : int64 := 26  // Würde Deadlock verursachen
con ERR_TOOBIG      : int64 := 27  // Argument / Daten zu groß
con ERR_NODEV       : int64 := 28  // Kein solches Gerät
con ERR_CAPVIOL     : int64 := 29  // Capability-Verletzung
con ERR_AIBUSY      : int64 := 30  // KI-Inferenz-Engine ausgelastet
con ERR_BADMODEL    : int64 := 31  // Ungültiges oder nicht unterstütztes KI-Modell
con ERR_CTXFULL     : int64 := 32  // KI-Kontextfenster voll
con ERR_NO_DISPLAY  : int64 := 33  // Kein Anzeigegerät vorhanden
con ERR_BAD_FORMAT  : int64 := 34  // Pixel-Format nicht unterstützt
con ERR_GPU_FAULT   : int64 := 35  // GPU-Fehler / Command-Buffer ungültig
```

---

## 4. File-Deskriptoren & Capabilities

### 4.1 Standard-FDs

```lyx
con FD_STDIN  : int64 := 0
con FD_STDOUT : int64 := 1
con FD_STDERR : int64 := 2
```

### 4.2 Spezielle dir_fd-Werte für Pfad-Syscalls

```lyx
con AT_CWD  : int64 := -1   // Aktuelles Arbeitsverzeichnis
con AT_ROOT : int64 := -2   // Dateisystem-Wurzel
```

### 4.3 Capabilities

Jeder fd ist eine **Capability**: er kodiert sowohl die Ressource als auch
die erlaubten Operationen. Capabilities können nur eingeschränkt (nie
erweitert) werden (`sys_cap_restrict`). Das verhindert Privilege-Escalation
durch fd-Weitergabe.

```lyx
con RIGHT_READ    : int64 := 1
con RIGHT_WRITE   : int64 := 2
con RIGHT_EXEC    : int64 := 4
con RIGHT_MMAP    : int64 := 8
con RIGHT_SEEK    : int64 := 16
con RIGHT_STAT    : int64 := 32
con RIGHT_DELETE  : int64 := 64
con RIGHT_CONTROL : int64 := 128   // ioctl, setsockopt
con RIGHT_ALL     : int64 := 0x7FFFFFFFFFFFFFFF
```

---

## 5. Syscall-Tabelle

### Kategorie 0x0000 – Prozess & Threads

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0000 | `sys_version` | — | `(major<<32)|minor` | Liefert die ABI-Version. Userspace ruft dies beim Start auf um sicherzustellen, dass der Kernel kompatibel ist. |
| 0x0001 | `sys_exit` | `code: int64` | — | Beendet den aktuellen Thread. Ist er der letzte Thread der Prozessgruppe, wird der Prozess terminiert. `code` ist der Exit-Status. Kehrt nie zurück. |
| 0x0002 | `sys_exit_group` | `code: int64` | — | Beendet alle Threads der aktuellen Prozessgruppe. Wie POSIX `exit()`. Kehrt nie zurück. |
| 0x0003 | `sys_spawn` | `dir_fd: fd`, `path: pchar`, `argv: pchar*`, `envp: pchar*`, `opts: SpawnOpts*` | neuer Prozess-fd | Erzeugt einen neuen Prozess aus dem ELF-Binary unter `path` (relativ zu `dir_fd`). Kein `fork()`-Äquivalent. `opts` steuert stdio-Umleitung, Namespaces und Stack-Größe. Rückgabe: Prozess-Handle-fd für `sys_wait`. |
| 0x0004 | `sys_thread_spawn` | `entry: fn*`, `stack: ptr`, `stack_size: int64`, `arg: ptr` | Thread-fd | Erzeugt einen neuen Kernel-Thread im aktuellen Adressraum. Startet bei `entry(arg)`. Teilt Adressraum und fds mit dem Elternprozess. |
| 0x0005 | `sys_thread_exit` | `code: int64` | — | Beendet den aktuellen Thread ohne den Prozess zu terminieren. Kehrt nie zurück. |
| 0x0006 | `sys_wait` | `proc_fd: fd`, `status_out: int64*`, `timeout_ns: int64` | — | Wartet auf Terminierung eines Prozesses oder Threads. `-1` als `timeout_ns` = unendlich. Bei Timeout: `ERR_TIMEOUT`. Exit-Status wird in `*status_out` geschrieben. |
| 0x0007 | `sys_getpid` | — | aktuelle PID | Liefert die Prozess-ID des aufrufenden Prozesses. |
| 0x0008 | `sys_gettid` | — | aktuelle TID | Liefert die Thread-ID des aufrufenden Threads. |
| 0x0009 | `sys_yield` | — | — | Gibt die CPU freiwillig an den Scheduler zurück. Kein Fehlerfall. |
| 0x000A | `sys_sleep_ns` | `nanoseconds: int64` | — | Schläft für mindestens `nanoseconds` Nanosekunden. Kann durch `sys_notify_post` auf dem Thread frühzeitig unterbrochen werden. |
| 0x000B | `sys_priority` | `fd: fd`, `priority: int64` | — | Setzt die Scheduling-Priorität des Prozesses oder Threads hinter `fd`. `0` = normal, `< 0` = höher (benötigt Capability), `> 0` = niedriger. |
| 0x000C | `sys_getrandom` | `buf: ptr`, `len: int64`, `flags: int64` | Bytes geschrieben | Füllt `buf` mit kryptographisch sicherem Zufall aus dem Kernel-CSPRNG. `flags = 0` = blockierend bis Entropie vorhanden. `GRND_NONBLOCK = 1` = `ERR_AGAIN` wenn nicht genug Entropie. |
| 0x000D | `sys_signal_mask` | `notify_fd: fd`, `mask: int64` | vorherige Maske | Maskiert asynchrone Benachrichtigungen. Bits entsprechen `NOTIFY_*`-Typen. Maskierte Notifications werden gepuffert bis demaskiert. |

---

### Kategorie 0x0100 – Speicher

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0100 | `sys_mmap` | `hint: ptr`, `size: int64`, `prot: int64`, `flags: int64` | gemappte Adresse | Bildet Speicher ab. `hint = 0` = Kernel wählt Adresse. `prot`: `PROT_*`. `flags`: `MAP_*`. Anonymes Mapping bei `MAP_ANONYMOUS`. Alignment: mindestens 4096 Bytes. |
| 0x0101 | `sys_munmap` | `addr: ptr`, `size: int64` | — | Gibt ein Speicher-Mapping frei. `addr` muss Page-aligned sein. |
| 0x0102 | `sys_mprotect` | `addr: ptr`, `size: int64`, `prot: int64` | — | Ändert Schutzflags einer Speicherregion. `PROT_EXEC` auf Data-Seiten benötigt `RIGHT_EXEC`-Capability. |
| 0x0103 | `sys_madvise` | `addr: ptr`, `size: int64`, `advice: int64` | — | Gibt Hinweise für das VMM-Subsystem. `MADV_SEQUENTIAL`, `MADV_RANDOM`, `MADV_WILLNEED`, `MADV_DONTNEED`. Nicht-bindend; Kernel kann ignorieren. |
| 0x0104 | `sys_shm_create` | `size: int64`, `flags: int64` | shm-fd | Erzeugt ein Shared-Memory-Objekt der Größe `size` (wird auf nächste Page aufgerundet). Das Objekt existiert bis alle fds geschlossen sind. `SHM_EXEC = 1` erlaubt ausführbares Mapping. |
| 0x0105 | `sys_shm_map` | `shm_fd: fd`, `offset: int64`, `size: int64`, `prot: int64` | gemappte Adresse | Mappt ein Shared-Memory-Objekt in den Adressraum. `offset` muss Page-aligned sein. Mehrere Prozesse können denselben shm_fd mappen; Änderungen sind sofort sichtbar. |

**PROT-Flags:**

```lyx
con PROT_NONE  : int64 := 0
con PROT_READ  : int64 := 1
con PROT_WRITE : int64 := 2
con PROT_EXEC  : int64 := 4
```

**MAP-Flags:**

```lyx
con MAP_PRIVATE   : int64 := 1
con MAP_SHARED    : int64 := 2
con MAP_ANONYMOUS : int64 := 4
con MAP_FIXED     : int64 := 8
con MAP_POPULATE  : int64 := 16   // Seiten sofort einpagen (kein lazy fault)
```

---

### Kategorie 0x0200 – Dateisystem & VFS

**Design-Entscheidung:** Alle Pfad-Syscalls nehmen `dir_fd` als erstes Argument.
`AT_CWD (-1)` für relative Pfade. Kein nachträgliches `*at`-Suffix nötig —
das ist von Anfang an die einzige API. Damit entfallen die TOCTOU-Lücken von
`open()`, `stat()` etc.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0200 | `sys_open` | `dir_fd: fd`, `path: pchar`, `flags: int64`, `mode: int64` | neuer fd | Öffnet oder erzeugt eine Datei relativ zu `dir_fd`. `mode` ist die Zugriffsmaske bei Neuanlage (wird mit `umask` verknüpft). `CLOEXEC` ist implizit gesetzt; `O_INHERIT` deaktiviert es. |
| 0x0201 | `sys_close` | `fd: fd` | — | Schließt einen fd. Löst ausstehende Locks und Notifications aus. `ERR_BADFD` wenn fd ungültig. |
| 0x0202 | `sys_read` | `fd: fd`, `buf: ptr`, `count: int64` | gelesene Bytes | Liest bis zu `count` Bytes. `0` = EOF. `ERR_AGAIN` wenn nonblocking und keine Daten. |
| 0x0203 | `sys_write` | `fd: fd`, `buf: ptr`, `count: int64` | geschriebene Bytes | Schreibt bis zu `count` Bytes. Bei Pipes/Sockets: atomic wenn `count ≤ PIPE_BUF (4096)`. |
| 0x0204 | `sys_seek` | `fd: fd`, `offset: int64`, `whence: int64` | neue Position | Setzt den Datei-Cursor. `SEEK_SET=0`, `SEEK_CUR=1`, `SEEK_END=2`. `ERR_NOTSUP` für Pipes und Sockets. |
| 0x0205 | `sys_stat` | `dir_fd: fd`, `path: pchar`, `stat_out: Stat*`, `flags: int64` | — | Liest Datei-Metadaten. `STAT_NOFOLLOW=1` → kein Symlink-Auflösen (wie `lstat`). `STAT_EMPTY_PATH=2` → stat des fd selbst (path=""). |
| 0x0206 | `sys_fstat` | `fd: fd`, `stat_out: Stat*` | — | `sys_stat` auf einem bereits offenen fd. |
| 0x0207 | `sys_mkdir` | `dir_fd: fd`, `path: pchar`, `mode: int64` | — | Erzeugt ein Verzeichnis. `ERR_EXIST` wenn bereits vorhanden. Intermediäre Verzeichnisse werden nicht automatisch erzeugt. |
| 0x0208 | `sys_unlink` | `dir_fd: fd`, `path: pchar`, `flags: int64` | — | Löscht einen Datei-Eintrag. `UNLINK_DIR=1` entfernt leere Verzeichnisse (entspricht `rmdir`). |
| 0x0209 | `sys_rename` | `old_dir: fd`, `old_path: pchar`, `new_dir: fd`, `new_path: pchar` | — | Atomares Umbenennen/Verschieben. Cross-Device-Rename: `ERR_NOTSUP`. |
| 0x020A | `sys_readdir` | `fd: fd`, `buf: ptr`, `buf_size: int64` | geschriebene Bytes | Liest Verzeichniseinträge in `buf` als Array von `DirEntry`. `0` = Ende. `fd` muss mit `O_DIRECTORY` geöffnet sein. |
| 0x020B | `sys_dup` | `fd: fd`, `flags: int64` | neuer fd | Dupliziert `fd`. `DUP_CLOEXEC=1` (Standard). Der neue fd referenziert dieselbe Ressource und dieselben Capabilities. |
| 0x020C | `sys_pipe` | `read_fd_out: fd*`, `write_fd_out: fd*`, `flags: int64` | — | Erzeugt ein unidirektionales Byte-Pipe-Paar. `PIPE_NONBLOCK=1` für non-blocking. Puffer-Kapazität: 65536 Bytes. |
| 0x020D | `sys_truncate` | `fd: fd`, `size: int64` | — | Setzt die Dateigröße auf `size`. Verlängerung füllt mit Nullbytes. `fd` muss Schreibrecht haben. |
| 0x020E | `sys_sync` | `fd: fd` | — | Schreibt alle Puffer für `fd` auf den Datenträger. `fd = -1` → globales Sync aller Dateisysteme (erfordert Admin-Capability). |
| 0x020F | `sys_mount` | `dev_fd: fd`, `mnt_dir: fd`, `mnt_path: pchar`, `fs_type: pchar`, `flags: int64` | — | Hängt ein Dateisystem ein. `fs_type`: `"fat32"`, `"ext2"`, `"tmpfs"`, `"devfs"`. Erfordert `CAP_MOUNT`-Capability. |
| 0x0210 | `sys_umount` | `dir_fd: fd`, `path: pchar`, `flags: int64` | — | Hängt ein Dateisystem aus. `UMOUNT_FORCE=1` erzwingt auch bei offenen fds. |
| 0x0211 | `sys_getcwd` | `buf: pchar`, `size: int64` | geschriebene Bytes | Schreibt den absoluten Pfad des aktuellen Verzeichnisses in `buf`. |
| 0x0212 | `sys_chdir` | `dir_fd: fd`, `path: pchar` | — | Ändert das aktuelle Arbeitsverzeichnis. `path = ""` + `STAT_EMPTY_PATH` → wechselt zu `dir_fd` direkt. |
| 0x0213 | `sys_symlink` | `target: pchar`, `dir_fd: fd`, `link_path: pchar` | — | Erzeugt einen symbolischen Link. `target` ist ein beliebiger Pfad-String; er wird nicht validiert. |
| 0x0214 | `sys_readlink` | `dir_fd: fd`, `path: pchar`, `buf: pchar`, `size: int64` | Bytes geschrieben | Liest das Ziel eines symbolischen Links. Kein Null-Terminator wird angefügt; Länge steht in `rdx`. |
| 0x0215 | `sys_content_id` | `fd: fd`, `algo: int64`, `out: ptr`, `out_len: int64` | Hash-Bytes | Berechnet den kryptografischen Content-Hash einer Datei. `algo`: `CID_BLAKE3=0` (Standard, 32 Bytes), `CID_SHA256=1` (32 Bytes). Ermöglicht inhaltsbasierte Adressierung unabhängig vom Pfad. Kernel cached den Hash bis zur nächsten Schreiboperation. |

**O_*-Flags:**

```lyx
con O_READ      : int64 := 1
con O_WRITE     : int64 := 2
con O_RDWR      : int64 := 3
con O_CREAT     : int64 := 4
con O_EXCL      : int64 := 8
con O_TRUNC     : int64 := 16
con O_APPEND    : int64 := 32
con O_NONBLOCK  : int64 := 64
con O_INHERIT   : int64 := 128   // fd über sys_spawn vererben (CLOEXEC ist Default)
con O_DIRECTORY : int64 := 256   // Fehler wenn kein Verzeichnis
con O_TMPFILE   : int64 := 512   // Anonyme temporäre Datei (kein Name)
con O_SEMANTIC  : int64 := 1024  // Beim Close: async Embedding + Graph-Node-Eintrag (WP18)
```

---

### Kategorie 0x0300 – I/O & Geräte

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0300 | `sys_poll` | `events: PollEvent*`, `count: int64`, `timeout_ns: int64` | bereite fds | Wartet auf Ereignisse auf mehreren fds gleichzeitig. `timeout_ns = -1` → blockiert unbegrenzt. `0` → nicht-blockierend. Funktioniert auch auf KI-Inferenz-fds (Completion-Notification). |
| 0x0301 | `sys_ioctl` | `fd: fd`, `request: int64`, `arg: ptr` | gerätespezifisch | Gerätespezifische Steuerbefehle. Streng typisiert: jede Geräte-Klasse hat eine eigene Request-Tabelle. Kein polymorpher Wildwuchs wie in Linux. |
| 0x0302 | `sys_mmap_device` | `fd: fd`, `offset: int64`, `size: int64`, `prot: int64` | gemappte Adresse | Mappt MMIO-Register eines Gerätes in den Adressraum. `fd` muss eine Gerätedatei sein (`devfs`). Nur mit `RIGHT_MMAP`-Capability. |
| 0x0303 | `sys_irq_bind` | `irq: int64`, `notify_fd: fd` | — | Bindet eine IRQ-Nummer an einen Notification-fd. Wenn der IRQ feuert, schreibt der Kernel eine `NOTIFY_IRQ`-Notification. Gerätetreiber im Userspace können so ohne Kernel-Modul reagieren. |
| 0x0304 | `sys_port_in` | `port: int64`, `width: int64` | gelesener Wert | Führt einen x86 `IN`-Befehl aus. `width`: 1, 2 oder 4 Bytes. Erfordert `CAP_IOPORT`. |
| 0x0305 | `sys_port_out` | `port: int64`, `width: int64`, `value: int64` | — | Führt einen x86 `OUT`-Befehl aus. `width`: 1, 2 oder 4 Bytes. Erfordert `CAP_IOPORT`. |

**POLL-Event-Flags:**

```lyx
con POLL_IN    : int64 := 1    // Daten zum Lesen vorhanden
con POLL_OUT   : int64 := 2    // Bereit zum Schreiben
con POLL_ERR   : int64 := 4    // Fehlerzustand
con POLL_HUP   : int64 := 8    // Verbindung getrennt
con POLL_RDHUP : int64 := 16   // Gegenseite hat Schreibende geschlossen
```

---

### Kategorie 0x0400 – IPC & Synchronisation

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0400 | `sys_mutex_create` | `flags: int64` | Mutex-fd | Erzeugt einen Kernel-Mutex. `MUTEX_PLAIN=0`, `MUTEX_RECURSIVE=1`, `MUTEX_ROBUST=2` (Eigentümer-Tod → automatisch freigelassen, `ERR_DEADLOCK` beim nächsten Lock). |
| 0x0401 | `sys_mutex_lock` | `fd: fd`, `timeout_ns: int64` | — | Sperrt einen Mutex. Blockiert bis zu `timeout_ns` Nanosekunden. `-1` = unbegrenzt. `ERR_DEADLOCK` bei ROBUST-Mutex nach Eigentümer-Tod. |
| 0x0402 | `sys_mutex_unlock` | `fd: fd` | — | Entsperrt einen Mutex. `ERR_PERM` wenn der aufrufende Thread nicht der Eigentümer ist. |
| 0x0403 | `sys_sem_create` | `initial: int64`, `flags: int64` | Semaphor-fd | Erzeugt einen Zählsemaphor mit Initialwert `initial`. `SEM_NAMED=1` für prozessübergreifende Nutzung via fd-Weitergabe. |
| 0x0404 | `sys_sem_wait` | `fd: fd`, `timeout_ns: int64` | — | Dekrementiert den Semaphor. Blockiert wenn Wert = 0. |
| 0x0405 | `sys_sem_post` | `fd: fd` | — | Inkrementiert den Semaphor. Weckt wartende Threads auf. |
| 0x0406 | `sys_channel_create` | `flags: int64` | `(send_fd<<32)|recv_fd` | Erzeugt ein bidirektionales Nachrichten-Kanal-Paar. Inspiriert von Mach-Ports. Nachrichten sind typed (Größe + Metadaten). fds können an Nachrichten angehängt werden (fd-Passing). |
| 0x0407 | `sys_channel_send` | `fd: fd`, `msg: ptr`, `size: int64`, `fds: fd*`, `fd_count: int64` | — | Sendet eine Nachricht auf einem Channel. Atomare Operation. `ERR_TOOBIG` wenn `size > CHAN_MSG_MAX (65536)`. |
| 0x0408 | `sys_channel_recv` | `fd: fd`, `msg: ptr`, `size: int64`, `fds: fd*`, `fd_count_inout: int64*` | Nachrichtengröße | Empfängt eine Nachricht. Blockiert wenn keine Nachricht vorhanden. Angehängte fds werden in das `fds`-Array geschrieben; `*fd_count_inout` enthält die tatsächliche Anzahl. |
| 0x0409 | `sys_notify_create` | `flags: int64` | Notify-fd | Erzeugt eine asynchrone Notification-Queue. Ersetzt Unix-Signale. Notifications werden gepuffert; keine verlorenen Events. |
| 0x040A | `sys_notify_wait` | `fd: fd`, `events: Notification*`, `count: int64`, `timeout_ns: int64` | empfangene Events | Liest bis zu `count` ausstehende Notifications. Blockiert wenn Queue leer. |
| 0x040B | `sys_notify_post` | `fd: fd`, `type: int64`, `data: int64` | — | Schreibt eine Notification in eine Queue. Kann aus Kernel-Interrupt-Kontext gerufen werden (z.B. `sys_irq_bind`). |
| 0x040C | `sys_futex` | `addr: int64*`, `op: int64`, `val: int64`, `timeout_ns: int64`, `addr2: int64*`, `val3: int64` | — | Fast Userspace Mutex (für libc/Laufzeit-Implementierungen). Bleibt aus Kompatibilitätsgründen. Userspace-Code bevorzugt `sys_mutex_*`. |

---

### Kategorie 0x0500 – Zeit

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0500 | `sys_clock_get` | `clock_id: int64`, `ts_out: TimeSpec*` | Nanosekunden seit Epoche | Liest eine Systemuhr. Schneller Pfad: vDSO-Mapping geplant (kein Syscall-Overhead für Hotpaths). |
| 0x0501 | `sys_clock_set` | `clock_id: int64`, `ts: TimeSpec*` | — | Setzt eine Systemuhr (erfordert Admin-Capability). Nur `CLOCK_REAL` ist setzbar. |
| 0x0502 | `sys_timer_create` | `clock_id: int64`, `notify_fd: fd`, `flags: int64` | Timer-fd | Erzeugt einen periodischen oder einmaligen Timer. Ablauf schreibt `NOTIFY_TIMER` in `notify_fd`. |
| 0x0503 | `sys_timer_set` | `fd: fd`, `interval_ns: int64`, `initial_ns: int64` | — | Aktiviert oder deaktiviert (`0/0` = disarm) einen Timer. `interval_ns = 0` → einmaliger Timer. |
| 0x0504 | `sys_timer_wait` | `fd: fd`, `timeout_ns: int64` | abgelaufene Ticks | Blockiert bis zum nächsten Timer-Ablauf. Gibt die Anzahl verpasster Ticks zurück (nützlich für overrun-Detection). |

**Clock-IDs:**

```lyx
con CLOCK_REAL   : int64 := 0   // Wanduhr (UTC, kann springen)
con CLOCK_MONO   : int64 := 1   // Monoton seit Boot (kein Sprung)
con CLOCK_CPU    : int64 := 2   // CPU-Zeit des aktuellen Prozesses
con CLOCK_THREAD : int64 := 3   // CPU-Zeit des aktuellen Threads
```

---

### Kategorie 0x0600 – Netzwerk

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0600 | `sys_socket` | `domain: int64`, `type: int64`, `proto: int64` | Socket-fd | Erzeugt einen Socket. `domain`: `AF_INET=2`, `AF_INET6=10`, `AF_UNIX=1`. `type`: `SOCK_STREAM=1`, `SOCK_DGRAM=2`. |
| 0x0601 | `sys_bind` | `fd: fd`, `addr: ptr`, `addr_len: int64` | — | Bindet einen Socket an eine lokale Adresse. |
| 0x0602 | `sys_listen` | `fd: fd`, `backlog: int64` | — | Versetzt einen TCP-Socket in den Wartezustand. `backlog`: Länge der Verbindungswarteschlange. |
| 0x0603 | `sys_accept` | `fd: fd`, `addr_out: ptr`, `addr_len_inout: int64*` | Client-fd | Akzeptiert eine eingehende Verbindung. Blockiert wenn keine Verbindung vorhanden. Neuer fd hat `CLOEXEC`. |
| 0x0604 | `sys_connect` | `fd: fd`, `addr: ptr`, `addr_len: int64` | — | Stellt eine Verbindung her. Blockiert bei TCP bis SYN-ACK. `ERR_AGAIN` bei `O_NONBLOCK` während Verbindungsaufbau. |
| 0x0605 | `sys_sendmsg` | `fd: fd`, `msg: MsgHdr*`, `flags: int64` | gesendete Bytes | Sendet Daten (ggf. mit Scatter/Gather und ancillary data). |
| 0x0606 | `sys_recvmsg` | `fd: fd`, `msg: MsgHdr*`, `flags: int64` | empfangene Bytes | Empfängt Daten. `MSG_PEEK=1` lässt Daten im Puffer. `MSG_WAITALL=2` blockiert bis Puffer voll. |
| 0x0607 | `sys_setsockopt` | `fd: fd`, `level: int64`, `opt: int64`, `val: ptr`, `val_len: int64` | — | Setzt Socket-Option. Standard-POSIX-Optionen werden unterstützt. |
| 0x0608 | `sys_getsockopt` | `fd: fd`, `level: int64`, `opt: int64`, `val_out: ptr`, `val_len_inout: int64*` | — | Liest Socket-Option. |
| 0x0609 | `sys_shutdown` | `fd: fd`, `how: int64` | — | Schließt Teile einer Socket-Verbindung. `SHUT_READ=0`, `SHUT_WRITE=1`, `SHUT_RDWR=2`. |

---

### Kategorie 0x0700 – Sicherheit & Capabilities

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0700 | `sys_cap_create` | `resource_fd: fd`, `rights: int64` | Capability-fd | Erzeugt eine Capability für `resource_fd` mit den angegebenen Rechten. Nur Rechte die `resource_fd` selbst besitzt können vergeben werden. |
| 0x0701 | `sys_cap_restrict` | `cap_fd: fd`, `rights: int64` | neuer eingeschränkter fd | Erzeugt eine neue Capability mit reduzierten Rechten. Rechte können nie erweitert werden. Original-`cap_fd` bleibt unverändert. |
| 0x0702 | `sys_cap_rights` | `cap_fd: fd` | Rechte-Bitmask | Liefert die aktuellen Rechte eines Capability-fds. |
| 0x0703 | `sys_pledge` | `promises: pchar`, `exec_promises: pchar` | — | Reduziert dauerhaft die erlaubten Syscall-Klassen (inspiriert von OpenBSD). Nach `sys_pledge` abgelehnte Syscalls → `ERR_CAPVIOL`. Nur Einschränkungen; einmal reduziert, nie erweitert. `exec_promises` gilt nach `sys_spawn`. |
| 0x0704 | `sys_unveil` | `path: pchar`, `permissions: pchar` | — | Schränkt den sichtbaren Dateisystem-Baum ein (OpenBSD-unveil). `permissions`: Kombination aus `"r"`, `"w"`, `"x"`, `"c"` (create). Nach dem ersten `sys_unveil` sind alle nicht genannten Pfade unsichtbar. |
| 0x0705 | `sys_uid_get` | — | UID | Liefert die User-ID des aktuellen Prozesses. |
| 0x0706 | `sys_gid_get` | — | GID | Liefert die Gruppen-ID des aktuellen Prozesses. |
| 0x0707 | `sys_setuid` | `uid: int64` | — | Ändert die User-ID (erfordert Admin-Capability). Permanente Reduktion von Rechten. |
| 0x0708 | `sys_seccomp` | `mode: int64`, `filter: BpfProg*` | — | Installiert einen BPF-Syscall-Filter (wie Linux seccomp). `SECCOMP_STRICT=1`, `SECCOMP_FILTER=2`. Komplementiert `sys_pledge`. |

**Pledge-Promises:**

```
"stdio"   – read/write/poll auf bestehenden fds
"rpath"   – Dateisystem lesend öffnen/stat
"wpath"   – Dateisystem schreibend öffnen
"cpath"   – Dateien erzeugen/löschen
"exec"    – sys_spawn
"net"     – Socket-Syscalls (0x0600-0x0609)
"thread"  – sys_thread_spawn
"memory"  – sys_mmap / sys_mprotect
"device"  – sys_ioctl, sys_port_in/out
"ai"      – KI-Syscalls (0x0800-0x08FF)
"lyra"    – Lyra-Syscalls (0x0900-0x09FF)
"display" – Grafik-Syscalls (0x0D00-0x0DFF)
"admin"   – privilegierte Syscalls (sys_mount, sys_setuid, ...)
```

---

### Kategorie 0x0800 – KI & Semantik

Diese Gruppe ist das Alleinstellungsmerkmal von Lyx OS. KI-Modelle sind
Kernel-verwaltete Ressourcen — wie Dateien oder Sockets. Der Kernel
teilt Modell-Weights OS-weit, scheduliert Inferenz als eigenen
Workload-Typ und bindet Embeddings an Speicherseiten (semantisches Paging).

Das gesamte KI-Subsystem wird als ladbares Modul (`kernel/ai.lyx`) implementiert.
Wenn es nicht geladen ist, geben alle 0x0800-Syscalls `ERR_NOTSUP` zurück.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0800 | `sys_ai_model_load` | `dir_fd: fd`, `path: pchar`, `flags: int64` | Model-fd | Lädt ein KI-Modell (GGUF, SafeTensors, LAB 2.0). Weights werden in Kernel-Shared-Memory gehalten; mehrere Prozesse können dasselbe Modell ohne Kopie nutzen. Lazy-Load per Page-Fault. |
| 0x0801 | `sys_ai_model_unload` | `model_fd: fd` | — | Gibt ein Modell frei sobald alle Context-fds geschlossen sind. Kernel hält interne Referenzzählung. |
| 0x0802 | `sys_ai_model_info` | `model_fd: fd`, `info_out: AiModelInfo*` | — | Schreibt Metadaten (Name, Architektur, Parameter-Anzahl, Kontext-Größe, Embedding-Dimension, Quantisierung) in `info_out`. |
| 0x0803 | `sys_ai_ctx_create` | `model_fd: fd`, `ctx_size: int64`, `flags: int64` | Context-fd | Erzeugt einen Inferenz-Kontext (KV-Cache, Sampling-State). `ctx_size = 0` → Modell-Default. Jeder Context ist unabhängig; parallele Anfragen nutzen getrennte Contexts. |
| 0x0804 | `sys_ai_ctx_destroy` | `ctx_fd: fd` | — | Gibt KV-Cache und Sampling-State eines Kontexts frei. |
| 0x0805 | `sys_ai_infer` | `ctx_fd: fd`, `prompt_fd: fd`, `result_fd: fd`, `opts: AiInferOpts*` | Inferenz-Job-fd | Startet asynchrone Inferenz. Liest Prompt von `prompt_fd`, schreibt Token-Stream in `result_fd`. Rückgabe: Job-fd der per `sys_poll` / `sys_notify_wait` beobachtet werden kann (`NOTIFY_AI_DONE`). |
| 0x0806 | `sys_ai_infer_sync` | `ctx_fd: fd`, `prompt: ptr`, `prompt_len: int64`, `result: ptr`, `result_max: int64`, `opts: AiInferOpts*` | Ergebnis-Bytes | Synchrone Inferenz; blockiert bis Completion. Nur für kurze Prompts empfohlen — blockiert den Thread. |
| 0x0807 | `sys_ai_embed` | `ctx_fd: fd`, `text: ptr`, `text_len: int64`, `vec_out: f32*`, `dim_inout: int64*` | — | Erzeugt einen Embedding-Vektor für `text`. `*dim_inout` enthält beim Aufruf die Puffergröße; nach Rückkehr die tatsächliche Dimension. |
| 0x0808 | `sys_ai_token_count` | `ctx_fd: fd`, `text: ptr`, `text_len: int64` | Token-Anzahl | Zählt Tokens ohne Inferenz. Nützlich zur Prüfung ob ein Prompt ins Kontextfenster passt. |
| 0x0809 | `sys_ai_search` | `index_fd: fd`, `query_vec: f32*`, `dim: int64`, `k: int64`, `results: AiSearchResult*`, `max: int64` | gefundene Einträge | k-Nearest-Neighbor-Suche in einem Kernel-Vektorindex. Ergebnis-Array wird absteigend nach Ähnlichkeit sortiert. |
| 0x080A | `sys_ai_index_create` | `dim: int64`, `flags: int64` | Index-fd | Erzeugt einen Kernel-verwalteten Vektorindex der Dimension `dim`. `IDX_HNSW=1` für approximative ANN-Suche. |
| 0x080B | `sys_ai_index_insert` | `index_fd: fd`, `id: int64`, `vec: f32*`, `dim: int64`, `meta: ptr`, `meta_len: int64` | — | Fügt einen Vektor mit numerischer ID und optionalen Metadaten in den Index ein. |
| 0x080C | `sys_ai_index_delete` | `index_fd: fd`, `id: int64` | — | Entfernt einen Eintrag aus dem Index. |
| 0x080D | `sys_sem_annotate` | `addr: ptr`, `size: int64`, `embed_fd: fd` | — | Bindet einen Embedding-Vektor (via fd eines laufenden `sys_ai_embed`-Ergebnisses) an eine Speicherregion. Der VMM nutzt diese Information für semantisches Swapping und Cache-Priorisierung. |
| 0x080E | `sys_sem_query` | `query_vec: f32*`, `dim: int64`, `k: int64`, `results: SemMemResult*`, `max: int64` | gefundene Regionen | Findet Speicherregionen deren semantischer Inhalt dem Abfragevektor ähnelt. Ermöglicht "Finde alle Pages die mit diesem Thema zusammenhängen". |
| 0x080F | `sys_graph_node_create` | `fd: fd`, `flags: int64` | Node-ID | Registriert einen fd (Datei, Speicherregion, Prozess, Notification) als Knoten im Kernel-Wissensgraphen. `GRAPH_PERSIST=1`: Knoten überlebt fd-Close und bleibt im persistenten Graph-Store. `GRAPH_AUTO_EMBED=2`: Kernel löst automatisch `sys_ai_embed` aus und verknüpft den Ergebnis-Vektor mit dem Knoten. |
| 0x0810 | `sys_graph_edge_add` | `src_node: int64`, `rel_type: int64`, `dst_node: int64`, `meta: ptr`, `meta_len: int64` | Edge-ID | Erzeugt eine gerichtete Kante zwischen zwei Graph-Knoten mit einem semantischen Relationstyp (`GRAPH_REL_*`). Optionale Metadaten (z.B. Gewicht, Zeitstempel) als Byte-Array. Kanten werden in einem Kernel-seitigen B+-Baum indexiert. |
| 0x0811 | `sys_graph_edge_remove` | `edge_id: int64` | — | Entfernt eine Graph-Kante anhand ihrer ID. Die zugehörigen Knoten bleiben erhalten. Wenn beide Endknoten `GRAPH_PERSIST=0` haben und keine weiteren Kanten besitzen, werden sie GC'd. |
| 0x0812 | `sys_graph_query` | `node_id: int64`, `rel_type: int64`, `depth: int64`, `results: GraphQueryResult*`, `max: int64` | gefundene Einträge | Traversiert den Wissensgraphen von `node_id` ausgehend entlang `rel_type`-Kanten bis Tiefe `depth` (1 = direkte Nachbarn). `rel_type = GRAPH_REL_ANY (-1)` liefert alle Kantentypen. Ergebnisse absteigend nach Kanten-Gewicht sortiert. |
| 0x0813 | `sys_ai_ctx_save` | `ctx_fd: fd`, `dir_fd: fd`, `path: pchar` | — | Persistiert den KV-Cache eines Inferenz-Kontexts als IOFS-Page-Cluster. Ermöglicht Lyra, unterbrochene Konversationen sitzungsübergreifend fortzusetzen. Nur Cache-Zustand wird gespeichert, nicht die Modell-Weights. |
| 0x0814 | `sys_ai_ctx_restore` | `model_fd: fd`, `dir_fd: fd`, `path: pchar` | Context-fd | Lädt einen zuvor gespeicherten KV-Cache und erzeugt einen neuen Context-fd. Das Modell muss identisch zum Modell beim Speichern sein; andernfalls `ERR_BADMODEL`. |
| 0x0815 | `sys_ai_cancel` | `job_fd: fd` | — | Bricht eine laufende asynchrone Inferenz ab (Job-fd aus `sys_ai_infer`). Schreibt `NOTIFY_AI_CANCELED` auf den ursprünglichen Notify-fd. Keine Auswirkung wenn Job bereits abgeschlossen. |
| 0x0816 | `sys_ai_model_pin` | `model_fd: fd` | — | Verhindert das Auslagern eines Modells aus der Kernel-KI-Arena (kein Swap). Kritisch für das Lyra-Basismodell das nie kalt werden darf. Erfordert `CAP_ADMIN` oder `"lyra"`-Pledge. |
| 0x0817 | `sys_ai_model_unpin` | `model_fd: fd` | — | Gibt ein zuvor gepinntes Modell wieder für das Swap-System frei. |
| 0x0818 | `sys_ai_batch_infer` | `ctx_fd: fd`, `prompts_fd: fd`, `count: int64`, `results_fd: fd`, `opts: AiInferOpts*` | Batch-Job-fd | Reicht `count` Prompts in einem GPU-Batch ein. Prompts werden aus `prompts_fd` als Array von `(ptr, len)`-Paaren gelesen. Ergebnisse landen sequentiell in `results_fd`. GPU-Batching erhöht den Durchsatz bei parallelen Anfragen drastisch. |
| 0x0819 | `sys_ai_adapter_load` | `model_fd: fd`, `dir_fd: fd`, `path: pchar`, `flags: int64` | Adapter-fd | Lädt einen LoRA-Adapter aus `path` und aktiviert ihn auf `model_fd`. Mehrere Adapter können gestapelt werden. `ADAPTER_MERGE=1` bäckt die Gewichte direkt ein (irreversibel, spart Laufzeit). |
| 0x081A | `sys_ai_adapter_unload` | `adapter_fd: fd` | — | Entfernt einen LoRA-Adapter vom zugehörigen Modell und gibt die Adapter-Gewichte frei. |
| 0x081B | `sys_ai_classify` | `model_fd: fd`, `text: ptr`, `text_len: int64`, `labels: pchar*`, `label_count: int64`, `scores_out: f32*` | Index des gewählten Labels | Schnelle Klassifikation ohne Textgenerierung. Gibt den Index des wahrscheinlichsten Labels zurück; `scores_out` enthält alle Wahrscheinlichkeitswerte. Hauptsächlich für die Semantische Firewall (Intent-Klassifikation PUBLIC/INTERNAL/CONFIDENTIAL/SECRET). |
| 0x081C | `sys_ai_speech_to_text` | `model_fd: fd`, `audio_fd: fd`, `sample_rate: int64`, `result_fd: fd`, `opts: AiInferOpts*` | STT-Job-fd | Transkribiert Audio-Samples aus `audio_fd` (PCM-S16LE) zu UTF-8-Text in `result_fd`. Basis für Lyras Spracheingabe. Asynchron; Abschluss via `NOTIFY_AI_DONE`. |
| 0x081D | `sys_ai_text_to_speech` | `model_fd: fd`, `text: ptr`, `text_len: int64`, `audio_fd: fd`, `sample_rate_out: int64*` | TTS-Job-fd | Synthetisiert Sprache aus `text` als PCM-S16LE-Samples in `audio_fd`. `*sample_rate_out` enthält die Ausgangs-Abtastrate. Basis für Lyras Sprachausgabe. |
| 0x081E | `sys_graph_node_info` | `node_id: int64`, `info_out: GraphNodeInfo*` | — | Liest Metadaten eines einzelnen Wissensgraph-Knotens (Typ, Payload-Größe, Kanten-Anzahl, Embedding-Dimension, Zeitstempel). Ergänzt `sys_graph_query` um direkten Einzelknoten-Zugriff. |
| 0x081F | `sys_graph_node_delete` | `node_id: int64`, `flags: int64` | — | Löscht einen Knoten explizit. `NODE_DELETE_CASCADE=1`: entfernt auch alle ausgehenden Kanten. Ohne Flag: `ERR_BUSY` wenn noch eingehende Kanten vorhanden. Löst anschließend einen GC-Zyklus aus. |

**AI-Inferenz-Flags:**

```lyx
con AI_STREAM   : int64 := 1   // Token-Streaming in result_fd
con AI_GREEDY   : int64 := 2   // Greedy-Decoding (ignoriert temperature)
con AI_PRIVATE  : int64 := 4   // Kein Audit-Log für diesen Aufruf (wenn erlaubt)
```

**Graph-Flags und Relationstypen:**

```lyx
// sys_graph_node_create flags
con GRAPH_PERSIST    : int64 := 1   // Knoten überlebt fd-Close
con GRAPH_AUTO_EMBED : int64 := 2   // Kernel löst Embedding beim Close aus

// sys_graph_query rel_type
con GRAPH_REL_ANY         : int64 := -1   // Alle Kantentypen
con GRAPH_REL_CREATED_BY  : int64 := 1    // Erstellt von (Prozess/Agent)
con GRAPH_REL_BELONGS_TO  : int64 := 2    // Gehört zu (Projekt, Kontext)
con GRAPH_REL_REFERENCES  : int64 := 3    // Referenziert (Import, Link, Zitat)
con GRAPH_REL_DERIVED_FROM: int64 := 4    // Abgeleitet von (Version, Transformation)
con GRAPH_REL_TEMPORAL    : int64 := 5    // Zeitliche Nähe (innerhalb eines Workflows)
con GRAPH_REL_SEMANTIC    : int64 := 6    // Semantische Ähnlichkeit (KNN-basiert)
con GRAPH_REL_DEPENDS_ON  : int64 := 7    // Abhängigkeit (Code-Modul, Datei)
```

**LoRA-Adapter-Flags:**

```lyx
con ADAPTER_MERGE : int64 := 1   // Gewichte einbacken (irreversibel, eliminiert Laufzeit-Overhead)
```

**Graph-Node-Delete-Flags:**

```lyx
con NODE_DELETE_CASCADE : int64 := 1   // Alle ausgehenden Kanten mitlöschen
```

---

### Kategorie 0x0900 – Lyra Agent Interface

Diese Gruppe implementiert die OS-Agenten-Schnittstelle für Lyra.
Normale Anwendungen nutzen sie nicht direkt — sie kommunizieren mit Lyra
über `sys_channel_*`. Nur Prozesse mit `"lyra"`-Pledge dürfen diese Syscalls aufrufen.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0900 | `sys_intent_submit` | `text: pchar`, `len: int64`, `priority: int64` | Intent-ID | Übermittelt einen natürlichsprachlichen Intent an Lyra. Der Kernel leitet ihn asynchron an den Lyra-Scheduler weiter. `priority`: 0=normal, -1=hoch, 1=niedrig. |
| 0x0901 | `sys_intent_wait` | `intent_id: int64`, `timeout_ns: int64`, `result_fd: fd` | Status | Wartet auf Auflösung eines Intents. Ergebnis wird in `result_fd` geschrieben. `ERR_TIMEOUT` wenn Intent innerhalb `timeout_ns` nicht aufgelöst wurde. |
| 0x0902 | `sys_intent_cancel` | `intent_id: int64` | — | Bricht einen laufenden Intent ab. Hat keinen Effekt wenn er bereits aufgelöst ist. |
| 0x0903 | `sys_lyra_event` | `event_type: int64`, `data: ptr`, `data_len: int64` | — | Sendet ein sensorisches Event an Lyra (Spracheingabe, Eye-Contact-Signal, Geste, Umgebungsdaten). `event_type`: `LYRA_VOICE=1`, `LYRA_GAZE=2`, `LYRA_SENSOR=3`. |
| 0x0904 | `sys_dream_register` | `fn_fd: fd`, `interval_ns: int64`, `flags: int64` | Dream-ID | Registriert eine Callback-Funktion die der Kernel in CPU-Idle-Zyklen aufruft ("Dreaming AI"). `fn_fd` ist ein ausführbarer fd. Wird nicht aufgerufen wenn CPU-Last > `DREAM_MAX_LOAD (20%)`. |
| 0x0905 | `sys_dream_unregister` | `dream_id: int64` | — | Entfernt eine registrierte Dream-Callback. |
| 0x0906 | `sys_memory_store` | `key: pchar`, `val: ptr`, `val_len: int64`, `flags: int64` | — | Schreibt in den episodischen Kern-Ringpuffer von Lyra. `MEM_PERSIST=1` verschiebt den Eintrag nach Ablauf der Ring-TTL in das Core Archive. `MEM_ENCRYPT=2` verschlüsselt vor dem Speichern. |
| 0x0907 | `sys_memory_recall` | `key: pchar`, `buf: ptr`, `buf_size: int64` | Bytes gelesen | Liest einen Eintrag aus dem episodischen Speicher. `ERR_NOENT` wenn nicht gefunden oder TTL abgelaufen. |
| 0x0908 | `sys_memory_search` | `query_vec: f32*`, `dim: int64`, `k: int64`, `results: MemoryResult*`, `max: int64` | gefundene Einträge | Semantische Suche im episodischen Speicher via Embedding-Ähnlichkeit. Gibt die k ähnlichsten Einträge zurück. |
| 0x0909 | `sys_context_push` | `frame: ptr`, `frame_len: int64` | — | Schiebt einen Kontext-Frame auf den Kernel-Kontext-Stack von Lyra (Context Graph, WP17). Wird genutzt um "was gerade passiert" zu kommunizieren. |
| 0x090A | `sys_context_pop` | — | — | Entfernt den obersten Kontext-Frame. |
| 0x090B | `sys_timeline_query` | `from_ns: int64`, `to_ns: int64`, `filter_vec: f32*`, `dim: int64`, `results: TimelineResult*`, `max: int64` | gefundene Einträge | Sucht im Kern-Wissensgraphen nach Ereignissen innerhalb des Zeitfensters `[from_ns, to_ns]` (CLOCK_REAL). Optionaler `filter_vec` (Embedding-Dimension `dim > 0`) schränkt auf semantisch ähnliche Ereignisse ein. Ermöglicht Queries wie "Zeige alles vom Montag als ich an Projekt Alpha gearbeitet habe". `from_ns = 0` → unbegrenzt zurück. |
| 0x090C | `sys_lyra_announce` | `text: pchar`, `text_len: int64`, `icon_fd: fd`, `duration_ns: int64`, `flags: int64` | Announce-ID | Zeigt eine Lyra-Statusmeldung an (Toast/Banner). `duration_ns = 0` = bleibt bis zum expliziten Dismiss. `icon_fd = -1` = kein Icon. `ANNOUNCE_URGENT=1` zeigt die Meldung auch über Vollbild-Apps. Lyra kündigt damit an was sie gerade tut ("Ich fülle das Formular aus..."). |
| 0x090D | `sys_lyra_confirm` | `action_desc: pchar`, `desc_len: int64`, `opts: LyraConfirmOpts*`, `timeout_ns: int64` | User-Antwort-Code | **Consent-Gate:** Fragt den User via Kernel-Dialog um Erlaubnis bevor Lyra eine destruktive Aktion ausführt. `action_desc` beschreibt was Lyra tun will ("Bestellung für 42€ abschicken?"). Rückgabe: `CONFIRM_YES=1`, `CONFIRM_NO=2`, `CONFIRM_TIMEOUT=3`. Kernel-seitig erzwungen — Lyra kann das Gate nicht umgehen. Blockiert den Lyra-Thread bis zur Antwort. |
| 0x090E | `sys_lyra_highlight` | `win_fd: fd`, `node_id: int64`, `color: int64`, `duration_ns: int64` | — | Hebt ein UI-Element optisch hervor (Lyra-Stil: Rahmen + Puls-Animation). Zeigt dem User was Lyra gerade anschaut oder bearbeiten will. `node_id = -1` hebt das gesamte Fenster hervor. Läuft intern über das Overlay-System. |
| 0x090F | `sys_lyra_cursor` | `shape: int64`, `win_fd: fd` | — | Setzt den Mauszeiger auf einen KI-spezifischen Cursor-Stil. `CURSOR_AI_ACTIVE=10` = animierter KI-Cursor. `CURSOR_DEFAULT=0` = zurück zum normalen Cursor. Signalisiert dem User visuell dass Lyra gerade die Steuerung hat. |

**Lyra-Confirm-Optionen:**

```lyx
type LyraConfirmOpts = flat struct {
    yes_label:  [64]uint8;    // Text für "Ja"-Button (Default: "Zulassen")
    no_label:   [64]uint8;    // Text für "Nein"-Button (Default: "Ablehnen")
    detail:     [512]uint8;   // Optionaler Detailtext (leer = keiner)
    risk_level: int64;        // 0=niedrig, 1=mittel, 2=hoch → steuert Dialog-Stil
};
```

**Confirm-Antwort-Codes:**

```lyx
con CONFIRM_YES     : int64 := 1   // User hat zugestimmt
con CONFIRM_NO      : int64 := 2   // User hat abgelehnt
con CONFIRM_TIMEOUT : int64 := 3   // Timeout abgelaufen (Lyra behandelt wie NO)
```

**Announce-Flags:**

```lyx
con ANNOUNCE_URGENT   : int64 := 1   // Über Vollbild-Apps hinaus sichtbar
con ANNOUNCE_PROGRESS : int64 := 2   // Zeigt Fortschrittsbalken
con ANNOUNCE_SILENT   : int64 := 4   // Kein Ton / keine Vibration
```

**Lyra-Cursor-Stile:**

```lyx
con CURSOR_DEFAULT   : int64 := 0    // Standard-Benutzer-Cursor
con CURSOR_AI_ACTIVE : int64 := 10   // Animierter KI-Cursor (Lyra steuert)
con CURSOR_AI_THINK  : int64 := 11   // KI-Denk-Cursor (Lyra überlegt)
con CURSOR_AI_DONE   : int64 := 12   // KI-Fertig-Cursor (kurz nach Aktion)
```

---

### Kategorie 0x0B00 – Task & Automatische Parallelität

Tasks sind leichtgewichtige Arbeitseinheiten ohne festen Core-Bezug.
Der Kernel verteilt sie automatisch über alle verfügbaren Cores via
Work-Stealing. Der Programmierer gibt nur an **was** getan werden soll —
**wo** und **wann** entscheidet der Kernel.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0B00 | `sys_task_spawn` | `fn: fn*`, `arg: ptr`, `arg_size: int64`, `flags: int64` | Task-fd | Erzeugt einen leichtgewichtigen Task. Der Kernel wählt den optimalen Core via Work-Stealing. Kein explizites Thread-Handling nötig. `TASK_DETACHED=1`: kein `sys_task_await` erforderlich. |
| 0x0B01 | `sys_task_await` | `task_fd: fd`, `result_out: ptr`, `result_size: int64`, `timeout_ns: int64` | Ergebnis-Bytes | Wartet auf Abschluss eines Tasks und liest dessen Rückgabewert. `ERR_TIMEOUT` wenn Task innerhalb `timeout_ns` nicht abgeschlossen. |
| 0x0B02 | `sys_task_cancel` | `task_fd: fd` | — | Bricht einen noch nicht gestarteten oder laufenden Task ab. Hat keinen Effekt wenn der Task bereits abgeschlossen ist. |
| 0x0B03 | `sys_task_group_create` | `flags: int64` | group_fd | Erzeugt eine Task-Gruppe für die gebündelte Verwaltung unabhängiger Tasks. Alle Tasks der Gruppe können gemeinsam gewartet werden. |
| 0x0B04 | `sys_task_group_add` | `group_fd: fd`, `fn: fn*`, `arg: ptr`, `arg_size: int64` | Task-fd | Fügt einen Task zur Gruppe hinzu. Der Task startet sofort; der Kernel verteilt ihn auf den am wenigsten ausgelasteten Core. |
| 0x0B05 | `sys_task_group_await` | `group_fd: fd`, `timeout_ns: int64` | abgeschlossene Tasks | Wartet bis alle Tasks der Gruppe abgeschlossen sind. Blockiert den aufrufenden Thread. `ERR_TIMEOUT` wenn nicht alle Tasks innerhalb der Frist fertig. |
| 0x0B06 | `sys_cpu_count` | — | Anzahl logischer CPUs | Liefert die Anzahl der verfügbaren CPU-Kerne. Nützlich zur Dimensionierung von Task-Gruppen. |
| 0x0B07 | `sys_cpu_topology` | `out: CpuTopology*`, `size: int64` | — | Schreibt die CPU-Topologie (Cores, Sockets, NUMA-Nodes) in `out`. Ermöglicht NUMA-bewusste Programmierung wenn nötig. |
| 0x0B08 | `sys_affinity_hint` | `fd: fd`, `cpu_mask: int64` | — | Weicher Scheduling-Hinweis (kein Mandat). Der Kernel berücksichtigt die Maske wenn es die Gesamtauslastung erlaubt, ignoriert sie andernfalls. Bitmask: Bit N = Core N bevorzugt. |
| 0x0B09 | `sys_numa_alloc` | `size: int64`, `node_hint: int64`, `prot: int64` | Adresse | Alloziert Speicher bevorzugt auf dem angegebenen NUMA-Node. `node_hint = -1` = Kernel wählt optimal. |

**Task-Flags:**

```lyx
con TASK_DETACHED         : int64 := 1   // Kein sys_task_await nötig; Ressourcen auto-frei
con TASK_CPU_INTENSIVE    : int64 := 2   // Hint: rechenintensiv → Performance-Core bevorzugt
con TASK_IO_INTENSIVE     : int64 := 4   // Hint: I/O-intensiv → Efficiency-Core akzeptabel
con TASK_LATENCY_SENSITIVE: int64 := 8   // Hint: Latenz kritisch → sofort schedulieren
con TASK_INHERIT_CAPS     : int64 := 16  // Capabilities des Eltern-Prozesses erben
```

**lyxc `@parallel`-Integration:**

Der lyxc-Compiler erzeugt für `--target=lyxos` bei `@parallel`-Loops
automatisch `sys_task_group_create` + `sys_task_group_add`-Calls:

```lyx
@parallel for i in range 0..N {
    result[i] := compute(data[i]);
}
// lyxc generiert:
//   group_fd = sys_task_group_create(0)
//   for i in range 0..N:
//     sys_task_group_add(group_fd, compute_wrapper, &ctx[i], sizeof(ctx[i]))
//   sys_task_group_await(group_fd, -1)
```

Voraussetzung: Loop-Body darf keine Daten-Abhängigkeiten zwischen Iterationen haben.
lyxc prüft dies zur Compilezeit (Data-Flow-Analyse); bei Verletzung: Compile-Fehler.

---

### Kategorie 0x0A00 – Debug & Telemetrie

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0A00 | `sys_debug_print` | `msg: pchar`, `len: int64` | — | Schreibt direkt auf den Kernel-Debug-Ausgang (Port 0xE9 / Debugcon / COM1). Nur in Debug-Builds aktiv; in Release-Builds ist es ein No-Op. |
| 0x0A01 | `sys_trace_event` | `event_id: int64`, `data: ptr`, `data_len: int64` | — | Schreibt einen Trace-Event in den Kernel-Ringpuffer. Abgreifbar über `/dev/trace`. Jeder KI-Inferenz-Aufruf schreibt automatisch einen Trace-Event. |
| 0x0A02 | `sys_perf_counter` | `counter_id: int64` | Zählerwert | Liest einen Hardware-Performance-Counter (RDPMC). `counter_id`: `PERF_CYCLES=0`, `PERF_INSTRS=1`, `PERF_CACHE_MISS=2`. Erfordert entsprechende Capability. |
| 0x0A03 | `sys_stack_trace` | `buf: ptr`, `buf_size: int64` | Frame-Anzahl | Schreibt die aktuelle Call-Stack-Rücksprungadressen-Liste in `buf`. Nützlich für Userspace-Profiler und Crash-Handler. |
| 0x0A04 | `sys_watchpoint_set` | `addr: ptr`, `size: int64`, `flags: int64` | Watchpoint-ID | Setzt einen Hardware-Watchpoint (DR0–DR3). `WP_READ=1`, `WP_WRITE=2`, `WP_EXEC=4`. Bei Auslösung: `NOTIFY_WATCHPOINT` auf dem Thread-Notify-fd. |
| 0x0A05 | `sys_watchpoint_clear` | `wp_id: int64` | — | Löscht einen Hardware-Watchpoint. |

---

### Kategorie 0x0C00 – IOFS: Island & Ocean File System

Niedrig-Level-Zugang zum IOFS-Objektspeicher. Normale Anwendungen nutzen
das VFS-Interface (`sys_open`, `sys_read`, usw.) — diese Gruppe ist für
Kernel-interne Operationen, Admin-Tools und die Panic-Sandbox.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0C00 | `sys_iofs_mount` | `dev_fd: fd`, `opts: IofsOpts*` | mount_fd | Mountet ein Raw-Block-Device als IOFS-Partition. Lädt Page-ID-Tabelle und Block-Bitmap in RAM, prüft CRC32. `opts.flags`: `IOFS_RDONLY=1`, `IOFS_REPAIR=2` (repariert korrupte Tombstones beim Mount). |
| 0x0C01 | `sys_iofs_compact` | `mount_fd: fd`, `region_hint: int64` | compacted_pages | Löst manuell einen REM-Kompaktierungszyklus aus. `region_hint`: Page-ID eines Startknotens (Graph-Cluster wird zusammengeführt); `-1` = ganzes Filesystem. Normalerweise von `sys_dream_register` aufgerufen. Blockiert nicht — Fortschritt via `NOTIFY_GRAPH_UPDATED`. |
| 0x0C02 | `sys_iofs_page_info` | `mount_fd: fd`, `page_id: int64`, `out: IofsPageInfo*` | — | Liest Header und Metadaten einer IOFS-Page ohne den Payload. Nützlich für Debugging, Graph-Inspektion und Admin-Tools. |
| 0x0C03 | `sys_iofs_sandbox_enter` | `mount_fd: fd` | — | Aktiviert die Panic-Sandbox: suspendiert alle KI-Prozesse (Lyra, graph.lyx, REM-Tasks), mountet das deterministische Sandbox-FS als Read-Write-Root. Kernel-Log ab jetzt auf COM1. Erfordert `CAP_ADMIN`. |
| 0x0C04 | `sys_iofs_sandbox_exit` | — | — | Verlässt die Panic-Sandbox: resumed KI-Prozesse, remountet IOFS als Root. Schreibt Prüfsumme des Sandbox-FS vor dem Exit. |

**IOFS-Flags:**

```lyx
// sys_iofs_mount opts.flags
con IOFS_RDONLY : int64 := 1   // Read-Only mounten
con IOFS_REPAIR : int64 := 2   // Tombstone-Reparatur beim Mount

// IofsPageHeader type_flags
con IOFS_META           : int64 := 0x01   // Meta-Page: Embeddings, Graph-Knoten-Info
con IOFS_DATA           : int64 := 0x02   // Data-Page: Nutzdaten (Code, Assets, Logs)
con IOFS_IMMUTABLE      : int64 := 0x04   // Schreibgeschützt nach erstem Write
con IOFS_EDGE_OVERFLOW  : int64 := 0x08   // Continuation-Page für >170 Kanten
con IOFS_TOMBSTONE      : int64 := 0x10   // CoW-Forwarding: neue LBA in Payload

// Page-Embedding-Dimension (384-dim = 1536 Bytes, passt in Meta-Page)
con IOFS_EMBED_DIM : int64 := 384
```

---

### Kategorie 0x0D00 — Display, Fenster & Eingabe

**Design-Entscheidung:** Lyx OS kennt keinen Display-Server und kein Protokoll-Socket
(kein X11, kein Wayland-Protokoll). Der Kernel verwaltet Display-Hardware,
Surface-Puffer (GPU-zugänglich), VSync-Signale und Eingabe-Streams direkt als
Kernel-Objekte hinter fds. **Lyra** übernimmt als privilegierter Compositor-Prozess
(benötigt `"display"`-Pledge) alle Layout- und Z-Order-Entscheidungen.

Anwendungen sprechen direkt mit dem Kernel — kein Protokoll-Overhead, kein
IPC-Roundtrip. Eine Anwendung erstellt ein Fenster, bekommt einen Surface-fd,
zeichnet (CPU oder GPU) und ruft `sys_surface_present` auf. Der Rest ist Lyra.

**Sub-Gruppen:**

| Bereich | Inhalt |
|---------|--------|
| 0x0D00–0x0D02 | Display-Verwaltung |
| 0x0D03–0x0D07 | Surface-Verwaltung (Pixel-Puffer) |
| 0x0D08–0x0D0E | Fenster-Verwaltung (Compositor-Interface) |
| 0x0D0F–0x0D10 | Eingabe |
| 0x0D11–0x0D12 | GPU-Beschleunigung |

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0D00 | `sys_display_open` | `display_id: int64`, `flags: int64` | Display-fd | Öffnet ein Display-Gerät. `display_id = 0` = primäres Display. Erfordert `"display"`-Pledge. Das zurückgegebene fd ist der Ankerpunkt für Surfaces und VSync. |
| 0x0D01 | `sys_display_info` | `display_fd: fd`, `info_out: DisplayInfo*` | — | Schreibt Auflösung, Refresh-Rate, DPI, Pixel-Format und Flags (HDR, Touch, primär) in `info_out`. |
| 0x0D02 | `sys_display_list` | `ids_out: int64*`, `max: int64` | Anzahl Displays | Füllt `ids_out` mit allen verfügbaren Display-IDs. Ermöglicht Multi-Monitor-Erkennung. |
| 0x0D03 | `sys_surface_create` | `display_fd: fd`, `width: int64`, `height: int64`, `format: int64`, `flags: int64` | Surface-fd | Alloziert einen GPU-zugänglichen Pixel-Puffer in der angegebenen Auflösung und im angegebenen Format (`PIX_*`). `SURF_DOUBLE_BUFFER=4` legt automatisch Front + Back Buffer an. |
| 0x0D04 | `sys_surface_map` | `surface_fd: fd` | Pixel-Puffer-Adresse | Mappt den Back-Buffer einer Surface als beschreibbare Speicherseiten in den Adressraum. Ermöglicht CPU-Drawing. Nach `sys_surface_present` ist die Adresse weiterhin gültig (Double-Buffering tauscht intern). |
| 0x0D05 | `sys_surface_unmap` | `surface_fd: fd` | — | Hebt das CPU-Mapping auf. Die Surface selbst bleibt erhalten; nur der Userspace-Zeiger wird ungültig. |
| 0x0D06 | `sys_surface_present` | `surface_fd: fd`, `win_fd: fd`, `damage: DamageRect*`, `damage_count: int64` | Frame-ID | Übergibt die Surface an den Compositor (Lyra) zur Darstellung im Fenster `win_fd`. `damage` gibt die veränderten Rechtecke an (0/NULL = gesamte Surface). Compositor wartet auf den nächsten VSync. `NOTIFY_VSYNC` wird geschrieben wenn der Frame auf dem Display erscheint. |
| 0x0D07 | `sys_vsync_wait` | `display_fd: fd`, `timeout_ns: int64` | Frame-ID | Blockiert bis zum nächsten vertikalen Sync-Puls des Displays. Gibt eine monoton steigende Frame-ID zurück. Nützlich für zeitpräzise Animation ohne Polling. `ERR_TIMEOUT` bei Ablauf der Frist. |
| 0x0D08 | `sys_window_create` | `display_fd: fd`, `title: pchar`, `opts: WindowOpts*` | Win-fd | Fordert beim Compositor ein Fenster an. Lyra entscheidet über tatsächliche Position und Größe (respektiert `opts` als Hint wenn `WIN_LYRA_MANAGED` nicht gesetzt). Schreibt `NOTIFY_WIN_CLOSE`, `NOTIFY_WIN_RESIZE` und `NOTIFY_WIN_FOCUS_*` auf `opts.notify_fd`. |
| 0x0D09 | `sys_window_resize` | `win_fd: fd`, `width: int64`, `height: int64` | — | Bittet den Compositor, das Fenster auf die neue Größe zu ändern. Bei `WIN_LYRA_MANAGED`: Lyra kann den Wunsch ignorieren. Bei manuell verwalteten Fenstern: sofortige Wirkung. |
| 0x0D0A | `sys_window_move` | `win_fd: fd`, `x: int64`, `y: int64` | — | Setzt die Fensterposition (in Display-Pixeln, Ursprung = oben links). Wie `sys_window_resize` ist dies ein Hint wenn `WIN_LYRA_MANAGED` gesetzt. |
| 0x0D0B | `sys_window_show` | `win_fd: fd`, `mode: int64` | — | Ändert den Sichtbarkeitszustand des Fensters. `mode`: `WIN_SHOW=0`, `WIN_HIDE=1`, `WIN_MINIMIZE=2`, `WIN_MAXIMIZE=3`, `WIN_FULLSCREEN=4`, `WIN_RESTORE=5`. |
| 0x0D0C | `sys_window_destroy` | `win_fd: fd` | — | Entfernt das Fenster aus dem Compositor. Der zugehörige Surface-fd wird implizit freigegeben. Schreibt `NOTIFY_WIN_CLOSE` auf den Notify-fd bevor der fd ungültig wird. |
| 0x0D0D | `sys_window_title` | `win_fd: fd`, `title: pchar` | — | Ändert den Fenstertitel. Lyra wertet den Titel semantisch aus (z.B. für Task-Switching-Ansagen). |
| 0x0D0E | `sys_window_surface` | `win_fd: fd` | Surface-fd | Gibt den Surface-fd zurück der diesem Fenster zugeordnet ist. Wird automatisch angelegt wenn das Fenster erzeugt wurde; kann auch manuell via `sys_surface_create` + manueller Übergabe gesetzt werden. |
| 0x0D0F | `sys_input_open` | `device_type: int64`, `flags: int64` | Input-fd | Öffnet einen Eingabekanal für den angegebenen Gerätetyp (`INPUT_KEYBOARD`, `INPUT_MOUSE`, `INPUT_TOUCH`, `INPUT_STYLUS`, `INPUT_GAMEPAD`). Events werden im Kernel gepuffert. `POLL_IN` auf dem fd wenn Events verfügbar. |
| 0x0D10 | `sys_input_read` | `input_fd: fd`, `events: InputEvent*`, `max: int64` | gelesene Events | Liest bis zu `max` Eingabeereignisse in das `events`-Array. `0` = kein Event vorhanden (non-blocking). Jedes Event enthält Typ, Zeitstempel, Koordinaten, Modifier-Bits und Druck (für Stylus/Touch). |
| 0x0D11 | `sys_gpu_submit` | `surface_fd: fd`, `cmds: ptr`, `cmd_len: int64` | Fence-ID | Reicht einen GPU-Command-Buffer zur Ausführung auf der Surface ein. Format und Inhalt von `cmds` sind GPU-spezifisch (Treiber-ABI). Rückgabe: Fence-ID für `sys_gpu_fence_wait`. |
| 0x0D12 | `sys_gpu_fence_wait` | `fence_id: int64`, `timeout_ns: int64` | — | Blockiert bis der GPU den Command-Buffer mit der angegebenen Fence-ID abgearbeitet hat. `ERR_TIMEOUT` bei Fristablauf. `ERR_GPU_FAULT` wenn der GPU einen Fehler gemeldet hat. |

**Display-Flags:**

```lyx
con DISP_HDR     : int64 := 1   // Display unterstützt High Dynamic Range
con DISP_TOUCH   : int64 := 2   // Touch-Display (integriert)
con DISP_PRIMARY : int64 := 4   // Primäres Display
con DISP_EXTERNAL: int64 := 8   // Extern angeschlossen (HDMI, DP, USB-C)
```

**Pixel-Formate:**

```lyx
con PIX_ARGB8888 : int64 := 1   // 32-bit: Alpha/R/G/B je 8 Bit (Standard)
con PIX_XRGB8888 : int64 := 2   // 32-bit: Padding/R/G/B (kein Alpha)
con PIX_RGB565   : int64 := 3   // 16-bit: 5/6/5 Bit (Embedded-Displays)
con PIX_A8       : int64 := 4   // 8-bit Alpha only (Masken-Surfaces)
```

**Surface-Flags:**

```lyx
con SURF_GPU_READABLE  : int64 := 1   // GPU kann Pixel lesen (für Compositing)
con SURF_GPU_WRITABLE  : int64 := 2   // GPU kann Pixel schreiben (für GPU-Rendering)
con SURF_DOUBLE_BUFFER : int64 := 4   // Front + Back Buffer; Present tauscht sie
```

**Fenster-Sichtbarkeitsmodi:**

```lyx
con WIN_SHOW       : int64 := 0   // Normal anzeigen
con WIN_HIDE       : int64 := 1   // Verstecken (kein Taskbar-Eintrag)
con WIN_MINIMIZE   : int64 := 2   // Minimieren (im Taskbar)
con WIN_MAXIMIZE   : int64 := 3   // Maximieren (gesamte Display-Fläche)
con WIN_FULLSCREEN : int64 := 4   // Exklusiv-Vollbild (kein Compositor-Overlay)
con WIN_RESTORE    : int64 := 5   // Zur vorherigen Größe zurückkehren
```

**Fenster-Optionen (WindowOpts.flags):**

```lyx
con WIN_RESIZABLE    : int64 := 1   // Benutzer kann Größe ziehen
con WIN_BORDERLESS   : int64 := 2   // Kein Fensterrahmen (eigene Dekoration)
con WIN_TRANSPARENT  : int64 := 4   // Compositor compositet Alpha-Kanal durch
con WIN_ALWAYS_TOP   : int64 := 8   // Immer über anderen Fenstern
con WIN_LYRA_MANAGED : int64 := 16  // Lyra entscheidet Position/Größe (Standard AI-OS)
con WIN_NO_SHADOW    : int64 := 32  // Kein Schatten durch Compositor
```

**Eingabegeräte:**

```lyx
con INPUT_KEYBOARD : int64 := 1
con INPUT_MOUSE    : int64 := 2
con INPUT_TOUCH    : int64 := 3
con INPUT_STYLUS   : int64 := 4
con INPUT_GAMEPAD  : int64 := 5
```

**Eingabe-Event-Typen:**

```lyx
con EV_KEY_PRESS    : int64 := 1   // Taste gedrückt
con EV_KEY_RELEASE  : int64 := 2   // Taste losgelassen
con EV_MOUSE_MOVE   : int64 := 3   // Maus bewegt
con EV_MOUSE_BUTTON : int64 := 4   // Maustaste gedrückt/losgelassen
con EV_MOUSE_SCROLL : int64 := 5   // Mausrad
con EV_TOUCH_DOWN   : int64 := 6   // Berührung beginnt
con EV_TOUCH_MOVE   : int64 := 7   // Berührung bewegt sich
con EV_TOUCH_UP     : int64 := 8   // Berührung endet
```

---

### Kategorie 0x0D13–0x0D1D — Lyra als GUI-Akteur

Wenn Lyra auf der Oberfläche handelt (anstelle des Users), gelten drei
Anforderungen die über normale Grafik-Syscalls hinausgehen:

1. **Sehen:** Lyra muss den Bildschirminhalt lesen (Snapshot für Vision-AI).
2. **Verstehen:** Lyra muss UI-Elemente semantisch kennen — nicht nur Pixel,
   sondern "Das ist ein Submit-Button" (Accessibility-Baum).
3. **Handeln:** Lyra muss synthetische Events einschleusen und eigene
   Overlay-Schichten rendern.

**Agency-Kontext:** Der Kernel unterscheidet explizit zwischen User-Eingabe und
KI-Eingabe. Jeder synthetische Input via `sys_input_inject` wird mit dem
Lyra-Prozess-fd markiert. Anwendungen können via `InputEvent.modifiers`-Bit
`EV_SOURCE_AI=0x8000` erkennen ob Lyra oder der Mensch steuert. Alle Lyra-UI-Aktionen
schreiben automatisch einen `sys_trace_event`-Eintrag (vollständiger Audit-Trail).

**Consent-Gate:** Für destructive Aktionen (Löschen, Senden, Kaufen) muss Lyra
`sys_lyra_confirm` aufrufen. Der User muss explizit bestätigen bevor der Kernel
die Aktion freigibt. Diese Bestätigung ist kernel-seitig erzwungen — Lyra kann sie
nicht selbst fälschen.

| Nr | Name | Argumente | rdx-Rückgabe | Beschreibung |
|----|------|-----------|--------------|--------------|
| 0x0D13 | `sys_window_list` | `out: int64*`, `max: int64` | Anzahl Fenster | Füllt `out` mit den win_fds aller sichtbaren Fenster (nach Z-Order, vorderstes zuerst). Erfordert `"display"`-Pledge. Lyras Einstiegspunkt um die aktuelle UI-Landschaft zu verstehen. |
| 0x0D14 | `sys_window_info` | `win_fd: fd`, `info_out: WindowInfo*` | — | Liest Metadaten eines Fensters: Titel, Bounds (x/y/width/height), Owner-PID, Fokus-Status und Accessibility-Typ. Ermöglicht Lyra das gezielte Ansteuern eines bestimmten App-Fensters. |
| 0x0D15 | `sys_window_focus` | `win_fd: fd` | — | Gibt dem Fenster den Eingabefokus. Erfordert `"display"`-Pledge. Notwendige Vorbedingung vor `sys_input_inject` wenn das Zielfenster nicht bereits fokussiert ist. Schreibt `NOTIFY_WIN_FOCUS_IN` / `NOTIFY_WIN_FOCUS_OUT` auf betroffene Fenster. |
| 0x0D16 | `sys_input_inject` | `win_fd: fd`, `events: InputEvent*`, `count: int64` | — | Schleust synthetische Eingabeereignisse in das Fenster ein. Erfordert `"display"`-Pledge. Der Kernel setzt automatisch `EV_SOURCE_AI=0x8000` im `modifiers`-Feld — die empfangende App kann Lyra-Input von User-Input unterscheiden. Jeder Aufruf schreibt einen Audit-`trace_event`. |
| 0x0D17 | `sys_display_snapshot` | `display_fd: fd`, `surface_fd: fd`, `flags: int64` | — | Rendert den komponierten Bildschirminhalt des Displays in `surface_fd`. Lyra nutzt dies als Eingabe für Vision-AI (`sys_ai_infer` mit multimodalen Modellen). `SNAP_CURSOR=1` schließt den Mauszeiger ein. `SNAP_NOCURSOR=2` blendet ihn aus. |
| 0x0D18 | `sys_window_snapshot` | `win_fd: fd`, `surface_fd: fd`, `flags: int64` | — | Wie `sys_display_snapshot`, aber nur für ein einzelnes Fenster. Auch wenn das Fenster teilweise verdeckt ist wird der vollständige Fensterinhalt geliefert (Off-Screen-Rendering). |
| 0x0D19 | `sys_overlay_create` | `win_fd: fd`, `x: int64`, `y: int64`, `width: int64`, `height: int64`, `flags: int64` | Overlay-fd | Erzeugt ein transparentes Overlay über einem Fenster. Lyra zeichnet in die Overlay-Surface (eigener Surface-fd via `sys_window_surface`). Der Compositor rendert das Overlay immer über dem Zielfenster. `OVL_CLICK_THROUGH=1`: Mausklicks gehen durch das Overlay ans Zielfenster. `OVL_HIGHLIGHT=2`: vordefinierter Highlight-Effekt (kein eigenes Drawing nötig). |
| 0x0D1A | `sys_overlay_destroy` | `overlay_fd: fd` | — | Entfernt ein Overlay. |
| 0x0D1B | `sys_acc_tree` | `win_fd: fd`, `buf: ptr`, `buf_size: int64` | geschriebene Bytes | Liest den Accessibility-Baum eines Fensters als Array von `AccNode`-Strukturen. Lyra-native Apps (lyxc-Runtime) exportieren diesen automatisch. Der Baum beschreibt alle sichtbaren UI-Elemente semantisch: "Button: Senden", "TextInput: leer", "Label: Preis 42€". Lyra muss damit nicht pixelweise analysieren. |
| 0x0D1C | `sys_acc_action` | `win_fd: fd`, `node_id: int64`, `action: int64`, `data: ptr`, `data_len: int64` | — | Führt eine Aktion auf einem UI-Element aus. `ACC_CLICK=1`: Klick auf Button/Link. `ACC_FOCUS=2`: Element fokussieren. `ACC_SET_VALUE=3`: Text in Eingabefeld setzen (`data` = UTF-8-String). `ACC_SCROLL=4`: Scroll-Position setzen. Jede Aktion schreibt einen Audit-`trace_event` mit node_id und Aktion. `ERR_PERM` wenn die App `"ai"`-Pledge nicht hat. |
| 0x0D1D | `sys_acc_subscribe` | `win_fd: fd`, `notify_fd: fd` | — | Abonniert `NOTIFY_ACC_CHANGED`-Events auf `notify_fd` wenn sich der Accessibility-Baum des Fensters ändert (neue Elemente, Zustandsänderungen, Text-Updates). Lyra nutzt dies um reaktiv auf UI-Änderungen zu reagieren (z.B. "Warte bis das Ladebalken-Element verschwindet"). |

**Agency-Flags für InputEvent.modifiers:**

```lyx
con EV_SOURCE_USER : int64 := 0x0000   // Physischer User-Input (Standard)
con EV_SOURCE_AI   : int64 := 0x8000   // Lyra-injizierter synthetischer Input
```

**Overlay-Flags:**

```lyx
con OVL_CLICK_THROUGH : int64 := 1   // Mausevents gehen ans Zielfenster durch
con OVL_HIGHLIGHT     : int64 := 2   // Vordefinierter Highlight-Effekt (Lyra-Stil)
con OVL_ALWAYS_TOP    : int64 := 4   // Über allen anderen Overlays
```

**Accessibility-Aktionen:**

```lyx
con ACC_CLICK     : int64 := 1   // Klick auf Element (Button, Link, Checkbox)
con ACC_FOCUS     : int64 := 2   // Eingabefokus setzen
con ACC_SET_VALUE : int64 := 3   // Wert setzen (TextInput, Slider, Dropdown)
con ACC_SCROLL    : int64 := 4   // Scroll-Position setzen (data = int64 Pixel-Offset)
con ACC_EXPAND    : int64 := 5   // Ausklappen (Accordion, Dropdown, TreeNode)
con ACC_COLLAPSE  : int64 := 6   // Einklappen
```

**Snapshot-Flags:**

```lyx
con SNAP_CURSOR   : int64 := 1   // Mauszeiger in Snapshot einschließen
con SNAP_NOCURSOR : int64 := 2   // Mauszeiger ausblenden
con SNAP_HDR      : int64 := 4   // HDR-Ausgabe wenn verfügbar
```

---

## 6. Strukturdefinitionen

```lyx
type Stat = flat struct {
    ino:      uint64;   // Inode-Nummer
    dev:      uint64;   // Geräte-ID
    mode:     uint64;   // Dateityp + Berechtigungen (S_* | Perm-Bits)
    nlink:    uint64;   // Anzahl harter Links
    uid:      uint64;   // Besitzer-UID
    gid:      uint64;   // Besitzer-GID
    size:     int64;    // Dateigröße in Bytes
    blksize:  int64;    // Bevorzugte Block-Größe für I/O
    blocks:   int64;    // Allokierte 512-Byte-Blöcke
    atime_ns: int64;    // Letzter Zugriff (Nanosekunden seit Unix-Epoche)
    mtime_ns: int64;    // Letzte Änderung
    ctime_ns: int64;    // Letzter Status-Wechsel
    rdev:     uint64;   // Gerätetyp (für Device-Dateien)
};

type DirEntry = flat struct {
    ino:      uint64;
    type:     uint8;    // S_REG, S_DIR usw.
    name_len: uint8;
    name:     [256]uint8;
};

type TimeSpec = flat struct {
    sec:  int64;
    nsec: int64;
};

type PollEvent = flat struct {
    fd:      int64;
    events:  uint32;    // POLL_* gewünschte Events
    revents: uint32;    // POLL_* eingetroffene Events (Kernel-Ausgabe)
};

type Notification = flat struct {
    type:       uint32;   // NOTIFY_* Typ
    flags:      uint32;
    data:       uint64;   // Typ-spezifische Daten
    source_pid: uint64;
    ts_ns:      int64;    // Zeitstempel (CLOCK_MONO)
};

type SpawnOpts = flat struct {
    flags:          int64;   // SPAWN_*
    cwd_fd:         int64;   // -1 = erben
    stdin_fd:       int64;   // -1 = /dev/null
    stdout_fd:      int64;
    stderr_fd:      int64;
    extra_fds:      int64;   // Zeiger auf int64-Array mit weiteren fds
    extra_fd_count: int64;
    stack_size:     int64;   // 0 = Default (2 MB)
    priority:       int64;   // 0 = normal
};

type AiModelInfo = flat struct {
    name:          [64]uint8;
    architecture:  [32]uint8;   // "llama", "qwen", "mistral", ...
    param_count:   uint64;
    ctx_size:      uint64;      // Max. Kontext in Tokens
    embed_dim:     uint64;      // Embedding-Vektor-Dimension
    quantization:  uint8;       // 0=f32, 1=f16, 2=q8, 3=q4
    flags:         uint64;      // Modell-Capability-Flags
};

type AiInferOpts = flat struct {
    max_tokens:   int64;    // 0 = Modell-Default
    temperature:  f32;      // 0.0 = deterministisch
    top_p:        f32;      // Nucleus-Sampling-Schwelle
    seed:         int64;    // -1 = zufällig
    stop_tokens:  int64;    // Zeiger auf pchar* (null-terminiertes Array)
    flags:        int64;    // AI_STREAM | AI_GREEDY | AI_PRIVATE
    timeout_ns:   int64;    // 0 = kein Timeout
};

type AiSearchResult = flat struct {
    id:         int64;
    score:      f32;    // Ähnlichkeitswert (0.0–1.0, höher = ähnlicher)
    meta_len:   int64;
    meta:       [256]uint8;
};

type SemMemResult = flat struct {
    addr:  int64;    // Basisadresse der Speicherregion
    size:  int64;    // Größe in Bytes
    score: f32;
};

type MemoryResult = flat struct {
    key:      [128]uint8;
    val_len:  int64;
    score:    f32;
    ts_ns:    int64;
};

type CpuTopology = flat struct {
    cpu_count:    int64;          // Anzahl logischer CPUs (Hyperthreads)
    core_count:   int64;          // Anzahl physischer Kerne
    socket_count: int64;          // Anzahl CPU-Sockets
    numa_nodes:   int64;          // Anzahl NUMA-Nodes
    cpu_ids:      [256]int64;     // Logische CPU-IDs
    core_ids:     [256]int64;     // Physische Kern-IDs pro CPU
    socket_ids:   [256]int64;     // Socket-IDs pro CPU (NUMA-Node)
};

type MsgHdr = flat struct {
    name:       int64;   // Zeiger auf Adress-Struktur (für UDP)
    name_len:   int64;
    iov:        int64;   // Zeiger auf IoVec-Array
    iov_count:  int64;
    ctrl:       int64;   // Ancillary-Daten (fd-Passing)
    ctrl_len:   int64;
    flags:      int64;
};

type IofsPageHeader = @big_endian flat struct {
    page_id:    uint64;         // Stabile 64-bit Sequenz-ID (≠ LBA)
    type_flags: uint64;         // IOFS_META | IOFS_DATA | IOFS_IMMUTABLE usw.
    payload_sz: uint32;         // Nutzdaten-Größe in Bytes
    edge_count: uint16;         // Anzahl Kanten im Edge-Array
    reserved:   uint16;
    ts_create:  int64;          // CLOCK_REAL Nanosekunden
    ts_modify:  int64;
    ts_access:  int64;
    crc32:      uint32;         // CRC32 über Payload + Edge-Array
    padding:    [52]uint8;      // Header auf 128 Bytes auffüllen
};

type IofsEdge = flat struct {
    target_id: uint64;   // Ziel-Page-ID
    weight:    f32;      // Kanten-Gewicht / semantische Nähe (0.0–1.0)
    rel_type:  uint32;   // GRAPH_REL_* (passt in 32-bit)
};

type IofsPageInfo = flat struct {
    page_id:    uint64;
    lba:        uint64;    // Aktuelle physische LBA auf dem Block-Device
    type_flags: uint64;
    payload_sz: uint32;
    edge_count: uint16;
    ref_count:  uint16;    // Anzahl eingehender Kanten (für GC)
    ts_create:  int64;
    ts_modify:  int64;
};

type IofsOpts = flat struct {
    flags:       int64;
    sandbox_lba: uint64;   // LBA-Start der Panic-Sandbox (0 = Auto-Detect)
    sandbox_sz:  uint64;   // Größe der Sandbox in Bytes
};

type GraphQueryResult = flat struct {
    node_id:   int64;    // Ziel-Knoten-ID
    edge_id:   int64;    // Kanten-ID
    rel_type:  int64;    // GRAPH_REL_* Kantentyp
    weight:    f32;      // Kanten-Gewicht (höher = stärker verknüpft)
    ts_ns:     int64;    // Zeitstempel der Kanten-Erzeugung
    meta_len:  int64;    // Länge der Kanten-Metadaten
    meta:      [128]uint8;
};

type GraphNodeInfo = flat struct {
    node_id:    int64;    // Knoten-ID
    type_flags: int64;    // GRAPH_NODE_* Typ-Bits
    payload_sz: int64;    // Größe der gespeicherten Nutzdaten in Bytes
    edge_count: int64;    // Anzahl ausgehender Kanten
    embed_dim:  int64;    // Embedding-Dimension (0 = kein Embedding vorhanden)
    ts_create:  int64;    // Erstellungszeitpunkt (CLOCK_REAL ns)
    ts_modify:  int64;    // Letzter Änderungszeitpunkt
    ref_count:  int64;    // Anzahl eingehender Kanten (GC-Referenzzähler)
};

type DisplayInfo = flat struct {
    display_id:   int64;
    width_px:     int64;
    height_px:    int64;
    refresh_mhz:  int64;    // Refresh-Rate in Millihertz (60000 = 60 Hz)
    dpi_x:        int64;
    dpi_y:        int64;
    pixel_format: int64;    // PIX_* Standardformat des Displays
    flags:        int64;    // DISP_HDR | DISP_TOUCH | DISP_PRIMARY | DISP_EXTERNAL
};

type WindowOpts = flat struct {
    x:          int64;    // Initiale X-Position (Hint für Compositor)
    y:          int64;    // Initiale Y-Position
    width:      int64;    // Initiale Breite in Pixeln
    height:     int64;    // Initiale Höhe in Pixeln
    min_width:  int64;    // Minimale Breite (0 = kein Limit)
    min_height: int64;    // Minimale Höhe
    max_width:  int64;    // Maximale Breite (0 = kein Limit)
    max_height: int64;    // Maximale Höhe
    flags:      int64;    // WIN_RESIZABLE | WIN_BORDERLESS | WIN_LYRA_MANAGED usw.
    notify_fd:  int64;    // fd für NOTIFY_WIN_CLOSE / NOTIFY_WIN_RESIZE / NOTIFY_WIN_FOCUS_*
};

type InputEvent = flat struct {
    type:      int64;    // EV_* Ereignistyp
    ts_ns:     int64;    // Zeitstempel (CLOCK_MONO ns)
    key:       int64;    // Taste / Button-Index (bei EV_KEY_*, EV_MOUSE_BUTTON)
    modifiers: int64;    // Modifier-Bits: SHIFT=1, CTRL=2, ALT=4, META=8
    x:         int64;    // Absolut-X in Pixeln (Maus/Touch; relativ für EV_MOUSE_MOVE)
    y:         int64;    // Absolut-Y in Pixeln
    dx:        int64;    // Delta-X (relativ, für Maus-Move und Scroll)
    dy:        int64;    // Delta-Y
    pressure:  f32;      // Druckwert 0.0–1.0 (Stylus/Touch; 0 für Keyboard/Maus)
    touch_id:  int64;    // Berührungs-ID für Multi-Touch (eindeutig pro Finger)
};

type DamageRect = flat struct {
    x:      int64;    // Linke Kante des geänderten Rechtecks in Pixeln
    y:      int64;    // Obere Kante
    width:  int64;
    height: int64;
};

type WindowInfo = flat struct {
    win_fd:      int64;       // fd des Fensters
    owner_pid:   int64;       // PID des besitzenden Prozesses
    title:       [256]uint8;  // Aktueller Fenstertitel (UTF-8)
    x:           int64;       // Position auf dem Display
    y:           int64;
    width:       int64;
    height:      int64;
    z_order:     int64;       // Z-Position (0 = vorderstes Fenster)
    focused:     bool;        // Hat Eingabefokus?
    visible:     bool;        // Sichtbar (nicht minimiert)?
    acc_type:    int64;       // Accessibility-Typ des Hauptinhalts
};

type AccNode = flat struct {
    node_id:   int64;         // Eindeutige ID innerhalb des Fensters
    parent_id: int64;         // 0 = Root-Element
    type:      int64;         // ACC_TYPE_BUTTON, ACC_TYPE_INPUT usw.
    x:         int64;         // Absolute Bildschirmposition
    y:         int64;
    width:     int64;
    height:    int64;
    label:     [128]uint8;    // Sichtbarer Text / Aria-Label (UTF-8)
    value:     [256]uint8;    // Aktueller Wert (z.B. Inhalt eines Textfelds)
    enabled:   bool;
    focused:   bool;
    checked:   bool;          // Für Checkboxen / Radio-Buttons
    expanded:  bool;          // Für Accordions / Dropdowns
    child_count: int64;
};

// Accessibility-Node-Typen
// (als Konstanten, kein Enum — lyxc kennt keine Enums)
```

**Accessibility-Node-Typen:**

```lyx
con ACC_TYPE_BUTTON    : int64 := 1
con ACC_TYPE_INPUT     : int64 := 2   // Einzeiliges Textfeld
con ACC_TYPE_TEXTAREA  : int64 := 3   // Mehrzeiliges Textfeld
con ACC_TYPE_LABEL     : int64 := 4
con ACC_TYPE_LINK      : int64 := 5
con ACC_TYPE_IMAGE     : int64 := 6
con ACC_TYPE_CHECKBOX  : int64 := 7
con ACC_TYPE_RADIO     : int64 := 8
con ACC_TYPE_DROPDOWN  : int64 := 9
con ACC_TYPE_SLIDER    : int64 := 10
con ACC_TYPE_LIST      : int64 := 11
con ACC_TYPE_LISTITEM  : int64 := 12
con ACC_TYPE_MENU      : int64 := 13
con ACC_TYPE_MENUITEM  : int64 := 14
con ACC_TYPE_CONTAINER : int64 := 15  // Allgemeiner Container / Panel
con ACC_TYPE_PROGRESS  : int64 := 16  // Fortschrittsbalken
con ACC_TYPE_CANVAS    : int64 := 17  // Frei gezeichnete Fläche (kein Baum darunter)
```

type TimelineResult = flat struct {
    node_id:   int64;    // Knoten-ID im Wissensgraphen
    ts_ns:     int64;    // Zeitstempel des Ereignisses (CLOCK_REAL)
    score:     f32;      // Semantische Ähnlichkeit zum filter_vec (0.0 wenn kein Filter)
    event_type: int64;   // GRAPH_REL_* oder 0 für generisches Ereignis
    summary:   [256]uint8; // Kurze Beschreibung (aus Embedding-Metadaten)
};
```

---

## 7. Konstanten-Referenz

### Stat-Dateityp-Bits (mode-Feld)

```lyx
con S_REG  : int64 := 0x8000   // Reguläre Datei
con S_DIR  : int64 := 0x4000   // Verzeichnis
con S_LINK : int64 := 0xA000   // Symbolischer Link
con S_CHAR : int64 := 0x2000   // Zeichen-Gerät
con S_BLK  : int64 := 0x6000   // Block-Gerät
con S_PIPE : int64 := 0x1000   // Named Pipe / FIFO
con S_SOCK : int64 := 0xC000   // Socket
```

### Notify-Typen

```lyx
con NOTIFY_SIGNAL     : int64 := 1   // Signal-ähnliches Event
con NOTIFY_CHILD_EXIT : int64 := 2   // Kind-Prozess beendet
con NOTIFY_TIMER      : int64 := 3   // Timer abgelaufen
con NOTIFY_FD_READY   : int64 := 4   // fd bereit (I/O)
con NOTIFY_AI_DONE      : int64 := 5   // KI-Inferenz abgeschlossen
con NOTIFY_INTENT_DONE  : int64 := 6   // Lyra-Intent aufgelöst
con NOTIFY_IRQ          : int64 := 7   // Hardware-IRQ
con NOTIFY_WATCHPOINT   : int64 := 8   // Hardware-Watchpoint ausgelöst
con NOTIFY_EMBED_DONE   : int64 := 9   // Async-Embedding (O_SEMANTIC) abgeschlossen
con NOTIFY_GRAPH_UPDATED: int64 := 10  // Wissensgraph-Kante hinzugefügt/entfernt
con NOTIFY_WIN_CLOSE    : int64 := 11  // Benutzer hat Fenster geschlossen
con NOTIFY_WIN_RESIZE   : int64 := 12  // Fenster wurde in der Größe verändert (neue Maße in data)
con NOTIFY_WIN_FOCUS_IN : int64 := 13  // Fenster hat Eingabefokus erhalten
con NOTIFY_WIN_FOCUS_OUT: int64 := 14  // Fenster hat Eingabefokus verloren
con NOTIFY_VSYNC        : int64 := 15  // Vertikaler Sync-Puls (Frame-ID in data)
con NOTIFY_INPUT_READY  : int64 := 16  // Eingabeereignisse auf einem input_fd verfügbar
con NOTIFY_AI_CANCELED  : int64 := 17  // KI-Inferenz-Job via sys_ai_cancel abgebrochen
con NOTIFY_ACC_CHANGED  : int64 := 18  // Accessibility-Baum eines Fensters hat sich geändert
con NOTIFY_LYRA_CONFIRM : int64 := 19  // User hat auf sys_lyra_confirm geantwortet (data = CONFIRM_*)
```

### Spawn-Flags

```lyx
con SPAWN_NONE    : int64 := 0
con SPAWN_REPLACE : int64 := 1   // Aktuellen Prozess ersetzen (exec-Äquivalent)
con SPAWN_WAIT    : int64 := 2   // Blockieren bis Kind beendet
con SPAWN_NEWENV  : int64 := 4   // Leere Umgebung (kein Erbe)
con SPAWN_NEWNS   : int64 := 8   // Neuer Dateisystem-Namespace
con SPAWN_NEWNET  : int64 := 16  // Neuer Netzwerk-Namespace
```

### getrandom-Flags

```lyx
con GRND_BLOCK    : int64 := 0   // Blockieren bis Entropie vorhanden
con GRND_NONBLOCK : int64 := 1   // ERR_AGAIN wenn keine Entropie
```

### Madvise-Hinweise

```lyx
con MADV_NORMAL     : int64 := 0
con MADV_SEQUENTIAL : int64 := 1
con MADV_RANDOM     : int64 := 2
con MADV_WILLNEED   : int64 := 3
con MADV_DONTNEED   : int64 := 4
```

### Stat-Flags

```lyx
con STAT_NOFOLLOW   : int64 := 1   // Keine Symlink-Auflösung
con STAT_EMPTY_PATH : int64 := 2   // dir_fd ist das Ziel (path = "")
```

### Content-ID-Algorithmen

```lyx
con CID_BLAKE3  : int64 := 0   // BLAKE3, 32 Bytes (Standard — schnell, sicher)
con CID_SHA256  : int64 := 1   // SHA-256, 32 Bytes (Kompatibilität)
```

### Unlink-Flags

```lyx
con UNLINK_FILE : int64 := 0   // Reguläre Datei entfernen
con UNLINK_DIR  : int64 := 1   // Leeres Verzeichnis entfernen (rmdir)
```

---

## 8. lyxc-Ziel `--target=lyxos`

```bash
lyxc myapp.lyx --target=lyxos -o myapp
```

**Was lyxc für `--target=lyxos` tut:**

1. Erzeugt ELF-64-Binary für Lyx OS (kein Linux-Syscall-ABI).
2. Ersetzt alle Builtin-Calls durch die entsprechenden `sys_*`-Stubs aus
   `lyxrt_lyxos.lyx` (wird automatisch gelinkt).
3. Keine Abhängigkeit von libc, libm, ld-linux.
4. Entry-Point: `fn main(): int64` → wird via `sys_exit(main())` gewrappt.
5. Stack-Canaries: per `sys_getrandom` initialisiert.
6. Alle von lyxc allokierten fds werden beim Prozessende durch den Kernel
   geschlossen (kein explizites `close` auf fds nötig, aber empfohlen).

**Linker-Layout (ELF):**

```
.text    ausführbarer Code
.rodata  String-Literale, Konstanten
.data    initialisierte globale Variablen
.bss     uninitalisierte globale Variablen
.note.lyx-abi   ABI-Version (major.minor), für Kernel-Kompatibilitätsprüfung
```

**Fehlerbehandlung in lyxc:**

```lyx
// lyxc generiert für --target=lyxos bei Syscall-Wrappern:
var result, err := sys_open(AT_CWD, "file.txt", O_READ, 0);
if (err != ERR_OK) {
    EPrintLn("open fehlgeschlagen");
    return 1;
}
```

---

## 9. Syscall-Nummern Übersichtstabelle (kompakt)

| Bereich | Kategorie | Anzahl |
|---------|-----------|--------|
| 0x0000–0x000D | Prozess & Threads | 14 |
| 0x0100–0x0105 | Speicher | 6 |
| 0x0200–0x0215 | Dateisystem & VFS | 22 |
| 0x0300–0x0305 | I/O & Geräte | 6 |
| 0x0400–0x040C | IPC & Synchronisation | 13 |
| 0x0500–0x0504 | Zeit | 5 |
| 0x0600–0x0609 | Netzwerk | 10 |
| 0x0700–0x0708 | Sicherheit & Capabilities | 9 |
| 0x0800–0x081F | KI & Semantik + Wissensgraph | 32 |
| 0x0900–0x090F | Lyra Agent Interface + native UI | 16 |
| 0x0A00–0x0A05 | Debug & Telemetrie | 6 |
| 0x0B00–0x0B09 | Task & Automatische Parallelität | 10 |
| 0x0C00–0x0C04 | IOFS: Island & Ocean File System | 5 |
| 0x0D00–0x0D1D | Display, Fenster, Eingabe & Lyra-GUI-Agentur | 30 |
| **Gesamt** | | **182** |

Reservierte Bereiche für spätere Erweiterungen:
- `0x000E–0x00FF`: Prozess & Threads
- `0x0106–0x01FF`: Speicher
- `0x0216–0x02FF`: Dateisystem
- `0x0813–0x08FF`: KI-Erweiterungen
- `0x090C–0x09FF`: Lyra-Erweiterungen
- `0x0A06–0x0AFF`: Debug-Erweiterungen
- `0x0B0A–0x0BFF`: Task-Erweiterungen
- `0x0C05–0x0CFF`: IOFS-Erweiterungen
- `0x0D13–0x0DFF`: Display-Erweiterungen (Color-Management, HDR, Virtual-Display)
- `0x0E00–0xFFFF`: Zukünftige Kategorien

---

---

## 10. Implementierter Ring-3 ABI (aktueller Stand)

Der vorangehende Abschnitt beschreibt den **zukünftigen** ABI-Entwurf mit hex-gruppierten Nummern. Dieser Abschnitt dokumentiert den **tatsächlich implementierten** Ring-3 Syscall-Stand in `kernel/ring3.lyx` (flaches Nummernschema 0–201).

### 10.1 Mechanismus

Ring-3-Prozesse rufen Syscalls via `SYSCALL`-Instruction auf. Der Handler `ring3_r3_deferred` in `bootloader/boot.asm` speichert den Kontext im `r3_sc_block` (physisch-feste 4 KB-Seite, auch von Ring-3 schreibbar):

```
r3_sc_block Layout (Byte-Offsets):
  +0:  nr      — Syscall-Nummer (rax beim Eintritt)
  +8:  a0      — Argument 0 (rdi)
  +16: a1      — Argument 1 (rsi)
  +24: a2      — Argument 2 (rdx)
  +32: a3      — Argument 3 (r10)
  +40: result  — Rückgabewert (Kernel → Ring-3, nach IRETQ in rdx)
  +48: rsp3    — Ring-3 RSP
  +56: rcx3    — Ring-3 RIP (= rcx nach SYSCALL)
  +64: r11     — Ring-3 RFLAGS
  +72: rbp3    — Ring-3 RBP
```

### 10.2 Rückgabe-Konvention

- Ring-3 liest das Ergebnis aus `+40 (result)` nach IRETQ in `rdx`.
- Fehler: result = `-1`; Erfolg: result = Wert ≥ 0.
- Keine dedizierten ERR\_\*-Konstanten im aktuellen Kernel — nur -1 / ≥0.

### 10.3 FD-Offset-Konvention

| Ring-3-FD | Bedeutung |
|-----------|-----------|
| 0 | Tastatur (stdin, blocking PS/2-Read) |
| 1 | stdout (vmm\_op41 → COM1 + Framebuffer) |
| 2 | stderr (reserviert) |
| ≥ 3 | VFS-FD = Ring-3-FD − 3 |

### 10.4 Syscall-Tabelle (implementiert)

| Nr | Name | Argumente (a0, a1, a2, a3) | Rückgabe | Beschreibung |
|----|------|-----------------------------|----------|--------------|
| 0 | `sys_read` | `fd, buf_uva, count` | bytes oder -1 | Lesen von fd. fd=0: blockierender PS/2-Tastatur-Read (1 Byte). fd≥3: VFS-Read. Bei Verzeichnis-FD: DirEntry-Array à 56 Byte. `buf_uva` wird via VmmPhysFromUserVirt übersetzt; large reads über Kernel-Zwischenpuffer. |
| 1 | `lyx_putchar` | `fd, char_byte, 1` | 1 | Byte auf COM1 + GOP-Framebuffer (vmm\_op41). Bei aktivem Child-Capture: Byte zusätzlich in SHM-Ringpuffer (+16). |
| 2 | `sys_open` | `path_uva, flags, mode` | r3fd+3 oder -1 | Datei im VFS öffnen. `path_uva` → physisch via VmmPhysFromUserVirt. Rückgabe = VFS-fd+3. |
| 3 | `sys_close` | `r3fd` | 0 | VFS-FD schließen (`VfsClose(r3fd − 3)`). |
| 9 | `sys_mmap` | `hint, size, prot, flags` | user\_virt | Virtuelle Seiten allozieren und in Prozess-PML4 mappen. Bump-Allokator ab USER\_HEAP\_BASE (0x10000000). |
| 24 | `sys_yield` | — | — | Asynchrones Yield: gibt Kontrolle vom Kind-Prozess an den Compositor zurück. Wird in child\_run\_init / child\_run\_once direkt abgefangen — **nicht** durch handle\_r3\_syscall. |
| 79 | `sys_getcwd` | `buf_phys, size` | len+1 | Aktuelles Arbeitsverzeichnis in buf schreiben (VfsGetCwd). |
| 80 | `sys_chdir` | `path_uva` | 0 oder -1 | Arbeitsverzeichnis wechseln (VfsChdir). |
| 81 | `sys_locale_info` | `buf_uva` | Ergebnis | Locale-Zusammenfassung in Puffer schreiben (LocaleSummary). |
| 82 | `sys_diskinfo` | — | 0 | Festplatten-Info auf COM1 + Framebuffer ausgeben (VfsDiskPrintInfoR3). |
| 83 | `sys_mkpart` | `disk_id, lba_start, sector_count` | 0 oder -1 | MBR-Partitionseintrag anlegen (VfsMkPart). |
| 84 | `sys_mkfat32` | `disk_id, lba_start, sector_count` | 0 oder -1 | Partition als FAT32 formatieren (VfsMkFat32). |
| 85 | `sys_mount` | `vol_id, disk_id, lba_start` | 0 oder -1 | Festplatte als Volume mounten (VfsMountDisk). |
| 86 | `sys_vol` | `vol_id` | 0 oder -1 | Aktives VFS-Volume wechseln; CWD → "/" (VfsSwitchVolume). |
| 87 | `sys_gpt` | `disk_id, vol_id_start` | Anzahl Partitionen oder -1 | GPT scannen, FAT32-Partitionen automatisch mounten + Infos ausgeben. |
| 88 | `sys_partinfo` | `disk_id` | 0 | Partitionstabelle mit freien Lücken ausgeben (VfsDiskMap). |
| 89 | `sys_mkfat32_part` | `disk_id, part_no` | 0 oder -1 | Partition `part_no` als FAT32 formatieren (VfsMkFat32ByPart). |
| 90 | `sys_mount_part` | `vol_id, disk_id, part_no` | 0 oder -1 | Partition `part_no` als `vol_id` mounten (VfsMountByPart). |
| 91 | `sys_spawn_child` | `path_uva, argc, argv_phys` | Exit-Code oder -1 | ELF-Binary als Kind-Prozess laden und **synchron** ausführen. AMD64-ABI-Stack (argc/argv) wird auf Kind-Stack aufgebaut. Blockiert bis zum Abschluss. |
| 92 | `sys_setenv` | `key_phys, val_phys` | 0 | Umgebungsvariable setzen (VfsEnvSet). |
| 93 | `sys_getenv` | `key_phys, buf_phys, size` | Länge oder -1 | Umgebungsvariable lesen (VfsEnvGet). |
| 94 | `sys_envlist` | — | 0 | Alle Umgebungsvariablen auf COM1 + Framebuffer ausgeben (VfsEnvList). |
| 95 | `sys_write` | `r3fd, buf_uva, count` | bytes oder -1 | In VFS-FD schreiben (VfsWrite). `buf_uva` → physisch via VmmPhysFromUserVirt. |
| 96 | `sys_rename` | `old_path_uva, new_path_uva` | 0 oder -1 | Datei/Verzeichnis umbenennen (VfsRename). |
| 97 | `sys_unlink` | `path_uva` | 0 oder -1 | Datei löschen (VfsUnlink). |
| 98 | `sys_block_open` | `disk_id, flags` | bfd+3 oder -1 | Rohes Block-Device öffnen (VfsBlockOpen). Rückgabe = Block-FD+3. |
| 99 | `sys_block_read` | `bfd, lba, count, buf_uva` | Ergebnis oder -1 | Sektoren von Block-Device in Benutzerpuffer lesen (VfsBlockRead). |
| 100 | `sys_block_write` | `bfd, lba, count, buf_uva` | Ergebnis oder -1 | Sektoren aus Benutzerpuffer auf Block-Device schreiben (VfsBlockWrite). |
| 101 | `sys_block_info` | `bfd, out_uva` | Ergebnis oder -1 | Block-Device-Info lesen: `{sector\_count(8), disk\_id(8), 512(8)}` (VfsBlockInfo). |
| 102 | `sys_gpt_create` | `disk_id, nsectors, nparts, parts_uva` | 0 oder -1 | GPT-Partitionstabelle anlegen. `parts_uva` → Array von `{lba_start, lba_end}`-Paaren (VfsGptCreate). |
| 110 | `sys_win_create` | `x, y, w, h` | win\_id oder -1 | Fenster anlegen, SHM-Framebuffer allozieren (w×h×4 Byte physisch kontiguös). |
| 111 | `sys_win_destroy` | `win_id` | 0 oder -1 | Fenster-Slot freigeben (WIN\_OFF\_STATE → 0). |
| 112 | `sys_win_raise` | `win_id` | 0 oder -1 | Fenster in den Vordergrund bringen (Z := max\_Z + 1). |
| 113 | `sys_win_move` | `win_id, x, y` | 0 oder -1 | Fensterposition in der Fenster-Tabelle aktualisieren. |
| 114 | `sys_win_resize` | `win_id, new_w, new_h` | 0 oder -1 | Fenster-Metadaten aktualisieren (kein FB-Realloc). |
| 115 | `sys_win_get_fb` | `win_id` | user\_virt oder -1 | Fenster-Framebuffer (SHM) in Prozess-PML4 mappen; liefert user-virtuelle Adresse. |
| 116 | `sys_vsync_wait` | — | 0 | Busy-wait bis PIT-Frame-Counter sich erhöht (~10 ms bei 100 Hz, vmm\_op48). |
| 117 | `sys_time_ns` | — | Nanosekunden | Monotone Zeit in ns: PIT-Frame-Counter × 10.000.000. |
| 118 | `sys_shm_create` | `size` | shm\_id (0–63) oder -1 | Physisch kontiguöse SHM-Seiten allozieren; liefert shm\_id. |
| 119 | `sys_shm_map` | `shm_id` | user\_virt oder -1 | SHM in Prozess-Adressraum mappen; Ref-Count erhöhen. |
| 120 | `sys_shm_unmap` | `shm_id` | 0 | Ref-Count verringern; Slot freigeben wenn Ref-Count = 0. |
| 121 | `sys_event_send` | `pid, type, a, b` | 0 | Event (32 Byte: type/a/b/c) in Ring-Puffer von `pid` schreiben. Max. 8 PIDs × 16 Slots. |
| 122 | `sys_event_recv` | `out_buf_uva` | 0 oder -1 | Ältestes Event für aktuelle PID lesen: `{type(8), a(8), b(8), c(8)}`. |
| 124 | `sys_set_console` | `pid, shm_id` | 0 | PutCh-Ausgabe von `pid` in SHM-Ringpuffer umleiten. `shm_id = -1` → trennen. |
| 125 | `sys_fb_map_user` | `fb_base, fb_width, fb_height, fb_stride` | fb\_phys | GOP-Framebuffer-Seiten user-zugänglich in Prozess-PML4 mappen (identity-map). |
| 126 | `sys_get_mouse_x` | — | X | PS/2-Maus X-Position (absolut, nach Bounds geclippt, vmm\_op50). |
| 127 | `sys_get_mouse_y` | — | Y | PS/2-Maus Y-Position (vmm\_op51). |
| 128 | `sys_get_mouse_btn` | — | Buttons | PS/2-Maus Tastenstand (vmm\_op52). |
| 129 | `sys_set_mouse_bounds` | `max_x, max_y` | 0 | Maus-Koordinatengrenze setzen (vmm\_op54/55). |
| 130 | `sys_win_get_table_phys` | — | phys | Physische Basisadresse der Fenster-Tabelle (Compositor-Direktzugriff). |
| 131 | `sys_kbd_poll` | — | char oder 0 | Non-blocking PS/2-Tastaturlesen (vmm\_op28). 0 = keine Taste verfügbar. |
| 132 | `sys_event_recv_pid` | `pid_idx, out_buf_uva` | 0 oder -1 | Event für bestimmten PID-Slot lesen (für Compositor-seitige Abfrage fremder PIDs). |
| 133 | `sys_envlistbuf` | `buf_uva, size` | bytes | Alle Env-Vars als `KEY=VAL\n` in Benutzerpuffer kopieren (VfsEnvListBuf). |
| 134 | `sys_rtc_read` | — | `(Stunden<<8)\|Minuten` | RTC-Zeit lesen, binär, 24h (vmm\_op61). |
| 135 | `sys_fstat` | `r3fd, stat_uva` | 0 oder -1 | Datei-Stat auf offenem FD (VfsFstat): `+0=Größe(8), +8=Typ(8; 0=Datei/1=Dir), +16=Cluster(8)`. |
| 136 | `sys_getpid` | — | PID | Aktuelle Scheduler-PID zurückgeben (vmm\_op49). |
| 137 | `sys_set_child_out` | `shm_id` | 0 | SHM für Child-stdout-Capture registrieren. Capture ist aktiv während SysSpawnChild; -1 deaktiviert. |
| 138 | `sys_rtc_datetime` | — | `(fat32\_date<<16)\|fat32\_time` | RTC als FAT32-Format lesen (vmm\_op62). date: Bits[15:9]=Jahr−1980, [8:5]=Monat, [4:0]=Tag. time: Bits[15:11]=Stunden, [10:5]=Minuten, [4:0]=Sekunden/2. |
| 139 | `sys_mkdir` | `path_uva` | 0 oder -1 | Verzeichnis anlegen (VfsMkdirPath). |
| 140 | `sys_utime_fd` | `r3fd, mtime` | 0 | Mtime auf offenem FD setzen (VfsUtimeFd). `mtime` im FAT32-Format wie sys\_rtc\_datetime. |
| 200 | `sys_spawn_async` | `path_uva` | slot (0..1) oder -1 | ELF als **asynchrones** Kind laden und bis zum ersten sys\_yield (nr=24) ausführen. Liefert Slot-Index. Max. 2 gleichzeitige async-Kinder. |
| 201 | `sys_run_child` | `slot` | 0 (yield) oder Exit-Code | Asynchrones Kind bis zum nächsten sys\_yield oder Beendigung fortsetzen. Rückgabe 0 = Kind hat geyldet; >0 = Exit-Code. |

### 10.5 SHM-Ringpuffer-Format

Für `sys_set_console` und `sys_set_child_out` gilt folgendes Layout der SHM-Seite:

```
+0:  write_pos (int64) — nächste Schreibposition mod 4080
+8:  (reserviert, 8 Byte)
+16: data[4080]        — Byte-Ringpuffer (rohe Zeichen-Ausgabe)
```

### 10.6 Async-Child-Slots

| Slot | Physische Ladeadresse | PHYS-Konstante |
|------|----------------------|----------------|
| 0 | 0x1D00000 (29 MB) | ACHILD0\_PHYS |
| 1 | 0x1E00000 (30 MB) | ACHILD1\_PHYS |

Jeder Slot hat einen 64-Byte-Kontextblock (achild\_ctx): `{rsp(8), rcx(8), r11(8), rbp(8), cr3(8), heap_virt(8), status(8)}`. status: 0=frei, 1=aktiv, -1=beendet.

### 10.7 Abweichungen vom Future-ABI

| Aspekt | Future-ABI (Abschnitte 2–9) | Implementierter ABI (aktuell) |
|--------|----------------------------|-------------------------------|
| Fehlercodes | `rax = ERR_*` (32 Konstanten) | Nur -1 / ≥0, keine dedizierten Codes |
| Zwei-Register-Rückgabe | `rax = Fehler`, `rdx = Wert` | Einzel-Register: `result` in rdx; rax immer 0 |
| Syscall-Nummernschema | 0x0000–0x0DFF (hex-Gruppen) | Flach: 0–201 |
| dir\_fd / AT\_CWD | Immer erstes Argument | Pfad-Syscalls ohne dir\_fd — CWD implizit |
| FD-Offset | VFS-FD 0 = stdin direkt | Ring-3-FD = VFS-FD + 3 (fd 0–2 reserviert) |
| CLOEXEC-Default | CLOEXEC per Default | Keine FD-Vererbungs-Kontrolle implementiert |
| sys\_mmap | Nr. 0x0100 | Nr. 9 |

---

*Dokument-Version: 1.5 | Erstellt: 2026-06-09 | Aktualisiert: 2026-06-17 | lyxc-Ziel: `--target=lyxos`*
