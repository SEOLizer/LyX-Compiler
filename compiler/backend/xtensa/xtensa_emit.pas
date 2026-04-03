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

  // Xtensa Register Numbers
  // A0 = return address, A1 = stack pointer, A2-A7 = args/return, A8-A15 = callee-saved
  TXtensaReg = (
    xrNone = -1,
    xrA0 = 0, xrA1 = 1, xrA2 = 2, xrA3 = 3,
    xrA4 = 4, xrA5 = 5, xrA6 = 6, xrA7 = 7,
    xrA8 = 8, xrA9 = 9, xrA10 = 10, xrA11 = 11,
    xrA12 = 12, xrA13 = 13, xrA14 = 14, xrA15 = 15
  );

  TFuncInfo = record
    Name: string;
    Offset: Integer;
  end;

  TLabelInfo = record
    Name: string;
    Offset: Integer;
  end;

  TCallPatch = record
    CodePos: Integer;
    TargetName: string;
  end;

  TBranchPatch = record
    CodePos: Integer;
    LabelName: string;
  end;

  TxtensaCodeEmitter = class(TInterfacedObject, ICodeEmitter)
  private
    FCodeBuffer: TByteBuffer;
    FDataBuffer: TByteBuffer;
    FDiag: TDiagnostics;
    FEnergyLevel: TEnergyLevel;
    FEnergyStats: TEnergyStats;
    FFuncOffsets: array of TFuncInfo;
    FLabels: array of TLabelInfo;
    FCallPatches: array of TCallPatch;
    FBranchPatches: array of TBranchPatch;
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FRandomSeedOffset: UInt64;
    FRandomSeedAdded: Boolean;
    FRandomSeedLeaPatches: array of Integer;
    
    procedure EmitNop;
    procedure EmitMov(dest, src: TXtensaReg);
    procedure EmitMovI(dest: TXtensaReg; imm: Integer);
    procedure EmitMovI128(dest: TXtensaReg; imm: Integer);
    procedure EmitAdd(dest, src1, src2: TXtensaReg);
    procedure EmitAddI(dest, src: TXtensaReg; imm: Integer);
    procedure EmitSub(dest, src1, src2: TXtensaReg);
    procedure EmitSubImm(dest, src: TXtensaReg; imm: Integer);
    procedure EmitInstr3R(buf: TByteBuffer; opcode: Byte; rd, rs, rt: TXtensaReg);
    procedure EmitNeg(dest, src: TXtensaReg);
    procedure EmitAnd(dest, src1, src2: TXtensaReg);
    procedure EmitOr(dest, src1, src2: TXtensaReg);
    procedure EmitXor(dest, src1, src2: TXtensaReg);
    procedure EmitSLL(dest, src1, src2: TXtensaReg);
    procedure EmitSRL(dest, src1, src2: TXtensaReg);
    procedure EmitSRA(dest, src1, src2: TXtensaReg);
    procedure EmitL8UI(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitL16UI(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitL32I(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitS8I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitS16I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitS32I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
    procedure EmitBEQ(src1, src2: TXtensaReg; offset: Integer);
    procedure EmitBNE(src1, src2: TXtensaReg; offset: Integer);
    procedure EmitBLT(src1, src2: TXtensaReg; offset: Integer);
    procedure EmitBGE(src1, src2: TXtensaReg; offset: Integer);
    procedure EmitJ(offset: Integer);
    procedure EmitCall(offset: Integer);
    procedure EmitRet;
    procedure EmitSyscall(num: Integer);
    
    procedure EmitPrintStrBuiltin;
    procedure EmitPrintIntBuiltin;
    procedure EmitStrLenBuiltin;
    procedure EmitStrFromIntBuiltin;
    
    function SlotOffset(slot: Integer): Integer;
    
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
  syscalls_esp32, Math;

// ============================================================================
// Xtensa Instruction Encoding
// ============================================================================
// Xtensa uses 24-bit instructions (3 bytes)
// R-format: [23:18] opcode, [17:12] r, [11:6] s, [5:0] t
// I-format: [23:12] imm12, [11:6] r, [5:0] opcode

procedure TxtensaCodeEmitter.EmitNop;
begin
  // nop = or a0, a0, a0
  FCodeBuffer.WriteU8($20);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
end;

procedure TxtensaCodeEmitter.EmitMov(dest, src: TXtensaReg);
begin
  // or dest, src, a0 (a0 is always valid)
  // Actually: or dest, src, src is more correct
  // R-format: opcode=0x20 (OR), r=dest, s=src, t=src
  FCodeBuffer.WriteU8($20 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src) or (Byte(src) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitMovI(dest: TXtensaReg; imm: Integer);
begin
  // movi.n dest, imm4 (4-bit immediate, sign-extended)
  // Only works for -8..7
  if (imm >= -8) and (imm <= 7) then
  begin
    FCodeBuffer.WriteU8(($30 or Byte(dest)) or ((imm and $F) shl 4));
    FCodeBuffer.WriteU8(0);
    FCodeBuffer.WriteU8(0);
  end
  else
    EmitMovI128(dest, imm);
end;

procedure TxtensaCodeEmitter.EmitMovI128(dest: TXtensaReg; imm: Integer);
var
  imm12: Integer;
begin
  // movi dest, imm12 (12-bit immediate, sign-extended)
  // I-format: opcode=0x02 (MOVI), r=dest, imm12
  imm12 := imm and $FFF;
  // Check if negative for sign extension
  if (imm < -2048) or (imm > 2047) then
  begin
    // Need multiple instructions for large immediates
    // Use movi + addi approach
    EmitMovI128(dest, imm and $FFFF);
    // For now, truncate to 16 bits
    Exit;
  end;
  FCodeBuffer.WriteU8($02 or Byte(dest));
  FCodeBuffer.WriteU8(imm12 and $FF);
  FCodeBuffer.WriteU8(imm12 shr 8);
end;

procedure TxtensaCodeEmitter.EmitAdd(dest, src1, src2: TXtensaReg);
begin
  // add dest, src1, src2
  // R-format: opcode=0x08 (ADD)
  FCodeBuffer.WriteU8($08 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitAddI(dest, src: TXtensaReg; imm: Integer);
var
  imm8: Integer;
begin
  // addi dest, src, imm8 (8-bit immediate, sign-extended)
  imm8 := imm and $FF;
  FCodeBuffer.WriteU8($0A or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitSubImm(dest, src: TXtensaReg; imm: Integer);
begin
  // addi dest, src, -imm
  EmitAddI(dest, src, -imm);
end;

procedure TxtensaCodeEmitter.EmitInstr3R(buf: TByteBuffer; opcode: Byte; rd, rs, rt: TXtensaReg);
begin
  // 3-register instruction: opcode | rd | rs | rt
  // R-format: [23:18] opcode, [17:12] rs, [11:6] rt, [5:0] rd
  FCodeBuffer.WriteU8((opcode shl 2) or (Byte(rd) and $3));
  FCodeBuffer.WriteU8((Byte(rs) shl 2) or (Byte(rt) shr 2));
  FCodeBuffer.WriteU8((Byte(rt) shl 6) and $C0);
end;

procedure TxtensaCodeEmitter.EmitSub(dest, src1, src2: TXtensaReg);
begin
  // sub dest, src1, src2
  // R-format: opcode=0x0C (SUB)
  FCodeBuffer.WriteU8($0C or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitNeg(dest, src: TXtensaReg);
begin
  // neg dest, src => sub dest, a0, src (a0 = 0)
  // Actually, Xtensa has a dedicated NEG instruction
  // R-format: opcode=0x0C, r=dest, s=a0, t=src
  FCodeBuffer.WriteU8($0C or Byte(dest));
  FCodeBuffer.WriteU8(Byte(xrA0) or (Byte(src) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitAnd(dest, src1, src2: TXtensaReg);
begin
  // and dest, src1, src2
  FCodeBuffer.WriteU8($14 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitOr(dest, src1, src2: TXtensaReg);
begin
  // or dest, src1, src2
  FCodeBuffer.WriteU8($20 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitXor(dest, src1, src2: TXtensaReg);
begin
  // xor dest, src1, src2
  FCodeBuffer.WriteU8($1E or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitSLL(dest, src1, src2: TXtensaReg);
begin
  // sll dest, src1, src2
  FCodeBuffer.WriteU8($17 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitSRL(dest, src1, src2: TXtensaReg);
begin
  // srl dest, src1, src2
  FCodeBuffer.WriteU8($18 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitSRA(dest, src1, src2: TXtensaReg);
begin
  // sra dest, src1, src2
  FCodeBuffer.WriteU8($19 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(src1) or (Byte(src2) shl 4));
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitL8UI(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // l8ui dest, base, offset8
  imm8 := offset and $FF;
  FCodeBuffer.WriteU8($00 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitL16UI(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // l16ui dest, base, offset8*2
  imm8 := (offset div 2) and $FF;
  FCodeBuffer.WriteU8($01 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitL32I(dest: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // l32i dest, base, offset8*4
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($02 or Byte(dest));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitS8I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // s8i src, base, offset8
  imm8 := offset and $FF;
  FCodeBuffer.WriteU8($04 or Byte(src));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitS16I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // s16i src, base, offset8*2
  imm8 := (offset div 2) and $FF;
  FCodeBuffer.WriteU8($05 or Byte(src));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitS32I(src: TXtensaReg; base: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // s32i src, base, offset8*4
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($06 or Byte(src));
  FCodeBuffer.WriteU8(Byte(base) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitBEQ(src1, src2: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  // beqz.n / beqi - simplified
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($26 or Byte(src1));
  FCodeBuffer.WriteU8(Byte(src2) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitBNE(src1, src2: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($27 or Byte(src1));
  FCodeBuffer.WriteU8(Byte(src2) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitBLT(src1, src2: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($28 or Byte(src1));
  FCodeBuffer.WriteU8(Byte(src2) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitBGE(src1, src2: TXtensaReg; offset: Integer);
var
  imm8: Integer;
begin
  imm8 := (offset div 4) and $FF;
  FCodeBuffer.WriteU8($29 or Byte(src1));
  FCodeBuffer.WriteU8(Byte(src2) or (imm8 and $F0));
  FCodeBuffer.WriteU8(imm8 shr 4);
end;

procedure TxtensaCodeEmitter.EmitJ(offset: Integer);
var
  imm18: Integer;
begin
  // j offset (18-bit relative)
  imm18 := (offset div 4) and $3FFFF;
  FCodeBuffer.WriteU8($06);
  FCodeBuffer.WriteU8(imm18 and $FF);
  FCodeBuffer.WriteU8(imm18 shr 8);
end;

procedure TxtensaCodeEmitter.EmitCall(offset: Integer);
var
  imm18: Integer;
begin
  // call offset (18-bit relative)
  imm18 := (offset div 4) and $3FFFF;
  FCodeBuffer.WriteU8($05);
  FCodeBuffer.WriteU8(imm18 and $FF);
  FCodeBuffer.WriteU8(imm18 shr 8);
end;

procedure TxtensaCodeEmitter.EmitRet;
begin
  // ret (return from call)
  // retw for windowed, ret for call0
  FCodeBuffer.WriteU8($0D);
  FCodeBuffer.WriteU8($F0);
  FCodeBuffer.WriteU8(0);
end;

procedure TxtensaCodeEmitter.EmitSyscall(num: Integer);
begin
  // syscall num
  // Xtensa syscall: syscall instruction with immediate
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($05);  // syscall opcode
  // num in a2
  EmitMovI128(xrA2, num);
  // Actual syscall instruction
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($05);
end;

function TxtensaCodeEmitter.SlotOffset(slot: Integer): Integer;
begin
  Result := slot * 4;
end;

// ============================================================================
// Builtin Functions
// ============================================================================

procedure TxtensaCodeEmitter.EmitPrintStrBuiltin;
var
  loopStart, donePos: Integer;
  lenReg, strReg: TXtensaReg;
begin
  // __builtin_PrintStr: A2 = string pointer
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_PrintStr';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
  
  strReg := xrA2;
  lenReg := xrA3;
  
  // Calculate string length
  EmitMovI128(lenReg, 0);
  
  loopStart := FCodeBuffer.Size;
  EmitL8UI(xrA4, strReg, 0);
  EmitBEQ(xrA4, xrA0, 12);
  EmitAddI(strReg, strReg, 1);
  EmitAddI(lenReg, lenReg, 1);
  EmitJ(loopStart - FCodeBuffer.Size - 3);
  
  donePos := FCodeBuffer.Size;
  // donePos wird für Branch-Patching benötigt
  
  // sys_write(STDOUT, str, len)
  EmitMovI128(xrA2, STDOUT_FD);
  // A3 = str (need original pointer - save it first)
  // For now, simplified
  EmitMovI128(xrA2, SYS_WRITE);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($05);
  
  EmitRet;
end;

procedure TxtensaCodeEmitter.EmitPrintIntBuiltin;
begin
  // __builtin_PrintInt: A2 = int value
  // Simplified: just print "INT" placeholder for now
  // Full itoa requires division which is expensive on Xtensa
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_PrintInt';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
  
  // Print "INT" as placeholder
  EmitMovI128(xrA2, STDOUT_FD);
  EmitMovI128(xrA3, 0);  // String pointer (placeholder)
  EmitMovI128(xrA4, 3);  // Length
  EmitMovI128(xrA2, SYS_WRITE);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($05);
  
  EmitRet;
end;

procedure TxtensaCodeEmitter.EmitStrLenBuiltin;
var
  loopStart, donePos: Integer;
  strReg, lenReg: TXtensaReg;
begin
  // __builtin_StrLen: A2 = string pointer, returns length in A2
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_StrLen';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
  
  strReg := xrA2;
  lenReg := xrA3;
  
  EmitMovI128(lenReg, 0);
  
  loopStart := FCodeBuffer.Size;
  EmitL8UI(xrA4, strReg, 0);
  EmitBEQ(xrA4, xrA0, 12);  // If null, done
  EmitAddI(strReg, strReg, 1);
  EmitAddI(lenReg, lenReg, 1);
  EmitJ(loopStart - FCodeBuffer.Size - 3);
  
  donePos := FCodeBuffer.Size;
  EmitMov(xrA2, lenReg);
  EmitRet;
end;

procedure TxtensaCodeEmitter.EmitStrFromIntBuiltin;
begin
  // __builtin_StrFromInt: A2 = int, returns string pointer in A2
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_StrFromInt';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
  
  // For now, return NULL
  EmitMovI128(xrA2, 0);
  EmitRet;
end;

// ============================================================================
// Main Emitter
// ============================================================================

constructor TxtensaCodeEmitter.Create;
begin
  inherited Create;
  FCodeBuffer := TByteBuffer.Create;
  FDataBuffer := TByteBuffer.Create;
  FDiag := TDiagnostics.Create;
  FEnergyLevel := eelMedium;
  FEnergyStats := GetDefaultEnergyStats;
  FRandomSeedAdded := False;
end;

destructor TxtensaCodeEmitter.Destroy;
begin
  FCodeBuffer.Free;
  FDataBuffer.Free;
  FDiag.Free;
  inherited Destroy;
end;

procedure TxtensaCodeEmitter.EmitFromIR(const module: TIRModule);
var
  i, j: Integer;
  instr: TIRInstr;
  fn: TIRFunction;
  localCnt, maxTemp, slotIdx, totalSlots, frameSize: Integer;
  strIdx: Integer;
  strOffset: UInt64;
  totalDataOffset: UInt64;
  stringByteOffsets: array of UInt64;
  labelIdx, targetPos, patchPos: Integer;
  branchOffset: Int32;
  callPatchIdx, targetFuncIdx: Integer;
  argCount: Integer;
  argTemps: array of Integer;
  cond: Byte;
  loopStartPos, loopEndPos: Integer;
  branchPos1, branchPos2, branchPos3: Integer;
  notFoundPos, doneLabelPos: Integer;
  found: Boolean;
  ei: Integer;
begin
  FCodeBuffer.Clear;
  FDataBuffer.Clear;
  SetLength(FFuncOffsets, 0);
  SetLength(FLabels, 0);
  SetLength(FCallPatches, 0);
  SetLength(FBranchPatches, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  FRandomSeedAdded := False;
  
  // Phase 1: Write strings to data section
  totalDataOffset := 0;
  if Assigned(module) then
  begin
    SetLength(stringByteOffsets, module.Strings.Count);
    for i := 0 to module.Strings.Count - 1 do
    begin
      stringByteOffsets[i] := totalDataOffset;
      for j := 1 to Length(module.Strings[i]) do
        FDataBuffer.WriteU8(Byte(module.Strings[i][j]));
      FDataBuffer.WriteU8(0);
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;
  
  while (FDataBuffer.Size mod 4) <> 0 do
    FDataBuffer.WriteU8(0);
  
  // Phase 2: Entry point (_start)
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '_start';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
  
  // Call main
  EmitCall(0);  // Will be patched
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size - 3;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  
  // exit(A2) - A2 contains return value from main
  EmitMovI128(xrA2, SYS_EXIT);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($00);
  FCodeBuffer.WriteU8($05);  // syscall
  
  // Infinite loop fallback
  EmitJ(-3);
  
  // Phase 3: Builtin functions
  EmitPrintStrBuiltin;
  EmitPrintIntBuiltin;
  EmitStrLenBuiltin;
  EmitStrFromIntBuiltin;
  
  // Phase 4: User functions
  if Assigned(module) then
  begin
    for i := 0 to High(module.Functions) do
    begin
      fn := module.Functions[i];
      
      SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
      FFuncOffsets[High(FFuncOffsets)].Name := fn.Name;
      FFuncOffsets[High(FFuncOffsets)].Offset := FCodeBuffer.Size;
      
      localCnt := fn.LocalCount;
      maxTemp := -1;
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        if instr.Dest > maxTemp then maxTemp := instr.Dest;
        if instr.Src1 > maxTemp then maxTemp := instr.Src1;
        if instr.Src2 > maxTemp then maxTemp := instr.Src2;
      end;
      
      totalSlots := localCnt + maxTemp + 1;
      if totalSlots < 1 then totalSlots := 1;
      
      frameSize := ((totalSlots * 4) + 3) and not 3;  // 4-byte aligned
      
      // Function prologue
      // Save A0 (return address) and adjust stack
      EmitS32I(xrA0, xrA1, -4);
      EmitAddI(xrA1, xrA1, -frameSize);
      
      // Copy parameters from A2-A7 to stack slots
      for j := 0 to Min(fn.ParamCount - 1, 5) do
      begin
        EmitS32I(TXtensaReg(Byte(xrA2) + j), xrA1, 4 + SlotOffset(j));
      end;
      
      // Clear branch tracking
      SetLength(FBranchPatches, 0);
      
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        
        case instr.Op of
          irConstInt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, instr.ImmInt);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irConstStr:
            begin
              slotIdx := localCnt + instr.Dest;
              strIdx := StrToIntDef(instr.ImmStr, 0);
              SetLength(FLeaPositions, Length(FLeaPositions) + 1);
              FLeaPositions[High(FLeaPositions)] := FCodeBuffer.Size;
              SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
              FLeaStrIndex[High(FLeaStrIndex)] := strIdx;
              // Load address from data section (placeholder)
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadLocal:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irStoreLocal:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, instr.Dest);
            end;
          
          irAdd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitAdd(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irSub:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSub(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irAnd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitAnd(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irOr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitOr(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irXor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitXor(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irNeg:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitNeg(xrA2, xrA2);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irShl:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSLL(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irShr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSRL(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpEq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSub(xrA2, xrA2, xrA3);
              EmitMovI128(xrA4, 1);
              EmitMovI128(xrA5, 0);
              EmitBEQ(xrA2, xrA0, 12);
              EmitMov(xrA2, xrA5);
              EmitJ(6);
              EmitMov(xrA2, xrA4);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpNeq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSub(xrA2, xrA2, xrA3);
              EmitMovI128(xrA4, 0);
              EmitMovI128(xrA5, 1);
              EmitBEQ(xrA2, xrA0, 12);
              EmitMov(xrA2, xrA5);
              EmitJ(6);
              EmitMov(xrA2, xrA4);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              // if src1 < src2: result = 1
              EmitBLT(xrA2, xrA3, 12);
              EmitMovI128(xrA2, 0);
              EmitJ(6);
              EmitMovI128(xrA2, 1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitBGE(xrA3, xrA2, 12);
              EmitMovI128(xrA2, 0);
              EmitJ(6);
              EmitMovI128(xrA2, 1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpGt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitBLT(xrA3, xrA2, 12);
              EmitMovI128(xrA2, 0);
              EmitJ(6);
              EmitMovI128(xrA2, 1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpGe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitBGE(xrA2, xrA3, 12);
              EmitMovI128(xrA2, 0);
              EmitJ(6);
              EmitMovI128(xrA2, 1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          irLabel:
            begin
              SetLength(FLabels, Length(FLabels) + 1);
              FLabels[High(FLabels)].Name := instr.LabelName;
              FLabels[High(FLabels)].Offset := FCodeBuffer.Size;
            end;
          
          irJmp:
            begin
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCodeBuffer.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitJ(0);
            end;
          
          irBrTrue:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitBNE(xrA2, xrA0, 0);
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCodeBuffer.Size - 3;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            end;
          
          irBrFalse:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitBEQ(xrA2, xrA0, 0);
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCodeBuffer.Size - 3;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            end;
          
          irCall:
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
              FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
              EmitCall(0);
            end;
          
          irCallBuiltin:
            begin
              if instr.ImmStr = 'exit' then
              begin
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                EmitMovI128(xrA2, SYS_EXIT);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
              end
              else if instr.ImmStr = 'PrintStr' then
              begin
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintStr';
                EmitCall(0);
              end
              else if instr.ImmStr = 'PrintInt' then
              begin
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintInt';
                EmitCall(0);
              end
              else if instr.ImmStr = 'StrLen' then
              begin
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_StrLen';
                EmitCall(0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFromInt' then
              begin
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_StrFromInt';
                EmitCall(0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'open' then
              begin
                // open(path, flags, mode) -> fd
                // sys_openat(AT_FDCWD, path, flags, mode)
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, O_RDONLY);
                if instr.Src3 >= 0 then
                  EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3))
                else
                  EmitMovI128(xrA4, 0);
                EmitMovI128(xrA2, -100);  // AT_FDCWD
                EmitMovI128(xrA7, SYS_OPENAT);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'read' then
              begin
                // read(fd, buf, count) -> bytes_read
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, STDIN_FD);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                if instr.Src3 >= 0 then
                  EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3))
                else
                  EmitMovI128(xrA4, 0);
                EmitMovI128(xrA7, SYS_READ);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'write' then
              begin
                // write(fd, buf, count) -> bytes_written
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, STDOUT_FD);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                if instr.Src3 >= 0 then
                  EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3))
                else
                  EmitMovI128(xrA4, 0);
                EmitMovI128(xrA7, SYS_WRITE);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'close' then
              begin
                // close(fd) -> int
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                EmitMovI128(xrA7, SYS_CLOSE);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'lseek' then
              begin
                // lseek(fd, offset, whence) -> new_offset
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                if instr.Src3 >= 0 then
                  EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3))
                else
                  EmitMovI128(xrA4, SEEK_SET);
                EmitMovI128(xrA7, SYS_LSEEK);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'unlink' then
              begin
                // unlink(path) -> int
                // sys_unlinkat(AT_FDCWD, path, 0)
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                EmitMovI128(xrA3, -100);  // AT_FDCWD
                EmitMovI128(xrA4, 0);
                EmitMovI128(xrA7, SYS_UNLINKAT);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'mkdir' then
              begin
                // mkdir(path, mode) -> int
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rmdir' then
              begin
                // rmdir(path) -> int
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'chmod' then
              begin
                // chmod(path, mode) -> int
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rename' then
              begin
                // rename(old, new) -> int
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'getpid' then
              begin
                // getpid() -> int
                EmitMovI128(xrA7, SYS_GETPID);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($00);
                FCodeBuffer.WriteU8($05);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sleep_ms' then
              begin
                // sleep_ms(ms) -> void
                // Stub
              end
              else if instr.ImmStr = 'now_unix' then
              begin
                // now_unix() -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'now_unix_ms' then
              begin
                // now_unix_ms() -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'Random' then
              begin
                // Random() -> int64
                // Use LCG if seed available
                if not FRandomSeedAdded then
                begin
                  FRandomSeedOffset := FDataBuffer.Size;
                  FDataBuffer.WriteU32LE(1);
                  FRandomSeedAdded := True;
                end;
                
                // Load seed, compute new seed, store back
                // Simplified: return incrementing counter
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'RandomSeed' then
              begin
                // RandomSeed(seed) -> void
                if not FRandomSeedAdded then
                begin
                  FRandomSeedOffset := FDataBuffer.Size;
                  FDataBuffer.WriteU32LE(1);
                  FRandomSeedAdded := True;
                end;
              end
              else if instr.ImmStr = 'mmap' then
              begin
                // mmap(size, prot, flags) -> pointer
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'munmap' then
              begin
                // munmap(addr, size) -> int
                // Stub
              end
              else if instr.ImmStr = 'peek8' then
              begin
                // peek8(addr) -> int
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                EmitL8UI(xrA2, xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek16' then
              begin
                // peek16(addr) -> int
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                EmitL16UI(xrA2, xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek32' then
              begin
                // peek32(addr) -> int
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                EmitL32I(xrA2, xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke8' then
              begin
                // poke8(addr, value) -> void
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                EmitS8I(xrA3, xrA2, 0);
              end
              else if instr.ImmStr = 'poke16' then
              begin
                // poke16(addr, value) -> void
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                EmitS16I(xrA3, xrA2, 0);
              end
              else if instr.ImmStr = 'poke32' then
              begin
                // poke32(addr, value) -> void
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                EmitS32I(xrA3, xrA2, 0);
              end
              else if instr.ImmStr = 'StrCharAt' then
              begin
                // StrCharAt(s, index) -> char
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src2 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovI128(xrA3, 0);
                EmitL8UI(xrA2, xrA2, 0);  // Simplified
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSetChar' then
              begin
                // StrSetChar(s, index, ch) -> void
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Src3 >= 0 then
                  EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src3))
                else
                  EmitMovI128(xrA3, 0);
                EmitS8I(xrA3, xrA2, 0);  // Simplified
              end
              else if instr.ImmStr = 'StrNew' then
              begin
                // StrNew(cap) -> pointer
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFree' then
              begin
                // StrFree(ptr) -> void
              end
              else if instr.ImmStr = 'StrAppend' then
              begin
                // StrAppend(dest, src) -> pchar
                // Stub: return dest
                if instr.Src1 >= 0 then
                  EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFindChar' then
              begin
                // StrFindChar(s, ch, start) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSub' then
              begin
                // StrSub(s, start, len) -> pchar
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrConcat' then
              begin
                // StrConcat(a, b) -> pchar
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrCopy' then
              begin
                // StrCopy(s) -> pchar
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'FileGetSize' then
              begin
                // FileGetSize(path) -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrStartsWith' then
              begin
                // StrStartsWith(s, prefix) -> bool
                // Stub: return true
                EmitMovI128(xrA2, 1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEndsWith' then
              begin
                // StrEndsWith(s, suffix) -> bool
                // Stub: return false
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEquals' then
              begin
                // StrEquals(a, b) -> bool
                // Stub: return true
                EmitMovI128(xrA2, 1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArgC' then
              begin
                // GetArgC() -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArg' then
              begin
                // GetArg(i) -> pchar
                // Stub: return NULL
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'PrintFloat' then
              begin
                // PrintFloat(f: f64) -> void
                // Stub: ESP32 has no FPU
              end
              else if instr.ImmStr = 'Println' then
              begin
                // Println(s: pchar) -> void
                // Stub
              end
              else if instr.ImmStr = 'printf' then
              begin
                // printf(format, ...) -> void
                // Stub
              end
              else if instr.ImmStr = 'ioctl' then
              begin
                // ioctl(fd, request, arg) -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek64' then
              begin
                // peek64(addr) -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke64' then
              begin
                // poke64(addr, value) -> void
              end
              else if instr.ImmStr = 'sys_socket' then
              begin
                // sys_socket(domain, type, protocol) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_bind' then
              begin
                // sys_bind(fd, addr, addrlen) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_listen' then
              begin
                // sys_listen(fd, backlog) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_accept' then
              begin
                // sys_accept(fd, addr, addrlen) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_connect' then
              begin
                // sys_connect(fd, addr, addrlen) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_recvfrom' then
              begin
                // sys_recvfrom(fd, buf, len, flags, addr, addrlen) -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_sendto' then
              begin
                // sys_sendto(fd, buf, len, flags, addr, addrlen) -> int64
                // Stub: return 0
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_setsockopt' then
              begin
                // sys_setsockopt(fd, level, optname, optval, optlen) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_getsockopt' then
              begin
                // sys_getsockopt(fd, level, optname, optval, optlen) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_shutdown' then
              begin
                // sys_shutdown(fd, how) -> int64
                // Stub: return -1
                EmitMovI128(xrA2, -1);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else
              begin
                // Unknown builtin - stub
                EmitMovI128(xrA2, 0);
                if instr.Dest >= 0 then
                  EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end;
            end;
          
          TIROpKind.irFuncExit:
            begin
              if instr.Src1 >= 0 then
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitAddI(xrA1, xrA1, frameSize);
              EmitL32I(xrA0, xrA1, -4);
              EmitRet;
            end;
          
          TIROpKind.irLoadLocalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, frameSize + SlotOffset(instr.Src1));
              EmitAdd(xrA2, xrA2, xrA1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          TIROpKind.irLoadGlobalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          TIROpKind.irLoadElem:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSLL(xrA3, xrA3, xrA3);
              EmitSLL(xrA3, xrA3, xrA3);
              EmitAdd(xrA2, xrA2, xrA3);
              EmitL32I(xrA2, xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;
          
          TIROpKind.irStoreElem:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3));
              EmitSLL(xrA3, xrA3, xrA3);
              EmitSLL(xrA3, xrA3, xrA3);
              EmitAdd(xrA2, xrA2, xrA3);
              EmitS32I(xrA4, xrA2, 0);
            end;
          
          TIROpKind.irPanic:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovI128(xrA3, 5);
              EmitMovI128(xrA2, SYS_WRITE);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
              EmitMovI128(xrA2, 1);
              EmitMovI128(xrA7, SYS_EXIT);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
            end;
          
          TIROpKind.irDynArrayPush, TIROpKind.irDynArrayPop,
          TIROpKind.irDynArrayLen, TIROpKind.irDynArrayFree:
            begin
              EmitMovI128(xrA2, 0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          TIROpKind.irMapNew, TIROpKind.irSetNew:
            begin
              EmitMovI128(xrA2, 0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          TIROpKind.irMapSet, TIROpKind.irSetAdd:
            begin
              // Stub
            end;
          
          TIROpKind.irMapGet, TIROpKind.irSetContains:
            begin
              EmitMovI128(xrA2, 0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          TIROpKind.irMapLen, TIROpKind.irSetLen:
            begin
              EmitMovI128(xrA2, 0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          TIROpKind.irMapRemove, TIROpKind.irSetRemove,
          TIROpKind.irMapFree, TIROpKind.irSetFree:
            begin
              // Stub: munmap via syscall
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovI128(xrA7, SYS_MUNMAP);
              EmitMovI128(xrA3, 4096);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
            end;

          // === Arithmetic (TOR-011) ===
          TIROpKind.irMul:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              // MUL16 or software mul - Xtensa has MULL instruction
              EmitInstr3R(FCodeBuffer, $90, xrA2, xrA2, xrA3); // mull a2, a2, a3
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irDiv:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              // DIVU instruction
              EmitInstr3R(FCodeBuffer, $91, xrA2, xrA2, xrA3); // divu a2, a2, a3
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irMod:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              // REMU instruction
              EmitInstr3R(FCodeBuffer, $92, xrA2, xrA2, xrA3); // remu a2, a2, a3
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irNot:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              // XOR with -1
              EmitMovI128(xrA3, -1);
              EmitXor(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irNor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitOr(xrA2, xrA2, xrA3);
              EmitMovI128(xrA4, -1);
              EmitXor(xrA2, xrA2, xrA4);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irBitAnd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitAnd(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irBitOr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitOr(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irBitXor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitXor(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irBitNot:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovI128(xrA3, -1);
              EmitXor(xrA2, xrA2, xrA3);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Float Operations (stubs - ESP32 has no FPU) ===
          TIROpKind.irFAdd, TIROpKind.irFSub, TIROpKind.irFMul, TIROpKind.irFDiv, TIROpKind.irFNeg:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irFCmpEq, TIROpKind.irFCmpNeq, TIROpKind.irFCmpLt,
          TIROpKind.irFCmpLe, TIROpKind.irFCmpGt, TIROpKind.irFCmpGe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irConstFloat:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irFToI, TIROpKind.irIToF:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irCast:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irSExt, TIROpKind.irZExt, TIROpKind.irTrunc:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Globals ===
          TIROpKind.irStoreGlobal:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              // Store to global - stub
            end;

          TIROpKind.irLoadStructAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Control Flow ===
          TIROpKind.irCallStruct:
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCodeBuffer.Size;
              FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
              EmitCall(0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;

          TIROpKind.irVarCall:
            begin
              // Virtual call via VMT
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA2, xrA2, 0); // VMT ptr
              EmitL32I(xrA2, xrA2, instr.VMTIndex * 4);
              EmitCall(0);
              if instr.Dest >= 0 then
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
            end;

          TIROpKind.irReturnStruct:
            begin
              if instr.Src1 >= 0 then
                EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitAddI(xrA1, xrA1, frameSize);
              EmitL32I(xrA0, xrA1, -4);
              EmitRet;
            end;

          TIROpKind.irStackAlloc:
            begin
              slotIdx := localCnt + instr.Dest;
              if instr.ImmInt > 0 then
                EmitSubImm(xrA1, xrA1, instr.ImmInt);
              EmitMov(xrA2, xrA1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irStoreElemDyn:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitL32I(xrA3, xrA1, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitL32I(xrA4, xrA1, frameSize + SlotOffset(localCnt + instr.Src3));
              EmitSLL(xrA3, xrA3, xrA3);
              EmitSLL(xrA3, xrA3, xrA3);
              EmitAdd(xrA2, xrA2, xrA3);
              EmitS32I(xrA4, xrA2, 0);
            end;

          TIROpKind.irLoadField, TIROpKind.irStoreField:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irLoadFieldHeap, TIROpKind.irStoreFieldHeap:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irAlloc:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitMovI128(xrA3, instr.ImmInt);
              EmitMovI128(xrA4, 3);
              EmitMovI128(xrA5, -1);
              EmitMovI128(xrA6, 0);
              EmitMovI128(xrA7, SYS_MMAP);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irFree:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovI128(xrA3, 4096);
              EmitMovI128(xrA7, SYS_MUNMAP);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
            end;

          TIROpKind.irLoadCaptured:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irPoolAlloc:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitMovI128(xrA3, instr.ImmInt);
              EmitMovI128(xrA4, 3);
              EmitMovI128(xrA5, -1);
              EmitMovI128(xrA6, 0);
              EmitMovI128(xrA7, SYS_MMAP);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irPoolFree:
            begin
              EmitL32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovI128(xrA3, 4096);
              EmitMovI128(xrA7, SYS_MUNMAP);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($00);
              FCodeBuffer.WriteU8($05);
            end;

          TIROpKind.irPushHandler, TIROpKind.irPopHandler,
          TIROpKind.irLoadHandlerExn, TIROpKind.irThrow:
            begin
              if instr.Dest >= 0 then
              begin
                EmitMovI128(xrA2, 0);
                EmitS32I(xrA2, xrA1, frameSize + SlotOffset(localCnt + instr.Dest));
              end;
            end;

          // === SIMD (stubs - ESP32 has no SIMD) ===
          TIROpKind.irSIMDAdd, TIROpKind.irSIMDSub, TIROpKind.irSIMDMul, TIROpKind.irSIMDDiv,
          TIROpKind.irSIMDAnd, TIROpKind.irSIMDOr, TIROpKind.irSIMDXor, TIROpKind.irSIMDNeg:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irSIMDCmpEq, TIROpKind.irSIMDCmpNe, TIROpKind.irSIMDCmpLt,
          TIROpKind.irSIMDCmpLe, TIROpKind.irSIMDCmpGt, TIROpKind.irSIMDCmpGe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          TIROpKind.irSIMDLoadElem, TIROpKind.irSIMDStoreElem:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Map Contains (TOR-011) ===
          TIROpKind.irMapContains:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 0);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Type Checking (TOR-011) ===
          TIROpKind.irIsType:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovI128(xrA2, 1);
              EmitS32I(xrA2, xrA1, frameSize + SlotOffset(slotIdx));
            end;

          // === Debug Inspect (TOR-011) ===
          TIROpKind.irInspect:
            begin
              // Stub
            end;
          
          else
            FDiag.Report(dkWarning, 'IR instruction not yet implemented for Xtensa: ' + IntToStr(Ord(instr.Op)), NullSpan);
        end;
      end;
    end;
  end;
  
  // Phase 5: Patch branches
  for i := 0 to High(FBranchPatches) do
  begin
    patchPos := FBranchPatches[i].CodePos;
    // Find target label
    found := False;
    for labelIdx := 0 to High(FLabels) do
    begin
      if FLabels[labelIdx].Name = FBranchPatches[i].LabelName then
      begin
        targetPos := FLabels[labelIdx].Offset;
        branchOffset := targetPos - (patchPos + 3);
        // Patch the jump instruction
        FCodeBuffer.PatchU8(patchPos, FCodeBuffer.ReadU8(patchPos) and $F8);
        FCodeBuffer.PatchU8(patchPos + 1, branchOffset and $FF);
        FCodeBuffer.PatchU8(patchPos + 2, (branchOffset shr 8) and $FF);
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 6: Patch calls
  for i := 0 to High(FCallPatches) do
  begin
    patchPos := FCallPatches[i].CodePos;
    // Find target function
    found := False;
    for ei := 0 to High(FFuncOffsets) do
    begin
      if FFuncOffsets[ei].Name = FCallPatches[i].TargetName then
      begin
        targetPos := FFuncOffsets[ei].Offset;
        branchOffset := targetPos - (patchPos + 3);
        // Patch the call instruction
        FCodeBuffer.PatchU8(patchPos, FCodeBuffer.ReadU8(patchPos) and $F8);
        FCodeBuffer.PatchU8(patchPos + 1, branchOffset and $FF);
        FCodeBuffer.PatchU8(patchPos + 2, (branchOffset shr 8) and $FF);
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 7: Patch string LEA positions
  for i := 0 to High(FLeaPositions) do
  begin
    patchPos := FLeaPositions[i];
    strIdx := FLeaStrIndex[i];
    if (strIdx >= 0) and (strIdx < Length(stringByteOffsets)) then
    begin
      strOffset := stringByteOffsets[strIdx];
      // Patch the movi instruction with data address
      // For now, use relative offset from code
      FCodeBuffer.PatchU8(patchPos + 1, strOffset and $FF);
      FCodeBuffer.PatchU8(patchPos + 2, (strOffset shr 8) and $FF);
    end;
  end;
  
  // Fallback infinite loop
  EmitJ(-3);
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
