# SemaRTI — Semantische Laufzeit-Introspektion

Stand: 1.2.32E · MVP · `std/semarti/`

SemaRTI beschreibt fachliche Fähigkeiten einer Anwendung so, dass ein
KI-Orchestrator sie **finden** kann, ohne sie **auslösen** zu können. Über
Validierung, Identität, Rechte, Richtlinie, Bestätigung, Ausführung und
Protokoll entscheidet allein das Programm.

## Warum das in Lyx anders aussieht als in C++

Das ursprüngliche Konzept grenzt SemaRTI gegen C++-RTTI ab: `dynamic_cast`
und `typeid` beantworten „welcher Typ ist das", nicht „welche Fähigkeit ist
das". In Lyx gibt es diese Abgrenzung nicht, weil es **keine
Laufzeit-Typinformation** gibt. Zwei Folgen:

* Die Forderung „der Kern darf nicht von RTTI abhängen" ist hier nicht
  erfüllt, sondern gegenstandslos. Es gibt nichts, wovon man abhängen könnte.
* Dafür muss **jede** Zuordnung explizit im Deskriptor stehen. Nichts lässt
  sich zur Laufzeit nachsehen. Das ist mehr Schreibarbeit und ein engerer
  Vertrag.

Dazu kommt ein Vorteil, den es in C++ nicht gibt: `@capabilities` ist in
dieser Sprache nicht Dokumentation, sondern wird vom Kernel durchgesetzt.

## Die sechs Units

| Unit | Aufgabe |
|---|---|
| `std.semarti.wert` | strukturierter Wert (Objekt, Liste, Text, Zahl, Bool, Null) in einer Arena mit harten Grenzen |
| `std.semarti.schema` | strikte Prüfung; das Schema ist selbst ein solcher Wert |
| `std.semarti.registry` | Deskriptoren, Aufbauphase, danach unveränderlich |
| `std.semarti.objekte` | dynamisches Objektregister: Handles mit Generation, Hierarchie, Beziehungen, Revisionen, Leihscheine |
| `std.semarti.ablauf` | Discovery, Autorisierung, Policy, Bestätigung, Ausführung, Protokoll |
| `std.semarti.adapter` | die Grenze nach außen: Serialisierung hinaus, geprüftes Lesen herein |

`std.json` bleibt unberührt. Es ist durchgehend textbasiert (`pchar` hinein,
`pchar` heraus) und hat keinen Werttyp, keine Navigation und keine Grenzen —
hier liegt deshalb keine zweite Fassung derselben Rechnung, sondern die
Schicht, die dort fehlt. Was sich nachnutzen lässt, wird nachgenutzt: das
Maskieren von Text läuft über `JSONEscape` aus `std.json`.

## Statische Beschreibung und dynamische Instanz sind getrennt

Die Registry ist nach der Aufbauphase unveränderlich — darauf ruhen alle
Prüfungen. Instanzen sind das Gegenteil: ein Fenster öffnet sich, ein
Dokument wird geschlossen, ein Titel ändert sich. Beides in einen Speicher zu
legen hiesse, die Unveränderlichkeit aufzugeben, von der die Aufrufprüfung
lebt.

| statische Beschreibung | dynamische Instanz |
|---|---|
| Schema `Document` | geöffnetes Dokument, Handle 4711 |
| Operation `document.export` | Aufruf auf Dokument 4711 |
| Eigenschaft `title: string` | aktueller Titel „Angebot" |
| unterstützte Beziehungen | konkrete Zuordnung zum Fenster |

### Drei Lebensdauern, nicht zwei

Die Wert-Arena hat zwei Phasen: vor der Marke die Deskriptoren, danach die
Werte eines Aufrufs. Ein Objektregister passt in keine davon — es ist
langlebig **und** veränderlich. Es bekommt deshalb seinen eigenen Speicher,
und das ist die **dritte** Lebensdauer im System. Ein Bereich, eine Rolle.

