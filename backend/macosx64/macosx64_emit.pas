{$mode objfpc}{$H+}
unit macosx64_emit;

{ macOS x86_64 Code-Emitter
  
  Dieser Emitter ist für macOS x86_64 optimiert und verwendet
  die macOS-spezifischen Syscall-Nummern.
  
  Aufrufkonvention: System V AMD64 ABI (wie Linux)
    - Parameter: RDI, RSI, RDX, RCX, R8, R9
    - Return: RAX
    - Caller-saved: RAX, RCX, RDX, RSI, RDI, R8-R11
    - Callee-saved: RBX, RBP, R12-R15
    
  Syscall-Konvention (macOS):
    - Syscall-Nummer: RAX (mit 0x2000000 Präfix für BSD-Syscalls)
    - Parameter: RDI, RSI, RDX, R10, R8, R9 (Beachte: R10 statt RCX!)
    - Return: RAX (bei Fehler: CF gesetzt)
    - Instruktion: SYSCALL
}

interface

uses
  SysUtils, Classes,
  bytes,              // TByteBuffer
  ir,                 // TIROpKind
  syscalls_macos;     // macOS Syscall-Konstanten

type
  { x86_64 Register-Indizes }
  TX86_64Reg = (
    regRAX = 0, regRCX = 1, regRDX = 2, regRBX = 3,
    regRSP = 4, regRBP = 5, regRSI = 6, regRDI = 7,
    regR8  = 8, regR9  = 9, regR10 = 10, regR11 = 11,
    regR12 = 12, regR13 = 13, regR14 = 14, regR15 = 15
  );

  { macOS x86_64 Code-Emitter }
  TMacOSX64CodeEmitter = class
  private
    FBuffer: TByteBuffer;
    FLabelMap: TStringList;      // Label-Name -> Position im Buffer
    FRelocations: TStringList;   // Pending Relocations: 'label:offset:size'
    
    procedure WriteModRM(modVal, regOp, rm: Byte);
    procedure WriteSIB(scale, index, base: Byte);
    procedure AddRelocation(const labelName: string; offset, size: Integer);
    function GetRegLow3(reg: TX86_64Reg): Byte;
    function NeedsREXB(reg: TX86_64Reg): Boolean;
    function NeedsREXR(reg: TX86_64Reg): Boolean;
    
  public
    constructor Create(aBuffer: TByteBuffer);
    destructor Destroy; override;
    
    function GetBuffer: TByteBuffer;
    function GetPosition: Integer;
    
    { Basis-Emit-Methoden }
    procedure EmitByte(b: Byte);
    procedure EmitBytes(const b: array of Byte);
    procedure EmitU16(val: UInt16);
    procedure EmitU32(val: UInt32);
    procedure EmitU64(val: UInt64);
    procedure EmitI32(val: Int32);
    
    { Register-Operationen }
    procedure EmitMovRegImm64(dest: TX86_64Reg; imm: Int64);
    procedure EmitMovRegImm32(dest: TX86_64Reg; imm: Int32);
    procedure EmitMovRegReg(dest, src: TX86_64Reg);
    procedure EmitMovRegMem(dest: TX86_64Reg; base: TX86_64Reg; disp: Int32);
    procedure EmitMovMemReg(base: TX86_64Reg; disp: Int32; src: TX86_64Reg);
    
    { Arithmetik }
    procedure EmitAddRegReg(dest, src: TX86_64Reg);
    procedure EmitAddRegImm32(dest: TX86_64Reg; imm: Int32);
    procedure EmitSubRegReg(dest, src: TX86_64Reg);
    procedure EmitSubRegImm32(dest: TX86_64Reg; imm: Int32);
    procedure EmitIMulRegReg(dest, src: TX86_64Reg);
    procedure EmitIDivReg(divisor: TX86_64Reg);
    procedure EmitCqo;  // Sign-extend RAX to RDX:RAX
    procedure EmitNegReg(reg: TX86_64Reg);
    
    { Bitweise Operationen }
    procedure EmitAndRegReg(dest, src: TX86_64Reg);
    procedure EmitOrRegReg(dest, src: TX86_64Reg);
    procedure EmitXorRegReg(dest, src: TX86_64Reg);
    procedure EmitNotReg(reg: TX86_64Reg);
    procedure EmitShlRegImm(reg: TX86_64Reg; imm: Byte);
    procedure EmitShrRegImm(reg: TX86_64Reg; imm: Byte);
    procedure EmitSarRegImm(reg: TX86_64Reg; imm: Byte);  // Arithmetic shift right
    
    { Vergleiche }
    procedure EmitCmpRegReg(r1, r2: TX86_64Reg);
    procedure EmitCmpRegImm32(reg: TX86_64Reg; imm: Int32);
    procedure EmitTestRegReg(r1, r2: TX86_64Reg);
    
    { Bedingte Setzung }
    procedure EmitSetE(dest: TX86_64Reg);   // Set if equal (ZF=1)
    procedure EmitSetNE(dest: TX86_64Reg);  // Set if not equal (ZF=0)
    procedure EmitSetL(dest: TX86_64Reg);   // Set if less (SF!=OF)
    procedure EmitSetLE(dest: TX86_64Reg);  // Set if less or equal
    procedure EmitSetG(dest: TX86_64Reg);   // Set if greater
    procedure EmitSetGE(dest: TX86_64Reg);  // Set if greater or equal
    
    { Sprünge }
    procedure EmitJmp(const targetLabel: string);
    procedure EmitJmpRel32(offset: Int32);
    procedure EmitJE(const targetLabel: string);   // Jump if equal
    procedure EmitJNE(const targetLabel: string);  // Jump if not equal
    procedure EmitJL(const targetLabel: string);   // Jump if less
    procedure EmitJLE(const targetLabel: string);  // Jump if less or equal
    procedure EmitJG(const targetLabel: string);   // Jump if greater
    procedure EmitJGE(const targetLabel: string);  // Jump if greater or equal
    procedure EmitJZ(const targetLabel: string);   // Jump if zero (= JE)
    procedure EmitJNZ(const targetLabel: string);  // Jump if not zero (= JNE)
    
    { Funktionsaufrufe }
    procedure EmitCall(const targetLabel: string);
    procedure EmitCallReg(reg: TX86_64Reg);
    procedure EmitRet;
    
    { Stack-Operationen }
    procedure EmitPush(reg: TX86_64Reg);
    procedure EmitPop(reg: TX86_64Reg);
    
    { System-Aufrufe (macOS) }
    procedure EmitSyscall;
    
    { Labels }
    procedure EmitLabel(const name: string);
    
    { Relokationen patchen }
    procedure PatchRelocations;
    
    { ============================================================
      macOS-spezifische Builtin-Funktionen
      ============================================================ }
    
    { PrintStr: Gibt einen String auf stdout aus
      Erwartet: RDI = Pointer auf String, RSI = Länge }
    procedure EmitBuiltinPrintStr;
    
    { PrintInt: Gibt eine 64-bit Ganzzahl auf stdout aus
      Erwartet: RDI = int64 Wert }
    procedure EmitBuiltinPrintInt;
    
    { Exit: Beendet das Programm
      Erwartet: RDI = Exit-Code }
    procedure EmitBuiltinExit;
    
    { Syscall-Wrapper für write(fd, buf, count)
      Erwartet: RDI = fd, RSI = buf, RDX = count
      Gibt zurück: RAX = geschriebene Bytes oder -1 bei Fehler }
    procedure EmitSyscallWrite;
    
    { Syscall-Wrapper für exit(status)
      Erwartet: RDI = status
      Kehrt nicht zurück }
    procedure EmitSyscallExit;
  end;

