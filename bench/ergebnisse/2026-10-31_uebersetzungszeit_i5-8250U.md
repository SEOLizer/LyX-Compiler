# Uebersetzungszeit: lyxc gegen TCC/GCC/Clang/Cranelift

Stand: 2026-10-31 · Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz · Last: 2000 Funktionen (tools/gen_bench_last.sh) ·
5 Uebersetzungen je Compiler, Median der Wandzeit, Quelle -> lauffaehiges Programm.
Pruefsumme aller Fassungen gleich: `checksum=135538870`. Erhoben mit `tools/bench_vergleich.sh`.

| Compiler | Uebersetzen (Median) | min/max | Erzeugnis | Laufzeit (2000 Wdh.) | Verhaeltnis zu lyxc | Version |
|---|---|---|---|---|---|---|
| `lyxc` | 205 ms | 193/246 ms | 497 KiB | 69 ms | 1.00 | lyxc 1.2.26K |
| `tcc` | 25 ms | 25/32 ms | 374 KiB | 69 ms | 0.12 | tcc version 0.9.27 (x86_64 Linux) |
| `gcc -O0` | 1456 ms | 1441/1502 ms | 429 KiB | 65 ms | 7.10 | gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| `gcc -O2` | 5347 ms | 5281/6182 ms | 251 KiB | 28 ms | 26.08 | gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| `gcc -O3 -march=native` | 4998 ms | 4819/5068 ms | 162 KiB | 29 ms | 24.38 | gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| `rustc cranelift -O0` | 1090 ms | 1080/1122 ms | 7529 KiB | 62 ms | 5.32 | rustc 1.101.0-nightly (92b5b8c87 2026-10-29) + librustc_codegen_cranelift-1.101.0-nightly.so |
| `rustc llvm -O0` | 1114 ms | 1111/1201 ms | 5780 KiB | 113 ms | 5.43 | rustc 1.101.0-nightly (92b5b8c87 2026-10-29) |
| `rustc llvm -O2` | 2441 ms | 2430/2566 ms | 4818 KiB | 25 ms | 11.91 | rustc 1.101.0-nightly (92b5b8c87 2026-10-29) |

Nicht gemessen, weil nicht installiert:
- `clang-O0` — `sudo apt install clang`
- `clang-O2` — `sudo apt install clang`
