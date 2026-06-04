# Syscall-Fahrplan — Fehlende Linux-Syscalls in Lyx

> Erstellt: 2026-06-04
> Basis: `work/linux-syscalls.md` (461 Syscalls, Kernel x86-64)
> Status: ⬜ geplant | 🔄 in Arbeit | ✅ erledigt

---

## Übersicht

| Phase | Schwerpunkt | WPs | Aufwand | Prio |
|-------|------------|-----|---------|------|
| 1 | 🔴 Datei-I/O & Prozessinfrastruktur | WP-1 – WP-3 | ~5 Tage | Hoch |
| 2 | 🔴 I/O-Multiplexing & Netzwerk | WP-4 – WP-6 | ~5 Tage | Hoch |
| 3 | 🟠 System & Scheduling | WP-7 – WP-9 | ~4 Tage | Mittel |
| 4 | 🟠 IPC & Dateisystem-Überwachung | WP-10 – WP-12 | ~4 Tage | Mittel |
| 5 | 🟡 Speicher & io_uring | WP-13 – WP-14 | ~4 Tage | Niedrig |
| 6 | 🟡 Sicherheit & Namespaces | WP-15 – WP-16 | ~3 Tage | Niedrig |
| 7 | 🔵 Erweitert / Spezialgebiet | WP-17 – WP-20 | ~6 Tage | Sehr Niedrig |

**Implementierungsprinzip:** Jedes WP besteht aus zwei Teilen:
1. **Compiler-Builtins** in `src/codegen_x86.lyx` — `sys_*`-Intrinsics für direkte Syscall-Emission
2. **Stdlib-Unit** in `std/` — benannte Wrapper-Funktionen mit sicherer API

---

## Phase 1 — 🔴 Datei-I/O & Prozessinfrastruktur

---

### WP-1: Erweitertes Datei-I/O

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_fstat`, `sys_pread64`, `sys_pwrite64`, `sys_readv`, `sys_writev`, `sys_access`, `sys_fsync`, `sys_fdatasync`, `sys_truncate`, `sys_ftruncate`, `sys_getcwd`, `sys_chdir`, `sys_sendfile` |
| **Syscall-Nummern** | 5, 17, 18, 19, 20, 21, 40, 74, 75, 76, 77, 79, 80 |
| **Stdlib-Unit** | `std/fs_ext.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** Häufig benötigte Dateioperationen fehlen:
- Kein `fstat()` → kein Abruf von Dateigröße/Mtime über offenen fd
- Kein `pread64`/`pwrite64` → immer `lseek` + `read`/`write` nötig (nicht atomar)
- Kein `readv`/`writev` → kein Scatter-Gather-I/O für Zero-Copy
- Kein `sendfile` → Dateiübertragung zu Sockets nur mit User-Space-Puffer möglich
- Kein `fsync`/`fdatasync` → keine garantierte Persistenz nach Schreiboperationen
- Kein `getcwd` → Prozess kennt sein Arbeitsverzeichnis nicht

**Stdlib-API (`std/fs_ext.lyx`):**
```lyx
pub fn Fstat(fd: int64, statBuf: int64): int64         // fstat(fd, &stat)
pub fn PRead(fd: int64, buf: int64, n: int64, off: int64): int64
pub fn PWrite(fd: int64, buf: int64, n: int64, off: int64): int64
pub fn ReadV(fd: int64, iov: int64, iovcnt: int64): int64
pub fn WriteV(fd: int64, iov: int64, iovcnt: int64): int64
pub fn FileAccess(path: pchar, mode: int64): bool       // access(path, R_OK|W_OK|X_OK)
pub fn Fsync(fd: int64): int64
pub fn Fdatasync(fd: int64): int64
pub fn Truncate(path: pchar, length: int64): int64
pub fn Ftruncate(fd: int64, length: int64): int64
pub fn GetCwd(buf: int64, size: int64): int64           // buf = alloc(PATH_MAX)
pub fn Chdir(path: pchar): int64
pub fn Sendfile(outFd: int64, inFd: int64, offset: int64, count: int64): int64

// Hilfskonstanten für access()
pub con F_OK: int64 := 0;  pub con R_OK: int64 := 4;
pub con W_OK: int64 := 2;  pub con X_OK: int64 := 1;

// iovec für ReadV/WriteV
pub con IOVEC_SIZE: int64 := 16;  // {base:8, len:8}
pub fn IovecCreate(buf: int64, idx: int64, base: int64, len: int64)
pub fn IovecBase(buf: int64, idx: int64): int64
pub fn IovecLen(buf: int64, idx: int64): int64
```

