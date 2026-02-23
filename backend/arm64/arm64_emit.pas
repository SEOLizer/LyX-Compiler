{$mode objfpc}{$H+}
unit arm64_emit;

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
    CondCode: Integer;  // For B.cond
  end;

  TARM64Emitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;   // Positions of ADR/ADRP instructions
    FLeaStrIndex: array of Integer;    // String index for each LEA
    FLabelPositions: array of TLabelPos;
    FBranchPatches: array of TBranchPatch;
    FFuncOffsets: array of Integer;    // Function start offsets
    FFuncNames: TStringList;           // Function names
    FCallPatches: array of record
      CodePos: Integer;
      TargetName: string;
    end;
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetFunctionOffset(const name: string): Integer;
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
  X29 = 29;  // Frame Pointer (FP)
  X30 = 30;  // Link Register (LR)
  XZR = 31;  // Zero Register (also SP in some contexts)
  SP = 31;   // Stack Pointer

  // Parameter registers (AAPCS64)
  ParamRegs: array[0..7] of Byte = (X0, X1, X2, X3, X4, X5, X6, X7);

  // Linux ARM64 Syscall Numbers
  SYS_read = 63;
  SYS_write = 64;
  SYS_exit = 93;
  SYS_mmap = 222;
  SYS_munmap = 215;
  SYS_brk = 214;

// ==========================================================================
// ARM64 Instruction Encoding Helpers
// All ARM64 instructions are 32-bit (4 bytes)
// ==========================================================================

procedure EmitInstr(buf: TByteBuffer; instr: DWord);
begin
  buf.WriteU32LE(instr);
end;

// MOVZ Xd, #imm16, LSL #shift  (move wide with zero)
// Clears other bits, then places imm16 at position shift
procedure WriteMovz(buf: TByteBuffer; rd: Byte; imm: Word; shift: Byte);
var
  hw: Byte;
begin
  hw := shift div 16;  // 0, 1, 2, or 3
  // MOVZ (64-bit): sf=1, opc=10, hw, imm16, Rd
  // 1 10 100101 hw imm16 Rd
  EmitInstr(buf, $D2800000 or (DWord(hw) shl 21) or (DWord(imm) shl 5) or rd);
end;

// MOVK Xd, #imm16, LSL #shift  (move wide with keep)
// Keeps other bits, replaces 16-bit field at position shift
procedure WriteMovk(buf: TByteBuffer; rd: Byte; imm: Word; shift: Byte);
var
  hw: Byte;
begin
  hw := shift div 16;
  // MOVK (64-bit): sf=1, opc=11, hw, imm16, Rd
  // 1 11 100101 hw imm16 Rd
  EmitInstr(buf, $F2800000 or (DWord(hw) shl 21) or (DWord(imm) shl 5) or rd);
end;

// MOVN Xd, #imm16, LSL #shift  (move wide with NOT)
procedure WriteMovn(buf: TByteBuffer; rd: Byte; imm: Word; shift: Byte);
var
  hw: Byte;
begin
  hw := shift div 16;
  // MOVN (64-bit): sf=1, opc=00, hw, imm16, Rd
  EmitInstr(buf, $92800000 or (DWord(hw) shl 21) or (DWord(imm) shl 5) or rd);
end;

// Load 64-bit immediate into register (up to 4 instructions)
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

  // For small values, single MOVZ is enough
  if (not needK1) and (not needK2) and (not needK3) then
  begin
    WriteMovz(buf, rd, w0, 0);
    Exit;
  end;

  // Start with MOVZ for lowest non-zero part, then MOVK for rest
  WriteMovz(buf, rd, w0, 0);
  if needK1 then WriteMovk(buf, rd, w1, 16);
  if needK2 then WriteMovk(buf, rd, w2, 32);
  if needK3 then WriteMovk(buf, rd, w3, 48);
end;

