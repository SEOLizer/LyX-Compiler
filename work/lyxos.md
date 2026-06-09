# Lyx OS Backend — Vollständiger Implementierungsfahrplan

**lyxc-Ziel:** `--target=lyxos`  
**ABI-Referenz:** `work/lyxos/syscalls.md` (ABI v1.0, 137 Syscalls)  
**Stand:** v0.9.5A — noch nicht implementiert  
**Branch-Namensschema:** `feat/lyxos-lx<nn>-<kürzel>`

---

## Übersicht

| LX | Titel | Phase | Prio | Abhängigkeit |
|----|-------|-------|------|--------------|
| LX-00 | LBF-Format & `--emit=lbf` Codegen-Ausgabe | 0 | Hoch | — |
| LX-01 | Target-Registrierung & ELF-Grundgerüst | 1 | Hoch | — |
| LX-02 | emit_lyxos.lyx Codegen-Skelett | 1 | Hoch | LX-01 |
| LX-03 | Prozess-Lebenszyklus & Entry-Point | 1 | Hoch | LX-02 |
| LX-04 | Basis-I/O (sys_write / sys_read → Builtins) | 1 | Hoch | LX-03 |
| LX-05 | Speicherverwaltung (sys_mmap / sys_munmap) | 1 | Hoch | LX-03 |
| LX-06 | Vollständiges Dateisystem VFS (0x0200–0x0215) | 2 | Hoch | LX-04 |
| LX-07 | I/O-Geräte & Poll (0x0300–0x0305) | 2 | Mittel | LX-06 |
| LX-08 | Netzwerk (0x0600–0x0609) | 2 | Mittel | LX-06 |
| LX-09 | Prozess & Threads vollständig (0x0000–0x000D) | 3 | Hoch | LX-05 |
| LX-10 | IPC & Synchronisation (0x0400–0x040C) | 3 | Mittel | LX-09 |
| LX-11 | Zeit-Syscalls (0x0500–0x0504) | 3 | Mittel | LX-03 |
| LX-12 | Capabilities + Pledge + Unveil (0x0700–0x0708) | 4 | Hoch | LX-09 |
| LX-13 | Task-Scheduler & `@parallel` (0x0B00–0x0B09) | 4 | Mittel | LX-09 |
| LX-14 | KI-Basis: Model + Context + Infer (0x0800–0x0806) | 5 | Mittel | LX-05 |
| LX-15 | KI-Embedding & Vektorindex (0x0807–0x080C) | 5 | Mittel | LX-14 |
| LX-16 | Semantisches Paging & Wissensgraph (0x080D–0x0812) | 5 | Niedrig | LX-15 |
| LX-17 | Lyra Agent Interface (0x0900–0x090B) | 5 | Niedrig | LX-16 |
| LX-18 | IOFS: Island & Ocean FS (0x0C00–0x0C04) | 6 | Niedrig | LX-12 |
| LX-19 | lyxrt_lyxos.lyx Runtime-Library | 7 | Hoch | LX-05 |
| LX-20 | std/io.lyx + std/alloc.lyx lyxos-Adaptation | 7 | Hoch | LX-19 |
| LX-21 | Zwei-Register-Rückgabe `var val, err :=` | 7 | Mittel | LX-02 |
| LX-22 | Debug & Telemetrie (0x0A00–0x0A05) | 7 | Niedrig | LX-03 |
| LX-23 | Integrations-Testsuite & Singularitätsprüfung | 7 | Hoch | LX-20, LX-24 |
| LX-24 | lbf_run — POSIX-Interpreter (Lyx) | 8 | Hoch | LX-00, LX-04 |

---

## Phase 0 — LBF-Testinfrastruktur

### LX-00 · LBF-Format & `--emit=lbf` Codegen-Ausgabe

**Priorität:** Hoch

**Aufgabe**  
lyxc um den Ausgabemodus `--emit=lbf` erweitern: statt Maschinencode wird ein
portables Bytecode-Paket (`.lbf`) erzeugt, das den IR direkt serialisiert.
Das ermöglicht das Testen aller lyxos-LX-Pakete auf POSIX-Linux ohne echten
lyxos-Kernel, indem `lbf_run` (LX-24) die Syscalls übersetzt.

**Testpipeline (Phase 1–3):**
```
lyxc --target=lyxos --emit=lbf prog.lyx -o prog.lbf
lbf_run prog.lbf             ← POSIX-Interpreter, läuft auf Linux
```

**LBF-Dateiformat:**

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
  FuncEntry:  nameOff:u32, nameLen:u16, firstInstr:u32, instrCount:u32
── InstrArray (instrCount × Instr) ────────────────────────────────
  Instr:  opcode:u16, dest:u16, a:u32, b:u32, imm:i64   = 20 Bytes
── RelocTable (relocCount × Reloc) ────────────────────────────────
  Reloc:  instrIdx:u32, field:u8, targetFuncIdx:u32      = 9 Bytes
```

Der Instr-Opcode-Raum entspricht dem internen `IRO_*`-Opcode-Set von lyxc.
lyxos-Syscalls erscheinen als `IRO_CALL_BUILTIN` mit dem lyxos-Syscall-Identifier
im `imm`-Feld.

**Änderungen in `src/lyxc.lyx`:**
- `parseLongFlag`: `--emit=lbf` → `self.emitMode := EMIT_LBF`
- `emitCode`: wenn `emitMode == EMIT_LBF`, direkt IR serialisieren statt Codegen
- Neue Datei `src/lbf_writer.lyx`: schreibt IR → `.lbf`

**Abnahme**
- `./lyxc --target=lyxos --emit=lbf tests/lyxos/lx03_entry.lyx -o /tmp/entry.lbf` — kein Fehler
- `xxd /tmp/entry.lbf | head -1` → Magic `4c 42 46 00` (LBF\0)
- `./lyxc --target=lyxos --emit=lbf` und `./lyxc --target=lyxos` erzeugen strukturell dieselbe IR-Basis
- `.lbf`-Datei enthält mindestens eine Funktion (`main`) in der FuncTable
- `./lyxc --target=x86_64` ignoriert `--emit=lbf` nicht (Fehler: "emit=lbf nur für lyxos-Target")

---

## Phase 1 — Foundation

### LX-01 · Target-Registrierung & ELF-Grundgerüst

**Priorität:** Hoch

**Aufgabe**  
Das neue Compile-Target `--target=lyxos` in `src/lyxc.lyx` registrieren, einen neuen
ELF-Writer-Pfad einrichten und den Pflicht-Abschnitt `.note.lyx-abi` (ABI-Versionskennzeichnung)
in das erzeugte Binary einbetten.

**Kontext**  
Alle bestehenden Targets (x86_64, arm64, macos-arm64 usw.) folgen dem Muster:
Konstante `LYX_TC_*` in `src/lyxc.lyx`, `parseLongFlag` erkennt `--target=lyxos`,
Dispatch in `emitCode()` springt in den neuen Codegen. Die ELF-Struktur für lyxos
ist identisch mit dem Linux-x86_64-ELF, erweitert um eine `.note.lyx-abi`-Section
mit 8 Bytes Payload: `[major:u32 = 1][minor:u32 = 0]`.

```
ELF-Sections (Pflicht ab LX-01):
  .text      – ausführbarer Code (PT_LOAD RX)
  .data      – initialisierte globale Variablen (PT_LOAD RW)
  .note.lyx-abi – ABI-Version (PT_NOTE, nicht ladbar)
