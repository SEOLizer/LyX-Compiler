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
  DT_JMPREL = 23; DT_PLTRELSZ = 2; DT_BIND_NOW = 24;
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
  gotVA: UInt64;
  symNameOff: UInt64;
  symStrOff: UInt64;
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
  pltBaseVA := baseVA + codeOffset;

  // Build .interp string
  interpStr := '/lib/ld-linux-aarch64.so.1' + #0;
  interpSize := Length(interpStr);

  // Build .dynstr section
  dynstrBuf := TByteBuffer.Create;
  dynstrBuf.WriteU8(0); // empty string at offset 0
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
  symNameOff := 1; // after the initial null byte
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
  hashBuf.WriteU32LE(symCount);  // nchain
  // Buckets: one per symbol (simple)
  for i := 0 to symCount - 1 do
    hashBuf.WriteU32LE(i + 1);  // chain index (1-based, skip null)
  // Chain
  for i := 0 to symCount - 1 do
    hashBuf.WriteU32LE(0);  // chain entries (all 0 = no collision handling)
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
  // DT_NEEDED for libc
  dynamicBuf.WriteU64LE(DT_NEEDED); dynamicBuf.WriteU64LE(1);  // offset 1 in .dynstr (first symbol name)
  // We don't have libc.so.6 in dynstr, so we add it separately
  // For now, skip DT_NEEDED — ld.so will handle libc resolution

  dynamicBuf.WriteU64LE(DT_HASH); dynamicBuf.WriteU64LE(0);     // patched
  dynamicBuf.WriteU64LE(DT_STRTAB); dynamicBuf.WriteU64LE(0);   // patched
  dynamicBuf.WriteU64LE(DT_SYMTAB); dynamicBuf.WriteU64LE(0);   // patched
  dynamicBuf.WriteU64LE(DT_STRSZ); dynamicBuf.WriteU64LE(dynstrSize);
  dynamicBuf.WriteU64LE(DT_SYMENT); dynamicBuf.WriteU64LE(24);  // ARM64 sym entry size
  dynamicBuf.WriteU64LE(DT_PLTGOT); dynamicBuf.WriteU64LE(0);   // patched
  dynamicBuf.WriteU64LE(DT_JMPREL); dynamicBuf.WriteU64LE(0);   // patched
  dynamicBuf.WriteU64LE(DT_PLTRELSZ); dynamicBuf.WriteU64LE(relaSize);
  dynamicBuf.WriteU64LE(DT_BIND_NOW); dynamicBuf.WriteU64LE(0);
  dynamicBuf.WriteU64LE(DT_DEBUG); dynamicBuf.WriteU64LE(0);
  dynamicBuf.WriteU64LE(DT_NULL); dynamicBuf.WriteU64LE(0);
  dynamicSize := dynamicBuf.Size;

  // Build .shstrtab section
  shstrtabBuf := TByteBuffer.Create;
  shstrtabBuf.WriteU8(0); // empty string
  // Section name offsets:
  // .interp=1, .dynsym=X, .dynstr=Y, .hash=Z, .got.plt=W, .rela.plt=V, .dynamic=U, .shstrtab=T
  shstrtabBuf.WriteBytes([Ord('.'), Ord('i'), Ord('n'), Ord('t'), Ord('e'), Ord('r'), Ord('p'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('s'), Ord('y'), Ord('m'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('s'), Ord('t'), Ord('r'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('h'), Ord('a'), Ord('s'), Ord('h'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('g'), Ord('o'), Ord('t'), Ord('.'), Ord('p'), Ord('l'), Ord('t'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('r'), Ord('e'), Ord('l'), Ord('a'), Ord('.'), Ord('p'), Ord('l'), Ord('t'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('d'), Ord('y'), Ord('n'), Ord('a'), Ord('m'), Ord('i'), Ord('c'), 0]);
  shstrtabBuf.WriteBytes([Ord('.'), Ord('s'), Ord('h'), Ord('s'), Ord('t'), Ord('r'), Ord('t'), Ord('a'), Ord('b'), 0]);
  shstrtabSize := shstrtabBuf.Size;

  // Layout
  interpOffset := codeOffset + codeSize;
  if (interpOffset mod 8) <> 0 then
    interpOffset := interpOffset + (8 - (interpOffset mod 8));
  // After interp: pad to next page
  dynstrOffset := AlignUp(interpOffset + interpSize, pageSize);
  dynsymOffset := AlignUp(dynstrOffset + dynstrSize, 8);
  hashOffset := AlignUp(dynsymOffset + dynsymSize, 8);
  gotOffset := AlignUp(hashOffset + hashSize, 8);
  relaOffset := AlignUp(gotOffset + gotSize, 8);
  dynamicOffset := AlignUp(relaOffset + relaSize, 8);
  shstrtabOffset := AlignUp(dynamicOffset + dynamicSize, 8);
  shdrsOffset := AlignUp(shstrtabOffset + shstrtabSize, 8);
  shdrsSize := 64 * 10; // 10 section headers

  // Patch GOT entries and RELA offsets
  gotVA := baseVA + gotOffset;
  // GOT[0] = _DYNAMIC (address of .dynamic section)
  gotBuf.PatchU64LE(0, baseVA + dynamicOffset);
  // GOT[3+n] = initially point to PLT0+8 (skip first two PLT0 entries to avoid infinite loop)
  for i := 0 to symCount - 1 do
    gotBuf.PatchU64LE(24 + i * 8, pltBaseVA + 16); // point to PLT0+16 (NOP padding after jmp)

  // Patch RELA r_offset values
  for i := 0 to symCount - 1 do
    relaBuf.PatchU64LE(i * 24, gotVA + 24 + i * 8); // GOT[3+i] address

  // Patch Dynamic section addresses
  dynamicBuf.PatchU64LE(16, baseVA + hashOffset);     // DT_HASH
  dynamicBuf.PatchU64LE(32, baseVA + dynstrOffset);   // DT_STRTAB
  dynamicBuf.PatchU64LE(48, baseVA + dynsymOffset);   // DT_SYMTAB
  dynamicBuf.PatchU64LE(80, gotVA);                   // DT_PLTGOT
  dynamicBuf.PatchU64LE(96, baseVA + relaOffset);     // DT_JMPREL

  // Build ELF header
  elfHeader := TByteBuffer.Create;
  phdrBuf := TByteBuffer.Create;
  shdrsBuf := TByteBuffer.Create;
  try
    // e_ident
    elfHeader.WriteBytes([$7F, Ord('E'), Ord('L'), Ord('F')]);
    elfHeader.WriteU8(2); elfHeader.WriteU8(1); elfHeader.WriteU8(1);
    elfHeader.WriteU8(0); elfHeader.WriteU8(0);
    elfHeader.WriteBytesFill(7, 0);

    elfHeader.WriteU16LE(3);           // ET_DYN (PIE)
    elfHeader.WriteU16LE(EM_AARCH64);  // EM_AARCH64
    elfHeader.WriteU32LE(1);

    elfHeader.WriteU64LE(entryVA);
    elfHeader.WriteU64LE(64);          // e_phoff
    elfHeader.WriteU64LE(shdrsOffset); // e_shoff

    elfHeader.WriteU32LE(0);
    elfHeader.WriteU16LE(64);
    elfHeader.WriteU16LE(56);
    elfHeader.WriteU16LE(4);           // e_phnum: PHDR, INTERP, LOAD(RX), LOAD(RW), DYNAMIC
    elfHeader.WriteU16LE(64);          // e_shentsize
    elfHeader.WriteU16LE(10);          // e_shnum
    elfHeader.WriteU16LE(9);           // e_shstrndx (.shstrtab is index 9)

    // Program header 0: PT_PHDR
    phdrBuf.WriteU32LE(PT_PHDR);
    phdrBuf.WriteU32LE(4 or 1);        // PF_R | PF_X
    phdrBuf.WriteU64LE(64);            // p_offset (after ELF header)
    phdrBuf.WriteU64LE(baseVA + 64);   // p_vaddr
    phdrBuf.WriteU64LE(baseVA + 64);   // p_paddr
    phdrBuf.WriteU64LE(4 * 56);        // p_filesz (4 phdrs * 56 bytes)
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
    phdrBuf.WriteU32LE(PT_LOAD);
    phdrBuf.WriteU32LE(4 or 2);        // PF_R | PF_W
    phdrBuf.WriteU64LE(dynstrOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset);
    phdrBuf.WriteU64LE(baseVA + dynstrOffset);
    phdrBuf.WriteU64LE(AlignUp(shstrtabOffset + shstrtabSize + shdrsSize, pageSize));
    phdrBuf.WriteU64LE(AlignUp(shstrtabOffset + shstrtabSize + shdrsSize, pageSize));
    phdrBuf.WriteU64LE(pageSize);

    // Section Headers
    // 0: NULL
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(0);

    // Helper proc for section headers
    // 1: .interp
    shdrsBuf.WriteU32LE(1); shdrsBuf.WriteU32LE(SHT_PROGBITS); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + interpOffset); shdrsBuf.WriteU64LE(interpOffset);
    shdrsBuf.WriteU64LE(interpSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 2: .dynsym
    shdrsBuf.WriteU32LE(9); shdrsBuf.WriteU32LE(SHT_DYNSYM); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynsymOffset); shdrsBuf.WriteU64LE(dynsymOffset);
    shdrsBuf.WriteU64LE(dynsymSize); shdrsBuf.WriteU32LE(3); // sh_link = .dynstr
    shdrsBuf.WriteU32LE(1); // sh_info = 1 (first global symbol)
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(24); // sh_entsize = 24

    // 3: .dynstr
    shdrsBuf.WriteU32LE(17); shdrsBuf.WriteU32LE(SHT_STRTAB); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + dynstrOffset); shdrsBuf.WriteU64LE(dynstrOffset);
    shdrsBuf.WriteU64LE(dynstrSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 4: .hash
    shdrsBuf.WriteU32LE(25); shdrsBuf.WriteU32LE(SHT_HASH); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + hashOffset); shdrsBuf.WriteU64LE(hashOffset);
    shdrsBuf.WriteU64LE(hashSize); shdrsBuf.WriteU32LE(2); // sh_link = .dynsym
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(4); shdrsBuf.WriteU64LE(4);

    // 5: .got.plt
    shdrsBuf.WriteU32LE(31); shdrsBuf.WriteU32LE(SHT_PROGBITS); shdrsBuf.WriteU64LE(SHF_ALLOC or SHF_WRITE);
    shdrsBuf.WriteU64LE(baseVA + gotOffset); shdrsBuf.WriteU64LE(gotOffset);
    shdrsBuf.WriteU64LE(gotSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(8);

    // 6: .rela.plt
    shdrsBuf.WriteU32LE(40); shdrsBuf.WriteU32LE(SHT_RELA); shdrsBuf.WriteU64LE(SHF_ALLOC);
    shdrsBuf.WriteU64LE(baseVA + relaOffset); shdrsBuf.WriteU64LE(relaOffset);
    shdrsBuf.WriteU64LE(relaSize); shdrsBuf.WriteU32LE(2); // sh_link = .dynsym
    shdrsBuf.WriteU32LE(symCount); // sh_info
    shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(24); // sh_entsize = 24

    // 7: .dynamic
    shdrsBuf.WriteU32LE(50); shdrsBuf.WriteU32LE(SHT_DYNAMIC); shdrsBuf.WriteU64LE(SHF_ALLOC or SHF_WRITE);
    shdrsBuf.WriteU64LE(baseVA + dynamicOffset); shdrsBuf.WriteU64LE(dynamicOffset);
    shdrsBuf.WriteU64LE(dynamicSize); shdrsBuf.WriteU32LE(3); // sh_link = .dynstr
    shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU64LE(8); shdrsBuf.WriteU64LE(16);

    // 8: .shstrtab
    shdrsBuf.WriteU32LE(59); shdrsBuf.WriteU32LE(SHT_STRTAB); shdrsBuf.WriteU64LE(0);
    shdrsBuf.WriteU64LE(0); shdrsBuf.WriteU64LE(shstrtabOffset);
    shdrsBuf.WriteU64LE(shstrtabSize); shdrsBuf.WriteU32LE(0); shdrsBuf.WriteU32LE(0);
    shdrsBuf.WriteU64LE(1); shdrsBuf.WriteU64LE(0);

    // 9: NULL (shstrtab placeholder — actually the index for .shstrtab name)
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
      // Pad to dynstr offset
      while fileBuf.Position < Int64(dynstrOffset) do fileBuf.WriteByte(0);
      // .dynstr
      fileBuf.WriteBuffer(dynstrBuf.GetBuffer^, dynstrBuf.Size);
      // Pad to dynsym offset
      while fileBuf.Position < Int64(dynsymOffset) do fileBuf.WriteByte(0);
      // .dynsym
      fileBuf.WriteBuffer(dynsymBuf.GetBuffer^, dynsymBuf.Size);
      // Pad to hash offset
      while fileBuf.Position < Int64(hashOffset) do fileBuf.WriteByte(0);
      // .hash
      fileBuf.WriteBuffer(hashBuf.GetBuffer^, hashBuf.Size);
      // Pad to got offset
      while fileBuf.Position < Int64(gotOffset) do fileBuf.WriteByte(0);
      // .got.plt
      fileBuf.WriteBuffer(gotBuf.GetBuffer^, gotBuf.Size);
      // Pad to rela offset
      while fileBuf.Position < Int64(relaOffset) do fileBuf.WriteByte(0);
      // .rela.plt
      fileBuf.WriteBuffer(relaBuf.GetBuffer^, relaBuf.Size);
      // Pad to dynamic offset
      while fileBuf.Position < Int64(dynamicOffset) do fileBuf.WriteByte(0);
      // .dynamic
      fileBuf.WriteBuffer(dynamicBuf.GetBuffer^, dynamicBuf.Size);
      // Pad to shstrtab offset
      while fileBuf.Position < Int64(shstrtabOffset) do fileBuf.WriteByte(0);
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
