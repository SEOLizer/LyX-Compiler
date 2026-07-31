# Testbestand ausserhalb von `make test` (Inventur zu Issue #1004)

Stand 2026-07-31, lyxc 1.0.10A.

`make test` ruft 20 Prueflaeufe auf. In `tests/` liegen daneben **8 Shell-Tests
und 193 `.lyx`-Tests**, die dabei nicht angefasst werden. Diese Inventur haelt
fest, was davon laeuft — Schritt 1 aus dem Issue.

Nicht mitgezaehlt: `ppas.sh` (Artefakt des FPC-Assemblers, kein Test) und
`run_lyx_tests.sh` (ein Runner fuer `tests/lyx/`, kein Test).

## Shell-Tests: 8 von 8 gruen

Vier waren rot, alle vier aus demselben Grund: die Existenzpruefung fuer
Feldnamen aus PR #988 lief nur ueber die Felder einer Klasse (`c0`), nie ueber
ihre Methoden (`c1`). Damit wurde `btn.on_click := form.Handle` — das Binden
eines Methodenzeigers — als `unknown field 'Handle'` abgewiesen. Behoben; die
Methodenliste wird jetzt mitgeprueft.

Dass eine Regression im Compiler zwei Monate unbemerkt blieb, ist genau der
Punkt dieses Issues: **die Tests, die sie gefunden haetten, liefen nicht.**

| Test | Ergebnis |
|---|---|
| `arity_check_test.sh` | 5 PASS |
| `asm_block_test.sh` | 5 PASS |
| `elf_reloc_test.sh` | 5 PASS |
| `fnptr_field_test.sh` | 3 PASS |
| `inline_fnptr_test.sh` | 3 PASS (war 2/1) |
| `local_fnptr_test.sh` | 5 PASS (war 4/1) |
| `method_ptr_test.sh` | 3 PASS (war 1/2) |
| `method_ptr_xmod_test.sh` | 2 PASS (war 0/2) |

Alle acht sind schnell und ohne Fremdabhaengigkeit — sie gehoeren ins
`test`-Target.

## `.lyx`-Tests: 193

Gemessen mit `--std-path=<root>`, ELF-Ziel, 90 s zum Uebersetzen und 20 s zur
Ausfuehrung.

| Ergebnis | Anzahl |
|---|---|
| laeuft mit Exit 0 | 104 |
| laeuft mit Exit != 0 | 53 |
| uebersetzt nicht | 34 |
| Zeitueberschreitung | 2 |

Die Zahl 104 ist eine Untergrenze: mehrere Tests nutzen **42 als Erfolgscode**,
werden hier also als Fehlschlag gezaehlt. Vor dem Verdrahten muss die Konvention
je Test geklaert werden.

### Uebersetzt nicht — aber falsches Ziel (15)

lx06_vfs_test.lyx lx09_process_test.lyx lx10_ipc_test.lyx lx11_time_test.lyx lx12_caps_test.lyx lx13_task_test.lyx lx14_ai_test.lyx lx15_embed_test.lyx lx16_graph_test.lyx lx17_lyra_test.lyx lx18_iofs_test.lyx lx19_lyxrt_test.lyx lx20_io_test.lyx lx21_tworet_test.lyx lx22_debug_test.lyx

Diese Tests sind fuer LyxOS geschrieben. Mit `--target=lyxos` uebersetzen
**15 von 15**. Kein Defekt, sondern ein fehlendes Ziel im Aufruf.

### Uebersetzt nicht — Cloud- und Datenbank-Demos (13)

aws_demo1_s3.lyx cf_demo3_d1.lyx cf_demo5_waf_analytics.lyx cf_integration.lyx demo_pg_copy.lyx demo_pg_stmt.lyx demo_s3_bulk.lyx demo_s3_crud.lyx demo_s3_list.lyx demo_s3_minio.lyx demo_s3_multipart.lyx demo_s3_presign.lyx s3_integration.lyx

Brauchen Zugangsdaten bzw. laufende Dienste. Gehoeren nicht ins `test`-Target.

### Uebersetzt nicht — echte Befunde (6)

| Test | Meldung |
|---|---|
| `generics_monomorph_test.lyx` | `Parse error at line 13: expected (, got [` |
| `match_exhaustiveness_test.lyx` | `Parse error at line 22: expected }, got :=` |
| `struct_packing_test.lyx` | `unknown type in var decl 'uint8'` |
| `test_class_embedding.lyx` | `Parse error at line 35: expected (, got ;` |
| `wp08_printf_format.lyx` | `undefined function 'Printf' — no codegen implementation found` |
| `hl703_result_test.lyx` | `Modul nicht gefunden 'std.hl7.results'` |

`Printf` ist in sema registriert und in `ir_lower.lyx` fuer die ARM64-Backends
gelowert, im x86-Codegen aber nicht implementiert — dieselbe Form wie zuvor bei
`sys_open` und den Atomics. Auf ELF ist die Funktion damit unbenutzbar; als
Ersatz gibt es die typisierten `PrintfS`/`PrintfI`/`PrintfF` in `std/io.lyx`.

`uint8` als Typ im var-Deklarator kennt sema nicht — derselbe Fund wie zuvor bei
`uint16` in den Beispielen.

### Laeuft, meldet aber Fehlschlaege

Stichprobe unter den sprachnahen Tests; die Programme geben `FAIL`-Zeilen aus
und enden mit Exit 1:

| Test | Meldung |
|---|---|
| `soft_keywords_test.lyx` | `range(5) sum expected 10, got 0` |
| `defer_scope_test.lyx` | `FAIL: single defer` |
| `compound_tokens_test.lyx` | `range sum expected 10, got 127326386040853` |
| `lexer_float_dot_test.lyx` | `3.14_159 should be > 3.14` |
| `meta_safe_test.lyx` | `FAIL: GetPageHash(0)` |

`defer` und `range` sind in `ebnf.md` als Soft Keywords mit Semantik gefuehrt,
funktionieren aber nicht. Der Unterstrich im Float-Literal wird nicht erkannt.

### Zeitueberschreitung (2)

`lx08_net_test.lyx`, `test_ipv6.lyx` — Netzwerktests, die auf Antwort warten.

## Naechste Schritte

1. Die 8 Shell-Tests ins `test`-Target (mit dieser Aenderung erledigt).
2. Fuer die `.lyx`-Tests die Erfolgskonvention je Test klaeren (Exit 0 vs. 42),
   dann die schnellen und gruenen ins `test`-Target, die uebrigen in ein
   getrenntes Ziel (`test-full`) mit LyxOS-Ziel bzw. Dienstabhaengigkeit.
3. Fuer die echten Befunde je ein Issue.
4. Eine Pruefung ergaenzen, die neue Testdateien meldet, die in keinem Ziel
   auftauchen — sonst waechst der Bestand wieder unbemerkt.
