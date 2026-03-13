{$mode objfpc}{$H+}
unit elf32_writer;

interface

uses
  SysUtils, Classes, bytes, backend_types;

procedure WriteElf32(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt32);

implementation

function AlignUp(v, a: UInt32): UInt32;
begin
  if a = 0 then
    Result := v
  else
    Result := (v + a - 1) and not (a - 1);
end;

const
  // ELF32 Identification
  EI_NIDENT = 16;

  // ELF32 Types
  ET_NONE   = 0;
  ET_REL    = 1;
  ET_EXEC   = 2;
  ET_DYN    = 3;
  ET_CORE   = 4;

  // ELF32 Machine
  EM_NONE         = 0;
  EM_M32          = 1;
  EM_SPARC        = 2;
  EM_386          = 3;
  EM_68K          = 4;
  EM_88K          = 5;
  EM_860          = 7;
  EM_MIPS         = 8;
  EM_S370         = 9;
  EM_MIPS_RS3_LE  = 10;
  EM_PARISC       = 15;
  EM_VPP500       = 17;
  EM_SPARC32PLUS  = 18;
  EM_960          = 19;
  EM_PPC          = 20;
  EM_PPC64        = 21;
  EM_S390         = 22;
  EM_SPU          = 23;
  EM_V800         = 36;
  EM_FR20         = 37;
  EM_RH32         = 38;
  EM_RCE          = 39;
  EM_ARM          = 40;
  EM_FAKE_ALPHA   = 41;
  EM_SH           = 42;
  EM_SPARCV9      = 43;
  EM_TRICORE      = 44;
  EM_ARC          = 45;
  EM_H8_300       = 46;
  EM_H8_300H      = 47;
  EM_H8S          = 48;
  EM_H8_500       = 49;
  EM_IA_64        = 50;
  EM_MIPS_X       = 51;
  EM_COLDFIRE     = 52;
  EM_68HC12       = 53;
  EM_MMA          = 54;
  EM_PCP          = 55;
  EM_NCPU         = 56;
  EM_NDR1         = 57;
  EM_STARCORE     = 58;
  EM_ME16         = 59;
  EM_ST100        = 60;
  EM_TINYJ        = 61;
  EM_X86_64       = 62;
  EM_PDSP         = 63;
  EM_PDP10        = 64;
  EM_PDP11        = 65;
  EM_FX66         = 66;
  EM_ST9PLUS      = 67;
  EM_ST7          = 68;
  EM_68HC16       = 69;
  EM_68HC11       = 70;
  EM_68HC08       = 71;
  EM_68HC05       = 72;
  EM_SVX          = 73;
  EM_ST19         = 74;
  EM_VAX          = 75;
  EM_CRIS         = 76;
  EM_JAVELIN      = 77;
  EM_FIREPATH     = 78;
  EM_ZSP          = 79;
  EM_MMIX         = 80;
  EM_HUANY        = 81;
  EM_PRAGMATIC    = 82;
  EM_XTENSA       = 93;   // <--- This is what we need for ESP32
  EM_VIDEO        = 94;
  EM_ALPHA        = 95;

  // ELF32 Section Types
  SHT_NULL     = 0;
  SHT_PROGBITS = 1;
  SHT_SYMTAB   = 2;
  SHT_STRTAB   = 3;
  SHT_RELA     = 4;
  SHT_HASH     = 5;
  SHT_DYNAMIC  = 6;
  SHT_NOTE     = 7;
  SHT_NOBITS   = 8;
  SHT_REL      = 9;
  SHT_SHLIB    = 10;
  SHT_DYNSYM   = 11;
  SHT_INIT_ARRAY = 14;
  SHT_FINI_ARRAY = 15;
  SHT_PREINIT_ARRAY = 16;
  SHT_GROUP    = 17;
  SHT_SYMTAB_SHNDX = 18;
  SHT_NUM      = 19;

  // ELF32 Section Flags
  SHF_WRITE     = $1;
  SHF_ALLOC     = $2;
  SHF_EXECINSTR = $4;
  SHF_MERGE     = $8;
  SHF_STRINGS   = $10;
  SHF_INFO_LINK = $20;
  SHF_LINK_ORDER = $40;
  SHF_OS_NONCONFORMING = $80;
  SHF_GROUP     = $100;
  SHF_TLS       = $200;
  SHF_COMPRESSED = $800;
  SHF_MASKOS    = $0ff00000;
  SHF_MASKPROC  = $f0000000;

  // ELF32 Segment Types
  PT_NULL    = 0;
  PT_LOAD    = 1;
  PT_DYNAMIC = 2;
  PT_INTERP  = 3;
  PT_NOTE    = 4;
  PT_SHLIB   = 5;
  PT_PHDR    = 6;
  PT_TLS     = 7;
  PT_NUM     = 8;
  PT_LOOS    = $60000000;
  PT_HIOS    = $6fffffff;
  PT_LOPROC  = $70000000;
  PT_HIPROC  = $7fffffff;

  // ELF32 Segment Flags
  PF_X = $1;   // Execute
  PF_W = $2;   // Write
  PF_R = $4;   // Read

  // ELF32 Header
