# Lyx OS Backend — Vollständiger Implementierungsfahrplan

**lyxc-Ziel:** `--target=lyxos`  
**ABI-Referenz:** `work/lyxos/syscalls.md` (ABI v1.0, 137 Syscalls)  
**Stand:** v1.0.1D  
**Stand:** v0.9.9A  
**Branch-Namensschema:** `feat/lyxos-lx<nn>-<kürzel>`

---

## Zwei LBF-Konzepte — Begriffsklärung

Dieses Dokument verwendet „LBF" für zwei verschiedene Dinge:

| Begriff | Magic | Format | Zweck |
|---------|-------|--------|-------|
| **LBF-IR** (LX-00/LX-24) | `LBF\0` (0x4C 0x42 0x46 0x00) | IR-Opcodes (kein Maschinencode) | Testen auf Linux ohne echten LyxOS-Kernel |
| **LBF-Nativ** (LX-25–LX-36) | `LYX!` (0x4C 0x59 0x58 0x21) | Nativer x86-64/ARM64-Maschinencode, 4KB-Page-aligned | Produktionsformat für echten LyxOS-Kernel |

**Testpipeline (Phase 0–7):**
```
lyxc --target=lyxos --emit=lbf prog.lyx -o prog.lbf   → LBF-IR-Bytecode
lbf_run prog.lbf                                        → Interpreter auf Linux
```

**Produktionspfad (Phase 8):**
```
lyxc --target=lyxos prog.lyx -o prog.lbf               → LBF-Nativ (LYX!-Format)
lbf_loader prog.lbf                                     → POSIX-Loader (mmap + Sprung)
```

---

## Work-Package-Übersicht

| LX   | Titel                                          | Phase | Prio    | Abhängigkeit     | Status |
|------|------------------------------------------------|-------|---------|------------------|--------|
| LX-00 | `--emit=lbf` IR-Serialisierer (lbf_writer)   | 0     | Hoch    | —                | ✅ Fertig |
| LX-01 | Target-Registrierung & ELF-Grundgerüst        | 1     | Hoch    | —                | ✅ Erledigt |
| LX-02 | emit_lyxos.lyx Codegen-Skelett                | 1     | Hoch    | LX-01            | ✅ Erledigt |
| LX-03 | Prozess-Lebenszyklus & Entry-Point            | 1     | Hoch    | LX-02            | ✅ Erledigt |
| LX-04 | Basis-I/O (PrintStr/PrintInt → sys_write)     | 1     | Hoch    | LX-03            | ✅ Erledigt |
| LX-05 | Speicherverwaltung (sys_mmap / sys_munmap)     | 1     | Hoch    | LX-03            | ✅ Erledigt |
| LX-06 | Vollständiges Dateisystem VFS (0x0200–0x0215) | 2     | Hoch    | LX-04            | ✅ Erledigt |
| LX-07 | I/O-Geräte & Poll (0x0300–0x0305)             | 2     | Mittel  | LX-06            | ✅ Fertig |
| LX-08 | Netzwerk (0x0600–0x0609)                      | 2     | Mittel  | LX-06            | ✅ Fertig |
| LX-09 | Prozess & Threads vollständig (0x0000–0x000D) | 3     | Hoch    | LX-05            | ✅ Fertig |
| LX-10 | IPC & Synchronisation (0x0400–0x040C)         | 3     | Mittel  | LX-09            | ✅ Fertig |
| LX-11 | Zeit-Syscalls (0x0500–0x0504)                 | 3     | Mittel  | LX-03            | ✅ Fertig |
| LX-12 | Capabilities + Pledge + Unveil (0x0700–0x0708)| 4     | Hoch    | LX-09            | ✅ Fertig |
| LX-13 | Task-Scheduler & `@parallel` (0x0B00–0x0B09)  | 4     | Mittel  | LX-09            | ✅ Fertig |
| LX-14 | KI-Basis: Model + Context + Infer (0x0800–0x0806) | 5  | Mittel | LX-05            | ✅ Fertig |
| LX-15 | KI-Embedding & Vektorindex (0x0807–0x080C)    | 5     | Mittel  | LX-14            | ✅ Fertig |
| LX-16 | Semantisches Paging & Wissensgraph (0x080D–0x0812) | 5 | Niedrig | LX-15          | ✅ Fertig |
| LX-17 | Lyra Agent Interface (0x0900–0x090B)          | 5     | Niedrig | LX-16            | ✅ Fertig |
| LX-18 | IOFS: Island & Ocean FS (0x0C00–0x0C04)       | 6     | Niedrig | LX-12            | ✅ Fertig |
| LX-19 | lyxrt_lyxos.lyx Runtime-Library               | 7     | Hoch    | LX-05            | ✅ Fertig |
| LX-20 | std/io.lyx + std/alloc.lyx lyxos-Adaptation   | 7     | Hoch    | LX-19            | ✅ Fertig |
| LX-21 | Zwei-Register-Rückgabe `var val, err :=`      | 7     | Mittel  | LX-02            | ✅ Fertig |
| LX-22 | Debug & Telemetrie (0x0A00–0x0A05)            | 7     | Niedrig | LX-03            | ✅ Fertig |
| LX-23 | Integrations-Testsuite & Singularitätsprüfung | 7     | Hoch    | LX-20, LX-24     | ✅ Fertig |
| LX-24 | lbf_run — IR-Bytecode-Interpreter             | 0     | Hoch    | LX-00, LX-04     | ✅ Erledigt |
| LX-25 | LBF-Nativ: Block Header I/O                   | 8     | Hoch    | —                | ✅ Fertig |
| LX-26 | LBF-Nativ: Genesis-Content Serializer         | 8     | Hoch    | LX-25            | ✅ Fertig |
| LX-27 | LBF-Nativ: TLV-Framework                      | 8     | Hoch    | LX-26            | ✅ Fertig |
| LX-28 | LBF-Nativ: Section Block Emitter              | 8     | Hoch    | LX-25            | ✅ Fertig |
| LX-29 | LBF-Nativ: Supply Chain Security              | 8     | Hoch    | LX-25–LX-27      | Offen |
| LX-30 | LBF-Nativ: lyxc-Backend `--target=lyxos` → LYX! | 8  | Hoch    | LX-25–LX-29      | Offen |
| LX-31 | LBF-Nativ: lbf_loader POSIX-Loader           | 8     | Hoch    | LX-25, LX-28, LX-29 | Offen |
| LX-32 | LBF-Nativ: lbf_import IOFS-Import            | 8     | Hoch    | LX-25–LX-29, IOFS| Offen |
| LX-33 | LBF-Nativ: Dependency Resolver               | 8     | Hoch    | LX-32, IOFS      | Offen |
| LX-34 | LBF-Nativ: Zero-Load Executor (Kernel)       | 8     | Hoch    | LX-32, LX-33, IOFS | Offen |
| LX-35 | LBF-Nativ: lbf-dump Inspection Tool         | 8     | Mittel  | LX-25–LX-29      | Offen |
| LX-36 | LBF-Nativ: Lifecycle Descriptor              | 8     | Hoch    | LX-27, LX-30, LX-34 | Offen |

---

## Phase 0 — LBF-IR-Testinfrastruktur

*Ermöglicht das Testen aller LX-01 bis LX-23 Pakete auf POSIX-Linux ohne echten LyxOS-Kernel.*

### LX-00 · `--emit=lbf` IR-Serialisierer

**Priorität:** Hoch  
**Datei:** `src/lbf_writer.lyx`

**Aufgabe**  
lyxc um den Ausgabemodus `--emit=lbf` erweitern: statt Maschinencode wird das
kompilierte IR direkt als LBF-IR-Bytecode-Datei serialisiert.