```

**Änderungen**
- `src/lyxc.lyx`: `con LYX_TC_LYXOS: int64 := 13;` (nächste freie Nummer prüfen)
- `parseLongFlag`: `--target=lyxos` → `self.target := LYX_TC_LYXOS`
- `emitCode`: neuer Branch `if self.target == LYX_TC_LYXOS { self.emitLyxOS(irMod) }`
- Neue Datei `src/backend/lyxos/emit_lyxos.lyx` (Skelett, noch leer außer Stub)
- ELF-Writer-Funktion `writeLyxOsELF()` mit `.note.lyx-abi`

**Abnahme**
- `./lyxc --target=lyxos /tmp/empty.lyx -o /tmp/out` — kein Compile-Fehler
- `readelf -n /tmp/out` zeigt Section `lyx-abi` mit `major=1 minor=0`
- `readelf -h /tmp/out` zeigt `Type: EXEC`, `Machine: X86-64`, `Class: ELF64`
- `./lyxc --version` bleibt unverändert; kein Regressions-Fehler auf anderen Targets
- `make test` grün

---

### LX-02 · emit_lyxos.lyx Codegen-Skelett

**Priorität:** Hoch

**Aufgabe**  
Das Codegen-Modul `src/backend/lyxos/emit_lyxos.lyx` vollständig aufbauen:
VMT, SYSCALL-Makro-Hilfsroutine, Stub-Dispatch für alle IR-Opcodes,
Register-Belegung nach Lyx-OS-ABI.

**Kontext**  
Die Lyx-OS-ABI legt fest (syscalls.md §2.2):

```
Eingabe:  rax=Syscall-Nr, rdi=a1, rsi=a2, rdx=a3, r10=a4, r8=a5, r9=a6
Ausgabe:  rax=Fehlercode, rdx=Rückgabewert
Clobbered nach SYSCALL: rcx, r11, rdi, rsi, r10, r8, r9
Callee-saved:           rbx, rbp, r12, r13, r14, r15
```

Der Codegen folgt strukturell `src/backend/arm64/emit_arm64.lyx` / `src/codegen_x86.lyx`,
nutzt aber ausschließlich SYSCALL (kein libc). Inline-Hilfsfunktion `emitSyscall(nr)`
erzeugt `MOV rax, nr; SYSCALL`.

Wichtig: VMT-Größe muss **gerade** sein (Parity-Bug, siehe Memory `project_qt_support.md`).

**Kernmethoden des Skeletts**

```
emitFunc()          – Prolog (PUSH rbp; MOV rbp,rsp; SUB rsp,N)
emitRet()           – Epilog (MOV rsp,rbp; POP rbp; RET)
emitSyscall(nr)     – MOV rax,nr + SYSCALL + Store rdx→destSlot + rax→errSlot
emitInstr(idx)      – IR-Opcode-Dispatch (alle IRO_* als Stubs)
emitCall(...)       – BL-Äquivalent via CALL rel32
emitConstStr(...)   – Inline-String (LEA rip-relativ)
slotOff(slot)       – -(slot+1)*8 relativ zu rbp
```

**Abnahme**
- `src/backend/lyxos/emit_lyxos.lyx` kompiliert ohne Fehler durch `./lyxc`
- VMT-Methoden-Anzahl ist gerade
- `./lyxc --target=lyxos` für ein Programm mit nur `return 0` erzeugt ein binär ausführbares ELF
  (`file /tmp/out` → `ELF 64-bit LSB executable, x86-64`)
- Kein Segfault beim Codegen selbst (Programm darf beim Ausführen noch abstürzen)

---

### LX-03 · Prozess-Lebenszyklus & Entry-Point

**Priorität:** Hoch

**Aufgabe**  
Den Entry-Point `_start` für lyxos-Binaries implementieren: Stack einrichten,
Stack-Canary via `sys_getrandom` (0x000C) initialisieren, `main()` aufrufen,
Rückgabewert an `sys_exit_group` (0x0002) übergeben.

**Kontext**  
Lyx OS kennt kein `fork()`. Der Prozess startet an `_start` mit einem leeren Stack.
argc/argv werden vom Kernel in Registern `rdi`/`rsi` übergeben (oder wie lyxos es
definiert — ABI-Detail das hier festgelegt wird). Stack-Canary analog zu WP-18
(Linux): 8 zufällige Bytes via `sys_getrandom`.

```asm
_start:
  ; Stack-Frame aufbauen
  xor rbp, rbp
  ; Canary: sys_getrandom(buf=rsp-8, len=8, flags=0)
  mov rax, 0x000C
  lea rdi, [rsp-8]
  mov rsi, 8
  xor rdx, rdx
  syscall
  mov rax, [rsp-8]
  mov fs:[canary_offset], rax   ; oder rbp-8 per Konvention
  ; main() aufrufen
  call main
  ; sys_exit_group(main_result)
  mov rdi, rax
  mov rax, 0x0002
  syscall
```

Implementierung in `emit_lyxos.lyx`: Methode `emitStartSymbol()`, aufgerufen
nach dem letzten Func-Emit.

**Abnahme**
- `./lyxc --target=lyxos` auf `fn main(): int64 { return 42; }` → Binary
- Binary mit `qemu-x86_64-static` ausgeführt → Exit-Code 42
- `sys_getrandom`-Syscall erscheint in `strace`-Ausgabe (Canary-Init)
- `sys_exit_group`-Syscall erscheint mit Code 42
- Kein Absturz in `_start`

---

### LX-04 · Basis-I/O — sys_write / sys_read

**Priorität:** Hoch

**Aufgabe**  
Die I/O-Builtins `PrintLn`, `Print`, `EPrintLn`, `EPrint`, `PrintStr`, `PrintInt`
auf lyxos-Syscalls mappen. Ausgabe via `sys_write` (0x0203) auf fd 1 (stdout) bzw.
fd 2 (stderr).

**Kontext**  
`sys_write(fd, buf, count)` → `rax=0x0203, rdi=fd, rsi=buf, rdx=count`.
Rückgabe: `rax=Fehlercode, rdx=geschriebene Bytes`.

In `emit_lyxos.lyx` wird `emitBuiltinCall(id)` analog zu `emit_arm64.lyx` implementiert.
Für `id=1` (PrintStr): `sys_write(FD_STDOUT=1, slot0, slot1)`.
Für `id=2` (PrintInt): inline itoa + `sys_write`.

Die lyxos-spezifische Besonderheit: Fehlerbehandlung ist optional in Phase 1
(Fehlercode in rax wird ignoriert).

```
Mapping:
  PrintStr(s, len)  → sys_write(1, s, len)
  PrintInt(n)       → itoa(n) + sys_write(1, buf, len)
  PrintLn("s")      → sys_write(1, "s\n", len+1)
  EPrintLn("s")     → sys_write(2, "s\n", len+1)
