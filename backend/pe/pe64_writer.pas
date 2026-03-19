{$mode objfpc}{$H+}
unit pe64_writer;

interface

uses
  SysUtils, Classes, Math, bytes;

type
  // Import-Information für eine DLL-Funktion
  TImportFunction = record
    Name: string;       // Funktionsname (z.B. "ExitProcess")
    Hint: Word;         // Hint-Index (optional, kann 0 sein)
  end;
  TImportFunctionArray = array of TImportFunction;

  // Import-Information für eine DLL
  TImportDll = record
    DllName: string;                // DLL-Name (z.B. "kernel32.dll")
    Functions: TImportFunctionArray; // Importierte Funktionen
  end;
  TImportDllArray = array of TImportDll;

  // IAT-Patch-Information (für Code-Referenzen auf IAT)
  TIATPatch = record
    CodeOffset: Integer;  // Position im Code-Buffer für Patching
    DllIndex: Integer;    // Index in TImportDllArray
    FuncIndex: Integer;   // Index in Functions-Array
  end;
  TIATPatchArray = array of TIATPatch;

  // LEA Patch: patch LEA [rip+disp32] to point to string index in .data
  TLeaStrPatch = record
    CodeOffset: Integer; // position in code buffer where LEA opcode starts
    StrIndex: Integer;   // index in data buffer/strings
  end;
  TLeaStrPatchArray = array of TLeaStrPatch;

  // LEA Patch for global variable addresses
  TLeaVarPatch = record
    CodeOffset: Integer; // position in code buffer where LEA opcode starts
    VarIndex: Integer;   // index into allocated globals
  end;
  TLeaVarPatchArray = array of TLeaVarPatch;

  // Data-internal reference patch (e.g., VMT RTTI pointers)
  // Patches a 64-bit address in data section to point to another data location
  TDataRefPatch = record
    DataOffset: Integer;    // position in data buffer where address is stored
    TargetOffset: Integer;  // target offset within data section
    IsCodeRef: Boolean;     // if true, target is in .text section
  end;
  TDataRefPatchArray = array of TDataRefPatch;

// Minimales PE64 ohne Imports (nur für Tests)
procedure WritePE64Minimal(const filename: string; const codeBuf: TByteBuffer);

// PE64 mit Imports
procedure WritePE64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  const imports: TImportDllArray; const iatPatches: TIATPatchArray;
  const leaStrPatches: TLeaStrPatchArray; const leaVarPatches: TLeaVarPatchArray;
  const dataRefPatches: TDataRefPatchArray;
  entryOffset: Integer);

implementation

const
  // PE Constants
  IMAGE_FILE_MACHINE_AMD64 = $8664;
  IMAGE_FILE_EXECUTABLE_IMAGE = $0002;
  IMAGE_FILE_LARGE_ADDRESS_AWARE = $0020;

  IMAGE_SUBSYSTEM_WINDOWS_CUI = 3;  // Console Application

  IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA = $0020;
  IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = $0040;
  IMAGE_DLLCHARACTERISTICS_NX_COMPAT = $0100;
  IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE = $8000;

  // Section Characteristics
  IMAGE_SCN_CNT_CODE = $00000020;
  IMAGE_SCN_CNT_INITIALIZED_DATA = $00000040;
  IMAGE_SCN_MEM_EXECUTE = $20000000;
  IMAGE_SCN_MEM_READ = $40000000;
  IMAGE_SCN_MEM_WRITE = $80000000;

  // Data Directory Indices
  IMAGE_DIRECTORY_ENTRY_EXPORT = 0;
  IMAGE_DIRECTORY_ENTRY_IMPORT = 1;
  IMAGE_DIRECTORY_ENTRY_RESOURCE = 2;
  IMAGE_DIRECTORY_ENTRY_EXCEPTION = 3;
  IMAGE_DIRECTORY_ENTRY_SECURITY = 4;
  IMAGE_DIRECTORY_ENTRY_BASERELOC = 5;
  IMAGE_DIRECTORY_ENTRY_DEBUG = 6;
  IMAGE_DIRECTORY_ENTRY_ARCHITECTURE = 7;
  IMAGE_DIRECTORY_ENTRY_GLOBALPTR = 8;
  IMAGE_DIRECTORY_ENTRY_TLS = 9;
  IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG = 10;
  IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT = 11;
  IMAGE_DIRECTORY_ENTRY_IAT = 12;
  IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13;
  IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR = 14;

  // Standard Values
  DEFAULT_IMAGE_BASE: UInt64 = $0000000140000000;
  SECTION_ALIGNMENT: DWord = $1000;  // 4 KB
  FILE_ALIGNMENT: DWord = $200;      // 512 Bytes

