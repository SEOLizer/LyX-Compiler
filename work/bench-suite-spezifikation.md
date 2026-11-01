# Benchmark-Suite: zehn Aufgaben, Compiletime und Kompilatlaufzeit getrennt

Stand: 2026-10-31 · **Vorabcheck erledigt, 1-S umgesetzt** · Vorlauf: #2332
Verbindliche Voraussetzungen: `work/vorabcheck-2332.md` (alles dort gemessen).

Grundsatz: je Aufgabe **zwei** unabhängige Ergebnisse — Übersetzungszeit und
Laufzeit des Erzeugnisses. Nicht zu einer Punktzahl verrühren.

```
Compile-Speedup = T_referenzcompiler / T_lyxc
Runtime-Speedup = T_referenzkompilat / T_lyxc-kompilat
```

Werte > 1 = Vorteil lyxc. Damit ist ablesbar, ob eine Optimierung 20 % längeres
Übersetzen für 8 % schnellere Ausführung kostet — und in welches
Optimierungsprofil sie gehört.

„Heftig" heißt **reale Optimierungsprobleme**. Eine Million identischer
Additionen quält den Compiler und sagt nichts über Alltagstauglichkeit.

## Stand der Umsetzung

| | Aufgabe | Stand |
|---|---|---|
| 0 | Vorabcheck Arithmetik/Objektdateien/Messpfade | **erledigt**, `work/vorabcheck-2332.md`, Dauerprüfung `tests/arith_vertrag_test.sh` |
| 1 | Große Codebasis mit Funktionsnetz | **1-S umgesetzt und gemessen**: `tools/gen_bench_netz.py`, `tools/bench_netz_ref.py`, `tools/bench_netz.sh`, `tests/bench_netz_test.sh`, `make bench-netz`. M und L offen (Skalierungsgrenze erst nachmessen) |
| 2 | Kontrollfluss-Labyrinth | offen |
| 3 | Registerdruck und Abhängigkeitsketten | offen; Arithmetikvertrag steht (echtes uint64, siehe unten) |
| 4 | Dichte Matrixmultiplikation f64 | offen; davor der Gleitkomma-Nachweis |
| 5 | 3D-Stencil Wärmeausbreitung | offen; davor der Gleitkomma-Nachweis |
| 6 | Sortieren mit schwierigen Eingaben | offen |
| 7 | Hash-Aggregation | offen; kein Ersatzhash nötig (uint64 trägt) |
| 8 | Dijkstra auf CSR | offen |
| 9 | Lexer/Parser/Bytecode-Interpreter | offen |
| 10 | Datenflussgraphen-Stresstest | offen — **als nächstes** |

Reihenfolge: **1-S → 10 → 3 → 2 → 4 und 5 → 6 bis 9.** Vor 4/5 steht der
Gleitkomma-Nachweis; eine offene Float-Frage blockiert die Integer-Benchmarks
also nicht.

Messgeschirr: `tools/bench_netz.sh` (Aufgabe 1, zwei Messpfade),
`tools/bench_vergleich.sh` (Übersetzungszeit mehrerer Compiler auf einer
Rechenlast), `tools/bench_runtime.sh` (Laufzeit mit `perf stat`),
`tools/bench_compile.sh` (Phasenaufteilung lyxc). Methode und Grenzen:
`work/compiler-vergleich.md`.

## Verbindliche Festlegungen

Aus dem Vorabcheck, alles belegt statt angenommen:

