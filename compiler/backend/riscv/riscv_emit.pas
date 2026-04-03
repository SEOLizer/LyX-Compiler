{$mode objfpc}{$H+}
unit riscv_emit;

{
  RISC-V RV64GC Emitter
  
  Target: RISC-V RV64GC (64-bit)
  ABI: LP64D
  Platform: Linux (ecall syscalls)
  Safety: PMP, ebreak, fence, CSR access
}

interface

uses
  SysUtils, Classes, bytes, ir, riscv_defs, backend_types, energy_model, diag;

type
  TRISCVCodeEmitter = class
  private
    FCode: TByteBuffer;
    FData: TByteBuffer;
    FDiag: TDiagnostics;
    FEnergyLevel: TEnergyLevel;
    FEnergyStats: TEnergyStats;
    FFuncOffsets: array of record Name: string; Offset: Integer; end;
    FCallPatches: array of record CodePos: Integer; TargetName: string; end;
    FBranchPatches: array of record CodePos: Integer; LabelName: string; end;
    FLabels: array of record Name: string; Offset: Integer; end;
    FLeaPositions: array of Integer;
    FLeaStrIndex: array of Integer;
    FRandomSeedOffset: UInt64;
    FRandomSeedAdded: Boolean;
    
    // RISC-V Instruction Encoding (RV64I base)
    procedure EmitRType(opcode, funct3, funct7, rd, rs1, rs2: Byte);
    procedure EmitIType(opcode, funct3, rd, rs1: Byte; imm: Integer);
    procedure EmitSType(opcode, funct3, rs1, rs2: Byte; imm: Integer);
    procedure EmitBType(opcode, funct3, rs1, rs2: Byte; imm: Integer);
    procedure EmitUType(opcode, rd: Byte; imm: Integer);
    procedure EmitJType(opcode, rd: Byte; imm: Integer);
    procedure EmitFType(opcode, funct3, fmt, rd, rs1, rs2: Byte);
    
    // Pseudo-instructions
    procedure EmitNop;
    procedure EmitLi(rd: Byte; imm: Int64);
    procedure EmitLa(rd: Byte; addr: Int64);
    procedure EmitMv(rd, rs: Byte);
    procedure EmitNeg(rd, rs: Byte);
    procedure EmitNot(rd, rs: Byte);
    procedure EmitSeq(rd, rs1, rs2: Byte);
    procedure EmitSnez(rd, rs: Byte);
    procedure EmitSltz(rd, rs: Byte);
    procedure EmitSgtz(rd, rs: Byte);
    procedure EmitBeqz(rs1: Byte; imm: Integer);
    procedure EmitBnez(rs1: Byte; imm: Integer);
    procedure EmitBlez(rs1: Byte; imm: Integer);
    procedure EmitBgez(rs1: Byte; imm: Integer);
    procedure EmitBltz(rs1: Byte; imm: Integer);
    procedure EmitBgtz(rs1: Byte; imm: Integer);
    procedure EmitJal(rd: Byte; imm: Integer);
    procedure EmitJalr(rd, rs1: Byte; imm: Integer);
    procedure EmitRet;
    procedure EmitEcall;
    procedure EmitEbreak;
    procedure EmitFence;
    procedure EmitFenceI;
    procedure EmitWfi;
    procedure EmitMret;
    procedure EmitSret;
    procedure EmitCsrrw(rd, csr: Word; rs1: Byte);
    procedure EmitCsrrs(rd, csr: Word; rs1: Byte);
    procedure EmitCsrrc(rd, csr: Word; rs1: Byte);
    procedure EmitCsrrwi(rd, csr: Word; uimm: Byte);
    procedure EmitCsrrsi(rd, csr: Word; uimm: Byte);
    procedure EmitCsrrci(rd, csr: Word; uimm: Byte);
    
    // Stack helpers
    function SlotOffset(slot: Integer): Integer;
    procedure EmitPushReg(r: Byte);
    procedure EmitPopReg(r: Byte);
    
    // Safety code
    procedure EmitPMPConfig;
    procedure EmitStackCanaryInit;
    procedure EmitStackCanaryCheck;
    
  public
    constructor Create;
    destructor Destroy; override;
    procedure EmitFromIR(const module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
    function GetExternalSymbols: TExternalSymbolArray;
    procedure SetEnergyLevel(level: TEnergyLevel);
    function GetEnergyStats: TEnergyStats;
  end;

implementation

// ============================================================================
// RISC-V Instruction Encoding
// ============================================================================

procedure TRISCVCodeEmitter.EmitRType(opcode, funct3, funct7, rd, rs1, rs2: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(funct7) shl 25) or
    (UInt32(rs2) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(funct3) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitIType(opcode, funct3, rd, rs1: Byte; imm: Integer);
begin
  FCode.WriteU32LE(
    (UInt32(imm and $FFF) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(funct3) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitSType(opcode, funct3, rs1, rs2: Byte; imm: Integer);
begin
  FCode.WriteU32LE(
    (UInt32(imm and $FE0) shl 20) or
    (UInt32(rs2) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(funct3) shl 12) or
    (UInt32(imm and $1F) shl 7) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitBType(opcode, funct3, rs1, rs2: Byte; imm: Integer);
begin
  FCode.WriteU32LE(
    (UInt32(imm and $1000) shl 19) or
    (UInt32(imm and $800) shl 4) or
    (UInt32(rs2) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(funct3) shl 12) or
    (UInt32(imm and $7E) shl 7) or
    (UInt32(imm and $10) shl 3) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitUType(opcode, rd: Byte; imm: Integer);
begin
  FCode.WriteU32LE(
    (UInt32(imm and $FFFFF000)) or
    (UInt32(rd) shl 7) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitJType(opcode, rd: Byte; imm: Integer);
begin
  FCode.WriteU32LE(
    (UInt32(imm and $100000) shl 11) or
    (UInt32(imm and $7FF) shl 12) or
    (UInt32(imm and $800) shl 11) or
    (UInt32(imm and $FFE00) shl 0) or
    (UInt32(rd) shl 7) or
    UInt32(opcode)
  );
end;

procedure TRISCVCodeEmitter.EmitFType(opcode, funct3, fmt, rd, rs1, rs2: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(rs2) shl 25) or
    (UInt32(rs1) shl 20) or
    (UInt32(fmt) shl 25) or
    (UInt32(funct3) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32(opcode)
  );
end;

// Pseudo-instructions
procedure TRISCVCodeEmitter.EmitNop;
begin
  EmitIType($13, 0, X0, X0, 0);  // addi x0, x0, 0
end;

procedure TRISCVCodeEmitter.EmitLi(rd: Byte; imm: Int64);
var
  hi, lo: Int64;
begin
  if (imm >= -2048) and (imm <= 2047) then
  begin
    EmitIType($13, 0, rd, X0, imm and $FFF);  // addi
  end
  else
  begin
    lo := Int64(Int32(imm));
    hi := (imm - lo) shr 12;
    if (lo and $800) <> 0 then
    begin
      lo := lo - $1000;
      hi := hi + 1;
    end;
    EmitUType($37, rd, hi);  // lui
    EmitIType($13, 0, rd, rd, lo and $FFF);  // addi
  end;
end;

procedure TRISCVCodeEmitter.EmitLa(rd: Byte; addr: Int64);
begin
  EmitLi(rd, addr);
end;

procedure TRISCVCodeEmitter.EmitMv(rd, rs: Byte);
begin
  EmitIType($13, 0, rd, rs, 0);  // addi rd, rs, 0
end;

procedure TRISCVCodeEmitter.EmitNeg(rd, rs: Byte);
begin
  EmitRType($33, 0, $40, rd, X0, rs);  // sub rd, x0, rs
end;

procedure TRISCVCodeEmitter.EmitNot(rd, rs: Byte);
begin
  EmitRType($33, $6, 0, rd, rs, -1);  // xori rd, rs, -1
end;

procedure TRISCVCodeEmitter.EmitSeq(rd, rs1, rs2: Byte);
begin
  EmitRType($33, 2, 1, rd, rs1, rs2);  // slt rd, rs1, rs2
  EmitRType($33, 2, 1, rd, rs2, rs1);  // slt rd, rs2, rs1
  EmitRType($33, 0, 0, rd, rd, rd);    // or rd, rd, rd (nop, result in rd)
end;

procedure TRISCVCodeEmitter.EmitSnez(rd, rs: Byte);
begin
  EmitRType($33, 3, 0, rd, X0, rs);  // sltu rd, x0, rs
end;

procedure TRISCVCodeEmitter.EmitSltz(rd, rs: Byte);
begin
  EmitRType($33, 2, 0, rd, rs, X0);  // slt rd, rs, x0
end;

procedure TRISCVCodeEmitter.EmitSgtz(rd, rs: Byte);
begin
  EmitRType($33, 2, 0, rd, X0, rs);  // slt rd, x0, rs
end;

procedure TRISCVCodeEmitter.EmitBeqz(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 0, rs1, X0, imm);
end;

procedure TRISCVCodeEmitter.EmitBnez(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 1, rs1, X0, imm);
end;

procedure TRISCVCodeEmitter.EmitBlez(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 5, X0, rs1, imm);
end;

procedure TRISCVCodeEmitter.EmitBgez(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 5, rs1, X0, imm);
end;

procedure TRISCVCodeEmitter.EmitBltz(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 4, rs1, X0, imm);
end;

procedure TRISCVCodeEmitter.EmitBgtz(rs1: Byte; imm: Integer);
begin
  EmitBType($63, 4, X0, rs1, imm);
end;

procedure TRISCVCodeEmitter.EmitJal(rd: Byte; imm: Integer);
begin
  EmitJType($6F, rd, imm);
end;

procedure TRISCVCodeEmitter.EmitJalr(rd, rs1: Byte; imm: Integer);
begin
  EmitIType($67, 0, rd, rs1, imm);
end;

procedure TRISCVCodeEmitter.EmitRet;
begin
  EmitJalr(X0, X1, 0);  // jalr x0, ra, 0
end;

procedure TRISCVCodeEmitter.EmitEcall;
begin
  EmitIType($73, 0, X0, X0, 0);
end;

procedure TRISCVCodeEmitter.EmitEbreak;
begin
  EmitIType($73, 0, X0, X0, 1);
end;

procedure TRISCVCodeEmitter.EmitFence;
begin
  FCode.WriteU32LE($0FF0000F);
end;

procedure TRISCVCodeEmitter.EmitFenceI;
begin
  FCode.WriteU32LE($0000100F);
end;

procedure TRISCVCodeEmitter.EmitWfi;
begin
  EmitIType($73, 1, X0, X0, $105);
end;

procedure TRISCVCodeEmitter.EmitMret;
begin
  EmitIType($73, 0, X0, X0, $302000);
end;

procedure TRISCVCodeEmitter.EmitSret;
begin
  EmitIType($73, 0, X0, X0, $102000);
end;

procedure TRISCVCodeEmitter.EmitCsrrw(rd, csr: Word; rs1: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(1) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitCsrrs(rd, csr: Word; rs1: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(2) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitCsrrc(rd, csr: Word; rs1: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(rs1) shl 15) or
    (UInt32(3) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitCsrrwi(rd, csr: Word; uimm: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(uimm) shl 15) or
    (UInt32(5) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitCsrrsi(rd, csr: Word; uimm: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(uimm) shl 15) or
    (UInt32(6) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitCsrrci(rd, csr: Word; uimm: Byte);
begin
  FCode.WriteU32LE(
    (UInt32(csr) shl 20) or
    (UInt32(uimm) shl 15) or
    (UInt32(7) shl 12) or
    (UInt32(rd) shl 7) or
    UInt32($73)
  );
end;

procedure TRISCVCodeEmitter.EmitPushReg(r: Byte);
begin
  EmitIType($03, 3, r, X2, -8);  // ld r, -8(sp)
  EmitIType($13, 0, X2, X2, -8);  // addi sp, sp, -8
end;

procedure TRISCVCodeEmitter.EmitPopReg(r: Byte);
begin
  EmitIType($03, 3, r, X2, 0);  // ld r, 0(sp)
  EmitIType($13, 0, X2, X2, 8);  // addi sp, sp, 8
end;

function TRISCVCodeEmitter.SlotOffset(slot: Integer): Integer;
begin
  Result := slot * 8;  // 8 bytes per slot (RV64)
end;

// ============================================================================
// Safety Code
// ============================================================================

procedure TRISCVCodeEmitter.EmitPMPConfig;
begin
  // PMP configuration stub
  // In practice: csrw pmpcfg0, a0; csrw pmpaddr0, a1
end;

procedure TRISCVCodeEmitter.EmitStackCanaryInit;
begin
  // Store canary at known stack location
  EmitLi(X5, $DEADBEEF);
  EmitIType($23, 3, X5, X2, -16);  // sd x5, -16(sp)
end;

procedure TRISCVCodeEmitter.EmitStackCanaryCheck;
begin
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_stack_canary_check';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  EmitLi(X5, $DEADBEEF);
  EmitIType($03, 3, X6, X2, -16);  // ld x6, -16(sp)
  EmitRType($33, 4, 0, X5, X5, X6); // xor x5, x5, x6
  EmitBnez(X5, 12);                 // bnez x5, fail
  EmitLi(X10, 0);                   // li a0, 0 (OK)
  EmitRet;
  // fail:
  EmitLi(X10, -1);                  // li a0, -1 (overflow)
  EmitRet;
end;

// ============================================================================
// Main Emitter
// ============================================================================

constructor TRISCVCodeEmitter.Create;
begin
  inherited Create;
  FCode := TByteBuffer.Create;
  FData := TByteBuffer.Create;
  FDiag := TDiagnostics.Create;
  FEnergyLevel := eelMedium;
  FEnergyStats := GetDefaultEnergyStats;
  FRandomSeedAdded := False;
end;

destructor TRISCVCodeEmitter.Destroy;
begin
  FCode.Free;
  FData.Free;
  FDiag.Free;
  inherited Destroy;
end;

procedure TRISCVCodeEmitter.EmitFromIR(const module: TIRModule);
var
  i, j: Integer;
  instr: TIRInstr;
  fn: TIRFunction;
  localCnt, maxTemp, slotIdx, totalSlots, frameSize: Integer;
  strIdx: Integer;
  strOffset: UInt64;
  totalDataOffset: UInt64;
  stringByteOffsets: array of UInt64;
  labelIdx, targetPos, patchPos: Integer;
  branchOffset: Int32;
  callPatchIdx, targetFuncIdx: Integer;
  found: Boolean;
begin
  FCode.Clear;
  FData.Clear;
  SetLength(FFuncOffsets, 0);
  SetLength(FLabels, 0);
  SetLength(FCallPatches, 0);
  SetLength(FBranchPatches, 0);
  SetLength(FLeaPositions, 0);
  SetLength(FLeaStrIndex, 0);
  FRandomSeedAdded := False;
  
  // Phase 1: Write strings to data section
  totalDataOffset := 0;
  if Assigned(module) then
  begin
    SetLength(stringByteOffsets, module.Strings.Count);
    for i := 0 to module.Strings.Count - 1 do
    begin
      stringByteOffsets[i] := totalDataOffset;
      for j := 1 to Length(module.Strings[i]) do
        FData.WriteU8(Byte(module.Strings[i][j]));
      FData.WriteU8(0);
      Inc(totalDataOffset, Length(module.Strings[i]) + 1);
    end;
  end;
  while (FData.Size mod 8) <> 0 do FData.WriteU8(0);
  
  // Phase 2: Entry point (_start)
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '_start';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // Safety init: stack canary
  EmitStackCanaryInit;
  
  // Call main
  EmitJal(X1, 0);  // jal ra, main
  SetLength(FCallPatches, Length(FCallPatches) + 1);
  FCallPatches[High(FCallPatches)].CodePos := FCode.Size - 4;
  FCallPatches[High(FCallPatches)].TargetName := 'main';
  
  // exit(a0)
  EmitLi(X17, SYS_EXIT);  // a7 = syscall number
  EmitEcall;
  
  // Infinite loop
  EmitJal(X0, -4);
  
  // Phase 3: Builtin functions
  EmitStackCanaryCheck;
  
  // PrintStr builtin
  SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
  FFuncOffsets[High(FFuncOffsets)].Name := '__builtin_PrintStr';
  FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
  
  // a0 = string pointer, calculate length, then write
  EmitMv(X11, X10);  // save string ptr in x11
  EmitMv(X10, X11);  // x10 = string ptr
  EmitLi(X12, 0);    // x12 = counter
  var lenLoop := FCode.Size;
  EmitIType($03, 0, X13, X10, 0);  // lb x13, 0(x10)
  EmitBeqz(X13, 12);
  EmitIType($13, 0, X10, X10, 1);
  EmitIType($13, 0, X12, X12, 1);
  EmitJal(X0, lenLoop - FCode.Size);
  // write(1, str, len)
  EmitLi(X17, SYS_WRITE);
  EmitLi(X10, STDOUT_FD);
  EmitMv(X11, X11);  // buf
  EmitMv(X12, X12);  // len
  EmitEcall;
  EmitRet;
  
  // Phase 4: User functions
  if Assigned(module) then
  begin
    for i := 0 to High(module.Functions) do
    begin
      fn := module.Functions[i];
      
      SetLength(FFuncOffsets, Length(FFuncOffsets) + 1);
      FFuncOffsets[High(FFuncOffsets)].Name := fn.Name;
      FFuncOffsets[High(FFuncOffsets)].Offset := FCode.Size;
      
      localCnt := fn.LocalCount;
      maxTemp := -1;
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        if instr.Dest > maxTemp then maxTemp := instr.Dest;
        if instr.Src1 > maxTemp then maxTemp := instr.Src1;
        if instr.Src2 > maxTemp then maxTemp := instr.Src2;
      end;
      
      totalSlots := localCnt + maxTemp + 1;
      if totalSlots < 1 then totalSlots := 1;
      frameSize := ((totalSlots * 8) + 15) and not 15;  // 16-byte aligned
      
      // Prologue
      EmitIType($13, 0, X2, X2, -frameSize);  // addi sp, sp, -frameSize
      EmitIType($23, 3, X1, X2, frameSize - 8);  // sd ra, frameSize-8(sp)
      EmitIType($23, 3, X8, X2, frameSize - 16); // sd fp, frameSize-16(sp)
      EmitIType($13, 0, X8, X2, 0);  // mv fp, sp
      
      for j := 0 to High(fn.Instructions) do
      begin
        instr := fn.Instructions[j];
        
        case instr.Op of
          irConstInt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLi(X10, instr.ImmInt);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irConstStr:
            begin
              slotIdx := localCnt + instr.Dest;
              strIdx := StrToIntDef(instr.ImmStr, 0);
              SetLength(FLeaPositions, Length(FLeaPositions) + 1);
              FLeaPositions[High(FLeaPositions)] := FCode.Size;
              SetLength(FLeaStrIndex, Length(FLeaStrIndex) + 1);
              FLeaStrIndex[High(FLeaStrIndex)] := strIdx;
              EmitLi(X10, 0);  // placeholder
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadLocal:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(instr.Src1));  // ld
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irStoreLocal:
            begin
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($23, 3, X10, X2, instr.Dest);
            end;
          
          irAdd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, 0, X10, X10, X11);  // add
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irSub:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, $40, X10, X10, X11);  // sub
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irMul:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, 1, X10, X10, X11);  // mul
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irDiv:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 4, 0, X10, X10, X11);  // div
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irMod:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 4, 1, X10, X10, X11);  // rem
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irNeg:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitNeg(X10, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irNot:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitNot(X10, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irAnd:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, 0, X10, X10, X11);  // and
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irOr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 6, 0, X10, X10, X11);  // or
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irXor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 4, 0, X10, X10, X11);  // xor
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irNor:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 6, 0, X10, X10, X11);  // or
              EmitNot(X10, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irBitAnd, irBitOr, irBitXor, irBitNot:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              if instr.Op <> irBitNot then
              begin
                EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
                case instr.Op of
                  irBitAnd: EmitRType($33, 0, 0, X10, X10, X11);
                  irBitOr:  EmitRType($33, 6, 0, X10, X10, X11);
                  irBitXor: EmitRType($33, 4, 0, X10, X10, X11);
                end;
              end
              else
                EmitNot(X10, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irShl:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 1, 0, X10, X10, X11);  // sll
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irShr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 5, 0, X10, X10, X11);  // srl
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpEq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, $40, X10, X10, X11);  // sub
              EmitSnez(X10, X10);  // sltu x10, x0, x10 (x10 != 0 ? 1 : 0)
              EmitLi(X11, 1);
              EmitRType($33, 0, $40, X10, X11, X10);  // sub x10, 1, x10
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpNeq:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 0, $40, X10, X10, X11);
              EmitSnez(X10, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 2, 0, X10, X10, X11);  // slt
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpLe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 2, 0, X10, X11, X10);  // slt (b <= a ? 1 : 0)
              EmitLi(X11, 1);
              EmitRType($33, 0, $40, X10, X11, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpGt:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 2, 0, X10, X11, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irCmpGe:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 2, 0, X10, X10, X11);
              EmitLi(X11, 1);
              EmitRType($33, 0, $40, X10, X11, X10);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irLabel:
            begin
              SetLength(FLabels, Length(FLabels) + 1);
              FLabels[High(FLabels)].Name := instr.LabelName;
              FLabels[High(FLabels)].Offset := FCode.Size;
            end;
          
          irJmp:
            begin
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitJal(X0, 0);
            end;
          
          irBrTrue:
            begin
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitBnez(X10, 0);
            end;
          
          irBrFalse:
            begin
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              SetLength(FBranchPatches, Length(FBranchPatches) + 1);
              FBranchPatches[High(FBranchPatches)].CodePos := FCode.Size;
              FBranchPatches[High(FBranchPatches)].LabelName := instr.LabelName;
              EmitBeqz(X10, 0);
            end;
          
          irCall:
            begin
              SetLength(FCallPatches, Length(FCallPatches) + 1);
              FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
              FCallPatches[High(FCallPatches)].TargetName := instr.ImmStr;
              EmitJal(X1, 0);
            end;
          
          irCallBuiltin:
            begin
              if instr.ImmStr = 'exit' then
              begin
                if instr.Src1 >= 0 then
                  EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitLi(X10, 0);
                EmitLi(X17, SYS_EXIT);
                EmitEcall;
              end
              else if instr.ImmStr = 'PrintStr' then
              begin
                if instr.Src1 >= 0 then
                  EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1))
                else
                  EmitLi(X10, 0);
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_PrintStr';
                EmitJal(X1, 0);
              end
              else if instr.ImmStr = 'PrintInt' then
              begin
                // Stub
              end
              else if instr.ImmStr = 'open' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X12, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X12, 0);
                EmitLi(X17, SYS_OPENAT);
                EmitLi(X10, -100);  // AT_FDCWD
                // Need to shuffle: a0=AT_FDCWD, a1=path, a2=flags, a3=mode
                // Already: X10=AT_FDCWD, X11=path, X12=flags
                // Swap: X10 was path, need to reload
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'read' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X12, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X12, 0);
                EmitLi(X17, SYS_READ);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'write' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X12, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X12, 0);
                EmitLi(X17, SYS_WRITE);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'close' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                EmitLi(X17, SYS_CLOSE);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'lseek' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X12, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X12, 0);
                EmitLi(X17, SYS_LSEEK);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'unlink' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X11, 0);
                EmitLi(X10, -100);  // AT_FDCWD
                EmitLi(X12, 0);
                EmitLi(X17, SYS_UNLINKAT);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'mkdir' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X11, 0);
                EmitLi(X10, -100);
                EmitLi(X12, $1FF);
                EmitLi(X17, SYS_MKDIRAT);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rmdir' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'chmod' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'rename' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'getpid' then
              begin
                EmitLi(X17, SYS_GETPID);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'sleep_ms' then
              begin
              end
              else if instr.ImmStr = 'now_unix' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'now_unix_ms' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'Random' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'RandomSeed' then
              begin
              end
              else if instr.ImmStr = 'mmap' then
              begin
                EmitLi(X10, 0);
                if instr.Src1 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X11, 4096);
                EmitLi(X12, 3);  // MAP_PRIVATE|MAP_ANONYMOUS
                EmitLi(X13, -1); // fd
                EmitLi(X14, 0);  // offset
                EmitLi(X15, 3);  // PROT_READ|PROT_WRITE
                EmitLi(X17, SYS_MMAP);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'munmap' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 4096);
                EmitLi(X17, SYS_MUNMAP);
                EmitEcall;
              end
              else if instr.ImmStr = 'peek8' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                EmitIType($03, 0, X10, X10, 0);  // lb
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke8' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                EmitIType($23, 0, X11, X10, 0);  // sb
              end
              else if instr.ImmStr = 'StrLen' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                EmitLi(X11, 0);
                var slenLoop := FCode.Size;
                EmitIType($03, 0, X12, X10, 0);
                EmitBeqz(X12, 12);
                EmitIType($13, 0, X10, X10, 1);
                EmitIType($13, 0, X11, X11, 1);
                EmitJal(X0, slenLoop - FCode.Size);
                EmitMv(X10, X11);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrCharAt' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X11, 0);
                EmitIType($03, 0, X10, X10, 0);  // lb
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSetChar' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X11, 0);
                EmitIType($23, 0, X11, X10, 0);  // sb
              end
              else if instr.ImmStr = 'StrNew' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFree' then
              begin
              end
              else if instr.ImmStr = 'StrFromInt' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrAppend' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrFindChar' then
              begin
                EmitLi(X10, -1);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrSub' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrConcat' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrCopy' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'FileGetSize' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrStartsWith' then
              begin
                EmitLi(X10, 1);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEndsWith' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'StrEquals' then
              begin
                EmitLi(X10, 1);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArgC' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'GetArg' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'PrintFloat' then
              begin
              end
              else if instr.ImmStr = 'Println' then
              begin
              end
              else if instr.ImmStr = 'printf' then
              begin
              end
              else if instr.ImmStr = 'ioctl' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek16' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'peek32' then
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'poke16' then
              begin
              end
              else if instr.ImmStr = 'poke32' then
              begin
              end
              // === RISC-V Safety Builtins (3.3) ===
              else if instr.ImmStr = 'pmp_config' then
              begin
                // pmp_config(region, addr, size, cfg)
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X6, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X6, 0);
                if instr.Src3 >= 0 then EmitIType($03, 3, X7, X2, frameSize + SlotOffset(localCnt + instr.Src3)) else EmitLi(X7, 0);
                if Length(instr.ArgTemps) >= 1 then EmitIType($03, 3, X8, X2, frameSize + SlotOffset(localCnt + instr.ArgTemps[0])) else EmitLi(X8, PMP_CFG_R or PMP_CFG_W or PMP_CFG_X or PMP_CFG_A_NAPOT);
                // csrw pmpcfg0+region, cfg
                EmitCsrrwi(X0, CSR_PMPCFG0 + (X5 and 3), X8);
                // csrw pmpaddr0+region, addr
                EmitCsrrw(X0, CSR_PMPADDR0 + X5, X6);
              end
              else if instr.ImmStr = 'pmp_enable' then
              begin
                // Already enabled via pmp_config with L bit
              end
              else if instr.ImmStr = 'pmp_lock' then
              begin
                // Lock PMP region
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                EmitCsrrsi(X0, CSR_PMPCFG0 + (X5 and 3), PMP_CFG_L);
              end
              else if instr.ImmStr = 'ebreak' then
              begin
                EmitEbreak;
              end
              else if instr.ImmStr = 'fence' then
              begin
                EmitFence;
              end
              else if instr.ImmStr = 'fence_i' then
              begin
                EmitFenceI;
              end
              else if instr.ImmStr = 'csr_read' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                EmitCsrrs(X10, X5, X0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'csr_write' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X6, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X6, 0);
                EmitCsrrw(X0, X5, X6);
              end
              else if instr.ImmStr = 'csr_set' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X6, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X6, 0);
                EmitCsrrs(X0, X5, X6);
              end
              else if instr.ImmStr = 'csr_clear' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X5, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X5, 0);
                if instr.Src2 >= 0 then EmitIType($03, 3, X6, X2, frameSize + SlotOffset(localCnt + instr.Src2)) else EmitLi(X6, 0);
                EmitCsrrc(X0, X5, X6);
              end
              else if instr.ImmStr = 'get_mhartid' then
              begin
                EmitCsrrs(X10, CSR_MHARTID, X0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'get_mcycle' then
              begin
                EmitCsrrs(X10, CSR_MCYCLE, X0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'get_time' then
              begin
                EmitCsrrs(X10, CSR_TIME, X0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'wfi' then
              begin
                EmitWfi;
              end
              else if instr.ImmStr = 'mret' then
              begin
                EmitMret;
              end
              else if instr.ImmStr = 'sret' then
              begin
                EmitSret;
              end
              else if instr.ImmStr = 'ecall_syscall' then
              begin
                if instr.Src1 >= 0 then EmitIType($03, 3, X17, X2, frameSize + SlotOffset(localCnt + instr.Src1)) else EmitLi(X17, 0);
                EmitEcall;
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else if instr.ImmStr = 'stack_canary_check' then
              begin
                SetLength(FCallPatches, Length(FCallPatches) + 1);
                FCallPatches[High(FCallPatches)].CodePos := FCode.Size;
                FCallPatches[High(FCallPatches)].TargetName := '__builtin_stack_canary_check';
                EmitJal(X1, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end
              else
              begin
                EmitLi(X10, 0);
                if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
              end;
            end;
          
          irFuncExit:
            begin
              if instr.Src1 >= 0 then
                EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X1, X2, frameSize - 8);  // ld ra
              EmitIType($03, 3, X8, X2, frameSize - 16); // ld fp
              EmitIType($13, 0, X2, X2, frameSize);
              EmitRet;
            end;
          
          irPanic:
            begin
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitLi(X17, SYS_WRITE);
              EmitLi(X10, STDERR_FD);
              EmitLi(X12, 5);
              EmitEcall;
              EmitLi(X17, SYS_EXIT);
              EmitLi(X10, 1);
              EmitEcall;
            end;
          
          irLoadLocalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLi(X10, frameSize + SlotOffset(instr.Src1));
              EmitRType($33, 0, 0, X10, X10, X2);  // add
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadGlobalAddr:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitLi(X10, 0);
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irLoadElem:
            begin
              slotIdx := localCnt + instr.Dest;
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitRType($33, 1, 0, X11, X11, X0);  // slli x11, x11, 3
              EmitRType($33, 0, 0, X10, X10, X11);  // add
              EmitIType($03, 3, X10, X10, 0);  // ld
              EmitIType($23, 3, X10, X2, frameSize + SlotOffset(slotIdx));
            end;
          
          irStoreElem:
            begin
              EmitIType($03, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Src1));
              EmitIType($03, 3, X11, X2, frameSize + SlotOffset(localCnt + instr.Src2));
              EmitIType($03, 3, X12, X2, frameSize + SlotOffset(localCnt + instr.Src3));
              EmitRType($33, 1, 0, X11, X11, X0);
              EmitRType($33, 0, 0, X10, X10, X11);
              EmitIType($23, 3, X12, X10, 0);  // sd
            end;
          
          irStoreElemDyn, irLoadField, irStoreField, irLoadFieldHeap, irStoreFieldHeap:
            begin
              // Stub
            end;
          
          irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree:
            begin
              EmitLi(X10, 0);
              if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapNew, irSetNew:
            begin
              EmitLi(X10, 0);
              if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapSet, irSetAdd:
            begin
            end;
          
          irMapGet, irSetContains:
            begin
              EmitLi(X10, 0);
              if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapLen, irSetLen:
            begin
              EmitLi(X10, 0);
              if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irMapRemove, irSetRemove, irMapFree, irSetFree:
            begin
            end;
          
          irIsType:
            begin
              EmitLi(X10, 1);
              if instr.Dest >= 0 then EmitIType($23, 3, X10, X2, frameSize + SlotOffset(localCnt + instr.Dest));
            end;
          
          irInspect:
            begin
              EmitEbreak;
            end;
          
          else
            FDiag.Report(dkWarning, 'IR instruction not yet implemented for RISC-V: ' + IntToStr(Ord(instr.Op)), NullSpan);
        end;
      end;
    end;
  end;
  
  // Phase 5: Patch branches
  for i := 0 to High(FBranchPatches) do
  begin
    patchPos := FBranchPatches[i].CodePos;
    found := False;
    for labelIdx := 0 to High(FLabels) do
    begin
      if FLabels[labelIdx].Name = FBranchPatches[i].LabelName then
      begin
        targetPos := FLabels[labelIdx].Offset;
        branchOffset := targetPos - patchPos;
        // Patch JAL or B-type instruction
        var instr := FCode.ReadU32LE(patchPos);
        var opcode := instr and $7F;
        if opcode = $6F then  // JAL
        begin
          instr := (instr and $FFF0007F) or (UInt32(branchOffset and $100000) shl 11) or
                   (UInt32(branchOffset and $7FF) shl 12) or
                   (UInt32(branchOffset and $800) shl 11) or
                   (UInt32(branchOffset and $FFE00) shl 0);
          FCode.PatchU32LE(patchPos, instr);
        end
        else if opcode = $63 then  // B-type
        begin
          instr := (instr and $FFF0007F) or
                   (UInt32(branchOffset and $1000) shl 19) or
                   (UInt32(branchOffset and $800) shl 4) or
                   (UInt32(branchOffset and $7E) shl 7) or
                   (UInt32(branchOffset and $10) shl 3);
          FCode.PatchU32LE(patchPos, instr);
        end;
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 6: Patch calls
  for i := 0 to High(FCallPatches) do
  begin
    patchPos := FCallPatches[i].CodePos;
    found := False;
    for targetFuncIdx := 0 to High(FFuncOffsets) do
    begin
      if FFuncOffsets[targetFuncIdx].Name = FCallPatches[i].TargetName then
      begin
        targetPos := FFuncOffsets[targetFuncIdx].Offset;
        branchOffset := targetPos - patchPos;
        var instr := FCode.ReadU32LE(patchPos);
        instr := (instr and $FFF0007F) or (UInt32(branchOffset and $100000) shl 11) or
                 (UInt32(branchOffset and $7FF) shl 12) or
                 (UInt32(branchOffset and $800) shl 11) or
                 (UInt32(branchOffset and $FFE00) shl 0);
        FCode.PatchU32LE(patchPos, instr);
        found := True;
        Break;
      end;
    end;
  end;
  
  // Phase 7: Patch string LEA
  for i := 0 to High(FLeaPositions) do
  begin
    patchPos := FLeaPositions[i];
    strIdx := FLeaStrIndex[i];
    if (strIdx >= 0) and (strIdx < Length(stringByteOffsets)) then
    begin
      strOffset := stringByteOffsets[strIdx];
      // Patch li instruction (lui + addi)
      var lo := Int64(Int32(strOffset));
      var hi := (strOffset - lo) shr 12;
      if (lo and $800) <> 0 then begin lo := lo - $1000; hi := hi + 1; end;
      FCode.PatchU32LE(patchPos, (UInt32(hi and $FFFFF) shl 12) or (UInt32(X10) shl 7) or $37);
      FCode.PatchU32LE(patchPos + 4, (UInt32(lo and $FFF) shl 20) or (UInt32(X10) shl 15) or (UInt32(X10) shl 7) or $13);
    end;
  end;
  
  // Fallback
  EmitJal(X0, -4);
end;

function TRISCVCodeEmitter.GetCodeBuffer: TByteBuffer;
begin
  Result := FCode;
end;

function TRISCVCodeEmitter.GetDataBuffer: TByteBuffer;
begin
  Result := FData;
end;

function TRISCVCodeEmitter.GetExternalSymbols: TExternalSymbolArray;
begin
  Result := nil;
end;

procedure TRISCVCodeEmitter.SetEnergyLevel(level: TEnergyLevel);
begin
  FEnergyLevel := level;
end;

function TRISCVCodeEmitter.GetEnergyStats: TEnergyStats;
begin
  Result := FEnergyStats;
end;

end.
