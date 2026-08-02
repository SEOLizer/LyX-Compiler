/// <summary>
/// DUnit-Testprojekt für KassenSichV.TseCore — WP-TSE-09
/// Läuft ohne physische TSE (alle Tests nutzen TMockTseProvider).
/// </summary>
program KassenSichV_Tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  TestFramework,
  TextTestRunner,
  TestKassenSichV in 'TestKassenSichV.pas',
  KassenSichV.Types in '..\KassenSichV.Types.pas',
  KassenSichV.Exceptions in '..\KassenSichV.Exceptions.pas',
  KassenSichV.Provider in '..\KassenSichV.Provider.pas',
  KassenSichV.Manager in '..\KassenSichV.Manager.pas',
  KassenSichV.Export in '..\KassenSichV.Export.pas',
  KassenSichV.Mock in '..\KassenSichV.Mock.pas',
  KassenSichV.Rest in '..\KassenSichV.Rest.pas',
  KassenSichV.File in '..\KassenSichV.File.pas';

begin
  RunRegisteredTests;
end.
