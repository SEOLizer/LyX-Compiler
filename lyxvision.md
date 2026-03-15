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
  ├── view.lyx         # TView: Basisklasse für alle Views
  ├── group.lyx        # TGroup: Container für Views (extends TView)
  ├── window.lyx       # TWindow: Fenster mit Rahmen (extends TGroup)
  ├── frame.lyx        # TFrame: Fenster-Rahmen
  ├── statictext.lyx   # TStaticText: Statischer Text
  ├── staticline.lyx   # TStaticLine: Horizontale/Vertikale Linie
  ├── button.lyx       # TButton: Klickbare Schaltfläche
  ├── inputline.lyx    # TInputLine: Eingabefeld
  └── terminal.lyx     # TTerminal: Terminal-Emulation
```

---

## 3. Klassen-Hierarchie (Vererbungsbaum)

Die folgende Übersicht zeigt die Vererbungsstruktur der LyxVision-Klassen:

```
TView                          ←── Basisklasse (alle Views erben hiervon)
│
├── TGroup                     ←── Container für Views
│   │
│   └── TWindow                ←── Fenster mit Rahmen
│       │
│       └── TDialog            ←── Modaler Dialog
│
├── TStaticText                ←── Statischer Text
│
├── TStaticLine                ←── Horizontale/Vertikale Linie
│
├── TButton                    ←── Klickbare Schaltfläche
│
├── TInputLine                ←── Eingabefeld
│
├── TTerminal                 ←── Terminal-Emulation
│
├── TDesktop                  ←── Desktop (geplant)
│
└── TBackground               ←── Hintergrund (geplant)
```

### Vererbungsregeln

- **TView** ist die Basisklasse aller sichtbaren Objekte
- **TGroup** erweitert TView um Container-Funktionalität (Child-Views)
- **TWindow** erweitert TGroup um Fenster-Funktionalität (Rahmen, Titel)
- Alle anderen Komponenten erben direkt von TView

### Syntax-Beispiel

```lyx
// Basisklasse
pub type TView = class {
  fn Init(x, y, w, h) { ... }
};

// Ableitung
pub type TGroup = class extends TView {
  fn Init(x, y, w, h) { ... }  // ruft super.Init() auf
};

