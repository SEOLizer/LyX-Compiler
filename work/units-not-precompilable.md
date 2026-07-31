# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

`make precompile-units` erzeugt für diese 16 Units keine `.lyu`.
Ausgangslage war 88. Die Klassen Keyword-Kollision, nicht existierende Syntax,
fehlende Imports, falsche Builtin-Namen, verschachtelte Funktionen und der
`do`-Namespace sind erledigt.

Der Sweep `test_compile_units.sh` sieht sie nicht — er prüft nur `std/*.lyx`,
keine Unterverzeichnisse.

## Verbleibend

| Unit | Fehler | Charakter |
|------|--------|-----------|
| `std/cloud/cf/analytics.lyx` | sema error (line 123): undefined function 'int64ToStr' | Funktion existiert nicht — `Int64ToStr` (großes I) ist gemeint? |
| `std/cloud/cf/email.lyx` | sema error (line 136): undefined function 'int64ToStr' | Funktion existiert nicht — `Int64ToStr` (großes I) ist gemeint? |
| `std/cloud/cf/r2.lyx` | std/cloud/s3.lyx: sema error (line 357): undefined function 'AWSCredentials' | Typ/Funktion fehlt in std/cloud/s3.lyx |
| `std/cloud/cloudwatch.lyx` | Parse error at line 35: expected IDENT, got unit 'unit' | `unit` als Bezeichner — mechanisch |
| `std/cloud/ec2.lyx` | sema error (line 137): verschachtelte Funktion darf keine lokale Variable der umgebenden Funktion verwenden 'buf' | echte Closure über mutierte Locals — Umbau auf Cursor-Parameter |
| `std/cloud/lambda.lyx` | Parse error at line 358: expected expression | Rest-Syntax, einzeln zu prüfen |
| `std/cloud/s3.lyx` | sema error (line 357): undefined function 'AWSCredentials' | Typ/Funktion fehlt in std/cloud/s3.lyx |
| `std/cpu/dispatch.lyx` | sema error (line 26): undefined function 'CpuFeatureDetect' | in features.lyx als `fn` statt `pub fn` deklariert |
| `std/cpu/features.lyx` | sema error (line 49): undefined function 'Open' | vermutlich `open` gemeint |
| `std/db/mysql.lyx` | Parse error at line 1801: expected expression | Rest-Syntax, einzeln zu prüfen |
| `std/lyxvision/menu.lyx` | Parse error at line 35: expected expression | Rest-Syntax, einzeln zu prüfen |
| `std/net/ssh.lyx` | sema error (line 56): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation | OS-Klasse — Policy-Entscheidung |
| `std/svg/defs.lyx` | sema error (line 227): undefined function '_svgFlushPendingGroup' | in svg/elements.lyx definiert, Import fehlt |
| `std/svg/image.lyx` | sema error (line 370): undefined function '_svgFlushPendingGroup' | in svg/elements.lyx definiert, Import fehlt |
| `std/svg/path.lyx` | sema error (line 17): undefined function '_svgFlushPendingGroup' | in svg/elements.lyx definiert, Import fehlt |
| `std/svg/text.lyx` | sema error (line 121): undefined function '_svgFlushPendingGroup' | in svg/elements.lyx definiert, Import fehlt |

## Was davon eine Entscheidung braucht

- `std/net/ssh.lyx`: OS-Klassen-Extern ohne `@capabilities`. Entweder annotieren
  oder die Unit auf Builtins umstellen — wie bei `std.process` geschehen.
- `std/cloud/ec2.lyx`: die verschachtelten Helfer mutieren äußere Locals
  (`buf`, `off`). Verschachtelte Funktionen haben keinen Static Link; das
  braucht einen Umbau auf einen Cursor-Parameter.

## Sweep-Abdeckung

`test_compile_units.sh` iteriert über `"$STD_DIR"/*.lyx` — nur die oberste
Ebene. Auf `find std data -name '*.lyx'` umzustellen macht die Lücke sichtbar;
bei 16 verbleibenden Fehlern ist das jetzt in Reichweite.
