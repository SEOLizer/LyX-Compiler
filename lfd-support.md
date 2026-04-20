# Roadmap: LFD (LyX Form Description) Support

> **Status**: In Progress | **Version**: 0.2.0 | **Branch**: `feat/lfd-support`

---

## Projektziel

**LFD (LyX Form Description)** ist ein deklaratives, textbasiertes UI-Definitionsformat für den **FreePascal Lyx-Compiler**, das von Delphis DFM inspiriert ist und Qt-Widgets beschreibt.

Anders als die alte Konzeption (LyX Editor Integration) ist LFD nun ein **Code-Generator**: LFD → FreePascal Parser → AST → **C++ Qt-Code**.

### Kernmerkmale:
- **Deklarativ**: UI wird als strukturierter Text definiert
- **Textbasiert**: Speicherbar in .lyx Dateien, versionierbar
- **Code-Generierung**: Übersetzt LFD in C++/Qt-Quellcode
- **Layout-basiert**: Nutzt QVBoxLayout/QHBoxLayout statt absolute Koordinaten

### Beispiel:

```lyx
// LFD-Source (in .lyx Datei)
Form MainWindow "Hauptfenster" {
  Layout Vertical {
    Label lblTitle {
      Text: "Mein Formular"
    }
    Button btnOk {
      Text: "OK"
      OnClick: "handleOk()"
    }
  }
}
```

Wird zu C++/Qt-Code generiert:

```cpp
// Generiertes C++/Qt
#include <QApplication>
#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QPushButton>

class MainWindow : public QWidget {
public:
    MainWindow(QWidget* parent = nullptr) : QWidget(parent) {
        setWindowTitle("Hauptfenster");
        auto* layout = new QVBoxLayout(this);
        
        auto* lblTitle = new QLabel("Mein Formular", this);
        layout->addWidget(lblTitle);
        
        auto* btnOk = new QPushButton("OK", this);
        connect(btnOk, &QPushButton::clicked, this, &MainWindow::handleOk);
        layout->addWidget(btnOk);
        
        setLayout(layout);
    }
    
private slots:
    void handleOk() { /* ... */ }
};
```

---

## Architektur-Design

### Komponenten:

```
┌─────────────────────────────────────────────────────────────────┐
│                    LFD Text (.lyx)                             │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│               LFDParser (FreePascal)                            │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐│
│  │   Lexer    │→ │   Parser   │→ │  AST (UI Tree)          ││
│  └─────────────┘  └──────────────┘  └────────────────────────┘│
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              LFDCodeGen (FreePascal)                            │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐│
│  │ C++ Header  │  │ C++ Source   │  │  Signal/Slot Code       ││
│  └─────────────┘  └──────────────┘  └────────────────────────┘│
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│               C++/Qt Source Code                                │
│           (Kompiliert mit Qt-Framework)                         │
└─────────────────────────────────────────────────────────────────┘
```

### Datenfluss:

1. **Parsing**: LFD-Text → AST (UI Object Tree)
2. **Validierung**: AST-Checks (Typen, Properties, Zyklen)
3. **Code-Generierung**: AST → C++ Header + Source
4. **Kompilierung**: C++ → Qt-Widget-Binary

---

## Arbeitspakete (WPs)

### WP 1: Parser & AST (bereits implementiert)

> **Ziel**: Grammatik und Parser für LFD definieren

- [x] **Syntax-Definition**: Formale EBNF für das LFD-Format
- [x] Objekt-Blöcke (Form, Widget-Definitionen)
- [x] Properties (Text, Align, Style, etc.)
- [x] Layout-Direktiven (Vertical, Horizontal, Grid)
- [x] Verschachtelung von Widgets

- [x] **Lexer/Parser**: FreePascal Parser
- [x] Token-Erkennung (OBJ, PROPERTY, LAYOUT, etc.)
- [x] Hierarchie-Parsing (nesting)
- [x] Fehlerbehandlung bei ungültiger Syntax

**Status**: ✓ Abgeschlossen

---

### WP 2: AST-Erweiterung für UI-Elemente

> **Ziel**: AST-Knoten für Qt-Widgets erweitern

- [x] **Widget-AST-Knoten**: Neue Knotentypen für Qt-Widgets
  - [x] `TLfdForm` (Hauptfenster/Dialog)
  - [x] `TLfdWidget` (Basis für alle Widgets)
  - [x] `TLfdWidgetKind` Enum (Button, Label, Input, Combo, Checkbox, etc.)
  - [x] 20+ Qt-Widget-Typen definiert

- [x] **Layout-AST-Knoten**: Layout-Container
  - [x] `TLfdLayout`
  - [x] `TLfdLayoutKind` Enum (Vertical, Horizontal, Grid, Form)

