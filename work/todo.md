# Aurum — Arbeitspakete

> Stand: 2026-06-08. Jedes WP ist eigenständig bearbeitbar. Status nach Abschluss updaten.

---

## Übersicht

| WP | Titel | Prio | Status |
|----|-------|------|--------|
| WP-01 | Windows ARM64 — StrSub / StrConcat / StrCopy | Hoch | [ ] Offen |
| WP-02 | macOS x86_64 — VMT / DynArray / Closures | Hoch | [ ] Offen |
| WP-03 | ARM64 Linux — CRT-Init für Dynamic Linking | Hoch | [ ] Offen |
| WP-04 | Compiler — Tuple-Return-Typ `[T, T]` | Hoch | [ ] Offen |
| WP-05 | std/audio.lyx — Audio Unit (WAV / ALSA / MP3) | Mittel | [ ] Offen |
| WP-06 | macOS x86_64 — Socket-Builtins | Mittel | [ ] Offen |
| WP-07 | std.net — IPv6 Support | Mittel | [ ] Offen |
| WP-08 | Windows ARM64 — printf via wsprintfA | Mittel | [ ] Offen |
| WP-09 | Windows VMT — Hardware-Verifikation | Mittel | [ ] Offen |
| WP-10 | ARM64 Linux — PIE Binary (ET_DYN) | Niedrig | [ ] Offen |
| WP-11 | macOS x86_64 — StrEndsWith | Niedrig | [x] Erledigt |
| WP-12 | Xtensa/ESP32 — PrintInt (echte itoa) | Niedrig | [x] Erledigt |

---

## WP-01 · Windows ARM64 — String-Funktionen

**Priorität:** Hoch  
**Problem:** `StrSub`, `StrConcat`, `StrCopy` allozieren Speicher, kopieren aber nicht. Aufrufer erhalten Puffer mit Zufallsinhalt — stilles Fehlverhalten, kein Compile- oder Runtime-Error.

| # | Aufgabe | Detail |
|---|---------|--------|
| 1 | `StrSub(s, start, len)` | VirtualAlloc + memcpy-Loop über `len` Bytes ab `start` |
| 2 | `StrConcat(a, b)` | VirtualAlloc(lenA + lenB + 1) + beide Strings kopieren |
| 3 | `StrCopy(s)` | VirtualAlloc + lstrlenA + memcpy |

---

## WP-02 · macOS x86_64 — Kern-Features

**Priorität:** Hoch  
**Problem:** VMT blockiert Object-Oriented-Code auf macOS vollständig. DynArray und Closures funktionieren auf allen anderen Targets, nur macOS fehlt.

| # | Aufgabe | Detail |
|---|---------|--------|
| 1 | VMT / Virtual Calls | Dispatch-Tabelle aufbauen + `new`-Initialisierung |
| 2 | DynArray | Push/Pop/Len/Free — analog x86_64 Linux implementieren |
| 3 | Closures / Static-Link | Capture-Variablen über Frame-Grenze (Upvalue-Pointer) |

Empfohlene Reihenfolge: VMT → DynArray → Closures (unabhängig, VMT ist der Blocker).

---

## WP-03 · ARM64 Linux — CRT-Init

**Priorität:** Hoch  
**Problem:** Ohne korrekten CRT-Start-Code scheitern dynamisch gegen libc gelinkte Programme beim Aufruf von Funktionen, die `__libc_start_main` voraussetzen.

| # | Aufgabe | Detail |
|---|---------|--------|
| 1 | CRT-Start-Code emittieren | `_start` → `__libc_start_main(main, argc, argv, ...)` |
| 2 | argc/argv aus Linux ABI | rdi (argc) + rsi (argv-Zeiger) korrekt an `main` weitergeben |

---

## WP-04 · Compiler — Tuple-Return-Typ

**Priorität:** Hoch  
**Problem:** `BoundingBoxFromPoints` und `CalculateBoundingBox` in `std/geo.lyx` können `[GeoPoint, GeoPoint]` nicht als Return-Type deklarieren. Der Parser behandelt `[...]` in Typ-Positionen als Array-Elementtyp, nicht als Tuple. Fünf koordinierte Änderungen nötig.

| Schritt | Datei | Aufgabe |
|---------|-------|---------|
| 1 | `ast.pas` | `atTuple` Knotentyp + `TTupleElemTypes`-Record |
| 2 | `parser.pas` | `[T, T, ...]` in `ParseTypeExFull` → Tuple statt Array wenn Identifier-Liste |
| 3 | `sema.pas` | Return-Type-Check für Tuple-Annotationen; Stellenzahl prüfen |
| 4 | `lower_ast_to_ir.pas` | Tuple-Return lowern → `irReturnStruct` oder Hidden-Pointer |
| 5 | `x86_64_emit.pas` | SysV ABI: 2 Structs ≤16B → RAX:RDX, >16B → Hidden-Ptr in RDI |

---

## WP-05 · std/audio.lyx — Audio Unit

**Priorität:** Mittel  
**Problem:** Komplett neues Modul, kein einziger Punkt existiert. Drei Phasen; Phase A ist Voraussetzung für B und C.

**Phase A — WAV + ALSA (Basis)**

| # | Aufgabe | Detail |
|---|---------|--------|
| A1 | API Design | `AudioOpen`, `AudioPlay`, `AudioClose` in `std/audio.lyx` |
| A2 | WAV Parser | RIFF-WAVE: fmt-Chunk + data-Chunk lesen |
| A3 | WAV Decoder | PCM 8-bit unsigned, 16-bit signed, Mono/Stereo |
| A4 | ALSA Syscalls | `snd_pcm_open`, `snd_pcm_write`, `snd_pcm_close` via FFI |
| A5 | Tests | `tests/audio_test.lyx` — WAV laden + abspielen |

