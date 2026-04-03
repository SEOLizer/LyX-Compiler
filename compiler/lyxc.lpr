{$mode objfpc}{$H+}
program lyxc;

uses
  SysUtils, Classes, BaseUnix,
  bytes, backend_types, energy_model,
  diag, lexer, parser, ast, sema, unit_manager, linter,
  ir, lower_ast_to_ir, ir_inlining, ir_optimize, ir_mcdc,
  x86_64_emit, elf64_writer,
  x86_64_win64, pe64_writer,
  arm64_emit, elf64_arm64_writer,
  macosx64_emit, macho64_writer,
  xtensa_emit, elf32_writer,
  riscv_emit, elf64_riscv_writer;

type
  TTarget = (targetLinux, targetWindows, targetLinuxARM64, targetMacOSX64, targetMacOSARM64, targetESP32, targetRISCV);
  TArchitecture = (archX86_64, archARM64, archXtensa, archRISCV);

var
  inputFile: string;
  outputFile: string;
  target: TTarget;
  arch: TArchitecture;
  flagEmitAsm: Boolean;
  flagDumpRelocs: Boolean;
  flagLint: Boolean;
  flagLintOnly: Boolean;
  flagEnergyLevel: Integer;  // 0 = disabled, 1-5 = energy level
  flagOptimize: Boolean;  // IR optimizations default aktiviert
  flagTraceImports: Boolean;  // --trace-imports Flag
  flagMCDC: Boolean;  // --mcdc MC/DC instrumentation
  includePaths: TStringList;  // -I Pfade
  stdLibPath: string;  // --std-path
  lint: TLinter;
  src: TStringList;
  d: TDiagnostics;
  lx: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  module: TIRModule;
  lower: TIRLowering;
  inliner: TIRInlining;
  optimizer: TIROptimizer;
  emit: TX86_64Emitter;
  winEmit: TWin64Emitter;
  arm64Emit: TARM64Emitter;
  macosx64Emit: TMacOSX64Emitter;
  esp32Emit: ICodeEmitter;
  riscvEmit: TRISCVCodeEmitter;
  codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64;
  basePath: string;
  externSymbols: TExternalSymbolArray;
  neededLibs: array of string;
  pltPatches: TPLTGOTPatchArray;
  mainOff: Integer;
  i, j: Integer;
  mcdc: TMCDCInstrumenter;
  mcdcCount: Integer;
  param: string;

type
  TStringArray = array of string;

procedure PrintEnergyStats(const stats: TEnergyStats);
var
  cfg: TEnergyConfig;
begin
  cfg := GetEnergyConfig;
  WriteLn;
  WriteLn('=== Energy Statistics ===');
  WriteLn('Energy level:           ', Ord(cfg.Level));
  WriteLn('CPU family:             ', Ord(cfg.CPUFamily));
  WriteLn('Optimize for battery:   ', cfg.OptimizeForBattery);
  WriteLn('Avoid SIMD:             ', cfg.AvoidSIMD);
  WriteLn('Avoid FPU:              ', cfg.AvoidFPU);
  WriteLn('Cache locality:         ', cfg.PrioritizeCacheLocality);
  WriteLn('Register over memory:   ', cfg.PreferRegisterOverMemory);
  WriteLn;
  WriteLn('Total ALU operations:   ', stats.TotalALUOps);
  WriteLn('Total FPU operations:   ', stats.TotalFPUOps);
  WriteLn('Total SIMD operations:  ', stats.TotalSIMDOps);
  WriteLn('Total memory accesses:  ', stats.TotalMemoryAccesses);
  WriteLn('Total branches:         ', stats.TotalBranches);
  WriteLn('Total syscalls:         ', stats.TotalSyscalls);
  WriteLn;
  WriteLn('Estimated energy units: ', stats.EstimatedEnergyUnits);
  WriteLn('Code size:              ', stats.CodeSizeBytes, ' bytes');
  WriteLn('L1 cache footprint:     ', stats.L1CacheFootprint, ' bytes');
end;

procedure DumpIRAsAsm(m: TIRModule);
var
  fi, ii, sidx: Integer;
  fn: TIRFunction;
  ins: TIRInstr;
  opName: string;
  argStr: string;
  ai: Integer;
