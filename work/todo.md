# Aurum — Offene Arbeitspakete

> Stand: 2026-06-09. Nur noch offene Punkte; erledigte WPs sind entfernt.
> Zuletzt erledigt: WP-02 (PR #706), WP-08 (PR #707).

---

## Übersicht

| WP | Titel | Prio | Offen |
|----|-------|------|-------|
| WP-09 | Windows ARM64 VMT — Hardware-Verifikation | Mittel | Hardware-Lauf ausstehend |
| WP-13 | Inspect Debug-Visualizer — ARM64 + Windows ARM64 | Niedrig | Nicht implementiert |

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
