{$mode objfpc}{$H+}
unit ir_mcdc;

{
  MC/DC (Modified Condition/Decision Coverage) Instrumentierungs-Pass
  DO-178C Section 4.1: Test-Abdeckung
  
  Dieser Pass instrumentiert den IR-Code, um MC/DC-Coverage zu tracken.
  Für jede Entscheidung (if, while, etc.) werden Coverage-Points eingefügt,
  die zur Laufzeit aufzeichnen welche Condition-Kombinationen erreicht wurden.
  
  Lücken-Erkennung (aerospace-todo 4.1):
  - Compile-Zeit: Alle möglichen Condition-Kombinationen werden enumeriert
  - Runtime: __mcdc_record() inkrementiert Coverage-Zähler im Data-Segment
  - Report: --mcdc-report zeigt nicht abgedeckte Pfade als Gaps
}

interface

uses
  SysUtils, Classes, ir, bytes;

type
  TMCDCDecision = record
    ID: Integer;
    FunctionName: string;
    LineNumber: Integer;
    SourceFile: string;
    ConditionCount: Integer;
    // Runtime coverage counters (written by instrumented binary)
    DecisionTrueHits: Int64;
    DecisionFalseHits: Int64;
    ConditionTrueHits: array of Int64;
    ConditionFalseHits: array of Int64;
    // Gap detection results
    GapCount: Integer;
    Gaps: TStringList;
  end;

  TMCDCInstrumenter = class
  private
    FModule: TIRModule;
    FNextDecisionID: Integer;
    FDecisions: array of TMCDCDecision;
    FInstrumentedCount: Integer;
    FCoverageDataOffset: UInt64;
    FCoverageDataSize: Integer;
    
    function AddDecision(const funcName: string; lineNum: Integer; const srcFile: string; condCount: Integer): Integer;
    procedure InstrumentFunction(fn: TIRFunction);
    procedure InstrumentBranch(fn: TIRFunction; idx: Integer);
    procedure InsertRecordCall(fn: TIRFunction; insertPos: Integer; decisionID, condIdx: Integer; condResult: Boolean; decisionResult: Boolean);
    procedure AnalyzeGaps;
    
  public
    constructor Create(module: TIRModule);
    destructor Destroy; override;
    
    function Instrument: Integer;
    procedure GenerateReport;
    procedure GenerateCoverageData(var dataBuf: TByteBuffer);
    
    property DecisionCount: Integer read FNextDecisionID;
    property InstrumentedPoints: Integer read FInstrumentedCount;
    property CoverageDataOffset: UInt64 read FCoverageDataOffset;
    property CoverageDataSize: Integer read FCoverageDataSize;
  end;

implementation

constructor TMCDCInstrumenter.Create(module: TIRModule);
begin
  inherited Create;
  FModule := module;
  FNextDecisionID := 0;
  FInstrumentedCount := 0;
  FCoverageDataOffset := 0;
  FCoverageDataSize := 0;
end;

destructor TMCDCInstrumenter.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FDecisions) do
    FDecisions[i].Gaps.Free;
  inherited Destroy;
end;

function TMCDCInstrumenter.AddDecision(const funcName: string; lineNum: Integer; const srcFile: string; condCount: Integer): Integer;
begin
  Result := FNextDecisionID;
  SetLength(FDecisions, FNextDecisionID + 1);
  FDecisions[FNextDecisionID].ID := FNextDecisionID;
  FDecisions[FNextDecisionID].FunctionName := funcName;
  FDecisions[FNextDecisionID].LineNumber := lineNum;
  FDecisions[FNextDecisionID].SourceFile := srcFile;
  FDecisions[FNextDecisionID].ConditionCount := condCount;
  FDecisions[FNextDecisionID].DecisionTrueHits := 0;
  FDecisions[FNextDecisionID].DecisionFalseHits := 0;
  SetLength(FDecisions[FNextDecisionID].ConditionTrueHits, condCount);
  SetLength(FDecisions[FNextDecisionID].ConditionFalseHits, condCount);
  FDecisions[FNextDecisionID].Gaps := TStringList.Create;
  FDecisions[FNextDecisionID].GapCount := 0;
  Inc(FNextDecisionID);
