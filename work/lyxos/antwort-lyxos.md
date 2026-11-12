# Antwort aus LyxOS auf `anforderungen-compiler.md`

Stand: 2026-08-20 · geprüft gegen `lyx-os/kernel/ring3.lyx` (nicht gegen Notizen)

## Kurzfassung

Drei Dinge, in dieser Reihenfolge wichtig:

1. **Unsere gemeinsame Tabelle ist 76 Einträge hinterher.** LyxOS implementiert
   **138** Syscalls, `syscalls.md` §10.4 beschreibt **62**. Ein Teil dessen, was
   ihr als fehlend meldet, ist längst da — ihr konntet es nur nicht wissen.
2. **Vergebt auf keinen Fall Linux-Nummern.** 19 der 80 angeforderten Aufrufe
   würden bei Linux-Nummerierung auf einen bestehenden LyxOS-Handler mit ganz
   anderer Bedeutung treffen. Das ist exakt #795 noch einmal.
3. Zu eurer offenen Frage: **ja**, hebt die stdlib auf unser Ereignismodell.
   Das ist das künftige. `epoll`/`eventfd`/`signalfd`/`inotify` bilden wir nicht nach.

Nichts aus §10.4 fehlt im Kernel — die Spec ist korrekt, nur unvollständig.

---

## 1. Nummernkollisionen — bitte zuerst lesen

Unsere ABI folgt in den ersten Nummern zufällig Linux (0 read, 1 write, 2 open,
3 close, 8 lseek, 9 mmap, 24 sched_yield) und weicht danach vollständig ab. Wer
daraus schließt, LyxOS sei linuxnummeriert, baut sich genau die Falle, die ihr
vermeiden wollt.

Diese 19 Aufrufe würden einschlagen:

| Linux-Nr | angeforderter Aufruf | trifft in LyxOS auf |
|---:|---|---|
| 25 | `sys_mremap` | `sleep_ticks(n)` — blockiert n PIT-Ticks |
| 101 | `sys_ptrace` | `sys_block_info` |
| 125 | `sys_capget` | `sys_fb_map_user` — GOP-Framebuffer einblenden |
| 126 | `sys_capset` | `sys_get_mouse_x` |
| 137 | `sys_statfs` | `sys_set_child_out` — stdout-Umleitung eines Kindes |
| 140 | `sys_getpriority` | `sys_utime_fd` |
| 141 | `sys_setpriority` | `sys_net_get_ip` |
| 149 | `sys_mlock` | `sys_win_find_by_idx` |
| 150 | `sys_munlock` | `sys_win_get_title` |
| 157 | `sys_prctl` | `sys_iofs_read_lpid` — 4-KB-Seite lesen |
| 158 | `sys_arch_prctl` | `sys_iofs_write_lpid` — 4-KB-Seite **schreiben** |
| 161 | `sys_chroot` | `sys_iofs_checkpoint` |
| 166 | `sys_umount2` | `sys_iofs_edge_remove` |
| 169 | `sys_reboot` | `sys_iofs_edge_has` |
| 170 | `sys_sethostname` | `sys_iofs_bfs` |
| 188 | `sys_setxattr` | `sys_probe_fs_part` |
| 202 | `sys_futex` | `sys_proc_info` |
| 203 | `sys_sched_setaffinity` | `sys_mem_stats` |
| 24 | `sys_sched_yield` | `sys_yield` — **einziger echter Treffer**, Bedeutung stimmt |

`sys_arch_prctl` auf 158 wäre besonders unangenehm: das schreibt bei uns eine
4-KB-Seite ins Dateisystem.

**Vorschlag:** Alles Neue aus dem Bereich **300–399** vergeben. Der ist bei uns
durchgehend frei (229–399 ist lückenlos unbelegt), und die Zuordnung ist damit
sichtbar eine bewusste Entscheidung und keine geerbte Zahl.

---

## 2. Was ihr schon habt, ohne es zu wissen