```

**Abnahme**
- `PrintLn("Hello Lyx OS")` → stdout: `Hello Lyx OS\n`
- `PrintInt(42)` → stdout: `42`
- `EPrintLn("Fehler")` → stderr: `Fehler\n`
- `Inspect(x)` auf lyxos → stderr: `[Inspect:x] <wert>\n`
- `sys_write`-Syscall-Nr (0x0203) in strace-Ausgabe sichtbar
- `make test` mit neuem lyxos-Smoke-Test grün

---

### LX-05 · Speicherverwaltung — sys_mmap / sys_munmap

**Priorität:** Hoch

**Aufgabe**  
Die Builtins `alloc(n)` und `free(ptr)` auf lyxos-Syscalls mappen.
`alloc` → `sys_mmap(0, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS)` (0x0100).
`free` → `sys_munmap(ptr, size)` (0x0101).

**Kontext**  
Unter Linux nutzt lyxc `brk`/`mmap`. Lyx OS kennt kein `brk` — der einzige
Heap-Allocator-Weg ist `sys_mmap`. Da lyxc einen einfachen Bump-Allocator
verwendet, reicht der direkte Syscall.

```
sys_mmap: rax=0x0100, rdi=hint(0), rsi=size, rdx=prot, r10=flags
          → rdx=Adresse (bei Erfolg)
