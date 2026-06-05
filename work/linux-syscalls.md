# Fehlende Linux x86-64 Syscalls in Lyx

Stand: 2026-06-04 · Kernel-Quelle: `/usr/include/x86_64-linux-gnu/asm/unistd_64.h` (461 Syscalls, 0–461)

## Bereits implementiert (57 Syscalls)

| Nr | Name |
|----|------|
| 0 | `read` |
| 1 | `write` |
| 2 | `open` |
| 3 | `close` |
| 4 | `stat` |
| 6 | `lstat` |
| 7 | `poll` |
| 8 | `lseek` |
| 9 | `mmap` |
| 10 | `mprotect` |
| 11 | `munmap` |
| 12 | `brk` |
| 16 | `ioctl` |
| 39 | `getpid` |
| 41 | `socket` |
| 42 | `connect` |
| 43 | `accept` |
| 44 | `sendto` |
| 45 | `recvfrom` |
| 46 | `sendmsg` |
| 47 | `recvmsg` |
| 48 | `shutdown` |
| 49 | `bind` |
| 50 | `listen` |
| 53 | `socketpair` |
| 54 | `setsockopt` |
| 55 | `getsockopt` |
| 56 | `clone` |
| 57 | `fork` |
| 59 | `execve` |
| 60 | `exit` |
| 61 | `wait4` |
| 62 | `kill` |
| 72 | `fcntl` |
| 82 | `rename` |
| 83 | `mkdir` |
| 84 | `rmdir` |
| 87 | `unlink` |
| 88 | `symlink` |
| 89 | `readlink` |
| 90 | `chmod` |
| 149 | `mlock` |
| 151 | `mlockall` |
| 186 | `gettid` |
| 202 | `futex` |
| 217 | `getdents64` |
| 228 | `clock_gettime` |
| 231 | `exit_group` |
| 234 | `tgkill` |
| 257 | `openat` |
| 263 | `unlinkat` |
| 314 | `sched_setattr` |
| 318 | `getrandom` |
| 322 | `execveat` |
| 332 | `statx` |
| 444 | `landlock_create_ruleset` |
| 445 | `landlock_add_rule` |
| 446 | `landlock_restrict_self` |

---

## Fehlende Syscalls (404 Syscalls)

### I/O — Datei

