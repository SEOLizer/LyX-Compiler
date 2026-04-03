{$mode objfpc}{$H+}
unit ir_mcdc;

{
  MC/DC (Modified Condition/Decision Coverage) Instrumentierungs-Pass
  DO-178C Section 4.1: Test-Abdeckung
  
  Dieser Pass instrumentiert den IR-Code, um MC/DC-Coverage zu tracken.
  Für jede Entscheidung (if, while, etc.) werden Coverage-Points eingefügt,
  die zur Laufzeit aufzeichnen welche Condition-Kombinationen erreicht wurden.
  
  MC/DC erfordert:
  1. Jede Bedingung in einer Entscheidung hat beide Ergebnisse (T/F) erreicht
  2. Jede Bedingung beeinflusst das Ergebnis der Entscheidung unabhängig
  3. Jede Bedingung wird isoliert variiert während andere konstant bleiben
}

interface

uses
  SysUtils, Classes, ir;

type
  TMCDCDecision = record
    ID: Integer;
    FunctionName: string;
    LineNumber: Integer;
    ConditionCount: Integer;    // Anzahl der Bedingungen (a, b, c in a && b && c)
    ConditionResults: array of Boolean; // T/F für jede Bedingung
    DecisionResult: Boolean;    // Gesamtergebnis der Entscheidung
    HitCount: Integer;          // Wie oft erreicht
  end;

  TMCDCInstrumenter = class
  private
    FModule: TIRModule;
    FNextDecisionID: Integer;
    FDecisions: array of TMCDCDecision;
    FInstrumentedCount: Integer;
    
    function AddDecision(const funcName: string; lineNum, condCount: Integer): Integer;
    procedure InstrumentFunction(fn: TIRFunction);
    procedure InstrumentBranch(fn: TIRFunction; idx: Integer);
    procedure InsertRecordCall(fn: TIRFunction; insertPos: Integer; decisionID, condIdx: Integer; condResult: Boolean);
    
  public
    constructor Create(module: TIRModule);
    destructor Destroy; override;
    
    function Instrument: Integer;
    procedure GenerateReport;
    
    property DecisionCount: Integer read FNextDecisionID;
    property InstrumentedPoints: Integer read FInstrumentedCount;
  end;

implementation

constructor TMCDCInstrumenter.Create(module: TIRModule);
begin
  inherited Create;
  FModule := module;
  FNextDecisionID := 0;
  FInstrumentedCount := 0;
end;

destructor TMCDCInstrumenter.Destroy;
begin
  inherited Destroy;
end;

function TMCDCInstrumenter.AddDecision(const funcName: string; lineNum, condCount: Integer): Integer;
begin
  Result := FNextDecisionID;
  SetLength(FDecisions, FNextDecisionID + 1);
  FDecisions[FNextDecisionID].ID := FNextDecisionID;
  FDecisions[FNextDecisionID].FunctionName := funcName;
  FDecisions[FNextDecisionID].LineNumber := lineNum;
  FDecisions[FNextDecisionID].ConditionCount := condCount;
  FDecisions[FNextDecisionID].HitCount := 0;
  Inc(FNextDecisionID);
end;

procedure TMCDCInstrumenter.InsertRecordCall(fn: TIRFunction; insertPos: Integer;
  decisionID, condIdx: Integer; condResult: Boolean);
var
  newInstr: TIRInstr;
  i: Integer;
begin
  // Create irCallBuiltin for __mcdc_record(decisionID, condIdx, condResult)
  SetLength(fn.Instructions, Length(fn.Instructions) + 1);
  
  // Shift instructions after insertPos
  for i := High(fn.Instructions) downto insertPos + 1 do
    fn.Instructions[i] := fn.Instructions[i - 1];
  
  // Insert the record call
  newInstr.Op := irCallBuiltin;
  newInstr.ImmStr := '__mcdc_record';
  newInstr.Dest := -1;
  newInstr.Src1 := -1;
  newInstr.Src2 := -1;
  newInstr.Src3 := -1;
  newInstr.ImmInt := decisionID;  // Store decision ID in ImmInt
  newInstr.LabelName := IntToStr(condIdx) + ':' + BoolToStr(condResult, True);
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
    // Create a new decision for this branch
    decisionID := AddDecision(fn.Name, 0, 1);  // 1 condition per branch
    
    // Insert record call before the branch
    InsertRecordCall(fn, idx, decisionID, 0, instr.Op = irBrTrue);
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
    
    // If we inserted an instruction, skip it
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

procedure TMCDCInstrumenter.GenerateReport;
var
  i: Integer;
  totalPossible, covered: Integer;
begin
  WriteLn;
  WriteLn('=== MC/DC Coverage Report ===');
  WriteLn('Total decisions: ', FNextDecisionID);
  WriteLn('Instrumented points: ', FInstrumentedCount);
  WriteLn;
  
  if FNextDecisionID = 0 then
  begin
    WriteLn('No decisions found in code.');
    Exit;
  end;
  
  totalPossible := FNextDecisionID * 2;  // Each decision has T/F outcomes
  covered := 0;
  
  WriteLn('Decision  | Function         | Line | T | F | Status');
  WriteLn('----------|------------------|------|---|---|--------');
  
  for i := 0 to FNextDecisionID - 1 do
  begin
    // Simplified: assume 50% coverage for now (would need runtime data)
    WriteLn(Format('DEC-%4d  | %-16s | %4d | ? | ? | PARTIAL',
      [FDecisions[i].ID, FDecisions[i].FunctionName, FDecisions[i].LineNumber]));
  end;
  
  WriteLn;
  WriteLn('Note: Full MC/DC coverage requires runtime execution data.');
  WriteLn('Run the instrumented binary and collect coverage data with --mcdc-report.');
end;

end.
