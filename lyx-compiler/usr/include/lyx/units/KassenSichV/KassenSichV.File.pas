/// <summary>
/// KassenSichV.File — TFileTseProvider: Dateibasierte USB-TSE-Anbindung.
/// WP-TSE-07
///
/// Unterstützt Swissbit, Epson und andere USB-TSEs, die über ein Dateisystem kommunizieren.
/// Protokoll: Schreibe {TransId}_req.json in BasePath; pollen für {TransId}_res.json.
/// Poll-Intervall: 100ms. ETseTimeoutError wenn nach timeout_ms keine Antwort.
/// </summary>
unit KassenSichV.File;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.DateUtils,
  System.IOUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Exceptions;

type
  /// <summary>
  /// Provider für dateisystembasierte USB-TSEs (Swissbit, Epson).
  ///
  /// ConfigData (JSON-Pflichtfelder):
  ///   "base_path"    — Pfad zum USB-TSE-Dateisystem (Laufwerksbuchstabe oder Mount-Punkt)
  ///
  /// Optional:
  ///   "timeout_ms"   — Standard: 5000 (ms bis ETseTimeoutError)
  ///   "poll_ms"      — Standard: 100  (ms zwischen Datei-Checks)
  /// </summary>
  TFileTseProvider = class(TTseProviderBase)
  private
    FBasePath:    string;
    FTimeoutMs:   Integer;
    FPollMs:      Integer;
    FSeriennummer: string;
    procedure ParseConfig(const ConfigData: string);
    function  ReadSeriennummer: string;
    function  RequestFilePath(const TransId: string): string;
    function  ResponseFilePath(const TransId: string): string;
    function  WriteRequest(const TransId: string; const Body: string): string;
    function  PollResponse(const TransId: string): TJSONObject;
    function  BuildRequestJson(const Beleg: TBelegDaten; const AState: string): string;
    function  ParseResponse(Json: TJSONObject; const StartTs: TDateTime): TSignaturErgebnis;
    procedure CleanupFiles(const TransId: string);
  public
    constructor Create; override;

    procedure Initialize(const ConfigData: string); override;
    function  GetSeriennummer: string; override;
    function  StartTransaction(var Beleg: TBelegDaten): string; override;
    function  UpdateTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; override;
    function  FinishTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; override;
    procedure ExportAuditData(const TargetPath: string); override;
    function  GetStatus: string; override;
  end;

implementation

const
  DEFAULT_TIMEOUT_MS = 5000;
  DEFAULT_POLL_MS    = 100;
  SERIAL_FILE        = 'tse_serial.txt';
  EXPORT_TAR         = 'tse_export.tar';
  EXPORT_TRIGGER     = 'export_req';

constructor TFileTseProvider.Create;
begin
  inherited Create;
  FTimeoutMs := DEFAULT_TIMEOUT_MS;
  FPollMs    := DEFAULT_POLL_MS;
end;

procedure TFileTseProvider.ParseConfig(const ConfigData: string);
var
  Json: TJSONObject;

  function RequireField(const AName: string): string;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName);
    if V = nil then
      raise ETseConfigurationError.Create(
        Format('%s fehlt in ConfigData.', [AName]), 400, 'FileTseProvider');
    Result := V.Value;
  end;

  function OptionalInt(const AName: string; ADefault: Integer): Integer;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName);
    if V <> nil then Result := V.AsType<Integer>
    else             Result := ADefault;
  end;

begin
  Json := TJSONObject.ParseJSONValue(ConfigData) as TJSONObject;
  if Json = nil then
    raise ETseConfigurationError.Create('ConfigData ist kein gültiges JSON.', 400, 'FileTseProvider');
  try
    FBasePath  := RequireField('base_path');
    FTimeoutMs := OptionalInt('timeout_ms', DEFAULT_TIMEOUT_MS);
    FPollMs    := OptionalInt('poll_ms',    DEFAULT_POLL_MS);
  finally
    Json.Free;
  end;
end;

function TFileTseProvider.ReadSeriennummer: string;
var
  SerialPath: string;
begin
  SerialPath := TPath.Combine(FBasePath, SERIAL_FILE);
  if TFile.Exists(SerialPath) then
    Result := Trim(TFile.ReadAllText(SerialPath))
  else
    Result := '';
