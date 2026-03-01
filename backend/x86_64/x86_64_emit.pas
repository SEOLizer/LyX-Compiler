{$mode objfpc}{$H+}
unit x86_64_emit;

interface

uses
  SysUtils,
  bytes,    // For TByteBuffer
  ir;       // For TIROpKind

type
  // Definition des IX86_64CodeEmitter Interfaces, wie in AGENTS.md angedeutet
  IX86_64CodeEmitter = interface
    ['{SOME-GUID-HERE}'] // Eine GUID würde hier stehen
    procedure EmitByte(b: Byte);
    procedure EmitBytes(const b: TBytes);
    procedure EmitU32(val: UInt32);
    procedure EmitU64(val: UInt64);

    // Grundlegende Instruktions-Emissionsmethoden (Beispiele)
    procedure EmitMovRegImm(destReg: Byte; imm64: Int64);
    procedure EmitAddRegReg(destReg, srcReg: Byte);
    procedure EmitSubRegReg(destReg, srcReg: Byte);
    procedure EmitMulRegReg(destReg, srcReg: Byte); // signed mul
    procedure EmitDivReg(reg: Byte);                // signed div (divides RAX by reg)

    // Bitwise Operations
    procedure EmitAndRegReg(destReg, srcReg: Byte);
    procedure EmitOrRegReg(destReg, srcReg: Byte);
    procedure EmitXorRegReg(destReg, srcReg: Byte);
    procedure EmitNotReg(reg: Byte); // Bitwise NOT (operand in register)
    procedure EmitShlRegImm(reg: Byte; imm8: Byte);
    procedure EmitShrRegImm(reg: Byte; imm8: Byte);

    // Andere typische x86_64 Operationen
    procedure EmitCall(targetAddr: UInt64); // Call absolute address
    procedure EmitRet;
    procedure EmitSyscall;
    procedure EmitLabel(const name: string); // Placeholder for label definition
    procedure EmitJmp(const targetLabel: string); // Placeholder for jump to label

    // Spätere Erweiterungen:
    // procedure EmitMovRegMem(destReg: Byte; baseReg: Byte; disp: Int32);
    // procedure EmitMovMemReg(baseReg: Byte; disp: Int32; srcReg: Byte);
    // etc.
  end;

  TX86_64CodeEmitter = class(TInterfacedObject, IX86_64CodeEmitter)
  private
    FBuffer: TByteBuffer;
    // Map for labels to their positions for backpatching
    FLabelMap: TStringList; // label name -> position in buffer
    FRelocations: TStringList; // list of pending relocations: 'label_name:offset:size'

    procedure WriteModRm(Mod, RegOp, Rm: Byte);
    procedure WriteSib(Scale, Index, Base: Byte);
    function  GetRegisterByte(Reg: Byte): Byte;
    procedure AddRelocation(const labelName: string; offset: Integer; size: Integer);

  public
    constructor Create(aBuffer: TByteBuffer);
    destructor Destroy; override;

    function GetBuffer: TByteBuffer;

    // IX86_64CodeEmitter Implementierung
    procedure EmitByte(b: Byte);
    procedure EmitBytes(const b: TBytes);
    procedure EmitU32(val: UInt32);
    procedure EmitU64(val: UInt64);

    procedure EmitMovRegImm(destReg: Byte; imm64: Int64);
    procedure EmitAddRegReg(destReg, srcReg: Byte);
    procedure EmitSubRegReg(destReg, srcReg: Byte);
    procedure EmitMulRegReg(destReg, srcReg: Byte);
    procedure EmitDivReg(reg: Byte);

    // Bitwise Operations
    procedure EmitAndRegReg(destReg, srcReg: Byte);
    procedure EmitOrRegReg(destReg, srcReg: Byte);
    procedure EmitXorRegReg(destReg, srcReg: Byte);
    procedure EmitNotReg(reg: Byte);
    procedure EmitShlRegImm(reg: Byte; imm8: Byte);
    procedure EmitShrRegImm(reg: Byte; imm8: Byte);

    procedure EmitCall(targetAddr: UInt64);
    procedure EmitRet;
    procedure EmitSyscall;
    procedure EmitLabel(const name: string);
    procedure EmitJmp(const targetLabel: string);

    // Patch pending relocations (called after all code is emitted and label addresses are known)
    procedure PatchRelocations;
  end;

  // Global instance (optional, for convenience)
  // var Emitter: IX86_64CodeEmitter;