**LBF-IR-Dateiformat (Magic `LBF\0`):**

```
Offset  Größe  Feld
──────  ─────  ──────────────────────────────────────────
0       4      Magic: 'L' 'B' 'F' 0x00
4       2      version: u16le  = 1
6       2      flags: u16le    (bit0=debug, bit1=stripped)
8       4      entry: u32le    – Index der main()-Funktion in FuncTable
12      4      strPoolOff: u32le
16      4      strPoolLen: u32le
20      4      funcTableOff: u32le
24      4      funcCount: u32le
28      4      instrOff: u32le
32      4      instrCount: u32le
36      4      relocOff: u32le
40      4      relocCount: u32le
44      20     reserved (Nullen)
── String-Pool (UTF-8, kein Null-Terminator; Längen via Referenz) ──
── FuncTable (funcCount × FuncEntry) ──────────────────────────────
  FuncEntry:  nameOff:u32, nameLen:u16, firstInstr:u32, instrCount:u32  (je 14 B)
── InstrArray (instrCount × Instr) ────────────────────────────────
  Instr:  opcode:u16, dest:u16, a:u32, b:u32, imm:i64   = 20 Bytes
── RelocTable (relocCount × Reloc) ────────────────────────────────
  Reloc:  instrIdx:u32, field:u8, targetFuncIdx:u32      = 9 Bytes
```

Der Opcode-Raum entspricht dem internen `IRO_*`-Set von lyxc.
LyxOS-Syscalls erscheinen als `IRO_CALL_BUILTIN` mit der LyxOS-Syscall-Nummer im `imm`-Feld.

**Änderungen in `src/lyxc.lyx`:**
- `parseLongFlag`: `--emit=lbf` → `self.emitMode := EMIT_LBF`
- `emitCode`: wenn `emitMode == EMIT_LBF`, direkt IR serialisieren statt Codegen
- Neue Datei `src/lbf_writer.lyx`: schreibt IR → `.lbf`

**Abnahme**
- `./lyxc --target=lyxos --emit=lbf tests/lyxos/lx03_entry.lyx -o /tmp/entry.lbf` — kein Fehler
- `xxd /tmp/entry.lbf | head -1` → Magic `4c 42 46 00`
- `.lbf`-Datei enthält mindestens eine Funktion (`main`) in der FuncTable
- `./lyxc --target=x86_64 --emit=lbf` → Compile-Fehler: „emit=lbf nur für lyxos-Target"

---

### LX-24 · lbf_run — IR-Bytecode-Interpreter

**Priorität:** Hoch  
**Status:** ✅ Erledigt (`src/tools/lbf_run.lyx`)  
**Abhängigkeit:** LX-00 (lbf_writer)

**Aufgabe**  
Den IR-Interpreter `lbf_run` in Lyx implementieren: LBF-IR-Datei laden,
Opcodes interpretieren, LyxOS-Syscall-Nummern auf POSIX-Linux-Äquivalente mappen.

`lbf_run` kompiliert selbst zu `--target=x86_64` und läuft auf normalem Linux.
Es ist das primäre Testfahrzeug für alle LX-01 bis LX-23 Pakete.

**Syscall-Mapping (LyxOS → POSIX Linux):**

| LyxOS-Nr | Name              | Linux-Nr | Linux-Name     |
|----------|-------------------|----------|----------------|
| 0x0002   | `sys_exit_group`  | 231      | `exit_group`   |
| 0x000C   | `sys_getrandom`   | 318      | `getrandom`    |
| 0x0100   | `sys_mmap`        | 9        | `mmap`         |
| 0x0101   | `sys_munmap`      | 11       | `munmap`       |
| 0x0200   | `sys_open`        | 257      | `openat`       |
| 0x0201   | `sys_close`       | 3        | `close`        |
| 0x0202   | `sys_read`        | 0        | `read`         |
| 0x0203   | `sys_write`       | 1        | `write`        |
| 0x0204   | `sys_seek`        | 8        | `lseek`        |
| 0x0205   | `sys_stat`        | 262      | `newfstatat`   |
| 0x0206   | `sys_fstat`       | 5        | `fstat`        |
| 0x020B   | `sys_dup`         | 292      | `dup3`         |
| 0x020C   | `sys_pipe`        | 293      | `pipe2`        |
| 0x0211   | `sys_getcwd`      | 79       | `getcwd`       |
| 0x0300   | `sys_poll`        | 271      | `ppoll`        |
| 0x0500   | `sys_clock_get`   | 228      | `clock_gettime`|
| 0x0600   | `sys_socket`      | 41       | `socket`       |
| 0x0601   | `sys_bind`        | 49       | `bind`         |
| 0x0602   | `sys_listen`      | 50       | `listen`       |
| 0x0603   | `sys_accept`      | 288      | `accept4`      |
| 0x0604   | `sys_connect`     | 42       | `connect`      |
| 0x0605   | `sys_sendmsg`     | 46       | `sendmsg`      |
| 0x0606   | `sys_recvmsg`     | 47       | `recvmsg`      |
| 0x0609   | `sys_shutdown`    | 48       | `shutdown`     |

Syscalls ohne POSIX-Äquivalent (KI 0x0800+, Lyra 0x0900+, IOFS 0x0C00+)
→ `lbf_run` gibt `ERR_NOTSUP` zurück. Tests für diese Pakete prüfen explizit
`ERR_NOTSUP`-Behandlung.

**Rückgabe-Konvention:** LyxOS gibt `(rax=err, rdx=val)` zurück. `lbf_run` simuliert
das intern als zwei Slots: `slot_err` und `slot_val`.

**Abnahme**
- `./lbf_run /tmp/entry.lbf` → Exit-Code 42
- `./lbf_run /tmp/io.lbf` → stdout: `Hello Lyx OS\n`
- `./lbf_run /tmp/alloc.lbf` → kein Segfault, poke8/peek8 korrekt
- `./lbf_run /tmp/fs.lbf` → Datei lesen und Inhalt ausgeben
- `./lbf_run /tmp/net.lbf` → TCP-Echo-Roundtrip

---

## Phase 1 — Foundation

### LX-01 · Target-Registrierung & ELF-Grundgerüst ✅

**Datei:** `src/backend/lyxos/emit_lyxos.lyx`

Target `--target=lyxos` registriert. ELF-Writer mit `.note.lyx-abi`-Section
(8 Bytes: `major=1, minor=0`). Struktur: `.text` (PT_LOAD RX), `.data` (PT_LOAD RW),
`.note.lyx-abi` (PT_NOTE).

---

### LX-02 · emit_lyxos.lyx Codegen-Skelett ✅

**Datei:** `src/backend/lyxos/emit_lyxos.lyx`

LyxOS-ABI (aus syscalls.md §2.2):
```
Eingabe:  rax=Syscall-Nr, rdi=a1, rsi=a2, rdx=a3, r10=a4, r8=a5, r9=a6
Ausgabe:  rax=Fehlercode, rdx=Rückgabewert
Clobbered: rcx, r11, rdi, rsi, r10, r8, r9
Callee-saved: rbx, rbp, r12, r13, r14, r15
```

VMT-Methoden-Anzahl ist gerade (Parity-Constraint). Slot-Layout: `slotOff(n) = -(n+1)*8` relativ zu rbp.

---

### LX-03 · Prozess-Lebenszyklus & Entry-Point ✅

**Datei:** `src/backend/lyxos/emit_lyxos.lyx` — `emitStartStub()`

`_start`: XOR rbp; Canary via `sys_getrandom` (0x000C); CALL main; Exit via `sys_exit_group` (0x0002).

---

