# Kosten von `--compile-profile` — i5-8250U, 2026-11-03

Erhoben mit `tools/bench_profil_overhead.sh -n 9` (#2343 Schritt 3) auf lyxc
**1.2.29A**, Branch `feat/compile-profile-grenzen-2343`. Last ist
`src/lyxc.lyx` — die größte, die das Repo selbst hergibt (rund 4400 geprüfte
Schleifen). Intel Core i5-8250U (Kaby Lake R), Turbo nicht fixiert, gepinnt auf
Kern 2, Maschine ansonsten ruhig gehalten. Rohprotokoll:
`2026-11-03_profil-overhead_i5-8250U.txt`.

**Lesart:** gemessen wird abwechselnd ein Lauf ohne und einer mit Schalter,
neun Paare je Fassung; ausgewiesen ist der **Median der paarweisen Differenz**.
Blockweise gemessen wandert die Maschine innerhalb des Blocks: in einem ersten
Aufbau kam `analysis` dadurch 12 % *schneller* heraus als „ohne Profil", bei
einer Spanne von 22 %. Der Rauschboden ist derselbe Aufbau mit zwei
identischen Fassungen — was er dort ausgibt, kann kein Effekt sein.

Rauschboden (aus gegen aus): **−0,05 %**, Median 1810,7 ms.

| Fassung | aus (Median) | mit (Median) | Spanne mit | Paardifferenz |
|---|---|---|---|---|
| `basic` | 2147,0 ms | 1947,0 ms | 1809,4–2343,7 ms | **+0,93 %** |
| `analysis` | 1879,9 ms | 1900,5 ms | 1814,6–2178,3 ms | **+3,18 %** |
| `detailed` | 1940,3 ms | 1978,7 ms | 1866,8–2210,8 ms | **+1,70 %** |

Die Einzelspannen liegen bei rund 20 %; die Reihenfolge `analysis` >
`detailed` ist damit **nicht** nachgewiesen, die Größenordnung „wenige
Prozent" schon. Ein Null-Overhead-Versprechen gibt dieser Aufbau nicht her.

## Was die Messung gefunden hat

Vor dem Fix in diesem Schritt kostete `detailed` auf derselben Last
**+1037 %** (1,95 s → 22,2 s), und ein Lauf wurde vom OOM-Killer getötet.
Zwei Ursachen, beide quadratisch:

- `StrConcat` legt bei jedem Aufruf eine neue Zeichenkette an und kopiert
  beide Seiten byteweise. Bei 4400 Einträgen mit je sechs Anhängen an einen
  wachsenden Text sind das Milliarden Bytekopien, und die Arena in
  `src/std/alloc.lyx` gibt nichts zurück.
- `_cpDecSummary` verglich jeden Eintrag mit allen vorherigen.

Ersetzt durch einen Anhängepuffer mit Verdopplung und `memcpy` sowie einen
einzigen Durchlauf gegen eine Gründetabelle. Die Serialisierung steht im
Bericht selbst: `collection.serialize_ns` = 29,4 ms bei 1861,6 ms Übersetzung.

**Mit der kleinen Testquelle wäre das unentdeckt geblieben** (80 Entscheidungen,
34 ms Last). Der Overhead einer Messung gehört auf die größte verfügbare Last
gemessen, nicht auf die bequemste.
