# Benchmark 1: grosse Codebasis mit Funktionsnetz — 2000 Funktionen, 20 Module

Stand: 2026-10-31 · Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz ·
5 Uebersetzungen und 10 Laufzeitmessungen je Eintrag, Median mit min/max ·
lyxc 1.2.26K, gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0.
Erhoben mit `tools/bench_netz.sh -f 2000 -m 20 -w 200 -n 5 -r 10`.
Pruefsumme Lyx == C == unabhaengige Referenz: `checksum_hi=2050426429 checksum_lo=2511273384`.

## Uebersetzungszeit

| Messpfad | Median | min/max | CPU | Spitzen-RSS |
|---|---|---|---|---|
| lyxc (ELF direkt, keine Linkphase) | 860 ms | 858/869 ms | 0.83 s | 66 MiB |
| tcc (ohne Optimierung, seriell) | 73 ms | 72/76 ms | 0.05 s | 5 MiB |
| tcc (parallel -P 8, ohne Kernbindung) | 77 ms | 72/83 ms | 0.20 s | 8 MiB |
| gcc -O2 (ein Aufruf, seriell) | 32060 ms | 30781/32625 ms | 39.76 s | 63 MiB |
| gcc -O2 (parallel -P 8, ohne Kernbindung) | 13458 ms | 12731/16844 ms | 61.74 s | 63 MiB |
| lyxc --emit=obj (EIN Objekt, ganze Uebersetzung) | 1341 ms | 1294/1884 ms | 1.69 s | 66 MiB |
| tcc -c je Datei | 323 ms | 318/345 ms | 0.14 s | 7 MiB |
| tcc Linken der Objekte | 19 ms | 16/23 ms | 0.00 s | 4 MiB |
| gcc -O2 -c je Datei | 50608 ms | 31351/59703 ms | 30.74 s | 63 MiB |
| gcc Linken der Objekte | 36 ms | 35/36 ms | 0.01 s | 11 MiB |

## Laufzeit (200 Datensaetze)

| Fassung | Median | min/max | Erzeugnis |
|---|---|---|---|
| lyxc | 89 ms | 88/99 ms | 845 KiB |
| tcc (ohne Optimierung) | 123 ms | 122/124 ms | 639 KiB |
| gcc -O2 | 66 ms | 66/73 ms | 528 KiB |

## Grenzen

- Messpfad B ist fuer lyxc **kein** Gegenstueck zu `gcc -c`: `--emit=obj` erzeugt
  ein Objekt der ganzen Uebersetzung, nicht eines je Modul.
- Der parallele C-Build steht als eigene Zahl und laeuft OHNE Kernbindung
  (auf einem Kern waere er keiner); er ersetzt den seriellen Wert nicht.
- Alle uebrigen Zeiten sind auf einen Kern gebunden (`taskset -c 2`).
- LTO und PGO gibt es fuer lyxc nicht (work/vorabcheck-2332.md).
- Die Referenz ist ein Auswerter ueber der Funktionstabelle
  (`tools/bench_netz_ref.py`), keine dritte Uebersetzung; sie laeuft mit
  3 Datensaetzen ausserhalb der Zeitmessung.
- clang war nicht installiert — Spalte fehlt, statt 0 zu melden.
- **tcc steht ohne Optimierungsschalter**: TCC optimiert nicht, `-O2` waere Zierrat.
