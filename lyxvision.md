# Lyx TUI Framework

## Aktuelle Implementierung (v0.1.0)

Dieses Dokument beschreibt die aktuelle implementierte Version des LyxVision TUI-Frameworks, die als Standardbibliothek (`std/lyxvision`) im Lyx Compiler enthalten ist.

### 1. Architektur

LyxVision basiert auf einem einfachen **Single-Buffer Terminal-UI-Modell** mit ANSI-Escape-Codes für die Bildschirmausgabe.

### 2. Modul-Struktur

Die LyxVision-Units sind im Unterordner `std/lyxvision/` organisiert:

```
std/lyxvision/
  ├── main.lyx          # Haupt-Unit, re-exportiert Funktionen
  ├── types.lyx         # Basis-Typen (TPoint, TRect, TEvent)
  ├── consts.lyx        # Konstanten für State, Options, Flags
  ├── drivers.lyx       # Terminal-Treiber (ANSI, Screen, Input)
  └── view.lyx          # TView Basisstruktur
```

### 3. Verfügbare Typen

#### Basis-Typen (`std.lyxvision.types`)

```lyx
type TPoint = struct {
  x: int64;
  y: int64;
}

type TRect = struct {
  a: TPoint;
  b: TPoint;
}

type TEvent = struct {
  what: int64;
  keyCode: int64;
  mouseX: int64;
  mouseY: int64;
}
```

#### TView-Struktur (`std.lyxvision.view`)

```lyx
type TView = struct {
  originX: int64;
  originY: int64;
  sizeX: int64;
  sizeY: int64;
  cursorX: int64;
  cursorY: int64;
  growMode: int64;
  dragMode: int64;
  helpCtx: int64;
  state: int64;
  options: int64;
  ownerPtr: int64;
  nextPtr: int64;
  viewType: int64;
}
```

### 4. State-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `sfVisible` | 1 | View ist sichtbar |
| `sfCursorVis` | 2 | Cursor sichtbar |
| `sfCursorIns` | 4 | Cursor im Insert-Modus |
| `sfShadow` | 8 | Shadow sichtbar |
| `sfActive` | 16 | View ist aktiv |

### 5. Option-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `ofSelectable` | 1 | View kann selektiert werden |
| `ofFirstClick` | 2 | Erster Klick geht an den View |
| `ofFramed` | 4 | View hat Rahmen |

### 6. Terminal-Treiber (`std.lyxvision.drivers`)

Der Treiber stellt Low-Level-Funktionen für Terminal-Steuerung bereit:

**Grundlegende Funktionen:**
- `ClearScreen()` - Leert den Bildschirm
- `ClearToEol()` - Leert bis Zeilenende
- `MoveCursor(x, y)` - Positioniert Cursor
- `HideCursor()` / `ShowCursor()` - Cursor sichtbar/unsichtbar

**Farb-Funktionen:**
- `SetForeground(color)` - Vordergrundfarbe
- `SetBackground(color)` - Hintergrundfarbe
- `SetColors(fg, bg)` - Beide Farben gleichzeitig
- `ResetColors()` - Farben zurücksetzen

**Zeichnungs-Funktionen:**
- `FillRect(x1, y1, x2, y2)` - Rechteck füllen
- `WriteStr(x, y, text)` - Text schreiben
- `DrawBox(x1, y1, x2, y2)` - Box zeichnen

**Input-Funktionen:**
- `ReadKeyRaw()` - Rohes Tastaturlesen
- `GetKeyEvent()` - Strukturiertes Tastatur-Event

### 7. Hauptmodul (`std.lyxvision.main`)

Das Hauptmodul re-exportiert Funktionen und bietet High-Level-APIs:

**Initialisierung:**
```lyx
pub fn Init()           // LyxVision initialisieren
pub fn Done()           // LyxVision beenden
```

**Event-Loop:**
```lyx
pub fn RunSimple()      // Einfacher Event-Loop (ESC oder 'q' zum Beenden)
```

**Wrapper-Funktionen:**
- `SetColors(fg, bg)`
- `FillRect(x1, y1, x2, y2)`
- `WriteStr(x, y, s)`
- `DrawBox(x1, y1, x2, y2)`
- `ClearScreen()`, `ClearToEol()`
- `MoveCursor(x, y)`, `HideCursor()`, `ShowCursor()`
- `SetForeground(color)`, `SetBackground(color)`, `ResetColors()`
- `GetKeyEvent()`

### 8. Beispiel

```lyx
import std.lyxvision.main as lv;
import std.lyxvision.consts;

fn main(): int64 {
  lv.Init();
  
  // Bildschirm vorbereiten
  lv.SetColors(colorLightGray, colorBlue);
  lv.FillRect(1, 1, 80, 24);
  
  // Titelleiste
  lv.SetColors(colorBlack, colorLightGray);
  lv.FillRect(1, 1, 80, 1);
  lv.WriteStr(30, 1, " LyxVision Demo ");
  
  // Event-Loop
  lv.RunSimple();
  
  // Beenden
  lv.Done();
  return 0;
}
```

### 9. Import-Pfad

Die Units werden über den `std`-Namespace importiert:

```lyx
import std.lyxvision.main as lv;      // Hauptmodul
import std.lyxvision.types;           // Typen
import std.lyxvision.consts;          // Konstanten
import std.lyxvision.drivers;         // Treiber
import std.lyxvision.view;            // View-Basis
```

### 10. Systemabhängigkeiten

Das Framework verwendet ausschließlich Linux-Syscalls:
- `write()` - Terminal-Ausgabe
- `read()` - Tastatur-Eingabe
- `ioctl()` - Terminal-Status
- `nanosleep()` - Verzögerungen

### 11. Dirty-System (Geplant für zukünftige Version)

Das Dirty-System für effizientes Rendering ist **noch nicht implementiert**. Aktuell wird bei jeder Änderung der gesamte Bildschirm neu gezeichnet.

Geplante Features:
- `dirtyLevel` und `parentDirty` Felder in `TView`
- `ViewMarkVisualDirty()`, `ViewMarkLayoutDirty()`, `ViewMarkChildrenDirty()`
- `ViewIsDirty()`, `ViewGetDirtyLevel()`
- Drei-Phasen-Laufzeitmodell (Event, Layout, Render)

## Version

Aktuelle Version: **0.1.0**
