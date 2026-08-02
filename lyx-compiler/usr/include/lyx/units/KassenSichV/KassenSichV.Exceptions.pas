/// <summary>
/// KassenSichV.Exceptions — Strukturierte Exception-Hierarchie der TseCore-Bibliothek.
/// WP-TSE-08
///
/// Alle TSE-spezifischen Fehler leiten von ETseException ab.
/// Kassensoftware-Entwickler fangen ETseException und reagieren auf Unterklassen.
/// ErrorCode orientiert sich an HTTP-Statuscodes (408, 400, 503 …).
/// </summary>
unit KassenSichV.Exceptions;

interface

uses
  System.SysUtils;

type
  /// <summary>
  /// Basisklasse aller KassenSichV-Exceptions.
  /// Erweitert Exception um ErrorCode und ProviderInfo für differenzierte Fehlerbehandlung.
  /// </summary>
  ETseException = class(Exception)
  private
    FErrorCode:   Integer;
    FProviderInfo: string;
  public
    /// <param name="AMessage">Deutschsprachige Fehlermeldung</param>
    /// <param name="AErrorCode">HTTP-analoger Fehlercode (400/403/408/503…)</param>
    /// <param name="AProviderInfo">Bezeichner des auslösenden Providers (für Logging)</param>
    constructor Create(const AMessage: string;
                       AErrorCode:    Integer = 0;
                       const AProviderInfo: string = ''); reintroduce;
    /// <summary>HTTP-analoger Fehlercode: 408=Timeout, 503=Verbindung, 400=Konfiguration</summary>
    property ErrorCode:    Integer read FErrorCode;
    /// <summary>Klassenname des Providers, der die Exception ausgelöst hat</summary>
    property ProviderInfo: string  read FProviderInfo;
  end;

  /// <summary>
  /// Verbindungsfehler zur TSE (Netzwerk, USB, Datei-Interface nicht erreichbar).
  /// ErrorCode: 503
  /// </summary>
  ETseConnectionError = class(ETseException);

  /// <summary>
  /// Timeout bei der Kommunikation mit der TSE.
  /// ErrorCode: 408
  /// </summary>
  ETseTimeoutError = class(ETseException);

  /// <summary>
  /// Fehler beim Signiervorgang innerhalb der TSE (z.B. Schlüssel ungültig).
  /// ErrorCode: 500
  /// </summary>
  ETseSignatureError = class(ETseException);

  /// <summary>
  /// Ungültige oder unvollständige Konfiguration (fehlende ConfigData-Felder).
  /// ErrorCode: 400
  /// </summary>
  ETseConfigurationError = class(ETseException);

  /// <summary>
  /// Fehler im TSE-Transaktionsprotokoll (offene Transaktion, ungültige TransId …).
  /// Offene Transaktionen sind ein Compliance-Problem — sofort behandeln.
  /// ErrorCode: 409 (Conflict)
  /// </summary>
  ETseTransactionError = class(ETseException);

  /// <summary>
  /// Exportverzeichnis nicht schreibbar oder Export fehlgeschlagen.
  /// ErrorCode: 403
  /// </summary>
  ETseExportError = class(ETseException);

implementation

constructor ETseException.Create(const AMessage: string;
                                  AErrorCode:    Integer;
                                  const AProviderInfo: string);
begin
  inherited Create(AMessage);
  FErrorCode    := AErrorCode;
  FProviderInfo := AProviderInfo;
end;

end.
