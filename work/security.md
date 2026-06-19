# Sicherheits-Fahrplan — Aurum/Lyx (Offene Punkte)

> Letzte Aktualisierung: 2026-06-18  
> Status: ⬜ offen | 🔄 in Arbeit | ✅ erledigt

Von ursprünglich 25 WPs sind **20 abgeschlossen**. Security-Audit 2026-06-18 hat 12 neue WPs (26–37) ergeben.

---

## Offene Punkte — Übersicht

| WP | Titel | Priorität |
|----|-------|-----------|
| **7a** | Path Traversal — Compiler-Side (`_sema_readFile`, `_cg_readFile`) | ✅ Erledigt |
| **12** | SMTP mit STARTTLS + Header-Sanitisierung | 🟡 Mittel |
| **22** | Automatisierte Security-Tests im CI (inkl. LCBS) | 🟡 Mittel |
| **24** | seccomp-Filter-Vollständigkeit (Capability→Syscall-Mapping) | ✅ Erledigt |
| **25** | `--capabilities=compat` Laufzeit-Warnung | ✅ Erledigt |
| **6c** | PIE/ASLR für x86-64 ELF (zurückgestellt, Risiko hoch) | 🔵 Niedrig |
| **6b-ARM64** | W^X für ARM64-ELF-Writer (`writeELF`, `writeELFExecDynamic`) | 🟡 Mittel |
| **26** | `alloc()` Integer-Overflow + Zero-Alloc-Aliasing | 🔴 Kritisch |
| **27** | `read()`-Fehlerbehandlung OOB (`--unit-info` + `_sema_readFile`) | 🔴 Kritisch |
| **28** | Kernel-Mode-Guard Erweiterung (`std.net.epoll` + gesamtes `std.net.*`) | 🟠 Hoch |
| **29** | Lizenz-Secret-Architektur (XOR-Obfuskation → asymmetrisch) | 🟠 Hoch |
| **30** | HTTP Custom-Header CRLF-Injection | 🟠 Hoch |
| **31** | Dateigrößen-Limit in `FileReadAll` / `_sema_readFile` (DoS) | 🟠 Hoch |
| **32** | TOCTOU in `ms_appendMetaSafe` | 🟠 Hoch |
| **33** | String-Library Bounds-Hardening (`StrCopy`, `StrSubstr`, `StrLen`) | 🟡 Mittel |
| **34** | Codegen-Buffer-Größenlimit | 🟡 Mittel |
| **35** | LYU-Parser `symCount`-Limit | 🟡 Mittel |
| **36** | `SecureZero()` Compiler-Barriere | ✅ Erledigt |
| **37** | `RandInt64()` Fehlerbehandlung bei `getrandom`-Fehler | 🔵 Niedrig |

---

## WP-7a: Path Traversal — Compiler-Side ✅

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx` (`_sema_processImport`, Z. 826), `src/codegen_x86.lyx` (`cg_processImport`, Z. 9391) |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ 2026-06-14 |

**Implementiert:**
- Parser blockt `..` syntaktisch (primäre Verteidigung: `Expect(TK_IDENT)` lässt keine `.`-Tokens als Modulname zu)
- `_sema_processImport()`: Defensive Prüfung auf `..` im Modulnamen → `EPrintStr` + `hadError := 1` + `errorCount++` (vorher fehlte die Error-Markierung)
- `cg_processImport()`: Gleiche defensive Prüfung hinzugefügt (war zuvor komplett fehlend)

---

## WP-12: SMTP mit STARTTLS und Header-Sanitisierung

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/smtp.lyx` |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |

**Problem:** Kein STARTTLS — Credentials (AUTH LOGIN/PLAIN) gehen im Klartext über Port 25. `From`/`To`/`Subject` werden roh in den Header kopiert → CRLF-Injection möglich.

**Teilschritte:**

- [ ] **12.1** STARTTLS: Port 25 → EHLO → STARTTLS → TLS-Upgrade via `TLSInit`/`TLSConnect`
- [ ] **12.2** SMTPS: Port 465, direkt TLS beim Connect
- [ ] **12.3** `From`/`To`/`Subject` auf `\r`/`\n` prüfen → Ablehnung
- [ ] **12.4** AUTH-Kommando nur über aktiver TLS-Verbindung senden

**Definition of Done:**
- E-Mail-Versand über STARTTLS funktioniert
- Header mit `\r\n` werden abgewiesen
- Klartext-AUTH ohne TLS → Fehler

