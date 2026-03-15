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
  ├── consts.lyx        # Konstanten für State, Options, Flags, Dirty
  ├── drivers.lyx       # Terminal-Treiber (ANSI, Screen, Input)
  └── view.lyx          # TView Basisstruktur
```

---

## 3. Basis-Typen (`std.lyxvision.types`)

### TPoint - 2D-Koordinatenpunkt

```lyx
type TPoint = struct {
  x: int64;
  y: int64;
}
```

**Funktionen:**
| Funktion | Beschreibung |
|----------|---------------|
| `PointNew(x, y)` | Erstellt einen neuen Punkt |
| `PointZero()` | Gibt den Nullpunkt (0, 0) zurück |
| `PointAdd(a, b)` | Addiert zwei Punkte |
| `PointSub(a, b)` | Subtrahiert zwei Punkte |
| `PointEqual(a, b)` | Vergleicht zwei Punkte |

### TRect - Rechteck (Bounding Box)

```lyx
type TRect = struct {
  ax: int64;   // Linke obere Ecke X
  ay: int64;   // Linke obere Ecke Y
  bx: int64;   // Rechte untere Ecke X
  by: int64;   // Rechte untere Ecke Y
}
```

**Funktionen:**
| Funktion | Beschreibung |
|----------|---------------|
| `RectFromCoords(ax, ay, bx, by)` | Erstellt Rechteck aus Koordinaten |
| `RectEmpty()` | Gibt ein leeres Rechteck zurück |
| `RectWidth(r)` | Gibt die Breite zurück |
| `RectHeight(r)` | Gibt die Höhe zurück |
| `RectSize(r)` | Gibt Größe als TPoint zurück |
| `RectIsEmpty(r)` | Prüft ob Rechteck leer ist |
| `RectContainsPoint(r, px, py)` | Prüft ob Punkt im Rechteck liegt |
| `RectMove(r, dx, dy)` | Verschiebt das Rechteck |
| `RectGrow(r, dx, dy)` | Vergrößert das Rechteck |

---

## 4. Event-System (`std.lyxvision.types`)

### TEvent - Event-Struktur

```lyx
type TEvent = struct {
  what:        int64;    // Event-Typ (evNothing, evMouseDown, etc.)
  buttons:     int64;    // Maustasten (mbLeftButton, etc.)
  doubleClick: int64;    // Doppelklick-Flag
  whereX:      int64;    // Maus-Position X
  whereY:      int64;    // Maus-Position Y
  keyCode:     int64;    // Tastatur-Code (virtuelle Keys)
  charCode:    int64;    // Zeichen-Code (ASCII)
  scanCode:    int64;    // Hardware Scan-Code
  command:     int64;    // Kommando (cmQuit, cmOK, etc.)
  infoInt:     int64;    // Zusätzliche Info
}
```

### Event-Typ Konstanten

| Konstante | Wert | Beschreibung |
|----------|------|---------------|
| `evNothing` | 0 | Kein Event |
| `evMouseDown` | 1 | Maustaste gedrückt |
| `evMouseUp` | 2 | Maustaste losgelassen |
| `evMouseMove` | 4 | Maus bewegt |
| `evKeyDown` | 16 | Taste gedrückt |
| `evCommand` | 256 | Kommando-Event |
| `evBroadcast` | 512 | Broadcast-Event |

### Event-Masken

| Konstante | Wert | Beschreibung |
|----------|------|---------------|
| `evMouse` | 15 | Alle Maus-Events |
| `evKeyboard` | 16 | Alle Keyboard-Events |
| `evMessage` | 65280 | Alle Nachrichten |

### Maus-Buttons

| Konstante | Wert |
|----------|------|
| `mbLeftButton` | 1 |
| `mbRightButton` | 2 |
| `mbMiddleButton` | 4 |

### Tastatur-Modifier

| Konstante | Wert |
|----------|------|
| `kbShift` | 1 |
| `kbCtrl` | 4 |
| `kbAlt` | 8 |

### Spezielle Tasten

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `kbEsc` | 27 | Escape |
| `kbEnter` | 13 | Enter |
| `kbTab` | 9 | Tab |
| `kbBackSp` | 8 | Backspace |
| `kbDel` | 127 | Delete |
| `kbUp` | 328 | Pfeil hoch |
| `kbDown` | 336 | Pfeil runter |
| `kbLeft` | 331 | Pfeil links |
| `kbRight` | 333 | Pfeil rechts |
| `kbHome` | 327 | Home |
| `kbEnd` | 335 | End |
| `kbPgUp` | 329 | Page Up |
| `kbPgDn` | 337 | Page Down |
| `kbF1` - `kbF10` | 315-324 | Funktionstasten |

### Kommando-Konstanten

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `cmValid` | 0 | Kein Kommando |
| `cmQuit` | 1 | Anwendung beenden |
| `cmError` | 2 | Fehler |
| `cmMenu` | 3 | Menü |
| `cmClose` | 4 | Schließen |
| `cmZoom` | 5 | Maximieren |
| `cmResize` | 6 | Größe ändern |
| `cmNext` | 7 | Nächster |
| `cmPrev` | 8 | Vorheriger |
| `cmHelp` | 9 | Hilfe |
| `cmOK` | 10 | OK |
| `cmCancel` | 11 | Abbrechen |
| `cmYes` | 12 | Ja |
| `cmNo` | 13 | Nein |

### Event-Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `EventEmpty()` | Erstellt ein leeres Event |
| `EventKey(kc, cc)` | Erstellt ein Tastatur-Event |
| `EventCommand(cmd, info)` | Erstellt ein Kommando-Event |
| `EventIsNothing(e)` | Prüft ob Event leer ist |
| `EventIsKeyboard(e)` | Prüft ob Tastatur-Event |
| `EventIsCommand(e)` | Prüft ob Kommando-Event |
| `EventClear(e)` | Markiert Event als behandelt |

---

## 5. TView-Struktur (`std.lyxvision.view`)

### TView - Basis-Struktur für alle sichtbaren Objekte

```lyx
type TView = struct {
  // Geometrie
  originX: int64;    // X-Position (Spalte)
  originY: int64;    // Y-Position (Zeile)
  sizeX: int64;      // Breite
  sizeY: int64;      // Höhe
  cursorX: int64;    // Cursor-Position X
  cursorY: int64;    // Cursor-Position Y
  
  // Verhalten
  growMode: int64;   // Resize-Verhalten
  dragMode: int64;   // Drag-Verhalten
  helpCtx: int64;    // Help-Kontext
  
  // Status
  state: int64;      // State-Flags (sfXxx)
  options: int64;    // Option-Flags (ofXxx)
  
  // Hierarchie (als int64 Pointer-Werte)
  ownerPtr: int64;   // Zeiger auf Owner
  nextPtr: int64;    // Zeiger auf nächsten View
  
  // View-Typ für Dispatch
  viewType: int64;   // vtXxx
  
  // Dirty-Management
  dirtyLevel: int64;    // 0=clean, 1=visual, 2=layout, 3=children
  parentDirty: int64;    // Vererbter Dirty-Status
}
```

### View-Typen

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `vtView` | 0 | Basis-View |
| `vtGroup` | 1 | Container |
| `vtWindow` | 2 | Fenster |
| `vtDialog` | 3 | Dialog |
| `vtButton` | 4 | Schaltfläche |
| `vtInputLine` | 5 | Eingabefeld |
| `vtDesktop` | 6 | Desktop |
| `vtBackground` | 7 | Hintergrund |

### TView Funktionen

**Konstruktor:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewCreate(ax, ay, bx, by)` | Erstellt einen neuen View |