sys_munmap: rax=0x0101, rdi=addr, rsi=size
```

`PROT_READ=1, PROT_WRITE=2, MAP_PRIVATE=1, MAP_ANONYMOUS=4`

In `emit_lyxos.lyx`: `emitBuiltinCall` für `id=4` (alloc) und `id=5` (free).

**Abnahme**
- `alloc(1024)` liefert einen Nicht-Null-Pointer
- `poke8(ptr, 42); peek8(ptr)` → 42 (Lese-/Schreibtest)
- `free(ptr)` → kein Absturz
- Programm mit dynamischer String-Verarbeitung (StrLen, StrConcat) funktioniert
- `sys_mmap`-Syscall (0x0100) in strace sichtbar

---

## Phase 2 — Dateisystem & Netzwerk

### LX-06 · Vollständiges VFS (0x0200–0x0215)

**Priorität:** Hoch

**Aufgabe**  
Alle 22 Dateisystem-Syscalls als `extern`-Wrapper in `lyxrt_lyxos.lyx` verfügbar
machen. Direktes Mapping auf Lyx-OS-Syscall-Nummern.

**Kontext**  
Alle Pfad-Syscalls nehmen `dir_fd` als erstes Argument — `AT_CWD = -1` für
CWD-relative Pfade. `CLOEXEC` ist implizit (kein `O_CLOEXEC`-Flag nötig).

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

Implementierung als Lyx-Inline-SYSCALL-Wrapper in `src/std/lyxos/fs.lyx`.

**Abnahme**
- Datei öffnen (`sys_open`), lesen (`sys_read`), schließen (`sys_close`) → Inhalt korrekt
- Datei schreiben (`sys_open` + O_WRITE + O_CREAT + `sys_write`) → Datei entsteht
- Verzeichnis erstellen (`sys_mkdir`) → sichtbar im FS
- Datei löschen (`sys_unlink`) → weg nach Aufruf
- `sys_stat` liefert korrekte `size` für eine bekannte Datei
- `sys_content_id` mit `CID_BLAKE3=0` liefert 32-Byte-Hash einer bekannten Datei
- `sys_pipe` + `sys_write`/`sys_read` zwischen zwei Prozessen (via fork-Äquivalent)
- `AT_CWD`-Verwendung für relative Pfade funktioniert

---

### LX-07 · I/O-Geräte & Poll (0x0300–0x0305)

**Priorität:** Mittel

**Aufgabe**  
`sys_poll`, `sys_ioctl`, `sys_mmap_device`, `sys_irq_bind`, `sys_port_in`, `sys_port_out`
als Wrapper in `src/std/lyxos/device.lyx` implementieren.

**Kontext**  
`sys_poll` (0x0300) ist das zentrale Multiplexing-Primitiv — es wird von allen
asynchronen Anwendungen (Netzwerk, KI, Notifications) benötigt. `sys_ioctl` (0x0301)
ist im Gegensatz zu Linux streng typisiert; jede Geräteklasse hat eine eigene
Request-Tabelle.

`sys_port_in`/`sys_port_out` (0x0304/0x0305) erfordern `CAP_IOPORT` — nur für
Treiber-Code relevant, aber in der Stdlib vorhalten.

**PollEvent-Struktur** (definiert in syscalls.md §6):
```lyx
type PollEvent = flat struct {
    fd:      int64;
    events:  uint32;
    revents: uint32;
};
```

**Abnahme**
- `sys_poll` auf einem Pipe-fd: `POLL_IN` erscheint wenn Daten vorhanden
- `sys_poll` mit `timeout_ns=0` kehrt sofort zurück (non-blocking)
- `sys_poll` mit `timeout_ns=1_000_000` (1 ms) liefert `ERR_TIMEOUT` wenn kein Event
- `sys_ioctl` gibt `ERR_INVAL` bei unbekanntem Request-Code zurück
- Kompiliert ohne Fehler

---

### LX-08 · Netzwerk (0x0600–0x0609)

**Priorität:** Mittel

**Aufgabe**  
Alle 10 Netzwerk-Syscalls als Wrapper in `src/std/lyxos/net.lyx` implementieren.
TCP-Client und TCP-Server als Integrations-Tests.

**Kontext**  
Das Socket-API ist intentional POSIX-nah, damit bestehende std/net-Lyx-Code
mit minimalem Aufwand portiert werden kann. Einzige Abweichung: `CLOEXEC` ist
Default (kein `SOCK_CLOEXEC` nötig).

| Syscall | Nr | Anmerkung |
|---------|-----|-----------|
| `sys_socket` | 0x0600 | `AF_INET=2, AF_INET6=10, AF_UNIX=1` |
| `sys_bind` | 0x0601 | |
| `sys_listen` | 0x0602 | |
| `sys_accept` | 0x0603 | Blockiert; neuer fd hat CLOEXEC |
| `sys_connect` | 0x0604 | Blockiert bei TCP bis SYN-ACK |
| `sys_sendmsg` | 0x0605 | Scatter/Gather + ancillary data |
| `sys_recvmsg` | 0x0606 | `MSG_PEEK=1, MSG_WAITALL=2` |
| `sys_setsockopt` | 0x0607 | |
| `sys_getsockopt` | 0x0608 | |
| `sys_shutdown` | 0x0609 | `SHUT_READ=0, SHUT_WRITE=1, SHUT_RDWR=2` |

**Abnahme**
- TCP-Echo-Server: `sys_socket` + `sys_bind` + `sys_listen` + `sys_accept` + `sys_read` + `sys_write`
- TCP-Client verbindet sich, sendet "ping", empfängt "pong"
- `AF_UNIX`-Socket (Unix-Domain-Socket) zwischen zwei lyxos-Prozessen
- `sys_poll` auf Socket-fd: `POLL_IN` erscheint nach eingehender Verbindung

---

## Phase 3 — Prozesse & IPC

### LX-09 · Prozess & Threads vollständig (0x0000–0x000D)

**Priorität:** Hoch

**Aufgabe**  
Alle verbleibenden Prozess/Thread-Syscalls implementieren: `sys_spawn`, `sys_thread_spawn`,
`sys_wait`, `sys_getpid`, `sys_gettid`, `sys_yield`, `sys_sleep_ns`, `sys_priority`,
`sys_signal_mask`.

**Kontext**  
`sys_spawn` (0x0003) ist das lyxos-Äquivalent zu `posix_spawn` / `CreateProcess`.
Kein `fork()` — der neue Prozess startet direkt aus einem ELF-Binary heraus.
`SpawnOpts` (Struct-Definition in syscalls.md §6) steuert stdio-Umleitung und
Namespace-Isolation.

`sys_thread_spawn` (0x0004) erzeugt Kernel-Threads im selben Adressraum —
für KI-parallele Inferenz, Audio-Threads, UI-Threads benötigt.

```lyx
type SpawnOpts = flat struct {
    flags:          int64;
    cwd_fd:         int64;
    stdin_fd:       int64;
    stdout_fd:      int64;
    stderr_fd:      int64;
    extra_fds:      int64;
    extra_fd_count: int64;
    stack_size:     int64;
    priority:       int64;
};
```

**Abnahme**
- `sys_spawn(AT_CWD, "/bin/echo", argv, envp, opts)` → neuer Prozess läuft, Exit-Code via `sys_wait`
- `sys_thread_spawn(worker_fn, stack, 65536, arg)` → Thread läuft parallel, schreibt Ergebnis
- `sys_wait(proc_fd, &status, -1)` blockiert bis Prozess beendet
- `sys_getpid` / `sys_gettid` liefern verschiedene Werte in Main-Thread und Spawn-Thread
- `sys_sleep_ns(100_000_000)` schläft ca. 100 ms (±20 ms gemessen via `sys_clock_get`)
- `sys_yield` gibt CPU ab ohne Fehler
- `sys_priority(fd, -1)` erhöht Priorität (mit Admin-Capability)

---

### LX-10 · IPC & Synchronisation (0x0400–0x040C)

**Priorität:** Mittel

**Aufgabe**  
Alle 13 IPC-Syscalls als Wrapper bereitstellen: Mutex, Semaphor, Channel (Mach-inspiriert),
Notification-Queue und futex.

**Kontext**  
`sys_channel_*` (0x0406–0x0408) ersetzt Unix-Pipes für strukturierten IPC — Nachrichten
sind getypt, fds können angehängt werden (fd-Passing). Das ist der primäre Kanal
zwischen Userspace-Prozessen und Lyra.

`sys_notify_*` (0x0409–0x040B) ersetzt Unix-Signale — keine verlorenen Events,
keine `SA_RESTART`-Problematik.

```lyx
// Kanal-Paar erzeugen
var fds: int64 := sys_channel_create(0);
var send_fd: int64 := fds >> 32;
var recv_fd: int64 := fds & 0xFFFFFFFF;
```

**Abnahme**
- Producer-Consumer via `sys_sem_create/wait/post` — korrekte Synchronisation ohne Race
- `sys_mutex_lock` + `sys_mutex_unlock` schützen kritischen Abschnitt zwischen 4 Threads
- `sys_mutex_lock` auf ROBUST-Mutex nach Thread-Tod → `ERR_DEADLOCK`
- `sys_channel_send` + `sys_channel_recv` überträgt 1024-Byte-Nachricht mit angehängte fd
- `sys_notify_post` weckt wartenden `sys_notify_wait` auf
- `sys_futex` WAIT/WAKE-Roundtrip funktioniert

---

### LX-11 · Zeit-Syscalls (0x0500–0x0504)

**Priorität:** Mittel

**Aufgabe**  
`sys_clock_get`, `sys_clock_set`, `sys_timer_create`, `sys_timer_set`, `sys_timer_wait`
als Wrapper in `src/std/lyxos/time.lyx`.

**Kontext**  
`sys_clock_get` (0x0500) ist der häufigste Zeit-Syscall — wird intern von `sleep_ns`,
Profiling und Lyra-Timeline genutzt. `CLOCK_MONO=1` für Messungen (kein Sprung),
`CLOCK_REAL=0` für Wanduhr.

Für den vDSO-Pfad (kein Syscall-Overhead) ist LX-11 der Platzhalter —
vDSO-Implementierung ist für eine spätere Version geplant.

```lyx
type TimeSpec = flat struct {
    sec:  int64;
    nsec: int64;
};
```

**Abnahme**
- `sys_clock_get(CLOCK_MONO, &ts)` liefert monoton steigende Werte in Schleife
- `sys_clock_get(CLOCK_REAL, &ts)` liefert Unix-Epoch-Zeit (plausibel für aktuelles Jahr)
- Periodischer Timer: `sys_timer_create` + `sys_timer_set(fd, 10_000_000, 0)` (10 ms) feuert
  regelmäßig via `sys_notify_wait`
- `sys_timer_wait` liefert `overrun_count > 0` wenn Timer-Rate höher als Empfangsrate
- `CLOCK_CPU` und `CLOCK_THREAD` unterscheiden sich nach CPU-intensiver Arbeit

---

## Phase 4 — Sicherheit & Parallelismus

### LX-12 · Capabilities + Pledge + Unveil (0x0700–0x0708)

**Priorität:** Hoch

**Aufgabe**  
Das Capability-System vollständig implementieren: `sys_cap_create`, `sys_cap_restrict`,
`sys_cap_rights`, `sys_pledge`, `sys_unveil` sowie UID/GID-Operationen.

**Kontext**  
Dies ist das Sicherheitsfundament von Lyx OS. Jeder fd ist eine Capability —
Rechte können nur eingeschränkt, nie erweitert werden.

`sys_pledge` (0x0703) schränkt dauerhaft die erlaubten Syscall-Klassen ein.
Nach `sys_pledge("stdio rpath", "")` sind z.B. `sys_socket` oder `sys_spawn` verboten.

`sys_unveil` (0x0704) beschränkt den sichtbaren Dateisystem-Baum — nach dem ersten
Aufruf sind alle nicht explizit genannten Pfade unsichtbar (analog OpenBSD).

Integration in lyxc: `@capabilities`-Annotation in `src/lyxc.lyx` generiert
automatisch `sys_pledge`-Call am Programmstart (analog LCBS für Linux).

**Pledge-Promises** (aus syscalls.md):
```
"stdio"   – read/write/poll auf bestehenden fds
"rpath"   – Dateisystem lesend öffnen
"wpath"   – Dateisystem schreibend öffnen
"cpath"   – Dateien erzeugen/löschen
"exec"    – sys_spawn
"net"     – Socket-Syscalls
"thread"  – sys_thread_spawn
"memory"  – sys_mmap / sys_mprotect
"device"  – sys_ioctl
"ai"      – KI-Syscalls
"lyra"    – Lyra-Syscalls
"admin"   – privilegierte Syscalls
```

**Abnahme**
- `sys_pledge("stdio", "")` → nachfolgender `sys_open`-Aufruf → `ERR_CAPVIOL`
- `sys_cap_restrict(fd, RIGHT_READ)` → `sys_write` auf eingeschränktem fd → `ERR_CAPVIOL`
- `sys_cap_rights(cap_fd)` liefert exakt die gesetzten Rechte zurück
- `sys_unveil("/tmp", "rw")` + kein weiterer unveil → `sys_open("/etc/passwd", ...)` → `ERR_NOENT`
- lyxc erzeugt für `@capabilities("stdio")` automatisch `sys_pledge("stdio", "")` am Start
- Programm ohne `@capabilities` läuft uneingeschränkt (keine Auto-Pledge)

---

### LX-13 · Task-Scheduler & `@parallel` (0x0B00–0x0B09)

**Priorität:** Mittel

**Aufgabe**  
Alle 10 Task-Syscalls implementieren und die `@parallel`-Compiler-Annotation
für `--target=lyxos` in lyxc einbauen.

**Kontext**  
Tasks sind leichtgewichtiger als Threads — kein eigener Stack im Kernel-Sinn,
Work-Stealing über alle CPUs automatisch. `sys_task_group_*` ist die primäre
High-Level-API für datenparallele Arbeit.

Die `@parallel`-Annotation ist eine lyxc-Compiler-Erweiterung:
```lyx
@parallel for i in range 0..1000 {
    result[i] := compute(data[i]);
}
// lyxc generiert:
//   var g: int64 := sys_task_group_create(0)
//   for i in range 0..1000:
//     sys_task_group_add(g, wrapper, &ctx[i], sizeof(ctx[i]))
//   sys_task_group_await(g, -1)
```

Die Datenabhängigkeitsanalyse in lyxc prüft zur Compilezeit, ob Loop-Iterationen
unabhängig sind. Bei erkannter Abhängigkeit: Compile-Fehler mit Hinweis.

| Syscall | Nr |
|---------|-----|
| `sys_task_spawn` | 0x0B00 |
| `sys_task_await` | 0x0B01 |
| `sys_task_cancel` | 0x0B02 |
| `sys_task_group_create` | 0x0B03 |
| `sys_task_group_add` | 0x0B04 |
| `sys_task_group_await` | 0x0B05 |
| `sys_cpu_count` | 0x0B06 |
| `sys_cpu_topology` | 0x0B07 |
| `sys_affinity_hint` | 0x0B08 |
| `sys_numa_alloc` | 0x0B09 |

**Abnahme**
- `sys_task_group_create` + 8× `sys_task_group_add` + `sys_task_group_await`
  → alle 8 Tasks laufen, Ergebnis korrekt, Laufzeit ≈ 1/N × sequentiell
- `@parallel for i in range 0..100` auf unabhängigen Berechnungen → lyxc generiert task_group-Code
- `@parallel` mit Daten-Abhängigkeit zwischen Iterationen → Compile-Fehler
- `sys_cpu_count` → plausible Zahl (≥ 1, ≤ 512)
- `sys_task_cancel` auf abgeschlossenem Task → kein Fehler (`ERR_OK`)
- `sys_affinity_hint(task_fd, 0b0001)` → kein Fehler (hint, kein Mandat)

---

## Phase 5 — KI-Primitiven

### LX-14 · KI-Basis: Model + Context + Infer (0x0800–0x0806)

**Priorität:** Mittel

**Aufgabe**  
Die sechs Basis-KI-Syscalls implementieren: Modell laden/entladen/info,
Kontext erzeugen/vernichten, synchrone und asynchrone Inferenz.

**Kontext**  
KI-Modelle sind Kernel-verwaltete Ressourcen — Weights in Kernel-Shared-Memory,
lazy-load per Page-Fault. Mehrere Prozesse können dasselbe Modell-fd nutzen
ohne Kopie (Referenzzählung im Kernel).

`sys_ai_infer` (0x0805) ist asynchron — gibt einen Job-fd zurück, der per
`sys_poll` / `sys_notify_wait` (`NOTIFY_AI_DONE=5`) beobachtet werden kann.
`sys_ai_infer_sync` (0x0806) blockiert — nur für kurze Prompts.

```lyx
type AiInferOpts = flat struct {
    max_tokens:  int64;
    temperature: f32;
    top_p:       f32;
    seed:        int64;
    stop_tokens: int64;
    flags:       int64;
    timeout_ns:  int64;
};
```

Wenn das KI-Modul nicht geladen ist → alle 0x0800-Syscalls → `ERR_NOTSUP`.
Das muss graceful behandelt werden.

**Abnahme**
- `sys_ai_model_load(AT_CWD, "model.gguf", 0)` → Model-fd (oder `ERR_NOTSUP` ohne Modul)
- `sys_ai_model_info(model_fd, &info)` → `info.name`, `info.param_count`, `info.ctx_size` gesetzt
- `sys_ai_ctx_create(model_fd, 4096, 0)` → Context-fd
- `sys_ai_infer_sync(ctx_fd, "Hallo", 5, buf, 1024, &opts)` → Antwort in `buf`
- `sys_ai_infer` (async) → Job-fd; `sys_poll(job_fd, POLL_IN, -1)` gibt nach Completion zurück
- `sys_ai_model_unload` auf Model-fd mit aktiven Contexts → `ERR_BUSY`
- Bei nicht geladenem KI-Modul → `ERR_NOTSUP`, Programm behandelt Fehler graceful

---

### LX-15 · KI-Embedding & Vektorindex (0x0807–0x080C)

**Priorität:** Mittel

**Aufgabe**  
`sys_ai_embed`, `sys_ai_token_count`, `sys_ai_search`,
`sys_ai_index_create`, `sys_ai_index_insert`, `sys_ai_index_delete` implementieren.

**Kontext**  
Embeddings sind der Brücke zwischen Text und dem Kernel-Wissensgraphen.
`sys_ai_embed` erzeugt einen Float32-Vektor der Dimension `embed_dim` (modellabhängig,
typisch 384–4096). Der Vektorindex (HNSW-Approximation) lebt im Kernel-Heap.

```lyx
// Beispiel: Text einbetten und in Index einfügen
var ctx_fd := sys_ai_ctx_create(model_fd, 0, 0);
var vec: [384]f32;
var dim: int64 := 384;
sys_ai_embed(ctx_fd, "Hallo Welt", 10, &vec, &dim);
var idx_fd := sys_ai_index_create(384, IDX_HNSW);
sys_ai_index_insert(idx_fd, 1, &vec, 384, null, 0);
// k-NN-Suche
var results: [10]AiSearchResult;
var found := sys_ai_search(idx_fd, &query_vec, 384, 5, &results, 10);
```

**Abnahme**
- `sys_ai_embed` für "Hallo" und "Hi" → ähnliche Vektoren (Cosine-Similarity > 0.8)
- `sys_ai_embed` für "Hallo" und "Mathematik" → unähnlich (Similarity < 0.3)
- `sys_ai_token_count(ctx_fd, "Hello World", 11)` → 2 oder 3 (tokenizer-abhängig)
- `sys_ai_index_insert` 100 Einträge → `sys_ai_search` findet korrekte Top-5
- `sys_ai_index_delete(idx_fd, 42)` → 42 erscheint nicht mehr in Suchergebnissen
- `IDX_HNSW=1` Index ist schneller als Brute-Force (messbar ab 10.000 Einträgen)

---

### LX-16 · Semantisches Paging & Wissensgraph (0x080D–0x0812)

**Priorität:** Niedrig

**Aufgabe**  
`sys_sem_annotate`, `sys_sem_query`, `sys_graph_node_create`, `sys_graph_edge_add`,
`sys_graph_edge_remove`, `sys_graph_query` implementieren.

**Kontext**  
Dies ist das fortgeschrittenste Feature von Lyx OS: Der Kernel-Wissensgraph verknüpft
Dateien, Prozesse, Speicherregionen und Embeddings. `sys_sem_annotate` bindet
ein Embedding an eine Speicherregion — der VMM kann damit semantisch verwandte
Pages im L3-Cache halten.

`sys_graph_node_create` mit `GRAPH_AUTO_EMBED=2` löst automatisch `sys_ai_embed`
beim fd-Close aus und trägt das Ergebnis in den Graphen ein.

```lyx
type GraphQueryResult = flat struct {
    node_id:  int64;
    edge_id:  int64;
    rel_type: int64;
    weight:   f32;
    ts_ns:    int64;
    meta_len: int64;
    meta:     [128]uint8;
};
```

**Abnahme**
- `sys_graph_node_create(file_fd, GRAPH_PERSIST|GRAPH_AUTO_EMBED)` → Node-ID ≥ 1
- `sys_graph_edge_add(src, GRAPH_REL_REFERENCES, dst, null, 0)` → Edge-ID ≥ 1
- `sys_graph_query(node_id, GRAPH_REL_ANY, 2, &results, 10)` → Nachbarn korrekt
- `sys_graph_edge_remove(edge_id)` → Kante nicht mehr in Abfragen sichtbar
- `sys_sem_annotate(ptr, 4096, embed_fd)` → kein Fehler
- `sys_sem_query(&query_vec, 384, 3, &results, 10)` → findet annotierte Region

---

### LX-17 · Lyra Agent Interface (0x0900–0x090B)

**Priorität:** Niedrig

**Aufgabe**  
Alle 12 Lyra-Syscalls implementieren: Intent-Submission, episodisches Gedächtnis,
Context-Stack, Timeline-Query, Dream-Callbacks.

**Kontext**  
Nur Prozesse mit `sys_pledge(... "lyra" ...)` dürfen diese Syscalls nutzen.
`sys_intent_submit` übermittelt einen natürlichsprachlichen Intent an Lyra;
der Kernel leitet ihn asynchron an den Lyra-Scheduler weiter.

`sys_dream_register` ist besonders: Callbacks werden in CPU-Idle-Zyklen aufgerufen
(ähnlich macOS NSBackgroundActivityScheduler). Sie laufen nie wenn CPU-Last > 20%.

```lyx
// Intent-Submission
var id: int64 := sys_intent_submit("Öffne die zuletzt bearbeitete Datei", 37, 0);
sys_intent_wait(id, 5_000_000_000, result_fd);  // max 5s