type
  // DOS Header (64 Bytes)
  TDosHeader = packed record
    e_magic: Word;           // 'MZ' = $5A4D
    e_cblp: Word;
    e_cp: Word;
    e_crlc: Word;
    e_cparhdr: Word;
    e_minalloc: Word;
    e_maxalloc: Word;
    e_ss: Word;
    e_sp: Word;
    e_csum: Word;
    e_ip: Word;
    e_cs: Word;
    e_lfarlc: Word;
    e_ovno: Word;
    e_res: array[0..3] of Word;
    e_oemid: Word;
    e_oeminfo: Word;
    e_res2: array[0..9] of Word;
    e_lfanew: DWord;         // Offset to PE Header
  end;

  // COFF File Header (20 Bytes)
  TCoffHeader = packed record
    Machine: Word;
    NumberOfSections: Word;
    TimeDateStamp: DWord;
    PointerToSymbolTable: DWord;
    NumberOfSymbols: DWord;
    SizeOfOptionalHeader: Word;
    Characteristics: Word;
  end;

  // Data Directory Entry (8 Bytes)
  TDataDirectory = packed record
    VirtualAddress: DWord;
    Size: DWord;
  end;

  // Optional Header PE32+ (240 Bytes)
  TOptionalHeader64 = packed record
    Magic: Word;                         // $020B = PE32+
    MajorLinkerVersion: Byte;
    MinorLinkerVersion: Byte;
    SizeOfCode: DWord;
    SizeOfInitializedData: DWord;
    SizeOfUninitializedData: DWord;
    AddressOfEntryPoint: DWord;
    BaseOfCode: DWord;
    ImageBase: UInt64;
    SectionAlignment: DWord;
    FileAlignment: DWord;
    MajorOperatingSystemVersion: Word;
    MinorOperatingSystemVersion: Word;
    MajorImageVersion: Word;
    MinorImageVersion: Word;
    MajorSubsystemVersion: Word;
    MinorSubsystemVersion: Word;
    Win32VersionValue: DWord;
    SizeOfImage: DWord;
    SizeOfHeaders: DWord;
    CheckSum: DWord;
    Subsystem: Word;
    DllCharacteristics: Word;
    SizeOfStackReserve: UInt64;
    SizeOfStackCommit: UInt64;
    SizeOfHeapReserve: UInt64;
    SizeOfHeapCommit: UInt64;
    LoaderFlags: DWord;
    NumberOfRvaAndSizes: DWord;
    DataDirectory: array[0..15] of TDataDirectory;
  end;

  // Section Header (40 Bytes)
  TSectionHeader = packed record
    Name: array[0..7] of AnsiChar;
    VirtualSize: DWord;
    VirtualAddress: DWord;
    SizeOfRawData: DWord;
    PointerToRawData: DWord;
    PointerToRelocations: DWord;
    PointerToLinenumbers: DWord;
    NumberOfRelocations: Word;
    NumberOfLinenumbers: Word;
    Characteristics: DWord;
  end;

  // Import Directory Entry (20 Bytes)
  TImportDirectoryEntry = packed record
    OriginalFirstThunk: DWord;  // RVA to Import Lookup Table (ILT)
    TimeDateStamp: DWord;
    ForwarderChain: DWord;
    Name: DWord;                // RVA to DLL name
    FirstThunk: DWord;          // RVA to Import Address Table (IAT)
  end;

function AlignUp(v, a: DWord): DWord;
begin
  if a = 0 then
    Result := v
  else
    Result := (v + a - 1) and not (a - 1);
end;

procedure WriteDosHeader(buf: TByteBuffer; peOffset: DWord);
var
  dos: TDosHeader;