### Was ein Objektregister ohne Ausnahme braucht

* **Handles mit Generation.** Ein Index allein zeigt nach dem Freigeben auf
  das nächste Objekt, das den Platz bekommt; ein veraltetes Handle träfe
  stillschweigend ein fremdes Dokument. Jedes Handle trägt die Generation
  seines Platzes, und ein veraltetes wird als **eigener** Befund gemeldet
  (`SRA_OBJECT_STALE`) — nicht als „ungültig", denn der Aufrufer hat ein
  Objekt im Blick, das es nicht mehr gibt, und muss seinen Stand neu holen.
* **Eindeutige Namen im Bereich.** Der Bereich ist das Elternobjekt. Zwei
  Geschwister mit demselben Namen machen jede Auflösung zufällig; derselbe
  Name in einem anderen Bereich bleibt erlaubt.
* **Besitzhierarchie und Beziehungen getrennt.** Ein Dokument *gehört* einem
  Projekt, ist aber auf einem Fenster *angezeigt*. Das erste bestimmt die
  Lebensdauer, das zweite ist eine benannte Kante ohne Besitz. Ein Objekt mit
  Kindern kann nicht freigegeben werden; Kanten auf ein freigegebenes Objekt
  verschwinden mit ihm.
* **Revision.** Jede Eigenschaftsänderung erhöht sie. Wer gelesen und dann
  gehandelt hat, kann prüfen, ob sein Wissen noch gilt — ohne Sperre.
* **Lebensdauer während des Zugriffs.** Für die Dauer des Handlers liegt ein
  Leihschein auf dem Objekt; es kann in dieser Zeit nicht freigegeben werden.
  Der Schein wird in **jedem** Fall zurückgegeben, auch wenn der Handler
  scheitert.

## Capability-Deklaration und Aufrufberechtigung sind zwei Fragen

Die drei Capability-Stufen begrenzen, was die **Anwendung** grundsätzlich
darf. `fs.read` unterscheidet keine Dokumente und keine Benutzer. Wer welche
Operation auf **welchem Objekt** ausführen darf, entscheidet allein der
Authorizer — und er bekommt dafür das Objekt-Handle. Der mitgelieferte Test
weist beides an derselben Operation nach: auf dem eigenen Dokument erlaubt,
auf einem fremden `unauthorized`, ohne dass der Handler läuft.

Die Instanzbindung wird in **beide** Richtungen erzwungen: eine Operation mit
`SRR_OBJEKT_NOETIG` ohne Handle ist `object_required`, eine mit
`SRR_OBJEKT_KEINES` mit Handle ist `object_not_allowed`. Ein Ziel, das
niemand prüft, darf einen Handler nicht erreichen.

## Ein Fehlschlag nach dem Handler ist etwas anderes als einer davor

Wenn der Handler gelaufen ist und erst die Ausgabeprüfung scheitert, ist die
Wirkung eingetreten. Ein blindes Wiederholen würde sie ein zweites Mal
auslösen. `AblaufWirkungEingetreten()` beantwortet das und ist an den
**Aufruf** gebunden, nicht an das Risiko: auch eine Operation, die sich als
`nur_lesen` bezeichnet, kann einen Zähler erhöht oder einen Cache gefüllt
haben, und diese Einordnung ist eine Angabe des Anbieters.

Nach `SRA_OK`, `SRA_HANDLER_FAILED`, `SRA_INVALID_OUTPUT` und
`SRA_AUDIT_FAILED` steht das Flag auf 1; bei jeder Ablehnung vor dem Handler
auf 0. Das Flag wird **vor** dem Aufruf gesetzt — die Rückkehr eines
scheiternden Handlers ist kein Beweis dafür, dass er nichts getan hat.

Ein Protokollfehler nach erfolgreicher Ausführung ist ebenfalls ein eigener
Befund (`SRA_AUDIT_FAILED`): der Vorgang ist gültig und ausgeführt, aber
nicht festgehalten. Die Ausgabe bleibt abrufbar, damit der Host abschliessen
kann, ohne zu wiederholen.

