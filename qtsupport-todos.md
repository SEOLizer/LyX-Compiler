# Qt Support for Lyx - Implementation Plan

## ✅ WP1: Qt Core/OpenGL/EGL/GLX FFI (COMPLETED)

**Erstellt und committed (Branch: feat/qt-support-linux):**

### std/qt5_core.lyx (C-FFI + Stubs)
| Funktion | Status |
|----------|--------|
| `qVersion()` | ✅ C-FFI |
| `qgetenv/qputenv/qunsetenv` | ✅ C-FFI |
| `QCoreApplication_*` statisch | ✅ C-FFI |
| `QTimer` via timerfd | ✅ C-FFI (Linux-native!) |
| `QCoreApplicationQuit()` | ⚠️ Stub (C++ needed) |
| `QCoreApplicationProcessEvents()` | ⚠️ Stub (C++ needed) |
| `QStringFromUtf8()` | ⚠️ Stub (C++ needed) |
| Qt Konstanten (~50+) | ✅ Implementiert |

### std/qt5_gl.lyx (OpenGL 2.1)
- `glClear`, `glDrawArrays`, `glVertexAttribPointer`
- `glCreateShader`, `glShaderSource`, `glCompileShader`
- `glCreateProgram`, `glAttachShader`, `glLinkProgram`
- `glGenBuffers`, `glBindBuffer`, `glBufferData`
- `glGenTextures`, `glTexImage2D`, `glTexParameteri`

### std/qt5_egl.lyx (EGL 1.4)
- `eglGetDisplay`, `eglInitialize`, `eglTerminate`
- `eglChooseConfig`, `eglCreateContext`
- `eglCreateWindowSurface`, `eglMakeCurrent`
- `eglSwapBuffers`, `eglSwapInterval`

### std/qt5_glx.lyx (GLX 1.4)
- `glXChooseVisual`, `glXCreateContext`
- `glXMakeCurrent`, `glXSwapBuffers`
- `glXSwapIntervalEXT`, `glXSwapIntervalMESA`

### std/x11.lyx
- X11 Display functions: XOpenDisplay, XCloseDisplay
- X11 Window functions: XCreateWindow, XCreateSimpleWindow
- X11 Screen functions: XDefaultScreen, XRootWindow

---

## 🔄 WP2: Test mit OpenGL Window (PARTIAL - ISSUE FOUND)

### Tests durchgeführt

| Test | Status | Ergebnis |
|------|--------|----------|
| X11 (XOpenDisplay, etc.) | ✅ FUNKTIONIERT | Display opened, Screen: 0 |
| GLX (glXChooseVisual, etc.) | ❌ CRASH | Memory access violation |
| X11 + GLX combined | ❌ CRASH | Memory access violation |

### Erkanntes Problem

**GLX-Funktionen (libGL.so.1) funktionieren nicht aus Lyx heraus:**
- Alle GLX-Aufrufe (glXChooseVisual, glXCreateContext, etc.) führen zu Segfault
- Auch最简单的 Aufruf `glXChooseVisual(dpy, screen, 0)` crasht
- Selbst ohne Fenster/Erstellung - nur der Funktionsaufruf reicht zum Crash

**Funktioniert:**
```lyx
extern fn XOpenDisplay(name: int64): int64 link "libX11.so.6";  // ✅
extern fn glXChooseVisual(...) link "libGL.so.1";                // ❌ Crash
```

### Mögliche Ursachen
1. GLX könnte andere calling convention haben
2. libGL.so.1 könnte spezielle Initialisierung brauchen
3. Lyx könnte Probleme mit某些 GL-Funktionssignaturen haben

### Workaround
Bis das Problem gelöst ist:
- X11 FFI funktioniert vollständig
- OpenGL/GLX FFI muss noch untersucht werden
- EGL könnte funktionieren (testen)

---

## 📋 Future Work Packages

### WP3: C++ Wrapper für Qt Widgets
```
qt_wrapper.cpp:
  - QApplication_create()
  - QWidget_create(), QWidget_show(), QWidget_setTitle()
  - QPushButton_create(), QPushButton_setText()
  - QLabel_create(), QLabel_setText()
```
→ `libqtlyx.so` kompilieren
→ Lyx FFI Bindings in `std/qt5_widgets.lyx`

### WP4: OpenGL Issue untersuchen
- Warum funktioniert GLX aus Lyx nicht?
- C-Test funktioniert - also kein systemisches Problem
-可能是 Lyx FFI-Handling für libGL.so.1

---

## Commit Log

```
feat(std): add Qt5/OpenGL/EGL/GLX FFI binding units          (1a1be86)
feat(std): expand qt5_core.lyx - implement C-FFI functions      (5450171)
refactor(std): improve qt5_core documentation                 (7e8de6c)
docs(qt): revise Qt plan - Lyx FFI approach                    (620f542)
docs(qt): update implementation plan - WP1 completed          (c45fd4c)
fix(std): resolve reserved keyword conflicts                   (1170736)
test(graphics): add working X11 test with direct extern       (4ccd57b)
```

---

## Nächste Schritte

1. **OpenGL/GLX Issue analysieren** - Warum crash GLX-Aufrufe?
2. **EGL testen** - Vielleicht funktioniert EGL besser als GLX
3. **C++ Wrapper für Qt Widgets** - Falls GLX nicht funktioniert