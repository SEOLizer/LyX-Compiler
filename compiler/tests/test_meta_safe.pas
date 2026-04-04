{$mode objfpc}{$H+}
program test_meta_safe;

{
  .meta_safe ELF Section Testsuite – aerospace-todo P0 #44

  Testet die Generierung der .meta_safe ELF-Sektion durch den Lyx-Compiler.
  Die Sektion wird erzeugt wenn @integrity vor einer unit-Deklaration steht.

  Geprüft wird:
    – .meta_safe Sektion vorhanden (alle 3 Integritäts-Modi)
    – Korrekte Header-Felder (code_range, mode, interval, recovery_ptr)
    – Triple-Hash-Store (CRC32 identisch in allen 3 Kopien, 4KB-Separation)
    – Sektion fehlt bei Programmen OHNE @integrity
    – Sektion fehlt bei Programmen NUR mit Funktions-@integrity (kein unit)
    – Verschiedene Intervalle korrekt eingetragen

  Sektion-Layout (.meta_safe):
    [0..7]   code_start_va (uint64 LE)
    [8..15]  code_end_va   (uint64 LE)
    [16..19] mode          (uint32 LE): 1=lockstep, 2=scrubbed, 3=hw_ecc
    [20..23] interval_ms   (uint32 LE)
    [24..31] recovery_ptr  (uint64 LE): 0 = not set
    [32..35] hash_copy_1   (uint32 LE CRC32)
    [36..4127] padding     (4092 bytes)
    [4128..4131] hash_copy_2 (uint32 LE CRC32)
    [4132..8223] padding   (4092 bytes)
    [8224..8227] hash_copy_3 (uint32 LE CRC32)
    [8228..8231] padding   (4 bytes)
    Total: 8232 bytes
}

uses
  SysUtils, Classes, BaseUnix, Process;

var
  TotalTests: Integer = 0;
  PassedTests: Integer = 0;
  FailedTests: Integer = 0;
  LyxcPath: string;

// ============================================================================
// Hilfsfunktionen
// ============================================================================
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
    WriteLn('  Erwartet: ', substring);
    WriteLn('  In: ', Copy(text, 1, 200));
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
    WriteLn('  Unerwarteter Substring: ', substring);
  end;
end;

function RunLyx(const src: string; out output: string; out exitCode: Integer;
  out outFile: string): Boolean;
var
  proc: TProcess;
  tmpFile: string;
  outStream: TStringList;
begin
  tmpFile := GetTempDir + 'test_meta_' + IntToStr(TotalTests) + '.lyx';
  outFile  := GetTempDir + 'test_meta_' + IntToStr(TotalTests) + '.out';
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
  end;
end;

function RunReadElf(const elfFile, args: string): string;
var
  proc: TProcess;
  outStream: TStringList;
begin
  outStream := TStringList.Create;
  proc := TProcess.Create(nil);
  try
    proc.Executable := '/bin/bash';
    proc.Parameters.Add('-c');
    proc.Parameters.Add('readelf ' + args + ' ' + elfFile + ' 2>&1');
    proc.Options := [poWaitOnExit, poUsePipes];
    proc.Execute;
    outStream.LoadFromStream(proc.Output);
    Result := outStream.Text;
  finally
    proc.Free;
    outStream.Free;
  end;
end;

// Liest 4 Bytes LE uint32 aus Datei an gegebenem Offset
function ReadU32LE(const filename: string; offset: Int64): UInt32;
var
  f: TFileStream;
  b: array[0..3] of Byte;
begin
  Result := 0;
  if not FileExists(filename) then Exit;
  f := TFileStream.Create(filename, fmOpenRead);
  try
    f.Seek(offset, soBeginning);
    f.ReadBuffer(b, 4);
    Result := b[0] or (UInt32(b[1]) shl 8) or (UInt32(b[2]) shl 16) or (UInt32(b[3]) shl 24);
  finally
    f.Free;
  end;
end;

// Liest 8 Bytes LE uint64 aus Datei an gegebenem Offset
function ReadU64LE(const filename: string; offset: Int64): UInt64;
var
  f: TFileStream;
  b: array[0..7] of Byte;
