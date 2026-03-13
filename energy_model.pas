{$mode objfpc}{$H+}
unit energy_model;

interface

uses
  SysUtils, backend_types;

type
  { Detailed instruction energy costs (in arbitrary units, normalized to ALU ops) }
  TInstructionEnergyCost = record
    ALU_OPS: array[0..15] of UInt64;     // Basic ALU ops (add, sub, etc.)
    FPU_OPS: array[0..15] of UInt64;     // Floating point ops (SSE, AVX)
    SIMD_OPS: array[0..31] of UInt64;    // SIMD ops (AVX, AVX-512)
    MEMORY_OPS: array[0..15] of UInt64;  // Memory ops (load, store, cache levels)
    BRANCH_OPS: array[0..7] of UInt64;   // Branch ops
    SYS_CALL_COST: UInt64;               // System call cost
    L1_CACHE_HIT_COST: UInt64;
    L2_CACHE_HIT_COST: UInt64;
    L3_CACHE_HIT_COST: UInt64;
    DRAM_ACCESS_COST: UInt64;
  end;

  { Realistic CPU energy models }
  TCPUEnergyModel = record
    Family: TCPUFamily;
    CoreFrequency: Single;  // GHz
    TDP: Single;            // Thermal Design Power (Watts)
    InstructionCosts: TInstructionEnergyCost;
    CacheSizes: record
      L1Data: UInt64;
      L1Instruction: UInt64;
      L2: UInt64;
      L3: UInt64;
    end;
    HasAVX512: Boolean;
    HasAVX2: Boolean;
    HasSSE41: Boolean;
    HasAVX: Boolean;
  end;

  { Extended energy statistics with detailed breakdown }
  TEnergyStats = record
    TotalALUOps, TotalFPUOps, TotalSIMDOps, TotalMemoryAccesses: UInt64;
    TotalBranches, TotalSyscalls, EstimatedEnergyUnits: UInt64;
    CodeSizeBytes, L1CacheFootprint: UInt64;
    DetailedBreakdown: array of record
      OperationType: string;
      Count: UInt64;
      EnergyCost: UInt64;
    end;
  end;

  { Enhanced energy configuration }
  TEnergyConfig = record
    Level: TEnergyLevel;
    CPUFamily: TCPUFamily;
    OptimizeForBattery, AvoidSIMD, AvoidFPU: Boolean;
    PrioritizeCacheLocality, EnableIOWarnings: Boolean;
    MaxLoopUnroll: Integer;
    PreferInline, UseFixedPointInsteadOfFloat: Boolean;
    EnableLoopTiling, BatchIOOperations: Boolean;
    // Energy-aware specific settings
    AllowAVX512: Boolean;
    AllowAVX2: Boolean;
    AllowSSE: Boolean;
    PreferRegisterOverMemory: Boolean;
    EnableLoopUnrolling: Boolean;
    UseFixedPointForConstants: Boolean;
  end;

  { Energy-aware instruction selection context }
  TEnergyContext = record
    Config: TEnergyConfig;
    CurrentCPU: TCPUEnergyModel;
    AvailableAlternatives: array of record
      Instruction: string;
      EnergyCost: UInt64;
      Latency: Integer;
      Throughput: Integer;
    end;
  end;

function GetDefaultEnergyStats: TEnergyStats;

