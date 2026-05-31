# `mmap`-Vereinfachung — Fahrplan

**Konvention:** WP-MEM-NN · Status: ✅ Erledigt · 🔄 In Arbeit · ⬜ Offen

---

## Problem

`mmap` ist ein Compiler-Builtin (Syscall 9). Von seinen 6 Parametern sind 5
fast immer gleich — nur `size` variiert. Trotzdem tauchen die magischen Zahlen
`3, 34, -1, 0` im gesamten Codebase auf:

```lyx
var buf: int64 := mmap(0, size, 3, 34, -1, 0);
//                          ^   ^   ^  ^  ^
//                          |   |   |  |  Offset (immer 0)
//                          |   |   |  fd (immer -1 = anonym)
//                          |   |   Flags (immer MAP_PRIVATE|MAP_ANON)
//                          |   Prot (immer PROT_READ|PROT_WRITE)
//                          Größe (einzige Variable)
```

**Umfang des Problems:**

| Bereich | Stellen |
|---------|---------|
| `std/*.lyx` | ~778 |
| `src/*.lyx` (Compiler) | ~778* |
| `tests/` + `examples/` | ~392 |
| **Gesamt** | **~1170** |

*inkl. `src/std/*.lyx`

Top-Betroffene: `db/postgres.lyx` (59), `net/quic.lyx` (58),
`src/codegen_x86.lyx` (75), `src/lyxc.lyx` (33).

---

## Gewählter Ansatz: Zweistufen-Plan

### Stufe 1 — Stdlib-Wrapper (Option A)

Wrapper-Funktionen in `std/alloc.lyx`. Kein Compiler-Aufwand, sofort nutzbar.
Aus `mmap(0, size, 3, 34, -1, 0)` wird `alloc(size)`.

### Stufe 2 — Default-Parameter (Option C)

Default-Parameter als echtes Sprachfeature, damit auch `mmap` direkt mit weniger
Argumenten aufrufbar wird (`mmap(size: 4096)`). Nützt auch anderen Builtins
(`open`, `connect`, etc.).

---

## Stufe 1 — Stdlib-Wrapper

---

### WP-MEM-01: `alloc`/`free` in `std/alloc.lyx` ⬜

**Ziel:** Benannte Konstanten und Wrapper-Funktionen für den Standard-Fall
definieren. Das macht `std/alloc.lyx` zur zentralen Speicher-Abstraktion.

**Aktuelle Situation:** `std/alloc.lyx` existiert, nutzt aber `extern fn libc_malloc/free`
(libc-Bindung). Die neuen Funktionen nutzen direkt `mmap`/`munmap` — kein libc.

**Zu implementieren:**

```lyx
// Konstanten
pub con MMAP_PROT_NONE: int64 := 0;   // kein Zugriff
pub con MMAP_PROT_RW:   int64 := 3;   // PROT_READ | PROT_WRITE
pub con MMAP_PROT_RX:   int64 := 5;   // PROT_READ | PROT_EXEC
pub con MMAP_PROT_RWX:  int64 := 7;   // PROT_READ | PROT_WRITE | PROT_EXEC

pub con MMAP_ANON:       int64 := 34;  // MAP_PRIVATE | MAP_ANONYMOUS
pub con MMAP_SHARED:     int64 := 1;   // MAP_SHARED (für File-mmap)

// Anonymer Heap-Speicher (= der 90%-Fall)
pub fn alloc(size: int64): int64 {
  return mmap(0, size, MMAP_PROT_RW, MMAP_ANON, -1, 0);
}

// Alias — mmap ist bereits zero-initialisiert bei MAP_ANONYMOUS
pub fn allocZeroed(size: int64): int64 {
  return alloc(size);
}

// Freigabe
pub fn free(ptr: int64, size: int64): void {
  munmap(ptr, size);
}
```

**Akzeptanzkriterien:**
- `alloc(4096)` gibt validen Zeiger zurück, Inhalt ist 0
- `free(ptr, 4096)` gibt Speicher zurück ohne Crash
- `--compile-unit std/alloc.lyx` läuft fehlerfrei

---

### WP-MEM-02: Migration `std/*.lyx` ⬜

**Ziel:** Alle `mmap(0, ..., 3, 34, -1, 0)` und `munmap(...)` in den
Standard-Library-Units durch `alloc`/`free` ersetzen.

**Voraussetzung:** WP-MEM-01

**Priorisierung nach Trefferdichte:**

| Datei | Stellen | Prio |
|-------|---------|------|
| `db/postgres.lyx` | 59 | 🔴 |
| `net/quic.lyx` | 58 | 🔴 |
| `db/redis.lyx` | 35 | 🔴 |
| `db/mysql.lyx` | 31 | 🔴 |
| `pdf/builder.lyx` | 22 | 🟠 |
| `svg/*.lyx` (3 Dateien) | ~23 | 🟠 |
| `fs.lyx` | 10 | 🟡 |
| `hash.lyx`, `thread.lyx`, `os.lyx`, `ini.lyx` | je ~7 | 🟡 |
| restliche std-Units | Restmenge | 🟢 |

**Vorgehen:**
1. `import std.alloc` am Anfang jeder betroffenen Unit eintragen
2. `mmap(0, X, 3, 34, -1, 0)` → `alloc(X)`
3. `munmap(ptr, size)` → `free(ptr, size)`
4. Nur die Fälle mit fixen `3, 34, -1, 0` ersetzen — File-mmap (andere Parameter)
   bleibt als rohes `mmap`
5. Pro Unit neu precompilieren: `./lyxc --compile-unit std/foo.lyx -o ...`

