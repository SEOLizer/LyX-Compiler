# std.mqtt — MQTT-Client für Lyx

Stand: M1 (netzfreier Codec). Protokollkern vollständig in Lyx, kein Wrapper
um eine C-Bibliothek. Dieses Verzeichnis enthält **nur** den netzfreien Teil:
Drahtformat, Validierung, Properties, Pakete beider Fassungen. Verbindung,
QoS-Zustandsautomat, Sitzungen und Transport folgen in M2/M3.

Der Altbestand `std/net/mqtt.lyx` bleibt unverändert (blockierend, nur 3.1.1,
ohne QoS-2-Pfad). Er wird nicht von hier benutzt und soll nach M2 abgelöst
werden.

## Einheiten

| Unit | Inhalt |
| --- | --- |
| `std.mqtt.topic` | MQTT-UTF-8, Topic Names, Topic Filter, Shared Subscriptions |
| `std.mqtt.wire` | Variable Byte Integer, Festbreiten, Strings, Fixed Header, inkrementelles Framing |
| `std.mqtt.props` | MQTT-5-Properties: Typ, zulässige Pakete, Wiederholbarkeit, Wertebereiche |
| `std.mqtt.packet` | Kodieren und Dekodieren aller Pakettypen, 3.1.1 und 5.0 |

## Verträge

**Kein Netzwerk, keine Uhr, kein Thread.** Jede Funktion arbeitet auf
`(Adresse, Länge)`. Der Aufrufer stellt alle Puffer; das Framing allokiert
nichts und kopiert den Rumpf genau einmal in den übergebenen Puffer.

**Keine Kopie der Nutzdaten.** Dekodierte Strings und Payloads sind
`(Offset, Länge)` in den Rumpfpuffer. Die Sicht gilt bis zum nächsten
`MqRahmenFuettere`; wer sie länger braucht, kopiert selbst (R-05).

**Grenze vor der Übernahme.** Die Paketgrenze greift, sobald die Remaining
Length dekodiert ist — also bevor ein Rumpfbyte übernommen wird. Ein zu
kleiner Rumpfpuffer meldet `MQ_E_RUMPF_KLEIN` statt zu wachsen oder zu kürzen
(R-03).

**Fehler sind Sentinel-Ganzzahlen** außerhalb jedes gültigen Ergebnisses
(`MQ_OK` = 0, Fehler ≤ −201). `ref` trägt in Lyx nur bei Struct-Parametern
(sema error, 1.2.31H), darum nehmen Funktionen mit mehreren Ergebnissen eine
Ausgabeadresse (`aus`); `0` heißt „Ergebnis nicht gewünscht".

**Kein stiller Default.** Unbekannter Property-Identifier, reservierter
Pakettyp, unzulässige Fixed-Header-Flags, Retain Handling 3, No Local auf
Shared Subscription, MQTT-5-Form unter 3.1.1: jedes davon wird mit eigenem
Fehlercode abgewiesen. Eine unbekannte Property wird **nicht** übersprungen —
ihre Länge ist nicht bestimmbar.

## Fassungen

Die Fassung ist kein Paketinhalt, sondern Zustand der Verbindung: sie kommt aus
dem CONNECT und wird dem Codec als `version` übergeben. Ein PUBLISH ist nicht
selbstbeschreibend — als 3.1.1 gelesen wandert ein MQTT-5-Property-Block in die
Payload. Der Test belegt genau das am Wert.

## Beispiel

Kein Beispiel täuscht hier eine fertige Client-API vor. Lauffähig geprüfte
Verwendung steht in `tests/regression/mqtt/*.lyx`; `test_mqtt_packet.lyx`
zeigt den vollen Weg Kodieren → Framing → Dekodieren für beide Fassungen.

## Anforderungs- und Normmatrix (M1)

Bezug: Pflichtenheft v0.1 vom 2026-11-05; OASIS MQTT 3.1.1 (2014-10-29) und
MQTT 5.0 (2019-03-07).

