# ToDo: Defekte und unvollständige std/-Units

Stand: 2026-05-21  
Alle 115 `.lyx`-Dateien sind kompiliert (`.lyu` vorhanden). Die Fehler liegen im Quellcode.

---

## Priorität 1 — Kritisch (falsche Semantik, silent failures)

---

### FIX-01 — `std/thread.lyx`: Threading komplett nicht-funktional

Die gesamte Threading-Unit ist ein Skeleton ohne reale Implementierung.

| Funktion | Problem |
|----------|---------|
| `ThreadCreate` | Ruft `sys_fork()`, das Child macht sofort `_exit(0)` – der übergebene Funktionszeiger wird **nie aufgerufen** |
| `MutexLock` | No-Op: `if (mutex.lock == 0) return 0;` – kein echtes Locking |
| `MutexUnlock` | No-Op: analoges Stub-Body |
| `CondWait` | Stub: prüft `cond.signal == 0`, wartet nie wirklich |
| `CondSignal` | Stub: signalisiert nichts, ruft `pthread_cond_signal` nie auf |
| `TLSKeyCreate` | Gibt hartcodierten Wert 0 zurück, ruft `pthread_key_create` nie auf |
| `TLSSetValue` | Gibt 0 zurück, ruft `pthread_setspecific` nie auf |
| `TLSGetValue` | Gibt 0 zurück, ruft `pthread_getspecific` nie auf |
| `AtomicAdd` | Kein `lock`-Präfix – Race-Condition bei parallelen Zugriffen |
| `CAS` | Kein `lock cmpxchg` – nicht atomar |

**Fix (nativ, ohne libpthread):**
- `ThreadCreate`: Linux-Syscall `clone(CLONE_VM | CLONE_SIGHAND | CLONE_THREAD | CLONE_FS | CLONE_FILES, stack_top, ...)` direkt aufrufen. Damit teilen sich Parent und Child denselben Adressraum – der Funktionszeiger kann direkt gesprungen werden. Stack-Speicher via `mmap` bereitstellen.
- `MutexLock / MutexUnlock`: Linux `futex`-Syscall (Nr. 202) mit `FUTEX_WAIT` / `FUTEX_WAKE`. Ein `int64`-Feld im Mutex-Struct als Zähler (`0` = frei, `1` = belegt). Kein pthread nötig.
- `AtomicAdd / CAS`: x86-64-Inline-Bytes via `poke8` auf den Code-Buffer oder Nutzung des `lock xadd` / `lock cmpxchg`-Patterns falls der Compiler das unterstützt; alternativ kurzfristig per Mutex absichern.
- Die bereits deklarierten `pthread_*`-Externals können entfernt werden sobald die native Implementierung steht.

---

### FIX-02 — `std/alloc.lyx`: `calloc` initialisiert nicht auf Null

```lyx
pub fn calloc(count: int64, elem_size: int64): int64 {
  var total_size: int64 := count * elem_size;
  var ptr: int64 := malloc(total_size);
  // ← kein memset/bzero!
  return ptr;
}
```

`calloc` garantiert per Definition null-initialierten Speicher. Wer sich darauf verlässt (z.B. bei Struct-Initialisierung) bekommt Garbage.

**Fix:** Nach `malloc` einen manuellen Null-Init-Loop mit `poke8` einfügen – kein `memset`-Extern nötig:
```lyx
var i: int64 := 0;
while (i < total_size) {
    poke8(ptr + i, 0);
    i := i + 1;
}
```

---

### FIX-03 — `std/ml.lyx`: `LogF64` gibt immer 0.0 zurück

```lyx
pub fn LogF64(x: f64): f64 {
  if (x <= 0.0) { var lf_n100: f64 := 0.0 - 100.0; return lf_n100; }
  return 0.0;   // ← ln(x) für x > 0 nicht implementiert
}
```

Alle ML-Algorithmen die `LogF64` für echte Berechnungen nutzen (Naive Bayes, Logistic Regression) liefern dadurch falsche Ergebnisse. `NBLog` im selben File arbeitet mit einer Lookup-Annäherung für Werte ∈ (0,1) und kann als Vorlage dienen.

