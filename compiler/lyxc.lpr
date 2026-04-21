{$mode objfpc}{$H+}
program lyxc;

uses
  SysUtils, Classes, BaseUnix,
  bytes, backend_types, energy_model,
  diag, lexer, parser, ast, sema, unit_manager, linter, unit_format,
  ir, lower_ast_to_ir, ir_inlining, ir_optimize, ir_mcdc, ir_static_analysis, ir_call_graph,
  dwarf_gen, asm_listing, map_file,
  x86_64_emit, elf64_writer,
  x86_64_win64{$IFDEF LINUX}, pe64_writer{$ENDIF},
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
  flagStaticAnalysis: Boolean;  // --static-analysis
  flagAsmListing: Boolean;  // --asm-listing Assembly listing output
  flagCallGraph: Boolean;  // --call-graph
  flagMapFile: Boolean;  // --map-file
  flagRuntimeChecks: Boolean;  // --runtime-checks (DO-178C Level A)
  flagProfile: Boolean;  // --profile (WP-3: Simple Profiler)
  flagTrace: Boolean;  // --trace (WP-4: Trace builtin)
  flagProvenance: Boolean;  // --provenance (WP-F: Provenance Tracking)
  flagAstdump: Boolean;  // --ast-dump (WP-A: AST Visualisierung)
  flagSymtabdump: Boolean;  // --symtab-dump (WP-B: Symbol Table)
  flagTracepasses: Boolean;  // --trace-passes (WP-C: Transformation Tracing)
  // Precompiled unit options
  flagCompileUnit: Boolean;  // --compile-unit
  flagUnitInfo: Boolean;  // --unit-info
  flagDebugSymbols: Boolean;  // --debug-symbols
  unitOutputFile: string;  // -o for unit output
  unitTargetArch: TLyuxArch;  // -t for target arch
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
  buffer: TByteBuffer;  { For .lyu serialization }
  ser: TLyuxSerializer;  { For .lyu serialization }
  deser: TLyuxDeserializer;  { For .lyu deserialization }
  loadedUnit: TLoadedLyux;  { For .lyu loading }
  lyuSymbols: TLyuxSymbolArray;  { Exported symbols from unit }
  fn: TAstFuncDecl;  { For unit compilation }
  symIdx: Integer;  { For unit compilation }
  unitName: string;  { For unit compilation }
  // TMR Hash Store patching variables (aerospace-todo P0 #46)
  x86Emit: TX86_64Emitter;
  hashCrc: UInt32;
  codeSize, dataSize, alignedCodeSize, hashDataOffset: Integer;
  codeStartVA, dataVA: UInt64;
  dataAddrPos: Integer;
  // DWARF debug info
  dwarfGen: TDwarfGenerator;
  debugAbbrev, debugInfo, debugLine, debugFrame, debugStr: TByteBuffer;
  mcdc: TMCDCInstrumenter;
  mcdcCount: Integer;
  sa: TStaticAnalyzer;
  al: TAsmListingGenerator;
  cg: TCallGraph;
  mapGen: TMapFileGenerator;
  listingFile: string;
  sl: TStringList;
  param: string;

type
  TStringArray = array of string;

{ Helper to convert TAurumType to string }
function FormatType(t: TAurumType): string;
begin
  case t of
    atInt8:    Result := 'int8';
    atInt16:   Result := 'int16';
    atInt32:   Result := 'int32';
    atInt64:  Result := 'int64';
    atUInt8:   Result := 'uint8';
    atUInt16:  Result := 'uint16';
    atUInt32:  Result := 'uint32';
    atUInt64:  Result := 'uint64';
    atISize:   Result := 'int';
    atUSize:   Result := 'uint';
    atF32:     Result := 'f32';
    atF64:     Result := 'f64';
    atBool:    Result := 'bool';
    atChar:    Result := 'char';
    atVoid:    Result := 'void';
    atPChar:   Result := 'pchar';
    atPCharNullable: Result := 'pchar?';
    atDynArray: Result := 'array';
    atArray:   Result := 'array';
    atMap:     Result := 'Map';
    atSet:     Result := 'Set';
    atParallelArray: Result := 'parallel Array';
    atFnPtr:   Result := 'fnptr';
    else      Result := 'unknown';
  end;
end;

procedure MergePrecompiledIR(um: TUnitManager; module: TIRModule);
{ Copy IR functions from precompiled .lyu units into the main module }
var
  i, j: Integer;
  loadedUnit: TLoadedUnit;
  srcFn: TIRFunction;
  dstFn: TIRFunction;
  srcStr: string;
  strIdxMap: array of Integer;
