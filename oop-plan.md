# OOP-Erweiterungen für Lyx Compiler (v0.1.8) – Plan

## Überblick

Dieses Dokument beschreibt den detaillierten Plan zur Implementierung der grundlegenden Objektorientierten Programmierungs (OOP)-Funktionen im Lyx-Compiler, Version 0.1.8. Ziel ist es, eine Pascal-ähnliche System-Unit-Struktur auf Basis von `TObject` als Basisklasse zu etablieren, automatische Vererbung zu implementieren, Sichtbarkeitsmodifikatoren zu parsen und Namenskonventionen für Klassen durchzusetzen.

### Klarstellungen (aus der Konversation)

1.  **Priorität der Anforderungen:** Alle Anforderungen werden parallel bearbeitet.
2.  **Definition von `Create` und `Destroy`:** Diese Methoden in `TObject` dienen als einfache Konstruktor- bzw. Destruktor-Platzhalter ohne besondere Syscall-Logik zur Speicherallokation.
3.  **Scope des impliziten Imports:** Der implizite Import von `std.system` gilt für die gesamte Unit.
4.  **Sichtbarkeitsmodifikatoren:** Es werden `private`, `protected` und `public` (statt `pub`) verwendet, um FreePascal-Konventionen zu folgen.

---

## Detaillierter Implementierungsplan

### 1. `std/system.lyx` erstellen

**Ziel:** Definition der Basisklasse `TObject` und grundlegender System-Aliase.

**Datei:** `std/system.lyx`

**Inhalt:**
```lyx
// std/system.lyx
// Basis-System-Unit für alle Lyx-Programme.
// Enthält die Wurzelklasse TObject und grundlegende System-Aliase.

unit std.system;

// ====================================================================
// System-Aliase für Handles
// ====================================================================

// Repräsentiert einen generischen System-Handle (z.B. Dateideskriptor, Socket).
// Verwendet int64 für Kompatibilität mit dem primären Integer-Typ von Lyx.
type Handle = int64;

// Spezieller Alias für Dateideskriptoren.
type FD = int64;

// ====================================================================
// TObject - Die Wurzelklasse der Objekthierarchie
// ====================================================================

// TObject ist die Basisklasse für alle anderen Klassen in Lyx.
// Sie bietet grundlegende Verhaltensweisen wie Objekt-Erzeugung und -Zerstörung.
type TObject = class {
  // Der Konstruktor für TObject.
  // Hier werden keine spezifischen Syscalls für die Speicherallokation durchgeführt,
  // da dies vom 'new'-Operator des Compilers gehandhabt wird.
  // Dient als Platzhalter für grundlegende Initialisierung.
  fn Create() {
    // Implementierung des Konstruktors (Platzhalter)
    // E.g., setup VMT pointer here in future
  }

  // Der Destruktor für TObject.
  // Wird vom 'dispose'-Statement des Compilers aufgerufen.
  // Dient als Platzhalter für Aufräumarbeiten.
  fn Destroy() {
    // Implementierung des Destruktors (Platzhalter)
    // E.g., tear down VMT pointer or release resources here in future
  }
};
```

**TODOs:**
- [ ] Erstelle die Datei `std/system.lyx` mit dem oben genannten Inhalt.

---

### 2. Compiler-Frontend (parser.pas) Änderungen

**Ziel:** Impliziter Import von `std.system` und Implementierung der 'Auto-Inheritance'.

#### 2.1 Impliziter Import von `std.system`

**Betroffene Datei:** `frontend/parser.pas`

**Anpassung:** In der Methode `TParser.ParseProgram`, nach der optionalen Unit-Deklaration und vor dem Parsen der expliziten Import-Deklarationen, wird ein `TAstImportDecl`-Knoten für `std.system` zur Liste der Top-Level-Deklarationen hinzugefügt.

**Code-Änderung (in `parser.pas`):**

```pascal
// In TParser.ParseProgram, vor der while-Schleife für tkImport:
// ...
  // optional unit declaration
  if Check(tkUnit) then
  begin
    d := ParseUnitDecl;
    if d <> nil then
    begin
      SetLength(decls, Length(decls) + 1);
      decls[High(decls)] := d;
    end;
  end;

  // Impliziter Import von std.system (immer zuerst)
  var implicitImportSpan: TSourceSpan;
  implicitImportSpan := MakeSpan(1, 1, 0, ''); // Dummy-Span für den impliziten Import
  d := TAstImportDecl.Create('std.system', '', nil, implicitImportSpan);
  SetLength(decls, Length(decls) + 1);
  decls[High(decls)] := d;

  // import declarations
  while Check(tkImport) do
  begin
// ...
```

**TODOs:**
- [ ] Füge den Code für den impliziten Import in `TParser.ParseProgram` in `frontend/parser.pas` ein.

#### 2.2 'Auto-Inheritance' für Klassen

**Betroffene Datei:** `frontend/parser.pas`

**Anpassung:** In der Methode `TParser.ParseTypeDecl`, im Codeblock, der eine `class`-Deklaration verarbeitet, wird `baseClassName` auf `'TObject'` gesetzt, falls keine `extends`-Klausel vorhanden ist.

**Code-Änderung (in `parser.pas`):**