begin
  WriteLn('; === Lyx IR Pseudo-Assembly ===');
  WriteLn('; Strings: ', m.Strings.Count);
  for fi := 0 to m.Strings.Count - 1 do
    WriteLn(';   .str', fi, ': "', m.Strings[fi], '"');
  WriteLn('; Globals: ', Length(m.GlobalVars));
  for fi := 0 to High(m.GlobalVars) do
  begin
    if m.GlobalVars[fi].IsArray then
    begin
      Write(';   .global ', m.GlobalVars[fi].Name, ' = [');
      for ai := 0 to m.GlobalVars[fi].ArrayLen - 1 do
      begin
        if ai > 0 then Write(', ');
        Write(m.GlobalVars[fi].InitValues[ai]);
      end;
      WriteLn(']');
    end
    else
      WriteLn(';   .global ', m.GlobalVars[fi].Name, ' = ', m.GlobalVars[fi].InitValue);
  end;
  WriteLn;

  for fi := 0 to High(m.Functions) do
  begin
    fn := m.Functions[fi];
    WriteLn(fn.Name, ':  ; params=', fn.ParamCount, ' locals=', fn.LocalCount);
    for ii := 0 to High(fn.Instructions) do
    begin
      ins := fn.Instructions[ii];
      WriteStr(opName, ins.Op);
      Write('  ', opName);
      case ins.Op of
        irConstInt: WriteLn(' t', ins.Dest, ', ', ins.ImmInt);
        irConstStr: begin
          sidx := StrToIntDef(ins.ImmStr, -1);
          if (sidx >= 0) and (sidx < m.Strings.Count) then
            WriteLn(' t', ins.Dest, ', .str', sidx, '  ; "', m.Strings[sidx], '"')
          else
            WriteLn(' t', ins.Dest, ', "', ins.ImmStr, '"');
        end;
        irConstFloat: WriteLn(' t', ins.Dest, ', ', ins.ImmFloat:0:6);
        irAdd, irSub, irMul, irDiv, irMod:
          WriteLn(' t', ins.Dest, ', t', ins.Src1, ', t', ins.Src2);
        irFAdd, irFSub, irFMul, irFDiv:
          WriteLn(' t', ins.Dest, ', t', ins.Src1, ', t', ins.Src2);
        irNeg, irFNeg, irNot:
          WriteLn(' t', ins.Dest, ', t', ins.Src1);
        irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe:
          WriteLn(' t', ins.Dest, ', t', ins.Src1, ', t', ins.Src2);
        irLoadLocal: WriteLn(' t', ins.Dest, ', [local', ins.Src1, ']');
        irStoreLocal: WriteLn(' [local', ins.Dest, '], t', ins.Src1);
        irLoadGlobal: WriteLn(' t', ins.Dest, ', [', ins.ImmStr, ']');
        irStoreGlobal: WriteLn(' [', ins.ImmStr, '], t', ins.Src1);
        irJmp: WriteLn(' ', ins.LabelName);
        irBrTrue: WriteLn(' t', ins.Src1, ', ', ins.LabelName);
        irBrFalse: WriteLn(' t', ins.Src1, ', ', ins.LabelName);
        irLabel: WriteLn(' ', ins.LabelName, ':');
        irFuncExit: begin
          if ins.Src1 >= 0 then WriteLn(' t', ins.Src1)
          else WriteLn;
        end;
        irCall, irCallBuiltin, irCallStruct: begin
          argStr := '';
          for ai := 0 to High(ins.ArgTemps) do
          begin
            if ai > 0 then argStr := argStr + ', ';
            argStr := argStr + 't' + IntToStr(ins.ArgTemps[ai]);
          end;
          if ins.Dest >= 0 then
            Write(' t', ins.Dest, ' = ')
          else
            Write(' ');
          Write(ins.ImmStr, '(', argStr, ')');
          case ins.CallMode of
            cmInternal: WriteLn('  ; internal');
            cmImported: WriteLn('  ; imported');
            cmExternal: WriteLn('  ; EXTERN');
          end;
        end;
        irAlloc: WriteLn(' t', ins.Dest, ', ', ins.ImmInt, ' bytes');
        irFree: WriteLn(' t', ins.Src1);
        irSExt, irZExt, irTrunc: WriteLn(' t', ins.Dest, ', t', ins.Src1, ', ', ins.ImmInt, 'bit');
        irCast: WriteLn(' t', ins.Dest, ', t', ins.Src1);
        irIToF: WriteLn(' t', ins.Dest, ', t', ins.Src1);
        irFToI: WriteLn(' t', ins.Dest, ', t', ins.Src1);
      else
        WriteLn(' d=', ins.Dest, ' s1=', ins.Src1, ' s2=', ins.Src2,
                ' imm=', ins.ImmInt, ' str=', ins.ImmStr, ' lbl=', ins.LabelName);
      end;
    end;
    WriteLn;
  end;
end;

