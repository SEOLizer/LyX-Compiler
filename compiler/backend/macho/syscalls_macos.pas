{$mode objfpc}{$H+}
unit syscalls_macos;

{ macOS Syscall-Nummern und Konstanten
  
  macOS verwendet das XNU-Kernel-Syscall-Interface.
  Die Syscall-Nummern unterscheiden sich von Linux.
  
  Für x86_64:
    - Syscall-Nummer in RAX
    - Parameter in RDI, RSI, RDX, R10, R8, R9 (wie Linux)
    - SYSCALL Instruktion
    - Return-Wert in RAX (bei Fehler: CF gesetzt, RAX = errno)
    
  Für arm64:
    - Syscall-Nummer in X16
    - Parameter in X0-X5
    - SVC #0x80 Instruktion
    - Return-Wert in X0 (bei Fehler: Carry-Flag gesetzt)
    
  macOS Syscall-Nummern haben ein Klassenprefix:
    - 0x2000000 = Unix-Syscalls (BSD-Layer)
    - 0x1000000 = Mach-Syscalls
}

interface

const
  { ============================================================
    Syscall-Klassen-Präfixe
    ============================================================ }
  SYSCALL_CLASS_UNIX  = $2000000;  // BSD/Unix Syscalls
  SYSCALL_CLASS_MACH  = $1000000;  // Mach Kernel Syscalls
  
  { ============================================================
    BSD/Unix Syscalls (Klasse 2)
    ============================================================ }
    
  // Prozess-Kontrolle
  SYS_EXIT            = SYSCALL_CLASS_UNIX or 1;    // void exit(int status)
  SYS_FORK            = SYSCALL_CLASS_UNIX or 2;    // pid_t fork(void)
  
  // I/O Operationen
  SYS_READ            = SYSCALL_CLASS_UNIX or 3;    // ssize_t read(int fd, void *buf, size_t count)
  SYS_WRITE           = SYSCALL_CLASS_UNIX or 4;    // ssize_t write(int fd, const void *buf, size_t count)
  SYS_OPEN            = SYSCALL_CLASS_UNIX or 5;    // int open(const char *path, int flags, mode_t mode)
  SYS_CLOSE           = SYSCALL_CLASS_UNIX or 6;    // int close(int fd)
  
  // Prozess-Warteoperationen
  SYS_WAIT4           = SYSCALL_CLASS_UNIX or 7;    // pid_t wait4(pid_t pid, int *status, int options, struct rusage *rusage)
  
  // Datei-Operationen
  SYS_LINK            = SYSCALL_CLASS_UNIX or 9;    // int link(const char *old, const char *new)
  SYS_UNLINK          = SYSCALL_CLASS_UNIX or 10;   // int unlink(const char *path)
  SYS_CHDIR           = SYSCALL_CLASS_UNIX or 12;   // int chdir(const char *path)
  SYS_FCHDIR          = SYSCALL_CLASS_UNIX or 13;   // int fchdir(int fd)
  SYS_MKNOD           = SYSCALL_CLASS_UNIX or 14;   // int mknod(const char *path, mode_t mode, dev_t dev)
  SYS_CHMOD           = SYSCALL_CLASS_UNIX or 15;   // int chmod(const char *path, mode_t mode)
  SYS_CHOWN           = SYSCALL_CLASS_UNIX or 16;   // int chown(const char *path, uid_t owner, gid_t group)
  
  // Prozess-IDs
  SYS_GETPID          = SYSCALL_CLASS_UNIX or 20;   // pid_t getpid(void)
  SYS_GETUID          = SYSCALL_CLASS_UNIX or 24;   // uid_t getuid(void)
  SYS_GETEUID         = SYSCALL_CLASS_UNIX or 25;   // uid_t geteuid(void)
  SYS_GETGID          = SYSCALL_CLASS_UNIX or 47;   // gid_t getgid(void)
  SYS_GETEGID         = SYSCALL_CLASS_UNIX or 43;   // gid_t getegid(void)
  
  // Memory Mapping
  SYS_MMAP            = SYSCALL_CLASS_UNIX or 197;  // void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
  SYS_MUNMAP          = SYSCALL_CLASS_UNIX or 73;   // int munmap(void *addr, size_t len)
  SYS_MPROTECT        = SYSCALL_CLASS_UNIX or 74;   // int mprotect(void *addr, size_t len, int prot)
  
  // Sonstige
  SYS_IOCTL           = SYSCALL_CLASS_UNIX or 54;   // int ioctl(int fd, unsigned long request, ...)
  SYS_FCNTL           = SYSCALL_CLASS_UNIX or 92;   // int fcntl(int fd, int cmd, ...)
  SYS_DUP             = SYSCALL_CLASS_UNIX or 41;   // int dup(int fd)
  SYS_DUP2            = SYSCALL_CLASS_UNIX or 90;   // int dup2(int old, int new)
  SYS_PIPE            = SYSCALL_CLASS_UNIX or 42;   // int pipe(int pipefd[2])
  
  // Zeit
  SYS_GETTIMEOFDAY    = SYSCALL_CLASS_UNIX or 116;  // int gettimeofday(struct timeval *tv, struct timezone *tz)
  SYS_NANOSLEEP       = SYSCALL_CLASS_UNIX or 240;  // int nanosleep(const struct timespec *req, struct timespec *rem)
  
  // Dateisystem-Status
  SYS_STAT            = SYSCALL_CLASS_UNIX or 188;  // int stat(const char *path, struct stat *buf)
  SYS_FSTAT           = SYSCALL_CLASS_UNIX or 189;  // int fstat(int fd, struct stat *buf)
  SYS_LSTAT           = SYSCALL_CLASS_UNIX or 190;  // int lstat(const char *path, struct stat *buf)
  SYS_STAT64          = SYSCALL_CLASS_UNIX or 338;  // int stat64(const char *path, struct stat64 *buf)
  SYS_FSTAT64         = SYSCALL_CLASS_UNIX or 339;  // int fstat64(int fd, struct stat64 *buf)
  SYS_LSTAT64         = SYSCALL_CLASS_UNIX or 340;  // int lstat64(const char *path, struct stat64 *buf)
  
  // Datei-Positionierung
  SYS_LSEEK           = SYSCALL_CLASS_UNIX or 199;  // off_t lseek(int fd, off_t offset, int whence)
  
  // Socket-Operationen
  SYS_SOCKET          = SYSCALL_CLASS_UNIX or 97;   // int socket(int domain, int type, int protocol)
  SYS_CONNECT         = SYSCALL_CLASS_UNIX or 98;   // int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen)
  SYS_ACCEPT          = SYSCALL_CLASS_UNIX or 30;   // int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen)
  SYS_SENDTO          = SYSCALL_CLASS_UNIX or 133;  // ssize_t sendto(...)
  SYS_RECVFROM        = SYSCALL_CLASS_UNIX or 29;   // ssize_t recvfrom(...)
  SYS_BIND            = SYSCALL_CLASS_UNIX or 104;  // int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen)
  SYS_LISTEN          = SYSCALL_CLASS_UNIX or 106;  // int listen(int sockfd, int backlog)
  
  // Prozess-Ausführung
  SYS_EXECVE          = SYSCALL_CLASS_UNIX or 59;   // int execve(const char *path, char *const argv[], char *const envp[])
  
  // Signale
  SYS_KILL            = SYSCALL_CLASS_UNIX or 37;   // int kill(pid_t pid, int sig)
  SYS_SIGACTION       = SYSCALL_CLASS_UNIX or 46;   // int sigaction(int sig, const struct sigaction *act, struct sigaction *oact)
  
  { ============================================================
    Standard Dateideskriptoren
    ============================================================ }
  STDIN_FILENO  = 0;
  STDOUT_FILENO = 1;
  STDERR_FILENO = 2;
  
  { ============================================================
    Datei-Öffnungsflags (für SYS_OPEN)
    ============================================================ }
  O_RDONLY    = $0000;
  O_WRONLY    = $0001;
  O_RDWR      = $0002;
  O_CREAT     = $0200;
  O_TRUNC     = $0400;
  O_EXCL      = $0800;
  O_APPEND    = $0008;
  O_NONBLOCK  = $0004;
  
  { ============================================================
    Memory Protection Flags (für SYS_MMAP, SYS_MPROTECT)
    ============================================================ }
  PROT_NONE   = $00;
  PROT_READ   = $01;
  PROT_WRITE  = $02;
  PROT_EXEC   = $04;
  
  { ============================================================
    Memory Mapping Flags (für SYS_MMAP)
    ============================================================ }
  MAP_SHARED    = $0001;
  MAP_PRIVATE   = $0002;
  MAP_FIXED     = $0010;
  MAP_ANONYMOUS = $1000;  // MAP_ANON auf macOS
  MAP_ANON      = $1000;
  
  { ============================================================
    Seek-Modi (für SYS_LSEEK)
    ============================================================ }
  SEEK_SET = 0;  // Vom Anfang
  SEEK_CUR = 1;  // Von aktueller Position
  SEEK_END = 2;  // Vom Ende

implementation

end.