### LX-04 · Basis-I/O — sys_write / sys_read ✅

**Datei:** `src/backend/lyxos/emit_lyxos.lyx`

`PrintStr` → `sys_write(1, slot0, slot1)` (0x0203).  
`PrintInt` → inline itoa + `sys_write`.  
CONST_STR string-pool mit rip-relativer LEA.

---

### LX-05 · Speicherverwaltung — sys_mmap / sys_munmap ✅

**Datei:** `src/backend/lyxos/emit_lyxos.lyx`

`alloc(n)` → `sys_mmap(0, size, PROT_RW, MAP_PRIVATE|MAP_ANONYMOUS)` (0x0100), Rückgabe in `rdx`.  
`free(ptr)` → `sys_munmap(ptr, size)` (0x0101).

---

## Phase 2 — Dateisystem & Netzwerk

### LX-06 · Vollständiges Dateisystem VFS (0x0200–0x0215) ✅

**Dateien:** `src/backend/lyxos/emit_lyxos.lyx`, `src/ir_lower.lyx`, `src/std/lyxos/fs.lyx`

22 VFS-Syscalls als Compiler-Builtins (IDs 20–41). `src/std/lyxos/fs.lyx` enthält
nur Konstanten (`AT_CWD`, `O_*`, `SEEK_*`, `S_*`, `CID_*`, `STAT_SIZE`) — keine
Stubs. Alle 22 Funktionsnamen in `sema.lyx` via `_regBuiltin()` registriert.

| Syscall | Nr | Signatur |
|---------|-----|----------|
| `sys_open` | 0x0200 | `(dir_fd, path, flags, mode) → fd` |
| `sys_close` | 0x0201 | `(fd) → —` |
| `sys_read` | 0x0202 | `(fd, buf, count) → bytes` |
| `sys_write` | 0x0203 | `(fd, buf, count) → bytes` |
| `sys_seek` | 0x0204 | `(fd, offset, whence) → pos` |
| `sys_stat` | 0x0205 | `(dir_fd, path, stat_out, flags) → —` |
| `sys_fstat` | 0x0206 | `(fd, stat_out) → —` |
| `sys_mkdir` | 0x0207 | `(dir_fd, path, mode) → —` |
| `sys_unlink` | 0x0208 | `(dir_fd, path, flags) → —` |
| `sys_rename` | 0x0209 | `(old_dir, old_path, new_dir, new_path) → —` |
| `sys_readdir` | 0x020A | `(fd, buf, buf_size) → bytes` |
| `sys_dup` | 0x020B | `(fd, flags) → fd` |
| `sys_pipe` | 0x020C | `(read_fd_out, write_fd_out, flags) → —` |
| `sys_truncate` | 0x020D | `(fd, size) → —` |
| `sys_sync` | 0x020E | `(fd) → —` |
| `sys_mount` | 0x020F | `(dev_fd, mnt_dir, mnt_path, fs_type, flags) → —` |
| `sys_umount` | 0x0210 | `(dir_fd, path, flags) → —` |
| `sys_getcwd` | 0x0211 | `(buf, size) → bytes` |
| `sys_chdir` | 0x0212 | `(dir_fd, path) → —` |
| `sys_symlink` | 0x0213 | `(target, dir_fd, link_path) → —` |
| `sys_readlink` | 0x0214 | `(dir_fd, path, buf, size) → bytes` |
| `sys_content_id` | 0x0215 | `(fd, algo, out, out_len) → bytes` |

**Abnahme**
- Datei öffnen, lesen, schließen — Inhalt korrekt
- `sys_mkdir`, `sys_unlink`, `sys_stat` korrekt
- `AT_CWD`-Verwendung für relative Pfade
- Verifiziert: 12 syscall-Instruktionen im Binary; 0x0200 ×2, 0x0202, 0x0203, 0x0201, 0x0204

---

### LX-07 · I/O-Geräte & Poll (0x0300–0x0305)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/device.lyx`

`sys_poll`, `sys_ioctl`, `sys_mmap_device`, `sys_irq_bind`, `sys_port_in`, `sys_port_out`
als Builtins. `sys_port_in/out` erfordern `CAP_IOPORT`.

```lyx
type PollEvent = flat struct {
    fd:      int64;
    events:  uint32;
    revents: uint32;
};
```

**Abnahme**
- `sys_poll` auf Pipe-fd: `POLL_IN` erscheint wenn Daten vorhanden
- `sys_poll` mit `timeout_ns=0` kehrt sofort zurück
- `sys_ioctl` gibt `ERR_INVAL` bei unbekanntem Request-Code

---

### LX-08 · Netzwerk (0x0600–0x0609)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/net.lyx`

| Syscall | Nr | Anmerkung |
|---------|-----|-----------|
| `sys_socket` | 0x0600 | `AF_INET=2, AF_INET6=10, AF_UNIX=1` |
| `sys_bind` | 0x0601 | |
| `sys_listen` | 0x0602 | |
| `sys_accept` | 0x0603 | CLOEXEC implizit |
| `sys_connect` | 0x0604 | Blockiert bis SYN-ACK |
| `sys_sendmsg` | 0x0605 | Scatter/Gather |
| `sys_recvmsg` | 0x0606 | `MSG_PEEK=1, MSG_WAITALL=2` |
| `sys_setsockopt` | 0x0607 | |
| `sys_getsockopt` | 0x0608 | |
| `sys_shutdown` | 0x0609 | `SHUT_READ=0, SHUT_WRITE=1, SHUT_RDWR=2` |

**Abnahme**
- TCP-Echo-Server + TCP-Client: "ping" → "pong"
- `AF_UNIX`-Socket zwischen zwei Prozessen
- `sys_poll` auf Socket-fd: `POLL_IN` nach eingehender Verbindung

---

## Phase 3 — Prozesse & IPC

### LX-09 · Prozess & Threads (0x0000–0x000D)

**Priorität:** Hoch  
**Datei:** `src/std/lyxos/process.lyx`

`sys_spawn` (0x0003), `sys_thread_spawn` (0x0004), `sys_wait` (0x0005),
`sys_getpid` (0x0006), `sys_gettid` (0x0007), `sys_yield` (0x0008),
`sys_sleep_ns` (0x0009), `sys_priority` (0x000A), `sys_signal_mask` (0x000B).

Kein `fork()` — `sys_spawn` ist das Äquivalent zu `posix_spawn`/`CreateProcess`.

```lyx
type SpawnOpts = flat struct {
    flags: int64; cwd_fd: int64; stdin_fd: int64; stdout_fd: int64;
    stderr_fd: int64; extra_fds: int64; extra_fd_count: int64;
    stack_size: int64; priority: int64;
};
```

**Abnahme**
- `sys_spawn` → neuer Prozess, Exit-Code via `sys_wait`
- `sys_thread_spawn` → Thread läuft parallel, schreibt Ergebnis
- `sys_getpid` / `sys_gettid` unterscheiden sich in Spawn-Thread
- `sys_sleep_ns(100_000_000)` schläft ~100 ms

---

### LX-10 · IPC & Synchronisation (0x0400–0x040C)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/ipc.lyx`

Mutex (0x0400–0x0401), Semaphor (0x0402–0x0405), Channel — Mach-inspiriert
(0x0406–0x0408), Notification-Queue (0x0409–0x040B), Futex (0x040C).

`sys_channel_*` ersetzt Unix-Pipes für strukturierten IPC. `sys_notify_*` ersetzt Signale.

```lyx
var fds: int64 := sys_channel_create(0);
var send_fd: int64 := fds >> 32;
var recv_fd: int64 := fds & 0xFFFFFFFF;
```

