# Aurum — Offene Arbeitspakete

> Stand: 2026-06-09. Erledigte WPs wurden entfernt. Jedes WP ist eigenständig bearbeitbar.

---

## Übersicht

| WP | Titel | Prio |
|----|-------|------|
| WP-01 | Windows ARM64 — StrSub / StrConcat / StrCopy | Hoch |
| WP-02 | macOS x86_64 — VMT / DynArray / Closures | Hoch |
| WP-03 | ARM64 Linux — CRT-Init für Dynamic Linking | Hoch |
| WP-04 | Compiler — Tuple-Return-Typ `[T1, T2]` | Hoch |
| WP-05 | std/audio.lyx — Audio Unit (WAV / ALSA / MP3) | Mittel |
| WP-06 | macOS x86_64 — Socket-Builtins | Mittel |
| WP-07 | std.net — IPv6 Support | Mittel |
| WP-08 | Windows ARM64 — Printf via wsprintfA | Mittel |
| WP-09 | Windows ARM64 VMT — Hardware-Verifikation | Mittel |
| WP-13 | Inspect Debug-Visualizer — ARM64 + Windows ARM64 | Niedrig |

---

## WP-01 · Windows ARM64 — String-Funktionen

**Priorität:** Hoch

**Aufgabe**  
`StrSub`, `StrConcat` und `StrCopy` im Windows ARM64 Backend vollständig implementieren: VirtualAlloc läuft bereits, der anschließende memcpy-Loop fehlt.

**Kontext**  
Datei: `src/backend/win_arm64.lyx`. Alle drei Funktionen reservieren Speicher via `VirtualAlloc`, schreiben aber keine Bytes hinein. Der Aufrufer erhält einen unbereinigten Puffer — stilles Fehlverhalten, kein Compiler- oder Runtime-Fehler.

| Funktion | Implementierung |
|----------|----------------|
| `StrSub(s, start, len)` | VirtualAlloc + byte-Loop: kopiere `len` Bytes ab `s+start` |
| `StrConcat(a, b)` | VirtualAlloc(`lenA+lenB+1`) + beide Strings hintereinander kopieren |
| `StrCopy(s)` | VirtualAlloc(`len+1`) + Byte-für-Byte-Kopie des Originals |

**Nutzen**  
Ohne korrekte String-Funktionen sind alle string-verarbeitenden Programme auf Windows ARM64 silently kaputt: URL-Bau, Dateinamen-Manipulation, jede Art von Textpipeline liefert Zufallsdaten.

**Abnahme**
- Testprogramm `tests/wp01_win_arm64_strings.lyx` auf echter Windows ARM64 Hardware ausführen.
- `StrSub("hello world"c, 6, 5)` → `"world"`, `StrConcat("foo"c, "bar"c)` → `"foobar"`, `StrCopy("abc"c)` → `"abc"`.
- Kein Zufallsinhalt, kein Absturz; Ausgabe: `PASS`.

---

## WP-02 · macOS x86_64 — VMT / DynArray / Closures

**Priorität:** Hoch

**Aufgabe**  
Drei fehlende Sprachfeatures für das macOS x86_64 Target implementieren: Virtual Method Dispatch (VMT), dynamische Arrays (DynArray) und Closures mit Upvalue-Capture.

**Kontext**  
Datei: `src/backend/macos_x86.lyx`. Das macOS-Backend verbatim-kopiert den Linux-Code ab Offset 301 und patcht Syscall-Nummern. VMT-Adress-Patching (Linux-Basisadresse → macOS-Basisadresse) ist in `mxb_patchVMTAddrs()` angelegt, aber noch nicht vollständig getestet. DynArray-mmap-Flags wurden mit WP-02-PR angepasst. Closures (Upvalue-Pointer über Frame-Grenze) fehlen vollständig.

Empfohlene Reihenfolge: VMT → DynArray → Closures (VMT ist der Blocker für OOP-Code).

