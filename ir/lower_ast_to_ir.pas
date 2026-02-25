{$mode objfpc}{$H+}
unit lower_ast_to_ir;

interface

uses
  SysUtils, Classes,
  ast, ir, diag, lexer, unit_manager;

type
  TConstValue = class
  public
    IsStr: Boolean;
    IntVal: Int64;
    StrVal: string;
  end;

  TIRLowering = class
  private
    FModule: TIRModule;
    FCurrentFunc: TIRFunction;
    FCurrentFuncDecl: TAstFuncDecl;  // current AST function being lowered (for return type info)
    FCurrentClassDecl: TAstClassDecl; // current class being lowered (for super calls)
    FDiag: TDiagnostics;
    FTempCounter: Integer;
    FLabelCounter: Integer;
    FLocalMap: TStringList; // name -> local index (as object integer)
    FLocalTypes: array of TAurumType; // index -> declared local type
    FLocalElemSize: array of Integer; // index -> element size in bytes for dynamic array locals (0 if not array)
    FLocalIsStruct: array of Boolean; // index -> true if this local is a struct (need address, not value)
    FLocalSlotCount: array of Integer; // index -> number of slots this variable occupies (for structs)
    FLocalArrayLen: array of Integer; // index -> array length (0 if not a static array)
    FLocalTypeNames: array of string; // index -> type name for classes (for destructor lookup)
    FConstMap: TStringList; // name -> TConstValue (compile-time constants)
    FLocalConst: array of TConstValue; // per-function local constant values (or nil)
    FBreakStack: TStringList; // stack of break labels
    FStructTypes: TStringList; // struct name -> TAstStructDecl (as object)
    FClassTypes: TStringList; // class name -> TAstClassDecl (as object)
    FGlobalVars: TStringList; // global variable name -> TAstVarDecl (as object)
    FExternFuncs: TStringList; // names of extern fn declarations
    FImportedFuncs: TStringList; // names of functions from imported units

    function NewTemp: Integer;
    function IsGlobalVar(const name: string): Boolean;
    function GetGlobalVarDecl(const name: string): TAstVarDecl;
    function NewLabel(const prefix: string): string;
    function AllocLocal(const name: string; aType: TAurumType): Integer;
    function AllocLocalMany(const name: string; aType: TAurumType; count: Integer; isStruct: Boolean = False): Integer;
    function GetLocalType(idx: Integer): TAurumType;
    function GetLocalArrayLen(idx: Integer): Integer;
    function ResolveLocal(const name: string): Integer;
    procedure Emit(instr: TIRInstr);

    function LowerStmt(stmt: TAstStmt): Boolean;
    function LowerExpr(expr: TAstExpr): Integer; // returns temp index
    function LowerStructLit(sl: TAstStructLit): Integer; // returns temp with struct address
    procedure LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
    function GetReturnStructDecl: TAstStructDecl; // get struct decl for current func's return type
  public
    constructor Create(modul: TIRModule; diag: TDiagnostics);
    destructor Destroy; override;

    function Lower(prog: TAstProgram): TIRModule;
    procedure LowerImportedUnits(um: TUnitManager);
  end;

implementation

{ Helpers }

function IntToObj(i: Integer): TObject;
begin
  Result := TObject(Pointer(i));
end;

function ObjToInt(o: TObject): Integer;
begin
  Result := Integer(Pointer(o));
end;

{ TIRLowering }

constructor TIRLowering.Create(modul: TIRModule; diag: TDiagnostics);
  begin
    inherited Create;
    FModule := modul;
    FDiag := diag;
    FCurrentFuncDecl := nil;
    FCurrentClassDecl := nil;
    FTempCounter := 0;
    FLabelCounter := 0;
    FLocalMap := TStringList.Create;
    FLocalMap.Sorted := False;
    FConstMap := TStringList.Create;
    FConstMap.Sorted := False;
    FBreakStack := TStringList.Create;
    FBreakStack.Sorted := False;
    FStructTypes := TStringList.Create;
    FStructTypes.Sorted := False;
    FClassTypes := TStringList.Create;
    FClassTypes.Sorted := False;
    FGlobalVars := TStringList.Create;
    FGlobalVars.Sorted := False;
    FExternFuncs := TStringList.Create;
    FExternFuncs.Sorted := True;
    FExternFuncs.Duplicates := dupIgnore;
    FImportedFuncs := TStringList.Create;
    FImportedFuncs.Sorted := True;
    FImportedFuncs.Duplicates := dupIgnore;
    SetLength(FLocalTypes, 0);
    SetLength(FLocalElemSize, 0);
    SetLength(FLocalIsStruct, 0);
    SetLength(FLocalSlotCount, 0);
    SetLength(FLocalConst, 0);
    SetLength(FLocalTypeNames, 0);
  end;


destructor TIRLowering.Destroy;
var
  i: Integer;
begin
  FLocalMap.Free;
  for i := 0 to FConstMap.Count - 1 do
    TObject(FConstMap.Objects[i]).Free;
  FConstMap.Free;
  for i := 0 to Length(FLocalConst)-1 do
    if Assigned(FLocalConst[i]) then FLocalConst[i].Free;
  SetLength(FLocalConst, 0);
  SetLength(FLocalIsStruct, 0);
  SetLength(FLocalTypeNames, 0);
  FBreakStack.Free;
  // Don't free objects in FStructTypes/FClassTypes/FGlobalVars - they belong to the AST
  FStructTypes.Free;
  FClassTypes.Free;
  FGlobalVars.Free;
  FExternFuncs.Free;
  FImportedFuncs.Free;
  inherited Destroy;
end;

function TIRLowering.IsGlobalVar(const name: string): Boolean;
begin
  Result := FGlobalVars.IndexOf(name) >= 0;
end;

function TIRLowering.GetGlobalVarDecl(const name: string): TAstVarDecl;
var
  idx: Integer;
begin
  idx := FGlobalVars.IndexOf(name);
  if idx >= 0 then
    Result := TAstVarDecl(FGlobalVars.Objects[idx])
  else
    Result := nil;
end;


function TIRLowering.NewTemp: Integer;
begin
  Result := FTempCounter;
  Inc(FTempCounter);
end;

function TIRLowering.NewLabel(const prefix: string): string;
begin
  Result := Format('%s_%d', [prefix, FLabelCounter]);
  Inc(FLabelCounter);
end;

function TIRLowering.AllocLocal(const name: string; aType: TAurumType): Integer;
var
  idx: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
  begin
    Result := ObjToInt(FLocalMap.Objects[idx]);
    Exit;
  end;
  Result := FCurrentFunc.LocalCount;
  FCurrentFunc.LocalCount := FCurrentFunc.LocalCount + 1;
  FLocalMap.AddObject(name, IntToObj(Result));
  // ensure FLocalTypes has same length
  SetLength(FLocalTypes, FCurrentFunc.LocalCount);
  FLocalTypes[Result] := aType;
  // ensure FLocalElemSize has same length and initialize to 0
  SetLength(FLocalElemSize, FCurrentFunc.LocalCount);
  FLocalElemSize[Result] := 0;
  // ensure FLocalIsStruct has same length and initialize to false
  SetLength(FLocalIsStruct, FCurrentFunc.LocalCount);
  FLocalIsStruct[Result] := False;
  // ensure FLocalTypeNames has same length and initialize to empty
  SetLength(FLocalTypeNames, FCurrentFunc.LocalCount);
  FLocalTypeNames[Result] := '';
end;