**Teilschritte:**
- [ ] **1.1** Builtins in `codegen_x86.lyx` (13 Syscalls)
- [ ] **1.2** `std/fs_ext.lyx` mit den Wrapper-Funktionen
- [ ] **1.3** stat-Buffer-Konstanten (st_size, st_mtime, st_mode Offsets)
- [ ] **1.4** iovec-Helfer für ReadV/WriteV

---

### WP-2: Pipes & fd-Duplikation

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_pipe`, `sys_pipe2`, `sys_dup`, `sys_dup2`, `sys_dup3` |
| **Syscall-Nummern** | 22, 293, 32, 33, 292 |
| **Stdlib-Unit** | `std/pipe.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** Ohne Pipes und fd-Duplikation ist kein vollständiges Prozessmanagement möglich:
- `fork` + `exec` ohne `pipe2` → keine Prozesskommunikation (stdin/stdout Weiterleitung)
- Kein `dup2` → kein Redirect von stdin/stdout auf Pipes
- Essentiell für Shell-artige Programme, Daemon-Logging, Subprozess-Kontrolle

**Stdlib-API (`std/pipe.lyx`):**
```lyx
// Pipe-Flags für pipe2
pub con O_CLOEXEC:  int64 := 0x80000;
pub con O_NONBLOCK: int64 := 0x800;

pub fn PipeCreate(readFdOut: int64, writeFdOut: int64): int64
pub fn Pipe2(readFdOut: int64, writeFdOut: int64, flags: int64): int64
pub fn FdDup(oldFd: int64): int64                 // dup
pub fn FdDup2(oldFd: int64, newFd: int64): int64  // dup2
pub fn FdDup3(oldFd: int64, newFd: int64, flags: int64): int64
// Ergänzung std/process.lyx:
pub fn ProcessPipeConnect(pid: int64, stdinFd: int64, stdoutFd: int64): int64
```

**Teilschritte:**
- [ ] **2.1** Builtins in `codegen_x86.lyx`
- [ ] **2.2** `std/pipe.lyx` mit PipeCreate, Pipe2, FdDup*
- [ ] **2.3** `std/process.lyx` ergänzen: ProcessPipeConnect (fork + dup2 + exec)

---

### WP-3: Signalbehandlung

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_rt_sigaction`, `sys_rt_sigprocmask`, `sys_rt_sigreturn`, `sys_sigaltstack`, `sys_signalfd4`, `sys_kill` |
| **Syscall-Nummern** | 13, 14, 15, 131, 289, 62 |
| **Stdlib-Unit** | `std/signal.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** Lyx-Programme können keine Signale behandeln. Jedes `Ctrl+C`, `SIGTERM` oder `SIGSEGV` terminiert unkontrolliert — kein Cleanup möglich. Auch Daemon-Programmierung (SIGHUP für Config-Reload) ist unmöglich.

**Stdlib-API (`std/signal.lyx`):**
```lyx
// Signalnummern
pub con SIGINT:  int64 := 2;   pub con SIGTERM: int64 := 15;
pub con SIGHUP:  int64 := 1;   pub con SIGUSR1: int64 := 10;
pub con SIGUSR2: int64 := 12;  pub con SIGCHLD: int64 := 17;
pub con SIGPIPE: int64 := 13;  pub con SIGALRM: int64 := 14;
pub con SIGSEGV: int64 := 11;  pub con SIGKILL: int64 := 9;

// SIG_DFL = 0, SIG_IGN = 1
pub con SIG_DFL: int64 := 0;
pub con SIG_IGN: int64 := 1;

// sigaction-Struktur (32 Bytes: handler:8, flags:8, restorer:8, mask:8)
pub con SIGACTION_SIZE: int64 := 32;
pub con SA_RESTORER:    int64 := 0x04000000;
pub con SA_SIGINFO:     int64 := 4;
pub con SA_RESTART:     int64 := 0x10000000;

pub fn SignalSet(signum: int64, handler: int64): int64
pub fn SignalIgnore(signum: int64): int64
pub fn SignalDefault(signum: int64): int64
pub fn SignalMaskBlock(signum: int64): int64
pub fn SignalMaskUnblock(signum: int64): int64
pub fn SignalFd(signals: int64, sigset: int64): int64  // signalfd4
pub fn SignalSend(pid: int64, signum: int64): int64     // kill
pub fn SignalSendThread(pid: int64, tid: int64, sig: int64): int64  // tgkill (234)
```

**Teilschritte:**
- [ ] **3.1** Builtins in `codegen_x86.lyx`
- [ ] **3.2** `std/signal.lyx` — sigaction-Struct + Wrapper
- [ ] **3.3** Signal-Restorer-Trampolin (benötigt Assembly-Stub für rt_sigreturn)
- [ ] **3.4** signalfd4 + Integration mit epoll (WP-5)

---

