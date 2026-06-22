/// <summary>
/// KassenSichV.Manager — Hauptklasse TTseManager.
/// WP-TSE-03
///
/// Einstiegspunkt für Kassensoftware-Entwickler.
/// Orchestriert Start → Finish → QR-Code-Generierung nach BSI TR-03153 Anhang A.
///
/// HINWEIS: TTseManager ist NICHT thread-safe.
/// Pro physische Kasse genau eine Instanz verwenden.
/// </summary>
unit KassenSichV.Manager;

interface

uses
  System.SysUtils,
  System.DateUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Exceptions,
  KassenSichV.Export;

type
  /// <summary>
  /// Orchestriert den vollständigen KassenSichV-Transaktionsablauf.
  /// Injizieren Sie beim Create einen konkreten ITseProvider
  /// (TMockTseProvider, TRestTseProvider, TFileTseProvider).
  /// </summary>
  TTseManager = class
  private
    FProvider: ITseProvider;
    function GenerateQrCodeString(const SigData: TSignaturErgebnis): string;
    function FormatUTC(const ADateTime: TDateTime): string;
    procedure RaiseIfFailed(const SigData: TSignaturErgebnis;
                            const TransId:  string);
  public
    /// <summary>
    /// Erstellt einen Manager mit dem angegebenen Provider.
    /// Wirft ETseConfigurationError wenn AProvider = nil.
    /// </summary>
    constructor Create(AProvider: ITseProvider);
    destructor Destroy; override;

    /// <summary>
    /// Standard-Kassenvorgang: öffnet und schließt die TSE-Transaktion in einem Aufruf.
    /// Ablauf: StartTransaction → FinishTransaction → QR-Code setzen.
    /// Wirft ETseTransactionError wenn FinishTransaction fehlschlägt.
    /// Offene Transaktionen bei Fehler sind Compliance-relevant — nicht ignorieren.
    /// </summary>
    function ProcessBeleg(var Beleg: TBelegDaten): TSignaturErgebnis;

    /// <summary>
    /// Öffnet eine Transaktion für mehrstufige Vorgänge (z.B. Tischbewirtung).
    /// Gibt die TSE-interne TransId zurück. Beleg.TransId wird ebenfalls gesetzt.
    /// </summary>
    function OpenBeleg(var Beleg: TBelegDaten): string;

    /// <summary>
    /// Aktualisiert einen laufenden Vorgang (Zwischenstand).
    /// Erfordert vorherigen Aufruf von OpenBeleg.
    /// </summary>
    function UpdateBeleg(const TransId: string;
                         const Beleg: TBelegDaten): TSignaturErgebnis;

    /// <summary>
    /// Schließt einen mehrstufigen Vorgang ab und setzt QrCodeData im Ergebnis.
    /// Erfordert vorherigen Aufruf von OpenBeleg.
    /// Wirft ETseTransactionError bei Fehler.
    /// </summary>
    function CloseBeleg(const TransId: string;
                        const Beleg: TBelegDaten): TSignaturErgebnis;

    /// <summary>
    /// Exportiert das TSE-Audit-Log und schreibt index.json mit Metadaten.
    /// TargetPath muss existieren und schreibbar sein.
    /// </summary>
    procedure ExportAuditData(const TargetPath:       string;
                              const KassenSeriennummer: string);

    /// <summary>Gibt den aktuellen TSE-Status als JSON-String zurück</summary>
    function GetTseStatus: string;

    /// <summary>Gibt die Seriennummer der angebundenen TSE zurück</summary>
    function GetTseSeriennummer: string;
  end;

implementation

constructor TTseManager.Create(AProvider: ITseProvider);
begin
  if AProvider = nil then
    raise ETseConfigurationError.Create(
      'Provider darf nicht nil sein.', 400);
  inherited Create;
  FProvider := AProvider;
end;

destructor TTseManager.Destroy;
begin
  FProvider := nil;
  inherited Destroy;
end;

function TTseManager.FormatUTC(const ADateTime: TDateTime): string;
begin
  Result := FormatDateTime(TSE_DATETIME_FORMAT,
              TTimeZone.Local.ToUniversalTime(ADateTime));