| Nr | Name | Beschreibung |
|----|------|-------------|
| 5 | `fstat` | Dateiinfo über fd |
| 17 | `pread64` | Lesen an Offset (ohne lseek) |
| 18 | `pwrite64` | Schreiben an Offset (ohne lseek) |
| 19 | `readv` | Scatter-Lesen (mehrere Puffer) |
| 20 | `writev` | Gather-Schreiben (mehrere Puffer) |
| 21 | `access` | Dateizugriff prüfen |
| 40 | `sendfile` | Datei zu Socket senden (zero-copy) |
| 73 | `flock` | Advisory file locking |
| 74 | `fsync` | Dateipuffer auf Disk flushen |
| 75 | `fdatasync` | Datenpuffer flushen (ohne Metadaten) |
| 76 | `truncate` | Datei auf Größe kürzen |
| 77 | `ftruncate` | Datei über fd kürzen |
| 78 | `getdents` | Verzeichniseinträge (veraltet, 32-bit) |
| 79 | `getcwd` | Aktuelles Verzeichnis |
| 80 | `chdir` | Verzeichnis wechseln |
| 81 | `fchdir` | Verzeichnis wechseln über fd |
| 85 | `creat` | Datei erstellen (veraltet, = open+flags) |
| 86 | `link` | Hardlink erstellen |
| 91 | `fchmod` | Dateiberechtigungen über fd ändern |
| 92 | `chown` | Dateieigentümer ändern |
| 93 | `fchown` | Dateieigentümer über fd ändern |
| 94 | `lchown` | Dateieigentümer (kein Symlink-Follow) |
| 95 | `umask` | Datei-Erstellungsmaske setzen |
| 132 | `utime` | Zeitstempel setzen (veraltet) |
| 133 | `mknod` | Gerätedatei / FIFO erstellen |
| 187 | `readahead` | Datei vorab in Page-Cache lesen |
| 221 | `fadvise64` | Zugriffsmuster dem Kernel mitteilen |
| 258 | `mkdirat` | Verzeichnis relativ zu fd erstellen |
| 259 | `mknodat` | Gerätedatei relativ zu fd erstellen |
| 260 | `fchownat` | Eigentümer relativ zu fd ändern |
| 261 | `futimesat` | Zeitstempel relativ zu fd setzen |
| 262 | `newfstatat` | stat relativ zu fd |
| 264 | `renameat` | Umbenennen relativ zu fd |
| 265 | `linkat` | Hardlink relativ zu fd |
| 266 | `symlinkat` | Symlink relativ zu fd |
| 267 | `readlinkat` | Symlink lesen relativ zu fd |
| 268 | `fchmodat` | chmod relativ zu fd |
| 269 | `faccessat` | access relativ zu fd |
| 275 | `splice` | Daten zwischen fd und Pipe bewegen |
| 276 | `tee` | Pipe-Inhalt duplizieren |
| 277 | `sync_file_range` | Teile einer Datei flushen |
| 278 | `vmsplice` | Userspace-Speicher in Pipe schreiben |
| 280 | `utimensat` | Zeitstempel nanosekunden-genau setzen |
| 285 | `fallocate` | Speicherplatz für Datei vorbelegen |
| 295 | `preadv` | Scatter-Lesen an Offset |
| 296 | `pwritev` | Gather-Schreiben an Offset |
| 306 | `syncfs` | Gesamtes Dateisystem-Flush |
| 316 | `renameat2` | Atomares Umbenennen (mit Flags) |
| 326 | `copy_file_range` | Datei zu Datei kopieren (zero-copy) |
| 327 | `preadv2` | preadv mit Flags |
| 328 | `pwritev2` | pwritev mit Flags |
| 436 | `close_range` | Mehrere fds auf einmal schließen |
| 437 | `openat2` | openat mit erweiterten Optionen |
| 439 | `faccessat2` | faccessat mit Flags |
| 451 | `cachestat` | Cache-Statistik für Dateibereich |
| 452 | `fchmodat2` | fchmodat mit Flags |

### I/O — Polling / Multiplexing

| Nr | Name | Beschreibung |
|----|------|-------------|
| 23 | `select` | I/O-Multiplexing (veraltet) |
| 232 | `epoll_wait` | epoll-Ereignisse warten |
| 233 | `epoll_ctl` | epoll-Instanz verwalten |
| 270 | `pselect6` | select mit Signalmaske |
| 271 | `ppoll` | poll mit Signalmaske |
| 281 | `epoll_pwait` | epoll_wait mit Signalmaske |
| 284 | `eventfd` | Eventfd-Deskriptor erstellen |
| 290 | `eventfd2` | eventfd mit Flags |
| 291 | `epoll_create1` | epoll erstellen mit Flags |
| 213 | `epoll_create` | epoll erstellen (veraltet) |
| 441 | `epoll_pwait2` | epoll_pwait mit Timeout-Struktur |

### I/O — Asynchronous (io_uring / AIO)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 206 | `io_setup` | AIO-Kontext erstellen (klassisch) |
| 207 | `io_destroy` | AIO-Kontext zerstören |
| 208 | `io_getevents` | AIO-Ereignisse abholen |
| 209 | `io_submit` | AIO-Operationen einreichen |
| 210 | `io_cancel` | AIO-Operation abbrechen |
| 333 | `io_pgetevents` | io_getevents mit Signalmaske |
| 425 | `io_uring_setup` | io_uring-Instanz erstellen |
| 426 | `io_uring_enter` | io_uring-Operationen einreichen/warten |
| 427 | `io_uring_register` | io_uring-Ressourcen registrieren |

### Memory

