{$mode objfpc}{$H+}
program test_pe64;

uses
  SysUtils, Classes, bytes, pe64_writer, x86_64_win64;

var
  // Globale Variablen für Test-Ausgaben
  GTestPassed: Integer = 0;
  GTestFailed: Integer = 0;

procedure Pass(const test, msg: string);
begin
  WriteLn('  [PASS] ', test, ': ', msg);
  Inc(GTestPassed);
end;

procedure Fail(const test, msg: string);
begin
  WriteLn('  [FAIL] ', test, ': ', msg);
  Inc(GTestFailed);
end;

// Test 1: Erzeuge ein minimales PE ohne Imports
procedure TestMinimalPE;
var
  code: TByteBuffer;
  fs: TFileStream;
begin
  WriteLn;
  WriteLn('=== Test 1: Minimales PE64 ===');
  
  code := TByteBuffer.Create;
  try
    // Einfacher Code: xor eax, eax; ret (Return 0)
    code.WriteU8($31);  // xor eax, eax
    code.WriteU8($C0);
    code.WriteU8($C3);  // ret
    
    WritePE64Minimal('/tmp/test_minimal.exe', code);
    
    if FileExists('/tmp/test_minimal.exe') then
    begin
      fs := TFileStream.Create('/tmp/test_minimal.exe', fmOpenRead);
      try
        if fs.Size >= 512 then
          Pass('Dateigröße', IntToStr(fs.Size) + ' Bytes')
        else
          Fail('Dateigröße', 'zu klein: ' + IntToStr(fs.Size) + ' Bytes');
      finally
        fs.Free;
      end;
    end
    else
      Fail('Dateierstellung', 'Datei nicht erstellt');
  finally
    code.Free;
  end;
end;

// Test 2: Prüfe DOS Header Signatur
procedure TestDosHeader;
var
  fs: TFileStream;
  magic: Word;
  peOffset: DWord;
  peSig: array[0..3] of Byte;
begin
  WriteLn;
  WriteLn('=== Test 2: DOS Header ===');
  
  if not FileExists('/tmp/test_minimal.exe') then
  begin
    Fail('Voraussetzung', 'test_minimal.exe nicht vorhanden');
    Exit;
  end;
  
  fs := TFileStream.Create('/tmp/test_minimal.exe', fmOpenRead);
  try
    // Lese MZ Signatur
    fs.ReadBuffer(magic, 2);
    if magic = $5A4D then
      Pass('MZ Signatur', '$5A4D')
    else
      Fail('MZ Signatur', 'erwartet $5A4D, bekommen $' + IntToHex(magic, 4));
    
    // Lese PE Offset (bei 0x3C)
    fs.Position := $3C;
    fs.ReadBuffer(peOffset, 4);
    
    // Lese PE Signatur
    fs.Position := peOffset;
    fs.ReadBuffer(peSig, 4);
    
    if (peSig[0] = $50) and (peSig[1] = $45) and (peSig[2] = 0) and (peSig[3] = 0) then
      Pass('PE Signatur', 'PE' + chr(0) + chr(0))
    else
      Fail('PE Signatur', 'ungültig');
  finally
    fs.Free;
  end;
end;

// Test 3: Prüfe COFF Header
procedure TestCoffHeader;
var
  fs: TFileStream;
  peOffset: DWord;
  machine: Word;
  numSections: Word;
  optHeaderSize: Word;
begin
  WriteLn;
  WriteLn('=== Test 3: COFF Header ===');
  
  if not FileExists('/tmp/test_minimal.exe') then
  begin
    Fail('Voraussetzung', 'test_minimal.exe nicht vorhanden');
    Exit;
  end;
  
  fs := TFileStream.Create('/tmp/test_minimal.exe', fmOpenRead);
  try
    // PE Offset lesen
    fs.Position := $3C;
    fs.ReadBuffer(peOffset, 4);
    
    // COFF Header beginnt nach PE Signatur (4 Bytes)
    fs.Position := peOffset + 4;
    fs.ReadBuffer(machine, 2);
    fs.ReadBuffer(numSections, 2);
    
    // SizeOfOptionalHeader ist bei Offset +16 im COFF Header
    fs.Position := peOffset + 4 + 16;
    fs.ReadBuffer(optHeaderSize, 2);
    
    if machine = $8664 then
      Pass('Machine', 'AMD64 ($8664)')
    else
      Fail('Machine', 'erwartet $8664, bekommen $' + IntToHex(machine, 4));
    
    if numSections >= 1 then
      Pass('Sections', IntToStr(numSections) + ' Section(s)')
    else
      Fail('Sections', 'keine Sections');
    
    if optHeaderSize = 240 then
      Pass('Optional Header', 'PE32+ (240 Bytes)')
    else
      Fail('Optional Header', 'erwartet 240, bekommen ' + IntToStr(optHeaderSize));
  finally
    fs.Free;
  end;
end;

// Test 4: TWin64Emitter Test
procedure TestWin64Emitter;
var
  emitter: TWin64Emitter;
  fs: TFileStream;
