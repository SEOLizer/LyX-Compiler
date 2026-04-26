procedure TIRLowering.EmitRangeCheck(tVal: Integer; rMin, rMax: Int64;
  const typeName: string; span: TSourceSpan);
var
  instr: TIRInstr;
  tMin, tMax, tGeMin, tLeMax, tOk, tMsg: Integer;
  failLbl, okLbl, msgStr: string;
begin
  instr := Default(TIRInstr);
  instr.SourceLine := span.Line;
  instr.SourceFile := span.FileName;

  // Load constants for min and max
  tMin := NewTemp;
  instr.Op := irConstInt; instr.Dest := tMin; instr.ImmInt := rMin; Emit(instr);
  tMax := NewTemp;
  instr.Op := irConstInt; instr.Dest := tMax; instr.ImmInt := rMax; Emit(instr);

  // tGeMin = tVal >= rMin
  tGeMin := NewTemp;
  instr.Op := irCmpGe; instr.Dest := tGeMin; instr.Src1 := tVal; instr.Src2 := tMin; Emit(instr);
  // tLeMax = tVal <= rMax  (implemented as rMax >= tVal)
  tLeMax := NewTemp;
  instr.Op := irCmpGe; instr.Dest := tLeMax; instr.Src1 := tMax; instr.Src2 := tVal; Emit(instr);
  // tOk = tGeMin && tLeMax
  tOk := NewTemp;
  instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGeMin; instr.Src2 := tLeMax; Emit(instr);

  // Branch to fail-label if not ok
  failLbl := NewLabel('Lrange_fail');
  okLbl   := NewLabel('Lrange_ok');
  instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := failLbl; Emit(instr);
  // skip to ok
  instr.Op := irJmp; instr.LabelName := okLbl; Emit(instr);

  // Fail block: panic message
  instr.Op := irLabel; instr.LabelName := failLbl; Emit(instr);
  msgStr := 'Range check failed: value out of [' +
            IntToStr(rMin) + '..' + IntToStr(rMax) + '] for type ' + typeName;
  tMsg := NewTemp;
  instr.Op := irConstStr; instr.Dest := tMsg;
  instr.ImmStr := IntToStr(FModule.InternString(msgStr));
  instr.ImmInt := Length(msgStr); Emit(instr);
  instr.Op := irPanic; instr.Src1 := tMsg; instr.ImmInt := Length(msgStr); Emit(instr);

  instr.Op := irLabel; instr.LabelName := okLbl; Emit(instr);
end;

{ Emits runtime float range-check: panics if tVal not in [rMin, rMax) }
procedure TIRLowering.EmitFloatRangeCheck(tVal: Integer; rMin, rMax: Double;
  const typeName: string; span: TSourceSpan);
var
  instr: TIRInstr;
  tMin, tMax, tGeMin, tLtMax, tOk, tMsg: Integer;
  failLbl, okLbl, msgStr: string;
begin
  instr := Default(TIRInstr);
  instr.SourceLine := span.Line;
  instr.SourceFile := span.FileName;

  tMin := NewTemp;
  instr.Op := irConstFloat; instr.Dest := tMin; instr.ImmFloat := rMin; Emit(instr);
  tMax := NewTemp;
  instr.Op := irConstFloat; instr.Dest := tMax; instr.ImmFloat := rMax; Emit(instr);

  // tGeMin = (tVal >= rMin)
  tGeMin := NewTemp;
  instr.Op := irFCmpGe; instr.Dest := tGeMin; instr.Src1 := tVal; instr.Src2 := tMin; Emit(instr);
  // tLtMax = (tVal < rMax)
  tLtMax := NewTemp;
  instr.Op := irFCmpLt; instr.Dest := tLtMax; instr.Src1 := tVal; instr.Src2 := tMax; Emit(instr);
  // tOk = tGeMin and tLtMax
  tOk := NewTemp;
  instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGeMin; instr.Src2 := tLtMax; Emit(instr);

  failLbl := NewLabel('Lfrange_fail');
  okLbl   := NewLabel('Lfrange_ok');
  instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := failLbl; Emit(instr);
  instr.Op := irJmp;     instr.LabelName := okLbl; Emit(instr);

  instr.Op := irLabel; instr.LabelName := failLbl; Emit(instr);
  msgStr := Format('value out of range [%g, %g) for type %s', [rMin, rMax, typeName]);
  tMsg := NewTemp;
  instr.Op := irConstStr; instr.Dest := tMsg;
  instr.ImmStr := IntToStr(FModule.InternString(msgStr));
  instr.ImmInt := Length(msgStr); Emit(instr);
  instr.Op := irPanic; instr.Src1 := tMsg; instr.ImmInt := Length(msgStr); Emit(instr);

  instr.Op := irLabel; instr.LabelName := okLbl; Emit(instr);
