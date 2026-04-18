# Qt Support for Lyx - Implementation Plan

> **Status**: Active Development | **Branch**: `feat/qt-support`

---

## Übersicht

Dieses Dokument beschreibt den Fahrplan für die vollständige Qt5-Integration in Lyx.
Ziel ist es, eine productive Desktop-GUI-Programmierung mit Lyx zu ermöglichen.

### Aktueller Stand (v0.8.1)
- ✅ Basis-Fenster (QMainWindow) mit Label und StatusBar
- ✅ Event-Loop und Prozess-Events
- ✅ QPushButton (Basis)
- ✅ Screen-Informationen

### Fehlende Kern-Features
- ❌ Weitere Widgets (QLineEdit, QTextEdit, etc.)
- ❌ Layout-Manager
- ❌ Signals/Slots Callbacks
- ❌ QTimer
- ❌ Menus und Toolbars

---

## Work Packages

### WP1: Qt Core/OpenGL/EGL/GLX FFI ✅ COMPLETED

**Zeitraum**: Abgeschlossen

**Deliverables**:
- `std/x11.lyx` - X11 Window system
- `std/qt5_core.lyx` - Qt Core + timerfd QTimer
- `std/qt5_gl.lyx` - OpenGL 2.1 bindings
- `std/qt5_glx.lyx` - GLX 1.4 bindings
- `std/qt5_egl.lyx` - EGL 1.4 bindings

---

### WP2: PLT Dynamic Linking Fixed ✅ COMPLETED

**Zeitraum**: Abgeschlossen

**Bugs behoben**:
1. Stack misalignment (x86-64 ABI violation) - behoben
2. RWX code segment caused dlopen rejection - behoben

**Ergebnis**: Alle shared libraries funktionieren via PLT

---

### WP3: Qt5 Window Basis ✅ COMPLETED

**Zeitraum**: Abgeschlossen

**Deliverables**:
- `qt_wrapper/qt_wrapper.cpp` - C++ Qt5 Widgets Wrapper mit C ABI
- `qt_wrapper/Makefile` - Build-System für libqtlyx.so
- `std/qt5_app.lyx` - Lyx FFI Unit
- `examples/graphics/hello_qt.lyx` - Hello World Beispiel

---

### WP4: Erweiterte Widgets

**Ziel**: Grundlegende Qt-Widgets für Benutzerinteraktion

#### WP4.1: Eingabe-Widgets

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Einzeilen-Text | QLineEdit | `qt_lineedit_create()` | ❌ TODO |
| Mehrzeilen-Text | QTextEdit | `qt_textedit_create()` | ❌ TODO |
| Passwort-Feld | QLineEdit (EchoMode) | `qt_lineedit_set_echo()` | ❌ TODO |
| SpinBox | QSpinBox | `qt_spinbox_create()` | ❌ TODO |
| DoubleSpinBox | QDoubleSpinBox | `qt_doublespinbox_create()` | ❌ TODO |
| Slider | QSlider | `qt_slider_create()` | ❌ TODO |
| Dial | QDial | `qt_dial_create()` | ❌ TODO |

#### WP4.2: Auswahl-Widgets

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| CheckBox | QCheckBox | `qt_checkbox_create()` | ❌ TODO |
| RadioButton | QRadioButton | `qt_radiobutton_create()` | ❌ TODO |
| ComboBox | QComboBox | `qt_combobox_create()` | ❌ TODO |
| PushButton | QPushButton | `qt_add_button()` | ✅ DONE |

#### WP4.3: Anzeige-Widgets

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Label | QLabel | `qt_set_label()` | ✅ DONE |
| ProgressBar | QProgressBar | `qt_progressbar_create()` | ❌ TODO |
| ListWidget | QListWidget | `qt_listwidget_create()` | ❌ TODO |

---

### WP5: Layout-Manager

**Ziel**: Flexible GUI-Layouts

| Layout | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Vertikal | QVBoxLayout | `qt_vbox_create()` | ❌ TODO |
| Horizontal | QHBoxLayout | `qt_hbox_create()` | ❌ TODO |
| Grid | QGridLayout | `qt_grid_create()` | ❌ TODO |
| Stack | QStackedLayout | `qt_stacked_create()` | ❌ TODO |
| Splitter | QSplitter | `qt_splitter_create()` | ❌ TODO |