- [x] **Property-AST-Knoten**: Erweiterte Properties
  - [x] `TLfdProperty` (Text, Enabled, Placeholder, etc.)
  - [x] `TLfdSignal` (OnClick, OnChanged, OnActivated, etc.)
  - [x] `TLfdSignalKind` Enum

- [ ] **Validation**: AST-Validierung
  - [ ] Zyklische Referenzen erkennen
  - [ ] Ungültige Widget-Kombinationen
  - [ ] Fehlende Pflicht-Properties

**Status**: ✓ Größtenteils abgeschlossen (nur Validierung fehlt)

**Deliverable**: `compiler/frontend/ast.pas` (erweitert)

---

### WP 3: C++ Qt Code-Generator

> **Ziel**: AST → C++/Qt Quellcode generieren

- [x] **Header-Generator**: Klassendefinitionen
  - [x] Form-Klasse (erbt von QWidget)
  - [x] Widget-Member-Variablen
  - [x] Slot-Deklarationen für Signal-Handler
  - [x] `Q_OBJECT` Makro

- [x] **Source-Generator**: Implementierung
  - [x] Konstruktor mit Layout-Aufbau
  - [x] Widget-Instanziierung
  - [x] Layout-Setup (addWidget, addLayout)
  - [x] Signal-Slot-Verbindungen (connect)

- [x] **Includes-Management**
  - [x] `#include <QWidget>` etc.
  - [x] `#include "ui_formname.h"`
  - [x] Automatische Include-Deduplizierung

- [x] **Naming-Convention**
  - [x] `FormName` → `class FormName : public QWidget`
  - [x] `btnOk` → `QPushButton* btnOk`
  - [x] `lblTitle` → `QLabel* lblTitle`

- [x] **Property-Support**
  - [x] Text, Placeholder, Enabled, Visible
  - [x] Checked (CheckBox, RadioButton)
  - [x] Title (GroupBox)
  - [x] ObjectName, Style
  - [x] Minimum, Maximum, Value (Slider, SpinBox)

**Status**: ✓ Abgeschlossen

**Deliverable**: `compiler/ir/lfd_codegen.pas`

---

### WP 4: Widget-Support

> **Ziel**: Unterstützung für Qt-Standard-Widgets

- [ ] **Basis-Widgets**
  - [ ] `QWidget` (generisches Widget)
  - [ ] `QLabel` (Text/Links/Bild)
  - [ ] `QPushButton`
  - [ ] `QCheckBox`
  - [ ] `QRadioButton`
  - [ ] `QLineEdit` (Input)
  - [ ] `QTextEdit` / `QPlainTextEdit`

- [ ] **Container-Widgets**
  - [ ] `QGroupBox`
  - [ ] `QTabWidget` (Tabs)
  - [ ] `QScrollArea`
  - [ ] `QStackedWidget`

- [ ] **Auswahl-Widgets**
  - [ ] `QComboBox`
  - [ ] `QListWidget`
  - [ ] `QTreeWidget`
  - [ ] `QTableWidget`

- [ ] **Fortschritt/Datum**
  - [ ] `QProgressBar`
  - [ ] `QSlider`
  - [ ] `QSpinBox`
  - [ ] `QDateEdit` / `QTimeEdit`

**Deliverable**: `std/lfd_widgets.pas` (Widget-Registry)

---

### WP 5: Layout-Generator

> **Ziel**: Qt-Layouts aus LFD-Layout-Blöcken generieren

- [ ] **QVBoxLayout**
  - [ ] Vertikale Anordnung
  - [ ] `addWidget()` für Widgets
  - [ ] `addStretch()` für Leerräume

- [ ] **QHBoxLayout**
  - [ ] Horizontale Anordnung
  - [ ] `addWidget()` für Widgets
  - [ ] `addStretch()` für Leerräume

- [ ] **QGridLayout**
  - [ ] Zeilen/Spalten-Positionierung
  - [ ] `addWidget(widget, row, col, rowSpan, colSpan)`
  - [ ] `setColumnStretch()`

- [ ] **QFormLayout**
  - [ ] Label-Field-Paare
  - [ ] Automatische Beschriftung

- [ ] **Nested Layouts**
  - [ ] Layouts in Layouts
  - [ ] Beliebige Verschachtelungstiefe

- [ ] **Layout-Properties**
  - [ ] `setSpacing(int)`
  - [ ] `setContentsMargins(int,int,int,int)`
  - [ ] `setStretch(int, int)`

**Deliverable**: `ir/lfd_layout.pas`

---

### WP 6: Signal & Event Handling

> **Ziel**: Interaktion zwischen Widgets und Code

- [ ] **Signal-Syntax**: LFD-Signale definieren
  - [ ] `OnClick: "methodName()"`
  - [ ] `OnChanged: "handleChanged()"`
  - [ ] `OnActivated: "handleSelect()"`

- [ ] **Signal-Generierung**: C++ connect() Calls
  - [ ] `connect(btn, &QPushButton::clicked, this, &Form::handler)`
  - [ ] Legacy: `connect(btn, SIGNAL(clicked()), SLOT(handler()))`

