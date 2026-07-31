# Nicht kompilierbare Beispiele (Stand 2026-07-31, lyxc 1.0.9A)

**323 von 342 Beispielen übersetzen** (Ausgangslage: 256).

## Wie geprüft wird

Jedes Beispiel wird **aus seinem eigenen Verzeichnis** übersetzt, mit
`--std-path=<repo-root>` — also dem Verzeichnis ÜBER `std/`, nicht `std/` selbst.
Der Resolver baut aus `import std.foo` den Pfad `std/foo.lyx` und hängt ihn an
die Suchwurzeln; `--std-path=…/std` sucht deshalb `std/std/foo.lyx`.

Dateien mit `unit …;` sind Bibliotheken und werden mit `--compile-unit` geprüft.

## Drei davon sollen NICHT übersetzen

| Datei | Grund |
|---|---|
| `examples/graphics/dlopen_test.lyx` | `dlopen` steht auf der harten FFI-Blacklist — dynamisches Nachladen hebelt die Sandbox aus. Die Datei belegt das Verhalten und trägt einen entsprechenden Kopfkommentar. |
| `examples/syntax_highlight_examples/hello.lyx` | Fixture für Editor-Highlighting, kein Programm (`let`, `print_str`) |
| `examples/syntax_highlight_examples/case_switch.lyx` | dito |
| `examples/syntax_highlight_examples/consts.lyx` | dito |

## Verbleibende

| Beispiel | Fehler |
|---|---|
| `examples/graphics/dlopen_test.lyx` | sema error (line 1): extern fn in FFI-Blacklist (Klasse 3) — direkter Aufruf verboten |
| `examples/graphics/glx_test.lyx` | sema error (line 70): undefined function 'GLXCreateContextLegacy' |
| `examples/graphics/qt5_egl_test.lyx` | sema error (line 39): undefined function 'EGLBindOpenGL' |
| `examples/graphics/test_ffi.lyx` | sema error (line 2): extern fn: ≥2 pchar-Parameter ohne Größenlimit (Klasse 3 via Signatur) |
| `examples/io/mmap/main_with_mmap.lyx` | sema error (line 1): Modul nicht gefunden (weder .lyx noch .lyu) 'myunit' |
| `examples/io/net/echo_client.lyx` | Parse error at line 40: expected ], got : ':' |
| `examples/io/net/echo_server.lyx` | sema error (line 129): undefined function 'read_raw' |
| `examples/io/net/icmp_test.lyx` | sema error (line 54): unknown type in var decl 'uint16' |
| `examples/ldap_test_simple.lyx` | sema error (line 9): undefined function 'LDAPErrorToStr' |
| `examples/lyxvision/lyxvision_demo.lyx` | sema error (line 79): undefined symbol 'IO' |
| `examples/syntax_highlight_examples/case_switch.lyx` | sema error (line 3): undefined function 'print_str' |
| `examples/syntax_highlight_examples/consts.lyx` | Parse error at line 6: expected expression |
| `examples/syntax_highlight_examples/hello.lyx` | sema error (line 3): undefined function 'print_str' |
| `examples/test_file_read.lyx` | error: undefined function 'sys_open' — no codegen implementation found |
| `examples/test_mmap_file.lyx` | error: undefined function 'sys_open' — no codegen implementation found |
| `examples/test_stack_peek.lyx` | Parse error at line 10: expected expression |
| `examples/thread_test.lyx` | sema error (line 13): undefined function 'MutexInit' |
| `examples/units/test/params.lyx` | sema error (line 5): undefined function 'print_int' |
| `examples/units/use_math_utils.lyx` | sema error (line 10): undefined symbol 'math_utils' |

## Muster in den verbleibenden

- **Funktionen, die es nicht gibt**: `GLXCreateContextLegacy`, `EGLBindOpenGL`,
  `LDAPErrorToStr`, `MutexInit`, `read_raw`, `print_int` — teils Wrapper, die
  nie geschrieben wurden, teils alte Namen.
- **`sys_open` fehlt im x86-Backend** (2 Dateien): in sema registriert, nur in
  emit_lyxos implementiert. Dieselbe Klasse wie die entfernten Phantom-Builtins,
  aber backend-spezifisch.
- **Qualifizierter Modulzugriff** (`math_utils.x`, `IO.x`): Modul-Symbole teilen
  sich einen flachen Namespace, `modul.name` gibt es nicht.
- **Sonstiges**: `uint16` als Typ, ein Parse-Fehler in `echo_client`, ein
  fehlendes `myunit` (Geschwister-Import ohne Suchpfad).
