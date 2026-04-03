{$mode objfpc}{$H+}
program test_ir_coverage;

{
  TOR-011: Vollständige IR-Abdeckung
  Prüft systematisch, welche IR-Operationen in welchen Backends implementiert sind.
}

uses
  SysUtils, Classes, RegExpr;

type
  TBackendCoverage = record
    Name: string;
    FilePath: string;
    TotalOps: Integer;
    CoveredOps: Integer;
    MissingOps: TStringList;
  end;

var
  AllIROps: TStringList;
  Backends: array of TBackendCoverage;
  TotalTests, PassedTests, FailedTests: Integer;

procedure AddIROp(const opName: string);
begin
  AllIROps.Add(opName);
end;

procedure InitIROps;
begin
  // Core arithmetic
  AddIROp('irAdd'); AddIROp('irSub'); AddIROp('irMul'); AddIROp('irDiv'); AddIROp('irMod');
  AddIROp('irNeg'); AddIROp('irNot'); AddIROp('irAnd'); AddIROp('irOr'); AddIROp('irXor');
  AddIROp('irNor');
  // Bit operations
  AddIROp('irBitAnd'); AddIROp('irBitOr'); AddIROp('irBitXor'); AddIROp('irBitNot');
  AddIROp('irShl'); AddIROp('irShr');
  // Float arithmetic
  AddIROp('irFAdd'); AddIROp('irFSub'); AddIROp('irFMul'); AddIROp('irFDiv'); AddIROp('irFNeg');
  // Comparisons
  AddIROp('irCmpEq'); AddIROp('irCmpNeq'); AddIROp('irCmpLt'); AddIROp('irCmpLe');
  AddIROp('irCmpGt'); AddIROp('irCmpGe');
  // Float comparisons
  AddIROp('irFCmpEq'); AddIROp('irFCmpNeq'); AddIROp('irFCmpLt'); AddIROp('irFCmpLe');
  AddIROp('irFCmpGt'); AddIROp('irFCmpGe');
  // Constants
  AddIROp('irConstInt'); AddIROp('irConstStr'); AddIROp('irConstFloat');
  // Load/Store
  AddIROp('irLoadLocal'); AddIROp('irStoreLocal'); AddIROp('irLoadLocalAddr');
  AddIROp('irLoadGlobal'); AddIROp('irStoreGlobal'); AddIROp('irLoadGlobalAddr');
  AddIROp('irLoadStructAddr');
  // Width/Sign
  AddIROp('irSExt'); AddIROp('irZExt'); AddIROp('irTrunc');
  // Float conversion
  AddIROp('irFToI'); AddIROp('irIToF');
  // Type casting
  AddIROp('irCast');
  // Control flow
  AddIROp('irJmp'); AddIROp('irBrTrue'); AddIROp('irBrFalse');
  AddIROp('irLabel'); AddIROp('irFuncExit');
  // Calls
  AddIROp('irCall'); AddIROp('irCallBuiltin'); AddIROp('irCallStruct');
  AddIROp('irVarCall'); AddIROp('irReturnStruct');
  // Array operations
  AddIROp('irStackAlloc'); AddIROp('irStoreElem'); AddIROp('irLoadElem');
  AddIROp('irStoreElemDyn');
  // Dynamic arrays
  AddIROp('irDynArrayPush'); AddIROp('irDynArrayPop');
  AddIROp('irDynArrayLen'); AddIROp('irDynArrayFree');
  // Struct fields
  AddIROp('irLoadField'); AddIROp('irStoreField');
  AddIROp('irLoadFieldHeap'); AddIROp('irStoreFieldHeap');
  // Heap
  AddIROp('irAlloc'); AddIROp('irFree');
  // Closures
  AddIROp('irLoadCaptured');
  // Memory pool
  AddIROp('irPoolAlloc'); AddIROp('irPoolFree');
  // Exception handling
  AddIROp('irPushHandler'); AddIROp('irPopHandler');
  AddIROp('irLoadHandlerExn'); AddIROp('irThrow');
  // Panic
  AddIROp('irPanic');
  // SIMD
  AddIROp('irSIMDAdd'); AddIROp('irSIMDSub'); AddIROp('irSIMDMul'); AddIROp('irSIMDDiv');
  AddIROp('irSIMDAnd'); AddIROp('irSIMDOr'); AddIROp('irSIMDXor'); AddIROp('irSIMDNeg');
  AddIROp('irSIMDCmpEq'); AddIROp('irSIMDCmpNe'); AddIROp('irSIMDCmpLt'); AddIROp('irSIMDCmpLe');
  AddIROp('irSIMDCmpGt'); AddIROp('irSIMDCmpGe');
  AddIROp('irSIMDLoadElem'); AddIROp('irSIMDStoreElem');
  // Map operations
  AddIROp('irMapNew'); AddIROp('irMapGet'); AddIROp('irMapSet');
  AddIROp('irMapContains'); AddIROp('irMapRemove'); AddIROp('irMapLen'); AddIROp('irMapFree');
  // Set operations
  AddIROp('irSetNew'); AddIROp('irSetAdd'); AddIROp('irSetContains');
  AddIROp('irSetRemove'); AddIROp('irSetLen'); AddIROp('irSetFree');
  // Type checking
  AddIROp('irIsType');
  // Debug
  AddIROp('irInspect');