## Phase 2 — 🔴 I/O-Multiplexing & Netzwerk

---

### WP-4: Zeit & Timer

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_nanosleep`, `sys_clock_nanosleep`, `sys_gettimeofday`, `sys_timerfd_create`, `sys_timerfd_settime`, `sys_timerfd_gettime` |
| **Syscall-Nummern** | 35, 230, 96, 283, 286, 287 |
| **Stdlib-Unit** | `std/time.lyx` (Erweiterung) |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** `std/time.lyx` hat `clock_gettime` aber kein `nanosleep` — Programme können nicht präzise schlafen. Kein `timerfd` → keine Timer-Integration in epoll-Loops.

**Stdlib-API:**
```lyx
pub fn Sleep(ms: int64): int64              // nanosleep (Millisekunden)
pub fn SleepNs(ns: int64): int64           // nanosleep (Nanosekunden)
pub fn SleepUntil(clockId: int64, absNs: int64): int64  // clock_nanosleep TIMER_ABSTIME
pub fn GetTimeOfDay(tvSec: int64, tvUsec: int64): int64 // gettimeofday

// timerfd (integrierbar mit epoll)
pub fn TimerFdCreate(clockId: int64, flags: int64): int64
pub fn TimerFdSetTime(fd: int64, intervalNs: int64, valueNs: int64): int64
pub fn TimerFdRead(fd: int64): int64        // liest uint64 (Ablaufanzahl)
```

**Teilschritte:**
- [ ] **4.1** Builtins in `codegen_x86.lyx`
- [ ] **4.2** `std/time.lyx` — Sleep/SleepNs, TimerFd*
- [ ] **4.3** itimerspec-Hilfsfunktionen

---

### WP-5: epoll & I/O-Multiplexing

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_epoll_create1`, `sys_epoll_ctl`, `sys_epoll_pwait`, `sys_epoll_pwait2`, `sys_eventfd2`, `sys_ppoll` |
| **Syscall-Nummern** | 291, 233, 281, 441, 290, 271 |
| **Stdlib-Unit** | `std/net/epoll.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** `sys_poll` (WP-1 Bluetooth) reicht für kleine Programm, aber hochperformante Server (>1000 Verbindungen) brauchen `epoll`. Kein `eventfd` → keine thread-sichere Signalisierung ohne Pipe-Overhead.

**Stdlib-API (`std/net/epoll.lyx`):**
```lyx
// epoll_event-Struktur: {events:4, data_u64:8} = 12 Bytes (aber 16 wegen Alignment)
pub con EPOLL_EVENT_SIZE: int64 := 16;
pub con EPOLLIN:          int64 := 1;
pub con EPOLLOUT:         int64 := 4;
pub con EPOLLERR:         int64 := 8;
pub con EPOLLHUP:         int64 := 16;
pub con EPOLLRDHUP:       int64 := 0x2000;
pub con EPOLLET:          int64 := 0x80000000;  // Edge-Triggered
pub con EPOLLONESHOT:     int64 := 0x40000000;

pub con EPOLL_CTL_ADD: int64 := 1;
pub con EPOLL_CTL_DEL: int64 := 2;
pub con EPOLL_CTL_MOD: int64 := 3;

pub fn EpollCreate(): int64                     // epoll_create1(EPOLL_CLOEXEC)
pub fn EpollAdd(epFd: int64, fd: int64, events: int64, data: int64): int64
pub fn EpollMod(epFd: int64, fd: int64, events: int64, data: int64): int64
pub fn EpollDel(epFd: int64, fd: int64): int64
pub fn EpollWait(epFd: int64, evBuf: int64, maxEvents: int64, timeoutMs: int64): int64
pub fn EpollEventFd(evBuf: int64, idx: int64): int64   // data_fd aus epoll_event
pub fn EpollEventData(evBuf: int64, idx: int64): int64 // data_u64 aus epoll_event
pub fn EpollEventFlags(evBuf: int64, idx: int64): int64

pub fn EventFdCreate(initVal: int64): int64     // eventfd2(0, EFD_CLOEXEC)
pub fn EventFdSignal(fd: int64): int64          // write 1
pub fn EventFdRead(fd: int64): int64            // read (räumt auf)
```

**Teilschritte:**
- [ ] **5.1** Builtins in `codegen_x86.lyx`
- [ ] **5.2** `std/net/epoll.lyx` — Epoll + EventFd API
- [ ] **5.3** Beispiel: Event-Loop-Grundgerüst mit EpollWait
- [ ] **5.4** Integration: EpollAdd für TimerFd, SignalFd, Socket-FDs

---

### WP-6: Netzwerk-Ergänzungen

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_getsockname`, `sys_getpeername`, `sys_accept4`, `sys_recvmmsg`, `sys_sendmmsg` |
| **Syscall-Nummern** | 51, 52, 288, 299, 307 |
| **Stdlib-Unit** | `std/net/socket.lyx` (Erweiterung) |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔴 Hoch |
| **Status** | ⬜ |