| Punkt | Festlegung |
|---|---|
| Arithmetikvertrag | **Modulo-2^64 für alle Fassungen.** Lyx trägt echtes `uint64`: logisches `>>`, vorzeichenloser Vergleich, Division, Rest, Multiplikation und Addition mod 2^64, Literale bis 2^64-1, exakte 64-Bit-`rotl`/`rotr`. Maskierung unterhalb einer Überlaufschwelle ist damit **nicht** nötig und nicht erlaubt, wo echte Rotation gemeint ist. |
| Lyx-Typunterstützung | geprüft und grün (9 Fälle + C-Gegenprobe, `tests/arith_vertrag_test.sh`). Der Rückfall „63-Bit-Rotation" in Aufgabe 3 **entfällt**; Aufgabe 7 braucht keinen Ersatzhash. Kein `>>>` — logisch schieben heißt `uint64`. |
| C-Seite | `uint64_t`/`int64_t`. Signierter Überlauf bleibt in C UB, also rechnet die C-Fassung an Überlaufstellen in `uint64_t`. Rust (nur bei Cranelift-Vergleichen): `wrapping_*`. |
| Prüfsummenausgabe | **zwei 32-Bit-Hälften** (`hi`/`lo`), weil keine vorzeichenlose Dezimalausgabe existiert. |
| Skalierungsgrenze | Aufgabe 1 zunächst **ausschließlich S**. Danach Funktionszahl, Modulzahl und Dateigröße **getrennt** erhöhen. Der Absturz bei ~1 MB generierter Daten-Unit wird reproduziert und als Compilerfehler dokumentiert. L bleibt Zielprofil. |
| Build-Messung | Zwei benannte Messpfade: **Quelltext → Objektdateien** und **Quelltext → ausführbare Datei**. `--emit=obj` funktioniert (ET_REL, `ld`-bindbar), erzeugt aber **ein** Objekt der ganzen Übersetzung; beim direkten ELF-Pfad entfällt eine eigenständige Linkphase. Der parallele C-Build steht als eigene Zahl und ersetzt den seriellen nicht. |
| LTO/PGO | für lyxc **nicht unterstützt** (keine Spur im Compiler). Keine Nullwerte, keine scheinbar vergleichbaren Ergebnisse. |
| Gleitkommaprofile | zunächst **ein** gemeinsames Profil: keine FMA-Kontraktion. lyxc kontrahiert nicht; GCC kontrahiert mit `-march=native`, bekommt also `-ffp-contract=off`. Umordnung und Kontraktion werden einzeln geprüft und dokumentiert, bevor weitere Kategorien entstehen. |
| Rust/Cranelift | Standardumfang **Lyx + C + unabhängige Referenz**. Rust nur für ausdrücklich ausgewählte Cranelift-Vergleiche, dann mit festgehaltenem Backend und Toolchain. |
| Referenz | Eine dritte Übersetzung desselben Algorithmus ist **nicht** automatisch unabhängig. Einfacherer Kontrollalgorithmus oder andere Darstellung; große Messdaten außerhalb der Zeitmessung prüfen. Aufgabe 1 löst das mit einem **Auswerter über der Funktionstabelle** (`tools/bench_netz_ref.py`). |

## Abschlussbedingung je Aufgabe

1. Eigenes Issue mit Algorithmus, Eingabeformat, Größen und exakter Semantik.
2. Vollständige benötigte Sprachfassungen und unabhängige Referenz.
3. Erfolgreiche Korrektheitsprüfung einschließlich Randfällen.
4. Reproduzierbarer Messaufruf mit Compilerständen, Optionen und Rohdaten.
5. Dokumentierte Grenzen und fehlende Fähigkeiten.

## Die zehn Aufgaben

### 1. Große Codebasis mit Funktionsnetz

Generator erzeugt viele **unterschiedliche** Funktionen über Module, als
gerichteter Aufrufgraph: kleine Hilfsfunktionen, längere Berechnungen,
gemeinsam genutzte Unterfunktionen. Zur Laufzeit führen eingelesene Datensätze
unterschiedliche Pfade aus; **jede** Funktion muss über gültige Eingaben
erreichbar sein.

| Größe | Funktionen | Module |
|---|---|---|
| S | 2.000 | 20 |
| M | 20.000 | 100 |
| L | 100.000 | 500 |

- Compiler: Symbolverwaltung, modulübergreifende Analyse, Inlining, Codegen, Linken.
- Laufzeit: Aufrufe, Registerübergabe, Inlining-Entscheidungen, Instruction-Cache.
- Korrektheit: 64-Bit-Prüfsumme mit **ausdrücklich festgelegtem** Überlaufverhalten.
- Interessant: aggressives Inlining macht Einzelpfade schnell und das
  Gesamtprogramm durch Codeaufblähung langsam.

**Umgesetzte Form (1-S).** `tools/gen_bench_netz.py -f 2000 -m 20 -w 200`
schreibt Lyx (`unit`/`import`, ein Modul je Datei), C (eine
Übersetzungseinheit je Modul plus Kopfdatei) und `netz_spec.json`.
Modul `k` hält einen zusammenhängenden Block von `B = ceil(F/M)` Funktionen;
jeder Knoten `kn<i>` ruft bis zu zwei Nachfolger mit **höherem** Index
(`i+1`, `i+B+1`) — azyklisch und modulüberschreitend. Acht Hilfsfunktionen in
`netz_h` werden von allen benutzt. Ob ein Nachfolger gerufen wird, entscheidet
der Datenwert `d`, der je Ebene nach rechts geschoben wird: verschiedene
Datensätze laufen verschiedene Pfade, die Tiefe ist durch die 64 Bit von `d`
begrenzt (kein Stacküberlauf), und **jede** Funktion ist erreichbar, weil
`main` je Datensatz alle `F` Knoten unmittelbar aufruft.

