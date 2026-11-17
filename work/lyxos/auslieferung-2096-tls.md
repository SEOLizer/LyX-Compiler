# Auslieferung für das LyxOS-Kernelteam: TLS messen (#2096)

Stand 2026-11-17. Ergänzt `anfrage-2096-tls.md` daneben: dort stehen die drei
Fragen, hier steht, **wie man zwei davon ohne jede Kernelarbeit beantwortet**.

## 0. Die Lage in drei Sätzen

`std.net.tls13` und `std.net.tls12` machen **keine Ein-/Ausgabe**. Sie
bekommen Byte herein (`TlsFuetter`) und geben Byte heraus (`TlsAusgabe`); wer
die über ein Netz schiebt, ist die Anwendung. Deshalb lässt sich ein
**vollständiger Handschlag in einem Prozess** führen — zwei
Zustandsmaschinen, ein Puffer dazwischen, kein Socket.

Das trennt die drei offenen Fragen sauber:

| Frage | Mit diesem Abbild |
|---|---|
| **A — Entropie** (`sys_getrandom`, Nr. 258) | **beantwortbar**, siehe unten |
| **C — Speicher** (mmap, 134 880 Byte je Verbindung) | **beantwortbar** |
| **B — Netz** (Signaturen von 1536–1545 fehlen) | **nicht berührt** — und das ist der Punkt: ihr könnt alles andere messen, bevor die Signaturen vorliegen |

## 1. Was ihr bekommt

### `tools/tls_selbsttest.lyx`

Ein einzelnes Programm, das einen echten TLS-1.3-Handschlag mit sich selbst
führt und danach Nutzdaten in beide Richtungen schickt. Zertifikat und
Schlüssel sind **fest eingebaut** (secp256r1, Testschlüssel, verschlüsselt
nichts Echtes) — auf dem Gerät gibt es kein Dateisystem, aus dem man sie
laden könnte, und ein Selbsttest, der erst eine PKI braucht, wird nicht
gefahren.

Es deklariert **genau zwei Rechte und kein drittes**:

```
@capabilities([memory.mmap, system.rand])
```

Damit ist das Abbild selbst die Aussage: läuft es unter diesen beiden,
braucht TLS auf LyxOS nicht mehr. Kein `fs.*`, kein `network.*`, keine Uhr.

### Bauen

```
# im aurum-Checkout, mit dem eigenen Compiler
make bootstrap
./lyxc tools/tls_selbsttest.lyx --std-path=. --target=lyxos -o tls_selbsttest.lbf
```

Gemessen am 2026-11-17 mit lyxc 1.2.42A: **1 384 448 Byte**, LBF Genesis
(`LYX!`), Einsprung 0x400000, Stapel 131 072 Byte, CRC32C hinterlegt. Mit
`lbfdump` nachprüfbar.

### Vorkompilate

`make deb` baut standardmäßig **nur** den x86_64-Baum (`LYU_BAEUME ?=
x86_64`). Für ein Paket mit LyxOS-Vorkompilaten:

```
make deb LYU_BAEUME="x86_64 lyxos"
```

Dass die vier TLS-Units für LyxOS übersetzen, ist nachgemessen:
`std/net/tls13.lyx`, `std/net/tls12.lyx`, `std/net/tls_config.lyx` und
`std/net/tls.lyx` je mit `--target=lyxos --compile-unit`, rc 0.

## 2. Wie ihr messt

Abbild aufs Gerät, starten, Ausgabe lesen. Jede Zeile ist eine Messung, kein
Fortschrittsbalken. So sieht ein bestandener Lauf aus (hier unter Linux
gegengemessen):

```
=== std.net.tls13 Selbsttest, ohne Netz ===
zufall-1-byte 32
zufall-2-byte 32
zufall-zwei-zuege-gleich 0
zufall-nicht-null 255
speicher-je-verbindung 134880
zertifikat-byte 412
schluessel-byte 121
handschlag 0
suite 4865
gruppe 29
server-liest 4
client-liest 4
handschlag-2 0
zwei-handschlaege-gleiches-geheimnis 0
ALLES BESTANDEN
```

Rückgabewert 0 heißt bestanden, sonst die Zahl der Fehlschläge.

### Was jede Zeile beantwortet

