{$mode objfpc}{$H+}
unit unit_format;

{ Serialisierung und Deserialisierung für vorkompilierte Units (.lyu) }

interface

uses
  SysUtils, Classes, 
  bytes, diag;

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
    procedure Serialize(AUnitName: string; symbols: TLyuxSymbolArray;
      funcCount: Integer; out buffer: TByteBuffer);
  end;

  { Deserializer für .lyu }
  TLyuxDeserializer = class
  private
    FBuffer: TByteBuffer;
    FPos: Integer;
    FDiag: TDiagnostics;

    function ReadString: string;

  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;
    procedure Deserialize(buffer: TByteBuffer; out loaded: TLoadedLyux);
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
  FBuffer.WriteU16LE(32);  { HeaderSize }

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
end;

destructor TLyuxDeserializer.Destroy;
begin
  inherited Destroy;
end;

function TLyuxDeserializer.ReadString: string;
var
  len: Word;
  b: array of Byte;
  i: Integer;
begin
  len := FBuffer.ReadU16LE(FPos);
  SetLength(b, len);
  for i := 0 to len - 1 do
    b[i] := FBuffer.ReadU8(FPos + i);
  Result := TEncoding.UTF8.GetString(b);
  Inc(FPos, len);
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
  if loaded.Header.Version <> LYU_VERSION then
    raise ELyuVersion.CreateFmt('Incompatible .lyu version: %d (expected %d)',
      [loaded.Header.Version, LYU_VERSION]);

  loaded.Header.TargetArch := TLyuxArch(FBuffer.ReadU8(FPos));
  loaded.Header.Flags := FBuffer.ReadU8(FPos);

  loaded.Header.UnitName := ReadString;
  loaded.Header.SymbolCount := FBuffer.ReadU32LE(FPos);
  loaded.Header.TypeInfoOffset := FBuffer.ReadU32LE(FPos);
  loaded.Header.IRCodeOffset := FBuffer.ReadU32LE(FPos);
  loaded.Header.DebugOffset := FBuffer.ReadU32LE(FPos);
  Inc(FPos, 4 + 2);

  SetLength(loaded.Symbols, loaded.Header.SymbolCount);
  for i := 0 to loaded.Header.SymbolCount - 1 do
  begin
    loaded.Symbols[i].Name := ReadString;
    loaded.Symbols[i].Kind := TLyuxSymbolKind(FBuffer.ReadU8(FPos));
    loaded.Symbols[i].TypeHash := FBuffer.ReadU32LE(FPos);
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

end.