---

## WP-22: Automatisierte Security-Tests im CI

| Attribut | Wert |
|----------|------|
| **Dateien** | `.github/workflows/ci.yml`, `tests/security/` (neu) |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |

**Ziel:** Regressionssicherheit für alle implementierten WPs.

**Teilschritte:**

- [ ] **22.1** Crypto-Testvektoren: SHA-256("abc"), HMAC-SHA256 RFC 4231, PBKDF2 RFC 6070
- [ ] **22.2** FFI-Blacklist-Regression: `extern fn system(...)` → immer Compile-Error
- [ ] **22.3** seccomp-Enforcement: verbotener Syscall → SIGSYS (nicht bloß Score-Check)
- [ ] **22.4** Landlock: Zugriff auf nicht-deklarierten Pfad → EACCES
- [ ] **22.5** W^X-Regression: `readelf -l` auf generiertem ELF → kein RWX-Segment
- [ ] **22.6** Audit-Score-Regression: Basiswert darf nicht sinken
- [ ] **22.7** Path-Traversal-Test (nach WP-7a): `import ../../../etc/passwd` → Fehler

---

## WP-24: seccomp-Filter-Vollständigkeit ✅

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/security/seccomp_gen.lyx`, `src/codegen_x86.lyx` |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ 2026-06-14 |

**Implementiert:**
- **24.1** `getrandom` (318) als impliziten Syscall hinzugefügt — Stack-Canary-Init (`__lyx_canary_init`) braucht es bei jedem Programmstart; vorher SIGSYS Exit 159 mit `@capabilities`
- **24.3** Fehlende Syscalls ergänzt: `pread64` (17) und `newfstatat` (262) für `fs.read`/`fs.write`; `newfstatat` für `fs.meta`. Konstanten `SC_SYS_PREAD64` und `SC_SYS_NEWFSTATAT` hinzugefügt
- **24.4** ✅ Programm mit `@capabilities([fs.read])` liest `/etc/hostname` ohne SIGSYS — 53 BPF-Regeln (vorher 47)
- **24.5** ✅ `sys_getpid()` mit `@capabilities([fs.read])` → SIGSYS (Exit 159) bestätigt
- Audit-Ausgabe zeigt `getrandom` als implizite Capability: `o system.rand → getrandom (Stack-Canary-Init, WP-24.1)`
- SEED (`src/lyxc_bootstrap`) aktualisiert — SHA256: `5057c776555bae3f115447ebe06ea68500c54e31f6796d37d2f84971d539a6ee` — Singularität bestätigt: S3 == S4

---

## WP-25: `--capabilities=compat` Laufzeit-Warnung ✅

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx`, `src/codegen_x86.lyx` |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ 2026-06-14 |

**Implementiert:**
- **25.1** `lyxc.lyx`: 3-zeilige `stderr`-Warnung beim Parsen von `--capabilities=compat`
- **25.2** `codegen_x86.lyx`: `cg_genCompatWarnSection()` schreibt Warnung-String in Datensektion; `cg_emitCompatWarn()` emittiert `write(2, ptr, len)`-Syscall am Anfang von `main`
- **25.3** Audit zeigt `!!! WARNUNG: Compat-Modus !!!`-Header + `WARNUNG: Compat-Modus -- kein Laufzeitschutz` im Score-Block
- SEED (`src/lyxc_bootstrap`) aktualisiert — SHA256: `de528b39...` — Singularität S3==S4 bestätigt

---

## WP-6c: PIE/ASLR (zurückgestellt)

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx`, `src/lyxc.lyx` |
| **Priorität** | 🔵 Niedrig |
| **Status** | ⬜ zurückgestellt — hohes Implementierungsrisiko |

**Problem:** Alle generierten ELFs (statisch + dynamisch) haben feste Ladeadresse `0x400000`. Kein PIE → kein ASLR → ROP-Gadget-Adressen sind deterministisch.

**Blockade:** PIE erfordert positionsunabhängigen Code (`lea`/`rip`-relative Zugriffe statt absoluter Adressen) und eine vollständige Relocation-Table (`R_X86_64_PC32`). Der Codegen nutzt aktuell noch fixe Adressen für Datenzugriffe.

---

## WP-6b-ARM64: W^X für ARM64-ELF-Writer

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx` (`writeELF` Z. ~2500, `writeELFExecDynamic` Z. ~2340) |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |

**Problem:** Beide ARM64-ELF-Writer setzen `PT_LOAD p_flags = 7 (PF_R|PF_W|PF_X)` — Single-RWX-Segment, analog zur x86-64-Lage vor WP-6. Die x86-64-Lösung (zwei PT_LOADs RX+RW) muss auf ARM64 portiert werden.

**Teilschritte:**

- [ ] **6b-1** `writeELF` (ARM64 statisch): zwei PT_LOADs wie x86-64
- [ ] **6b-2** `writeELFExecDynamic` (ARM64 dynamisch): zwei PT_LOADs, Page-Alignment prüfen

---

## WP-26: `alloc()` Integer-Overflow + Zero-Alloc-Aliasing 🔴

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/std/alloc.lyx`, Z. 16–35 |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt (2026-06-18, commit eab88e6) |
| **Quelle** | Security-Audit 2026-06-18 (C-1, C-2) |

**Problem 1 — Integer-Overflow (C-1):** `alloc(size)` berechnet `((size + 15) / 16) * 16`. Bei `size ≈ INT64_MAX` überläuft `size + 15` auf einen negativen Wert → `aligned` wird winzig → `alloc()` gibt einen bereits genutzten Pointer zurück → Heap-Überschreibung. Tritt auf wenn zwei sehr große Strings konkateniert werden (`StrConcat`).

**Problem 2 — Zero-Alloc-Aliasing (C-2):** `alloc(0)` erhöht `_arena_off` nicht. Zwei aufeinanderfolgende `alloc(0)`-Aufrufe liefern **identische Adressen**. Schreibzugriffe auf einen der Pointer korrumpieren das andere Objekt.

**Fix:**
```
pub fn alloc(size: int64): int64 {
    if size <= 0 { size := 1; }                      // C-2: Zero-Alloc
    if size > 0x40000000 { return 0; }               // C-1: Integer-Overflow-Guard (max 1 GB)
    ...
}
```

**Teilschritte:**
- [x] **26.1** Guard-Zeilen in `alloc()` einfügen (src/std/alloc.lyx + std/alloc.lyx)
- [x] **26.2** Regressionstest: `tests/sec_wp26_alloc_test.lyx` — 15/15 PASS; `make test` — 0 FAIL
- [ ] **26.3** Singularität prüfen + Seed updaten

---

## WP-27: `read()`-Fehlerbehandlung OOB 🔴

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx` Z. 4384; `src/sema.lyx` Z. 757 |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt (2026-06-18, commit eab88e6) |
| **Quelle** | Security-Audit 2026-06-18 (C-3, M-4) |

**Problem 1 — OOB-Schreibzugriff `--unit-info` (C-3):**
```
uiSz := read(uiFd, uiBuf as pchar, 131071);
poke8(uiBuf + uiSz, 0);   // bei uiSz = -1 (EINTR): schreibt 1 Byte VOR dem Buffer
```
Wenn `read()` durch ein Signal unterbrochen wird (`EINTR`), ist `uiSz = -1` → `poke8(uiBuf - 1, 0)` korrumpiert Arena-Metadaten.

**Problem 2 — Partieller Read in `_sema_readFile` (M-4):** Rückgabewert von `read()` ungeprüft → bei partiellem Read enthält der Rest des Buffers Arena-Müll → Parser verarbeitet korrumpierte Quelldaten.

**Fix:**
```
// src/lyxc.lyx Z. 4384
uiSz := read(uiFd, uiBuf as pchar, 131071);
if uiSz < 0 { uiSz := 0; }    // EINTR-Guard

// src/sema.lyx Z. 757
var bytesRead: int64 := read(fd, buf as pchar, size);
if bytesRead != size { close(fd); return 0 as pchar; }
```

**Teilschritte:**
- [x] **27.1** `--unit-info` OOB-Guard in `src/lyxc.lyx` (Z. 4384: `if uiSz < 0 { uiSz := 0; }`)
- [x] **27.2** `_sema_readFile` Rückgabewert-Prüfung in `src/sema.lyx` (Z. 757: partial-read guard)
- [x] **27.3** Regressionstest: `make test` — 0 FAIL

---

## WP-28: Kernel-Mode-Guard Erweiterung 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx`, `_sema_isKernelForbidden()` |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt (2026-06-18, branch fix/sec-wp28-kernel-guard-allowlist) |
| **Quelle** | Security-Audit 2026-06-18 (H-1) |

