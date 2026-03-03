# Lyx Compiler ToDo Liste

## Aktuelle Aufgaben

*   **Implementierung der `where`-Klausel für Typen**
    *   **Tests:**
        *   Schreibe Unit-Tests für den Parser (um die korrekte Grammatikerkennung zu prüfen).
        *   Schreibe Unit-Tests für die semantische Analyse (um die korrekte Typ-Validierung und Kompilierzeit-Auswertung zu prüfen).

## Abgeschlossene Aufgaben

*   Analyse der `ebnf.md` für die `where`-Klausel-Syntax.
*   Analyse der `frontend/ast.pas` für die AST-Erweiterung.
*   **AST-Implementierung in `ast.pas` und `frontend/ast.pas`:**
    *   Füge `nkConstrainedTypeDecl` zu `TNodeKind` hinzu.
    *   Füge `FConstraint: TAstExpr` zu `TAstTypeDecl` hinzu.
    *   Passe den Konstruktor von `TAstTypeDecl` an, um `FConstraint` zu initialisieren.
    *   Erweitere den Destruktor von `TAstTypeDecl`, um `FConstraint` freizugeben.
    *   Aktualisiere `NodeKindToStr` für `nkConstrainedTypeDecl`.
*   **Lexer-Erweiterung in `frontend/lexer.pas` (Symlink zu `lexer.pas`):**
    *   Füge `tkWhere` Token hinzu.
    *   Füge `tkValue` Token hinzu.
    *   Aktualisiere `TokenKindToStr` und `LookupKeyword`.
*   **Parser-Anpassung in `parser.pas` und `frontend/parser.pas`:**
    *   Implementiere die Logik zum Parsen der `where`-Klausel nach einer Typdeklaration.
    *   Erstelle einen `TAstExpr`-Knoten für die Bedingung (`ConstExpr`).
    *   Übergib diesen `TAstExpr`-Knoten an den `TAstTypeDecl`-Konstruktor.
    *   Behandle `tkValue` als Ausdruck.
*   **Semantische Analyse in `sema.pas` (Vollständige Implementierung):**
    *   Prüfe, ob ein Constraint vorhanden ist.
    *   Prüfe, ob der Ausdruck `bool` zurückgibt.
    *   Ersetze `value` Bezeichner durch den Basistyp.
    *   Behandle `value` als speziellen Bezeichner in CheckExpr.
    *   Implementiere konstante Auswertung zur Kompilierzeit.
    *   Registriere den neuen Typ im Symbol-Table.
*   **Dokumentation:**
    *   Aktualisiere `ebnf.md` mit `where`-Klausel und Keywords.
    *   Aktualisiere `SPEC.md` mit typsicheren Typen.
*   **Verifikation:**
    *   Compiler kann erfolgreich `type Percentage = int64 where { value >= 0 && value <= 100 };` parsen und typisieren.
    *   Compiler meldet Fehler für ungültige Constraints wie `where { false }`.
    *   Compiler kann den neuen Typ in Variablendeklarationen verwenden.