// Episodisches Gedächtnis
sys_memory_store("last_file", "/home/andreas/project.lyx", 25, MEM_PERSIST);
var buf: [256]uint8;
var len: int64 := sys_memory_recall("last_file", &buf, 256);
```

**Abnahme**
- `sys_intent_submit` ohne "lyra"-Pledge → `ERR_CAPVIOL`
- `sys_intent_submit` mit Pledge → Intent-ID ≥ 1 (oder `ERR_NOTSUP` wenn Lyra nicht aktiv)
- `sys_memory_store` + `sys_memory_recall` → gespeicherter Wert korrekt zurückgelesen
- `sys_memory_recall` auf nicht existierenden Key → `ERR_NOENT`
- `sys_context_push` + `sys_context_pop` → Stack-Balance korrekt (kein Leak)
- `sys_dream_register(fn_fd, 60_000_000_000, 0)` → Dream-ID; Callback wird in Idle aufgerufen
- `sys_timeline_query(0, INT64_MAX, null, 0, &results, 10)` → alle Events zurück

---

## Phase 6 — IOFS

### LX-18 · IOFS: Island & Ocean File System (0x0C00–0x0C04)

**Priorität:** Niedrig

**Aufgabe**  
Die fünf IOFS-Syscalls implementieren: `sys_iofs_mount`, `sys_iofs_compact`,
`sys_iofs_page_info`, `sys_iofs_sandbox_enter`, `sys_iofs_sandbox_exit`.

**Kontext**  
IOFS ist das native Kernel-Dateisystem für Lyx OS — graphbasiert mit semantischen
Kanten, Content-ID statt Inode-Nummern. Normale Anwendungen greifen über das VFS
darauf zu; diese Syscalls sind für Admin-Tools und den Kernel selbst.

`sys_iofs_sandbox_enter` aktiviert die Panic-Sandbox: suspendiert alle KI-Prozesse,
mountet ein deterministic FS als Read-Write-Root — für Debugging und Recovery.

```lyx
type IofsPageHeader = @big_endian flat struct {
    page_id:    uint64;
    type_flags: uint64;
    payload_sz: uint32;
    edge_count: uint16;
    reserved:   uint16;
    ts_create:  int64;
    ts_modify:  int64;
    ts_access:  int64;
    crc32:      uint32;
    padding:    [52]uint8;   // Header = 128 Bytes total
};
```

**Abnahme**
- `sys_iofs_mount(dev_fd, &opts)` auf Block-Device → Mount-fd, FS zugänglich via VFS
- `sys_iofs_compact(mount_fd, -1)` → `NOTIFY_GRAPH_UPDATED` Events während Kompaktierung
- `sys_iofs_page_info(mount_fd, page_id, &info)` → Header-Felder korrekt
- `sys_iofs_sandbox_enter` (mit `CAP_ADMIN`) → KI-Prozesse suspendiert, Sandbox aktiv
- `sys_iofs_sandbox_exit` → KI-Prozesse resumed, IOFS wieder Root
- Ohne `CAP_ADMIN`: `sys_iofs_sandbox_enter` → `ERR_CAPVIOL`

---

## Phase 7 — Stdlib & Integration

### LX-19 · lyxrt_lyxos.lyx Runtime-Library

**Priorität:** Hoch

**Aufgabe**  
Die Lyx-OS-Runtime-Library `src/std/lyxos/lyxrt.lyx` erstellen — die minimale
Basis, die jedes lyxos-Programm automatisch bekommt.

**Kontext**  
Analog zu `lyxrt.lyx` für Linux. Enthält:
- `_start`-Symbol (aus LX-03)
- Alle Syscall-Wrapper als `extern`-Funktionen mit Inline-SYSCALL-Stubs
- Stack-Canary-Init
- `@capabilities`-Macro-Expansion → `sys_pledge`-Call
- Panic-Handler: `__lyxos_panic(msg, len)` → `sys_debug_print` + `sys_exit_group(1)`
- `alloc` / `free` auf `sys_mmap` / `sys_munmap`

Die Library wird bei `--target=lyxos` automatisch zum Compile-Lauf hinzugefügt,
wie unter Linux `libc` implizit verfügbar ist (nur ohne externe Abhängigkeit).

**Dateistruktur:**
```
src/std/lyxos/
  lyxrt.lyx      – _start, Canary, panic
  syscalls.lyx   – alle sys_* Wrapper
  fs.lyx         – VFS-Komfort-API
  net.lyx        – Socket-API
  time.lyx       – Uhr + Timer
  device.lyx     – Poll + ioctl
  security.lyx   – pledge, unveil, cap
  task.lyx       – Task-Scheduler-API
  ai.lyx         – KI-Primitiven
  lyra.lyx       – Lyra Agent Interface
  iofs.lyx       – IOFS-Admin-API