begin
  FillChar(dos, SizeOf(dos), 0);
  dos.e_magic := $5A4D;      // 'MZ'
  dos.e_cblp := $0090;
  dos.e_cp := $0003;
  dos.e_cparhdr := $0004;
  dos.e_maxalloc := $FFFF;
  dos.e_sp := $00B8;
  dos.e_lfarlc := $0040;
  dos.e_lfanew := peOffset;
  buf.WriteBuffer(dos, SizeOf(dos));
end;

procedure WriteDosStub(buf: TByteBuffer);
const
  // Minimal DOS stub: "This program cannot be run in DOS mode.\r\r\n$"
  // Plus simple code: push cs; pop ds; mov dx, msg; mov ah, 9; int 21h; mov ax, 4c01h; int 21h
  DosStub: array[0..63] of Byte = (
    $0E, $1F, $BA, $0E, $00, $B4, $09, $CD, $21, $B8, $01, $4C, $CD, $21,
    $54, $68, $69, $73, $20, $70, $72, $6F, $67, $72, $61, $6D, $20, $63,
    $61, $6E, $6E, $6F, $74, $20, $62, $65, $20, $72, $75, $6E, $20, $69,
    $6E, $20, $44, $4F, $53, $20, $6D, $6F, $64, $65, $2E, $0D, $0D, $0A,
    $24, $00, $00, $00, $00, $00, $00, $00
  );
begin
  buf.WriteBytes(DosStub);
end;

procedure WriteCoffHeader(buf: TByteBuffer; numSections: Word; optHeaderSize: Word);
var
  coff: TCoffHeader;
begin
  FillChar(coff, SizeOf(coff), 0);
  coff.Machine := IMAGE_FILE_MACHINE_AMD64;
  coff.NumberOfSections := numSections;
  coff.TimeDateStamp := 0;  // Reproducible builds
  coff.PointerToSymbolTable := 0;
  coff.NumberOfSymbols := 0;
  coff.SizeOfOptionalHeader := optHeaderSize;
  coff.Characteristics := IMAGE_FILE_EXECUTABLE_IMAGE or IMAGE_FILE_LARGE_ADDRESS_AWARE;
  buf.WriteBuffer(coff, SizeOf(coff));
end;

procedure WriteOptionalHeader(buf: TByteBuffer; entryRVA, codeRVA, codeSize,
  rdataRVA, rdataSize, dataRVA, dataSize, imageSize, headerSize: DWord;
  importDirRVA, importDirSize, iatRVA, iatSize: DWord);
var
  opt: TOptionalHeader64;
  i: Integer;
begin
  FillChar(opt, SizeOf(opt), 0);
  
  opt.Magic := $020B;  // PE32+
  opt.MajorLinkerVersion := 1;
  opt.MinorLinkerVersion := 0;
  opt.SizeOfCode := AlignUp(codeSize, FILE_ALIGNMENT);
  opt.SizeOfInitializedData := AlignUp(rdataSize + dataSize, FILE_ALIGNMENT);
  opt.SizeOfUninitializedData := 0;
  opt.AddressOfEntryPoint := entryRVA;
  opt.BaseOfCode := codeRVA;
  opt.ImageBase := DEFAULT_IMAGE_BASE;
  opt.SectionAlignment := SECTION_ALIGNMENT;
  opt.FileAlignment := FILE_ALIGNMENT;
  opt.MajorOperatingSystemVersion := 6;
  opt.MinorOperatingSystemVersion := 2;  // Windows 8+
  opt.MajorImageVersion := 0;
  opt.MinorImageVersion := 0;
  opt.MajorSubsystemVersion := 6;
  opt.MinorSubsystemVersion := 2;
  opt.Win32VersionValue := 0;
  opt.SizeOfImage := imageSize;
  opt.SizeOfHeaders := headerSize;
  opt.CheckSum := 0;  // Optional for EXEs
  opt.Subsystem := IMAGE_SUBSYSTEM_WINDOWS_CUI;
  opt.DllCharacteristics := IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE or
                            IMAGE_DLLCHARACTERISTICS_NX_COMPAT or
                            IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA or
                            IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE;
  opt.SizeOfStackReserve := $100000;   // 1 MB
  opt.SizeOfStackCommit := $1000;      // 4 KB
  opt.SizeOfHeapReserve := $100000;    // 1 MB
  opt.SizeOfHeapCommit := $1000;       // 4 KB
  opt.LoaderFlags := 0;
  opt.NumberOfRvaAndSizes := 16;
  
  // Data Directories
  for i := 0 to 15 do
  begin
    opt.DataDirectory[i].VirtualAddress := 0;
    opt.DataDirectory[i].Size := 0;
  end;
  
  // Import Directory
  if importDirRVA > 0 then
  begin
    opt.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress := importDirRVA;
    opt.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size := importDirSize;
  end;
  
  // IAT
  if iatRVA > 0 then
  begin
    opt.DataDirectory[IMAGE_DIRECTORY_ENTRY_IAT].VirtualAddress := iatRVA;
    opt.DataDirectory[IMAGE_DIRECTORY_ENTRY_IAT].Size := iatSize;
  end;
  
  buf.WriteBuffer(opt, SizeOf(opt));