**Problem:** Die aktuelle Forbidden-List für `--target=lyxos-kernel` blockt explizit benannte Module, lässt aber `std.net.epoll` und alle weiteren POSIX-abhängigen `std.net.*`-Module durch. `std.net.epoll` ruft direkt `sys_epoll_create1`/`sys_epoll_ctl`/`sys_epoll_wait` auf — ohne `std.net.socket` zu importieren, greift kein transitives Blocking.

**Fehlende Module:** `std.net.epoll`, `std.net.tls`, `std.net.http`, `std.net.https`, `std.net.dns`, `std.net.mqtt`, `std.net.quic`, `std.net.ssh`, `std.net.smtp`, `std.net.imap`, `std.net.ldap`, `std.net.rest`.

**Fix:** Statt Blockliste → Allowlist-Ansatz: alle `std.net.*` blockieren, explizite Ausnahmen für die reinen Frame-Units:
```
// Blockiere gesamtes std.net.* — dann Ausnahmen erlauben
if self._sema_kmPfx(modName, modLen, "std.net."c) != 0 {
    // Erlaubte reine Frame-Units
    if self._sema_kmEq(modName, modLen, "std.net.eth"c)        != 0 { return 0; }
    if self._sema_kmEq(modName, modLen, "std.net.ipv4"c)       != 0 { return 0; }
    if self._sema_kmEq(modName, modLen, "std.net.udp"c)        != 0 { return 0; }
    if self._sema_kmEq(modName, modLen, "std.net.arp.frame"c)  != 0 { return 0; }
    if self._sema_kmEq(modName, modLen, "std.net.dhcp.frame"c) != 0 { return 0; }
    return 1;  // alles andere: verboten
}
```

**Teilschritte:**
- [x] **28.1** `_sema_isKernelForbidden()` auf Allowlist-Ansatz für `std.net.*` umgestellt
- [x] **28.2** `std.fs.*`, `std.thread.*`, `std.os.*`, `std.io.*` als Prefix-Blockliste beibehalten
- [x] **28.3** Tests: `tests/sec_wp28_kernel_guard_test.sh` — 20/20 PASS; `make test` — 0 FAIL

---

## WP-29: Lizenz-Secret-Architektur 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/crypto/lic_secret.lyx` |
| **Priorität** | 🟠 Hoch |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (H-2) |

**Problem:** Das 32-Byte Lizenz-Master-Secret ist als XOR zweier Int64-Konstanten in der Binary eingebettet. Beide Hälften jedes Paars sind im Binary-Image vorhanden → das Secret ist trivial rekonstruierbar (`strings lyxc` + XOR). Ein Angreifer kann danach beliebige Lizenzschlüssel für beliebige Name/Email-Kombinationen generieren. Die XOR-Obfuskation liefert Null-Sicherheit gegen Binary-Analyse.

**Fix-Optionen (absteigend nach Sicherheit):**
1. **Asymmetrische Signatur:** Ed25519 — privater Schlüssel nur beim Aussteller, öffentlicher Schlüssel in der Binary. Lizenzprüfung = Signatur-Verifikation.
2. **Hardware-Binding:** Secret wird aus Maschinenmerkmalen (CPU-ID, MAC, Hostname) abgeleitet → Lizenz ist maschinengebunden.
3. **Obfuskation verbessern:** Zumindest Secret aus Runtime-Berechnung ableiten statt statischer Konstanten.

**Empfehlung:** Option 1 (Ed25519). Implementierungsaufwand ~2 Tage; `std/crypto/` hat bereits SHA-256/HMAC.

**Teilschritte:**
- [ ] **29.1** Ed25519-Verifikation in `src/crypto/` implementieren (oder libsodium-Binding)
- [ ] **29.2** `lic_secret.lyx` auf Public-Key-Ansatz umstellen
- [ ] **29.3** Keygen-Tool anpassen (`src/lyxc_keygen.lyx`)
- [ ] **29.4** Bestehende Lizenzschlüssel migrieren

---

## WP-30: HTTP Custom-Header CRLF-Injection 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/http.lyx`, Z. 204–207 |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt (feat/hl7 → develop) |
| **Quelle** | Security-Audit 2026-06-18 (H-3) |

