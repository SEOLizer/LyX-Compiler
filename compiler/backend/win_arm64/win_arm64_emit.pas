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
  
  // Map/Set loop variables
  loopStartPos, loopEndPos: Integer;
  branchPos1, branchPos2, branchPos3: Integer;
  notFoundPos, doneLabelPos: Integer;
  
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
  
  // Load ExitProcess from IAT
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'ExitProcess';
  WriteBranchLink(FCode, 0);
  
  // Move exit code to X0
  WriteMovRegReg(FCode, X0, X19);
  
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
  
  // GetStdHandle call
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  
  // Now X0 = handle
  WriteMovRegReg(FCode, X8, X0);  // Save handle in X8
  
  // WriteFile(Handle, Buffer, Length, ...)
  WriteMovRegReg(FCode, X1, X9);  // Buffer = string address
  WriteMovRegReg(FCode, X2, X2);  // Length = calculated length
  WriteMovImm64(FCode, X3, 0);    // pWritten = NULL
  WriteMovImm64(FCode, X4, 0);    // Overlapped = NULL
  
  // WriteFile call
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
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
  // GetStdHandle call
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  
  WriteMovRegReg(FCode, X8, X0);
  WriteMovRegReg(FCode, X1, X10);
  WriteMovRegReg(FCode, X2, X2);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  
  // WriteFile call
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 48);
  WriteRet(FCode);
  
  // PrintFloat: D0 = float value
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintFloat');
  
  // Prologue - need stack for buffer and constants
  WriteStpPreIndex(FCode, X29, X30, SP, -96);
  WriteMovRegReg(FCode, X29, SP);
  
  // Save D0 to stack [SP+80]
  EmitInstr(FCode, $FD0000A0);  // STR D0, [X29, #80]
  
  // Check sign: fcmp d0, #0.0
  // Load 0.0 into D1
  WriteMovImm64(FCode, X9, 0);
  EmitInstr(FCode, $FD000049);  // STR D0 -> need to zero D1 first
  // FCMP D0, #0.0
  EmitInstr(FCode, $1E202000);
  // B.NM handle_negative (if negative)
  // Neg block size ~60 bytes, use placeholder
  EmitU8(FCode, $54); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $04); // b.mi +8 (placeholder)
  arg3 := FCode.Size - 4;  // position of branch instruction
  
  // === Negative handling ===
  // Print '-'
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  WriteMovRegReg(FCode, X8, X0);  // Save handle
  
  // Write '-' character
  WriteMovImm64(FCode, X0, UInt64($000000000000002D));  // '-'
  EmitInstr(FCode, $F90003E0);  // STR X0, [SP]
  WriteMovRegReg(FCode, X0, X8);
  WriteAddImm(FCode, X1, SP, 0);
  WriteMovImm64(FCode, X2, 1);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Negate: D0 = -D0
  EmitInstr(FCode, $FD0000A0);  // Reload D0
  WriteMovImm64(FCode, X9, UInt64($8000000000000000));  // Sign bit mask
  EmitInstr(FCode, $FD000049);  // STR X9 as double
  EmitInstr(FCode, $FD000069);  // LDR D1, [SP+8]
  // EOR V0.8B, V0.8B, V1.8B (flip sign bit)
  EmitInstr(FCode, $4E201C00);
  EmitInstr(FCode, $FD0000A0);  // Store negated D0
  
  // Patch negative branch
  FCode.PatchU32(arg3, $54000004 or (((FCode.Size - arg3) div 4) shl 5));
  
  // === Positive path ===
  // Extract integer part: fcvtzs X9, D0
  EmitInstr(FCode, $FD0000A0);  // LDR D0
  EmitInstr(FCode, $1E6B0129);  // FCVTZS X9, D0
  
  // Print integer part via itoa loop
  // Check if zero
  WriteCmpImm(FCode, X9, 0);
  WriteCbz(FCode, X9, 24);  // Skip to decimal point if zero
  
  // Save integer value
  WriteMovRegReg(FCode, X10, X9);
  // Buffer at [SP+48..79], start from end
  WriteAddImm(FCode, X11, SP, 79);
  // Null-terminate
  WriteMovImm64(FCode, X12, 0);
  EmitInstr(FCode, $3800016C);  // STRB W12, [X11]
  
  // Divisor = 10
  WriteMovImm64(FCode, X13, 10);
  // Digit loop
  WriteSubImm(FCode, X11, X11, 1);
  WriteUdiv(FCode, X14, X10, X13);
  WriteMsub(FCode, X12, X14, X13, X10);
  WriteAddImm(FCode, X12, X12, Ord('0'));
  EmitInstr(FCode, $3800016C);  // STRB W12, [X11]
  WriteMovRegReg(FCode, X10, X14);
  WriteCbnz(FCode, X10, -24);
  
  // Calculate length and print integer part
  WriteAddImm(FCode, X2, SP, 79);
  WriteSubRegReg(FCode, X2, X2, X11);
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  WriteMovRegReg(FCode, X8, X0);
  WriteMovRegReg(FCode, X0, X8);
  WriteMovRegReg(FCode, X1, X11);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Print decimal point '.'
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  WriteMovRegReg(FCode, X8, X0);
  WriteMovImm64(FCode, X0, UInt64($000000000000002E));  // '.'
  EmitInstr(FCode, $F90003E0);
  WriteMovRegReg(FCode, X0, X8);
  WriteAddImm(FCode, X1, SP, 0);
  WriteMovImm64(FCode, X2, 1);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Print 6 decimal digits
  // fractional = (value - integer_part) * 10^6
  EmitInstr(FCode, $FD0000A0);  // LDR D0 (original/negated value)
  WriteMovImm64(FCode, X9, 0);
  EmitInstr(FCode, $FD000049);  // STR X9 as 0.0
  EmitInstr(FCode, $FD000069);  // LDR D1 = 0.0
  // FCVTZS X10, D0 (integer part)
  EmitInstr(FCode, $1E6B014A);
  // SCVTF D1, X10 (back to double)
  EmitInstr(FCode, $1E620141);
  // FSUB D2, D0, D1 (fractional part)
  EmitInstr(FCode, $1E612802);
  // Multiply by 1000000.0
  WriteMovImm64(FCode, X9, UInt64($412E848000000000));  // 1000000.0
  EmitInstr(FCode, $FD000049);
  EmitInstr(FCode, $FD000069);  // LDR D1 = 1000000.0
  // FMUL D2, D2, D1
  EmitInstr(FCode, $1E612842);
  // FCVTZS X10, D2 (6 decimal digits as integer)
  EmitInstr(FCode, $1E6B004A);
  
  // Print 6 digits with leading zeros
  // Buffer at [SP+48..53], fill from right
  WriteAddImm(FCode, X11, SP, 54);
  WriteMovImm64(FCode, X12, 0);
  EmitInstr(FCode, $3800016C);  // Null-terminate
  WriteMovImm64(FCode, X13, 10);
  
  // Loop 6 times
  WriteMovImm64(FCode, X14, 6);
  WriteSubImm(FCode, X11, X11, 1);
  WriteUdiv(FCode, X15, X10, X13);
  WriteMsub(FCode, X12, X15, X13, X10);
  WriteAddImm(FCode, X12, X12, Ord('0'));
  EmitInstr(FCode, $3800016C);
  WriteMovRegReg(FCode, X10, X15);
  WriteSubImm(FCode, X14, X14, 1);
  WriteCbnz(FCode, X14, -24);
  
  // Print 6 decimal digits
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  WriteMovRegReg(FCode, X8, X0);
  WriteMovRegReg(FCode, X0, X8);
  WriteAddImm(FCode, X1, SP, 48);
  WriteMovImm64(FCode, X2, 6);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 96);
  WriteRet(FCode);
  
  // Println: X0 = string address
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_Println');
  
  // Prologue
  WriteStpPreIndex(FCode, X29, X30, SP, -64);
  WriteMovRegReg(FCode, X29, SP);
  
  // Save string pointer
  WriteMovRegReg(FCode, X9, X0);
  
  // Calculate string length (same as PrintStr)
  WriteMovImm64(FCode, X2, 0);
  // ldrb w1, [x9, x2]
  EmitInstr(FCode, $38626921);
  // cbz w1, end
  EmitInstr(FCode, $34000061);
  // add x2, x2, #1
  WriteAddImm(FCode, X2, X2, 1);
  // b -12
  WriteBranch(FCode, -12);
  
  // Now X2 = length, X9 = address
  // GetStdHandle(STD_OUTPUT_HANDLE)
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  
  WriteMovRegReg(FCode, X8, X0);  // Save handle
  
  // WriteFile(handle, string, length, NULL, NULL)
  WriteMovRegReg(FCode, X0, X8);
  WriteMovRegReg(FCode, X1, X9);
  WriteMovRegReg(FCode, X2, X2);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Now write "\r\n" (CRLF for Windows console)
  // Store CRLF on stack at [SP+48]
  WriteMovImm64(FCode, X0, UInt64($0000000000000A0D));  // \r\n
  EmitInstr(FCode, $F9001BE0);  // STR X0, [SP+48]
  
  // GetStdHandle again
  WriteMovImm64(FCode, X0, UInt64(-11));
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
  WriteBranchLink(FCode, 0);
  
  // WriteFile(handle, "\r\n", 2, NULL, NULL)
  WriteMovRegReg(FCode, X1, SP);
  WriteAddImm(FCode, X1, X1, 48);
  WriteMovImm64(FCode, X2, 2);
  WriteMovImm64(FCode, X3, 0);
  WriteMovImm64(FCode, X4, 0);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
  WriteBranchLink(FCode, 0);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 64);
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

        irLoadGlobal:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irStoreGlobal:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Store to global address - stub
          end;

        irLoadGlobalAddr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
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
        
        // ========================================================================
        // SIMD Operations (NEON) for ParallelArray - Windows ARM64
        // ========================================================================
        
        irSIMDAdd:
          begin
            // Scalar: dest = src1 + src2
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDSub:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDMul:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteMul(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDDiv:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteSdiv(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDAnd:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteAndRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDOr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteOrrRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDXor:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteEorRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDNeg:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteNeg(FCode, X0, X0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteCmpRegReg(FCode, X0, X1);
            case instr.Op of
              irSIMDCmpEq: WriteCset(FCode, X0, COND_EQ);
              irSIMDCmpNe: WriteCset(FCode, X0, COND_NE);
              irSIMDCmpLt: WriteCset(FCode, X0, COND_LT);
              irSIMDCmpLe: WriteCset(FCode, X0, COND_LE);
              irSIMDCmpGt: WriteCset(FCode, X0, COND_GT);
              irSIMDCmpGe: WriteCset(FCode, X0, COND_GE);
            end;
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDLoadElem:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLslImm(FCode, X1, X1, 3);
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteLdrReg(FCode, X0, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSIMDStoreElem:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3));
            WriteLslImm(FCode, X1, X1, 3);
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteStrReg(FCode, X2, X0, 0);
          end;

        // === Missing IR Operations (TOR-011) ===
        irXor:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteEorRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irNor:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteOrrRegReg(FCode, X0, X0, X1);
            WriteMvnReg(FCode, X0, X0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irBitAnd:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteAndRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irBitOr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteOrrRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irBitXor:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteEorRegReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irBitNot:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteMvnReg(FCode, X0, X0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irShl:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLslReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irShr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLsrReg(FCode, X0, X0, X1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        // === Float Operations ===
        irFAdd, irFSub, irFMul, irFDiv, irFNeg:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irConstFloat:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irFToI, irIToF:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irCast:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irSExt, irZExt, irTrunc:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irLoadLocalAddr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteAddImm(FCode, X0, X29, frameSize + SlotOffset(instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irLoadStructAddr:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irCallStruct:
          begin
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            WriteBranchLink(FCode, 0);
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;

        irVarCall:
          begin
            // Virtual call via VMT
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrReg(FCode, X0, X0, 0); // VMT ptr
            WriteLdrImm(FCode, X0, X0, instr.VMTIndex * 8);
            WriteBlr(FCode, X0);
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;

        irReturnStruct:
          begin
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdpPostIndex(FCode, X29, X30, SP, 48);
            WriteRet(FCode);
          end;

        irStackAlloc:
          begin
            slotIdx := localCnt + instr.Dest;
            if instr.ImmInt > 0 then
              WriteSubImm(FCode, SP, SP, instr.ImmInt);
            WriteMovRegReg(FCode, X0, SP);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irStoreElem:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3));
            WriteLslImm(FCode, X1, X1, 3);
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteStrReg(FCode, X2, X0, 0);
          end;

        irLoadElem:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLslImm(FCode, X1, X1, 3);
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteLdrReg(FCode, X0, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irStoreElemDyn:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3));
            WriteLslImm(FCode, X1, X1, 3);
            WriteAddRegReg(FCode, X0, X0, X1);
            WriteStrReg(FCode, X2, X0, 0);
          end;

        irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irLoadField, irStoreField:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irLoadFieldHeap, irStoreFieldHeap:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irAlloc:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteMovImm64(FCode, X1, instr.ImmInt);
            WriteMovImm64(FCode, X2, $3000); // MEM_COMMIT|MEM_RESERVE
            WriteMovImm64(FCode, X3, $04);   // PAGE_READWRITE
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
            WriteBranchLink(FCode, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irFree:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteMovImm64(FCode, X1, 0);
            WriteMovImm64(FCode, X2, $8000); // MEM_RELEASE
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'VirtualFree';
            WriteBranchLink(FCode, 0);
          end;

        irLoadCaptured:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irPoolAlloc:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 0);
            WriteMovImm64(FCode, X1, instr.ImmInt);
            WriteMovImm64(FCode, X2, $3000);
            WriteMovImm64(FCode, X3, $04);
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
            WriteBranchLink(FCode, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irPoolFree:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteMovImm64(FCode, X1, 0);
            WriteMovImm64(FCode, X2, $8000);
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'VirtualFree';
            WriteBranchLink(FCode, 0);
          end;

        irPushHandler, irPopHandler, irLoadHandlerExn, irThrow:
          begin
            if instr.Dest >= 0 then
            begin
              WriteMovImm64(FCode, X0, 0);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          end;

        irPanic:
          begin
            // panic(msg): write to stderr and exit(1)
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // GetStdHandle(STD_ERROR_HANDLE = -12)
            WriteMovImm64(FCode, X0, UInt64(-12));
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'GetStdHandle';
            WriteBranchLink(FCode, 0);
            // WriteFile
            WriteMovRegReg(FCode, X8, X0);
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // strlen
            WriteMovImm64(FCode, X1, 0);
            WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            var panicLoop := FCode.Size;
            WriteLdrReg(FCode, X3, X2, 0);
            WriteCmpImm(FCode, X3, 0);
            WriteBCond(FCode, COND_EQ, 12);
            WriteAddImm(FCode, X2, X2, 1);
            WriteAddImm(FCode, X1, X1, 1);
            WriteBranch(FCode, (panicLoop - FCode.Size) div 4);
            WriteMovRegReg(FCode, X0, X8);
            WriteMovRegReg(FCode, X1, X0);
            WriteMovRegReg(FCode, X2, X1);
            WriteMovImm64(FCode, X3, 0);
            WriteMovImm64(FCode, X4, 0);
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
            WriteBranchLink(FCode, 0);
            // ExitProcess(1)
            WriteMovImm64(FCode, X0, 1);
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := 'ExitProcess';
            WriteBranchLink(FCode, 0);
          end;

        irIsType:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovImm64(FCode, X0, 1);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;

        irInspect:
          begin
            // Stub
          end;
        
        irCallBuiltin:
          begin
            // Handle specific builtins directly
            if instr.ImmStr = 'exit' then
            begin
              // exit(code: int64) -> never returns
              // Load code into X0
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Call ExitProcess
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'ExitProcess';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'PrintStr' then
            begin
              // PrintStr(s: pchar) -> void
              // Use OutputDebugStringA Windows API
              // X0 = string pointer
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Call OutputDebugStringA
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'OutputDebugStringA';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'PrintInt' then
            begin
              // PrintInt(n: int64) -> void
              // Call __builtin_PrintInt function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintInt';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'PrintFloat' then
            begin
              // PrintFloat(f: f64) -> void
              // Call __builtin_PrintFloat function
              // Note: For now, just print as integer part with 6 decimal places
              // This is a placeholder - full float formatting requires more work
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintFloat';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'open' then
            begin
              // open(path, flags, mode) -> int64 (handle)
              // Use CreateFileA Windows API
              // Parameters: X0=path, X1=access, X2=share, X3=security, X4=disposition, X5=flags
              // Load parameters from stack
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Default access = GENERIC_READ | GENERIC_WRITE = 0xC0000000
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, UInt64($C0000000));
              // Share mode = FILE_SHARE_READ | FILE_SHARE_WRITE = 3
              WriteMovImm64(FCode, X2, 3);
              // Security = NULL
              WriteMovImm64(FCode, X3, 0);
              // Disposition = OPEN_EXISTING = 3
              WriteMovImm64(FCode, X4, 3);
              // Flags = FILE_ATTRIBUTE_NORMAL = 0x80
              WriteMovImm64(FCode, X5, UInt64($80));
              // Call CreateFileA
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'CreateFileA';
              WriteBranchLink(FCode, 0);
              // Return handle in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'read' then
            begin
              // read(handle, buffer, bytes) -> int64
              // Use ReadFile Windows API
              // Parameters: X0=handle, X1=buffer, X2=bytes
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // pBytesRead = NULL
              WriteMovImm64(FCode, X3, 0);
              // Overlapped = NULL
              WriteMovImm64(FCode, X4, 0);
              // Call ReadFile
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'ReadFile';
              WriteBranchLink(FCode, 0);
              // Return bytes read in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'write' then
            begin
              // write(handle, buffer, bytes) -> int64
              // Use WriteFile Windows API
              // Parameters: X0=handle, X1=buffer, X2=bytes
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // pBytesWritten = NULL
              WriteMovImm64(FCode, X3, 0);
              // Overlapped = NULL
              WriteMovImm64(FCode, X4, 0);
              // Call WriteFile
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'WriteFile';
              WriteBranchLink(FCode, 0);
              // Return bytes written in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'close' then
            begin
              // close(handle) -> int64
              // Use CloseHandle Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Call CloseHandle
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'CloseHandle';
              WriteBranchLink(FCode, 0);
              // Return value in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'mmap' then
            begin
              // mmap(size, prot, flags) -> pointer
              // Use VirtualAlloc Windows API
              // Parameters: X0=lpAddress, X1=dwSize, X2=flAllocationType, X3=flProtect
              // lpAddress = NULL (0) - let system choose address
              WriteMovImm64(FCode, X0, 0);
              // dwSize = size from Src1
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X1, 4096); // Default 4KB page
              // flAllocationType = MEM_COMMIT | MEM_RESERVE = 0x3000
              WriteMovImm64(FCode, X2, UInt64($3000));
              // flProtect = PAGE_READWRITE = 0x04
              WriteMovImm64(FCode, X3, UInt64($04));
              // Call VirtualAlloc
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              // Return pointer in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'munmap' then
            begin
              // munmap(addr, size) -> int64
              // Use VirtualFree Windows API
              // Parameters: X0=lpAddress, X1=dwSize, X2=dwFreeType
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // dwFreeType = MEM_RELEASE = 0x8000
              WriteMovImm64(FCode, X2, UInt64($8000));
              // Call VirtualFree
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualFree';
              WriteBranchLink(FCode, 0);
              // Return result in X0 (non-zero = success)
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrLen' then
            begin
              // StrLen - use Windows lstrlenA
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Call lstrlenA
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'lstrlenA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'GetLastError' then
            begin
              // GetLastError - useful for debugging
              // Call GetLastError
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetLastError';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrCharAt' then
            begin
              // StrCharAt(s, index) -> char
              // Load string pointer and index, return byte at offset
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // LDRB W0, [X0, X1]
              EmitInstr(FCode, $38616800);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrSetChar' then
            begin
              // StrSetChar(s, index, ch) -> void
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // STRB W2, [X0, X1]
              EmitInstr(FCode, $38216842);
            end
            else if instr.ImmStr = 'StrNew' then
            begin
              // StrNew(capacity) -> pointer
              // Use VirtualAlloc
              WriteMovImm64(FCode, X0, 0);
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X1, 64);
              WriteMovImm64(FCode, X2, UInt64($3000));  // MEM_COMMIT | MEM_RESERVE
              WriteMovImm64(FCode, X3, UInt64($04));    // PAGE_READWRITE
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrFree' then
            begin
              // StrFree(ptr) -> void
              // Use VirtualFree
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              WriteMovImm64(FCode, X1, 0);
              WriteMovImm64(FCode, X2, UInt64($8000));  // MEM_RELEASE
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualFree';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'StrFromInt' then
            begin
              // StrFromInt(n) -> pchar
              // Allocate buffer, convert int to string, return pointer
              // Allocate 32 bytes via VirtualAlloc
              WriteMovImm64(FCode, X0, 0);
              WriteMovImm64(FCode, X1, 32);
              WriteMovImm64(FCode, X2, UInt64($3000));
              WriteMovImm64(FCode, X3, UInt64($04));
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              // Save buffer pointer in X10
              WriteMovRegReg(FCode, X10, X0);
              // Load value to convert
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X9, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X9, 0);
              // itoa: divide by 10, store remainders
              WriteMovRegReg(FCode, X11, X9);  // Save original value for sign check
              // Check if negative
              WriteCmpImm(FCode, X9, 0);
              // CSNEG X9, X9, X9, GE (absolute value)
              EmitInstr(FCode, $DA80A529);
              // Buffer position at end (X10 + 30)
              WriteAddImm(FCode, X12, X10, 30);
              // Null-terminate
              WriteMovImm64(FCode, X13, 0);
              EmitInstr(FCode, $3800018D);  // STRB W13, [X12]
              // Divisor = 10
              WriteMovImm64(FCode, X14, 10);
              // Digit loop
              WriteSubImm(FCode, X12, X12, 1);
              WriteUdiv(FCode, X15, X9, X14);
              WriteMsub(FCode, X13, X15, X14, X9);
              WriteAddImm(FCode, X13, X13, Ord('0'));
              EmitInstr(FCode, $3800018D);  // STRB W13, [X12]
              WriteMovRegReg(FCode, X9, X15);
              WriteCbnz(FCode, X9, -24);
              // Handle negative
              WriteCbz(FCode, X11, 16);
              WriteSubImm(FCode, X12, X12, 1);
              WriteMovImm64(FCode, X13, Ord('-'));
              EmitInstr(FCode, $3800018D);
              // Return buffer pointer
              WriteMovRegReg(FCode, X0, X10);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrAppend' then
            begin
              // StrAppend(dest, src) -> pchar
              // Just return dest for now (simple stub)
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrFindChar' then
            begin
              // StrFindChar(s, ch, start) -> int64 (index or -1)
              // Linear search from start position
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              
              // X0 = string, X1 = char, X2 = start index
              // X3 = current position (X0 + X2)
              WriteAddReg(FCode, X3, X0, X2);
              // X4 = current index = X2
              WriteMovRegReg(FCode, X4, X2);
              
              // Search loop
              var searchLoop := FCode.Size;
              // LDRB W5, [X3] - load current byte
              EmitInstr(FCode, $39400065);
              // CBZ W5, not_found (end of string)
              var cbzPos := FCode.Size;
              EmitInstr(FCode, $34000005);  // placeholder
              // CMP W5, W1 - compare with search char
              EmitInstr(FCode, $6B0100BF);
              // B.EQ found
              var beqPos := FCode.Size;
              EmitInstr(FCode, $54000000);  // placeholder
              
              // X3++, X4++
              WriteAddImm(FCode, X3, X3, 1);
              WriteAddImm(FCode, X4, X4, 1);
              // b search_loop
              WriteBranch(FCode, (searchLoop - FCode.Size) div 4);
              
              // found: X0 = X4
              var foundPos := FCode.Size;
              WriteMovRegReg(FCode, X0, X4);
              var skipNotFound := FCode.Size;
              WriteBranch(FCode, 0);  // b done
              
              // not_found: X0 = -1
              var notFoundPos := FCode.Size;
              WriteMovImm64(FCode, X0, UInt64(-1));
              
              // done:
              var donePos := FCode.Size;
              // Patch CBZ
              FCode.PatchU32(cbzPos, $34000005 or (((notFoundPos - cbzPos) div 4) shl 5));
              // Patch BEQ
              FCode.PatchU32(beqPos, $54000000 or (((foundPos - beqPos) div 4) shl 5));
              // Patch skip
              FCode.PatchU32(skipNotFound, $14000000 or (((donePos - skipNotFound) div 4)));
              
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrSub' then
            begin
              // StrSub(s, start, len) -> pchar
              // Allocate new buffer and copy substring
              WriteMovImm64(FCode, X0, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X1, 64);
              WriteMovImm64(FCode, X2, UInt64($3000));
              WriteMovImm64(FCode, X3, UInt64($04));
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              // Return new buffer (content not copied - stub)
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrConcat' then
            begin
              // StrConcat(a, b) -> pchar
              // Allocate buffer, copy a, copy b
              WriteMovImm64(FCode, X0, 0);
              WriteMovImm64(FCode, X1, 256);
              WriteMovImm64(FCode, X2, UInt64($3000));
              WriteMovImm64(FCode, X3, UInt64($04));
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              // Return buffer (content not copied - stub)
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrCopy' then
            begin
              // StrCopy(s) -> pchar
              // Allocate and copy
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // Get length via lstrlenA
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'lstrlenA';
              WriteBranchLink(FCode, 0);
              // X0 = length, allocate len+1
              WriteAddImm(FCode, X1, X0, 1);
              WriteMovImm64(FCode, X0, 0);
              WriteMovImm64(FCode, X2, UInt64($3000));
              WriteMovImm64(FCode, X3, UInt64($04));
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'VirtualAlloc';
              WriteBranchLink(FCode, 0);
              // Return buffer (content not copied - stub)
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'FileGetSize' then
            begin
              // FileGetSize(path) -> int64
              // Use CreateFileA + GetFileSizeEx + CloseHandle
              // X0 = path
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // CreateFileA: GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING
              WriteMovImm64(FCode, X1, UInt64($80000000));  // GENERIC_READ
              WriteMovImm64(FCode, X2, 1);                   // FILE_SHARE_READ
              WriteMovImm64(FCode, X3, 0);                   // Security = NULL
              WriteMovImm64(FCode, X4, 3);                   // OPEN_EXISTING
              WriteMovImm64(FCode, X5, UInt64($80));         // FILE_ATTRIBUTE_NORMAL
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'CreateFileA';
              WriteBranchLink(FCode, 0);
              
              // Check if handle is valid (not INVALID_HANDLE_VALUE)
              WriteMovImm64(FCode, X1, UInt64($FFFFFFFFFFFFFFFF));
              WriteCmpReg(FCode, X0, X1);
              WriteCbz(FCode, X0, 48);  // If invalid, jump to return 0
              
              // Save handle
              WriteMovRegReg(FCode, X9, X0);
              
              // GetFileSizeEx(handle, &size)
              WriteMovRegReg(FCode, X0, X9);
              // Allocate 8 bytes on stack for size
              WriteSubImm(FCode, SP, SP, 16);
              WriteMovRegReg(FCode, X1, SP);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetFileSizeEx';
              WriteBranchLink(FCode, 0);
              
              // Load size value
              WriteLdrImm(FCode, X0, SP, 0);
              
              // CloseHandle
              WriteMovRegReg(FCode, X0, X9);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'CloseHandle';
              WriteBranchLink(FCode, 0);
              
              // Restore stack
              WriteAddImm(FCode, SP, SP, 16);
              
              // Return size in X0
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrStartsWith' then
            begin
              // StrStartsWith(s, prefix) -> bool
              // Compare byte by byte until prefix null terminator
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              
              // Loop: compare bytes
              WriteMovImm64(FCode, X2, 1);  // result = true
              WriteMovImm64(FCode, X3, 0);  // index
              
              // Loop start
              var loopStart := FCode.Size;
              // LDRB W4, [X1, X3] - load prefix byte
              EmitInstr(FCode, $38636824);
              // CBZ W4, done (prefix end = match)
              var cbzPos := FCode.Size;
              EmitInstr(FCode, $34000004);  // placeholder
              
              // LDRB W5, [X0, X3] - load string byte
              EmitInstr(FCode, $38636805);
              // CMP W4, W5
              EmitInstr(FCode, $6B05009F);
              // B.NE not_match
              var bnePos := FCode.Size;
              EmitInstr(FCode, $54000001);  // placeholder
              
              // index++
              WriteAddImm(FCode, X3, X3, 1);
              // b loop
              WriteBranch(FCode, (loopStart - FCode.Size) div 4);
              
              // not_match:
              var notMatchPos := FCode.Size;
              WriteMovImm64(FCode, X2, 0);  // result = false
              
              // done:
              var donePos := FCode.Size;
              // Patch CBZ
              FCode.PatchU32(cbzPos, $34000004 or (((donePos - cbzPos) div 4) shl 5));
              // Patch B.NE
              FCode.PatchU32(bnePos, $54000001 or (((notMatchPos - bnePos) div 4) shl 5));
              
              WriteMovRegReg(FCode, X0, X2);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrEndsWith' then
            begin
              // StrEndsWith(s, suffix) -> bool
              // Get lengths of both strings, compare from end
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              
              // Get string length (X0)
              WriteMovRegReg(FCode, X9, X0);
              WriteMovImm64(FCode, X2, 0);
              var lenLoop1 := FCode.Size;
              EmitInstr(FCode, $38626923);  // ldrb w3, [x9, x2]
              EmitInstr(FCode, $34000063);  // cbz w3, +0
              var cbz1Pos := FCode.Size;
              WriteAddImm(FCode, X2, X2, 1);
              WriteBranch(FCode, -12);
              var len1Done := FCode.Size;
              FCode.PatchU32(cbz1Pos, $34000003 or (((len1Done - cbz1Pos) div 4) shl 5));
              WriteMovRegReg(FCode, X3, X2);  // X3 = len(s)
              
              // Get prefix length (X1)
              WriteMovRegReg(FCode, X9, X1);
              WriteMovImm64(FCode, X2, 0);
              var lenLoop2 := FCode.Size;
              EmitInstr(FCode, $38626924);
              EmitInstr(FCode, $34000064);
              var cbz2Pos := FCode.Size;
              WriteAddImm(FCode, X2, X2, 1);
              WriteBranch(FCode, -12);
              var len2Done := FCode.Size;
              FCode.PatchU32(cbz2Pos, $34000004 or (((len2Done - cbz2Pos) div 4) shl 5));
              WriteMovRegReg(FCode, X4, X2);  // X4 = len(prefix)
              
              // If prefix longer than string, return false
              WriteCmpReg(FCode, X4, X3);
              var bgtPos := FCode.Size;
              WriteBranchCond(FCode, $0A, 0);  // b.gt not_match
              
              // Compare from end: offset = len(s) - len(prefix)
              WriteSubRegReg(FCode, X5, X3, X4);  // X5 = start offset in s
              WriteMovImm64(FCode, X6, 0);  // index in prefix
              
              var cmpLoop := FCode.Size;
              // LDRB W7, [X1, X6] - prefix byte
              EmitInstr(FCode, $38666827);
              EmitInstr(FCode, $34000067);  // cbz w7, match (prefix end)
              var cbz3Pos := FCode.Size;
              // LDRB W8, [X0, X5] - string byte
              EmitInstr(FCode, $38656808);
              EmitInstr(FCode, $6B0800FF);  // cmp w7, w8
              var bne2Pos := FCode.Size;
              WriteBranchCond(FCode, $01, 0);  // b.ne not_match
              
              WriteAddImm(FCode, X5, X5, 1);
              WriteAddImm(FCode, X6, X6, 1);
              WriteBranch(FCode, (cmpLoop - FCode.Size) div 4);
              
              // match:
              var matchPos := FCode.Size;
              WriteMovImm64(FCode, X0, 1);
              var skipNotMatch := FCode.Size;
              WriteBranch(FCode, 0);  // b done
              
              // not_match:
              var notMatchPos2 := FCode.Size;
              FCode.PatchU32(bgtPos, $5400000A or (((notMatchPos2 - bgtPos) div 4) shl 5));
              FCode.PatchU32(bne2Pos, $54000001 or (((notMatchPos2 - bne2Pos) div 4) shl 5));
              WriteMovImm64(FCode, X0, 0);
              
              // done:
              var donePos2 := FCode.Size;
              FCode.PatchU32(cbz3Pos, $34000007 or (((matchPos - cbz3Pos) div 4) shl 5));
              FCode.PatchU32(skipNotMatch, $14000000 or (((donePos2 - skipNotMatch) div 4)));
              
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'StrEquals' then
            begin
              // StrEquals(a, b) -> bool
              // Use lstrcmpA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // Call lstrcmpA - returns 0 if equal
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'lstrcmpA';
              WriteBranchLink(FCode, 0);
              // X0 = 0 means equal -> result = (X0 == 0)
              WriteCmpImm(FCode, X0, 0);
              WriteCset(FCode, X0, COND_EQ);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'GetArgC' then
            begin
              // GetArgC() -> int64
              // Use GetCommandLineA and count arguments
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetCommandLineA';
              WriteBranchLink(FCode, 0);
              
              // X0 = command line string
              // Parse: skip whitespace, count words
              WriteMovRegReg(FCode, X9, X0);  // Save cmdline pointer
              WriteMovImm64(FCode, X10, 0);   // arg count
              WriteMovImm64(FCode, X11, 1);   // state: 1 = in whitespace
              
              var parseLoop := FCode.Size;
              // LDRB W12, [X9]
              EmitInstr(FCode, $3940012C);
              // CBZ W12, parse_done
              var cbzParsePos := FCode.Size;
              EmitInstr(FCode, $3400000C);  // placeholder
              
              // CMP W12, #32 (space)
              EmitInstr(FCode, $7100819F);
              // B.EQ is_space
              var beqSpacePos := FCode.Size;
              EmitInstr(FCode, $54000000);  // placeholder
              
              // Not space: if in_whitespace, increment count
              WriteCbz(FCode, X11, 8);  // if not in_whitespace, skip
              WriteAddImm(FCode, X10, X10, 1);
              WriteMovImm64(FCode, X11, 0);  // in_whitespace = false
              var skipSpace := FCode.Size;
              WriteBranch(FCode, 0);  // b next
              
              // is_space:
              var isSpacePos := FCode.Size;
              WriteMovImm64(FCode, X11, 1);  // in_whitespace = true
              
              // next:
              var nextPos := FCode.Size;
              FCode.PatchU32(skipSpace, $14000000 or (((nextPos - skipSpace) div 4)));
              FCode.PatchU32(beqSpacePos, $54000000 or (((isSpacePos - beqSpacePos) div 4) shl 5));
              WriteAddImm(FCode, X9, X9, 1);
              WriteBranch(FCode, (parseLoop - FCode.Size) div 4);
              
              // parse_done:
              var parseDonePos := FCode.Size;
              FCode.PatchU32(cbzParsePos, $3400000C or (((parseDonePos - cbzParsePos) div 4) shl 5));
              
              // If count is 0, return 1 (at least program name)
              WriteCmpImm(FCode, X10, 0);
              WriteCset(FCode, X0, COND_NE);
              WriteAddImm(FCode, X0, X0, 1);  // +1 for program name
              
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'GetArg' then
            begin
              // GetArg(i) -> pchar
              // Returns pointer to i-th argument in command line
              // This is a simplified implementation
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              
              // Get command line
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetCommandLineA';
              WriteBranchLink(FCode, 0);
              
              // X0 = cmdline, X1 = target index
              WriteMovRegReg(FCode, X9, X0);  // Save cmdline
              WriteMovImm64(FCode, X10, 0);   // current arg index
              WriteMovImm64(FCode, X11, 1);   // in_whitespace
              WriteMovRegReg(FCode, X12, X1); // Save target index
              
              var argLoop := FCode.Size;
              // LDRB W13, [X9]
              EmitInstr(FCode, $3940012D);
              // CBZ W13, arg_not_found (end of string)
              var cbzArgPos := FCode.Size;
              EmitInstr(FCode, $3400000D);  // placeholder
              
              // CMP W13, #32
              EmitInstr(FCode, $710081BF);
              // B.EQ arg_is_space
              var beqArgSpacePos := FCode.Size;
              EmitInstr(FCode, $54000000);  // placeholder
              
              // Not space: if transitioning from whitespace, check index
              WriteCbz(FCode, X11, 16);  // if not in_whitespace, skip
              WriteAddImm(FCode, X10, X10, 1);
              WriteMovImm64(FCode, X11, 0);
              // Check if this is the target arg
              WriteCmpReg(FCode, X10, X12);
              var bneTargetPos := FCode.Size;
              WriteBranchCond(FCode, $01, 0);  // b.ne skip_found
              
              // Found! Return X9 (current position)
              WriteMovRegReg(FCode, X0, X9);
              var skipNotFound := FCode.Size;
              WriteBranch(FCode, 0);  // b arg_done
              
              var skipFoundPos := FCode.Size;
              FCode.PatchU32(bneTargetPos, $54000001 or (((skipFoundPos - bneTargetPos) div 4) shl 5));
              var skipNext := FCode.Size;
              WriteBranch(FCode, 0);  // b arg_next
              
              // arg_is_space:
              var argSpacePos := FCode.Size;
              WriteMovImm64(FCode, X11, 1);
              
              // arg_next:
              var argNextPos := FCode.Size;
              FCode.PatchU32(skipNext, $14000000 or (((argNextPos - skipNext) div 4)));
              WriteAddImm(FCode, X9, X9, 1);
              WriteBranch(FCode, (argLoop - FCode.Size) div 4);
              
              // arg_not_found:
              var argNotFoundPos := FCode.Size;
              FCode.PatchU32(cbzArgPos, $3400000D or (((argNotFoundPos - cbzArgPos) div 4) shl 5));
              WriteMovImm64(FCode, X0, 0);  // Return NULL
              
              // arg_done:
              var argDonePos := FCode.Size;
              FCode.PatchU32(beqArgSpacePos, $54000000 or (((argSpacePos - beqArgSpacePos) div 4) shl 5));
              FCode.PatchU32(skipNotFound, $14000000 or (((argDonePos - skipNotFound) div 4)));
              
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'Random' then
            begin
              // Random() -> int64: Linear Congruential Generator
              // seed = (seed * 1103515245 + 12345) mod 2^31
              // Uses global seed stored in data section
              if not FRandomSeedAdded then
              begin
                FRandomSeedOffset := FData.Size;
                FData.WriteU64LE(1); // Initial seed = 1
                FRandomSeedAdded := True;
              end;
              
              // Load seed address via ADRP+ADD
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := -2; // Special: random seed
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := True;
              WriteAdrp(FCode, X1, 0);  // Placeholder
              
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := -2;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := False;
              WriteAddImm(FCode, X1, X1, 0);  // Placeholder
              
              // LDR X0, [X1] - load current seed
              WriteLdrImm(FCode, X0, X1, 0);
              
              // Compute: X0 = X0 * 1103515245 + 12345
              WriteMovImm64(FCode, X2, 1103515245);
              WriteMul(FCode, X0, X0, X2);
              WriteMovImm64(FCode, X2, 12345);
              WriteAddRegReg(FCode, X0, X0, X2);
              
              // AND X0, X0, 0x7FFFFFFF (mod 2^31)
              WriteMovImm64(FCode, X2, $7FFFFFFF);
              WriteAndRegReg(FCode, X0, X0, X2);
              
              // Store seed back: STR X0, [X1]
              WriteStrImm(FCode, X0, X1, 0);
              
              // Store result in dest temp
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'RandomSeed' then
            begin
              // RandomSeed(seed) -> void: sets the random seed
              if not FRandomSeedAdded then
              begin
                FRandomSeedOffset := FData.Size;
                FData.WriteU64LE(1);
                FRandomSeedAdded := True;
              end;
              
              // Load seed address via ADRP+ADD
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := -2;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := True;
              WriteAdrp(FCode, X1, 0);
              
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := -2;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := False;
              WriteAddImm(FCode, X1, X1, 0);
              
              // Load seed value from Src1
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 1);
              
              // STR X0, [X1] - store new seed
              WriteStrImm(FCode, X0, X1, 0);
            end
            else if instr.ImmStr = 'getpid' then
            begin
              // getpid() -> int64
              // Use GetCurrentProcessId Windows API
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetCurrentProcessId';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'ioctl' then
            begin
              // ioctl(fd, request, arg) -> int64
              // Use DeviceIoControl Windows API
              // Stub: return 0
              WriteMovImm64(FCode, X0, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'peek8' then
            begin
              // peek8(addr) -> int64
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // LDRB W0, [X0]
              EmitInstr(FCode, $39400000);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'peek16' then
            begin
              // peek16(addr) -> int64
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // LDRH W0, [X0]
              EmitInstr(FCode, $79400000);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'peek32' then
            begin
              // peek32(addr) -> int64
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // LDR W0, [X0]
              EmitInstr(FCode, $B9400000);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'peek64' then
            begin
              // peek64(addr) -> int64
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // LDR X0, [X0]
              EmitInstr(FCode, $F9400000);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'poke8' then
            begin
              // poke8(addr, value) -> void
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // STRB W1, [X0]
              EmitInstr(FCode, $38000001);
            end
            else if instr.ImmStr = 'poke16' then
            begin
              // poke16(addr, value) -> void
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // STRH W1, [X0]
              EmitInstr(FCode, $78000001);
            end
            else if instr.ImmStr = 'poke32' then
            begin
              // poke32(addr, value) -> void
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // STR W1, [X0]
              EmitInstr(FCode, $B8000001);
            end
            else if instr.ImmStr = 'poke64' then
            begin
              // poke64(addr, value) -> void
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // STR X1, [X0]
              EmitInstr(FCode, $F8000001);
            end
            else if instr.ImmStr = 'lseek' then
            begin
              // lseek(handle, offset, whence) -> int64
              // Use SetFilePointerEx Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // lpDistanceToMoveHigh = NULL
              WriteMovImm64(FCode, X2, 0);
              // lpNewFilePointer = NULL
              WriteMovImm64(FCode, X3, 0);
              // dwMoveMethod = whence
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X4, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X4, 0);
              // Call SetFilePointerEx
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'SetFilePointerEx';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'unlink' then
            begin
              // unlink(path) -> int64
              // Use DeleteFileA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'DeleteFileA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'mkdir' then
            begin
              // mkdir(path, mode) -> int64
              // Use CreateDirectoryA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              // lpSecurityAttributes = NULL
              WriteMovImm64(FCode, X1, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'CreateDirectoryA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'rmdir' then
            begin
              // rmdir(path) -> int64
              // Use RemoveDirectoryA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'RemoveDirectoryA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'chmod' then
            begin
              // chmod(path, mode) -> int64
              // Use SetFileAttributesA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'SetFileAttributesA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'rename' then
            begin
              // rename(oldPath, newPath) -> int64
              // Use MoveFileA Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'MoveFileA';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sleep_ms' then
            begin
              // sleep_ms(ms) -> void
              // Use Sleep Windows API
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'Sleep';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'now_unix' then
            begin
              // now_unix() -> int64 (seconds since 1970-01-01 00:00:00 UTC)
              // Use GetSystemTimeAsFileTime Windows API
              // FILETIME is 100-nanosecond intervals since 1601-01-01
              // Unix epoch offset: 11644473600 seconds = 116444736000000000 * 100ns
              
              // Allocate 8 bytes on stack for FILETIME
              WriteSubImm(FCode, SP, SP, 16);
              WriteMovRegReg(FCode, X0, SP);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetSystemTimeAsFileTime';
              WriteBranchLink(FCode, 0);
              
              // Load FILETIME value (64-bit)
              WriteLdrImm(FCode, X0, SP, 0);
              
              // Subtract Unix epoch offset: 116444736000000000 (0x19DB1DED53E8000)
              WriteMovImm64(FCode, X1, UInt64($19DB1DED53E8000));
              WriteSubRegReg(FCode, X0, X0, X1);
              
              // Divide by 10000000 to convert 100ns intervals to seconds
              WriteMovImm64(FCode, X1, 10000000);
              WriteUdiv(FCode, X0, X0, X1);
              
              // Restore stack
              WriteAddImm(FCode, SP, SP, 16);
              
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'now_unix_ms' then
            begin
              // now_unix_ms() -> int64
              // Use GetTickCount64 Windows API
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'GetTickCount64';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'Println' then
            begin
              // Println(s: pchar) -> void
              // Print string + newline
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_Println';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'printf' then
            begin
              // printf(format, ...) -> void
              // Stub: just return for now
            end
            else if instr.ImmStr = 'sys_socket' then
            begin
              // sys_socket(domain, type, protocol) -> SOCKET (int64)
              // Use WinSock2 socket() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 2);  // AF_INET
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 1);  // SOCK_STREAM
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 6);  // IPPROTO_TCP
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'socket';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_bind' then
            begin
              // sys_bind(sockfd, addr, addrlen) -> int64
              // Use WinSock2 bind() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 16);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'bind';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_listen' then
            begin
              // sys_listen(sockfd, backlog) -> int64
              // Use WinSock2 listen() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 128);  // SOMAXCONN
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'listen';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_accept' then
            begin
              // sys_accept(sockfd, addr, addrlen) -> SOCKET (int64)
              // Use WinSock2 accept() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'accept';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_connect' then
            begin
              // sys_connect(sockfd, addr, addrlen) -> int64
              // Use WinSock2 connect() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 16);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'connect';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_recvfrom' then
            begin
              // sys_recvfrom(sockfd, buf, len, flags, addr, addrlen) -> int64
              // Use WinSock2 recvfrom() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // flags from ArgTemps[0]
              if Length(instr.ArgTemps) >= 1 then
                WriteLdrImm(FCode, X3, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[0]))
              else
                WriteMovImm64(FCode, X3, 0);
              // addr from ArgTemps[1]
              if Length(instr.ArgTemps) >= 2 then
                WriteLdrImm(FCode, X4, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[1]))
              else
                WriteMovImm64(FCode, X4, 0);
              // addrlen from ArgTemps[2]
              if Length(instr.ArgTemps) >= 3 then
                WriteLdrImm(FCode, X5, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[2]))
              else
                WriteMovImm64(FCode, X5, 0);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'recvfrom';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_sendto' then
            begin
              // sys_sendto(sockfd, buf, len, flags, addr, addrlen) -> int64
              // Use WinSock2 sendto() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // flags from ArgTemps[0]
              if Length(instr.ArgTemps) >= 1 then
                WriteLdrImm(FCode, X3, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[0]))
              else
                WriteMovImm64(FCode, X3, 0);
              // addr from ArgTemps[1]
              if Length(instr.ArgTemps) >= 2 then
                WriteLdrImm(FCode, X4, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[1]))
              else
                WriteMovImm64(FCode, X4, 0);
              // addrlen from ArgTemps[2]
              if Length(instr.ArgTemps) >= 3 then
                WriteLdrImm(FCode, X5, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[2]))
              else
                WriteMovImm64(FCode, X5, 16);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'sendto';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_setsockopt' then
            begin
              // sys_setsockopt(sockfd, level, optname, optval, optlen) -> int64
              // Use WinSock2 setsockopt() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0xFFFF);  // SOL_SOCKET
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // optval from ArgTemps[0]
              if Length(instr.ArgTemps) >= 1 then
                WriteLdrImm(FCode, X3, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[0]))
              else
                WriteMovImm64(FCode, X3, 0);
              // optlen from ArgTemps[1]
              if Length(instr.ArgTemps) >= 2 then
                WriteLdrImm(FCode, X4, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[1]))
              else
                WriteMovImm64(FCode, X4, 4);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'setsockopt';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_getsockopt' then
            begin
              // sys_getsockopt(sockfd, level, optname, optval, optlen) -> int64
              // Use WinSock2 getsockopt() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0xFFFF);  // SOL_SOCKET
              if instr.Src3 >= 0 then
                WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3))
              else
                WriteMovImm64(FCode, X2, 0);
              // optval from ArgTemps[0]
              if Length(instr.ArgTemps) >= 1 then
                WriteLdrImm(FCode, X3, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[0]))
              else
                WriteMovImm64(FCode, X3, 0);
              // optlen from ArgTemps[1]
              if Length(instr.ArgTemps) >= 2 then
                WriteLdrImm(FCode, X4, X29, frameSize + SlotOffset(localCnt + instr.ArgTemps[1]))
              else
                WriteMovImm64(FCode, X4, 4);
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'getsockopt';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_shutdown' then
            begin
              // sys_shutdown(sockfd, how) -> int64
              // Use WinSock2 shutdown() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 2);  // SD_BOTH
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'shutdown';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'sys_closesocket' then
            begin
              // sys_closesocket(sockfd) -> int64
              // Use WinSock2 closesocket() function
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, UInt64(-1));
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'closesocket';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'WSAStartup' then
            begin
              // WSAStartup(version, data) -> int64
              // Initialize WinSock2
              if instr.Src1 >= 0 then
                WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, $0202);  // Version 2.2
              if instr.Src2 >= 0 then
                WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2))
              else
                WriteSubImm(FCode, SP, SP, 400);  // Allocate WSADATA on stack
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := 'WSAStartup';
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else
            begin
              // Unknown builtin - call as __builtin_<name>
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_' + instr.ImmStr;
              WriteBranchLink(FCode, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
        
        irFuncExit:
          begin
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdpPostIndex(FCode, X29, X30, SP, frameSize);
            WriteRet(FCode);
          end;

        // === Map/Set Operations (Windows ARM64) ===
        // Map structure: [len:8][cap:8][entries:16*cap], Entry: [key:8][value:8]
        irMapNew, irSetNew:
          begin
            // Windows ARM64: Use VirtualAlloc - simplified stack allocation for now
            // Allocate 144 bytes on stack
            WriteSubImm(FCode, SP, SP, 144);
            WriteMovRegReg(FCode, X0, SP);
            // Store pointer
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            // Initialize len=0, cap=8
            WriteMovImm64(FCode, X1, 0);
            WriteStrImm(FCode, X1, X0, 0);
            WriteMovImm64(FCode, X1, 8);
            WriteStrImm(FCode, X1, X0, 8);
          end;

        irMapSet:
          begin
            // map_set: Linear search, update or append
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3));
            WriteLdrImm(FCode, X3, X0, 0);  // len
            WriteMovImm64(FCode, X4, 0);    // counter
            WriteAddImm(FCode, X5, X0, 16); // first entry
            loopStartPos := FCode.Size;
            WriteCmpReg(FCode, X4, X3);
            branchPos1 := FCode.Size;
            WriteBranchCond(FCode, $0A, 0); // b.ge notFound
            WriteLdrImm(FCode, X6, X5, 0);
            WriteCmpReg(FCode, X6, X1);
            branchPos2 := FCode.Size;
            WriteBranchCond(FCode, $01, 0); // b.ne next
            WriteStrImm(FCode, X2, X5, 8);  // found: update
            branchPos3 := FCode.Size;
            WriteBranch(FCode, 0);          // b done
            notFoundPos := FCode.Size;
            FCode.PatchU32(branchPos2, ((notFoundPos - branchPos2) div 4) shl 5 or $54000001);
            WriteAddImm(FCode, X5, X5, 16);
            WriteAddImm(FCode, X4, X4, 1);
            WriteBranch(FCode, (loopStartPos - FCode.Size) div 4);
            doneLabelPos := FCode.Size;
            FCode.PatchU32(branchPos1, ((doneLabelPos - branchPos1) div 4) shl 5 or $5400000A);
            // Append new entry
            WriteLslImm(FCode, X6, X3, 4);
            WriteAddReg(FCode, X5, X0, X6);
            WriteAddImm(FCode, X5, X5, 16);
            WriteStrImm(FCode, X1, X5, 0);
            WriteStrImm(FCode, X2, X5, 8);
            WriteAddImm(FCode, X3, X3, 1);
            WriteStrImm(FCode, X3, X0, 0);
            loopEndPos := FCode.Size;
            FCode.PatchU32(branchPos3, ((loopEndPos - branchPos3) div 4) shl 5 or $14000000);
          end;

        irSetAdd:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X0, 0);
            WriteLslImm(FCode, X3, X2, 4);
            WriteAddReg(FCode, X3, X0, X3);
            WriteAddImm(FCode, X3, X3, 16);
            WriteStrImm(FCode, X1, X3, 0);
            WriteAddImm(FCode, X2, X2, 1);
            WriteStrImm(FCode, X2, X0, 0);
          end;

        irMapGet:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X0, 0);
            WriteMovImm64(FCode, X3, 0);
            WriteMovImm64(FCode, X7, 0);
            WriteAddImm(FCode, X4, X0, 16);
            loopStartPos := FCode.Size;
            WriteCmpReg(FCode, X3, X2);
            branchPos1 := FCode.Size;
            WriteBranchCond(FCode, $0A, 0);
            WriteLdrImm(FCode, X5, X4, 0);
            WriteCmpReg(FCode, X5, X1);
            branchPos2 := FCode.Size;
            WriteBranchCond(FCode, $01, 0);
            WriteLdrImm(FCode, X7, X4, 8);
            branchPos3 := FCode.Size;
            WriteBranch(FCode, 0);
            notFoundPos := FCode.Size;
            FCode.PatchU32(branchPos2, ((notFoundPos - branchPos2) div 4) shl 5 or $54000001);
            WriteAddImm(FCode, X4, X4, 16);
            WriteAddImm(FCode, X3, X3, 1);
            WriteBranch(FCode, (loopStartPos - FCode.Size) div 4);
            doneLabelPos := FCode.Size;
            FCode.PatchU32(branchPos1, ((doneLabelPos - branchPos1) div 4) shl 5 or $5400000A);
            FCode.PatchU32(branchPos3, ((doneLabelPos - branchPos3) div 4) shl 5 or $14000000);
            WriteStrImm(FCode, X7, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;

        irMapContains, irSetContains:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteLdrImm(FCode, X2, X0, 0);
            WriteMovImm64(FCode, X3, 0);
            WriteMovImm64(FCode, X7, 0);
            WriteAddImm(FCode, X4, X0, 16);
            loopStartPos := FCode.Size;
            WriteCmpReg(FCode, X3, X2);
            branchPos1 := FCode.Size;
            WriteBranchCond(FCode, $0A, 0);
            WriteLdrImm(FCode, X5, X4, 0);
            WriteCmpReg(FCode, X5, X1);
            branchPos2 := FCode.Size;
            WriteBranchCond(FCode, $01, 0);
            WriteMovImm64(FCode, X7, 1);
            branchPos3 := FCode.Size;
            WriteBranch(FCode, 0);
            notFoundPos := FCode.Size;
            FCode.PatchU32(branchPos2, ((notFoundPos - branchPos2) div 4) shl 5 or $54000001);
            WriteAddImm(FCode, X4, X4, 16);
            WriteAddImm(FCode, X3, X3, 1);
            WriteBranch(FCode, (loopStartPos - FCode.Size) div 4);
            doneLabelPos := FCode.Size;
            FCode.PatchU32(branchPos1, ((doneLabelPos - branchPos1) div 4) shl 5 or $5400000A);
            FCode.PatchU32(branchPos3, ((doneLabelPos - branchPos3) div 4) shl 5 or $14000000);
            WriteStrImm(FCode, X7, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;

        irMapLen, irSetLen:
          begin
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X0, X0, 0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;

        irMapRemove, irSetRemove, irMapFree, irSetFree:
          begin
            // TODO: implement
          end;
        
        else
          // Unhandled - skip
          ;
      end;
    end;
  end;
  
  // Phase 5: Patch branches - simplified approach without GetBufferAt
  // We'll skip patching for now as it requires GetBufferAt which doesn't exist
  
  // Patch Random Seed ADRP+ADD references
  if FRandomSeedAdded and (Length(FGlobalVarLeaPatches) > 0) then
  begin
    var i: Integer;
    for i := 0 to High(FGlobalVarLeaPatches) do
    begin
      if FGlobalVarLeaPatches[i].VarIndex = -2 then
      begin
        var patchPos := FGlobalVarLeaPatches[i].CodePos;
        var strOffset := FRandomSeedOffset;
        var codeVA: UInt64 = 0; // Will be set by PE writer
        var dataVA: UInt64 = 0; // Will be set by PE writer
        var targetAddr := dataVA + strOffset;
        var instrAddr := codeVA + patchPos;
        var pageOffset := targetAddr - (instrAddr and not UInt64($FFF));
        
        if FGlobalVarLeaPatches[i].IsAdrp then
        begin
          // Patch ADRP: page offset >> 12
          var page := pageOffset shr 12;
          var immlo := (page shr 2) and 3;
          var immhi := page and 3;
          // ADRP encoding: bits 5,29,30,31 for immlo, bits 8-23 for immhi
          var instr := FCode.Data[patchPos] or (FCode.Data[patchPos+1] shl 8) or
                       (FCode.Data[patchPos+2] shl 16) or (FCode.Data[patchPos+3] shl 24);
          instr := instr or (UInt32(immlo) shl 29) or (UInt32(immhi) shl 5);
          FCode.PatchU32(patchPos, instr);
        end
        else
        begin
          // Patch ADD: low 12 bits of offset
          var low12 := pageOffset and $FFF;
          var instr := FCode.Data[patchPos] or (FCode.Data[patchPos+1] shl 8) or
                       (FCode.Data[patchPos+2] shl 16) or (FCode.Data[patchPos+3] shl 24);
          // Clear old immediate and set new one
          instr := instr and not $003FFC00;
          instr := instr or (UInt32(low12) shl 10);
          FCode.PatchU32(patchPos, instr);
        end;
      end;
    end;
  end;
  
  // Note: For a complete implementation, you would need to:
  // 1. Add GetBufferAt method to TByteBuffer
  // 2. Or use a different approach to patch instructions
  
end;

end.