function TIRLowering.AllocLocalMany(const name: string; aType: TAurumType; count: Integer; isStruct: Boolean = False): Integer;
var
  idx, i, base: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
  begin
    Result := ObjToInt(FLocalMap.Objects[idx]);
    Exit;
  end;
  base := FCurrentFunc.LocalCount;
  FCurrentFunc.LocalCount := FCurrentFunc.LocalCount + count;
  FLocalMap.AddObject(name, IntToObj(base));
  // ensure FLocalTypes has same length
  SetLength(FLocalTypes, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalTypes[base + i] := aType;
  // ensure FLocalElemSize has same length and initialize entries to 0
  SetLength(FLocalElemSize, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalElemSize[base + i] := 0;
  // ensure FLocalIsStruct has same length
  SetLength(FLocalIsStruct, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalIsStruct[base + i] := isStruct and (i = 0); // only mark first slot as struct
  // ensure FLocalSlotCount has same length
  SetLength(FLocalSlotCount, FCurrentFunc.LocalCount);
  FLocalSlotCount[base] := count; // store slot count on first slot
  for i := 1 to count - 1 do
    FLocalSlotCount[base + i] := 0; // other slots don't need count
  // ensure FLocalTypeNames has same length
  SetLength(FLocalTypeNames, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalTypeNames[base + i] := '';
  // ensure FLocalArrayLen has same length - store array length on first slot
  SetLength(FLocalArrayLen, FCurrentFunc.LocalCount);
  if (not isStruct) and (count > 1) then
    FLocalArrayLen[base] := count  // this is an array
  else
    FLocalArrayLen[base] := 0;     // not an array
  for i := 1 to count - 1 do
    FLocalArrayLen[base + i] := 0;
  Result := base;
end;

function TIRLowering.GetLocalType(idx: Integer): TAurumType;
begin
  if (idx >= 0) and (idx < Length(FLocalTypes)) then
    Result := FLocalTypes[idx]
  else
    Result := atUnresolved;
end;

function TIRLowering.GetLocalArrayLen(idx: Integer): Integer;
begin
  if (idx >= 0) and (idx < Length(FLocalArrayLen)) then
    Result := FLocalArrayLen[idx]
  else
    Result := 0;
end;

procedure TIRLowering.Emit(instr: TIRInstr);
begin
  if not Assigned(FCurrentFunc) then
    Exit;
  FCurrentFunc.Emit(instr);
end;

{ Lowering main entry }

function TIRLowering.Lower(prog: TAstProgram): TIRModule;
var
  i: Integer;
  fn: TIRFunction;
  node: TAstNode;
  j: Integer;
  k: Integer;
  m: TAstFuncDecl;
  mangled: string;
  cv: TConstValue;
  instr: TIRInstr;
  items: TAstExprList;
  vals: array of Int64;
begin
  instr := Default(TIRInstr);
  // First pass: collect all struct, class, and global variable declarations
  FStructTypes.Clear;
  FClassTypes.Clear;
  FGlobalVars.Clear;
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstStructDecl then
      FStructTypes.AddObject(TAstStructDecl(node).Name, TObject(node))
    else if node is TAstClassDecl then
    begin
      // Classes are stored in both maps - they have the same field layout logic
      FStructTypes.AddObject(TAstClassDecl(node).Name, TObject(node));
      FClassTypes.AddObject(TAstClassDecl(node).Name, TObject(node));
    end
    else if node is TAstVarDecl then
    begin
      // Global variable declaration
      if TAstVarDecl(node).IsGlobal then
      begin
        FGlobalVars.AddObject(TAstVarDecl(node).Name, TObject(node));
        // Register in module with init value
        if TAstVarDecl(node).InitExpr is TAstIntLit then
        begin
          FModule.AddGlobalVar(TAstVarDecl(node).Name, TAstIntLit(TAstVarDecl(node).InitExpr).Value, True);
        end
        else if TAstVarDecl(node).InitExpr is TAstArrayLit then
        begin
          // collect integer items if possible
          items := TAstArrayLit(TAstVarDecl(node).InitExpr).Items;
          SetLength(vals, 0);
          for k := 0 to High(items) do
          begin
            if items[k] is TAstIntLit then
            begin
              SetLength(vals, Length(vals) + 1);
              vals[High(vals)] := TAstIntLit(items[k]).Value;
            end
            else
            begin
              // non-integer array initializers not supported for global arrays yet
              SetLength(vals, 0);
              Break;
            end;
          end;
          if (Length(vals) > 0) then
            FModule.AddGlobalArray(TAstVarDecl(node).Name, vals)
          else
            FModule.AddGlobalVar(TAstVarDecl(node).Name, 0, False);
        end
        else
          FModule.AddGlobalVar(TAstVarDecl(node).Name, 0, False);
      end;
    end;
  end;

  // iterate top-level decls, create functions
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstFuncDecl then
    begin
       // Skip extern function declarations (no body to lower)
       if TAstFuncDecl(node).IsExtern then
       begin
         // Register as extern so call sites can set cmExternal
         FExternFuncs.Add(TAstFuncDecl(node).Name);
         Continue;
       end;
       fn := FModule.AddFunction(TAstFuncDecl(node).Name);
       // Lower function body
       FCurrentFunc := fn;
       FCurrentFuncDecl := TAstFuncDecl(node);
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for j := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[j]) then
            FLocalConst[j].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
       fn.ParamCount := Length(TAstFuncDecl(node).Params);
       fn.LocalCount := fn.ParamCount;
       SetLength(FLocalTypes, fn.LocalCount);
       SetLength(FLocalConst, fn.LocalCount);
       for j := 0 to fn.ParamCount - 1 do
       begin
         FLocalMap.AddObject(TAstFuncDecl(node).Params[j].Name, IntToObj(j));
         FLocalTypes[j] := TAstFuncDecl(node).Params[j].ParamType;
         FLocalConst[j] := nil;
       end;

       // lower statements sequentially
       for j := 0 to High(TAstFuncDecl(node).Body.Stmts) do
       begin
         LowerStmt(TAstFuncDecl(node).Body.Stmts[j]);
       end;
       
       // Emit implicit return for void functions if last statement wasn't a return
       if (Length(FCurrentFunc.Instructions) = 0) or 
          (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irReturn) then
       begin
         instr.Op := irReturn;
         instr.Src1 := -1;
         Emit(instr);
       end;
       
       FCurrentFunc := nil;
       FCurrentFuncDecl := nil;
    end
    else if node is TAstStructDecl then
    begin
      // Lower each method as a top-level mangled function: _L_<Struct>_<Method>
      for j := 0 to High(TAstStructDecl(node).Methods) do
      begin
        m := TAstStructDecl(node).Methods[j];
        mangled := '_L_' + TAstStructDecl(node).Name + '_' + m.Name;
        // create function
        fn := FModule.AddFunction(mangled);
        FCurrentFunc := fn;
        FCurrentFuncDecl := m;  // set current func decl for return type info
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for k := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[k]) then
            FLocalConst[k].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocalTypes[k] := m.Params[k].ParamType;
            FLocalConst[k] := nil;
            FLocalIsStruct[k] := False;
            FLocalElemSize[k] := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // implicit self param at index 0
          // Note: self is a pointer to struct passed by caller, NOT a struct on stack
          // So we should NOT mark it as FLocalIsStruct - it's already an address
          FLocalMap.AddObject('self', IntToObj(0));
          FLocalTypes[0] := atUnresolved;
          FLocalConst[0] := nil;
          FLocalIsStruct[0] := False; // self holds address, don't use LEA
          FLocalElemSize[0] := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocalTypes[k+1] := m.Params[k].ParamType;
            FLocalConst[k+1] := nil;
            FLocalIsStruct[k+1] := False;
            FLocalElemSize[k+1] := 0;
          end;
        end;
        
        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (Length(FCurrentFunc.Instructions) = 0) or 
           (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irReturn) then
        begin
          instr.Op := irReturn;
          instr.Src1 := -1;
          Emit(instr);
        end;
        
        FCurrentFunc := nil;
        FCurrentFuncDecl := nil;
      end;
    end
    else if node is TAstClassDecl then
    begin
      // Lower each class method as a top-level mangled function: _L_<Class>_<Method>
      FCurrentClassDecl := TAstClassDecl(node); // set for super calls
      for j := 0 to High(TAstClassDecl(node).Methods) do
      begin
        m := TAstClassDecl(node).Methods[j];
        mangled := '_L_' + TAstClassDecl(node).Name + '_' + m.Name;
        // create function
        fn := FModule.AddFunction(mangled);
        FCurrentFunc := fn;
        FCurrentFuncDecl := m;  // set current func decl for return type info
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for k := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[k]) then
            FLocalConst[k].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocalTypes[k] := m.Params[k].ParamType;
            FLocalConst[k] := nil;
            FLocalIsStruct[k] := False;
            FLocalElemSize[k] := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self (pointer to class instance)
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // implicit self param at index 0
          // For classes, self is a pointer (8 bytes), not a struct on stack
          FLocalMap.AddObject('self', IntToObj(0));
          FLocalTypes[0] := atUnresolved;
          FLocalConst[0] := nil;
          FLocalIsStruct[0] := False; // self holds pointer address
          FLocalElemSize[0] := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocalTypes[k+1] := m.Params[k].ParamType;
            FLocalConst[k+1] := nil;
            FLocalIsStruct[k+1] := False;
            FLocalElemSize[k+1] := 0;
          end;
        end;
        
        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (Length(FCurrentFunc.Instructions) = 0) or 
           (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irReturn) then
        begin
          instr.Op := irReturn;
          instr.Src1 := -1;
          Emit(instr);
        end;
        
        FCurrentFunc := nil;
        FCurrentFuncDecl := nil;
      end;
      FCurrentClassDecl := nil; // clear after processing all methods of this class
    end
    else if node is TAstConDecl then
    begin
      // register compile-time constant for inline substitution
      cv := TConstValue.Create;
      if TAstConDecl(node).InitExpr is TAstIntLit then
      begin
        cv.IsStr := False;
        cv.IntVal := TAstIntLit(TAstConDecl(node).InitExpr).Value;
      end
      else if TAstConDecl(node).InitExpr is TAstStrLit then
      begin
        cv.IsStr := True;
        cv.StrVal := TAstStrLit(TAstConDecl(node).InitExpr).Value;
      end
      else if TAstConDecl(node).InitExpr is TAstBoolLit then
      begin
        cv.IsStr := False;
        if TAstBoolLit(TAstConDecl(node).InitExpr).Value then
          cv.IntVal := 1
        else
          cv.IntVal := 0;
      end
      else
      begin
        FDiag.Error('con initializer must be a literal', TAstConDecl(node).Span);
        cv.Free;
        Continue;
      end;
      FConstMap.AddObject(TAstConDecl(node).Name, TObject(cv));
    end;
  end;
  Result := FModule;
end;

procedure TIRLowering.LowerImportedUnits(um: TUnitManager);
{ Lower all functions from imported units }
var
  i, j, k: Integer;
  loadedUnit: TLoadedUnit;
  node: TAstNode;
  fn: TIRFunction;
  unitAST: TAstProgram;
begin
  if not Assigned(um) then Exit;

  for i := 0 to um.Units.Count - 1 do
  begin
    loadedUnit := TLoadedUnit(um.Units.Objects[i]);
    if not Assigned(loadedUnit) or not Assigned(loadedUnit.AST) then
      Continue;

    unitAST := loadedUnit.AST;

    // Lower all function declarations from this unit
    for j := 0 to High(unitAST.Decls) do
    begin
      node := unitAST.Decls[j];
      if node is TAstFuncDecl then
      begin
        // Only lower public functions from imported units
        if not TAstFuncDecl(node).IsPublic then
          Continue;

        // Track as imported function for CallMode resolution
        FImportedFuncs.Add(TAstFuncDecl(node).Name);
        // Check if function already exists (avoid duplicates)
        fn := FModule.FindFunction(TAstFuncDecl(node).Name);
        if not Assigned(fn) then
        begin
          fn := FModule.AddFunction(TAstFuncDecl(node).Name);
          FCurrentFunc := fn;
          FCurrentFuncDecl := TAstFuncDecl(node);
          FLocalMap.Clear;
          // Free old FLocalConst entries before resetting
          for k := 0 to Length(FLocalConst) - 1 do
            if Assigned(FLocalConst[k]) then
              FLocalConst[k].Free;
          SetLength(FLocalConst, 0);
          FTempCounter := 0;
          fn.ParamCount := Length(TAstFuncDecl(node).Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);

          for k := 0 to fn.ParamCount - 1 do
          begin
            FLocalMap.AddObject(TAstFuncDecl(node).Params[k].Name, IntToObj(k));
            FLocalTypes[k] := TAstFuncDecl(node).Params[k].ParamType;
            FLocalConst[k] := nil;
          end;

          // Lower statements
          if Assigned(TAstFuncDecl(node).Body) then
            for k := 0 to High(TAstFuncDecl(node).Body.Stmts) do
              LowerStmt(TAstFuncDecl(node).Body.Stmts[k]);

          FCurrentFunc := nil;
          FCurrentFuncDecl := nil;
        end;
      end;
    end;
  end;
end;

{ Lowering helpers }

// Returns struct decl for current function's return type, or nil if not a struct
function TIRLowering.GetReturnStructDecl: TAstStructDecl;
var
  idx: Integer;
  typeName: string;
begin
  Result := nil;
  if not Assigned(FCurrentFuncDecl) then
    Exit;
  
  typeName := FCurrentFuncDecl.ReturnTypeName;
  if typeName = '' then
    Exit;
  
  // Handle 'Self' (should already be resolved in sema, but just in case)
  if (typeName = 'Self') or (typeName = 'self') then
    Exit; // Can't resolve without struct context here
  
  idx := FStructTypes.IndexOf(typeName);
  if idx >= 0 then
    Result := TAstStructDecl(FStructTypes.Objects[idx]);
end;

function TIRLowering.ResolveLocal(const name: string): Integer;
var
  idx: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
    Result := ObjToInt(FLocalMap.Objects[idx])
  else
    Result := -1;
end;


function TIRLowering.LowerExpr(expr: TAstExpr): Integer;
  var
    instr: TIRInstr;
    loc: Integer;
    tmp: Integer;
    condTmp: Integer;
    t0, t1, t2: Integer;
    i, k: Integer;
    strIdx: Integer;
    cv: TConstValue;
    argCount: Integer;
    argTemps: array of Integer;
    fn: TIRFunction;
    ltype, rType: TAurumType;
    width: Integer;
    w: Integer;
    lit: Int64;
    mask64: UInt64;
    truncated: UInt64;
    half: UInt64;
    signedVal: Int64;
    cvLocal: TConstValue;
    vd: TAstVarDecl;
    items: TAstExprList;
    elemSize: Integer;
    fa: TAstFieldAssign;
    fldOffset: Integer;
    ownerName: string;
    slotCount: Integer;
    baseIdx: Integer;
    isFloatArith: Boolean;
    isFloatCmp: Boolean;
    mangled: string;
    // Null-Coalesce Phase 2
    zeroSlot: Integer;
    resultSlot: Integer;
    cmpSlot: Integer;
    xSlot: Integer;
    ySlot: Integer;
    useRightLabel: string;
    endLabel: string;
    arrLen: Integer;
    baseSlot: Integer;
    // bounds-check temporaries
    gv: TAstVarDecl;
    tZero, tLen, tGe0, tLtLen, tOk: Integer;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl: string;
  begin
  Result := -1;
  if not Assigned(expr) then
    Exit;

  // Initialize instruction
  instr := Default(TIRInstr);

  case expr.Kind of
    nkIntLit:
      begin
        // Emit integer constant
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        instr.ImmInt := TAstIntLit(expr).Value;
        Emit(instr);
        Result := t0;
      end;

    nkStrLit:
      begin
        // Intern string and emit reference
        strIdx := FModule.InternString(TAstStrLit(expr).Value);
        t0 := NewTemp;
        instr.Op := irConstStr;
        instr.Dest := t0;
        instr.ImmStr := IntToStr(strIdx);
        Emit(instr);
        Result := t0;
      end;

    nkRegexLit:
      begin
        // Regex-Literal: like string, store pattern in data section
        // Syntax validation happens in Sema already
        strIdx := FModule.InternString(TAstRegexLit(expr).Pattern);
        t0 := NewTemp;
        instr.Op := irConstStr;
        instr.Dest := t0;
        instr.ImmStr := IntToStr(strIdx);
        Emit(instr);
        Result := t0;
      end;

    nkBoolLit:
      begin
        // Emit boolean as 0 or 1
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        if TAstBoolLit(expr).Value then
          instr.ImmInt := 1
        else
          instr.ImmInt := 0;
        Emit(instr);
        Result := t0;
      end;

    nkFloatLit:
      begin
        // Emit float constant
        t0 := NewTemp;
        instr.Op := irConstFloat;
        instr.Dest := t0;
        instr.ImmFloat := TAstFloatLit(expr).Value;
        Emit(instr);
        Result := t0;
      end;

    nkCharLit:
      begin
        // Emit char as integer constant
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        instr.ImmInt := Ord(TAstCharLit(expr).Value);
        Emit(instr);
        Result := t0;
      end;

    nkIdent:
      begin
        // Check if it's a global variable first
        if IsGlobalVar(TAstIdent(expr).Name) then
        begin
          // Load global variable
          t0 := NewTemp;
          instr.Op := irLoadGlobal;
          instr.Dest := t0;
          instr.ImmStr := TAstIdent(expr).Name;
          Emit(instr);
          Result := t0;
          Exit;
        end;
        
        // Look up local variable
        loc := ResolveLocal(TAstIdent(expr).Name);
        if loc < 0 then
        begin
          // Check if it's a compile-time constant
          i := FConstMap.IndexOf(TAstIdent(expr).Name);
          if i >= 0 then
          begin
            cv := TConstValue(FConstMap.Objects[i]);
            t0 := NewTemp;
            if cv.IsStr then
            begin
              strIdx := FModule.InternString(cv.StrVal);
              instr.Op := irConstStr;
              instr.Dest := t0;
              instr.ImmStr := IntToStr(strIdx);
            end
            else
            begin
              instr.Op := irConstInt;
              instr.Dest := t0;
              instr.ImmInt := cv.IntVal;
            end;
            Emit(instr);
            Result := t0;
          end
          else
          begin
            FDiag.Error('undefined identifier: ' + TAstIdent(expr).Name, expr.Span);
            Exit;
          end;
        end
        else
        begin
          // Check for const-folded local
          if (loc < Length(FLocalConst)) and Assigned(FLocalConst[loc]) then
          begin
            cv := FLocalConst[loc];
            t0 := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := t0;
            instr.ImmInt := cv.IntVal;
            Emit(instr);
            Result := t0;
          end
          else
          begin
            // Check if this local is a struct - if so, load address instead of value
            if (loc < Length(FLocalIsStruct)) and FLocalIsStruct[loc] then
            begin
              // Struct local: load base address for field access
              // Need to know struct size to calculate correct base address
              slotCount := 1;
              if loc < Length(FLocalSlotCount) then
                slotCount := FLocalSlotCount[loc];
              if slotCount < 1 then slotCount := 1;
              
              t0 := NewTemp;
              instr.Op := irLoadStructAddr;
              instr.Dest := t0;
              instr.Src1 := loc;
              instr.StructSize := slotCount * 8; // size in bytes
              Emit(instr);
              Result := t0;
            end
            else
            begin
              // Load local into temp
              t0 := NewTemp;
              instr.Op := irLoadLocal;
              instr.Dest := t0;
              instr.Src1 := loc;
              Emit(instr);
              // If local type is narrower than 64 bits, emit sign- or zero-extend
              ltype := GetLocalType(loc);
              if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64) then
              begin
                width := 64;
                case ltype of
                  atInt8, atUInt8: width := 8;
                  atInt16, atUInt16: width := 16;
                  atInt32, atUInt32: width := 32;
                end;
                if ltype in [atInt8, atInt16, atInt32] then
                begin
                  instr.Op := irSExt; instr.Dest := NewTemp; instr.Src1 := t0; instr.ImmInt := width; Emit(instr);
                  Result := instr.Dest;
                end
                else if ltype in [atUInt8, atUInt16, atUInt32] then
                begin
                  instr.Op := irZExt; instr.Dest := NewTemp; instr.Src1 := t0; instr.ImmInt := width; Emit(instr);
                  Result := instr.Dest;
                end
                else
                  Result := t0;
              end
              else
                Result := t0;
            end; // end else (non-struct local)
          end; // end else (non-const-folded)
        end; // end else (local found)
      end;

    nkBinOp:
      begin
        // Lower left and right operands
        t1 := LowerExpr(TAstBinOp(expr).Left);
        t2 := LowerExpr(TAstBinOp(expr).Right);
        if (t1 < 0) or (t2 < 0) then
          Exit;

        // Determine result type based on operand types
        // Get types from AST
        lType := TAstBinOp(expr).Left.ResolvedType;
        rType := TAstBinOp(expr).Right.ResolvedType;

        // Check if both operands are float
        isFloatArith := (lType = atF64) and (rType = atF64);
        isFloatCmp := isFloatArith and (TAstBinOp(expr).Op in [tkEq, tkNeq, tkLt, tkLe, tkGt, tkGe]);

        t0 := NewTemp;
        case TAstBinOp(expr).Op of
          tkPlus:
            begin
              if isFloatArith then
                instr.Op := irFAdd
              else
                instr.Op := irAdd;
            end;
          tkMinus:
            begin
              if isFloatArith then
                instr.Op := irFSub
              else
                instr.Op := irSub;
            end;
          tkStar:
            begin
              if isFloatArith then
                instr.Op := irFMul
              else
                instr.Op := irMul;
            end;
          tkSlash:
            begin
              if isFloatArith then
                instr.Op := irFDiv
              else
                instr.Op := irDiv;
            end;
          tkPercent: instr.Op := irMod;
          tkEq:
            begin
              if isFloatCmp then
                instr.Op := irFCmpEq
              else
                instr.Op := irCmpEq;
            end;
          tkNeq:
            begin
              if isFloatCmp then
                instr.Op := irFCmpNeq
              else
                instr.Op := irCmpNeq;
            end;
          tkLt:
            begin
              if isFloatCmp then
                instr.Op := irFCmpLt
              else
                instr.Op := irCmpLt;
            end;
          tkLe:
            begin
              if isFloatCmp then
                instr.Op := irFCmpLe
              else
                instr.Op := irCmpLe;
            end;
          tkGt:
            begin
              if isFloatCmp then
                instr.Op := irFCmpGt
              else
                instr.Op := irCmpGt;
            end;
          tkGe:
            begin
              if isFloatCmp then
                instr.Op := irFCmpGe
              else
                instr.Op := irCmpGe;
            end;
          tkAnd:   instr.Op := irAnd;
          tkOr:    instr.Op := irOr;
          tkNor:   instr.Op := irNor;
          tkXor:   instr.Op := irXor;
          tkNullCoalesce:
            begin
              // x ?? y: if x == 0 (null), use y, else use x
              // t1 und t2 sind temporäre IR-Werte. Wir müssen sie zuerst in 
              // lokale Slots speichern, damit irLoadLocal funktioniert.
              
              // Speichere t1 (x) in einen temporären lokalen Slot
              // Wir allozieren einen echten lokalen Slot via NewTemp + erhöhe LocalCount
              xSlot := NewTemp;
              // Reserviere einen lokalen Slot dafür
              if xSlot >= FCurrentFunc.LocalCount then
                FCurrentFunc.LocalCount := xSlot + 1;
              
              instr.Op := irStoreLocal;
              instr.Dest := xSlot;
              instr.Src1 := t1;
              Emit(instr);
              
              // Speichere t2 (y) in einen temporären lokalen Slot
              ySlot := NewTemp;
              if ySlot >= FCurrentFunc.LocalCount then
                FCurrentFunc.LocalCount := ySlot + 1;
              
              instr.Op := irStoreLocal;
              instr.Dest := ySlot;
              instr.Src1 := t2;
              Emit(instr);
              
              // Ergebnis-Slot allozieren
              resultSlot := NewTemp;
              if resultSlot >= FCurrentFunc.LocalCount then
                FCurrentFunc.LocalCount := resultSlot + 1;
              
              // Konstante 0 für den Vergleich
              zeroSlot := NewTemp;
              instr.Op := irConstInt;
              instr.Dest := zeroSlot;
              instr.ImmInt := 0;
              Emit(instr);
              
              // cmpSlot prüfen ob x == 0
              cmpSlot := NewTemp;
              instr.Op := irCmpEq;
              instr.Dest := cmpSlot;
              instr.Src1 := xSlot;
              instr.Src2 := zeroSlot;
              Emit(instr);
              
              // Labels für die Verzweigung
              useRightLabel := NewLabel('Lcoalesce_right');
              endLabel := NewLabel('Lcoalesce_end');
              
              // Wenn x == null (cmpSlot == true), gehe zu use_right
              instr.Op := irBrTrue;
              instr.Src1 := cmpSlot;
              instr.LabelName := useRightLabel;
              Emit(instr);
              
              // x != null, verwende x: result = x
              instr.Op := irLoadLocal;
              instr.Dest := resultSlot;
              instr.Src1 := xSlot;
              Emit(instr);
              
              // Springe zum Ende
              instr.Op := irJmp;
              instr.LabelName := endLabel;
              Emit(instr);
              
              // use_right: y
              instr.Op := irLabel;
              instr.LabelName := useRightLabel;
              Emit(instr);
              
              // result = y
              instr.Op := irLoadLocal;
              instr.Dest := resultSlot;
              instr.Src1 := ySlot;
              Emit(instr);
              
              // end:
              instr.Op := irLabel;
              instr.LabelName := endLabel;
              Emit(instr);
              
              Result := resultSlot;
              Exit;
            end;
        else
          FDiag.Error('unsupported binary operator', expr.Span);
          Exit;
        end;
        instr.Dest := t0;
        instr.Src1 := t1;
        instr.Src2 := t2;
        Emit(instr);
        Result := t0;
      end;

    nkUnaryOp:
      begin
        // Lower operand
        t1 := LowerExpr(TAstUnaryOp(expr).Operand);
        if t1 < 0 then
          Exit;

        t0 := NewTemp;
        case TAstUnaryOp(expr).Op of
          tkMinus:
            begin
              instr.Op := irNeg;
              instr.Dest := t0;
              instr.Src1 := t1;
              Emit(instr);
            end;
          tkNot:
            begin
              instr.Op := irNot;
              instr.Dest := t0;
              instr.Src1 := t1;
              Emit(instr);
            end;
        else
          FDiag.Error('unsupported unary operator', expr.Span);
          Exit;
        end;
        Result := t0;
      end;

    nkCall:
      begin
        // Lower arguments
        argCount := Length(TAstCall(expr).Args);
        SetLength(argTemps, argCount);
        for i := 0 to argCount - 1 do
          argTemps[i] := LowerExpr(TAstCall(expr).Args[i]);

        // Check for builtins (both with and without namespace, e.g., PrintStr and IO.PrintStr)
        // Namespace is already resolved in Sema, so we just check the Name
        if (TAstCall(expr).Name = 'PrintStr') or 
           ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'PrintStr')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintStr';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (TAstCall(expr).Name = 'PrintLn') or 
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'PrintLn')) then
        begin
          // PrintLn: like PrintStr but adds newline
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintLn';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (TAstCall(expr).Name = 'PrintInt') or 
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'PrintInt')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintInt';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (TAstCall(expr).Name = 'printf') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'printf')) then
        begin
          // printf is varargs - emit as generic external call
          instr.Op := irCall;
          instr.Dest := -1;
          instr.ImmStr := 'printf';
          instr.ImmInt := argCount;
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          Emit(instr);
          Result := -1;
        end
        else if (TAstCall(expr).Name = 'getpid') or
                ((TAstCall(expr).Namespace = 'OS') and (TAstCall(expr).Name = 'getpid')) then
        begin
          // getpid() -> int64: returns process ID
          // Use generic external call (like user-defined extern functions)
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := 'getpid';
          instr.ImmInt := 0; // argCount
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, 0);
          Emit(instr);
          Result := t0;
        end
        // === std.io: fd-basierte I/O Syscalls (v0.3.1) ===
        else if (TAstCall(expr).Name = 'open') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'open')) then
        begin
          // open(path: pchar, flags: int64, mode: int64) -> int64 (fd or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'open';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'read') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'read')) then
        begin
          // read(fd: int64, buf: pchar, count: int64) -> int64 (bytes read or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'read';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'write') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'write')) then
        begin
          // write(fd: int64, buf: pchar, count: int64) -> int64 (bytes written or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'write';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'close') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'close')) then
        begin
          // close(fd: int64) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'close';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'lseek') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'lseek')) then
        begin
          // lseek(fd: int64, offset: int64, whence: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'lseek';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'unlink') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'unlink')) then
        begin
          // unlink(path: pchar) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'unlink';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'rename') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'rename')) then
        begin
          // rename(oldpath: pchar, newpath: pchar) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'rename';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'mkdir') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'mkdir')) then
        begin
          // mkdir(path: pchar, mode: int64) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'mkdir';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'rmdir') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'rmdir')) then
        begin
          // rmdir(path: pchar) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'rmdir';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'chmod') or
                ((TAstCall(expr).Namespace = 'IO') and (TAstCall(expr).Name = 'chmod')) then
        begin
          // chmod(path: pchar, mode: int64) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'chmod';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'Random') or
                ((TAstCall(expr).Namespace = 'Math') and (TAstCall(expr).Name = 'Random')) then
        begin
          // Random() -> int64: returns pseudo-random number
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'Random';
          instr.ImmInt := 0;
          SetLength(instr.ArgTemps, 0);
          Emit(instr);
          Result := t0;
        end
        else if (TAstCall(expr).Name = 'RandomSeed') or
                ((TAstCall(expr).Namespace = 'Math') and (TAstCall(expr).Name = 'RandomSeed')) then
        begin
          // RandomSeed(seed) -> void: sets the random seed
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'RandomSeed';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          Emit(instr);
          Result := -1;
        end
        else if ((TAstCall(expr).Name = 'RegexMatch') or
                 ((TAstCall(expr).Namespace = 'Regex') and (TAstCall(expr).Name = 'Match'))) then
        begin
          // RegexMatch(pattern, text) -> bool
          // Use generic external call
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := 'strstr';  // Use libc's strstr
          instr.ImmInt := argCount;
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if ((TAstCall(expr).Name = 'RegexSearch') or
                 ((TAstCall(expr).Namespace = 'Regex') and (TAstCall(expr).Name = 'Search'))) then
        begin
          // RegexSearch(pattern, text) -> int64 (position or -1)
          // Use generic external call
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := 'strstr';
          instr.ImmInt := argCount;
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if ((TAstCall(expr).Name = 'RegexReplace') or
                 ((TAstCall(expr).Namespace = 'Regex') and (TAstCall(expr).Name = 'Replace'))) then
        begin
          // RegexReplace(pattern, text, replacement) -> int64 (count)
          // Use generic external call
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := 'strstr';
          instr.ImmInt := argCount;
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          if argCount >= 3 then instr.Src3 := argTemps[2] else instr.Src3 := -1;
          Emit(instr);
          Result := t0;
        end
        else
        begin
          // Regular function call
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := TAstCall(expr).Name;
          instr.ImmInt := argCount; // Backend needs argCount in ImmInt
          // Determine call mode based on function origin
          if FExternFuncs.IndexOf(TAstCall(expr).Name) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(TAstCall(expr).Name) >= 0 then
            instr.CallMode := cmImported
          else
            instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := t0;
        end;
      end;

    nkIndexAccess:
      begin
        // Check if accessing a global array
        if (TAstIndexAccess(expr).Obj is TAstIdent) and
           IsGlobalVar(TAstIdent(TAstIndexAccess(expr).Obj).Name) then
        begin
          // For global arrays: load the ADDRESS, not the value
          // This is needed because irLoadElem expects a base address
          t0 := NewTemp;
          instr.Op := irLoadGlobalAddr;
          instr.Dest := t0;
          instr.ImmStr := TAstIdent(TAstIndexAccess(expr).Obj).Name;
          Emit(instr);
          t1 := t0;  // t1 now holds the base address

           // Lower index
           t2 := LowerExpr(TAstIndexAccess(expr).Index);
           if t2 < 0 then
             Exit;

           // If global array has known static length, emit bounds check
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAccess(expr).Obj).Name);
           if Assigned(gv) and (gv.ArrayLen > 0) then
           begin
             tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
             tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := gv.ArrayLen; Emit(instr);
             tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
             tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
             tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
             errLbl := NewLabel('Larr_oob');
             instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);
           end;

           // Load element at index
           t0 := NewTemp;
           instr.Op := irLoadElem;
           instr.Dest := t0;
           instr.Src1 := t1;  // array base address
           instr.Src2 := t2;  // index
           Emit(instr);
           Result := t0;

           // Emit error handler if needed
           if Assigned(gv) and (gv.ArrayLen > 0) then
           begin
             instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
             msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
             instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
             codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
             instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
           end;
        end
        else
        begin
          // Local array: need to load ADDRESS of array base, not value
          if TAstIndexAccess(expr).Obj is TAstIdent then
          begin
            loc := ResolveLocal(TAstIdent(TAstIndexAccess(expr).Obj).Name);
            if loc >= 0 then
            begin
              // Array elements are stored in reverse order on stack.
              // arr[0] is at slot loc + arrayLen - 1, arr[arrayLen-1] is at slot loc.
              // Load address of arr[0] (highest slot) so base + index*8 works correctly.
              arrLen := GetLocalArrayLen(loc);
              if arrLen > 0 then
                baseSlot := loc + arrLen - 1  // base address points to arr[0]
              else
                baseSlot := loc;  // fallback for non-array locals
              
              t1 := NewTemp;
              instr.Op := irLoadLocalAddr;
              instr.Dest := t1;
              instr.Src1 := baseSlot;
              Emit(instr);
              
               // Lower index
               t2 := LowerExpr(TAstIndexAccess(expr).Index);
               if t2 < 0 then
                 Exit;

               // If local array has known static length, emit bounds check
               if arrLen > 0 then
               begin
                 tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
                 tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := arrLen; Emit(instr);
                 tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
                 tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
                 tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
                 errLbl := NewLabel('Larr_oob');
                 instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);
               end;

               t0 := NewTemp;
               instr.Op := irLoadElem;
               instr.Dest := t0;
               instr.Src1 := t1;  // array base address
               instr.Src2 := t2;  // index
               Emit(instr);
               Result := t0;

               if arrLen > 0 then
               begin
                 instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
                 msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
                 instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
                 codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
                 instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
               end;
               Exit;
            end;
          end;
          
          // Fallback: use normal LowerExpr for base (for other expression types)
          t1 := LowerExpr(TAstIndexAccess(expr).Obj);
          t2 := LowerExpr(TAstIndexAccess(expr).Index);
          if (t1 < 0) or (t2 < 0) then
            Exit;

          t0 := NewTemp;
          instr.Op := irLoadElem;
          instr.Dest := t0;
          instr.Src1 := t1;  // array base
          instr.Src2 := t2;  // index
          Emit(instr);
          Result := t0;
        end;
      end;

    nkCast:
      begin
        // Type cast: expr as Type
        // First lower the expression
        t1 := LowerExpr(TAstCast(expr).Expr);
        if t1 < 0 then
          Exit;

        // Get source and target types
        ltype := TAstCast(expr).Expr.ResolvedType;
        rType := TAstCast(expr).CastType;

        t0 := NewTemp;

        // Check for int -> float conversion
        if (ltype = atInt64) and (rType = atF64) then
        begin
          instr.Op := irIToF;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        // Check for float -> int conversion
        else if (ltype = atF64) and (rType = atInt64) then
        begin
          instr.Op := irFToI;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        else
        begin
          // No conversion needed, just copy
          instr.Op := irLoadLocal;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end;

        Result := t0;
      end;

    nkFieldAccess:
      begin
        // Lower object
        t1 := LowerExpr(TAstFieldAccess(expr).Obj);
        if t1 < 0 then
          Exit;

        // If sema annotated the field offset on the AST node, use it
        fldOffset := TAstFieldAccess(expr).FieldOffset;
        ownerName := TAstFieldAccess(expr).OwnerName;

        t0 := NewTemp;
        if fldOffset >= 0 then
        begin
          // Check if owner is a class (heap) or struct (stack)
          if (ownerName <> '') and (FClassTypes.IndexOf(ownerName) >= 0) then
          begin
            // Class: use positive offset (heap access)
            instr.Op := irLoadFieldHeap;
            instr.Dest := t0;
            instr.Src1 := t1;
            instr.ImmInt := fldOffset; // positive offset for heap
            Emit(instr);
          end
          else
          begin
            // Struct: use negative offset (stack access)
            instr.Op := irLoadField;
            instr.Dest := t0;
            instr.Src1 := t1;
            instr.ImmInt := fldOffset; // will be negated in backend
            Emit(instr);
          end;
        end
        else
        begin
          // Fallback to name-based access (slower / requires runtime lookup)
          // Assume struct for fallback
          instr.Op := irLoadField;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.LabelName := TAstFieldAccess(expr).Field;
          Emit(instr);
        end;
        Result := t0;
      end;

    nkArrayLit:
      begin
        // Array literals are typically handled in statement context
        // Return first element temp for now (or error)
        if Length(TAstArrayLit(expr).Items) > 0 then
          Result := LowerExpr(TAstArrayLit(expr).Items[0])
        else
          Result := -1;
      end;

    nkStructLit:
      begin
        // Struct literal: TypeName { field1: val1, field2: val2, ... }
        // Allocate stack space for the struct, initialize fields, return address
        Result := LowerStructLit(TAstStructLit(expr));
      end;

    nkNewExpr:
      begin
        // new ClassName() or new ClassName(args) - allocate heap memory for class
        // Look up class type to get size
        i := FStructTypes.IndexOf(TAstNewExpr(expr).ClassName);
        if i < 0 then
        begin
          FDiag.Error('unknown class type: ' + TAstNewExpr(expr).ClassName, expr.Span);
          Exit;
        end;
        
        // Allocate temp for pointer, emit irAlloc with size
        t0 := NewTemp;
        instr.Op := irAlloc;
        instr.Dest := t0;
        // Check if it's a class or struct - they have different layouts
        if FStructTypes.Objects[i] is TAstClassDecl then
          instr.ImmInt := TAstClassDecl(FStructTypes.Objects[i]).Size
        else
          instr.ImmInt := TAstStructDecl(FStructTypes.Objects[i]).Size;
        if instr.ImmInt = 0 then
          instr.ImmInt := 8; // minimum allocation
        Emit(instr);
        
        // If new has arguments, call the Create constructor
        if Length(TAstNewExpr(expr).Args) > 0 then
        begin
          // Build args: [self (t0), original args...]
          argCount := Length(TAstNewExpr(expr).Args);
          SetLength(argTemps, argCount + 1);
          argTemps[0] := t0; // self is the allocated object pointer
          
          // Lower the constructor arguments
          for k := 0 to argCount - 1 do
            argTemps[k + 1] := LowerExpr(TAstNewExpr(expr).Args[k]);
          
          // Emit call to Create constructor
          t1 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irCall;
          instr.Dest := t1;
          instr.ImmStr := '_L_' + TAstNewExpr(expr).ClassName + '_Create';
          instr.ImmInt := argCount + 1; // +1 for self
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount + 1);
          for k := 0 to argCount do
            instr.ArgTemps[k] := argTemps[k];
          Emit(instr);
        end;
        
        Result := t0;
      end;

    nkSuperCall:
      begin
        // super.method(args) - call base class method
        // Requires FCurrentClassDecl to be set (we're in a class method)
        if not Assigned(FCurrentClassDecl) or (FCurrentClassDecl.BaseClassName = '') then
        begin
          FDiag.Error('super call outside of derived class method', expr.Span);
          Result := -1;
          Exit;
        end;
        
        // Find base class in FClassTypes
        baseIdx := FClassTypes.IndexOf(FCurrentClassDecl.BaseClassName);
        if baseIdx < 0 then
        begin
          FDiag.Error('unknown base class: ' + FCurrentClassDecl.BaseClassName, expr.Span);
          Result := -1;
          Exit;
        end;
        
        // Build mangled name: _L_<BaseClass>_<MethodName>
        mangled := '_L_' + FCurrentClassDecl.BaseClassName + '_' + TAstSuperCall(expr).MethodName;
        
        // Build args: [self, originalArgs...]
        argCount := Length(TAstSuperCall(expr).Args);
        SetLength(argTemps, argCount + 1);
        
        // First arg is self (local index 0)
        t0 := NewTemp;
        instr.Op := irLoadLocal;
        instr.Dest := t0;
        instr.Src1 := 0; // self is always at local index 0
        Emit(instr);
        argTemps[0] := t0;
        
        // Lower remaining args
        for i := 0 to argCount - 1 do
          argTemps[i + 1] := LowerExpr(TAstSuperCall(expr).Args[i]);
        
        // Emit call
        t0 := NewTemp;
        instr.Op := irCall;
        instr.Dest := t0;
        instr.ImmStr := mangled;
        instr.ImmInt := argCount + 1; // +1 for self
        instr.CallMode := cmInternal;
        SetLength(instr.ArgTemps, argCount + 1);
        for i := 0 to argCount do
          instr.ArgTemps[i] := argTemps[i];
        Emit(instr);
        Result := t0;
      end;

    nkPanic:
      begin
        // panic(message) - write message to stderr and exit with error code
        // Lower the message expression first
        msgTmp := LowerExpr(TAstPanicExpr(expr).Message);
        if msgTmp < 0 then
          Exit(-1);
        
        // Emit panic instruction with string length info
        instr.Op := irPanic;
        instr.Src1 := msgTmp;
        // Store string length in ImmInt for the backend
        if TAstPanicExpr(expr).Message is TAstStrLit then
          instr.ImmInt := Length(TAstStrLit(TAstPanicExpr(expr).Message).Value)
        else
          instr.ImmInt := 0; // Will need runtime strlen
        Emit(instr);
        
        // panic never returns - emit unreachable code (or just return -1)
        Result := -1;
      end;

  else
    FDiag.Error('lowering: unsupported expression kind', expr.Span);
    Result := -1;
  end;
