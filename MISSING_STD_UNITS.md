# Standard-Library: Bestand und Lücken

Stand: 2026-11-25 · Bestand gemessen, nicht gepflegt.

Der Bestandsteil wird erzeugt, nicht von Hand geschrieben — die vorige Fassung
(24.10.2026) nannte 77 Units, real waren es zu diesem Zeitpunkt längst mehrere
hundert. Vor jeder Änderung an diesem Dokument neu messen:

```sh
find std -name '*.lyx' | wc -l
for d in $(find std -mindepth 1 -type d | sort); do \
  echo "$d: $(ls $d/*.lyx 2>/dev/null | wc -l)"; done
```

Ein Name in der Liste belegt nur, dass die Datei existiert — nicht, dass die
Unit das tut, was der Name vermuten lässt. `std/cpu/cache.lyx` ist der
CPU-Cache, kein Caching-Interface; `std/cloud/gcp/jwt.lyx` ist
GCP-spezifisch, keine allgemeine JWT-Unit.

---

## Bestand: 502 Units in 39 Verzeichnissen

| Verzeichnis | Anzahl | Units |
|---|---:|---|
| `std/` | 131 | alloc, audio, autodiff, base64, bignum, bits, blockchain, bpf, brotli, buffer, circle, color, complex, conv, convolve, country, crt, crt_raw, csv, datetime, debug, decomp, dist, env, error, fasttext, feq, fft, fma, fs, fs_ext, geo, graph, grapheme, grid, gzip, hash, html, i128, inflate, ini, inotify, io, io_uring, ipc_sysv, iso, json, lfd_factory, lfd_parser, linalg, list, log, math, math_batch, mathx, matrix, meta_safe, ml, ml_full, mmap_ext, modmath, money, mqueue, nn, nn_data, nn_io, nn_store, nn_store_pg, ns, numeric, os, pack, pdf, pipe, prime, prob, process, process_ext, qbool, qt5_app, qt5_core, qt5_egl, qt5_gl, qt5_glx, quat, rar, rat, rect, regex, res, result, sat, sched, security_ext, security_ext_x86, signals, sort, sparse, stats, stats_batch, string, strtype, sum, svg, sysadmin, system, systeminfo, tar, tensor, text, theorem123, thread, time, unicode, unicode_case, unicode_casedata, unicode_data, unicode_gbdata, units, url, uuid, vector, vector_batch, wavelet, x11, xattr, xml, yaml, zip, zlib, zstd |
| `std/aero/` | 5 | atmos, fplan, holding, perf, vnav |
| `std/android/` | 16 | apk_builder, app_glue, asset, gles2, input, ioctl, jni, log, looper, manifest_gen, native_activity, native_window, random, restrictions, sensor, zip_writer |
| `std/astro/` | 9 | attitude, cr3bp, entry, groundtrack, guidance, insertion, launch, orbit, state |
| `std/audio/` | 3 | alsa, mpg123, playback |
| `std/blockchain/` | 1 | p2p |
| `std/cloud/` | 9 | cloudwatch, dynamodb, ec2, iam, lambda, s3, secrets, sns, sqs |
| `std/cloud/aws/` | 4 | core, sigv4, transport, xml |
| `std/cloud/cf/` | 16 | analytics, cache, core, credentials, d1, dns, email, kv, lb, pages, r2, transport, tunnel, waf, workers, zones |
| `std/cloud/digitalocean/` | 13 | apps, core, credentials, databases, droplets, functions, kubernetes, monitoring, networking, registry, spaces, transport, volumes |
| `std/cloud/gcp/` | 11 | compute, credentials, firestore, functions, jwt, logging, oauth, pubsub, secrets, storage, transport |
| `std/coordinates/` | 2 | transform, vec3 |
| `std/cpu/` | 9 | cache, clock, features, identity, limits, power, status, sysfs, topology |
| `std/crypto/` | 28 | aes, aesccm, aescmac, aescore, aesgcm, bignum, chacha20poly1305, ct, der, ec, ecc, ed25519, hkdf, hmac, keccak, md4, md5, ntt, ocsp, pkey, rand, rsa, rsa_native, sha1, sha256, sha512, x25519, x509 |
| `std/crypto/pqc/` | 6 | dadq, hybrid, mldsa, mlkem, pqc, slhdsa |
| `std/db/` | 5 | mysql, postgres, redis, redis_simple, sqlite |
| `std/edi/` | 14 | catalog, core, customs, delfor, inventory, invoice, messages, orders, partner, payment, rfq, seafreight, shipping, transport |
| `std/ee/` | 3 | ac, const, dc |
| `std/fs/` | 6 | exfat, ext4, fat, ntfs, part, squashfs |
| `std/geo/` | 1 | sphere |
| `std/geodesy/` | 2 | ellipsoid, frames |
| `std/graphdb/` | 7 | core, edge, file, index, mem, node, query |
| `std/hardware/` | 42 | bluetooth, bluetooth_ai, bluetooth_dbus, bluetooth_ext, bluetooth_gattc, bluetooth_gatts, bluetooth_l2cap, bluetooth_rfcomm, bluetooth_types, gpio_barriers, gpio_ext, gpio_ioctl, gpio_mmio, gpio_pin, gpio_syscalls, gpio_util, pci, pci_bar, pci_caps, pci_config, pci_ecam, pci_enum, pci_ids, pci_irq, pci_portio, pci_syscalls, pci_types, pci_vfio, rpi4, usb_bulk, usb_control, usb_discovery, usb_endpoint_bind, usb_endpoint_types, usb_ifc_mgr, usb_interrupt, usb_iso, usb_parse, usb_syscalls, usb_types, usb_urb_pool, usb_util |
| `std/hl7/` | 5 | adt, core, orders, results, scheduling |
| `std/image/` | 10 | avif, bmp, core, gif, image, jpeg, png, png_mem, tiff, webp |
| `std/lyxvision/` | 20 | app, button, cluster, consts, dialog, drivers, frame, group, inputline, listview, main, menu, staticline, statictext, tapplication, terminal, textdevice, types, view, window |
| `std/math/` | 1 | constants |
| `std/mqtt/` | 4 | packet, props, topic, wire |
| `std/net/` | 36 | arp, asn1, bgp, dhcp, dns, dtls13, epoll, eth, http, https, imap, ipv4, ldap, mongo, mqtt, ntp, quic, rest, sip, smtp, snmp, socket, socket_win, ssh, syscalls, telnet, tls, tls12, tls13, tls_config, tls_kern, tls_openssl, types, udp, wait, whois |
| `std/net/arp/` | 1 | frame |
| `std/net/dhcp/` | 1 | frame |
| `std/net/internal/` | 3 | syscalls_android, syscalls_linux, types |
| `std/office/` | 4 | odf_doc, odf_xml, ods, odt |
| `std/pdf/` | 25 | annot, attach, builder, compress, fonts, forms, graphics, image, imagefile, layer, meta, namedest, objects, outline, page, pagelabels, pdfa, reader, shading, spot, transition, ttfont, viewprefs, xmp, xobject |
| `std/pgp/` | 4 | armor, core, key, packet |
| `std/semarti/` | 6 | ablauf, adapter, objekte, registry, schema, wert |
| `std/svg/` | 11 | anim, builder, defs, elements, filter, image, parser, path, style, text, xml |
| `std/validate/` | 25 | bic, cas, ch_ahv, de_numbers, de_personal, ean, ewc, iata, iban, isbn, isin, ismn, iso6346, isrc, issn, lei, luhn, mmsi, nl_bsn, orcid, uic, us_cusip, us_ssn, vat, vin |
| `std/video/` | 3 | avi, core, mp4 |

