{$mode objfpc}{$H+}
unit unit_format;

{ Serialisierung und Deserialisierung für vorkompilierte Units (.lyu) }

interface

uses
  SysUtils, Classes, 
  ast, ir, bytes, diag;

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
    lskFn,       { pub fn }
    lskVar,      { pub var }
    lskLet,      { pub let }
    lskCon,      { pub con }
    lskStruct,   { pub struct }
    lskClass,    { pub class }
    lskEnum,     { pub enum }
    lskExternFn  { pub extern fn }
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
    Magic: array[0..3] of Char;  { 'LYU' + #0 }
    Version: Word;
    TargetArch: TLyuxArch;
    Flags: Byte;       { bit 0: hasDebug }
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
    TypeInfo: string;  { serialisierte Typ-Info }
  end;
  TLyuxSymbolArray = array of TLyuxSymbol;

  { serialisierte Class-Info }
  TLyuxClassInfo = record
    Name: string;
    BaseClassName: string;
    MethodCount: Integer;
    Methods: array of record
      Name: string;
      ReturnType: string;
      ParamCount: Integer;
      ParamTypes: string;
      IsVirtual: Boolean;
      VMTIndex: Integer;
    end;
  end;

  { Wrapper für eine gelesene .lyu }
  TLoadedLyux = class
  public
    Header: TLyuxHeader;
    Symbols: TLyuxSymbolArray;
    Strings: TStringList;
    Functions: TStringList;  { Name -> IR }

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
    FStrings: TStringList;  { String -> Index }

    procedure WriteString(const s: string);
    function GetStringIdx(const s: string): Integer;
    procedure WriteType(t: TAurumType);
    procedure WriteStructDecl(sd: TAstStructDecl);
    procedure WriteClassDecl(cd: TAstClassDecl);
    procedure WriteEnumDecl(ed: TAstEnumDecl);
    procedure WriteFunction(fn: TIRFunction);
    procedure WriteInstr(instr: TIRInstr);
    procedure WriteModule(mod: TIRModule; symbols: TLyuxSymbolArray);
    function ComputeTypeHash(t: TAurumType): Cardinal;

  public
    constructor Create(d: TDiagnostics; arch: TLyuxArch; includeDebug: Boolean);
    destructor Destroy; override;
    procedure Serialize(mod: TIRModule; const unitName: string; symbols: TLyuxSymbolArray;
      out buffer: TByteBuffer);
  end;

  { Deserializer für .lyu }
  TLyuxDeserializer = class
  private
    FBuffer: TByteBuffer;
    FPos: Integer;
    FDiag: TDiagnostics;

    function ReadString: string;
    function ReadType: TAurumType;
    function ReadStructDecl: TAstStructDecl;
    function ReadClassDecl: TAstClassDecl;
    function ReadEnumDecl: TAstEnumDecl;
    function ReadFunction: TIRFunction;
    function ReadInstr: TIRInstr;
    procedure ReadModule(out mod: TIRModule; out symbols: TLyuxSymbolArray);

    function CharToKind(c: Char): TLyuxSymbolKind;

  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;
    procedure Deserialize(buffer: TByteBuffer; out loaded: TLoadedLyux);
  end;

  { Hilfsfunktionen }
  function ArchToStr(arch: TLyuxArch): string;
  function StrToArch(const s: string): TLyuxArch;
  function GetCurrentArch: TLyuxArch;

implementation

{ Konstanten }
const
  LYU_MAGIC: array[0..3] of Char = ('L', 'Y', 'U', #0);
  LYU_VERSION = 1;

{ TLoadedLyux }

constructor TLoadedLyux.Create;
begin
  inherited Create;
  Strings := TStringList.Create;
  Strings.Sorted := False;
  Strings.CaseSensitive := True;
  Strings.Duplicates := dupIgnore;
  Functions := TStringList.Create;
  Functions.Sorted := False;
end;

destructor TLoadedLyux.Destroy;
begin
  Strings.Free;
  Functions.Free;
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

function TLyuxSerializer.ComputeTypeHash(t: TAurumType): Cardinal;
var
  s: string;
begin
  { Einfache Hash-Funktion: basierend auf Typ-String }
  s := '';
  case t of
    atInt64:      s := 'int64';
    atBool:      s := 'bool';
    atVoid:      s := 'void';
    atPChar:     s := 'pchar';
    atPCharNull: s := 'pchar?';
    atF32:       s := 'f32';
    atF64:       s := 'f64';
    atDynArray:  s := 'dynarray';
    atArray:     s := 'array';
    atStruct:    s := 'struct';
    atClass:     s := 'class';
    atEnum:      s := 'enum';
    atMap:       s := 'Map';
    atSet:       s := 'Set';
    atParallelArray: s := 'parallel';
  else
    s := 'unknown';
  end;
  { FNV-1a Hash }
  Result := 2166136261;
  for i := 1 to Length(s) do
  begin
    Result := Result xor Ord(s[i]);
    Result := Result * 16777619;
  end;
end;

procedure TLyuxSerializer.WriteType(t: TAurumType);
begin
  FBuffer.WriteU8(Ord(t));
  { Bei komplexen Typen müssten wir hier weitere Daten schreiben }
  { Für atDynArray, atArray, atStruct, atClass, atMap, atSet müsste der Element- }
  { bzw. Key/Value-Typ serialisiert werden - vereinfacht für v1 }
end;

procedure TLyuxSerializer.WriteStructDecl(sd: TAstStructDecl);
var
  i: Integer;
begin
  WriteString(sd.Name);
  FBuffer.WriteU32LE(Length(sd.Fields));
  for i := 0 to High(sd.Fields) do
  begin
    WriteString(sd.Fields[i].Name);
    WriteType(sd.Fields[i].DeclType);
    FBuffer.WriteU32LE(sd.FieldOffsets[i]);
    FBuffer.WriteU32LE(sd.Fields[i].Size);
  end;
end;

procedure TLyuxSerializer.WriteClassDecl(cd: TAstClassDecl);
var
  i: Integer;
begin
  WriteString(cd.Name);
  WriteString(cd.BaseClassName);
  FBuffer.WriteU32LE(Length(cd.Methods));
  for i := 0 to High(cd.Methods) do
  begin
    WriteString(cd.Methods[i].Name);
    WriteType(cd.Methods[i].ReturnType);
    FBuffer.WriteU32LE(cd.Methods[i].ParamCount);
    { ParamTypes serialisieren - vereinfacht }
    FBuffer.WriteU8(Ord(cd.Methods[i].IsVirtual));
    FBuffer.WriteU32LE(cd.Methods[i].VMTIndex);
  end;
end;

procedure TLyuxSerializer.WriteEnumDecl(ed: TAstEnumDecl);
var
  i: Integer;
begin
  WriteString(ed.Name);
  FBuffer.WriteU32LE(Length(ed.Values));
  for i := 0 to High(ed.Values) do
  begin
    WriteString(ed.Values[i].Name);
    FBuffer.WriteU64LE(ed.Values[i].Value);
  end;
end;

procedure TLyuxSerializer.WriteInstr(instr: TIRInstr);
begin
  FBuffer.WriteU16LE(Ord(instr.Op));
  FBuffer.WriteU32LE(instr.Dest);
  FBuffer.WriteU32LE(instr.Src1);
  FBuffer.WriteU32LE(instr.Src2);
  FBuffer.WriteU32LE(instr.Src3);
  FBuffer.WriteU64LE(instr.ImmInt);
  { ImmFloat }
  FBuffer.WriteU64LE(Trunc(instr.ImmFloat));
  { ImmStr - als Index }
  if instr.ImmStr <> '' then
    FBuffer.WriteU32LE(GetStringIdx(instr.ImmStr))
  else
    FBuffer.WriteU32LE($FFFFFFFF);
  { LabelName }
  if instr.LabelName <> '' then
    FBuffer.WriteU32LE(GetStringIdx(instr.LabelName))
  else
    FBuffer.WriteU32LE($FFFFFFFF);
  { CallMode }
  FBuffer.WriteU8(Ord(instr.CallMode));
  { Sonstige Felder vereinfacht }
end;

procedure TLyuxSerializer.WriteFunction(fn: TIRFunction);
var
  i: Integer;
begin
  WriteString(fn.Name);
  FBuffer.WriteU16LE(fn.ParamCount);
  FBuffer.WriteU16LE(fn.LocalCount);
  FBuffer.WriteU8(Ord(fn.EnergyLevel));
  FBuffer.WriteU32LE(Length(fn.Instructions));
  for i := 0 to High(fn.Instructions) do
    WriteInstr(fn.Instructions[i]);
end;

procedure TLyuxSerializer.WriteModule(mod: TIRModule; symbols: TLyuxSymbolArray);
var
  i, j: Integer;
  funcName: string;
  fn: TIRFunction;
begin
  { Symbol-Tabelle }
  FBuffer.WriteU32LE(Length(symbols));
  for i := 0 to High(symbols) do
  begin
    WriteString(symbols[i].Name);
    FBuffer.WriteU8(Ord(symbols[i].Kind));
    FBuffer.WriteU32LE(symbols[i].TypeHash);
    WriteString(symbols[i].TypeInfo);
  end;

  { Type-Info Section (vereinfacht: nur Structs/Classes/Enums) }
  j := 0;
  for i := 0 to mod.ProgramNode.Decls.Count - 1 do
    if mod.ProgramNode.Decls[i] is TAstStructDecl then
      Inc(j);
  for i := 0 to mod.ProgramNode.Decls.Count - 1 do
    if mod.ProgramNode.Decls[i] is TAstClassDecl then
      Inc(j);
  for i := 0 to mod.ProgramNode.Decls.Count - 1 do
    if mod.ProgramNode.Decls[i] is TAstEnumDecl then
      Inc(j);
  FBuffer.WriteU32LE(j);
  for i := 0 to mod.ProgramNode.Decls.Count - 1 do
  begin
    if mod.ProgramNode.Decls[i] is TAstStructDecl then
      WriteStructDecl(TAstStructDecl(mod.ProgramNode.Decls[i]));
    if mod.ProgramNode.Decls[i] is TAstClassDecl then
      WriteClassDecl(TAstClassDecl(mod.ProgramNode.Decls[i]));
    if mod.ProgramNode.Decls[i] is TAstEnumDecl then
      WriteEnumDecl(TAstEnumDecl(mod.ProgramNode.Decls[i]));
  end;

  { IR Code Section }
  { Strings }
  FBuffer.WriteU32LE(mod.Strings.Count);
  for i := 0 to mod.Strings.Count - 1 do
    WriteString(mod.Strings[i]);

  { Functions }
  FBuffer.WriteU32LE(Length(mod.Functions));
  for i := 0 to High(mod.Functions) do
  begin
    fn := mod.Functions[i];
    { Nur exportierte (pub) Funktionen }
    funcName := fn.Name;
    if (Length(funcName) > 2) and (Copy(funcName, 1, 2) = '__') then
      Continue;  { Compiler-generierte ignorieren }
    WriteFunction(fn);
  end;

  { Globals }
  FBuffer.WriteU32LE(Length(mod.GlobalVars));
  for i := 0 to High(mod.GlobalVars) do
  begin
    WriteString(mod.GlobalVars[i].Name);
    FBuffer.WriteU64LE(mod.GlobalVars[i].InitValue);
    FBuffer.WriteU8(Ord(mod.GlobalVars[i].HasInitValue));
    FBuffer.WriteU8(Ord(mod.GlobalVars[i].IsArray));
    if mod.GlobalVars[i].IsArray then
      FBuffer.WriteU32LE(mod.GlobalVars[i].ArrayLen);
  end;
end;

procedure TLyuxSerializer.Serialize(mod: TIRModule; const unitName: string;
  symbols: TLyuxSymbolArray; out buffer: TByteBuffer);
var
  typeInfoPos, irCodePos, debugPos: Cardinal;
  nameBytes: TBytes;
  i: Integer;
begin
  FStrings.Clear;

  { Header reservieren (Position wird später berechnet) }
  { Wir schreiben zuerst in einen Temp-Buffer }

  { Header }
  for i := 0 to 3 do
    FBuffer.WriteU8(Ord(LYU_MAGIC[i]));
  FBuffer.WriteU16LE(LYU_VERSION);
  FBuffer.WriteU8(Ord(FArch));
  FBuffer.WriteU8(Byte(FIncludeDebug));

  nameBytes := TEncoding.UTF8.GetBytes(unitName);
  FBuffer.WriteU16LE(Length(nameBytes));
  for i := 0 to High(nameBytes) do
    FBuffer.WriteU8(nameBytes[i]);

  FBuffer.WriteU32LE(Length(symbols));

  { Placeholder für Offsets }
  typeInfoPos := FBuffer.Size;
  FBuffer.WriteU32LE(0);  { TypeInfoOffset - placeholder }
  irCodePos := FBuffer.Size;
  FBuffer.WriteU32LE(0);  { IRCodeOffset - placeholder }
  debugPos := FBuffer.Size;
  FBuffer.WriteU32LE(0);  { DebugOffset - placeholder }
  FBuffer.WriteU32LE(0);  { Reserved }

  { HeaderSize }
  FBuffer.WriteU16LE(debugPos);  { = size of header }

  { Symbol-Tabelle schreiben }
  { Wir beginnen bei Offset debugPos = TypeInfoOffset }
  FBuffer.PatchU32LE(typeInfoPos, FBuffer.Size);
  WriteModule(mod, symbols);

  { IR Code Section (bei current position) }
  irCodePos := FBuffer.Size;

  { Debug Section (optional) - vorerst nicht implementiert }
  debugPos := FBuffer.Size;

  { Patch Offsets }
  FBuffer.PatchU32LE(typeInfoPos, typeInfoPos);
  FBuffer.PatchU32LE(irCodePos, irCodePos);
  FBuffer.PatchU32LE(debugPos, debugPos);

  buffer := FBuffer;
  FBuffer := nil;  { Transfer ownership }
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

function TLyuxDeserializer.ReadType: TAurumType;
begin
  Result := TAurumType(FBuffer.ReadU8(FPos));
  Inc(FPos);
  { Bei komplexen Typen hier weitere Daten lesen }
end;

function TLyuxDeserializer.ReadStructDecl: TAstStructDecl;
var
  name: string;
  fieldCount, i: Integer;
  fields: TStructFieldList;
begin
  name := ReadString;
  fieldCount := FBuffer.ReadU32LE(FPos);
  SetLength(fields, fieldCount);
  for i := 0 to fieldCount - 1 do
  begin
    fields[i].Name := ReadString;
    fields[i].DeclType := ReadType;
    fields[i].Size := FBuffer.ReadU32LE(FPos);
  end;
  { Vereinfacht: wir geben nil zurück, da TAstStructDecl im .lyu }
  { nicht vollständig rekonstruiert wird }
  Result := nil;
end;

function TLyuxDeserializer.ReadClassDecl: TAstClassDecl;
begin
  { Vereinfacht }
  Result := nil;
end;

function TLyuxDeserializer.ReadEnumDecl: TAstEnumDecl;
begin
  { Vereinfacht }
  Result := nil;
end;

function TLyuxDeserializer.ReadFunction: TIRFunction;
var
  name: string;
  paramCount, localCount, instrCount, i: Integer;
begin
  name := ReadString;
  paramCount := FBuffer.ReadU16LE(FPos);
  localCount := FBuffer.ReadU16LE(FPos);
  Result := TIRFunction.Create(name);
  Result.ParamCount := paramCount;
  Result.LocalCount := localCount;
  FBuffer.ReadU8(FPos);  { EnergyLevel }
  instrCount := FBuffer.ReadU32LE(FPos);
  SetLength(Result.Instructions, instrCount);
  for i := 0 to instrCount - 1 do
    Result.Instructions[i] := ReadInstr;
end;

function TLyuxDeserializer.ReadInstr: TIRInstr;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Op := TIROpKind(FBuffer.ReadU16LE(FPos));
  Result.Dest := FBuffer.ReadU32LE(FPos);
  Result.Src1 := FBuffer.ReadU32LE(FPos);
  Result.Src2 := FBuffer.ReadU32LE(FPos);
  Result.Src3 := FBuffer.ReadU32LE(FPos);
  Result.ImmInt := FBuffer.ReadU64LE(FPos);
  Inc(FPos, 8);  { ImmFloat - vereinfacht }
  { ImmStr, LabelName, CallMode - vereinfacht }
  Inc(FPos, 4 + 4 + 1);
end;

procedure TLyuxDeserializer.ReadModule(out mod: TIRModule; out symbols: TLyuxSymbolArray);
var
  i, count: Integer;
begin
  mod := TIRModule.Create;

  { Symbol-Tabelle }
  count := FBuffer.ReadU32LE(FPos);
  SetLength(symbols, count);
  for i := 0 to count - 1 do
  begin
    symbols[i].Name := ReadString;
    symbols[i].Kind := TLyuxSymbolKind(FBuffer.ReadU8(FPos));
    symbols[i].TypeHash := FBuffer.ReadU32LE(FPos);
    symbols[i].TypeInfo := ReadString;
  end;

  { Type-Info lesen (und ignorieren für v1) }
  count := FBuffer.ReadU32LE(FPos);
  for i := 0 to count - 1 do
  begin
    { Vereinfacht: Types lesen aber nicht rekonstruieren }
    ReadString;
  end;

  { Strings }
  count := FBuffer.ReadU32LE(FPos);
  for i := 0 to count - 1 do
    mod.InternString(ReadString);

  { Functions }
  count := FBuffer.ReadU32LE(FPos);
  for i := 0 to count - 1 do
    mod.AddFunction(ReadFunction.Name);

  { Globals lesen - vereinfacht }
  count := FBuffer.ReadU32LE(FPos);
end;

procedure TLyuxDeserializer.Deserialize(buffer: TByteBuffer; out loaded: TLoadedLyux);
var
  i: Integer;
  magic: array[0..3] of Char;
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

  { Version }
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
  Inc(FPos, 4 + 2);  { Reserved + HeaderSize }

  { Symbols lesen }
  SetLength(loaded.Symbols, loaded.Header.SymbolCount);
  for i := 0 to loaded.Header.SymbolCount - 1 do
  begin
    loaded.Symbols[i].Name := ReadString;
    loaded.Symbols[i].Kind := TLyuxSymbolKind(FBuffer.ReadU8(FPos));
    loaded.Symbols[i].TypeHash := FBuffer.ReadU32LE(FPos);
    loaded.Symbols[i].TypeInfo := ReadString;
  end;
end;

function TLyuxDeserializer.CharToKind(c: Char): TLyuxSymbolKind;
begin
  case c of
    'f': Result := lskFn;
    'v': Result := lskVar;
    'l': Result := lskLet;
    'c': Result := lskCon;
    's': Result := lskStruct;
    'C': Result := lskClass;
    'e': Result := lskEnum;
    'x': Result := lskExternFn;
  else
    Result := lskFn;
  end;
end;

{ Hilfsfunktionen }

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
    Result := la_x86_64;  { Default }
end;

function GetCurrentArch: TLyuxArch;
begin
  {$IFDEF CPUX86_64}
  {$IFDEF WINDOWS}
  Result := la_x86_64_win;
  {$ELSE}
  Result := la_x86_64;
  {$ENDIF}
  {$ENDIF}
  {$IFDEF CPUARM64}
  Result := la_arm64;
  {$ENDIF}
  { Weitere Architekturen }
  Result := la_x86_64;  { Fallback }
end;

end.