begin
  Result := 0;
  if not FileExists(filename) then Exit;
  f := TFileStream.Create(filename, fmOpenRead);
  try
    f.Seek(offset, soBeginning);
    f.ReadBuffer(b, 8);
    Result := b[0] or (UInt64(b[1]) shl 8) or (UInt64(b[2]) shl 16) or
              (UInt64(b[3]) shl 24) or (UInt64(b[4]) shl 32) or
              (UInt64(b[5]) shl 40) or (UInt64(b[6]) shl 48) or (UInt64(b[7]) shl 56);
  finally
    f.Free;
  end;
end;

// Liefert den Datei-Offset der .meta_safe Section über readelf -S Ausgabe
// Gibt -1 zurück wenn nicht gefunden
function GetMetaSafeOffset(const elfFile: string): Int64;
var
  output, line: string;
  lines: TStringList;
  i, p: Integer;
  offStr: string;
begin
  Result := -1;
  output := RunReadElf(elfFile, '-S');
  lines := TStringList.Create;
  try
    lines.Text := output;
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      if Pos('.meta_safe', line) > 0 then
      begin
        // readelf -S format: [Nr] Name Type Address Offset ...
        // Offset is the 5th field on the same line or a continuation
        // Example: "  [ 3] .meta_safe        PROGBITS         0000000000000000  000010a0"
        // The offset field is at position after the address field
        p := Pos('PROGBITS', line);
        if p > 0 then
        begin
          // Skip past "PROGBITS", then address (16 hex chars + spaces), then offset
          offStr := Trim(Copy(line, p + 8, 100));
          // offStr starts with address (16 chars) then space then offset (8 chars)
          if Length(offStr) >= 26 then
          begin
            offStr := Trim(Copy(offStr, 17, 20));
            // First token is the file offset
            p := Pos(' ', offStr);
            if p > 0 then offStr := Copy(offStr, 1, p - 1);
            try
              Result := StrToInt64('$' + Trim(offStr));
            except
              Result := -1;
            end;
          end;
        end;
      end;
    end;
  finally
    lines.Free;
  end;
end;

// ============================================================================
// Tests
// ============================================================================

// Test 1: scrubbed mode → .meta_safe section present
procedure Test_ScrubbedMode_MetaSafePresent;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 1: scrubbed → .meta_safe vorhanden ===');
  RunLyx('@integrity(mode: scrubbed, interval: 100)' + #10 +
         'unit nav.core;' + #10 +
         'fn main(): int64 { return 42; }',
         output, exitCode, outFile);
  try
    AssertTrue('scrubbed: kompiliert ohne Fehler', exitCode = 0);
    elfSections := RunReadElf(outFile, '-S');
    AssertContains('scrubbed: .meta_safe Sektion vorhanden', elfSections, '.meta_safe');
    AssertContains('scrubbed: Compiler meldet .meta_safe', output, '.meta_safe');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 2: software_lockstep mode → .meta_safe present
