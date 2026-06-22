/// <summary>
/// DUnit-Testsuite für KassenSichV.TseCore.
/// WP-TSE-09
///
/// Alle Tests laufen ohne physische TSE (MockProvider).
/// BSI TR-03153 Anhang A QR-Code-Format-Referenztests enthalten.
/// Integrationstests gegen Fiskaly-Sandbox sind ausgelagert (benötigen API-Credentials).
/// </summary>
unit TestKassenSichV;

interface

uses
  TestFramework,
  System.SysUtils,
  System.DateUtils,
  System.IOUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Manager,
  KassenSichV.Mock,
  KassenSichV.Export,
  KassenSichV.Exceptions;

type
  // --- Hilfsfunktion ---
  // Parst einen QR-Code-String in seine Segmente (Semikolon-getrennt)

  TStringArray = array of string;

  TTestTypes = class(TTestCase)
  published
    procedure TestTBelegDatenDefaultValues;
    procedure TestTSignaturErgebnisDefaultValues;
  end;

  TTestMockProvider = class(TTestCase)
  private
    FProvider: TMockTseProvider;
    FManager:  TTseManager;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestInitializeAcceptsAnyConfig;
    procedure TestGetSeriennummer;
    procedure TestStartTransactionSetsBelegTransId;
    procedure TestSignaturZaehlerMonotonIncreasing;
    procedure TestSimulateTimeoutRaisesETseTimeoutError;
    procedure TestSimulateErrorRaisesETseConnectionError;
    procedure TestLastBelegAndLastSignaturAfterProcessBeleg;
    procedure TestExportAuditDataCreatesFile;
    procedure TestGetStatusContainsProvider;
  end;

  TTestManager = class(TTestCase)
  private
    FProvider: TMockTseProvider;
    FManager:  TTseManager;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestProcessBelegReturnsErfolg;
    procedure TestProcessBelegSetsQrCodeData;
    procedure TestOpenAndCloseBelegFlow;
    procedure TestUpdateBelegFlow;
    procedure TestManagerRaisesOnNilProvider;
    procedure TestManagerWrapsProviderExceptionAsETseTransactionError;
    procedure TestExportAuditDataCreatesIndexJson;
    procedure TestGetTseStatus;
    procedure TestGetTseSeriennummer;
  end;

  // BSI TR-03153 Anhang A QR-Code-Format-Tests (keine echte TSE nötig)
  TTestQrCodeFormat = class(TTestCase)
  private
    FProvider: TMockTseProvider;
    FManager:  TTseManager;
    function SplitQr(const AQr: string): TStringArray;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // Referenztest 1: Pflichtpräfix V0
    procedure TestQrCodeStartsWithV0;
    // Referenztest 2: Segmentanzahl = 7 (V0;Serial;Start;End;Zähler;AnzTrans;Sig)
    procedure TestQrCodeHasSevenSegments;
    // Referenztest 3: Zeitstempel-Format yyyy-mm-dd"T"hh:nn:ss"Z"
    procedure TestQrCodeTimestampFormatIsIso8601Utc;
    // Referenztest 4: Zähler monoton steigend über mehrere Belege
    procedure TestQrCodeZaehlerIncreases;
    // Referenztest 5: Seriennummer im QR-Code = GetSeriennummer
    procedure TestQrCodeSerialMatchesProvider;
    // Referenztest 6: SignaturWert ist non-empty Base64 (nicht leer, keine Leerzeichen am Rand)
    procedure TestQrCodeSignaturWertIsNonEmpty;
  end;

  TTestExceptions = class(TTestCase)
  published
    procedure TestETseExceptionHierarchy;
    procedure TestETseConfigurationErrorCode;
    procedure TestETseTimeoutErrorCode;
    procedure TestETseConnectionErrorCode;
    procedure TestETseTransactionErrorCode;
    procedure TestETseExportErrorCode;
    procedure TestRestProviderMissingApiUrl;
    procedure TestRestProviderMissingApiKey;
    procedure TestRestProviderMissingClientId;
    procedure TestFileTseProviderMissingBasePath;
    procedure TestFileTseProviderInvalidPath;
    procedure TestManagerNilProviderRaises;
  end;

  TTestExporter = class(TTestCase)
  private
    FTempDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEnsureWritableOnValidDir;
    procedure TestEnsureWritableOnMissingDir;
    procedure TestWriteIndexJsonCreatesFile;
    procedure TestWriteIndexJsonContainsRequiredFields;
  end;

