# Qt Support for Lyx - Implementation Plan (REVISED)

## ⚠️ WICHTIG: Qt-Bindings in Lyx, nicht Pascal!

Der FFI-Mechanismus in Lyx funktioniert wie in `std/net/tls.lyx`:
```lyx
extern fn SSL_new(ctx: int64): int64 link "libssl.so.3";
```

Qt hat aber das Problem: Viele Widgets sind C++ (keine C-FFI möglich).

---

## Architektur-Ansatz

### Option A: OpenGL-only (einfach, C-FFI reicht)

Qt OpenGL hat C-kompatible Funktionen:
- `QOpenGLContext` (C++ Wrapper nötig)
- `gl*` Funktionen (Standard OpenGL - C-FFI direkt!)
- `EGL` / `GLX` (C-FFI direkt)

→ **Qt OpenGL ist via Lyx FFI machbar!**

### Option B: C++ Wrapper für Widgets

Für QWidget, QLabel, QPushButton brauchen wir einen C-Wrapper:
```c
// qt_wrapper.h
void* lyx_qwidget_create(void* parent, int x, int y, int w, int h);
void  lyx_qwidget_show(void* widget);
void  lyx_qpushbutton_set_text(void* btn, const char* text);
```

---

## Implementation Work Packages

### WP1: Qt Core via Lyx FFI (Phase 1 - OpenGL)
- [ ] `std/qt5_core.lyx` - Qt Core C-kompatible Funktionen
  - `QCoreApplication::exec()` - via C-Wrapper
  - `QTimer` - via C-Wrapper
  - `QString::toUtf8()` - via QByteArray C-API
- [ ] `std/qt5_gl.lyx` - OpenGL Bindings
  - `glClear`, `glDrawArrays`, `glVertexAttribPointer` etc.
  - `glCreateShader`, `glShaderSource`, `glCompileShader`
  - `glCreateProgram`, `glAttachShader`, `glLinkProgram`
- [ ] Test: Minimal OpenGL-Fenster mit Lyx

### WP2: EGL/GLX Surface (Phase 2)
- [ ] `std/qt5_egl.lyx` - EGL für Wayland/X11
  - `eglGetDisplay`, `eglInitialize`, `eglCreateWindowSurface`
  - `eglBindAPI`, `eglSwapBuffers`
- [ ] `std/qt5_glx.lyx` - GLX (X11 Fallback)
  - `glXChooseVisual`, `glXCreateContext`, `glXMakeCurrent`

### WP3: C++ Wrapper für Qt Widgets (Phase 3)
- [ ] Erstelle `qt_wrapper.cpp` mit:
  ```cpp
  extern "C" {
    void* QApplication_create();
    void* QWidget_create(void* parent, int x, int y, int w, int h);
    void QWidget_show(void*);
    void QWidget_setTitle(void*, const char* title);
    void* QPushButton_create(void* parent, const char* label);
    void QPushButton_setText(void*, const char* text);
    void* QLabel_create(void* parent, const char* text);
    void QLabel_setText(void*, const char* text);
  }
  ```
- [ ] Kompiliere als `libqtlyx.so`
- [ ] `std/qt5_widgets.lyx` - Lyx FFI Bindings

### WP4: Erweiterte Widgets (Phase 4)
- [ ] QLineEdit, QTextEdit
- [ ] QMainWindow, QDialog
- [ ] Layouts: QVBoxLayout, QHBoxLayout
- [ ] Signal/Slot Callback-Registry

### WP5: Application & Event Loop (Phase 5)
- [ ] `QApplication` Singleton
- [ ] Lyx main() → QApplication.exec()
- [ ] Exit-Handler für sauberes Shutdown

---

## Open Questions

1. **OpenGL-only starten?** 
   - Problem: Keine UI-Elemente (Buttons, Labels)
   - Pro: Simpler, schnell umsetzbar
   - Contra: Nicht vollständig

2. **QML/Qt Quick statt Widgets?**
   - QML hat bessere C-API (QQmlEngine, QQmlComponent)
   - Aber: QML ist eigenständige Sprache, nicht Lyx
   - Bleibt bei Widgets

3. **Qt Version?**
   - Qt5: Stabil, Libs verfügbar
   - Qt6: Weniger Libs in Distros

---

## Referenz: Lyx FFI Pattern

Aus `std/net/tls.lyx`:
```lyx
// OpenSSL Funktionen
extern fn SSL_new(ctx: int64): int64 link "libssl.so.3";

// Opaque Pointer Wrapper
pub type TLSContext = struct {
  ctx: int64;           // SSL_CTX* pointer
  initialized: int64;  // 1 if successfully initialized
};

// High-level API
pub fn TLSInit(): TLSContext { ... }
```

→ Qt-Bindings folgen demselben Pattern!

---

## Build Dependencies

```bash
# Für C++ Wrapper (WP3)
sudo apt install qtbase5-dev

# Kompilieren des Wrappers
g++ -shared -fPIC -I/usr/include/qt5/QtCore \
    -I/usr/include/qt5/QtWidgets \
    qt_wrapper.cpp -o libqtlyx.so \
    -lQt5Core -lQt5Widgets -lQt5Gui
```

---

## Next Steps

1. **Entscheidung**: Mit OpenGL-only starten oder direkt C++ Wrapper?
2. **Design**: Welche Qt-Funktionen zuerst?
3. **Prototyp**: Minimaler Test mit bestehendem Lyx-FFI

---

## Referenzen

- Lyx FFI: `std/net/tls.lyx`, `std/net/ssh.lyx`
- Qt Docs: https://doc.qt.io/qt-5/
- Qt C++ → C Wrapper: https://wiki.lazarus.freepascal.org/Qt5_Interface