## Der Ablauf, und warum die Reihenfolge der Kern ist

```
1. Operations-ID auflösen   → unbekannt?        operation_not_found
2. Version prüfen           → passt nicht?      unsupported_version
2b. Instanz prüfen          → fehlt/veraltet?   object_required / object_stale
3. Eingabe gegen Schema     → ungültig?         invalid_input
4. Autorisierung            → kein Recht?       unauthorized
5. Policy                   → verweigert?       policy_denied
6. Bestätigung              → fehlt?            confirmation_required
7. HANDLER
8. Ausgabe gegen Schema     → ungültig?         invalid_output
9. Protokoll
```

Es gibt keinen Zweig, der eine Stufe überspringt, und keinen Rückfall, der
eine fehlende Berechtigung in etwas Milderes verwandelt.

**Deny by default, und zwar wirksam:** ohne gesetzten Authorizer lehnt
`std.semarti.ablauf` jeden Aufruf ab und zeigt in der Discovery nichts an.
Eine Voreinstellung „alles erlaubt, bis der Host etwas setzt" hätte jedes
Programm offen gelassen, das die Einrichtung vergisst.

**Der Principal kommt nicht aus der Eingabe.** Er wird vom Host übergeben;
sonst könnte sich ein Vorschlag seine eigene Identität geben. Dasselbe gilt
für die Bestätigung: sie ist eine Zusage des Hosts, kein Eingabefeld.

## Capability-Bindung

Jede Operation nennt die Rechte, die sie braucht. Die Registry nimmt nur
Namen an, die der Host zuvor als **seine eigenen** deklariert hat — also
dieselben, die in seinem `@capabilities`-Attribut stehen. Damit ist die Kette
dreifach gesichert und keine Stufe allein genügt:

| Stufe | prüft | Beispiel |
|---|---|---|
| Übersetzer | Gibt es den Namen überhaupt? | `fs.reed` → `sema error: unbekannte Capability` |
| Registry | Verlangt die Operation nur deklarierte Rechte? | `fs.write` ohne Deklaration → `SRR_E_CAP_NICHT_DEKLARIERT` |
| Kernel | Tut der Code nur das Deklarierte? | Schreiben unter `@capabilities([fs.read])` → SIGSYS, rc 159 |

SemaRTI führt **keine eigene Liste** von Capability-Namen. In diesem Baum
lebt eine Capability schon an vier Stellen; eine fünfte Kopie wäre eine zu
viel. Verglichen wird auf **Gleichheit**, nie auf Präfix — eine
Präfixprüfung in einer Rechtezuordnung trifft auch jeden Namen, den es noch
nicht gibt, und das ist hier dreimal teuer geworden.

## Arena und Marke

Alle Werte liegen in einer Arena mit festem Deckel: die Erschöpfung ist ein
gemeldeter Fehler, keine offene Speicherbelegung. Nach der Aufbauphase setzt
`RegistryAbschliessen()` eine **Marke**; `WertArenaZuruecksetzen()` gibt nur
frei, was danach entstanden ist. Deskriptoren und Schemas überleben also
jeden Aufruf, die Werte eines einzelnen Aufrufs nicht.

