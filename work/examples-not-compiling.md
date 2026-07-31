# Nicht kompilierbare Beispiele (Stand 2026-07-31, lyxc 1.0.10A)

**336 von 342 Beispielen übersetzen** (Ausgangslage: 256).

## Wie geprüft wird

Jedes Beispiel wird **aus seinem eigenen Verzeichnis** übersetzt, mit
`--std-path=<repo-root>` — also dem Verzeichnis ÜBER `std/`, nicht `std/` selbst.
Der Resolver baut aus `import std.foo` den Pfad `std/foo.lyx` und hängt ihn an
die Suchwurzeln; `--std-path=…/std` sucht deshalb `std/std/foo.lyx`.

Dateien mit `unit …;` sind Bibliotheken und werden mit `--compile-unit` geprüft.
Die `unit`-Zeile steht nicht zwingend in den ersten drei Zeilen — wer nur den
Dateikopf absucht, meldet sechs Bibliotheken fälschlich als kaputt.

## Fünf davon sollen NICHT übersetzen

| Datei | Grund |
|---|---|
| `examples/graphics/dlopen_test.lyx` | `dlopen` steht auf der harten FFI-Blacklist — dynamisches Nachladen hebelt die Sandbox aus. Die Datei belegt das Verhalten und trägt einen entsprechenden Kopfkommentar. |
| `examples/graphics/test_ffi.lyx` | ≥2 `pchar`-Parameter ohne Größenlimit ⇒ Klasse 3 über die Signatur. Belegt die Signatur-Heuristik der Sandbox. |
| `examples/syntax_highlight_examples/hello.lyx` | Fixture für Editor-Highlighting, kein Programm (`let`, `print_str`) |
| `examples/syntax_highlight_examples/case_switch.lyx` | dito |
| `examples/syntax_highlight_examples/consts.lyx` | dito |

## Verbleibend: eines

| Beispiel | Fehler | Bewertung |
|---|---|---|
| `examples/io/mmap/main_with_mmap.lyx` | `sema error (line 1): Modul nicht gefunden … 'myunit'` | Wortgleiches, aber kaputtes Duplikat von `examples/units/main_with_unit.lyx`: es nutzt qualifizierten Zugriff (`myunit.call_ioctl()`, den es nicht gibt) und liegt in einem Verzeichnis ohne `myunit`-Geschwisterdatei. Demonstriert außerdem nichts zu mmap. Kandidat zum Löschen — nicht ohne Rückfrage entfernt. |

## Was in dieser Runde behoben wurde

- **Qualifizierter Modulzugriff** (`IO.alloc`, `math_utils.add`): Modul-Symbole
  teilen sich einen flachen Namespace, `modul.name` gibt es nicht — Präfix weg.
- **Alte Funktionsnamen**: `read_raw`→`read`, `MutexInit`→`MutexNew`,
  `AtomicInit`→`AtomicNew`, `print_int`/`print_str`→`PrintInt`/`PrintStr`.
- **Fehlender Import**: `LDAPErrorToStr` existiert in `std/net/ldap.lyx`, das
  Beispiel importierte die Unit nicht.
- **Adressoperator**: `&y` → `@y`.
- **`uint16` als var-Typ** → `int64`.
- **`echo_client.lyx` neu geschrieben**: war durchgängig Go (Tupel-Destructuring,
  Slices, `nil`, `err.Error()`). Jetzt gegen die echte Socket-API
  (`TCPConnect`/`TCPConnWrite`/`TCPConnRead`/`TCPConnClose`); end-to-end gegen
  `echo_server.lyx` verifiziert.
- **GLX-/EGL-Wrapper geschrieben**: `std/qt5_glx.lyx` und `std/qt5_egl.lyx`
  enthielten nur Konstanten und rohe `extern fn`-Bindings. Die typisierten
  Hüllen, die der Kommentarblock „Usage pattern“ in `qt5_egl.lyx` als API
  beschreibt, waren nie geschrieben worden — die Beispiele riefen sie trotzdem.
  Ergänzt: `GLXCreateContextLegacy`/`GLXMakeCurrent`/`GLXDestroyContext`/
  `GLXSwapBuffers` sowie `EGLGetDisplay`/`EGLBindOpenGL`/`EGLBindOpenGLES`/
  `EGLCreateContext`/`EGLCreateWindowSurface`/`EGLMakeCurrent`/`EGLSwapBuffers`/
  `EGLTerminate`. `EGLDisplay` ist dabei vom `int64`-Alias zum Struct mit
  `display`/`initialized` geworden (es hatte keine anderen Nutzer), damit
  `eglTerminate` nicht auf uninitialisierte Displays läuft.
  Regressionstest: `tests/glx_egl_wrappers_test.sh` (compile-only — libGL/libEGL
  sind auf einem Buildhost ohne GPU nicht sinnvoll aufrufbar).

## Nebenbefund

`AtomicAdd` in `std/thread.lyx` liest und schreibt mit `peek64`/`poke64` und ist
damit **nicht atomar** — trotz des Namens. Für echte Atomarität müssten die
WSP-Atomics-Builtins verwendet werden. Separat zu behandeln, hier nur notiert;
das Beispiel beschriftete den Rückgabewert zusätzlich als „old value“, obwohl die
Funktion laut eigenem Kommentar den neuen Wert liefert (Beschriftung korrigiert).