// MOV Xd, Xm  (register to register)
// For SP (X31), we must use ADD Xd, SP, #0 because ORR treats X31 as XZR
// For other registers, we use ORR Xd, XZR, Xm
procedure WriteMovRegReg(buf: TByteBuffer; rd, rm: Byte);
begin
  if rm = SP then
  begin
    // MOV Xd, SP must be encoded as ADD Xd, SP, #0
    // ADD (immediate): sf=1, op=0, S=0, imm12=0, Rn=SP, Rd
    // 1 0 0 10001 00 000000000000 11111 Rd
    EmitInstr(buf, $910003E0 or rd);
  end
  else
  begin
    // ORR (shifted register): sf=1, opc=01, shift=00, N=0, Rm, imm6=0, Rn=XZR, Rd
    // 1 01 01010 00 0 Rm 000000 11111 Rd
    EmitInstr(buf, $AA0003E0 or (DWord(rm) shl 16) or rd);
  end;
end;

// LDR Xt, [Xn, #imm]  (load 64-bit, unsigned offset)
// Offset must be multiple of 8
procedure WriteLdrImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  // Offset is scaled by 8 for 64-bit loads
  imm12 := DWord((offset div 8) and $FFF);
  // LDR (immediate, unsigned offset): size=11, V=0, opc=01, imm12, Rn, Rt
  // 11 111 0 01 01 imm12 Rn Rt
  EmitInstr(buf, $F9400000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// STR Xt, [Xn, #imm]  (store 64-bit, unsigned offset)
// Offset must be multiple of 8
procedure WriteStrImm(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset div 8) and $FFF);
  // STR (immediate, unsigned offset): size=11, V=0, opc=00, imm12, Rn, Rt
  // 11 111 0 01 00 imm12 Rn Rt
  EmitInstr(buf, $F9000000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// LDR Xt, [Xn, #simm] (load with signed offset, pre/post index)
// LDUR for unscaled offset
procedure WriteLdurImm(buf: TByteBuffer; rt, rn: Byte; offset: Int16);
var
  imm9: DWord;
begin
  imm9 := DWord(offset and $1FF);
  // LDUR: 11 111000 010 imm9 00 Rn Rt
  EmitInstr(buf, $F8400000 or (imm9 shl 12) or (DWord(rn) shl 5) or rt);
end;

// STUR Xt, [Xn, #simm] (store with unscaled signed offset)
procedure WriteSturImm(buf: TByteBuffer; rt, rn: Byte; offset: Int16);
var
  imm9: DWord;
begin
  imm9 := DWord(offset and $1FF);
  // STUR: 11 111000 000 imm9 00 Rn Rt
  EmitInstr(buf, $F8000000 or (imm9 shl 12) or (DWord(rn) shl 5) or rt);
end;

// STP Xt1, Xt2, [Xn, #imm]! (store pair, pre-index)
procedure WriteStpPreIndex(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  // Offset is scaled by 8
  imm7 := DWord((offset div 8) and $7F);
  // STP (pre-index): 10 101 0 011 imm7 Rt2 Rn Rt1
  EmitInstr(buf, $A9800000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

// LDP Xt1, Xt2, [Xn], #imm (load pair, post-index)
procedure WriteLdpPostIndex(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  // LDP (post-index): 10 101 0 001 imm7 Rt2 Rn Rt1
  EmitInstr(buf, $A8C00000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

// STP Xt1, Xt2, [Xn, #imm] (store pair, signed offset)
procedure WriteStpOffset(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  // STP (signed offset): 10 101 0 010 imm7 Rt2 Rn Rt1
  EmitInstr(buf, $A9000000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

// LDP Xt1, Xt2, [Xn, #imm] (load pair, signed offset)
procedure WriteLdpOffset(buf: TByteBuffer; rt1, rt2, rn: Byte; offset: Int16);
var
  imm7: DWord;
begin
  imm7 := DWord((offset div 8) and $7F);
  // LDP (signed offset): 10 101 0 010 imm7 Rt2 Rn Rt1  (with opc=01 for load)
  EmitInstr(buf, $A9400000 or (imm7 shl 15) or (DWord(rt2) shl 10) or (DWord(rn) shl 5) or rt1);
end;

// ADD Xd, Xn, Xm
procedure WriteAddRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // ADD (shifted register): sf=1, op=0, S=0, shift=00, Rm, imm6=0, Rn, Rd
  // 1 0 0 01011 00 0 Rm 000000 Rn Rd
  EmitInstr(buf, $8B000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// ADD Xd, Xn, #imm12
procedure WriteAddImm(buf: TByteBuffer; rd, rn: Byte; imm: Word);
begin
  // ADD (immediate): sf=1, op=0, S=0, imm12, Rn, Rd
  // 1 0 0 10001 00 imm12 Rn Rd
  EmitInstr(buf, $91000000 or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5) or rd);
end;

// SUB Xd, Xn, Xm
procedure WriteSubRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // SUB (shifted register): sf=1, op=1, S=0, shift=00, Rm, imm6=0, Rn, Rd
  // 1 1 0 01011 00 0 Rm 000000 Rn Rd
  EmitInstr(buf, $CB000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// SUB Xd, Xn, #imm12
procedure WriteSubImm(buf: TByteBuffer; rd, rn: Byte; imm: Word);
begin
  // SUB (immediate): sf=1, op=1, S=0, imm12, Rn, Rd
  EmitInstr(buf, $D1000000 or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5) or rd);
end;

// MUL Xd, Xn, Xm  (alias for MADD Xd, Xn, Xm, XZR)
procedure WriteMul(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // MADD: sf=1, op54=00, op31=000, Rm, o0=0, Ra=XZR, Rn, Rd
  // 1 00 11011 000 Rm 0 11111 Rn Rd
  EmitInstr(buf, $9B007C00 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// SDIV Xd, Xn, Xm (signed divide)
procedure WriteSdiv(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // SDIV: sf=1, op=0, S=0, Rm, opcode=000011, Rn, Rd
  // 1 0 0 11010 110 Rm 00001 1 Rn Rd
  EmitInstr(buf, $9AC00C00 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// UDIV Xd, Xn, Xm (unsigned divide)
procedure WriteUdiv(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // UDIV: sf=1, op=0, S=0, Rm, opcode=000010, Rn, Rd
  EmitInstr(buf, $9AC00800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// MSUB Xd, Xn, Xm, Xa  (Xa - Xn*Xm)
// Used for: Xd = Xn - (Xn/Xm)*Xm  (modulo)
procedure WriteMsub(buf: TByteBuffer; rd, rn, rm, ra: Byte);
begin
  // MSUB: sf=1, op54=00, op31=000, Rm, o0=1, Ra, Rn, Rd
  // 1 00 11011 000 Rm 1 Ra Rn Rd
  EmitInstr(buf, $9B008000 or (DWord(rm) shl 16) or (DWord(ra) shl 10) or (DWord(rn) shl 5) or rd);
end;

// NEG Xd, Xm  (alias for SUB Xd, XZR, Xm)
procedure WriteNeg(buf: TByteBuffer; rd, rm: Byte);
begin
  WriteSubRegReg(buf, rd, XZR, rm);
end;

// AND Xd, Xn, Xm
procedure WriteAndRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // AND (shifted register): sf=1, opc=00, shift=00, N=0, Rm, imm6=0, Rn, Rd
  // 1 00 01010 00 0 Rm 000000 Rn Rd
  EmitInstr(buf, $8A000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// ORR Xd, Xn, Xm
procedure WriteOrrRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // ORR (shifted register): sf=1, opc=01, shift=00, N=0, Rm, imm6=0, Rn, Rd
  EmitInstr(buf, $AA000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// EOR Xd, Xn, Xm (XOR)
procedure WriteEorRegReg(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // EOR (shifted register): sf=1, opc=10, shift=00, N=0, Rm, imm6=0, Rn, Rd
  EmitInstr(buf, $CA000000 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// CMP Xn, Xm  (alias for SUBS XZR, Xn, Xm)
procedure WriteCmpRegReg(buf: TByteBuffer; rn, rm: Byte);
begin
  // SUBS (shifted register): sf=1, op=1, S=1, shift=00, Rm, imm6=0, Rn, Rd=XZR
  // 1 1 1 01011 00 0 Rm 000000 Rn 11111
  EmitInstr(buf, $EB00001F or (DWord(rm) shl 16) or (DWord(rn) shl 5));
end;

// CMP Xn, #imm12
procedure WriteCmpImm(buf: TByteBuffer; rn: Byte; imm: Word);
begin
  // SUBS (immediate): sf=1, op=1, S=1, imm12, Rn, Rd=XZR
  EmitInstr(buf, $F100001F or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5));
end;

// CSET Xd, cond  (alias for CSINC Xd, XZR, XZR, invert(cond))
// Sets Xd to 1 if condition is true, else 0
procedure WriteCset(buf: TByteBuffer; rd: Byte; cond: Byte);
var
  invCond: Byte;
begin
  // Invert condition (flip bit 0)
  invCond := cond xor 1;
  // CSINC Xd, XZR, XZR, inv_cond
  // sf=1, op=0, S=0, Rm=XZR, cond, o2=0, Rn=XZR, Rd
  // 1 0 0 11010100 11111 cond 0 1 11111 Rd
  EmitInstr(buf, $9A9F07E0 or (DWord(invCond) shl 12) or rd);
end;

// Condition codes for CSET and B.cond
const
  COND_EQ = $0;  // Equal (Z=1)
  COND_NE = $1;  // Not equal (Z=0)
  COND_CS = $2;  // Carry set / unsigned higher or same (C=1)
  COND_CC = $3;  // Carry clear / unsigned lower (C=0)
  COND_MI = $4;  // Minus / negative (N=1)
  COND_PL = $5;  // Plus / positive or zero (N=0)
  COND_VS = $6;  // Overflow (V=1)
  COND_VC = $7;  // No overflow (V=0)
  COND_HI = $8;  // Unsigned higher (C=1 and Z=0)
  COND_LS = $9;  // Unsigned lower or same (C=0 or Z=1)
  COND_GE = $A;  // Signed greater or equal (N=V)
  COND_LT = $B;  // Signed less than (N!=V)
  COND_GT = $C;  // Signed greater than (Z=0 and N=V)
  COND_LE = $D;  // Signed less or equal (Z=1 or N!=V)
  COND_AL = $E;  // Always
  COND_NV = $F;  // Never (reserved)

// B label (unconditional branch)
procedure WriteBranch(buf: TByteBuffer; offset: Int32);
var
  imm26: DWord;
begin
  // Offset is in bytes, must be divisible by 4
  imm26 := DWord((offset div 4) and $3FFFFFF);
  // B: 000101 imm26
  EmitInstr(buf, $14000000 or imm26);
end;

// BL label (branch with link)
procedure WriteBranchLink(buf: TByteBuffer; offset: Int32);
var
  imm26: DWord;
begin
  imm26 := DWord((offset div 4) and $3FFFFFF);
  // BL: 100101 imm26
  EmitInstr(buf, $94000000 or imm26);
end;

// B.cond label (conditional branch)
procedure WriteBranchCond(buf: TByteBuffer; cond: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  // B.cond: 0101010 0 imm19 0 cond
  EmitInstr(buf, $54000000 or (imm19 shl 5) or cond);
end;

// CBZ Xt, label (compare and branch if zero)
procedure WriteCbz(buf: TByteBuffer; rt: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  // CBZ (64-bit): sf=1, 011010 0 imm19 Rt
  EmitInstr(buf, $B4000000 or (imm19 shl 5) or rt);
end;

// CBNZ Xt, label (compare and branch if not zero)
procedure WriteCbnz(buf: TByteBuffer; rt: Byte; offset: Int32);
var
  imm19: DWord;
begin
  imm19 := DWord((offset div 4) and $7FFFF);
  // CBNZ (64-bit): sf=1, 011010 1 imm19 Rt
  EmitInstr(buf, $B5000000 or (imm19 shl 5) or rt);
end;

// RET (return, branch to X30)
procedure WriteRet(buf: TByteBuffer);
begin
  // RET: 1101011 0 0 10 11111 0000 0 0 Rn=11110 00000
  // Default Rn = X30
  EmitInstr(buf, $D65F03C0);
end;

// SVC #imm16 (supervisor call / syscall)
procedure WriteSvc(buf: TByteBuffer; imm: Word);
begin
  // SVC: 11010100 000 imm16 00001
  EmitInstr(buf, $D4000001 or (DWord(imm) shl 5));
end;

// NOP
procedure WriteNop(buf: TByteBuffer);
begin
  EmitInstr(buf, $D503201F);
end;

// ADR Xd, label (PC-relative address, +/- 1MB range)
procedure WriteAdr(buf: TByteBuffer; rd: Byte; offset: Int32);
var
  immlo, immhi: DWord;
begin
  immlo := DWord(offset and $3);
  immhi := DWord((offset shr 2) and $7FFFF);
  // ADR: 0 immlo 10000 immhi Rd
  EmitInstr(buf, $10000000 or (immlo shl 29) or (immhi shl 5) or rd);
end;

// ADRP Xd, label (PC-relative page address, +/- 4GB range)
procedure WriteAdrp(buf: TByteBuffer; rd: Byte; offset: Int32);
var
  immlo, immhi: DWord;
begin
  // offset is already page-aligned (4KB)
  immlo := DWord((offset shr 12) and $3);
  immhi := DWord((offset shr 14) and $7FFFF);
  // ADRP: 1 immlo 10000 immhi Rd
  EmitInstr(buf, $90000000 or (immlo shl 29) or (immhi shl 5) or rd);
end;

// ==========================================================================
// TARM64Emitter Implementation
// ==========================================================================

constructor TARM64Emitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  FFuncNames := TStringList.Create;
  SetLength(FStringOffsets, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  SetLength(FLabelPositions, 0);
  SetLength(FBranchPatches, 0);
  SetLength(FFuncOffsets, 0);
  SetLength(FCallPatches, 0);
end;

destructor TARM64Emitter.Destroy;
begin
  FFuncNames.Free;
  FData.Free;
  FCode.Free;
  inherited Destroy;
end;

function TARM64Emitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TARM64Emitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TARM64Emitter.GetFunctionOffset(const name: string): Integer;
var
  idx: Integer;
begin
  idx := FFuncNames.IndexOf(name);
  if idx >= 0 then
    Result := FFuncOffsets[idx]
  else
    Result := -1;
end;

// Calculate stack slot offset from FP (X29)
// Slot 0 is at [FP-8], slot 1 at [FP-16], etc.
function SlotOffset(slot: Integer): Integer;
begin
  Result := -(slot + 1) * 8;
end;

procedure TARM64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  fn: TIRFunction;
  localCnt, maxTemp, slotIdx: Integer;
  totalSlots, frameSize: Integer;
  strIdx: Integer;
  isEntryFunction: Boolean;
  
  // String handling
  strOffset: UInt64;
  totalDataOffset: UInt64;
  stringByteOffsets: array of UInt64;
  
  // Label/branch patching
  labelIdx, targetPos, patchPos: Integer;
  branchOffset: Int32;
  
  // Call patching
  callPatchIdx, targetFuncIdx: Integer;
  
  // Function arguments
  argCount: Integer;
  argTemps: array of Integer;
  
  // Comparison result
  cond: Byte;
  
  // For address calculation
  dataVA, codeVA, instrVA: UInt64;
  disp: Int32;
  
  // Temporaries
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
      FData.WriteU8(0); // Null terminator
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;
  
  // Align data section to 8 bytes
  while (FData.Size mod 8) <> 0 do
    FData.WriteU8(0);
  
  // Phase 2: Emit _start entry point
  // _start will call main() and then exit with the return value
  
  // Save position for _start
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('_start');
  
  // _start:
  //   bl main
  //   mov x8, #93    ; sys_exit
  //   svc #0
  
  // BL main (placeholder, will be patched)
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  WriteBranchLink(FCode, 0);  // Placeholder
  
  // Move return value (X0) to exit code
  // (X0 is already the exit code from main)
  
  // sys_exit(X0)
  WriteMovImm64(FCode, X8, SYS_exit);
  WriteSvc(FCode, 0);
  
  // Phase 3: Emit builtin stubs
  
  // PrintStr builtin: X0 = string address
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintStr');
  
  // Calculate string length (strlen)
  // Input: X0 = string address
  // Uses: X1 = current char, X2 = length counter, X3 = temp
  WriteMovRegReg(FCode, X9, X0);    // Save string address in X9
  WriteMovImm64(FCode, X2, 0);       // X2 = 0 (length counter)
  // Loop: load byte, check if zero
  // loop_start:
  //   ldrb w1, [x9, x2]
  //   cbz w1, loop_end
  //   add x2, x2, #1
  //   b loop_start
  // loop_end:
  
  // LDRB W1, [X9, X2] - load byte at X9+X2
  // 00 111000 01 1 Rm 011 0 10 Rn Rt
  // size=00, V=0, opc=01, Rm=X2, option=011, S=0, Rn=X9, Rt=W1
  EmitInstr(FCode, $38626921);  // ldrb w1, [x9, x2]
  
  // CBZ W1, +12 (skip to after the branch back)
  EmitInstr(FCode, $34000061);  // cbz w1, +12
  
  // ADD X2, X2, #1
  WriteAddImm(FCode, X2, X2, 1);
  
  // B -12 (back to ldrb)
  WriteBranch(FCode, -12);
  
  // Now X2 = string length, X9 = string address
  // sys_write(1, X9, X2)
  WriteMovImm64(FCode, X0, 1);       // fd = STDOUT
  WriteMovRegReg(FCode, X1, X9);     // buf = string address
  // X2 already has length
  WriteMovImm64(FCode, X8, SYS_write);
  WriteSvc(FCode, 0);
  WriteRet(FCode);
  
  // PrintInt builtin: X0 = integer value
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('__builtin_PrintInt');
  
  // Stack buffer for digits (max 20 digits + sign + null)
  // We'll use a simple approach: divide repeatedly and store digits
  
  // Prologue: allocate stack space
  WriteStpPreIndex(FCode, X29, X30, SP, -48);  // stp x29, x30, [sp, #-48]!
  WriteMovRegReg(FCode, X29, SP);               // mov x29, sp
  
  // X0 = value to print
  // X9 = absolute value
  // X10 = buffer pointer (end)
  // X11 = sign flag (1 if negative)
  // X12 = digit
  // X13 = 10 (divisor)
  
  // Check if negative
  WriteCmpImm(FCode, X0, 0);
  WriteCset(FCode, X11, COND_LT);    // X11 = 1 if X0 < 0
  
  // If negative, negate
  // CSNEG X9, X0, X0, GE  - if >= 0, X9=X0, else X9=-X0
  // cond=GE=1010, sf=1, op=1, S=0, Rm=0, Rn=0, Rd=9, o2=1
  EmitInstr(FCode, $DA80A409);  // csneg x9, x0, x0, ge
  
  // X10 = sp + 40 (end of buffer)
  WriteAddImm(FCode, X10, SP, 40);
  
  // Store null terminator
  WriteMovImm64(FCode, X12, 0);
  WriteSturImm(FCode, X12, X10, 0);
  
  // X13 = 10
  WriteMovImm64(FCode, X13, 10);
  
  // digit_loop:
  //   sub x10, x10, #1      ; move buffer pointer back
  //   udiv x14, x9, x13     ; x14 = x9 / 10
  //   msub x12, x14, x13, x9 ; x12 = x9 - x14*10 (remainder)
  //   add x12, x12, #'0'    ; convert to ASCII
  //   strb w12, [x10]       ; store digit
  //   mov x9, x14           ; x9 = quotient
  //   cbnz x9, digit_loop   ; continue if quotient != 0
  
  // digit_loop:
  WriteSubImm(FCode, X10, X10, 1);    // sub x10, x10, #1
  WriteUdiv(FCode, X14, X9, X13);     // udiv x14, x9, x13
  WriteMsub(FCode, X12, X14, X13, X9); // msub x12, x14, x13, x9
  WriteAddImm(FCode, X12, X12, Ord('0')); // add x12, x12, #'0'
  // STRB W12, [X10]
  EmitInstr(FCode, $3800014C);        // strb w12, [x10]
  WriteMovRegReg(FCode, X9, X14);     // mov x9, x14
  WriteCbnz(FCode, X9, -24);          // cbnz x9, -24
  
  // If negative, prepend '-'
  WriteCbz(FCode, X11, 16);           // cbz x11, skip_minus
  WriteSubImm(FCode, X10, X10, 1);    // sub x10, x10, #1
  WriteMovImm64(FCode, X12, Ord('-'));
  EmitInstr(FCode, $3800014C);        // strb w12, [x10]
  // skip_minus:
  
  // Calculate length: (sp + 40) - x10
  WriteAddImm(FCode, X2, SP, 40);
  WriteSubRegReg(FCode, X2, X2, X10);
  
  // sys_write(1, X10, X2)
  WriteMovImm64(FCode, X0, 1);
  WriteMovRegReg(FCode, X1, X10);
  WriteMovImm64(FCode, X8, SYS_write);
  WriteSvc(FCode, 0);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 48);
  WriteRet(FCode);
  
  // Phase 4: Emit user functions
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];
    
    // Record function offset
    SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
    FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
    FFuncNames.Add(fn.Name);
    
    isEntryFunction := (fn.Name = 'main');
    
    // Calculate frame size
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
    
    // Frame size: slots * 8, plus 16 for saved FP/LR, aligned to 16
    frameSize := ((totalSlots * 8) + 16 + 15) and not 15;
    
    // Function prologue
    // stp x29, x30, [sp, #-frameSize]!
    // mov x29, sp
    WriteStpPreIndex(FCode, X29, X30, SP, -frameSize);
    WriteMovRegReg(FCode, X29, SP);
    
    // Copy parameters from registers to local slots
    for j := 0 to Min(fn.ParamCount - 1, 7) do
    begin
      // Parameter j is in ParamRegs[j], store to slot j
      WriteStrImm(FCode, ParamRegs[j], X29, frameSize + SlotOffset(j));
    end;
    
    // Clear label/branch tracking for this function
    SetLength(FLabelPositions, 0);
    SetLength(FBranchPatches, 0);
    
    // Emit instructions
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
            // Record LEA position for patching
            SetLength(FLeaPositions, Length(FLeaPositions) + 1);
            FLeaPositions[High(FLeaPositions)] := FCode.Size;
            SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
            FLeaStrIndex[High(FLeaStrIndex)] := strIdx;
            // ADR X0, string (placeholder, will be patched)
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
            // X0 = src1, X1 = src2
            // X2 = src1 / src2
            // result = src1 - X2 * src2
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
            // Logical NOT: if src1 == 0 then 1 else 0
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
            FBranchPatches[High(FBranchPatches)].InstrType := 0; // B
            WriteBranch(FCode, 0);  // Placeholder
          end;
          
        irBrTrue:
          begin
            // Branch if src1 != 0
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].InstrType := 3; // CBNZ
            WriteCbnz(FCode, X0, 0);  // Placeholder
          end;
          
        irBrFalse:
          begin
            // Branch if src1 == 0
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].InstrType := 2; // CBZ
            WriteCbz(FCode, X0, 0);  // Placeholder
          end;
          
        irCall:
          begin
            // Load arguments into registers
            argCount := instr.ImmInt;
            SetLength(argTemps, argCount);
            for k := 0 to argCount - 1 do argTemps[k] := -1;
            if argCount > 0 then argTemps[0] := instr.Src1;
            if argCount > 1 then argTemps[1] := instr.Src2;
            if Length(instr.ArgTemps) > 0 then
            begin
              for k := 0 to Min(argCount - 1, High(instr.ArgTemps)) do
                argTemps[k] := instr.ArgTemps[k];
            end;
            
            for k := 0 to Min(argCount - 1, 7) do
            begin
              if argTemps[k] >= 0 then
                WriteLdrImm(FCode, ParamRegs[k], X29, frameSize + SlotOffset(localCnt + argTemps[k]));
            end;
            
            // Emit BL (will be patched)
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            WriteBranchLink(FCode, 0);  // Placeholder
            
            // Store return value
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;
          
        irCallBuiltin:
          begin
            // Load argument
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            
            // Call builtin
            if instr.ImmStr = 'PrintStr' then
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintStr';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'PrintInt' then
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintInt';
              WriteBranchLink(FCode, 0);
            end
            else if instr.ImmStr = 'exit' then
            begin
              // sys_exit(X0)
              WriteMovImm64(FCode, X8, SYS_exit);
              WriteSvc(FCode, 0);
            end;
          end;
          
        irReturn:
          begin
            // Load return value into X0
            if instr.Src1 >= 0 then
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            
            // Epilogue
            WriteLdpPostIndex(FCode, X29, X30, SP, frameSize);
            WriteRet(FCode);
          end;
          
      else
        // Unimplemented: store 0 to dest
        if instr.Dest >= 0 then
        begin
          slotIdx := localCnt + instr.Dest;
          WriteMovImm64(FCode, X0, 0);
          WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
        end;
      end;
    end;
    
    // Patch intra-function branches
    for k := 0 to High(FBranchPatches) do
    begin
      // Find label
      labelIdx := -1;
      for j := 0 to High(FLabelPositions) do
      begin
        if FLabelPositions[j].Name = FBranchPatches[k].LabelName then
        begin
          labelIdx := j;
          Break;
        end;
      end;
      
      if labelIdx >= 0 then
      begin
        targetPos := FLabelPositions[labelIdx].Pos;
        patchPos := FBranchPatches[k].Pos;
        branchOffset := targetPos - patchPos;
        
        case FBranchPatches[k].InstrType of
          0: // B
            FCode.PatchU32LE(patchPos, $14000000 or DWord((branchOffset div 4) and $3FFFFFF));
          1: // BL
            FCode.PatchU32LE(patchPos, $94000000 or DWord((branchOffset div 4) and $3FFFFFF));
          2: // CBZ
            FCode.PatchU32LE(patchPos, $B4000000 or (DWord((branchOffset div 4) and $7FFFF) shl 5) or X0);
          3: // CBNZ
            FCode.PatchU32LE(patchPos, $B5000000 or (DWord((branchOffset div 4) and $7FFFF) shl 5) or X0);
        end;
      end;
    end;
    
    // Ensure function ends with return (if not already)
    // (Skip for now - functions should have explicit return)
  end;
  
  // Phase 5: Patch function calls
  for i := 0 to High(FCallPatches) do
  begin
    targetFuncIdx := FFuncNames.IndexOf(FCallPatches[i].TargetName);
    if targetFuncIdx >= 0 then
    begin
      patchPos := FCallPatches[i].CodePos;
      targetPos := FFuncOffsets[targetFuncIdx];
      branchOffset := targetPos - patchPos;
      FCode.PatchU32LE(patchPos, $94000000 or DWord((branchOffset div 4) and $3FFFFFF));
    end;
  end;
  
  // Phase 6: Patch string ADR instructions
  // Data section starts after code, aligned to page boundary
  // Base VA = $400000, Code at $401000, Data at $401000 + AlignUp(codeSize, 4096)
  codeVA := $400000 + 4096;
  dataVA := codeVA + ((FCode.Size + 4095) and not UInt64(4095));
  
  for i := 0 to High(FLeaPositions) do
  begin
    patchPos := FLeaPositions[i];
    strIdx := FLeaStrIndex[i];
    if (strIdx >= 0) and (strIdx < Length(stringByteOffsets)) then
    begin
      strOffset := stringByteOffsets[strIdx];
      instrVA := codeVA + UInt64(patchPos);
      disp := Int32((dataVA + strOffset) - instrVA);
      // Patch ADR instruction
      // ADR: 0 immlo[1:0] 10000 immhi[18:0] Rd
      FCode.PatchU32LE(patchPos, $10000000 or 
        (DWord(disp and $3) shl 29) or 
        (DWord((disp shr 2) and $7FFFF) shl 5) or 
        X0);
    end;
  end;
end;

end.
