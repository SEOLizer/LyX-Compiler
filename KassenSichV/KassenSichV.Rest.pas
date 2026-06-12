/// <summary>
/// KassenSichV.Rest — TRestTseProvider: Cloud-TSE-Anbindung über HTTPS/REST.
/// WP-TSE-06
///
/// Unterstützt Fiskaly, Deutsche Fiskal und kompatible APIs.
/// Retry-Logik: max. 3 Versuche bei HTTP 503/504, exponentielles Backoff (1s→2s→4s).
/// TLS 1.2 mindestens erzwungen. api_key wird nie geloggt.
/// </summary>
unit KassenSichV.Rest;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.JSON,
  System.DateUtils,
  System.IOUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Exceptions;

type
  /// <summary>
  /// Provider für Cloud-TSE-Anbieter (Fiskaly, Deutsche Fiskal).
  ///
  /// ConfigData (JSON-Pflichtfelder):
  ///   "api_url"   — Basis-URL der TSE-API (z.B. "https://kassensichv.io/api/v1")
  ///   "api_key"   — Bearer-Token (wird nie geloggt)
  ///   "client_id" — Kassen-ID beim Cloud-Anbieter
  ///
  /// Optional:
  ///   "connect_timeout_ms" — Standard: 5000
  ///   "read_timeout_ms"    — Standard: 10000
  /// </summary>
  TRestTseProvider = class(TTseProviderBase)
  private
    FApiUrl:      string;
    FApiKey:      string;
    FClientId:    string;
    FSeriennummer: string;
    FHttpClient:  THTTPClient;
    procedure ParseConfig(const ConfigData: string);
    function  PostJson(const APath: string; const ABody: string): TJSONObject;
    function  GetJson(const APath: string): TJSONObject;
    function  BuildTransactionBody(const Beleg: TBelegDaten): string;
    function  ParseSignaturErgebnis(Json: TJSONObject;
                                    const StartTs: TDateTime): TSignaturErgebnis;
    procedure EnsureInitialized;
    function  MaskApiKey(const AKey: string): string;
  public
    constructor Create; override;
    destructor  Destroy; override;

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
  DEFAULT_CONNECT_TIMEOUT_MS = 5000;
  DEFAULT_READ_TIMEOUT_MS    = 10000;
  MAX_RETRIES                = 3;

constructor TRestTseProvider.Create;
begin
  inherited Create;
  FHttpClient := THTTPClient.Create;
  FHttpClient.ConnectionTimeout := DEFAULT_CONNECT_TIMEOUT_MS;
  FHttpClient.ResponseTimeout   := DEFAULT_READ_TIMEOUT_MS;
  // TLS 1.2 mindestens erzwingen (KassenSichV-Anforderung)
  FHttpClient.SecureProtocols := [THTTPSecureProtocol.TLS12, THTTPSecureProtocol.TLS13];
end;

destructor TRestTseProvider.Destroy;
begin
  FHttpClient.Free;
  inherited Destroy;
end;

function TRestTseProvider.MaskApiKey(const AKey: string): string;
begin
  if Length(AKey) <= 4 then Result := '***'
  else                      Result := Copy(AKey, 1, 4) + '***';
end;

procedure TRestTseProvider.ParseConfig(const ConfigData: string);
var
  Json: TJSONObject;

  function RequireField(const AName: string): string;
  var V: TJSONValue;
  begin
    V := Json.GetValue(AName);
    if V = nil then
      raise ETseConfigurationError.Create(
        Format('%s fehlt in ConfigData.', [AName]), 400, 'RestTseProvider');
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
    raise ETseConfigurationError.Create('ConfigData ist kein gültiges JSON.', 400);
  try
    FApiUrl   := RequireField('api_url');
    FApiKey   := RequireField('api_key');
    FClientId := RequireField('client_id');
    FHttpClient.ConnectionTimeout := OptionalInt('connect_timeout_ms', DEFAULT_CONNECT_TIMEOUT_MS);
    FHttpClient.ResponseTimeout   := OptionalInt('read_timeout_ms',    DEFAULT_READ_TIMEOUT_MS);
  finally
    Json.Free;
  end;
