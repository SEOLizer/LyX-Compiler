{$mode objfpc}{$H+}
program test_integrity_blocks;

{
  Integrity-Block Testsuite – DO-178C Aerospace (aerospace-todo P0 #43)

  Testet den Lyx-Parser und Sema für @integrity Blöcke:
    @integrity(mode: scrubbed,         interval: N)
    @integrity(mode: software_lockstep, interval: N)
    @integrity(mode: hardware_ecc,      interval: N)

  Syntax (EBNF):
    IntegrityAttr := "@integrity" "(" "mode" ":" IntegrityMode "," "interval" ":" IntLiteral ")" ;
    IntegrityMode := "software_lockstep" | "scrubbed" | "hardware_ecc" ;

  Tests decken ab:
    – @integrity vor unit-Deklaration (alle drei Modi)
    – @integrity als Funktions-Attribut
    – @integrity kombiniert mit @dal, @critical
    – Fehlerfall: unbekannter Modus
    – Fehlerfall: @integrity auf extern-Funktion
    – Warnung: scrubbed ohne interval
    – Mehrere Funktionen mit unterschiedlichen Modi
}

uses
  SysUtils, Classes, BaseUnix, Process;

var
  TotalTests: Integer = 0;
  PassedTests: Integer = 0;
  FailedTests: Integer = 0;
  LyxcPath: string;

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

procedure AssertContains(const testName, text, substring: string);
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
    WriteLn('  In text: ', Copy(text, 1, 200));
  end;
end;

procedure AssertNotContains(const testName, text, substring: string);
begin
  Inc(TotalTests);
  if Pos(substring, text) = 0 then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName);
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName);
    WriteLn('  Unexpected substring: ', substring);
  end;
end;

function RunLyx(const src: string; out output: string; out exitCode: Integer): Boolean;
var
  proc: TProcess;
  tmpFile: string;
  outFile: string;
  outStream: TStringList;
begin
  tmpFile := GetTempDir + 'test_integrity_' + IntToStr(TotalTests) + '.lyx';
  outFile  := GetTempDir + 'test_integrity_' + IntToStr(TotalTests) + '.out';
  outStream := TStringList.Create;
  proc := TProcess.Create(nil);
  try
    outStream.Text := src;
    outStream.SaveToFile(tmpFile);
    proc.Executable := '/bin/bash';
    proc.Parameters.Add('-c');
    proc.Parameters.Add(LyxcPath + ' ' + tmpFile + ' -o ' + outFile + ' 2>&1');
    proc.Options := [poWaitOnExit, poUsePipes];
    proc.Execute;
    exitCode := proc.ExitStatus;
    outStream.LoadFromStream(proc.Output);
    output := outStream.Text;
    Result := True;
  finally
    proc.Free;
    outStream.Free;
    DeleteFile(tmpFile);
    DeleteFile(outFile);
  end;
end;

function WrapMain(const body: string): string;
begin
  Result := body + #10 + 'fn main(): int64 { return 0; }';
end;