| Ihr fragt nach | LyxOS hat | Anmerkung |
|---|---|---|
| `sys_sched_yield` | **24** `sys_yield` | identisch, sofort nutzbar |
| `sys_reboot` | **210** `sys_power(0=reboot, 1=shutdown)` | Streicht euren Eintrag |
| `sys_shmget`/`shmat`/`shmdt` | **118/119/120** `sys_shm_create` / `shm_map` / `shm_unmap` | anderes Modell (ID-basiert, kein key_t), gleicher Zweck |
| `sys_select`, `epoll_*`, `eventfd2`, `signalfd4` | **121/122/132/218** `event_send`, `event_recv`, `event_recv_pid`, `event_recv_timeout` | unser Modell, siehe §4 |
| `sys_pread64`/`pwrite64` | **8** `sys_lseek` + **0/1** | zusammensetzbar; eigener Aufruf nur, wenn ihr Atomarität braucht |
| `sys_getcpu` | **205** `sys_cpu_stats` liefert Per-Kern-Ticks | „auf welchem Kern laufe ich" fehlt — siehe §3 |
| `sys_fsync`/`fdatasync` | `VfsSync(fd)` existiert, ist aber ein **No-op** | Aufruf anbinden ist trivial, echte Semantik fehlt |

Dazu 76 weitere Syscalls, die in §10.4 fehlen: TCP (180–184), rohe
Ethernet-Frames (146/147), Netzkonfiguration (141–145, 211–213), DNS (214),
IOFS-Graph mit Kanten und Traversierung (155–188), Fensterverwaltung (110–115,
148–152), Audio (219–226), Prozess- und Speicherstatistik (202/203/205),
RAM-Disks (153/154), Wissensgraph (2063–2066) und Zeitleiste (2315).
Vollständige Liste im Anhang.

---

## 3. Zusagen

> **NACHTRAG 2026-08-20, wenige Stunden spaeter: alles unter „Ja" ist gebaut.**
> Nummern 300–320 vergeben, implementiert und mit `/bin/systest.elf` geprueft —
> 25 von 25 Pruefungen bestanden. Die Argumentfolgen stehen unten und sind
> verbindlich. `systest.lyx` im lyx-os-Baum ist zugleich die Vorlage, wie die
> Aufrufe zu bedienen sind.
>
> | Nr | Aufruf | Nr | Aufruf |
> |---:|---|---:|---|
> | 300 | `sys_access` | 311 | `sys_statfs` |
> | 301 | `sys_fcntl` | 312 | `sys_sched_getaffinity` |
> | 302 | `sys_dup2` | 313 | `sys_sched_setaffinity` |
> | 303 | `sys_dup3` | 314 | `sys_getpriority` |
> | 304 | `sys_ftruncate` | 315 | `sys_setpriority` |
> | 305 | `sys_fsync` | 316 | `sys_futex_wait` |
> | 306 | `sys_fdatasync` | 317 | `sys_futex_wake` |
> | 307 | `sys_uname` | 318 | `sys_futex_requeue` |
> | 308 | `sys_getcpu` | 319 | `sys_kill` |
> | 309 | `sys_readv` | 320 | `sys_pipe2` |
> | 310 | `sys_writev` | | |
>
> **Sechs Abweichungen, die ihr kennen muesst — keine davon ist ein Bug:**
> 1. `dup2`/`dup3` teilen den **Dateizeiger nicht**. Slot-Kopie, danach laufen
>    beide Deskriptoren unabhaengig. Fuer Umleiten vor einem exec reicht das.
> 2. `ftruncate` kann **nur auf 0**. Andere Laengen liefern -1, statt still
>    etwas anderes zu tun.
> 3. `statfs` meldet **freie Bloecke als -1 (unbekannt)**. Eine Zaehlung
>    braeuchte einen vollstaendigen FAT-Durchlauf; eine erfundene Zahl waere
>    schlechter als ein erkennbares „weiss ich nicht".
> 4. `get`/`setpriority` benutzen die **LyxOS-Skala 0–255** (0 = HARD_RT,
>    128 = NORMAL, 255 = IDLE), nicht nice. Eine Abbildung auf -20..19 waere
>    verlustbehaftet und wuerde Rueckschreiben kaputtmachen.
> 5. `pipe2` **blockiert nicht**. Leer liefert 0, voll nimmt 0 Byte an.
> 6. `kill` ist **kein Signalmodell**: keine Handler, keine Nummern. `sig=0`
>    prueft Existenz, sonst wird der Thread beendet.
>
> `fcntl` speichert `O_NONBLOCK`, wertet es aber noch nicht aus — `read` auf
> fd=0 blockiert weiterhin. Bewusst so, statt das Flag zu schlucken und Erfolg
> zu melden.

