{$mode objfpc}{$H+}
unit win_arm64_emit;

interface

uses
  SysUtils, Classes, bytes, ir, backend_types;

type
  TLabelPos = record
    Name: string;
    Pos: Integer;
  end;

  TBranchPatch = record
    Pos: Integer;
    LabelName: string;
    InstrType: Integer; // 0=B, 1=BL, 2=CBZ, 3=CBNZ, 4=B.cond
    CondCode: Integer;
  end;

  TGlobalVarLeaPatch = record
    VarIndex: Integer;
    CodePos: Integer;
    IsAdrp: Boolean;
  end;

  // Record for external function calls (Windows API)
  TExtFuncPatch = record
    CodePos: Integer;
    FuncName: string;
    IsTailCall: Boolean;
  end;

  TWindowsARM64Emitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FLabelPositions: array of TLabelPos;
    FBranchPatches: array of TBranchPatch;
    FFuncOffsets: array of Integer;
    FFuncNames: TStringList;
    FCallPatches: array of record
      CodePos: Integer;
      TargetName: string;
    end;
    FGlobalVarNames: TStringList;
    FGlobalVarOffsets: array of UInt64;
    FGlobalVarLeaPatches: array of TGlobalVarLeaPatch;
    FTotalDataOffset: UInt64;
    // Random seed
    FRandomSeedOffset: UInt64;
    FRandomSeedAdded: Boolean;
    FRandomSeedLeaPatches: array of Integer;
    // External symbols for dynamic linking
    FExternalSymbols: array of TExternalSymbol;
    FPLTGOTPatches: array of TPLTGOTPatch;
    // Windows API patches - we need to load addresses from IAT
    FWindowsAPIPatches: array of TExtFuncPatch;
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetFunctionOffset(const name: string): Integer;
    function GetExternalSymbols: TExternalSymbolArray;
    function GetPLTGOTPatches: TPLTGOTPatchArray;
  end;

implementation

uses
  Math;

const
  // ARM64 General-Purpose Registers (64-bit)
  X0 = 0; X1 = 1; X2 = 2; X3 = 3; X4 = 4; X5 = 5; X6 = 6; X7 = 7;
  X8 = 8; X9 = 9; X10 = 10; X11 = 11; X12 = 12; X13 = 13; X14 = 14; X15 = 15;
  X16 = 16; X17 = 17; X18 = 18; X19 = 19; X20 = 20; X21 = 21; X22 = 22; X23 = 23;
  X24 = 24; X25 = 25; X26 = 26; X27 = 27; X28 = 28;
  X29 = 29;
  X30 = 30;
  XZR = 31;
  SP = 31;
  RBP = 29;

  // Parameter registers (AAPCS64)
  ParamRegs: array[0..7] of Byte = (X0, X1, X2, X3, X4, X5, X6, X7);

  // ARM64 FP/SIMD Registers
  V0 = 0; V1 = 1; V2 = 2; V3 = 3; V4 = 4; V5 = 5; V6 = 6; V7 = 7;
  V8 = 8; V9 = 9; V10 = 10; V11 = 11; V12 = 12; V13 = 13; V14 = 14; V15 = 15;

  // Condition codes
  COND_EQ = $0;
  COND_NE = $1;
  COND_LT = $B;
  COND_LE = $D;
  COND_GT = $C;
  COND_GE = $A;

// ==========================================================================
// ARM64 Instruction Encoding
// ==========================================================================

procedure EmitInstr(buf: TByteBuffer; instr: DWord);
begin
  buf.WriteU32LE(instr);
end;

procedure WriteMovz(buf: TByteBuffer; rd: Byte; imm: Word; shift: Byte);
var
  hw: Byte;
begin
  hw := shift div 16;
  EmitInstr(buf, $D2800000 or (DWord(hw) shl 21) or (DWord(imm) shl 5) or rd);
end;

procedure WriteMovk(buf: TByteBuffer; rd: Byte; imm: Word; shift: Byte);
var
  hw: Byte;
begin
  hw := shift div 16;
  EmitInstr(buf, $F2800000 or (DWord(hw) shl 21) or (DWord(imm) shl 5) or rd);
