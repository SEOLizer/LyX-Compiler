/// <summary>
/// KassenSichV.Mock — TMockTseProvider: Test-Doppelgänger ohne echte TSE.
/// WP-TSE-05
///
/// Erzeugt deterministische SHA-256-basierte Testsignaturen (kein ECDSA).
/// Konfigurierbar für Fehlersimulation — alle Negativtests ohne Hardware möglich.
/// Kein externer Abhängigkeit außer System.* und KassenSichV.*.
/// </summary>
unit KassenSichV.Mock;

interface

uses
  System.SysUtils,
  System.DateUtils,
  System.NetEncoding,
  System.Hash,
  System.IOUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Exceptions;

type
  /// <summary>
  /// Vollständige ITseProvider-Implementierung ohne physische TSE.
  /// Für Unit-Tests, CI/CD und Bondrucktests.
  ///
  /// Signaturwert: SHA-256(TransId + Zeitstempel) → Base64 — deterministisch, nicht kryptografisch.
  /// Zähler: startet bei 0, monoton steigend je FinishTransaction-Aufruf.
  /// </summary>
  TMockTseProvider = class(TTseProviderBase)
  private
    FSeriennummer:     string;
    FSignaturZaehler:  Int64;
    FSimulateError:    Boolean;
    FSimulateTimeout:  Boolean;
    FLastBeleg:        TBelegDaten;
    FLastSignatur:     TSignaturErgebnis;
    function ComputeMockSignature(const ATransId:  string;
                                  const ADateTime: TDateTime): string;
    function BuildEmptyErgebnis: TSignaturErgebnis;
  public
    constructor Create; override;

    // ITseProvider
    procedure Initialize(const ConfigData: string); override;
    function  GetSeriennummer: string; override;
    function  StartTransaction(var Beleg: TBelegDaten): string; override;
    function  UpdateTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; override;
    function  FinishTransaction(const TransId: string;
                                const Daten:   TBelegDaten): TSignaturErgebnis; override;
    procedure ExportAuditData(const TargetPath: string); override;
    function  GetStatus: string; override;

    /// <summary>True → FinishTransaction wirft ETseConnectionError</summary>
    property SimulateError:    Boolean  read FSimulateError   write FSimulateError;
    /// <summary>True → FinishTransaction wirft ETseTimeoutError</summary>
    property SimulateTimeout:  Boolean  read FSimulateTimeout write FSimulateTimeout;
    /// <summary>Letzter verarbeiteter TBelegDaten (für Assertions in Tests)</summary>
    property LastBeleg:        TBelegDaten      read FLastBeleg;
    /// <summary>Letztes TSignaturErgebnis (QrCodeData nach Manager-Aufruf befüllt)</summary>
    property LastSignatur:     TSignaturErgebnis read FLastSignatur;
    /// <summary>Aktueller Transaktionszähler (monoton steigend, startet bei 0)</summary>
    property SignaturZaehler:  Int64    read FSignaturZaehler;
  end;

implementation

const
  MOCK_SERIAL = 'MOCK-TSE-0000000000000001';

constructor TMockTseProvider.Create;
begin
  inherited Create;
  FSeriennummer    := MOCK_SERIAL;
  FSignaturZaehler := 0;
  FSimulateError   := False;
  FSimulateTimeout := False;
end;

function TMockTseProvider.ComputeMockSignature(const ATransId:  string;
                                               const ADateTime: TDateTime): string;
var
  Input: string;
  Hash:  TBytes;
begin
  // SHA-256(TransId + Zeitstempel-Millisekunden) → Base64
  // Deterministisch, aber nicht kryptografisch — nur für Tests.
  Input := ATransId + FormatDateTime('yyyymmddhhnnsszzz', ADateTime);
  Hash  := THashSHA2.GetHashBytes(Input);
  Result := TNetEncoding.Base64.EncodeBytesToString(Hash);
end;

function TMockTseProvider.BuildEmptyErgebnis: TSignaturErgebnis;
begin
  Result := Default(TSignaturErgebnis);
  Result.TseSeriennummer    := FSeriennummer;
  Result.AnzahlTransaktionen := FSignaturZaehler;
end;

procedure TMockTseProvider.Initialize(const ConfigData: string);
begin
  // Mock akzeptiert beliebige Konfiguration ohne Fehler
  Log('MockTseProvider: Initialize — kein Config-Parsing erforderlich');
end;

function TMockTseProvider.GetSeriennummer: string;
begin
  Result := FSeriennummer;
end;

function TMockTseProvider.StartTransaction(var Beleg: TBelegDaten): string;
begin
  if Beleg.TransId = '' then
    Beleg.TransId := 'MOCK-TX-' + FormatDateTime('yyyymmddhhnnsszzz', Now);
  Beleg.StartZeitpunkt := Now;
  LogFmt('StartTransaction: TransId=%s', [Beleg.TransId]);
  Result := Beleg.TransId;
end;

function TMockTseProvider.UpdateTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  EndTs: TDateTime;
begin
  EndTs  := Now;
  Result := BuildEmptyErgebnis;
  Result.SignaturZaehler  := FSignaturZaehler;
  Result.StartZeitpunkt   := Daten.StartZeitpunkt;
  Result.EndZeitpunkt     := EndTs;
  Result.SignaturWert      := ComputeMockSignature(TransId, EndTs);
  Result.Erfolg            := True;
  LogFmt('UpdateTransaction: TransId=%s', [TransId]);
end;

function TMockTseProvider.FinishTransaction(const TransId: string;
                                            const Daten:   TBelegDaten): TSignaturErgebnis;
var
  EndTs: TDateTime;
begin
  // Fehlersimulation — simulierte Szenarien für Negativtests
  if FSimulateTimeout then
    raise ETseTimeoutError.Create(
      Format('Simulierter Timeout (TransId=%s)', [TransId]), 408, 'MockTseProvider');

  if FSimulateError then
    raise ETseConnectionError.Create(
      Format('Simulierter Verbindungsfehler (TransId=%s)', [TransId]), 503, 'MockTseProvider');

  Inc(FSignaturZaehler);
  EndTs  := Now;

  Result := BuildEmptyErgebnis;
  Result.SignaturZaehler     := FSignaturZaehler;
  Result.AnzahlTransaktionen := FSignaturZaehler;
  Result.StartZeitpunkt      := Daten.StartZeitpunkt;
  Result.EndZeitpunkt        := EndTs;
  Result.SignaturWert         := ComputeMockSignature(TransId, EndTs);
  Result.Erfolg               := True;

  FLastBeleg   := Daten;
  FLastSignatur := Result;

  LogFmt('FinishTransaction: TransId=%s, Zähler=%d', [TransId, FSignaturZaehler]);
end;

procedure TMockTseProvider.ExportAuditData(const TargetPath: string);
var
  TarPath: string;
  F: TFileStream;
begin
  // Leere mock_audit.tar — Datei muss existieren, Inhalt irrelevant für Tests
  TarPath := TPath.Combine(TargetPath, 'mock_audit.tar');
  F := TFileStream.Create(TarPath, fmCreate);
  F.Free;
  LogFmt('ExportAuditData: %s erstellt (leer, Mock)', [TarPath]);
end;

function TMockTseProvider.GetStatus: string;
begin
  Result := Format(
    '{"provider":"MockTseProvider","serial":"%s","transactions":%d,' +
    '"simulate_error":%s,"simulate_timeout":%s}',
    [FSeriennummer, FSignaturZaehler,
     BoolToStr(FSimulateError,  'true', 'false'),
     BoolToStr(FSimulateTimeout,'true', 'false')]);
end;

end.
