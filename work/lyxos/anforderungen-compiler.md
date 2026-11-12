# Anforderungen an LyxOS aus dem Compiler und der Standardbibliothek

Stand: lyxc 1.1.4J · gemessen am 2026-08-20 · Bezug: #1720 (Block C)

## Worum es geht

Die Standardbibliothek ruft Systemaufrufe, die LyxOS nicht hat. Betroffen sind
**99 Aufrufe in 32 Units**. Der Compiler kann sie nicht uebersetzen, ohne eine
Nummer zu erfinden — und genau das war 2026 der Fehler aus #795: Hex-Nummern,
die im Kernel echte Handler trafen.

Diese Liste sagt, **was gebraucht wird und wofuer**. Sie ist keine Bestellung:
ein Teil davon gehoert vermutlich gar nicht auf dieses Betriebssystem, und die
betroffenen Units laufen dort dann eben nicht. Die Entscheidung darueber liegt
bei euch; wir liefern die Messung.

## Wie gemessen wurde

Nachvollziehbar aus dem Compiler-Baum:

```
tests/builtin_drift_test.sh        # Rueckstand zwischen sema und ir_lower
tests/lyxos_stdlib_import_test.sh  # welche stdlib-Units gegen --target=lyxos bauen
```

Gezaehlt sind nur **echte Aufrufstellen** — Kommentare, Typangaben und
`pub fn`-Definitionen sind ausgenommen. Eine fruehere Fassung dieser Liste war
um drei Namen zu lang, weil sie `// +4: len (uint32)` und die Annotation
`@cap(system.time)` mitzaehlte.

## Was der Compiler in der Zwischenzeit tut

Nichts erfinden. Ein Aufruf ohne Entsprechung meldet **`-ENOSYS`**, damit der
Aufrufer die Wahrheit erfaehrt und die Unit trotzdem uebersetzt (Vorbild: die
timerfd-Familie, ID 239). Eine plausibel aussehende Fehluebersetzung waere das
Schlechtere — sie faellt erst zur Laufzeit auf, und dann an der falschen
Stelle.

Was LyxOS schon hat (62 Aufrufe, `work/lyxos/syscalls.md` §10.4), ist
angebunden und steht hier nicht.

## Vorschlag zur Reihenfolge

**Zuerst — ohne diese bleibt ein ganzer Bereich unbenutzbar:**

| Aufruf | Stellen | warum |
|---|---:|---|
| `sys_recvfrom`, `sys_sendto` | 29 | die gesamte Bluetooth- und Socket-Strecke |
| `sys_fcntl` | 10 | nicht-blockierende Deskriptoren, in vielen Units vorausgesetzt |
| `sys_select` | 5 | Warten auf mehrere Deskriptoren; ohne Ersatz gibt es keine Ereignisschleife |
| `sys_access` | 4 | Existenz- und Rechtepruefung vor dem Oeffnen |

**Danach — einzeln nuetzlich, aber kein Bereich haengt daran:**
`sys_dup2`/`sys_dup3`, `sys_pread64`/`sys_pwrite64`, `sys_ftruncate`,
`sys_fsync`/`sys_fdatasync`, `sys_uname`, `sys_kill`, `sys_getcpu`.

**Vermutlich nicht — hier waere die ehrliche Antwort, dass die betreffenden
Units auf LyxOS nicht laufen:** `sys_ptrace`, `sys_bpf`, `sys_io_uring_*`,
`sys_chroot`, `sys_unshare`, `sys_setns`, `sys_clone`. Das sind
Linux-Eigenheiten; sie nachzubauen bindet Aufwand fuer Units, die auf diesem
System ohnehin keinen Zweck haben.

**Offene Frage an euch:** fuer `epoll`, `eventfd`, `signalfd` und `inotify`
gibt es auf LyxOS bereits ein eigenes Ereignismodell
(`sys_event_send`/`sys_event_recv`, `sys_notify_*`). Sinnvoller als eine
Nachbildung waere vermutlich, die stdlib auf **euer** Modell zu heben. Dafuer
braeuchten wir eine Zusage, welches der beiden das kuenftige ist.

## Vollstaendige Liste

### Netzwerk

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_recvfrom` | 16 | `hardware.bluetooth`, `hardware.bluetooth_gattc`, `hardware.bluetooth_l2cap`, `hardware.bluetooth_rfcomm` *(+4)* |
| `sys_sendto` | 13 | `hardware.bluetooth`, `hardware.bluetooth_gattc`, `hardware.bluetooth_l2cap`, `hardware.bluetooth_rfcomm` *(+4)* |
| `sys_accept4` | 2 | `net.socket` |
| `sys_getsockname` | 2 | `net.socket` |
| `sys_getpeername` | 2 | `net.socket` |
| `sys_sendmmsg` | 1 | `net.socket` |
| `sys_recvmmsg` | 1 | `net.socket` |
| `sys_sethostname` | 1 | `sysadmin` |

### Dateideskriptoren und Dateisystem

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_fcntl` | 10 | `net.internal.syscalls_android`, `net.internal.syscalls_linux`, `net.socket`, `net.syscalls` |
| `sys_select` | 5 | `db.postgres`, `net.ssh`, `net.syscalls` |
| `sys_access` | 4 | `fs_ext` |
| `sys_dup2` | 3 | `pipe`, `process` |
| `sys_epoll_ctl` | 3 | `net.epoll` |
| `sys_eventfd2` | 3 | `hardware.pci_irq`, `net.epoll` |
| `sys_pread64` | 2 | `fs_ext`, `hardware.pci_syscalls` |
| `sys_pwrite64` | 2 | `fs_ext`, `hardware.pci_syscalls` |
| `sys_fallocate` | 2 | `xattr` |
| `sys_dup3` | 1 | `pipe` |
| `sys_epoll_create1` | 1 | `net.epoll` |
| `sys_epoll_wait` | 1 | `net.epoll` |
| `sys_signalfd4` | 1 | `signals` |
| `sys_pipe2` | 1 | `pipe` |
| `sys_readv` | 1 | `fs_ext` |
| `sys_writev` | 1 | `fs_ext` |
| `sys_sendfile` | 1 | `fs_ext` |
| `sys_ftruncate` | 1 | `fs_ext` |
| `sys_fsync` | 1 | `fs_ext` |
| `sys_fdatasync` | 1 | `fs_ext` |
| `sys_statfs` | 1 | `xattr` |
| `sys_memfd_create` | 1 | `mmap_ext` |
| `sys_inotify_init1` | 1 | `inotify` |
| `sys_inotify_add_watch` | 1 | `inotify` |
| `sys_inotify_rm_watch` | 1 | `inotify` |
| `sys_umount2` | 1 | `sysadmin` |