// ============================================================================
// Test 1: @integrity(mode: scrubbed, interval: 100) vor unit-Deklaration
// ============================================================================
procedure Test_UnitLevel_Scrubbed;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 1: @integrity(mode: scrubbed, interval: 100) vor unit ===');
  src :=
    '@integrity(mode: scrubbed, interval: 100)' + #10 +
    'unit navigation.core;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('unit_scrubbed: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('unit_scrubbed: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 2: @integrity(mode: software_lockstep, interval: 50) vor unit
// ============================================================================
procedure Test_UnitLevel_SoftwareLockstep;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 2: @integrity(mode: software_lockstep, interval: 50) vor unit ===');
  src :=
    '@integrity(mode: software_lockstep, interval: 50)' + #10 +
    'unit flight.control;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('unit_lockstep: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('unit_lockstep: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 3: @integrity(mode: hardware_ecc, interval: 200) vor unit
// ============================================================================
procedure Test_UnitLevel_HardwareEcc;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 3: @integrity(mode: hardware_ecc, interval: 200) vor unit ===');
  src :=
    '@integrity(mode: hardware_ecc, interval: 200)' + #10 +
    'unit mission.handler;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('unit_hw_ecc: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('unit_hw_ecc: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 4: @integrity als Funktions-Attribut (scrubbed)
// ============================================================================
procedure Test_FuncLevel_Scrubbed;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 4: @integrity als Funktions-Attribut (scrubbed) ===');
  src := WrapMain(
    '@integrity(mode: scrubbed, interval: 100)' + #10 +
    'fn calculate_burn(): int64 {' + #10 +
    '  return 42;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('func_scrubbed: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('func_scrubbed: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 5: @integrity als Funktions-Attribut (software_lockstep)
// ============================================================================
procedure Test_FuncLevel_Lockstep;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 5: @integrity als Funktions-Attribut (software_lockstep) ===');
  src := WrapMain(
    '@integrity(mode: software_lockstep, interval: 25)' + #10 +
    'fn attitude_control(): int64 {' + #10 +
    '  return 1;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('func_lockstep: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('func_lockstep: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 6: @integrity als Funktions-Attribut (hardware_ecc)
// ============================================================================
procedure Test_FuncLevel_HardwareEcc;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 6: @integrity als Funktions-Attribut (hardware_ecc) ===');
  src := WrapMain(
    '@integrity(mode: hardware_ecc, interval: 500)' + #10 +
    'fn telemetry_send(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('func_hw_ecc: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('func_hw_ecc: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 7: @integrity kombiniert mit @dal(A) @critical
// ============================================================================
procedure Test_IntegrityWithDalAndCritical;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 7: @integrity + @dal(A) + @critical kombiniert ===');
  src := WrapMain(
    '@dal(A) @critical @integrity(mode: scrubbed, interval: 100)' + #10 +
    'fn flight_control(): int64 {' + #10 +
    '  return 99;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('integrity_dal_critical: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('integrity_dal_critical: kein Parse-Fehler', output, 'Error:');
end;

// ============================================================================
// Test 8: Fehlerfall – unbekannter Integritäts-Modus
// ============================================================================
procedure Test_UnknownMode_Error;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 8: Fehlerfall – unbekannter Integritäts-Modus ===');
  src := WrapMain(
    '@integrity(mode: quantum_foam, interval: 42)' + #10 +
    'fn bogus(): int64 { return 0; }'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('unknown_mode: Compiler meldet Fehler', exitCode <> 0);
  AssertContains('unknown_mode: Fehlermeldung über unbekannten Modus', output, 'error:');
end;

// ============================================================================
// Test 9: Fehlerfall – @integrity auf extern-Funktion
// ============================================================================
procedure Test_ExternFunc_Error;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 9: Fehlerfall – @integrity auf extern-Funktion ===');
  src :=
    '@integrity(mode: scrubbed, interval: 100)' + #10 +
    'extern fn ext_func(): int64;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  // extern fn darf kein @integrity haben (sema-check)
  AssertTrue('extern_integrity: Compiler meldet Fehler', exitCode <> 0);
  AssertContains('extern_integrity: Fehlermeldung über extern', output, 'error:');
end;

// ============================================================================
// Test 10: Warnung – scrubbed ohne interval
// ============================================================================
procedure Test_ScrubbedWithoutInterval_Warning;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 10: Warnung – scrubbed ohne interval ===');
  src := WrapMain(
    '@integrity(mode: scrubbed)' + #10 +
    'fn memory_guard(): int64 { return 0; }'
  );
  RunLyx(src, output, exitCode);
  // Kompilierung sollte erfolgreich sein (nur Warnung)
  AssertTrue('scrubbed_no_interval: kompiliert (nur Warnung)', exitCode = 0);
  AssertContains('scrubbed_no_interval: Warnung über fehlendes interval', output, 'warning:');
end;

// ============================================================================
// Test 11: Mehrere Funktionen mit verschiedenen Modi
// ============================================================================
procedure Test_MultipleFunctions;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 11: Mehrere Funktionen mit verschiedenen integrity-Modi ===');
  src := WrapMain(
    '@integrity(mode: software_lockstep, interval: 10)' + #10 +
    'fn lockstep_fn(): int64 { return 1; }' + #10 +
    '@integrity(mode: scrubbed, interval: 200)' + #10 +
    'fn scrubbed_fn(): int64 { return 2; }' + #10 +
    '@integrity(mode: hardware_ecc, interval: 1000)' + #10 +
    'fn ecc_fn(): int64 { return 3; }'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('multi_fn: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('multi_fn: kein Fehler', output, 'Error:');
end;

// ============================================================================
// Test 12: @integrity vor unit ohne Funktionsdeklaration (nur unit + main)
// ============================================================================
procedure Test_UnitOnly;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 12: @integrity vor unit, kein Funktions-@integrity ===');
  src :=
    '@integrity(mode: hardware_ecc, interval: 50)' + #10 +
    'unit sensor.driver;' + #10 +
    'fn main(): int64 {' + #10 +
    '  return 7;' + #10 +
    '}';
  RunLyx(src, output, exitCode);
  AssertTrue('unit_only: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('unit_only: kein Fehler', output, 'Error:');
end;

// ============================================================================
// Test 13: Warnung – unit mit scrubbed und fehlendem interval
// ============================================================================
procedure Test_UnitScrubbed_NoInterval_Warning;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 13: Warnung – unit scrubbed ohne interval ===');
  // @integrity(mode: scrubbed) ohne interval → Warnung
  src :=
    '@integrity(mode: scrubbed)' + #10 +
    'unit warn.module;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('unit_scrubbed_no_interval: kompiliert (nur Warnung)', exitCode = 0);
  AssertContains('unit_scrubbed_no_interval: Warnung erwartet', output, 'warning:');
end;

// ============================================================================
// Test 14: @integrity mit @wcet kombiniert
// ============================================================================
procedure Test_IntegrityWithWcet;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 14: @integrity + @wcet kombiniert ===');
  src := WrapMain(
    '@integrity(mode: hardware_ecc, interval: 100) @wcet(5000)' + #10 +
    'fn realtime_fn(): int64 { return 0; }'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('integrity_wcet: kompiliert ohne Fehler', exitCode = 0);
  AssertNotContains('integrity_wcet: kein Fehler', output, 'Error:');
end;

// ============================================================================
// Hauptprogramm
// ============================================================================
begin
  WriteLn('========================================');
  WriteLn('Integrity-Block Test Suite (Task #43)');
  WriteLn('DO-178C / aerospace-todo P0 #43');
  WriteLn('========================================');

  // Finde lyxc binary
  LyxcPath := './lyxc';
  if not FileExists(LyxcPath) then
  begin
    WriteLn('ERROR: lyxc not found at ', LyxcPath);
    Halt(1);
  end;

  Test_UnitLevel_Scrubbed;
  Test_UnitLevel_SoftwareLockstep;
  Test_UnitLevel_HardwareEcc;
  Test_FuncLevel_Scrubbed;
  Test_FuncLevel_Lockstep;
  Test_FuncLevel_HardwareEcc;
  Test_IntegrityWithDalAndCritical;
  Test_UnknownMode_Error;
  Test_ExternFunc_Error;
  Test_ScrubbedWithoutInterval_Warning;
  Test_MultipleFunctions;
  Test_UnitOnly;
  Test_UnitScrubbed_NoInterval_Warning;
  Test_IntegrityWithWcet;

  WriteLn;
  WriteLn('========================================');
  WriteLn('Ergebnis: ', PassedTests, '/', TotalTests, ' Tests bestanden');
  if FailedTests > 0 then
  begin
    WriteLn('FAILED: ', FailedTests, ' Tests fehlgeschlagen');
    Halt(1);
  end
  else
    WriteLn('ALLE TESTS BESTANDEN');
  WriteLn('========================================');
end.
