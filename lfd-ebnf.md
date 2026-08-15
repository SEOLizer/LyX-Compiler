# LFD EBNF Grammatik v1.0.0

> Diese Grammatik beschreibt das LFD-Format (LyX Form Description) so, wie
> `std/lfd_parser.lyx` es **tatsächlich** liest.
>
> Version: 1.0.0 | Status: gültig | Maßgeblich: der Parser

**Zur Fassung 0.1.0 (#1397):** Die vorherige Grammatik beschrieb eine andere
Sprache als der Parser — großgeschriebene Schlüsselwörter (`Form`, `Layout`,
`Button`), einen Bezeichner je Element (`Button btnOk { … }`), eine
`Format:`-Kopfzeile und Widget-Typen, die es nie gab (`WebView`). Wer sich
daran hielt, bekam `expected 'form'`. Entschieden wurde: **der Parser ist
maßgeblich**, die Grammatik zieht nach. Alles unten Beschriebene ist gegen
`tests/lfd_grammatik_test.sh` gemessen.

## 1. Grundstruktur

```
LFD-Datei    ::= Form-Block
Form-Block   ::= "form" Titel? Block
Titel        ::= String
Block        ::= "{" Element* "}"
```

Es gibt **keine Kopfzeile**. Ein `Format: "…"` am Dateianfang ist kein
gültiges LFD — die Datei beginnt mit `form`.

Der Titel ist **optional** und steht als Zeichenkette direkt hinter dem
Schlüsselwort. Einen Bezeichner je Element gibt es nicht: der Knoten führt
Typ und Text, kein Namensfeld.

## 2. Elemente

```
Element      ::= Container | Widget | Property
Container    ::= Container-Typ Titel? Block
Widget       ::= Widget-Typ Titel? Block?
Property     ::= Property-Name ":" Wert
```

Container und Widgets unterscheiden sich nur darin, dass ein Container
üblicherweise Kinder trägt; syntaktisch sind sie gleich. Der Block ist bei
beiden optional — `button "OK"` allein ist gültig.

## 3. Schlüsselwörter

**Alle Schlüsselwörter werden kleingeschrieben verglichen.** `Button` ist
kein Widget-Typ, sondern ein gewöhnlicher Bezeichner (und damit ein
Property-Name, sobald ein `:` folgt).

```
Container-Typ ::= "layout" | "vertical" | "horizontal" | "grid" | "stack"
                | "groupbox" | "tabwidget" | "splitter"

Widget-Typ    ::= "button" | "label" | "input" | "checkbox" | "radiobutton"
                | "combobox" | "spinbox" | "slider" | "listbox" | "textedit"
                | "progressbar" | "image" | "custom"
```

`groupbox`, `tabwidget` und `splitter` zählen im Parser zu den Containern,
nicht zu den Widgets — sie tragen Kinder.

Ein `webview` gibt es nicht. Die Fassung 0.1.0 führte ihn in der Liste; der
Parser kannte ihn nie und liest ihn als Bezeichner.

## 4. Properties

```
Property-Name ::= Property-Schlüsselwort | Identifier
Property-Schlüsselwort
              ::= "text" | "tooltip" | "enabled" | "visible"
                | "width" | "height" | "onclick" | "onchange"
Identifier    ::= [a-zA-Z_][a-zA-Z0-9_]*

Wert          ::= String | Number | Boolean | Identifier
Boolean       ::= "true" | "false"
Number        ::= [0-9]+
String        ::= '"' [^"]* '"'
```

Ein Property-Name darf jeder Bezeichner sein — die acht Schlüsselwörter sind
nur die, für die es einen eigenen Token-Typ gibt. `align: "center"` ist
gültig und landet als Property mit dem Namen `align` im Baum.

**Zahlen sind vorzeichenlos.** Ein `-` vor der Zahl ist kein Teil der Zahl;
zur Behandlung siehe #1394.

**Zeichenketten-Werte** werden vom Parser derzeit gelesen, aber nicht am
Knoten abgelegt (#1393). Die Grammatik beschreibt hier die Sprache, nicht den
Stand der Umsetzung; die offenen Punkte sind unten aufgeführt.

## 5. Vollständiges Beispiel

Dieses Beispiel ist gegen den Parser gemessen und wird fehlerfrei gelesen:

```
form "Konfiguration" {
  vertical {
    label "Einstellungen" {
      align: "center"
    }

    groupbox "Optionen" {
      vertical {
        checkbox "Automatisch speichern" {
          onchange: "set-auto-save"
        }
        checkbox "Benachrichtigungen anzeigen" {
          onchange: "set-notifications"
        }
      }
    }

    horizontal {
      button "OK" {
        width: 100
        onclick: "save-config"
      }
      button "Abbrechen" {
        onclick: "cancel"
      }
    }
  }
}
```

## 6. Knotenarten

Der Baum führt für jeden Knoten eine Art. Widget- und Container-Knoten tragen
den `LFD_TK_*`-Wert ihres Schlüsselworts, Properties eine eigene Konstante:

| Knoten | Konstante | Wert |
|---|---|---|
| Form | `LFD_TK_FORM` | 0 |
| Layout | `LFD_TK_LAYOUT` | 1 |
| Property | `LFD_NODE_PROPERTY` | 101 |
| Event | `LFD_NODE_EVENT` | 102 |
| Wurzel | `LFD_NODE_ROOT` | 100 |

Die Widget-Konstanten `LFD_NODE_*` aus früheren Fassungen überschneiden sich
mit den Token-Werten (`LFD_NODE_WIDGET` = 3 = `LFD_TK_HORIZONTAL`); das ist
als #1396 geführt.

## 7. Reservierte Wörter

```
form  layout  vertical  horizontal  grid  stack
button  label  input  checkbox  radiobutton  combobox  spinbox
slider  listbox  textedit  progressbar  groupbox  tabwidget
splitter  image  custom
text  tooltip  enabled  visible  width  height  onclick  onchange
true  false
```

Alles andere ist ein Bezeichner.

## 8. Was diese Grammatik NICHT beschreibt

Die Fassung 0.1.0 führte mehrere Formen, die nie umgesetzt waren. Sie stehen
hier bewusst nicht mehr, damit niemand danach schreibt:

* Bezeichner je Element (`Button btnOk { … }`)
* `Format:`-Kopfzeile
* Ausdrücke und Variablen (`Text: "$value"`)
* Wiederholungen (`For i in 0..3 { … }`)
* Der Widget-Typ `webview`
* Die Ereignisse `onselect`, `ondoubleclick`, `onfocusin`, `onfocusout`,
  `onhover` — der Lexer kennt nur `onclick` und `onchange`; alles andere
  wird als gewöhnlicher Property-Name gelesen.

## 9. Offene Punkte am Parser

Die folgenden Abweichungen sind gemeldet und noch nicht behoben. Sie ändern
nichts an der hier beschriebenen Sprache:

| Nummer | Punkt |
|---|---|
| #1393 | Zeichenketten-Werte (`text`, `tooltip`, `onclick`) werden verworfen |
| #1394 | `width: -5` ergibt still 5 — das Minuszeichen fällt weg |
| #1395 | kein Getter für die Textlänge |
| #1396 | `LFD_NODE_WIDGET` kollidiert mit `LFD_TK_HORIZONTAL` |
| #1391 | `std.lfd_factory` ist funktionslos |
| #1392 | `std.lfd_factory` vergleicht `pchar` mit `==` statt `StrEquals` |

---

*EBNF-Version: 1.0.0*
*Erstellt: 2026-04-20*
*Letzte Änderung: 2026-08-15 (#1397 — an den Parser angeglichen)*