**Problem:** `Host` und `Path` werden bereits auf CRLF geprüft (Z. 147–149), aber `req.headers` (benutzerdefinierte Header) wird ohne jede Validierung direkt in den Request-Buffer geschrieben. Ein Angreifer mit Kontrolle über `req.headers` kann beliebige HTTP-Header injizieren — inkl. `\r\nTransfer-Encoding: chunked\r\n`, Body-Injection und Request-Smuggling.

**Fix (implementiert):**
- `std/net/http.lyx`: Neue Funktion `http_hasInjectionCrLf` — erkennt nacktes CR/LF und doppeltes CRLF (`\r\n\r\n`), erlaubt einzelne CRLF-Zeilentrenner (wie von `HTTPSetHeader` generiert)
- `HTTPRequestBuild`: Prüft `req.headers` mit `http_hasInjectionCrLf`; bei Fehler `munmap` + `return 0`
- `HTTPSetHeader`: Prüft `name` und `value` mit `http_hasCrLf`; bei CRLF `return 0` (Validierung an der Quelle)
- `std/net/dns.lyx`: `@cap(system.time)` auf `extern fn time` ergänzt (fehlende FFI-Annotation)

**Teilschritte:**
- [x] **30.1** CRLF-Check für `req.headers` in `std/net/http.lyx`
- [x] **30.2** CRLF-Validierung in `HTTPSetHeader` (Name + Value)
- [x] **30.3** Test `tests/sec_wp30_crlf_test.lyx` — 20 Tests PASS

---

## WP-31: Dateigrößen-Limit (DoS-Schutz) 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (builtin), `src/std/io.lyx`, `src/sema.lyx` |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt (feat/hl7 → develop) |
| **Quelle** | Security-Audit 2026-06-18 (H-4) |

**Problem:** `FileReadAll` und `_sema_readFile` lesen Dateien ohne Größenlimit. Eine 4-GB-Eingabedatei (oder ein 4-GB-`.lyu`-File) erschöpft den Systemspeicher → OOM-Kill. Da `alloc()` unbegrenzt wächst, kann ein Angreifer mit einer präparierten Datei alle anderen Prozesse auf dem System killen.

**Fix (implementiert):**
- `src/codegen_x86.lyx`: Limit direkt als x86-Maschinenbytes im `FileReadAll`-Builtin eingebaut (`cmp rax, 268435456` + `jle`/`jg` short jumps); zusätzlich size ≤ 0 Prüfung
- `src/std/io.lyx`: Limit in der Quelle als Fallback (für nicht-builtin-Nutzung)
- `src/sema.lyx` `_sema_readFile`: Limit für importierte `.lyx`/`.lyu`-Dateien beim Kompilieren
- Fehlermeldung auf stderr bei Überschreitung; `256-MB-Limit` im Text für Grep-Tests

**Teilschritte:**
- [x] **31.1** Limit im `FileReadAll`-Builtin (`src/codegen_x86.lyx`) als x86-Bytes
- [x] **31.2** Limit in `_sema_readFile` (`src/sema.lyx`)
- [x] **31.3** Fehlermeldung bei überschrittenem Limit (enthält `256-MB-Limit`)
- [x] **31.4** Test `tests/sec_wp31_filesize_test.sh` — 20 Tests PASS

---

## WP-32: TOCTOU in `ms_appendMetaSafe` 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx` Z. 208, 315 |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt (fix/sec-wp32-toctou-metasafe → develop) |
| **Quelle** | Security-Audit 2026-06-18 (H-5) |

**Problem:** `ms_appendMetaSafe` öffnet die Output-Binary mit `O_RDONLY`, liest sie, schließt den FD, berechnet Hashes, öffnet sie dann neu mit `O_WRONLY|O_CREAT|O_TRUNC` und überschreibt sie. In diesem Zeitfenster kann ein anderer Prozess die Datei durch eine präparierte Version ersetzen (Symlink-Attack, Race Condition). Der Compiler würde dann die manipulierte Binary mit einem gültigen Sicherheits-Header stempeln.

**Fix (implementiert):**
- `open(path, 0, 0)` (O_RDONLY) → `open(path, 2, 0)` (O_RDWR)
- `close(fd)` nach dem Lesen entfernt — fd bleibt offen
- Zweites `open(path, 577, 493)` (O_WRONLY|O_CREAT|O_TRUNC) ersetzt durch `lseek(fd, 0, 0)` + `write(fd, ...)` auf demselben fd
- Einzelnes `close(fd)` am Ende — kein TOCTOU-Fenster mehr möglich