**Fix (nativ):** Identität `ln(x) = 2 · arctanh((x-1)/(x+1))` mit Taylor-Reihe für arctanh implementieren. Für `x > 1` Argument via `ln(x) = ln(m · 2^e) = ln(m) + e·ln(2)` auf den Bereich `[0.5, 1.0]` reduzieren (Mantisse/Exponent-Zerlegung). `ln(2)` als Konstante (≈ 0.693147...) hartcodieren. Kein `libm`-Extern.

---

## Priorität 2 — Major (Funktionen existieren, tun aber nichts)

---

### FIX-04 — `std/datetime.lyx`: 22 Funktionen mit `return 0; // TODO: Implement`

Vollständig unimplementiert (alle geben 0 zurück):

```
Format          FormatIso        FormatRfc2822    FormatLocale
ParseDate       ParseTime        ParseDatetime    ParseIso
ParseRfc2822    AddDays          AddHours         AddMinutes
AddSeconds      DiffDays         DiffHours        DiffMinutes
DiffSeconds     IsLeapYear       DaysInMonth      WeekdayOf
ToUnixTime      FromUnixTime
```

**Fix:** Schrittweise implementieren. Empfohlene Reihenfolge:
1. `ToUnixTime` / `FromUnixTime` (Basis für alles)
2. `Add*` / `Diff*` (bauen auf Unix-Time auf)
3. `Format` / `FormatIso` (häufigste Anwendungsfälle)
4. `Parse*` (komplex, nach den anderen)

---

### FIX-05 — `std/yaml.lyx`: Fast vollständig unimplementiert

Betroffene Funktionen:

| Funktion | Problem |
|----------|---------|
| `YAMLReadFile` | `// TODO: Implement when fs integration is stable` → `return 0` |
| `YAMLWriteFile` | `// TODO: Implement when fs integration is stable` → `return 0` |
| `YAMLGetString` | `return 0` – kein Wert-Lookup |
| `YAMLGetInt` | `return 0` |
| `YAMLGetFloat` | `return 0.0` |
| `YAMLParseString` | Erkennt YAML-Header, parst aber keinen Inhalt |
| `YAMLSerialize` | `return 0` |
| `YAMLQuery` | `return 0` |

**Fix:** `YAMLReadFile` freischalten sobald `std.fs` die Einschränkung (→ FIX-07) behebt. Danach Key-Value-Parser für den häufigsten YAML-Anwendungsfall (flache Maps, einfache Listen) implementieren.

---

### FIX-06 — `std/net/quic.lyx`: TLS-Handshake und Datentransfer sind Platzhalter

QUIC-Paketbau ist implementiert, die eigentliche Verbindungslogik nicht:

| Funktion | Problem |
|----------|---------|
| `QUICConnect` | Erstellt Struct, aber kein echter Handshake: `// Note: Full connection establishment requires: 1. Build TLS 1.3 ClientHello ...` |
| `QUICBuildInitialPacket` | CRYPTO-Frame leer: `// In production, this would contain the TLS 1.3 ClientHello` |
| `QUICWrite` | `// In production, this would: 1. Build STREAM frame 2. Encrypt ...` → `return 0` |
| `QUICRead` | `// In production, this would: 1. Receive UDP datagram 2. Decrypt ...` → `return 0` |
| `QUICCloseStream` | Leerer Body – sendet kein `RESET_STREAM` |

**Fix:** Vollständige QUIC-Implementierung erfordert AEAD-Verschlüsselung (AES-128-GCM / ChaCha20-Poly1305) und TLS 1.3. Kurzfristig: Abhängigkeit auf `std.net.tls` (OpenSSL hat QUIC-Support ab 3.x) evaluieren.

---

## Priorität 3 — Moderat (falsche Ergebnisse in Randfällen)

---

### FIX-07 — `std/os.lyx`: Mehrere Funktionen liefern falsche Werte

| Funktion | Problem | Fix |
|----------|---------|-----|
| `get_cwd()` | Gibt immer `""` zurück. `getcwd()` ist extern deklariert aber nie aufgerufen. | `mmap` Puffer allozieren, `getcwd(buf, size)` aufrufen, Ergebnis zurückgeben |
| `get_total_memory_mb()` | Gibt 0 zurück | `/proc/meminfo` parsen oder `sysinfo()` Syscall nutzen |
| `get_available_memory_mb()` | Gibt 0 zurück | wie oben |
| `get_num_cores()` | Ruft `sysconf(SC_CLK_TCK)` auf (= Takte/Sekunde, Wert 2) statt `sysconf(SC_NPROCESSORS_ONLN)` (= 84) | Konstante auf 84 korrigieren: `con SC_NPROCESSORS_ONLN: int64 := 84` |
| `sleep(ms)` | Spin-Loop (`while i < ms * 10000`) – frisst CPU, Timing-Präzision von CPU-Takt abhängig | `nanosleep` Syscall (Nr. 35) oder `clock_nanosleep` verwenden |