procedure DumpRelocs(e: TX86_64Emitter);
var
  syms: TExternalSymbolArray;
  patches: TPLTGOTPatchArray;
  i: Integer;
begin
  syms := e.GetExternalSymbols;
  patches := e.GetPLTGOTPatches;

  WriteLn('; === Relocation Dump ===');
  WriteLn('; External Symbols: ', Length(syms));
  for i := 0 to High(syms) do
    WriteLn(';   [', i, '] ', syms[i].Name, ' from "', syms[i].LibraryName, '"');

  WriteLn('; PLT/GOT Patches: ', Length(patches));
  for i := 0 to High(patches) do
    WriteLn(';   [', i, '] pos=0x', IntToHex(patches[i].Pos, 4),
            ' sym=', patches[i].SymbolName,
            ' idx=', patches[i].SymbolIndex);

  if Length(syms) = 0 then
    WriteLn('; -> Static ELF (no dynamic linking needed)')
  else
    WriteLn('; -> Dynamic ELF (', Length(syms), ' external symbols)');
end;

function CollectLibraries(const symbols: TExternalSymbolArray): TStringArray;
var
  libList: TStringList;
  i: Integer;
begin
  Result := nil;
  libList := TStringList.Create;
  try
    libList.Duplicates := dupIgnore;
    libList.Sorted := True;
    
    // Collect unique library names from symbols
    for i := 0 to High(symbols) do
      libList.Add(symbols[i].LibraryName);
    
    // Convert to array
    SetLength(Result, libList.Count);
    for i := 0 to libList.Count - 1 do
      Result[i] := libList[i];
  finally
    libList.Free;
  end;
end;

