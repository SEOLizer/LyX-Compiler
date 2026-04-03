{$mode objfpc}{$H+}
unit arm_cm_defs;

interface

// ============================================================================
// ARM Cortex-M Safety-Critical Definitions (aerospace-todo 3.2)
// ============================================================================
//
// Unterstützt: Cortex-M0/M0+, M3, M4, M7, M33 (TrustZone)
// Ziel: Safety-Critical Embedded mit DO-178C DAL A/B/C Compliance

// ============================================================================
// 1. MPU (Memory Protection Unit) - ARMv7-M / ARMv8-M
// ============================================================================

// MPU Region Numbers
const
  ARM_MPU_REGION_FLASH    = 0;  // Flash memory (RO, X)
  ARM_MPU_REGION_SRAM     = 1;  // SRAM (RW, no X)
  ARM_MPU_REGION_PERIPH   = 2;  // Peripherals (device memory)
  ARM_MPU_REGION_STACK    = 3;  // Stack (RW, no X, with canary)
  ARM_MPU_REGION_HEAP     = 4;  // Heap (RW)
  ARM_MPU_REGION_EXTMEM   = 5;  // External memory (if available)
  ARM_MPU_REGION_COUNT    = 8;  // Cortex-M supports up to 8 regions

// MPU Access Permissions (AP field)
const
  ARM_MPU_AP_PRIV_RW      = 1;  // Privileged: RW, Unprivileged: No access
  ARM_MPU_AP_FULL_RW      = 3;  // Full RW access
  ARM_MPU_AP_PRIV_RO      = 5;  // Privileged: RO, Unprivileged: No access
  ARM_MPU_AP_RO           = 6;  // Full RO access
  ARM_MPU_AP_PRIV_RO_U_RO = 7;  // RO for both privileged and unprivileged

// MPU Memory Types and Attributes
const
  ARM_MPU_DEVICE_NGNRNE   = 0;  // Device: nGnRnE (no gather, no reorder, no early write ack)
  ARM_MPU_DEVICE_NGNRE    = 1;  // Device: nGnRE
  ARM_MPU_DEVICE_NGRE     = 2;  // Device: nGRE
  ARM_MPU_NORMAL_WT       = 3;  // Normal: Write-through
  ARM_MPU_NORMAL_WB       = 4;  // Normal: Write-back
  ARM_MPU_NORMAL_NC       = 5;  // Normal: Non-cacheable

// MPU Region Sizes (encoded as 2^(size+1))
const
  ARM_MPU_SIZE_32B        = 4;   // 32 bytes
  ARM_MPU_SIZE_64B        = 5;
  ARM_MPU_SIZE_128B       = 6;
  ARM_MPU_SIZE_256B       = 7;
  ARM_MPU_SIZE_512B       = 8;
  ARM_MPU_SIZE_1KB        = 9;
  ARM_MPU_SIZE_2KB        = 10;
  ARM_MPU_SIZE_4KB        = 11;
  ARM_MPU_SIZE_8KB        = 12;
  ARM_MPU_SIZE_16KB       = 13;
  ARM_MPU_SIZE_32KB       = 14;
  ARM_MPU_SIZE_64KB       = 15;
  ARM_MPU_SIZE_128KB      = 16;
  ARM_MPU_SIZE_256KB      = 17;
  ARM_MPU_SIZE_512KB      = 18;
  ARM_MPU_SIZE_1MB        = 19;
  ARM_MPU_SIZE_2MB        = 20;
  ARM_MPU_SIZE_4MB        = 21;
  ARM_MPU_SIZE_8MB        = 22;
  ARM_MPU_SIZE_16MB       = 23;
  ARM_MPU_SIZE_32MB       = 24;
  ARM_MPU_SIZE_64MB       = 25;
  ARM_MPU_SIZE_128MB      = 26;
  ARM_MPU_SIZE_256MB      = 27;
  ARM_MPU_SIZE_512MB      = 28;
  ARM_MPU_SIZE_1GB        = 29;
  ARM_MPU_SIZE_2GB        = 30;
  ARM_MPU_SIZE_4GB        = 31;

// ============================================================================
// 2. Fault Handler Types
// ============================================================================

// Fault Status Register Addresses
const
  ARM_SCB_CFSR          = $E000ED28;  // Configurable Fault Status Register
  ARM_SCB_HFSR          = $E000ED2C;  // HardFault Status Register
  ARM_SCB_DFSR          = $E000ED30;  // Debug Fault Status Register
  ARM_SCB_MMFAR         = $E000ED34;  // MemManage Fault Address Register
  ARM_SCB_BFAR          = $E000ED38;  // BusFault Address Register
  ARM_SCB_AFSR          = $E000ED3C;  // Auxiliary Fault Status Register

// Fault Types (for handler dispatch)
const
  ARM_FAULT_MEMMANAGE     = 0;
  ARM_FAULT_BUS           = 1;
  ARM_FAULT_USAGE         = 2;
  ARM_FAULT_HARD          = 3;
  ARM_FAULT_DEBUG         = 4;
  ARM_FAULT_SECURE        = 5;  // Cortex-M33+ only
  ARM_FAULT_COUNT         = 6;

