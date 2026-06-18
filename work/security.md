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
| **36** | `SecureZero()` Compiler-Barriere | 🔵 Niedrig |
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
| **Status** | ⬜ offen |
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
- [ ] **28.1** `_sema_isKernelForbidden()` auf Allowlist-Ansatz für `std.net.*` umstellen
- [ ] **28.2** `std.fs.*`, `std.thread.*`, `std.os.*`, `std.io.*` bleiben als Prefix-Blockliste
- [ ] **28.3** Tests: `std.net.epoll` mit `--target=lyxos-kernel` → Fehler; `std.net.eth` → OK

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
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (H-3) |

**Problem:** `Host` und `Path` werden bereits auf CRLF geprüft (Z. 147–149), aber `req.headers` (benutzerdefinierte Header) wird ohne jede Validierung direkt in den Request-Buffer geschrieben. Ein Angreifer mit Kontrolle über `req.headers` kann beliebige HTTP-Header injizieren — inkl. `\r\nTransfer-Encoding: chunked\r\n`, Body-Injection und Request-Smuggling.

**Fix:**
```
if (req.headers != 0) {
    if http_hasCrLf(req.headers, StrLen(req.headers)) != 0 { return 0; }
    var hlen: int64 := StrLen(req.headers);
    p := http_writeMem(p, req.headers, hlen);
}
```

**Teilschritte:**
- [ ] **30.1** CRLF-Check für `req.headers` in `std/net/http.lyx`
- [ ] **30.2** Fehlercode bei CRLF-Injektion dokumentieren
- [ ] **30.3** Test: Header mit `\r\n` → Fehler; normaler Header → OK

---

## WP-31: Dateigrößen-Limit (DoS-Schutz) 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/std/io.lyx` Z. 477–498; `src/sema.lyx` Z. 754–758 |
| **Priorität** | 🟠 Hoch |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (H-4) |

**Problem:** `FileReadAll` und `_sema_readFile` lesen Dateien ohne Größenlimit. Eine 4-GB-Eingabedatei (oder ein 4-GB-`.lyu`-File) erschöpft den Systemspeicher → OOM-Kill. Da `alloc()` unbegrenzt wächst, kann ein Angreifer mit einer präparierten Datei alle anderen Prozesse auf dem System killen.

**Fix:**
```
// src/std/io.lyx und src/sema.lyx
var size: int64 := lseek(fd, 0, 2);
if size > 256 * 1024 * 1024 {   // max 256 MB
    close(fd);
    return 0 as pchar;
}
```

**Teilschritte:**
- [ ] **31.1** Limit in `FileReadAll` (`src/std/io.lyx`)
- [ ] **31.2** Limit in `_sema_readFile` (`src/sema.lyx`)
- [ ] **31.3** Fehlermeldung bei überschrittenem Limit ausgeben (nicht lautlos 0 zurückgeben)

---

## WP-32: TOCTOU in `ms_appendMetaSafe` 🟠

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx` Z. 207–314 |
| **Priorität** | 🟠 Hoch |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (H-5) |

**Problem:** `ms_appendMetaSafe` öffnet die Output-Binary mit `O_RDONLY`, liest sie, schließt den FD, berechnet Hashes, öffnet sie dann neu mit `O_WRONLY|O_CREAT|O_TRUNC` und überschreibt sie. In diesem Zeitfenster kann ein anderer Prozess die Datei durch eine präparierte Version ersetzen (Symlink-Attack, Race Condition). Der Compiler würde dann die manipulierte Binary mit einem gültigen Sicherheits-Header stempeln.

**Fix:** Datei mit `O_RDWR` in einem einzigen `open()`-Aufruf öffnen, in-place modifizieren. Alternativ: Schreiben in Temp-File + atomares `rename()`.

**Teilschritte:**
- [ ] **32.1** `O_RDONLY` + schließen + `O_WRONLY` → durch `O_RDWR` in einem `open()` ersetzen
- [ ] **32.2** In-place-Schreiblogik anpassen (kein erneutes `open`)
- [ ] **32.3** Test: Race-Condition-Szenario prüfen

---

## WP-33: String-Library Bounds-Hardening 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/std/string.lyx` Z. 218, 232–242, 290–302; `src/sema.lyx` Z. 893 |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (M-1, M-2, M-3, L-2) |

**Probleme:**

