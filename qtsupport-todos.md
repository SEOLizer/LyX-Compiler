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

## Commit Log
```
6320b52 feat(std): Qt/OpenGL/EGL/GLX/X11 FFI units - X11 works, GLX/EGL issue found
4ccd57b test(graphics): add working X11 test with direct extern declarations
1170736 fix(std): resolve reserved keyword conflicts
c45fd4c docs(qt): update implementation plan - WP1 completed
7e8de6c refactor(std): improve qt5_core documentation
5450171 feat(std): expand qt5_core.lyx - implement C-FFI functions
1a1be86 feat(std): add Qt5/OpenGL/EGL/GLX FFI binding units
```