```

**Abnahme**
- `--target=lyxos` linkt `lyxrt.lyx` automatisch ohne expliziten Import
- `alloc` / `free` funktionieren in lyxos-Binary (aus LX-05)
- Panic-Handler gibt Meldung aus und beendet mit Exit-Code 1
- Alle Syscall-Wrapper haben korrekte Nummern (Test: strace-Verifikation)
- `make singularity` nach Hinzufügen der Library grün (S3 == S4)

---

### LX-20 · std/io.lyx + std/alloc.lyx lyxos-Adaptation

**Priorität:** Hoch

**Aufgabe**  
Die bestehenden Stdlib-Module `std/io.lyx` und `std/alloc.lyx` um lyxos-Pfade
erweitern — target-bedingte Compilation via `@target`-Annotation oder
Compile-Time-Konstante `TARGET_LYXOS`.

**Kontext**  
`std/io.lyx` nutzt aktuell `write()` syscall (Linux-Nr 1). Für lyxos muss es
`sys_write` (0x0203) mit anderem Calling-Convention nutzen. Da lyxc aktuell
keine target-bedingte Conditional-Compilation hat, wird in `ir_lower.lyx`
target-abhängig dispatcht (analog `emitBuiltinCall` pro Backend).

Alternative: separate Dateien `src/std/lyxos/io.lyx` die bei `--target=lyxos`
statt `src/std/io.lyx` gelinkt werden.

**Abnahme**
- `import std.io; PrintLn("test")` kompiliert für `--target=lyxos`
- Keine `#include libc`-Abhängigkeit im Binary
- `import std.alloc; var p := alloc(64)` funktioniert auf lyxos
- Alle bestehenden x86_64/arm64-Tests bleiben unverändert grün

