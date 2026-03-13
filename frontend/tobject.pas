{$mode objfpc}{$H+}
unit tobject;

{ TObject - Implizite Basisklasse für alle Lyx-Klassen
  
  Diese Unit definiert die eingebaute TObject-Klasse, die als Wurzel der
  Klassenhierarchie dient. Jede Klasse ohne explizites 'extends' erbt 
  automatisch von TObject.
  
  VMT-Layout mit RTTI:
  =====================
  Offset -16: Parent VMT Pointer (für InheritsFrom)
  Offset -8:  ClassName Pointer (pchar, null-terminiert)
  Offset  0:  Methode 0 (Destroy)
  Offset  8:  Methode 1 (Free)
  Offset 16:  Methode 2 (ClassName)
  ... weitere virtuelle Methoden
  
  Instanz-Layout:
  ===============
  Offset 0: VMT Pointer (zeigt auf Offset 0 der VMT)
  Offset 8+: Felder der Klasse
}

interface

uses
  ast, diag;

const
  { TObject VMT Indizes }
  VMT_INDEX_DESTROY   = 0;
  VMT_INDEX_FREE      = 1;
  VMT_INDEX_CLASSNAME = 2;
  VMT_INDEX_INHERITSFROM = 3;
  
  { VMT Header Offsets (negative Offsets relativ zu VMT-Basis) }
  VMT_OFFSET_PARENT_VMT   = -16;  // Pointer auf Parent-Klasse VMT
  VMT_OFFSET_CLASSNAME    = -8;   // Pointer auf Klassennamen (pchar)
  
  { TObject Klassenname }
  TOBJECT_CLASSNAME = 'TObject';

{ Erstellt die eingebaute TObject-Klassendefinition als AST-Knoten }
function CreateTObjectClassDecl: TAstClassDecl;

{ Prüft ob eine Klasse TObject ist }
function IsTObject(cd: TAstClassDecl): Boolean;

{ Gibt den Namen der impliziten Basisklasse zurück (TObject) }
function GetImplicitBaseClass: string;

implementation

function GetImplicitBaseClass: string;
begin
  Result := TOBJECT_CLASSNAME;
end;

function IsTObject(cd: TAstClassDecl): Boolean;
begin
  Result := Assigned(cd) and (cd.Name = TOBJECT_CLASSNAME);
end;

function CreateTObjectClassDecl: TAstClassDecl;
var
  fields: TStructFieldList;
  methods: TMethodList;
  destroyMethod, freeMethod, classNameMethod, inheritsFromMethod: TAstFuncDecl;
  emptyParams: TAstParamList;
  emptyBlock: TAstBlock;
  emptyStmts: TAstStmtList;
  inheritsFromParams: TAstParamList;
begin
  // TObject hat keine Felder
  SetLength(fields, 0);
  
  // Leere Parameter-Liste
  SetLength(emptyParams, 0);
  
  // Leerer Body für virtuelle Methoden (werden vom Backend speziell behandelt)
  SetLength(emptyStmts, 0);
  emptyBlock := TAstBlock.Create(emptyStmts, NullSpan);
  
  // Destroy - virtueller Destruktor
  destroyMethod := TAstFuncDecl.Create('Destroy', emptyParams, atVoid, 
    TAstBlock.Create(emptyStmts, NullSpan), NullSpan, False);
  destroyMethod.IsVirtual := True;
  destroyMethod.VirtualTableIndex := VMT_INDEX_DESTROY;
  
  // Free - ruft Destroy auf und gibt Speicher frei (nicht virtual, aber eingebaut)
  freeMethod := TAstFuncDecl.Create('Free', emptyParams, atVoid,
    TAstBlock.Create(emptyStmts, NullSpan), NullSpan, False);
  freeMethod.IsVirtual := True;  // Auch virtual für konsistente VMT
  freeMethod.VirtualTableIndex := VMT_INDEX_FREE;
  
  // ClassName - gibt den Klassennamen als pchar zurück
  classNameMethod := TAstFuncDecl.Create('ClassName', emptyParams, atPChar,
    TAstBlock.Create(emptyStmts, NullSpan), NullSpan, False);
  classNameMethod.IsVirtual := True;
  classNameMethod.VirtualTableIndex := VMT_INDEX_CLASSNAME;
  
  // InheritsFrom - prüft ob diese Klasse von einer anderen erbt
  // Parameter: className: pchar
  // Rückgabe: bool
  SetLength(inheritsFromParams, 1);
  inheritsFromParams[0].Name := 'className';
  inheritsFromParams[0].ParamType := atPChar;
  inheritsFromParams[0].Span := NullSpan;
  inheritsFromMethod := TAstFuncDecl.Create('InheritsFrom', inheritsFromParams, atBool,
    TAstBlock.Create(emptyStmts, NullSpan), NullSpan, False);
  inheritsFromMethod.IsVirtual := True;
  inheritsFromMethod.VirtualTableIndex := VMT_INDEX_INHERITSFROM;
  
  // Methoden-Array
  SetLength(methods, 4);
  methods[0] := destroyMethod;
  methods[1] := freeMethod;
  methods[2] := classNameMethod;
  methods[3] := inheritsFromMethod;
  
  // TObject-Klasse erstellen (keine Basisklasse - leerer String)
  Result := TAstClassDecl.Create(TOBJECT_CLASSNAME, '', fields, methods, True, NullSpan);
  
  // VMT Name setzen
  Result.VMTName := '_vmt_' + TOBJECT_CLASSNAME;
  
  // VMT initialisieren
  Result.VirtualMethods := methods;
end;

end.