---

### FIX-08 — `std/fs.lyx`: `PutChar` schreibt immer Space statt übergebenem Zeichen

```lyx
pub fn PutChar(c: int64): int64 {
  var chbuf: pchar := " ";
  // chbuf[0] = c;  // TODO: Array-Index-Zuweisung in Lyx
  return write(STDOUT_FILENO, chbuf, 1);
}
```

Ursache: Lyx kann aktuell keinen Index-Schreib-Zugriff auf `pchar` ausführen. Das Zeichen `c` wird ignoriert, stattdessen immer ein Leerzeichen geschrieben.

**Fix:** Mit `poke8` umschreiben sobald die Sprachfähigkeit verfügbar ist:
```lyx
var chbuf: int64 := mmap(0, 8, 3, 34, -1, 0);
poke8(chbuf, c);
var ret: int64 := write(STDOUT_FILENO, chbuf, 1);
munmap(chbuf, 8);
return ret;
```

---

## Priorität 4 — Minor (Semantik-Abweichungen, kein Absturz)

---

### FIX-09 — `std/process.lyx`: `spawn`/`run` verschlucken execve-Fehler

```lyx
pub fn spawn(prog: pchar): Process {
  var pid: int64 := fork();
  if (pid == 0) {
    execve(prog, prog, 0);
    return -1;   // Child gibt -1 zurück – aber Parent wartet nicht auf diesen Exit
  }
  return pid;   // Parent sieht PID, nicht ob execve scheiterte
}
```

Wenn `execve` fehlschlägt (Programm nicht gefunden), lebt der Child-Prozess weiter und gibt -1 zurück, aber der Parent bekommt eine scheinbar valide PID. Der Child wird nie zu einem Zombie weil der Parent keine `waitpid`-Pflicht hat – aber `try_wait` könnte fälschlich "läuft noch" melden.

**Fix:** Im Child nach `execve`-Fehler `_exit(127)` aufrufen (Unix-Konvention für "command not found"). Im Parent kurz `try_wait` nach dem Fork prüfen ob das Child sofort mit 127 exited.

---

### FIX-10 — `std/os.lyx`: `exec()` enthält Debug-`PrintStr`-Aufrufe

```lyx
pub fn exec(...): int64 {
  PrintStr("exec:A\n");      // ← Debug-Output in Produktionscode
  PrintStr("exec:B argv=");
  PrintInt(argv);
  ...
}
```

Jeder `exec()`-Aufruf gibt Debug-Zeilen auf stdout aus.

**Fix:** `PrintStr`/`PrintInt`-Aufrufe entfernen.

---

## Zusammenfassung

| # | Datei | Schwere | Kurzbeschreibung |
|---|-------|---------|-----------------|
| FIX-01 | `std/thread.lyx` | Kritisch | Threading komplett non-funktional (Fork ohne Callback, No-Op-Mutexe) |
| FIX-02 | `std/alloc.lyx` | Kritisch | `calloc` initialisiert nicht auf Null |
| FIX-03 | `std/ml.lyx` | Kritisch | `LogF64` gibt immer 0.0 zurück |
| FIX-04 | `std/datetime.lyx` | Major | 22 Funktionen mit `return 0; // TODO` |
| FIX-05 | `std/yaml.lyx` | Major | Fast vollständig unimplementiert |
| FIX-06 | `std/net/quic.lyx` | Major | TLS-Handshake und Datentransfer nur Platzhalter |
| FIX-07 | `std/os.lyx` | Moderat | `get_cwd`, `get_*_memory_mb`, `get_num_cores` (falscher Const), `sleep` (Spin-Loop) |
| FIX-08 | `std/fs.lyx` | Moderat | `PutChar` schreibt immer Space |
| FIX-09 | `std/process.lyx` | Minor | `spawn`/`run` können execve-Fehler nicht von fork-Fehler unterscheiden |
| FIX-10 | `std/os.lyx` | Minor | Debug-`PrintStr` in `exec()` nicht entfernt |