Einen Verteiler (Sprungtabelle oder `if`-Kette über den Index) gibt es
bewusst **nicht**: er würde die Laufzeitmessung dominieren und wird zwischen
den Sprachen unterschiedlich übersetzt — gemessen wäre dann der Verteiler,
nicht das Netz.

Die Knoten heißen `kn<i>`, nicht `f<i>`: `f32`/`f64` sind Typnamen in Lyx, ein
`f32(...)` ist ein Parse error.

### 2. Kontrollfluss-Labyrinth

Regelbasierter Transaktionsprüfer: verschachtelte Bedingungen, große
Fallunterscheidungen, frühe Rückgaben, gemeinsame Berechnungen.

| Größe | Regeln | Datensätze |
|---|---|---|
| S | 500 | 1 Mio. |
| M | 5.000 | 10 Mio. |
| L | 20.000 | 50 Mio. |

Zwei Eingabeverteilungen: stark vorhersehbar und nahezu gleichverteilt. Regeln
auf mehrere Funktionen verteilt, zusätzlich eine Extremvariante mit einer
besonders großen Funktion.

- Compiler: CFG, Dominatoren, SSA, Wertflussanalyse, Sprungoptimierung.
- Laufzeit: Branch Prediction, bedingte Befehle, Anordnung heißer/seltener Pfade.
- Korrektheit: exakte Entscheidung je Datensatz **und** Gesamtsumme.

### 3. Registerdruck und Abhängigkeitsketten

Generierter Ganzzahlkern über Datenblöcke mit vielen gleichzeitig lebenden
Zwischenwerten: Addition, Multiplikation, XOR, Rotation, **variable**
Schiebeoperationen. Varianten: 16/64/256 gleichzeitig lebende Werte; lange
serielle Abhängigkeiten; viele unabhängige Ketten; Funktionsaufrufe mitten in
der Berechnung.

- Compiler: Registerallokation, Live-Range, Spill-Entscheidungen, Scheduling.
- Laufzeit: Registerknappheit, Stackzugriffe, Latenz, parallele Ausführung.
- Korrektheit: bitgenau, Schiebeweiten ausdrücklich 0..63.
- Gleiche Operationszahl heißt hier **nicht** gleiche Laufzeit.

### 4. Dichte Matrixmultiplikation (f64)

`C = A × B`, Dimensionen S 256², M 768², L 1.536². Zwei getrennte
Implementierungen: naive Dreifachschleife und **festgelegte** blockweise
Variante; jeder Compiler bekommt denselben Algorithmus.

- Compiler: Schleifenanalyse, Vektorisierung, Adressrechnung, Entrollen.
- Laufzeit: SIMD, Cache, Speicherzugriffe, Gleitkommaleistung.
- Korrektheit: gegen unabhängig geprüfte Referenz, absolute **und** relative
  Toleranz vorab festgelegt.
- Messdisziplin: strikte Gleitkommasemantik und ein Modus mit erlaubter
  Umordnung (`-ffast-math` und Verwandte) sind **getrennte Ergebnisse** — GCC
  dokumentiert selbst, dass sich die Zahlen dadurch ändern.

### 5. 3D-Stencil: Wärmeausbreitung

Jeder innere Gitterpunkt aus seinem Wert und sechs Nachbarn; zwei Puffer
wechseln, Ränder fest. S 64³, M 128³, L 256³, je 100 Zeitschritte.

- Compiler: verschachtelte Schleifen, Induktionsvariablen, Alias-Analyse, Vektorisierung.
- Laufzeit: Speicherbandbreite, Cache-Lokalität, redundante Ladeoperationen.
- Korrektheit: Feldvergleich gegen Referenz in festgelegter Toleranz.
- Zusatzvariante: derselbe Kernel einmal mit nachweislich getrennten Puffern,
  einmal mit erst zur Laufzeit geprüfter Überlappungsfreiheit — zeigt, ob der
  Compiler sinnvolle Schleifenversionen erzeugt.

### 6. Sortieren mit schwierigen Eingaben

**Exakt festgelegte** Introsort-Implementierung über Datensätze aus
64-Bit-Schlüssel und Nutzdaten; 100.000 / 1 Mio. / 10 Mio. Datensätze.
Muster: zufällig, sortiert, umgekehrt, sehr viele gleiche Schlüssel, fast
sortiert mit wenigen Störungen.

- Korrektheit: Reihenfolge **und** Erhalt sämtlicher Datensätze — eine sortierte
  Ausgabe allein genügt nicht.
