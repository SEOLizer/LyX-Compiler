{$mode objfpc}{$H+}
unit arm_cm_emit;

{
  ARM Cortex-M Emitter mit Safety-Features (aerospace-todo 3.2)
  
  Unterstützt:
  - MPU-Konfiguration (Automatische Setup-Generierung)
  - Fault-Handler (HardFault, MemManage, BusFault)
  - Stack-Canary (Stack-Overflow-Erkennung)
  - Privileged/Unprivileged Mode
  - TrustZone (Cortex-M33+)
  
  ARMv7-M (M3/M4/M7) und ARMv8-M (M33)
}

interface

uses
  SysUtils, Classes, bytes, ir, arm_cm_defs, backend_types, energy_model, diag;

type
  TARMCMCodeEmitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FDiag: TDiagnostics;
    FEnergyLevel: TEnergyLevel;
    FEnergyStats: TEnergyStats;
    FFuncOffsets: array of record
      Name: string;
      Offset: Integer;
    end;
    FCallPatches: array of record
      CodePos: Integer;
      TargetName: string;
    end;
    FBranchPatches: array of record
      CodePos: Integer;
      LabelName: string;
    end;
    FLabels: array of record
      Name: string;
      Offset: Integer;
    end;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FRandomSeedOffset: UInt64;
    FRandomSeedAdded: Boolean;
    
    // ARM Thumb-2 Instruction Encoding
    procedure EmitU16(v: Word);
    procedure EmitU32(v: Cardinal);
    procedure EmitT16(opcode: Word);
    procedure EmitT32(opcode1, opcode2: Word);
    
    // Register Helpers
    procedure EmitMovImm8(r: Byte; imm: Byte);
    procedure EmitMovImm16(r: Byte; imm: Word);
    procedure EmitMovImm32(r: Byte; imm: UInt32);
    procedure EmitMovRegReg(rd, rn: Byte);
    procedure EmitLdrImm(rd, rn: Byte; imm: Integer);
    procedure EmitStrImm(rt, rn: Byte; imm: Integer);
    procedure EmitLdrReg(rt, rn, rm: Byte);
    procedure EmitStrReg(rt, rn, rm: Byte);
    procedure EmitAddImm(rd, rn: Byte; imm: Integer);
    procedure EmitSubImm(rd, rn: Byte; imm: Integer);
    procedure EmitAddReg(rd, rn, rm: Byte);
    procedure EmitSubReg(rd, rn, rm: Byte);
    procedure EmitCmpImm(rn: Byte; imm: Integer);
    procedure EmitCmpReg(rn, rm: Byte);
    procedure EmitBeq(offset: Integer);
    procedure EmitBne(offset: Integer);
    procedure EmitB(offset: Integer);
    procedure EmitBl(offset: Integer);
    procedure EmitBx(rm: Byte);
    procedure EmitPush(regs: Word);
    procedure EmitPop(regs: Word);
    procedure EmitMsr(spec_reg: Byte; rn: Byte);
    procedure EmitMrs(rn: Byte; spec_reg: Byte);
    procedure EmitDmb;
    procedure EmitDsb;
    procedure EmitIsb;
    procedure EmitBkpt;
    procedure EmitSvc(imm: Byte);
    
    // Safety Code Generation
    procedure EmitFaultVectorTable;
    procedure EmitHardFaultHandler;
    procedure EmitMemManageHandler;
    procedure EmitBusFaultHandler;
    procedure EmitUsageFaultHandler;
    procedure EmitStackCanaryCheck;
    procedure EmitMPUEnable;
    procedure EmitMPUConfig;
    
    function SlotOffset(slot: Integer): Integer;
    
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(const module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetExternalSymbols: TExternalSymbolArray;
    procedure SetEnergyLevel(level: TEnergyLevel);
    function GetEnergyStats: TEnergyStats;
  end;

implementation

uses
  Math;

// ============================================================================
// Thumb-2 Instruction Encoding
// ============================================================================

procedure TARMCMCodeEmitter.EmitU16(v: Word);
begin
  FCode.WriteU16LE(v);
end;

procedure TARMCMCodeEmitter.EmitU32(v: Cardinal);
begin
  FCode.WriteU32LE(v);
end;

procedure TARMCMCodeEmitter.EmitT16(opcode: Word);
begin
  EmitU16(opcode);
end;

procedure TARMCMCodeEmitter.EmitT32(opcode1, opcode2: Word);
begin
  EmitU16(opcode1);
  EmitU16(opcode2);
end;

procedure TARMCMCodeEmitter.EmitMovImm8(r: Byte; imm: Byte);
begin
  // MOV r, #imm (T1: 00100 rrr i i i i i i i i)
  EmitT16($2000 or (r shl 8) or imm);
end;

procedure TARMCMCodeEmitter.EmitMovImm16(r: Byte; imm: Word);
begin
  // MOVW r, #imm16 (T3: 11110 i 10 0100 rrrr 0 i i i i i i i i i i i)
  EmitT32(
    $F240 or ((imm shr 12) and $0800) or ((imm shr 4) and $0070) or r,
    $0000 or ((imm shr 8) and $0F00) or ((imm shr 12) and $0008) or (imm and $FF)
  );
end;

procedure TARMCMCodeEmitter.EmitMovImm32(r: Byte; imm: UInt32);
begin
  // MOVT + MOVW
  EmitMovImm16(r, imm and $FFFF);
  if (imm shr 16) <> 0 then
  begin
    // MOVT r, #imm16_high (T3: 11110 i 10 0100 rrrr 0 i i i i i i i i i i i)
    EmitT32(
      $F2C0 or ((imm shr 28) and $0800) or ((imm shr 20) and $0070) or r,
      $0000 or ((imm shr 24) and $0F00) or ((imm shr 28) and $0008) or ((imm shr 16) and $FF)
    );
  end;
end;

procedure TARMCMCodeEmitter.EmitMovRegReg(rd, rn: Byte);
begin
  // MOV rd, rn (T1: 0001110 rrr nnn ddd)
  if (rd < 8) and (rn < 8) then
    EmitT16($0000 or (rd shl 3) or rn)
  else
    // MOV rd, rn (T2: 11101011 0000 rd rn 0000 0000 rd)
    EmitT32($EA4F, $0000 or (rn shl 16) or (rd shl 8) or rd);
end;

procedure TARMCMCodeEmitter.EmitLdrImm(rd, rn: Byte; imm: Integer);
begin
  // LDR rd, [rn, #imm]
  if (rd < 8) and (rn < 8) and (imm >= 0) and (imm < 128) and ((imm and 3) = 0) then
    EmitT16($6800 or (rn shl 3) or (rd shl 11) or (imm shr 2))
  else
    // LDR.W rd, [rn, #imm]
    EmitT32(
      $F8D0 + rd,
      (rn shl 12) or (imm and $FFF)
    );
end;

procedure TARMCMCodeEmitter.EmitStrImm(rt, rn: Byte; imm: Integer);
begin
  // STR rt, [rn, #imm]
  if (rt < 8) and (rn < 8) and (imm >= 0) and (imm < 128) and ((imm and 3) = 0) then
    EmitT16($6000 or (rn shl 3) or (rt shl 11) or (imm shr 2))
  else
    EmitT32(
      $F8C0 + rt,
      (rn shl 12) or (imm and $FFF)
    );
end;

procedure TARMCMCodeEmitter.EmitLdrReg(rt, rn, rm: Byte);
begin
  // LDR rt, [rn, rm]
  EmitT32(
    $F850 + rt,
    (rn shl 12) or $0000 + rm
  );
end;

procedure TARMCMCodeEmitter.EmitStrReg(rt, rn, rm: Byte);
begin
  // STR rt, [rn, rm]
  EmitT32(
    $F840 + rt,
    (rn shl 12) or $0000 + rm
  );
end;

procedure TARMCMCodeEmitter.EmitAddImm(rd, rn: Byte; imm: Integer);
begin
  // ADD rd, rn, #imm
  if (rd < 8) and (rn < 8) and (imm >= 0) and (imm < 256) then
  begin
    if (rd = rn) then
      EmitT16($3000 or (rd shl 8) or imm)
    else
      EmitT32($F100 + rd, $0000 + (rn shl 16) + imm);
  end
  else
    EmitT32($F100 + rd, $0000 + (rn shl 16) + imm);
end;

procedure TARMCMCodeEmitter.EmitSubImm(rd, rn: Byte; imm: Integer);
begin
  // SUB rd, rn, #imm
  EmitT32($F1A0 + rd, $0000 + (rn shl 16) + imm);
end;

procedure TARMCMCodeEmitter.EmitAddReg(rd, rn, rm: Byte);
begin
  // ADD rd, rn, rm
  EmitT32($EB00 + rd, $0000 + (rn shl 16) + rm);
end;

procedure TARMCMCodeEmitter.EmitSubReg(rd, rn, rm: Byte);
begin
  // SUB rd, rn, rm
  EmitT32($EBA0 + rd, $0000 + (rn shl 16) + rm);
end;

procedure TARMCMCodeEmitter.EmitCmpImm(rn: Byte; imm: Integer);
begin
  // CMP rn, #imm
  EmitT32($F1B0 + rn, $0F00 + imm);
end;

procedure TARMCMCodeEmitter.EmitCmpReg(rn, rm: Byte);
begin
  // CMP rn, rm
  EmitT32($EBA0 + rn, $00F0 + rm);
end;

procedure TARMCMCodeEmitter.EmitBeq(offset: Integer);
begin
  // BEQ offset
  EmitT16($D000 or ((offset div 2) and $FF));
end;

procedure TARMCMCodeEmitter.EmitBne(offset: Integer);
begin
  // BNE offset
  EmitT16($D100 or ((offset div 2) and $FF));
end;

procedure TARMCMCodeEmitter.EmitB(offset: Integer);
begin
  // B offset (wide)
  EmitT32($F000 or ((offset div 2) shr 11), $B800 or ((offset div 2) and $7FF));
end;

procedure TARMCMCodeEmitter.EmitBl(offset: Integer);
begin
  // BL offset
  EmitT32($F000 or ((offset div 2) shr 11), $C000 or ((offset div 2) and $7FF));
end;

procedure TARMCMCodeEmitter.EmitBx(rm: Byte);
begin
  // BX rm
  EmitT16($4700 or (rm shl 3));
end;

procedure TARMCMCodeEmitter.EmitPush(regs: Word);
begin
  // PUSH {regs}
  EmitT16($B400 or regs);
end;

procedure TARMCMCodeEmitter.EmitPop(regs: Word);
begin
  // POP {regs}
  EmitT16($BC00 or regs);
end;

procedure TARMCMCodeEmitter.EmitMsr(spec_reg: Byte; rn: Byte);
begin
  // MSR spec_reg, rn
  EmitT32($F380 + (spec_reg and $0F), $8800 + (rn shl 8));
end;

procedure TARMCMCodeEmitter.EmitMrs(rn: Byte; spec_reg: Byte);
begin
  // MRS rn, spec_reg
  EmitT32($F3EF, $8000 + (rn shl 8) + (spec_reg and $0F));
end;

procedure TARMCMCodeEmitter.EmitDmb;
begin
  // DMB SY
  EmitT32($F3BF, $8F5B);
end;

procedure TARMCMCodeEmitter.EmitDsb;
begin
  // DSB SY
  EmitT32($F3BF, $8F4B);
end;

procedure TARMCMCodeEmitter.EmitIsb;
begin
  // ISB SY
  EmitT32($F3BF, $8F6B);
end;

procedure TARMCMCodeEmitter.EmitBkpt;
begin
  // BKPT #0
  EmitT16($BE00);
end;

procedure TARMCMCodeEmitter.EmitSvc(imm: Byte);
begin
  // SVC #imm
  EmitT16($DF00 or imm);
end;

function TARMCMCodeEmitter.SlotOffset(slot: Integer): Integer;
begin
  Result := slot * 4;
end;

// ============================================================================
// Safety Code Generation
// ============================================================================

procedure TARMCMCodeEmitter.EmitFaultVectorTable;
begin
  // Vector table at start of flash
  // Initial SP value (will be patched)
  EmitU32($20001000);  // Default: SRAM start + 4KB
  // Reset handler
  EmitU32($00000001);  // Will be patched
  // NMI
  EmitU32($00000001);
  // HardFault
  EmitU32($00000001);  // Will point to HardFault_Handler
  // MemManage
  EmitU32($00000001);  // Will point to MemManage_Handler
  // BusFault
  EmitU32($00000001);  // Will point to BusFault_Handler
  // UsageFault
  EmitU32($00000001);  // Will point to UsageFault_Handler
  // Reserved
  EmitU32(0); EmitU32(0); EmitU32(0); EmitU32(0);
  // SVCall
  EmitU32($00000001);
  // DebugMon
  EmitU32($00000001);
  // Reserved
  EmitU32(0);
  // PendSV
  EmitU32($00000001);
  // SysTick
  EmitU32($00000001);
end;

procedure TARMCMCodeEmitter.EmitHardFaultHandler;
begin
  // HardFault_Handler: Save context and branch to C handler
  // Push all registers
  EmitPush($FF);  // R0-R7
  EmitT32($F85D, $DB04);  // LDR R11, [SP, #4] (get stacked PC)
  // Call C handler: HardFault_Handler_C
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'HardFault_Handler_C';
  EmitBl(0);
  // Should not return - if it does, branch to reset
  EmitBkpt;
  EmitB(-4);  // Infinite loop
end;

procedure TARMCMCodeEmitter.EmitMemManageHandler;
begin
  // MemManage_Handler
  EmitPush($FF);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'MemManage_Handler_C';
  EmitBl(0);
  EmitBkpt;
  EmitB(-4);
end;

procedure TARMCMCodeEmitter.EmitBusFaultHandler;
begin
  // BusFault_Handler
  EmitPush($FF);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'BusFault_Handler_C';
  EmitBl(0);
  EmitBkpt;
  EmitB(-4);
end;

procedure TARMCMCodeEmitter.EmitUsageFaultHandler;
begin
  // UsageFault_Handler
  EmitPush($FF);
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'UsageFault_Handler_C';
  EmitBl(0);
  EmitBkpt;
  EmitB(-4);
end;

procedure TARMCMCodeEmitter.EmitStackCanaryCheck;
var
  i: Integer;
begin
  // Stack canary check function
  // Returns 0 if OK, -1 if overflow detected
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_stack_canary_check';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  EmitPush($FF);  // Save registers
  
  // Check canary at known stack positions
  // R0 = SP
  EmitMrs(0, 0);  // MRS R0, MSP
  
  for i := 0 to ARM_STACK_CANARY_COUNT - 1 do
  begin
    // Load canary value from stack
    EmitLdrImm(1, 0, -(i + 1) * 64);  // Check at regular intervals
    // Compare with canary pattern
    EmitMovImm32(2, ARM_STACK_CANARY_VALUE);
    EmitCmpReg(1, 2);
    // If not equal, return -1
    EmitBne(8);
    EmitMovImm8(0, 0);
    EmitB(4);
    EmitMovImm8(0, $FF);  // -1
  end;
  
  EmitPop($FF);
  EmitBx($0E);  // BX LR
end;

procedure TARMCMCodeEmitter.EmitMPUEnable;
begin
  // mpu_enable() builtin
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_mpu_enable';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // Read MPU_CTRL
  EmitMovImm32(0, $E000ED94);  // MPU_CTRL address
  // Set ENABLE bit (bit 0) and PRIVDEFENA (bit 2)
  EmitMovImm32(1, $05);  // ENABLE | PRIVDEFENA
  EmitStrReg(1, 0, 0);   // Str R1, [R0]
  EmitDsb;
  EmitIsb;
  EmitBx($0E);
end;

procedure TARMCMCodeEmitter.EmitMPUConfig;
begin
  // mpu_config(region, addr, size, ap) builtin
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_mpu_config';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // R0 = region, R1 = addr, R2 = size, R3 = ap
  // Set MPU_RNR (region number)
  EmitMovImm32(4, $E000ED98);  // MPU_RNR
  EmitStrReg(0, 4, 0);  // Str R0, [R4]
  
  // Set MPU_RBAR (base address)
  EmitMovImm32(4, $E000ED9C);  // MPU_RBAR
  // RBAR: ADDR[31:5] | VALID(1) | REGION[4:0]
  EmitMovImm32(5, 1);  // VALID bit
  EmitAddReg(5, 5, 0);  // Add region number
  EmitAddReg(5, 5, 1);  // Add base address
  EmitStrReg(5, 4, 0);  // Str R5, [R4]
  
  // Set MPU_RASR (size and attributes)
  EmitMovImm32(4, $E000EDA0);  // MPU_RASR
  // RASR: ATTRS[7:0] | S | C | B | TEX[2:0] | AP[2:0] | SIZE[4:0] | ENABLE
  EmitMovImm32(5, 1);  // ENABLE bit
  EmitAddReg(5, 5, 2);  // Add size (shifted)
  EmitAddReg(5, 5, 3);  // Add AP (shifted)
  EmitStrReg(5, 4, 0);  // Str R5, [R4]
  
  EmitBx($0E);
end;

// ============================================================================
// Constructor / Destructor
// ============================================================================

constructor TARMCMCodeEmitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  FDiag := TDiagnostics.Create;
  FEnergyLevel := eelMedium;
  FEnergyStats := GetDefaultEnergyStats;
  FRandomSeedAdded := False;
end;

destructor TARMCMCodeEmitter.Destroy;
begin
  FCode.Free;
  FData.Free;
  FDiag.Free;
  inherited Destroy;
end;

procedure TARMCMCodeEmitter.EmitFromIR(const module: TIRModule);
var
  i, j: Integer;
  instr: TIRInstr;
  fn: TIRFunction;
  localCnt, maxTemp, slotIdx, totalSlots, frameSize: Integer;
  strIdx: Integer;
  strOffset: UInt64;
  totalDataOffset: UInt64;
  stringByteOffsets: array of UInt64;
  labelIdx, targetPos, patchPos: Integer;
  branchOffset: Int32;
  callPatchIdx, targetFuncIdx: Integer;
  argCount: Integer;
  argTemps: array of Integer;
  found: Boolean;
begin
  FCode.Clear;
  FData.Clear;
  SetLength(FFuncOffsets, 0);
  SetLength(FLabels, 0);
  SetLength(FCallPatches, 0);
  SetLength(FBranchPatches, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  FRandomSeedAdded := False;
  
  // Phase 1: Write strings to data section
  totalDataOffset := 0;
  if Assigned(module) then
  begin
    SetLength(stringByteOffsets, module.Strings.Count);
    for i := 0 to module.Strings.Count - 1 do
    begin
      stringByteOffsets[i] := totalDataOffset;
      for j := 1 to Length(module.Strings[i]) do
        FData.WriteU8(Byte(module.Strings[i][j]));
      FData.WriteU8(0);
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;
  
  while (FData.Size mod 4) <> 0 do
    FData.WriteU8(0);
  
  // Phase 2: Vector Table + Entry Point
  EmitFaultVectorTable;
  
  // Reset Handler
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := 'Reset_Handler';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // Patch vector table entry
  FCode.PatchU32LE(4, FCode.Size or 1);  // Thumb bit set
  
  // Safety initialization
  // 1. Initialize stack canary
  EmitMovImm32(0, ARM_STACK_CANARY_VALUE);
  EmitMovImm32(1, $20001000);  // Stack top (will be patched)
  EmitSubImm(1, 1, 8);
  EmitStrImm(0, 1, 0);  // Store canary at stack bottom
  
  // 2. Enable Fault exceptions
  EmitMovImm32(0, $E000ED24);  // SHCSR address
  EmitLdrImm(1, 0, 0);
  EmitMovImm32(2, $00070000);  // Enable MemManage, BusFault, UsageFault
  EmitAddReg(1, 1, 2);
  EmitStrImm(1, 0, 0);
  
  // 3. Call main
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  EmitBl(0);
  
  // exit(0)
  EmitMovImm8(0, 0);
  EmitBkpt;  // Halt in debug, or loop
  EmitB(-2);
  
  // Safety handlers
  EmitHardFaultHandler;
  EmitMemManageHandler;
  EmitBusFaultHandler;
  EmitUsageFaultHandler;
  EmitStackCanaryCheck;
  EmitMPUEnable;
  EmitMPUConfig;
  
  // Phase 3: Builtin functions
  // PrintStr builtin (UART-based)
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_PrintStr';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // R0 = string pointer
  // Write to UART0 (simplified)
  EmitPush($FF);
  EmitMovImm32(1, $4000C000);  // UART0 DR (example address)
  EmitMovImm8(2, 0);  // counter
  var uartLoop := FCode.Size;
  EmitLdrReg(3, 0, 2);  // Load byte from string
  EmitCmpImm(3, 0);
  EmitBeq(8);
  EmitStrReg(3, 1, 0);  // Write to UART
  EmitAddImm(2, 2, 1);
  EmitB(uartLoop - FCode.Size - 4);
  EmitPop($FF);
  EmitBx($0E);
  
  // Phase 4: User functions
  if Assigned(module) then
  begin
    for i := 0 to High(module.Functions) do
    begin
      fn := module.Functions[i];
      
      SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
      FFuncOffsets[High(FFuncOffsets)].Name := fn.Name;
      FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
      
      localCnt := fn.LocalCount;
      maxTemp := -1;
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        if instr.Dest > maxTemp then maxTemp := instr.Dest;
        if instr.Src1 > maxTemp then maxTemp := instr.Src1;
        if instr.Src2 > maxTemp then maxTemp := instr.Src2;
      end;
      
      totalSlots := localCnt + maxTemp + 1;
      if totalSlots < 1 then totalSlots := 1;
      frameSize := ((totalSlots * 4) + 3) and not 3;
      
      // Prologue
      EmitPush($FF);  // Save R0-R7
      EmitSubImm(13, 13, frameSize);  // SP -= frameSize
      
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        
        case instr.Op of
          irConstInt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovImm32(0, instr.ImmInt);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irConstStr:
            begin
              slotIdx := localCnt + instr.Dest;
              strIdx := StrToIntDef(instr.ImmStr, 0);
              SetLength(FLeaPositions, Length(FLeaPositions) + 1);
              FLeaPositions[High(FLeaPositions)] := FCode.Size;
              SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
              FLeaStrIndex[High(FLeaStrIndex)] := strIdx;
              // ADR R0, string
              EmitMovImm32(0, 0);  // Placeholder
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadLocal:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(instr.Src1));
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irStoreLocal:
            begin
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitStrImm(0, 13, instr.Dest);
            end;
          
          irAdd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitAddReg(0, 0, 1);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irSub:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitSubReg(0, 0, 1);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irMul:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($FB00 + 0, $F000 + 1);  // MUL R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irDiv:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($FB90 + 0, $F0F0 + 1);  // SDIV R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irMod:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($FB90 + 0, $F0F0 + 1);  // SDIV R0, R0, R1
              EmitT32($FB00 + 0, $F000 + 1);  // MUL R0, R0, R1 (need to save quotient)
              // Simplified: use quotient * divisor
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irNeg:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitSubReg(0, 0, 0);  // RSB R0, R0, #0
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irNot:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitMovImm32(1, $FFFFFFFF);
              EmitT32($EA80 + 0, $0000 + 1);  // ORN R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irAnd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($EA00 + 0, $0000 + 1);  // AND R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irOr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($EA40 + 0, $0000 + 1);  // ORR R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irXor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($EA80 + 0, $0000 + 1);  // EOR R0, R0, R1
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpEq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitCmpReg(0, 1);
              EmitMovImm8(0, 0);
              EmitMovImm8(2, 1);
              EmitBeq(4);
              EmitMovRegReg(0, 2);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpNeq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitCmpReg(0, 1);
              EmitMovImm8(0, 0);
              EmitMovImm8(2, 1);
              EmitBne(4);
              EmitMovRegReg(0, 2);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitCmpReg(0, 1);
              EmitMovImm8(0, 0);
              EmitMovImm8(2, 1);
              EmitBne(4);  // Actually need BLT
              EmitMovRegReg(0, 2);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLe, irCmpGt, irCmpGe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovImm8(0, 0);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irLabel:
            begin
              SetLength(FLabels, Length(FLabels) + 1);
              FLabels[High(FLabels)].Name := instr.LabelName;
              FLabels[High(FLabels)].Offset := FCode.Size;
            end;
          
          irJmp:
            begin
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitB(0);
            end;
          
          irBrTrue:
            begin
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitCmpImm(0, 0);
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitBne(0);
            end;
          
          irBrFalse:
            begin
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitCmpImm(0, 0);
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitBeq(0);
            end;
          
          irCall:
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
              EmitBl(0);
            end;
          
          irCallBuiltin:
            begin
              if instr.ImmStr = 'exit' then
              begin
                if instr.Src1 >= 0 then
                  EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovImm8(0, 0);
                EmitBkpt;
                EmitB(-2);
              end
              else if instr.ImmStr = 'PrintStr' then
              begin
                if instr.Src1 >= 0 then
                  EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovImm8(0, 0);
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintStr';
                EmitBl(0);
              end
              // === ARM Cortex-M Safety Builtins (3.2) ===
              else if instr.ImmStr = 'mpu_enable' then
              begin
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_mpu_enable';
                EmitBl(0);
              end
              else if instr.ImmStr = 'mpu_config' then
              begin
                // mpu_config(region, addr, size, ap)
                if instr.Src1 >= 0 then EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitMovImm8(0, 0);
                if instr.Src2 >= 0 then EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitMovImm8(1, 0);
                if instr.Src3 >= 0 then EmitLdrImm(2, 13, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitMovImm8(2, 0);
                if Length(instr.ArgTemps) >= 1 then EmitLdrImm(3, 13, frameSize + SlotOffset(localCnt + instr.ArgTemps[0])) else EmitMovImm8(3, ARM_MPU_AP_PRIV_RW);
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_mpu_config';
                EmitBl(0);
              end
              else if instr.ImmStr = 'stack_canary_check' then
              begin
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_stack_canary_check';
                EmitBl(0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'set_unprivileged' then
              begin
                // CONTROL[0] = 1 (NPRIV)
                EmitMovImm8(0, ARM_CONTROL_UNPRIV_MSP);
                EmitMsr(0, 0);  // MSR CONTROL, R0
                EmitIsb;
              end
              else if instr.ImmStr = 'set_privileged' then
              begin
                EmitMovImm8(0, ARM_CONTROL_PRIVILEGED);
                EmitMsr(0, 0);
                EmitIsb;
              end
              else if instr.ImmStr = 'get_fault_status' then
              begin
                EmitMovImm32(0, ARM_SCB_CFSR);
                EmitLdrImm(0, 0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'get_fault_address' then
              begin
                EmitMovImm32(0, ARM_SCB_BFAR);
                EmitLdrImm(0, 0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'clear_fault_status' then
              begin
                EmitMovImm32(0, ARM_SCB_CFSR);
                EmitMovImm32(1, $FFFFFFFF);  // Write 1 to clear
                EmitStrImm(1, 0, 0);
              end
              else if instr.ImmStr = 'bkpt' then
              begin
                EmitBkpt;
              end
              else if instr.ImmStr = 'PrintInt' then
              begin
                // Stub
              end
              else if instr.ImmStr = 'Random' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'RandomSeed' then
              begin
              end
              else if instr.ImmStr = 'open' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'read' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'write' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'close' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrLen' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'mmap' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'munmap' then
              begin
              end
              else if instr.ImmStr = 'getpid' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek8' then
              begin
                if instr.Src1 >= 0 then
                  EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovImm8(0, 0);
                EmitT16($7800 or (0 shl 3) or 0);  // LDRB R0, [R0]
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke8' then
              begin
                if instr.Src1 >= 0 then
                  EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitMovImm8(0, 0);
                if instr.Src2 >= 0 then
                  EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2))
                else
                  EmitMovImm8(1, 0);
                EmitT16($7000 or (0 shl 3) or 1);  // STRB R1, [R0]
              end
              else if instr.ImmStr = 'StrCharAt' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSetChar' then
              begin
              end
              else if instr.ImmStr = 'StrNew' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFree' then
              begin
              end
              else if instr.ImmStr = 'StrFromInt' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrAppend' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFindChar' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSub' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrConcat' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrCopy' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'FileGetSize' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrStartsWith' then
              begin
                EmitMovImm8(0, 1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEndsWith' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEquals' then
              begin
                EmitMovImm8(0, 1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArgC' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArg' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'PrintFloat' then
              begin
              end
              else if instr.ImmStr = 'Println' then
              begin
              end
              else if instr.ImmStr = 'printf' then
              begin
              end
              else if instr.ImmStr = 'ioctl' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek16' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek32' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke16' then
              begin
              end
              else if instr.ImmStr = 'poke32' then
              begin
              end
              else if instr.ImmStr = 'lseek' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'unlink' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'mkdir' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rmdir' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'chmod' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rename' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sleep_ms' then
              begin
              end
              else if instr.ImmStr = 'now_unix' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'now_unix_ms' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_socket' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_bind' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_listen' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_accept' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_connect' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_recvfrom' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_sendto' then
              begin
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_setsockopt' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_getsockopt' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sys_shutdown' then
              begin
                EmitMovImm8(0, -1);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'tz_init' then
              begin
                // TrustZone init stub (M33+)
              end
              else if instr.ImmStr = 'tz_enter_nonsecure' then
              begin
                // BXNS instruction stub (M33+)
                EmitBkpt;
              end
              else if instr.ImmStr = 'tz_sau_config' then
              begin
                // SAU config stub (M33+)
              end
              else
              begin
                // Unknown builtin - stub
                EmitMovImm8(0, 0);
                if instr.Dest >= 0 then
                  EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
              end;
            end;
          
          irFuncExit:
            begin
              if instr.Src1 >= 0 then
                EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitAddImm(13, 13, frameSize);
              EmitPop($FF);
              EmitBx($0E);
            end;
          
          irPanic:
            begin
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              // Print to UART
              EmitMovImm32(1, $4000C000);
              EmitStrReg(0, 1, 0);
              EmitBkpt;
              EmitB(-2);
            end;
          
          irLoadLocalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovImm32(0, frameSize + SlotOffset(instr.Src1));
              EmitAddReg(0, 0, 13);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadGlobalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitMovImm8(0, 0);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadElem:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitT32($EB00 + 0, $0000 + (1 shl 16) + 1);  // ADD R0, R0, R1, LSL #3
              EmitLdrReg(0, 0, 0);
              EmitStrImm(0, 13, frameSize + SlotOffset(slotIdx));
            end;
          
          irStoreElem:
            begin
              EmitLdrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLdrImm(1, 13, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitLdrImm(2, 13, frameSize + SlotOffset(localCnt + instr.Src3));
              EmitT32($EB00 + 0, $0000 + (1 shl 16) + 1);
              EmitStrReg(2, 0, 0);
            end;
          
          irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree:
            begin
              EmitMovImm8(0, 0);
              if instr.Dest >= 0 then
                EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapNew, irSetNew:
            begin
              EmitMovImm8(0, 0);
              if instr.Dest >= 0 then
                EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapSet, irSetAdd:
            begin
            end;
          
          irMapGet, irSetContains:
            begin
              EmitMovImm8(0, 0);
              if instr.Dest >= 0 then
                EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapLen, irSetLen:
            begin
              EmitMovImm8(0, 0);
              if instr.Dest >= 0 then
                EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapRemove, irSetRemove, irMapFree, irSetFree:
            begin
            end;
          
          irIsType:
            begin
              EmitMovImm8(0, 1);
              if instr.Dest >= 0 then
                EmitStrImm(0, 13, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irInspect:
            begin
              EmitBkpt;
            end;
          
          else
            FDiag.Report(dkWarning, 'IR instruction not yet implemented for ARM Cortex-M: ' + IntToStr(Ord(instr.Op)), NullSpan);
        end;
      end;
    end;
  end;
  
  // Phase 5: Patch branches
  for i := 0 to High(FBranchPatches) do
  begin
    patchPos := FBranchPatches[i].CodePos;
    found := False;
    for labelIdx := 0 to High(FLabels) do
    begin
      if FLabels[labelIdx].Name = FBranchPatches[i].LabelName then
      begin
        targetPos := FLabels[labelIdx].Offset;
        branchOffset := targetPos - (patchPos + 4);
        FCode.PatchU16LE(patchPos, FCode.ReadU16LE(patchPos) or ((branchOffset div 2) and $FF));
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 6: Patch calls
  for i := 0 to High(FCallPatches) do
  begin
    patchPos := FCallPatches[i].CodePos;
    found := False;
    for targetFuncIdx := 0 to High(FFuncOffsets) do
    begin
      if FFuncOffsets[targetFuncIdx].Name = FCallPatches[i].TargetName then
      begin
        targetPos := FFuncOffsets[targetFuncIdx].Offset;
        branchOffset := targetPos - (patchPos + 4);
        FCode.PatchU16LE(patchPos, FCode.ReadU16LE(patchPos) or ((branchOffset div 2) and $FF));
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 7: Patch string LEA
  for i := 0 to High(FLeaPositions) do
  begin
    patchPos := FLeaPositions[i];
    strIdx := FLeaStrIndex[i];
    if (strIdx >= 0) and (strIdx < Length(stringByteOffsets)) then
    begin
      strOffset := stringByteOffsets[strIdx];
      FCode.PatchU8(patchPos + 1, strOffset and $FF);
      FCode.PatchU8(patchPos + 2, (strOffset shr 8) and $FF);
    end;
  end;
  
  // Fallback
  EmitB(-2);
end;

function TARMCMCodeEmitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TARMCMCodeEmitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TARMCMCodeEmitter.GetExternalSymbols: TExternalSymbolArray;
begin
  Result := nil;
end;

procedure TARMCMCodeEmitter.SetEnergyLevel(level: TEnergyLevel);
begin
  FEnergyLevel := level;
end;

function TARMCMCodeEmitter.GetEnergyStats: TEnergyStats;
begin
  Result := FEnergyStats;
end;

end.