implementation

{ Helper functions / constants for x86_64 encoding }
const
  // REX Prefixes
  REX = $40;
  REXB = $01; // Extension of R/M field
  REXX = $02; // Extension of SIB Index field
  REXR = $04; // Extension of ModR/M Reg field
  REXW = $08; // 64-bit operand size

  // Registers (low 8-bit, R8-R15 need REX.B)
  RAX = 0; RCX = 1; RDX = 2; RBX = 3; RSP = 4; RBP = 5; RSI = 6; RDI = 7;
  R8 = 0; R9 = 1; R10 = 2; R11 = 3; R12 = 4; R13 = 5; R14 = 6; R15 = 7; // For REX.B
  
  // ModR/M Byte
  // Mod (bits 7-6): 00 = indirect, 01 = disp8, 10 = disp32, 11 = direct register
  // Reg/Opcode (bits 5-3)
  // R/M (bits 2-0)

{ TX86_64CodeEmitter }

constructor TX86_64CodeEmitter.Create(aBuffer: TByteBuffer);
begin
  inherited Create;
  FBuffer := aBuffer;
  FLabelMap := TStringList.Create;
  FLabelMap.Sorted := False;
  FRelocations := TStringList.Create;
  FRelocations.Sorted := False;
end;

destructor TX86_64CodeEmitter.Destroy;
begin
  FLabelMap.Free;
  FRelocations.Free;
  inherited Destroy;
end;

function TX86_64CodeEmitter.GetBuffer: TByteBuffer;
begin
  Result := FBuffer;
end;

procedure TX86_64CodeEmitter.EmitByte(b: Byte);
begin
  FBuffer.WriteU8(b);
end;

procedure TX86_64CodeEmitter.EmitBytes(const b: TBytes);
var
  i: Integer;
begin
  for i := Low(b) to High(b) do
    FBuffer.WriteU8(b[i]);
end;

procedure TX86_64CodeEmitter.EmitU32(val: UInt32);
begin
  FBuffer.WriteU32LE(val);
end;

procedure TX86_64CodeEmitter.EmitU64(val: UInt64);
begin
  FBuffer.WriteU64LE(val);
end;

function TX86_64CodeEmitter.GetRegisterByte(Reg: Byte): Byte;
begin
  // Maps 0-7 to Rax-Rdi, and R8-R15 to 0-7 with REX.B
  Result := Reg and $07;
end;

procedure TX86_64CodeEmitter.WriteModRm(Mod, RegOp, Rm: Byte);
begin
  EmitByte(((Mod and $03) shl 6) or ((RegOp and $07) shl 3) or (Rm and $07));
end;

procedure TX86_64CodeEmitter.WriteSib(Scale, Index, Base: Byte);
begin
  EmitByte(((Scale and $03) shl 6) or ((Index and $07) shl 3) or (Base and $07));
end;

procedure TX86_64CodeEmitter.AddRelocation(const labelName: string; offset: Integer; size: Integer);
begin
  FRelocations.Add(Format('%s:%d:%d', [labelName, offset, size]));
end;

procedure TX86_64CodeEmitter.EmitMovRegImm(destReg: Byte; imm64: Int64);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // Always 64-bit operand size for mov reg, imm64
  if destReg >= R8 then
    RexPrefix := RexPrefix or REXB; // Set REX.B for R8-R15

  EmitByte(RexPrefix);
  EmitByte($B8 + GetRegisterByte(destReg)); // Opcode B8+rd
  EmitU64(imm64); // 64-bit immediate
end;

procedure TX86_64CodeEmitter.EmitAddRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXB;
  if srcReg >= R8 then RexPrefix := RexPrefix or REXR;

  EmitByte(RexPrefix);
  EmitByte($01); // ADD r/m64, r64 (Opcode 01 /r)
  WriteModRm($C0, GetRegisterByte(srcReg), GetRegisterByte(destReg)); // Mod=11 (direct register), Reg=src, R/M=dest
