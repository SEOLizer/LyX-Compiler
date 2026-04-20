# Qt Support for Lyx - Implementation Plan

> **Status**: Active Development | **Branch**: `feat/qt-support` | **Version**: v0.8.2

---

## Übersicht

Dieses Dokument beschreibt den Fahrplan für die vollständige Qt5-Integration in Lyx.
Ziel ist es, eine productive Desktop-GUI-Programmierung mit Lyx zu ermöglichen.

### Bereits Implementiert (v0.8.2)
- ✅ `std/x11.lyx` - X11 Window system
- ✅ `std/qt5_core.lyx` - Qt Core + timerfd QTimer
- ✅ `std/qt5_app.lyx` - QApplication, QMainWindow
- ✅ `std/qt5_gl.lyx` - OpenGL 2.1 bindings
- ✅ `std/qt5_glx.lyx` - GLX 1.4 bindings
- ✅ `std/qt5_egl.lyx` - EGL 1.4 bindings
- ✅ QPushButton Basis-Funktionen
- ✅ QLabel Basis-Funktionen
- ✅ Event-Loop Basis
- ✅ Screen-Informationen

---

## Work Packages (Neu)

### WP-A: Grundlagen & Setup (✅ COMPLETED)

**Beschreibung**: X11/Qt5/OpenGL/EGL FFI Basis

| Unit | Status |
|------|--------|
| `std/x11.lyx` | ✅ |
| `std/qt5_core.lyx` | ✅ |
| `std/qt5_app.lyx` | ✅ |
| `std/qt5_gl.lyx` | ✅ |
| `std/qt5_glx.lyx` | ✅ |
| `std/qt5_egl.lyx` | ✅ |

**Bugs behoben**:
- Stack misalignment (x86-64 ABI violation)
- RWX code segment (dlopen rejection)

---

### WP-B: Fenster-Widget (✅ COMPLETED)

**Beschreibung**: QMainWindow mit Basis-Widgets

| Widget | Funktion | Status |
|--------|--------------|--------|
| QMainWindow | `qt_main_window_create()` | ✅ |
| QLabel | `qt_label_create()` | ✅ |
| QLabel (Text setzen) | `qt_label_set_text()` | ✅ |
| StatusBar | `qt_statusbar_create()` | ✅ |
| Event-Loop | `qt_exec()` | ✅ |

---

### WP-C: Buttons & Events (✅ COMPLETED)

**Beschreibung**: Button-Widgets mit Click-Events

| Widget | Funktion | Status |
|--------|--------------|--------|
| QPushButton | `qt_button_create()` | ✅ |
| QPushButton Click | `qt_button_on_clicked()` | ✅ |

---

### WP-D: Eingabe-Widgets (✅ COMPLETED)

**Beschreibung**: Grundlegende Benutzer-Eingabe

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Einzeilen-Text | QLineEdit | `qt_lineedit_create()` | ✅ |
| Passwort-Feld | QLineEdit (EchoMode) | `qt_lineedit_set_echo()` | ✅ |
| SpinBox | QSpinBox | `qt_spinbox_create()` | ✅ |
| DoubleSpinBox | QDoubleSpinBox | `qt_doublespinbox_create()` | ✅ |
| Mehrzeilen-Text | QTextEdit | `qt_textedit_create()` | ✅ |

---

### WP-E: Auswahl-Widgets (✅ COMPLETED)

**Beschreibung**: Auswahl-Elemente

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| CheckBox | QCheckBox | `qt_checkbox_create()` | ✅ |
| RadioButton | QRadioButton | `qt_radiobutton_create()` | ✅ |
| ComboBox | QComboBox | `qt_combobox_create()` | ✅ |
| PushButton | QPushButton | `qt_add_button()` | ✅ |

---

### WP-F: Anzeige-Widgets (✅ COMPLETED)

**Beschreibung**: Anzeige-Elemente

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Label | QLabel | `qt_set_label()` | ✅ |
| ProgressBar | QProgressBar | `qt_progressbar_create()` | ✅ |
| ListWidget | QListWidget | `qt_listwidget_create()` | ✅ |

---

### WP-G: Wert-Eingabe (Slider/Dial) (✅ COMPLETED)

**Beschreibung**: Wert-Eingabe via Slider/Dial

| Widget | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Slider | QSlider | `qt_slider_create()` | ✅ |
| Dial | QDial | `qt_dial_create()` | ✅ | |

---

### WP-H: Layout-Manager (✅ COMPLETED)

**Beschreibung**: Flexible GUI-Layouts

| Layout | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Vertikal | QVBoxLayout | `qt_vbox_create()` | ✅ |
| Horizontal | QHBoxLayout | `qt_hbox_create()` | ✅ |
| Grid | QGridLayout | `qt_grid_create()` | ✅ |
| Stack | QStackedLayout | `qt_stacked_create()` | 🟡 |
| Splitter | QSplitter | `qt_splitter_create()` | ✅ |

---

### WP-I: QTimer erweitert (✅ COMPLETED)

**Beschreibung**: Timer-Funktionalität erweitern

