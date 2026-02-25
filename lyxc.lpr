{$mode objfpc}{$H+}
program lyxc;

uses
  SysUtils, Classes, BaseUnix,
  bytes, backend_types,
  diag, lexer, parser, ast, sema, unit_manager,
  ir, lower_ast_to_ir,
  x86_64_emit, elf64_writer,
  x86_64_win64, pe64_writer,
  arm64_emit, elf64_arm64_writer;

type
  TTarget = (targetLinux, targetWindows, targetLinuxARM64);

var
  inputFile: string;
  outputFile: string;
  target: TTarget;
  flagEmitAsm: Boolean;
  flagDumpRelocs: Boolean;
  src: TStringList;
  d: TDiagnostics;
  lx: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  module: TIRModule;
  lower: TIRLowering;
  emit: TX86_64Emitter;
  winEmit: TWin64Emitter;
  arm64Emit: TARM64Emitter;
  codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64;
  basePath: string;
  externSymbols: TExternalSymbolArray;
  neededLibs: array of string;
  pltPatches: TPLTGOTPatchArray;
  i, j: Integer;
  param: string;

type
  TStringArray = array of string;

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
    WriteLn(';   .global ', m.GlobalVars[fi].Name, ' = ', m.GlobalVars[fi].InitValue);
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
        irReturn: begin
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
  {$ELSE}
  target := targetLinux;
  {$ENDIF}
  
    if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'Lyx Compiler v0.2.0');
    WriteLn(StdErr, 'Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Verwendung: lyxc <datei.lyx> [-o <output>] [--target=win64|linux|arm64]');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Optionen:');
    WriteLn(StdErr, '  -o <datei>       Ausgabedatei (Standard: a.out bzw. a.exe)');
    WriteLn(StdErr, '  --target=TARGET  Zielplattform (win64, linux oder arm64)');
    WriteLn(StdErr, '  --emit-asm       IR als Pseudo-Assembler ausgeben');
    WriteLn(StdErr, '  --dump-relocs    Relocations und externe Symbole anzeigen');
    Halt(1);
  end;

  inputFile := '';
  outputFile := '';
  flagEmitAsm := False;
  flagDumpRelocs := False;

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
        target := targetWindows
      else if (param = 'linux') or (param = 'elf') then
        target := targetLinux
      else if (param = 'arm64') or (param = 'aarch64') or (param = 'linux-arm64') then
        target := targetLinuxARM64
      else
      begin
        WriteLn(StdErr, 'Unbekanntes Ziel: ', param);
        WriteLn(StdErr, 'Gültige Werte: win64, linux, arm64');
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

  WriteLn('Lyx Compiler v0.3.1');
  WriteLn('Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
  WriteLn;
  WriteLn('Eingabe:  ', inputFile);
  WriteLn('Ausgabe:  ', outputFile);
  if target = targetWindows then
    WriteLn('Ziel:     Windows x64 (PE32+)')
  else if target = targetLinux then
    WriteLn('Ziel:     Linux x86_64 (ELF64)')
  else if target = targetLinuxARM64 then
    WriteLn('Ziel:     Linux ARM64 (ELF64)');

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
        um.AddSearchPath(basePath);
        um.LoadAllImports(prog, basePath);

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

        module := TIRModule.Create;
        lower := TIRLowering.Create(module, d);
        try
          lower.Lower(prog);
          // Lower imported unit functions into the IR module
          lower.LowerImportedUnits(um);

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
            // Linux x86_64 Code Generation (existing path)
            emit := TX86_64Emitter.Create;
            try
              emit.EmitFromIR(module);
              codeBuf := emit.GetCodeBuffer;
              dataBuf := emit.GetDataBuffer;
              // Entry point is the generated _start placed at code base + 0x1000
              // For static ELF: entryVA := $400000 + 4096;
              // For dynamic (PIE) ELF: entryVA := 4096 (page-aligned)
              externSymbols := emit.GetExternalSymbols;
              if Length(externSymbols) > 0 then
              begin
                entryVA := 4096;  // PIE: entry at page start
                // Build unique library list
                neededLibs := CollectLibraries(externSymbols);
                WriteLn('Generating dynamic ELF with ', Length(externSymbols), ' external symbols');
                WriteDynamicElf64WithPatches(outputFile, codeBuf, dataBuf, entryVA, externSymbols, neededLibs, emit.GetPLTGOTPatches);
              end
              else
              begin
                entryVA := $400000 + 4096;  // Static: traditional address
                WriteLn('Generating static ELF (no external symbols)');
                WriteElf64(outputFile, codeBuf, dataBuf, entryVA);
              end;
              
              FpChmod(PChar(outputFile), 493);
              WriteLn('Wrote ', outputFile);
            finally
              emit.Free;
            end;
          end
          else
          begin
            // Linux ARM64 Code Generation
            arm64Emit := TARM64Emitter.Create;
            try
              arm64Emit.EmitFromIR(module);
              codeBuf := arm64Emit.GetCodeBuffer;
              dataBuf := arm64Emit.GetDataBuffer;
              entryVA := $400000 + 4096;
              
              // Note: dynamic linking for ARM64 not implemented yet
              WriteLn('Generating static ELF for Linux ARM64 (no dynamic linking yet)');
              WriteElf64ARM64(outputFile, codeBuf, dataBuf, entryVA);
              
              FpChmod(PChar(outputFile), 493);
              WriteLn('Wrote ', outputFile, ' (ELF64 for Linux ARM64)');
            finally
              arm64Emit.Free;
            end;
          end;
        finally
          lower.Free;
          module.Free;
        end;
      finally
        um.Free;
      end;

    finally
      d.Free;
    end;
  finally
    src.Free;
  end;
end.