type
  Elf32_Ehdr = packed record
    e_ident: array[0..EI_NIDENT-1] of Byte;
    e_type: UInt16;
    e_machine: UInt16;
    e_version: UInt32;
    e_entry: UInt32;
    e_phoff: UInt32;
    e_shoff: UInt32;
    e_flags: UInt32;
    e_ehsize: UInt16;
    e_phentsize: UInt16;
    e_phnum: UInt16;
    e_shentsize: UInt16;
    e_shnum: UInt16;
    e_shstrndx: UInt16;
  end;

  Elf32_Phdr = packed record
    p_type: UInt32;
    p_offset: UInt32;
    p_vaddr: UInt32;
    p_paddr: UInt32;
    p_filesz: UInt32;
    p_memsz: UInt32;
    p_flags: UInt32;
    p_align: UInt32;
  end;

  Elf32_Shdr = packed record
    sh_name: UInt32;
    sh_type: UInt32;
    sh_flags: UInt32;
    sh_addr: UInt32;
    sh_offset: UInt32;
    sh_size: UInt32;
    sh_link: UInt32;
    sh_info: UInt32;
    sh_addralign: UInt32;
    sh_entsize: UInt32;
  end;

procedure WriteElf32(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt32);
  var
    f: File of Byte;
    ehdr: Elf32_Ehdr;
    phdr: Elf32_Phdr;
    shdr: Elf32_Shdr;
    offset: UInt32;
    padByte: Byte;
    i: Integer;
  begin
    AssignFile(f, filename);
    Rewrite(f, 1);
    try
      // Initialize ELF header
      FillChar(ehdr, SizeOf(ehdr), 0);
      ehdr.e_ident[0] := $7f;   // Magic number
      ehdr.e_ident[1] := Ord('E');
      ehdr.e_ident[2] := Ord('L');
      ehdr.e_ident[3] := Ord('F');
      ehdr.e_ident[4] := 1;     // 32-bit
      ehdr.e_ident[5] := 1;     // Little endian
      ehdr.e_ident[6] := 1;     // ELF version
      ehdr.e_type := ET_EXEC;
      ehdr.e_machine := EM_XTENSA;
      ehdr.e_version := 1;
      ehdr.e_entry := entryVA;
      ehdr.e_phoff := SizeOf(Elf32_Ehdr);
      ehdr.e_phentsize := SizeOf(Elf32_Phdr);
      ehdr.e_phnum := 2;        // Two program headers: text and data
      ehdr.e_shentsize := SizeOf(Elf32_Shdr);
      ehdr.e_shnum := 0;        // No section headers for simplicity
      ehdr.e_shstrndx := 0;

      // Write ELF header
      BlockWrite(f, ehdr, SizeOf(ehdr));

      // Write program headers
      // First segment: .text (code)
      FillChar(phdr, SizeOf(phdr), 0);
      phdr.p_type := PT_LOAD;
      phdr.p_offset := ehdr.e_phoff + ehdr.e_phnum * SizeOf(Elf32_Phdr);
      phdr.p_vaddr := entryVA; // Entry point is the start of text
      phdr.p_paddr := phdr.p_vaddr;
      phdr.p_filesz := codeBuf.Size;
      phdr.p_memsz := phdr.p_filesz;
      phdr.p_flags := PF_R or PF_X; // Read and execute
      phdr.p_align := $1000; // Page alignment
      BlockWrite(f, phdr, SizeOf(phdr));

      // Second segment: .data (data)
      FillChar(phdr, SizeOf(phdr), 0);
      phdr.p_type := PT_LOAD;
      phdr.p_offset := ehdr.e_phoff + ehdr.e_phnum * SizeOf(Elf32_Phdr) + SizeOf(Elf32_Phdr);
      // Align data segment to page boundary
      phdr.p_vaddr := entryVA + AlignUp(codeBuf.Size, $1000);
      phdr.p_paddr := phdr.p_vaddr;
      phdr.p_filesz := dataBuf.Size;
      phdr.p_memsz := phdr.p_filesz;
      phdr.p_flags := PF_R or PF_W; // Read and write
      phdr.p_align := $1000;
      BlockWrite(f, phdr, SizeOf(phdr));

      // Write code section
      BlockWrite(f, codeBuf.GetBuffer^, codeBuf.Size);

      // Pad to page boundary before data
      offset := ehdr.e_phoff + ehdr.e_phnum * SizeOf(Elf32_Phdr) + codeBuf.Size;
      // Write padding byte (0)
      padByte := 0;
      while (offset mod $1000) <> 0 do
      begin
        BlockWrite(f, padByte, 1);
        Inc(offset);
      end;

      // Write data section
      if dataBuf.Size > 0 then
        BlockWrite(f, dataBuf.GetBuffer^, dataBuf.Size);

      // No section headers for now, but we could add them later

    finally
      CloseFile(f);
    end;
  end;

end.
