# Multi-Import Syntax — Refactoring Plan

## 1. Status Quo & Ziel

### Aktuell (Status Quo)
Mehrere Imports müssen als separate Statements mit Semikolon getrennt werden:
```
import std.time;
import std.datetime;
import std.io;
```

Die Grammatik lautet formal:
```
ImportDecl ::= 'import' IDENT ('.' IDENT)* ';'
```

### Ziel
Eine kommagetrennte Liste von Modulnamen soll in einem einzigen `import`-Statement erlaubt sein:
```
import std.time, std.datetime, std.io;
```

Beide Formen sollen gleichzeitig gültig sein. Die neue Grammatik:
```
ImportDecl ::= 'import' ModulePath (',' ModulePath)* ';'
ModulePath ::= IDENT ('.' IDENT)*
```

---

## 2. Architekturentwurf

### Betroffene Komponenten

| Komponente | Datei | Änderungsbedarf |
|---|---|---|
| **Lexer** | `src/lexer.lyx` | **Keine.** `TK_COMMA` (107) existiert bereits. |
| **Parser** | `src/parser.lyx` | **Ja.** `_parseImport()` und die äußere Parse-Schleife anpassen. |
| **Sema** | `src/sema.lyx` | **Keine.** Verarbeitet jeden `NK_IMPORT`-Knoten einzeln. |
| **IR-Lowering** | `src/ir_lower.lyx` | **Keine.** Verarbeitet jeden `NK_IMPORT`-Knoten einzeln. |

### AST-Strategie: Expansion zu mehreren NK_IMPORT-Knoten (Flat Expansion)

Es wird **kein neuer AST-Knoten** eingeführt. Stattdessen expandiert der Parser
`import a, b, c;` direkt in eine Kette aus drei separaten `NK_IMPORT`-Knoten,
identisch zu dem, was drei einzelne `import`-Statements erzeugen würden.

Vorteil: Sema, IR-Lowering, Codegen bleiben unverändert. Die Komplexität
bleibt vollständig im Parser lokalisiert.

```
import std.time, std.datetime, std.io;
  ↓  Parser: _parseImport()
NK_IMPORT("std.time") → NK_IMPORT("std.datetime") → NK_IMPORT("std.io")
```

### Technische Herausforderung: Tail-Tracking in der Parse-Schleife

Die äußere Parse-Schleife in `Parse()` (Zeile 2322–2325) trackt den `tail`-Zeiger
mit `tail := decl`. Wenn `_parseImport` jetzt eine Kette mehrerer Knoten zurückgibt,
muss `tail` zum **letzten Knoten** dieser Kette gesetzt werden, sonst wird die Kette
beim nächsten `_sn(tail, next_decl)` überschrieben und n2/n3 gehen verloren.

---

## 3. Arbeitsschritte (Work Packages)

### WP-1: `_parseImport()` — Komma-Schleife und Knoten-Kette

**Titel & Ziel:** Die Funktion `_parseImport()` so erweitern, dass nach jedem
geparseten Modulpfad geprüft wird, ob ein Komma folgt. Falls ja, wird ein weiterer
`NK_IMPORT`-Knoten allokiert und per `_sn()` an den vorherigen gehängt.
Das Semikolon am Ende wird nach der gesamten Liste einmalig konsumiert.

**Betroffene Dateien:** `src/parser.lyx`, Zeile 1846–1863

**Aktuelle Implementierung:**
```lyx
fn _parseImport(): int64 {
  var ti: int64 := self.cur;
  self.Advance();                              // 'import' konsumieren
  var n: int64 := self._alloc(NK_IMPORT, ti);
  var nameTok: int64 := self.cur;
  self.Expect(TK_IDENT);
  var endTok: int64 := nameTok;
  while (self.Check(TK_DOT) != 0) {
    self.Advance();
    endTok := self.cur;
    self.Expect(TK_IDENT);
  }
  var startOff: int64 := self.TokStart(nameTok);
  var endOff: int64 := self.TokStart(endTok) + self.TokLen(endTok);
  self._ssv(n, startOff, endOff - startOff);
  self.Match(TK_SEMI);
  return n;
}
```

