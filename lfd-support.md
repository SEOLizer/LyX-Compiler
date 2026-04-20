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

- [x] **Basis-Widgets** (bereits in lfd_codegen.pas)
  - [x] `QWidget` (generisches Widget)
  - [x] `QLabel` (Text/Links/Bild)
  - [x] `QPushButton`
  - [x] `QCheckBox`
  - [x] `QRadioButton`
  - [x] `QLineEdit` (Input)
  - [x] `QTextEdit` / `QPlainTextEdit`

- [x] **Container-Widgets**
  - [x] `QGroupBox`
  - [x] `QTabWidget` (Tabs)
  - [x] `QScrollArea`
  - [x] `QStackedWidget`

- [x] **Auswahl-Widgets**
  - [x] `QComboBox`
  - [x] `QListWidget`
  - [x] `QTreeWidget`
  - [x] `QTableWidget`

- [x] **Fortschritt/Datum**
  - [x] `QProgressBar`
  - [x] `QSlider`
  - [x] `QSpinBox`
  - [x] `QDateEdit` / `QTimeEdit`

- [ ] **Erweiterte Widget-Properties**
  - [ ] Tooltips
  - [ ] Icons (QIcon)
  - [ ] Shortcuts (QKeySequence)
  - [ ] Font-Settings

**Status**: ✓ Größtenteils abgeschlossen

**Deliverable**: `compiler/ir/lfd_codegen.pas` (Widget-Mapping)

---

### WP 5: Layout-Generator

> **Ziel**: Qt-Layouts aus LFD-Layout-Blöcken generieren

- [x] **QVBoxLayout**
  - [x] Vertikale Anordnung
  - [x] `addWidget()` für Widgets

- [x] **QHBoxLayout**
  - [x] Horizontale Anordnung
  - [x] `addWidget()` für Widgets

- [x] **QGridLayout**
  - [x] Zeilen/Spalten-Positionierung
  - [x] `addWidget(widget, row, col, rowSpan, colSpan)`

- [x] **QFormLayout**
  - [x] Label-Field-Paare
  - [x] Automatische Beschriftung

- [x] **Nested Layouts**
  - [x] Layouts in Layouts
  - [x] Beliebige Verschachtelungstiefe

- [x] **Layout-Properties**
  - [x] `setSpacing(int)`
  - [x] `setContentsMargins(int,int,int,int)` (partiell)
  - [x] `setStretch(int, int)` (partiell)

**Status**: ✓ Abgeschlossen

**Deliverable**: `compiler/ir/lfd_codegen.pas` (integriert)

---

### WP 6: Signal & Event Handling

> **Ziel**: Interaktion zwischen Widgets und Code

- [x] **Signal-Syntax**: LFD-Signale definieren
  - [x] `OnClick: "methodName()"`
  - [x] `OnChanged: "handleChanged()"`
  - [x] `OnActivated: "handleSelect()"`

- [x] **Signal-Generierung**: C++ connect() Calls
  - [x] `connect(btn, &QPushButton::clicked, this, &Form::handler)` (modern)
  - [x] Slots werden automatisch generiert

- [x] **Handler-Signaturen**
  - [x] `void handler()` (no params)
  - [x] `void handler(bool)` (toggle)
  - [x] `void handler(const QString&)` (text change)
  - [x] `void handler(int)` (activated)

- [x] **Custom Slots**
  - [x] Slot-Deklarationen in Header
  - [x] Leere Methoden-Stubs in Source

**Status**: ✓ Abgeschlossen

**Deliverable**: `compiler/ir/lfd_codegen.pas` (integriert)

---

### WP 7: Styling & Themes

> **Goal**: Qt Style Sheets Integration

- [x] **Inline Styles**
  - [x] `Style: "color: red; background: white"`
  - [x] Generierung von `setStyleSheet()`

- [x] **Font-Support**
  - [x] `FontSize: 12`
  - [x] `FontFamily: "Arial"`
  - [x] QFont-Objekt generiert

- [x] **Widget-Properties erweitert**
  - [x] `ToolTip: "Help text"`
  - [x] `Alignment: AlignLeft|Center|Right`
  - [x] `ReadOnly: true|false`
  - [x] `MaxLength: 100`
  - [x] `RowCount`, `ColumnCount`
  - [x] `Orientation: Horizontal|Vertical`
  - [x] `TickPosition`
  - [x] `Format` (ProgressBar)

- [x] **Object-Namen**
  - [x] `setObjectName("btnOk")` für CSS-Selektoren

**Status**: ✓ Abgeschlossen

**Deliverable**: `compiler/ir/lfd_codegen.pas` (erweitert)

---

### WP 8: Testing & Dokumentation

> **Ziel**: Produktionsreife sicherstellen

- [x] **Unit-Tests erstellt**
  - [x] Widget-Mapping Tests (lfd_codegen_test.lpr)
  - [x] Layout-Tests
  - [x] Signal-Mapping Tests
  - [x] Property-Generierung Tests
  - [x] Header/Source-Generierung Tests

- [ ] **Integration-Tests**
  - [ ] LFD → C++ → Kompilierung → Qt-App
  - [ ] Kompilierte Qt-Apps ausführen

- [x] **Dokumentation**
  - [x] Property-Referenz (in lfd_codegen.pas)
  - [x] Widget-Referenz (in lfd_codegen.pas)
  - [ ] Beispiele

**Status**: Größtenteils abgeschlossen (Integration-Tests fehlen)

**Deliverable**: `compiler/ir/lfd_codegen.pas`, Test-Dateien

---

## Definition of Done

### Must-Have (WP 1-6):
- [x] Parser erkennt gültige LFD-Syntax
- [x] Parser zeigt klare Fehlermeldungen bei ungültiger Syntax
- [x] C++/Qt-Code wird generiert (Header + Source)
- [x] Mindestens 5 Qt-Widgets (Button, Label, Input, Combo, Checkbox)
- [x] Layouts (Vertical, Horizontal) funktionieren
- [x] Signal-Handler werden generiert

### Should-Have (WP 7-8):
- [x] QSS-Styling funktioniert
- [x] Alle 15+ Qt-Standard-Widgets unterstützt
- [x] GridLayout funktioniert
- [ ] Dokumentation ist vollständig

### Nice-to-Have:
- [ ] Live-Preview (Qt-Designer-ähnlich)
- [x] FormLayout
- [x] TabWidget, GroupBox Support

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