| Nr | Name | Beschreibung |
|----|------|-------------|
| 25 | `mremap` | Mapping vergrößern/verkleinern/verschieben |
| 26 | `msync` | Memory-Mapping auf Disk flushen |
| 27 | `mincore` | Seiten im RAM prüfen |
| 28 | `madvise` | Zugriffshinweise für Mapping |
| 150 | `munlock` | Seiten wieder auslagerbar machen |
| 152 | `munlockall` | Alle Seiten wieder auslagerbar |
| 319 | `memfd_create` | Anonyme Datei im RAM erstellen |
| 323 | `userfaultfd` | Userspace-Seitenfehlbehandlung |
| 324 | `membarrier` | Speicherbarriere zwischen Threads |
| 325 | `mlock2` | mlock mit Flags |
| 329 | `pkey_mprotect` | mprotect mit Memory Protection Keys |
| 330 | `pkey_alloc` | Memory Protection Key anlegen |
| 331 | `pkey_free` | Memory Protection Key freigeben |
| 447 | `memfd_secret` | Geheimen Memory-Bereich erstellen |
| 453 | `map_shadow_stack` | Shadow-Stack mappen (CET) |

### Pipes

| Nr | Name | Beschreibung |
|----|------|-------------|
| 22 | `pipe` | Pipe erstellen |
| 293 | `pipe2` | Pipe mit Flags erstellen |

### Netzwerk — Fehlende Funktionen

| Nr | Name | Beschreibung |
|----|------|-------------|
| 51 | `getsockname` | Eigene Adresse des Sockets |
| 52 | `getpeername` | Gegenseiten-Adresse des Sockets |
| 288 | `accept4` | accept mit Flags (z. B. SOCK_NONBLOCK) |
| 299 | `recvmmsg` | Mehrere Nachrichten empfangen |
| 307 | `sendmmsg` | Mehrere Nachrichten senden |

### Prozess

| Nr | Name | Beschreibung |
|----|------|-------------|
| 58 | `vfork` | Fork mit Copy-on-Write-Semantik |
| 63 | `uname` | Systeminfo (Kernel-Version etc.) |
| 110 | `getppid` | Parent-Prozess-ID |
| 200 | `tkill` | Signal an Thread senden (veraltet) |
| 247 | `waitid` | Auf Kindprozess warten (erweitert) |
| 312 | `kcmp` | Zwei Prozesse auf geteilte Ressourcen prüfen |
| 434 | `pidfd_open` | Prozess als fd referenzieren |
| 424 | `pidfd_send_signal` | Signal via pidfd senden |
| 438 | `pidfd_getfd` | fd eines anderen Prozesses duplizieren |
| 435 | `clone3` | clone mit erweiterter Struktur |
| 448 | `process_mrelease` | Speicher eines beendeten Prozesses freigeben |

### fd-Duplikation

| Nr | Name | Beschreibung |
|----|------|-------------|
| 32 | `dup` | fd duplizieren |
| 33 | `dup2` | fd auf bestimmten Wert duplizieren |
| 292 | `dup3` | dup2 mit Flags |

### Signale

| Nr | Name | Beschreibung |
|----|------|-------------|
| 13 | `rt_sigaction` | Signalhandler registrieren |
| 14 | `rt_sigprocmask` | Signalmaske setzen |
| 15 | `rt_sigreturn` | Aus Signalhandler zurückkehren |
| 127 | `rt_sigpending` | Ausstehende Signale abfragen |
| 128 | `rt_sigtimedwait` | Auf Signal warten (mit Timeout) |
| 129 | `rt_sigqueueinfo` | Signal mit Daten senden |
| 130 | `rt_sigsuspend` | Prozess auf Signal suspendieren |
| 131 | `sigaltstack` | Alternativen Signal-Stack setzen |
| 282 | `signalfd` | Signale über fd empfangen |
| 289 | `signalfd4` | signalfd mit Flags |
| 297 | `rt_tgsigqueueinfo` | Signal mit Daten an Thread |

### Zeit / Timer