---

## Lücken

Jeder Eintrag einzeln per `find std -name '<name>.lyx'` geprüft; kein Treffer
oder nur ein Treffer, der etwas anderes ist.

### Text und Serialisierung

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `fmt` | formatierte Ausgabe mit Platzhaltern | `io`, `conv`, `string` — Formatierung von Hand |
| `bytes` | Operationen auf Byte-Scheiben | `buffer` (Puffer mit Besitz, keine Scheiben-Sicht) |
| `toml` | TOML lesen und schreiben | `ini`, `yaml`, `json` |
| `markdown` | Markdown parsen | `html` (nur Ausgabe/Escaping) |

### Krypto und Authentisierung

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `jwt` | JSON Web Tokens, allgemein | `std/cloud/gcp/jwt` — nur für GCP-Dienstkonten |
| `oauth` | OAuth-2-Fluss, allgemein | `std/cloud/gcp/oauth` — nur für GCP |

Die Primitive sind vollständig da: `crypto/{sha1,sha256,sha512,keccak,md5,md4,
hmac,hkdf,rand,ec,ecc,ed25519,x25519,rsa,der,x509,ocsp,ct}`,
`crypto/{aes,aescore,aesgcm,aescmac,aesccm,chacha20poly1305}` und
`crypto/pqc/*`. `hmac` nimmt seit #2638 eine Hash-Kennung, deckt also MD4 bis
SHA-512 mit einer Unit ab. Ein generisches `jwt`/`oauth` wäre vermutlich ein
Herausziehen aus `cloud/gcp`, kein Neuentwurf.

### Netz

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `net/websocket` | WebSocket, Client und Server | `net/http`, `net/socket` |
| `net/grpc` | gRPC | `net/http` (kein HTTP/2-Rahmenwerk) |
| `net/ftp` | FTP-Client | `net/socket` |
| `net/sftp` | SFTP-Client | `net/ssh` |
| `net/smb` | SMB-Client | — · Bausteine für SMB 3.1.1 und NTLMv2 seit #2638 da: `crypto/{md4,hmac,aescmac,aesccm}` samt SP-800-108-Ableitung |
| `net/radius` | RADIUS-Client | `net/udp`, `net/ldap` |

