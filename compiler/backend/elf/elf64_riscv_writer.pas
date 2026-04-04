{$mode objfpc}{$H+}
unit elf64_riscv_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

procedure WriteElf64RISCV(const fileName: string; codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
procedure WriteElf64RISCVWithMetaSafe(const fileName: string; codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const integrity: TIntegrityAttr);

implementation

const
  // ELF Header constants
  ELF_MAGIC: array[0..3] of Byte = ($7F, $45, $4C, $46);  // \x7FELF
  ELFCLASS64 = 2;
  ELFDATA2LSB = 1;  // Little-endian
  EV_CURRENT = 1;
  ET_EXEC = 2;
  EM_RISCV = 243;  // RISC-V machine type
  PT_LOAD = 1;
  PF_X = 1;
  PF_W = 2;
  PF_R = 4;

procedure WriteElf64RISCV(const fileName: string; codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);
var
  f: TFileStream;
  codeSize, dataSize, codeOffset, dataOffset: Integer;
  codeVA, dataVA: UInt64;
  phOff, phNum: Integer;
  padByte: Byte;
begin
  codeSize := codeBuf.Size;
  dataSize := dataBuf.Size;
  
  // Align to page boundaries
  codeOffset := 4096;
  dataOffset := 4096 + ((codeSize + 4095) and not 4095);
  codeVA := entryVA;
  dataVA := entryVA + UInt64((codeSize + 4095) and not 4095);
  
  phOff := 64;  // ELF header size
  phNum := 2;   // Two PT_LOAD segments
  
  f := TFileStream.Create(fileName, fmCreate);
  try
    // ELF Header (64 bytes)
    f.WriteBuffer(ELF_MAGIC, 4);
    f.WriteByte(ELFCLASS64);
    f.WriteByte(ELFDATA2LSB);
    f.WriteByte(EV_CURRENT);
    padByte := 0;
    f.WriteBuffer(padByte, 9);  // Padding: EI_OSABI(1) + EI_ABIVERSION(1) + EI_PAD(7)
    f.WriteWord(ET_EXEC);       // e_type
    f.WriteWord(EM_RISCV);      // e_machine
    f.WriteDWord(EV_CURRENT);   // e_version
    f.WriteQWord(entryVA);      // e_entry
    f.WriteQWord(phOff);        // e_phoff
    f.WriteQWord(0);            // e_shoff (no section headers)
    f.WriteDWord(0);            // e_flags
    f.WriteWord(64);            // e_ehsize
    f.WriteWord(56);            // e_phentsize
    f.WriteWord(phNum);         // e_phnum
    f.WriteWord(0);             // e_shentsize
    f.WriteWord(0);             // e_shnum
    f.WriteWord(0);             // e_shstrndx
    
    // Padding to code offset
    while f.Position < codeOffset do
      f.WriteByte(0);
    
    // Code segment
    if codeSize > 0 then
      f.WriteBuffer(codeBuf.GetBuffer^, codeSize);
    
    // Padding to data offset
    while f.Position < dataOffset do
      f.WriteByte(0);
    
    // Data segment
    if dataSize > 0 then
      f.WriteBuffer(dataBuf.GetBuffer^, dataSize);
    
    // Program Headers (written after data, but offset is at phOff)
    // We need to seek back and write them
    f.Position := phOff;
    
    // Code segment PT_LOAD
    f.WriteDWord(PT_LOAD);       // p_type
    f.WriteDWord(PF_X or PF_R);  // p_flags
    f.WriteQWord(codeVA);        // p_vaddr
    f.WriteQWord(codeVA);        // p_paddr
    f.WriteQWord(codeSize);      // p_filesz
    f.WriteQWord(codeSize);      // p_memsz
    f.WriteQWord(4096);          // p_align
    
    // Data segment PT_LOAD
    f.WriteDWord(PT_LOAD);       // p_type
    f.WriteDWord(PF_W or PF_R);  // p_flags
    f.WriteQWord(dataVA);        // p_vaddr
    f.WriteQWord(dataVA);        // p_paddr
    f.WriteQWord(dataSize);      // p_filesz
    f.WriteQWord(dataSize);      // p_memsz
    f.WriteQWord(4096);          // p_align
    
  finally
    f.Free;
  end;
end;

// RISC-V .meta_safe ELF writer (aerospace-todo P0 #44)
procedure WriteElf64RISCVWithMetaSafe(const fileName: string; codeBuf, dataBuf: TByteBuffer;
  entryVA: UInt64; const integrity: TIntegrityAttr);
var
  f: TFileStream;
  pageSize: UInt64;
  codeOffset, metaSafeOff, shStrTabOff, shdrsOff: UInt64;
  codeSize, metaSafeSize, shStrTabSize: UInt64;
  codeStartVA, codeEndVA: UInt64;
  baseVA: UInt64;
  numShdrs: Integer;
  shdrSize: UInt64;
  metaSafeSec, shStrTab: TByteBuffer;
  SHStr_text_off, SHStr_shstrtab_off, SHStr_metasafe_off: Integer;
  modeVal: UInt32;
  hashCrc: UInt32;
  POLY: UInt32;
  crc: UInt32;
  i, j: Integer;
  b: Byte;
  p: PByte;
  filesz: UInt64;

  procedure WriteU8(v: Byte); begin f.WriteByte(v); end;
  procedure WriteU16(v: Word); var w: Word; begin w := LEToN(v); f.WriteBuffer(w, 2); end;
  procedure WriteU32(v: UInt32); var d: UInt32; begin d := LEToN(v); f.WriteBuffer(d, 4); end;
  procedure WriteU64(v: UInt64); var q: UInt64; begin q := LEToN(v); f.WriteBuffer(q, 8); end;
  procedure PadTo(off: UInt64); begin while f.Position < Int64(off) do f.WriteByte(0); end;
begin
  pageSize   := 4096;
  baseVA     := $400000;
  codeSize   := codeBuf.Size;
  codeOffset := pageSize;
  codeStartVA := baseVA + codeOffset;
  codeEndVA   := codeStartVA + codeSize;
  shdrSize   := 64;

  POLY := $EDB88320; crc := $FFFFFFFF;
  p := PByte(codeBuf.GetBuffer);
  for i := 0 to Integer(codeSize) - 1 do
  begin
    b := p^; Inc(p);
    for j := 0 to 7 do
    begin
      if ((crc xor b) and 1) <> 0 then crc := (crc shr 1) xor POLY
      else crc := crc shr 1;
      b := b shr 1;
    end;
  end;
  hashCrc := crc xor $FFFFFFFF;

  case integrity.Mode of
    imSoftwareLockstep: modeVal := 1;
    imScrubbed:         modeVal := 2;
    imHardwareEcc:      modeVal := 3;
  else modeVal := 0;
  end;

  metaSafeSec := TByteBuffer.Create;
  metaSafeSec.WriteU64LE(codeStartVA); metaSafeSec.WriteU64LE(codeEndVA);
  metaSafeSec.WriteU32LE(modeVal); metaSafeSec.WriteU32LE(UInt32(integrity.Interval));
  metaSafeSec.WriteU64LE(0);
  metaSafeSec.WriteU32LE(hashCrc); for i := 1 to 4092 do metaSafeSec.WriteU8(0);
  metaSafeSec.WriteU32LE(hashCrc); for i := 1 to 4092 do metaSafeSec.WriteU8(0);
  metaSafeSec.WriteU32LE(hashCrc); metaSafeSec.WriteU32LE(0);
  metaSafeSize := metaSafeSec.Size;

  shStrTab := TByteBuffer.Create;
  shStrTab.WriteU8(0);
  SHStr_text_off := shStrTab.Size;
  shStrTab.WriteBytes([Ord('.'),Ord('t'),Ord('e'),Ord('x'),Ord('t'),0]);
  SHStr_shstrtab_off := shStrTab.Size;
  shStrTab.WriteBytes([Ord('.'),Ord('s'),Ord('h'),Ord('s'),Ord('t'),
    Ord('r'),Ord('t'),Ord('a'),Ord('b'),0]);
  SHStr_metasafe_off := shStrTab.Size;
  shStrTab.WriteBytes([Ord('.'),Ord('m'),Ord('e'),Ord('t'),Ord('a'),Ord('_'),
    Ord('s'),Ord('a'),Ord('f'),Ord('e'),0]);
  shStrTabSize := shStrTab.Size;

  metaSafeOff := codeOffset + codeSize;
  if (metaSafeOff mod 8) <> 0 then metaSafeOff := metaSafeOff + (8 - (metaSafeOff mod 8));
  shStrTabOff := metaSafeOff + metaSafeSize;
  if (shStrTabOff mod 8) <> 0 then shStrTabOff := shStrTabOff + (8 - (shStrTabOff mod 8));
  shdrsOff := shStrTabOff + shStrTabSize;
  if (shdrsOff mod 8) <> 0 then shdrsOff := shdrsOff + (8 - (shdrsOff mod 8));
  numShdrs := 4;
  filesz := shdrsOff - codeOffset + numShdrs * shdrSize;

  f := TFileStream.Create(fileName, fmCreate);
  try
    f.WriteBuffer(ELF_MAGIC, 4);
    WriteU8(ELFCLASS64); WriteU8(ELFDATA2LSB); WriteU8(EV_CURRENT); WriteU8(0);
    for i := 1 to 8 do WriteU8(0);
    WriteU16(ET_EXEC); WriteU16(EM_RISCV); WriteU32(EV_CURRENT);
    WriteU64(entryVA); WriteU64(64); WriteU64(shdrsOff);
    WriteU32(4 {EF_RISCV_FLOAT_ABI_DOUBLE}); WriteU16(64); WriteU16(56);
    WriteU16(1); WriteU16(Word(shdrSize)); WriteU16(numShdrs); WriteU16(2);
    // PT_LOAD
    WriteU32(PT_LOAD); WriteU32(PF_R or PF_W or PF_X);
    WriteU64(codeOffset); WriteU64(codeStartVA); WriteU64(codeStartVA);
    WriteU64(filesz); WriteU64(filesz); WriteU64(pageSize);
    PadTo(codeOffset);
    if codeSize > 0 then f.WriteBuffer(codeBuf.GetBuffer^, codeSize);
    PadTo(metaSafeOff); f.WriteBuffer(metaSafeSec.GetBuffer^, metaSafeSize);
    PadTo(shStrTabOff); f.WriteBuffer(shStrTab.GetBuffer^, shStrTabSize);
    PadTo(shdrsOff);
    // NULL shdr
    for i := 1 to 64 do WriteU8(0);
    // .text shdr
    WriteU32(SHStr_text_off); WriteU32(1 {PROGBITS}); WriteU64(6 {ALLOC|EXEC});
    WriteU64(codeStartVA); WriteU64(codeOffset); WriteU64(codeSize);
    WriteU32(0); WriteU32(0); WriteU64(4); WriteU64(0);
    // .shstrtab shdr
    WriteU32(SHStr_shstrtab_off); WriteU32(3 {STRTAB}); WriteU64(0); WriteU64(0);
    WriteU64(shStrTabOff); WriteU64(shStrTabSize); WriteU32(0); WriteU32(0); WriteU64(1); WriteU64(0);
    // .meta_safe shdr
    WriteU32(SHStr_metasafe_off); WriteU32(1 {PROGBITS}); WriteU64(0); WriteU64(0);
    WriteU64(metaSafeOff); WriteU64(metaSafeSize); WriteU32(0); WriteU32(0); WriteU64(8); WriteU64(0);
  finally
    f.Free; metaSafeSec.Free; shStrTab.Free;
  end;
end;

end.
