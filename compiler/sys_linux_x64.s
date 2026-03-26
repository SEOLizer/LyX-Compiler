; sys_linux_x64.s
; Assembler-Brücke für Linux x86_64 Syscalls
; Wird von Lyx-compiliertem Code aufgerufen

section .text
    global _lyx_syscall3
    global _lyx_syscall0
    global _lyx_syscall1
    global _lyx_syscall2

; Universelle Syscall-Funktion (bis zu 4 Argumente)
; int64 _lyx_syscall3(int64 num, int64 a1, int64 a2, int64 a3)
_lyx_syscall3:
    mov rax, rdi        ; Syscall Nummer
    mov rdi, rsi        ; 1. Argument
    mov rsi, rdx        ; 2. Argument
    mov rdx, rcx        ; 3. Argument
    mov r10, r8         ; 4. Argument (r10 statt rcx, da syscall rcx überschreibt)
    syscall
    ret

; Spezialisierte Syscalls für weniger Argumente (Performance)
; int64 _lyx_syscall2(int64 num, int64 a1, int64 a2)
_lyx_syscall2:
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    syscall
    ret

; int64 _lyx_syscall1(int64 num, int64 a1)
_lyx_syscall1:
    mov rax, rdi
    mov rdi, rsi
    syscall
    ret

; int64 _lyx_syscall0(int64 num)
_lyx_syscall0:
    mov rax, rdi
    syscall
    ret

; Hilfsfunktionen für Fehlerbehandlung
; int64 _lyx_error_from_syscall(int64 result)
_lyx_error_from_syscall:
    test rax, rax           ; Test auf negative Ergebnisse
    js .error              ; Wenn negativ, ist es ein Fehler
    ret

.error:
    neg rax                ; Absolutwert zurückgeben
    ret

; int64 _lyx_is_error(int64 result)
_lyx_is_error:
    test rdi, rdi
    js .yes               ; Negativ = Fehler
    mov rax, 0           ; False
    ret
.yes:
    mov rax, 1           ; True
    ret