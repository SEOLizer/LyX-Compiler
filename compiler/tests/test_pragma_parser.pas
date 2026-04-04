{$mode objfpc}{$H+}
program test_pragma_parser;

{
  Pragma-Parser Testsuite – DO-178C Aerospace (aerospace-todo P1 #6)

  Testet den Lyx-Parser für Safety-Pragmas:
    @dal(A|B|C|D)   – Design Assurance Level
    @critical        – Safety-Critical Funktion
    @wcet(N)         – WCET-Budget in Mikrosekunden
    @stack_limit(N)  – Max Stack-Nutzung in Bytes

  Alle Tests kompilieren Lyx-Quelltext-Snippets und prüfen
  Exit-Code + ggf. Fehlerausgabe.
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
  outStream: TStringList;
  outFile: string;
begin
  tmpFile := GetTempDir + 'test_pragma_' + IntToStr(TotalTests) + '.lyx';
  outFile := GetTempDir + 'test_pragma_' + IntToStr(TotalTests) + '.out';
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

// ============================================================================
// Hilfsfunktion: Lyx-Programm mit main() wrapper
// ============================================================================
function WrapMain(const body: string): string;
begin
  Result := body + #10 + 'fn main(): int64 { return 0; }';
end;

// ============================================================================
// Test 1: @dal(A) – DAL-A Annotation
// ============================================================================
procedure Test_DAL_A;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 1: @dal(A) – Design Assurance Level A ===');
  src := WrapMain(
    '@dal(A) @critical' + #10 +
    'fn flight_control(): int64 {' + #10 +
    '  return 42;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('dal_A: compiles without error', exitCode = 0);
  AssertNotContains('dal_A: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 2: @dal(B) – DAL-B Annotation
// ============================================================================
procedure Test_DAL_B;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 2: @dal(B) – Design Assurance Level B ===');
  src := WrapMain(
    '@dal(B)' + #10 +
    'fn navigation(): int64 {' + #10 +
    '  return 1;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('dal_B: compiles without error', exitCode = 0);
  AssertNotContains('dal_B: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 3: @dal(C) – DAL-C Annotation
// ============================================================================
procedure Test_DAL_C;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 3: @dal(C) – Design Assurance Level C ===');
  src := WrapMain(
    '@dal(C)' + #10 +
    'fn display_update(): int64 {' + #10 +
    '  return 2;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('dal_C: compiles without error', exitCode = 0);
  AssertNotContains('dal_C: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 4: @dal(D) – DAL-D Annotation
// ============================================================================
procedure Test_DAL_D;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 4: @dal(D) – Design Assurance Level D ===');
  src := WrapMain(
    '@dal(D)' + #10 +
    'fn log_event(): int64 {' + #10 +
    '  return 3;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('dal_D: compiles without error', exitCode = 0);
  AssertNotContains('dal_D: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 5: @critical – Safety-Critical Markierung
// ============================================================================
procedure Test_Critical;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 5: @critical – Safety-Critical Funktion ===');
  src := WrapMain(
    '@critical' + #10 +
    'fn arm_ejection(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('critical: compiles without error', exitCode = 0);
  AssertNotContains('critical: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 6: @wcet(N) – WCET Budget
// ============================================================================
procedure Test_WCET;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 6: @wcet(N) – WCET Budget ===');
  src := WrapMain(
    '@wcet(500)' + #10 +
    'fn sensor_read(): int64 {' + #10 +
    '  return 99;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('wcet: compiles without error', exitCode = 0);
  AssertNotContains('wcet: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 7: @stack_limit(N) – Stack-Limit
// ============================================================================
procedure Test_StackLimit;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 7: @stack_limit(N) – Stack-Limit ===');
  src := WrapMain(
    '@stack_limit(256)' + #10 +
    'fn isr_handler(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('stack_limit: compiles without error', exitCode = 0);
  AssertNotContains('stack_limit: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 8: Alle Pragmas kombiniert
// ============================================================================
procedure Test_AllPragmasCombined;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 8: Alle Pragmas kombiniert ===');
  src := WrapMain(
    '@dal(A) @critical @wcet(100) @stack_limit(512)' + #10 +
    'fn autopilot_update(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('combined: compiles without error', exitCode = 0);
  AssertNotContains('combined: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 9: @dal(A) ohne @critical – Soll Warning ausgeben
// ============================================================================
procedure Test_DAL_A_Without_Critical;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 9: @dal(A) ohne @critical – Warning erwartet ===');
  src := WrapMain(
    '@dal(A)' + #10 +
    'fn critical_routine(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  // Exit code 0 (Warning, kein Fehler)
  AssertTrue('dal_A_no_critical: compiles (warning, not error)', exitCode = 0);
  AssertContains('dal_A_no_critical: warning about @critical', output, 'critical');
end;

// ============================================================================
// Test 10: @energy mit @dal kombiniert
// ============================================================================
procedure Test_Energy_And_DAL;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 10: @energy + @dal kombiniert ===');
  src := WrapMain(
    '@energy(3) @dal(B) @wcet(1000)' + #10 +
    'fn compute_trajectory(): int64 {' + #10 +
    '  return 7;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('energy_dal: compiles without error', exitCode = 0);
  AssertNotContains('energy_dal: no parse error', output, 'Error:');
end;

// ============================================================================
// Test 11: Ungültiger DAL-Level – Fehler erwartet
// ============================================================================
procedure Test_Invalid_DAL;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 11: Ungültiger DAL-Level – Fehler erwartet ===');
  src := WrapMain(
    '@dal(X)' + #10 +
    'fn bad_func(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('invalid_dal: exit code != 0', exitCode <> 0);
  AssertContains('invalid_dal: error message mentions DAL or invalid', output, 'invalid');
end;

// ============================================================================
// Test 12: @critical auf extern fn – Fehler erwartet
// ============================================================================
procedure Test_Critical_On_Extern;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 12: @critical auf extern fn – Fehler erwartet ===');
  src :=
    '@critical' + #10 +
    'extern fn printf(fmt: pchar): int64;' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('critical_extern: exit code != 0', exitCode <> 0);
  AssertContains('critical_extern: error mentions extern or not meaningful', output, 'extern');
end;

// ============================================================================
// Test 13: @wcet(0) – Ungültiger Wert, Fehler erwartet
// ============================================================================
procedure Test_WCET_Zero;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 13: @wcet(0) – Ungültiger Wert ===');
  src := WrapMain(
    '@wcet(0)' + #10 +
    'fn zero_wcet(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('wcet_zero: exit code != 0', exitCode <> 0);
  AssertContains('wcet_zero: error about positive integer', output, 'positive');
end;

// ============================================================================
// Test 14: @stack_limit(0) – Ungültiger Wert, Fehler erwartet
// ============================================================================
procedure Test_StackLimit_Zero;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 14: @stack_limit(0) – Ungültiger Wert ===');
  src := WrapMain(
    '@stack_limit(0)' + #10 +
    'fn zero_stack(): int64 {' + #10 +
    '  return 0;' + #10 +
    '}'
  );
  RunLyx(src, output, exitCode);
  AssertTrue('stack_limit_zero: exit code != 0', exitCode <> 0);
  AssertContains('stack_limit_zero: error about positive integer', output, 'positive');
end;

// ============================================================================
// Test 15: Mehrere Funktionen mit unterschiedlichen DAL-Levels
// ============================================================================
procedure Test_Multiple_Functions_Different_DAL;
var
  output: string;
  exitCode: Integer;
  src: string;
begin
  WriteLn;
  WriteLn('=== Test 15: Mehrere Funktionen mit unterschiedlichen DAL-Levels ===');
  src :=
    '@dal(A) @critical @wcet(50)' + #10 +
    'fn engine_cutoff(): int64 { return 0; }' + #10 +
    '@dal(B) @wcet(200)' + #10 +
    'fn fuel_monitor(): int64 { return 1; }' + #10 +
    '@dal(C)' + #10 +
    'fn cabin_pressure(): int64 { return 2; }' + #10 +
    'fn main(): int64 { return 0; }';
  RunLyx(src, output, exitCode);
  AssertTrue('multi_dal: compiles without error', exitCode = 0);
  AssertNotContains('multi_dal: no parse error', output, 'Error:');
end;

// ============================================================================
// Hauptprogramm
// ============================================================================
begin
  // lyxc lives one directory above compiler/ (see Makefile: -o../lyxc)
  LyxcPath := '../lyxc';

  WriteLn('========================================');
  WriteLn(' Pragma-Parser Testsuite (DO-178C)');
  WriteLn(' aerospace-todo P1 #6');
  WriteLn('========================================');

  Test_DAL_A;
  Test_DAL_B;
  Test_DAL_C;
  Test_DAL_D;
  Test_Critical;
  Test_WCET;
  Test_StackLimit;
  Test_AllPragmasCombined;
  Test_DAL_A_Without_Critical;
  Test_Energy_And_DAL;
  Test_Invalid_DAL;
  Test_Critical_On_Extern;
  Test_WCET_Zero;
  Test_StackLimit_Zero;
  Test_Multiple_Functions_Different_DAL;

  WriteLn;
  WriteLn('========================================');
  WriteLn(' Ergebnis: ', PassedTests, '/', TotalTests, ' Tests bestanden');
  if FailedTests > 0 then
    WriteLn(' FEHLER: ', FailedTests, ' Tests fehlgeschlagen!')
  else
    WriteLn(' ALLE TESTS BESTANDEN');
  WriteLn('========================================');

  if FailedTests > 0 then
    Halt(1);
end.
