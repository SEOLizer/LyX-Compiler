{$mode objfpc}{$H+}
unit x86_64_win64;

interface

uses
  SysUtils, Classes, Math, bytes, ir, pe64_writer, ast;

type
  // Emitter für Windows x64 Code Generation
  TWin64Emitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FImports: TImportDllArray;
    FIATPatches: TIATPatchArray;
    FKernel32Index: Integer;  // Index von kernel32.dll in FImports
    
    // IAT Indices für Builtins
    FGetStdHandleIndex: Integer;
    FWriteFileIndex: Integer;
    FExitProcessIndex: Integer;
    FVirtualAllocIndex: Integer;  // For heap allocation
    
    // Windows I/O API Indices
    FCreateFileAIndex: Integer;
    FReadFileIndex: Integer;
    FWriteFile2Index: Integer;
    FCloseHandleIndex: Integer;
    FSetFilePointerIndex: Integer;
    FDeleteFileAIndex: Integer;
    FMoveFileAIndex: Integer;
    FCreateDirectoryAIndex: Integer;
    FRemoveDirectoryAIndex: Integer;
    FSetFileAttributesAIndex: Integer;
    
    // Random LCG State (offset in .data)
    FRandomSeedOffset: Integer;
    
    // String/LEA patching
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;   // opcode start positions for LEA
    FLeaStrIndex: array of Integer;    // string offset within data buffer
    FGlobalVarLeaPositions: array of record
      VarIndex: Integer;
      CodePos: Integer;
    end;
    FGlobalVarOffsets: array of UInt64;

    // VMT Labels for OOP (Virtual Method Table)
    FVMTLabels: array of record
      Name: string;
      Pos: Integer;
    end;

    // Label positions for function/method addresses (for VMT patching)
    FLabelPositions: array of record
      Name: string;
      Pos: Integer;
    end;

    // Data-internal reference patches (for VMT method pointers and RTTI)
    FDataRefPatches: TDataRefPatchArray;

    // Label/Jump Patching (intra-function)
    FLabelMap: TStringList;  // label name -> code position (for current function)
    FBranchPatches: array of record
      CodePos: Integer;
      LabelName: string;
      JmpSize: Integer;  // 2 for short, 6 for near
    end;
    FCallPatches: array of record
      CodePos: Integer;
      TargetName: string;
    end;
    
    // Entry point offset (position of _start code)
    FEntryOffset: Integer;
    // Position of _start -> main call (for patching)
    FStartMainCallPos: Integer;
    
    // Function Info
    FFuncOffsets: array of Integer;
    
    procedure SetupKernel32Imports;
    function EmitPrologue(localBytes, paramCount: Integer): Integer;  // Returns actual frameBytes
    procedure EmitEpilogue(frameBytes: Integer);
    
    // Builtin-Stubs
    procedure EmitPrintStrStub;
    procedure EmitPrintIntStub;
    procedure EmitRandomStub;
    procedure EmitRandomSeedStub;
    procedure EmitExitStub;
    
    // Helper
    procedure AddIATPatch(codeOffset, dllIdx, funcIdx: Integer);
    procedure WriteIndirectCall(iatDllIdx, iatFuncIdx: Integer);
    
  public
    constructor Create;
    destructor Destroy; override;
    
    procedure EmitFromIR(const module: TIRModule);
    procedure WriteToFile(const filename: string);
    
    property CodeBuffer: TByteBuffer read FCode;
    property DataBuffer: TByteBuffer read FData;
  end;

// Utility procedures for x86_64 instruction encoding
procedure EmitU8(buf: TByteBuffer; v: Byte);
procedure EmitU32(buf: TByteBuffer; v: Cardinal);
procedure EmitU64(buf: TByteBuffer; v: UInt64);
procedure EmitRex(buf: TByteBuffer; w, r, x, b: Integer);

// Register constants
const
  RAX = 0; RCX = 1; RDX = 2; RBX = 3;
  RSP = 4; RBP = 5; RSI = 6; RDI = 7;
  R8 = 8; R9 = 9; R10 = 10; R11 = 11;
  R12 = 12; R13 = 13; R14 = 14; R15 = 15;

  // Windows x64 Parameter Registers (in order)
  Win64ParamRegs: array[0..3] of Byte = (RCX, RDX, R8, R9);

implementation

// ============================================================================
// Utility Procedures
// ============================================================================

procedure EmitU8(buf: TByteBuffer; v: Byte);
begin
  buf.WriteU8(v);
end;

procedure EmitU32(buf: TByteBuffer; v: Cardinal);
begin
  buf.WriteU32LE(v);
end;

procedure EmitU64(buf: TByteBuffer; v: UInt64);
begin
  buf.WriteU64LE(v);
end;

procedure EmitRex(buf: TByteBuffer; w, r, x, b: Integer);
var
  rex: Byte;
begin
  rex := $40 or (Byte(w and 1) shl 3) or (Byte(r and 1) shl 2) or
         (Byte(x and 1) shl 1) or Byte(b and 1);
  EmitU8(buf, rex);
end;

// MOV r64, imm64
procedure WriteMovRegImm64(buf: TByteBuffer; reg: Byte; imm: UInt64);
begin
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $B8 + (reg and 7));
  EmitU64(buf, imm);
end;

// MOV r/m64, r64 (register to register)
procedure WriteMovRegReg(buf: TByteBuffer; dst, src: Byte);
begin
  EmitRex(buf, 1, (src shr 3) and 1, 0, (dst shr 3) and 1);
  EmitU8(buf, $89);
  EmitU8(buf, $C0 or ((src and 7) shl 3) or (dst and 7));
end;

// MOV r64, [base + disp32]
procedure WriteMovRegMem(buf: TByteBuffer; reg, base: Byte; disp: Integer);
var
  modBits: Byte;
begin
  EmitRex(buf, 1, (reg shr 3) and 1, 0, (base shr 3) and 1);
  EmitU8(buf, $8B);
  
  if (disp >= -128) and (disp <= 127) then
    modBits := $40
  else
    modBits := $80;
  
  EmitU8(buf, modBits or ((reg and 7) shl 3) or (base and 7));
  
  // SIB byte for RSP-based addressing
  if (base and 7) = 4 then
    EmitU8(buf, $24);
  
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

// MOV [base + disp32], r64
procedure WriteMovMemReg(buf: TByteBuffer; base: Byte; disp: Integer; reg: Byte);
var
  modBits: Byte;
begin
  EmitRex(buf, 1, (reg shr 3) and 1, 0, (base shr 3) and 1);
  EmitU8(buf, $89);
  
  if (disp >= -128) and (disp <= 127) then
    modBits := $40
  else
    modBits := $80;
  
  EmitU8(buf, modBits or ((reg and 7) shl 3) or (base and 7));
  
  if (base and 7) = 4 then
    EmitU8(buf, $24);
  
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

// MOV r32, imm32
procedure WriteMovReg32Imm32(buf: TByteBuffer; reg: Byte; imm: Cardinal);
begin
  if reg >= 8 then
    EmitU8(buf, $41);  // REX.B
  EmitU8(buf, $B8 + (reg and 7));
  EmitU32(buf, imm);
end;

// XOR r64, r64
procedure WriteXorRegReg(buf: TByteBuffer; dst, src: Byte);
begin
  EmitRex(buf, 1, (src shr 3) and 1, 0, (dst shr 3) and 1);
  EmitU8(buf, $31);
  EmitU8(buf, $C0 or ((src and 7) shl 3) or (dst and 7));
end;

// ADD r64, r64
procedure WriteAddRegReg(buf: TByteBuffer; dst, src: Byte);
begin
  EmitRex(buf, 1, (src shr 3) and 1, 0, (dst shr 3) and 1);
  EmitU8(buf, $01);
  EmitU8(buf, $C0 or ((src and 7) shl 3) or (dst and 7));
end;

// SUB r64, imm32
procedure WriteSubRegImm32(buf: TByteBuffer; reg: Byte; imm: Cardinal);
begin
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $81);
  EmitU8(buf, $E8 or (reg and 7));
  EmitU32(buf, imm);
end;

// ADD r64, imm32
procedure WriteAddRegImm32(buf: TByteBuffer; reg: Byte; imm: Cardinal);
begin
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $81);
  EmitU8(buf, $C0 or (reg and 7));
  EmitU32(buf, imm);
end;

// LEA r64, [base + disp32]
procedure WriteLeaRegMem(buf: TByteBuffer; reg, base: Byte; disp: Integer);
var
  modBits: Byte;
begin
  EmitRex(buf, 1, (reg shr 3) and 1, 0, (base shr 3) and 1);
  EmitU8(buf, $8D);
  
  if (disp >= -128) and (disp <= 127) then
    modBits := $40
  else
    modBits := $80;
  
  EmitU8(buf, modBits or ((reg and 7) shl 3) or (base and 7));
  
  if (base and 7) = 4 then
    EmitU8(buf, $24);
  
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

// PUSH r64
procedure WritePush(buf: TByteBuffer; reg: Byte);
begin
  if reg >= 8 then
    EmitU8(buf, $41);
  EmitU8(buf, $50 + (reg and 7));
end;

// POP r64
procedure WritePop(buf: TByteBuffer; reg: Byte);
begin
  if reg >= 8 then
    EmitU8(buf, $41);
  EmitU8(buf, $58 + (reg and 7));
end;

// RET
procedure WriteRet(buf: TByteBuffer);
begin
  EmitU8(buf, $C3);
end;

// CALL rel32
procedure WriteCallRel32(buf: TByteBuffer; rel32: Integer);
begin
  EmitU8(buf, $E8);
  EmitU32(buf, Cardinal(rel32));
end;

// JMP rel32
procedure WriteJmpRel32(buf: TByteBuffer; rel32: Integer);
begin
  EmitU8(buf, $E9);
  EmitU32(buf, Cardinal(rel32));
end;

// CMP byte [reg], imm8
procedure WriteCmpBytePtrImm8(buf: TByteBuffer; reg: Byte; imm: Byte);
begin
  if reg >= 8 then
    EmitU8(buf, $41);
  EmitU8(buf, $80);
  EmitU8(buf, $38 or (reg and 7));
  EmitU8(buf, imm);
end;

// JE rel32
procedure WriteJeRel32(buf: TByteBuffer; rel32: Integer);
begin
  EmitU8(buf, $0F);
  EmitU8(buf, $84);
  EmitU32(buf, Cardinal(rel32));
end;

// JNE rel8
procedure WriteJneRel8(buf: TByteBuffer; rel8: ShortInt);
begin
  EmitU8(buf, $75);
  EmitU8(buf, Byte(rel8));
end;

// JNE rel32
procedure WriteJneRel32(buf: TByteBuffer; rel32: Integer);
begin
  EmitU8(buf, $0F);
  EmitU8(buf, $85);
  EmitU32(buf, Cardinal(rel32));
end;

// INC r64
procedure WriteIncReg(buf: TByteBuffer; reg: Byte);
begin
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $FF);
  EmitU8(buf, $C0 or (reg and 7));
end;

procedure WriteDecReg(buf: TByteBuffer; reg: Byte);
begin
  // dec r64: REX.W(+B) FF C8+reg
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $FF); EmitU8(buf, $C8 or (reg and $7));
end;

procedure WriteSubRegReg(buf: TByteBuffer; dst, src: Byte);
var rexR, rexB: Integer;
begin
  // sub r/m64, r64 : REX.W + 29 /r
  rexR := (src shr 3) and 1;
  rexB := (dst shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $29);
  EmitU8(buf, $C0 or (((src and 7) shl 3) and $38) or (dst and $7));
end;

procedure WriteImulRegReg(buf: TByteBuffer; dst, src: Byte);
var rexR, rexB: Integer;
begin
  // imul r64, r/m64 : REX.W 0F AF /r  (reg=dst, rm=src)
  rexR := (dst shr 3) and 1;
  rexB := (src shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $0F);
  EmitU8(buf, $AF);
  EmitU8(buf, $C0 or (((dst and 7) shl 3) and $38) or (src and $7));
end;

procedure WriteCqo(buf: TByteBuffer); begin EmitU8(buf,$48); EmitU8(buf,$99); end;

procedure WriteIdivReg(buf: TByteBuffer; src: Byte);
var rexB: Integer;
begin
  // idiv r/m64 : REX.W + F7 /7 ; modrm = 0xF8 | rm (with mod=11)
  rexB := (src shr 3) and 1;
  EmitRex(buf, 1, 0, 0, rexB);
  EmitU8(buf, $F7);
  EmitU8(buf, $F8 or (src and $7));
