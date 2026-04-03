{$mode objfpc}{$H+}
unit macosx64_emit;

{ macOS x86_64 Emitter

  Emitter für macOS x86_64 (Mach-O, dyld FFI).
  Unterstützt extern fn link "libname" über LC_LOAD_DYLIB + stub-PLT.

  macOS Syscall-Interface (XNU):
  - Syscall-Nummern: BSD-Syscalls haben Präfix 0x2000000
  - Calling Convention: RDI, RSI, RDX, RCX, R8, R9 (wie SysV ABI)
  - SYSCALL Instruktion
}

interface

uses
  SysUtils, Classes, Math, bytes, ir, ast, backend_types, energy_model;

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

  { TMacOSX64Emitter - High-Level IR-zu-Maschinencode Emitter für macOS x86_64 }
  TMacOSX64Emitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FStringOffsets: array of UInt64;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FLabelPositions: array of TLabelPos;
    FJumpPatches: array of TJumpPatch;
    FVMTLabels: array of TLabelPos;
    FVMTLeaPositions: array of record
      VMTIndex: Integer;
      CodePos: Integer;
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

    { Memory move helpers (instance methods, emit to FCode) }
    procedure WriteMovRegMem(reg, base, disp: Integer);
    procedure WriteMovMemReg(base, disp, reg: Integer);
    function AddExternalSymbolMacos(const name: string; module: TIRModule): Integer;

  public
    constructor Create;
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

const
  // Register-Konstanten
  RAX = 0; RCX = 1; RDX = 2; RBX = 3; RSP = 4; RBP = 5; RSI = 6; RDI = 7;
  R8 = 8; R9 = 9; R10 = 10; R11 = 11; R12 = 12; R13 = 13; R14 = 14; R15 = 15;
  ParamRegs: array[0..5] of Byte = (RDI, RSI, RDX, RCX, R8, R9);

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
  SYS_MACOS_GETPID = $2000014;  // sys_getpid (20)
  SYS_MACOS_IOCTL  = $2000036;  // sys_ioctl (54)

{ ---- Free functions (standalone helpers, take TByteBuffer as parameter) ---- }

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

function SlotOffset(slot: Integer): Integer;
begin
  Result := -8 * (slot + 1);
end;

{ ---- Standalone memory move helpers (used in EmitFromIR before class is fully set up) ---- }

procedure StandaloneWriteMovRegMem(buf: TByteBuffer; reg, base, disp: Integer);
var
  rexR, rexB: Integer;
  modrm, modBits: Byte;
begin
  rexR := (reg shr 3) and 1;
  rexB := (base shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $8B);
  if (disp >= -128) and (disp <= 127) then
    modBits := $40
  else
    modBits := $80;
  modrm := modBits or Byte(((reg and 7) shl 3) and $38) or Byte(base and $7);
  EmitU8(buf, modrm);
  if (base and 7) = 4 then
    EmitU8(buf, $24);
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

procedure StandaloneWriteMovMemReg(buf: TByteBuffer; base, disp, reg: Integer);
var
  rexR, rexB: Integer;
  modrm, modBits: Byte;
begin
  rexR := (reg shr 3) and 1;
  rexB := (base shr 3) and 1;
  EmitRex(buf, 1, rexR, 0, rexB);
  EmitU8(buf, $89);
  if (disp >= -128) and (disp <= 127) then
    modBits := $40
  else
    modBits := $80;
  modrm := modBits or Byte(((reg and 7) shl 3) and $38) or Byte(base and $7);
  EmitU8(buf, modrm);
  if (base and 7) = 4 then
    EmitU8(buf, $24);
  if modBits = $40 then
    EmitU8(buf, Byte(disp))
  else
    EmitU32(buf, Cardinal(disp));
end;

{ TMacOSX64Emitter }

