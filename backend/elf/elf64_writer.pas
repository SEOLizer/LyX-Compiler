{$mode objfpc}{$H+}
unit elf64_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

procedure WriteElf64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
procedure WriteDynamicElf64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string);
procedure WriteDynamicElf64WithPatches(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string; const pltPatches: TPLTGOTPatchArray);

implementation

// Allokiert Platz im Segment mit korrektem Alignment
// Gibt den Offset VOR dem Allokieren zurück (also den Start der Sektion)
function AllocateSpace(var currentOffset: QWord; size: QWord; alignment: QWord): QWord;
begin
  // Alignment anwenden
  currentOffset := (currentOffset + alignment - 1) and not (alignment - 1);
  Result := currentOffset;
  // Dann Platz für die Sektion reservieren
  currentOffset := currentOffset + size;
end;

const
  // ELF Dynamic Tag Types
  DT_NULL = 0;
  DT_NEEDED = 1;
  DT_PLTRELSZ = 2;
  DT_PLTGOT = 3;
  DT_HASH = 4;
  DT_STRTAB = 5;
  DT_SYMTAB = 6;
  DT_RELA = 7;
  DT_RELASZ = 8;
  DT_RELAENT = 9;
  DT_STRSZ = 10;
  DT_SYMENT = 11;
  DT_INIT = 12;
  DT_FINI = 13;
  DT_SONAME = 14;
  DT_RPATH = 15;
  DT_SYMBOLIC = 16;
  DT_REL = 17;
  DT_RELSZ = 18;
  DT_RELENT = 19;
  DT_PLTREL = 20;
  DT_DEBUG = 21;
  DT_TEXTREL = 22;
  DT_JMPREL = 23;
  DT_BIND_NOW = 24;
  DT_INIT_ARRAY = 25;
  DT_FINI_ARRAY = 26;
  DT_INIT_ARRAYSZ = 27;
  DT_FINI_ARRAYSZ = 28;
  DT_RUNPATH = 29;
  DT_FLAGS = 30;
  DT_ENCODING = 32;
  DT_PREINIT_ARRAY = 32;
  DT_PREINIT_ARRAYSZ = 33;
  DT_MAXPOSTAGS = 34;
  DT_LOOS = $6000000D;
  DT_HIOS = $6FFFF000;
  DT_LOPROC = $70000000;
  DT_HIPROC = $7FFFFFFF;
  DT_GNU_HASH = $6FFFFEF5;
  DT_VERNEED = $6FFFFFFE;
  DT_VERNEEDNUM = $6FFFFFFF;
  DT_VERSYM = $6FFFFFF0;
  DT_RELACOUNT = $6FFFFFF9;
  DT_RELCOUNT = $6FFFFFFA;
  
  // Relocation Types
  R_X86_64_NONE = 0;
  R_X86_64_64 = 1;
  R_X86_64_PC32 = 2;
  R_X86_64_GOT32 = 3;
  R_X86_64_PLT32 = 4;
  R_X86_64_COPY = 5;
  R_X86_64_GLOB_DAT = 6;
  R_X86_64_JUMP_SLOT = 7;
  R_X86_64_RELATIVE = 8;
  R_X86_64_GOTPCREL = 9;
  R_X86_64_32 = 10;
  R_X86_64_32S = 11;
  R_X86_64_16 = 12;
  R_X86_64_PC16 = 13;
  R_X86_64_8 = 14;
  R_X86_64_PC8 = 15;

procedure WriteStringToBuffer(buf: TByteBuffer; const s: string);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    buf.WriteU8(Ord(s[i]));
end;

function AlignUp(v, a: UInt64): UInt64;
begin
  if a = 0 then Result := v else Result := (v + a - 1) and not (a - 1);
end;

// ELF structures
type
  TElf64Header = packed record
    e_ident: array[0..15] of Byte;
    e_type: Word;
    e_machine: Word;
    e_version: DWord;
    e_entry: UInt64;
    e_phoff: UInt64;
    e_shoff: UInt64;
    e_flags: DWord;
    e_ehsize: Word;
    e_phentsize: Word;
    e_phnum: Word;
    e_shentsize: Word;
    e_shnum: Word;
    e_shstrndx: Word;
  end;
  
  TElf64Phdr = packed record
    p_type: DWord;
    p_flags: DWord;
    p_offset: UInt64;
    p_vaddr: UInt64;
    p_paddr: UInt64;
    p_filesz: UInt64;
    p_memsz: UInt64;
    p_align: UInt64;
  end;
  
  TElf64Dyn = packed record
    d_tag: UInt64;
    d_un: UInt64;
  end;
  
  TElf64Sym = packed record
    st_name: DWord;
    st_info: Byte;
    st_other: Byte;
    st_shndx: Word;
    st_value: UInt64;
    st_size: UInt64;
  end;
  
  TElf64Rela = packed record
    r_offset: UInt64;
    r_info: UInt64;
    r_addend: Int64;
  end;

