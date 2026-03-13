{$mode objfpc}{$H+}
unit macho64_writer;

{ Mach-O 64-Bit Object Writer für macOS x86_64 und arm64
  
  Erzeugt statische ausführbare Dateien im Mach-O Format.
  Unterstützt zunächst nur statische Binaries (keine dyld-Abhängigkeiten).
  
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

{ ============================================================
  Haupt-Writer-Prozedur
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
  i: Integer;
  padByte: Byte;
begin
  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;
  
  // ================================================================
  // Layout-Berechnung
  // ================================================================
  //
  // Page 0: __PAGEZERO (nicht gemappt, Null-Pointer-Schutz)
  // Page 1+: __TEXT Segment (Header + Load Commands + Code)
  // Nächste Page: __DATA Segment (Daten)
  // Danach: __LINKEDIT (für Symbole, etc. - minimal)
  //
  
  // Header + Load Commands Größe berechnen
  // Load Commands: __PAGEZERO + __TEXT (mit 1 Section) + __DATA (mit 2 Sections) + __LINKEDIT + LC_MAIN + LC_UUID
  numLoadCmds := 6;
  loadCmdsSize := SizeOf(TSegmentCommand64) +                       // __PAGEZERO
                  SizeOf(TSegmentCommand64) + SizeOf(TSection64) +  // __TEXT + __text
                  SizeOf(TSegmentCommand64) + 2 * SizeOf(TSection64) + // __DATA + __data + __bss
                  SizeOf(TSegmentCommand64) +                       // __LINKEDIT
                  SizeOf(TEntryPointCommand) +                      // LC_MAIN
                  SizeOf(TUUIDCommand);                             // LC_UUID
  
  headerSize := SizeOf(TMachHeader64) + loadCmdsSize;
  
  // __PAGEZERO: VM-Adresse 0, VM-Größe = PAGE_SIZE (Null-Pointer-Trap)
  // Typischerweise ist __PAGEZERO auf macOS 4GB für 64-bit, wir nutzen PAGE_SIZE für Kompatibilität
  
  // __TEXT Segment: Beginnt bei PAGE_SIZE (VM-Adresse), enthält Header + Code
  textVMAddr := PAGE_SIZE;
  textSegOffset := 0;  // File offset beginnt bei 0
  textSegSize := AlignUp(headerSize + codeSize, PAGE_SIZE);
  
  // __DATA Segment: Nach __TEXT
  dataVMAddr := textVMAddr + textSegSize;
  dataSegOffset := textSegSize;
  dataSegSize := AlignUp(dataSize, PAGE_SIZE);
  if dataSegSize = 0 then
    dataSegSize := PAGE_SIZE;  // Mindestens eine Page
  
  // __LINKEDIT: Nach __DATA (minimal, für Signatur/Symbole)
  linkeditVMAddr := dataVMAddr + dataSegSize;
  linkeditOffset := dataSegOffset + dataSegSize;
  
  // ================================================================
  // Mach-O Header
  // ================================================================
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
  
  // ================================================================
  // Load Commands
  // ================================================================
  
  // __PAGEZERO Segment (Null-Pointer-Schutz)
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
  
  // __TEXT Segment
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
  
  // __text Section (Code)
  FillChar(sectText, SizeOf(sectText), 0);
  SetSectionName(sectText, '__text', '__TEXT');
  sectText.addr := textVMAddr + headerSize;  // Code beginnt nach Header
  sectText.size := codeSize;
  sectText.offset := headerSize;  // File offset
  sectText.align := 4;  // 16-byte alignment (2^4)
  sectText.reloff := 0;
  sectText.nreloc := 0;
  sectText.flags := S_ATTR_PURE_INSTRUCTIONS or S_ATTR_SOME_INSTRUCTIONS;
  sectText.reserved1 := 0;
  sectText.reserved2 := 0;
  sectText.reserved3 := 0;
  
  // __DATA Segment
  FillChar(segData, SizeOf(segData), 0);
  segData.cmd := LC_SEGMENT_64;
  segData.cmdsize := SizeOf(TSegmentCommand64) + 2 * SizeOf(TSection64);
  SetSegmentName(segData, '__DATA');
  segData.vmaddr := dataVMAddr;
  segData.vmsize := dataSegSize;
  segData.fileoff := dataSegOffset;
  segData.filesize := dataSize;  // Nur tatsächliche Daten in der Datei
  segData.maxprot := VM_PROT_READ or VM_PROT_WRITE;
  segData.initprot := VM_PROT_READ or VM_PROT_WRITE;
  segData.nsects := 2;
  segData.flags := 0;
  
  // __data Section
  FillChar(sectData, SizeOf(sectData), 0);
  SetSectionName(sectData, '__data', '__DATA');
  sectData.addr := dataVMAddr;
  sectData.size := dataSize;
  sectData.offset := dataSegOffset;
  sectData.align := 3;  // 8-byte alignment (2^3)
  sectData.reloff := 0;
  sectData.nreloc := 0;
  sectData.flags := S_REGULAR;
  sectData.reserved1 := 0;
  sectData.reserved2 := 0;
  sectData.reserved3 := 0;
  
  // __bss Section (Zero-Fill, für uninitialisierte Daten)
  FillChar(sectBss, SizeOf(sectBss), 0);
  SetSectionName(sectBss, '__bss', '__DATA');
  sectBss.addr := dataVMAddr + dataSize;
  sectBss.size := 0;  // Keine BSS-Daten für jetzt
  sectBss.offset := 0;  // Kein File-Offset für S_ZEROFILL
  sectBss.align := 3;
  sectBss.reloff := 0;
  sectBss.nreloc := 0;
  sectBss.flags := S_ZEROFILL;
  sectBss.reserved1 := 0;
  sectBss.reserved2 := 0;
  sectBss.reserved3 := 0;
  
  // __LINKEDIT Segment (minimal, für Code Signing etc.)
  FillChar(segLinkedit, SizeOf(segLinkedit), 0);
  segLinkedit.cmd := LC_SEGMENT_64;
  segLinkedit.cmdsize := SizeOf(TSegmentCommand64);
  SetSegmentName(segLinkedit, '__LINKEDIT');
  segLinkedit.vmaddr := linkeditVMAddr;
  segLinkedit.vmsize := PAGE_SIZE;
  segLinkedit.fileoff := linkeditOffset;
  segLinkedit.filesize := 0;  // Leer für jetzt
  segLinkedit.maxprot := VM_PROT_READ;
  segLinkedit.initprot := VM_PROT_READ;
  segLinkedit.nsects := 0;
  segLinkedit.flags := 0;
  
  // LC_MAIN (Entry Point)
  FillChar(entryCmd, SizeOf(entryCmd), 0);
  entryCmd.cmd := LC_MAIN;
  entryCmd.cmdsize := SizeOf(TEntryPointCommand);
  // entryoff ist der Offset vom Beginn von __TEXT zum Entry Point
  entryCmd.entryoff := headerSize + entryOffset;
  entryCmd.stacksize := 0;  // Default Stack-Größe
  
  // LC_UUID
  FillChar(uuidCmd, SizeOf(uuidCmd), 0);
  uuidCmd.cmd := LC_UUID;
  uuidCmd.cmdsize := SizeOf(TUUIDCommand);
  GenerateUUID(uuidCmd.uuid);
  
  // ================================================================
  // Datei schreiben
  // ================================================================
  fileBuf := TFileStream.Create(filename, fmCreate);
  try
    // Header
    fileBuf.WriteBuffer(header, SizeOf(header));
    
    // Load Commands
    fileBuf.WriteBuffer(segPageZero, SizeOf(segPageZero));
    fileBuf.WriteBuffer(segText, SizeOf(segText));
    fileBuf.WriteBuffer(sectText, SizeOf(sectText));
    fileBuf.WriteBuffer(segData, SizeOf(segData));
    fileBuf.WriteBuffer(sectData, SizeOf(sectData));
    fileBuf.WriteBuffer(sectBss, SizeOf(sectBss));
    fileBuf.WriteBuffer(segLinkedit, SizeOf(segLinkedit));
    fileBuf.WriteBuffer(entryCmd, SizeOf(entryCmd));
    fileBuf.WriteBuffer(uuidCmd, SizeOf(uuidCmd));
    
    // Padding bis zum Code-Offset
    padByte := 0;
    while fileBuf.Position < Int64(headerSize) do
      fileBuf.WriteBuffer(padByte, 1);
    
    // Code schreiben
    if codeSize > 0 then
      fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);
    
    // Padding bis zum __DATA Segment
    while fileBuf.Position < Int64(dataSegOffset) do
      fileBuf.WriteBuffer(padByte, 1);
    
    // Daten schreiben
    if dataSize > 0 then
      fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);
    
    // Padding bis zum __LINKEDIT Segment (optional)
    while fileBuf.Position < Int64(linkeditOffset) do
      fileBuf.WriteBuffer(padByte, 1);
      
  finally
    fileBuf.Free;
  end;
end;

procedure WriteMachO64WithSymbols(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryOffset: UInt64; const symbols: array of string; cpuType: TMachOCpuType);
begin
  // Für jetzt: Einfacher Aufruf ohne Symboltabelle
  // TODO: Symboltabelle implementieren für Debug-Support
  WriteMachO64(filename, codeBuf, dataBuf, entryOffset, cpuType);
end;

end.