end;

procedure WriteSectionHeader(buf: TByteBuffer; const name: string;
  virtualSize, virtualAddr, rawSize, rawPtr, characteristics: DWord);
var
  sec: TSectionHeader;
  i: Integer;
begin
  FillChar(sec, SizeOf(sec), 0);
  
  // Section Name (max 8 chars)
  for i := 0 to Min(Length(name), 8) - 1 do
    sec.Name[i] := AnsiChar(name[i + 1]);
  
  sec.VirtualSize := virtualSize;
  sec.VirtualAddress := virtualAddr;
  sec.SizeOfRawData := rawSize;
  sec.PointerToRawData := rawPtr;
  sec.PointerToRelocations := 0;
  sec.PointerToLinenumbers := 0;
  sec.NumberOfRelocations := 0;
  sec.NumberOfLinenumbers := 0;
  sec.Characteristics := characteristics;
  
  buf.WriteBuffer(sec, SizeOf(sec));
end;

procedure WritePE64Minimal(const filename: string; const codeBuf: TByteBuffer);
var
  fileBuf: TByteBuffer;
  headerSize, textRVA, textFileSize, imageSize: DWord;
  peHeaderOffset: DWord;
  padding: Integer;
begin
  fileBuf := TByteBuffer.Create;
  try
    // Layout:
    // 0x0000 - DOS Header (64 bytes)
    // 0x0040 - DOS Stub (64 bytes)
    // 0x0080 - PE Signature (4 bytes)
    // 0x0084 - COFF Header (20 bytes)
    // 0x0098 - Optional Header (240 bytes)
    // 0x0188 - Section Headers (1 * 40 = 40 bytes)
    // 0x01B0 - Padding to FILE_ALIGNMENT
    // 0x0200 - .text Section
    
    peHeaderOffset := $80;
    headerSize := AlignUp($80 + 4 + 20 + 240 + 40, FILE_ALIGNMENT);  // 0x200
    textRVA := SECTION_ALIGNMENT;  // 0x1000
    textFileSize := AlignUp(codeBuf.Size, FILE_ALIGNMENT);
    imageSize := AlignUp(textRVA + codeBuf.Size, SECTION_ALIGNMENT);
    
    // 1. DOS Header
    WriteDosHeader(fileBuf, peHeaderOffset);
    
    // 2. DOS Stub (pad to PE offset)
    WriteDosStub(fileBuf);
    
    // 3. PE Signature
    fileBuf.WriteBytes([$50, $45, $00, $00]);  // "PE\0\0"
    
    // 4. COFF Header
    WriteCoffHeader(fileBuf, 1, 240);
    
    // 5. Optional Header
    WriteOptionalHeader(fileBuf,
      textRVA,        // Entry Point RVA
      textRVA,        // Code RVA
      codeBuf.Size,   // Code Size
      0, 0,           // .rdata (none)
      0, 0,           // .data (none)
      imageSize,
      headerSize,
      0, 0,           // Import Directory (none)
      0, 0);          // IAT (none)
    
    // 6. Section Header: .text
    WriteSectionHeader(fileBuf, '.text',
      codeBuf.Size,   // Virtual Size
      textRVA,        // Virtual Address
      textFileSize,   // Size of Raw Data
      headerSize,     // Pointer to Raw Data
      IMAGE_SCN_CNT_CODE or IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_MEM_READ);
    
    // 7. Padding to headerSize
    padding := headerSize - fileBuf.Size;
    if padding > 0 then
      fileBuf.WriteBytesFill(padding, 0);
    
    // 8. .text Section Content
    fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeBuf.Size);
    
    // 9. Padding to textFileSize
    padding := textFileSize - codeBuf.Size;
    if padding > 0 then
      fileBuf.WriteBytesFill(padding, 0);
    
    // Write to file
    fileBuf.SaveToFile(filename);
  finally
    fileBuf.Free;
  end;
