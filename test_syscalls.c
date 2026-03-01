/* test_syscalls.c */
/* Einfacher Test für die Syscall-Funktionen */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <string.h>

long _lyx_syscall3(long num, long a1, long a2, long a3) {
    return syscall(num, a1, a2, a3);
}

int _lyx_is_error(long result) {
    return result < 0;
}

int main() {
    printf("=== Pure Syscall FS API Test ===\n");
    
    // Test 1: write syscall
    printf("Test 1: write syscall\n");
    const char *msg1 = "Hello from pure syscall!\n";
    long write_res = _lyx_syscall3(1, 1, (long)msg1, 26);
    printf("  write returned: %ld\n", write_res);
    
    // Test 2: Datei erstellen
    printf("Test 2: create file\n");
    const char *filename = "testfile.txt";
    long fd = _lyx_syscall3(2, (long)filename, 577, 420);
    
    if (fd >= 0) {
        printf("  File opened, fd=%ld\n", fd);
        
        // In Datei schreiben
        const char *content = "hello\n";
        long wr = _lyx_syscall3(1, fd, (long)content, 6);
        printf("  Written %ld bytes\n", wr);
        
        // Datei schließen
        long cr = _lyx_syscall3(3, fd, 0, 0);
        printf("  Close returned: %ld\n", cr);
    } else {
        printf("  Failed to open file: %ld\n", fd);
    }
    
    // Test 3: Fehlerbehandlung
    printf("Test 3: error handling\n");
    int err_test1 = _lyx_is_error(5);
    int err_test2 = _lyx_is_error(-5);
    printf("  is_error(5)=%d, is_error(-5)=%d\n", err_test1, err_test2);
    
    if (!err_test1 && err_test2) {
        printf("  Error detection works!\n");
    }
    
    printf("=== Tests Complete ===\n");
    return 0;
}