| Zeile | Bedeutung | Soll |
|---|---|---|
| `zufall-1-byte`, `zufall-2-byte` | liefert `sys_getrandom` (Nr. 258, **zwei** Argumente) die angeforderten Byte? | je 32 |
| `zufall-zwei-zuege-gleich` | **zwei Züge dürfen nicht bitgleich sein.** Eine Quelle, die immer dasselbe liefert, besteht jede Längenprüfung und ist trotzdem wertlos | 0 |
| `zufall-nicht-null` | nicht durchgehend null (ODER über alle Byte) | ≠ 0 |
| `speicher-je-verbindung` | Frage C: so viel verlangt `TlsNeu` je Verbindung | 134880 |
| `handschlag` | der vollständige Handschlag, Fehlercode | 0 |
| `suite` | ausgehandelte Suite — 4865 = 0x1301 = `TLS_AES_128_GCM_SHA256` | 4865 |
| `gruppe` | Schlüsseltausch — 29 = 0x001D = x25519 | 29 |
| `server-liest`, `client-liest` | Nutzdaten durch die Record-Schicht, beide Richtungen | je 4 |
| `handschlag-2` | ein **zweiter** Handschlag im selben Prozess | 0 |
| `zwei-handschlaege-gleiches-geheimnis` | **die wichtigste Zeile.** Ein Gerät mit festem Startwert besteht beide Handschläge und benutzt dabei denselben Verkehrsschlüssel. Verglichen wird das Exporter-Geheimnis beider Läufe; es MUSS sich unterscheiden | 0 |

### Wenn es scheitert

Jeder Fehlschlag nennt sich selbst. Die drei erwarteten Fälle:

- **`zufall-1-byte` ist negativ oder kleiner als 32** → Frage A ist damit
  beantwortet: die Quelle liefert nicht. Der Rückgabewert von Nr. 258 steht
  in der Zahl; `RandBytesExact` wiederholt, bis die Länge beisammen ist, und
  bricht bei negativem Wert ab.
- **`zwei-handschlaege-gleiches-geheimnis 1`** → die Quelle wiederholt sich.
  Das ist der Fall, der von außen *nicht* auffällt und TLS vollständig
  bricht: ein vorhersagbarer ECDH-Anteil hebt die Verschlüsselung
  rückwirkend auf, und am Protokoll sieht man nichts.
- **„kein Speicher für …"** → Frage C. Das Programm sagt, an welcher
  Anforderung es scheiterte, statt zu faulten.

## 3. Was dieses Abbild NICHT misst

- **Netz.** Bewusst nicht. Die Nummern 1536–1545 sind laut
  `syscall-ist.txt` belegt, haben aber in `doku/syscalls_ist.md` keine
  lesbare Signatur; eine Bindung darauf würde still das Falsche übergeben
  (die Gestaltprüfung lässt nicht erfasste Nummern durch, #2482). Sobald die
  Signaturen vorliegen, kommt ein zweites Abbild mit echtem Socket.
- **Zertifikatsprüfung gegen eine Uhr.** `TlsConfigKettePruefen` ist hier
  **aus**: sie braucht einen passenden Namen und eine Uhr, und beides ist
  nicht die Frage. Geprüft wird der Handschlag — Zufall, Speicher, Rechnung.
- **Leistung.** Keine Takte, keine Durchsätze. Erst wenn es *läuft*, lohnt
  die Frage, wie schnell.

## 4. Warum nicht der lokale LBF-Lader

`src.tools.lbf.loader` führt LyxOS-Abbilder unter Linux aus, taugt hier aber
nicht: LyxOS liefert Syscall-Ergebnisse in `rdx`, Linux in `rax`. Alles, was
Speicher anfordert — und das tut dieses Programm bei jeder Verbindung —
bekommt darüber eine Mülladresse und faultet, obwohl es auf dem Gerät laufen
würde. Beim Vorbereiten von #1834 fiel die Sonde in beiden Formen aus.

Gegengemessen ist stattdessen der gemeinsame IR-Weg: dieselbe Rechnung läuft
unter **arm64 und riscv in qemu**. Dreimal war ein gemeldeter „LyxOS-Fehler"
in Wahrheit dieser gemeinsame Weg (#1786, #1787, #1798).

## 5. Was wir von euch brauchen

Nur die Ausgabe des Laufs — die Zeilen von oben, unverändert. Daraus lesen
wir A und C ab. Frage B bleibt wie in `anfrage-2096-tls.md` beschrieben: die
Signaturen von 1536–1545, oder ein Eintrag in `doku/syscalls_ist.md`, damit
unser Abgleichskript sie aufnimmt.
