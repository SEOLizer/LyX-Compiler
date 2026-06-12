/// <summary>
/// KassenSichV.Provider — ITseProvider Interface und abstrakte Basisklasse.
/// WP-TSE-02
///
/// Dependency-Inversion-Prinzip: Kassensoftware programmiert ausschließlich
/// gegen ITseProvider. Der konkrete Anbieter wird bei Initialisierung injiziert.
/// GUID des Interfaces ist fixiert — nie ändern (Delphi-Binärkompatibilität).
/// </summary>
unit KassenSichV.Provider;

interface

uses
  System.SysUtils,
  System.DateUtils,
  KassenSichV.Types,
  KassenSichV.Exceptions;

type
  /// <summary>Callback-Typ für optionales Logging aus Provider-Implementierungen</summary>
  TLogMessageEvent = reference to procedure(const AMessage: string);

  /// <summary>
  /// Kern-Interface für alle TSE-Provider.
  /// Alle konkreten Implementierungen (Cloud, Hardware, Mock, File) erfüllen dieses Interface.
  /// </summary>
  ITseProvider = interface
    ['{A3F1C2D4-8E5B-4A9F-BC01-7D3E6F2A1B94}']
    /// <summary>
    /// Initialisiert den Provider mit anbieterabhängiger JSON-Konfiguration.
    /// Wirft ETseConfigurationError bei fehlenden Pflichtfeldern.
    /// </summary>
    procedure Initialize(const ConfigData: string);

    /// <summary>Gibt die Seriennummer der angebundenen TSE zurück</summary>
    function GetSeriennummer: string;

    /// <summary>
    /// Öffnet eine neue TSE-Transaktion. Die TSE vergibt einen internen Zählerwert.
    /// Befüllt Beleg.TransId und Beleg.StartZeitpunkt.
    /// Gibt die TSE-interne TransId zurück.
    /// </summary>
    function StartTransaction(var Beleg: TBelegDaten): string;

    /// <summary>
    /// Aktualisiert eine laufende Transaktion (Zwischenstand, z.B. bei Tischbewirtung).
    /// Optionaler Schritt zwischen StartTransaction und FinishTransaction.
    /// </summary>
    function UpdateTransaction(const TransId: string;
                               const Daten:   TBelegDaten): TSignaturErgebnis;

    /// <summary>
    /// Schließt die Transaktion ab. Die TSE signiert mit ihrem ECDSA-Schlüssel.
    /// Liefert alle Pflichtangaben für den gesetzeskonformen Bondruck.
    /// Wirft ETseTransactionError bei Fehler — offene Transaktionen sind Compliance-relevant.
    /// </summary>
    function FinishTransaction(const TransId: string;
                               const Daten:   TBelegDaten): TSignaturErgebnis;

    /// <summary>
    /// Exportiert das TSE-Audit-Log als TAR-Datei in TargetPath (für Finanzamt).
    /// Wirft ETseExportError wenn TargetPath nicht schreibbar.
    /// </summary>
    procedure ExportAuditData(const TargetPath: string);

    /// <summary>
    /// Gibt den aktuellen Verbindungs- und Betriebsstatus der TSE als JSON-String zurück.
    /// Mindestfelder: "provider", "serial", "status".
    /// </summary>
    function GetStatus: string;
  end;

  /// <summary>
  /// Abstrakte Basisklasse für alle Provider-Implementierungen.
  /// Übernimmt: Logging-Callback, ISO-8601-Datumsformatierung, Exception-Wrapping.
  /// Konkrete Subklassen implementieren die abstract-Methoden.
  /// </summary>
  TTseProviderBase = class(TInterfacedObject, ITseProvider)
  private
    FOnLogMessage: TLogMessageEvent;
  protected
    /// <summary>Schreibt eine Log-Zeile (Zeitstempel + Klassenname vorangestellt)</summary>
    procedure Log(const AMessage: string);
    /// <summary>Schreibt eine formatierte Log-Zeile</summary>
    procedure LogFmt(const AFormat: string; const AArgs: array of const);
    /// <summary>
    /// Formatiert ADateTime als UTC ISO-8601-String mit Suffix 'Z'.
    /// Verwendet für QR-Code-Felder und DSFinV-K-Export.
    /// </summary>
    function FormatUTC(const ADateTime: TDateTime): string;
    /// <summary>
    /// Wrapped eine nicht-TSE-Exception in die passende ETseException-Unterklasse.
    /// Verhindert, dass raw EInOutError o.Ä. nach außen dringen.
    /// </summary>
    procedure WrapAndRaise(E: Exception; const AContext: string); virtual;
  public
    constructor Create; virtual;

    /// <summary>Optionaler Log-Callback — nil = kein Logging</summary>
    property OnLogMessage: TLogMessageEvent read FOnLogMessage write FOnLogMessage;

    // ITseProvider — alle abstract
    procedure Initialize(const ConfigData: string); virtual; abstract;
    function  GetSeriennummer: string; virtual; abstract;
    function  StartTransaction(var Beleg: TBelegDaten): string; virtual; abstract;
    function  UpdateTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; virtual; abstract;
    function  FinishTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; virtual; abstract;
    procedure ExportAuditData(const TargetPath: string); virtual; abstract;
    function  GetStatus: string; virtual; abstract;
  end;

implementation

constructor TTseProviderBase.Create;
begin
  inherited Create;
  FOnLogMessage := nil;
end;

procedure TTseProviderBase.Log(const AMessage: string);
begin
  if Assigned(FOnLogMessage) then
    FOnLogMessage(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) +
                  ' [' + ClassName + '] ' + AMessage);
end;

procedure TTseProviderBase.LogFmt(const AFormat: string; const AArgs: array of const);
begin
  Log(Format(AFormat, AArgs));
end;

function TTseProviderBase.FormatUTC(const ADateTime: TDateTime): string;
begin
  Result := FormatDateTime(TSE_DATETIME_FORMAT,
              TTimeZone.Local.ToUniversalTime(ADateTime));
end;

procedure TTseProviderBase.WrapAndRaise(E: Exception; const AContext: string);
begin
  if E is ETseException then
    raise E
  else if E is EInOutError then
    raise ETseConnectionError.Create(
      Format('I/O-Fehler in %s: %s', [AContext, E.Message]), 503, ClassName)
  else
    raise ETseConnectionError.Create(
      Format('Unerwarteter Fehler in %s: %s', [AContext, E.Message]), 503, ClassName);
end;

end.
