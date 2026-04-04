{$mode objfpc}{$H+}
unit map_file;

interface

uses
  SysUtils, Classes,
  ir, diag;

type
  { Map File Generator - creates memory layout documentation }
  TMapFileGenerator = class
  private
    FDiag: TDiagnostics;
    FOutput: TStringList;

    procedure AddLine(const line: string);
    procedure ProcessModule(module: TIRModule);

  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;

    { Generate map file from IR module }
    procedure GenerateFromModule(module: TIRModule; const outputFile: string);

    { Export as text string }
    function GetOutput: string;
  end;

implementation

constructor TMapFileGenerator.Create(d: TDiagnostics);
begin
  inherited Create;
  FDiag := d;
  FOutput := TStringList.Create;
end;

destructor TMapFileGenerator.Destroy;
begin
  FOutput.Free;
  inherited Destroy;
end;

procedure TMapFileGenerator.AddLine(const line: string);
begin
  FOutput.Add(line);
end;

procedure TMapFileGenerator.ProcessModule(module: TIRModule);
var
  i: Integer;
  fn: TIRFunction;
  gv: TGlobalVar;
  addr: UInt64;
  totalCode, totalData: UInt64;
begin
  if module = nil then
    Exit;

  AddLine('=== Memory Map ===');
  AddLine('');
  AddLine('Start         End           Size     Kind        Name');
  AddLine('-----------  -----------   ------   ---------   ----------------');

  // Sections (placeholder addresses for documentation)
  AddLine('0x00001000  0x00001FFF    4096     SECTION     .text');
  AddLine('0x00004000  0x00004FFF    4096     SECTION     .data');
  AddLine('0x00005000  0x00005FFF    4096     SECTION     .rodata');
  AddLine('0x00006000  0x00006FFF    4096     SECTION     .bss');
  AddLine('');

  // Functions
  AddLine('=== Functions ===');
  addr := $1000;
  totalCode := 0;
  for i := 0 to High(module.Functions) do
  begin
    fn := module.Functions[i];
    if fn = nil then
      Continue;

    AddLine('0x' + IntToHex(addr, 8) + '  ' + 
            '0x' + IntToHex(addr + 256, 8) + '   ' +
            '256     FUNCTION    ' + fn.Name);
    Inc(addr, 256);
    Inc(totalCode, 256);
  end;
  AddLine('');

  // Global variables
  AddLine('=== Global Variables ===');
  addr := $4000;
  totalData := 0;
  for i := 0 to High(module.GlobalVars) do
  begin
    gv := module.GlobalVars[i];

    AddLine('0x' + IntToHex(addr, 8) + '  ' + 
            '0x' + IntToHex(addr + 8, 8) + '    ' +
            '8       GLOBAL      ' + gv.Name);
    Inc(addr, 8);
    Inc(totalData, 8);
  end;
  AddLine('');

  // Statistics
  AddLine('=== Statistics ===');
  AddLine('');
  AddLine('Sections:    ' + IntToStr(4));
  AddLine('Functions:   ' + IntToStr(Length(module.Functions)));
  AddLine('Globals:     ' + IntToStr(Length(module.GlobalVars)));
  AddLine('Code Size:   ' + IntToStr(totalCode) + ' bytes (estimated)');
  AddLine('Data Size:   ' + IntToStr(totalData) + ' bytes');
  AddLine('Total Size:  ' + IntToStr(totalCode + totalData) + ' bytes');
end;

procedure TMapFileGenerator.GenerateFromModule(module: TIRModule; const outputFile: string);
begin
  FOutput.Clear;
  ProcessModule(module);

  // Write to file if specified
  if outputFile <> '' then
  begin
    try
      FOutput.SaveToFile(outputFile);
      WriteLn('[Map File] Wrote ', outputFile);
    except
      on E: Exception do
        WriteLn(StdErr, '[Map File] Failed to write: ', E.Message);
    end;
  end;
end;

function TMapFileGenerator.GetOutput: string;
begin
  Result := FOutput.Text;
end;

end.