| Anforderung | Umsetzung | Nachweis |
| --- | --- | --- |
| A-01 kein OS-Aufruf, keine Uhr, kein Thread im Codec | alle vier Units | keine Importe außer `std.mqtt.*` |
| A-02 Teilweises Lesen ist regulärer Zustand | `MqRahmenFuettere` → `MQ_RAHMEN_TEIL` | `test_mqtt_wire` (b), (c) |
| R-01 Fragmentierung, Längen, Flags, Properties, UTF-8 vor Zustandsänderung | `wire`, `props`, `packet` | `test_mqtt_wire`, `test_mqtt_props` |
| R-01 Überlauf/Vorzeichen bei Längenfeldern | alle Lesevorgänge byteweise maskiert | `test_mqtt_wire` „u16 wert" (0xFFFF ≠ −1) |
| R-02 ungültiges Paket → spezifikationsgerechter Fehler | eigene Codes je Grund | alle vier Tests, negative Seite |
| R-03 Grenze vor unbegrenztem Einlesen | Prüfung bei dekodierter Remaining Length | `test_mqtt_wire` (e), (f) |
| R-05 Besitz und Lebensdauer der Payload | Sichten statt Kopien, dokumentiert | `test_mqtt_packet` |
| F-01 leere Payload gültig, Daten unverändert | `MqPublishSchreib`/`MqPaketLies` | `test_mqtt_packet` „publish leer" |
| F-02 mehrere Filter je Operation, Ergebnis je Filter | `MqSubscribeSchreib`, `MqAckReason` | `test_mqtt_packet` SUBSCRIBE/SUBACK |
| F-03 Topic Names, Filter, MQTT-UTF-8, `$`-Topics, Shared | `std.mqtt.topic` | `test_mqtt_topic` (20 Fälle) |
| F-04 empfangene Nachricht mit QoS/Retain/DUP/Properties | Ergebnisblock `MQ_R_*` | `test_mqtt_packet` |
| F-05 No Local, RAP, Retain Handling, Subscription Identifier; unzulässige Kombination abgewiesen | `MqSubOptPruefe` | `test_mqtt_packet` „nolocal shared", „rh3" |
| M5-01 alle Pakettypen inkl. AUTH, typisierter Property-Vertrag, Reihenfolge wiederholter User Properties, unbekannte Property nicht übersprungen | `props`, `packet` | `test_mqtt_props` (a)–(h) |
| M5-02 Session/Message Expiry, Will Delay, Content Type, Response Topic, Correlation Data, User Properties, Subscription Identifier | Tabelle in `MqPropTyp`/`MqPropErlaubt` | `test_mqtt_props` |
| M5-06 Server Reference wird ausgegeben | DISCONNECT/CONNACK-Properties | `test_mqtt_packet` „serverref" |
| API-03 MQTT-5-Option unter 3.1.1 → eigener Fehler | `MQ_E_SUBOPT_V5` | `test_mqtt_packet` (6 Fälle) |
| T01 identisches Ergebnis bei jeder Fragmentierung | — | 299 Schnittpunkte in `test_mqtt_wire`, je Pakettyp in `test_mqtt_packet` |
| T02 fehlerhafte Längen, Flags, IDs, UTF-8, Properties | — | alle Tests, negative Seite |

Nicht in M1 enthalten, als eigener Umfang geführt:
Verbindungs- und QoS-Zustandsautomat (Q-01…Q-06), Sitzungen (S-01…S-06),
Transport und TLS-Adapter (V-01…V-08), ausgehandelte Grenzen und Topic Alias
zur Laufzeit (M5-03, M5-04), AUTH-Provider (M5-05), Client-API und
Fehlerkategorien (API-01, API-02), Dauerlauf und Fuzzing (T10, Fuzzing-Lauf).

## Gegenprobe

Beide Prüfungen wurden durch Mutation belegt (wäre der Test vor dem Fix rot?):

- `MqSubOptPruefe` ohne die No-Local-Prüfung → `test_mqtt_packet` rot
  („subscribe5 nolocal shared ist=23 soll=−289").
- Paketgrenze im Framing deaktiviert → `test_mqtt_wire` rot
  („grenze vor rumpf ist=1 soll=−224").