procedure WriteElf64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
var
  pageSize: UInt64 = 4096;
  codeOffset: UInt64;
  codeSize: UInt64;
  dataOffset: UInt64;
  dataSize: UInt64;
  fileBuf: TFileStream;
  elfHeader: TByteBuffer;
  phdr: TByteBuffer;
  filesz, memsz: UInt64;
  baseVA: UInt64;
begin
  // For static ELF, use 0x400000 as base
  baseVA := $400000;

  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;

  codeOffset := pageSize; // 0x1000
  dataOffset := codeOffset + AlignUp(codeSize, pageSize);

  // build ELF header
  elfHeader := TByteBuffer.Create;
  phdr := TByteBuffer.Create;
  try
    // e_ident
    elfHeader.WriteBytes([$7F, Ord('E'), Ord('L'), Ord('F')]);
    elfHeader.WriteU8(2); // EI_CLASS_64
    elfHeader.WriteU8(1); // EI_DATA_LE
    elfHeader.WriteU8(1); // EV_CURRENT
    elfHeader.WriteU8(0); // OSABI
    elfHeader.WriteU8(0); // ABI version
    elfHeader.WriteBytesFill(7, 0);

    // type, machine, version
    elfHeader.WriteU16LE(2); // ET_EXEC
    elfHeader.WriteU16LE(62); // EM_X86_64
    elfHeader.WriteU32LE(1);

    // entry, phoff, shoff
    elfHeader.WriteU64LE(entryVA);
    elfHeader.WriteU64LE(64);
    elfHeader.WriteU64LE(0);

    // flags, ehsize, phentsize, phnum, shentsize, shnum, shstrndx
    elfHeader.WriteU32LE(0);
    elfHeader.WriteU16LE(64);
    elfHeader.WriteU16LE(56);
    elfHeader.WriteU16LE(1);
    elfHeader.WriteU16LE(0);
    elfHeader.WriteU16LE(0);
    elfHeader.WriteU16LE(0);

    // program header
    phdr.WriteU32LE(1); // PT_LOAD
    phdr.WriteU32LE(4 or 2 or 1); // PF_R|PF_W|PF_X
    phdr.WriteU64LE(codeOffset);
    phdr.WriteU64LE(baseVA + codeOffset);
    phdr.WriteU64LE(baseVA + codeOffset);

    filesz := AlignUp(codeSize, pageSize) + dataSize;
    memsz := AlignUp(codeSize + dataSize, pageSize);
    if memsz < filesz then memsz := filesz;

    phdr.WriteU64LE(filesz);
    phdr.WriteU64LE(memsz);
    phdr.WriteU64LE(pageSize);

    // write file
    fileBuf := TFileStream.Create(filename, fmCreate);
    try
      if elfHeader.Size <> 64 then raise Exception.Create('Invalid ELF header size');
      fileBuf.WriteBuffer(elfHeader.GetBuffer^, elfHeader.Size);
      if phdr.Size <> 56 then raise Exception.Create('Invalid PHDR size');
      fileBuf.WriteBuffer(phdr.GetBuffer^, phdr.Size);
      while fileBuf.Position < Int64(codeOffset) do fileBuf.WriteByte(0);
      if codeSize > 0 then fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);
      while fileBuf.Position < Int64(dataOffset) do fileBuf.WriteByte(0);
      if dataSize > 0 then fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);
    finally
      fileBuf.Free;
    end;
  finally
    phdr.Free;
    elfHeader.Free;
  end;
end;

// Structure to hold dynamic section info
type
  TDynamicSectionInfo = record
    gotOffset: UInt64;
    relaPltOffset: UInt64;
    relaDynOffset: UInt64;
    dynStrOffset: UInt64;
    dynSymOffset: UInt64;
    dynamicOffset: UInt64;
    pltOffset: UInt64;  // Virtual address where PLT stubs are located
    gotVA: UInt64;
    relaPltVA: UInt64;
    relaDynVA: UInt64;
    dynStrVA: UInt64;
    dynSymVA: UInt64;
    dynamicVA: UInt64;
    pltVA: UInt64;
    gotSize: UInt64;
    relaPltSize: UInt64;
    relaDynSize: UInt64;
    dynStrSize: UInt64;
    dynSymSize: UInt64;
    dynamicSize: UInt64;
  end;

// Build string table and return string offsets
procedure BuildStringTable(const libNames, symNames: TStringList; out strTable: TByteBuffer; out strOffsets: TStringList);
var
  i: Integer;
  currentOffset: Integer;
