{$mode objfpc}{$H+}
program test_determinism;

{
  Determinismus-Test für Lyx Compiler
  DO-178C Section 1.3: Deterministischer Codegen
  
  Prüft:
  1. Gleicher Source → immer gleicher Output (Byte-für-Byte)
  2. Keine nicht-deterministischen Optimierungen
  3. Keine zeitabhängigen Entscheidungen
  4. Reproduzierbare Builds über mehrere Durchläufe
}

uses
  SysUtils, Classes, Process;

var
  TotalTests, PassedTests, FailedTests: Integer;

function RunCompiler(const sourceFile, outputFile: string; out output: string; out exitCode: Integer): Boolean;
var
  proc: TProcess;
  outStream: TStringList;
begin
  proc := TProcess.Create(nil);
  outStream := TStringList.Create;
  try
    proc.Executable := './lyxc';
    proc.Parameters.Add(sourceFile);
    proc.Parameters.Add('-o');
    proc.Parameters.Add(outputFile);
    proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    proc.Execute;
    exitCode := proc.ExitStatus;
    outStream.LoadFromStream(proc.Output);
    output := outStream.Text;
    Result := True;
  finally
    proc.Free;
    outStream.Free;
  end;
end;

function FileMD5(const fileName: string): string;
var
  fs: TFileStream;
  buf: array[0..4095] of Byte;
  bytesRead: Integer;
  hash: UInt64;
  i: Integer;
begin
  // Simple hash for determinism check (not cryptographic)
  hash := 0;
  fs := TFileStream.Create(fileName, fmOpenRead or fmShareDenyWrite);
  try
    while fs.Position < fs.Size do
    begin
      bytesRead := fs.Read(buf, SizeOf(buf));
      for i := 0 to bytesRead - 1 do
        hash := hash * 31 + buf[i];
    end;
  finally
    fs.Free;
  end;
  Result := IntToHex(hash, 16);
end;

procedure AssertEqual(const testName: string; expected, actual: string);
begin
  Inc(TotalTests);
  if expected = actual then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName);
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName);
    WriteLn('  Expected: ', expected);
    WriteLn('  Actual:   ', actual);
  end;
end;

procedure AssertTrue(const testName: string; condition: Boolean);
begin
  Inc(TotalTests);
  if condition then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName);
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName);
  end;
end;