**Problem:** Häufig genutzte Socket-Funktionen fehlen:
- `getsockname`/`getpeername` → Server kennt eigene Adresse nicht (z.B. nach bind mit Port 0)
- `accept4` mit `SOCK_NONBLOCK` → Non-Blocking Sockets ohne Extra-fcntl
- `recvmmsg`/`sendmmsg` → Batch-I/O für UDP-Server (erheblicher Throughput-Gewinn)

**Stdlib-API:**
```lyx
pub fn SocketGetOwnAddr(fd: int64, addrBuf: int64, addrLen: int64): int64
pub fn SocketGetPeerAddr(fd: int64, addrBuf: int64, addrLen: int64): int64
pub fn AcceptNonBlocking(fd: int64, addrBuf: int64, addrLen: int64): int64
pub fn RecvMmsg(fd: int64, msgvec: int64, vlen: int64, flags: int64): int64
pub fn SendMmsg(fd: int64, msgvec: int64, vlen: int64, flags: int64): int64
// mmsghdr-Hilfsfunktionen (Struktur: msghdr:56 + msg_len:4 + pad:4 = 64 Bytes)
pub con MMSGHDR_SIZE: int64 := 64;
```

**Teilschritte:**
- [ ] **6.1** Builtins in `codegen_x86.lyx`
- [ ] **6.2** `std/net/socket.lyx` ergänzen

---

## Phase 3 — 🟠 System & Scheduling

---

### WP-7: Prozess-Credentials & Systeminfo

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_getuid`, `sys_getgid`, `sys_geteuid`, `sys_getegid`, `sys_getppid`, `sys_uname`, `sys_setsid`, `sys_setpgid`, `sys_getpgrp`, `sys_setuid`, `sys_setgid` |
| **Syscall-Nummern** | 102, 104, 107, 108, 110, 63, 112, 109, 111, 105, 106 |
| **Stdlib-Unit** | `std/process_ext.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/process_ext.lyx`):**
```lyx
pub fn GetUID(): int64;    pub fn GetGID(): int64
pub fn GetEUID(): int64;   pub fn GetEGID(): int64
pub fn GetPPID(): int64
pub fn SetUID(uid: int64): int64;  pub fn SetGID(gid: int64): int64
pub fn SetSID(): int64             // Neue Session (Daemon-Basis)
pub fn SetPGID(pid: int64, pgid: int64): int64
pub fn GetPGRP(): int64

// uname → {sysname, nodename, release, version, machine} je 65 Bytes
pub fn GetUname(buf: int64): int64     // buf = alloc(400)
pub fn GetUnameRelease(outBuf: int64): int64   // nur Kernel-Version
pub fn GetUnameMachine(outBuf: int64): int64   // z.B. "x86_64"

// Hilfsfunktion: ist der Prozess root?
pub fn IsRoot(): bool
```

**Teilschritte:**
- [ ] **7.1** Builtins in `codegen_x86.lyx`
- [ ] **7.2** `std/process_ext.lyx`

---

### WP-8: Scheduling & CPU-Affinität

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_sched_yield`, `sys_sched_setaffinity`, `sys_sched_getaffinity`, `sys_getpriority`, `sys_setpriority`, `sys_getcpu` |
| **Syscall-Nummern** | 24, 203, 204, 140, 141, 309 |
| **Stdlib-Unit** | `std/sched.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/sched.lyx`):**
```lyx
pub fn SchedYield(): int64               // CPU freiwillig abgeben
pub fn SchedSetAffinity(pid: int64, cpuMask: int64): int64
pub fn SchedGetAffinity(pid: int64, outMask: int64): int64
pub fn GetPriority(pid: int64): int64    // Nice-Wert (-20..19)
pub fn SetPriority(pid: int64, nice: int64): int64
pub fn GetCPU(cpuOut: int64, nodeOut: int64): int64

// CPU-Affinity-Masken-Helfer (cpu_set_t = 128 Bytes auf Linux)
pub con CPU_SET_SIZE: int64 := 128;
pub fn CpuSetZero(buf: int64)
pub fn CpuSetAdd(buf: int64, cpu: int64)
pub fn CpuSetHas(buf: int64, cpu: int64): bool
```

**Teilschritte:**
- [ ] **8.1** Builtins in `codegen_x86.lyx`
- [ ] **8.2** `std/sched.lyx`

---

