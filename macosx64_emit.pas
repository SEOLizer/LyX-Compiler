{$mode objfpc}{$H+}
unit macosx64_emit;

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

uses
  Math;

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
  
  // Energy-Modell initialisieren
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
  // write(fd, buf, count): fd=RDI, buf=RSI, count=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_WRITE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallExit;
begin
  // exit(status): status=RDI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_EXIT);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallRead;
begin
  // read(fd, buf, count): fd=RDI, buf=RSI, count=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_READ);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallOpen;
begin
  // open(path, flags, mode): path=RDI, flags=RSI, mode=RDX
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_OPEN);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallClose;
begin
  // close(fd): fd=RDI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_CLOSE);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallMmap;
begin
  // mmap(addr, len, prot, flags, fd, offset)
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitSyscallMunmap;
begin
  // munmap(addr, len): addr=RDI, len=RSI
  WriteMovRegImm64(FCode, RAX, SYS_MACOS_MUNMAP);
  WriteSyscall(FCode);
  TrackEnergy(eokSyscall);
end;

procedure TMacOSX64Emitter.EmitDebugPrintString(const s: string);
begin
  // TODO: Implementieren
end;

procedure TMacOSX64Emitter.EmitDebugPrintInt(valueReg: Integer);
begin
  // TODO: Implementieren
end;

procedure TMacOSX64Emitter.EmitFromIR(module: TIRModule);
var
  i, j, k: Integer;
  instr: TIRInstr;
  labelIdx: Integer;
  fn: TIRFunction;
begin
  // Minimale Implementierung für grundlegende IR-Generierung
  // Diese muss für volle Funktionalität erheblich erweitert werden
  
  // Strings in den Data-Buffer schreiben
  for i := 0 to module.Strings.Count - 1 do
  begin
    SetLength(FStringOffsets, Length(FStringOffsets) + 1);
    FStringOffsets[High(FStringOffsets)] := FData.Size;
    for k := 1 to Length(module.Strings[i]) do
      FData.WriteU8(Ord(module.Strings[i][k]));
    FData.WriteU8(0);  // Null-Terminator
  end;
  
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
    
    // Stack-Frame für lokale Variablen
    if fn.LocalCount > 0 then
    begin
      // sub rsp, n*8
      EmitRex(FCode, 1, 0, 0, 0);
      EmitU8(FCode, $81);
      EmitU8(FCode, $EC);
      EmitU32(FCode, Cardinal(fn.LocalCount * 8));
    end;
    
    // IR-Instruktionen verarbeiten
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      
      case instr.Op of
        irReturn:
        begin
          // Epilog
          EmitRex(FCode, 1, 0, 0, 0);
          EmitU8(FCode, $89);
          EmitU8(FCode, $EC);  // mov rsp, rbp
          EmitU8(FCode, $5D);  // pop rbp
          WriteRet(FCode);
        end;
        
        irCallBuiltin:
        begin
          // Builtin-Calls behandeln
          if instr.ImmStr = 'exit' then
          begin
            // Exit-Syscall: Argument ist in Src1 (temp index)
            WriteMovRegImm64(FCode, RDI, instr.ImmInt);  // Exit-Code aus ImmInt
            EmitSyscallExit;
          end;
        end;
        
        // TODO: Weitere IR-Opcodes implementieren
        // Dies ist nur eine minimale Implementierung
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
  
  // Code-Größe für Energy-Stats aktualisieren
  FEnergyStats.CodeSizeBytes := FCode.Size;
end;

end.