end;

procedure TX86_64CodeEmitter.EmitSubRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXB;
  if srcReg >= R8 then RexPrefix := RexPrefix or REXR;

  EmitByte(RexPrefix);
  EmitByte($29); // SUB r/m64, r64 (Opcode 29 /r)
  WriteModRm($C0, GetRegisterByte(srcReg), GetRegisterByte(destReg)); // Mod=11 (direct register), Reg=src, R/M=dest
end;

procedure TX86_64CodeEmitter.EmitMulRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  // IMUL r64, r/m64 (Opcode 0F AF /r) - two-operand form
  // destReg = destReg * srcReg
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXR; // destReg is Reg field
  if srcReg >= R8 then RexPrefix := RexPrefix or REXB; // srcReg is R/M field

  EmitByte(RexPrefix);
  EmitByte($0F);
  EmitByte($AF);
  WriteModRm($C0, GetRegisterByte(destReg), GetRegisterByte(srcReg)); // Mod=11, Reg=dest, R/M=src
end;

procedure TX86_64CodeEmitter.EmitDivReg(reg: Byte);
var
  RexPrefix: Byte;
begin
  // IDIV r/m64 (Opcode F7 /7)
  // Divides RAX by r/m64. Quotient in RAX, Remainder in RDX.
  RexPrefix := REXW; // 64-bit operand
  if reg >= R8 then RexPrefix := RexPrefix or REXB; // reg is R/M field

  EmitByte(RexPrefix);
  EmitByte($F7);
  WriteModRm($C0, $07, GetRegisterByte(reg)); // Mod=11, Reg/Opcode=7 (for IDIV), R/M=reg
end;

procedure TX86_64CodeEmitter.EmitAndRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXB;
  if srcReg >= R8 then RexPrefix := RexPrefix or REXR;

  EmitByte(RexPrefix);
  EmitByte($21); // AND r/m64, r64 (Opcode 21 /r)
  WriteModRm($C0, GetRegisterByte(srcReg), GetRegisterByte(destReg)); // Mod=11 (direct register), Reg=src, R/M=dest
end;

procedure TX86_64CodeEmitter.EmitOrRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXB;
  if srcReg >= R8 then RexPrefix := RexPrefix or REXR;

  EmitByte(RexPrefix);
  EmitByte($09); // OR r/m64, r64 (Opcode 09 /r)
  WriteModRm($C0, GetRegisterByte(srcReg), GetRegisterByte(destReg)); // Mod=11 (direct register), Reg=src, R/M=dest
end;

procedure TX86_64CodeEmitter.EmitXorRegReg(destReg, srcReg: Byte);
var
  RexPrefix: Byte;
begin
  RexPrefix := REXW; // 64-bit operand
  if destReg >= R8 then RexPrefix := RexPrefix or REXB;
  if srcReg >= R8 then RexPrefix := RexPrefix or REXR;

  EmitByte(RexPrefix);
  EmitByte($31); // XOR r/m64, r64 (Opcode 31 /r)
  WriteModRm($C0, GetRegisterByte(srcReg), GetRegisterByte(destReg)); // Mod=11 (direct register), Reg=src, R/M=dest
end;

procedure TX86_64CodeEmitter.EmitNotReg(reg: Byte);
var
  RexPrefix: Byte;
begin
  // NOT r/m64 (Opcode F7 /2)
  RexPrefix := REXW; // 64-bit operand
  if reg >= R8 then RexPrefix := RexPrefix or REXB;

  EmitByte(RexPrefix);
  EmitByte($F7);
  WriteModRm($C0, $02, GetRegisterByte(reg)); // Mod=11, Reg/Opcode=2 (for NOT), R/M=reg
end;

procedure TX86_64CodeEmitter.EmitShlRegImm(reg: Byte; imm8: Byte);
var
  RexPrefix: Byte;
