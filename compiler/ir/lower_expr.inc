function TIRLowering.LowerExpr(expr: TAstExpr): Integer;
  var
    instr: TIRInstr;
    loc: Integer;
    tmp: Integer;
    condTmp: Integer;
    t0, t1, t2, tResult, tVec, tIdx: Integer;
    i, k: Integer;
    strIdx: Integer;
    cv: TConstValue;
    argCount: Integer;
    argTemps: array of Integer;
    callTemps: array of Integer;
    callName: string;
    regexLit: TAstRegexLit;
    useCompiled: Boolean;
    compiledTemp: Integer;
    lenTemp: Integer;
    fn: TIRFunction;
    ltype, rType: TAurumType;
    width: Integer;
    w: Integer;
    captureIdx: Integer;
    lit: Int64;
    mask64: UInt64;
    truncated: UInt64;
    half: UInt64;
    signedVal: Int64;
    cvLocal: TConstValue;
    vd: TAstVarDecl;
    castTypeName: string;
    items: TAstExprList;
    elemSize: Integer;
    fa: TAstFieldAssign;
    fldOffset: Integer;
    fldType: TAurumType;
    ownerName: string;
    slotCount: Integer;
    baseIdx: Integer;
    isFloatArith: Boolean;
    isFloatCmp: Boolean;
    isStringConcat: Boolean;
    mangled: string;
    // Map/Set lowering (v0.5.0)
    entryCount: Integer;
    elemCount: Integer;
    containerType: TAurumType;
    // Call handling
    call: TAstCall;
    // Virtual call handling
    classIdx: Integer;
    cd: TAstClassDecl;
    methodIdx: Integer;
    vmtIdx: Integer;
    vmtClassName: string;
    vmtMethodName: string;
    posIdx: Integer;
    hasVMT: Boolean;
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
    tZero, tLen, tGe0, tLtLen, tOk, tLtZero, tGeLen: Integer;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl, skipLbl: string;
    // Nested field access
    baseExpr: TAstExpr;
    // Method call type lookup
    recvExpr: TAstExpr;
    // Format expr lowering
    instr2: TIRInstr;
    tWidth, tDecimals: Integer;
    // Generic call monomorphization
    mangledName: string;
    idx: Integer;
    // Struct field resolution in imported function bodies
    structIdx: Integer;
    sd: TAstStructDecl;
    fi: Integer;
    // WP6: struct collection field indexed access
    fAccess: TAstFieldAccess;
    fldArrLen: Integer;
    fldElemType: TAurumType;
    isHeap: Boolean;
    addrBase, tOffset, ptrTemp, mapTemp: Integer;
    // WP8: Map/Set method dispatch
    recvTemp: Integer;
    recvType2: TAurumType;
  begin
  Result := -1;
  if not Assigned(expr) then
    Exit;

  // Provenance Tracking (WP-F): set current AST node for IR provenance
  FCurrentASTNode := expr;

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
        if loc < -1 then
        begin
          // Captured variable: load from parent frame via static link
          // loc = -100 - captureIndex
          captureIdx := -100 - loc;
          if Assigned(FCurrentFuncDecl) and (captureIdx <= High(FCurrentFuncDecl.CapturedVars)) then
          begin
            // The OuterSlot in CapturedVars needs to be looked up in parent's FLocalMap
            // But we cleared FLocalMap when we entered this function.
            // For now, use the captured var index as a hint — the actual slot is determined
            // by the parent function's local map at the time of the call.
            // We'll load from static_link + SlotOffset(outerSlot) where outerSlot is 
            // the index in the parent's locals.
            // Since we don't have the parent's FLocalMap here, we use a convention:
            // The captured var's OuterSlot is stored as the slot index in the parent function.
            // This was set by the Sema, but the Sema doesn't know slot indices.
            // WORKAROUND: Use the captured var index as outerSlot (0-based).
            // This works because the parent's captured vars are allocated in order.
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irLoadCaptured;
            instr.Dest := t0;
            instr.Src1 := 0; // static link is in slot 0
            instr.ImmInt := captureIdx; // use capture index as outer slot (patched later)
            Emit(instr);
            Result := t0;
            Exit;
          end;
        end;
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
          if (loc < Length(FLocals)) and Assigned(FLocals[loc].ConstVal) then
          begin
            cv := FLocals[loc].ConstVal;
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
            if (loc < Length(FLocals)) and FLocals[loc].IsStruct then
            begin
              // Struct local: load base address for field access
              // Need to know struct size to calculate correct base address
              slotCount := 1;
              if loc < Length(FLocals) then
                slotCount := FLocals[loc].SlotCount;
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
        // Get types from AST; fall back to local-type inference when sema has not
        // set ResolvedType (e.g. bodies of imported units are not analyzed by sema).
        lType := TAstBinOp(expr).Left.ResolvedType;
        if lType = atUnresolved then lType := InferExprType(TAstBinOp(expr).Left);
        rType := TAstBinOp(expr).Right.ResolvedType;
        if rType = atUnresolved then rType := InferExprType(TAstBinOp(expr).Right);

        // Check if both operands are float. Also handle the mixed case where one
        // side is known f64 and the other remains unresolved (Lyx forbids mixing,
        // so if one is f64 the other must be too).
        isFloatArith := (lType = atF64) and (rType = atF64)
                     or ((lType = atF64) and (rType = atUnresolved))
                     or ((rType = atF64) and (lType = atUnresolved));
        isFloatCmp := isFloatArith and (TAstBinOp(expr).Op in [tkEq, tkNeq, tkLt, tkLe, tkGt, tkGe]);

        // Check for string concatenation (pchar + pchar)
        isStringConcat := (lType = atPChar) and (rType = atPChar) and (TAstBinOp(expr).Op = tkPlus);

        t0 := NewTemp;
        case TAstBinOp(expr).Op of
          tkPlus:
            begin
              if isFloatArith then
                instr.Op := irFAdd
              else if isStringConcat then
              begin
                // String concatenation: call str_concat builtin
                instr.Op := irCallBuiltin;
                instr.Dest := t0;
                instr.ImmStr := 'str_concat';
                instr.ImmInt := 2;
                SetLength(instr.ArgTemps, 2);
                instr.ArgTemps[0] := t1;
                instr.ArgTemps[1] := t2;
                Emit(instr);
                Result := t0;
                Exit;
              end
              else
                instr.Op := irAdd;
            end;
            tkMinus:
              if isFloatArith then
                instr.Op := irFSub
              else
                instr.Op := irSub;
            tkStar:
              if isFloatArith then
                instr.Op := irFMul
              else
                instr.Op := irMul;
            tkSlash:
              if isFloatArith then
                instr.Op := irFDiv
              else
                instr.Op := irDiv;
            tkPercent:
              instr.Op := irMod;

            // Bitwise operators
            tkBitAnd:   instr.Op := irBitAnd;
            tkBitOr:    instr.Op := irBitOr;
            tkBitXor:   instr.Op := irBitXor;
            tkShiftLeft: instr.Op := irShl;
            tkShiftRight: instr.Op := irShr;

            tkEq:
              if isFloatCmp then instr.Op := irFCmpEq else instr.Op := irCmpEq;
            tkNeq:
              if isFloatCmp then instr.Op := irFCmpNeq else instr.Op := irCmpNeq;
            tkLt:
              if isFloatCmp then instr.Op := irFCmpLt else instr.Op := irCmpLt;
            tkLe:
              if isFloatCmp then instr.Op := irFCmpLe else instr.Op := irCmpLe;
            tkGt:
              if isFloatCmp then instr.Op := irFCmpGt else instr.Op := irCmpGt;
            tkGe:
              if isFloatCmp then instr.Op := irFCmpGe else instr.Op := irCmpGe;
            tkAnd:
              instr.Op := irAnd;
            tkOr:
              instr.Op := irOr;
          else
            FDiag.Error('unsupported binary operator ' + TokenKindToStr(TAstBinOp(expr).Op), expr.Span);
            Exit;
          end;

        // Set Dest, Src1, Src2 for binary operation
        instr.Dest := t0;
        instr.Src1 := t1;
        instr.Src2 := t2;
        Emit(instr);
        Result := t0;
      end;

    nkUnaryOp:
      begin
        t1 := LowerExpr(TAstUnaryOp(expr).Operand);
        if t1 < 0 then Exit;

        t0 := NewTemp;
        instr.Dest := t0;
        instr.Src1 := t1;
        case TAstUnaryOp(expr).Op of
          tkMinus:
            instr.Op := irNeg;
          tkNot:
            instr.Op := irNot; // Logical NOT (for boolean)
          tkBitNot:
            instr.Op := irBitNot; // Bitwise NOT (for integers)
        else
          FDiag.Error('unsupported unary operator ' + TokenKindToStr(TAstUnaryOp(expr).Op), expr.Span);
          Exit;
        end;
        Emit(instr);
        Result := t0;
      end;

    nkCall:
      begin
        call := TAstCall(expr);
        argCount := Length(call.Args);

        // Bootstrap compat: sizeof(TypeName) is a compile-time constant.
        // Handle before argument evaluation since the arg is a type name, not a variable.
        if call.Name = 'sizeof' then
        begin
          if (argCount = 1) and (call.Args[0] is TAstIdent) then
          begin
            vmtClassName := TAstIdent(call.Args[0]).Name;
            classIdx := FClassTypes.IndexOf(vmtClassName);
            if classIdx >= 0 then
            begin
              cd := TAstClassDecl(FClassTypes.Objects[classIdx]);
              EnsureClassLayout(cd);
              t0 := NewTemp;
              instr.Op := irConstInt;
              instr.Dest := t0;
              instr.ImmInt := cd.Size;
              Emit(instr);
              Result := t0;
              Exit;
            end;
          end;
          // Unknown type — emit 8 as conservative default
          t0 := NewTemp;
          instr.Op := irConstInt;
          instr.Dest := t0;
          instr.ImmInt := 8;
          Emit(instr);
          Result := t0;
          Exit;
        end;

        SetLength(argTemps, argCount);
        for i := 0 to High(call.Args) do
          argTemps[i] := LowerExpr(call.Args[i]);

        // Generic function call: monomorphize on demand
        if Length(call.TypeArgs) > 0 then
        begin
          // Build mangled name: _G_funcname__type1__type2__...
          mangledName := '_G_' + call.Name;
          for i := 0 to High(call.TypeArgs) do
            mangledName := mangledName + '__' + AurumTypeToStr(call.TypeArgs[i]);
          // Generate specialization if not already done
          if FGenericSpecializations.IndexOf(mangledName) < 0 then
          begin
            idx := FGenericFuncs.IndexOf(call.Name);
            if idx >= 0 then
              LowerGenericSpecialization(TAstFuncDecl(FGenericFuncs.Objects[idx]),
                mangledName, call.TypeArgs)
            else
              FDiag.Error('unknown generic function: ' + call.Name, expr.Span);
          end;
          // Emit call to specialized version
          t0 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := mangledName;
          instr.ImmInt := argCount;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := t0;
          Exit;
        end;

        // === In-Situ Data Visualizer (Debugging 2.0) ===
        // Inspect(expr) - gibt formatierte Debug-Ausgabe im Terminal aus
        if (call.Name = 'Inspect') or 
           ((call.Namespace = 'Debug') and (call.Name = 'Inspect')) then
        begin
          // irInspect: Src1=value temp, ImmStr=varname, ImmInt=argCount
          instr.Op := irInspect;
          instr.Dest := -1; // void return
          if argCount >= 1 then
          begin
            instr.Src1 := argTemps[0];
            if (call.Args[0] is TAstIdent) then
              instr.ImmStr := TAstIdent(call.Args[0]).Name
            else
              instr.ImmStr := '<expr>';
          end
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          Emit(instr);
          Result := -1;
        end
        // Builtin calls
        else if call.Name = 'abs' then
        begin
          // abs(n): if n < 0 then -n else n
          tZero := NewTemp;
          tGe0 := NewTemp;
          t0 := NewTemp;
          tResult := NewTemp;
          instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
          instr.Op := irCmpLt; instr.Dest := tGe0; instr.Src1 := argTemps[0]; instr.Src2 := tZero; Emit(instr);
          instr.Op := irNeg; instr.Dest := t0; instr.Src1 := argTemps[0]; Emit(instr);
          errLbl := NewLabel('Labs_pos');
          skipLbl := NewLabel('Labs_done');
          instr.Op := irBrFalse; instr.Src1 := tGe0; instr.LabelName := errLbl; Emit(instr);
          // negative: result = -n (use irAdd tResult = t0 + 0 as copy)
          instr.Op := irAdd; instr.Dest := tResult; instr.Src1 := t0; instr.Src2 := tZero; Emit(instr);
          instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
          // non-negative: result = n
          instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
          instr.Op := irAdd; instr.Dest := tResult; instr.Src1 := argTemps[0]; instr.Src2 := tZero; Emit(instr);
          instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
          Result := tResult;
        end
        else if call.Name = 'odd' then
        begin
          // odd(n): returns (n and 1) != 0
          t0 := NewTemp;
          tZero := NewTemp;
          tGe0 := NewTemp;
          instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 1; Emit(instr);
          instr.Op := irBitAnd; instr.Dest := t0; instr.Src1 := argTemps[0]; instr.Src2 := tZero; Emit(instr);
          instr.Op := irConstInt; instr.Dest := tGe0; instr.ImmInt := 0; Emit(instr);
          instr.Op := irCmpNeq; instr.Dest := NewTemp; instr.Src1 := t0; instr.Src2 := tGe0; Emit(instr);
          Result := instr.Dest;
        end
        else if (call.Name = 'PrintStr') or (call.Name = 'print_str') or ((call.Namespace = 'IO') and (call.Name = 'PrintStr')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1; // no return value
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
        else if (call.Name = 'PrintLn') or 
                ((call.Namespace = 'IO') and (call.Name = 'PrintLn')) then
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
        else if (call.Name = 'PrintInt') or (call.Name = 'print_int') or
                ((call.Namespace = 'IO') and (call.Name = 'PrintInt')) then
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
        else if (call.Name = 'PrintFloat') or
                ((call.Namespace = 'IO') and (call.Name = 'PrintFloat')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintFloat';
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
        else if (call.Name = 'printf') or
                ((call.Namespace = 'IO') and (call.Name = 'printf')) then
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
        else if (call.Name = 'getpid') or
                ((call.Namespace = 'OS') and (call.Name = 'getpid')) then
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
        else if (call.Name = 'open') or
                ((call.Namespace = 'IO') and (call.Name = 'open')) then
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
        else if (call.Name = 'read') or (call.Name = 'read_raw') or
                ((call.Namespace = 'IO') and ((call.Name = 'read') or (call.Name = 'read_raw'))) then
        begin
          // read/read_raw(fd: int64, buf: pchar/int64, count: int64) -> int64 (bytes read or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'read';  // Both use the same syscall
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'write') or
                ((call.Namespace = 'IO') and (call.Name = 'write')) then
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
        else if (call.Name = 'close') or
                ((call.Namespace = 'IO') and (call.Name = 'close')) then
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
        else if (call.Name = 'lseek') or
                ((call.Namespace = 'IO') and (call.Name = 'lseek')) then
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
        else if (call.Name = 'unlink') or
                ((call.Namespace = 'IO') and (call.Name = 'unlink')) then
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
          else if (call.Name = 'rename') or
                  ((call.Namespace = 'IO') and (call.Name = 'rename')) then
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
          // Bootstrap compat: syscall_sys_open(path, len, flags, mode) -> fd
          // Map to open(path, flags, mode) ignoring the length argument
          else if call.Name = 'syscall_sys_open' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'open';
            // Pass 3 args: path (arg0), flags (arg2), mode (arg3), skip len (arg1)
            SetLength(instr.ArgTemps, 3);
            if argCount >= 1 then instr.ArgTemps[0] := argTemps[0] else instr.ArgTemps[0] := -1;  // path
            if argCount >= 3 then instr.ArgTemps[1] := argTemps[2] else instr.ArgTemps[1] := -1;  // flags
            if argCount >= 4 then instr.ArgTemps[2] := argTemps[3] else instr.ArgTemps[2] := -1;  // mode
            instr.ImmInt := 3;
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 3 then instr.Src2 := argTemps[2] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: syscall_sys_write(fd, buf, len) -> bytes written
          else if call.Name = 'syscall_sys_write' then
          begin
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
          // Bootstrap compat: syscall_sys_close(fd)
          else if call.Name = 'syscall_sys_close' then
          begin
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
          // sys_close(fd: int64) -> int64 (direct syscall, not external)
          else if call.Name = 'sys_close' then
          begin
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
          // sys_read(fd: int64, buf: Pointer, count: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_read' then
          begin
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
          // sys_write(fd: int64, buf: Pointer, count: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_write' then
          begin
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
          // sys_fork() -> int64
          else if call.Name = 'sys_fork' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'fork';
            instr.ImmInt := 0;
            SetLength(instr.ArgTemps, 0);
            Emit(instr);
            Result := t0;
          end
          // sys_execve(path: pchar, argv: int64, envp: int64) -> int64
          else if call.Name = 'sys_execve' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'execve';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_wait4(pid: int64, status: int64, options: int64) -> int64
          else if call.Name = 'sys_wait4' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'wait4';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_select/nfds: int64, readfds: Pointer, writefds: Pointer, exceptfds: Pointer, timeout: Pointer) -> int64 (direct syscall)
          else if call.Name = 'sys_select' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'sys_select';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_poll(fds: Pointer, nfds: int64, timeout: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_poll' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'sys_poll';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'peek8') then
          begin
            // peek8(addr: int64) -> int64 (byte value)
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek8';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke8') then
          begin
            // poke8(addr: int64, value: int64) -> void
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke8';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek16') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek16';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke16') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke16';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek32') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek32';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke32') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke32';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek64') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke64') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peekf64') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peekf64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'pokef64') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'pokef64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
        else if (call.Name = 'mkdir') or
                ((call.Namespace = 'IO') and (call.Name = 'mkdir')) then
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
        else if (call.Name = 'rmdir') or
                ((call.Namespace = 'IO') and (call.Name = 'rmdir')) then
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
         else if (call.Name = 'chmod') or
                 ((call.Namespace = 'IO') and (call.Name = 'chmod')) then
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
           Emit(instr);
           Result := t0;
         end
         // === Socket System Calls (for std.net) ===
         else if call.Name = 'sys_socket' then
         begin
           // sys_socket(domain: int64, type: int64, protocol: int64) -> int64
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_socket';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_bind' then
         begin
           // sys_bind(sockfd, addr, addrlen) -> int64
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_bind';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_listen' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_listen';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_accept' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_accept';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_connect' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_connect';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_recvfrom' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_recvfrom';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_sendto' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_sendto';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_setsockopt' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_setsockopt';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_getsockopt' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_getsockopt';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_fcntl' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_fcntl';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_shutdown' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_shutdown';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: alloc(size) = mmap(0, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
          else if call.Name = 'alloc' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'alloc';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: ArgvGet(argv, i) = *(argv + i*8)
          else if call.Name = 'ArgvGet' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'ArgvGet';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // === mmap/munmap for memory allocation ===
          else if call.Name = 'mmap' then
          begin
            // mmap(addr, length, prot, flags, fd, offset) -> int64 (pointer)
            // Bootstrap compat: mmap(size, prot) mit 2 Argumenten
            // - mmap(size, prot) -> mmap(0, size, prot, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'mmap';
            instr.ImmInt := argCount;
            // Expand to 6 arguments for the backend
            SetLength(instr.ArgTemps, 6);
            
            if argCount = 2 then
            begin
              // Bootstrap 2-arg mode: mmap(size, prot)
              // Der Bootstrap verwendet: mmap(size, prot)
              // Map to full 6-arg: mmap(0, size, prot, 34, -1, 0)
              // WICHTIG: argTemps[0] = erstes Argument (size), argTemps[1] = zweites Argument (prot)
              // WIR MÜSSEN SIE TAUSCHEN: size ist length, prot ist prot
              instr.ArgTemps[0] := 0;                       // addr = NULL
              instr.ArgTemps[1] := argTemps[0];             // length = size (erstes Argument)
              instr.ArgTemps[2] := argTemps[1];             // prot (zweites Argument)
              instr.ArgTemps[3] := 34;                      // flags = MAP_PRIVATE | MAP_ANONYMOUS
              instr.ArgTemps[4] := -1;                      // fd = -1
              instr.ArgTemps[5] := 0;                       // offset = 0
            end
            else if argCount >= 3 then
            begin
              // Full 3+ arg mode - use provided values
              // arg[0]=addr, arg[1]=length, arg[2]=prot, arg[3]=flags, arg[4]=fd, arg[5]=offset
              for i := 0 to argCount - 1 do
              begin
                if i < 6 then instr.ArgTemps[i] := argTemps[i];
              end;
              // Fill remaining with defaults
              for i := argCount to 5 do
                instr.ArgTemps[i] := 0;
            end
            else if argCount = 1 then
            begin
              // mmap(size) -> mmap(0, size, 3, 34, -1, 0)
              instr.ArgTemps[0] := 0;                      // addr
              instr.ArgTemps[1] := argTemps[0];            // length = size
              instr.ArgTemps[2] := 3;                     // prot = READ|WRITE
              instr.ArgTemps[3] := 34;                     // flags
              instr.ArgTemps[4] := -1;                     // fd
              instr.ArgTemps[5] := 0;                      // offset
            end
            else
            begin
              // No arguments - all zeros
              for i := 0 to 5 do
                instr.ArgTemps[i] := 0;
            end;
            if Length(instr.ArgTemps) >= 1 then instr.Src1 := instr.ArgTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if call.Name = 'munmap' then
          begin
            // munmap(addr, length) -> int64
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'munmap';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // write_raw(fd, buf, len) -> int64
          else if call.Name = 'write_raw' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'write_raw';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Buffer/primitive calls
          else if call.Name = 'buf_put_byte' then
        begin
          // buf_put_byte(buf: int64, idx: int64, b: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'buf_put_byte';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          // 3. Argument via LabelName übergeben
          if argCount >= 3 then
            instr.LabelName := IntToStr(argTemps[2]);
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'buf_get_byte' then
        begin
          // buf_get_byte(buf: int64, idx: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'buf_get_byte';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        // === Dynamic growable strings (F2) ===
        else if call.Name = 'StrLen' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrLen';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrCharAt' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrCharAt';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrSetChar' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrSetChar';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrNew' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrNew';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrFree' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrFree';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrAppend' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrAppend';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrFromInt' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrFromInt';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        // S1: String split primitives
        else if call.Name = 'StrFindChar' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrFindChar';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrSub' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrSub';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S2: StringBuilder
        else if call.Name = 'StrAppendStr' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrAppendStr';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrConcat' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrConcat';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrCopy' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrCopy';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S3: IntToStr alias
        else if call.Name = 'IntToStr' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrFromInt';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S4: FileGetSize
        else if call.Name = 'FileGetSize' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'FileGetSize';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S5: HashMap
        else if call.Name = 'HashNew' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashNew';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'HashSet' then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'HashSet';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        else if call.Name = 'HashGet' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashGet';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'HashHas' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashHas';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S6: Argv access
        else if call.Name = 'GetArgC' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArgC';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'GetArg' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArg';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'GetArgV' then
        begin
          // GetArgV(): pchar — returns pointer to argv[0] (raw C argv array)
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArgV';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S7: String comparison
        else if call.Name = 'StrStartsWith' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrStartsWith';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrEndsWith' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrEndsWith';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrEquals' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrEquals';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // profile_enter(fn_name) - Profiler function entry (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'enter')) or
              (call.Name = 'profile_enter') then
        begin
          // If using global name, handle same as Profile.enter
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_enter';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // profile_leave(fn_name) - Profiler function leave (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'leave')) or
              (call.Name = 'profile_leave') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_leave';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // profile_report() - Print profile report (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'report')) or
              (call.Name = 'profile_report') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_report';
          instr.ImmInt := 0;
          Emit(instr); Result := -1;
        end
        // trace(msg: pchar) - Trace output (WP-4)
        else if (call.Name = 'trace') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // trace_int(val: int64) - Trace integer (WP-4)
        else if (call.Name = 'trace_int') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace_int';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // trace_str(label: pchar, val: pchar) - Trace string (WP-4)
        else if (call.Name = 'trace_str') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace_str';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // breakpoint() - Debugger breakpoint (WP-5)
        else if (call.Name = 'breakpoint') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'breakpoint';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // sqrt(x: f64) - Square root
        else if (call.Name = 'sqrt') then
        begin
          t0 := NewTemp;
          instr.Op := irFSqrt;
          instr.Dest := t0;
          instr.Src1 := argTemps[0];
          instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'VerifyIntegrity') or
                 ((call.Namespace = 'Integrity') and (call.Name = 'VerifyIntegrity'))) then
        begin
          // Integrity.VerifyIntegrity() -> bool (aerospace-todo P0 #45)
          // Returns true if code integrity is verified (CRC32 match with .meta_safe section)
          t0 := NewTemp;
          instr.Op := irVerifyIntegrity;
          instr.Dest := t0;
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexMatch') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Match'))) then
        begin
          useCompiled := (argCount >= 2) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexMatchCompiled';
            SetLength(callTemps, 3);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
          end
          else
          begin
            callName := 'RegexMatch';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode
          // cmExternal has highest priority, then cmImported (must check before
          // FModule.FindFunction because imported functions get added to FModule
          // when compiled, and we must not treat them as cmInternal).
          if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
          begin
            fn := FModule.FindFunction(callName);
            if Assigned(fn) then
            begin
              if fn.NeedsStaticLink then
                instr.CallMode := cmStaticLink
              else
                instr.CallMode := cmInternal;
            end
            else
              instr.CallMode := cmInternal;
          end;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexSearch') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Search'))) then
        begin
          useCompiled := (argCount >= 2) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexSearchCompiled';
            SetLength(callTemps, 3);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
          end
          else
          begin
            callName := 'RegexSearch';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode: check if function is defined locally first
          fn := FModule.FindFunction(callName);
          if Assigned(fn) then
            instr.CallMode := cmInternal
          else if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
            instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexReplace') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Replace'))) then
        begin
          useCompiled := (argCount >= 3) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexReplaceCompiled';
            SetLength(callTemps, 4);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
            callTemps[3] := argTemps[2];
          end
          else
          begin
            callName := 'RegexReplace';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode: check if function is defined locally first
          fn := FModule.FindFunction(callName);
          if Assigned(fn) then
            instr.CallMode := cmInternal
          else if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
            instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else
        begin
          // Handle unprocessed namespace method calls: obj.method(args)
          // This occurs in imported class method bodies where sema didn't run.
          // The parser generates call.Namespace = "self" (or another var), call.Name = "method".
          if call.Namespace <> '' then
          begin
            loc := ResolveLocal(call.Namespace);
            if loc >= 0 then
            begin
              // Determine class type of the receiver
              mangled := '';
              if (call.Namespace = 'self') and Assigned(FCurrentClassDecl) then
                mangled := '_L_' + FCurrentClassDecl.Name + '_' + call.Name
              else if (loc < Length(FLocals)) and (FLocals[loc].TypeName <> '') then
                mangled := '_L_' + FLocals[loc].TypeName + '_' + call.Name;
              if mangled <> '' then
              begin
                // Load receiver
                t1 := NewTemp;
                instr.Op := irLoadLocal;
                instr.Dest := t1;
                instr.Src1 := loc;
                Emit(instr);
                // Emit: _L_ClassName_MethodName(receiver, arg1, arg2, ...)
                t0 := NewTemp;
                instr.Op := irCall;
                instr.Dest := t0;
                instr.ImmStr := mangled;
                instr.ImmInt := argCount + 1;
                instr.IsVirtualCall := False;
                instr.VMTIndex := -1;
                instr.SelfSlot := -1;
                instr.CallMode := cmInternal;
                SetLength(instr.ArgTemps, argCount + 1);
                instr.ArgTemps[0] := t1;
                for i := 0 to argCount - 1 do
                  instr.ArgTemps[i + 1] := argTemps[i];
                Emit(instr);
                Result := t0;
                Exit;
              end;
              // WP8: local Map/Set variable method calls (myMap.insert(k,v) etc.)
              recvType2 := GetLocalType(loc);
              if recvType2 = atMap then
              begin
                t1 := NewTemp; instr := Default(TIRInstr); instr.Op := irLoadLocal; instr.Dest := t1; instr.Src1 := loc; Emit(instr);
                if call.Name = 'get' then
                begin
                  t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapGet; instr.Dest := t0; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := t0;
                end
                else if call.Name = 'insert' then
                begin
                  instr := Default(TIRInstr); instr.Op := irMapSet; instr.Src1 := t1; instr.Src2 := argTemps[0]; instr.Src3 := argTemps[1]; Emit(instr);
                  Result := -1;
                end
                else if call.Name = 'remove' then
                begin
                  instr := Default(TIRInstr); instr.Op := irMapRemove; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := -1;
                end
                else if call.Name = 'contains' then
                begin
                  t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapContains; instr.Dest := t0; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := t0;
                end
                else if call.Name = 'len' then
                begin
                  t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapLen; instr.Dest := t0; instr.Src1 := t1; Emit(instr);
                  Result := t0;
                end
                else if call.Name = 'free' then
                begin
                  instr := Default(TIRInstr); instr.Op := irMapFree; instr.Src1 := t1; Emit(instr);
                  Result := -1;
                end;
                Exit;
              end
              else if recvType2 = atSet then
              begin
                t1 := NewTemp; instr := Default(TIRInstr); instr.Op := irLoadLocal; instr.Dest := t1; instr.Src1 := loc; Emit(instr);
                if call.Name = 'add' then
                begin
                  instr := Default(TIRInstr); instr.Op := irSetAdd; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := -1;
                end
                else if call.Name = 'remove' then
                begin
                  instr := Default(TIRInstr); instr.Op := irSetRemove; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := -1;
                end
                else if call.Name = 'contains' then
                begin
                  t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irSetContains; instr.Dest := t0; instr.Src1 := t1; instr.Src2 := argTemps[0]; Emit(instr);
                  Result := t0;
                end
                else if call.Name = 'len' then
                begin
                  t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irSetLen; instr.Dest := t0; instr.Src1 := t1; Emit(instr);
                  Result := t0;
                end
                else if call.Name = 'free' then
                begin
                  instr := Default(TIRInstr); instr.Op := irSetFree; instr.Src1 := t1; Emit(instr);
                  Result := -1;
                end;
                Exit;
              end;
            end;
          end;

          // === Dynamic Array Operations (push, len, pop, free) ===
          // These must come BEFORE the regular function call handling
          if (call.Name = 'push') or (call.Name = 'append') then
          begin
            // push(array, value) - adds element to dynamic array
            // Src1 = LOCAL slot index of the fat-pointer (NOT a temp)
            instr := Default(TIRInstr);
            instr.Op := irDynArrayPush;
            if (argCount >= 1) and (call.Args[0] is TAstIdent) then
              instr.Src1 := ResolveLocal(TAstIdent(call.Args[0]).Name)
            else
              instr.Src1 := argTemps[0];
            instr.Src2 := argTemps[1];  // value to push (temp)
            instr.Dest := -1;
            Emit(instr);
            Result := -1;
            Exit;
          end
          else if call.Name = 'len' then
          begin
            // len(array) - returns length of dynamic array
            // Src1 = LOCAL slot index of the fat-pointer (NOT a temp)
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irDynArrayLen;
            if (argCount >= 1) and (call.Args[0] is TAstIdent) then
              instr.Src1 := ResolveLocal(TAstIdent(call.Args[0]).Name)
            else
              instr.Src1 := argTemps[0];
            instr.Dest := t0;
            Emit(instr);
            Result := t0;
            Exit;
          end
          else if call.Name = 'pop' then
          begin
            // pop(array) - removes and returns last element
            // Src1 = LOCAL slot index of the fat-pointer (NOT a temp)
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irDynArrayPop;
            if (argCount >= 1) and (call.Args[0] is TAstIdent) then
              instr.Src1 := ResolveLocal(TAstIdent(call.Args[0]).Name)
            else
              instr.Src1 := argTemps[0];
            instr.Dest := t0;
            Emit(instr);
            Result := t0;
            Exit;
          end
          else if call.Name = 'free' then
          begin
            // free(array) - frees the dynamic array memory
            // Src1 = LOCAL slot index of the fat-pointer (NOT a temp)
            instr := Default(TIRInstr);
            instr.Op := irDynArrayFree;
            if (argCount >= 1) and (call.Args[0] is TAstIdent) then
              instr.Src1 := ResolveLocal(TAstIdent(call.Args[0]).Name)
            else
              instr.Src1 := argTemps[0];
            instr.Dest := -1;
            Emit(instr);
            Result := -1;
            Exit;
          end;

          // Regular function call (or function pointer call)
          t0 := NewTemp;

          // Check if this is a function pointer call (indirect call)
          if call.IsIndirectCall then
          begin
            // This is an indirect call via function pointer
            // First, load the function pointer value (the variable name is in call.Name)
            // We need to resolve the variable and load its value
            
            // Load the function pointer value from the variable
            // call.Name contains the variable name (e.g., "cb")
            instr := Default(TIRInstr);
            instr.Op := irLoadLocal;  // Load the function pointer value
            instr.Dest := t0;
            instr.Src1 := ResolveLocal(call.Name);  // local slot index
            if instr.Src1 < 0 then
            begin
              // Try as global variable
              instr.Op := irLoadGlobal;
              instr.Src1 := -1;
              instr.ImmStr := call.Name;
            end;
            Emit(instr);
            
            // Now emit indirect call using the loaded function pointer
            instr := Default(TIRInstr);
            instr.Op := irVarCall;
            instr.Dest := t0;
            instr.Src1 := t0;  // Use the loaded function pointer as the call target
            instr.ImmInt := argCount;
            instr.IsVirtualCall := False;
            instr.VMTIndex := -1;
            instr.SelfSlot := -1;
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            Emit(instr);
            Result := t0;
          end
          else
          begin
            // Regular direct function call
            instr.Op := irCall;
            instr.Dest := t0;
            instr.ImmStr := call.Name;
            instr.ImmInt := argCount;
            callName := call.Name;
            instr.IsVirtualCall := False;
            instr.VMTIndex := -1;
            instr.SelfSlot := -1;
           
            // Check if this is a method call (mangled name starts with _L_ or _METHOD_)
            if (Length(call.Name) > 3) and ((Copy(call.Name, 1, 3) = '_L_') or (Copy(call.Name, 1, 8) = '_METHOD_')) then
            begin
              // For _METHOD_<methodname>: extract method name and look up class from first argument's type
              // For _L_<ClassName>_<MethodName>: extract class name and method name from mangled name
              if Copy(call.Name, 1, 8) = '_METHOD_' then
              begin
                // Format: _METHOD_<methodname>
                // Need to look up class from receiver type (call.Args[0])
                vmtMethodName := Copy(call.Name, 9, MaxInt);
                vmtClassName := '';

                // WP8: Map/Set method call on any receiver (local var or struct field)
                // argTemps[0] = receiver pointer, argTemps[1..n] = actual args
                if (argCount >= 1) and Assigned(call.Args) and Assigned(call.Args[0]) and
                   (call.Args[0].ResolvedType in [atMap, atSet]) then
                begin
                  recvTemp := argTemps[0];
                  if call.Args[0].ResolvedType = atMap then
                  begin
                    if vmtMethodName = 'get' then
                    begin
                      t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapGet; instr.Dest := t0; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := t0;
                    end
                    else if vmtMethodName = 'insert' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irMapSet; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; instr.Src3 := argTemps[2]; Emit(instr);
                      Result := -1;
                    end
                    else if vmtMethodName = 'remove' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irMapRemove; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := -1;
                    end
                    else if vmtMethodName = 'contains' then
                    begin
                      t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapContains; instr.Dest := t0; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := t0;
                    end
                    else if vmtMethodName = 'len' then
                    begin
                      t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapLen; instr.Dest := t0; instr.Src1 := recvTemp; Emit(instr);
                      Result := t0;
                    end
                    else if vmtMethodName = 'free' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irMapFree; instr.Src1 := recvTemp; Emit(instr);
                      Result := -1;
                    end;
                  end
                  else // atSet
                  begin
                    if vmtMethodName = 'add' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irSetAdd; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := -1;
                    end
                    else if vmtMethodName = 'remove' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irSetRemove; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := -1;
                    end
                    else if vmtMethodName = 'contains' then
                    begin
                      t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irSetContains; instr.Dest := t0; instr.Src1 := recvTemp; instr.Src2 := argTemps[1]; Emit(instr);
                      Result := t0;
                    end
                    else if vmtMethodName = 'len' then
                    begin
                      t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irSetLen; instr.Dest := t0; instr.Src1 := recvTemp; Emit(instr);
                      Result := t0;
                    end
                    else if vmtMethodName = 'free' then
                    begin
                      instr := Default(TIRInstr); instr.Op := irSetFree; instr.Src1 := recvTemp; Emit(instr);
                      Result := -1;
                    end;
                  end;
                  Exit;
                end;

                // Get receiver's type from semantic analysis
                if (argCount >= 1) and Assigned(call.Args) and Assigned(call.Args[0]) then
                begin
                  recvExpr := call.Args[0];

                  // Try to get the variable name from Ident node
                  if recvExpr is TAstIdent then
                  begin
                    // Look up the local slot by name
                    loc := ResolveLocal(TAstIdent(recvExpr).Name);
                    if loc >= 0 then
                    begin
                      // Check FLocalTypeNames for class types
                      if (loc < Length(FLocals)) and (FLocals[loc].TypeName <> '') then
                        vmtClassName := FLocals[loc].TypeName;
                    end;
                  end;
                end;
              end
              else
              begin
                // Format: _L_ClassName_methodName
                posIdx := Pos('_', Copy(call.Name, 4, MaxInt));
                if posIdx > 0 then
                begin
                  vmtClassName := Copy(call.Name, 4, posIdx - 1);
                  vmtMethodName := Copy(call.Name, 4 + posIdx, MaxInt);
                  
                  // Also need to find the receiver's slot for SelfSlot
                  // The receiver is in call.Args[0]
                  if (argCount >= 1) and Assigned(call.Args) and Assigned(call.Args[0]) then
                  begin
                    recvExpr := call.Args[0];
                    if recvExpr is TAstIdent then
                    begin
                      loc := ResolveLocal(TAstIdent(recvExpr).Name);
                    end;
                  end;
                end;
              end;
              
              // Look up class in FClassTypes if we have a class name
              if vmtClassName <> '' then
              begin
                classIdx := FClassTypes.IndexOf(vmtClassName);
                if classIdx >= 0 then
                begin
                  cd := TAstClassDecl(FClassTypes.Objects[classIdx]);
                  // First check if class has virtual methods (VMT exists)
                  if Length(cd.VirtualMethods) > 0 then
                  begin
                    // Look for method in VirtualMethods list (has correct VMT indices)
                    for vmtIdx := 0 to High(cd.VirtualMethods) do
                    begin
                      if Assigned(cd.VirtualMethods[vmtIdx]) and
                         (cd.VirtualMethods[vmtIdx].Name = vmtMethodName) then
                      begin
                        // This is a virtual call - method is in VMT
                        instr.IsVirtualCall := True;
                        instr.VMTIndex := vmtIdx;
                        // Store the local slot for self
                        instr.SelfSlot := loc;
                        Break;
                      end;
                    end;
                  end;

                  // Fallback: also check in Methods list (for non-virtual methods)
                  if not instr.IsVirtualCall then
                  begin
                    for methodIdx := 0 to High(cd.Methods) do
                    begin
                      if cd.Methods[methodIdx].Name = vmtMethodName then
                      begin
                        // Check if method is explicitly virtual
                        if cd.Methods[methodIdx].IsVirtual then
                        begin
                          instr.IsVirtualCall := True;
                          instr.VMTIndex := cd.Methods[methodIdx].VirtualTableIndex;
                          // Store the local slot for self
                          instr.SelfSlot := loc;
                        end;
                        Break;
                      end;
                    end;
                  end;
                end;
              end;
            end;
          
          // Bootstrap compat: for _METHOD_ calls that are NOT virtual, translate the call
          // name to _L_ClassName_MethodName so the jump patcher can resolve it.
          if (Copy(call.Name, 1, 8) = '_METHOD_') and (not instr.IsVirtualCall) and (vmtClassName <> '') then
            instr.ImmStr := '_L_' + vmtClassName + '_' + vmtMethodName;

          // Determine call mode based on function origin
          // cmExternal has highest priority, then cmImported (must check before
          // FModule.FindFunction because imported functions get added to FModule
          // when compiled, and we must not treat them as cmInternal).
          if FExternFuncs.IndexOf(call.Name) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(call.Name) >= 0 then
            instr.CallMode := cmImported
          else
          begin
            fn := FModule.FindFunction(call.Name);
            if Assigned(fn) then
            begin
              if fn.NeedsStaticLink then
                instr.CallMode := cmStaticLink
              else
                instr.CallMode := cmInternal;
            end
            else
              instr.CallMode := cmInternal;
          end;
          // For regular calls, callTemps is never set above — use argTemps directly
          if Length(callTemps) = 0 then
            callTemps := argTemps;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
          end;
        end;
      end;

    nkIndexAccess:
      begin
        // --- WP6: struct collection field indexed access ---
        if TAstIndexAccess(expr).Obj is TAstFieldAccess then
        begin
          fAccess    := TAstFieldAccess(TAstIndexAccess(expr).Obj);
          fldArrLen  := 0;
          fldElemType := atUnresolved;
          fldType    := fAccess.FieldType;
          fldOffset  := fAccess.FieldOffset;

          // Look up full field metadata from struct declaration
          if fAccess.OwnerName <> '' then
          begin
            structIdx := FStructTypes.IndexOf(fAccess.OwnerName);
            if structIdx >= 0 then
            begin
              sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
              for fi := 0 to High(sd.Fields) do
                if sd.Fields[fi].Name = fAccess.Field then
                begin
                  fldArrLen   := sd.Fields[fi].ArrayLen;
                  fldElemType := sd.Fields[fi].ElemType;
                  fldType     := sd.Fields[fi].FieldType;
                  Break;
                end;
            end;
          end;

          isHeap := (fAccess.OwnerName <> '') and
                    (FClassTypes.IndexOf(fAccess.OwnerName) >= 0);

          // static [N]T field: addrBase = struct_base ∓ fldOffset, then irLoadElem
          if fldArrLen > 0 then
          begin
            t1 := LowerExpr(fAccess.Obj);
            if t1 < 0 then Exit;
            if fldElemType <> atUnresolved then
              elemSize := TypeSizeBytes(fldElemType)
            else
              elemSize := TypeSizeBytes(fldType);
            if elemSize < 1 then elemSize := 8;
            t2 := LowerExpr(TAstIndexAccess(expr).Index);
            if t2 < 0 then Exit;
            // bounds check: index >= N → out of bounds
            tLen    := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := fldArrLen; Emit(instr);
            tOk     := NewTemp; instr := Default(TIRInstr); instr.Op := irCmpGe; instr.Dest := tOk; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
            errLbl  := NewLabel('Larr_oob');
            instr := Default(TIRInstr); instr.Op := irBrTrue; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);
            // addrBase = struct_base + fldOffset (both heap and stack use actual address + offset)
            tOffset  := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := tOffset; instr.ImmInt := fldOffset; Emit(instr);
            addrBase := NewTemp; instr := Default(TIRInstr);
            instr.Op := irAdd;
            instr.Dest := addrBase; instr.Src1 := t1; instr.Src2 := tOffset; Emit(instr);
            t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irLoadElem; instr.Dest := t0; instr.Src1 := addrBase; instr.Src2 := t2; instr.ImmInt := elemSize; Emit(instr);
            Result := t0;
            skipLbl := NewLabel('Larr_ok');
            instr := Default(TIRInstr); instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
            Exit;
          end
          // dynamic []T field: fat-pointer (ptr @ fldOffset, len @ fldOffset+8)
          else if (fldArrLen < 0) or (fldType = atDynArray) then
          begin
            t1 := LowerExpr(fAccess.Obj);
            if t1 < 0 then Exit;
            ptrTemp := NewTemp; instr := Default(TIRInstr);
            if isHeap then instr.Op := irLoadFieldHeap else instr.Op := irLoadField;
            instr.Dest := ptrTemp; instr.Src1 := t1; instr.ImmInt := fldOffset; instr.FieldSize := 8; Emit(instr);
            lenTemp := NewTemp; instr := Default(TIRInstr);
            if isHeap then instr.Op := irLoadFieldHeap else instr.Op := irLoadField;
            instr.Dest := lenTemp; instr.Src1 := t1; instr.ImmInt := fldOffset + 8; instr.FieldSize := 8; Emit(instr);
            t2 := LowerExpr(TAstIndexAccess(expr).Index);
            if t2 < 0 then Exit;
            tZero   := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
            tGe0    := NewTemp; instr := Default(TIRInstr); instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
            tLtLen  := NewTemp; instr := Default(TIRInstr); instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := lenTemp; Emit(instr);
            tOk     := NewTemp; instr := Default(TIRInstr); instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
            errLbl  := NewLabel('Larr_oob');
            instr := Default(TIRInstr); instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);
            if fldElemType <> atUnresolved then
              elemSize := TypeSizeBytes(fldElemType)
            else
              elemSize := 8;
            t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irLoadElem; instr.Dest := t0; instr.Src1 := ptrTemp; instr.Src2 := t2; instr.ImmInt := elemSize; Emit(instr);
            Result := t0;
            skipLbl := NewLabel('Larr_ok');
            instr := Default(TIRInstr); instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr := Default(TIRInstr); instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr := Default(TIRInstr); instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
            Exit;
          end
          // Map<K,V> field: load map ptr, then irMapGet
          else if fldType = atMap then
          begin
            t1 := LowerExpr(fAccess.Obj);
            if t1 < 0 then Exit;
            mapTemp := NewTemp; instr := Default(TIRInstr);
            if isHeap then instr.Op := irLoadFieldHeap else instr.Op := irLoadField;
            instr.Dest := mapTemp; instr.Src1 := t1; instr.ImmInt := fldOffset; instr.FieldSize := 8; Emit(instr);
            t2 := LowerExpr(TAstIndexAccess(expr).Index);
            if t2 < 0 then Exit;
            t0 := NewTemp; instr := Default(TIRInstr); instr.Op := irMapGet; instr.Dest := t0; instr.Src1 := mapTemp; instr.Src2 := t2; Emit(instr);
            Result := t0;
            Exit;
          end;
          // fall through for non-collection fields (scalar etc.)
        end;

        // Check if this is a Map access (map[key])
        if TAstIndexAccess(expr).Obj.ResolvedType = atMap then
        begin
          // Map access: map[key] -> irMapGet(map, key)
          // Lower the map (object)
          t1 := LowerExpr(TAstIndexAccess(expr).Obj);
          if t1 < 0 then Exit;

          // Lower the key
          t2 := LowerExpr(TAstIndexAccess(expr).Index);
          if t2 < 0 then Exit;

          // Emit map_get
          t0 := NewTemp;
          instr.Op := irMapGet;
          instr.Dest := t0;
          instr.Src1 := t1;  // map
          instr.Src2 := t2;  // key
          Emit(instr);
          Result := t0;
          Exit;
        end;

        // Check if this is a Set access (not supported - sets are not indexable)
        if TAstIndexAccess(expr).Obj.ResolvedType = atSet then
        begin
          FDiag.Error('sets are not indexable, use "in" operator to check membership', expr.Span);
          Exit;
        end;

        // Regular array access
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
              // Skip over error handler after successful load
              skipLbl := NewLabel('Larr_ok');
              instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
              instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
              msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
              instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
              codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
              instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
              instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
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
              // Check if this is a dynamic array (fat-pointer)
              arrLen := GetLocalArrayLen(loc);
              if (loc < Length(FLocals)) and FLocals[loc].IsDynArray then
              begin
                // Dynamic array: ptr is stored in slot loc, load it as base address
                t1 := NewTemp;
                instr.Op := irLoadLocal;
                instr.Dest := t1;
                instr.Src1 := loc;  // load ptr from fat-pointer slot 0
                Emit(instr);

                // Lower index
                t2 := LowerExpr(TAstIndexAccess(expr).Index);
                if t2 < 0 then
                  Exit;

                // Runtime bounds check against len (slot loc+1)
                tLen := NewTemp;
                instr.Op := irLoadLocal; instr.Dest := tLen; instr.Src1 := loc + 1; Emit(instr);
                tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
                tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
                tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
                tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
                errLbl := NewLabel('Larr_oob');
                instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);

                t0 := NewTemp;
                instr.Op := irLoadElem;
                instr.Dest := t0;
                instr.Src1 := t1;  // heap pointer (array data)
                instr.Src2 := t2;  // index
                Emit(instr);
                Result := t0;

                // Skip over error handler
                skipLbl := NewLabel('Larr_ok');
                instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);

                // Error handler
                instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
                msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
                instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
                codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
                instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
                instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
                Exit;
              end;

              // For local arrays, elements are stored in REVERSE order:
              // arr[0] at slot loc + arrLen - 1, arr[1] at slot loc + arrLen - 2, etc.
              // This is because stack grows downward and we want arr[index] = base + index*8
              arrLen := GetLocalArrayLen(loc);
              if arrLen > 0 then
                baseSlot := loc + arrLen - 1  // arr[0] at highest slot
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
                // Using CmpGe: if index >= length, jump to error
                // CmpGe gives 1 when index >= length (invalid), 0 when index < length (valid)
                // BrTrue jumps when value is 1 (invalid), so BrTrue CmpGe jumps on invalid index
                if arrLen > 0 then
                begin
                  errLbl := NewLabel('Larr_oob');
                  // tLen = length (constant)
                  tLen := NewTemp;
                  instr.Op := irConstInt;
                  instr.Dest := tLen;
                  instr.ImmInt := arrLen;
                  Emit(instr);
                  
                  // tOk = (index >= tLen) ? 1 : 0
                  tOk := NewTemp;
                  instr.Op := irCmpGe;
                  instr.Dest := tOk;
                  instr.Src1 := t2;  // index
                  instr.Src2 := tLen;  // length
                  Emit(instr);
                  
                // If tOk == 1 (index >= length, invalid), jump to error
                   instr.Op := irBrTrue;
                   instr.Src1 := tOk;
                   instr.LabelName := errLbl;
                   Emit(instr);
                end;

                t0 := NewTemp;
                instr.Op := irLoadElem;
                instr.Dest := t0;
                instr.Src1 := t1;  // array base address
                instr.Src2 := t2;  // index
                instr.LabelName := '';  // Clear any residual label
                Emit(instr);
                Result := t0;

                if arrLen > 0 then
                begin
                  skipLbl := NewLabel('Larr_ok');
                  instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
                  instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
                  msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
                  instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
                  codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
                  instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
                  instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
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
          // Check if this is pchar indexing (byte access)
          if (TAstIndexAccess(expr).Obj.ResolvedType = atPChar) or
             (TAstIndexAccess(expr).Obj.ResolvedType = atPCharNullable) then
            instr.ImmInt := 1  // element size = 1 byte for pchar
          else
            instr.ImmInt := 8;  // element size = 8 bytes for int64 arrays
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
        castTypeName := TAstCast(expr).CastTypeName;

        // Unit type conversion: value * (srcFactor / tgtFactor)
        if TAstCast(expr).IsUnitConversion then
        begin
          t0 := NewTemp;
          t2 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op       := irConstFloat;
          instr.Dest     := t2;
          instr.ImmFloat := TAstCast(expr).UnitConvFactor;
          Emit(instr);
          instr := Default(TIRInstr);
          instr.Op   := irFMul;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.Src2 := t2;
          Emit(instr);
          Result := t0;
          Exit;
        end;

        t0 := NewTemp;

        // Check for class cast (target is a class name)
        if (castTypeName <> '') and (FClassTypes.IndexOf(castTypeName) >= 0) then
        begin
          // Class cast is a no-op in IR (just a type annotation / pointer reinterpret).
          Result := t1;
          Exit;
        end
        // Check for int64 -> float conversion
        else if (ltype = atInt64) and (rType = atF64) then
        begin
          instr.Op := irIToF;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        // Check for float -> int64 conversion
        else if (ltype = atF64) and (rType = atInt64) then
        begin
          instr.Op := irFToI;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        // Check for function pointer to int64 (function address cast)
        else if TAstCast(expr).IsFunctionToPointer then
        begin
          // This is a cast from function to int64 - return the function address
          // The expression could be a function call or a function name (identifier)
          
          // Check if the source expression is a function identifier (not a call)
          if TAstCast(expr).Expr is TAstIdent then
          begin
            // Function name cast to int64 - load the function address
            // Use irLoadGlobalAddr to get the function address
            instr := Default(TIRInstr);
            instr.Op := irLoadGlobalAddr;
            instr.Dest := t0;
            instr.ImmStr := TAstIdent(TAstCast(expr).Expr).Name;
            Emit(instr);
          end
          else
          begin
            // For other expressions (like function calls), just copy the value
            // This is a workaround - proper handling would require more changes
            instr.Op := irLoadLocal;
            instr.Dest := t0;
            instr.Src1 := t1;
            Emit(instr);
          end;
        end
        // Check for int64 -> uint8 (truncate to 8 bits)
        else if (ltype = atInt64) and (rType = atUInt8) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 8;  // Truncate to 8 bits
          Emit(instr);
        end
        // Check for int64 -> uint16 (truncate to 16 bits)
        else if (ltype = atInt64) and (rType = atUInt16) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 16;  // Truncate to 16 bits
          Emit(instr);
        end
        // Check for int64 -> uint32 (truncate to 32 bits)
        else if (ltype = atInt64) and (rType = atUInt32) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 32;  // Truncate to 32 bits
          Emit(instr);
        end
        // Check for int64 -> int8 (truncate to 8 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt8) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 8;  // Truncate to 8 bits
          Emit(instr);
          // Sign-extend from 8 bits to 64 bits (t0 = sign-extended result)
          instr.Op := irSExt;
          instr.Dest := t0;  // Reuse t0 for sign-extended result
          instr.Src1 := t0;  // Sign-extend the truncated value
          instr.ImmInt := 64;  // Extend to full 64-bit
          Emit(instr);
        end
        // Check for int64 -> int16 (truncate to 16 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt16) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 16;  // Truncate to 16 bits
          Emit(instr);
          // Sign-extend from 16 bits to 64 bits
          instr.Op := irSExt;
          instr.Dest := t0;
          instr.Src1 := t0;
          instr.ImmInt := 64;
          Emit(instr);
        end
        // Check for int64 -> int32 (truncate to 32 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt32) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 32;  // Truncate to 32 bits
          Emit(instr);
          // Sign-extend from 32 bits to 64 bits
          instr.Op := irSExt;
          instr.Dest := t0;
          instr.Src1 := t0;
          instr.ImmInt := 64;
          Emit(instr);
        end
        // Check for unsigned -> int64 (no conversion needed, just zero-extend conceptually)
        else if (rType = atInt64) and (ltype in [atUInt8, atUInt16, atUInt32, atUInt64]) then
        begin
          // No conversion needed for unsigned -> signed int64
          instr.Op := irLoadLocal;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        else
        begin
          // No conversion needed - just use the source temp directly
          // (No need to emit a copy instruction)
          Result := t1;
          Exit;
        end;

        Result := t0;
      end;

    nkFieldAccess:
       begin
         // For nested field access like o.x.a, we need to find the root struct
         // and use the combined offset. The Sema has already calculated the
         // combined offset in FieldOffset.
         
         // Walk up the chain of field accesses to find the root (non-field) expression
         baseExpr := TAstFieldAccess(expr).Obj;
         while (baseExpr is TAstFieldAccess) do
           baseExpr := TAstFieldAccess(baseExpr).Obj;
         
         // Now lower the root expression (e.g., 'o' in 'o.x.a')
         t1 := LowerExpr(baseExpr);
         if t1 < 0 then
           Exit;

         // If sema annotated the field offset on the AST node, use it
         fldOffset := TAstFieldAccess(expr).FieldOffset;
         ownerName := TAstFieldAccess(expr).OwnerName;
         fldType := TAstFieldAccess(expr).FieldType; // Get the field type for proper extension

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
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end
            else
            begin
              // Struct: use negative offset (stack access)
              instr.Op := irLoadField;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.ImmInt := fldOffset; // will be negated in backend
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end;
          end
          else
          begin
            // FieldOffset not set by sema (e.g., imported class methods not fully sema'd).
            // Try to resolve the field by name.
            // First determine which class the receiver belongs to:
            //   - If receiver is 'self' → FCurrentClassDecl
            //   - If receiver is a local variable → look up FLocalTypeNames
            fldOffset := -1;
            ownerName := '';
            cd := nil;
            // Try to determine receiver class:
            //   - Named local variable → look up FLocalTypeNames (works in any function)
            //   - 'self' → FCurrentClassDecl (only in class methods)
            if (baseExpr is TAstIdent) and (TAstIdent(baseExpr).Name <> 'self') then
            begin
              // Named local variable: look up its class type
              i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
              if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocals)) and
                 (FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName <> '') then
              begin
                idx := FClassTypes.IndexOf(FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName);
                if idx >= 0 then
                  cd := TAstClassDecl(FClassTypes.Objects[idx]);
              end;
            end;
            // Also try struct types (for struct parameters/locals passed by pointer
            // in imported function bodies where sema doesn't annotate FieldOffset)
            if (cd = nil) and (baseExpr is TAstIdent) then
            begin
              i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
              if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocals)) and
                 (FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName <> '') then
              begin
                structIdx := FStructTypes.IndexOf(FLocals[ObjToInt(FLocalMap.Objects[i])].TypeName);
                if structIdx >= 0 then
                begin
                  sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
                  if Length(sd.FieldOffsets) = Length(sd.Fields) then
                    for fi := 0 to High(sd.Fields) do
                    begin
                      if sd.Fields[fi].Name = TAstFieldAccess(expr).Field then
                      begin
                        fldOffset := sd.FieldOffsets[fi];
                        fldType := sd.Fields[fi].FieldType;
                        Break;
                      end;
                    end;
                end;
              end;
            end;
            if (cd = nil) and Assigned(FCurrentClassDecl) then
              cd := FCurrentClassDecl;
            if Assigned(cd) then
            begin
              // Walk the class and base classes to find the field
              // ownerName set to root class name for irLoadFieldHeap dispatch
              ownerName := cd.Name;
              while Assigned(cd) do
              begin
                for k := 0 to High(cd.Fields) do
                begin
                  if cd.Fields[k].Name = TAstFieldAccess(expr).Field then
                  begin
                    fldOffset := cd.FieldOffsets[k];
                    fldType := cd.Fields[k].FieldType;
                    Break;
                  end;
                end;
                if fldOffset >= 0 then Break;
                if cd.BaseClassName <> '' then
                begin
                  i := FClassTypes.IndexOf(cd.BaseClassName);
                  if i >= 0 then
                    cd := TAstClassDecl(FClassTypes.Objects[i])
                  else
                    cd := nil;
                end
                else
                  cd := nil;
              end;
            end;
            if fldOffset >= 0 then
            begin
              // Emit heap access for the class field (or struct param passed by pointer)
              instr.Op := irLoadFieldHeap;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.ImmInt := fldOffset;
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end
            else
            begin
              // Last resort: name-based fallback (likely wrong for heap objects, but best effort)
              instr.Op := irLoadField;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.LabelName := TAstFieldAccess(expr).Field;
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end;
          end;
         
         // Sign/zero-extend the loaded value to full register width based on field type
         if (fldType <> atUnresolved) and (fldType <> atInt64) and (fldType <> atUInt64) then
         begin
           t2 := NewTemp; // temp for extended value
           case fldType of
             atInt8, atUInt8:   // 8-bit types
               begin
                 if fldType = atInt8 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 8;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
             atInt16, atUInt16: // 16-bit types
               begin
                 if fldType = atInt16 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 16;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
             atInt32, atUInt32: // 32-bit types
               begin
                 if fldType = atInt32 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 32;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
           end;
         end;
         
         Result := t0;
       end;

    nkArrayLit:
      begin
        Result := LowerArrayLit(TAstArrayLit(expr));
      end;

    nkStructLit:
      begin
        // Struct literal: TypeName { field1: val1, field2: val2, ... }
        // Allocate stack space for the struct, initialize fields, return address
        Result := LowerStructLit(TAstStructLit(expr));
      end;

    // Map/Set expressions (v0.5.0)
    nkMapLit:
      begin
        // Map literal: {key1: val1, key2: val2, ...}
        // Emit: map_new(initial_capacity) + map_set(key, val) for each entry

        // Determine initial capacity (round up to power of 2)
        entryCount := Length(TAstMapLit(expr).Entries);
        if entryCount < 4 then
          entryCount := 4
        else
        begin
          // Round up to next power of 2
          while (entryCount and (entryCount - 1)) <> 0 do
            entryCount := entryCount and (entryCount - 1);
          entryCount := entryCount shl 1;
        end;

        // Allocate new map
        t0 := NewTemp;
        instr.Op := irMapNew;
        instr.Dest := t0;
        instr.ImmInt := entryCount;
        Emit(instr);

        // Add each entry: map_set(map, key, value)
        for i := 0 to High(TAstMapLit(expr).Entries) do
        begin
          // Lower key
          t1 := LowerExpr(TAstMapLit(expr).Entries[i].Key);
          if t1 < 0 then Exit;

          // Lower value
          t2 := LowerExpr(TAstMapLit(expr).Entries[i].Value);
          if t2 < 0 then Exit;

          // Emit map_set
          instr := Default(TIRInstr);
          instr.Op := irMapSet;
          instr.Src1 := t0;  // map
          instr.Src2 := t1;  // key
          instr.Src3 := t2;  // value
          Emit(instr);
        end;

        Result := t0;
      end;

    nkSetLit:
      begin
        // Set literal: {val1, val2, val3, ...}
        // Emit: set_new(initial_capacity) + set_add(set, value) for each element

        // Determine initial capacity (round up to power of 2)
        elemCount := Length(TAstSetLit(expr).Items);
        if elemCount < 4 then
          elemCount := 4
        else
        begin
          // Round up to next power of 2
          while (elemCount and (elemCount - 1)) <> 0 do
            elemCount := elemCount and (elemCount - 1);
          elemCount := elemCount shl 1;
        end;

        // Allocate new set
        t0 := NewTemp;
        instr.Op := irSetNew;
        instr.Dest := t0;
        instr.ImmInt := elemCount;
        Emit(instr);

        // Add each element: set_add(set, value)
        for i := 0 to High(TAstSetLit(expr).Items) do
        begin
          // Lower value
          t1 := LowerExpr(TAstSetLit(expr).Items[i]);
          if t1 < 0 then Exit;

          // Emit set_add
          instr := Default(TIRInstr);
          instr.Op := irSetAdd;
          instr.Src1 := t0;  // set
          instr.Src2 := t1;  // value
          Emit(instr);
        end;

        Result := t0;
      end;

    nkInExpr:
      begin
        // In expression: key in map/set
        // Emit: map_contains(map, key) or set_contains(set, value)

        // Lower the key and container
        t1 := LowerExpr(TAstInExpr(expr).Key);
        if t1 < 0 then Exit;

        t2 := LowerExpr(TAstInExpr(expr).Container);
        if t2 < 0 then Exit;

        // Determine which operation to use based on container type
        t0 := NewTemp;
        containerType := TAstInExpr(expr).Container.ResolvedType;

        if containerType = atMap then
        begin
          // map contains: irMapContains(map, key) -> bool
          instr.Op := irMapContains;
          instr.Dest := t0;
          instr.Src1 := t2;  // map
          instr.Src2 := t1;  // key
        end
        else if containerType = atSet then
        begin
          // set contains: irSetContains(set, value) -> bool
          instr.Op := irSetContains;
          instr.Dest := t0;
          instr.Src1 := t2;  // set
          instr.Src2 := t1;  // value
        end
        else
        begin
          FDiag.Error('invalid container type for "in" operator', expr.Span);
          Exit;
        end;

        Emit(instr);
        Result := t0;
      end;

    nkIsExpr:
      begin
        // Is expression: expr is ClassName
        // Returns true if expr is an instance of ClassName or a derived class
        // We implement this by checking the class name in the VMT
        
        t1 := LowerExpr(TAstIsExpr(expr).Expr);
        if t1 < 0 then Exit;
        
        // Call the ClassName method and compare with target class name
        // For now, we emit a call to a runtime helper that does the check
        
        // Load object pointer into RDI (first arg)
        // Emit: mov rdi, [rbp - slot]
        
        // For simplicity, we emit a call to a builtin that checks the type
        // Format: irIsType(object, targetClassName) -> bool
        
        t0 := NewTemp;
        instr.Op := irIsType;
        instr.Dest := t0;
        instr.Src1 := t1;  // object pointer
        instr.ImmStr := TAstIsExpr(expr).ClassName;  // target class name
        Emit(instr);
        Result := t0;
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
        
        // Check if it's a class with virtual methods
        hasVMT := False;
        if FStructTypes.Objects[i] is TAstClassDecl then
        begin
          cd := TAstClassDecl(FStructTypes.Objects[i]);
          if Length(cd.VirtualMethods) > 0 then
            hasVMT := True;
        end;
        
        // Allocate temp for pointer, emit irAlloc with size
        t0 := NewTemp;
        instr.Op := irAlloc;
        instr.Dest := t0;
        // Check if it's a class or struct - they have different layouts
        if FStructTypes.Objects[i] is TAstClassDecl then
        begin
          // Classes: Size already includes VMT pointer (added by ResolveVMTForClasses)
          instr.ImmInt := TAstClassDecl(FStructTypes.Objects[i]).Size;
        end
        else
          instr.ImmInt := TAstStructDecl(FStructTypes.Objects[i]).Size;
        if instr.ImmInt = 0 then
          instr.ImmInt := 8; // minimum allocation
        Emit(instr);
        
        // Initialize VMT pointer if class has virtual methods
        if hasVMT then
        begin
          // VMT pointer goes at offset 0 of the object
          // We need to store the VMT address into the allocated memory
          // This will be handled by the backend which knows the VMT data position
          // For now, emit a placeholder that will be patched
          // Actually, we can emit this directly: load VMT address from data section
          
          // Emit: mov rax, [rel _vmt_ClassName]  (load VMT address)
          // Then:  mov [t0], rax                   (store VMT pointer to object)
          
          // Load VMT address into temporary
          t1 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irLoadGlobalAddr;  // Use this to get the VMT address
          instr.Dest := t1;
          instr.ImmStr := '_vmt_' + TAstNewExpr(expr).ClassName;
          Emit(instr);
          
          // Store VMT pointer to object at offset 0
          instr := Default(TIRInstr);
          instr.Op := irStoreFieldHeap;
          instr.Src1 := t0;  // object pointer
          instr.Src2 := t1;  // VMT address
          instr.ImmInt := 0; // offset 0
          instr.FieldSize := 8; // VMT pointer is always 8 bytes
          Emit(instr);
        end;
        
        // If new has arguments, call the constructor (method named 'new')
        if Length(TAstNewExpr(expr).Args) > 0 then
        begin
          // Build args: [self (t0), original args...]
          argCount := Length(TAstNewExpr(expr).Args);
          SetLength(argTemps, argCount + 1);
          argTemps[0] := t0; // self is the allocated object pointer
          
          // Lower the constructor arguments
          for k := 0 to argCount - 1 do
            argTemps[k + 1] := LowerExpr(TAstNewExpr(expr).Args[k]);
          
          // Emit call to constructor (use the name from AST)
          t1 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irCall;
          instr.Dest := t1;
          instr.ImmStr := '_L_' + TAstNewExpr(expr).ClassName + '_' + TAstNewExpr(expr).ConstructorName;
          instr.ImmInt := argCount + 1; // +1 for self
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount + 1);
          for k := 0 to argCount do
            instr.ArgTemps[k] := argTemps[k];
          Emit(instr);
          // Bootstrap compat: if constructor is 'Create', it handles its own allocation
          // and returns the properly initialized object. Use the constructor return value
          // instead of the pre-allocated t0 (which will be leaked but that's acceptable).
          if TAstNewExpr(expr).ConstructorName = 'Create' then
            t0 := t1;
        end
        else
        begin
          // No arguments: call 0-arg Create constructor if name is 'Create'
          if TAstNewExpr(expr).ConstructorName = 'Create' then
          begin
            t1 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irCall;
            instr.Dest := t1;
            instr.ImmStr := '_L_' + TAstNewExpr(expr).ClassName + '_Create';
            instr.ImmInt := 1; // +1 for self (dummy t0)
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, 1);
            instr.ArgTemps[0] := t0; // pass pre-allocated ptr as dummy self
            Emit(instr);
            t0 := t1; // use constructor return value
          end;
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

    nkCheck:
      begin
        // check(condition) - runtime-only assertion, panics if false without message
        // Expand to: if (!condition) panic("check failed")
        // Lower the condition expression first
        condTmp := LowerExpr(TAstCheckExpr(expr).Condition);
        if condTmp < 0 then
          Exit(-1);

        // Create labels for skip and panic
        skipLbl := NewLabel('Lcheck_ok');
        // if cond is true, jump to skip (use irBrTrue to jump if condition is true)
        instr := Default(TIRInstr);
        instr.Op := irBrTrue; // jump if true -> skip panic
        instr.Src1 := condTmp;
        instr.LabelName := skipLbl;
        Emit(instr);

        // panic("check failed") - use irPanic with ImmInt = -1 to signal default message
        instr := Default(TIRInstr);
        instr.Op := irPanic;
        instr.ImmInt := -1; // Signal default "check failed" message
        Emit(instr);

        // skip label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := skipLbl;
        Emit(instr);

        // check never returns on false, so we can assign any type
        Result := -1;
      end;

    // SIMD Expressions (v0.2.0) — delegated to lower_simd.inc
    nkSIMDNew, nkSIMDBinOp, nkSIMDUnaryOp, nkSIMDIndexAccess:
      Result := LowerSIMDExpr(expr);

    nkFormatExpr:
      begin
        t1 := LowerExpr(TAstFormatExpr(expr).Expr);
        if t1 < 0 then Exit;
        t0 := NewTemp;
        instr := Default(TIRInstr);
        instr.Op := irCallBuiltin;
        instr.Dest := t0;
        instr.ImmStr := 'format_float';
        instr.ImmInt := 3;
        SetLength(instr.ArgTemps, 3);
        instr.ArgTemps[0] := t1;
        // Width as constant temp
        tWidth := NewTemp;
        instr2 := Default(TIRInstr);
        instr2.Op := irConstInt;
        instr2.Dest := tWidth;
        instr2.ImmInt := TAstFormatExpr(expr).Width;
        Emit(instr2);
        // Decimals as constant temp
        tDecimals := NewTemp;
        instr2 := Default(TIRInstr);
        instr2.Op := irConstInt;
        instr2.Dest := tDecimals;
        instr2.ImmInt := TAstFormatExpr(expr).Decimals;
        Emit(instr2);
        instr.ArgTemps[1] := tWidth;
        instr.ArgTemps[2] := tDecimals;
        Emit(instr);
        Result := t0;
      end;

  else
    FDiag.Error('lowering: unsupported expression kind', expr.Span);
    Result := -1;
  end;
end;

