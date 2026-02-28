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
    InstrType: Integer;
    CondCode: Integer;
  end;

  TGlobalVarLeaPatch = record
    VarIndex: Integer;
    CodePos: Integer;
    IsAdrp: Boolean;
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

// ARM64 Register (gleiche Definitionen wie Linux ARM64)
const
  X0 = 0; X1 = 1; X2 = 2; X3 = 3; X4 = 4; X5 = 5; X6 = 6; X7 = 7;
  X8 = 8; X9 = 9; X10 = 10; X11 = 11; X12 = 12; X13 = 13; X14 = 14; X15 = 15;
  X16 = 16; X17 = 17; X18 = 18; X19 = 19; X20 = 20; X21 = 21; X22 = 22; X23 = 23;
  X24 = 24; X25 = 25; X26 = 26; X27 = 27; X28 = 28;
  X29 = 29;
  X30 = 30;
  XZR = 31;
  SP = 31;
  RBP = 29;

  ParamRegs: array[0..7] of Byte = (X0, X1, X2, X3, X4, X5, X6, X7);

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

const
  COND_EQ = $0;
  COND_NE = $1;
  COND_CS = $2;
  COND_CC = $3;
  COND_MI = $4;
  COND_PL = $5;
  COND_VS = $6;
  COND_VC = $7;
  COND_HI = $8;
  COND_LS = $9;
  COND_GE = $A;
  COND_LT = $B;
  COND_GT = $C;
  COND_LE = $D;
  COND_AL = $E;

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

