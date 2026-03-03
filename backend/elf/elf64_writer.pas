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

function AlignUp(v, a: UInt64): UInt64;
begin
  if a = 0 then Result := v else Result := (v + a - 1) and not (a - 1);
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
  DT_PLTREL = 20;
  DT_DEBUG = 21;
  DT_JMPREL = 23;
  DT_BIND_NOW = 24;
  DT_FLAGS = 30;

  // Relocation Types
  R_X86_64_JUMP_SLOT = 7;
  R_X86_64_RELATIVE = 8;

procedure WriteStringToBuffer(buf: TByteBuffer; const s: string);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    buf.WriteU8(Ord(s[i]));
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

// ============================================================
// Static ELF writer (no dynamic linking)
// ============================================================
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
  baseVA := $400000;

  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;

  codeOffset := pageSize;
  dataOffset := codeOffset + AlignUp(codeSize, pageSize);

  elfHeader := TByteBuffer.Create;
  phdr := TByteBuffer.Create;
  try
    // e_ident
    elfHeader.WriteBytes([$7F, Ord('E'), Ord('L'), Ord('F')]);
    elfHeader.WriteU8(2); // ELFCLASS64
    elfHeader.WriteU8(1); // ELFDATA2LSB
    elfHeader.WriteU8(1); // EV_CURRENT
    elfHeader.WriteU8(0); // OSABI
    elfHeader.WriteU8(0); // ABI version
    elfHeader.WriteBytesFill(7, 0);

    elfHeader.WriteU16LE(2); // ET_EXEC
    elfHeader.WriteU16LE(62); // EM_X86_64
    elfHeader.WriteU32LE(1);

    elfHeader.WriteU64LE(entryVA);
    elfHeader.WriteU64LE(64);
    elfHeader.WriteU64LE(0);

    elfHeader.WriteU32LE(0);
    elfHeader.WriteU16LE(64);
    elfHeader.WriteU16LE(56);
    elfHeader.WriteU16LE(1);
    elfHeader.WriteU16LE(0);
    elfHeader.WriteU16LE(0);
    elfHeader.WriteU16LE(0);

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

    fileBuf := TFileStream.Create(filename, fmCreate);
    try
      fileBuf.WriteBuffer(elfHeader.GetBuffer^, elfHeader.Size);
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

// ============================================================
// Build .dynstr and record offsets
// ============================================================
procedure BuildStringTable(const libNames, symNames: TStringList;
  out strTable: TByteBuffer; out strOffsets: TStringList);
var
  i: Integer;
  currentOffset: Integer;
begin
  strTable := TByteBuffer.Create;
  strOffsets := TStringList.Create;

  // First entry is empty string at offset 0
  strTable.WriteU8(0);
  currentOffset := 1;

  for i := 0 to libNames.Count - 1 do
  begin
    strOffsets.AddObject(libNames[i], TObject(PtrUInt(currentOffset)));
    WriteStringToBuffer(strTable, libNames[i]);
    strTable.WriteU8(0);
    currentOffset := strTable.Size;
  end;

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

// ============================================================
// Build a minimal SysV .hash section for the dynamic linker
// ============================================================
// Layout: nbucket(4) + nchain(4) + bucket[nbucket] + chain[nchain]
// nchain = number of symbols in .dynsym (including NULL symbol at index 0)
// We use nbucket = 1 for simplicity (single chain).
procedure BuildHashTable(symTotal: Integer; out hashBuf: TByteBuffer);
var
  nBucket, nChain: Integer;
  i: Integer;
