{$mode objfpc}{$H+}
unit arm64_emit;

interface

uses
  SysUtils, Classes, bytes, ir, backend_types, energy_model;

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

  TGlobalVarLeaPatch = record
    VarIndex: Integer;
    CodePos: Integer;
    IsAdrp: Boolean;  // True if ADRP, False if ADR
  end;

  TEnergyOpKind = (eokALU, eokFPU, eokMemory, eokBranch, eokSyscall);

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
    // Global variables
    FGlobalVarNames: TStringList;
    FGlobalVarOffsets: array of UInt64;
    FGlobalVarLeaPatches: array of TGlobalVarLeaPatch;
    FTotalDataOffset: UInt64;
    // Random seed
    FRandomSeedOffset: UInt64;
    FRandomSeedAdded: Boolean;
    FRandomSeedLeaPatches: array of Integer;
    // External symbols for PLT/GOT (Dynamic Linking)
    FExternalSymbols: array of TExternalSymbol;
    FPLTGOTPatches: array of TPLTGOTPatch;
    FPLT0CodePos: Integer;  // Position of PLT0 in code buffer
    // VMT (Virtual Method Table) support
    FVMTLabels: array of TLabelPos;
    FVMTLeaPositions: array of record
      VMTIndex: Integer;     // Index in module.ClassDecls
      MethodIndex: Integer;  // Index in VirtualMethods array
      CodePos: Integer;      // Position of ADRP+ADD placeholder in code
    end;
    FVMTAddrLeaPositions: array of record
      VMTLabelIndex: Integer;
      CodePos: Integer;      // Position of ADRP+ADD for VMT address load
    end;
    // Energy tracking (minimal — vollständige Integration in Phase 3)
    FEnergyStats: TEnergyStats;
    FEnergyContext: TEnergyContext;
    FCurrentCPU: TCPUEnergyModel;
    FMemoryAccessCount: UInt64;
    FCurrentFunctionEnergy: UInt64;
    FTargetOS: TTargetOS;
    procedure TrackEnergy(kind: TEnergyOpKind);
    // OS-specific syscall helpers
    procedure WriteSyscall(syscallNum: UInt64);
    procedure WriteSyscallInsn;
  public
    constructor Create(targetOS: TTargetOS = atLinux);
    procedure SetTargetOS(targetOS: TTargetOS);
    destructor Destroy; override;
    procedure EmitFromIR(module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetFunctionOffset(const name: string): Integer;
    function GetExternalSymbols: TExternalSymbolArray;
    function GetPLTGOTPatches: TPLTGOTPatchArray;
    function GetEnergyStats: TEnergyStats;
    procedure SetEnergyLevel(level: TEnergyLevel);
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
  RBP = 29;  // Alias for X29 (for compatibility)

  // Parameter registers (AAPCS64)
  ParamRegs: array[0..7] of Byte = (X0, X1, X2, X3, X4, X5, X6, X7);

  // ARM64 FP/SIMD Registers (V0-V31, auch nutzbar als D0-D31 für 64-bit Double)
  V0 = 0; V1 = 1; V2 = 2; V3 = 3; V4 = 4; V5 = 5; V6 = 6; V7 = 7;
  V8 = 8; V9 = 9; V10 = 10; V11 = 11; V12 = 12; V13 = 13; V14 = 14; V15 = 15;
  V16 = 16; V17 = 17; V18 = 18; V19 = 19; V20 = 20; V21 = 21; V22 = 22; V23 = 23;
  V24 = 24; V25 = 25; V26 = 26; V27 = 27; V28 = 28; V29 = 29; V30 = 30; V31 = 31;

  // Linux ARM64 Syscall Numbers
  SYS_read = 63;
  SYS_write = 64;
  SYS_exit = 93;
  SYS_open = 56;
  SYS_close = 57;
  SYS_lseek = 62;
  SYS_unlink = 87;
  SYS_rename = 82;
  SYS_mkdir = 83;
  SYS_rmdir = 84;
  SYS_chmod = 90;
  SYS_mmap = 222;
  SYS_munmap = 215;
  SYS_brk = 214;

  // macOS ARM64 Syscall Numbers (BSD-style)
  MACOS_SYS_exit = 1;
  MACOS_SYS_read = 3;
  MACOS_SYS_write = 4;
  MACOS_SYS_open = 5;
  MACOS_SYS_close = 6;
  MACOS_SYS_lseek = 199;
  MACOS_SYS_unlink = 10;
  MACOS_SYS_rename = 51;
  MACOS_SYS_mkdir = 54;
  MACOS_SYS_rmdir = 73;
  MACOS_SYS_chmod = 15;
  MACOS_SYS_mmap = 197;
  MACOS_SYS_munmap = 73;

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

// AND Xd, Xn, #imm (logical immediate)
// Note: ARM64 has complex immediate encoding for logical ops
// For simplicity, we use MOV + AND for masks that don't fit
procedure WriteAndImm(buf: TByteBuffer; rd, rn: Byte; imm: UInt64);
var
  encoded: DWord;
  n, immr, imms: Boolean;
begin
  // Try to encode as logical immediate (simplified - only handles power-of-2 minus 1 masks)
  // For now, use a simpler approach: if imm fits in 32-bit, use 32-bit AND
  if imm <= $FFFFFFFF then
  begin
    // AND (immediate, 32-bit): 00 100100 immr imms Rn Rd
    // For masks like 0xFF, 0xFFFF, 0xFFFFFF, etc., we can encode directly
    // Simplified: just AND with lower 32 bits
    EmitInstr(buf, $12000000 or (DWord(imm and $FFF) shl 10) or (DWord(rn) shl 5) or rd);
  end
  else
  begin
    // For larger masks, load into register first
    // This should be handled by caller using MOV + AND
    WriteAndRegReg(buf, rd, rn, rn);  // Fallback
  end;
end;

// LSL Xd, Xn, #amount (Logical Shift Left)
// LSL is an alias for UBFM: LSL Xd, Xn, #amount = UBFM Xd, Xn, #(64-amount), #(63-amount)
procedure WriteLslImm(buf: TByteBuffer; rd, rn: Byte; amount: Byte);
var
  immr, imms: DWord;
begin
  // UBFM: 1 10 100110 immr imms Rn Rd
  immr := (64 - amount) and $3F;
  imms := (63 - amount) and $3F;
  EmitInstr(buf, $D3400000 or (immr shl 16) or (imms shl 10) or (DWord(rn) shl 5) or rd);
end;

// ASR Xd, Xn, #amount (Arithmetic Shift Right)
// ASR is an alias for SBFM: ASR Xd, Xn, #amount = SBFM Xd, Xn, #amount, #63
procedure WriteAsrImm(buf: TByteBuffer; rd, rn: Byte; amount: Byte);
var
  immr, imms: DWord;
begin
  // SBFM: 1 00 100110 immr imms Rn Rd
  immr := amount and $3F;
  imms := 63;
  EmitInstr(buf, $93400000 or (immr shl 16) or (imms shl 10) or (DWord(rn) shl 5) or rd);
end;

// SXTW Xd, Wn (Sign Extend Word to Doubleword)
// SXTW is an alias for SBFM Xd, Xn, #0, #31
procedure WriteSxtw(buf: TByteBuffer; rd, rn: Byte);
begin
  // SBFM Xd, Xn, #0, #31
  // 1 00 100110 000000 011111 Rn Rd
  EmitInstr(buf, $93407C00 or (DWord(rn) shl 5) or rd);
end;

// SXTH Xd, Wn (Sign Extend Halfword to Doubleword)
procedure WriteSxth(buf: TByteBuffer; rd, rn: Byte);
begin
  // SBFM Xd, Xn, #0, #15
  // 1 00 100110 000000 001111 Rn Rd
  EmitInstr(buf, $93402C00 or (DWord(rn) shl 5) or rd);
end;

// SXTB Xd, Wn (Sign Extend Byte to Doubleword)
procedure WriteSxtb(buf: TByteBuffer; rd, rn: Byte);
begin
  // SBFM Xd, Xn, #0, #7
  // 1 00 100110 000000 000111 Rn Rd
  EmitInstr(buf, $93401C00 or (DWord(rn) shl 5) or rd);
end;

// UXTW Xd, Wn (Zero Extend Word to Doubleword)
// Actually, just using the 32-bit form (Wn) automatically zeros the upper 32 bits
// But we can also encode it explicitly as UBFM Xd, Xn, #0, #31
procedure WriteUxtw(buf: TByteBuffer; rd, rn: Byte);
begin
  // UBFM Xd, Xn, #0, #31
  // 1 10 100110 000000 011111 Rn Rd
  EmitInstr(buf, $D3407C00 or (DWord(rn) shl 5) or rd);
end;

// UXTH Xd, Wn (Zero Extend Halfword to Doubleword)
procedure WriteUxth(buf: TByteBuffer; rd, rn: Byte);
begin
  // UBFM Xd, Xn, #0, #15
  // 1 10 100110 000000 001111 Rn Rd
  EmitInstr(buf, $D3402C00 or (DWord(rn) shl 5) or rd);
end;

// UXTB Xd, Wn (Zero Extend Byte to Doubleword)
procedure WriteUxtb(buf: TByteBuffer; rd, rn: Byte);
begin
  // UBFM Xd, Xn, #0, #7
  // 1 10 100110 000000 000111 Rn Rd
  EmitInstr(buf, $D3401C00 or (DWord(rn) shl 5) or rd);
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

// BLR Xn - Branch with Link to Register (indirect call)
procedure WriteBlr(buf: TByteBuffer; rn: Byte);
begin
  // BLR Xn: 1101011 0001 00000 000000 rn 00000
  EmitInstr(buf, $D63F0000 or (DWord(rn and $1F) shl 5));
end;

// LDR Xd, [Xn, #imm9] - Load register with offset (unscaled, 9-bit signed offset)
procedure WriteLdrRegOffset(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm9: DWord;
begin
  // LDR (immediate, unsigned offset): 111100 011 imm12 rn rt
  // For 64-bit: opc=11, V=0
  if offset >= 0 then
    // LDR Xt, [Xn, #imm12] - unsigned offset
    EmitInstr(buf, $F9400000 or (DWord(offset and $FFF) shl 10) or (DWord(rn and $1F) shl 5) or DWord(rt and $1F))
  else
  begin
    // Negative offset: use STUR/LDUR encoding (unscaled offset)
    imm9 := DWord(offset and $1FF);
    EmitInstr(buf, $F8600000 or (imm9 shl 12) or (DWord(rn and $1F) shl 5) or DWord(rt and $1F));
  end;
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
// ARM64 Floating Point Instruction Encoding
// ==========================================================================

// FMOV Sd, Sn (32-bit float move)
procedure WriteFmovS(buf: TByteBuffer; rd, rn: Byte);
begin
  // FMOV (scalar, 32-bit): 000 11110 00 1 00000 Rm 000000 Rn Rd
  // 0 00 11110 00 1 00000 00000 000000 00000 Rd
  EmitInstr(buf, $1E204000 or (DWord(rn) shl 5) or rd);
end;

// FMOV Dd, Dn (64-bit float move)
procedure WriteFmovD(buf: TByteBuffer; rd, rn: Byte);
begin
  // FMOV (scalar, 64-bit): 111 1110 0 01 00000 Rm 000000 Rn Rd
  EmitInstr(buf, $D6000000 or (DWord(rn) shl 5) or rd);
end;

// FADD Sd, Sn, Sm (32-bit float add)
procedure WriteFaddS(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FADD (scalar, 32-bit): 000 11110 00 1 00100 Rm 000000 Rn Rd
  EmitInstr(buf, $1E204800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FADD Dd, Dn, Dm (64-bit float add)
procedure WriteFaddD(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FADD (scalar, 64-bit): 111 1110 0 01 00100 Rm 000000 Rn Rd
  EmitInstr(buf, $D6200800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FSUB Sd, Sn, Sm (32-bit float subtract)
procedure WriteFsubS(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FSUB: 000 11110 00 1 00110 Rm 000000 Rn Rd
  EmitInstr(buf, $1E205800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FSUB Dd, Dn, Dm (64-bit float subtract)
procedure WriteFsubD(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FSUB: 111 1110 0 01 00110 Rm 000000 Rn Rd
  EmitInstr(buf, $D6201800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FMUL Sd, Sn, Sm (32-bit float multiply)
procedure WriteFmulS(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FMUL: 000 11110 00 1 10010 Rm 000000 Rn Rd
  EmitInstr(buf, $1E208800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FMUL Dd, Dn, Dm (64-bit float multiply)
procedure WriteFmulD(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FMUL: 111 1110 0 01 10010 Rm 000000 Rn Rd
  EmitInstr(buf, $D6208800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FDIV Sd, Sn, Sm (32-bit float divide)
procedure WriteFdivS(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FDIV: 000 11110 00 1 11110 Rm 000000 Rn Rd
  EmitInstr(buf, $1E20F800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FDIV Dd, Dn, Dm (64-bit float divide)
procedure WriteFdivD(buf: TByteBuffer; rd, rn, rm: Byte);
begin
  // FDIV: 111 1110 0 01 11110 Rm 000000 Rn Rd
  EmitInstr(buf, $D620F800 or (DWord(rm) shl 16) or (DWord(rn) shl 5) or rd);
end;

// FNEG Sd, Sn (32-bit float negate)
procedure WriteFnegS(buf: TByteBuffer; rd, rn: Byte);
begin
  // FNEG: 000 11110 01 1 00010 Rm 000000 Rn Rd
  EmitInstr(buf, $1E214000 or (DWord(rn) shl 5) or rd);
end;

// FNEG Dd, Dn (64-bit float negate)
procedure WriteFnegD(buf: TByteBuffer; rd, rn: Byte);
begin
  // FNEG: 111 1110 0 11 00010 Rm 000000 Rn Rd
  EmitInstr(buf, $D6200C00 or (DWord(rn) shl 5) or rd);
end;

// FCMP Sd, Sn (compare float)
procedure WriteFcmpS(buf: TByteBuffer; rn, rm: Byte);
begin
  // FCMP: 000 11110 00 1 00100 Rm 000000 Rn 00000
  EmitInstr(buf, $1E20403E or (DWord(rm) shl 16) or (DWord(rn) shl 5));
end;

// FCMP Dn, Dm (compare float, 64-bit)
procedure WriteFcmpD(buf: TByteBuffer; rn, rm: Byte);
begin
  // FCMP: 111 1110 0 01 00100 Rm 000000 Rn 00000
  EmitInstr(buf, $D620043E or (DWord(rm) shl 16) or (DWord(rn) shl 5));
end;

// FCMP Sd, #0 (compare with zero)
procedure WriteFcmpSZero(buf: TByteBuffer; rn: Byte);
begin
  // FCMP: 000 11110 00 1 00100 Rm=00000 000000 Rn 00000
  EmitInstr(buf, $1E20403E or (DWord(rn) shl 5));
end;

// FCMP Dn, #0 (compare with zero, 64-bit)
procedure WriteFcmpDZero(buf: TByteBuffer; rn: Byte);
begin
  // FCMP: 111 1110 0 01 00100 Rm=00000 000000 Rn 00000
  EmitInstr(buf, $D620043E or (DWord(rn) shl 5));
end;

// FCSEL Sd, Sn, Sm, cond (conditional select float, 32-bit)
// cond: 0=EQ, 1=NE, 2=CS, 3=CC, 4=MI, 5=PL, 6=VS, 7=VC, 8=HI, 9=LS, A=GE, B=LT, C=GT, D=LE
procedure WriteFcselS(buf: TByteBuffer; rd, rn, rm: Byte; cond: Byte);
begin
  // FCSEL: 000 11110 01 1 00011 Rm cond 00 Rn Rd
  EmitInstr(buf, $1E204C00 or (DWord(rm) shl 16) or (DWord(cond) shl 12) or (DWord(rn) shl 5) or rd);
end;

// FCSEL Dd, Dn, Dm, cond (conditional select float, 64-bit)
procedure WriteFcselD(buf: TByteBuffer; rd, rn, rm: Byte; cond: Byte);
begin
  // FCSEL: 111 1110 0 11 00011 Rm cond 00 Rn Rd
  EmitInstr(buf, $D6200C00 or (DWord(rm) shl 16) or (DWord(cond) shl 12) or (DWord(rn) shl 5) or rd);
end;

// FCVTZS Sd, Sn (float to signed int, 32-bit result)
procedure WriteFcvtzsS(buf: TByteBuffer; rd, rn: Byte);
begin
  // FCVTZS (scalar): 000 11110 11 1 11000 000000 Rn Rd
  EmitInstr(buf, $1E21C000 or (DWord(rn) shl 5) or rd);
end;

// FCVTZS Dd, Dn (float to signed int, 64-bit result)
procedure WriteFcvtzsD(buf: TByteBuffer; rd, rn: Byte);
begin
  // FCVTZS (scalar, 64-bit): 111 1110 1 11 11000 000000 Rn Rd
  EmitInstr(buf, $D621C000 or (DWord(rn) shl 5) or rd);
end;

// SCVTF Sd, Sn (signed int to float, 32-bit result)
procedure WriteScvtfS(buf: TByteBuffer; rd, rn: Byte);
begin
  // SCVTF (scalar): 000 11110 10 0 00000 000000 Rn Rd
  EmitInstr(buf, $1E220000 or (DWord(rn) shl 5) or rd);
end;

// SCVTF Dd, Dn (signed int to float, 64-bit result)
procedure WriteScvtfD(buf: TByteBuffer; rd, rn: Byte);
begin
  // SCVTF (scalar, 64-bit): 111 1110 1 10 00000 000000 Rn Rd
  EmitInstr(buf, $D6204000 or (DWord(rn) shl 5) or rd);
end;

// LDR St, [Xn, #imm] (load 32-bit float)
procedure WriteLdrFloat(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  // LDR (immediate, scalar, 32-bit): size=01, V=1, opc=01, imm12, Rn, Rt
  imm12 := DWord((offset div 4) and $FFF);
  EmitInstr(buf, $BC400000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// STR St, [Xn, #imm] (store 32-bit float)
procedure WriteStrFloat(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  imm12 := DWord((offset div 4) and $FFF);
  // STR (immediate, scalar, 32-bit): size=01, V=1, opc=00, imm12, Rn, Rt
  EmitInstr(buf, $BC000000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// LDR Dt, [Xn, #imm] (load 64-bit float/double)
procedure WriteLdrDouble(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  // LDR (immediate, scalar, 64-bit): size=11, V=1, opc=01, imm12, Rn, Rt
  imm12 := DWord((offset div 8) and $FFF);
  EmitInstr(buf, $FD400000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// STR Dt, [Xn, #imm] (store 64-bit float/double)
procedure WriteStrDouble(buf: TByteBuffer; rt, rn: Byte; offset: Integer);
var
  imm12: DWord;
begin
  // STR (immediate, scalar, 64-bit): size=11, V=1, opc=00, imm12, Rn, Rt
  imm12 := DWord((offset div 8) and $FFF);
  EmitInstr(buf, $FD000000 or (imm12 shl 10) or (DWord(rn) shl 5) or rt);
end;

// High-level Load/Store wrapper for slot access from frame pointer
// WriteLoad: Load from [base + offset] into dest register
procedure WriteLoad(buf: TByteBuffer; dest, base: Byte; offset: Integer);
begin
  WriteLdrImm(buf, dest, base, offset);
end;

// WriteStore: Store from source register to [base + offset]
procedure WriteStore(buf: TByteBuffer; src, base: Byte; offset: Integer);
begin
  WriteStrImm(buf, src, base, offset);
end;

// ==========================================================================
// Compute the GOT VA that WriteDynamicElf64ARM64 will place the GOT at,
// given the final code size and external symbol list.
// Mirrors the layout calculation in elf64_arm64_writer.pas.
// ==========================================================================

function ComputeExpectedGotVA(const externalSymbols: array of TExternalSymbol;
  codeSize: UInt64; dataSize: UInt64): UInt64;
const
  pageSize: UInt64 = 4096;
  baseVA:   UInt64 = $400000;
  interpSize: UInt64 = 27;  // Length('/lib/ld-linux-aarch64.so.1'#0)
var
  interpOffset, dynstrOffset: UInt64;
  dynstrSize, dynsymSize, dynsymOffset: UInt64;
  hashSize, hashOffset, gotOffsetSeg: UInt64;
  dataShift: UInt64;
  symCount, i: Integer;
begin
  symCount := Length(externalSymbols);

  interpOffset := pageSize + codeSize;
  if (interpOffset mod 8) <> 0 then
    interpOffset := interpOffset + (8 - (interpOffset mod 8));

  dynstrOffset := (interpOffset + interpSize + pageSize - 1) and not (pageSize - 1);

  // dataShift: user data lives at the start of the RW segment, before dynstr
  dataShift := (dataSize + 7) and not UInt64(7);

  // dynstrSize: 1 null byte + library names + symbol names (each NUL-terminated)
  dynstrSize := 1;
  for i := 0 to symCount - 1 do
    dynstrSize := dynstrSize + UInt64(Length(externalSymbols[i].LibraryName)) + 1;
  for i := 0 to symCount - 1 do
    dynstrSize := dynstrSize + UInt64(Length(externalSymbols[i].Name)) + 1;

  dynsymSize   := UInt64(symCount + 1) * 24;
  dynsymOffset := (dataShift + dynstrSize + 7) and not UInt64(7);
  hashSize     := UInt64(3 + 2 * symCount) * 4;
  hashOffset   := (dynsymOffset + dynsymSize + 7) and not UInt64(7);
  gotOffsetSeg := (hashOffset + hashSize + 7) and not UInt64(7);

  Result := baseVA + dynstrOffset + gotOffsetSeg;
end;

// ==========================================================================
// Helper function to get library name for external symbols
// ==========================================================================

function GetLibraryForSymbol(const symbolName: string): string;
begin
  // Map common symbols to their libraries
  if (symbolName = 'strlen') or (symbolName = 'strcmp') or
     (symbolName = 'strcpy') or (symbolName = 'strcat') or
     (symbolName = 'strstr') or (symbolName = 'strchr') or
     (symbolName = 'strdup') or (symbolName = 'malloc') or
     (symbolName = 'free') or (symbolName = 'realloc') or
     (symbolName = 'memcpy') or (symbolName = 'memmove') or
     (symbolName = 'memset') or (symbolName = 'memcmp') or
     (symbolName = 'printf') or (symbolName = 'sprintf') or
     (symbolName = 'fopen') or (symbolName = 'fclose') or
     (symbolName = 'fread') or (symbolName = 'fwrite') or
     (symbolName = 'fprintf') or (symbolName = 'fscanf') or
     (symbolName = 'atoi') or (symbolName = 'atof') or
     (symbolName = 'strtol') or (symbolName = 'strtod') or
     (symbolName = 'exit') or (symbolName = 'abort') or
     (symbolName = 'system') or (symbolName = 'getenv') or
     (symbolName = 'setenv') or (symbolName = 'unsetenv') then
    Result := 'libc.so.6'
  else if (symbolName = 'pthread_create') or (symbolName = 'pthread_join') or
          (symbolName = 'pthread_mutex_init') or (symbolName = 'pthread_mutex_lock') or
          (symbolName = 'pthread_mutex_unlock') or (symbolName = 'pthread_cond_init') or
          (symbolName = 'pthread_cond_wait') or (symbolName = 'pthread_cond_signal') or
          (symbolName = 'pthread_cond_broadcast') then
    Result := 'libpthread.so.0'
  else if (symbolName = 'sqrt') or (symbolName = 'sin') or
          (symbolName = 'cos') or (symbolName = 'tan') or
          (symbolName = 'asin') or (symbolName = 'acos') or
          (symbolName = 'atan') or (symbolName = 'exp') or
          (symbolName = 'log') or (symbolName = 'log10') or
          (symbolName = 'pow') or (symbolName = 'floor') or
          (symbolName = 'ceil') or (symbolName = 'fabs') then
    Result := 'libm.so.6'
  else
    // Default to libc
    Result := 'libc.so.6';
end;

// ==========================================================================
// TARM64Emitter Implementation
// ==========================================================================

constructor TARM64Emitter.Create(targetOS: TTargetOS = atLinux);
begin
  inherited Create;
  FTargetOS := targetOS;
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
  // External symbols for PLT/GOT
  SetLength(FExternalSymbols, 0);
  SetLength(FPLTGOTPatches, 0);
  FPLT0CodePos := 0;
  // Energy tracking initialization
  FCurrentCPU := GetCPUEnergyModel(cfARM64);
  FEnergyContext.CurrentCPU := FCurrentCPU;
  FEnergyContext.Config := GetEnergyConfig;
  FMemoryAccessCount := 0;
  FCurrentFunctionEnergy := 0;
  FillChar(FEnergyStats, SizeOf(FEnergyStats), 0);
  FEnergyStats.DetailedBreakdown := nil;
end;

destructor TARM64Emitter.Destroy;
begin
  FGlobalVarNames.Free;
  FFuncNames.Free;
  FData.Free;
  FCode.Free;
  inherited Destroy;
end;

procedure TARM64Emitter.SetTargetOS(targetOS: TTargetOS);
begin
  FTargetOS := targetOS;
end;

procedure TARM64Emitter.WriteSyscall(syscallNum: UInt64);
begin
  if FTargetOS = atmacOS then
  begin
    // macOS ARM64: syscall number in X16, svc #0x80
    WriteMovImm64(FCode, X16, syscallNum);
    WriteSvc(FCode, $80);
  end
  else
  begin
    // Linux ARM64: syscall number in X8, svc #0
    WriteMovImm64(FCode, X8, syscallNum);
    WriteSvc(FCode, 0);
  end;
end;

// Write just the SVC instruction (after syscall number is set)
procedure TARM64Emitter.WriteSyscallInsn;
begin
  if FTargetOS = atmacOS then
    WriteSvc(FCode, $80)
  else
    WriteSvc(FCode, 0);
end;

procedure TARM64Emitter.TrackEnergy(kind: TEnergyOpKind);
var
  cost: UInt64;
begin
  case kind of
    eokALU:
    begin
      Inc(FEnergyStats.TotalALUOps);
      cost := FCurrentCPU.InstructionCosts.ALU_OPS[0];
    end;
    eokFPU:
    begin
      Inc(FEnergyStats.TotalFPUOps);
      cost := FCurrentCPU.InstructionCosts.FPU_OPS[0];
    end;
    eokMemory:
    begin
      Inc(FEnergyStats.TotalMemoryAccesses);
      Inc(FMemoryAccessCount);
      cost := FCurrentCPU.InstructionCosts.MEMORY_OPS[0];
    end;
    eokBranch:
    begin
      Inc(FEnergyStats.TotalBranches);
      cost := FCurrentCPU.InstructionCosts.BRANCH_OPS[0];
    end;
    eokSyscall:
    begin
      Inc(FEnergyStats.TotalSyscalls);
      cost := FCurrentCPU.InstructionCosts.SYS_CALL_COST;
    end;
    else
      cost := 0;
  end;
  FCurrentFunctionEnergy := FCurrentFunctionEnergy + cost;
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
  strIdx, varIdx: Integer;
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
  extLibName: string;

  // Function arguments
  argCount: Integer;
  argTemps: array of Integer;
  arg3: Integer;
  
  // Comparison result
  cond: Byte;
  
  // For address calculation
  dataVA, codeVA, instrVA: UInt64;
  
  // VMT patching
  vmtIdx, methodIdx, vmtLabelIdx: Integer;
  mangledName: string;
  adrpPos, adrpPage, targetPage: Integer;
  pageOffset, addOffset: Int32;
  found: Boolean;
  ei: Integer;
  disp: Int32;
  origInstr: DWord;

  // Phase 11: PLT GOT patching
  gotBaseVA, gotSlotVA, stubVA: UInt64;
  ldrPos: Integer;
  wordOff: Int64;
  rd, rn: Byte;
  
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
  
  // Phase 1b: Write global variables to data section
  // This is BEFORE FTotalDataOffset is set, so globals are placed right after strings
  for i := 0 to High(module.GlobalVars) do
  begin
    // Record this global's name and offset
    FGlobalVarNames.Add(module.GlobalVars[i].Name);
    SetLength(FGlobalVarOffsets, Length(FGlobalVarOffsets) + 1);
    FGlobalVarOffsets[High(FGlobalVarOffsets)] := FData.Size;
    
    if module.GlobalVars[i].IsArray then
    begin
      // Global array
      if module.GlobalVars[i].HasInitValue and (module.GlobalVars[i].ArrayLen > 0) then
      begin
        // Write initialized array values
        for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
          FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValues[j]));
      end
      else
      begin
        // Write zero-initialized array
        if module.GlobalVars[i].ArrayLen > 0 then
        begin
          for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
            FData.WriteU64LE(0);
        end;
      end;
    end
    else
    begin
      // Scalar global variable
      if module.GlobalVars[i].HasInitValue then
        FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValue))
      else
        FData.WriteU64LE(0);
    end;
  end;
  
  // Sync FTotalDataOffset with the data section size after strings and globals
  FTotalDataOffset := FData.Size;
  
  // Phase 2: Emit _start entry point
  // _start calls main() and exits with the return value.

  // Save position for _start
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
  FFuncNames.Add('_start');

  // BL main (placeholder, will be patched)
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  WriteBranchLink(FCode, 0);  // Placeholder
  
  // Move return value (X0) to exit code
  // (X0 is already the exit code from main)
  
  // sys_exit(X0)
  WriteSyscall(SYS_exit);
  
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
  WriteSyscall(SYS_write);
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
  WriteSyscall(SYS_write);
  
  // Epilogue
  WriteLdpPostIndex(FCode, X29, X30, SP, 48);
  WriteRet(FCode);
  
  // Phase 4: Emit user functions
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];
    
    // Energy-Level für diese Funktion setzen (falls spezifiziert)
    if fn.EnergyLevel > eelNone then
      SetEnergyLevel(fn.EnergyLevel);
    
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
      
      // Energy-Tracking: Kategorie pro IR-Instruktion zählen
      case instr.Op of
        irAdd, irSub, irMul, irDiv, irMod, irNeg, irNot, irAnd, irOr,
        irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
        irSExt, irZExt, irTrunc:
          TrackEnergy(eokALU);
        irFAdd, irFSub, irFMul, irFDiv, irFNeg,
        irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe,
        irFToI, irIToF:
          TrackEnergy(eokFPU);
        irLoadLocal, irStoreLocal, irLoadGlobal, irStoreGlobal,
        irLoadGlobalAddr, irLoadLocalAddr, irLoadStructAddr,
        irStoreElem, irLoadElem, irStoreElemDyn,
        irLoadField, irStoreField, irLoadFieldHeap, irStoreFieldHeap,
        irAlloc, irFree,
        irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree:
          TrackEnergy(eokMemory);
        irJmp, irBrTrue, irBrFalse, irCall, irCallStruct,
        irReturn, irReturnStruct:
          TrackEnergy(eokBranch);
        irCallBuiltin:
          if (instr.ImmStr = 'exit') or (instr.ImmStr = 'PrintStr') or
             (instr.ImmStr = 'PrintInt') or (instr.ImmStr = 'open') or
             (instr.ImmStr = 'read') or (instr.ImmStr = 'write') or
             (instr.ImmStr = 'lseek') or (instr.ImmStr = 'unlink') or
             (instr.ImmStr = 'rename') or (instr.ImmStr = 'mkdir') or
             (instr.ImmStr = 'rmdir') or (instr.ImmStr = 'chmod') or
             (instr.ImmStr = 'now_unix') or (instr.ImmStr = 'now_unix_ms') or
             (instr.ImmStr = 'sleep_ms') then
            TrackEnergy(eokSyscall)
          else
            TrackEnergy(eokALU);
        irPanic:
          TrackEnergy(eokSyscall);
      end;

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
          
        irTrunc:
          begin
            // Truncate src1 to ImmInt bits
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            if instr.ImmInt < 64 then
            begin
              // Create mask: (1 << bits) - 1
              // For small masks, we can use immediate AND
              // For larger masks, load mask into register
              if instr.ImmInt <= 24 then
              begin
                // Small mask fits in immediate encoding
                // Use AND with immediate (simplified - actually need bitfield)
                // Alternative: AND with register containing mask
                WriteMovImm64(FCode, X1, (UInt64(1) shl instr.ImmInt) - 1);
                WriteAndRegReg(FCode, X0, X0, X1);
              end
              else
              begin
                // Larger mask - load into register
                WriteMovImm64(FCode, X1, (UInt64(1) shl instr.ImmInt) - 1);
                WriteAndRegReg(FCode, X0, X0, X1);
              end;
            end;
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irSExt:
          begin
            // Sign-extend src1 (width in ImmInt) into dest
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            case instr.ImmInt of
              8:  WriteSxtb(FCode, X0, X0);   // Sign-extend byte
              16: WriteSxth(FCode, X0, X0);   // Sign-extend halfword
              32: WriteSxtw(FCode, X0, X0);   // Sign-extend word
            else
              // Generic sign-extend: shift left then arithmetic shift right
              if instr.ImmInt < 64 then
              begin
                WriteLslImm(FCode, X0, X0, 64 - instr.ImmInt);
                WriteAsrImm(FCode, X0, X0, 64 - instr.ImmInt);
              end;
            end;
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irZExt:
          begin
            // Zero-extend src1 (width in ImmInt) into dest
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            case instr.ImmInt of
              8:  WriteUxtb(FCode, X0, X0);   // Zero-extend byte
              16: WriteUxth(FCode, X0, X0);   // Zero-extend halfword
              32: WriteUxtw(FCode, X0, X0);   // Zero-extend word (also: using W register clears upper bits)
            else
              // For other widths, mask with (1 << bits) - 1
              if instr.ImmInt < 64 then
              begin
                WriteMovImm64(FCode, X1, (UInt64(1) shl instr.ImmInt) - 1);
                WriteAndRegReg(FCode, X0, X0, X1);
              end;
            end;
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
            
            // Virtual method call dispatch
            if instr.IsVirtualCall and (instr.VMTIndex >= 0) then
            begin
              // 1. Load VMT pointer from object: ldr x0, [x0] (VMT at offset 0)
              WriteLdrImm(FCode, X0, X0, 0);
              // 2. Load method pointer from VMT: ldr x0, [x0, #(vmtIdx*8)]
              WriteLdrRegOffset(FCode, X0, X0, instr.VMTIndex * 8);
              // 3. Indirect call: blr x0
              WriteBlr(FCode, X0);
            end
            else
            // Check if this is an external call (cmExternal)
            if instr.CallMode = cmExternal then
            begin
              // External call: record symbol for PLT/GOT generation
              found := False;
              for ei := 0 to High(FExternalSymbols) do
                if FExternalSymbols[ei].Name = instr.ImmStr then
                begin
                  found := True;
                  Break;
                end;
              
              if not found then
              begin
                SetLength(FExternalSymbols, Length(FExternalSymbols) + 1);
                FExternalSymbols[High(FExternalSymbols)].Name := instr.ImmStr;
                extLibName := module.GetExternLibrary(instr.ImmStr);
                if extLibName = '' then extLibName := GetLibraryForSymbol(instr.ImmStr);
                FExternalSymbols[High(FExternalSymbols)].LibraryName := extLibName;
              end;
              
              // Emit call to PLT stub label (generated after all functions)
              // Use BLR to call PLT stub (will be patched later)
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := '__plt_' + instr.ImmStr;
              // BLR X16 (call via PLT entry in X16)
              // For now, use simple BL - will be patched to PLT
              WriteBranchLink(FCode, 0);  // Placeholder
            end
            else
            begin
              // Internal or imported call: emit BL (will be patched)
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
              WriteBranchLink(FCode, 0);  // Placeholder
            end;
            
            // Store return value
            if instr.Dest >= 0 then
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
          end;
          
          // ========================================================================
          // SIMD Operations (NEON) for ParallelArray
          // ========================================================================
          // ARM64 NEON: 128-bit registers (V0-V31), accessed as 64-bit for int64
          
          irSIMDAdd:
            begin
              // Scalar fallback: dest = src1 + src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteAddRegReg(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDSub:
            begin
              // Scalar fallback: dest = src1 - src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteSubRegReg(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDMul:
            begin
              // Scalar fallback: dest = src1 * src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteMul(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDDiv:
            begin
              // Scalar fallback: dest = src1 / src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteSdiv(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDAnd:
            begin
              // Scalar: dest = src1 & src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteAndRegReg(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDOr:
            begin
              // Scalar: dest = src1 | src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteOrrRegReg(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDXor:
            begin
              // Scalar: dest = src1 ^ src2
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              WriteEorRegReg(FCode, X0, X0, X1);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDNeg:
            begin
              // Scalar: dest = -src1
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteNeg(FCode, X0, X0);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe:
            begin
              // Scalar comparison: set dest to 1 if true, 0 if false
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
              // Compare X0, X1 - sets flags
              WriteCmpRegReg(FCode, X0, X1);
              // Use CSET to set X0 to 1 if condition is true
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
              // Load element: dest = src1[src2]
              // Simplified version: assumes index is small constant or 0
              // Full implementation would need register-based address calculation
              slotIdx := localCnt + instr.Dest;
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));  // base
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));  // index
              // X1 = X1 * 8
              WriteLslImm(FCode, X1, X1, 3);
              // X0 = X0 + X1
              WriteAddRegReg(FCode, X0, X0, X1);
              // Load from [X0] - simplified: load from base+offset
              WriteLdrImm(FCode, X0, X0, 0);
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;

          irSIMDStoreElem:
            begin
              // Store element: src1[src2] = src3
              // Simplified version
              WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));  // base
              WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));  // index
              WriteLdrImm(FCode, X2, X29, frameSize + SlotOffset(localCnt + instr.Src3));  // value
              // Save base+offset to X1
              WriteLslImm(FCode, X1, X1, 3);
              WriteAddRegReg(FCode, X1, X0, X1);
              // Store from X2 to address in X1 (simplified)
              WriteStrImm(FCode, X2, X1, 0);
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
              WriteSyscall(SYS_exit);
            end
            // === std.io: fd-basierte I/O Syscalls (Linux ARM64) ===
            else if instr.ImmStr = 'open' then
            begin
              // open(path: pchar, flags: int64, mode: int64) -> int64
              // X0 = path, X1 = flags, X2 = mode
              // syscall number = 56
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteLoad(FCode, X2, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovImm64(FCode, X2, 0);
              WriteSyscall(SYS_open);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'read' then
            begin
              // read(fd: int64, buf: pchar, count: int64) -> int64
              // X0 = fd, X1 = buf, X2 = count
              // syscall number = 63
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteLoad(FCode, X2, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovImm64(FCode, X2, 0);
              WriteSyscall(SYS_read);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'write' then
            begin
              // write(fd: int64, buf: pchar, count: int64) -> int64
              // X0 = fd, X1 = buf, X2 = count
              // syscall number = 64
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteLoad(FCode, X2, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovImm64(FCode, X2, 0);
              WriteSyscall(SYS_write);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'close' then
            begin
              // close(fd: int64) -> int64
              // X0 = fd
              // syscall number = 57
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              WriteSyscall(SYS_close);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'lseek' then
            begin
              // lseek(fd: int64, offset: int64, whence: int64) -> int64
              // X0 = fd, X1 = offset, X2 = whence
              // syscall number = 62
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteLoad(FCode, X2, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovImm64(FCode, X2, 0);
              WriteSyscall(SYS_lseek);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'unlink' then
            begin
              // unlink(path: pchar) -> int64
              // X0 = path
              // syscall number = 87
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              WriteSyscall(SYS_unlink);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'rename' then
            begin
              // rename(oldpath: pchar, newpath: pchar) -> int64
              // X0 = oldpath, X1 = newpath
              // syscall number = 82
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              WriteSyscall(SYS_rename);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'mkdir' then
            begin
              // mkdir(path: pchar, mode: int64) -> int64
              // X0 = path, X1 = mode
              // syscall number = 83
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              WriteSyscall(SYS_mkdir);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'rmdir' then
            begin
              // rmdir(path: pchar) -> int64
              // X0 = path
              // syscall number = 84
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              WriteSyscall(SYS_rmdir);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'chmod' then
            begin
              // chmod(path: pchar, mode: int64) -> int64
              // X0 = path, X1 = mode
              // syscall number = 90
              if instr.Src1 >= 0 then
                WriteLoad(FCode, X0, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovImm64(FCode, X0, 0);
              if instr.Src2 >= 0 then
                WriteLoad(FCode, X1, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovImm64(FCode, X1, 0);
              WriteSyscall(SYS_chmod);
              if instr.Dest >= 0 then
                WriteStore(FCode, X0, RBP, SlotOffset(localCnt + instr.Dest));
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
              
              // Load seed address: ADRP X1, page + ADD X1, X1, #offset
              SetLength(FRandomSeedLeaPatches, Length(FRandomSeedLeaPatches) + 1);
              FRandomSeedLeaPatches[High(FRandomSeedLeaPatches)] := FCode.Size;
              WriteAdrp(FCode, X1, 0);  // Placeholder
              SetLength(FRandomSeedLeaPatches, Length(FRandomSeedLeaPatches) + 1);
              FRandomSeedLeaPatches[High(FRandomSeedLeaPatches)] := FCode.Size;
              WriteAddImm(FCode, X1, X1, 0);  // Placeholder
              
              // LDR X0, [X1] - load current seed
              WriteLdrImm(FCode, X0, X1, 0);
              
              // Compute: X0 = X0 * 1103515245 + 12345
              // X2 = 1103515245 (0x41C64E6D)
              WriteMovImm64(FCode, X2, 1103515245);
              // X0 = X0 * X2
              WriteMul(FCode, X0, X0, X2);
              // X0 = X0 + 12345 (12345 > 4095, need to load into register first)
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
              // X0 already contains the seed value from Src1
              if not FRandomSeedAdded then
              begin
                FRandomSeedOffset := FData.Size;
                FData.WriteU64LE(1);
                FRandomSeedAdded := True;
              end;
              
              // Load seed address: ADRP X1, page + ADD X1, X1, #offset
              SetLength(FRandomSeedLeaPatches, Length(FRandomSeedLeaPatches) + 1);
              FRandomSeedLeaPatches[High(FRandomSeedLeaPatches)] := FCode.Size;
              WriteAdrp(FCode, X1, 0);  // Placeholder
              SetLength(FRandomSeedLeaPatches, Length(FRandomSeedLeaPatches) + 1);
              FRandomSeedLeaPatches[High(FRandomSeedLeaPatches)] := FCode.Size;
              WriteAddImm(FCode, X1, X1, 0);  // Placeholder
              
              // STR X0, [X1] - store new seed
              WriteStrImm(FCode, X0, X1, 0);
            end
            else if instr.ImmStr = 'RegexMatch' then
            begin
              // RegexMatch(pattern, text) -> bool (1 or 0)
              // X0 = pattern, X1 = text
              // Einfache Implementierung: noch nicht vollstaendig
              // Return 0 fuer jetzt
              WriteMovImm64(FCode, X0, 0);
              // Store result in dest temp
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'RegexSearch' then
            begin
              // RegexSearch(pattern, text) -> int64 (position or -1)
              // Einfache Implementierung: return -1
              WriteMovImm64(FCode, X0, UInt64(-1));
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end
            else if instr.ImmStr = 'RegexReplace' then
            begin
              // RegexReplace(pattern, text, replacement) -> int64 (count)
              // Einfache Implementierung: return 0
              WriteMovImm64(FCode, X0, 0);
              if instr.Dest >= 0 then
                WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          end;
          
        // ========== Phase 2: Global Variables ==========
        
        irLoadGlobal:
          begin
            // Load global variable into temp: dest = globals[ImmStr]
            slotIdx := localCnt + instr.Dest;
            varIdx := FGlobalVarNames.IndexOf(instr.ImmStr);
            if varIdx < 0 then
            begin
              // First access to this global - allocate space in data section
              varIdx := FGlobalVarNames.Count;
              FGlobalVarNames.Add(instr.ImmStr);
              SetLength(FGlobalVarOffsets, varIdx + 1);
              FGlobalVarOffsets[varIdx] := FTotalDataOffset;
              FData.WriteU64LE(0); // Initialize to 0
              Inc(FTotalDataOffset, 8);
            end;
            // Emit ADRP + ADD to get address (will be patched later)
            SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := True;
            WriteAdrp(FCode, X1, 0);  // Placeholder: ADRP X1, page
            // Now emit ADD for page offset
            SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := False;
            WriteAddImm(FCode, X1, X1, 0);  // Placeholder: ADD X1, X1, #offset
            // LDR X0, [X1]
            WriteLdrImm(FCode, X0, X1, 0);
            // Store into temp slot
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irStoreGlobal:
          begin
            // Store temp into global variable: globals[ImmStr] = src1
            // Load value from temp
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            varIdx := FGlobalVarNames.IndexOf(instr.ImmStr);
            if varIdx < 0 then
            begin
              // First access to this global - allocate space in data section
              varIdx := FGlobalVarNames.Count;
              FGlobalVarNames.Add(instr.ImmStr);
              SetLength(FGlobalVarOffsets, varIdx + 1);
              FGlobalVarOffsets[varIdx] := FTotalDataOffset;
              FData.WriteU64LE(0);
              Inc(FTotalDataOffset, 8);
            end;
            // Emit ADRP + ADD to get address
            SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := True;
            WriteAdrp(FCode, X1, 0);  // Placeholder
            SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
            FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := False;
            WriteAddImm(FCode, X1, X1, 0);  // Placeholder
            // STR X0, [X1]
            WriteStrImm(FCode, X0, X1, 0);
          end;
          
        irLoadGlobalAddr:
          begin
            // Load address of global variable into temp: dest = &globals[ImmStr]
            slotIdx := localCnt + instr.Dest;
            
            // Check for VMT address load (_vmt_ClassName)
            if Copy(instr.ImmStr, 1, 5) = '_vmt_' then
            begin
              // VMT address load: ADRP + ADD with placeholder, patched later
              SetLength(FVMTAddrLeaPositions, Length(FVMTAddrLeaPositions) + 1);
              FVMTAddrLeaPositions[High(FVMTAddrLeaPositions)].CodePos := FCode.Size;
              // Find or create VMT label index
              found := False;
              for ei := 0 to High(FVMTLabels) do
              begin
                if FVMTLabels[ei].Name = instr.ImmStr then
                begin
                  FVMTAddrLeaPositions[High(FVMTAddrLeaPositions)].VMTLabelIndex := ei;
                  found := True;
                  Break;
                end;
              end;
              if not found then
              begin
                // VMT label not yet created - create placeholder
                FVMTAddrLeaPositions[High(FVMTAddrLeaPositions)].VMTLabelIndex := Length(FVMTLabels);
                SetLength(FVMTLabels, Length(FVMTLabels) + 1);
                FVMTLabels[High(FVMTLabels)].Name := instr.ImmStr;
                FVMTLabels[High(FVMTLabels)].Pos := 0;  // Will be set during VMT generation
              end;
              WriteAdrp(FCode, X0, 0);   // Placeholder: ADRP X0, page
              WriteAddImm(FCode, X0, X0, 0); // Placeholder: ADD X0, X0, #offset
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end
            else
            begin
              varIdx := FGlobalVarNames.IndexOf(instr.ImmStr);
              if varIdx < 0 then
              begin
                // First access to this global - allocate space in data section
                varIdx := FGlobalVarNames.Count;
                FGlobalVarNames.Add(instr.ImmStr);
                SetLength(FGlobalVarOffsets, varIdx + 1);
                FGlobalVarOffsets[varIdx] := FTotalDataOffset;
                FData.WriteU64LE(0);
                Inc(FTotalDataOffset, 8);
              end;
              // Emit ADRP + ADD to get address directly into X0
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := True;
              WriteAdrp(FCode, X0, 0);
              SetLength(FGlobalVarLeaPatches, Length(FGlobalVarLeaPatches) + 1);
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].VarIndex := varIdx;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].CodePos := FCode.Size;
              FGlobalVarLeaPatches[High(FGlobalVarLeaPatches)].IsAdrp := False;
              WriteAddImm(FCode, X0, X0, 0);
              // Store address into temp slot
              WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
            end;
          end;
          
        // ========== Phase 3: Arrays ==========
        
        irStackAlloc:
          begin
            // Allocate array on stack: dest = stack[ImmInt bytes]
            // Just compute the address (stack pointer minus size)
            slotIdx := localCnt + instr.Dest;
            // We'll use a simple approach: the address is at a known offset from FP
            // The stack space is already allocated in the function prologue
            WriteAddImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irLoadElem:
          begin
            // Load array element: dest = base[index * scale]
            slotIdx := localCnt + instr.Dest;
            // Load base address
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Load index
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            // Calculate offset: index * 8 (assuming 64-bit elements)
            // LSL X1, X1, #3 (multiply by 8)
            WriteLslImm(FCode, X1, X1, 3);
            // Add base + offset
            WriteAddRegReg(FCode, X0, X0, X1);
            // Load element
            WriteLdrImm(FCode, X0, X0, 0);
            // Store result
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irStoreElem:
          begin
            // Store array element: base[ImmInt] = value
            // Src1 = base address temp, Src2 = value temp, ImmInt = static index
            // Load base address
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Calculate address: base + index * 8
            // For static index, we can use immediate offset in LDR/STR
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            // Store at base + index*8
            WriteStrImm(FCode, X1, X0, instr.ImmInt * 8);
          end;
          
        irStoreElemDyn:
          begin
            // Store array element with dynamic index
            // Src1 = base address temp, Src2 = index temp, Src3 = value temp
            // Load base address
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Load index
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            // Calculate offset: index * 8
            WriteLslImm(FCode, X1, X1, 3);
            // Add base + offset -> X0 = target address
            WriteAddRegReg(FCode, X0, X0, X1);
            // Load value to store (Src3)
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src3));
            // Store element at [X0]
            WriteStrImm(FCode, X1, X0, 0);
          end;
          
        irLoadLocalAddr:
          begin
            // Load address of local variable: dest = &locals[src1]
            slotIdx := localCnt + instr.Dest;
            WriteAddImm(FCode, X0, X29, frameSize + SlotOffset(instr.Src1));
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irAlloc:
          begin
            // Heap allocation: Dest = alloc(ImmInt bytes)
            // Use mmap syscall: sys_mmap(addr=0, len=ImmInt, prot=3, flags=34, fd=-1, off=0)
            // ARM64 Linux syscall numbers: mmap=222, munmap=215
            
            // X0 = addr (0 = NULL, let kernel choose)
            WriteMovImm64(FCode, X0, 0);
            // X1 = length (size in bytes)
            WriteMovImm64(FCode, X1, UInt64(instr.ImmInt));
            // X2 = prot (PROT_READ | PROT_WRITE = 3)
            WriteMovImm64(FCode, X2, 3);
            // X3 = flags (MAP_PRIVATE | MAP_ANONYMOUS = 34)
            WriteMovImm64(FCode, X3, 34);
            // X4 = fd (-1)
            WriteMovImm64(FCode, X4, High(UInt64));  // -1 as unsigned
            // X5 = offset (0)
            WriteMovImm64(FCode, X5, 0);
            // Syscall number (different register for Linux vs macOS)
            if FTargetOS = atmacOS then
              WriteMovImm64(FCode, X16, MACOS_SYS_mmap)
            else
              WriteMovImm64(FCode, X8, SYS_mmap);
            WriteSyscallInsn;
            // Result (pointer) is now in X0, store to Dest temp slot
            slotIdx := localCnt + instr.Dest;
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
          
        irFree:
          begin
            // Heap deallocation: free(Src1)
            // munmap(addr, length) - but we don't track sizes, so skip for now
            // TODO: Track allocation sizes for proper munmap
            // This causes a memory leak but prevents crashes
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
        
        // ========== Float Operations ==========
        
        irConstFloat:
          begin
            // Float constants are stored in data section
            // For now, we only support 64-bit doubles
            slotIdx := localCnt + instr.Dest;
            // Emit the float value to data section (temporarily, will be patched)
            // For now, load the float bits from ImmFloat
            // Use X0 as temporary, then store to slot
            // We'll use a simpler approach: convert bits to UInt64
            WriteMovImm64(FCode, X0, PUInt64(@instr.ImmFloat)^);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFAdd:
          begin
            slotIdx := localCnt + instr.Dest;
            // Load first operand (stored as double in stack slot)
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            // Load second operand
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            // Move to FP registers
            WriteFmovD(FCode, V0, X0);  // V0 = X0 bits
            WriteFmovD(FCode, V1, X1);  // V1 = X1 bits
            // Add: V0 = V0 + V1
            WriteFaddD(FCode, V0, V0, V1);
            // Move result back to general register
            WriteFmovD(FCode, X0, V0);  // X0 = V0 bits
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFSub:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteFmovD(FCode, V0, X0);
            WriteFmovD(FCode, V1, X1);
            // Subtract: V0 = V0 - V1
            WriteFsubD(FCode, V0, V0, V1);
            WriteFmovD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFMul:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteFmovD(FCode, V0, X0);
            WriteFmovD(FCode, V1, X1);
            // Multiply: V0 = V0 * V1
            WriteFmulD(FCode, V0, V0, V1);
            WriteFmovD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFDiv:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            WriteFmovD(FCode, V0, X0);
            WriteFmovD(FCode, V1, X1);
            // Divide: V0 = V0 / V1
            WriteFdivD(FCode, V0, V0, V1);
            WriteFmovD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFNeg:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteFmovD(FCode, V0, X0);
            // Negate: V0 = -V0
            WriteFnegD(FCode, V0, V0);
            WriteFmovD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
          begin
            slotIdx := localCnt + instr.Dest;
            // Load operands
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteLdrImm(FCode, X1, X29, frameSize + SlotOffset(localCnt + instr.Src2));
            // Move to FP registers
            WriteFmovD(FCode, V0, X0);
            WriteFmovD(FCode, V1, X1);
            // Compare
            WriteFcmpD(FCode, V0, V1);
            // Set result based on condition
            case instr.Op of
              irFCmpEq:  WriteCset(FCode, X0, COND_EQ);
              irFCmpNeq: WriteCset(FCode, X0, COND_NE);
              irFCmpLt:  WriteCset(FCode, X0, COND_LT);
              irFCmpLe:  WriteCset(FCode, X0, COND_LE);
              irFCmpGt:  WriteCset(FCode, X0, COND_GT);
              irFCmpGe:  WriteCset(FCode, X0, COND_GE);
            end;
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irFToI:
          begin
            // Convert float to integer
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteFmovD(FCode, V0, X0);
            // Convert to signed integer (truncates towards zero)
            WriteFcvtzsD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
          end;
        
        irIToF:
          begin
            // Convert integer to float
            slotIdx := localCnt + instr.Dest;
            WriteLdrImm(FCode, X0, X29, frameSize + SlotOffset(localCnt + instr.Src1));
            WriteFmovD(FCode, V0, X0);
            // Convert to float
            WriteScvtfD(FCode, V0, V0);
            WriteFmovD(FCode, X0, V0);
            WriteStrImm(FCode, X0, X29, frameSize + SlotOffset(slotIdx));
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
  
// Phase 7: Patch global variable addresses (ADRP + ADD)
  for i := 0 to High(FGlobalVarLeaPatches) do
  begin
    patchPos := FGlobalVarLeaPatches[i].CodePos;
    varIdx := FGlobalVarLeaPatches[i].VarIndex;
    if (varIdx >= 0) and (varIdx < Length(FGlobalVarOffsets)) then
    begin
      strOffset := FGlobalVarOffsets[varIdx];
      instrVA := codeVA + UInt64(patchPos);
      
      if FGlobalVarLeaPatches[i].IsAdrp then
      begin
        // ADRP: PC-relative page address
        // Calculate page offset
        disp := Int32((dataVA + strOffset) - (instrVA and not UInt64($FFF)));
        // ADRP: 1 immlo[1:0] 10000 immhi[18:0] Rd
        // Read original instruction to get Rd (bits 4:0)
        origInstr := FCode.ReadU32LE(patchPos);
        rd := origInstr and $1F;  // Extract Rd from original
        
        FCode.PatchU32LE(patchPos, $90000000 or 
          (DWord((disp shr 12) and $3) shl 29) or 
          (DWord((Int64(disp) shr 14) and $7FFFF) shl 5) or
          rd);
      end
      else
      begin
        // ADD: immediate offset within page
        // disp = (dataVA + strOffset) and $FFF
        disp := Int32((dataVA + strOffset) and $FFF);
        // Read original instruction to get Rn (bits 9:5) and Rd (bits 4:0)
        origInstr := FCode.ReadU32LE(patchPos);
        rn := (origInstr shr 5) and $1F;  // Extract Rn
        rd := origInstr and $1F;          // Extract Rd
        
        FCode.PatchU32LE(patchPos, $91000000 or 
          (DWord(disp and $FFF) shl 10) or 
          (DWord(rn) shl 5) or 
          rd);
      end;
    end;
  end;
  
  // Phase 8: Patch random seed addresses (ADRP + ADD)
  if FRandomSeedAdded then
  begin
    for i := 0 to High(FRandomSeedLeaPatches) do
    begin
      patchPos := FRandomSeedLeaPatches[i];
      strOffset := FRandomSeedOffset;
      instrVA := codeVA + UInt64(patchPos);
      
      // Determine if this is ADRP or ADD based on even/odd index
      if (i mod 2) = 0 then
      begin
        // ADRP: PC-relative page address
        disp := Int32((dataVA + strOffset) - (instrVA and not UInt64($FFF)));
        origInstr := FCode.ReadU32LE(patchPos);
        rd := origInstr and $1F;
        FCode.PatchU32LE(patchPos, $90000000 or 
          (DWord((disp shr 12) and $3) shl 29) or 
          (DWord((Int64(disp) shr 14) and $7FFFF) shl 5) or
          rd);
      end
      else
      begin
        // ADD: immediate offset within page
        disp := Int32((dataVA + strOffset) and $FFF);
        origInstr := FCode.ReadU32LE(patchPos);
        rn := (origInstr shr 5) and $1F;
        rd := origInstr and $1F;
        FCode.PatchU32LE(patchPos, $91000000 or 
          (DWord(disp and $FFF) shl 10) or 
          (DWord(rn) shl 5) or 
          rd);
      end;
    end;
  end;
  
  // Phase 9: Generate PLT stubs for external symbols
  if Length(FExternalSymbols) > 0 then
  begin
    // ARM64 PLT/GOT Implementation using LDR (literal):
    // Each PLT stub is 8 bytes:
    //   ldr x17, <GOT_slot>  ; PC-relative load of resolved function address
    //   br  x17              ; Jump to resolved function
    //
    // The LDR imm19 offset is patched in Phase 11 once we know the GOT VA.
    // DT_BIND_NOW is used, so the dynamic linker resolves all GOT entries
    // before the program runs. PLT0 is never called and can be NOPs.

    // PLT0: two NOPs (never called with DT_BIND_NOW)
    FPLT0CodePos := FCode.Size;
    EmitInstr(FCode, $D503201F);  // NOP
    EmitInstr(FCode, $D503201F);  // NOP

    // Generate PLT entries for each external symbol (8 bytes each)
    for i := 0 to High(FExternalSymbols) do
    begin
      // Register PLT stub label
      SetLength(FLabelPositions, Length(FLabelPositions) + 1);
      FLabelPositions[High(FLabelPositions)].Name := '__plt_' + FExternalSymbols[i].Name;
      FLabelPositions[High(FLabelPositions)].Pos := FCode.Size;

      // Record patch position so Phase 11 can fill in the correct LDR offset
      SetLength(FPLTGOTPatches, Length(FPLTGOTPatches) + 1);
      FPLTGOTPatches[High(FPLTGOTPatches)].Pos := FCode.Size;
      FPLTGOTPatches[High(FPLTGOTPatches)].SymbolName := FExternalSymbols[i].Name;
      FPLTGOTPatches[High(FPLTGOTPatches)].SymbolIndex := i;
      FPLTGOTPatches[High(FPLTGOTPatches)].PLT0PushPos := 0;
      FPLTGOTPatches[High(FPLTGOTPatches)].PLT0JmpPos := 0;
      FPLTGOTPatches[High(FPLTGOTPatches)].PLT0VA := FPLT0CodePos;
      FPLTGOTPatches[High(FPLTGOTPatches)].GotVA := 0;  // patched in Phase 11

      // ldr x17, #0   (placeholder — imm19=0, patched in Phase 11)
      // LDR (literal) 64-bit: 0x58000000 | (imm19 << 5) | Rt
      EmitInstr(FCode, $58000011);  // ldr x17, #0  (placeholder)
      // br x17 = 0xD61F0000 | (17 << 5) = 0xD61F0220
      EmitInstr(FCode, $D61F0220);  // br x17
    end;
    
    // Now patch the calls to PLT stubs (BL __plt_<name>)
    for i := 0 to High(FCallPatches) do
    begin
      // Check if this call is to a PLT stub
      if Pos('__plt_', FCallPatches[i].TargetName) = 1 then
      begin
        // Find the PLT stub position
        targetFuncIdx := -1;
        for j := 0 to High(FLabelPositions) do
        begin
          if FLabelPositions[j].Name = FCallPatches[i].TargetName then
          begin
            targetFuncIdx := j;
            Break;
          end;
        end;
        
        if targetFuncIdx >= 0 then
        begin
          patchPos := FCallPatches[i].CodePos;
          targetPos := FLabelPositions[targetFuncIdx].Pos;
          branchOffset := targetPos - patchPos;
          // Patch BL instruction
          FCode.PatchU32LE(patchPos, $94000000 or DWord((branchOffset div 4) and $3FFFFFF));
        end;
      end;
    end;
  end;

  // Phase 10: Generate VMT tables for classes with virtual methods
  for i := 0 to High(module.ClassDecls) do
  begin
    if Length(module.ClassDecls[i].VirtualMethods) = 0 then
      Continue;

    // Register VMT label
    SetLength(FVMTLabels, Length(FVMTLabels) + 1);
    FVMTLabels[High(FVMTLabels)].Name := module.ClassDecls[i].VMTName;
    FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;

    // Emit VMT entries (8 bytes per virtual method)
    for j := 0 to High(module.ClassDecls[i].VirtualMethods) do
    begin
      // Record position for later patching
      SetLength(FVMTLeaPositions, Length(FVMTLeaPositions) + 1);
      FVMTLeaPositions[High(FVMTLeaPositions)].VMTIndex := i;
      FVMTLeaPositions[High(FVMTLeaPositions)].MethodIndex := j;
      FVMTLeaPositions[High(FVMTLeaPositions)].CodePos := FCode.Size;
      
      // Placeholder: will be patched with function address
      EmitInstr(FCode, 0);  // 8-byte placeholder (written as two 32-bit zeros)
      EmitInstr(FCode, 0);
    end;
  end;

  // Patch VMT entries with actual function addresses
  for i := 0 to High(FVMTLeaPositions) do
  begin
    vmtIdx := FVMTLeaPositions[i].VMTIndex;
    methodIdx := FVMTLeaPositions[i].MethodIndex;
    
    if (vmtIdx >= 0) and (vmtIdx <= High(module.ClassDecls)) then
    begin
      if (methodIdx >= 0) and (methodIdx <= High(module.ClassDecls[vmtIdx].VirtualMethods)) then
      begin
        mangledName := '_L_' + module.ClassDecls[vmtIdx].Name + '_' + module.ClassDecls[vmtIdx].VirtualMethods[methodIdx].Name;
        // Try to find function in label positions
        found := False;
        for j := 0 to High(FLabelPositions) do
        begin
          if FLabelPositions[j].Name = mangledName then
          begin
            // Write function address (relative to code start for PIE)
            FCode.PatchU64LE(FVMTLeaPositions[i].CodePos, UInt64(FLabelPositions[j].Pos));
            found := True;
            Break;
          end;
        end;
        // If not found (abstract method), leave as 0
      end;
    end;
  end;

  // Phase 11: Patch PLT LDR (literal) instructions with correct GOT offsets.
  // Now that all code is emitted we know the final code size, so we can
  // compute the exact GOT VA that the ELF writer will assign.
  // For macOS targets, WriteDynamicMachO64 patches the stubs with Mach-O GOT VAs.
  if (FTargetOS = atLinux) and (Length(FPLTGOTPatches) > 0) then
  begin
    gotBaseVA := ComputeExpectedGotVA(FExternalSymbols, FCode.Size, FData.Size);
    for i := 0 to High(FPLTGOTPatches) do
    begin
      ldrPos    := FPLTGOTPatches[i].Pos;
      gotSlotVA := gotBaseVA + 24 + UInt64(FPLTGOTPatches[i].SymbolIndex) * 8;
      stubVA    := $400000 + $1000 + UInt64(ldrPos);  // baseVA + codeOffset + pos
      wordOff   := Int64(gotSlotVA - stubVA) div 4;
      // LDR X17 (literal): 0x58000011 | (imm19[18:0] << 5)
      FCode.PatchU32LE(ldrPos, $58000011 or DWord(DWord(wordOff and $7FFFF) shl 5));
      FPLTGOTPatches[i].GotVA := gotSlotVA;
    end;
  end;

  // Patch VMT address loads (irLoadGlobalAddr with _vmt_ prefix)
  for i := 0 to High(FVMTAddrLeaPositions) do
  begin
    vmtLabelIdx := FVMTAddrLeaPositions[i].VMTLabelIndex;
    
    if (vmtLabelIdx >= 0) and (vmtLabelIdx < Length(FVMTLabels)) then
    begin
      // Calculate ADRP page-relative offset
      adrpPos := FVMTAddrLeaPositions[i].CodePos;
      targetPos := FVMTLabels[vmtLabelIdx].Pos;
      
      // ADRP computes: page(PC + imm21 << 12)
      // We need: (targetPage - PCPage) >> 12
      adrpPage := (adrpPos shr 12) shl 12;
      targetPage := (targetPos shr 12) shl 12;
      pageOffset := (targetPage - adrpPage) shr 12;
      
      // Patch ADRP imm21 (bits 29:5 of the instruction)
      FCode.PatchU32LE(adrpPos, $90000000 or (DWord((pageOffset and $1FFFFF)) shl 5));
      
      // Patch ADD imm12 (offset within page)
      addOffset := targetPos and $FFF;
      FCode.PatchU32LE(adrpPos + 4, $91000000 or (DWord(addOffset) shl 10));
    end;
  end;

end;

function TARM64Emitter.GetExternalSymbols: TExternalSymbolArray;
var
  i: Integer;
begin
  SetLength(Result, Length(FExternalSymbols));
  for i := 0 to High(FExternalSymbols) do
    Result[i] := FExternalSymbols[i];
end;

function TARM64Emitter.GetPLTGOTPatches: TPLTGOTPatchArray;
var
  i: Integer;
begin
  SetLength(Result, Length(FPLTGOTPatches));
  for i := 0 to High(FPLTGOTPatches) do
    Result[i] := FPLTGOTPatches[i];
end;

function TARM64Emitter.GetEnergyStats: TEnergyStats;
begin
  FEnergyStats.CodeSizeBytes := FCode.Size;
  FEnergyStats.L1CacheFootprint := EstimateL1CacheFootprint(FCode.Size);
  FEnergyStats.EstimatedEnergyUnits := FCurrentFunctionEnergy;
  FEnergyStats.TotalMemoryAccesses := FMemoryAccessCount;
  Result := FEnergyStats;
end;

procedure TARM64Emitter.SetEnergyLevel(level: TEnergyLevel);
begin
  energy_model.SetEnergyLevel(level, cfARM64);
  FEnergyContext.Config := GetEnergyConfig;
  FCurrentCPU := GetCPUEnergyModel(cfARM64);
  FEnergyContext.CurrentCPU := FCurrentCPU;
end;

end.