end;

function TTseManager.GenerateQrCodeString(const SigData: TSignaturErgebnis): string;
begin
  // BSI TR-03153 Anhang A — exaktes Format, alle Felder Pflicht:
  // V0;{SerNr};{StartISO};{EndISO};{Zähler};{AnzTrans};{SigBase64}
  Result := Format('%s;%s;%s;%s;%d;%d;%s', [
    TSE_QR_PREFIX,
    SigData.TseSeriennummer,
    FormatUTC(SigData.StartZeitpunkt),
    FormatUTC(SigData.EndZeitpunkt),
    SigData.SignaturZaehler,
    SigData.AnzahlTransaktionen,
    SigData.SignaturWert
  ]);
end;

procedure TTseManager.RaiseIfFailed(const SigData: TSignaturErgebnis;
                                     const TransId:  string);
begin
  if not SigData.Erfolg then
    raise ETseTransactionError.Create(
      Format('TSE-Signierung fehlgeschlagen (TransId=%s): %s',
             [TransId, SigData.FehlerMeldung]), 409);
end;

function TTseManager.ProcessBeleg(var Beleg: TBelegDaten): TSignaturErgebnis;
begin
  // 1. Transaktion öffnen — TSE vergibt internen Zähler und Zeitstempel
  Beleg.TransId := FProvider.StartTransaction(Beleg);

  // 2. Transaktion abschließen — TSE signiert mit ECDSA-Schlüssel
  // Fehler hier sind ein Compliance-Problem: offene Transaktionen müssen sofort behandelt werden.
  try
    Result := FProvider.FinishTransaction(Beleg.TransId, Beleg);
  except
    on E: ETseException do
      raise ETseTransactionError.Create(
        Format('FinishTransaction fehlgeschlagen (TransId=%s): %s',
               [Beleg.TransId, E.Message]),
        E.ErrorCode, E.ProviderInfo);
    on E: Exception do
      raise ETseTransactionError.Create(
        Format('FinishTransaction fehlgeschlagen (TransId=%s): %s',
               [Beleg.TransId, E.Message]), 503);
  end;

  RaiseIfFailed(Result, Beleg.TransId);

  // 3. QR-Code-String nach BSI TR-03153 Anhang A zusammensetzen
  Result.QrCodeData := GenerateQrCodeString(Result);
end;

function TTseManager.OpenBeleg(var Beleg: TBelegDaten): string;
begin
  Beleg.TransId := FProvider.StartTransaction(Beleg);
  Result := Beleg.TransId;
end;

function TTseManager.UpdateBeleg(const TransId: string;
                                  const Beleg:   TBelegDaten): TSignaturErgebnis;
begin
  Result := FProvider.UpdateTransaction(TransId, Beleg);
end;

function TTseManager.CloseBeleg(const TransId: string;
                                 const Beleg:   TBelegDaten): TSignaturErgebnis;
begin
  try
    Result := FProvider.FinishTransaction(TransId, Beleg);
  except
    on E: ETseException do
      raise ETseTransactionError.Create(
        Format('CloseBeleg fehlgeschlagen (TransId=%s): %s', [TransId, E.Message]),
        E.ErrorCode, E.ProviderInfo);
    on E: Exception do
      raise ETseTransactionError.Create(
        Format('CloseBeleg fehlgeschlagen (TransId=%s): %s', [TransId, E.Message]), 503);
  end;

  RaiseIfFailed(Result, TransId);
  Result.QrCodeData := GenerateQrCodeString(Result);
end;

procedure TTseManager.ExportAuditData(const TargetPath:        string;
                                       const KassenSeriennummer: string);
begin
  TTseExporter.EnsureWritable(TargetPath);
  FProvider.ExportAuditData(TargetPath);
  TTseExporter.WriteIndexJson(TargetPath, FProvider.GetSeriennummer, KassenSeriennummer);
end;

function TTseManager.GetTseStatus: string;
begin
  Result := FProvider.GetStatus;
end;

function TTseManager.GetTseSeriennummer: string;
begin
  Result := FProvider.GetSeriennummer;
end;

end.
