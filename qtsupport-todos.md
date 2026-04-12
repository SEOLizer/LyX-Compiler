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

---

## 🔄 WP2: Test mit OpenGL Window (NEXT)

### Schritte:
1. **X11 Display öffnen** - braucht std.x11 (oder via libc Xlib)
2. **GLX Context erstellen** - via std.qt5_glx
3. **OpenGL Rendering testen** - via std.qt5_gl
4. **Swap Buffers** - via glXSwapBuffers

### Alternativ (Wayland):
1. **EGL Display** - via std.qt5_egl
2. **Wayland Window** - braucht std.wayland
3. **OpenGL Rendering** - via std.qt5_gl
4. **eglSwapBuffers** - present frame

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

### WP4: Erweiterte Widgets
- QLineEdit, QTextEdit
- QMainWindow, QDialog
- Layouts: QVBoxLayout, QHBoxLayout
- Signal/Slot Callback-Registry

### WP5: Application & Event Loop
- QApplication Singleton
- Lyx main() → QApplication.exec()
- Exit-Handler

---

## ⚠️ Wichtig

| Komponente | FFI-Typ | Status |
|------------|---------|--------|
| OpenGL (gl*) | C-FFI | ✅ |
| EGL | C-FFI | ✅ |
| GLX | C-FFI | ✅ |
| Qt Core (qVersion, env) | C-FFI | ✅ |
| QTimer (timerfd) | C-FFI | ✅ |
| Qt Widgets (QWidget) | C++ Wrapper | ❌ Braucht |
| QApplication | C++ Wrapper | ❌ Braucht |
| QString | C++ Wrapper | ❌ Braucht |

---

## Build Dependencies

```bash
# OpenGL/EGL
sudo apt install libgl1-mesa-dev libegl1-mesa-dev

# Für C++ Wrapper (WP3)
sudo apt install qtbase5-dev

# Kompilieren des Wrappers (später)
g++ -shared -fPIC -I/usr/include/qt5/QtCore \
    -I/usr/include/qt5/QtWidgets \
    qt_wrapper.cpp -o libqtlyx.so \
    -lQt5Core -lQt5Widgets -lQt5Gui
```

---

## Referenzen

- Lyx FFI: `std/net/tls.lyx`, `std/net/ssh.lyx`
- Qt Docs: https://doc.qt.io/qt-5/
- Qt C++ → C Wrapper: https://wiki.lazarus.freepascal.org/Qt5_Interface
- Linux timerfd: `man timerfd_create`

---

## Commit Log

```
feat(std): add Qt5/OpenGL/EGL/GLX FFI binding units          (1a1be86)
feat(std): expand qt5_core.lyx - implement C-FFI functions    (5450171)
refactor(std): improve qt5_core documentation                 (7e8de6c)
docs(qt): revise Qt plan - Lyx FFI approach                  (620f542)
```