begin
  hashBuf := TByteBuffer.Create;
  nBucket := 1;
  nChain := symTotal; // includes the NULL symbol at index 0

  hashBuf.WriteU32LE(Cardinal(nBucket));
  hashBuf.WriteU32LE(Cardinal(nChain));

  // bucket[0] = 1 (first real symbol) if we have any, else 0
  if symTotal > 1 then
    hashBuf.WriteU32LE(1)
  else
    hashBuf.WriteU32LE(0);

  // chain[0] = STN_UNDEF (0) — the NULL symbol entry
  hashBuf.WriteU32LE(0);

  // chain[1..nChain-1]: link each symbol to the next, last = 0
  for i := 1 to nChain - 1 do
  begin
    if i < nChain - 1 then
      hashBuf.WriteU32LE(Cardinal(i + 1))
    else
      hashBuf.WriteU32LE(0); // end of chain
  end;
end;

// ============================================================
// Dynamic ELF writer (with PLT/GOT for external symbols)
// ============================================================
procedure WriteDynamicElf64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string);
begin
  WriteDynamicElf64WithPatches(filename, codeBuf, dataBuf, entryVA,
    externSymbols, neededLibs, nil);
end;

procedure WriteDynamicElf64WithPatches(const filename: string;
  const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64;
  const externSymbols: TExternalSymbolArray;
  const neededLibs: array of string;
  const pltPatches: TPLTGOTPatchArray);
const
  pageSize: UInt64 = 4096;
  baseVA: UInt64 = 0;  // PIE: base = 0, loader relocates
  interpPath: string = '/lib64/ld-linux-x86-64.so.2';
  numPhdrs = 5;  // INTERP + LOAD(RX) + LOAD(RW) + DYNAMIC + PHDR
var
  codeSize, dataSize, interpSize: UInt64;
  codeOffset, dataOffset: UInt64;
  headersSize, interpOffset: UInt64;

  // Dynamic section buffers
  dynStrTable, dynSymTable, gotTable: TByteBuffer;
  relaPltTable, relaDynTable, dynamicTable: TByteBuffer;
  hashTable: TByteBuffer;
  strOffsets: TStringList;

  // Lists
  libNames, symNames: TStringList;
  i, symCount, symTotal: Integer;

  // Layout tracking — all offsets are file offsets = virtual addresses (PIE base=0)
  curOff: UInt64;
  gotOff, relaPltOff, relaDynOff: UInt64;
  dynStrOff, dynSymOff, hashOff, dynamicOff: UInt64;
  dataEndOff: UInt64;  // end of entire RW segment

  // ELF structures
  fileBuf: TFileStream;
  elfHdr: TElf64Header;
  phdrInterp, phdrRX, phdrRW, phdrDynamic, phdrPhdr: TElf64Phdr;
  sym: TElf64Sym;
  rela: TElf64Rela;
  dyn: TElf64Dyn;

  // PLT patching
  gotEntryVA, pltStubVA, nextInstrVA, plt0VA: UInt64;
  ripOffset, pushOffset, jmpOffset: Int64;
  gotBufOffset, plt0StartInBuffer: Integer;
