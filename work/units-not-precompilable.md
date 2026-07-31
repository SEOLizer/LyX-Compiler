# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

`make precompile-units` erzeugt für diese 75 Units keine `.lyu`.
Der Sweep `test_compile_units.sh` sieht sie nicht — er prüft nur `std/*.lyx`,
keine Unterverzeichnisse.

Vorher waren es 88; die Keyword-Kollisionen (`match`/`to`/`pool`) sind erledigt.
Beim Beheben einer Schicht treten die darunterliegenden Fehler erst hervor —
`CF_AUTH_TOKEN` etwa war vom `match`-Parse-Fehler verdeckt.

## Verbleibende Ursachen

| Ursache | betroffene Units | Charakter |
|---|---:|---|
| `read_raw` fehlt in `std/lyxvision/drivers.lyx` | 16 | fehlende Implementierung, 15 Folgefehler |
| `CF_AUTH_TOKEN` fehlt in `std/cloud/cf/credentials.lyx` | 14 | fehlendes Symbol, 13 Folgefehler |
| **`do` als Namespace** (`std/cloud/do/`) | 12 | **API-Entscheidung** — `do` ist reserviert |
| „expected expression" (vermutlich Struct-Literale) | 8 | Rezept wie PR #961 |
| `sys_clock_gettime` in `std/cloud/aws/core.lyx` | 6 | fehlende Funktion, 4 Folgefehler |
| `_svgFlushPendingGroup` nie definiert | 4 | fehlende Implementierung |
| `alloc`-Import fehlt (keccak, mongo, …) | 6 | fehlender Import |
| „unexpected top-level token" (vermutlich `const`) | 3 | Rezept wie PR #961 |
| `Open`, `nib`, `CpuFeatureDetect` | 3 | je eine fehlende Funktion |
| `std/net/ssh.lyx` braucht `@capabilities` | 1 | OS-Klasse, Policy |

## Zwei Punkte brauchen eine Entscheidung

1. **`std/cloud/do/` umbenennen** (z.B. → `digitalocean`) ist eine öffentliche
   API-Änderung und trifft jeden Importeur.
2. Die semantischen Lücken (`read_raw`, `_svgFlushPendingGroup`, `CF_AUTH_TOKEN`)
   bedeuten, dass diese Units **nie** erfolgreich übersetzt wurden. Dort fehlt
   Implementierung, nicht Syntax.

## Vollständige Liste

| Unit | Fehler |
|------|--------|
| `std/cloud/aws/core.lyx` | sema error (line 318): undefined function 'sys_clock_gettime' |
| `std/cloud/aws/sigv4.lyx` | sema error (line 477): undefined function 'sys_clock_gettime' |
| `std/cloud/aws/transport.lyx` | std/cloud/aws/core.lyx: sema error (line 318): undefined function 'sys_clock_gettime' |
| `std/cloud/aws/xml.lyx` | Parse error at line 226: expected expression |
| `std/cloud/cf/analytics.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/cache.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/core.lyx` | Parse error at line 12: unexpected top-level token |
| `std/cloud/cf/credentials.lyx` | sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/d1.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/dns.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/email.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/kv.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/lb.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/pages.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/r2.lyx` | Parse error at line 16: unexpected top-level token |
| `std/cloud/cf/transport.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/tunnel.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/waf.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/workers.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cf/zones.lyx` | std/cloud/cf/credentials.lyx: sema error (line 57): undefined symbol 'CF_AUTH_TOKEN' |
| `std/cloud/cloudwatch.lyx` | Parse error at line 27: expected IDENT, got unit 'unit' |
| `std/cloud/do/apps.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/core.lyx` | Parse error at line 7: expected IDENT, got do 'do' |
| `std/cloud/do/credentials.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/databases.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/droplets.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/functions.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/kubernetes.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/monitoring.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/networking.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/registry.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/spaces.lyx` | Parse error at line 8: expected IDENT, got do 'do' |
| `std/cloud/do/transport.lyx` | sema error (line 499): falsche Argument-Anzahl im Aufruf von 'doMakePath3' |
| `std/cloud/do/volumes.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/dynamodb.lyx` | Parse error at line 60: expected expression |
| `std/cloud/ec2.lyx` | std/cloud/aws/core.lyx: sema error (line 318): undefined function 'sys_clock_gettime' |
| `std/cloud/iam.lyx` | Parse error at line 242: expected expression |
| `std/cloud/lambda.lyx` | Parse error at line 358: expected expression |
| `std/cloud/s3.lyx` | std/cloud/aws/core.lyx: sema error (line 318): undefined function 'sys_clock_gettime' |
| `std/cloud/secrets.lyx` | std/cloud/aws/core.lyx: sema error (line 318): undefined function 'sys_clock_gettime' |
| `std/cloud/sns.lyx` | Parse error at line 33: expected expression |
| `std/cloud/sqs.lyx` | Parse error at line 50: expected expression |
| `std/cpu/dispatch.lyx` | sema error (line 26): undefined function 'CpuFeatureDetect' |
| `std/cpu/features.lyx` | sema error (line 49): undefined function 'Open' |
| `std/crypto/keccak.lyx` | sema error (line 23): undefined function 'alloc' |
| `std/crypto/pqc/mldsa.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/crypto/pqc/mlkem.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/crypto/pqc/pqc.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/db/mysql.lyx` | Parse error at line 1801: expected expression |
| `std/hardware/bluetooth_ext.lyx` | sema error (line 397): undefined function '_a8' |
| `std/hardware/bluetooth_gatts.lyx` | sema error (line 125): undefined function 'nib' |
| `std/lyxvision/app.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/button.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/cluster.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/dialog.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/drivers.lyx` | sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/frame.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/group.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/inputline.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/listview.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/main.lyx` | Parse error at line 15: unexpected top-level token |
| `std/lyxvision/menu.lyx` | Parse error at line 35: expected expression |
| `std/lyxvision/staticline.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/statictext.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/tapplication.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/terminal.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/textdevice.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/view.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/window.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/net/mongo.lyx` | sema error (line 426): undefined function 'alloc' |
| `std/net/ssh.lyx` | sema error (line 56): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation |
| `std/svg/defs.lyx` | sema error (line 227): undefined function '_svgFlushPendingGroup' |
| `std/svg/image.lyx` | sema error (line 370): undefined function '_svgFlushPendingGroup' |
| `std/svg/path.lyx` | sema error (line 17): undefined function '_svgFlushPendingGroup' |
| `std/svg/text.lyx` | sema error (line 121): undefined function '_svgFlushPendingGroup' |

## Sweep-Abdeckung

`test_compile_units.sh` iteriert über `"$STD_DIR"/*.lyx` — also nur die oberste
Ebene. Auf `find std data -name '*.lyx'` umzustellen macht die Lücke sichtbar,
färbt die Suite aber sofort rot. Sinnvoll erst, wenn die Liste oben abgearbeitet ist.
