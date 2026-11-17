# Für das LyxOS-Kernelteam: natives TLS (#2096) auf LyxOS

Gemessen am 2026-11-17 im aurum-Worktree zu #2096 (Basis `develop` 4b12d894, lyxc 1.2.41A).
Quellen für die Kernelseite sind ausschließlich die beiden erzeugten Tabellen daneben
(`syscall-ist.txt`, `syscall-argc.txt`, Stand lyx-os `324ae90` / `512dcdc`, 2026-11-16) —
nichts davon ist aus einem Issue-Text übernommen.

## 0. Was gefragt ist, in einem Satz

`std.net.tls13` und `std.net.tls12` sind fertig und tragen (TLS 1.3 und 1.2, ECDHE, AEAD,
X.509, mTLS). Sie übersetzen für `--target=lyxos`. Was wir **nicht** beantworten können, ohne
die Kernelseite zu fragen, sind **drei Punkte**: die Güte der Entropiequelle, die Signaturen
der Netz-Syscalls, und ob der Speicherbedarf je Verbindung auf dem Gerät tragbar ist.

## 1. Was die Units verlangen — und wie die Lage dazu ist

Die beiden Units deklarieren `@capabilities([memory.mmap, system.rand])`. Mehr brauchen sie
selbst nicht: sie machen **keine** Ein-/Ausgabe, kennen keinen Socket und keine Uhr. Beides
gehört der Anwendung, die sie benutzt. Ein TLS-**Server** auf LyxOS braucht darüber hinaus
`network.tcp.bind`, `io.wait` und `system.time`, und **kein** `fs.*` — der Trust-Store wird
als Puffer übergeben, nicht als Datei gelesen.