### WP-9: erweiterte Memory-Operationen

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_mremap`, `sys_madvise`, `sys_msync`, `sys_memfd_create`, `sys_munlock`, `sys_mincore` |
| **Syscall-Nummern** | 25, 28, 26, 319, 150, 27 |
| **Stdlib-Unit** | `std/mmap_ext.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/mmap_ext.lyx`):**
```lyx
pub con MADV_SEQUENTIAL:  int64 := 2;
pub con MADV_RANDOM:      int64 := 1;
pub con MADV_WILLNEED:    int64 := 3;
pub con MADV_DONTNEED:    int64 := 4;
pub con MADV_FREE:        int64 := 8;
pub con MADV_HUGEPAGE:    int64 := 14;

pub con MS_SYNC:      int64 := 4;
pub con MS_ASYNC:     int64 := 1;
pub con MS_INVALIDATE: int64 := 2;

pub fn MmapResize(addr: int64, oldSize: int64, newSize: int64): int64
pub fn MmapAdvise(addr: int64, len: int64, advice: int64): int64
pub fn MmapSync(addr: int64, len: int64, flags: int64): int64
pub fn MemFdCreate(name: pchar, flags: int64): int64
pub fn MemUnlock(addr: int64, len: int64): int64
pub fn MemInCore(addr: int64, len: int64, vecOut: int64): int64
```

**Teilschritte:**
- [ ] **9.1** Builtins in `codegen_x86.lyx`
- [ ] **9.2** `std/mmap_ext.lyx`

---

## Phase 4 — 🟠 IPC & Dateisystem-Überwachung

---

### WP-10: inotify — Dateisystem-Überwachung

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_inotify_init1`, `sys_inotify_add_watch`, `sys_inotify_rm_watch` |
| **Syscall-Nummern** | 294, 254, 255 |
| **Stdlib-Unit** | `std/inotify.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/inotify.lyx`):**
```lyx
pub con IN_CREATE:     int64 := 0x100;   pub con IN_DELETE:     int64 := 0x200;
pub con IN_MODIFY:     int64 := 0x2;     pub con IN_CLOSE_WRITE: int64 := 0x8;
pub con IN_MOVED_FROM: int64 := 0x40;   pub con IN_MOVED_TO:   int64 := 0x80;
pub con IN_ALL_EVENTS: int64 := 0xFFF;
pub con IN_NONBLOCK:   int64 := 0x800;  pub con IN_CLOEXEC:    int64 := 0x80000;

// inotify_event: {wd:4, mask:4, cookie:4, len:4, name:len}
pub con INOTIFY_EVENT_HDR_SIZE: int64 := 16;

pub fn InotifyCreate(): int64
pub fn InotifyWatch(fd: int64, path: pchar, mask: int64): int64   // returns wd
pub fn InotifyUnwatch(fd: int64, wd: int64): int64
pub fn InotifyRead(fd: int64, buf: int64, bufSize: int64): int64  // sys_read
pub fn InotifyEventMask(buf: int64): int64
pub fn InotifyEventName(buf: int64): int64   // Zeiger auf den name-Teil
pub fn InotifyEventLen(buf: int64): int64    // Länge des name-Teils
```

**Teilschritte:**
- [ ] **10.1** Builtins in `codegen_x86.lyx`
- [ ] **10.2** `std/inotify.lyx`
- [ ] **10.3** Beispiel: Verzeichnis auf neue Dateien überwachen

---

### WP-11: POSIX Message Queues

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_mq_open`, `sys_mq_unlink`, `sys_mq_timedsend`, `sys_mq_timedreceive`, `sys_mq_getsetattr` |
| **Syscall-Nummern** | 240, 241, 242, 243, 245 |
| **Stdlib-Unit** | `std/mqueue.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/mqueue.lyx`):**
```lyx
pub con MQ_OPEN_RDONLY: int64 := 0;  pub con MQ_OPEN_WRONLY: int64 := 1;
pub con MQ_OPEN_RDWR:   int64 := 2;  pub con MQ_OPEN_CREATE: int64 := 0x40;
pub con MQ_OPEN_EXCL:   int64 := 0x80;