### Ja, und billig — vergebt Nummern ab 300

`sys_access`, `sys_fcntl` (mindestens `F_GETFL`/`F_SETFL` für `O_NONBLOCK`),
`sys_dup2`, `sys_dup3`, `sys_ftruncate`, `sys_fsync`, `sys_fdatasync`,
`sys_uname`, `sys_getcpu`, `sys_readv`, `sys_writev`, `sys_statfs`,
`sys_sched_getaffinity`, `sys_sched_setaffinity`, `sys_getpriority`,
`sys_setpriority`.

Begründung: Das ist alles vorhandene Kernel-Funktionalität, der nur der
Ring-3-Durchgang fehlt. Der Scheduler kennt Affinität (`T_CPU_AFFINITY`) und
Prioritäten intern bereits; `uname` können wir aus `LYXOS_VERSION` plus der
Hypervisor-Erkennung bedienen.

### Ja, aber mit Arbeit

- **`sys_kill`** — wir haben Prozess-Erzeugung und -Ende, aber kein Signalmodell.
  Machbar als „Thread beenden", nicht als POSIX-Signale.
- **`sys_futex_wait`/`wake`/`requeue`** — der Scheduler hat Mutexe intern
  (`sched_mutex.lyx`), aber keinen Ring-3-Durchgang. Für die `thread`-Unit die
  sinnvollste Investition der ganzen Liste.
- **`sys_pipe2`** — kein Pipe-Konzept vorhanden, wäre neu.
- **`sys_mremap`, `madvise`, `mincore`, `msync`, `mlock`, `munlock`** — unser
  VMM ist ein Bump-Allokator mit statischer 4-GB-Map. `madvise`/`mlock` könnten
  ehrliche No-ops werden; `mremap` und `mincore` bräuchten echtes Paging.

### Nein — und zwar begründet, nicht aus Bequemlichkeit

- **`sys_recvfrom`/`sys_sendto` (29 Stellen)** — **KORREKTUR, siehe unten: die
  UDP-Hälfte dieser Absage war falsch und ist inzwischen gebaut.** Was bleibt:
  **LyxOS hat keinen Bluetooth-Treiber.** Kein HCI, kein L2CAP, nichts. Die vier
  `hardware.bluetooth*`-Units laufen hier nicht, egal welche Syscalls
  existieren.
- **xattr-Familie (8 Aufrufe)** — FAT32 kennt keine erweiterten Attribute. Auf
  IOFS wären sie über Graph-Kanten darstellbar, aber das wäre etwas anderes als
  POSIX-xattr. Tragt sie als `-ENOSYS` ein.
- **SysV-IPC (`msg*`, `sem*`, `shm*` mit `key_t`)** — für SHM habt ihr 118–120.
  Nachrichtenschlangen und Semaphorenmengen würden wir nicht nachbauen; unser
  Ereignismodell deckt den Zweck ab.
- **`sys_mq_*`** — dito.
- **`sys_sendfile`, `sys_fallocate`, `sys_memfd_create`** — kein Bedarf, den wir
  sehen; sagt Bescheid, wenn eine konkrete Unit daran hängt.
- **`sys_sethostname`, `sys_umount2`, `sys_chroot`** — kein Hostname-Konzept,
  Unmount gibt es nur volumeweise (`sys_vol`), kein chroot-Modell.
- **Eure „vermutlich nicht"-Liste stimmt:** `ptrace`, `bpf`, `io_uring_*`,
  `unshare`, `setns`, `clone`, `pidfd_*`, `capget`/`capset`, `prctl`,
  `arch_prctl`, `rt_sig*`, `tgkill`, `perf_event_open`. Alles Linux-Eigenheiten.
  Für Rechte haben wir das LBF-Capability-Modell, für Debugging nichts
  Vergleichbares.

---

## 3b. Korrektur: UDP ist doch da — `sendto`/`recvfrom` sind gebaut

Die Absage oben stützte sich zur Hälfte auf einen Irrtum. Wir schrieben, für
`net.socket` fehle UDP auf Nutzerebene. Das stimmt nicht: Der Stack kann UDP
seit jeher — `udp_build`, IP-Bau mit Prüfsummen und ein Empfangs-Demux nach
Zielport, benutzt von DHCP (Port 68) und DNS (Port 53). Gefehlt hat nur der
Durchgang nach Ring 3. Wir hatten nach `sys_udp`-Wrappern gesucht, keine
gefunden und daraus auf die fehlende Fähigkeit geschlossen.

