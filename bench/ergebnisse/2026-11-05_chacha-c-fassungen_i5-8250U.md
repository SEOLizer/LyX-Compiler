# ChaCha20-Viertelrunde: welche C-Fassung wird verglichen? (#2322)

Datum: 2026-11-05
Maschine: Intel i5-8250U (Kaby Lake R), 8 Threads, Linux 7.0.0-42
Werkzeuge: lyxc 1.2.31H, gcc 15.2.0 (Ubuntu 15.2.0-16ubuntu1), clang nicht installiert
Geschirr: `tools/bench_runtime.sh -n 9 -k chacha` (Median aus 9 Laeufen, dazu min/max)

## Frage

#2114 nennt als Vergleichswert **gcc -O2: 6-8 ns** je Viertelrunde. Mit
`tools/bench_runtime.sh` kam **10,5 ns** heraus, waehrend die lyxc-Zahl mit
#2114 uebereinstimmte. Die Richtung des Fehlers war die unangenehme: ein
Geschirr, das gcc benachteiligt, stellt unser Erzeugnis zu gut dar.

## Befund 1: die gespiegelte C-Fassung bekommt kein `rol`

`bench/chacha_qr.c` baut absichtlich die Form von `chacha_qr.lyx` nach
(int64-Rechnung, Maske `0xFFFFFFFF`, Rotation aus Schieben/Verodern/
Maskieren). Der Kopf dieser Datei behauptete, GCC ziehe diese Form zu einem
`rol r32` zusammen. **Das ist falsch.** Disassembliert:

| Quelle | gcc -O2 | `rol`-Befehle in `main` |
|---|---|---|
| `bench/chacha_qr.c` (gespiegelt, int64 + Maske) | — | **0** (stattdessen `shl`/`shr`/`or`/`and`) |
| `bench/chacha_qr_u32.c` (idiomatisch, uint32_t) | — | **4**, eine je Rotation |

lyxc nutzt seit #2177 das Builtin `rotl32` und emittiert `rol eax, cl`. Die
gespiegelte C-Fassung ist damit kein Vergleich gegen "was C kann", sondern
gegen "C in unserer Schreibweise" — und unsere Seite hatte den `rol`, die
Gegenseite nicht.

## Befund 2: bei 2e6 Runden war der Prozessstart ein Posten, kein Rundungsfehler

Leerlaufmessung mit 1e5 Runden (5 Laeufe je Fassung, `taskset -c 2`):

| Fassung | ms je Lauf bei 1e5 Runden |
|---|---|
| `qr_c_u32` (gcc, dynamisch gegen libc) | 6,20 |
| `qr_c_mask` (gcc, dynamisch gegen libc) | 3,80 |
| `qr_lyx` (statisch) | 3,20 |

Die Grundkosten sind also **nicht gleich**. Bei den bis heute eingestellten
2e6 Runden machte das bis zu 40 % der Messung aus, und es trifft die
schnellere Fassung relativ haerter — auch das zu unseren Gunsten. Der
Kommentar im Geschirr behauptete "unter einem Prozent"; das war angenommen,
nicht gemessen.

## Messung nach der Korrektur (2e7 Runden, beide C-Schreibweisen)

| Fassung | Median | ns/Op | Takte/Op | Befehle/Op | IPC | Verhaeltnis |
|---|---|---|---|---|---|---|
| lyxc baseline | 190 ms | 9,500 | 26,24 | 53,61 | 2,04 | 1,00x |
| lyxc avx2 | 191 ms | 9,550 | 25,81 | 53,63 | 2,08 | 0,99x |
| gcc -O2 (gespiegelt) | 190 ms | 9,500 | 26,52 | 41,14 | 1,55 | 1,00x |
| gcc -O3 -march=native (gespiegelt) | 185 ms | 9,250 | 25,76 | 41,14 | 1,60 | 1,03x |
| **gcc -O2 idiomatisch** | **94 ms** | **4,700** | **12,71** | **19,10** | 1,50 | **2,02x** |
| gcc -O3 -march=native idiomatisch | 95 ms | 4,750 | 12,70 | 19,10 | 1,50 | 2,00x |

Pruefsumme in allen sechs Fassungen gleich (1597588117 bei 2e7 Runden) — es
wird dieselbe Arbeit gerechnet.

## Antwort auf #2322

1. **Welcher C-Kern ergab 6-8 ns?** Ein idiomatischer. #2114 nennt selbst,
   dass gcc fuer den Schritt "etwa 3 Befehle (`xor`, `rol $16`, implizit
   32 Bit)" braucht — das ist die uint32_t-Form. Heute liegt sie bei
   **4,7 ns/Op**, also besser als die damals genannten 6-8 ns (die Maschine
   war damals belastet).
2. **Zaehlt "Op" dasselbe?** Ja, eine Viertelrunde in beiden Angaben. Kein
   Faktor 16.
3. **Hemmt das Geschirr gcc?** Nicht die Pruefsummenforderung — die kostet
   beide Seiten gleich. Gehemmt haben die **Wahl des C-Kerns** (Befund 1) und
   die **zu kleine Rundenzahl** (Befund 2). Beides ist behoben.
4. **Kein Gleichstand mit gcc.** Der Gleichstand galt gegen die gespiegelte
   Schreibweise. Gegen idiomatisches C ist lyxc bei diesem Kern **Faktor 2,02
   langsamer** (in Takten 26,24 gegen 12,71, in Befehlen 53,61 gegen 19,10).
   Die lyxc-Zahl selbst ist seit #2114 unveraendert richtig.

## Was im Repo geaendert wurde

- `bench/chacha_qr_u32.c` neu: die idiomatische Fassung.
- `tools/bench_runtime.sh`: optionale zweite C-Quelle `CQ2`, als eigene Zeile
  ("gcc -O2 idiomatisch"); Rundenzahl des chacha-Kerns 2e6 -> 2e7; der
  Kommentar zum Startaufwand nennt jetzt gemessene Zahlen und die Vorgabe,
  den Anteil bei neuen Kernen unter 5 % zu halten und das zu belegen.
- Die falsche Behauptung ueber das `rol` ist in `bench/chacha_qr.c` und
  `bench/chacha_qr.lyx` richtiggestellt.

## Offen

Fuer **clang** ist die `rol`-Frage nicht beantwortet — auf dieser Maschine ist
clang nicht installiert. Die Lyx-Seite koennte die Schiebeform selbst erkennen
(Wertebereichsnachweis "obere 32 Bit leer"); das bleibt ein eigener Schritt,
siehe Kopf von `bench/chacha_qr.lyx`.
