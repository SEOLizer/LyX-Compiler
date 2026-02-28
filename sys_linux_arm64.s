; sys_linux_arm64.s
; Assembler-Brücke für Linux ARM64 Syscalls
; Wird von Lyx-compiliertem Code aufgerufen

section .text
    global _lyx_syscall3
    global _lyx_syscall0
    global _lyx_syscall1
    global _lyx_syscall2
    global _lyx_error_from_syscall
    global _lyx_is_error

; Universelle Syscall-Funktion (bis zu 4 Argumente)
; int64 _lyx_syscall3(int64 num, int64 a1, int64 a2, int64 a3)
_lyx_syscall3:
    mov x8, x0        ; Syscall Nummer (x8 ist der Syscall-Nummer-Register auf ARM64)
    mov x0, x1        ; 1. Argument
    mov x1, x2        ; 2. Argument
    mov x2, x3        ; 3. Argument
    mov x3, x4        ; 4. Argument
    svc #0            ; Syscall ausführen
    ret

; Spezialisierte Syscalls für weniger Argumente
; int64 _lyx_syscall2(int64 num, int64 a1, int64 a2)
_lyx_syscall2:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    svc #0
    ret

; int64 _lyx_syscall1(int64 num, int64 a1)
_lyx_syscall1:
    mov x8, x0
    mov x0, x1
    svc #0
    ret

; int64 _lyx_syscall0(int64 num)
_lyx_syscall0:
    mov x8, x0
    svc #0
    ret

; Hilfsfunktionen für Fehlerbehandlung
; int64 _lyx_error_from_syscall(int64 result)
_lyx_error_from_syscall:
    cmp x0, #0
    cneg x0, x0, lt  ; negate if negative
    ret

; int64 _lyx_is_error(int64 result)
_lyx_is_error:
    cmp x0, #0
    cset x0, lt       ; set to 1 if negative
    ret
