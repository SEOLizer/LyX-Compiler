# Roadmap: LyX Form Description (LFD) Support

> **Status**: Proposed | **Version**: 0.1.0 | **Branch**: `feat/lfd-support`

---

## Projektziel

**LFD (LyX Form Description)** ist ein deklaratives, textbasiertes UI-Definitionsformat für LyX, das von Delphis DFM inspiriert ist, aber moderne Qt-Layout-Konzepte verwendet.

### Kernmerkmale:
- **Deklarativ**: UI wird als strukturierter Text definiert, nicht interaktiv aufgebaut
- **Textbasiert**: Speicherbar in .lyx Dateien, versionierbar
- **Qt-fokussiert**: Übersetzt LFD in QWidget-Hierarchien
- **Layout-basiert**: Nutzt QVBoxLayout/QHBoxLayout statt absoluter Koordinaten

### Beispiel (angedacht):

```
Form MainWindow "Hauptfenster" {
  Layout Vertical {
    Label lblTitle {
      Text: "Mein Formular"
    }
    Button btnOk {
      Text: "OK"
      OnClick: "commit"
    }
    Button btnCancel {
      Text: "Abbrechen"
      OnClick: "cancel"
    }
  }
}
```

---

## Architektur-Design

### Komponenten:

```
┌─────────────────────────────────────────────────────────────────┐
│                      LFD Text (.lyx)                          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    LFDParser                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│  │   Lexer    │→ │   Parser   │→ │  AST (Object Tree)      │   │
│  └─────────────┘  └──────────────┘  └────────────────────────┘   │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                LFDWidgetFactory                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ QPushButton│  │  QLabel      │  │  Custom Widgets        │   │
│  └─────────────┘  └──────────────┘  └────────────────────────┘   │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│               QWidget Hierarchie                                │
│         (wird in LyX als Inset gerendert)                        │
└─────────────────────────────────────────────────────────────────┘
```

### Datenfluss:

1. **Parsing**: LFD-Text → AST (Abstract Syntax Tree)
2. **Factory**: AST → QWidget-Instanzen
3. **Layout**: Automatisches QLayout-Management
4. **Rendering**: QWidget in LyX-Inset einbetten
5. **Interaktion**: Signals → Lfun-Mapping

---

## Arbeitspakete (WPs)

### WP 1: Kern-Spezifikation & Parser

> **Ziel**: Grammatik und Parser für LFD definieren und implementieren

- [ ] **Syntax-Definition**: Formale EBNF für das LFD-Format
  - [ ] Objekt-Blöcke (Form, Widget-Definitionen)
  - [ ] Properties (Text, Align, Style, etc.)
  - [ ] Layout-Direktiven (Vertical, Horizontal, Grid)
  - [ ] Verschachtelung von Widgets

- [ ] **Lexer/Parser**: Implementierung eines LFD-Parsers
  - [ ] Token-Erkennung (OBJ, PROPERTY, LAYOUT, etc.)
  - [ ] Hierarchie-Parsing ( nesting )
  - [ ] Fehlerbehandlung bei ungültiger Syntax

- [ ] **Factory-Pattern**: Mapping von String-Namen auf Qt-Klassen
  - [ ] Registry für Widget-Typen (QPushButton → QAbstractButton)
  - [ ] Property-Mapping (Text → setText, Enabled → setEnabled)
  - [ ] Builder-Methode für jeden Widget-Typ

**Deliverable**: `std/lfd_parser.lyx` (oder C++ Parser in lyxkernel)

---

### WP 2: LyX-Inset Entwicklung

> **Ziel**: Integration von LFD in LyX als Inset

- [ ] **InsetLFD Klasse**: C++ Klasse in LyX-Kernel
  - [ ] Erbt von `Inset`
  - [ ] Überschreibt `draw()`, `edit()`, `validate()`
  - [ ] `getLfdCode()` und `setLfdCode()` Methoden

- [ ] **Serialisierung**: LFD in .lyx Dateien speichern/laden
  - [ ] LFD-Text als Buffer im Inset speichern
  - [ ] `\begin_inset LFD ... \end_inset` Syntax
  - [ ] Encoding-Handling (UTF-8)

- [ ] **UI-Dialog**: Einfacher Editor-Dialog
  - [ ] Text-Editor für LFD-Code
  - [ ] "Validate" Button (Syntax-Check)
  - [ ] "Preview" Button (Live-Rendering)

**Deliverable**: `InsetLFD.{cpp,h}` in lyxkernel

---

### WP 3: Visuelle Engine (Modernisierter DFM-Ansatz)

> **Ziel**: Rendering der LFD-UI in LyX

- [ ] **Layout-Auto-Generator**
  - [ ] `QVBoxLayout` generieren aus "Vertical" Block
  - [ ] `QHBoxLayout` generieren aus "Horizontal" Block  
  - [ ] `QGridLayout` generieren aus "Grid" Block
  - [ ] Verschachtelte Layouts

- [ ] **High-DPI Support**
  - [ ] Relative Einheiten (em, %)
  - [ ] Skalierung für Retina/HiDPI
  - [ ] DPI-aware Größenberechnung

- [ ] **Live-Vorschau**
  - [ ] QWidget in LyX-Arbeitsbereich einbetten
  - [ ] Update bei LFD-Änderungen
  - [ ] Maus-Event-Forwarding an Inset