end;

procedure WriteMovImm64(buf: TByteBuffer; rd: Byte; imm: UInt64);
var
  w0, w1, w2, w3: Word;
  needK1, needK2, needK3: Boolean;
begin
  w0 := Word(imm and $FFFF);
  w1 := Word((imm shr 16) and $FFFF);
  w2 := Word((imm shr 32) and $FFFF);
  w3 := Word((imm shr 48) and $FFFF);

  needK1 := w1 <> 0;
  needK2 := w2 <> 0;
  needK3 := w3 <> 0;

  if (not needK1) and (not needK2) and (not needK3) then
  begin
    WriteMovz(buf, rd, w0, 0);
    Exit;
  end;

  WriteMovz(buf, rd, w0, 0);
  if needK1 then WriteMovk(buf, rd, w1, 16);
  if needK2 then WriteMovk(buf, rd, w2, 32);
  if needK3 then WriteMovk(buf, rd, w3, 48);
end;

procedure WriteMovRegReg(buf: TByteBuffer; rd, rm: Byte);
begin
  if rm = SP then
    EmitInstr(buf, $910003E0 or rd)
  else
    EmitInstr(buf, $AA0003E0 or (DWord(rm) shl 16) or rd);
end;

procedure WriteLdrImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset div 8) and $FFF);
  EmitInstr(buf, $F9400000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

procedure WriteStrImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset div 8) and $FFF);
  EmitInstr(buf, $F9000000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

procedure WriteLdpPostIndex(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  EmitInstr(buf, $A8C00000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

procedure WriteStpPreIndex(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  EmitInstr(buf, $A9800000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

procedure WriteLdpOffset(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  EmitInstr(buf, $A9400000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

procedure WriteStpOffset(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  EmitInstr(buf, $A9000000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

procedure WriteAddRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $8B000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteAddImm(buf: TByteBuffer; rd, rn: Byte; imm: Word);
begin
  EmitInstr(buf, $91000000 or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5) or rd);
end;

procedure WriteSubRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $CB000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteSubImm(buf: TByteBuffer; rd, rn: Byte; imm: Word);
begin
  EmitInstr(buf, $D1000000 or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5) or rd);
end;

procedure WriteMul(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $9B007C00 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteSdiv(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $9AC00C00 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteUdiv(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $9AC00800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteMsub(buf: TByteBuffer; rd, rn, rm, ra: Byte);
begin
  EmitInstr(buf, $9B008000 or (DWord(rm) shl 16) or (DWord(ra) shl 10) or (DWord(rn) shl 5) or rd);
end;

procedure WriteNeg(buf: TByteBuffer; rd, rm: Byte);
begin
  WriteSubRegReg(buf, rd, XZR, rm);
end;

procedure WriteAndRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $8A000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteOrrRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $AA000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteEorRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  EmitInstr(buf, $CA000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

procedure WriteCmpRegReg(buf: TByteBuffer; rn, rm: Byte);
begin
  EmitInstr(buf, $EB00001F or (DWord(rm) shl 16) or (DWord(rn) shl 5));
end;

procedure WriteCmpImm(buf: TByteBuffer; rn: Byte; imm: Word);
begin
  EmitInstr(buf, $F100001F or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5));
end;

procedure WriteCset(buf: TByteBuffer; rd: Byte; cond: Byte);
var
  invCond: Byte;
begin
  invCond := cond xor 1;
  EmitInstr(buf, $9A9F07E0 or (DWord(invCond) shl 12) or rd);
end;

procedure WriteBranch(buf: TByteBuffer; offset: Int32);
var
  imm26: DWord;
begin
  imm26 := DWord((offset div 4) and $3FFFFFF);
  EmitInstr(buf, $14000000 or imm26);
end;

procedure WriteBranchLink(buf: TByteBuffer; offset: Int32);
var
  imm26: DWord;
begin
  imm26 := DWord((offset div 4) and $3FFFFFF);
  EmitInstr(buf, $94000000 or imm26);
end;

procedure WriteBranchCond(buf: TByteBuffer; cond: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  EmitInstr(buf, $54000000 or (imm19 shl 5) or cond);
end;

procedure WriteCbz(buf: TByteBuffer; rt: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  EmitInstr(buf, $B4000000 or (imm19 shl 5) or rt);
end;

procedure WriteCbnz(buf: TByteBuffer; rt: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  EmitInstr(buf, $B5000000 or (imm19 shl 5) or rt);
end;

procedure WriteRet(buf: TByteBuffer);
begin
  EmitInstr(buf, $D65F03C0);
end;

procedure WriteNop(buf: TByteBuffer);
begin
  EmitInstr(buf, $D503201F);
end;

procedure WriteAdr(buf: TByteBuffer; rd: Byte; offset: Int32);
var
  immlo, immhi: DWord;
begin
  immlo := DWord(offset and $3);
  immhi := DWord((offset shr 2) and $7FFFF);
  EmitInstr(buf, $10000000 or (immlo shl 29) or (immhi shl 5) or rd);
end;

procedure WriteAdrp(buf: TByteBuffer; rd: Byte; offset: Int32);
var
  immlo, immhi: DWord;
begin
  immlo := DWord((offset shr 12) and $3);
  immhi := DWord((offset shr 14) and $7FFFF);
  EmitInstr(buf, $90000000 or (immlo shl 29) or (immhi shl 5) or rd);
end;

// Load from [base + offset] into dest register
procedure WriteLoad(buf: TByteBuffer; dest, base: Byte; offset: Integer);
begin
  WriteLdrImm(buf, dest, base, offset);
end;

// Store from source register to [base + offset]
procedure WriteStore(buf: TByteBuffer; src, base: Byte; offset: Integer);
begin
  WriteStrImm(buf, src, base, offset);
end;

function SlotOffset(slot: Integer): Integer;
begin
  Result := -(slot + 1) * 8;
end;

// ==========================================================================
// Helper: Load address from IAT (Import Address Table)
// For Windows, we use a simple approach: LDR X16, [X16, #offset]
// The offset will be patched later based on the function's position in IAT
procedure WriteLoadFromIAT(buf: TByteBuffer; destReg: Byte; iatOffset: Integer);
begin
  // LDR Xdest, [X16, #offset]
  // offset is in bytes, must be multiple of 8 for 64-bit load
  WriteLdrImm(buf, destReg, X16, iatOffset);
end;

// ==========================================================================
// TWindowsARM64Emitter Implementation
// ==========================================================================

constructor TWindowsARM64Emitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  FFuncNames := TStringList.Create;
  FGlobalVarNames := TStringList.Create;
  SetLength(FStringOffsets, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  SetLength(FLabelPositions, 0);
  SetLength(FBranchPatches, 0);
  SetLength(FFuncOffsets, 0);
  SetLength(FCallPatches, 0);
  SetLength(FGlobalVarOffsets, 0);
  SetLength(FGlobalVarLeaPatches, 0);
  FTotalDataOffset := 0;
  FRandomSeedOffset := 0;
  FRandomSeedAdded := False;
  SetLength(FRandomSeedLeaPatches, 0);
  SetLength(FExternalSymbols, 0);
  SetLength(FPLTGOTPatches, 0);
  SetLength(FWindowsAPIPatches, 0);
end;

destructor TWindowsARM64Emitter.Destroy;
begin
  FGlobalVarNames.Free;
  FFuncNames.Free;
  FData.Free;
  FCode.Free;
  inherited Destroy;
end;

function TWindowsARM64Emitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TWindowsARM64Emitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TWindowsARM64Emitter.GetFunctionOffset(const name: string): Integer;
var
  idx: Integer;
begin
  idx := FFuncNames.IndexOf(name);
  if idx >= 0 then
    Result := FFuncOffsets[idx]
  else
    Result := -1;
end;

function TWindowsARM64Emitter.GetExternalSymbols: TExternalSymbolArray;
begin
  SetLength(Result, Length(FExternalSymbols));
  Move(FExternalSymbols[0], Result[0], Length(FExternalSymbols) * SizeOf(TExternalSymbol));
end;

function TWindowsARM64Emitter.GetPLTGOTPatches: TPLTGOTPatchArray;
begin
  SetLength(Result, Length(FPLTGOTPatches));
  Move(FPLTGOTPatches[0], Result[0], Length(FPLTGOTPatches) * SizeOf(TPLTGOTPatch));
end;

procedure TWindowsARM64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  fn: TIRFunction;
  localCnt, maxTemp, slotIdx: Integer;
  totalSlots, frameSize: Integer;
  strIdx, varIdx: Integer;
  isEntryFunction: Boolean;
  
  strOffset: UInt64;
  totalDataOffset: UInt64;
  stringByteOffsets: array of UInt64;
  
  labelIdx, targetPos, patchPos: Integer;
  branchOffset: Int32;
  
  callPatchIdx, targetFuncIdx: Integer;
  
  argCount: Integer;
  argTemps: array of Integer;
  arg3: Integer;
  
  cond: Byte;
  
  dataVA, codeVA, instrVA: UInt64;
  disp: Int32;
  rd, rn: Byte;
  
  tmpReg: Byte;
  
  found: Boolean;
  ei: Integer;
begin
  // Phase 1: Write interned strings to data section
  totalDataOffset := 0;
  SetLength(stringByteOffsets, 0);
  
  if Assigned(module) then
  begin
    SetLength(stringByteOffsets, module.Strings.Count);
    for i := 0 to module.Strings.Count - 1 do
    begin
      stringByteOffsets[i] := totalDataOffset;
      for j := 1 to Length(module.Strings[i]) do
        FData.WriteU8(Byte(module.Strings[i][j]));
      FData.WriteU8(0);
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;
  
  while (FData.Size mod 8) <> 0 do
    FData.WriteU8(0);
  
  // Phase 1b: Write global variables
  for i := 0 to High(module.GlobalVars) do
  begin
    FGlobalVarNames.Add(module.GlobalVars[i].Name);
    SetLength(FGlobalVarOffsets, Length(FGlobalVarOffsets) + 1);
    FGlobalVarOffsets[High(FGlobalVarOffsets)] := FData.Size;
    
    if module.GlobalVars[i].IsArray then
    begin
      if module.GlobalVars[i].HasInitValue and (module.GlobalVars[i].ArrayLen > 0) then
      begin
        for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
          FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValues[j]));
      end
      else
      begin
        if module.GlobalVars[i].ArrayLen > 0 then
        begin
          for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
            FData.WriteU64LE(0);
        end;
      end;
    end
    else
    begin
      if module.GlobalVars[i].HasInitValue then
        FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValue))
      else
        FData.WriteU64LE(0);
    end;
  end;
  
  FTotalDataOffset := FData.Size;
  
  // Phase 2: Emit _start entry point for Windows
  // Windows uses a different entry point mechanism
  // We'll use a simple approach: call main, then call ExitProcess
  
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('_start');
  
  // _start:
  // Windows has already set up the stack, no need for explicit stack setup
  // Save LR on stack
  WriteStpPreIndex(FCode, X30, XZR, SP, -16);
  
  // Call main
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  WriteBranchLink(FCode, 0);
  
  // Restore LR
  WriteLdpPostIndex(FCode, X30, XZR, SP, 16);
  
  // X0 contains return value from main
  // Call ExitProcess(X0) - load from IAT
  // For now, we use a placeholder - the actual IAT offset would be patched
  
  // Save exit code
  WriteMovRegReg(FCode, X19, X0);  // X19 = exit code
  
  // Load ExitProcess address from IAT (placeholder - offset 0)
  // LDR X16, [X16, #0]
  WriteLdrImm(FCode, X16, X16, 0);
  
  // Move exit code to X0
  WriteMovRegReg(FCode, X0, X19);
  
  // Call ExitProcess via X16
  // BLR X16 (branch with link to address in X16)
  // BLR X16 = 0xD63F03E0
  EmitInstr(FCode, $D63F03E0);
  
  // If ExitProcess returns (shouldn't happen), loop forever
  WriteBranch(FCode, -4);
  
  // Phase 3: Builtin Stubs
  
  // PrintStr: X0 = string address
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintStr');
  
  // Calculate string length first
  WriteMovRegReg(FCode, X9, X0);
  WriteMovImm64(FCode, X2, 0);
  
  // strlen loop
  // ldrb w1, [x9, x2]
  EmitInstr(FCode, $38626921);
  // cbz w1, end
  EmitInstr(FCode, $34000061);
  // add x2, x2, #1
  WriteAddImm(FCode, X2, X2, 1);
  // b -12
  WriteBranch(FCode, -12);
  
  // Now X2 = length, X9 = address
  // Call WriteFile via IAT
  // WriteFile parameters: X0=hFile, X1=Buffer, X2=nBytes, X3=pWritten, X4=Overlapped
  // hFile = GetStdHandle(STD_OUTPUT_HANDLE) = -11
  // For simplicity, use console handle directly: X0 = -11
  WriteMovImm64(FCode, X0, UInt64(-11));  // STD_OUTPUT_HANDLE
  
  // Get pointer to GetStdHandle (placeholder)
  WriteMovImm64(FCode, X16, 0);
  // LDR X16, [X16, #0]
  WriteLdrImm(FCode, X16, X16, 0);
  // BLR X16
  EmitInstr(FCode, $D63F03E0);
  
  // Now X0 = handle
  WriteMovRegReg(FCode, X8, X0);  // Save handle in X8
  
  // WriteFile(Handle, Buffer, Length, ...)
  WriteMovRegReg(FCode, X1, X9);  // Buffer = string address
  WriteMovRegReg(FCode, X2, X2);  // Length = calculated length
  WriteMovImm64(FCode, X3, 0);    // pWritten = NULL
  WriteMovImm64(FCode, X4, 0);    // Overlapped = NULL
  
  // Load WriteFile address from IAT (placeholder)
  WriteMovImm64(FCode, X16, 0);
  WriteLdrImm(FCode, X16, X16, 0);
  // BLR X16
  EmitInstr(FCode, $D63F03E0);
  
  WriteRet(FCode);
  
  // PrintInt: X0 = integer value
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintInt');
  
  // Prologue
  WriteStpPreIndex(FCode, X29, X30, SP, -48);
  WriteMovRegReg(FCode, X29, SP);
  
  // Check sign
  WriteCmpImm(FCode, X0, 0);
  WriteCset(FCode, X11, COND_LT);
  
  // Absolute value
  // CSNEG X9, X0, X0, GE
  EmitInstr(FCode, $DA80A409);
  
  // Buffer at SP+40
  WriteAddImm(FCode, X10, SP, 40);
  WriteMovImm64(FCode, X12, 0);
  // STUR X12, [X10]
  EmitInstr(FCode, $F800001C);
  
  WriteMovImm64(FCode, X13, 10);
  
  // Digit loop
  WriteSubImm(FCode, X10, X10, 1);
  WriteUdiv(FCode, X14, X9, X13);
  WriteMsub(FCode, X12, X14, X13, X9);
  WriteAddImm(FCode, X12, X12, Ord('0'));
  // STRB W12, [X10]
  EmitInstr(FCode, $3800014C);
  WriteMovRegReg(FCode, X9, X14);
  WriteCbnz(FCode, X9, -24);
  
  // Handle negative
  WriteCbz(FCode, X11, 16);
  WriteSubImm(FCode, X10, X10, 1);
  WriteMovImm64(FCode, X12, Ord('-'));
  EmitInstr(FCode, $3800014C);
  
  // Calculate length
  WriteAddImm(FCode, X2, SP, 40);
  WriteSubRegReg(FCode, X2, X2, X10);
  
  // Write to console
  WriteMovImm64(FCode, X0, UInt64(-11));  // STD_OUTPUT_HANDLE
  // GetStdHandle call (placeholder)
  WriteMovImm64(FCode, X16, 0);
  WriteLdrImm(FCode, X16, X16, 0);
  EmitInstr(FCode, $D63F03E0);
  
  WriteMovRegReg(FCode, X8, X0);
  WriteMovRegReg(FCode, X1, X10);
  WriteMovRegReg(FCode, X2, X2);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  
  // WriteFile call (placeholder)
  WriteMovImm64(FCode, X16, 0);
  WriteLdrImm(FCode, X16, X16, 0);
  EmitInstr(FCode, $D63F03E0);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 48);
  WriteRet(FCode);
  
  // Phase 4: User functions
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];
    
    SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
    FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
    FFuncNames.Add(fn.Name);
    
    isEntryFunction := (fn.Name = 'main');
    
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
    
    frameSize := ((totalSlots * 8) + 16 + 15) and not 15;
    
    // Function prologue
    WriteStpPreIndex(FCode, X29, X30, SP, -frameSize);
    WriteMovRegReg(FCode, X29, SP);
    
    // Copy parameters
    for j := 0 to Min(fn.ParamCount - 1, 7) do
    begin
      WriteStrImm(FCode, ParamRegs[j], X29, frameSize + SlotOffset(j));
    end;
    
    SetLength(FLabelPositions, 0);
    SetLength(FBranchPatches, 0);
    
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      
      case instr.Op of
        irConstInt:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, UInt64(instr.ImmInt));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irConstStr:
          begin
            slotIdx := localCnt + instr.Dest;
            strIdx := StrToIntDef(instr.ImmStr, 0);
            SetLength(FLeaPositions, Length(FLeaPositions) + 1);
            FLeaPositions[High(FLeaPositions)] := FCode.Size;
            SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
            FLeaStrIndex[High(FLeaStrIndex)] := strIdx;
            WriteAdr(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irLoadLocal:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irStoreLocal:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(instr.Dest));
          end;
        
        irAdd:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irSub:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irMul:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteMul(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irDiv:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteSdiv(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irMod:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteSdiv(FCode, X2, X0, X1);
            WriteMsub(FCode, X0, X2, X1, X0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irNeg:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteNeg(FCode, X0, X0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpEq:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_EQ);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpNeq:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_NE);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpLt:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_LT);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpLe:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_LE);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpGt:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_GT);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irCmpGe:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            WriteCset(FCode, X0, COND_GE);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irAnd:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteAndRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irOr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteOrrRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irNot:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteCmpImm(FCode, X0, 0);
            WriteCset(FCode, X0, COND_EQ);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irLabel:
          begin
            SetLength(FLabelPositions, Length(FLabelPositions) + 1);
            FLabelPositions[High(FLabelPositions)].Name := instr.LabelName;
            FLabelPositions[High(FLabelPositions)].Pos := FCode.Size;
          end;
        
        irJmp:
          begin
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].InstrType := 0;
            WriteBranch(FCode, 0);
          end;
        
        irBrTrue, irBrFalse:
          begin
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            if instr.Op = irBrTrue then
              FBranchPatches[High(FBranchPatches)].InstrType := 3  // CBNZ
            else
              FBranchPatches[High(FBranchPatches)].InstrType := 2; // CBZ
            
            // Load the condition value
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            
            if instr.Op = irBrTrue then
              WriteCbnz(FCode, X0, 0)
            else
              WriteCbz(FCode, X0, 0);
          end;
        
        irCall:
          begin
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            // For external calls, we'd need to load from IAT
            // For now, internal calls only
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            WriteBranchLink(FCode, 0);
          end;
        
        irCallBuiltin:
          begin
            // Load parameter into X0
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            
            // Call builtin
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := '__builtin_' + instr.ImmStr;
            WriteBranchLink(FCode, 0);
            
            // Store result
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;
        
        irReturn:
          begin
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdpPostIndex(FCode, X29, X30, SP, frameSize);
            WriteRet(FCode);
          end;
        
        else
          // Unhandled - skip
          ;
      end;
    end;
  end;
  
  // Phase 5: Patch branches - simplified approach without GetBufferAt
  // We'll skip patching for now as it requires GetBufferAt which doesn't exist
  
  // Note: For a complete implementation, you would need to:
  // 1. Add GetBufferAt method to TByteBuffer
  // 2. Or use a different approach to patch instructions
  
end;

end.