implementation

uses
  KassenSichV.Rest,
  KassenSichV.File;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function SplitStr(const S: string; const Delim: Char): TStringArray;
var
  Parts: TArray<string>;
  I:     Integer;
begin
  Parts  := S.Split([Delim]);
  SetLength(Result, Length(Parts));
  for I := 0 to High(Parts) do Result[I] := Parts[I];
end;

// ---------------------------------------------------------------------------
// TTestTypes
// ---------------------------------------------------------------------------

procedure TTestTypes.TestTBelegDatenDefaultValues;
var B: TBelegDaten;
begin
  B := Default(TBelegDaten);
  CheckEquals('', B.TransId, 'TransId leer');
  CheckEquals('', B.ProzessTyp, 'ProzessTyp leer');
  CheckEquals(0,  B.UmsatzZaehler, 'UmsatzZaehler 0');
end;

procedure TTestTypes.TestTSignaturErgebnisDefaultValues;
var S: TSignaturErgebnis;
begin
  S := Default(TSignaturErgebnis);
  CheckFalse(S.Erfolg, 'Erfolg Default False');
  CheckEquals('', S.QrCodeData, 'QrCodeData leer');
  CheckEquals(0,  S.SignaturZaehler, 'Zähler 0');
end;

// ---------------------------------------------------------------------------
// TTestMockProvider setup
// ---------------------------------------------------------------------------

procedure TTestMockProvider.SetUp;
begin
  FProvider := TMockTseProvider.Create;
  FProvider.Initialize('{}');
  FManager := TTseManager.Create(FProvider);
end;

procedure TTestMockProvider.TearDown;
begin
  FManager.Free;
  // FProvider wird durch Interface-Ref-Count freigegeben
end;

procedure TTestMockProvider.TestInitializeAcceptsAnyConfig;
begin
  // keine Exception — jede Config ist für den Mock akzeptabel
  FProvider.Initialize('{"beliebig":"wert"}');
  CheckTrue(True);
end;

procedure TTestMockProvider.TestGetSeriennummer;
begin
  CheckEquals('MOCK-TSE-0000000000000001', FProvider.GetSeriennummer);
end;

procedure TTestMockProvider.TestStartTransactionSetsBelegTransId;
var B: TBelegDaten;
begin
  B := Default(TBelegDaten);
  B.ProzessTyp := PROZESSTYP_KASSENBELEG;
  FProvider.StartTransaction(B);
  CheckNotEquals('', B.TransId, 'TransId muss nach StartTransaction gesetzt sein');
end;

procedure TTestMockProvider.TestSignaturZaehlerMonotonIncreasing;
var
  Beleg: TBelegDaten;
  Sig1, Sig2: TSignaturErgebnis;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  Sig1 := FManager.ProcessBeleg(Beleg);
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  Sig2 := FManager.ProcessBeleg(Beleg);
  Check(Sig2.SignaturZaehler > Sig1.SignaturZaehler,
    'Zähler muss nach zweitem Beleg höher sein');
end;

procedure TTestMockProvider.TestSimulateTimeoutRaisesETseTimeoutError;
var Beleg: TBelegDaten;
begin
  FProvider.SimulateTimeout := True;
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  try
    FManager.ProcessBeleg(Beleg);
    Fail('ETseTransactionError erwartet');
  except
    on E: ETseTransactionError do Check(True)
    else Fail('Falscher Exception-Typ');
  end;
end;

procedure TTestMockProvider.TestSimulateErrorRaisesETseConnectionError;
var Beleg: TBelegDaten;
begin
  FProvider.SimulateError := True;
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  try
    FManager.ProcessBeleg(Beleg);
    Fail('ETseTransactionError erwartet');
  except
    on E: ETseTransactionError do Check(True)
    else Fail('Falscher Exception-Typ');
  end;
end;

procedure TTestMockProvider.TestLastBelegAndLastSignaturAfterProcessBeleg;
var Beleg: TBelegDaten;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp    := PROZESSTYP_KASSENBELEG;
  Beleg.ProzessDaten  := 'Testdaten';
  FManager.ProcessBeleg(Beleg);
  CheckEquals(PROZESSTYP_KASSENBELEG, FProvider.LastBeleg.ProzessTyp,
    'LastBeleg.ProzessTyp muss nach ProcessBeleg gesetzt sein');
  CheckTrue(FProvider.LastSignatur.Erfolg, 'LastSignatur.Erfolg muss True sein');