| Nr | Name | Beschreibung |
|----|------|-------------|
| 34 | `pause` | Prozess pausieren bis Signal |
| 35 | `nanosleep` | Nanosekunden schlafen |
| 36 | `getitimer` | Intervall-Timer auslesen |
| 37 | `alarm` | SIGALRM in N Sekunden |
| 38 | `setitimer` | Intervall-Timer setzen |
| 96 | `gettimeofday` | Uhrzeit (veraltet, → clock_gettime) |
| 164 | `settimeofday` | Uhrzeit setzen (root) |
| 201 | `time` | Unix-Timestamp (veraltet) |
| 222 | `timer_create` | POSIX-Timer erstellen |
| 223 | `timer_settime` | POSIX-Timer starten/stoppen |
| 224 | `timer_gettime` | POSIX-Timer auslesen |
| 225 | `timer_getoverrun` | Timer-Überlaufzähler |
| 226 | `timer_delete` | POSIX-Timer löschen |
| 227 | `clock_settime` | Uhr setzen |
| 229 | `clock_getres` | Uhren-Auflösung abfragen |
| 230 | `clock_nanosleep` | Schlafen relativ zu einer Uhr |
| 235 | `utimes` | Zeitstempel setzen (µs-genau) |
| 283 | `timerfd_create` | Timer als fd |
| 286 | `timerfd_settime` | Timerfd starten/stoppen |
| 287 | `timerfd_gettime` | Timerfd-Zeit auslesen |
| 305 | `clock_adjtime` | NTP-Uhranpassung |

### Scheduling / Priorität

| Nr | Name | Beschreibung |
|----|------|-------------|
| 24 | `sched_yield` | CPU freiwillig abgeben |
| 140 | `getpriority` | Nice-Priorität lesen |
| 141 | `setpriority` | Nice-Priorität setzen |
| 142 | `sched_setparam` | Echtzeit-Parameter setzen |
| 143 | `sched_getparam` | Echtzeit-Parameter lesen |
| 144 | `sched_setscheduler` | Scheduling-Klasse setzen |
| 145 | `sched_getscheduler` | Scheduling-Klasse lesen |
| 146 | `sched_get_priority_max` | Maximale Priorität einer Klasse |
| 147 | `sched_get_priority_min` | Minimale Priorität einer Klasse |
| 148 | `sched_rr_get_interval` | Round-Robin-Intervall |
| 203 | `sched_setaffinity` | CPU-Affinität setzen |
| 204 | `sched_getaffinity` | CPU-Affinität lesen |
| 309 | `getcpu` | Aktuelle CPU und NUMA-Node |
| 315 | `sched_getattr` | Scheduling-Attribute lesen |

### Benutzer / Gruppen / Credentials

| Nr | Name | Beschreibung |
|----|------|-------------|
| 102 | `getuid` | User-ID |
| 104 | `getgid` | Group-ID |
| 105 | `setuid` | User-ID setzen |
| 106 | `setgid` | Group-ID setzen |
| 107 | `geteuid` | Effektive User-ID |
| 108 | `getegid` | Effektive Group-ID |
| 109 | `setpgid` | Prozessgruppe setzen |
| 111 | `getpgrp` | Eigene Prozessgruppe |
| 112 | `setsid` | Neue Session erstellen |
| 113 | `setreuid` | Real- und Effektiv-UID setzen |
| 114 | `setregid` | Real- und Effektiv-GID setzen |
| 115 | `getgroups` | Supplementäre Gruppen lesen |
| 116 | `setgroups` | Supplementäre Gruppen setzen |
| 117 | `setresuid` | Real/Effektiv/Saved-UID setzen |
| 118 | `getresuid` | Real/Effektiv/Saved-UID lesen |
| 119 | `setresgid` | Real/Effektiv/Saved-GID setzen |
| 120 | `getresgid` | Real/Effektiv/Saved-GID lesen |
| 121 | `getpgid` | Prozessgruppe eines Prozesses |
| 122 | `setfsuid` | Dateisystem-UID setzen |
| 123 | `setfsgid` | Dateisystem-GID setzen |
| 124 | `getsid` | Session-ID |

### System-Ressourcen