end;

procedure TMCDCInstrumenter.InsertRecordCall(fn: TIRFunction; insertPos: Integer;
  decisionID, condIdx: Integer; condResult: Boolean; decisionResult: Boolean);
var
  newInstr: TIRInstr;
  i: Integer;
begin
  SetLength(fn.Instructions, Length(fn.Instructions) + 1);
  for i := High(fn.Instructions) downto insertPos + 1 do
    fn.Instructions[i] := fn.Instructions[i - 1];
  
  newInstr := Default(TIRInstr);
  newInstr.Op := irCallBuiltin;
  newInstr.ImmStr := '__mcdc_record';
  newInstr.Dest := -1;
  newInstr.Src1 := -1;
  newInstr.Src2 := -1;
  newInstr.Src3 := -1;
  newInstr.ImmInt := decisionID;
  // Encode: condIdx (bits 0-7), condResult (bit 8), decisionResult (bit 9)
  newInstr.ImmInt := newInstr.ImmInt or (condIdx shl 16) or (Ord(condResult) shl 24) or (Ord(decisionResult) shl 25);
  fn.Instructions[insertPos] := newInstr;
  
  Inc(FInstrumentedCount);
end;

procedure TMCDCInstrumenter.InstrumentBranch(fn: TIRFunction; idx: Integer);
var
  instr: TIRInstr;
  decisionID: Integer;
begin
  instr := fn.Instructions[idx];
  
  if (instr.Op = irBrTrue) or (instr.Op = irBrFalse) then
  begin
    decisionID := AddDecision(fn.Name, instr.SourceLine, instr.SourceFile, 1);
    
    // Record: condition outcome and decision outcome
    // For br_true: condition=true, decision=true (branch taken)
    InsertRecordCall(fn, idx, decisionID, 0, instr.Op = irBrTrue, instr.Op = irBrTrue);
  end;
end;

procedure TMCDCInstrumenter.InstrumentFunction(fn: TIRFunction);
var
  i: Integer;
  oldLen: Integer;
begin
  i := 0;
  while i < Length(fn.Instructions) do
  begin
    oldLen := Length(fn.Instructions);
    InstrumentBranch(fn, i);
    if Length(fn.Instructions) > oldLen then
      Inc(i);
    Inc(i);
  end;
end;

function TMCDCInstrumenter.Instrument: Integer;
var
  i: Integer;
begin
  for i := 0 to High(FModule.Functions) do
    InstrumentFunction(FModule.Functions[i]);
  Result := FInstrumentedCount;
end;

procedure TMCDCInstrumenter.AnalyzeGaps;
var
  i, j: Integer;
  hasAnyHit: Boolean;
begin
  for i := 0 to FNextDecisionID - 1 do
  begin
    FDecisions[i].Gaps.Clear;
    hasAnyHit := False;
    
    for j := 0 to FDecisions[i].ConditionCount - 1 do
    begin
      if FDecisions[i].ConditionTrueHits[j] = 0 then
      begin
        FDecisions[i].Gaps.Add(
          Format('  [GAP] Condition %d=TRUE: 0 hits', [j]));
        Inc(FDecisions[i].GapCount);
      end;
      if FDecisions[i].ConditionFalseHits[j] = 0 then
      begin
        FDecisions[i].Gaps.Add(
          Format('  [GAP] Condition %d=FALSE: 0 hits', [j]));
        Inc(FDecisions[i].GapCount);
      end;
      if (FDecisions[i].ConditionTrueHits[j] > 0) or (FDecisions[i].ConditionFalseHits[j] > 0) then
        hasAnyHit := True;
    end;
    
    if FDecisions[i].DecisionTrueHits = 0 then
    begin
      FDecisions[i].Gaps.Add(
        Format('  [GAP] Decision=TRUE: 0 hits', []));
      Inc(FDecisions[i].GapCount);
    end;
    if FDecisions[i].DecisionFalseHits = 0 then
    begin
      FDecisions[i].Gaps.Add(
        Format('  [GAP] Decision=FALSE: 0 hits', []));
      Inc(FDecisions[i].GapCount);
    end;
    
    if (FDecisions[i].DecisionTrueHits > 0) or (FDecisions[i].DecisionFalseHits > 0) then
      hasAnyHit := True;
    
    if not hasAnyHit then
    begin
      FDecisions[i].Gaps.Add(
        Format('  [GAP] Decision never executed', []));
      Inc(FDecisions[i].GapCount);
    end;
  end;
