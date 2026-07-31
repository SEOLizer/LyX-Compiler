# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

`make precompile-units` erzeugt für diese 29 Units keine `.lyu`.
Ausgangslage war 88; die Syntax- und Import-Klassen sind erledigt.

Der Sweep `test_compile_units.sh` sieht sie nicht — er prüft nur `std/*.lyx`,
keine Unterverzeichnisse.

## Vollständige Liste

| Unit | Fehler |
|------|--------|
| `std/cloud/cf/analytics.lyx` | sema error (line 123): undefined function 'int64ToStr' |
| `std/cloud/cf/email.lyx` | sema error (line 136): undefined function 'int64ToStr' |
| `std/cloud/cf/r2.lyx` | std/cloud/s3.lyx: sema error (line 357): undefined function 'AWSCredentials' |
| `std/cloud/cloudwatch.lyx` | Parse error at line 35: expected IDENT, got unit 'unit' |
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
| `std/cloud/ec2.lyx` | sema error (line 137): verschachtelte Funktion darf keine lokale Variable der umgebenden Funktion verwenden 'buf' |
| `std/cloud/lambda.lyx` | Parse error at line 358: expected expression |
| `std/cloud/s3.lyx` | sema error (line 357): undefined function 'AWSCredentials' |
| `std/cpu/dispatch.lyx` | sema error (line 26): undefined function 'CpuFeatureDetect' |
| `std/cpu/features.lyx` | sema error (line 49): undefined function 'Open' |
| `std/db/mysql.lyx` | Parse error at line 1801: expected expression |
| `std/lyxvision/menu.lyx` | Parse error at line 35: expected expression |
| `std/net/ssh.lyx` | sema error (line 56): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation |
| `std/svg/defs.lyx` | sema error (line 227): undefined function '_svgFlushPendingGroup' |
| `std/svg/image.lyx` | sema error (line 370): undefined function '_svgFlushPendingGroup' |
| `std/svg/path.lyx` | sema error (line 17): undefined function '_svgFlushPendingGroup' |
| `std/svg/text.lyx` | sema error (line 121): undefined function '_svgFlushPendingGroup' |

## Verbleibende Kategorien

| Ursache | Units | Charakter |
|---|---:|---|
| **`do` als Namespace** (`std/cloud/do/`) | 12 | **API-Entscheidung** — `do` ist reserviert |
| `_svgFlushPendingGroup` — Import fehlt in svg-Untermodulen | 4 | mechanisch |
| „expected expression" | 3 | Rest-Syntax |
| `int64ToStr` fehlt | 2 | fehlende Funktion |
| `AWSCredentials` fehlt | 2 | fehlender Typ/Import |
| `std/cloud/ec2.lyx`: verschachtelte fn mutiert äußere Locals | 1 | echte Closure — braucht Umbau auf Cursor-Parameter |
| `Open`, `CpuFeatureDetect` | 2 | fehlend bzw. nicht `pub` |
| `doMakePath3`-Arity, `unit`-Bezeichner, ssh-`@capabilities` | 3 | einzeln |
