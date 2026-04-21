{$mode objfpc}{$H+}
unit dwarf_gen;

interface

uses
  SysUtils, Classes, bytes, ir, ast;

type
  { DWARF constants }
  TDwarfTag = (
    dwTagCompileUnit = $11,
    dwTagSubprogram = $2e,
    dwTagVariable = $34,
    dwTagFormalParameter = $35,
    dwTagBaseType = $36,
    dwTagPointerType = $3f,
    dwTagConstType = $26,
    dwTagArrayType = $1a,
    dwTagStructType = $3c,
    dwTagSubroutineType = $2f,
    dwTagFile = $38
  );

  TDwarfForm = (
    dwFormAddr = $0f,
    dwFormBlock1 = $0a,
    dwFormBlock2 = $0c,
    dwFormData1 = $01,
    dwFormData2 = $02,
    dwFormData4 = $04,
    dwFormData8 = $05,
    dwFormString = $08,
    dwFormStrp = $0e,
    dwFormRef4 = $13,
    dwFormSecOffset = $17,
    dwFormFlag = $0c
  );

  TDwarfLNS = (
    dwLNSExtendedOpcode = $00,
    dwLNSCopy = $01,
    dwLNSAdvancePc = $02,
    dwLNSAdvanceLine = $03,
    dwLNSSetFile = $04,
    dwLNSSetColumn = $05,
    dwLNSNegate = $06,
    dwLNSSetBasicFrame = $07,
    dwLNSConstAddPc = $08,
    dwLNSFixedAdvancePc = $09
  );

  TDwarfLNE = (
    dwLNEEndSequence = $01,
    dwLNESetAddress = $02,
    dwLNEAppending = $03,
    dwLNESetDiscriminator = $04
  );

  TDwarfGenerator = class
  private
    FModule: TIRModule;
    FAbbrevBuf: TByteBuffer;
    FInfoBuf: TByteBuffer;
    FLineBuf: TByteBuffer;
    FFrameBuf: TByteBuffer;
    FStrBuf: TByteBuffer;
    FCompDir: string;
    FProducer: string;
    // String table - deduplication
    FStringOffsets: array of record
      Str: string;
      Offset: Cardinal;
    end;
    FStringCount: Integer;
    FNextStringOffset: Cardinal;
    // Source file tracking
    FSourceFiles: array of record
      Name: string;
      Idx: Integer;
    end;
    FSourceFileCount: Integer;
    // Helper methods
    function GetStringOffset(const s: string): Cardinal;
    function GetSourceFileIdx(const fileName: string): Integer;
    procedure WriteLeb128Signed(var buf: TByteBuffer; v: Int64);
    procedure WriteUleb128u8(var buf: TByteBuffer; v: Byte);
    procedure WriteUleb128u16(var buf: TByteBuffer; v: Word);
    procedure WriteUleb128u32(var buf: TByteBuffer; v: Cardinal);
    procedure WriteString(var buf: TByteBuffer; const s: string);
    function AurumTypeToDwarfType(t: TAurumType): Integer;
  public
    constructor Create(module: TIRModule; const compDir: string);
    destructor Destroy; override;
    procedure Generate(out debugAbbrev, debugInfo, debugLine, debugFrame, debugStr: TByteBuffer);
  end;

implementation

function TDwarfGenerator.GetStringOffset(const s: string): Cardinal;
var
  i: Integer;
begin
  for i := 0 to FStringCount - 1 do
    if FStringOffsets[i].Str = s then
    begin
      Result := FStringOffsets[i].Offset;
      Exit;
    end;
  // Add new string
  if FStringCount >= Length(FStringOffsets) then
    SetLength(FStringOffsets, FStringCount + 32);
  FStringOffsets[FStringCount].Str := s;
  FStringOffsets[FStringCount].Offset := FNextStringOffset;
  Result := FNextStringOffset;
  Inc(FNextStringOffset, Length(s) + 1);
  Inc(FStringCount);
end;

