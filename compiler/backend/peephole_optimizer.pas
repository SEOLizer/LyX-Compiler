{$mode objfpc}{$H+}
unit peephole_optimizer;

{ Peephole-Optimizer für x86_64 Maschinencode

   Dieser Optimizer arbeitet auf dem generierten Bytecode und ersetzt
   ineffiziente Instruktionsfolgen durch effizientere Alternativen.

   Unterstützte Optimierungen:
   - mul → shl bei Zweierpotenzen (x * 2^n → x << n)
   - Redundante mov-Elimination (mov r, r)
   - lea-Optimierungen (lea r, [r+0] → mov r, r)
   - Push/Pop-Elimination für gleiche Register
}

interface

uses
  SysUtils, Classes, bytes;

type
  TOptimizerStats = record
    MulToShl: Integer;
    RedundantMov: Integer;
    LeaOptimization: Integer;
    PushPopElim: Integer;
  end;

  TPeepholeOptimizer = class
  private
    FCode: TByteBuffer;
    FCodeData: PByte;
    FCodeSize: Integer;
    FOptimized: Boolean;
    FStats: TOptimizerStats;
    
    function IsPowerOfTwo(v: Int64): Boolean;
    function Log2Int(v: Int64): Integer;
    
    function GetByte(offset: Integer): Byte;
    procedure SetByte(offset: Integer; value: Byte);
    
    procedure DoOptimizeMulToShl(pos: Integer);
    procedure DoOptimizeRedundantMov(pos: Integer);
    procedure DoOptimizeLea(pos: Integer);
    procedure DoOptimizePushPop(pos: Integer);
    
    function MatchInstruction(pos: Integer): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    
    procedure Optimize(code: TByteBuffer);
    
    property Optimized: Boolean read FOptimized;
    property Stats: TOptimizerStats read FStats;
  end;

implementation

constructor TPeepholeOptimizer.Create;
begin
  inherited Create;
  FCode := nil;
  FCodeData := nil;
  FCodeSize := 0;
  FOptimized := False;
  FillChar(FStats, SizeOf(FStats), 0);
end;

destructor TPeepholeOptimizer.Destroy;
begin
  inherited Destroy;
end;

function TPeepholeOptimizer.IsPowerOfTwo(v: Int64): Boolean;
begin
  Result := (v > 0) and ((v and (v - 1)) = 0);
end;

function TPeepholeOptimizer.Log2Int(v: Int64): Integer;
begin
  Result := 0;
  while (v > 1) do
  begin
    v := v shr 1;
    Inc(Result);
  end;
end;

function TPeepholeOptimizer.GetByte(offset: Integer): Byte;
begin
  if (offset < 0) or (offset >= FCodeSize) then
    Result := 0
  else
    Result := FCodeData[offset];
end;

procedure TPeepholeOptimizer.SetByte(offset: Integer; value: Byte);
begin
  if (offset >= 0) and (offset < FCodeSize) then
    FCodeData[offset] := value;
end;

{ Erkennt Instruktionstypen im Bytecode }

function TPeepholeOptimizer.MatchInstruction(pos: Integer): Integer;
var
  b0, b1, modrm, modField, reg, rm: Byte;
  popOpcode: Byte;
begin
  Result := -1;
  if pos + 3 >= FCodeSize then Exit;
  
  b0 := GetByte(pos);
  b1 := GetByte(pos + 1);
  
  // LEA: 48 8D /r = LEA r64, [r/m]
  if (b0 = $48) and (b1 = $8D) then
  begin
    Result := 3;
    Exit;
  end;
  
  // Redundant mov: 48 89 XX where mod=11 and reg=rm
  if (b0 = $48) and (b1 = $89) then
  begin
    modrm := GetByte(pos + 2);
    modField := (modrm shr 6) and $03;
    if modField = 3 then
    begin
      reg := (modrm shr 3) and $07;
      rm := modrm and $07;
      if reg = rm then
        Result := 2;
    end;
    Exit;
  end;
  
  // Short-form IMUL: 48/49 6B /r ib or 48/49 69 /r id
  if ((b0 = $48) or (b0 = $49)) and ((b1 = $6B) or (b1 = $69)) then
  begin
    Result := 1;
    Exit;
  end;
  
  // Push/Pop pair
  if (b0 >= $50) and (b0 <= $57) then
  begin
    if pos + 1 < FCodeSize then
    begin
      popOpcode := $58 + (b0 - $50);
      if GetByte(pos + 1) = popOpcode then
        Result := 4;
    end;
  end;
end;

{ mul → shl Optimierung }

procedure TPeepholeOptimizer.DoOptimizeMulToShl(pos: Integer);
var
  b0, b1, modrm, rm: Byte;
  immVal: Int64;
  shiftAmt: Integer;
