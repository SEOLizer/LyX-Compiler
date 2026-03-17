{$mode objfpc}{$H+}
unit elf64_arm64_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

procedure WriteElf64ARM64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);

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

end.
