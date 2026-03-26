{$mode objfpc}{$H+}
unit elf64_arm64_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

procedure WriteElf64ARM64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
procedure WriteDynamicElf64ARM64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; externSymbols: TExternalSymbolArray; pltPatches: TPLTGOTPatchArray);

implementation

const
  // ELF Machine Type
  EM_AARCH64 = 183;
  
  // ARM64 Relocation Types (for future use)
  R_AARCH64_NONE = 0;
  R_AARCH64_ABS64 = 257;
  R_AARCH64_ABS32 = 258;
  R_AARCH64_CALL26 = 283;
  R_AARCH64_JUMP26 = 282;
  R_AARCH64_ADR_PREL_PG_HI21 = 275;
  R_AARCH64_ADD_ABS_LO12_NC = 277;

function AlignUp(v, a: UInt64): UInt64;
begin
  if a = 0 then Result := v else Result := (v + a - 1) and not (a - 1);
end;

procedure WriteElf64ARM64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
var
  pageSize: UInt64 = 4096;
  codeOffset: UInt64;
  codeSize: UInt64;
  rodataOffset: UInt64;
  rodataSize: UInt64;
  dataOffset: UInt64;
  dataSize: UInt64;
  fileBuf: TFileStream;
  elfHeader: TByteBuffer;
  phdr: TByteBuffer;
  filesz, memsz: UInt64;
  baseVA: UInt64 = $400000;
begin
  codeSize := codeBuf.Size;
  rodataSize := 0;  // Currently no separate rodata
  dataSize := dataBuf.Size;

  codeOffset := pageSize; // 0x1000
  rodataOffset := codeOffset + AlignUp(codeSize, pageSize);
  dataOffset := rodataOffset + AlignUp(rodataSize, pageSize);

  // Build ELF header
  elfHeader := TByteBuffer.Create;
  phdr := TByteBuffer.Create;
  try
    // e_ident
    elfHeader.WriteBytes([$7F, Ord('E'), Ord('L'), Ord('F')]);
    elfHeader.WriteU8(2); // EI_CLASS_64
    elfHeader.WriteU8(1); // EI_DATA_LE
    elfHeader.WriteU8(1); // EV_CURRENT
    elfHeader.WriteU8(0); // OSABI (ELFOSABI_NONE)
    elfHeader.WriteU8(0); // ABI version
    elfHeader.WriteBytesFill(7, 0); // Padding

    // e_type, e_machine, e_version
    elfHeader.WriteU16LE(2);          // ET_EXEC
    elfHeader.WriteU16LE(EM_AARCH64); // EM_AARCH64 = 183
    elfHeader.WriteU32LE(1);          // EV_CURRENT

    // e_entry, e_phoff, e_shoff
    elfHeader.WriteU64LE(entryVA);    // Entry point
    elfHeader.WriteU64LE(64);         // Program header offset (immediately after ELF header)
    elfHeader.WriteU64LE(0);          // Section header offset (none)

    // e_flags, e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx
    elfHeader.WriteU32LE(0);          // e_flags (no flags for ARM64)
    elfHeader.WriteU16LE(64);         // e_ehsize (ELF header size)
    elfHeader.WriteU16LE(56);         // e_phentsize (program header entry size)
    elfHeader.WriteU16LE(2);          // e_phnum (2 program headers: text + data)
    elfHeader.WriteU16LE(0);          // e_shentsize
    elfHeader.WriteU16LE(0);          // e_shnum
    elfHeader.WriteU16LE(0);          // e_shstrndx

    // Program header 1: PT_LOAD for code (.text)
    phdr.WriteU32LE(1);               // p_type = PT_LOAD
    phdr.WriteU32LE(5);              // p_flags = PF_R | PF_X (read + execute)
    phdr.WriteU64LE(codeOffset);      // p_offset (file offset)
    phdr.WriteU64LE(baseVA + codeOffset); // p_vaddr
    phdr.WriteU64LE(baseVA + codeOffset); // p_paddr
    
    filesz := AlignUp(codeSize, pageSize);
    memsz := filesz;
    phdr.WriteU64LE(filesz);          // p_filesz
    phdr.WriteU64LE(memsz);           // p_memsz
    phdr.WriteU64LE(pageSize);        // p_align

    // Program header 2: PT_LOAD for data (.data + .rodata)
    phdr.WriteU32LE(1);               // p_type = PT_LOAD
    phdr.WriteU32LE(6);              // p_flags = PF_R | PF_W (read + write)
    phdr.WriteU64LE(rodataOffset);   // p_offset (file offset)
    phdr.WriteU64LE(baseVA + rodataOffset); // p_vaddr
    phdr.WriteU64LE(baseVA + rodataOffset); // p_paddr
    
    filesz := AlignUp(rodataSize, pageSize) + AlignUp(dataSize, pageSize);
    memsz := filesz;
    phdr.WriteU64LE(filesz);          // p_filesz
    phdr.WriteU64LE(memsz);           // p_memsz
    phdr.WriteU64LE(pageSize);        // p_align

    // Write file
    fileBuf := TFileStream.Create(filename, fmCreate);
    try
      // Verify sizes
      if elfHeader.Size <> 64 then 
        raise Exception.CreateFmt('Invalid ELF header size: %d (expected 64)', [elfHeader.Size]);
      if phdr.Size <> 112 then 
        raise Exception.CreateFmt('Invalid PHDR size: %d (expected 112)', [phdr.Size]);
      
      // Write ELF header
      fileBuf.WriteBuffer(elfHeader.GetBuffer^, elfHeader.Size);
      
      // Write program headers
      fileBuf.WriteBuffer(phdr.GetBuffer^, phdr.Size);
      
      // Pad to code offset
      while fileBuf.Position < Int64(codeOffset) do 
        fileBuf.WriteByte(0);
      
      // Write code
      if codeSize > 0 then 
        fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);
      
      // Pad to rodata offset
      while fileBuf.Position < Int64(rodataOffset) do 
        fileBuf.WriteByte(0);
      
      // Write rodata (currently empty)
      // if rodataSize > 0 then 
      //   fileBuf.WriteBuffer(rodataBuf.GetBuffer^, rodataSize);
      
      // Pad to data offset
      while fileBuf.Position < Int64(dataOffset) do 
        fileBuf.WriteByte(0);
      
      // Write data
      if dataSize > 0 then 
        fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataSize);
    finally
      fileBuf.Free;
    end;
  finally
    phdr.Free;
    elfHeader.Free;
  end;