// LDRB for byte load
procedure WriteLdrbImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset) and $FFF);
  EmitInstr(buf, $38400000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// STRB for byte store
procedure WriteStrbImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset) and $FFF);
  EmitInstr(buf, $38000000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

function SlotOffset(slot: Integer): Integer;
begin
  Result := -(slot + 1) * 8;
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
  SetLength(Result, 0);
end;

function TWindowsARM64Emitter.GetPLTGOTPatches: TPLTGOTPatchArray;
begin
  SetLength(Result, 0);
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
  origInstr: DWord;
  rd, rn: Byte;
  tmpReg: Byte;
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
  
  // Phase 2: Emit _start entry point
  // Für Windows verwenden wir keinen Syscall, sondern rufen ExitProcess auf
  // Der Entry-Point ist am Anfang des Codes (Address 0x10000)
  
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('_start');
  
  // _start:
  //   ; Kein Stack-Setup nötig, Windows hat bereits einen Stack eingerichtet
  //   ; Aber wir müssen LR (X30) sichern für den Fall, dass wir zurückkehren
  //   ; Eigentlich für Windows: Wir rufen main() auf und dann ExitProcess
  
  // Save LR on stack
  WriteStpPreIndex(FCode, X30, XZR, SP, -16);  // str x30, [sp, #-16]!
  
  // call main (placeholder)
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  WriteBranchLink(FCode, 0);
  
  // Restore LR and exit
  WriteLdpPostIndex(FCode, X30, XZR, SP, 16);  // ldr x30, [sp], #16
  
  // X0 enthält den Return-Wert von main
  // ExitProcess(exitCode) - wir müssen die Adresse aus der IAT laden
  // Da wir keinen PLT haben, werden wir einen simplen Hack verwenden:
  // Wir erwarten, dass die IAT am Anfang der .idata Sektion liegt
  
  // Für jetzt: Endlosschleife wenn kein ExitProcess verfügbar
  // Real: hier würde der Aufruf von ExitProcess stehen
  
  // MOV X16, #0 (Platzhalter für ExitProcess aus IAT)
  // WriteMovImm64(FCode, X16, 0);
  // LDR X16, [X16, #0]  ; Load from IAT
  // BLR X16            ; Call ExitProcess
  
  // Infinite loop for now - actual ExitProcess would be called here
  WriteCbz(FCode, X0, 4);   // cbz x0, $+8 (skip next)
  WriteBranch(FCode, -4);   // b -4 (loop forever)
  WriteRet(FCode);           // return (sollte nicht erreicht werden)
  
  // Phase 3: Builtin Stubs
  // PrintStr: X0 = string address
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintStr');
  
  // X0 = string address
  // X9 = saved string address
  // X2 = length
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
  
  // Write to console using Windows API
  // GetStdHandle(STD_OUTPUT_HANDLE) = -11
  // WriteFile(hFile, lpBuffer, nNumberOfBytesToWrite, lpNumberOfBytesWritten, lpOverlapped)
  
  // Load -11 into X0 for GetStdHandle
  WriteMovImm64(FCode, X0, UInt64(-11));
  // Placeholder: LDR X16, [X16, #Offset] ; Load GetStdHandle from IAT
  // BLR X16
  // Ergebnis (Handle) ist in X0
  
  // Oder einfacher: WriteFile direkt mit bereits bekanntem Handle
  // WriteFile braucht: X0=Handle, X1=Buffer, X2=BytesToWrite, X3=BytesWritten, X4=Overlapped
  WriteMovRegReg(FCode, X1, X9);  // Buffer = string address
  WriteMovRegReg(FCode, X2, X2);  // nBytesToWrite = length
  WriteMovImm64(FCode, X3, 0);     // lpNumberOfBytesWritten = NULL
  WriteMovImm64(FCode, X4, 0);     // lpOverlapped = NULL
  
  // Placeholder: LDR X16, [X16, #Offset] ; Load WriteFile from IAT
  // BLR X16
  
  // Falls WriteFile fehlschlägt, ignorieren wir einfach
  
  WriteRet(FCode);
  
  // PrintInt: X0 = integer value
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintInt');
  
  // Prologue
  WriteStpPreIndex(FCode, X29, X30, SP, -48);
  WriteMovRegReg(FCode, X29, SP);
  
  // X0 = value to print
  // Similar to Linux version, but using Windows API for output
  WriteCmpImm(FCode, X0, 0);
  WriteCset(FCode, X11, COND_LT);
  
  // CSNEG X9, X0, X0, GE
  EmitInstr(FCode, $DA80A409);
  
  WriteAddImm(FCode, X10, SP, 40);
  WriteMovImm64(FCode, X12, 0);
  // STUR X12, [X10]
  EmitInstr(FCode, $F800001C);
  
  WriteMovImm64(FCode, X13, 10);
  
  // digit loop
  WriteSubImm(FCode, X10, X10, 1);
  WriteUdiv(FCode, X14, X9, X13);
  WriteMsub(FCode, X12, X14, X13, X9);
  WriteAddImm(FCode, X12, X12, Ord('0'));
  // STRB W12, [X10]
  EmitInstr(FCode, $3800014C);
  WriteMovRegReg(FCode, X9, X14);
  WriteCbnz(FCode, X9, -24);
  
  WriteCbz(FCode, X11, 16);
  WriteSubImm(FCode, X10, X10, 1);
  WriteMovImm64(FCode, X12, Ord('-'));
  EmitInstr(FCode, $3800014C);
  
  WriteAddImm(FCode, X2, SP, 40);
  WriteSubRegReg(FCode, X2, X2, X10);
  
  // Write to console
  WriteMovRegReg(FCode, X1, X10);
  // Placeholder für WriteFile-Aufruf
  
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
        
        irBranch:
          begin
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].InstrType := 0;
            WriteBranch(FCode, 0);
          end;
        
        irBranchCond:
          begin
            // B.cond
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].InstrType := 4;
            // Load condition code from imm
            cond := Byte(instr.ImmInt);
            WriteBranchCond(FCode, cond, 0);
          end;
        
        irCall:
          begin
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.FuncName;
            WriteBranchLink(FCode, 0);
          end;
        
        irCallBuiltin:
          begin
            // Builtin-Aufrufe wie PrintStr, PrintInt
            // Diese müssen in X0-X7 vorbereitet werden
            // Der Name ist in instr.ImmStr
            
            // Load parameters
            if instr.Src1 >= 0 then
            begin
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            end;
            
            // Call builtin
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := '__builtin_' + instr.ImmStr;
            WriteBranchLink(FCode, 0);
            
            // Store result if needed
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;
        
        irRet:
          begin
            // Load return value into X0
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Epilogue
            WriteLdpPostIndex(FCode, X29, X30, SP, frameSize);
            WriteRet(FCode);
          end;
        
        else
          // Unhandled IR opcode
          ;
      end;
    end;
  end;
  
  // Phase 5: Patch branches
  for i := 0 to High(FBranchPatches) do
  begin
    labelIdx := -1;
    for j := 0 to High(FLabelPositions) do
    begin
      if FLabelPositions[j].Name = FBranchPatches[i].LabelName then
      begin
        labelIdx := j;
        Break;
      end;
    end;
    
    if labelIdx >= 0 then
    begin
      targetPos := FLabelPositions[labelIdx].Pos;
      patchPos := FBranchPatches[i].Pos;
      branchOffset := targetPos - patchPos;
      
      // Patch instruction
      origInstr := 0;
      FCode.GetBufferAt(patchPos, origInstr);
      
      case FBranchPatches[i].InstrType of
        0: // B
          origInstr := origInstr or (DWord((branchOffset div 4) and $3FFFFFF) shl 0);
        4: // B.cond
          origInstr := origInstr or (DWord((branchOffset div 4) and $7FFFF) shl 5);
      end;
      
      FCode.PatchU32LE(patchPos, origInstr);
    end;
  end;
  
  // Phase 6: Patch calls
  for i := 0 to High(FCallPatches) do
  begin
    targetFuncIdx := FFuncNames.IndexOf(FCallPatches[i].TargetName);
    if targetFuncIdx >= 0 then
    begin
      targetPos := FFuncOffsets[targetFuncIdx];
      patchPos := FCallPatches[i].CodePos;
      branchOffset := targetPos - patchPos;
      
      origInstr := 0;
      FCode.GetBufferAt(patchPos, origInstr);
      origInstr := origInstr or (DWord((branchOffset div 4) and $3FFFFFF));
      FCode.PatchU32LE(patchPos, origInstr);
    end;
  end;
  
  // Phase 7: Patch string LEA positions
  for i := 0 to High(FLeaPositions) do
  begin
    strIdx := FLeaStrIndex[i];
    if strIdx >= 0 then
    begin
      // Calculate offset from LEA position to string in data section
      // ADR instruction is at position FLeaPositions[i]
      // String is at totalDataOffset + stringByteOffsets[strIdx]
      // Need to calculate relative offset
      
      // Current code position after ADR is: FLeaPositions[i] + 4
      // Data starts at: FCode.Size + FData.Size
      
      // Simpler: calculate absolute offset
      disp := Int32((FTotalDataOffset + stringByteOffsets[strIdx]) - UInt64(FLeaPositions[i]));
      
      origInstr := 0;
      FCode.GetBufferAt(FLeaPositions[i], origInstr);
      
      // ADR encoding: immlo = offset & 3, immhi = (offset >> 2) & 0x7FFFF
      // But ADR expects signed offset, so we need to sign-extend
      
      // For simplicity, use ADRP + LDR
      // Actually, ADR can handle it if we fix the encoding
      
      // Patch ADR to use correct offset
      // ADR: 0 immlo 10000 immhi Rd
      // offset is in bytes, ADR adds PC to offset
      
      // PC at ADR position is: FLeaPositions[i]
      // Target: FTotalDataOffset + stringByteOffsets[strIdx]
      
      // Just patch the existing ADR instruction
      // This is a simplification - proper solution needs relocations
      
    end;
  end;
  
  // Done - the actual executable would need relocations to be applied
  // by the PE loader or we need to use absolute addresses
  
end;

end.