end;

procedure WriteTestRaxRax(buf: TByteBuffer); begin EmitU8(buf,$48); EmitU8(buf,$85); EmitU8(buf,$C0); end;

procedure WriteTestRegReg(buf: TByteBuffer; r1, r2: Byte);
var rexR, rexB: Integer;
begin
  rexR := (r1 shr 3) and 1;
  rexB := (r2 shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $85);
  EmitU8(buf, $C0 or (((r1 and 7) shl 3) and $38) or (r2 and $7));
end;

procedure WriteMovMemRegByte(buf: TByteBuffer; base: Byte; disp: Integer; reg8: Byte);
begin
  // mov byte ptr [base + disp32], r8 -> 88 /0 with mod=10 (disp32)
  EmitU8(buf, $88);
  EmitU8(buf, $80 or ((reg8 and $7) shl 3) or (base and $7));
  EmitU32(buf, Cardinal(disp));
end;

procedure WriteMovMemRegByteNoDisp(buf: TByteBuffer; base: Byte; reg8: Byte);
begin
  // mov byte ptr [base], r8 -> 88 /0 with mod=00 and rm=base
  EmitU8(buf, $88);
  EmitU8(buf, ((reg8 and $7) shl 3) or (base and $7));
end;

procedure WriteMovMemImm8(buf: TByteBuffer; base: Byte; disp: Integer; value: Byte);
begin
  // mov byte ptr [base+disp32], imm8 => C6 80 disp32 imm8
  EmitU8(buf, $C6);
  EmitU8(buf, $80 or (base and $7));
  EmitU32(buf, Cardinal(disp));
  EmitU8(buf, value);
end;

procedure WriteSetccMem8(buf: TByteBuffer; ccOpcode: Byte; baseReg: Byte; disp32: Integer);
begin
  // setcc r/m8 : opcode 0F ccOpcode modrm(mod=10) rm=base
  EmitU8(buf, $0F);
  EmitU8(buf, ccOpcode);
  EmitU8(buf, $80 or ((0 shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovzxRegMem8(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movzx r64, r/m8 : rex.w 0F B6 /r with reg=dst, rm=mem
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $B6);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovzxRegMem16(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movzx r64, r/m16 : rex.w 0F B7 /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $B7);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem8(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsx r64, r/m8 : rex.w 0F BE /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $BE);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem16(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsx r64, r/m16 : rex.w 0F BF /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $BF);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem32(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsxd r64, r/m32 : rex.w 63 /r
  EmitU8(buf, $48);
  EmitU8(buf, $63);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovEAXMem32(buf: TByteBuffer; baseReg: Byte; disp32: Integer);
begin
  // mov eax, dword ptr [base+disp32] : 8B 80 disp32
  EmitU8(buf, $8B);
  EmitU8(buf, $80 or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

// === SSE2 Float-Instruktionen (f64 / double) ===
const
  XMM0 = 0; XMM1 = 1; XMM2 = 2; XMM3 = 3;
  XMM4 = 4; XMM5 = 5; XMM6 = 6; XMM7 = 7;

// movsd xmm, [base+disp32]
procedure WriteMovsdLoad(buf: TByteBuffer; xmm, base: Byte; disp: Integer);
var modBits: Byte;
begin
  EmitU8(buf, $F2);
  if ((xmm shr 3) <> 0) or ((base shr 3) <> 0) then
    EmitU8(buf, $40 or ((xmm shr 3) and 1) shl 2 or ((base shr 3) and 1));
  EmitU8(buf, $0F); EmitU8(buf, $10);
  if (disp >= -128) and (disp <= 127) then modBits := $40
  else modBits := $80;
  EmitU8(buf, modBits or ((xmm and 7) shl 3) or (base and 7));
  if (base and 7) = 4 then EmitU8(buf, $24);
  if modBits = $40 then EmitU8(buf, Byte(disp))
  else EmitU32(buf, Cardinal(disp));
end;

// movsd [base+disp32], xmm
procedure WriteMovsdStore(buf: TByteBuffer; base: Byte; disp: Integer; xmm: Byte);
var modBits: Byte;
begin
  EmitU8(buf, $F2);
  if ((xmm shr 3) <> 0) or ((base shr 3) <> 0) then
    EmitU8(buf, $40 or ((xmm shr 3) and 1) shl 2 or ((base shr 3) and 1));
  EmitU8(buf, $0F); EmitU8(buf, $11);
  if (disp >= -128) and (disp <= 127) then modBits := $40
  else modBits := $80;
  EmitU8(buf, modBits or ((xmm and 7) shl 3) or (base and 7));
  if (base and 7) = 4 then EmitU8(buf, $24);
  if modBits = $40 then EmitU8(buf, Byte(disp))
  else EmitU32(buf, Cardinal(disp));
end;

// addsd xmm0, xmm1
procedure WriteAddsd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $F2); EmitU8(buf, $0F); EmitU8(buf, $58);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// subsd xmm0, xmm1
procedure WriteSubsd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $F2); EmitU8(buf, $0F); EmitU8(buf, $5C);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// mulsd xmm0, xmm1
procedure WriteMulsd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $F2); EmitU8(buf, $0F); EmitU8(buf, $59);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// divsd xmm0, xmm1
procedure WriteDivsd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $F2); EmitU8(buf, $0F); EmitU8(buf, $5E);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// xorpd xmm, xmm
procedure WriteXorpd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $66); EmitU8(buf, $0F); EmitU8(buf, $57);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// ucomisd xmm0, xmm1
procedure WriteUcomisd(buf: TByteBuffer; dst, src: Byte);
begin
  EmitU8(buf, $66); EmitU8(buf, $0F); EmitU8(buf, $2E);
  EmitU8(buf, $C0 or ((dst and 7) shl 3) or (src and 7));
end;

// cvtsi2sd xmm, r64
procedure WriteCvtsi2sd(buf: TByteBuffer; xmm, gpr: Byte);
begin
  EmitU8(buf, $F2);
  EmitRex(buf, 1, (xmm shr 3) and 1, 0, (gpr shr 3) and 1);
  EmitU8(buf, $0F); EmitU8(buf, $2A);
  EmitU8(buf, $C0 or ((xmm and 7) shl 3) or (gpr and 7));
end;

// cvttsd2si r64, xmm
procedure WriteCvttsd2si(buf: TByteBuffer; gpr, xmm: Byte);
begin
  EmitU8(buf, $F2);
  EmitRex(buf, 1, (gpr shr 3) and 1, 0, (xmm shr 3) and 1);
  EmitU8(buf, $0F); EmitU8(buf, $2C);
  EmitU8(buf, $C0 or ((gpr and 7) shl 3) or (xmm and 7));
end;

// Calculate stack slot offset
function SlotOffset(slot: Integer): Integer;
begin
  Result := -8 * (slot + 1);
end;

// ============================================================================
// TWin64Emitter
// ============================================================================

constructor TWin64Emitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  FLabelMap := TStringList.Create;
  SetLength(FImports, 0);
  SetLength(FIATPatches, 0);
  FKernel32Index := -1;
  FGetStdHandleIndex := -1;
  FWriteFileIndex := -1;
  FExitProcessIndex := -1;
  FVirtualAllocIndex := -1;
  // Windows I/O API
  FCreateFileAIndex := -1;
  FReadFileIndex := -1;
  FWriteFile2Index := -1;
  FCloseHandleIndex := -1;
  FSetFilePointerIndex := -1;
  FDeleteFileAIndex := -1;
  FMoveFileAIndex := -1;
  FCreateDirectoryAIndex := -1;
  FRemoveDirectoryAIndex := -1;
  FSetFileAttributesAIndex := -1;
  FRandomSeedOffset := -1;
  FEntryOffset := 0;
  FStartMainCallPos := 0;
  SetLength(FDataRefPatches, 0);
end;

destructor TWin64Emitter.Destroy;
begin
  FLabelMap.Free;
  FCode.Free;
  FData.Free;
  inherited Destroy;
end;

procedure TWin64Emitter.SetupKernel32Imports;
var
  kernelDll: TImportDll;
begin
  // Setup kernel32.dll imports
  kernelDll.DllName := 'kernel32.dll';
  SetLength(kernelDll.Functions, 13);
  
  kernelDll.Functions[0].Name := 'GetStdHandle';
  kernelDll.Functions[0].Hint := 0;
  FGetStdHandleIndex := 0;
  
  kernelDll.Functions[1].Name := 'WriteFile';
  kernelDll.Functions[1].Hint := 0;
  FWriteFileIndex := 1;
  FWriteFile2Index := 1;  // Gleiche Funktion, gleicher Import-Slot
  
  kernelDll.Functions[2].Name := 'ExitProcess';
  kernelDll.Functions[2].Hint := 0;
  FExitProcessIndex := 2;
  
  kernelDll.Functions[3].Name := 'VirtualAlloc';
  kernelDll.Functions[3].Hint := 0;
  FVirtualAllocIndex := 3;
  
  // Windows I/O API
  kernelDll.Functions[4].Name := 'CreateFileA';
  kernelDll.Functions[4].Hint := 0;
  FCreateFileAIndex := 4;
  
  kernelDll.Functions[5].Name := 'ReadFile';
  kernelDll.Functions[5].Hint := 0;
  FReadFileIndex := 5;
  
  kernelDll.Functions[6].Name := 'CloseHandle';
  kernelDll.Functions[6].Hint := 0;
  FCloseHandleIndex := 6;
  
  kernelDll.Functions[7].Name := 'SetFilePointer';
  kernelDll.Functions[7].Hint := 0;
  FSetFilePointerIndex := 7;
  
  kernelDll.Functions[8].Name := 'DeleteFileA';
  kernelDll.Functions[8].Hint := 0;
  FDeleteFileAIndex := 8;
  
  kernelDll.Functions[9].Name := 'MoveFileA';
  kernelDll.Functions[9].Hint := 0;
  FMoveFileAIndex := 9;
  
  kernelDll.Functions[10].Name := 'CreateDirectoryA';
  kernelDll.Functions[10].Hint := 0;
  FCreateDirectoryAIndex := 10;
  
  kernelDll.Functions[11].Name := 'RemoveDirectoryA';
  kernelDll.Functions[11].Hint := 0;
  FRemoveDirectoryAIndex := 11;
  
  kernelDll.Functions[12].Name := 'SetFileAttributesA';
  kernelDll.Functions[12].Hint := 0;
  FSetFileAttributesAIndex := 12;
  
  SetLength(FImports, 1);
  FImports[0] := kernelDll;
  FKernel32Index := 0;
end;

procedure TWin64Emitter.AddIATPatch(codeOffset, dllIdx, funcIdx: Integer);
var
  n: Integer;
begin
  n := Length(FIATPatches);
  SetLength(FIATPatches, n + 1);
  FIATPatches[n].CodeOffset := codeOffset;
  FIATPatches[n].DllIndex := dllIdx;
  FIATPatches[n].FuncIndex := funcIdx;
end;

procedure TWin64Emitter.WriteIndirectCall(iatDllIdx, iatFuncIdx: Integer);
begin
  // call [rip + disp32]
  // FF 15 xx xx xx xx
  // The displacement will be patched later
  EmitU8(FCode, $FF);
  EmitU8(FCode, $15);
  AddIATPatch(FCode.Size, iatDllIdx, iatFuncIdx);
  EmitU32(FCode, 0);  // Placeholder
end;

function TWin64Emitter.EmitPrologue(localBytes, paramCount: Integer): Integer;
var
  frameBytes, framePad: Integer;
  k: Integer;
begin
  // push rbp
  WritePush(FCode, RBP);
  // mov rbp, rsp
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  
  // Push non-volatile registers (Win64: RBX, RDI, RSI, R12-R15)
  WritePush(FCode, RBX);
  WritePush(FCode, RDI);
  WritePush(FCode, RSI);
  WritePush(FCode, R12);
  WritePush(FCode, R13);
  WritePush(FCode, R14);
  WritePush(FCode, R15);
  
  // Calculate frame size
  // After 8 pushes (rbp + 7 regs): 64 bytes
  // Need 32 bytes shadow space for any calls we make
  frameBytes := localBytes + 32;
  // Align to 16 bytes (considering 64 bytes already pushed)
  framePad := (16 - (frameBytes mod 16)) mod 16;
  frameBytes := frameBytes + framePad;
  
  if frameBytes > 0 then
    WriteSubRegImm32(FCode, RSP, frameBytes);
  
  // Spill parameters from registers to stack
  for k := 0 to Min(paramCount - 1, 3) do
    WriteMovMemReg(FCode, RBP, SlotOffset(k), Win64ParamRegs[k]);
    
  Result := frameBytes;  // Return actual frame size for epilogue
