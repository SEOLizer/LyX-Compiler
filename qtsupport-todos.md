# Qt Support for Lyx - Implementation Plan

## Status: Research Phase Complete

## Research Findings (2026-04-12)

### Available Qt Bindings for FreePascal

| Binding | Status | Notes |
|---------|--------|-------|
| **libqt5pas** | ✅ Stable | Most widely available, mature |
| **libqt6pas** | ⚠️ Emerging | Less mature, fewer packages |
| Lazarus LCL Qt5 | ✅ Stable | Full widget set support |
| Lazarus LCL Qt6 | ⚠️ Beta | In development |

### Key Observations

1. **Qt5 is recommended** for production use
   - `libqt5pas` available in most Linux distros
   - Full widget set (QWidget, QMainWindow, QDialog)
   - Mature OpenGL integration via QOpenGLWidget

2. **Qt6 is emerging** but less mature
   - `qt6pas` is the corresponding binding
   - Wayland native support (no XWayland needed)
   - Fewer packages in distros

3. **OpenGL in Qt**:
   - QGLWidget (Qt5) / QGLWidget (Qt6) - obsolete
   - QOpenGLWidget - recommended replacement
   - Requires proper EGL/GLX setup on Wayland

4. **Wayland considerations**:
   - Qt5 on Wayland requires XWayland for OpenGL
   - Qt6 has native Wayland support

---

## Implementation Work Packages

### WP1: Dependency Management
- [ ] Add `libqt5pas` package detection to Lyx build system
- [ ] Document required system packages (Debian: `libqt5pas`, Arch: `qt5-base` with pascal bindings)
- [ ] Create optional dependency flag for Qt support

### WP2: Basic Qt Integration (Phase 1)
- [ ] Create `std/qt5.lyx` wrapper unit
  - Initialize/QFinalize Qt application
  - Basic QApplication singleton
  - Event loop integration with Lyx runtime
- [ ] Test minimal Qt5 app from Lyx

### WP3: Widget System (Phase 2)
- [ ] Implement QWidget wrappers
  - QLabel, QPushButton, QLineEdit, QTextEdit
  - QMainWindow, QDialog
- [ ] Create signal/slot mechanism for Lyx
- [ ] Layout system (QVBoxLayout, QHBoxLayout, QGridLayout)

### WP4: Graphics & OpenGL (Phase 3)
- [ ] QPainter support for 2D graphics
- [ ] QOpenGLWidget integration
- [ ] Shader program helpers
- [ ] Texture management utilities

### WP5: Advanced Widgets (Phase 4)
- [ ] QTableWidget, QTreeWidget
- [ ] QMenuBar, QToolBar, QStatusBar
- [ ] QDockWidget
- [ ] QTabWidget, QSplitter

---

## Open Questions

1. **Integration approach**: Should Qt be a std unit or a separate library?
   - Pro std: auto-import, familiar usage
   - Pro separate: lighter binaries when not needed

2. **Event loop**: How to integrate Qt event loop with Lyx runtime?
   - Option A: Qt owns main loop, Lyx registers callbacks
   - Option B: Lyx owns loop, Qt uses processEvents()

3. **Memory management**: Qt uses parent-child ownership model
   - Lyx has no classes yet - should we add class support first?
   - Or use manual delete with RAII pattern

4. **String handling**: Qt uses QString, Lyx uses pchar
   - Need conversion layer ( QString → pchar for display strings)

---

## Dependencies to Install (for testing)

```bash
# Debian/Ubuntu
sudo apt install libqt5pas libqt5xmlpatterns

# Arch Linux
sudo pacman -S qt5-base

# Fedora
sudo dnf install qt5-qtbase qt5-qtbase-common
```

---

## Next Steps

1. **Decision needed**: Qt5 or Qt6 for initial implementation?
2. **Architecture decision**: Event loop integration approach
3. **Priority**: Is Qt support high priority vs other std units?

---

## References

- Lazarus Qt5: https://wiki.lazarus.freepascal.org/Qt5
- libqt5pas: https://github.com/davidbannon/libqt5pas
- Qt6 pascal: https://github.com/davidbannon/qt6pas