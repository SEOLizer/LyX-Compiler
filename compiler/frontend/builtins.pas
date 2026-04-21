{$mode objfpc}{$H+}
unit builtins;

interface

uses
  SysUtils, Classes, ast;

type
  TBuiltinInfo = record
    Namespace: string;
    Name: string;
    ImplName: string; // name used by lowering/backend
    RetType: TAurumType;
    ParamCount: Integer;
    ParamTypes: array of TAurumType;
    IsVarArgs: Boolean;
  end;

  TBuiltinInfoArray = array of TBuiltinInfo;

function FindBuiltin(const qualifier, name: string; out info: TBuiltinInfo): Boolean;
function GetAllBuiltins: TBuiltinInfoArray;

implementation

var
  BuiltinList: array of TBuiltinInfo;

procedure AddBuiltin(const NS, Name, Impl: string; Ret: TAurumType; Params: array of TAurumType; VarArgs: Boolean = False);
var
  bi: TBuiltinInfo;
begin
  bi.Namespace := NS;
  bi.Name := Name;
  bi.ImplName := Impl;
  bi.RetType := Ret;
  bi.ParamCount := Length(Params);
  SetLength(bi.ParamTypes, bi.ParamCount);
  if bi.ParamCount > 0 then
    Move(Params[0], bi.ParamTypes[0], SizeOf(TAurumType) * bi.ParamCount);
  bi.IsVarArgs := VarArgs;
  SetLength(BuiltinList, Length(BuiltinList) + 1);
  BuiltinList[High(BuiltinList)] := bi;
end;

function FindBuiltin(const qualifier, name: string; out info: TBuiltinInfo): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(BuiltinList) do
  begin
    if (BuiltinList[i].Name = name) and ((qualifier = '') or (BuiltinList[i].Namespace = qualifier)) then
    begin
      info := BuiltinList[i];
      Result := True;
      Exit;
    end;
  end;
end;

function GetAllBuiltins: TBuiltinInfoArray;
var
  i: Integer;
begin
  SetLength(Result, Length(BuiltinList));
  for i := 0 to High(BuiltinList) do
    Result[i] := BuiltinList[i];
end;

