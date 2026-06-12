/// <summary>
/// TseDemo — Beispielanwendung für KassenSichV.TseCore.
/// WP-TSE-10
///
/// Demonstriert den vollständigen Kassenbons-Workflow mit TMockTseProvider.
/// Keine externe TSE-Hardware oder Netzwerkverbindung erforderlich.
/// </summary>
unit TseDemo;

interface

procedure RunDemo;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  KassenSichV.Types,
  KassenSichV.Provider,
  KassenSichV.Manager,
  KassenSichV.Mock;

// ---------------------------------------------------------------------------
// Ausgabe-Helfer
// ---------------------------------------------------------------------------

procedure Sep(const AChar: Char = '-'; ALen: Integer = 60);
begin
  Writeln(StringOfChar(AChar, ALen));
end;

procedure PrintSignaturErgebnis(const ASig: TSignaturErgebnis; const ATitle: string);
begin
  Sep('=');
  Writeln('[' + ATitle + ']');
  Sep;
  Writeln('  Erfolg              : ', BoolToStr(ASig.Erfolg, True));
  Writeln('  TSE-Seriennummer    : ', ASig.TseSeriennummer);
  Writeln('  Signaturzähler      : ', ASig.SignaturZaehler);
  Writeln('  Anzahl Transaktionen: ', ASig.AnzahlTransaktionen);
  Writeln('  Startzeitpunkt      : ', DateTimeToStr(ASig.StartZeitpunkt));
  Writeln('  Endzeitpunkt        : ', DateTimeToStr(ASig.EndZeitpunkt));
  Writeln('  Signaturwert (B64)  : ', ASig.SignaturWert);
  Sep;
  Writeln('  QR-Code-String (BSI TR-03153 Anhang A):');
  Writeln('  ', ASig.QrCodeData);
  if ASig.FehlerMeldung <> '' then
    Writeln('  FEHLER              : ', ASig.FehlerMeldung);
  Sep('=');
  Writeln;
end;

// ---------------------------------------------------------------------------
// Demo 1: Einfacher Kassenbon (ProcessBeleg)
// ---------------------------------------------------------------------------

procedure DemoEinfacherKassenbon(Manager: TTseManager);
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
begin
  Writeln('=== Demo 1: Einfacher Kassenbon (ProcessBeleg) ===');
  Writeln;

  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp          := PROZESSTYP_KASSENBELEG;
  Beleg.KassenSeriennummer  := 'KASSE-001';
  Beleg.ProzessDaten        := 'Kaffee;2.50_0.00_0.00_0.00_0.00';
  Beleg.UmsatzZaehler       := 2.50;

  Sig := Manager.ProcessBeleg(Beleg);
  PrintSignaturErgebnis(Sig, 'Einfacher Kassenbon');
end;

// ---------------------------------------------------------------------------
// Demo 2: Mehrstufiger Vorgang (OpenBeleg → UpdateBeleg → CloseBeleg)
// ---------------------------------------------------------------------------

procedure DemoTischbestellung(Manager: TTseManager);
var
  Beleg:   TBelegDaten;
  TransId: string;
  UpdSig:  TSignaturErgebnis;
  FinalSig: TSignaturErgebnis;
begin
  Writeln('=== Demo 2: Mehrstufiger Vorgang (Tischbestellung) ===');
  Writeln;

  // Vorgang eröffnen
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp         := PROZESSTYP_KASSENBELEG;
  Beleg.KassenSeriennummer := 'KASSE-001';
  Beleg.ProzessDaten       := 'Bestellung Tisch 4;Vorspeise';
  Beleg.UmsatzZaehler      := 12.80;
  TransId := Manager.OpenBeleg(Beleg);
  Writeln('  TransId: ', TransId);

  // Zwischenstand
  Beleg.ProzessDaten  := 'Bestellung Tisch 4;Hauptgang';
  Beleg.UmsatzZaehler := 28.50;
  UpdSig := Manager.UpdateBeleg(TransId, Beleg);
  Writeln('  Update-Signatur ok: ', BoolToStr(UpdSig.Erfolg, True));

  // Abschluss
  Beleg.ProzessDaten  := 'Bestellung Tisch 4;Dessert+Getraenke';
  Beleg.UmsatzZaehler := 42.30;
  FinalSig := Manager.CloseBeleg(TransId, Beleg);
  PrintSignaturErgebnis(FinalSig, 'Tischbestellung Abschluss');