end;

procedure WriteDynamicElf64ARM64(const filename: string; const codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; externSymbols: TExternalSymbolArray; pltPatches: TPLTGOTPatchArray);
const
  // ARM64 Dynamic Linking Relocations
  R_AARCH64_JUMP_SLOT = 1026;
  R_AARCH64_RELATIVE = 1027;
  R_AARCH64_ABS64 = 257;
  // ARM64 ELF Machine Type
  EM_AARCH64 = 183;
  // ELF Dynamic Tags
  DT_NULL = 0; DT_NEEDED = 1; DT_PLTGOT = 3; DT_HASH = 4;
  DT_STRTAB = 5; DT_SYMTAB = 6; DT_RELA = 7; DT_RELASZ = 8;
  DT_RELAENT = 9; DT_STRSZ = 10; DT_SYMENT = 11; DT_DEBUG = 21;
  DT_JMPREL = 23; DT_PLTRELSZ = 2; DT_PLTREL = 20; DT_BIND_NOW = 24;
  // ELF Program Header Types
  PT_LOAD = 1; PT_DYNAMIC = 2; PT_INTERP = 3; PT_PHDR = 6;
  // ELF Section Header Types
  SHT_PROGBITS = 1; SHT_SYMTAB = 2; SHT_STRTAB = 3;
  SHT_RELA = 4; SHT_HASH = 5; SHT_DYNAMIC = 6;
  SHT_NOBITS = 8; SHT_DYNSYM = 11;
  // Section Header Flags
  SHF_ALLOC = 2; SHF_WRITE = 1; SHF_EXECINSTR = 4;
var
  pageSize: UInt64 = 4096;
  baseVA: UInt64 = $400000;
  symCount: Integer;
  i: Integer;
  // Layout
  codeOffset, codeSize: UInt64;
  interpStr: string;
  interpSize: UInt64;
  interpOffset: UInt64;
  dynstrBuf: TByteBuffer;
  dynstrSize: UInt64;
  dynstrOffset: UInt64;
  dataShift: UInt64;  // bytes reserved for user dataBuf at start of RW segment
  dynsymBuf: TByteBuffer;
  dynsymSize: UInt64;
  dynsymOffset: UInt64;
  hashBuf: TByteBuffer;
  hashSize: UInt64;
  hashOffset: UInt64;
  gotBuf: TByteBuffer;
  gotSize: UInt64;
  gotOffset: UInt64;
  relaBuf: TByteBuffer;
  relaSize: UInt64;
  relaOffset: UInt64;
  dynamicBuf: TByteBuffer;
  dynamicSize: UInt64;
  dynamicOffset: UInt64;
  shstrtabBuf: TByteBuffer;
  shstrtabSize: UInt64;
  shstrtabOffset: UInt64;
  shdrsBuf: TByteBuffer;
  shdrsSize: UInt64;
  shdrsOffset: UInt64;
  // File write
  fileBuf: TFileStream;
  elfHeader: TByteBuffer;
  phdrBuf: TByteBuffer;
  totalPhdrs: Integer;
  // Helpers
  pltBaseVA: UInt64;
  pltEntryVA: UInt64;
  gotVA: UInt64;
  gotOffsetSeg: UInt64;  // GOT offset within segment
  symNameOff: UInt64;
  symStrOff: UInt64;
  libOffsets: array of UInt64;
  filesz: UInt64;