Inzwischen implementiert und gegen eine echte Gegenstelle geprüft (30 von 30):

| Nr | Aufruf | Argumente | Rückgabe |
|---:|---|---|---|
| 321 | `sys_udp_open` | `lport` (0 = ephemer) | sock_idx 0–7 / -1 |
| 322 | `sys_udp_close` | `sock_idx` | 0 / -1 |
| 323 | `sys_sendto` | `sock, buf, len, dst` | gesendete Bytes / -1 / -2 (ARP) |
| 324 | `sys_recvfrom` | `sock, buf, maxlen, out` | Bytes, **0 = Zeitablauf** |
| 325 | `sys_getsockname` | `sock, out, kind` (0=TCP, 1=UDP) | 0 / -1 |
| 326 | `sys_getpeername` | `sock, out` | 0 / -1 (nur TCP) |

**Adressformat:** `{ip: int64, port: int64}` — kein `sockaddr_in`. Wir haben
kein BSD-Socket-Modell, und eine Fassade würde nur Erwartungen wecken, die der
Unterbau nicht einlöst. Bei `recvfrom` steht zusätzlich bei `out+16` das
Zeitlimit in Millisekunden als **Eingabe**.

**Die Grenze, die ihr kennen müsst:** Alle Netzoperationen pollen die Karte
*innerhalb* des Aufrufs und verwerfen Fremdpakete — genau wie DHCP und DNS es
seit jeher tun. Praktisch heißt das: **ein Socket zur Zeit**, und während des
Wartens gehen Pakete für andere Ports verloren. Beim Testen wurde das konkret
sichtbar: ein Paketstrom vom Host ließ die ARP-Auflösung scheitern, weil deren
Warteschleife die Antwort verpasste. Echtes Multiplexing bräuchte einen
Hintergrund-Thread mit Socket-Tabelle und Ringpuffer je Socket — das ist ein
eigenes Paket und bewusst nicht enthalten.

Für Bluetooth ändert das nichts. Die Units laufen hier nicht.

## 4. Zu eurer offenen Frage: das Ereignismodell

**Ja — hebt die stdlib auf unser Modell.** Das ist eine Zusage, keine Absicht.

Vorhanden und in Benutzung (Compositor, Terminal, alle Fenster-Apps):

| Nr | Aufruf | Zweck |
|---:|---|---|
| 121 | `sys_event_send(pid, type, a, b, c)` | Ereignis an einen Prozess |
| 122 | `sys_event_recv(out_uva)` | nicht-blockierend abholen |
| 132 | `sys_event_recv_pid(pid_idx, out_uva)` | für Prozesse mit mehreren Queues |
| 218 | `sys_event_recv_timeout(pid_idx, out_uva, timeout_ms)` | **blockierend mit Frist** — das ist euer `select`-Ersatz |

218 ist der Aufruf, um den eine Ereignisschleife gebaut gehört. Damit brauchen
wir weder `epoll` noch `eventfd` noch `signalfd`; `inotify` ist ohne
Dateiänderungsbenachrichtigung im VFS ohnehin nicht darstellbar.

Was fehlt und was wir liefern müssten, wenn ihr umstellt: das Warten auf
**Dateideskriptoren** ist im Ereignismodell noch nicht abgebildet. Heute ist es
Fenster-, Tastatur- und Prozessereignisse. Sagt uns, welche Deskriptorarten die
stdlib beobachten muss, dann ergänzen wir die Ereignistypen.

---

## 5. Was als Nächstes passieren sollte

Bei uns:

1. **§10.4 neu erzeugen** — aus dem Quelltext, nicht von Hand. Der Anhang unten
   ist der fehlende Teil und kann direkt übernommen werden. Solange die Tabelle
   76 Einträge hinterherhinkt, meldet ihr Lücken, die keine sind.
2. Für die zugesagten Aufrufe Nummern ab 300 vergeben und die Argumentfolgen
   festschreiben.

Bei euch: alles, was in §2 als vorhanden steht, könnt ihr sofort anbinden — die
Nummern stehen fest und sind seit Monaten stabil.