- [ ] **Handler-Signaturen**
  - [ ] `void handler()` (no params)
  - [ ] `void handler(bool)` (toggle)
  - [ ] `void handler(const QString&)` (text change)

- [ ] **Custom Slots**
  - [ ] User-defined slot Methoden generieren
  - [ ] Leere Methoden-Stubs für User-Implementierung

**Deliverable**: `ir/lfd_signals.pas`

---

### WP 7: Styling & Themes

> **Goal**: Qt Style Sheets Integration

- [ ] **Inline Styles**
  - [ ] `Style: "color: red; background: white"`
  - [ ] Generierung von `setStyleSheet()`

- [ ] **Stylesheet-Variablen**
  - [ ] `@primaryColor`, `@fontSize`, etc.
  - [ ] Theme-Dateien (.qss)

- [ ] **Object-Namen**
  - [ ] `setObjectName("btnOk")` für CSS-Selektoren

**Deliverable**: `ir/lfd_styling.pas`

---

### WP 8: Testing & Dokumentation

> **Ziel**: Produktionsreife sicherstellen

- [ ] **Unit-Tests**
  - [ ] Parser-Tests (gültige/ungültige Syntax)
  - [ ] Code-Generator Tests (Output-Verifikation)
  - [ ] Widget-Mapping Tests

- [ ] **Integration-Tests**
  - [ ] LFD → C++ → Kompilierung → Qt-App
  - [ ] Kompilierte Qt-Apps ausführen

- [ ] **Dokumentation**
  - [ ] Widget-Referenz
  - [ ] Property-Referenz
  - [ ] Beispiele

**Deliverable**: Test-Suite + Dokumentation

---

## Definition of Done

### Must-Have (WP 1-6):
- [x] Parser erkennt gültige LFD-Syntax
- [x] Parser zeigt klare Fehlermeldungen bei ungültiger Syntax
- [ ] C++/Qt-Code wird generiert (Header + Source)
- [ ] Mindestens 5 Qt-Widgets (Button, Label, Input, Combo, Checkbox)
- [ ] Layouts (Vertical, Horizontal) funktionieren
- [ ] Signal-Handler werden generiert

### Should-Have (WP 7-8):
- [ ] QSS-Styling funktioniert
- [ ] Alle 15+ Qt-Standard-Widgets unterstützt
- [ ] GridLayout funktioniert
- [ ] Dokumentation ist vollständig

### Nice-to-Have:
- [ ] Live-Preview (Qt-Designer-ähnlich)
- [ ] FormLayout
- [ ] TabWidget, GroupBox Support

---

## Technische Notes

### Zielplattform:
- **Linux x86_64** mit Qt 5.15+
- **Windows** mit Qt 5.15+ / Qt 6.x
- **macOS** mit Qt (optional)

### Abhängigkeiten:
- FreePascal 3.2.2+ (für Parser/Code-Gen)
- Qt 5.15+ (für generierten C++-Code)
- C++ Compiler (g++/clang++)

### Performance-Ziele:
- Parse-Zeit: < 5ms für typische Form (100 Zeilen)
- Code-Generierung: < 10ms für typische Form
- Generierter Code: Kompiliert in < 1s

### Sicherheit:
- Kein `eval()` von externem Code
- Input-Validierung vor Code-Generierung
- Keine Shell-Exec im generierten Code

---

## Offene Fragen

1. **Output-Format**: Nur C++ oder auch andere Sprachen?
   - *Empfehlung*: C++ für Qt, später Python für PyQt

2. **User-Code Integration**: Wo implementiert der User seine Handler?
   - *Vorschlag*: Separate .cpp Datei, LFD-Header inkludiert

3. **Form-Namen**: Vollständiger Klassenname oder nur Basis?
   - *Vorschlag*: `Form MeinDialog` → `class MeinDialog : public QWidget`

---

## Quick Start (nach Implementierung)

```bash
# LFD-Datei (.lyx) kompilieren
./lyxc myform.lyx -o myform

# Generierten C++-Code ansehen
cat myform.h
cat myform.cpp

# Mit Qt kompilieren
g++ -fPIC myform.cpp -o myform \
    -I/usr/include/qt5 -I/usr/include/qt5/QtWidgets \
    -lQt5Widgets -lQt5Core -lQt5Gui

# Starten
./myform
```

---

## Existierende Implementierung

Der Parser für WP1 befindet sich in:
- `compiler/frontend/` - Lexer/Parser (existierend)

**Zu erweiternde Dateien:**
- `frontend/ast.pas` - Neue AST-Knoten für UI
- `ir/` - Neue IR-Pässe für Code-Gen

---

*Erstellt: 2026-04-20*
*Letzte Aktualisierung: 2026-04-20*
*Version: 0.2.0 - Complete Overhaul*
