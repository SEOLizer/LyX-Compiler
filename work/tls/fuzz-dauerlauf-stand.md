# Dauerlauf-Nachweis fuer #2096 Kriterium 6 (#2614)

Kriterium 6 lautet: „Fuzzing von Record-Layer, Handshake-Parser und
X.509-Parser (mind. 24 h ohne Absturz)".

Erhoben wird er mit `tools/fuzz_tls_dauerlauf.sh`, abgekoppelt und nicht im
`test`-Ziel. Der Grund steht im Kopf des Werkzeugs: der Lauf haelt die
Maschine 24 h unter Last, und daneben misst nichts anderes verlaesslich —
`tests/tls13_tlsfuzzer_test.sh` fiel dabei auf 41 von 42 Gespraechen, und die
Konstantzeitmessung aus K7 muesste ihr Messfenster nachziehen.

## So wird er gefahren

```sh
setsid nohup tools/fuzz_tls_dauerlauf.sh 24 > /dev/null 2>&1 &
# Protokoll: work/tls/fuzz-dauerlauf.log
```

Das Skript liegt als DATEI vor und wird von dort gestartet. Das ist kein
Geschmack: `setsid nohup bash -c '<mehrzeiliger Text>'` bekam die
Zeilenumbrueche nicht durch, `ende` wurde nie gesetzt, und der Lauf lief ohne
Zeitlimit weiter, bis er von Hand abgebrochen wurde.

## Werkzeug nachgemessen (2026-11-27, lyxc 1.2.51C, i5-8250U)

Vor dem langen Lauf wurde das Werkzeug selbst gefahren — ein Dauerlaufskript,
das niemand einmal ganz durchlaufen liess, prueft man sonst erst am Fund:

| Probe | Ergebnis |
|---|---|
| `DAUER_SEKUNDEN=60 FAELLE_JE_LAUF=20000` | 65 Saaten, **3 900 000 Faelle**, rc=0 durchgehend, `fertig-ohne-handschlag=0`, `ueberlebt=1` je Lauf |
| Abbruch bei `rc != 0` (Stub mit Exit 139) | bricht bei Saat 1 ab, nennt die Saat und das Nachstellrezept, Exitcode 1 |
| Abbruch bei `fertig-ohne-handschlag != 0` **trotz** `rc=0` (Stub) | bricht bei Saat 1 ab, Exitcode 1 |

Die dritte Zeile ist die wichtige: ein Lauf, der zurueckkehrt, aber eine
Verbindung FERTIG gemeldet hat, ohne dass ein Handschlag lief, waere mit einer
Pruefung nur auf `rc` durchgefallen — und das ist genau die Eigenschaft, die
Kriterium 6 meint. Beide Zweige sind deshalb ueber `FUZZ_BIN` pruefbar
gemacht und gemessen.

## Stand des 24-Stunden-Laufs

<!-- Nach dem Lauf hier eintragen: Start, Ende, Saaten, Faelle, rc, und dass
     `fertig-ohne-handschlag` durchgehend 0 war. Solange die Zeilen fehlen,
     ist das Kriterium NICHT belegt -- die Eigenschaft ist gut belegt (165 Mio
     Faelle in #2614, 3,9 Mio in der Probe oben), die Zeitangabe nicht. -->

noch nicht gelaufen.