**API-Design**:
```lyx
// Beispiel: Vertikales Layout
var vbox: int64 := qt_vbox_create();
qt_vbox_add_widget(vbox, label);
qt_vbox_add_widget(vbox, button);
qt_vbox_add_layout(vbox, hbox);
qt_window_set_layout(window, vbox);
```

---

### WP6: Signals/Slots Callback-System

**Ziel**: Event-Handling für Benutzerinteraktionen

#### Challenge
Qt's Signals/Slots basieren auf MOC (Meta-Object Compiler), der C++-Code generiert.
Lyx kann das nicht direkt nutzen.

#### Lösung: Callback-Registry Pattern

1. **Event-Handler registrieren** (in Lyx):
```lyx
// Callback-Typ definieren
type Callback := fn(button: int64);

// Handler implementieren
fn on_click(btn: int64) {
  PrintStr("Button clicked!\n");
}

// Bei Qt-Objekt registrieren
qt_button_on_clicked(button, on_click);
```

2. **Wrapper implementiert** (in C++):
```cpp
// Global registry of Lyx callbacks
std::map<int64, std::function<void()>> g_callbacks;

extern "C" long long _qt_button_on_clicked(long long button, long long callback_ptr) {
    // Connect to Qt signal, call Lyx callback when triggered
    QObject::connect(button, &QPushButton::clicked, [callback_ptr]() {
        ((void(*)())callback_ptr)();
    });
    return 0;
}
```

#### Zu implementierende Callbacks

| Event | Qt Signal | Lyx-Funktion | Status |
|-------|-----------|--------------|--------|
| Button clicked | clicked() | `qt_button_on_clicked()` | ❌ TODO |
| Button pressed | pressed() | `qt_button_on_pressed()` | ❌ TODO |
| Button released | released() | `qt_button_on_released()` | ❌ TODO |
| LineEdit textChanged | textChanged(QString) | `qt_lineedit_on_textchanged()` | ❌ TODO |
| LineEdit returnPressed | returnPressed() | `qt_lineedit_on_returnpressed()` | ❌ TODO |
| CheckBox toggled | toggled(bool) | `qt_checkbox_on_toggled()` | ❌ TODO |
| Slider valueChanged | valueChanged(int) | `qt_slider_on_valuechanged()` | ❌ TODO |
| Timer timeout | timeout() | `qt_timer_on_timeout()` | ❌ TODO |

---

### WP7: QTimer Unterstützung

**Ziel**: Periodische Tasks und Animationen

```lyx
// Timer erstellen (1000ms Intervall)
var timer: int64 := qt_timer_create(1000);

// Callback registrieren
fn tick() {
  PrintStr("Timer tick!\n");
}
qt_timer_on_timeout(timer, tick);

// Timer starten
qt_timer_start(timer);

// ... event loop ...
qt_timer_stop(timer);
```

**C++ API**:
```cpp
extern "C" long long _qt_timer_create(long long interval_ms);
extern "C" long long _qt_timer_start(long long timer);
extern "C" long long _qt_timer_stop(long long timer);
extern "C" long long _qt_timer_delete(long long timer);
extern "C" long long _qt_timer_on_timeout(long long timer, long long callback);
```

---

### WP8: Menus und Toolbars

**Ziel**: Anwendung-Menüs und Toolbars

| Element | Qt-Klasse | Lyx-Funktion | Status |
|---------|-----------|--------------|--------|
| MenuBar | QMenuBar | `qt_menubar_create()` | ❌ TODO |
| Menu | QMenu | `qt_menu_create()` | ❌ TODO |
| Action | QAction | `qt_action_create()` | ❌ TODO |
| Toolbar | QToolBar | `qt_toolbar_create()` | ❌ TODO |

```lyx
var menubar: int64 := qt_menubar_create(window);
var file_menu: int64 := qt_menu_create("File");
var exit_action: int64 := qt_action_create("Exit", on_exit);
qt_menu_add_action(file_menu, exit_action);
qt_menubar_add_menu(menubar, file_menu);
```

---

### WP9: Standard-Dialoge

**Ziel**: Vordefinierte Dialoge für häufige Tasks

| Dialog | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Message Box | QMessageBox | `qt_msgbox_show()` | ❌ TODO |
| Input Dialog | QInputDialog | `qt_inputdialog_get_text()` | ❌ TODO |
| File Open | QFileDialog::getOpenFileName | `qt_file_open_dialog()` | ❌ TODO |
| File Save | QFileDialog::getSaveFileName | `qt_file_save_dialog()` | ❌ TODO |
| Color Picker | QColorDialog | `qt_color_dialog()` | ❌ TODO |
| Font Picker | QFontDialog | `qt_font_dialog()` | ❌ TODO |

---

### WP10: Graphics View (2D)

**Ziel**: 2D-Grafiken und Custom Painting

| Feature | Qt-Klasse | Lyx-Funktion | Status |
|---------|-----------|--------------|--------|
| Paint Device | QPixmap/QImage | `qt_pixmap_create()` | ❌ TODO |
| Painter | QPainter | `qt_painter_begin()` | ❌ TODO |
| Draw Line | QPainter::drawLine | `qt_painter_draw_line()` | ❌ TODO |
| Draw Rect | QPainter::drawRect | `qt_painter_draw_rect()` | ❌ TODO |
| Draw Ellipse | QPainter::drawEllipse | `qt_painter_draw_ellipse()` | ❌ TODO |
| Draw Text | QPainter::drawText | `qt_painter_draw_text()` | ❌ TODO |
| Fill | QPainter::fillRect | `qt_painter_fill()` | ❌ TODO |

---

## Priorisierung

### Phase 1: Produktiv (Sofort)
1. WP4.1 - Eingabe-Widgets (QLineEdit, QSpinBox)
2. WP6 - Callbacks (klickbar machen)
3. WP7 - QTimer

### Phase 2: Layout & Struktur
4. WP5 - Layout-Manager
5. WP8 - Menus/Toolbars

### Phase 3: Erweitert
6. WP4.2/4.3 - Weitere Widgets
7. WP9 - Standard-Dialoge

### Phase 4: Graphics (Zukunft)
8. WP10 - 2D Graphics

---

## Build & Deployment

### qt_wrapper bauen
```bash
cd qt_wrapper
make        # → libqtlyx.so
sudo make install  # → /usr/local/lib/
```

### Im Projekt nutzen
```bash
# Entweder: LD_LIBRARY_PATH setzen
LD_LIBRARY_PATH=qt_wrapper ./myapp

# Oder: Systemweit installiert (sudo make install)
./myapp
```

---

## Test-Strategie

Jedes WP enthält:
1. **Unit-Tests**: Einzelne Widget-Funktionen
2. **Integrationstest**: Kombination mehrerer Widgets
3. **Beispiel-Programm**: `examples/graphics/qt_*.lyx`

```bash
# Alle Qt-Tests kompilieren
for f in examples/graphics/qt_*.lyx; do
  lyxc "$f" -o "/tmp/$(basename $f)"
done
```

---

## Technische Notes

### Warum C++ Wrapper?
- Qt basiert auf C++ mit MOC (Meta-Object Compiler)
- MOC generiert Code für Signals/Slots, Property-System
- Wrapper mit C ABI ermöglicht FFI aus Lyx

### Memory Management
- Qt-Objekte werden als `int64` Handles (Pointer) behandelt
- `qt_close()` oder `qt_delete()` gibt Speicher frei
- Lyx-seitig: nur Handle speichern, nicht direkt auf Objekte zugreifen

### Threading
- Qt-GUI muss im Haupt-Thread laufen
- QTimer + Event-Loop für asynchrone Tasks
- Future: QThread für Hintergrund-Processing (WPX)

---

## Commit-Log (bisher)

```
7c12e09 feat(qt): Qt5 window support - 3 bugs fixed, hello_qt works
b151ed9 docs(qt): mark WP2 PLT fixes complete
e46b9dc fix(plt): fix two ELF dynamic linking bugs enabling libGL/libEGL via PLT
6320b52 feat(std): Qt/OpenGL/EGL/GLX/X11 FFI units - X11 works, GLX/EGL issue found
4ccd57b test(graphics): add working X11 test with direct extern declarations
```

---

## Offene Fragen

1. **Callbacks via Funktions-Pointer**: Funktioniert das zuverlässig mit Lyx-Calling-Convention?
2. **String-Konvertierung**: Qt verwendet QString, Lyx verwendet pchar. Wie am besten konvertieren?
3. **Object-Ownership**: Wer ist für das Löschen von Qt-Objekten verantwortlich?

---

*Letzte Aktualisierung: 2026-04-18*