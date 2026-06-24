# REGRESSION in lyxc 1.0.2B: peek/poke → PrintStr is back

**Compiler:** lyxc 1.0.2B
**Target:** `--target=lyxos`. ELF correct.
**Severity:** High — re-opens the already-fixed peek/poke mis-dispatch.

## What happened

- 1.0.2A **fixed** the peek/poke→PrintStr mis-dispatch (verified: `peek8("Z")`=90).
- 1.0.2A had a **separate** strength-reduction bug (`*2^k`/`/2^k`).
- 1.0.2B **fixed strength-reduction** (verified: `x*4`=76, `x/8`=10, all OK) …
- … but **regressed peek/poke**: it is mis-dispatched to PrintStr again, exactly
  as in the original 1.0.1E bug. The two fixes are not both present in 1.0.2B.

## Proof (1.0.2B)

| test | ELF | lyxos |
|------|----:|------:|
| `var s:pchar:="Z"; var ch:=peek8(s); return ch;` | 90 | **0** |
| `peek64("ABCDEFGH") & 0xFF` | 65 | **0** |
| `StrCharAt("Z",0)` | 90 | **0** |
| `x*4`, `x/8` (strength-reduction) | 76 / 10 | 76 / 10 ✓ |

Disasm of `peek8(s)` in 1.0.2B — identical to the original bug, a PrintStr body
(strlen + `write`), no byte load:

```
lea  rax,[rel 0x4000be]     ; s = &"Z"   (correct)
...
mov  rsi,[rbp-0x8]
mov  rdx,[rbp-0x10]
cmp  byte [rsi+rdx],0        ; strlen
jz / inc rdx / jmp
mov  edi,1
mov  rax,0x203               ; write / PrintStr  <-- peek8 became PrintStr again
syscall
```

## Likely cause

The 1.0.2B work (strength-reduction in `ir_optimize.lyx`) appears to have been
built on a tree that does **not** contain the 1.0.2A `ir_lower.lyx` change
(adding peek8/peek64/peek32/poke8/poke64/poke32/StrCharAt to `lowerCall`'s
builtin table / not defaulting the catch-all to `IRO_CALL_BUILTIN imm=1`
PrintStr). A rebase/branch reset most likely dropped it.

## Ask

Ship a build that contains **both** fixes:
1. peek/poke/StrCharAt builtins lowered correctly (1.0.2A fix), AND
2. strength-reduction shift-count as a temp ref, not raw operand (1.0.2B fix).

Regression test to keep both green:

```lyx
// must return 90 on both ELF and --target=lyxos
fn main(): int64 { var s: pchar := "Z"; return peek8(s); }
// must return 76 on both
fn t(): int64 { var x: int64 := 19; return x * 4; }
```

After both land, `vega/lbfwin` should finally render (its draw path is just
peek8 / poke / `*4` pixel math; the kernel already honours its 128 KB stack and
loads multi-section LBF images).