**Geometrie:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewGetBounds(v)` | Gibt Bounds als TRect zurück |
| `ViewSetBounds(v, r)` | Setzt Bounds aus TRect |
| `ViewMoveTo(v, x, y)` | Verschiebt View |
| `ViewGrowTo(v, w, h)` | Ändert Größe |

**Sichtbarkeit:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewIsVisible(v)` | Prüft Sichtbarkeit |
| `ViewShow(v)` | Zeigt View |
| `ViewHide(v)` | Versteckt View |

**Fokus:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewIsFocused(v)` | Prüft Fokus |
| `ViewFocus(v)` | Setzt Fokus |
| `ViewUnfocus(v)` | Entfernt Fokus |

**State:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewSetState(v, state, enable)` | Setzt/Entfernt State-Flag |
| `ViewGetState(v, state)` | Prüft State-Flag |

**Koordinaten:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewMakeLocalX(v, globalX)` | Konvertiert globale X nach lokal |
| `ViewMakeLocalY(v, globalY)` | Konvertiert globale Y nach lokal |
| `ViewMakeGlobalX(v, localX)` | Konvertiert lokale X nach global |
| `ViewMakeGlobalY(v, localY)` | Konvertiert lokale Y nach global |
| `ViewContainsPoint(v, x, y)` | Prüft ob Punkt im View |

**Cursor:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewSetCursor(v, x, y)` | Setzt Cursor-Position |
| `ViewShowCursor(v)` | Zeigt Cursor |
| `ViewHideCursor(v)` | Versteckt Cursor |

**Zeichnen:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewDrawFrame(v, fg, bg)` | Zeichnet Rahmen |
| `ViewFillBackground(v, fg, bg)` | Füllt Hintergrund |
| `ViewWriteStr(v, x, y, s)` | Schreibt Text |
| `ViewWriteStrAttr(v, x, y, s, fg, bg)` | Schreibt Text mit Farben |

**GrowMode:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewCalcBounds(v, dx, dy)` | Berechnet neue Bounds bei Resize |

**Dirty-Management:**
| Funktion | Beschreibung |
|----------|---------------|
| `ViewInitDirty(v)` | Initialisiert Dirty-Flags |
| `ViewSetDirtyLevel(v, level)` | Setzt Dirty-Level |
| `ViewMarkVisualDirty(v)` | Markiert als visuell geändert |
| `ViewMarkLayoutDirty(v)` | Markiert als Layout geändert |
| `ViewMarkChildrenDirty(v)` | Markiert als Struktur geändert |
| `ViewMarkClean(v)` | Markiert als sauber |
| `ViewIsDirty(v)` | Prüft ob Update nötig |
| `ViewGetDirtyLevel(v)` | Gibt Dirty-Level zurück |
| `ViewNeedsLayout(v)` | Prüft ob Layout-Update nötig |
| `ViewNeedsChildrenUpdate(v)` | Prüft ob Children-Update nötig |
| `ViewInheritDirtyFromParent(v, parentDirty)` | Erbt Dirty-Status |
| `ViewResetInheritedDirty(v)` | Setzt vererbten Status zurück |

---

## 6. State-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `sfVisible` | 1 | View ist sichtbar |
| `sfCursorVis` | 2 | Cursor sichtbar |
| `sfCursorIns` | 4 | Cursor im Insert-Modus |
| `sfShadow` | 8 | Shadow sichtbar |
| `sfActive` | 16 | View ist aktiv |
| `sfSelected` | 32 | View ist selektiert |
| `sfFocused` | 64 | View hat Fokus |
| `sfDragging` | 128 | View wird gezogen |
| `sfDisabled` | 256 | View ist deaktiviert |
| `sfModal` | 512 | View ist modal |
| `sfDefault` | 1024 | View ist Default |
| `sfExposed` | 2048 | View ist exponiert |

---

## 7. Option-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `ofSelectable` | 1 | View kann selektiert werden |
| `ofTopSelect` | 2 | Kommt nach oben bei Selektion |
| `ofFirstClick` | 4 | Erster Klick geht an View |
| `ofFramed` | 8 | View hat Rahmen |
| `ofPreProcess` | 16 | Pre-Processing aktiviert |
| `ofPostProcess` | 32 | Post-Processing aktiviert |
| `ofBuffered` | 64 | Buffered Output |
| `ofTileable` | 128 | Kann geteilt werden |
| `ofCenterX` | 256 | Zentriere X |
| `ofCenterY` | 512 | Zentriere Y |
| `ofCentered` | 768 | Zentriert (X+Y) |
| `ofValidate` | 1024 | Validierung aktiviert |

---