end;

function TIRLowering.LowerStructLit(sl: TAstStructLit): Integer;
var
  instr: TIRInstr;
  sd: TAstStructDecl;
  baseLoc, slotsNeeded: Integer;
  i, fi, fldOffset, valTemp, addrTemp: Integer;
  fieldName: string;
  fieldFound: Boolean;
begin
  Result := -1;
  instr := Default(TIRInstr);
  
  // Get struct declaration (should have been set by sema)
  sd := sl.StructDecl;
  if not Assigned(sd) then
  begin
    // Try to look it up
    fi := FStructTypes.IndexOf(sl.TypeName);
    if fi < 0 then
    begin
      FDiag.Error('unknown struct type in literal: ' + sl.TypeName, sl.Span);
      Exit;
    end;
    sd := TAstStructDecl(FStructTypes.Objects[fi]);
  end;
  
  // Allocate stack slots for the struct
  slotsNeeded := (sd.Size + 7) div 8;
  if slotsNeeded < 1 then slotsNeeded := 1;
  
  // Use an anonymous name for the temporary struct
  baseLoc := AllocLocalMany('_structlit_' + IntToStr(FTempCounter), atUnresolved, slotsNeeded, True);
  
  // Zero-initialize first slot (other slots will be written to)
  addrTemp := NewTemp;
  instr.Op := irConstInt;
  instr.Dest := addrTemp;
  instr.ImmInt := 0;
  Emit(instr);
  instr.Op := irStoreLocal;
  instr.Dest := baseLoc;
  instr.Src1 := addrTemp;
  Emit(instr);
  
  // Get address of the struct
  addrTemp := NewTemp;
  instr.Op := irLoadLocalAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  Emit(instr);
  
  // Initialize each field from the literal
  for i := 0 to High(sl.Fields) do
  begin
    fieldName := sl.Fields[i].Name;
    fieldFound := False;
    
    // Find field in struct declaration
    for fi := 0 to High(sd.Fields) do
    begin
      if sd.Fields[fi].Name = fieldName then
      begin
        fieldFound := True;
        fldOffset := sd.FieldOffsets[fi];
        
        // Lower the value expression
        valTemp := LowerExpr(sl.Fields[i].Value);
        if valTemp < 0 then Continue;
        
        // Store value at field offset
        instr.Op := irStoreField;
        instr.Src1 := addrTemp;  // base address
        instr.Src2 := valTemp;   // value
        instr.ImmInt := fldOffset;
        Emit(instr);
        
        Break;
      end;
    end;
    
    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;
  
  // Return the address temp
  Result := addrTemp;
