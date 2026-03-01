{$mode objfpc}{$H+}
program test_builtin_coverage;
{
  Umfassender Integrationstest-Runner für alle .lyx-Testdateien.
  Kompiliert jede .lyx-Datei mit lyxc und führt das Ergebnis aus.
  Prüft den erwarteten Exit-Code.
}
uses SysUtils, Classes, Process;

type
  TTestEntry = record
    LyxFile: string;
    ExpectedRC: Integer;
    Description: string;
  end;

var
  Tests: array of TTestEntry;
  TestCount: Integer;

procedure AddTest(const aFile: string; aRC: Integer; const aDesc: string);
begin
  Inc(TestCount);
  SetLength(Tests, TestCount);
  Tests[TestCount - 1].LyxFile := aFile;
  Tests[TestCount - 1].ExpectedRC := aRC;
  Tests[TestCount - 1].Description := aDesc;
end;

function RunCmdCapture(const cmd: string; out output: string): LongInt;
var
  p: TProcess;
  buf: array[0..4095] of Byte;
  n: LongInt;
begin
  output := '';
  p := TProcess.Create(nil);
  try
    p.Executable := '/bin/sh';
    p.Parameters.Clear;
    p.Parameters.Add('-c');
    p.Parameters.Add(cmd);
    p.Options := [poWaitOnExit, poUsePipes];
    p.Execute;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then
        output := output + Copy(PAnsiChar(@buf[0]), 1, n);
    until n <= 0;
    Result := p.ExitStatus;
  finally
    p.Free;
  end;
end;

var
  i, ret, passed, failed, compileErrors: Integer;
  txt, outBin: string;