**Phase B — PipeWire (Alternative zu ALSA)**

| # | Aufgabe | Detail |
|---|---------|--------|
| B1 | PipeWire Support | `pw_stream_connect`, `pw_stream_write` als Alternative zu ALSA |

**Phase C — MP3**

| # | Aufgabe | Detail |
|---|---------|--------|
| C1 | MP3 Parser | ID3v2 Tag-Parsing, Frame-Header Dekodierung |
| C2 | MP3 Decoder | Minimaler Frame-Extraktor oder FFI zu `libmpg123` |
| C3 | Tests | `tests/audio_test.lyx` um MP3 erweitern |

---

## WP-06 · macOS x86_64 — Socket-Builtins

**Priorität:** Mittel  
**Hinweis:** macOS verwendet `0x2000000`-Präfix vor Syscall-Nummern (z.B. `socket` = `0x2000061`).

| # | Aufgabe |
|---|---------|
| 1 | `sys_socket`, `sys_bind`, `sys_listen`, `sys_accept`, `sys_connect` |
| 2 | `sys_recvfrom`, `sys_sendto`, `sys_setsockopt`, `sys_getsockopt`, `sys_shutdown` |

---

## WP-07 · std.net — IPv6

**Priorität:** Mittel  
**Problem:** `SockAddrIn6` ist in `std/net/socket.lyx` definiert, aber nirgends verwendet.

| # | Aufgabe | Detail |
|---|---------|--------|
| 1 | AF_INET6 in sys_bind / sys_connect | `sockaddr_in6` befüllen + übergeben |
| 2 | GetHostByName erweitern | AAAA-Records auswerten, IPv6-Adresse zurückgeben |
| 3 | Neue API-Funktionen | `SocketNewV6`, `BindV6`, `ConnectV6` in `std/net/socket.lyx` |

---

## WP-08 · Windows ARM64 — printf

**Priorität:** Mittel

| # | Aufgabe | Detail |
|---|---------|--------|
| 1 | printf via `wsprintfA` | Format-String-Parsing für `%s`, `%d`, `%f` |

---

## WP-09 · Windows VMT — Hardware-Verifikation

**Priorität:** Mittel  
**Problem:** Virtual Calls wurden nur unter QEMU verifiziert.  
**Status:** Test-Binary bereit (`tests/wp09_win_arm64_vmt.lyx` → `wp09_vmt.exe`, PE32+/Aarch64 verified).  
Ausführung auf echter Windows ARM64 Hardware noch ausstehend.

| # | Aufgabe | Status |
|---|---------|--------|
| 1 | Virtual-Dispatch-Test auf echter Windows ARM64 Hardware ausführen | ⏳ ausstehend |
| 2 | Ergebnis (Pass/Fail + Gerät) in Commit-Message dokumentieren | ⏳ ausstehend |

---

## WP-10 · ARM64 Linux — PIE Binary

**Priorität:** Niedrig  
**Status:** ELF-Writer geändert (`src/lyxc.lyx` → `writeELF`): ET_DYN + loadVA=0x1000 für `LYX_TC_ARM64`.  
Test-Datei: `tests/wp10_arm64_pie.lyx`.  
Bekannte Einschränkung: x86_64-Cross-Compilation schlägt wegen `InjectConBool`-Shadowing fehl; nativ auf ARM64 Linux ausführen.

| # | Aufgabe | Detail | Status |
|---|---------|--------|--------|
| 1 | `ET_DYN` im ELF-Header | Nur ELF-Writer ändern; kein IR-Änderungsbedarf | ✅ erledigt |

---

## WP-11 · macOS x86_64 — StrEndsWith

**Priorität:** Niedrig  
**Status:** ✅ erledigt

| # | Aufgabe | Status |
|---|---------|--------|
| 1 | `StrEndsWith` vollständig implementieren | ✅ erledigt |

**Root Cause:** `repe cmpsb` mit `rcx=0` (leeres Suffix) führt nicht aus und lässt ZF undefiniert.  
`sete al` las dann ZF des vorherigen `sub`-Befehls → false statt true.  
**Fix:** `test rcx, rcx; jz .sewzero` vor `repe cmpsb`; `.sewzero` setzt `eax=1` direkt.  
**Betrifft:** `src/codegen_x86.lyx` + `bootstrap/codegen_x86.lyx`; macOS-Binary ist korrekt (verbatim-copy von offset 301+).

---

## WP-12 · Xtensa/ESP32 — PrintInt

**Priorität:** Niedrig  
**Status:** ✅ erledigt (WP-D3, commit d0fd8a7)

| # | Aufgabe | Detail | Status |
|---|---------|--------|--------|
| 1 | Echte itoa-Loop | Iterative Subtraktion (×10), Digit-Buffer sp+8..23, UART 0x60000000 | ✅ erledigt |

**Implementierung:** `xt_emitPrintIntHelper()` in `src/backend/xtensa.lyx` (111 Bytes, 37 Xtensa-Instruktionen).  
Digits werden rückwärts in Stack-Buffer sp+8..23 gespeichert, vorwärts via S8I → a5=0x60000000 ausgegeben.  
Negative Zahlen: NEG + direktes `-` an UART. Zero: korrekt als `0` ausgegeben.  
**Test:** `tests/wp12_esp32_printint.lyx` → Xtensa ELF32, e_machine=0x5e, e_entry=0x400800xx.

---

## Deferred

| Thema | Begründung |
|-------|------------|
| `Inspect` — Debug-Visualizer (ARM64 + Windows ARM64) | Existiert auch nicht im Referenz-Backend x86_64; erst relevant wenn x86_64-Implementierung vorliegt |

