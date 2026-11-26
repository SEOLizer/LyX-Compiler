# TLS-Client gegen öffentliche Hosts — Standvermerk

Stand: **2026-11-25**, lyxc 1.2.49C (Zweig `fix/2660-syscall438-buendel-s`).
Erhoben mit `tools/tls_hosts_probe.lyx` (#2613 Punkt 3, Rest aus #2096
Kriterium 2).

Dieser Vermerk ist **kein Test**. Ein Test, der an einem fremden Dienst im Netz
hängt, wird rot, wenn dort jemand ein Zertifikat tauscht, und misst dann nichts
über uns. Erneuern:

```sh
./lyxc --std-path=. tools/tls_hosts_probe.lyx -o /tmp/hp
/tmp/hp                       # die vier Hosts unten
/tmp/hp host [host ...]       # eigene
```

## Befund

Eigener Client (`std.net.tls`-Hülle über `std.net.tls13`), **System-CA-Store**
(`/etc/ssl/certs/ca-certificates.crt`), Gültigkeit gegen die **echte Uhr**,
`TlsConfigKettePruefen(cfg, 1)` — ein fertiger Handschlag heißt hier also:
Kette **und** Hostname haben getragen.

| Host | Gegenstelle | Version | Suite | Kette | HTTP-Antwort |
|---|---|---|---|---|---|
| `seolizer.de` | eigene (nginx/OpenSSL) | TLS 1.3 | `0x1301` | ok | `301 Moved Permanently` |
| `www.google.com` | BoringSSL | TLS 1.3 | `0x1301` | ok | `200 OK` |
| `cloudflare.com` | Cloudflare | TLS 1.3 | `0x1301` | ok | `301 Moved Permanently` |
| `letsencrypt.org` | Let's-Encrypt-Kette | TLS 1.3 | `0x1301` | ok | `200 OK` |

**4 von 4: Handschlag fertig und Antwort gelesen.** Die Antwortzeile gehört
dazu — ohne sie wäre nur belegt, dass ein Handschlag zustande kam, nicht dass
die Verbindung danach benutzbar ist.

## Zwei Dinge, die man falsch lesen könnte

**`0x1301` überall ist keine Einschränkung.** Der Client bietet alle drei
TLS-1.3-Suiten an (`tls13.lyx:2026–2028`): `TLS_AES_128_GCM_SHA256`,
`TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`, in dieser Reihenfolge.
Server nehmen die erste Präferenz des Clients, also fällt überall dieselbe
Suite. Gegengemessen: `openssl s_client` handelt mit demselben Host
`TLS_AES_256_GCM_SHA384` aus — die Wahl liegt an der Reihenfolge, nicht am
Können.

**`kette=ok` ist aus dem fertigen Handschlag abgeleitet**, nicht separat
abgefragt: `TLSConnect` schaltet die Kettenprüfung ein und bricht sonst ab
(`std/net/tls.lyx:265ff.`). Wer eine eigene Anzeige dafür will, muss sie in der
Hülle nachrüsten.

## Was damit NICHT belegt ist

* **Firefox/NSS** (#2613 Punkt 1) — braucht `certutil` aus `libnss3-tools`,
  fehlt auf der Maschine.
* **nginx als Gegenstelle** (#2613 Punkt 2) — `nginx` fehlt auf der Maschine.
* **DTLS 1.3** (#2630) — OpenSSL 3.5.5 kann es nicht (`s_client` kennt nur
  `-dtls1`, `-dtls1_2`); es braucht wolfSSL.
* **Wiederaufnahme und 0-RTT** gegen diese Hosts: die Probe fährt je Host eine
  Verbindung und holt kein Ticket ein.