1. **`StrLen(0)` → SIGSEGV** — Kein Null-Pointer-Guard. Fix: `if ptr == 0 { return 0; }`.

2. **`StrCopy` Off-by-One** (Z. 232) — `while i <= srcLen` liest 1 Byte über das Source-Array-Ende. Fix: `while i < srcLen` + explizites `poke8(dest + srcLen, 0)`.

3. **`StrSubstr` ohne Bounds-Prüfung** (Z. 290) — `start + len > srcLen` → OOB-Read. Fix: `if start < 0 || len < 0 || start + len > srcLen { return 0 as pchar; }`.

4. **`_sema_processImport` modLen==1 OOB** (sema.lyx Z. 893) — `while wptd < modLen - 1` liest bei `modLen == 1` ein Byte jenseits des Modulnamens. Fix: `while wptd + 1 < modLen`.

**Teilschritte:**
- [ ] **33.1** `StrLen`: Null-Pointer-Guard
- [ ] **33.2** `StrCopy`: Off-by-One korrigieren
- [ ] **33.3** `StrSubstr`: Bounds-Check
- [ ] **33.4** `_sema_processImport`: Loop-Bedingung korrigieren (identischer Bug auch in `codegen_x86.lyx`)

---

## WP-34: Codegen-Buffer-Größenlimit 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` Z. 627–632 |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (M-5) |

**Problem:** Der Code-Output-Buffer beginnt mit 65 536 Bytes und verdoppelt sich unbegrenzt. Eine crafted große Eingabedatei (z. B. eine Million inline-Assemblerwerte) kann den Buffer auf mehrere GB wachsen lassen → OOM.

**Fix:**
```
con MAX_CODE_SIZE: int64 := 512 * 1024 * 1024;  // 512 MB
...
if nc > MAX_CODE_SIZE {
    EPrintStrLn("error: code output exceeds 512 MB limit"c);
    return;
}
```

**Teilschritte:**
- [ ] **34.1** `MAX_CODE_SIZE`-Konstante definieren und Wachstums-Check einbauen
- [ ] **34.2** Fehlermeldung + sauberer Abbruch

---

## WP-35: LYU-Parser `symCount`-Limit 🟡

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx` Z. 798 |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (M-6) |

**Problem:** `symCount` wird aus einer `.lyu`-Datei gelesen ohne obere Schranke. Eine crafted `.lyu`-Datei mit `symCount = 0x7FFFFFFF` und gültigem Format treibt das Symboltabellen-Wachstum ins Extreme (jeder `_pushSym`-Aufruf verdoppelt bei Bedarf den Puffer).

**Fix:**
```
if symCount > 65536 {
    EPrintStr("sema error: .lyu symCount unreasonably large: "c);
    return;
}
```

**Teilschritte:**
- [ ] **35.1** Limit-Check nach dem Lesen von `symCount`
- [ ] **35.2** Test: crafted `.lyu` mit `symCount = 100000` → Fehler

---

## WP-36: `SecureZero()` Compiler-Barriere 🔵

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/crypto/ct.lyx` Z. 80–84 |
| **Priorität** | 🔵 Niedrig |
| **Status** | ⬜ offen |
| **Quelle** | Security-Audit 2026-06-18 (I-1) |

**Problem:** `SecureZero()` nutzt eine `poke8`-Schleife ohne Compiler-Barriere. Ein aggressiver Optimizer könnte Dead-Store-Elimination anwenden und die Schleife komplett entfernen. `lic_zeroSecret()` nutzt korrekt `explicit_bzero()` (nicht wegoptimierbar), aber `SecureZero()` in `std/crypto/ct.lyx` tut das nicht.

**Fix:** `SecureZero()` auf `explicit_bzero` (Syscall-basiert oder Memory-Barrier) umstellen, oder eine `volatile`-äquivalente Schreibsequenz verwenden, die der Lyx-Codegen nicht eliminiert.

**Teilschritte:**
- [ ] **36.1** Prüfen ob Lyx-Codegen Dead-Store-Elimination für `poke8` macht
- [ ] **36.2** Falls ja: `explicit_bzero`-Binding nutzen

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
| **36** | **SecureZero() Compiler-Barriere** | **⬜** | – | 🔵 |
| **37** | **RandInt64() Fehlerbehandlung** | **⬜** | – | 🔵 |
