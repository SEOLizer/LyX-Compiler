# Qt Support for Lyx - Implementation Plan

## ✅ WP1: Qt Core/OpenGL/EGL/GLX FFI (COMPLETED)

### std Units Created
- `std/x11.lyx` - X11 Window system (WORKS!)
- `std/qt5_core.lyx` - Qt Core + timerfd QTimer
- `std/qt5_gl.lyx` - OpenGL 2.1 bindings
- `std/qt5_glx.lyx` - GLX 1.4 bindings
- `std/qt5_egl.lyx` - EGL 1.4 bindings

---

## ✅ WP2: PLT Dynamic Linking Fixed (COMPLETED)

### Root Causes Found and Fixed

**Bug 1: Stack misalignment (x86-64 ABI violation)**
- x86-64 ABI requires RSP = 0 mod 16 before any CALL instruction
- After `push rbp`, RSP = 8 mod 16, so frame size N must be 8 mod 16
- The compiler was using frame sizes where totalSlots was even (N = 0 mod 16)
- This caused `movdqa` to crash inside glibc's `_dl_map_object_from_fd`
- **Fix**: if `totalSlots` is even, increment it (ensures N = 8 mod 16)

**Bug 2: RWX code segment caused dlopen rejection**
- `_lyx_argv_base` (stores initial RSP) was embedded in the code section
- Required PF_W on the code segment for dynamic ELF
- glibc's dlopen rejects/crashes on RWX code segments
- **Fix**: moved `_lyx_argv_base` to FData (always RW); code segment stays PF_R|PF_X

### Result
All shared libraries now work via compile-time PLT:
- libGL.so.1 ✅ (glXQueryVersion, glXChooseVisual, etc.)
- libX11.so.6 ✅
- libdl.so.2 ✅ (dlopen, dlclose)
- libEGL.so.1 (not tested yet)

---

## Test Programs Created
- `examples/graphics/x11_direct.lyx` - Working X11 test ✅
- `examples/graphics/dlopen_test.lyx` - dlopen wrapper ✅
- `examples/graphics/egl_test.lyx` - EGL (needs workaround) ⚠️

---

---

## ✅ WP3: Qt5 Window Support (COMPLETED)

### Files Created
- `qt_wrapper/qt_wrapper.cpp` — C++ Qt5 Widgets wrapper with C ABI (functions named `_qt_xxx`)
- `qt_wrapper/Makefile` — builds `libqtlyx.so`
- `std/qt5_app.lyx` — unit with `extern fn _qt_xxx` + `pub fn qt_xxx` wrapper pattern
- `examples/graphics/hello_qt.lyx` — Qt5 hello world: window, label, status bar

### 3 Additional Bugs Fixed

**Bug 1: `extern fn` in imported units not generating PLT stubs**
- `LowerImportedUnits` added extern fn to `FImportedFuncs` instead of `FExternFuncs`
- Fix: detect `IsExtern` in phase 2, route to `FExternFuncs` + `RegisterExternLibrary`

**Bug 2: `_start` `push rbp` breaks x86-64 ABI alignment**
- `_start` did `push rbp; call main` → main entered with RSP = 0 mod 16 (wrong)
- ABI requires RSP = 8 mod 16 at function entry
- Fix: remove `push rbp` from `_start` — it's not a function, no frame needed

**Bug 3: `totalSlots` parity inverted (masked by Bug 2)**
- Previous fix forced odd totalSlots to compensate Bug 2's off-by-8
- Now that `_start` is correct, totalSlots must be EVEN (N*8 = 0 mod 16)
- Fix: change parity check from `(= 0)` to `(= 1)`

### Result
- `LD_LIBRARY_PATH=qt_wrapper ./hello_qt` opens a 640×480 Qt5 window ✅
- All existing programs (return42, dlopen, x11_direct) still work ✅

## Commit Log
```
7c12e09 feat(qt): Qt5 window support - 3 bugs fixed, hello_qt works
b151ed9 docs(qt): mark WP2 PLT fixes complete
e46b9dc fix(plt): fix two ELF dynamic linking bugs enabling libGL/libEGL via PLT
6320b52 feat(std): Qt/OpenGL/EGL/GLX/X11 FFI units - X11 works, GLX/EGL issue found
4ccd57b test(graphics): add working X11 test with direct extern declarations
```