**Abnahme**
- Producer-Consumer via Semaphor — korrekte Synchronisation
- Mutex schützt kritischen Abschnitt zwischen 4 Threads
- Channel überträgt 1024-Byte-Nachricht mit angehängtem fd

---

### LX-11 · Zeit-Syscalls (0x0500–0x0504)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/time.lyx`

`sys_clock_get` (0x0500), `sys_clock_set` (0x0501), `sys_timer_create` (0x0502),
`sys_timer_set` (0x0503), `sys_timer_wait` (0x0504).

`CLOCK_REAL=0`, `CLOCK_MONO=1`, `CLOCK_CPU=2`, `CLOCK_THREAD=3`.

```lyx
type TimeSpec = flat struct { sec: int64; nsec: int64; };
```

**Abnahme**
- `sys_clock_get(CLOCK_MONO, &ts)` → monoton steigende Werte
- Periodischer Timer 10 ms feuert via `sys_notify_wait`

---

## Phase 4 — Sicherheit & Parallelismus

### LX-12 · Capabilities + Pledge + Unveil (0x0700–0x0708)

**Priorität:** Hoch  
**Datei:** `src/std/lyxos/security.lyx`

`sys_cap_create` (0x0700), `sys_cap_restrict` (0x0701), `sys_cap_rights` (0x0702),
`sys_pledge` (0x0703), `sys_unveil` (0x0704).

Pledge-Promises: `stdio`, `rpath`, `wpath`, `cpath`, `exec`, `net`, `thread`,
`memory`, `device`, `ai`, `lyra`, `admin`.

Integration in lyxc: `@capabilities`-Annotation → automatisch `sys_pledge`-Call.

**Abnahme**
- `sys_pledge("stdio", "")` → nachfolgender `sys_open` → `ERR_CAPVIOL`
- `sys_unveil("/tmp", "rw")` → `sys_open("/etc/passwd")` → `ERR_NOENT`
- lyxc erzeugt für `@capabilities("stdio")` automatisch `sys_pledge("stdio", "")`

---

### LX-13 · Task-Scheduler & `@parallel` (0x0B00–0x0B09)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/task.lyx`

`sys_task_spawn` (0x0B00), `sys_task_await` (0x0B01), `sys_task_group_create` (0x0B03),
`sys_task_group_add` (0x0B04), `sys_task_group_await` (0x0B05),
`sys_cpu_count` (0x0B06), `sys_affinity_hint` (0x0B08).

`@parallel`-Compiler-Annotation für datenparallele Schleifen:
```lyx
@parallel for i in range 0..1000 {
    result[i] := compute(data[i]);
}
```

**Abnahme**
- Task-Group mit 8 Tasks, korrekte Ergebnisse, Laufzeit ≈ 1/N × sequentiell
- `@parallel` mit Daten-Abhängigkeit → Compile-Fehler

---

## Phase 5 — KI-Primitiven

### LX-14 · KI-Basis: Model + Context + Infer (0x0800–0x0806)

**Priorität:** Mittel  
**Datei:** `src/std/lyxos/ai.lyx`

`sys_ai_model_load` (0x0800), `sys_ai_model_unload` (0x0801), `sys_ai_model_info` (0x0802),
`sys_ai_ctx_create` (0x0803), `sys_ai_ctx_destroy` (0x0804),
`sys_ai_infer` (0x0805, async), `sys_ai_infer_sync` (0x0806, blockierend).

```lyx
type AiInferOpts = flat struct {
    max_tokens: int64; temperature: f32; top_p: f32;
    seed: int64; stop_tokens: int64; flags: int64; timeout_ns: int64;
};
```

Ohne KI-Modul → alle 0x0800-Syscalls → `ERR_NOTSUP` (graceful behandeln).

**Abnahme**
- `sys_ai_model_load` → Model-fd (oder `ERR_NOTSUP`)
- `sys_ai_infer_sync` → Antwort in buf
- `sys_ai_infer` async → Job-fd; `sys_poll(job_fd, POLL_IN, -1)` gibt nach Completion zurück

---

### LX-15 · KI-Embedding & Vektorindex (0x0807–0x080C)

**Priorität:** Mittel

`sys_ai_embed` (0x0807), `sys_ai_token_count` (0x0808), `sys_ai_search` (0x0809),
`sys_ai_index_create` (0x080A), `sys_ai_index_insert` (0x080B), `sys_ai_index_delete` (0x080C).

**Abnahme**
- "Hallo" und "Hi" → Cosine-Similarity > 0.8; "Hallo" und "Mathematik" < 0.3
- 100 insertierte Einträge → `sys_ai_search` findet korrekte Top-5

---

### LX-16 · Semantisches Paging & Wissensgraph (0x080D–0x0812)

**Priorität:** Niedrig

`sys_sem_annotate` (0x080D), `sys_sem_query` (0x080E),
`sys_graph_node_create` (0x080F), `sys_graph_edge_add` (0x0810),
`sys_graph_edge_remove` (0x0811), `sys_graph_query` (0x0812).

`GRAPH_AUTO_EMBED=2` → automatisch `sys_ai_embed` beim fd-Close.

---

### LX-17 · Lyra Agent Interface (0x0900–0x090B)

**Priorität:** Niedrig  
**Datei:** `src/std/lyxos/lyra.lyx`

`sys_intent_submit` (0x0900), `sys_intent_wait` (0x0901),
`sys_memory_store` (0x0902), `sys_memory_recall` (0x0903),
`sys_context_push` (0x0904), `sys_context_pop` (0x0905),
`sys_timeline_query` (0x0906), `sys_dream_register` (0x0907).

Nur mit `sys_pledge(... "lyra" ...)` nutzbar. Dream-Callbacks nur in CPU-Idle-Zyklen.

---

## Phase 6 — IOFS

### LX-18 · IOFS: Island & Ocean FS (0x0C00–0x0C04)

**Priorität:** Niedrig  
**Datei:** `src/std/lyxos/iofs.lyx`

`sys_iofs_mount` (0x0C00), `sys_iofs_compact` (0x0C01), `sys_iofs_page_info` (0x0C02),
`sys_iofs_sandbox_enter` (0x0C03), `sys_iofs_sandbox_exit` (0x0C04).

`sys_iofs_sandbox_enter` erfordert `CAP_ADMIN`.

```lyx
type IofsPageHeader = @big_endian flat struct {
    page_id: uint64; type_flags: uint64; payload_sz: uint32;
    edge_count: uint16; reserved: uint16; ts_create: int64;
    ts_modify: int64; ts_access: int64; crc32: uint32; padding: [52]uint8;
};
```

---

## Phase 7 — Stdlib & Integration

### LX-19 · lyxrt_lyxos.lyx Runtime-Library ✅ Fertig — v0.9.5B

**Datei:** `src/std/lyxos/lyxrt.lyx`  
**Test:** `tests/lx19_lyxrt_test.lyx`

Implementiert (`import src.std.lyxos.lyxrt;`):

| Funktion | Beschreibung |
|---|---|
| `alloc(size)` | Bump-Pointer Arena auf `mmap` (LyxOS: 0x0100), 64 MB/Chunk, mit Fehlerbehandlung |
| `free(ptr, size)` | No-op — Arena wird beim Prozess-Exit freigegeben |
| `rt_panic(msg, len)` | `sys_write(2, msg, len)` + `sys_exit_group(1)` |

Hinweise:
- `_start` + Stack-Canary sind bereits in `emitStartStub()` (emit_lyxos.lyx) als Maschinencode eingebettet — gehören nicht zur Bibliothek
- `panic` ist ein Lyx-Keyword (TK_PANIC); deshalb `rt_panic` als Name
- Auto-Link (implizites `import` bei `--target=lyxos`) ist nicht implementiert — bleibt für LX-23
- Singularität S1==S2 nach Hinzufügen bestätigt

