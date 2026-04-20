# WP2: LyX-Inset Entwicklung (Konzept)

> **Status**: Konzept-Design | **Branch**: `feat/lfd-support`

Dieses Dokument beschreibt das Design für das **InsetLFD** - die C++ Klasse, die LFD-Code in LyX integriert.

---

## 1. InsetLFD Klasse

### Header-Datei (Konzept)

```cpp
// InsetLFD.hh
#pragma once

#include "Inset.hh"

class Buffer;
class BufferView;

class InsetLFD : public Inset
{
public:
    explicit InsetLFD(Buffer * buf, string const & lfdCode = "");
    
    // Inset virtual methods
    InsetCode lyxCode() const override { return LFD_CODE; }
    string name() const override { return "LFD"; }
    
    // Rendering
    void draw(BufferView const &, pit_type, GraphicsContext &) const override;
    
    // Editing
    void edit(BufferView *, bool, bool) override;
    bool insetAllowed(InsetCode) const override;
    void setBuffer(Buffer &) override;
    
    // Cursor movement
    bool arrowKey(BufferView &, KeyState, LyX::Cursor &) override;
    
    // Properties dialog
    bool showInsetDialog() const override { return true; }
    
    // Export
    void latex(otexstream &, OutputFormat const &) const override;
    void docbook(odocstream &, OutputFormat const &) const override;
    
    // Accessors
    string const & getLfdCode() const { return lfd_code_; }
    void setLfdCode(string const & code);
    
private:
    // Inset virtual methods
    void doDispatch(Cursor &, FuncRequest &) override;
    bool getStatus(Cursor &, FuncRequest const &, FuncStatus &) const override;
    
    // Private data
    string lfd_code_;
    mutable QWidget * preview_widget_ = nullptr;
    mutable bool preview_dirty_ = true;
};
```

---

## 2. Serialisierung

### LyX-Format

Der LFD-Code wird im LyX-Format so gespeichert:

```lyx
\begin_inset LFD
Form MainDialog "Titel" {
    Layout Vertical {
        Button btnOk {
            Text: "OK"
            OnClick: "commit"
        }
    }
}
\end_inset
```

### Laden (InsetFactory)

```cpp
Inset * InsetLFD::create(Buffer * buf, string const & data)
{
    // Parse the data between \begin_inset and \end_inset
    return new InsetLFD(buf, data);
}
```

### Speichern

```cpp
void InsetLFD::toStream(ostream & os) const
{
    os << "\\begin_inset LFD\n";
    os << lfd_code_;
    os << "\n\\end_inset\n";
}
```

---

## 3. UI-Dialog

### LFD-Editor Dialog (Konzept)

Der Dialog hat zwei Bereiche:

```
┌─────────────────────────────────────────────────────┐
│ LFD Form Editor                                    │
├─────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────┐   │
│ │ Form MainDialog "Titel" {                    │   │
│ │     Layout Vertical {                       │   │
│ │         Label lbl {                         │   │
│ │             Text: "Name:"                    │   │
│ │         }                                   │   │
│ │         Input txt {                         │   │
│ │             Placeholder: "Eingabe..."       │   │
│ │         }                                   │   │
│ │         Button ok {                         │   │
│ │             Text: "OK"                      │   │
│ │             OnClick: "commit"              │   │
│ │         }                                   │   │
│ │     }                                       │   │
│ │ }                                           │   │
│ └─────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│ [Validate] [Preview]              [OK] [Cancel]  │
└─────────────────────────────────────────────────────┘
```

### Dialog-Funktionen

| Funktion | Beschreibung |
|---------|--------------|
| **Validate** | Prüft LFD-Syntax und zeigt Fehler |
| **Preview** | Live-Vorschau des gerenderten Forms |
| **OK** | Speichert und schließt |
| **Cancel** | Verwirft Änderungen |

---

## 4. Render-Pipeline

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  LFD-Text   │ ──→ │  Parser     │ ──→ │  AST        │
└──────────────┘     └──────────────┘     └──────────────┘
                                                │
                                                ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  LyX View   │ ←── │  QWidget    │ ←── │  Factory    │
└──────────────┘     └──────────────┘     └──────────────┘
```

---

## 5. Implementierungs-Schritte

### Schritt 1: Basis-Inset

```cpp
// Minimal viable InsetLFD
class InsetLFD : public Inset {
    string lfd_code_;
    
    void draw(...) const override {
        // Draw placeholder: "[LFD Form]"
    }
    
    void latex(otexstream & os) const override {
        os << "\\lfd{" << lfd_code_ << "}";
    }
};
```

### Schritt 2: Dialog hinzufügen

```cpp
void InsetLFD::edit(BufferView * bv, bool, bool) {
    LFDEditorDialog dialog(bv, lfd_code_);
    if (dialog.run() == QDialog::Accepted) {
        lfd_code_ = dialog.getCode();
        setBuffer(*buffer());
    }
}
```

### Schritt 3: Preview integrieren

```cpp
void InsetLFD::draw(...) const {
    if (preview_dirty_) {
        preview_widget_ = renderLFD(lfd_code_);
        preview_dirty_ = false;
    }
    
    // Draw preview_widget_ into LyX buffer
    GC::guard guard;
    Context gc(context);
    preview_widget_->render(gc);
}
```

---

## 6. Abhängigkeiten

| Komponente | Abhängigkeit |
|-----------|--------------|
| `std.lfd_parser` | Muss als C++ existieren |
| `libqtlyx.so` | Qt-Rendering |
| `Inset` (LyX Kernel) | Basis-Klasse |

---

## 7. Offene Fragen

1. **Wo wird der C++ Parser implementiert?**
   - Option A: Eigenständige C++ Datei im LyX-Kernel
   - Option B: Als Teil von libqtlyx.so

2. **Preview-Rendering:**
   - Direkt in LyX oder in separatem QWindow?

3. **Event-Handling:**
   - Wie kommuniziert LFD-Event → LyX-Kommando?

---

*Erstellt: 2026-04-20*
*Für: lfd-support.md WP2*