# Vorabcheck zur Benchmark-Suite: Arithmetik, Objektdateien, Messpfade

Stand: 2026-10-31 · lyxc 1.2.26K · gcc 15.2.0 · i5-8250U
Gegenstand: die sieben Voraussetzungen aus `work/bench-suite-spezifikation.md`.
Alles hier ist **gemessen**, nicht aus dem Quelltext geschlossen. Die
Dauerprüfung steht in `tests/arith_vertrag_test.sh` (im `test`-Ziel).

## 1. Arithmetikvertrag — Lyx trägt echtes uint64

Der vorgesehene Rückfall („Aufgabe 3 heißt dann 63-Bit-Rotation") **ist nicht
nötig**. Gemessen, je als Bitmuster:

| Eigenschaft | Probe | Ergebnis |
|---|---|---|
| `uint64` existiert | `var a: uint64 := 5` | übersetzt, läuft |
| `>>` auf `uint64` **logisch** | `(2^64-1) >> 1` | `0x7FFF_FFFF_FFFF_FFFF` ✅ |
| Vergleich vorzeichenlos | `(2^64-1) > 1` | wahr ✅ (signiert wäre falsch) |
| Division vorzeichenlos | `(2^64-1) / 2` | `0x7FFF_FFFF_FFFF_FFFF` ✅ |
| Rest vorzeichenlos | `(2^64-1) % 1000` | `615` ✅ (signiert: `-615`) |
| Addition modulo 2^64 | `(2^64-1) + 2` | `1` ✅ |
| signierter Überlauf | `INT64_MAX + 1` | `INT64_MIN`, **kein Abbruch** ✅ |
| Multiplikation modulo 2^64 | `0x9E3779B97F4A7C15 * 3` | exakt ✅ |
| Literal bis 2^64-1 | `18446744073709551615` | Bitmuster aller Einsen ✅ |
| `rotl`/`rotr` 64 Bit | `0x8000000000000001 rotl 1` | `0x3`; `rotr 1` → `0xC000000000000000` ✅ |
| `>>` auf `int64` | `-8 >> 1` | `-4`, arithmetisch ✅ |
| `>>>` | — | **gibt es nicht**, Parse error |

**Festlegung.** Gemeinsamer Vertrag: Modulo-2^64-Semantik, `uint64` für alles
Vorzeichenlose, `int64` nur wo Vorzeichen gewollt ist, logisches Schieben über
`uint64` (kein `>>>`). C-Gegenstück: `uint64_t`/`int64_t`. Die C-Gegenprobe im
Test rechnet dieselben elf Bitmuster und stimmt überein. Aufgabe 3 kann **echte
uint64-Rotation** verwenden; Aufgabe 7 braucht keinen Ersatzhash.

**Einschränkung, die bleibt:** signierter Überlauf ist in C weiterhin UB —
`int64`-Überlauf darf in den Benchmarks also nur in der Lyx-Fassung auftreten,
die C-Fassung rechnet an diesen Stellen in `uint64_t` und castet. Für Rust
(nur bei Cranelift-Vergleichen) sind es `u64`/`i64` mit
`wrapping_add`/`wrapping_mul` — Rust bricht im Debug-Bau sonst ab.

**Lücke: es gibt keine vorzeichenlose Ausgabe.** `PrintLn` nimmt `int64` und
gibt `2^64-1` als `-1` aus; eine `UIntToStr`/`PrintUInt` fand sich nicht in der
stdlib. Prüfsummen der Suite werden deshalb als **zwei 32-Bit-Hälften**
ausgegeben (`p >> 32` und `p & 0xFFFFFFFF`), nicht als eine Dezimalzahl.
Das ist ohnehin die Form, in der 64-Bit-Werte lesbar bleiben.

## 2. Objektdateiausgabe und Messpfade

- **`--emit=obj` funktioniert.** Erzeugnis ist `ELF64 Typ REL (relozierbare
  Datei)`, Maschine x86-64; `ld -o bin obj.o` bindet es, das Programm läuft
  (`ld` warnt über ein RWX-LOAD-Segment).
- **`-c` wird abgewiesen** — `lyxc: unbekannter Schalter '-c'`, Exit 2. Die
  Quelle führt `-c` als Alias (`src/lyxc.lyx:1402`), aber einstellige Schalter
  landen vorher in der Buchstabenzerlegung (`src/lyxc.lyx:1888`) und werden
  dort verworfen. Der Alias ist also ein **toter Zweig**. Eigenes Issue, kein
  Teil der Suite; die Suite ruft `--emit=obj`.
- **`--emit=obj` ist nicht der Mehrdatei-Weg.** lyxc löst Units über `import`
  selbst auf und schreibt eine Datei; es gibt keinen Lauf „ein Objekt je
  Modul, danach linken". Für Aufgabe 1 heißt das:

| Messpfad | lyxc | gcc/clang |
|---|---|---|
| Quelltext → ausführbare Datei | ein Aufruf, ELF direkt, **keine eigene Linkphase** | `gcc *.c -o bin` |
| Quelltext → Objektdateien | nur als **ein** Objekt der ganzen Übersetzung (`--emit=obj`) | `gcc -c` je Datei, Linkzeit separat |

Beide Spalten werden **getrennt ausgewiesen und benannt**. Eine Zahl „ohne
Linken" für lyxc, die in Wahrheit die ganze Übersetzung ist, wäre kein
Vergleich. Die vorkompilierten Units (`--compile-unit` → `.lyu`) sind ein
dritter, eigener Pfad; bleibt vorerst außen vor.

## 3. LTO und PGO

Im Compiler findet sich **nichts** dazu (`--lto`, `link-time`, `pgo`,
`fprofile`: keine Treffer in `src/*.lyx`; `--help` nennt keine). **Für lyxc
nicht unterstützt** — in Tabellen als solches vermerkt, keine Nullwerte.

## 4. Gleitkomma: ein gemeinsames Profil, und es braucht einen gcc-Schalter

- **lyxc kontrahiert nicht zu FMA.** `a * b + c` erzeugt auch mit
  `--target-cpu=avx2` kein `vfmadd` (0 Treffer im Disassemblat).
- **gcc kontrahiert, sobald FMA verfügbar ist**: `gcc -O2 -march=native -S`
  liefert ein `fmadd`; mit `-ffp-contract=off` keines; ohne `-march=native`
  (Baseline ohne FMA) ebenfalls keines.

**Festlegung für Aufgaben 4 und 5:** gemeinsames Profil = **keine
Kontraktion**. GCC und Clang bekommen `-ffp-contract=off`, auch bei
`-march=native`. Ein zweites Profil mit erlaubter Kontraktion/Umordnung ist
eine eigene Kategorie mit eigener Spalte — und ohne lyxc-Gegenstück, solange
lyxc keines hat. Umordnung (Assoziativität) in lyxc ist noch nicht gemessen;
das gehört in den Gleitkomma-Nachweis vor 4/5, nicht hierher.

## 5. Skalierungsgrenze

Noch nicht gemessen. Aufgabe 1 beginnt bei S (2.000 Funktionen, 20 Module).
Funktionszahl, Modulzahl und Dateigröße werden danach **getrennt** erhöht; der
gemeldete Absturz bei ~1 MB generierter Daten-Unit wird eigens reproduziert und
als Compilerfehler dokumentiert. L bleibt bis dahin Zielprofil.

## 6. Rust und Cranelift

Standardumfang der Suite: **Lyx + C + unabhängige Referenz**. Rust nur für
ausdrücklich ausgewählte Cranelift-Vergleiche; dann werden Backend und
Toolchain festgehalten (hier: rustc 1.101.0-nightly, 92b5b8c87, 2026-10-29,
`librustc_codegen_cranelift-1.101.0-nightly.so`).

Die bereits gemessene Übersetzungszeit-Tabelle (`bench/ergebnisse/`) behält
ihre Rust-Fassung — sie ist der Cranelift-Vergleich.

## 7. Unabhängigkeit der Referenz

Eine dritte Übersetzung desselben Algorithmus ist **nicht** automatisch
unabhängig. Je Aufgabe gilt: einfacherer Kontrollalgorithmus oder andere
Darstellung, und große Messdaten werden **außerhalb** der Zeitmessung geprüft.

## Offen aus diesem Vorabcheck

1. Issue: `-c` als Alias für `--emit=obj` ist ein toter Zweig
   (`src/lyxc.lyx:1402` vs. `:1888`) — entweder in die Buchstabenzerlegung
   aufnehmen oder den Alias entfernen; still abgewiesen ist er in keinem Fall.
2. Issue oder stdlib-Ergänzung: keine vorzeichenlose Dezimalausgabe
   (`UIntToStr`/`PrintUInt` fehlen).
3. Gleitkomma-Umordnung in lyxc messen (vor Aufgaben 4/5).
4. Skalierungsgrenze nachmessen (vor Aufgabe 1 M/L).
