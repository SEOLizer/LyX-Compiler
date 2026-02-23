{$mode objfpc}{$H+}
unit x86_64_win64;

interface

uses
  SysUtils, Classes, Math, bytes, ir, pe64_writer;

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

    // Label/Jump Patching
    FLabelPositions: array of Integer;
    FJumpPatches: array of record
      CodePos: Integer;
      LabelIdx: Integer;
    end;
    FCallPatches: array of record
      CodePos: Integer;
      TargetName: string;
    end;
    
    // Entry point offset (position of _start code)
    FEntryOffset: Integer;
    
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
  SetLength(FImports, 0);
  SetLength(FIATPatches, 0);
  FKernel32Index := -1;
  FGetStdHandleIndex := -1;
  FWriteFileIndex := -1;
  FExitProcessIndex := -1;
  FRandomSeedOffset := -1;
  FEntryOffset := 0;
end;

destructor TWin64Emitter.Destroy;
begin
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
  SetLength(kernelDll.Functions, 3);
  
  kernelDll.Functions[0].Name := 'GetStdHandle';
  kernelDll.Functions[0].Hint := 0;
  FGetStdHandleIndex := 0;
  
  kernelDll.Functions[1].Name := 'WriteFile';
  kernelDll.Functions[1].Hint := 0;
  FWriteFileIndex := 1;
  
  kernelDll.Functions[2].Name := 'ExitProcess';
  kernelDll.Functions[2].Hint := 0;
  FExitProcessIndex := 2;
  
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
  // use emitter-level FGlobalVarLeaPositions field to collect patches
  nonZeroPos, jmpDonePos, jgePos, loopStartPos, jneLoopPos, jeSignPos: Integer;
  targetPos, jmpPos: Integer;
  jmpAfterPadPos: Integer;
  argCount: Integer;
  argTemps: array of Integer;
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
  savedPushBytes: Integer;
  mask64: UInt64;
  sh: Integer;
  argTemp3: Integer;
  argTemp4: Integer;
  argTemp5: Integer;
  argTemp6: Integer;
  found: Boolean;
  ei: Integer;
  varIdx: Integer;
  dumpStart, dumpEnd, dumpLen, di: Integer;
  dumpBuf: array of Byte;
  fs: TFileStream;
  fname: string;
  // Builtin stub offsets
  printStrOffset, printIntOffset, randomOffset, randomSeedOffsetStub, exitOffset: Integer;
  // Call patching temps
  callPos, foundIdx, targetOffsetInt, relInt: Integer;
  targetName: string;
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
  randomSeedAdded := True;
  randomSeedOffset := FRandomSeedOffset;

  // Emit builtin stubs and record their offsets
  printStrOffset := FCode.Size; EmitPrintStrStub;
  printIntOffset := FCode.Size; EmitPrintIntStub;
  randomOffset := FCode.Size; EmitRandomStub;
  randomSeedOffsetStub := FCode.Size; EmitRandomSeedStub;
  exitOffset := FCode.Size; EmitExitStub;

  // Record entry point offset (after builtins, before _start code)
  FEntryOffset := FCode.Size;

  // Basic program entry (_start): set up stack for Win64 and call main
  // sub rsp, 40 (32-byte shadow + alignment)
  WriteSubRegImm32(FCode, RSP, 40);
  // call main (patched later)
  SetLength(FJumpPatches, Length(FJumpPatches) + 1);
  FJumpPatches[High(FJumpPatches)].CodePos := FCode.Size;
  FJumpPatches[High(FJumpPatches)].LabelIdx := -1; // use label resolution later via function names
  WriteCallRel32(FCode, 0); // placeholder
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

  // Main function emission: loop over functions in module
  for i := 0 to High(module.Functions) do
  begin
    // record function offset
    SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
    FFuncOffsets[High(FFuncOffsets)] := FCode.Size;

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
            // labels are implicit via function offsets; for intra-function labels we could record here
          end;
        irJmp:
          begin
            // For simplicity, use absolute labels via function's LabelName not yet implemented
            // placeholder: no-op
            // Real implementation would emit rel32 jump and record for patching
          end;
        irBrTrue, irBrFalse:
          begin
            // conditional branches: not implemented in detail here
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
            // Call function: if external -> via IAT, else direct relative to function offsets
            if instr.ImmStr <> '' then
            begin
              // external or named function: find in FFuncOffsets by name
              found := False;
              for ei := 0 to High(FFuncOffsets) do
              begin
                // No name mapping available here; this is placeholder
              end;
            end;
            // For now, emit a call rel32 placeholder and record for patching
            SetLength(FCallPatches, Length(FCallPatches) + 1);
            FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
            FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
            // emit call rel32 with zero placeholder
            EmitU8(FCode, $E8);
            EmitU32(FCode, 0);
            // Store return value from RAX to destination slot
            if instr.Dest >= 0 then
              WriteMovMemReg(FCode, RBP, SlotOffset(localCnt + instr.Dest), RAX);
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

  // Patch _start -> main call (FJumpPatches with LabelIdx = -1)
  if Length(FJumpPatches) > 0 then
  begin
    for i := 0 to High(FJumpPatches) do
    begin
      if FJumpPatches[i].LabelIdx = -1 then
      begin
        // This is the _start -> main call
        callPos := FJumpPatches[i].CodePos;
        // Find main function offset
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
          relInt := Integer(targetOffsetInt) - Integer(callPos + 5);
          FCode.PatchU32LE(callPos + 1, Cardinal(relInt));
        end;
      end;
    end;
  end;

  // Cleanup
  globalVarNames.Free;
end;

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
    // VarIndex in FGlobalVarLeaPositions refers to index in FGlobalVarOffsets
    if FGlobalVarLeaPositions[i].VarIndex < Length(FGlobalVarOffsets) then
      leaVarPatches[i].VarIndex := Integer(FGlobalVarOffsets[FGlobalVarLeaPositions[i].VarIndex])
    else
      leaVarPatches[i].VarIndex := 0;
  end;

  WritePE64(filename, FCode, FData, FImports, FIATPatches, leaStrPatches, leaVarPatches, FEntryOffset);
end;

end.