end;

function CheckBackendCoverage(const backendName, filePath: string; out coverage: TBackendCoverage): Boolean;
var
  f: TextFile;
  line, content: string;
  i: Integer;
  found: Boolean;
begin
  coverage.Name := backendName;
  coverage.FilePath := filePath;
  coverage.MissingOps := TStringList.Create;
  coverage.CoveredOps := 0;
  coverage.TotalOps := AllIROps.Count;

  if not FileExists(filePath) then
  begin
    Result := False;
    Exit;
  end;

  // Read entire file
  content := '';
  AssignFile(f, filePath);
  Reset(f);
  while not Eof(f) do
  begin
    ReadLn(f, line);
    content := content + line + LineEnding;
  end;
  CloseFile(f);

  // Check each IR op
  for i := 0 to AllIROps.Count - 1 do
  begin
    // Suche nach dem IR-Op als Case-Label oder else if
    found := (Pos('ir' + Copy(AllIROps[i], 3, MaxInt), content) > 0) and
             ((Pos(' ' + AllIROps[i] + ':', content) > 0) or
              (Pos(' ' + AllIROps[i] + ',', content) > 0) or
              (Pos('TIROpKind.' + AllIROps[i], content) > 0) or
              (Pos('ir' + Copy(AllIROps[i], 3, MaxInt) + ':', content) > 0));
    
    if found then
      Inc(coverage.CoveredOps)
    else
      coverage.MissingOps.Add(AllIROps[i]);
  end;

  Result := True;
end;

procedure AssertCoverage(const testName: string; coverage: TBackendCoverage; minPercent: Integer);
var
  percent: Integer;
begin
  Inc(TotalTests);
  if coverage.TotalOps > 0 then
    percent := Round(coverage.CoveredOps / coverage.TotalOps * 100)
  else
    percent := 0;
  
  if percent >= minPercent then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName, ' (', coverage.CoveredOps, '/', coverage.TotalOps, ' = ', percent, '%)');
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName, ' (', coverage.CoveredOps, '/', coverage.TotalOps, ' = ', percent, '%, min: ', minPercent, '%)');
    if coverage.MissingOps.Count > 0 then
    begin
      WriteLn('  Missing: ', coverage.MissingOps.CommaText);
    end;
  end;
end;

procedure AssertNoCriticalMissing(const testName: string; coverage: TBackendCoverage);
var
  criticalOps: TStringList;
  i: Integer;
  missing: TStringList;