begin
  strTable := TByteBuffer.Create;
  strOffsets := TStringList.Create;
  
  // First entry is empty string at offset 0
  strTable.WriteU8(0);
  currentOffset := 1;
  
  // Add library names
  for i := 0 to libNames.Count - 1 do
  begin
    strOffsets.AddObject(libNames[i], TObject(PtrUInt(currentOffset)));
    WriteStringToBuffer(strTable, libNames[i]);
    strTable.WriteU8(0);
    currentOffset := strTable.Size;
  end;
  
  // Add symbol names
  for i := 0 to symNames.Count - 1 do
  begin
    strOffsets.AddObject(symNames[i], TObject(PtrUInt(currentOffset)));
    WriteStringToBuffer(strTable, symNames[i]);
    strTable.WriteU8(0);
    currentOffset := strTable.Size;
  end;
end;

function GetStringOffset(const strOffsets: TStringList; const s: string): Integer;
var
  idx: Integer;
begin
  idx := strOffsets.IndexOf(s);
  if idx >= 0 then
    Result := PtrInt(strOffsets.Objects[idx])
  else
    Result := 0;
end;

procedure WriteDynamicElf64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string);
begin
  // Call the version with patches but pass empty array
  WriteDynamicElf64WithPatches(filename, codeBuf, dataBuf, entryVA, externSymbols, neededLibs, nil);
end;

procedure WriteDynamicElf64WithPatches(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string; const pltPatches: TPLTGOTPatchArray);
const
  pageSize: UInt64 = 4096;
  baseVA: UInt64 = 0;  // PIE: base address is 0, loader will relocate
  interpPath: string = '/lib64/ld-linux-x86-64.so.2';
var
  // Layout offsets
  codeOffset, dataOffset: UInt64;
  codeSize, dataSize, interpSize: UInt64;
  
  // ELF structures
  fileBuf: TFileStream;
  elfHeader: TElf64Header;
  interpPhdr, loadPhdr, dynamicPhdr: TElf64Phdr;
  dataLoadPhdr: TElf64Phdr;
  
  // Dynamic sections
  dynStrTable: TByteBuffer;
  dynSymTable: TByteBuffer;
  gotTable: TByteBuffer;
  relaPltTable: TByteBuffer;
  relaDynTable: TByteBuffer;
  dynamicTable: TByteBuffer;
  strOffsets: TStringList;
  
  // Symbol and library lists
  libNames, symNames: TStringList;
  i, symCount: Integer;
  
  // Calculated offsets
  dynInfo: TDynamicSectionInfo;
  currentOffset: UInt64;
  strTabSize: UInt64;
  sym: TElf64Sym;
  rela: TElf64Rela;
  dyn: TElf64Dyn;
  
  // File positions
  interpOffset: UInt64;
  headersSize: UInt64;
  
  // PLT patching
  gotEntryVA: UInt64;
  pltStubVA: UInt64;
  nextInstrVA: UInt64;
  ripOffset: Int64;
  gotBufOffset: Integer;
  plt0VA: UInt64;
  pushOffset: Int64;
  jmpOffset: Int64;
  plt0StartInBuffer: Integer;

  // Local helper to dump first bytes of a TByteBuffer for debugging
  procedure DumpBuf(const name: string; buf: TByteBuffer);
  var
    i, lim: Integer;
    p: PByte;
  begin
    if buf = nil then
    begin
      WriteLn('DBG ', name, ': <nil>');
      Exit;
    end;
    WriteLn('DBG ', name, ' size=', buf.Size);
    if buf.Size = 0 then Exit;
    p := buf.GetBuffer;
    lim := buf.Size;
    if lim > 64 then lim := 64;
    for i := 0 to lim - 1 do
      Write(IntToHex(p[i], 2), ' ');
    if buf.Size > lim then
      Write('...');
    WriteLn;
  end;