**Nutzen**  
Ohne VMT kein einziges `class`-Programm auf macOS. Ohne DynArray keine dynamischen Listen. Ohne Closures keine funktionalen Muster. macOS ist ein primäres Entwicklungsgerät — fehlende Features blockieren den gesamten Entwickler-Workflow.

**Abnahme**
- VMT: Klasse mit zwei virtuellen Methoden, beide korrekt via Dispatch aufrufbar; Ergebnis PASS auf macOS x86_64.
- DynArray: `DynAppend`, `DynLen`, `DynGet`, `DynFree` funktionieren mit mindestens 100 Elementen.
- Closures: Closure captured eine `int64`-Variable aus dem äußeren Frame und gibt den korrekten Wert zurück.

---

## WP-03 · ARM64 Linux — CRT-Init für Dynamic Linking

**Priorität:** Hoch

**Aufgabe**  
Den ARM64 Linux `_start`-Stub so erweitern, dass er korrekt in `__libc_start_main` delegiert — Voraussetzung für dynamisch gegen libc gelinkte Programme.

**Kontext**  
Datei: `src/backend/arm64/emit_arm64.lyx` (bzw. der ELF-Writer). Statisch gelinkte ARM64-Binaries laufen bereits. Für dynamisches Linking (z.B. gegen OpenSSL, libcurl, SQLite) muss `_start` die ABI-konforme Signatur `__libc_start_main(main, argc, argv, init, fini, rtld_fini, stack_end)` bedienen. `argc` liegt im ersten Stack-Word, `argv` zeigt auf `sp+8`.

| Schritt | Detail |
|---------|--------|
| `argc` aus Stack lesen | `ldr x0, [sp]` → argc |
| `argv`-Zeiger laden | `add x1, sp, #8` → argv |
| `__libc_start_main` aufrufen | PLT-Call oder direkter Branch + restliche ABI-Args (init/fini/rtld_fini/stack_end = NULL) |

**Nutzen**  
Ohne korrekten CRT-Start schlägt jeder Aufruf von libc-Funktionen fehl, die `__libc_start_main` voraussetzen. Mit korrektем CRT öffnet sich das gesamte Shared-Library-Ökosystem: OpenSSL, SQLite, libcurl — ohne Reimplementierung in Lyx.

**Abnahme**
- `lyxc --target=arm64 --dynamic test.lyx -o test.out`
- `ldd test.out` zeigt `libc.so.6` als Abhängigkeit.
- Programm startet, `main()` empfängt korrekte `argc`/`argv`, Ausgabe korrekt.

---

## WP-04 · Compiler — Tuple-Return-Typ `[T1, T2]`

**Priorität:** Hoch

**Aufgabe**  
`[T1, T2]` als Return-Typ deklarieren und destrukturieren können: `var [a, b] := fn()`.

**Kontext**  
Der Parser behandelt `[...]` in Typ-Positionen heute als Array-Elementtyp, nicht als Tuple. Fünf koordinierte Änderungen sind nötig:

| Schritt | Datei | Änderung |
|---------|-------|----------|
| 1 | `src/ast.lyx` | `atTuple`-Knotentyp + `TTupleElemTypes`-Record |
| 2 | `src/parser.lyx` | `[T, T, ...]` in `ParseTypeExFull` → Tuple wenn Identifier-Liste |
| 3 | `src/sema.lyx` | Return-Type-Check für Tuples; Stellenzahl prüfen |
| 4 | `src/ir_lower.lyx` | Tuple-Return lowern → `irReturnStruct` oder Hidden-Pointer |
| 5 | `src/codegen_x86.lyx` | SysV AMD64 ABI: 2 Werte ≤ 16 B → RAX:RDX; größer → Hidden-Ptr in RDI |

**Nutzen**  
`BoundingBoxFromPoints` und `CalculateBoundingBox` in `std/geo.lyx` können derzeit keinen `[GeoPoint, GeoPoint]`-Rückgabetyp deklarieren. Allgemein: elegante APIs ohne Out-Parameter, analog zu Go-Multiple-Returns oder C++-`std::pair`.