begin
  Inc(TotalTests);
  
  // Kritische IR-Operationen die IMMER implementiert sein müssen
  criticalOps := TStringList.Create;
  criticalOps.Add('irAdd'); criticalOps.Add('irSub'); criticalOps.Add('irMul');
  criticalOps.Add('irDiv'); criticalOps.Add('irMod'); criticalOps.Add('irNeg');
  criticalOps.Add('irAnd'); criticalOps.Add('irOr'); criticalOps.Add('irXor');
  criticalOps.Add('irNot'); criticalOps.Add('irShl'); criticalOps.Add('irShr');
  criticalOps.Add('irCmpEq'); criticalOps.Add('irCmpNeq'); criticalOps.Add('irCmpLt');
  criticalOps.Add('irCmpLe'); criticalOps.Add('irCmpGt'); criticalOps.Add('irCmpGe');
  criticalOps.Add('irConstInt'); criticalOps.Add('irConstStr');
  criticalOps.Add('irLoadLocal'); criticalOps.Add('irStoreLocal');
  criticalOps.Add('irLoadGlobal'); criticalOps.Add('irStoreGlobal');
  criticalOps.Add('irLoadGlobalAddr'); criticalOps.Add('irLoadLocalAddr');
  criticalOps.Add('irJmp'); criticalOps.Add('irBrTrue'); criticalOps.Add('irBrFalse');
  criticalOps.Add('irLabel'); criticalOps.Add('irFuncExit');
  criticalOps.Add('irCall'); criticalOps.Add('irCallBuiltin');
  criticalOps.Add('irPanic');
  criticalOps.Add('irLoadElem'); criticalOps.Add('irStoreElem');
  criticalOps.Add('irStoreElemDyn');
  criticalOps.Add('irAlloc'); criticalOps.Add('irFree');
  criticalOps.Add('irDynArrayPush'); criticalOps.Add('irDynArrayPop');
  criticalOps.Add('irDynArrayLen'); criticalOps.Add('irDynArrayFree');
  criticalOps.Add('irMapNew'); criticalOps.Add('irMapGet'); criticalOps.Add('irMapSet');
  criticalOps.Add('irMapContains'); criticalOps.Add('irMapRemove');
  criticalOps.Add('irMapLen'); criticalOps.Add('irMapFree');
  criticalOps.Add('irSetNew'); criticalOps.Add('irSetAdd');
  criticalOps.Add('irSetContains'); criticalOps.Add('irSetRemove');
  criticalOps.Add('irSetLen'); criticalOps.Add('irSetFree');
  criticalOps.Add('irLoadField'); criticalOps.Add('irStoreField');
  criticalOps.Add('irLoadFieldHeap'); criticalOps.Add('irStoreFieldHeap');
  criticalOps.Add('irSExt'); criticalOps.Add('irZExt'); criticalOps.Add('irTrunc');
  criticalOps.Add('irFToI'); criticalOps.Add('irIToF');
  criticalOps.Add('irFAdd'); criticalOps.Add('irFSub'); criticalOps.Add('irFMul');
  criticalOps.Add('irFDiv'); criticalOps.Add('irFNeg');
  criticalOps.Add('irFCmpEq'); criticalOps.Add('irFCmpNeq');
  criticalOps.Add('irFCmpLt'); criticalOps.Add('irFCmpLe');
  criticalOps.Add('irFCmpGt'); criticalOps.Add('irFCmpGe');
  criticalOps.Add('irConstFloat');
  criticalOps.Add('irSIMDAdd'); criticalOps.Add('irSIMDSub');
  criticalOps.Add('irSIMDMul'); criticalOps.Add('irSIMDDiv');
  criticalOps.Add('irSIMDLoadElem'); criticalOps.Add('irSIMDStoreElem');
  criticalOps.Add('irBitAnd'); criticalOps.Add('irBitOr');
  criticalOps.Add('irBitXor'); criticalOps.Add('irBitNot');
  criticalOps.Add('irNor');

  missing := TStringList.Create;
  try
    for i := 0 to criticalOps.Count - 1 do
    begin
      if coverage.MissingOps.IndexOf(criticalOps[i]) >= 0 then
        missing.Add(criticalOps[i]);
    end;
    
    if missing.Count = 0 then
    begin
      Inc(PassedTests);
      WriteLn('[PASS] ', testName, ' - No critical ops missing');
    end
    else
    begin
      Inc(FailedTests);
      WriteLn('[FAIL] ', testName, ' - ', missing.Count, ' critical ops missing:');
      WriteLn('  ', missing.CommaText);
    end;
  finally
    missing.Free;
    criticalOps.Free;
  end;