---

### LX-20 · std/io.lyx + std/alloc.lyx lyxos-Adaptation ✅ Fertig — v0.9.5B

**Dateien:** `src/std/lyxos/io.lyx`  
**Test:** `tests/lx20_io_test.lyx`

`src/std/alloc.lyx` — keine Anpassung nötig; das `mmap`-Builtin dispatcht bereits auf LyxOS 0x0100.

`src/std/lyxos/io.lyx` — vollständige Reimplementierung von `src/std/io.lyx` mit LyxOS-Syscalls:

| Linux (std/io.lyx) | LyxOS (lyxos/io.lyx) | Syscall |
|---|---|---|
| `write(fd, buf, n)` | `sys_write(fd, buf, n)` | 0x0203 |
| `read(fd, buf, n)` | `sys_read(fd, buf, n)` | 0x0202 |
| `open(path, f, m)` | `sys_open(AT_CWD, path, f, m)` | 0x0200 |
| `close(fd)` | `sys_close(fd)` | 0x0201 |
| `lseek(fd, off, w)` | `sys_seek(fd, off, w)` | 0x0204 |

Gleiche öffentliche API: `PrintStr`, `PrintStrLn`, `PrintInt`, `PrintIntLn`, `PrintFloat`, `PrintChar`, `PrintBool`, `PrintLn`, `EPrintStr`, `EPrintStrLn`, `ReadLine`, `ReadChar`, `ReadInt`, `FileOpen`, `FileClose`, `FileRead`, `FileWrite`, `FileSeek`, `FileSize`, `FileReadAll`, `FileWriteAll`, `Flush`.

Hinweis: Target-Dispatch (automatisches Umleiten von `import src.std.io;` auf `src.std.lyxos.io;` bei `--target=lyxos`) bleibt für LX-23. Programme importieren `src.std.lyxos.io` direkt.

---

### LX-21 · Zwei-Register-Rückgabe `var val, err :=` ✅ Fertig — v0.9.5B

**Geänderte Dateien:** `src/ir.lyx`, `src/ir_lower.lyx`, `src/backend/lyxos/emit_lyxos.lyx`  
**Test:** `tests/lx21_tworet_test.lyx`

Implementierung:

| Komponente | Änderung |
|---|---|
| `ir.lyx` | Neues `IRO_LOAD_ERRVAL` (Opcode 164) |
| `ir_lower.lyx` | `lowerTupleVarDecl()` vollständig implementiert (war Stub) |
| `emit_lyxos.lyx` | `emitVfsSyscall`: `MOV r15, rax` nach SYSCALL (Error-Shadow); `emitInstr`: Handler für Opcode 164 → `MOV rax, r15; MOV [errSlot], rax` |

Syntax: `var val, err := syscall(...)` und `var val, _ := syscall(...)` (Discard-Variante).

Der Parser (`NK_TUPLE_VAR_DECL`) und Sema-Handler bestanden bereits (WP-BC-05).  
r15 ist callee-saved — SYSCALL preserviert r12–r15 per LyxOS-ABI.  
Singularität: S2 == S3 bestätigt.

---

### LX-22 · Debug & Telemetrie (0x0A00–0x0A05) ✅ Fertig — v0.9.5B

**Dateien:** `src/std/lyxos/debug.lyx`  
**Test:** `tests/lx22_debug_test.lyx`

| ID | Builtin | Syscall | Argc | Beschreibung |
|---|---|---|---|---|
| 145 | `sys_debug_print(msg, len)` | 0x0A00 | 2 | Kernel-Output (Port 0xE9/COM1), No-Op in Release |
| 146 | `sys_trace_event(event_id, data, len)` | 0x0A01 | 3 | Kernel-Trace-Event |
| 147 | `sys_perf_counter(counter_id)` | 0x0A02 | 1 | Hardware-Perf-Counter lesen |
| 148 | `sys_stack_trace(out_buf, max_frames)` | 0x0A03 | 2 | Stack-Trace in Buffer |
| 149 | `sys_watchpoint_set(addr, size, flags)` | 0x0A04 | 3 | Watchpoint setzen |
| 150 | `sys_watchpoint_clear(addr)` | 0x0A05 | 1 | Watchpoint löschen |

Konstanten: `TRACE_*`, `PERF_*`, `WP_*` in `src/std/lyxos/debug.lyx`.  
Singularität S1==S2 bestätigt.

---

### LX-23 · Integrations-Testsuite & Singularitätsprüfung

**Priorität:** Hoch

```
tests/lyxos/
  lx00_lbf_magic.lyx     – .lbf-Header-Validierung
  lx03_entry.lyx         – Exit-Code 42
  lx04_io.lyx            – PrintLn, PrintInt, EPrintLn
  lx05_alloc.lyx         – alloc, poke8, peek8, free
  lx06_fs.lyx            – open, read, write, stat, close
  lx08_net.lyx           – TCP Echo-Client/Server
  lx09_spawn.lyx         – sys_spawn, sys_wait
  lx10_mutex.lyx         – Mutex 4 Threads
  lx11_timer.lyx         – Periodischer Timer
  lx12_pledge.lyx        – sys_pledge + ERR_CAPVIOL
  lx13_parallel.lyx      – @parallel for-Schleife
  lx14_ai_infer.lyx      – sys_ai_infer_sync (ERR_NOTSUP graceful)
  lx21_two_ret.lyx       – var fd, err := sys_open(...)
```

```
make test-lyxos:
  ./lyxc --target=lyxos --emit=lbf <test>.lyx -o /tmp/<test>.lbf
  ./lbf_run /tmp/<test>.lbf
```

**Abnahme**
- `make test-lyxos` alle Tests grün
- `make singularity` S3 == S4

---

## Phase 8 — Produktions-LBF-Format (LYX!-Format)

*Natives Binärformat für den echten LyxOS-Kernel. Voraussetzung: LyxOS-Kernel existiert.*  
*Bis dahin ist Phase 0 (LBF-IR + lbf_run) der aktive Testpfad.*

### LBF-Nativ-Dateiformat (Magic `LYX!`)

```
BLOCK 0    Genesis-Block   4096 B  = 64 B Header + 4032 B Payload
BLOCK 1..N .text           4096 B pro Block  (R/X, Immutable)
BLOCK M+1  .rodata         4096 B pro Block  (R, Immutable)
BLOCK K+1  .data           4096 B pro Block  (R/W)
BLOCK L+1  .bss            kein physischer Block, Anzahl im Genesis vermerkt
```

**Block-Header (64 Bytes, Magic `LYX!` 0x4C 0x59 0x58 0x21):**

```
+0x0000  [4]  Magic:         'L' 'Y' 'X' '!'
+0x0004  [1]  page_type:     0x04 = LBF_Executable
+0x0005  [1]  flags:         bit0=Immutable
+0x0006  [2]  edge_offset:   0x0040 (Genesis) / 0x0000 (andere)
+0x0008  [8]  lpid:          Logical Page ID (0 auf POSIX)
+0x0010  [2]  payload_size:  4032
+0x0018  [4]  block_crc32c:  CRC32C des Payloads
+0x001C  [4]  meta_offset:   0x0040 (Genesis) / 0x0000
+0x0020  [8]  cont_lpid:     Fortsetzungs-LPID (für ext. Metadaten)
+0x0028  [4]  block_index:   Index dieses Blocks
+0x002C  [4]  total_blocks:  Gesamtanzahl Blöcke der Datei
+0x0038  [8]  compiled_at:   Zeitstempel (Epoch µs)
```

