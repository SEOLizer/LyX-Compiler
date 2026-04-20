{$mode objfpc}{$H+}
unit unit_manager;

interface

uses
  SysUtils, Classes,
  ast, diag, lexer, parser, bytes, unit_format;

type
  { Suchergebnis für Import-Auflösung }
  TResolveResult = record
    Found: Boolean;
    FilePath: string;
    SearchPath: string;  // Welcher Suchpfad hat gematcht
    IsStdLib: Boolean;   // War es ein std.* Import
  end;

  { Geladene Unit mit ihrem AST }
  TLoadedUnit = class
  public
    UnitPath: string;
    FileName: string;
    AST: TAstProgram;
    LyuxData: TLoadedLyux;  { .lyu data if precompiled }
    IsPrecompiled: Boolean;  { True if loaded from .lyu }
    IsParsed: Boolean;
    constructor Create(const aUnitPath, aFileName: string; aAST: TAstProgram);
    constructor CreatePrecompiled(const aUnitPath, aFileName: string; aLyux: TLoadedLyux);
    destructor Destroy; override;
  end;

  { Verwaltet alle geladenen Units mit verbesserter Auflösung }
  TUnitManager = class
  private
    FUnits: TStringList;           // UnitPath -> TLoadedUnit
    FIncludePaths: TStringList;    // -I Pfade
    FStdLibPath: string;           // Pfad zur Standardbibliothek
    FSourceFilePath: string;       // Pfad der Hauptdatei
    FProjectRoot: string;          // Projekt-Root (wo lyxc aufgerufen wurde)
    FDiag: TDiagnostics;
    FTraceImports: Boolean;        // --trace-imports Flag

    procedure Trace(const msg: string);
    function IsStdNamespace(const unitPath: string): Boolean;
    function UnitPathToRelativePath(const unitPath: string): string;
    function TryResolvePath(const basePath, relativePath: string; out fullPath: string): Boolean;
    function TryResolvePrecompiledPath(const basePath, relativePath: string; out fullPath: string): Boolean;
    function ResolveUnitPath(const unitPath: string; const importingFile: string): TResolveResult;
    function LoadUnitFile(const unitPath: string; const importingFile: string): TAstProgram;
    function LoadPrecompiledUnit(const filePath: string): TLoadedLyux;
  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;

    { Konfiguration }
    procedure SetSourceFile(const path: string);
    procedure SetProjectRoot(const path: string);
    procedure SetStdLibPath(const path: string);
    procedure AddIncludePath(const path: string);
    procedure SetTraceImports(enabled: Boolean);

    { Unit-Laden }
    function LoadUnit(const unitPath: string; const importingFile: string): TLoadedUnit;
    function FindUnit(const unitPath: string): TLoadedUnit;
    procedure LoadAllImports(prog: TAstProgram; const importingFile: string);

    { Für Abwärtskompatibilität }
    procedure AddSearchPath(const path: string);

    property Units: TStringList read FUnits;
    property StdLibPath: string read FStdLibPath;
    property TraceImports: Boolean read FTraceImports write FTraceImports;
  end;

implementation

{ TLoadedUnit }

constructor TLoadedUnit.Create(const aUnitPath, aFileName: string; aAST: TAstProgram);
begin
  inherited Create;
  UnitPath := aUnitPath;
  FileName := aFileName;
  AST := aAST;
  LyuxData := nil;
  IsPrecompiled := False;
  IsParsed := False;
end;

constructor TLoadedUnit.CreatePrecompiled(const aUnitPath, aFileName: string; aLyux: TLoadedLyux);
begin
  inherited Create;
  UnitPath := aUnitPath;
  FileName := aFileName;
  AST := nil;
  LyuxData := aLyux;
  IsPrecompiled := True;
  IsParsed := False;
end;

destructor TLoadedUnit.Destroy;
begin
  if Assigned(AST) then
    AST.Free;
  if Assigned(LyuxData) then
    LyuxData.Free;
  inherited Destroy;
