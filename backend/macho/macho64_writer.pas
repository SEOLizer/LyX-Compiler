{$mode objfpc}{$H+}
unit macho64_writer;

{ Mach-O 64-Bit Object Writer für macOS x86_64 und arm64

  Erzeugt statische und dynamische ausführbare Dateien im Mach-O Format.

  Referenz: Apple Mach-O File Format Reference
  https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/MachORuntime/
}

interface

uses
  SysUtils, Classes, Math, bytes, backend_types;

type
  { CPU-Typ für Mach-O }
  TMachOCpuType = (
    mctX86_64,   // Intel 64-bit
    mctARM64     // Apple Silicon (arm64)
  );

{ Schreibt eine statische Mach-O 64-Bit Datei }
procedure WriteMachO64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; cpuType: TMachOCpuType = mctX86_64);

{ Schreibt eine statische Mach-O 64-Bit Datei mit Symboltabelle (für Debugging) }
procedure WriteMachO64WithSymbols(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; const symbols: array of string; cpuType: TMachOCpuType = mctX86_64);

{ Schreibt eine dynamische Mach-O 64-Bit Datei mit dyld bind info }
procedure WriteDynamicMachO64(const filename: string;
  const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; cpuType: TMachOCpuType;
  const externSymbols: TExternalSymbolArray;
  const pltPatches: TPLTGOTPatchArray);

{ Normalisiert macOS Bibliotheksnamen zu vollständigen Pfaden }
function NormalizeMacOSLibName(const name: string): string;

implementation

{ ============================================================
  Mach-O Konstanten
  ============================================================ }
const
  // Mach-O Magic Numbers
  MH_MAGIC_64 = $FEEDFACF;  // 64-bit Mach-O (Little-Endian)

  // CPU Types
  CPU_TYPE_X86_64 = $01000007;  // CPU_TYPE_X86 | CPU_ARCH_ABI64
  CPU_TYPE_ARM64  = $0100000C;  // CPU_TYPE_ARM | CPU_ARCH_ABI64

  // CPU Subtypes
  CPU_SUBTYPE_X86_64_ALL = 3;
  CPU_SUBTYPE_ARM64_ALL  = 0;

  // File Types
  MH_EXECUTE = 2;  // Ausführbare Datei

  // Header Flags
  MH_NOUNDEFS     = $00000001;  // Keine undefinierten Symbole
  MH_PIE          = $00200000;  // Position Independent Executable

  // Load Command Types
  LC_SEGMENT_64   = $19;  // 64-bit Segment Load Command
  LC_SYMTAB       = $02;  // Symbol Table Load Command
  LC_DYSYMTAB     = $0B;  // Dynamic Symbol Table Load Command
  LC_MAIN         = $80000028;  // Entry Point Load Command (ersetzt LC_UNIXTHREAD)
  LC_UUID         = $1B;  // UUID Load Command

  LC_LOAD_DYLIB         = $0C;
  LC_DYLD_INFO_ONLY     = $80000022;
  S_NON_LAZY_SYMBOL_POINTERS = $06;

  // Dyld bind opcodes
  BIND_OPCODE_DONE                          = $00;
  BIND_OPCODE_SET_DYLIB_ORDINAL_IMM         = $10;
  BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB        = $20;
  BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM = $40;
  BIND_OPCODE_SET_TYPE_IMM                  = $50;
  BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB   = $70;
  BIND_OPCODE_DO_BIND                       = $90;
  BIND_TYPE_POINTER = 1;
  N_UNDF = $00;
  N_EXT  = $01;

  // Segment/Section Protection Flags
  VM_PROT_NONE    = $00;
  VM_PROT_READ    = $01;
  VM_PROT_WRITE   = $02;
  VM_PROT_EXECUTE = $04;

  // Section Types and Attributes
  S_REGULAR                   = $00;  // Regular Section
  S_ZEROFILL                  = $01;  // Zero-filled on demand
  S_ATTR_PURE_INSTRUCTIONS    = $80000000;  // Contains only machine instructions
  S_ATTR_SOME_INSTRUCTIONS    = $00000400;  // Contains some machine instructions

  // Standard page size for macOS
  PAGE_SIZE = $4000;  // 16KB auf Apple Silicon (arm64), auch für x86_64 kompatibel

{ ============================================================
  Mach-O Strukturen (packed records)
  ============================================================ }
