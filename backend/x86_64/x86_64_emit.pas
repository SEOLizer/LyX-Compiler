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
  maxTemp: Integer;
  totalSlots: Integer;
  mainFnIdx: Integer;
  mainPos: Integer;
  offset: Integer;
  negOffset: Integer;
  argCount: Integer;
  argTemps: array of Integer;
  stackArgsCount: Integer;
  stackCleanup: Integer;
  disp32: Integer;
  // Global variable tracking
  globalVarNames: TStringList;
  globalVarOffsets: array of Integer;
  totalDataOffset: Integer;
  varIdx: Integer;
  leaPos: Integer;
  vmtDataPos: Integer;
  FGlobalVarLeaPositions: array of record
    VarIndex: Integer;
    CodePos: Integer;
  end;
begin
  globalVarNames := TStringList.Create;
  try
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
  
  // Initialize global variable offset tracking (after strings in data section)
  totalDataOffset := FData.Size;
  
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
  
  // mov rax, 60 (sys_exit)
  WriteMovRegImm64(FCode, RAX, 60);
  
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
    if fn.ParamCount > 0 then
    begin
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
          // SysV ABI: Structs ≤16 Bytes werden in RAX:RDX zurückgegeben
          if instr.Src1 >= 0 then
          begin
            // Erstes Quadword in RAX laden
            WriteMovRegMem(FCode, RAX, RBP, SlotOffset(instr.Src1));
            
            // Für Structs > 8 Bytes: zweites Quadword in RDX laden
            if instr.StructSize > 8 then
              WriteMovRegMem(FCode, RDX, RBP, SlotOffset(instr.Src1 + 1));
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
             // Src1 is a local slot index (0..LocalCount-1)
             // Dest is a temp index (needs fn.LocalCount added)
             slotIdx := instr.Src1;  // Local slot (no offset)
             WriteMovRegMem(FCode, RAX, RBP, SlotOffset(slotIdx));
             slotIdx := fn.LocalCount + instr.Dest;  // Temp slot
             WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
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
                 // VMT label not found - this shouldn't happen, but create placeholder
                 vmtDataPos := FData.Size;
                 FData.WriteU64LE(0);
               end;
               
               // lea rax, [rip+disp32] ; will be patched later - loads ADDRESS directly
               leaPos := FCode.Size;
               EmitU8(FCode, $48); EmitU8(FCode, $8D); EmitU8(FCode, $05); EmitU32(FCode, 0);
               // Record position for patching - add 10000 to indicate VMT offset (use FData offset directly)
               SetLength(FGlobalVarLeaPositions, Length(FGlobalVarLeaPositions) + 1);
               FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].VarIndex := vmtDataPos + 10000;
               FGlobalVarLeaPositions[High(FGlobalVarLeaPositions)].CodePos := leaPos;
               // Store the ADDRESS into temp slot
               slotIdx := fn.LocalCount + instr.Dest;
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
               slotIdx := fn.LocalCount + instr.Dest;
               WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
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

          irConstInt:
            begin
               // Load immediate integer into temp slot
               slotIdx := fn.LocalCount + instr.Dest;
               WriteMovRegImm64(FCode, RAX, UInt64(instr.ImmInt));
               WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
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
              
              // RAX = sys_mmap = 9
              WriteMovRegImm64(FCode, RAX, 9);
              
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
              
              // RAX = sys_munmap = 11
              WriteMovRegImm64(FCode, RAX, 11);
              
              // syscall
              WriteSyscall(FCode);
            end;
            
          irConstStr:
           begin
              // Load string address into temp slot
              // ImmStr contains the string index as string
              slotIdx := fn.LocalCount + instr.Dest;
              arg3 := StrToIntDef(instr.ImmStr, -1);
              if (arg3 >= 0) and (arg3 <= High(FStringOffsets)) then
              begin
                // Save position for later patching by ELF writer
                // The ELF writer will calculate the actual address based on layout
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
                WriteMovRegImm64(FCode, RAX, 60);  // sys_exit
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
                  
                  // RAX = 1 (sys_write)
                  WriteMovRegImm64(FCode, RAX, 1);
                  
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
                  
                  // RAX = 1 (sys_write)
                  WriteMovRegImm64(FCode, RAX, 1);
                  
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
               WriteMovRegImm64(FCode, RAX, 16); // sys_ioctl
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
               // 4th arg from ArgTemps[3]
               arg4 := -1;
               if (instr.ImmInt >= 4) and (Length(instr.ArgTemps) >= 4) then
                 arg4 := instr.ArgTemps[3];
               if arg4 >= 0 then
               begin
                 slotIdx := fn.LocalCount + arg4;
                 WriteMovRegMem(FCode, R10, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R10, 0);
               // 5th arg from ArgTemps[4]
               arg5 := -1;
               if (instr.ImmInt >= 5) and (Length(instr.ArgTemps) >= 5) then
                 arg5 := instr.ArgTemps[4];
               if arg5 >= 0 then
               begin
                 slotIdx := fn.LocalCount + arg5;
                 WriteMovRegMem(FCode, R8, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R8, 0);
               // 6th arg from ArgTemps[5]
               arg6 := -1;
               if (instr.ImmInt >= 6) and (Length(instr.ArgTemps) >= 6) then
                 arg6 := instr.ArgTemps[5];
               if arg6 >= 0 then
               begin
                 slotIdx := fn.LocalCount + arg6;
                 WriteMovRegMem(FCode, R9, RBP, SlotOffset(slotIdx));
               end
               else
                 WriteMovRegImm64(FCode, R9, 0);
               WriteMovRegImm64(FCode, RAX, 9); // sys_mmap
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
                   
                 WriteMovRegImm64(FCode, RAX, 11); // sys_munmap
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_SOCKET);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_BIND);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_LISTEN);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_ACCEPT);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_CONNECT);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_RECVFROM);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_SENDTO);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_SETSOCKOPT);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_GETSOCKOPT);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_FCNTL);
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
                   
                 WriteMovRegImm64(FCode, RAX, SYS_LINUX_SHUTDOWN);
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
                  
                  WriteMovRegImm64(FCode, RAX, SYS_LINUX_MMAP);
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
                  
                  WriteMovRegImm64(FCode, RAX, SYS_LINUX_MUNMAP);
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
                  
                  WriteMovRegImm64(FCode, RAX, SYS_LINUX_WRITE);
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
                
                WriteMovRegImm64(FCode, RAX, 0); // sys_read
                WriteSyscall(FCode);
                
                if instr.Dest >= 0 then
                begin
                  slotIdx := fn.LocalCount + instr.Dest;
                  WriteMovMemReg(FCode, RBP, SlotOffset(slotIdx), RAX);
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
             
             // Handle virtual method calls
             if instr.IsVirtualCall and (instr.VMTIndex >= 0) then
             begin
               // Virtual call: self is in RDI (first arg for SysV ABI)
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
               // Regular call: emit call rel32 with placeholder for patching
               SetLength(FJumpPatches, Length(FJumpPatches) + 1);
               FJumpPatches[High(FJumpPatches)].Pos := FCode.Size + 1;  // Position after E8 opcode
               FJumpPatches[High(FJumpPatches)].LabelName := instr.ImmStr;
               FJumpPatches[High(FJumpPatches)].JmpSize := 4;
               EmitU8(FCode, $E8);  // call rel32
               EmitU32(FCode, 0);   // placeholder
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
         
         irCallStruct:
           begin
             // Struct-returning function call (SysV ABI)
             // Dest is a LOCAL slot index (not temp!), StructSize gives size in bytes
             // After call: RAX has first quadword, RDX has second (if StructSize > 8)
             argCount := instr.ImmInt;
             
             // Get argument temps from ArgTemps array
             SetLength(argTemps, argCount);
             for k := 0 to argCount - 1 do argTemps[k] := -1;
             if Length(instr.ArgTemps) > 0 then
             begin
               for k := 0 to Min(argCount - 1, High(instr.ArgTemps)) do
                 argTemps[k] := instr.ArgTemps[k];
             end;
             
             // Ensure stack is 16-byte aligned before call
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
               // Store RAX to first slot
               WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest), RAX);
               
               // For structs > 8 bytes, store RDX to second slot
               if instr.StructSize > 8 then
                 WriteMovMemReg(FCode, RBP, SlotOffset(instr.Dest + 1), RDX);
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
             // jne rel32
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
           end;
           
         irStoreElem:
           begin
             // Store element: array[index] = value
             // Src1 = array base address temp, Src2 = value temp, ImmInt = static index
             offset := instr.ImmInt * 8;  // 8 bytes per element
             
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
           end;
           
         irStoreElemDyn:
           begin
             // Store element dynamically: array[index] = value
             // Src1 = array base, Src2 = index, Src3 = value
             
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
            end;

          irLoadField:
            begin
              // Load field from struct: Dest = *(Src1 - ImmInt)
              // Stack slots grow negative, so we SUBTRACT the field offset
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
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
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RCX);
            end;

          irStoreField:
            begin
              // Store field into struct: *(Src1 - ImmInt) = Src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
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
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              if (instr.ImmInt >= -128) and (instr.ImmInt <= 127) then
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $48); EmitU8(FCode, Byte(instr.ImmInt));
              end
              else
              begin
                EmitU8(FCode, $48); EmitU8(FCode, $8B); EmitU8(FCode, $88);
                EmitU32(FCode, Cardinal(instr.ImmInt));
              end;
              WriteMovMemReg(FCode, RBP, SlotOffset(fn.LocalCount + instr.Dest), RCX);
            end;

          irStoreFieldHeap:
            begin
              // Store field into heap object: *(Src1 + ImmInt) = Src2
              WriteMovRegMem(FCode, RAX, RBP, SlotOffset(fn.LocalCount + instr.Src1));
              WriteMovRegMem(FCode, RCX, RBP, SlotOffset(fn.LocalCount + instr.Src2));
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
  
  if Length(FLeaPositions) > 0 then
  begin
    // Record current code size (where strings will start)
    mainPos := FCode.Size;
    
    // Copy strings from FData to end of FCode
    for i := 0 to High(FStringOffsets) do
    begin
      // Update FStringOffsets to point to code buffer position
      FStringOffsets[i] := FCode.Size;
    end;
    
    // Re-copy strings (they were already written to FData, now copy to FCode)
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
    // First, copy global variables from FData to end of FCode (after strings)
    // Record where globals start in code section
    mainPos := FCode.Size;
    
    // Update globalVarOffsets to point to code buffer position
    for i := 0 to globalVarNames.Count - 1 do
    begin
      globalVarOffsets[i] := FCode.Size;
      FCode.WriteU64LE(0);  // Initialize global to 0
    end;
    
    // Now patch all global variable LEA instructions
    for i := 0 to High(FGlobalVarLeaPositions) do
    begin
      // FGlobalVarLeaPositions[i].CodePos points to the start of "lea r, [rip + disp32]"
      // The disp32 is at CodePos + 3 (after 48 8D 05)
      // The instruction ends at CodePos + 7
      // RIP at execution time points to CodePos + 7
      // So: disp32 = target - (CodePos + 7)
      varIdx := FGlobalVarLeaPositions[i].VarIndex;
      
      if varIdx >= 10000 then
      begin
        // VMT reference - varIdx is FData offset + 10000
        // VMT data is NOT copied to code section, it stays in FData
        // This requires proper ELF section handling - for now, skip VMT patching
        // TODO: Implement proper VMT patching when data section is properly handled
      end
      else if (varIdx >= 0) and (varIdx < globalVarNames.Count) then
      begin
        // Regular global variable - use code section offset
        offset := globalVarOffsets[varIdx] - (FGlobalVarLeaPositions[i].CodePos + 7);
        FCode.PatchU32LE(FGlobalVarLeaPositions[i].CodePos + 3, Cardinal(offset));
      end;
    end;
  end;
  
  // Code-Größe für Energy-Stats aktualisieren
  FEnergyStats.CodeSizeBytes := FCode.Size;
  
  finally
    globalVarNames.Free;
  end;
end;

end.