constructor TMacOSX64Emitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  SetLength(FStringOffsets, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  SetLength(FLabelPositions, 0);
  SetLength(FJumpPatches, 0);
  SetLength(FVMTLabels, 0);
  SetLength(FExternalSymbols, 0);
  SetLength(FPLTGOTPatches, 0);

  FCurrentCPU := GetCPUEnergyModel(cfX86_64);
  FEnergyContext.Config := GetEnergyConfig;
  FEnergyContext.CurrentCPU := FCurrentCPU;
  FMemoryAccessCount := 0;
  FCurrentFunctionEnergy := 0;
  FillChar(FEnergyStats, SizeOf(FEnergyStats), 0);
  FEnergyStats.DetailedBreakdown := nil;
end;

destructor TMacOSX64Emitter.Destroy;
begin
  FCode.Free;
  FData.Free;
  inherited Destroy;
end;

procedure TMacOSX64Emitter.TrackEnergy(kind: TEnergyOpKind);
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

procedure TMacOSX64Emitter.WriteMovRegMem(reg, base, disp: Integer);
begin
  StandaloneWriteMovRegMem(FCode, reg, base, disp);
end;

procedure TMacOSX64Emitter.WriteMovMemReg(base, disp, reg: Integer);
begin
  StandaloneWriteMovMemReg(FCode, base, disp, reg);
end;

function GetMacOSLibraryForSymbol(const symbolName: string): string;
begin
  // Map well-known symbols to their macOS library paths
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
     (symbolName = 'setenv') or (symbolName = 'unsetenv') or
     (symbolName = 'sqrt') or (symbolName = 'sin') or
     (symbolName = 'cos') or (symbolName = 'tan') or
     (symbolName = 'pow') or (symbolName = 'floor') or
     (symbolName = 'ceil') or (symbolName = 'fabs') then
    Result := '/usr/lib/libSystem.B.dylib'
  else
    Result := '/usr/lib/libSystem.B.dylib';
end;

function TMacOSX64Emitter.AddExternalSymbolMacos(const name: string; module: TIRModule): Integer;
var
  i: Integer;
  libName: string;
begin
  for i := 0 to High(FExternalSymbols) do
    if FExternalSymbols[i].Name = name then
    begin
      Result := i;
      Exit;
    end;
  Result := Length(FExternalSymbols);
  SetLength(FExternalSymbols, Result + 1);
  FExternalSymbols[Result].Name := name;
  libName := GetMacOSLibraryForSymbol(name);
  FExternalSymbols[Result].LibraryName := libName;
end;

function TMacOSX64Emitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TMacOSX64Emitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TMacOSX64Emitter.GetFunctionOffset(const name: string): Integer;
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

function TMacOSX64Emitter.GetExternalSymbols: TExternalSymbolArray;
begin
  SetLength(Result, Length(FExternalSymbols));
  if Length(FExternalSymbols) > 0 then
    Move(FExternalSymbols[0], Result[0], Length(FExternalSymbols) * SizeOf(TExternalSymbol));
end;

function TMacOSX64Emitter.GetPLTGOTPatches: TPLTGOTPatchArray;
begin
  SetLength(Result, Length(FPLTGOTPatches));
  if Length(FPLTGOTPatches) > 0 then
    Move(FPLTGOTPatches[0], Result[0], Length(FPLTGOTPatches) * SizeOf(TPLTGOTPatch));
end;

function TMacOSX64Emitter.GetEnergyStats: TEnergyStats;
begin
  FEnergyStats.CodeSizeBytes := FCode.Size;
  FEnergyStats.EstimatedEnergyUnits := FCurrentFunctionEnergy;
  FEnergyStats.L1CacheFootprint := Min(FCode.Size, 32768);
  Result := FEnergyStats;
end;

procedure TMacOSX64Emitter.SetEnergyLevel(level: TEnergyLevel);
begin
  FEnergyContext.Config.Level := level;
end;

{ Syscall-Helfer }

procedure TMacOSX64Emitter.EmitSyscallWrite;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallExit;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_EXIT);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallRead;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_READ);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallOpen;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_OPEN);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallClose;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_CLOSE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallMmap;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallMunmap;
begin
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MUNMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitDebugPrintString(const s: string);
begin
  // not implemented
end;

procedure TMacOSX64Emitter.EmitDebugPrintInt(valueReg: Integer);
begin
  // not implemented
end;

procedure TMacOSX64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  labelIdx: Integer;
  fn: TIRFunction;
  slotIdx: Integer;
  arg2: Integer;
  arg3: Integer;
  arg4: Integer;
  arg5: Integer;
  arg6: Integer;
  argCount: Integer;
  offset: Integer;
  totalSlots: Integer;
  maxTemp: Integer;