**Abnahme**
- `BoundingBoxFromPoints(points)` in `std/geo.lyx` kompiliert fehlerfrei.
- Rückgabewert ist ein `[GeoPoint, GeoPoint]` mit korrektem min/max; Destrukturierung per `var [min, max] := ...` funktioniert.
- Bestehende Tests bleiben grün.

---

## WP-05 · std/audio.lyx — Audio Unit

**Priorität:** Mittel

**Aufgabe**  
Neues Standardmodul `std/audio.lyx` mit WAV-Wiedergabe via ALSA (Phase A), PipeWire-Support (Phase B) und MP3-Dekodierung (Phase C).

**Kontext**  
Das Modul existiert noch nicht. Phase A ist Voraussetzung für B und C. ALSA-Funktionen werden via FFI (`extern fn`) aufgerufen; WAV ist ein RIFF-basiertes Format mit einfachem Header-Parser.

**Phase A — WAV + ALSA (Basis)**

| # | Aufgabe | Detail |
|---|---------|--------|
| A1 | API | `AudioOpen(path)`, `AudioPlay()`, `AudioClose()` in `std/audio.lyx` |
| A2 | WAV-Parser | RIFF-WAVE: `fmt`-Chunk (SampleRate, Channels, BitsPerSample) + `data`-Chunk |
| A3 | WAV-Decoder | PCM 8-bit unsigned, PCM 16-bit signed, Mono + Stereo |
| A4 | ALSA via FFI | `snd_pcm_open`, `snd_pcm_set_params`, `snd_pcm_writei`, `snd_pcm_close` |
| A5 | Test | `tests/audio_test.lyx` lädt eine 16-bit-Mono-WAV und spielt sie ab |

**Phase B — PipeWire**

| # | Aufgabe | Detail |
|---|---------|--------|
| B1 | PipeWire-Backend | `pw_stream_connect`, `pw_stream_queue_buffer`, `pw_stream_trigger_process` als Alternative zu ALSA |

**Phase C — MP3**

| # | Aufgabe | Detail |
|---|---------|--------|
| C1 | MP3-Parser | ID3v2-Tag-Überspringen + Sync-Word-Suche; Frame-Header (Layer III, Bitrate, SampleRate) |
| C2 | MP3-Decoder | Minimaler Frame-Extraktor oder FFI zu `libmpg123` für PCM-Output |
| C3 | Test | `tests/audio_test.lyx` um MP3-Datei erweitern |

**Nutzen**  
Audio-Wiedergabe ohne externe Tools; Basis für Spiele, Benachrichtigungen, Media-Apps in Lyx. Phase A allein deckt den häufigsten Use-Case (WAV-Soundeffekte) ab.

**Abnahme**
- Phase A: `tests/audio_test.lyx` kompiliert auf x86_64 Linux, lädt eine WAV-Testdatei und gibt hörbaren Ton über ALSA aus; kein Absturz bei fehlerhafter Datei.
- Phase B: Gleicher Test läuft über PipeWire-Backend ohne Codeänderung im Testprogramm.
- Phase C: MP3-Testdatei wird korrekt zu PCM dekodiert und abgespielt.

---

## WP-06 · macOS x86_64 — Socket-Builtins

**Priorität:** Mittel

**Aufgabe**  
BSD-Socket-Syscalls für macOS x86_64 implementieren: `socket`, `bind`, `listen`, `accept`, `connect`, `send`/`recv`-Familie und Socket-Optionen.

**Kontext**  
macOS verwendet den `0x2000000`-Syscall-Präfix (BSD-Kernel-Trap). Die entsprechenden Nummern sind in `src/backend/macos_x86.lyx` als Konstanten definiert (`MACOS_SYS_SOCKET = 0x2000061` usw.). Die eigentliche Builtin-Emission im Codegen fehlt noch oder ist unvollständig.