end;

procedure TWin64Emitter.EmitEpilogue(frameBytes: Integer);
begin
  // Restore stack
  if frameBytes > 0 then
    WriteAddRegImm32(FCode, RSP, frameBytes);
  
  // Pop non-volatile registers (reverse order)
  WritePop(FCode, R15);
  WritePop(FCode, R14);
  WritePop(FCode, R13);
  WritePop(FCode, R12);
  WritePop(FCode, RSI);
  WritePop(FCode, RDI);
  WritePop(FCode, RBX);
  
  // pop rbp
  WritePop(FCode, RBP);
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitPrintStrStub;
var
  strlenLoopStart, strlenLoopEnd: Integer;
begin
  // _L_PrintStr: Print null-terminated string
  // Input: RCX = pchar
  // Uses: GetStdHandle, WriteFile
  
  // Save non-volatiles and set up frame
  WritePush(FCode, RBP);
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  WritePush(FCode, RBX);
  WritePush(FCode, RDI);
  WritePush(FCode, RSI);
  
  // sub rsp, 64 (32 shadow + 8 for bytesWritten + padding)
  WriteSubRegImm32(FCode, RSP, 64);
  
  // Save string pointer in RBX
  WriteMovRegReg(FCode, RBX, RCX);
  
  // strlen: count characters until null
  WriteXorRegReg(FCode, RDI, RDI);  // RDI = 0 (counter)
  
  strlenLoopStart := FCode.Size;
  // cmp byte [rbx + rdi], 0
  // No REX needed: RBX=3, RDI=7 are both in low 8 registers
  EmitU8(FCode, $80);  // cmp r/m8, imm8
  EmitU8(FCode, $3C);  // ModR/M: /7, mod=00, r/m=100 (SIB follows)
  EmitU8(FCode, $3B);  // SIB: scale=1, index=RDI(7), base=RBX(3)
  EmitU8(FCode, $00);  // imm8 = 0
  
  // je strlen_done (forward jump, patch later)
  EmitU8(FCode, $74);
  strlenLoopEnd := FCode.Size;
  EmitU8(FCode, $00);  // Placeholder
  
  // inc rdi
  WriteIncReg(FCode, RDI);
  
  // jmp strlen_loop
  WriteJmpRel32(FCode, strlenLoopStart - (FCode.Size + 5));
  
  // strlen_done:
  FCode.PatchU8(strlenLoopEnd, FCode.Size - strlenLoopEnd - 1);
  
  // Save length in RSI
  WriteMovRegReg(FCode, RSI, RDI);
  
  // GetStdHandle(STD_OUTPUT_HANDLE = -11)
  WriteMovReg32Imm32(FCode, RCX, $FFFFFFF5);  // -11 as unsigned
  WriteIndirectCall(FKernel32Index, FGetStdHandleIndex);
  
  // WriteFile(hFile=RAX, lpBuffer=RBX, nBytes=RSI, lpWritten=[rsp+48], lpOverlapped=0)
  WriteMovRegReg(FCode, RCX, RAX);   // hFile
  WriteMovRegReg(FCode, RDX, RBX);   // lpBuffer
  WriteMovRegReg(FCode, R8, RSI);    // nNumberOfBytesToWrite
  WriteLeaRegMem(FCode, R9, RSP, 48); // lpNumberOfBytesWritten
  // mov qword [rsp+32], 0 (5th param: lpOverlapped)
  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $44);
  EmitU8(FCode, $24); EmitU8(FCode, $20); EmitU32(FCode, 0);
  WriteIndirectCall(FKernel32Index, FWriteFileIndex);
  
  // Cleanup and return
  WriteAddRegImm32(FCode, RSP, 64);
  WritePop(FCode, RSI);
  WritePop(FCode, RDI);
  WritePop(FCode, RBX);
  WritePop(FCode, RBP);
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitPrintIntStub;
var
  loopStart, doneCheck: Integer;
  negJump, revLoopStart, revDone: Integer;
begin
  // _L_PrintInt: Print int64 as decimal
  // Input: RCX = int64 value
  
  WritePush(FCode, RBP);
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  WritePush(FCode, RBX);
  WritePush(FCode, RDI);
  WritePush(FCode, RSI);
  WritePush(FCode, R12);
  
  // sub rsp, 96 (32 shadow + 32 buffer + padding)
  WriteSubRegImm32(FCode, RSP, 96);
  
  // Save value
  WriteMovRegReg(FCode, R12, RCX);
  
  // Handle negative numbers
  // test rcx, rcx
  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C9);
  // jns positive
  EmitU8(FCode, $79);
  negJump := FCode.Size;
  EmitU8(FCode, $00);
  
  // neg rcx
  EmitU8(FCode, $48); EmitU8(FCode, $F7); EmitU8(FCode, $D9);
  // Save negated value
  WriteMovRegReg(FCode, R12, RCX);
  
  // Print minus sign
  // mov byte [rsp+64], '-'
  EmitU8(FCode, $C6); EmitU8(FCode, $44); EmitU8(FCode, $24);
  EmitU8(FCode, $40); EmitU8(FCode, $2D);
  // mov byte [rsp+65], 0
  EmitU8(FCode, $C6); EmitU8(FCode, $44); EmitU8(FCode, $24);
  EmitU8(FCode, $41); EmitU8(FCode, $00);
  // lea rcx, [rsp+64]
  WriteLeaRegMem(FCode, RCX, RSP, 64);
  // Call PrintStr (recursively - need to emit this carefully)
  // For now, we'll print minus inline using WriteFile
  WriteMovReg32Imm32(FCode, RCX, $FFFFFFF5);
  WriteIndirectCall(FKernel32Index, FGetStdHandleIndex);
  WriteMovRegReg(FCode, RCX, RAX);
  WriteLeaRegMem(FCode, RDX, RSP, 64);
  WriteMovRegImm64(FCode, R8, 1);
  WriteLeaRegMem(FCode, R9, RSP, 56);
  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $44);
  EmitU8(FCode, $24); EmitU8(FCode, $20); EmitU32(FCode, 0);
  WriteIndirectCall(FKernel32Index, FWriteFileIndex);
  WriteMovRegReg(FCode, RCX, R12);
  
  // positive:
  FCode.PatchU8(negJump, FCode.Size - negJump - 1);
  
  // itoa algorithm: divide by 10, store remainders, then reverse
  // Use buffer at [rsp+64..95]
  WriteMovRegReg(FCode, RAX, RCX);  // Value to convert
  WriteXorRegReg(FCode, RDI, RDI);   // Buffer index
  
  // mov r10, 10
  WriteMovRegImm64(FCode, R10, 10);
  
  loopStart := FCode.Size;
  // xor rdx, rdx
  WriteXorRegReg(FCode, RDX, RDX);
  // div r10 (rax = quotient, rdx = remainder)
  EmitU8(FCode, $49); EmitU8(FCode, $F7); EmitU8(FCode, $F2);
  // add dl, '0'
  EmitU8(FCode, $80); EmitU8(FCode, $C2); EmitU8(FCode, $30);
  // mov [rsp+64+rdi], dl
  EmitU8(FCode, $88); EmitU8(FCode, $54); EmitU8(FCode, $3C); EmitU8(FCode, $40);
  // inc rdi
  WriteIncReg(FCode, RDI);
  // test rax, rax
  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
  // jnz loop
  EmitU8(FCode, $75);
  EmitU8(FCode, Byte(loopStart - FCode.Size - 1));
  
  // Now reverse the string [rsp+64..rsp+64+rdi-1]
  // and print it
  // RDI = length
  WriteMovRegReg(FCode, RSI, RDI);  // Save length
  
  // Reverse in place
  WriteXorRegReg(FCode, RCX, RCX);  // i = 0
  // dec rdi (j = length - 1)
  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $CF);
  
  // while i < j
  revLoopStart := FCode.Size;
  // cmp rcx, rdi
  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $F9);
  // jge done
  EmitU8(FCode, $7D);
  revDone := FCode.Size;
  EmitU8(FCode, $00);
  
  // swap [rsp+64+rcx] and [rsp+64+rdi]
  // mov al, [rsp+64+rcx]
  EmitU8(FCode, $8A); EmitU8(FCode, $44); EmitU8(FCode, $0C); EmitU8(FCode, $40);
  // mov bl, [rsp+64+rdi]
  EmitU8(FCode, $8A); EmitU8(FCode, $5C); EmitU8(FCode, $3C); EmitU8(FCode, $40);
  // mov [rsp+64+rcx], bl
  EmitU8(FCode, $88); EmitU8(FCode, $5C); EmitU8(FCode, $0C); EmitU8(FCode, $40);
  // mov [rsp+64+rdi], al
  EmitU8(FCode, $88); EmitU8(FCode, $44); EmitU8(FCode, $3C); EmitU8(FCode, $40);
  // inc rcx
  WriteIncReg(FCode, RCX);
  // dec rdi
  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $CF);
  // jmp rev_loop
  WriteJmpRel32(FCode, revLoopStart - (FCode.Size + 5));
  
  FCode.PatchU8(revDone, FCode.Size - revDone - 1);
  
  // Print the reversed string
  WriteMovReg32Imm32(FCode, RCX, $FFFFFFF5);
  WriteIndirectCall(FKernel32Index, FGetStdHandleIndex);
  WriteMovRegReg(FCode, RCX, RAX);
  WriteLeaRegMem(FCode, RDX, RSP, 64);
  WriteMovRegReg(FCode, R8, RSI);  // length
  WriteLeaRegMem(FCode, R9, RSP, 56);
  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $44);
  EmitU8(FCode, $24); EmitU8(FCode, $20); EmitU32(FCode, 0);
  WriteIndirectCall(FKernel32Index, FWriteFileIndex);
  
  // Cleanup and return
  WriteAddRegImm32(FCode, RSP, 96);
  WritePop(FCode, R12);
  WritePop(FCode, RSI);
  WritePop(FCode, RDI);
  WritePop(FCode, RBX);
  WritePop(FCode, RBP);
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitRandomStub;
var
  seedPatchPos: Integer;
begin
  // _L_Random: Return pseudo-random int64 using LCG
  // LCG: seed = (seed * 1103515245 + 12345) mod 2^31
  // Returns: RAX = random value (0..2^31-1)
  
  WritePush(FCode, RBP);
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  
  // Load seed from data segment (will be patched with RIP-relative)
  // lea rax, [rip + seed_offset]
  // For now, we'll use a fixed offset that will be patched
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05);
  seedPatchPos := FCode.Size;
  EmitU32(FCode, 0);  // Will be patched
  
  // mov rax, [rax]
  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $00);
  
  // LCG calculation
  // imul rax, rax, 1103515245
  EmitU8(FCode, $48); EmitU8(FCode, $69); EmitU8(FCode, $C0);
  EmitU32(FCode, 1103515245);
  
  // add rax, 12345
  EmitU8(FCode, $48); EmitU8(FCode, $05);
  EmitU32(FCode, 12345);
  
  // and rax, 0x7FFFFFFF
  EmitU8(FCode, $48); EmitU8(FCode, $25);
  EmitU32(FCode, $7FFFFFFF);
  
  // Store new seed
  // mov rcx, rax
  WriteMovRegReg(FCode, RCX, RAX);
  // lea rdx, [rip + seed_offset]
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $15);
  EmitU32(FCode, 0);  // Will be patched (same offset)
  // mov [rdx], rcx
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $0A);
  
  WritePop(FCode, RBP);
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitRandomSeedStub;
begin
  // _L_RandomSeed: Set random seed
  // Input: RCX = seed value
  
  WritePush(FCode, RBP);
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  
  // lea rax, [rip + seed_offset]
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05);
  EmitU32(FCode, 0);  // Will be patched
  
  // mov [rax], rcx
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $08);
  
  WritePop(FCode, RBP);
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitExitStub;
begin
  // _L_Exit: Terminate process
  // Input: RCX = exit code
  
  // No prologue needed - ExitProcess doesn't return
  WriteIndirectCall(FKernel32Index, FExitProcessIndex);
  // Should never reach here, but add ret just in case
  WriteRet(FCode);
end;