pub fn MqOpen(name: pchar, flags: int64, mode: int64): int64
pub fn MqClose(fd: int64): int64
pub fn MqUnlink(name: pchar): int64
pub fn MqSend(fd: int64, msg: int64, msgLen: int64, prio: int64): int64
pub fn MqRecv(fd: int64, buf: int64, bufLen: int64, prioOut: int64): int64
pub fn MqTimedSend(fd: int64, msg: int64, msgLen: int64, prio: int64, timeoutNs: int64): int64
pub fn MqTimedRecv(fd: int64, buf: int64, bufLen: int64, prioOut: int64, timeoutNs: int64): int64
```

**Teilschritte:**
- [ ] **11.1** Builtins in `codegen_x86.lyx` — Hinweis: mq_open hat 5-Arg-ABI (r10 für 4. Arg)
- [ ] **11.2** `std/mqueue.lyx`

---

### WP-12: SysV IPC — Shared Memory, Semaphore, Message Queues

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_shmget`, `sys_shmat`, `sys_shmctl`, `sys_shmdt`, `sys_semget`, `sys_semop`, `sys_semctl`, `sys_msgget`, `sys_msgsnd`, `sys_msgrcv`, `sys_msgctl` |
| **Syscall-Nummern** | 29, 30, 31, 67, 64, 65, 66, 68, 69, 70, 71 |
| **Stdlib-Unit** | `std/ipc_sysv.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🟠 Mittel |
| **Status** | ⬜ |

**Stdlib-API (`std/ipc_sysv.lyx`):**
```lyx
// Shared Memory
pub con IPC_PRIVATE:  int64 := 0;
pub con IPC_CREAT:    int64 := 0x200;
pub con IPC_EXCL:     int64 := 0x400;
pub con IPC_RMID:     int64 := 0;

pub fn ShmCreate(key: int64, size: int64, flags: int64): int64   // shmget
pub fn ShmAttach(shmId: int64, addr: int64, flags: int64): int64 // shmat
pub fn ShmDetach(addr: int64): int64                              // shmdt
pub fn ShmDelete(shmId: int64): int64                             // shmctl IPC_RMID

// Semaphore
pub fn SemCreate(key: int64, nsems: int64, flags: int64): int64  // semget
pub fn SemWait(semId: int64, semNum: int64): int64               // semop -1
pub fn SemPost(semId: int64, semNum: int64): int64               // semop +1
pub fn SemDelete(semId: int64): int64

// SysV Message Queues
pub fn MsgQueueCreate(key: int64, flags: int64): int64           // msgget
pub fn MsgSend(mqId: int64, buf: int64, size: int64, flags: int64): int64
pub fn MsgRecv(mqId: int64, buf: int64, size: int64, msgType: int64, flags: int64): int64
pub fn MsgQueueDelete(mqId: int64): int64
```

**Teilschritte:**
- [ ] **12.1** Builtins in `codegen_x86.lyx` (11 Syscalls)
- [ ] **12.2** `std/ipc_sysv.lyx` — Shared Memory + Semaphore + MsgQueue

---

## Phase 5 — 🟡 Speicher & io_uring

---

### WP-13: io_uring — Asynchrones I/O

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_io_uring_setup`, `sys_io_uring_enter`, `sys_io_uring_register` |
| **Syscall-Nummern** | 425, 426, 427 |
| **Stdlib-Unit** | `std/io_uring.lyx` |
| **Aufwand** | 3 Tage |
| **Priorität** | 🟡 Niedrig |
| **Status** | ⬜ |

**Problem:** io_uring ist die modernste Linux-I/O-API (seit Kernel 5.1). Für höchste I/O-Performance (File-Server, Datenbankserver) unersetzlich. Komplex: Submission Queue (SQE) + Completion Queue (CQE) über mmap.

**Stdlib-API (`std/io_uring.lyx`):**
```lyx
pub fn IoUringCreate(entries: int64, paramsOut: int64): int64   // io_uring_setup
pub fn IoUringEnter(fd: int64, toSubmit: int64, minComplete: int64, flags: int64): int64
// Low-level: SQE/CQE direkt über mmap-Offsets zugänglich
pub fn IoUringGetSQE(ring: int64): int64   // nächste freie SQE
pub fn IoUringSubmit(ring: int64): int64
pub fn IoUringCQESeen(ring: int64, cqe: int64)

// Op-Codes für SQEs
pub con IORING_OP_READ:    int64 := 22;
pub con IORING_OP_WRITE:   int64 := 23;
pub con IORING_OP_ACCEPT:  int64 := 13;
pub con IORING_OP_CONNECT: int64 := 16;
pub con IORING_OP_SEND:    int64 := 26;
pub con IORING_OP_RECV:    int64 := 27;
pub con IORING_OP_TIMEOUT: int64 := 11;
```

**Teilschritte:**
- [ ] **13.1** Builtins in `codegen_x86.lyx`
- [ ] **13.2** `std/io_uring.lyx` — Ring-Buffer-Verwaltung, SQE/CQE-Zugriff
- [ ] **13.3** Beispiel: Read/Write über io_uring

---

### WP-14: Erweiterte Dateiattribute (xattr) & Dateisystem

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_setxattr`, `sys_getxattr`, `sys_listxattr`, `sys_removexattr`, `sys_fsetxattr`, `sys_fgetxattr`, `sys_flistxattr`, `sys_fremovexattr`, `sys_fallocate`, `sys_statfs` |
| **Syscall-Nummern** | 188, 191, 194, 197, 190, 193, 196, 199, 285, 137 |
| **Stdlib-Unit** | `std/xattr.lyx`, Erweiterung `std/fs_ext.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟡 Niedrig |
| **Status** | ⬜ |

