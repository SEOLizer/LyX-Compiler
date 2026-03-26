{$mode objfpc}{$H+}
unit pe64_arm64_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

type
  // IMAGE_DOS_HEADER
  _IMAGE_DOS_HEADER = packed record
    e_magic: Word;           // Magic number (MZ)
    e_cblp: Word;            // Bytes on last page of file
    e_cp: Word;              // Pages in file
    e_crlc: Word;            // Relocations
    e_cparhdr: Word;         // Size of header in paragraphs
    e_minalloc: Word;        // Minimum extra paragraphs needed
    e_maxalloc: Word;        // Maximum extra paragraphs needed
    e_ss: Word;              // Initial (relative) SS value
    e_sp: Word;              // Initial SP value
    e_csum: Word;            // Checksum
    e_ip: Word;              // Initial IP value
    e_cs: Word;              // Initial (relative) CS value
    e_lfarlc: Word;          // File address of relocation table
    e_ovno: Word;            // Overlay number
    e_res: array[0..3] of Word; // Reserved words
    e_oemid: Word;           // OEM identifier (for e_oeminfo)
    e_oeminfo: Word;         // OEM information; e_oemid specific
    e_res2: array[0..9] of Word; // Reserved words
    e_lfanew: Longint;       // File address of new EXE header (NT Headers)
  end;
  IMAGE_DOS_HEADER = _IMAGE_DOS_HEADER;

  // IMAGE_FILE_HEADER
  _IMAGE_FILE_HEADER = packed record
    Machine: Word;
    NumberOfSections: Word;
    TimeDateStamp: DWord;
    PointerToSymbolTable: DWord;
    NumberOfSymbols: DWord;
    SizeOfOptionalHeader: Word;
    Characteristics: Word;
  end;
  IMAGE_FILE_HEADER = _IMAGE_FILE_HEADER;

  // IMAGE_DATA_DIRECTORY
  _IMAGE_DATA_DIRECTORY = packed record
    VirtualAddress: DWord;
    Size: DWord;
  end;
  IMAGE_DATA_DIRECTORY = _IMAGE_DATA_DIRECTORY;

  // IMAGE_OPTIONAL_HEADER64 (PE32+)
  _IMAGE_OPTIONAL_HEADER64 = packed record
    Magic: Word;
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
    Checksum: DWord;
    Subsystem: Word;
    DllCharacteristics: Word;
    SizeOfStackReserve: UInt64;
    SizeOfStackCommit: UInt64;
    SizeOfHeapReserve: UInt64;
    SizeOfHeapCommit: UInt64;
    LoaderFlags: DWord;
    NumberOfRvaAndSizes: DWord;
    DataDirectory: array[0..15] of IMAGE_DATA_DIRECTORY;
  end;
  IMAGE_OPTIONAL_HEADER64 = _IMAGE_OPTIONAL_HEADER64;

  // IMAGE_NT_HEADERS (PE32+)
  _IMAGE_NT_HEADERS64 = packed record
    Signature: DWord; // PE\0\0
    FileHeader: IMAGE_FILE_HEADER;
    OptionalHeader: IMAGE_OPTIONAL_HEADER64;
  end;
  IMAGE_NT_HEADERS64 = _IMAGE_NT_HEADERS64;

  // IMAGE_SECTION_HEADER
  _IMAGE_SECTION_HEADER = packed record
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
  IMAGE_SECTION_HEADER = _IMAGE_SECTION_HEADER;

  TPE64ARM64Writer = class
  public
    constructor Create;
    function WriteObjectFile(const AFileName: string; ACodeBuffer: TByteBuffer; ADataBuffer: TByteBuffer): Boolean;
  end;

  // IMAGE_IMPORT_DESCRIPTOR
  _IMAGE_IMPORT_DESCRIPTOR = packed record
    OriginalFirstThunk: DWord; // RVA to Import Name Table (INT)
    TimeDateStamp: DWord;
    ForwarderChain: DWord;
    Name: DWord;             // RVA to DLL name string
    FirstThunk: DWord;       // RVA to Import Address Table (IAT)
  end;
  IMAGE_IMPORT_DESCRIPTOR = _IMAGE_IMPORT_DESCRIPTOR;

  // IMAGE_THUNK_DATA64 (für INT und IAT)
  _IMAGE_THUNK_DATA64 = packed record
    case Byte of
      0: (AddressOfData: UInt64);
      1: (Ordinal: UInt64);
  end;
  IMAGE_THUNK_DATA64 = _IMAGE_THUNK_DATA64;

  // IMAGE_IMPORT_BY_NAME
  _IMAGE_IMPORT_BY_NAME = packed record
    Hint: Word;
    Name: array[0..0] of AnsiChar; // Null-terminierter String
  end;
  IMAGE_IMPORT_BY_NAME = _IMAGE_IMPORT_BY_NAME;