// Instanziierung
var win: TWindow := new TWindow();
win.Init(10, 5, 60, 20, "Mein Fenster");
```

---

## 4. TView (`std.lyxvision.view`) - BASISKLASSE

**TView** ist die Basisklasse für alle sichtbaren Objekte in LyxVision.

```lyx
pub type TView = class {
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
  dirtyLevel: int64;
  parentDirty: int64;
  
  fn Init(vx, vy, vw, vh) { ... }
}
```

### View-Typen

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `vtView` | 0 | Basis-View |
| `vtGroup` | 1 | Container |
| `vtWindow` | 2 | Fenster |
| `vtDialog` | 3 | Dialog |
| `vtButton` | 4 | Button |
| `vtInputLine` | 5 | Eingabefeld |
| `vtDesktop` | 6 | Desktop |
| `vtBackground` | 7 | Hintergrund |

### TView Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `ViewCreate(ax, ay, bx, by)` | Erstellt View |
| `ViewInitDirty(v)` | Initialisiert Dirty-Flags |
| `ViewMarkVisualDirty(v)` | Markiert als visuell geändert |
| `ViewMarkLayoutDirty(v)` | Markiert als Layout geändert |
| `ViewMarkChildrenDirty(v)` | Markiert als strukturell geändert |
| `ViewMarkClean(v)` | Markiert als sauber |
| `ViewIsDirty(v)` | Prüft Dirty-Status |

---

## 5. TGroup (`std.lyxvision.group`) - CONTAINER

**TGroup** ist ein Container für Views und erweitert TView.

```lyx
pub type TGroup = class extends TView {
  firstChild: int64;
  lastChild: int64;
  current: int64;
  buffer: int64;
  bufferSize: int64;
  focusChain: int64;
  
  fn Init(gx, gy, gw, gh) { ... }
}
```

### TGroup Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `GroupNew(x, y, w, h)` | Erstellt neue Gruppe |
| `GroupInsert(g, viewPtr)` | Fügt View hinzu |
| `GroupRemove(g, viewPtr)` | Entfernt View |
| `GroupDraw(g)` | Zeichnet Gruppe |
| `GroupNext(g)` | Nächster fokussierbarer View |
| `GroupPrev(g)` | Vorheriger fokussierbarer View |
| `GroupSetCurrent(g, viewPtr)` | Setzt aktuellen View |
| `GroupGetCurrent(g)` | Gibt aktuellen View zurück |
| `GroupExecute(g)` | Event-Loop für Gruppe |
| `GroupClear(g)` | Entfernt alle Children |
| `GroupIsEmpty(g)` | Prüft ob leer |

---

## 6. TWindow (`std.lyxvision.window`) - FENSTER

**TWindow** ist ein Fenster mit Rahmen und erweitert TGroup.

```lyx
pub type TWindow = class extends TGroup {
  title: pchar;
  frameHandle: int64;
  zoomed: int64;
  number: int64;
  flags: int64;
  
  fn Init(wx, wy, ww, wh, title) { ... }
}
```

### TWindow Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `WindowNew(x, y, w, h, title)` | Erstellt Fenster |
| `WindowNewCentered(w, h, title)` | Erstellt zentriertes Fenster |
| `WindowSetTitle(win, title)` | Setzt Titel |
| `WindowGetTitle(win)` | Gibt Titel zurück |
| `WindowZoom(win)` | Zoom-Toggle |
| `WindowIsZoomed(win)` | Prüft Zoom-Status |
| `WindowDraw(win)` | Zeichnet Fenster |

---

## 7. TDialog (`std.lyxvision.dialog`) - MODALER DIALOG

TDialog erweitert TWindow um modale Dialog-Funktionalitat.

### Typ

```lyx
pub type TDialog = class extends TWindow {
  modalResult: int64;
  oldFocus: int64;
  valid: int64;
  
  fn Init(dx, dy, dw, dh, title) { ... }
}
```

### Modal Results

| Konstante | Wert |
|----------|------|
| `mrNone` | 0 |
| `mrOK` | 10 |
| `mrCancel` | 11 |
| `mrYes` | 12 |
| `mrNo` | 13 |

### TDialog Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `DialogNew(x, y, w, h, title)` | Erstellt Dialog |
| `DialogNewCentered(w, h, title)` | Erstellt zentrierten Dialog |
| `DialogSetModalResult(dlg, result)` | Setzt Modal-Result |
| `DialogGetModalResult(dlg)` | Gibt Modal-Result zurück |
| `DialogClose(dlg)` | Schließt Dialog |
| `DialogExecute(dlg)` | Führt modalen Dialog aus |
| `DialogIsValid(dlg)` | Prüft Gültigkeit |
| `DialogSetValid(dlg, valid)` | Setzt Gültigkeit |
| `DialogDraw(dlg)` | Zeichnet Dialog |

---

## 8. TFrame (`std.lyxvision.frame`)

Fenster-Rahmen mit verschiedenen Stilen.

### Typ

```lyx
type TFrame = struct {
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
  dirtyLevel: int64;
  parentDirty: int64;
  frameStyle: int64;
}
```

### Rahmen-Stile

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `frThin` | 0 | Dünner Rahmen (ASCII) |
| `frDouble` | 1 | Doppelter Rahmen |
| `frBox` | 2 | Einfacher Rahmen |

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `FrameCreate(x, y, w, h)` | Erstellt Rahmen |
| `FrameSetStyle(f, style)` | Setzt Rahmen-Stil |
| `FrameDraw(f)` | Zeichnet Rahmen |
| `FrameDrawTitle(f, title, color)` | Zeichnet Rahmen mit Titel |

---

## 9. Basis-Typen (`std.lyxvision.types`)

### TPoint - 2D-Koordinatenpunkt

```lyx
type TPoint = struct {
  x: int64;
  y: int64;
}
```

---

## 10. Event-System (`std.lyxvision.types`)

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

## 11. State-Flags (`std.lyxvision.consts`)

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

## 12. Option-Flags (`std.lyxvision.consts`)

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

## 13. GrowMode-Flags (`std.lyxvision.consts`)

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

## 14. DragMode-Flags (`std.lyxvision.consts`)

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

## 15. Dirty-Flags (`std.lyxvision.consts`)

| Flag | Wert | Beschreibung |
|------|------|--------------|
| `dfClean` | 0 | View sauber, kein Update |
| `dfVisual` | 1 | Visuelle Änderung, Neuzeichnung nötig |
| `dfLayout` | 2 | Layout-Änderung, Positionen neu berechnen |
| `dfChildren` | 3 | Struktur-Änderung, Children neu aufbauen |

---

## 16. Farbkonstanten (`std.lyxvision.consts`)

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

## 17. Terminal-Treiber (`std.lyxvision.drivers`)

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

## 18. Hauptmodul (`std.lyxvision.main`)

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

## 19. Import-Pfad

Die Units werden über den `std`-Namespace importiert:

```lyx
import std.lyxvision.main as lv;      // Hauptmodul
import std.lyxvision.types;           // Typen
import std.lyxvision.consts;          // Konstanten
import std.lyxvision.drivers;         // Treiber
import std.lyxvision.view;            // View-Basis
import std.lyxvision.frame;           // Rahmen
import std.lyxvision.statictext;      // Statischer Text
import std.lyxvision.staticline;      // Linie
import std.lyxvision.button;          // Button
import std.lyxvision.inputline;       // Eingabefeld
import std.lyxvision.terminal;        // Terminal
```

---

## 20. TStaticText - Statischer Text (`std.lyxvision.statictext`)

### Typ

```lyx
type TStaticText = struct {
  // TView Felder...
  textPtr: int64;
  text: pchar;
  centerAlign: int64;
}
```

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `StaticTextCreate(x, y, text)` | Erstellt Text |
| `StaticTextSetText(st, text)` | Setzt Text |
| `StaticTextSetCenterAlign(st, center)` | Setzt Zentrierung |
| `StaticTextDraw(st)` | Zeichnet Text |
| `StaticTextDrawColor(st, fg, bg)` | Zeichnet mit Farben |

---

## 21. TStaticLine - Linie (`std.lyxvision.staticline`)

### Linien-Typen

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `slHorizontal` | 0 | Horizontale Linie |
| `slVertical` | 1 | Vertikale Linie |

### Linien-Stile

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `slSingle` | 0 | Einfache Linie |
| `slDouble` | 1 | Doppelte Linie |
| `slBlock` | 2 | Ausgefüllte Linie |

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `StaticLineCreateH(x, y, len)` | Erstellt horizontale Linie |
| `StaticLineCreateV(x, y, len)` | Erstellt vertikale Linie |
| `StaticLineSetStyle(sl, style)` | Setzt Stil |
| `StaticLineDraw(sl)` | Zeichnet Linie |
| `StaticLineDrawColor(sl, fg, bg)` | Zeichnet mit Farben |

---

## 22. TButton - Schaltfläche (`std.lyxvision.button`)

### Button-Flags

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `bfNormal` | 0 | Normaler Button |
| `bfDefault` | 1 | Default-Button (Enter) |
| `bfBold` | 2 | Fetter Text |
| `bfShadow` | 4 | Schatten |
| `bfGrabFocus` | 8 | Nimmt Fokus an |

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `ButtonCreate(x, y, w, h, title, cmd)` | Erstellt Button |
| `ButtonCreateStd(x, y, title, cmd)` | Erstellt Standard-Button |
| `ButtonCreateDefault(x, y, title, cmd)` | Erstellt Default-Button |
| `ButtonSetPressed(btn, pressed)` | Setzt Gedrückt-Status |
| `ButtonDraw(btn)` | Zeichnet Button |
| `ButtonIsKey(btn, key)` | Prüft ob Taste passt |
| `ButtonPress(btn)` | Führt Button-Aktion aus |

---

## 23. TInputLine - Eingabefeld (`std.lyxvision.inputline`)

### InputLine-Optionen

| Konstante | Wert | Beschreibung |
|----------|------|--------------|
| `ilValidate` | 1 | Validierung aktiv |
| `ilCursorIns` | 2 | Insert-Modus |
| `ilCursorOver` | 4 | Overwrite-Modus |
| `ilPassword` | 8 | Passwort-Modus |
| `ilHistory` | 16 | History unterstützt |

### Konstanten

| Konstante | Wert |
|----------|------|
| `MAX_INPUT_LENGTH` | 256 |

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `InputLineCreate(x, y, maxLen)` | Erstellt Eingabefeld |
| `InputLineSetInsertMode(il, insert)` | Setzt Insert/Overwrite |
| `InputLineSetSelection(il, start, end)` | Setzt Markierung |
| `InputLineClearSelection(il)` | Löscht Markierung |
| `InputLineSetCurPos(il, pos)` | Setzt Cursor-Position |
| `InputLineDraw(il)` | Zeichnet Eingabefeld |
| `InputLineProcessKey(il, key)` | Verarbeitet Taste |

---

## 24. TTerminal - Terminal-Emulation (`std.lyxvision.terminal`)

### Typ

```lyx
type TTerminal = struct {
  // TView Felder...
  bufferLines: int64;
  bufferCols: int64;
  curRow: int64;
  curCol: int64;
  startLine: int64;
  canScroll: int64;
}
```

### Konstanten

| Konstante | Wert |
|----------|------|
| `TERM_BUFFER_LINES` | 100 |
| `TERM_BUFFER_COLS` | 80 |
| `TERM_MAX_LINES` | 1000 |
| `ANSI_ESC` | 27 |

### Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `TerminalCreate(x, y, w, h)` | Erstellt Terminal |
| `TerminalSetCursor(term, row, col)` | Setzt Cursor |
| `TerminalHome(term)` | Cursor nach Hause |
| `TerminalClear(term)` | Löscht Bildschirm |
| `TerminalClearEOL(term)` | Löscht bis Zeilenende |
| `TerminalNewLine(term)` | Zeilenumbruch |
| `TerminalWriteStr(term, s)` | Schreibt String |
| `TerminalPutChar(term, ch)` | Schreibt Zeichen |
| `TerminalWriteAnsi(term, s)` | Schreibt mit ANSI |
| `TerminalScrollUp(term)` | Scrollt hoch |
| `TerminalScrollDown(term)` | Scrollt runter |
| `TerminalSetFG(term, color)` | Setzt Vordergrund |
| `TerminalSetBG(term, color)` | Setzt Hintergrund |
| `TerminalSetColor(term, fg, bg)` | Setzt beide Farben |
| `TerminalResetColor(term)` | Reset Farben |
| `TerminalDraw(term)` | Zeichnet Terminal |

---

## 25. Beispiel

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

## 26. Systemabhängigkeiten

Das Framework verwendet ausschließlich Linux-Syscalls:
- `write()` - Terminal-Ausgabe
- `read()` - Tastatur-Eingabe
- `ioctl()` - Terminal-Status
- `nanosleep()` - Verzögerungen

---

## 27. Geplante Module (TODO)

Diese Module sind noch nicht implementiert:

- `std.lyxvision.listview` - TListView: Listenansicht
- `std.lyxvision.cluster` - TCluster: Basis für RadioButtons/Checkboxes
- `std.lyxvision.menu` - TMenuBar: Menüsystem
- `std.lyxvision.app` - TApplication: Hauptanwendung
- `std.lyxvision.textdevice` - TTextDevice: Text-Gerät

### Bereits implementiert (Sektionen 4-7):

- `std.lyxvision.view` - TView: Basisklasse
- `std.lyxvision.group` - TGroup: Container für Views
- `std.lyxvision.window` - TWindow: Fenster mit Rahmen
- `std.lyxvision.dialog` - TDialog: Modaler Dialog

---

## Version

Aktuelle Version: **0.1.0**
