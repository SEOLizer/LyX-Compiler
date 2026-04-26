{ lower_simd.inc — SIMD expression lowering (ParallelArray<T> nodes)
  Included by lower_ast_to_ir.pas in the implementation section. }

function TIRLowering.LowerSIMDExpr(expr: TAstExpr): Integer;
var
  instr: TIRInstr;
  t0, t1, t2, tResult, tVec, tIdx: Integer;
  elemSize: Integer;
begin
  instr := Default(TIRInstr);
  Result := -1;

  case expr.Kind of

    nkSIMDNew:
    begin
      t0 := LowerExpr(TAstSIMDNew(expr).Size);
      if t0 < 0 then Exit;

      case TAstSIMDNew(expr).ElementType of
        atInt8, atUInt8:   elemSize := 1;
        atInt16, atUInt16: elemSize := 2;
        atInt32, atUInt32, atF32: elemSize := 4;
        atInt64, atUInt64, atF64: elemSize := 8;
      else
        elemSize := 8;
      end;

      t1 := NewTemp;
      instr.Op := irAlloc;
      instr.Dest := t1;
      instr.Src1 := t0;
      instr.ImmInt := elemSize;
      Emit(instr);
      Result := t1;
    end;

    nkSIMDBinOp:
    begin
      t1 := LowerExpr(TAstSIMDBinOp(expr).Left);
      if t1 < 0 then Exit;
      t2 := LowerExpr(TAstSIMDBinOp(expr).Right);
      if t2 < 0 then Exit;

      tResult := NewTemp;
      case TAstSIMDBinOp(expr).Op of
        tkPlus:  instr.Op := irSIMDAdd;
        tkMinus: instr.Op := irSIMDSub;
        tkStar:  instr.Op := irSIMDMul;
        tkSlash: instr.Op := irSIMDDiv;
        tkAnd:   instr.Op := irSIMDAnd;
        tkOr:    instr.Op := irSIMDOr;
        tkXor:   instr.Op := irSIMDXor;
        tkEq:    instr.Op := irSIMDCmpEq;
        tkNeq:   instr.Op := irSIMDCmpNe;
        tkLt:    instr.Op := irSIMDCmpLt;
        tkLe:    instr.Op := irSIMDCmpLe;
        tkGt:    instr.Op := irSIMDCmpGt;
        tkGe:    instr.Op := irSIMDCmpGe;
      else
        FDiag.Error('unsupported SIMD operator', expr.Span);
        Exit;
      end;
      instr.Dest := tResult;
      instr.Src1 := t1;
      instr.Src2 := t2;
      Emit(instr);
      Result := tResult;
    end;

    nkSIMDUnaryOp:
    begin
      t1 := LowerExpr(TAstSIMDUnaryOp(expr).Operand);
      if t1 < 0 then Exit;

      tResult := NewTemp;
      case TAstSIMDUnaryOp(expr).Op of
        tkMinus: instr.Op := irSIMDNeg;
      else
        FDiag.Error('unsupported SIMD unary operator', expr.Span);
        Exit;
      end;
      instr.Dest := tResult;
      instr.Src1 := t1;
      Emit(instr);
      Result := tResult;
    end;

    nkSIMDIndexAccess:
    begin
      tVec := LowerExpr(TAstSIMDIndexAccess(expr).Obj);
      if tVec < 0 then Exit;
      tIdx := LowerExpr(TAstSIMDIndexAccess(expr).Index);
      if tIdx < 0 then Exit;

      elemSize := 8;
      if TAstSIMDIndexAccess(expr).Obj is TAstSIMDNew then
      begin
        case TAstSIMDNew(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
          simdI8:  elemSize := 1;
          simdI16: elemSize := 2;
          simdI32: elemSize := 4;
          simdI64: elemSize := 8;
          simdF32: elemSize := 4;
          simdF64: elemSize := 8;
        end;
      end
      else if TAstSIMDIndexAccess(expr).Obj is TAstSIMDBinOp then
      begin
        case TAstSIMDBinOp(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
          simdI8:  elemSize := 1;
          simdI16: elemSize := 2;
          simdI32: elemSize := 4;
          simdI64: elemSize := 8;
          simdF32: elemSize := 4;
          simdF64: elemSize := 8;
        end;
      end
      else if TAstSIMDIndexAccess(expr).Obj is TAstSIMDUnaryOp then
      begin
        case TAstSIMDUnaryOp(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
          simdI8:  elemSize := 1;
          simdI16: elemSize := 2;
          simdI32: elemSize := 4;
          simdI64: elemSize := 8;
          simdF32: elemSize := 4;
          simdF64: elemSize := 8;
        end;
      end;

      t0 := NewTemp;
      instr.Op := irLoadElem;
      instr.Dest := t0;
      instr.Src1 := tVec;
      instr.Src2 := tIdx;
      instr.ImmInt := elemSize;
      Emit(instr);
      Result := t0;
    end;

  else
    FDiag.Error('LowerSIMDExpr: unexpected node kind', expr.Span);
  end;
end;