end;

procedure TRestTseProvider.EnsureInitialized;
begin
  if FApiUrl = '' then
    raise ETseConfigurationError.Create(
      'RestTseProvider nicht initialisiert — Initialize() zuerst aufrufen.', 400);
end;

function TRestTseProvider.PostJson(const APath: string; const ABody: string): TJSONObject;
var
  Url:        string;
  BodyStream: TStringStream;
  Response:   IHTTPResponse;
  Attempt:    Integer;
  WaitMs:     Integer;
begin
  EnsureInitialized;
  Url    := FApiUrl + APath;
  WaitMs := 1000;

  for Attempt := 1 to MAX_RETRIES do
  begin
    BodyStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      try
        // api_key nie in Log ausgeben
        FHttpClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
        FHttpClient.CustomHeaders['Content-Type']  := 'application/json';
        Response := FHttpClient.Post(Url, BodyStream);

        case Response.StatusCode of
          200, 201, 204:
            begin
              if Response.ContentAsString <> '' then
                Result := TJSONObject.ParseJSONValue(Response.ContentAsString) as TJSONObject
              else
                Result := nil;
              Exit;
            end;
          503, 504:
            begin
              LogFmt('HTTP %d — Retry %d/%d nach %d ms',
                [Response.StatusCode, Attempt, MAX_RETRIES, WaitMs]);
              if Attempt < MAX_RETRIES then
              begin
                Sleep(WaitMs);
                WaitMs := WaitMs * 2; // exponentielles Backoff
              end;
            end;
        else
          raise ETseConnectionError.Create(
            Format('HTTP %d von %s: %s',
              [Response.StatusCode, Url, Response.ContentAsString]),
            Response.StatusCode, 'RestTseProvider');
        end;
      except
        on E: ETseException do raise;
        on E: Exception do
        begin
          LogFmt('Verbindungsfehler (Versuch %d/%d): %s', [Attempt, MAX_RETRIES, E.Message]);
          if Attempt = MAX_RETRIES then
            raise ETseConnectionError.Create(
              Format('Verbindungsfehler nach %d Versuchen: %s', [MAX_RETRIES, E.Message]),
              503, 'RestTseProvider');
          Sleep(WaitMs);
          WaitMs := WaitMs * 2;
        end;
      end;
    finally
      BodyStream.Free;
    end;
  end;

  raise ETseConnectionError.Create(
    Format('Keine Antwort nach %d Versuchen (URL: %s)', [MAX_RETRIES, Url]),
    503, 'RestTseProvider');
end;

function TRestTseProvider.GetJson(const APath: string): TJSONObject;
var
  Response: IHTTPResponse;
begin
  EnsureInitialized;
  FHttpClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
  Response := FHttpClient.Get(FApiUrl + APath);
  if Response.StatusCode = 200 then
    Result := TJSONObject.ParseJSONValue(Response.ContentAsString) as TJSONObject
  else
    raise ETseConnectionError.Create(
      Format('HTTP %d bei GET %s', [Response.StatusCode, APath]),
      Response.StatusCode, 'RestTseProvider');
end;

function TRestTseProvider.BuildTransactionBody(const Beleg: TBelegDaten): string;
begin
  Result := Format(
    '{"client_id":"%s","process_type":"%s","process_data":"%s"}',
    [FClientId, Beleg.ProzessTyp, Beleg.ProzessDaten]);
end;

function TRestTseProvider.ParseSignaturErgebnis(Json: TJSONObject;
                                                const StartTs: TDateTime): TSignaturErgebnis;

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

begin
  Result := Default(TSignaturErgebnis);
  if Json = nil then Exit;
  Result.TseSeriennummer     := GetStr('tse_serial');
  Result.SignaturZaehler     := GetInt64('signature_counter');
  Result.SignaturWert        := GetStr('signature_value');
  Result.AnzahlTransaktionen := GetInt64('transaction_counter');
  Result.StartZeitpunkt      := StartTs;
  Result.EndZeitpunkt        := Now;
  Result.Erfolg              := Result.TseSeriennummer <> '';
  if not Result.Erfolg then
    Result.FehlerMeldung := 'Kein tse_serial in API-Antwort';
