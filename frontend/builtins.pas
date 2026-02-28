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

  // OS namespace
  AddBuiltin('OS', 'exit', 'exit', atVoid, [atInt64]);
  AddBuiltin('OS', 'getpid', 'getpid', atInt64, []);

  // Math
  AddBuiltin('Math', 'Random', 'Random', atInt64, []);
  AddBuiltin('Math', 'RandomSeed', 'RandomSeed', atVoid, [atInt64]);

  // String operations
  AddBuiltin('', 'str_concat', 'str_concat', atPChar, [atPChar, atPChar]);
end.
