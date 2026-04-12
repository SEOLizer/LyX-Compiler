# Qt Support for Lyx - Implementation Plan

## ✅ WP1: Qt Core/OpenGL/EGL/GLX FFI (COMPLETED)

### std Units Created
- `std/x11.lyx` - X11 Window system (WORKS!)
- `std/qt5_core.lyx` - Qt Core + timerfd QTimer
- `std/qt5_gl.lyx` - OpenGL 2.1 bindings
- `std/qt5_glx.lyx` - GLX 1.4 bindings
- `std/qt5_egl.lyx` - EGL 1.4 bindings

---

## WP2: GLX/EGL Issue - ROOT CAUSE FOUND 🔍

### Problem Statement
Direct `extern fn ... link "libGL.so.1"` causes crash, but:
- `extern fn ... link "libX11.so.6"` WORKS
- `dlopen/dlsym("libGL.so.1")` WORKS

### Root Cause
Some libraries (libGL, libEGL, libdl) crash when called via **compile-time PLT** (the `link` mechanism), but work via **runtime dynamic loading** (dlopen/dlsym).

This is a Lyx compiler/backend issue with how PLT entries are resolved for certain shared libraries.

### Working Workaround
Use dlopen/dlsym instead of direct extern declarations:

```lyx
// WORKS (workaround):
extern fn dlopen(filename: pchar, flags: int64): int64 link "libdl.so.2";
extern fn dlsym(handle: int64, symbol: pchar): int64 link "libdl.so.2";
var handle: int64 := dlopen("libGL.so.1", 1);
var glXChooseVisual: int64 := dlsym(handle, "glXChooseVisual");

// CRASHES (direct extern):
extern fn glXChooseVisual(dpy, screen, attrib): int64 link "libGL.so.1";
```

### Affected Libraries (crash via direct extern)
- libGL.so.1
- libEGL.so.1  
- libdl.so.2

### Working Libraries
- libX11.so.6
- libc.so.6
- libm.so.6
- libpthread.so.0
- libnsl.so.1
- libresolv.so.2

---

## Next Steps

### Option A: Workaround via dlsym (recommended)
Create wrapper functions that use dlopen/dlsym for problematic libraries:
```lyx
pub fn glXChooseVisual(dpy, screen, attrib): int64 {
  // Load libGL.so.1 if not already loaded
  // Use dlsym to get function pointer
  // Call via function pointer
}
```

### Option B: Fix in Lyx compiler
Investigate why PLT resolution works for some libs but not others.
This is likely in the dynamic linking code generation.

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