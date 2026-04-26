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