| Syscall | macOS-Nummer |
|---------|-------------|
| `socket` | `0x2000061` |
| `bind` | `0x2000068` |
| `listen` | `0x200006A` |
| `accept` | `0x200001E` |
| `connect` | `0x2000062` |
| `sendto` | `0x2000085` |
| `recvfrom` | `0x200001D` |
| `setsockopt` | `0x2000069` |
| `getsockopt` | `0x2000076` |
| `shutdown` | `0x2000086` |

**Nutzen**  
Netzwerk-Programme (HTTP-Clients, TCP-Server, Websockets) auf macOS x86_64. Ohne Socket-Builtins ist `std/net` auf macOS wirkungslos.

**Abnahme**
- TCP-Echo-Server in Lyx läuft auf macOS x86_64, nimmt Verbindungen an und antwortet korrekt.
- `curl localhost:<port>` liefert die erwartete Antwort.

---

## WP-07 · std.net — IPv6 Support

**Priorität:** Mittel

**Aufgabe**  
IPv6-Unterstützung in `std/net/socket.lyx` aktivieren: `sockaddr_in6` in `sys_bind`/`sys_connect` nutzen, AAAA-DNS-Lookup, neue API-Funktionen `SocketNewV6`, `BindV6`, `ConnectV6`.

**Kontext**  
`SockAddrIn6` ist bereits in `std/net/socket.lyx` definiert, wird aber an keiner Stelle befüllt oder übergeben. `GetHostByName` löst nur A-Records auf. Die Syscall-ABI für IPv6 ist identisch zu IPv4 — nur `sin6_family = AF_INET6` und die 16-Byte-Adresse unterscheiden sich.

| Aufgabe | Detail |
|---------|--------|
| `sys_bind` / `sys_connect` erweitern | `sockaddr_in6`-Struct korrekt befüllen (sin6_family, sin6_port, sin6_addr) |
| `GetHostByName` erweitern | AAAA-Record auswerten, IPv6-Adresse als 16-Byte-Array zurückgeben |
| `SocketNewV6` | Neuen `AF_INET6 / SOCK_STREAM`-Socket erstellen |
| `BindV6(port)` | Socket an `::` (alle Interfaces) binden |
| `ConnectV6(addr, port)` | IPv6-Verbindung aufbauen |

**Nutzen**  
IPv6-only-Umgebungen werden häufiger (Cloud-Deployments, mobile Carrier-NAT). Dual-Stack-Support macht Lyx-Netzwerkprogramme zukunftssicher und kompatibel mit modernen Infrastrukturen.

**Abnahme**
- `ConnectV6("::1"c, 8080)` baut eine TCP-Verbindung zu einem lokalen IPv6-Server auf.
- Daten werden korrekt gesendet und empfangen.
- `GetHostByName("ipv6.google.com"c)` gibt eine gültige IPv6-Adresse zurück.

---

## WP-08 · Windows ARM64 — Printf via wsprintfA

**Priorität:** Mittel

**Aufgabe**  
Formatierte Ausgabe `Printf(fmt, ...)` für Windows ARM64 implementieren, intern über `wsprintfA` aus `Kernel32.dll`.

**Kontext**  
Das Windows ARM64 Backend (`src/backend/win_arm64.lyx`) hat `PrintStr` und `PrintInt` als primitive Ausgabe. `wsprintfA` ist eine `cdecl`-Funktion aus `Kernel32.dll`, die bereits im IAT gelinkt ist. Zu unterstützen: `%s` (ANSI-String), `%d` (int32), `%f` (float als Dezimalzahl). Die Vararg-Übergabe auf Windows ARM64 folgt der Microsoft-ABI (x0–x3 + Stack).

| Format-Spezifier | Verhalten |
|-----------------|-----------|
| `%s` | ANSI-String-Pointer (pchar) |
| `%d` | int32-Dezimalzahl |
| `%f` | float64 mit 6 Nachkommastellen |
| `%%` | Literal-`%` |