type
  { Mach-O 64-bit Header }
  TMachHeader64 = packed record
    magic: UInt32;       // MH_MAGIC_64
    cputype: Int32;      // CPU Type
    cpusubtype: Int32;   // CPU Subtype
    filetype: UInt32;    // File Type (MH_EXECUTE)
    ncmds: UInt32;       // Number of load commands
    sizeofcmds: UInt32;  // Total size of load commands
    flags: UInt32;       // Flags
    reserved: UInt32;    // Reserved (64-bit only)
  end;

  { Generic Load Command Header }
  TLoadCommand = packed record
    cmd: UInt32;     // Load command type
    cmdsize: UInt32; // Total size of command
  end;

  { LC_SEGMENT_64 Load Command }
  TSegmentCommand64 = packed record
    cmd: UInt32;                  // LC_SEGMENT_64
    cmdsize: UInt32;              // sizeof(TSegmentCommand64) + nsects * sizeof(TSection64)
    segname: array[0..15] of Char; // Segment name (null-padded)
    vmaddr: UInt64;               // Virtual address
    vmsize: UInt64;               // Virtual size
    fileoff: UInt64;              // File offset
    filesize: UInt64;             // File size
    maxprot: Int32;               // Maximum VM protection
    initprot: Int32;              // Initial VM protection
    nsects: UInt32;               // Number of sections
    flags: UInt32;                // Segment flags
  end;

  { Section64 Structure }
  TSection64 = packed record
    sectname: array[0..15] of Char;  // Section name
    segname: array[0..15] of Char;   // Segment name
    addr: UInt64;                    // Virtual address
    size: UInt64;                    // Section size
    offset: UInt32;                  // File offset
    align: UInt32;                   // Alignment (power of 2)
    reloff: UInt32;                  // Relocation entries offset
    nreloc: UInt32;                  // Number of relocation entries
    flags: UInt32;                   // Section type and attributes
    reserved1: UInt32;               // Reserved
    reserved2: UInt32;               // Reserved
    reserved3: UInt32;               // Reserved (64-bit only)
  end;

  { LC_MAIN Load Command (Entry Point) }
  TEntryPointCommand = packed record
    cmd: UInt32;       // LC_MAIN
    cmdsize: UInt32;   // sizeof(TEntryPointCommand) = 24
    entryoff: UInt64;  // File offset of entry point
    stacksize: UInt64; // Initial stack size (0 = default)
  end;

  { LC_UUID Load Command }
  TUUIDCommand = packed record
    cmd: UInt32;               // LC_UUID
    cmdsize: UInt32;           // sizeof(TUUIDCommand) = 24
    uuid: array[0..15] of Byte; // 128-bit UUID
  end;

  { LC_SYMTAB Load Command }
  TSymtabCommand = packed record
    cmd: UInt32;     // LC_SYMTAB
    cmdsize: UInt32; // sizeof(TSymtabCommand) = 24
    symoff: UInt32;  // Symbol table offset
    nsyms: UInt32;   // Number of symbols
    stroff: UInt32;  // String table offset
    strsize: UInt32; // String table size
  end;

  TDylibInfo = packed record
    nameoff:        UInt32;
    timestamp:      UInt32;
    currentVersion: UInt32;
    compatVersion:  UInt32;
  end;
  TDylibCommand = packed record
    cmd:     UInt32;
    cmdsize: UInt32;
    dylib:   TDylibInfo;
  end;
  TDyldInfoCommand = packed record
    cmd:            UInt32;
    cmdsize:        UInt32;
    rebase_off:     UInt32;  rebase_size:    UInt32;
    bind_off:       UInt32;  bind_size:      UInt32;
    weak_bind_off:  UInt32;  weak_bind_size: UInt32;
    lazy_bind_off:  UInt32;  lazy_bind_size: UInt32;
    export_off:     UInt32;  export_size:    UInt32;
  end;
  TDysymtabCommand = packed record
    cmd:            UInt32;  cmdsize:        UInt32;
    ilocalsym:      UInt32;  nlocalsym:      UInt32;
    iextdefsym:     UInt32;  nextdefsym:     UInt32;
    iundefsym:      UInt32;  nundefsym:      UInt32;
    tocoff:         UInt32;  ntoc:           UInt32;
    modtaboff:      UInt32;  nmodtab:        UInt32;
    extrefsymoff:   UInt32;  nextrefsyms:    UInt32;
    indirectsymoff: UInt32;  nindirectsyms:  UInt32;
    extreloff:      UInt32;  nextrel:        UInt32;
    locreloff:      UInt32;  nlocrel:        UInt32;
  end;
  TNList64 = packed record
    n_strx:  UInt32;
    n_type:  Byte;
    n_sect:  Byte;
    n_desc:  UInt16;
    n_value: UInt64;
  end;

{ ============================================================
  Hilfsfunktionen
  ============================================================ }

function AlignUp(v, a: UInt64): UInt64;
begin
  if a = 0 then
    Result := v
  else
    Result := (v + a - 1) and not (a - 1);
end;

procedure SetSegmentName(var seg: TSegmentCommand64; const name: string);
var
  i: Integer;
begin
  FillChar(seg.segname, SizeOf(seg.segname), 0);
  for i := 1 to Min(Length(name), 16) do
    seg.segname[i - 1] := name[i];
end;

procedure SetSectionName(var sect: TSection64; const sectName, segName: string);
var
  i: Integer;
begin
  FillChar(sect.sectname, SizeOf(sect.sectname), 0);
  FillChar(sect.segname, SizeOf(sect.segname), 0);
  for i := 1 to Min(Length(sectName), 16) do
    sect.sectname[i - 1] := sectName[i];
  for i := 1 to Min(Length(segName), 16) do
    sect.segname[i - 1] := segName[i];
end;

procedure GenerateUUID(var uuid: array of Byte);
var
  i: Integer;
begin
  // Einfache UUID-Generierung basierend auf Zeitstempel und Zufallszahlen
  Randomize;
  for i := 0 to 15 do
    uuid[i] := Random(256);
  // Version 4 UUID (random)
  uuid[6] := (uuid[6] and $0F) or $40;
  // Variant 1
  uuid[8] := (uuid[8] and $3F) or $80;
end;

function NormalizeMacOSLibName(const name: string): string;
begin
  if (name = 'libc.so.6') or (name = 'libc') or (name = 'libSystem') or
     (name = 'libSystem.B.dylib') then
    Result := '/usr/lib/libSystem.B.dylib'
  else if (name = 'libm.so.6') or (name = 'libm') then
    Result := '/usr/lib/libm.dylib'
  else if (name = 'libpthread.so.0') or (name = 'libpthread') then
    Result := '/usr/lib/libSystem.B.dylib'
  else if (Length(name) > 0) and (name[1] = '/') then
    Result := name
  else
    Result := '/usr/lib/' + name;
end;

procedure WriteULEB128(buf: TMemoryStream; v: UInt64);
var
  b: Byte;
begin
  repeat
    b := Byte(v and $7F);
    v := v shr 7;
    if v > 0 then b := b or $80;
    buf.WriteByte(b);
  until v = 0;