begin
  b0 := GetByte(pos);
  b1 := GetByte(pos + 1);
  
  if not ((b0 = $48) or (b0 = $49)) then Exit;
  if not ((b1 = $6B) or (b1 = $69)) then Exit;
  
  modrm := GetByte(pos + 2);
  rm := modrm and $07;
  
  // Calculate offset to immediate
  if b1 = $6B then
  begin
    // imm8 after ModRM (3 bytes total)
    if pos + 4 > FCodeSize then Exit;
    immVal := PInt8(@FCodeData[pos + 3])^;
  end
  else
  begin
    // imm32 after ModRM (6 bytes total)
    if pos + 7 > FCodeSize then Exit;
    immVal := PInt32(@FCodeData[pos + 3])^;
  end;
  
  if not IsPowerOfTwo(immVal) then Exit;
  
  shiftAmt := Log2Int(immVal);
  
  // Replace with SHL r64, imm8: 48 C1 E0 XX
  SetByte(pos, $48);                  // REX.W
  SetByte(pos + 1, $C1);              // SHL r/m64, imm8
  SetByte(pos + 2, $E0 or rm);        // ModRM: 11 100 [rm]
  SetByte(pos + 3, shiftAmt);         // Immediate
  
  // Clear remaining bytes if imm32 was used
  if b1 = $69 then
  begin
    SetByte(pos + 4, 0);
    SetByte(pos + 5, 0);
    SetByte(pos + 6, 0);
    SetByte(pos + 7, 0);
  end;
  
  Inc(FStats.MulToShl);
  FOptimized := True;
end;

{ Redundante mov-Elimination }

procedure TPeepholeOptimizer.DoOptimizeRedundantMov(pos: Integer);
begin
  // Pattern: 48 89 C0 = mov rax, rax
  // Replace with NOP: 66 90 (2 bytes)
  
  SetByte(pos, $66);
  SetByte(pos + 1, $90);
  
  Inc(FStats.RedundantMov);
  FOptimized := True;
end;

{ LEA-Optimierung }

procedure TPeepholeOptimizer.DoOptimizeLea(pos: Integer);
var
  b2, modrm, modField, rm, sib, scale, index, base, reg: Byte;
begin
  b2 := GetByte(pos + 2);
  modrm := b2;
  modField := (modrm shr 6) and $03;
  rm := modrm and $07;
  
  if modField = 0 then
  begin
    if rm = 4 then
    begin
      // SIB byte follows
      if pos + 3 >= FCodeSize then Exit;
      sib := GetByte(pos + 3);
      scale := (sib shr 6) and $03;
      index := (sib shr 3) and $07;
      base := sib and $07;
      
      // lea r64, [base + index*0] -> mov r64, base
      if (scale = 0) and (index = 4) then
      begin
        reg := (modrm shr 3) and $07;
        SetByte(pos, $48);
        SetByte(pos + 1, $89);
        SetByte(pos + 2, $C0 or (reg shl 3) or base);
        
        Inc(FStats.LeaOptimization);
        FOptimized := True;
      end;
    end
    else
    begin
      // Simple [base] case
      if rm = 5 then Exit;  // [rip+disp32]
      
      reg := (modrm shr 3) and $07;
      SetByte(pos, $48);
      SetByte(pos + 1, $89);
      SetByte(pos + 2, $C0 or (reg shl 3) or rm);
      
      Inc(FStats.LeaOptimization);
      FOptimized := True;
    end;
  end;
end;

{ Push/Pop-Elimination }

procedure TPeepholeOptimizer.DoOptimizePushPop(pos: Integer);
begin
  SetByte(pos, $90);
  SetByte(pos + 1, $90);
  
  Inc(FStats.PushPopElim);
  FOptimized := True;
end;

{ Haupt-Optimierungsroutine }

procedure TPeepholeOptimizer.Optimize(code: TByteBuffer);
var
  pos, optType: Integer;
begin
  if not Assigned(code) or (code.Size = 0) then Exit;
  
  FCode := code;
  FCodeData := code.GetBuffer;
  FCodeSize := code.Size;
  FOptimized := False;
  FillChar(FStats, SizeOf(FStats), 0);
  
  pos := 0;
  while pos < FCodeSize - 2 do
  begin
    optType := MatchInstruction(pos);
    
    case optType of
      1: DoOptimizeMulToShl(pos);
      2: DoOptimizeRedundantMov(pos);
      3: DoOptimizeLea(pos);
      4: DoOptimizePushPop(pos);
    end;
    
    Inc(pos);
  end;
  
  if FOptimized then
  begin
    WriteLn('[Peephole] Optimierungen angewendet:');
    if FStats.MulToShl > 0 then WriteLn('  mul → shl: ', FStats.MulToShl);
    if FStats.RedundantMov > 0 then WriteLn('  Redundante mov: ', FStats.RedundantMov);
    if FStats.LeaOptimization > 0 then WriteLn('  LEA optimiert: ', FStats.LeaOptimization);
    if FStats.PushPopElim > 0 then WriteLn('  Push/Pop eliminiert: ', FStats.PushPopElim);
  end;
end;

end.