procedure TWin64Emitter.EmitFromIR(const module: TIRModule);
var
  i, j, k, sidx: Integer;
  totalDataOffset: UInt64;
  instr: TIRInstr;
  localCnt, maxTemp, totalSlots, slotIdx: Integer;
  leaPos: Integer;
  disp32, rel32: Int64;
  stringByteOffsets: array of Integer;  // byte offsets for each string in data section
  tempStrIndex: array of Integer;
  bufferAdded: Boolean;
  bufferOffset: UInt64;
  bufferLeaPositions: array of Integer;
  envAdded: Boolean;
  envOffset: UInt64;
  envLeaPositions: array of Integer;
  randomSeedAdded: Boolean;
  randomSeedOffset: UInt64;
  randomSeedLeaPositions: array of Integer;
  globalVarNames: TStringList;
  globalVarOffsets: array of UInt64;
  cd: TAstClassDecl;  // for VMT emission
  method: TAstFuncDecl;  // for VMT patching
  methodAddr: Integer;
  methodLabelName: string;
  vmtDataPos: Integer;
  baseCd, nextBaseCd: TAstClassDecl;
  parentVmtPos, parentPtrPos, classNamePos, classNamePtrPos: Integer;
  // use emitter-level FGlobalVarLeaPositions field to collect patches
  nonZeroPos, jmpDonePos, jgePos, loopStartPos, jneLoopPos, jeSignPos: Integer;
  targetPos, jmpPos: Integer;
  jmpAfterPadPos: Integer;
  nextLabelPos, doneLabelPos, notFoundPos: Integer;
  argCount: Integer;
  argTemps: array of Integer;
  arg3: Integer;
  sParse: string;
  ppos, ai: Integer;
  extraCount: Integer;
  isEntryFunction: Boolean;
  structBaseOff: Int64;
  negOffset: Int64;
  frameBytes: Integer;
  framePad: Integer;
  callPad: Integer;
  allocSize: Integer;
  elemIndex: Integer;
  elemOffset: Integer;
  pushBytes: Integer;
  restoreBytes: Integer;
  mask64: UInt64;
  sh: Integer;
  varIdx: Integer;
  // Builtin stub offsets
  printStrOffset, printIntOffset, randomOffset, randomSeedOffsetStub: Integer;
  // Call patching temps
  callPos, foundIdx, targetOffsetInt, relInt: Integer;
  targetName: string;
  // Branch patching temps
  labelIdx, patchPos, jmpSize, relOffset: Integer;