implementation

const
  // REX Präfix-Bits
  REX_BASE = $40;
  REX_W    = $08;  // 64-bit Operandengröße
  REX_R    = $04;  // Erweiterung des ModRM.reg Feldes
  REX_X    = $02;  // Erweiterung des SIB.index Feldes
  REX_B    = $01;  // Erweiterung des ModRM.rm oder SIB.base Feldes

{ ============================================================
  Konstruktor/Destruktor
  ============================================================ }

constructor TMacOSX64CodeEmitter.Create(aBuffer: TByteBuffer);
begin
  inherited Create;
  FBuffer := aBuffer;
  FLabelMap := TStringList.Create;
  FLabelMap.Sorted := False;
  FRelocations := TStringList.Create;
  FRelocations.Sorted := False;
end;

destructor TMacOSX64CodeEmitter.Destroy;
begin
  FLabelMap.Free;
  FRelocations.Free;
  inherited Destroy;
end;

function TMacOSX64CodeEmitter.GetBuffer: TByteBuffer;
begin
  Result := FBuffer;
end;

function TMacOSX64CodeEmitter.GetPosition: Integer;
begin
  Result := FBuffer.Size;
end;

{ ============================================================
  Hilfsfunktionen
  ============================================================ }

function TMacOSX64CodeEmitter.GetRegLow3(reg: TX86_64Reg): Byte;
begin
  Result := Ord(reg) and $07;
