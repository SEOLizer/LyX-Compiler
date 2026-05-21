# S1 Bootstrap Debugging Notes

## Current Status (as of 2026-04-11)

### S2 Compiler Capabilities
- ✅ S2 (bootstrap/lyxc.lyx compiled by S1) compiles successfully
- ✅ S2 can compile simple Lyx programs (`fn main(): int64 { return 42; }`)
- ✅ S2 generates valid ELF files with correct header structure
- ✅ S2 binary loads (int3 at entry point triggers SIGTRAP, proving code runs)
- ❌ BUT: Still crashes on full execution - SIGSEGV at 0x401022

### Latest Code (emitX86_64)
```lyx
// _start at offset 0, main at offset 23
// Entry point at vaddr 0x401000

// 0x401000: int3 (debug - proves we get here)
cc

// 0x401001: push rbp
55

// 0x401002-0x401005: mov rbp, rsp
48 89 e8

// 0x401006-0x40100a: call main (rel32 = 13)
e8 0d 00 00 00

// 0x40100b-0x40100d: mov rdi, rax
48 89 c7

// 0x40100e-0x401017: mov rax, 60; syscall
48 b8 3c 00 00 00 00 00 00 0f 05

// 0x401019: main: push rbp
55

// 0x40101a-0x40101d: mov rbp, rsp
48 89 e8

// 0x40101e-0x401027: mov rax, 42
48 b8 2a 00 00 00 00 00 00

// 0x401028: pop rbp
5d

// 0x401029: ret
c3
```

Total: 42 bytes (codeLen = 42)

## Key Discoveries

### 1. ELF Structure is CORRECT
- Single PT_LOAD at offset 0x1000, vaddr 0x401000, filesz=0x20, memsz=0x20
- Entry point: 0x401000
- Program header count: 1 (verified with readelf)
- Headers at offset 64 are covered by LOAD segment (offset 0x1000 > 0x40)

### 2. Code Execution Confirmed
- int3 at entry point triggers SIGTRAP (not SIGSEGV)
- This proves the ELF loads correctly and CPU starts executing at 0x401000
- The problem occurs AFTER the initial execution

### 3. GDB Analysis
```
RIP = 0x401022 (after ret at 0x401029)
RSP = 0x7fffffffd6e0 (valid stack pointer)
RBP = 0x0 (was zeroed by main's "pop rbp" to "push rbp" in _start)
```

The crash happens when `ret` in main tries to pop from stack, but stack is invalid.

### 4. Stack Alignment Issue
- In `_start`: we push rbp (8 bytes), then call main (pushes return address = 8 bytes)
- In main: we push rbp again
- The problem: RSP is not properly aligned for SysV ABI (should be 16-byte aligned before call)

### 5. Syscall Instruction Fix
- Original: `0f 05` = syscall (wrong! needs REX prefix for sys_exit)
- Correct: `0f 05` is actually correct for syscall
- The issue is not the syscall encoding

### 6. mov rdi, rax Fix
- Original: `48 89 f8` = mov rax, rdi (WRONG direction!)
- Fixed: `48 89 c7` = mov rdi, rax (correct)

## What Works Now

1. **ELF loading**: Binary loads correctly, int3 at entry proves this
2. **Single PT_LOAD**: Matches S1 working binary structure
3. **Program headers**: Correctly formatted and counted

## What's Still Broken

1. **Stack alignment**: RSP not 16-byte aligned before calling main
2. **Return address**: After call main, stack has return address that needs proper handling
3. **Full execution**: Binary still crashes with SIGSEGV at 0x401022

## GDB Output (Final State)
```
Program received signal SIGSEGV, Segmentation fault.
0x0000000000401022 in ?? ()
rax            0xc35d0000002a      214804199374890
rbx            0x0                 0
...
rip            0x401022            0x401022
rsp            0x7fffffffd6e0      0x7fffffffd6e0
rbp            0x0                 0x0
```

0x401022 is AFTER our ret instruction (0x401029), which means the CPU is trying to execute invalid code after returning from main.

## Next Steps

1. **Fix stack alignment**: Add `sub rsp, 8` before `call main` to ensure 16-byte alignment
2. **Fix return handling**: The `ret` in main pops garbage because we didn't properly set up the stack
3. **Alternative**: Instead of returning from main, jump directly to exit syscall

## Files Modified
- `bootstrap/ir_lower.lyx` - VTable detection, lowerCall handling
- `bootstrap/lyxc.lyx` - emitX86_64 (with int3 debug), writeELF (single PT_LOAD)
- `bootstrap/s1-debug.md` - This documentation

## Test Commands

```bash
# Compile S2 with S1
cd /home/andreas/PhpstormProjects/aurum
./compiler/lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_s2

# Test S2
echo 'fn main(): int64 { return 42; }' > /tmp/test42.lyx
/tmp/lyxc_s2 /tmp/test42.lyx -o /tmp/test42_out

# Run and check exit code
/tmp/test42_out
echo "Exit code: $?"

# Debug with GDB
gdb -batch -ex "run" -ex "info registers" /tmp/test42_out

# Trace with strace
strace /tmp/test42_out

# Compare with working binary
./compiler/lyxc /tmp/test42.lyx -o /tmp/test41_out
/tmp/test41_out
echo "Working exit code: $?"
```

## Comparison: S1 vs S2 Binary

### S1 (Working) - 4472 bytes
- Multiple sections (.text, .data, .rodata, etc.)
- Proper syscall setup (brk for memory allocation)
- Full runtime initialization

### S2 (Crashing) - 4128 bytes
- Single PT_LOAD segment
- Minimal code (just _start + main)
- No runtime setup

The key difference may be that S1 sets up a proper stack and memory layout, while our minimal S2 doesn't.