```pascal
// In TParser.ParseTypeDecl, innerhalb des tkClass-Branches:
// ...
  // class [extends BaseClass] { ... }
  if Check(tkClass) then
  begin
    Advance; // class
    baseClassName := ''; // Initialisierung
    // Check for extends
    if Check(tkExtends) then
    begin
      Advance; // extends
      if Check(tkIdent) then
      begin
        baseClassName := FCurTok.Value;
        Advance;
      end
      else
        FDiag.Error('expected base class name after ''extends''', FCurTok.Span);
    end
    else
      // AUTO-INHERITANCE: Wenn kein 'extends' angegeben ist, ist die Basisklasse 'TObject'.
      baseClassName := 'TObject';
// ... Rest der Funktion ...
    Result := TAstClassDecl.Create(name, baseClassName, fields, methods, isPub, FCurTok.Span);
    Exit;
  end;
// ...
```

**TODOs:**
- [ ] Implementiere die Auto-Inheritance-Logik in `TParser.ParseTypeDecl` in `frontend/parser.pas`.

---

### 3. Sichtbarkeits-Parsing

**Ziel:** Unterstützung der Sichtbarkeitsmodifikatoren `private`, `protected`, `public` in Klassen und Speicherung im AST.

#### 3.1 `lexer.pas` anpassen

**Betroffene Datei:** `frontend/lexer.pas`

**Anpassung:** Ersetze `tkPub` durch `tkPublic` in der Definition von `TTokenKind`.

**Code-Äänderung (in `lexer.pas` oder der globalen Token-Definition):**
```pascal
// In der Definition von TTokenKind:
TTokenKind = (..., tkPrivate, tkProtected, tkPublic, ...); // tkPub entfernen
```
**(Hinweis: Da die Definition von `TTokenKind` nicht in den bereitgestellten Dateien ist, muss diese Änderung in der entsprechenden Datei vorgenommen werden, die `lexer.pas` verwendet oder die Tokens definiert.)**

**TODOs:**
- [ ] Ersetze `tkPub` durch `tkPublic` in der Token-Definition (vermutlich in `lexer.pas`).

#### 3.2 `parser.pas` anpassen

**Betroffene Datei:** `frontend/parser.pas`

**Anpassung:** Die Methode `TParser.ParseVisibility` wird angepasst, um `tkPublic` korrekt zu erkennen. Die bereits vorhandene Logik zum Zuweisen der `FVisibility`-Felder in `TAstFuncDecl` und `TStructField` ist korrekt.

**Code-Änderung (in `parser.pas`):**

```pascal
// In TParser.ParseVisibility:
function TParser.ParseVisibility: TVisibility;
begin
  Result := visPublic; // default
  if Accept(tkPrivate) then
    Result := visPrivate
  else if Accept(tkProtected) then
    Result := visProtected
  else if Accept(tkPublic) then // tkPub durch tkPublic ersetzt
    Result := visPublic;
end;
```

**TODOs:**
- [ ] Aktualisiere `TParser.ParseVisibility` in `frontend/parser.pas`, um `tkPublic` zu unterstützen.

---

### 4. Namenskonvention-Warnung

**Ziel:** Erzeugung einer Warnung, wenn ein Klassenname nicht mit 'T' beginnt.

**Betroffene Datei:** `frontend/parser.pas`

**Anpassung:** Direkt nach dem Parsen des Klassennamens in `TParser.ParseTypeDecl` wird eine Überprüfung eingefügt. Da `FCurTok.Span` nach dem `Advance` bereits auf das nächste Token zeigt, müssen wir den Span des Klassennamens selbst verwenden.

**Code-Änderung (in `parser.pas`):**

```pascal
// In TParser.ParseTypeDecl, innerhalb des tkClass-Branches, nach dem Parsen des Klassennamens:
// ...
          if Check(tkIdent) then
          begin
            name := FCurTok.Value;
            var classNameSpan: TSourceSpan := FCurTok.Span; // Speichere den Span des Klassennamens
            Advance;
            // Prüfung der Namenskonvention: Klassenname sollte mit 'T' beginnen
            if (Length(name) > 0) and (name[1] <> 'T') then
              FDiag.Report(dkWarning, 'Class name ''' + name + ''' should start with ''T'' (naming convention)', classNameSpan); // Nutze den gespeicherten Span
          end
          else
          begin
            name := '<anon>';
            FDiag.Error('expected type name', FCurTok.Span);
          end;
// ...
```

**TODOs:**
- [ ] Implementiere die Namenskonventionsprüfung und Warnung in `TParser.ParseTypeDecl` in `frontend/parser.pas`.

---

## Nächste Schritte

Sobald diese Änderungen implementiert sind, werden wir:
1.  Die Änderungen kompilieren (`fpc -O2 -Mobjfpc -Sh lyxc.lpr -olyxc`).
2.  Bestehende Tests ausführen (`make test`).
3.  Neue spezifische Tests für die Auto-Inheritance, Sichtbarkeitsmodifikatoren und Namenskonventionswarnung erstellen und ausführen.

Dies stellt sicher, dass die neuen Funktionen korrekt arbeiten und keine Regressionen in bestehenden Bereichen verursacht werden.