begin
  TestCount := 0;

  // === basic ===
  AddTest('tests/lyx/basic/test_exit.lyx', 42, 'basic: exit(42)');

  // === functions ===
  AddTest('tests/lyx/functions/call.lyx', 0, 'functions: simple call');
  AddTest('tests/lyx/functions/test_fn_call.lyx', 4, 'functions: fn call return');
  AddTest('tests/lyx/functions/test_ret_val.lyx', 42, 'functions: return value');

  // === globals ===
  AddTest('tests/lyx/globals/static_test.lyx', 0, 'globals: static test');
  AddTest('tests/lyx/globals/test_globals.lyx', 0, 'globals: global vars');
  AddTest('tests/lyx/globals/test_globals2.lyx', 0, 'globals: global vars 2');
  AddTest('tests/lyx/globals/test_static.lyx', 42, 'globals: static var');

  // === arrays ===
  AddTest('tests/lyx/arrays/test_bounds.lyx', 42, 'arrays: bounds check');
  AddTest('tests/lyx/arrays/test_len2.lyx', 2, 'arrays: len function');

  // === dynarray ===
  AddTest('tests/lyx/dynarray/hello_dynarray.lyx', 0, 'dynarray: push/pop/len/free');
  AddTest('tests/lyx/dynarray/test_dyn_simple.lyx', 0, 'dynarray: simple ops');
  AddTest('tests/lyx/dynarray/test_dyn_index.lyx', 0, 'dynarray: index access');
  AddTest('tests/lyx/dynarray/test_dyn_init.lyx', 0, 'dynarray: empty init');
  AddTest('tests/lyx/dynarray/test_dyn_init_values.lyx', 60, 'dynarray: literal init [10,20,30]');
  AddTest('tests/lyx/dynarray/test_dyn_double.lyx', 0, 'dynarray: double push');
  AddTest('tests/lyx/dynarray/test_append.lyx', 0, 'dynarray: append alias');

  // === random ===
  AddTest('tests/lyx/random/test_random.lyx', 0, 'random: Random/RandomSeed');

  // === io ===
  AddTest('tests/lyx/io/test_simple_io.lyx', 0, 'io: open/write/close/unlink');
  AddTest('tests/lyx/io/test_syscall.lyx', 0, 'io: syscall fd ops');

  // === pipe ===
  AddTest('tests/lyx/pipe/test_pipe.lyx', 0, 'pipe: basic pipe operator');
  AddTest('tests/lyx/pipe/test_pipe_args.lyx', 0, 'pipe: pipe with args');
  AddTest('tests/lyx/pipe/test_pipe_compare.lyx', 0, 'pipe: pipe vs classic');

  // === operators ===
  AddTest('tests/lyx/operators/test_inc_dec.lyx', 0, 'operators: inc/dec');

  // === panic ===
  AddTest('tests/lyx/panic/test_panic_assert.lyx', 0, 'panic: assert pass');
  AddTest('tests/lyx/panic/test_assert_fail.lyx', 1, 'panic: assert fail');
  AddTest('tests/lyx/panic/test_panic_direct.lyx', 1, 'panic: direct panic');

  // === simd ===
  AddTest('tests/lyx/simd/simd_basic_test.lyx', 0, 'simd: basic test');
  AddTest('tests/lyx/simd/simd_example.lyx', 0, 'simd: example');

  // === energy ===
  AddTest('tests/lyx/energy/test_energy_simple.lyx', 0, 'energy: simple tracking');

  // === lint ===
  AddTest('tests/lyx/lint/naming.lyx', 0, 'lint: naming convention');
  AddTest('tests/lyx/lint/unreachable.lyx', 0, 'lint: unreachable code');
  AddTest('tests/lyx/lint/empty_block.lyx', 1, 'lint: empty block warning');
  AddTest('tests/lyx/lint/shadow.lyx', 1, 'lint: variable shadow');
  AddTest('tests/lyx/lint/unused_param.lyx', 1, 'lint: unused param');
  AddTest('tests/lyx/lint/unused_var.lyx', 10, 'lint: unused var');
  AddTest('tests/lyx/lint/mutable_never_mutated.lyx', 42, 'lint: mutable never mutated');

  // === misc ===
  AddTest('tests/lyx/misc/simple_test.lyx', 0, 'misc: simple test');
  AddTest('tests/lyx/misc/simple_test2.lyx', 0, 'misc: simple test 2');
  AddTest('tests/lyx/misc/hello_test.lyx', 42, 'misc: hello test');
  AddTest('tests/lyx/misc/test_debug1.lyx', 42, 'misc: debug test 1');

  // === printf ===
  AddTest('tests/lyx/printf/print_int.lyx', 0, 'printf: print int');

  // === stdlib ===
  AddTest('tests/lyx/stdlib/use_math.lyx', 0, 'stdlib: use_math');
  AddTest('tests/lyx/stdlib/use_env.lyx', 0, 'stdlib: use_env (no args)');

  // === import ===
  AddTest('tests/lyx/import/test_namespace.lyx', 0, 'import: namespace');

  // === fs ===
  AddTest('tests/lyx/fs/test_rename.lyx', 1, 'fs: rename test');

  // Build compiler first
  Writeln('Building compiler...');
  ret := RunCmdCapture('fpc -O2 -Mobjfpc -Sh -FUlib/ -Fuutil/ -Fufrontend/ -Fuir/ -Fubackend/ -Fubackend/x86_64/ -Fubackend/elf/ -Fubackend/pe/ -Fubackend/arm64/ lyxc.lpr -olyxc', txt);
  if ret <> 0 then
  begin
    Writeln('ERROR: Compiler build failed');
    Writeln(txt);
    Halt(1);
  end;
  Writeln('Compiler built successfully.');
  Writeln('');

  passed := 0;
  failed := 0;
  compileErrors := 0;

  for i := 0 to TestCount - 1 do
  begin
    outBin := '/tmp/lyxtest_' + ExtractFileName(ChangeFileExt(Tests[i].LyxFile, ''));

    // Compile
    ret := RunCmdCapture('./lyxc ' + Tests[i].LyxFile + ' -o ' + outBin, txt);
    if ret <> 0 then
    begin
      Writeln('FAIL [compile] ', Tests[i].Description, ' (', Tests[i].LyxFile, ')');
      Inc(compileErrors);
      Inc(failed);
      Continue;
    end;

    // Run
    if Tests[i].Description = 'stdlib: use_env (no args)' then
      ret := RunCmdCapture(outBin, txt)  // no extra args
    else
      ret := RunCmdCapture(outBin, txt);

    if ret = Tests[i].ExpectedRC then
    begin
      Writeln('PASS ', Tests[i].Description);
      Inc(passed);
    end
    else
    begin
      Writeln('FAIL [rc=', ret, ' expected=', Tests[i].ExpectedRC, '] ',
              Tests[i].Description, ' (', Tests[i].LyxFile, ')');
      Inc(failed);
    end;
  end;

  Writeln('');
  Writeln('=== Ergebnis ===');
  Writeln('Gesamt:         ', TestCount);
  Writeln('Bestanden:      ', passed);
  Writeln('Fehlgeschlagen: ', failed);
  Writeln('Compile-Fehler: ', compileErrors);

  if failed > 0 then
    Halt(1)
  else
    Writeln('Alle Tests bestanden!');
end.