**Neue Implementierung:**
```lyx
fn _parseImport(): int64 {
  var ti: int64 := self.cur;
  self.Advance();                              // 'import' konsumieren
  var firstNode: int64 := -1;
  var lastNode:  int64 := -1;

  while (1 == 1) {
    var nodeTi: int64 := self.cur;             // Token-Index für diesen Knoten
    var n: int64 := self._alloc(NK_IMPORT, nodeTi);
    var nameTok: int64 := self.cur;
    self.Expect(TK_IDENT);
    var endTok: int64 := nameTok;
    while (self.Check(TK_DOT) != 0) {
      self.Advance();
      endTok := self.cur;
      self.Expect(TK_IDENT);
    }
    var startOff: int64 := self.TokStart(nameTok);
    var endOff: int64 := self.TokStart(endTok) + self.TokLen(endTok);
    self._ssv(n, startOff, endOff - startOff);

    if (firstNode == -1) { firstNode := n; }
    if (lastNode  != -1) { self._sn(lastNode, n); }
    lastNode := n;

    if (self.Match(TK_COMMA) == 0) { break; }  // kein Komma → Ende der Liste
  }

  self.Match(TK_SEMI);
  return firstNode;
}
```

**Akzeptanzkriterien:**
- `import std.io;` → ein `NK_IMPORT`-Knoten mit `sVal = "std.io"`
- `import std.time, std.io;` → zwei `NK_IMPORT`-Knoten, korrekt verkettet
- `import a.b, c.d, e.f.g;` → drei `NK_IMPORT`-Knoten mit den korrekten `sVal`-Spans
- Trailing-Komma `import a, b,;` → Parser-Fehler (Expect TK_IDENT schlägt fehl)

---

### WP-2: Parse-Schleife — Tail-Pointer nach Kette korrekt setzen

**Titel & Ziel:** Nach einem `_parseImport()`-Aufruf muss der `tail`-Pointer der
äußeren Schleife auf den **letzten Knoten** der zurückgegebenen Kette gesetzt werden,
nicht nur auf den ersten. Sonst wird die Kette beim nächsten Declaration-Append
korrumpiert.

**Betroffene Dateien:** `src/parser.lyx`, Zeile 2322–2325

**Aktuelle Implementierung:**
```lyx
if (decl >= 0) {
  if (head == -1) { head := decl; tail := decl; }
  else { self._sn(tail, decl); tail := decl; }
}
```

**Neue Implementierung:**
```lyx
if (decl >= 0) {
  if (head == -1) { head := decl; }
  else { self._sn(tail, decl); }
  // Zum Ende der (ggf. mehrelementigen) Kette laufen
  tail := decl;
  while (self.NNext(tail) != -1) { tail := self.NNext(tail); }
}
```

*Hinweis:* Diese Änderung ist allgemein sicher — für alle anderen Declarations, die
einen Einzelknoten zurückgeben, terminiert die `while`-Schleife sofort in Iteration 0.

**Akzeptanzkriterien:**
- `import a, b, c; fn main() {}` → Die gesamte Deklarationsliste ist
  `NK_IMPORT("a") → NK_IMPORT("b") → NK_IMPORT("c") → NK_FUNC_DECL("main")`
  ohne unterbrochene Zeiger.
- `import a; import b, c; import d;` → Kette:
  `NK_IMPORT("a") → NK_IMPORT("b") → NK_IMPORT("c") → NK_IMPORT("d")`

---

### WP-3: Tests

**Titel & Ziel:** Neue Testfälle hinzufügen, die die korrekte Expansion und
Fehlerbehandlung der neuen Syntax prüfen.

**Betroffene Dateien:**
- Neue Testdatei: `tests/lyx/test_multi_import.lyx`
- Erwartete Ausgabe: `tests/lyx/test_multi_import.expected`

**Testfälle:**

```
# test_multi_import.lyx — Positiv-Tests
import std.io, std.time;         // 2 Module
import a.b, c.d, e.f.g;         // 3 Module, unterschiedliche Tiefe
import single;                   // 1 Modul (Rückwärtskompatibilität)
import a; import b, c;           // gemischt: alter und neuer Stil

# Negativ-Tests (erwarteter Parser-Fehler)
import a, ;                      // Trailing-Komma → Fehler
import , a;                      // Führendes Komma → Fehler
import a b;                      // Fehlendes Komma → Fehler (fällt auf `;` zurück)
```

**Akzeptanzkriterien:**
- Positiv-Tests kompilieren ohne Fehler
- Negativ-Tests produzieren exakt einen `ParseError` mit sinnvoller Meldung
- `import std.io, std.time;` und `import std.io; import std.time;` erzeugen
  semantisch identische AST-Knoten-Ketten (verifizierbar über Debug-Dump)

---

## Zusammenfassung der Änderungen

| WP | Datei | Zeilen | Art der Änderung |
|---|---|---|---|
| WP-1 | `src/parser.lyx` | 1846–1863 | `_parseImport()` mit Komma-Schleife |
| WP-2 | `src/parser.lyx` | 2322–2325 | Tail-Walk nach `_parseImport()` |
| WP-3 | `tests/lyx/` | neu | Testdateien |

Lexer, Sema, IR-Lowering und Codegen bleiben **unverändert**.
