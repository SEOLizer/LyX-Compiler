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
  i: Integer;
  param: string;

type
  TStringArray = array of string;

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
    WriteLn(StdErr, 'Lyx Compiler v0.1.7');
    WriteLn(StdErr, 'Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Verwendung: lyxc <datei.lyx> [-o <output>] [--target=win64|linux|arm64]');
    WriteLn(StdErr);
    WriteLn(StdErr, 'Optionen:');
    WriteLn(StdErr, '  -o <datei>     Ausgabedatei (Standard: a.out bzw. a.exe)');
    WriteLn(StdErr, '  --target=TARGET Zielplattform (win64, linux oder arm64)');
    Halt(1);
  end;

  inputFile := '';
  outputFile := '';

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

  WriteLn('Lyx Compiler v0.1.7');
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
              entryVA := $400000 + 4096;
              
              // Check if we have external symbols - if so, generate dynamic ELF
              externSymbols := emit.GetExternalSymbols;
              if Length(externSymbols) > 0 then
              begin
                // Build unique library list
                neededLibs := CollectLibraries(externSymbols);
                WriteLn('Generating dynamic ELF with ', Length(externSymbols), ' external symbols');
                WriteDynamicElf64WithPatches(outputFile, codeBuf, dataBuf, entryVA, externSymbols, neededLibs, emit.GetPLTGOTPatches);
              end
              else
              begin
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