end;

{ TUnitManager }

constructor TUnitManager.Create(d: TDiagnostics);
var
  envPath: string;
begin
  inherited Create;
  FDiag := d;
  FUnits := TStringList.Create;
  FUnits.Sorted := False;
  FIncludePaths := TStringList.Create;
  FTraceImports := False;

  // Standard-Pfade initialisieren
  FSourceFilePath := '';
  FProjectRoot := GetCurrentDir;

  // Standardbibliothek-Pfad ermitteln:
  // 1. Umgebungsvariable LYX_STD_PATH
  // 2. Relativ zum Compiler-Binary: ../std/
  // 3. Systemweiter Pfad: /usr/lib/lyx/std/
  // 4. Fallback: ./std/
  envPath := GetEnvironmentVariable('LYX_STD_PATH');
  if (envPath <> '') and DirectoryExists(envPath) then
    FStdLibPath := envPath
  else if DirectoryExists(ExtractFilePath(ParamStr(0)) + '../std') then
    FStdLibPath := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../std')
  else if DirectoryExists('/usr/lib/lyx/std') then
    FStdLibPath := '/usr/lib/lyx/std'
  else
    FStdLibPath := ExpandFileName('./std');
end;

destructor TUnitManager.Destroy;
var
  i: Integer;
begin
  for i := 0 to FUnits.Count - 1 do
    TLoadedUnit(FUnits.Objects[i]).Free;
  FUnits.Free;
  FIncludePaths.Free;
  inherited Destroy;
end;

procedure TUnitManager.Trace(const msg: string);
begin
  if FTraceImports then
    WriteLn('[TRACE] ', msg);
end;

function TUnitManager.IsStdNamespace(const unitPath: string): Boolean;
begin
  // Prüft ob der Import mit 'std.' beginnt
  Result := (Length(unitPath) >= 4) and (Copy(unitPath, 1, 4) = 'std.');
end;

function TUnitManager.UnitPathToRelativePath(const unitPath: string): string;
begin
  // Wandelt 'std.io' -> 'std/io.lyx'
  // Wandelt 'mylib.utils' -> 'mylib/utils.lyx'
  Result := StringReplace(unitPath, '.', DirectorySeparator, [rfReplaceAll]) + '.lyx';
end;

function TUnitManager.TryResolvePath(const basePath, relativePath: string; out fullPath: string): Boolean;
var
  candidate: string;
begin
  if basePath = '' then
  begin
    Result := False;
    Exit;
  end;

  candidate := IncludeTrailingPathDelimiter(basePath) + relativePath;
  fullPath := ExpandFileName(candidate);
  Result := FileExists(fullPath);

  if FTraceImports then
  begin
    if Result then
      Trace('  -> Trying: ' + fullPath + ' ... FOUND!')
    else
      Trace('  -> Trying: ' + fullPath + ' ... NOT FOUND');
  end;
end;

function TUnitManager.ResolveUnitPath(const unitPath: string; const importingFile: string): TResolveResult;
var
  relativePath: string;
  importingDir: string;
  fullPath: string;
  i: Integer;
  lastPart: string;
  dotPos: Integer;