initialization
  // IO namespace
  AddBuiltin('IO', 'PrintStr', 'PrintStr', atVoid, [atPChar]);
  AddBuiltin('IO', 'PrintInt', 'PrintInt', atVoid, [atInt64]);
  AddBuiltin('IO', 'PrintFloat', 'PrintFloat', atVoid, [atF64]);
  AddBuiltin('IO', 'Println', 'Println', atVoid, [atPChar]);
  AddBuiltin('IO', 'printf', 'printf', atVoid, [atPChar], True);
  AddBuiltin('IO', 'open', 'open', atInt64, [atPChar, atInt64, atInt64]);
  AddBuiltin('IO', 'read', 'read', atInt64, [atInt64, atPChar, atInt64]);
  AddBuiltin('IO', 'write', 'write', atInt64, [atInt64, atPChar, atInt64]);
  AddBuiltin('IO', 'close', 'close', atInt64, [atInt64]);
  AddBuiltin('IO', 'lseek', 'lseek', atInt64, [atInt64, atInt64, atInt64]);
  AddBuiltin('IO', 'unlink', 'unlink', atInt64, [atPChar]);
  AddBuiltin('IO', 'rename', 'rename', atInt64, [atPChar, atPChar]);
  AddBuiltin('IO', 'mkdir', 'mkdir', atInt64, [atPChar, atInt64]);
  AddBuiltin('IO', 'rmdir', 'rmdir', atInt64, [atPChar]);
  AddBuiltin('IO', 'chmod', 'chmod', atInt64, [atPChar, atInt64]);
  AddBuiltin('IO', 'ioctl', 'ioctl', atInt64, [atInt64, atInt64, atInt64]);
  // mmap: erlaubt 1-6 Argumente (wird in lower_ast_to_ir auf 6 erweitert)
  AddBuiltin('IO', 'mmap', 'mmap', atInt64, [atInt64, atInt64, atInt64, atInt64, atInt64, atInt64]);
  AddBuiltin('IO', 'munmap', 'munmap', atInt64, [atInt64, atInt64]);

  // OS namespace
  AddBuiltin('OS', 'exit', 'exit', atVoid, [atInt64]);
  AddBuiltin('OS', 'getpid', 'getpid', atInt64, []);

  // Math
  AddBuiltin('Math', 'Random', 'Random', atInt64, []);
  AddBuiltin('Math', 'RandomSeed', 'RandomSeed', atVoid, [atInt64]);

  // Profiler (WP-3) - global builtins (no namespace)
  AddBuiltin('', 'profile_enter', 'profile_enter', atVoid, [atPChar]);
  AddBuiltin('', 'profile_leave', 'profile_leave', atVoid, [atPChar]);
  AddBuiltin('', 'profile_report', 'profile_report', atVoid, []);

  // String operations
  AddBuiltin('', 'str_concat', 'str_concat', atPChar, [atPChar, atPChar]);
  AddBuiltin('', 'StrLen',    'StrLen',    atInt64,  [atPChar]);
  AddBuiltin('', 'StrCharAt', 'StrCharAt', atInt64,  [atPChar, atInt64]);
  AddBuiltin('', 'StrSetChar','StrSetChar',atVoid,   [atPChar, atInt64, atInt64]);
  AddBuiltin('', 'StrNew',    'StrNew',    atPChar,  [atInt64]);
  AddBuiltin('', 'StrFree',   'StrFree',   atVoid,   [atPChar]);
  AddBuiltin('', 'StrAppend', 'StrAppend', atPChar,  [atPChar, atPChar]);
  AddBuiltin('', 'StrFromInt','StrFromInt',atPChar,  [atInt64]);

  // S1: String split primitives
  AddBuiltin('', 'StrFindChar', 'StrFindChar', atInt64,  [atPChar, atInt64, atInt64]);
  AddBuiltin('', 'StrSub',      'StrSub',      atPChar,  [atPChar, atInt64, atInt64]);

  // S2: StringBuilder / concat
  AddBuiltin('', 'StrAppendStr', 'StrAppendStr', atPChar, [atPChar, atPChar]);
  AddBuiltin('', 'StrConcat',    'StrConcat',    atPChar, [atPChar, atPChar]);
  AddBuiltin('', 'StrCopy',      'StrCopy',      atPChar, [atPChar]);

  // S3: IntToStr alias
  AddBuiltin('', 'IntToStr', 'IntToStr', atPChar, [atInt64]);

  // S4: FileGetSize
  AddBuiltin('', 'FileGetSize', 'FileGetSize', atInt64, [atPChar]);

  // S5: O(1) HashMap (string -> int64)
  AddBuiltin('', 'HashNew', 'HashNew', atPChar,  [atInt64]);
  AddBuiltin('', 'HashSet', 'HashSet', atVoid,   [atPChar, atPChar, atInt64]);
  AddBuiltin('', 'HashGet', 'HashGet', atInt64,  [atPChar, atPChar]);
  AddBuiltin('', 'HashHas', 'HashHas', atBool,   [atPChar, atPChar]);

  // S6: Argv access
  AddBuiltin('', 'GetArgC', 'GetArgC', atInt64, []);
  AddBuiltin('', 'GetArg',  'GetArg',  atPChar, [atInt64]);

  // S7: String comparison
  AddBuiltin('', 'StrStartsWith', 'StrStartsWith', atBool,  [atPChar, atPChar]);
  AddBuiltin('', 'StrEndsWith',   'StrEndsWith',   atBool,  [atPChar, atPChar]);
  AddBuiltin('', 'StrEquals',     'StrEquals',     atBool,  [atPChar, atPChar]);

  // Debug namespace - In-Situ Data Visualizer
  // Inspect akzeptiert jeden Typ - die Typprüfung erfolgt speziell in Sema
  // Der Parameter wird als int64 deklariert, aber Sema erlaubt jeden Typ
  AddBuiltin('Debug', 'Inspect', 'Inspect', atVoid, [atInt64]);
  // Kurzform ohne Namespace
  AddBuiltin('', 'Inspect', 'Inspect', atVoid, [atInt64]);
end.