- Abgrenzung: keine Bibliothekssortierung, sonst vergleichen wir Bibliotheken.

### 7. Hash-Aggregation einer kleinen Datenbank

Datensätze (Kunden-ID, Kategorie, Betrag) filtern und nach zusammengesetztem
Schlüssel aggregieren; Hash-Tabelle mit **festgelegtem** Open Addressing.
1 Mio. / 10 Mio. / 50 Mio. Datensätze. Varianten: gleichverteilt, wenige sehr
häufige Schlüssel, erhöhte Kollisionsrate.

- Messdisziplin: identische Kapazität und Speicherstrategie; Reservierung und
  Initialisierung **separat** ausgewiesen.
- Korrektheit: alle Gruppen und Summen gegen einfache Referenz.

### 8. Graphanalyse mit Dijkstra

Kürzeste Wege, gerichtet, nichtnegative ganzzahlige Gewichte, CSR-Darstellung,
**identischer** binärer Heap. S 50.000/300.000, M 500.000/3 Mio.,
L 2 Mio./12 Mio. (Knoten/Kanten), je mehrere festgelegte Startknoten.

- Korrektheit: vollständige Distanzvektoren gegen Referenz, unerreichbare
  Knoten eingeschlossen; Überlauf bei Distanzaddition ausgeschlossen.
- Nutzen: realistischer Gegenpol zu gut vektorisierbaren Rechenschleifen.

### 9. Lexer, Parser und Bytecode-Interpreter

Kleine definierte Sprache (Variablen, Integer-Ausdrücke, Bedingungen,
Schleifen, Funktionen): tokenisieren → Syntaxbaum → Bytecode → ausführen.
10.000 / 100.000 / 1 Mio. Tokens, Ausführungslast zusätzlich über eine
festgelegte Zahl ausgeführter Bytecode-Befehle.

- Korrektheit: erwartete Tokenfolge, Syntaxbaum-Prüfung, exakte Programmausgabe.
- Messdisziplin: **jede Stufe separat** und zusätzlich die Gesamtlaufzeit —
  sonst bleibt unsichtbar, wo ein Compiler gewinnt.

### 10. Optimierungs-Stresstest mit großen Datenflussgraphen

Generator baut Berechnungsfunktionen mit gezielten Gelegenheiten: wiederholte
Teilausdrücke, schleifeninvariante Berechnungen, Konstanten über
Funktionsgrenzen, überflüssige Speicherungen, redundante Bedingungen,
Multiplikation und Division durch Konstanten, unterschiedlich lange Ketten
gleichwertiger Zwischenwerte. 10.000 / 100.000 / 500.000 Operationen auf
mehrere Funktionen verteilt; separat die maximale Funktionsgröße erhöhen.

- Compiler: Zusammenspiel und **Skalierung** der Optimierungspässe.
- Laufzeit: wie viel unnötige Arbeit im Kompilat übrig bleibt.
- Korrektheit: gegen einfache unabhängige Referenzauswertung; Laufzeiteingaben
  verhindern vollständige Vorberechnung.
- Der bewusst synthetische Härtetest: zeigt verpasste Optimierungen **und**
  explodierende Compiletime.

## Messregeln für alle zehn

| Bereich | Festlegung |
|---|---|
| Übersetzungszeit | Clean Build vom Compilerstart bis zu fertigen Objektdateien; Linkzeit separat, Gesamtzeit zusätzlich |
| Compiler-Ressourcen | Walltime, CPU-Zeit, maximaler RAM, Größe des ausführbaren Codes |
| Laufzeit | Eingaben vor der Messung laden; Initialisierung, Kernberechnung, Gesamtdauer getrennt |
| Wiederholungen | mindestens 5 Builds und 10 Laufzeitmessungen; Median **und** Streuung |
| Messumgebung | gleiche Maschine, feste Kernzuordnung, kontrollierte Hintergrundlast, dokumentierter Taktmodus |
| Vergleich | gleicher Algorithmus, gleiche Datentypen, gleiche Sicherheitsprüfungen, gleiche Ziel-ISA |
| Optimierungsprofile | Standard- und Maximaloptimierung getrennt; LTO und PGO als eigene Kategorien |
| Ergebnisprüfung | außerhalb der gemessenen Kernberechnung; falsches Ergebnis disqualifiziert den Lauf |
| Eingaben | versionierte Generatoren, feste Seeds, zusätzlich zurückgehaltene Prüfdaten |
| Grenzen | einheitliche Zeit- und RAM-Limits; Überschreitung ausdrücklich als solche melden |

