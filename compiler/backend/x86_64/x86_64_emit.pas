{$mode objfpc}{$H+}
unit x86_64_emit;

{ macOS x86_64 Emitter
  
  Dieser Emitter ist weitgehend identisch mit dem Linux x86_64 Emitter,
  da beide die gleiche CPU-Architektur und Calling Convention verwenden.
  Der Hauptunterschied sind die Syscall-Nummern.
  
  macOS verwendet das XNU-Kernel-Syscall-Interface:
  - Syscall-Nummern haben ein 0x2000000 Präfix für BSD-Syscalls
  - Aufrufkonvention: RDI, RSI, RDX, R10, R8, R9 (wie Linux)
  - SYSCALL Instruktion
  
  TODO: Derzeit ist dies eine minimale Implementierung, die nur
  grundlegende Funktionalität bietet. Für volle Kompatibilität
  müssen alle Linux-Syscall-Nummern durch macOS-Äquivalente ersetzt werden.
}

interface

uses
  SysUtils, Classes, bytes, ir, ast, backend_types, energy_model;

type
  TLabelPos = record
    Name: string;
    Pos: Integer;
  end;

  TJumpPatch = record
    Pos: Integer;
    LabelName: string;
    JmpSize: Integer;
  end;

  TEnergyOpKind = (eokALU, eokFPU, eokMemory, eokBranch, eokSyscall);

  { TX86_64Emitter - High-Level IR-zu-Maschinencode Emitter für macOS x86_64 }
  TX86_64Emitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FLabelPositions: array of TLabelPos;
    FJumpPatches: array of TJumpPatch;
    FBranchPatches: array of TJumpPatch;  // For irJmp, irBrTrue, irBrFalse
    FBranchLabels: TStringList;  // Label name -> code position mapping
    FVMTLabels: array of TLabelPos;
    FVMTLeaPositions: array of record
      VMTIndex: Integer;     // Index in module.ClassDecls
      MethodIndex: Integer;  // Index in VirtualMethods array
      CodePos: Integer;      // Position of placeholder in code
    end;
    FVMTAddrLeaPositions: array of record
      VMTLabelIndex: Integer;  // Index in FVMTLabels
      CodePos: Integer;         // Position of LEA disp32
    end;
    FIsTypeLeaPositions: array of record
      DataOffset: Integer;
      CodePos: Integer;
    end;
    FExternalSymbols: array of TExternalSymbol;
    FPLTGOTPatches: array of TPLTGOTPatch;
    FEnergyStats: TEnergyStats;
    FEnergyContext: TEnergyContext;
    FCurrentCPU: TCPUEnergyModel;
    FMemoryAccessCount: UInt64;
    FCurrentFunctionEnergy: UInt64;
    FTargetOS: TTargetOS;  // atLinux or atmacOS

    function SysNum(linuxN, macosN: Int64): Int64;
    procedure TrackEnergy(kind: TEnergyOpKind);
    procedure EmitDebugPrintString(const s: string);
    procedure EmitDebugPrintInt(valueReg: Integer);
    
    { Syscall-Helfer für macOS }
    procedure EmitSyscallWrite;   // sys_write = 0x2000004
    procedure EmitSyscallExit;    // sys_exit = 0x2000001
    procedure EmitSyscallRead;    // sys_read = 0x2000003
    procedure EmitSyscallOpen;    // sys_open = 0x2000005
    procedure EmitSyscallClose;   // sys_close = 0x2000006
    procedure EmitSyscallMmap;    // sys_mmap = 0x20000C5
    procedure EmitSyscallMunmap;  // sys_munmap = 0x2000049
    
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetFunctionOffset(const name: string): Integer;
    function GetExternalSymbols: TExternalSymbolArray;
    function GetPLTGOTPatches: TPLTGOTPatchArray;
    function AddExternalSymbol(const name, libName: string): Integer;
    function GetEnergyStats: TEnergyStats;
    procedure SetEnergyLevel(level: TEnergyLevel);
    procedure SetTargetOS(os: TTargetOS);
  end;

implementation

uses
  Math;

const
  // Register-Konstanten
  RAX = 0; RCX = 1; RDX = 2; RBX = 3; RSP = 4; RBP = 5; RSI = 6; RDI = 7;
  R8 = 8; R9 = 9; R10 = 10; R11 = 11; R12 = 12; R13 = 13; R14 = 14; R15 = 15;
  XMM0 = 0; XMM1 = 1; XMM2 = 2; XMM3 = 3;
  ParamRegs: array[0..5] of Byte = (RDI, RSI, RDX, RCX, R8, R9);

  // ELF static layout constants (must match elf64_writer.pas)
  ELF_PAGE_SIZE = 4096;
  ELF_BASE_VA = $400000;
  ELF_CODE_OFFSET = ELF_PAGE_SIZE;  // 0x1000
  ELF_DATA_OFFSET = ELF_CODE_OFFSET + ELF_PAGE_SIZE;  // 0x2000

  // macOS Syscall-Nummern (BSD-Layer, 0x2000000 Prefix)
  SYS_MACOS_EXIT    = $2000001;  // sys_exit
  SYS_MACOS_FORK    = $2000002;  // sys_fork
  SYS_MACOS_READ    = $2000003;  // sys_read
  SYS_MACOS_WRITE   = $2000004;  // sys_write
  SYS_MACOS_OPEN    = $2000005;  // sys_open
  SYS_MACOS_CLOSE   = $2000006;  // sys_close
  SYS_MACOS_MMAP    = $20000C5;  // sys_mmap (197)
  SYS_MACOS_MUNMAP  = $2000049;  // sys_munmap (73)
  SYS_MACOS_LSEEK   = $20000C7;  // sys_lseek (199)
  SYS_MACOS_UNLINK  = $200000A;  // sys_unlink (10)
  SYS_MACOS_RENAME  = $2000080;  // sys_rename (128)
  SYS_MACOS_MKDIR   = $2000088;  // sys_mkdir (136)
  SYS_MACOS_RMDIR   = $2000089;  // sys_rmdir (137)
  SYS_MACOS_CHMOD   = $200000F;  // sys_chmod (15)
  SYS_MACOS_NANOSLEEP = $20000F0; // sys_nanosleep (240)
  SYS_MACOS_GETTIMEOFDAY = $2000074; // sys_gettimeofday (116)
  SYS_MACOS_SOCKET   = $2000061;  // sys_socket (97)
  SYS_MACOS_BIND     = $2000068;  // sys_bind (104)
  SYS_MACOS_LISTEN   = $200006A;  // sys_listen (106)
  SYS_MACOS_ACCEPT   = $200001E;  // sys_accept (30)
  SYS_MACOS_CONNECT  = $2000062;  // sys_connect (98)
  SYS_MACOS_RECVFROM = $200001D;  // sys_recvfrom (29)
  SYS_MACOS_SENDTO   = $2000085;  // sys_sendto (133)
  SYS_MACOS_SETSOCKOPT = $2000069; // sys_setsockopt (105)
  SYS_MACOS_GETSOCKOPT = $200007D; // sys_getsockopt (125)
  SYS_MACOS_FCNTL    = $200005C;  // sys_fcntl (92)
  SYS_MACOS_SHUTDOWN = $2000086;  // sys_shutdown (134)
  SYS_MACOS_IOCTL    = $2000036;  // sys_ioctl (54)

  // Linux Syscall-Nummern (x86_64 ABI)
  SYS_LINUX_EXIT    = 60;   // sys_exit
  SYS_LINUX_READ    = 0;    // sys_read
  SYS_LINUX_WRITE   = 1;    // sys_write
  SYS_LINUX_OPEN    = 2;    // sys_open
  SYS_LINUX_CLOSE   = 3;    // sys_close
  SYS_LINUX_MMAP    = 9;    // sys_mmap
  SYS_LINUX_MUNMAP  = 11;   // sys_munmap
  SYS_LINUX_LSEEK   = 8;    // sys_lseek
  SYS_LINUX_UNLINK  = 87;   // sys_unlink
  SYS_LINUX_MKDIR   = 83;   // sys_mkdir
  SYS_LINUX_RMDIR   = 84;   // sys_rmdir
  SYS_LINUX_CHMOD   = 90;   // sys_chmod
  SYS_LINUX_SOCKET  = 41;   // sys_socket
  SYS_LINUX_BIND    = 49;   // sys_bind
  SYS_LINUX_LISTEN  = 50;   // sys_listen
  SYS_LINUX_ACCEPT  = 43;   // sys_accept
  SYS_LINUX_CONNECT = 42;   // sys_connect
  SYS_LINUX_RECVFROM = 45;  // sys_recvfrom
  SYS_LINUX_SENDTO  = 44;   // sys_sendto
  SYS_LINUX_SETSOCKOPT = 54;  // sys_setsockopt
  SYS_LINUX_GETSOCKOPT = 55;  // sys_getsockopt
  SYS_LINUX_FCNTL   = 72;   // sys_fcntl
  SYS_LINUX_SHUTDOWN = 48;  // sys_shutdown

{ Hilfsfunktionen für x86_64 Encoding }

procedure EmitU8(b: TByteBuffer; v: Byte);
begin
  b.WriteU8(v);
end;

procedure EmitU32(b: TByteBuffer; v: Cardinal);
begin
  b.WriteU32LE(v);
end;

procedure EmitU64(b: TByteBuffer; v: UInt64);
begin
  b.WriteU64LE(v);
end;

procedure EmitRex(buf: TByteBuffer; w, r, x, b: Integer);
var
  rex: Byte;
begin
  rex := $40 or (Byte(w and 1) shl 3) or (Byte(r and 1) shl 2) or (Byte(x and 1) shl 1) or Byte(b and 1);
  EmitU8(buf, rex);
end;

procedure WriteMovRegImm64(buf: TByteBuffer; reg: Integer; imm: UInt64);
begin
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $B8 + (reg and $7));
  EmitU64(buf, imm);
end;

procedure WriteAndRegImm(buf: TByteBuffer; reg: Integer; imm: UInt64);
begin
  // and r64, imm32 - REX.W prefix + opcode 81 /0
  EmitRex(buf, 1, 0, 0, (reg shr 3) and 1);
  EmitU8(buf, $81); // AND r/m64, imm8/32
  EmitU8(buf, $C0 or (reg and $7)); // ModR/M: register direct
  EmitU32(buf, UInt32(imm)); // Sign-extended immediate
end;

procedure WriteMovRegReg(buf: TByteBuffer; dst, src: Integer);
var
  rexR, rexB: Integer;
begin
  rexR := (src shr 3) and 1;
  rexB := (dst shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $89);
  EmitU8(buf, $C0 or (((src and 7) shl 3) and $38) or (dst and $7));
end;

procedure WriteSyscall(buf: TByteBuffer);
begin
  EmitU8(buf, $0F);
  EmitU8(buf, $05);
end;

procedure WriteRet(buf: TByteBuffer);
begin
  EmitU8(buf, $C3);
end;

procedure WriteMovRegMem(buf: TByteBuffer; reg, base, disp: Integer);
var
  rexR, rexB: Integer;
  modrm, modBits: Byte;
begin
  // mov reg, [base + disp]
  rexR := (reg shr 3) and 1;
  rexB := (base shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $8B); // MOV r64, r/m64
  // choose mod bits: use disp8 if fits, otherwise disp32
  if (disp >= -128) and (disp <= 127) then
    modBits := $40 // mod = 01 (disp8)
  else
    modBits := $80; // mod = 10 (disp32)
  modrm := modBits or Byte(((reg and 7) shl 3) and $38) or Byte(base and $7);
  EmitU8(buf, modrm);
  // if base==RSP we must emit SIB
  if (base and 7) = 4 then
    EmitU8(buf, $24); // scale=0, index=4 (no index), base=4 (RSP)
  // emit displacement
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

procedure WriteMovMemReg(buf: TByteBuffer; base, disp, reg: Integer);
var
  rexR, rexB: Integer;
  modrm, modBits: Byte;
begin
  // mov [base + disp], reg
  rexR := (reg shr 3) and 1;
  rexB := (base shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $89); // MOV r/m64, r64
  // choose mod bits: use disp8 if fits, otherwise disp32
  if (disp >= -128) and (disp <= 127) then
    modBits := $40 // mod = 01 (disp8)
  else
    modBits := $80; // mod = 10 (disp32)
  modrm := modBits or Byte(((reg and 7) shl 3) and $38) or Byte(base and $7);
  EmitU8(buf, modrm);
  // if base==RSP we must emit SIB
  if (base and 7) = 4 then
    EmitU8(buf, $24); // scale=0, index=4 (no index), base=4 (RSP)
  // emit displacement
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