**Teilschritte:**
- [x] **32.1** `O_RDONLY` → `O_RDWR` in einem `open()`
- [x] **32.2** In-place-Schreiblogik: `lseek + write` statt zweitem `open`
- [x] **32.3** Test `tests/sec_wp32_toctou_test.sh` — 20 Tests PASS

---

## WP-33: String-Library Bounds-Hardening 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (strlen x86), `src/std/string.lyx`, `src/sema.lyx`, `src/codegen_x86.lyx` (loop) |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt (fix/sec-wp33-string-bounds → develop) |
| **Quelle** | Security-Audit 2026-06-18 (M-1, M-2, M-3, L-2) |

**Probleme und Fixes:**

1. **`StrLen(0)` → SIGSEGV**: `_lyx_strlen`-Builtin (x86) hatte keinen Null-Guard. Fix: `test rdi, rdi; jz` an den Beginn der Helper-Funktion; Helper von 15 auf 24 Bytes; alle nachfolgenden Helper-Offsets +9.

2. **`StrCopy` Off-by-One** (Z. 232): `while i <= srcLen` → `while i < srcLen` + explizites `poke8(dest + srcLen, 0)` in der Source (Builtin in `codegen_x86.lyx` läuft via strlen und ist unabhängig korrekt).

3. **`StrSubstr` ohne Bounds-Prüfung** (Z. 290): `if src == 0 || start < 0 || len < 0 || start + len > srcLen { return 0; }` eingefügt.

4. **`_sema_processImport`/`cg_processImport` Loop-Bedingung**: `while wptd < modLen - 1` → `while wptd + 1 < modLen` in `src/sema.lyx` und `src/codegen_x86.lyx`.

**Teilschritte:**
- [x] **33.1** `_lyx_strlen`-Builtin: Null-Pointer-Guard als x86-Bytes (codegen_x86.lyx)
- [x] **33.2** `StrCopy`: Off-by-One in src/std/string.lyx korrigiert
- [x] **33.3** `StrSubstr`: Bounds-Check (src/std/string.lyx)
- [x] **33.4** `_sema_processImport` + `cg_processImport`: Loop-Bedingung korrigiert
- [x] **33.5** Test `tests/sec_wp33_string_bounds_test.sh` — 20 Tests PASS

---

## WP-34: Codegen-Buffer-Größenlimit 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt (fix/sec-wp34-codegen-buffer-limit → develop) |
| **Quelle** | Security-Audit 2026-06-18 (M-5) |

**Problem:** Der Code-Output-Buffer beginnt mit 65 536 Bytes und verdoppelt sich unbegrenzt. Eine crafted große Eingabedatei (z. B. eine Million inline-Assemblerwerte) kann den Buffer auf mehrere GB wachsen lassen → OOM.

**Fix:**

1. **`codeOverflow`/`dataOverflow`-Flags** in der `Codegen`-Klasse (beide in `Init()` auf 0 gesetzt).
2. **`cg_grow()`/`cg_growData()`**: Vor Verdopplung wird `nc > 536870912` (512 MB) geprüft; bei Überschreitung wird das Flag gesetzt und ein Fehler per `EPrintStrLn` ausgegeben.
3. **`cg_e8()`/`cg_edata()`**: Prüft das jeweilige Overflow-Flag vor jedem Byte; bei gesetztem Flag wird `return` ausgeführt (kein OOB-Write).
4. **`WriteELF()`**: Prüft beide Flags am Anfang; bei gesetztem Flag wird die Ausgabe mit Fehlermeldung abgebrochen.

**Teilschritte:**
- [x] **34.1** `codeOverflow`/`dataOverflow`-Flags in Codegen-Klasse + `Init()` initialisiert
- [x] **34.2** `cg_grow()`/`cg_growData()`: 512-MB-Check + Fehlermeldung
- [x] **34.3** `cg_e8()`/`cg_edata()`: Overflow-Guard (kein Byte nach Overflow)
- [x] **34.4** `WriteELF()`: Guard verhindert korrupte ELF-Ausgabe
- [x] **34.5** Test `tests/sec_wp34_codegen_buffer_test.sh` — 20 Tests PASS

---

## WP-35: LYU-Parser `symCount`-Limit 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx` |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt (fix/sec-wp35-lyu-symcount-limit → develop) |
| **Quelle** | Security-Audit 2026-06-18 (M-6) |

