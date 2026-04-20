{$mode objfpc}{$H+}
unit unit_format;

{ Serialisierung und Deserialisierung für vorkompilierte Units (.lyu) }

interface

uses
  SysUtils, Classes, 
  bytes, diag, ir, backend_types;

type
  { Target-Architektur für .lyu }
  TLyuxArch = (
    la_x86_64,
    la_arm64,
    la_x86_64_win,
    la_macosx64,
    la_riscv64,
    la_xtensa,
    la_win_arm64,
    la_arm_cm
  );

  { Symbol-Arten in .lyu }
  TLyuxSymbolKind = (
    lskFn,
    lskVar,
    lskLet,
    lskCon,
    lskStruct,
    lskClass,
    lskEnum,
    lskExternFn
  );

  { Fehlercodes für .lyu-Operationen }
  ELyuError = class(Exception);
  ELyuInvalid = class(ELyuError);
  ELyuVersion = class(ELyuError);
  ELYuArch = class(ELyuError);
  ELyuNoSym = class(ELyuError);

  { Header einer .lyu-Datei }
  PLyuxHeader = ^TLyuxHeader;
  TLyuxHeader = record
    Magic: array[0..3] of Char;
    Version: Word;
    TargetArch: TLyuxArch;
    Flags: Byte;
    UnitNameLen: Word;
    UnitName: string;
    SymbolCount: Cardinal;
    TypeInfoOffset: Cardinal;
    IRCodeOffset: Cardinal;
    DebugOffset: Cardinal;
    Reserved: Cardinal;
  end;

  { Ein exportiertes Symbol }
  TLyuxSymbol = record
    Name: string;
    Kind: TLyuxSymbolKind;
    TypeHash: Cardinal;
    TypeInfo: string;
  end;
  TLyuxSymbolArray = array of TLyuxSymbol;

  { Wrapper für eine gelesene .lyu }
  TLoadedLyux = class
  public
    Header: TLyuxHeader;
    Symbols: TLyuxSymbolArray;
    constructor Create;
    destructor Destroy; override;
  end;

  { Serializer für .lyu }
  TLyuxSerializer = class
  private
    FBuffer: TByteBuffer;
    FDiag: TDiagnostics;
    FArch: TLyuxArch;
    FIncludeDebug: Boolean;
    FStrings: TStringList;

    procedure WriteString(const s: string);
    function GetStringIdx(const s: string): Integer;

  public
    constructor Create(d: TDiagnostics; arch: TLyuxArch; includeDebug: Boolean);
    destructor Destroy; override;
    { Simple serializer (for v1 placeholder) }
    procedure Serialize(AUnitName: string; symbols: TLyuxSymbolArray;
      funcCount: Integer; out buffer: TByteBuffer);
    { Full serializer with IR module }
    procedure SerializeModule(IRModule: TIRModule; AUnitName: string; 
      symbols: TLyuxSymbolArray; out buffer: TByteBuffer);
  end;

  { Deserializer für .lyu }
  TLyuxDeserializer = class
  private
    FBuffer: TByteBuffer;
    FPos: Integer;
    FDiag: TDiagnostics;
    FStrings: TStringList;  { String pool for this file }

    function ReadString: string;
    function ReadU32LEAdv: UInt32;

  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;
    procedure Deserialize(buffer: TByteBuffer; out loaded: TLoadedLyux);
    { Deserialize full IR module from buffer }
    function DeserializeModule(buffer: TByteBuffer; out IRModule: TIRModule): Boolean;
  end;

  { Hilfsfunktionen }
  function ArchToStr(arch: TLyuxArch): string;
  function StrToArch(const s: string): TLyuxArch;
  function GetCurrentArch: TLyuxArch;
  function GetCurrentArchStr: string;

implementation

