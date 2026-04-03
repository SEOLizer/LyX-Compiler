{$mode objfpc}{$H+}
unit elf64_riscv_writer;

interface

uses
  SysUtils, Classes, bytes;

procedure WriteElf64RISCV(const fileName: string; codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);

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

end.