**Stdlib-API:**
```lyx
// xattr
pub fn XattrSet(path: pchar, name: pchar, val: int64, size: int64): int64
pub fn XattrGet(path: pchar, name: pchar, buf: int64, size: int64): int64
pub fn XattrList(path: pchar, buf: int64, size: int64): int64
pub fn XattrRemove(path: pchar, name: pchar): int64
// fd-Varianten: FXattrSet, FXattrGet, FXattrList, FXattrRemove

// Dateisystem-Statistik
pub fn StatFs(path: pchar, buf: int64): int64   // buf = alloc(120)
pub fn StatFsFreeBlocks(buf: int64): int64
pub fn StatFsTotalBlocks(buf: int64): int64

// Voralloziierung
pub fn FileAllocate(fd: int64, offset: int64, size: int64): int64
```

---

## Phase 6 — 🟡 Sicherheit & Namespaces

---

### WP-15: Linux Capabilities & prctl

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_capget`, `sys_capset`, `sys_prctl`, `sys_arch_prctl` |
| **Syscall-Nummern** | 125, 126, 157, 158 |
| **Stdlib-Unit** | `std/security_ext.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟡 Niedrig |
| **Status** | ⬜ |

**Stdlib-API (`std/security_ext.lyx`):**
```lyx
pub con PR_SET_NAME:     int64 := 15;   // Prozessname setzen
pub con PR_GET_NAME:     int64 := 16;
pub con PR_SET_DUMPABLE: int64 := 4;    // Core-Dump erlauben/sperren
pub con PR_SET_NO_NEW_PRIVS: int64 := 38;
pub con PR_CAP_AMBIENT:  int64 := 47;

pub fn ProcessSetName(name: pchar): int64
pub fn ProcessGetName(outBuf: int64): int64
pub fn ProcessSetNoNewPrivs(): int64    // sicherheitskritisch: einweg!
pub fn CapGet(capBuf: int64): int64
pub fn CapSet(capBuf: int64): int64
pub fn CapDrop(capNum: int64): int64    // einzelne Capability fallen lassen
```

---

### WP-16: Namespaces, pidfd & Prozess-Isolation

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_pidfd_open`, `sys_pidfd_send_signal`, `sys_pidfd_getfd`, `sys_unshare`, `sys_setns` |
| **Syscall-Nummern** | 434, 424, 438, 272, 308 |
| **Stdlib-Unit** | `std/ns.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🟡 Niedrig |
| **Status** | ⬜ |

**Stdlib-API (`std/ns.lyx`):**
```lyx
pub con CLONE_NEWPID:  int64 := 0x20000000;
pub con CLONE_NEWNET:  int64 := 0x40000000;
pub con CLONE_NEWNS:   int64 := 0x00020000;
pub con CLONE_NEWUSER: int64 := 0x10000000;
pub con CLONE_NEWUTS:  int64 := 0x04000000;
pub con CLONE_NEWIPC:  int64 := 0x08000000;

pub fn PidFdOpen(pid: int64, flags: int64): int64
pub fn PidFdSendSignal(pidfd: int64, sig: int64): int64
pub fn PidFdGetFd(pidfd: int64, targetFd: int64): int64
pub fn NamespaceUnshare(flags: int64): int64
pub fn NamespaceJoin(fd: int64, nsType: int64): int64
```

---

## Phase 7 — 🔵 Erweitert / Spezialgebiet

---

### WP-17: Thread-Synchronisierung — Futex-Varianten (Kernel 5.16+)

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_futex_waitv`, `sys_futex_wake`, `sys_futex_wait`, `sys_futex_requeue` |
| **Syscall-Nummern** | 449, 454, 455, 456 |
| **Stdlib-Unit** | `std/thread.lyx` (Erweiterung) |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔵 Sehr Niedrig |
| **Status** | ⬜ |

---

### WP-18: Debugging & Performance-Monitoring

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_ptrace`, `sys_perf_event_open` |
| **Syscall-Nummern** | 101, 298 |
| **Stdlib-Unit** | `std/debug.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔵 Sehr Niedrig |
| **Status** | ⬜ |

---

### WP-19: BPF-Programme

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_bpf` |
| **Syscall-Nummern** | 321 |
| **Stdlib-Unit** | `std/bpf.lyx` |
| **Aufwand** | 3 Tage |
| **Priorität** | 🔵 Sehr Niedrig |
| **Status** | ⬜ |