---

### LX-21 · Zwei-Register-Rückgabe `var val, err :=`

**Priorität:** Mittel

**Aufgabe**  
Neue Syntax für Syscall-Rückgabe in lyxc einführen: `var result, err := expr`
dekonstruiert ein `(rdx, rax)`-Paar, das von Lyx-OS-Syscalls zurückgegeben wird.

**Kontext**  
Lyx OS gibt zwei Register zurück: `rax = Fehlercode`, `rdx = Nutzwert`.
lyxc muss das als eigenen Typ `(val: int64, err: int64)` unterstützen.

```lyx
// Neue Syntax:
var fd, err := sys_open(AT_CWD, "file.txt"c, O_READ, 0);
if err != ERR_OK {
    EPrintLn("open fehlgeschlagen");
    return 1;
}
// fd ist nun der gültige fd

// Alternativ mit _ zum Wegwerfen:
var buf_addr, _ := sys_mmap(0, 4096, PROT_RW, MAP_ANON);
```

**Implementierung:**
- Parser: neue Produktionsregel für `var a, b := expr`
- IR: neues `IRO_SPLIT_PAIR` Opcode oder Nutzung von zwei Dest-Slots
- Codegen für lyxos: Slot für `rdx`, separater Slot für `rax`
- Andere Targets: Syntaxzucker, `b` ist immer 0

**Abnahme**
- `var fd, err := sys_open(...)` parst ohne Fehler
- `err == 0` nach erfolgreichem open
- `err == ERR_NOENT` wenn Datei nicht existiert
- `var _, _ := expr` (beide wegwerfen) kompiliert
- x86_64 und arm64 Targets: Syntax parst; `b` ist immer 0 (kein Fehlercode)
- `make singularity` S3 == S4 nach dieser Änderung

---

### LX-22 · Debug & Telemetrie (0x0A00–0x0A05)

**Priorität:** Niedrig

**Aufgabe**  
Alle 6 Debug-Syscalls implementieren: `sys_debug_print`, `sys_trace_event`,
`sys_perf_counter`, `sys_stack_trace`, `sys_watchpoint_set`, `sys_watchpoint_clear`.

**Kontext**  
`sys_debug_print` (0x0A00) schreibt direkt auf Kernel-Debug-Output (Port 0xE9 /
COM1). In Release-Builds ist es ein No-Op. Wichtig für frühe Boot-Phasen wo noch
kein VFS verfügbar ist.

`sys_trace_event` wird intern von jedem KI-Inferenz-Aufruf automatisch gerufen
(Compliance/Audit). Abgreifbar über `/dev/trace` via normales `sys_read`.

**Abnahme**
- `sys_debug_print("boot\n", 5)` in Debug-Build → Ausgabe auf Debugcon sichtbar
- `sys_debug_print("boot\n", 5)` in Release-Build → No-Op, kein Fehler
- `sys_trace_event(1, &data, 8)` → Event in `/dev/trace` lesbar
- `sys_perf_counter(PERF_CYCLES=0)` → wachsender Wert in Schleife
- `sys_stack_trace(buf, 256)` → Frame-Adressen im Buffer, Frame-Anzahl > 0
- `sys_watchpoint_set(addr, 8, WP_WRITE=2)` → `NOTIFY_WATCHPOINT` bei Schreibzugriff

---

### LX-23 · Integrations-Testsuite & Singularitätsprüfung

**Priorität:** Hoch

**Aufgabe**  
Eine vollständige Integrations-Testsuite für das lyxos-Backend erstellen und
`make singularity` nach allen LX-Änderungen verifizieren.

**Kontext**  
Jedes abgeschlossene LX-Paket bekommt einen dedizierten Test in `tests/lyxos/`.
Die Tests kompilieren über `--emit=lbf` (LX-00) und laufen via `lbf_run` (LX-24)
auf POSIX-Linux — kein echter lyxos-Kernel nötig. Das `make test-lyxos`-Target
ruft für jeden Test automatisch:

```
./lyxc --target=lyxos --emit=lbf <test>.lyx -o /tmp/<test>.lbf
./lbf_run /tmp/<test>.lbf
```

**Teststruktur:**
```
tests/lyxos/
  lx00_lbf_magic.lyx     – .lbf-Header-Validierung (Magic, Version, FuncTable)
  lx03_entry.lyx         – Exit-Code 42 via sys_exit_group
  lx04_io.lyx            – PrintLn, PrintInt, EPrintLn
  lx05_alloc.lyx         – alloc, poke8, peek8, free
  lx06_fs.lyx            – open, read, write, stat, close
  lx08_net.lyx           – TCP Echo-Client/Server
  lx09_spawn.lyx         – sys_spawn, sys_wait
  lx10_mutex.lyx         – Mutex-Synchronisation 4 Threads
  lx11_timer.lyx         – Periodischer Timer
  lx12_pledge.lyx        – sys_pledge + ERR_CAPVIOL-Test
  lx13_parallel.lyx      – @parallel for-Schleife
  lx14_ai_infer.lyx      – sys_ai_infer_sync (ERR_NOTSUP graceful)
  lx21_two_ret.lyx       – var fd, err := sys_open(...)
```

**Abnahme**
- `make test-lyxos` führt alle Tests aus und liefert grünes Ergebnis
- Jeder Test gibt Exit-Code 0 und die erwartete Ausgabe
- `make singularity` S3 == S4 nach Fertigstellung aller LX-Pakete
- Keine Regression auf bestehenden x86_64/arm64/android-Tests

---

## Phase 8 — LBF-Interpreter

### LX-24 · lbf_run — POSIX-Interpreter (Lyx)

**Priorität:** Hoch

**Aufgabe**  
Den Interpreter `lbf_run` vollständig in Lyx implementieren: `.lbf`-Datei laden,
IR-Opcodes interpretieren, lyxos-Syscalls auf POSIX-Linux-Äquivalente mappen.
`lbf_run` ist das primäre Testfahrzeug für alle LX-Pakete bis ein echter
lyxos-Kernel existiert.