begin
  Result.Found := False;
  Result.FilePath := '';
  Result.SearchPath := '';
  Result.IsStdLib := False;

  relativePath := UnitPathToRelativePath(unitPath);

  if FTraceImports then
    Trace('Resolving ''' + unitPath + '''...');

  // ============================================================
  // SONDERFALL: std.* Namespace
  // ============================================================
  // Wenn der Import mit 'std.' beginnt, suchen wir NUR in der
  // Standardbibliothek. Dies verhindert, dass lokale Dateien
  // die Standardbibliothek überschatten können.
  // ============================================================
  if IsStdNamespace(unitPath) then
  begin
    if FTraceImports then
      Trace('  Reserved prefix ''std'' detected. Jumping to STD_PATH.');

    // Bei std.io -> suche std/io.lyx im StdLibPath
    // Der Pfad 'std/' ist bereits Teil von relativePath
    if TryResolvePath(FStdLibPath, Copy(relativePath, 5, MaxInt), fullPath) then
    begin
      Result.Found := True;
      Result.FilePath := fullPath;
      Result.SearchPath := FStdLibPath;
      Result.IsStdLib := True;
      Exit;
    end;

    // Alternativ: std/io.lyx direkt im StdLibPath-Parent
    if TryResolvePath(ExtractFilePath(ExcludeTrailingPathDelimiter(FStdLibPath)), relativePath, fullPath) then
    begin
      Result.Found := True;
      Result.FilePath := fullPath;
      Result.SearchPath := ExtractFilePath(ExcludeTrailingPathDelimiter(FStdLibPath));
      Result.IsStdLib := True;
      Exit;
    end;

    // Nicht gefunden - gib Fehler aus
    Exit;
  end;

  // ============================================================
  // STANDARD SUCHREIHENFOLGE (für nicht-std Imports)
  // ============================================================
  // 1. Direkt als Dateipfad (wenn unitPath bereits ein Pfad ist)
  // 2. Relativ zur importierenden Datei
  // 3. Projekt-Root
  // 4. -I Include-Pfade
  // 5. Standardbibliothek (für nicht-std Module wie 'math')
  // ============================================================

  // 0. Direkt als Dateipfad versuchen (z.B. "tests/lyx/foo" statt "foo")
  if (Pos('/', unitPath) > 0) or (Pos('\', unitPath) > 0) then
  begin
    // Wandle '/' in Pfadtrennzeichen um
    fullPath := StringReplace(unitPath, '.', DirectorySeparator, [rfReplaceAll]);
    // Versuche mit .lyx Erweiterung
    if RightStr(fullPath, 4) <> '.lyx' then
      fullPath := fullPath + '.lyx';
    fullPath := ExpandFileName(fullPath);
    if FileExists(fullPath) then
    begin
      Result.Found := True;
      Result.FilePath := fullPath;
      Result.SearchPath := ExtractFilePath(fullPath);
      Exit;
    end;
  end;

  // 1. Relativ zur importierenden Datei
  if importingFile <> '' then
  begin
    importingDir := ExtractFilePath(ExpandFileName(importingFile));
    if TryResolvePath(importingDir, relativePath, fullPath) then
    begin
      Result.Found := True;
      Result.FilePath := fullPath;
      Result.SearchPath := importingDir;
      Exit;
    end;
  end;

  // 2. Projekt-Root (Working Directory) - mit nur dem Dateinamen, nicht dem vollen Pfad
  // Extrahiere nur den letzten Teil: "tests.lyx.precompiled.myunit" -> "myunit"
  dotPos := LastDelimiter('.', unitPath);
  if dotPos > 0 then
    lastPart := Copy(unitPath, dotPos + 1, MaxInt)
  else
    lastPart := unitPath;
  if TryResolvePath(FProjectRoot, lastPart + '.lyx', fullPath) then
  begin
    Result.Found := True;
    Result.FilePath := fullPath;
    Result.SearchPath := FProjectRoot;
    Exit;
  end;

  // 3. Projekt-Root (voller relativer Pfad, für verschachtelte Module)
  if TryResolvePath(FProjectRoot, relativePath, fullPath) then
  begin
    Result.Found := True;
    Result.FilePath := fullPath;
    Result.SearchPath := FProjectRoot;
    Exit;
  end;

  // 4. -I Include-Pfade (in der Reihenfolge wie angegeben)
  for i := 0 to FIncludePaths.Count - 1 do
  begin
    if TryResolvePath(FIncludePaths[i], relativePath, fullPath) then
    begin
      Result.Found := True;
      Result.FilePath := fullPath;
      Result.SearchPath := FIncludePaths[i];
      Exit;
    end;
  end;

  // 5. Standardbibliothek (für Module ohne std. Präfix)
  if TryResolvePath(FStdLibPath, relativePath, fullPath) then
  begin
    Result.Found := True;
    Result.FilePath := fullPath;
    Result.SearchPath := FStdLibPath;
    Result.IsStdLib := True;
    Exit;
  end;

  // Nicht gefunden
  if FTraceImports then
    Trace('  -> Module NOT FOUND in any search path!');
end;

procedure TUnitManager.SetSourceFile(const path: string);
begin
  FSourceFilePath := ExpandFileName(path);
end;

procedure TUnitManager.SetProjectRoot(const path: string);
begin
  if path <> '' then
    FProjectRoot := ExpandFileName(path)
  else
    FProjectRoot := GetCurrentDir;
end;

procedure TUnitManager.SetStdLibPath(const path: string);
begin
  if (path <> '') and DirectoryExists(path) then
    FStdLibPath := ExpandFileName(path);
end;

procedure TUnitManager.AddIncludePath(const path: string);
var
  expandedPath: string;
begin
  expandedPath := ExpandFileName(path);
  if DirectoryExists(expandedPath) then
  begin
    if FIncludePaths.IndexOf(expandedPath) < 0 then
      FIncludePaths.Add(expandedPath);
  end;
end;

procedure TUnitManager.SetTraceImports(enabled: Boolean);
begin
  FTraceImports := enabled;
end;

procedure TUnitManager.AddSearchPath(const path: string);
begin
  // Für Abwärtskompatibilität: fügt als Include-Pfad hinzu
  AddIncludePath(path);
end;

function TUnitManager.LoadUnitFile(const unitPath: string; const importingFile: string): TAstProgram;
var
  lx: TLexer;
  p: TParser;
  src: TStringList;
  res: TResolveResult;
begin
  Result := nil;

  res := ResolveUnitPath(unitPath, importingFile);

  if not res.Found then
  begin
    FDiag.Error('cannot find unit: ' + unitPath, Default(TSourceSpan));
    Exit;
  end;

  if not FileExists(res.FilePath) then
  begin
    FDiag.Error('unit file not found: ' + res.FilePath, Default(TSourceSpan));
    Exit;
  end;

  src := TStringList.Create;
  try
    try
      src.LoadFromFile(res.FilePath);
    except
      on E: Exception do
      begin
        FDiag.Error('cannot read unit file: ' + res.FilePath + ' - ' + E.Message, Default(TSourceSpan));
        Exit;
      end;
    end;

    lx := TLexer.Create(src.Text, res.FilePath, FDiag);
    try
      p := TParser.Create(lx, FDiag);
      try
        Result := p.ParseProgram;
      finally
        p.Free;
      end;
    finally
      lx.Free;
    end;
  finally
    src.Free;
  end;
end;

function TUnitManager.LoadUnit(const unitPath: string; const importingFile: string): TLoadedUnit;
var
  idx: Integer;
  ast: TAstProgram;
  res: TResolveResult;
  lyux: TLoadedLyux;
  lyuPath: string;
begin
  // Prüfe ob Unit bereits geladen
  idx := FUnits.IndexOf(unitPath);
  if idx >= 0 then
  begin
    Result := TLoadedUnit(FUnits.Objects[idx]);
    if FTraceImports then
      Trace('Unit ''' + unitPath + ''' already loaded');
    Exit;
  end;

  // First try to load precompiled .lyu
  res := ResolveUnitPath(unitPath, importingFile);
  lyuPath := '';
  if res.Found then
  begin
    // Replace .lyx with .lyu
    if RightStr(res.FilePath, 4) = '.lyx' then
      lyuPath := Copy(res.FilePath, 1, Length(res.FilePath) - 4) + '.lyu'
    else
      lyuPath := res.FilePath + '.lyu';
  end;
  
  // Versuche .lyu zu laden wenn vorhanden
  if (lyuPath <> '') and FileExists(lyuPath) then
  begin
    if FTraceImports then
      Trace('Loading precompiled unit: ' + lyuPath);
    try
      lyux := LoadPrecompiledUnit(lyuPath);
      if Assigned(lyux) then
      begin
        Result := TLoadedUnit.CreatePrecompiled(unitPath, lyuPath, lyux);
        FUnits.AddObject(unitPath, Result);
        Exit;
      end;
    except
      on E: Exception do
      begin
        if FTraceImports then
          Trace('Failed to load precompiled unit: ' + E.Message + ' - falling back to .lyx');
        { Fallback to .lyx }
      end;
    end;
  end;

  // Fallback: Lade .lyx
  if not res.Found then
  begin
    FDiag.Error('cannot find unit: ' + unitPath, Default(TSourceSpan));
    Result := nil;
    Exit;
  end;

  // Lade die Unit
  ast := LoadUnitFile(unitPath, importingFile);
  if not Assigned(ast) then
  begin
    Result := nil;
    Exit;
  end;

  Result := TLoadedUnit.Create(unitPath, res.FilePath, ast);
  FUnits.AddObject(unitPath, Result);

  // Rekursiv alle Imports dieser Unit laden
  LoadAllImports(ast, res.FilePath);
end;

function TUnitManager.TryResolvePrecompiledPath(const basePath, relativePath: string; out fullPath: string): Boolean;
var
  p: string;
begin
  Result := False;
  fullPath := '';
  
  // Convert unit path to file path: "std.io" -> "std/io"
  p := StringReplace(relativePath, '.', PathDelim, [rfReplaceAll]);
  
  // Try .lyu first
  if basePath <> '' then
    fullPath := basePath + PathDelim + p + '.lyu'
  else
    fullPath := p + '.lyu';
    
  if FileExists(fullPath) then
  begin
    Result := True;
    Exit;
  end;
  
  fullPath := '';
end;

function TUnitManager.LoadPrecompiledUnit(const filePath: string): TLoadedLyux;
var
  buffer: TByteBuffer;
  deser: TLyuxDeserializer;
  f: TFileStream;
  data: array of Byte;
  size: Integer;
begin
  Result := nil;
  if not FileExists(filePath) then
    Exit;
    
  f := TFileStream.Create(filePath, fmOpenRead or fmShareDenyNone);
  try
    size := f.Size;
    SetLength(data, size);
    f.Read(data[0], size);
  finally
    f.Free;
  end;
  
  buffer := TByteBuffer.Create;
  try
    buffer.WriteBytes(data);
    deser := TLyuxDeserializer.Create(FDiag);
    try
      deser.Deserialize(buffer, Result);
    finally
      deser.Free;
    end;
  finally
    buffer.Free;
  end;
end;

function TUnitManager.FindUnit(const unitPath: string): TLoadedUnit;
var
  idx: Integer;
begin
  idx := FUnits.IndexOf(unitPath);
  if idx >= 0 then
    Result := TLoadedUnit(FUnits.Objects[idx])
  else
    Result := nil;
end;

procedure TUnitManager.LoadAllImports(prog: TAstProgram; const importingFile: string);
var
  i: Integer;
  decl: TAstNode;
  impDecl: TAstImportDecl;
  unitPath: string;
  loadedUnit: TLoadedUnit;
begin
  if not Assigned(prog) then Exit;

  for i := 0 to High(prog.Decls) do
  begin
    decl := prog.Decls[i];
    if decl is TAstImportDecl then
    begin
      impDecl := TAstImportDecl(decl);
      unitPath := impDecl.UnitPath;

      // Prüfe ob Unit bereits geladen
      loadedUnit := FindUnit(unitPath);
      if not Assigned(loadedUnit) then
      begin
        loadedUnit := LoadUnit(unitPath, importingFile);

        if not Assigned(loadedUnit) then
        begin
          FDiag.Error('failed to load import: ' + unitPath, decl.Span);
        end;
      end;
    end;
  end;
end;

end.