**Deliverable**: `LfdRenderer` Komponente

---

### WP 4: Interaktion & Logik

> **Ziel**: Verbindung von UI-Events mit LyX-Funktionen

- [ ] **Signal-Mapping**: Syntax für Click/Toggle/Change Events
  - [ ] `OnClick: "insert-graphics"` (Lfun-Aufruf)
  - [ ] `OnChange: "buffer-toggle-read-only"` 
  - [ ] Multi-Handler support

- [ ] **Lfun-Binding**
  - [ ] Mapping von Signal-Namen zu Lfun-Strings
  - [ ] Argument-Übergabe (`OnClick: "custom arg"`)
  - [ ] Async-Handling (buffer-... commands)

- [ ] **Data Binding** (Optional)
  - [ ] Dokument-Variablen lesen/schreiben
  - [ ] `Bind: "variable=meineVariable"`

**Deliverable**: `LfdSignals` Modul

---

### WP 5: Styling & Themes

> **Ziel**: Qt Style Sheets Integration in LFD

- [ ] **QSS Support**
  - [ ] `Style { ... }` Block in LFD
  - [ ] CSS-ähnliche Syntax
  - [ ] Inline-Styles pro Widget

- [ ] **Theme-Management**
  - [ ] Vordefinierte Themes (Dark/Light)
  - [ ] Theme-Wechsel zur Laufzeit

- [ ] **Custom Properties**
  - [ ] `[custom]` Section für erweiterte Qt-Properties
  - [ ] ToolTips, Icons, Shortcuts

**Deliverable**: `LfdStyler` Komponente

---

### WP 6: Dokumentation & Testing

> **Ziel**: Produktionsreife sicherstellen

- [ ] **Referenz-Guide**: Vollständige Widget-Dokumentation
  - [ ] Alle unterstützten Qt-Widgets
  - [ ] Property-Referenz
  - [ ] Beispiele

- [ ] **Unit-Tests**
  - [ ] Parser-Tests (gültige/ungültige Syntax)
  - [ ] Widget-Factory Tests
  - [ ] Rendering-Tests
  - [ ] Signal-Handling Tests

- [ ] **Performance-Tests**
  - [ ] Parse-Geschwindigkeit (< 10ms für typische Forms)
  - [ ] Rendering-Latenz

**Deliverable**: Test-Suite + Dokumentation

---

## Definition of Done

Das Projekt gilt als **stabil** wenn folgende Kriterien erfüllt sind:

### Must-Have (WP 1-4):
- [ ] Parser erkennt gültige LFD-Syntax
- [ ] Parser zeigt klare Fehlermeldungen bei ungültiger Syntax
- [ ] Mindestens 5 Qt-Widgets (Button, Label, Input, Combo, Checkbox) funktionieren
- [ ] LFD-Inset wird in .lyx Dateien gespeichert und geladen
- [ ] Einfache Live-Vorschau (statisch) funktioniert
- [ ] Mindestens ein Signal (OnClick) kann eine Lfun auslösen

### Should-Have (WP 5-6):
- [ ] QSS-Styling funktioniert
- [ ] Alle 15+ Qt-Standard-Widgets unterstützt
- [ ] Dokumentation ist vollständig
- [ ] 80%+ Test-Abdeckung

### Nice-to-Have:
- [ ] Data Binding
- [ ] Live-Rendering bei Tastatureingaben
- [ ] Theme-Wechsel

---

## Technische Notes

### Qt-Version:
- Target: Qt 5.15+ (oder Qt 6.x mit Compatibility Layer)
- Benötigt: QtWidgets, QtCore

### Abhängigkeiten:
- `libqtlyx.so` (bereits vorhanden)
- Keine neuen externen Libraries

### Performance-Ziele:
- Parse-Zeit: < 5ms für typische Form (100 Zeilen)
- Render-Zeit: < 20ms für einfache Forms
- Memory-Footprint: < 1MB pro Form-Instanz

### Sicherheit:
- Kein `eval()` von externem Code
- Sandboxed Qt-Rendering (QScrollArea)
- Input-Validierung vor Widget-Erstellung

---

## Offene Fragen

1. **Widget-Library**: Sollen wir QtWidgets oder QtQml verwenden?
   - *Empfehlung*: QtWidgets für einfache Integration mit bestehendem Code

2. **Versionierung**: Wie gehen wir mit LFD-Schema-Änderungen um?
   - *Vorschlag*: Version-Header in jeder LFD-Datei (`Format: "LFD v1.0"`)

3. **Custom-Widgets**: Sollen Dritte eigene Widgets registrieren können?
   - *Vorschlag*: Ja, via `.lyxrc` Registry

---

## Quick Start (nach Implementierung)

```lyx
\begin_inset LFD
Form MeinDialog {
  Layout Vertical {
    Label nameLabel { Text: "Name:" }
    Input nameField { Placeholder: "Eingabe..." }
    Button ok { Text: "OK" OnClick: "commit" }
    Button cancel { Text: "Abbrechen" OnClick: "cancel" }
  }
}
\end_inset
```

---

*Erstellt: 2026-04-20*
*Letzte Aktualisierung: 2026-04-20*