end;

procedure WritePE64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  const imports: TImportDllArray; const iatPatches: TIATPatchArray;
  const leaStrPatches: TLeaStrPatchArray; const leaVarPatches: TLeaVarPatchArray;
  const dataRefPatches: TDataRefPatchArray;
  entryOffset: Integer);
var
  fileBuf, rdataBuf: TByteBuffer;
  headerSize, textRVA, textFileSize, rdataRVA, rdataFileSize: DWord;
  dataRVA, dataFileSize, imageSize: DWord;
  peHeaderOffset: DWord;
  padding, numSections: Integer;
  
  // Import table positions
  importDirRVA, importDirSize: DWord;
  iltRVA, iatRVA, iatSize: DWord;
  hintNameRVA, dllNameRVA: DWord;
  
  // Import building
  totalFuncs, i, j, k, p, di: Integer;
  iltOffset, iatOffset, hintNameOffset, dllNameOffset: DWord;
  importDirOffset: DWord;
  hintNameEntry: Word;
  importDir: TImportDirectoryEntry;
  iatEntries: array of DWord;  // File offsets of IAT entries for patching
  
  // Patch loop variables
  currentIltRVA, currentIatRVA: DWord;
  currentHintNameRVA, currentDllNameRVA: DWord;
  iltFileOffset, iatFileOffset: DWord;
  
  // IAT patch variables
  entryRVA: DWord;
  patchOffset: Integer;
  instrEndRVA: DWord;
  disp32: Int32;
