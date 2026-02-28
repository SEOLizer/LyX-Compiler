{$mode objfpc}{$H+}
program test_std_examples;

uses SysUtils, Classes, Process;

function RunCapture(cmd: string; out outText: string): Integer;
var
  p: TProcess;
  sl: TStringList;
begin
  p := TProcess.Create(nil);
  sl := TStringList.Create;
  try
    p.CommandLine := cmd;
    p.Options := p.Options + [poUsePipes];
    p.Execute;
    sl.LoadFromStream(p.Output);
    p.WaitOnExit;
    outText := sl.Text;
    Result := p.ExitStatus;
  finally
    p.Free;
    sl.Free;
  end;
end;

var
  r: Integer; outp: string; txt: string; lines: TStringList;
begin
  // build compiler
  r := RunCapture('fpc -O2 -Mobjfpc -Sh lyxc.lpr -olyxc', txt);
  if r <> 0 then Halt(1);

  // use_string -> expect 5
  r := RunCapture('./lyxc tests/lyx/strings/use_string.lyx -o /tmp/use_string', txt);
  if r <> 0 then Halt(2);
  r := RunCapture('/tmp/use_string', txt);
  if r <> 0 then Halt(3);
  if txt <> '5'#10 then Halt(4);

  // use_time -> expect numeric (>= 0)
  r := RunCapture('./lyxc tests/lyx/stdlib/use_time.lyx -o /tmp/use_time', txt);
  if r <> 0 then Halt(5);
  r := RunCapture('/tmp/use_time', txt);
  if r <> 0 then Halt(6);
  if Length(Trim(txt)) = 0 then Halt(7);

  // use_geo -> expect two numbers
  r := RunCapture('./lyxc tests/lyx/stdlib/use_geo.lyx -o /tmp/use_geo', txt);
  if r <> 0 then Halt(8);
  r := RunCapture('/tmp/use_geo', txt);
  if r <> 0 then Halt(9);
  lines := TStringList.Create;
  try
    lines.Text := txt;
    if lines.Count < 2 then Halt(10);
  finally
    lines.Free;
  end;

   // Test IO functions (open, write, read, close)
   r := RunCapture('./lyxc tests/lyx/io/io_test.lyx -o /tmp/io_test', txt);
   if r <> 0 then Halt(11);
   r := RunCapture('/tmp/io_test', outp);
   if r <> 0 then Halt(12); // Should return 0 on success
    if outp <> 'Gelesen: Hello Lyx IO!\n' then
    begin
      Writeln('IO Test Output: ', outp);
      Halt(13);
    end;

   // Test advanced IO functions (lseek, mkdir, rmdir, rename)
   r := RunCapture('./lyxc tests/lyx/io/io_advanced.lyx -o /tmp/io_advanced', txt);
   if r <> 0 then Halt(14);
   r := RunCapture('/tmp/io_advanced', outp);
   if r <> 0 then Halt(15);
   if Pos('Alle erweiterten IO-Tests bestanden!', outp) = 0 then
   begin
     Writeln('IO Advanced Test Output: ', outp);
     Halt(16);
   end;

   Writeln('std examples ok');
end.
