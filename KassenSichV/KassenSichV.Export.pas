/// <summary>
/// KassenSichV.Export — DSFinV-K-konformer Datenexport-Helfer.
/// WP-TSE-04
///
/// Schreibt index.json mit Exportmetadaten neben die vom Provider erzeugte TAR-Datei.
/// Das eigentliche TAR-Archiv stammt vom Provider (enthält TSE-interne Audit-Daten,
/// darf nicht verändert werden — Integrität durch TSE-Signatur gesichert).
/// </summary>
unit KassenSichV.Export;

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  KassenSichV.Types,
  KassenSichV.Exceptions;

type
  /// <summary>
  /// Hilfsklasse für den DSFinV-K-konformen Datenexport.
  /// Alle Methoden sind Klassenmethoden — keine Instanz nötig.
  /// </summary>
  TTseExporter = class
  public
    /// <summary>
    /// Prüft ob TargetPath existiert und schreibbar ist.
    /// Wirft ETseExportError bei nicht schreibbarem Verzeichnis.
    /// </summary>
    class procedure EnsureWritable(const TargetPath: string); static;

    /// <summary>
    /// Schreibt index.json mit Exportmetadaten in TargetPath.
    /// Felder: dsfinvk_version, tse_serial, kasse_id, export_timestamp (ISO 8601 UTC).
    /// </summary>
    class procedure WriteIndexJson(const TargetPath:        string;
                                   const TseSeriennummer:   string;
                                   const KassenSeriennummer: string); static;
  end;

implementation

class procedure TTseExporter.EnsureWritable(const TargetPath: string);
var
  TestFile: string;
  Writer: TStreamWriter;
begin
  if not TDirectory.Exists(TargetPath) then
    raise ETseExportError.Create(
      Format('Exportpfad existiert nicht: %s', [TargetPath]), 400);

  TestFile := TPath.Combine(TargetPath, '.tse_write_test');
  try
    Writer := TStreamWriter.Create(TestFile);
    try
      Writer.Write('ok');
    finally
      Writer.Free;
    end;
    TFile.Delete(TestFile);
  except
    on E: ETseExportError do raise;
    on E: Exception do
      raise ETseExportError.Create(
        Format('Exportpfad nicht schreibbar: %s (%s)', [TargetPath, E.Message]), 403);
  end;
end;

class procedure TTseExporter.WriteIndexJson(const TargetPath:         string;
                                             const TseSeriennummer:    string;
                                             const KassenSeriennummer: string);
var
  IndexPath:  string;
  Timestamp:  string;
  Json:       string;
  Writer:     TStreamWriter;
begin
  Timestamp := FormatDateTime(TSE_DATETIME_FORMAT,
                 TTimeZone.Local.ToUniversalTime(Now));

  // Kompaktes JSON — DSFinV-K 2.3 Pflichtfelder für index.json
  Json :=
    '{' + sLineBreak +
    '  "dsfinvk_version": "' + DSFINVK_VERSION + '",' + sLineBreak +
    '  "tse_serial": "' + TseSeriennummer + '",' + sLineBreak +
    '  "kasse_id": "' + KassenSeriennummer + '",' + sLineBreak +
    '  "export_timestamp": "' + Timestamp + '"' + sLineBreak +
    '}';

  IndexPath := TPath.Combine(TargetPath, 'index.json');
  Writer := TStreamWriter.Create(IndexPath, False, TEncoding.UTF8);
  try
    Writer.Write(Json);
  finally
    Writer.Free;
  end;
end;

end.