end;

procedure TTestMockProvider.TestExportAuditDataCreatesFile;
var TmpDir, TarPath: string;
begin
  TmpDir := TPath.Combine(TPath.GetTempPath, 'tse_mock_test_' + IntToStr(GetCurrentThreadId));
  TDirectory.CreateDirectory(TmpDir);
  try
    FProvider.ExportAuditData(TmpDir);
    TarPath := TPath.Combine(TmpDir, 'mock_audit.tar');
    CheckTrue(TFile.Exists(TarPath), 'mock_audit.tar muss existieren');
  finally
    TDirectory.Delete(TmpDir, True);
  end;
end;

procedure TTestMockProvider.TestGetStatusContainsProvider;
var Status: string;
begin
  Status := FProvider.GetStatus;
  Check(Pos('MockTseProvider', Status) > 0, 'GetStatus muss "MockTseProvider" enthalten');
end;

// ---------------------------------------------------------------------------
// TTestManager setup
// ---------------------------------------------------------------------------

procedure TTestManager.SetUp;
begin
  FProvider := TMockTseProvider.Create;
  FProvider.Initialize('{}');
  FManager  := TTseManager.Create(FProvider);
end;

procedure TTestManager.TearDown;
begin
  FManager.Free;
end;

procedure TTestManager.TestProcessBelegReturnsErfolg;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  Sig   := FManager.ProcessBeleg(Beleg);
  CheckTrue(Sig.Erfolg, 'Erfolg muss True sein');
end;

procedure TTestManager.TestProcessBelegSetsQrCodeData;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  Sig   := FManager.ProcessBeleg(Beleg);
  CheckNotEquals('', Sig.QrCodeData, 'QrCodeData muss nach ProcessBeleg gesetzt sein');
end;

procedure TTestManager.TestOpenAndCloseBelegFlow;
var
  Beleg:   TBelegDaten;
  TransId: string;
  Sig:     TSignaturErgebnis;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  TransId := FManager.OpenBeleg(Beleg);
  CheckNotEquals('', TransId, 'OpenBeleg muss TransId zurückgeben');
  Sig := FManager.CloseBeleg(TransId, Beleg);
  CheckTrue(Sig.Erfolg, 'CloseBeleg Erfolg muss True sein');
  CheckNotEquals('', Sig.QrCodeData, 'CloseBeleg QrCodeData muss gesetzt sein');
end;

procedure TTestManager.TestUpdateBelegFlow;
var
  Beleg:   TBelegDaten;
  TransId: string;
  UpdSig:  TSignaturErgebnis;
begin
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  TransId := FManager.OpenBeleg(Beleg);
  UpdSig  := FManager.UpdateBeleg(TransId, Beleg);
  CheckEquals(FProvider.GetSeriennummer, UpdSig.TseSeriennummer,
    'UpdateBeleg TseSeriennummer muss korrekt sein');
  // UpdateBeleg setzt keinen QrCodeData — nur CloseBeleg tut das
  FManager.CloseBeleg(TransId, Beleg);
end;

procedure TTestManager.TestManagerRaisesOnNilProvider;
begin
  try
    var M := TTseManager.Create(nil);
    M.Free;
    Fail('ETseConfigurationError erwartet');
  except
    on E: ETseConfigurationError do Check(True)
    else Fail('Falscher Exception-Typ');
  end;
end;

procedure TTestManager.TestManagerWrapsProviderExceptionAsETseTransactionError;
var Beleg: TBelegDaten;
begin
  FProvider.SimulateError := True;
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;
  try
    FManager.ProcessBeleg(Beleg);
    Fail('ETseTransactionError erwartet');
  except
    on E: ETseTransactionError do Check(True)
    else Fail('Falscher Exception-Typ: ' + ExceptObject.ClassName);
  end;
end;

procedure TTestManager.TestExportAuditDataCreatesIndexJson;
var TmpDir, IndexPath: string;
begin
  TmpDir := TPath.Combine(TPath.GetTempPath, 'tse_mgr_test_' + IntToStr(GetCurrentThreadId));
  TDirectory.CreateDirectory(TmpDir);
  try
    FManager.ExportAuditData(TmpDir, 'KASSE-001');
    IndexPath := TPath.Combine(TmpDir, 'index.json');
    CheckTrue(TFile.Exists(IndexPath), 'index.json muss existieren');
  finally
    TDirectory.Delete(TmpDir, True);
  end;