### Prozesse, Signale, Rechte

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_ptrace` | 9 | `debug` |
| `sys_kill` | 6 | `process`, `signals` |
| `sys_prctl` | 6 | `security_ext` |
| `sys_uname` | 6 | `process_ext` |
| `sys_rt_sigprocmask` | 3 | `signals` |
| `sys_arch_prctl` | 2 | `security_ext` |
| `sys_getcpu` | 2 | `sched` |
| `sys_clone` | 1 | `thread` |
| `sys_tgkill` | 1 | `signals` |
| `sys_setpgid` | 1 | `process_ext` |
| `sys_geteuid` | 1 | `process_ext` |
| `sys_setpriority` | 1 | `sched` |
| `sys_getpriority` | 1 | `sched` |
| `sys_rt_sigaction` | 1 | `signals` |
| `sys_pidfd_open` | 1 | `ns` |
| `sys_pidfd_getfd` | 1 | `ns` |
| `sys_pidfd_send_signal` | 1 | `ns` |
| `sys_capget` | 1 | `security_ext` |
| `sys_capset` | 1 | `security_ext` |
| `sys_chroot` | 1 | `sysadmin` |
| `sys_unshare` | 1 | `ns` |
| `sys_setns` | 1 | `ns` |
| `sys_reboot` | 1 | `sysadmin` |

### Speicher

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_mremap` | 2 | `mmap_ext` |
| `sys_madvise` | 2 | `mmap_ext` |
| `sys_mincore` | 2 | `mmap_ext` |
| `sys_mlock` | 1 | `mmap_ext` |
| `sys_munlock` | 1 | `mmap_ext` |
| `sys_msync` | 1 | `mmap_ext` |
| `sys_shmget` | 1 | `ipc_sysv` |
| `sys_shmat` | 1 | `ipc_sysv` |
| `sys_shmdt` | 1 | `ipc_sysv` |
| `sys_shmctl` | 1 | `ipc_sysv` |

### Nachrichten, Semaphoren, Futex

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_semctl` | 3 | `ipc_sysv` |
| `sys_mq_getsetattr` | 3 | `mqueue` |
| `sys_semop` | 2 | `ipc_sysv` |
| `sys_mq_open` | 2 | `mqueue` |
| `sys_mq_timedsend` | 2 | `mqueue` |
| `sys_mq_timedreceive` | 2 | `mqueue` |
| `sys_futex_wake` | 2 | `thread` |
| `sys_msgget` | 1 | `ipc_sysv` |
| `sys_msgsnd` | 1 | `ipc_sysv` |
| `sys_msgrcv` | 1 | `ipc_sysv` |
| `sys_msgctl` | 1 | `ipc_sysv` |
| `sys_semget` | 1 | `ipc_sysv` |
| `sys_mq_unlink` | 1 | `mqueue` |
| `sys_futex_wait` | 1 | `thread` |
| `sys_futex_requeue` | 1 | `thread` |
| `sys_futex_waitv` | 1 | `thread` |

### Erweiterte Attribute

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_getxattr` | 1 | `xattr` |
| `sys_setxattr` | 1 | `xattr` |
| `sys_listxattr` | 1 | `xattr` |
| `sys_removexattr` | 1 | `xattr` |
| `sys_fgetxattr` | 1 | `xattr` |
| `sys_fsetxattr` | 1 | `xattr` |
| `sys_flistxattr` | 1 | `xattr` |
| `sys_fremovexattr` | 1 | `xattr` |

### Zeit und Planung

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_perf_event_open` | 2 | `debug` |
| `sys_sched_yield` | 1 | `sched` |
| `sys_sched_getaffinity` | 1 | `sched` |
| `sys_sched_setaffinity` | 1 | `sched` |

### Linux-eigen (vermutlich kein LyxOS-Thema)

| Aufruf | Stellen | gebraucht von |
|---|---:|---|
| `sys_bpf` | 5 | `bpf` |
| `sys_io_uring_enter` | 4 | `io_uring` |
| `sys_io_uring_setup` | 1 | `io_uring` |

## Was wir bei einer Zusage tun

Pro zugesagtem Aufruf: Nummer und Argumentfolge aus eurer Tabelle uebernehmen,
im Lowerer eine ID vergeben, im lyxos-Backend anbinden, Eintrag in
`src/backend/_builtin_ids.md`. Das ist Fliessarbeit, sobald die Semantik
feststeht — was fehlt, ist nicht der Code, sondern die verbindliche Zusage,
**welche** Nummer **was** tut.

Umgekehrt gilt: sagt ihr fuer einen Aufruf ab, tragen wir ihn dauerhaft als
`-ENOSYS` ein und vermerken im Code, dass das eine Entscheidung war und keine
Luecke.