begin
  // Prepare imports and builtin stubs
  SetupKernel32Imports;

  // write interned strings from module
  SetLength(tempStrIndex, 0);
  totalDataOffset := 0;
  SetLength(stringByteOffsets, 0);
  if Assigned(module) then
  begin
    SetLength(stringByteOffsets, module.Strings.Count);
    for i := 0 to module.Strings.Count - 1 do
    begin
      stringByteOffsets[i] := totalDataOffset; // store byte offset for this string
      for j := 1 to Length(module.Strings[i]) do
        FData.WriteU8(Byte(module.Strings[i][j]));
      FData.WriteU8(0);
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;

  // Reserve random seed
  randomSeedAdded := False;
  randomSeedOffset := 0;
  FRandomSeedOffset := FData.Size;
  FData.WriteU64LE(12345);
  Inc(totalDataOffset, 8);  // Account for random seed in data offset
  randomSeedAdded := True;
  randomSeedOffset := FRandomSeedOffset;

  // Emit builtin stubs and record their offsets
  printStrOffset := FCode.Size; EmitPrintStrStub;
  printIntOffset := FCode.Size; EmitPrintIntStub;
  randomOffset := FCode.Size; EmitRandomStub;
  randomSeedOffsetStub := FCode.Size; EmitRandomSeedStub;
  EmitExitStub;

  // Record entry point offset (after builtins, before _start code)
  FEntryOffset := FCode.Size;

  // Basic program entry (_start): set up stack for Win64 and call main
  // sub rsp, 40 (32-byte shadow + alignment)
  WriteSubRegImm32(FCode, RSP, 40);
  // call main (patched later)
  FStartMainCallPos := FCode.Size;
  WriteCallRel32(FCode, 0); // placeholder - will be patched after all functions emitted
  // mov rcx, rax (exit code)
  WriteMovRegReg(FCode, RCX, RAX);
  // call ExitProcess
  WriteIndirectCall(FKernel32Index, FExitProcessIndex);

  // If module is nil, emit simple demo main and return
  if not Assigned(module) then
  begin
    // emit a trivial main returning 0
    // push rbp; mov rbp,rsp; sub rsp,32; xor rax,rax; add rsp,32; pop rbp; ret
    WritePush(FCode, RBP); EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
    WriteSubRegImm32(FCode, RSP, 32);
    WriteXorRegReg(FCode, RAX, RAX);
    WriteAddRegImm32(FCode, RSP, 32);
    WritePop(FCode, RBP); WriteRet(FCode);
    Exit;
  end;

  // Initialize helpers for emit loop
  bufferAdded := False; bufferOffset := 0; SetLength(bufferLeaPositions, 0);
  envAdded := False; envOffset := 0; SetLength(envLeaPositions, 0);
  SetLength(randomSeedLeaPositions, 0);
  globalVarNames := TStringList.Create; globalVarNames.Sorted := False;
  SetLength(FGlobalVarOffsets, 0); SetLength(FGlobalVarLeaPositions, 0);

  // Pre-allocate global variables in data section
  for i := 0 to High(module.GlobalVars) do
  begin
    globalVarNames.Add(module.GlobalVars[i].Name);
    SetLength(FGlobalVarOffsets, globalVarNames.Count);
    FGlobalVarOffsets[High(FGlobalVarOffsets)] := totalDataOffset;
    if module.GlobalVars[i].IsArray then
    begin
      if module.GlobalVars[i].HasInitValue and (module.GlobalVars[i].ArrayLen > 0) then
      begin
        for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
          FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValues[j]));
        Inc(totalDataOffset, UInt64(8) * UInt64(module.GlobalVars[i].ArrayLen));
      end
      else
      begin
        if module.GlobalVars[i].ArrayLen > 0 then
        begin
          for j := 0 to module.GlobalVars[i].ArrayLen - 1 do
            FData.WriteU64LE(0);
          Inc(totalDataOffset, UInt64(8) * UInt64(module.GlobalVars[i].ArrayLen));
        end
        else
        begin
          FData.WriteU64LE(0); Inc(totalDataOffset, 8);
        end;
      end;
    end
    else
    begin
      if module.GlobalVars[i].HasInitValue then
        FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValue))
      else
        FData.WriteU64LE(0);
      Inc(totalDataOffset, 8);
    end;
  end;

  // Emit VMT tables for classes with virtual methods
  // VMT data is placed in CODE section to avoid relocation issues
  for i := 0 to High(module.ClassDecls) do
  begin
    cd := module.ClassDecls[i];
    // Only emit VMT if class has virtual methods
    if Length(cd.VirtualMethods) > 0 then
    begin
      // Emit class name string (for RTTI ClassName method)
      SetLength(FVMTLabels, Length(FVMTLabels) + 1);
      FVMTLabels[High(FVMTLabels)].Name := '_classname_' + cd.Name;
      FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;
      
      // Write class name as null-terminated string
      for j := 1 to Length(cd.Name) do
        FCode.WriteU8(Ord(cd.Name[j]));
      FCode.WriteU8(0);  // null terminator
      
      // Align to 8 bytes before RTTI header
      while (FCode.Size mod 8) <> 0 do
        FCode.WriteU8(0);
      
      // Emit RTTI header
      // 1. Parent VMT Pointer
      SetLength(FVMTLabels, Length(FVMTLabels) + 1);
      FVMTLabels[High(FVMTLabels)].Name := '_vmt_parent_' + cd.Name;
      FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;
      FCode.WriteU64LE(0);  // Placeholder
      
      // 2. ClassName Pointer
      SetLength(FVMTLabels, Length(FVMTLabels) + 1);
      FVMTLabels[High(FVMTLabels)].Name := '_vmt_classname_ptr_' + cd.Name;
      FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;
      FCode.WriteU64LE(0);  // Placeholder
      
      // 3. VMT base (where instance VMT pointers point to)
      SetLength(FVMTLabels, Length(FVMTLabels) + 1);
      FVMTLabels[High(FVMTLabels)].Name := '_vmt_' + cd.Name;
      FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;
      
      // Emit VMT entries (method pointers)
      for j := 0 to High(cd.VirtualMethods) do
      begin
        method := cd.VirtualMethods[j];
        // For methods without body, write FFFFFFFF as marker
        if Assigned(method) and Assigned(method.Body) and (Length(method.Body.Stmts) > 0) then
          FCode.WriteU64LE(0)  // Placeholder for patching
        else
          FCode.WriteU64LE($FFFFFFFFFFFFFFFF);  // Marker for unimplemented method
      end;
    end;
  end;

  // Main function emission: loop over functions in module
  for i := 0 to High(module.Functions) do
  begin
    // record function offset
    SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
    FFuncOffsets[High(FFuncOffsets)] := FCode.Size;
    
    // Record function label position for VMT patching
    SetLength(FLabelPositions, Length(FLabelPositions) + 1);
    FLabelPositions[High(FLabelPositions)].Name := module.Functions[i].Name;
    FLabelPositions[High(FLabelPositions)].Pos := FCode.Size;

    // record labels mapping by name -> pos using FFuncOffsets index
    // compute local slots
    localCnt := module.Functions[i].LocalCount;
    isEntryFunction := (module.Functions[i].Name = 'main');
    maxTemp := -1;
    for j := 0 to High(module.Functions[i].Instructions) do
    begin
      instr := module.Functions[i].Instructions[j];
      if instr.Dest > maxTemp then maxTemp := instr.Dest;
      if instr.Src1 > maxTemp then maxTemp := instr.Src1;
      if instr.Src2 > maxTemp then maxTemp := instr.Src2;
    end;
    if maxTemp < 0 then maxTemp := 0 else Inc(maxTemp);
    totalSlots := localCnt + maxTemp;
    if totalSlots < 0 then totalSlots := 0;
    if totalSlots > 1024 then totalSlots := 1024;

    // Reset label tracking for this function
    FLabelMap.Clear;
    SetLength(FBranchPatches, 0);

    // Prologue - returns actual frame size used
    frameBytes := EmitPrologue(totalSlots * 8, module.Functions[i].ParamCount);

    // Spill incoming parameters into slots
    if module.Functions[i].ParamCount > 0 then
    begin
      for k := 0 to module.Functions[i].ParamCount - 1 do
      begin
        slotIdx := k;
        if k < Length(Win64ParamRegs) then
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), Win64ParamRegs[k])
        else
        begin
          disp32 := 16 + (k - Length(Win64ParamRegs)) * 8;
          // load from caller stack area
          WriteMovRegMem(FCode, RAX, RBP, Integer(disp32));
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
        end;
      end;
    end;

    SetLength(tempStrIndex, maxTemp);
    for k := 0 to maxTemp - 1 do tempStrIndex[k] := -1;

    // Instruction loop
    for j := 0 to High(module.Functions[i].Instructions) do
    begin
      instr := module.Functions[i].Instructions[j];
      case instr.Op of
        irConstStr:
          begin
            slotIdx := localCnt + instr.Dest;
            leaPos := FCode.Size;
            // lea rax, [rip + imm32]
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
            SetLength(FLeaPositions, Length(FLeaPositions) + 1);
            SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
            FLeaPositions[High(FLeaPositions)] := leaPos;
            sidx := StrToIntDef(instr.ImmStr, 0);  // string index
            // Convert string index to byte offset using stringByteOffsets
            if (sidx >= 0) and (sidx < Length(stringByteOffsets)) then
              FLeaStrIndex[High(FLeaStrIndex)] := stringByteOffsets[sidx]
            else
              FLeaStrIndex[High(FLeaStrIndex)] := 0;
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irCallBuiltin:
          begin
            // map builtins to stub calls
            if instr.ImmStr = 'PrintStr' then
            begin
              // arg in slot Src1 -> RCX
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteCallRel32(FCode, printStrOffset - (FCode.Size + 5));
            end
            else if instr.ImmStr = 'PrintInt' then
            begin
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteCallRel32(FCode, printIntOffset - (FCode.Size + 5));
            end
            else if instr.ImmStr = 'exit' then
            begin
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteIndirectCall(FKernel32Index, FExitProcessIndex);
            end
            // === std.io: Windows I/O API (simplified) ===
            else if instr.ImmStr = 'open' then
            begin
              // CreateFileA(lpFileName, dwDesiredAccess, dwShareMode,
              //             lpSecurityAttributes, dwCreationDisposition,
              //             dwFlagsAndAttributes, hTemplateFile)
              // RCX = path, RDX = GENERIC_READ|GENERIC_WRITE ($C0000000),
              // R8 = FILE_SHARE_READ ($1), R9 = NULL (security)
              // Stack: [rsp+32]=OPEN_EXISTING(3), [rsp+40]=FILE_ATTRIBUTE_NORMAL($80), [rsp+48]=NULL
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              // Flags -> dwDesiredAccess: Linux O_RDONLY=0, O_WRONLY=1, O_RDWR=2
              // Simplified: always use GENERIC_READ | GENERIC_WRITE
              WriteMovRegImm64(FCode, RDX, $C0000000); // GENERIC_READ | GENERIC_WRITE
              WriteMovRegImm64(FCode, R8, 1);  // FILE_SHARE_READ
              WriteMovRegImm64(FCode, R9, 0);  // NULL (security attributes)
              // 3 stack args: CreationDisposition, FlagsAndAttributes, hTemplateFile
              // sub rsp, 24 (3 * 8 bytes for stack args)
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 24);
              // [rsp+32] = OPEN_EXISTING (3) - creation disposition
              // But with shadow space: 5th arg is at [rsp+32]
              WriteMovRegImm64(FCode, RAX, 3); // OPEN_EXISTING
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 32); // mov [rsp+32], rax
              WriteMovRegImm64(FCode, RAX, $80); // FILE_ATTRIBUTE_NORMAL
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 40); // mov [rsp+40], rax
              WriteMovRegImm64(FCode, RAX, 0); // hTemplateFile = NULL
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 48); // mov [rsp+48], rax
              WriteIndirectCall(FKernel32Index, FCreateFileAIndex);
              // add rsp, 24
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 24);
              // RAX = handle or INVALID_HANDLE_VALUE (-1)
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'read' then
            begin
              // ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead, LPOVERLAPPED lpOverlapped)
              // RCX = handle, RDX = buffer, R8 = count, R9 = &bytesRead (stack), [rsp+32] = NULL
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              if instr.Src2 >= 0 then
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovRegImm64(FCode, RDX, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteMovRegMem(FCode, R8, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovRegImm64(FCode, R8, 0);
              // R9 = NULL (lpNumberOfBytesRead — vereinfacht, ohne Rückgabe der tatsächlichen Bytes)
              WriteMovRegImm64(FCode, R9, 0);
              // 5. Parameter (lpOverlapped) auf dem Stack = NULL
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 8); // sub rsp, 8
              EmitU8(FCode, $48); EmitU8(FCode, $33); EmitU8(FCode, $C0); // xor rax, rax
              WriteIndirectCall(FKernel32Index, FReadFileIndex);
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 8); // add rsp, 8
              // Rückgabe: Erfolg → angeforderte Byteanzahl (R8), Fehler → -1
              WriteMovRegReg(FCode, R11, RAX);
              // Test if RAX is zero (failure)
              EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0); // test rax, rax
              // je .failure
              EmitU8(FCode, $74); EmitU8(FCode, 5); // je +5
              // success: mov rax, r8 (return requested count, not actual but close enough)
              WriteMovRegReg(FCode, RAX, R8);       // 3 bytes
              // jmp .done (skip WriteMovRegImm64 = 10 bytes)
              EmitU8(FCode, $EB); EmitU8(FCode, 10); // jmp +10
              // failure: mov rax, -1
              WriteMovRegImm64(FCode, RAX, UInt64(-1)); // 10 bytes
              // done:
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'write' then
            begin
              // WriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite, LPDWORD lpNumberOfBytesWritten, LPOVERLAPPED lpOverlapped)
              // RCX = handle, RDX = buffer, R8 = count, R9 = &bytesWritten (stack), [rsp+32] = NULL
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              if instr.Src2 >= 0 then
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovRegImm64(FCode, RDX, 0);
              // Load 3rd arg from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteMovRegMem(FCode, R8, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovRegImm64(FCode, R8, 0);
              WriteMovRegImm64(FCode, R9, 0);
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 8);
              EmitU8(FCode, $48); EmitU8(FCode, $33); EmitU8(FCode, $C0);
              WriteIndirectCall(FKernel32Index, FWriteFile2Index);
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 8);
              // Check success: if RAX != 0 return requested count, else -1
              WriteMovRegReg(FCode, R11, RAX);
              EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0); // test rax, rax
              EmitU8(FCode, $74); EmitU8(FCode, 5);   // je +5 (skip mov+jmp = 3+2)
              WriteMovRegReg(FCode, RAX, R8);          // 3 bytes
              EmitU8(FCode, $EB); EmitU8(FCode, 10);   // jmp +10 (skip WriteMovRegImm64)
              WriteMovRegImm64(FCode, RAX, UInt64(-1)); // 10 bytes
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'close' then
            begin
              // CloseHandle(handle) -> bool
              // RCX = handle
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteIndirectCall(FKernel32Index, FCloseHandleIndex);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'lseek' then
            begin
              // SetFilePointer(HANDLE hFile, LONG lDistanceToMove, PLONG lpDistanceToMoveHigh, DWORD dwMoveMethod)
              // RCX = handle, RDX = offset, R8 = high (NULL), R9 = method (SEEK_SET=0, SEEK_CUR=1, SEEK_END=2)
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              if instr.Src2 >= 0 then
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovRegImm64(FCode, RDX, 0);
              // Load 3rd arg (whence) from ArgTemps[2]
              arg3 := -1;
              if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                arg3 := instr.ArgTemps[2];
              if arg3 >= 0 then
                WriteMovRegMem(FCode, R9, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovRegImm64(FCode, R9, 0);
              // R8 = NULL for lpDistanceToMoveHigh
              WriteMovRegImm64(FCode, R8, 0);
              WriteIndirectCall(FKernel32Index, FSetFilePointerIndex);
              // SetFilePointer returns INVALID_SET_FILE_POINTER (-1) on failure, check via RAX == -1 && GetLastError()
              // For simplicity, just return RAX (may need GetLastError for proper error handling)
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'unlink' then
            begin
              // DeleteFileA(LPCSTR lpFileName)
              // RCX = filename
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteIndirectCall(FKernel32Index, FDeleteFileAIndex);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'rename' then
            begin
              // MoveFileA(LPCSTR lpExistingFileName, LPCSTR lpNewFileName)
              // RCX = existing, RDX = new
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              if instr.Src2 >= 0 then
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src2))
              else
                WriteMovRegImm64(FCode, RDX, 0);
              WriteIndirectCall(FKernel32Index, FMoveFileAIndex);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'mkdir' then
            begin
              // CreateDirectoryA(LPCSTR lpPathName, LPSECURITY_ATTRIBUTES lpSecurityAttributes)
              // RCX = path, RDX = NULL
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteMovRegImm64(FCode, RDX, 0);
              WriteIndirectCall(FKernel32Index, FCreateDirectoryAIndex);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'rmdir' then
            begin
              // RemoveDirectoryA(LPCSTR lpPathName)
              // RCX = path
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteIndirectCall(FKernel32Index, FRemoveDirectoryAIndex);
              // RAX enthält den Rückgabewert (non-zero = Erfolg)
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'chmod' then
            begin
              // SetFileAttributesA(LPCSTR lpFileName, DWORD dwFileAttributes)
              // RCX = filename, RDX = attributes
              // Windows doesn't have a direct chmod equivalent, but we can set file attributes
              // For read-write: FILE_ATTRIBUTE_NORMAL (0x80)
              // For read-only: FILE_ATTRIBUTE_READONLY (0x1)
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              // Load 2nd arg from ArgTemps[1]
              arg3 := -1;
              if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
                arg3 := instr.ArgTemps[1];
              if arg3 >= 0 then
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + arg3))
              else
                WriteMovRegImm64(FCode, RDX, $80); // Default: FILE_ATTRIBUTE_NORMAL
              WriteIndirectCall(FKernel32Index, FSetFileAttributesAIndex);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'Random' then
            begin
              // call Random stub
              WriteCallRel32(FCode, randomOffset - (FCode.Size + 5));
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'RandomSeed' then
            begin
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1))
              else
                WriteMovRegImm64(FCode, RCX, 0);
              WriteCallRel32(FCode, randomSeedOffsetStub - (FCode.Size + 5));
            end
            else if instr.ImmStr = 'RegexMatch' then
            begin
              // RegexMatch(pattern, text) -> bool (1 or 0)
              // Einfache Implementierung: return 0
              WriteMovRegImm64(FCode, RAX, 0);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'RegexSearch' then
            begin
              // RegexSearch(pattern, text) -> int64 (position or -1)
              // Einfache Implementierung: return -1
              WriteMovRegImm64(FCode, RAX, UInt64(-1));
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else if instr.ImmStr = 'RegexReplace' then
            begin
              // RegexReplace(pattern, text, replacement) -> int64 (count)
              // Einfache Implementierung: return 0
              WriteMovRegImm64(FCode, RAX, 0);
              if instr.Dest >= 0 then
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end
            else
            begin
              // unsupported builtin: no-op / placeholder
              // set dest to 0 if applicable
              if instr.Dest >= 0 then
              begin
                WriteMovRegImm64(FCode, RAX, 0);
                WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
              end;
            end;
          end;
        irConstInt:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovRegImm64(FCode, RAX, UInt64(instr.ImmInt));
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irLoadLocal:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1));
            slotIdx := localCnt + instr.Dest;
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irStoreLocal:
          begin
            // Store temp into local variable: locals[Dest] = temps[Src1]
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);
          end;
        irTrunc:
          begin
            // Truncate src1 to ImmInt bits and store to dest
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            if instr.ImmInt < 64 then
            begin
              // Mask lower bits: and rax, mask
              mask64 := (UInt64(1) shl instr.ImmInt) - 1;
              EmitU8(FCode, $48); EmitU8(FCode, $81); EmitU8(FCode, $E0); // and rax, imm32
              EmitU32(FCode, Cardinal(mask64 and $FFFFFFFF));
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irSExt:
          begin
            // Sign-extend src1 (width in ImmInt) into dest using shl/sar sequence
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            if instr.ImmInt < 64 then
            begin
              sh := 64 - instr.ImmInt;
              // shl rax, sh
              EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E0); EmitU8(FCode, Byte(sh));
              // sar rax, sh
              EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $F8); EmitU8(FCode, Byte(sh));
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irZExt:
          begin
            // Zero-extend src1 (width in ImmInt) into dest
            slotIdx := localCnt + instr.Src1;
            case instr.ImmInt of
              8: WriteMovzxRegMem8(FCode, RAX, RBP, SlotOffset(slotIdx));
              16: WriteMovzxRegMem16(FCode, RAX, RBP, SlotOffset(slotIdx));
              32:
                begin
                  // mov eax, dword ptr [base+disp] zero-extends into rax implicitly
                  WriteMovEAXMem32(FCode, RBP, SlotOffset(slotIdx));
                end;
            else
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irLoadLocalAddr:
          begin
            // Load address of local variable into temp: dest = &locals[src1]
            // LEA rax, [rbp + offset]
            structBaseOff := SlotOffset(instr.Src1);
            EmitU8(FCode, $48); // REX.W
            EmitU8(FCode, $8D); // LEA opcode
            if (structBaseOff >= -128) and (structBaseOff <= 127) then
            begin
              EmitU8(FCode, $45); // ModR/M: [rbp + disp8], reg=rax
              EmitU8(FCode, Byte(structBaseOff));
            end
            else
            begin
              EmitU8(FCode, $85); // ModR/M: [rbp + disp32], reg=rax
              EmitU32(FCode, Cardinal(structBaseOff));
            end;
            // Store result in destination temp slot
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irLoadGlobal:
          begin
            // Load global variable into temp: dest = globals[ImmStr]
            // Globals are pre-allocated in data section during EmitFromIR
            varIdx := globalVarNames.IndexOf(instr.ImmStr);
            if varIdx < 0 then
            begin
              // Should not happen if frontend correctly registered globals
              varIdx := globalVarNames.Count;
              globalVarNames.Add(instr.ImmStr);
              SetLength(globalVarOffsets, varIdx + 1);
              globalVarOffsets[varIdx] := totalDataOffset;
              FData.WriteU64LE(0);
              Inc(totalDataOffset, 8);
            end;
            // lea rax, [rip+disp32] ; will be patched later
            leaPos := FCode.Size;
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
            // Record position for patching using FGlobalVarLeaPositions
            SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := varIdx;
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
            // mov rax, [rax]
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $00);
            // Store into temp slot
            slotIdx := localCnt + instr.Dest;
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irStoreGlobal:
          begin
            // Store temp into global variable: globals[ImmStr] = src1
            // Load value from temp
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            // Find slot for this global variable
            varIdx := globalVarNames.IndexOf(instr.ImmStr);
            if varIdx < 0 then
            begin
              varIdx := globalVarNames.Count;
              globalVarNames.Add(instr.ImmStr);
              SetLength(globalVarOffsets, varIdx + 1);
              globalVarOffsets[varIdx] := totalDataOffset;
              FData.WriteU64LE(0);
              Inc(totalDataOffset, 8);
            end;
            // lea rcx, [rip+disp32] ; will be patched later
            leaPos := FCode.Size;
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D); EmitU32(FCode, 0);
            // Record position for patching
            SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := varIdx;
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
            // mov [rcx], rax
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $01);
          end;
        irLoadGlobalAddr:
          begin
            // Load address of global variable OR VMT label into temp: dest = &globals[ImmStr]
            // Check if this is a VMT label (_vmt_ClassName)
            if Copy(instr.ImmStr, 1, 5) = '_vmt_' then
            begin
              // This is a VMT label - look up its position in FVMTLabels
              // VMT data is now in CODE section, so vmtDataPos is offset in code
              vmtDataPos := -1;
              for k := 0 to High(FVMTLabels) do
              begin
                if FVMTLabels[k].Name = instr.ImmStr then
                begin
                  vmtDataPos := FVMTLabels[k].Pos;
                  Break;
                end;
              end;
              
              if vmtDataPos < 0 then
              begin
                // VMT label not found - should not happen
                vmtDataPos := 0;
              end;
              
              // lea rax, [rip+disp32] ; will be patched later
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
              // Record position for patching - LeaPos points to instruction start, but displacement is at +3
              // Store LeaPos + 3 so patch offset targets the displacement bytes
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := $100000 + vmtDataPos;  // RVA marker
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos + 3;  // +3 to target displacement
              // Store the ADDRESS into temp slot
              slotIdx := localCnt + instr.Dest;
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end
            else
            begin
              // Regular global variable
              varIdx := globalVarNames.IndexOf(instr.ImmStr);
              if varIdx < 0 then
              begin
                varIdx := globalVarNames.Count;
                globalVarNames.Add(instr.ImmStr);
                SetLength(globalVarOffsets, varIdx + 1);
                globalVarOffsets[varIdx] := totalDataOffset;
                FData.WriteU64LE(0);
                Inc(totalDataOffset, 8);
              end;
              // lea rax, [rip+disp32] ; will be patched later - loads ADDRESS directly
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
              // Record position for patching
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := varIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // Store the ADDRESS into temp slot
              slotIdx := localCnt + instr.Dest;
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;
          end;
        irAdd:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteAddRegReg(FCode, RAX, RCX);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irSub:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irMul:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteImulRegReg(FCode, RAX, RCX);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irDiv:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteCqo(FCode);
            WriteIdivReg(FCode, RCX);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irMod:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteCqo(FCode);
            WriteIdivReg(FCode, RCX);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RDX);
          end;
        irNeg:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            EmitU8(FCode, $48); EmitU8(FCode, $F7); EmitU8(FCode, $D8); // neg rax
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpEq:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $94); EmitU8(FCode, $C0); // sete al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpNeq:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $95); EmitU8(FCode, $C0); // setne al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpLt:
          begin
            // dest = (src1 < src2) ? 1 : 0 (signed)
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $9C); EmitU8(FCode, $C0); // setl al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpLe:
          begin
            // dest = (src1 <= src2) ? 1 : 0 (signed)
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $9E); EmitU8(FCode, $C0); // setle al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpGt:
          begin
            // dest = (src1 > src2) ? 1 : 0 (signed)
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $9F); EmitU8(FCode, $C0); // setg al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irCmpGe:
          begin
            // dest = (src1 >= src2) ? 1 : 0 (signed)
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubRegReg(FCode, RAX, RCX);
            EmitU8(FCode, $0F); EmitU8(FCode, $9D); EmitU8(FCode, $C0); // setge al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al
             WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
           end;
         irNot:
           begin
             // dest = !src1  (boolean not)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1)); // load src1 to RAX
             WriteTestRaxRax(FCode);                                           // test RAX, RAX (sets ZF if RAX is 0)
             EmitU8(FCode, $0F); EmitU8(FCode, $94); EmitU8(FCode, $C0);       // sete al (AL = 1 if ZF, else 0)
             EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0); // movzx rax, al (zero-extend AL to RAX)
             WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX); // store result
           end;
         irAnd:
           begin
             // dest = src1 & src2
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1)); // load src1 to RAX
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2)); // load src2 to RCX
             EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $C8);       // and rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX); // store result
           end;
         irOr:
           begin
             // dest = src1 | src2
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1)); // load src1 to RAX
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2)); // load src2 to RCX
             EmitU8(FCode, $48); EmitU8(FCode, $09); EmitU8(FCode, $C8);       // or rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX); // store result
           end;
         irReturn:
          begin
            // Move return value into RAX (non-entry) or RCX (entry)
            if isEntryFunction then
            begin
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src1));
            end
            else
            begin
              if instr.Src1 >= 0 then
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            end;

            // Epilogue - frameBytes already includes padding from EmitPrologue
            EmitEpilogue(frameBytes);
          end;
        irLabel:
          begin
            // Record label position for branch patching
            FLabelMap.AddObject(instr.LabelName, TObject(PtrInt(FCode.Size)));
          end;
        irJmp:
          begin
            // Unconditional jump to label
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].JmpSize := 5;  // jmp rel32
            WriteJmpRel32(FCode, 0);  // placeholder
          end;
        irBrTrue:
          begin
            // Jump to label if Src1 != 0
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteTestRaxRax(FCode);
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].JmpSize := 6;  // jne rel32
            WriteJneRel32(FCode, 0);  // placeholder
          end;
        irBrFalse:
          begin
            // Jump to label if Src1 == 0
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteTestRaxRax(FCode);
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].JmpSize := 6;  // je rel32
            WriteJeRel32(FCode, 0);  // placeholder
          end;
        irCall:
          begin
            // user-defined calls: simple implementation
            argCount := instr.ImmInt;
            SetLength(argTemps, argCount);
            for k := 0 to argCount - 1 do argTemps[k] := -1;
            if argCount > 0 then argTemps[0] := instr.Src1;
            if argCount > 1 then argTemps[1] := instr.Src2;
            if (argCount > 2) and (instr.LabelName <> '') then
            begin
              sParse := instr.LabelName;
              ppos := Pos(',', sParse);
              ai := 2;
              while (ppos > 0) and (ai < argCount) do
              begin
                argTemps[ai] := StrToIntDef(Copy(sParse, 1, ppos - 1), -1);
                Delete(sParse, 1, ppos);
                Inc(ai);
                ppos := Pos(',', sParse);
              end;
              if (sParse <> '') and (ai < argCount) then
                argTemps[ai] := StrToIntDef(sParse, -1);
            end;
            // If the IR carries explicit ArgTemps array, use it (newer IR)
            if Length(instr.ArgTemps) > 0 then
            begin
              for k := 0 to argCount - 1 do
                if k <= High(instr.ArgTemps) then argTemps[k] := instr.ArgTemps[k];
            end;
            // Load up to 4 args into RCX,RDX,R8,R9
            for k := 0 to Min(argCount - 1, 3) do
            begin
              if argTemps[k] >= 0 then
                WriteMovRegMem(FCode, Win64ParamRegs[k], RBP, SlotOffset(localCnt + argTemps[k]))
              else
                WriteMovRegImm64(FCode, Win64ParamRegs[k], 0);
            end;
            // Stack args (beyond 4) - write into caller's shadow area
            if argCount > 4 then
            begin
              for k := argCount - 1 downto 4 do
              begin
                if argTemps[k] >= 0 then
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + argTemps[k]))
                else
                  WriteMovRegImm64(FCode, RAX, 0);
                // mov [rsp+32 + (k-4)*8], rax
                WriteMovMemReg(FCode, RSP, 32 + (k - 4) * 8, RAX);
              end;
            end;
            
            // Handle virtual method calls
            if instr.IsVirtualCall and (instr.VMTIndex >= 0) then
            begin
              // Virtual call: self is in RCX (first arg for Windows x64)
              // 1. Load VMT pointer from object: mov rax, [rcx]
              WriteMovRegMem(FCode, RAX, RCX, 0);
              // 2. Load method pointer from VMT table: mov rax, [rax + vmtIndex*8]
              WriteMovRegMem(FCode, RAX, RAX, instr.VMTIndex * 8);
              // 3. Indirect call through the method pointer
              EmitU8(FCode, $FF); // rex.w + D0 = call r/m64
              EmitU8(FCode, $D0);
              // Skip the regular call emission below
            end
            else
            begin
            // For now, emit a call rel32 placeholder and record for patching
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            // emit call rel32 with zero placeholder
            EmitU8(FCode, $E8);
            EmitU32(FCode, 0);
            end; // end of virtual call handling
            // Store return value from RAX to destination slot
            if instr.Dest >= 0 then
              WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irStackAlloc:
          begin
            // Allocate stack space for array: alloc_size = ImmInt bytes
            allocSize := instr.ImmInt;
            // Align to 8-byte boundary
            allocSize := (allocSize + 7) and not 7;
            
            // Move current RSP down by allocSize bytes: sub rsp, allocSize
            if allocSize <= 127 then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, Byte(allocSize));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $81); EmitU8(FCode, $EC);
              EmitU32(FCode, Cardinal(allocSize));
            end;
            
            // Store current RSP as array base address in temp slot
            slotIdx := localCnt + instr.Dest;
            WriteMovRegReg(FCode, RAX, RSP); // mov rax, rsp
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irStoreElem:
          begin
            // Store element: array[index] = value
            // Src1 = array base address temp, Src2 = value temp, ImmInt = index
            elemIndex := instr.ImmInt;
            elemOffset := elemIndex * 8; // 8 bytes per element
            
            // Load array base address into RAX
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            // Load element value into RCX
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            // Store value at array[index]: mov [rax + elemOffset], rcx
            if elemOffset <= 127 then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(elemOffset));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $88);
              EmitU32(FCode, Cardinal(elemOffset));
            end;
          end;
        irLoadElem:
          begin
            // Load element: dest = array[index]
            // Src1 = array base address temp, Src2 = index temp, Dest = result
            
            // Load array base address into RAX
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            // Load index into RCX
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            
            // Calculate element address: RAX = RAX + RCX * 8
            // shl rcx, 3   (multiply index by 8)
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E1); EmitU8(FCode, $03);
            // add rax, rcx (add scaled offset)
            EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C8);
            
            // Load value from calculated address: RCX = [RAX]
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $08);
            
            // Store result in destination temp slot
            slotIdx := localCnt + instr.Dest;
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RCX);
          end;
        irStoreElemDyn:
          begin
            // Store element dynamically: array[index] = value
            // Src1 = array base, Src2 = index, Src3 = value
            
            // Load array base address into RAX
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            // Load index into RCX
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            // Load value into RDX
            WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src3));
            
            // Calculate element address: RAX = RAX + RCX * 8
            // shl rcx, 3   (multiply index by 8)
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E1); EmitU8(FCode, $03);
            // add rax, rcx (add scaled offset)
            EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C8);
            
            // Store value at calculated address: [RAX] = RDX
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $10);
          end;
        irLoadStructAddr:
          begin
            // Load base address of struct local for field access
            // With negative field offsets, base is simply SlotOffset(loc)
            structBaseOff := SlotOffset(instr.Src1);
            // LEA rax, [rbp + structBaseOff]
            EmitU8(FCode, $48); // REX.W
            EmitU8(FCode, $8D); // LEA opcode
            if (structBaseOff >= -128) and (structBaseOff <= 127) then
            begin
              EmitU8(FCode, $45); // ModR/M: [rbp + disp8], reg=rax
              EmitU8(FCode, Byte(structBaseOff));
            end
            else
            begin
              EmitU8(FCode, $85); // ModR/M: [rbp + disp32], reg=rax
              EmitU32(FCode, Cardinal(structBaseOff));
            end;
            // Store result in destination temp slot
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irLoadField:
          begin
            // Load field from struct: Dest = *(Src1 - ImmInt)
            // Stack slots grow negative, so we SUBTRACT the field offset
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            negOffset := -instr.ImmInt;
            if (negOffset >= -128) and (negOffset <= 127) then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $88);
              EmitU32(FCode, Cardinal(negOffset));
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RCX);
          end;
        irStoreField:
          begin
            // Store field into struct: *(Src1 - ImmInt) = Src2
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            negOffset := -instr.ImmInt;
            if (negOffset >= -128) and (negOffset <= 127) then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $88);
              EmitU32(FCode, Cardinal(negOffset));
            end;
          end;
        irLoadFieldHeap:
          begin
            // Load field from heap object: Dest = *(Src1 + ImmInt)
            // Positive offset for heap objects
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            if (instr.ImmInt >= -128) and (instr.ImmInt <= 127) then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $88);
              EmitU32(FCode, Cardinal(instr.ImmInt));
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RCX);
          end;
        irStoreFieldHeap:
          begin
            // Store field into heap object: *(Src1 + ImmInt) = Src2
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(localCnt + instr.Src2));
            if (instr.ImmInt >= -128) and (instr.ImmInt <= 127) then
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
            end
            else
            begin
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $88);
              EmitU32(FCode, Cardinal(instr.ImmInt));
            end;
          end;
        irAlloc:
          begin
            // Heap allocation: Dest = alloc(ImmInt bytes)
            // Use VirtualAlloc(NULL, size, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)
            // MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, PAGE_READWRITE = 0x04
            
            // RCX = lpAddress = NULL (0)
            WriteMovRegImm64(FCode, RCX, 0);
            // RDX = dwSize = ImmInt
            WriteMovRegImm64(FCode, RDX, UInt64(instr.ImmInt));
            // R8 = flAllocationType = MEM_COMMIT | MEM_RESERVE = 0x3000
            WriteMovRegImm64(FCode, R8, $3000);
            // R9 = flProtect = PAGE_READWRITE = 0x04
            WriteMovRegImm64(FCode, R9, $04);
            // Call VirtualAlloc
            WriteIndirectCall(FKernel32Index, FVirtualAllocIndex);
            // Result (pointer) is now in RAX, store to Dest temp slot
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;
        irFree:
          begin
            // Heap deallocation: free(Src1)
            // For now, skip freeing to avoid complexity
            // Windows will free all memory when process exits
          end;

        irPoolAlloc:
          begin
            // Pool allocation: Dest = pool_alloc(ImmInt bytes)
            // Use VirtualAlloc like irAlloc for now
            // TODO: Implement real pool with pre-allocated arena
            
            // RCX = lpAddress = NULL (0)
            WriteMovRegImm64(FCode, RCX, 0);
            // RDX = dwSize = ImmInt
            WriteMovRegImm64(FCode, RDX, UInt64(instr.ImmInt));
            // R8 = flAllocationType = MEM_COMMIT | MEM_RESERVE = 0x3000
            WriteMovRegImm64(FCode, R8, $3000);
            // R9 = flProtect = PAGE_READWRITE = 0x04
            WriteMovRegImm64(FCode, R9, $04);
            // Call VirtualAlloc
            WriteIndirectCall(FKernel32Index, FVirtualAllocIndex);
            // Result (pointer) is now in RAX, store to Dest temp slot
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;

        irPoolFree:
          begin
            // Pool free all: free entire pool
            // For now, skip freeing like irFree
            // Windows will free all memory when process exits
          end;

        irConstFloat:
          begin
            // Float-Konstante als Bit-Pattern in den Slot schreiben
            slotIdx := localCnt + instr.Dest;
            WriteMovRegImm64(FCode, RAX, PUInt64(@instr.ImmFloat)^);
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;

        // === SSE2 Float-Arithmetik ===
        irFAdd:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(localCnt + instr.Src2));
            WriteAddsd(FCode, XMM0, XMM1);
            WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
          end;
        irFSub:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(localCnt + instr.Src2));
            WriteSubsd(FCode, XMM0, XMM1);
            WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
          end;
        irFMul:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(localCnt + instr.Src2));
            WriteMulsd(FCode, XMM0, XMM1);
            WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
          end;
        irFDiv:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(localCnt + instr.Src2));
            WriteDivsd(FCode, XMM0, XMM1);
            WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
          end;
        irFNeg:
          begin
            // FNeg: Toggle Sign-Bit (Bit 63)
            slotIdx := localCnt + instr.Dest;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $BA);
            EmitU8(FCode, $F8); EmitU8(FCode, 63); // btc rax, 63
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;

        // === SSE2 Float-Vergleiche ===
        irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(localCnt + instr.Src2));
            WriteUcomisd(FCode, XMM0, XMM1);
            case instr.Op of
              irFCmpEq:  begin EmitU8(FCode, $0F); EmitU8(FCode, $94); EmitU8(FCode, $C0); end;
              irFCmpNeq: begin EmitU8(FCode, $0F); EmitU8(FCode, $95); EmitU8(FCode, $C0); end;
              irFCmpLt:  begin EmitU8(FCode, $0F); EmitU8(FCode, $92); EmitU8(FCode, $C0); end;
              irFCmpLe:  begin EmitU8(FCode, $0F); EmitU8(FCode, $96); EmitU8(FCode, $C0); end;
              irFCmpGt:  begin EmitU8(FCode, $0F); EmitU8(FCode, $97); EmitU8(FCode, $C0); end;
              irFCmpGe:  begin EmitU8(FCode, $0F); EmitU8(FCode, $93); EmitU8(FCode, $C0); end;
            end;
            // movzx rax, al
            EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0);
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;

        // === Float ↔ Integer Konvertierung ===
        irFToI:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(localCnt + instr.Src1));
            WriteCvttsd2si(FCode, RAX, XMM0);
            WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
          end;
        irIToF:
          begin
            slotIdx := localCnt + instr.Dest;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(localCnt + instr.Src1));
            WriteCvtsi2sd(FCode, XMM0, RAX);
            WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
          end;

        irCallStruct:
          begin
            // Call returning struct: handled similar to irCall
            // For now, just call and store result
            argCount := instr.ImmInt;
            SetLength(argTemps, argCount);
            for k := 0 to argCount - 1 do argTemps[k] := -1;
            if argCount > 0 then argTemps[0] := instr.Src1;
            if argCount > 1 then argTemps[1] := instr.Src2;
            if Length(instr.ArgTemps) > 0 then
            begin
              for k := 0 to argCount - 1 do
                if k <= High(instr.ArgTemps) then argTemps[k] := instr.ArgTemps[k];
            end;
            // Load args into registers
            for k := 0 to Min(argCount - 1, 3) do
            begin
              if argTemps[k] >= 0 then
                WriteMovRegMem(FCode, Win64ParamRegs[k], RBP, SlotOffset(localCnt + argTemps[k]))
              else
                WriteMovRegImm64(FCode, Win64ParamRegs[k], 0);
            end;
            // Emit call
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            EmitU8(FCode, $E8);
            EmitU32(FCode, 0);
            // Store result in dest slot (struct address)
            if instr.Dest >= 0 then
              WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);
          end;
        irReturnStruct:
          begin
            // Return struct by value - Src1 is local slot index
            if instr.Src1 >= 0 then
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1));
            EmitEpilogue(frameBytes);
          end;

        // === Map/Set Operations ===
        // Map structure: [len:8][cap:8][entries:16*cap], Entry: [key:8][value:8]
        irMapNew, irSetNew:
          begin
            // Allocate 144 bytes (16 header + 8*16 entries) using VirtualAlloc
            // For simplicity, use a static buffer approach or HeapAlloc
            // Here we use VirtualAlloc: rcx=NULL, rdx=144, r8=MEM_COMMIT|MEM_RESERVE, r9=PAGE_READWRITE
            WriteMovRegImm64(FCode, RCX, 0);
            WriteMovRegImm64(FCode, RDX, 144);
            WriteMovRegImm64(FCode, R8, $3000); // MEM_COMMIT | MEM_RESERVE
            WriteMovRegImm64(FCode, R9, $04);   // PAGE_READWRITE
            // Call VirtualAlloc - need to add import
            // For now, just allocate from stack (simplified)
            // sub rsp, 144; mov rax, rsp
            EmitU8(FCode, $48); EmitU8(FCode, $81); EmitU8(FCode, $EC);
            EmitU32(FCode, 144);
            WriteMovRegReg(FCode, RAX, RSP);
            // Store pointer in dest
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            // Initialize: len=0, cap=8
            EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $00);
            EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
            EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $40); EmitU8(FCode, $08);
            EmitU8(FCode, $08); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
          end;

        irMapSet:
          begin
            // map_set(map, key, value) - search for key, update or append
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(localCnt + instr.Src1)); // map ptr
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(localCnt + instr.Src2)); // key
            WriteMovRegMem(FCode, RDX, RBP, SlotOffset(localCnt + instr.Src3)); // value
            // rcx = len
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F);
            // r8 = 0
            EmitU8(FCode, $45); EmitU8(FCode, $31); EmitU8(FCode, $C0);
            // r9 = rdi + 16
            EmitU8(FCode, $4C); EmitU8(FCode, $8D); EmitU8(FCode, $4F); EmitU8(FCode, $10);
            // Search loop
            loopStartPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $C8); // cmp r8, rcx
            jgePos := FCode.Size;
            EmitU8(FCode, $7D); EmitU8(FCode, $00);
            EmitU8(FCode, $4D); EmitU8(FCode, $8B); EmitU8(FCode, $11); // mov r10, [r9]
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $F2); // cmp r10, rsi
            jneLoopPos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);
            // Found: update [r9+8] = rdx
            EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $51); EmitU8(FCode, $08);
            jmpDonePos := FCode.Size;
            EmitU8(FCode, $EB); EmitU8(FCode, $00);
            // Next
            nextLabelPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $10);
            EmitU8(FCode, $49); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
            EmitU8(FCode, $EB);
            EmitU8(FCode, Byte(Int8(loopStartPos - (FCode.Size + 1))));
            // notFound: append
            notFoundPos := FCode.Size;
            WriteMovRegReg(FCode, R9, RDI);
            WriteMovRegReg(FCode, R10, RCX);
            EmitU8(FCode, $49); EmitU8(FCode, $C1); EmitU8(FCode, $E2); EmitU8(FCode, $04);
            EmitU8(FCode, $4D); EmitU8(FCode, $01); EmitU8(FCode, $D1);
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $10);
            EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $31);
            EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $51); EmitU8(FCode, $08);
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $07);
            doneLabelPos := FCode.Size;
            FCode.PatchU8(jgePos + 1, notFoundPos - (jgePos + 2));
            FCode.PatchU8(jneLoopPos + 1, nextLabelPos - (jneLoopPos + 2));
            FCode.PatchU8(jmpDonePos + 1, doneLabelPos - (jmpDonePos + 2));
          end;

        irSetAdd:
          begin
            // set_add(set, value) - same as map_set but no value
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(localCnt + instr.Src2));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F);
            WriteMovRegReg(FCode, R8, RCX);
            EmitU8(FCode, $49); EmitU8(FCode, $C1); EmitU8(FCode, $E0); EmitU8(FCode, $04);
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
            WriteMovRegReg(FCode, R9, RDI);
            WriteAddRegReg(FCode, R9, R8);
            EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $31);
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $07);
          end;

        irMapGet:
          begin
            // map_get(map, key) -> value (linear search)
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(localCnt + instr.Src2));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F);
            EmitU8(FCode, $45); EmitU8(FCode, $31); EmitU8(FCode, $C0);
            EmitU8(FCode, $31); EmitU8(FCode, $C0);
            EmitU8(FCode, $4C); EmitU8(FCode, $8D); EmitU8(FCode, $4F); EmitU8(FCode, $10);
            loopStartPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $C8);
            jgePos := FCode.Size;
            EmitU8(FCode, $7D); EmitU8(FCode, $00);
            EmitU8(FCode, $4D); EmitU8(FCode, $8B); EmitU8(FCode, $11);
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $F2);
            jneLoopPos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);
            EmitU8(FCode, $49); EmitU8(FCode, $8B); EmitU8(FCode, $41); EmitU8(FCode, $08);
            jmpDonePos := FCode.Size;
            EmitU8(FCode, $EB); EmitU8(FCode, $00);
            nextLabelPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $10);
            EmitU8(FCode, $49); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
            EmitU8(FCode, $EB);
            EmitU8(FCode, Byte(Int8(loopStartPos - (FCode.Size + 1))));
            doneLabelPos := FCode.Size;
            FCode.PatchU8(jgePos + 1, doneLabelPos - (jgePos + 2));
            FCode.PatchU8(jneLoopPos + 1, nextLabelPos - (jneLoopPos + 2));
            FCode.PatchU8(jmpDonePos + 1, doneLabelPos - (jmpDonePos + 2));
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;

        irMapContains, irSetContains:
          begin
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(localCnt + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(localCnt + instr.Src2));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F);
            EmitU8(FCode, $45); EmitU8(FCode, $31); EmitU8(FCode, $C0);
            EmitU8(FCode, $31); EmitU8(FCode, $C0);
            EmitU8(FCode, $4C); EmitU8(FCode, $8D); EmitU8(FCode, $4F); EmitU8(FCode, $10);
            loopStartPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $C8);
            jgePos := FCode.Size;
            EmitU8(FCode, $7D); EmitU8(FCode, $00);
            EmitU8(FCode, $4D); EmitU8(FCode, $8B); EmitU8(FCode, $11);
            EmitU8(FCode, $49); EmitU8(FCode, $39); EmitU8(FCode, $F2);
            jneLoopPos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);
            WriteMovRegImm64(FCode, RAX, 1);
            jmpDonePos := FCode.Size;
            EmitU8(FCode, $EB); EmitU8(FCode, $00);
            nextLabelPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $10);
            EmitU8(FCode, $49); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
            EmitU8(FCode, $EB);
            EmitU8(FCode, Byte(Int8(loopStartPos - (FCode.Size + 1))));
            doneLabelPos := FCode.Size;
            FCode.PatchU8(jgePos + 1, doneLabelPos - (jgePos + 2));
            FCode.PatchU8(jneLoopPos + 1, nextLabelPos - (jneLoopPos + 2));
            FCode.PatchU8(jmpDonePos + 1, doneLabelPos - (jmpDonePos + 2));
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;

        irMapLen, irSetLen:
          begin
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(localCnt + instr.Src1));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $07);
            WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
          end;

        irMapRemove, irSetRemove, irMapFree, irSetFree:
          begin
            // TODO: implement properly
          end;

        else
          begin
            // other ops unimplemented: set dest to 0
            if instr.Dest >= 0 then
            begin
              WriteMovRegImm64(FCode, RAX, 0);
              WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
            end;
          end;
      end; // case instr.Op
    end; // for instructions

    // Apply intra-function branch patches
    for k := 0 to High(FBranchPatches) do
    begin
      labelIdx := FLabelMap.IndexOf(FBranchPatches[k].LabelName);
      if labelIdx >= 0 then
      begin
        targetPos := PtrInt(FLabelMap.Objects[labelIdx]);
        patchPos := FBranchPatches[k].CodePos;
        jmpSize := FBranchPatches[k].JmpSize;
        // rel32 offset is from end of instruction
        relOffset := targetPos - (patchPos + jmpSize);
        // Patch the rel32 displacement (last 4 bytes of instruction)
        FCode.PatchU32LE(patchPos + jmpSize - 4, Cardinal(relOffset));
      end;
    end;

    // If function didn't end with return, emit epilogue
    // (simplified) emit epilogue - frameBytes already includes padding
    EmitEpilogue(frameBytes);
  end; // for functions

  // Patch call placeholders with actual function offsets
  if Length(FCallPatches) > 0 then
  begin
    for i := 0 to High(FCallPatches) do
    begin
      targetName := FCallPatches[i].TargetName;
      callPos := FCallPatches[i].CodePos;
      foundIdx := -1;
      for k := 0 to High(module.Functions) do
      begin
        if module.Functions[k].Name = targetName then
        begin
          foundIdx := k; Break;
        end;
      end;
      if foundIdx >= 0 then
      begin
        targetOffsetInt := Integer(FFuncOffsets[foundIdx]);
        relInt := Integer(targetOffsetInt) - Integer(callPos + 5);
        FCode.PatchU32LE(callPos + 1, Cardinal(relInt));
      end
      else
      begin
        // unresolved: leave as 0 (or could be external)
      end;
    end;
  end;

  // Patch _start -> main call
  foundIdx := -1;
  for k := 0 to High(module.Functions) do
  begin
    if module.Functions[k].Name = 'main' then
    begin
      foundIdx := k; Break;
    end;
  end;
  if foundIdx >= 0 then
  begin
    targetOffsetInt := Integer(FFuncOffsets[foundIdx]);
    relInt := Integer(targetOffsetInt) - Integer(FStartMainCallPos + 5);
    FCode.PatchU32LE(FStartMainCallPos + 1, Cardinal(relInt));
  end;

  // Cleanup
  globalVarNames.Free;
  
  // === VMT Patching ===
  // Patch VMT entries with actual method addresses
  for i := 0 to High(module.ClassDecls) do
  begin
    cd := module.ClassDecls[i];
    if Length(cd.VirtualMethods) > 0 then
    begin
      // Find VMT label position
      vmtDataPos := -1;
      for j := 0 to High(FVMTLabels) do
      begin
        if FVMTLabels[j].Name = '_vmt_' + cd.Name then
        begin
          vmtDataPos := FVMTLabels[j].Pos;
          Break;
        end;
      end;
      
      if vmtDataPos < 0 then
        Continue;
      
      // Patch each VMT entry with the method address
      for j := 0 to High(cd.VirtualMethods) do
      begin
        method := cd.VirtualMethods[j];
          
          // Handle abstract methods (nil entries in VMT)
          if not Assigned(method) then
          begin
            // Find abstract method error handler address
            methodAddr := -1;
            for k := 0 to High(FLabelPositions) do
            begin
              if FLabelPositions[k].Name = '__abstract_method_error' then
              begin
                methodAddr := FLabelPositions[k].Pos;
                Break;
              end;
            end;
            
            if methodAddr >= 0 then
            begin
              // Patch VMT entry with abstract method error handler
              // VMT data is now in CODE section, so patch directly
              // Use absolute address for dereferencing
              FCode.PatchU64LE(vmtDataPos + (j * 8), UInt64($140001000) + UInt64(methodAddr));
            end;
            Continue;
          end;
          
          // Handle abstract methods that have method objects but IsAbstract=true
          if method.IsAbstract then
          begin
            // Find abstract method error handler address
            methodAddr := -1;
            for k := 0 to High(FLabelPositions) do
            begin
              if FLabelPositions[k].Name = '__abstract_method_error' then
              begin
                methodAddr := FLabelPositions[k].Pos;
                Break;
              end;
            end;
            
            if methodAddr >= 0 then
            begin
              // Use absolute address for dereferencing
              FCode.PatchU64LE(vmtDataPos + (j * 8), UInt64($140001000) + UInt64(methodAddr));
            end;
            Continue;
          end;
          
          // Find method address - method defined in this class
          methodLabelName := '_L_' + cd.Name + '_' + method.Name;
          
          // Find method address in label positions
          methodAddr := -1;
          for k := 0 to High(FLabelPositions) do
          begin
            if FLabelPositions[k].Name = methodLabelName then
            begin
              methodAddr := FLabelPositions[k].Pos;
              Break;
            end;
          end;
          
          // Second try: method might be inherited - search in base class chain
          if (methodAddr < 0) and (cd.BaseClassName <> '') then
          begin
            baseCd := nil;
            for k := 0 to High(module.ClassDecls) do
            begin
              if module.ClassDecls[k].Name = cd.BaseClassName then
              begin
                baseCd := module.ClassDecls[k];
                Break;
              end;
            end;
            
            while Assigned(baseCd) and (methodAddr < 0) do
            begin
              methodLabelName := '_L_' + baseCd.Name + '_' + method.Name;
              for k := 0 to High(FLabelPositions) do
              begin
                if FLabelPositions[k].Name = methodLabelName then
                begin
                  methodAddr := FLabelPositions[k].Pos;
                  Break;
                end;
              end;
              
              // Move to next base class
              if (methodAddr < 0) and (baseCd.BaseClassName <> '') then
              begin
                nextBaseCd := nil;
                for k := 0 to High(module.ClassDecls) do
                begin
                  if module.ClassDecls[k].Name = baseCd.BaseClassName then
                  begin
                    nextBaseCd := module.ClassDecls[k];
                    Break;
                  end;
                end;
                baseCd := nextBaseCd;
              end
              else
                Break;
            end;
          end;
          
          // Record VMT method pointer patch - patch directly to FCode (VMT is in code section now)
          if methodAddr >= 0 then
          begin
            // VMT data is in CODE section, patch directly
            // For indirect calls, we need absolute addresses, not RVAs
            FCode.PatchU64LE(vmtDataPos + (j * 8), UInt64($140001000) + UInt64(methodAddr));
          end;
        end;
        
        // === Patch RTTI pointers ===
        // Find RTTI label positions
        parentVmtPos := -1;
        parentPtrPos := -1;
        classNamePos := -1;
        classNamePtrPos := -1;
        
        for j := 0 to High(FVMTLabels) do
        begin
          if FVMTLabels[j].Name = '_vmt_parent_' + cd.Name then
            parentPtrPos := FVMTLabels[j].Pos;
          if FVMTLabels[j].Name = '_classname_' + cd.Name then
            classNamePos := FVMTLabels[j].Pos;
          if FVMTLabels[j].Name = '_vmt_classname_ptr_' + cd.Name then
            classNamePtrPos := FVMTLabels[j].Pos;
          if (cd.BaseClassName <> '') and (FVMTLabels[j].Name = '_vmt_' + cd.BaseClassName) then
            parentVmtPos := FVMTLabels[j].Pos;
        end;
        
        // Patch parent VMT pointer directly (both in code section)
        // Use absolute address for dereferencing
        if (parentPtrPos >= 0) and (parentVmtPos >= 0) then
        begin
          FCode.PatchU64LE(parentPtrPos, UInt64($140001000) + UInt64(parentVmtPos));
        end;
        
        // Patch class name pointer directly (both in code section)
        // Use absolute address for dereferencing
        if (classNamePtrPos >= 0) and (classNamePos >= 0) then
        begin
          FCode.PatchU64LE(classNamePtrPos, UInt64($140001000) + UInt64(classNamePos));
        end;
      end;  // Ende von if Length(cd.VirtualMethods) > 0
    end;  // Ende von for i := 0 to High(module.ClassDecls)
  end;  // Ende von EmitFromIR