**Genesis-Payload (4032 Bytes, Offsets relativ zu Payload-Start):**

```
+0x0000  [1]   content_type:   0x01
+0x0001  [1]   target_arch:    0x01=x86-64, 0x02=ARM64, 0x03=RISC-V
+0x0002  [2]   os_version_min: Mindest-Kernel-Version
+0x0004  [8]   entry_point:    VA des _start-Symbols
+0x000C  [4]   file_size:      Gesamtgröße in Bytes
+0x0010  [2]   text_blocks
+0x0012  [2]   rodata_blocks
+0x0014  [2]   data_blocks
+0x0016  [2]   bss_blocks
+0x0018  [4]   stack_size:     Default 0x20000 (128 KB)
+0x001C  [4]   file_crc32c:    CRC32C der gesamten Datei (Feld=0 beim Berechnen)
+0x0020  [16]  compiler_name:  "lyxc" + Nullen
+0x0030  [4]   compiler_ver:   Packed Major.Minor.Patch
+0x0034  [8]   compiled_at:    Epoch µs
+0x003C  [16]  compiler_uuid:  UUID v4
+0x004C  [32]  source_sha256:  SHA-256 der Quelldateien
+0x006C  [2]   tlv_offset:     0x0080 (Standard)
+0x006E  [2]   tlv_used:       Genutzte Bytes im TLV-Pool
+0x0080  [3904] tlv_pool:      TLV-Einträge (Type+Length+Value)
```

**TLV-Encoding:** `[type:u8][length:u16LE][value:length Bytes]`

| TLV | Name | Inhalt |
|-----|------|--------|
| 0x01 | HUMAN_INTENT | UTF-8 Freitext aus `///`-Doc-Comment über `main()` |
| 0x02 | DEP_HASH_GRAPH | Array aus SHA-256-Hashes der Abhängigkeiten |
| 0x03 | SYM_INTERFACE | Funktions-Signaturen + Contract-Hashes |
| 0x04 | ISA_EXTENSIONS | `uint64_t` Bitmaske (AVX2=0, AVX512=1, ARM-NEON=2) |
| 0x05 | CAPABILITIES | `uint64_t` Capability-Bits |
| 0x06 | SOURCE_MAP | Git-Commit-Hash / Quellcode-URI |
| 0x07 | BUILD_MANIFEST | Array aus `(filename[64] + sha256[32])` |
| 0x08 | LIFECYCLE | Lifecycle-Descriptor (ONE_SHOT/EVENT_LOOP/DAEMON/REACTIVE) |

**Lifecycle-Descriptor (TLV 0x08):**

| Kind | Wert | Bedeutung |
|------|------|-----------|
| ONE_SHOT | 0x00 | CLI: start → main → exit (aktueller LX-03 _start) |
| EVENT_LOOP | 0x01 | Explizite Event-Schleife, Kernel registriert Quellen vor _start |
| DAEMON | 0x02 | Langlebiger Hintergrundprozess, kein SIGHUP |
| REACTIVE | 0x03 | Lazy-Start: Prozess startet erst beim ersten Event |

**Physische Konstanten (`src/std/lyxos/lbf_layout.lyx`):**

```lyx
con LBF_BLOCK_SIZE:   int64 := 4096;
con LBF_HEADER_SIZE:  int64 := 64;
con LBF_PAYLOAD_SIZE: int64 := 4032;
con LBF_TLV_MAX_SIZE: int64 := 3904;

con LBF_CAP_FS_READ:        int64 := 1;
con LBF_CAP_FS_WRITE:       int64 := 2;
con LBF_CAP_NET_SOCKET:     int64 := 4;
con LBF_CAP_PROC_SPAWN:     int64 := 8;
con LBF_CAP_KI_EMBED:       int64 := 16;
con LBF_CAP_KI_GRAPH_WRITE: int64 := 32;
con LBF_CAP_AUDIO_MIC:      int64 := 128;
con LBF_CAP_PRIVILEGED:     int64 := 9223372036854775808;

con LBF_EV_STDIN:      int64 := 0x01;
con LBF_EV_FD:         int64 := 0x02;
con LBF_EV_TIMER:      int64 := 0x03;
con LBF_EV_SIGNAL:     int64 := 0x04;
con LBF_EV_NET_ACCEPT: int64 := 0x05;
con LBF_EV_NET_RECV:   int64 := 0x06;
con LBF_EV_IOFS_EVENT: int64 := 0x07;
con LBF_EV_KI_MESSAGE: int64 := 0x08;
con LBF_EV_CHILD_EXIT: int64 := 0x09;
con LBF_EV_AUDIO_IN:   int64 := 0x0A;
```

---

### LX-25 · LBF-Nativ: Block Header I/O

**Datei:** `src/tools/lbf/block_header.lyx`

**Aufgabe**  
Lesen, Schreiben und Validieren des 64-Byte-Block-Headers. Kleinstes strukturelles
Atom des Formats — alle höheren LX-Pakete bauen darauf auf.

**Funktionen:**
- `lbf_header_init(buf, block_index, total_blocks, compiled_at, is_genesis)` — befüllt 64 Bytes
- `lbf_header_set_immutable(buf)` — setzt `flags |= 0x01` für .text/.rodata
- `lbf_header_set_crc(buf, payload)` — CRC32C über 4032 Bytes, Ergebnis in Header
- `lbf_header_validate(buf) → int64` — return 0=OK, -1=Magic-Fehler, -2=CRC-Fehler
- `lbf_header_is_genesis(buf) → bool` — `meta_offset == 0x0040`

**Abnahme**
- `lbf_header_init` + Byte-Dump: alle 64 Bytes korrekt belegt
- `lbf_header_validate` auf korrekt initialisiertem Header → 0
- `lbf_header_validate` nach Flippen von 1 Bit im Payload → -2
- `lbf_header_validate` mit falschen Magic-Bytes → -1
- Roundtrip: 100 verschiedene `block_index`-Werte → stets korrekt gelesen

---

### LX-26 · LBF-Nativ: Genesis-Content Serializer

**Datei:** `src/tools/lbf/genesis.lyx`  
**Abhängigkeit:** LX-25

**Aufgabe**  
Aufbau, Serialisierung und Deserialisierung des 4032-Byte-Genesis-Payloads.

**Funktionen:**
- `genesis_serialize(data: LbfGenesisData, out: pchar)` — schreibt alle Felder byteweise
- `genesis_deserialize(payload: pchar, out: LbfGenesisData)` — liest zurück
- `genesis_get_entry_point(payload: pchar) → int64` — Schnellabfrage
- `genesis_get_total_block_count(payload: pchar) → int64` — text+rodata+data+bss+1

**Abnahme**
- Serialize + Deserialize Roundtrip: alle Felder byte-identisch
- `entry_point = 0x401000` korrekt serialisiert (Little-Endian, 8 Bytes)
- `compiler_name = "lyxc"` als 16-Byte-Feld mit Null-Padding (Bytes 4–15 = 0x00)
- `LBF_GEN_FILE_CRC32C` nach Serialize = 0x00000000 (wird von LX-29 gefüllt)

---

### LX-27 · LBF-Nativ: TLV-Framework

**Datei:** `src/tools/lbf/tlv.lyx`  
**Abhängigkeit:** LX-26

**Aufgabe**  
Vollständiges TLV-Encoding/Decoding für den 3904-Byte-KI-Kontext-Pool.

**Format:** `[type:u8][length:u16LE][value:length Bytes]`