begin
  // SHL r/m64, imm8 (Opcode C1 /4)
  RexPrefix := REXW; // 64-bit operand
  if reg >= R8 then RexPrefix := RexPrefix or REXB;

  EmitByte(RexPrefix);
  EmitByte($C1);
  WriteModRm($C0, $04, GetRegisterByte(reg)); // Mod=11, Reg/Opcode=4 (for SHL), R/M=reg
  EmitByte(imm8);
end;

procedure TX86_64CodeEmitter.EmitShrRegImm(reg: Byte; imm8: Byte);
var
  RexPrefix: Byte;
begin
  // SHR r/m64, imm8 (Opcode C1 /5)
  RexPrefix := REXW; // 64-bit operand
  if reg >= R8 then RexPrefix := RexPrefix or REXB;

  EmitByte(RexPrefix);
  EmitByte($C1);
  WriteModRm($C0, $05, GetRegisterByte(reg)); // Mod=11, Reg/Opcode=5 (for SHR), R/M=reg
  EmitByte(imm8);
end;

procedure TX86_64CodeEmitter.EmitCall(targetAddr: UInt64);
begin
  // Für absolute Adressen: MOV RAX, targetAddr; CALL RAX
  // Dies ist ein vereinfachter Ansatz. Besser wäre CALL rel32
  EmitMovRegImm(RAX, targetAddr);
  EmitByte($FF); // CALL r/m64 (Opcode FF /2)
  WriteModRm($C0, $02, RAX); // Mod=11, Reg/Opcode=2 (for CALL), R/M=RAX
end;

procedure TX86_64CodeEmitter.EmitRet;
begin
  EmitByte($C3); // RET
end;

procedure TX86_64CodeEmitter.EmitSyscall;
begin
  EmitByte($0F);
  EmitByte($05); // SYSCALL
end;

procedure TX86_64CodeEmitter.EmitLabel(const name: string);
var
  idx: Integer;
begin
  // Check for duplicate label definition
  idx := FLabelMap.IndexOf(name);
  if idx >= 0 then
  begin
    // Error: Label already defined
    // For now, simply ignore or log an error. In a full compiler, this would be a fatal error.
    Exit;
  end;
  // Store current position of label
  FLabelMap.AddObject(name, TObject(FBuffer.Position));
end;

procedure TX86_64CodeEmitter.EmitJmp(const targetLabel: string);
var
  targetPos: Integer;
  currentPos: Integer;
  relOffset: Int32;
begin
  // JMP rel32 (Opcode E9 + 4-byte relative offset)
  EmitByte($E9);
  currentPos := FBuffer.Position;
  if FLabelMap.IndexOf(targetLabel) >= 0 then
  begin
    // Label already defined, calculate relative offset
    targetPos := Integer(FLabelMap.Objects[FLabelMap.IndexOf(targetLabel)]);
    relOffset := targetPos - (currentPos + 4); // +4 for length of offset itself
    EmitU32(relOffset);
  end
  else
  begin
    // Label not yet defined, add a relocation entry
    AddRelocation(targetLabel, currentPos, 4); // 4 bytes for rel32
    EmitU32(0); // Placeholder for offset
  end;
end;

procedure TX86_64CodeEmitter.PatchRelocations;
var
  i: Integer;
  s: string;
  parts: TStringDynArray;
  labelName: string;
  offset: Integer;
  size: Integer;
  targetPos: Integer;
  relOffset: Int32;
begin
  for i := 0 to FRelocations.Count - 1 do
  begin
    s := FRelocations[i];
    parts := s.Split([':']);
    if Length(parts) = 3 then
    begin
      labelName := parts[0];
      offset := StrToInt(parts[1]);
      size := StrToInt(parts[2]);

      targetPos := -1;
      if FLabelMap.IndexOf(labelName) >= 0 then
        targetPos := Integer(FLabelMap.Objects[FLabelMap.IndexOf(labelName)]);

      if targetPos = -1 then
      begin
        // Error: Undefined label for relocation
        // In a real compiler, this would be a linker error
        Continue;
      end;

      // Calculate relative offset: target address - (current instruction address + size of offset field)
      relOffset := targetPos - (offset + size);

      // Patch the buffer
      FBuffer.PatchU32LE(offset, relOffset);
    end;
  end;
end;

end.