| Nr | Name | Beschreibung |
|----|------|-------------|
| 97 | `getrlimit` | Ressourcenlimits lesen |
| 98 | `getrusage` | Ressourcenverbrauch lesen |
| 99 | `sysinfo` | Systemzustand (RAM, Load etc.) |
| 100 | `times` | CPU-Zeiten lesen |
| 157 | `prctl` | Prozess-Attribute steuern |
| 158 | `arch_prctl` | Architekturspezifische Steuerung (z. B. TLS) |
| 160 | `setrlimit` | Ressourcenlimits setzen |
| 302 | `prlimit64` | getrlimit/setrlimit kombiniert |

### IPC — Shared Memory (System V)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 29 | `shmget` | Shared-Memory-Segment erstellen |
| 30 | `shmat` | Segment einbinden |
| 31 | `shmctl` | Segment steuern |
| 67 | `shmdt` | Segment aushängen |

### IPC — Semaphore (System V)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 64 | `semget` | Semaphor-Menge erstellen |
| 65 | `semop` | Semaphor-Operation |
| 66 | `semctl` | Semaphor steuern |
| 220 | `semtimedop` | semop mit Timeout |

### IPC — Message Queues (System V)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 68 | `msgget` | Message Queue erstellen |
| 69 | `msgsnd` | Nachricht senden |
| 70 | `msgrcv` | Nachricht empfangen |
| 71 | `msgctl` | Queue steuern |

### IPC — POSIX Message Queues

| Nr | Name | Beschreibung |
|----|------|-------------|
| 240 | `mq_open` | POSIX-MQ öffnen/erstellen |
| 241 | `mq_unlink` | POSIX-MQ löschen |
| 242 | `mq_timedsend` | Nachricht senden mit Timeout |
| 243 | `mq_timedreceive` | Nachricht empfangen mit Timeout |
| 244 | `mq_notify` | Benachrichtigung bei Nachrichteneingang |
| 245 | `mq_getsetattr` | MQ-Attribute lesen/setzen |

### Erweiterte Dateiattribute (xattr)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 188 | `setxattr` | Erweitertes Attribut setzen |
| 189 | `lsetxattr` | xattr setzen (kein Symlink-Follow) |
| 190 | `fsetxattr` | xattr über fd setzen |
| 191 | `getxattr` | Erweitertes Attribut lesen |
| 192 | `lgetxattr` | xattr lesen (kein Symlink-Follow) |
| 193 | `fgetxattr` | xattr über fd lesen |
| 194 | `listxattr` | Alle xattrs auflisten |
| 195 | `llistxattr` | xattrs auflisten (kein Symlink-Follow) |
| 196 | `flistxattr` | xattrs über fd auflisten |
| 197 | `removexattr` | Erweitertes Attribut entfernen |
| 198 | `lremovexattr` | xattr entfernen (kein Symlink-Follow) |
| 199 | `fremovexattr` | xattr über fd entfernen |

### Dateisystem-Überwachung

| Nr | Name | Beschreibung |
|----|------|-------------|
| 253 | `inotify_init` | inotify-Instanz erstellen (veraltet) |
| 254 | `inotify_add_watch` | Datei/Verzeichnis beobachten |
| 255 | `inotify_rm_watch` | Beobachtung entfernen |
| 294 | `inotify_init1` | inotify mit Flags |
| 300 | `fanotify_init` | fanotify-Instanz erstellen |
| 301 | `fanotify_mark` | Dateisystem-Ereignis beobachten |