begin
  symCount := Length(externSymbols);
  if symCount = 0 then
  begin
    // No external symbols — use static writer
    WriteElf64ARM64(filename, codeBuf, dataBuf, entryVA);
    Exit;
  end;

  codeSize := codeBuf.Size;
  codeOffset := pageSize;  // 0x1000
  // PLT is at the end of the code section
  // PLT0 position = codeSize - (16 + 16) = codeSize - 32 for 1 external symbol
  // Each PLT entry is 16 bytes, PLT0 is 16 bytes
  // With 1 symbol: PLT occupies last 32 bytes of code
  pltBaseVA := baseVA + codeOffset + codeSize;

  // Build .interp string
  interpStr := '/lib/ld-linux-aarch64.so.1' + #0;
  interpSize := Length(interpStr);

  // Build .dynstr section
  // Layout: offset 0 = empty string, then library names (for DT_NEEDED), then symbol names (for dynsym)
  dynstrBuf := TByteBuffer.Create;
  dynstrBuf.WriteU8(0); // empty string at offset 0
  
  // First: library names for DT_NEEDED entries
  // We need unique library names
  SetLength(libOffsets, symCount);
  for i := 0 to symCount - 1 do
  begin
    libOffsets[i] := dynstrBuf.Size;
    for symStrOff := 1 to Length(externSymbols[i].LibraryName) do
      dynstrBuf.WriteU8(Ord(externSymbols[i].LibraryName[symStrOff]));
    dynstrBuf.WriteU8(0);
  end;
  
  // Then: symbol names for dynsym entries
  symNameOff := dynstrBuf.Size; // after all library names
  for i := 0 to symCount - 1 do
  begin
    for symStrOff := 1 to Length(externSymbols[i].Name) do
      dynstrBuf.WriteU8(Ord(externSymbols[i].Name[symStrOff]));
    dynstrBuf.WriteU8(0);
  end;
  dynstrSize := dynstrBuf.Size;

  // Build .dynsym section (symbol table)
  dynsymBuf := TByteBuffer.Create;
  // Entry 0: null symbol (24 bytes on ARM64)
  dynsymBuf.WriteU32LE(0);  // st_name
  dynsymBuf.WriteU8(0);     // st_info
  dynsymBuf.WriteU8(0);     // st_other
  dynsymBuf.WriteU16LE(0);  // st_shndx
  dynsymBuf.WriteU64LE(0);  // st_value
  dynsymBuf.WriteU64LE(0);  // st_size
  // Entries for external symbols
  // symNameOff was calculated after library names
  for i := 0 to symCount - 1 do
  begin
    dynsymBuf.WriteU32LE(symNameOff);          // st_name (offset in .dynstr)
    dynsymBuf.WriteU8($10);                    // st_info = STB_GLOBAL | STT_FUNC
    dynsymBuf.WriteU8(0);                      // st_other = STV_DEFAULT
    dynsymBuf.WriteU16LE(0);                   // st_shndx = SHN_UNDEF
    dynsymBuf.WriteU64LE(0);                   // st_value = 0 (undefined)
    dynsymBuf.WriteU64LE(0);                   // st_size = 0
    Inc(symNameOff, Length(externSymbols[i].Name) + 1);
  end;
  dynsymSize := dynsymBuf.Size;

  // Build .hash section (minimal hash table)
  hashBuf := TByteBuffer.Create;
  hashBuf.WriteU32LE(symCount);  // nbucket
  hashBuf.WriteU32LE(symCount + 1);  // nchain (includes null symbol at index 0)
  // Buckets: one per symbol (simple)
  for i := 0 to symCount - 1 do
    hashBuf.WriteU32LE(i + 1);  // chain index (1-based, skip null)
  // Chain: one entry per symbol (including null)
  hashBuf.WriteU32LE(0);  // chain[0] = 0 (null symbol, end of chain)
  for i := 0 to symCount - 1 do
    hashBuf.WriteU32LE(0);  // chain[i+1] = 0 (end of chain for each symbol)
  hashSize := hashBuf.Size;

  // Build .got.plt section
  gotBuf := TByteBuffer.Create;
  gotBuf.WriteU64LE(0);  // GOT[0] = _DYNAMIC (patched)
  gotBuf.WriteU64LE(0);  // GOT[1] = link_map (set by ld.so)
  gotBuf.WriteU64LE(0);  // GOT[2] = _dl_runtime_resolve (set by ld.so)
  for i := 0 to symCount - 1 do
    gotBuf.WriteU64LE(0); // GOT[3+n] = initially PLT0 (patched below)
  gotSize := gotBuf.Size;

  // Build .rela.plt section
  relaBuf := TByteBuffer.Create;
  for i := 0 to symCount - 1 do
  begin
    // r_offset = GOT[3+i] address
    // r_info = (sym_index << 32) | R_AARCH64_JUMP_SLOT
    // r_addend = 0
    relaBuf.WriteU64LE(0);  // r_offset (patched below)
    relaBuf.WriteU64LE(UInt64(i + 1) shl 32 + R_AARCH64_JUMP_SLOT); // r_info
    relaBuf.WriteU64LE(0);   // r_addend
  end;
  relaSize := relaBuf.Size;

  // Build .dynamic section
  dynamicBuf := TByteBuffer.Create;
  // Dynamic section entries (each entry is 2 x UInt64 = 16 bytes)
  // Entry 0: DT_NEEDED for library (use libOffsets[0])
  dynamicBuf.WriteU64LE(DT_NEEDED); dynamicBuf.WriteU64LE(libOffsets[0]);  // offset to "libc.so.6" in .dynstr
  // Entry 1: DT_HASH (patched)
  dynamicBuf.WriteU64LE(DT_HASH); dynamicBuf.WriteU64LE(0);
  // Entry 2: DT_STRTAB (patched)
  dynamicBuf.WriteU64LE(DT_STRTAB); dynamicBuf.WriteU64LE(0);
  // Entry 3: DT_SYMTAB (patched)
  dynamicBuf.WriteU64LE(DT_SYMTAB); dynamicBuf.WriteU64LE(0);
  // Entry 4: DT_STRSZ
  dynamicBuf.WriteU64LE(DT_STRSZ); dynamicBuf.WriteU64LE(dynstrSize);
  // Entry 5: DT_SYMENT (24 bytes for ARM64 ELF64 symbol)
  dynamicBuf.WriteU64LE(DT_SYMENT); dynamicBuf.WriteU64LE(24);
  // Entry 6: DT_PLTGOT (patched)
  dynamicBuf.WriteU64LE(DT_PLTGOT); dynamicBuf.WriteU64LE(0);
  // Entry 7: DT_JMPREL (patched)
  dynamicBuf.WriteU64LE(DT_JMPREL); dynamicBuf.WriteU64LE(0);
  // Entry 8: DT_PLTRELSZ
  dynamicBuf.WriteU64LE(DT_PLTRELSZ); dynamicBuf.WriteU64LE(relaSize);
  // Entry 9: DT_PLTREL (type of PLT relocations = DT_RELA = 7)
  dynamicBuf.WriteU64LE(DT_PLTREL); dynamicBuf.WriteU64LE(DT_RELA);
  // Entry 10: DT_BIND_NOW
  dynamicBuf.WriteU64LE(DT_BIND_NOW); dynamicBuf.WriteU64LE(0);
  // Entry 11: DT_DEBUG
  dynamicBuf.WriteU64LE(DT_DEBUG); dynamicBuf.WriteU64LE(0);
  // Entry 12: DT_NULL (terminator)
  dynamicBuf.WriteU64LE(DT_NULL); dynamicBuf.WriteU64LE(0);
  dynamicSize := dynamicBuf.Size;

  // Build .shstrtab section
  shstrtabBuf := TByteBuffer.Create;
  shstrtabBuf.WriteU8(0); // empty string
  // Section name offsets:
  // .text=1, .interp=7, .dynsym=15, .dynstr=23, .hash=31, .got.plt=37, .rela.plt=46, .dynamic=57, .shstrtab=66
  shstrtabBuf.WriteBytes([Ord('.'), Ord('t'), Ord('e'), Ord('x'), Ord('t'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('i'), Ord('n'), Ord('t'), Ord('e'), Ord('r'), Ord('p'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('s'), Ord('y'), Ord('m'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('s'), Ord('t'), Ord('r'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('h'), Ord('a'), Ord('s'), Ord('h'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('g'), Ord('o'), Ord('t'), Ord('.'), Ord('p'), Ord('l'), Ord('t'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('r'), Ord('e'), Ord('l'), Ord('a'), Ord('.'), Ord('p'), Ord('l'), Ord('t'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('a'), Ord('m'), Ord('i'), Ord('c'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('s'), Ord('h'), Ord('s'), Ord('t'), Ord('r'), Ord('t'), Ord('a'), Ord('b'), 0]);
  shstrtabSize := shstrtabBuf.Size;

  // Layout for dynamic linking
  // Data segment starts at baseVA + dynstrOffset (dynstrOffset is page-aligned after interp)
  // Layout: [dataBuf] + dynstr + dynsym + hash + GOT + rela + dynamic + shstrtab
  interpOffset := codeOffset + codeSize;
  if (interpOffset mod 8) <> 0 then
    interpOffset := interpOffset + (8 - (interpOffset mod 8));
  // After interp: pad to next page
  dynstrOffset := AlignUp(interpOffset + interpSize, pageSize);
  // dataShift: user data (strings, globals) lives at the start of the RW segment
  dataShift := (dataBuf.Size + 7) and not UInt64(7);
  // All following offsets are relative to dynstrOffset (segment start)
  // dynsym at dataShift + dynstrSize (aligned to 8) — after user data and dynstr
  dynsymOffset := AlignUp(dataShift + dynstrSize, 8);
  // hash at dynsymOffset + dynsymSize (aligned to 8)
  hashOffset := AlignUp(dynsymOffset + dynsymSize, 8);
  // GOT at offset after hash (aligned to 8) within segment
  gotOffsetSeg := AlignUp(hashOffset + hashSize, 8);
  // rela immediately after GOT within segment
  relaOffset := gotOffsetSeg + gotSize;
  // dynamic after rela within segment (aligned to 8)
  dynamicOffset := AlignUp(relaOffset + relaSize, 8);
  shstrtabOffset := AlignUp(dynamicOffset + dynamicSize, 8);
  // shstrtab file offset = dynstrOffset + shstrtabOffset
  // shdrs file offset = aligned after shstrtab
  shdrsOffset := AlignUp(dynstrOffset + shstrtabOffset + shstrtabSize, 8);
  shdrsSize := 64 * 11; // 11 section headers (added .text)

  // Patch GOT entries and RELA offsets
  // GOT VA = (baseVA + dynstrOffset) + gotOffsetSeg
  // Since the LOAD(RW) segment starts at file offset dynstrOffset with VA baseVA + dynstrOffset,
  // and gotOffsetSeg is the offset from the segment start:
  gotVA := (baseVA + dynstrOffset) + gotOffsetSeg;
  // GOT[0] = _DYNAMIC (address of .dynamic section)
  // .dynamic is at VA baseVA + dynstrOffset + dynamicOffset
  gotBuf.PatchU64LE(0, baseVA + dynstrOffset + dynamicOffset);
  // GOT[3+i] = initially point to PLT[i] (the ldr instruction)
  // Each PLT entry is 16 bytes: ldr, br, nop, nop
  // PLT[0] starts at pltBaseVA - 16 - symCount * 16 (at the end of code)
  // PLT[i] = pltBaseVA - (symCount - i) * 16
  for i := 0 to symCount - 1 do
  begin
    pltEntryVA := pltBaseVA - (symCount - i) * 16;
    gotBuf.PatchU64LE(24 + i * 8, pltEntryVA);
  end;

  // Patch RELA r_offset values
  for i := 0 to symCount - 1 do
    relaBuf.PatchU64LE(i * 24, gotVA + 24 + i * 8); // GOT[3+i] address

  // Patch Dynamic section addresses
  // All VAs are relative to dynstrOffset within the data segment
  // VA = baseVA + dynstrOffset + (offset within segment)
  // Entry offsets in dynamicBuf (each entry is 16 bytes):
  //   Entry 0 (offset 0):   DT_NEEDED, value=1
  //   Entry 1 (offset 16):  DT_HASH
  //   Entry 2 (offset 32):  DT_STRTAB
  //   Entry 3 (offset 48):  DT_SYMTAB
  //   Entry 4 (offset 64):  DT_STRSZ, value=dynstrSize
  //   Entry 5 (offset 80):  DT_SYMENT, value=24
  //   Entry 6 (offset 96):  DT_PLTGOT
  //   Entry 7 (offset 112): DT_JMPREL
  //   Entry 8 (offset 128): DT_PLTRELSZ
  //   Entry 9 (offset 144): DT_PLTREL, value=DT_RELA
  //   Entry 10 (offset 160): DT_BIND_NOW
  //   Entry 11 (offset 176): DT_DEBUG
  //   Entry 12 (offset 192): DT_NULL
  // Patching the VALUE fields (offset+8 within each entry):
  dynamicBuf.PatchU64LE(16 + 8, baseVA + dynstrOffset + hashOffset);      // DT_HASH value
  dynamicBuf.PatchU64LE(32 + 8, baseVA + dynstrOffset + dataShift);      // DT_STRTAB value
  dynamicBuf.PatchU64LE(48 + 8, baseVA + dynstrOffset + dynsymOffset);    // DT_SYMTAB value
  dynamicBuf.PatchU64LE(96 + 8, gotVA);                                    // DT_PLTGOT value
  dynamicBuf.PatchU64LE(112 + 8, baseVA + dynstrOffset + relaOffset);      // DT_JMPREL value

  // Build ELF header
  elfHeader := TByteBuffer.Create;
  phdrBuf := TByteBuffer.Create;
  try
    // e_ident
    elfHeader.WriteBytes([$7F, Ord('E'), Ord('L'), Ord('F')]);
    elfHeader.WriteU8(2); elfHeader.WriteU8(1); elfHeader.WriteU8(1);
    elfHeader.WriteU8(0); elfHeader.WriteU8(0);
    elfHeader.WriteBytesFill(7, 0);

    elfHeader.WriteU16LE(2);           // ET_EXEC (position-dependent executable)
    elfHeader.WriteU16LE(EM_AARCH64);  // EM_AARCH64
    elfHeader.WriteU32LE(1);

    elfHeader.WriteU64LE(entryVA);
    elfHeader.WriteU64LE(64);          // e_phoff
    elfHeader.WriteU64LE(shdrsOffset); // e_shoff

    elfHeader.WriteU32LE(0);
    elfHeader.WriteU16LE(64);
    elfHeader.WriteU16LE(56);
    elfHeader.WriteU16LE(5);           // e_phnum: PHDR, INTERP, LOAD(RX), LOAD(RW), DYNAMIC
    elfHeader.WriteU16LE(64);          // e_shentsize
    elfHeader.WriteU16LE(11);          // e_shnum (0-10 = 11 sections)
    elfHeader.WriteU16LE(9);           // e_shstrndx (.shstrtab is index 9)

    // Program header 0: PT_PHDR
    phdrBuf.WriteU32LE(PT_PHDR);
    phdrBuf.WriteU32LE(4 or 1);        // PF_R | PF_X
    phdrBuf.WriteU64LE(64);            // p_offset (after ELF header)
    phdrBuf.WriteU64LE(baseVA + 64);   // p_vaddr
    phdrBuf.WriteU64LE(baseVA + 64);   // p_paddr
    phdrBuf.WriteU64LE(5 * 56);        // p_filesz (5 phdrs * 56 bytes)
    phdrBuf.WriteU64LE(4 * 56);        // p_memsz
    phdrBuf.WriteU64LE(8);             // p_align

    // Program header 1: PT_INTERP
    phdrBuf.WriteU32LE(PT_INTERP);
    phdrBuf.WriteU32LE(4);             // PF_R
    phdrBuf.WriteU64LE(interpOffset);
    phdrBuf.WriteU64LE(baseVA + interpOffset);
    phdrBuf.WriteU64LE(baseVA + interpOffset);
    phdrBuf.WriteU64LE(interpSize);
    phdrBuf.WriteU64LE(interpSize);
    phdrBuf.WriteU64LE(1);

    // Program header 2: PT_LOAD (RX) — code + interp
    phdrBuf.WriteU32LE(PT_LOAD);
    phdrBuf.WriteU32LE(4 or 1);        // PF_R | PF_X
    phdrBuf.WriteU64LE(0);
    phdrBuf.WriteU64LE(baseVA);
    phdrBuf.WriteU64LE(baseVA);
    phdrBuf.WriteU64LE(AlignUp(interpOffset + interpSize, pageSize));
    phdrBuf.WriteU64LE(AlignUp(interpOffset + interpSize, pageSize));
    phdrBuf.WriteU64LE(pageSize);

    // Program header 3: PT_LOAD (RW) — dynamic sections
    // The segment starts at file offset dynstrOffset with VA baseVA + dynstrOffset
    // All section offsets are relative to dynstrOffset
    phdrBuf.WriteU32LE(PT_LOAD);
    phdrBuf.WriteU32LE(4 or 2);        // PF_R | PF_W
    phdrBuf.WriteU64LE(dynstrOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset);
    // p_filesz and p_memsz should cover from dynstrOffset to the end of section headers
    filesz := AlignUp(shstrtabOffset + shstrtabSize + shdrsSize, pageSize);
    phdrBuf.WriteU64LE(filesz);   // p_filesz
    phdrBuf.WriteU64LE(filesz);   // p_memsz (same as filesz for data segments)
    phdrBuf.WriteU64LE(pageSize); // p_align

    // Program header 4: PT_DYNAMIC — points to .dynamic section
    // .dynamic is at file offset dynstrOffset + dynamicOffset
    phdrBuf.WriteU32LE(PT_DYNAMIC);
    phdrBuf.WriteU32LE(4 or 2);        // PF_R | PF_W
    phdrBuf.WriteU64LE(dynstrOffset + dynamicOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset + dynamicOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset + dynamicOffset);
    phdrBuf.WriteU64LE(dynamicSize);
    phdrBuf.WriteU64LE(dynamicSize);
    phdrBuf.WriteU64LE(8);            // p_align

    // Initialize section header buffer
    shdrsBuf := TByteBuffer.Create;

    // Section Headers
    // 0: NULL
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);

    // Helper proc for section headers
    // 1: .text
    shdrsBuf.WriteU32LE(1); shdrsBuf.WriteU32LE(SHT_PROGBITS); shdrsBuf.WriteU64LE(SHF_ALLOC or SHF_EXECINSTR);
    shdrsBuf.WriteU64LE(baseVA + codeOffset); shdrsBuf.WriteU64LE(codeOffset);
    shdrsBuf.WriteU64LE(codeSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(16); shdrsBuf.WriteU64LE(0);

    // 2: .interp
    shdrsBuf.WriteU32LE(7); shdrsBuf.WriteU32LE(SHT_PROGBITS); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + interpOffset); shdrsBuf.WriteU64LE(interpOffset);
    shdrsBuf.WriteU64LE(interpSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 3: .dynsym
    shdrsBuf.WriteU32LE(15); shdrsBuf.WriteU32LE(SHT_DYNSYM); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + dynsymOffset); shdrsBuf.WriteU64LE(dynstrOffset + dynsymOffset);
    shdrsBuf.WriteU64LE(dynsymSize); shdrsBuf.WriteU32LE(4); // sh_link = .dynstr (index 4)
    shdrsBuf.WriteU32LE(1); // sh_info = 1 (first global symbol)
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(24); // sh_entsize = 24

    // 4: .dynstr
    shdrsBuf.WriteU32LE(23); shdrsBuf.WriteU32LE(SHT_STRTAB); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + dataShift); shdrsBuf.WriteU64LE(dynstrOffset + dataShift);
    shdrsBuf.WriteU64LE(dynstrSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 5: .hash
    shdrsBuf.WriteU32LE(31); shdrsBuf.WriteU32LE(SHT_HASH); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + hashOffset); shdrsBuf.WriteU64LE(dynstrOffset + hashOffset);
    shdrsBuf.WriteU64LE(hashSize); shdrsBuf.WriteU32LE(3); // sh_link = .dynsym (index 3)
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(4); shdrsBuf.WriteU64LE(4);

    // 6: .got.plt
    shdrsBuf.WriteU32LE(37); shdrsBuf.WriteU32LE(SHT_PROGBITS); shdrsBuf.WriteU64LE(SHF_ALLOC or SHF_WRITE);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + gotOffsetSeg); shdrsBuf.WriteU64LE(dynstrOffset + gotOffsetSeg);
    shdrsBuf.WriteU64LE(gotSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(8);

    // 7: .rela.plt
    shdrsBuf.WriteU32LE(46); shdrsBuf.WriteU32LE(SHT_RELA); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + relaOffset); shdrsBuf.WriteU64LE(dynstrOffset + relaOffset);
    shdrsBuf.WriteU64LE(relaSize); shdrsBuf.WriteU32LE(3); // sh_link = .dynsym (index 3)
    shdrsBuf.WriteU32LE(symCount); // sh_info
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(24); // sh_entsize = 24

    // 8: .dynamic
    shdrsBuf.WriteU32LE(57); shdrsBuf.WriteU32LE(SHT_DYNAMIC); shdrsBuf.WriteU64LE(SHF_ALLOC or SHF_WRITE);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset + dynamicOffset); shdrsBuf.WriteU64LE(dynstrOffset + dynamicOffset);
    shdrsBuf.WriteU64LE(dynamicSize); shdrsBuf.WriteU32LE(4); // sh_link = .dynstr (index 4)
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(16);

    // 9: .shstrtab
    shdrsBuf.WriteU32LE(66); shdrsBuf.WriteU32LE(SHT_STRTAB); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(dynstrOffset + shstrtabOffset);
    shdrsBuf.WriteU64LE(shstrtabSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 10: NULL
    // No, index 9 is the last entry. Actually we need 10 entries: 0-9.
    // We already wrote 9 entries (0-8). Let's add one more NULL for safety.
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);

    // Write file
    fileBuf := TFileStream.Create(filename, fmCreate);
    try
      // ELF header
      fileBuf.WriteBuffer(elfHeader.GetBuffer^, elfHeader.Size);
      // Program headers
      fileBuf.WriteBuffer(phdrBuf.GetBuffer^, phdrBuf.Size);
      // Pad to code offset
      while fileBuf.Position < Int64(codeOffset) do fileBuf.WriteByte(0);
      // Code
      if codeSize > 0 then fileBuf.WriteBuffer(codeBuf.GetBuffer^, codeSize);
      // Pad to interpreter offset
      while fileBuf.Position < Int64(interpOffset) do fileBuf.WriteByte(0);
      // Interpreter string
      fileBuf.WriteBuffer(Pointer(@interpStr[1])^, Length(interpStr));
      // Pad to RW segment start (dynstrOffset) — user data goes here
      while fileBuf.Position < Int64(dynstrOffset) do fileBuf.WriteByte(0);
      // Static data (user strings and global variables)
      if dataBuf.Size > 0 then fileBuf.WriteBuffer(dataBuf.GetBuffer^, dataBuf.Size);
      // Pad to .dynstr offset (dynstrOffset + dataShift)
      while fileBuf.Position < Int64(dynstrOffset + dataShift) do fileBuf.WriteByte(0);
      // .dynstr
      fileBuf.WriteBuffer(dynstrBuf.GetBuffer^, dynstrBuf.Size);
      // Pad to dynsym offset (relative to dynstrOffset, already includes dataShift)
      while fileBuf.Position < Int64(dynstrOffset + dynsymOffset) do fileBuf.WriteByte(0);
      // .dynsym
      fileBuf.WriteBuffer(dynsymBuf.GetBuffer^, dynsymBuf.Size);
      // Pad to hash offset (relative to dynstrOffset)
      while fileBuf.Position < Int64(dynstrOffset + hashOffset) do fileBuf.WriteByte(0);
      // .hash
      fileBuf.WriteBuffer(hashBuf.GetBuffer^, hashBuf.Size);
      // Pad to GOT offset (relative to dynstrOffset)
      while fileBuf.Position < Int64(dynstrOffset + gotOffsetSeg) do fileBuf.WriteByte(0);
      // .got.plt
      fileBuf.WriteBuffer(gotBuf.GetBuffer^, gotBuf.Size);
      // Pad to RELA offset (relative to dynstrOffset)
      while fileBuf.Position < Int64(dynstrOffset + relaOffset) do fileBuf.WriteByte(0);
      // .rela.plt
      fileBuf.WriteBuffer(relaBuf.GetBuffer^, relaBuf.Size);
      // Pad to dynamic offset (relative to dynstrOffset)
      while fileBuf.Position < Int64(dynstrOffset + dynamicOffset) do fileBuf.WriteByte(0);
      // .dynamic
      fileBuf.WriteBuffer(dynamicBuf.GetBuffer^, dynamicBuf.Size);
      // Pad to shstrtab offset (relative to dynstrOffset)
      while fileBuf.Position < Int64(dynstrOffset + shstrtabOffset) do fileBuf.WriteByte(0);
      // .shstrtab
      fileBuf.WriteBuffer(shstrtabBuf.GetBuffer^, shstrtabBuf.Size);
      // Pad to section headers offset
      while fileBuf.Position < Int64(shdrsOffset) do fileBuf.WriteByte(0);
      // Section headers
      fileBuf.WriteBuffer(shdrsBuf.GetBuffer^, shdrsBuf.Size);
    finally
      fileBuf.Free;
    end;
  finally
    shdrsBuf.Free;
    phdrBuf.Free;
    elfHeader.Free;
  end;
  dynstrBuf.Free;
  dynsymBuf.Free;
  hashBuf.Free;
  gotBuf.Free;
  relaBuf.Free;
  dynamicBuf.Free;
  shstrtabBuf.Free;
end;

end.
