# Changelog - Lyx Compiler

## Unveröffentlicht (develop)

### Tests — 73 verrottete Alttests portiert, Vollsuite 286 → 362 grün (#1150, erster Teil)

Der Altbestand unter `tests/regression/**` und `tests/feature_checks/**` war an
der Sprache vorbeigealtert, weil ihn nie ein Ziel ausgeführt hat (sichtbar erst
durch die rekursive Abdeckungsprüfung aus #1112). Von 140 roten Einträgen sind
73 nachgezogen:

- `print_str`/`print_int` → `Print` (19 Dateien), dazu `strlen`→`StrLen`,
  `str_to_int`→`StrToInt`, `sleep_ms`→`Sleep`, `parse_lat`→`ParseLat`,
  `str_length`→`StrLength`, `str_compare`→`StrEquals`
- `extern fn` auf libc-Symbole → die heutigen Builtins (`exit`, `getpid`,
  `open`/`write`/`close`/`unlink`, `PrintChar`, `Printf`). Sie waren an der
  FFI-Sandbox gescheitert, die es bei ihrer Ablage noch nicht gab.
- alte Schreibweisen: `fn(...) -> T` → `fn(...): T`, `type X := struct` →
  `type X = struct`, Struktur-Literal als Wert → Variable + Feldzuweisungen
  (das Literal gibt es nur als Muster, #1104), `};` nach Blöcken, `unit`-Kopf
- **Exit-Code-Konvention**: 22 Tests trugen ihr Ergebnis im Rückgabewert
  (`return sum;`). Der Suite-Runner urteilt nach der Ausgabe, ein Code ≠ 0/42
  gilt ihm als rot — und ab 128 als Absturz, weshalb `return 142` als SIGSEGV
  gezählt wurde. Sie prüfen den Wert jetzt und drucken `PASS`/`FAIL`.

Neu im Runner: `!compileonly` unter den testeigenen Optionen. Damit bleiben
die drei Fremdziel-Tests (win64, macOS) als Übersetzungsprüfung erhalten,
statt gelöscht oder dauerhaft rot zu sein.

Beim Portieren aufgefallen und getrennt aufgesetzt — es sind echte
Compiler-Defekte, keine Testrottung:

- **#1287** `extern fn` mit `@cap` auf unbekanntem FFI-Symbol: der Aufruf wird
  still zum No-op, die Binary bleibt statisch (`_exit(42)` kehrt zurück).
- **#1288** abstrakte Methode, in der Unterklasse ohne `override`
  implementiert: der VMT-Slot bleibt 0, der Aufruf springt nach null.
- **#1289** `append(arr, wert)` fällt in den Catch-all und nullt `rax`; das
  Array bleibt uninitialisiert, `len`/Index stürzen ab. `push` ist in Ordnung.

`tests/suite-broken.txt` führt die verbleibenden 63 Einträge weiter, jetzt
nach Ursache gruppiert und mit dem Befund des letzten Laufs. #1150 bleibt
offen, bis auch sie zugeordnet sind.

### Compiler — `panic` ist nicht mehr mit try/catch abfangbar (#1149)

`panic` sprang in einen installierten Ausnahme-Handler. Ein umschließendes
`try`/`catch` verschluckte den Abbruch, `finally` lief an, und das Programm
lief mit gebrochener Invariante bis Exit 0 weiter:

```lyx
fn Tief(): int64 { panic("kaputt"); return 0; }
fn main(): int64 {
    try { Tief(); } catch (e) { PrintLn("verschluckt"); }
    PrintLn("laeuft weiter");        // wurde erreicht
    return 0;
}
```

`panic` meldet einen Zustand, der nicht auftreten darf — Invariantverletzung,
Programmierfehler, Hardwaredefekt. Der kontrollierte Abbruch **ist** die
Zusicherung; ihn abfangen zu können macht aus dem sichersten Ausgang den
schlechtesten. Beide Emitter (`cg_emitPanicBody` und der `panic`-Builtin)
schreiben die Meldung jetzt nach stderr und beenden den Prozess unbedingt
mit 1 — kein `longjmp` mehr.

`finally` läuft dabei **nicht** mehr an; das ist die Entscheidung, die der
Issue offen ließ, und deckt sich mit „beendet das Programm sofort".

Dieselbe Klasse und derselbe Codepfad: `assert`, `assertNotNull`, die
Bereichs- und die Grenzprüfung waren ebenso fangbar und sind mitgezogen.
Fangbar bleibt allein `throw`.

`tests/panic_uncatchable_test.sh`: 10 Prüfungen, 5 davon rot gegen den
Vorstand. `ebnf.md` bei `PanicExpr` nachgezogen. Kein Versionsbump;
S3 == S4 unverändert.

### Compiler — `finally` läuft auch beim vorzeitigen Verlassen des try-Blocks (#1148)

`return` aus dem `try`-Block sprang direkt in den Epilog; der `finally`-Block
wurde übersprungen und die Freigabe unterblieb lautlos:

```lyx
fn F(): int64 {
    try { PrintLn("A"); return 1; } finally { PrintLn("F"); }
    return 0;
}
// gab A, 1 aus — erwartet A, F, 1
```

**Auch `break` und `continue` waren betroffen** — der Issue hielt sie für in
Ordnung, weil im dortigen Beispiel eine *andere* Schleifenrunde das erwartete
`F` druckte. Drei Runden mit Abbruch in der zweiten liefern jetzt zwei
finally-Läufe statt einem.

**Zweite, unsichtbare Hälfte:** der beim `try` installierte Ausnahme-Handler
blieb beim `return` stehen und zeigte danach in den Rahmen einer bereits
verlassenen Funktion. Ein späterer `throw` sprang dorthin — im Test SIGSEGV
bzw. `stack smashing detected`. Der Handler wird jetzt zurückgesetzt.

Der Codegen führt dafür die offenen try-Blöcke der laufenden Funktion mit
(`tryDepth`, je Ebene ein verdeckter Slot mit der jmp_buf-Basis und der
finally-Knoten). `return` räumt alle ab, `break`/`continue` die, die der
Sprung wirklich verlässt (`loopTryMark`, analog zu `loopDeferMark` aus #1006).
Reihenfolge: von innen nach außen, defers des Blocks vor dem finally.

`tests/finally_exit_test.sh`: 12 Prüfungen, 10 davon rot gegen den Vorstand.
Kein Versionsbump; S3 == S4 unverändert.

### Compiler — `catch` bindet den geworfenen Wert (#1147)

Der geworfene Wert war in **keiner** Schreibweise auslesbar; `catch` war damit
auf „ein Fehler ist aufgetreten" beschränkt. Drei Ausprägungen:

- `catch (e: int64)` — die Form aus `ebnf.md` §12 — wies der Parser ab
  (`expected ), got :`),
- `catch (e)` parste, band aber nichts (`undefined symbol 'e'`),
- gab es außen ein gleichnamiges `e`, **übersetzte es und lief** — und las
  still dessen alten Wert. Der Repro gab `0` aus statt `5`.

Der Parser las den Bezeichner und warf ihn weg (`// currently just consumes
type name`). Jetzt trägt `NK_CATCH` den Namen in `sVal` und die Typangabe in
`c1`; sema legt für den catch-Block einen eigenen Gültigkeitsbereich an und
bindet den Namen darin; der Codegen gibt der Bindung einen Stack-Slot und
schreibt den geworfenen Wert (aus `CG_EXN_VAL`) hinein. Eine gleichnamige
äußere Variable ist im Rumpf verdeckt und danach wieder sichtbar.

Ohne Typangabe gilt `int64` — der geworfene Wert ist das rohe Maschinenwort.
Ein unbekannter Typ in der Klausel wird gemeldet.

**Die Typangabe wählt nicht aus.** Der geworfene Wert trägt keine
Typkennung; mehrere `catch`-Klauseln liefen deshalb bisher **alle
nacheinander**. Das wird jetzt gemeldet statt still getan — die neue
Typangabe legt die Auswahl sonst erst recht nahe.

`tests/catch_binding_test.sh`: 13 Prüfungen. `tests/feature_checks/exceptions/
test_try_catch` ist von `suite-broken.txt` nach `suite-full.txt` gewandert
(Vollsuite 285 → 286 grün). `ebnf.md` §12 nachgezogen: Typangabe optional,
`finally` ergänzt, keine Auswahl. Kein Versionsbump; S3 == S4 unverändert.

### Compiler — `self` als Parametername wird gemeldet statt zu segfaulten (#1144)

`self` ist in Lyx der **implizite** Empfänger einer Methode. Als Variablenname
wies der Parser ihn seit BUG-8 zurück, als Parametername ließ er ihn durch:

```lyx
type P = class {
    a: int64;
    fn Get(self: P): int64 { return self.a; }   // Exit 139, ohne Meldung
};
```

Der Parameter verdeckte die Bindung, jeder Feldzugriff griff ins Leere, das
Programm starb mit SIGSEGV — schweigend. Der Fall trifft alle, die die
Signatur aus Python oder Rust übernehmen. Jetzt:

```
Parse error: 'self' is a reserved keyword and cannot be used as a parameter name
```

Die Prüfung sitzt an beiden Stellen: im Parser (`_parseParam`) und in sema
(`_checkFuncDecl`, Parameter-Registrierung), damit sie auch dann greift, wenn
die Deklaration nicht über den Parser kommt.

**Zu `super`,** das im Issue mitvermutet wurde: der Defekt besteht dort nicht.
`super` ist ein eigener Token-Typ, den `Expect(TK_IDENT)` in der
Parameterliste bereits abweist. `tests/self_param_test.sh` hält das fest,
damit ein späterer Umbau zum weichen Schlüsselwort die Lücke nicht unbemerkt
aufreißt.

`tests/self_param_test.sh`: 12 Prüfungen. Kein Versionsbump, keine
Codegen-Änderung (S3 == S4 unverändert).

### Compiler — Print druckt Verkettungen als Text, Operatoren prüfen ihre Typen (#1143)

**Zur Prämisse des Issues.** `"a" + "b"` verkettet — und zwar richtig. Der
Codegen erkennt zwei `pchar`-Operanden an `+` und emittiert `StrConcat`;
`tests/regression/test_string_format.lyx` lebt davon. Der Repro

```lyx
PrintLn("Wert: " + IntToStr(7));   // gab 130895145168896 aus
```

gab nur deshalb eine Zahl aus, weil `cg_inferPrintType` eine Verkettung nicht
als Zeichenkette einstufte und `Print`/`PrintLn` sie folglich als Ganzzahl
ausgaben. Der Fehler saß im **Drucker**, nicht im Operator. Behoben: derselbe
Ausdruck druckt jetzt `Wert: 7`. Ein Aufruf wurde seit #1058 schon richtig
eingestuft, der Binop-Fall fehlte.

**Typprüfung der Operatoren.** Das Gegenstück zu #1135 (dort Zuweisung,
Rückgabe, Argumente). `pchar` und `bool` sind in einer Rechnung keine
Ganzzahlen:

```
sema error (line 3): Operator +: bool und int64
sema error (line 3): Operator *: pchar und int64 (verkettet wird mit + oder StrConcat; fuer die Adresse `as int64`)
```

Zugelassen bleibt, was die Sprache umgesetzt hat: die Verkettung
`pchar + pchar`, die Zeigerarithmetik `pchar ± int64` (807 Fundstellen im
Bestand) und die boolesche Algebra `^ & |` auf zwei Wahrheitswerten
(`tests/regression/operators/simple_xor.lyx`). Geurteilt wird nur, wenn beide
Typen bestimmt sind — Unbekanntes bleibt still, wie bei #1135. Die Zahl der
sema-Meldungen im Bestand ist vor und nach der Änderung dieselbe (727).

**Nicht enthalten:** gemischte int/f64-Arithmetik. `10 - 2.5` rechnet falsch,
das ist #1212 — ob dort gemeldet oder hochgezogen wird, ist eine
Sprachentscheidung, der eine Meldung hier vorgreifen würde.

`tests/binop_types_test.sh`: 28 Prüfungen, 11 davon rot gegen den Vorstand.

### Compiler — `@redundant` wirkt auch an Globals, `--verify-tmr` prüft (#1141)

Die Sache lag zweigeteilt: **lokal** funktionierte TMR (drei Kopien im Rahmen,
Lesen über die Mehrheitsentscheidung, Schreiben in alle drei — WP-B1),
**global** wirkte `@redundant` gar nicht. Die Variable bekam acht Byte im
Datensegment, keinen Voter, keine Kopien und keinen Hinweis. Auf Modulebene
war das Attribut ein stiller Default — und der Repro des Issues ist genau so
eine globale Variable.

Jetzt bekommen Globals drei Zellen hintereinander (A, B, C), der Anfangswert
steht in allen dreien (sonst wäre die Mehrheit beim ersten Lesen 0 und der
Initialisierer verloren). Lesen und Schreiben laufen über je eine Stelle im
Codegen — dieselbe, die auch die Bilanz zählt.

**`--verify-tmr`** gab es bisher nicht; das Flag fiel unter #1098 (unbekannte
Flags werden stillschweigend ignoriert). Es druckt die Bilanz

```
TMR: 1 @redundant-Variable(n), 2 gevotete(r) Lesezugriff(e), 1 dreifache(r) Schreibzugriff(e), 0 am Voter vorbei
```

und ist **kein bloßer Bericht**: geht auch nur ein Zugriff am Voter vorbei,
schlägt der Lauf mit Exit 1 fehl und es entsteht keine Binary.

Der einzige solche Weg ist die Adresse-von-Form `@x`. Sie liefert die Adresse
*einer* Kopie; ein Schreibzugriff darüber geht beim nächsten
Mehrheitsentscheid verloren. Ohne das Flag wird derselbe Fall gewarnt —
stillschweigend durchlassen wäre das Gegenteil dessen, was das Attribut
zusagt, abbrechen ohne ausdrückliche Prüfbitte zu scharf.

Nebenbei belegt: der Voter *heilt*. Wird gezielt eine Kopie verfälscht,
liefert das Lesen den richtigen Wert und schreibt die Minderheit zurück.

`tests/verify_tmr_test.sh`: 17 Prüfungen, 9 davon rot gegen 1.0.14M.

### Compiler — `@flight_crit` schaltet die FPU-Traps frei (#1140)

`sprache/datentypen.txt` sagt zu, dass in `@flight_crit`-Code jede entstehende
NaN/Inf-Operation `panic` auslöst statt still weiterzulaufen. Bis 1.0.14L
geschah nichts: `1.0 / 0.0` lieferte still `+Inf`.

**Umsetzung: MXCSR.** Der Prolog der annotierten Funktion sichert MXCSR und
löscht die Masken für *invalid* (Bit 7) und *divide-by-zero* (Bit 9); der
Epilog schreibt den alten Wert zurück — an der einen Stelle, an der jede
Rückkehr vorbeikommt.

**Reichweite: dynamisch.** MXCSR ist Thread-Zustand. Ab dem Eintritt gilt der
Trap deshalb auch für alles, was die Funktion *ruft*, bis sie zurückkehrt. Ein
Maskieren vor jedem Aufruf würde die Zusage an der ersten Funktionsgrenze
enden lassen.

**Der Handler kommt mit.** Ohne ihn stürbe das Programm wortlos, was für einen
Nachweis zu wenig wäre. Der Compiler emittiert `__lyx_fc_handler` samt
Restorer und hängt ihn in `main` ein; ein Zeiger auf den Funktionsnamen liegt
in `_lyx_fc_name` (alter Wert im Rahmen, damit Schachtelung trägt):

```
panic: FPU-Ausnahme (NaN/Inf oder Division durch 0) unter @flight_crit in `F`
exit 134
```

Der Text nennt beide Anlässe: SIGFPE kommt auch von einer ganzzahligen
Division durch 0 (#DE), und „nur NaN/Inf" wäre dort falsch. Ohne das Attribut
stirbt derselbe Fall weiterhin wortlos mit Signal 8 — der Handler wird nur
eingehängt, wenn das Programm eine `@flight_crit`-Funktion hat.

Gilt auch für **Methoden**. Nicht erfasst: Überlauf, Unterlauf und
Ungenauigkeit bleiben maskiert — zugesagt sind NaN und Inf, nicht jede
IEEE-Ausnahme.

Nebenbefund: `SA_RESTORER` ist auf x86-64 Pflicht. `std/signals.lyx` setzt es
nicht (`sa_restorer = 0` mit dem Kommentar „Kernel nutzt vDSO"); ein damit
registrierter Handler bringt das Programm beim ersten Signal zum Absturz.
Eigenes Issue #1267.

`tests/flight_crit_test.sh`: 15 Prüfungen, 8 davon rot gegen 1.0.14L.

### Compiler — `@wcet` wird nachgewiesen (#1139)

Auch dieses Attribut war ein bloßer Vermerk. Jetzt zählt der Compiler die
Iterationen des Rumpfes gegen die Schranke:

```
error: Endlos: @wcet(10) verletzt — der Rumpf laeuft bis zu 1000000 Iterationen
```

**Einheit: Iterationen, nicht Zyklen.** Eine Zyklenzahl bräuchte ein
Mikroarchitekturmodell; jede Zahl in einer Kostentabelle wäre erfunden und
damit ein Beweisanschein. Iterationen sind das, was sich am Baum abzählen
lässt. Gezählt wird kumulativ: eine Schleife mit Schranke B, in deren Rumpf I
Iterationen stecken, trägt `B * (1 + I)` bei — zwei geschachtelte
Zehnerschleifen ergeben 110.

**Abzählbar** sind `for ... to`/`downto` und `for i in a..b` mit literalen
Grenzen, `for i in range(A, B)`, `while (c) limit(N)` (die Sprache hat die
Form seit #1103) und `while (i < C)` mit literalem Startwert des Zählers,
konstanter Grenze und genau einer Fortschaltung `i := i + K`, K > 0.

**Nicht nachweisbar ist ein Fehler**, kein stiller Durchlass: berechnete
Schleifengrenzen, `repeat/until`, das C-artige `for`, Rekursion (auch
indirekt, über den Aufrufgraphen) und der Aufruf einer Funktion ohne eigene
Schranke. Trägt der Gerufene selbst ein `@wcet`, geht dessen N in die Summe
ein. Kostenfrei sind allein `peek8/16/32/64`, `poke8/16/32/64` und `exit`;
die Liste steht in `src/frontend/wcet.lyx` und in §20.1, damit sie
nachprüfbar bleibt statt als stiller Default zu wirken. Importierte
Funktionen liegen nicht vor — `PrintLn` in einer `@wcet`-Funktion wird
abgewiesen.

Gilt auch für **Methoden**: dort belegen die Modifier-Bits die `iVal`, der
Wert braucht deshalb einen eigenen Zweig im Parser. Ohne ihn wäre das
Attribut an einer Methode angenommen und nie geprüft worden.

Nicht enthalten: Attribute an *geschachtelten* Funktionen kommen gar nicht
erst durch den Parser (`undefined function 'wcet'`) — das gilt für alle
Attribute außer `@energy` und ist älter als diese Änderung; eigenes Issue
#1261.

`tests/wcet_test.sh`: 30 Prüfungen, 14 davon rot gegen 1.0.14K.

### Compiler — `@stack_limit` wird nachgewiesen (#1138)

Das Attribut war ein bloßer Vermerk: seit #1099 meldete jedes Vorkommen, dass
der Compiler die Zusicherung **nicht** nachweist. Jetzt prüfen zwei Teile:

**Rahmengröße.** Der Codegen kennt sie, wenn er `sub rsp, imm32` patcht. Ist
der Rahmen größer als die Schranke, ist die Zusage schon für *einen* Aufruf
verletzt:

```
error: Viele: @stack_limit(16) verletzt — der Rahmen belegt 48 Byte
```

**Rekursion.** Ohne nachweisbare Aufruftiefe ist der Gesamtverbrauch
unbeschränkt. Der vorhandene Aufrufgraph (`src/ir_call_graph.lyx`) erkennt
auch **indirekte** Zyklen; gebaut wird er nur, wenn das Attribut im Programm
überhaupt vorkommt:

```
error: Tief: @stack_limit ist mit Rekursion nicht nachweisbar — die Aufruftiefe ist unbeschraenkt
```

Damit der Codegen die Schranke kennt, reicht der Parser den Wert jetzt durch
(Bits 16–39 von `iVal`, wie `@energy` seine Stufe in Bits 8–10). Die Einheit
ist **Byte** — das ist die Einheit, in der der Compiler rechnet.

**Wichtig für die Erwartung:** ein `var puffer: int64[4096]` liegt in Lyx
*nicht* im Rahmen. Arrays bekommen einen Heap-Block, der Slot hält den Zeiger;
der Rahmen wächst nur um 8 Byte je Variable. Der Repro aus dem Issue wird
deshalb wegen der **Rekursion** abgewiesen, nicht wegen des Puffers.

Nicht erfasst: der Verbrauch der aufgerufenen Funktionen entlang der
Aufrufkette und dynamisch angeforderter Speicher. Beides steht in §20.1.

`@stack_limit` ist aus der Liste „Attribute ohne Nachweis" gestrichen; `@wcet`,
`@integrity`, `@flight_crit`, `@dal` und `@critical` melden weiterhin.

Neu: `tests/stack_limit_test.sh` (12 Prüfungen, davon 6 gegen 1.0.14J rot).


### Compiler — Zeilennummern in allen Meldungen; Linter wieder lesbar (#1137)

Der Befund im Issue lautete „der Linter meldet nichts". Er meldete sehr wohl —
nur unbrauchbar, und die Meldungen landeten zerrissen auf zwei Strömen:

```
datei:: W004 function should use PascalCase naming
datei:: W006 unreachable code after return statement mai
```

**Vier Fehler kamen zusammen:**

1. Die **Zeilennummer** ging über `PrintInt` auf **stdout**, während der Rest
   der Meldung auf stderr geht. Auf stderr blieb `datei::` übrig, die Ziffern
   standen zusammenhanglos in der Programmausgabe.
2. Zehn Meldungstexte wurden mit **handgezählter Länge** geschrieben, acht
   davon falsch — mal abgeschnitten, mal über das Ende hinaus.
3. `lnt_warn` bekam von den einen Aufrufern einen **Knoten**, von den anderen
   eine fertige **Zeile**, schickte aber alles durch `lnt_lineOf` — die Zeile
   wurde als Knotenindex gedeutet.
4. **Die Wurzel, und die weicht weit über den Linter hinaus:** im Parser bekam
   jedes Token die Zeile des **vorigen**. `_tokenize` las `lx.line` *vor*
   `Next()`. Innerhalb einer Zeile fällt das nicht auf, beim ersten Token einer
   neuen Zeile aber schon — und zwar um so viele Zeilen, wie dazwischen leer
   waren. Eine Funktion in Zeile 5 nach drei Leerzeilen wurde als Zeile 1
   gemeldet, **auch von sema**.

Dazu zwei Prüfungen, die *immer* meldeten und damit reines Rauschen waren:
`W004` nahm `main` nicht aus (Zeigervergleich statt Inhaltsvergleich), und
`W016` verglich Funktions- gegen Modulnamen und konnte nie treffen — jeder
Import galt als unbenutzt. W016 ist abgeschaltet, bis es eine tragfähige
Fassung gibt (die braucht die Zuordnung Symbol → Unit, die sema hat).

`--lint` unterdrückt **keine** Warnungen; die Grant-Warnung stand immer auf
stdout, die Lint-Meldungen auf stderr. Der Eindruck im Issue entstand durch
diese Trennung.

Neu: `tests/lint_output_test.sh` (14 Prüfungen, davon 8 gegen 1.0.14I rot).


### Compiler — die Typprüfung gilt jetzt ohne Ausnahme (#1221 abgeschlossen, #1135 vollständig)

Der letzte Schritt: die Ausnahme in `_typeMismatch` ist entfernt. Eine
Zeichenkette in einem Ganzzahl-Ziel wird gemeldet — der **Haupt-Repro aus
#1135**:

```lyx
var x: int64 := "text";   // sema error: Initialisierung: int64 erwartet, pchar gegeben
fn F(): int64 { return "text"; }        // Rueckgabe: …
fn G(a: int64): int64 { … }  G("x")     // Argument: …
```

Möglich wurde das durch #1221 in fünf Schritten: 470 Fundstellen in 16
Dateien tragen jetzt `pchar`, wo eine Zeichenkette gemeint ist. Dazu kamen
zwölf Stellen in Testdateien und drei im Compiler selbst
(`WriteElf64`/`WritePE64`/`WriteMachO64` nehmen einen Dateinamen).

Damit gilt die Zusage aus der Dokumentation endlich ohne Einschränkung:
*„Implizite Konvertierungen gibt es nicht — alle Typumwandlungen müssen mit
dem `as`-Operator explizit geschrieben werden."*

Weiterhin zugelassen: der `as`-Cast selbst und die Null in einem
`pchar`-Ziel (Nullzeiger).

`tests/type_check_test.sh` ist auf 21 Prüfungen gewachsen; der Fall, der
dort bis eben als „bleibt zulässig" stand, ist jetzt ein Fehlerfall.


### stdlib — `data/core.lyx` benennt Spaltennamen als `pchar` (#1221, Schritt 5 von 5)

Der letzte und tiefste Schritt: Spaltennamen, Schlüssel und Labels hießen
`int64`, obwohl der Quelltext selbst es besser wusste —

```lyx
name: int64;          // Pointer to column name (pchar)
```

Umgestellt in acht Runden, jede mit sofortiger Nachmessung: die
`DataFrame`-API (`AddColumn`, `GetSeries`, `ColIndex`, `Get/SetInt`,
`Get/SetString`, `Filter`, `Query`, `Explode`, `Pivot`, `JoinRight`,
`JoinOuter`, `GroupBy*`, `GetDummies`, …), die `Series`-Konstruktoren
(`SeriesNewInt64`, `SeriesNewString`, `SeriesNewFloat64`),
`SeriesGet/SetString`, `DataStrLen` und die Zeichenketten-Helfer.

Wo ein Name per `peek64` aus dem Spaltenkopf kommt, steht `as pchar` an der
Aufrufstelle — das ist eine Adresse, und der Cast sagt das.

Die Fundstellen aus #1221 sinken damit auf **12**, und alle zwölf liegen in
**Testdateien**, nicht mehr in der stdlib. Der Weg ist frei, die Ausnahme in
`_typeMismatch` zu entfernen.


### Compiler — Typableitung eines Aufrufs prüft jetzt, welche Funktion sie gefunden hat (#1135)

Die Ausdrucks-Typableitung aus #1135 nahm den Rückgabetyp aus dem Knoten, den
`SymNodeIdx` liefert — ohne zu prüfen, ob dieser Knoten wirklich die gerufene
Funktion ist. Über Modulgrenzen hinweg zeigt der Eintrag auf einen fremden
Baum, und der abgeleitete Typ gehört dann zu irgendeiner anderen Funktion.

Sichtbar wurde es beim Messlauf zu #1221: in `std/cloud/cf/analytics.lyx`
meldete die scharfe Regel 91 Stellen, darunter

```lyx
var path: int64 := alloc(512);   // "Initialisierung: int64 erwartet, pchar gegeben"
```

`alloc` liefert `int64`. **Alle 91 Meldungen dieser Datei waren Fehlalarme.**

**Fix:** derselbe Abgleich, den die Stelligkeitsprüfung seit jeher macht — der
Knoten muss ein `SNK_FUNC_DECL` sein *und* denselben Namen tragen wie der
Aufruf. Sonst gilt der Typ als unbestimmt.

Heute fiel das nicht auf, weil die betroffene Richtung (Zeiger in eine Zahl)
bis zum Abschluss von #1221 ohnehin zugelassen ist. Beim letzten Schritt hätte
es reihenweise falsche Meldungen gegeben.

Die Gesamtzahl der #1221-Fundstellen sinkt dadurch von 148 auf **54**.


### stdlib — `net`-Module benennen Zeichenketten als `pchar` (#1221, Schritt 3 von 5)

Der erste Schritt mit echter Kaskade: `std/net/sip.lyx`, `ldap.lyx`,
`imap.lyx` und `mqtt.lyx`. **273 → 148** Fundstellen; alle vier Dateien
melden 0.

Umgestellt wurden Rückgabetypen (`LDAPGetSASLMechanismName`,
`LDAPErrorToStr`), Schreibhelfer (`SIPWriteStr`, `SIPWriteLit`,
`MQTTWriteString`, `SIPStrLen`, `MQTTStrLen`) und die **öffentliche API**, wo
sie Zeichenketten annimmt: `SIPBuildRegister`, `SIPBuildMessage`,
`SIPBuildOptions`, `SIPRegister`, `SIPSendMessage`, `SIPOptions`,
`MQTTBuildConnect`, `MQTTPublish`, `MQTTBuildSubscribe`,
`MQTTBuildUnsubscribe`, `MQTTConnect`, `MQTTSubscribe`, `MQTTPublishMsg`,
`IMAPBuildTaggedCmd`.

Wo ein **selbst allozierter Puffer** übergeben wird (`uri`, `branch`, `tag`,
`fromTag`, `msg`, `cmdBuf`), steht jetzt `as pchar` an der Aufrufstelle — der
Cast benennt, was dort geschieht: eine Adresse wird als Zeichenkette
weitergereicht.

Eine Umstellung war **falsch und wurde zurückgenommen**: `method` in
`SIPBuildRequestLine` sieht wie ein Textparameter aus, ist aber eine Nummer
(`SIP_METHOD_REGISTER: int64 := 1`). Nur `uri` daneben ist eine Zeichenkette.
Aufgefallen ist es, weil die Meldungszahl nach der Umstellung nicht auf 0 fiel.


### stdlib — Zeichenketten-Parameter in mysql, quic und dns heißen `pchar` (#1221, Schritt 2 von 5)

Drei Parameter, die eine Zeichenkette meinen, hießen `int64`:
`mysqlSendCommand(… data …)`, `QUICBuildConnectionClose(… reason)` und
`dns_lit(… src …)`. Sie heißen jetzt `pchar`; alle drei Dateien sind damit
sauber (281 → 273 Fundstellen).

`std/net/imap.lyx` und `std/net/mqtt.lyx` waren ebenfalls für diesen Schritt
vorgesehen, sind aber **zurückgestellt**: dort kaskadiert die Umstellung in
die öffentliche API (`MQTTPublish`, `MQTTSubscribe`, `IMAPBuildTaggedCmd` und
deren Aufrufer) und in Struct-Felder (`topic: int64; // Pointer to topic
string`). Das gehört zu Schritt 3, wo die übrigen `net`-Module ohnehin mit
ihren Aufrufern umgestellt werden.


### stdlib — Zeichenketten-Rückgaben heißen jetzt `pchar` (#1221, Schritt 1 von 5)

Neun Funktionen in `std/validate/*` und `std/country.lyx` hatten `int64` als
Rückgabetyp und lieferten Zeichenketten:

```lyx
pub fn CreditCardTypeName(cardType: int64): int64 { … return "Visa"; }
```

Sie heißen jetzt `pchar`. Damit fallen **189 der 470** Fundstellen weg, die
der Typprüfung aus #1135 im Weg stehen (470 → 281); `std/validate/*` und
`std/country.lyx` sind vollständig sauber.

Betroffen: `EAN13GetCountry`, `IBANGetCountryName`, `VATGetCountryName`,
`VATGetFormat`, `CreditCardTypeName`, `CountryGetName`, `CountryGetCode`,
`CountryGetCurrency`, `CountryGetRegionName`.

Keine Kaskade: die Aufrufer speichern das Ergebnis in `int64`-Variablen, und
diese Richtung (Zeiger in eine Zahl) bleibt bis zum letzten Schritt zulässig.
Kein Eingriff in den Compiler, keine neue Version — nur Deklarationen.


### Compiler — Deklarationsprüfungen: fehlendes `return`, doppelte Namen (#1135, zweite Stufe)

Drei weitere Lücken aus der Tabelle des Issues, alle mit demselben Muster —
der Compiler nahm etwas an und tat stillschweigend das Naheliegende:

| Fall | vorher | jetzt |
|---|---|---|
| Funktion mit Rückgabetyp ohne `return` | lieferte `0` | `Funktion ohne return, Rueckgabetyp verlangt einen Wert` |
| Variable zweimal im selben Block | die zweite gewann | `Name im selben Block bereits deklariert` |
| Zwei Funktionen gleichen Namens | die erste gewann | `Funktion bereits deklariert` |

Die `return`-Prüfung gilt auch für **Methoden** — die volle Rumpfprüfung läuft
aus Rücksicht auf Altbestand nur bei capability-annotierten Klassen, diese
Frage muss aber überall gestellt werden (wie bei #1090 für `static`).

Sie ist **bewusst keine Flussanalyse**: gemeldet wird nur, wenn im Rumpf
überhaupt kein Ausgang vorkommt — `return`, `throw`, `panic` oder `exit(…)`
(`examples/test_aes_debug.lyx` endet so, und zu Recht).
`if (a > 0) { return 1; }` ohne weiteren Ausgang bleibt damit unbemerkt — das
zu beurteilen braucht eine Pfadbetrachtung, und ein Fehlalarm wäre schlimmer
als die Lücke. Verdecken in einem *inneren* Block bleibt erlaubt, ebenso
gleichnamige Methoden in verschiedenen Klassen und gleichnamige Funktionen in
verschiedenen Units.

**Nicht umgesetzt, mit Begründung:** Arithmetik auf `pchar`. Sie ist im
Bestand legitim — `pchar` *ist* ein Zeiger, und `peek8(src + i)` ist die
übliche zeichenweise Iteration (`std/db/sqlite.lyx` u. a.). Eine Meldung wäre
ein Fehlalarm; der Test hält das ausdrücklich fest.

Neu: `tests/decl_checks_test.sh` (16 Prüfungen, davon 7 gegen 1.0.14F rot).
§20.1 fasst die Reichweite der statischen Prüfungen jetzt zusammen.


### Compiler — Typprüfung bei Initialisierung, Zuweisung, Rückgabe und Argumenten (#1135, erste Stufe)

Geprüft wurden bisher **Namen und Stelligkeit**, nicht aber Typen:
`var x: pchar := 42` übersetzte und stürzte beim ersten Lesen ab, eine
Funktion mit `int64`-Rückgabetyp durfte ein `f64` zurückgeben.

Neu ist eine Ausdrucks-Typableitung in sema (`_inferExprType`) und ihre
Anwendung an vier Stellen: **Initialisierung** mit deklariertem Typ,
**Zuweisung**, **`return`** und **Argumente**. Die Ableitung bleibt bewusst
klein und sicher — sie kennt Literale, Variablen mit deklariertem Typ, den
`as`-Cast und den Rückgabetyp einer im selben Lauf deklarierten Funktion.
Alles andere (Builtins, Importiertes, Feld- und Indexzugriffe,
Methodenaufrufe) bleibt unbestimmt und wird **nicht** gemeldet; sonst bräche
der Bestand an Stellen, an denen der Typ gar nicht bestimmbar ist.

Gemeldet wird jetzt zum Beispiel:

```
sema error (line 2): Initialisierung: pchar erwartet, int64 gegeben
sema error (line 3): Argument: int64 erwartet, f64 gegeben
sema error (line 2): Rueckgabe: int64 erwartet, f64 gegeben
```

**Drei Ausnahmen, jede durch den Bestand erzwungen:**

1. Ein `as`-Cast wird nie bemängelt — er *ist* die ausdrückliche Umwandlung.
2. Eine Zeichenkette in einem **Ganzzahl**-Ziel bleibt zulässig: `int64` ist
   in Lyx zugleich der Zeigertyp, und die stdlib nutzt ihn durchgehend so
   (`pub fn CreditCardTypeName(…): int64 { return "Visa"; }`). Ein Messlauf
   mit scharfer Regel ergab **473 Fundstellen in 16 Dateien** — als #1221
   abgetrennt. Der im Issue genannte Fall `var x: int64 := "text"` bleibt
   deshalb vorerst ungeprüft.
3. Die Null in einem `pchar`-Ziel (`var p: pchar := 0;`) ist der übliche
   Nullzeiger.

Im Bestand angepasst: drei Aufrufe in `std/db/sqlite.lyx`, die einen
`alloc`-Puffer an einen `pchar`-Parameter geben — jetzt mit `as pchar`
geschrieben, also als das benannt, was sie sind.

Nicht enthalten und weiterhin offen (#1135): fehlendes `return` bei
nicht-`void`, Variable zweimal im selben Block, zwei Funktionen gleichen
Namens, Arithmetik auf `pchar`.

Neu: `tests/type_check_test.sh` (17 Prüfungen, davon 9 gegen 1.0.14E rot).


### Compiler — Meldung bei zyklischem Import gab den Dateiinhalt aus (#1134)

```
sema error: zyklischer Import erkannt: za;
pub fn B(): int64 { return 2; }
 → zb;
pub fn A(): int64 { return 1; }
 → …
```

Der Zyklus wurde korrekt erkannt, die Meldung war aber unbrauchbar: bei einer
Unit mit einigen hundert Zeilen stand die halbe Datei darin.

**Ursache:** die Namen im Capability-Graphen zeigen in den **Quelltext** und
sind nicht nullterminiert. `PrintStr` lief bis zum nächsten NUL, also bis zum
Dateiende. Dass Name und Inhalt „gegeneinander verschoben" wirkten, kam daher,
dass die Zeiger in verschiedene Quelltexte zeigen.

**Fix:** Namen mit ihrer Länge schreiben. Dazu führt der DFS jetzt den Weg der
grauen Knoten mit und meldet die ganze **Kette** statt zweier Namen und einer
Auslassung:

```
sema error: zyklischer Import erkannt: zb → za → zb
sema error: zyklischer Import erkannt: cc → ca → cb → cc
```

Neu: `tests/import_cycle_message_test.sh` (13 Prüfungen, davon 6 gegen 1.0.14D
rot). Geprüft wird unter anderem, dass **jedes Kettenglied ein reiner
Unit-Name** ist — eine bloße „enthält `za`"-Prüfung wäre auch vorher grün
gewesen.


### Compiler — Interface-Dispatch lieferte 0 (#1133)

```lyx
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };

var p: P := new P();  p.Zeig();   // 7 — über den Klassentyp
var i: I := p;        i.Zeig();   // 0 — über die Schnittstelle
```

Mit zwei Implementierungen lieferten **beide** 0 — es wurde also nicht die
falsche Methode gewählt, sondern gar keine. Damit war der Zweck von
`interface` nicht nutzbar.

**Ursache:** ein Interface hat Methoden, bekam also ein ganz normales
Klassen-Layout. Seine Signaturen tragen weder `virtual` noch `abstract`, und
so erzeugte der Codegen für jede von ihnen einen **Rumpf** — der leer ist, es
gibt ja keinen. `I_Zeig` bestand aus Prolog, `xor rax,rax`, Epilog. Der Aufruf
über die Interface-Variable fand keinen VMT-Slot (`VMTSLOTS` war 0) und
landete statisch genau dort.

**Fix — Selektoren:** die Namen aller in Interfaces deklarierten Methoden
bekommen je einen festen Slot, den **jede** Klasse an derselben Stelle führt
(ein Vorabpass sammelt sie, bevor die Layouts gebaut werden). Nur so trifft
ein Aufruf, der bloß das Interface kennt, dieselbe Stelle wie einer über die
Klasse. Eine Methode, die einen Selektor erfüllt, braucht kein `virtual` — die
Zusage steckt im `implements` — und trägt ihre Adresse in den Slot ein.
Interfaces bekommen kein Codestück mehr.

Abgedeckt sind mehrere Interfaces an einer Klasse, geerbte und überschriebene
Interface-Methoden, die Mischung mit `virtual`/`override` und Arrays mit
Interface-Elementtyp.

Neu: `tests/interface_dispatch_test.sh` (15 Prüfungen, davon 10 gegen 1.0.14C
rot). `ebnf.md` kannte `interface`/`implements` bisher nur als Schlüsselwörter
— die Grammatik führt beide jetzt (§9), §20.1 hält das Verfahren fest.


### Compiler — Zuweisung an `con` wurde nicht abgewiesen (#1132)

```lyx
con X: int64 := 10;
X := 5;              // übersetzte kommentarlos
```

Die Prüfung gab es nur für `let`/`co` („assignment to let/co binding not
allowed", #1083) und für con-*Parameter* (WP-AS-13) — die con-Deklaration
selbst fiel durch.

Irreführend war vor allem der Unterschied nach Geltungsbereich: eine
**lokale** `con` ließ sich tatsächlich ändern (Ausgabe 5), bei einer
**globalen** verpuffte die Zuweisung, weil der Wert als Immediate im Code
steht (Ausgabe 10). Derselbe Quelltext tat je nach Ort etwas anderes, und
gemeldet wurde nichts.

**Fix:** dieselbe Prüfung wie bei `let`/`co`, anhand der Symbolart `SYM_CON`.
Sie greift in jeder Form der Zuweisung (`:=`, `+=`, `-=`, `++`, `--`) und in
beiden Geltungsbereichen. Lesen und Rechnen mit `con` bleibt unverändert,
ebenso `var`; `let` behält seine eigene Meldung.

Neu: `tests/con_assignment_test.sh` (16 Prüfungen, davon 9 gegen 1.0.14B
rot). §20.1 hält den Schreibschutz der Speicherklassen fest.


### Compiler — explizite Enum-Werte wurden verworfen (#1131, #1157)

```lyx
enum E { A = 10, B = 20 }
E.A   // 4294967296 statt 10   (= 2^32 + 0)
E.B   // 4294967297 statt 20   (= 2^32 + 1)
```

Der angegebene Wert spielte keine Rolle — auch dann nicht, wenn er der
impliziten Zählung entsprach (`A = 0, B = 1`): die 2^32 kam trotzdem oben
drauf. Ein Enum mit expliziten Werten war damit unbrauchbar, und genau die
sind der Zweck der Sache (Protokollkonstanten, Fehlercodes,
Hardware-Register).

**Ursache:** der Wertausdruck hängt am Mitglied als Kind, und
`cg_buildEnumLayout` zählte die Kinder als **Nutzlast**. `payloadCnt` wurde
damit 1, landete in der oberen Hälfte des gepackten Ergebnisses (`{Wert
unten, Nutzlastgröße oben}`), und der Tag blieb der Positionsindex. Eine
Nutzlast gibt es in der Deklaration überhaupt nicht — `EnumMember = Ident
[ "=" IntLiteral ]` (§10); die Musterform `Ok(wert)` wird beim `match`
aufgelöst.

**Fix:** der Wert wird zur Übersetzungszeit gefaltet und als Tag eingetragen;
ein Mitglied ohne eigenen Wert zählt vom vorigen weiter (`A = 5, B, C` ergibt
5, 6, 7 — wie in C). Was zur Übersetzungszeit nicht feststeht, wird gemeldet,
ebenso ein Wert außerhalb von `0..4294967295` — der liefe in die obere Hälfte
und käme als etwas anderem zurück.

Rein implizite Enums waren korrekt und bleiben es.

Neu: `tests/enum_explicit_value_test.sh` (16 Prüfungen, davon 14 gegen
1.0.14A rot). §20.1 hält die Zählregel und die Grenzen fest.


### Compiler — `x in a..b` stürzte ab, `for i in a..b` fehlte (#1129)

```lyx
var i: int64 := 2;
if (i in 0..3) { … }      // Segmentation fault
for i in 0..3 { … }       // Parse error: expected :=, got in
```

**Ursache:** *jedes* `in` lief in den Wörterbuch-Zweig. `_lyx_map_has` bekam
als „Map" das, was der Bereichsknoten hinterließ — kein Zeiger, sondern die
obere Grenze, während die untere unbalanciert auf dem Stack liegen blieb. Der
Ausdruck übersetzte und starb erst beim Laufen; die schlechteste der drei
Möglichkeiten, wie das Issue zu Recht anmerkt.

**Fix:** steht rechts von `in` ein Bereich, wird der Zugehörigkeitstest
erzeugt — Grenzen **einschließlich**, wie beim Bereichsmuster in `match`
(#1113) und beim Bereichstyp (§7); ein offenes Ende (`a..`) ist nach oben
unbeschränkt. Für jede andere rechte Seite gilt unverändert die
Wörterbuch-Zugehörigkeit (`schlüssel in map`).

Dazu die Schleifenform `for i in a..b` als dritte `ForRangeStmt`-Alternative
in Parser und `ebnf.md` §12 — sie läuft auf dieselbe Schleife wie
`for i := a to b`. **Achtung:** `in a..b` schließt die obere Grenze **ein**,
`in range(a, b)` schließt sie **aus**; die beiden Formen sind nicht dasselbe.
`for … in` ohne Bereich und ohne `range(…)` meldet, statt etwas zu raten.

Neu: `tests/in_range_test.sh` (18 Prüfungen, davon 14 gegen 1.0.13S rot).
§20.1 hält das Verhalten von `in` fest.

### Compiler — NaN-Vergleiche folgen IEEE 754 (#1128)

```lyx
var z: f64 := 0.0;
var n: f64 := 0.0 / z;
n == n        // war wahr, muss falsch sein
n != n        // war falsch — das verbreitete NaN-Idiom erkannte nichts
```

`ucomisd` setzt bei einem NaN-Operanden ZF=1, PF=1 **und** CF=1 („unordered").
Von den sechs Vergleichen waren nur `>` und `>=` schon richtig: `seta`/`setae`
verlangen CF=0 und liefern deshalb ohnehin `false`. `sete`, `setb` und `setbe`
lasen dagegen bloß ZF bzw. CF und meldeten wahr.

`<` und `<=` werden jetzt mit vertauschten Operanden als `>`/`>=` gerechnet;
Gleichheit und Ungleichheit prüfen zusätzlich das Paritätsflag (`setnp`/`setp`).
Damit ist jeder Vergleich mit NaN falsch außer `!=` — wie es die Tabelle in
`sprache/datentypen.txt` zusichert.

Gewöhnliche Werte sind unberührt.

Neuer Test: `tests/nan_compare_test.sh`

### Compiler — `f32` lieferte das Bitmuster statt des Werts (#1127)

```lyx
var a: f32 := 1.5;
a as int64        // 4609434218613702656 statt 1
```

`cg_isF64Expr` prüfte den Typnamen ausschließlich gegen `"f64"`. Eine
`f32`-Variable galt damit als Ganzzahl: Arithmetik und `as`-Konversion
arbeiteten auf dem rohen IEEE-754-Bitmuster. `f64` war nie betroffen.

Neu ist `cg_isFloatTypeName`, das beide Namen abdeckt. Umgestellt sind die
Erkennung eines Bezeichners, die Cast-Erkennung, die Registrierung des
Rückgabetyps, die `as`-Konversion (`cvtsi2sd`) und die Typklassifikation.

Eine eigene 32-Bit-Darstellung gibt es weiterhin nicht: `f32` liegt wie `f64`
als double im Register, und Struct-Felder wie Array-Elemente belegen ohnehin
8 Byte. Der Typ dokumentiert damit die Absicht, nicht die Breite.

Neuer Test: `tests/f32_value_test.sh`

### Compiler — `uint64`-Vergleiche liefen signiert (#1126)

```lyx
var a: uint64 := 18446744073709551615;
var b: uint64 := 1;
a > b        // falsch statt wahr
```

Jeder Wert ab 2^63 wurde als negativ gelesen: Der Codegen erzeugte durchgängig
`setl`/`setg` (signiert) statt `setb`/`seta`. Unterhalb von 2^63 fiel das nicht
auf, weil sich beide Lesarten dort nicht unterscheiden — betroffen war also
gerade der Bereich, für den man `uint64` überhaupt wählt: Dateigrößen, Hashes,
Zeitstempel jenseits von 2^63.

`cg_emitBinOp` bekommt den Parameter `cmpUnsigned`. Anders als beim Rechtsshift,
wo allein der linke Operand entscheidet, zählt beim Vergleich, ob **einer** der
beiden vorzeichenlos ist — wie bei den üblichen arithmetischen Konversionen.
Damit greift die Korrektur auch bei `5 < b`, wo der unsignierte Operand rechts
steht.

Der zweite Teil des Issues — schmale Typen wrappen nicht auf ihre Breite — war
bereits mit #1151 erledigt und ist mitgeprüft: `uint8 255 + 1` ergibt `0`,
`int8 127 + 1` ergibt `-128`.

Neuer Test: `tests/unsigned_compare_test.sh`

### Compiler — `>>` auf `int64` war logisch statt arithmetisch (#1125)

```lyx
var a: int64 := -8;
a >> 1        // 9223372036854775804 statt -4
```

Der Shift füllte mit Nullen auf, statt das Vorzeichenbit nachzuziehen. Bei
negativen Werten entstanden riesige positive Zahlen — still, und weil das
Ergebnis riesig positiv ist, folgte typischerweise ein Speicher- oder
Indexfehler statt einer Meldung. Jede Halbierung per Shift (Binärsuche,
Mittelwert, Skalierung) lieferte bei negativen Werten Unsinn.

**Ursache:** eine falsche Kodierung, vom Kommentar daneben verdeckt.

```lyx
self.cg_e8(0x48); self.cg_e8(0xD3); self.cg_e8(0xEB);  // sar rbx, cl (signed)
```

ModRM `0xEB` ist `/5` = **SHR**; `SAR` wäre `/7` = `0xFB`. Der Disassembler
sagte `shr %cl,%rbx`, der Quelltext behauptete `sar`.

**Fix:** `SAR` für vorzeichenbehaftete, `SHR` für vorzeichenlose Typen — der
**linke** Operand entscheidet (`cg_isUnsignedExpr`: deklarierter Typ einer
Variablen, lokal wie global, sowie der `as`-Cast; alles andere gilt als
vorzeichenbehaftet, das ist die Vorgabe von `int64` und die sichere
Antwort). `(a as uint64) >> 1` bleibt damit der ausdrückliche Weg zum
logischen Shift.

Die Übersetzungszeit-Faltung rechnet den Shift jetzt ausdrücklich
(`cg_sarConst`, floor-Division), statt das `>>` des *bauenden* Compilers zu
benutzen — dessen Verhalten war genau der Fehler, der Fixpunkt hätte sonst
davon abgehangen, mit welchem Wirt gebaut wurde.

**Der Bestand stützte sich auf das alte Verhalten** — die Gegenprobe fand
neun Stellen, die den logischen Shift *brauchen*, und fünf Tests wurden davon
rot (`pqc_wp01/04/07/10/11`, SHA3/SHAKE stimmten nicht mehr mit den
NIST-Vektoren überein). Sie fordern ihn jetzt ausdrücklich per `as uint64` an:

- Rotationen `(x << n) | (x >> (64 - n))` in `std/crypto/keccak.lyx`,
  `std/hash.lyx` und `std/zstd.lyx` — `keccak.lyx` hielt die Abhängigkeit
  sogar im Kommentar fest („Lyx >> ist SHR (logisch)").
- Die Konstante-Zeit-Idiome in `std/crypto/ct.lyx` (`(x | -x) >> 63`), die
  Bit 63 *herausziehen* statt es zu schmieren, sowie je eine Stelle in
  `std/hash.lyx` und `src/crypto/lic_ed25519.lyx`.

Byte-Extraktionen der Form `(v >> 56) & 255` sind unberührt: die Maske
entfernt die nachgezogenen Vorzeichenbits ohnehin.

Unverändert: `<<`, Division und Modulo (die waren schon korrekt), sowie die
Maskierung des Shift-Betrags auf 6 Bit (`1 << 64` ergibt `1` — Verhalten der
Hardware, im Issue als Randnotiz und nicht als Fehler geführt).

Neu: `tests/shift_right_signed_test.sh` (17 Prüfungen, davon 10 gegen 1.0.13R
rot).

### Compiler — `@bounds_check(true)` war wirkungslos (#1124)

Die Direktive erzeugte dieselbe Binary wie gar keine Angabe. Wer die
Indexprüfung ausdrücklich anforderte, bekam sie ohne `--runtime-checks`
trotzdem nicht.

**Ursache:** der Vorgabewert. `boundsCheckEnabled` steht auf 1, „angefordert"
und „nicht gesetzt" waren davon nicht zu unterscheiden — der
Emissionszweig fragte nur ab, ob jemand *abgeschaltet* hat. Die Direktive
konnte also ausschließlich in der Richtung `false` wirken.

**Fix:** ein zweites Feld `boundsCheckForced`. `@bounds_check(true)` fordert
die Prüfung an und wirkt damit auch ohne `--runtime-checks`;
`@bounds_check(false)` schaltet sie weiterhin ab, auch *wenn* die Option
gesetzt ist — die Direktive steht näher am Code. Gilt am Dateikopf wie auf
Anweisungsebene, für feste und dynamische Arrays.

Nicht betroffen und schon vorhanden: ein **konstanter** Index außerhalb der
Grenzen wird zur Übersetzungszeit abgewiesen (sema, ohne Schalter), und
`--runtime-checks` prüft berechnete Indizes — beides seit #1156. Der
Issue-Text beschrieb den Stand von 1.0.11D, davor.

Neu: `tests/bounds_check_directive_test.sh` (12 Prüfungen, davon 5 gegen
1.0.13Q rot). §20.1 nennt jetzt beide Richtungen der Direktive.

Nicht enthalten: der Nebenbefund zu `Map<K,V>` (deklarierbar, aber ohne
Zugriffsfunktionen) — als #1205 geführt.

### Compiler — Struct-Elemente in Tupeln gingen verloren (#1122)

```lyx
type S = struct { v: int64; };
fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); }
var a, b := F();   // a.v = 0 (erwartet 3), b = 4
```

Kein Müllwert wie bei #1121, sondern konstant `0` — und ohne jede Meldung.
Betroffen war jede Position und jede Anzahl: `(S, int64)`, `(int64, S)`,
`(S, S)`.

**Ursache:** der Zeiger kam die ganze Zeit korrekt an —
`tests/wp04_geo_tuple.lyx` prüft genau das und war grün. Was fehlte, war der
**Typ** am entpackten Namen: die Schreibweise `var a, b := F();` trägt keine
Annotation, der Slot blieb also typlos, `cg_objClassIdx` fand keine Klasse,
der Feldzugriff bekam Offset `-1` und `cg_genFieldLoad` nullte `rax`. Ein
stiller Default an der Stelle, an der ein unbekanntes Feld hätte auffallen
müssen.

**Fix:** eine Registry der Tupel-Elementtypen je Funktion bzw. je gemangelter
Methode (`cg_registerTupleRet`/`cg_findTupleRet`), gefüllt im selben
Vorabpass, der die übrigen Rückgabetypen sammelt. `cg_genTupleVarDecl`
überträgt sie auf die beiden Namen. Erfasst sind freie Funktionen, Methoden,
geerbte Methoden (der Rückgabetyp steht beim Elternteil, #1120) und
`TypeName.M()`. Ist der Aufgerufene dem Codegen unbekannt (importiert,
Builtin), bleibt der Name typlos wie bisher.

**Stelligkeit:** Tupel haben genau **zwei** Elemente — die Aufrufkonvention
trägt zwei Rückgabewerte (`rax`, `rdx`). Der Compiler wies mehr schon ab
(#1088), die Grammatik in `ebnf.md` §7 nannte aber `{ "," Type }`. Beide
sagen jetzt dasselbe; die Abweichung ist in §20.1 vermerkt. Ein N-Tupel
bräuchte eine Rückgabe über Speicher plus ein N-stelliges Entpacken — das ist
ein eigener Umbau und hier nicht enthalten.

Neu: `tests/tuple_struct_elem_test.sh` (16 Prüfungen, davon 9 gegen 1.0.13P
rot).

### Compiler — Tupel-Rückgabe aus Methoden lieferte Müll (#1121)

```lyx
type C = class { v: int64; fn Pair(): (int64, int64) { return (3, 6); } };
var a, b := c.Pair();   // a = 3, b = 140726350547195
```

Der zweite Wert war Speichermüll — wechselnd, adressartig, ohne jede Meldung
beim Übersetzen. Bei freien Funktionen lief dieselbe Rückgabe seit #1088
korrekt; betroffen waren alle Methodenarten (Klasse, `struct`, `static`,
`virtual`).

**Ursache:** nicht die im Issue vermutete Registerkonkurrenz zwischen `self`
und der Zwei-Register-Rückgabe, sondern eine nicht mitgezogene Kopie.
`cg_genFuncDecl` erkennt den Tupel-Rückgabetyp und setzt
`funcHasTupleReturn`; `cg_genMethodDecl` tat das nie. Ohne die Merkung legte
`return (3, 6)` nur `rax` an — `rdx` trug, was zufällig darin stand, und der
Aufrufer las daraus seinen zweiten Wert. Die Merkung blieb dabei auf dem
Stand der zuletzt übersetzten *Funktion* stehen, weshalb der Fehler mal
plausibel und mal offensichtlich aussah.

**Fix:** dieselbe Erkennung in `cg_genMethodDecl`. Der Parser baut eine
Methode als gewöhnlichen Funktionsknoten (`ParseFuncDecl`), der
Rückgabetyp steht also ebenfalls in `c1`.

Neu: `tests/method_tuple_return_test.sh` (14 Prüfungen, davon 11 gegen
1.0.13O rot). Geprüft werden beide Rückgabewerte **einzeln** — ein Test auf
ihre Summe könnte durch zufällig passenden Müll grün werden.

Unverändert: Tupel mit mehr als zwei Elementen lehnt der Parser weiterhin ab
(„Tupel mit mehr als zwei Elementen wird nicht unterstuetzt"), die SysV-ABI
gibt zwei Werte in `rax`/`rdx` zurück.

### Compiler — geerbte nicht-virtuelle Methode nicht aufrufbar (#1120)

```lyx
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { };
var b: B := new B(); b.G();
// error: undefined function 'B_G' — no codegen implementation found
```

Der Aufruf wurde auf den gemangelten Namen der **statischen** Klasse des
Empfängers abgebildet. Anders als die Felder wird eine Methode aber nicht in
die abgeleitete Klasse kopiert — der Rumpf steht unter `A_G`, ein `B_G` gibt
es nie. Die Meldung nannte damit einen Namen, den niemand geschrieben hat,
und der einzige Ausweg war, jede geerbte Methode `virtual` zu machen (nur
dann lief der Aufruf über die VMT), auch wo keine Überschreibung vorgesehen
war.

**Fix:** das Klassen-Layout führt jetzt die je Klasse *deklarierten*
Methoden mit (`CG_CLASS_OFF_METHLIST`/`METHCNT`) — `VMTLIST` kannte nur die
virtuellen, damit ließ sich nicht feststellen, welche Klasse der Kette eine
Methode definiert. `cg_findMethodOwner` läuft die Kette über
`CG_CLASS_OFF_PARENTIDX` hoch, dieselbe, die `cg_isDescendantClass` schon
benutzt, und der Aufruf mangelt auf die gefundene Klasse.

Die *näheste* Definition gewinnt: bei `A → B → C` mit `G` in A und B trifft
`c.G()` die von B. Findet sich nichts in der Kette, bleibt es beim statischen
Namen und der Abbruch meldet ihn wie bisher — kein stiller Default.
`virtual` bleibt spät gebunden, `super.G()` geht weiter direkt zur
Elternimplementierung (#1091). Cross-Module vererbte Methoden funktionieren
ebenfalls.

Neu: `tests/inherited_method_call_test.sh` (14 Prüfungen, davon 7 gegen
1.0.13N rot).

### Compiler — `defer` lief auf zwei Ausgängen nicht (#1118)

`defer` wurde bislang nur beim regulären Blockende und bei `return`
abgearbeitet. Zwei Ausgänge übersprangen ihn:

```lyx
try { defer Print("d"c); throw 1; }
catch { Print("c"c); }
// erwartet: dc     tatsächlich: c

switch (x) {
  case 1: { defer Print("a"c); Print("n"c); break; }
}
// erwartet: na     tatsächlich: n
```

Genau im Fehlerfall unterblieb also die Freigabe — der Zweck von `defer`.
Der `switch`-Fall wiegt zusätzlich, weil der Compiler in jedem Zweig `break`
oder `return` **erzwingt** („switch case may fall through"): der defekte
Pfad war der vorgeschriebene.

**Ursache:** die fehlende Ebene, nicht eine falsche Rechnung. Für Schleifen
gibt es seit #1006 die Marke `loopDeferMark` — den Stand des defer-Stapels
beim Schleifeneintritt, bis zu dem `break`/`continue` vor dem Sprung
abräumen. Für `try` existierte keine Entsprechung, und `cg_genSwitch` setzte
die Marke nie, sodass der `break` dort mit der Marke der *umgebenden*
Schleife (oder −1) lief.

**Fix:** ein `tryDeferMark` analog zu `loopDeferMark`, um den try-Rumpf
gesetzt und geschachtelt gerettet; `throw` arbeitet vor dem `longjmp` bis
dorthin ab (den geworfenen Wert in `rax` über `push`/`pop` gerettet).
`cg_genSwitch` und `cg_genMatch` setzen `loopDeferMark` auf den Eintritt
ihres Zweigs, womit der bestehende `break`-Pfad greift.

Ein `defer` **vor** dem `try` bleibt liegen, verschachtelte `try` räumen nur
ihren eigenen Block ab, und ein `switch` innerhalb einer Schleife lässt die
Schleifen-defers unberührt — vorher liefen die bei jedem `break` im Zweig
zusätzlich, also doppelt.

Nicht enthalten: `catch` bindet den geworfenen Wert nicht (`catch (e)` →
„undefined symbol", `catch (e: int64)` → Parse-Fehler), obwohl ebnf.md §12
die Bindung vorsieht. Eigene Lücke, eigenes Issue.

Neu: `tests/defer_exit_paths_test.sh` (16 Prüfungen, misst die Reihenfolge
der Ausgaben — 8 davon waren gegen 1.0.13M rot).

## Version 1.0.13M (August 2026)

### Compiler — das vierte Syscall-Argument lag im falschen Register (#1192)

`sendto` bekam als Flags-Maske, was zufällig in `r10` stand:

```
sendto(3, "…", 33, MSG_OOB|MSG_CTRUNC|MSG_TRUNC|MSG_DONTWAIT|…|0x19400000, …) = -1 EOPNOTSUPP
```

Der Wert wechselte von Lauf zu Lauf — deshalb mal Timeout (ohne
`MSG_DONTWAIT` blockiert der Aufruf), mal sofortiger Fehler (`MSG_OOB` →
`EOPNOTSUPP`). Betroffen war jede Namensauflösung über `std.net.dns`, damit
`GetHostByName`, `HTTPGet` und `HTTPSGet`.

**Ursache:** die Argumente eines Intrinsics kommen nach C-Konvention an —
`rdi`, `rsi`, `rdx`, **`rcx`**, `r8`, `r9`. Der Linux-*Syscall* nimmt das
vierte aber in **`r10`**. Wer das `mov r10, rcx` vergisst, lässt dort stehen,
was vorher drin war.

**Systematisch geprüft statt einzeln nachgetragen.** Ein Abgleich über alle
35 Intrinsics mit vier oder mehr Argumenten zeigt: genau zwei fehlten,
`sendto` (44) und `recvfrom` (45). `wait4` nullt `r10` absichtlich
(`rusage = NULL`), alle übrigen setzen es korrekt. Die Vermutung im Issue —
„die 6-Argument-Konvention an sich scheint zu stehen" — trifft also zu.

**Beim Testen mitgefunden:** `sys_send`/`sys_recv` teilten sich den Zweig mit
`sendto`/`recvfrom`. Auf x86-64 gibt es `send` aber nicht als eigene Nummer;
der Kernel kennt nur `sendto`, und die fehlenden zwei Argumente (`addr`,
`addrlen`) müssen **NULL** sein. Sie enthielten stattdessen Reste, und der
Aufruf scheiterte mit `EINVAL`. Beide haben jetzt einen eigenen Zweig, der
`r8`/`r9` nullt.

`tests/syscall_r10_test.sh` (5 Prüfungen, in `make test`) kommt **ohne
externes Netz** aus — zwei UDP-Sockets auf `127.0.0.1`. Geprüft wird das
Ergebnis des Aufrufs samt Timeout, denn der Fehler zeigte sich auch als
Hängen. Ein Fall prüft, dass die Flags nicht nur `0` sind, sondern **wirken**:
`MSG_DONTWAIT` auf einem leeren Socket muss sofort `EAGAIN` liefern. Gegen den
Vorgängerstand: 2 PASS, 3 FAIL.

Nachweis der Auswirkung — `GetHostByName("one.one.one.one")`:

| | Ergebnis |
|---|---|
| vorher | `0` (fehlgeschlagen) |
| jetzt | `16843009` = 1.1.1.1 |

Zusammen mit #1193 ist HTTPS damit auf beiden Wegen frei.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`647e2d3a…`).

## Version 1.0.13L (August 2026)

### Sicherheit — `setsockopt` fehlte bei den Netzwerk-Capabilities (#1193)

Der TLS-Handshake starb mit `SIGSYS`: `sys_socket` und `sys_connect` waren
erlaubt, `sys_setsockopt` (54) nicht. Damit lief HTTPS auch mit fester IP nicht,
und `std.net.socket` bot vier Funktionen an — `TCPConnSetNodelay`,
`TCPConnSetKeepAlive`, `TCPConnSetRecvBuf`, `TCPConnGetError` —, die alle in
SIGSYS liefen.

Freigegeben mit **jeder** `network.*`-Capability: `setsockopt` (54),
`getsockopt` (55), `getsockname` (51), `getpeername` (52).

Die Abwägung dahinter: diese Aufrufe öffnen keinen neuen Weg nach draußen. Sie
betreffen die **bereits erlaubte** Verbindung — wer sie aufbauen darf, darf
ihre Puffergrößen und Zeitgrenzen einstellen und wissen, mit wem er spricht.
`TCP_ULP`, das OpenSSL beim Handshake setzt, fällt in dieselbe Kategorie.

**Nicht freigegeben: `fcntl` (72)**, obwohl `std.net.socket` es zum
Nicht-Blockierend-Schalten nutzt. `fcntl` wirkt auf jeden Dateideskriptor, nicht
nur auf Sockets — es über eine Netzwerk-Capability zu erlauben, gäbe
stillschweigend auch Operationen auf Dateien frei. Das braucht einen
Argument-Filter auf `cmd` und ist eine eigene Änderung.

### Der Nebenbefund im Issue ist keiner

Das Issue vermutet hinter `setsockopt(3, SOL_TCP, TCP_ULP, [7564404], 4) = 54`
einen zweiten Fehler bei der Argumentübergabe, verwandt mit #1192. Gemessen
trifft das nicht zu — dasselbe Programm einmal mit altem und einmal mit neuem
Compiler unter `strace`:

```
alt:  setsockopt(3, SOL_SOCKET, SO_KEEPALIVE, [1], 4) = 54   +++ killed by SIGSYS +++
neu:  setsockopt(3, SOL_SOCKET, SO_KEEPALIVE, [1], 4) = 0
```

Die **Argumente sind in beiden Fällen identisch und richtig**. Die „54" ist
kein Rückgabewert, sondern die Syscall-Nummer, die `strace` anzeigt, wenn
seccomp den Aufruf mit `KILL` beendet — ein Artefakt des Sterbens, nicht die
Wurzel von #1192.

`tests/seccomp_filter_test.sh` wächst auf 19 Prüfungen: `setsockopt` und
`getsockopt` laufen mit `network.tcp.connect`, und `setsockopt` ohne
Netzwerk-Capability stirbt weiterhin. Gegen den Vorgängerstand: 17 PASS,
2 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`54b73fea…`).

## Version 1.0.13K (August 2026)

### Sprache — Typparameter als Typargument weiterreichen (#1117)

```lyx
fn Id<T>(x: T): T { return x; }
fn Twice<T>(x: T): T { return Id<T>(Id<T>(x)); }
```

Vorher: `sema error: unknown type in generic arguments 'T'`.

`T` war als Parameter- und Rückgabetyp gültig, im **Typargument** eines Aufrufs
aber nicht. Der Aufruf ohne Typargument (`Id(Id(x))`) war der Workaround — die
explizite Weitergabe ist die natürliche Schreibweise, gerade wenn die Inferenz
nicht eindeutig ist.

Die Mechanik lag bereits vor: `_isTypeParamRef` unterscheidet seit #1009 einen
aktiven Typparameter von einem unbekannten Typ, und `_checkFuncDecl` nutzt sie
für Parameter- und Rückgabetypen. In `_resolveGenericCall` fehlte genau diese
eine Frage.

**Der Geltungsbereich bleibt eng:** ein Typparameter gilt nur *innerhalb*
seiner Funktion. `Id<T>(1)` aus `main` heraus wird weiterhin gemeldet, ebenso
ein erfundener Typ im Typargument — auch innerhalb einer generischen Funktion.
Ohne diese Grenze wäre die Ausnahme ein Freibrief für jeden Tippfehler, der
zufällig wie ein Typparameter aussieht.

`tests/generics_typeparam_test.sh` wächst von 9 auf 15 Prüfungen. Die vier
neuen Positivfälle prüfen den **Wert**, nicht die Übersetzbarkeit — eine
Weitergabe, die den falschen Typ instanziiert, würde sonst durchgehen. Dazu
drei Gegenproben. Gegen den Vorgängerstand: 11 PASS, 4 FAIL.

### Dokumentation

Der Nebenbefund aus dem Issue ist erledigt: `ebnf.md` §6 hielt fest, generische
Funktionen seien „auch mit `<T>` nicht nutzbar" — das stimmt seit #1009 nicht
mehr. Der Absatz nennt jetzt, was geht (ein und mehrere Typparameter,
Struct-Typen, Weitergabe des eigenen Typparameters, Geltungsbereich) und was
weiterhin nicht: generische **Typen** (`type Box<T> = struct { v: T; }`).

### Seed

Neu verankert auf den Fixpunkt dieser Version (`2cf9f154…`).

## Version 1.0.13J (August 2026)

### Sicherheit — neue Capability `fs.perm` für Rechteänderungen (#1188)

`chmod` und `chown` waren mit aktivem LCBS **gar nicht erreichbar**: die
Intrinsics gibt es, `std.fs` benutzt sie, aber keine der fünf
Dateisystem-Capabilities deckte sie ab. Jedes Programm mit `@capabilities`
starb dort mit `SIGSYS`, egal welche Rechte es anforderte.

Von den drei in #1188 aufgeführten Wegen ist der additive umgesetzt:

| Capability | Bedeutung |
|---|---|
| `fs.meta` | Metadaten **lesen** (stat, Verzeichnislisting) |
| **`fs.perm`** | **Zugriffsrechte und Eigentümer ändern** (chmod, chown) |

`chmod` an `fs.meta` zu hängen wäre der kleinere Eingriff gewesen und genau
deshalb falsch: wer die Capability anfordert, um ein Verzeichnis aufzulisten,
bekäme stillschweigend das Recht, Zugriffsrechte umzuschreiben. Eine
Ausweitung, die niemand angefordert hat, ist das Gegenteil dessen, wofür ein
Capability-Modell da ist.

Freigegeben werden mit `fs.perm`: `chmod` (90), `fchmod` (91), `fchmodat`
(268), `chown` (92), `fchown` (93), `lchown` (94), `fchownat` (260).

Die Capability ist an allen Stellen registriert, an denen die anderen stehen —
Registry, Namensauflösung, seccomp-Generator, Audit-Report und die
Argument-Whitelist (`fs.perm(path: …)`). Der Audit-Report nannte sie zunächst
`unknown`, weil die Namenstabelle in `src/tooling/audit.lyx` eine eigene Kopie
ist; auch das ist nachgezogen.

`tests/seccomp_filter_test.sh` wächst auf 16 Prüfungen und hält beide
Richtungen fest: `chmod`/`chown` laufen mit `fs.perm` und sterben ohne — auch
mit allen anderen fs-Capabilities zusammen. Dazu die Gegenprobe, dass
`fs.perm` **keine** Dateien öffnet: die Capability gibt Rechte frei, nicht
Inhalte. Gegen den Vorgängerstand: 13 PASS, 3 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`04bd05a9…`).

## Version 1.0.13I (August 2026)

### Sicherheit — seccomp-Filter kannte die emittierten Syscalls nicht (#1185)

Ein Programm mit `@capabilities([… fs.create …])` starb beim ersten `mkdir` mit
`SIGSYS`. Dasselbe bei `unlink` trotz `fs.delete` und bei `rename`. Mit
`--capabilities=compat` — also ohne seccomp — lief derselbe Code durch; es lag
am Filter, nicht am Codegen.

**Ursache:** der Filter kannte nur die `*at`-Varianten (`unlinkat`, `openat`),
der Codegen emittiert aber die **direkten** Formen. `rmdir` war zufällig dabei,
`mkdir` und `unlink` nicht — die Lücke betraf also einzelne Nummern, nicht
ganze Kategorien.

Abgeglichen wurde entlang `capabilities.md`, nicht nach Gefühl:

| Capability | neu freigegeben |
|---|---|
| `fs.create` | `mkdir` (83), `mkdirat` (258), `creat` (85) |
| `fs.delete` | `unlink` (87) |
| `fs.write` | `truncate` (76), `ftruncate` (77), `fsync` (74), `fdatasync` (75) |
| `fs.read` | `readlink` (89), `getcwd` (79) |
| `fs.meta` | `stat` (4), `lstat` (6), `access` (21) |

**`rename` verlangt beide Capabilities.** Umbenennen legt am Ziel an *und*
entfernt an der Quelle — mit nur `fs.create` wäre es ein Weg, ohne `fs.delete`
zu löschen. Der Generator prüft deshalb `fs.create && fs.delete`.

**Basissatz harmloser Introspektion**, immer erlaubt: `getpid`, `gettid`,
`getppid`, `getuid`, `geteuid`, `getgid`, `getegid`. Sie geben Auskunft über
den eigenen Prozess und berühren nichts außerhalb davon. Ohne sie ist eine
extern gelinkte Bibliothek nicht benutzbar: OpenSSL ruft `getpid` beim Init
(RNG-Reseed-Check), womit HTTPS mit aktivem LCBS gar nicht lief.
`clock_gettime` gehört bewusst **nicht** dazu — dafür gibt es `system.time`,
und ein immer erlaubter Zeitzugriff entwertete die Capability.

**Nicht freigegeben: `chmod` und `chown`.** Sie *schreiben* Metadaten;
`fs.meta` deckt laut Doku das *Lesen* ab. Sie an `fs.meta` zu hängen wäre eine
stille Ausweitung für jeden, der die Capability nur zum Auflisten anfordert —
als **#1188** aufgesetzt.

`tests/seccomp_filter_test.sh` (12 Prüfungen, in `make test`) prüft **beide
Richtungen**: dass der erlaubte Aufruf läuft und der nicht gewährte weiterhin
mit `SIGSYS` stirbt. Ein Test, der nur das erste prüft, wäre auch von einem
Filter erfüllt, der alles durchlässt. Gegen den Vorgängerstand: 7 PASS,
5 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`1707b6ec…`).

## Version 1.0.13H (August 2026)

### Compiler — dynamisches Array ohne Initialisierung war null (#1177)

```lyx
var a: Array<int64>;
PrintLn(len(a));      // traf die Null
a[0] := 5;            // schrieb dorthin
```

Betroffen waren alle drei Schreibweisen (`Array<T>`, `array[T]`, `T[]`) und
jeder Elementtyp — das Ausgangs-Issue #1109 schrieb den Absturz fälschlich dem
Struct-Elementtyp zu.

Auffällig war der Widerspruch im Bestand: `int64[N]` wird seit jeher belegt,
`var s: S;` seit WP-10d, und `push` legte **lazy** an — die dynamische
Schreibweise fiel als einzige heraus. Genau das machte auch die Entscheidung
leicht: **abweisen** schied aus, weil `var a: int64[]; push(a, 5);`
nachweislich funktioniert und damit gebrochen wäre.

Die Deklaration legt jetzt dasselbe leere Array an, das `push` sonst beim
ersten Aufruf erzeugt (`cap` = 1024, `len` = 0). `push` findet den Zeiger
gesetzt vor und überspringt seinen eigenen Allokationszweig.

Damit die beiden Stellen nicht auseinanderlaufen können, liegt die Folge jetzt
**einmal** als `cg_emitEmptyDynArray` vor und wird von beiden benutzt — vorher
stand sie ausgeschrieben in `cg_genArrayPush`.

`tests/dyn_array_decl_test.sh` (12 Prüfungen, in `make test`) misst das
Verhalten **vor** dem ersten `push`: `len` liefert 0 statt abzustürzen, der
Zeiger ist gesetzt, ein Schreibzugriff kommt an. Vier Gegenproben: mit
Initialisierung (`= []` und `= [7,8,9]`) darf nicht zusätzlich belegt werden,
und `int64[N]` wie `S[N]` bleiben unberührt. Gegen den Vorgängerstand:
6 PASS, 6 FAIL.

Zu beachten: jede solche Deklaration belegt 8208 Byte — dieselbe Größe, die
`push` bisher beim ersten Aufruf nahm, nur früher. Wer viele dynamische Arrays
deklariert und nie füllt, zahlt das jetzt sofort.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`b37ffe10…`).

## Version 1.0.13G (August 2026)

### Compiler — Array als Funktionsparameter (#1115)

```lyx
fn F(a: int64[4]): int64 { return a[0]; }
```

Der Callee las eine **Adresse** statt eines Werts — bei jedem Index dieselbe,
der Index wirkte also gar nicht. Schreibzugriffe kamen beim Aufrufer nicht an.
Übersetzt wurde ohne Meldung.

**Die Übergabe selbst war in Ordnung.** Der Aufrufer legt den Zeiger auf die
Ablage ins Register; das ließ sich zeigen, indem man ihn als `int64` annahm und
mit `peek64` daraus las. Im Callee fehlte die Merkung *„das ist ein Array"*:
der Prologue wertete den Parametertyp nur für `NK_TYPE_NAME` aus und nicht für
`NK_TYPE_ARRAY_FIXED`, `localIsArray` blieb also 0 — und der Indexzugriff fiel
in den Zweig für einen rohen Zeiger.

Behoben an allen fünf Stellen, an denen ein Parameter abgelegt wird: die sechs
Register-Argumente und die Stack-Argumente, jeweils für freie Funktionen und
für Methoden. Mitgenommen wird auch die deklarierte **Größe** — damit liefert
`len(a)` sie, und die Bereichsprüfung aus #1156 greift jetzt auch am Parameter
— sowie der **Elementtyp**, sonst fände `a[0].feld` die Klasse nicht (#1109).

Semantik: das Array wird als **Zeiger** übergeben, der Callee arbeitet auf
demselben Speicher. Das passt zur Zeiger-Semantik der Struct-Arrays aus #1109
und steht in §20.1.

Im Bestand fiel der Fehler nicht auf, weil `std/` und `src/` **keinen einzigen**
Array-Parameter verwenden — dort laufen Puffer durchgängig als `int64`-Adresse
mit `peek`/`poke`.

`tests/array_param_test.sh` (12 Prüfungen, in `make test`) misst den Wert im
Callee **und** die Wirkung beim Aufrufer, über alle drei Übergabewege
(Register, Stack ab dem siebten Argument, Methode) und mit Struct-Elementtyp.
Zwei Gegenproben: ein `int64`-Parameter bleibt `int64`, und das lokale Array
bleibt unberührt. Gegen den Vorgängerstand: 2 PASS, 10 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`346b61d9…`).

## Version 1.0.13F (August 2026)

### Sprache — Bereichsmuster in `match` (#1113)

```lyx
match (altitude) {
    case 0..500      => { return "Bodennaher Betrieb"; }
    case 501..3000   => { return "Platzrunde / Anflug"; }
    case 3001..10000 => { return "Steigflug"; }
    case 13001..     => { return "Hochflug"; }
    case _           => { return "Ungültig"; }
}
```

Vorher: `Parse error: expected =>, got '..'`.

Ein Feature-Request, kein Bug — §14 sah Bereichsmuster nicht vor. Der Ersatz
war allerdings deutlich schlechter: eine OR-Liste bräuchte für `0..500`
fünfhunderteins Alternativen, und eine `if`-Kette nimmt `match` genau den
Vorteil, für den es da ist. Die Bausteine lagen vor: `..` ist ein etabliertes
Token mit eigener Disambiguierungsregel (§1.1), und die Grenzenauswertung gibt
es seit den Bereichstypen (#1082).

Festgelegt, in §14 dokumentiert:

- Grenzen sind **einschließlich** — `500` trifft noch `0..500`, `501` schon den
  nächsten Zweig. Dieselbe Lesart wie beim Bereichstyp.
- Die **obere** Grenze darf fehlen (`case 13001.. =>`), die untere nicht; so
  steht es in der vorgeschlagenen Produktion `RangeBound ".." [ RangeBound ]`.
- Negative Grenzen sind erlaubt (`case -10..-1`).
- Bei **Überschneidung** gewinnt der erste passende Zweig, wie bei den übrigen
  Mustern; eine **Lücke** zwischen zwei Bändern fällt an den Wildcard und nicht
  an das nächstliegende Band.
- Verdrehte Grenzen (`case 9..1`) werden abgewiesen.

Ein Bereich ist auch als Alternative eines **Or-Musters** (`case 0..9 | 20..29`)
und mit **Guard** verwendbar. Der Or-Fall brauchte eigene Sorgfalt: anders als
der Gleichheitsvergleich prüft ein Bereich zwei Bedingungen, der
Treffer-Sprung darf also erst fallen, wenn beide zusagen.

Erzeugt werden zwei Vergleiche je Bereich, keine Sprungtabelle — das wäre eine
eigene Optimierung.

`tests/match_range_test.sh` (12 Prüfungen, in `make test`) prüft, **welcher
Zweig trifft** — an den Grenzen und daneben. Ein Test auf Übersetzbarkeit
könnte einen Bereich nicht von einem Wildcard unterscheiden. Zwei Gegenproben:
ein Einzelwert-Muster bleibt ein Einzelwert, und `..` außerhalb von Mustern
bleibt der Bereichstyp. Gegen den Vorgängerstand: 2 PASS, 10 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`dad0dfb9…`).

## Version 1.0.13E (August 2026)

### Sicherheit — `dim`/`utype` hatten keine Semantik (#1110)

Einheitentypen wurden geparst und bewirkten nichts. Der Faktor war dekorativ,
die Dimension folgenlos, und der Range-Modifier scheiterte am Parser. Für die
Fehlerklasse, gegen die Einheitentypen antreten — Einheitenverwechslung, Mars
Climate Orbiter — ist eine Annotation, die sie nicht erkennt, irreführend.

**Der Faktor rechnet um.** `var b: M := a` bei `a: Km` ergibt jetzt `2000`
statt `2`. Erst multiplizieren, dann ganzzahlig teilen: `Km` → `M` ist exakt,
`M` → `Km` schneidet ab, wie die Ganzzahldivision sonst auch. §20 führt die
Konversionssemantik ausdrücklich als undefiniert; sie steht jetzt in §20.1.

**Die Dimension wird geprüft.** Abgewiesen werden die Zuweisung über
Dimensionsgrenzen (`var t: S := a` mit `a: Km`), das Addieren zweier
Dimensionen und das Verrechnen mit einer dimensionslosen Zahl (`a + r`).
Erlaubt bleiben, was die Einheit benutzbar hält:

| Form | Grund |
|---|---|
| `var a: Km := 2` | ein Literal ist dimensionslos und muss sich zuweisen lassen |
| `a * 3` | Skalierung behält die Einheit |
| `(a as int64) + r` | der `as`-Cast ist der bewusste Fluchtweg |

Wo die Einheit nicht bestimmbar ist, wird **nichts** gemeldet — unentscheidbar
heißt nicht falsch. Zwei Einheiten miteinander multipliziert ergäbe eine
abgeleitete Dimension; die rechnet der Compiler nicht aus und behauptet
deshalb auch nichts.

**`range` und `wraps` parsen und wirken.** Beide standen seit jeher in §11 und
scheiterten mit `expected ;, got IDENT 'range'`. Jetzt: `range 0..100` bricht
außerhalb mit `panic` ab, `wraps 0..359` rechnet in den Bereich zurück
(`400` → `40`, `-10` → `350`). Grenzen einschließlich, wie beim Bereichstyp;
steht der Wert zur Übersetzungszeit fest, meldet der Compiler ihn sofort
(#1082), und verdrehte Grenzen werden abgewiesen.

`tests/utype_test.sh` (18 Prüfungen, in `make test`) misst das **Verhalten**:
den umgerechneten Wert, die Meldung, den Abbruch bzw. das Umrechnen. Ein Test
auf Übersetzbarkeit wäre bei jedem Punkt grün gewesen. Mit fünf Gegenproben,
ohne die eine Prüfung, die alles abweist, ebenso grün wäre. Gegen den
Vorgängerstand: 5 PASS, 13 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`0cbd64ab…`).

## Version 1.0.13D (August 2026)

### Compiler — Arrays mit Struct- oder Klassen-Elementtyp (#1109)

`var arr: S[3]; arr[0] := s; PrintLn(arr[0].v)` gab **0** statt `1`. Übersetzt
wurde ohne Meldung.

Drei Fehler übereinander, und die ersten beiden verdeckten sich gegenseitig:

1. **Der Elementtyp wurde am Local nicht vermerkt.** Nur `NK_TYPE_NAME`
   führte zu `cg_setLocalType`, `NK_TYPE_ARRAY_FIXED` nicht. Damit fand
   `cg_arrayElemClassIdx` die Klasse nicht, `arr[0].v` bekam Feldoffset -1 und
   lieferte still `0` — der bekannte „unbekanntes Feld → Offset 0"-Fall. Das
   *Element* selbst kam korrekt an: `var q: S := arr[0]` las den richtigen
   Wert. Sichtbar wurde der Fehler also nur über den Feldzugriff.
2. **Die Allokation ließ den `{cap,len}`-Kopf aus.** Angefordert wurden `N*8`
   Byte, der Indexzugriff überspringt aber 16 Byte (`lea rcx,[rax+16]`). Beide
   Seiten waren gleich verschoben, deshalb fiel es bei skalaren Elementen nie
   auf — gedeckt war das allein durch die Seitengröße der `mmap`. Mit
   Zeiger-Slots traf der Zugriff Nullen, und `arr[2].v := 7` schrieb an
   Adresse 0.
3. **Der Index-Operator einer Klasse griff auf das Array zu.** Sobald der
   Elementtyp vermerkt war, hielt `cg_tryClassIndex` die Array-Variable für
   ein Klassenobjekt und machte aus `cs[1]` ein `cs.Get(1)` — mit der
   Array-Basis als Empfänger. Der Index-Operator gehört nur einer Variablen,
   die selbst ein Klassenobjekt *ist*.

**Semantik: Zeiger-Slots.** `arr[i] := s` teilt das Objekt mit `s`, wie die
Struct-Zuweisung sonst auch. Die Slots werden bei der Deklaration mit frischen
Objekten belegt — `arr[0].v := 42` braucht also kein vorheriges `new`, genauso
wie ein `var s: S;` seit WP-10d angelegt wird. Die Vorbelegung läuft als
Laufzeitschleife: `N` steht zwar fest, aber ein `S[1000]` hätte sonst tausend
Kopien derselben Befehlsfolge im Code.

`tests/struct_array_test.sh` (12 Prüfungen, in `make test`) misst den **Wert**
nach dem Schreiben; ein Test auf Übersetzbarkeit wäre grün gewesen, denn
übersetzt wurde immer — nur eben Falsches. Mit Gegenproben: skalare Arrays
unverändert, `len()` unverändert, und der Index-Operator einer Klasse bleibt
überladen. Gegen den Vorgängerstand: 4 PASS, 8 FAIL.

**Nicht enthalten:** `array[T]` und `Array<T>` ohne Initialisierung sind
**null** und stürzen beim Zugriff ab. Das Issue schrieb das dem
Struct-Elementtyp zu — es trifft alle Elementtypen, auch `Array<int64>`, und
ist als **#1177** herausgelöst.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`f0752a14…`).

## Version 1.0.13C (August 2026)

### Sicherheit — Capability-Argumente ohne Wirkung und ohne Prüfung (#1108)

Die Capability-**Ebene** greift: ohne `fs.read` bricht ein Dateizugriff zur
Laufzeit mit SIGSYS ab, und ein erfundener Capability-**Name** wird abgewiesen.
Die **Argumente** waren der blinde Fleck.

**Argumentnamen werden jetzt geprüft.** `fs.read(zzz_arg: "x")` und
`fs.read(pfad: "/tmp")` übersetzten kommentarlos: `ValidateArg` sah nur
Wertebereiche bekannter Schlüssel an und fiel für alles andere auf „in
Ordnung" — und es lief ohnehin nur für Ganzzahlwerte, Zeichenketten kamen dort
nie an. Ein Tippfehler fiel damit doppelt nicht auf: nicht beim Übersetzen, und
zur Laufzeit nicht, weil die Angabe folgenlos bleibt. Gültige Schlüssel:
`path` (`fs.*`, `process.exec`), `host`/`port` (`network.*`), `pin`
(`hardware.gpio`), `bus` (i2c/spi), `cs` (spi), `vendor`/`product` (usb). Ein
Argument an einer Capability, die keine nimmt, wird ebenfalls abgewiesen.

**Die fehlende Wirkung wird gemeldet.** `fs.read(path: "/tmp")` schränkt
nichts ein — die Sandbox wirkt als Ja/Nein: seccomp filtert Syscalls, und
Landlock bekommt **eine** Regel für `/`, in die der genannte Pfad nicht
eingeht. Eine Annotation, die eine Beschränkung ausdrückt und sie nicht
einhält, erzeugt eine Sicherheitszusage, die es nicht gibt — dasselbe Muster
wie bei den Safety-Attributen in #1099, also dieselbe Antwort: melden. Die
Durchsetzung selbst ist als **#1173** herausgelöst; sie ist handgeschriebener
x86-Code an einer Sicherheitsgrenze und braucht einen Test, der die
Verweigerung *misst*.

**PortSpec-Bereich parst.** `"host":8000-9000` stand seit jeher in §22 und
scheiterte am Parser (`expected ), got - '-'`). Der Endport hängt jetzt an `c1`
des `NK_NETWORK_TARGET`; Start > Ende wird abgewiesen.

Randnotiz zum Issue: die dort vermuteten fehlenden `net.*`-Capabilities gibt es
sehr wohl — sie heißen `network.tcp.bind`, `network.tcp.connect`,
`network.udp.*`, `network.unix`, `network.raw`.

`tests/capability_args_test.sh` (14 Prüfungen, in `make test`) misst, was der
Compiler **meldet**. Ein Test auf Übersetzbarkeit wäre bei jedem der drei
Punkte grün gewesen — genau das war der Befund. Gegen den Vorgängerstand:
4 PASS, 10 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`df0c2b09…`).

## Version 1.0.13B (August 2026)

### Compiler — Methodenzeiger als lokale Variable stürzte beim Aufruf ab (#1106)

Ein Methodenzeiger funktionierte als **Klassenfeld** und nicht als **lokale
Variable**. Übersetzt wurde ohne jede Meldung, der Aufruf endete mit Exit 139:

```lyx
var m: TM := f.Handle;
return m(c);          // Speicherzugriffsfehler
```

Die Vermutung im Issue — ein lokaler Slot fasse nur 8 statt der 16 Byte des
Paares `{Code, Daten}` — trifft nicht zu: der fat pointer liegt auf dem Heap,
in der Variablen steht ein gewöhnlicher Zeiger darauf. Auch der Aufrufpfad war
in Ordnung; der Closure-Fallback für lokale Variablen lädt bereits
`rdi = [p+8]` (self) und `rbx = [p]` (Code) und ruft damit korrekt an.

Kaputt war allein die **Bindung**: `cg_genMethodRef` wurde nur aufgerufen, wenn
links ein Klassenfeld stand. Für eine lokale Variable lief die rechte Seite
durch den gewöhnlichen Feld-Load — und weil `Handle` kein Feld ist, wurde
Offset 0 gelesen, also der VMT-Zeiger. Der Aufruf sprang ins Leere. Das ist die
Bauart, die in diesem Projekt schon mehrfach Zeit gekostet hat: *das Konstrukt
trifft konsequent das Falsche, weil die Stelle fehlt, an der das Richtige
entstünde.*

Entschieden wird jetzt am Klassenlayout: `obj.name` ist ein **Feld**, wenn die
Klasse es als Feld führt — sonst ist es die **Methode** und wird gebunden. Die
Regel greift an beiden Stellen, an denen eine Variable vom `method(...)`-Typ
einen Wert bekommt: Initialisierung und spätere Zuweisung.

`tests/method_ptr_test.sh` deckte ausschließlich die Feldvariante ab (3 PASS)
und sagte über die lokale nichts aus. Jetzt 8 Prüfungen, darunter das Umbinden
auf eine andere Instanz und zwei Gegenproben: das Kopieren eines bereits
gebundenen Felds in eine lokale Variable darf **nicht** neu binden, und ein
gewöhnliches Feld wird weiterhin geladen. Vor dem Fix: 5 PASS, 3 FAIL.

### Seed

Neu verankert auf den Fixpunkt dieser Version (`dc530bef…`), wie es die Regel
aus #1167 für jede Codegen-Änderung vorsieht.

## Version 1.0.13A (August 2026)

### Bootstrap — der Seed belegte nichts mehr (#1167)

`make singularity` prüft S3 == S4: das Seed-Binary übersetzt die Quelle (S3),
S3 übersetzt sie erneut (S4), beide müssen Byte für Byte gleich sein. Sie
waren es nicht — der Seed stand auf **1.0.7B**, die Quelle auf 1.0.12A.

S3 trägt das *Verhalten* der neuen Quelle, aber die *Bytes* des alten
Codegens; S4 beides aus der neuen. Nach jeder Codegen-Änderung laufen die zwei
zwangsläufig auseinander — kein Nichtdeterminismus, und der Fixpunkt selbst
(gen2 == gen3 == gen4) war die ganze Zeit intakt. Aber ein Seed, der den
Compiler nicht mehr reproduziert, belegt nichts: die Vertrauenswurzel des
Bootstraps war seit mehreren Versionen ohne Aussage, und die CI-Stufe
„Singularity check" konnte nur rot sein.

`src/lyxc_bootstrap` ist jetzt der Fixpunkt dieser Version:

| | SHA-256 | Version |
|---|---|---|
| vorher | `968084de…` | 1.0.7B |
| nachher | `61662af5…` | 1.0.13A |

Der Anlass steht jetzt dort, wo er gilt — Makefile-Kopf und `CLAUDE.md`: die
Neuverankerung hängt an der **Codegen-Änderung**, nicht am Versionsbump. Einen
Automatismus braucht es nicht, `make singularity` *ist* der Detektor.

### Versionsschema festgeschrieben

`MAJOR.MINOR.TAG` + Suffix. **TAG** zählt die Build-*Tage*: der erste Build an
einem neuen Tag erhöht ihn und setzt den Suffix auf `A`. Der **Suffix** zählt
die Kompilate innerhalb des Tages — `A`…`Z`, dann `BA`…`BZ`, dann `CA`…;
`AA` gibt es nicht.

- `tools/next_version.sh` rechnet die nächste Version aus `VERSION` und dem
  neuen `VERSION_DATE` und setzt sie an allen vier lebenden Stellen.
- `tests/version_consistency_test.sh` (in `make test`) hält Makefile,
  README-Badge, die vier Strings in `src/lyxc.lyx`, den ebnf.md-Kopf und das
  gebaute Binary zusammen. Beim Bump auf 1.0.12A stand der ebnf.md-Kopf noch
  auf 1.0.11C — zwei Versionen hinter dem Compiler, und niemandem fiel es auf,
  weil keine der Stellen sich aus einer anderen ableitet.

**Reihenfolge:** erst bumpen, dann verankern. Die Version steckt im Binary,
ein Bump erzeugt also einen neuen Fixpunkt; umgekehrt wäre `singularity`
sofort wieder rot.

## Version 1.0.12A (August 2026)

Drei Befunde derselben Bauart: eine Zusicherung, die nur im Namen bestand.
Der erste hat die anderen beiden erst sichtbar gemacht.

### Testabdeckung — die Prüfung sah nur ein Drittel des Bestands (#1112)

`tests/test_coverage_test.sh` — der Wächter, der seit #1004 verhindern soll,
dass Testdateien unbemerkt verfallen — scannte **flach**: `tests/*.sh` und
`tests/*.lyx`, 307 von 928 Dateien. Die 621 in Unterverzeichnissen waren
unsichtbar, und er meldete trotzdem "alle Testdateien sind zugeordnet".

Die Lehre eine Stufe über #1004: *eine Abdeckungsprüfung, die nicht überall
hinsieht, meldet Vollständigkeit über den Ausschnitt, den sie kennt — und
sieht dabei genauso grün aus wie eine vollständige.*

Der Scan läuft jetzt über `find`. Zugeordnet ist eine Datei, wenn das Makefile
sie nennt, sie in einer Suite-Liste steht, sie in der neuen Liste
`tests/known-red.txt` geführt ist — oder sie unter einem Verzeichnis liegt,
dessen Runner **an einem Make-Ziel hängt**. Die letzte Bedingung wird
mitgeprüft: `tests/run_lyx_tests.sh` lief über 268 Dateien und wurde von
keinem Ziel aufgerufen. Ein Runner ohne Ziel ist derselbe Verfall wie ein Test
ohne Runner.

Triage der 621:

| Bereich | Dateien | Zuordnung |
|---|---|---|
| `tests/regression/**` + `tests/feature_checks/**` | 284 | 143 grün → `suite-full`; 141 verrottet → `suite-broken` (#1150) |
| `tests/lyx/**` | 268 | neues Ziel `test-lyx-integration`; 218 grün, 46 bekannt rot (#1153, #1156) |
| `tests/snapshot/**` | 49 | war über `make snapshot` verdrahtet |
| `tests/lyxos/**` | 17 | im `test-lyxos`-Ziel |
| `tests/e2e`, `tests/syntax`, `tests/integration` | 3 | einzeln |

**Rote Tests wandern nicht aus dem Lauf.** `tests/known-red.txt` führt sie mit
Issue weiter mit; wird ein Eintrag wieder grün, wird das Ziel **rot**, damit er
verschwindet statt zu veralten. Geräteabhängige Fälle tragen `!flaky` — sie
werden gemeldet, färben den Lauf aber in keine Richtung.

Vier Nebenbefunde, alle vom selben Muster:

- `tests/syntax/test_grammar.sh` **konnte gar nicht rot werden**: die
  JSON-Prüfung las `$GRAMMAR` in einem quotierten Here-Dokument, wo die Shell
  nicht ersetzt, und fehlende Schlüsselwörter gaben nur `WARNING` aus, Exit 0.
- `tests/e2e/test_int_widths.sh` zeigte auf einen gelöschten Pfad und nutzte
  entfernte Builtins.
- `tests/integration/run_examples.sh` entfernt: baute mit `fpc` den nicht mehr
  vorhandenen Pascal-Seed, hängte `|| true` an jeden Aufruf und prüfte nichts.
- `make snapshot` war rot: `11_at_if` fragte `TARGET_X86_64` ab, ein Name, den
  es nicht gibt (`@if` nimmt bei unbekanntem Bezeichner still den else-Zweig,
  #1159), und zwei `.expected` pinnten die Compilerversion im Copyright-Banner
  fest. Der Runner vergleicht jetzt die Diagnose ohne Banner. **49/49 grün.**

### Compiler — `--runtime-checks` prüfte Indizes gar nicht (#1156)

Die Option ist als *"Runtime-Assertions (bounds, null, zero) für DO-178C"*
dokumentiert. Für Array-Indizes passierte nichts: `arr[5]` bei `int64[3]` las
den Speicher hinter dem Array und lief weiter. Der Rückgabewert war Stack-Müll
und wechselte von Lauf zu Lauf. Das Feld `boundsCheckEnabled` (aus
`@bounds_check`) existierte, wurde geschrieben — und von keiner
Emissionsstelle gelesen.

Behoben auf zwei Ebenen, weil der Defekt auf zweien lag:

- **sema**: ein konstanter Index auf eine Variable mit fester Größe ist zur
  Übersetzungszeit entscheidbar und wird abgewiesen — ohne Schalter.
- **codegen**: berechnete Indizes prüfen zur Laufzeit, lesend wie schreibend.
  Feste Größe gegen Immediate, dynamisches Array gegen die Länge im
  `{cap,len}`-Kopf. Der Vergleich ist **vorzeichenlos**, ein negativer Index
  fällt damit in denselben Zweig wie ein zu großer.

Wo es keine Länge gibt — roher Zeiger, `pchar`, inline liegendes Struct-Feld —
wird weiterhin nicht geprüft. Das steht als benannte Lücke in `ebnf.md` §20.1,
statt als stiller Durchfall. Nur das x86-64-Backend trägt die Prüfung; die
übrigen kennen `--runtime-checks` insgesamt nicht.

### Compiler — schmale Ganzzahltypen trugen ihre Breite nur im Namen (#1151)

Ein Local, ein Parameter und eine globale Variable belegen immer einen
64-Bit-Slot, auch wenn sie `int8` heißen. Der Wert ging ungekürzt hinein:

| Ausdruck | erwartet | war |
|---|---|---|
| `var a: int8 := 130` | -126 | 130 |
| `var b: uint8 := 300` | 44 | 300 |
| `var d: uint32 := 0 - 1` | 4294967295 | -1 |
| `f(200)` bei `x: int8` | -56 | 200 |
| `return 300` bei `: uint8` | 44 | 300 |

Strukturfelder waren als einzige korrekt — sie liegen in ihrer eigenen Breite
im Speicher, dort kürzt der Speicherbefehl. Genau das verdeckte den Defekt.

Gekürzt wird jetzt an jeder Stelle, an der ein Wert in einen solchen Slot
geht: Initialisierung, Zuweisung (lokal, global, Closure), Parameter am
Funktions- wie am Methodeneintritt, `return`, und die globale
Literal-Initialisierung im Datenbereich (zur Übersetzungszeit gerechnet).

Zwei Nebenbefunde mit derselben Wurzel — die kurze und die lange Schreibweise
galten nicht überall als derselbe Typ, obwohl §7 sie so führt:

- `x as int8` und `x as int16` kürzten nicht; die Kette im Codegen kannte nur
  `i8`/`i16`.
- `var a: i8` wurde von sema abgewiesen, während `feld: i8` und `as i8`
  durchgingen — dieselbe Asymmetrie, die #1010 für die vorzeichenlose Hälfte
  (`u8`/`uint8`) geschlossen hat.

### Tests

Drei neue Suiten im `test`-Ziel, alle messen die **Ausführung**, nicht die
Übersetzung — ein Test, der nur schaut, ob etwas übersetzt, wäre in allen drei
Fällen vorher grün gewesen:

| Suite | Prüfungen | vor dem Fix |
|---|---|---|
| `tests/bounds_check_test.sh` | 12 | 6 PASS / 6 FAIL |
| `tests/int_width_test.sh` | 20 | 3 PASS / 17 FAIL |
| `tests/syntax/test_grammar.sh` | — | konnte nicht rot werden |

Jeder Fehlerfall kommt paarweise mit dem gültigen daneben, und die Gegenprobe
gehört dazu: ohne `--runtime-checks` und mit `@bounds_check(false)` darf
**nicht** geprüft werden; `int64`/`uint64` dürfen **nicht** gekürzt werden.
Ohne diese Fälle wäre eine Prüfung, die immer zuschlägt, ebenso grün.

Neue Ziele: `test-lyx-integration` (tests/lyx/**) und `test-known-red`; beide
laufen in der CI mit.

### Offen

- **#1150** — 141 verrottete Dateien in `tests/regression/**`, nach Ursache
  gebündelt.
- **#1153** — 45 rote Tests in `tests/lyx/**`; es fehlt eine Kategorie
  "übersetzen ja, ausführen nein" für die geräte- und dienstabhängigen.
- **#1159** — `@if` mit unbekanntem Bezeichner ist stillschweigend false.
- **#1164** — globale Variable mit **berechneter** Initialisierung bleibt
  still 0; nur Ganzzahlliterale landen im Datenbereich.
- **#1167** — `make singularity` ist rot: der Seed (1.0.7B) erzeugt nicht mehr
  denselben Compiler wie der Compiler selbst. Vorbestehend, gegen den
  Vorgängerstand belegt. Der Fixpunkt selbst hält (gen2 == gen3 == gen4).

## Version 1.0.11D (August 2026)

### Standardbibliothek — zstd: Compressed Blocks dekodieren wieder (#1027)

Der komprimierte Blockpfad (Huffman-Literale + FSE-Sequenzen) war
fail-closed, weil er stillschweigend falschen Inhalt lieferte. Gemessen
ueber 97 Frames derselben Textquelle in aufsteigender Groesse
(`zstd -1`, 20..116 Byte):

| | korrekt | still falsch | gemeldet | abgestuerzt |
|---|---|---|---|---|
| Ausgangslage | 5 | 6 | 19 | 67 |
| fail-closed (1.0.11C) | 44 | 0 | 53 | 0 |
| **jetzt** | **97** | **0** | **0** | **0** |

Sechs Defekte, drei davon Positionsfehler im Bitstrom, drei falsch
uebernommene Konstantentabellen:

- Der FSE-Gewichtsleser terminierte nach statt vor dem Verbrauch. RFC 8878
  §4.2.1.2 macht die Terminierung daran fest, ob das **Zustands-Update** noch
  in den Strom passt.
- Die kanonische Codezuweisung lief rueckwaerts: in zstd beginnt der
  **laengste** Code bei 0, nicht der kuerzeste.
- Der FSE-Tabellenkopf endet an einer **Bytegrenze**. Das angebrochene Byte
  wurde mitgezaehlt, der Rueckwaertsstrom begann ein Byte zu frueh — das war
  die Wurzel hinter den ersten beiden Befunden.
- Die drei Sequenztabellen stehen als LL, OFFSET, ML; gelesen wurde ML als
  zweite.
- Im Sequenzpfad wurden die FSE-Zustaende **vor** den Zusatzbits und in der
  Reihenfolge LL, OFF, ML fortgeschrieben. Richtig ist: erst die Zusatzbits
  (Offset, ML, LL), dann das Update LL, ML, OFF.
- Vier eingebaute Tabellen wichen vom RFC ab — die vordefinierte
  LL-Verteilung (2er-Lauf bis Symbol 12, nicht 8), die vordefinierte
  OFFSET-Verteilung (2er bei 6..8, nicht 5..7), die LL-Zusatzbits ab Code 25
  und die ML-Basen und -Zusatzbits ab Code 43.

Der letzte Punkt ist die Lehre dieser Runde: eine von Hand uebernommene
Konstantentabelle sieht plausibel aus und ist trotzdem falsch. Alle vier
fielen erst auf, als eine unabhaengige Referenzdekodierung derselben vier
Bytes danebengelegt wurde — nicht durch Lesen des eigenen Codes.

`tests/zstd_measure.sh` laeuft in `make test` und wird rot, sobald wieder ein
Frame stillschweigend falsch endet.

## Version 1.0.11C (August 2026)

Neun PRs. Roter Faden: **stille Lücken laut machen** — sechs der Befunde
lieferten etwas Plausibles, statt zu melden.

### Compiler (Codegen) — `defer` lief am Funktionsende statt am Blockende (#1006)
- Ursache war nicht eine falsch berechnete Blockgrenze, sondern **gar keine**:
  `cg_collectDefers` sammelte funktionsweit in einen Puffer, den
  `cg_emitDefers` an den Funktionsausgängen abarbeitete — Blockzugehörigkeit
  kam im Entwurf nicht vor.
- Jetzt Vormerkung an der Quelltextstelle, Abarbeitung am Ende des
  umschließenden Blocks (LIFO, vor dem Verwerfen der Locals). `return` führt
  weiterhin alle offenen defers aus.
- Zusätzlich gefunden: **`break` und `continue` übersprangen die defers** des
  Schleifenrumpfes. Neues Feld `loopDeferMark`, gesetzt in allen fünf
  Schleifenformen.
- Nicht enthalten (#1030): die **Argumente** werden weiterhin beim Blockende
  ausgewertet, nicht bei der Vormerkung.

### Compiler (Codegen) — `Printf` fehlte im x86-Backend (#1012)
- In sema als Builtin registriert und für ARM64 gelowert, auf ELF endete jeder
  Aufruf mit `undefined function 'Printf'`.
- Der Formatstring wird zur **Übersetzungszeit** zerlegt (`cg_genPrintf`), je
  Bestandteil eigene Emission (`%s`, `%d`, `%f`, `%c`, `%%`) — damit ohne
  varargs und ohne Laufzeit-Interpreter. Grenzfälle melden laut.

### Compiler (Codegen) — inline geschriebener fn-Zeigertyp stürzte ab (#1003)
- Die Eigenschaft *ist ein fn-Zeiger* hing am Typ**namen**: `cg_isFnPtrAlias`
  suchte in der Liste der `type X = fn(...)`-Aliase. Ein inline geschriebener
  Typ hat keinen Namen, der Aufruf lief über den Closure-Pfad und sprang in
  Datenmüll. Dieselbe Klasse wie bei `defer` — die richtige Ebene fehlte.
- Vermerkt wird die Eigenschaft jetzt am Local selbst (`localIsFnPtr`), gesetzt
  an allen vier Entstehungsstellen. Als Klassenfeld war der Fall seit #889 in
  Ordnung.

### Compiler (Lexer) — Ziffern-Trenner im Float-Literal wurde verschluckt (#1011)
- Der Lexer akzeptiert `_` im Zahlliteral, die beiden Umwandlungen nach
  IEEE-754 (`cg_parseFloat`, `_parseFloatBits`) hielten am `_` an: `3.14_159`
  wurde zu 3.139999, `1_000.5` zu 1.0 — ohne Meldung.
- Der vorhandene Test **konnte den Fehler nicht sehen**: er verglich über
  `as int64`, wodurch beide Werte zu 3 kollabierten. Vergleich läuft jetzt auf
  f64.

### Compiler (sema) — gleichnamige Exporte zweier Units (#1028)
- `Lookup()` durchsucht die flache Symboltabelle rückwärts: bei Namensgleichheit
  gewann die Import-Reihenfolge, ohne Warnung. Bei unterschiedlicher Semantik —
  `DirList` als flacher Puffer vs. Hashmap — übersetzt das Programm und rechnet
  falsch.
- Kollisionen werden mit beiden Modulnamen gemeldet; nur `pub`,
  Builtin-Shadowing bleibt erlaubt. Drei echte Funde im Bestand bereinigt.

### Compiler (sema, Codegen) — `uintN` und `uN` waren uneinheitlich (#1010)
- Vier Stellen kannten unterschiedliche Teilmengen: der var-Deklarator wies
  `uint8` ab, `cg_typeSize` kannte umgekehrt **nur** die Langform, und ein
  `u16`-Feld bekam stillschweigend Breite 8.
- Beide Schreibweisen an allen vier Stellen. `ebnf.md` §7 führt jetzt beide;
  `isize`/`usize` gestrichen, weil der Compiler sie nachweislich nicht kennt.

### stdlib — zstd meldet Compressed Blocks, statt zu raten (#1027, entschärft)
- Messung über 97 Frames: vorher 67 Abstürze und 6-mal **still falscher**
  Inhalt; nachher 0 und 0. Bei 44 Byte Inhalt kam die richtige Länge mit
  9 falschen Bytes zurück — ein Längenvergleich allein sichert nicht ab.
- `blockType == 2` ist jetzt fail-closed; der Dekodierpfad wurde gehärtet
  (u.a. Bereichsprüfung im FSE-Zustand, Ursache der Abstürze). **Der Decoder
  ist damit nicht repariert**, #1027 bleibt offen.

### Tests
- `edi06_desadv_test` las aus einem freigegebenen Puffer (#1016) — kein
  Bibliotheks- oder Compilerfehler, sondern ein Use-after-free im Test, der
  erst auffiel, seit `free` tatsächlich `munmap` ruft. Vollsuite jetzt
  132 grün.
- zstd-Test importiert nur noch eine stdlib-Familie.

### Dokumentation
- `CLAUDE.md` neu: Arbeitsregeln aus den Postmortems dieses Projekts — die zwei
  dominanten Fehlerursachen (stiller Default; die im Entwurf fehlende Ebene),
  Testdisziplin, Nachweispflicht vor dem PR, wiederkehrende Sprach- und
  Repo-Fallen.
- Darin festgehalten: `Closes #N` greift hier **nie**, weil GitHub die
  Verknüpfung nur beim Merge in den Default-Branch (`main`) auslöst — gearbeitet
  wird gegen `develop`. Issues sind von Hand zu schließen.

## Version 1.0.11B (August 2026)

### Compiler (Codegen) — `&&` und `||` schlossen nicht kurz (#1023)
- Beide Operatoren werteten **immer beide** Operanden aus. Die Ursache war
  nicht eine falsche Auswertungsreihenfolge, sondern dass überhaupt keine
  bedingte Auswertung erzeugt wurde: `CGT_AND`/`CGT_OR` fielen in den
  generischen `CGN_BINOP`-Pfad, der beide Seiten zu Werten auswertet und danach
  verknüpft (`test`/`setnz`/`and` bzw. `or` mit Normierung).
- Damit lief das übliche Null-Guard-Idiom `if (p != 0 && deref(p))` auch bei
  `p == 0` in die Dereferenzierung — Segfault. Gefunden beim Bau des
  Paketmanagers lpm, dort an zwei Stellen.
- Beide Operatoren werden jetzt vor der Operandenauswertung abgefangen und als
  Sprungfolge emittiert; das Ergebnis bleibt auf 0/1 normiert. Semantik in
  `ebnf.md` bei `LogicalOrExpr` festgehalten.
- `tests/shortcircuit_test.sh` **zählt** die Auswertungen der rechten Seite,
  statt nur das Ergebnis zu prüfen — ein reiner Ergebnistest wäre auch vor dem
  Fix grün gewesen, denn das Ergebnis stimmte, nur der Weg dorthin war falsch.

## Version 1.0.11A (August 2026)

### Compiler (Codegen) — `for i in range(...)` erzeugte gar keinen Code (#1007)
- Der Parser baut dafür `NK_FOR_RANGE`, sema prüft den Knoten — im x86-Codegen
  kam er nicht vor und fiel in den stillen Catch-all `// Other statement kinds:
  skip` am Ende von `cg_genStmt`. Die Schleife lief **null Mal**:
  `for i in range(5) { s := s + i; }` ließ `s` unverändert.
- `cg_genForRange` ergänzt, nach dem Vorbild von `cg_genFor`. Einziger
  inhaltlicher Unterschied: `to` läuft bis **einschließlich** limit, `range` bis
  stop−1 — der Abbruch prüft `v >= stop` statt `v > limit`.

### Compiler (Codegen) — `|~` (bitweises NOR) emittierte nichts
- Lexer-Token (`TK_NOR`) und Parser-Präzedenz waren vorhanden, im
  Binäroperator-Dispatch fehlte der Operator und lieferte **still 0**.
- Der Catch-all dort bricht jetzt laut ab. Verifiziert, dass kein Operator
  legitim durchfällt.

### Compiler (Lexer, Codegen) — `match` funktionierte nur mit Literalen ≠ 0 (#1008)
- Zwei Ursachen, die still zusammenwirkten:
  1. Die Lexer-Prüfung für `_` stand **innerhalb** des `len == 3`-Blocks und war
     damit toter Code — `_` hat Länge 1. Der Parser erzeugte statt eines
     Wildcards ein Bezeichner-Muster namens `_`.
  2. Der Codegen unterschied Ganzzahl-Literal und Bezeichner an `ival != 0`. Für
     den vermeintlichen Bezeichner `_` wurde 0 geladen und verglichen —
     **`case _ =>` traf ausgerechnet nur bei Wert 0**; umgekehrt galt
     `case 0 =>` als Bezeichner.
- Unterstrich-Prüfung herausgezogen; unterschieden wird jetzt an der
  Namenslänge. Bezeichner werden auch über die Konstantentabelle aufgelöst,
  wodurch Enum-Mitglieder (`case Green =>`) treffen. Ein Bezeichner, der weder
  Konstante noch lokale Variable benennt, wird gemeldet statt still gegen 0
  verglichen.

### Sprache — `match` ist jetzt auch ein Ausdruck (#1008)
- `var r: int64 := match c { case 1 => 10; case _ => 0; };` — bisher war `match`
  nur eine Anweisung, ein Ergebnis ließ sich nur über Seiteneffekte gewinnen.
- `cg_genMatch` ließ den Wert des getroffenen Fallrumpfes ohnehin in `rax`;
  nötig waren `TK_MATCH` in `ParsePrimary`, `SNK_MATCH` in `_checkExpr` und
  `CGN_MATCH` in `cg_genExpr`. Ohne Treffer und ohne Default ist das Ergebnis
  jetzt definiert 0.

### sema — Methodenzeiger-Bindung war seit 1.0.10A abgewiesen
- `_checkFieldExists` (aus der Feldnamen-Prüfung) lief nur über die Felder einer
  Klasse, nie über ihre Methoden. `btn.on_click := form.Handle` wurde daher als
  `unknown field 'Handle'` abgelehnt. Die Methodenliste wird jetzt mitgeprüft.
- Die Regression blieb zwei PRs lang unbemerkt, weil die vier Testsuiten, die
  sie gefunden hätten, nicht in `make test` liefen.

### Tests — Bestand vollständig zugeordnet (#1004)
- In `tests/` lagen rund 200 Dateien, die von keinem Make-Ziel aufgerufen
  wurden. Jetzt sind alle **264** einem Ziel oder einer dokumentierten Liste
  zugeordnet: `suite-core` (in `make test`), `suite-full` (`make test-lyx`),
  `suite-lyxos`, `suite-external`, `suite-broken`, `suite-manual`.
- Der Runner urteilt nach der **Ausgabe**, nicht nach dem Exit-Code: die
  Konvention ist uneinheitlich (0, 42, und die `edi*`-Familie druckt „ALL PASS"
  und endet mit Exit 1). Ein Absturz ist immer rot — so kam heraus, dass
  `edi06_desadv_test` alle Prüfungen besteht und danach segfaultet (#1016).
- `tests/test_coverage_test.sh` meldet neue Testdateien, die in keinem Ziel
  stehen.

### Dokumentation — ebnf.md gegen den Compiler geprüft
- Die Datei trug noch v0.9.5B. 19 reservierte Wörter fehlten, fünf gelistete
  waren keine; Funktions- und Methodenzeiger fehlten komplett;
  `QualifiedIdent = Ident "::" Ident` war Fiktion; `SetType` ist nicht
  implementiert.
- `Ident` war ohne Unterstrich angegeben, obwohl er überall verwendet wird;
  `TypeParamClause` mit eckigen statt spitzen Klammern — **danach hatte sich ein
  Test gerichtet**, der deshalb als „veraltet" fehleingeordnet wurde.
- Die `match`-Produktion war an drei Stellen falsch: Fallrumpf als `Block`
  statt `Expr`, fehlender Guard, und ein `default =>`, das es nicht gibt.
- Neuer Abschnitt 20.1 hält fest, wo der Parser mehr annimmt, als die
  Werkzeugkette trägt. `tests/ebnf_keywords_test.sh` bindet die Keyword-Liste
  dauerhaft an den Compiler.

### Aufräumen
- Vier tote `src/lyxc_*`-Sicherungskopien entfernt (seit Mai unangetastet, in
  keinem Build-Ziel). Sie verfälschten jede Messung über das Repository — die
  Zählung der einargumentigen `free`-Aufrufe fiel dadurch zu hoch aus, und beide
  neuen Testskripte brauchten eine Ausnahmeliste.
- `examples/io/mmap/main_with_mmap.lyx` entfernt (kaputtes Duplikat). Damit
  übersetzen alle Beispiele, die übersetzen sollen: 336 von 341.

## Version 1.0.10A (Juli 2026)

### Compiler (sema) — unbekannte Feldnamen werden gemeldet (#988)
- sema prüfte bei `basis.feld` nur die **Sichtbarkeit**, nie die **Existenz**. Ein
  Tippfehler übersetzte klaglos und lieferte zur Laufzeit 0: `p.zzz := 99;
  return p.zzz;` auf einem Struct ohne dieses Feld ergab 0 statt eines Fehlers.
- `_checkFieldExists` prüft jetzt gegen den deklarierten Typ der Basis und läuft
  dabei die Vererbungskette hoch. Bewusst konservativ: gemeldet wird nur, wenn
  sich der Typ eindeutig zu einer Struct-/Klassendeklaration mit Feldern auflöst.
- Fallstrick dabei: eine Elternklasse aus einem importierten Unit hat in dieser
  Übersetzungseinheit **keinen AST-Knoten**. Das als „Feld fehlt“ zu werten
  meldete zwölf lyxvision-Units fälschlich als kaputt — ohne einsehbare
  Felderliste ist Abwesenheit nicht belegbar.

### Compiler (Parser) — Sentinel-Knoten für AST-Index -1 (#989)
- Der AST nutzt `-1` als Marker für „kein Kind“; etliche Baumläufe riefen die
  Knoten-Zugriffsfunktionen ungeprüft damit auf. `sn_off` rechnete dann
  `nodes + (-1)*88`, also **unter die Knoten-Arena**.
- Ob das tödlich war, entschied allein die Speicherlage: lag dort noch eine
  gemappte Seite, wurde still Garbage gelesen; fiel der Puffer an einen
  Mapping-Anfang, faultete der Compiler. Sichtbar wurde es als scheinbare
  Größengrenze — **jede** Zwei-Zeilen-Ergänzung in `src/sema.lyx` brach den
  Selbstbau, dieselbe Ergänzung in `parser.lyx` war harmlos.
- Der Parser alloziert den Knotenpuffer jetzt um einen Knoten größer und lässt
  `self.nodes` hinter einen Sentinel zeigen. Weil alle Konsumenten denselben
  Basiszeiger bekommen, wirkt das für die ganze Pipeline.

### Compiler (Codegen) + Standardbibliothek — echte Atomics (#991)
- `atomic_load/store/cas/fetch_add` und die drei `fence_*` waren in sema
  registriert, aber **nur im lyxos-Backend emittiert**. Auf dem ELF-Pfad endete
  jeder Aufruf in `no codegen implementation found` — die stdlib konnte sie also
  gar nicht verwenden.
- Jetzt auch im x86-Codegen: `lock xadd`, `lock cmpxchg`, `xchg`,
  `sfence`/`lfence`/`mfence`.
- Damit sind `AtomicAdd` und `CAS` in `std/thread.lyx` echt atomar; sie nutzten
  vorher `peek64`/`poke64` und hatten trotz des Namens ein Rennen. Derselbe
  Defekt steckte im Mutex: `if (peek32(p) == 0) { poke32(p, 1) }` ist ein
  nicht-atomares Test-and-Set — ein Mutex, der nicht ausschließt.

### Standardbibliothek — `ThreadCreate` startet wieder Threads (#992)
- `func` und `arg` lagen in `ThreadCreate`s eigenem Frame. `CLONE_VM` garantiert
  den geteilten **Adressraum**, nicht die **Lebensdauer** des Frames — nach dem
  Return wurde der Speicher wiederverwendet, und der Kindthread sprang auf einen
  überschriebenen Funktionszeiger. Ohne Join lief es zufällig durch, mit Join
  segfaultete es; `ThreadJoin` war nur das erste, was den Frame überschrieb.
- Übergabe jetzt über einen Heap-Block plus Trampolin, das auf dem Kind-Stack
  einen eigenen Frame bekommt; Handshake über Atomics, Spawns serialisiert.
- Zweiter Teil: `CLONE_CHILD_SETTID` schreibt die TID erst, wenn das Kind läuft —
  der Elternteil las vorher die selbst geschriebene 0 und hielt den Thread für
  beendet. Jetzt `CLONE_PARENT_SETTID` (Kernel schreibt synchron).
- `ThreadJoin` gibt den Kind-Stack frei; ohne das scheiterte `ThreadCreate` unter
  `ulimit -v 1G` ab dem 509. Thread.

### Compiler — `free`-Builtin entfernt, Freigaben wirken wieder (#995)
- `free` war ein Builtin, das **nichts tat** („no-op in bootstrap ... leaks are
  acceptable“) und dabei `std/alloc.lyx` verdeckte. Jede Freigabe im Projekt war
  wirkungslos: 1000× `alloc(2 MB)` + `free(2 MB)` scheiterte unter
  `ulimit -v 262144` beim 127. Durchlauf.
- Es auf `munmap` umzustellen wäre falsch gewesen — der so gebaute Compiler
  übersetzte seine eigene Quelle nicht mehr. Grund: es gibt **zwei Allokatoren**.
  `std/alloc.lyx` macht ein `mmap` je Allokation (dort muss `free` `munmap`
  rufen), `src/std/alloc.lyx` ist eine Arena mit Bump-Pointer (dort ist `free`
  korrekt ein No-op) — und den nutzt der Compiler selbst.
- Ein globales Builtin kann nur eine der beiden Seiten richtig bedienen. Es ist
  jetzt entfernt; jede Übersetzungseinheit bekommt das `free` ihres eigenen
  Allokators.
- Voraussetzung war, alle 135 einargumentigen Aufrufstellen auf
  `free(ptr, size)` zu bringen. `tests/free_arity_test.sh` hält das fest.

### Standardbibliothek — GLX-/EGL-Wrapper geschrieben
- `std/qt5_glx.lyx` und `std/qt5_egl.lyx` enthielten nur Konstanten und rohe
  `extern fn`-Bindings. Die typisierten Wrapper, die der Kommentarblock
  „Usage pattern“ als API beschreibt, waren **nie geschrieben worden** — die
  Beispiele riefen sie trotzdem auf.
- Zwölf Wrapper ergänzt. `EGLDisplay` ist dabei vom `int64`-Alias zum Struct
  geworden, damit `eglTerminate` nicht auf ein uninitialisiertes Display läuft.

### Tests — Builtins, die Unit-Namen verdecken
- Ein registriertes Builtin gewinnt gegen eine gleichnamige Deklaration in einer
  importierten Unit; die Unit-Fassung ist dann stillschweigend wirkungslos. Diese
  Klasse hat das Projekt mehrfach getroffen (`free`, Phantom-Builtins,
  POSIX-Flag-Konstanten).
- `tests/builtin_shadow_test.sh` führt die 31 bekannten Kollisionen und schlägt
  bei einer neuen fehl. Dabei gefunden: `std/audio.lyx` deklarierte
  `MAP_ANON := 32`, das Builtin liefert 34 — wer die Konstante aus der Unit las,
  bekam still den anderen Wert.
- Bewusst **kein** Compiler-Warnhinweis: er würde bei jedem Programm feuern, das
  `std.io` oder `std.string` importiert, weil die dortigen Kollisionen gewollt
  sind.

### Beispiele — 256 → 336 von 341
- Qualifizierter Modulzugriff entfernt (den gibt es in Lyx nicht), alte
  Funktionsnamen nachgezogen, fehlende Imports ergänzt, `&x` → `@x`.
- `examples/io/net/echo_client.lyx` war durchgängig Go (Tupel-Destructuring,
  Slices, `nil`) und ist gegen die echte Socket-API neu geschrieben — end-to-end
  gegen `echo_server.lyx` verifiziert.


### Compiler (Codegen) — `sys_open`, `sys_lseek`, `sys_stat` auf dem ELF-Pfad
- `sys_read`, `sys_write` und `sys_close` waren im x86-Codegen als Alias der
  gleichnamigen Builtins vorhanden, `sys_open`/`sys_lseek`/`sys_stat` **nicht** —
  obwohl `sys_open` in sema registriert und im IR-Pfad gelowert war. Auf ELF
  starb der Aufruf mit `no codegen implementation found`, auf LyxOS lief er.
- Aliase ergänzt (Syscalls 2, 8, 4). `sys_lseek` war zusätzlich in sema gar nicht
  registriert und ist jetzt nachgetragen.
- Neuer Test `tests/sys_file_syscalls_test.lyx` (6 Prüfungen), in `make test`:
  echter Datei-Roundtrip — schreiben, zurücklesen, Inhalt vergleichen, per
  `lseek` die Größe bestimmen.

### Beispiele — FFI-Sandbox
- **Zwei Beispiele deklarierten Builtins als `extern fn`** (`read`/`write` in
  `games/game1`, `sys_socket`/`mmap`/`poke8`/… in `test_extern_redis`). Das war
  überflüssig und lief in die Fail-Closed-Prüfung. Deklarationen entfernt — die
  Builtins waren die ganze Zeit direkt verfügbar.
- **Sechs Grafik-Beispiele** (X11/GLX/EGL) tragen jetzt `@cap(network.unix)` an
  ihren Externs: X11 spricht über einen Unix-Socket mit dem X-Server. Die
  Annotation dokumentiert den Bedarf — die Sandbox verlangt bei einem
  unbekannten Symbol lediglich, **dass** eine Capability deklariert ist, nicht
  dass sie zum Symbol passt.
- **`graphics/dlopen_test.lyx` bleibt bewusst nicht übersetzbar.** `dlopen` steht
  auf der harten Blacklist, weil dynamisches Nachladen die Sandbox aushebelt.
  Die Datei belegt das Verhalten und trägt jetzt einen Kopfkommentar, der das
  erklärt — sie wird nicht „repariert".
- Beispiele 315 → 323 von 342.

### Standardbibliothek — `Select` und `Poll` in `std.net.syscalls`
- Die Unit trug „I/O multiplexing" seit jeher in der Überschrift, hatte die
  beiden Wrapper aber nicht — acht Beispiele riefen sie ins Leere.
- `sys_poll` gab es als Builtin; **`sys_select` fehlte ganz** und ist jetzt
  ergänzt (Syscall 23). Das vierte Argument steht nach SysV-Aufrufkonvention in
  `rcx`, die Syscall-Konvention erwartet es in `r10` — ohne Umladen bekäme der
  Kernel Müll als `exceptfds`.
- Neuer Test `tests/select_poll_test.lyx` (3 Prüfungen), in `make test`: prüft
  echte Syscall-Ergebnisse (leeres fd-Set → 0, `Poll` mit `nfds=0` → 0, stdout
  als schreibbar → 1), nicht nur dass der Aufruf übersetzt.
- Beispiele 307 → 315 von 342.

### Compiler (Codegen) — `_indirect_call_2/3/4` implementiert
- `_indirect_call_0` und `_1` gab es; `_2`, `_3` und `_4` waren in sema
  registriert, aber **nie emittiert** — der Aufruf bestand sema und starb im
  Codegen mit `no codegen implementation found`.
- Gleiches Schema wie `_1`: Argumente in umgekehrter Reihenfolge pushen, fnPtr
  nach `rax`, dann nach `rdi`/`rsi`/`rdx`/`rcx` zurückholen.
- **Warum das kein Sweep gefunden hat**: `std/android/jni.lyx` benutzt
  `_indirect_call_2` und `_4` und galt trotzdem als übersetzbar, weil
  `--compile-unit` den Codegen nicht erreicht. Diese Fehlerklasse zeigt sich nur
  beim Bauen eines echten Programms.
- Entsperrt die drei Android-JNI-Beispiele.
- Neuer Test `tests/indirect_call_test.lyx` (5 Prüfungen), in `make test`: prüft
  die Argumentlage mit stellenwertigen Erwartungen (123, 1234), die eine
  Vertauschung nicht überleben würden.

### Compiler (sema) — sechs Phantom-Builtins entfernt
- sema registrierte `PrintStrLn`, `PrintIntLn`, `StrCmp`, `StrNCmp`, `StrToInt`
  und `StrToFloat` als Builtins, **die kein Backend implementiert**. Ein Aufruf
  ohne passenden Import bestand sema und starb erst im Codegen mit
  `no codegen implementation found` — an der Aufrufstelle, ohne Hinweis auf den
  fehlenden Import.
- Registrierungen entfernt. Der Fehler kommt jetzt aus sema
  (`undefined function`), mit Import funktionieren die Funktionen normal.
- **Verdeckte einen echten Fehler**: `std/db/sqlite.lyx` rief `StrCmp` ohne
  `import std.string` auf und galt trotzdem als übersetzbar. Import ergänzt.
- `StrToInt` in `std/string.lyx` implementiert (es gab zwei Aufrufer in
  `lpm/registry/`); `StrNCmp` und `StrToFloat` haben keine Aufrufer und bleiben
  ohne Implementierung — wer sie braucht, ergänzt eine Bibliotheksfunktion.
- Neuer Test `tests/no_phantom_builtins_test.sh` (10 Prüfungen), in `make test`:
  alle sechs Namen müssen **von sema** abgelehnt werden (nicht vom Codegen), und
  die vier vorhandenen Funktionen müssen mit Import laufen.

### Compiler (sema) — Import auf ein fehlendes Modul meldet jetzt einen Fehler (#978)
- `_sema_processImport` kehrte kommentarlos zurück, wenn weder `.lyx` noch der
  `.lyu`-Fallback gefunden wurde. Der Import verschwand, und der Fehler tauchte
  erst an der **ersten Nutzung** als `undefined function` auf — was nach einem
  Tippfehler im Funktionsnamen aussieht, während die Ursache im Import-Pfad
  liegt. In `std/cpu/dispatch.lyx` zeigte die Meldung auf `CpuFeatureDetect`,
  während `import src.std.cpu.features` ins Leere lief (`src/std/cpu/` existiert
  nicht).
- Die Meldung nennt Modul, Zeile und den gesuchten Dateipfad, dazu `-I` und
  `--std-path`, falls gesetzt — die Verwechslung `std.` ↔ `src.` ist genau der
  Fall, in dem man das braucht.
- Neuer Test `tests/dangling_import_test.sh` (6 Prüfungen), in `make test`:
  fehlendes std-/src-Modul, tief verschachtelter Pfad, Pfadangabe in der
  Meldung, Meldung **vor** dem Folgefehler, und kein Fehlalarm bei gültigen
  Imports.
- Nichts im Baum verließ sich auf das stille Verhalten: der Unit-Sweep bleibt
  bei 390 OK / 0 failed.

## Version 1.0.9A (Juli 2026)

Aufruf-Protokoll im Codegen korrigiert, kompletter Unicode-/Text-Stack, alle
stdlib-Units wieder übersetzbar. Basis V1.0.8C.

Schwerpunkte:
- **Codegen/ABI**: drei Fehler im Aufruf-Protokoll — verschobener self-Slot bei
  statischen Methodenaufrufen, nie abgeräumte Stack-Argumente ab 7 Slots, und
  ein Aufruf-Ergebnis war kein gültiger Methoden-Empfänger (#958, #965, #959).
- **Text/Unicode**: `Text` als Klasse mit Operatoren, volles Simple-Case-Mapping,
  normalisierungs-/case-insensitiver Vergleich, Unicode-Trim, UTF-16-Konverter.
  Damit ist die Encoding-Entscheidung (UTF-8 kanonisch) vollständig umgesetzt.
- **Standardbibliothek**: 17 Units waren gar nicht übersetzbar; Compile-Sweep
  von 64 OK / 28 failed auf **92 OK / 0 failed** (#960).
- **LyxOS**: Float-Memory-Intrinsics gelowert; `DIV → SHR` entfernt, weil für
  vorzeichenbehaftete Division falsch.

Alle Compiler-Änderungen mit Selbst-Host-Fixpunkt gen2==gen3 verifiziert;
`make test` 20 PASS / 0 FAIL.

### `std.process` auf Compiler-Builtins umgestellt (#960)
- **Compile-Sweep jetzt 92 OK / 0 failed** — die letzte nicht übersetzbare Unit.
- `std/process.lyx` deklarierte `execve`/`execvp` als rohes FFI. Beide stehen auf
  der harten FFI-Blacklist (beliebiges exec über ein dynamisch gelinktes Symbol
  ist ein Sandbox-Escape), die Unit ließ sich deshalb gar nicht übersetzen.
  Umgestellt auf die bereits vorhandenen Builtins `sys_fork`, `sys_execve`,
  `sys_wait4`, `sys_kill`, `sys_getpid` — derselbe Syscall, aber über den
  kontrollierten Pfad des Compilers. **Die Blacklist bleibt unangetastet.**
- **Zwei Laufzeitfehler mitgefixt**, die beim Compilieren nie auffielen:
  - `execve(prog, prog, 0)` übergab den Pfad als `argv`; `argv` muss ein
    NULL-terminiertes Zeiger-Array sein. Der Aufruf wäre auch mit erlaubtem FFI
    gescheitert. Jetzt echte argv-Arrays (`_argv1`, `_argvShell`).
  - `waitpid(pid, status, 0)` übergab die **Zahl** 0 als Status-Zeiger und las
    den Status nie zurück → Exit-Codes waren immer 0. Jetzt 8-Byte-Puffer.
  - `sys_exit_group` ist in sema registriert, hat aber keine Codegen-Umsetzung →
    `exit()` verwendet.
- Neuer Test `tests/process_unit_test.lyx` (8 Prüfungen), in `make test`: prüft
  gegen echte Prozesse (`run /bin/true` = 0, `/bin/false` = 1, `shell "exit 7"`
  = 7, fehlendes Programm = 127, spawn/wait_for). Nur so sind beide Fehler oben
  sichtbar — am Compilieren nicht.

### Compiler — FFI-Trust für `--compile-unit` (#960)
- **`--compile-unit` auf einer stdlib-Unit gilt jetzt als vertrauenswürdig**,
  genau wie dieselbe Unit beim Import. Vorher war sie als **Root**-Modul
  untrusted und ihre Externs fielen in den Fail-Closed-Zweig der FFI-Sandbox.
- Das war **kein Test-Artefakt**: `make package` ruft über `precompile-units`
  denselben Pfad auf. 15 Units ließen sich dadurch nicht mehr zu `.lyu`
  vorkompilieren — die gepackten Kopien stammten noch von vor der FFI-Härtung
  und waren nicht regenerierbar.
- Das Vertrauen kommt vom **Pfad**, den der Aufrufer angibt (`std/`, `src/`,
  `data/`), nicht aus einer Selbstauskunft der Datei: eine Datei außerhalb des
  Baums bleibt fail-closed, auch wenn sie sich selbst `unit std.x;` nennt.
  Blacklist und Klassifizierung gelten unverändert weiter.
- Compile-Sweep: **77 OK / 15 failed → 91 OK / 1 failed**.
- Neuer Test `tests/ffi_unit_trust_test.sh` (5 PASS), in `make test`: hält beide
  Seiten der Grenze fest — stdlib-Unit compiliert, Datei außerhalb des Baums und
  normales Programm bleiben fail-closed, Blacklist greift auch im std-Baum,
  stdlib-interne Builtins ohne link-String bleiben erlaubt.
- **Offen**: `std/process.lyx` bleibt die einzige nicht übersetzbare Unit. Sie
  deklariert `execve`/`execvp`, beide auf der harten FFI-Blacklist. Das ist die
  Sandbox-Policy, keine Panne — braucht eine Entscheidung, kein Aufweichen.

### Standardbibliothek — nicht kompilierbare Units repariert (#960)
- **16 Units waren nicht übersetzbar** und blockierten damit jedes Programm, das
  sie importiert (der Resolver bevorzugt `.lyx` vor `.lyu`). `test_compile_units.sh`
  geht von **64 OK / 28 failed** auf **77 OK / 15 failed**; die verbleibenden 15
  sind ausschließlich FFI-Sandbox-fail-closed und damit gewolltes Verhalten.
- **Struct-Literale `Type{f: e, …}` (96 Stellen in 7 Units)** — eine Syntax, die
  Lyx nie hatte, weder im Parser noch in der EBNF. Umgeschrieben auf Deklaration
  + Feldzuweisung; verschachtelte Literale (`Rect{min: Vec2{…}}`) wandern von
  innen nach außen in Hilfsvariablen.
- **`array[N]T` → `[N]T`** (13 Stellen in 6 Units): `ArrayType` ist laut EBNF
  `array "[" Type "]"`, eine Zahl ist dort kein gültiger Typ.
- **Reservierte Keywords als Bezeichner**: `match` (buffer), `widget`/`layout`
  (lfd_factory, qt5_app), `repeat` (svg/anim), `i8` (ml_full).
- **`const` → `con`** (crt_raw), fehlende `import std.alloc` (xml, uuid),
  Phantomtyp `fd` → `int64` (systeminfo).
- Neuer Test `tests/geom_units_test.lyx` (31 Prüfungen), in `make test`
  verdrahtet: prüft Konstruktoren **und** abgeleitete Werte der umgeschriebenen
  Geometrie-/Result-Units gegen erwartete Zahlen — „kompiliert durch" genügt bei
  einem mechanischen Umbau nicht.

### Compiler (Codegen) — Methodenaufruf auf einem Aufruf-Ergebnis (#959)
- **`t.Trim().ByteLength()` scheiterte** mit `undefined function 'ByteLength'`:
  `cg_objClassIdx` lieferte für einen Aufruf als Empfänger -1, der Aufruf wurde
  ungemangelt emittiert und fand beim Patchen kein Ziel.
- Die Klassenauflösung existierte bereits (`cg_exprClassName` + fnRet-Registry,
  in der freie Funktionen **und** Methoden stehen) — sie wurde an dieser Stelle
  nur nicht benutzt. Da sie sich für den Empfänger rekursiv aufruft, lösen jetzt
  auch **Ketten** (`padded.Trim().AsciiUpper().ByteLength()`) und freie
  Funktionen mit class-Rückgabe als Empfänger (`TextFromPchar("abc").ByteLength()`)
  korrekt auf.
- **Operatoren auf einem Methoden-Ergebnis** funktionieren damit ebenfalls
  (`a.M() == b`, `a.M()[i]`). `ebnf.md` §15.3 sagte das Gegenteil und ist
  angepasst; die Zwischenvariable in `examples/basics/text_operators.lyx`
  entfällt.
- Neuer Test `tests/method_result_dispatch_test.lyx` (13 Prüfungen), in
  `make test`: Methoden- und Operator-Aufrufe auf Ergebnissen, dreistufige
  Ketten, freie Funktion als Empfänger, `String` wie `Text`, und die
  Zwischenvariable als Gegenprobe.

### Compiler (Codegen) — Stack-Argumente nach dem Aufruf abräumen (#965)
- **Ein Aufruf mit 7+ Argumenten innerhalb der Argumentliste eines anderen
  Aufrufs zerstörte den äußeren Aufruf.** Ab dem 7. Slot gehen Argumente nach
  SysV-Konvention über den Stack, und der Aufrufer muss sie nach dem `call`
  selbst entfernen — das fehlte. Isoliert fiel es nicht auf (der Frame wird beim
  Funktionsende ohnehin über `rbp` zurückgesetzt); verschachtelt lagen dort aber
  schon die ausgewerteten Argumente des äußeren Aufrufs.
- Zwei Ausprägungen: SIGSEGV oder — gefährlicher — ein stillschweigend
  verlorener Parameter. `show("n7", seven(7,7,7,7,7,7,7))` verlor den Namen bzw.
  stürzte ab.
- Bei Methoden zählt das implizite `self` mit, dort lag die Grenze schon bei
  **6** expliziten Argumenten.
- Fix: `cg_popStackArgs(nTotal)` nach jedem Aufruf, der gespillt hat (imm8 bzw.
  imm32). Betrifft den Methoden-/Static-Pfad und den Pfad für freie Funktionen.
- Neuer Test `tests/nested_call_stackargs_test.lyx` (11 Prüfungen), in
  `make test`: verschachtelte Aufrufe mit 6/7/9 Argumenten, zwei verschachtelte
  nebeneinander, Methoden mit 6/7 Argumenten plus statischer Aufruf, isolierte
  Aufrufe als Gegenprobe, und der Erhalt des äußeren `pchar`-Parameters.

### Compiler (Codegen) — statischer Methodenaufruf (#958)
- **`TypeName.Method(args)` übergab die Argumente um ein Register verschoben.**
  Der Callee `TypeName_Method` hat immer ein implizites `self` als ersten
  Parameter; der statische Aufruf ließ diesen Slot weg. Dadurch landete das erste
  echte Argument in `self` und der erste Parameter bekam Müll — `SB.Create(41)`
  lieferte 169 statt 42, in `src/std/string.lyx` reichte es für einen SIGSEGV.
- Fix: der statische Aufruf reserviert den self-Slot und übergibt **0**. Dass die
  Methode `self` nicht anfassen darf, prüft sema bereits (BUG-6-Check).
  Betrifft beide Pfade — Registerargumente und den Stack-Spill ab 7 Slots.
- Damit ist das Static-Factory-Muster (`StringBuilder.Create(256)`) erstmals
  funktionsfähig; es war seit jeher fehlerhaft, nur bisher nicht isoliert.
- Neuer Test `tests/static_method_codegen_test.lyx` (10 Prüfungen), in
  `make test`: statische Aufrufe mit 0/1/2/5/7 Argumenten, dieselben Aufrufe über
  eine Instanz, und `self`-Integrität nach einem statischen Aufruf. Gegen den
  Vorgänger-Compiler schlagen genau die vier statischen Fälle fehl.

### Compiler (sema)
- **`TypeName.Method()` wird abgelehnt, wenn die Methode `self` benutzt** — dann
  fehlt der Empfänger und die Methode arbeitete an einer beliebigen Adresse
  (BUG-6 aus `work/compiler-bugs.md`). Methoden **ohne** self-Zugriff bleiben
  erlaubt: das Static-Factory-Muster (`StringBuilder.Create(256)`) ist in
  `src/std/` verbreitet, ein pauschales Verbot würde alle Aufrufstellen brechen.
- Rekursive `self`-Erkennung über den ganzen Methodenrumpf; verschachtelte
  `fn`-Deklarationen werden nicht betreten (eigener self-Kontext). Importierte
  Typen tragen keine sichtbare Deklaration und bleiben ungeprüft — lieber
  ungeprüft als falsch-positiv.
- `TypeName.field` (Byte-Offset) bleibt unverändert gültig und ist mitgetestet.
- Neuer Test `tests/static_method_call_test.sh` (7 PASS), in `make test` verdrahtet.
- **Audit `work/compiler-bugs.md` (lyxc 0.9.9B, BUG-1..8)**: 7 der 8 gegen 1.0.8C
  als behoben verifiziert — Feld-Offsets, der `e8 cc`-Platzhalter-CALL (bricht
  heute in `cg_patchAll` hart ab), verschluckte sema-Fehler aus Imports (melden
  jetzt den Modulnamen), `MemCopy`, `sizeof(Type)` in beiden Kontexten, `StrEq`,
  `var self`-Shadowing. Report entfernt.
- **Dabei neu gefunden**: statische Methodenaufrufe crashen zur Laufzeit auch
  ohne self-Zugriff — vorbestehend, betrifft `src/std/string.lyx`,
  `json.lyx`, `time.lyx`. Eigener Report `work/static-method-call-codegen.md`.

### Compiler (IR-Optimizer)
- **Strength-Reduction `DIV → SHR` entfernt** — für vorzeichenbehaftete Division
  ist die Umformung schlicht falsch: Rechtsschieben rundet ab, Division
  trunkiert Richtung Null. `-21 / 4` ist `-5`, `-21 >> 2` aber `-6`. Nur exakt
  teilbare Werte kamen zufällig richtig heraus, weshalb es lange unauffällig
  blieb. Die IR unterscheidet an dieser Stelle kein signed/unsigned, es gibt
  also keine Bedingung, unter der die Umformung sicher wäre.
- Derselbe Arm miscompilierte zusätzlich den 2^0-Fall: `x / 1` lieferte auf dem
  IR-Pfad (lyxos, arm64, …) konstant **1** statt `x`.
- `MUL → SHL` bleibt: im Zweierkomplement ist sie für beide Vorzeichen exakt.
- Betrifft alle IR-basierten Backends; der ELF-Pfad war nie betroffen (AST →
  codegen_x86 ohne diesen Pass). Regressionstests in
  `tests/lyxos_strength_reduction_test.sh` (jetzt 20 PASS): negative Dividenden
  mit Rest, `x / 1`, sowie geteilte Const-Temps (ein nicht reduziertes `%` darf
  die auf log2 umgeschriebene Konstante einer benachbarten `*` nicht sehen).
- Damit ist `BUG_lyxos_strength_reduction_shift.md` abgearbeitet und entfernt.

### Compiler (LyxOS-Backend)
- **Float-Memory-Intrinsics für `--target=lyxos`**: `peekf64`, `pokef64`,
  `peek32f`, `poke32f` werden jetzt gelowert (ir_lower ids 253–256, Emission in
  emit_lyxos). Sie waren in sema registriert und im ELF-Codegen inline
  emittiert, im lyxos-Pfad aber nicht behandelt — die letzte Lücke aus dem
  peek/poke-Misdispatch-Report. Der gehärtete Catch-all machte daraus einen
  harten Compile-Fehler statt einer stillen Fehl-Emission, `--target=lyxos`
  konnte also überhaupt keinen f64/f32-Speicherzugriff übersetzen.
- `peekf64`/`pokef64` sind reine 8-Byte-Moves (f64 liegt als IEEE-Bits im
  int64-Slot, wie in codegen_x86); nur die f32-Varianten brauchen SSE, weil sie
  zwischen f32-Speicher und f64-Registerdarstellung konvertieren
  (cvtss2sd / cvtsd2ss).
- Regressionstests in `tests/lyxos_builtin_intrinsics_test.sh` (jetzt 75 PASS):
  Reads auf rodata sind runtime-verifiziert — "AAAA" als f32 = 12.078431,
  "AAAAAAAA" als f64 = 2261634.5098 prüft zugleich die f32→f64-Weitung, nicht
  nur dass geladen wird. Stores compile-only wie die bestehenden poke-Tests.
- Die Bug-Reports `BUG_lyxos_peek_poke_misdispatch.md` und
  `BUG_lyxos_v102B_peek_poke_REGRESSION.md` sind damit vollständig abgearbeitet
  und entfernt (Historie steht in git).

### Standardbibliothek

### Standardbibliothek
- **`std.text.Text` ist jetzt eine Klasse** (vorher struct). Damit trägt die
  UTF-8-Schicht eine Methoden-API und nimmt am Operator-Overloading teil:
  `a + b` (Add), `a == b`/`a != b` (Eq/Ne), `a < b` … `a >= b` (Compare), `a[i]` (Get).
- **`a[i]` liefert den Codepoint**, nicht das Byte — `Text` ist die
  codepoint-aware Schicht; für Rohbytes bleibt `ByteAt`. `Compare` ist
  lexikografisch über die UTF-8-Bytes, was bei UTF-8 der Codepoint-Ordnung
  entspricht (keine Locale-Collation, nicht normalisierungs-insensitiv).
- **Neu**: `SplitCount` + `PartAt` (Split ohne Caller-Buffer), `TextCompare` als
  freie Funktion.
- **Kompatibel**: alle bisherigen freien Funktionen bleiben als Wrapper über den
  Methoden — `std.unicode`, `std.unicode_case` und `std.grapheme` sind
  unverändert (sie nutzten nur `TextData`/`TextByteLength`).
- **Latenter Bug mitgefixt**: `Free()`/`TextFree()` leert jetzt wirklich das
  Objekt des Aufrufers. Als struct mutierte es eine By-Value-Kopie, ließ die
  Felder des Aufrufers also dangling.
- `sizeof(Text)` ist die Handle-Größe → der Stride der rohen `TextSplit`-Ausgabe
  ist die explizite Konstante `TEXT_PART_STRIDE` (24 = `[data][byteLen][valid]`).

- **`std.unicode`**: `TextCompareNormalized`, `TextStartsWithNormalized` und
  `TextTrimUnicode` / `TextTrimStartUnicode` / `TextTrimEndUnicode` (Trimmen nach
  der Unicode-White_Space-Eigenschaft — `Text.Trim()` lässt NBSP, EN/EM-Space und
  U+3000 stehen). Ergänzt das schon vorhandene `TextEqualsNormalized`.
- **`std.unicode_case`**: caseless Vergleich — `TextEqualsFold`,
  `TextCompareFold`, `TextContainsFold`, plus `TextFoldFull` (Schlüssel einmal
  berechnen) und `UnicodeFoldFull` auf Codepoint-Ebene. Simple Faltung inkl.
  griechischem Schluss-Sigma (ς→σ), das reines Kleinschreiben nicht erwischt;
  1:n-Expansion (ß→ss) bleibt außerhalb.
- Die beiden Achsen sind bewusst getrennt (Fold ≠ normalisierungs-insensitiv):
  beide Tabellen-Units zusammen sprengen das Kompilierungs-Größenlimit von `lyxc`.

- **`std.text` UTF-16-Boundary-Konverter**: `TextFromUtf16` /
  `TextFromUtf16Bom` / `TextUtf16Length` / `TextToUtf16` / `TextToUtf16Bom`,
  Byte-Reihenfolge über `UTF16_BE` / `UTF16_LE`. Surrogate-Paare in beide
  Richtungen; fehlerhafte Eingabe (unpaariges High-/Low-Surrogate,
  abgeschnittenes Paar, ungerades Rest-Byte) wird zu U+FFFD statt zum Fehler,
  das Ergebnis bleibt also gültiges UTF-8. BOM wird erkannt und entfernt bzw.
  auf Wunsch geschrieben; ohne BOM gilt Big-Endian (RFC 2781). Tabellenfrei.
  Damit ist der letzte offene Punkt der Encoding-Entscheidung erledigt — UTF-16
  bleibt reines Grenzformat, intern ist alles UTF-8.

### Doku / Beispiele
- **`examples/basics/text_operators.lyx`**: Showcase für `Text` (Methoden,
  Operatoren, Codepoint- vs. Byte-Indizierung).
- **`DATATYPES.md` §5.1**: `String` (Bytes-Ebene) vs. `Text` (UTF-8-Ebene),
  Operator-Tabelle, Normalisierungs-Fallstrick, Lebensdauer.
- **`README.md`**: String-Modultabelle um `std.strtype`, `std.text`,
  `std.unicode`, `std.unicode_case`, `std.grapheme` ergänzt.

### Bekannte Grenze
- Volles Case-Folding mit 1:n-Expansion (ß→ss, ﬁ→fi) ist nicht abgedeckt; die
  simple 1:1-Faltung kann das nicht ausdrücken.

Verifiziert: `make test` 20 PASS / 0 FAIL; Smoke-Test über Methoden, Operatoren
und Free-Function-Wrapper; `std.unicode`/`std.unicode_case`/`std.grapheme` laufen
gegen das Klassen-`Text`.

## Version 1.0.8C (Juli 2026)

Operator-Overloading komplettiert (Stufen 2b, 2c, 3) + `!=`-Fallback. Basis V1.0.8B.

### Compiler
- **Verkettete Ausdrücke** (2b): `a + b + c`, `(a+b)*d` — `cg_exprClassName` löst
  die statische Klasse auch eines Arithmetik-Overloads auf (Result = Links-Klasse).
- **Voller Operator-Satz** (2b): `!=` Ne, `<` Lt, `<=` Le, `>` Gt, `>=` Ge; Index
  `a[i]` → `a.Get(i)` (neuer Zweig vor dem normalen CGN_INDEX-Pfad).
- **Call-Ergebnis-Operanden** (2c): `f() + g()` wenn eine freie Funktion einen
  class-Rückgabetyp hat (neue `fnRetList`-Registry: funcName → Rückgabetyp-Name,
  Klasse zur Lookup-Zeit via `cg_findClass`).
- **`!=`-Fallback**: eine Klasse mit nur `Eq` bekommt `!=` gratis (`a.Eq(b)` +
  logisches NOT, wenn kein `Ne` definiert).
- Trigger bleibt eng (nur class-Operanden) → int/f64/pchar-Binops, Vergleiche und
  normale Array/pchar-Indizierung unverändert.

### Standardbibliothek / Doku
- **`std.strtype.String`**: Operator-Methoden `Eq`/`Ne`/`Compare`/`Lt`/`Le`/`Gt`/
  `Ge`/`Get` ergänzt → String-Operatoren arbeiten **inhaltsbasiert** (vorher fiel
  `==` mangels `Eq` auf einen Pointer-Vergleich zurück).
- **`examples/basics/operator_overloading.lyx`**: Showcase (Vec-Klasse + String).
- **`ebnf.md` §15.3**: Semantik-Notiz zum Operator-Overloading (kein Grammatik-
  Zusatz — Overload-Resolution ist per §19 ohnehin außerhalb der EBNF).

Verifiziert je Stufe: Selbst-Host-Fixpunkt gen2==gen3; `make test` 20 PASS/0 FAIL.

## Version 1.0.8B (Juli 2026)

Operator-Overloading für User-Klassen (Stufe 2a). Basis V1.0.8A.

- **`a + b` → `a.Add(b)`** wenn der linke Operand ein Identifier mit class-Typ
  ist, dessen Klasse die Operator-Methode definiert. Generisch — jede Klasse
  mit passender Methode (String, Vec, BigInt …), kein String-Hardcode.
- Operator → Methode: `+` Add, `-` Sub, `*` Mul, `/` Div, `%` Mod, `==` Eq.
- Umsetzung im Codegen (x86): `cg_tryClassBinop` erkennt den class-Ident-Links-
  Operanden über `localTypes`, baut den mangled Namen `ClassName_Method`, prüft
  das Label und emittiert einen direkten Method-Call (Receiver→rdi/self,
  Arg→rsi, Ergebnis rax). Neuer Zweig im CGN_BINOP-Handler neben
  `pchar+pchar→StrConcat` und `parallel-Array→SIMD`. Trigger bewusst eng (nur
  Ident-Links-Operand) → int/f64/pchar-Binops unverändert.
- **Vertagt** (spätere Stufen): verkettete Ausdrücke `(a+b)+c` (Return-Typ-
  Inferenz), `!=`/`[]`/Vergleichs-Overloads, `Text`-Operatoren.

Verifiziert: `Vec{x,y}` mit Add — (1,2)+(10,20)=(11,22); `std.strtype.String`
"Hello, "+"World!" konkateniert (Länge 13, korrekte Bytes) + `c == c` → Eq;
int/f64/pchar-Binops unverändert; Selbst-Host-Fixpunkt gen2==gen3;
`make test` 20 PASS/0 FAIL.

## Version 1.0.8A (Juli 2026)

Vollständiger String- und Unicode-Stack. Basis V1.0.7D.

### String- und Text-Typen
- **`std.strtype.String`** — eigener, längentragender String-Wert als Klasse
  (mmap-basiert, libc-frei, embedded-NUL-sicher; Append/Substring/Equals/Add),
  Empfänger für das geplante Operator-Overloading (`a + b` → `a.Add(b)`).
- **`std.text.Text`** — UTF-8-Typ: validiert bei Konstruktion, codepoint-aware
  (`TextCodepointCount`/`At`, En-/Decode), Concat, Codepoint-Substring, Find/
  Contains, Trim, Replace, Split, ASCII-Case. Byte-Länge ≠ Codepoint-Zahl.

### Unicode (opt-in Units)
- **`std.unicode`** — Case-Folding (ASCII + Latin-1), Unicode-Whitespace-
  Klassifikation, Text-Level Upper/Lower, und **volle Normalisierung
  NFD/NFC/NFKD/NFKC**: kanonische + Kompatibilitäts-Dekomposition, Canonical-
  Ordering nach Combining-Class, Composition-mit-Blocking, Hangul algorithmisch
  (§3.12). `TextEqualsNormalized` (normalisierungs-insensitiver Vergleich).
- **`std.grapheme`** — UAX #29 erweiterte Grapheme-Cluster (`TextGraphemeCount`/
  `ByteOffset`/`At`): Regeln GB3–GB999 (Hangul, Extend/ZWJ, SpacingMark,
  Prepend, Emoji-ZWJ GB11, Regional-Indicator-Paare GB12/13).
- **`std.unicode_data` / `std.unicode_gbdata`** — aus UnicodeData.txt,
  GraphemeBreakProperty.txt und emoji-data.txt generierte Tabellen (2081
  kanonische + 5914 Kompatibilitäts-Dekompositionen, 968 Combining-Classes,
  961 Composition-Pairs, 1429 Grapheme-Break-Ranges, 451 Extended_Pictographic),
  sortiert + Binärsuche, Lazy-Init. Auf zwei Units gesplittet wegen lyxc-
  Größen-Grenze beim Kompilieren.

### Framework-Integration
- **`data.strbridge`** — String↔Text-Konversion, DataFrame-Utf8-Zelle ↔ Text,
  `DataFrameColumnAllValidUtf8` (UTF-8-Qualitätsprüfung) und
  `DataFrameNormalizeColumnNFC` → normalisierungs-insensitive Group-by/Join auf
  String-Spalten.

Verifiziert e2e (Latin/Greek/Cyrillic/CJK-compat/Hangul, Emoji-ZWJ/Flags,
Ligatur/Superscript/Fullwidth); Selbst-Host-Fixpunkt gen2==gen3.

## Version 1.0.7D (Juli 2026)

Rollout der Compound-Assignment-Operatoren in Standardbibliothek und Beispielen.
Basis V1.0.7C.

- **`std/`** — 3603 `x := x + y`-Muster auf `x += y` (bzw. `-= *= /= %=`)
  umgestellt (238 Units), rein mechanisch (Desugaring-äquivalent), Idempotenz-
  und Kompilier-verifiziert.
- **`examples/basics/`** — neues Showcase `compound_assign.lyx`; control_flow/
  variables/arrays modernisiert (inkl. `const`→`con`-Fix in variables.lyx).

## Version 1.0.7C (Juli 2026)

Rollout der Compound-Assignment-Operatoren in Compiler-Quelle und Daten-
Framework. Basis V1.0.7B.

- **Compiler-Quelle** (`src/`) auf `+=`/`-=` umgestellt und **Bootstrap-Seed
  neu verankert** (Seed kennt die neue Syntax).
- **`data/`-Framework**-Units auf die Compound-Operatoren umgestellt.

## Version 1.0.7B (Juli 2026)

Sprach-Feature: Compound-Assignment-Operatoren. Basis V1.0.7A.

- **`+= -= *= /= %=`** als Parser-Desugaring (`a += b` → `a := a + b`),
  backend-agnostisch. Neue Tokens im Lexer (`TK_PLUSEQ`…`TK_PERCENTEQ`),
  Desugaring nach dem `++`/`--`-Block im Parser, `CompoundAssignStmt` in
  `ebnf.md`. Fixpunkt gen2==gen3, 20 PASS.

## Version 1.0.7A (Juli 2026)

Standard-Daten-Framework: ein einheitliches, geschachteltes, spalten-
orientiertes Datenmodell (Arrow-inspiriert, Lyx-Eigenformat). Basis V1.0.6A.

### Schichten
- **L1 Kernel** (`data.kernel`) — DataType-Tags, wachsender Buffer, Null-Bitmap.
- **L2 Struktur** (`data.frame`) — Field/Column/DataFrame, typisierte Spalten
  Int64/Float64/Utf8, geschachtelte List- und Struct-Spalten (offset-basiert,
  grow-fest).
- **L3 Operationen** (`data.ops`) — Aggregate/Filter/Select/Slice, generischer
  und mehrspaltiger Sort (Merge-Sort), Group-by, Inner/Left/Right/Full-Join,
  Melt/Pivot, sowie **hash-basierte** Group-by/Join (int64 + Utf8, O(n),
  Open-Addressing/FNV-1a).

### IO / Formate
- **CSV** Reader (Typinferenz) + Writer; **JSON** Reader (flach + geschachtelt:
  Arrays→List-, Objekte→Struct-Spalten, mixed-type) + Writer; **natives
  Binärformat** (schnelles Save/Load, nested-aware); `DataFramePrint`
  (ausgerichtete ASCII-Tabelle).
- Robustheit (P0): Buffer-Grow + OOB/OOM-Guards.
- Codegen-Fix: `x as f64` wird als f64-Ausdruck behandelt (Integer-Division-Bug
  bei Doppel-Cast).

## Version 1.0.6A (Juli 2026)

WSP-07: `extern "asm"` externe Daten-Symbole + relocatable Objekt-Ausgabe (ET_REL).
Basis V1.0.5A.

### extern "asm" (WSP-07)
- **Syntax**: `extern "asm" name: Type;` — deklariert ein externes Daten-Symbol
  (neuer AST-Knoten `NK_EXTERN_DATA`). Der Bezeichner liefert an jeder Nutzung die
  ADRESSE des Symbols. Sema registriert es als adress-typisierte Variable ohne
  Initializer; IDENT-Auflösung + Typecheck laufen normal.
- **Auflösung zur Link-Zeit** durch `ld` (z.B. Linker-Skript-Symbole
  `__kernel_start`/`__kernel_end`), nicht durch einen Runtime-Loader.
- **Neuer Ausgabemodus `--emit=obj` (bzw. `-c`)**: relocatable ELF-Objekt (ET_REL)
  statt Executable (x86_64). Eine Section `.ltext` = code||data (interne Refs sind
  RIP-relativ → reloc-invariant). Erzeugt `.symtab`/`.strtab`/`.rela.text`:
  - `R_X86_64_64` gegen das `.ltext`-Section-Symbol für interne absolute Referenzen
    (Klassen-VMTs/Methoden-Zeiger, aus dem bestehenden baseReloc-Set).
  - `R_X86_64_PC32` gegen ein `UNDEF`-Symbol je `extern "asm"`-Nutzung.
  - Globales `_start`-Symbol als Entry (`ld -T script.ld obj.o stub.o`).
- **Fail-closed**: `extern "asm"` ohne `--emit=obj` ist ein Compile-Fehler (kein
  Linker → nicht auflösbar), kein stilles Falschergebnis.
- **Grammatik**: `ExternDataDecl` in `ebnf.md` ergänzt.
- Verifiziert: e2e mit `ld` gegen Assembly-Stub (Symbol-Byte 42 → Exit 42);
  Klassen-Programm mit virtueller Dispatch (R_X86_64_64) + extern (R_X86_64_PC32)
  → Exit 49; `readelf` bestätigt ET_REL/UNDEF-Symbol/Relocs; Selbst-Host-Fixpunkt
  gen2==gen3; `make test` 20 PASS/0 FAIL.

## Version 1.0.5A (Juli 2026)

Inline-Assembly `asm { }` (WSP-05) auf alle funktionalen Backends erweitert — jetzt
architektur-spezifisch statt nur x86 + LyxOS. Basis V1.0.4A.

### asm{} Multi-Backend (arch-spezifisch)
- **Modell**: Jede Ziel-Architektur akzeptiert nur ihre eigenen Mnemonics; ein Mnemonic
  einer fremden Arch ist ein harter Compile-Fehler (wie C-Inline-Assembly). `ir_lower`
  wählt die Mnemonic→Id-Tabelle über das neue `target`-Feld (VMT-sicher: Feld, keine
  neue IRLower-Methode).
- **Neue Backend-Handler** (`IRO_ASM`, op==167):
  - `emit_arm64.lyx` (arm64/macos-arm64/win-arm64/android-arm64): nop, wfi, wfe, sev,
    sevl, yield, isb, dsb, dmb, svc, brk, hlt, ret, eret.
  - `riscv_linux.lyx` (linux-riscv64): nop, wfi, fence, fence.i, ecall, ebreak, mret, sret.
  - `arm_cm_backend.lyx` (arm-cm4/arm-cm33, Thumb-2): nop, wfi, wfe, sev, yield, isb, dsb,
    dmb, svc, bkpt, cpsid i, cpsie i (32-bit-Thumb: höheres Halbwort zuerst).
  - `xtensa.lyx` (esp32/esp32s3): nop (weitere Mnemonics fail-closed, da Byte-Konvention
    nicht gegen einen Assembler verifizierbar).
- **Bestehend unverändert**: x86-64/macos-x86/win-x86 (AST-Pfad `codegen_x86`), LyxOS
  (`emit_lyxos`).
- **Grammatik**: `AsmStmt` + Abschnitt „12.2 Inline-Assembly Rule" in `ebnf.md` ergänzt
  (Soft-Keyword, arch-spezifische Mnemonic-Sets, Fail-closed-Semantik).
- **Vertagt** (pre-existing, ganzer Backend fehlt/hohl, nicht asm-spezifisch): android-x86_64
  (`emitX86_64`-Stub), riscv64-non-linux + arm_cm-non-cm4 (leere `emit()`).
- Verifiziert: Byte-Encodings je Arch, Cross-Arch-Fail-closed, x86/LyxOS-Regression grün,
  Selbst-Host-Fixpunkt gen2==gen3, `make test` 20 PASS/0 FAIL.

## Version 1.0.4A (Juni 2026)

Funktionszeiger + Method-Pointer (Vega-VCL-Event-System) sprachseitig komplett, ELF + LyxOS.
Basis V1.0.3E.

### Funktionszeiger-Felder A1 (#885)
- **fn-Typ-Alias als Klassenfeld**: `type TNE = fn(TControl): int64; type TB = class { on_click: TNE; }`.
  `b.on_click := h` (fn-Name → Adresse), Null-Check, `b.on_click(arg)` (indirekter Call). Zwei
  Wurzeln gefixt: fn-Name-als-Wert lieferte 0 (cg_isDeclaredFunc + lea-Adresse / IRO_FUNC_ADDR);
  `obj.field(args)` wurde als Methode gemangled (Feld-Load + plain indirekter Call).

### Method-Pointer B2 (#886)
- **`method`-Typ = fat pointer {code, data}** mit self-Bindung. `button.on_click := form.Handle`
  bindet `form` als self; `button.on_click(arg)` ruft `form.Handle` mit self=form. Design:
  heap-fat-ptr (Feld = 8B-Pointer → heap{code,data}; kein Klassen-Layout-Umbau). Parser-Befund:
  Typ-Alias-Target wurde verworfen → jetzt gespeichert (TYPE_DECL c0 + iv-Bit1) + method-Alias-Registry.

### fn-ptr/method-ptr Polish (#887)
- **lokaler plain-fn-ptr-Call** `var f := fn; f(args)` crashte (ELF WP-02-Closure-Fehlinterpretation;
  LyxOS „unbekannte Funktion") → thin-call / _findLocalSlot+CALL_INDIRECT.
- **benannte Params** in fn/method-Typ (`fn(s: T)`, `method(s: T)`) parsen jetzt.
- **cross-module method-Felder** (importierte Klasse) auf LyxOS (_treg-Context-Swap).

### sema (#884)
- **Arity-Check**: Argument-Anzahl bei Funktionsaufrufen wird geprüft (vorher KEINE Prüfung →
  `add(5)` für `fn add(a,b)` kompilierte → Garbage/Crash). Konservativ (same-module, nicht extern/variadic).

## Version 1.0.3E (Juni 2026)

Windows-Backend-Korrektheit. Basis V1.0.3D.

### Windows PE32+ (win64)
- **Beschreibbare Globals + argc/argv (#882)**: win64 hatte keine beschreibbaren globalen
  Variablen — Daten/Globals liegen im single-section-Design am `.text`-Ende, aber `.text` war
  nur CODE|EXECUTE|READ → jeder globale Schreibzugriff (`g := x`) page-faultete. Zusätzlich
  speicherte `_start` argc/argv nicht in die Globals (GetArgC/GetArgV lasen 0). Fix: `.text` →
  +MEM_WRITE; `_start` schreibt argc/argv nach CG_ARGC/CG_ARGV (rip-relativer Store, disp gepatcht).
  Wine-verifiziert: globale Writes, GetArgC/GetArgV/ArgvGet korrekt.

Verifiziert: wine (global-write, GetArgC 1/4/2, ArgvGet); ELF-Pfad unberührt; Singularität S3==S4.

## Version 1.0.3D (Juni 2026)

LyxOS-Kernel-Systemprimitive (WSP). Basis V1.0.3C.

### LyxOS — WSP-Systemprimitive
- **cpu-ctrl / Fences / Atomics (#877)**: Builtins für Kernel-Treiber — cpu_pause/hlt/cli/sti/rdmsr/wrmsr,
  fence_sfence/lfence/mfence, atomic_load/store(xchg)/cas(lock cmpxchg)/fetch_add(lock xadd).
- **@volatile (#879)**: volatile-Loads von DCE ausgenommen (MMIO/Hardware-Register-Reads bleiben
  erhalten; callmode-Sentinel-Markierung).
- **@align(n) (#880)**: array/heap-backed Locals N-Byte-aligned alloziert (über-alloc + round-up;
  DMA/MMIO/SIMD/Page-Buffer). Neues Var-Attribut, ebnf.md ergänzt.

Verifiziert: Atomics runtime (store_load/fetch_add/cas), @volatile (Load überlebt DCE), @align
(Disasm over-alloc+round); intrinsics 70/70, call_args 8/8, wp4 4/4; Singularität S3==S4
(3c0068e2); voll-lyxc→LBF baut (3.85 MB). ELF-Pfad unberührt. Offen (WSP): asm{}-Block,
extern/FFI echte Linkage (Reloc-Consumer).

## Version 1.0.3C (Juni 2026)

LyxOS-SIMD vervollständigt. Basis V1.0.3B.

### LyxOS — SIMD-Reste (#875)
- **AND/OR/XOR** auf parallel Array<f32> → `andps`/`orps`/`xorps` (vektorisierte SSE2-Loop).
- **NEG** (`-vec`) → packed Vorzeichenbit-Flip (`pcmpeqd`+`pslld 31`+`xorps`).
- **CMP_EQ/NE/LT/LE/GT/GE** → `cmpps` mit Prädikat-Imm (Masken-Vektor pro Lane).
- Damit ist SIMD vollständig: Allokation, f32-Element-Zugriff, Arithmetik (ADD/SUB/MUL/DIV, #873)
  und nun Bitwise/Negation/Vergleich.

Verifiziert: NEG runtime (-5→5), AND/OR/XOR/CMP Disasm; intrinsics 62/62, call_args 8/8;
Singularität S3==S4; voll-lyxc→LBF baut (3.83 MB). ELF-Pfad unberührt. Offen: WSP-System-
primitiven, Kernel-Runtime-Bestätigung (uidemo/lyxc-LBF).

## Version 1.0.3B (Juni 2026)

LyxOS-Sprach-Features: Adresse-von, korrekter f64-Vergleich, SIMD. Basis V1.0.3A.

### LyxOS (#872, #873)
- **@local Adresse-von (#872)**: `@x` (TK_AT) liefert auf lyxos jetzt die Slot-Adresse
  (lowerUnOp op==111 → IRO_LOAD_LOCAL_ADDR, lea); ELF konnte es bereits.
- **ucomisd-f64-Vergleich (#872)**: f64-Vergleich nutzt jetzt `ucomisd` (IRO_FCMP_*) statt
  Integer-CMP der IEEE-Bits → korrekt auch für negative f64 (vorher Ordering kaputt).
- **SIMD parallel Array<f32> (#873)**: aligned-mmap-Allokation (count @ ptr-8), f32-Element-
  Zugriff (movss + f32↔f64-Konvertierung), vektorisierte SSE2-Binops (addps/subps/mulps/divps).
  Runtime-verifiziert (lbf_run). SIMD AND/OR/XOR/NEG/CMP weiter offen (kontrollierter Abbruch).

Verifiziert: intrinsics 61/61, call_args 8/8; Singularität S3==S4; voll-lyxc→LBF baut (3.82 MB).
ELF-Pfad unberührt. Offen: WSP-Systemprimitiven, Kernel-Runtime-Bestätigung (uidemo/lyxc-LBF).

## Version 1.0.3A (Juni 2026)

Minor-Release: LyxOS-Codegen-Kern abgeschlossen — vollständige OOP, alle reachable IR-Opcodes,
f64-Pipeline. Basis V1.0.2I.

### LyxOS — cross-module OOP (#866)
- Globales Type-Registry: jeder `NK_TYPE_DECL` aller Module bekommt eine stabile globale type-id
  (modul-unabhängig). Behebt importierte Klassen: `new` mit korrekter Größe/VMT/type-id,
  Feld-Zugriff, virtuelle Dispatch über Modulgrenzen. Damit ist die OOP-Kette komplett
  (geerbte Felder #856, virtuelle Dispatch #857, importierte Methoden #861, Konstruktor-Args #864,
  cross-module #866).

### LyxOS — Opcode-Reste (#867)
- Div/Mod durch 0 → kontrollierter Panic (Exit 1) statt SIGFPE (ASSERT_NOT_ZERO).
- FSQRT (sqrtsd), Diagnostik-Ops (INSPECT/PROFILE) → expliziter NOP, SIMD → expliziter Abbruch,
  LOAD_LOCAL_ADDR-Infra (&local; Parser-Support ausstehend). Kein reachable Opcode mehr im
  INT3-Catch-all.

### LyxOS — f64-Pipeline (#868)
- f64-Literale (Quelltext → IEEE-754 via `_parseFloatBits`), Arithmetik (FADD/FSUB/FMUL/FDIV →
  addsd/subsd/mulsd/divsd), Casts f64↔int (ITOF/FTOI → cvtsi2sd/cvttsd2si), sqrt end-to-end.
  Runtime-verifiziert (lbf_run): add/mul/div/sub/sqrt/casts/Vergleich. f64-Bits liegen als int64
  im Slot, xmm-Ops laden via movsd.

Verifiziert: intrinsics 53/53, call_args 8/8, wp4 4/4; Singularität S3==S4; voll-lyxc→LBF baut
(3.81 MB). ELF-Pfad unberührt. Offene Folge-Items: Parser unary-`&`, ucomisd-f64-Vergleich
(negative Ordering), xmm-Vektor-SIMD; Kernel-Runtime-Bestätigung (uidemo/VUI, lyxc-als-LBF).

## Version 1.0.2I (Juni 2026)

Patch-Release auf Basis von V1.0.2H. LyxOS-Backend: unbehandelte IR-Opcodes, Konstruktor-Args.

### LyxOS-Nativ (emit_lyxos / ir_lower)
- **Unbehandelte IR-Opcodes emittiert + Catch-all gehärtet (#863)**: emit_lyxos verwarf reachable
  Opcodes STILL (kein Code) → stilles Falschverhalten. Jetzt emittiert: NOT(50)/BITNOT(58),
  ASSERT_NOT_NULL/NOT_ZERO/TRUE(158-160)+BOUNDS(157)→`emitPanicExit`, PANIC(121), CALL_INDIRECT(85)→
  `emitCallIndirect`, CALL_EXTERN(84)→dest=0 (kein lyxos-Linkage), POOL_ALLOC/FREE(115/116)→no-op.
  STUB-00: Catch-all → INT3 (lauter Runtime-Trap) statt stillem Drop. Sicherheit: ASSERT_*-Checks
  wirken jetzt. (Offen, nun INT3-Trap: FSQRT(155), SIMD(122-131), INSPECT(153), PROFILE(161-163).)
- **Konstruktor-Args (#864)**: `lowerNew` allozierte Objekt + type-id, rief den Konstruktor GAR NICHT
  → `new C(11)` ließ Felder 0 (Args ignoriert). Fix: lowerNew ruft nach alloc+type-id
  `ClassName_Create(self, args...)` falls definiert (Konvention wie ELF #683; cross-module via
  `_findFuncByName` → auch importierte Ctors). Behebt die TForm.Create-Kaskade (frm.Root()=null → #PF).

Verifiziert: lbf_run `~240&0xFF`=15/`!0`=1/`!5`=0/ctor_0arg=5; Konstruktor-Disasm zeigt Arg + `call
Class_Create` (ELF-Referenz=11); intrinsics 41/41, call_args 8/8, wp4 4/4, imported-dispatch 1/1;
Singularität S3==S4; voll-lyxc→LBF baut (3.75 MB). ELF-Pfad unberührt. OOP-Runtime am echten Kernel.

## Version 1.0.2H (Juni 2026)

Patch-Release auf Basis von V1.0.2G. LyxOS-Backend: Array-Store-DCE-Bug, sema-Builtins, importierte OOP-Methoden.

### LyxOS-Nativ (ir_optimize / ir_lower / sema)
- **STORE_IDX DCE-Bug (#859)**: `IRO_STORE_IDX` fehlte in `ir_optimize.hasSideEffect` → DCE eliminierte
  ALLE Array-Element-Stores (`a[i] := v`) auf dem lyxos-IR-Pfad (dest=idx-temp galt als tot → NOP).
  Fix: STORE_IDX in hasSideEffect. wp4_fields jetzt 4/4.
- **pipe/truncate sema-Registrierung (#859)**: `_regBuiltin("pipe"/"truncate")` — die lowerCall/emit-
  Einträge (id 231/232) lagen bereit, waren aber unerreichbar.
- **Methoden-Dispatch importierter Klassen (#861)**: eine Methode einer importierten Klasse (z.B.
  TForm.Run aus vui) kehrte sofort zurück statt zu laufen — (a) `_findTypeDecl` scannte nur das aktuelle
  Modul → unauflösbar am Call-Site → kein Dispatch; (b) der transitive Import-Pre-Pass registrierte
  Methoden importierter Klassen nicht. Fix: `_baseTypeNode` liefert den Klassennamen auch ohne lokales
  decl (statische Mangle `Class_method`, cross-module); Pre-Pass registriert importierte Methoden mangled.

Verifiziert: wp4 4/4, intrinsics 37/37, call_args 8/8, neuer importierte-Klassen-Dispatch-Test;
importierte Methode loopt korrekt (lbf_run exit 124, vorher 2). Singularität S3==S4; voll-lyxc→LBF
baut (3.74 MB). ELF-Pfad unberührt (nutzt ir_optimize/ir_lower nicht). OOP-Runtime am echten Kernel.

## Version 1.0.2G (Juni 2026)

Patch-Release auf Basis von V1.0.2F. LyxOS-OOP: geerbte Feld-Offsets + virtuelle Methoden-Dispatch.

### LyxOS-Nativ (ir_lower)
- **OOP Bug #1 — geerbte Feld-Offsets (#856)**: `_fieldOffsetIn`/`_typeSizeOf` ignorierten geerbte
  Basis-Klassen-Felder (extends, c2). `D extends A{val}`: `new D()` alloc(0) + Offset -1 → Garbage
  (d.val=0, self.val=1016). Fix: Basis-Felder flach voranstellen (rekursiv), wie ELF. Am Kernel
  bestätigt: d.val=41, d.S()=42.
- **OOP Bug #2 — virtuelle Methoden-Dispatch (#857)**: ir_lower machte nur statische Dispatch
  (deklarierter Typ) → `a.S()` (a:A hält D) rief A.S() statt D.S(). Fix: switch-dispatch über eine
  type-id @ Objekt-Offset 0 (Klassen mit virtueller Methode; Felder ab +8), closed-world-
  Vergleichskette über Subklassen-Overrides. Kein Daten-VMT/Adress-Patching — nur vorhandene IR-Ops.

Verifiziert: ELF-Referenz a.S()=42; Disasm new D() alloc 16; Tests intrinsics 35/35, call_args 8/8,
wp3 5/5. Singularität S3==S4; voll-lyxc→LBF baut weiter (3.65 MB). OOP-Runtime auf echtem LyxOS-
Kernel zu verifizieren (new→mmap nr9 ≠ Linux). ELF-Pfad unberührt (nutzt ir_lower nicht).

## Version 1.0.2F (Juni 2026)

Patch-Release auf Basis von V1.0.2E. **Meilenstein: lyxc compiliert vollständig zu einem LyxOS-LBF.**
`lyxc --target=lyxos src/lyxc.lyx` erzeugt ein vollständiges natives LBF (~3.6 MB, Magic LYX!) ohne
unaufgelöste Builtins.

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **Transitiver Import-Funktions-Pre-Pass**: globaler Pre-Pass in `lowerModule` registriert alle
  (transitiv) importierten Top-Level-Funktionen im funcBuffer vor dem Body-Lowering. Behebt
  „unbekannter Builtin: StrLen" (lyxc importiert std.string nur transitiv). Iterative Work-Queue
  mit Pfad-Dedup, keine neue IRLower-Methode (Seed-vtable-Schutz). funcId bleibt namensbasiert
  konsistent.
- **0x0200-VFS-Block** (kernel-adoptiert, Commit 6e02a6f): `lseek`(0x0204), `stat`/`lstat`(0x0205
  ±NOFOLLOW), `symlink`(0x0213), `rmdir`(0x0208+UNLINK_DIR), `nanosleep`(0x000A sleep_ns,
  timespec→ns). dir_fd(AT_CWD=-1)/flags via CONST_INT-Injektion in den argBase-Block.
- **Intrinsics/Diagnostik**: `EPrintInt`→stderr (`emitPrintIntFd`), `ArgvGet` (lea+deref),
  `getdents64`→read-on-dirfd, `clock_gettime`→sys_time_ns+timespec-Split, `chmod`/`chown`→no-op.
- **Gruppe D** `sys_fork`/`sys_execve`/`sys_wait4` → return -1 (LyxOS hat kein fork/exec/wait-
  Prozessmodell, nur sys_spawn_child; einzige Nutzer self_test/lbf_loader laufen nicht auf LyxOS).

Verifiziert: voll-lyxc→LBF baut blockerfrei (lbfdump 1.1: arch=x86-64); funcId-Konsistenz
lyxos_call_args 8/8; intrinsics 33/33, strength 12/12, caps_tlv 6/6, wp3 5/5. Singularität S3==S4.
Offen (Runtime, kein Compile-Blocker): on-device-Test durch Kernel-Team (LyxOS-Syscall-Nrn ≠ Linux).

## Version 1.0.2E (Juni 2026)

Patch-Release auf Basis von V1.0.2D. lyxc→LyxOS: Kat-B/C-Builtins (kein Kernel-Bedarf).

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **getdents64(fd,buf,n)** → read-on-dirfd (`sys_read`=0; §10.4 liefert DirEntry-Array bei Verzeichnis-FD).
- **clock_gettime(clk_id, ts)** → id 211: `sys_time_ns`(117) + timespec-Split (tv_sec=ns/1e9, tv_nsec=ns%1e9
  via cqo/idiv); clk_id ignoriert.
- **chmod/chown** → no-op return 0 (LyxOS ist capability-basiert, keine POSIX-Permission-Bits).

Verifiziert: alle vier compilieren auf `--target=lyxos` (kein Catch-all). Runtime der Syscall-Adapter nicht
via lbf_run testbar (LyxOS-Nrn ≠ Linux) → Disasm. Tests: intrinsics 22/22, caps_tlv 6/6. Singularität S3==S4
erhalten. Nächstes Gate für lyxc-self-hosting: StrLen (transitive Import-Resolution).

## Version 1.0.2D (Juni 2026)

Patch-Release auf Basis von V1.0.2C. Schwerpunkt: lyxc self-hosting auf LyxOS — Builtin-Lowering + CAPS-TLV.

### LyxOS-Nativ (ir_lower / emit_lyxos / writer)
- **Gruppe C — Memory-Intrinsics** (ids 200–210): `peek16`/`poke16`/`memcpy` gelowert (argBase-Konvention,
  `movzx`/`mov`/`rep movsb`).
- **Gruppe A — POSIX-File-Builtins** (ids 220–227): `open`/`close`/`read`/`write`/`rename`/`unlink`/`mkdir`/`exit`
  → flache §10.4-Syscalls (kein dir_fd — implementierter Kernel ist flach). Neuer `emitVfsSyscallAB` mit
  argBase statt fester Slots (vermeidet Caller-Local-Aliasing).
- **sizeof(Type)** compile-time fold in lowerCall (via `_findTypeDecl`+`_typeSizeOf`) — entblockt std.string.
- **@capabilities → LBF CAPS-TLV-Mapping**: `writer.lyx` schrieb CAPS-TLV hart als 0 → @capabilities
  wirkungslos, Kernel-Pledge-Gate erlaubte nur STDIO. Jetzt scannt lyxc `NK_CAPABILITY_DECL`, mappt
  Pfad→`LBF_CAP_*`-Bit (fs.read=1/fs.write=2/network=4/process=8/ki.graph=32/ki.embed=16/audio=128),
  OR-Union → `writer.setCapabilities`. CAPS-TLV trägt nun die echten FS-Caps.

Verifiziert: CAPS-TLV [fs.read,fs.write]=3; Syscall-Nrn + Intrinsics disasm-/lbf_run-verifiziert.
Neue Tests: `lyxos_builtin_intrinsics` (22), `lyxos_strength_reduction` (12), `lyxos_caps_tlv` (6) — alle
in `make test`. Singularität S3==S4 erhalten.

## Version 1.0.2C (Juni 2026)

Patch-Release auf Basis von V1.0.2B. Verifizierter Kombi-Build (peek/poke + strength-reduction) und CI-Härtung.

### CI / Test-Infrastruktur
- **`make test` ruft die neuen LyxOS-Regressionssuites auf**: `tests/lyxos_builtin_intrinsics_test.sh`
  (peek/poke/StrCharAt, 10 Tests) und `tests/lyxos_strength_reduction_test.sh` (`*2^k`/`÷2^k`, 12 Tests)
  liefen bisher nicht im `test`-Target. Genau diese Lücke ließ eine gemeldete „peek/poke-Regression"
  in einer stale Zwischen-Binary (ohne den V1.0.2A-ir_lower-Fix) unbemerkt — die develop-Quelle war
  immer korrekt. Beide Suites jetzt im `test`-Target: ein Build kann keinen der beiden LyxOS-Codegen-Fixes
  mehr verlieren, ohne dass `make test` rot wird.

### Verifikation (develop-HEAD, frischer Build)
- peek8("Z")=90, peek8(var s)=90 (Disasm `movzx`, kein PrintStr-Fehldispatch).
- x*4=20, (y*w+x)*4=48 (strength-reduction korrekt).
- Beide Regressionssuites grün (10/10, 12/12); Singularität S3==S4 erhalten.

## Version 1.0.2B (Juni 2026)

Patch-Release auf Basis von V1.0.2A. LyxOS-IR-Optimizer-Korrektheit: Strength-Reduction-Shift-Bug behoben (lbfwin Bug #4).

### IR-Optimizer (ir_optimize)
- **strength-reduction `*2^k` / `/2^k` Shift-Count korrigiert**: `strengthReduction()` setzte beim
  Umbau `MUL`→`SHL` / `DIV`→`SHR` den Shift-Count (`power`) als **rohen Integer** in `src2`
  (`setInstrSrc2(i, power)`). IR-Backends (`emit_lyxos`) lesen `src2` als Temp-/Slot-Referenz →
  `shl rax, cl` lud `cl` aus Slot `#power` (fremde Variable) statt dem Shift-Betrag. Symptom:
  `x*2/4/8/16` → Garbage (oft 0), `x/4/8` → Garbage; non-pow2 (×3,×5,÷3) + expliziter `x<<2` ok.
  lbfwin-Crash: `DrawChar buf+(y*w+x)*4` (BGRA) → wilder Shift → `#PF`. Fix: den Wert des bereits
  von `src2` referenzierten `CONST_INT`-Temps auf `power` ändern (Helper `setConstDefValue`); die
  `src2`-Referenz bleibt — exakt die Form die ein expliziter `x << 2` erzeugt.
  ELF-Prod-Codegen (`codegen_x86`, AST-direkt) nutzt das IR nicht → nur IR-Backends betroffen.

Verifiziert nativ via lbf_run (x*4=20, x/4=5, (y*w+x)*4=48, a*4+b*2=22).
Neuer Test `tests/lyxos_strength_reduction_test.sh` (12/12). Singularität S3==S4 erhalten.

## Version 1.0.2A (Juni 2026)

Minor-Release auf Basis von V1.0.1E. LyxOS-Codegen-Korrektheit: Memory-Intrinsics-Misdispatch behoben.

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **peek/poke/StrCharAt/StrSetChar Misdispatch behoben (Wurzel des fb-Garblings)**: `ir_lower.lowerCall`
  hatte einen stillen Catch-all der jeden nicht explizit gelowerten Builtin auf `IRO_CALL_BUILTIN imm=1`
  (= **PrintStr**) abbildete. `peek8/32/64`, `poke8/32/64`, `StrCharAt`, `StrSetChar` fehlten in der
  lowerCall-Tabelle (anders als im ELF-Pfad) → wurden `write(1,ptr,strlen)`-Syscalls statt Byte-Load/Store.
  Symptom: lbfwin `DrawString` (liest Glyphen via peek8) + `FillWinFb` (schreibt via poke64) scribbelten
  über den Framebuffer. Fix: acht Intrinsics mit echten CALL_BUILTIN-ids (200–207) gelowert; `emit_lyxos`
  emittiert `movzx`/`mov`. Args in hohen argBase-Block gespillt (nicht Slots 0..2, die Caller-Locals aliasen).
- **lowerCall-Catch-all gehärtet**: kein stiller `id=1=PrintStr`-Default mehr → harter Compile-Fehler
  `"unbekannter Builtin/Funktion: <name>"`. Der stille Default versteckte den Bug; ~150 ELF-Builtins fehlen
  noch in lowerCall und werden jetzt laut statt still gemeldet.

Verifiziert nativ via lbf_run (peek8=90, peek64&0xFF=65, StrCharAt=90/67); Store-Encoding disasm-verifiziert.
Neuer Test `tests/lyxos_builtin_intrinsics_test.sh` (10/10). Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1E (Juni 2026)

Patch-Release auf Basis von V1.0.1D. Drei Optimizer-Bugs im lyxos-Backend behoben.

### IR-Optimizer (ir_optimize)
- **getInstrCount-Division**: `instrLen / IR_INSTR_SIZE` (93/80=1) ließ DCE nur eine Instruktion
  sehen → LOAD_LOCAL für Param `a` wurde genoppt → Param `a` immer 0. Behoben via `fnEnd - fnStart`.
- **Cross-Function-Register-Kollision**: Alle Optimizer-Passes scannten den gesamten Instruktions-
  puffer über Funktionsgrenzen hinweg. IR-Register-Nummern starten pro Funktion neu bei 0 →
  `isConstInt(reg)` / `getConstValue()` fanden Konstanten aus einer *anderen* Funktion und falteten
  lebendige Arithmetik falsch (z. B. `f(1,2,3,4,5)` → 7 statt 15). Fix: `fnStart`/`fnEnd`-Felder
  gesetzt pro Funktion in `optimize()`; alle Scan-Loops auf `[fnStart, fnEnd)` eingeschränkt.
- **DCE eliminiert Rückgabe-Register**: `LOAD_LOCAL(dest=0, src1=retValTemp)` — die letzte
  Instruktion die rax vor dem Epilog lädt — wurde von DCE geNOPpt wenn kein anderer Befehl
  Register 0 als Quelle hatte. Das NOP wurde zu `CONST_INT(imm=0)` → rax=0.
  Fix: DCE-Guard `dest > 0` (Register 0 = lyxos-Rückgabe-Register, nie tot).

Wurzel-Symptom: `add5(10,20,30,40,50)` via globaler Variable lieferte 140 statt 150.
Zwei Regressionstests in `tests/lyxos_call_args_test.sh` ergänzt (8/8 grün).

## Version 1.0.1D (Juni 2026)

Patch-Release auf Basis von V1.0.1C. Zwei LyxOS-Codegen-Bugs an der Wurzel behoben.

### LyxOS-Nativ (emit_lyxos / ir_lower)
- **pchar-Variable an PrintStr — echte Wurzel**: `lowerExpr` für `NK_LIT_STR` nutzte
  `nodeIVal` (Parser-Offset) statt des IR-strBuf-Offsets → der Pointer zeigte in die
  Symbol-/Namen-Tabelle ("main"/"gv") statt auf das rodata-Literal. Jetzt via `irAddString`
  interniert (null-terminiert, Escapes verarbeitet). Betrifft alle String-Literale auf
  IR-Backends.
- **user-Funktions-Calls implementiert**: `emit_lyxos.emitCall` war ein Stub (`CALL rel32=0`,
  keine Args/Result) → alle user-fn-Calls kaputt (`g := f(...)` → 0). Jetzt: Args via
  System-V-Register (rdi,rsi,rdx,rcx,r8,r9), CALL-rel32-Patch auf Funktions-Offset,
  Result rax→dest, Callee-Param-Spill Register→Slots.

Verifiziert nativ via lbf_run (call→global=42, 5-arg=15, nested=16, pchar x[0]='H').
Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1C (Juni 2026)

Patch-Release auf Basis von V1.0.1B. LyxOS-Nativ-Backend kernel-tauglich (Multi-Section)
und pchar-Fix; Repo-Hygiene.

### LyxOS-Nativ (emit_lyxos / writer / loader)
- **LYXOS-WP-5 — Multi-Section-Metadaten** nach Kernel-Kontrakt (LX-34): natives `LYX!`
  trägt bis zu 3 SECTION_MAP-TLVs (TEXT/RODATA/DATA + prot) + Genesis text/rodata/data_blocks.
  Image bleibt contiguous-4032 @ VA 0x400000 (RIP-Offsets unverändert, uniform RW, per-Sektion-
  prot kernelseitig deferred). entry_point = volle VA; kein Lifecycle-Handler-Table.
  Loader lädt das ganze Image über die Dateigröße (robust gegen Block-Range-Überlappung).
- **pchar-Variable an PrintStr behoben**: `var x: pchar := "..."; PrintStr(x)` lieferte einen
  falschen rodata-Pointer (null-flood). ir_lower hat jetzt einen PrintStr(non-literal)-Pfad
  (slot0=ptr, slot1=-1 Sentinel); emitPrintStr berechnet strlen zur Laufzeit bei len<0.

### Repo-Hygiene
- Fehlende LBF-Quelldateien (`src/tools/lbf/genesis.lyx`, `tlv.lyx`) + referenzierte Tests
  ins Repo aufgenommen — frischer Checkout baut sonst nicht (`undefined function 'tlv_append'`).

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1B (Juni 2026)

Patch-Release auf Basis von V1.0.1A. Schwerpunkt: nativer LyxOS-Backend (emit_lyxos)
von einem ~10-Op-Skelett zu echtem Codegen ausgebaut (LYXOS-WP-0..4).

### LyxOS-Nativ-Backend (emit_lyxos)
- **WP-1 Arithmetik/Vergleiche**: ADD/SUB/MUL/DIV/MOD, AND/OR/XOR/BITAND/BITOR/BITXOR,
  SHL/SHR, CMP_EQ/NEQ/LT/LE/GT/GE, NEG (x86-64, rax/rcx, CMP+SETcc+MOVZX).
- **WP-2 Control-Flow**: JMP/BR_TRUE/BR_FALSE/LABEL mit dynamischer Label-Tabelle +
  rel32-Patching. Fix: Label-Id steht in IMMINT, nicht LABELOFF.
- **WP-3 Globals**: LOAD/STORE_GLOBAL + LOAD_GLOBAL_ADDR über RIP-relativen Daten-Pool
  (Init-Werte aus IR globalBuffer).
- **WP-4 Fields/Index**: LOAD/STORE_FIELD (+HEAP), LOAD/STORE_IDX für structs/arrays.
- Verifikation: lyxos sys_exit==Linux 60 → compute-only LYX! via lbf_run nativ ausgeführt;
  Heap-Pfade Disasm-verifiziert. Tests in `make test` (lyxos_wp1..4).
- LX-30: nativer `--target=lyxos` LYX!-Emit dokumentiert/getestet; lyxc self-compiliert
  zu validem nativem lyxos-LYX!.

### Offen
- LYXOS-WP-5 (Multi-Section W^X, entry_point-Konvention, Lifecycle-Events) — wartet auf
  Kernel-Loader-Kontrakt-Abstimmung (Spec §11b).

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1A (Juni 2026)

Patch-Release auf Basis von V1.0.0A. Schwerpunkt: Sicherheits-Härtung, Korrektheit
und Erweiterung der Backend-/Nativ-Unterstützung.

### Security (Audit-Verifikationspass)
- FFI-Sandbox **fail-closed**: unbekannte Externs erfordern `@cap(...)`; PROCESS-Klasse
  + no-link-Pfad gehärtet (`FFI_CLASS_UNKNOWN`, TCB-Modell std.*/src.*).
- `calloc()` Integer-Overflow-Guard; alle `read()`-Pfade (inkl. `cg_readFile`) OOB-gehärtet.
- DNS-rdata-Doku-Hazard (64- vs 128-Byte-Puffer) behoben; TLS-Hostname-Verifikation
  per CI verankert. RandInt64 silent-0 → `exit(1)`.
- Jeder Fix mit CI-Regressionstest (sec_*-Suite).

### Korrektheit
- `--std-path=` Off-by-one (lieferte `=PATH`) behoben.
- Makefile-Paketversion synchronisiert.

### Backend / Nativ
- **ARM64-Backend wiederbelebt**: con-Namens-Kollision (Target-Routing), `_start`→main,
  lokales/nested Assignment, PrintInt, Arrays, Globals, plain structs + statische Methoden
  (qemu-verifiziert). x86 unverändert.
- **Nativer LYX!-Loader/Runtime** (`lbf_run`): LYX!-Datei laden + in-process ausführen
  (mmap RWX + Sprung). `_indirect_call_0/_1` im x86-Codegen.

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.0A (Juni 2026)

Erste Alpha-Version (V1.0.0A) — vollständiger Sprachkern, self-hosting (Singularität),
echte OOP-Vererbung und Backend-Parität inkl. vollständigem Windows-PE32+-Target.
Enthält lyxc-Fix-Backlog L1–L6, WP-A2 (Windows), WP-28..37 (Security), V-1..3 und
BUG-1..8.

### OOP / Vererbung

- **L1 — Feld-Layout-Vererbung**: Felder einer Basisklasse werden in das Layout der abgeleiteten Klasse flach vorangestellt; geerbte Felder erhalten korrekte Offsets (`cg_buildClassLayout`/`cg_buildStructLayout`).
- **L2 — virtuelle Dispatch über Basis-Pointer**: `extends`-Parent korrekt erfasst (Parser `_sc2`-Setter-Bug); `override`/`abstract` implizieren `virtual`; virtuelle Methoden werden dynamisch über die vtable aufgerufen (`cg_genCall`); abgeleitete Klassen erben die vtable, `override` ersetzt den Slot, geerbte nicht-überschriebene Slots werden base→derived propagiert.

### Parser

- **L4 — `[N]T` Prefix-Array-Felder**: `kids: [4]Node;` wird geparst (führendes Integer-Literal nach `[` disambiguiert gegen Tuple-Typen); erzeugt denselben Array-Knoten wie die Suffix-Form `T[N]`.
- **L5 — `form` als Soft-Keyword**: `form` ist überall als normaler Bezeichner nutzbar; das Top-Level-`form`-Konstrukt wird kontextuell per Text erkannt.
- **L6 — lesbare Diagnostik**: Parse-Fehler nennen Token-Namen und das tatsächliche Lexem statt roher Token-IDs (z. B. „expected IDENT, got form 'form'").

### Windows PE32+ — vollständiges OOP & Funktionen (WP-A2)

- **A2.1**: Trampolin-Zone exakt auf die `CG_H_*`-Helper-Offsets ausgerichtet — `wine hello.exe` gibt korrekt aus (vorher Müll, weil PrintStr-Calls in den PrintInt-Helper durchfielen).
- **A2.2**: Unified Base-Relocation — Codegen registriert absolute VMT-Pointer; PE-Backend emittiert echte `.reloc`-Blöcke (`IMAGE_REL_BASED_DIR64`) + rebased die Werte → ASLR-tauglich.
- **A2.3**: `new`/alloc nutzt `VirtualAlloc` statt Linux-`mmap`-syscall.
- **A2.4**: `_start`→`main`-Aufruf korrigiert (`relMain + 14`) — alle user-Funktions-/Methoden-Calls funktionieren.
- Verifiziert unter wine: Funktionen, Rekursion, virtuelle Dispatch, Vererbung, Felder, Heap, Output.

### Security (WP-28..37)

- **WP-28**: Kernel-Mode-Guard Allowlist — `@kernel_mode` Attribut blockiert unsichere Imports
- **WP-29**: Ed25519-Lizenzverifikation — asymmetrische Signaturprüfung ohne RSA-Overhead
- **WP-30**: HTTP Custom-Header CRLF-Injection-Schutz — `\r\n` in Header-Werten wird abgelehnt
- **WP-31**: `FileReadAll` 256-MB-Limit — schützt vor OOM-Angriffen via überdimensionale Dateien; explizite Größenprüfung auch in lyxc selbst (Seed-Binary-Invarianz)
- **WP-32**: TOCTOU-Schutz `ms_appendMetaSafe` — atomares Append mit POSIX-Locks
- **WP-33**: String-Library Bounds-Hardening — alle Slice/Sub-Operationen prüfen Grenzen
- **WP-34**: Codegen-Buffer-Größenlimit — verhindert Stack-Overflow bei pathologischen Inputs
- **WP-35**: LYU-Parser symCount-Limit — begrenzt Symboltabellengröße in Precompiled Units
- **WP-36**: `SecureZero` Compiler-Barriere — `poke8`-basiertes Nullen verhindert Dead-Store-Elimination
- **WP-37**: `RandInt64` Fehlerbehandlung — `getrandom`-Fehler werden propagiert, kein Silent-Fail

### V1-Blocker (LyxOS Self-Hosting)

- **V-1**: `--target=lyxos` Segfault bei großen Programmen — behoben
- **V-2**: LyxOS Builtin-I/O falsche Syscall-Nummern — `sys_open=0x200`, `sys_read=0x202`, `sys_write=0x203` korrekt gesetzt
- **V-3**: `lyxc` dynamisch gelinkt via `explicit_bzero` — ersetzt durch `poke8`-Loop (PR #789); `lyxc` ist jetzt vollständig statisch

### P0-Blocker (V1.0.0A Milestone)

- **WP-A2**: Windows PE32+ `.reloc`-Section + ASLR (PR #791) — `win_x86.lyx` und `win_arm64.lyx` emittieren jetzt eine gültige `.reloc`-Section mit leerem `IMAGE_BASE_RELOCATION`-Block; BaseReloc-DataDir korrekt verdrahtet; `DllCharacteristics=0x8160` (DYNAMIC_BASE|NX_COMPAT|HIGH_ENTROPY_VA)

### Security Audit Fixes (PR #790)

- **SEC-BUG-05**: `PathNormalize` — segment-stack-basierter Algorithmus ersetzt fehlerhaften one-pass `..`-Handler; 80-Byte Buffer-Overflow gefixt; sicherer gegen path-traversal-Angriffe

### Compiler-Bugs (BUG-1..8)

- BUG-1: Importierte Konstanten im Bootstrap — behoben
- BUG-2: VMT-Kollision bei identischen Methodennamen — behoben
- BUG-3: Klassen-Instanz-Parameter — behoben
- BUG-4: 7-Argument-Overflow — behoben
- BUG-5: `break` als NOP in verschachtelten Schleifen — behoben
- BUG-6: r8/r9 werden nicht gespillt — behoben
- BUG-7: `BUG-1`-Typenfeld-Offset — behoben (PR #769)
- BUG-8: TypeName.field Offset immer 0 — behoben

### Test Suite

- `make test` grün: alle Tests PASS (LX-25..36, net_frame 45 Tests, WP-28..37 je 20 Tests)
- sec_wp37 in Makefile eingetragen

### P1-Status (86% ✅, Kriterium ≥80%)

C1 TmpFile, C2 Trig-Funktionen, C4 StrFormat, C5 URL-Encode/Build/Resolve, C6 HTTP PUT/DELETE/PATCH/HEAD, C8 log_info_kv — alle implementiert.
A4 (`@big_endian` ARM64 REV-Emission) bleibt offen.

---

## Unreleased

### Parser
- **Multi-import syntax**: `import a, b, c;` expandiert direkt in drei `NK_IMPORT`-Knoten — kein neuer AST-Knoten, Sema/Lowering/Codegen unverändert. Beide Formen sind gültig.

## Version 0.7.0-aerospace (April 2026) 🎉

### 🚀 **DO-178C Compliance**

#### **Tool Qualification (TQL-5)**
- `--version` flag (TOR-001): SemVer + TQL level output
- `--build-info` flag (TOR-002): Build hash, host, FPC version, determinism
- `--config` flag (TOR-003): All configuration parameters documented
- TOR-010: Deterministic code generation validated (SHA-256 comparison)
- TOR-011: 100% IR coverage in all 6 backends
- TOR-012: Error messages with source positions
- TOR-040: Reproducible builds (10x stress test passed)
- TOR-041: No hidden dependencies (static binary, no libc)
- TOR-042: Deterministic optimization

#### **MC/DC Instrumentation (DAL A)**
- `--mcdc` flag for coverage instrumentation
- `--mcdc-report` for coverage report generation
- `__mcdc_record` builtin in all 7 backends
- Coverage report: Decision | Function | Line | T | F | Status

#### **Static Analysis (7 Passes)**
- `--static-analysis` flag
- **Data-Flow Analysis**: Def-Use chains with use-location tracking
- **Live Variable Analysis**: Detects unused variables (warnings)
- **Constant Propagation**: Tracks known constants through irAdd/irSub/irMul
- **Null Pointer Analysis**: Tracks potentially null pointers from ConstStr
- **Array Bounds Analysis**: Static index safety verification
- **Termination Analysis**: Detects unbounded loops and recursive calls
- **Stack Usage Analysis**: Worst-case stack calculation per function

#### **Test Generation**
- **Fuzzing**: 50 random Lyx programs, 0 crashes, 50 unique inputs
- **Boundary-Value Analysis**: 28 tests across 4 categories (all passed)
- **Mutation Testing**: 3 mutations generated, 1 killed (33% score)
- **Symbolic Execution**: 15 paths explored through if/else trees

### 🌐 **New Backends**

#### **RISC-V RV64GC** (`--target=riscv`)
- Full RV64I emitter with LP64D ABI
- PMP configuration (16 regions, NAPOT/NA4/TOR modes)
- CSR access (read/write/set/clear)
- ECALL/EBREAK, Fence/WFI
- Machine Mode support (mret, get_mhartid, get_mcycle)
- ELF64 writer for RISC-V (EM_RISCV=243)

#### **ARM Cortex-M** (`compiler/backend/arm_cm/`)
- MPU configuration (8 regions, 6 AP modes)
- Fault handlers (HardFault, MemManage, BusFault, UsageFault)
- Stack canary detection ($DEADBEEF pattern)
- Privileged/Unprivileged mode switching
- TrustZone stubs (M33+)

### 🛡️ **Safety Features**

#### **ESP32 Safety**
- Watchdog: `watchdog_init()`, `watchdog_feed()`, `wdt_reset()`
- Brownout: `brownout_check()`, `brownout_config()`
- Flash: `flash_verify()`, `secure_boot()`
- MPU: `mpu_config()`, `pmp_lock()`
- Stack: `stack_canary_check()`
- Cache: `cache_flush()`
- Coredump: `coredump_save()`

#### **ARM Cortex-M Safety**
- MPU: `mpu_enable()`, `mpu_config()`
- Fault: `get_fault_status()`, `get_fault_address()`, `clear_fault_status()`
- Stack: `stack_canary_check()`
- Mode: `set_unprivileged()`, `set_privileged()`
- Debug: `bkpt()`

#### **RISC-V Safety**
- PMP: `pmp_config()`, `pmp_lock()`
- CSR: `csr_read()`, `csr_write()`, `csr_set()`, `csr_clear()`
- Control: `ebreak()`, `fence()`, `fence_i()`, `wfi()`, `mret()`, `sret()`
- Info: `get_mhartid()`, `get_mcycle()`, `get_time()`

### 📊 **IR Coverage**
- **100% IR coverage** in all 7 backends (113/113 operations)
- x86_64: ✅ 100% · x86_64_win64: ✅ 100% · arm64: ✅ 100%
- macosx64: ✅ 100% · xtensa: ✅ 100% · win_arm64: ✅ 100% · riscv: ✅ 100%

### 📚 **Documentation**
- **COMPILER_MANUAL.md**: Complete compiler documentation
- **USER_GUIDE.md**: User-facing guide with examples
- **VERIFICATION_REPORT.md**: DO-178C verification report (111/111 tests passed)
- **aerospace-todo.md**: Updated with completed items
- **README.md**: Updated with new features

---

## Version 0.5.7 (April 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **String-Bibliothek (std.string) v0.5.7**

Erweiterte String-Manipulationsfunktionen:

```lyx
import std.string;

fn main(): int64 {
    // StringBuilder für effizientes Konkatenieren
    var sb: StringBuilder := new StringBuilder();
    sb.Init(64);
    sb.Append("Hello");
    sb.Append(", ");
    sb.Append("World");
    sb.AppendChar(33);     // '!'
    sb.AppendInt(42);
    
    var result: pchar := sb.ToString();
    PrintStr(result);       // Hello, World!42
    StrFree(result);
    
    sb.FreeBuffer();
    dispose sb;
    return 0;
}
```

- **StringBuilder**: Klasse für effizientes String-Building
- **StrTrim**: Entfernt führende/nachfolgende Leerzeichen
- **StrSplit**: Splitst Strings nachDelimiter

#### **Data Library (Pandas-like) v0.5.7**

Umfassende Data-Frame-Bibliothek für Datenanalyse:

```lyx
import std.data.core;
import std.data.io;

fn main(): int64 {
    // CSV einlesen
    var df: DataFrame := ReadCSV("data.csv", true, ",");
    
    // Spalten-Operationen
    var sum: int64 := SeriesSum(df, "sales");
    var avg: f64 := SeriesMeanF64(df, "price");
    
    // Gruppierung
    var grouped: DataFrame := DataFrameGroupBy(df, "category");
    var counts: DataFrame := GroupByCount(grouped, "category");
    
    DataFrameFree(df);
    return 0;
}
```

- **DataFrame**: 2D-Tabellen mit benannten Spalten
- **Series**: 1D-Arrays mit Labels
- **CSV I/O**: ReadCSV, WriteCSV
- **GroupBy**: Gruppierung und Aggregation
- **Filter/Slice**: Daten-Teilmengen
- **Statistik**: Sum, Mean, Min, Max, StdDev, etc.

#### **Validation Library (std.validate) v0.5.7**

Business-Identifier Validierung:

```lyx
import std.validate.ean;
import std.validate.iban;
import std.validate.luhn;
import std.validate.vat;

fn main(): int64 {
    // EAN/ISBN Validation
    var valid: bool := EAN13Validate("4006381333931");
    var isbn: bool := ISBN13Validate("978-3-16-148410-0");
    
    // IBAN Validation
    var ibanValid: bool := IBANValidate("DE89370400440532013000");
    
    // Credit Card
    var cardType: int64 := CreditCardType("4111111111111111");
    var isValid: bool := CreditCardValidate("4111111111111111", 12, 25);
    
    // VAT ID
    var vatValid: bool := VATValidate("DE123456789");
    
    return 0;
}
```

- **EAN/UPC**: EAN-13, EAN-8, EAN-14, ISBN-13/10, UPC-A
- **IBAN**: ISO 13616 Mod 97, 50+ Länder
- **Credit Card**: Luhn-Algorithmus, 8 Kartentypen
- **VAT**: EU 27 Länder mit länderspezifischen Regeln

#### **Statistics Library (std.stats) v0.5.7**

Array-Aggregatfunktionen und Statistik:

```lyx
import std.stats;

fn main(): int64 {
    var arr: array := [3, 1, 4, 1, 5, 9, 2, 6];
    
    var sum: int64 := ArraySum(arr);
    var avg: f64 := ArrayAvg(arr);
    var min: int64 := ArrayMin(arr);
    var max: int64 := ArrayMax(arr);
    var median: f64 := ArrayMedian(arr);
    
    // Sorting
    ArraySort(arr);
    
    // Variance/StdDev
    var variance: f64 := ArrayVariance(arr);
    var stddev: f64 := ArrayStdDev(arr);
    
    return 0;
}
```

- **Aggregates**: Sum, Min, Max, Avg, Median, Count, Product
- **Sorting**: ArraySort, ArrayReverse
- **Filtering**: ArrayFilterGt, ArrayFilterLt, ArrayFilterRange
- **Statistical**: Variance, StdDev, Range, SumSquares

---

## Version 0.5.7 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Enum-Typen (v0.5.7)**

Native Aufzählungstypen mit typsicheren Konstanten:

```lyx
enum Direction { North, South, East, West }
enum Color { Red = 1, Green = 2, Blue = 4 }

fn main(): int64 {
    var d: int64 := Direction::North;
    var c: int64 := Color::Green;
    PrintInt(d);  // 0
    PrintInt(c);  // 2
    return 0;
}
```

- `enum Name { Val, Val = N, ... }` Syntax
- Werte mit optionalem explizitem Integer-Wert
- Zugriff via `EnumName::Wert` (Namespace-Syntax)
- Werden intern als `int64`-Konstanten lowered

#### **Exception Handling: try/catch/throw (v0.5.7)**

Strukturierte Fehlerbehandlung:

```lyx
fn riskyOp(x: int64): int64 {
    if (x < 0) { throw "negative value"; }
    return x * 2;
}

fn main(): int64 {
    try {
        var r: int64 := riskyOp(-1);
    } catch (e) {
        PrintStr("Caught: "); PrintStr(e); PrintStr("\n");
    }
    return 0;
}
```

- `try { ... } catch (varname) { ... }` Syntax
- `throw expr` wirft eine Exception (pchar-Nachricht)
- Nested try/catch vollständig unterstützt
- Implementiert via `irPushHandler`/`irPopHandler`/`irThrow` IR-Opcodes

#### **Multi-Return / Tuple-Rückgabe (v0.5.7)**

Funktionen können mehrere Werte zurückgeben:

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
    return (a / b, a % b);
}

fn main(): int64 {
    var q, r := divmod(17, 5);
    PrintInt(q);  // 3
    PrintInt(r);  // 2
    return 0;
}
```

- Rückgabetyp `(T1, T2)` Syntax
- `return (expr1, expr2)` Tupel-Literal
- `var a, b := f()` Tupel-Destrukturierung
- Implementierung: RAX/RDX Register-Paar (16-Byte Struct Return)

#### **Generics mit Monomorphisierung (v0.5.7)**

Echte generische Funktionen mit Compile-Time-Spezialisierung:

```lyx
fn max[T](a: T, b: T): T {
    if (a > b) { return a; }
    return b;
}

fn main(): int64 {
    var x: int64 := max[int64](10, 20);  // spezialisiert zu _G_max__int64
    PrintInt(x);  // 20
    return 0;
}
```

- `fn name[T](...)` Syntax für generische Typparameter
- `func[int64](...)` Aufruf-Syntax mit konkreten Typen
- Monomorphisierung: jede Typen-Kombination erzeugt eine eigene Funktion `_G_name__type`
- Mehrere Typparameter möglich: `fn zip[A, B](...)`

#### **Pattern Matching mit match/case (v0.5.7)**

Ausdrucksstärkere Alternative zu `switch`:

```lyx
fn classify(n: int64): int64 {
    match n {
        case 0 => { PrintStr("zero\n"); }
        case 1 | 2 | 3 => { PrintStr("small\n"); }
        case 10 | 20 | 30 => { PrintStr("tens\n"); }
        default => { PrintStr("other\n"); }
    }
    return 0;
}
```

- `match expr { ... }` — kein Klammern um den Ausdruck nötig
- `case val => body` — `=>` statt `:`
- OR-Patterns: `case 1 | 2 | 3 =>` — mehrere Werte pro Case
- `default =>` Fallback
- Bestehender `switch`-Syntax bleibt vollständig kompatibel

#### **Dynamische String-Builtins (v0.5.7)**

7 neue Built-in-Funktionen für mmap-basierte dynamische Strings:

```lyx
var s: pchar := StrNew(64);          // Allokiere String-Buffer
StrSetChar(s, 0, 72);               // s[0] = 'H'
StrSetChar(s, 1, 105);              // s[1] = 'i'
StrSetChar(s, 2, 0);                // Null-Terminator
PrintStr(s);                         // "Hi"

var s2: pchar := StrAppend(s, " World");
PrintStr(s2);                        // "Hi World"

var ns: pchar := StrFromInt(-42);
PrintStr(ns);                        // "-42"

PrintInt(StrLen("Hello"));           // 5  (funktioniert auch auf Literalen)
PrintInt(StrCharAt("ABC", 1));       // 66 ('B')

StrFree(s2);
StrFree(ns);
```

| Funktion | Signatur | Beschreibung |
|----------|----------|-------------|
| `StrNew(cap)` | `(int64) → pchar` | mmap-Allokation mit Header |
| `StrFree(s)` | `(pchar) → void` | munmap via Header |
| `StrLen(s)` | `(pchar) → int64` | Strlen (Null-Scan, kompatibel mit Literalen) |
| `StrCharAt(s, i)` | `(pchar, int64) → int64` | Byte-Zugriff (zero-extended) |
| `StrSetChar(s, i, c)` | `(pchar, int64, int64) → void` | Byte schreiben |
| `StrAppend(dest, src)` | `(pchar, pchar) → pchar` | Konkatenation mit Reallokation |
| `StrFromInt(n)` | `(int64) → pchar` | Integer → Dezimalstring |

**String-Header-Layout:** 16 Byte vor dem Daten-Pointer: `[capacity:8][length:8][data...]`. Der zurückgegebene `pchar` zeigt auf `data` und ist direkt mit `PrintStr` kompatibel.

---

### 🔧 **Bugfixes**

- **Generics arr[i] Regression**: Heuristik für Typarg-Parsing war zu breit — `arr[idx]` wurde fälschlicherweise als generischer Typarg geparst. Fix: `IsKnownTypeIdent()` prüft ob der Token ein bekannter Primitiv-Typ oder deklarierter Typparameter ist.
- **Generics Commit Unvollständig**: `TAstFuncDecl.TypeParams` Feld und `savedTypeParams`/`typeParams` Variablen fehlten im Commit. Der Branch `fix/generics` enthält den Fix.

---

## Version 0.5.1 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Linux ARM64 Backend: VMT Support (v0.5.1)**

Vollständige Virtual Method Table (VMT) Unterstützung für Linux ARM64:

```lyx
// Virtual methods on ARM64
type Animal = class {
    fn virtual speak() {
        PrintStr("?\n");
    }
};

type Dog = class extends Animal {
    fn override speak() {
        PrintStr("Woof!\n");
    }
};

fn main(): int64 {
    var a: Animal := new Dog();
    a.speak();  // Dynamischer Aufruf → "Woof!"
    dispose a;
    return 0;
}
```

**Implementierung:**
- `backend/elf/elf64_arm64_writer.pas`: VMT-Tabelle im .rodata Segment
- `backend/arm64/arm64_emit.pas`: Virtual Call via VMT (LDR + BLR)
- `backend/arm64/arm64_emit.pas`: VMT-Pointer bei `new` gesetzt
- `tests/test_arm64_vmt.pas`: Unit-Tests für ARM64 VMT

#### **ARM64 Backend: 100% IR Opcode Coverage (v0.5.1)**

Alle 93 IR-Opcodes sind jetzt für ARM64 implementiert:

**Neu implementierte Opcodes:**
- `irCast`: Type casting (int↔float)
- `irVarCall`: Indirekte Funktionsaufrufe via BLR
- `irCallStruct`: Struct-by-value calls (AAPCS64 ABI)
- `irReturnStruct`: Struct return mit Memory-Copy
- `irIsType`: VMT-basierte Type-Prüfung
- `irPanic`: Panic/Abort mit stderr + exit
- `irPushHandler/irPopHandler/irThrow`: Exception-Handling
- `irInspect`: Debug Visualizer

**ARM64 SIMD/NEON Operationen:**
- `WriteAddSimd`, `WriteSubSimd`, `WriteMulSimd`
- `WriteAndSimd`, `WriteOrSimd`, `WriteXorSimd`
- `WriteNegSimd`, `WriteNotSimd`
- `WriteCmeqSimd`, `WriteCmhiSimd`, `WriteCmgeSimd`

**ARM64 DynArray Support:**
- `irDynArrayPush`: Element hinzufügen mit auto-growth
- `irDynArrayPop`: Element entfernen
- `irDynArrayLen`: Länge abrufen
- `irDynArrayFree`: Speicher freigeben

#### **IR Bugfix: Float Arithmetic (v0.5.1)**

Korrigierte Float-Operationen im IR-Generator:

```lyx
// Vorher: verwendet irSub/irMul/irDiv (Integer)
var z: f64 := x - y;  // ❌ Falscher Opcode

// Jetzt: verwendet irFSub/irFMul/irFDiv
var z: f64 := x - y;  // ✅ Korrekter Opcode
```

---

## Version 0.4.3 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **IR-Level Inlining (v0.4.3)**

Automatische Inlining-Optimierung auf IR-Ebene für bessere Performance:

```lyx
// Funktionen mit ≤12 IR-Anweisungen werden automatisch inlined
fn add(a: int64, b: int64): int64 {
    return a + b;
}

fn main(): int64 {
    var x: int64 := add(10, 20);  // Wird zu: var x: int64 := 10 + 20;
    return x;
}
```

**Implementierung:**
- `ir_inlining.pas`: Vollständiger Inlining-Pass
- Rekursionserkennung vermeidet selbstreferenzielle Inlinings
- Korrektes Argument-Mapping zwischen Caller/Callee
- Return-Statements werden durch Jumps ersetzt
- Mehrere Pässe für verschachtelte Funktionen

#### **Naming Conventions: PascalCase (v0.4.3)**

Alle stdlib-Funktionen verwenden jetzt PascalCase gemäß AGENTS.md:

```lyx
// Vorher (lowercase/snake_case)
printf("Hello %d\n", 42);
clrscr();
gotoxy(10, 5);

// Jetzt (PascalCase)
Printf("Hello %d\n", 42);
ClrScr();
GoToXY(10, 5);
```

**Umbenannte Funktionen:**
- `std/crt`: `TextColor`, `TextBackground`, `TextAttr`, `ClrScr`, `ClrEol`, `GoToXY`, `HideCursor`, `ShowCursor`, `WriteStrAt`, `ReadChar`
- `std/io`: `Printf`
- `std/env`: `Init`, `Arg`
- `std/string`: `StrCmp`, `StrCpy`
- `std/time`: `Now`

---

## Version 0.2.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **SIMD / ParallelArray (v0.2.2)**

SIMD-optimierte Arrays mit element-weisen Operationen:

```lyx
var vec: parallel Array<Int64> := parallel Array<Int64>(1000);
vec[0] := 42;
var first: int64 := vec[0];
var sum: parallel Array<Int64> := vec + vec;  // element-weise Addition
```

**Frontend (Lexer/Parser/AST/Sema):**
- `parallel` und `simd` als Keywords im Lexer
- Parser: `parallel Array<T>(size)` Syntax
- AST: `TAstSIMDNew`, `TAstSIMDBinOp`, `TAstSIMDUnaryOp`, `TAstSIMDIndexAccess`
- Sema: Typprüfung, SIMDKind-Propagierung, Operator-Validierung

**IR-Lowering (vollständig):**
- `nkSIMDNew` → `irAlloc` (Heap-Allokation mit Element-Größe)
- `nkSIMDBinOp` → `irSIMDAdd/Sub/Mul/Div/And/Or/Xor` + Vergleiche
- `nkSIMDUnaryOp` → `irSIMDNeg`
- `nkSIMDIndexAccess` → `irLoadElem` mit korrekter Element-Größe aus SIMDKind
- VarDecl für `atParallelArray`: Heap-Pointer als einzelner Stack-Slot
- Index-Assignment (`vec[i] := value`): Pointer via `irLoadLocal` statt `irLoadLocalAddr`

**Element-Typen:** Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, F32, F64

**SIMD-Operatoren:** `+`, `-`, `*`, `/`, `&&`, `||`, `^`, `==`, `!=`, `<`, `<=`, `>`, `>=`

### ⚠️ **Noch offen (Backend)**
- x86_64 Backend: SSE2/AVX-Instruktionen für `irSIMD*`-Opcodes
- Bounds-Checks bei ParallelArray Index-Zugriff
- Reduce-Operationen (`irSIMDAddReduce`, etc.)

---

## Version 0.4.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Regex-Literale und Regex-Funktionen (v0.4.2)**

Native Unterstützung für reguläre Ausdrücke:

```lyx
var email: pchar := r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$";
var phone: pchar := r"\d{3}-\d{4}";

// Regex-Funktionen
if (RegexMatch(r"abc", "abcdef")) {
    IO.PrintStr("Match!\n");
};
var pos: int64 := RegexSearch(r"\d+", "abc123def");
var count: int64 := RegexReplace(r"old", "text", "new");
```

**Syntax:** `r"pattern"` - Präfix `r` gefolgt von Anführungszeichen

**Funktionen:**
- `RegexMatch(pattern, text)` -> bool: Prüft ob Pattern in Text vorkommt
- `RegexSearch(pattern, text)` -> int64: Position oder -1
- `RegexReplace(pattern, text, replacement)` -> int64: Anzahl Ersetzungen

**Namespace:** `Regex.Match`, `Regex.Search`, `Regex.Replace`

**Compile-Time-Validierung:** Der Compiler prüft die Regex-Syntax

#### **Namespaces für Builtins (empfohlen, rückwärtskompatibel)**

Funktionen können jetzt über Namespaces aufgerufen werden:
```lyx
// Direkter Aufruf (Rückwärtskompatibilität)
PrintStr("Hallo");

// Namespace-Aufruf (empfohlen)
IO.PrintStr("Hallo");
OS.exit(0);
Math.Random();
```

**Verfügbare Namespaces:**
- `IO`: PrintStr, PrintInt, open, read, write, close, etc.
- `OS`: exit, getpid
- `Math`: Random, RandomSeed

#### **Panic und Assert - Fehlerbehandlung zur Laufzeit**

- **`panic(message)`**: Bricht das Programm mit einer Fehlermeldung ab
  - Expression, die nie zurückkehrt
  - Argument muss ein String sein
  - Nachricht wird auf stderr ausgegeben
  - Exit-Code: 1

- **`assert(cond, msg)`**: Runtime-Assertion für Invariantenprüfung
  - `cond` muss ein Boolean sein
  - `msg` muss ein String sein
  - Wenn `cond` false ist, wird `panic(msg)` aufgerufen

**Beispiel:**
```lyx
fn divide(a: int64, b: int64) -> int64 {
    if b == 0 {
        panic("Division by zero!");
    };
    return a / b;
}

fn setAge(age: int64) -> void {
    assert(age >= 0 && age < 150, "Age must be between 0 and 149");
}
```

---

## Version 0.4.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Access Control (Sichtbarkeit) für Klassen-Member**
Private, Protected und Public Member für Klassen und Structs:

- **`pub`**: Überall zugänglich (Standard)
- **`private`**: Nur innerhalb der eigenen Klasse zugänglich
- **`protected`**: In der eigenen Klasse und in abgeleiteten Klassen zugänglich

**Beispiel:**
```lyx
type MyClass = class {
  pub pubField: int64;           // Überall zugänglich
  private privField: int64;       // Nur in der Klasse
  protected protField: int64;    // In Klasse und Subklassen
  
  pub fn pubMethod() { }
  private fn privMethod() { }
};
```

---

## Version 0.4.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Option Types / Nullable Pointer**
Statische Typprüfung für Pointer-Sicherheit zur Kompilierzeit:

- **Nullable Typen**: `pchar?` kann `null` sein
- **Non-nullable Typen**: `pchar` darf nicht `null` sein (Standard)
- **Null-Coalescing**: `??` Operator für sichere Dereferenzierung
- **null Keyword**: Explizite Null-Zuweisung

**Beispiel:**
```lyx
var p: pchar? := null;    // nullable Pointer
var q: pchar;              // non-nullable Pointer (Standard)
var r: pchar := p ?? "default";  // sicherer Zugriff
```

#### **CLI-Argumente im statischen ELF**
Statische ELF-Binaries unterstützen jetzt CLI-Argumente:

- `main(argc: int64, argv: pchar)` wird nach SysV ABI aufgerufen
- argc: Anzahl der Argumente (inkl. Programmname)
- argv: Array der Argument-Strings

---

## Version 0.3.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: Direkte Syscalls (statisches ELF)**
Die I/O-Funktionen werden jetzt als **direkte Linux-Syscalls** generiert:
- Keine libc-Abhängigkeit
- Statisches ELF ohne externe Symbole
- Funktioniert auf x86-64 und ARM64

**Unterstützte Funktionen:**
| Funktion | x86-64 | ARM64 |
|----------|--------|-------|
| `open` | Syscall 2 | Syscall 56 |
| `read` | Syscall 0 | Syscall 63 |
| `write` | Syscall 1 | Syscall 64 |
| `close` | Syscall 3 | Syscall 57 |
| `lseek` | Syscall 8 | Syscall 62 |
| `unlink` | Syscall 87 | Syscall 87 |
| `rename` | Syscall 82 | Syscall 82 |
| `mkdir` | Syscall 83 | Syscall 83 |
| `rmdir` | Syscall 84 | Syscall 84 |
| `chmod` | Syscall 90 | Syscall 90 |

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: Alle I/O-Tests bestanden
- ✅ Unit-Tests: Alle bestanden

---

## Version 0.3.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: fd-basierte I/O via libc Wrappers**
- `open(path: pchar, flags: int64, mode: int64): int64` – Datei öffnen
- `read(fd: int64, buf: pchar, count: int64): int64` – von File-Descriptor lesen
- `write(fd: int64, buf: pchar, count: int64): int64` – auf File-Descriptor schreiben
- `close(fd: int64): int64` – File-Descriptor schließen

Die Funktionen sind als Builtins registriert und werden als externe libc-Calls
via PLT/GOT generiert (dynamic ELF mit `-rdynamic` Linker-Flag).

### 🔧 **Behobene Bugs**
- Keine neuen Bugs in dieser Version

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: open/write/read/close funktionieren
- ✅ Unit-Tests: 157+ Tests bestanden

---

## Version 0.1.4 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Vollständiges Module System**
- **Import/Export Syntax**: `import std.math;`, `pub fn` Deklarationen
- **Cross-Unit Symbol Resolution**: Importierte Funktionen werden automatisch gefunden
- **Standard Library Support**: `std/math.lyx` mit mathematischen Funktionen
- **Dynamic ELF Generation**: Unterstützung für externe Symbole und Libraries

#### **Robuste Parser-Architektur**
- **Flexible While-Syntax**: `while condition` UND `while (condition)` funktionieren beide
- **Einheitliche If-Syntax**: `if (condition)` - Klammern sind erforderlich für Eindeutigkeit
- **Unary-Expressions**: `return -x` und `var y := -x` funktionieren korrekt
- **Function-In-Function**: If-Statements in Funktionen vollständig unterstützt

### 🔧 **Behobene kritische Bugs**
- **Parser-Rekursion**: Unary-Operator Parsing führte zu unendlicher Rekursion
- **Context-Confusion**: If-Statements wurden fälschlicherweise als Struct-Literale interpretiert
- **Import-Parsing**: Units mit komplexen Control-Flow-Konstrukten parsen korrekt

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/control/for_loop.lyx`: While-Schleifen (Output: 15, 15)
- ✅ `tests/lyx/stdlib/use_math.lyx`: Module Import mit dynamischem ELF
- ✅ `std/math.lyx`: Standard Library kompiliert erfolgreich
- ✅ Complex Functions: `Abs64()`, `Min64()`, `Max64()` Implementierungen
- ✅ Cross-File Compilation: Multi-Unit Projekte funktionieren

### 🎯 **Standard Library (std/)**
```lyx
import std.math;

fn main(): int64 {
    let x: int64 := Abs64(-42);      // 42
    let smaller: int64 := Min64(x, 100);  // 42
    PrintInt(times_two(smaller));   // 84
    return 0;
}
```

### ⚠️ **Bekannte Einschränkungen**
- **Cross-Unit Function Calls**: Werden erkannt und gelinkt, aber nicht ausgeführt (Backend-Bug)
- **Verschachtelte Unary-Ops**: `--x` temporär deaktiviert für Parser-Stabilität
- **If-Syntax**: Klammern sind jetzt erforderlich (Breaking Change von flexibler Syntax)

### 📈 **Performance & Stabilität**
- **Compiler-Geschwindigkeit**: ~1.0-1.2s für komplexe Multi-Unit Projekte
- **Memory Management**: Robuste AST/IR Speicherverwaltung ohne Leaks
- **Error Handling**: Präzise Fehlermeldungen mit Zeilen/Spalten-Angaben

### 🔄 **Migration Guide**
```diff
// Alte Syntax (funktioniert nicht mehr)
- if x < 0 { return -x; }
- while i < 10 { i := i + 1; }

// Neue Syntax (erforderlich)
+ if (x < 0) { return -x; }
+ while i < 10 { i := i + 1; }  // oder while (i < 10)
```

---

**Status**: Der Lyx-Compiler ist von *"grundlegend defekt"* zu *"weitgehend produktiv"* geworden und unterstützt nun professionelle Multi-Module Projekte.