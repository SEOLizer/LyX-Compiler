{$mode objfpc}{$H+}
program test_range_types;

{
  Range-Types Testsuite – DO-178C Aerospace (aerospace-todo P1 #7)

  Testet den Lyx-Compiler für Range-Typen:
    type T = int64 range Min..Max;

  Compile-Time-Checks: Literal-Werte außerhalb des Bereichs → Fehler
  Runtime-Checks: Nicht-konstante Werte → Laufzeitfehler bei Verletzung
}

uses
  SysUtils, Classes, Process;

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
    WriteLn('  In text: ', Copy(text, 1, 300));
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
  tmpFile := GetTempDir + 'test_range_' + IntToStr(TotalTests) + '.lyx';
  outFile := GetTempDir + 'test_range_' + IntToStr(TotalTests) + '.out';
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
// Test 1: Gültige Range-Deklaration kompiliert ohne Fehler
// ============================================================================
procedure Test_ValidRangeDecl;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 1: Gültige Range-Deklaration ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := 5000;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test1: Exit-Code 0 bei gültigem Range-Wert', exitCode = 0);
  AssertNotContains('Test1: Kein Fehler in Ausgabe', output, 'error:');
end;

// ============================================================================
// Test 2: Compile-Time Fehler – Wert über Obergrenze
// ============================================================================
procedure Test_CompileTimeAboveMax;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 2: Compile-Time Fehler (über Max) ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := 70000;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test2: Exit-Code 1 bei Wert über Max', exitCode = 1);
  AssertContains('Test2: Fehlermeldung enthält "out of range"', output, 'out of range');
  AssertContains('Test2: Fehlermeldung enthält Wert 70000', output, '70000');
end;

// ============================================================================
// Test 3: Compile-Time Fehler – Wert unter Untergrenze
// ============================================================================
procedure Test_CompileTimeBelowMin;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 3: Compile-Time Fehler (unter Min) ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := -2000;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test3: Exit-Code 1 bei Wert unter Min', exitCode = 1);
  AssertContains('Test3: Fehlermeldung enthält "out of range"', output, 'out of range');
  AssertContains('Test3: Fehlermeldung enthält -2000', output, '-2000');
end;

// ============================================================================
// Test 4: Grenzwerte – genau an der Untergrenze
// ============================================================================
procedure Test_BoundaryMin;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 4: Grenzwert Min ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := -1000;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test4: Exit-Code 0 bei genau Min', exitCode = 0);
  AssertNotContains('Test4: Kein Fehler bei Min-Grenzwert', output, 'error:');
end;

// ============================================================================
// Test 5: Grenzwerte – genau an der Obergrenze
// ============================================================================
procedure Test_BoundaryMax;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 5: Grenzwert Max ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := 60000;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test5: Exit-Code 0 bei genau Max', exitCode = 0);
  AssertNotContains('Test5: Kein Fehler bei Max-Grenzwert', output, 'error:');
end;

// ============================================================================
// Test 6: Fehlermeldung enthält Typnamen
// ============================================================================
procedure Test_ErrorContainsTypeName;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 6: Fehlermeldung enthält Typnamen ---');
  RunLyx(
    'type Speed = int64 range 0..300;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var s: Speed := 500;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test6: Exit-Code 1', exitCode = 1);
  AssertContains('Test6: Fehlermeldung enthält Typnamen "Speed"', output, 'Speed');
  AssertContains('Test6: Fehlermeldung enthält Bereich [0..300]', output, '[0..300]');
end;

// ============================================================================
// Test 7: Mehrere Range-Typen in einer Datei
// ============================================================================
procedure Test_MultipleRangeTypes;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 7: Mehrere Range-Typen ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'type Speed = int64 range 0..300;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var alt: Altitude := 5000;' + #10 +
    '  var spd: Speed := 150;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test7: Exit-Code 0 mit zwei Range-Typen', exitCode = 0);
  AssertNotContains('Test7: Kein Fehler bei gültigen Werten', output, 'error:');
end;

// ============================================================================
// Test 8: Reine positive Range (z.B. Prozentwert)
// ============================================================================
procedure Test_PositiveOnlyRange;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 8: Positive Range 0..100 ---');
  RunLyx(
    'type Percent = int64 range 0..100;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var p: Percent := 101;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test8: Exit-Code 1 bei 101 > 100', exitCode = 1);
  AssertContains('Test8: Fehlermeldung enthält "out of range"', output, 'out of range');
end;