begin
  WriteLn;
  WriteLn('=== Test 4: Win64 Emitter ===');
  
  emitter := TWin64Emitter.Create;
  try
    // EmitFromIR mit nil (nur Builtins und Demo-Main)
    emitter.EmitFromIR(nil);
    
    if emitter.CodeBuffer.Size > 100 then
      Pass('Code-Größe', IntToStr(emitter.CodeBuffer.Size) + ' Bytes')
    else
      Fail('Code-Größe', 'zu klein: ' + IntToStr(emitter.CodeBuffer.Size));
    
    if emitter.DataBuffer.Size > 0 then
      Pass('Data-Größe', IntToStr(emitter.DataBuffer.Size) + ' Bytes')
    else
      Fail('Data-Größe', 'leer');
    
    // PE schreiben
    emitter.WriteToFile('/tmp/test_win64.exe');
    
    if FileExists('/tmp/test_win64.exe') then
    begin
      fs := TFileStream.Create('/tmp/test_win64.exe', fmOpenRead);
      try
        if fs.Size >= 1024 then
          Pass('PE-Datei', IntToStr(fs.Size) + ' Bytes')
        else
          Fail('PE-Datei', 'zu klein: ' + IntToStr(fs.Size));
      finally
        fs.Free;
      end;
    end
    else
      Fail('PE-Datei', 'nicht erstellt');
  finally
    emitter.Free;
  end;
end;

// Test 5: Hex-Dump der ersten Bytes
procedure TestHexDump;
var
  fs: TFileStream;
  buf: array[0..63] of Byte;
  i, j: Integer;
  line: string;
begin
  WriteLn;
  WriteLn('=== Test 5: Hex-Dump (erste 64 Bytes) ===');
  
  if not FileExists('/tmp/test_win64.exe') then
  begin
    WriteLn('  [SKIP] Datei nicht vorhanden');
    Exit;
  end;
  
  fs := TFileStream.Create('/tmp/test_win64.exe', fmOpenRead);
  try
    fs.ReadBuffer(buf, 64);
    
    for i := 0 to 3 do
    begin
      line := Format('  %04X: ', [i * 16]);
      for j := 0 to 15 do
        line := line + IntToHex(buf[i * 16 + j], 2) + ' ';
      WriteLn(line);
    end;
    
    // Prüfe ob MZ Signatur vorhanden
    if (buf[0] = $4D) and (buf[1] = $5A) then
      Pass('Hex-Dump MZ', 'Signatur erkannt')
    else
      Fail('Hex-Dump MZ', 'Signatur nicht erkannt');
  finally
    fs.Free;
  end;
end;

// Test 6: Import Directory Check
procedure TestImportDirectory;
var
  fs: TFileStream;
  peOffset: DWord;
  optHeaderPos: DWord;
  importDirVA, importDirSize: DWord;
  iatVA, iatSize: DWord;
begin
  WriteLn;
  WriteLn('=== Test 6: Import Directory ===');
  
  if not FileExists('/tmp/test_win64.exe') then
  begin
    WriteLn('  [SKIP] Datei nicht vorhanden');
    Exit;
  end;
  
  fs := TFileStream.Create('/tmp/test_win64.exe', fmOpenRead);
  try
    // PE Offset
    fs.Position := $3C;
    fs.ReadBuffer(peOffset, 4);
    
    // Optional Header Position
    optHeaderPos := peOffset + 4 + 20;  // PE Sig + COFF Header
    
    // Data Directory ist am Ende des Optional Headers
    // Bei PE32+ (240 Bytes): Data Directory beginnt bei Offset 112
    // Import Directory ist Index 1, IAT ist Index 12
    
    // Import Directory (Index 1) = Offset 112 + 8*1 = 120 im Optional Header
    fs.Position := optHeaderPos + 112 + 8;
    fs.ReadBuffer(importDirVA, 4);
    fs.ReadBuffer(importDirSize, 4);
    
    // IAT (Index 12) = Offset 112 + 8*12 = 208 im Optional Header
    fs.Position := optHeaderPos + 112 + 96;
    fs.ReadBuffer(iatVA, 4);
    fs.ReadBuffer(iatSize, 4);
    
    if importDirVA > 0 then
      Pass('Import Directory RVA', '$' + IntToHex(importDirVA, 8))
    else
      Fail('Import Directory RVA', 'nicht gesetzt');
    
    if iatVA > 0 then
      Pass('IAT RVA', '$' + IntToHex(iatVA, 8))
    else
      Fail('IAT RVA', 'nicht gesetzt');
    
  finally
    fs.Free;
  end;
end;

begin
  WriteLn('╔════════════════════════════════════════════════════════════╗');
  WriteLn('║           PE64 Writer Test Suite für Lyx Compiler          ║');
  WriteLn('╚════════════════════════════════════════════════════════════╝');
  
  try
    TestMinimalPE;
    TestDosHeader;
    TestCoffHeader;
    TestWin64Emitter;
    TestHexDump;
    TestImportDirectory;
    
    WriteLn;
    WriteLn('════════════════════════════════════════════════════════════');
    WriteLn('Test-Ergebnisse: ', GTestPassed, ' bestanden, ', GTestFailed, ' fehlgeschlagen');
    WriteLn('════════════════════════════════════════════════════════════');
    
    if GTestFailed = 0 then
      WriteLn('ALLE TESTS BESTANDEN!')
    else
      WriteLn('WARNUNG: Einige Tests fehlgeschlagen!');
      
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('EXCEPTION: ', E.ClassName, ' - ', E.Message);
      Halt(1);
    end;
  end;
end.
