# Sicherheits-Fahrplan — Aurum/Lyx (Offene Punkte)

> Letzte Aktualisierung: 2026-06-13  
> Status: ⬜ offen | 🔄 in Arbeit

Von ursprünglich 25 WPs sind **20 abgeschlossen**. Diese Datei enthält nur noch die offenen Punkte.

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
