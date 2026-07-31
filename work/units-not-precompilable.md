# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

`make precompile-units` erzeugt für diese 88 Units keine `.lyu`.
Der Sweep `test_compile_units.sh` sieht sie nicht — er prüft nur `std/*.lyx`,
keine Unterverzeichnisse.

## Nach Ursache

| Unit | Fehler |
|------|--------|
| `std/cloud/cf/analytics.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/cache.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/d1.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/dns.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/email.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/kv.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/lb.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/pages.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/transport.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/waf.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/workers.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/zones.lyx` | Parse error at line 108: expected IDENT, got match 'match' |
| `std/cloud/cf/credentials.lyx` | Parse error at line 109: expected IDENT, got match 'match' |
| `std/cloud/aws/core.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/ec2.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/firestore.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/functions.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/logging.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/pubsub.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/storage.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/gcp/transport.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/s3.lyx` | Parse error at line 124: expected IDENT, got match 'match' |
| `std/cloud/cf/core.lyx` | Parse error at line 12: unexpected top-level token |
| `std/cloud/secrets.lyx` | Parse error at line 136: expected IDENT, got match 'match' |
| `std/lyxvision/main.lyx` | Parse error at line 15: unexpected top-level token |
| `std/cloud/cf/r2.lyx` | Parse error at line 16: unexpected top-level token |
| `std/db/mysql.lyx` | Parse error at line 1800: expected IDENT, got pool 'pool' |
| `std/cloud/aws/xml.lyx` | Parse error at line 226: expected expression |
| `std/cloud/iam.lyx` | Parse error at line 242: expected expression |
| `std/cloud/cf/tunnel.lyx` | Parse error at line 248: expected IDENT, got to 'to' |
| `std/cloud/cloudwatch.lyx` | Parse error at line 27: expected IDENT, got unit 'unit' |
| `std/cloud/do/transport.lyx` | Parse error at line 339: expected IDENT, got match 'match' |
| `std/cloud/sns.lyx` | Parse error at line 33: expected expression |
| `std/cloud/lambda.lyx` | Parse error at line 358: expected expression |
| `std/lyxvision/menu.lyx` | Parse error at line 35: expected expression |
| `std/net/imap.lyx` | Parse error at line 364: expected IDENT, got match 'match' |
| `std/net/mongo.lyx` | Parse error at line 472: expected IDENT, got match 'match' |
| `std/cloud/sqs.lyx` | Parse error at line 50: expected expression |
| `std/cloud/gcp/jwt.lyx` | Parse error at line 54: expected IDENT, got match 'match' |
| `std/cloud/dynamodb.lyx` | Parse error at line 60: expected expression |
| `std/cloud/gcp/compute.lyx` | Parse error at line 62: expected IDENT, got match 'match' |
| `std/hardware/bluetooth_ext.lyx` | Parse error at line 68: expected IDENT, got match 'match' |
| `std/cloud/do/apps.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/credentials.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/databases.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/droplets.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/functions.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/kubernetes.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/monitoring.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/networking.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/registry.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/do/volumes.lyx` | Parse error at line 6: expected IDENT, got do 'do' |
| `std/cloud/gcp/secrets.lyx` | Parse error at line 71: expected IDENT, got match 'match' |
| `std/cloud/gcp/oauth.lyx` | Parse error at line 73: expected IDENT, got match 'match' |
| `std/cloud/gcp/credentials.lyx` | Parse error at line 76: expected IDENT, got match 'match' |
| `std/cloud/do/core.lyx` | Parse error at line 7: expected IDENT, got do 'do' |
| `std/cloud/do/spaces.lyx` | Parse error at line 8: expected IDENT, got do 'do' |
| `std/cloud/aws/transport.lyx` | Parse error at line 93: expected IDENT, got match 'match' |
| `std/net/ldap.lyx` | Parse error at line 958: expected IDENT, got match 'match' |
| `std/svg/text.lyx` | sema error (line 121): undefined function '_svgFlushPendingGroup' |
| `std/hardware/bluetooth_gatts.lyx` | sema error (line 125): undefined function 'nib' |
| `std/svg/path.lyx` | sema error (line 17): undefined function '_svgFlushPendingGroup' |
| `std/svg/defs.lyx` | sema error (line 227): undefined function '_svgFlushPendingGroup' |
| `std/crypto/keccak.lyx` | sema error (line 23): undefined function 'alloc' |
| `std/cpu/dispatch.lyx` | sema error (line 26): undefined function 'CpuFeatureDetect' |
| `std/svg/image.lyx` | sema error (line 370): undefined function '_svgFlushPendingGroup' |
| `std/lyxvision/drivers.lyx` | sema error (line 410): undefined function 'read_raw' |
| `std/cloud/aws/sigv4.lyx` | sema error (line 477): undefined function 'sys_clock_gettime' |
| `std/cpu/features.lyx` | sema error (line 49): undefined function 'Open' |
| `std/net/ssh.lyx` | sema error (line 56): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation |
| `std/crypto/pqc/mldsa.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/crypto/pqc/mlkem.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/crypto/pqc/pqc.lyx` | std/crypto/keccak.lyx: sema error (line 23): undefined function 'alloc' |
| `std/lyxvision/app.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/button.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/cluster.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/dialog.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/frame.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/group.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/inputline.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/listview.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/staticline.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/statictext.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/tapplication.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/terminal.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/textdevice.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/view.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |
| `std/lyxvision/window.lyx` | std/lyxvision/drivers.lyx: sema error (line 410): undefined function 'read_raw' |

## Kategorien

| Kategorie | Units | Charakter |
|---|---:|---|
| `match` als Variablenname | 34 | mechanisch, lokale Umbenennung |
| **`do` als Namespace** (`import std.cloud.do.transport`) | 12 | **API-Entscheidung** — `do` ist reserviert, das ganze `std/cloud/do/` ist unimportierbar |
| `read_raw` fehlt in `std/lyxvision/drivers.lyx` | 16 | 1 Ursache, 15 Folgefehler |
| „expected expression" (vermutlich Struct-Literale) | 7 | Rezept wie PR #961 |
| `_svgFlushPendingGroup` nie definiert | 4 | fehlende Implementierung |
| `alloc`-Import fehlt in `std/crypto/keccak.lyx` | 4 | 1 Ursache, 3 Folgefehler |
| „unexpected top-level token" (vermutlich `const`) | 3 | Rezept wie PR #961 |
| `pool`, `unit`, `to` als Bezeichner | 3 | mechanisch |
| `sys_clock_gettime`, `CpuFeatureDetect`, `Open`, `nib` | 4 | je eine fehlende Funktion |
| `std/net/ssh.lyx` braucht `@capabilities` | 1 | OS-Klasse, Policy |

## Zwei Punkte brauchen eine Entscheidung

1. **`std/cloud/do/` umbenennen** (z.B. → `digitalocean`) ist eine öffentliche
   API-Änderung und trifft jeden Importeur.
2. Die semantischen Fehler (`read_raw`, `_svgFlushPendingGroup`) bedeuten, dass
   diese Units **nie** erfolgreich übersetzt wurden. Dort fehlt Implementierung,
   nicht Syntax.

## Sweep-Abdeckung

`test_compile_units.sh` iteriert über `"$STD_DIR"/*.lyx` — also nur die oberste
Ebene. Auf `find std data -name '*.lyx'` umzustellen macht die Lücke sichtbar,
färbt die Suite aber sofort rot. Sinnvoll erst, wenn die Liste oben abgearbeitet
ist (oder mit einer expliziten Known-Failures-Liste).