end;

{ ============================================================
  Haupt-Writer-Prozedur (statisch)
  ============================================================ }

procedure WriteMachO64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; cpuType: TMachOCpuType);
var
  fileBuf: TFileStream;
  header: TMachHeader64;
  segPageZero: TSegmentCommand64;
  segText: TSegmentCommand64;
  sectText: TSection64;
  segData: TSegmentCommand64;
  sectData: TSection64;
  sectBss: TSection64;
  segLinkedit: TSegmentCommand64;
  entryCmd: TEntryPointCommand;
  uuidCmd: TUUIDCommand;

  codeSize, dataSize: UInt64;
  headerSize, loadCmdsSize: UInt64;
  textSegOffset, textSegSize: UInt64;
  dataSegOffset, dataSegSize: UInt64;
  linkeditOffset: UInt64;

  textVMAddr, dataVMAddr, linkeditVMAddr: UInt64;
  numLoadCmds: UInt32;
  padByte: Byte;
begin
  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;

  numLoadCmds := 6;
  loadCmdsSize := SizeOf(TSegmentCommand64) +                       // __PAGEZERO
                  SizeOf(TSegmentCommand64) + SizeOf(TSection64) +  // __TEXT + __text
                  SizeOf(TSegmentCommand64) + 2 * SizeOf(TSection64) + // __DATA + __data + __bss
                  SizeOf(TSegmentCommand64) +                       // __LINKEDIT
                  SizeOf(TEntryPointCommand) +                      // LC_MAIN
                  SizeOf(TUUIDCommand);                             // LC_UUID

  headerSize := SizeOf(TMachHeader64) + loadCmdsSize;

  textVMAddr := PAGE_SIZE;
  textSegOffset := 0;
  textSegSize := AlignUp(headerSize + codeSize, PAGE_SIZE);

  dataVMAddr := textVMAddr + textSegSize;
  dataSegOffset := textSegSize;
  dataSegSize := AlignUp(dataSize, PAGE_SIZE);
  if dataSegSize = 0 then
    dataSegSize := PAGE_SIZE;

  linkeditVMAddr := dataVMAddr + dataSegSize;
  linkeditOffset := dataSegOffset + dataSegSize;

  FillChar(header, SizeOf(header), 0);
  header.magic := MH_MAGIC_64;
  case cpuType of
    mctX86_64: begin
      header.cputype := CPU_TYPE_X86_64;
      header.cpusubtype := CPU_SUBTYPE_X86_64_ALL;
    end;
    mctARM64: begin
      header.cputype := CPU_TYPE_ARM64;
      header.cpusubtype := CPU_SUBTYPE_ARM64_ALL;
    end;
  end;
  header.filetype := MH_EXECUTE;
  header.ncmds := numLoadCmds;
  header.sizeofcmds := loadCmdsSize;
  header.flags := MH_NOUNDEFS or MH_PIE;
  header.reserved := 0;

  FillChar(segPageZero, SizeOf(segPageZero), 0);
  segPageZero.cmd := LC_SEGMENT_64;
  segPageZero.cmdsize := SizeOf(TSegmentCommand64);
  SetSegmentName(segPageZero, '__PAGEZERO');
  segPageZero.vmaddr := 0;
  segPageZero.vmsize := PAGE_SIZE;
  segPageZero.fileoff := 0;
  segPageZero.filesize := 0;
  segPageZero.maxprot := VM_PROT_NONE;
  segPageZero.initprot := VM_PROT_NONE;
  segPageZero.nsects := 0;
  segPageZero.flags := 0;

  FillChar(segText, SizeOf(segText), 0);
  segText.cmd := LC_SEGMENT_64;
  segText.cmdsize := SizeOf(TSegmentCommand64) + SizeOf(TSection64);
  SetSegmentName(segText, '__TEXT');
  segText.vmaddr := textVMAddr;
  segText.vmsize := textSegSize;
  segText.fileoff := textSegOffset;
  segText.filesize := textSegSize;
  segText.maxprot := VM_PROT_READ or VM_PROT_EXECUTE;
  segText.initprot := VM_PROT_READ or VM_PROT_EXECUTE;
  segText.nsects := 1;
  segText.flags := 0;

  FillChar(sectText, SizeOf(sectText), 0);
  SetSectionName(sectText, '__text', '__TEXT');
  sectText.addr := textVMAddr + headerSize;
  sectText.size := codeSize;
  sectText.offset := headerSize;
  sectText.align := 4;
  sectText.reloff := 0;
  sectText.nreloc := 0;
  sectText.flags := S_ATTR_PURE_INSTRUCTIONS or S_ATTR_SOME_INSTRUCTIONS;
  sectText.reserved1 := 0;
  sectText.reserved2 := 0;
  sectText.reserved3 := 0;

  FillChar(segData, SizeOf(segData), 0);
  segData.cmd := LC_SEGMENT_64;
  segData.cmdsize := SizeOf(TSegmentCommand64) + 2 * SizeOf(TSection64);
  SetSegmentName(segData, '__DATA');
  segData.vmaddr := dataVMAddr;
  segData.vmsize := dataSegSize;
  segData.fileoff := dataSegOffset;
  segData.filesize := dataSize;
  segData.maxprot := VM_PROT_READ or VM_PROT_WRITE;
  segData.initprot := VM_PROT_READ or VM_PROT_WRITE;
  segData.nsects := 2;
  segData.flags := 0;

  FillChar(sectData, SizeOf(sectData), 0);
  SetSectionName(sectData, '__data', '__DATA');
  sectData.addr := dataVMAddr;
  sectData.size := dataSize;
  sectData.offset := dataSegOffset;
  sectData.align := 3;
  sectData.reloff := 0;
  sectData.nreloc := 0;
  sectData.flags := S_REGULAR;
  sectData.reserved1 := 0;
  sectData.reserved2 := 0;
  sectData.reserved3 := 0;

  FillChar(sectBss, SizeOf(sectBss), 0);
  SetSectionName(sectBss, '__bss', '__DATA');
  sectBss.addr := dataVMAddr + dataSize;
  sectBss.size := 0;
  sectBss.offset := 0;
  sectBss.align := 3;
  sectBss.reloff := 0;
  sectBss.nreloc := 0;
  sectBss.flags := S_ZEROFILL;
  sectBss.reserved1 := 0;
  sectBss.reserved2 := 0;
  sectBss.reserved3 := 0;

  FillChar(segLinkedit, SizeOf(segLinkedit), 0);
  segLinkedit.cmd := LC_SEGMENT_64;
  segLinkedit.cmdsize := SizeOf(TSegmentCommand64);
  SetSegmentName(segLinkedit, '__LINKEDIT');
  segLinkedit.vmaddr := linkeditVMAddr;
  segLinkedit.vmsize := PAGE_SIZE;
  segLinkedit.fileoff := linkeditOffset;
  segLinkedit.filesize := 0;
  segLinkedit.maxprot := VM_PROT_READ;
  segLinkedit.initprot := VM_PROT_READ;
  segLinkedit.nsects := 0;
  segLinkedit.flags := 0;

  FillChar(entryCmd, SizeOf(entryCmd), 0);
  entryCmd.cmd := LC_MAIN;
  entryCmd.cmdsize := SizeOf(TEntryPointCommand);
  entryCmd.entryoff := headerSize + entryOffset;
  entryCmd.stacksize := 0;

  FillChar(uuidCmd, SizeOf(uuidCmd), 0);
  uuidCmd.cmd := LC_UUID;
  uuidCmd.cmdsize := SizeOf(TUUIDCommand);
  GenerateUUID(uuidCmd.uuid);

  fileBuf := TFileStream.Create(filename, fmCreate);
  try
    fileBuf.WriteBuffer(header, SizeOf(header));
    fileBuf.WriteBuffer(segPageZero, SizeOf(segPageZero));
    fileBuf.WriteBuffer(segText, SizeOf(segText));
    fileBuf.WriteBuffer(sectText, SizeOf(sectText));
    fileBuf.WriteBuffer(segData, SizeOf(segData));
    fileBuf.WriteBuffer(sectData, SizeOf(sectData));
    fileBuf.WriteBuffer(sectBss, SizeOf(sectBss));
    fileBuf.WriteBuffer(segLinkedit, SizeOf(segLinkedit));
    fileBuf.WriteBuffer(entryCmd, SizeOf(entryCmd));
    fileBuf.WriteBuffer(uuidCmd, SizeOf(uuidCmd));

    padByte := 0;
    while fileBuf.Position < Int64(headerSize) do
      fileBuf.WriteBuffer(padByte, 1);

    if codeSize > 0 then
      fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);

    while fileBuf.Position < Int64(dataSegOffset) do
      fileBuf.WriteBuffer(padByte, 1);

    if dataSize > 0 then
      fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);

    while fileBuf.Position < Int64(linkeditOffset) do
      fileBuf.WriteBuffer(padByte, 1);

  finally
    fileBuf.Free;
  end;