**Akzeptanzkriterien:**
- Alle betroffenen `.lyu`-Dateien kompilieren ohne Fehler
- Snapshot-Tests und pg-Integrationstests bestanden
- Keine `mmap(0, ..., 3, 34, -1, 0)` mehr in `std/` (grep liefert 0 Treffer)

---

### WP-MEM-03: Migration `src/*.lyx` (Compiler-Quellcode) ⬜

**Ziel:** Auch im selbst-gehosteten Compiler die magischen Zahlen eliminieren.

**Voraussetzung:** WP-MEM-01 (analog: `src/std/alloc.lyx` oder inline-Wrapper)

**Besonderheit:** Der Compiler importiert `src.std.io` und `src.std.fs`, nicht
`std.alloc`. Daher entweder:
- Option A: `alloc`/`free` zu `src/std/io.lyx` hinzufügen (bereits importiert)
- Option B: Eigenes `src/std/alloc.lyx` anlegen (analog zu WP-MEM-01)

**Priorisierung:**

| Datei | Stellen |
|-------|---------|
| `src/codegen_x86.lyx` | 75 |
| `src/lyxc.lyx` | 33 |
| `src/ir_lower.lyx` | 21 |
| `src/sema.lyx` | 19 |
| `src/std/io.lyx` | 13 |
| `src/backend/arm64/emit_arm64.lyx` | 13 |
| restliche src-Dateien | Restmenge |

**Nach jeder Änderung:** `make singularity` muss S3==S4 bestätigen.

**Akzeptanzkriterien:**
- `make singularity`: S3 == S4 ✅
- Keine `mmap(0, ..., 3, 34, -1, 0)` mehr in `src/` (grep liefert 0 Treffer)
- `make test` grün

---

### WP-MEM-04: Migration `tests/` und `examples/` ⬜

**Ziel:** Auch User-facing Code bereinigen — ein gutes Vorbild für Entwickler.

**Voraussetzung:** WP-MEM-01

**Vorgehen:** Skript-basiert (sed oder Python), da ~392 Stellen.
Danach Regression-Tests laufen lassen.

**Akzeptanzkriterien:**
- Snapshot-Tests alle grün
- Keine `mmap(0, ..., 3, 34, -1, 0)` in `tests/` und `examples/`

---

## Stufe 2 — Default-Parameter (Sprachfeature)

---

### WP-MEM-05: Default-Parameter im Lyx-Parser ⬜

**Ziel:** Funktionen können Parameter mit Default-Werten deklarieren.
Nicht übergebene Argumente werden durch den Default-Wert ersetzt.

**Syntax:**
```lyx
fn connect(host: pchar, port: int64 = 443, tls: bool = true): int64 { ... }

// Aufruf ohne Defaults:
connect("example.com", 443, true)
// Gleichwertig:
connect("example.com")
```

**Anwendung auf mmap:**
```lyx
// Compiler-Builtin-Deklaration (intern):
fn mmap(addr: int64 = 0, len: int64, prot: int64 = 3, flags: int64 = 34,
        fd: int64 = -1, offset: int64 = 0): int64

// Dann reicht:
mmap(4096)              // anonym, RW, Standard-Fall
mmap(0, fileSize, 3, 1, fd, 0)  // File-mmap (explizit)
```

**Zu implementieren:**

| Schritt | Datei | Beschreibung |
|---------|-------|-------------|
| Parser | `src/parser.lyx` | `= expr` nach Parametertyp parsen, in AST speichern |
| Sema | `src/sema.lyx` | Default-Ausdrücke auswerten, fehlende Args auffüllen |
| IR-Lowering | `src/ir_lower.lyx` | Default-Werte als normale Argumente behandeln |
| Codegen | `src/codegen_x86.lyx` | Builtins mit Default-Deklaration erweitern |
| EBNF | `ebnf.md` | Grammatik aktualisieren |

**Herausforderungen:**
- Default-Ausdrücke müssen zur Compile-Zeit auswertbar sein (Konstanten, Literale)
- Positionelle Argumente müssen weiterhin funktionieren
- Named Arguments (`fn(port: 8080)`) wären ideal, aber erheblicher Mehraufwand

**Akzeptanzkriterien:**
- `fn foo(x: int64 = 42): int64 { return x; }` → `foo()` ergibt 42
- `mmap(size: 4096)` funktioniert als Kurzform
- Singularität S3==S4 nach Compiler-Änderung

---

## Meilensteine

| Meilenstein | WPs | Ergebnis |
|-------------|-----|----------|
| M1: Wrapper verfügbar | MEM-01 | `alloc`/`free` in std/alloc.lyx nutzbar |
| M2: Stdlib sauber | MEM-01, MEM-02 | Keine magischen Zahlen in std/ |
| M3: Compiler sauber | MEM-03 | Keine magischen Zahlen in src/ |
| M4: Vollständig sauber | MEM-04 | Kein `mmap(0,...,3,34,-1,0)` im gesamten Repo |
| M5: Sprachfeature | MEM-05 | Default-Parameter, `mmap(size)` als Kurzform |

---

## Offene Fragen

| # | Frage | Empfehlung |
|---|-------|-----------|
| 1 | `alloc`/`free` in `std/alloc.lyx` oder neues `std/mem.lyx`? | `std/alloc.lyx` — existiert bereits, passt thematisch |
| 2 | Soll `libc_malloc` aus `std/alloc.lyx` entfernt werden? | Nein — behalten für Kompatibilität, aber als deprecated kennzeichnen |
| 3 | Sollen Named Arguments (WP-MEM-05) sofort mitimplementiert werden? | Optional — Default-Werte allein bringen schon den Mehrwert |
| 4 | Migration per Skript oder manuell? | Skript (sed/grep) für WP-02/04, manuell für WP-03 (Compiler braucht Singularität) |