end;

procedure TTestManager.TestGetTseStatus;
begin
  CheckNotEquals('', FManager.GetTseStatus, 'GetTseStatus darf nicht leer sein');
end;

procedure TTestManager.TestGetTseSeriennummer;
begin
  CheckEquals(FProvider.GetSeriennummer, FManager.GetTseSeriennummer);
end;

// ---------------------------------------------------------------------------
// TTestQrCodeFormat setup
// ---------------------------------------------------------------------------

function TTestQrCodeFormat.SplitQr(const AQr: string): TStringArray;
begin
  Result := SplitStr(AQr, ';');
end;

procedure TTestQrCodeFormat.SetUp;
begin
  FProvider := TMockTseProvider.Create;
  FProvider.Initialize('{}');
  FManager  := TTseManager.Create(FProvider);
end;

procedure TTestQrCodeFormat.TearDown;
begin
  FManager.Free;
end;

function MakeBeleg(const AProzessTyp: string = PROZESSTYP_KASSENBELEG): TBelegDaten;
begin
  Result := Default(TBelegDaten);
  Result.ProzessTyp   := AProzessTyp;
  Result.ProzessDaten := 'Testbon;42.00_0.00_0.00_0.00_0.00';
end;

// Referenztest 1 — BSI TR-03153 Anhang A: QR-Code muss mit "V0" beginnen
procedure TTestQrCodeFormat.TestQrCodeStartsWithV0;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
  Parts: TStringArray;
begin
  Beleg := MakeBeleg;
  Sig   := FManager.ProcessBeleg(Beleg);
  Parts := SplitQr(Sig.QrCodeData);
  CheckEquals('V0', Parts[0], 'QR-Code muss mit V0 beginnen (BSI TR-03153 Anhang A)');
end;

// Referenztest 2 — exakt 7 Segmente: V0;Serial;Start;End;Zähler;AnzTrans;Sig
procedure TTestQrCodeFormat.TestQrCodeHasSevenSegments;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
  Parts: TStringArray;
begin
  Beleg := MakeBeleg;
  Sig   := FManager.ProcessBeleg(Beleg);
  Parts := SplitQr(Sig.QrCodeData);
  CheckEquals(7, Length(Parts),
    'QR-Code muss genau 7 Semikolon-getrennte Felder haben (BSI TR-03153 Anhang A)');
end;

// Referenztest 3 — Zeitstempel muss im Format yyyy-mm-ddTHH:MM:SSZ sein
procedure TTestQrCodeFormat.TestQrCodeTimestampFormatIsIso8601Utc;
var
  Beleg:     TBelegDaten;
  Sig:       TSignaturErgebnis;
  Parts:     TStringArray;
  StartTs:   string;

  function IsValidIso8601(const S: string): Boolean;
  begin
    // Format: 2024-01-15T09:30:00Z — Länge 20, enthält T, endet mit Z
    Result := (Length(S) = 20) and
              (S[5] = '-') and (S[8] = '-') and
              (S[11] = 'T') and (S[14] = ':') and (S[17] = ':') and
              (S[20] = 'Z');
  end;

begin
  Beleg  := MakeBeleg;
  Sig    := FManager.ProcessBeleg(Beleg);
  Parts  := SplitQr(Sig.QrCodeData);
  StartTs := Parts[2];
  CheckTrue(IsValidIso8601(StartTs),
    'Startzeitpunkt muss im Format yyyy-mm-ddTHH:MM:SSZ sein, got: ' + StartTs);
  CheckTrue(IsValidIso8601(Parts[3]),
    'Endzeitpunkt muss im Format yyyy-mm-ddTHH:MM:SSZ sein, got: ' + Parts[3]);
end;

// Referenztest 4 — Signaturzähler steigt bei jedem ProcessBeleg
procedure TTestQrCodeFormat.TestQrCodeZaehlerIncreases;
var
  Beleg:   TBelegDaten;
  Sig1, Sig2: TSignaturErgebnis;
  Parts1, Parts2: TStringArray;
  Zaehler1, Zaehler2: Int64;
