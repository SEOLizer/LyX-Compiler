# ToDo: Defekte und unvollständige std/-Units

Stand: 2026-05-24  
Alle 115 `.lyx`-Dateien sind kompiliert (`.lyu` vorhanden). Die Fehler liegen im Quellcode.

---

## Status-Übersicht

| # | Datei | Schwere | Status | PR / Branch |
|---|-------|---------|--------|-------------|
| FIX-01 | `std/thread.lyx` | Kritisch | ✅ Erledigt | WP-STB-07 |
| FIX-02 | `std/alloc.lyx` | Kritisch | ✅ Erledigt | #471 |
| FIX-03 | `std/ml.lyx` | Kritisch | ✅ Erledigt | #474 |
| FIX-04 | `std/datetime.lyx` | Major | ✅ Erledigt | WP-STB-01 |
| FIX-05 | `std/yaml.lyx` | Major | ✅ Erledigt | #475 |
| FIX-06 | `std/net/quic.lyx` | Major | ✅ Erledigt | WP-STB-11 |
| FIX-07 | `std/os.lyx` | Moderat | ✅ Erledigt | #473 |
| FIX-08 | `std/fs.lyx` | Moderat | ✅ Erledigt | #472 |
| FIX-09 | `std/process.lyx` | Minor | ✅ Erledigt | — |
| FIX-10 | `std/os.lyx` | Minor | ✅ Erledigt | — |

---

## Priorität 1 — Kritisch

---

### ✅ FIX-01 — `std/thread.lyx`: Threading komplett nicht-funktional

**Erledigt in WP-STB-07.**  
Echte Implementierung via `clone(2)` + `futex(2)`: `ThreadCreate` nutzt `sys_clone` mit `CLONE_VM|CLONE_THREAD|…`, `MutexLock`/`MutexUnlock` nutzen `FUTEX_WAIT`/`FUTEX_WAKE`, `AtomicAdd`/`CAS` implementiert, TLS via mmap-Tabelle.

---

### ✅ FIX-02 — `std/alloc.lyx`: `calloc` initialisiert nicht auf Null

**Erledigt in PR #471.**  
`poke8`-Zero-Init-Loop nach `malloc` eingefügt:
```lyx
var i: int64 := 0;
while (i < total_size) {
    poke8(ptr + i, 0);
    i := i + 1;
}
```

---

### ✅ FIX-03 — `std/ml.lyx`: `LogF64` gibt immer 0.0 zurück

**Erledigt in PR #474.**  
Implementiert via Argumentreduktion auf `m ∈ [0.5, 2.0)` + `ln(m) = 2·arctanh(t)`, `t = (m−1)/(m+1)`, Taylor-Reihe mit 10 Termen (~1e-11 Fehler). Kein `libm`, kein Bit-Casting.

---

## Priorität 2 — Major

---

### ✅ FIX-04 — `std/datetime.lyx`: 22 Funktionen mit `return 0; // TODO`

**Erledigt in WP-STB-01.**  
Alle 22 Datetime-Funktionen implementiert (`Format`, `Parse*`, `Add*`, `Diff*`, `ToUnixTime`, `FromUnixTime`, etc.).

---

### ✅ FIX-05 — `std/yaml.lyx`: Fast vollständig unimplementiert

**Erledigt in PR #475.**  
Implementiert (flat top-level key-value Modell, doc = raw mmap-Textpuffer):

| Funktion | Implementierung |
|----------|----------------|
| `ParseYamlFloat` | Per-digit `int64 as f64` Skalierung |
| `GetFloat` | `GetString` + `ParseYamlFloat` |
| `HasPath` | `_yamlFindKey >= 0` |
| `GetType` | Erstes Wertzeichen → BOOL/INT/FLOAT/STRING/NULL |
| `SetString` | `_yamlSetKey` (privater Zeilenrebuild-Helper) |
| `SetInt` | `IntToStr` + `_yamlSetKey` |
| `SetFloat` | mmap-Scratch + `f64 as int64` Ziffernextraktion |
| `SetBool` | `"true"` / `"false"` + `_yamlSetKey` |
| `DeleteKey` | Wie `_yamlSetKey`, überspringt passende Zeile |
| `GetKeys` | Scan aller nicht-eingerückten Doppelpunkt-Zeilen |
| `GetArrayLen` | Zählt eingerückte `- ` Zeilen nach dem Key |

Verbleibende Stubs (brauchen YAML-AST): `GetArray`, `GetObject`, `SetArray`, `SetObject`.

---

### ✅ FIX-06 — `std/net/quic.lyx`: TLS-Handshake und Datentransfer implementiert

**Erledigt in WP-STB-11.**

Vollständiger Crypto-Stack implementiert (kein libm, kein libc-Crypto, alle Funktionen ≤ 6 Argumente):

| Komponente | Implementierung |
|------------|----------------|
| SHA-256 | 64-Runden-Kompression, Big-Endian-Padding, 32-Bit-Maskierung |
| HMAC-SHA256 | Inner/Outer-Hash per RFC 2104 |
| HKDF | Extract + Expand-Label per RFC 5869 / TLS 1.3 |
| AES-128 | Algorithmische S-Box aus GF(2⁸) exp/log-Tabellen; Key-Expand; Encrypt |
| AES-128-GCM | CTR-Verschlüsselung + GHASH-Tag; GF(2¹²⁸)-Multiplikation bitweise |
| QUIC Initial Keys | DCID → initial_secret → client_in → key/iv/hp (RFC 9001 §5.2) |
| `QUICConnect` | Leitet Keys ab, sendet verschlüsseltes 1200-Byte Initial-Paket mit Header-Protection |
| `QUICStreamWrite` | AEAD-Short-Header-Paket via UDP sendto |
| `QUICStreamRead` | UDP-Empfang + CTR-Entschlüsselung + STREAM-Frame-Parse |
| `QUICCloseStream` | Verschlüsselter RESET_STREAM-Frame |

---

## Priorität 3 — Moderat

---

### ✅ FIX-07 — `std/os.lyx`: Mehrere Funktionen liefern falsche Werte

**Erledigt in PR #473.**

| Funktion | Fix |
|----------|-----|
| `sleep` / `sleep_seconds` / `sleep_microseconds` | `nanosleep(2)` statt Spin-Loop (mmap 16-Byte `timespec`) |
| `get_cwd()` | mmap 4096-Byte Buffer + `getcwd(2)` |
| `get_num_cores()` | `SC_NPROCESSORS_ONLN` (84) statt `SC_CLK_TCK` (2) |
| `get_total_memory_mb()` | `/proc/meminfo` Parser via `_readMemInfoKB` Helper |
| `get_available_memory_mb()` | `/proc/meminfo` Parser via `_readMemInfoKB` Helper |

---

### ✅ FIX-08 — `std/fs.lyx`: `PutChar` schreibt immer Space

**Erledigt in PR #472.**  
`mmap(8) + poke8(chbuf, c) + write(STDOUT_FILENO, chbuf, 1) + munmap` ersetzt den Leerzeichen-Workaround.

---

## Priorität 4 — Minor

---

### ✅ FIX-09 — `std/process.lyx`: `spawn`/`run` verschlucken execve-Fehler

**Erledigt** (bereits in aktuellem `main`).  
Child ruft `os_exit(127)` nach fehlgeschlagenem `execve` auf (Unix-Konvention).

---

### ✅ FIX-10 — `std/os.lyx`: `exec()` enthält Debug-`PrintStr`-Aufrufe

**Erledigt** (bereits in aktuellem `main`).  
Keine Debug-Ausgaben mehr in `exec()`.