Auch LLVM empfiehlt wiederholte Messungen und Kontrolle der Störquellen.
Kleine Prozentunterschiede ohne diese Disziplin sind Rechnerwetter — auf
diesem i5-8250U zusätzlich das JCC-Erratum (Sprungpaare über
32-Byte-Grenzen, 8–10 % je Kern).

## Was vor der Umsetzung geklärt sein muss

Diese Punkte sind keine Bedenken gegen die Suite, sondern Festlegungen, die
sonst mitten in der Umsetzung erfunden würden.

1. **Überlaufverhalten, dreisprachig.** Die Suite verlangt „ausdrücklich
   festgelegtes" Überlaufverhalten und an mehreren Stellen **vorzeichenlose**
   64-Bit-Werte. In C ist signierter Überlauf UB, Rust bricht im Debug-Bau ab,
   Lyx kennt `int64` als vorzeichenbehaftet und `>>` arithmetisch
   (CLAUDE.md). `tools/gen_bench_last.sh` löst das heute durch Maskierung
   unterhalb der Überlaufschwelle. Für Aufgaben 3 und 7 (Rotation, Hash) ist
   das zu eng — dort braucht es eine festgelegte Form, die in allen drei
   Sprachen dasselbe Bitmuster liefert, plus einen Test, der genau das belegt.
   **Vor** Aufgabe 3, nicht während.
2. **Vorzeichenlose Breiten in Lyx** sind zu prüfen, nicht anzunehmen. Steht
   kein `uint64` zur Verfügung, wird die Festlegung „vorzeichenlos" zu
   „vorzeichenbehaftet mit festgelegter Maske", und das gilt dann für alle
   Fassungen — sonst messen wir die Sprache mit.
3. **Modulgrenzen.** Aufgabe 1 L verlangt 500 Module und 100.000 Funktionen.
   Unbelegt ist, ob Import-Auflösung und `.lyu`-Weg das tragen; bekannt ist
   eine Grenze bei großen generierten Daten-Units (>~1 MB führte zum
   Compiler-Segfault). Vor L erst S messen und die Grenze **nachmessen**, nicht
   schätzen.
4. **„Objektdateien" bei lyxc.** Die Messregel trennt Übersetzen und Linken.
   lyxc schreibt die ELF-Datei selbst; `--emit=obj` existiert (ET_REL). Welche
   Größe hier „Übersetzungszeit ohne Linken" ist, muss je Compiler benannt
   werden, sonst vergleicht die Spalte zwei verschiedene Dinge.
5. **LTO und PGO** gibt es für lyxc nicht. Die Kategorien bleiben in der
   Tabelle, aber mit Vermerk — nicht als leere Spalte, die wie ein Ergebnis
   aussieht.
6. **f64-Umordnung.** Ein `-ffast-math`-Gegenstück in lyxc ist zu belegen,
   bevor Aufgabe 4 zwei Profile ausweist.
7. **Rust als dritte Fassung** ist für Cranelift nötig. Wer Cranelift aus der
   Suite lässt, braucht nur Lyx und C — das halbiert den Schreibaufwand je
   Aufgabe. Entscheidung je Aufgabe, nicht einmal für alle.

## Reihenfolge

Vorschlag nach Verhältnis von Erkenntnis zu Aufwand, nicht nach Nummer:

1. **Aufgabe 1 S** — baut auf `tools/gen_bench_last.sh` auf, bringt Module und
   Aufrufgraph; misst sofort gegen den vorhandenen Stand.
2. **Aufgabe 10** — rein generiert, keine Referenzimplementierung von Hand;
   trifft genau die Pässe, über die `work/compile-profile-schema.md` schon
   Buch führt.
3. **Aufgabe 3** — nach der Überlauf-Festlegung aus Punkt 1 oben; zielt auf
   Registerallokation, den teuersten Teil des Backends.
4. **Aufgabe 2** — Kontrollfluss, zweiter großer Backend-Bereich.
5. **Aufgaben 4, 5** — Gleitkomma und Speicherbandbreite; hier ist der Abstand
   zu GCC heute am größten (`bench/ergebnisse/2026-10-24_i5-8250U.md`).
6. **Aufgaben 6, 7, 8, 9** — handgeschriebene Algorithmen in je drei Sprachen,
   der größte Schreibaufwand und der geringste Anteil generierter Prüfbarkeit.

Jede Aufgabe ist ein eigenes Issue mit eigenem Nachweis. Keine halbe Aufgabe im
Baum: was den Rahmen sprengt, wird als Issue geführt, nicht angefangen.