begin
  // Reset state
  SetLength(FStringOffsets, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  SetLength(FLabelPositions, 0);
  SetLength(FJumpPatches, 0);
  SetLength(FExternalSymbols, 0);
  SetLength(FPLTGOTPatches, 0);

  // ----------------------------------------------------------------
  // Generate per-function code
  // ----------------------------------------------------------------
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];

    // Register function label
    SetLength(FLabelPositions, Length(FLabelPositions) + 1);
    labelIdx := High(FLabelPositions);
    FLabelPositions[labelIdx].Name := fn.Name;
    FLabelPositions[labelIdx].Pos := FCode.Size;

    // Compute max temp index
    maxTemp := 0;
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      if instr.Dest > maxTemp then maxTemp := instr.Dest;
      if instr.Src1 > maxTemp then maxTemp := instr.Src1;
      if instr.Src2 > maxTemp then maxTemp := instr.Src2;
    end;

    // Total slots: locals + temporaries
    totalSlots := fn.LocalCount + maxTemp + 1;

    // Prolog
    EmitU8(FCode, $55);             // push rbp
    EmitRex(FCode, 1, 0, 0, 0);
    EmitU8(FCode, $89);
    EmitU8(FCode, $E5);             // mov rbp, rsp

    // Allocate stack frame
    if totalSlots > 0 then
    begin
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $81);
      EmitU8(FCode, $EC);
      EmitU32(FCode, Cardinal(totalSlots * 8));
    end;

    // Spill incoming parameters (SysV ABI: RDI, RSI, RDX, RCX, R8, R9)
    for k := 0 to fn.ParamCount - 1 do
    begin
      if k < 6 then
        StandaloneWriteMovMemReg(FCode, RBP, SlotOffset(k), ParamRegs[k])
      else
      begin
        // Stack params: above saved rbp
        StandaloneWriteMovRegMem(FCode, RAX, RBP, 16 + (k - 6) * 8);
        StandaloneWriteMovMemReg(FCode, RBP, SlotOffset(k), RAX);
      end;
    end;

    // Process IR instructions
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];

      case instr.Op of
        irFuncExit:
        begin
          if instr.Src1 >= 0 then
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
          EmitRex(FCode, 1, 0, 0, 0);
          EmitU8(FCode, $89);
          EmitU8(FCode, $EC);  // mov rsp, rbp
          EmitU8(FCode, $5D);  // pop rbp
          WriteRet(FCode);
        end;

        irConstInt:
        begin
          slotIdx := fn.LocalCount + instr.Dest;
          WriteMovRegImm64(FCode, RAX, UInt64(instr.ImmInt));
          WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
        end;

        irConstStr:
        begin
          slotIdx := fn.LocalCount + instr.Dest;
          arg3 := StrToIntDef(instr.ImmStr, -1);
          if arg3 >= 0 then
          begin
            SetLength(FLeaPositions, Length(FLeaPositions) + 1);
            SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
            FLeaPositions[High(FLeaPositions)] := FCode.Size + 3;
            FLeaStrIndex[High(FLeaStrIndex)] := arg3;
            EmitRex(FCode, 1, 0, 0, 0);  // REX.W
            EmitU8(FCode, $8D);           // LEA
            EmitU8(FCode, $05);           // ModR/M: rax, [rip + disp32]
            EmitU32(FCode, 0);            // placeholder
            WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
          end;
        end;

        irLoadLocal:
        begin
          slotIdx := instr.Src1;
          WriteMovRegMem(RAX, RBP, SlotOffset(slotIdx));
          WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
        end;

        irStoreLocal:
        begin
          WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
          WriteMovMemReg(RBP, SlotOffset(instr.Dest), RAX);
        end;

        irCall:
        begin
          argCount := Length(instr.ArgTemps);
          for k := 0 to Min(argCount, 6) - 1 do
            WriteMovRegMem(ParamRegs[k], RBP, SlotOffset(fn.LocalCount + instr.ArgTemps[k]));

          if instr.CallMode = cmExternal then
          begin
            AddExternalSymbolMacos(instr.ImmStr, module);
            SetLength(FJumpPatches, Length(FJumpPatches) + 1);
            FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;
            FJumpPatches[High(FJumpPatches)].LabelName := '@plt_' + instr.ImmStr;
            FJumpPatches[High(FJumpPatches)].JmpSize := 4;
            EmitU8(FCode, $E8);  // call rel32
            EmitU32(FCode, 0);   // placeholder
          end
          else
          begin
            SetLength(FJumpPatches, Length(FJumpPatches) + 1);
            FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;
            FJumpPatches[High(FJumpPatches)].LabelName := instr.ImmStr;
            FJumpPatches[High(FJumpPatches)].JmpSize := 4;
            EmitU8(FCode, $E8);  // call rel32
            EmitU32(FCode, 0);   // placeholder
          end;

          if instr.Dest >= 0 then
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
        end;

        // ========================================================================
        // SIMD Operations for ParallelArray - macOS x86_64
        // ========================================================================
        
        irSIMDAdd:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $01);
            EmitU8(FCode, $C8);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDSub:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $29);
            EmitU8(FCode, $C8);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDMul:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $0F);
            EmitU8(FCode, $AF);
            EmitU8(FCode, $C1);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDDiv:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $99);
            EmitU8(FCode, $F7);
            EmitU8(FCode, $F9);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDAnd, irSIMDOr, irSIMDXor:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            if instr.Op = irSIMDAnd then
            begin
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $21);
              EmitU8(FCode, $C8);
            end
            else if instr.Op = irSIMDOr then
            begin
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $09);
              EmitU8(FCode, $C8);
            end
            else
            begin
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $31);
              EmitU8(FCode, $C8);
            end;
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDNeg:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $F7);
            EmitU8(FCode, $D8);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $39);
            EmitU8(FCode, $C8);
            EmitRex(FCode, 0, 0, 0, 0);
            EmitU8(FCode, $0F);
            case instr.Op of
              irSIMDCmpEq: EmitU8(FCode, $94);
              irSIMDCmpNe: EmitU8(FCode, $95);
              irSIMDCmpLt: EmitU8(FCode, $9C);
              irSIMDCmpLe: EmitU8(FCode, $9E);
              irSIMDCmpGt: EmitU8(FCode, $9F);
              irSIMDCmpGe: EmitU8(FCode, $9D);
            end;
            EmitU8(FCode, $C0);
            EmitRex(FCode, 0, 0, 0, 0);
            EmitU8(FCode, $0F);
            EmitU8(FCode, $B6);
            EmitU8(FCode, $C0);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDLoadElem:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $C1);
            EmitU8(FCode, $E1);
            EmitU8(FCode, 3);
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $01);
            EmitU8(FCode, $C8);
            WriteMovRegMem(RAX, RAX, 0);
            WriteMovMemReg(RBP, SlotOffset(fn.LocalCount + instr.Dest), RAX);
          end;

        irSIMDStoreElem:
          begin
            WriteMovRegMem(RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $C1);
            EmitU8(FCode, $E1);
            EmitU8(FCode, 3);
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $01);
            EmitU8(FCode, $C8);
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $89);
            EmitU8(FCode, $45);
            EmitU8(FCode, $F8);
            WriteMovRegMem(RCX, RBP, SlotOffset(fn.LocalCount + instr.Src3));
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $8B);
            EmitU8(FCode, $45);
            EmitU8(FCode, $F8);
            WriteMovMemReg(RAX, RCX, 0);
          end;

        irCallBuiltin:
        begin
          if instr.ImmStr = 'exit' then
          begin
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, UInt64(instr.ImmInt));
            EmitSyscallExit;
          end
          else if (instr.ImmStr = 'PrintStr') or (instr.ImmStr = 'Println') then
          begin
            arg3 := -1;
            if Length(instr.ArgTemps) > 0 then
              arg3 := instr.ArgTemps[0]
            else
              arg3 := instr.Src1;

            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              StandaloneWriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));

              // mov rdi, rsi
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $89);
              EmitU8(FCode, $F7);

              // strlen loop: cmp byte [rdi], 0 / je +5 / inc rdi / jmp -10
              EmitU8(FCode, $80);
              EmitU8(FCode, $3F);
              EmitU8(FCode, $00);  // cmp byte [rdi], 0
              EmitU8(FCode, $74);
              EmitU8(FCode, $05);  // je +5
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $FF);
              EmitU8(FCode, $C7);  // inc rdi
              EmitU8(FCode, $EB);
              EmitU8(FCode, $F6);  // jmp -10

              // sub rdi, rsi -> rdi = length
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $29);
              EmitU8(FCode, $F7);

              // mov rdx, rdi (length)
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $89);
              EmitU8(FCode, $FA);

              // Reload RSI (buf pointer)
              StandaloneWriteMovRegMem(FCode, RSI, RBP, SlotOffset(slotIdx));

              // RDI = 1 (stdout fd)
              WriteMovRegImm64(FCode, RDI, 1);

              // RAX = SYS_MACOS_WRITE
              WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
              WriteSyscall(FCode);
              TrackEnergy(eokSyscall);
            end;
          end
          else if instr.ImmStr = 'PrintInt' then
          begin
            arg3 := -1;
            if Length(instr.ArgTemps) > 0 then
              arg3 := instr.ArgTemps[0]
            else
              arg3 := instr.Src1;

            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              StandaloneWriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));

              // sub rsp, 24
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $83);
              EmitU8(FCode, $EC);
              EmitU8(FCode, 24);

              // lea rdi, [rsp+20]
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $8D);
              EmitU8(FCode, $7C);
              EmitU8(FCode, $24);
              EmitU8(FCode, 20);

              // mov byte [rdi], 0
              EmitU8(FCode, $C6);
              EmitU8(FCode, $07);
              EmitU8(FCode, $00);

              // xor r8d, r8d
              EmitU8(FCode, $45);
              EmitU8(FCode, $31);
              EmitU8(FCode, $C0);

              // test rax, rax
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $85);
              EmitU8(FCode, $C0);

              // jns +9
              EmitU8(FCode, $79);
              EmitU8(FCode, $09);

              // neg rax
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $F7);
              EmitU8(FCode, $D8);

              // mov r8d, 1
              EmitU8(FCode, $41);
              EmitU8(FCode, $B8);
              EmitU32(FCode, 1);

              // mov rcx, 10
              WriteMovRegImm64(FCode, RCX, 10);

              // .Lloop:
              // dec rdi
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $FF);
              EmitU8(FCode, $CF);

              // xor rdx, rdx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $31);
              EmitU8(FCode, $D2);

              // div rcx
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $F7);
              EmitU8(FCode, $F1);

              // add dl, '0'
              EmitU8(FCode, $80);
              EmitU8(FCode, $C2);
              EmitU8(FCode, $30);

              // mov [rdi], dl
              EmitU8(FCode, $88);
              EmitU8(FCode, $17);

              // test rax, rax
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $85);
              EmitU8(FCode, $C0);

              // jnz .Lloop
              EmitU8(FCode, $75);
              EmitU8(FCode, $ED);

              // test r8d, r8d
              EmitU8(FCode, $45);
              EmitU8(FCode, $85);
              EmitU8(FCode, $C0);

              // jz +6
              EmitU8(FCode, $74);
              EmitU8(FCode, $06);

              // dec rdi
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $FF);
              EmitU8(FCode, $CF);

              // mov byte [rdi], '-'
              EmitU8(FCode, $C6);
              EmitU8(FCode, $07);
              EmitU8(FCode, $2D);

              // mov rsi, rdi
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $89);
              EmitU8(FCode, $FE);

              // lea rdx, [rsp+20]
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $8D);
              EmitU8(FCode, $54);
              EmitU8(FCode, $24);
              EmitU8(FCode, 20);

              // sub rdx, rdi
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $29);
              EmitU8(FCode, $FA);

              // RDI = 1 (stdout)
              WriteMovRegImm64(FCode, RDI, 1);

              // RAX = SYS_MACOS_WRITE
              WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
              WriteSyscall(FCode);
              TrackEnergy(eokSyscall);

              // add rsp, 24
              EmitRex(FCode, 1, 0, 0, 0);
              EmitU8(FCode, $83);
              EmitU8(FCode, $C4);
              EmitU8(FCode, 24);
            end;
          end
          else if instr.ImmStr = 'open' then
          begin
            // open(path: pchar, flags: int64, mode: int64) -> int64 (fd)
            // RDI=path, RSI=flags, RDX=mode
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            if instr.Src2 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_OPEN);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'read' then
          begin
            // read(fd: int64, buf: pchar, count: int64) -> int64
            // RDI=fd, RSI=buf, RDX=count
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            arg2 := -1;
            if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
              arg2 := instr.ArgTemps[1]
            else
              arg2 := instr.Src2;
            if arg2 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_READ);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'write' then
          begin
            // write(fd: int64, buf: pchar, count: int64) -> int64
            // RDI=fd, RSI=buf, RDX=count
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            arg2 := -1;
            if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
              arg2 := instr.ArgTemps[1]
            else
              arg2 := instr.Src2;
            if arg2 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'close' then
          begin
            // close(fd: int64) -> int64
            // RDI=fd
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_CLOSE);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'lseek' then
          begin
            // lseek(fd: int64, offset: int64, whence: int64) -> int64
            // RDI=fd, RSI=offset, RDX=whence
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            arg2 := -1;
            if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
              arg2 := instr.ArgTemps[1]
            else
              arg2 := instr.Src2;
            if arg2 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_LSEEK);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'unlink' then
          begin
            // unlink(path: pchar) -> int64
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_UNLINK);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'mkdir' then
          begin
            // mkdir(path: pchar, mode: int64) -> int64
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            if instr.Src2 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_MKDIR);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'mmap' then
          begin
            // mmap(addr, length, prot, flags, fd, offset) -> int64 (pointer)
            // RDI=addr, RSI=length, RDX=prot, R10=flags, R8=fd, R9=offset
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            // flags go to R10 for syscall
            arg4 := -1;
            if (instr.ImmInt >= 4) and (Length(instr.ArgTemps) >= 4) then
              arg4 := instr.ArgTemps[3];
            if arg4 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg4;
              WriteMovRegMem(R10, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, R10, 0);
            arg5 := -1;
            if (instr.ImmInt >= 5) and (Length(instr.ArgTemps) >= 5) then
              arg5 := instr.ArgTemps[4];
            if arg5 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg5;
              WriteMovRegMem(R8, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, R8, UInt64(-1));
            arg6 := -1;
            if (instr.ImmInt >= 6) and (Length(instr.ArgTemps) >= 6) then
              arg6 := instr.ArgTemps[5];
            if arg6 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg6;
              WriteMovRegMem(R9, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, R9, 0);
            // addr and length
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            if instr.Src2 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_MMAP);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'munmap' then
          begin
            // munmap(addr, length) -> int64
            // RDI=addr, RSI=length
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            arg2 := -1;
            if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
              arg2 := instr.ArgTemps[1]
            else
              arg2 := instr.Src2;
            if arg2 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_MUNMAP);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'ioctl' then
          begin
            // ioctl(fd, request, argp) -> int64
            // RDI=fd, RSI=request, RDX=argp
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            if instr.Src2 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            arg3 := -1;
            if (instr.ImmInt >= 3) and (Length(instr.ArgTemps) >= 3) then
              arg3 := instr.ArgTemps[2];
            if arg3 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg3;
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_IOCTL);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'getpid' then
          begin
            // getpid() -> int64: returns process ID
            WriteMovRegImm64(FCode, RDI, 0);  // No args
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_GETPID);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrLen' then
          begin
            // StrLen(s: pchar): int64 — null-scan strlen
            if Length(instr.ArgTemps) >= 1 then
            begin
              slotIdx := fn.LocalCount + instr.ArgTemps[0];
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
              // xor rcx, rcx
              EmitU8(FCode, $48); EmitU8(FCode, $31); EmitU8(FCode, $C9);
              // loop: cmp byte [rdi+rcx], 0
              EmitU8(FCode, $80); EmitU8(FCode, $3C); EmitU8(FCode, $0F); EmitU8(FCode, $00);
              // jz +5
              EmitU8(FCode, $74); EmitU8(FCode, $05);
              // inc rcx
              EmitU8(FCode, $48); EmitU8(FCode, $FF); EmitU8(FCode, $C1);
              // jmp -11
              EmitU8(FCode, $EB); EmitU8(FCode, $F5);
              // mov rax, rcx
              EmitU8(FCode, $48); EmitU8(FCode, $89); EmitU8(FCode, $C8);
              if instr.Dest >= 0 then
              begin
                slotIdx := fn.LocalCount + instr.Dest;
                WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
              end;
            end;
          end
          else if instr.ImmStr = 'StrCharAt' then
          begin
            // StrCharAt(s: pchar, i: int64): int64 — load byte at s[i]
            if Length(instr.ArgTemps) >= 2 then
            begin
              slotIdx := fn.LocalCount + instr.ArgTemps[0];
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));  // rdi = s
              slotIdx := fn.LocalCount + instr.ArgTemps[1];
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));  // rsi = i
              // movzx rax, byte [rdi+rsi]
              EmitU8(FCode, $48); EmitU8(FCode, $0F); EmitU8(FCode, $B6); EmitU8(FCode, $04); EmitU8(FCode, $0F);
              if instr.Dest >= 0 then
              begin
                slotIdx := fn.LocalCount + instr.Dest;
                WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
              end;
            end;
          end
          else if instr.ImmStr = 'StrSetChar' then
          begin
            // StrSetChar(s: pchar, i: int64, c: int64) — write byte c to s[i]
            if Length(instr.ArgTemps) >= 3 then
            begin
              slotIdx := fn.LocalCount + instr.ArgTemps[0];
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));  // rdi = s
              slotIdx := fn.LocalCount + instr.ArgTemps[1];
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));  // rsi = i
              slotIdx := fn.LocalCount + instr.ArgTemps[2];
              WriteMovRegMem(RDX, RBP, SlotOffset(slotIdx));  // rdx = c
              // mov byte [rdi+rsi], dl
              EmitU8(FCode, $88); EmitU8(FCode, $14); EmitU8(FCode, $0F);
            end;
          end
          else if instr.ImmStr = 'StrNew' then
          begin
            // StrNew(capacity: int64): pchar — mmap alloc
            // Stub: return NULL
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrFree' then
          begin
            // StrFree(s: pchar) — munmap using header
            // Stub: do nothing
          end
          else if instr.ImmStr = 'StrFromInt' then
          begin
            // StrFromInt(n: int64): pchar — convert int64 to decimal string
            // Stub: return empty string
            // Allocate minimal buffer
            WriteMovRegImm64(FCode, RSI, 32);
            WriteMovRegImm64(FCode, RDX, 3);
            WriteMovRegImm64(FCode, R10, $22);
            WriteMovRegImm64(FCode, R8, UInt64(-1));
            WriteMovRegImm64(FCode, R9, 0);
            WriteMovRegImm64(FCode, RAX, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_MMAP);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            // Return empty string (just \0)
            EmitU8(FCode, $C6); EmitU8(FCode, $00); EmitU8(FCode, 0);  // mov byte [rax], 0
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrAppend' then
          begin
            // StrAppend(dest, src): stub - return dest
            if Length(instr.ArgTemps) >= 1 then
            begin
              slotIdx := fn.LocalCount + instr.ArgTemps[0];
              WriteMovRegMem(RAX, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrFindChar' then
          begin
            // StrFindChar: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrSub' then
          begin
            // StrSub: stub - return NULL
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrConcat' then
          begin
            // StrConcat: stub - return NULL
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrCopy' then
          begin
            // StrCopy: stub - return NULL
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'FileGetSize' then
          begin
            // FileGetSize: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrStartsWith' then
          begin
            // StrStartsWith: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrEndsWith' then
          begin
            // StrEndsWith: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'StrEquals' then
          begin
            // StrEquals: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'GetArgC' then
          begin
            // GetArgC: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'GetArg' then
          begin
            // GetArg: stub - return NULL
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'PrintFloat' then
          begin
            // PrintFloat(value: f64) -> void
            // Stub: print "(float)\n" to stdout using write syscall
            // Just use write with a pre-defined string
            // Allocate small buffer on stack
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $83); EmitU8(FCode, $EC); EmitU8(FCode, 16); // sub rsp, 16
            // Write "(float)\n" to stack buffer
            EmitU8(FCode, Ord('('));
            EmitU8(FCode, Ord('f'));
            EmitU8(FCode, Ord('l'));
            EmitU8(FCode, Ord('o'));
            EmitU8(FCode, Ord('a'));
            EmitU8(FCode, Ord('t'));
            EmitU8(FCode, Ord(')'));
            EmitU8(FCode, 10); // newline
            // Write to stdout: write(1, rsp, 8)
            WriteMovRegImm64(FCode, RDI, 1);  // stdout
            // lea rsi, [rsp]
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $8D); EmitU8(FCode, $74); EmitU8(FCode, $24); EmitU8(FCode, 0); // lea rsi, [rsp]
            WriteMovRegImm64(FCode, RDX, 8);  // length
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            // Restore stack
            EmitRex(FCode, 1, 0, 0, 0);
            EmitU8(FCode, $83); EmitU8(FCode, $C4); EmitU8(FCode, 16); // add rsp, 16
          end
          else if instr.ImmStr = 'Random' then
          begin
            // Random() -> int64: LCG random (stub: return 0)
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'RandomSeed' then
          begin
            // RandomSeed(seed: int64): void (stub)
          end
          else if instr.ImmStr = 'sys_socket' then
          begin
            // sys_socket: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_bind' then
          begin
            // sys_bind: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_listen' then
          begin
            // sys_listen: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_accept' then
          begin
            // sys_accept: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_connect' then
          begin
            // sys_connect: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_recvfrom' then
          begin
            // sys_recvfrom: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_sendto' then
          begin
            // sys_sendto: stub - return 0
            WriteMovRegImm64(FCode, RAX, 0);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_setsockopt' then
          begin
            // sys_setsockopt: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_getsockopt' then
          begin
            // sys_getsockopt: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'sys_shutdown' then
          begin
            // sys_shutdown: stub - return -1
            WriteMovRegImm64(FCode, RAX, UInt64(-1));
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'printf' then
          begin
            // printf: stub - just ignore
          end
          else if instr.ImmStr = 'Println' then
          begin
            // Println: already handled above as PrintStr variant
          end
          else if instr.ImmStr = 'rmdir' then
          begin
            // rmdir(path: pchar) -> int64
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_RMDIR);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'chmod' then
          begin
            // chmod(path: pchar, mode: int64) -> int64
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            if instr.Src2 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_CHMOD);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          else if instr.ImmStr = 'rename' then
          begin
            // rename(oldpath: pchar, newpath: pchar) -> int64
            if instr.Src1 >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Src1;
              WriteMovRegMem(RDI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RDI, 0);
            arg2 := -1;
            if (instr.ImmInt >= 2) and (Length(instr.ArgTemps) >= 2) then
              arg2 := instr.ArgTemps[1]
            else
              arg2 := instr.Src2;
            if arg2 >= 0 then
            begin
              slotIdx := fn.LocalCount + arg2;
              WriteMovRegMem(RSI, RBP, SlotOffset(slotIdx));
            end
            else
              WriteMovRegImm64(FCode, RSI, 0);
            WriteMovRegImm64(FCode, RAX, SYS_MACOS_RENAME);
            WriteSyscall(FCode);
            TrackEnergy(eokSyscall);
            if instr.Dest >= 0 then
            begin
              slotIdx := fn.LocalCount + instr.Dest;
              WriteMovMemReg(RBP, SlotOffset(slotIdx), RAX);
            end;
          end
          // Other builtins: ignore for now
        end;

      end; // case
    end; // for j

    // Ensure function ends with return
    if (Length(fn.Instructions) = 0) or
       (fn.Instructions[High(fn.Instructions)].Op <> irFuncExit) then
    begin
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $89);
      EmitU8(FCode, $EC);  // mov rsp, rbp
      EmitU8(FCode, $5D);  // pop rbp
      WriteRet(FCode);
    end;
  end; // for i (functions)

  // ----------------------------------------------------------------
  // Generate PLT stubs for external symbols (6 bytes: FF 25 <disp32>)
  // ----------------------------------------------------------------
  if Length(FExternalSymbols) > 0 then
  begin
    SetLength(FPLTGOTPatches, Length(FExternalSymbols));
    for i := 0 to High(FExternalSymbols) do
    begin
      FPLTGOTPatches[i].Pos := FCode.Size;
      FPLTGOTPatches[i].SymbolIndex := i;
      FPLTGOTPatches[i].SymbolName := FExternalSymbols[i].Name;
      FPLTGOTPatches[i].PLT0PushPos := 0;
      FPLTGOTPatches[i].PLT0JmpPos := 0;
      FPLTGOTPatches[i].PLT0VA := 0;
      FPLTGOTPatches[i].GotVA := 0;

      // Register PLT stub label for call patching
      SetLength(FLabelPositions, Length(FLabelPositions) + 1);
      FLabelPositions[High(FLabelPositions)].Name := '@plt_' + FExternalSymbols[i].Name;
      FLabelPositions[High(FLabelPositions)].Pos := FCode.Size;

      // jmp qword [rip + disp32] — the disp32 is patched by WriteDynamicMachO64
      EmitU8(FCode, $FF);
      EmitU8(FCode, $25);
      EmitU32(FCode, 0);  // placeholder
    end;
  end;

  // ----------------------------------------------------------------
  // Patch CALL rel32 to function / PLT stub labels
  // ----------------------------------------------------------------
  for i := 0 to High(FJumpPatches) do
  begin
    for j := 0 to High(FLabelPositions) do
    begin
      if FLabelPositions[j].Name = FJumpPatches[i].LabelName then
      begin
        offset := FLabelPositions[j].Pos - (FJumpPatches[i].Pos + 4);
        FCode.PatchU32LE(FJumpPatches[i].Pos, Cardinal(offset));
        Break;
      end;
    end;
  end;

  // ----------------------------------------------------------------
  // Write strings to FCode (after PLT stubs), then patch LEA disp32
  // ----------------------------------------------------------------
  SetLength(FStringOffsets, module.Strings.Count);
  for i := 0 to module.Strings.Count - 1 do
  begin
    FStringOffsets[i] := FCode.Size;
    for k := 1 to Length(module.Strings[i]) do
      FCode.WriteU8(Ord(module.Strings[i][k]));
    FCode.WriteU8(0);  // null terminator
  end;

  for i := 0 to High(FLeaPositions) do
  begin
    if (FLeaStrIndex[i] >= 0) and (FLeaStrIndex[i] <= High(FStringOffsets)) then
    begin
      offset := Integer(FStringOffsets[FLeaStrIndex[i]]) - (FLeaPositions[i] + 4);
      FCode.PatchU32LE(FLeaPositions[i], Cardinal(offset));
    end;
  end;

  // Update energy stats
  FEnergyStats.CodeSizeBytes := FCode.Size;
end;

end.
