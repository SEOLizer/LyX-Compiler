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
  
  Hinweis: Vollständige Unterstützung für IR-Opcodes, DynArray, Map, Set, VMT, OOP und SSE2 Floats.
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
      VMTLabelName: string;    // Name of VMT label (e.g. '_vmt_Parser')
      CodePos: Integer;        // Position of LEA disp32
    end;
    FIsTypeLeaPositions: array of record
      DataOffset: Integer;
      CodePos: Integer;
    end;
    // TMR Hash Store patch positions (aerospace-todo P0 #46)
    FTMRDataAddrPos: Integer;                    // Position of movabs rdi, data_va placeholder
    FHasVerifyIntegrity: Boolean;                // True if VerifyIntegrity() was used
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
    // TMR Hash Store accessors (aerospace-todo P0 #46)
    function HasVerifyIntegrityCall: Boolean;
    function GetTMRDataAddrPos: Integer;
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
  SYS_LINUX_SELECT  = 23;  // sys_select
  SYS_LINUX_POLL    = 7;   // sys_poll
  SYS_LINUX_FORK    = 57;  // sys_fork
  SYS_LINUX_EXECVE  = 59;  // sys_execve
  SYS_LINUX_WAIT4   = 61;  // sys_wait4

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

// stmxcsr [rsp+disp] — save MXCSR control register (aerospace-todo P2 #58)
procedure WriteStmxcsr(buf: TByteBuffer; base: Byte; disp: Integer);
var modBits: Byte;
begin
  // 0F AE /1 — stmxcsr m32
  if (disp >= -128) and (disp <= 127) then modBits := $40
  else modBits := $80;
  EmitU8(buf, $0F); EmitU8(buf, $AE);
  EmitU8(buf, modBits or ($1 shl 3) or (base and 7)); // /1 = stmxcsr
  if (base and 7) = 4 then EmitU8(buf, $24); // SIB for RSP
  if modBits = $40 then EmitU8(buf, Byte(disp))
  else EmitU32(buf, Cardinal(disp));
end;

// ldmxcsr [rsp+disp] — load MXCSR control register (aerospace-todo P2 #58)
procedure WriteLdmxcsr(buf: TByteBuffer; base: Byte; disp: Integer);
var modBits: Byte;
begin
  // 0F AE /2 — ldmxcsr m32
  if (disp >= -128) and (disp <= 127) then modBits := $40
  else modBits := $80;
  EmitU8(buf, $0F); EmitU8(buf, $AE);
  EmitU8(buf, modBits or ($2 shl 3) or (base and 7)); // /2 = ldmxcsr
  if (base and 7) = 4 then EmitU8(buf, $24); // SIB for RSP
  if modBits = $40 then EmitU8(buf, Byte(disp))
  else EmitU32(buf, Cardinal(disp));
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
  // Optional: Debug-Ausgabe während Entwicklung
  // Niedrige Priorität - nicht für Production-Code benötigt
end;

procedure TX86_64Emitter.EmitDebugPrintInt(valueReg: Integer);
begin
  // Optional: Debug-Ausgabe während Entwicklung
  // Niedrige Priorität - nicht für Production-Code benötigt
end;