**Nutzen**  
Komfortable formatierte Ausgabe für Debugging und User-facing Output auf Windows ARM64 — ohne manuelle String-Konkatenation. Ermöglicht Portierung von bestehenden Print-Aufrufen aus anderen Targets.

**Abnahme**
- `Printf("x=%d, s=%s\n"c, 42, "hello"c)` gibt `x=42, s=hello` aus.
- `Printf("%f\n"c, 3.14)` gibt `3.140000` aus.
- Kein Absturz bei `%%`-Escaping.

---

## WP-09 · Windows ARM64 VMT — Hardware-Verifikation

**Priorität:** Mittel

**Aufgabe**  
Das bestehende VMT-Testprogramm (`tests/wp09_win_arm64_vmt.lyx`) auf echter Windows ARM64 Hardware ausführen und das Ergebnis dokumentieren.

**Kontext**  
Das PE32+/Aarch64-Binary wurde unter QEMU und per Cross-Compilation verifiziert. Ein QEMU-Lauf ist kein Ersatz für echte Hardware — Mikroarchitektur-Details (Alignment, Cache-Verhalten, Calling-Convention-Randfälle) können dort abweichen. Das Binary ist unter `tests/wp09_win_arm64_vmt.lyx` versioniert und produziert bereits eine korrekte Ausgabe unter Emulation:
```
3
60
PASS
```

**Nutzen**  
Erst ein erfolgreicher Lauf auf echter Hardware (z.B. Surface Pro X, Surface Pro 11, Snapdragon-Laptop) schließt den Verifikationskreis für den gesamten ARM64-Windows-Codegen-Pfad ab. Ohne diese Bestätigung bleibt die Produktionsreife des Windows ARM64 Backends unklar.

**Abnahme**
- Programm gibt `3`, `60`, `PASS` auf der Konsole aus.
- Gerät und Betriebssystemversion werden im Commit-Message dokumentiert (z.B. `Surface Pro X, Windows 11 ARM64, Build 26100`).
- Ergebnis und Gerät werden als Follow-up-Commit in `tests/wp09_win_arm64_vmt.lyx` kommentiert.

---

## WP-13 · Inspect Debug-Visualizer — ARM64 Linux + Windows ARM64

**Priorität:** Niedrig

**Aufgabe**  
Den bestehenden `Inspect(expr)`-Builtin für ARM64 Linux und Windows ARM64 implementieren.

**Kontext**  
Die x86_64-Implementierung existiert seit WP-BC-39 in `src/codegen_x86.lyx` (ab Zeile 5040). Sie gibt `[Inspect:varname] value\n` auf stderr aus und extrahiert den Variablennamen direkt aus dem AST-Node — kein extra Import nötig. Die interne Hilfsfunktion `cg_emitInspectPrintInt()` enthält eine vollständige inline-itoa-Sequenz mit `idiv`.

Für die neuen Targets bedeutet das:

| Target | Syscall / API | itoa | Datenadressen |
|--------|--------------|------|---------------|
| ARM64 Linux | `write(2, buf, len)` via `svc #0` | `sdiv`/`msub`-Loop | ADRP + ADD |
| Windows ARM64 | `WriteFile(GetStdHandle(-12), ...)` via IAT | identisch ARM64 | ADRP + ADD |

**Nutzen**  
`Inspect(x)` ist ein einzeiliges, importfreies Debug-Werkzeug. Auf ARM64 Linux und Windows ARM64 fehlt es heute komplett — Entwickler müssen auf `PrintLn` und manuelle Konvertierungen ausweichen, was Debugging deutlich langsamer macht.

**Abnahme**
- ARM64 Linux: `var x: int64 := 42; Inspect(x)` gibt `[Inspect:x] 42` auf stderr aus.
- ARM64 Linux: `Inspect(2 + 3)` gibt `[Inspect:?] 5` aus (kein Variablenname für Expressions).
- Windows ARM64: Gleiches Verhalten, Ausgabe via `WriteFile` auf STDERR-Handle.
- Bestehende x86_64-Tests bleiben grün.