**Kontext**  
`lbf_run` kompiliert selbst zu `--target=x86_64` und läuft auf normalem Linux.
Es öffnet die `.lbf`-Datei, validiert den Header, baut eine IR-Dispatch-Schleife
und einen Call-Stack auf. Der Interpreter braucht kein JIT — reines Interpret-Loop
reicht für Funktionstests.

**Datei:** `src/tools/lbf_run.lyx` → Binary `./lbf_run`

**Architektur:**

```lyx
// Haupt-Ausführungsschleife
fn interpFunc(state: InterpState, funcIdx: int64): int64 {
    var ip: int64 := state.funcs[funcIdx].firstInstr;
    var end: int64 := ip + state.funcs[funcIdx].instrCount;
    while ip < end {
        var op: int64 := state.instrOp(ip);
        if op == IRO_CONST_INT   { ... }
        else if op == IRO_ADD    { ... }
        ...
        else if op == IRO_CALL_BUILTIN { dispatchSyscall(state, ip); }
        ip := ip + 1;
    }
    return state.retVal;
}
```

**Syscall-Mapping (lyxos → POSIX Linux):**

| lyxos Syscall-Nr | lyxos Name | POSIX-Äquivalent | Linux-Nr |
|-----------------|------------|-----------------|---------|
| 0x0002 | `sys_exit_group` | `exit_group` / `exit` | 231 |
| 0x000C | `sys_getrandom` | `getrandom` | 318 |
| 0x0100 | `sys_mmap` | `mmap` | 9 |
| 0x0101 | `sys_munmap` | `munmap` | 11 |
| 0x0202 | `sys_read` | `read` | 0 |
| 0x0203 | `sys_write` | `write` | 1 |
| 0x0200 | `sys_open` | `openat` | 257 |
| 0x0201 | `sys_close` | `close` | 3 |
| 0x0204 | `sys_seek` | `lseek` | 8 |
| 0x0205 | `sys_stat` | `newfstatat` | 262 |
| 0x0206 | `sys_fstat` | `fstat` | 5 |
| 0x020B | `sys_dup` | `dup3` | 292 |
| 0x020C | `sys_pipe` | `pipe2` | 293 |
| 0x0211 | `sys_getcwd` | `getcwd` | 79 |
| 0x0300 | `sys_poll` | `ppoll` | 271 |
| 0x0500 | `sys_clock_get` | `clock_gettime` | 228 |
| 0x0503 | `sys_timer_create` | `timer_create` | 222 |
| 0x0600 | `sys_socket` | `socket` | 41 |
| 0x0601 | `sys_bind` | `bind` | 49 |
| 0x0602 | `sys_listen` | `listen` | 50 |
| 0x0603 | `sys_accept` | `accept4` | 288 |
| 0x0604 | `sys_connect` | `connect` | 42 |
| 0x0605 | `sys_sendmsg` | `sendmsg` | 46 |
| 0x0606 | `sys_recvmsg` | `recvmsg` | 47 |
| 0x0609 | `sys_shutdown` | `shutdown` | 48 |

Syscalls ohne POSIX-Äquivalent (KI, Lyra, Capabilities, IOFS) → `lbf_run` gibt
`ERR_NOTSUP` zurück. Das ist das korrekte Verhalten: Tests für diese Pakete prüfen
explizit `ERR_NOTSUP`-Behandlung.

**Rückgabe-Konvention:** lyxos gibt `(rax=err, rdx=val)` zurück. `lbf_run` simuliert
das intern als zwei Slots: `slot_err` und `slot_val`. Bei `var fd, err := sys_open(...)`
wird `slot_val` → `fd`, `slot_err` → `err`.

**Slot-Modell:**

```lyx
type InterpState = class {
    slots:    [1024]int64;   // Locals (entsprechen IR-Slots)
    stack:    [256]int64;    // Call-Stack (Rücksprungadressen)
    sp:       int64;
    retVal:   int64;
    retErr:   int64;
    strPool:  int64;         // Zeiger auf den String-Pool-Puffer
    funcs:    int64;         // Zeiger auf FuncEntry-Array
    instrs:   int64;         // Zeiger auf Instr-Array
    instrCnt: int64;
};
```

**Build:**
```
./lyxc src/tools/lbf_run.lyx -o lbf_run
```

**Abnahme**
- `./lbf_run /tmp/entry.lbf` → Exit-Code 42 (lx03_entry)
- `./lbf_run /tmp/io.lbf` → stdout: `Hello Lyx OS\n` (lx04_io)
- `./lbf_run /tmp/alloc.lbf` → kein Segfault, poke8/peek8 korrekt (lx05_alloc)
- `./lbf_run /tmp/fs.lbf` → Datei wird gelesen und Inhalt ausgegeben (lx06_fs)
- `./lbf_run /tmp/net.lbf` → TCP-Echo-Roundtrip erfolgreich (lx08_net)
- `./lbf_run /tmp/ai.lbf` → `ERR_NOTSUP` für 0x0800-Syscalls, Programm behandelt graceful
- `./lbf_run --help` → Usage-Text mit unterstützten lyxos-Syscall-Mappings
- `./lbf_run /tmp/corrupt.lbf` → Fehler "Invalid LBF magic", Exit-Code 1
- `make test-lyxos` nutzt `lbf_run` als einziges Test-Backend (kein QEMU nötig)

---

## Anhang — Syscall-Nummer-Referenz

Alle Nummern aus `work/lyxos/syscalls.md` (ABI v1.0):

| Bereich | Kategorie | Syscalls | LX-Paket |
|---------|-----------|----------|----------|
| 0x0000–0x000D | Prozess & Threads | 14 | LX-03 + LX-09 |
| 0x0100–0x0105 | Speicher | 6 | LX-05 |
| 0x0200–0x0215 | Dateisystem & VFS | 22 | LX-06 |
| 0x0300–0x0305 | I/O & Geräte | 6 | LX-07 |
| 0x0400–0x040C | IPC & Synchronisation | 13 | LX-10 |
| 0x0500–0x0504 | Zeit | 5 | LX-11 |
| 0x0600–0x0609 | Netzwerk | 10 | LX-08 |
| 0x0700–0x0708 | Sicherheit & Capabilities | 9 | LX-12 |
| 0x0800–0x0812 | KI & Semantik + Wissensgraph | 19 | LX-14/15/16 |
| 0x0900–0x090B | Lyra Agent Interface | 12 | LX-17 |
| 0x0A00–0x0A05 | Debug & Telemetrie | 6 | LX-22 |
| 0x0B00–0x0B09 | Task & Automatische Parallelität | 10 | LX-13 |
| 0x0C00–0x0C04 | IOFS | 5 | LX-18 |
| **Gesamt** | | **137** | **25 LX-Pakete** |

**Zusatz-Pakete (nicht syscall-gebunden):**

| LX | Beschreibung |
|----|-------------|
| LX-00 | LBF-Format & `--emit=lbf` — portables IR-Bytecode-Ausgabeformat |
| LX-24 | `lbf_run` — POSIX-Interpreter in Lyx; übersetzt lyxos-Syscalls auf Linux |

---

*Dokument-Version: 1.1 | Aktualisiert: 2026-06-09 | Basis: syscalls.md ABI v1.0 | lyxc v0.9.5A*
