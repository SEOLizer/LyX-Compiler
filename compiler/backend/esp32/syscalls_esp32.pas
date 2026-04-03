{$mode objfpc}{$H+}
unit syscalls_esp32;

interface

// ESP32 Syscall Numbers (Xtensa ABI via ESP-IDF/newlib)
// ESP32 verwendet newlib, daher sind die Syscall-Nummern ähnlich wie bei Linux
// aber mit ESP-IDF-spezifischen Erweiterungen

const
  // Standard POSIX syscalls (via newlib)
  SYS_EXIT     = 93;    // sys_exit
  SYS_WRITE    = 64;    // sys_write
  SYS_READ     = 63;    // sys_read
  SYS_OPENAT   = 56;    // sys_openat
  SYS_CLOSE    = 57;    // sys_close
  SYS_LSEEK    = 62;    // sys_lseek
  SYS_UNLINKAT = 35;    // sys_unlinkat
  SYS_RENAMEAT = 38;    // sys_renameat
  SYS_FSTAT    = 80;    // sys_fstat
  SYS_GETPID   = 172;   // sys_getpid
  SYS_NANOSLEEP = 101;  // sys_nanosleep
  
  // Memory management
  SYS_MMAP     = 222;   // sys_mmap
  SYS_MUNMAP   = 215;   // sys_munmap
  
  // ESP32-specific syscalls (via ESP-IDF)
  SYS_GPIO_SET_MODE    = 1000;
  SYS_GPIO_WRITE       = 1001;
  SYS_GPIO_READ        = 1002;
  SYS_UART_WRITE       = 1100;
  SYS_UART_READ        = 1101;
  SYS_UART_CONFIG      = 1102;
  SYS_GET_TIME         = 1200;
  SYS_DELAY_MS         = 1201;
  SYS_RANDOM           = 1202;
  SYS_RANDOM_SEED      = 1203;

// File descriptors
const
  STDIN_FD  = 0;
  STDOUT_FD = 1;
  STDERR_FD = 2;

// ESP32 UART
const
  UART_PORT_0 = 0;
  UART_PORT_1 = 1;
  UART_PORT_2 = 2;

// GPIO Modes
const
  GPIO_MODE_INPUT  = 0;
  GPIO_MODE_OUTPUT = 1;
  GPIO_MODE_INPUT_OUTPUT = 2;

// Memory protection flags (mmap)
const
  PROT_READ  = 1;
  PROT_WRITE = 2;
  PROT_EXEC  = 4;
  MAP_PRIVATE = 2;
  MAP_ANONYMOUS = 32;

// open flags
const
  O_RDONLY = 0;
  O_WRONLY = 1;
  O_RDWR   = 2;
  O_CREAT  = 64;
  O_TRUNC  = 512;
  O_APPEND = 1024;

// lseek whence
const
  SEEK_SET = 0;
  SEEK_CUR = 1;
  SEEK_END = 2;

// ESP32 SPIFFS base path
const
  SPIFFS_BASE_PATH = '/spiffs';

implementation

end.