| Funktion | Status |
|--------------|--------|
| `qt_timer_create()` | ✅ |
| `qt_timer_start()` | ✅ |
| `qt_timer_stop()` | ✅ |
| `qt_timer_delete()` | ✅ |
| `qt_timer_on_timeout()` | ✅ |

---

### WP-J: Callbacks erweitern (✅ COMPLETED)

**Beschreibung**: Alle verfügbaren Event-Callbacks

| Event | Qt Signal | Lyx-Funktion | Status |
|-------|-----------|--------------|--------|
| Button clicked | clicked() | `qt_button_on_clicked()` | ✅ |
| Button pressed | pressed() | `qt_button_on_pressed()` | 🟡 |
| Button released | released() | `qt_button_on_released()` | 🟡 |
| LineEdit textChanged | textChanged(QString) | `qt_lineedit_was_changed()` | ✅ |
| LineEdit returnPressed | returnPressed() | `qt_lineedit_on_returnpressed()` | 🟡 |
| CheckBox toggled | toggled(bool) | `qt_checkbox_on_toggled()` | ✅ |
| Slider valueChanged | valueChanged(int) | `qt_slider_on_valuechanged()` | ✅ |

---

### WP-K: Menus & Toolbars (✅ COMPLETED)

**Beschreibung**: Anwendung-Menüs

| Element | Qt-Klasse | Lyx-Funktion | Status |
|---------|-----------|--------------|--------|
| MenuBar | QMenuBar | `qt_menubar_create()` | ✅ |
| Menu | QMenu | `qt_menu_create()` | ✅ |
| Action | QAction | `qt_action_create()` | ✅ |
| Toolbar | QToolBar | `qt_toolbar_create()` | ✅ |

---

### WP-L: Standard-Dialoge (✅ COMPLETED)

**Beschreibung**: Vordefinierte Dialoge

| Dialog | Qt-Klasse | Lyx-Funktion | Status |
|--------|-----------|--------------|--------|
| Message Box | QMessageBox | `qt_msgbox_show()` | ✅ |
| Input Dialog | QInputDialog | `qt_input_dialog()` | ✅ |
| File Open | QFileDialog::getOpenFileName | `qt_file_open_dialog()` | ✅ |
| File Save | QFileDialog::getSaveFileName | `qt_file_save_dialog()` | ✅ |
| Color Picker | QColorDialog | `qt_color_dialog()` | 🟡 |
| Font Picker | QFontDialog | `qt_font_dialog()` | 🟡 |

---

### WP-M: Graphics (2D) (✅ COMPLETED)

**Beschreibung**: Custom Painting

| Feature | Qt-Klasse | Lyx-Funktion | Status |
|---------|-----------|--------------|--------|
| Paint Device | QPixmap | `qt_pixmap_create()` | ✅ |
| Painter | QPainter | `qt_painter_begin()` | ✅ |
| Draw Line | QPainter::drawLine | `qt_painter_draw_line()` | ✅ |
| Draw Rect | QPainter::drawRect | `qt_painter_draw_rect()` | ✅ |
| Draw Ellipse | QPainter::drawEllipse | `qt_painter_draw_ellipse()` | ✅ |
| Draw Text | QPainter::drawText | `qt_painter_draw_text()` | ✅ |
| Fill | QPainter::fillRect | `qt_painter_fill_rect()` | ✅ |
| Color Picker | QColorDialog | `qt_color_dialog()` | 🟡 |
| Font Picker | QFontDialog | `qt_font_dialog()` | 🟡 |

---

## Phasen (Priorisierung)

### Phase 1: Kern ✅ COMPLETED
- WP-A: Grundlagen
- WP-B: Fenster
- WP-C: Buttons

### Phase 2: Kern II ✅ COMPLETED
- WP-D: Eingabe-Widgets ✅
- WP-E: Auswahl-Widgets ✅
- WP-F: Anzeige-Widgets ✅

### Phase 3: Layout ✅ COMPLETED
- WP-G: Slider/Dial ✅
- WP-I: QTimer erweitert ✅

### Phase 4: Callbacks ✅ COMPLETED
- WP-J: Callbacks erweitern ✅
- WP-K: Menus/Toolbars ✅

### Phase 5: Dialoge ✅ COMPLETED
- WP-L: Standard-Dialoge ✅

### Phase 6: Graphics ✅ COMPLETED
- WP-M: 2D Graphics ✅ (Color/Font Picker 🟡)

---

## Build & Deployment

```bash
# qt_wrapper bauen
cd qt_wrapper
make        # → libqtlyx.so
sudo make install  # → /usr/local/lib/

# Im Projekt nutzen
LD_LIBRARY_PATH=qt_wrapper ./myapp
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
- Future: QThread für Hintergrund-Processing

---

## Offene Fragen

1. **Callbacks via Funktions-Pointer**: Funktioniert das zuverlässig mit Lyx-Calling-Convention?
2. **String-Konvertierung**: Qt verwendet QString, Lyx verwendet pchar. Wie am besten konvertieren?
3. **Object-Ownership**: Wer ist für das Löschen von Qt-Objekten verantwortlich?

---

*Letzte Aktualisierung: 2026-04-19*
*Version: v0.8.2*