# Nicht kompilierbare Beispiele (Stand 2026-07-31, lyxc 1.0.9A)

**307 von 342 Beispielen übersetzen** (Ausgangslage: 256).

## Wie geprüft wird

Jedes Beispiel wird **aus seinem eigenen Verzeichnis** übersetzt, mit
`--std-path=<repo-root>` — also dem Verzeichnis ÜBER `std/`, nicht `std/`
selbst. Der Resolver baut aus `import std.foo` den Pfad `std/foo.lyx` und
hängt ihn an die Suchwurzeln; `--std-path=…/std` sucht deshalb `std/std/foo.lyx`.

Dateien mit `unit …;` sind Bibliotheken und werden mit `--compile-unit` geprüft.

## Verbleibende 38

| Ursache | Anzahl | Charakter |
|---|---:|---|
| FFI-Sandbox fail-closed (`@capabilities` fehlt) | 7 | Beispiele mit rohem FFI — brauchen `@cap(...)` bzw. eine Policy-Entscheidung |
| `Select` / `Poll` existieren nicht | 8 | weder Builtin noch stdlib-Funktion; gemeint ist vermutlich `sys_select` / `sys_poll` |

| `print_str` / `let` | 2 | `examples/syntax_highlight_examples/` sind **Highlighting-Fixtures**, keine Programme — gehören aus einem Compile-Sweep ausgenommen |
| `sys_open` fehlt im Codegen | 2 | in sema registriert, im x86-Backend nicht implementiert |
| Rest (Syntax, `uint16`, Einzelfälle) | 16 | einzeln zu prüfen |

## Vollständige Liste

| Beispiel | Fehler |
|---|---|
| `examples/games/game1/game1.lyx` | sema error (line 1): extern fn mit OS-Zugriff erfordert @capabilities([...])-Annotation |
| `examples/graphics/dlopen_test.lyx` | sema error (line 1): extern fn in FFI-Blacklist (Klasse 3) — direkter Aufruf verboten |
| `examples/graphics/egl_test.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/graphics/glx_direct.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/graphics/glx_minimal.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/graphics/glx_test.lyx` | sema error (line 70): undefined function 'GLXCreateContextLegacy' |
| `examples/graphics/glx_tiny.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/graphics/glx_visual_only.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/graphics/qt5_egl_test.lyx` | sema error (line 39): undefined function 'EGLBindOpenGL' |
| `examples/graphics/test_ffi.lyx` | sema error (line 2): extern fn: ≥2 pchar-Parameter ohne Größenlimit (Klasse 3 via Signatur) |
| `examples/graphics/x11_direct.lyx` | sema error (line 1): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/io/mmap/main_with_mmap.lyx` | sema error (line 1): Modul nicht gefunden (weder .lyx noch .lyu) 'myunit' |
| `examples/io/net/echo_client.lyx` | Parse error at line 40: expected ], got : ':' |
| `examples/io/net/echo_server.lyx` | sema error (line 129): undefined function 'read_raw' |
| `examples/io/net/icmp_test.lyx` | sema error (line 54): unknown type in var decl 'uint16' |
| `examples/ldap_test_simple.lyx` | sema error (line 9): undefined function 'LDAPErrorToStr' |
| `examples/lyxvision/lyxvision_demo.lyx` | sema error (line 79): undefined symbol 'IO' |
| `examples/syntax_highlight_examples/case_switch.lyx` | sema error (line 3): undefined function 'print_str' |
| `examples/syntax_highlight_examples/consts.lyx` | Parse error at line 6: expected expression |
| `examples/syntax_highlight_examples/hello.lyx` | sema error (line 3): undefined function 'print_str' |
| `examples/test_extern_redis.lyx` | sema error (line 2): extern fn: unbekanntes FFI-Symbol erfordert @capabilities([...]) (FFI-Sandbox Fail-Closed) |
| `examples/test_file_read.lyx` | error: undefined function 'sys_open' — no codegen implementation found |
| `examples/test_mmap_file.lyx` | error: undefined function 'sys_open' — no codegen implementation found |
| `examples/test_poll2.lyx` | sema error (line 31): undefined function 'Poll' |
| `examples/test_poll_check.lyx` | sema error (line 21): undefined function 'Poll' |
| `examples/test_poll_debug.lyx` | sema error (line 20): undefined function 'Poll' |
| `examples/test_select3.lyx` | sema error (line 25): undefined function 'Select' |
| `examples/test_select.lyx` | sema error (line 39): undefined function 'Select' |
| `examples/test_select_read2.lyx` | sema error (line 23): undefined function 'Select' |
| `examples/test_select_sanity.lyx` | sema error (line 29): undefined function 'Select' |
| `examples/test_select_workaround.lyx` | sema error (line 24): undefined function 'Select' |
| `examples/test_stack_peek.lyx` | Parse error at line 10: expected expression |
| `examples/thread_test.lyx` | sema error (line 13): undefined function 'MutexInit' |
| `examples/units/test/params.lyx` | sema error (line 5): undefined function 'print_int' |
| `examples/units/use_math_utils.lyx` | sema error (line 10): undefined symbol 'math_utils' |

## Querbezug

sema registriert **6 Namen als Builtin, die kein Backend implementiert**:
`PrintIntLn`, `PrintStrLn`, `StrCmp`, `StrNCmp`, `StrToFloat`, `StrToInt`.
Ein Aufruf besteht sema und scheitert erst im Codegen mit
"no codegen implementation found". Die ersten drei sind jetzt als echte
Funktionen in `std/io.lyx` bzw. `std/string.lyx` vorhanden — eine
Bibliotheksfunktion gewinnt gegen die Builtin-Registrierung. Die drei
übrigen existieren nirgends und sollten aus sema entfernt werden.