begin
  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;
  interpSize := Length(interpPath) + 1;

  // ================================================================
  // Collect library and symbol names
  // ================================================================
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
    symTotal := symCount + 1; // +1 for NULL symbol at index 0

    // ================================================================
    // Build all dynamic-section buffers (content, not yet positioned)
    // ================================================================
    BuildStringTable(libNames, symNames, dynStrTable, strOffsets);

    // .dynsym
    dynSymTable := TByteBuffer.Create;
    FillChar(sym, SizeOf(sym), 0);
    dynSymTable.WriteBuffer(sym, SizeOf(sym)); // NULL symbol
    for i := 0 to symCount - 1 do
    begin
      sym.st_name := GetStringOffset(strOffsets, symNames[i]);
      sym.st_info := $12; // STB_GLOBAL | STT_FUNC
      sym.st_other := 0;
      sym.st_shndx := 0; // SHN_UNDEF
      sym.st_value := 0;
      sym.st_size := 0;
      dynSymTable.WriteU32LE(sym.st_name);
      dynSymTable.WriteU8(sym.st_info);
      dynSymTable.WriteU8(sym.st_other);
      dynSymTable.WriteU16LE(sym.st_shndx);
      dynSymTable.WriteU64LE(sym.st_value);
      dynSymTable.WriteU64LE(sym.st_size);
    end;

    // .got.plt: 3 reserved entries + one per external symbol
    gotTable := TByteBuffer.Create;
    gotTable.WriteU64LE(0); // GOT[0] = _DYNAMIC (patched by R_X86_64_RELATIVE)
    gotTable.WriteU64LE(0); // GOT[1] = link_map (set by ld.so)
    gotTable.WriteU64LE(0); // GOT[2] = _dl_runtime_resolve (set by ld.so)
    for i := 0 to symCount - 1 do
      gotTable.WriteU64LE(0); // GOT[3+i]

    // .rela.plt (placeholder — rebuilt after layout)
    relaPltTable := TByteBuffer.Create;
    // .rela.dyn (placeholder — rebuilt after layout)
    relaDynTable := TByteBuffer.Create;
    // .hash
    BuildHashTable(symTotal, hashTable);
    // .dynamic (placeholder — rebuilt after layout)
    dynamicTable := TByteBuffer.Create;

    try
      // ================================================================
      // PHASE 1: Compute file layout
      // ================================================================
      //
      // Page 0 (0x0000-0x0FFF): ELF header + PHDRs + INTERP string
      //   -> Covered by RX LOAD (from offset 0, covers headers+code)
      // Page 1+ (0x1000-...): .text (code)
      //   -> End of RX LOAD
      // Next page boundary: .data (user data) + GOT + dynamic metadata
      //   -> RW LOAD starts here
      //
      headersSize := 64 + UInt64(numPhdrs) * 56;
      interpOffset := headersSize;

      codeOffset := AlignUp(interpOffset + interpSize, pageSize);
      dataOffset := codeOffset + AlignUp(codeSize, pageSize);

      // Inside the RW segment: user data first, then dynamic structures
      curOff := dataOffset + AlignUp(dataSize, 8);

      // .dynsym (8-byte aligned)
      dynSymOff := AlignUp(curOff, 8);
      curOff := dynSymOff + UInt64(dynSymTable.Size);

      // .dynstr
      dynStrOff := AlignUp(curOff, 1); // no alignment needed
      curOff := dynStrOff + UInt64(dynStrTable.Size);

      // .hash (4-byte aligned)
      hashOff := AlignUp(curOff, 4);
      curOff := hashOff + UInt64(hashTable.Size);

      // .got.plt (8-byte aligned)
      gotOff := AlignUp(curOff, 8);
      curOff := gotOff + UInt64(gotTable.Size);

      // .rela.plt (8-byte aligned)
      relaPltOff := AlignUp(curOff, 8);
      curOff := relaPltOff + UInt64(symCount) * SizeOf(TElf64Rela);

      // .rela.dyn (8-byte aligned, 1 entry)
      relaDynOff := AlignUp(curOff, 8);
      curOff := relaDynOff + SizeOf(TElf64Rela);

      // .dynamic (8-byte aligned) — size computed below
      dynamicOff := AlignUp(curOff, 8);

      // ================================================================
      // PHASE 2: Build tables with final addresses
      // ================================================================

      // Rebuild .rela.plt with correct GOT entry VAs
      relaPltTable.Clear;
      for i := 0 to symCount - 1 do
      begin
        rela.r_offset := baseVA + gotOff + 24 + UInt64(i) * 8; // GOT[3+i]
        rela.r_info := ((UInt64(i) + 1) shl 32) or R_X86_64_JUMP_SLOT;
        rela.r_addend := 0;
        relaPltTable.WriteBuffer(rela, SizeOf(rela));
      end;

      // Rebuild .rela.dyn: R_X86_64_RELATIVE for GOT[0] -> _DYNAMIC
      relaDynTable.Clear;
      rela.r_offset := baseVA + gotOff; // GOT[0]
      rela.r_info := R_X86_64_RELATIVE; // no symbol, just RELATIVE
      rela.r_addend := baseVA + dynamicOff; // absolute address of _DYNAMIC
      relaDynTable.WriteBuffer(rela, SizeOf(rela));

      // Build .dynamic section
      dynamicTable.Clear;

      // DT_NEEDED for each library
      for i := 0 to libNames.Count - 1 do
      begin
        dyn.d_tag := DT_NEEDED;
        dyn.d_un := UInt64(GetStringOffset(strOffsets, libNames[i]));
        dynamicTable.WriteBuffer(dyn, SizeOf(dyn));
      end;

      // DT_HASH
      dyn.d_tag := DT_HASH;
      dyn.d_un := baseVA + hashOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_STRTAB
      dyn.d_tag := DT_STRTAB;
      dyn.d_un := baseVA + dynStrOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_SYMTAB
      dyn.d_tag := DT_SYMTAB;
      dyn.d_un := baseVA + dynSymOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_STRSZ
      dyn.d_tag := DT_STRSZ;
      dyn.d_un := dynStrTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_SYMENT
      dyn.d_tag := DT_SYMENT;
      dyn.d_un := SizeOf(TElf64Sym);
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_PLTGOT
      dyn.d_tag := DT_PLTGOT;
      dyn.d_un := baseVA + gotOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_PLTRELSZ
      dyn.d_tag := DT_PLTRELSZ;
      dyn.d_un := relaPltTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_PLTREL
      dyn.d_tag := DT_PLTREL;
      dyn.d_un := DT_RELA;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_JMPREL
      dyn.d_tag := DT_JMPREL;
      dyn.d_un := baseVA + relaPltOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELA
      dyn.d_tag := DT_RELA;
      dyn.d_un := baseVA + relaDynOff;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELASZ
      dyn.d_tag := DT_RELASZ;
      dyn.d_un := relaDynTable.Size;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_RELAENT
      dyn.d_tag := DT_RELAENT;
      dyn.d_un := SizeOf(TElf64Rela);
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_BIND_NOW — eager symbol resolution
      dyn.d_tag := DT_BIND_NOW;
      dyn.d_un := 1;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_DEBUG — needed for gdb
      dyn.d_tag := DT_DEBUG;
      dyn.d_un := 0;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      // DT_NULL terminator
      dyn.d_tag := DT_NULL;
      dyn.d_un := 0;
      dynamicTable.WriteBuffer(dyn, SizeOf(dyn));

      dataEndOff := dynamicOff + UInt64(dynamicTable.Size);

      // ================================================================
      // PHASE 3: Patch PLT stubs in codeBuf
      // ================================================================
      if Length(pltPatches) > 0 then
      begin
        plt0VA := baseVA + codeOffset;

        // PLT0 displacements: pushq [rip+disp32] / jmpq [rip+disp32]
        pushOffset := Int64(baseVA + gotOff + 8) - Int64(plt0VA + 6);
        jmpOffset := Int64(baseVA + gotOff + 16) - Int64(plt0VA + 12);

        plt0StartInBuffer := pltPatches[0].Pos - 16;
        codeBuf.PatchU32LE(plt0StartInBuffer + 2, Cardinal(pushOffset));
        codeBuf.PatchU32LE(plt0StartInBuffer + 8, Cardinal(jmpOffset));

        // Patch each PLTn stub
        for i := 0 to High(pltPatches) do
        begin
          gotEntryVA := baseVA + gotOff + 24 + UInt64(pltPatches[i].SymbolIndex) * 8;
          pltStubVA := baseVA + codeOffset + UInt64(pltPatches[i].Pos);
          nextInstrVA := pltStubVA + 6; // after jmp [rip+disp32]
          ripOffset := Int64(gotEntryVA) - Int64(nextInstrVA);
          codeBuf.PatchU32LE(pltPatches[i].Pos + 2, Cardinal(ripOffset));

          // Patch jmp-to-PLT0 at offset +12 in the PLTn stub
          jmpOffset := Int64(plt0VA) - Int64(pltStubVA + 16);
          codeBuf.PatchU32LE(pltPatches[i].Pos + 12, Cardinal(jmpOffset));
        end;

        // Initialize GOT[3+symIdx] to PLT0 (first instruction) for lazy binding
        // When the external function is called for the first time, the dynamic linker
        // will be invoked via PLT0 to resolve the symbol
        for i := 0 to High(pltPatches) do
        begin
          // Point GOT entry to PLT0, not to PLTn+6
          // PLT0 is at codeOffset (relative to baseVA)
          pltStubVA := baseVA + codeOffset;  // PLT0 address
          gotBufOffset := (3 + pltPatches[i].SymbolIndex) * 8;
          gotTable.PatchU64LE(gotBufOffset, QWord(pltStubVA));
        end;
      end;

      // ================================================================
      // PHASE 4: Build ELF header and program headers
      // ================================================================
      FillChar(elfHdr, SizeOf(elfHdr), 0);
      FillChar(phdrInterp, SizeOf(phdrInterp), 0);
      FillChar(phdrRX, SizeOf(phdrRX), 0);
      FillChar(phdrRW, SizeOf(phdrRW), 0);
      FillChar(phdrDynamic, SizeOf(phdrDynamic), 0);
      FillChar(phdrPhdr, SizeOf(phdrPhdr), 0);

      // ELF Header
      elfHdr.e_ident[0] := $7F;
      elfHdr.e_ident[1] := Ord('E');
      elfHdr.e_ident[2] := Ord('L');
      elfHdr.e_ident[3] := Ord('F');
      elfHdr.e_ident[4] := 2; // ELFCLASS64
      elfHdr.e_ident[5] := 1; // ELFDATA2LSB
      elfHdr.e_ident[6] := 1; // EV_CURRENT
      elfHdr.e_ident[7] := 0; // ELFOSABI_NONE
      elfHdr.e_type := 3; // ET_DYN (PIE)
      elfHdr.e_machine := 62; // EM_X86_64
      elfHdr.e_version := 1;
      elfHdr.e_entry := entryVA;
      elfHdr.e_phoff := 64;
      elfHdr.e_shoff := 0;
      elfHdr.e_flags := 0;
      elfHdr.e_ehsize := 64;
      elfHdr.e_phentsize := 56;
      elfHdr.e_phnum := numPhdrs;
      elfHdr.e_shentsize := 0;
      elfHdr.e_shnum := 0;
      elfHdr.e_shstrndx := 0;

      // PT_PHDR — describes the program header table itself
      phdrPhdr.p_type := 6; // PT_PHDR
      phdrPhdr.p_flags := 4; // PF_R
      phdrPhdr.p_offset := 64;
      phdrPhdr.p_vaddr := baseVA + 64;
      phdrPhdr.p_paddr := baseVA + 64;
      phdrPhdr.p_filesz := UInt64(numPhdrs) * 56;
      phdrPhdr.p_memsz := phdrPhdr.p_filesz;
      phdrPhdr.p_align := 8;

      // PT_INTERP
      phdrInterp.p_type := 3; // PT_INTERP
      phdrInterp.p_flags := 4; // PF_R
      phdrInterp.p_offset := interpOffset;
      phdrInterp.p_vaddr := baseVA + interpOffset;
      phdrInterp.p_paddr := baseVA + interpOffset;
      phdrInterp.p_filesz := interpSize;
      phdrInterp.p_memsz := interpSize;
      phdrInterp.p_align := 1;

      // PT_LOAD for RX (covers ELF header + PHDRs + interp + code)
      phdrRX.p_type := 1; // PT_LOAD
      phdrRX.p_flags := 5; // PF_R | PF_X
      phdrRX.p_offset := 0;
      phdrRX.p_vaddr := baseVA;
      phdrRX.p_paddr := baseVA;
      phdrRX.p_filesz := codeOffset + codeSize;
      phdrRX.p_memsz := phdrRX.p_filesz;
      phdrRX.p_align := pageSize;

      // PT_LOAD for RW (covers user data + all dynamic structures)
      // starts at dataOffset (page-aligned) — includes dataBuf + GOT + .rela + .dynsym + .dynstr + .hash + .dynamic
      phdrRW.p_type := 1; // PT_LOAD
      phdrRW.p_flags := 6; // PF_R | PF_W
      phdrRW.p_offset := dataOffset;
      phdrRW.p_vaddr := baseVA + dataOffset;
      phdrRW.p_paddr := baseVA + dataOffset;
      phdrRW.p_filesz := dataEndOff - dataOffset;
      phdrRW.p_memsz := phdrRW.p_filesz;
      phdrRW.p_align := pageSize;

      // PT_DYNAMIC
      phdrDynamic.p_type := 2; // PT_DYNAMIC
      phdrDynamic.p_flags := 6; // PF_R | PF_W
      phdrDynamic.p_offset := dynamicOff;
      phdrDynamic.p_vaddr := baseVA + dynamicOff;
      phdrDynamic.p_paddr := baseVA + dynamicOff;
      phdrDynamic.p_filesz := dynamicTable.Size;
      phdrDynamic.p_memsz := dynamicTable.Size;
      phdrDynamic.p_align := 8;

      // ================================================================
      // PHASE 5: Write the ELF file
      // ================================================================
      fileBuf := TFileStream.Create(filename, fmCreate);
      try
        // ELF header
        fileBuf.WriteBuffer(elfHdr, SizeOf(elfHdr));

        // Program headers in order: PHDR, INTERP, LOAD(RX), LOAD(RW), DYNAMIC
        fileBuf.WriteBuffer(phdrPhdr, SizeOf(phdrPhdr));
        fileBuf.WriteBuffer(phdrInterp, SizeOf(phdrInterp));
        fileBuf.WriteBuffer(phdrRX, SizeOf(phdrRX));
        fileBuf.WriteBuffer(phdrRW, SizeOf(phdrRW));
        fileBuf.WriteBuffer(phdrDynamic, SizeOf(phdrDynamic));

        // Interpreter path
        fileBuf.WriteBuffer(PChar(interpPath)^, Length(interpPath));
        fileBuf.WriteByte(0);

        // Pad to code offset
        while fileBuf.Position < Int64(codeOffset) do
          fileBuf.WriteByte(0);

        // Code section
        if codeSize > 0 then
          fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);

        // Pad to data offset (page boundary)
        while fileBuf.Position < Int64(dataOffset) do
          fileBuf.WriteByte(0);

        // User data
        if dataSize > 0 then
          fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);

        // .dynsym
        while fileBuf.Position < Int64(dynSymOff) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(dynSymTable.GetBuffer^, dynSymTable.Size);

        // .dynstr
        while fileBuf.Position < Int64(dynStrOff) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(dynStrTable.GetBuffer^, dynStrTable.Size);

        // .hash
        while fileBuf.Position < Int64(hashOff) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(hashTable.GetBuffer^, hashTable.Size);

        // .got.plt
        while fileBuf.Position < Int64(gotOff) do
          fileBuf.WriteByte(0);
        fileBuf.WriteBuffer(gotTable.GetBuffer^, gotTable.Size);

        // .rela.plt
        while fileBuf.Position < Int64(relaPltOff) do
          fileBuf.WriteByte(0);
        if relaPltTable.Size > 0 then
          fileBuf.WriteBuffer(relaPltTable.GetBuffer^, relaPltTable.Size);

        // .rela.dyn
        while fileBuf.Position < Int64(relaDynOff) do
          fileBuf.WriteByte(0);
        if relaDynTable.Size > 0 then
          fileBuf.WriteBuffer(relaDynTable.GetBuffer^, relaDynTable.Size);

        // .dynamic
        while fileBuf.Position < Int64(dynamicOff) do
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
      hashTable.Free;
      strOffsets.Free;
    end;
  finally
    libNames.Free;
    symNames.Free;
  end;
end;

end.