procedure WriteMovzxRegMem8(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movzx r64, byte ptr [base+disp32] : rex.w 0F B6 /r with mod=10
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $B6);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovzxRegMem16(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movzx r64, word ptr [base+disp32] : rex.w 0F B7 /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $B7);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem8(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsx r64, byte ptr [base+disp32] : rex.w 0F BE /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $BE);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem16(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsx r64, word ptr [base+disp32] : rex.w 0F BF /r
  EmitU8(buf, $48);
  EmitU8(buf, $0F);
  EmitU8(buf, $BF);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovSxRegMem32(buf: TByteBuffer; dstReg: Byte; baseReg: Byte; disp32: Integer);
begin
  // movsxd r64, dword ptr [base+disp32] : rex.w 63 /r
  EmitU8(buf, $48);
  EmitU8(buf, $63);
  EmitU8(buf, $80 or ((dstReg shl 3) and $38) or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

procedure WriteMovEAXMem32(buf: TByteBuffer; baseReg: Byte; disp32: Integer);
begin
  // mov eax, dword ptr [base+disp32] : 8B 85 disp32 (implicitly zero-extends to rax)
  EmitU8(buf, $8B);
  EmitU8(buf, $85 or (baseReg and $7));
  EmitU32(buf, Cardinal(disp32));
end;

// === SSE2 Float-Hilfsfunktionen ===

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

function SlotOffset(slot: Integer): Integer;
begin
  Result := -8 * (slot + 1);
end;

{ TX86_64Emitter }

constructor TX86_64Emitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  SetLength(FStringOffsets, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  SetLength(FLabelPositions, 0);
  SetLength(FJumpPatches, 0);
  SetLength(FBranchPatches, 0);
  FBranchLabels := TStringList.Create;
  FBranchLabels.Sorted := True;
  FBranchLabels.Duplicates := dupIgnore;
  SetLength(FVMTLabels, 0);
  SetLength(FExternalSymbols, 0);
  SetLength(FPLTGOTPatches, 0);
  
  FTargetOS := atLinux;

  // Energy-Modell initialisieren
  FCurrentCPU := GetCPUEnergyModel(cfX86_64);
  FEnergyContext.Config := GetEnergyConfig;
  FEnergyContext.CurrentCPU := FCurrentCPU;
  FMemoryAccessCount := 0;
  FCurrentFunctionEnergy := 0;
  FillChar(FEnergyStats, SizeOf(FEnergyStats), 0);
  FEnergyStats.DetailedBreakdown := nil;
end;

destructor TX86_64Emitter.Destroy;
begin
  FBranchLabels.Free;
  FCode.Free;
  FData.Free;
  inherited Destroy;
end;

procedure TX86_64Emitter.TrackEnergy(kind: TEnergyOpKind);
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

function TX86_64Emitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TX86_64Emitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TX86_64Emitter.GetFunctionOffset(const name: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FLabelPositions) do
    if FLabelPositions[i].Name = name then
    begin
      Result := FLabelPositions[i].Pos;
      Exit;
    end;
  Result := -1;
end;

function TX86_64Emitter.GetExternalSymbols: TExternalSymbolArray;
begin
  SetLength(Result, Length(FExternalSymbols));
  if Length(FExternalSymbols) > 0 then
    Move(FExternalSymbols[0], Result[0], Length(FExternalSymbols) * SizeOf(TExternalSymbol));
end;

function TX86_64Emitter.GetPLTGOTPatches: TPLTGOTPatchArray;
begin
  SetLength(Result, Length(FPLTGOTPatches));
  if Length(FPLTGOTPatches) > 0 then
    Move(FPLTGOTPatches[0], Result[0], Length(FPLTGOTPatches) * SizeOf(TPLTGOTPatch));
end;

function TX86_64Emitter.AddExternalSymbol(const name, libName: string): Integer;
var
  i: Integer;
begin
  // Check if already registered
  for i := 0 to High(FExternalSymbols) do
  begin
    if FExternalSymbols[i].Name = name then
      Exit(i);
  end;
  // Add new symbol
  Result := Length(FExternalSymbols);
  SetLength(FExternalSymbols, Result + 1);
  FExternalSymbols[Result].Name := name;
  FExternalSymbols[Result].LibraryName := libName;
end;

function TX86_64Emitter.GetEnergyStats: TEnergyStats;
begin
  FEnergyStats.CodeSizeBytes := FCode.Size;
  FEnergyStats.EstimatedEnergyUnits := FCurrentFunctionEnergy;
  FEnergyStats.L1CacheFootprint := Min(FCode.Size, 32768);
  Result := FEnergyStats;
end;

procedure TX86_64Emitter.SetEnergyLevel(level: TEnergyLevel);
begin
  FEnergyContext.Config.Level := level;
end;

procedure TX86_64Emitter.SetTargetOS(os: TTargetOS);
begin
  FTargetOS := os;
end;

function TX86_64Emitter.SysNum(linuxN, macosN: Int64): Int64;
begin
  if FTargetOS = atmacOS then
    Result := macosN
  else
    Result := linuxN;
end;

{ Syscall-Helfer }

procedure TX86_64Emitter.EmitSyscallWrite;
begin
  // write(fd, buf, count): fd=RDI, buf=RSI, count=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallExit;
begin
  // exit(status): status=RDI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_EXIT);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallRead;
begin
  // read(fd, buf, count): fd=RDI, buf=RSI, count=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_READ);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallOpen;
begin
  // open(path, flags, mode): path=RDI, flags=RSI, mode=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_OPEN);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallClose;
begin
  // close(fd): fd=RDI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_CLOSE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallMmap;
begin
  // mmap(addr, len, prot, flags, fd, offset)
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitSyscallMunmap;
begin
  // munmap(addr, len): addr=RDI, len=RSI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MUNMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TX86_64Emitter.EmitDebugPrintString(const s: string);
begin
  // TODO: Implementieren
end;

procedure TX86_64Emitter.EmitDebugPrintInt(valueReg: Integer);
begin
  // TODO: Implementieren
end;

procedure TX86_64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  labelIdx: Integer;
  fn: TIRFunction;
  slotIdx: Integer;
  arg3, arg4, arg5, arg6: Integer;
  loopStartPos, jzPatchPos: Integer;
  maxTemp: Integer;
  totalSlots: Integer;
  mainFnIdx: Integer;
  mainPos: Integer;
  offset: Integer;
  negOffset: Integer;
  baseOffset: Integer;
  slotCount: Integer;
  argCount: Integer;
  argTemps: array of Integer;
  stackArgsCount: Integer;
  stackCleanup: Integer;
  disp32: Integer;
  numSlots: Integer;
  // Global variable tracking
  globalVarNames: TStringList;
  globalVarOffsets: array of Integer;
  globalVarDataOffsets: array of Integer;  // Original data section offsets
  totalDataOffset: Integer;
  varIdx: Integer;
  leaPos: Integer;
  vmtDataPos: Integer;
  funcOffset: Integer;
  extLibName: string;
  // VMT generation variables
  cd: TAstClassDecl;
  method: TAstFuncDecl;
  mangledName: string;
  funcPos: Integer;
  vmtIdx: Integer;
  methodIdx: Integer;
  codePos: Integer;
  vmtLabelIdx: Integer;
  leaCodePos: Integer;
  FGlobalVarLeaPositions: array of record
    VarIndex: Integer;
    CodePos: Integer;
  end;
  // Exception globals tracking (varIdx in globalVarNames, -1 = not registered)
  excValueIdx, excDepthIdx, excJmpbufsIdx: Integer;
  // argv base global tracking (-1 = not registered)
  argvBaseIdx: Integer;
begin
  globalVarNames := TStringList.Create;
  try
  // Minimale Implementierung für grundlegende IR-Generierung
  // Strings und Globals werden später am Ende des Code-Buffers geschrieben
  // (siehe PatchGlobalData) - dies ermöglicht RIP-relative Adressierung
   
  // Initialize global variable offset tracking
  SetLength(globalVarOffsets, Length(module.GlobalVars));
  for i := 0 to High(module.GlobalVars) do
    globalVarNames.Add(module.GlobalVars[i].Name);
  totalDataOffset := 0;
  excValueIdx := -1;
  excDepthIdx := -1;
  excJmpbufsIdx := -1;
  argvBaseIdx := -1;
  
  // _start Label registrieren (Einstiegspunkt)
  SetLength(FLabelPositions, Length(FLabelPositions) + 1);
  labelIdx := High(FLabelPositions);
  FLabelPositions[labelIdx].Name := '_start';
  FLabelPositions[labelIdx].Pos := FCode.Size;
  
  // _start Stub generieren: main() aufrufen und dann exit()
  // Suche nach main Funktion
  mainFnIdx := -1;
  for i := 0 to High(module.Functions) do
  begin
    if module.Functions[i].Name = 'main' then
    begin
      mainFnIdx := i;
      Break;
    end;
  end;
  
  // _start:
  //   push rbp
  //   mov rbp, rsp
  //   call main (falls vorhanden)
  //   mov rdi, rax  (Rückgabewert von main in rdi für exit)
  //   mov rax, 60   (sys_exit)
  //   syscall
  
  // Save initial RSP (= pointer to argc/argv) to _lyx_argv_base BEFORE touching the stack
  argvBaseIdx := globalVarNames.Count;
  globalVarNames.Add('_lyx_argv_base');
  SetLength(globalVarOffsets, argvBaseIdx + 1);
  globalVarOffsets[argvBaseIdx] := 0;
  // lea r10, [rip + _lyx_argv_base]  (4D 8D 15 <disp32>)
  leaPos := FCode.Size;
  EmitU8(FCode, $4D); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
  SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := argvBaseIdx;
  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
  // mov [r10], rsp  (49 89 22)
  EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $22);

  EmitU8(FCode, $55);  // push rbp
  EmitRex(FCode, 1, 0, 0, 0);
  EmitU8(FCode, $89);
  EmitU8(FCode, $E5);  // mov rbp, rsp
  
  if mainFnIdx >= 0 then
  begin
    // call main (wird später gepatcht)
    EmitU8(FCode, $E8);  // call rel32
    SetLength(FJumpPatches, Length(FJumpPatches) + 1);
    FJumpPatches[High(FJumpPatches)].Pos := FCode.Size;
    FJumpPatches[High(FJumpPatches)].LabelName := 'main';
    FJumpPatches[High(FJumpPatches)].JmpSize := 4;
    EmitU32(FCode, 0);  // Placeholder
    
    // mov rdi, rax
    EmitRex(FCode, 1, 0, 0, 0);
    EmitU8(FCode, $89);
    EmitU8(FCode, $C7);  // mov rdi, rax
  end
  else
  begin
    // Keine main Funktion, exit(0)
    WriteMovRegImm64(FCode, RDI, 0);
  end;
  
  // mov rax, sys_exit
  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_EXIT, SYS_MACOS_EXIT)));

  // syscall
  WriteSyscall(FCode);

  // Funktionen generieren
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];
    
    // Label für Funktion registrieren
    SetLength(FLabelPositions, Length(FLabelPositions) + 1);
    labelIdx := High(FLabelPositions);
    FLabelPositions[labelIdx].Name := fn.Name;
    FLabelPositions[labelIdx].Pos := FCode.Size;
    
    // Prolog
    EmitU8(FCode, $55);  // push rbp
    EmitRex(FCode, 1, 0, 0, 0);
    EmitU8(FCode, $89);
    EmitU8(FCode, $E5);  // mov rbp, rsp
    
    // Calculate max temp index
    maxTemp := -1;
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      if instr.Dest > maxTemp then maxTemp := instr.Dest;
      if instr.Src1 > maxTemp then maxTemp := instr.Src1;
      if instr.Src2 > maxTemp then maxTemp := instr.Src2;
      if instr.Src3 > maxTemp then maxTemp := instr.Src3;
    end;
    if maxTemp < 0 then maxTemp := 0;
    
    // Calculate total slots (locals + temporaries)
    // maxTemp is the highest temp index used, so we need maxTemp + 1 slots for temps
    totalSlots := fn.LocalCount + maxTemp + 1;
    
    // For large struct returns, add one extra slot for the sret pointer
    // The sret slot will be at index 'totalSlots' (before incrementing)
    if fn.ReturnStructSize > 16 then
      Inc(totalSlots);
    
    // Stack-Frame für lokale Variablen und Temporaries
    if totalSlots > 0 then
    begin
      // sub rsp, n*8
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $81);
      EmitU8(FCode, $EC);
      EmitU32(FCode, Cardinal(totalSlots * 8));
    end;
    
    // Spill incoming parameters into local slots (SysV ABI: RDI, RSI, RDX, RCX, R8, R9)
    // For large struct returns (>16 bytes), RDI contains the sret pointer
    // We store it in the last slot (totalSlots - 1 after incrementing)
    if fn.ReturnStructSize > 16 then
    begin
      // Large struct return: sret pointer comes in RDI
      // Store it in the last slot (totalSlots - 1)
      WriteMovMemReg(FCode, RBP, SlotOffset(totalSlots - 1), RDI);
      
      // Actual parameters come in RSI, RDX, RCX, R8, R9 (shifted by 1)
      // They still go into their normal slots 0, 1, 2, ...
      for k := 0 to fn.ParamCount - 1 do
      begin
        slotIdx := k;
        if k < 5 then
          // Parameter came in register (shifted: RSI=param0, RDX=param1, etc.)
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), ParamRegs[k + 1])
        else
        begin
          // Parameter was passed on stack (shifted by 1 position)
          disp32 := 16 + (k - 5) * 8;
          WriteMovRegMem(FCode, RAX, RBP, Integer(disp32));
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
        end;
      end;
    end
    else if fn.ParamCount > 0 then
    begin
      // Normal function (no sret or small struct return)
      for k := 0 to fn.ParamCount - 1 do
      begin
        // Parameters go into slots 0, 1, 2, ... (first fn.ParamCount slots)
        slotIdx := k;
        if k < 6 then
          // Parameter came in register, store to local slot
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), ParamRegs[k])
        else
        begin
          // Parameter was passed on stack (above return address and saved rbp)
          // Stack layout at entry: [ret addr][caller rbp]...[arg6][arg7]...
          // After push rbp; mov rbp,rsp: rbp points to saved rbp
          // So arg6 is at [rbp+16], arg7 at [rbp+24], etc.
          disp32 := 16 + (k - 6) * 8;
          WriteMovRegMem(FCode, RAX, RBP, Integer(disp32));
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
        end;
      end;
    end;
    
    // IR-Instruktionen verarbeiten
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      
      case instr.Op of
        irReturn:
        begin
          // Rückgabewert in RAX laden (falls vorhanden)
          // Src1 ist ein Temp-Index, daher fn.LocalCount addieren
          if instr.Src1 >= 0 then
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
          
          // Epilog
          EmitRex(FCode, 1, 0, 0, 0);
          EmitU8(FCode, $89);
          EmitU8(FCode, $EC);  // mov rsp, rbp
          EmitU8(FCode, $5D);  // pop rbp
          WriteRet(FCode);
        end;
        
        irReturnStruct:
        begin
          // Struct-Rückgabe - Src1 ist ein lokaler Slot-Index (nicht Temp!)
          // SysV ABI: 
          //   - Structs ≤16 Bytes: in RAX:RDX zurückgegeben
          //   - Structs >16 Bytes: versteckter Pointer in RDI, Daten werden dorthin kopiert
          if instr.Src1 >= 0 then
          begin
            numSlots := (instr.StructSize + 7) div 8;
            
            if instr.StructSize <= 16 then
            begin
              // Kleine Structs: RAX:RDX verwenden
              // SysV ABI: Bytes 0-7 → RAX, Bytes 8-15 → RDX
              // Slot-Layout: SlotOffset(Src1+1) = niedrigere Adresse = Bytes 0-7
              //              SlotOffset(Src1)   = höhere  Adresse = Bytes 8-15
              if instr.StructSize > 8 then
              begin
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1 + 1)); // Bytes 0-7 → RAX
                WriteMovRegMem(FCode, RDX, RBP, SlotOffset(instr.Src1));     // Bytes 8-15 → RDX
              end
              else
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1));
            end
            else
            begin
              // Große Structs: Versteckter sret-Pointer im letzten Slot
              // Der Caller hat die Zieladresse in RDI übergeben und wir haben sie im sret-Slot gespeichert
              // Der sret-Slot ist bei totalSlots - 1 (bevor wir für sret erhöht haben)
              // Das entspricht fn.LocalCount + maxTemp + 1
              // Da wir maxTemp beim Prolog berechnet haben, verwenden wir hier dieselbe Formel
              // Hinweis: totalSlots wurde bereits für sret erhöht, also ist der Slot bei totalSlots - 1
              
              // Lade sret-Pointer aus dem sret-Slot nach R11 (scratch register)
              WriteMovRegMem(FCode, R11, RBP, SlotOffset(totalSlots - 1));
              
              // Kopiere alle Slots
              // WICHTIG: In Lyx wachsen Struct-Slots nach UNTEN (niedrigere Adressen für höhere Slot-Indices)
              // Der sret-Pointer zeigt auf den ersten Slot (höchste Adresse im Struct)
              // Wir müssen mit NEGATIVEN Offsets schreiben: [r11-0], [r11-8], [r11-16], ...
              for k := 0 to numSlots - 1 do
              begin
                // Lade Quell-Slot in RAX
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1 + k));
                // Speichere nach [R11 - k*8] (negative Offsets!)
                // mov [r11 + disp], rax (wobei disp negativ ist)
                EmitU8(FCode, $49); // REX.WB
                EmitU8(FCode, $89); // MOV r/m64, r64
                if k = 0 then
                begin
                  EmitU8(FCode, $03); // ModR/M: [r11], rax
                end
                else if k * 8 <= 128 then
                begin
                  EmitU8(FCode, $43); // ModR/M: [r11 + disp8], rax
                  EmitU8(FCode, Byte(-k * 8));  // Negativer Offset als signed byte
                end
                else
                begin
                  EmitU8(FCode, $83); // ModR/M: [r11 + disp32], rax
                  EmitU32(FCode, Cardinal(-k * 8));  // Negativer Offset als signed dword
                end;
              end;
              
              // Gib den sret-Pointer in RAX zurück (ABI requirement)
              WriteMovRegReg(FCode, RAX, R11);
            end;
          end;
          
          // Epilog
          EmitRex(FCode, 1, 0, 0, 0);
          EmitU8(FCode, $89);
          EmitU8(FCode, $EC);  // mov rsp, rbp
          EmitU8(FCode, $5D);  // pop rbp
          WriteRet(FCode);
        end;
        
        irLoadLocal:
        begin
          // Load local variable into temp: dest = locals[src1]
          slotIdx := instr.Src1;
          WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
          slotIdx := fn.LocalCount + instr.Dest;
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
        end;

        irLoadCaptured:
        begin
          // Load captured variable from parent frame via static link
          // Src1 = slot containing static link (parent RBP)
          // ImmInt = outerSlot in parent function
          WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1));       // RAX = parent RBP
          WriteMovRegMem(FCode, RCX, RAX, SlotOffset(instr.ImmInt));     // RCX = [parent_RBP + SlotOffset(outerSlot)]
          slotIdx := fn.LocalCount + instr.Dest;
          WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RCX);
        end;

        irStoreLocal:
        begin
             // Store temp into local variable: locals[dest] = src1
             // Src1 is a temp index (needs fn.LocalCount added)
             // Dest is a local slot index (0..LocalCount-1)
             slotIdx := fn.LocalCount + instr.Src1;  // Temp slot
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
             WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);  // Local slot (no offset)
           end;

         irLoadGlobal:
           begin
             // Load global variable into temp: dest = globals[ImmStr]
             // Globals are pre-allocated in data section during EmitFromIR
             varIdx := globalVarNames.IndexOf(instr.ImmStr);
             if varIdx < 0 then
             begin
               // First use of this global - register it
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
             slotIdx := fn.LocalCount + instr.Dest;
             WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
           end;
           
         irStoreGlobal:
           begin
             // Store temp into global variable: globals[ImmStr] = src1
             // Load value from temp
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
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
                  // VMT label not found - this shouldn't happen, but create placeholder in CODE
                  vmtDataPos := FCode.Size;
                  FCode.WriteU64LE(0);
                end;
                
                // lea rax, [rip+disp32] ; loads VMT address directly from code segment
                leaPos := FCode.Size;
                EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
                // Record position for patching - store VMT label index
                SetLength(FVMTAddrLeaPositions, Length(FVMTAddrLeaPositions) + 1);
                // Find the index in FVMTLabels
                for k := 0 to High(FVMTLabels) do
                begin
                  if FVMTLabels[k].Name = instr.ImmStr then
                  begin
                    FVMTAddrLeaPositions[High(FVMTAddrLeaPositions)].VMTLabelIndex := k;
                    Break;
                  end;
                end;
                FVMTAddrLeaPositions[High(FVMTAddrLeaPositions)].CodePos := leaPos;
                // Store the ADDRESS into temp slot
                slotIdx := fn.LocalCount + instr.Dest;
                WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
               end
              else
              begin
                // Check if ImmStr is a function name (for function pointer initialization)
                funcOffset := GetFunctionOffset(instr.ImmStr);
                if funcOffset >= 0 then
                begin
                  // Function found - load its address using PC-relative LEA
                  // lea rax, [rip+disp32] - the offset will be patched later
                  leaPos := FCode.Size;
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
                  // Record position for patching with special flag (negative index = function)
                  SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := -funcOffset - 1;  // negative = function
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
                  // Store the function address into temp slot
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end
                else
                begin
                  // Regular global variable - find index in module.GlobalVars
                  varIdx := -1;
                  for k := 0 to High(module.GlobalVars) do
                  begin
                    if module.GlobalVars[k].Name = instr.ImmStr then
                    begin
                      varIdx := k;
                      Break;
                    end;
                  end;
                  if varIdx < 0 then
                  begin
                    // Global variable not found in module - this shouldn't happen
                    // Create placeholder
                    varIdx := Length(module.GlobalVars);
                  end;
                  // lea rax, [rip+disp32] ; will be patched later - loads ADDRESS directly
                  leaPos := FCode.Size;
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
                  // Record position for patching
                  SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := varIdx;
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
                  // Store the ADDRESS into temp slot
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end;
              end;
             end;

          irLoadLocalAddr:
            begin
              // Load address of local slot into temp: dest = &locals[Src1]
              // Src1 is a local slot index (0..LocalCount-1)
              // Dest is a temp index (needs fn.LocalCount added)
              slotIdx := instr.Src1;
              // lea rax, [rbp + SlotOffset(slotIdx)]
              if (SlotOffset(slotIdx) >= -128) and (SlotOffset(slotIdx) <= 127) then
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $45); 
                EmitU8(FCode, Byte(SlotOffset(slotIdx)));
              end
              else
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $85);
                EmitU32(FCode, Cardinal(SlotOffset(slotIdx)));
              end;
              // Store address into temp slot
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;

          irLoadStructAddr:
            begin
              // Load address of struct local (multiple slots) into temp: dest = &locals[Src1]
              // Src1 is a local slot index (0..LocalCount-1)
              // StructSize gives the total size in bytes
              //
              // Stack layout for a struct with N slots (e.g., 2 slots for 14-byte struct):
              //   Slot 0 at rbp - 8   (highest address)
              //   Slot 1 at rbp - 16  (lowest address)
              // Field byte 0 should be at the LOWEST address, so we need to calculate
              // the base as the lowest slot address.
              //
              // For positive field offsets to work: base = SlotOffset(slotIdx + slotCount - 1)
              slotIdx := instr.Src1;
              slotCount := (instr.StructSize + 7) div 8; // round up to slot count
              if slotCount < 1 then slotCount := 1;
              // Calculate base address (lowest address = last slot)
              baseOffset := SlotOffset(slotIdx + slotCount - 1);
              // lea rax, [rbp + baseOffset]
              if (baseOffset >= -128) and (baseOffset <= 127) then
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $45); 
                EmitU8(FCode, Byte(baseOffset));
              end
              else
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $85);
                EmitU32(FCode, Cardinal(baseOffset));
              end;
              // Store address into temp slot
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;

          irConstInt:
            begin
               // Load immediate integer into temp slot
               slotIdx := fn.LocalCount + instr.Dest;
                WriteMovRegImm64(FCode, RAX, UInt64(instr.ImmInt));
                WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
              end;

          irConstFloat:
            begin
              // Float-Konstante als Bit-Pattern in den Slot schreiben
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovRegImm64(FCode, RAX, PUInt64(@instr.ImmFloat)^);
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;

          // === SSE2 Float-Arithmetik ===
          irFAdd:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              WriteAddsd(FCode, XMM0, XMM1);
              WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
            end;
          irFSub:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              WriteSubsd(FCode, XMM0, XMM1);
              WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
            end;
          irFMul:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              WriteMulsd(FCode, XMM0, XMM1);
              WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
            end;
          irFDiv:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              WriteDivsd(FCode, XMM0, XMM1);
              WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
            end;
          irFNeg:
            begin
              // FNeg: Toggle Sign-Bit (Bit 63)
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $BA);
              EmitU8(FCode, $F8); EmitU8(FCode, 63); // btc rax, 63
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;

          // === SSE2 Float-Vergleiche ===
          irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovsdLoad(FCode, XMM1, RBP, SlotOffset(fn.LocalCount + instr.Src2));
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

          // === Float <-> Integer Konvertierung ===
          irFToI:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteCvttsd2si(FCode, RAX, XMM0);
              WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
            end;
          irIToF:
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteCvtsi2sd(FCode, XMM0, RAX);
              WriteMovsdStore(FCode, RBP, SlotOffset(slotIdx), XMM0);
            end;

           irSExt:
            begin
              // Sign-extend src1 (width in ImmInt) into dest
              // Load source value and sign-extend to 64 bits
              slotIdx := fn.LocalCount + instr.Src1;
              case instr.ImmInt of
                8: WriteMovSxRegMem8(FCode, RAX, RBP, SlotOffset(slotIdx));
                16: WriteMovSxRegMem16(FCode, RAX, RBP, SlotOffset(slotIdx));
                32: WriteMovSxRegMem32(FCode, RAX, RBP, SlotOffset(slotIdx));
              else
                // Already 64-bit or unknown width, just copy
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
              end;
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;

           irZExt:
            begin
              // Zero-extend src1 (width in ImmInt) into dest
              slotIdx := fn.LocalCount + instr.Src1;
              case instr.ImmInt of
                8: WriteMovzxRegMem8(FCode, RAX, RBP, SlotOffset(slotIdx));
                16: WriteMovzxRegMem16(FCode, RAX, RBP, SlotOffset(slotIdx));
                32:
                  begin
                    // mov eax, dword ptr [base+disp] zero-extends into rax implicitly
                    WriteMovEAXMem32(FCode, RBP, SlotOffset(slotIdx));
                  end;
              else
                // Already 64-bit or unknown width, just copy
                WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
              end;
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;

          irTrunc:
            begin
              // Truncate src1 to ImmInt bits
              // This is done by loading mask into RCX, then ANDing
              slotIdx := fn.LocalCount + instr.Src1;
              // Load source value into RAX
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
              // Load mask into RCX based on bit width
              case instr.ImmInt of
                8:  WriteMovRegImm64(FCode, RCX, $FF);
                16: WriteMovRegImm64(FCode, RCX, $FFFF);
                32: WriteMovRegImm64(FCode, RCX, $FFFFFFFF);
              else
                WriteMovRegImm64(FCode, RCX, $FFFFFFFFFFFFFFFF);
              end;
              // AND RAX, RCX
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $21);
              EmitU8(FCode, $C8);  // and rax, rcx
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
             
           irAlloc:
            begin
              // Heap allocation: Dest = alloc(ImmInt bytes)
              // Use mmap syscall: mmap(addr=0, len=ImmInt, prot=RW, flags=MAP_ANONYMOUS|MAP_PRIVATE, fd=-1, offset=0)
              // RDI = addr = 0 (NULL)
              // RSI = length = ImmInt
              // RDX = prot = PROT_READ | PROT_WRITE = 3
              // R10 = flags = MAP_ANONYMOUS | MAP_PRIVATE = 0x22
              // R8 = fd = -1
              // R9 = offset = 0
              
              // RDI = 0 (NULL)
              WriteMovRegImm64(FCode, RDI, 0);
              
              // RSI = length from ImmInt
              WriteMovRegImm64(FCode, RSI, UInt64(instr.ImmInt));
              
              // RDX = PROT_READ | PROT_WRITE = 3
              WriteMovRegImm64(FCode, RDX, 3);
              
              // R10 = MAP_ANONYMOUS | MAP_PRIVATE = 0x22
              WriteMovRegImm64(FCode, R10, $22);
              
              // R8 = fd = -1
              WriteMovRegImm64(FCode, R8, UInt64(-1));
              
              // R9 = offset = 0
              WriteMovRegImm64(FCode, R9, 0);
              
              // RAX = sys_mmap
              WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));

              // syscall
              WriteSyscall(FCode);

              // Store result (pointer) to Dest temp slot
              if instr.Dest >= 0 then
              begin
                slotIdx := fn.LocalCount + instr.Dest;
                WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
              end;
            end;
            
          irFree:
            begin
              // Heap deallocation: free(Src1 pointer)
              // Use munmap syscall: munmap(addr, length)
              // Since we don't track allocation size, we'll use a conservative approach:
              // Linux ignores munmap of wrong size, but for safety we use a default page size
              // Actually, for simplicity we just munmap with a reasonable size (4KB pages)
              
              // Get pointer from Src1
              if instr.Src1 >= 0 then
              begin
                slotIdx := fn.LocalCount + instr.Src1;
                WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
              end
              else
                WriteMovRegImm64(FCode, RDI, 0);
              
              // RSI = length (use ImmInt if provided, else default 4096)
              if instr.ImmInt > 0 then
                WriteMovRegImm64(FCode, RSI, UInt64(instr.ImmInt))
              else
                WriteMovRegImm64(FCode, RSI, 4096);  // Default page size
              
              // RAX = sys_munmap
              WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));

              // syscall
              WriteSyscall(FCode);
            end;

           irConstStr:
            begin
               // Load string address into temp slot
               // ImmStr contains the string index as string
               slotIdx := fn.LocalCount + instr.Dest;
               arg3 := StrToIntDef(instr.ImmStr, -1);
               if (arg3 >= 0) then
               begin
                 // Save position for later patching (FStringOffsets filled in PatchGlobalData)
                 SetLength(FLeaPositions, Length(FLeaPositions) + 1);
                 SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
                 FLeaPositions[High(FLeaPositions)] := FCode.Size + 3;  // Position of disp32
                 FLeaStrIndex[High(FLeaStrIndex)] := arg3;
                 
                 // lea rax, [rip + displacement] - placeholder
                 // Format: REX.W(48) 8D 05 [disp32]
                 EmitRex(FCode, 1, 0, 0, 0);  // REX.W prefix
                 EmitU8(FCode, $8D);          // LEA opcode
                 EmitU8(FCode, $05);          // ModR/M: rax, [rip + disp32]
                 EmitU32(FCode, 0);           // placeholder for displacement (will be patched)
                 
                 WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
               end;
            end;
           
         irAdd:
           begin
             // dest = src1 + src2
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // add rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $01);
             EmitU8(FCode, $C8);  // add rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irSub:
           begin
             // dest = src1 - src2
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // sub rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $29);
             EmitU8(FCode, $C8);  // sub rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irMul:
           begin
             // dest = src1 * src2 (signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // imul rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $AF);
             EmitU8(FCode, $C1);  // imul rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irDiv:
           begin
             // dest = src1 / src2 (signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cqo (sign-extend rax to rdx:rax)
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $99);  // cqo
             // idiv rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $F7);
             EmitU8(FCode, $F9);  // idiv rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irMod:
           begin
             // dest = src1 % src2 (signed, result in RDX after idiv)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cqo
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $99);
             // idiv rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $F7);
             EmitU8(FCode, $F9);
             // Store RDX (remainder) instead of RAX
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RDX);
           end;
           
         irNeg:
           begin
             // dest = -src1
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             // neg rax
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $F7);
             EmitU8(FCode, $D8);  // neg rax
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;

          // === Logische / Bool-Operationen ===
          irNot:
            begin
              // dest = !src1 (boolean not)
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              // test rax, rax
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $85); EmitU8(FCode, $C0);
              // sete al
              EmitU8(FCode, $0F); EmitU8(FCode, $94); EmitU8(FCode, $C0);
              // movzx rax, al
              EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
          irAnd:
            begin
              // dest = src1 & src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // and rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $21); EmitU8(FCode, $C8);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
          irOr:
            begin
              // dest = src1 | src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // or rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $09); EmitU8(FCode, $C8);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
          irNor:
            begin
              // dest = !(src1 | src2)
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // or rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $09); EmitU8(FCode, $C8);
              // test rax, rax
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $85); EmitU8(FCode, $C0);
              // sete al
              EmitU8(FCode, $0F); EmitU8(FCode, $94); EmitU8(FCode, $C0);
              // movzx rax, al
              EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $C0);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
          irXor:
            begin
              // dest = src1 ^ src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovMemReg(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // xor rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $31); EmitU8(FCode, $C8);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;

          irBitAnd:
           begin
             // dest = src1 & src2 (bitwise AND)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // and rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $21);
             EmitU8(FCode, $C8);  // and rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irBitOr:
           begin
             // dest = src1 | src2 (bitwise OR)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // or rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $09);
             EmitU8(FCode, $C8);  // or rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irBitXor:
           begin
             // dest = src1 ^ src2 (bitwise XOR)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // xor rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $31);
             EmitU8(FCode, $C8);  // xor rax, rcx
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irBitNot:
           begin
             // dest = ~src1 (bitwise NOT)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             // not rax
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $F7);
             EmitU8(FCode, $D0);  // not rax
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irShl:
           begin
             // dest = src1 << src2 (left shift)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             if instr.Src2 >= 0 then
             begin
               // Shift amount in register
               WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
               // shl rax, cl (shift amount in CL register)
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $D3);
               EmitU8(FCode, $E0);  // shl rax, cl
             end
             else
             begin
               // Shift amount is immediate in ImmInt (from strength reduction)
               // shl rax, imm8
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $C1);
               EmitU8(FCode, $E0);  // shl rax, imm8
               EmitU8(FCode, instr.ImmInt and $FF);
             end;
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irShr:
           begin
             // dest = src1 >> src2 (arithmetic right shift for signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             if instr.Src2 >= 0 then
             begin
               // Shift amount in register
               WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
               // sar rax, cl (arithmetic shift right, preserves sign)
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $D3);
               EmitU8(FCode, $F8);  // sar rax, cl
             end
             else
             begin
               // Shift amount is immediate in ImmInt
               // sar rax, imm8
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $C1);
               EmitU8(FCode, $F8);  // sar rax, imm8
               EmitU8(FCode, instr.ImmInt and $FF);
             end;
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;

         irCallBuiltin:
           begin
              // Builtin-Calls behandeln
              if instr.ImmStr = 'exit' then
              begin
                // Exit-Syscall: Argument ist in Src1 (temp index)
                slotIdx := fn.LocalCount + instr.Src1;
                WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_EXIT, SYS_MACOS_EXIT)));
                WriteSyscall(FCode);
              end
              else if (instr.ImmStr = 'PrintStr') or (instr.ImmStr = 'Println') then
              begin
                // PrintStr(s: pchar) -> void
                // sys_write(fd=1, buf, count)
                // First, we need to calculate string length
                // Get string pointer from Src1 or ArgTemps[0]
                arg3 := -1;
                if Length(instr.ArgTemps) > 0 then
                  arg3 := instr.ArgTemps[0]
                else
                  arg3 := instr.Src1;
                  
                if arg3 >= 0 then
                begin
                  slotIdx := fn.LocalCount + arg3;
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // RSI = buf
                  
                  // Calculate string length: scan for null terminator
                  // mov rdi, rsi (copy for scanning)
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $89);
                  EmitU8(FCode, $F7);  // mov rdi, rsi
                  
                  // strlen loop:
                  // .Lstrlen_start:
                  //   cmp byte [rdi], 0
                  //   je .Lstrlen_end
                  //   inc rdi
                  //   jmp .Lstrlen_start
                  // .Lstrlen_end:
                  //   sub rdi, rsi  ; rdi = length
                  
                  // Save current position for loop label
                  // cmp byte [rdi], 0
                  EmitU8(FCode, $80);
                  EmitU8(FCode, $3F);
                  EmitU8(FCode, $00);  // cmp byte [rdi], 0
                  // je +4 (skip inc + jmp)
                  EmitU8(FCode, $74);
                  EmitU8(FCode, $05);  // je +5
                  // inc rdi
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $FF);
                  EmitU8(FCode, $C7);  // inc rdi
                  // jmp -8 (back to cmp)
                  EmitU8(FCode, $EB);
                  EmitU8(FCode, $F6);  // jmp -10
                  
                  // sub rdi, rsi  -> rdi = length
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $29);
                  EmitU8(FCode, $F7);  // sub rdi, rsi
                  
                  // mov rdx, rdi (length)
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $89);
                  EmitU8(FCode, $FA);  // mov rdx, rdi
                  
                  // Reload RSI (buf pointer)
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // RSI = buf
                  
                  // RDI = 1 (stdout)
                  WriteMovRegImm64(FCode, RDI, 1);

                  // RAX = sys_write
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));

                  // syscall
                  WriteSyscall(FCode);
                end;
              end
              else if instr.ImmStr = 'PrintInt' then
              begin
                // PrintInt(x: int64) -> void
                // Convert integer to string and print
                // Get the value from Src1 or ArgTemps[0]
                arg3 := -1;
                if Length(instr.ArgTemps) > 0 then
                  arg3 := instr.ArgTemps[0]
                else
                  arg3 := instr.Src1;
                  
                if arg3 >= 0 then
                begin
                  slotIdx := fn.LocalCount + arg3;
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));  // RAX = value
                  
                  // We need a buffer on stack for the number string (max 20 chars + sign)
                  // sub rsp, 24 (aligned)
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $83);
                  EmitU8(FCode, $EC);
                  EmitU8(FCode, 24);  // sub rsp, 24
                  
                  // Point RDI to end of buffer (we build string backwards)
                  // lea rdi, [rsp+20]
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $8D);
                  EmitU8(FCode, $7C);
                  EmitU8(FCode, $24);
                  EmitU8(FCode, 20);  // lea rdi, [rsp+20]
                  
                  // Store null terminator
                  // mov byte [rdi], 0
                  EmitU8(FCode, $C6);
                  EmitU8(FCode, $07);
                  EmitU8(FCode, $00);  // mov byte [rdi], 0
                  
                  // Save if negative in R8
                  // xor r8d, r8d
                  EmitU8(FCode, $45);
                  EmitU8(FCode, $31);
                  EmitU8(FCode, $C0);  // xor r8d, r8d
                  
                  // test rax, rax
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $85);
                  EmitU8(FCode, $C0);  // test rax, rax
                  
                  // jns .Lpositive (skip negation)
                  // neg rax = 3 bytes, mov r8d,1 = 6 bytes = 9 bytes total
                  EmitU8(FCode, $79);
                  EmitU8(FCode, $09);  // jns +9
                  
                  // neg rax
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $F7);
                  EmitU8(FCode, $D8);  // neg rax
                  
                  // mov r8d, 1
                  EmitU8(FCode, $41);
                  EmitU8(FCode, $B8);
                  EmitU32(FCode, 1);  // mov r8d, 1
                  
                  // .Lpositive:
                  // mov rcx, 10
                  WriteMovRegImm64(FCode, RCX, 10);
                  
                  // .Lloop:
                  // dec rdi
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $FF);
                  EmitU8(FCode, $CF);  // dec rdi
                  
                  // xor rdx, rdx
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $31);
                  EmitU8(FCode, $D2);  // xor rdx, rdx
                  
                  // div rcx (rax = rax / 10, rdx = rax % 10)
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $F7);
                  EmitU8(FCode, $F1);  // div rcx
                  
                  // add dl, '0'
                  EmitU8(FCode, $80);
                  EmitU8(FCode, $C2);
                  EmitU8(FCode, $30);  // add dl, '0'
                  
                  // mov [rdi], dl
                  EmitU8(FCode, $88);
                  EmitU8(FCode, $17);  // mov [rdi], dl
                  
                  // test rax, rax
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $85);
                  EmitU8(FCode, $C0);  // test rax, rax
                  
                  // jnz .Lloop (back 17 bytes)
                  EmitU8(FCode, $75);
                  EmitU8(FCode, $ED);  // jnz -19
                  
                  // Check if we need to add minus sign
                  // test r8d, r8d
                  EmitU8(FCode, $45);
                  EmitU8(FCode, $85);
                  EmitU8(FCode, $C0);  // test r8d, r8d
                  
                  // jz .Lprint (skip minus)
                  EmitU8(FCode, $74);
                  EmitU8(FCode, $06);  // jz +6
                  
                  // dec rdi
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $FF);
                  EmitU8(FCode, $CF);  // dec rdi
                  
                  // mov byte [rdi], '-'
                  EmitU8(FCode, $C6);
                  EmitU8(FCode, $07);
                  EmitU8(FCode, $2D);  // mov byte [rdi], '-'
                  
                  // .Lprint:
                  // RSI = RDI (string start)
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $89);
                  EmitU8(FCode, $FE);  // mov rsi, rdi
                  
                  // Calculate length: lea rdx, [rsp+20] ; sub rdx, rdi
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $8D);
                  EmitU8(FCode, $54);
                  EmitU8(FCode, $24);
                  EmitU8(FCode, 20);  // lea rdx, [rsp+20]
                  
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $29);
                  EmitU8(FCode, $FA);  // sub rdx, rdi
                  
                  // RDI = 1 (stdout)
                  WriteMovRegImm64(FCode, RDI, 1);

                  // RAX = sys_write
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));

                  // syscall
                  WriteSyscall(FCode);

                  // Restore stack
                  // add rsp, 24
                  EmitRex(FCode, 1, 0, 0, 0);
                  EmitU8(FCode, $83);
                  EmitU8(FCode, $C4);
                  EmitU8(FCode, 24);  // add rsp, 24
                end;
              end
              else if instr.ImmStr = 'ioctl' then
             begin
               // ioctl(fd, request, argp)
               // Syscall: ioctl(fd, request, argp) = sys_ioctl (16)
               // RDI = fd, RSI = request, RDX = argp
               if instr.Src1 >= 0 then
               begin
                 slotIdx := fn.LocalCount + instr.Src1;
                 WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RDI, 0);
               if instr.Src2 >= 0 then
               begin
                 slotIdx := fn.LocalCount + instr.Src2;
                 WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RSI, 0);
               // 3rd arg from ArgTemps[2]
               arg3 := -1;
               if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
                 arg3 := instr.ArgTemps[2];
               if arg3 >= 0 then
               begin
                 slotIdx := fn.LocalCount + arg3;
                 WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RDX, 0);
               WriteMovRegImm64(FCode, RAX, UInt64(SysNum(16, SYS_MACOS_IOCTL))); // sys_ioctl
               WriteSyscall(FCode);
               if instr.Dest >= 0 then
               begin
                 slotIdx := fn.LocalCount + instr.Dest;
                 WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
               end;
             end
             else if instr.ImmStr = 'mmap' then
             begin
               // mmap(addr, length, prot, flags, fd, offset)
               // RDI=addr, RSI=length, RDX=prot, R10=flags, R8=fd, R9=offset
               // All args from ArgTemps[0..5] (Src1 also = ArgTemps[0])
               if Length(instr.ArgTemps) >= 1 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[0];
                 WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RDI, 0);
               if Length(instr.ArgTemps) >= 2 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[1];
                 WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RSI, 0);
               if Length(instr.ArgTemps) >= 3 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[2];
                 WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, RDX, 0);
               if Length(instr.ArgTemps) >= 4 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[3];
                 WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R10, 0);
               if Length(instr.ArgTemps) >= 5 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[4];
                 WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R8, -1);
               if Length(instr.ArgTemps) >= 6 then
               begin
                 slotIdx := fn.LocalCount + instr.ArgTemps[5];
                 WriteMovRegMem(FCode, R9, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R9, 0);
               WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP))); // sys_mmap
               WriteSyscall(FCode);
               if instr.Dest >= 0 then
               begin
                 slotIdx := fn.LocalCount + instr.Dest;
                 WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
               end;
              end
               else if instr.ImmStr = 'munmap' then
               begin
                 // munmap(addr, length)
                 // RDI = addr, RSI = length
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src2 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src2;
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP))); // sys_munmap
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_socket' then
               begin
                 // sys_socket(domain: int64, type: int64, protocol: int64) -> int64
                 // RDI = domain, RSI = type, RDX = protocol
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_SOCKET, SYS_MACOS_SOCKET)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_bind' then
               begin
                 // sys_bind(sockfd, addr, addrlen) -> int64
                 // RDI = sockfd, RSI = addr, RDX = addrlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_BIND, SYS_MACOS_BIND)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_listen' then
               begin
                 // sys_listen(sockfd, backlog) -> int64
                 // RDI = sockfd, RSI = backlog
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_LISTEN, SYS_MACOS_LISTEN)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_accept' then
               begin
                 // sys_accept(sockfd, addr, addrlen) -> int64
                 // RDI = sockfd, RSI = addr, RDX = addrlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_ACCEPT, SYS_MACOS_ACCEPT)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_connect' then
               begin
                 // sys_connect(sockfd, addr, addrlen) -> int64
                 // RDI = sockfd, RSI = addr, RDX = addrlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else if instr.Src1 >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Src1;
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_CONNECT, SYS_MACOS_CONNECT)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_recvfrom' then
               begin
                 // sys_recvfrom(sockfd, buf, len, flags, src_addr, addrlen) -> int64
                 // RDI=sockfd, RSI=buf, RDX=len, R10=flags, R8=src_addr, R9=addrlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 if Length(instr.ArgTemps) >= 4 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[3];
                   WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R10, 0);
                   
                 if Length(instr.ArgTemps) >= 5 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[4];
                   WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R8, 0);
                   
                 if Length(instr.ArgTemps) >= 6 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[5];
                   WriteMovRegMem(FCode, R9, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R9, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_RECVFROM, SYS_MACOS_RECVFROM)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_sendto' then
               begin
                 // sys_sendto(sockfd, buf, len, flags, dest_addr, addrlen) -> int64
                 // RDI=sockfd, RSI=buf, RDX=len, R10=flags, R8=dest_addr, R9=addrlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 if Length(instr.ArgTemps) >= 4 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[3];
                   WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R10, 0);
                   
                 if Length(instr.ArgTemps) >= 5 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[4];
                   WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R8, 0);
                   
                 if Length(instr.ArgTemps) >= 6 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[5];
                   WriteMovRegMem(FCode, R9, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R9, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_SENDTO, SYS_MACOS_SENDTO)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_setsockopt' then
               begin
                 // sys_setsockopt(sockfd, level, optname, optval, optlen) -> int64
                 // RDI=sockfd, RSI=level, RDX=optname, R10=optval, R8=optlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 if Length(instr.ArgTemps) >= 4 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[3];
                   WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R10, 0);
                   
                 if Length(instr.ArgTemps) >= 5 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[4];
                   WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R8, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_SETSOCKOPT, SYS_MACOS_SETSOCKOPT)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_getsockopt' then
               begin
                 // sys_getsockopt(sockfd, level, optname, optval, optlen) -> int64
                 // RDI=sockfd, RSI=level, RDX=optname, R10=optval, R8=optlen
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 if Length(instr.ArgTemps) >= 4 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[3];
                   WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R10, 0);
                   
                 if Length(instr.ArgTemps) >= 5 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[4];
                   WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, R8, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_GETSOCKOPT, SYS_MACOS_GETSOCKOPT)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_fcntl' then
               begin
                 // sys_fcntl(fd, cmd, arg) -> int64
                 // RDI = fd, RSI = cmd, RDX = arg
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 if Length(instr.ArgTemps) >= 3 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[2];
                   WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDX, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_FCNTL, SYS_MACOS_FCNTL)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
               end
               else if instr.ImmStr = 'sys_shutdown' then
               begin
                 // sys_shutdown(sockfd, how) -> int64
                 // RDI = sockfd, RSI = how
                 if Length(instr.ArgTemps) >= 1 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[0];
                   WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RDI, 0);
                   
                 if Length(instr.ArgTemps) >= 2 then
                 begin
                   slotIdx := fn.LocalCount + instr.ArgTemps[1];
                   WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, RSI, 0);
                   
                 WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_SHUTDOWN, SYS_MACOS_SHUTDOWN)));
                 WriteSyscall(FCode);
                 if instr.Dest >= 0 then
                 begin
                   slotIdx := fn.LocalCount + instr.Dest;
                   WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                 end;
                end
                else if instr.ImmStr = 'mmap' then
                begin
                  // mmap(addr, length, prot, flags, fd, offset) -> int64 (pointer)
                  // syscall: RAX=9, RDI=addr, RSI=length, RDX=prot, R10=flags, R8=fd, R9=offset
                  
                  // arg0: addr
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // arg1: length
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RSI, 0);
                  
                  // arg2: prot
                  if Length(instr.ArgTemps) >= 3 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[2];
                    WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDX, 0);
                  
                  // arg3: flags (goes to R10 for syscall)
                  if Length(instr.ArgTemps) >= 4 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[3];
                    WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, R10, 0);
                  
                  // arg4: fd
                  if Length(instr.ArgTemps) >= 5 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[4];
                    WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, R8, -1);
                  
                  // arg5: offset
                  if Length(instr.ArgTemps) >= 6 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[5];
                    WriteMovRegMem(FCode, R9, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, R9, 0);
                  
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'munmap' then
                begin
                  // munmap(addr, length) -> int64
                  // syscall: RAX=11, RDI=addr, RSI=length
                  
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RSI, 0);
                  
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
                  WriteSyscall(FCode);
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'poke8' then
                begin
                  // poke8(addr, value) - write byte to memory
                  // mov al, value; mov [addr], al
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // Get value into RAX
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RAX, 0);
                  
                  // mov [rdi], al - write byte
                  FCode.WriteU8($88);  // MOV r/m8, r8
                  FCode.WriteU8($07);  // ModRM: [RDI], AL
                end
                else if instr.ImmStr = 'peek8' then
                begin
                  // peek8(addr) -> int64 - read byte from memory
                  // xor rax, rax; mov al, [addr]
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // xor rax, rax - clear RAX
                  FCode.WriteU8($48);  // REX.W
                  FCode.WriteU8($31);  // XOR r/m64, r64
                  FCode.WriteU8($C0);  // ModRM: RAX, RAX
                  
                  // movzx eax, byte [rdi] - read byte and zero-extend
                  FCode.WriteU8($0F);  // two-byte opcode
                  FCode.WriteU8($B6);  // MOVZX r32, r/m8
                  FCode.WriteU8($07);  // ModRM: [RDI], EAX
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'poke16' then
                begin
                  // poke16(addr, value) - write 16-bit word to memory
                  // mov ax, value; mov [addr], ax
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // Get value into RAX
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RAX, 0);
                  
                  // mov [rdi], ax - write word (16-bit)
                  EmitRex(FCode, 1, 0, 0, 0);
                  FCode.WriteU8($89);  // MOV r/m16, r16
                  FCode.WriteU8($07);  // ModRM: [RDI], AX
                end
                else if instr.ImmStr = 'peek16' then
                begin
                  // peek16(addr) -> int64 - read 16-bit word from memory
                  // xor rax, rax; mov ax, [addr]
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // xor rax, rax - clear RAX
                  FCode.WriteU8($48);  // REX.W
                  FCode.WriteU8($31);  // XOR r/m64, r64
                  FCode.WriteU8($C0);  // ModRM: RAX, RAX
                  
                  // movzx eax, word [rdi] - read word and zero-extend
                  FCode.WriteU8($0F);  // two-byte opcode
                  FCode.WriteU8($B7);  // MOVZX r32, r/m16
                  FCode.WriteU8($07);  // ModRM: [RDI], EAX
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'poke32' then
                begin
                  // poke32(addr, value) - write 32-bit dword to memory
                  // mov eax, value; mov [addr], eax
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // Get value into RAX (low 32 bits)
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RAX, 0);
                  
                  // mov [rdi], eax - write dword (32-bit)
                  // Note: 32-bit mov automatically zero-extends to 64-bit
                  FCode.WriteU8($89);  // MOV r/m32, r32
                  FCode.WriteU8($07);  // ModRM: [RDI], EAX
                end
                else if instr.ImmStr = 'peek32' then
                begin
                  // peek32(addr) -> int64 - read 32-bit dword from memory
                  // mov eax, [addr] - 32-bit read automatically zero-extends
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // mov eax, [rdi] - read dword (zero-extends to 64-bit)
                  FCode.WriteU8($8B);  // MOV r32, r/m32
                  FCode.WriteU8($07);  // ModRM: [RDI], EAX
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'poke64' then
                begin
                  // poke64(addr, value) - write 64-bit qword to memory
                  // mov rax, value; mov [addr], rax
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // Get value into RAX
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RAX, 0);
                  
                  // mov [rdi], rax - write qword (64-bit)
                  EmitRex(FCode, 1, 0, 0, 0);
                  FCode.WriteU8($89);  // MOV r/m64, r64
                  FCode.WriteU8($07);  // ModRM: [RDI], RAX
                end
                else if instr.ImmStr = 'peek64' then
                begin
                  // peek64(addr) -> int64 - read 64-bit qword from memory
                  // mov rax, [addr]
                  
                  // Get addr into RDI
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  // mov rax, [rdi] - read qword (64-bit)
                  EmitRex(FCode, 1, 0, 0, 0);
                  FCode.WriteU8($8B);  // MOV r64, r/m64
                  FCode.WriteU8($07);  // ModRM: [RDI], RAX
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
                else if instr.ImmStr = 'write_raw' then
                begin
                  // write_raw(fd, buf, len) -> int64
                  // syscall: RAX=1, RDI=fd, RSI=buf, RDX=len
                  
                  if Length(instr.ArgTemps) >= 1 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[0];
                    WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDI, 0);
                  
                  if Length(instr.ArgTemps) >= 2 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[1];
                    WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RSI, 0);
                  
                  if Length(instr.ArgTemps) >= 3 then
                  begin
                    slotIdx := fn.LocalCount + instr.ArgTemps[2];
                    WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, RDX, 0);
                  
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
                  WriteSyscall(FCode);
                  
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end
               else if instr.ImmStr = 'buf_put_byte' then
              begin
                // buf_put_byte(buf: int64, idx: int64, b: int64) -> int64
                // Writes byte b to memory at address buf + idx
                // Returns 0 on success
                
                // Get buf (base address)
                if Length(instr.ArgTemps) >= 1 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[0]
                else if instr.Src1 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src1
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RDI, 0);
                
                // Get idx (offset)
                if Length(instr.ArgTemps) >= 2 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[1]
                else if instr.Src2 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src2
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RSI, 0);
                
                // Get b (byte value)
                arg3 := -1;
                if Length(instr.ArgTemps) >= 3 then
                  arg3 := instr.ArgTemps[2];
                if arg3 >= 0 then
                begin
                  slotIdx := fn.LocalCount + arg3;
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                end
                else
                  WriteMovRegImm64(FCode, RAX, 0);
                
                // Calculate address: rdi = rdi + rsi
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $01);
                EmitU8(FCode, $F7);  // add rdi, rsi
                
                // Write byte: mov [rdi], al
                EmitU8(FCode, $88);
                EmitU8(FCode, $07);  // mov [rdi], al
                
                // Return 0
                WriteMovRegImm64(FCode, RAX, 0);
                if instr.Dest >= 0 then
                begin
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end;
              end
              else if instr.ImmStr = 'buf_get_byte' then
              begin
                // buf_get_byte(buf: int64, idx: int64) -> int64
                // Reads byte from memory at address buf + idx
                
                // Get buf (base address)
                if Length(instr.ArgTemps) >= 1 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[0]
                else if instr.Src1 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src1
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RDI, 0);
                
                // Get idx (offset)
                if Length(instr.ArgTemps) >= 2 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[1]
                else if instr.Src2 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src2
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RSI, 0);
                
                // Calculate address: rdi = rdi + rsi
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $01);
                EmitU8(FCode, $F7);  // add rdi, rsi
                
                // Read byte: movzx rax, byte [rdi]
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $0F);
                EmitU8(FCode, $B6);
                EmitU8(FCode, $07);  // movzx rax, byte [rdi]
                
                if instr.Dest >= 0 then
                begin
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end;
              end
              else if instr.ImmStr = 'read' then
              begin
                // read(fd, buf, count) -> ssize_t
                // sys_read = 0
                
                // Get fd
                if Length(instr.ArgTemps) >= 1 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[0]
                else if instr.Src1 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src1
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RDI, 0);
                
                // Get buf
                if Length(instr.ArgTemps) >= 2 then
                  slotIdx := fn.LocalCount + instr.ArgTemps[1]
                else if instr.Src2 >= 0 then
                  slotIdx := fn.LocalCount + instr.Src2
                else
                  slotIdx := -1;
                if slotIdx >= 0 then
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx))
                else
                  WriteMovRegImm64(FCode, RSI, 0);
                
                // Get count
                arg3 := -1;
                if Length(instr.ArgTemps) >= 3 then
                  arg3 := instr.ArgTemps[2];
                if arg3 >= 0 then
                begin
                  slotIdx := fn.LocalCount + arg3;
                  WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));
                end
                else
                  WriteMovRegImm64(FCode, RDX, 0);
                
                WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_READ, SYS_MACOS_READ))); // sys_read
                WriteSyscall(FCode);

                if instr.Dest >= 0 then
                begin
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end;
              end
              else if instr.ImmStr = 'StrLen' then
              begin
                // StrLen(s: pchar): int64 — null-scan strlen, works on literals
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = s
                  // xor rcx, rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $C9);
                  // loop: cmp byte [rdi+rcx], 0  (4 bytes)
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0F); EmitU8(FCode, $00);
                  // jz +5 (skip inc+jmp)  (2 bytes)
                  EmitU8(FCode, $74); EmitU8(FCode, $05);
                  // inc rcx  (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // jmp -11 (back to cmp)  (2 bytes)
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);
                  // mov rax, rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $C8);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrCharAt' then
              begin
                // StrCharAt(s: pchar, i: int64): int64 — load byte at s[i] zero-extended
                if Length(instr.ArgTemps) >= 2 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = s
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // rsi = i
                  // movzx rax, byte [rdi+rsi]:  48 0F B6 04 37
                  EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6);
                  EmitU8(FCode, $04); EmitU8(FCode, $37);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrSetChar' then
              begin
                // StrSetChar(s: pchar, i: int64, c: int64) — write byte c to s[i]
                if Length(instr.ArgTemps) >= 3 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = s
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // rsi = i
                  slotIdx := fn.LocalCount + instr.ArgTemps[2];
                  WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));  // rdx = c
                  // mov byte [rdi+rsi], dl:  88 14 37
                  EmitU8(FCode, $88); EmitU8(FCode, $14); EmitU8(FCode, $37);
                end;
              end
              else if instr.ImmStr = 'StrNew' then
              begin
                // StrNew(capacity: int64): pchar — mmap alloc with 16-byte header, return data ptr
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = capacity
                  // push rdi (save capacity)
                  EmitU8(FCode, $57);
                  // rsi = capacity + 16 (total mmap size)
                  WriteMovRegReg(FCode, RSI, RDI);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10); // add rsi, 16
                  // mmap(NULL, rsi, PROT_READ|WRITE=3, MAP_PRIVATE|ANON=0x22, -1, 0)
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // pop rdi (restore capacity)
                  EmitU8(FCode, $5F);
                  // mov [rax], rdi  (store capacity at offset 0):  48 89 38
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $38);
                  // mov qword [rax+8], 0  (length=0 at offset 8):  48 C7 40 08 00 00 00 00
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $40); EmitU8(FCode, $08);
                  EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
                  // mov byte [rax+16], 0  (null terminator):  C6 40 10 00
                  EmitU8(FCode, $C6); EmitU8(FCode, $40); EmitU8(FCode, $10); EmitU8(FCode, $00);
                  // add rax, 16  (return data pointer):  48 83 C0 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrFree' then
              begin
                // StrFree(s: pchar) — munmap(s-16, *(s-16)+16)
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = s (data ptr)
                  // mov rsi, [rdi-16]  (load capacity):  48 8B 77 F0
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $77); EmitU8(FCode, $F0);
                  // add rsi, 16  (total size = capacity + 16):  48 83 C6 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);
                  // sub rdi, 16  (base = s - 16):  48 83 EF 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EF); EmitU8(FCode, $10);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
                  WriteSyscall(FCode);
                end;
              end
              else if instr.ImmStr = 'StrAppend' then
              begin
                // StrAppend(dest: pchar, src: pchar): pchar
                // Always-reallocate approach.
                // NOTE: syscall clobbers RCX and R11, so we use stack for all saved values.
                // Stack layout during execution (from top):
                //   [rsp+0]  = dest (old data ptr, saved for munmap)
                //   [rsp+8]  = src (saved for copy)
                //   [rsp+16] = newDest (= newBase+16, result)
                if Length(instr.ArgTemps) >= 2 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = dest
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // rsi = src

                  // Save dest and src
                  EmitU8(FCode, $57);  // push rdi (dest)   [rsp+0]
                  EmitU8(FCode, $56);  // push rsi (src)    [rsp+0]=src, [rsp+8]=dest

                  // Load destLen = *(dest-8) into RDX (save before scan overwrites RSI)
                  // dest is now at [rsp+8]; reload it: mov rdi, [rsp+8]:  48 8B 7C 24 08
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $7C); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  // mov rdx, [rdi-8]  (destLen):  48 8B 57 F8
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $57); EmitU8(FCode, $F8);

                  // Compute srcLen via null scan on RSI: rcx = 0
                  // rsi = src = [rsp+0]
                  WriteMovRegImm64(FCode, RCX, 0);
                  // cmp byte [rsi+rcx], 0  (4 bytes)
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
                  // jz +5  (2 bytes)
                  EmitU8(FCode, $74); EmitU8(FCode, $05);
                  // inc rcx  (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // jmp -11  (2 bytes)
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);
                  // rcx = srcLen

                  // rsi = mmap total size = destLen(rdx) + srcLen(rcx) + 17
                  WriteMovRegReg(FCode, RSI, RDX);
                  // add rsi, rcx:  48 01 CE
                  EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $CE);
                  // add rsi, 17:  48 83 C6 11
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $11);

                  // mmap(NULL, rsi, 3, 0x22, -1, 0)
                  WriteMovRegImm64(FCode, RDI, 0);
                  // rsi = size (already set)
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = newBase (R11 and RCX are clobbered by kernel after syscall)

                  // Compute newDest = newBase + 16
                  // save newBase+16 on stack
                  // add rax, 16:  48 83 C0 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
                  EmitU8(FCode, $50);  // push rax (newDest)  [rsp+0]=newDest, [rsp+8]=src, [rsp+16]=dest

                  // Reload dest and src to fill header
                  // dest at [rsp+16], src at [rsp+8]
                  // rdi = dest:  48 8B 7C 24 10
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $7C); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // rsi = src:  48 8B 74 24 08
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  // rcx = newDest = [rsp+0]:  48 8B 0C 24
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0C); EmitU8(FCode, $24);

                  // newBase = newDest - 16 = rcx - 16
                  // rdx = rcx - 16 (newBase):  48 8D 51 F0
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $51); EmitU8(FCode, $F0);

                  // destLen = *(dest-8):  mov rax, [rdi-8]:  48 8B 47 F8
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $47); EmitU8(FCode, $F8);
                  // push destLen:
                  EmitU8(FCode, $50);  // push rax  [rsp+0]=destLen, [rsp+8]=newDest, [rsp+16]=src, [rsp+24]=dest

                  // srcLen via null scan on RSI: reuse rcx=0
                  WriteMovRegImm64(FCode, RCX, 0);
                  // cmp byte [rsi+rcx], 0  (4 bytes)
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
                  // jz +5  (2 bytes)
                  EmitU8(FCode, $74); EmitU8(FCode, $05);
                  // inc rcx  (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // jmp -11  (2 bytes)
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);
                  // rcx = srcLen

                  // Fill header in new buffer (rdx = newBase):
                  // capacity = destLen + srcLen + 1 = [rsp] + rcx + 1
                  // rax = [rsp]:  48 8B 04 24
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  // push srcLen:
                  EmitU8(FCode, $51);  // push rcx  [rsp]=srcLen, [rsp+8]=destLen, [rsp+16]=newDest, [rsp+24]=src, [rsp+32]=dest

                  // rax = destLen + srcLen + 1 (capacity):
                  // add rax, rcx:  48 01 C8
                  EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C8);
                  // inc rax:  48 FF C0
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
                  // store capacity at [newBase]: mov [rdx], rax  (48 89 02)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $02);
                  // length = destLen + srcLen = capacity - 1:  dec rax:  48 FF C8
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C8);
                  // store length at [newBase+8]: mov [rdx+8], rax  (48 89 42 08)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $42); EmitU8(FCode, $08);

                  // Copy old dest content to newDest:
                  // newDest = [rsp+16], destLen = [rsp+8], dest = [rsp+32]
                  // rdi = newDest:  48 8B 7C 24 10
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $7C); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // rcx = destLen = [rsp+8]:  48 8B 4C 24 08
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  // rsi = dest (old data ptr) = [rsp+32]:  48 8B 74 24 20
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $20);
                  // rep movsb: copy destLen bytes from [rsi] to [rdi]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);
                  // rdi now = newDest + destLen

                  // Copy src to rdi: rsi = src = [rsp+24]:  48 8B 74 24 18
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $18);
                  // lodsb/stosb loop (copies including null terminator)
                  EmitU8(FCode, $AC);   // lodsb
                  EmitU8(FCode, $AA);   // stosb
                  EmitU8(FCode, $84); EmitU8(FCode, $C0);  // test al, al
                  EmitU8(FCode, $75); EmitU8(FCode, $FA);  // jnz -6

                  // munmap old buffer
                  // dest = [rsp+32], old capacity = *(dest-16)
                  // rdi = dest:  48 8B 7C 24 20
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $7C); EmitU8(FCode, $24); EmitU8(FCode, $20);
                  // rsi = *(dest-16) + 16:  mov rsi, [rdi-16]:  48 8B 77 F0
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $77); EmitU8(FCode, $F0);
                  // add rsi, 16:  48 83 C6 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);
                  // sub rdi, 16 (base):  48 83 EF 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EF); EmitU8(FCode, $10);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
                  WriteSyscall(FCode);

                  // Return newDest = [rsp+16]:  48 8B 44 24 10
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // Restore stack: pop srcLen, pop destLen, pop newDest, pop src, pop dest
                  EmitU8(FCode, $59);  // pop rcx (srcLen, discard)
                  EmitU8(FCode, $59);  // pop rcx (destLen, discard)
                  EmitU8(FCode, $59);  // pop rcx (newDest, discard)
                  EmitU8(FCode, $59);  // pop rcx (src, discard)
                  EmitU8(FCode, $59);  // pop rcx (dest, discard)

                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrFromInt' then
              begin
                // StrFromInt(n: int64): pchar — convert int64 to decimal string
                // Uses 32-byte stack buffer, fills digits right-to-left, then allocates result.
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = n

                  // Reserve 32-byte stack buffer + 8 bytes for flags = 40 bytes total (keep stack aligned)
                  // sub rsp, 40:  48 83 EC 28
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $28);

                  // Set null terminator at [rsp+23]:  C6 44 24 17 00
                  EmitU8(FCode, $C6); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $17); EmitU8(FCode, $00);

                  // rcx = 23 (write position, we fill backwards)
                  WriteMovRegImm64(FCode, RCX, 23);

                  // Check if negative: test rdi, rdi; jge .positive
                  // test rdi, rdi:  48 85 FF
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $FF);
                  // jge +7 (past neg+push1+jmp to reach push0):  7D 07
                  EmitU8(FCode, $7D); EmitU8(FCode, $07);
                  // neg rdi:  48 F7 DF
                  EmitU8(FCode, $48); EmitU8(FCode, $F7); EmitU8(FCode, $DF);
                  // push 1 (negative flag):  6A 01
                  EmitU8(FCode, $6A); EmitU8(FCode, $01);
                  // jmp +2 (past push 0):  EB 02
                  EmitU8(FCode, $EB); EmitU8(FCode, $02);
                  // push 0 (positive flag):  6A 00
                  EmitU8(FCode, $6A); EmitU8(FCode, $00);
                  // nop to align (jmp target):  but not needed since jge skips to here

                  // Digit loop: divide rdi by 10, get remainder as digit
                  // loop_start:
                  // xor rdx, rdx:  48 31 D2
                  EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $D2);
                  // mov rax, rdi:  48 89 F8
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $F8);
                  // mov r10, 10:  49 BA 0A 00 00 00 00 00 00 00
                  WriteMovRegImm64(FCode, R10, 10);
                  // div r10:  49 F7 F2
                  EmitU8(FCode, $49); EmitU8(FCode, $F7); EmitU8(FCode, $F2);
                  // rax = n/10, rdx = n%10
                  // rdi = rax (quotient):  48 89 C7
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $C7);
                  // add dl, '0':  80 C2 30
                  EmitU8(FCode, $80); EmitU8(FCode, $C2); EmitU8(FCode, $30);
                  // dec rcx:  48 FF C9
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C9);
                  // mov [rsp+rcx+8], dl  — note: rsp has 8 extra bytes from push flag
                  // We need to store at [rsp+rcx+8]: SIB with RSP base, RCX index, disp8=8
                  // mod=01 (disp8), reg=DL(2), rm=100 (SIB): ModRM=54, SIB=0C (ss=0,idx=RCX=1,base=RSP=4), disp=8
                  // 88 54 0C 08
                  EmitU8(FCode, $88); EmitU8(FCode, $54); EmitU8(FCode, $0C); EmitU8(FCode, $08);
                  // test rdi, rdi:  48 85 FF
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $FF);
                  // jnz back to loop_start
                  // loop_start is 3+10+3+3+3+4+3+3 = back from here
                  // Let's count bytes from loop_start to current jnz instruction:
                  // xor(3)+mov rax(3)+movabs r10(10)+div(3)+mov rdi(3)+add dl(3)+dec rcx(3)+mov [rsp+rcx+8](4)+test(3) = 35 bytes
                  // jnz: 75 (-37) = 75 DB (35 bytes of loop body + 2 for jnz itself)
                  EmitU8(FCode, $75); EmitU8(FCode, $DB);

                  // Pop negative flag into r10
                  EmitU8(FCode, $41); EmitU8(FCode, $5A);  // pop r10
                  // test r10, r10:  4D 85 D2
                  EmitU8(FCode, $4D); EmitU8(FCode, $85); EmitU8(FCode, $D2);
                  // jz +7 (skip dec_rcx(3)+movb_minus(4)=7 bytes):  74 07
                  EmitU8(FCode, $74); EmitU8(FCode, $07);
                  // dec rcx (make room for '-'):  48 FF C9
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C9);
                  // After pop r10 (flag), rsp=RSP0. Digits at [rsp+rcx]. Write '-' at [rsp+rcx] (no +8).
                  // mov byte [rsp+rcx*1], '-':  C6 04 0C 2D
                  EmitU8(FCode, $C6); EmitU8(FCode, $04); EmitU8(FCode, $0C); EmitU8(FCode, $2D);

                  // Now: rsp+rcx+8 = start of digit string (with sign if negative)
                  // length = 23 - rcx
                  // lea rsi, [rsp+rcx+8]: the data pointer for mmap copy
                  // But we need to mmap a new buffer first, then copy.
                  // rsi = mmap size = 24 - rcx (to cover all digits + null)
                  // mov rax, 24:  B8 18 00 00 00 (but need rex for 64-bit result... use movabs)
                  WriteMovRegImm64(FCode, RAX, 24);
                  // sub rax, rcx:  48 29 C8
                  EmitU8(FCode, $48); EmitU8(FCode, $29); EmitU8(FCode, $C8);
                  // save length in r11 = rax (= 24-rcx = actual string length incl null)
                  WriteMovRegReg(FCode, R11, RAX);
                  // rsi = r11 (mmap size), but we also need to know start offset
                  // save rcx in R10 for later (digit start offset in stack buf)
                  WriteMovRegReg(FCode, R10, RCX);

                  // mmap for result: size = r11 (includes null, use as capacity too)
                  // push r10 (rcx saved)
                  EmitU8(FCode, $41); EmitU8(FCode, $52);  // push r10
                  // push r11 (length incl null)
                  EmitU8(FCode, $41); EmitU8(FCode, $53);  // push r11

                  // mmap size = r11 + 16 (for header)
                  WriteMovRegReg(FCode, RSI, R11);
                  // add rsi, 16:  48 83 C6 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = newBase

                  // pop r11 (length incl null), pop r10 (digit start offset in [rsp+8+rcx])
                  EmitU8(FCode, $41); EmitU8(FCode, $5B);  // pop r11
                  EmitU8(FCode, $41); EmitU8(FCode, $5A);  // pop r10

                  // capacity = r11 - 1 (exclude null from capacity, or just use r11)
                  // Store capacity at [newBase]: mov [rax], r11  4C 89 18
                  EmitU8(FCode, $4C); EmitU8(FCode, $89); EmitU8(FCode, $18);
                  // length = r11 - 1 (exclude null):  r11 - 1 into rdx
                  WriteMovRegReg(FCode, RDX, R11);
                  // dec rdx:  48 FF CA
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $CA);
                  // store length at [newBase+8]: mov [rax+8], rdx  48 89 50 08
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $50); EmitU8(FCode, $08);

                  // newDest = newBase + 16; store in RDI for copy target
                  WriteMovRegReg(FCode, RDI, RAX);
                  // add rdi, 16:  48 83 C7 10
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C7); EmitU8(FCode, $10);
                  // save newDest in R11 for return
                  WriteMovRegReg(FCode, R11, RDI);

                  // Source: rsp + r10 + 8  (digit start in stack buffer; rsp shifted by 2 pushes = +16)
                  // Wait: after the two push r10/r11 and pop r11/r10, stack is back where it was.
                  // Stack layout at this point: [rsp+0..7] = nothing (just sub rsp,40 space)
                  // digit buffer at [rsp+8..rsp+31] (23 bytes of buffer + null at [rsp+31])
                  // r10 = digit start index in original rcx (= value of rcx when stored)
                  // So source = rsp + 8 + r10
                  // lea rsi, [rsp + r10 + 8]:
                  // mod=00, reg=RSI(6), rm=100 (SIB): ModRM=$34
                  // SIB: scale=0, index=R10(10 & 7 = 2), base=RSP(4): SIB = (0 shl 6) or (2 shl 3) or 4 = $14
                  // But R10 is an extended register (bit 3 set), need REX.X
                  // REX: W=1, R=0(RSI<8), X=1(R10>=8), B=0: REX = 0x48 | 0x02 = 0x4A
                  // 4A 8D 34 14 (no disp — RSP post-pop so digits at [rsp+r10])
                  EmitU8(FCode, $4A); EmitU8(FCode, $8D); EmitU8(FCode, $34); EmitU8(FCode, $14);
                  // rcx = r11_length = length+1 (copy including null)
                  WriteMovRegReg(FCode, RCX, R11);
                  // Hmm, R11 now holds newDest. We need the count (length+1 = old r11 before we moved it)
                  // Recompute: count = 24 - r10 (since null is at position 23, digit start at r10)
                  WriteMovRegImm64(FCode, RCX, 24);
                  // sub rcx, r10:  4C 29 D1
                  EmitU8(FCode, $4C); EmitU8(FCode, $29); EmitU8(FCode, $D1);
                  // rep movsb: copies rcx bytes from [rsi] to [rdi]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);

                  // Restore stack: add rsp, 40
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $28);

                  // Return R11 (newDest)
                  WriteMovRegReg(FCode, RAX, R11);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'str_concat' then
              begin
                // str_concat(a: pchar, b: pchar) -> pchar
                // Uses mmap to allocate buffer, copies both strings into it.
                // Strategy: use push/pop to save pointers; R10/R11 for lengths (caller-saved).
                //
                // Encoding notes:
                //   push rsi = $56, push rdx = $52, push rcx = $51
                //   pop rcx  = $59, pop rdx  = $5A, pop rsi  = $5E
                //   add rsi, r11: REX=4C, 01, DE
                //   inc rsi:  REX.W=48, FF, C6
                //   rep movsb = F3 A4
                //   lodsb     = AC
                //   stosb     = AA
                //   test al,al = 84 C0
                //   jnz -N    = 75 (256-N)
                if Length(instr.ArgTemps) >= 2 then
                begin
                  // Load a into rsi, b into rdx
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RDX, RBP, SlotOffset(slotIdx));

                  // Save a and b on stack
                  EmitU8(FCode, $56);  // push rsi (a)
                  EmitU8(FCode, $52);  // push rdx (b)

                  // strlen(a): rsi=a (already), rcx=0
                  // Loop structure: [10-byte movabs][4-byte cmp][2-byte jz +5][3-byte inc rcx][2-byte jmp -11]
                  // jz jumps over inc(3)+jmp(2) = 5 bytes. offset = +5 = $05
                  // jmp jumps back to cmp: back over jmp(2)+inc(3)+jz(2)+cmp(4) = 11. offset = -11 = $F5
                  WriteMovRegImm64(FCode, RCX, 0);
                  // loop_a: cmp byte [rsi+rcx], 0
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz +5 (past inc[3]+jmp[2])
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C1); // inc rcx
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);  // jmp -11 (back to cmp byte)
                  WriteMovRegReg(FCode, R10, RCX);  // r10 = len(a)

                  // strlen(b): rsi=rdx (b)
                  WriteMovRegReg(FCode, RSI, RDX);
                  WriteMovRegImm64(FCode, RCX, 0);
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz +5
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C1); // inc rcx
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);  // jmp -11
                  WriteMovRegReg(FCode, R11, RCX);  // r11 = len(b)

                  // mmap size: rsi = r10 + r11 + 1
                  WriteMovRegReg(FCode, RSI, R10);
                  // add rsi, r11: REX=0x4C (W=1,R=1 for r11,B=0 for rsi), opcode=01, ModRM=0xDE
                  EmitU8(FCode, $4C); EmitU8(FCode, $01); EmitU8(FCode, $DE);
                  // inc rsi: REX.W=48, FF, C6
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C6);

                  // mmap(NULL, rsi, PROT_RW=3, MAP_PRIVATE|MAP_ANON=0x22, fd=-1, off=0)
                  WriteMovRegImm64(FCode, RDI, 0);       // addr=NULL
                  // rsi = size (already set)
                  WriteMovRegImm64(FCode, RDX, 3);       // PROT_READ|WRITE
                  WriteMovRegImm64(FCode, R10, $22);     // MAP_PRIVATE|MAP_ANONYMOUS
                  WriteMovRegImm64(FCode, R8, UInt64(-1)); // fd=-1
                  WriteMovRegImm64(FCode, R9, 0);        // offset=0
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // RAX = buffer pointer

                  // Restore b ptr (rdx) and a ptr (rsi) from stack
                  EmitU8(FCode, $5A);  // pop rdx (b)
                  EmitU8(FCode, $5E);  // pop rsi (a)

                  // Save buffer start in R11 (return value)
                  WriteMovRegReg(FCode, R11, RAX);

                  // Copy a to buffer: rdi = rax (dest), rsi = a (src), rcx = len(a)
                  WriteMovRegReg(FCode, RDI, RAX);
                  WriteMovRegReg(FCode, RCX, R10);
                  // But r10 was overwritten by mmap arg! Need to recalculate len(a).
                  // Actually after pop rsi = a, we can do strlen(a) again.
                  // OR: we can save len(a) on stack before mmap.
                  // Let me save len(a) before mmap:
                  // Actually, let me restructure: save lens before mmap using push.

                  // Wait - R10 was used for mmap's R10 (MAP_PRIVATE|MAP_ANONYMOUS).
                  // After mmap, R10 = 0x22. We lost len(a).
                  // R11 was used as len(b) temp then re-saved as buffer.
                  // Fix: save len(a) and len(b) on stack before mmap.

                  // I need to redo the ordering. Let me rewrite:
                  // (all the code above is already emitted, so I need to emit correct code from here)
                  // Actually no - the code above IS the final emitted code. There's a bug.
                  // Let me fix this by recalculating len(a) from rsi (which was restored from stack):

                  // Recalculate len(a): rsi=a, rcx=0
                  WriteMovRegImm64(FCode, RCX, 0);
                  EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz +5
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C1); // inc rcx
                  EmitU8(FCode, $EB); EmitU8(FCode, $F5);  // jmp -11
                  // rcx = len(a)

                  // rdi = buffer (R11), rsi = a
                  WriteMovRegReg(FCode, RDI, R11);

                  // rep movsb: copies rcx bytes from [rsi] to [rdi]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);  // rep movsb

                  // Now rsi = a+len(a), rdi = buf+len(a)
                  // Copy b: rsi = rdx (b was in rdx - but rdx was popped into rdx above)
                  WriteMovRegReg(FCode, RSI, RDX);

                  // Copy b including null terminator using lodsb/stosb loop
                  // loop: lodsb; stosb; test al,al; jnz loop
                  // lodsb: AC
                  EmitU8(FCode, $AC);   // lodsb
                  EmitU8(FCode, $AA);   // stosb
                  EmitU8(FCode, $84); EmitU8(FCode, $C0);   // test al, al
                  EmitU8(FCode, $75); EmitU8(FCode, $FA);   // jnz -6 (back 6 bytes to lodsb)

                  // Result: R11 = buffer start
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), R11);
                  end;
                end;
              end
              else if instr.ImmStr = 'PrintFloat' then
              begin
                // PrintFloat(value: f64) -> void
                // Prints a float with 6 decimal digits to stdout.
                // Uses stack for temp storage.
                // Stack layout (after sub rsp,48):
                //   [rsp+0..rsp+15]  = digit buffer for integer part (16 bytes)
                //   [rsp+16]         = single char buffer (for '.', '-', digit)
                //   [rsp+24]         = f64 constant 10.0
                //   [rsp+32..rsp+39] = r10 save slot
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(slotIdx)); // xmm0 = value

                  // sub rsp, 48
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 48);

                  // Store 10.0 at [rsp+24]
                  WriteMovRegImm64(FCode, RAX, UInt64($4024000000000000));
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 24);

                  // Check sign: xorpd xmm1, xmm1 (zero)
                  WriteXorpd(FCode, XMM1, XMM1);
                  // ucomisd xmm0, xmm1: sets flags for xmm0 vs 0
                  WriteUcomisd(FCode, XMM0, XMM1);
                  // jae .Lpositive: if xmm0 >= 0 jump forward (past neg block)
                  // neg block size: mov+lea+mov*3+syscall+2*xorpd+subsd+movsd = ~60 bytes... hard to predict.
                  // Use jmp patch: emit jae with placeholder, record position, fill later.
                  // For simplicity, use a conditional approach: print '-' only if negative.
                  // Emit jnb (JAE = 0x73) with placeholder offset to jump over neg handling.
                  EmitU8(FCode, $73); EmitU8(FCode, $00); // jae +0 placeholder (2 bytes)
                  // Record patch position: FCode.Size - 1 is the offset byte
                  // We'll patch it after emitting the neg block.
                  // Save patch position
                  arg3 := FCode.Size - 1;  // position of the jae offset byte

                  // === Negative handling block ===
                  // Print '-'
                  EmitU8(FCode, $C6); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 16); EmitU8(FCode, $2D); // mov byte [rsp+16], '-'
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, 16); // lea rsi, [rsp+16]
                  WriteMovRegImm64(FCode, RDX, 1);
                  WriteMovRegImm64(FCode, RDI, 1);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
                  WriteSyscall(FCode);
                  // Negate: subsd xmm1, xmm0 (xmm1=0-xmm0); xmm0 = xmm1
                  WriteXorpd(FCode, XMM1, XMM1);  // xmm1 = 0
                  WriteSubsd(FCode, XMM1, XMM0);  // xmm1 = -xmm0
                  // movsd xmm0, xmm1 (F2 0F 10 C1)
                  EmitU8(FCode, $F2); EmitU8(FCode, $0F); EmitU8(FCode, $10); EmitU8(FCode, $C1);

                  // Patch the jae offset: jump target is current position
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));

                  // === Positive path ===
                  // Extract integer part: cvttsd2si rax, xmm0
                  WriteCvttsd2si(FCode, RAX, XMM0);
                  WriteMovRegReg(FCode, R10, RAX);  // save integer part in r10

                  // Print integer part: build digits at [rsp+14] downwards.
                  // rdi starts at [rsp+15] (one past end). Each digit: dec rdi; store.
                  // After loop: rdi = MSB digit address. Length = [rsp+15] - rdi.
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $7C); EmitU8(FCode, $24); EmitU8(FCode, 15); // lea rdi, [rsp+15]
                  // test rax, rax
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  // jnz .Ldigits: skip 3+3+2=8 bytes (dec rdi + mov '0' + jmp)
                  EmitU8(FCode, $75); EmitU8(FCode, $08);  // jnz +8
                  // zero case: dec rdi (to [14]), store '0', then jmp past loop = 3+3+2 = 8 bytes
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $CF);  // dec rdi
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $30);  // mov byte [rdi], '0'
                  // jump past digit loop
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);  // jmp +0 placeholder
                  arg4 := FCode.Size - 1;  // patch pos for "past digit loop" jump

                  // .Ldigits: rcx = 10 (divisor) -- jnz +8 lands here
                  WriteMovRegImm64(FCode, RCX, 10);
                  // digit loop: dec rdi; xor rdx,rdx; div rcx; add dl,'0'; mov [rdi],dl; test rax,rax; jnz
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $CF);  // dec rdi
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $31); EmitU8(FCode, $D2);  // xor rdx,rdx
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $F7); EmitU8(FCode, $F1);  // div rcx
                  EmitU8(FCode, $80); EmitU8(FCode, $C2); EmitU8(FCode, $30);           // add dl,'0'
                  EmitU8(FCode, $88); EmitU8(FCode, $17);                               // mov [rdi],dl
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test rax,rax
                  EmitU8(FCode, $75); EmitU8(FCode, $ED);  // jnz -19 (back to dec rdi)

                  // Patch "jmp past digit loop" to here (rdi already points to MSB digit)
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));

                  // print: rsi=rdi, rdx=[rsp+15]-rdi, rdi=1
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $89); EmitU8(FCode, $FE);  // mov rsi, rdi
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $54); EmitU8(FCode, $24); EmitU8(FCode, 15); // lea rdx,[rsp+15]
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $29); EmitU8(FCode, $FA);  // sub rdx, rdi
                  WriteMovRegImm64(FCode, RDI, 1);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
                  WriteSyscall(FCode);

                  // Print '.'
                  EmitU8(FCode, $C6); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 16); EmitU8(FCode, $2E); // mov byte [rsp+16],'.'
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, 16);
                  WriteMovRegImm64(FCode, RDX, 1);
                  WriteMovRegImm64(FCode, RDI, 1);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
                  WriteSyscall(FCode);

                  // Compute fractional: xmm0 -= float(r10)
                  WriteCvtsi2sd(FCode, XMM1, R10);
                  WriteSubsd(FCode, XMM0, XMM1);

                  // Load 10.0 into xmm1 from [rsp+24]
                  WriteMovsdLoad(FCode, XMM1, RSP, 24);

                  // Emit 6 unrolled decimal digit iterations (no backward jump offset issues)
                  // Each iteration:
                  //   mulsd xmm0, xmm1         (xmm0 *= 10)
                  //   cvttsd2si rax, xmm0      (rax = digit)
                  //   mov r10, rax             (save)
                  //   add rax, '0'             (add 48)
                  //   mov [rsp+16], al         (store char)
                  //   lea rsi, [rsp+16]        (point to char)
                  //   mov rdx, 1               (length)
                  //   mov rdi, 1               (stdout)
                  //   mov rax, SYS_WRITE       (syscall number)
                  //   syscall
                  //   cvtsi2sd xmm1, r10       (float(digit))
                  //   subsd xmm0, xmm1         (remove digit)
                  //   movsd xmm1, [rsp+24]     (reload 10.0)
                  arg3 := 6;
                  while arg3 > 0 do
                  begin
                    WriteMulsd(FCode, XMM0, XMM1);
                    WriteCvttsd2si(FCode, RAX, XMM0);
                    WriteMovRegReg(FCode, R10, RAX);
                    EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $30); // add rax,48
                    EmitU8(FCode, $88); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 16);           // mov [rsp+16],al
                    EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, 16);
                    WriteMovRegImm64(FCode, RDX, 1);
                    WriteMovRegImm64(FCode, RDI, 1);
                    WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
                    WriteSyscall(FCode);
                    WriteCvtsi2sd(FCode, XMM1, R10);
                    WriteSubsd(FCode, XMM0, XMM1);
                    WriteMovsdLoad(FCode, XMM1, RSP, 24);
                    Dec(arg3);
                  end;

                  // Restore stack
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 48); // add rsp, 48
                end;
              end
              else if instr.ImmStr = 'format_float' then
              begin
                // format_float(value: f64, width: int64, decimals: int64) -> pchar
                // Formats a float with `decimals` decimal places into a mmap'd buffer.
                // For simplicity, we use a fixed 6 decimal digits (ignoring width/decimals args for now)
                // and return pointer to the mmap'd buffer.
                // TODO: use decimals arg for variable decimal places
                if Length(instr.ArgTemps) >= 3 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovsdLoad(FCode, XMM0, RBP, SlotOffset(slotIdx)); // xmm0 = value

                  // Allocate a 64-byte buffer via mmap
                  WriteMovRegImm64(FCode, RDI, 0);      // addr=NULL
                  WriteMovRegImm64(FCode, RSI, 64);     // size=64
                  WriteMovRegImm64(FCode, RDX, 3);      // PROT_READ|WRITE
                  WriteMovRegImm64(FCode, R10, $22);    // MAP_PRIVATE|MAP_ANONYMOUS
                  WriteMovRegImm64(FCode, R8, UInt64(-1)); // fd=-1
                  WriteMovRegImm64(FCode, R9, 0);       // offset=0
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // RAX = buffer ptr. Save in R11.
                  WriteMovRegReg(FCode, R11, RAX);

                  // We need stack temp for 10.0 constant and digit buffer.
                  // sub rsp, 48
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 48);

                  // Store 10.0 at [rsp+24]
                  WriteMovRegImm64(FCode, RAX, UInt64($4024000000000000));
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, 24);

                  // rdi = buffer write pointer (R11 = buffer base)
                  WriteMovRegReg(FCode, RDI, R11);

                  // Handle sign
                  WriteXorpd(FCode, XMM1, XMM1);
                  WriteUcomisd(FCode, XMM0, XMM1);
                  EmitU8(FCode, $73); EmitU8(FCode, $00); // jae placeholder
                  arg3 := FCode.Size - 1;
                  // Write '-'
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $2D);  // mov byte [rdi], '-'
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C7);  // inc rdi
                  // Negate xmm0
                  WriteXorpd(FCode, XMM1, XMM1);
                  WriteSubsd(FCode, XMM1, XMM0);
                  EmitU8(FCode, $F2); EmitU8(FCode, $0F); EmitU8(FCode, $10); EmitU8(FCode, $C1); // movsd xmm0, xmm1
                  // Patch jae
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));

                  // Extract integer part
                  WriteCvttsd2si(FCode, RAX, XMM0);
                  WriteMovRegReg(FCode, R10, RAX);

                  // Build integer digits at [rsp+0..rsp+14] backwards.
                  // rsi starts at [rsp+15]. Each digit: dec rsi; store.
                  // After loop: rsi = MSB digit address. Count = [rsp+15] - rsi.
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, 15); // lea rsi, [rsp+15]
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test rax,rax
                  EmitU8(FCode, $75); EmitU8(FCode, $08);  // jnz +8 (skip 3+3+2=8 bytes)
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $CE);  // dec rsi
                  EmitU8(FCode, $C6); EmitU8(FCode, $06); EmitU8(FCode, $30);  // mov byte [rsi], '0'
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);  // jmp +0 placeholder
                  arg4 := FCode.Size - 1;
                  WriteMovRegImm64(FCode, RCX, 10);
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $CE);  // dec rsi
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $31); EmitU8(FCode, $D2);  // xor rdx,rdx
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $F7); EmitU8(FCode, $F1);  // div rcx
                  EmitU8(FCode, $80); EmitU8(FCode, $C2); EmitU8(FCode, $30);           // add dl,'0'
                  EmitU8(FCode, $88); EmitU8(FCode, $16);                               // mov [rsi],dl
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test rax,rax
                  EmitU8(FCode, $75); EmitU8(FCode, $ED);  // jnz -19
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  // rsi already points to MSB digit. Copy [rsi..[rsp+15]) to [rdi].
                  // compute count: lea rcx, [rsp+15]; sub rcx, rsi
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $8D); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, 15); // lea rcx,[rsp+15]
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $29); EmitU8(FCode, $F1);  // sub rcx, rsi
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);  // rep movsb

                  // Write '.'
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $2E);  // mov byte [rdi], '.'
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C7);  // inc rdi

                  // Compute fractional: xmm0 -= float(r10)
                  WriteCvtsi2sd(FCode, XMM1, R10);
                  WriteSubsd(FCode, XMM0, XMM1);

                  // Load 10.0
                  WriteMovsdLoad(FCode, XMM1, RSP, 24);

                  // Load decimals count from ArgTemps[2] slot into RCX
                  WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.ArgTemps[2]));

                  // Fractional digit loop (RCX = remaining digits):
                  //   test rcx,rcx; jz done
                  //   mulsd xmm0,xmm1; cvttsd2si rax,xmm0; mov r10,rax
                  //   add rax,48; mov [rdi],al; inc rdi
                  //   cvtsi2sd xmm2,r10; subsd xmm0,xmm2 (use xmm2 to preserve xmm1)
                  //   movsd xmm1,[rsp+24]; dec rcx; jmp loop
                  loopStartPos := FCode.Size;
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $85); EmitU8(FCode, $C9);  // test rcx,rcx
                  EmitU8(FCode, $74); EmitU8(FCode, 0);  // jz done (patch)
                  jzPatchPos := FCode.Size - 1;
                  WriteMulsd(FCode, XMM0, XMM1);
                  WriteCvttsd2si(FCode, RAX, XMM0);
                  WriteMovRegReg(FCode, R10, RAX);
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $30); // add rax,48
                  EmitU8(FCode, $88); EmitU8(FCode, $07);  // mov [rdi],al
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C7);  // inc rdi
                  WriteCvtsi2sd(FCode, XMM2, R10);  // xmm2 = float(digit) — don't clobber xmm1
                  WriteSubsd(FCode, XMM0, XMM2);
                  WriteMovsdLoad(FCode, XMM1, RSP, 24);  // reload 10.0
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C9);  // dec rcx
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(loopStartPos - (FCode.Size + 1)));  // jmp loop
                  FCode.PatchU8(jzPatchPos, Byte(FCode.Size - (jzPatchPos + 1)));

                  // Write null terminator
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);  // mov byte [rdi], 0

                  // Restore stack
                  EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 48); // add rsp, 48

                  // Store R11 (buffer base) in dest slot
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), R11);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrFindChar' then
              begin
                // StrFindChar(s: pchar, c: int64, from: int64): int64
                // Scan s[from..] for byte c. Return index (from 0) or -1 if not found.
                if Length(instr.ArgTemps) >= 3 then
                begin
                  // rdi = s (base pointer)
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  // rsi = c (byte to find)
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));
                  // rcx = from (starting index)
                  slotIdx := fn.LocalCount + instr.ArgTemps[2];
                  WriteMovRegMem(FCode, RCX, RBP, SlotOffset(slotIdx));
                  // rax = -1 (not found default)
                  WriteMovRegImm64(FCode, RAX, UInt64(-1));
                  // scan loop: rdi+rcx = current byte address
                  // movzx rdx, byte [rdi+rcx]  (0F B6 14 0F)
                  // test rdx, rdx → jz not_found
                  // cmp rdx, rsi → je found
                  // inc rcx → jmp loop
                  // loop_start:
                  //   movzx rdx, byte [rdi+rcx]
                  //   test rdx, rdx → jz done (not found, rax=-1)
                  //   cmp rdx, rsi → je found
                  //   inc rcx
                  //   jmp loop_start
                  // found: mov rax, rcx
                  // done:
                  leaPos := FCode.Size;  // loop start  (P+0)
                  // P+0:  movzx edx, byte [rdi+rcx]: 0F B6 14 0F  (4 bytes)
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0F);
                  // P+4:  test rdx, rdx (48 85 D2)               (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $D2);
                  // P+7:  jz +13 → P+22 (done, rax=-1 already)  (2 bytes)
                  EmitU8(FCode, $74); EmitU8(FCode, $0D);
                  // P+9:  cmp rdx, rsi (48 39 F2)                (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $F2);
                  // P+12: je +5 → P+19 (found)                   (2 bytes)
                  EmitU8(FCode, $74); EmitU8(FCode, $05);
                  // P+14: inc rcx (48 FF C1)                     (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // P+17: jmp loop_start (-19 from end = EB ED)  (2 bytes)
                  EmitU8(FCode, $EB); EmitU8(FCode, $ED);
                  // P+19: found: mov rax, rcx (48 89 C8)         (3 bytes)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $C8);
                  // P+22: done
                  // done:
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrSub' then
              begin
                // StrSub(s: pchar, start: int64, len: int64): pchar
                // mmap a new string of len+17 bytes, copy len bytes from s+start, return data ptr (base+16)
                if Length(instr.ArgTemps) >= 3 then
                begin
                  // sub rsp, 40 (16-byte aligned: 40 = 8+8+8+8+8)
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $28);
                  // save s at [rsp+0], start at [rsp+8], len at [rsp+16]
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  // mov [rsp], rax
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  // mov [rsp+8], rax
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  slotIdx := fn.LocalCount + instr.ArgTemps[2];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  // mov [rsp+16], rax (len)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // mmap(0, len+17, 3, 0x22, -1, 0)
                  // rdi=0, rsi=len+17, rdx=3, r10=0x22, r8=-1, r9=0
                  WriteMovRegImm64(FCode, RDI, 0);
                  // rsi = len + 17: load len from [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  // lea rsi, [rax+17] (48 8D 70 11)
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $70); EmitU8(FCode, $11);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = mmap base. Save at [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov [rsp+24],rax
                  // Write header: [base+0]=len (cap), [base+8]=len (length)
                  // rcx = len = [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rcx,[rsp+16]
                  // mov [rax], rcx  (48 89 08)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $08);
                  // mov [rax+8], rcx  (48 89 48 08)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, $08);
                  // Copy len bytes from s+start into base+16
                  // rdi = base+16
                  // mov rdi, rax; add rdi, 16
                  WriteMovRegReg(FCode, RDI, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C7); EmitU8(FCode, $10);  // add rdi, 16
                  // rsi = s + start = [rsp+0] + [rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);  // mov rsi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rax,[rsp+8]
                  // add rsi, rax  (48 01 C6)
                  EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C6);
                  // rcx = len = [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rcx,[rsp+16]
                  // rep movsb (F3 A4)
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);
                  // null terminate: mov byte [rdi], 0  (C6 07 00)
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);
                  // result = base + 16
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov rax,[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);  // add rax, 16
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $28);  // add rsp, 40
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrAppendStr' then
              begin
                // StrAppendStr(s: pchar, other: pchar): pchar
                // Append other to s. s has header [cap:8][len:8] at s-16 and s-8.
                // If len_s+len_other < cap: copy in place, update len, return s
                // Else: mmap new buffer, copy both, munmap old, return new_data
                if Length(instr.ArgTemps) >= 2 then
                begin
                  // sub rsp, 48
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $30);
                  // save s at [rsp+0], other at [rsp+8]
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);  // mov [rsp+0], rax
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov [rsp+8], rax
                  // rdi = s; len_s = [s-8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $47); EmitU8(FCode, $F8);  // mov rax,[rdi-8]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov [rsp+16], rax (len_s)
                  // strlen(other): rsi = other, scan for null
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  WriteMovRegImm64(FCode, RCX, 0);
                  // strlen loop for other
                  leaPos := FCode.Size;
                  // movzx rax, byte [rsi+rcx]: 0F B6 04 0E
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);
                  // test rax, rax (48 85 C0)
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  // jz +5 (done with strlen: skip inc rcx 3B + jmp 2B)
                  EmitU8(FCode, $74); EmitU8(FCode, $05);
                  // inc rcx (48 FF C1)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // jmp loop
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // rcx = len_other. Save at [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov [rsp+24], rcx
                  // new_total = len_s + len_other: rax = [rsp+16] + [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $03); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // add rax,[rsp+24]
                  // rax = new_total
                  // cap = [s-16] = [rdi-16]; rdi = [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4F); EmitU8(FCode, $F0);  // mov rcx,[rdi-16]
                  // cmp rax, rcx (new_total vs cap) (48 39 C8)
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $C8);
                  // jl fits_in_place (if new_total < cap, near 32-bit forward jump)
                  EmitU8(FCode, $0F); EmitU8(FCode, $8C); EmitU32(FCode, 0);
                  leaPos := FCode.Size - 4;  // patch target for jl (32-bit offset)

                  // ELSE: need realloc path
                  // mmap new buf: size = (new_total)*2 + 17
                  // rax = new_total (already computed), save it
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $20);  // mov [rsp+32], rax (new_total)
                  // new_cap = new_total * 2
                  EmitU8(FCode, $48); EmitU8(FCode, $D1); EmitU8(FCode, $E0);  // shl rax, 1
                  // mmap size = new_cap + 17
                  // lea rsi, [rax+17]
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $70); EmitU8(FCode, $11);
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = new_base. Save at [rsp+40] (we use 40 for new_base... but rsp+40 = index 5 in 8-byte slots, need 48 bytes total)
                  // Note: [rsp+40] is within our 48-byte frame
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $28);  // mov [rsp+40], rax (new_base)
                  // Set cap header: new_cap = new_total*2; new_total is at [rsp+32]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $20);  // mov rcx,[rsp+32]
                  EmitU8(FCode, $48); EmitU8(FCode, $D1); EmitU8(FCode, $E1);  // shl rcx, 1 (new_cap)
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $08);  // mov [rax], rcx
                  // Set len header: [rax+8] = new_total
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $20);  // mov rcx,[rsp+32]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, $08);  // mov [rax+8], rcx
                  // Copy s[0..len_s] into new_base+16
                  // rdi = new_base+16
                  WriteMovRegReg(FCode, RDI, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C7); EmitU8(FCode, $10);  // add rdi, 16
                  // rsi = s = [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);  // mov rsi,[rsp+0]
                  // rcx = len_s = [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rcx,[rsp+16]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);  // rep movsb
                  // Copy other[0..len_other] into rdi (already advanced)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov rcx,[rsp+24]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);  // rep movsb
                  // null terminate: mov byte [rdi], 0
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);
                  // munmap old s: rdi = s-16 = [rsp+0]-16, rsi = old cap+16+1 (approx, use old cap from [rsp+0]-16)
                  // Actually just munmap the old s base: rdi = [rsp+0]-16
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EF); EmitU8(FCode, $10);  // sub rdi, 16
                  // rsi = old size = old_cap + 17 = [rdi] + 17 (cap is at [old_base])
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $37);  // mov rsi,[rdi]
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $11);  // add rsi, 17
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
                  WriteSyscall(FCode);
                  // return new_base+16
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $28);  // mov rax,[rsp+40]
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);  // add rax, 16
                  // jmp done (skip in-place path)
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  arg3 := FCode.Size - 1;  // patch jmp done

                  // fits_in_place: patch jl target (32-bit near jump offset)
                  FCode.PatchU32LE(leaPos, Cardinal(FCode.Size - (leaPos + 4)));
                  // rdi = s = [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  // dst = s + len_s = rdi + [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  // add rdi, rax  (48 01 C7)
                  EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C7);
                  // rsi = other = [rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  // rcx = len_other = [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov rcx,[rsp+24]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);  // rep movsb
                  // null terminate
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);
                  // update len: [s-8] = new_total = len_s + len_other
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $03); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // add rax,[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $47); EmitU8(FCode, $F8);  // mov [rdi-8], rax
                  // return s = [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $24);  // mov rax,[rsp+0]
                  // done: patch jmp
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $30);  // add rsp, 48
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrConcat' then
              begin
                // StrConcat(a: pchar, b: pchar): pchar
                // Create new string = a + b concatenated.
                if Length(instr.ArgTemps) >= 2 then
                begin
                  // sub rsp, 48
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $30);
                  // save a at [rsp+0], b at [rsp+8]
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  // strlen(a) → rcx, save at [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);  // mov rsi,[rsp+0]
                  WriteMovRegImm64(FCode, RCX, 0);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);  // movzx rax,byte[rsi+rcx]
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test rax,rax
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz done_a (skip inc 3B + jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc rcx
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov [rsp+16],rcx
                  // strlen(b) → rcx, save at [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  WriteMovRegImm64(FCode, RCX, 0);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz done_b (skip inc 3B + jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov [rsp+24],rcx
                  // mmap(0, len_a+len_b+17, 3, 0x22, -1, 0)
                  // rsi = len_a + len_b + 17
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $03); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // add rax,[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $70); EmitU8(FCode, $11);  // lea rsi,[rax+17]
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = new_base. Save at [rsp+32]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $20);
                  // write cap header = len_a+len_b
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rcx,[rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $03); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);  // add rcx,[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $08);  // mov [rax], rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, $08);  // mov [rax+8], rcx
                  // rdi = rax+16 (data area)
                  WriteMovRegReg(FCode, RDI, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C7); EmitU8(FCode, $10);
                  // copy a: rsi=[rsp+0], rcx=[rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);
                  // copy b: rsi=[rsp+8], rcx=[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);
                  // null terminate
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);
                  // return new_base+16
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $20);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $30);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrCopy' then
              begin
                // StrCopy(s: pchar): pchar
                // Deep copy of s. Read length from [s-8]. mmap new buffer. Copy header+data.
                if Length(instr.ArgTemps) >= 1 then
                begin
                  // sub rsp, 24
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $18);
                  // save s at [rsp+0]
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  // len = [s-8]: rax = s, rcx = [rax-8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, $F8);  // mov rcx,[rax-8]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov [rsp+8],rcx
                  // mmap(0, len+17, 3, 0x22, -1, 0)
                  // rsi = len+17 = rcx+17
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $71); EmitU8(FCode, $11);  // lea rsi,[rcx+17]
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = new_base
                  // write cap = len = [rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rcx,[rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $08);  // mov [rax],rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, $08);  // mov [rax+8],rcx
                  // copy data: rdi=rax+16, rsi=s=[rsp+0], rcx=len=[rsp+8]
                  WriteMovRegReg(FCode, RDI, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C7); EmitU8(FCode, $10);
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);  // mov rsi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rcx,[rsp+8]
                  EmitU8(FCode, $F3); EmitU8(FCode, $A4);
                  // null terminate
                  EmitU8(FCode, $C6); EmitU8(FCode, $07); EmitU8(FCode, $00);
                  // return new_base+16: sub rdi,16 was moved, just use rax directly
                  // rdi now points past the copy; we need rax+16
                  // Reload rax: we lost it. But rdi = rax+16+len+1, so we can't recover easily.
                  // Better: save rax before copy. Redo: save new_base at [rsp+16].
                  // (patch: we need to save rax before modifying rdi. Let's insert mov [rsp+16],rax before rdi=rax+16)
                  // Actually we already moved rax into rdi+16, so let's sub rdi back:
                  // rdi = rax+16+len. So rax = rdi - 16 - len = rdi - rcx - 16. But rcx=0 after rep movsb.
                  // Simplest: we saved rcx (len) at [rsp+8]. rdi after rep movsb = rax+16+len.
                  // So rax = rdi - 16 - [rsp+8]... complex. Instead restructure to save rax.
                  // The above code already has WriteMovRegReg(FCode, RDI, RAX) which makes rdi=rax.
                  // Then add rdi,16. So rax is still valid as new_base. Let's check: after WriteSyscall,
                  // rax = new_base. We wrote [rax], [rax+8]. Then WriteMovRegReg(RDI,RAX) -> rdi=rax (=new_base).
                  // Then add rdi,16. Then movsb. AFTER movsb, rax is not changed by movsb (movsb uses rdi/rsi/rcx).
                  // So rax still = new_base! Great.
                  // add rax, 16
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $18);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'FileGetSize' then
              begin
                // FileGetSize(path: pchar): int64
                // open(path, O_RDONLY=0, 0) → fd
                // if fd < 0: return -1
                // lseek(fd, 0, SEEK_END=2) → size
                // close(fd)
                // return size
                if Length(instr.ArgTemps) >= 1 then
                begin
                  // sub rsp, 16
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $10);
                  // open(path, 0, 0)
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                  WriteMovRegImm64(FCode, RSI, 0);
                  WriteMovRegImm64(FCode, RDX, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_OPEN, SYS_MACOS_OPEN)));
                  WriteSyscall(FCode);
                  // test rax, rax: jns ok (48 85 C0, 79 XX)
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $79); EmitU8(FCode, $0A);  // jns ok (forward 10 bytes)
                  // open failed: mov rax, -1; add rsp,16; jmp done
                  WriteMovRegImm64(FCode, RAX, UInt64(-1));
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  arg3 := FCode.Size - 1;  // patch jmp done
                  // ok: save fd at [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);  // mov [rsp+0],rax
                  // Patch the jns: it was 10 bytes forward from after the jns instruction
                  // jns was at pos-2. The instruction after jns is at pos. Target is here.
                  // We emitted: jns +10, then 10 bytes (7+3 = 10 is: WriteMovRegImm64=10, add rsp=4, jmp=2 = 16 not 10)
                  // Let me count: WriteMovRegImm64(RAX,-1)=10 bytes, add rsp,16=4 bytes, jmp=2 bytes = 16 bytes
                  // Fix: change jns offset to 16 (0x10)
                  // But we already emitted $0A... We need to patch it. The jns is at FCode.Size - 16 - 2... complex.
                  // Let's just save fd, do lseek, close, and patch properly.
                  // Actually let me restructure: emit the error path as a forward jump from jns,
                  // and place the error path after the success path.
                  // The jns +0A emitted already needs to jump over: WriteMovRegImm64(10) + add rsp(4) + jmp(2) = 16 bytes.
                  // We emitted jns $0A which is only 10 bytes forward. This is wrong.
                  // Since we already emitted it, let's just fix it: the jns byte is 2 bytes back from where
                  // WriteMovRegImm64 started. WriteMovRegImm64 = 10 bytes, add rsp = 4, jmp = 2 → total = 16.
                  // So we need jns +16 = $10. But we already wrote $0A. We need to patch.
                  // We already set arg3 to the jmp's patch pos. The jns patch pos is arg3 - 16 + 2... messy.
                  // RESTART this builtin with a cleaner structure. I'll use jns to jump OVER the error path to a label.
                  // Unfortunately the code is already emitted so I'll accept the bug and fix the offset.
                  // Actually re-counting: the jns opcode is at some position P. After emitting $79 $0A, we are at P+2.
                  // From P+2, we emit:
                  //   WriteMovRegImm64(RAX,-1): 10 bytes → P+12
                  //   add rsp,16: 4 bytes → P+16
                  //   jmp rel8: 2 bytes → P+18
                  // Then the "ok" label is at P+18.
                  // jns offset = target - (P+2) = P+18 - P+2 = 16 = $10. But we wrote $0A.
                  // NEED TO FIX. We already wrote the jns. We need to patch the $0A to $10.
                  // The jns byte is at position: FCode.Size (after mov [rsp],rax = 4 bytes) - 4 - 16 - 2 = FCode.Size - 22
                  // Wait: we are at "ok" label now. Let me count from here back:
                  //   mov [rsp+0],rax = 4 bytes
                  //   jmp rel8 = 2 bytes
                  //   add rsp,16 = 4 bytes
                  //   WriteMovRegImm64(RAX,-1) = 10 bytes
                  //   jns rel8 = 2 bytes
                  // So jns offset byte is at FCode.Size - 4 - 2 - 4 - 10 - 1 = FCode.Size - 21
                  FCode.PatchU8(FCode.Size - (4 + 2 + 4 + 10 + 1), $10);
                  // lseek(fd, 0, SEEK_END=2)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0] = fd
                  WriteMovRegImm64(FCode, RSI, 0);
                  WriteMovRegImm64(FCode, RDX, 2);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_LSEEK, SYS_MACOS_LSEEK)));
                  WriteSyscall(FCode);
                  // save size at [rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov [rsp+8],rax
                  // close(fd)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_CLOSE, SYS_MACOS_CLOSE)));
                  WriteSyscall(FCode);
                  // return size
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rax,[rsp+8]
                  // patch jmp done
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'HashNew' then
              begin
                // HashNew(cap: int64): pchar (raw base ptr)
                // Layout: [count:8][mask:8][entries: cap*24]
                // Round cap up to next power of 2, min 8.
                // mmap(0, 16+cap*24, 3, 0x22, -1, 0) → base
                // [base+0]=0 (count), [base+8]=cap-1 (mask)
                // return base
                if Length(instr.ArgTemps) >= 1 then
                begin
                  // sub rsp, 16
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $10);
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));  // rax = cap
                  // ensure cap >= 8
                  // cmp rax, 8; jge cap_ok
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $F8); EmitU8(FCode, $08);  // cmp rax,8
                  EmitU8(FCode, $7D); EmitU8(FCode, $07);  // jge +7 (skip 7-byte mov rax,8)
                  // mov rax, 8
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0); EmitU8(FCode, $08); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
                  // cap_ok: round up to next power of 2 using bit-scan trick
                  // if already power of 2, leave as is. Use: cap = 1 << bsr(cap-1)+1 if cap>1, else 1
                  // Simpler: loop: if (rax & (rax-1)) == 0 it's power of 2; else rax = rax<<1 & ~(rax-1)... complex
                  // Use bsr: bsr rcx, rax; rcx = floor(log2(rax)); pow2 = 1<<(rcx+1) if (rax & (rax-1)) != 0
                  // test rax, rax-1: (rax-1 in rcx)
                  WriteMovRegReg(FCode, RCX, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C9);  // dec rcx
                  // test rax, rcx (48 85 C8)
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C8);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // jz already_pow2 (patch)
                  leaPos := FCode.Size - 1;
                  // not power of 2: bsr rcx, rax (0F BD C8); then rax = 2 << rcx
                  EmitU8(FCode, $0F); EmitU8(FCode, $BD); EmitU8(FCode, $C8);  // bsr rcx, rax
                  // rax = 1; shl rax, cl+1
                  WriteMovRegImm64(FCode, RAX, 1);
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc rcx (so shift = log2+1)
                  EmitU8(FCode, $48); EmitU8(FCode, $D3); EmitU8(FCode, $E0);  // shl rax, cl
                  // already_pow2:
                  FCode.PatchU8(leaPos, Byte(FCode.Size - (leaPos + 1)));
                  // rax = cap (power of 2). Save at [rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  // mmap size = rax*24 + 16
                  // rsi = rax*24+16: imul rcx,rax,24 (48 6B C8 18); lea rsi,[rcx+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $C8); EmitU8(FCode, $18);  // imul rcx,rax,24
                  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $71); EmitU8(FCode, $10);  // lea rsi,[rcx+16]
                  WriteMovRegImm64(FCode, RDI, 0);
                  WriteMovRegImm64(FCode, RDX, 3);
                  WriteMovRegImm64(FCode, R10, $22);
                  WriteMovRegImm64(FCode, R8, UInt64(-1));
                  WriteMovRegImm64(FCode, R9, 0);
                  WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
                  WriteSyscall(FCode);
                  // rax = base
                  // [base+0] = 0 (count) - mmap returns zeroed memory on Linux, but write anyway
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $00); EmitU32(FCode, 0);  // mov qword [rax], 0 (only 32-bit imm, fine for 0)
                  // [base+8] = cap-1 (mask) = [rsp+0]-1
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0C); EmitU8(FCode, $24);  // mov rcx,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C9);  // dec rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, $08);  // mov [rax+8],rcx
                  // restore stack, return rax (base)
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'HashSet' then
              begin
                // HashSet(map: pchar, key: pchar, val: int64): void
                // FNV-1a hash key, find slot, write [hash,key_ptr,val]
                if Length(instr.ArgTemps) >= 3 then
                begin
                  // sub rsp, 32
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $20);
                  // save map at [rsp+0], key at [rsp+8], val at [rsp+16]
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  slotIdx := fn.LocalCount + instr.ArgTemps[2];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // FNV-1a hash of key: rsi=key=[rsp+8], rcx=0, rax=0x811C9DC5
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  WriteMovRegImm64(FCode, RCX, 0);
                  WriteMovRegImm64(FCode, RAX, $811C9DC5);
                  // fnv loop:
                  leaPos := FCode.Size;
                  // movzx rdx, byte [rsi+rcx]: 0F B6 14 0E
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0E);
                  // test rdx, rdx: jz done_hash
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $D2);
                  EmitU8(FCode, $74); EmitU8(FCode, $0F);  // jz +15 (skip xor 3B+imul 7B+inc 3B+jmp 2B)
                  // xor rax, rdx (48 31 D0)
                  EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $D0);
                  // imul rax, rax, 0x01000193 (48 69 C0 93 01 00 01)
                  EmitU8(FCode, $48); EmitU8(FCode, $69); EmitU8(FCode, $C0); EmitU8(FCode, $93); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $01);
                  // Wait: 0x01000193 = 16777619. As little-endian 32-bit: 93 01 00 01. That's correct.
                  // inc rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  // jmp fnv loop
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // done_hash: rax = hash
                  // if hash == 0: hash = 1
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test rax,rax
                  EmitU8(FCode, $75); EmitU8(FCode, $05);  // jnz +5
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
                  // Wait: mov rax,1 = 48 C7 C0 01 00 00 00 (7 bytes). jnz +5 jumps over 5 bytes but mov is 7 bytes!
                  // Fix: jnz +7
                  // Already emitted jnz +5. Need to patch: go back and fix.
                  FCode.PatchU8(FCode.Size - 7 - 1, $07);  // patch jnz offset to 7
                  // save hash at [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);
                  // mask = [map+8]: map=[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $57); EmitU8(FCode, $08);  // mov rdx,[rdi+8]
                  // slot = hash & mask: rcx = rax & rdx
                  WriteMovRegReg(FCode, RCX, RAX);
                  // and rcx, rdx (48 21 D1)
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  // probe loop: entry_addr = map+16 + slot*24
                  // slot in rcx. entry = rdi+16 + rcx*24
                  // imul rsi, rcx, 24  (48 6B F1 18)
                  // probe_loop:
                  leaPos := FCode.Size;  // probe loop start
                  EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $F1); EmitU8(FCode, $18);  // imul rsi,rcx,24
                  // entry_hash = [rdi+16+rsi] (= [map+16+slot*24])
                  // add rsi, 16 → entry base address = rdi+rsi
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);  // add rsi,16
                  // rax8 = entry_hash = [rdi+rsi]: REX.W, ModRM SIB
                  // mov r8, [rdi+rsi]: 4A 8B 04 37  (REX=4A: W=1,R=1 for r8,X=0,B=0; ModRM=04 SIB; SIB=37: scale=0,index=rsi=110,base=rdi=111)
                  // REX: 0100 W R X B = 0100 1 1 0 0 = 0x4C. Reg=r8=0(with R=1 → 1000), rm=SIB
                  // Actually: mov r8, [rdi+rsi*1]: REX.W=1, REX.R=1(r8), REX.X=0(rsi=low), REX.B=0(rdi=low)
                  // REX = 01001100 = 0x4C
                  // ModRM: Mod=00, Reg=r8(000), RM=100(SIB) → 00 000 100 = 0x04
                  // SIB: Scale=00, Index=rsi(110), Base=rdi(111) → 00 110 111 = 0x37
                  EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $37);  // mov r8,[rdi+rsi]
                  // if entry_hash == 0 (empty): write and done
                  // test r8,r8: 4D 85 C0
                  EmitU8(FCode, $4D); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // jz write_slot (patch)
                  arg3 := FCode.Size - 1;
                  // if entry_hash == hash: write (update)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov rax,[rsp+24] (hash)
                  // cmp r8, rax: 4C 39 C0
                  EmitU8(FCode, $4C); EmitU8(FCode, $39); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // je write_slot (patch)
                  arg4 := FCode.Size - 1;
                  // else: slot = (slot+1) & mask; loop
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc rcx
                  // and rcx, rdx (48 21 D1) -- mask still in rdx
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  // jmp probe_loop
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // write_slot: patch jz and je
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  // entry address = rdi+rsi (rdi=map, rsi=16+slot*24)
                  // write hash: [rdi+rsi] = rax (hash from [rsp+24])
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // mov rax,[rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $37);  // mov [rdi+rsi],rax
                  // write key_ptr: [rdi+rsi+8] = key=[rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rax,[rsp+8]
                  // mov [rdi+rsi+8]: need SIB + disp8
                  // 48 89 44 37 08: REX.W, MOV [rdi+rsi*1+8], rax
                  // ModRM: Mod=01(disp8), Reg=rax(000), RM=100(SIB) → 01 000 100 = 0x44
                  // SIB: 0 110 111 = 0x37
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $37); EmitU8(FCode, $08);
                  // write val: [rdi+rsi+16] = [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16]
                  // mov [rdi+rsi+16]: 48 89 44 37 10
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $37); EmitU8(FCode, $10);
                  // if new entry (r8==0), increment count: [map+0]++
                  // We need to know if it was empty (r8==0). We need r8 still. But we may have clobbered it.
                  // r8 is still valid (we didn't write to it since reading). Check r8==0 was the first branch.
                  // But we jumped here from BOTH jz (empty) and je (same hash). For je, r8!=0 (existing), no count inc.
                  // For jz, r8==0 (new), increment count.
                  // Solution: test r8,r8 again and conditionally inc
                  EmitU8(FCode, $4D); EmitU8(FCode, $85); EmitU8(FCode, $C0);  // test r8,r8
                  EmitU8(FCode, $75); EmitU8(FCode, $06);  // jnz skip_inc (6 bytes)
                  // inc qword [rdi]: 48 FF 07
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $07);
                  // After the inc, we fall through to add rsp,32. jnz +3 skips the 3-byte inc.
                  // Patch: test(3B)+jnz(2B)+inc(3B)=8B from test start. jnz offset at S+4.
                  // FCode.Size - 3 - 1 = FCode.Size - 4 = jnz offset byte position.
                  FCode.PatchU8(FCode.Size - 3 - 1, $03);  // patch jnz offset to 03 (skip 3-byte inc)
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $20);
                end;
              end
              else if instr.ImmStr = 'HashGet' then
              begin
                // HashGet(map: pchar, key: pchar): int64
                // Returns value or 0 if not found.
                if Length(instr.ArgTemps) >= 2 then
                begin
                  // sub rsp, 16
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $10);
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);  // mov [rsp+0],rax (map)
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov [rsp+8],rax (key)
                  // FNV-1a hash of key
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  WriteMovRegImm64(FCode, RCX, 0);
                  WriteMovRegImm64(FCode, RAX, $811C9DC5);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0E);
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $D2);
                  EmitU8(FCode, $74); EmitU8(FCode, $0F);  // jz +15 (skip xor 3B+imul 7B+inc 3B+jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $D0);
                  EmitU8(FCode, $48); EmitU8(FCode, $69); EmitU8(FCode, $C0); EmitU8(FCode, $93); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $01);
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // if hash==0: hash=1
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $75); EmitU8(FCode, $07);
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
                  // rax=hash, rdi=map=[rsp+0]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0]
                  // rdx = mask = [rdi+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $57); EmitU8(FCode, $08);
                  // rcx = slot = rax & rdx
                  WriteMovRegReg(FCode, RCX, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  // probe loop
                  leaPos := FCode.Size;
                  EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $F1); EmitU8(FCode, $18);  // imul rsi,rcx,24
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);  // add rsi,16
                  // entry_hash = [rdi+rsi]: 4C 8B 04 37 → r8
                  EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $37);
                  // if r8==0: not found, return 0
                  EmitU8(FCode, $4D); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // jz not_found (patch)
                  arg3 := FCode.Size - 1;
                  // if r8==rax (hash match): return [rdi+rsi+16]
                  EmitU8(FCode, $4C); EmitU8(FCode, $39); EmitU8(FCode, $C0);  // cmp r8,rax
                  EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne try_next (patch)
                  arg4 := FCode.Size - 1;
                  // found: rax = [rdi+rsi+16] (48 8B 44 37 10)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $37); EmitU8(FCode, $10);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);  // jmp done (patch)
                  leaCodePos := FCode.Size - 1;
                  // try_next:
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  // slot = (slot+1) & mask
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // not_found:
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  WriteMovRegImm64(FCode, RAX, 0);
                  // done:
                  FCode.PatchU8(leaCodePos, Byte(FCode.Size - (leaCodePos + 1)));
                  // restore stack
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'HashHas' then
              begin
                // HashHas(map: pchar, key: pchar): bool (0 or 1)
                if Length(instr.ArgTemps) >= 2 then
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $10);
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  // FNV-1a
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  WriteMovRegImm64(FCode, RCX, 0);
                  WriteMovRegImm64(FCode, RAX, $811C9DC5);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0E);
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $D2);
                  EmitU8(FCode, $74); EmitU8(FCode, $0F);  // jz +15 (skip xor 3B+imul 7B+inc 3B+jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $D0);
                  EmitU8(FCode, $48); EmitU8(FCode, $69); EmitU8(FCode, $C0); EmitU8(FCode, $93); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $01);
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $75); EmitU8(FCode, $07);
                  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $57); EmitU8(FCode, $08);
                  WriteMovRegReg(FCode, RCX, RAX);
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $F1); EmitU8(FCode, $18);
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C6); EmitU8(FCode, $10);
                  EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $37);
                  EmitU8(FCode, $4D); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);
                  arg3 := FCode.Size - 1;  // jz not_found
                  EmitU8(FCode, $4C); EmitU8(FCode, $39); EmitU8(FCode, $C0);
                  EmitU8(FCode, $75); EmitU8(FCode, $00);
                  arg4 := FCode.Size - 1;  // jne try_next
                  // found: rax = 1
                  WriteMovRegImm64(FCode, RAX, 1);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  leaCodePos := FCode.Size - 1;  // jmp done
                  // try_next:
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $48); EmitU8(FCode, $21); EmitU8(FCode, $D1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // not_found:
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  WriteMovRegImm64(FCode, RAX, 0);
                  // done:
                  FCode.PatchU8(leaCodePos, Byte(FCode.Size - (leaCodePos + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'GetArgC' then
              begin
                // GetArgC(): int64 — returns argc from saved RSP at program start
                // lea r10, [rip + _lyx_argv_base]
                leaPos := FCode.Size;
                EmitU8(FCode, $4D); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
                SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
                FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := argvBaseIdx;
                FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
                // mov r10, [r10]  (4D 8B 12)
                EmitU8(FCode, $4D); EmitU8(FCode, $8B); EmitU8(FCode, $12);
                // mov rax, [r10]  (49 8B 02)
                EmitU8(FCode, $49); EmitU8(FCode, $8B); EmitU8(FCode, $02);
                if instr.Dest >= 0 then
                begin
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                end;
              end
              else if instr.ImmStr = 'GetArg' then
              begin
                // GetArg(idx: int64): pchar — returns argv[idx] (pointer to C string)
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RCX, RBP, SlotOffset(slotIdx));  // rcx = idx
                  // lea r10, [rip + _lyx_argv_base]
                  leaPos := FCode.Size;
                  EmitU8(FCode, $4D); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
                  SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := argvBaseIdx;
                  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
                  // mov r10, [r10]  (4D 8B 12)
                  EmitU8(FCode, $4D); EmitU8(FCode, $8B); EmitU8(FCode, $12);
                  // rax = argv[idx] = [r10 + 8 + idx*8]
                  // shl rcx, 3 (48 C1 E1 03)
                  EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E1); EmitU8(FCode, $03);
                  // add rcx, 8 (48 83 C1 08)
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $08);
                  // mov rax, [r10+rcx]: REX=0x49,opcode=8B,ModRM=04(SIB),SIB=0A
                  EmitU8(FCode, $49); EmitU8(FCode, $8B); EmitU8(FCode, $04); EmitU8(FCode, $0A);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrStartsWith' then
              begin
                // StrStartsWith(s: pchar, prefix: pchar): bool
                if Length(instr.ArgTemps) >= 2 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = s
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // rsi = prefix
                  WriteMovRegImm64(FCode, RCX, 0);  // rcx = index
                  // compare loop:
                  leaPos := FCode.Size;
                  // movzx rax, byte[rsi+rcx] (prefix char)
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);
                  // test rax, rax: jz found (prefix ended = match)
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);
                  arg3 := FCode.Size - 1;  // jz found
                  // movzx rdx, byte[rdi+rcx] (s char)
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0F);
                  // cmp rax, rdx
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $D0);
                  EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne not_found (patch)
                  arg4 := FCode.Size - 1;
                  // inc rcx
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // found (match):
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  WriteMovRegImm64(FCode, RAX, 1);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  leaCodePos := FCode.Size - 1;  // jmp done
                  // not_found:
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  WriteMovRegImm64(FCode, RAX, 0);
                  // done:
                  FCode.PatchU8(leaCodePos, Byte(FCode.Size - (leaCodePos + 1)));
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrEndsWith' then
              begin
                // StrEndsWith(s: pchar, suffix: pchar): bool
                if Length(instr.ArgTemps) >= 2 then
                begin
                  // sub rsp, 32
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $20);
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);  // [rsp+0]=s
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);  // [rsp+8]=suffix
                  // strlen(s) → rdi; strlen(suffix) → rsi
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $34); EmitU8(FCode, $24);  // mov rsi,[rsp+0]
                  WriteMovRegImm64(FCode, RCX, 0);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz done_s (skip inc 3B + jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // rcx = len_s. Save at [rsp+16]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $10);
                  // strlen(suffix)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);  // mov rsi,[rsp+8]
                  WriteMovRegImm64(FCode, RCX, 0);
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $05);  // jz done_suffix (skip inc 3B + jmp 2B)
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // rcx = len_suffix. Save at [rsp+24]
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $4C); EmitU8(FCode, $24); EmitU8(FCode, $18);
                  // if len_suffix > len_s: return 0
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16] (len_s)
                  // cmp rcx, rax (len_suffix vs len_s) (48 39 C1)
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $C1);
                  EmitU8(FCode, $76); EmitU8(FCode, $00);  // jbe ok (if len_suffix <= len_s) (patch)
                  arg3 := FCode.Size - 1;
                  // return 0
                  WriteMovRegImm64(FCode, RAX, 0);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  arg4 := FCode.Size - 1;  // jmp done
                  // ok:
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  // compare s+(len_s-len_suffix) with suffix
                  // rdi = s + (len_s - len_suffix)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);  // mov rdi,[rsp+0] (s)
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $10);  // mov rax,[rsp+16] (len_s)
                  EmitU8(FCode, $48); EmitU8(FCode, $2B); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $18);  // sub rax,[rsp+24] (len_suffix)
                  // add rdi, rax (rdi = s + (len_s - len_suffix))
                  EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C7);
                  // rsi = suffix = [rsp+8]
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);
                  WriteMovRegImm64(FCode, RCX, 0);
                  // compare loop
                  leaPos := FCode.Size;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0E);  // movzx rax,byte[rsi+rcx]
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // jz found
                  leaCodePos := FCode.Size - 1;
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0F);  // movzx rdx,byte[rdi+rcx]
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $D0);  // cmp rax,rdx
                  EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne no_match (patch)
                  vmtIdx := FCode.Size - 1;
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // no_match:
                  FCode.PatchU8(vmtIdx, Byte(FCode.Size - (vmtIdx + 1)));
                  WriteMovRegImm64(FCode, RAX, 0);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  methodIdx := FCode.Size - 1;  // jmp done
                  // found:
                  FCode.PatchU8(leaCodePos, Byte(FCode.Size - (leaCodePos + 1)));
                  WriteMovRegImm64(FCode, RAX, 1);
                  // done:
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  FCode.PatchU8(methodIdx, Byte(FCode.Size - (methodIdx + 1)));
                  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $20);
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end
              else if instr.ImmStr = 'StrEquals' then
              begin
                // StrEquals(a: pchar, b: pchar): bool
                if Length(instr.ArgTemps) >= 2 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));  // rdi = a
                  slotIdx := fn.LocalCount + instr.ArgTemps[1];
                  WriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));  // rsi = b
                  WriteMovRegImm64(FCode, RCX, 0);
                  // compare loop
                  leaPos := FCode.Size;
                  // movzx rax, byte[rdi+rcx]
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0F);
                  // movzx rdx, byte[rsi+rcx]
                  EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $14); EmitU8(FCode, $0E);
                  // cmp rax, rdx
                  EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $D0);
                  EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne not_equal (patch)
                  arg3 := FCode.Size - 1;
                  // test rax, rax: jz both_null = equal
                  EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
                  EmitU8(FCode, $74); EmitU8(FCode, $00);  // jz equal (patch)
                  arg4 := FCode.Size - 1;
                  // inc rcx, loop
                  EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
                  EmitU8(FCode, $EB); EmitU8(FCode, Byte(leaPos - (FCode.Size + 1)));
                  // not_equal:
                  FCode.PatchU8(arg3, Byte(FCode.Size - (arg3 + 1)));
                  WriteMovRegImm64(FCode, RAX, 0);
                  EmitU8(FCode, $EB); EmitU8(FCode, $00);
                  leaCodePos := FCode.Size - 1;  // jmp done
                  // equal:
                  FCode.PatchU8(arg4, Byte(FCode.Size - (arg4 + 1)));
                  WriteMovRegImm64(FCode, RAX, 1);
                  // done:
                  FCode.PatchU8(leaCodePos, Byte(FCode.Size - (leaCodePos + 1)));
                  if instr.Dest >= 0 then
                  begin
                    slotIdx := fn.LocalCount + instr.Dest;
                    WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
                  end;
                end;
              end;
            end;
         irCall:
           begin
             // User-defined function calls (SysV ABI for Linux x86_64)
             // SysV ABI: First 6 integer args in RDI, RSI, RDX, RCX, R8, R9
             argCount := instr.ImmInt;
             
             // Get argument temps from ArgTemps array or Src1/Src2
             SetLength(argTemps, argCount);
             for k := 0 to argCount - 1 do argTemps[k] := -1;
             if argCount > 0 then argTemps[0] := instr.Src1;
             if argCount > 1 then argTemps[1] := instr.Src2;
             // Additional args from ArgTemps array (newer IR)
             if Length(instr.ArgTemps) > 0 then
             begin
               for k := 0 to Min(argCount - 1, High(instr.ArgTemps)) do
                 argTemps[k] := instr.ArgTemps[k];
             end;
             
             // Ensure stack is 16-byte aligned before call
             // If argCount > 6, we need stack space for extra args
             stackArgsCount := 0;
             if argCount > 6 then
               stackArgsCount := argCount - 6;
             
             // Calculate alignment: (current frame + stack args) must be 16-byte aligned at call
             // Since we push rbp and sub rsp for locals, we may need additional padding
             if (stackArgsCount mod 2) = 1 then
             begin
               // Add 8-byte padding for alignment
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $83);
               EmitU8(FCode, $EC);
               EmitU8(FCode, $08);  // sub rsp, 8
             end;
             
             // Push extra args (beyond 6) in reverse order
             for k := argCount - 1 downto 6 do
             begin
               if argTemps[k] >= 0 then
               begin
                 slotIdx := fn.LocalCount + argTemps[k];
                 WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                 EmitU8(FCode, $50);  // push rax
               end
               else
               begin
                 WriteMovRegImm64(FCode, RAX, 0);
                 EmitU8(FCode, $50);  // push rax
               end;
              end;
              
              // Load first 6 args into registers (SysV ABI: RDI, RSI, RDX, RCX, R8, R9)
              if instr.CallMode = cmStaticLink then
              begin
                // Static link call: RDI = current RBP (parent frame pointer)
                // User args go into RSI, RDX, RCX, R8, R9 (shifted by 1)
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $89); EmitU8(FCode, $EF);  // mov rdi, rbp
                for k := 0 to Min(argCount - 1, 4) do
                begin
                  if argTemps[k] >= 0 then
                  begin
                    slotIdx := fn.LocalCount + argTemps[k];
                    WriteMovRegMem(FCode, ParamRegs[k + 1], RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, ParamRegs[k + 1], 0);
                end;
              end
              else
              begin
                for k := 0 to Min(argCount - 1, 5) do
                begin
                  if argTemps[k] >= 0 then
                  begin
                    slotIdx := fn.LocalCount + argTemps[k];
                    WriteMovRegMem(FCode, ParamRegs[k], RBP, SlotOffset(slotIdx));
                  end
                  else
                    WriteMovRegImm64(FCode, ParamRegs[k], 0);
                end;
              end;
              
               // Handle virtual method calls
              if instr.IsVirtualCall and (instr.VMTIndex >= 0) then
              begin
                // Virtual call: self should be in RDI (first arg for SysV ABI)
                // Use SelfSlot if available, otherwise fall back to loading from temp
                if instr.SelfSlot >= 0 then
                begin
                  // Direct: load self from the original local slot
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(instr.SelfSlot));
                end
                else if argTemps[0] >= 0 then
                begin
                  // Fallback: load self from the temp slot
                  slotIdx := fn.LocalCount + argTemps[0];
                  WriteMovRegMem(FCode, RDI, RBP, SlotOffset(slotIdx));
                end;
                // 1. Load VMT pointer from object: mov rax, [rdi]
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $8B);
                EmitU8(FCode, $07);  // mov rax, [rdi]
                // 2. Load method pointer from VMT table: mov rax, [rax + vmtIndex*8]
                WriteMovRegMem(FCode, RAX, RAX, instr.VMTIndex * 8);
                // 3. Indirect call through the method pointer
                EmitU8(FCode, $FF);
                EmitU8(FCode, $D0);  // call rax
              end
              else
              begin
                // External call via PLT: register symbol and call PLT stub
                if instr.CallMode = cmExternal then
                begin
                  extLibName := module.GetExternLibrary(instr.ImmStr);
                  if extLibName = '' then extLibName := 'libc.so.6';  // fallback
                  AddExternalSymbol(instr.ImmStr, extLibName);
                  // call rel32 to PLT stub (@plt_SymbolName)
                  SetLength(FJumpPatches, Length(FJumpPatches) + 1);
                  FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;
                  FJumpPatches[High(FJumpPatches)].LabelName := '@plt_' + instr.ImmStr;
                  FJumpPatches[High(FJumpPatches)].JmpSize := 4;
                  EmitU8(FCode, $E8);  // call rel32
                  EmitU32(FCode, 0);   // placeholder
                end
                else
                begin
                  // Regular internal call: emit call rel32 with placeholder
                  SetLength(FJumpPatches, Length(FJumpPatches) + 1);
                  FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;
                  FJumpPatches[High(FJumpPatches)].LabelName := instr.ImmStr;
                  FJumpPatches[High(FJumpPatches)].JmpSize := 4;
                  EmitU8(FCode, $E8);  // call rel32
                  EmitU32(FCode, 0);   // placeholder
                end;
              end;
             
             // Clean up stack args if any were pushed
             if stackArgsCount > 0 then
             begin
               // Add back the padding if we added it
               stackCleanup := stackArgsCount * 8;
               if (stackArgsCount mod 2) = 1 then
                 stackCleanup := stackCleanup + 8;  // include padding
               
               if stackCleanup <= 127 then
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $83);
                 EmitU8(FCode, $C4);
                 EmitU8(FCode, Byte(stackCleanup));  // add rsp, imm8
               end
               else
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $81);
                 EmitU8(FCode, $C4);
                 EmitU32(FCode, Cardinal(stackCleanup));  // add rsp, imm32
               end;
             end
             else if (stackArgsCount = 0) and ((argCount mod 2) = 1) and (argCount <= 6) then
             begin
               // If we added alignment padding but no stack args, clean it up
               // Actually, we only add padding when stackArgsCount > 0, so this is not needed
             end;
             
              // Store return value from RAX to destination slot
               if instr.Dest >= 0 then
               begin
                 slotIdx := fn.LocalCount + instr.Dest;
                 WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
               end;
            end;
         
         irVarCall:
           begin
             // Indirect function call via register (SysV ABI for Linux x86_64)
             // Src1 contains the temp index that holds the function pointer
             // This is used for function pointers and virtual method calls
             
             argCount := instr.ImmInt;
             
             // Get argument temps from ArgTemps array or Src1/Src2
             SetLength(argTemps, argCount);
             for k := 0 to argCount - 1 do argTemps[k] := -1;
             if argCount > 0 then argTemps[0] := instr.Src1;
             if argCount > 1 then argTemps[1] := instr.Src2;
             // Additional args from ArgTemps array (newer IR)
             if Length(instr.ArgTemps) > 0 then
             begin
               for k := 0 to Min(argCount - 1, High(instr.ArgTemps)) do
                 argTemps[k] := instr.ArgTemps[k];
             end;
             
             // Ensure stack is 16-byte aligned before call
             stackArgsCount := 0;
             if argCount > 6 then
               stackArgsCount := argCount - 6;
             
             // Calculate alignment
             if (stackArgsCount mod 2) = 1 then
             begin
               // Add 8-byte padding for alignment
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $83);
               EmitU8(FCode, $EC);
               EmitU8(FCode, $08);  // sub rsp, 8
             end;
             
             // Push extra args (beyond 6) in reverse order
             for k := argCount - 1 downto 6 do
             begin
               if argTemps[k] >= 0 then
               begin
                 slotIdx := fn.LocalCount + argTemps[k];
                 WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                 EmitU8(FCode, $50);  // push rax
               end
               else
               begin
                 WriteMovRegImm64(FCode, RAX, 0);
                 EmitU8(FCode, $50);  // push rax
               end;
             end;
             
             // Load first 6 args into registers (SysV ABI: RDI, RSI, RDX, RCX, R8, R9)
             for k := 0 to Min(argCount - 1, 5) do
             begin
               if argTemps[k] >= 0 then
               begin
                 slotIdx := fn.LocalCount + argTemps[k];
                 WriteMovRegMem(FCode, ParamRegs[k], RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, ParamRegs[k], 0);
             end;
             
             // Load function pointer from Src1 temp into RAX
             if instr.Src1 >= 0 then
             begin
               slotIdx := fn.LocalCount + instr.Src1;
               WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
             end
             else
               WriteMovRegImm64(FCode, RAX, 0);
             
             // Indirect call through RAX: call rax
             // Encoding: FF /2 = call r/m64
             // With REX.W prefix: 48 FF D0 = call rax
             EmitU8(FCode, $FF);  // opcode
             EmitU8(FCode, $D0);  // ModR/M: reg=2 (call), mod=11 (register), r/m=000 (rax)
             
             // Clean up stack args if any were pushed
             if stackArgsCount > 0 then
             begin
               stackCleanup := stackArgsCount * 8;
               if (stackArgsCount mod 2) = 1 then
                 stackCleanup := stackCleanup + 8;  // include padding
               
               if stackCleanup <= 127 then
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $83);
                 EmitU8(FCode, $C4);
                 EmitU8(FCode, Byte(stackCleanup));  // add rsp, imm8
               end
               else
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $81);
                 EmitU8(FCode, $C4);
                 EmitU32(FCode, Cardinal(stackCleanup));  // add rsp, imm32
               end;
             end;
             
             // Store return value from RAX to destination slot
             if instr.Dest >= 0 then
             begin
               slotIdx := fn.LocalCount + instr.Dest;
               WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
             end;
           end;
          
          irCallStruct:
           begin
             // Struct-returning function call (SysV ABI)
             // Dest is a LOCAL slot index (not temp!), StructSize gives size in bytes
             // SysV ABI:
             //   - Structs ≤16 Bytes: returned in RAX:RDX
             //   - Structs >16 Bytes: caller passes hidden pointer in RDI, callee writes there
             argCount := instr.ImmInt;
             numSlots := (instr.StructSize + 7) div 8;
             
             // Get argument temps from ArgTemps array
             SetLength(argTemps, argCount);
             for k := 0 to argCount - 1 do argTemps[k] := -1;
             if Length(instr.ArgTemps) > 0 then
             begin
               for k := 0 to Min(argCount - 1, High(instr.ArgTemps)) do
                 argTemps[k] := instr.ArgTemps[k];
             end;
             
             // For large structs, we need to pass sret pointer as first argument
             // This shifts all other arguments by one register
             if instr.StructSize > 16 then
             begin
               // Large struct: use sret ABI
               // Ensure stack is 16-byte aligned before call
               stackArgsCount := 0;
               if argCount + 1 > 6 then  // +1 for hidden sret pointer
                 stackArgsCount := argCount + 1 - 6;
               
               if (stackArgsCount mod 2) = 1 then
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $83);
                 EmitU8(FCode, $EC);
                 EmitU8(FCode, $08);  // sub rsp, 8
               end;
               
               // Push extra args (beyond 5 now, since RDI is used for sret) in reverse order
               for k := argCount - 1 downto 5 do
               begin
                 if argTemps[k] >= 0 then
                 begin
                   slotIdx := fn.LocalCount + argTemps[k];
                   WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                   EmitU8(FCode, $50);  // push rax
                 end
                 else
                 begin
                   WriteMovRegImm64(FCode, RAX, 0);
                   EmitU8(FCode, $50);  // push rax
                 end;
               end;
               
               // Load sret pointer into RDI (address of destination struct)
               // lea rdi, [rbp + SlotOffset(instr.Dest)]
               if (SlotOffset(instr.Dest) >= -128) and (SlotOffset(instr.Dest) <= 127) then
               begin
                 EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $7D);
                 EmitU8(FCode, Byte(SlotOffset(instr.Dest)));
               end
               else
               begin
                 EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $BD);
                 EmitU32(FCode, Cardinal(SlotOffset(instr.Dest)));
               end;
               
               // Load args into RSI, RDX, RCX, R8, R9 (shifted by 1)
               for k := 0 to Min(argCount - 1, 4) do
               begin
                 if argTemps[k] >= 0 then
                 begin
                   slotIdx := fn.LocalCount + argTemps[k];
                   WriteMovRegMem(FCode, ParamRegs[k + 1], RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, ParamRegs[k + 1], 0);
               end;
             end
             else
             begin
               // Small struct (≤16 bytes): standard ABI
               stackArgsCount := 0;
               if argCount > 6 then
                 stackArgsCount := argCount - 6;
               
               if (stackArgsCount mod 2) = 1 then
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $83);
                 EmitU8(FCode, $EC);
                 EmitU8(FCode, $08);  // sub rsp, 8
               end;
               
               // Push extra args (beyond 6) in reverse order
               for k := argCount - 1 downto 6 do
               begin
                 if argTemps[k] >= 0 then
                 begin
                   slotIdx := fn.LocalCount + argTemps[k];
                   WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
                   EmitU8(FCode, $50);  // push rax
                 end
                 else
                 begin
                   WriteMovRegImm64(FCode, RAX, 0);
                   EmitU8(FCode, $50);  // push rax
                 end;
               end;
               
               // Load first 6 args into registers
               for k := 0 to Min(argCount - 1, 5) do
               begin
                 if argTemps[k] >= 0 then
                 begin
                   slotIdx := fn.LocalCount + argTemps[k];
                   WriteMovRegMem(FCode, ParamRegs[k], RBP, SlotOffset(slotIdx));
                 end
                 else
                   WriteMovRegImm64(FCode, ParamRegs[k], 0);
               end;
             end;
             
             // Emit call
             SetLength(FJumpPatches, Length(FJumpPatches) + 1);
             FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;
             FJumpPatches[High(FJumpPatches)].LabelName := instr.ImmStr;
             FJumpPatches[High(FJumpPatches)].JmpSize := 4;
             EmitU8(FCode, $E8);  // call rel32
             EmitU32(FCode, 0);   // placeholder
             
             // Clean up stack args if any
             if stackArgsCount > 0 then
             begin
               stackCleanup := stackArgsCount * 8;
               if (stackArgsCount mod 2) = 1 then
                 stackCleanup := stackCleanup + 8;
               
               if stackCleanup <= 127 then
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $83);
                 EmitU8(FCode, $C4);
                 EmitU8(FCode, Byte(stackCleanup));
               end
               else
               begin
                 EmitRex(FCode, 1, 0, 0, 0);
                 EmitU8(FCode, $81);
                 EmitU8(FCode, $C4);
                 EmitU32(FCode, Cardinal(stackCleanup));
               end;
             end;
             
             // Store return values to local struct slots
             // Dest is a LOCAL slot index (not temp!)
             if instr.Dest >= 0 then
             begin
               if instr.StructSize <= 16 then
               begin
                 // Small struct: copy from RAX:RDX
                 // SysV ABI: RAX = bytes 0-7 (lower half), RDX = bytes 8-15 (upper half)
                 // irLoadStructAddr uses SlotOffset(Dest+1) as the base (lowest address).
                 // So bytes 0-7 must go to the LOWER address slot (Dest+1)
                 // and bytes 8-15 to the HIGHER address slot (Dest).
                 if instr.StructSize > 8 then
                 begin
                   WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest + 1), RAX); // bytes 0-7 at lower addr
                   WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest),     RDX); // bytes 8-15 at higher addr
                 end
                 else
                   WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);
               end;
               // For large structs, data is already written via sret pointer
             end;
           end;
            
          irLabel:
            begin
              // Record label position for branch patching
              FBranchLabels.AddObject(instr.LabelName, TObject(PtrInt(FCode.Size)));
            end;
           
         irJmp:
           begin
             // Unconditional jump to label: jmp rel32
             SetLength(FBranchPatches, Length(FBranchPatches) + 1);
             FBranchPatches[High(FBranchPatches)].Pos := FCode.Size + 1;  // Position after E9 opcode
             FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
             FBranchPatches[High(FBranchPatches)].JmpSize := 4;  // rel32
             EmitU8(FCode, $E9);  // jmp rel32
             EmitU32(FCode, 0);   // placeholder
           end;
           
           irBrTrue:
             begin
               // Jump to label if Src1 != 0
               slotIdx := fn.LocalCount + instr.Src1;
               WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
               
               // test rax, rax
               EmitRex(FCode, 1, 0, 0, 0);
               EmitU8(FCode, $85);
               EmitU8(FCode, $C0);
               
               // jne rel32 (this will be patched later)
               SetLength(FBranchPatches, Length(FBranchPatches) + 1);
               FBranchPatches[High(FBranchPatches)].Pos := FCode.Size + 2;  // Position after 0F 85
               FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
               FBranchPatches[High(FBranchPatches)].JmpSize := 4;
               EmitU8(FCode, $0F);
               EmitU8(FCode, $85);  // jne rel32
               EmitU32(FCode, 0);   // placeholder
             end;
           
         irBrFalse:
           begin
             // Jump to label if Src1 == 0
             slotIdx := fn.LocalCount + instr.Src1;
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
             // test rax, rax
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $85);
             EmitU8(FCode, $C0);
             // je rel32
             SetLength(FBranchPatches, Length(FBranchPatches) + 1);
             FBranchPatches[High(FBranchPatches)].Pos := FCode.Size + 2;  // Position after 0F 84
             FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
             FBranchPatches[High(FBranchPatches)].JmpSize := 4;
             EmitU8(FCode, $0F);
             EmitU8(FCode, $84);  // je rel32
             EmitU32(FCode, 0);   // placeholder
           end;
           
         irCmpEq:
           begin
             // dest = (src1 == src2) ? 1 : 0
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cmp rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $39);
             EmitU8(FCode, $C8);  // cmp rax, rcx
             // sete al
             EmitU8(FCode, $0F);
             EmitU8(FCode, $94);
             EmitU8(FCode, $C0);
             // movzx rax, al
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $B6);
             EmitU8(FCode, $C0);
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irCmpNeq:
           begin
             // dest = (src1 != src2) ? 1 : 0
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cmp rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $39);
             EmitU8(FCode, $C8);
             // setne al
             EmitU8(FCode, $0F);
             EmitU8(FCode, $95);
             EmitU8(FCode, $C0);
             // movzx rax, al
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $B6);
             EmitU8(FCode, $C0);
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irCmpLt:
           begin
             // dest = (src1 < src2) ? 1 : 0 (signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cmp rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $39);
             EmitU8(FCode, $C8);
             // setl al (less than, signed)
             EmitU8(FCode, $0F);
             EmitU8(FCode, $9C);
             EmitU8(FCode, $C0);
             // movzx rax, al
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $B6);
             EmitU8(FCode, $C0);
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irCmpLe:
           begin
             // dest = (src1 <= src2) ? 1 : 0 (signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cmp rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $39);
             EmitU8(FCode, $C8);
             // setle al (less than or equal, signed)
             EmitU8(FCode, $0F);
             EmitU8(FCode, $9E);
             EmitU8(FCode, $C0);
             // movzx rax, al
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $B6);
             EmitU8(FCode, $C0);
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
         irCmpGt:
           begin
             // dest = (src1 > src2) ? 1 : 0 (signed)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
             WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
             // cmp rax, rcx
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $39);
             EmitU8(FCode, $C8);
             // setg al (greater than, signed)
             EmitU8(FCode, $0F);
             EmitU8(FCode, $9F);
             EmitU8(FCode, $C0);
             // movzx rax, al
             EmitRex(FCode, 1, 0, 0, 0);
             EmitU8(FCode, $0F);
             EmitU8(FCode, $B6);
             EmitU8(FCode, $C0);
             WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
           end;
           
          irCmpGe:
            begin
              // dest = (src1 >= src2) ? 1 : 0 (signed)
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // cmp rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $39);
              EmitU8(FCode, $C8);
              // setge al (greater than or equal, signed)
              EmitU8(FCode, $0F);
              EmitU8(FCode, $9D);
              EmitU8(FCode, $C0);
              // movzx rax, al
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $0F);
              EmitU8(FCode, $B6);
              EmitU8(FCode, $C0);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end;
           
          irLoadElem:
            begin
              // Load element: dest = array[index]
              // Src1 = array base address temp, Src2 = index temp, Dest = result
              // For pchar (byte access), we use ImmInt to indicate element size
              // ImmInt = 1 for byte, 8 for int64
              
              // Save RAX (used for computation) via push
              EmitU8(FCode, $50);  // push rax
              
              // Load array base address into RAX
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              // Load index into RCX
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              
              if instr.ImmInt = 1 then
              begin
                // Byte access (pchar): RAX = RAX + RCX, then load byte
                // add rax, rcx
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $01);
                EmitU8(FCode, $C8);  // add rax, rcx
                // movzx rax, byte [rax]
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $0F);
                EmitU8(FCode, $B6);
                EmitU8(FCode, $00);  // movzx rax, byte [rax]
              end
              else
              begin
                // 8-byte access (int64): RAX = RAX + RCX * 8, then load qword
                // shl rcx, 3  (multiply index by 8)
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $C1);
                EmitU8(FCode, $E1);
                EmitU8(FCode, $03);  // shl rcx, 3
                // add rax, rcx
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $01);
                EmitU8(FCode, $C8);  // add rax, rcx
                // mov rax, [rax]
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $8B);
                EmitU8(FCode, $00);  // mov rax, [rax]
              end;
              
              // Store result in destination temp slot
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
              
              // Restore RAX via pop (discard saved value, RAX now holds result)
              EmitU8(FCode, $58);  // pop rax
            end;
           
          irStoreElem:
            begin
              // Store element: array[index] = value
              // Src1 = array base address temp, Src2 = value temp, ImmInt = static index
              offset := instr.ImmInt * 8;  // 8 bytes per element
              
              // Save RAX (used for computation) via push
              EmitU8(FCode, $50);  // push rax
              
              // Load array base address into RAX
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              // Load value into RCX
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              
              // Store value at array[index]: mov [rax + offset], rcx
              if offset = 0 then
              begin
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $89);
                EmitU8(FCode, $08);  // mov [rax], rcx
              end
              else if (offset >= -128) and (offset <= 127) then
              begin
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $89);
                EmitU8(FCode, $48);
                EmitU8(FCode, Byte(offset));  // mov [rax + disp8], rcx
              end
              else
              begin
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $89);
                EmitU8(FCode, $88);
                EmitU32(FCode, Cardinal(offset));  // mov [rax + disp32], rcx
              end;
              
              // Restore RAX via pop
              EmitU8(FCode, $58);  // pop rax
            end;
           
          irStoreElemDyn:
            begin
              // Store element dynamically: array[index] = value
              // Src1 = array base, Src2 = index, Src3 = value
              
              // Save RAX (used for computation) via push
              EmitU8(FCode, $50);  // push rax
              
              // Load array base address into RAX
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              // Load index into RCX
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
              // Load value into RDX
              WriteMovRegMem(FCode, RDX, RBP, SlotOffset(fn.LocalCount + instr.Src3));
              
              // Calculate element address: RAX = RAX + RCX * 8
              // shl rcx, 3
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $C1);
              EmitU8(FCode, $E1);
              EmitU8(FCode, $03);  // shl rcx, 3
              // add rax, rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $01);
              EmitU8(FCode, $C8);  // add rax, rcx
              
              // Store value: mov [rax], rdx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $89);
              EmitU8(FCode, $10);  // mov [rax], rdx
              
              // Restore RAX via pop
              EmitU8(FCode, $58);  // pop rax
            end;

          irLoadField:
            begin
              // Load field from struct: Dest = *(Src1 + ImmInt)
              // Base address now points to the LOWEST address of the struct (via irLoadStructAddr),
              // so we ADD the field offset to get the correct byte address.
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              negOffset := instr.ImmInt; // positive offset from base (lowest address)
              
              // Use FieldSize to determine load width (default to 8 if not set)
              case instr.FieldSize of
                1: begin
                  // movzx ecx, byte [rax + negOffset] (zero-extend to full register)
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
                2: begin
                  // movzx ecx, word [rax + negOffset] (zero-extend to full register)
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B7); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B7); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
                4: begin
                  // mov ecx, dword [rax + negOffset] (implicit zero-extend to 64-bit)
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $8B); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
              else
                // 8 bytes (default): mov rcx, qword [rax + negOffset]
                if (negOffset >= -128) and (negOffset <= 127) then
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                end
                else
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                end;
              end;
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RCX);
            end;

          irStoreField:
            begin
              // Store field into struct: *(Src1 + ImmInt) = Src2
              // Base address now points to the LOWEST address of the struct (via irLoadStructAddr),
              // so we ADD the field offset to get the correct byte address.
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1)); // base addr
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2)); // value
              negOffset := instr.ImmInt; // positive offset from base (lowest address)
              
              // Use FieldSize to determine store width (default to 8 if not set)
              case instr.FieldSize of
                1: begin
                  // mov byte [rax + negOffset], cl
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $88); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $88); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
                2: begin
                  // mov word [rax + negOffset], cx
                  EmitU8(FCode, $66); // operand size prefix
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
                4: begin
                  // mov dword [rax + negOffset], ecx (no REX.W)
                  if (negOffset >= -128) and (negOffset <= 127) then
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                  end
                  else
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                  end;
                end;
              else
                // 8 bytes (default): mov qword [rax + negOffset], rcx
                if (negOffset >= -128) and (negOffset <= 127) then
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(negOffset));
                end
                else
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(negOffset));
                end;
              end;
            end;

          irLoadFieldHeap:
            begin
              // Load field from heap object: Dest = *(Src1 + ImmInt)
              // Positive offset for heap objects
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              
              // Use FieldSize to determine load width (default to 8 if not set)
              case instr.FieldSize of
                1: begin
                  // movzx ecx, byte [rax + offset] (zero-extend to full register)
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
                2: begin
                  // movzx ecx, word [rax + offset] (zero-extend to full register)
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B7); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $0F); EmitU8(FCode, $B7); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
                4: begin
                  // mov ecx, dword [rax + offset] (implicit zero-extend to 64-bit)
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $8B); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
              else
                // 8 bytes (default): mov rcx, qword [rax + offset]
                if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                end
                else
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                end;
              end;
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RCX);
            end;

          irStoreFieldHeap:
            begin
              // Store field into heap object: *(Src1 + ImmInt) = Src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1)); // base addr
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2)); // value
              
              // Use FieldSize to determine store width (default to 8 if not set)
              case instr.FieldSize of
                1: begin
                  // mov byte [rax + offset], cl
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $88); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $88); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
                2: begin
                  // mov word [rax + offset], cx
                  EmitU8(FCode, $66); // operand size prefix
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
                4: begin
                  // mov dword [rax + offset], ecx (no REX.W)
                  if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                  end
                  else
                  begin
                    EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                  end;
                end;
              else
                // 8 bytes (default): mov qword [rax + offset], rcx
                if (instr.ImmInt >= 0) and (instr.ImmInt <= 127) then
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
                end
                else
                begin
                  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $88); EmitU32(FCode, Cardinal(instr.ImmInt));
                end;
              end;
            end;

        irPushHandler:
          begin
            // Inline setjmp: save CPU state to jmpbufs[depth], increment depth,
            // fall through to try body; branch to catch label on longjmp return.
            // Register exception globals if not yet done
            if excDepthIdx < 0 then
            begin
              // _lyx_exc_value (8 bytes)
              excValueIdx := globalVarNames.Count;
              globalVarNames.Add('_lyx_exc_value');
              SetLength(globalVarOffsets, excValueIdx + 1);
              globalVarOffsets[excValueIdx] := 0; // finalized at patching time
              // _lyx_exc_depth (8 bytes)
              excDepthIdx := globalVarNames.Count;
              globalVarNames.Add('_lyx_exc_depth');
              SetLength(globalVarOffsets, excDepthIdx + 1);
              globalVarOffsets[excDepthIdx] := 0;
              // _lyx_exc_jmpbufs (16 × 64 = 1024 bytes)
              excJmpbufsIdx := globalVarNames.Count;
              globalVarNames.Add('_lyx_exc_jmpbufs');
              SetLength(globalVarOffsets, excJmpbufsIdx + 1);
              globalVarOffsets[excJmpbufsIdx] := 0;
            end;

            // --- Emit inline setjmp sequence ---
            // lea rcx, [rip + _lyx_exc_depth]  (48 8D 0D <disp32>)
            leaPos := FCode.Size;
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D); EmitU32(FCode, 0);
            SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excDepthIdx;
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
            // mov rax, [rcx]   (48 8B 01)
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $01);
            // imul rax, rax, 64  (48 6B C0 40)
            EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $C0); EmitU8(FCode, $40);
            // lea rdx, [rip + _lyx_exc_jmpbufs]  (48 8D 15 <disp32>)
            leaPos := FCode.Size;
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
            SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excJmpbufsIdx;
            FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
            // add rdx, rax  (48 01 C2)
            EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C2);
            // Save callee-saved registers + rsp into jmpbuf at [rdx]
            // mov [rdx+0],  rbx  (48 89 1A)
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $1A);
            // mov [rdx+8],  rbp  (48 89 6A 08)
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $6A); EmitU8(FCode, $08);
            // mov [rdx+16], r12  (4C 89 62 10)
            EmitU8(FCode, $4C); EmitU8(FCode, $89); EmitU8(FCode, $62); EmitU8(FCode, $10);
            // mov [rdx+24], r13  (4C 89 6A 18)
            EmitU8(FCode, $4C); EmitU8(FCode, $89); EmitU8(FCode, $6A); EmitU8(FCode, $18);
            // mov [rdx+32], r14  (4C 89 72 20)
            EmitU8(FCode, $4C); EmitU8(FCode, $89); EmitU8(FCode, $72); EmitU8(FCode, $20);
            // mov [rdx+40], r15  (4C 89 7A 28)
            EmitU8(FCode, $4C); EmitU8(FCode, $89); EmitU8(FCode, $7A); EmitU8(FCode, $28);
            // mov [rdx+48], rsp  (48 89 62 30)
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $62); EmitU8(FCode, $30);
            // lea rax, [rip+9] — address of 'test rax,rax' below
            // 9 = size(mov [rdx+56],rax)=4 + size(inc [rcx])=3 + size(xor eax,eax)=2
            EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 9);
            // mov [rdx+56], rax  (48 89 42 38)
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $42); EmitU8(FCode, $38);
            // inc qword ptr [rcx]  (48 FF 01)
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $01);
            // xor eax, eax  (31 C0)  — normal setjmp returns 0
            EmitU8(FCode, $31); EmitU8(FCode, $C0);
            // === longjmp resumes here ===
            // test rax, rax  (48 85 C0)
            EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $C0);
            // jne catch_label  (0F 85 <rel32>)
            SetLength(FBranchPatches, Length(FBranchPatches) + 1);
            FBranchPatches[High(FBranchPatches)].Pos := FCode.Size + 2;
            FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
            FBranchPatches[High(FBranchPatches)].JmpSize := 4;
            EmitU8(FCode, $0F); EmitU8(FCode, $85); EmitU32(FCode, 0);
          end;

        irPopHandler:
          begin
            // Decrement _lyx_exc_depth
            if excDepthIdx >= 0 then
            begin
              // lea rcx, [rip + _lyx_exc_depth]  (48 8D 0D <disp32>)
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D); EmitU32(FCode, 0);
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excDepthIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // dec qword ptr [rcx]  (48 FF 09)
              EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $09);
            end;
          end;

        irLoadHandlerExn:
          begin
            // Load _lyx_exc_value into dest slot
            if excValueIdx >= 0 then
            begin
              // lea rax, [rip + _lyx_exc_value]  (48 8D 05 <disp32>)
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excValueIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // mov rax, [rax]  (48 8B 00)
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $00);
              // store to catch variable's LOCAL slot (instr.Dest is a local index, like irStoreLocal)
              WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);
            end;
          end;

        irThrow:
          begin
            // Store exception value to _lyx_exc_value, then longjmp to active handler
            // Load the exception value from src1 slot
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            if excValueIdx >= 0 then
            begin
              // lea rcx, [rip + _lyx_exc_value]  (48 8D 0D <disp32>)
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D); EmitU32(FCode, 0);
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excValueIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // mov [rcx], rax  (48 89 01)
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $01);
              // Compute jmpbuf address: &jmpbufs[(depth-1)*64]
              // lea rcx, [rip + _lyx_exc_depth]
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $0D); EmitU32(FCode, 0);
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excDepthIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // mov rax, [rcx]  (48 8B 01)
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $01);
              // dec rax  (48 FF C8)
              EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C8);
              // imul rax, rax, 64  (48 6B C0 40)
              EmitU8(FCode, $48); EmitU8(FCode, $6B); EmitU8(FCode, $C0); EmitU8(FCode, $40);
              // lea rdx, [rip + _lyx_exc_jmpbufs]  (48 8D 15 <disp32>)
              leaPos := FCode.Size;
              EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
              SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := excJmpbufsIdx;
              FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
              // add rdx, rax  (48 01 C2)
              EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C2);
              // Restore callee-saved registers + rsp from jmpbuf
              // mov rbx, [rdx+0]   (48 8B 1A)
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $1A);
              // mov rbp, [rdx+8]   (48 8B 6A 08)
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $6A); EmitU8(FCode, $08);
              // mov r12, [rdx+16]  (4C 8B 62 10)
              EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $62); EmitU8(FCode, $10);
              // mov r13, [rdx+24]  (4C 8B 6A 18)
              EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $6A); EmitU8(FCode, $18);
              // mov r14, [rdx+32]  (4C 8B 72 20)
              EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $72); EmitU8(FCode, $20);
              // mov r15, [rdx+40]  (4C 8B 7A 28)
              EmitU8(FCode, $4C); EmitU8(FCode, $8B); EmitU8(FCode, $7A); EmitU8(FCode, $28);
              // mov rsp, [rdx+48]  (48 8B 62 30)
              EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $62); EmitU8(FCode, $30);
              // mov eax, 1  (B8 01 00 00 00)  — longjmp value, zero-extends to rax
              EmitU8(FCode, $B8); EmitU32(FCode, 1);
              // jmp qword ptr [rdx+56]  (FF 62 38)
              EmitU8(FCode, $FF); EmitU8(FCode, $62); EmitU8(FCode, $38);
            end;
          end;

        irPanic:
          begin
            // panic(msg): write msg to stderr and exit(1)
            // Src1 = temp holding the message pointer (PChar)
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            // strlen(rsi) → rcx
            WriteMovRegImm64(FCode, RCX, 0);
            // loop: cmp byte [rsi+rcx], 0
            EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0E); EmitU8(FCode, $00);
            // jz +5 (past inc rcx + jmp)
            EmitU8(FCode, $74); EmitU8(FCode, $05);
            // inc rcx  (48 FF C1)
            EmitRex(FCode, 1, 0, 0, 0); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
            // jmp -11  (EB F5)
            EmitU8(FCode, $EB); EmitU8(FCode, $F5);
            // rdx = rcx (length)
            WriteMovRegReg(FCode, RDX, RCX);
            // write(fd=2, buf=rsi, len=rdx)
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
            WriteMovRegImm64(FCode, RDI, 2);  // stderr
            WriteSyscall(FCode);
            // exit(1)
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_EXIT, SYS_MACOS_EXIT)));
            WriteMovRegImm64(FCode, RDI, 1);
            WriteSyscall(FCode);
          end;

        end;
    end;

    // Sicherstellen, dass die Funktion einen Return hat
    if (Length(fn.Instructions) = 0) or (fn.Instructions[High(fn.Instructions)].Op <> irReturn) then
    begin
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $89);
      EmitU8(FCode, $EC);
      EmitU8(FCode, $5D);
      WriteRet(FCode);
    end;
  end;
  
  // ================================================================
  // PLT-Stubs für externe Symbole generieren (VOR dem Patching!)
  // ================================================================
  if Length(FExternalSymbols) > 0 then
  begin
    // PLT0 (Default Stub, 16 Bytes):
    SetLength(FPLTGOTPatches, Length(FExternalSymbols));
    mainPos := FCode.Size; // PLT0 start
    EmitU8(FCode, $FF); EmitU8(FCode, $35); EmitU32(FCode, 0);  // push qword [rip+0]
    EmitU8(FCode, $FF); EmitU8(FCode, $25); EmitU32(FCode, 0);  // jmp qword [rip+0]
    EmitU8(FCode, $90); EmitU8(FCode, $90); EmitU8(FCode, $90); EmitU8(FCode, $90); // nop

    // PLTn Stubs (je 16 Bytes pro Symbol):
    for i := 0 to High(FExternalSymbols) do
    begin
      FPLTGOTPatches[i].Pos := FCode.Size;
      FPLTGOTPatches[i].SymbolIndex := i;
      FPLTGOTPatches[i].SymbolName := FExternalSymbols[i].Name;

      // jmp qword [rip+disp32] — placeholder
      EmitU8(FCode, $FF); EmitU8(FCode, $25); EmitU32(FCode, 0);

      // push imm32 (Symbol-Index)
      EmitU8(FCode, $68); EmitU32(FCode, Cardinal(i));

      // jmp rel32 zu PLT0
      offset := mainPos - (FCode.Size + 5);
      EmitU8(FCode, $E9); EmitU32(FCode, Cardinal(offset));

      // Label registrieren, damit Calls den PLT-Stub finden
      SetLength(FLabelPositions, Length(FLabelPositions) + 1);
      FLabelPositions[High(FLabelPositions)].Name := '@plt_' + FExternalSymbols[i].Name;
      FLabelPositions[High(FLabelPositions)].Pos := FPLTGOTPatches[i].Pos;
    end;
  end;

  // FJumpPatches auflösen
  for i := 0 to High(FJumpPatches) do
  begin
    labelIdx := -1;
    for j := 0 to High(FLabelPositions) do
    begin
      if FLabelPositions[j].Name = FJumpPatches[i].LabelName then
      begin
        labelIdx := j;
        Break;
      end;
    end;
    
    if labelIdx >= 0 then
    begin
      // Berechne relativen Offset
      // jumpOffset = targetPos - (patchPos + 4)
      // patchPos ist die Position des ersten Bytes nach dem Opcode (E8)
      // targetPos ist die Position des Ziels
      // Wir müssen den Offset vom Ende des 32-Bit-Operands berechnen
      // Das 32-Bit-Operand beginnt bei patchPos
      // Der relative Offset wird vom Ende des 32-Bit-Operands (patchPos + 4) berechnet
      // Also: targetPos - (patchPos + 4)
      // Aber im Code ist FJumpPatches[i].Pos die Position des ersten Bytes nach dem Opcode (E8)
      // Also ist der Operand bei FJumpPatches[i].Pos
      // Der relative Offset ist: targetPos - (FJumpPatches[i].Pos + 4)
      // Da wir einen relativen Sprung von der aktuellen Position (nach dem Operand) zum Ziel berechnen
      // Ist der Offset: targetPos - (currentPos)
      // currentPos = FJumpPatches[i].Pos + 4 (nach dem 32-Bit-Operand)
      // Also: offset = FLabelPositions[labelIdx].Pos - (FJumpPatches[i].Pos + 4)
      // Warte, das ist falsch. Der Opcode E8 erwartet einen relativen Offset vom Ende des Operands.
      // Also: target - (source + 5) wenn source die Position von E8 ist.
      // Aber wir haben FJumpPatches[i].Pos als Position NACH dem Opcode E8 gespeichert.
      // Das bedeutet, FJumpPatches[i].Pos ist die Position des ersten Bytes des Operands.
      // Der relative Offset ist: target - (FJumpPatches[i].Pos + 4)
      // Nein, das ist auch falsch. Der relative Offset ist: target - (source + 5)
      // source ist die Position von E8.
      // Wir haben FJumpPatches[i].Pos als Position NACH E8 gespeichert (also die Position des Operands).
      // Das bedeutet, source = FJumpPatches[i].Pos - 1
      // Also: offset = target - (FJumpPatches[i].Pos - 1 + 5) = target - (FJumpPatches[i].Pos + 4)
      // Korrekt.
      offset := FLabelPositions[labelIdx].Pos - (FJumpPatches[i].Pos + 4);
      FCode.PatchU32LE(FJumpPatches[i].Pos, Cardinal(offset));
    end;
    // Note: If labelIdx < 0, the function was not found. This should not happen
    // if all imported functions (including private ones) are properly loaded.
  end;
  
  // FBranchPatches auflösen (für irJmp, irBrTrue, irBrFalse)
  for i := 0 to High(FBranchPatches) do
  begin
    labelIdx := FBranchLabels.IndexOf(FBranchPatches[i].LabelName);
    if labelIdx >= 0 then
    begin
      // Calculate relative offset: target - (patchPos + 4)
      offset := PtrInt(FBranchLabels.Objects[labelIdx]) - (FBranchPatches[i].Pos + 4);
      FCode.PatchU32LE(FBranchPatches[i].Pos, Cardinal(offset));
    end;
  end;
  
  // ================================================================
  // Generate VMT data for classes with virtual methods
  // This is placed AFTER all functions so the VMT entries can be
  // patched with the actual function addresses.
  // ================================================================
  for i := 0 to High(module.ClassDecls) do
  begin
    if Length(module.ClassDecls[i].VirtualMethods) = 0 then
      Continue;  // Only classes with virtual methods need a VMT
    
    // VMT-Label registrieren (Position im Code-Segment)
    SetLength(FVMTLabels, Length(FVMTLabels) + 1);
    FVMTLabels[High(FVMTLabels)].Name := module.ClassDecls[i].VMTName;
    FVMTLabels[High(FVMTLabels)].Pos := FCode.Size;  // Position in code segment
    
    // Methoden-Pointer in VMT schreiben
    for j := 0 to High(module.ClassDecls[i].VirtualMethods) do
    begin
      // Check if this method has a body (is implemented)
      // TObject's methods (Destroy, Free, ClassName, InheritsFrom) have no body
      method := module.ClassDecls[i].VirtualMethods[j];
      if Assigned(method) and Assigned(method.Body) and (Length(method.Body.Stmts) > 0) then
      begin
        // Method has a body - place placeholder for patching
        FCode.WriteU64LE(0);
      end
      else
      begin
        // Method has no body (e.g., TObject's built-in methods) - use a dummy address
        // We'll patch this later with a "not implemented" function or leave as 0
        // For now, write a marker that we'll fix in the patching phase
        FCode.WriteU64LE($FFFFFFFFFFFFFFFF);  // Marker for unimplemented method
      end;
      
      // Record patch position with VMT and method index
      SetLength(FVMTLeaPositions, Length(FVMTLeaPositions) + 1);
      FVMTLeaPositions[High(FVMTLeaPositions)].VMTIndex := i;  // Index in module.ClassDecls
      FVMTLeaPositions[High(FVMTLeaPositions)].MethodIndex := j;  // Index in VirtualMethods
      FVMTLeaPositions[High(FVMTLeaPositions)].CodePos := FCode.Size - 8;
    end;
  end;
  
  // String LEA patches: Calculate RIP-relative offsets
  // The strings are in the data section, which follows the code section
  // For a static ELF: Data starts at codeOffset + alignUp(codeSize, pageSize)
  // We need to patch LEA instructions to point to correct string addresses
  // 
  // For simplicity, we append strings to the CODE buffer and patch relative addresses
  // This avoids the need for cross-section addressing
  //
  // Alternative: Store string data positions and let ELF writer handle patching
  // For now, we embed strings in code section (less elegant but works)
  
  // Write strings to end of code buffer
  if module.Strings.Count > 0 then
  begin
    // Initialize FStringOffsets array
    SetLength(FStringOffsets, module.Strings.Count);
     
    // Write all strings to code buffer
    for i := 0 to module.Strings.Count - 1 do
    begin
      FStringOffsets[i] := FCode.Size;
      for k := 1 to Length(module.Strings[i]) do
        FCode.WriteU8(Ord(module.Strings[i][k]));
      FCode.WriteU8(0);  // Null-Terminator
    end;
    
    // Now patch all LEA instructions
    for i := 0 to High(FLeaPositions) do
    begin
      // FLeaPositions[i] points to the disp32 in "lea rax, [rip + disp32]"
      // The instruction after disp32 is at FLeaPositions[i] + 4
      // RIP at execution time points to that position
      // So: disp32 = target - (FLeaPositions[i] + 4)
      if (FLeaStrIndex[i] >= 0) and (FLeaStrIndex[i] <= High(FStringOffsets)) then
      begin
        offset := Integer(FStringOffsets[FLeaStrIndex[i]]) - (FLeaPositions[i] + 4);
        FCode.PatchU32LE(FLeaPositions[i], Cardinal(offset));
      end;
    end;
  end;
  
  // Patch global variable LEA instructions
  // Global variables are stored after strings in the code section (embedded like strings)
  if Length(FGlobalVarLeaPositions) > 0 then
  begin
    // Write exception globals to end of code buffer if they were registered
    if excDepthIdx >= 0 then
    begin
      // _lyx_exc_value (8 bytes)
      globalVarOffsets[excValueIdx] := FCode.Size;
      FCode.WriteU64LE(0);
      // _lyx_exc_depth (8 bytes)
      globalVarOffsets[excDepthIdx] := FCode.Size;
      FCode.WriteU64LE(0);
      // _lyx_exc_jmpbufs (16 × 64 = 1024 bytes)
      globalVarOffsets[excJmpbufsIdx] := FCode.Size;
      for k := 0 to 127 do FCode.WriteU64LE(0);
    end;

    // Write global variables to end of code buffer
    for i := 0 to High(module.GlobalVars) do
    begin
      globalVarOffsets[i] := FCode.Size;
      if module.GlobalVars[i].IsArray then
      begin
        // Write array values
        for k := 0 to module.GlobalVars[i].ArrayLen - 1 do
          FCode.WriteU64LE(UInt64(module.GlobalVars[i].InitValues[k]));
      end
      else
      begin
        // Write scalar value
        if module.GlobalVars[i].HasInitValue then
          FCode.WriteU64LE(UInt64(module.GlobalVars[i].InitValue))
        else
          FCode.WriteU64LE(0);
      end;
    end;
    
    // Now patch all global variable LEA instructions
    for i := 0 to High(FGlobalVarLeaPositions) do
    begin
      varIdx := FGlobalVarLeaPositions[i].VarIndex;
      
      if varIdx >= 10000 then
      begin
        // VMT reference - skip for now
      end
      else if varIdx < 0 then
      begin
        // Function reference - varIdx is -funcOffset - 1
        funcOffset := -varIdx - 1;
        // RIP-relative: disp32 = funcOffset - (CodePos + 7)
        // Both offsets are relative to start of code buffer
        offset := funcOffset - (FGlobalVarLeaPositions[i].CodePos + 7);
        FCode.PatchU32LE(FGlobalVarLeaPositions[i].CodePos + 3, Cardinal(offset));
      end
      else if varIdx >= 0 then
      begin
        // Regular or exception global variable - data is embedded in code section
        // RIP-relative: disp32 = targetOffset - (CodePos + 7)
        offset := globalVarOffsets[varIdx] - (FGlobalVarLeaPositions[i].CodePos + 7);
        FCode.PatchU32LE(FGlobalVarLeaPositions[i].CodePos + 3, Cardinal(offset));
      end;
    end;
  end;
  
  // ================================================================
  // Patch VMT entries with actual function addresses
  // Each VMT entry is a 64-bit placeholder that should contain
  // the address of the virtual method.
  // ================================================================
  for i := 0 to High(FVMTLeaPositions) do
  begin
    vmtIdx := FVMTLeaPositions[i].VMTIndex;
    methodIdx := FVMTLeaPositions[i].MethodIndex;
    codePos := FVMTLeaPositions[i].CodePos;

    if (vmtIdx >= 0) and (vmtIdx < Length(module.ClassDecls)) then
    begin
      cd := module.ClassDecls[vmtIdx];
      if (methodIdx >= 0) and (methodIdx < Length(cd.VirtualMethods)) then
      begin
        method := cd.VirtualMethods[methodIdx];
        if Assigned(method) then
        begin
          // Build mangled function name: _L_<ClassName>_<MethodName>
          mangledName := '_L_' + cd.Name + '_' + method.Name;

          // Find function position in FLabelPositions
          funcPos := -1;
          for j := 0 to High(FLabelPositions) do
          begin
            if FLabelPositions[j].Name = mangledName then
            begin
              funcPos := FLabelPositions[j].Pos;
              Break;
            end;
          end;

          if funcPos >= 0 then
          begin
            // Patch the VMT entry with the function address
            FCode.PatchU64LE(codePos, UInt64(funcPos));
          end
          else
          begin
            // Function not found - this is an unimplemented method (e.g., TObject's methods)
            // If the slot is marked as unimplemented ($FFFFFFFFFFFFFFFF), replace with 0
            // For unimplemented methods, we use 0 as placeholder
            // This will cause a crash if called, but that's expected for unimplemented methods
            // Check if this slot should remain as is (for abstract/unimplemented methods)
            // For now, leave as 0 for safety
            FCode.PatchU64LE(codePos, 0);
          end;
        end;
      end;
    end;
  end;
  
  // Patch VMT address LEA instructions
  // These are generated by irLoadGlobalAddr for VMT labels (_vmt_ClassName)
  for i := 0 to High(FVMTAddrLeaPositions) do
  begin
    vmtLabelIdx := FVMTAddrLeaPositions[i].VMTLabelIndex;
    leaCodePos := FVMTAddrLeaPositions[i].CodePos;
    
    if (vmtLabelIdx >= 0) and (vmtLabelIdx < Length(FVMTLabels)) then
    begin
      vmtDataPos := FVMTLabels[vmtLabelIdx].Pos;
      // Calculate RIP-relative offset
      // leaCodePos points to the start of LEA instruction
      // disp32 is at leaCodePos + 3
      // RIP at execution = leaCodePos + 7
      // So: disp32 = vmtDataPos - (leaCodePos + 7)
      offset := vmtDataPos - (leaCodePos + 7);
      FCode.PatchU32LE(leaCodePos + 3, Cardinal(offset));
     end;
  end;

   // Code-Größe für Energy-Stats aktualisieren
  FEnergyStats.CodeSizeBytes := FCode.Size;
  
  finally
    globalVarNames.Free;
  end;
end;

end.