// CFSR Bit Masks
const
  // MemManage Fault Status (MMFSR)
  ARM_CFSR_IACCVIOL     = $01;  // Instruction Access Violation
  ARM_CFSR_DACCVIOL     = $02;  // Data Access Violation
  ARM_CFSR_MUNSTKERR    = $08;  // Memory Management Unstacking Error
  ARM_CFSR_MSTKERR      = $10;  // Memory Management Stacking Error
  ARM_CFSR_MLSPERR      = $20;  // Memory Management Lazy State Preservation Error (M4/M7)
  ARM_CFSR_MMARVALID    = $80;  // MMAR has valid address

  // BusFault Status (BFSR)
  ARM_CFSR_IBUSERR      = $0100;  // Instruction Bus Error
  ARM_CFSR_PRECISERR    = $0200;  // Precise Data Bus Error
  ARM_CFSR_IMPREISERR   = $0400;  // Imprecise Data Bus Error
  ARM_CFSR_UNSTKERR     = $0800;  // BusFault Unstacking Error
  ARM_CFSR_STKERR       = $1000;  // BusFault Stacking Error
  ARM_CFSR_LSPERR       = $2000;  // BusFault Lazy State Preservation Error (M4/M7)
  ARM_CFSR_BFARVALID    = $8000;  // BFAR has valid address

  // UsageFault Status (UFSR)
  ARM_CFSR_UNDEFINSTR   = $010000;  // Undefined Instruction
  ARM_CFSR_INVSTATE     = $020000;  // Invalid State (Thumb/ARM)
  ARM_CFSR_INVPC        = $040000;  // Invalid PC (EPSR.T = 0)
  ARM_CFSR_NOCP         = $080000;  // No Coprocessor
  ARM_CFSR_UNALIGNED    = $01000000; // Unaligned Access (M3+)
  ARM_CFSR_DIVBYZERO    = $02000000; // Divide By Zero (M3+)

  // HardFault Status (HFSR)
  ARM_HFSR_VECTTBL      = $00000002;  // Vector Table Read Error
  ARM_HFSR_FORCED       = $40000000;  // Forced HardFault (escalated)
  ARM_HFSR_DEBUGEVT     = $80000000;  // Debug Event

// ============================================================================
// 3. Stack Canary
// ============================================================================

const
  ARM_STACK_CANARY_VALUE  = $DEADBEEF;  // Canary pattern
  ARM_STACK_CANARY_SIZE   = 4;           // 4 bytes per canary
  ARM_STACK_CANARY_COUNT  = 3;           // 3 canaries: top, middle, bottom

// ============================================================================
// 4. Privileged/Unprivileged Mode
// ============================================================================

const
  ARM_CONTROL_PRIVILEGED  = 0;   // Thread mode: Privileged, MSP
  ARM_CONTROL_UNPRIV_MSP  = 1;   // Thread mode: Unprivileged, MSP
  ARM_CONTROL_UNPRIV_PSP  = 3;   // Thread mode: Unprivileged, PSP
  ARM_CONTROL_SPSEL       = 2;   // Stack Pointer Select (0=MSP, 1=PSP)
  ARM_CONTROL_NPRIV       = 1;   // Non-Privileged bit

// ============================================================================
// 5. TrustZone (Cortex-M33+, ARMv8-M)
// ============================================================================

const
  ARM_TZ_SECURE_STACK_SIZE = 2048;  // Default secure stack size
  ARM_TZ_NONSECURE_STACK_SIZE = 1024;  // Default non-secure stack size
  ARM_TZ_SAU_REGION_COUNT = 8;     // Security Attribution Unit regions

// SAU Region Types
const
  ARM_SAU_SECURE          = 0;  // Secure region
  ARM_SAU_NONSECURE       = 1;  // Non-secure region
  ARM_SAU_NONSECURE_CALLABLE = 2; // Non-secure callable (NSC)

// ============================================================================
// 6. Builtins for ARM Cortex-M Safety
// ============================================================================

// Diese Builtins werden vom Compiler als irCallBuiltin generiert:
//
// Builtin                    | Beschreibung
// ---------------------------|------------------------------------------
// mpu_enable()               | MPU aktivieren
// mpu_disable()              | MPU deaktivieren
// mpu_config(region,addr,size,ap) | MPU-Region konfigurieren
// fault_handler_install(type, fn) | Fault-Handler registrieren
// stack_canary_init()        | Stack-Canary initialisieren
// stack_canary_check()       | Stack-Canary prüfen → 0=OK, -1=Overflow
// set_unprivileged()         | Zu Unprivileged-Mode wechseln
// set_privileged()           | Zu Privileged-Mode wechseln (nur aus Handler)
// tz_init()                  | TrustZone initialisieren (M33+)
// tz_enter_nonsecure()       | Zu Non-Secure-Mode wechseln (M33+)
// tz_sau_config(region,addr,size,type) | SAU-Region konfigurieren (M33+)
// get_fault_status()         → CFSR/HFSR auslesen
// get_fault_address()        → MMFAR/BFAR auslesen
// clear_fault_status()       → Fault-Status zurücksetzen
// bkpt()                     → Breakpoint-Instruktion

implementation

end.