end;

function TFileTseProvider.RequestFilePath(const TransId: string): string;
begin
  Result := TPath.Combine(FBasePath, TransId + '_req.json');
end;

function TFileTseProvider.ResponseFilePath(const TransId: string): string;
begin
  Result := TPath.Combine(FBasePath, TransId + '_res.json');
end;

function TFileTseProvider.BuildRequestJson(const Beleg:  TBelegDaten;
                                           const AState: string): string;
begin
  Result := Format(
    '{"trans_id":"%s","state":"%s","process_type":"%s","process_data":"%s"}',
    [Beleg.TransId, AState, Beleg.ProzessTyp, Beleg.ProzessDaten]);
end;

function TFileTseProvider.WriteRequest(const TransId: string; const Body: string): string;
var
  ReqPath: string;
begin
  if not TDirectory.Exists(FBasePath) then
    raise ETseConnectionError.Create(
      Format('USB-TSE-Pfad nicht gefunden: %s', [FBasePath]), 503, 'FileTseProvider');
  ReqPath := RequestFilePath(TransId);
  TFile.WriteAllText(ReqPath, Body, TEncoding.UTF8);
  LogFmt('WriteRequest: %s', [ReqPath]);
  Result := ReqPath;
end;

function TFileTseProvider.PollResponse(const TransId: string): TJSONObject;
var
  ResPath:  string;
  Elapsed:  Integer;
  Content:  string;
begin
  ResPath := ResponseFilePath(TransId);
  Elapsed := 0;
  repeat
    if TFile.Exists(ResPath) then
    begin
      // Kurze Pause sicherstellen dass das TSE-System fertig geschrieben hat
      Sleep(10);
      try
        Content := TFile.ReadAllText(ResPath, TEncoding.UTF8);
        Result  := TJSONObject.ParseJSONValue(Content) as TJSONObject;
        if Result <> nil then
        begin
          LogFmt('PollResponse: %s nach %d ms', [ResPath, Elapsed]);
          Exit;
        end;
      except
        // JSON noch nicht vollständig geschrieben — weiter warten
      end;
    end;
    Sleep(FPollMs);
    Inc(Elapsed, FPollMs);
  until Elapsed >= FTimeoutMs;

  raise ETseTimeoutError.Create(
    Format('Keine Antwort von USB-TSE nach %d ms (TransId=%s)', [FTimeoutMs, TransId]),
    408, 'FileTseProvider');
end;

function TFileTseProvider.ParseResponse(Json:            TJSONObject;
                                        const StartTs:   TDateTime): TSignaturErgebnis;

  function GetStr(const AName: string): string;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName); if V <> nil then Result := V.Value else Result := '';
  end;

  function GetInt64(const AName: string): Int64;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName); if V <> nil then Result := V.AsType<Int64> else Result := 0;
  end;

  function GetBool(const AName: string): Boolean;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName);
    Result := (V <> nil) and (V is TJSONTrue);
  end;

begin
  Result := Default(TSignaturErgebnis);
  Result.TseSeriennummer     := GetStr('tse_serial');
  Result.SignaturZaehler     := GetInt64('signature_counter');
  Result.SignaturWert        := GetStr('signature_value');
  Result.AnzahlTransaktionen := GetInt64('transaction_counter');
  Result.StartZeitpunkt      := StartTs;
  Result.EndZeitpunkt        := Now;
  Result.Erfolg              := GetBool('success');
  if not Result.Erfolg then
    Result.FehlerMeldung := GetStr('error');
end;

procedure TFileTseProvider.CleanupFiles(const TransId: string);
var
  ReqPath, ResPath: string;
begin
  ReqPath := RequestFilePath(TransId);
  ResPath := ResponseFilePath(TransId);
  if TFile.Exists(ReqPath) then TFile.Delete(ReqPath);
  if TFile.Exists(ResPath) then TFile.Delete(ResPath);
end;

procedure TFileTseProvider.Initialize(const ConfigData: string);
begin
  ParseConfig(ConfigData);
  if not TDirectory.Exists(FBasePath) then
    raise ETseConnectionError.Create(
      Format('USB-TSE-Pfad nicht erreichbar: %s', [FBasePath]), 503, 'FileTseProvider');
  FSeriennummer := ReadSeriennummer;
  LogFmt('FileTseProvider: base_path=%s serial=%s timeout=%d ms',
    [FBasePath, FSeriennummer, FTimeoutMs]);
