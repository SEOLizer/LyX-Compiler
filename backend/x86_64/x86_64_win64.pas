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
    
    // Label/Jump Patching
    FLabelPositions: array of Integer;
    FJumpPatches: array of record
      CodePos: Integer;
      LabelIdx: Integer;
    end;
    
    // Function Info
    FFuncOffsets: array of Integer;
    
    procedure SetupKernel32Imports;
    procedure EmitPrologue(localBytes, paramCount: Integer);
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

procedure TWin64Emitter.EmitPrologue(localBytes, paramCount: Integer);
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
  EmitU8(FCode, $42);  // REX for RDI as index
  EmitU8(FCode, $80);
  EmitU8(FCode, $3C);
  EmitU8(FCode, $3B);  // [rbx + rdi]
  EmitU8(FCode, $00);
  
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
  i: Integer;
  entryOffset, printStrOffset, printIntOffset: Integer;
  randomOffset, randomSeedOffset, exitOffset: Integer;
  mainCallPos, mainOffset: Integer;
  helloOffset, helloStr: Integer;
  strPatchPos, nlOffset, nlPatchPos: Integer;
  helloText: string;
begin
  // Setup imports
  SetupKernel32Imports;
  
  // Reserve space for random seed in .data
  FRandomSeedOffset := FData.Size;
  FData.WriteU64LE(12345);  // Default seed
  
  // Emit builtin stubs first
  printStrOffset := FCode.Size;
  EmitPrintStrStub;
  
  printIntOffset := FCode.Size;
  EmitPrintIntStub;
  
  randomOffset := FCode.Size;
  EmitRandomStub;
  
  randomSeedOffset := FCode.Size;
  EmitRandomSeedStub;
  
  exitOffset := FCode.Size;
  EmitExitStub;
  
  // Entry point (_start)
  entryOffset := FCode.Size;
  
  // Simple entry: call main and exit
  // sub rsp, 40 (32 shadow + 8 for alignment)
  WriteSubRegImm32(FCode, RSP, 40);
  
  // call main (will be patched)
  mainCallPos := FCode.Size;
  WriteCallRel32(FCode, 0);  // Placeholder
  
  // mov rcx, rax (exit code)
  WriteMovRegReg(FCode, RCX, RAX);
  
  // call ExitProcess
  WriteIndirectCall(FKernel32Index, FExitProcessIndex);
  
  // Emit user functions
  // For now, just emit a simple main that returns 0
  mainOffset := FCode.Size;
  
  // Patch main call
  FCode.PatchU32LE(mainCallPos + 1, mainOffset - (mainCallPos + 5));
  
  // Simple main:
  // push rbp
  WritePush(FCode, RBP);
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E5);
  WriteSubRegImm32(FCode, RSP, 32);
  
  // Call PrintStr("Hello Windows!\n")
  // First, add string to data segment
  helloOffset := FData.Size;
  helloText := 'Hello Windows from Lyx!'#13#10#0;
  for i := 1 to Length(helloText) do
    FData.WriteU8(Ord(helloText[i]));
  
  // lea rcx, [rip + hello_offset]
  // This will need to be patched later when we know the data section RVA
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D);
  strPatchPos := FCode.Size;
  EmitU32(FCode, 0);  // Placeholder
  
  // call PrintStr
  WriteCallRel32(FCode, printStrOffset - (FCode.Size + 5));
  
  // Call PrintInt(42)
  WriteMovRegImm64(FCode, RCX, 42);
  WriteCallRel32(FCode, printIntOffset - (FCode.Size + 5));
  
  // Print newline
  nlOffset := FData.Size;
  FData.WriteU8($0D);
  FData.WriteU8($0A);
  FData.WriteU8($00);
  
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D);
  nlPatchPos := FCode.Size;
  EmitU32(FCode, 0);
  WriteCallRel32(FCode, printStrOffset - (FCode.Size + 5));
  
  // Return 0
  WriteXorRegReg(FCode, RAX, RAX);
  WriteAddRegImm32(FCode, RSP, 32);
  WritePop(FCode, RBP);
  WriteRet(FCode);
  
  // Note: Data section RIP-relative patches will be applied in WriteToFile
  // For now, store the patch positions
end;

procedure TWin64Emitter.WriteToFile(const filename: string);
begin
  WritePE64(filename, FCode, FData, FImports, FIATPatches);
end;

end.