const
  LYU_MAGIC: array[0..3] of Char = ('L', 'Y', 'U', #0);
  LYU_VERSION = 1;

{ TLoadedLyux }

constructor TLoadedLyux.Create;
begin
  inherited Create;
end;

destructor TLoadedLyux.Destroy;
begin
  inherited Destroy;
end;

{ TLyuxSerializer }

constructor TLyuxSerializer.Create(d: TDiagnostics; arch: TLyuxArch; includeDebug: Boolean);
begin
  inherited Create;
  FDiag := d;
  FArch := arch;
  FIncludeDebug := includeDebug;
  FBuffer := TByteBuffer.Create;
  FStrings := TStringList.Create;
  FStrings.Sorted := False;
  FStrings.CaseSensitive := True;
  FStrings.Duplicates := dupIgnore;
end;

destructor TLyuxSerializer.Destroy;
begin
  FBuffer.Free;
  FStrings.Free;
  inherited Destroy;
end;

procedure TLyuxSerializer.WriteString(const s: string);
var
  b: TBytes;
  i: Integer;
begin
  b := TEncoding.UTF8.GetBytes(s);
  FBuffer.WriteU16LE(Length(b));
  for i := 0 to High(b) do
    FBuffer.WriteU8(b[i]);
end;

function TLyuxSerializer.GetStringIdx(const s: string): Integer;
begin
  Result := FStrings.IndexOf(s);
  if Result < 0 then
  begin
    FStrings.Add(s);
    Result := FStrings.Count - 1;
  end;
end;

procedure TLyuxSerializer.Serialize(AUnitName: string;
  symbols: TLyuxSymbolArray; funcCount: Integer; out buffer: TByteBuffer);
var
  i: Integer;
  nameBytes: TBytes;
begin
  FStrings.Clear;

  { Header }
  for i := 0 to 3 do
    FBuffer.WriteU8(Ord(LYU_MAGIC[i]));
  FBuffer.WriteU16LE(LYU_VERSION);
  FBuffer.WriteU8(Ord(FArch));
  FBuffer.WriteU8(Byte(FIncludeDebug));

  nameBytes := TEncoding.UTF8.GetBytes(AUnitName);
  FBuffer.WriteU16LE(Length(nameBytes));
  for i := 0 to High(nameBytes) do
    FBuffer.WriteU8(nameBytes[i]);

  FBuffer.WriteU32LE(Length(symbols));

  { Placeholder für Offsets - für v1 einfach 0 }
  FBuffer.WriteU32LE(0);  { TypeInfoOffset }
  FBuffer.WriteU32LE(0);  { IRCodeOffset }
  FBuffer.WriteU32LE(0);  { DebugOffset }
  FBuffer.WriteU32LE(0);  { Reserved }
  { HeaderSize removed - not read by deserializer }

  { Symbol-Tabelle }
  for i := 0 to High(symbols) do
  begin
    WriteString(symbols[i].Name);
    FBuffer.WriteU8(Ord(symbols[i].Kind));
    FBuffer.WriteU32LE(symbols[i].TypeHash);
    WriteString(symbols[i].TypeInfo);
  end;

  { Strings Section (leer für v1) }
  FBuffer.WriteU32LE(0);

  { Functions Section }
  FBuffer.WriteU32LE(funcCount);

  { Globals Section (leer für v1) }
  FBuffer.WriteU32LE(0);

  { Debug Section }
  if FIncludeDebug then
  begin
    FBuffer.WriteU32LE(0);  { SourceFileCount }
  end;

  buffer := FBuffer;
  FBuffer := nil;
end;

{ TLyuxDeserializer }

constructor TLyuxDeserializer.Create(d: TDiagnostics);
begin
  inherited Create;
  FDiag := d;
  FStrings := TStringList.Create;
  FStrings.Sorted := False;
end;

destructor TLyuxDeserializer.Destroy;
begin
  FStrings.Free;
  inherited Destroy;
end;

function TLyuxDeserializer.ReadString: string;
var
  len: Word;
  b: array of Byte;
  i: Integer;
begin
  len := FBuffer.ReadU16LE(FPos);
  Inc(FPos, 2);  { Advance past length field }
  SetLength(b, len);
  for i := 0 to len - 1 do
  begin
    b[i] := FBuffer.ReadU8(FPos);
    Inc(FPos);
  end;
  Result := TEncoding.UTF8.GetString(b);
end;

function TLyuxDeserializer.ReadU32LEAdv: UInt32;
begin
  Result := FBuffer.ReadU32LE(FPos);
  Inc(FPos, 4);
end;

procedure TLyuxDeserializer.Deserialize(buffer: TByteBuffer; out loaded: TLoadedLyux);
var
  i: Integer;
  magic: array[0..3] of Char;
  nameBytes: TBytes;
begin
  loaded := TLoadedLyux.Create;
  FBuffer := buffer;
  FPos := 0;

  { Magic prüfen }
  for i := 0 to 3 do
  begin
    magic[i] := Char(FBuffer.ReadU8(FPos));
    Inc(FPos);
  end;
  if (magic[0] <> 'L') or (magic[1] <> 'Y') or (magic[2] <> 'U') then
    raise ELyuInvalid.Create('Invalid .lyu file: bad magic');

  loaded.Header.Version := FBuffer.ReadU16LE(FPos);
  Inc(FPos, 2);
  if loaded.Header.Version <> LYU_VERSION then
    raise ELyuVersion.CreateFmt('Incompatible .lyu version: %d (expected %d)',
      [loaded.Header.Version, LYU_VERSION]);

  loaded.Header.TargetArch := TLyuxArch(FBuffer.ReadU8(FPos));
  Inc(FPos);
  loaded.Header.Flags := FBuffer.ReadU8(FPos);
  Inc(FPos);
  loaded.Header.UnitName := ReadString;
  loaded.Header.SymbolCount := ReadU32LEAdv;
  loaded.Header.TypeInfoOffset := ReadU32LEAdv;
  loaded.Header.IRCodeOffset := ReadU32LEAdv;
  loaded.Header.DebugOffset := ReadU32LEAdv;
  Inc(FPos, 4);  { Reserved (4 Bytes) }

  { Bounds check: don't try to read beyond buffer }
  if loaded.Header.SymbolCount > 1000 then
    raise ELyuInvalid.CreateFmt('Invalid .lyu file: suspicious symbol count %d',
      [loaded.Header.SymbolCount]);

  SetLength(loaded.Symbols, loaded.Header.SymbolCount);
  for i := 0 to loaded.Header.SymbolCount - 1 do
  begin
    { Check bounds before reading each symbol }
    if FPos >= FBuffer.Size then
      Break;  { Reached end of buffer - incomplete file, stop reading }
    loaded.Symbols[i].Name := ReadString;
    if FPos >= FBuffer.Size then Break;
    loaded.Symbols[i].Kind := TLyuxSymbolKind(FBuffer.ReadU8(FPos));
    if FPos >= FBuffer.Size then Break;
    loaded.Symbols[i].TypeHash := FBuffer.ReadU32LE(FPos);
    if FPos >= FBuffer.Size then Break;
    loaded.Symbols[i].TypeInfo := ReadString;
  end;
end;

function ArchToStr(arch: TLyuxArch): string;
begin
  case arch of
    la_x86_64:     Result := 'x86_64';
    la_arm64:     Result := 'arm64';
    la_x86_64_win: Result := 'x86_64_win';
    la_macosx64:   Result := 'macosx64';
    la_riscv64:    Result := 'riscv64';
    la_xtensa:     Result := 'xtensa';
    la_win_arm64:  Result := 'win_arm64';
    la_arm_cm:     Result := 'arm_cm';
  else
    Result := 'unknown';
  end;
end;

function StrToArch(const s: string): TLyuxArch;
begin
  if s = 'x86_64' then
    Result := la_x86_64
  else if s = 'arm64' then
    Result := la_arm64
  else if s = 'x86_64_win' then
    Result := la_x86_64_win
  else if s = 'macosx64' then
    Result := la_macosx64
  else if s = 'riscv64' then
    Result := la_riscv64
  else if s = 'xtensa' then
    Result := la_xtensa
  else if s = 'win_arm64' then
    Result := la_win_arm64
  else if s = 'arm_cm' then
    Result := la_arm_cm
  else
    Result := la_x86_64;
end;

function GetCurrentArch: TLyuxArch;
begin
  Result := la_x86_64;
end;

function GetCurrentArchStr: string;
begin
  Result := 'x86_64';
end;

function TLyuxDeserializer.DeserializeModule(buffer: TByteBuffer; out IRModule: TIRModule): Boolean;
var
  i, j, funcCount, instrCount: Integer;
  strIdx: Cardinal;
  fn: TIRFunction;
begin
  Result := False;
  FBuffer := buffer;
  FPos := 0;
  FStrings.Clear;
  
  IRModule := TIRModule.Create;
  
  try
    { Skip header (already validated) }
    Inc(FPos, 32);  { Skip header }
    
    { Skip symbols in this simplified version }
    { Read strings first - use count from file }
    FBuffer.ReadU32LE(FPos);  { string count - ignore }
    while (FPos < FBuffer.Size - 10) and (FPos < 10000) do
    begin
      IRModule.InternString(ReadString);
    end;
    
    { Read functions }
    funcCount := FBuffer.ReadU32LE(FPos);
    for i := 0 to funcCount - 1 do
    begin
      fn := TIRFunction.Create(ReadString);
      fn.ParamCount := FBuffer.ReadU16LE(FPos);
      fn.LocalCount := FBuffer.ReadU16LE(FPos);
      fn.EnergyLevel := TEnergyLevel(FBuffer.ReadU8(FPos));
      
      instrCount := FBuffer.ReadU32LE(FPos);
      SetLength(fn.Instructions, instrCount);
      for j := 0 to instrCount - 1 do
      begin
        fn.Instructions[j].Op := TIROpKind(FBuffer.ReadU16LE(FPos));
        fn.Instructions[j].Dest := FBuffer.ReadU32LE(FPos);
        fn.Instructions[j].Src1 := FBuffer.ReadU32LE(FPos);
        fn.Instructions[j].Src2 := FBuffer.ReadU32LE(FPos);
        fn.Instructions[j].Src3 := FBuffer.ReadU32LE(FPos);
        fn.Instructions[j].ImmInt := FBuffer.ReadU64LE(FPos);
        
        strIdx := FBuffer.ReadU32LE(FPos);
        if (strIdx <> $FFFFFFFF) and (strIdx < Cardinal(FStrings.Count)) then
          fn.Instructions[j].ImmStr := FStrings[strIdx];
        
        strIdx := FBuffer.ReadU32LE(FPos);
        if (strIdx <> $FFFFFFFF) and (strIdx < Cardinal(FStrings.Count)) then
          fn.Instructions[j].LabelName := FStrings[strIdx];
        
        fn.Instructions[j].CallMode := TIRCallMode(FBuffer.ReadU8(FPos));
      end;
      
      IRModule.AddFunction(fn.Name);
      IRModule.Functions[High(IRModule.Functions)].Instructions := fn.Instructions;
      fn.Instructions := nil;
      fn.Free;
    end;
    
    { Skip globals for now }
    Result := True;
    
  except
    IRModule.Free;
    IRModule := nil;
  end;
end;

{ TLyuxSerializer - Full IR Serialization }

procedure TLyuxSerializer.SerializeModule(IRModule: TIRModule; AUnitName: string;
  symbols: TLyuxSymbolArray; out buffer: TByteBuffer);
var
  i, j: Integer;
  nameBytes: TBytes;
  fn: TIRFunction;
begin
  FStrings.Clear;

  { Header }
  for i := 0 to 3 do
    FBuffer.WriteU8(Ord(LYU_MAGIC[i]));
  FBuffer.WriteU16LE(LYU_VERSION);
  FBuffer.WriteU8(Ord(FArch));
  FBuffer.WriteU8(Byte(FIncludeDebug));

  nameBytes := TEncoding.UTF8.GetBytes(AUnitName);
  FBuffer.WriteU16LE(Length(nameBytes));
  for i := 0 to High(nameBytes) do
    FBuffer.WriteU8(nameBytes[i]);

  FBuffer.WriteU32LE(Length(symbols));

  { Placeholder für Offsets }
  FBuffer.WriteU32LE(32);   { TypeInfoOffset - simplified: right after header }
  FBuffer.WriteU32LE(0);   { IRCodeOffset }
  FBuffer.WriteU32LE(0);   { DebugOffset }
  FBuffer.WriteU32LE(0);   { Reserved }
  FBuffer.WriteU16LE(32);  { HeaderSize }

  { Symbol-Tabelle }
  for i := 0 to High(symbols) do
  begin
    WriteString(symbols[i].Name);
    FBuffer.WriteU8(Ord(symbols[i].Kind));
    FBuffer.WriteU32LE(symbols[i].TypeHash);
    WriteString(symbols[i].TypeInfo);
  end;

  { Type-Info Section - count only for now }
  FBuffer.WriteU32LE(0);

  { Strings Section - from IR module }
  FBuffer.WriteU32LE(IRModule.Strings.Count);
  for i := 0 to IRModule.Strings.Count - 1 do
    WriteString(IRModule.Strings[i]);

  { Functions Section - from IR module }
  FBuffer.WriteU32LE(Length(IRModule.Functions));
  for i := 0 to High(IRModule.Functions) do
  begin
    fn := IRModule.Functions[i];
    WriteString(fn.Name);
    FBuffer.WriteU16LE(fn.ParamCount);
    FBuffer.WriteU16LE(fn.LocalCount);
    FBuffer.WriteU8(Ord(fn.EnergyLevel));
    
    { Instructions }
    FBuffer.WriteU32LE(Length(fn.Instructions));
    for j := 0 to High(fn.Instructions) do
    begin
      FBuffer.WriteU16LE(Ord(fn.Instructions[j].Op));
      FBuffer.WriteU32LE(fn.Instructions[j].Dest);
      FBuffer.WriteU32LE(fn.Instructions[j].Src1);
      FBuffer.WriteU32LE(fn.Instructions[j].Src2);
      FBuffer.WriteU32LE(fn.Instructions[j].Src3);
      FBuffer.WriteU64LE(fn.Instructions[j].ImmInt);
      
      { ImmStr as index }
      if fn.Instructions[j].ImmStr <> '' then
        FBuffer.WriteU32LE(GetStringIdx(fn.Instructions[j].ImmStr))
      else
        FBuffer.WriteU32LE($FFFFFFFF);
        
      { LabelName as index }
      if fn.Instructions[j].LabelName <> '' then
        FBuffer.WriteU32LE(GetStringIdx(fn.Instructions[j].LabelName))
      else
        FBuffer.WriteU32LE($FFFFFFFF);
        
      FBuffer.WriteU8(Ord(fn.Instructions[j].CallMode));
    end;
  end;

  { Globals Section }
  FBuffer.WriteU32LE(Length(IRModule.GlobalVars));
  for i := 0 to High(IRModule.GlobalVars) do
  begin
    WriteString(IRModule.GlobalVars[i].Name);
    FBuffer.WriteU64LE(IRModule.GlobalVars[i].InitValue);
    FBuffer.WriteU8(Ord(IRModule.GlobalVars[i].HasInitValue));
    FBuffer.WriteU8(Ord(IRModule.GlobalVars[i].IsArray));
    if IRModule.GlobalVars[i].IsArray then
      FBuffer.WriteU32LE(IRModule.GlobalVars[i].ArrayLen);
  end;

  { Debug Section - empty for now }
  if FIncludeDebug then
    FBuffer.WriteU32LE(0);

  buffer := FBuffer;
  FBuffer := nil;
end;

end.