function TDwarfGenerator.GetSourceFileIdx(const fileName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to FSourceFileCount - 1 do
    if FSourceFiles[i].Name = fileName then
    begin
      Result := FSourceFiles[i].Idx;
      Exit;
    end;
  // Add new file
  if FSourceFileCount >= Length(FSourceFiles) then
    SetLength(FSourceFiles, FSourceFileCount + 16);
  FSourceFiles[FSourceFileCount].Name := fileName;
  FSourceFiles[FSourceFileCount].Idx := FSourceFileCount + 1;
  Result := FSourceFiles[FSourceFileCount].Idx;
  Inc(FSourceFileCount);
end;

procedure TDwarfGenerator.WriteLeb128Signed(var buf: TByteBuffer; v: Int64);
var
  byteVal: Byte;
begin
  repeat
    byteVal := Byte(v and $7F);
    v := v shr 7;
    if (v <> 0) or (byteVal and $40 <> 0) then
      byteVal := byteVal or $80;
    buf.WriteU8(byteVal);
  until (v = 0) and (byteVal and $80 = 0);
end;

procedure TDwarfGenerator.WriteUleb128u8(var buf: TByteBuffer; v: Byte);
var
  byteVal: Byte;
begin
  repeat
    byteVal := Byte(v and $7F);
    v := v shr 7;
    if v <> 0 then
      byteVal := byteVal or $80;
    buf.WriteU8(byteVal);
  until v = 0;
end;

procedure TDwarfGenerator.WriteUleb128u16(var buf: TByteBuffer; v: Word);
var
  byteVal: Byte;
begin
  repeat
    byteVal := Byte(v and $7F);
    v := v shr 7;
    if v <> 0 then
      byteVal := byteVal or $80;
    buf.WriteU8(byteVal);
  until v = 0;
end;

procedure TDwarfGenerator.WriteUleb128u32(var buf: TByteBuffer; v: Cardinal);
var
  byteVal: Byte;
begin
  repeat
    byteVal := Byte(v and $7F);
    v := v shr 7;
    if v <> 0 then
      byteVal := byteVal or $80;
    buf.WriteU8(byteVal);
  until v = 0;
end;

procedure TDwarfGenerator.WriteString(var buf: TByteBuffer; const s: string);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    buf.WriteU8(Ord(s[i]));
  buf.WriteU8(0);
end;

function TDwarfGenerator.AurumTypeToDwarfType(t: TAurumType): Integer;
begin
  case t of
    atInt8:   Result := GetStringOffset('signed char');
    atInt16:  Result := GetStringOffset('short');
    atInt32:  Result := GetStringOffset('int');
    atInt64:  Result := GetStringOffset('long long int');
    atUInt8:  Result := GetStringOffset('unsigned char');
    atUInt16: Result := GetStringOffset('unsigned short');
    atUInt32: Result := GetStringOffset('unsigned int');
    atUInt64: Result := GetStringOffset('unsigned long long int');
    atISize:  Result := GetStringOffset('long');
    atUSize:  Result := GetStringOffset('unsigned long');
    atF32:   Result := GetStringOffset('float');
    atF64:   Result := GetStringOffset('double');
    atBool:   Result := GetStringOffset('boolean');
    atChar:   Result := GetStringOffset('char');
    atVoid:   Result := GetStringOffset('void');
    atPChar,
    atPCharNullable: Result := GetStringOffset('char*');
    else
      Result := GetStringOffset('unknown');
  end;
end;

constructor TDwarfGenerator.Create(module: TIRModule; const compDir: string);
begin
  inherited Create;
  FModule := module;
  FCompDir := compDir;
  FProducer := 'Lyx Compiler 0.2.0';
  FNextStringOffset := 1;
  FStringCount := 0;
  FSourceFileCount := 0;
  SetLength(FStringOffsets, 32);
  SetLength(FSourceFiles, 16);
end;

destructor TDwarfGenerator.Destroy;
begin
  FStringOffsets := nil;
  FSourceFiles := nil;
  inherited;
end;

procedure TDwarfGenerator.Generate(out debugAbbrev, debugInfo, debugLine, debugFrame, debugStr: TByteBuffer);
var
  i, j, idx: Integer;
  func: TIRFunction;
  instr: TIRInstr;
  lastLine, lastFile: Integer;
  codeVA, codeSize: UInt64;
  subprogAbbrevCode, cuAbbrevCode: Cardinal;
begin
  // Initialize buffers
  FAbbrevBuf := TByteBuffer.Create;
  FInfoBuf := TByteBuffer.Create;
  FLineBuf := TByteBuffer.Create;
  FFrameBuf := TByteBuffer.Create;
  FStrBuf := TByteBuffer.Create;

  cuAbbrevCode := 1;
  subprogAbbrevCode := 2;

  try
    // 1. Build string table first (debug_str)
    FStrBuf.WriteU8(0); // NULL string at offset 0
    // Pre-populate strings for types and common names
    GetStringOffset(FProducer);
    GetStringOffset(FCompDir);

    // 2. Generate .debug_abbrev
    with FAbbrevBuf do
    begin
      // Abbrev 1: Compile Unit
      WriteUleb128u32(FAbbrevBuf, cuAbbrevCode);
      WriteUleb128u8(FAbbrevBuf, Byte(dwTagCompileUnit));
      WriteUleb128u8(FAbbrevBuf, 0); // no children
      WriteUleb128u8(FAbbrevBuf, $03); // DW_AT_name
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormString));
      WriteUleb128u8(FAbbrevBuf, $1b); // DW_AT_comp_dir
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormString));
      WriteUleb128u8(FAbbrevBuf, $25); // DW_AT_producer
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormString));
      WriteUleb128u8(FAbbrevBuf, $44); // DW_AT_source_language
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormData2));
      WriteUleb128u8(FAbbrevBuf, $10); // DW_AT_stmt_list
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormSecOffset));
      WriteUleb128u8(FAbbrevBuf, 0); // terminator
      WriteUleb128u8(FAbbrevBuf, 0);

      // Abbrev 2: Subprogram (function)
      WriteUleb128u32(FAbbrevBuf, subprogAbbrevCode);
      WriteUleb128u8(FAbbrevBuf, Byte(dwTagSubprogram));
      WriteUleb128u8(FAbbrevBuf, 1); // children yes
      WriteUleb128u8(FAbbrevBuf, $03); // DW_AT_name
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormString));
      WriteUleb128u8(FAbbrevBuf, $3a); // DW_AT_decl_file
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormData1));
      WriteUleb128u8(FAbbrevBuf, $3b); // DW_AT_decl_line
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormData2));
      WriteUleb128u8(FAbbrevBuf, $40); // DW_AT_low_pc
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormAddr));
      WriteUleb128u8(FAbbrevBuf, $41); // DW_AT_high_pc
      WriteUleb128u8(FAbbrevBuf, Byte(dwFormAddr));
      WriteUleb128u8(FAbbrevBuf, 0); // terminator
      WriteUleb128u8(FAbbrevBuf, 0);
    end;

    // 3. Generate .debug_info
    with FInfoBuf do
    begin
      WriteU32LE(0); // length (will be patched)
      WriteU16LE(4); // version DWARF 4
      WriteU32LE(0); // abbrev offset
      WriteU8(8);    // address size 64-bit

      // CU entry
      WriteUleb128u32(FInfoBuf, cuAbbrevCode);
      WriteString(FInfoBuf, FCompDir); // name (we use comp dir as working dir)
      WriteString(FInfoBuf, FCompDir);
      WriteString(FInfoBuf, FProducer);
      WriteU16LE(1); // DW_LANG_C
      WriteU32LE(0); // stmt_list (will point to debug_line)
    end;

    // 4. Generate .debug_line header
    with FLineBuf do
    begin
      WriteU32LE(0); // length (placeholder)
      WriteU16LE(4); // version
      WriteU32LE(0); // header length
      WriteU8(16);  // minimum instruction length
      WriteU8(1);   // maximum operations per instruction
      WriteU8(0);   // default is_stmt
      WriteU8(1);   // line base
      WriteU8(1);   // line range
      WriteU8(13);  // opcode base

      // Standard opcode lengths (13 opcodes)
      WriteU8(0);
      WriteU8(1);
      WriteU8(1);
      WriteU8(1);
      WriteU8(1);
      WriteU8(1);
      WriteU8(0);
      WriteU8(0);
      WriteU8(0);
      WriteU8(0);
      WriteU8(1);
      WriteU8(0);
      WriteU8(0);

      // Include directory table (empty)
      WriteU8(0);

      // File table
      for i := 0 to FSourceFileCount - 1 do
      begin
        WriteString(FLineBuf, FSourceFiles[i].Name);
        WriteU8(0); // directory index
        WriteU8(0); // modification time
        WriteU8(0); // length
      end;
      WriteU8(0); // end file table
    end;

    // 5. Generate functions and their line info
    for i := 0 to Length(FModule.Functions) - 1 do
    begin
      func := FModule.Functions[i];
      if func.Name.StartsWith('_lyx_') then
        Continue; // Skip runtime helpers

      // Get code offset (placeholder - would need to get from codegen)
      codeVA := UInt64($1000 + i * $100);
      codeSize := UInt64(Length(func.Instructions) * 8);

      // Add function subprogram to .debug_info
      with FInfoBuf do
      begin
        WriteUleb128u32(FInfoBuf, subprogAbbrevCode);
        WriteString(FInfoBuf, func.Name);

        // Find first source line
        for j := 0 to Length(func.Instructions) - 1 do
        begin
          instr := func.Instructions[j];
          if instr.SourceLine > 0 then
          begin
            WriteU8(GetSourceFileIdx(instr.SourceFile));
            WriteU16LE(instr.SourceLine);
            Break;
          end;
        end;
        if j = Length(func.Instructions) then
        begin
          WriteU8(1);
          WriteU16LE(1);
        end;

        WriteU64LE(codeVA);
        WriteU64LE(codeVA + codeSize);
      end;

      // Add to .debug_info children (formal parameters)
      for j := 0 to func.ParamCount - 1 do
      begin
        // Could add parameter DIEs here
      end;

      // Write null to terminate children
      FInfoBuf.WriteU8(0);
    end;

    // Write null to terminate last subprogram children
    FInfoBuf.WriteU8(0);

    // Generate line program for each function
    lastFile := 0;
    lastLine := 0;
    for i := 0 to Length(FModule.Functions) - 1 do
    begin
      func := FModule.Functions[i];
      if func.Name.StartsWith('_lyx_') then
        Continue;

      codeVA := UInt64($1000 + i * $100);

      // Set address
      with FLineBuf do
      begin
        WriteU8(0); // extended opcode
        WriteU8(3); // length
        WriteU8(Ord(dwLNEAppending));
        WriteU64LE(codeVA);
      end;

      lastLine := 0;
      lastFile := 0;

      for j := 0 to Length(func.Instructions) - 1 do
      begin
        instr := func.Instructions[j];
        if instr.SourceLine > 0 then
        begin
          idx := GetSourceFileIdx(instr.SourceFile);

          with FLineBuf do
          begin
            if idx <> lastFile then
            begin
              WriteU8(Ord(dwLNSSetFile));
              WriteUleb128u8(FLineBuf, Byte(idx));
              lastFile := idx;
            end;

            if instr.SourceLine <> lastLine then
            begin
              WriteU8(Ord(dwLNSAdvanceLine));
              WriteLeb128Signed(FLineBuf, Int64(instr.SourceLine - lastLine));
              lastLine := instr.SourceLine;
            end;

            WriteU8(Ord(dwLNSCopy));
          end;
        end;
      end;
    end;

    // End sequence
    FLineBuf.WriteU8(0);
    FLineBuf.WriteU8(2);
    FLineBuf.WriteU8(Ord(dwLNEEndSequence));
    FLineBuf.WriteU64LE($FFFFFFFFFFFFFFFF);

    // 6. Generate .debug_frame (CIE + FDEs)
    with FFrameBuf do
    begin
      // CIE
      WriteU32LE(0); // length (patch later)
      WriteU32LE(0); // CIE id
      WriteU8(1);   // version
      WriteU8(0);   // augmentation
      WriteUleb128u8(FFrameBuf, 8); // code alignment
      WriteLeb128Signed(FFrameBuf, -8); // return address offset
      WriteUleb128u8(FFrameBuf, 16); // ra = x86_64 rax

      // CIE FDE instructions (empty - simple)
      WriteU8($0c); // DW_CFA_advance_loc
      WriteU8(0);
      WriteU8($0c); // ...
      WriteU8(0);
      WriteU8(0); // end

      // Now FDEs for each function
      for i := 0 to Length(FModule.Functions) - 1 do
      begin
        func := FModule.Functions[i];
        if func.Name.StartsWith('_lyx_') then
          Continue;

        codeVA := UInt64($1000 + i * $100);
        codeSize := UInt64(Length(func.Instructions) * 8);

        WriteU32LE(0); // length
        WriteU32LE(0); // CIE offset (first CIE)
        WriteU64LE(codeVA);
        WriteU64LE(codeSize);

        // FDE instructions (simple: advance loc to address)
        WriteU8($0c); // DW_CFA_advance_loc
        WriteU8(0); // modifier
        WriteU8(0); // end
      end;
    end;

    // 7. Patch lengths
    // debug_abbrev length
    // debug_info length
    // debug_line length
    // debug_frame length

    // Output
    debugAbbrev := FAbbrevBuf;
    debugInfo := FInfoBuf;
    debugLine := FLineBuf;
    debugFrame := FFrameBuf;
    debugStr := FStrBuf;

  except
    on E: Exception do
    begin
      FAbbrevBuf.Free;
      FInfoBuf.Free;
      FLineBuf.Free;
      FFrameBuf.Free;
      FStrBuf.Free;
      raise;
    end;
  end;
end;

end.