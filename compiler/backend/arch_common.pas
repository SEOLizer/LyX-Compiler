{$mode objfpc}{$H+}
unit arch_common;

{ Shared backend utilities across all architecture emitters.

  Single source of truth for:
    - Stack slot addressing (FP-based 64-bit layout)
    - Frame size alignment
    - ABI parameter register lists and counts
    - Architecture register number constants

  Architecture-specific concerns (instruction encoding, prologue byte
  sequences, calling convention details) remain in each emitter.
}

interface

const
  // -----------------------------------------------------------------------
  // x86-64 general-purpose register encodings (ModRM/SIB reg field)
  // Used by: x86_64_emit, x86_64_win64, macosx64_emit
  // -----------------------------------------------------------------------
  X86_RAX = 0;  X86_RCX = 1;  X86_RDX = 2;  X86_RBX = 3;
  X86_RSP = 4;  X86_RBP = 5;  X86_RSI = 6;  X86_RDI = 7;
  X86_R8  = 8;  X86_R9  = 9;  X86_R10 = 10; X86_R11 = 11;
  X86_R12 = 12; X86_R13 = 13; X86_R14 = 14; X86_R15 = 15;

  // -----------------------------------------------------------------------
  // ARM64 general-purpose register numbers (0-31)
  // Used by: arm64_emit, win_arm64_emit
  // -----------------------------------------------------------------------
  ARM64_X0  =  0; ARM64_X1  =  1; ARM64_X2  =  2; ARM64_X3  =  3;
  ARM64_X4  =  4; ARM64_X5  =  5; ARM64_X6  =  6; ARM64_X7  =  7;
  ARM64_X8  =  8; ARM64_X9  =  9; ARM64_X10 = 10; ARM64_X11 = 11;
  ARM64_X12 = 12; ARM64_X13 = 13; ARM64_X14 = 14; ARM64_X15 = 15;
  ARM64_X16 = 16; ARM64_X17 = 17; ARM64_X18 = 18; ARM64_X19 = 19;
  ARM64_X20 = 20; ARM64_X21 = 21; ARM64_X22 = 22; ARM64_X23 = 23;
  ARM64_X24 = 24; ARM64_X25 = 25; ARM64_X26 = 26; ARM64_X27 = 27;
  ARM64_X28 = 28; ARM64_FP  = 29; ARM64_LR  = 30; ARM64_XZR = 31;
  ARM64_SP  = 31; // alias for zero register / stack pointer context

  // -----------------------------------------------------------------------
  // ABI: maximum number of parameters passed in registers
  // -----------------------------------------------------------------------
  ABI_SYSVAMD64_MAX_REG_PARAMS = 6;  // RDI RSI RDX RCX R8 R9
  ABI_AAPCS64_MAX_REG_PARAMS   = 8;  // X0..X7
  ABI_WIN64_MAX_REG_PARAMS     = 4;  // RCX RDX R8 R9

  // -----------------------------------------------------------------------
  // ABI: parameter register lists (values are register numbers above)
  // -----------------------------------------------------------------------
  // System V AMD64 ABI (Linux x86-64, macOS x86-64)
  ABI_SYSVAMD64_PARAM_REGS: array[0..5] of Byte =
    (X86_RDI, X86_RSI, X86_RDX, X86_RCX, X86_R8, X86_R9);

  // AAPCS64 (AArch64 Procedure Call Standard — Linux ARM64, Windows ARM64)
  ABI_AAPCS64_PARAM_REGS: array[0..7] of Byte =
    (ARM64_X0, ARM64_X1, ARM64_X2, ARM64_X3,
     ARM64_X4, ARM64_X5, ARM64_X6, ARM64_X7);

  // Microsoft x64 ABI (Windows x86-64)
  ABI_WIN64_PARAM_REGS: array[0..3] of Byte =
    (X86_RCX, X86_RDX, X86_R8, X86_R9);

{ --------------------------------------------------------------------------
  FPBaseSlotOffset — stack slot offset from the frame pointer

  All 64-bit FP-based backends use this layout:
    slot 0 → [FP -  8]   (first local / first temp)
    slot 1 → [FP - 16]
    slot N → [FP - (N+1)*8]

  Applicable to: x86_64_emit, x86_64_win64, macosx64_emit,
                 arm64_emit (X29-relative), win_arm64_emit.

  NOT applicable to RISC-V (SP-based, positive offsets) or
  Xtensa (SP-based, 32-bit slots).
  -------------------------------------------------------------------------- }
function FPBaseSlotOffset(slot: Integer): Integer; inline;

{ --------------------------------------------------------------------------
  CalcFrameSize64 — frame size for x86-64 style (no dedicated FP/LR slot)

  Returns the minimum number of bytes to allocate on the stack for
  `totalSlots` 8-byte slots, rounded up to a 16-byte boundary.
  -------------------------------------------------------------------------- }
function CalcFrameSize64(totalSlots: Integer): Integer; inline;

{ --------------------------------------------------------------------------
  CalcFrameSize64FPLR — frame size for AAPCS64 (ARM64)

  Like CalcFrameSize64, but adds 16 bytes for the saved FP/LR register
  pair stored just above the local variable area (via STP X29, X30).
  -------------------------------------------------------------------------- }
function CalcFrameSize64FPLR(totalSlots: Integer): Integer; inline;

implementation

function FPBaseSlotOffset(slot: Integer): Integer; inline;
begin
  Result := -(slot + 1) * 8;
end;

function CalcFrameSize64(totalSlots: Integer): Integer; inline;
begin
  if totalSlots < 1 then totalSlots := 1;
  Result := (totalSlots * 8 + 15) and not 15;
end;

function CalcFrameSize64FPLR(totalSlots: Integer): Integer; inline;
begin
  if totalSlots < 1 then totalSlots := 1;
  // +16 bytes for the saved FP/LR pair, then align to 16 bytes
  Result := (totalSlots * 8 + 16 + 15) and not 15;
end;

end.