end;

procedure TRestTseProvider.Initialize(const ConfigData: string);
var
  Json: TJSONObject;
  Val:  TJSONValue;
begin
  ParseConfig(ConfigData);
  LogFmt('RestTseProvider: api_url=%s api_key=%s client_id=%s',
    [FApiUrl, MaskApiKey(FApiKey), FClientId]);

  // Seriennummer abrufen (Fehler ist nicht fatal — Initialize bleibt trotzdem erfolgreich)
  try
    Json := GetJson('/tss/' + FClientId);
    if Json <> nil then
    try
      Val := Json.GetValue('serial_number');
      if Val <> nil then FSeriennummer := Val.Value;
    finally
      Json.Free;
    end;
  except
    on E: Exception do
      Log('Warnung: Seriennummer nicht abrufbar: ' + E.Message);
  end;
end;

function TRestTseProvider.GetSeriennummer: string;
begin
  Result := FSeriennummer;
end;

function TRestTseProvider.StartTransaction(var Beleg: TBelegDaten): string;
var
  Json: TJSONObject;
  Val:  TJSONValue;
begin
  EnsureInitialized;
  Json := PostJson('/tx', BuildTransactionBody(Beleg));
  try
    if Json = nil then
      raise ETseTransactionError.Create(
        'StartTransaction: leere Antwort von API.', 503, 'RestTseProvider');
    Val := Json.GetValue('_id');
    if Val = nil then
      raise ETseTransactionError.Create(
        'StartTransaction: kein "_id" in Antwort.', 503, 'RestTseProvider');
    Result           := Val.Value;
    Beleg.TransId    := Result;
    Beleg.StartZeitpunkt := Now;
    LogFmt('StartTransaction: TransId=%s', [Result]);
  finally
    Json.Free;
  end;
end;

function TRestTseProvider.UpdateTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  Json: TJSONObject;
begin
  EnsureInitialized;
  Json := PostJson('/tx/' + TransId, BuildTransactionBody(Daten));
  try
    Result := ParseSignaturErgebnis(Json, Daten.StartZeitpunkt);
  finally
    Json.Free;
  end;
end;

function TRestTseProvider.FinishTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  Json: TJSONObject;
  Body: string;
begin
  EnsureInitialized;
  Body := Format(
    '{"state":"FINISHED","process_type":"%s","process_data":"%s"}',
    [Daten.ProzessTyp, Daten.ProzessDaten]);
  Json := PostJson('/tx/' + TransId, Body);
  try
    Result := ParseSignaturErgebnis(Json, Daten.StartZeitpunkt);
    LogFmt('FinishTransaction: TransId=%s Erfolg=%s', [TransId, BoolToStr(Result.Erfolg, True)]);
  finally
    Json.Free;
  end;
end;

procedure TRestTseProvider.ExportAuditData(const TargetPath: string);
var
  TarPath:   string;
  TarStream: TFileStream;
  Response:  IHTTPResponse;
begin
  EnsureInitialized;
  TarPath := TPath.Combine(TargetPath, 'tse_export.tar');
  FHttpClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
  Response  := FHttpClient.Get(FApiUrl + '/export/' + FClientId);
  TarStream := TFileStream.Create(TarPath, fmCreate);
  try
    TarStream.CopyFrom(Response.ContentStream, 0);
  finally
    TarStream.Free;
  end;
  LogFmt('ExportAuditData: %s gespeichert', [TarPath]);
end;

function TRestTseProvider.GetStatus: string;
begin
  EnsureInitialized;
  try
    var Json := GetJson('/status/' + FClientId);
    try
      if Json <> nil then Result := Json.ToJSON
      else               Result := '{"status":"unknown"}';
    finally
      Json.Free;
    end;
  except
    on E: Exception do
      Result := Format('{"status":"error","message":"%s"}', [E.Message]);
  end;
end;

end.
