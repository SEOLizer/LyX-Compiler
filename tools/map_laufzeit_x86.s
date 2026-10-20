# tools/map_laufzeit_x86.s — Quelle der Map-Laufzeit im x86-Helferblock (#2150)
#
# Die Bytes in codegen_x86.lyx (cg_emitHelpers, "Map-Laufzeit, Teil 1/2")
# sind aus dieser Datei assembliert. Die .org-Angaben sind die echten
# Versaetze im Helferblock (CG_H_MAP_NEW = 990, __lyx_stack_fail = 1275,
# CG_H_MAP_STR = 1478); nur dann stimmen die Sprungweiten zwischen den
# Eintritten und dem Kern.
#
#   as --64 -o map.o tools/map_laufzeit_x86.s
#   objcopy -O binary --only-section=.text map.o map.bin
#   nm -n map.o            # Versaetze fuer CG_H_MAP_SET/GET/HAS, Kernlaenge
#
# Aufbau der Map: [m+0] Kapazitaet, [m+8] Anzahl, [m+16] Eintraege;
# Eintrag 32 Byte: Schluessel, Wert, Hash, belegt. Dieselbe Bauart erzeugt
# ir_lower.lyx (_mapNeu/_mapZugriff) fuer die IR-Ziele.
.intel_syntax noprefix
.text
.org 990
# ---- _lyx_map_new(rdi=cap) -> rax = map
map_new:
  push rbx
  mov rbx, rdi
  xor edi, edi
  mov esi, 24
  mov edx, 3
  mov r10d, 34
  mov r8, -1
  xor r9d, r9d
  mov eax, 9
  syscall
  cmp rax, -4095
  jae oom
  push rax
  mov rsi, rbx
  shl rsi, 5
  xor edi, edi
  mov edx, 3
  mov r10d, 34
  mov r8, -1
  xor r9d, r9d
  mov eax, 9
  syscall
  cmp rax, -4095
  jae oom
  pop rcx
  mov [rcx], rbx
  mov [rcx+16], rax
  mov rax, rcx
  pop rbx
  ret
# ---- _lyx_map_set(rdi=map, rsi=key, rdx=val)
map_set:
  xor ecx, ecx
  xor r8d, r8d
  jmp kern
map_get:
  mov ecx, 1
  xor r8d, r8d
  jmp kern
map_has:
  mov ecx, 2
  xor r8d, r8d
  jmp kern
oom:
  # Text im DATENbereich (codegen_x86.lyx: cg_edata + cg_emitLeaRdiData,
  # den Versatz setzt cg_patchAll) — Text im Code disassembliert jedes
  # Werkzeug anders (tests/disasm_test.sh).
  lea rdi, [rip+0]
  mov rsi, rdi
  mov edx, 42
  mov edi, 2
  mov eax, 1
  syscall
  mov edi, 1
  mov eax, 231
  syscall
.org 1275, 0xcc
.org 1478, 0x00
# ---- _lyx_map_str(rdi=map, rsi=key, rdx=val, rcx=modus)
map_str:
  mov r8d, 1
kern:
  push rbx
  push r12
  push r13
  push r14
  push r15
  push rbp
  sub rsp, 8
  mov [rsp], r8
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rbp, rcx
  test r8, r8
  jz inthash
  movabs r15, 0xCBF29CE484222325
  movabs r10, 0x100000001B3
  mov rsi, r12
hloop:
  movzx eax, byte ptr [rsi]
  test al, al
  jz hdone
  xor r15, rax
  imul r15, r10
  inc rsi
  jmp hloop
inthash:
  mov r15, r12
hdone:
  test rbp, rbp
  jnz probe
  mov rax, [rbx+8]
  inc rax
  shl rax, 2
  mov rcx, [rbx]
  lea rcx, [rcx+rcx*2]
  cmp rax, rcx
  jbe probe
  call grow
probe:
  mov r14, [rbx]
  dec r14
  mov rax, r15
  and rax, r14
ptop:
  mov rcx, rax
  shl rcx, 5
  add rcx, [rbx+16]
  cmp qword ptr [rcx+24], 0
  je leer
  cmp r15, [rcx+16]
  jne weiter
  cmp qword ptr [rsp], 0
  jne strcmp
  cmp r12, [rcx]
  je treffer
  jmp weiter
strcmp:
  push rax
  push rcx
  mov rdi, [rcx]
  mov rsi, r12
sloop:
  mov al, [rdi]
  cmp al, [rsi]
  jne ungleich
  test al, al
  jz gleich
  inc rdi
  inc rsi
  jmp sloop
ungleich:
  pop rcx
  pop rax
  jmp weiter
gleich:
  pop rcx
  pop rax
  jmp treffer
weiter:
  inc rax
  and rax, r14
  jmp ptop
leer:
  test rbp, rbp
  jnz null
  inc qword ptr [rbx+8]
  mov [rcx], r12
  mov [rcx+8], r13
  mov [rcx+16], r15
  mov qword ptr [rcx+24], 1
  xor eax, eax
  jmp ende
treffer:
  test rbp, rbp
  jnz t_lesen
  mov [rcx+8], r13
  xor eax, eax
  jmp ende
t_lesen:
  cmp rbp, 1
  jne t_hat
  mov rax, [rcx+8]
  jmp ende
t_hat:
  mov eax, 1
  jmp ende
null:
  xor eax, eax
ende:
  add rsp, 8
  pop rbp
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
grow:
  mov r14, [rbx]
  lea rsi, [r14+r14]
  shl rsi, 5
  xor edi, edi
  mov edx, 3
  mov r10d, 34
  mov r8, -1
  xor r9d, r9d
  mov eax, 9
  syscall
  cmp rax, -4095
  jae oom
  mov rdi, rax
  mov rsi, [rbx+16]
  mov r9, r14
  lea r8, [r14+r14-1]
  xor edx, edx
gl:
  cmp rdx, r9
  jae gdone
  mov rcx, rdx
  shl rcx, 5
  add rcx, rsi
  cmp qword ptr [rcx+24], 0
  je gnext
  mov rax, [rcx+16]
  and rax, r8
gp:
  mov r10, rax
  shl r10, 5
  add r10, rdi
  cmp qword ptr [r10+24], 0
  je gput
  inc rax
  and rax, r8
  jmp gp
gput:
  mov r11, [rcx]
  mov [r10], r11
  mov r11, [rcx+8]
  mov [r10+8], r11
  mov r11, [rcx+16]
  mov [r10+16], r11
  mov qword ptr [r10+24], 1
gnext:
  inc rdx
  jmp gl
gdone:
  mov [rbx+16], rdi
  lea rax, [r9+r9]
  mov [rbx], rax
  mov rdi, rsi
  mov rsi, r9
  shl rsi, 5
  mov eax, 11
  syscall
  ret
kernende:
