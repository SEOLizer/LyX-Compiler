{$mode objfpc}{$H+}
{ type_utils.pas — shared type predicates and size/alignment helpers.
  Used by parser, sema, and lowering so that a single fix reaches all layers. }
unit type_utils;

interface

uses
  ast, backend_types;

{ Size/alignment — two distinct concepts:
    TypeSizeBytes:    memory-access width for load/store (pointer slots = 8 bytes)
    TypeStorageBytes: space a field occupies inside a struct (dynarray fat-ptr = 16 bytes)
    TypeAlignBytes:   required field alignment inside a struct }
function TypeSizeBytes(t: TAurumType): Integer;
function TypeStorageBytes(t: TAurumType; out align: Integer): Boolean;

{ Type predicates }
function IsIntegerType(t: TAurumType): Boolean;
function IsFloatType(t: TAurumType): Boolean;
function IsNumericType(t: TAurumType): Boolean;
function IsBoolType(t: TAurumType): Boolean;
function IsStringType(t: TAurumType): Boolean;
function IsStructType(t: TAurumType): Boolean;

implementation

function TypeSizeBytes(t: TAurumType): Integer;
begin
  case t of
    atInt8, atUInt8, atBool, atChar:          Result := 1;
    atInt16, atUInt16:                         Result := 2;
    atInt32, atUInt32, atF32:                  Result := 4;
    atInt64, atUInt64, atISize, atUSize,
    atF64, atPChar, atPCharNullable, atFnPtr,
    atDynArray, atArray, atMap, atSet,
    atParallelArray:                           Result := 8;
  else
    Result := 8; // atUnresolved, atVoid, others → full register width
  end;
end;

function TypeStorageBytes(t: TAurumType; out align: Integer): Boolean;
begin
  case t of
    atInt8, atUInt8, atChar, atBool:
      begin align := 1; Result := True; end;
    atInt16, atUInt16:
      begin align := 2; Result := True; end;
    atInt32, atUInt32, atF32:
      begin align := 4; Result := True; end;
    atInt64, atUInt64, atISize, atUSize,
    atF64, atPChar, atPCharNullable, atFnPtr:
      begin align := 8; Result := True; end;
    atDynArray:
      begin align := 8; Result := True; end; // fat-ptr (ptr+len) = 16 bytes, align 8
    atMap, atSet:
      begin align := 8; Result := True; end; // heap pointer = 8 bytes
  else
    begin align := 0; Result := False; end;
  end;
end;

function IsIntegerType(t: TAurumType): Boolean;
begin
  case t of
    atInt8, atInt16, atInt32, atInt64,
    atUInt8, atUInt16, atUInt32, atUInt64,
    atISize, atUSize: Result := True;
  else
    Result := False;
  end;
end;

function IsFloatType(t: TAurumType): Boolean;
begin
  Result := t in [atF32, atF64];
end;

function IsNumericType(t: TAurumType): Boolean;
begin
  Result := IsIntegerType(t) or IsFloatType(t);
end;

function IsBoolType(t: TAurumType): Boolean;
begin
  Result := (t = atBool);
end;

function IsStringType(t: TAurumType): Boolean;
begin
  Result := (t = atPChar);
end;

function IsStructType(t: TAurumType): Boolean;
begin
  Result := t in [atDynArray, atArray, atMap, atSet, atTuple];
end;

end.
