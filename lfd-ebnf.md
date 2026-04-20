# LFD EBNF Grammatik v0.1.0

> Diese Grammatik definiert das LFD (LyX Form Description) Format.
> Version: 0.1.0 | Status: Draft

## 1. Grundstruktur

```
LFD-File          ::= Header? Form-Block
Header           ::= "Format:" String NEWLINE
Form-Block       ::= "Form" Identifier String "{" Layout-Block "}"
Identifier       ::= [a-zA-Z_][a-zA-Z0-9_]*
String            ::= '"' [^"\\\n]* '"'
```

## 2. Layout-Blöcke

```
Layout-Block      ::= (Layout-Directive | Widget-Definition)*
Layout-Directive  ::= "Layout" Layout-Type "{" Layout-Block "}"
Layout-Type       ::= "Vertical" | "Horizontal" | "Grid" | "Stack"
```

**Beispiel:**
```
Layout Vertical {
  ...
}
```

## 3. Widget-Definitionen

```
Widget-Definition ::= Widget-Type Identifier "{" Property-List "}"
Widget-Type      ::= "Button" | "Label" | "Input" | "Checkbox" 
                    | "RadioButton" | "ComboBox" | "SpinBox"
                    | "Slider" | "ListBox" | "TextEdit"
                    | "ProgressBar" | "GroupBox" | "TabWidget"
                    | "Splitter" | "Image" | "WebView"
                    | "Custom"
```

**Widget-Typ Aliasse:**
```
Button         = QPushButton
Label         = QLabel
Input         = QLineEdit
Checkbox      = QCheckBox
RadioButton   = QRadioButton
ComboBox      = QComboBox
SpinBox       = QSpinBox
Slider        = QSlider
ListBox       = QListWidget
TextEdit      = QPlainTextEdit
ProgressBar   = QProgressBar
GroupBox      = QGroupBox
TabWidget     = QTabWidget
Splitter      = QSplitter
Image         = QLabel (mit Pixmap)
WebView       = QWebEngineView (falls verfügbar)
Custom        = Benutzerdefiniertes Widget
```

## 4. Properties

```
Property-List    ::= Property*
Property         ::= Property-Name ":" PropertyValue
Property-Name    ::= Identifier
PropertyValue    ::= String | Number | Boolean | Expression | Block

Boolean          ::= "true" | "false"
Number          ::= [0-9]+ ("." [0-9]+)?
Expression       ::= "$" Identifier | "$" "{" Expression "}" | ...
```

### Standard Properties (alle Widgets):

| Property | Typ | Default | Beschreibung |
|---------|-----|---------|-------------|
| Text | String | "" | Angezeigter Text |
| ToolTip | String | "" | Tooltip bei Hover |
| Enabled | Boolean | true | Widget aktiviert |
| Visible | Boolean | true | Widget sichtbar |
| Width | Number | -1 | feste Breite (-1 = auto) |
| Height | Number | -1 | fixe Höhe (-1 = auto) |
| MinWidth | Number | 0 | minimale Breite |
| MinHeight | Number | 0 | minimale Höhe |
| MaxWidth | Number | 0xFFFFFF | maximale Breite |
| MaxHeight | Number | 0xFFFFFF | maximale Höhe |
| Align | String | "left" | Text-Ausrichtung |
| Style | String | "" | CSS-Style (QSS) |
| OnClick | LFun | - | Click-Event Handler |
| OnChange | LFun | - | Change-Event Handler |

### Widget-spezifische Properties:

**Button:**
| Property | Typ | Default |
|---------|-----|---------|
| Default | Boolean | false |
| Flat | Boolean | false |
| Icon | String | - |

**Input:**
| Property | Typ | Default |
|---------|-----|---------|
| Placeholder | String | "" |
| MaxLength | Number | 0 (unlimited) |
| EchoMode | String | "Normal" (Normal/NoEcho/Password) |

**Slider/SpinBox:**
| Property | Typ | Default |
|---------|-----|---------|
| Min | Number | 0 |
| Max | Number | 100 |
| Value | Number | 0 |
| Step | Number | 1 |

**ComboBox:**
| Property | Typ | Default |
|---------|-----|---------|
| Items | String[] | [] |
| Editable | Boolean | false |

## 5. Events & Interaktion

```
Event-Handler    ::= "On" Event-Name ":" LFun-Reference
Event-Name       ::= "Click" | "Change" | "Select" | "DoubleClick"
                    | "FocusIn" | "FocusOut" | "KeyPress" | "Hover"
LFun-Reference   ::= Identifier | String
```

**Beispiel:**
```
Button btnOk {
  Text: "OK"
  OnClick: "command-insert"
}
```

## 6. Erweiterungen

### Verschachtelte Widgets

```
GroupBox mainGroup {
  Text: "Optionen"
  Layout Vertical {
    Checkbox opt1 { Text: "Option A" }
    Checkbox opt2 { Text: "Option B" }
  }
}
```

### Bedingte Properties

```
Input field {
  Text: "$value"
  Enabled: "$isEditable"
}
```

### Wiederholungen (Future)

```
For i in 0..3 {
  Button "btn$i" { Text: "Button $i" }
}
```

---

## Vollständiges Beispiel

```
Format: "LFD v1.0"

Form ConfigDialog "Konfiguration" {
  Layout Vertical {
    Label lblTitle {
      Text: "Einstellungen"
      Align: "center"
    }
    
    GroupBox grpOptions {
      Text: "Optionen"
      Layout Vertical {
        Checkbox optAutoSave {
          Text: "Automatisch speichern"
          OnChange: "set-auto-save"
        }
        Checkbox optNotifications {
          Text: "Benachrichtigungen anzeigen"
          OnChange: "set-notifications"
        }
      }
    }
    
    Layout Horizontal {
      Button btnOk {
        Text: "OK"
        OnClick: "save-config"
      }
      Button btnCancel {
        Text: "Abbrechen"
        OnClick: "cancel"
      }
    }
  }
}
```

---

## Zusammenfassung: Reserved Words

```
Form
Layout
Vertical
Horizontal
Grid
Stack
OnClick
OnChange
OnSelect
OnDoubleClick
OnFocusIn
OnFocusOut
OnHover
true
false
Format
```

---

*EBNF Version: 0.1.0*
*Erstellt: 2026-04-20*
*Letzte Änderung: 2026-04-20*