### Sicherheit / Namespaces / Capabilities (Linux)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 125 | `capget` | Linux-Capabilities lesen |
| 126 | `capset` | Linux-Capabilities setzen |
| 272 | `unshare` | Namespaces abtrennen |
| 308 | `setns` | Namespace beitreten |
| 317 | `seccomp` | seccomp-Filter installieren |
| 310 | `process_vm_readv` | Speicher eines anderen Prozesses lesen |
| 311 | `process_vm_writev` | Speicher eines anderen Prozesses schreiben |
| 321 | `bpf` | BPF-Programme laden/verwalten |
| 334 | `rseq` | Restartable Sequences registrieren |
| 428 | `open_tree` | Dateisystem-Baum öffnen |
| 429 | `move_mount` | Mount bewegen |
| 430 | `fsopen` | Dateisystem öffnen |
| 431 | `fsconfig` | Dateisystem konfigurieren |
| 432 | `fsmount` | Dateisystem einbinden |
| 433 | `fspick` | Existierenden Mount öffnen |
| 442 | `mount_setattr` | Mount-Attribute ändern |
| 459 | `lsm_get_self_attr` | LSM-Attribute des eigenen Prozesses |
| 460 | `lsm_set_self_attr` | LSM-Attribute setzen |
| 461 | `lsm_list_modules` | Geladene LSM-Module auflisten |

### Schlüssel / Keyring

| Nr | Name | Beschreibung |
|----|------|-------------|
| 248 | `add_key` | Schlüssel zum Kernel-Keyring hinzufügen |
| 249 | `request_key` | Schlüssel anfordern |
| 250 | `keyctl` | Schlüssel verwalten |

### Thread / TLS

| Nr | Name | Beschreibung |
|----|------|-------------|
| 205 | `set_thread_area` | Thread-Local-Storage-Deskriptor setzen |
| 211 | `get_thread_area` | TLS-Deskriptor lesen |
| 218 | `set_tid_address` | Thread-ID-Adresse setzen |
| 219 | `restart_syscall` | Unterbrochenen Syscall neu starten |
| 273 | `set_robust_list` | Robust-Mutex-Liste setzen |
| 274 | `get_robust_list` | Robust-Mutex-Liste lesen |
| 449 | `futex_waitv` | Auf mehrere Futex warten |
| 454 | `futex_wake` | Futex-Wartende aufwecken (neu) |
| 455 | `futex_wait` | Auf Futex warten (neu) |
| 456 | `futex_requeue` | Futex-Wartende umleiten (neu) |

### I/O-Priorisierung

| Nr | Name | Beschreibung |
|----|------|-------------|
| 251 | `ioprio_set` | I/O-Priorität setzen |
| 252 | `ioprio_get` | I/O-Priorität lesen |

### Debugging / Tracing

| Nr | Name | Beschreibung |
|----|------|-------------|
| 101 | `ptrace` | Prozess tracen/debuggen |
| 298 | `perf_event_open` | Performance-Counter öffnen |

### Dateisystem — Administration (root)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 135 | `personality` | Execution-Domain setzen |
| 137 | `statfs` | Dateisystem-Statistik |
| 138 | `fstatfs` | Dateisystem-Statistik über fd |
| 139 | `sysfs` | Dateisystemtypen auflisten |
| 154 | `modify_ldt` | LDT modifizieren |
| 155 | `pivot_root` | Root-Dateisystem wechseln |
| 156 | `_sysctl` | Kernel-Parameter (obsolet) |
| 161 | `chroot` | Root-Verzeichnis wechseln |
| 162 | `sync` | Alle Puffer auf Disk schreiben |
| 163 | `acct` | Prozess-Accounting aktivieren |
| 165 | `mount` | Dateisystem einbinden |
| 166 | `umount2` | Dateisystem aushängen |
| 167 | `swapon` | Swap aktivieren |
| 168 | `swapoff` | Swap deaktivieren |
| 169 | `reboot` | System neustarten |
| 170 | `sethostname` | Hostname setzen |
| 171 | `setdomainname` | Domain-Name setzen |
| 172 | `iopl` | I/O-Privilege-Level ändern |
| 173 | `ioperm` | I/O-Port-Zugriff |
| 159 | `adjtimex` | NTP-Kernel-Uhranpassung |
| 212 | `lookup_dcookie` | Dentrycache-Eintrag auflesen |
| 237 | `mbind` | NUMA-Speicherpolicy für Bereich |
| 238 | `set_mempolicy` | NUMA-Speicherpolicy setzen |
| 239 | `get_mempolicy` | NUMA-Speicherpolicy lesen |
| 256 | `migrate_pages` | Seiten zwischen NUMA-Nodes bewegen |
| 279 | `move_pages` | Seiten zu anderem NUMA-Node |
| 303 | `name_to_handle_at` | Datei-Handle lesen |
| 304 | `open_by_handle_at` | Datei über Handle öffnen |
| 313 | `finit_module` | Kernel-Modul laden |
| 320 | `kexec_file_load` | Kernel neu laden (kexec) |
| 321 | `bpf` | BPF-Programme verwalten |
| 340 | `quotactl` | Quota verwalten |
| 443 | `quotactl_fd` | quotactl über fd |
| 440 | `process_madvise` | madvise für anderen Prozess |
| 450 | `set_mempolicy_home_node` | NUMA-Home-Node setzen |
| 457 | `statmount` | Mount-Informationen lesen |
| 458 | `listmount` | Mounts auflisten |
| 103 | `syslog` | Kernel-Ringpuffer lesen/steuern |