**Eine Bitte:** Nehmt Nummern nur aus der Tabelle, nie aus Linux-Analogie. Der
Bereich 0–228 ist bei uns dicht belegt und semantisch unabhängig von Linux.

---

## Anhang: die 76 Syscalls, die in §10.4 fehlen

Direkt aus `kernel/ring3.lyx` erzeugt.
| Nr | Name | Beschreibung (aus dem Quelltext) |
|---:|------|----------------|
| 8 | `sys_lseek` |  |
| 25 | `` | sleep_ticks(n) → block n PIT ticks (~n×10 ms) |
| 141 | `sys_net_get_ip` | ) → assigned IP (packed BE), 0 = no lease |
| 142 | `sys_net_get_gw` | ) → default gateway IP |
| 143 | `sys_net_get_mask` | ) → subnet mask |
| 144 | `sys_net_get_dns` | ) → primary DNS server IP |
| 145 | `sys_net_get_mac` | uva_buf): copy 6 MAC bytes to user buffer |
| 146 | `sys_net_send` | uva_buf, len): send raw Ethernet frame |
| 147 | `sys_net_recv` | uva_buf, maxlen): receive one raw Ethernet frame (0 = no frame) |
| 148 | `sys_win_set_title` | win_id, title_uva): copy title string into win slot (WP27) |
| 149 | `sys_win_find_by_idx` | n): win_id of n-th active window sorted ascending by creation order (WP27) |
| 150 | `sys_win_get_title` | win_id, out_uva): copy window title to user buffer (32 bytes) (WP27) |
| 151 | `sys_win_get_geom` | win_id, out_uva): copy {x,y,w,h} (4×int64 = 32 bytes) to user buf (WP29) |
| 152 | `sys_win_get_pid` | win_id) → owner PID or -1 (WP29) |
| 153 | `sys_ramdisk_create` | size_mb) → disk_id (4-7) or -1 (WP30) |
| 154 | `sys_ramdisk_fmt` | disk_id, fs_type): format RAM disk + mount as vol 0. |
| 155 | `sys_mkfs_iofs` | disk_id): format disk as IOFS (WP01+WP09) |
| 156 | `sys_iofs_mount` | disk_id): mount IOFS volume, load LIP+bitmap into RAM (WP02) |
| 157 | `sys_iofs_read_lpid` | lpid, user_buf): read 4096-byte page into user buf (WP02) |
| 158 | `sys_iofs_write_lpid` | lpid, user_buf): write 4096-byte page from user buf (WP02) |
| 159 | `sys_iofs_new_page` | type, flags, payload_uva, psize): alloc LPID + write (WP02) |
| 160 | `sys_iofs_free_lpid` | lpid): free physical page + clear LIP entry (WP02) |
| 161 | `sys_iofs_checkpoint` | ): flush LIP+bitmap to inactive slot (WP02) |
| 162 | `sys_iofs_unmount` | ): checkpoint if dirty + release LIP table (WP02) |
| 163 | `sys_iofs_lip_get` | lpid): return physical page_idx for lpid, 0=unmapped (WP02) |
| 164 | `sys_iofs_info` | out_buf_uva): write iofs status into 64-byte user buf (WP02+WP04) |
| 165 | `sys_iofs_edge_add` | from_lpid, to_lpid, edge_type) → 0 or -1 (WP05) |
| 166 | `sys_iofs_edge_remove` | from_lpid, to_lpid) → 0 or -1 (WP05) |
| 167 | `sys_iofs_edge_count` | from_lpid) → count (WP05) |
| 168 | `sys_iofs_edge_get_all` | from_lpid, out_buf_uva, max_edges) → count written (WP05) |
| 169 | `sys_iofs_edge_has` | from_lpid, to_lpid) → 1 if exists, 0 if not (WP05) |
| 170 | `sys_iofs_bfs` | start_lpid, out_buf_uva, max_nodes) → count (WP06) |
| 171 | `sys_iofs_dfs` | start_lpid, out_buf_uva, max_nodes) → count (WP06) |
| 172 | `sys_iofs_reachable` | from_lpid, to_lpid) → 1 reachable, 0 not (WP06) |
| 173 | `sys_iofs_shortest_path` | from_lpid, to_lpid, path_buf_uva, max_len) → path_len (WP06) |
| 174 | `sys_iofs_name_init` | ): create/verify name store at LPID=2 (WP07) |
| 175 | `sys_iofs_name_lookup` | name_uva, name_len) → LPID or 0 (WP07) |
| 176 | `sys_iofs_name_bind` | name_uva, name_len, lpid) → 0 or -1 (WP07) |
| 177 | `sys_iofs_name_unbind` | name_uva, name_len) → 0 or -1 (WP07) |
| 178 | `sys_iofs_name_list` | out_buf_uva, max_entries) → count (WP07) |
| 179 | `sys_iofs_gc` | ) → freed LPID count, or -1 if not mounted (WP07-GC) |
| 180 | `sys_tcp_connect` | dst_ip, dst_port) → sock_idx  (WP16d) |
| 181 | `sys_tcp_send` | sock, uva_buf, len) → bytes_sent |
| 182 | `sys_tcp_recv` | sock, uva_buf, max) → bytes_received |
| 183 | `sys_tcp_close` | sock) |
| 184 | `sys_tcp_status` | sock) → state (0=CLOSED 1=SYN_SENT 2=ESTABLISHED 3=FIN_WAIT) |
| 185 | `sys_mkfs_iofs_part` | disk_id, part_no): format partition #part_no as IOFS (WP31) |
| 186 | `sys_iofs_mount_part` | disk_id, part_no): mount IOFS from a partition (WP31) |
| 187 | `sys_mount_part_auto` | vol_id, disk_id, part_no): auto-detect FS + mount (WP31) |
| 188 | `sys_probe_fs_part` | disk_id, part_no): → 1 = IOFS, 0 = FAT32/other, -1 = none (WP31) |
| 202 | `sys_proc_info` | slot=a0, out_uva=a1): per-slot process info for `top`. |
| 203 | `sys_mem_stats` | out_uva=a0): +0=free_pages +8=total_pages +16=pit_frame |
| 205 | `sys_cpu_stats` | out) → ncpu + per-core (busy, total) ticks (TO-9.5). Mirrors the |
| 210 | `sys_power` | action=a0): 0 = reboot, 1 = shutdown. Does not return. |
| 211 | `sys_net_get_info` | uva_buf): fill 112-byte interface info struct |
| 212 | `sys_net_set` | field=a0, val=a1): configure one interface field |
| 213 | `sys_icmp_ping` | buf): ICMP echo round-trip; buf carries params in/results out |
| 214 | `sys_dns_query` | buf, name_uva): DNS lookup; buf params/results, a1=name string |
| 215 | `sys_launch_request` | path): copy the path (user-virtual or physical literal, |
| 217 | `sys_spawn_queued` | ): if a launch is pending, spawn g_launch_path as an async |
| 218 | `sys_event_recv_timeout` | pid_idx=a0, out_buf=a1, timeout_ms=a2): |
| 219 | `sys_audio_play` | uva=a0, nbytes=a1, rate=a2): copy user PCM (16-bit |
| 220 | `sys_audio_tone` | freq=a0, amp=a1, ms=a2): kernel-generated tone. |
| 221 | `sys_audio_status` | ): 1 if an audio device is present, else 0. |
| 222 | `sys_audio_stream_start` | chunk_frames=a0): init the BDL-ring stream. |
| 223 | `sys_audio_stream_queue` | uva=a0, nframes=a1): non-blocking — if the ring |
| 224 | `sys_audio_stream_busy` | ): 1 if the ring is full (caller may yield). |
| 225 | `sys_mp3_offload_start` | ): load the mp3 + tables (BSP), spawn the decoder as a |
| 226 | `sys_mp3_offload_pump` | ): drain decoded frames from the ring to AC97 (BSP-side, |
| 227 | `` | mp3_offload_frames() — decoder progress (DIAG) |
| 228 | `sys_rdtsc` | ) — raw TSC for ring-3 profiling |
| 2063 | `sys_graph_node_create` | label_uva, type) → node_id or -1  [ABI 0x080F] |
| 2064 | `sys_graph_edge_add` | from_id, to_id, rel_type) → edge_id or -1  [ABI 0x0810] |
| 2065 | `sys_graph_edge_remove` | edge_id) → 0/-1  [ABI 0x0811] |
| 2066 | `sys_graph_query` | start_id, depth, out_uva, out_max) → count  [ABI 0x0812] |
| 2315 | `sys_timeline_query` | t_start, t_end, out_uva, out_max) → count  [ABI 0x090B] |