end;

procedure WriteMachO64WithSymbols(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; const symbols: array of string; cpuType: TMachOCpuType);
begin
  WriteMachO64(filename, codeBuf, dataBuf, entryOffset, cpuType);
end;

{ ============================================================
  Dynamischer Mach-O Writer mit LC_LOAD_DYLIB + dyld bind info
  ============================================================ }

procedure WriteDynamicMachO64(const filename: string;
  const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; cpuType: TMachOCpuType;
  const externSymbols: TExternalSymbolArray;
  const pltPatches: TPLTGOTPatchArray);
var
  N: Integer;                          // number of external symbols
  numLibs: Integer;
  i, j, k: Integer;

  // Library info
  libNames: array of string;           // unique normalized library names
  libOrdinals: array of Integer;       // 1-based ordinal per symbol

  // Layout variables
  textVMAddr: UInt64;
  headerSize: UInt64;
  loadCmdsSize: UInt64;
  codeSize: UInt64;
  dataSize: UInt64;
  textSegSize: UInt64;
  dataVMAddr: UInt64;
  dataFileOffset: UInt64;
  gotSectionOffset: UInt64;
  gotVMAddr: UInt64;
  dataSegFileSize: UInt64;
  dataSegSize: UInt64;
  linkeditFileOffset: UInt64;
  linkeditVMAddr: UInt64;

  numLoadCmds: UInt32;
  dylibCmdSizes: array of UInt32;

  // LINKEDIT sub-offsets
  bindInfoOffset: UInt64;
  bindInfoSize: UInt64;
  symtabOffset: UInt64;
  strtabOffset: UInt64;
  indirSymtabOffset: UInt64;
  linkeditContentSize: UInt64;
  linkeditVMSize: UInt64;

  // Bind info
  bindBuf: TMemoryStream;
  alignPad: Integer;

  // Symbol table
  nlistEntries: array of TNList64;
  strtab: TMemoryStream;
  strOffsets: array of UInt32;
  strtabSize: UInt32;
  c: AnsiChar;

  // Patched code buffer
  patchedCode: array of Byte;
  ldrPos: Integer;
  gotSlotVA: UInt64;
  stubVA: UInt64;
  wordOff: Int64;
  disp32: Int32;
  patchedWord: DWord;

  // Load command structures
  header: TMachHeader64;
  segPageZero: TSegmentCommand64;
  segText: TSegmentCommand64;
  sectText: TSection64;
  segData: TSegmentCommand64;
  sectData: TSection64;
  sectGot: TSection64;
  segLinkedit: TSegmentCommand64;
  dyldInfoCmd: TDyldInfoCommand;
  symtabCmd: TSymtabCommand;
  dysymtabCmd: TDysymtabCommand;
  entryCmd: TEntryPointCommand;
  uuidCmd: TUUIDCommand;

  dylibCmd: TDylibCommand;
  libNameStr: string;
  libCmdSize: UInt32;

  fileBuf: TFileStream;
  padByte: Byte;
  zeroU32: UInt32;
  indirSym: UInt32;

  found: Boolean;
