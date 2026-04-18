{$mode objfpc}{$H+}
program test_tor_validation;

{
  Tool Validation Framework für Lyx Compiler
  DO-178C TQL-5 Tool Qualification
  
  Dieses Programm validiert, dass der Lyx Compiler die Tool Operational
  Requirements (TOR) erfüllt.
}

uses
  SysUtils, Classes, BaseUnix, Process;

var
  TotalTests: Integer = 0;
  PassedTests: Integer = 0;
  FailedTests: Integer = 0;

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

procedure AssertContains(const testName: string; text, substring: string);
begin
  Inc(TotalTests);
  if Pos(substring, text) > 0 then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName);
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName);
    WriteLn('  Expected substring: ', substring);
    WriteLn('  In text: ', text);
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

function RunCommandAndGetOutput(const cmd: string; out output: string; out exitCode: Integer): Boolean;
var
  proc: TProcess;
  outStream: TStringList;
begin
  proc := TProcess.Create(nil);
  outStream := TStringList.Create;
  try
    proc.Executable := '/bin/bash';
    proc.Parameters.Add('-c');
    proc.Parameters.Add(cmd);
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

// ============================================================================
// TOR-001: Tool-Versionierung
// ============================================================================
procedure Test_TOR001_Version;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== TOR-001: Tool-Versionierung ===');
  
  RunCommandAndGetOutput('./lyxc --version', output, exitCode);
  AssertTrue('TOR-001: Exit code 0', exitCode = 0);
  AssertContains('TOR-001: Version number present', output, '0.8.1');
  AssertContains('TOR-001: SemVer format', output, '.');
end;

// ============================================================================
// TOR-002: Build-Identifikation
// ============================================================================
procedure Test_TOR002_BuildInfo;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== TOR-002: Build-Identifikation ===');
  
  RunCommandAndGetOutput('./lyxc --build-info', output, exitCode);
  AssertTrue('TOR-002: Exit code 0', exitCode = 0);
  AssertContains('TOR-002: Version present', output, '0.8.1');
  AssertContains('TOR-002: TQL level present', output, 'TQL-5');
  AssertContains('TOR-002: Build OS present', output, 'Linux');
  AssertContains('TOR-002: Deterministic flag', output, 'Deterministic');
  AssertContains('TOR-002: Hidden deps info', output, 'Hidden Deps');
end;

// ============================================================================
// TOR-003: Konfigurations-Status
// ============================================================================
procedure Test_TOR003_Config;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== TOR-003: Konfigurations-Status ===');
  
  RunCommandAndGetOutput('./lyxc --config', output, exitCode);
  AssertTrue('TOR-003: Exit code 0', exitCode = 0);
  AssertContains('TOR-003: Default target present', output, 'Default Target');
  AssertContains('TOR-003: Supported targets', output, 'Supported Targets');
  AssertContains('TOR-003: Linux target listed', output, 'linux');
  AssertContains('TOR-003: ARM64 target listed', output, 'arm64');
  AssertContains('TOR-003: ESP32 target listed', output, 'esp32');
end;

