# Aurum — Offene Arbeitspakete

> Stand: 2026-06-09. Nur noch offene Punkte; erledigte WPs sind entfernt.
> Zuletzt erledigt: WP-02 (PR #706), WP-08 (PR #707), WP-13 (PR offen).

---

## Übersicht

| WP | Titel | Prio | Offen |
|----|-------|------|-------|
| WP-09 | Windows ARM64 VMT — Hardware-Verifikation | Mittel | Hardware-Lauf ausstehend |

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