begin
  N := Length(externSymbols);
  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;
  textVMAddr := PAGE_SIZE;

  // ----------------------------------------------------------------
  // Step 1: Collect unique library names, assign ordinals
  // ----------------------------------------------------------------
  SetLength(libNames, 0);
  SetLength(libOrdinals, N);
  SetLength(dylibCmdSizes, 0);

  for i := 0 to N - 1 do
  begin
    libNameStr := NormalizeMacOSLibName(externSymbols[i].LibraryName);
    found := False;
    for j := 0 to High(libNames) do
      if libNames[j] = libNameStr then
      begin
        libOrdinals[i] := j + 1;
        found := True;
        Break;
      end;
    if not found then
    begin
      SetLength(libNames, Length(libNames) + 1);
      libNames[High(libNames)] := libNameStr;
      libOrdinals[i] := Length(libNames);
    end;
  end;
  numLibs := Length(libNames);

  // ----------------------------------------------------------------
  // Step 2: Compute loadCmdsSize
  // ----------------------------------------------------------------
  SetLength(dylibCmdSizes, numLibs);
  loadCmdsSize :=
    UInt64(SizeOf(TSegmentCommand64)) +                           // PAGEZERO
    UInt64(SizeOf(TSegmentCommand64)) + UInt64(SizeOf(TSection64)) +  // TEXT + __text
    UInt64(SizeOf(TSegmentCommand64)) + 2 * UInt64(SizeOf(TSection64)) + // DATA + __data + __got
    UInt64(SizeOf(TSegmentCommand64)) +                           // LINKEDIT
    48 +                                                           // LC_DYLD_INFO_ONLY
    UInt64(SizeOf(TSymtabCommand)) +                              // LC_SYMTAB
    UInt64(SizeOf(TDysymtabCommand)) +                            // LC_DYSYMTAB
    UInt64(SizeOf(TEntryPointCommand)) +                          // LC_MAIN
    UInt64(SizeOf(TUUIDCommand));                                 // LC_UUID

  for i := 0 to numLibs - 1 do
  begin
    // cmdsize = AlignUp(24 + len(name) + 1, 8)
    dylibCmdSizes[i] := UInt32(AlignUp(24 + UInt64(Length(libNames[i])) + 1, 8));
    loadCmdsSize := loadCmdsSize + dylibCmdSizes[i];
  end;

  numLoadCmds := 9 + UInt32(numLibs);
  headerSize := UInt64(SizeOf(TMachHeader64)) + loadCmdsSize;

  textSegSize := AlignUp(headerSize + codeSize, PAGE_SIZE);
  dataVMAddr := textVMAddr + textSegSize;
  dataFileOffset := textSegSize;

  // GOT goes after user data (aligned to 8)
  gotSectionOffset := AlignUp(dataSize, 8);
  gotVMAddr := dataVMAddr + gotSectionOffset;
  dataSegFileSize := gotSectionOffset + UInt64(N) * 8;
  dataSegSize := AlignUp(dataSegFileSize, PAGE_SIZE);
  linkeditFileOffset := textSegSize + dataSegSize;
  linkeditVMAddr := dataVMAddr + dataSegSize;

  // ----------------------------------------------------------------
  // Step 3: Build bind info
  // ----------------------------------------------------------------
  bindBuf := TMemoryStream.Create;
  try
    for i := 0 to N - 1 do
    begin
      // SET_DYLIB_ORDINAL_IMM (ordinal <= 15)
      if libOrdinals[i] <= 15 then
        bindBuf.WriteByte(BIND_OPCODE_SET_DYLIB_ORDINAL_IMM or Byte(libOrdinals[i]))
      else
      begin
        bindBuf.WriteByte(BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB);
        WriteULEB128(bindBuf, UInt64(libOrdinals[i]));
      end;
      // SET_SYMBOL_TRAILING_FLAGS_IMM
      bindBuf.WriteByte(BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM);
      // write '_' + symbolName + #0
      c := '_';
      bindBuf.WriteBuffer(c, 1);
      for k := 1 to Length(externSymbols[i].Name) do
      begin
        c := AnsiChar(externSymbols[i].Name[k]);
        bindBuf.WriteBuffer(c, 1);
      end;
      c := #0;
      bindBuf.WriteBuffer(c, 1);
      // SET_TYPE_IMM (BIND_TYPE_POINTER = 1 -> $51)
      bindBuf.WriteByte(BIND_OPCODE_SET_TYPE_IMM or BIND_TYPE_POINTER);
      // SET_SEGMENT_AND_OFFSET_ULEB | 2 (segment index 2 = __DATA)
      bindBuf.WriteByte(BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB or 2);
      WriteULEB128(bindBuf, gotSectionOffset + UInt64(i) * 8);
      // DO_BIND
      bindBuf.WriteByte(BIND_OPCODE_DO_BIND);
    end;
    // DONE
    bindBuf.WriteByte(BIND_OPCODE_DONE);
    // Pad to 8-byte alignment
    alignPad := Integer(AlignUp(UInt64(bindBuf.Size), 8)) - bindBuf.Size;
    for i := 1 to alignPad do
      bindBuf.WriteByte(0);
    bindInfoSize := UInt64(bindBuf.Size);

    // ----------------------------------------------------------------
    // Step 4: Build symbol table + string table
    // ----------------------------------------------------------------
    SetLength(nlistEntries, N);
    SetLength(strOffsets, N);
    strtab := TMemoryStream.Create;
    try
      // String table starts with a null byte
      strtab.WriteByte(0);

      for i := 0 to N - 1 do
      begin
        strOffsets[i] := UInt32(strtab.Size);
        c := '_';
        strtab.WriteBuffer(c, 1);
        for k := 1 to Length(externSymbols[i].Name) do
        begin
          c := AnsiChar(externSymbols[i].Name[k]);
          strtab.WriteBuffer(c, 1);
        end;
        c := #0;
        strtab.WriteBuffer(c, 1);
      end;
      // Pad strtab to 4-byte alignment
      alignPad := Integer(AlignUp(UInt64(strtab.Size), 4)) - strtab.Size;
      for i := 1 to alignPad do
        strtab.WriteByte(0);
      strtabSize := UInt32(strtab.Size);

      // Build nlist entries
      for i := 0 to N - 1 do
      begin
        FillChar(nlistEntries[i], SizeOf(TNList64), 0);
        nlistEntries[i].n_strx  := strOffsets[i];
        nlistEntries[i].n_type  := N_EXT or N_UNDF;  // $01
        nlistEntries[i].n_sect  := 0;
        nlistEntries[i].n_desc  := UInt16(libOrdinals[i] shl 8);
        nlistEntries[i].n_value := 0;
      end;

      // ----------------------------------------------------------------
      // Step 5: Compute LINKEDIT sub-offsets
      // ----------------------------------------------------------------
      bindInfoOffset := linkeditFileOffset;
      symtabOffset := bindInfoOffset + bindInfoSize;
      strtabOffset := symtabOffset + UInt64(N) * 16;
      indirSymtabOffset := strtabOffset + strtabSize;
      linkeditContentSize := indirSymtabOffset + UInt64(N) * 4;
      linkeditVMSize := AlignUp(linkeditContentSize - linkeditFileOffset, PAGE_SIZE);

      // ----------------------------------------------------------------
      // Step 6: Patch code buffer copy
      // ----------------------------------------------------------------
      SetLength(patchedCode, codeSize);
      if codeSize > 0 then
        Move(codeBuf.GetBuffer^, patchedCode[0], codeSize);

      for i := 0 to High(pltPatches) do
      begin
        ldrPos := pltPatches[i].Pos;
        gotSlotVA := gotVMAddr + UInt64(pltPatches[i].SymbolIndex) * 8;
        stubVA := textVMAddr + headerSize + UInt64(ldrPos);

        if cpuType = mctARM64 then
        begin
          // ARM64: LDR X17 (literal), imm19 word offset
          wordOff := Int64(gotSlotVA - stubVA) div 4;
          patchedWord := $58000011 or DWord(DWord(wordOff and $7FFFF) shl 5);
          patchedCode[ldrPos]     := Byte(patchedWord and $FF);
          patchedCode[ldrPos + 1] := Byte((patchedWord shr 8) and $FF);
          patchedCode[ldrPos + 2] := Byte((patchedWord shr 16) and $FF);
          patchedCode[ldrPos + 3] := Byte((patchedWord shr 24) and $FF);
        end
        else
        begin
          // x86_64: FF 25 <disp32> — patch disp32 at ldrPos + 2
          disp32 := Int32(gotSlotVA - (stubVA + 6));
          patchedCode[ldrPos + 2] := Byte(Cardinal(disp32) and $FF);
          patchedCode[ldrPos + 3] := Byte((Cardinal(disp32) shr 8) and $FF);
          patchedCode[ldrPos + 4] := Byte((Cardinal(disp32) shr 16) and $FF);
          patchedCode[ldrPos + 5] := Byte((Cardinal(disp32) shr 24) and $FF);
        end;
      end;

      // ----------------------------------------------------------------
      // Step 7: Build load command structures
      // ----------------------------------------------------------------

      // Header
      FillChar(header, SizeOf(header), 0);
      header.magic := MH_MAGIC_64;
      case cpuType of
        mctX86_64: begin
          header.cputype := CPU_TYPE_X86_64;
          header.cpusubtype := CPU_SUBTYPE_X86_64_ALL;
        end;
        mctARM64: begin
          header.cputype := CPU_TYPE_ARM64;
          header.cpusubtype := CPU_SUBTYPE_ARM64_ALL;
        end;
      end;
      header.filetype := MH_EXECUTE;
      header.ncmds := numLoadCmds;
      header.sizeofcmds := UInt32(loadCmdsSize);
      header.flags := MH_PIE;  // NOT MH_NOUNDEFS — we have undefined external symbols
      header.reserved := 0;

      // PAGEZERO
      FillChar(segPageZero, SizeOf(segPageZero), 0);
      segPageZero.cmd := LC_SEGMENT_64;
      segPageZero.cmdsize := SizeOf(TSegmentCommand64);
      SetSegmentName(segPageZero, '__PAGEZERO');
      segPageZero.vmaddr := 0;
      segPageZero.vmsize := PAGE_SIZE;
      segPageZero.fileoff := 0;
      segPageZero.filesize := 0;
      segPageZero.maxprot := VM_PROT_NONE;
      segPageZero.initprot := VM_PROT_NONE;
      segPageZero.nsects := 0;
      segPageZero.flags := 0;

      // TEXT segment
      FillChar(segText, SizeOf(segText), 0);
      segText.cmd := LC_SEGMENT_64;
      segText.cmdsize := UInt32(SizeOf(TSegmentCommand64) + SizeOf(TSection64));
      SetSegmentName(segText, '__TEXT');
      segText.vmaddr := textVMAddr;
      segText.vmsize := textSegSize;
      segText.fileoff := 0;
      segText.filesize := textSegSize;
      segText.maxprot := VM_PROT_READ or VM_PROT_EXECUTE;
      segText.initprot := VM_PROT_READ or VM_PROT_EXECUTE;
      segText.nsects := 1;
      segText.flags := 0;

      // __text section
      FillChar(sectText, SizeOf(sectText), 0);
      SetSectionName(sectText, '__text', '__TEXT');
      sectText.addr := textVMAddr + headerSize;
      sectText.size := codeSize;
      sectText.offset := UInt32(headerSize);
      sectText.align := 4;
      sectText.reloff := 0;
      sectText.nreloc := 0;
      sectText.flags := S_ATTR_PURE_INSTRUCTIONS or S_ATTR_SOME_INSTRUCTIONS;
      sectText.reserved1 := 0;
      sectText.reserved2 := 0;
      sectText.reserved3 := 0;

      // DATA segment
      FillChar(segData, SizeOf(segData), 0);
      segData.cmd := LC_SEGMENT_64;
      segData.cmdsize := UInt32(SizeOf(TSegmentCommand64) + 2 * SizeOf(TSection64));
      SetSegmentName(segData, '__DATA');
      segData.vmaddr := dataVMAddr;
      segData.vmsize := dataSegSize;
      segData.fileoff := dataFileOffset;
      segData.filesize := dataSegFileSize;
      segData.maxprot := VM_PROT_READ or VM_PROT_WRITE;
      segData.initprot := VM_PROT_READ or VM_PROT_WRITE;
      segData.nsects := 2;
      segData.flags := 0;

      // __data section
      FillChar(sectData, SizeOf(sectData), 0);
      SetSectionName(sectData, '__data', '__DATA');
      sectData.addr := dataVMAddr;
      sectData.size := dataSize;
      sectData.offset := UInt32(dataFileOffset);
      sectData.align := 3;
      sectData.reloff := 0;
      sectData.nreloc := 0;
      sectData.flags := S_REGULAR;
      sectData.reserved1 := 0;
      sectData.reserved2 := 0;
      sectData.reserved3 := 0;

      // __got section
      FillChar(sectGot, SizeOf(sectGot), 0);
      SetSectionName(sectGot, '__got', '__DATA');
      sectGot.addr := gotVMAddr;
      sectGot.size := UInt64(N) * 8;
      sectGot.offset := UInt32(dataFileOffset + gotSectionOffset);
      sectGot.align := 3;
      sectGot.reloff := 0;
      sectGot.nreloc := 0;
      sectGot.flags := S_NON_LAZY_SYMBOL_POINTERS;
      sectGot.reserved1 := 0;  // indirect symbol table index 0
      sectGot.reserved2 := 0;
      sectGot.reserved3 := 0;

      // LINKEDIT segment
      FillChar(segLinkedit, SizeOf(segLinkedit), 0);
      segLinkedit.cmd := LC_SEGMENT_64;
      segLinkedit.cmdsize := SizeOf(TSegmentCommand64);
      SetSegmentName(segLinkedit, '__LINKEDIT');
      segLinkedit.vmaddr := linkeditVMAddr;
      segLinkedit.vmsize := linkeditVMSize;
      segLinkedit.fileoff := linkeditFileOffset;
      segLinkedit.filesize := linkeditContentSize - linkeditFileOffset;
      segLinkedit.maxprot := VM_PROT_READ;
      segLinkedit.initprot := VM_PROT_READ;
      segLinkedit.nsects := 0;
      segLinkedit.flags := 0;

      // LC_DYLD_INFO_ONLY
      FillChar(dyldInfoCmd, SizeOf(dyldInfoCmd), 0);
      dyldInfoCmd.cmd := LC_DYLD_INFO_ONLY;
      dyldInfoCmd.cmdsize := 48;
      dyldInfoCmd.rebase_off := 0;    dyldInfoCmd.rebase_size := 0;
      dyldInfoCmd.bind_off := UInt32(bindInfoOffset);
      dyldInfoCmd.bind_size := UInt32(bindInfoSize);
      dyldInfoCmd.weak_bind_off := 0; dyldInfoCmd.weak_bind_size := 0;
      dyldInfoCmd.lazy_bind_off := 0; dyldInfoCmd.lazy_bind_size := 0;
      dyldInfoCmd.export_off := 0;    dyldInfoCmd.export_size := 0;

      // LC_SYMTAB
      FillChar(symtabCmd, SizeOf(symtabCmd), 0);
      symtabCmd.cmd := LC_SYMTAB;
      symtabCmd.cmdsize := SizeOf(TSymtabCommand);
      symtabCmd.symoff := UInt32(symtabOffset);
      symtabCmd.nsyms := UInt32(N);
      symtabCmd.stroff := UInt32(strtabOffset);
      symtabCmd.strsize := strtabSize;

      // LC_DYSYMTAB
      FillChar(dysymtabCmd, SizeOf(dysymtabCmd), 0);
      dysymtabCmd.cmd := LC_DYSYMTAB;
      dysymtabCmd.cmdsize := SizeOf(TDysymtabCommand);
      dysymtabCmd.ilocalsym := 0;   dysymtabCmd.nlocalsym := 0;
      dysymtabCmd.iextdefsym := 0;  dysymtabCmd.nextdefsym := 0;
      dysymtabCmd.iundefsym := 0;   dysymtabCmd.nundefsym := UInt32(N);
      dysymtabCmd.tocoff := 0;      dysymtabCmd.ntoc := 0;
      dysymtabCmd.modtaboff := 0;   dysymtabCmd.nmodtab := 0;
      dysymtabCmd.extrefsymoff := 0; dysymtabCmd.nextrefsyms := 0;
      dysymtabCmd.indirectsymoff := UInt32(indirSymtabOffset);
      dysymtabCmd.nindirectsyms := UInt32(N);
      dysymtabCmd.extreloff := 0;   dysymtabCmd.nextrel := 0;
      dysymtabCmd.locreloff := 0;   dysymtabCmd.nlocrel := 0;

      // LC_MAIN
      FillChar(entryCmd, SizeOf(entryCmd), 0);
      entryCmd.cmd := LC_MAIN;
      entryCmd.cmdsize := SizeOf(TEntryPointCommand);
      entryCmd.entryoff := headerSize + entryOffset;
      entryCmd.stacksize := 0;

      // LC_UUID
      FillChar(uuidCmd, SizeOf(uuidCmd), 0);
      uuidCmd.cmd := LC_UUID;
      uuidCmd.cmdsize := SizeOf(TUUIDCommand);
      GenerateUUID(uuidCmd.uuid);

      // ----------------------------------------------------------------
      // Write file
      // ----------------------------------------------------------------
      fileBuf := TFileStream.Create(filename, fmCreate);
      try
        padByte := 0;

        // 1. Header
        fileBuf.WriteBuffer(header, SizeOf(header));

        // 2. Load commands
        fileBuf.WriteBuffer(segPageZero, SizeOf(segPageZero));
        fileBuf.WriteBuffer(segText, SizeOf(segText));
        fileBuf.WriteBuffer(sectText, SizeOf(sectText));
        fileBuf.WriteBuffer(segData, SizeOf(segData));
        fileBuf.WriteBuffer(sectData, SizeOf(sectData));
        fileBuf.WriteBuffer(sectGot, SizeOf(sectGot));
        fileBuf.WriteBuffer(segLinkedit, SizeOf(segLinkedit));
        fileBuf.WriteBuffer(dyldInfoCmd, SizeOf(dyldInfoCmd));
        fileBuf.WriteBuffer(symtabCmd, SizeOf(symtabCmd));
        fileBuf.WriteBuffer(dysymtabCmd, SizeOf(dysymtabCmd));

        // LC_LOAD_DYLIB for each library (sorted order — we use insertion order)
        for i := 0 to numLibs - 1 do
        begin
          libCmdSize := dylibCmdSizes[i];
          FillChar(dylibCmd, SizeOf(dylibCmd), 0);
          dylibCmd.cmd := LC_LOAD_DYLIB;
          dylibCmd.cmdsize := libCmdSize;
          dylibCmd.dylib.nameoff := 24;  // name starts right after fixed struct
          dylibCmd.dylib.timestamp := 0;
          dylibCmd.dylib.currentVersion := 0;
          dylibCmd.dylib.compatVersion := 0;
          fileBuf.WriteBuffer(dylibCmd, SizeOf(dylibCmd));
          // Write library name + null + padding
          for k := 1 to Length(libNames[i]) do
          begin
            c := AnsiChar(libNames[i][k]);
            fileBuf.WriteBuffer(c, 1);
          end;
          c := #0;
          fileBuf.WriteBuffer(c, 1);
          // Pad to cmdsize (from current position = SizeOf(TDylibCommand) + len + 1)
          j := SizeOf(TDylibCommand) + Length(libNames[i]) + 1;
          while j < Integer(libCmdSize) do
          begin
            fileBuf.WriteBuffer(padByte, 1);
            Inc(j);
          end;
        end;

        fileBuf.WriteBuffer(entryCmd, SizeOf(entryCmd));
        fileBuf.WriteBuffer(uuidCmd, SizeOf(uuidCmd));

        // 3. Pad to headerSize
        while fileBuf.Position < Int64(headerSize) do
          fileBuf.WriteBuffer(padByte, 1);

        // 4. Write patched code
        if codeSize > 0 then
          fileBuf.WriteBuffer(patchedCode[0], codeSize);

        // 5. Pad to textSegSize
        while fileBuf.Position < Int64(textSegSize) do
          fileBuf.WriteBuffer(padByte, 1);

        // 6. Write data
        if dataSize > 0 then
          fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);

        // 7. Pad to gotSectionOffset within DATA
        while fileBuf.Position < Int64(dataFileOffset + gotSectionOffset) do
          fileBuf.WriteBuffer(padByte, 1);

        // 8. Write N*8 zero bytes (GOT, filled by dyld at load time)
        zeroU32 := 0;
        for i := 0 to N - 1 do
        begin
          fileBuf.WriteBuffer(zeroU32, 4);
          fileBuf.WriteBuffer(zeroU32, 4);
        end;

        // 9. Pad to dataSegSize
        while fileBuf.Position < Int64(dataFileOffset + dataSegSize) do
          fileBuf.WriteBuffer(padByte, 1);

        // 10. Write bind info
        bindBuf.Position := 0;
        fileBuf.CopyFrom(bindBuf, bindBuf.Size);

        // 11. Write symtab (N nlist_64 entries, each 16 bytes)
        for i := 0 to N - 1 do
          fileBuf.WriteBuffer(nlistEntries[i], SizeOf(TNList64));

        // 12. Write string table
        strtab.Position := 0;
        fileBuf.CopyFrom(strtab, strtab.Size);

        // 13. Write indirect symbol table (N UInt32s, value i for entry i)
        for i := 0 to N - 1 do
        begin
          indirSym := UInt32(i);
          fileBuf.WriteBuffer(indirSym, SizeOf(UInt32));
        end;

      finally
        fileBuf.Free;
      end;

    finally
      strtab.Free;
    end;

  finally
    bindBuf.Free;
  end;

end;

end.
