{$mode objfpc}{$H+}
unit lower_ast_to_ir;

interface

uses
  SysUtils, Classes,
  ast, ir, diag, lexer, unit_manager, tobject, backend_types,
  type_utils;

type
  TConstValue = class
  public
    IsStr: Boolean;
    IntVal: Int64;
    StrVal: string;
  end;

  TLocalVar = record
    VarType:    TAurumType;   // declared type of this local slot
    ElemSize:   Integer;      // element size in bytes for dyn-array locals (0 otherwise)
    IsStruct:   Boolean;      // true if this slot holds a struct (needs address, not value)
    SlotCount:  Integer;      // number of consecutive slots this variable occupies
    ArrayLen:   Integer;      // static array length (0 if not a static array)
    IsDynArray: Boolean;      // true if this local is a dynamic-array fat-pointer
    TypeName:   string;       // type name for class/struct locals (destructor/method lookup)
    ConstVal:   TConstValue;  // compile-time constant value, or nil
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
    FLocals: array of TLocalVar; // per-slot metadata (type, size, flags, const value, ...)
    FConstMap: TStringList; // name -> TConstValue (compile-time constants)
    FBreakStack: TStringList; // stack of break labels
    FContinueStack: TStringList; // stack of continue labels (loop start)
    FStructTypes: TStringList; // struct name -> TAstStructDecl (as object)
    FClassTypes: TStringList; // class name -> TAstClassDecl (as object)
    FRangeTypes: TStringList; // range type name -> TAstTypeDecl (aerospace-todo P1 #7)
    FGlobalVars: TStringList; // global variable name -> TAstVarDecl (as object)
    FExternFuncs: TStringList; // names of extern fn declarations
    FImportedFuncs: TStringList; // names of functions from imported units
    // Generics: monomorphization support
    FGenericFuncs: TStringList;          // name -> TAstFuncDecl
    FGenericSpecializations: TStringList; // mangled name -> already lowered
    FTypeSubstParams: TStringArray;      // type param names for current specialization
    FTypeSubstTypes: array of TAurumType; // concrete types for current specialization
    // Source location tracking for assembly listing (aerospace-todo 6.1)
    FCurrentSourceLine: Integer;
    FCurrentSourceFile: string;
    // Provenance Tracking (WP-F): current AST node being lowered
    FCurrentASTNode: TAstNode;  // current AST node for provenance

    function NewTemp: Integer;
    function IsGlobalVar(const name: string): Boolean;
    function GetGlobalVarDecl(const name: string): TAstVarDecl;
    function NewLabel(const prefix: string): string;
    function AllocLocal(const name: string; aType: TAurumType): Integer;
    function AllocLocalMany(const name: string; aType: TAurumType; count: Integer; isStruct: Boolean = False): Integer;
    function GetLocalType(idx: Integer): TAurumType;
    function InferExprType(expr: TAstExpr): TAurumType;
    function GetLocalArrayLen(idx: Integer): Integer;
    function ResolveLocal(const name: string): Integer;
    procedure Emit(instr: TIRInstr);

    function SubstType(t: TAurumType; const n: string): TAurumType;
    procedure LowerGenericSpecialization(decl: TAstFuncDecl; const mangledName: string;
      const typeArgs: array of TAurumType);
    procedure LowerStructMethodSpec(methodDecl: TAstFuncDecl;
      const mangledName, concreteName: string; concStructDecl: TAstStructDecl;
      const typeParams: TStringArray; const typeArgs: array of TAurumType);

    { Emits IR range-check for value in temp tVal against [rMin..rMax] (aerospace-todo P1 #7) }
    procedure EmitRangeCheck(tVal: Integer; rMin, rMax: Int64; const typeName: string; span: TSourceSpan);

    { Emits runtime float range-check: panics if tVal not in [rMin, rMax) }
    procedure EmitFloatRangeCheck(tVal: Integer; rMin, rMax: Double; const typeName: string; span: TSourceSpan);

    { Emits cyclic wrap math: result = rMin + fmod(tVal - rMin, rMax - rMin), negative-safe.
      Returns a new temp holding the wrapped value. }
    function EmitFloatWrap(tVal: Integer; rMin, rMax: Double; span: TSourceSpan): Integer;

    procedure EmitScopeDrops; // WP9: emit nil-guarded frees for Map/Set locals and struct fields
    function LowerStmt(stmt: TAstStmt): Boolean;
    function LowerSIMDExpr(expr: TAstExpr): Integer; // handles nkSIMD* nodes (lower_simd.inc)
    function LowerExpr(expr: TAstExpr): Integer; // returns temp index
    function LowerStructLit(sl: TAstStructLit): Integer; // returns temp with struct address
    function LowerArrayLit(al: TAstArrayLit): Integer; // returns temp with array base address
    procedure LowerNestedFunc(funcDecl: TAstFuncDecl); // lift nested function to top-level
    procedure LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
    function GetReturnStructDecl: TAstStructDecl; // get struct decl for current func's return type
    procedure EnsureClassLayout(cd: TAstClassDecl); // compute field offsets if not yet done
  public
    constructor Create(modul: TIRModule; diag: TDiagnostics);
    destructor Destroy; override;

    function Lower(prog: TAstProgram): TIRModule;
    procedure LowerImportedUnits(um: TUnitManager);
    procedure PreRegisterConcreteStructs(const entries: TMonoStructMethodList);
    procedure LowerMonoStructMethods(const entries: TMonoStructMethodList);
  end;

implementation

{ Helpers }

function IntToObj(i: Integer): System.TObject;
begin
  Result := System.TObject(Pointer(i));
end;

function ObjToInt(o: System.TObject): Integer;
begin
  Result := Integer(Pointer(o));
end;

{ TypeSizeBytes is now provided by type_utils (via the uses clause above). }

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
    FLocalMap.CaseSensitive := True;
    FConstMap := TStringList.Create;
    FConstMap.Sorted := False;
    FBreakStack := TStringList.Create;
    FBreakStack.Sorted := False;
    FContinueStack := TStringList.Create;
    FContinueStack.Sorted := False;
    FStructTypes := TStringList.Create;
    FStructTypes.Sorted := False;
    FClassTypes := TStringList.Create;
    FClassTypes.Sorted := False;
    FRangeTypes := TStringList.Create;
    FRangeTypes.Sorted := False;
    FGlobalVars := TStringList.Create;
    FGlobalVars.Sorted := False;
    FExternFuncs := TStringList.Create;
    FExternFuncs.Sorted := True;
    FExternFuncs.Duplicates := dupIgnore;
    FImportedFuncs := TStringList.Create;
    FImportedFuncs.Sorted := True;
    FImportedFuncs.Duplicates := dupIgnore;
    FGenericFuncs := TStringList.Create;
    FGenericFuncs.Sorted := False;
    FGenericSpecializations := TStringList.Create;
    FGenericSpecializations.Sorted := True;
    FGenericSpecializations.Duplicates := dupIgnore;
    SetLength(FTypeSubstParams, 0);
    SetLength(FTypeSubstTypes, 0);
    SetLength(FLocals, 0);
  end;


destructor TIRLowering.Destroy;
var
  i: Integer;
begin
  FLocalMap.Free;
  for i := 0 to FConstMap.Count - 1 do
    System.TObject(FConstMap.Objects[i]).Free;
  FConstMap.Free;
  for i := 0 to Length(FLocals)-1 do
    if Assigned(FLocals[i].ConstVal) then FLocals[i].ConstVal.Free;
  SetLength(FLocals, 0);
  FBreakStack.Free;
  FContinueStack.Free;
  // Don't free objects in FStructTypes/FClassTypes/FGlobalVars - they belong to the AST
  FStructTypes.Free;
  FClassTypes.Free;
  // Don't free objects in FRangeTypes — they belong to the AST
  FRangeTypes.Free;
  FGlobalVars.Free;
  FExternFuncs.Free;
  FImportedFuncs.Free;
  // Don't free objects in FGenericFuncs — they belong to the AST
  FGenericFuncs.Free;
  FGenericSpecializations.Free;
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


{ Range check helpers — see lower_range_checks.inc }
{$include 'lower_range_checks.inc'}

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
  SetLength(FLocals, FCurrentFunc.LocalCount);
  FLocals[Result].VarType  := aType;
  FLocals[Result].ElemSize := 0;
  FLocals[Result].IsStruct := False;
  FLocals[Result].TypeName := '';
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
  if count <= 0 then
    count := 1; // minimum 1 slot for empty/dynamic arrays
  base := FCurrentFunc.LocalCount;
  FCurrentFunc.LocalCount := FCurrentFunc.LocalCount + count;
  FLocalMap.AddObject(name, IntToObj(base));
  SetLength(FLocals, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
  begin
    FLocals[base + i].VarType    := aType;
    FLocals[base + i].ElemSize   := 0;
    FLocals[base + i].IsStruct   := isStruct and (i = 0);
    FLocals[base + i].SlotCount  := 0;
    FLocals[base + i].ArrayLen   := 0;
    FLocals[base + i].IsDynArray := False;
    FLocals[base + i].TypeName   := '';
    FLocals[base + i].ConstVal   := nil;
  end;
  FLocals[base].SlotCount := count;
  if (not isStruct) and (count > 1) then
    FLocals[base].ArrayLen := count;
  Result := base;
end;

function TIRLowering.GetLocalType(idx: Integer): TAurumType;
begin
  if (idx >= 0) and (idx < Length(FLocals)) then
    Result := FLocals[idx].VarType
  else
    Result := atUnresolved;
end;

// Infers the expression type when ResolvedType is atUnresolved.
// Used for imported unit function bodies where sema did not run on the body,
// so AST identifier nodes carry atUnresolved instead of their actual type.
function TIRLowering.InferExprType(expr: TAstExpr): TAurumType;
var
  loc: Integer;
  lType, rType: TAurumType;
begin
  if expr = nil then Exit(atUnresolved);
  Result := expr.ResolvedType;
  if Result <> atUnresolved then Exit;

  if expr is TAstIdent then
  begin
    loc := ResolveLocal(TAstIdent(expr).Name);
    if loc >= 0 then
      Result := GetLocalType(loc);
  end
  else if expr is TAstFloatLit then
    Result := atF64
  else if expr is TAstBinOp then
  begin
    lType := InferExprType(TAstBinOp(expr).Left);
    rType := InferExprType(TAstBinOp(expr).Right);
    if (lType = atF64) or (rType = atF64) then
      Result := atF64
    else if lType <> atUnresolved then
      Result := lType
    else
      Result := rType;
  end
  else if expr is TAstUnaryOp then
    Result := InferExprType(TAstUnaryOp(expr).Operand);
end;

function TIRLowering.GetLocalArrayLen(idx: Integer): Integer;
begin
  if (idx >= 0) and (idx < Length(FLocals)) then
    Result := FLocals[idx].ArrayLen
  else
    Result := 0;
end;

procedure TIRLowering.Emit(instr: TIRInstr);
begin
  if not Assigned(FCurrentFunc) then
    Exit;
  // Attach source location to IR instruction (aerospace-todo 6.1)
  instr.SourceLine := FCurrentSourceLine;
  instr.SourceFile := FCurrentSourceFile;
  // Provenance Tracking (WP-F): attach AST node reference
  if Assigned(FCurrentASTNode) then
  begin
    instr.SourceASTID := FCurrentASTNode.ID;
    instr.SourceASTKind := Ord(FCurrentASTNode.Kind);
  end
  else
  begin
    instr.SourceASTID := -1;
    instr.SourceASTKind := -1;
  end;
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
  strIdx: Integer;
  structIdx: Integer;
  sd: TAstStructDecl;
begin
  instr := Default(TIRInstr);
  // First pass: collect all struct, class, and global variable declarations
  // Note: FStructTypes, FClassTypes, FGlobalVars are NOT cleared here
  // because LowerImportedUnits may have already populated them with imported symbols
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstUnitDecl then
    begin
      // Propagate @integrity attribute from unit declaration to IR module
      if TAstUnitDecl(node).IntegrityAttr.Mode <> imNone then
        FModule.UnitIntegrity := TAstUnitDecl(node).IntegrityAttr;
    end
    else if node is TAstStructDecl then
      FStructTypes.AddObject(TAstStructDecl(node).Name, System.TObject(node))
    else if node is TAstClassDecl then
    begin
      // Classes are stored in both maps - they have the same field layout logic
      FStructTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
      FClassTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
      // Also store in IR module for VMT emission
      FModule.AddClassDecl(TAstClassDecl(node));
    end
    else if node is TAstVarDecl then
    begin
      // Global variable declaration
      if TAstVarDecl(node).IsGlobal then
      begin
        FGlobalVars.AddObject(TAstVarDecl(node).Name, System.TObject(node));
        // Register in module with init value
        if TAstVarDecl(node).InitExpr is TAstIntLit then
        begin
          FModule.AddGlobalVar(TAstVarDecl(node).Name, TAstIntLit(TAstVarDecl(node).InitExpr).Value, True);
        end
        else if TAstVarDecl(node).InitExpr is TAstStrLit then
        begin
          // String literal initializer: use special function to mark as string pointer
          strIdx := FModule.InternString(TAstStrLit(TAstVarDecl(node).InitExpr).Value);
          FModule.AddGlobalStringPtr(TAstVarDecl(node).Name, strIdx);
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
  
  // Add TObject to class types if not already present
  // TObject is the implicit base class for all classes without explicit base
  if FClassTypes.IndexOf(TOBJECT_CLASSNAME) < 0 then
  begin
    // Create TObject class declaration and add to module
    node := CreateTObjectClassDecl;
    FStructTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(node));
    FClassTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(node));
    FModule.AddClassDecl(TAstClassDecl(node));
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
          FExternFuncs.Add(TAstFuncDecl(node).Name);
          // Register library name if provided via link "..."
          if TAstFuncDecl(node).LibraryName <> '' then
            FModule.RegisterExternLibrary(TAstFuncDecl(node).Name,
              TAstFuncDecl(node).LibraryName);
          Continue;
        end;
       // Skip abstract methods (no body to lower)
       if TAstFuncDecl(node).IsAbstract then
       begin
         Continue;
       end;
       // Store generic functions for monomorphization; skip normal lowering
       if Length(TAstFuncDecl(node).TypeParams) > 0 then
       begin
         FGenericFuncs.AddObject(TAstFuncDecl(node).Name, System.TObject(node));
         Continue;
       end;
       // Remove any imported function with the same name (main prog wins)
       if FModule.FindFunction(TAstFuncDecl(node).Name) <> nil then
         FModule.RemoveFunction(TAstFuncDecl(node).Name);
       fn := FModule.AddFunction(TAstFuncDecl(node).Name);
       // Lower function body
       FCurrentFunc := fn;
       FCurrentFuncDecl := TAstFuncDecl(node);
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for j := 0 to Length(FLocals) - 1 do
          if Assigned(FLocals[j].ConstVal) then
            FLocals[j].ConstVal.Free;
        SetLength(FLocals, 0);
        FTempCounter := 0;
       fn.ParamCount := Length(TAstFuncDecl(node).Params);
       fn.LocalCount := fn.ParamCount;
       // Copy safety pragmas from AST to IR
       fn.SafetyPragmas := TAstFuncDecl(node).SafetyPragmas;

       // Calculate ReturnStructSize for struct-returning functions
       fn.ReturnStructSize := 0;
       if TAstFuncDecl(node).ReturnTypeName <> '' then
       begin
         structIdx := FStructTypes.IndexOf(TAstFuncDecl(node).ReturnTypeName);
         if structIdx >= 0 then
         begin
           sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
           fn.ReturnStructSize := sd.Size;
         end;
       end;
        SetLength(FLocals, fn.LocalCount);
        for j := 0 to fn.ParamCount - 1 do
        begin
          FLocalMap.AddObject(TAstFuncDecl(node).Params[j].Name, IntToObj(j));
          FLocals[j].VarType  := TAstFuncDecl(node).Params[j].ParamType;
          FLocals[j].ConstVal := nil;
          FLocals[j].IsStruct := False;
          FLocals[j].ElemSize := 0;
          if TAstFuncDecl(node).Params[j].TypeName <> '' then
            FLocals[j].TypeName := TAstFuncDecl(node).Params[j].TypeName
          else
            FLocals[j].TypeName := '';
        end;

       // lower statements sequentially
       for j := 0 to High(TAstFuncDecl(node).Body.Stmts) do
       begin
         LowerStmt(TAstFuncDecl(node).Body.Stmts[j]);
       end;
       
       // Emit implicit return for void functions if last statement wasn't a return
       if (FCurrentFunc.InstrLen = 0) or
          (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
       begin
         EmitScopeDrops; // WP9
         instr := Default(TIRInstr);
         instr.Op := irFuncExit;
         instr.Src1 := -1;
         Emit(instr);
       end;
       FCurrentFunc.TrimInstructions;
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
        for k := 0 to Length(FLocals) - 1 do
          if Assigned(FLocals[k].ConstVal) then
            FLocals[k].ConstVal.Free;
        SetLength(FLocals, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocals, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocals[k].VarType := m.Params[k].ParamType;
            FLocals[k].ConstVal := nil;
            FLocals[k].IsStruct := False;
            FLocals[k].ElemSize := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocals, fn.LocalCount);
          // implicit self param at index 0
          // Note: self is a pointer to struct passed by caller, NOT a struct on stack
          // So we should NOT mark it as FLocalIsStruct - it's already an address
          FLocalMap.AddObject('self', IntToObj(0));
          FLocals[0].VarType := atUnresolved;
          FLocals[0].ConstVal := nil;
          FLocals[0].IsStruct := False; // self holds address, don't use LEA
          FLocals[0].ElemSize := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocals[k+1].VarType := m.Params[k].ParamType;
            FLocals[k+1].ConstVal := nil;
            FLocals[k+1].IsStruct := False;
            FLocals[k+1].ElemSize := 0;
          end;
        end;
        
        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (FCurrentFunc.InstrLen = 0) or
           (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
        begin
          EmitScopeDrops; // WP9
          instr := Default(TIRInstr);
          instr.Op := irFuncExit;
          instr.Src1 := -1;
          Emit(instr);
        end;
        FCurrentFunc.TrimInstructions;
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
        for k := 0 to Length(FLocals) - 1 do
          if Assigned(FLocals[k].ConstVal) then
            FLocals[k].ConstVal.Free;
        SetLength(FLocals, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocals, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocals[k].VarType := m.Params[k].ParamType;
            FLocals[k].ConstVal := nil;
            FLocals[k].IsStruct := False;
            FLocals[k].ElemSize := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self (pointer to class instance)
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocals, fn.LocalCount);
          // implicit self param at index 0
          // For classes, self is a pointer (8 bytes), not a struct on stack
          FLocalMap.AddObject('self', IntToObj(0));
          FLocals[0].VarType := atUnresolved;
          FLocals[0].ConstVal := nil;
          FLocals[0].IsStruct := False; // self holds pointer address
          FLocals[0].ElemSize := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocals[k+1].VarType := m.Params[k].ParamType;
            FLocals[k+1].ConstVal := nil;
            FLocals[k+1].IsStruct := False;
            FLocals[k+1].ElemSize := 0;
          end;
        end;

        // Skip abstract methods (no body to lower)
        if m.IsAbstract then
        begin
          FCurrentFunc := nil;
          FCurrentFuncDecl := nil;
          Continue;
        end;

        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (FCurrentFunc.InstrLen = 0) or
           (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
        begin
          EmitScopeDrops; // WP9
          instr := Default(TIRInstr);
          instr.Op := irFuncExit;
          instr.Src1 := -1;
          Emit(instr);
        end;
        FCurrentFunc.TrimInstructions;
        FCurrentFunc := nil;
        FCurrentFuncDecl := nil;
      end;
      FCurrentClassDecl := nil; // clear after processing all methods of this class
    end
    else if node is TAstEnumDecl then
    begin
      // Register each enum value as a compile-time integer constant
      for j := 0 to High(TAstEnumDecl(node).Values) do
      begin
        cv := TConstValue.Create;
        cv.IsStr  := False;
        cv.IntVal := TAstEnumDecl(node).Values[j].Value;
        FConstMap.AddObject(TAstEnumDecl(node).Values[j].Name, System.TObject(cv));
      end;
    end
    else if node is TAstTypeDecl then
    begin
      // Register range types for runtime bounds-check emission (aerospace-todo P1 #7)
      if TAstTypeDecl(node).HasRange then
      begin
        if FRangeTypes.IndexOf(TAstTypeDecl(node).Name) < 0 then
          FRangeTypes.AddObject(TAstTypeDecl(node).Name, System.TObject(node));
      end;
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
      FConstMap.AddObject(TAstConDecl(node).Name, System.TObject(cv));
    end;
  end;
  Result := FModule;
end;

procedure TIRLowering.EnsureClassLayout(cd: TAstClassDecl);
{ Compute field offsets for an imported class if not yet done by sema.
  Classes imported transitively (e.g., lexer.lyx imported by parser.lyx) may
  not have been processed by ComputeClassLayouts in sema because they were not
  directly visible to sema's FClassTypes.  We recompute the layout here so
  that the fallback field-access code in LowerStmt/LowerExpr uses correct offsets. }
var
  fldIdx: Integer;
  f: TStructField;
  off, fsize, falign: Integer;
  baseSize: Integer;
  baseIdx: Integer;
  baseCd: TAstClassDecl;
begin
  if not Assigned(cd) then Exit;
  if cd.Size <> 0 then Exit;  // already computed

  // Ensure base class layout first
  baseSize := 8;  // VMT pointer slot for all classes (even without virtual methods)
  if cd.BaseClassName <> '' then
  begin
    baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
    if baseIdx >= 0 then
    begin
      baseCd := TAstClassDecl(FClassTypes.Objects[baseIdx]);
      EnsureClassLayout(baseCd);
      if baseCd.Size > 0 then
        baseSize := baseCd.Size;
    end;
  end;

  off := baseSize;
  for fldIdx := 0 to High(cd.Fields) do
  begin
    f := cd.Fields[fldIdx];
    fsize := 8; falign := 8;  // default: 8-byte pointer/int
    case f.FieldType of
      atInt8, atUInt8, atChar, atBool: begin fsize := 1; falign := 1; end;
      atInt16, atUInt16:               begin fsize := 2; falign := 2; end;
      atInt32, atUInt32, atF32:        begin fsize := 4; falign := 4; end;
      atInt64, atUInt64, atISize, atUSize, atF64, atPChar: begin fsize := 8; falign := 8; end;
      atUnresolved:
        begin
          // Named type — assume pointer (8 bytes)
          fsize := 8; falign := 8;
        end;
    else
      fsize := 8; falign := 8;
    end;
    // align offset
    if (off mod falign) <> 0 then
      off := ((off + falign - 1) div falign) * falign;
    cd.FieldOffsets[fldIdx] := off;
    off := off + fsize;
  end;
  // align total size to 8
  if (off mod 8) <> 0 then
    off := ((off + 7) div 8) * 8;
  cd.SetLayout(off, 8, baseSize);
end;

procedure TIRLowering.LowerImportedUnits(um: TUnitManager);
{ Lower all functions, constants and global variables from imported units
  Uses two-phase approach:
  Phase 1: Import all structs, classes, and constants
  Phase 2: Import all functions and global variables
  This ensures constants are available when function bodies are lowered }
var
  i, j, k, mi: Integer;
  loadedUnit: TLoadedUnit;
  node: TAstNode;
  fn: TIRFunction;
  m: TAstFuncDecl;
  mangled: string;
  unitAST: TAstProgram;
  cv: TConstValue;
  con: TAstConDecl;
  vd: TAstVarDecl;
  items: TAstExprList;
  vals: array of Int64;
  phase: Integer;
  instr: TIRInstr;
  structIdx: Integer;
  sd: TAstStructDecl;
begin
  if not Assigned(um) then Exit;

  { Three-phase approach:
    Phase 0: Pre-register ALL types (structs, classes) and constants/enums.
             Class method bodies are NOT lowered yet. This ensures that when
             Phase 1 lowers class method bodies, every imported constant (e.g.
             PARSER_NODE_SIZE from bootstrap.parser) is already in FConstMap
             and every imported class type is already in FClassTypes — regardless
             of which unit appears first in the reverse-order traversal.
    Phase 1: Lower class method bodies (all types/constants already available).
    Phase 2: Functions and global variables.
    Units are processed in REVERSE order so leaf units are handled first;
    duplicates are skipped via the existing IndexOf() checks. }
  for phase := 0 to 2 do
  begin
    for i := um.Units.Count - 1 downto 0 do
    begin
      loadedUnit := TLoadedUnit(um.Units.Objects[i]);
      if not Assigned(loadedUnit) or not Assigned(loadedUnit.AST) then
        Continue;

      unitAST := loadedUnit.AST;

      // Lower all declarations from this unit
      for j := 0 to High(unitAST.Decls) do
      begin
        node := unitAST.Decls[j];

          // PHASE 0: Register all types and constants (NO method body lowering).
          // By registering everything in a dedicated first pass, Phase 1 can lower
          // class method bodies knowing that all imported constants and class types
          // are already available — independent of unit processing order.
          if phase = 0 then
          begin
            if node is TAstStructDecl then
            begin
              if not TAstStructDecl(node).IsPublic then
                Continue;
              if FStructTypes.IndexOf(TAstStructDecl(node).Name) >= 0 then
                Continue;
              FStructTypes.AddObject(TAstStructDecl(node).Name, System.TObject(node));
            end
            else if node is TAstClassDecl then
            begin
              if not TAstClassDecl(node).IsPublic then
                Continue;
              if FClassTypes.IndexOf(TAstClassDecl(node).Name) >= 0 then
                Continue;
              FStructTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
              FClassTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
              EnsureClassLayout(TAstClassDecl(node));
              FModule.AddClassDecl(TAstClassDecl(node));
              // Method bodies are NOT lowered here; that happens in Phase 1.
            end
            else if node is TAstConDecl then
            begin
              con := TAstConDecl(node);
              if FConstMap.IndexOf(con.Name) >= 0 then
                Continue;
              cv := TConstValue.Create;
              if con.InitExpr is TAstIntLit then
              begin
                cv.IsStr := False;
                cv.IntVal := TAstIntLit(con.InitExpr).Value;
              end
              else if con.InitExpr is TAstStrLit then
              begin
                cv.IsStr := True;
                cv.StrVal := TAstStrLit(con.InitExpr).Value;
              end
              else if con.InitExpr is TAstBoolLit then
              begin
                cv.IsStr := False;
                if TAstBoolLit(con.InitExpr).Value then
                  cv.IntVal := 1
                else
                  cv.IntVal := 0;
              end
              else
              begin
                FDiag.Error('imported con initializer must be a literal', con.Span);
                cv.Free;
                Continue;
              end;
              FConstMap.AddObject(con.Name, System.TObject(cv));
            end
            else if node is TAstEnumDecl then
            begin
              for k := 0 to High(TAstEnumDecl(node).Values) do
              begin
                if FConstMap.IndexOf(TAstEnumDecl(node).Values[k].Name) >= 0 then
                  Continue;
                cv := TConstValue.Create;
                cv.IsStr  := False;
                cv.IntVal := TAstEnumDecl(node).Values[k].Value;
                FConstMap.AddObject(TAstEnumDecl(node).Values[k].Name, System.TObject(cv));
              end;
            end;
          end
          // PHASE 1: Lower class method bodies.
          // All types and constants are already registered (Phase 0), so
          // imported constants and class types are available during lowering.
          else if phase = 1 then
          begin
            if node is TAstClassDecl then
            begin
              if not TAstClassDecl(node).IsPublic then
                Continue;
              // Class was already registered in Phase 0; just lower the method bodies.
              FCurrentClassDecl := TAstClassDecl(node);
              for mi := 0 to High(TAstClassDecl(node).Methods) do
              begin
                m := TAstClassDecl(node).Methods[mi];
                mangled := '_L_' + TAstClassDecl(node).Name + '_' + m.Name;
                fn := FModule.AddFunction(mangled);
                FCurrentFunc := fn;
                FCurrentFuncDecl := m;
                FLocalMap.Clear;
                for k := 0 to Length(FLocals) - 1 do
                  if Assigned(FLocals[k].ConstVal) then
                    FLocals[k].ConstVal.Free;
                SetLength(FLocals, 0);
                FTempCounter := 0;
                if m.IsStatic then
                begin
                  fn.ParamCount := Length(m.Params);
                  fn.LocalCount := fn.ParamCount;
                  SetLength(FLocals, fn.LocalCount);
                  for k := 0 to High(m.Params) do
                  begin
                    FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
                    FLocals[k].VarType := m.Params[k].ParamType;
                    FLocals[k].ConstVal := nil;
                    FLocals[k].IsStruct := False;
                    FLocals[k].ElemSize := 0;
                    if m.Params[k].TypeName <> '' then
                      FLocals[k].TypeName := m.Params[k].TypeName
                    else
                      FLocals[k].TypeName := '';
                  end;
                end
                else
                begin
                  fn.ParamCount := Length(m.Params) + 1;
                  fn.LocalCount := fn.ParamCount;
                  SetLength(FLocals, fn.LocalCount);
                  FLocalMap.AddObject('self', IntToObj(0));
                  FLocals[0].VarType := atUnresolved;
                  FLocals[0].ConstVal := nil;
                  FLocals[0].IsStruct := False;
                  FLocals[0].ElemSize := 0;
                  FLocals[0].TypeName := TAstClassDecl(node).Name;  // 'self' = current class
                  for k := 0 to High(m.Params) do
                  begin
                    FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
                    FLocals[k+1].VarType := m.Params[k].ParamType;
                    FLocals[k+1].ConstVal := nil;
                    FLocals[k+1].IsStruct := False;
                    FLocals[k+1].ElemSize := 0;
                    if m.Params[k].TypeName <> '' then
                      FLocals[k+1].TypeName := m.Params[k].TypeName
                    else
                      FLocals[k+1].TypeName := '';
                  end;
                end;
                if m.IsAbstract then
                begin
                  FCurrentFunc := nil;
                  FCurrentFuncDecl := nil;
                  Continue;
                end;
                for k := 0 to High(m.Body.Stmts) do
                  LowerStmt(m.Body.Stmts[k]);
                if (FCurrentFunc.InstrLen = 0) or
                   (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
                begin
                  EmitScopeDrops; // WP9
                  instr := Default(TIRInstr);
                  instr.Op := irFuncExit;
                  instr.Src1 := -1;
                  Emit(instr);
                end;
                FCurrentFunc.TrimInstructions;
                FCurrentFunc := nil;
                FCurrentFuncDecl := nil;
              end;
              FCurrentClassDecl := nil;
            end;
            // Structs, constants, and enums are handled in Phase 0; nothing to do here.
          end
          // PHASE 2: Functions and Global Variables
          else
        begin
          // Process global variable declarations (var / let / pub var / pub let)
          if node is TAstVarDecl then
          begin
            vd := TAstVarDecl(node);
            // Check if variable already exists (avoid duplicates)
            if FGlobalVars.IndexOf(vd.Name) >= 0 then
              Continue;

            // Register global variable (import all, not just public ones)
            FGlobalVars.AddObject(vd.Name, System.TObject(node));

            // Register in module with init value
            if vd.InitExpr is TAstIntLit then
              FModule.AddGlobalVar(vd.Name, TAstIntLit(vd.InitExpr).Value, True)
            else if vd.InitExpr is TAstArrayLit then
            begin
              // Collect integer items if possible
              items := TAstArrayLit(vd.InitExpr).Items;
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
                  SetLength(vals, 0);
                  Break;
                end;
              end;
              if Length(vals) > 0 then
                FModule.AddGlobalArray(vd.Name, vals)
              else
                FModule.AddGlobalVar(vd.Name, 0, False);
            end
            else
              FModule.AddGlobalVar(vd.Name, 0, False);
          end
          // Process function declarations
          else if node is TAstFuncDecl then
          begin
            // Note: We must include ALL functions (including private ones) from imported units,
            // because public functions may call private helper functions.
            // The visibility check (IsPublic) is only relevant for name resolution in the
            // importing module - it should not affect code generation.

            // Skip if function already imported (avoid duplicate names from different units)
            // This can happen when wrapper functions in one unit call functions with the same name in another unit
            // Process units in reverse order so implementations come before wrappers
            if FImportedFuncs.IndexOf(TAstFuncDecl(node).Name) >= 0 then
              Continue;

            // Track as imported function for CallMode resolution.
            // Extern fn from imported units must go into FExternFuncs (not FImportedFuncs)
            // so that callers inside the same unit get cmExternal, generating PLT stubs.
            if TAstFuncDecl(node).IsExtern then
            begin
              // Known Linux syscall wrappers must NOT go into FExternFuncs — they are
              // dispatched as irCallBuiltin by name in the call-lowering chain below.
              // Adding them here would route callers to a PLT stub that does not exist.
              if (TAstFuncDecl(node).Name = 'sys_socket')    or
                 (TAstFuncDecl(node).Name = 'sys_bind')      or
                 (TAstFuncDecl(node).Name = 'sys_listen')    or
                 (TAstFuncDecl(node).Name = 'sys_accept')    or
                 (TAstFuncDecl(node).Name = 'sys_connect')   or
                 (TAstFuncDecl(node).Name = 'sys_recvfrom')  or
                 (TAstFuncDecl(node).Name = 'sys_sendto')    or
                 (TAstFuncDecl(node).Name = 'sys_setsockopt') or
                 (TAstFuncDecl(node).Name = 'sys_getsockopt') or
                 (TAstFuncDecl(node).Name = 'sys_fcntl')     or
                 (TAstFuncDecl(node).Name = 'sys_shutdown')  or
                 (TAstFuncDecl(node).Name = 'sys_close')     or
                 (TAstFuncDecl(node).Name = 'sys_read')      or
                 (TAstFuncDecl(node).Name = 'sys_write')     or
                 (TAstFuncDecl(node).Name = 'sys_select')    or
                 (TAstFuncDecl(node).Name = 'sys_poll')      then
              begin
                Continue;  // Handled as irCallBuiltin by the call-lowering name dispatch
              end;
              FExternFuncs.Add(TAstFuncDecl(node).Name);
              if TAstFuncDecl(node).LibraryName <> '' then
                FModule.RegisterExternLibrary(TAstFuncDecl(node).Name,
                  TAstFuncDecl(node).LibraryName);
              Continue;  // No body to lower for extern fn
            end;
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
              for k := 0 to Length(FLocals) - 1 do
                if Assigned(FLocals[k].ConstVal) then
                  FLocals[k].ConstVal.Free;
              SetLength(FLocals, 0);
              FTempCounter := 0;
              fn.ParamCount := Length(TAstFuncDecl(node).Params);
              fn.LocalCount := fn.ParamCount;
              SetLength(FLocals, fn.LocalCount);

              for k := 0 to fn.ParamCount - 1 do
              begin
                FLocalMap.AddObject(TAstFuncDecl(node).Params[k].Name, IntToObj(k));
                FLocals[k].VarType := TAstFuncDecl(node).Params[k].ParamType;
                FLocals[k].ConstVal := nil;
                FLocals[k].IsStruct := False;
                FLocals[k].ElemSize := 0;
                // Record class type name for method-call resolution on class-typed params
                if TAstFuncDecl(node).Params[k].TypeName <> '' then
                  FLocals[k].TypeName := TAstFuncDecl(node).Params[k].TypeName
                else
                  FLocals[k].TypeName := '';
              end;

              // Calculate ReturnStructSize so the backend generates correct sret prologue
              fn.ReturnStructSize := 0;
              if TAstFuncDecl(node).ReturnTypeName <> '' then
              begin
                structIdx := FStructTypes.IndexOf(TAstFuncDecl(node).ReturnTypeName);
                if structIdx >= 0 then
                begin
                  sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
                  fn.ReturnStructSize := sd.Size;
                end;
              end;

              // Lower statements
              if Assigned(TAstFuncDecl(node).Body) then
                for k := 0 to High(TAstFuncDecl(node).Body.Stmts) do
                  LowerStmt(TAstFuncDecl(node).Body.Stmts[k]);

              // Emit implicit return for void functions if last statement wasn't a return
              if (FCurrentFunc.InstrLen = 0) or
                 (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
              begin
                EmitScopeDrops; // WP9
                // Initialize instr locally for this scope
                instr := Default(TIRInstr);
                instr.Op := irFuncExit;
                instr.Src1 := -1;
                Emit(instr);
              end;

              FCurrentFunc.TrimInstructions;
              FCurrentFunc := nil;
              FCurrentFuncDecl := nil;
            end;
          end;
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

{ Generics monomorphization — see lower_generics.inc }
{$include 'lower_generics.inc'}

{ SIMD expression lowering — see lower_simd.inc }
{$include 'lower_simd.inc'}

{ Expression lowering — see lower_expr.inc }
{$include 'lower_expr.inc'}

function TIRLowering.LowerStructLit(sl: TAstStructLit): Integer;
var
  instr: TIRInstr;
  sd: TAstStructDecl;
  baseLoc, slotsNeeded: Integer;
  i, fi, j, fldOffset, valTemp, addrTemp: Integer;
  elemSize, ptrTemp, lenTemp, elemTemp: Integer;
  fld: TStructField;
  arrLit: TAstArrayLit;
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
  
  // Get base address of the struct (lowest address = slot baseLoc + slotCount - 1)
  // Use irLoadStructAddr so the convention matches irCallStruct / irReturnStruct.
  addrTemp := NewTemp;
  instr.Op := irLoadStructAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  instr.StructSize := sd.Size;
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
        fld       := sd.Fields[fi];

        // --- static inline array [N]T: store each element individually ---
        if fld.ArrayLen > 0 then
        begin
          if fld.ElemType <> atUnresolved then
            elemSize := TypeSizeBytes(fld.ElemType)
          else
            elemSize := TypeSizeBytes(fld.FieldType);
          if elemSize < 1 then elemSize := 8;

          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            for j := 0 to High(arrLit.Items) do
            begin
              elemTemp := LowerExpr(arrLit.Items[j]);
              if elemTemp < 0 then Continue;
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := elemTemp;
              instr.ImmInt    := fldOffset + j * elemSize;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end;
        end

        // --- dynamic array []T: store fat-pointer (ptr, len) ---
        else if (fld.ArrayLen < 0) or (fld.FieldType = atDynArray) then
        begin
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            if Length(arrLit.Items) > 0 then
            begin
              baseLoc := AllocLocalMany('_dynfld_' + IntToStr(FTempCounter), atUnresolved,
                                        Length(arrLit.Items));
              SetLength(FLocals, baseLoc + Length(arrLit.Items));
              for j := 0 to High(arrLit.Items) do
              begin
                FLocals[baseLoc + j].ArrayLen := Length(arrLit.Items);
                elemTemp := LowerExpr(arrLit.Items[j]);
                if elemTemp >= 0 then
                begin
                  instr := Default(TIRInstr);
                  instr.Op   := irStoreLocal;
                  instr.Dest := baseLoc + (Length(arrLit.Items) - 1 - j);
                  instr.Src1 := elemTemp;
                  Emit(instr);
                end;
              end;
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op   := irLoadLocalAddr;
              instr.Dest := ptrTemp;
              instr.Src1 := baseLoc;
              Emit(instr);
            end
            else
            begin
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op     := irConstInt;
              instr.Dest   := ptrTemp;
              instr.ImmInt := 0;
              Emit(instr);
            end;
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := ptrTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
            lenTemp := NewTemp;
            instr := Default(TIRInstr);
            instr.Op     := irConstInt;
            instr.Dest   := lenTemp;
            instr.ImmInt := Length(arrLit.Items);
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := lenTemp;
            instr.ImmInt    := fldOffset + 8;
            instr.FieldSize := 8;
            Emit(instr);
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := 8;
              Emit(instr);
            end;
          end;
        end

        // --- Map<K,V> and Set<T>: lower → pointer, store 8 bytes ---
        else if fld.FieldType in [atMap, atSet] then
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp >= 0 then
          begin
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := valTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
          end;
        end

        // --- scalar / named-type: single store ---
        else
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp < 0 then Continue;
          instr := Default(TIRInstr);
          instr.Op        := irStoreField;
          instr.Src1      := addrTemp;
          instr.Src2      := valTemp;
          instr.ImmInt    := fldOffset;
          instr.FieldSize := TypeSizeBytes(fld.FieldType);
          Emit(instr);
        end;

        Break;
      end;
    end;

    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;

  // Return the address temp (LowerStructLit)
  Result := addrTemp;
end;

function TIRLowering.LowerArrayLit(al: TAstArrayLit): Integer;
var
  instr: TIRInstr;
  arrLen, baseLoc, addrTemp, tmp, i: Integer;
  items: TAstExprList;
begin
  Result := -1;
  instr := Default(TIRInstr);

  items := al.Items;
  arrLen := Length(items);

  // Empty array: return -1 (no valid temp)
  if arrLen = 0 then
    Exit;

  // Allocate stack slots for the array elements
  baseLoc := AllocLocalMany('_arraylit_' + IntToStr(FTempCounter), atUnresolved, arrLen);

  // Record array length for bounds checking
  if baseLoc + arrLen > Length(FLocals) then
    SetLength(FLocals, baseLoc + arrLen);
  for i := 0 to arrLen - 1 do
    FLocals[baseLoc + i].ArrayLen := arrLen;

  // Store elements in REVERSE order: arr[0] at highest slot (baseLoc + arrLen - 1 - i)
  for i := 0 to High(items) do
  begin
    tmp := LowerExpr(items[i]);
    if tmp < 0 then Continue;
    instr.Op := irStoreLocal;
    instr.Dest := baseLoc + (arrLen - 1 - i);
    instr.Src1 := tmp;
    Emit(instr);
  end;

  // Load the address of the array base slot
  addrTemp := NewTemp;
  instr.Op := irLoadLocalAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  Emit(instr);

  Result := addrTemp;
end;

procedure TIRLowering.LowerNestedFunc(funcDecl: TAstFuncDecl);
var
  fn: TIRFunction;
  j, captureSlot, outerSlot: Integer;
  structIdx: Integer;
  sd: TAstStructDecl;
  savedFunc: TIRFunction;
  savedDecl: TAstFuncDecl;
  savedLocalMap: TStringList;
  savedTempCounter: Integer;
  instr: TIRInstr;
begin
  // Save current function context
  savedFunc := FCurrentFunc;
  savedDecl := FCurrentFuncDecl;
  savedLocalMap := TStringList.Create;
  for j := 0 to FLocalMap.Count - 1 do
    savedLocalMap.AddObject(FLocalMap[j], FLocalMap.Objects[j]);
  savedTempCounter := FTempCounter;

  try
    // Create new function in module (use original name)
    fn := FModule.AddFunction(funcDecl.Name);
    FCurrentFunc := fn;
    FCurrentFuncDecl := funcDecl;
    FLocalMap.Clear;
    for j := 0 to Length(FLocals) - 1 do
      if Assigned(FLocals[j].ConstVal) then
        FLocals[j].ConstVal.Free;
    SetLength(FLocals, 0);
    FTempCounter := 0;

    // Copy closure info from AST to IR
    fn.ParentFuncName := funcDecl.ParentFuncName;
    fn.NeedsStaticLink := funcDecl.NeedsStaticLink;

    // Params: if needs static link, add as implicit first param (slot 0 = static link)
    if funcDecl.NeedsStaticLink then
    begin
      fn.ParamCount := Length(funcDecl.Params) + 1; // +1 for static link
      fn.LocalCount := fn.ParamCount;
      SetLength(FLocals, fn.LocalCount);
      // Slot 0 = static link pointer (parent RBP)
      // Slots 1..N = regular params
      FLocalMap.AddObject('__static_link__', IntToObj(0));
      FLocals[0].VarType := atInt64;
      FLocals[0].ConstVal := nil;
      for j := 0 to High(funcDecl.Params) do
      begin
        FLocalMap.AddObject(funcDecl.Params[j].Name, IntToObj(j + 1));
        FLocals[j + 1].VarType := funcDecl.Params[j].ParamType;
        FLocals[j + 1].ConstVal := nil;
      end;
      // Register captured vars by name — they will be loaded via irLoadCaptured
      for j := 0 to High(funcDecl.CapturedVars) do
      begin
        captureSlot := fn.LocalCount;
        Inc(fn.LocalCount);
        SetLength(FLocals, fn.LocalCount);
        FLocals[captureSlot].VarType := funcDecl.CapturedVars[j].VarType;
        FLocals[captureSlot].ConstVal := nil;
        // Register: name -> special marker slot (captured vars use irLoadCaptured)
        FLocalMap.AddObject(funcDecl.CapturedVars[j].Name, IntToObj(-100 - j));
      end;
    end
    else
    begin
      fn.ParamCount := Length(funcDecl.Params);
      fn.LocalCount := fn.ParamCount;
      for j := 0 to fn.ParamCount - 1 do
      begin
        FLocalMap.AddObject(funcDecl.Params[j].Name, IntToObj(j));
        FLocals[j].VarType := funcDecl.Params[j].ParamType;
        FLocals[j].ConstVal := nil;
      end;
    end;

    // Calculate ReturnStructSize
    fn.ReturnStructSize := 0;
    if funcDecl.ReturnTypeName <> '' then
    begin
      structIdx := FStructTypes.IndexOf(funcDecl.ReturnTypeName);
      if structIdx >= 0 then
      begin
        sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
        fn.ReturnStructSize := sd.Size;
      end;
    end;

    // Lower the function body
    for j := 0 to High(funcDecl.Body.Stmts) do
      LowerStmt(funcDecl.Body.Stmts[j]);

  finally
    // Restore parent function context
    FCurrentFunc := savedFunc;
    FCurrentFuncDecl := savedDecl;
    FLocalMap.Clear;
    for j := 0 to savedLocalMap.Count - 1 do
      FLocalMap.AddObject(savedLocalMap[j], savedLocalMap.Objects[j]);
    savedLocalMap.Free;
    FTempCounter := savedTempCounter;
  end;
end;

procedure TIRLowering.LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
var
  instr: TIRInstr;
  i, fi, j, fldOffset, valTemp, addrTemp: Integer;
  elemSize, ptrTemp, lenTemp, elemTemp, dynBase: Integer;
  fld: TStructField;
  arrLit: TAstArrayLit;
  fieldName: string;
  fieldFound: Boolean;
begin
  instr := Default(TIRInstr);

  // Get base address of the local struct (lowest address = slot baseLoc + slotCount - 1)
  // Use irLoadStructAddr (not irLoadLocalAddr) so the address convention matches
  // irCallStruct and irReturnStruct (both use SlotOffset(base+slotCount-1) as lowest address).
  addrTemp := NewTemp;
  instr.Op := irLoadStructAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  instr.StructSize := sd.Size;
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
        fld       := sd.Fields[fi];

        if fld.ArrayLen > 0 then
        begin
          if fld.ElemType <> atUnresolved then
            elemSize := TypeSizeBytes(fld.ElemType)
          else
            elemSize := TypeSizeBytes(fld.FieldType);
          if elemSize < 1 then elemSize := 8;
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            for j := 0 to High(arrLit.Items) do
            begin
              elemTemp := LowerExpr(arrLit.Items[j]);
              if elemTemp < 0 then Continue;
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := elemTemp;
              instr.ImmInt    := fldOffset + j * elemSize;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end;
        end
        else if (fld.ArrayLen < 0) or (fld.FieldType = atDynArray) then
        begin
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            if Length(arrLit.Items) > 0 then
            begin
              dynBase := AllocLocalMany('_dynfld_' + IntToStr(FTempCounter), atUnresolved,
                                        Length(arrLit.Items));
              SetLength(FLocals, dynBase + Length(arrLit.Items));
              for j := 0 to High(arrLit.Items) do
              begin
                FLocals[dynBase + j].ArrayLen := Length(arrLit.Items);
                elemTemp := LowerExpr(arrLit.Items[j]);
                if elemTemp >= 0 then
                begin
                  instr := Default(TIRInstr);
                  instr.Op   := irStoreLocal;
                  instr.Dest := dynBase + (Length(arrLit.Items) - 1 - j);
                  instr.Src1 := elemTemp;
                  Emit(instr);
                end;
              end;
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op   := irLoadLocalAddr;
              instr.Dest := ptrTemp;
              instr.Src1 := dynBase;
              Emit(instr);
            end
            else
            begin
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op     := irConstInt;
              instr.Dest   := ptrTemp;
              instr.ImmInt := 0;
              Emit(instr);
            end;
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := ptrTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
            lenTemp := NewTemp;
            instr := Default(TIRInstr);
            instr.Op     := irConstInt;
            instr.Dest   := lenTemp;
            instr.ImmInt := Length(arrLit.Items);
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := lenTemp;
            instr.ImmInt    := fldOffset + 8;
            instr.FieldSize := 8;
            Emit(instr);
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := 8;
              Emit(instr);
            end;
          end;
        end
        else if fld.FieldType in [atMap, atSet] then
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp >= 0 then
          begin
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := valTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
          end;
        end
        else
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp < 0 then Continue;
          instr := Default(TIRInstr);
          instr.Op        := irStoreField;
          instr.Src1      := addrTemp;
          instr.Src2      := valTemp;
          instr.ImmInt    := fldOffset;
          instr.FieldSize := TypeSizeBytes(fld.FieldType);
          Emit(instr);
        end;

        Break;
      end;
    end;

    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;
end;

procedure TIRLowering.EmitScopeDrops;
var
  i, fi, loc: Integer;
  ltype: TAurumType;
  typeName: string;
  structIdx: Integer;
  sd: TAstStructDecl;
  slotCnt: Integer;
  addrTemp, ptrTemp, nilTemp: Integer;
  instr: TIRInstr;
  skipLbl: string;
  fldOffset: Integer;
begin
  for i := 0 to FLocalMap.Count - 1 do
  begin
    loc := ObjToInt(FLocalMap.Objects[i]);
    if loc < 0 then Continue;
    if loc >= Length(FLocals) then Continue;
    ltype := FLocals[loc].VarType;
    typeName := '';
    if loc < Length(FLocals) then
      typeName := FLocals[loc].TypeName;

    // Case 1: local Map variable — nil-guarded irMapFree + zero-out
    if ltype = atMap then
    begin
      skipLbl := NewLabel('Ldrop_map');
      ptrTemp := NewTemp;
      instr := Default(TIRInstr); instr.Op := irLoadLocal; instr.Dest := ptrTemp; instr.Src1 := loc; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irBrFalse; instr.Src1 := ptrTemp; instr.LabelName := skipLbl; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irMapFree; instr.Src1 := ptrTemp; Emit(instr);
      nilTemp := NewTemp;
      instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := nilTemp; instr.ImmInt := 0; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := nilTemp; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
    end

    // Case 2: local Set variable — nil-guarded irSetFree + zero-out
    else if ltype = atSet then
    begin
      skipLbl := NewLabel('Ldrop_set');
      ptrTemp := NewTemp;
      instr := Default(TIRInstr); instr.Op := irLoadLocal; instr.Dest := ptrTemp; instr.Src1 := loc; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irBrFalse; instr.Src1 := ptrTemp; instr.LabelName := skipLbl; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irSetFree; instr.Src1 := ptrTemp; Emit(instr);
      nilTemp := NewTemp;
      instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := nilTemp; instr.ImmInt := 0; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := nilTemp; Emit(instr);
      instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
    end

    // Case 3: struct local with Map/Set fields — load struct, load field ptr, nil-guard free
    else if (ltype = atUnresolved) and (typeName <> '') and
            (FStructTypes.IndexOf(typeName) >= 0) then
    begin
      structIdx := FStructTypes.IndexOf(typeName);
      sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
      if Length(sd.FieldOffsets) < Length(sd.Fields) then Continue;
      slotCnt := 0;
      if loc < Length(FLocals) then slotCnt := FLocals[loc].SlotCount;
      if slotCnt < 1 then slotCnt := (sd.Size + 7) div 8;
      if slotCnt < 1 then slotCnt := 1;
      addrTemp := -1;
      for fi := 0 to High(sd.Fields) do
      begin
        if not (sd.Fields[fi].FieldType in [atMap, atSet]) then Continue;
        fldOffset := sd.FieldOffsets[fi];
        // Load struct base address once (or each time — cheap temp)
        addrTemp := NewTemp;
        instr := Default(TIRInstr); instr.Op := irLoadStructAddr; instr.Dest := addrTemp;
        instr.Src1 := loc; instr.StructSize := slotCnt * 8; Emit(instr);
        // Load field pointer (8 bytes)
        ptrTemp := NewTemp;
        instr := Default(TIRInstr); instr.Op := irLoadField; instr.Dest := ptrTemp;
        instr.Src1 := addrTemp; instr.ImmInt := fldOffset; instr.FieldSize := 8; Emit(instr);
        // Nil guard
        skipLbl := NewLabel('Ldrop_fld');
        instr := Default(TIRInstr); instr.Op := irBrFalse; instr.Src1 := ptrTemp; instr.LabelName := skipLbl; Emit(instr);
        // Free
        if sd.Fields[fi].FieldType = atMap then
          begin instr := Default(TIRInstr); instr.Op := irMapFree; instr.Src1 := ptrTemp; Emit(instr); end
        else
          begin instr := Default(TIRInstr); instr.Op := irSetFree; instr.Src1 := ptrTemp; Emit(instr); end;
        // Zero field to prevent double-free
        nilTemp := NewTemp;
        instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := nilTemp; instr.ImmInt := 0; Emit(instr);
        // Reload addrTemp (was clobbered by previous iteration)
        addrTemp := NewTemp;
        instr := Default(TIRInstr); instr.Op := irLoadStructAddr; instr.Dest := addrTemp;
        instr.Src1 := loc; instr.StructSize := slotCnt * 8; Emit(instr);
        instr := Default(TIRInstr); instr.Op := irStoreField; instr.Src1 := addrTemp; instr.Src2 := nilTemp;
        instr.ImmInt := fldOffset; instr.FieldSize := 8; Emit(instr);
        instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
      end;
    end;
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
    i, j, k: Integer;
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
    tZero, tLen, tGe0, tLtLen, tOk, tLtZero, tGeLen: Integer;
    // assert/panic helpers
    cond, msg: Integer;
    skipLbl: string;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl: string;
    // struct helpers
    sd: TAstStructDecl;
    structIdx: Integer;
    structSlots: Integer;
    slotCount: Integer;
    // nested field access helpers
    baseExpr: TAstExpr;
    // class field resolution helpers
    cd: TAstClassDecl;
    fi: Integer;
    fldOffset: Integer;
    fldType: TAurumType;
    // struct/class field static array assignment helpers
    fAccess2: TAstFieldAccess;
    fldArrLen2: Integer;
    fldElemType2: TAurumType;
    isHeap2: Boolean;
    addrBase2, tOffset2: Integer;
    // range type helpers (aerospace-todo P1 #7)
    rtIdx, rtIdx2: Integer;
    rtDecl, rtDecl2: TAstTypeDecl;
  begin
  // Track source location from AST node for assembly listing (aerospace-todo 6.1)
  if Assigned(stmt) then
  begin
    FCurrentSourceLine := stmt.Span.Line;
    FCurrentSourceFile := stmt.Span.FileName;
    // Provenance Tracking (WP-F): set current AST node for IR provenance
    FCurrentASTNode := stmt;
  end;
  instr := Default(TIRInstr);
  Result := True;
  // Handle block statements (multiple statements in braces)
  if stmt is TAstBlock then
  begin
    for i := 0 to High(TAstBlock(stmt).Stmts) do
      LowerStmt(TAstBlock(stmt).Stmts[i]);
    Exit(True);
  end;

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
      if (vd.InitExpr is TAstArrayLit) then
        arrLen := Length(TAstArrayLit(vd.InitExpr).Items);
      // Handle static array literals with known elements: store inline (no fat-pointer).
      // Dynamic arrays (ArrayLen=-1) or empty/no-literal cases use the fat-pointer branch below.
      if (arrLen > 0) and (vd.DeclType = atDynArray) then
      begin
          // Non-empty dynamic array literal: allocate slots inline for elements.
          // Store elements in REVERSE order so that arr[0] is at highest address.
          // This way, baseSlot + index*8 correctly addresses all elements.
          // Mark as NOT dynamic array - elements are stored inline.
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          // Record array length for bounds checking
          SetLength(FLocals, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocals[loc + i].ArrayLen := arrLen;
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
                // store in REVERSE order: arr[0] at highest slot (loc + arrLen - 1 - i)
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

        // dynamic array: fat-pointer with 3 slots (ptr, len, cap)
        loc := AllocLocalMany(vd.Name, atPChar, 3);
        // mark base slot as dynamic array
        if loc >= Length(FLocals) then SetLength(FLocals, loc + 3);
        FLocals[loc].IsDynArray := True;
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
            if loc >= Length(FLocals) then SetLength(FLocals, loc+1);
            FLocals[loc].ElemSize := elemSize;
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
           instr.Op := irStoreLocal; instr.Dest := loc;     instr.Src1 := t0; Emit(instr); // ptr = 0
           instr.Op := irStoreLocal; instr.Dest := loc + 1; instr.Src1 := t0; Emit(instr); // len = 0
           instr.Op := irStoreLocal; instr.Dest := loc + 2; instr.Src1 := t0; Emit(instr); // cap = 0

        end

       else
       begin
         tmp := LowerExpr(vd.InitExpr);
         instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := tmp; Emit(instr);
       end;
       Exit(True);
     end
      else if (vd.DeclType = atParallelArray) or (vd.InitExpr is TAstSIMDNew) then
      begin
        // ParallelArray: heap-allocated SIMD array, stored as a single pointer slot.
        // The initializer (TAstSIMDNew) lowers to irAlloc which returns a heap pointer.
        loc := AllocLocal(vd.Name, atParallelArray);
        tmp := LowerExpr(vd.InitExpr);
        instr.Op := irStoreLocal;
        instr.Dest := loc;
        instr.Src1 := tmp;
        Emit(instr);
        // Record element size for this local (needed by index access in backend)
        elemSize := 8; // default
        if vd.InitExpr is TAstSIMDNew then
        begin
          case TAstSIMDNew(vd.InitExpr).ElementType of
            atInt8, atUInt8:   elemSize := 1;
            atInt16, atUInt16: elemSize := 2;
            atInt32, atUInt32, atF32: elemSize := 4;
            atInt64, atUInt64, atF64: elemSize := 8;
          end;
        end;
        if loc >= Length(FLocals) then SetLength(FLocals, loc + 1);
        FLocals[loc].ElemSize := elemSize;
        Exit(True);
      end
      else if (vd.DeclTypeName <> '') and
              (((FStructTypes.IndexOf(vd.DeclTypeName) >= 0) and
                (FStructTypes.Objects[FStructTypes.IndexOf(vd.DeclTypeName)] is TAstClassDecl)) or
               (Assigned(FClassTypes) and (FClassTypes.IndexOf(vd.DeclTypeName) >= 0))) then
      begin
        // Class type: allocate a single pointer slot for the object reference
        loc := AllocLocal(vd.Name, vd.DeclType);
        
        // Record the class name for VMT lookup
        if loc < Length(FLocals) then
          FLocals[loc].TypeName := vd.DeclTypeName;
        
        // Initialize with new expression if present
        if Assigned(vd.InitExpr) then
        begin
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end
        else
        begin
          // No initializer - initialize to 0 (null pointer)
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irConstInt;
          instr.Dest := tmp;
          instr.ImmInt := 0;
          Emit(instr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end;
        Exit(True);
      end
      else if (vd.DeclTypeName <> '') and (FStructTypes.IndexOf(vd.DeclTypeName) >= 0) then
      begin
        // Struct type: allocate multiple slots on stack
        structIdx := FStructTypes.IndexOf(vd.DeclTypeName);
        sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
        structSlots := (sd.Size + 7) div 8;
        if structSlots < 1 then structSlots := 1;
        
        // Allocate stack slots for the struct
        loc := AllocLocalMany(vd.Name, vd.DeclType, structSlots, True);
        // Record the struct type name so field assignments can resolve offsets
        // for imported function bodies where sema hasn't annotated FieldOffset.
        if loc < Length(FLocals) then
          FLocals[loc].TypeName := vd.DeclTypeName;

        // Initialize with struct literal if present
        if vd.InitExpr is TAstStructLit then
        begin
          LowerStructLitIntoLocal(TAstStructLit(vd.InitExpr), loc, sd);
        end
        else if Assigned(vd.InitExpr) and (vd.InitExpr is TAstCall) then
        begin
          // Struct assignment from function call
          // Use special handling: emit irCallStruct which stores RAX and RDX
          call := TAstCall(vd.InitExpr);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          
          // Emit irCallStruct with dest being the local base slot
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;  // Base local slot (not temp!)
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := structSlots * 8;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
        end
        else if Assigned(vd.InitExpr) then
        begin
          // Struct assignment from other expression
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            // Copy first quadword to first slot
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end;
        Exit(True);
      end
      else if vd.DeclType = atArray then
      begin
        // Static array: allocate multiple slots on stack
        arrLen := vd.ArrayLen;
        if arrLen <= 0 then
        begin
          // Try to infer from initializer
          if vd.InitExpr is TAstArrayLit then
            arrLen := Length(TAstArrayLit(vd.InitExpr).Items)
          else
            FDiag.Error('static array requires explicit length or initializer', vd.Span);
        end;
        if arrLen > 0 then
        begin
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          // Record array length for this local
          SetLength(FLocals, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocals[loc + i].ArrayLen := arrLen;
          // Initialize with initializer if present
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
                instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
              end;
            end;
          end
          else if Assigned(vd.InitExpr) then
          begin
            // Single expression: broadcast to all elements
            tmp := LowerExpr(vd.InitExpr);
            for i := 0 to arrLen - 1 do
            begin
              instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
            end;
          end;
        end;
        Exit(True);
      end
      else if vd.DeclType = atArray then
      begin
        // Static array: allocate multiple slots on stack
        arrLen := vd.ArrayLen;
        if arrLen <= 0 then
        begin
          if vd.InitExpr is TAstArrayLit then
            arrLen := Length(TAstArrayLit(vd.InitExpr).Items)
          else
            FDiag.Error('static array requires explicit length or initializer', vd.Span);
        end;
        if arrLen > 0 then
        begin
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          SetLength(FLocals, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocals[loc + i].ArrayLen := arrLen;
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
                instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
              end;
            end;
          end
          else if Assigned(vd.InitExpr) then
          begin
            tmp := LowerExpr(vd.InitExpr);
            for i := 0 to arrLen - 1 do
            begin
              instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
            end;
          end;
        end;
        Exit(True);
      end
      // Check for function pointer: either explicit atFnPtr type OR unresolved with function name as initializer
      // This handles the case where type declarations aren't resolved in sema.
      // Exclude the case where the initializer is a compile-time constant (e.g. enum value) —
      // those must not be treated as function addresses.
      else if (vd.DeclType = atFnPtr) or
              ((vd.DeclType = atUnresolved) and (vd.DeclTypeName <> '') and
               Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent) and
               (FConstMap.IndexOf(TAstIdent(vd.InitExpr).Name) < 0)) then
      begin
        // Function pointer: allocate one slot and initialize with function address
        loc := AllocLocal(vd.Name, atFnPtr);  // Use atFnPtr for function pointers
        
        // Check if initializer is a function identifier
        if Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent) then
        begin
          // Function name as initializer - load function address
          // Use irLoadGlobalAddr to get the function address
          // First load into a temp, then store to local slot
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irLoadGlobalAddr;
          instr.Dest := tmp;
          instr.ImmStr := TAstIdent(vd.InitExpr).Name;
          Emit(instr);
          // Store to local slot
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end
        else if Assigned(vd.InitExpr) then
        begin
          // Other initializer - lower it normally
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end
        else
        begin
          // No initializer - initialize to 0 (null function pointer)
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irConstInt;
          instr.Dest := tmp;
          instr.ImmInt := 0;
          Emit(instr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end;
        Exit(True);
      end
      else
      begin
        // scalar local
       loc := AllocLocal(vd.Name, SubstType(vd.DeclType, vd.DeclTypeName));
       // Store type name so range checks can be emitted at assignment sites
       if (vd.DeclTypeName <> '') and (loc < Length(FLocals)) then
         FLocals[loc].TypeName := vd.DeclTypeName;
       // Bootstrap compat: if initializer is a cast to a class (e.g. var cfg: int64 := obj as CompilerConfig),
       // record the cast target class name so method calls can be resolved via _L_ClassName_MethodName.
       if Assigned(vd.InitExpr) and (vd.InitExpr is TAstCast) then
       begin
         if (TAstCast(vd.InitExpr).CastTypeName <> '') and
            (FClassTypes.IndexOf(TAstCast(vd.InitExpr).CastTypeName) >= 0) then
         begin
           if loc >= Length(FLocals) then SetLength(FLocals, loc + 1);
           FLocals[loc].TypeName := TAstCast(vd.InitExpr).CastTypeName;
         end;
       end;
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
             if loc >= Length(FLocals) then SetLength(FLocals, loc+1);
             FLocals[loc].ConstVal := cvLocal;
           end
           else
           begin
             // unsigned: record local constant zero-extended value
             cvLocal := TConstValue.Create;
             cvLocal.IsStr := False;
             cvLocal.IntVal := Int64(truncated);
             if loc >= Length(FLocals) then SetLength(FLocals, loc+1);
             FLocals[loc].ConstVal := cvLocal;
           end;
           Exit(True);
         end;
       end;
        tmp := LowerExpr(vd.InitExpr);
        // If local has narrower integer width, truncate before store.
        // Skip truncation for pointer-like types, float types, and unresolved.
        ltype := GetLocalType(loc);
        if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64)
           and (ltype <> atF64) and (ltype <> atF32)
           and (ltype <> atPChar) and (ltype <> atPCharNullable)
           and (ltype <> atMap) and (ltype <> atSet) and (ltype <> atDynArray)
           and (ltype <> atParallelArray) then
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
       // Emit runtime range check if this variable has a range type (aerospace-todo P1 #7)
       if (vd.DeclTypeName <> '') and Assigned(FRangeTypes) then
       begin
         rtIdx := FRangeTypes.IndexOf(vd.DeclTypeName);
         if rtIdx >= 0 then
         begin
           rtDecl := TAstTypeDecl(FRangeTypes.Objects[rtIdx]);
           EmitRangeCheck(tmp, rtDecl.RangeMin, rtDecl.RangeMax, vd.DeclTypeName, vd.Span);
         end;
       end;
       // Utype range enforcement: checked range → runtime panic; wraps → cyclic fold
       case vd.RangeKind of
         urkRange: EmitFloatRangeCheck(tmp, vd.RangeMin, vd.RangeMax, vd.DeclTypeName, vd.Span);
         urkWraps: tmp := EmitFloatWrap(tmp, vd.RangeMin, vd.RangeMax, vd.Span);
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
      if (loc < Length(FLocals)) and Assigned(FLocals[loc].ConstVal) then
      begin
        FLocals[loc].ConstVal.Free;
        FLocals[loc].ConstVal := nil;
      end;
      // Special case: assigning a struct-returning function call to a struct local
      // Must use irCallStruct (sret ABI) instead of irCall (scalar RAX return)
      if (TAstAssign(stmt).Value is TAstCall) and
         (loc < Length(FLocals)) and FLocals[loc].IsStruct and
         (loc < Length(FLocals)) and (FLocals[loc].TypeName <> '') then
      begin
        structIdx := FStructTypes.IndexOf(FLocals[loc].TypeName);
        if structIdx >= 0 then
        begin
          sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
          call := TAstCall(TAstAssign(stmt).Value);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := sd.Size;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Exit(True);
        end;
      end;
      tmp := LowerExpr(TAstAssign(stmt).Value);
      // truncate if local has narrower integer width; skip for float and pointer types
      ltype := GetLocalType(loc);
      if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64)
         and (ltype <> atF64) and (ltype <> atF32)
         and (ltype <> atPChar) and (ltype <> atPCharNullable)
         and (ltype <> atMap) and (ltype <> atSet) and (ltype <> atDynArray) then
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
      // Emit runtime range check for range-typed local (aerospace-todo P1 #7)
      if Assigned(FRangeTypes) and (loc < Length(FLocals)) and (FLocals[loc].TypeName <> '') then
      begin
        rtIdx2 := FRangeTypes.IndexOf(FLocals[loc].TypeName);
        if rtIdx2 >= 0 then
        begin
          rtDecl2 := TAstTypeDecl(FRangeTypes.Objects[rtIdx2]);
          EmitRangeCheck(tmp, rtDecl2.RangeMin, rtDecl2.RangeMax, FLocals[loc].TypeName, stmt.Span);
        end;
      end;
      // Utype range enforcement on assignment
      case TAstAssign(stmt).RangeKind of
        urkRange: EmitFloatRangeCheck(tmp, TAstAssign(stmt).RangeMin, TAstAssign(stmt).RangeMax,
                    TAstAssign(stmt).Name, stmt.Span);
        urkWraps: tmp := EmitFloatWrap(tmp, TAstAssign(stmt).RangeMin, TAstAssign(stmt).RangeMax,
                    stmt.Span);
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
      
      // For nested field access like o.x.a, we need to find the root struct
      // and use the combined offset. The Sema has already calculated the
      // combined offset in fa.Target.FieldOffset.
      
      // Walk up the chain of field accesses to find the root (non-field) expression
      baseExpr := fa.Target.Obj;
      while (baseExpr is TAstFieldAccess) do
        baseExpr := TAstFieldAccess(baseExpr).Obj;
      
      // Now lower the root expression (e.g., 'o' in 'o.x.a')
      t1 := LowerExpr(baseExpr);
      if t1 < 0 then Exit(False);
      t2 := LowerExpr(fa.Value);
      if t2 < 0 then Exit(False);
      
      // Check if target's owner is a class (heap) or struct (stack)
      ownerName := fa.Target.OwnerName;
      fldOffset := fa.Target.FieldOffset;
      fldType := fa.Target.FieldType;
      // If sema didn't annotate the field offset (imported class method bodies),
      // resolve it now.  Determine receiver class: 'self' → FCurrentClassDecl,
      // named local → FLocalTypeNames lookup.
      if fldOffset < 0 then
      begin
        // First: try struct type lookup via FStructTypes (for imported function bodies
        // where sema hasn't annotated FieldOffset on the AST node).
        if (baseExpr is TAstIdent) then
        begin
          i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
          if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocals)) and
             (FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName <> '') then
          begin
            structIdx := FStructTypes.IndexOf(FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName);
            if structIdx >= 0 then
            begin
              sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
              ownerName := sd.Name;
              if Length(sd.FieldOffsets) = Length(sd.Fields) then
                for fi := 0 to High(sd.Fields) do
                begin
                  if sd.Fields[fi].Name = fa.Target.Field then
                  begin
                    fldOffset := sd.FieldOffsets[fi];
                    fldType := sd.Fields[fi].FieldType;
                    Break;
                  end;
                end;
            end;
          end;
        end;

        // Second: try class type lookup (for class method bodies)
        if fldOffset < 0 then
        begin
          cd := nil;
          if (baseExpr is TAstIdent) and (TAstIdent(baseExpr).Name <> 'self') then
          begin
            i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
            if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocals)) and
               (FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName <> '') then
            begin
              j := FClassTypes.IndexOf(FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName);
              if j >= 0 then
                cd := TAstClassDecl(FClassTypes.Objects[j]);
            end;
          end;
          if (cd = nil) and Assigned(FCurrentClassDecl) then
            cd := FCurrentClassDecl;
          if Assigned(cd) then
            ownerName := cd.Name;
          while Assigned(cd) do
          begin
            for fi := 0 to High(cd.Fields) do
            begin
              if cd.Fields[fi].Name = fa.Target.Field then
              begin
                fldOffset := cd.FieldOffsets[fi];
                fldType := cd.Fields[fi].FieldType;
                Break;
              end;
            end;
            if fldOffset >= 0 then Break;
            if cd.BaseClassName <> '' then
            begin
              i := FClassTypes.IndexOf(cd.BaseClassName);
              if i >= 0 then cd := TAstClassDecl(FClassTypes.Objects[i])
              else cd := nil;
            end
            else cd := nil;
          end;
        end;
      end;
      if (ownerName <> '') and (FClassTypes.IndexOf(ownerName) >= 0) then
      begin
        // Class: use positive offset (heap access)
        instr.Op := irStoreFieldHeap;
        instr.Src1 := t1; // base pointer (heap address)
        instr.Src2 := t2; // value temp
        if fldOffset >= 0 then
          instr.ImmInt := fldOffset // positive offset for heap
        else
          instr.LabelName := fa.Target.Field;
        instr.FieldSize := TypeSizeBytes(fldType);
        Emit(instr);
      end
      else
      begin
        // Struct: use negative offset (stack access)
        instr.Op := irStoreField;
        instr.Src1 := t1; // base pointer
        instr.Src2 := t2; // value temp
        if fldOffset >= 0 then
          instr.ImmInt := fldOffset
        else
          instr.LabelName := fa.Target.Field;
        instr.FieldSize := TypeSizeBytes(fldType);
        Emit(instr);
      end;
      Exit(True);
    end;

    // index assignment: arr[idx] := value
    if stmt is TAstIndexAssign then
    begin
      // Check if this is a Map assignment (map[key] := value)
      if TAstIndexAssign(stmt).Target.Obj.ResolvedType = atMap then
      begin
        // Map assignment: map[key] := value -> irMapSet(map, key, value)

        // Lower the map (object)
        t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
        if t1 < 0 then Exit(False);

        // Lower the key
        t2 := LowerExpr(TAstIndexAssign(stmt).Target.Index);
        if t2 < 0 then Exit(False);

        // Lower the value
        t0 := LowerExpr(TAstIndexAssign(stmt).Value);
        if t0 < 0 then Exit(False);

        // Emit map_set(map, key, value)
        instr := Default(TIRInstr);
        instr.Op := irMapSet;
        instr.Src1 := t1;  // map
        instr.Src2 := t2;  // key
        instr.Src3 := t0;  // value
        Emit(instr);
        Exit(True);
      end;

      // Check if this is a Set (not supported for assignment)
      if TAstIndexAssign(stmt).Target.Obj.ResolvedType = atSet then
      begin
        FDiag.Error('sets are not indexable, cannot assign to set elements', stmt.Span);
        Exit(False);
      end;

      // Struct/class field static array assignment: p.items[i] := v
      if TAstIndexAssign(stmt).Target.Obj is TAstFieldAccess then
      begin
        fAccess2 := TAstFieldAccess(TAstIndexAssign(stmt).Target.Obj);
        fldArrLen2 := 0;
        fldElemType2 := atUnresolved;

        if fAccess2.OwnerName <> '' then
        begin
          structIdx := FStructTypes.IndexOf(fAccess2.OwnerName);
          if structIdx >= 0 then
          begin
            sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
            for fi := 0 to High(sd.Fields) do
              if sd.Fields[fi].Name = fAccess2.Field then
              begin
                fldArrLen2   := sd.Fields[fi].ArrayLen;
                fldElemType2 := sd.Fields[fi].ElemType;
                fldType      := sd.Fields[fi].FieldType;
                Break;
              end;
          end;
        end;

        isHeap2 := (fAccess2.OwnerName <> '') and
                   (FClassTypes.IndexOf(fAccess2.OwnerName) >= 0);

        if fldArrLen2 > 0 then
        begin
          // Get struct/class base address
          t1 := LowerExpr(fAccess2.Obj);
          if t1 < 0 then Exit(False);

          if fldElemType2 <> atUnresolved then
            elemSize := TypeSizeBytes(fldElemType2)
          else
            elemSize := TypeSizeBytes(fldType);
          if elemSize < 1 then elemSize := 8;

          t2 := LowerExpr(TAstIndexAssign(stmt).Target.Index);
          if t2 < 0 then Exit(False);
          t0 := LowerExpr(TAstIndexAssign(stmt).Value);
          if t0 < 0 then Exit(False);

          // Bounds check
          tLen := NewTemp; instr := Default(TIRInstr);
          instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := fldArrLen2; Emit(instr);
          tOk := NewTemp; instr := Default(TIRInstr);
          instr.Op := irCmpGe; instr.Dest := tOk; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
          errLbl := NewLabel('Larr_oob');
          instr := Default(TIRInstr); instr.Op := irBrTrue; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);

          // addrBase = struct_base + fldOffset (same for heap and stack)
          fldOffset := fAccess2.FieldOffset;
          tOffset2 := NewTemp; instr := Default(TIRInstr);
          instr.Op := irConstInt; instr.Dest := tOffset2; instr.ImmInt := fldOffset; Emit(instr);
          addrBase2 := NewTemp; instr := Default(TIRInstr);
          instr.Op := irAdd; instr.Dest := addrBase2; instr.Src1 := t1; instr.Src2 := tOffset2; Emit(instr);

          // Store: [addrBase2 + t2 * elemSize] = t0
          instr := Default(TIRInstr);
          instr.Op := irStoreElemDyn; instr.Src1 := addrBase2; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

          skipLbl := NewLabel('Larr_ok');
          instr := Default(TIRInstr); instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
          instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
          msgTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstStr; instr.Dest := msgTmp;
          instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
          instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr';
          instr.ImmInt := 1; SetLength(instr.ArgTemps, 1); instr.ArgTemps[0] := msgTmp; Emit(instr);
          codeTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
          instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit';
          instr.ImmInt := 1; SetLength(instr.ArgTemps, 1); instr.ArgTemps[0] := codeTmp; Emit(instr);
          instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);

          Exit(True);
        end;
        // Fall through for non-array struct field indexing (e.g., dynamic array or map)
      end;

      // Regular array assignment
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
            // ParallelArray: heap pointer stored in single slot - load pointer directly
            if GetLocalType(loc) = atParallelArray then
            begin
              t1 := NewTemp;
              instr.Op := irLoadLocal;
              instr.Dest := t1;
              instr.Src1 := loc;
              Emit(instr);
            end
            else
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
            end;
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
            // emit runtime check for global array - use two separate branches
            tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
            tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := gv.ArrayLen; Emit(instr);
            // Check idx < 0
            tLtZero := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtZero; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
            errLbl := NewLabel('Larr_oob'); instr.Op := irBrTrue; instr.Src1 := tLtZero; instr.LabelName := errLbl; Emit(instr);
            // Check idx >= len
            tGeLen := NewTemp; instr.Op := irCmpGe; instr.Dest := tGeLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := tGeLen; instr.LabelName := errLbl; Emit(instr);

             instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

            skipLbl := NewLabel('Larr_ok');
            instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
          end
          else if (loc >= 0) and (GetLocalArrayLen(loc) > 0) then
          begin
            // emit runtime check for local array - use two separate branches
            tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
            tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := GetLocalArrayLen(loc); Emit(instr);
            // Check idx < 0
            tLtZero := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtZero; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
            errLbl := NewLabel('Larr_oob'); instr.Op := irBrTrue; instr.Src1 := tLtZero; instr.LabelName := errLbl; Emit(instr);
            // Check idx >= len
            tGeLen := NewTemp; instr.Op := irCmpGe; instr.Dest := tGeLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := tGeLen; instr.LabelName := errLbl; Emit(instr);

            instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

            skipLbl := NewLabel('Larr_ok');
            instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
          end
         else
         begin
           // no bounds info, emit dynamic store
           instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);
        end;
      end;
      Exit(True);
    end;

    // if (cond) { thenBranch } [else { elseBranch }]
    if stmt is TAstIf then
    begin
      condTmp := LowerExpr(TAstIf(stmt).Cond);
      if condTmp < 0 then Exit(False);

      if Assigned(TAstIf(stmt).ElseBranch) then
      begin
        // if-else: brfalse to else, then to end
        elseLabel := NewLabel('Lelse');
        endLabel := NewLabel('Lendif');

        instr := Default(TIRInstr);
        instr.Op := irBrFalse;
        instr.Src1 := condTmp;
        instr.LabelName := elseLabel;
        Emit(instr);

        // then branch
        LowerStmt(TAstIf(stmt).ThenBranch);

        // jump to end
        instr := Default(TIRInstr);
        instr.Op := irJmp;
        instr.LabelName := endLabel;
        Emit(instr);

        // else label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := elseLabel;
        Emit(instr);

        // else branch
        LowerStmt(TAstIf(stmt).ElseBranch);

        // end label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := endLabel;
        Emit(instr);
      end
      else
      begin
        // if without else: brfalse to end
        endLabel := NewLabel('Lendif');

        instr := Default(TIRInstr);
        instr.Op := irBrFalse;
        instr.Src1 := condTmp;
        instr.LabelName := endLabel;
        Emit(instr);

        // then branch
        LowerStmt(TAstIf(stmt).ThenBranch);

        // end label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := endLabel;
        Emit(instr);
      end;
      Exit(True);
    end;

    // while (cond) { body }
    if stmt is TAstWhile then
    begin
      startLabel := NewLabel('Lwhile_start');
      exitLabel := NewLabel('Lwhile_exit');

      // start label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := startLabel;
      Emit(instr);

      // evaluate condition
      condTmp := LowerExpr(TAstWhile(stmt).Cond);
      if condTmp < 0 then Exit(False);

      // brfalse to exit
      instr := Default(TIRInstr);
      instr.Op := irBrFalse;
      instr.Src1 := condTmp;
      instr.LabelName := exitLabel;
      Emit(instr);

      // push break/continue labels
      FBreakStack.AddObject(exitLabel, nil);
      FContinueStack.AddObject(startLabel, nil);

      // body
      LowerStmt(TAstWhile(stmt).Body);

      // pop break/continue labels
      FBreakStack.Delete(FBreakStack.Count - 1);
      FContinueStack.Delete(FContinueStack.Count - 1);

      // jump back to start
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := startLabel;
      Emit(instr);

      // exit label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := exitLabel;
      Emit(instr);

      Exit(True);
    end;

    // return [expr];
    if stmt is TAstReturn then
    begin
      if Assigned(TAstReturn(stmt).Value) then
      begin
        // Check if returning a struct variable directly
        if (TAstReturn(stmt).Value is TAstIdent) then
        begin
          loc := ResolveLocal(TAstIdent(TAstReturn(stmt).Value).Name);
          if (loc >= 0) and (loc < Length(FLocals)) and FLocals[loc].IsStruct then
          begin
            // Get struct slot count
            slotCount := 1;
            if loc < Length(FLocals) then
              slotCount := FLocals[loc].SlotCount;
            if slotCount < 1 then slotCount := 1;

            // Struct return: use irReturnStruct with base local slot
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;  // Base local slot index
            instr.StructSize := slotCount * 8;  // Size in bytes
            Emit(instr);
            Exit(True);
          end;
        end;

        // Check if returning a tuple literal: return (a, b)
        if (TAstReturn(stmt).Value is TAstTupleLit) then
        begin
          // Allocate two consecutive slots in reverse order so irReturnStruct works:
          //   irReturnStruct(Src1=loc_b): RAX←slot[loc_b+1]=loc_a, RDX←slot[loc_b]=loc_b
          loc := AllocLocal('_retb_' + IntToStr(FLabelCounter), atInt64);  // slot N
          AllocLocal('_reta_' + IntToStr(FLabelCounter), atInt64);          // slot N+1
          Inc(FLabelCounter);
          // lower first element → store into slot N+1 (loc+1)
          t0 := LowerExpr(TAstTupleLit(TAstReturn(stmt).Value).Elems[0]);
          instr := Default(TIRInstr);
          instr.Op := irStoreLocal;
          instr.Dest := loc + 1;
          instr.Src1 := t0;
          Emit(instr);
          // lower second element → store into slot N (loc)
          tmp := LowerExpr(TAstTupleLit(TAstReturn(stmt).Value).Elems[1]);
          instr := Default(TIRInstr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
          // emit irReturnStruct with base=loc, size=16
          instr := Default(TIRInstr);
          instr.Op := irReturnStruct;
          instr.Src1 := loc;
          instr.StructSize := 16;
          Emit(instr);
          Exit(True);
        end;

        // Check if returning a struct from a function call (return someFunc(args...))
        // Without this, the call would be lowered via irCall (scalar return) instead of
        // irCallStruct (sret ABI), corrupting registers and memory.
        if (TAstReturn(stmt).Value is TAstCall) and (FCurrentFunc.ReturnStructSize > 16) then
        begin
          sd := GetReturnStructDecl;
          if Assigned(sd) then
          begin
            call := TAstCall(TAstReturn(stmt).Value);
            argCount := Length(call.Args);
            SetLength(argTemps, argCount);
            for i := 0 to argCount - 1 do
              argTemps[i] := LowerExpr(call.Args[i]);
            structSlots := (sd.Size + 7) div 8;
            if structSlots < 1 then structSlots := 1;
            loc := AllocLocalMany('_retcall_' + IntToStr(FLabelCounter), atUnresolved, structSlots, True);
            Inc(FLabelCounter);
            instr := Default(TIRInstr);
            instr.Op := irCallStruct;
            instr.Dest := loc;
            instr.ImmStr := call.Name;
            instr.ImmInt := argCount;
            instr.StructSize := sd.Size;
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;
            instr.StructSize := sd.Size;
            Emit(instr);
            Exit(True);
          end;
        end;

        // Check if returning a struct literal (e.g. return Pair { a: x, b: y })
        if (TAstReturn(stmt).Value is TAstStructLit) then
        begin
          sd := GetReturnStructDecl;
          if Assigned(sd) then
          begin
            structSlots := (sd.Size + 7) div 8;
            if structSlots < 1 then structSlots := 1;
            // Allocate local slots for the return struct and fill via field stores
            loc := AllocLocalMany('_retval_' + IntToStr(FLabelCounter), atUnresolved, structSlots, True);
            LowerStructLitIntoLocal(TAstStructLit(TAstReturn(stmt).Value), loc, sd);
            // Return via irReturnStruct so backend uses RAX/RDX correctly
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;
            instr.StructSize := structSlots * 8;
            Emit(instr);
            Exit(True);
          end;
        end;

        // Normal return (non-struct or expression)
        tmp := LowerExpr(TAstReturn(stmt).Value);
        if tmp < 0 then Exit(False);
        EmitScopeDrops; // WP9: free Map/Set locals and struct collection fields
        instr := Default(TIRInstr);
        instr.Op := irFuncExit;
        instr.Src1 := tmp;
        Emit(instr);
      end
      else
      begin
        EmitScopeDrops; // WP9: free Map/Set locals and struct collection fields
        instr := Default(TIRInstr);
        instr.Op := irFuncExit;
        instr.Src1 := -1; // void return
        Emit(instr);
      end;
      Exit(True);
    end;

    // break;
    if stmt is TAstBreak then
    begin
      if FBreakStack.Count = 0 then
      begin
        FDiag.Error('break statement outside of loop', stmt.Span);
        Exit(False);
      end;
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := FBreakStack[FBreakStack.Count - 1];
      Emit(instr);
      Exit(True);
    end;

    // continue;
    if stmt is TAstContinue then
    begin
      if FContinueStack.Count = 0 then
      begin
        FDiag.Error('continue statement outside of loop', stmt.Span);
        Exit(False);
      end;
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := FContinueStack[FContinueStack.Count - 1];
      Emit(instr);
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
          // OR pattern extra values
          for j := 0 to High(sw.Cases[i].ExtraValues) do
          begin
            caseTmp := LowerExpr(sw.Cases[i].ExtraValues[j]);
            instr.Op := irCmpEq; instr.Dest := NewTemp; instr.Src1 := switchTmp; instr.Src2 := caseTmp; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := instr.Dest; instr.LabelName := lbl; Emit(instr);
          end;
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

    // pool { ... } - Memory Pool Block
    if stmt is TAstPoolStmt then
    begin
      // Pool-Block: Allokiere Pool-Speicher am Anfang und gib ihn am Ende frei
      // Für jetzt: Pool direkt als normalen Block behandeln
      // Die IR-Operationen irPoolAlloc/irPoolFree werden vom Backend verwendet
      LowerStmt(TAstPoolStmt(stmt).Body);
      Exit(True);
    end;

    // dispose expr; - free heap-allocated class instance
    if stmt is TAstDispose then
    begin
      // Lower the expression - this returns a temp index
      // For identifiers, this returns the slot index, which is fine for irLoadLocal
      t0 := LowerExpr(TAstDispose(stmt).Expr);
      if t0 < 0 then Exit(False);
      
      // Emit irFree instruction
      // The temp value t0 contains the pointer to free
      instr := Default(TIRInstr);
      instr.Op := irFree;
      instr.Src1 := t0;
      instr.ImmInt := 0;  // Default size handling in backend
      Emit(instr);
      Exit(True);
    end;

    // Nested function — lower inline as a separate function in the module
    if stmt is TAstFuncStmt then
    begin
      LowerNestedFunc(TAstFuncStmt(stmt).FuncDecl);
      Exit(True);
    end;

    // try { body } catch (e: int64) { handler }
    if stmt is TAstTry then
    begin
      // catch label is the jump target when an exception is thrown
      thenLabel := NewLabel('Lcatch');
      // end label is after the catch block
      elseLabel := NewLabel('Ltry_end');

      // irPushHandler: tells backend to call setjmp and jump to thenLabel on throw
      instr := Default(TIRInstr);
      instr.Op := irPushHandler;
      instr.LabelName := thenLabel;
      Emit(instr);

      // lower try body
      LowerStmt(TAstTry(stmt).TryBody);

      // irPopHandler: remove handler frame (normal path)
      instr := Default(TIRInstr);
      instr.Op := irPopHandler;
      Emit(instr);

      // jump past the catch block
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := elseLabel;
      Emit(instr);

      // catch label: exception occurred
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := thenLabel;
      Emit(instr);

      // irPopHandler: remove handler frame (exception path)
      instr := Default(TIRInstr);
      instr.Op := irPopHandler;
      Emit(instr);

      // allocate the catch variable slot and load exception value into it
      loc := AllocLocal(TAstTry(stmt).CatchVar, atInt64);
      instr := Default(TIRInstr);
      instr.Op := irLoadHandlerExn;
      instr.Dest := loc;
      Emit(instr);

      // lower catch body
      LowerStmt(TAstTry(stmt).CatchBody);

      // end label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := elseLabel;
      Emit(instr);

      Exit(True);
    end;

    // throw expr;
    if stmt is TAstThrow then
    begin
      t0 := LowerExpr(TAstThrow(stmt).Value);
      if t0 < 0 then Exit(False);
      instr := Default(TIRInstr);
      instr.Op := irThrow;
      instr.Src1 := t0;
      Emit(instr);
      Exit(True);
    end;

    // var a, b := f() — tuple multi-return destructuring
    if stmt is TAstTupleVarDecl then
    begin
      with TAstTupleVarDecl(stmt) do
      begin
        if (Length(Names) = 2) and (InitExpr is TAstCall) then
        begin
          call := TAstCall(InitExpr);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          // irCallStruct stores RAX→slot[b+1]=a, RDX→slot[b]=b
          // allocate b first (lower slot index = higher address), then a
          loc := AllocLocal(Names[1], atInt64); // slot N   → RDX (second return)
          AllocLocal(Names[0], atInt64);        // slot N+1 → RAX (first return)
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;  // base: RAX→loc+1, RDX→loc
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := 16;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
        end;
      end;
      Exit(True);
    end;

    FDiag.Error('lowering: unsupported statement', stmt.Span);
    Result := False;
  end;


{ DONE: Indirect Call Support (irVarCall)
  =========================================
  
  Indirect calls via function pointers are already supported.
  Implementation at line ~3257:
    - TAstCall.IsIndirectCall is checked
    - Function pointer is loaded via irLoadLocal/irLoadGlobal
    - Indirect call is emitted via irVarCall
  
  Backend support exists in:
    - x86_64_emit.pas (line 5857): indirect call via 'call rax'
    - x86_64_win64.pas (line 2828)
    - arm64_emit.pas (line 2533)
    - macosx64_emit.pas (line 1196)
    - win_arm64_emit.pas (line 1502)
}


end.