**Funktionen:**
- `tlv_append(pool, pool_used, type, value, length) → int64` — return 0 oder -1 (voll)
- `tlv_find(pool, pool_used, type, out_value, out_length) → int64` — return 0 oder -1
- `tlv_count(pool, pool_used) → int64`
- `tlv_add_intent(pool, pool_used, text) → int64` — max 512 Bytes
- `tlv_add_section(pool, pool_used, block_start, block_count, type, prot) → int64`
- `tlv_add_capabilities(pool, pool_used, cap_bits) → int64`
- `tlv_add_lifecycle(pool, pool_used, lc: LbfLifecycle) → int64`

**Abnahme**
- Roundtrip für alle 8 TLV-Typen: Inhalt byte-identisch
- Pool-Überlauf: `tlv_append` bei vollem Pool → -1, Pool unverändert
- Intent > 512 Bytes → auf 512 Bytes gekürzt, kein Absturz

---

### LX-28 · LBF-Nativ: Section Block Emitter

**Datei:** `src/tools/lbf/sections.lyx`  
**Abhängigkeit:** LX-25

**Aufgabe**  
Erzeugung der Code- und Datensegment-Blöcke (Block 1..N). Jeder Block exakt
4096 Bytes (64-Byte-Header + 4032 Bytes Nutzdaten), CRC32C-gesichert.

**Funktion:**
```lyx
fn section_emit(fd, data, data_len, sect_type, start_block, total_blocks, compiled_at): int64
```
Schreibt so viele 4096-Byte-Blöcke wie nötig; .bss schreibt 0 Bytes (Anzahl im Genesis).

**Abnahme**
- 4000 Bytes .text → 1 Block; Bytes 64–4063 = Code, 4064–4095 = 0x00
- 4033 Bytes .text → 2 Blöcke; Block 1: 1 Code-Byte + 4031 Null-Bytes
- .text/.rodata: `flags = 0x01` (Immutable); .data: `flags = 0x00`
- CRC32C jedes Blocks: `lbf_header_validate` → 0

---

### LX-29 · LBF-Nativ: Supply Chain Security

**Datei:** `src/tools/lbf/security.lyx`  
**Abhängigkeit:** LX-25–LX-27

**Aufgabe**  
SHA-256 der Quelldateien, CRC32C der Gesamtdatei, Compiler-UUID, Blacklist-Prüfung.

**Funktionen:**
- `lbf_compute_source_hash(source_files, out_sha256)` — SHA-256 über alle Quelldateien
- `lbf_finalize_file_crc(filepath)` — CRC32C über alle Block-Payloads in Genesis setzen
- `lbf_generate_compiler_uuid(out_uuid)` — UUID v4 (16 zufällige Bytes via sys_getrandom)
- `lbf_check_compiler_blacklist(uuid) → bool` — prüft `/etc/lyx/compiler_blacklist.bin`

**Abnahme**
- Gleiche Quelldateien → identisches SHA-256 (deterministisch)
- 1 Bit in Quelldatei geändert → anderer SHA-256
- `lbf_generate_compiler_uuid`: 1000 UUIDs alle unterschiedlich
- Blacklist: bekannte UUID → false; unbekannte → true; keine Blacklist-Datei → true

---

### LX-30 · LBF-Nativ: lyxc-Backend `--target=lyxos` → LYX!

**Datei:** lyxc-intern (ersetzt/ergänzt `emit_lyxos.lyx`)  
**Abhängigkeit:** LX-25–LX-29

**Aufgabe**  
Integration des LBF-Emitters als vollständiges Compiler-Backend. Ersetzt die
aktuelle ELF-Ausgabe für `--target=lyxos`. Flag `--emit-lbf` bleibt als Alias.

**Backend-Ablauf:**
1. IR-Code-Generierung (bestehender IR-Pass)
2. x86-64-Maschinencode-Ausgabe (bestehender Codegen, LX-01–LX-23)
3. Block-Anzahlen berechnen: `ceil(code_size / LBF_PAYLOAD_SIZE)` etc.
4. Compiler-UUID generieren (LX-29)
5. SHA-256 der Quelldateien berechnen (LX-29)
6. TLV-Pool aufbauen (LX-27): Intent, Sections, Capabilities, Lifecycle
7. Genesis-Content serialisieren (LX-26)
8. Block 0 schreiben: Header (LX-25) + Genesis (LX-26)
9. .text-Blöcke emittieren (LX-28)
10. .rodata-Blöcke emittieren (LX-28)
11. .data-Blöcke emittieren (LX-28)
12. Gesamt-CRC32C finalisieren (LX-29)

**Intent-Extraktion aus Doc-Comments:**
```lyx
/// Berechnet CRC32C für IOFS-Speichermedien.
fn main(): int64 { ... }
// → TLV 0x01: "Berechnet CRC32C für IOFS-Speichermedien."
```
Ohne Doc-Comment: Intent = Dateiname ohne Erweiterung.

**Abnahme**
- `lyxc hello.lyx -o hello.lbf` — Größe ist Vielfaches von 4096
- `lbf_header_validate` auf Block 0 → 0 (CRC korrekt)
- Genesis: `entry_point` zeigt auf korrekte VA
- Reproduzierbarkeit: zweimal kompiliert → byte-identisches Ergebnis

---

### LX-31 · LBF-Nativ: lbf_loader POSIX-Loader

**Datei:** `src/tools/lbf_loader.lyx`  
**Abhängigkeit:** LX-25, LX-28, LX-29

**Aufgabe**  
POSIX-Loader für LYX!-Dateien auf Linux/macOS. Mappt Sektionen via `mmap()` mit
korrekten Schutzrechten und springt zum Entry-Point. Kein JIT, kein Interpreter —
echter nativer Maschinencode.

*Unterschied zu LX-24 (`lbf_run`): LX-24 ist ein IR-Interpreter für LBF-IR-Bytecode.
LX-31 ist ein nativer Loader für LBF-Nativ-Maschinencode.*

**Ladesequenz:**
1. Datei öffnen, Größe prüfen (Vielfaches von 4096)
2. Block 0 validieren (Magic, CRC32C — LX-25)
3. Gesamt-CRC32C prüfen (LX-29)
4. Compiler-UUID gegen Blacklist prüfen (LX-29)
5. Section-Table aus TLV 0x04 lesen (LX-27)
6. Jede Sektion mit korrekten mmap-Flags mappen (`base_va = 0x400000`)
7. .bss als anonymes zeroed Mapping anlegen
8. Stack allozieren (128 KB Default)
9. Entry-Point via indirektem Sprung aufrufen

**Abnahme**
- `lbf_loader hello.lbf` — Programm läuft, Ausgabe korrekt
- `lbf_loader manipulated.lbf` (1 Bit geflippt) — CRC-Fehler, Ausführungsverbot
- .rodata: Schreibversuch → SIGSEGV
- .bss: Global-Variable ohne Initializer = 0 (MAP_ANON korrekt zeroed)

---

### LX-32 · LBF-Nativ: lbf_import IOFS-Import

**Datei:** `src/tools/lbf_import.lyx`  
**Abhängigkeit:** LX-25–LX-29, IOFS

**Aufgabe**  
Konvertierung einer POSIX-LBF-Datei in IOFS-native Pages (Typ 0x04) und
Einbindung in den IOFS-Graphen. Jeder Block → eine IOFS-Page.

**Abnahme**
- `lbf_import("hello.lbf", "tools")` → valide LPID
- Anzahl IOFS-Pages = `total_blocks`
- Jede importierte Page: Typ=0x04, Magic=LYX!, valide CRC32C
- Block-Kette via 0xB001-Kanten vollständig traversierbar

---

### LX-33 · LBF-Nativ: Dependency Resolver

**Datei:** `src/tools/lbf/dep_resolver.lyx`  
**Abhängigkeit:** LX-32, IOFS

