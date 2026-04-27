function TIRLowering.SubstType(t: TAurumType; const n: string): TAurumType;
var
  i: Integer;
begin
  if (t = atUnresolved) and (n <> '') then
    for i := 0 to High(FTypeSubstParams) do
      if FTypeSubstParams[i] = n then
        Exit(FTypeSubstTypes[i]);
  Result := t;
end;

// Monomorphize a generic function: lower its body with type substitution active
procedure TIRLowering.LowerGenericSpecialization(decl: TAstFuncDecl;
  const mangledName: string; const typeArgs: array of TAurumType);
var
  fn: TIRFunction;
  j: Integer;
  savedFunc: TIRFunction;
  savedDecl: TAstFuncDecl;
  savedLocalMap: TStringList;
  savedTempCounter: Integer;
  savedSubstParams: TStringArray;
  savedSubstTypes: array of TAurumType;
  paramType: TAurumType;
  instr: TIRInstr;
begin
  instr := Default(TIRInstr);

  // Mark as already specialized (before lowering, to handle recursion)
  FGenericSpecializations.Add(mangledName);

  // Save current function context
  savedFunc := FCurrentFunc;
  savedDecl := FCurrentFuncDecl;
  savedLocalMap := TStringList.Create;
  for j := 0 to FLocalMap.Count - 1 do
    savedLocalMap.AddObject(FLocalMap[j], FLocalMap.Objects[j]);
  savedTempCounter := FTempCounter;
  savedSubstParams := FTypeSubstParams;
  savedSubstTypes := FTypeSubstTypes;

  try
    // Install substitution: decl.TypeParams[i] -> typeArgs[i]
    SetLength(FTypeSubstParams, Length(decl.TypeParams));
    SetLength(FTypeSubstTypes, Length(decl.TypeParams));
    for j := 0 to High(decl.TypeParams) do
    begin
      FTypeSubstParams[j] := decl.TypeParams[j];
      if j < Length(typeArgs) then
        FTypeSubstTypes[j] := typeArgs[j]
      else
        FTypeSubstTypes[j] := atInt64; // fallback
    end;

    // Create new function in module
    fn := FModule.AddFunction(mangledName);
    FCurrentFunc := fn;
    FCurrentFuncDecl := decl;
    FLocalMap.Clear;
    for j := 0 to Length(FLocals) - 1 do
      if Assigned(FLocals[j].ConstVal) then
        FLocals[j].ConstVal.Free;
    SetLength(FLocals, 0);
    FTempCounter := 0;

    // Set up parameters with type substitution applied
    fn.ParamCount := Length(decl.Params);
    fn.LocalCount := fn.ParamCount;
    SetLength(FLocals, fn.LocalCount);
    for j := 0 to fn.ParamCount - 1 do
    begin
      FLocalMap.AddObject(decl.Params[j].Name, IntToObj(j));
      paramType := SubstType(decl.Params[j].ParamType, decl.Params[j].TypeName);
      FLocals[j].VarType := paramType;
      FLocals[j].ConstVal := nil;
    end;

    // Lower the function body
    for j := 0 to High(decl.Body.Stmts) do
      LowerStmt(decl.Body.Stmts[j]);

    // Emit implicit return for void functions
    if (Length(FCurrentFunc.Instructions) = 0) or
       (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
    begin
      EmitScopeDrops; // WP9
      instr := Default(TIRInstr);
      instr.Op := irFuncExit;
      instr.Src1 := -1;
      Emit(instr);
    end;

  finally
    // Restore parent function context
    FCurrentFunc := savedFunc;
    FCurrentFuncDecl := savedDecl;
    FLocalMap.Clear;
    for j := 0 to savedLocalMap.Count - 1 do
      FLocalMap.AddObject(savedLocalMap[j], savedLocalMap.Objects[j]);
    savedLocalMap.Free;
    FTempCounter := savedTempCounter;
    FTypeSubstParams := savedSubstParams;
    FTypeSubstTypes := savedSubstTypes;
  end;
end;

// Lower one monomorphized struct method body using explicit type-param substitution.
// typeParams is the STRUCT's type params (e.g. ['T']); typeArgs are the concrete
// types (e.g. [atInt64]).  concStructDecl is registered in FStructTypes so the
// fallback field-offset lookup can resolve 'self.field' correctly.
procedure TIRLowering.LowerStructMethodSpec(methodDecl: TAstFuncDecl;
  const mangledName, concreteName: string; concStructDecl: TAstStructDecl;
  const typeParams: TStringArray; const typeArgs: array of TAurumType);
var
  fn: TIRFunction;
  j, k: Integer;
  savedFunc: TIRFunction;
  savedDecl: TAstFuncDecl;
  savedLocalMap: TStringList;
  savedTempCounter: Integer;
  savedSubstParams: TStringArray;
  savedSubstTypes: array of TAurumType;
  instr: TIRInstr;
begin
  instr := Default(TIRInstr);
  FGenericSpecializations.Add(mangledName);

  savedFunc     := FCurrentFunc;
  savedDecl     := FCurrentFuncDecl;
  savedLocalMap := TStringList.Create;
  for j := 0 to FLocalMap.Count - 1 do
    savedLocalMap.AddObject(FLocalMap[j], FLocalMap.Objects[j]);
  savedTempCounter := FTempCounter;
  savedSubstParams := FTypeSubstParams;
  savedSubstTypes  := FTypeSubstTypes;

  try
    // Install type-param → concrete-type substitution from the struct params
    SetLength(FTypeSubstParams, Length(typeParams));
    SetLength(FTypeSubstTypes,  Length(typeParams));
    for j := 0 to High(typeParams) do
    begin
      FTypeSubstParams[j] := typeParams[j];
      if j < Length(typeArgs) then
        FTypeSubstTypes[j] := typeArgs[j]
      else
        FTypeSubstTypes[j] := atInt64;
    end;

    // Ensure the concrete struct is visible for dynamic field-offset fallback
    if FStructTypes.IndexOf(concreteName) < 0 then
      FStructTypes.AddObject(concreteName, System.TObject(concStructDecl));

    fn := FModule.AddFunction(mangledName);
    FCurrentFunc     := fn;
    FCurrentFuncDecl := methodDecl;
    FLocalMap.Clear;
    for j := 0 to Length(FLocals) - 1 do
      if Assigned(FLocals[j].ConstVal) then
        FLocals[j].ConstVal.Free;
    SetLength(FLocals, 0);
    FTempCounter := 0;

    if methodDecl.IsStatic then
    begin
      fn.ParamCount := Length(methodDecl.Params);
      fn.LocalCount := fn.ParamCount;
      SetLength(FLocals, fn.LocalCount);
      for k := 0 to High(methodDecl.Params) do
      begin
        FLocalMap.AddObject(methodDecl.Params[k].Name, IntToObj(k));
        FLocals[k].VarType   := SubstType(methodDecl.Params[k].ParamType, methodDecl.Params[k].TypeName);
        FLocals[k].TypeName  := methodDecl.Params[k].TypeName;
        FLocals[k].ConstVal  := nil;
      end;
    end
    else
    begin
      fn.ParamCount := Length(methodDecl.Params) + 1;
      fn.LocalCount := fn.ParamCount;
      SetLength(FLocals, fn.LocalCount);
      // slot 0: implicit self — typed as the concrete struct for dynamic field lookup
      FLocalMap.AddObject('self', IntToObj(0));
      FLocals[0].VarType  := atUnresolved;
      FLocals[0].TypeName := concreteName; // key: dynamic fallback uses this
      FLocals[0].IsStruct := False;
      FLocals[0].ConstVal := nil;
      for k := 0 to High(methodDecl.Params) do
      begin
        FLocalMap.AddObject(methodDecl.Params[k].Name, IntToObj(k + 1));
        FLocals[k + 1].VarType  := SubstType(methodDecl.Params[k].ParamType, methodDecl.Params[k].TypeName);
        FLocals[k + 1].TypeName := methodDecl.Params[k].TypeName;
        FLocals[k + 1].ConstVal := nil;
      end;
    end;

    for j := 0 to High(methodDecl.Body.Stmts) do
      LowerStmt(methodDecl.Body.Stmts[j]);

    if (FCurrentFunc.InstrLen = 0) or
       (FCurrentFunc.Instructions[FCurrentFunc.InstrLen - 1].Op <> irFuncExit) then
    begin
      EmitScopeDrops;
      instr := Default(TIRInstr);
      instr.Op   := irFuncExit;
      instr.Src1 := -1;
      Emit(instr);
    end;
    FCurrentFunc.TrimInstructions;

  finally
    FCurrentFunc     := savedFunc;
    FCurrentFuncDecl := savedDecl;
    FLocalMap.Clear;
    for j := 0 to savedLocalMap.Count - 1 do
      FLocalMap.AddObject(savedLocalMap[j], savedLocalMap.Objects[j]);
    savedLocalMap.Free;
    FTempCounter     := savedTempCounter;
    FTypeSubstParams := savedSubstParams;
    FTypeSubstTypes  := savedSubstTypes;
  end;
end;

// Pre-register concrete struct declarations so var-decl lowering can compute
// the correct slot count and IsStruct flag for generic instantiation variables.
// Must be called BEFORE Lower(prog).
procedure TIRLowering.PreRegisterConcreteStructs(const entries: TMonoStructMethodList);
var
  i: Integer;
begin
  for i := 0 to High(entries) do
    if Assigned(entries[i].ConcreteStructDecl) and
       (FStructTypes.IndexOf(entries[i].ConcreteStructName) < 0) then
      FStructTypes.AddObject(entries[i].ConcreteStructName,
                             System.TObject(entries[i].ConcreteStructDecl));
end;

// Lower all monomorphized struct methods collected by sema during monomorphization.
procedure TIRLowering.LowerMonoStructMethods(const entries: TMonoStructMethodList);
var
  i: Integer;
begin
  for i := 0 to High(entries) do
  begin
    if FGenericSpecializations.IndexOf(entries[i].MangledName) >= 0 then
      Continue; // already lowered
    if not Assigned(entries[i].TemplateMethod) then
      Continue;
    if not Assigned(entries[i].TemplateMethod.Body) then
      Continue; // extern or abstract method — no body to lower
    LowerStructMethodSpec(
      entries[i].TemplateMethod,
      entries[i].MangledName,
      entries[i].ConcreteStructName,
      entries[i].ConcreteStructDecl,
      entries[i].StructTypeParams,
      entries[i].ConcreteTypeArgs);
  end;
end;
