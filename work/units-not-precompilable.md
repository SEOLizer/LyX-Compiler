# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

`make precompile-units` erzeugt für diese 38 Units keine `.lyu`.
Ausgangslage war 88; die Syntax- und Import-Klassen sind erledigt.

Der Sweep `test_compile_units.sh` sieht sie nicht — er prüft nur `std/*.lyx`,
keine Unterverzeichnisse.

## Verbleibende Ursachen

| Ursache | Units | Charakter |
|---|---:|---|
| **`do` als Namespace** (`std/cloud/do/`) | 12 | **API-Entscheidung** — `do` ist reserviert, das Verzeichnis ist unimportierbar |
| `w4` fehlt in `std/cloud/aws/sigv4.lyx` | 10 | fehlende Implementierung, 9 Folgefehler |
| `_svgFlushPendingGroup` nie definiert | 4 | fehlende Implementierung |
| „expected expression" | 3 | Rest-Syntax, einzeln zu prüfen |
| `int64ToStr` fehlt | 2 | fehlende Funktion |
| `Open`, `nib`, `CpuFeatureDetect`, `_a8` | 4 | je eine fehlende Funktion |
| `doMakePath3` mit falscher Argument-Anzahl | 1 | Signatur passt nicht |
| `unit` als Bezeichner | 1 | mechanisch |
| `std/net/ssh.lyx` braucht `@capabilities` | 1 | OS-Klasse, Policy |

## Was noch entschieden werden muss

1. **`std/cloud/do/` umbenennen** (z.B. → `digitalocean`): `do` ist ein
   reserviertes Wort, damit ist das ganze Verzeichnis unimportierbar. Ein
   Umbenennen ist eine öffentliche API-Änderung.
2. Die fehlenden Funktionen (`w4`, `_svgFlushPendingGroup`, `int64ToStr`,
   `Open`, `nib`, `CpuFeatureDetect`, `_a8`) bedeuten, dass diese Units **nie**
   erfolgreich übersetzt wurden. Dort fehlt Implementierung, nicht Syntax —
   der Aufwand hängt davon ab, was die Funktionen leisten sollen.

## Vollständige Liste

| Unit | Fehler |
|------|--------|
| `std/cloud/aws/sigv4.lyx` | sema error (line 544): undefined function 'w4' |
| `std/cloud/aws/transport.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/cf/analytics.lyx` | sema error (line 123): undefined function 'int64ToStr' |
| `std/cloud/cf/email.lyx` | sema error (line 136): undefined function 'int64ToStr' |
| `std/cloud/cf/r2.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
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
| `std/cloud/dynamodb.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/ec2.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/iam.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/lambda.lyx` | Parse error at line 358: expected expression |
| `std/cloud/s3.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/secrets.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/sns.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cloud/sqs.lyx` | std/cloud/aws/sigv4.lyx: sema error (line 544): undefined function 'w4' |
| `std/cpu/dispatch.lyx` | sema error (line 26): undefined function 'CpuFeatureDetect' |
| `std/cpu/features.lyx` | sema error (line 49): undefined function 'Open' |
| `std/db/mysql.lyx` | Parse error at line 1801: expected expression |
| `std/hardware/bluetooth_ext.lyx` | sema error (line 397): undefined function '_a8' |
| `std/hardware/bluetooth_gatts.lyx` | sema error (line 125): undefined function 'nib' |
| `std/lyxvision/menu.lyx` | Parse error at line 35: expected expression |
| `std/net/ssh.lyx` | sema error (line 56): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation |
| `std/svg/defs.lyx` | sema error (line 227): undefined function '_svgFlushPendingGroup' |
| `std/svg/image.lyx` | sema error (line 370): undefined function '_svgFlushPendingGroup' |
| `std/svg/path.lyx` | sema error (line 17): undefined function '_svgFlushPendingGroup' |
| `std/svg/text.lyx` | sema error (line 121): undefined function '_svgFlushPendingGroup' |

## Sweep-Abdeckung

`test_compile_units.sh` iteriert über `"$STD_DIR"/*.lyx` — nur die oberste
Ebene. Auf `find std data -name '*.lyx'` umzustellen macht die Lücke sichtbar,
färbt die Suite aber sofort rot. Sinnvoll, sobald die Liste oben leer ist.
