# Nicht vorkompilierbare Units (Stand 2026-07-31, lyxc 1.0.9A)

**388 von 390 Units übersetzen.** Ausgangslage war 302 von 390.

Es verbleiben zwei — beide brauchen eine Entscheidung, keine Reparatur:

| Unit | Fehler | Was zu klären ist |
|------|--------|-------------------|
| `std/cloud/ec2.lyx` | verschachtelte Funktion darf keine lokale Variable der umgebenden Funktion verwenden (`buf`, Zeile 137) | Die Helfer `ap`/`apc`/`apN` **mutieren** `buf` und `off` der umgebenden Funktion. Verschachtelte Funktionen bekommen keinen Static Link, ein Lesen liefe still ins Leere — deshalb lehnt sema es ab. Umbau: Cursor als Parameter (Zeiger auf ein 2-Slot-Feld mit `buf` und `off`), oder die Helfer auf Unit-Ebene ziehen. |
| `std/net/ssh.lyx` | extern fn mit OS-Zugriff erfordert `@capabilities([...])` (Zeile 56) | Sicherheits-Policy. Entweder die Unit annotieren, oder — wie bei `std.process` geschehen — auf Compiler-Builtins umstellen, sodass gar kein OS-Klassen-Extern nötig ist. |

## Verlauf

| Stand | übersetzbar | offen |
|---|---:|---:|
| Sitzungsbeginn | 302 | 88 |
| nach Keyword-Umbenennungen (#971) | 315 | 75 |
| nach Syntax + Imports (#972) | 352 | 38 |
| nach verschachtelten Funktionen (#974) | 361 | 29 |
| nach `do` → `digitalocean` (#975) | 374 | 16 |
| nach den mechanischen Resten | **388** | **2** |

## Sweep-Abdeckung

`test_compile_units.sh` iteriert über `"$STD_DIR"/*.lyx` — nur die oberste Ebene.
Genau deshalb blieben die 88 so lange unsichtbar: der Sweep meldete 92 OK / 0 failed,
während ein Viertel der stdlib nie geprüft wurde.

Mit nur noch zwei bekannten Fehlern ist die Umstellung auf
`find std data -name '*.lyx'` jetzt in Reichweite — sinnvollerweise zusammen mit
einer expliziten Known-Failures-Liste für die beiden Einträge oben.
