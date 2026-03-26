{$mode objfpc}{$H+}
unit syscalls_esp32;

interface

// ESP32 Syscall Numbers (Xtensa ABI)
// Using the standard Xtensa syscall convention: 
//   a2 = syscall number
//   a3-a6 = arguments
//   a8 = return value

const
  // Standard POSIX-like syscalls
  SYS_EXIT   = 1;
  SYS_WRITE  = 4;
  SYS_READ   = 3;
  
  // ESP32-specific syscalls (hypothetical - based on ESP-IDF)
  SYS_GPIO_SET_MODE    = 100;
  SYS_GPIO_WRITE       = 101;
  SYS_GPIO_READ        = 102;
  SYS_UART_WRITE       = 200;
  SYS_UART_READ        = 201;
  SYS_UART_CONFIG      = 202;
  
  // System info syscalls
  SYS_GET_TIME         = 300;
  SYS_DELAY_MS         = 301;
  SYS_RANDOM           = 302;
  SYS_RANDOM_SEED      = 303;

// File descriptors
const
  STDIN_FD  = 0;
  STDOUT_FD = 1;
  STDERR_FD = 2;

// GPIO Modes
const
  GPIO_MODE_INPUT  = 0;
  GPIO_MODE_OUTPUT = 1;
  GPIO_MODE_INPUT_OUTPUT = 2;

// UART Ports
const
  UART_PORT_0 = 0;
  UART_PORT_1 = 1;

implementation

end.