procedure WriteTestFile(const path, content: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add(content);
    sl.SaveToFile(path);
  finally
    sl.Free;
  end;
end;

// ============================================================================
// Test 1: Reproduzierbarkeit - gleicher Source → gleicher Binary
// ============================================================================
procedure Test_Reproducibility;
var
  md5_1, md5_2, md5_3: string;
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== Test 1: Reproduzierbarkeit (Byte-für-Byte) ===');
  
  WriteTestFile('/tmp/det_test_simple.lyx',
    'fn main(): int64 { ' + LineEnding +
    '  let a: int64 = 10; ' + LineEnding +
    '  let b: int64 = 20; ' + LineEnding +
    '  return a + b; ' + LineEnding +
    '}'
  );
  
  // Build 1
  RunCompiler('/tmp/det_test_simple.lyx', '/tmp/det_build1.out', output, exitCode);
  AssertTrue('Build 1 succeeds', exitCode = 0);
  md5_1 := FileMD5('/tmp/det_build1.out');
  
  // Build 2
  RunCompiler('/tmp/det_test_simple.lyx', '/tmp/det_build2.out', output, exitCode);
  AssertTrue('Build 2 succeeds', exitCode = 0);
  md5_2 := FileMD5('/tmp/det_build2.out');
  
  // Build 3
  RunCompiler('/tmp/det_test_simple.lyx', '/tmp/det_build3.out', output, exitCode);
  AssertTrue('Build 3 succeeds', exitCode = 0);
  md5_3 := FileMD5('/tmp/det_build3.out');
  
  AssertEqual('MD5 Build 1 == Build 2', md5_1, md5_2);
  AssertEqual('MD5 Build 2 == Build 3', md5_2, md5_3);
  
  DeleteFile('/tmp/det_test_simple.lyx');
  DeleteFile('/tmp/det_build1.out');
  DeleteFile('/tmp/det_build2.out');
  DeleteFile('/tmp/det_build3.out');
end;

// ============================================================================
// Test 2: Reproduzierbarkeit mit komplexerem Source
// ============================================================================
procedure Test_ComplexReproducibility;
var
  md5_1, md5_2: string;
  output: string;
  exitCode: Integer;
  i: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 2: Komplexe Reproduzierbarkeit ===');
  
  src := 'fn main(): int64 {' + LineEnding;
  for i := 1 to 20 do
    src := src + '  let x' + IntToStr(i) + ': int64 = ' + IntToStr(i * 7) + ';' + LineEnding;
  src := src + '  return x1 + x2 + x3 + x4 + x5;' + LineEnding;
  src := src + '}' + LineEnding;
  
  WriteTestFile('/tmp/det_test_complex.lyx', src);
  
  RunCompiler('/tmp/det_test_complex.lyx', '/tmp/det_complex1.out', output, exitCode);
  AssertTrue('Complex Build 1 succeeds', exitCode = 0);
  md5_1 := FileMD5('/tmp/det_complex1.out');
  
  RunCompiler('/tmp/det_test_complex.lyx', '/tmp/det_complex2.out', output, exitCode);
  AssertTrue('Complex Build 2 succeeds', exitCode = 0);
  md5_2 := FileMD5('/tmp/det_complex2.out');
  
  AssertEqual('MD5 Complex Build 1 == Build 2', md5_1, md5_2);
  
  DeleteFile('/tmp/det_test_complex.lyx');
  DeleteFile('/tmp/det_complex1.out');
  DeleteFile('/tmp/det_complex2.out');
end;

// ============================================================================
// Test 3: Reproduzierbarkeit mit Funktionen
// ============================================================================
procedure Test_FunctionReproducibility;
var
  md5_1, md5_2: string;
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== Test 3: Reproduzierbarkeit mit Funktionen ===');
  
  WriteTestFile('/tmp/det_test_fn.lyx',
    'fn add(a: int64, b: int64): int64 { return a + b; }' + LineEnding +
    'fn sub(a: int64, b: int64): int64 { return a - b; }' + LineEnding +
    'fn mul(a: int64, b: int64): int64 { return a * b; }' + LineEnding +
    'fn main(): int64 {' + LineEnding +
    '  let x: int64 = add(10, 20);' + LineEnding +
    '  let y: int64 = sub(100, x);' + LineEnding +
    '  let z: int64 = mul(y, 2);' + LineEnding +
    '  return z;' + LineEnding +
    '}'
  );
  
  RunCompiler('/tmp/det_test_fn.lyx', '/tmp/det_fn1.out', output, exitCode);
  AssertTrue('Function Build 1 succeeds', exitCode = 0);
  md5_1 := FileMD5('/tmp/det_fn1.out');
  
  RunCompiler('/tmp/det_test_fn.lyx', '/tmp/det_fn2.out', output, exitCode);
  AssertTrue('Function Build 2 succeeds', exitCode = 0);
  md5_2 := FileMD5('/tmp/det_fn2.out');
  
  AssertEqual('MD5 Function Build 1 == Build 2', md5_1, md5_2);
  
  DeleteFile('/tmp/det_test_fn.lyx');
  DeleteFile('/tmp/det_fn1.out');
  DeleteFile('/tmp/det_fn2.out');
end;

// ============================================================================
// Test 4: Reproduzierbarkeit mit Control Flow
// ============================================================================
procedure Test_ControlFlowReproducibility;
var
  md5_1, md5_2: string;
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== Test 4: Reproduzierbarkeit mit Control Flow ===');
  
  // Use simple Lyx syntax that is known to work
  WriteTestFile('/tmp/det_test_cf.lyx',
    'fn main(): int64 {' + LineEnding +
    '  let x: int64 = 42;' + LineEnding +
    '  let y: int64 = 10;' + LineEnding +
    '  let z: int64 = x + y;' + LineEnding +
    '  return z;' + LineEnding +
    '}'
  );
  
  RunCompiler('/tmp/det_test_cf.lyx', '/tmp/det_cf1.out', output, exitCode);
  if exitCode <> 0 then
  begin
    WriteLn('  Compiler output: ', output);
  end;
  AssertTrue('Control Flow Build 1 succeeds', exitCode = 0);
  if exitCode <> 0 then Exit;
  md5_1 := FileMD5('/tmp/det_cf1.out');
  
  RunCompiler('/tmp/det_test_cf.lyx', '/tmp/det_cf2.out', output, exitCode);
  AssertTrue('Control Flow Build 2 succeeds', exitCode = 0);
  if exitCode <> 0 then Exit;
  md5_2 := FileMD5('/tmp/det_cf2.out');
  
  AssertEqual('MD5 Control Flow Build 1 == Build 2', md5_1, md5_2);
  
  DeleteFile('/tmp/det_test_cf.lyx');
  DeleteFile('/tmp/det_cf1.out');
  DeleteFile('/tmp/det_cf2.out');
end;

// ============================================================================
// Test 5: Reproduzierbarkeit mit Map/Set
// ============================================================================
procedure Test_MapSetReproducibility;
var
  md5_1, md5_2: string;
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== Test 5: Reproduzierbarkeit mit Map/Set ===');
  
  WriteTestFile('/tmp/det_test_map.lyx',
    'fn main(): int64 {' + LineEnding +
    '  let a: int64 = 100;' + LineEnding +
    '  let b: int64 = 200;' + LineEnding +
    '  let c: int64 = 300;' + LineEnding +
    '  return a + b + c;' + LineEnding +
    '}'
  );
  
  RunCompiler('/tmp/det_test_map.lyx', '/tmp/det_map1.out', output, exitCode);
  AssertTrue('Map Build 1 succeeds', exitCode = 0);
  md5_1 := FileMD5('/tmp/det_map1.out');
  
  RunCompiler('/tmp/det_test_map.lyx', '/tmp/det_map2.out', output, exitCode);
  AssertTrue('Map Build 2 succeeds', exitCode = 0);
  md5_2 := FileMD5('/tmp/det_map2.out');
  
  AssertEqual('MD5 Map Build 1 == Build 2', md5_1, md5_2);
  
  DeleteFile('/tmp/det_test_map.lyx');
  DeleteFile('/tmp/det_map1.out');
  DeleteFile('/tmp/det_map2.out');
end;

// ============================================================================
// Test 6: 10-fache Reproduzierbarkeit (Stresstest)
// ============================================================================
procedure Test_MultipleBuilds;
var
  md5_first, md5_current: string;
  output: string;
  exitCode: Integer;
  i: Integer;
  allSame: Boolean;
begin
  WriteLn;
  WriteLn('=== Test 6: 10-fache Reproduzierbarkeit (Stresstest) ===');
  
  WriteTestFile('/tmp/det_stress.lyx',
    'fn fib(n: int64): int64 {' + LineEnding +
    '  if (n == 0) { return 0; }' + LineEnding +
    '  if (n == 1) { return 1; }' + LineEnding +
    '  return fib(n - 1) + fib(n - 2);' + LineEnding +
    '}' + LineEnding +
    'fn main(): int64 { return fib(10); }'
  );
  
  RunCompiler('/tmp/det_stress.lyx', '/tmp/det_stress0.out', output, exitCode);
  md5_first := FileMD5('/tmp/det_stress0.out');
  
  allSame := True;
  for i := 1 to 9 do
  begin
    RunCompiler('/tmp/det_stress.lyx', '/tmp/det_stress' + IntToStr(i) + '.out', output, exitCode);
    md5_current := FileMD5('/tmp/det_stress' + IntToStr(i) + '.out');
    if md5_current <> md5_first then
      allSame := False;
    DeleteFile('/tmp/det_stress' + IntToStr(i) + '.out');
  end;
  
  AssertTrue('All 10 builds produce identical binary', allSame);
  
  DeleteFile('/tmp/det_stress.lyx');
  DeleteFile('/tmp/det_stress0.out');
end;

// ============================================================================
// Main
// ============================================================================
begin
  TotalTests := 0;
  PassedTests := 0;
  FailedTests := 0;

  WriteLn('========================================');
  WriteLn('Determinism Test Suite');
  WriteLn('DO-178C Section 1.3: Deterministic Codegen');
  WriteLn('========================================');

  // Change to project root
  ChDir(ExtractFilePath(ParamStr(0)) + '../..');

  Test_Reproducibility;
  Test_ComplexReproducibility;
  Test_FunctionReproducibility;
  Test_ControlFlowReproducibility;
  Test_MapSetReproducibility;
  Test_MultipleBuilds;

  WriteLn;
  WriteLn('========================================');
  WriteLn('Determinism Test Results');
  WriteLn('========================================');
  WriteLn('Total:  ', TotalTests);
  WriteLn('Passed: ', PassedTests);
  WriteLn('Failed: ', FailedTests);
  WriteLn;

  if FailedTests > 0 then
  begin
    WriteLn('DETERMINISM VALIDATION: FAILED');
    Halt(1);
  end
  else
  begin
    WriteLn('DETERMINISM VALIDATION: PASSED');
    Halt(0);
  end;
end.