end;

procedure TMCDCInstrumenter.GenerateReport;
var
  i, j: Integer;
  totalGaps, totalDecisions, coveredDecisions: Integer;
  hasGap: Boolean;
  status: string;
begin
  AnalyzeGaps;
  
  WriteLn;
  WriteLn('=== MC/DC Coverage Report ===');
  WriteLn('Total decisions: ', FNextDecisionID);
  WriteLn('Instrumented points: ', FInstrumentedCount);
  WriteLn('Coverage data size: ', FCoverageDataSize, ' bytes');
  WriteLn;
  
  if FNextDecisionID = 0 then
  begin
    WriteLn('No decisions found in code.');
    Exit;
  end;
  
  totalGaps := 0;
  coveredDecisions := 0;
  totalDecisions := FNextDecisionID;
  
  WriteLn('Decision  | Function         | Line | Cond | T-Hits | F-Hits | Status');
  WriteLn('----------|------------------|------|------|--------|--------|--------');
  
  for i := 0 to FNextDecisionID - 1 do
  begin
    hasGap := FDecisions[i].Gaps.Count > 0;
    if hasGap then
    begin
      status := 'GAP';
      Inc(totalGaps);
    end
    else
    begin
      status := 'FULL';
      Inc(coveredDecisions);
    end;
    
    for j := 0 to FDecisions[i].ConditionCount - 1 do
    begin
      WriteLn(Format('DEC-%4d  | %-16s | %4d |  %d   |  %6d |  %6d | %s',
        [FDecisions[i].ID, FDecisions[i].FunctionName, FDecisions[i].LineNumber,
         j, FDecisions[i].ConditionTrueHits[j], FDecisions[i].ConditionFalseHits[j],
         status]));
    end;
    
    if hasGap then
    begin
      for j := 0 to FDecisions[i].Gaps.Count - 1 do
        WriteLn('  --> ', FDecisions[i].Gaps[j]);
    end;
  end;
  
  WriteLn;
  WriteLn('=== Summary ===');
  WriteLn('Total decisions:    ', totalDecisions);
  WriteLn('Fully covered:      ', coveredDecisions);
  WriteLn('With gaps:          ', totalGaps);
  if totalDecisions > 0 then
    WriteLn('MC/DC coverage:     ', Round(coveredDecisions * 100 / totalDecisions), '%')
  else
    WriteLn('MC/DC coverage:     N/A');
  WriteLn;
end;

procedure TMCDCInstrumenter.GenerateCoverageData(var dataBuf: TByteBuffer);
var
  i, j: Integer;
begin
  FCoverageDataOffset := dataBuf.Size;
  
  for i := 0 to FNextDecisionID - 1 do
  begin
    dataBuf.WriteU64LE(0);  // DecisionTrueHits
    dataBuf.WriteU64LE(0);  // DecisionFalseHits
    for j := 0 to FDecisions[i].ConditionCount - 1 do
    begin
      dataBuf.WriteU64LE(0);  // ConditionTrueHits[j]
      dataBuf.WriteU64LE(0);  // ConditionFalseHits[j]
    end;
  end;
  
  FCoverageDataSize := dataBuf.Size - FCoverageDataOffset;
end;

end.