procedure Test_LockstepMode_MetaSafePresent;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 2: software_lockstep → .meta_safe vorhanden ===');
  RunLyx('@integrity(mode: software_lockstep, interval: 50)' + #10 +
         'unit flight.ctrl;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('lockstep: kompiliert ohne Fehler', exitCode = 0);
    elfSections := RunReadElf(outFile, '-S');
    AssertContains('lockstep: .meta_safe Sektion vorhanden', elfSections, '.meta_safe');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 3: hardware_ecc mode → .meta_safe present
procedure Test_HardwareEccMode_MetaSafePresent;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 3: hardware_ecc → .meta_safe vorhanden ===');
  RunLyx('@integrity(mode: hardware_ecc, interval: 200)' + #10 +
         'unit sensor.drv;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('hw_ecc: kompiliert ohne Fehler', exitCode = 0);
    elfSections := RunReadElf(outFile, '-S');
    AssertContains('hw_ecc: .meta_safe Sektion vorhanden', elfSections, '.meta_safe');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 4: kein @integrity → keine .meta_safe section
procedure Test_NoIntegrity_NoMetaSafe;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 4: kein @integrity → keine .meta_safe Sektion ===');
  RunLyx('unit plain.prog;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('no_integrity: kompiliert ohne Fehler', exitCode = 0);
    elfSections := RunReadElf(outFile, '-S');
    AssertNotContains('no_integrity: keine .meta_safe', elfSections, '.meta_safe');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 5: kein unit → keine .meta_safe section (function-level @integrity reicht nicht)
procedure Test_FuncIntegrityOnly_NoMetaSafe;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 5: nur Funktions-@integrity → keine .meta_safe ===');
  RunLyx('@integrity(mode: scrubbed, interval: 50)' + #10 +
         'fn guarded(): int64 { return 1; }' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('func_only: kompiliert ohne Fehler', exitCode = 0);
    elfSections := RunReadElf(outFile, '-S');
    AssertNotContains('func_only: keine .meta_safe', elfSections, '.meta_safe');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 6: Header-Felder – mode=2 (scrubbed), interval=100
procedure Test_HeaderFields_Scrubbed;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  modeVal, intervalVal: UInt32;
  recPtr: UInt64;
begin
  WriteLn;
  WriteLn('=== Test 6: Header-Felder (scrubbed, interval=100) ===');
  RunLyx('@integrity(mode: scrubbed, interval: 100)' + #10 +
         'unit hdr.test;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('header_fields: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    AssertTrue('header_fields: .meta_safe Offset gefunden', metaOff > 0);
    if metaOff > 0 then
    begin
      modeVal     := ReadU32LE(outFile, metaOff + 16);
      intervalVal := ReadU32LE(outFile, metaOff + 20);
      recPtr      := ReadU64LE(outFile, metaOff + 24);
      AssertTrue('header_fields: mode=2 (scrubbed)', modeVal = 2);
      AssertTrue('header_fields: interval=100', intervalVal = 100);
      AssertTrue('header_fields: recovery_ptr=0 (nicht gesetzt)', recPtr = 0);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// Test 7: Header-Felder – mode=1 (software_lockstep), interval=50
procedure Test_HeaderFields_Lockstep;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  modeVal, intervalVal: UInt32;
begin
  WriteLn;
  WriteLn('=== Test 7: Header-Felder (software_lockstep, interval=50) ===');
  RunLyx('@integrity(mode: software_lockstep, interval: 50)' + #10 +
         'unit hdr.lockstep;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('lockstep_hdr: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    AssertTrue('lockstep_hdr: .meta_safe Offset gefunden', metaOff > 0);
    if metaOff > 0 then
    begin
      modeVal     := ReadU32LE(outFile, metaOff + 16);
      intervalVal := ReadU32LE(outFile, metaOff + 20);
      AssertTrue('lockstep_hdr: mode=1 (lockstep)', modeVal = 1);
      AssertTrue('lockstep_hdr: interval=50', intervalVal = 50);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// Test 8: Header-Felder – mode=3 (hardware_ecc), interval=250
procedure Test_HeaderFields_HardwareEcc;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  modeVal, intervalVal: UInt32;
begin
  WriteLn;
  WriteLn('=== Test 8: Header-Felder (hardware_ecc, interval=250) ===');
  RunLyx('@integrity(mode: hardware_ecc, interval: 250)' + #10 +
         'unit hdr.ecc;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('ecc_hdr: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    AssertTrue('ecc_hdr: .meta_safe Offset gefunden', metaOff > 0);
    if metaOff > 0 then
    begin
      modeVal     := ReadU32LE(outFile, metaOff + 16);
      intervalVal := ReadU32LE(outFile, metaOff + 20);
      AssertTrue('ecc_hdr: mode=3 (hardware_ecc)', modeVal = 3);
      AssertTrue('ecc_hdr: interval=250', intervalVal = 250);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// Test 9: Triple-Hash-Store – alle 3 CRC32-Kopien identisch, 4KB-Separation
procedure Test_TripleHashStore;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  h1, h2, h3: UInt32;
begin
  WriteLn;
  WriteLn('=== Test 9: Triple-Hash-Store – 3 CRC32-Kopien identisch ===');
  RunLyx('@integrity(mode: scrubbed, interval: 100)' + #10 +
         'unit triple.hash;' + #10 +
         'fn main(): int64 { return 99; }',
         output, exitCode, outFile);
  try
    AssertTrue('triple_hash: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    AssertTrue('triple_hash: .meta_safe Offset gefunden', metaOff > 0);
    if metaOff > 0 then
    begin
      // Hash-Kopie 1: offset 32
      h1 := ReadU32LE(outFile, metaOff + 32);
      // Hash-Kopie 2: offset 32 + 4 + 4092 = 32 + 4096 = 4128
      h2 := ReadU32LE(outFile, metaOff + 4128);
      // Hash-Kopie 3: offset 4128 + 4 + 4092 = 4128 + 4096 = 8224
      h3 := ReadU32LE(outFile, metaOff + 8224);
      AssertTrue('triple_hash: Hash != 0 (nicht leer)', h1 <> 0);
      AssertTrue('triple_hash: Kopie 1 = Kopie 2', h1 = h2);
      AssertTrue('triple_hash: Kopie 2 = Kopie 3', h2 = h3);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// Test 10: code_start_va und code_end_va korrekt im Header
procedure Test_CodeRange;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  startVA, endVA: UInt64;
begin
  WriteLn;
  WriteLn('=== Test 10: code_start_va und code_end_va im Header ===');
  RunLyx('@integrity(mode: hardware_ecc, interval: 10)' + #10 +
         'unit code.range;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('code_range: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    AssertTrue('code_range: .meta_safe Offset gefunden', metaOff > 0);
    if metaOff > 0 then
    begin
      startVA := ReadU64LE(outFile, metaOff + 0);
      endVA   := ReadU64LE(outFile, metaOff + 8);
      // x86_64: baseVA=$400000, codeOffset=0x1000 → startVA=$401000
      AssertTrue('code_range: start_va = $401000', startVA = $401000);
      // end_va > start_va (non-empty code)
      AssertTrue('code_range: end_va > start_va', endVA > startVA);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// Test 11: .meta_safe Sektion-Größe = 8232 Bytes
procedure Test_SectionSize;
var
  output, outFile: string;
  exitCode: Integer;
  elfSections: string;
begin
  WriteLn;
  WriteLn('=== Test 11: .meta_safe Sektion-Größe = 8232 Bytes ===');
  RunLyx('@integrity(mode: scrubbed, interval: 100)' + #10 +
         'unit meta.sizing;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('sec_size: kompiliert', exitCode = 0);
    // readelf -S gibt Größe in Hex aus
    elfSections := RunReadElf(outFile, '-S');
    // 8232 bytes = 0x2028
    AssertContains('sec_size: Größe 0x2028 (8232 bytes)', elfSections, '2028');
  finally
    DeleteFile(outFile);
  end;
end;

// Test 12: Verschiedene Intervalle korrekt
procedure Test_DifferentIntervals;
var
  output, outFile: string;
  exitCode: Integer;
  metaOff: Int64;
  intervalVal: UInt32;
begin
  WriteLn;
  WriteLn('=== Test 12: Verschiedene Intervalle ===');
  RunLyx('@integrity(mode: scrubbed, interval: 500)' + #10 +
         'unit interval.test;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('interval_500: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    if metaOff > 0 then
    begin
      intervalVal := ReadU32LE(outFile, metaOff + 20);
      AssertTrue('interval_500: interval=500', intervalVal = 500);
    end;
  finally
    DeleteFile(outFile);
  end;

  RunLyx('@integrity(mode: hardware_ecc, interval: 1000)' + #10 +
         'unit interval.test2;' + #10 +
         'fn main(): int64 { return 0; }',
         output, exitCode, outFile);
  try
    AssertTrue('interval_1000: kompiliert', exitCode = 0);
    metaOff := GetMetaSafeOffset(outFile);
    if metaOff > 0 then
    begin
      intervalVal := ReadU32LE(outFile, metaOff + 20);
      AssertTrue('interval_1000: interval=1000', intervalVal = 1000);
    end;
  finally
    DeleteFile(outFile);
  end;
end;

// ============================================================================
// Hauptprogramm
// ============================================================================
begin
  WriteLn('========================================');
  WriteLn('.meta_safe ELF Section Test Suite (#44)');
  WriteLn('DO-178C / aerospace-todo P0 #44');
  WriteLn('========================================');

  LyxcPath := './lyxc';
  if not FileExists(LyxcPath) then
  begin
    WriteLn('ERROR: lyxc nicht gefunden unter ', LyxcPath);
    Halt(1);
  end;
  if not FileExists('/usr/bin/readelf') then
  begin
    WriteLn('SKIP: readelf nicht gefunden – ELF-Struktur-Tests übersprungen');
    WriteLn('      (sudo apt install binutils)');
    Halt(77); // Konvention: 77 = skip
  end;

  Test_ScrubbedMode_MetaSafePresent;
  Test_LockstepMode_MetaSafePresent;
  Test_HardwareEccMode_MetaSafePresent;
  Test_NoIntegrity_NoMetaSafe;
  Test_FuncIntegrityOnly_NoMetaSafe;
  Test_HeaderFields_Scrubbed;
  Test_HeaderFields_Lockstep;
  Test_HeaderFields_HardwareEcc;
  Test_TripleHashStore;
  Test_CodeRange;
  Test_SectionSize;
  Test_DifferentIntervals;

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