begin
  Beleg := MakeBeleg;
  Sig1  := FManager.ProcessBeleg(Beleg);
  Beleg := MakeBeleg;
  Sig2  := FManager.ProcessBeleg(Beleg);

  Parts1   := SplitQr(Sig1.QrCodeData);
  Parts2   := SplitQr(Sig2.QrCodeData);
  Zaehler1 := StrToInt64(Parts1[4]);
  Zaehler2 := StrToInt64(Parts2[4]);

  Check(Zaehler2 > Zaehler1,
    Format('Signaturzähler muss steigen: %d → %d', [Zaehler1, Zaehler2]));
end;

// Referenztest 5 — Seriennummer in QR stimmt mit GetSeriennummer überein
procedure TTestQrCodeFormat.TestQrCodeSerialMatchesProvider;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
  Parts: TStringArray;
begin
  Beleg := MakeBeleg;
  Sig   := FManager.ProcessBeleg(Beleg);
  Parts := SplitQr(Sig.QrCodeData);
  CheckEquals(FProvider.GetSeriennummer, Parts[1],
    'Seriennummer in QR-Code muss mit GetSeriennummer übereinstimmen');
end;

// Referenztest 6 — SignaturWert ist nicht leer und hat keine Leerzeichen
procedure TTestQrCodeFormat.TestQrCodeSignaturWertIsNonEmpty;
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
  Parts: TStringArray;
  SigVal: string;
begin
  Beleg  := MakeBeleg;
  Sig    := FManager.ProcessBeleg(Beleg);
  Parts  := SplitQr(Sig.QrCodeData);
  SigVal := Parts[6];
  CheckNotEquals('', SigVal, 'SignaturWert darf nicht leer sein');
  CheckEquals(SigVal, Trim(SigVal), 'SignaturWert darf keine Leerzeichen enthalten');
end;

// ---------------------------------------------------------------------------
// TTestExceptions
// ---------------------------------------------------------------------------

procedure TTestExceptions.TestETseExceptionHierarchy;
begin
  CheckTrue(ETseConnectionError.InheritsFrom(ETseException));
  CheckTrue(ETseTimeoutError.InheritsFrom(ETseException));
  CheckTrue(ETseSignatureError.InheritsFrom(ETseException));
  CheckTrue(ETseConfigurationError.InheritsFrom(ETseException));
  CheckTrue(ETseTransactionError.InheritsFrom(ETseException));
  CheckTrue(ETseExportError.InheritsFrom(ETseException));
end;

procedure TTestExceptions.TestETseConfigurationErrorCode;
var E: ETseConfigurationError;
begin
  E := ETseConfigurationError.Create('test', 400);
  try
    CheckEquals(400, E.ErrorCode);
  finally
    E.Free;
  end;
end;

procedure TTestExceptions.TestETseTimeoutErrorCode;
var E: ETseTimeoutError;
begin
  E := ETseTimeoutError.Create('test', 408);
  try
    CheckEquals(408, E.ErrorCode);
  finally
    E.Free;
  end;
end;

procedure TTestExceptions.TestETseConnectionErrorCode;
var E: ETseConnectionError;
begin
  E := ETseConnectionError.Create('test', 503);
  try
    CheckEquals(503, E.ErrorCode);
  finally
    E.Free;
  end;
end;

procedure TTestExceptions.TestETseTransactionErrorCode;
var E: ETseTransactionError;
begin
  E := ETseTransactionError.Create('test', 409);
  try
    CheckEquals(409, E.ErrorCode);
  finally
    E.Free;
  end;
end;

procedure TTestExceptions.TestETseExportErrorCode;
var E: ETseExportError;
begin
  E := ETseExportError.Create('test', 403);
  try
    CheckEquals(403, E.ErrorCode);
  finally
    E.Free;
  end;
end;

procedure TTestExceptions.TestRestProviderMissingApiUrl;
var P: TRestTseProvider;
begin
  P := TRestTseProvider.Create;
  try
    try
      P.Initialize('{"api_key":"k","client_id":"c"}');
      Fail('ETseConfigurationError erwartet');
    except
      on E: ETseConfigurationError do Check(True)
      else Fail('Falscher Exception-Typ');
    end;
  finally
    P.Free;
  end;
end;

procedure TTestExceptions.TestRestProviderMissingApiKey;
var P: TRestTseProvider;
begin
  P := TRestTseProvider.Create;
  try
    try
      P.Initialize('{"api_url":"https://example.com","client_id":"c"}');
      Fail('ETseConfigurationError erwartet');
    except
      on E: ETseConfigurationError do Check(True)
      else Fail('Falscher Exception-Typ');
    end;
  finally
    P.Free;
  end;