{ Predefined CPU energy models }
const
  // Intel Core i7-10710U (15W TDP, 6 cores, up to 4.7GHz)
  CPU_MODEL_INTEL_CORE_I7_10710U: TCPUEnergyModel = (
    Family: cfX86_64;
    CoreFrequency: 1.1;
    TDP: 15.0;
    InstructionCosts: (
      ALU_OPS: (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
      FPU_OPS: (3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3);
      SIMD_OPS: (5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
                 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8);
      MEMORY_OPS: (100, 100, 100, 100, 100, 100, 100, 100,
                   100, 100, 100, 100, 100, 100, 100, 100);
      BRANCH_OPS: (50, 50, 50, 50, 50, 50, 50, 50);
      SYS_CALL_COST: 5000;
      L1_CACHE_HIT_COST: 1;
      L2_CACHE_HIT_COST: 5;
      L3_CACHE_HIT_COST: 20;
      DRAM_ACCESS_COST: 100;
    );
    CacheSizes: (
      L1Data: 6 * 32 * 1024;
      L1Instruction: 6 * 32 * 1024;
      L2: 6 * 512 * 1024;
      L3: 12 * 1024 * 1024
    );
    HasAVX512: False;
    HasAVX2: True;
    HasSSE41: True;
    HasAVX: True;
  );

  // AMD Ryzen 7 4700U (15W TDP, 8 cores, up to 4.1GHz)
  CPU_MODEL_AMD_RYZEN_7_4700U: TCPUEnergyModel = (
    Family: cfX86_64;
    CoreFrequency: 1.2;
    TDP: 15.0;
    InstructionCosts: (
      ALU_OPS: (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
      FPU_OPS: (3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3);
      SIMD_OPS: (5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
                 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8);
      MEMORY_OPS: (100, 100, 100, 100, 100, 100, 100, 100,
                   100, 100, 100, 100, 100, 100, 100, 100);
      BRANCH_OPS: (50, 50, 50, 50, 50, 50, 50, 50);
      SYS_CALL_COST: 5000;
      L1_CACHE_HIT_COST: 1;
      L2_CACHE_HIT_COST: 5;
      L3_CACHE_HIT_COST: 20;
      DRAM_ACCESS_COST: 100;
    );
    CacheSizes: (
      L1Data: 8 * 32 * 1024;
      L1Instruction: 8 * 32 * 1024;
      L2: 8 * 512 * 1024;
      L3: 8 * 1024 * 1024
    );
    HasAVX512: False;
    HasAVX2: True;
    HasSSE41: True;
    HasAVX: True;
  );

  // Intel Atom x5-Z8350 (2W TDP, 4 cores, up to 1.92GHz) - Low power
  CPU_MODEL_INTEL_ATOM_X5_Z8350: TCPUEnergyModel = (
    Family: cfX86_64;
    CoreFrequency: 1.44;
    TDP: 2.0;
    InstructionCosts: (
      ALU_OPS: (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
      FPU_OPS: (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4);
      SIMD_OPS: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      MEMORY_OPS: (150, 150, 150, 150, 150, 150, 150, 150,
                   150, 150, 150, 150, 150, 150, 150, 150);
      BRANCH_OPS: (70, 70, 70, 70, 70, 70, 70, 70);
      SYS_CALL_COST: 7000;
      L1_CACHE_HIT_COST: 1;
      L2_CACHE_HIT_COST: 8;
      L3_CACHE_HIT_COST: 30;
      DRAM_ACCESS_COST: 150;
    );
    CacheSizes: (
      L1Data: 4 * 24 * 1024;
      L1Instruction: 4 * 24 * 1024;
      L2: 4 * 1 * 1024 * 1024;
      L3: 2 * 1024 * 1024
    );
    HasAVX512: False;
    HasAVX2: False;
    HasSSE41: True;
    HasAVX: False;
   );

{ Energy estimation functions }
function EstimateTotalEnergy(const stats: TEnergyStats): UInt64;
function EstimateL1CacheFootprint(codeSizeBytes: UInt64): UInt64;
function GetCPUEnergyModel(cpuFamily: TCPUFamily): TCPUEnergyModel;
function SelectEnergyEfficientInstruction(const context: TEnergyContext; const alternatives: array of string): string;
function GetEnergyConfig: TEnergyConfig;
procedure SetEnergyLevel(level: TEnergyLevel; cpuFamily: TCPUFamily);
procedure ResetEnergyConfig;

implementation

function GetDefaultEnergyStats: TEnergyStats;
begin
  FillChar(Result, SizeOf(TEnergyStats), 0);
  SetLength(Result.DetailedBreakdown, 0);
end;

var
  CurrentEnergyConfig: TEnergyConfig;

function GetCPUEnergyModel(cpuFamily: TCPUFamily): TCPUEnergyModel;
begin
  case cpuFamily of
    cfX86_64:
      begin
        // Default to Intel Core i7-10710U for x86_64
        Result := CPU_MODEL_INTEL_CORE_I7_10710U;
      end;
    cfARM64: Result := CPU_MODEL_AMD_RYZEN_7_4700U; // Fallback
    cfARMCortexM, cfARMCortexA: Result := CPU_MODEL_INTEL_ATOM_X5_Z8350;
    else Result := CPU_MODEL_INTEL_CORE_I7_10710U;
  end;
end;

function EstimateTotalEnergy(const stats: TEnergyStats): UInt64;
var
  cpuModel: TCPUEnergyModel;
begin
  cpuModel := GetCPUEnergyModel(CurrentEnergyConfig.CPUFamily);
  
  Result := stats.TotalALUOps * cpuModel.InstructionCosts.ALU_OPS[0] +
            stats.TotalFPUOps * cpuModel.InstructionCosts.FPU_OPS[0] +
            stats.TotalSIMDOps * cpuModel.InstructionCosts.SIMD_OPS[0] +
            stats.TotalMemoryAccesses * cpuModel.InstructionCosts.DRAM_ACCESS_COST +
            stats.TotalBranches * cpuModel.InstructionCosts.BRANCH_OPS[0] +
            stats.TotalSyscalls * cpuModel.InstructionCosts.SYS_CALL_COST;
end;

function EstimateL1CacheFootprint(codeSizeBytes: UInt64): UInt64;
var
  cpuModel: TCPUEnergyModel;
  cacheSize: UInt64;
begin
  cpuModel := GetCPUEnergyModel(CurrentEnergyConfig.CPUFamily);

  case CurrentEnergyConfig.CPUFamily of
    cfX86_64: cacheSize := cpuModel.CacheSizes.L1Data;
    cfARM64: cacheSize := cpuModel.CacheSizes.L1Data;
    else cacheSize := 32 * 1024;
  end;

  if codeSizeBytes >= cacheSize then
    Result := cacheSize
  else
    Result := codeSizeBytes;
end;

function GetEnergyConfig: TEnergyConfig;
begin
  Result := CurrentEnergyConfig;
end;

procedure SetEnergyLevel(level: TEnergyLevel; cpuFamily: TCPUFamily);
var
  cpuModel: TCPUEnergyModel;
begin
  CurrentEnergyConfig.Level := level;
  CurrentEnergyConfig.CPUFamily := cpuFamily;

  cpuModel := GetCPUEnergyModel(cpuFamily);
  
  CurrentEnergyConfig.OptimizeForBattery := (level >= eelMinimal);
  CurrentEnergyConfig.AvoidSIMD := (level >= eelMedium);
  CurrentEnergyConfig.AvoidFPU := (level >= eelHigh);
  CurrentEnergyConfig.PrioritizeCacheLocality := (level >= eelMinimal);
  CurrentEnergyConfig.EnableIOWarnings := (level >= eelLow);
  CurrentEnergyConfig.PreferInline := (level >= eelMinimal);
  CurrentEnergyConfig.BatchIOOperations := (level >= eelLow);
  CurrentEnergyConfig.UseFixedPointInsteadOfFloat := (level >= eelHigh);
  CurrentEnergyConfig.AllowAVX512 := (level = eelExtreme) and cpuModel.HasAVX512;
  CurrentEnergyConfig.AllowAVX2 := (level >= eelMedium) and cpuModel.HasAVX2;
  CurrentEnergyConfig.AllowSSE := (level >= eelLow) and cpuModel.HasSSE41;
  CurrentEnergyConfig.PreferRegisterOverMemory := (level >= eelMinimal);
  CurrentEnergyConfig.EnableLoopUnrolling := (level >= eelMedium);
  CurrentEnergyConfig.UseFixedPointForConstants := (level >= eelHigh);
  
  case level of
    eelMinimal: CurrentEnergyConfig.MaxLoopUnroll := 4;
    eelLow: CurrentEnergyConfig.MaxLoopUnroll := 2;
    eelMedium: CurrentEnergyConfig.MaxLoopUnroll := 1;
    eelHigh: CurrentEnergyConfig.MaxLoopUnroll := 0;
    eelExtreme: CurrentEnergyConfig.MaxLoopUnroll := 8;
    else CurrentEnergyConfig.MaxLoopUnroll := 0;
  end;
end;

procedure ResetEnergyConfig;
begin
  SetEnergyLevel(eelNone, cfUnknown);
end;

function SelectEnergyEfficientInstruction(const context: TEnergyContext; const alternatives: array of string): string;
var
  cpuModel: TCPUEnergyModel;
  minCost: UInt64;
  bestIndex, i: Integer;
begin
  cpuModel := context.CurrentCPU;

  Result := alternatives[0];

  if Length(alternatives) <= 1 then
    Exit;
  
  // Find the most energy-efficient instruction
  minCost := High(UInt64);
  bestIndex := 0;
  
  for i := 0 to High(alternatives) do
  begin
    case alternatives[i] of
      'mov_reg_reg':
        if cpuModel.InstructionCosts.ALU_OPS[0] < minCost then
        begin
          minCost := cpuModel.InstructionCosts.ALU_OPS[0];
          bestIndex := i;
        end;
      'mov_reg_mem':
        if cpuModel.InstructionCosts.MEMORY_OPS[0] < minCost then
        begin
          minCost := cpuModel.InstructionCosts.MEMORY_OPS[0];
          bestIndex := i;
        end;
      'add_reg_reg':
        if cpuModel.InstructionCosts.ALU_OPS[0] < minCost then
        begin
          minCost := cpuModel.InstructionCosts.ALU_OPS[0];
          bestIndex := i;
        end;
      'add_reg_imm':
        if cpuModel.InstructionCosts.ALU_OPS[0] < minCost then
        begin
          minCost := cpuModel.InstructionCosts.ALU_OPS[0];
          bestIndex := i;
        end;
      'mul_reg_reg':
        if cpuModel.InstructionCosts.ALU_OPS[0] * 2 < minCost then  // Multiplication is more expensive
        begin
          minCost := cpuModel.InstructionCosts.ALU_OPS[0] * 2;
          bestIndex := i;
        end;
      'div_reg_reg':
        if cpuModel.InstructionCosts.ALU_OPS[0] * 4 < minCost then  // Division is very expensive
        begin
          minCost := cpuModel.InstructionCosts.ALU_OPS[0] * 4;
          bestIndex := i;
        end;
      'sse_add':
        if (context.Config.AllowSSE) and 
           (cpuModel.InstructionCosts.FPU_OPS[0] < minCost) then
        begin
          minCost := cpuModel.InstructionCosts.FPU_OPS[0];
          bestIndex := i;
        end;
      'avx_add':
        if (context.Config.AllowAVX2) and 
           (cpuModel.InstructionCosts.SIMD_OPS[0] < minCost) then
        begin
          minCost := cpuModel.InstructionCosts.SIMD_OPS[0];
          bestIndex := i;
        end;
    end;
  end;
  
  Result := alternatives[bestIndex];
end;

initialization
  ResetEnergyConfig;
end.