procedure TWin64Emitter.WriteToFile(const filename: string);
var
  leaStrPatches: TLeaStrPatchArray;
  leaVarPatches: TLeaVarPatchArray;
  i: Integer;
begin
  // Build LEA string patches
  SetLength(leaStrPatches, Length(FLeaPositions));
  for i := 0 to High(FLeaPositions) do
  begin
    leaStrPatches[i].CodeOffset := FLeaPositions[i];
    leaStrPatches[i].StrIndex := FLeaStrIndex[i];
  end;

  // Build LEA var patches
  SetLength(leaVarPatches, Length(FGlobalVarLeaPositions));
  for i := 0 to High(FGlobalVarLeaPositions) do
  begin
    leaVarPatches[i].CodeOffset := FGlobalVarLeaPositions[i].CodePos;
    // VarIndex in FGlobalVarLeaPositions can be:
    // 1. Global variable offset (index into globalVarOffsets)
    // 2. VMT buffer position (>= $100000) - VMT is in CODE section now
    //    The PE writer will check for >= $100000 and convert to RVA
    if FGlobalVarLeaPositions[i].VarIndex >= $100000 then
    begin
      // This is a VMT label - pass the marker through unchanged so PE writer can detect it
      leaVarPatches[i].VarIndex := FGlobalVarLeaPositions[i].VarIndex;
    end
    else if FGlobalVarLeaPositions[i].VarIndex < Length(FGlobalVarOffsets) then
    begin
      leaVarPatches[i].VarIndex := Integer(FGlobalVarOffsets[FGlobalVarLeaPositions[i].VarIndex])
    end
    else
    begin
      leaVarPatches[i].VarIndex := 0;
    end;
  end;

  WritePE64(filename, FCode, FData, FImports, FIATPatches, leaStrPatches, leaVarPatches, FDataRefPatches, FEntryOffset);
end;

end.
