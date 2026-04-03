{$mode objfpc}{$H+}
unit riscv_defs;

interface

// ============================================================================
// RISC-V RV64GC Definitions
// ============================================================================
// Target: RISC-V RV64GC (64-bit, General + Compressed + Atomic + Float)
// ABI: LP64D (Integer in a0-a7, Float in fa0-fa7)
// Platform: Linux (ecall syscalls)

// ============================================================================
// 1. Register Names
// ============================================================================

const
  // Integer Registers (x0-x31)
  X0  = 0;  X1  = 1;  X2  = 2;  X3  = 3;  X4  = 4;  X5  = 5;  X6  = 6;  X7  = 7;
  X8  = 8;  X9  = 9;  X10 = 10; X11 = 11; X12 = 12; X13 = 13; X14 = 14; X15 = 15;
  X16 = 16; X17 = 17; X18 = 18; X19 = 19; X20 = 20; X21 = 21; X22 = 22; X23 = 23;
  X24 = 24; X25 = 25; X26 = 26; X27 = 27; X28 = 28; X29 = 29; X30 = 30; X31 = 31;

  // ABI Aliases
  REG_ZERO = X0; REG_RA = X1; REG_SP = X2; REG_GP = X3; REG_TP = X4;
  REG_T0 = X5; REG_T1 = X6; REG_T2 = X7;
  REG_S0 = X8; REG_FP = X8; REG_S1 = X9;
  REG_A0 = X10; REG_A1 = X11; REG_A2 = X12; REG_A3 = X13;
  REG_A4 = X14; REG_A5 = X15; REG_A6 = X16; REG_A7 = X17;
  REG_S2 = X18; REG_S3 = X19; REG_S4 = X20; REG_S5 = X21;
  REG_S6 = X22; REG_S7 = X23; REG_S8 = X24; REG_S9 = X25;
  REG_S10 = X26; REG_S11 = X27;
  REG_T3 = X28; REG_T4 = X29; REG_T5 = X30; REG_T6 = X31;

  // Float Registers (f0-f31)
  F0  = 0;  F1  = 1;  F2  = 2;  F3  = 3;  F4  = 4;  F5  = 5;  F6  = 6;  F7  = 7;
  F8  = 8;  F9  = 9;  F10 = 10; F11 = 11; F12 = 12; F13 = 13; F14 = 14; F15 = 15;
  F16 = 16; F17 = 17; F18 = 18; F19 = 19; F20 = 20; F21 = 21; F22 = 22; F23 = 23;
  F24 = 24; F25 = 25; F26 = 26; F27 = 27; F28 = 28; F29 = 29; F30 = 30; F31 = 31;

// ============================================================================
// 2. Linux RISC-V Syscall Numbers
// ============================================================================

const
  SYS_EXIT      = 93;
  SYS_READ      = 63;
  SYS_WRITE     = 64;
  SYS_OPENAT    = 56;
  SYS_CLOSE     = 57;
  SYS_LSEEK     = 62;
  SYS_MMAP      = 222;
  SYS_MUNMAP    = 215;
  SYS_MPROTECT  = 226;
  SYS_BRK       = 214;
  SYS_GETPID    = 172;
  SYS_GETRANDOM = 278;
  SYS_NANOSLEEP = 101;
  SYS_CLOCK_GETTIME = 113;
  SYS_UNLINKAT  = 35;
  SYS_RENAMEAT  = 38;
  SYS_MKDIRAT   = 34;
  SYS_FCHMODAT  = 53;
  SYS_IOCTL     = 29;
  SYS_FSTAT     = 80;
  SYS_GETCWD    = 17;
  SYS_DUP       = 23;
  SYS_DUP3      = 24;
  SYS_FCNTL     = 25;
  SYS_SOCKET    = 198;
  SYS_BIND      = 200;
  SYS_LISTEN    = 201;
  SYS_ACCEPT    = 202;
  SYS_CONNECT   = 203;
  SYS_SENDTO    = 206;
  SYS_RECVFROM  = 207;
  SYS_SETSOCKOPT = 208;
  SYS_GETSOCKOPT = 209;
  SYS_SHUTDOWN  = 210;
  SYS_CLONE     = 220;
  SYS_EXECVE    = 221;
  SYS_WAIT4     = 260;
  SYS_KILL      = 129;
  SYS_TGKILL    = 131;
  SYS_RT_SIGACTION = 134;
  SYS_SIGALTSTACK = 140;
  SYS_FUTEX     = 98;
  SYS_SET_TID_ADDRESS = 96;
  SYS_EXIT_GROUP = 94;

// ============================================================================
// 3. PMP (Physical Memory Protection)
// ============================================================================

const
  PMP_REGION_COUNT = 16;
  PMP_CFG_R   = $01;
  PMP_CFG_W   = $02;
  PMP_CFG_X   = $04;
  PMP_CFG_A   = $18;
  PMP_CFG_A_OFF = $00;
  PMP_CFG_A_TOR = $08;
  PMP_CFG_A_NA4 = $10;
  PMP_CFG_A_NAPOT = $18;
  PMP_CFG_L   = $80;

  CSR_PMPCFG0 = $3A0; CSR_PMPCFG1 = $3A1; CSR_PMPCFG2 = $3A2; CSR_PMPCFG3 = $3A3;
  CSR_PMPADDR0 = $3B0; CSR_PMPADDR1 = $3B1; CSR_PMPADDR2 = $3B2; CSR_PMPADDR3 = $3B3;
  CSR_PMPADDR4 = $3B4; CSR_PMPADDR5 = $3B5; CSR_PMPADDR6 = $3B6; CSR_PMPADDR7 = $3B7;
  CSR_PMPADDR8 = $3B8; CSR_PMPADDR9 = $3B9; CSR_PMPADDR10 = $3BA; CSR_PMPADDR11 = $3BB;
  CSR_PMPADDR12 = $3BC; CSR_PMPADDR13 = $3BD; CSR_PMPADDR14 = $3BE; CSR_PMPADDR15 = $3BF;

  // Machine mode CSRs
  CSR_MSTATUS   = $300;
  CSR_MISA      = $301;
  CSR_MIE       = $304;
  CSR_MTVEC     = $305;
  CSR_MSCRATCH  = $340;
  CSR_MEPC      = $341;
  CSR_MCAUSE    = $342;
  CSR_MTVAL     = $343;
  CSR_MIP       = $344;
  CSR_MCYCLE    = $B00;
  CSR_MCYCLEH   = $B80;
  CSR_MHARTID   = $F14;

  // Supervisor mode CSRs
  CSR_SSTATUS   = $100;
  CSR_SIE       = $104;
  CSR_STVEC     = $105;
  CSR_SSCRATCH  = $140;
  CSR_SEPC      = $141;
  CSR_SCAUSE    = $142;
  CSR_STVAL     = $143;
  CSR_SIP       = $144;
  CSR_SATP      = $180;
  CSR_TIME      = $C01;

// ============================================================================
// 4. Memory Protection Constants
// ============================================================================

const
  PROT_READ  = 1; PROT_WRITE = 2; PROT_EXEC  = 4;
  MAP_PRIVATE = 2; MAP_ANONYMOUS = $20; MAP_FIXED  = $10; MAP_SHARED = 1;
  O_RDONLY = 0; O_WRONLY = 1; O_RDWR   = 2;
  O_CREAT  = 64; O_TRUNC  = 512; O_APPEND = 1024;
  SEEK_SET = 0; SEEK_CUR = 1; SEEK_END = 2;
  STDIN_FD  = 0; STDOUT_FD = 1; STDERR_FD = 2;

implementation
end.