### Hilfsmittel

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `base32` | Base32-Kodierung | `base64` (kein Base32 darin) |
| `mime` | MIME-Typen, Zuordnung zu Endungen | Teilstücke in `base64`, `net/http` |
| `cron` | Cron-Ausdrücke auswerten | `datetime`, `sched` |
| `hex` | Hex als eigene Unit | verstreut in `buffer`, `conv`, `bignum`, `color`, `hash` — mehrere Fassungen derselben Rechnung |
| `uri` | URI zerlegen, allgemeiner als URL | in `url` enthalten |
| `fnv` | FNV-Streuwert | `hash` (xxhash und andere, kein FNV) |

### Medien

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `wav` | WAV lesen und schreiben | `audio`, `audio/{alsa,playback}` — Wiedergabe, kein Dateiformat |
| `mp3` | MP3 dekodieren | `audio/mpg123` — FFI auf libmpg123, kein eigener Dekodierer |

### System

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `tty` | Terminal-Einstellungen (termios) | `lyxvision/terminal` (an die Oberfläche gebunden) |
| `pty` | Pseudoterminals | — |
| `user` | Benutzer und Gruppen (passwd, group) | `system`, `sysadmin`, `env` |
| `exec` | Kommandos ausführen, als eigene Unit | `process`, `process_ext` |

### Prüfen

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `testing` | Testrahmen in Lyx | nichts — Tests laufen über `tests/*.sh` und `tests/suite-*.txt` |
| `assert` | Zusicherungen mit Meldung | Sprach-`assert` ohne Testanbindung |
| `mock` | Attrappen | — |

Das ist eine Entwurfsfrage, keine Lücke im üblichen Sinn: der Bestand prüft von
außen (Erzeugnis, Wirkung, Ausgabe), nicht von innen. Wer `testing` anlegt, muss
sagen, wie es sich zu `run_lyx_suite.sh` und `test_coverage_test.sh` verhält.

### Verschiedenes

| Fehlt | Beschreibung | Nächstes im Bestand |
|---|---|---|
| `context` | Abbruch und Fristen weitergeben | `thread` (Futex, Cond), `sched` |
| `iter` | Iteratormuster | `list`, `vector` — jeweils eigene Durchlaufform |
| `cache` | Caching-Interface (LRU, TTL) | `std/cpu/cache` ist der CPU-Cache, `std/cloud/cf/cache` ist Cloudflare |

---

## Einträge der Vorfassung, die erledigt sind

Zur Nachvollziehbarkeit — diese standen als FEHLT und sind da, teils unter
anderem Namen:

| Vorfassung | Real |
|---|---|
| `sqlite`, `redis`, `mongo` | `db/sqlite`, `db/redis`, `db/redis_simple`, `db/mysql`, `db/postgres`, `net/mongo` |
| `crypto/sha` | `crypto/sha1`, `sha256`, `sha512`, `keccak`, `md5` |
| `crypto/hmac`, `crypto/rand` | `crypto/hmac`, `crypto/rand` |
| `crypto/ecb` (gemeint: Elliptic Curve) | `crypto/ec`, `ecc`, `ed25519`, `x25519` |
| `crypto/cmac`, `crypto/ccm` (nicht aufgeführt, aber offen) | `crypto/aescmac` (RFC 4493 + SP 800-108), `crypto/aesccm` (RFC 3610) — beide seit #2638 |
| `ini`, `text` | `std/ini`, `std/text` |
| `image`, `bmp`, `png`, `jpeg` | `image/*` (zusätzlich gif, tiff, webp, avif) |
| `audio` | `std/audio` + `audio/{alsa,mpg123,playback}` |
| `signal` | `std/signals` |
| `sync` | `std/thread` — MutexNew/Free/Lock/Unlock/TryLock, Cond*, AtomicLoad/Store/Add, CAS, TLSKey*, Futex |
| `tz` | in `std/datetime` |
| `xxhash` | in `std/hash` |
| `csv`, `xml`, `yaml`, `html`, `uuid`, `url`, `datetime`, `net/ntp`, `crypto/aes` | unverändert vorhanden |

Nicht erledigt, aber in der Vorfassung falsch eingeordnet: `errors` und `hex`
standen als TEILWEISE. `error`/`result`/`res` deckt Fehlerbehandlung ab —
`errors` ist gestrichen. `hex` bleibt als Lücke geführt, weil mehrere Fassungen
derselben Rechnung im Bestand liegen.

---

## Zusammenfassung

| Kategorie | Lücken |
|---|---:|
| Text und Serialisierung | 4 |
| Krypto und Authentisierung | 2 |
| Netz | 6 |
| Hilfsmittel | 6 |
| Medien | 2 |
| System | 4 |
| Prüfen | 3 |
| Verschiedenes | 3 |
| **Gesamt** | **30** |