Das ist derselbe Mechanismus wie bei der Vektorarena des Übersetzers
(#2206) und die Antwort auf einen Fehler, der in diesem Baum fünfmal
aufgetreten ist: ein wiederverwendeter Bereich mit zwei Rollen, bei dem jeder
zweite Zugriff auf fremde Daten zeigt. **Ein Bereich, eine Rolle** — hier
umgesetzt als eine Arena mit zwei klar getrennten Phasen.

Grenzen (alle in `std/semarti/wert.lyx`, nirgends sonst): 4096 Knoten, Tiefe
16, 8192 Byte je Text, 64 Felder je Objekt, 128 Byte je Feldname, 262144 Byte
Textraum. Es gibt keinen unbegrenzten Fall.

## Was ein Beschreibungstext ist

Daten. Ein Deskriptor kann beschreiben, was eine Operation tut; er kann keine
Richtlinie ändern und keine Berechtigung erteilen. Der mitgelieferte Test
enthält eine Operation mit manipulativem Text und weist nach, dass sie
weiterhin bestätigungspflichtig bleibt.

## Nachweis

`tests/semarti_mvp_test.sh` (10 Prüfungen) fährt drei Nachweise, von denen
keiner die anderen ersetzt:

1. **Ablauf** — `tests/semarti/slice.lyx`, 36 Prüfungen. Entscheidend ist,
   dass die **Wirkung** gemessen wird: der Handler zählt seine Aufrufe, und
   jede Ablehnung muss diesen Zähler unverändert lassen. Ein Test, der nur
   Fehlercodes vergleicht, wäre auch von einer Umsetzung erfüllt, die den
   Handler ausführt und danach einen Fehler zurückgibt.
2. **Durchsetzung** — `tests/semarti/durchsetzung.lyx`. Beide Seiten: der
   erlaubte Fall läuft (rc 0), der verbotene stirbt an SIGSYS (rc 159) und
   hinterlässt keine Datei.
3. **Übersetzerseite** — ein Tippfehler in `@capabilities` wird gemeldet, der
   richtige Name übersetzt.

## Abbruch und Frist

Beide Codes sind jetzt erreichbar, und sie beantworten die Frage, die der
Wirkungsbefund aufgeworfen hat: ein Abbruch **nach** dem Handlerstart ist kein
folgenloses Nein.

* Abgefragt wird **vor** dem Handler (dann ist `cancelled` folgenlos,
  `AblaufWirkungEingetreten()` bleibt 0) und **nach** ihm (dann ist die
  Wirkung eingetreten und das Flag steht auf 1).
* **Während** des Handlers kann die Bibliothek nicht fragen — sie ruft fremden
  Code auf. Ein langlaufender Handler fragt deshalb selbst:
  `AblaufSollAbbrechen()` ist dafür öffentlich.

### Die Uhr kommt vom Host, nicht aus einem Import

Der erste Entwurf holte sie über `import std.time`. Das war ein Fehler mit
sofortiger Folge: beide Bestandstests starben an SIGSYS (rc 159), weil
`clock_gettime` nicht in ihrem `@capabilities([fs.read])` stand. **Ein Import
in einer Bibliothek verschiebt die Rechteanforderung jedes Nutzers** — SemaRTI
hätte ab dann `system.time` verlangt, auch von einem Host, der nie eine Frist
setzt.

Die Uhr ist deshalb ein Haken wie Authorizer und Policy. Ohne gesetzte Uhr
wird eine Frist **abgewiesen** (`SRA_FRIST_OHNE_UHR`) und nicht stillschweigend
ignoriert: der Host würde sonst an eine Grenze glauben, die es nicht gibt.

## Nebenläufigkeit wird gemeldet, nicht zugesagt

Registry, Objektregister und Wert-Arena sind Modulzustand. Zwei gleichzeitige
Aufrufe würden sich die Werte überschreiben — still, und das ist das
Schlimmere.

Diese Bibliothek baut deshalb **keine wartende Sperre** ein. Eine solche wäre
eine Zusage über Blockieren und Fairness, die sie nicht halten kann, und sie
verdeckte den Entwurfsfehler im Host. Statt dessen gibt es eine
Eintrittsmarke: wer eintritt und sie belegt findet, bekommt `SRA_REENTRANT`.

Derselbe Befund trifft **Rekursion** — ein Handler, der wieder aufruft, würde
die Arena unter sich wegziehen. Das ist der Fall, der im Test nachgewiesen
ist, weil er sich ohne Fäden herstellen lässt. Die Marke wird auf jedem
Rückweg freigegeben, auch auf jedem Ablehnungsweg; eine liegengebliebene
Marke wäre schlimmer als das Problem, das sie löst.

## Die Grenze nach außen

Zwei Richtungen, und sie sind nicht gleich vertrauenswürdig:

* **Hinaus** — Deskriptoren werden zur Werkzeugbeschreibung, Werte zu JSON.
  Das ist geprüfte eigene Datenlage; die Aufgabe ist Maskierung. Sie läuft
  über `JSONEscape` aus `std.json` und ist nicht nachgebaut. Die verlangten
  **Capabilities stehen nicht** in der Beschreibung: sie sind eine Innensicht,
  und ein Empfänger könnte daraus ableiten, welche Rechte zu erraten lohnen.
* **Herein** — ein Vorschlag wird zum Wert. Das ist Angreifereingabe, auch
  wenn sie wohlgeformt ist. Jede Grenze greift beim **Lesen**: ein zu tiefes
  Dokument steht nie vollständig im Speicher.

Ausdrücklich abgewiesen statt halb unterstützt: Gleitkommazahlen, `\uXXXX`,
Zahlen jenseits von int64 (geprüft **vor** der Multiplikation), ein zweites
Dokument im selben Text, ein zu kleiner Ausgabepuffer. Jedes davon wäre als
stiller Default ein anderer Wert als der gesendete.

## Was gemessen wurde, statt es anzunehmen

Objekt- und Namenssuche laufen linear über die Plätze. GEMESSEN (i5-8250U,
`taskset`): das Füllen des Registers braucht 5 / 15 / 32 / 101 ms für
500 / 1000 / 2000 / 4000 Objekte, eine Namenssuche an der Grenze 55 µs.

Daraus folgt: **kein Index.** Ein Merker für den nächsten freien Platz bringt
102 → 91 ms (11 %) und bleibt, weil er fünf Zeilen kostet; mehr ist von ihm
nicht zu erwarten, denn der dominante Posten ist die Namensprüfung beim
Registrieren, nicht die Platzsuche. Wer die Grenzen ausreizt, hat die Messung
und kann sie wiederholen.

Eigenschaftstexte werden beim Überschreiben **wiederverwendet**, solange der
neue Wert nicht länger ist — der häufige Fall (ein Titel ändert sich) ohne
Allokator. Ein wachsender Wert belegt weiter neuen Raum; die Zähler
`ObjektTextWiederverwendet()` und `ObjektTextNeuBelegt()` machen das messbar,
ohne den Code zu ändern.

## Nicht enthalten

* Keine Modell- oder Netzanbindung. Der Kern läuft ohne beides.
* Keine automatische Deskriptor-Erzeugung. Registriert wird von Hand; es gibt
  keinen Scan, der Funktionen nach Namensähnlichkeit freigibt.
* Keine Nebenläufigkeit zugesagt. Registry und Arena sind Modulzustand ohne
  Sperre; ein Host mit Fäden muss die Aufrufe selbst ordnen.
* **Kein attributgetriebener Deskriptor** — der einzige offene Punkt aus
  #2419. Er berührt Parser, sema und das Hauptprogramm und ist deshalb ein
  eigener Schritt. Das käme **nach** dem Objektmodell,
  nicht davor: sonst automatisiert man einen Vertrag, dessen Instanzbindung
  noch fehlt. Der Weg wäre ein Attribut wie `@operation(...)`, aus dem der
  Übersetzer eine Tabelle im Erzeugnis erzeugt — dafür gibt es mit
  `.meta_safe` ein erprobtes Muster.
* Keine Suche über den ganzen Graphen (`find` über alle Bereiche), keine
  Sortierung der Kinder und keine Beziehungen mit Eigenschaften. Die
  Kinderliste folgt der Platzreihenfolge und ist stabil, solange nichts
  freigegeben wird.
* Objekt- und Beziehungssuche laufen linear über alle Plätze. Bei 4096
  Objekten ist das tragbar; ein Index wäre der nächste Schritt, wenn ein
  Programm die Grenze wirklich ausnutzt.