## 8. GrowMode-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `gfGrowLoX` | 1 | Links wachsen |
| `gfGrowLoY` | 2 | Oben wachsen |
| `gfGrowHiX` | 4 | Rechts wachsen |
| `gfGrowHiY` | 8 | Unten wachsen |
| `gfGrowAll` | 15 | In alle Richtungen |
| `gfGrowRel` | 16 | Relatives Wachstum |
| `gfFixed` | 0 | Kein Wachstum |

---

## 9. DragMode-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `dmDragMove` | 1 | Verschieben erlaubt |
| `dmDragGrow` | 2 | Vergrößern erlaubt |
| `dmLimitLoX` | 16 | Limit links |
| `dmLimitLoY` | 32 | Limit oben |
| `dmLimitHiX` | 64 | Limit rechts |
| `dmLimitHiY` | 128 | Limit unten |
| `dmLimitAll` | 240 | Alle Limits |

---

## 10. Dirty-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `dfClean` | 0 | View sauber, kein Update |
| `dfVisual` | 1 | Visuelle Änderung, Neuzeichnung nötig |
| `dfLayout` | 2 | Layout-Änderung, Positionen neu berechnen |
| `dfChildren` | 3 | Struktur-Änderung, Children neu aufbauen |

---

## 11. Farbkonstanten (`std.lyxvision.consts`)

| Konstante | Wert | Farbe |
|-----------|------|-------|
| `colorBlack` | 0 | Schwarz |
| `colorBlue` | 1 | Blau |
| `colorGreen` | 2 | Grün |
| `colorCyan` | 3 | Cyan |
| `colorRed` | 4 | Rot |
| `colorMagenta` | 5 | Magenta |
| `colorBrown` | 6 | Braun |
| `colorLightGray` | 7 | Hellgrau |
| `colorDarkGray` | 8 | Dunkelgrau |
| `colorLightBlue` | 9 | Hellblau |
| `colorLightGreen` | 10 | Hellgrün |
| `colorLightCyan` | 11 | Hellcyan |
| `colorLightRed` | 12 | Hellrot |
| `colorLightMagenta` | 13 | Hellmagenta |
| `colorYellow` | 14 | Gelb |
| `colorWhite` | 15 | Weiß |

### Flag-Hilfsfunktionen

| Funktion | Beschreibung |
|----------|---------------|
| `FlagSet(flags, flag)` | Prüft ob Flag gesetzt |
| `FlagAdd(flags, flag)` | Setzt Flag |
| `FlagRemove(flags, flag)` | Entfernt Flag |
| `FlagToggle(flags, flag)` | Toggle Flag |

---

## 12. Terminal-Treiber (`std.lyxvision.drivers`)

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

---

## 13. Hauptmodul (`std.lyxvision.main`)

Das Hauptmodul re-exportiert Funktionen und bietet High-Level-APIs:

**Version:**
```lyx
pub con LYXVISION_VERSION_MAJOR := 0;
pub con LYXVISION_VERSION_MINOR := 1;
pub con LYXVISION_VERSION_PATCH := 0;

pub fn GetVersion(): pchar  // Gibt "0.1.0" zurück
```

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

---

## 14. Import-Pfad

Die Units werden über den `std`-Namespace importiert:

```lyx
import std.lyxvision.main as lv;      // Hauptmodul
import std.lyxvision.types;           // Typen
import std.lyxvision.consts;          // Konstanten
import std.lyxvision.drivers;         // Treiber
import std.lyxvision.view;            // View-Basis
```

---

## 15. Beispiel

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

---

## 16. Systemabhängigkeiten

Das Framework verwendet ausschließlich Linux-Syscalls:
- `write()` - Terminal-Ausgabe
- `read()` - Tastatur-Eingabe
- `ioctl()` - Terminal-Status
- `nanosleep()` - Verzögerungen

---

## 17. Geplante Module (TODO)

- `std.lyxvision.group` - TGroup: Container für Views
- `std.lyxvision.window` - TWindow: Fenster mit Rahmen
- `std.lyxvision.dialog` - TDialog: Modale Dialoge
- `std.lyxvision.button` - TButton: Klickbare Schaltfläche
- `std.lyxvision.input` - TInputLine: Eingabefeld
- `std.lyxvision.menu` - TMenuBar: Menüsystem
- `std.lyxvision.app` - TApplication: Hauptanwendung

---

## Version

Aktuelle Version: **0.1.0**