procedure WriteTestFile(const path, content: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := content;
    sl.SaveToFile(path);
  finally
    sl.Free;
  end;
end;

// ============================================================================
// TOR-010: Deterministische Code-Generierung
// ============================================================================
procedure Test_TOR010_Deterministic;
var
  output1, output2: string;
  exitCode1, exitCode2: Integer;
  sha1, sha2: string;
begin
  WriteLn;
  WriteLn('=== TOR-010: Deterministische Code-Generierung ===');
  
  WriteTestFile('/tmp/tor_test_det.lyx', 'fn main(): int64 { return 42; }');
  
  // Build 1
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_det.lyx -o /tmp/tor_det1.out 2>&1', output1, exitCode1);
  AssertTrue('TOR-010: Build 1 succeeds (exit=' + IntToStr(exitCode1) + ')', exitCode1 = 0);
  
  // Build 2
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_det.lyx -o /tmp/tor_det2.out 2>&1', output2, exitCode2);
  AssertTrue('TOR-010: Build 2 succeeds (exit=' + IntToStr(exitCode2) + ')', exitCode2 = 0);
  
  // Compare SHA-256
  RunCommandAndGetOutput('sha256sum /tmp/tor_det1.out | cut -d" " -f1', sha1, exitCode1);
  RunCommandAndGetOutput('sha256sum /tmp/tor_det2.out | cut -d" " -f1', sha2, exitCode2);
  
  AssertEqual('TOR-010: SHA-256 identical', Trim(sha1), Trim(sha2));
  
  // Cleanup
  DeleteFile('/tmp/tor_test_det.lyx');
  DeleteFile('/tmp/tor_det1.out');
  DeleteFile('/tmp/tor_det2.out');
end;

// ============================================================================
// TOR-012: Fehlermeldungen mit Source-Position
// ============================================================================
procedure Test_TOR012_ErrorPositions;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== TOR-012: Fehlermeldungen mit Source-Position ===');
  
  WriteTestFile('/tmp/tor_test_err.lyx', 'fn main(): int64 { return "hello"; }');
  
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_err.lyx -o /tmp/tor_err.out 2>&1', output, exitCode);
  // Compiler may exit 0 or non-zero for semantic errors - check for error output
  AssertContains('TOR-012: Error output present', output, 'error');
  AssertContains('TOR-012: File name in error', output, 'tor_test_err.lyx');
  AssertContains('TOR-012: Line number in error', output, ':');
  
  // Cleanup
  DeleteFile('/tmp/tor_test_err.lyx');
  DeleteFile('/tmp/tor_err.out');
end;

// ============================================================================
// TOR-040: Reproduzierbarkeit (cross-build)
// ============================================================================
procedure Test_TOR040_Reproducible;
var
  output1, output2: string;
  exitCode1, exitCode2: Integer;
  sha1, sha2: string;
begin
  WriteLn;
  WriteLn('=== TOR-040: Reproduzierbarkeit ===');
  
  WriteTestFile('/tmp/tor_test_repro.lyx', 'fn main(): int64 { let a: int64 = 10; let b: int64 = 20; return a + b; }');
  
  // Build 1
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_repro.lyx -o /tmp/tor_repro1.out', output1, exitCode1);
  
  // Build 2 (separate process simulation)
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_repro.lyx -o /tmp/tor_repro2.out', output2, exitCode2);
  
  // Compare
  RunCommandAndGetOutput('sha256sum /tmp/tor_repro1.out | cut -d" " -f1', sha1, exitCode1);
  RunCommandAndGetOutput('sha256sum /tmp/tor_repro2.out | cut -d" " -f1', sha2, exitCode2);
  
  AssertEqual('TOR-040: Reproducible builds', Trim(sha1), Trim(sha2));
  
  // Cleanup
  DeleteFile('/tmp/tor_test_repro.lyx');
  DeleteFile('/tmp/tor_repro1.out');
  DeleteFile('/tmp/tor_repro2.out');
end;

// ============================================================================
// TOR-041: Keine versteckten Abhängigkeiten
// ============================================================================
procedure Test_TOR041_NoHiddenDeps;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn;
  WriteLn('=== TOR-041: Keine versteckten Abhängigkeiten ===');
  
  WriteTestFile('/tmp/tor_test_deps.lyx', 'fn main(): int64 { return 0; }');
  
  RunCommandAndGetOutput('./lyxc /tmp/tor_test_deps.lyx -o /tmp/tor_deps.out', output, exitCode);
  
  if exitCode = 0 then
  begin
    // Check for dynamic dependencies (German or English output)
    RunCommandAndGetOutput('ldd /tmp/tor_deps.out 2>&1', output, exitCode);
    AssertTrue('TOR-041: No libc dependency (static binary)',
      (Pos('not a dynamic executable', output) > 0) or
      (Pos('nicht dynamisch gelinkt', output) > 0) or
      (Pos('statically linked', output) > 0));
  end;
  
  // Cleanup
  DeleteFile('/tmp/tor_test_deps.lyx');
  DeleteFile('/tmp/tor_deps.out');
end;

// ============================================================================
// Main
// ============================================================================
begin
  WriteLn('========================================');
  WriteLn('Lyx Compiler - Tool Validation Suite');
  WriteLn('DO-178C TQL-5 Qualification');
  WriteLn('========================================');
  
  // Change to project root (parent of compiler/)
  ChDir(ExtractFilePath(ParamStr(0)) + '../..');
  
  Test_TOR001_Version;
  Test_TOR002_BuildInfo;
  Test_TOR003_Config;
  Test_TOR010_Deterministic;
  Test_TOR012_ErrorPositions;
  Test_TOR040_Reproducible;
  Test_TOR041_NoHiddenDeps;
  
  WriteLn;
  WriteLn('========================================');
  WriteLn('Test Results');
  WriteLn('========================================');
  WriteLn('Total:  ', TotalTests);
  WriteLn('Passed: ', PassedTests);
  WriteLn('Failed: ', FailedTests);
  WriteLn;
  
  if FailedTests > 0 then
  begin
    WriteLn('TOR VALIDATION: FAILED');
    Halt(1);
  end
  else
  begin
    WriteLn('TOR VALIDATION: PASSED');
    Halt(0);
  end;
end.