### Kernel-Module (root, wahrscheinlich irrelevant für Lyx)

| Nr | Name | Beschreibung |
|----|------|-------------|
| 175 | `init_module` | Kernel-Modul laden (veraltet) |
| 176 | `delete_module` | Kernel-Modul entladen |
| 246 | `kexec_load` | Kernel neu laden |

### Obsolet / ungenutzt / nicht implementierbar

| Nr | Name | Grund |
|----|------|-------|
| 134 | `uselib` | Shared Libraries (veraltet, nie auf x86-64 genutzt) |
| 136 | `ustat` | Dateisystem-Statistik (veraltet, → statfs) |
| 174 | `create_module` | Kernel-Module (Linux < 2.6, immer ENOSYS) |
| 177 | `get_kernel_syms` | Kernel-Symbole (immer ENOSYS) |
| 178 | `query_module` | Modul-Info (immer ENOSYS) |
| 179 | `quotactl` | Disk-Quotas (root-only) |
| 180 | `nfsservctl` | NFS-Server (immer ENOSYS) |
| 181 | `getpmsg` | STREAMS (immer ENOSYS) |
| 182 | `putpmsg` | STREAMS (immer ENOSYS) |
| 183 | `afs_syscall` | AFS (immer ENOSYS) |
| 184 | `tuxcall` | TUX web server (immer ENOSYS) |
| 185 | `security` | LSM-Aufruf (immer ENOSYS) |
| 214 | `epoll_ctl_old` | Veraltet (immer ENOSYS) |
| 215 | `epoll_wait_old` | Veraltet (immer ENOSYS) |
| 216 | `remap_file_pages` | Veraltet (immer ENOSYS) |
| 236 | `vserver` | VServer (immer ENOSYS) |
| 153 | `vhangup` | Terminal aushängen (sehr selten genutzt) |

---

## Statistik

| Kategorie | Anzahl fehlend |
|-----------|---------------|
| I/O — Datei | 53 |
| I/O — Polling/Multiplexing | 11 |
| I/O — Asynchronous (io_uring/AIO) | 9 |
| Memory | 15 |
| Pipes | 2 |
| Netzwerk | 5 |
| Prozess | 11 |
| fd-Duplikation | 3 |
| Signale | 11 |
| Zeit / Timer | 22 |
| Scheduling / Priorität | 14 |
| Benutzer / Gruppen | 24 |
| System-Ressourcen | 8 |
| IPC — System V (SHM/Sem/Msg) | 11 |
| IPC — POSIX MQ | 6 |
| Erweiterte Dateiattribute | 12 |
| Dateisystem-Überwachung | 6 |
| Sicherheit / Namespaces | 13 |
| Schlüssel / Keyring | 3 |
| Thread / TLS | 10 |
| I/O-Priorisierung | 2 |
| Debugging / Tracing | 2 |
| Dateisystem — Administration | 29 |
| Kernel-Module | 3 |
| Obsolet / ENOSYS | 17 |
| **Gesamt fehlend** | **~322** |
| Implementiert | 57 |
| Gesamt Linux x86-64 | ~379 aktive |