end;

function TMacOSX64CodeEmitter.NeedsREXB(reg: TX86_64Reg): Boolean;
begin
  Result := Ord(reg) >= 8;
end;

function TMacOSX64CodeEmitter.NeedsREXR(reg: TX86_64Reg): Boolean;
begin
  Result := Ord(reg) >= 8;
end;

procedure TMacOSX64CodeEmitter.WriteModRM(modVal, regOp, rm: Byte);
begin
  EmitByte((modVal shl 6) or ((regOp and $07) shl 3) or (rm and $07));
end;

procedure TMacOSX64CodeEmitter.WriteSIB(scale, index, base: Byte);
begin
  EmitByte((scale shl 6) or ((index and $07) shl 3) or (base and $07));
end;

procedure TMacOSX64CodeEmitter.AddRelocation(const labelName: string; offset, size: Integer);
begin
  FRelocations.Add(Format('%s:%d:%d', [labelName, offset, size]));
end;

{ ============================================================
  Basis-Emit-Methoden
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitByte(b: Byte);
begin
  FBuffer.WriteU8(b);
end;

procedure TMacOSX64CodeEmitter.EmitBytes(const b: array of Byte);
var
  i: Integer;
begin
  for i := Low(b) to High(b) do
    FBuffer.WriteU8(b[i]);
end;

procedure TMacOSX64CodeEmitter.EmitU16(val: UInt16);
begin
  FBuffer.WriteU16LE(val);
end;

procedure TMacOSX64CodeEmitter.EmitU32(val: UInt32);
begin
  FBuffer.WriteU32LE(val);
end;

procedure TMacOSX64CodeEmitter.EmitU64(val: UInt64);
begin
  FBuffer.WriteU64LE(val);
end;

procedure TMacOSX64CodeEmitter.EmitI32(val: Int32);
begin
  FBuffer.WriteU32LE(UInt32(val));
end;

{ ============================================================
  Register-Operationen
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitMovRegImm64(dest: TX86_64Reg; imm: Int64);
var
  rex: Byte;
begin
  // MOV r64, imm64 (REX.W + B8+rd)
  rex := REX_BASE or REX_W;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($B8 + GetRegLow3(dest));
  EmitU64(UInt64(imm));
end;

procedure TMacOSX64CodeEmitter.EmitMovRegImm32(dest: TX86_64Reg; imm: Int32);
var
  rex: Byte;
begin
  // MOV r64, imm32 (sign-extended): REX.W + C7 /0
  rex := REX_BASE or REX_W;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($C7);
  WriteModRM($03, 0, GetRegLow3(dest));
  EmitI32(imm);
end;

procedure TMacOSX64CodeEmitter.EmitMovRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // MOV r64, r64: REX.W + 89 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($89);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitMovRegMem(dest: TX86_64Reg; base: TX86_64Reg; disp: Int32);
var
  rex: Byte;
  modVal: Byte;
begin
  // MOV r64, [base+disp]: REX.W + 8B /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(dest) then
    rex := rex or REX_R;
  if NeedsREXB(base) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($8B);
  
  if disp = 0 then
    modVal := $00
  else if (disp >= -128) and (disp <= 127) then
    modVal := $01
  else
    modVal := $02;
    
  WriteModRM(modVal, GetRegLow3(dest), GetRegLow3(base));
  
  // SIB-Byte für RSP/R12 als Basis
  if (base = regRSP) or (base = regR12) then
    WriteSIB(0, 4, GetRegLow3(base));
    
  if modVal = $01 then
    EmitByte(Byte(disp))
  else if modVal = $02 then
    EmitI32(disp);
end;

procedure TMacOSX64CodeEmitter.EmitMovMemReg(base: TX86_64Reg; disp: Int32; src: TX86_64Reg);
var
  rex: Byte;
  modVal: Byte;
begin
  // MOV [base+disp], r64: REX.W + 89 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(base) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($89);
  
  if disp = 0 then
    modVal := $00
  else if (disp >= -128) and (disp <= 127) then
    modVal := $01
  else
    modVal := $02;
    
  WriteModRM(modVal, GetRegLow3(src), GetRegLow3(base));
  
  if (base = regRSP) or (base = regR12) then
    WriteSIB(0, 4, GetRegLow3(base));
    
  if modVal = $01 then
    EmitByte(Byte(disp))
  else if modVal = $02 then
    EmitI32(disp);
end;

{ ============================================================
  Arithmetik
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitAddRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // ADD r64, r64: REX.W + 01 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($01);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitAddRegImm32(dest: TX86_64Reg; imm: Int32);
var
  rex: Byte;
begin
  // ADD r64, imm32: REX.W + 81 /0
  rex := REX_BASE or REX_W;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($81);
  WriteModRM($03, 0, GetRegLow3(dest));
  EmitI32(imm);
end;

procedure TMacOSX64CodeEmitter.EmitSubRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // SUB r64, r64: REX.W + 29 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($29);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSubRegImm32(dest: TX86_64Reg; imm: Int32);
var
  rex: Byte;
begin
  // SUB r64, imm32: REX.W + 81 /5
  rex := REX_BASE or REX_W;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($81);
  WriteModRM($03, 5, GetRegLow3(dest));
  EmitI32(imm);
end;

procedure TMacOSX64CodeEmitter.EmitIMulRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // IMUL r64, r64: REX.W + 0F AF /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(dest) then
    rex := rex or REX_R;
  if NeedsREXB(src) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitBytes([$0F, $AF]);
  WriteModRM($03, GetRegLow3(dest), GetRegLow3(src));
end;

procedure TMacOSX64CodeEmitter.EmitIDivReg(divisor: TX86_64Reg);
var
  rex: Byte;
begin
  // IDIV r64: REX.W + F7 /7
  rex := REX_BASE or REX_W;
  if NeedsREXB(divisor) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($F7);
  WriteModRM($03, 7, GetRegLow3(divisor));
end;

procedure TMacOSX64CodeEmitter.EmitCqo;
begin
  // CQO: REX.W + 99 (Sign-extend RAX to RDX:RAX)
  EmitBytes([REX_BASE or REX_W, $99]);
end;

procedure TMacOSX64CodeEmitter.EmitNegReg(reg: TX86_64Reg);
var
  rex: Byte;
begin
  // NEG r64: REX.W + F7 /3
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($F7);
  WriteModRM($03, 3, GetRegLow3(reg));
end;

{ ============================================================
  Bitweise Operationen
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitAndRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // AND r64, r64: REX.W + 21 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($21);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitOrRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // OR r64, r64: REX.W + 09 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($09);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitXorRegReg(dest, src: TX86_64Reg);
var
  rex: Byte;
begin
  // XOR r64, r64: REX.W + 31 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(src) then
    rex := rex or REX_R;
  if NeedsREXB(dest) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($31);
  WriteModRM($03, GetRegLow3(src), GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitNotReg(reg: TX86_64Reg);
var
  rex: Byte;
begin
  // NOT r64: REX.W + F7 /2
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($F7);
  WriteModRM($03, 2, GetRegLow3(reg));
end;

procedure TMacOSX64CodeEmitter.EmitShlRegImm(reg: TX86_64Reg; imm: Byte);
var
  rex: Byte;
begin
  // SHL r64, imm8: REX.W + C1 /4
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($C1);
  WriteModRM($03, 4, GetRegLow3(reg));
  EmitByte(imm);
end;

procedure TMacOSX64CodeEmitter.EmitShrRegImm(reg: TX86_64Reg; imm: Byte);
var
  rex: Byte;
begin
  // SHR r64, imm8: REX.W + C1 /5
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($C1);
  WriteModRM($03, 5, GetRegLow3(reg));
  EmitByte(imm);
end;

procedure TMacOSX64CodeEmitter.EmitSarRegImm(reg: TX86_64Reg; imm: Byte);
var
  rex: Byte;
begin
  // SAR r64, imm8: REX.W + C1 /7
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($C1);
  WriteModRM($03, 7, GetRegLow3(reg));
  EmitByte(imm);
end;

{ ============================================================
  Vergleiche
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitCmpRegReg(r1, r2: TX86_64Reg);
var
  rex: Byte;
begin
  // CMP r64, r64: REX.W + 39 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(r2) then
    rex := rex or REX_R;
  if NeedsREXB(r1) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($39);
  WriteModRM($03, GetRegLow3(r2), GetRegLow3(r1));
end;

procedure TMacOSX64CodeEmitter.EmitCmpRegImm32(reg: TX86_64Reg; imm: Int32);
var
  rex: Byte;
begin
  // CMP r64, imm32: REX.W + 81 /7
  rex := REX_BASE or REX_W;
  if NeedsREXB(reg) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($81);
  WriteModRM($03, 7, GetRegLow3(reg));
  EmitI32(imm);
end;

procedure TMacOSX64CodeEmitter.EmitTestRegReg(r1, r2: TX86_64Reg);
var
  rex: Byte;
begin
  // TEST r64, r64: REX.W + 85 /r
  rex := REX_BASE or REX_W;
  if NeedsREXR(r2) then
    rex := rex or REX_R;
  if NeedsREXB(r1) then
    rex := rex or REX_B;
  EmitByte(rex);
  EmitByte($85);
  WriteModRM($03, GetRegLow3(r2), GetRegLow3(r1));
end;

{ ============================================================
  Bedingte Setzung (SETcc)
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitSetE(dest: TX86_64Reg);
begin
  // SETE r8: 0F 94 /0 (erfordert REX für R8-R15)
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $94]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSetNE(dest: TX86_64Reg);
begin
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $95]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSetL(dest: TX86_64Reg);
begin
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $9C]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSetLE(dest: TX86_64Reg);
begin
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $9E]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSetG(dest: TX86_64Reg);
begin
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $9F]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

procedure TMacOSX64CodeEmitter.EmitSetGE(dest: TX86_64Reg);
begin
  if NeedsREXB(dest) then
    EmitByte(REX_BASE or REX_B);
  EmitBytes([$0F, $9D]);
  WriteModRM($03, 0, GetRegLow3(dest));
end;

{ ============================================================
  Sprünge
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitJmp(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JMP rel32: E9 + 4-byte displacement
  EmitByte($E9);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);  // Platzhalter
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJmpRel32(offset: Int32);
begin
  EmitByte($E9);
  EmitI32(offset);
end;

procedure TMacOSX64CodeEmitter.EmitJE(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JE rel32: 0F 84 + 4-byte displacement
  EmitBytes([$0F, $84]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJNE(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JNE rel32: 0F 85 + 4-byte displacement
  EmitBytes([$0F, $85]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJL(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JL rel32: 0F 8C
  EmitBytes([$0F, $8C]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJLE(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JLE rel32: 0F 8E
  EmitBytes([$0F, $8E]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJG(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JG rel32: 0F 8F
  EmitBytes([$0F, $8F]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJGE(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // JGE rel32: 0F 8D
  EmitBytes([$0F, $8D]);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitJZ(const targetLabel: string);
begin
  EmitJE(targetLabel);  // JZ = JE
end;

procedure TMacOSX64CodeEmitter.EmitJNZ(const targetLabel: string);
begin
  EmitJNE(targetLabel);  // JNZ = JNE
end;

{ ============================================================
  Funktionsaufrufe
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitCall(const targetLabel: string);
var
  idx, targetPos, currentPos: Integer;
  relOffset: Int32;
begin
  // CALL rel32: E8 + 4-byte displacement
  EmitByte($E8);
  currentPos := FBuffer.Size;
  
  idx := FLabelMap.IndexOf(targetLabel);
  if idx >= 0 then
  begin
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (currentPos + 4);
    EmitI32(relOffset);
  end
  else
  begin
    AddRelocation(targetLabel, currentPos, 4);
    EmitU32(0);
  end;
end;

procedure TMacOSX64CodeEmitter.EmitCallReg(reg: TX86_64Reg);
var
  rex: Byte;
begin
  // CALL r64: FF /2
  if NeedsREXB(reg) then
  begin
    rex := REX_BASE or REX_B;
    EmitByte(rex);
  end;
  EmitByte($FF);
  WriteModRM($03, 2, GetRegLow3(reg));
end;

procedure TMacOSX64CodeEmitter.EmitRet;
begin
  EmitByte($C3);  // RET
end;

{ ============================================================
  Stack-Operationen
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitPush(reg: TX86_64Reg);
begin
  // PUSH r64: 50+rd (mit REX.B für R8-R15)
  if NeedsREXB(reg) then
    EmitByte(REX_BASE or REX_B);
  EmitByte($50 + GetRegLow3(reg));
end;

procedure TMacOSX64CodeEmitter.EmitPop(reg: TX86_64Reg);
begin
  // POP r64: 58+rd (mit REX.B für R8-R15)
  if NeedsREXB(reg) then
    EmitByte(REX_BASE or REX_B);
  EmitByte($58 + GetRegLow3(reg));
end;

{ ============================================================
  System-Aufrufe
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitSyscall;
begin
  EmitBytes([$0F, $05]);  // SYSCALL
end;

{ ============================================================
  Labels
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitLabel(const name: string);
var
  idx: Integer;
begin
  idx := FLabelMap.IndexOf(name);
  if idx >= 0 then
    Exit;  // Label bereits definiert (Fehler ignorieren)
  FLabelMap.AddObject(name, TObject(PtrInt(FBuffer.Size)));
end;

procedure TMacOSX64CodeEmitter.PatchRelocations;
var
  i: Integer;
  s: string;
  labelName: string;
  offset, size, targetPos: Integer;
  relOffset: Int32;
  idx: Integer;
  colonPos1, colonPos2: Integer;
begin
  for i := 0 to FRelocations.Count - 1 do
  begin
    s := FRelocations[i];
    
    // Manuelles Parsen von 'labelName:offset:size'
    colonPos1 := Pos(':', s);
    if colonPos1 = 0 then Continue;
    
    labelName := Copy(s, 1, colonPos1 - 1);
    Delete(s, 1, colonPos1);
    
    colonPos2 := Pos(':', s);
    if colonPos2 = 0 then Continue;
    
    offset := StrToIntDef(Copy(s, 1, colonPos2 - 1), -1);
    size := StrToIntDef(Copy(s, colonPos2 + 1, Length(s)), -1);
    
    if (offset < 0) or (size < 0) then Continue;
      
    idx := FLabelMap.IndexOf(labelName);
    if idx < 0 then
      Continue;  // Undefiniertes Label (Fehler)
      
    targetPos := PtrInt(FLabelMap.Objects[idx]);
    relOffset := targetPos - (offset + size);
    FBuffer.PatchU32LE(offset, UInt32(relOffset));
  end;
end;

{ ============================================================
  macOS-spezifische Builtin-Funktionen
  ============================================================ }

procedure TMacOSX64CodeEmitter.EmitSyscallWrite;
begin
  // write(fd, buf, count) - macOS Syscall
  // Parameter bereits in RDI, RSI, RDX
  // Syscall-Nummer in RAX
  EmitMovRegImm32(regRAX, SYS_WRITE);
  EmitSyscall;
end;

procedure TMacOSX64CodeEmitter.EmitSyscallExit;
begin
  // exit(status) - macOS Syscall
  // Parameter in RDI
  // Syscall-Nummer in RAX
  EmitMovRegImm32(regRAX, SYS_EXIT);
  EmitSyscall;
end;

procedure TMacOSX64CodeEmitter.EmitBuiltinPrintStr;
begin
  // PrintStr(str, len)
  // Erwartet: RDI = Pointer auf String, RSI = Länge
  // Wir müssen: write(STDOUT_FILENO, str, len)
  
  // Parameter-Mapping:
  // RDI = str -> RSI (buf)
  // RSI = len -> RDX (count)
  // STDOUT_FILENO (1) -> RDI (fd)
  
  EmitMovRegReg(regRDX, regRSI);   // count = len
  EmitMovRegReg(regRSI, regRDI);   // buf = str
  EmitMovRegImm32(regRDI, STDOUT_FILENO);  // fd = 1
  EmitSyscallWrite;
  EmitRet;
end;

procedure TMacOSX64CodeEmitter.EmitBuiltinPrintInt;
var
  bufferOffset: Int32;
begin
  // PrintInt(value)
  // Erwartet: RDI = int64 Wert
  // Konvertiert Zahl zu String und gibt sie aus
  
  // Stack-Frame einrichten (32 Bytes für Puffer)
  EmitPush(regRBP);
  EmitMovRegReg(regRBP, regRSP);
  EmitSubRegImm32(regRSP, 32);
  
  // Wert sichern
  EmitPush(regRBX);
  EmitPush(regR12);
  EmitMovRegReg(regRAX, regRDI);  // Wert in RAX
  
  // Negatives Vorzeichen prüfen
  EmitTestRegReg(regRAX, regRAX);
  EmitLabel('_printint_positive');
  // TODO: Vorzeichen-Behandlung (jns _printint_positive, neg, ...)
  
  // Puffer-Ende (wir schreiben rückwärts)
  bufferOffset := -8;  // Relativ zu RBP
  EmitMovRegReg(regR12, regRBP);
  EmitAddRegImm32(regR12, bufferOffset);
  
  // Ziffern extrahieren (Division durch 10)
  EmitLabel('_printint_loop');
  EmitXorRegReg(regRDX, regRDX);  // RDX:RAX für Division
  EmitMovRegImm32(regRBX, 10);
  EmitIDivReg(regRBX);            // RAX = quotient, RDX = remainder
  
  EmitAddRegImm32(regRDX, Ord('0'));  // Ziffer -> ASCII
  // Byte in Puffer schreiben (vereinfacht)
  EmitSubRegImm32(regR12, 1);
  EmitMovMemReg(regR12, 0, regRDX);
  
  // Weitere Ziffern?
  EmitTestRegReg(regRAX, regRAX);
  EmitJNZ('_printint_loop');
  
  // String ausgeben
  EmitMovRegReg(regRSI, regR12);  // buf
  EmitMovRegReg(regRDX, regRBP);
  EmitAddRegImm32(regRDX, bufferOffset);
  EmitSubRegReg(regRDX, regR12);  // len = end - current
  EmitMovRegImm32(regRDI, STDOUT_FILENO);
  EmitSyscallWrite;
  
  // Stack-Frame aufräumen
  EmitPop(regR12);
  EmitPop(regRBX);
  EmitMovRegReg(regRSP, regRBP);
  EmitPop(regRBP);
  EmitRet;
end;

procedure TMacOSX64CodeEmitter.EmitBuiltinExit;
begin
  // Exit(code)
  // Erwartet: RDI = Exit-Code
  EmitSyscallExit;
  // Kehrt nie zurück
end;

end.