| Was | Nummer | Lage in `syscall-argc.txt` | Urteil |
|---|---|---|---|
| Zufall | 258 `sys_getrandom` | erfasst, **2** Argumente | nutzbar, lyxc hat die Weiche (`TARGET_OS == OS_LYXOS`, #2513) |
| Lesen/Schreiben | 0 `sys_read`, 1/95 `sys_write` | erfasst, 3 | nutzbar |
| Schließen | 3 `sys_close` | erfasst, 1 | nutzbar |
| Uhrzeit | 138 `sys_rtc_datetime` | erfasst, 0 | nutzbar (Zertifikatsgültigkeit) |
| **Netz** | **1536–1545** (0x600–0x609) | **belegt, aber OHNE lesbare Signatur** | **blockiert, siehe 3** |
| **Speicher** | mmap/munmap | **in keiner der beiden Tabellen** | **offen, siehe 4** |

## 2. Frage A — Güte der Entropiequelle hinter `sys_getrandom` (258)

Das ist die Frage, an der die Sicherheit hängt, und sie ist von außen nicht beantwortbar.
TLS leitet daraus ab: den privaten ECDH-Anteil je Verbindung (32 Byte), die 32 Byte
`server_random`/`client_random`, und bei TLS 1.2 zusätzlich das Premaster-Material. Ein
vorhersagbarer ECDH-Anteil bricht die Verbindung **vollständig** und rückwirkend, ohne dass
am Protokoll etwas auffällt — es gibt keinen Test, der das von außen sieht.

Bitte benennt:

1. **Woraus wird gespeist?** Hardware (RDRAND/RDSEED), Zeitmessungen, Gerätejitter, oder ein
   festes Startwertfeld im Abbild?
2. **Was tut 258 VOR der Speisung?** Die einzige sichere Antwort ist *blockieren* oder
   *Fehler*. Gibt es stattdessen einen Rückfall auf etwas Plausibles, ist das aus unserer
   Sicht der Fall „stiller Default" — dann müssen wir in `std.crypto.rand` davor
   zurückweisen, und wir brauchen das erkennbare Merkmal dafür.
3. **Welcher Aufbau danach?** CSPRNG mit Fortpflanzung (ChaCha20, HMAC-DRBG) oder direkte
   Weitergabe?
4. **Was ist der Rückgabewert?** Linux liefert die Zahl gelieferter Byte; mit zwei Argumenten
   fehlt das Flag-Feld. Liefert 258 immer `len` oder darf es kürzen? Unsere Schleife in
   `RandBytesExact` wiederholt, bis `len` beisammen ist, und bricht bei negativem Wert ab —
   das setzt voraus, dass ein Fehler **negativ** zurückkommt und nicht 0.
5. **Nach einem Fork/Klon eines Prozesses**: getrennte Zustände, oder geteilt?

## 3. Frage B — die Signaturen der Netz-Syscalls 1536–1545

`syscall-ist.txt` führt den Lauf `1536 1545 A`, die Nummern sind also belegt.
`syscall-argc.txt` führt **keine** davon — nach dem Kopf dieser Datei heißt das: in
`doku/syscalls_ist.md` steht für sie keine lesbare Signatur. Für lyxc ist das kein
Schönheitsfehler, sondern ein Riegel: die Gestaltprüfung lässt nicht erfasste Nummern durch
(#2482), wir würden also eine Bindung schreiben, die **still** das Falsche übergibt.

`syscalls.md` (die Entwurfsseite) beschreibt die Kategorie 0x0600 bereits ausführlich —
`sys_socket(domain, type, proto)`, `sys_bind(fd, addr, addr_len)` und so weiter. Nach der
Erfahrung aus #2507 („Hex 0x02xx war Design-Schema, NICHT Kernel") nehmen wir diese Seite
ausdrücklich **nicht** als Beleg.

Bitte entweder die Signaturen in `doku/syscalls_ist.md` eintragen, sodass unser
Abgleichskript sie aufnimmt, oder hier bestätigen:

| Nummer | Name | Argumente | Rückgabe |
|---|---|---|---|
| 1536 | `sys_socket` | ? | ? |
| 1537 | `sys_bind` | ? | ? |
| 1538 | `sys_listen` | ? | ? |
| 1539 | `sys_accept` | ? | ? |
| … bis 1545 | ? | ? | ? |

Dazu drei Punkte, die die Tabelle nicht hergibt:

- **Adressform.** Linux-`sockaddr_in` (Familie 16 bit, Port in Netzreihenfolge) oder eigene?
- **Blockierend oder nicht?** Gibt es ein Gegenstück zu `accept4`/`O_NONBLOCK`, und wie
  wartet man auf mehrere fds (`sys_event_recv_timeout`, 218)?
- **Teillesung.** TLS-Records kommen zerstückelt an; wir brauchen die Zusage, dass `sys_read`
  auf einem Socket eine Teilmenge liefern darf und das kein Fehler ist.

## 4. Frage C — Speicher je Verbindung

Ein Verbindungsblock ist nach den Korrekturen aus dieser Runde **134 040 Byte** (vorher
118 680; die Puffer mussten wachsen, weil ein Record nach RFC 8446 §5.2 bis 2^14 Byte
Klartext tragen darf und wir zulässige Höchstlängen abgewiesen haben). Darin stecken
Empfangs-, Sende-, Anwendungs- und Handschlagpuffer zu je 24 KiB sowie der Platz für
Zertifikatskette und RSA-Schlüssel.

- Ist eine Anforderung dieser Größe über `mmap` auf dem Gerät vertretbar, und ab welcher
  Zahl paralleler Verbindungen wird sie es nicht mehr?
- **In beiden Tabellen steht kein `mmap`.** Wie kommt ein Ring-3-Programm auf LyxOS heute an
  Speicher? Die Notiz zum Sentinel („negative mmap-Größe ist ein interner Befehl") lässt
  vermuten, dass es einen Weg gibt, der nicht als eigene Nummer erscheint — bitte benennt
  ihn, mit Obergrenze je Prozess.
- Gibt es eine Zusage, dass freigegebener Speicher **genullt** wird, oder müssen wir
  Schlüsselmaterial selbst überschreiben? (Wir tun es ohnehin; die Antwort entscheidet, ob
  wir uns auf mehr verlassen dürfen — Antwort „nein" ist völlig in Ordnung.)

## 5. Was wir selbst nicht messen können, und warum

Der lokale LBF-Lader (`src.tools.lbf.loader`) führt lyxos-Abbilder unter Linux aus, taugt
hier aber nicht: LyxOS liefert Syscall-Ergebnisse in `rdx`, Linux in `rax`. Alles, was
Speicher anfordert — und das tun die TLS-Units bei jeder Verbindung — bekommt darüber eine
Mülladresse und faultet, obwohl es auf dem Gerät laufen würde. Beim Vorbereiten von #1834
fiel die Sonde in beiden Formen aus; wir haben sie hier gar nicht erst eingesetzt.

Was wir **statt** einer Ausführung gemessen haben, und was damit belegt ist:

- Beide Units übersetzen für `--target=lyxos` bis zum LBF-Erzeugnis.
- Der gemeinsame IR-Weg ist über **arm64 und riscv unter qemu** geprüft: dreimal war ein
  gemeldeter „lyxos-Fehler" in Wahrheit dieser gemeinsame Weg (#1786, #1787, #1798). Die
  Kryptographie und die Zustandsmaschinen laufen dort.
- RFC 8448 ist bytegenau nachgerechnet (22 Werte), 1818 Wycheproof-Fälle laufen, und
  tlsfuzzer fährt die Serverrolle: `record-layer-limits` 68/68, `lengths` 1002/1002,
  `finished` 42/42. Eigenes Fuzzing: 3,6 Mio Fälle ohne Absturz.

Was **nicht** belegt ist und erst auf dem Gerät entschieden wird: Entropie (Frage A), Netz
(Frage B), Speicher (Frage C). Genau diese drei und nichts anderes.

## 6. Reihenfolge aus unserer Sicht

1. **Frage A zuerst.** Sie entscheidet, ob TLS auf LyxOS überhaupt sicher sein kann, und sie
   ist unabhängig von allem anderen. Eine Antwort genügt, kein Code.
2. **Frage B danach.** Mit den Signaturen schreiben wir die Bindung in `std.net.tcp` und
   können einen echten Handschlag auf dem Gerät fahren.
3. **Frage C zuletzt.** Sie ist eine Zahl, keine Sperre: notfalls bauen wir ein Profil mit
   kleineren Puffern, das dann aber auch kleinere Records erzwingt (`max_fragment_length`,
   RFC 6066).
