/// <summary>
/// TseDemoApp — Einstiegspunkt der KassenSichV.TseCore Demo-Anwendung.
/// WP-TSE-10
///
/// Kompilierbar mit Delphi 11 und Delphi 12.
/// Keine externen Abhängigkeiten. MockProvider ist Standard.
/// </summary>
program TseDemoApp;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  TseDemo in 'TseDemo.pas',
  KassenSichV.Types in '..\KassenSichV.Types.pas',
  KassenSichV.Exceptions in '..\KassenSichV.Exceptions.pas',
  KassenSichV.Provider in '..\KassenSichV.Provider.pas',
  KassenSichV.Manager in '..\KassenSichV.Manager.pas',
  KassenSichV.Export in '..\KassenSichV.Export.pas',
  KassenSichV.Mock in '..\KassenSichV.Mock.pas';

begin
  try
    RunDemo;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'FATAL: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