begin

  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;
  interpSize := Length(interpPath) + 1;
  
  // Collect unique library names and symbols
  libNames := TStringList.Create;
  libNames.Duplicates := dupIgnore;
  libNames.Sorted := True;
  
  symNames := TStringList.Create;
  
  try
    for i := 0 to High(neededLibs) do
      libNames.Add(neededLibs[i]);
    
    for i := 0 to High(externSymbols) do
    begin
      libNames.Add(externSymbols[i].LibraryName);
      symNames.Add(externSymbols[i].Name);
    end;

    symCount := symNames.Count;
    
    // Build string table
    BuildStringTable(libNames, symNames, dynStrTable, strOffsets);
    strTabSize := dynStrTable.Size;
    
    // Calculate layout
    // Headers: ELF header (64) + 4 PHDRs (4*56) = 64 + 224 = 288
    // Align to 8 bytes: 288 is already aligned
    headersSize := 64 + 4 * 56;
    interpOffset := headersSize;
    
    // Code section starts after interp path, page aligned
    codeOffset := AlignUp(interpOffset + interpSize, pageSize);

    // Data section (holds dataBuf and dynamic metadata) starts after code, page aligned
    dataOffset := codeOffset + AlignUp(codeSize, pageSize);

    // Build dynamic sections buffers (in-memory) before writing
    dynSymTable := TByteBuffer.Create;
    gotTable := TByteBuffer.Create;
    relaPltTable := TByteBuffer.Create;
    dynamicTable := TByteBuffer.Create;

    try
      // Build .dynsym

      // First symbol: UNDEFINED
      FillChar(sym, SizeOf(sym), 0);
      dynSymTable.WriteBuffer(sym, SizeOf(sym));
      
      // External symbols
      for i := 0 to symCount - 1 do
      begin
        sym.st_name := GetStringOffset(strOffsets, symNames[i]);
        sym.st_info := $12; // STB_GLOBAL | STT_FUNC
        sym.st_other := 0;
        sym.st_shndx := 0; // SHN_UNDEF
        sym.st_value := 0;
        sym.st_size := 0;
        // Write individual fields to ensure correct byte order
        dynSymTable.WriteU32LE(sym.st_name);
        dynSymTable.WriteU8(sym.st_info);
        dynSymTable.WriteU8(sym.st_other);
        dynSymTable.WriteU16LE(sym.st_shndx);
        dynSymTable.WriteU64LE(sym.st_value);
        dynSymTable.WriteU64LE(sym.st_size);
      end;
      
      // Build .got.plt
      // GOT[0] = _DYNAMIC address
      // GOT[1] = link_map pointer
      // GOT[2] = _dl_runtime_resolve address
      // GOT[3..] = function pointers (filled by dynamic linker)
      gotTable.WriteU64LE(0); // _DYNAMIC - filled by linker
      gotTable.WriteU64LE(0); // link_map - filled by linker
      gotTable.WriteU64LE(0); // _dl_runtime_resolve - filled by linker
      
      for i := 0 to symCount - 1 do
        gotTable.WriteU64LE(0); // Function entries
      
      // Build .rela.plt - fill with actual GOT offsets now that we know gotVA will be at this offset
      // We'll recalculate these after layout, but initialize first
      for i := 0 to symCount - 1 do
      begin
        rela.r_offset := 0; // Will be filled with GOT entry VA
        rela.r_info := ((UInt64(i) + 1) shl 32) or R_X86_64_JUMP_SLOT;
        rela.r_addend := 0;
        // Write individual fields to ensure correct byte order
        relaPltTable.WriteU64LE(rela.r_offset);
        relaPltTable.WriteU64LE(rela.r_info);
        relaPltTable.WriteU64LE(rela.r_addend);
      end;
      
      // Build .rela.dyn with R_X86_64_RELATIVE (we know the structure)
      // r_offset: GOT[0] address (relative to baseVA)
      // r_addend: address of _DYNAMIC (will be set after we know dynamicVA)
      relaDynTable := TByteBuffer.Create;
      
      // === PHASE 1: Calculate all offsets based on table sizes ===
      
      // Data section (user data) comes first
      dataOffset := codeOffset + AlignUp(codeSize, pageSize);
      
      // All dynamic sections come after user data, 8-byte aligned
      currentOffset := dataOffset + AlignUp(dataSize, 8);
      
      // Layout: GOT -> RELA.PLT -> RELA.DYN -> DYNSZSTR -> DYNSYM -> DYNAMIC
      // Each section is 8-byte aligned
      
      // Debug: show currentOffset before allocations
      // Write to stderr to ensure it's flushed immediately
      System.WriteLn('DEBUG: currentOffset before GOT: ', currentOffset);
      System.Flush(StdOut);
      
      // GOT section - use AllocateSpace for consistency
      dynInfo.gotOffset := AllocateSpace(currentOffset, gotTable.Size, 8);
      System.WriteLn('DEBUG: after GOT: offset=', dynInfo.gotOffset, ' currentOffset=', currentOffset);
      System.Flush(StdOut);
      dynInfo.gotVA := baseVA + dynInfo.gotOffset;
      
      // RELA.PLT section - use AllocateSpace
      dynInfo.relaPltOffset := AllocateSpace(currentOffset, symCount * 24, 8);
      System.WriteLn('DEBUG: after RELA.PLT: offset=', dynInfo.relaPltOffset, ' currentOffset=', currentOffset);
      System.Flush(StdOut);
      dynInfo.relaPltVA := baseVA + dynInfo.relaPltOffset;
      
      // RELA.DYN section (1 entry for R_X86_64_RELATIVE = 24 bytes) - use AllocateSpace
      dynInfo.relaDynOffset := AllocateSpace(currentOffset, 24, 8); // sizeof(TElf64Rela)
      System.WriteLn('DEBUG: after RELA.DYN: offset=', dynInfo.relaDynOffset, ' currentOffset=', currentOffset);
      System.Flush(StdOut);
      dynInfo.relaDynVA := baseVA + dynInfo.relaDynOffset;
      
      // DYNSTR section - use AllocateSpace
      dynInfo.dynStrOffset := AllocateSpace(currentOffset, dynStrTable.Size, 8);
      System.WriteLn('DEBUG: after DYNSTR: offset=', dynInfo.dynStrOffset, ' currentOffset=', currentOffset);
      System.Flush(StdOut);
      dynInfo.dynStrVA := baseVA + dynInfo.dynStrOffset;
      
      // DYNSYM section - use AllocateSpace
      dynInfo.dynSymOffset := AllocateSpace(currentOffset, dynSymTable.Size, 8);
      System.WriteLn('DEBUG: after DYNSYM: offset=', dynInfo.dynSymOffset, ' currentOffset=', currentOffset);
      System.Flush(StdOut);
      dynInfo.dynSymVA := baseVA + dynInfo.dynSymOffset;
      
      // DYNAMIC section - just set offset (size determined after building)
      dynInfo.dynamicOffset := currentOffset;
      dynInfo.dynamicVA := baseVA + dynInfo.dynamicOffset;
      
      // === PHASE 2: Build tables with correct values now that we know offsets ===
      
      // Build .rela.plt with actual GOT entry offsets
      relaPltTable.Clear;
      for i := 0 to symCount - 1 do
      begin
        rela.r_offset := dynInfo.gotVA + 24 + (i * 8); // GOT[3+i] - 3 reserved entries * 8 bytes
        rela.r_info := ((UInt64(i) + 1) shl 32) or R_X86_64_JUMP_SLOT;
        rela.r_addend := 0;
        relaPltTable.WriteBuffer(rela, SizeOf(rela));
      end;
      
      // Build .rela.dyn with R_X86_64_RELATIVE for GOT[0]
      // This tells the dynamic linker to add the load bias to GOT[0]
      rela.r_offset := dynInfo.gotVA; // GOT[0] address
      rela.r_info := R_X86_64_RELATIVE;
      rela.r_addend := dynInfo.dynamicVA; // Absolute address of _DYNAMIC
      relaDynTable.WriteBuffer(rela, SizeOf(rela));
      
      // Build .dynamic section
      // DT_NEEDED entries
      for i := 0 to libNames.Count - 1 do
      begin
        dyn.d_tag := DT_NEEDED;
        // DT_NEEDED uses an offset into .dynstr (relative to DT_STRTAB start)
        dyn.d_un := GetStringOffset(strOffsets, libNames[i]);
        dynamicTable.WriteBuffer(dyn, SizeOf(dyn));
      end;

      // DT_PLTGOT
      dyn.d_tag := DT_PLTGOT;
      dyn.d_un := dynInfo.gotVA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_PLTRELSZ (size of .rela.plt)
      dyn.d_tag := DT_PLTRELSZ;
      dyn.d_un := relaPltTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_PLTREL -> type of PLT relocations (DT_RELA = 7)
      dyn.d_tag := DT_PLTREL;
      dyn.d_un := DT_RELA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_JMPREL -> .rela.plt VA
      dyn.d_tag := DT_JMPREL;
      dyn.d_un := dynInfo.relaPltVA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELA -> .rela.dyn VA
      dyn.d_tag := DT_RELA;
      dyn.d_un := dynInfo.relaDynVA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELASZ -> size of .rela.dyn
      dyn.d_tag := DT_RELASZ;
      dyn.d_un := relaDynTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELAENT
      dyn.d_tag := DT_RELAENT;
      dyn.d_un := SizeOf(TElf64Rela);
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_SYMTAB
      dyn.d_tag := DT_SYMTAB;
      dyn.d_un := dynInfo.dynSymVA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_SYMENT
      dyn.d_tag := DT_SYMENT;
      dyn.d_un := SizeOf(TElf64Sym);
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_STRTAB
      dyn.d_tag := DT_STRTAB;
      dyn.d_un := dynInfo.dynStrVA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_STRSZ
      dyn.d_tag := DT_STRSZ;
      dyn.d_un := dynStrTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

       // DT_BIND_NOW - force eager binding at load time (resolves GOT before run)
       dyn.d_tag := DT_BIND_NOW;
       dyn.d_un := 1;
       dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

       // DT_NULL terminator
       dyn.d_tag := DT_NULL;
       dyn.d_un := 0;
       dynamicTable.WriteBuffer(dyn, SizeOf(dyn));
       
        // Apply PLT patches if provided
        WriteLn('DEBUG: Applying ', Length(pltPatches), ' PLT patches');
        if Length(pltPatches) > 0 then
        begin
          // First, patch PLT0 (the resolver stub)
          // PLT0 is at the start of the code section
          // pushq GOT+8: FF 35 at offset 0, rel32 at offset 2
          // jmpq GOT+16: FF 25 at offset 6, rel32 at offset 8
          plt0VA := baseVA + codeOffset;
          
          // Push offset: (GOT+8) - (PLT0VA + 6)
          // After pushq instruction reads its 4-byte displacement, RIP is at PLT0VA + 6
          pushOffset := Int64(dynInfo.gotVA + 8) - Int64(plt0VA + 6);
          // Jmp offset: (GOT+16) - (PLT0VA + 12)
          // After jmpq instruction reads its 4-byte displacement, RIP is at PLT0VA + 12
          jmpOffset := Int64(dynInfo.gotVA + 16) - Int64(plt0VA + 12);
          
          WriteLn('DEBUG PLT0: plt0VA=', UInt64(plt0VA), 
                  ' gotVA=', UInt64(dynInfo.gotVA),
                  ' pushOffset=', pushOffset, 
                  ' jmpOffset=', jmpOffset,
                  ' codeOffset=', codeOffset);
          
          // PLT0 starts 16 bytes before the first PLT stub (pltStubPos - 16)
          // For PLT1: pltStubPos = 116, so PLT0 starts at 100
          plt0StartInBuffer := pltPatches[0].Pos - 16;
          WriteLn('DEBUG PLT0: pltStubPos[0]=', pltPatches[0].Pos, ' plt0StartInBuffer=', plt0StartInBuffer);
          
          // Patch PLT0 pushq GOT+8 at position plt0StartInBuffer + 2
          codeBuf.PatchU32LE(plt0StartInBuffer + 2, Cardinal(pushOffset));
          // Patch PLT0 jmpq GOT+16 at position plt0StartInBuffer + 8
          codeBuf.PatchU32LE(plt0StartInBuffer + 8, Cardinal(jmpOffset));
          
          // Now patch PLT stubs for each external symbol
         for i := 0 to High(pltPatches) do
          begin
            // Calculate the GOT entry address for this symbol
            // GOT layout: [0]=_DYNAMIC, [1]=link_map, [2]=_dl_runtime_resolve, [3..]=functions
            gotEntryVA := dynInfo.gotVA + 24 + (pltPatches[i].SymbolIndex * 8);

            // Calculate RIP-relative offset from PLT stub to GOT entry
            pltStubVA := baseVA + codeOffset + pltPatches[i].Pos;
            nextInstrVA := pltStubVA + 6; // After FF 25 xx xx xx xx
            ripOffset := Int64(gotEntryVA) - Int64(nextInstrVA);

            WriteLn('DEBUG PLT patch ', i, ': sym=', pltPatches[i].SymbolName, ' symIdx=', pltPatches[i].SymbolIndex,
                    ' gotEntryVA=', UInt64(gotEntryVA), 
                    ' pltStubPos=', pltPatches[i].Pos, 
                    ' pltStubVA=', UInt64(pltStubVA),
                    ' nextInstrVA=', UInt64(nextInstrVA),
                    ' ripOffset=', ripOffset);

            // Patch jmp [rip+disp32] to GOT entry - use buffer index directly
            codeBuf.PatchU32LE(pltPatches[i].Pos + 2, Cardinal(ripOffset));
            
            // Patch the jmp PLT0 at offset +12 within the PLT stub
            // PLTn starts at pltStubPos, jmp opcode at +6, rel32 at +12
            // rel32 = plt0VA - (pltStubVA + 11 + 5) = plt0VA - pltStubVA - 16
            pltStubVA := baseVA + codeOffset + pltPatches[i].Pos;
            jmpOffset := Int64(plt0VA) - Int64(pltStubVA + 16);
            WriteLn('DEBUG jmp PLT0: pltStubVA=', UInt64(pltStubVA), ' plt0VA=', UInt64(plt0VA), 
                    ' jmpOffset=', jmpOffset, ' bufPos=', pltPatches[i].Pos + 12);
            codeBuf.PatchU32LE(pltPatches[i].Pos + 12, Cardinal(jmpOffset));
          end;

          // Initialize GOT entries for PLT resolution: set GOT[3 + symIdx]
          // to point to the PLT stub's second instruction (so the first indirect
          // jmp lands inside the PLT which then calls the resolver).
          for i := 0 to High(pltPatches) do
          begin
            pltStubVA := baseVA + codeOffset + pltPatches[i].Pos;
            nextInstrVA := pltStubVA + 6;
            gotBufOffset := (3 + pltPatches[i].SymbolIndex) * 8;
            gotTable.PatchU64LE(gotBufOffset, QWord(nextInstrVA));
            WriteLn('DBG GOT init symIdx=', pltPatches[i].SymbolIndex, ' GOTbufOff=', gotBufOffset, 
                    ' pltStubVA=', UInt64(pltStubVA), ' nextInstrVA=', UInt64(nextInstrVA), ' val=', UInt64(nextInstrVA));
          end;
        end;

       // Build ELF header
       FillChar(elfHeader, SizeOf(elfHeader), 0);

      
      // Build ELF header and initialize all structures
      FillChar(elfHeader, SizeOf(elfHeader), 0);
      FillChar(interpPhdr, SizeOf(interpPhdr), 0);
      FillChar(loadPhdr, SizeOf(loadPhdr), 0);
      FillChar(dataLoadPhdr, SizeOf(dataLoadPhdr), 0);
      FillChar(dynamicPhdr, SizeOf(dynamicPhdr), 0);
      
      elfHeader.e_ident[0] := $7F;
      elfHeader.e_ident[1] := Ord('E');
      elfHeader.e_ident[2] := Ord('L');
      elfHeader.e_ident[3] := Ord('F');
      elfHeader.e_ident[4] := 2; // ELFCLASS64
      elfHeader.e_ident[5] := 1; // ELFDATA2LSB
      elfHeader.e_ident[6] := 1; // EV_CURRENT
      elfHeader.e_type := 3; // ET_DYN (Position-Independent Executable)
      elfHeader.e_machine := 62; // EM_X86_64
      elfHeader.e_version := 1;
      elfHeader.e_entry := entryVA;
      elfHeader.e_phoff := 64;
      elfHeader.e_shoff := 0;
      elfHeader.e_flags := 0;
      elfHeader.e_ehsize := 64;
      elfHeader.e_phentsize := 56;
      elfHeader.e_phnum := 4;
      elfHeader.e_shentsize := 0;
      elfHeader.e_shnum := 0;
      elfHeader.e_shstrndx := 0;
      
      // Build program headers
      // PT_INTERP
      interpPhdr.p_type := 3; // PT_INTERP
      interpPhdr.p_flags := 4; // PF_R
      interpPhdr.p_offset := interpOffset;
      interpPhdr.p_vaddr := baseVA + interpOffset;
      interpPhdr.p_paddr := baseVA + interpOffset;
      interpPhdr.p_filesz := interpSize;
      interpPhdr.p_memsz := interpSize;
      interpPhdr.p_align := 1;
      
      // PT_LOAD for code (RX)
      loadPhdr.p_type := 1; // PT_LOAD
      loadPhdr.p_flags := 5; // PF_R | PF_X
      // Start at offset 0 to include ELF header and program headers
      loadPhdr.p_offset := 0;
      loadPhdr.p_vaddr := baseVA;
      loadPhdr.p_paddr := baseVA;
      // Cover: ELF header (64) + PHDRs (224) + interp string + code
      loadPhdr.p_filesz := codeOffset + AlignUp(codeSize, pageSize);
      loadPhdr.p_memsz := loadPhdr.p_filesz;
      loadPhdr.p_align := pageSize;
      
      // PT_LOAD for data (RW)
      dataLoadPhdr.p_type := 1; // PT_LOAD
      dataLoadPhdr.p_flags := 6; // PF_R | PF_W
      dataLoadPhdr.p_offset := dynInfo.gotOffset;
      dataLoadPhdr.p_vaddr := baseVA + dynInfo.gotOffset;
      dataLoadPhdr.p_paddr := baseVA + dynInfo.gotOffset;
      dataLoadPhdr.p_filesz := (dynInfo.dynamicOffset + dynamicTable.Size) - dynInfo.gotOffset;
      dataLoadPhdr.p_memsz := dataLoadPhdr.p_filesz;
      dataLoadPhdr.p_align := pageSize;
      
      // PT_DYNAMIC
      dynamicPhdr.p_type := 2; // PT_DYNAMIC
      dynamicPhdr.p_flags := 6; // PF_R | PF_W
      dynamicPhdr.p_offset := dynInfo.dynamicOffset;
      dynamicPhdr.p_vaddr := dynInfo.dynamicVA;
      dynamicPhdr.p_paddr := dynInfo.dynamicVA;
      dynamicPhdr.p_filesz := dynamicTable.Size;
      dynamicPhdr.p_memsz := dynamicTable.Size;
      dynamicPhdr.p_align := 8;
      
      // Debug: print computed layout before writing file
      WriteLn('DEBUG ELF LAYOUT:');
      WriteLn('  codeOffset=', codeOffset, ' codeSize=', codeSize);
      WriteLn('  dataOffset=', dataOffset, ' dataSize=', dataSize);
      WriteLn('  gotOffset=', dynInfo.gotOffset, ' gotVA=', UInt64(dynInfo.gotVA));
      WriteLn('  relaPltOffset=', dynInfo.relaPltOffset, ' relaPltVA=', UInt64(dynInfo.relaPltVA), ' relaPltSize=', relaPltTable.Size);
      WriteLn('  relaDynOffset=', dynInfo.relaDynOffset, ' relaDynVA=', UInt64(dynInfo.relaDynVA), ' relaDynSize=', relaDynTable.Size);
      WriteLn('  dynStrOffset=', dynInfo.dynStrOffset, ' dynStrVA=', UInt64(dynInfo.dynStrVA), ' dynStrSize=', dynStrTable.Size);
      WriteLn('  dynSymOffset=', dynInfo.dynSymOffset, ' dynSymVA=', UInt64(dynInfo.dynSymVA), ' dynSymSize=', dynSymTable.Size);
      WriteLn('  dynamicOffset=', dynInfo.dynamicOffset, ' dynamicVA=', UInt64(dynInfo.dynamicVA), ' dynamicSize=', dynamicTable.Size);
      WriteLn('  headersSize=', headersSize);

      DumpBuf('.got.plt', gotTable);
      DumpBuf('.rela.plt', relaPltTable);
      DumpBuf('.rela.dyn', relaDynTable);
      DumpBuf('.dynstr', dynStrTable);
      DumpBuf('.dynsym', dynSymTable);
      DumpBuf('.dynamic', dynamicTable);

      // Debug: print computed layout before writing file
      System.WriteLn('DEBUG ELF LAYOUT (with currentOffset):');
      System.WriteLn('  currentOffset=', currentOffset);
      System.WriteLn('  codeOffset=', codeOffset, ' codeSize=', codeSize);
      WriteLn('  dataOffset=', dataOffset, ' dataSize=', dataSize);
       WriteLn('  gotOffset=', dynInfo.gotOffset, ' gotVA=', UInt64(dynInfo.gotVA));
       WriteLn('  relaPltOffset=', dynInfo.relaPltOffset, ' relaPltVA=', UInt64(dynInfo.relaPltVA), ' relaPltSize=', relaPltTable.Size);
       WriteLn('  relaDynOffset=', dynInfo.relaDynOffset, ' relaDynVA=', UInt64(dynInfo.relaDynVA), ' relaDynSize=', relaDynTable.Size);
       WriteLn('  dynStrOffset=', dynInfo.dynStrOffset, ' dynStrVA=', UInt64(dynInfo.dynStrVA), ' dynStrSize=', dynStrTable.Size);
       WriteLn('  dynSymOffset=', dynInfo.dynSymOffset, ' dynSymVA=', UInt64(dynInfo.dynSymVA), ' dynSymSize=', dynSymTable.Size);
       WriteLn('  dynamicOffset=', dynInfo.dynamicOffset, ' dynamicVA=', UInt64(dynInfo.dynamicVA), ' dynamicSize=', dynamicTable.Size);
       WriteLn('  headersSize=', headersSize);

       // Write ELF file
      fileBuf := TFileStream.Create(filename, fmCreate);
      try
        // Write ELF header
        fileBuf.WriteBuffer(elfHeader, SizeOf(elfHeader));
        
        // Write program headers
        fileBuf.WriteBuffer(interpPhdr, SizeOf(interpPhdr));
        fileBuf.WriteBuffer(loadPhdr, SizeOf(loadPhdr));
        fileBuf.WriteBuffer(dataLoadPhdr, SizeOf(dataLoadPhdr));
        fileBuf.WriteBuffer(dynamicPhdr, SizeOf(dynamicPhdr));
        
        // Write interpreter path
        fileBuf.WriteBuffer(PChar(interpPath)^, Length(interpPath));
        fileBuf.WriteByte(0);
        
        // Pad to code offset
        while fileBuf.Position < Int64(codeOffset) do
          fileBuf.WriteByte(0);
        
        // Write code section
        if codeSize > 0 then
          fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);
        
        // Write data section
        while fileBuf.Position < Int64(dataOffset) do
          fileBuf.WriteByte(0);
        if dataSize > 0 then
          fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);
        
        // Write GOT
        while fileBuf.Position < Int64(dynInfo.gotOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(gotTable.GetBuffer^, gotTable.Size);
        
        // Write .rela.plt
        while fileBuf.Position < Int64(dynInfo.relaPltOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(relaPltTable.GetBuffer^, relaPltTable.Size);

        // Write .rela.dyn
        while fileBuf.Position < Int64(dynInfo.relaDynOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(relaDynTable.GetBuffer^, relaDynTable.Size);

        // Write .dynstr
        while fileBuf.Position < Int64(dynInfo.dynStrOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(dynStrTable.GetBuffer^, dynStrTable.Size);
        
        // Write .dynsym
        while fileBuf.Position < Int64(dynInfo.dynSymOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(dynSymTable.GetBuffer^, dynSymTable.Size);
        
        // Write .dynamic
        while fileBuf.Position < Int64(dynInfo.dynamicOffset) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(dynamicTable.GetBuffer^, dynamicTable.Size);
        
      finally
        fileBuf.Free;
      end;
      
    finally
      dynStrTable.Free;
      dynSymTable.Free;
      gotTable.Free;
      relaPltTable.Free;
      relaDynTable.Free;
      dynamicTable.Free;
      strOffsets.Free;
    end;
  finally
    libNames.Free;
    symNames.Free;
  end;
end;

end.