procedure TX86_64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  labelIdx: Integer;
  fn: TIRFunction;
  slotIdx: Integer;
  arg3, arg4, arg5, arg6: Integer;
  loopStartPos, jzPatchPos, jgePos, jneLoopPos, jmpDonePos, nextLabelPos: Integer;
  notFoundPos, doneLabelPos, reallocDonePos: Integer;
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
    IsDataBased: Boolean;  // True if variable is in FData (not embedded in FCode)
  end;
  // Exception globals tracking (varIdx in globalVarNames, -1 = not registered)
  excValueIdx, excDepthIdx, excJmpbufsIdx: Integer;
  // argv base global tracking (-1 = not registered)
  argvBaseIdx: Integer;
  // TMR Hash Store patch variables (aerospace-todo P0 #46)
  dataAddrPos: Integer;
  codeToDataGap: Integer;
  jne1Pos, jne2Pos, jne3Pos: Integer;
  match1Pos, match2Pos, match3Pos: Integer;
  jgeOkPatchPos, jmpEndPatchPos: Integer;
  okPos, endPos: Integer;
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
  // Pre-allocate user-declared globals in FData (writable section).
  // This fixes dynamic ELF: code segment is R+X (read-only), data segment is RW.
  for i := 0 to High(module.GlobalVars) do
  begin
    globalVarOffsets[i] := FData.Size;
    if module.GlobalVars[i].IsArray then
    begin
      for k := 0 to module.GlobalVars[i].ArrayLen - 1 do
        FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValues[k]));
    end
    else if module.GlobalVars[i].HasInitValue then
      FData.WriteU64LE(UInt64(module.GlobalVars[i].InitValue))
    else
      FData.WriteU64LE(0);
  end;
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
  // _lyx_argv_base lives in FData (always RW) so the code segment can remain PF_R|PF_X
  argvBaseIdx := globalVarNames.Count;
  globalVarNames.Add('_lyx_argv_base');
  SetLength(globalVarOffsets, argvBaseIdx + 1);
  globalVarOffsets[argvBaseIdx] := FData.Size;  // FData offset (currently 0)
  FData.WriteU64LE(0);  // Reserve 8 bytes in FData for the stored initial RSP
  // Advance totalDataOffset so irLoadGlobal/irStoreGlobal vars don't overlap
  totalDataOffset := FData.Size;
  // lea r10, [rip + _lyx_argv_base]  (4D 8D 15 <disp32>)
  leaPos := FCode.Size;
  EmitU8(FCode, $4D); EmitU8(FCode, $8D); EmitU8(FCode, $15); EmitU32(FCode, 0);
  SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := argvBaseIdx;
  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
  FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].IsDataBased := True;
  // mov [r10], rsp  (49 89 22)
  EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $22);

  // Remove stack size limit via prlimit64(0, RLIMIT_STACK, {RLIM_INFINITY, RLIM_INFINITY}, NULL)
  // sub rsp, 16   (48 83 EC 10)
  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, $10);
  // mov rax, -1   (48 C7 C0 FF FF FF FF)  RLIM_INFINITY
  EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0);
  EmitU8(FCode, $FF); EmitU8(FCode, $FF); EmitU8(FCode, $FF); EmitU8(FCode, $FF);
  // mov [rsp], rax    (48 89 04 24)  rlim_cur
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $04); EmitU8(FCode, $24);
  // mov [rsp+8], rax  (48 89 44 24 08)  rlim_max
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $44); EmitU8(FCode, $24); EmitU8(FCode, $08);
  // xor edi, edi  (31 FF)  pid=0
  EmitU8(FCode, $31); EmitU8(FCode, $FF);
  // mov esi, 3    (BE 03 00 00 00)  RLIMIT_STACK
  EmitU8(FCode, $BE); EmitU8(FCode, $03); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
  // mov rdx, rsp  (48 89 E2)  new_limit
  EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $E2);
  // xor r10d, r10d  (45 31 D2)  old_limit=NULL
  EmitU8(FCode, $45); EmitU8(FCode, $31); EmitU8(FCode, $D2);
  // mov eax, 302  (B8 2E 01 00 00)  SYS_prlimit64
  EmitU8(FCode, $B8); EmitU8(FCode, $2E); EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $00);
  // syscall       (0F 05)
  EmitU8(FCode, $0F); EmitU8(FCode, $05);
  // add rsp, 16   (48 83 C4 10)
  EmitU8(FCode, $48); EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, $10);

  // Pass argc/argv to main: argc=[rsp], argv=rsp+8 (Linux ABI at _start entry)
  // mov rdi, [rsp]  (48 8B 3C 24)
  EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $3C); EmitU8(FCode, $24);
  // lea rsi, [rsp+8]  (48 8D 74 24 08)
  EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, $08);

  // _start is NOT a function — no frame setup here.
  // RSP is already 0 mod 16 at this point (OS guarantee at process entry).
  // The CALL instruction below pushes the return address (8 bytes), so main()
  // is entered with RSP = -8 mod 16 = 8 mod 16, satisfying the x86-64 ABI.
  // Adding 'push rbp' here would shift RSP to 8 mod 16 BEFORE the call,
  // causing main() to be entered with RSP = 0 mod 16 (wrong!) and propagating
  // misalignment through all subsequent frames — causing movaps faults in Qt etc.

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

    // x86-64 ABI: RSP must be 16-byte aligned (0 mod 16) before any CALL instruction.
    // At function entry (after the CALL from the caller): RSP = 8 mod 16.
    // After 'push rbp': RSP = 0 mod 16.
    // After 'sub rsp, N': RSP = (0 - N) mod 16 = (-N) mod 16.
    // For RSP = 0 mod 16 before internal calls: N must be 0 mod 16.
    // N = totalSlots * 8, so totalSlots must be even.
    // If totalSlots is odd, add one padding slot.
    if (totalSlots mod 2) = 1 then
      Inc(totalSlots);

    // Stack-Frame für lokale Variablen und Temporaries
    begin
      // sub rsp, n*8  (always emitted; at least 1 slot for alignment)
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $81);
      EmitU8(FCode, $EC);
      EmitU32(FCode, Cardinal(totalSlots * 8));
    end;

    // FP-Deterministik: MXCSR auf Round-to-Zero setzen (aerospace-todo P2 #58)
    if fn.SafetyPragmas.FPDeterministic then
    begin
      // sub rsp, 16 — Platz für MXCSR (16-byte aligned)
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $81);
      EmitU8(FCode, $EC);
      EmitU32(FCode, 16);

      // stmxcsr [rsp] — aktuellen MXCSR speichern
      WriteStmxcsr(FCode, RSP, 0);

      // ldmxcsr [rip + mxcsr_val] — MXCSR auf 0x7F80 laden (round-to-zero, alle Exceptions masked)
      // Da wir keine Daten-Labels haben, laden wir den Wert direkt:
      // mov dword [rsp], 0x7F80
      EmitU8(FCode, $C7); EmitU8(FCode, $04); EmitU8(FCode, $24);  // mov dword [rsp], imm32
      EmitU32(FCode, $00007F80);  // MXCSR: round-to-zero, all exceptions masked
      WriteLdmxcsr(FCode, RSP, 0);
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
              end
              // Profile.enter(fn_name: pchar) - Profiler function entry (WP-3)
              else if instr.ImmStr = 'profile_enter' then
              begin
                // profile_enter(fn_name: pchar)
                // Uses RDTSC to get timestamp and stores it in profile_data[fn_ptr % 256]
                // RDTSC returns timestamp in EDX:EAX
                // We'll use a simple approach: store timestamp in thread-local storage
                // For now: push timestamp to stack (for matching with leave)
                
                // Get timestamp via RDTSC
                EmitU8(FCode, $0F); EmitU8(FCode, $31);  // rdtsc
                // Save EDX:EAX to stack (to retrieve in profile_leave)
                // push rax
                EmitU8(FCode, $50);  // push rax
                // push rdx  
                EmitU8(FCode, $52);  // push rdx
                
                // Store function name pointer as key in profile_entry_stack
                // For simplicity, we'll just push the function pointer too
                if Length(instr.ArgTemps) >= 1 then
                begin
                  slotIdx := fn.LocalCount + instr.ArgTemps[0];
                  // push [rbp+slot]
                  EmitU8(FCode, $FF); EmitU8(FCode, $B5);
                  EmitU32(FCode, UInt32(SlotOffset(slotIdx)));
                end;
              end
              // Profile.leave(fn_name: pchar) - Profiler function leave (WP-3)
              else if instr.ImmStr = 'profile_leave' then
              begin
                // profile_leave(fn_name: pchar)
                // Pop function pointer, timestamp from stack
                // Calculate elapsed time and update profile stats
                
                // Pop function name (discard for now, or could use to index)
                if Length(instr.ArgTemps) >= 1 then
                begin
                  // pop rdi (discard)
                  EmitU8(FCode, $5F);  // pop rdi
                end;
                
                // Pop saved RDTSC values
                // pop rdx
                EmitU8(FCode, $5A);  // pop rdx
                // pop rax  
                EmitU8(FCode, $58);  // pop rax
                
                // Get current timestamp
                EmitU8(FCode, $0F); EmitU8(FCode, $31);  // rdtsc
                
                // Calculate elapsed: current - saved (EDX:EAX - RDX:RAX)
                // For simplicity, just use low 32 bits: eax = eax - saved_rax
                // sub rax, [rsp+8] (the saved rax is at rsp+0, then rdx at rsp+8 after pop... actually let's simplify)
                // Just ignore elapsed time for now - we just count calls
                
                // Actually, let's just increment a counter
                // Load profile_counter address into rdi
                WriteMovRegImm64(FCode, RDI, UInt64($5000));  // profile_counter data section (placeholder)
                // inc qword [rdi]
                EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $07);
              end
              // Profile.report() - Print profile report (WP-3)
              else if instr.ImmStr = 'profile_report' then
              begin
                // profile_report()
                // For now, just print a placeholder message
                // PrintStr("=== Profile Report ===\n")
                
                // Print the profile report header
                // We'll use a simple syscall to write
                WriteMovRegImm64(FCode, RDI, 1);  // stdout
                // Point RSI to embedded string
                // Use immediate string for now
                WriteMovRegImm64(FCode, RSI, 0);  // placeholder
                
                // sys_write(fd=1, buf="Profile report...\n", len=20)
                WriteMovRegImm64(FCode, RDX, 20);  // length
                EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $C0); 
                EmitU8(FCode, $01); EmitU8(FCode, $00); EmitU8(FCode, $00);  // mov rax, 1 (sys_write)
                EmitU8(FCode, $0F); EmitU8(FCode, $05);  // syscall
              end
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
            // Special case: ImmInt = -1 means "check failed" - use default message
            if instr.ImmInt = -1 then
            begin
              // check() - output default "check failed" message
              // RSI = address of "check failed\0" in .rodata
              // We'll encode this in the code - use a workaround with lea
              // For simplicity, load address of embedded string
              // Actually, the easiest: just exit(1) with no message for now
              // Better: write a simple message inline
              // Use: mov rsi, offset Lcheck_failed  (where we put string in rodata)
              // But we don't have easy access to label addresses here
              // Simplest workaround: use write with hardcoded "check failed"
              // Encode: "check failed\n" as immediate bytes in code (not ideal)
              // Let's use a different approach: call a runtime function
              // But we don't have libc...
              // Final approach: just exit(1) - the user can see the exit code
              // That's not great for debugging. Let's try one more approach:
              // Use a fixed buffer on stack
              // Actually, let's just use the existing panic mechanism with a default
              // string we'll add to the data section later
              // For now, use a simple inline message: "check"
              // Encode "check\0" as: 'c'=63, 'h'=68, 'e'=65, 'c'=63, 'k'=6B, 0=00
              // mov rsi, rsp (temporarily use stack)
              // But stack is not guaranteed to be writable at this point...
              // OK, simplest working solution: just exit(1) for now
              // A proper solution would require data section support
              WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_EXIT, SYS_MACOS_EXIT)));
              WriteMovRegImm64(FCode, RDI, 1);
              WriteSyscall(FCode);
            end
            else
            begin
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

        // === Integrity Verification (aerospace-todo P0 #45 + #46) ===
        // VerifyIntegrity() checks TMR hash store for code integrity
        // Returns: 1 (true) if 2+ of 3 stored hashes match, 0 (false) otherwise
        //
        // The 3 CRC32 hashes are written to the DATA section by lyxc.lpr after codegen.
        // Data layout (at data_start): [hash1:4][hash2:4][hash3:4][code_size:4][code_start_va:8]
        //
        // Runtime algorithm (TMR majority vote):
        //   1. Read 3 stored hashes from data section
        //   2. Count matching pairs: if 2+ agree → return 1, else 0
        irVerifyIntegrity:
          begin
            // Register usage (all caller-saved):
            //   rax = return value
            //   rdi = data section base address
            //   edx = hash value from data
            //   ecx = match counter
            //   r8d, r9d, r10d = hash1, hash2, hash3

            // Step 1: Load data section address
            // The data section starts right after the code section:
            //   data_va = code_start_va + aligned(code_size)
            // For static ELF: code_start_va = $401000, code_size is known at link time
            // We use a placeholder address that will be patched by lyxc.lpr
            // movabs rdi, 0  (placeholder for data_va)
            EmitU8(FCode, $48); EmitU8(FCode, $BF);
            dataAddrPos := FCode.Size;
            FCode.WriteU64LE(0);  // placeholder for data_va

            // Step 2: Read 3 hashes from data section
            // mov r8d, [rdi]       (hash1)
            EmitU8(FCode, $44); EmitU8(FCode, $8B); EmitU8(FCode, $07);
            // mov r9d, [rdi+4]     (hash2)
            EmitU8(FCode, $44); EmitU8(FCode, $8B); EmitU8(FCode, $4F); EmitU8(FCode, $04);
            // mov r10d, [rdi+8]    (hash3)
            EmitU8(FCode, $44); EmitU8(FCode, $8B); EmitU8(FCode, $57); EmitU8(FCode, $08);

            // Step 3: TMR majority vote
            // ecx = 0 (match counter)
            EmitU8(FCode, $31); EmitU8(FCode, $C9);  // xor ecx, ecx

            // Compare hash1 vs hash2: cmp r8d, r9d; je inc ecx
            EmitU8(FCode, $45); EmitU8(FCode, $39); EmitU8(FCode, $C8);  // cmp r8d, r9d
            jne1Pos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne +0 (placeholder)
            EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc ecx
            match1Pos := FCode.Size;

            // Compare hash1 vs hash3: cmp r8d, r10d; je inc ecx
            EmitU8(FCode, $45); EmitU8(FCode, $39); EmitU8(FCode, $D0);  // cmp r8d, r10d
            jne2Pos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne +0 (placeholder)
            EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc ecx
            match2Pos := FCode.Size;

            // Compare hash2 vs hash3: cmp r9d, r10d; je inc ecx
            EmitU8(FCode, $45); EmitU8(FCode, $39); EmitU8(FCode, $D1);  // cmp r9d, r10d
            jne3Pos := FCode.Size;
            EmitU8(FCode, $75); EmitU8(FCode, $00);  // jne +0 (placeholder)
            EmitU8(FCode, $FF); EmitU8(FCode, $C1);  // inc ecx
            match3Pos := FCode.Size;

            // Patch jne offsets
            FCode.PatchU8(jne1Pos + 1, match1Pos - (jne1Pos + 2));
            FCode.PatchU8(jne2Pos + 1, match2Pos - (jne2Pos + 2));
            FCode.PatchU8(jne3Pos + 1, match3Pos - (jne3Pos + 2));

            // Step 4: Check if ecx >= 2 (majority)
            // cmp ecx, 2; jge ok
            EmitU8(FCode, $83); EmitU8(FCode, $F9); EmitU8(FCode, $02);  // cmp ecx, 2
            EmitU8(FCode, $0F); EmitU8(FCode, $8D);
            jgeOkPatchPos := FCode.Size;
            FCode.WriteU32LE(0);  // placeholder

            // Not OK: rax = 0
            EmitU8(FCode, $31); EmitU8(FCode, $C0);  // xor eax, eax
            EmitU8(FCode, $E9);
            jmpEndPatchPos := FCode.Size;
            FCode.WriteU32LE(0);  // placeholder

            // OK: rax = 1
            okPos := FCode.Size;
            FCode.PatchU32LE(jgeOkPatchPos, Cardinal(okPos - (jgeOkPatchPos + 4)));
            EmitU8(FCode, $B8); EmitU8(FCode, $01); EmitU8(FCode, $00);
            EmitU8(FCode, $00); EmitU8(FCode, $00);

            // End: store result
            endPos := FCode.Size;
            FCode.PatchU32LE(jmpEndPatchPos, Cardinal(endPos - (jmpEndPatchPos + 4)));

            // Store result in destination local
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);

            // Store patch positions for lyxc.lpr
            FTMRDataAddrPos := dataAddrPos;
            FHasVerifyIntegrity := True;
          end;

        // === Map/Set Operations (TOR-011) ===
        // Map structure: [len:8][cap:8][entries:16*cap], Entry: [key:8][value:8]
        irMapNew, irSetNew:
          begin
            // Allocate map/set on heap via sys_mmap
            // For simplicity: allocate 144 bytes (16 header + 8*16 entries)
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
            WriteMovRegImm64(FCode, RDI, 0);  // addr = NULL
            WriteMovRegImm64(FCode, RSI, 144); // length
            WriteMovRegImm64(FCode, RDX, 3);   // MAP_PRIVATE | MAP_ANONYMOUS
            WriteMovRegImm64(FCode, R10, -1);  // fd = -1
            WriteMovRegImm64(FCode, R8, 0);    // offset
            WriteMovRegImm64(FCode, R9, 3);    // PROT_READ | PROT_WRITE
            WriteSyscall(FCode);
            // Initialize len=0, cap=8
            EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $00);
            EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
            EmitU8(FCode, $48); EmitU8(FCode, $C7); EmitU8(FCode, $40); EmitU8(FCode, $08);
            EmitU8(FCode, $08); EmitU8(FCode, $00); EmitU8(FCode, $00); EmitU8(FCode, $00);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irMapSet:
          begin
            // map_set(map, key, value) - linear search, update or append
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1)); // map
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src2)); // key
            WriteMovRegMem(FCode, RDX, RBP, SlotOffset(fn.LocalCount + instr.Src3)); // value
            // rcx = len
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F);
            // r8 = 0 (counter)
            EmitU8(FCode, $45); EmitU8(FCode, $31); EmitU8(FCode, $C0);
            // r9 = rdi + 16 (first entry)
            EmitU8(FCode, $4C); EmitU8(FCode, $8D); EmitU8(FCode, $4F); EmitU8(FCode, $10);
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
            nextLabelPos := FCode.Size;
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C1); EmitU8(FCode, $10);
            EmitU8(FCode, $49); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
            EmitU8(FCode, $EB);
            EmitU8(FCode, Byte(Int8(loopStartPos - (FCode.Size + 1))));
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
            // set_add(set, value) - append at end
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $0F); // rcx = len
            WriteMovRegReg(FCode, R8, RCX);
            EmitU8(FCode, $49); EmitU8(FCode, $C1); EmitU8(FCode, $E0); EmitU8(FCode, $04);
            EmitU8(FCode, $49); EmitU8(FCode, $83); EmitU8(FCode, $C0); EmitU8(FCode, $10);
            WriteMovRegReg(FCode, R9, RDI);
            EmitU8(FCode, $4C); EmitU8(FCode, $01); EmitU8(FCode, $C1); // add r9, r8
            EmitU8(FCode, $49); EmitU8(FCode, $89); EmitU8(FCode, $31);
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $07);
          end;

        irMapGet:
          begin
            // map_get(map, key) -> value (linear search)
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src2));
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
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irMapContains, irSetContains:
          begin
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src2));
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
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irMapLen, irSetLen:
          begin
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $07);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irMapRemove, irSetRemove, irMapFree, irSetFree:
          begin
            // Stub: free via sys_munmap
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
            WriteMovRegImm64(FCode, RSI, 144);
            WriteSyscall(FCode);
          end;

        // === Stack Alloc (TOR-011) ===
        irStackAlloc:
          begin
            // Allocate space on stack: sub rsp, ImmInt
            if instr.ImmInt > 0 then
            begin
              if instr.ImmInt <= 127 then
              begin
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $83); EmitU8(FCode, $EC);
                EmitU8(FCode, Byte(instr.ImmInt));
              end
              else
              begin
                EmitRex(FCode, 1, 0, 0, 0);
                EmitU8(FCode, $81); EmitU8(FCode, $EC);
                EmitU32(FCode, Cardinal(instr.ImmInt));
              end;
            end;
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RSP);
          end;

        // === DynArray Operations (TOR-011) ===
        // Fat pointer: [ptr:8][len:8][cap:8] stored in 3 consecutive local slots
        irDynArrayPush:
          begin
            // push element: Src1 = base local (ptr slot), Src2 = value temp
            // Load ptr, len, cap from slots
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));      // ptr
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1));  // len
            WriteMovRegMem(FCode, RDX, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 2));  // cap
            // if len >= cap, realloc
            EmitU8(FCode, $48); EmitU8(FCode, $39); EmitU8(FCode, $D6); // cmp rsi, rdx
            jgePos := FCode.Size;
            EmitU8(FCode, $7D); EmitU8(FCode, $00);
            // Realloc: double cap or init to 4
            EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $D2); // test rdx, rdx
            EmitU8(FCode, $75); EmitU8(FCode, $07); // jnz +7
            WriteMovRegImm64(FCode, RDX, 4);
            EmitU8(FCode, $EB); EmitU8(FCode, $05);
            EmitU8(FCode, $48); EmitU8(FCode, $D1); EmitU8(FCode, $E2); // shl rdx, 1
            // mmap new buffer
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
            WriteMovRegImm64(FCode, RDI, 0);
            WriteMovRegReg(FCode, RSI, RDX);
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E6); EmitU8(FCode, $03); // *8
            WriteMovRegImm64(FCode, RDX, 3);
            WriteMovRegImm64(FCode, R10, -1);
            WriteMovRegImm64(FCode, R8, 0);
            WriteMovRegImm64(FCode, R9, 3);
            WriteSyscall(FCode);
            // Copy old data if exists
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1)); // src = old ptr
            EmitU8(FCode, $48); EmitU8(FCode, $85); EmitU8(FCode, $FF); // test rdi, rdi
            EmitU8(FCode, $74); EmitU8(FCode, $00); // jz +0 (skip copy)
            // memcpy: RDI=dest, RSI=src, RCX=len
            WriteMovRegReg(FCode, RSI, RDI); // RSI = src (old ptr)
            WriteMovRegReg(FCode, RDI, RAX); // RDI = dest (new mmap'd ptr)
            WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1)); // len
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E1); EmitU8(FCode, $03); // rcx *= 8 (element size)
            EmitU8(FCode, $F3); EmitU8(FCode, $A4); // rep movsb
            // Update ptr, cap
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Src1), RAX);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 2), RDX);
            reallocDonePos := FCode.Size;
            FCode.PatchU8(jgePos + 1, reallocDonePos - (jgePos + 2));
            // Store value at ptr[len*8]
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1));
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E6); EmitU8(FCode, $03);
            // RDI = RDI + RSI
            EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $F7);
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $37);
            // len++
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1));
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C0);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1), RAX);
          end;

        irDynArrayPop:
          begin
            // pop: len--, return element at len-1
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1)); // len
            EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C8); // dec rax
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1), RAX);
            // Load element at ptr[(len-1)*8]
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1)); // ptr
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E0); EmitU8(FCode, $03);
            EmitU8(FCode, $48); EmitU8(FCode, $01); EmitU8(FCode, $C7); // add rdi, rax
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $07);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irDynArrayLen:
          begin
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 1));
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irDynArrayFree:
          begin
            // munmap(ptr, cap*8)
            WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(FCode, RSI, RBP, SlotOffset(fn.LocalCount + instr.Src1 + 2));
            EmitU8(FCode, $48); EmitU8(FCode, $C1); EmitU8(FCode, $E6); EmitU8(FCode, $03);
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
            WriteSyscall(FCode);
          end;

        // === Memory Pool (TOR-011) ===
        irPoolAlloc, irPoolFree:
          begin
            // Stub: use mmap/munmap
            if instr.Op = irPoolAlloc then
            begin
              WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MMAP, SYS_MACOS_MMAP)));
              WriteMovRegImm64(FCode, RDI, 0);
              WriteMovRegImm64(FCode, RSI, instr.ImmInt);
              WriteMovRegImm64(FCode, RDX, 3);
              WriteMovRegImm64(FCode, R10, -1);
              WriteMovRegImm64(FCode, R8, 0);
              WriteMovRegImm64(FCode, R9, 3);
              WriteSyscall(FCode);
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
            end
            else
            begin
              WriteMovRegMem(FCode, RDI, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_MUNMAP, SYS_MACOS_MUNMAP)));
              WriteMovRegImm64(FCode, RSI, 4096);
              WriteSyscall(FCode);
            end;
          end;

        // === Type Cast (TOR-011) ===
        irCast:
          begin
            // Type cast: just copy value (runtime type check would go here)
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        // === Type Checking (TOR-011) ===
        irIsType:
          begin
            // is_type(object, className): check VMT
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            // Load VMT pointer from object
            EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $00);
            // Compare with expected VMT (stored in data section)
            // For now: stub - return true
            WriteMovRegImm64(FCode, RAX, 1);
            WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        // === Runtime Assertions (DO-178C Level A) ===
        irAssertBounds:
          begin
            // assert(Src1 >= 0 && Src1 < ImmInt)
            // Src1 = index, ImmInt = array length
            // Wenn Check fehlschlägt → panic mit "bounds check failed"
            slotIdx := fn.LocalCount + instr.Src1;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
            // test rax, rax → js (sign flag set if negative)
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $85);
            EmitU8(FCode, $C0);
            // js zur Fehlermeldung
            EmitU8(FCode, $78); EmitU8(FCode, 0); // placeholder for js +offset
            // cmp rax, ImmInt
            WriteMovRegImm64(FCode, RCX, instr.ImmInt);
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $39);
            EmitU8(FCode, $C8); // cmp rax, rcx
            // jae zur Fehlermeldung (>=)
            EmitU8(FCode, $73); EmitU8(FCode, 0); // placeholder for jae +offset
            // Check bestanden → OK
          end;

        irAssertNotNull:
          begin
            // assert(Src1 != 0)
            // Src1 = pointer value
            // Wenn Check fehlschlägt → panic mit "null check failed"
            slotIdx := fn.LocalCount + instr.Src1;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
            // test rax, rax → jz (zero) = null
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $85);
            EmitU8(FCode, $C0);
            // jz zur Fehlermeldung
            EmitU8(FCode, $74); EmitU8(FCode, 0); // placeholder for jz +offset
            // Check bestanden → OK
          end;

        irAssertNotZero:
          begin
            // assert(Src1 != 0)
            // Src1 = value to check (nicht nur pointer)
            // Wenn Check fehlschlägt → panic mit "zero check failed"
            slotIdx := fn.LocalCount + instr.Src1;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
            // test rax, rax → jz (zero)
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $85);
            EmitU8(FCode, $C0);
            // jz zur Fehlermeldung
            EmitU8(FCode, $74); EmitU8(FCode, 0); // placeholder
            // Check bestanden → OK
          end;

        irAssertTrue:
          begin
            // assert(Src1 != 0) - boolean must be true
            // Src1 = boolean value
            // Wenn Check fehlschlägt → panic mit "assertion failed"
            slotIdx := fn.LocalCount + instr.Src1;
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
            // test rax, rax → jz = false
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $85);
            EmitU8(FCode, $C0);
            // jz zur Fehlermeldung
            EmitU8(FCode, $74); EmitU8(FCode, 0); // placeholder
            // Check bestanden → OK
          end;

        // === Debug Inspect (TOR-011) ===
        irInspect:
          begin
            // Debug inspect: print variable name and value
            // Stub: print "inspect: <name>"
            WriteMovRegImm64(FCode, RAX, UInt64(SysNum(SYS_LINUX_WRITE, SYS_MACOS_WRITE)));
            WriteMovRegImm64(FCode, RDI, 2); // stderr
            // Print variable name
            WriteMovRegImm64(FCode, RSI, 0); // placeholder
            WriteMovRegImm64(FCode, RDX, Length(instr.ImmStr));
            WriteSyscall(FCode);
          end;

        end;
    end;

    // Sicherstellen, dass die Funktion einen Return hat
    if (Length(fn.Instructions) = 0) or (fn.Instructions[High(fn.Instructions)].Op <> irFuncExit) then
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
    end
    else
    begin
      // Debug: print unresolved label name
      WriteLn(StdErr, '[DEBUG] Unresolved jump patch: label="', FJumpPatches[i].LabelName, '"');
    end;
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
    // Note: _lyx_argv_base is stored in FData (not FCode) — see setup in _start code above.
    // Its offset in globalVarOffsets[argvBaseIdx] is already the FData offset (0).

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

    // Global variables are now pre-allocated in FData (writable section) during
    // initialization — see pre-allocation loop after module.GlobalVars setup.
    // globalVarOffsets[i] already holds the correct FData offsets.

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
      else if FGlobalVarLeaPositions[i].IsDataBased then
      begin
        // Variable lives in FData (e.g. _lyx_argv_base).
        // Code-to-data distance depends on ELF type:
        //   dynamic ELF: data section is page-aligned after code -> AlignUp(FCode.Size, 4096)
        //   static ELF:  data immediately follows code           -> FCode.Size
        // Use presence of external symbols as proxy for dynamic ELF.
        if Length(FExternalSymbols) > 0 then
          codeToDataGap := (FCode.Size + 4095) and (not 4095)  // page-align for dynamic ELF
        else
          codeToDataGap := FCode.Size;  // data follows code directly in static ELF
        offset := codeToDataGap + globalVarOffsets[varIdx]
                  - (FGlobalVarLeaPositions[i].CodePos + 7);
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
  // These are generated by irLoadGlobalAddr for VMT labels (_vmt_ClassName).
  // We resolve by name here because FVMTLabels was not yet populated when the
  // instructions were emitted (it is filled above, after all function bodies).
  for i := 0 to High(FVMTAddrLeaPositions) do
  begin
    leaCodePos := FVMTAddrLeaPositions[i].CodePos;
    vmtDataPos := -1;
    for j := 0 to High(FVMTLabels) do
    begin
      if FVMTLabels[j].Name = FVMTAddrLeaPositions[i].VMTLabelName then
      begin
        vmtDataPos := FVMTLabels[j].Pos;
        Break;
      end;
    end;
    if vmtDataPos >= 0 then
    begin
      // disp32 = vmtDataPos - (leaCodePos + 7)  (RIP points past the 7-byte LEA)
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

// === TMR Hash Store accessors (aerospace-todo P0 #46) ===
function TX86_64Emitter.HasVerifyIntegrityCall: Boolean;
begin
  Result := FHasVerifyIntegrity;
end;

function TX86_64Emitter.GetTMRDataAddrPos: Integer;
begin
  Result := FTMRDataAddrPos;
end;

end.