begin
  // Default target is the host OS
  {$IFDEF WINDOWS}
  target := targetWindows;
  arch := archX86_64;
  {$ELSE}
  target := targetLinux;
  arch := archX86_64;
  {$ENDIF}
  
    // TOR-001: Handle --version
  if (ParamCount = 1) and (ParamStr(1) = '--version') then
  begin
    WriteLn('lyxc 0.6.0-aerospace');
    WriteLn('DO-178C TQL-5 Qualified Compiler');
    WriteLn('Target Platforms: Linux x86_64, Linux ARM64, Windows x64, macOS x86_64, macOS ARM64, ESP32');
    Halt(0);
  end;

  // TOR-002: Handle --build-info
  if (ParamCount = 1) and (ParamStr(1) = '--build-info') then
  begin
    WriteLn('Lyx Compiler Build Information');
    WriteLn('================================');
    WriteLn('Version:         0.6.0-aerospace');
    WriteLn('TQL Level:       TQL-5 (DO-178C Section 12.2)');
    WriteLn('Build Host:      ', GetEnvironmentVariable('HOSTNAME'));
    WriteLn('Build OS:        ', {$IFDEF LINUX}'Linux'{$ELSE}{$IFDEF WINDOWS}'Windows'{$ELSE}'Unknown'{$ENDIF}{$ENDIF});
    WriteLn('Build Arch:      x86_64');
    WriteLn('FPC Version:     ', {$I %FPCVERSION%});
    WriteLn('Deterministic:   Yes');
    WriteLn('Hidden Deps:     None (no libc, pure syscalls)');
    Halt(0);
  end;

  // TOR-003: Handle --config
  if (ParamCount = 1) and (ParamStr(1) = '--config') then
  begin
    WriteLn('Lyx Compiler Configuration');
    WriteLn('===========================');
    WriteLn('Default Target:  ', {$IFDEF WINDOWS}'Windows x64'{$ELSE}'Linux x86_64'{$ENDIF});
    WriteLn('Default Arch:    x86_64');
    WriteLn('Optimizations:   Enabled (default)');
    WriteLn('Linter:          Disabled (default)');
    WriteLn('Energy Model:    Available (levels 1-5)');
    WriteLn('Supported Targets:');
    WriteLn('  - linux / elf         (Linux x86_64, ELF64)');
    WriteLn('  - win64 / windows     (Windows x64, PE32+)');
    WriteLn('  - arm64 / aarch64     (Linux ARM64, ELF64)');
    WriteLn('  - macosx64 / darwin   (macOS x86_64, Mach-O)');
    WriteLn('  - macos-arm64         (macOS ARM64, Mach-O)');
    WriteLn('  - esp32 / xtensa      (ESP32, ELF32)');
    WriteLn('  - riscv / riscv64     (RISC-V RV64GC, ELF64)');
    WriteLn('Supported Architectures:');
    WriteLn('  - x86_64');
    WriteLn('  - arm64 / aarch64');
    WriteLn('  - xtensa');
    WriteLn('  - riscv / riscv64');
    WriteLn('IR Features:');
    WriteLn('  - Constant Folding, CSE, DCE');
    WriteLn('  - Function Inlining');
    WriteLn('  - Dead Code Elimination');
    Halt(0);
  end;

  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'Lyx Compiler v0.6.0-aerospace');
    WriteLn(StdErr, 'Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Verwendung: lyxc <datei.lyx> [-o <output>] [--target=TARGET] [--arch=ARCH]');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Optionen:');
    WriteLn(StdErr, '  -o <datei>       Ausgabedatei (Standard: a.out bzw. a.exe)');
    WriteLn(StdErr, '  -I <pfad>        Include-Pfad für Module hinzufügen (mehrfach verwendbar)');
    WriteLn(StdErr, '  --std-path=PATH  Pfad zur Standardbibliothek überschreiben');
    WriteLn(StdErr, '  --target=TARGET  Zielplattform (win64, linux, arm64, macosx64, macos-arm64, esp32, riscv)');
    WriteLn(StdErr, '  --arch=ARCH      Architektur (x86_64, arm64, xtensa, riscv)');
    WriteLn(StdErr, '  --target-energy=<1-5>  Energy-Ziel setzen (1=Minimal, 5=Extreme)');
    WriteLn(StdErr, '  --emit-asm       IR als Pseudo-Assembler ausgeben');
    WriteLn(StdErr, '  --dump-relocs    Relocations und externe Symbole anzeigen');
    WriteLn(StdErr, '  --trace-imports  Import-Auflösung debuggen');
    WriteLn(StdErr, '  --lint           Linter-Warnungen aktivieren (Stil, ungenutzte Variablen)');
    WriteLn(StdErr, '  --lint-only      Nur linten, nicht kompilieren');
    WriteLn(StdErr, '  --no-lint        Linter-Warnungen deaktivieren');
    WriteLn(StdErr, '  --no-opt         IR-Optimierungen deaktivieren (Standard: aktiv)');
    WriteLn(StdErr, '  --mcdc           MC/DC-Instrumentierung für DO-178C Coverage');
    WriteLn(StdErr, '  --mcdc-report    MC/DC-Coverage-Bericht nach Kompilierung');
    WriteLn(StdErr);
    WriteLn(StdErr, 'TOR-Optionen (DO-178C Tool Qualification):');
    WriteLn(StdErr, '  --version        Versionsnummer ausgeben (TOR-001)');
    WriteLn(StdErr, '  --build-info     Build-Identifikation ausgeben (TOR-002)');
    WriteLn(StdErr, '  --config         Aktive Konfiguration ausgeben (TOR-003)');
    Halt(1);
  end;

  inputFile := '';
  outputFile := '';
  flagEmitAsm := False;
  flagDumpRelocs := False;
  flagLint := False;
  flagLintOnly := False;
  flagEnergyLevel := 0;
  flagOptimize := True;  // IR optimizations enabled by default
  flagTraceImports := False;
  flagMCDC := False;
  includePaths := TStringList.Create;
  stdLibPath := '';

  // Parse command line arguments
  i := 1;
  while i <= ParamCount do
  begin
    param := ParamStr(i);
    
    if (param = '-o') and (i < ParamCount) then
    begin
      outputFile := ParamStr(i + 1);
      Inc(i, 2);  // Skip -o and the filename
    end
     else if Copy(param, 1, 9) = '--target=' then
     begin
       param := LowerCase(Copy(param, 10, MaxInt));
       if (param = 'win64') or (param = 'windows') then
       begin
         target := targetWindows;
         arch := archX86_64;
       end
       else if (param = 'linux') or (param = 'elf') then
       begin
         target := targetLinux;
         arch := archX86_64;
       end
       else if (param = 'arm64') or (param = 'aarch64') or (param = 'linux-arm64') then
       begin
         target := targetLinuxARM64;
         arch := archARM64;
       end
       else if (param = 'macosx64') or (param = 'darwin') then
       begin
         target := targetMacOSX64;
         arch := archX86_64;
       end
       else if (param = 'macos-arm64') or (param = 'macos-aarch64') then
       begin
         target := targetMacOSARM64;
         arch := archARM64;
       end
        else if (param = 'esp32') or (param = 'xtensa') then
        begin
          target := targetESP32;
          arch := archXtensa;
        end
        else if (param = 'riscv') or (param = 'riscv64') or (param = 'rv64') then
        begin
          target := targetRISCV;
          arch := archRISCV;
        end
        else
        begin
          WriteLn(StdErr, 'Unbekanntes Ziel: ', param);
          WriteLn(StdErr, 'Gültige Werte: win64, linux, arm64, macosx64, macos-arm64, esp32, riscv');
          Halt(1);
        end;
       Inc(i);
     end
     else if Copy(param, 1, 6) = '--arch=' then
     begin
       param := LowerCase(Copy(param, 7, MaxInt));
       if (param = 'x86_64') or (param = 'x64') then
         arch := archX86_64
       else if (param = 'arm64') or (param = 'aarch64') then
         arch := archARM64
        else if (param = 'xtensa') then
          arch := archXtensa
        else if (param = 'riscv') or (param = 'riscv64') or (param = 'rv64') then
          arch := archRISCV
        else
        begin
          WriteLn(StdErr, 'Unbekannte Architektur: ', param);
          WriteLn(StdErr, 'Gültige Werte: x86_64, arm64, xtensa, riscv');
          Halt(1);
        end;
       Inc(i);
     end
    else if param = '--emit-asm' then
    begin
      flagEmitAsm := True;
      Inc(i);
    end
    else if param = '--dump-relocs' then
    begin
      flagDumpRelocs := True;
      Inc(i);
    end
    else if param = '--lint' then
    begin
      flagLint := True;
      Inc(i);
    end
    else if param = '--lint-only' then
    begin
      flagLint := True;
      flagLintOnly := True;
      Inc(i);
    end
    else if param = '--no-lint' then
    begin
      flagLint := False;
      Inc(i);
    end
    else if param = '--no-opt' then
    begin
      flagOptimize := False;
      Inc(i);
    end
    else if param = '--mcdc' then
    begin
      flagMCDC := True;
      Inc(i);
    end
    else if param = '--mcdc-report' then
    begin
      flagMCDC := True;
      Inc(i);
    end
    else if param = '--trace-imports' then
    begin
      flagTraceImports := True;
      Inc(i);
    end
    else if (param = '-I') and (i < ParamCount) then
    begin
      includePaths.Add(ParamStr(i + 1));
      Inc(i, 2);
    end
    else if Copy(param, 1, 2) = '-I' then
    begin
      // -I/path/to/include (ohne Leerzeichen)
      includePaths.Add(Copy(param, 3, MaxInt));
      Inc(i);
    end
    else if Copy(param, 1, 11) = '--std-path=' then
    begin
      stdLibPath := Copy(param, 12, MaxInt);
      Inc(i);
    end
    else if Copy(param, 1, 16) = '--target-energy=' then
    begin
      flagEnergyLevel := StrToIntDef(Copy(param, 17, MaxInt), 0);
      if (flagEnergyLevel < 1) or (flagEnergyLevel > 5) then
      begin
        WriteLn(StdErr, 'Ungültiger Energy-Level: ', flagEnergyLevel, '. Erlaubt: 1-5.');
        Halt(1);
      end;
      Inc(i);
    end
    else if (param <> '-o') and (Copy(param, 1, 2) <> '--') then
    begin
      if inputFile = '' then
        inputFile := param;
      Inc(i);
    end
    else
      Inc(i);
  end;

  if inputFile = '' then
  begin
    WriteLn(StdErr, 'Keine Eingabedatei angegeben');
    Halt(1);
  end;

  // Default output filename
  if outputFile = '' then
  begin
    if target = targetWindows then
      outputFile := 'a.exe'
    else
      outputFile := 'a.out';
  end;

  WriteLn('Lyx Compiler v0.6.0-aerospace');
  WriteLn('DO-178C TQL-5 Qualified');
  WriteLn('Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
  WriteLn;
  WriteLn('Eingabe:  ', inputFile);
  WriteLn('Ausgabe:  ', outputFile);
    if target = targetWindows then
      WriteLn('Ziel:     Windows x64 (PE32+)')
    else if target = targetLinux then
      WriteLn('Ziel:     Linux x86_64 (ELF64)')
    else if target = targetLinuxARM64 then
      WriteLn('Ziel:     Linux ARM64 (ELF64)')
    else if target = targetMacOSX64 then
      WriteLn('Ziel:     macOS x86_64 (Mach-O)')
    else if target = targetMacOSARM64 then
      WriteLn('Ziel:     macOS ARM64 (Mach-O)')
    else if target = targetESP32 then
      WriteLn('Ziel:     ESP32 (Xtensa, ELF32)');

  // Energy-Konfiguration setzen (vor der Statusausgabe)
  if flagEnergyLevel > 0 then
  begin
    case target of
      targetLinux: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfX86_64);
      targetLinuxARM64: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfARM64);
      targetWindows: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfX86_64);
    end;
  end;

  if flagEnergyLevel > 0 then
  begin
    WriteLn('Energy-Level: ', flagEnergyLevel);
    case flagEnergyLevel of
      1: WriteLn('Target: Minimal energy consumption (battery optimized)');
      2: WriteLn('Target: Low energy consumption (balanced)');
      3: WriteLn('Target: Medium energy consumption (performance optimized)');
      4: WriteLn('Target: High energy consumption (performance first)');
      5: WriteLn('Target: Extreme energy consumption (maximum performance)');
    end;
    WriteLn;
  end;

  basePath := ExtractFilePath(inputFile);
  if basePath = '' then
    basePath := '.';

  src := TStringList.Create;
  try
    src.LoadFromFile(inputFile);
    d := TDiagnostics.Create;
    try
      // Phase 1: Parse Hauptdatei
      lx := TLexer.Create(src.Text, inputFile, d);
      try
        p := TParser.Create(lx, d);
        try
          prog := p.ParseProgram;
        finally
          p.Free;
        end;
      finally
        lx.Free;
      end;

      if d.HasErrors then
      begin
        d.PrintAll;
        Halt(1);
      end;

        // Phase 2: Lade alle Imports (UnitManager)
        um := TUnitManager.Create(d);
        try
          // Konfiguriere den UnitManager
          um.SetSourceFile(inputFile);
          um.SetProjectRoot(GetCurrentDir);
          um.SetTraceImports(flagTraceImports);
          
          // Optionaler Std-Lib-Pfad
          if stdLibPath <> '' then
            um.SetStdLibPath(stdLibPath);
          
          // Include-Pfade von -I hinzufügen
          for i := 0 to includePaths.Count - 1 do
            um.AddIncludePath(includePaths[i]);
          
          um.LoadAllImports(prog, inputFile);

        if d.HasErrors then
        begin
          d.PrintAll;
          Halt(1);
        end;

        // Phase 3: Semantische Analyse (mit Unit-Integration)
        s := TSema.Create(d);
        try
          s.AnalyzeWithUnits(prog, um);
          if d.HasErrors then
          begin
            d.PrintAll;
            Halt(1);
          end;
        finally
          s.Free;
        end;

        // Phase 3b: Linter (optional)
        if flagLint then
        begin
          lint := TLinter.Create(d);
          try
            lint.Lint(prog);
            if lint.WarnCount > 0 then
              WriteLn(StdErr, '[lint] ', lint.WarnCount, ' warning(s)');
          finally
            lint.Free;
          end;
          if flagLintOnly then
          begin
            d.PrintAll;
            if d.HasErrors then
              Halt(1)
            else
              Halt(0);
          end;
        end;

        module := TIRModule.Create;
        lower := TIRLowering.Create(module, d);
        try
          // First, register constants from imported units so they're available during lowering
          lower.LowerImportedUnits(um);
          // Then lower the main program
          lower.Lower(prog);

          // IR-Level Inlining Optimization
          WriteLn('[IR] Running inlining optimization...');
          inliner := TIRInlining.Create(module);
          try
            inliner.Optimize;
          finally
            inliner.Free;
          end;

          // --emit-asm: Dump IR BEFORE optimization
          if flagEmitAsm then
          begin
            WriteLn('; === IR (before optimization) ===');
            DumpIRAsAsm(module);
          end;

          // IR-Level Optimizations (Constant Folding, CSE, DCE, etc.)
          if flagOptimize then
          begin
            WriteLn('[IR] Running IR optimizations...');
            optimizer := TIROptimizer.Create(module);
            try
              optimizer.Optimize;
              if optimizer.Changed then
                WriteLn('[IR] IR optimized: ', optimizer.PassCount, ' passes');
            finally
              optimizer.Free;
            end;
          end
          else
            WriteLn('[IR] IR optimizations disabled');

          // MC/DC Instrumentation (DO-178C DAL A)
          if flagMCDC then
          begin
            WriteLn('[MC/DC] Running MC/DC instrumentation...');
            mcdc := TMCDCInstrumenter.Create(module);
            try
              mcdcCount := mcdc.Instrument;
              WriteLn('[MC/DC] Instrumented ', mcdcCount, ' coverage points (', mcdc.DecisionCount, ' decisions)');
              mcdc.GenerateReport;
            finally
              mcdc.Free;
            end;
          end;

          // --emit-asm: Dump IR as pseudo-assembly
          if flagEmitAsm then
            DumpIRAsAsm(module);

           if target = targetWindows then
           begin
             // Windows x64 Code Generation
             winEmit := TWin64Emitter.Create;
             try
               winEmit.EmitFromIR(module);
               winEmit.WriteToFile(outputFile);
               WriteLn('Wrote ', outputFile, ' (PE32+ for Windows x64)');
             finally
               winEmit.Free;
             end;
           end
           else if target = targetLinux then
           begin
             // Linux x86_64 Code Generation
             emit := TX86_64Emitter.Create;
             try
               if flagEnergyLevel > 0 then
                 emit.SetEnergyLevel(TEnergyLevel(flagEnergyLevel));
 
                emit.EmitFromIR(module);
                codeBuf := emit.GetCodeBuffer;
                dataBuf := emit.GetDataBuffer;
  
                // --dump-relocs: show external symbols and PLT patches
               if flagDumpRelocs then
                 DumpRelocs(emit);
 
               // Check if we have external symbols - if so, generate dynamic ELF
               externSymbols := emit.GetExternalSymbols;
               if Length(externSymbols) > 0 then
               begin
                 neededLibs := CollectLibraries(externSymbols);
                 entryVA := 4096;
                 WriteLn('Generating dynamic ELF with ', Length(externSymbols), ' external symbols');
                 WriteDynamicElf64WithPatches(outputFile, codeBuf, dataBuf, entryVA, externSymbols, neededLibs, emit.GetPLTGOTPatches);
               end
               else
               begin
                 entryVA := $400000 + 4096;
                 WriteLn('Generating static ELF (no external symbols)');
                 WriteElf64(outputFile, codeBuf, dataBuf, entryVA);
               end;
 
               // Energy statistics output
               if flagEnergyLevel > 0 then
                 PrintEnergyStats(emit.GetEnergyStats);
 
               FpChmod(PChar(outputFile), 493);
               WriteLn('Wrote ', outputFile);
             finally
               emit.Free;
             end;
           end
           else if target = targetLinuxARM64 then
           begin
             // Linux ARM64 Code Generation
             arm64Emit := TARM64Emitter.Create;
             try
               arm64Emit.EmitFromIR(module);
               codeBuf := arm64Emit.GetCodeBuffer;
               dataBuf := arm64Emit.GetDataBuffer;
               entryVA := $400000 + 4096;  // Base VA + code offset
 
               // Check if we have external symbols
               externSymbols := arm64Emit.GetExternalSymbols;
                if Length(externSymbols) > 0 then
                begin
                  WriteLn('Generating dynamic ELF for Linux ARM64 with ', Length(externSymbols), ' external symbols');
                  WriteDynamicElf64ARM64(outputFile, codeBuf, dataBuf, entryVA, externSymbols, arm64Emit.GetPLTGOTPatches);
                end
                else
                begin
                  WriteLn('Generating static ELF for Linux ARM64');
                  WriteElf64ARM64(outputFile, codeBuf, dataBuf, entryVA);
                end;
 
               // Energy statistics output
               if flagEnergyLevel > 0 then
                 PrintEnergyStats(arm64Emit.GetEnergyStats);
 
               FpChmod(PChar(outputFile), 493);
               WriteLn('Wrote ', outputFile, ' (ELF64 for Linux ARM64)');
             finally
               arm64Emit.Free;
             end;
           end
            else if target = targetMacOSX64 then
            begin
              // macOS x86_64 Code Generation (reuse Linux emitter with macOS syscall mode)
              emit := TX86_64Emitter.Create;
              emit.SetTargetOS(atmacOS);
              try
                if flagEnergyLevel > 0 then
                  emit.SetEnergyLevel(TEnergyLevel(flagEnergyLevel));

                emit.EmitFromIR(module);
                codeBuf := emit.GetCodeBuffer;
                dataBuf := emit.GetDataBuffer;

                externSymbols := emit.GetExternalSymbols;
                pltPatches := emit.GetPLTGOTPatches;
                if Length(externSymbols) > 0 then
                begin
                  WriteLn('Generating dynamic Mach-O for macOS x86_64 with ', Length(externSymbols), ' external symbols');
                  mainOff := emit.GetFunctionOffset('main');
                  if mainOff < 0 then mainOff := 0;
                  WriteDynamicMachO64(outputFile, codeBuf, dataBuf, UInt64(mainOff), mctX86_64,
                    externSymbols, pltPatches);
                end
                else
                begin
                  WriteLn('Generating static Mach-O for macOS x86_64');
                  entryVA := $100000000;  // macOS: user space starts at 4GB
                  WriteMachO64(outputFile, codeBuf, dataBuf, entryVA, mctX86_64);
                end;

                // Energy statistics output
                if flagEnergyLevel > 0 then
                  PrintEnergyStats(emit.GetEnergyStats);

                FpChmod(PChar(outputFile), 493);
                WriteLn('Wrote ', outputFile);
              finally
                emit.Free;
              end;
            end
            else if target = targetMacOSARM64 then
            begin
              // macOS ARM64 Code Generation
              arm64Emit := TARM64Emitter.Create;
              arm64Emit.SetTargetOS(atmacOS);
              try
                arm64Emit.EmitFromIR(module);
                codeBuf := arm64Emit.GetCodeBuffer;
                dataBuf := arm64Emit.GetDataBuffer;

                externSymbols := arm64Emit.GetExternalSymbols;
                pltPatches := arm64Emit.GetPLTGOTPatches;
                if Length(externSymbols) > 0 then
                begin
                  WriteLn('Generating dynamic Mach-O for macOS ARM64 with ', Length(externSymbols), ' external symbols');
                  mainOff := arm64Emit.GetFunctionOffset('main');
                  if mainOff < 0 then mainOff := 0;
                  WriteDynamicMachO64(outputFile, codeBuf, dataBuf, UInt64(mainOff), mctARM64,
                    externSymbols, pltPatches);
                end
                else
                begin
                  WriteLn('Generating static Mach-O for macOS ARM64');
                  entryVA := $400000 + 4096;
                  WriteMachO64(outputFile, codeBuf, dataBuf, entryVA, mctARM64);
                end;

                // Energy statistics output
                if flagEnergyLevel > 0 then
                  PrintEnergyStats(arm64Emit.GetEnergyStats);

                FpChmod(PChar(outputFile), 493);
                WriteLn('Wrote ', outputFile, ' (Mach-O for macOS ARM64)');
              finally
                arm64Emit.Free;
              end;
            end
            else if target = targetESP32 then
            begin
              // ESP32 (Xtensa) Code Generation
              esp32Emit := TxtensaCodeEmitter.Create;
              try
                if flagEnergyLevel > 0 then
                  esp32Emit.SetEnergyLevel(TEnergyLevel(flagEnergyLevel));

                esp32Emit.EmitFromIR(module);
                codeBuf := esp32Emit.GetCodeBuffer;
                dataBuf := esp32Emit.GetDataBuffer;
                entryVA := $400000 + 4096;  // Base VA + code offset

                // Check if we have external symbols (for now ignore, produce static ELF)
                externSymbols := esp32Emit.GetExternalSymbols;
                if Length(externSymbols) > 0 then
                begin
                  WriteLn('Note: ESP32 dynamic linking not yet implemented');
                  WriteLn('External symbols found: ', Length(externSymbols), ' (will be ignored for now)');
                end;

                WriteLn('Generating static ELF32 for ESP32 (Xtensa)');
                WriteElf32(outputFile, codeBuf, dataBuf, entryVA);

                // Energy statistics output
                if flagEnergyLevel > 0 then
                  PrintEnergyStats(esp32Emit.GetEnergyStats);

                FpChmod(PChar(outputFile), 493);
                WriteLn('Wrote ', outputFile);
               finally
                 // esp32Emit is interface reference, automatically freed
               end;
             end
             else if target = targetRISCV then
             begin
               // RISC-V RV64GC Code Generation
               riscvEmit := TRISCVCodeEmitter.Create;
               try
                 if flagEnergyLevel > 0 then
                   riscvEmit.SetEnergyLevel(TEnergyLevel(flagEnergyLevel));

                 riscvEmit.EmitFromIR(module);
                 codeBuf := riscvEmit.GetCodeBuffer;
                 dataBuf := riscvEmit.GetDataBuffer;
                 entryVA := $400000 + 4096;

                 externSymbols := riscvEmit.GetExternalSymbols;
                 if Length(externSymbols) > 0 then
                 begin
                   WriteLn('Note: RISC-V dynamic linking not yet implemented');
                   WriteLn('External symbols found: ', Length(externSymbols), ' (will be ignored for now)');
                 end;

                 WriteLn('Generating static ELF64 for RISC-V RV64GC');
                 WriteElf64RISCV(outputFile, codeBuf, dataBuf, entryVA);

                 FpChmod(PChar(outputFile), 493);
                 WriteLn('Wrote ', outputFile, ' (ELF64 for RISC-V RV64GC)');
               finally
                 riscvEmit.Free;
               end;
             end;
          finally
            lower.Free;
            module.Free;
          end;
      finally
        um.Free;
      end;

      // Free the AST after compilation is complete
      prog.Free;

    finally
      d.Free;
    end;
  finally
    src.Free;
  end;
  
  // Cleanup
  includePaths.Free;
end.