**Problem:** `symCount` wird aus einer `.lyu`-Datei gelesen ohne obere Schranke. Eine crafted `.lyu`-Datei mit `symCount = 0x7FFFFFFF` treibt das Symboltabellen-Wachstum ins Extreme.

**Wurzelursache (neu entdeckt):** `_sema_processImport` nutzte `StrLen(lyuSrc)` für die `.lyu`-Größe — da `.lyu` Binärformat ist und `\x00` ab Byte 3 (Magic-Padding) enthält, lieferte `StrLen` immer 3 → `_sema_parseLyuSyms` exitete sofort wegen `size < 10`. Das `symCount`-Limit konnte nicht greifen.

**Fix:**

1. **`lastReadSize: int64`** in der Sema-Klasse: wird in `_sema_readFile` auf die echte Dateigröße (via `lseek`) gesetzt, bevor der Buffer zurückgegeben wird.
2. **`_sema_processImport`**: nutzt jetzt `self.lastReadSize` statt `StrLen(lyuSrc)` → binärsicheres Parsen.
3. **`_sema_parseLyuSyms`**: `if symCount > 65536 { EPrintStrLn(...); return; }` → verhindert OOM.

**Teilschritte:**
- [x] **35.1** `lastReadSize`-Feld + binärsichere Größenübergabe an `_sema_parseLyuSyms`
- [x] **35.2** `symCount > 65536`-Check + Fehlermeldung in `_sema_parseLyuSyms`
- [x] **35.3** Test `tests/sec_wp35_lyu_symcount_test.sh` — 20 Tests PASS

---

## WP-36: `SecureZero()` Compiler-Barriere 🔵

| Attribut | Wert |
|----------|------|
| **Dateien** | `lyx-compiler/usr/include/lyx/units/std/crypto/ct.lyx` Z. 79–85 |
| **Priorität** | 🔵 Niedrig |
| **Status** | ✅ erledigt (fix/sec-wp36-securezero-barrier → develop) |
| **Quelle** | Security-Audit 2026-06-18 (I-1) |

**Problem:** `SecureZero()` nutzte eine `poke8`-Schleife ohne Compiler-Barriere. Ein aggressiver Optimizer könnte Dead-Store-Elimination anwenden und die Schleife komplett entfernen. `lic_zeroSecret()` nutzt korrekt `explicit_bzero()` (nicht wegoptimierbar), aber `SecureZero()` in `std/crypto/ct.lyx` tat das nicht.

**Analyse (36.1):** Der Lyx-Codegen macht **kein** Dead-Store-Elimination auf `poke8` (nicht-optimierender Einpass-Compiler). Die `poke8`-Schleife wäre zur Laufzeit sicher. Dennoch: `explicit_bzero` als Defense-in-Depth für zukünftige Optimizer-Pässe und zur Konsistenz mit `lic_zeroSecret()`.

**Fix (implementiert):**
- `extern fn explicit_bzero(ptr: pchar, n: int64) link "libc.so.6"` zu `ct.lyx` hinzugefügt
- `SecureZero()` ersetzt `poke8`-Schleife durch `explicit_bzero(ptr as pchar, len)` mit `len <= 0`-Guard

**Teilschritte:**
- [x] **36.1** Lyx-Codegen macht kein DSE auf `poke8` (bestätigt — non-optimizing compiler)
- [x] **36.2** `explicit_bzero`-Binding + Umstieg in `SecureZero()` (Defense-in-Depth)
- [x] **36.3** Test `tests/sec_wp36_securezero_test.sh` — 20 Tests PASS

---