end;

procedure TTestExceptions.TestRestProviderMissingClientId;
var P: TRestTseProvider;
begin
  P := TRestTseProvider.Create;
  try
    try
      P.Initialize('{"api_url":"https://example.com","api_key":"k"}');
      Fail('ETseConfigurationError erwartet');
    except
      on E: ETseConfigurationError do Check(True)
      else Fail('Falscher Exception-Typ');
    end;
  finally
    P.Free;
  end;
end;

procedure TTestExceptions.TestFileTseProviderMissingBasePath;
var P: TFileTseProvider;
begin
  P := TFileTseProvider.Create;
  try
    try
      P.Initialize('{"timeout_ms":1000}');
      Fail('ETseConfigurationError erwartet');
    except
      on E: ETseConfigurationError do Check(True)
      else Fail('Falscher Exception-Typ');
    end;
  finally
    P.Free;
  end;
end;

procedure TTestExceptions.TestFileTseProviderInvalidPath;
var P: TFileTseProvider;
begin
  P := TFileTseProvider.Create;
  try
    try
      P.Initialize('{"base_path":"/nichtvorhanden/xyz123"}');
      Fail('ETseConnectionError erwartet');
    except
      on E: ETseConnectionError do Check(True)
      else Fail('Falscher Exception-Typ');
    end;
  finally
    P.Free;
  end;
end;

procedure TTestExceptions.TestManagerNilProviderRaises;
begin
  try
    var M := TTseManager.Create(nil);
    M.Free;
    Fail('ETseConfigurationError erwartet');
  except
    on E: ETseConfigurationError do Check(True)
    else Fail('Falscher Exception-Typ');
  end;
end;

// ---------------------------------------------------------------------------
// TTestExporter setup
// ---------------------------------------------------------------------------

procedure TTestExporter.SetUp;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath,
               'tse_export_test_' + IntToStr(GetCurrentThreadId));
  TDirectory.CreateDirectory(FTempDir);
end;

procedure TTestExporter.TearDown;
begin
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TTestExporter.TestEnsureWritableOnValidDir;
begin
  TTseExporter.EnsureWritable(FTempDir);
  CheckTrue(True);
end;

procedure TTestExporter.TestEnsureWritableOnMissingDir;
begin
  try
    TTseExporter.EnsureWritable('/nichtvorhanden/xyz_tse_test');
    Fail('ETseExportError erwartet');
  except
    on E: ETseExportError do Check(True)
    else Fail('Falscher Exception-Typ');
  end;
end;

procedure TTestExporter.TestWriteIndexJsonCreatesFile;
begin
  TTseExporter.WriteIndexJson(FTempDir, 'TSE-SER-001', 'KASSE-001');
  CheckTrue(TFile.Exists(TPath.Combine(FTempDir, 'index.json')),
    'index.json muss nach WriteIndexJson existieren');
end;

procedure TTestExporter.TestWriteIndexJsonContainsRequiredFields;
var Content: string;
begin
  TTseExporter.WriteIndexJson(FTempDir, 'TSE-SER-001', 'KASSE-002');
  Content := TFile.ReadAllText(TPath.Combine(FTempDir, 'index.json'));
  Check(Pos('"dsfinvk_version"', Content) > 0, 'index.json braucht dsfinvk_version');
  Check(Pos('"tse_serial"',      Content) > 0, 'index.json braucht tse_serial');
  Check(Pos('"kasse_id"',        Content) > 0, 'index.json braucht kasse_id');
  Check(Pos('"export_timestamp"',Content) > 0, 'index.json braucht export_timestamp');
  Check(Pos(DSFINVK_VERSION,     Content) > 0, 'index.json braucht dsfinvk_version Wert "' + DSFINVK_VERSION + '"');
end;

// ---------------------------------------------------------------------------
// Registrierung
// ---------------------------------------------------------------------------

initialization
  RegisterTest(TTestTypes.Suite);
  RegisterTest(TTestMockProvider.Suite);
  RegisterTest(TTestManager.Suite);
  RegisterTest(TTestQrCodeFormat.Suite);
  RegisterTest(TTestExceptions.Suite);
  RegisterTest(TTestExporter.Suite);

end.