end;

// ---------------------------------------------------------------------------
// Demo 3: Fehlersimulation (ETseTransactionError)
// ---------------------------------------------------------------------------

procedure DemoFehlerSimulation(Manager: TTseManager; Provider: TMockTseProvider);
var Beleg: TBelegDaten;
begin
  Writeln('=== Demo 3: Fehlersimulation ===');
  Writeln;

  Provider.SimulateError := True;
  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp := PROZESSTYP_KASSENBELEG;

  try
    Manager.ProcessBeleg(Beleg);
    Writeln('  FEHLER: keine Exception ausgelöst (sollte nicht passieren)');
  except
    on E: Exception do
      Writeln('  Erwartete Exception (', E.ClassName, '): ', E.Message);
  end;

  Provider.SimulateError := False;
  Writeln;
end;

// ---------------------------------------------------------------------------
// Demo 4: Trainingsbon
// ---------------------------------------------------------------------------

procedure DemoTrainingsbon(Manager: TTseManager);
var
  Beleg: TBelegDaten;
  Sig:   TSignaturErgebnis;
begin
  Writeln('=== Demo 4: Trainingsbon (PROZESSTYP_TRAINING) ===');
  Writeln;

  Beleg := Default(TBelegDaten);
  Beleg.ProzessTyp         := PROZESSTYP_TRAINING;
  Beleg.KassenSeriennummer := 'KASSE-001';
  Beleg.ProzessDaten       := 'Schulungszwecke;0.00_0.00_0.00_0.00_0.00';

  Sig := Manager.ProcessBeleg(Beleg);
  PrintSignaturErgebnis(Sig, 'Trainingsbon');
end;

// ---------------------------------------------------------------------------
// Demo 5: TSE-Status und Datenexport
// ---------------------------------------------------------------------------

procedure DemoStatusUndExport(Manager: TTseManager);
var
  TmpDir:  string;
  Status:  string;
begin
  Writeln('=== Demo 5: TSE-Status und Datenexport ===');
  Writeln;

  Status := Manager.GetTseStatus;
  Writeln('  TSE-Status: ', Status);
  Writeln('  TSE-Serial: ', Manager.GetTseSeriennummer);
  Writeln;

  TmpDir := TPath.Combine(TPath.GetTempPath, 'tse_demo_export');
  if not TDirectory.Exists(TmpDir) then TDirectory.CreateDirectory(TmpDir);

  Manager.ExportAuditData(TmpDir, 'KASSE-001');
  Writeln('  Export-Verzeichnis: ', TmpDir);
  Writeln('  Dateien:');
  for var F in TDirectory.GetFiles(TmpDir) do
    Writeln('    - ', TPath.GetFileName(F));

  // Aufräumen
  TDirectory.Delete(TmpDir, True);
  Writeln;
end;

// ---------------------------------------------------------------------------
// Hauptroutine
// ---------------------------------------------------------------------------

procedure RunDemo;
var
  Provider: TMockTseProvider;
  Manager:  TTseManager;
begin
  Sep('*', 60);
  Writeln('* KassenSichV.TseCore Demo (BSI TR-03153 / KassenSichV)    *');
  Writeln('* Provider: TMockTseProvider (keine TSE-Hardware nötig)     *');
  Sep('*', 60);
  Writeln;

  // Provider mit Logging-Callback erstellen
  Provider := TMockTseProvider.Create;
  Provider.OnLogMessage := procedure(const AMsg: string)
    begin
      Writeln('  [LOG] ', AMsg);
    end;
  Provider.Initialize('{}');

  Manager := TTseManager.Create(Provider);
  try
    DemoEinfacherKassenbon(Manager);
    DemoTischbestellung(Manager);
    DemoFehlerSimulation(Manager, Provider);
    DemoTrainingsbon(Manager);
    DemoStatusUndExport(Manager);
  finally
    Manager.Free;
  end;

  Sep('*', 60);
  Writeln('* Demo beendet — alle Vorgänge erfolgreich abgeschlossen.   *');
  Sep('*', 60);
end;

end.