end;

function TFileTseProvider.GetSeriennummer: string;
begin
  Result := FSeriennummer;
end;

function TFileTseProvider.StartTransaction(var Beleg: TBelegDaten): string;
var
  TransId: string;
  Body:    string;
  Json:    TJSONObject;
  Val:     TJSONValue;
begin
  // TransId vom TSE-System vergeben lassen
  TransId         := 'START-' + FormatDateTime('yyyymmddhhnnsszzz', Now);
  Beleg.TransId   := TransId;
  Beleg.StartZeitpunkt := Now;

  Body := Format('{"state":"START","process_type":"%s","process_data":"%s"}',
    [Beleg.ProzessTyp, Beleg.ProzessDaten]);

  WriteRequest(TransId, Body);
  Json := PollResponse(TransId);
  try
    Val := Json.GetValue('trans_id');
    if Val <> nil then
    begin
      Beleg.TransId := Val.Value;
      TransId       := Beleg.TransId;
    end;
    Result := TransId;
    LogFmt('StartTransaction: TransId=%s', [TransId]);
  finally
    Json.Free;
    CleanupFiles(TransId);
  end;
end;

function TFileTseProvider.UpdateTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  Json: TJSONObject;
  Body: string;
  TmpBeleg: TBelegDaten;
begin
  TmpBeleg := Daten;
  TmpBeleg.TransId := TransId;
  Body := BuildRequestJson(TmpBeleg, 'UPDATE');
  WriteRequest(TransId, Body);
  Json := PollResponse(TransId);
  try
    Result := ParseResponse(Json, Daten.StartZeitpunkt);
  finally
    Json.Free;
    CleanupFiles(TransId);
  end;
end;

function TFileTseProvider.FinishTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  Json:     TJSONObject;
  Body:     string;
  TmpBeleg: TBelegDaten;
begin
  TmpBeleg := Daten;
  TmpBeleg.TransId := TransId;
  Body := BuildRequestJson(TmpBeleg, 'FINISH');
  WriteRequest(TransId, Body);
  Json := PollResponse(TransId);
  try
    Result := ParseResponse(Json, Daten.StartZeitpunkt);
    LogFmt('FinishTransaction: TransId=%s Erfolg=%s', [TransId, BoolToStr(Result.Erfolg, True)]);
  finally
    Json.Free;
    CleanupFiles(TransId);
  end;
end;

procedure TFileTseProvider.ExportAuditData(const TargetPath: string);
var
  TriggerPath: string;
  TarSrc:      string;
  TarDst:      string;
  Elapsed:     Integer;
begin
  // Export-Trigger schreiben (TSE erzeugt dann tse_export.tar)
  TriggerPath := TPath.Combine(FBasePath, EXPORT_TRIGGER);
  TFile.WriteAllText(TriggerPath, '1');

  // Warten bis tse_export.tar erscheint
  TarSrc  := TPath.Combine(FBasePath, EXPORT_TAR);
  Elapsed := 0;
  while (Elapsed < FTimeoutMs) and (not TFile.Exists(TarSrc)) do
  begin
    Sleep(FPollMs);
    Inc(Elapsed, FPollMs);
  end;

  if not TFile.Exists(TarSrc) then
    raise ETseExportError.Create(
      Format('USB-TSE hat kein %s nach %d ms erzeugt', [EXPORT_TAR, FTimeoutMs]), 408);

  TarDst := TPath.Combine(TargetPath, EXPORT_TAR);
  TFile.Copy(TarSrc, TarDst, True);

  // Trigger-Datei aufräumen
  if TFile.Exists(TriggerPath) then TFile.Delete(TriggerPath);

  LogFmt('ExportAuditData: %s → %s', [TarSrc, TarDst]);
end;

function TFileTseProvider.GetStatus: string;
var
  Online: string;
begin
  if TDirectory.Exists(FBasePath) then Online := 'online'
  else                                  Online := 'offline';
  Result := Format(
    '{"provider":"FileTseProvider","serial":"%s","status":"%s","base_path":"%s"}',
    [FSeriennummer, Online, FBasePath]);
end;

end.