**Hinweis:** BPF ist ein vollständiges Subsystem mit eigener Instruction-Set-Architecture. Eine sinnvolle Lyx-API erfordert einen BPF-Assembler oder Integration mit `libbpf`.

---

### WP-20: System-Administration (root-only)

| Attribut | Wert |
|----------|------|
| **Compiler-Builtins** | `sys_mount`, `sys_umount2`, `sys_chroot`, `sys_statfs`, `sys_sethostname`, `sys_reboot`, `sys_sync` |
| **Syscall-Nummern** | 165, 166, 161, 137, 170, 169, 162 |
| **Stdlib-Unit** | `std/sysadmin.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔵 Sehr Niedrig |
| **Status** | ⬜ |

**Stdlib-API (`std/sysadmin.lyx`):**
```lyx
pub fn Mount(source: pchar, target: pchar, fsType: pchar, flags: int64): int64
pub fn Umount(target: pchar, flags: int64): int64
pub fn Chroot(path: pchar): int64
pub fn SetHostname(name: pchar, len: int64): int64
pub fn SyncAll(): int64
pub fn Reboot(magic: int64): int64   // LINUX_REBOOT_MAGIC1 erforderlich
```

---

## Bearbeitungsstatus

| WP | Titel | Status | Prio | Stdlib-Unit |
|----|-------|--------|------|-------------|
| 1 | Erweitertes Datei-I/O | ⬜ | 🔴 | `std/fs_ext.lyx` |
| 2 | Pipes & fd-Duplikation | ⬜ | 🔴 | `std/pipe.lyx` |
| 3 | Signalbehandlung | ⬜ | 🔴 | `std/signal.lyx` |
| 4 | Zeit & Timer | ⬜ | 🔴 | `std/time.lyx` (Erweiterung) |
| 5 | epoll & I/O-Multiplexing | ⬜ | 🔴 | `std/net/epoll.lyx` |
| 6 | Netzwerk-Ergänzungen | ⬜ | 🔴 | `std/net/socket.lyx` (Erweiterung) |
| 7 | Prozess-Credentials | ⬜ | 🟠 | `std/process_ext.lyx` |
| 8 | Scheduling & CPU-Affinität | ⬜ | 🟠 | `std/sched.lyx` |
| 9 | Memory-Erweiterungen | ⬜ | 🟠 | `std/mmap_ext.lyx` |
| 10 | inotify | ⬜ | 🟠 | `std/inotify.lyx` |
| 11 | POSIX Message Queues | ⬜ | 🟠 | `std/mqueue.lyx` |
| 12 | SysV IPC | ⬜ | 🟠 | `std/ipc_sysv.lyx` |
| 13 | io_uring | ⬜ | 🟡 | `std/io_uring.lyx` |
| 14 | xattr & Dateisystem | ⬜ | 🟡 | `std/xattr.lyx` |
| 15 | Linux Capabilities & prctl | ⬜ | 🟡 | `std/security_ext.lyx` |
| 16 | Namespaces & pidfd | ⬜ | 🟡 | `std/ns.lyx` |
| 17 | Futex-Varianten (Kernel 5.16+) | ⬜ | 🔵 | `std/thread.lyx` (Erweiterung) |
| 18 | Debugging & Perf | ⬜ | 🔵 | `std/debug.lyx` |
| 19 | BPF | ⬜ | 🔵 | `std/bpf.lyx` |
| 20 | System-Administration | ⬜ | 🔵 | `std/sysadmin.lyx` |

---

## Implementierungshinweise

### Compiler-Builtins (codegen_x86.lyx)

Jedes neue `sys_*`-Builtin folgt dem Muster:

```lyx
} else if (self.cg_seq(fname, fnlen, "sys_nanosleep", 13)) {
  // nanosleep(req, rem): int64 -- syscall 35
  self.cg_movRaxImm(35); self.cg_e8(0x0F); self.cg_e8(0x05);
```

Für Syscalls mit 4+ Argumenten (4. Arg in `r10`, nicht `rcx`):
```lyx
self.cg_e8(0x49); self.cg_e8(0x89); self.cg_e8(0xCA);  // mov r10, rcx
self.cg_movRaxImm(N); self.cg_e8(0x0F); self.cg_e8(0x05);
```

### Stdlib-Units: Namenskonventionen

- Funktionen: PascalCase (`FdDup`, `EpollAdd`, `SignalSet`)
- Konstanten: UPPER_SNAKE (`EPOLLIN`, `CLONE_NEWNET`)
- Buffer-Größen als Konstanten mit `_SIZE`-Suffix
- Fehlercodes: Rückgabe < 0 = Fehler (Kernel-Konvention beibehalten)
- Kein Wrapping negativer Fehler — Aufrufer prüft `ret < 0`