begin
  if not Assigned(um) or not Assigned(module) then Exit;
  for i := 0 to um.Units.Count - 1 do
  begin
    loadedUnit := TLoadedUnit(um.Units.Objects[i]);
    if not Assigned(loadedUnit) or not loadedUnit.IsPrecompiled then
      Continue;
    if not Assigned(loadedUnit.LyuxData) or not Assigned(loadedUnit.LyuxData.IRModule) then
      Continue;

    { Copy all functions from precompiled unit's IR into main module }
    for j := 0 to High(loadedUnit.LyuxData.IRModule.Functions) do
    begin
      srcFn := loadedUnit.LyuxData.IRModule.Functions[j];
      { Skip if already present (avoid duplicates) }
      if module.FindFunction(srcFn.Name) <> nil then
        Continue;
      { Build a string index remap from source to dest module }
      SetLength(strIdxMap, loadedUnit.LyuxData.IRModule.Strings.Count);
      for symIdx := 0 to loadedUnit.LyuxData.IRModule.Strings.Count - 1 do
      begin
        srcStr := loadedUnit.LyuxData.IRModule.Strings[symIdx];
        strIdxMap[symIdx] := module.InternString(srcStr);
      end;
      { Add function to main module }
      module.AddFunction(srcFn.Name);
      dstFn := module.Functions[High(module.Functions)];
      dstFn.ParamCount := srcFn.ParamCount;
      dstFn.LocalCount := srcFn.LocalCount;
      dstFn.EnergyLevel := srcFn.EnergyLevel;
      dstFn.Instructions := Copy(srcFn.Instructions);
    end;
  end;
end;

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

{ WP-A: AST Visualization - Helper to get node kind as string }
function GetNodeKindName(kind: TNodeKind): string;
begin
  case kind of
    nkIntLit: Result := 'IntLit';
    nkFloatLit: Result := 'FloatLit';
    nkStrLit: Result := 'StrLit';
    nkBoolLit: Result := 'BoolLit';
    nkCharLit: Result := 'CharLit';
    nkRegexLit: Result := 'RegexLit';
    nkIdent: Result := 'Ident';
    nkConstrainedTypeDecl: Result := 'ConstrainedTypeDecl';
    nkBinOp: Result := 'BinOp';
    nkUnaryOp: Result := 'UnaryOp';
    nkCall: Result := 'Call';
    nkArrayLit: Result := 'ArrayLit';
    nkStructLit: Result := 'StructLit';
    nkTupleLit: Result := 'TupleLit';
    nkFieldAccess: Result := 'FieldAccess';
    nkIndexAccess: Result := 'IndexAccess';
    nkCast: Result := 'Cast';
    nkNewExpr: Result := 'NewExpr';
    nkSuperCall: Result := 'SuperCall';
    nkPanic: Result := 'Panic';
    nkMapLit: Result := 'MapLit';
    nkSetLit: Result := 'SetLit';
    nkInExpr: Result := 'InExpr';
    nkInspect: Result := 'Inspect';
    nkVarDecl: Result := 'VarDecl';
    nkAssign: Result := 'Assign';
    nkFieldAssign: Result := 'FieldAssign';
    nkIndexAssign: Result := 'IndexAssign';
    nkIf: Result := 'If';
    nkWhile: Result := 'While';
    nkFor: Result := 'For';
    nkRepeatUntil: Result := 'RepeatUntil';
    nkPool: Result := 'Pool';
    nkReturn: Result := 'Return';
    nkBreak: Result := 'Break';
    nkContinue: Result := 'Continue';
    nkSwitch: Result := 'Switch';
    nkBlock: Result := 'Block';
    nkExprStmt: Result := 'ExprStmt';
    nkDispose: Result := 'Dispose';
    nkAssert: Result := 'Assert';
    nkCheck: Result := 'Check';
    nkTry: Result := 'Try';
    nkThrow: Result := 'Throw';
    nkTupleVarDecl: Result := 'TupleVarDecl';
    nkFuncDecl: Result := 'FuncDecl';
    nkConDecl: Result := 'ConDecl';
    nkTypeDecl: Result := 'TypeDecl';
    nkStructDecl: Result := 'StructDecl';
    nkEnumDecl: Result := 'EnumDecl';
    nkClassDecl: Result := 'ClassDecl';
    nkInterfaceDecl: Result := 'InterfaceDecl';
    nkUnitDecl: Result := 'UnitDecl';
    nkImportDecl: Result := 'ImportDecl';
    nkProgram: Result := 'Program';
    nkBitAnd: Result := 'BitAnd';
    nkBitOr: Result := 'BitOr';
    nkBitXor: Result := 'BitXor';
    nkBitNot: Result := 'BitNot';
    nkShiftLeft: Result := 'ShiftLeft';
    nkShiftRight: Result := 'ShiftRight';
    nkSIMDNew: Result := 'SIMDNew';
    nkSIMDBinOp: Result := 'SIMDBinOp';
    nkSIMDUnaryOp: Result := 'SIMDUnaryOp';
    nkSIMDIndexAccess: Result := 'SIMDIndexAccess';
    nkIsExpr: Result := 'IsExpr';
    nkFormatExpr: Result := 'FormatExpr';
    nkLfdForm: Result := 'LfdForm';
    nkLfdWidget: Result := 'LfdWidget';
    nkLfdLayout: Result := 'LfdLayout';
    nkLfdProperty: Result := 'LfdProperty';
    nkLfdSignal: Result := 'LfdSignal';
    else Result := 'NodeKind_' + IntToStr(Ord(kind));
  end;
end;

{ WP-A: Recursive AST node dump }
procedure DumpASTNode(node: TAstNode; indent: Integer);
var
  prefix: string;
begin
  if not Assigned(node) then
  begin
    WriteLn('  ', StringOfChar(' ', indent), '<null>');
    Exit;
  end;

  prefix := StringOfChar(' ', indent);
  Write(prefix, '+ Node(ID=', node.ID, ' kind=', GetNodeKindName(node.Kind));

  if node is TAstIntLit then
    WriteLn(' value=', TAstIntLit(node).Value, ')')
  else if node is TAstFloatLit then
    WriteLn(' value=', TAstFloatLit(node).Value:0:6, ')')
  else if node is TAstStrLit then
    WriteLn(' value="', TAstStrLit(node).Value, '")')
  else if node is TAstBoolLit then
    WriteLn(' value=', TAstBoolLit(node).Value, ')')
  else if node is TAstIdent then
    WriteLn(' name=', TAstIdent(node).Name, ')')
  else if node is TAstCall then
    WriteLn(' func=', TAstCall(node).Name, ')')
  else if node is TAstVarDecl then
    WriteLn(' name=', TAstVarDecl(node).Name, ')')
  else if node is TAstFuncDecl then
    WriteLn(' name=', TAstFuncDecl(node).Name, ')')
  else if node is TAstStructDecl then
    WriteLn(' name=', TAstStructDecl(node).Name, ')')
  else if node is TAstClassDecl then
    WriteLn(' name=', TAstClassDecl(node).Name, ')')
  else if node is TAstBlock then
    WriteLn(' stmts=', Length(TAstBlock(node).Stmts), ')')
  else
    WriteLn(')');
end;

{ WP-A: Dump the full AST tree }
procedure DumpASTTree(prog: TAstProgram);
var
  i: Integer;
begin
  WriteLn;
  WriteLn('=== AST Tree (WP-A) ===');
  WriteLn;
  WriteLn('AST Program with ', Length(prog.Decls), ' declarations');
  WriteLn('Source: ', prog.Span.Filename);
  WriteLn;
  for i := 0 to High(prog.Decls) do
  begin
    if Assigned(prog.Decls[i]) then
    begin
      WriteLn('[Declaration ', i, ']');
      DumpASTNode(prog.Decls[i], 2);
      WriteLn;
    end;
  end;
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

{ WP-C: Transformation Tracing (Pass-by-Pass) }
var
  FPassStartTime: QWord;

procedure EnterPass(const PassName: string; const InputInfo: string);
begin
  if flagTracepasses then
  begin
    WriteLn;
    WriteLn('=== Pass: ', PassName, ' ===');
    if InputInfo <> '' then
      WriteLn('Input:  ', InputInfo);
    FPassStartTime := GetTickCount64;
  end;
end;

procedure LeavePass(const PassName: string; const OutputInfo: string);
var
  elapsed: QWord;
begin
  if flagTracepasses then
  begin
    if OutputInfo <> '' then
      WriteLn('Output: ', OutputInfo);
    elapsed := GetTickCount64 - FPassStartTime;
    WriteLn('Done:   ', elapsed, 'ms');
    WriteLn;
  end;
end;

procedure LeavePassSimple(const PassName, OutputInfo: string);
begin
  LeavePass(PassName, OutputInfo);
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
    WriteLn('lyxc 0.8.2-aerospace');
    WriteLn('DO-178C TQL-5 Qualified Compiler');
    WriteLn('Target Platforms: Linux x86_64, Linux ARM64, Windows x64, macOS x86_64, macOS ARM64, ESP32');
    Halt(0);
  end;

  // TOR-002: Handle --build-info
  if (ParamCount = 1) and (ParamStr(1) = '--build-info') then
  begin
    WriteLn('Lyx Compiler Build Information');
    WriteLn('================================');
    WriteLn('Version:         0.8.2-aerospace');
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
    WriteLn(StdErr, 'Lyx Compiler v0.8.2-aerospace');
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
    WriteLn(StdErr, '  --asm-listing    Assembly-Listing mit Source-Zeilen (DO-178C 6.1)');
    WriteLn(StdErr, '  --dump-relocs    Relocations und externe Symbole anzeigen');
    WriteLn(StdErr, '  --trace-imports  Import-Auflösung debuggen');
    WriteLn(StdErr, '  --lint           Linter-Warnungen aktivieren (Stil, ungenutzte Variablen)');
    WriteLn(StdErr, '  --lint-only      Nur linten, nicht kompilieren');
    WriteLn(StdErr, '  --no-lint        Linter-Warnungen deaktivieren');
    WriteLn(StdErr, '  --no-opt         IR-Optimierungen deaktivieren (Standard: aktiv)');
    WriteLn(StdErr, '  --mcdc           MC/DC-Instrumentierung für DO-178C Coverage');
    WriteLn(StdErr, '  --mcdc-report    MC/DC-Coverage-Bericht nach Kompilierung');
    WriteLn(StdErr, '  --static-analysis Statische Analyse (Data-Flow, Live-Vars, Stack, ...)');
    WriteLn(StdErr, '  --call-graph      Statischer Aufrufgraph (WCET-Analyse, Rekursions-Erkennung)');
    WriteLn(StdErr, '  --map-file        Speicherlayout-Datei (.map) für Debug/Audit');
    WriteLn(StdErr, '  --runtime-checks  Runtime-Assertions (bounds, null, zero) für DO-178C');
  WriteLn(StdErr, '  --profile      Profiler: instrument function calls (WP-3)');
  WriteLn(StdErr, '  --trace        Trace builtin: debug output (WP-4)');
  WriteLn(StdErr, '  --provenance   Provenance Tracking: IR→AST→Source mapping (WP-F)');
  WriteLn(StdErr, '  --ast-dump    AST Visualisierung: Text-Baum (WP-A)');
  WriteLn(StdErr, '  --symtab-dump Symbol-Tabelle ausgeben (WP-B)');
  WriteLn(StdErr, '  --trace-passes Transformation Tracing (WP-C)');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Unit-Kompilierung:');
    WriteLn(StdErr, '  --compile-unit    Unit zu .lyu vorkompilieren (IR-Code)');
    WriteLn(StdErr, '  -o <datei>      Ausgabedatei für .lyu');
    WriteLn(StdErr, '  -t=<arch>     Ziel-Architektur (x86_64, arm64)');
    WriteLn(StdErr, '  --debug-symbols Debug-Info in .lyu einbetten');
    WriteLn(StdErr, '  --unit-info    Info über .lyu-Datei anzeigen');
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
  flagStaticAnalysis := False;
  flagAsmListing := False;
  flagCallGraph := False;
  flagMapFile := False;
  flagRuntimeChecks := False;
  flagProfile := False;
  flagTrace := False;
  flagProvenance := False;
  flagAstdump := False;
  flagSymtabdump := False;
  flagTracepasses := False;
  includePaths := TStringList.Create;
  
  // Precompiled unit options
  flagCompileUnit := False;
  flagUnitInfo := False;
  flagDebugSymbols := False;
  unitOutputFile := '';
  unitTargetArch := la_x86_64;
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
    else if param = '--static-analysis' then
    begin
      flagStaticAnalysis := True;
      Inc(i);
    end
    else if param = '--asm-listing' then
    begin
      flagAsmListing := True;
      Inc(i);
    end
    else if param = '--call-graph' then
    begin
      flagCallGraph := True;
      Inc(i);
    end
    else if param = '--map-file' then
    begin
      flagMapFile := True;
      Inc(i);
    end
    else if param = '--runtime-checks' then
    begin
      flagRuntimeChecks := True;
      Inc(i);
    end
    else if param = '--profile' then
    begin
      flagProfile := True;
      Inc(i);
    end
    else if param = '--trace' then
    begin
      flagTrace := True;
      Inc(i);
    end
    else if param = '--provenance' then
    begin
      flagProvenance := True;
      Inc(i);
    end
    else if param = '--ast-dump' then
    begin
      flagAstdump := True;
      Inc(i);
    end
    else if param = '--symtab-dump' then
    begin
      flagSymtabdump := True;
      Inc(i);
    end
    else if param = '--trace-passes' then
    begin
      flagTracepasses := True;
      Inc(i);
    end
    else if param = '--compile-unit' then
    begin
      flagCompileUnit := True;
      Inc(i);
    end
    else if param = '--unit-info' then
    begin
      flagUnitInfo := True;
      Inc(i);
    end
    else if param = '--debug-symbols' then
    begin
      flagDebugSymbols := True;
      Inc(i);
    end
    else if param = '-g' then
    begin
      // DWARF debug info (same as -g in gcc/clang)
      flagDebugSymbols := True;
      Inc(i);
    end
    else if Copy(param, 1, 3) = '-t=' then
    begin
      // -t=x86_64 for unit target arch
      param := Copy(param, 4, MaxInt);
      unitTargetArch := StrToArch(param);
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

  WriteLn('Lyx Compiler v0.8.2-aerospace');
  WriteLn('DO-178C TQL-5 Qualified');
  WriteLn('Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
  WriteLn;
  WriteLn('Eingabe:  ', inputFile);
  if flagCompileUnit then
    WriteLn('Modus:    Unit-Kompilierung')
  else if flagUnitInfo then
    WriteLn('Modus:    Unit-Info')
  else
  begin
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
  end;

  // Energy-Konfiguration setzen (vor der Statusausgabe)
  if (flagEnergyLevel > 0) and not flagUnitInfo and not flagCompileUnit then
  begin
    case target of
      targetLinux: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfX86_64);
      targetLinuxARM64: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfARM64);
      targetWindows: SetEnergyLevel(TEnergyLevel(flagEnergyLevel), cfX86_64);
    end;
  end;

  if (flagEnergyLevel > 0) and not flagUnitInfo and not flagCompileUnit then
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