## WP-37: `RandInt64()` Fehlerbehandlung 🔵

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/crypto/rand.lyx` |
| **Priorität** | 🔵 Niedrig |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (I-3) |

**Problem:** `RandInt64()` gibt `0` zurück wenn `getrandom` fehlschlägt. Der Kommentar verschleiert den Fehler. Aufrufer, die den Rückgabewert nicht auf Null prüfen, könnten vorhersagbare Werte verwenden (z. B. als Session-Token, Nonce, CSRF-Token).

**Fix:** Expliziten Fehlerindikator zurückgeben (z. B. separater Out-Parameter) oder bei `getrandom`-Fehler abbrechen (`exit(1)`), da vorhersagbare Zufallszahlen schlimmer sind als ein Programm-Abbruch.

**Teilschritte:**
- [ ] **37.1** Fehlerfall dokumentieren (Kommentar präzisieren)
- [ ] **37.2** Fehlerbehandlungsstrategie entscheiden: Abbruch oder Fehlercode
- [ ] **37.3** Alle Aufrufer von `RandInt64()` auf Fehlerfall-Handling prüfen

---

## Bearbeitungsstatus (vollständig)

| WP | Titel | Status | Ende | Prio |
|----|-------|--------|------|------|
| 1 | Kryptografische Hash-Funktionen | ✅ | 2026-05-31 | 🔴 |
| 2 | TLS-Hostname-Verifikation | ✅ | 2026-05-31 | 🔴 |
| 3 | SSH-Host-Key-Verifikation | ✅ | 2026-05-31 | 🔴 |
| 4 | MongoDB-Treiber absichern | ✅ | 2026-06-01 | 🔴 |
| 5 | Gefährliche FFI-Externs (via LCBS WP-L5) | ✅ | 2026-06-03 | 🟠 |
| 6 | W^X für x86-64 ELF (statisch + dynamisch) | ✅ | 2026-06-13 | 🔴 |
| **6b-ARM64** | **W^X für ARM64-ELF-Writer** | **⬜** | – | 🟡 |
| **6c** | **PIE/ASLR** | **⬜ zurückgestellt** | – | 🔵 |
| **7a** | **Path Traversal — Compiler-Side** | **✅** | 2026-06-14 | 🟠 |
| 7b | Path Traversal — Stdlib/Runtime (via Landlock) | ✅ | 2026-06-03 | – |
| 8 | SQL Injection schließen | ✅ | 2026-06-03 | 🟠 |
| 9 | HTTP-Client absichern | ✅ | 2026-06-03 | 🟠 |
| 10 | Integer-Overflow-Prüfungen | ✅ | 2026-06-03 | 🟠 |
| 11 | Redis-Treiber korrigieren | ✅ | 2026-06-03 | 🟠 |
| **12** | **SMTP mit TLS + Header-Sanitisierung** | **⬜** | – | 🟡 |
| 13 | Crypto-Memory sicher löschen | ✅ | 2026-06-03 | 🟡 |
| 14 | DNS-Parser mit Limits | ✅ | 2026-06-03 | 🟡 |
| 15 | Constant-Time Crypto | ✅ | 2026-06-03 | 🟡 |
| 16 | gen_lic_secret.py sicherer | ✅ | 2026-06-04 | 🟡 |
| 17 | Annotationen dokumentieren | ✅ | 2026-06-04 | 🟡 |
| 18 | Stack-Canaries | ✅ | 2026-06-04 | 🔵 |
| 19 | ARM64-Dynamic-Linking-Bugs | ✅ | – | 🔵 |
| 20 | `.meta_safe` Code-Integrität | ✅ | 2026-06-04 | 🟡 |
| 21 | Debug-Datei entfernen | ✅ | 2026-06-13 | 🔵 |
| **22** | **Security-Tests im CI** | **⬜** | – | 🟡 |
| 23 | Audit W^X-Reporting korrigieren | ✅ | 2026-06-13 | 🔴 |
| **24** | **seccomp-Filter-Vollständigkeit** | **✅** | 2026-06-14 | 🟠 |
| **25** | **--capabilities=compat Warnung** | **✅** | 2026-06-14 | 🟡 |
| **26** | **alloc() Integer-Overflow + Zero-Alloc** | **⬜** | – | 🔴 |
| **27** | **read()-Fehlerbehandlung OOB** | **⬜** | – | 🔴 |
| **28** | **Kernel-Mode-Guard Erweiterung** | **⬜** | – | 🟠 |
| **29** | **Lizenz-Secret-Architektur** | **⬜** | – | 🟠 |
| **30** | **HTTP Custom-Header CRLF-Injection** | **⬜** | – | 🟠 |
| **31** | **Dateigrößen-Limit (DoS-Schutz)** | **⬜** | – | 🟠 |
| **32** | **TOCTOU in ms_appendMetaSafe** | **⬜** | – | 🟠 |
| **33** | **String-Library Bounds-Hardening** | **⬜** | – | 🟡 |
| **34** | **Codegen-Buffer-Größenlimit** | **⬜** | – | 🟡 |
| **35** | **LYU-Parser symCount-Limit** | **⬜** | – | 🟡 |
| **36** | **SecureZero() Compiler-Barriere** | **✅** | 2026-06-19 | 🔵 |
| **37** | **RandInt64() Fehlerbehandlung** | **⬜** | – | 🔵 |
