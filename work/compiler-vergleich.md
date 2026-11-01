# lyxc dauerhaft gegen TCC, GCC, Clang und Cranelift messen

Stand: 2026-10-31 · Issue #2332

## Was es gibt

| Werkzeug | misst | Compiler |
|---|---|---|
| `tools/bench_compile.sh` | Übersetzungszeit **von lyxc**, Phasenaufteilung (`--time-trace`) | nur lyxc |
| `tools/bench_runtime.sh` | **Laufzeit** erzeugten Codes auf den Kernen in `bench/` | lyxc, gcc, clang |
| `tools/bench_vergleich.sh` | **Übersetzungszeit im Vergleich**, Größe, Laufzeit | lyxc, tcc, gcc, clang, rustc/LLVM, rustc/Cranelift |
| `tools/gen_bench_last.sh` | erzeugt die Last in Lyx, C und Rust | — |
| `tests/bench_vergleich_test.sh` | hält das Geschirr messfähig (im `test`-Ziel) | alle vorhandenen |

## Aufruf

```
tools/bench_vergleich.sh -l                      # wer ist installiert, was fehlt
tools/bench_vergleich.sh                         # 2000 Funktionen, 5 Läufe
tools/bench_vergleich.sh -f 8000 -n 7 -w 5000 \
  --md bench/ergebnisse/$(date +%F)_uebersetzungszeit.md
make bench-vergleich                             # Kurzform
```

## Warum eine generierte Last

Die Übersetzungszeit eines kleinen Programms besteht fast nur aus
Prozessstart; bei 200 Zeilen liegen alle Compiler im Rauschen beieinander.
Erst ein paar tausend Funktionen trennen sie. Und nur generierter Code ist in
drei Sprachen wirklich zeilenweise gleich — eine von Hand nachgebaute
„entsprechende" Fassung vergleicht die Handschrift mit, nicht den Compiler.

`tools/gen_bench_last.sh -n N -o DIR` schreibt `last.lyx`, `last.c` und
`last.rs`: je `N` gleich gebaute Funktionen mit je sechs Rechenschritten,
Konstanten aus dem Index (damit kein Compiler zwei Rümpfe als denselben
erkennt), und ein `main`, das sie der Reihe nach aufruft. Jede Fassung gibt
`checksum=<zahl>` aus.

**Kein Überlauf, alle Werte positiv** — und das ist kein Zierrat: signierter
Überlauf ist in C unbestimmtes Verhalten, in Rust bricht er im Debug-Bau ab,
und `>>` ist in allen drei Sprachen arithmetisch, auf positiven Werten also
dasselbe wie logisch. Ohne diese Schranke wäre ein Prüfsummenunterschied
zwischen den Fassungen kein Compilerbefund, sondern ein Fehler des Generators.

Die Rust-Fassung trägt `#[inline(never)]`: ohne das Attribut zieht LLVM auf
`-Copt-level=2` die Kette aus N Aufrufen zu einem Ausdruck zusammen und
misst etwas anderes als die beiden anderen Fassungen.

## Reihenfolge der Messung

Wie in `tools/bench_runtime.sh`, und sie ist nicht verhandelbar:

1. **Korrektheit.** Weicht eine Prüfsumme ab, wird diese Fassung gemeldet und
   **nicht** gemessen. Eine Zeit zu einem Programm, das etwas anderes rechnet,
   sieht aus wie ein Ergebnis.
2. **Zeit** als Median aus `-n` Läufen, mit min/max, auf einen Kern gepinnt
   (`taskset -c 2`) — ohne Pinning kippt der Median bei kleinen Unterschieden
   das Vorzeichen.
3. **Größe** des Erzeugnisses und **Laufzeit** mit `-w` Wiederholungen.

## Gemessen wird der ganze Weg Quelle → lauffähiges Programm

Das ist, was „Kompiliergeschwindigkeit" im Alltag heißt. Für lyxc ist das kein
Vorteil mit Sternchen: lyxc schreibt die ELF-Datei selbst, die C-Compiler rufen
`ld`, rustc ruft es ebenfalls. Wer nur die Codeerzeugung vergleichen will, misst
etwas anderes — dann `-c`-Varianten ergänzen, nicht diese Zahlen umdeuten.

## Grenzen der Tabelle

- **Die Größenspalte vergleicht nicht drei Sprachen.** rustc bindet die
  Rust-Standardbibliothek statisch ein (einige MB); lyxc und die C-Compiler
  linken gegen die vorhandene libc bzw. schreiben die Datei selbst. Innerhalb
  einer Sprache ist die Spalte aussagekräftig, quer nicht.
- **Die Laufzeitspalte ist grob** (Median aus drei Läufen, Wandzeit mit
  Prozessstart). Für Laufzeitaussagen gilt `tools/bench_runtime.sh` mit
  `perf stat` und Prüfsummen-Gate.
- **Nur direkt nacheinander erhobene Zahlen sind vergleichbar.** Takt,
  Cachegrößen und Last verschieben sie; das Protokoll nennt deshalb CPU,
  Compilerversionen, Datum und Systemlast vor und nach dem Lauf mit.
- **Die Last ist ein Kern, kein Programm.** Sie sagt nichts über Präprozessor,
  Header-Mengen, Templates, Module oder Linkzeit großer Projekte. Dafür wäre
  eine zweite Last nötig (Issue, nicht Halbfassung).

## Fehlende Compiler

Ein fehlender Compiler wird **mit Grund** genannt, nicht übergangen — sonst
liest sich eine halbe Tabelle wie eine vollständige. `-l` zeigt beides.

| fehlt | Abhilfe |
|---|---|
| `tcc` | `sudo apt install tcc` |
| `clang` | `sudo apt install clang` |
| Cranelift | `rustup toolchain install nightly -c rustc-codegen-cranelift-preview` |

Cranelift ist kein eigenes Programm, sondern ein rustc-Backend; die Prüfung
sucht deshalb die Backend-Bibliothek
(`~/.rustup/toolchains/nightly-*/lib/rustlib/*/codegen-backends/librustc_codegen_cranelift-*.so`),
nicht nur `rustc`.

## Ergebnisse

`bench/ergebnisse/<datum>_uebersetzungszeit_<cpu>.md`, geschrieben mit `--md`.
