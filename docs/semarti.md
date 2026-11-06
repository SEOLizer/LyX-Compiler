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

## Die vier Units

| Unit | Aufgabe |
|---|---|
| `std.semarti.wert` | strukturierter Wert (Objekt, Liste, Text, Zahl, Bool, Null) in einer Arena mit harten Grenzen |
| `std.semarti.schema` | strikte Prüfung; das Schema ist selbst ein solcher Wert |
| `std.semarti.registry` | Deskriptoren, Aufbauphase, danach unveränderlich |
| `std.semarti.ablauf` | Discovery, Autorisierung, Policy, Bestätigung, Ausführung, Protokoll |

`std.json` bleibt unberührt. Es ist durchgehend textbasiert (`pchar` hinein,
`pchar` heraus) und hat keinen Werttyp, keine Navigation und keine Grenzen —
hier liegt deshalb keine zweite Fassung derselben Rechnung, sondern die
Schicht, die dort fehlt. Was sich nachnutzen lässt, wird nachgenutzt: das
Maskieren von Text läuft über `JSONEscape` aus `std.json`.

## Der Ablauf, und warum die Reihenfolge der Kern ist

```
1. Operations-ID auflösen   → unbekannt?        operation_not_found
2. Version prüfen           → passt nicht?      unsupported_version
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

## Nicht enthalten

* Keine Modell- oder Netzanbindung. Der Kern läuft ohne beides.
* Keine automatische Deskriptor-Erzeugung. Registriert wird von Hand; es gibt
  keinen Scan, der Funktionen nach Namensähnlichkeit freigibt.
* Kein Serialisierer für ein Tool-Calling-Format. Der Wert kann gelesen und
  gebaut werden; ein Adapter nach außen gehört in die Anwendung.
* Kein Abbruch und keine Zeitgrenze im Aufruf. Die Codes `cancelled` und
  `deadline_exceeded` sind vergeben, aber noch von keinem Pfad erreichbar —
  und das steht hier, statt als erfüllt zu gelten.
* Keine Nebenläufigkeit zugesagt. Registry und Arena sind Modulzustand ohne
  Sperre; ein Host mit Fäden muss die Aufrufe selbst ordnen.
* Kein attributgetriebener Deskriptor. Der nächste Schritt wäre ein Attribut
  wie `@operation(...)`, aus dem der Übersetzer eine Tabelle im Erzeugnis
  erzeugt — dafür gibt es mit `.meta_safe` schon ein erprobtes Muster.