const
  // DOS Header
  IMAGE_DOS_SIGNATURE = $5A4D; // MZ

  // NT Header
  IMAGE_NT_SIGNATURE = $00004550; // PE\0\0

  // File Header
  IMAGE_FILE_MACHINE_ARM64 = $AA64;
  IMAGE_FILE_EXECUTABLE_IMAGE = $0002;
  IMAGE_FILE_LARGE_ADDRESS_AWARE = $0020;
  IMAGE_FILE_DLL = $2000; // Not a DLL, so exclude

  // Optional Header
  IMAGE_NT_OPTIONAL_HDR64_MAGIC = $20B; // PE32+
  IMAGE_SUBSYSTEM_WINDOWS_CUI = 3; // Console User Interface
  IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = $0040;
  IMAGE_DLLCHARACTERISTICS_NX_COMPAT = $0100;
  IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE = $8000;

  // Data Directory Indices
  IMAGE_DIRECTORY_ENTRY_EXPORT = 0;
  IMAGE_DIRECTORY_ENTRY_IMPORT = 1;
  // ... weitere Einträge nach Bedarf

  // Section Header Characteristics
  IMAGE_SCN_CNT_CODE = $00000020;         // Section contains code.
  IMAGE_SCN_CNT_INITIALIZED_DATA = $00000040; // Section contains initialized data.
  IMAGE_SCN_MEM_EXECUTE = $20000000;     // Section is executable.
  IMAGE_SCN_MEM_READ = $40000000;        // Section is readable.
  IMAGE_SCN_MEM_WRITE = $80000000;       // Section is writable.

implementation

// Hilfsfunktion zum Schreiben eines null-terminierten AnsiStrings
procedure WriteAnsiString(buf: TFileStream; const s: AnsiString);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    buf.WriteByte(Byte(s[i]));
  buf.WriteByte(0); // Null-Terminator
end;

// Hilfsfunktion zum Runden auf Alignment
function AlignUp(value, alignment: DWord): DWord;
begin
  if alignment = 0 then
    Result := value
  else
    Result := (value + alignment - 1) and not (alignment - 1);
end;

constructor TPE64ARM64Writer.Create;
begin
  inherited Create;
end;

function TPE64ARM64Writer.WriteObjectFile(const AFileName: string; ACodeBuffer: TByteBuffer; ADataBuffer: TByteBuffer): Boolean;
var
  fileStream: TFileStream;
  dosHeader: IMAGE_DOS_HEADER;
  ntHeaders: IMAGE_NT_HEADERS64;
  textSectionHeader: IMAGE_SECTION_HEADER;
  dataSectionHeader: IMAGE_SECTION_HEADER;
  idataSectionHeader: IMAGE_SECTION_HEADER;
  currentFileOffset: DWord;
  currentVirtualAddress: DWord;
  codeSize: DWord;
  dataSize: DWord;
  idataSize: DWord;

  // Import-spezifische Variablen
  kernel32DllName: AnsiString = 'kernel32.dll';
  exitProcessFuncName: AnsiString = 'ExitProcess';
  kernel32DllNameRVA: DWord;
  exitProcessHintNameRVA: DWord;
  intRVA: DWord; // Import Name Table RVA
  iatRVA: DWord; // Import Address Table RVA
  importDescriptorRVA: DWord;

  imageImportByName: IMAGE_IMPORT_BY_NAME;
  imageThunkData: IMAGE_THUNK_DATA64;
  imageImportDescriptor: IMAGE_IMPORT_DESCRIPTOR;