**Aufgabe**  
Auflösung der TLV 0x02 SHA-256-Abhängigkeitshashes zu LPIDs im IOFS-Graphen.
Einweben der Dependency-Kanten (0xD001) in den Programm-Graphen.

- `dep_resolve_all(prog_lpid) → int64` — gibt Anzahl nicht aufgelöster Deps zurück
- `dep_index_register(sha256, prog_lpid)` — SHA-256 → LPID in globalem Index
- `dep_index_lookup(sha256) → int64` — O(1)-Suche

**Abnahme**
- Programm A importiert, Programm B (abhängig von A) importiert → `dep_resolve_all(B) = 0`
- Fehlende Dependency → Fehlermeldung auf stderr mit Alias
- 100 registrierte Dependencies → alle korrekt gefunden

---

### LX-34 · LBF-Nativ: Zero-Load Executor (Kernel)

**Datei:** `kernel/lbf_exec.lyx`  
**Abhängigkeit:** LX-32, LX-33, IOFS, Semantische Firewall

**Aufgabe**  
Implementierung von `sys_exec()` für LBF-Programme auf IOFS. Kein Kopieren von
Segmenten — der Kernel mappt LBAs direkt in die CPU-Page-Tables (CR3-Struktur).

**sys_exec() Sequenz:**
1. Genesis-Block lesen
2. Semantische Firewall prüfen (Intent vs. Capabilities)
3. Neues CR3 anlegen
4. Section-Table aus TLV 0x04 lesen
5. Block-LPIDs aus 0xB001-Kanten sammeln
6. LBA-Adressen → direkt in Page-Tables eintragen (kein memcpy)
7. .bss: zeroed RAM-Frames zuweisen
8. Stack allozieren
9. Prozess starten, zu Entry-Point springen

**Abnahme**
- "Hello World" startet und gibt Text aus, Exit-Code 0
- 100 Instanzen: RAM steigt nicht proportional (Page-Sharing)
- .rodata-Schreibversuch → Page-Fault, Prozess terminiert, Kernel läuft weiter
- Ladezeit eines 10-Block-Programms < 1 ms

---

### LX-35 · LBF-Nativ: lbf-dump Inspection Tool

**Datei:** `src/tools/lbf_dump.lyx`  
**Abhängigkeit:** LX-25–LX-29

**Aufgabe**  
Kommandozeilentool zur menschenlesbaren Inspektion und Validierung von LYX!-Dateien.
Analogon zu `readelf` für ELF.

**Beispielausgabe:**
```
=== LBF DUMP: hello.lbf ===

[Block 0 — Genesis]
  Magic:       LYX! (0x4C 0x59 0x58 0x21)  ✓
  Target:      x86-64
  Entry Point: 0x0000000000401040
  File Size:   24576 bytes (6 blocks)
  File CRC32C: 0x3F8A21B7  ✓

[Compiler Provenance]
  Compiler:    lyxc 1.0.1D
  Compiler:    lyxc 0.9.9A
  Compiled At: 2026-06-10 12:14:03 UTC
  UUID:        a3f72b18-4c91-4d2e-8e7b-1234567890ab
  UUID Status: ✓ (not blacklisted)

[TLV Entries]
  [0x01] Intent: "Öffnet /etc/hostname und gibt Inhalt aus."
  [0x04] Sections: .text=3(R/X), .rodata=1(R), .data=1(R/W), .bss=1(R/W)
  [0x05] Capabilities: 0 (none)

[Block Inventory]
  Block 0: Genesis       CRC ✓
  Block 1: .text  [1/3]  CRC ✓  Immutable
  ...
```

**Abnahme**
- `lbf_dump hello.lbf` — alle Felder korrekt dekodiert
- `lbf_dump --verify-only hello.lbf` — Exit-Code 0 valide / 1 korrupt
- UUID im Format `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- Manipulierter Block → CRC ✗ für diesen Block, ✓ für alle anderen

---

### LX-36 · LBF-Nativ: Lifecycle Descriptor (TLV 0x08)

**Datei:** lyxc-intern + `kernel/lbf_exec.lyx`  
**Abhängigkeit:** LX-27, LX-30, LX-34

**Aufgabe**  
Drei Teile: (1) `@lifecycle`/`@on_event`-Annotationen parsen → TLV 0x08 emittieren,
(2) `_start`-Varianten je nach Lifecycle-Kind, (3) Kernel-Dispatch.

**Quellcode-Annotationen:**
```lyx
/// GUI-Anwendung, 60 FPS.
@lifecycle(event_loop)
@on_event(stdin,  handler: fn handle_key)
@on_event(timer,  hz: 60, handler: fn render_frame)
@on_event(signal, sig: 15, handler: fn on_sigterm)
@quiescence_stack(4)
fn main(): int64 { ... }
```
Ohne Annotation: `ONE_SHOT` implizit — identisch mit aktuellem LX-03 `_start`.

**_start-Varianten:**
- `ONE_SHOT`: aktueller LX-03-Stub (unverändert)
- `EVENT_LOOP`: wie ONE_SHOT, solange der Kernel keine Registrierung hat (siehe unten)
- `DAEMON`: wie ONE_SHOT, aber Kernel behandelt Prozess als Service-Knoten
- `REACTIVE`: kein `_start` — Kernel startet erst beim ersten Event direkt in `on_event_va`

**Neuer LyxOS-Syscall — ANGEFORDERT, NICHT GEBAUT:** `sys_event_loop_init` (0x0020)
sollte alle TLV-0x08-Quellen vor dem ersten `_start`-Aufruf registrieren. Die
Nummer 32 steht weder im Dispatcher (`kernel/ring3.lyx`) noch unter den
Bootloader-Abfängen; ein Aufruf landet in `.r3_unknown` und bekommt **still 0
samt Erfolgsmeldung**.

Der Startcode hat sie bis 1.1.13E trotzdem emittiert — sichtbar wurde das nie,
weil ein unbekannter Syscall in LyxOS nicht scheitert. Seit #1795 emittiert
`emitStartStubEventLoop` nichts mehr und meldet beim Übersetzen, dass
EVENT_LOOP wie ONE_SHOT läuft. Sobald der Kernel 32 baut, kommt der Aufruf
zurück — dann über `emitVfsSyscall`, damit die Nummernprüfung ihn sieht.

**Abnahme**
- `@lifecycle(one_shot)`: TLV 0x08 mit `kind=0x00`, `count=0`; `_start` identisch zu LX-03
- `@lifecycle(event_loop)` + 2× `@on_event`: `count=2`, Deskriptoren byte-korrekt
- Timer 60Hz: Prozess erhält 60× pro Sekunde den Event
- `REACTIVE`: `sys_exec()` kehrt sofort zurück, Prozess startet erst beim ersten Event

---

## Gesamtabnahme — Produktions-LBF-Integration

Wenn LX-25 bis LX-36 abgeschlossen sind:

1. `lyxc hello.lyx -o hello.lbf` — LYX!-Format, Größe Vielfaches von 4096
2. `lbf_dump --verify-only hello.lbf` — Exit-Code 0
3. `lbf_loader hello.lbf` — korrekte Ausgabe auf POSIX-Linux
4. `lbf_import hello.lbf --into-island=tools` — LPID zurück, Graph korrekt
5. Dependency-Test: Programm mit fehlender Dep → Fehlermeldung, kein Laden
6. `sys_exec(prog_lpid)` auf IOFS — native Ausführung, Entry-Point korrekt
7. Manipuliertes Binary → `lbf_loader` und `lbf_import` verweigern
8. Firewall-Test: Intent ↔ Capability-Mismatch → `sys_exec` verweigert