end;

var
  cov: TBackendCoverage;
  i: Integer;
  baseDir: string;
begin
  TotalTests := 0;
  PassedTests := 0;
  FailedTests := 0;

  WriteLn('========================================');
  WriteLn('TOR-011: IR Coverage Analysis');
  WriteLn('========================================');

  // Determine base directory
  baseDir := ExtractFilePath(ParamStr(0));
  if Pos('/tests/', baseDir) > 0 then
    baseDir := baseDir + '../'
  else if Pos('/compiler/', baseDir) > 0 then
    baseDir := baseDir
  else
    baseDir := './';

  AllIROps := TStringList.Create;
  InitIROps;
  WriteLn('Total IR operations to check: ', AllIROps.Count);
  WriteLn;

  // Check each backend
  SetLength(Backends, 6);
  Backends[0].Name := 'x86_64';
  Backends[0].FilePath := baseDir + 'backend/x86_64/x86_64_emit.pas';
  Backends[1].Name := 'x86_64_win64';
  Backends[1].FilePath := baseDir + 'backend/x86_64/x86_64_win64.pas';
  Backends[2].Name := 'arm64';
  Backends[2].FilePath := baseDir + 'backend/arm64/arm64_emit.pas';
  Backends[3].Name := 'macosx64';
  Backends[3].FilePath := baseDir + 'backend/macosx64/macosx64_emit.pas';
  Backends[4].Name := 'xtensa';
  Backends[4].FilePath := baseDir + 'backend/xtensa/xtensa_emit.pas';
  Backends[5].Name := 'win_arm64';
  Backends[5].FilePath := baseDir + 'backend/win_arm64/win_arm64_emit.pas';

  for i := 0 to High(Backends) do
  begin
    WriteLn('--- Backend: ', Backends[i].Name, ' ---');
    if CheckBackendCoverage(Backends[i].Name, Backends[i].FilePath, cov) then
    begin
      WriteLn('  Covered: ', cov.CoveredOps, '/', cov.TotalOps, ' (',
              Round(cov.CoveredOps / cov.TotalOps * 100), '%)');
      
      // TOR-011: Mindestens 80% Abdeckung für jedes Backend
      AssertCoverage('TOR-011: ' + Backends[i].Name + ' >= 80%', cov, 80);
      
      // Keine kritischen Operationen dürfen fehlen
      AssertNoCriticalMissing('TOR-011: ' + Backends[i].Name + ' critical ops', cov);
    end
    else
    begin
      WriteLn('  File not found: ', Backends[i].FilePath);
      Inc(TotalTests);
      Inc(FailedTests);
      WriteLn('[FAIL] ', Backends[i].Name, ' - Backend file not found');
    end;
    WriteLn;
  end;

  // Summary
  WriteLn('========================================');
  WriteLn('TOR-011: IR Coverage Summary');
  WriteLn('========================================');
  WriteLn('Total Tests: ', TotalTests);
  WriteLn('Passed:      ', PassedTests);
  WriteLn('Failed:      ', FailedTests);
  WriteLn;

  // Print missing ops summary
  WriteLn('Missing Operations Summary:');
  for i := 0 to High(Backends) do
  begin
    if CheckBackendCoverage(Backends[i].Name, Backends[i].FilePath, cov) then
    begin
      if cov.MissingOps.Count > 0 then
      begin
        WriteLn('  ', Backends[i].Name, ' (', cov.MissingOps.Count, ' missing):');
        WriteLn('    ', cov.MissingOps.CommaText);
      end;
    end;
  end;

  WriteLn;
  if FailedTests > 0 then
  begin
    WriteLn('TOR-011 VALIDATION: FAILED');
    Halt(1);
  end
  else
  begin
    WriteLn('TOR-011 VALIDATION: PASSED');
    Halt(0);
  end;
end.