// ============================================================================
// Test 9: Negative Range (z.B. Temperatur)
// ============================================================================
procedure Test_NegativeRange;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 9: Negative Range -273..0 ---');
  RunLyx(
    'type CryoTemp = int64 range -273..0;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var t: CryoTemp := -100;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test9: Exit-Code 0 bei gültigem negativen Wert', exitCode = 0);
  AssertNotContains('Test9: Kein Fehler bei -100 in [-273..0]', output, 'error:');
end;

// ============================================================================
// Test 10: Fehler für negativen Wert außerhalb negativer Range
// ============================================================================
procedure Test_NegativeRangeViolation;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 10: Verletzung negativer Range ---');
  RunLyx(
    'type CryoTemp = int64 range -273..0;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var t: CryoTemp := -300;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test10: Exit-Code 1 bei -300 < -273', exitCode = 1);
  AssertContains('Test10: Fehlermeldung enthält "out of range"', output, 'out of range');
end;

// ============================================================================
// Test 11: Kombination Range-Typ + Safety-Pragma (P1 #6 + P1 #7)
// ============================================================================
procedure Test_RangeWithPragma;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 11: Range-Typ + Safety-Pragma ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    '@dal(B) @critical' + #10 +
    'fn set_altitude(alt: int64): int64 {' + #10 +
    '  return 0;' + #10 +
    '}' + #10 +
    'fn main(): int64 { return 0; }',
    output, exitCode);
  AssertTrue('Test11: Exit-Code 0 bei Range+Pragma Kombination', exitCode = 0);
  AssertNotContains('Test11: Kein Fehler bei Range+Pragma', output, 'error:');
end;

// ============================================================================
// Test 12: Syntaxfehler – Range ohne Integer-Basistyp
// ============================================================================
procedure Test_RangeRequiresIntegerBase;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 12: Range erfordert Integer-Basistyp ---');
  RunLyx(
    'type BadRange = bool range 0..1;' + #10 +
    'fn main(): int64 { return 0; }',
    output, exitCode);
  AssertTrue('Test12: Exit-Code 1 bei bool als Range-Basis', exitCode = 1);
  AssertContains('Test12: Fehlermeldung enthält "integer"', output, 'integer');
end;

// ============================================================================
// Test 13: Redeclaration desselben Range-Typs → Fehler
// ============================================================================
procedure Test_RedeclarationError;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 13: Doppelte Range-Typ-Deklaration ---');
  RunLyx(
    'type Altitude = int64 range -1000..60000;' + #10 +
    'type Altitude = int64 range 0..100;' + #10 +
    'fn main(): int64 { return 0; }',
    output, exitCode);
  AssertTrue('Test13: Exit-Code 1 bei Redeclaration', exitCode = 1);
  AssertContains('Test13: Fehlermeldung enthält "redeclaration"', output, 'redeclaration');
end;

// ============================================================================
// Test 14: int8 als Basistyp
// ============================================================================
procedure Test_Int8Base;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 14: int8 als Basistyp ---');
  RunLyx(
    'type SmallVal = int8 range -10..10;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var v: SmallVal := 5;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test14: Exit-Code 0 mit int8-Basis', exitCode = 0);
  AssertNotContains('Test14: Kein Fehler bei int8-Range', output, 'error:');
end;

// ============================================================================
// Test 15: Wert 0 in Range 0..100 (Nullwert an Untergrenze)
// ============================================================================
procedure Test_ZeroAtMin;
var
  output: string;
  exitCode: Integer;
begin
  WriteLn('--- Test 15: Wert 0 an Untergrenze ---');
  RunLyx(
    'type Percent = int64 range 0..100;' + #10 +
    'fn main(): int64 {' + #10 +
    '  var p: Percent := 0;' + #10 +
    '  return 0;' + #10 +
    '}',
    output, exitCode);
  AssertTrue('Test15: Exit-Code 0 bei p=0 in [0..100]', exitCode = 0);
  AssertNotContains('Test15: Kein Fehler bei 0 in [0..100]', output, 'error:');
end;

// ============================================================================
// Hauptprogramm
// ============================================================================
begin
  WriteLn('========================================');
  WriteLn(' Range-Types Testsuite (P1 #7)');
  WriteLn('========================================');

  LyxcPath := '../lyxc';

  Test_ValidRangeDecl;
  Test_CompileTimeAboveMax;
  Test_CompileTimeBelowMin;
  Test_BoundaryMin;
  Test_BoundaryMax;
  Test_ErrorContainsTypeName;
  Test_MultipleRangeTypes;
  Test_PositiveOnlyRange;
  Test_NegativeRange;
  Test_NegativeRangeViolation;
  Test_RangeWithPragma;
  Test_RangeRequiresIntegerBase;
  Test_RedeclarationError;
  Test_Int8Base;
  Test_ZeroAtMin;

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
