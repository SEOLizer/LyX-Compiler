# Aurum — Offene Arbeitspakete

> Stand: 2026-06-09. Nur noch offene Punkte; erledigte WPs sind entfernt.

---

## Übersicht

| WP | Titel | Prio | Offen |
|----|-------|------|-------|
| WP-02 | macOS x86_64 — Closures | Hoch | Upvalue-Capture (VMT + DynArray erledigt) |
| WP-08 | Windows ARM64 — Printf Formatstrings | Mittel | %s / %d / %f (PrintFloat erledigt) |
| WP-09 | Windows ARM64 VMT — Hardware-Verifikation | Mittel | Hardware-Lauf ausstehend |
| WP-13 | Inspect Debug-Visualizer — ARM64 + Windows ARM64 | Niedrig | Nicht implementiert |

---

## WP-02 · macOS x86_64 — Closures

**Priorität:** Hoch

**Was bereits erledigt ist**
VMT-Dispatch (PR #693: `mxb_patchVMTAddrs`) und DynArray (`push`, `pop`, `len`, `free` mit macOS mmap-Flags) sind vollständig implementiert und getestet.

**Aufgabe**
Closures mit Upvalue-Capture für macOS x86_64: eine innere Funktion soll eine Variable aus dem umgebenden Frame lesen und schreiben können.

**Kontext**
Der aktuelle Test `tests/wp02_macos_closures.lyx` enthält den Hinweis *"Closures with upvalue capture require further compiler work (sema gap)"*. Das bedeutet: der IR-Lowering-Schritt erzeugt keinen Static-Link-Zeiger und kein Upvalue-Frame-Layout. Dateien: `src/sema.lyx`, `src/ir_lower.lyx`, `src/codegen_x86.lyx` (macOS-Pfad via Codegen ist identisch zu Linux, da die macOS-Binary verbatim-kopiert wird).

| Schritt | Datei | Änderung |
|---------|-------|----------|
| 1 | `src/sema.lyx` | Upvalue-Variablen in inneren Funktionen markieren; Static-Link-Slot im Frame reservieren |
| 2 | `src/ir_lower.lyx` | `IRO_LOAD_UPVAL` / `IRO_STORE_UPVAL` Instruktionen emittieren; Static-Link als versteckten ersten Parameter weitergeben |
| 3 | `src/codegen_x86.lyx` | Static-Link via `rdi`/Stack-Slot laden; Upvalue-Loads/Stores über Frame-Pointer der Elternfunktion |

**Nutzen**
Closures sind Voraussetzung für funktionale Idiome: `map`, `filter`, `forEach` mit Lambda-Syntax. Ohne Upvalue-Capture müssen alle Variablen als Parameter durchgereicht werden.

**Abnahme**
```lyx
fn makeCounter(): fn(): int64 {
  var n: int64 := 0;
  return fn(): int64 { n := n + 1; return n; };
}
var c := makeCounter();
c(); c(); var v := c();  // v == 3
```
Kompiliert und gibt `3` auf macOS x86_64 aus. Bestehende VMT- und DynArray-Tests bleiben grün.

---

## WP-08 · Windows ARM64 — Printf Formatstrings

**Priorität:** Mittel

**Was bereits erledigt ist**
`PrintFloat(f64)` ist implementiert (PR #701): `wab_emitPrintfHelper` (100 Bytes) in `src/backend/win_arm64.lyx` zerlegt eine `f64` über Integer-Arithmetik in Vor- und Nachkommateil und gibt beide via `wab_printint`/`wab_printstr` aus. `USER32.DLL`/`wsprintfA` ist im IAT gelinkt.

**Aufgabe**
Vollständige Formatstring-Funktion `Printf(fmt, ...)` mit den Spezifizierern `%s`, `%d` und `%f` für Windows ARM64 implementieren, intern via `wsprintfA`.

**Kontext**
`wsprintfA` ist eine `cdecl`-Funktion in `USER32.DLL` (bereits gelinkt). Die Microsoft ARM64-ABI übergibt die ersten vier Argumente in `x0–x3`; weitere Argumente kommen auf den Stack. `wsprintfA` erwartet: `x0=dst_buf`, `x1=fmt`, `x2..`=varargs.

| Format-Spezifizierer | Verhalten |
|---------------------|-----------|
| `%s` | ANSI-String-Pointer (`pchar`) |
| `%d` | `int64` als Dezimalzahl |
| `%f` | `f64` mit 6 Nachkommastellen |
| `%%` | Literal-`%` |

Implementierungspfad: neuer Builtin-ID (oder Erweiterung des bestehenden `wab_emitPrintfHelper`), der varargs aus dem IR-Slot-Array in die richtigen Register/Stack-Positionen legt und dann `wsprintfA` aufruft. Der resultierende String wird anschließend via `wab_printstr` ausgegeben.

**Nutzen**
Einzeilige formatierte Ausgabe ohne manuelle String-Konkatenation — unerlässlich für Debugging, Logging und User-facing Output auf Windows ARM64.

**Abnahme**
- `Printf("x=%d, s=%s\n"c, 42, "hello"c)` gibt `x=42, s=hello` aus.
- `Printf("%f\n"c, 3.14)` gibt `3.140000` aus.
- `Printf("100%%\n"c)` gibt `100%` aus.
- Bestehender `PrintFloat`-Test (`tests/wp08_win_arm64_printf.lyx`) bleibt grün.

---

## WP-09 · Windows ARM64 VMT — Hardware-Verifikation

**Priorität:** Mittel

**Aufgabe**
Das bestehende Testprogramm `tests/wp09_win_arm64_vmt.lyx` auf echter Windows ARM64 Hardware ausführen und das Ergebnis dokumentieren.

**Kontext**
Das PE32+/Aarch64-Binary ist fertig kompiliert und wurde unter QEMU-Emulation verifiziert. Ein QEMU-Lauf ist kein Ersatz für echte Hardware — Mikroarchitektur-Details (Alignment, Cache-Kohärenz, Calling-Convention-Randfälle) können abweichen. Das Testprogramm prüft zwei unabhängige Klassen mit VMT-Dispatch (`Counter`, `Accumulator`) und erwartet folgende Konsolenausgabe:
```
3
60
PASS
```

**Nutzen**
Erst ein erfolgreicher Lauf auf echter Hardware schließt den Verifikationskreis für den gesamten Windows ARM64 Codegen-Pfad ab. Ohne diesen Nachweis bleibt die Produktionsreife des Backends unklar.

**Abnahme**
- Programm gibt `3`, `60`, `PASS` auf der Konsole aus — kein Absturz, kein falsches Ergebnis.
- Gerät und OS-Version werden im Commit-Message dokumentiert (z.B. `Surface Pro X, Windows 11 ARM64, Build 26100`).

---

## WP-13 · Inspect Debug-Visualizer — ARM64 Linux + Windows ARM64

**Priorität:** Niedrig

**Aufgabe**
Den `Inspect(expr)`-Builtin für ARM64 Linux und Windows ARM64 implementieren.

**Kontext**
Die x86_64-Referenz-Implementierung existiert in `src/codegen_x86.lyx` ab Zeile 5040 (WP-BC-39). Sie gibt `[Inspect:varname] value\n` auf stderr aus und extrahiert den Variablennamen direkt aus dem AST-Node. Die interne Hilfsfunktion `cg_emitInspectPrintInt()` enthält eine vollständige inline-itoa-Sequenz.

In `src/backend/arm64/emit_arm64.lyx` und `src/backend/win_arm64.lyx` fehlt jede Inspect-Implementierung — `grep` liefert keine Treffer.

| Target | Syscall / API | Datenadressen | itoa |
|--------|--------------|---------------|------|
| ARM64 Linux | `write(2, buf, len)` via `svc #0` | ADRP + ADD | SDIV + MSUB Loop |
| Windows ARM64 | `WriteFile(GetStdHandle(-12), ...)` via IAT | ADRP + ADD | identisch ARM64 |

Der Variablenname wird zur Compile-Zeit aus dem AST-Node gelesen (wie in x86_64) und in den Daten-Abschnitt geschrieben.

**Nutzen**
`Inspect(x)` ist ein importfreies, einzeiliges Debug-Werkzeug. Auf ARM64 Linux und Windows ARM64 fehlt es heute — Entwickler müssen auf `PrintLn` + manuelle Konvertierungen ausweichen.

**Abnahme**
- ARM64 Linux: `var x: int64 := 42; Inspect(x)` → stderr: `[Inspect:x] 42`
- ARM64 Linux: `Inspect(2 + 3)` → stderr: `[Inspect:?] 5`
- Windows ARM64: gleiches Verhalten, Ausgabe via `WriteFile` auf STDERR-Handle (`GetStdHandle(-12)`)
- Bestehende x86_64-Tests bleiben grün.