end;

procedure TIRLowering.LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
var
  instr: TIRInstr;
  i, fi, fldOffset, valTemp, addrTemp: Integer;
  fieldName: string;
  fieldFound: Boolean;
begin
  instr := Default(TIRInstr);
  
  // Get address of the local struct
  addrTemp := NewTemp;
  instr.Op := irLoadLocalAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  Emit(instr);
  
  // Initialize each field from the literal
  for i := 0 to High(sl.Fields) do
  begin
    fieldName := sl.Fields[i].Name;
    fieldFound := False;
    
    // Find field in struct declaration
    for fi := 0 to High(sd.Fields) do
    begin
      if sd.Fields[fi].Name = fieldName then
      begin
        fieldFound := True;
        fldOffset := sd.FieldOffsets[fi];
        
        // Lower the value expression
        valTemp := LowerExpr(sl.Fields[i].Value);
        if valTemp < 0 then Continue;
        
        // Store value at field offset
        instr.Op := irStoreField;
        instr.Src1 := addrTemp;  // base address
        instr.Src2 := valTemp;   // value
        instr.ImmInt := fldOffset;
        Emit(instr);
        
        Break;
      end;
    end;
    
    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;
end;

function TIRLowering.LowerStmt(stmt: TAstStmt): Boolean;
  var
    instr: TIRInstr;
    loc: Integer;
    tmp: Integer;
    condTmp: Integer;
    t0, t1, t2: Integer;
    thenLabel, elseLabel, endLabel: string;
    whileNode: TAstWhile;
    startLabel, bodyLabel, exitLabel: string;
    i, k: Integer;
    sw: TAstSwitch;
    switchTmp: Integer;
    endLbl, defaultLbl: string;
    caseLabels: TStringList;
    lbl: string;
    caseTmp: Integer;
    ltype: TAurumType;
    width: Integer;
    w: Integer;
    lit: Int64;
    mask64: UInt64;
    truncated: UInt64;
    half: UInt64;
    signedVal: Int64;
    cvLocal: TConstValue;
    vd: TAstVarDecl;
    items: TAstExprList;
    elemSize: Integer;
    fa: TAstFieldAssign;
    retStructDecl: TAstStructDecl;
    call: TAstCall;
    argCount: Integer;
    argTemps: array of Integer;
    ownerName: string;
    mangledName: string;
    arrLen: Integer;
    baseSlot: Integer;
    // bounds-check helpers
    gv: TAstVarDecl;
    tZero, tLen, tGe0, tLtLen, tOk: Integer;
    // assert/panic helpers
    cond, msg: Integer;
    skipLbl: string;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl: string;
  begin
  instr := Default(TIRInstr);
  Result := True;
  // Handle expression statements (e.g., function calls, panic as statement)
  if stmt is TAstExprStmt then
  begin
    // Just lower the expression, discard the result
    LowerExpr(TAstExprStmt(stmt).Expr);
    Exit(True);
  end;

   if stmt is TAstVarDecl then
    begin
      vd := TAstVarDecl(stmt);
      // If ArrayLen not set but InitExpr is an array literal, infer the length
      arrLen := vd.ArrayLen;
      if (arrLen = 0) and (vd.InitExpr is TAstArrayLit) then
        arrLen := Length(TAstArrayLit(vd.InitExpr).Items);
      if arrLen > 0 then
      begin
        // static array: allocate consecutive locals and initialize per-item
        // IMPORTANT: Store elements in REVERSE order so that arr[0] has the 
        // highest slot index. This way, base_addr + index*8 works correctly
        // because stack grows downward.
        loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
        if vd.InitExpr is TAstArrayLit then
        begin
          items := TAstArrayLit(vd.InitExpr).Items;
          if Length(items) <> arrLen then
            FDiag.Error('array literal length mismatch', vd.Span)
          else
          begin
            for i := 0 to High(items) do
            begin
              tmp := LowerExpr(items[i]);
              // store into reversed slot: arr[0] -> highest slot, arr[n-1] -> lowest slot
              instr.Op := irStoreLocal; instr.Dest := loc + (arrLen - 1 - i); instr.Src1 := tmp; Emit(instr);
            end;
          end;
        end
        else
        begin
          // initializer not an array literal: try to lower single expression into first element
          tmp := LowerExpr(vd.InitExpr);
          instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := tmp; Emit(instr);
        end;
        Exit(True);
      end
      else if vd.ArrayLen = -1 then
      begin

        // dynamic array: represent as single local pointer (pchar/int64)
        loc := AllocLocal(vd.Name, atPChar);
        // record element size for this local slot (needed by backend for element addressing)
          begin
            elemSize := 8; // default
            case vd.DeclType of
              atInt8, atUInt8: elemSize := 1;
              atInt16, atUInt16: elemSize := 2;
              atInt32, atUInt32: elemSize := 4;
              atInt64, atUInt64: elemSize := 8;
              atChar: elemSize := 1;
              atPChar: elemSize := 8;
            else
              elemSize := 8; // conservative default
            end;
            if loc >= Length(FLocalElemSize) then SetLength(FLocalElemSize, loc+1);
            FLocalElemSize[loc] := elemSize;
          end;

        // initializer: if empty array literal -> set nil (0)
        if vd.InitExpr is TAstArrayLit then
        begin
          // only allow empty literal for now
          if Length(TAstArrayLit(vd.InitExpr).Items) <> 0 then
            FDiag.Error('cannot initialize dynamic array with non-empty literal', vd.Span);
           // emit const 0 -> store
           t0 := NewTemp;
           instr.Op := irConstInt; instr.Dest := t0; instr.ImmInt := 0; Emit(instr);
           instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := t0; Emit(instr);

        end

       else
       begin
         tmp := LowerExpr(vd.InitExpr);
         instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := tmp; Emit(instr);
       end;
       Exit(True);
     end
      else if (vd.DeclTypeName <> '') and (FStructTypes.IndexOf(vd.DeclTypeName) >= 0) then
      begin
        // Check if this is a class (reference type) or struct (value type)
        i := FStructTypes.IndexOf(vd.DeclTypeName);
        
        // Classes are stored in FStructTypes but are reference types (pointers)
        if FStructTypes.Objects[i] is TAstClassDecl then
        begin
          // Class: allocate 1 slot for pointer, handle new expression
          loc := AllocLocal(vd.Name, atUnresolved);
          // Store the class type name for destructor lookup
          FLocalTypeNames[loc] := vd.DeclTypeName;
          
          // Handle initializer
          if vd.InitExpr is TAstNewExpr then
          begin
            // new ClassName() - already lowered to irAlloc in LowerExpr
            tmp := LowerExpr(vd.InitExpr);
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end
          else
          begin
            // Other initializer (shouldn't happen for classes, but handle gracefully)
            tmp := LowerExpr(vd.InitExpr);
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end
        else
        begin
          // Struct: allocate slots for the whole struct
          // Size is in bytes, each slot is 8 bytes
          if TAstStructDecl(FStructTypes.Objects[i]).Size > 0 then
          begin
            loc := AllocLocalMany(vd.Name, atUnresolved, 
              (TAstStructDecl(FStructTypes.Objects[i]).Size + 7) div 8, True);
          end
          else
          begin
            // fallback: 1 slot
            loc := AllocLocal(vd.Name, atUnresolved);
            FLocalIsStruct[loc] := True;
          end;
          // Initialize based on InitExpr type
          if (vd.InitExpr is TAstIntLit) and (TAstIntLit(vd.InitExpr).Value = 0) then
          begin
            // Zero initialization
            t0 := NewTemp;
            instr.Op := irConstInt; instr.Dest := t0; instr.ImmInt := 0; Emit(instr);
            instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := t0; Emit(instr);
          end
          else if vd.InitExpr is TAstStructLit then
          begin
            // Struct literal: initialize fields directly into the variable's stack slots
            LowerStructLitIntoLocal(TAstStructLit(vd.InitExpr), loc, TAstStructDecl(FStructTypes.Objects[i]));
          end
          else if vd.InitExpr is TAstCall then
          begin
            // Call returning struct: use irCallStruct to handle RAX+RDX properly
            call := TAstCall(vd.InitExpr);
            argCount := Length(call.Args);
            SetLength(argTemps, argCount);
            for k := 0 to argCount - 1 do
              argTemps[k] := LowerExpr(call.Args[k]);
            
            // Emit irCallStruct with struct size info
            instr.Op := irCallStruct;
            instr.Dest := loc;  // destination is the struct variable slot
            instr.ImmStr := call.Name;
            instr.ImmInt := argCount;
            instr.StructSize := TAstStructDecl(FStructTypes.Objects[i]).Size;
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, argCount);
            for k := 0 to argCount - 1 do
              instr.ArgTemps[k] := argTemps[k];
            Emit(instr);
          end;
        end;
        Exit(True);
      end
     else
     begin
       // scalar local
       loc := AllocLocal(vd.Name, vd.DeclType);
       // If initializer is constant integer and the local has narrower signed width, constant fold
       if (vd.InitExpr is TAstIntLit) then
       begin
         lit := TAstIntLit(vd.InitExpr).Value;
         ltype := GetLocalType(loc);
         if (ltype <> atUnresolved) and (ltype <> atInt64) then
         begin
           // determine width in bits
           width := 64;
           case ltype of
             atInt8, atUInt8: width := 8;
             atInt16, atUInt16: width := 16;
             atInt32, atUInt32: width := 32;
             atInt64, atUInt64: width := 64;
           end;
           mask64 := (UInt64(1) shl width) - 1;
           truncated := UInt64(lit) and mask64;
           if (ltype in [atInt8, atInt16, atInt32, atInt64]) then
           begin
             // signed interpretation
             half := UInt64(1) shl (width - 1);
             if truncated >= half then
               signedVal := Int64(truncated) - Int64(UInt64(1) shl width)
             else
               signedVal := Int64(truncated);
             // record local constant for future loads instead of emitting store
             cvLocal := TConstValue.Create;
             cvLocal.IsStr := False;
             cvLocal.IntVal := signedVal;
             if loc >= Length(FLocalConst) then SetLength(FLocalConst, loc+1);
             FLocalConst[loc] := cvLocal;
           end
           else
           begin
             // unsigned: record local constant zero-extended value
             cvLocal := TConstValue.Create;
             cvLocal.IsStr := False;
             cvLocal.IntVal := Int64(truncated);
             if loc >= Length(FLocalConst) then SetLength(FLocalConst, loc+1);
             FLocalConst[loc] := cvLocal;
           end;
           Exit(True);
         end;
       end;
        tmp := LowerExpr(vd.InitExpr);
        // If local has narrower integer width, truncate before store
        ltype := GetLocalType(loc);
        if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64)
           and (ltype <> atPChar) and (ltype <> atPCharNullable) then
        begin
         // determine width in bits
         width := 64;
         case ltype of
           atInt8, atUInt8: width := 8;
           atInt16, atUInt16: width := 16;
           atInt32, atUInt32: width := 32;
           atInt64, atUInt64: width := 64;
         end;
         instr.Op := irTrunc; instr.Dest := NewTemp; instr.Src1 := tmp; instr.ImmInt := width; Emit(instr);
         tmp := instr.Dest;
       end;
       instr.Op := irStoreLocal;
       instr.Dest := loc;
       instr.Src1 := tmp;
       Emit(instr);
       Exit(True);
     end;
   end;


    if stmt is TAstAssign then
    begin
      // Check if it's a global variable assignment
      if IsGlobalVar(TAstAssign(stmt).Name) then
      begin
        tmp := LowerExpr(TAstAssign(stmt).Value);
        instr.Op := irStoreGlobal;
        instr.ImmStr := TAstAssign(stmt).Name;
        instr.Src1 := tmp;
        Emit(instr);
        Exit(True);
      end;
      
      loc := ResolveLocal(TAstAssign(stmt).Name);
      if loc < 0 then
      begin
        FDiag.Error('assignment to undeclared variable: ' + TAstAssign(stmt).Name, stmt.Span);
        Exit(False);
      end;
      // invalidate any const-folded value for this local
      if (loc < Length(FLocalConst)) and Assigned(FLocalConst[loc]) then
      begin
        FLocalConst[loc].Free;
        FLocalConst[loc] := nil;
      end;
      tmp := LowerExpr(TAstAssign(stmt).Value);
      // truncate if local has narrower integer width
      ltype := GetLocalType(loc);
      if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64) 
         and (ltype <> atPChar) and (ltype <> atPCharNullable) then
      begin
        width := 64;
        case ltype of
          atInt8, atUInt8: width := 8;
          atInt16, atUInt16: width := 16;
          atInt32, atUInt32: width := 32;
        end;
        instr.Op := irTrunc; instr.Dest := NewTemp; instr.Src1 := tmp;
        instr.ImmInt := width; Emit(instr);
        tmp := instr.Dest;
      end;
      instr.Op := irStoreLocal;
      instr.Dest := loc;
      instr.Src1 := tmp;
      Emit(instr);
      Exit(True);
    end;

    // field assignment: obj.field := value
      if stmt is TAstFieldAssign then
    begin
      fa := TAstFieldAssign(stmt);
      // target is a TAstFieldAccess node
      t1 := LowerExpr(fa.Target.Obj);
      if t1 < 0 then Exit(False);
      t2 := LowerExpr(fa.Value);
      if t2 < 0 then Exit(False);
      
      // Check if target's owner is a class (heap) or struct (stack)
      ownerName := fa.Target.OwnerName;
      if (ownerName <> '') and (FClassTypes.IndexOf(ownerName) >= 0) then
      begin
        // Class: use positive offset (heap access)
        instr.Op := irStoreFieldHeap;
        instr.Src1 := t1; // base pointer (heap address)
        instr.Src2 := t2; // value temp
        if fa.Target.FieldOffset >= 0 then
          instr.ImmInt := fa.Target.FieldOffset // positive offset for heap
        else
          instr.LabelName := fa.Target.Field;
        Emit(instr);
      end
      else
      begin
        // Struct: use negative offset (stack access)
        instr.Op := irStoreField;
        instr.Src1 := t1; // base pointer
        instr.Src2 := t2; // value temp
        if fa.Target.FieldOffset >= 0 then
          instr.ImmInt := fa.Target.FieldOffset
        else
          instr.LabelName := fa.Target.Field;
        Emit(instr);
      end;
      Exit(True);
    end;

    // index assignment: arr[idx] := value
    if stmt is TAstIndexAssign then
    begin
      // t1 = base array/pointer
      // Check if target is a global array - need address, not value
      if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and
         IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
      begin
        // For global arrays: load the ADDRESS
        t1 := NewTemp;
        instr.Op := irLoadGlobalAddr;
        instr.Dest := t1;
        instr.ImmStr := TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name;
        Emit(instr);
      end
      else
      begin
        // Local array: need to load ADDRESS of array base, not value
        if TAstIndexAssign(stmt).Target.Obj is TAstIdent then
        begin
          loc := ResolveLocal(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
          if loc >= 0 then
          begin
            // Array elements are stored in reverse order on stack.
            // arr[0] is at slot loc + arrayLen - 1, arr[arrayLen-1] is at slot loc.
            // Load address of arr[0] (highest slot) so base + index*8 works correctly.
            arrLen := GetLocalArrayLen(loc);
            if arrLen > 0 then
              baseSlot := loc + arrLen - 1  // base address points to arr[0]
            else
              baseSlot := loc;  // fallback for non-array locals
            
            t1 := NewTemp;
            instr.Op := irLoadLocalAddr;
            instr.Dest := t1;
            instr.Src1 := baseSlot;
            Emit(instr);
          end
          else
          begin
            // Fallback: use normal LowerExpr
            t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
            if t1 < 0 then Exit(False);
          end;
        end
        else
        begin
          // Non-identifier: use normal LowerExpr
          t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
          if t1 < 0 then Exit(False);
        end;
      end;
      
      // t2 = index expression
      t2 := LowerExpr(TAstIndexAssign(stmt).Target.Index);
      if t2 < 0 then Exit(False);
      // t0 = value to store
      t0 := LowerExpr(TAstIndexAssign(stmt).Value);
      if t0 < 0 then Exit(False);

       // check if index is a constant for static vs dynamic store
       if TAstIndexAssign(stmt).Target.Index is TAstIntLit then
       begin
         // static index: use irStoreElem with ImmInt, but first check compile-time bounds if available
         staticIdx := TAstIntLit(TAstIndexAssign(stmt).Target.Index).Value;
         // check global array length
         if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
         begin
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
           if Assigned(gv) and (gv.ArrayLen > 0) and (staticIdx >= gv.ArrayLen) then
           begin
             FDiag.Error('array index out of bounds (static)', stmt.Span);
           end
           else
           begin
             instr.Op := irStoreElem; instr.Src1 := t1; instr.Src2 := t0; instr.ImmInt := staticIdx; Emit(instr);
           end;
         end
         else
         begin
           // local array
           if (loc >= 0) and (GetLocalArrayLen(loc) > 0) and (staticIdx >= GetLocalArrayLen(loc)) then
           begin
             FDiag.Error('array index out of bounds (static)', stmt.Span);
           end
           else
           begin
             instr.Op := irStoreElem; instr.Src1 := t1; instr.Src2 := t0; instr.ImmInt := staticIdx; Emit(instr);
           end;
         end;
       end
       else
       begin
         // dynamic index: attempt runtime bounds check if length known
         gv := nil;
         if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
         if Assigned(gv) and (gv.ArrayLen > 0) then
         begin
           // emit runtime check for global array
           tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
           tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := gv.ArrayLen; Emit(instr);
           tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
           tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
           tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
           errLbl := NewLabel('Larr_oob'); instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);

           instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

           instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
           msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
           instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
           codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
           instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
         end
         else if (loc >= 0) and (GetLocalArrayLen(loc) > 0) then
         begin
           // emit runtime check for local array
           tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
           tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := GetLocalArrayLen(loc); Emit(instr);
           tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
           tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
           tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
           errLbl := NewLabel('Larr_oob'); instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);

           instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

           instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
           msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
           instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
           codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
           instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
         end
         else
         begin
           // no bounds info, emit dynamic store
           instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);
        end;
      end;
      Exit(True);
    end;

    // assert(cond, msg); - expand to if (!cond) { panic(msg); }
    if stmt is TAstAssert then
    begin
      // Lower: if (!condition) panic(message);
      cond := LowerExpr(TAstAssert(stmt).Condition);
      if cond < 0 then Exit(False);
      msg := LowerExpr(TAstAssert(stmt).Message);
      if msg < 0 then Exit(False);

      skipLbl := NewLabel('Lassert_ok');
      // if cond is true, jump to skip (use irBrTrue to jump if condition is true)
      instr := Default(TIRInstr);
      instr.Op := irBrTrue; // jump if true -> skip panic
      instr.Src1 := cond;
      instr.LabelName := skipLbl;
      Emit(instr);

      // panic(msg);
      instr := Default(TIRInstr);
      instr.Op := irPanic;
      instr.Src1 := msg;
      // Store string length in ImmInt for the backend
      if TAstAssert(stmt).Message is TAstStrLit then
        instr.ImmInt := Length(TAstStrLit(TAstAssert(stmt).Message).Value)
      else
        instr.ImmInt := 0; // Will need runtime strlen
      Emit(instr);

      // skip label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := skipLbl;
      Emit(instr);
      Exit(True);
    end;

    if stmt is TAstSwitch then
   begin
     // Lower switch by generating compares and branches
      sw := TAstSwitch(stmt);
      switchTmp := LowerExpr(sw.Expr);
      endLbl := NewLabel('Lswitch_end');
      defaultLbl := endLbl;
      if Assigned(sw.Default) then
        defaultLbl := NewLabel('Lswitch_default');

      // For each case, create label and compare
      caseLabels := TStringList.Create; try
        for i := 0 to High(sw.Cases) do
        begin
          lbl := NewLabel('Lcase');
          caseLabels.Add(lbl);
          // lower case value
          caseTmp := LowerExpr(sw.Cases[i].Value);
          // cmp eq
          instr.Op := irCmpEq; instr.Dest := NewTemp; instr.Src1 := switchTmp; instr.Src2 := caseTmp; Emit(instr);
          // br true -> caseLbl
          instr.Op := irBrTrue; instr.Src1 := instr.Dest; instr.LabelName := lbl; Emit(instr);
        end;


       // no match -> jump default or end
       instr.Op := irJmp; instr.LabelName := defaultLbl; Emit(instr);

       // emit case bodies
       for i := 0 to High(sw.Cases) do
       begin
         instr.Op := irLabel; instr.LabelName := caseLabels[i]; Emit(instr);
         // push break label for cases
         FBreakStack.AddObject(endLbl, nil);
         LowerStmt(sw.Cases[i].Body);
         FBreakStack.Delete(FBreakStack.Count - 1);
         // after case body, jump to end
         instr.Op := irJmp; instr.LabelName := endLbl; Emit(instr);
       end;

       // default body
       if Assigned(sw.Default) then
       begin
         instr.Op := irLabel; instr.LabelName := defaultLbl; Emit(instr);
         FBreakStack.AddObject(endLbl, nil);
         LowerStmt(sw.Default);
         FBreakStack.Delete(FBreakStack.Count - 1);
         instr.Op := irJmp; instr.LabelName := endLbl; Emit(instr);
       end;

       // end label
       instr.Op := irLabel; instr.LabelName := endLbl; Emit(instr);
     finally
       caseLabels.Free;
     end;
     Exit(True);
   end;

   FDiag.Error('lowering: unsupported statement', stmt.Span);
   Result := False;
 end;


end.