begin
  Result := False;
  fileStream := TFileStream.Create(AFileName, fmCreate);
  try
    FillChar(dosHeader, SizeOf(dosHeader), 0);
    dosHeader.e_magic := IMAGE_DOS_SIGNATURE;
    dosHeader.e_lfanew := SizeOf(IMAGE_DOS_HEADER); // PE Header direkt nach DOS Header

    fileStream.WriteBuffer(dosHeader, SizeOf(dosHeader));

    currentFileOffset := SizeOf(IMAGE_DOS_HEADER);
    currentVirtualAddress := $10000; // Typische Start-VA

    codeSize := ACodeBuffer.Size;
    dataSize := ADataBuffer.Size;

    // Berechnung der Größe der Import-Daten
    // kernel32.dll string + null = len + 1
    // ExitProcess string + null = len + 1
    // IMAGE_IMPORT_BY_NAME für ExitProcess = 2 (Hint) + len + 1
    // IMAGE_THUNK_DATA64 für INT und IAT (jeweils 1 Eintrag für ExitProcess) = 2 * 8 Bytes
    // IMAGE_IMPORT_DESCRIPTOR für kernel32.dll = 20 Bytes
    // + 2x IMAGE_THUNK_DATA64 (Null-Terminatoren für INT/IAT)
    // + 1x IMAGE_IMPORT_DESCRIPTOR (Null-Terminator für IDT)
    idataSize := Length(kernel32DllName) + 1; // kernel32.dll
    idataSize := AlignUp(idataSize, 2); // Strings sind Word-aligned
    exitProcessHintNameRVA := idataSize; // RVA von Hint/Name von ExitProcess
    idataSize := idataSize + SizeOf(Word) + Length(exitProcessFuncName) + 1; // Hint + ExitProcess String
    idataSize := AlignUp(idataSize, SizeOf(UInt64)); // INT/IAT müssen 8-Byte aligned sein
    intRVA := idataSize;
    idataSize := idataSize + SizeOf(IMAGE_THUNK_DATA64); // INT-Eintrag
    idataSize := idataSize + SizeOf(IMAGE_THUNK_DATA64); // INT-Null-Terminator
    iatRVA := idataSize;
    idataSize := idataSize + SizeOf(IMAGE_THUNK_DATA64); // IAT-Eintrag
    idataSize := idataSize + SizeOf(IMAGE_THUNK_DATA64); // IAT-Null-Terminator
    importDescriptorRVA := idataSize;
    idataSize := idataSize + SizeOf(IMAGE_IMPORT_DESCRIPTOR); // Import Descriptor
    idataSize := idataSize + SizeOf(IMAGE_IMPORT_DESCRIPTOR); // IDT-Null-Terminator
    idataSize := AlignUp(idataSize, $1000); // Runden auf Seiten-Größe

    FillChar(ntHeaders, SizeOf(ntHeaders), 0);
    ntHeaders.Signature := IMAGE_NT_SIGNATURE;

    // File Header
    ntHeaders.FileHeader.Machine := IMAGE_FILE_MACHINE_ARM64;
    ntHeaders.FileHeader.NumberOfSections := 3; // .text, .data und .idata
    ntHeaders.FileHeader.TimeDateStamp := 0; // Statischer Zeitstempel
    ntHeaders.FileHeader.PointerToSymbolTable := 0;
    ntHeaders.FileHeader.NumberOfSymbols := 0;
    ntHeaders.FileHeader.SizeOfOptionalHeader := SizeOf(IMAGE_OPTIONAL_HEADER64);
    ntHeaders.FileHeader.Characteristics := IMAGE_FILE_EXECUTABLE_IMAGE or IMAGE_FILE_LARGE_ADDRESS_AWARE;

    // Optional Header
    ntHeaders.OptionalHeader.Magic := IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    ntHeaders.OptionalHeader.MajorLinkerVersion := 6; // Beispielversion
    ntHeaders.OptionalHeader.MinorLinkerVersion := 0;
    ntHeaders.OptionalHeader.SizeOfCode := AlignUp(codeSize, ntHeaders.OptionalHeader.FileAlignment);
    ntHeaders.OptionalHeader.SizeOfInitializedData := AlignUp(dataSize, ntHeaders.OptionalHeader.FileAlignment) + idataSize; // Inklusive .idata
    ntHeaders.OptionalHeader.SizeOfUninitializedData := 0;
    ntHeaders.OptionalHeader.AddressOfEntryPoint := currentVirtualAddress; // Annahme: Entry Point am Anfang der .text Sektion
    ntHeaders.OptionalHeader.BaseOfCode := currentVirtualAddress;
    // BaseOfData gibt es in PE32+ nicht mehr explizit
    ntHeaders.OptionalHeader.ImageBase := $140000000; // Typische Image Base für ARM64 PE
    ntHeaders.OptionalHeader.SectionAlignment := $1000; // 4KB
    ntHeaders.OptionalHeader.FileAlignment := $200; // 512 Bytes
    ntHeaders.OptionalHeader.MajorOperatingSystemVersion := 6;
    ntHeaders.OptionalHeader.MinorOperatingSystemVersion := 0;
    ntHeaders.OptionalHeader.MajorImageVersion := 1;
    ntHeaders.OptionalHeader.MinorImageVersion := 0;
    ntHeaders.OptionalHeader.MajorSubsystemVersion := 6;
    ntHeaders.OptionalHeader.MinorSubsystemVersion := 0;
    ntHeaders.OptionalHeader.Win32VersionValue := 0;

    ntHeaders.OptionalHeader.SizeOfHeaders := AlignUp(SizeOf(IMAGE_DOS_HEADER) + SizeOf(IMAGE_NT_HEADERS64) + (ntHeaders.FileHeader.NumberOfSections * SizeOf(IMAGE_SECTION_HEADER)), ntHeaders.OptionalHeader.FileAlignment);

    ntHeaders.OptionalHeader.Checksum := 0; // Später berechnen
    ntHeaders.OptionalHeader.Subsystem := IMAGE_SUBSYSTEM_WINDOWS_CUI;
    ntHeaders.OptionalHeader.DllCharacteristics := IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE or IMAGE_DLLCHARACTERISTICS_NX_COMPAT or IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE;
    ntHeaders.OptionalHeader.SizeOfStackReserve := $100000;
    ntHeaders.OptionalHeader.SizeOfStackCommit := $1000;
    ntHeaders.OptionalHeader.SizeOfHeapReserve := $100000;
    ntHeaders.OptionalHeader.SizeOfHeapCommit := $1000;
    ntHeaders.OptionalHeader.LoaderFlags := 0;
    ntHeaders.OptionalHeader.NumberOfRvaAndSizes := 16; // Anzahl der Data Directories

    // Data Directories - Import Directory
    ntHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress := ntHeaders.OptionalHeader.ImageBase + importDescriptorRVA; // Später korrigieren
    ntHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size := SizeOf(IMAGE_IMPORT_DESCRIPTOR) * 2; // Ein Descriptor + Null-Terminator

    fileStream.WriteBuffer(ntHeaders, SizeOf(ntHeaders));
    currentFileOffset := currentFileOffset + SizeOf(ntHeaders);

    // .text Section Header
    FillChar(textSectionHeader, SizeOf(textSectionHeader), 0);
    StrPCopy(textSectionHeader.Name, '.text');
    textSectionHeader.VirtualSize := codeSize;
    textSectionHeader.VirtualAddress := currentVirtualAddress;
    textSectionHeader.SizeOfRawData := AlignUp(codeSize, ntHeaders.OptionalHeader.FileAlignment);
    textSectionHeader.PointerToRawData := ntHeaders.OptionalHeader.SizeOfHeaders; // Direkt nach den Headern
    textSectionHeader.Characteristics := IMAGE_SCN_CNT_CODE or IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_MEM_READ;

    fileStream.WriteBuffer(textSectionHeader, SizeOf(textSectionHeader));
    currentFileOffset := currentFileOffset + SizeOf(textSectionHeader);

    // .data Section Header
    FillChar(dataSectionHeader, SizeOf(dataSectionHeader), 0);
    StrPCopy(dataSectionHeader.Name, '.data');
    dataSectionHeader.VirtualSize := dataSize;
    dataSectionHeader.VirtualAddress := AlignUp(textSectionHeader.VirtualAddress + textSectionHeader.VirtualSize, ntHeaders.OptionalHeader.SectionAlignment);
    dataSectionHeader.SizeOfRawData := AlignUp(dataSize, ntHeaders.OptionalHeader.FileAlignment);
    dataSectionHeader.PointerToRawData := textSectionHeader.PointerToRawData + textSectionHeader.SizeOfRawData;
    dataSectionHeader.Characteristics := IMAGE_SCN_CNT_INITIALIZED_DATA or IMAGE_SCN_MEM_READ or IMAGE_SCN_MEM_WRITE;

    fileStream.WriteBuffer(dataSectionHeader, SizeOf(dataSectionHeader));
    currentFileOffset := currentFileOffset + SizeOf(dataSectionHeader);

    // .idata Section Header
    FillChar(idataSectionHeader, SizeOf(idataSectionHeader), 0);
    StrPCopy(idataSectionHeader.Name, '.idata');
    idataSectionHeader.VirtualSize := idataSize; // Virtuelle Größe der Import-Daten
    idataSectionHeader.VirtualAddress := AlignUp(dataSectionHeader.VirtualAddress + dataSectionHeader.VirtualSize, ntHeaders.OptionalHeader.SectionAlignment);
    idataSectionHeader.SizeOfRawData := AlignUp(idataSize, ntHeaders.OptionalHeader.FileAlignment);
    idataSectionHeader.PointerToRawData := dataSectionHeader.PointerToRawData + dataSectionHeader.SizeOfRawData;
    idataSectionHeader.Characteristics := IMAGE_SCN_CNT_INITIALIZED_DATA or IMAGE_SCN_MEM_READ or IMAGE_SCN_MEM_WRITE;

    fileStream.WriteBuffer(idataSectionHeader, SizeOf(idataSectionHeader));
    currentFileOffset := currentFileOffset + SizeOf(idataSectionHeader);

    // Padding bis zum Beginn der ersten Sektion (.text)
    while fileStream.Position < Int64(textSectionHeader.PointerToRawData) do
      fileStream.WriteByte(0);

    // Code schreiben
    if codeSize > 0 then
      fileStream.WriteBuffer(ACodeBuffer.GetBuffer^, codeSize);

    // Padding bis zum Beginn der .data Sektion
    while fileStream.Position < Int64(dataSectionHeader.PointerToRawData) do
      fileStream.WriteByte(0);

    // Daten schreiben
    if dataSize > 0 then
      fileStream.WriteBuffer(ADataBuffer.GetBuffer^, dataSize);

    // Padding bis zum Beginn der .idata Sektion
    while fileStream.Position < Int64(idataSectionHeader.PointerToRawData) do
      fileStream.WriteByte(0);

    // === Import-Daten schreiben ===
    // Zuerst die DLL-Namen und Funktionsnamen-Hints
    // kernel32.dll name
    kernel32DllNameRVA := idataSectionHeader.VirtualAddress + 0; // Start der .idata Sektion
    WriteAnsiString(fileStream, kernel32DllName);
    // padding to Word alignment for next string
    while (fileStream.Position mod 2) <> 0 do fileStream.WriteByte(0);

    // ExitProcess hint/name
    exitProcessHintNameRVA := idataSectionHeader.VirtualAddress + fileStream.Position - idataSectionHeader.PointerToRawData; // RVA innerhalb .idata
    imageImportByName.Hint := 0; // Hint ist optional, hier 0
    fileStream.WriteBuffer(imageImportByName.Hint, SizeOf(imageImportByName.Hint));
    WriteAnsiString(fileStream, exitProcessFuncName);
    // padding to 8-byte alignment for INT/IAT
    while (fileStream.Position mod SizeOf(UInt64)) <> 0 do fileStream.WriteByte(0);

    // Import Name Table (INT)
    intRVA := idataSectionHeader.VirtualAddress + fileStream.Position - idataSectionHeader.PointerToRawData; // RVA innerhalb .idata
    imageThunkData.AddressOfData := exitProcessHintNameRVA; // Zeigt auf Hint/Name von ExitProcess
    fileStream.WriteBuffer(imageThunkData, SizeOf(imageThunkData));
    imageThunkData.AddressOfData := 0; // Null-Terminator
    fileStream.WriteBuffer(imageThunkData, SizeOf(imageThunkData));

    // Import Address Table (IAT) - Zunächst identisch mit INT, wird vom Loader gepatcht
    iatRVA := idataSectionHeader.VirtualAddress + fileStream.Position - idataSectionHeader.PointerToRawData; // RVA innerhalb .idata
    imageThunkData.AddressOfData := exitProcessHintNameRVA; // Zeigt auf Hint/Name von ExitProcess
    fileStream.WriteBuffer(imageThunkData, SizeOf(imageThunkData));
    imageThunkData.AddressOfData := 0; // Null-Terminator
    fileStream.WriteBuffer(imageThunkData, SizeOf(imageThunkData));

    // Import Directory Table (IDT)
    importDescriptorRVA := idataSectionHeader.VirtualAddress + fileStream.Position - idataSectionHeader.PointerToRawData; // RVA innerhalb .idata
    imageImportDescriptor.OriginalFirstThunk := intRVA; // RVA zur INT
    imageImportDescriptor.TimeDateStamp := 0; // Kann 0 sein für ungebundene Imports
    imageImportDescriptor.ForwarderChain := 0;
    imageImportDescriptor.Name := kernel32DllNameRVA; // RVA zum DLL-Namen
    imageImportDescriptor.FirstThunk := iatRVA; // RVA zur IAT
    fileStream.WriteBuffer(imageImportDescriptor, SizeOf(imageImportDescriptor));
    FillChar(imageImportDescriptor, SizeOf(imageImportDescriptor), 0); // Null-Terminator
    fileStream.WriteBuffer(imageImportDescriptor, SizeOf(imageImportDescriptor));

    // Optional Header aktualisieren mit korrekter Import Directory Entry
    ntHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress := importDescriptorRVA;
    ntHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size := SizeOf(IMAGE_IMPORT_DESCRIPTOR) * 2; // Ein Descriptor + Null-Terminator

    // Finales SizeOfImage berechnen
    ntHeaders.OptionalHeader.SizeOfImage := AlignUp(idataSectionHeader.VirtualAddress + idataSectionHeader.VirtualSize, ntHeaders.OptionalHeader.SectionAlignment);

    // Zurückspringen und NT Headers aktualisieren (insbesondere Optional Header)
    fileStream.Position := SizeOf(IMAGE_DOS_HEADER) + 4; // 4 für Signature
    fileStream.WriteBuffer(ntHeaders.FileHeader, SizeOf(IMAGE_FILE_HEADER));
    fileStream.WriteBuffer(ntHeaders.OptionalHeader, SizeOf(IMAGE_OPTIONAL_HEADER64));

    Result := True;
  finally
    fileStream.Free;
  end;
end;

end.