begin
  // Count total functions for IAT size calculation
  totalFuncs := 0;
  for i := 0 to High(imports) do
    totalFuncs := totalFuncs + Length(imports[i].Functions);
  
  if totalFuncs = 0 then
  begin
    // No imports - use minimal version
    WritePE64Minimal(filename, codeBuf);
    Exit;
  end;
  
  SetLength(iatEntries, totalFuncs);
  
  rdataBuf := TByteBuffer.Create;
  fileBuf := TByteBuffer.Create;
  try
    // Build .rdata content (Import structures)
    // Layout within .rdata:
    // 1. Import Directory Table (one entry per DLL + null terminator)
    // 2. Import Lookup Tables (ILT) - one per DLL
    // 3. Import Address Tables (IAT) - one per DLL (copy of ILT)
    // 4. Hint/Name Table
    // 5. DLL Names
    
    // Calculate sizes
    importDirSize := (Length(imports) + 1) * SizeOf(TImportDirectoryEntry);  // +1 for null terminator
    
    // Reserve space for Import Directory (will fill later)
    importDirOffset := rdataBuf.Size;
    rdataBuf.WriteBytesFill(importDirSize, 0);
    
    // Build ILT, IAT, Hint/Name, and DLL names for each DLL
    iltOffset := rdataBuf.Size;
    
    // First pass: ILT entries
    for i := 0 to High(imports) do
    begin
      for j := 0 to High(imports[i].Functions) do
        rdataBuf.WriteU64LE(0);  // Placeholder, will patch
      rdataBuf.WriteU64LE(0);    // Null terminator
    end;
    
    // IAT entries (copy of ILT initially)
    iatOffset := rdataBuf.Size;
    k := 0;
    for i := 0 to High(imports) do
    begin
      for j := 0 to High(imports[i].Functions) do
      begin
        iatEntries[k] := rdataBuf.Size;  // Remember file offset for patching
        rdataBuf.WriteU64LE(0);  // Placeholder
        Inc(k);
      end;
      rdataBuf.WriteU64LE(0);    // Null terminator
    end;
    
    // Hint/Name entries
    hintNameOffset := rdataBuf.Size;
    for i := 0 to High(imports) do
    begin
      for j := 0 to High(imports[i].Functions) do
      begin
        rdataBuf.WriteU16LE(imports[i].Functions[j].Hint);
        // Write function name (null-terminated)
        for k := 1 to Length(imports[i].Functions[j].Name) do
          rdataBuf.WriteU8(Ord(imports[i].Functions[j].Name[k]));
        rdataBuf.WriteU8(0);
        // Align to word boundary
        if (rdataBuf.Size mod 2) <> 0 then
          rdataBuf.WriteU8(0);
      end;
    end;
    
    // DLL names
    dllNameOffset := rdataBuf.Size;
    for i := 0 to High(imports) do
    begin
      for j := 1 to Length(imports[i].DllName) do
        rdataBuf.WriteU8(Ord(imports[i].DllName[j]));
      rdataBuf.WriteU8(0);
    end;
    
    // Now calculate RVAs and patch everything
    peHeaderOffset := $80;
    numSections := 2;  // .text, .rdata
    if dataBuf.Size > 0 then
      Inc(numSections);  // .data
    
    headerSize := AlignUp($80 + 4 + 20 + 240 + (numSections * 40), FILE_ALIGNMENT);
    textRVA := SECTION_ALIGNMENT;
    textFileSize := AlignUp(codeBuf.Size, FILE_ALIGNMENT);
    rdataRVA := AlignUp(textRVA + codeBuf.Size, SECTION_ALIGNMENT);
    rdataFileSize := AlignUp(rdataBuf.Size, FILE_ALIGNMENT);
    
    if dataBuf.Size > 0 then
    begin
      dataRVA := AlignUp(rdataRVA + rdataBuf.Size, SECTION_ALIGNMENT);
      dataFileSize := AlignUp(dataBuf.Size, FILE_ALIGNMENT);
    end
    else
    begin
      dataRVA := 0;
      dataFileSize := 0;
    end;
    
    imageSize := rdataRVA + AlignUp(rdataBuf.Size, SECTION_ALIGNMENT);
    if dataBuf.Size > 0 then
      imageSize := dataRVA + AlignUp(dataBuf.Size, SECTION_ALIGNMENT);
    
    // Calculate RVAs for import structures
    importDirRVA := rdataRVA + importDirOffset;
    iltRVA := rdataRVA + iltOffset;
    iatRVA := rdataRVA + iatOffset;
    hintNameRVA := rdataRVA + hintNameOffset;
    dllNameRVA := rdataRVA + dllNameOffset;
    iatSize := (totalFuncs + Length(imports)) * 8;  // +null terminators
    
    // Patch ILT and IAT entries with Hint/Name RVAs
    // And patch Import Directory entries
    currentIltRVA := iltRVA;
    currentIatRVA := iatRVA;
    currentHintNameRVA := hintNameRVA;
    currentDllNameRVA := dllNameRVA;
    iltFileOffset := iltOffset;
    iatFileOffset := iatOffset;
    
    for i := 0 to High(imports) do
    begin
      // Fill Import Directory entry
      FillChar(importDir, SizeOf(importDir), 0);
      importDir.OriginalFirstThunk := currentIltRVA;
      importDir.TimeDateStamp := 0;
      importDir.ForwarderChain := $FFFFFFFF;
      importDir.Name := currentDllNameRVA;
      importDir.FirstThunk := currentIatRVA;
      
      // Patch in rdataBuf
      Move(importDir, rdataBuf.GetBuffer[importDirOffset + i * SizeOf(importDir)], SizeOf(importDir));
      
      // Patch ILT and IAT entries
      for j := 0 to High(imports[i].Functions) do
      begin
        // ILT entry points to Hint/Name
        rdataBuf.PatchU64LE(iltFileOffset, currentHintNameRVA);
        // IAT entry (same as ILT initially)
        rdataBuf.PatchU64LE(iatFileOffset, currentHintNameRVA);
        
        Inc(iltFileOffset, 8);
        Inc(iatFileOffset, 8);
        
        // Move to next Hint/Name entry
        currentHintNameRVA := currentHintNameRVA + 2 +
          DWord(Length(imports[i].Functions[j].Name)) + 1;
        // Align
        if (currentHintNameRVA mod 2) <> 0 then
          Inc(currentHintNameRVA);
      end;
      
      // Skip null terminators
      Inc(iltFileOffset, 8);
      Inc(iatFileOffset, 8);
      currentIltRVA := currentIltRVA + (Length(imports[i].Functions) + 1) * 8;
      currentIatRVA := currentIatRVA + (Length(imports[i].Functions) + 1) * 8;
      
      // Move to next DLL name
      currentDllNameRVA := currentDllNameRVA + DWord(Length(imports[i].DllName)) + 1;
    end;
    
    // Build final PE file
    // 1. DOS Header
    WriteDosHeader(fileBuf, peHeaderOffset);
    
    // 2. DOS Stub
    WriteDosStub(fileBuf);
    
    // 3. PE Signature
    fileBuf.WriteBytes([$50, $45, $00, $00]);
    
    // 4. COFF Header
    WriteCoffHeader(fileBuf, numSections, 240);
    
    // 5. Optional Header
    WriteOptionalHeader(fileBuf,
      textRVA + DWord(entryOffset),  // Entry Point RVA (offset within .text)
      textRVA,           // Code RVA
      codeBuf.Size,      // Code Size
      rdataRVA,          // .rdata RVA
      rdataBuf.Size,     // .rdata Size
      dataRVA,           // .data RVA
      dataBuf.Size,      // .data Size
      imageSize,
      headerSize,
      importDirRVA,
      importDirSize,
      iatRVA,
      iatSize);
    
    // 6. Section Headers
    // .text
    WriteSectionHeader(fileBuf, '.text',
      codeBuf.Size,
      textRVA,
      textFileSize,
      headerSize,
      IMAGE_SCN_CNT_CODE or IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_MEM_READ);
    
    // .rdata
    WriteSectionHeader(fileBuf, '.rdata',
      rdataBuf.Size,
      rdataRVA,
      rdataFileSize,
      headerSize + textFileSize,
      IMAGE_SCN_CNT_INITIALIZED_DATA or IMAGE_SCN_MEM_READ);
    
    // .data (if present)
    if dataBuf.Size > 0 then
    begin
      WriteSectionHeader(fileBuf, '.data',
        dataBuf.Size,
        dataRVA,
        dataFileSize,
        headerSize + textFileSize + rdataFileSize,
        IMAGE_SCN_CNT_INITIALIZED_DATA or IMAGE_SCN_MEM_READ or IMAGE_SCN_MEM_WRITE);
    end;
    
    // 7. Padding to headerSize
    padding := headerSize - fileBuf.Size;
    if padding > 0 then
      fileBuf.WriteBytesFill(padding, 0);
    
    // 8. .text Section
    fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeBuf.Size);
    padding := textFileSize - codeBuf.Size;
    if padding > 0 then
      fileBuf.WriteBytesFill(padding, 0);
    
    // 9. .rdata Section
    fileBuf.WriteBuffer(rdataBuf.GetBuffer^, rdataBuf.Size);
    padding := rdataFileSize - rdataBuf.Size;
    if padding > 0 then
      fileBuf.WriteBytesFill(padding, 0);
    
    // 10. .data Section (if present)
    if dataBuf.Size > 0 then
    begin
      fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataBuf.Size);
      padding := dataFileSize - dataBuf.Size;
      if padding > 0 then
        fileBuf.WriteBytesFill(padding, 0);
    end;
    
    // Apply IAT patches to code buffer
    // Each patch needs: calculate IAT entry RVA, then compute RIP-relative offset
    k := 0;
    for i := 0 to High(imports) do
    begin
      for j := 0 to High(imports[i].Functions) do
      begin
        // Find matching patch
        for p := 0 to High(iatPatches) do
        begin
          if (iatPatches[p].DllIndex = i) and (iatPatches[p].FuncIndex = j) then
          begin
            // IAT starts at iatRVA, each DLL has its functions + null terminator
            entryRVA := iatRVA;
            for di := 0 to i - 1 do
              entryRVA := entryRVA + (Length(imports[di].Functions) + 1) * 8;
            entryRVA := entryRVA + DWord(j) * 8;

            // Patch position in code
            patchOffset := iatPatches[p].CodeOffset;
            // Instruction end RVA (patch is 4 bytes, instruction is 6 bytes for FF 15 xx xx xx xx)
            instrEndRVA := textRVA + DWord(patchOffset) + 4; // disp32 is 4 bytes; end = dispStart + 4
            // RIP-relative displacement
            disp32 := Int32(entryRVA) - Int32(instrEndRVA);

            // Patch in file buffer (code is at headerSize)
            fileBuf.PatchU32LE(headerSize + patchOffset, Cardinal(disp32));
          end;
        end;
        Inc(k);
      end;
    end;

    // Apply LEA patches for strings (lea rax, [rip+disp32] -> opcode length 7 bytes)
    if Length(leaStrPatches) > 0 then
    begin
      for i := 0 to High(leaStrPatches) do
      begin
        patchOffset := leaStrPatches[i].CodeOffset;
        // target RVA = dataRVA + offset of string in dataBuf
        // For strings we assume they are placed at start of dataBuf in emitter; pass StrIndex as offset
        // Note: here StrIndex is actually the byte offset within dataBuf where string starts
        entryRVA := dataRVA + DWord(leaStrPatches[i].StrIndex);
        instrEndRVA := textRVA + DWord(patchOffset) + 7; // lea imm32 length
        disp32 := Int32(entryRVA) - Int32(instrEndRVA);
        fileBuf.PatchU32LE(headerSize + patchOffset + 3, Cardinal(disp32));
      end;
    end;

    // Apply LEA patches for global vars
    if Length(leaVarPatches) > 0 then
    begin
      for i := 0 to High(leaVarPatches) do
      begin
        patchOffset := leaVarPatches[i].CodeOffset;
        // VarIndex can be:
        // 1. Offset in data section (global variables)
        // 2. VMT label marker (>= $100000) - VarIndex = $100000 + bufferPosition
        if leaVarPatches[i].VarIndex >= $100000 then
        begin
          // This is a VMT label - VarIndex contains buffer position + marker
          // Extract buffer position and convert to RVA
          entryRVA := textRVA + DWord(leaVarPatches[i].VarIndex - $100000);
        end
        else if leaVarPatches[i].VarIndex >= Integer(textRVA) then
        begin
          // This is a VMT label - VarIndex is the RVA directly (in code section)
          entryRVA := DWord(leaVarPatches[i].VarIndex);
        end
        else
        begin
          // Regular global variable in data section
          entryRVA := dataRVA + DWord(leaVarPatches[i].VarIndex);
        end;
        // Calculate RIP-relative displacement for LEA instruction
        // patchOffset points to the displacement field (4 bytes), so instr ends at patchOffset + 4
        instrEndRVA := textRVA + DWord(patchOffset) + 4;
        disp32 := Int32(entryRVA) - Int32(instrEndRVA);
        fileBuf.PatchU32LE(headerSize + patchOffset, Cardinal(disp32));
      end;
    end;
    
    // Apply data-internal reference patches (VMT RTTI pointers, etc.)
    if Length(dataRefPatches) > 0 then
    begin
      for i := 0 to High(dataRefPatches) do
      begin
        // Calculate file offset of the patch location in .data section
        patchOffset := headerSize + textFileSize + rdataFileSize + dataRefPatches[i].DataOffset;
        // Calculate target RVA
        if dataRefPatches[i].IsCodeRef then
          entryRVA := textRVA + DWord(dataRefPatches[i].TargetOffset)
        else
          entryRVA := dataRVA + DWord(dataRefPatches[i].TargetOffset);
        // Patch the absolute address (full 64-bit RVA)
        fileBuf.PatchU64LE(patchOffset, UInt64(entryRVA));
      end;
    end;
    
    fileBuf.SaveToFile(filename);
  finally
    rdataBuf.Free;
    fileBuf.Free;
  end;
end;

end.
