/// <summary>
/// KassenSichV.Types — Zentrale Typdefinitionen der TseCore-Bibliothek.
/// WP-TSE-01
///
/// Enthält ausschließlich Records, Enumerationen und Konstanten.
/// Keine Logik, keine externen Abhängigkeiten (nur System.*).
/// </summary>
unit KassenSichV.Types;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils;

type
  /// <summary>
  /// Eingangsdaten eines Kassenbelegs für die TSE-Signierung.
  /// Value-Semantik (record), UTC-basierte Zeitfelder, Currency für Geldbeträge.
  /// </summary>
  TBelegDaten = record
    /// <summary>Interne Vorgangs-ID der Kasse (wird von StartTransaction befüllt)</summary>
    TransId: string;
    /// <summary>Beginn des Vorgangs (UTC)</summary>
    StartZeitpunkt: TDateTime;
    /// <summary>Ende des Vorgangs (UTC)</summary>
    EndZeitpunkt: TDateTime;
    /// <summary>
    /// Kumulierter Brutto-Umsatz (4 Dezimalstellen, BCD-intern).
    /// Currency statt Double — keine IEEE-754-Rundungsfehler bei Geldbeträgen.
    /// </summary>
    UmsatzZaehler: Currency;
    /// <summary>Geräte-ID laut DSFinV-K (Kassenseriennummer des Betreibers)</summary>
    KassenSeriennummer: string;
    /// <summary>
    /// BSI-Prozesstyp nach TR-03153, z.B. PROZESSTYP_KASSENBELEG.
    /// String (keine Enum) — neue BSI-Werte ohne Code-Änderung möglich.
    /// </summary>
    ProzessTyp: string;
    /// <summary>Strukturierter Payload (DSFinV-K-konformes JSON, anbieterabhängig)</summary>
    ProzessDaten: string;
  end;

  /// <summary>
  /// Steuerliche Pflichtangaben für den Bondruck nach KassenSichV / BSI TR-03153.
  /// Alle 7 Pflichtfelder gemäß Anhang A der TR-03153.
  /// </summary>
  TSignaturErgebnis = record
    /// <summary>Seriennummer der zertifizierten TSE (Pflichtangabe auf Bon)</summary>
    TseSeriennummer: string;
    /// <summary>Fortlaufender Vorgangszähler der TSE (Pflichtangabe auf Bon)</summary>
    SignaturZaehler: Int64;
    /// <summary>Offizieller Startzeitpunkt laut TSE, UTC (Pflichtangabe auf Bon)</summary>
    StartZeitpunkt: TDateTime;
    /// <summary>Offizieller Endzeitpunkt laut TSE, UTC (Pflichtangabe auf Bon)</summary>
    EndZeitpunkt: TDateTime;
    /// <summary>Kryptografischer Prüfwert, Base64-kodiert (ECDSA/SHA-256, Pflichtangabe)</summary>
    SignaturWert: string;
    /// <summary>Gesamtzähler aller Transaktionen dieser TSE-Einheit</summary>
    AnzahlTransaktionen: Int64;
    /// <summary>
    /// Vorformatierter QR-Code-String nach BSI TR-03153 Anhang A.
    /// Format: V0;{SerNr};{StartISO};{EndISO};{Zähler};{AnzTrans};{SigBase64}
    /// Wird von TTseManager.GenerateQrCodeString befüllt.
    /// </summary>
    QrCodeData: string;
    /// <summary>True wenn die Signierung erfolgreich war</summary>
    Erfolg: Boolean;
    /// <summary>Fehlermeldung im Fehlerfall, andernfalls leer</summary>
    FehlerMeldung: string;
  end;

const
  /// Bibliotheksversion
  KASSENSICHV_TSECORE_VERSION = '1.0.0';

  /// DSFinV-K Schema-Version (BSI, Stand 2024)
  DSFINVK_VERSION = '2.3';

  /// QR-Code Format-Präfix nach BSI TR-03153 Anhang A
  TSE_QR_PREFIX = 'V0';

  /// Standardprozesstyp für gewöhnliche Kassenbelegvorgänge
  PROZESSTYP_KASSENBELEG = 'Kassenbeleg-V1';

  /// Prozesstyp für Trainings- und Testvorgänge (kein Steuerbezug)
  PROZESSTYP_TRAINING = 'Training';

  /// Prozesstyp für Stornovorgänge
  PROZESSTYP_STORNO = 'Kassenbeleg-V1-Storno';

  /// Timeout-Konstante: maximale Wartezeit auf TSE-Antwort in Millisekunden
  TSE_DEFAULT_TIMEOUT_MS = 5000;

  /// ISO 8601 UTC Datumsformat für QR-Code und Export
  TSE_DATETIME_FORMAT = 'yyyy-mm-dd"T"hh:nn:ss"Z"';

implementation

end.