{ ====== PRECOMPILED UNIT MODE ====== }
  if flagCompileUnit then
  begin
    WriteLn;
    WriteLn('--- Unit-Kompilierungs-Modus ---');
    
    // Determine output file
    if unitOutputFile = '' then
    begin
      // Remove .lyx extension if present, add .lyu
      if RightStr(inputFile, 4) = '.lyx' then
        unitOutputFile := Copy(inputFile, 1, Length(inputFile) - 4) + '.lyu'
      else
        unitOutputFile := inputFile + '.lyu';
    end;
    
    WriteLn('Ausgabe: ', unitOutputFile);
    WriteLn('Ziel:   ', ArchToStr(unitTargetArch));
    if flagDebugSymbols then
      WriteLn('Debug-Symbole: aktiviert');
    WriteLn;
    
    // Phase 1: Parse die .lyx Datei
    src := TStringList.Create;
    d := TDiagnostics.Create;
    try
      src.LoadFromFile(inputFile);
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

      // WP-A: AST Visualization
      if flagAstdump and Assigned(prog) then
        DumpASTTree(prog);
      
      if d.HasErrors then
      begin
        d.PrintAll;
        Halt(1);
      end;
      
      // Phase 2: Extrahiere alle pub fn Symbole
      if Assigned(prog) and Assigned(prog.Decls) then
      begin
        for i := 0 to High(prog.Decls) do
        begin
          if prog.Decls[i] is TAstFuncDecl then
          begin
            fn := TAstFuncDecl(prog.Decls[i]);
            if fn.IsPublic then
            begin
              SetLength(lyuSymbols, Length(lyuSymbols) + 1);
              symIdx := High(lyuSymbols);
              lyuSymbols[symIdx].Name := fn.Name;
              lyuSymbols[symIdx].Kind := lskFn;
              lyuSymbols[symIdx].TypeHash := UInt32(Ord(fn.ReturnType));
              // TypeInfo: "retType" or "retType:param1,param2,..." for import reconstruction
              lyuSymbols[symIdx].TypeInfo := FormatType(fn.ReturnType);
              if Length(fn.Params) > 0 then
              begin
                lyuSymbols[symIdx].TypeInfo := lyuSymbols[symIdx].TypeInfo + ':';
                for j := 0 to High(fn.Params) do
                begin
                  if j > 0 then
                    lyuSymbols[symIdx].TypeInfo := lyuSymbols[symIdx].TypeInfo + ',';
                  lyuSymbols[symIdx].TypeInfo := lyuSymbols[symIdx].TypeInfo + FormatType(fn.Params[j].ParamType);
                end;
              end;
              WriteLn('  Exportiere: pub fn ', fn.Name, ' -> ', lyuSymbols[symIdx].TypeInfo);
            end;
          end;
        end;
      end;
      
      WriteLn;
      WriteLn('Gefundene Symbole: ', Length(lyuSymbols));

      // Phase 3: Sema (needed for IR lowering)
      s := TSema.Create(d);
      um := TUnitManager.Create(d);
      module := nil;
      try
        um.SetSourceFile(inputFile);
        um.SetProjectRoot(GetCurrentDir);
        um.LoadAllImports(prog, inputFile);
        s.AnalyzeWithUnits(prog, um);
        if d.HasErrors then
        begin
          d.PrintAll;
          Halt(1);
        end;

        // Phase 4: Lower to IR
        module := TIRModule.Create;
        lower := TIRLowering.Create(module, d);
        try
          lower.LowerImportedUnits(um);
          lower.Lower(prog);
        finally
          lower.Free;
        end;
      finally
        s.Free;
        um.Free;
      end;

    finally
      d.Free;
      src.Free;
      if Assigned(prog) then prog.Free;
    end;

    // Phase 5: Serialize to .lyu (symbols + IR)
    buffer := TByteBuffer.Create;
    ser := TLyuxSerializer.Create(nil, unitTargetArch, flagDebugSymbols);
    try
      unitName := ExtractFileName(inputFile);
      if RightStr(unitName, 4) = '.lyx' then
        unitName := Copy(unitName, 1, Length(unitName) - 4);
      ser.Serialize(unitName, lyuSymbols, Length(lyuSymbols), buffer);
      if Assigned(module) then
        ser.AppendIRSection(module, buffer);
      if Assigned(module) then
        module.Free;
      try
        buffer.SaveToFile(unitOutputFile);
      finally
        buffer.Free;
      end;
    finally
      ser.Free;
    end;

    WriteLn;
    WriteLn('Erfolgreich kompiliert: ', unitOutputFile);
    WriteLn('Symbol-Count: ', Length(lyuSymbols));
    Halt(0);
  end;

  { ====== UNIT INFO MODE ====== }
  if flagUnitInfo then
  begin
    WriteLn;
    WriteLn('--- Unit-Info-Modus ---');
    
    // Prüfe ob die Datei existiert
    if not FileExists(inputFile) then
    begin
      WriteLn(StdErr, 'Fehler: Datei nicht gefunden: ', inputFile);
      Halt(1);
    end;
    
    // Lade die .lyu als Binärdatei
    buffer := TByteBuffer.Create;
    d := TDiagnostics.Create;
    ser := TLyuxSerializer.Create(nil, la_x86_64, False);
    try
      buffer.LoadFromFile(inputFile);
      
      // Deserialisiere die .lyu
      loadedUnit := TLoadedLyux.Create;
      try
        deser := TLyuxDeserializer.Create(d);
        try
          deser.Deserialize(buffer, loadedUnit);
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'Fehler beim Lesen der .lyu: ', E.Message);
            Halt(1);
          end;
        end;
        
        // Ausgabe der Informationen
        WriteLn;
        WriteLn('Unit: ', loadedUnit.Header.UnitName);
        WriteLn('Version: ', loadedUnit.Header.Version);
        WriteLn('Target: ', ArchToStr(loadedUnit.Header.TargetArch));
        if (loadedUnit.Header.Flags and 1) <> 0 then
          WriteLn('Debug-Symbole: vorhanden')
        else
          WriteLn('Debug-Symbole: nicht vorhanden');
        WriteLn;
        WriteLn('Exportierte Symbole: ', loadedUnit.Header.SymbolCount);
        
        // Zeige alle Symbole
        for i := 0 to loadedUnit.Header.SymbolCount - 1 do
        begin
          case loadedUnit.Symbols[i].Kind of
            lskFn:     Write('  pub fn ');
            lskVar:    Write('  pub var ');
            lskLet:    Write('  pub let ');
            lskCon:    Write('  pub con ');
            lskStruct: Write('  pub struct ');
            lskClass:  Write('  pub class ');
            lskEnum:   Write('  pub enum ');
            lskExternFn: Write('  pub extern fn ');
          else
            Write('  pub ??? ');
          end;
          Write(loadedUnit.Symbols[i].Name);
          if loadedUnit.Symbols[i].TypeInfo <> '' then
            Write('(', loadedUnit.Symbols[i].TypeInfo, ')');
          WriteLn;
        end;
        
        // Zeige IR-Informationen falls vorhanden
        if Assigned(loadedUnit.IRModule) then
        begin
          WriteLn;
          WriteLn('IR-Code: ', Length(loadedUnit.IRModule.Functions), ' Funktion(en)');
          for i := 0 to High(loadedUnit.IRModule.Functions) do
            WriteLn('  fn ', loadedUnit.IRModule.Functions[i].Name, 
                    ' (params=', loadedUnit.IRModule.Functions[i].ParamCount,
                    ', locals=', loadedUnit.IRModule.Functions[i].LocalCount, ')');
        end;
        
      finally
        loadedUnit.Free;
        deser.Free;
      end;
    finally
      buffer.Free;
      d.Free;
      ser.Free;
    end;
    
    Halt(0);
  end;

  { ====== NORMAL COMPILATION MODE ====== }

  src := TStringList.Create;
  try
    src.LoadFromFile(inputFile);
    d := TDiagnostics.Create;
    try
      // Phase 1: Parse Hauptdatei
      EnterPass('Lexer', inputFile + ' (' + IntToStr(src.Text.Length) + ' bytes)');
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
      LeavePass('Lexer', '(lexer complete)');

      EnterPass('Parser', '(tokens ready)');
      if Assigned(prog) and Assigned(prog.Decls) then
        LeavePass('Parser', 'AST: ' + IntToStr(Length(prog.Decls)) + ' declarations')
      else
        LeavePass('Parser', 'AST: (empty)');

      // WP-A: AST Visualization
      if flagAstdump and Assigned(prog) then
        DumpASTTree(prog);

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
        EnterPass('Semantic Analysis', 'AST: ' + IntToStr(Length(prog.Decls)) + ' declarations');
        s := TSema.Create(d);
        try
          s.AnalyzeWithUnits(prog, um);
          if d.HasErrors then
          begin
            d.PrintAll;
            Halt(1);
          end;
          // Print any warnings (e.g. safety-pragma warnings) even on success
          if d.WarningCount > 0 then
            d.PrintAll;

          // WP-B: Symbol Table Dump
          if flagSymtabdump then
            s.DumpSymbolTable;
        finally
          s.Free;
        end;
        LeavePass('Semantic Analysis', 'Typed AST: ' + IntToStr(Length(prog.Decls)) + ' declarations');

        // Call Graph Analysis (DO-178C Section 6.1 - WCET-Analyse)
        if flagCallGraph then
        begin
          WriteLn('[Call Graph] Building static call graph...');
          cg := TCallGraph.Create(d);
          try
            cg.BuildFromAST(prog);
            WriteLn('[Call Graph] Found ', cg.GetFunctionCount, ' function(s)');
            if cg.HasRecursion then
              WriteLn('[Call Graph] WARNING: Recursion detected!');
            WriteLn;
            WriteLn(cg.ExportText);
          finally
            cg.Free;
          end;
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
        module.ProgramNode := prog;  { Für Call-Graph-Analyse }
        lower := TIRLowering.Create(module, d);
        try
          // First, register constants from imported units so they're available during lowering
          EnterPass('IR Lowering', 'Typed AST: ' + IntToStr(Length(prog.Decls)) + ' declarations');
          lower.LowerImportedUnits(um);
          // Merge IR from precompiled units (.lyu) - simple version
          MergePrecompiledIR(um, module);
          // Then lower the main program
          lower.Lower(prog);
          LeavePass('IR Lowering', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions');

          // IR-Level Inlining Optimization
          EnterPass('IR Inlining', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions');
          WriteLn('[IR] Running inlining optimization...');
          inliner := TIRInlining.Create(module);
          try
            inliner.Optimize;
          finally
            inliner.Free;
          end;
          LeavePass('IR Inlining', 'Inlined functions: 0');

          // --emit-asm: Dump IR BEFORE optimization
          if flagEmitAsm then
          begin
            WriteLn('; === IR (before optimization) ===');
            DumpIRAsAsm(module);
          end;

          // IR-Level Optimizations (Constant Folding, CSE, DCE, etc.)
          if flagOptimize then
          begin
            EnterPass('IR Optimization', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions');
            WriteLn('[IR] Running IR optimizations...');
            optimizer := TIROptimizer.Create(module);
            try
              optimizer.Optimize;
              if optimizer.Changed then
                WriteLn('[IR] IR optimized: ', optimizer.PassCount, ' passes');
            finally
              optimizer.Free;
            end;
            LeavePass('IR Optimization', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions (optimized)');
          end
          else
          begin
            WriteLn('[IR] IR optimizations disabled');
            LeavePass('IR Optimization', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions (no optimization)');
          end;

          // Map File Generation (DO-178C Section 6.1 - Memory Layout)
          if flagMapFile then
          begin
            WriteLn('[Map File] Generating memory layout...');
            mapGen := TMapFileGenerator.Create(d);
            try
              mapGen.GenerateFromModule(module, outputFile + '.map');
              WriteLn('[Map File] Done');
            finally
              mapGen.Free;
            end;
          end;

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

          // Static Analysis (DO-178C Section 5.1)
          if flagStaticAnalysis then
          begin
            WriteLn('[Static Analysis] Running static analysis...');
            sa := TStaticAnalyzer.Create(module, d);
            try
              sa.RunAll;
              sa.GenerateReport;
            finally
              sa.Free;
            end;
          end;

// Provenance Tracking (WP-F): Output IR→AST→Source mapping
          if flagProvenance then
          begin
            WriteLn('=== Provenance Chain (WP-F) ===');
            WriteLn('Provenance tracking enabled. IR instructions now carry AST source IDs.');
          end;

          // --emit-asm: Dump IR as pseudo-assembly
          if flagEmitAsm then
            DumpIRAsAsm(module);

          // --asm-listing: Assembly listing with source lines (DO-178C 6.1)
          // This is done per-target after code generation

          EnterPass('Code Generation', 'IR Module: ' + IntToStr(Length(module.Functions)) + ' functions');

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
  
                // TMR Hash Store: Patch CRC32 hashes if VerifyIntegrity() was used (aerospace-todo P0 #46)
                if (target = targetLinux) and (arch = archX86_64) then
                begin
                  // Cast to access TMR-specific methods
                  x86Emit := TX86_64Emitter(emit);
                  if x86Emit.HasVerifyIntegrityCall then
                  begin
                    WriteLn('Patching TMR hash store with CRC32 values...');
                    codeSize := codeBuf.Size;
                    codeStartVA := $400000 + 4096;

                    // Calculate data section VA: code_start_va + code_size (no alignment needed)
                    // The ELF writer writes data directly after code without padding
                    dataVA := codeStartVA + UInt64(codeSize);

                    // Patch the movabs rdi, data_va placeholder in code FIRST
                    // (this changes the code, so CRC32 must be computed AFTER)
                    dataAddrPos := x86Emit.GetTMRDataAddrPos;
                    codeBuf.PatchU64LE(dataAddrPos, dataVA);

                    // NOW compute CRC32 of the patched code
                    hashCrc := Crc32Buffer(codeBuf);

                    // Write TMR hash store to data buffer at position 0
                    // The data buffer may already contain strings/globals from the emitter.
                    // We write the hashes at the START of the data buffer.
                    // If dataBuf already has content, we need to prepend the hashes.
                    // Simplest: write hashes at current position, then adjust dataVA.
                    // But the code already loads from dataVA = code_start_va + aligned(code_size).
                    // So we need the hashes at the START of the data section.
                    // If dataBuf is empty, just write. If not, we need to insert at position 0.
                    if dataBuf.Size = 0 then
                    begin
                      dataBuf.WriteU32LE(hashCrc);  // hash1
                      dataBuf.WriteU32LE(hashCrc);  // hash2
                      dataBuf.WriteU32LE(hashCrc);  // hash3
                      dataBuf.WriteU32LE(Cardinal(codeSize));  // code_size
                      dataBuf.WriteU64LE(codeStartVA);  // code_start_va
                    end
                    else
                    begin
                      // Data buffer already has content - write hashes at end
                      // and adjust dataVA to point to the end
                      hashDataOffset := dataBuf.Size;
                      dataBuf.WriteU32LE(hashCrc);  // hash1
                      dataBuf.WriteU32LE(hashCrc);  // hash2
                      dataBuf.WriteU32LE(hashCrc);  // hash3
                      dataBuf.WriteU32LE(Cardinal(codeSize));  // code_size
                      dataBuf.WriteU64LE(codeStartVA);  // code_start_va
                      // Update dataVA to point to the hashes
                      dataVA := codeStartVA + UInt64(codeSize) + UInt64(hashDataOffset);
                      // Re-patch the movabs with the corrected dataVA
                      codeBuf.PatchU64LE(dataAddrPos, dataVA);
                    end;

                    WriteLn('  CRC32: ', IntToHex(hashCrc, 8));
                    WriteLn('  Code size: ', codeSize, ' bytes');
                    WriteLn('  Data VA: $', IntToHex(dataVA, 8));
                  end;
                end;
 
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
                  if module.UnitIntegrity.Mode <> imNone then
                  begin
                    WriteLn('Generating static ELF with .meta_safe section');
                    WriteElf64WithMetaSafe(outputFile, codeBuf, dataBuf, entryVA, module.UnitIntegrity);
                  end
                  else
                  begin
                    if flagDebugSymbols then
                    begin
                      // Generate DWARF debug info
                      WriteLn('Generating static ELF with DWARF debug info');
                      dwarfGen := TDwarfGenerator.Create(module, ExtractFilePath(inputFile));
                      try
                        dwarfGen.Generate(debugAbbrev, debugInfo, debugLine, debugFrame, debugStr);
                        WriteElf64WithDebug(outputFile, codeBuf, dataBuf, debugAbbrev, debugInfo,
                          debugLine, debugFrame, debugStr, entryVA);
                      finally
                        dwarfGen.Free;
                      end;
                    end
else
                    begin
                      WriteLn('Generating static ELF (no external symbols)');
                      WriteElf64(outputFile, codeBuf, dataBuf, entryVA);
                    end;
                  end;
                end;
 
                // Energy statistics output
                if flagEnergyLevel > 0 then
                  PrintEnergyStats(emit.GetEnergyStats);
  
                // Assembly listing (DO-178C 6.1)
                if flagAsmListing then
                begin
                  al := TAsmListingGenerator.Create(module, codeBuf, dataBuf, 'x86_64');
                  try
                    listingFile := ChangeFileExt(outputFile, '.lst');
                    sl := TStringList.Create;
                    try
                      sl.Text := al.Generate;
                      sl.SaveToFile(listingFile);
                    finally
                      sl.Free;
                    end;
                    WriteLn('Wrote ', listingFile, ' (Assembly Listing)');
                  finally
                    al.Free;
                  end;
end;
   
                FpChmod(PChar(outputFile), 493);
                WriteLn('Wrote ', outputFile);
              finally
                emit.Free;
              end;
              LeavePass('Code Generation', 'x86_64: ' + IntToStr(codeBuf.Size) + ' bytes code, ' + IntToStr(dataBuf.Size) + ' bytes data');
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
                  if module.UnitIntegrity.Mode <> imNone then
                  begin
                    WriteLn('Generating static ELF for Linux ARM64 with .meta_safe section');
                    WriteElf64ARM64WithMetaSafe(outputFile, codeBuf, dataBuf, entryVA, module.UnitIntegrity);
                  end
                  else
                  begin
                    WriteLn('Generating static ELF for Linux ARM64');
                    WriteElf64ARM64(outputFile, codeBuf, dataBuf, entryVA);
                  end;
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

                // Assembly listing (DO-178C 6.1)
                if flagAsmListing then
                begin
                  al := TAsmListingGenerator.Create(module, codeBuf, dataBuf, 'x86_64');
                  try
                    listingFile := ChangeFileExt(outputFile, '.lst');
                    sl := TStringList.Create;
                    try
                      sl.Text := al.Generate;
                      sl.SaveToFile(listingFile);
                    finally
                      sl.Free;
                    end;
                    WriteLn('Wrote ', listingFile, ' (Assembly Listing)');
                  finally
                    al.Free;
                  end;
                end;
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

                 if module.UnitIntegrity.Mode <> imNone then
                 begin
                   WriteLn('Generating static ELF64 for RISC-V RV64GC with .meta_safe section');
                   WriteElf64RISCVWithMetaSafe(outputFile, codeBuf, dataBuf, entryVA, module.UnitIntegrity);
                 end
                 else
                 begin
                   WriteLn('Generating static ELF64 for RISC-V RV64GC');
                   WriteElf64RISCV(outputFile, codeBuf, dataBuf, entryVA);
                 end;

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
  
  // Workaround: Skip finalization to avoid EAccessViolation crash after Dynamic ELF
  // The crash occurs during FPC unit finalization when external libraries are linked.
  // This does not affect the generated binary - it is correctly written.
  Halt(0);
end.
