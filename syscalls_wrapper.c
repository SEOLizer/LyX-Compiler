/* syscalls_wrapper.c */
/* Wrapper-Bibliothek für die Syscall-Funktionen */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/unistd.h>

long _lyx_syscall3(long num, long a1, long a2, long a3) {
    return syscall(num, a1, a2, a3);
}

long _lyx_syscall2(long num, long a1, long a2) {
    return syscall(num, a1, a2);
}

long _lyx_syscall1(long num, long a1) {
    return syscall(num, a1);
}

long _lyx_syscall0(long num) {
    return syscall(num);
}

int _lyx_is_error(long result) {
    return result < 0;
}

long _lyx_error_from_syscall(long result) {
    if (result < 0) {
        return -result;
    }
    return 0;
}