end;

{ Emits cyclic wrap (branchless): result = rMin + (norm - trunc(norm/range)*range) + range*(norm<0)
  where norm = tVal - rMin, range = rMax - rMin. }
function TIRLowering.EmitFloatWrap(tVal: Integer; rMin, rMax: Double; span: TSourceSpan): Integer;
var
  instr: TIRInstr;
  tMin, tRange, tNorm, tDivRaw, tDivInt, tDivF, tFloorPart, tRem, tZero,
  tNegFlag, tNegF, tCorrAmt, tRemFinal, tResult: Integer;
begin
  instr := Default(TIRInstr);
  instr.SourceLine := span.Line;
  instr.SourceFile := span.FileName;

  tMin := NewTemp;
  instr.Op := irConstFloat; instr.Dest := tMin; instr.ImmFloat := rMin; Emit(instr);
  tRange := NewTemp;
  instr.Op := irConstFloat; instr.Dest := tRange; instr.ImmFloat := rMax - rMin; Emit(instr);

  // norm = tVal - min
  tNorm := NewTemp;
  instr.Op := irFSub; instr.Dest := tNorm; instr.Src1 := tVal; instr.Src2 := tMin; Emit(instr);

  // trunc(norm / range) via FToI+IToF
  tDivRaw := NewTemp;
  instr.Op := irFDiv; instr.Dest := tDivRaw; instr.Src1 := tNorm; instr.Src2 := tRange; Emit(instr);
  tDivInt := NewTemp;
  instr.Op := irFToI; instr.Dest := tDivInt; instr.Src1 := tDivRaw; Emit(instr);
  tDivF := NewTemp;
  instr.Op := irIToF; instr.Dest := tDivF; instr.Src1 := tDivInt; Emit(instr);

  // rem = norm - trunc(norm/range)*range
  tFloorPart := NewTemp;
  instr.Op := irFMul; instr.Dest := tFloorPart; instr.Src1 := tDivF; instr.Src2 := tRange; Emit(instr);
  tRem := NewTemp;
  instr.Op := irFSub; instr.Dest := tRem; instr.Src1 := tNorm; instr.Src2 := tFloorPart; Emit(instr);

  // branchless negative correction: rem += range * (rem < 0.0)
  // tNegFlag = int(rem < 0)  →  tNegF = float  →  correction = tNegF * range
  tZero := NewTemp;
  instr.Op := irConstFloat; instr.Dest := tZero; instr.ImmFloat := 0.0; Emit(instr);
  tNegFlag := NewTemp;
  instr.Op := irFCmpLt; instr.Dest := tNegFlag; instr.Src1 := tRem; instr.Src2 := tZero; Emit(instr);
  tNegF := NewTemp;
  instr.Op := irIToF; instr.Dest := tNegF; instr.Src1 := tNegFlag; Emit(instr);
  tCorrAmt := NewTemp;
  instr.Op := irFMul; instr.Dest := tCorrAmt; instr.Src1 := tNegF; instr.Src2 := tRange; Emit(instr);
  tRemFinal := NewTemp;
  instr.Op := irFAdd; instr.Dest := tRemFinal; instr.Src1 := tRem; instr.Src2 := tCorrAmt; Emit(instr);

  // result = remFinal + min
  tResult := NewTemp;
  instr.Op := irFAdd; instr.Dest := tResult; instr.Src1 := tRemFinal; instr.Src2 := tMin; Emit(instr);
  Result := tResult;
end;
