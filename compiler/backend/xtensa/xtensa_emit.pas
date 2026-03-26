{$mode objfpc}{$H+}
unit xtensa_emit;

interface

uses
  SysUtils,
  Classes,
  bytes,
  ir,
  energy_model,
  backend_types,
  diag;

type
  ICodeEmitter = interface
    ['{D4E5F6A7-B8C9-D0E1-F2A3-B4C5D6E7F8A9}']
    procedure EmitFromIR(const module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetExternalSymbols: TExternalSymbolArray;
    procedure SetEnergyLevel(level: TEnergyLevel);
    function GetEnergyStats: TEnergyStats;
  end;

  // Xtensa Register Numbers (based on standard ABI)
  TXtensaReg = (
    xrNone = -1,
    xrA0 = 0, xrA1 = 1, xrA2 = 2, xrA3 = 3,
    xrA4 = 4, xrA5 = 5, xrA6 = 6, xrA7 = 7,
    xrA8 = 8, xrA9 = 9, xrA10 = 10, xrA11 = 11,
    xrA12 = 12, xrA13 = 13, xrA14 = 14, xrA15 = 15
  );

  // Xtensa Instruction Opcodes (simplified)
  TXtensaOpcode = (
    xtNOP   = $00,
    xtL8UI  = $01,
    xtL16UI = $02,
    xtL32I  = $03,
    xtS8I   = $04,
    xtS16I  = $05,
    xtS32I  = $06,
    xtADD   = $08,
    xtADDI  = $0A,
    xtSUB   = $0C,
    xtMOVI  = $0B,
    xtMOV   = $0D,
    xtAND   = $14,
    xtOR    = $15,
    xtXOR   = $16,
    xtSLL   = $17,
    xtSRL   = $18,
    xtSRA   = $19,
    xtBEQ   = $26,
    xtBNE   = $27,
    xtBLT   = $28,
    xtBGE   = $29,
    xtJ     = $2A,
    xtCALL  = $2B,
    xtRET   = $2C,
    xtSYSCALL = $30
  );

  TxtensaCodeEmitter = class(TInterfacedObject, ICodeEmitter)
  private
    FCodeBuffer: TByteBuffer;
    FDataBuffer: TByteBuffer;
    FEnergyLevel: TEnergyLevel;
    FEnergyStats: TEnergyStats;
    FDiag: TDiagnostics;
    FCurrentFunc: TIRFunction;
    FLabelOffsets: TStringList;
    
    procedure EmitInstruction(opcode: Byte; r1, r2, r3: TXtensaReg; imm: Integer = 0);
    procedure EmitJump(target: string);
    procedure EmitMove(dest, src: TXtensaReg);
    procedure EmitLoad32(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitStore32(src: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitAdd(dest, src1, src2: TXtensaReg);
    procedure EmitAddi(dest, src: TXtensaReg; imm: Integer);
    procedure EmitSub(dest, src1, src2: TXtensaReg);
    procedure EmitAnd(dest, src1, src2: TXtensaReg);
    procedure EmitOr(dest, src1, src2: TXtensaReg);
    procedure EmitXor(dest, src1, src2: TXtensaReg);
    procedure EmitMovi(dest: TXtensaReg; imm: Integer);
    procedure EmitSyscall(num: Integer);
    procedure EmitBranchEQ(src1, src2: TXtensaReg; labelName: string);
    procedure EmitBranchNE(src1, src2: TXtensaReg; labelName: string);
    procedure EmitIRFunction(const func: TIRFunction);
    procedure EmitIRInstr(const instr: TIRInstr);
    function GetRegisterForTemp(temp: Integer): TXtensaReg;
    function GetRegisterForLocal(localIdx: Integer): TXtensaReg;
    
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(const module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetExternalSymbols: TExternalSymbolArray;
    procedure SetEnergyLevel(level: TEnergyLevel);
    function GetEnergyStats: TEnergyStats;
  end;

implementation

uses
  syscalls_esp32;

procedure TxtensaCodeEmitter.EmitInstruction(opcode: Byte; r1, r2, r3: TXtensaReg; imm: Integer = 0);
var
  instr: UInt32;
begin
  // Simplified encoding: [31:24] R1, [23:16] R2, [15:8] R3, [7:0] Opcode
  instr := (Byte(r1) shl 24) or (Byte(r2) shl 16) or (Byte(r3) shl 8) or opcode;
  FCodeBuffer.WriteU32LE(instr);
end;

procedure TxtensaCodeEmitter.EmitJump(target: string);
begin
  // J instruction placeholder (will be patched)
  FCodeBuffer.WriteU8(Byte(xtJ));
  FCodeBuffer.WriteU32LE(0);
end;

procedure TxtensaCodeEmitter.EmitMove(dest, src: TXtensaReg);
begin
  EmitInstruction(Byte(xtMOV), dest, src, xrNone);
end;

procedure TxtensaCodeEmitter.EmitLoad32(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
begin
  EmitInstruction(Byte(xtL32I), dest, base, xrNone, offset);
end;

procedure TxtensaCodeEmitter.EmitStore32(src: TXtensaReg; base: TXtensaReg; offset: Integer);
begin
  EmitInstruction(Byte(xtS32I), src, base, xrNone, offset);
end;

procedure TxtensaCodeEmitter.EmitAdd(dest, src1, src2: TXtensaReg);
begin
  EmitInstruction(Byte(xtADD), dest, src1, src2);
end;

procedure TxtensaCodeEmitter.EmitAddi(dest, src: TXtensaReg; imm: Integer);
begin
  EmitInstruction(Byte(xtADDI), dest, src, xrNone, imm);
end;

procedure TxtensaCodeEmitter.EmitSub(dest, src1, src2: TXtensaReg);
begin
  EmitInstruction(Byte(xtSUB), dest, src1, src2);
end;

procedure TxtensaCodeEmitter.EmitAnd(dest, src1, src2: TXtensaReg);
begin
  EmitInstruction(Byte(xtAND), dest, src1, src2);
end;

procedure TxtensaCodeEmitter.EmitOr(dest, src1, src2: TXtensaReg);
begin
  EmitInstruction(Byte(xtOR), dest, src1, src2);
end;

procedure TxtensaCodeEmitter.EmitXor(dest, src1, src2: TXtensaReg);
begin
  EmitInstruction(Byte(xtXOR), dest, src1, src2);
end;

procedure TxtensaCodeEmitter.EmitMovi(dest: TXtensaReg; imm: Integer);
begin
  FCodeBuffer.WriteU8(Byte(xtMOVI));
  FCodeBuffer.WriteU8(Byte(dest));
  FCodeBuffer.WriteU16LE(imm and $FFFF);
end;

procedure TxtensaCodeEmitter.EmitSyscall(num: Integer);
begin
  FCodeBuffer.WriteU8(Byte(xtSYSCALL));
  FCodeBuffer.WriteU32LE(num);
end;

procedure TxtensaCodeEmitter.EmitBranchEQ(src1, src2: TXtensaReg; labelName: string);
begin
  EmitInstruction(Byte(xtBEQ), src1, src2, xrNone);
end;

procedure TxtensaCodeEmitter.EmitBranchNE(src1, src2: TXtensaReg; labelName: string);
begin
  EmitInstruction(Byte(xtBNE), src1, src2, xrNone);
end;

constructor TxtensaCodeEmitter.Create;
begin
  inherited Create;
  FCodeBuffer := TByteBuffer.Create;
  FDataBuffer := TByteBuffer.Create;
  FLabelOffsets := TStringList.Create;
  FEnergyLevel := eelMedium;
  FEnergyStats := GetDefaultEnergyStats;
  FDiag := TDiagnostics.Create;
end;

destructor TxtensaCodeEmitter.Destroy;
begin
  FCodeBuffer.Free;
  FDataBuffer.Free;
  FLabelOffsets.Free;
  FDiag.Free;
  inherited Destroy;
end;

function TxtensaCodeEmitter.GetRegisterForTemp(temp: Integer): TXtensaReg;
begin
  // Map IR temporaries to Xtensa registers
  // A2-A7 are used for parameters and return values (SysV ABI)
  // A8-A15 are used for locals and temporaries
  if (temp >= 0) and (temp <= 7) then
    Result := TXtensaReg(Byte(xrA2) + temp)
  else if (temp >= 8) and (temp <= 15) then
    Result := TXtensaReg(Byte(xrA8) + (temp - 8))
  else
    Result := xrNone;
end;

function TxtensaCodeEmitter.GetRegisterForLocal(localIdx: Integer): TXtensaReg;
begin
  // Map local variables to registers (A8-A15)
  if (localIdx >= 0) and (localIdx <= 7) then
    Result := TXtensaReg(Byte(xrA8) + localIdx)
  else
    Result := xrNone;
end;

procedure TxtensaCodeEmitter.EmitIRFunction(const func: TIRFunction);
var
  i: Integer;
begin
  FCurrentFunc := func;
  FLabelOffsets.Add(func.Name + '=' + IntToStr(FCodeBuffer.Size));
  
  for i := 0 to High(func.Instructions) do
    EmitIRInstr(func.Instructions[i]);
end;

procedure TxtensaCodeEmitter.EmitIRInstr(const instr: TIRInstr);
var
  destReg, src1Reg, src2Reg: TXtensaReg;
begin
  case instr.Op of
    irConstInt:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        EmitMovi(destReg, instr.ImmInt);
      end;
    
    irAdd:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        src1Reg := GetRegisterForTemp(instr.Src1);
        src2Reg := GetRegisterForTemp(instr.Src2);
        EmitAdd(destReg, src1Reg, src2Reg);
      end;
    
    irSub:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        src1Reg := GetRegisterForTemp(instr.Src1);
        src2Reg := GetRegisterForTemp(instr.Src2);
        EmitSub(destReg, src1Reg, src2Reg);
      end;
    
    irMul, irDiv:
      begin
        FDiag.Report(dkWarning, 'Multiplication/Division not yet implemented for Xtensa', NullSpan);
      end;
    
    irAnd:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        src1Reg := GetRegisterForTemp(instr.Src1);
        src2Reg := GetRegisterForTemp(instr.Src2);
        EmitAnd(destReg, src1Reg, src2Reg);
      end;
    
    irOr:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        src1Reg := GetRegisterForTemp(instr.Src1);
        src2Reg := GetRegisterForTemp(instr.Src2);
        EmitOr(destReg, src1Reg, src2Reg);
      end;
    
    irXor:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        src1Reg := GetRegisterForTemp(instr.Src1);
        src2Reg := GetRegisterForTemp(instr.Src2);
        EmitXor(destReg, src1Reg, src2Reg);
      end;
    
    irCall:
      begin
        if instr.CallMode = cmExternal then
        begin
          if instr.ImmStr = 'exit' then
            EmitSyscall(SYS_EXIT)
          else if instr.ImmStr = 'PrintStr' then
            EmitSyscall(SYS_WRITE);
        end;
      end;
    
    irLabel:
      begin
        FLabelOffsets.Add(instr.LabelName + '=' + IntToStr(FCodeBuffer.Size));
      end;
    
    irJmp:
      begin
        EmitJump(instr.LabelName);
      end;
    
    irBrTrue, irBrFalse:
      begin
        src1Reg := GetRegisterForTemp(instr.Src1);
        if instr.Op = irBrTrue then
          EmitBranchNE(src1Reg, xrNone, instr.LabelName)
        else
          EmitBranchEQ(src1Reg, xrNone, instr.LabelName);
      end;
    
    irReturn:
      begin
        FCodeBuffer.WriteU8(Byte(xtRET));
      end;
    
    irLoadLocal:
      begin
        destReg := GetRegisterForTemp(instr.Dest);
        EmitLoad32(destReg, xrA1, instr.Src1 * 4);
      end;
    
    irStoreLocal:
      begin
        src1Reg := GetRegisterForTemp(instr.Src1);
        EmitStore32(src1Reg, xrA1, instr.Dest * 4);
      end;
    
    else
      FDiag.Report(dkWarning, 'IR instruction not yet implemented for Xtensa', NullSpan);
  end;
end;

procedure TxtensaCodeEmitter.EmitFromIR(const module: TIRModule);
var
  i: Integer;
begin
  FCodeBuffer.Clear;
  FDataBuffer.Clear;
  FLabelOffsets.Clear;
  
  for i := 0 to High(module.Functions) do
    EmitIRFunction(module.Functions[i]);
  
  // Fallback infinite loop
  FCodeBuffer.WriteU8(Byte(xtJ));
  FCodeBuffer.WriteU32LE(0);
end;

function TxtensaCodeEmitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCodeBuffer;
end;

function TxtensaCodeEmitter.GetDataBuffer: TByteBuffer;
begin
  Result := FDataBuffer;
end;

function TxtensaCodeEmitter.GetExternalSymbols: TExternalSymbolArray;
begin
  Result := nil;
end;

procedure TxtensaCodeEmitter.SetEnergyLevel(level: TEnergyLevel);
begin
  FEnergyLevel := level;
end;

function TxtensaCodeEmitter.GetEnergyStats: TEnergyStats;
begin
  Result := FEnergyStats;
end;

end.