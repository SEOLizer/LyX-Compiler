# BUG: `--target=lyxos` mis-compiles peek/poke/StrCharAt as `PrintStr`

**Compiler:** lyxc 1.0.1E (self-hosting, aurum/src)
**Target:** `--target=lyxos` (LBF / `LYX!` native). ELF target is correct.
**Severity:** High — breaks every LBF program that reads or writes memory
(peek/poke), i.e. all real apps. Surfaced as `vega/lbfwin` drawing garbage
and scribbling over the desktop framebuffer.

---

## TL;DR

In the IR lowering path used by `--target=lyxos`, the **memory-intrinsic
builtins are not in the builtin→id table**, so they hit the catch-all in
`IRLower.lowerCall` which emits `IRO_CALL_BUILTIN … imm = 1`. Builtin id 1
is **`PrintStr`**. So `peek8(s)` (and friends) compile to
`write(1, s, strlen(s))` instead of a memory load, and return garbage.

The x86/ELF backend handles these by name in `codegen_x86.lyx` and is fine.

---

## Minimal reproducers (all: ELF correct, lyxos wrong)

```lyx
// A — peek8 of a string literal
fn main(): int64 { var s: pchar := "Z"; return peek8(s); }   // 'Z' = 90
//   ELF  -> 90      lyxos -> 0

// B — peek64
fn main(): int64 { var s: pchar := "ABCDEFGH"; return peek64(s) & 0xFF; }
//   ELF  -> 65      lyxos -> 0

// C — poke8 + peek8 on an mmap buffer
fn main(): int64 {
    var b: int64 := mmap(0, 4096, 3, 34, -1, 0);
    poke8(b, 77); return peek8(b);                            // 77
}
//   ELF  -> 77      lyxos -> 0

// D — StrCharAt (uses the same path)
fn main(): int64 { var s: pchar := "Z"; return StrCharAt(s, 0); }
//   ELF  -> 90      lyxos -> 0
```

Confirmed broken in lyxos: `peek8`, `peek64`, `poke8`, `poke64`,
`StrCharAt` (likely also `peek32`, `poke32`, `StrSetChar` — same gap).

## Disassembly evidence (reproducer A, lyxos)

`main` for `return peek8(s)` emits a **PrintStr body** — a strlen loop plus
`write` — not a byte load:

```
lea  rax,[rel 0x4000be]     ; s = &"Z"  (correct, position-independent)
...
mov  rsi,[rbp-0x8]          ; arg ptr
mov  rdx,[rbp-0x10]
0x73: cmp byte [rsi+rdx],0  ; \
      jz  ...               ;  > inline strlen
      inc rdx               ; /
      jmp 0x73
mov  edi, 1                 ; fd = 1
mov  rax, 0x203             ; <-- write / PrintStr syscall
syscall
... returns an uninitialised slot (garbage)
```

There is no `movzx eax, byte [reg]` anywhere — `peek8` was never emitted.

---

## Root cause

`aurum/src/ir_lower.lyx`, `IRLower.lowerCall`, catch-all at **line ~2395**:

```lyx
// General call: lower first argument and emit IRO_CALL_BUILTIN
if (arg0 >= 0) {
  var argTemp: int64 := self.lowerExpr(arg0);
  self.irAddInstrDirect(IRO_CALL_BUILTIN, dest, argTemp, -1, 1);   // imm = 1 = PrintStr
}
return dest;
```

Any builtin name not matched by the long `self.seq(fname, fnlen, "<name>", …)`
table above (ids 1–171: PrintInt, StrSub, the `sys_*` set, …) falls here and
is silently turned into `IRO_CALL_BUILTIN` **id 1 (PrintStr)**, with only
`arg0` lowered. The line-1314 comment already names this hazard: *"the
generic id=1 fallback."*

Verified gap:

| builtin    | in `lowerCall` id-table | in `codegen_x86.lyx` (ELF inline) |
|------------|:-----------------------:|:---------------------------------:|
| peek8      | **no**                  | yes (≈ line 5049)                 |
| peek64     | **no**                  | yes (≈ line 5088)                 |
| peek32     | **no**                  | yes                               |
| poke8      | **no**                  | yes (≈ line 5029)                 |
| poke64     | **no**                  | yes (≈ line 5068)                 |
| poke32     | **no**                  | yes                               |
| StrCharAt  | **no**                  | yes                               |

ELF reaches the name-based inline emit in `codegen_x86.lyx`; lyxos goes
through `ir_lower` first and loses the call to the id=1 fallback before
`codegen_x86` ever sees the name.

---

## Suggested fix (two parts)

1. **Add the memory/string intrinsics to `IRLower.lowerCall`** with their own
   `IRO_CALL_BUILTIN` ids (or dedicated IR ops such as `IRO_LOAD8/LOAD64/
   STORE8/STORE64`) that the lyxos/IR backend lowers to real `mov`/`movzx`
   load-store — mirroring what `codegen_x86.lyx` already does by name:
   `peek8`, `peek16`, `peek32`, `peek64`, `peekf64`, `poke8`, `poke16`,
   `poke32`, `poke64`, `pokef64`, `StrCharAt`, `StrSetChar`. Audit the full
   builtin list in `codegen_x86.lyx` for any other name handled there but
   absent from `lowerCall`.

2. **Make the catch-all fail loud instead of defaulting to PrintStr.** Silently
   compiling an unknown call to `write()` hides bugs like this. Emit a real
   named/user call, or a hard `error: unknown builtin '<name>' for
   --target=lyxos`, instead of `imm = 1`.

---

## How it was found / impact on the OS side

The kernel LBF loader bug (only the last `SECTION_MAP` TLV was loaded) was
fixed first (lyx-os commit 539f947) — LBF binaries now load and run. With that
out of the way, `lbfwin` still rendered garbage because its draw path
(`DrawString` reads glyph/string bytes via `peek8`; `FillWinFb` writes via
`poke64`) compiled to `write(1, …)` syscalls that scribbled over the
framebuffer. `lbfwin` is parked (boot-spawn disabled in `vega/vega.lyx`) until
this compiler fix lands; it can be launched from the dock menu to retest.

Repro harness: compile each snippet twice (`lyxc x.lyx -o e` and
`lyxc x.lyx --target=lyxos -o x.lbf`), run the ELF directly; run the `.lbf`
by extracting its `SECTION_MAP` blocks into a flat image and `CFUNCTYPE`-
calling the entry (LBF code is position-independent / RIP-relative, so any
mmap base works).
